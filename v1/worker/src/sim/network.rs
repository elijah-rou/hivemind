use std::collections::VecDeque;

use crate::message::{ControlMessage, WorkerMessage};
use crate::prng::Prng;

const QUEUE_CAPACITY: usize = 256;

struct PendingControl {
    msg: ControlMessage,
    deliver_at_tick: u64,
}

struct PendingAgent {
    msg: WorkerMessage,
    deliver_at_tick: u64,
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
    prng: Prng,
    pub min_delay: u64,
    pub max_delay: u64,
    pub drop_rate_percent: u8,

    // Packet replay: probability of re-queueing a delivered message
    pub replay_percent: u8,

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
            prng: Prng::init(seed.wrapping_add(0xBEEF)),
            min_delay: 1,
            max_delay: 5,
            drop_rate_percent: 0,
            replay_percent: 0,
            path_max_capacity: 0,
            partition_stable_until,
            heal_stable_until: 0,
            partition_stability: 0,
            heal_stability: 0,
            stats: MessageStats::new(),
        }
    }

    pub fn send_to_agent(&mut self, agent_id: usize, msg: ControlMessage, current_tick: u64) {
        if self.partitioned[agent_id] {
            return;
        }
        if self.drop_rate_percent > 0 && self.prng.chance(self.drop_rate_percent) {
            return;
        }

        // Path clogging
        if self.path_max_capacity > 0 {
            let queue = &self.inbound[agent_id];
            if queue.len() >= self.path_max_capacity {
                return;
            }
        }

        let delay = self.min_delay + self.prng.bounded(self.max_delay - self.min_delay + 1);
        let queue = &mut self.inbound[agent_id];
        if queue.len() < QUEUE_CAPACITY {
            queue.push_back(PendingControl {
                msg,
                deliver_at_tick: current_tick + delay,
            });
            self.stats.control_sent += 1;
        }
    }

    pub fn send_from_agent(&mut self, agent_id: usize, msg: WorkerMessage, current_tick: u64) {
        if self.partitioned[agent_id] {
            return;
        }
        if self.drop_rate_percent > 0 && self.prng.chance(self.drop_rate_percent) {
            return;
        }

        let delay = self.min_delay + self.prng.bounded(self.max_delay - self.min_delay + 1);
        let queue = &mut self.outbound[agent_id];
        if queue.len() < QUEUE_CAPACITY {
            queue.push_back(PendingAgent {
                msg,
                deliver_at_tick: current_tick + delay,
            });
        }
    }

    pub fn pop_inbound(&mut self, agent_id: usize, now: u64) -> Option<ControlMessage> {
        let queue = &mut self.inbound[agent_id];
        let pos = queue.iter().position(|m| m.deliver_at_tick <= now)?;
        Some(queue.remove(pos).unwrap().msg)
    }

    pub fn pop_outbound(&mut self, agent_id: usize, now: u64) -> Option<WorkerMessage> {
        let queue = &mut self.outbound[agent_id];
        let pos = queue.iter().position(|m| m.deliver_at_tick <= now)?;
        Some(queue.remove(pos).unwrap().msg)
    }

    pub fn partition_agent(&mut self, agent_id: usize, current_tick: u64) {
        if current_tick < self.heal_stable_until {
            return; // too soon after last heal
        }
        self.partitioned[agent_id] = true;
        self.partition_stable_until[agent_id] = current_tick + self.partition_stability;
    }

    pub fn is_partitioned(&self, agent_id: usize) -> bool {
        self.partitioned[agent_id]
    }

    pub fn heal_all(&mut self, current_tick: u64) {
        // Check stability: don't heal if any partition is too recent
        for &stable_until in &self.partition_stable_until {
            if current_tick < stable_until {
                return;
            }
        }
        for p in self.partitioned.iter_mut() {
            *p = false;
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
    fn partitioned_drops_messages() {
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
}
