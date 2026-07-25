use std::collections::VecDeque;

use crate::message::{ControlMessage, WorkerMessage};
use crate::prng::{Prng, Ratio};
use crate::protocol::{
    encode_agent_message, MAX_FRAME_PAYLOAD, MAX_RUN_RESPONSE_BODY, RUN_STATUS_RESPONSE_TOO_LARGE,
};

const QUEUE_CAPACITY: usize = 256;

struct PendingControl {
    msg: ControlMessage,
    deliver_at_tick: u64,
    epoch: u64,
    replayed: bool,
}

struct PendingAgent {
    msg: WorkerMessage,
    deliver_at_tick: u64,
    epoch: u64,
    replayed: bool,
}

/// Message accounting
pub struct MessageStats {
    pub control_sent: u64,
    pub control_bytes: u64,
    pub worker_sent: u64,
    pub worker_bytes: u64,
}

impl MessageStats {
    fn new() -> Self {
        Self {
            control_sent: 0,
            control_bytes: 0,
            worker_sent: 0,
            worker_bytes: 0,
        }
    }
}

pub struct SimulatedNetwork {
    inbound: Vec<VecDeque<PendingControl>>,
    outbound: Vec<VecDeque<PendingAgent>>,
    partitioned: Vec<bool>,
    session_epochs: Vec<u64>,
    prng: Prng,
    pub min_delay: u64,
    pub max_delay: u64,
    pub drop_rate: Ratio,

    // Packet replay: probability of re-queueing a delivered message
    pub replay_rate: Ratio,

    // Path clogging: max in-flight per worker (0=unlimited)
    pub path_max_capacity: usize,

    // Stability tracking
    pub partition_stable_until: Vec<u64>,
    pub heal_stable_until: u64,
    pub partition_stability: u64,
    pub heal_stability: u64,

    // Message accounting
    pub stats: MessageStats,
}

impl SimulatedNetwork {
    pub fn new(agent_count: usize, seed: u64) -> Self {
        let mut inbound = Vec::with_capacity(agent_count);
        let mut outbound = Vec::with_capacity(agent_count);
        let mut partitioned = Vec::with_capacity(agent_count);
        let mut partition_stable_until = Vec::with_capacity(agent_count);
        for _ in 0..agent_count {
            inbound.push(VecDeque::with_capacity(QUEUE_CAPACITY));
            outbound.push(VecDeque::with_capacity(QUEUE_CAPACITY));
            partitioned.push(false);
            partition_stable_until.push(0);
        }

        Self {
            inbound,
            outbound,
            partitioned,
            session_epochs: vec![0; agent_count],
            prng: Prng::init(seed.wrapping_add(0xBEEF)),
            min_delay: 1,
            max_delay: 5,
            drop_rate: Ratio::zero(),
            replay_rate: Ratio::zero(),
            path_max_capacity: 0,
            partition_stable_until,
            heal_stable_until: 0,
            partition_stability: 0,
            heal_stability: 0,
            stats: MessageStats::new(),
        }
    }

    pub fn send_to_agent(&mut self, agent_id: usize, msg: ControlMessage, current_tick: u64) {
        assert!(agent_id < self.inbound.len());
        assert!(self.min_delay <= self.max_delay);
        if self.prng.chance_ratio(self.drop_rate) {
            return;
        }

        let queue = &mut self.inbound[agent_id];
        if queue.len() >= Self::queue_capacity(self.path_max_capacity) {
            return;
        }

        let delay = self.min_delay + self.prng.bounded(self.max_delay - self.min_delay + 1);
        queue.push_back(PendingControl {
            msg,
            deliver_at_tick: current_tick + delay,
            epoch: self.session_epochs[agent_id],
            replayed: false,
        });
        self.stats.control_sent += 1;
    }

