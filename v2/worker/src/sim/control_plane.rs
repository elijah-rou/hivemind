use crate::message::*;
use crate::prng::Prng;
use crate::types::GpuType;

const SCHEDULE_CAPACITY: usize = 4_096;
const RECEIVED_CAPACITY: usize = 16_384;

pub struct ControlPlaneStub {
    prng: Prng,
    scheduled: Vec<(u64, usize, ControlMessage)>,
    schedule_index: usize,
    received: Vec<(u64, usize, WorkerMessage)>,
    next_pod_id: u64,
}

impl ControlPlaneStub {
    pub fn new(seed: u64) -> Self {
        Self {
            prng: Prng::init(seed.wrapping_add(0xF00D)),
            scheduled: Vec::with_capacity(SCHEDULE_CAPACITY),
            schedule_index: 0,
            received: Vec::with_capacity(RECEIVED_CAPACITY),
            next_pod_id: 1,
        }
    }

    pub fn generate_workload(&mut self, agent_count: usize, pod_count: u32, over_ticks: u64) {
        assert!(agent_count > 0);
        assert!(over_ticks >= 2);
        assert!(self.scheduled.len() <= SCHEDULE_CAPACITY);
        assert!((pod_count as usize).saturating_mul(2) <= SCHEDULE_CAPACITY - self.scheduled.len());
        for _ in 0..pod_count {
            let agent_id = self.prng.bounded(agent_count as u64) as usize;
            let start_tick = self.prng.bounded(over_ticks / 2);
            let pod_id = self.next_pod_id;
            self.next_pod_id += 1;

            let gpu_count = (self.prng.bounded(3) + 1) as u8;

            self.scheduled.push((
                start_tick,
                agent_id,
                ControlMessage::StartPod(StartPodCmd {
                    pod_id,
                    deployment_id: pod_id * 100,
                    image: format!("sim-image:{pod_id}"),
                    entrypoint: String::new(),
                    port: 8080,
                    gpu_count,
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
                }),
            ));

            if self.prng.chance(60) {
                let stop_tick = start_tick + 50 + self.prng.bounded(200);
                self.scheduled.push((
                    stop_tick,
                    agent_id,
                    ControlMessage::StopPod(StopPodCmd {
                        pod_id,
                        grace_period_ms: 5000,
                    }),
                ));
            }
        }

        self.scheduled.sort_by_key(|(tick, _, _)| *tick);
    }

    pub fn commands_for_tick(&mut self, tick: u64) -> Vec<(usize, ControlMessage)> {
        let mut result = Vec::new();
        while self.schedule_index < self.scheduled.len()
            && self.scheduled[self.schedule_index].0 <= tick
        {
            let (_, agent_id, ref cmd) = self.scheduled[self.schedule_index];
            result.push((agent_id, cmd.clone()));
            self.schedule_index += 1;
        }
        result
    }

    pub fn on_agent_message(&mut self, tick: u64, agent_id: usize, msg: WorkerMessage) {
        assert!(self.received.len() < RECEIVED_CAPACITY);
        self.received.push((tick, agent_id, msg));
    }

    pub fn received_messages(&self) -> &[(u64, usize, WorkerMessage)] {
        &self.received
    }
}
