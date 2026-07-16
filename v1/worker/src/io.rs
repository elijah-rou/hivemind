use crate::message::{ControlMessage, WorkerMessage};

/// Abstraction over time, network, and randomness.
/// Production: real clock, TCP, OS random.
/// Simulation: tick counter, message queues, PRNG.
///
/// The agent borrows `&mut dyn Io` for each tick call and has
/// zero knowledge of whether it is running in simulation.
pub trait Io {
    fn now(&self) -> u64;
    fn send(&mut self, msg: WorkerMessage);
    fn recv(&mut self) -> Option<ControlMessage>;
    fn random_u64(&mut self) -> u64;
}