    pub fn send_from_agent(&mut self, agent_id: usize, msg: WorkerMessage, current_tick: u64) {
        assert!(agent_id < self.outbound.len());
        assert!(self.min_delay <= self.max_delay);
        if self.prng.chance_ratio(self.drop_rate) {
            return;
        }

        let queue = &mut self.outbound[agent_id];
        if queue.len() >= Self::queue_capacity(self.path_max_capacity) {
            return;
        }

        let mut payload = [0u8; MAX_FRAME_PAYLOAD];
        let (_, payload_len) = encode_agent_message(&msg, &mut payload)
            .expect("worker simulation must emit encodable messages");
        let msg = match msg {
            WorkerMessage::RunResponse(mut response)
                if response.payload.len() > MAX_RUN_RESPONSE_BODY =>
            {
                response.status = RUN_STATUS_RESPONSE_TOO_LARGE;
                response.payload.clear();
                WorkerMessage::RunResponse(response)
            }
            other => other,
        };
        let delay = self.min_delay + self.prng.bounded(self.max_delay - self.min_delay + 1);
        queue.push_back(PendingAgent {
            msg,
            deliver_at_tick: current_tick + delay,
            epoch: self.session_epochs[agent_id],
            replayed: false,
        });
        self.stats.worker_sent += 1;
        self.stats.worker_bytes += payload_len as u64;
    }

    pub fn pop_inbound(&mut self, agent_id: usize, now: u64) -> Option<ControlMessage> {
        assert!(agent_id < self.inbound.len());
        if self.partitioned[agent_id] {
            return None;
        }

        let queue = &mut self.inbound[agent_id];
        while queue.front().is_some_and(|pending| pending.epoch != self.session_epochs[agent_id]) {
            queue.pop_front();
        }
        if queue.front()?.deliver_at_tick > now {
            return None;
        }
        let pending = queue.pop_front().expect("ready inbound message must exist");
        if !pending.replayed
            && self.prng.chance_ratio(self.replay_rate)
            && queue.len() < Self::queue_capacity(self.path_max_capacity)
        {
            queue.push_back(PendingControl {
                msg: pending.msg.clone(),
                deliver_at_tick: now + self.min_delay.max(1),
                epoch: pending.epoch,
                replayed: true,
            });
        }
        Some(pending.msg)
    }

    pub fn pop_outbound(&mut self, agent_id: usize, now: u64) -> Option<WorkerMessage> {
        assert!(agent_id < self.outbound.len());
        if self.partitioned[agent_id] {
            return None;
        }

        let queue = &mut self.outbound[agent_id];
        while queue.front().is_some_and(|pending| pending.epoch != self.session_epochs[agent_id]) {
            queue.pop_front();
        }
        if queue.front()?.deliver_at_tick > now {
            return None;
        }
        let pending = queue.pop_front().expect("ready outbound message must exist");
        if !pending.replayed
            && self.prng.chance_ratio(self.replay_rate)
            && queue.len() < Self::queue_capacity(self.path_max_capacity)
        {
            queue.push_back(PendingAgent {
                msg: pending.msg.clone(),
                deliver_at_tick: now + self.min_delay.max(1),
                epoch: pending.epoch,
                replayed: true,
            });
        }
        Some(pending.msg)
    }

    fn queue_capacity(path_max_capacity: usize) -> usize {
        if path_max_capacity == 0 {
            QUEUE_CAPACITY
        } else {
            path_max_capacity.min(QUEUE_CAPACITY)
        }
    }

    pub fn partition_agent(&mut self, agent_id: usize, current_tick: u64) {
        if current_tick < self.heal_stable_until {
            return; // too soon after last heal
        }
        self.partitioned[agent_id] = true;
        self.partition_stable_until[agent_id] = current_tick + self.partition_stability;
    }

    pub fn is_partitioned(&self, agent_id: usize) -> bool {
        assert!(agent_id < self.partitioned.len());
        self.partitioned[agent_id]
    }

    pub fn discard_session_queues(&mut self, agent_id: usize) {
        assert!(agent_id < self.inbound.len());
        assert!(agent_id < self.outbound.len());
        self.session_epochs[agent_id] = self.session_epochs[agent_id]
            .checked_add(1)
            .expect("simulation session epoch must not overflow");
        self.inbound[agent_id].clear();
        self.outbound[agent_id].clear();
    }

