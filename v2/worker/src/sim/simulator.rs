use crate::prng::Prng;
use crate::types::GpuType;
use crate::worker::Worker;

use super::checker::WorkerChecker;
use super::control_plane::ControlPlaneStub;
use super::io::SimulatedIo;
use super::network::SimulatedNetwork;
use super::runtime::{FaultConfig, SimulatedRuntime};

pub struct WorkerSimulator {
    pub current_tick: u64,
    pub prng: Prng,
    pub workers: Vec<Worker>,
    pub sim_ios: Vec<SimulatedIo>,
    pub sim_runtimes: Vec<SimulatedRuntime>,
    pub network: SimulatedNetwork,
    pub control_plane: ControlPlaneStub,
    pub checker: WorkerChecker,
    agent_count: usize,
}

impl WorkerSimulator {
    pub fn new(agent_count: usize, seed: u64) -> Self {
        Self::new_with_lifecycle_concurrency(agent_count, seed, 1)
    }

    pub fn new_with_lifecycle_concurrency(
        agent_count: usize,
        seed: u64,
        lifecycle_concurrency: usize,
    ) -> Self {
        let prng = Prng::init(seed.wrapping_add(0xDEAD));
        let network = SimulatedNetwork::new(agent_count, seed);
        let control_plane = ControlPlaneStub::new(seed);
        let checker = WorkerChecker::new(agent_count);

        let mut workers = Vec::with_capacity(agent_count);
        let mut sim_ios = Vec::with_capacity(agent_count);
        let mut sim_runtimes = Vec::with_capacity(agent_count);

        for i in 0..agent_count {
            let agent_seed = seed.wrapping_add(i as u64);
            sim_ios.push(SimulatedIo::new(agent_seed));
            sim_runtimes.push(SimulatedRuntime::new(agent_seed, FaultConfig::default()));
            workers.push(Worker::new_with_lifecycle_concurrency(
                format!("sim-node-{i}"),
                GpuType::H100Sxm,
                8,
                32000,
                65536,
                lifecycle_concurrency,
            ));
        }

        Self {
            current_tick: 0,
            prng,
            workers,
            sim_ios,
            sim_runtimes,
            network,
            control_plane,
            checker,
            agent_count,
        }
    }

    pub fn tick(&mut self) {
        self.current_tick += 1;

        // A. Deliver run responses enqueued on an earlier tick.
        for i in 0..self.agent_count {
            while let Some(message) = self.network.pop_outbound(i, self.current_tick) {
                self.control_plane
                    .on_agent_message(self.current_tick, i, message);
            }
        }

        // B. Control plane generates commands for this tick.
        let commands = self.control_plane.commands_for_tick(self.current_tick);
        for (agent_id, command) in commands {
            self.network
                .send_to_agent(agent_id, command, self.current_tick);
        }

        // C. Deliver control messages, tick each worker, then enqueue its output.
        for i in 0..self.agent_count {
            self.sim_ios[i].current_tick = self.current_tick;
            while let Some(message) = self.network.pop_inbound(i, self.current_tick) {
                self.sim_ios[i].push_inbound(message);
            }

            self.sim_runtimes[i].maybe_crash_pods();
            self.workers[i].tick(&mut self.sim_ios[i], &self.sim_runtimes[i]);

            for message in self.sim_ios[i].drain_outbound() {
                if matches!(message, crate::message::WorkerMessage::RunResponse(_)) {
                    self.network.send_from_agent(i, message, self.current_tick);
                } else {
                    self.control_plane
                        .on_agent_message(self.current_tick, i, message);
                }
            }
        }

        // D. Invariant checking
        for i in 0..self.agent_count {
            let partitioned = self.network.is_partitioned(i);
            self.checker
                .check(self.current_tick, i, &self.workers[i], partitioned);
        }
    }

    pub fn run(&mut self, ticks: u64) {
        for _ in 0..ticks {
            self.tick();
        }
    }

    pub fn partition_agent(&mut self, agent_id: usize) {
        self.network.partition_agent(agent_id, self.current_tick);
    }

    pub fn heal_all(&mut self) {
        self.network.heal_all(self.current_tick);
    }

