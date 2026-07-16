use std::collections::VecDeque;

use crate::io::Io;
use crate::message::{ControlMessage, WorkerMessage};
use crate::prng::Prng;

/// Deterministic Io for simulation. The simulator fills `inbound`
/// and drains `outbound` around each agent tick call.
pub struct SimulatedIo {
    pub current_tick: u64,
    pub inbound: VecDeque<ControlMessage>,
    pub outbound: Vec<WorkerMessage>,
    prng: Prng,
}

impl SimulatedIo {
    pub fn new(seed: u64) -> Self {
        Self {
            current_tick: 0,
            inbound: VecDeque::new(),
            outbound: Vec::new(),
            prng: Prng::init(seed),
        }
    }
}

impl Io for SimulatedIo {
    fn now(&self) -> u64 {
        self.current_tick
    }

    fn send(&mut self, msg: WorkerMessage) {
        self.outbound.push(msg);
    }

    fn recv(&mut self) -> Option<ControlMessage> {
        self.inbound.pop_front()
    }

    fn random_u64(&mut self) -> u64 {
        self.prng.next()
    }
}
