use std::collections::VecDeque;

use crate::io::Io;
use crate::message::{ControlMessage, WorkerMessage};
use crate::prng::Prng;

const STAGING_CAPACITY: usize = 256;

/// Deterministic Io for simulation. The simulator fills `inbound`
/// and drains `outbound` around each agent tick call.
pub struct SimulatedIo {
    pub current_tick: u64,
    inbound: VecDeque<ControlMessage>,
    outbound: Vec<WorkerMessage>,
    prng: Prng,
}

impl SimulatedIo {
    pub fn new(seed: u64) -> Self {
        Self {
            current_tick: 0,
            inbound: VecDeque::with_capacity(STAGING_CAPACITY),
            outbound: Vec::with_capacity(STAGING_CAPACITY),
            prng: Prng::init(seed),
        }
    }

    pub fn push_inbound(&mut self, msg: ControlMessage) {
        assert!(
            self.inbound.len() < STAGING_CAPACITY,
            "simulated I/O inbound staging capacity exceeded"
        );
        self.inbound.push_back(msg);
    }

    pub fn drain_outbound(&mut self) -> std::vec::Drain<'_, WorkerMessage> {
        assert!(
            self.outbound.len() <= STAGING_CAPACITY,
            "simulated I/O outbound staging capacity exceeded"
        );
        self.outbound.drain(..)
    }
}

impl Io for SimulatedIo {
    fn now(&self) -> u64 {
        self.current_tick
    }

    fn send(&mut self, msg: WorkerMessage) {
        assert!(
            self.outbound.len() < STAGING_CAPACITY,
            "simulated I/O outbound staging capacity exceeded"
        );
        self.outbound.push(msg);
    }

    fn recv(&mut self) -> Option<ControlMessage> {
        self.inbound.pop_front()
    }

    fn random_u64(&mut self) -> u64 {
        self.prng.next()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::{NodeHeartbeatMsg, WorkerMessage};

    #[test]
    #[should_panic(expected = "simulated I/O inbound staging capacity exceeded")]
    fn inbound_staging_is_fail_loud_bounded() {
        let mut io = SimulatedIo::new(0xB1_30);
        for pod_id in 0..=256 {
            io.push_inbound(ControlMessage::StopPod(crate::message::StopPodCmd {
                pod_id,
                grace_period_ms: 0,
            }));
        }
    }

    #[test]
    #[should_panic(expected = "simulated I/O outbound staging capacity exceeded")]
    fn outbound_staging_is_fail_loud_bounded() {
        let mut io = SimulatedIo::new(0xB1_30);
        for tick in 0..=256 {
            io.send(WorkerMessage::NodeHeartbeat(NodeHeartbeatMsg {
                tick,
                active_pods: 0,
                gpu_free: 0,
            }));
        }
    }
}