    pub fn heal_all(&mut self, current_tick: u64) {
        // Check stability: don't heal if any partition is too recent
        for &stable_until in &self.partition_stable_until {
            if current_tick < stable_until {
                return;
            }
        }
        self.force_heal_all(current_tick);
    }

    pub fn force_heal_all(&mut self, current_tick: u64) {
        for partitioned in &mut self.partitioned {
            *partitioned = false;
        }
        self.heal_stable_until = current_tick + self.heal_stability;
    }

    pub fn heal_one(&mut self, agent_id: usize, current_tick: u64) {
        if current_tick < self.partition_stable_until[agent_id] {
            return;
        }
        self.partitioned[agent_id] = false;
    }

    /// Total messages sent (control + worker).
    pub fn total_messages(&self) -> u64 {
        self.stats.control_sent + self.stats.worker_sent
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::*;
    use crate::protocol::{MAX_RUN_RESPONSE_BODY, RUN_STATUS_RESPONSE_TOO_LARGE};
    use crate::types::GpuType;

    fn test_start_cmd(pod_id: u64) -> ControlMessage {
        ControlMessage::StartPod(StartPodCmd {
            pod_id,
            deployment_id: 100,
            image: "test:latest".into(),
            entrypoint: String::new(),
            port: 8080,
            gpu_count: 1,
            gpu_type: GpuType::H100Sxm,
            cpu_millicores: 2000,
            memory_megabytes: 4096,
            juicefs_path: String::new(),
            liveness_path: String::new(),
            readiness_path: String::new(),
            env_vars: vec![],
            image_pull_registry: String::new(),
            image_pull_username: String::new(),
            image_pull_password: String::new(),
            image_pull_password_is_secret: false,
        })
    }

    fn test_heartbeat(tick: u64) -> WorkerMessage {
        WorkerMessage::NodeHeartbeat(NodeHeartbeatMsg {
            tick,
            active_pods: 0,
            gpu_free: 1,
        })
    }

    #[test]
    fn message_delayed_delivery() {
        let mut net = SimulatedNetwork::new(1, 42);
        net.min_delay = 3;
        net.max_delay = 3;

        net.send_to_agent(0, test_start_cmd(1), 10);

        assert!(net.pop_inbound(0, 10).is_none());
        assert!(net.pop_inbound(0, 12).is_none());
        assert!(net.pop_inbound(0, 13).is_some());
    }

    #[test]
    fn partitioned_blocks_delivery() {
        let mut net = SimulatedNetwork::new(1, 42);
        net.partition_agent(0, 0);

        net.send_to_agent(0, test_start_cmd(1), 10);
        assert!(net.pop_inbound(0, 100).is_none());
    }

    #[test]
    fn heal_allows_messages() {
        let mut net = SimulatedNetwork::new(1, 42);
        net.min_delay = 1;
        net.max_delay = 1;

        net.partition_agent(0, 0);
        net.heal_all(1);

        net.send_to_agent(0, test_start_cmd(1), 10);
        assert!(net.pop_inbound(0, 11).is_some());
    }

    #[test]
    fn partition_holds_both_directions_until_healing() {
        let mut net = SimulatedNetwork::new(1, 0xB1_10);
        net.min_delay = 1;
        net.max_delay = 1;
        net.partition_agent(0, 0);
        net.send_to_agent(0, test_start_cmd(1), 0);
        net.send_from_agent(0, test_heartbeat(0), 0);

        assert!(net.pop_inbound(0, 10).is_none());
        assert!(net.pop_outbound(0, 10).is_none());

        net.heal_all(10);
        assert!(net.pop_inbound(0, 10).is_some());
        assert!(net.pop_outbound(0, 10).is_some());
        assert_eq!(net.stats.control_sent, 1);
        assert_eq!(net.stats.worker_sent, 1);
        assert!(net.stats.worker_bytes > 0);
    }

    #[test]
    fn outbound_preserves_registration_first_with_variable_delay() {
        for seed in 0..128 {
            let mut net = SimulatedNetwork::new(1, seed);
            net.send_from_agent(
                0,
                WorkerMessage::NodeRegister(NodeRegisterMsg {
                    node_name: "worker".into(),
                    cpu_millicores: 1,
                    memory_megabytes: 1,
                    gpu_type: GpuType::None,
                    gpu_count: 0,
                }),
                0,
            );
            net.send_from_agent(0, test_heartbeat(0), 0);

            let first = (1..=5).find_map(|tick| net.pop_outbound(0, tick));
            assert!(matches!(first, Some(WorkerMessage::NodeRegister(_))));
            assert!(matches!(
                net.pop_outbound(0, 5),
                Some(WorkerMessage::NodeHeartbeat(_))
            ));
        }
    }

    #[test]
    fn outbound_run_response_matches_wire_overflow_semantics() {
        let mut net = SimulatedNetwork::new(1, 0xB4_10);
        net.min_delay = 1;
        net.max_delay = 1;
        net.send_from_agent(
            0,
            WorkerMessage::RunResponse(RunResponseMsg {
                request_id: 44,
                status: 0,
                payload: vec![0x5a; MAX_RUN_RESPONSE_BODY + 1],
            }),
            0,
        );

        let delivered = net
            .pop_outbound(0, 1)
            .expect("encoded run response must be delivered");
        match delivered {
            WorkerMessage::RunResponse(response) => {
                assert_eq!(response.request_id, 44);
                assert_eq!(response.status, RUN_STATUS_RESPONSE_TOO_LARGE);
                assert!(response.payload.is_empty());
            }
            other => panic!("unexpected worker message: {other:?}"),
        }
    }

    #[test]
    fn drop_replay_and_capacity_apply_to_both_directions() {
        let mut dropped = SimulatedNetwork::new(1, 0xB1_11);
        dropped.drop_rate = Ratio::new(1, 1);
        dropped.send_to_agent(0, test_start_cmd(1), 0);
        dropped.send_from_agent(0, test_heartbeat(0), 0);
        assert!(dropped.pop_inbound(0, 100).is_none());
        assert!(dropped.pop_outbound(0, 100).is_none());
        assert_eq!(dropped.total_messages(), 0);

        let mut replayed = SimulatedNetwork::new(1, 0xB1_12);
        replayed.min_delay = 1;
        replayed.max_delay = 1;
        replayed.replay_rate = Ratio::new(1, 1);
        replayed.send_to_agent(0, test_start_cmd(1), 0);
        replayed.send_from_agent(0, test_heartbeat(0), 0);
        assert!(replayed.pop_inbound(0, 1).is_some());
        assert!(replayed.pop_outbound(0, 1).is_some());
        assert!(replayed.pop_inbound(0, 2).is_some());
        assert!(replayed.pop_outbound(0, 2).is_some());
        assert!(replayed.pop_inbound(0, 3).is_none());
        assert!(replayed.pop_outbound(0, 3).is_none());

        let mut clogged = SimulatedNetwork::new(1, 0xB1_13);
        clogged.min_delay = 1;
        clogged.max_delay = 1;
        clogged.path_max_capacity = 1;
        clogged.send_to_agent(0, test_start_cmd(1), 0);
        clogged.send_to_agent(0, test_start_cmd(2), 0);
        clogged.send_from_agent(0, test_heartbeat(1), 0);
        clogged.send_from_agent(0, test_heartbeat(2), 0);
        assert_eq!(clogged.stats.control_sent, 1);
        assert_eq!(clogged.stats.worker_sent, 1);
        assert!(clogged.pop_inbound(0, 1).is_some());
        assert!(clogged.pop_outbound(0, 1).is_some());
        assert!(clogged.pop_inbound(0, 1).is_none());
        assert!(clogged.pop_outbound(0, 1).is_none());
    }
}