    pub fn set_runtime_faults(&mut self, agent_id: usize, config: FaultConfig) {
        self.sim_runtimes[agent_id].fault_config = config;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::*;
    use crate::protocol::MAX_RUN_RESPONSE_BODY;
    use crate::sim::runtime::RunOutcome;
    use crate::types::GpuType;
    use crate::worker::TrackedPodState;

    #[test]
    fn deterministic_run_outcomes_preserve_identity_bounds_and_accounting() {
        let mut sim = WorkerSimulator::new(1, 0xB4_02);
        sim.network.min_delay = 1;
        sim.network.max_delay = 1;
        let mut gpu_start = match start_cmd(820, 8_200) {
            ControlMessage::StartPod(command) => command,
            _ => unreachable!("start_cmd must construct StartPod"),
        };
        gpu_start.gpu_count = 1;
        gpu_start.gpu_type = GpuType::H100Sxm;
        sim.network
            .send_to_agent(0, ControlMessage::StartPod(gpu_start), 0);
        sim.run(5);
        assert_eq!(
            sim.workers[0].tracked_pods()[&820].state,
            TrackedPodState::Running
        );
        sim.sim_runtimes[0].script_run_outcomes(
            820,
            &[
                RunOutcome::Echo,
                RunOutcome::ExactResponseBoundary,
                RunOutcome::ResponseBoundaryOverflow,
                RunOutcome::ForwardingFailure,
                RunOutcome::Timeout,
                RunOutcome::Echo,
                RunOutcome::Echo,
            ],
        );

        let resources = |sim: &WorkerSimulator| {
            (
                sim.workers[0].gpu_allocated(),
                sim.workers[0].cpu_allocated_millicores(),
                sim.workers[0].memory_allocated_megabytes(),
            )
        };
        let running_resources = resources(&sim);
        assert_eq!(running_resources, (1, 10, 16));

        for (request_id, expected_status, payload, expected_response_len) in [
            (821, 0, b"success".as_slice(), b"success".len()),
            (822, 0, b"exact-boundary".as_slice(), MAX_RUN_RESPONSE_BODY),
            (
                823,
                crate::protocol::RUN_STATUS_RESPONSE_TOO_LARGE,
                b"overflow".as_slice(),
                0,
            ),
            (
                824,
                crate::protocol::RUN_STATUS_FORWARDING_FAILED,
                b"failure".as_slice(),
                "internal error: simulated forwarding failure".len(),
            ),
            (
                825,
                crate::protocol::RUN_STATUS_FORWARDING_FAILED,
                b"timeout".as_slice(),
                "internal error: simulated forwarding timeout".len(),
            ),
        ] {
            sim.network.send_to_agent(
                0,
                ControlMessage::RunRequest(RunRequestCmd {
                    request_id,
                    deployment_id: 8_200,
                    payload: payload.to_vec(),
                }),
                sim.current_tick,
            );
            sim.run(3);
            let responses: Vec<_> = sim
                .control_plane
                .received_messages()
                .iter()
                .filter_map(|(_, agent_id, message)| match message {
                    WorkerMessage::RunResponse(response)
                        if *agent_id == 0 && response.request_id == request_id =>
                    {
                        Some(response)
                    }
                    _ => None,
                })
                .collect();
            assert_eq!(
                responses.len(),
                1,
                "request must produce exactly one response"
            );
            let response = responses[0];
            assert_eq!(response.status, expected_status);
            assert_eq!(response.payload.len(), expected_response_len);
            assert!(response.payload.len() <= MAX_RUN_RESPONSE_BODY);
            if request_id == 821 {
                assert_eq!(response.payload, payload);
            }
            assert_eq!(resources(&sim), running_resources);
        }

        // A response accepted by the outbound path before a partition remains
        // buffered and is delivered exactly once after healing.
        sim.sim_ios[0].push_inbound(ControlMessage::RunRequest(RunRequestCmd {
            request_id: 826,
            deployment_id: 8_200,
            payload: b"buffered-before-partition".to_vec(),
        }));
        sim.tick();
        sim.partition_agent(0);
        sim.run(3);
        assert!(!sim
            .control_plane
            .received_messages()
            .iter()
            .any(|(_, _, message)| matches!(
                message,
                WorkerMessage::RunResponse(response) if response.request_id == 826
            )));
        sim.heal_all();
        sim.run(1);
        let healed_responses: Vec<_> = sim
            .control_plane
            .received_messages()
            .iter()
            .filter_map(|(_, agent_id, message)| match message {
                WorkerMessage::RunResponse(response)
                    if *agent_id == 0 && response.request_id == 826 =>
                {
                    Some(response)
                }
                _ => None,
            })
            .collect();
        assert_eq!(healed_responses.len(), 1);
        let healed = healed_responses[0];
        assert_eq!(healed.status, 0);
        assert_eq!(healed.payload, b"buffered-before-partition");
        assert!(healed.payload.len() <= MAX_RUN_RESPONSE_BODY);
        assert_eq!(resources(&sim), running_resources);

        // A request already accepted into worker I/O can execute after the link
        // partitions while its response send fails. The caller observes no reply,
        // so execution is provably ambiguous rather than safely retryable.
        let run_attempts_before = sim.sim_runtimes[0].run_attempt_count(820);
        sim.sim_ios[0].push_inbound(ControlMessage::RunRequest(RunRequestCmd {
            request_id: 829,
            deployment_id: 8_200,
            payload: b"executed-but-response-lost".to_vec(),
        }));
        sim.partition_agent(0);
        sim.tick();
        assert_eq!(
            sim.sim_runtimes[0].run_attempt_count(820),
            run_attempts_before + 1
        );
        assert_eq!(sim.network.stats.worker_failed_partition, 1);
        sim.heal_all();
        sim.run(3);
        assert!(!sim
            .control_plane
            .received_messages()
            .iter()
            .any(|(_, _, message)| matches!(
                message,
                WorkerMessage::RunResponse(response) if response.request_id == 829
            )));
        assert_eq!(resources(&sim), running_resources);

        sim.sim_runtimes[0].crash_pod(820, 137);
        sim.sim_ios[0].push_inbound(ControlMessage::RunRequest(RunRequestCmd {
            request_id: 827,
            deployment_id: 8_200,
            payload: b"crash-tick".to_vec(),
        }));
        sim.tick();
        let stopped_resources = resources(&sim);
        assert_eq!(stopped_resources, (0, 0, 0));
        sim.tick();
        let crash_tick_responses: Vec<_> = sim
            .control_plane
            .received_messages()
            .iter()
            .filter_map(|(_, agent_id, message)| match message {
                WorkerMessage::RunResponse(response)
                    if *agent_id == 0 && response.request_id == 827 =>
                {
                    Some(response)
                }
                _ => None,
            })
            .collect();
        assert_eq!(crash_tick_responses.len(), 1);
        assert_eq!(
            crash_tick_responses[0].status,
            crate::protocol::RUN_STATUS_FORWARDING_FAILED,
            "a request already delivered on the crash tick observes runtime forwarding failure"
        );
        assert_eq!(resources(&sim), stopped_resources);

        sim.network.send_to_agent(
            0,
            ControlMessage::RunRequest(RunRequestCmd {
                request_id: 828,
                deployment_id: 8_200,
                payload: b"after-crash".to_vec(),
            }),
            sim.current_tick,
        );
        sim.run(3);
        let no_pod_responses: Vec<_> = sim
            .control_plane
            .received_messages()
            .iter()
            .filter_map(|(_, agent_id, message)| match message {
                WorkerMessage::RunResponse(response)
                    if *agent_id == 0 && response.request_id == 828 =>
                {
                    Some(response)
                }
                _ => None,
            })
            .collect();
        assert_eq!(no_pod_responses.len(), 1);
        let no_pod = no_pod_responses[0];
        assert_eq!(no_pod.status, crate::protocol::RUN_STATUS_NO_RUNNING_POD);
        assert!(no_pod.payload.len() <= MAX_RUN_RESPONSE_BODY);
        assert_eq!(resources(&sim), stopped_resources);
        assert_eq!(sim.checker.safety_violations, 0);
    }

    #[test]
    fn single_agent_registers_and_heartbeats() {
        let mut sim = WorkerSimulator::new(1, 42);
        sim.run(200);

        assert_eq!(sim.checker.safety_violations, 0);
        assert!(sim.workers[0].is_registered());

        let has_register = sim
            .control_plane
            .received_messages()
            .iter()
            .any(|(_, _, msg)| matches!(msg, WorkerMessage::NodeRegister(_)));
        assert!(has_register);

        let heartbeat_count = sim
            .control_plane
            .received_messages()
            .iter()
            .filter(|(_, _, msg)| matches!(msg, WorkerMessage::NodeHeartbeat(_)))
            .count();
        assert!(heartbeat_count >= 1);
    }

    #[test]
    fn start_pod_flows_through() {
        let mut sim = WorkerSimulator::new(1, 42);
        sim.network.min_delay = 1;
        sim.network.max_delay = 1;

        sim.run(5);

        // Manually inject a StartPod command
        sim.network.send_to_agent(
            0,
            ControlMessage::StartPod(StartPodCmd {
                pod_id: 99,
                deployment_id: 100,
                image: "nginx:latest".into(),
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
            }),
            sim.current_tick,
        );

        sim.run(10);

        assert_eq!(sim.checker.safety_violations, 0);
        let pods = sim.workers[0].tracked_pods();
        assert!(pods.contains_key(&99));
        assert_eq!(pods[&99].state, TrackedPodState::Running);
    }

    fn start_cmd(pod_id: u64, deployment_id: u64) -> ControlMessage {
        ControlMessage::StartPod(StartPodCmd {
            pod_id,
            deployment_id,
            image: "docker.io/library/nginx:1.27-alpine".into(),
            entrypoint: String::new(),
            port: 8080,
            gpu_count: 0,
            gpu_type: GpuType::None,
            cpu_millicores: 10,
            memory_megabytes: 16,
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

    fn stop_cmd(pod_id: u64) -> ControlMessage {
        ControlMessage::StopPod(StopPodCmd {
            pod_id,
            grace_period_ms: 0,
        })
    }

    fn running_status_count(sim: &WorkerSimulator, min_pod_id: u64, max_pod_id: u64) -> usize {
        sim.control_plane
            .received_messages()
            .iter()
            .filter(|(_, agent_id, msg)| match msg {
                WorkerMessage::PodStatusEvent(event) => {
                    *agent_id == 0
                        && event.pod_id >= min_pod_id
                        && event.pod_id <= max_pod_id
                        && matches!(event.status, PodStatusReport::Running)
                }
                _ => false,
            })
            .count()
    }

    #[test]
    fn post_churn_burst_50x1_reaches_running_with_stopped_pods_retained() {
        let mut sim = WorkerSimulator::new(1, 0x50_50);
        sim.network.min_delay = 1;
        sim.network.max_delay = 1;

        sim.run(5);

        for i in 0..50 {
            sim.network
                .send_to_agent(0, start_cmd(1 + i, 10_000), sim.current_tick);
        }
        sim.run(10);

        for i in 0..50 {
            assert_eq!(
                sim.workers[0].tracked_pods()[&(1 + i)].state,
                TrackedPodState::Running,
                "single-deployment scale-out pod {} must run",
                1 + i
            );
        }
        assert_eq!(running_status_count(&sim, 1, 50), 50);

        for i in 0..50 {
            sim.network
                .send_to_agent(0, stop_cmd(1 + i), sim.current_tick);
        }
        sim.run(10);

        for i in 0..50 {
            assert!(
                matches!(
                    sim.workers[0].tracked_pods()[&(1 + i)].state,
                    TrackedPodState::Stopped { exit_code: 0 }
                ),
                "old pod {} must stop",
                1 + i
            );
        }

        for i in 0..50 {
            sim.network
                .send_to_agent(0, start_cmd(1_001 + i, 20_000 + i), sim.current_tick);
        }
        sim.run(10);

        for i in 0..50 {
            assert_eq!(
                sim.workers[0].tracked_pods()[&(1_001 + i)].state,
                TrackedPodState::Running,
                "post-churn 50x1 pod {} must run",
                1_001 + i
            );
        }
        assert_eq!(running_status_count(&sim, 1_001, 1_050), 50);
        assert_eq!(sim.workers[0].tracked_pods().len(), 100);
        assert_eq!(sim.checker.safety_violations, 0);
    }

    #[test]
    fn connection_loss_reregisters_and_running_pod_still_serves_run() {
        let mut sim = WorkerSimulator::new(1, 42);
        sim.network.min_delay = 1;
        sim.network.max_delay = 1;

        sim.run(5);
        sim.network.send_to_agent(
            0,
            ControlMessage::StartPod(StartPodCmd {
                pod_id: 77,
                deployment_id: 700,
                image: "echo:latest".into(),
                entrypoint: String::new(),
                port: 8080,
                gpu_count: 0,
                gpu_type: GpuType::None,
                cpu_millicores: 500,
                memory_megabytes: 512,
                juicefs_path: String::new(),
                liveness_path: String::new(),
                readiness_path: String::new(),
                env_vars: vec![],
                image_pull_registry: String::new(),
                image_pull_username: String::new(),
                image_pull_password: String::new(),
                image_pull_password_is_secret: false,
            }),
            sim.current_tick,
        );
        sim.run(10);
        assert_eq!(
            sim.workers[0].tracked_pods()[&77].state,
            TrackedPodState::Running
        );

        sim.workers[0].on_connection_lost();
        sim.run(2);

        let register_count = sim
            .control_plane
            .received_messages()
            .iter()
            .filter(|(_, agent_id, msg)| {
                *agent_id == 0 && matches!(msg, WorkerMessage::NodeRegister(_))
            })
            .count();
        assert!(
            register_count >= 2,
            "worker must re-register after reconnect"
        );

        sim.network.send_to_agent(
            0,
            ControlMessage::RunRequest(RunRequestCmd {
                request_id: 99,
                deployment_id: 700,
                payload: b"after-reconnect".to_vec(),
            }),
            sim.current_tick,
        );
        sim.run(3);

        let response = sim
            .control_plane
            .received_messages()
            .iter()
            .rev()
            .find_map(|(_, agent_id, msg)| match (agent_id, msg) {
                (0, WorkerMessage::RunResponse(resp)) if resp.request_id == 99 => Some(resp),
                _ => None,
            })
            .expect("expected run response after reconnect");
        assert_eq!(response.status, 0);
        assert_eq!(response.payload, b"after-reconnect");
    }

    #[test]
    fn bounded_lifecycle_concurrency_preserves_resource_invariants() {
        let mut sim = WorkerSimulator::new_with_lifecycle_concurrency(1, 0xC0DE, 4);
        sim.network.min_delay = 1;
        sim.network.max_delay = 1;
        sim.run(5);

        for i in 0..8 {
            sim.network.send_to_agent(
                0,
                ControlMessage::StartPod(StartPodCmd {
                    pod_id: 10_000 + i,
                    deployment_id: 30_000 + i,
                    image: "docker.io/library/nginx:1.27-alpine".into(),
                    entrypoint: String::new(),
                    port: 8080,
                    gpu_count: 0,
                    gpu_type: GpuType::None,
                    cpu_millicores: 4000,
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
                sim.current_tick,
            );
        }
        sim.run(6);

        assert_eq!(sim.checker.safety_violations, 0);
        assert_eq!(sim.workers[0].cpu_allocated_millicores(), 32_000);
        assert_eq!(sim.workers[0].memory_allocated_megabytes(), 32_768);
        for i in 0..8 {
            assert_eq!(
                sim.workers[0].tracked_pods()[&(10_000 + i)].state,
                TrackedPodState::Running
            );
        }

        sim.network.send_to_agent(
            0,
            ControlMessage::StartPod(StartPodCmd {
                pod_id: 20_000,
                deployment_id: 40_000,
                image: "docker.io/library/nginx:1.27-alpine".into(),
                entrypoint: String::new(),
                port: 8080,
                gpu_count: 0,
                gpu_type: GpuType::None,
                cpu_millicores: 1,
                memory_megabytes: 1,
                juicefs_path: String::new(),
                liveness_path: String::new(),
                readiness_path: String::new(),
                env_vars: vec![],
                image_pull_registry: String::new(),
                image_pull_username: String::new(),
                image_pull_password: String::new(),
                image_pull_password_is_secret: false,
            }),
            sim.current_tick,
        );
        sim.run(3);

        assert_eq!(sim.checker.safety_violations, 0);
        assert!(!sim.workers[0].tracked_pods().contains_key(&20_000));
        assert_eq!(sim.workers[0].cpu_allocated_millicores(), 32_000);
    }

    #[test]
    fn deterministic_across_runs() {
        let mut sim1 = WorkerSimulator::new(2, 777);
        sim1.control_plane.generate_workload(2, 5, 100);
        sim1.run(200);

        let mut sim2 = WorkerSimulator::new(2, 777);
        sim2.control_plane.generate_workload(2, 5, 100);
        sim2.run(200);

        // Same violations (should be zero)
        assert_eq!(
            sim1.checker.safety_violations,
            sim2.checker.safety_violations
        );

        // Same message count
        assert_eq!(
            sim1.control_plane.received_messages().len(),
            sim2.control_plane.received_messages().len(),
        );
    }
}
