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

        // A. Deliver worker messages enqueued on an earlier tick.
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
                self.network.send_from_agent(i, message, self.current_tick);
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
        assert!(agent_id < self.agent_count);
        self.network.partition_agent(agent_id, self.current_tick);
    }

    pub fn lose_agent_session(&mut self, agent_id: usize) {
        assert!(agent_id < self.agent_count);
        self.network.discard_session_queues(agent_id);
        self.workers[agent_id].on_connection_lost();
    }

    pub fn retry_agent_registration(&mut self, agent_id: usize) {
        assert!(agent_id < self.agent_count);
        self.workers[agent_id].on_connection_lost();
    }

    pub fn heal_all(&mut self) {
        self.network.heal_all(self.current_tick);
    }

    pub fn force_heal_all(&mut self) {
        self.network.force_heal_all(self.current_tick);
    }

    pub fn set_runtime_faults(&mut self, agent_id: usize, config: FaultConfig) {
        self.sim_runtimes[agent_id].fault_config = config;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::*;
    use crate::prng::Ratio;
    use crate::runtime::{PodStatus, Runtime};
    use crate::sim::runtime::ProbeOutcome;
    use crate::types::GpuType;
    use crate::worker::{TrackedPodState, STOP_RETRY_DELAY_TICKS};

    fn received_count(sim: &WorkerSimulator, predicate: impl Fn(&WorkerMessage) -> bool) -> usize {
        sim.control_plane
            .received_messages()
            .iter()
            .filter(|(_, agent_id, message)| *agent_id == 0 && predicate(message))
            .count()
    }

    fn received_pod_statuses(sim: &WorkerSimulator, pod_id: u64) -> Vec<PodStatusReport> {
        sim.control_plane
            .received_messages()
            .iter()
            .filter_map(|(_, agent_id, message)| match message {
                WorkerMessage::PodStatusEvent(event)
                    if *agent_id == 0 && event.pod_id == pod_id =>
                {
                    Some(event.status.clone())
                }
                _ => None,
            })
            .collect()
    }

    fn liveness_probe_sim(outcomes: &[ProbeOutcome]) -> WorkerSimulator {
        let mut sim = WorkerSimulator::new(1, 0xB3_01);
        sim.network.min_delay = 1;
        sim.network.max_delay = 1;
        sim.control_plane.schedule_command(
            1,
            0,
            ControlMessage::StartPod(StartPodCmd {
                pod_id: 1,
                deployment_id: 100,
                image: "sim-probe:1".into(),
                entrypoint: String::new(),
                port: 8080,
                gpu_count: 8,
                gpu_type: GpuType::H100Sxm,
                cpu_millicores: 500,
                memory_megabytes: 512,
                juicefs_path: String::new(),
                liveness_path: "/health".into(),
                readiness_path: String::new(),
                env_vars: vec![],
                image_pull_registry: String::new(),
                image_pull_username: String::new(),
                image_pull_password: String::new(),
                image_pull_password_is_secret: false,
            }),
        );
        sim.control_plane.schedule_command(
            30_023,
            0,
            ControlMessage::StartPod(StartPodCmd {
                pod_id: 2,
                deployment_id: 200,
                image: "sim-replacement:1".into(),
                entrypoint: String::new(),
                port: 8080,
                gpu_count: 1,
                gpu_type: GpuType::H100Sxm,
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
        );
        sim.sim_runtimes[0].script_probe_outcomes(1, outcomes);
        sim.run(20);
        assert_eq!(
            sim.workers[0].tracked_pods()[&1].state,
            TrackedPodState::Running
        );
        sim
    }

    fn advance_to_next_probe(sim: &mut WorkerSimulator) {
        sim.current_tick = sim.current_tick.saturating_add(10_000);
        sim.tick();
    }

    #[test]
    fn liveness_probe_two_failures_then_success_resets_counter() {
        let mut sim = liveness_probe_sim(&[
            ProbeOutcome::Unhealthy,
            ProbeOutcome::Error,
            ProbeOutcome::Healthy,
        ]);

        advance_to_next_probe(&mut sim);
        assert_eq!(sim.workers[0].tracked_pods()[&1].consecutive_failures, 1);
        advance_to_next_probe(&mut sim);
        assert_eq!(sim.workers[0].tracked_pods()[&1].consecutive_failures, 2);
        advance_to_next_probe(&mut sim);
        assert_eq!(sim.workers[0].tracked_pods()[&1].consecutive_failures, 0);
        assert_eq!(
            sim.workers[0].tracked_pods()[&1].state,
            TrackedPodState::Running
        );
    }

    #[test]
    fn liveness_probe_three_failures_transition_pod_to_failed() {
        let mut sim = liveness_probe_sim(&[
            ProbeOutcome::Unhealthy,
            ProbeOutcome::Error,
            ProbeOutcome::Unhealthy,
        ]);

        advance_to_next_probe(&mut sim);
        advance_to_next_probe(&mut sim);
        sim.set_runtime_faults(
            0,
            FaultConfig {
                stop_failure_rate: Ratio::new(1, 1),
                ..FaultConfig::default()
            },
        );
        advance_to_next_probe(&mut sim);

        assert_eq!(
            sim.workers[0].tracked_pods()[&1].state,
            TrackedPodState::Stopping,
            "failed probe must retain ownership until runtime termination is verified"
        );
        assert_eq!(sim.workers[0].gpu_allocated(), 8);
        assert_eq!(sim.workers[0].cpu_allocated_millicores(), 500);
        assert_eq!(sim.workers[0].memory_allocated_megabytes(), 512);
        let handle = sim.workers[0].tracked_pods()[&1]
            .handle
            .as_ref()
            .unwrap()
            .clone();
        assert_eq!(
            sim.sim_runtimes[0].pod_status(&handle).unwrap(),
            PodStatus::Running
        );

        sim.tick();
        assert_eq!(
            sim.workers[0].tracked_pods()[&1].state,
            TrackedPodState::Stopping,
            "failed stop must retain the live runtime"
        );
        assert_eq!(
            sim.sim_runtimes[0].pod_status(&handle).unwrap(),
            PodStatus::Running
        );
        assert_eq!(sim.workers[0].gpu_allocated(), 8);

        sim.tick();
        assert!(received_pod_statuses(&sim, 2).iter().any(|status| matches!(
            status,
            PodStatusReport::Failed { reason } if reason == "insufficient GPU capacity"
        )));

        sim.current_tick = sim.current_tick.saturating_add(STOP_RETRY_DELAY_TICKS);
        sim.tick();
        assert_eq!(
            sim.workers[0].tracked_pods()[&1].state,
            TrackedPodState::Failed {
                reason: "liveness probe failed".into()
            }
        );
        assert_eq!(sim.workers[0].gpu_allocated(), 0);
        assert_eq!(sim.workers[0].cpu_allocated_millicores(), 0);
        assert_eq!(sim.workers[0].memory_allocated_megabytes(), 0);
        assert!(sim.sim_runtimes[0].pod_status(&handle).is_err());
    }

    #[test]
    fn outbound_partition_before_registration_delays_delivery_until_healing() {
        let mut sim = WorkerSimulator::new(1, 0xB1_01);
        sim.network.min_delay = 1;
        sim.network.max_delay = 1;
        sim.partition_agent(0);

        sim.tick();
        assert_eq!(
            received_count(&sim, |message| matches!(
                message,
                WorkerMessage::NodeRegister(_)
            )),
            0,
            "partitioned registration must not bypass the simulated network"
        );

        sim.heal_all();
        sim.run(2);
        let registrations: Vec<_> = sim
            .control_plane
            .received_messages()
            .iter()
            .filter_map(|(_, agent_id, message)| match message {
                WorkerMessage::NodeRegister(register) if *agent_id == 0 => Some(register),
                _ => None,
            })
            .collect();
        assert_eq!(registrations.len(), 1);
        assert_eq!(registrations[0].node_name, "sim-node-0");
    }

    #[test]
    fn outbound_partition_before_heartbeat_delays_delivery_until_healing() {
        let mut sim = WorkerSimulator::new(1, 0xB1_02);
        sim.network.min_delay = 1;
        sim.network.max_delay = 1;
        sim.run(101);
        let before = received_count(&sim, |message| {
            matches!(message, WorkerMessage::NodeHeartbeat(_))
        });

        sim.partition_agent(0);
        assert!(
            sim.workers[0].is_registered(),
            "a delayed network partition must not imply session loss"
        );
        sim.tick();
        assert_eq!(
            received_count(&sim, |message| matches!(
                message,
                WorkerMessage::NodeHeartbeat(_)
            )),
            before,
            "partitioned heartbeat must not bypass the simulated network"
        );

        sim.heal_all();
        sim.run(2);
        let heartbeats: Vec<_> = sim
            .control_plane
            .received_messages()
            .iter()
            .filter_map(|(_, agent_id, message)| match message {
                WorkerMessage::NodeHeartbeat(heartbeat) if *agent_id == 0 => Some(heartbeat),
                _ => None,
            })
            .collect();
        assert_eq!(heartbeats.len(), before + 1);
        assert_eq!(
            heartbeats.last().expect("heartbeat must be delivered").tick,
            101
        );
    }

    #[test]
    fn outbound_partition_before_pod_status_delays_delivery_until_healing() {
        let mut sim = WorkerSimulator::new(1, 0xB1_03);
        sim.network.min_delay = 1;
        sim.network.max_delay = 1;
        sim.run(2);
        let before = received_count(&sim, |message| {
            matches!(message, WorkerMessage::PodStatusEvent(_))
        });
        sim.sim_ios[0].push_inbound(start_cmd(700, 7_000));

        sim.partition_agent(0);
        sim.tick();
        assert_eq!(
            received_count(&sim, |message| matches!(
                message,
                WorkerMessage::PodStatusEvent(_)
            )),
            before,
            "partitioned pod status must not bypass the simulated network"
        );

        sim.heal_all();
        sim.run(3);
        assert_eq!(
            received_pod_statuses(&sim, 700),
            vec![
                PodStatusReport::ImagePulling,
                PodStatusReport::Creating,
                PodStatusReport::Running,
            ],
            "healing must deliver the exact pod status identity and sequence once"
        );
        assert_eq!(
            received_count(&sim, |message| matches!(
                message,
                WorkerMessage::PodStatusEvent(_)
            )),
            before + 3
        );
    }

    #[test]
    fn session_loss_discards_old_epoch_and_reregisters_before_new_traffic() {
        let mut sim = WorkerSimulator::new(1, 0xB1_05);
        sim.network.min_delay = 1;
        sim.network.max_delay = 1;
        sim.run(2);
        let received_before_loss = sim.control_plane.received_messages().len();

        sim.network.send_from_agent(
            0,
            WorkerMessage::NodeHeartbeat(NodeHeartbeatMsg {
                tick: 20,
                active_pods: 1,
                gpu_free: 7,
            }),
            sim.current_tick,
        );
        sim.network.send_from_agent(
            0,
            WorkerMessage::PodStatusEvent(PodStatusEventMsg {
                pod_id: 70,
                status: PodStatusReport::Running,
            }),
            sim.current_tick,
        );
        sim.network.send_from_agent(
            0,
            WorkerMessage::RunResponse(RunResponseMsg {
                request_id: 80,
                status: 0,
                payload: b"old-session".to_vec(),
            }),
            sim.current_tick,
        );
        sim.lose_agent_session(0);
        assert!(!sim.workers[0].is_registered());
        sim.run(2);

        sim.network.send_from_agent(
            0,
            WorkerMessage::NodeHeartbeat(NodeHeartbeatMsg {
                tick: 40,
                active_pods: 0,
                gpu_free: 8,
            }),
            sim.current_tick,
        );
        sim.network.send_from_agent(
            0,
            WorkerMessage::PodStatusEvent(PodStatusEventMsg {
                pod_id: 71,
                status: PodStatusReport::Stopped { exit_code: 0 },
            }),
            sim.current_tick,
        );
        sim.network.send_from_agent(
            0,
            WorkerMessage::RunResponse(RunResponseMsg {
                request_id: 81,
                status: 0,
                payload: b"new-session".to_vec(),
            }),
            sim.current_tick,
        );
        sim.tick();

        let after_loss = &sim.control_plane.received_messages()[received_before_loss..];
        assert_eq!(after_loss.len(), 4);
        assert!(matches!(
            after_loss[0],
            (_, 0, WorkerMessage::NodeRegister(_))
        ));
        assert!(matches!(
            &after_loss[1].2,
            WorkerMessage::NodeHeartbeat(heartbeat) if heartbeat.tick == 40
        ));
        assert!(matches!(
            &after_loss[2].2,
            WorkerMessage::PodStatusEvent(event)
                if event.pod_id == 71
                    && event.status == PodStatusReport::Stopped { exit_code: 0 }
        ));
        assert!(matches!(
            &after_loss[3].2,
            WorkerMessage::RunResponse(response)
                if response.request_id == 81 && response.payload == b"new-session"
        ));
    }

    #[test]
    fn outbound_partition_before_run_response_delays_delivery_until_healing() {
        let mut sim = WorkerSimulator::new(1, 0xB1_04);
        sim.network.min_delay = 1;
        sim.network.max_delay = 1;
        sim.sim_ios[0].push_inbound(start_cmd(800, 8_000));
        sim.run(3);
        assert_eq!(
            sim.workers[0].tracked_pods()[&800].state,
            TrackedPodState::Running
        );
        let before = received_count(&sim, |message| {
            matches!(message, WorkerMessage::RunResponse(_))
        });
        sim.sim_ios[0].push_inbound(ControlMessage::RunRequest(RunRequestCmd {
            request_id: 81,
            deployment_id: 8_000,
            payload: b"partitioned-response".to_vec(),
        }));

        sim.partition_agent(0);
        sim.tick();
        assert_eq!(
            received_count(&sim, |message| matches!(
                message,
                WorkerMessage::RunResponse(_)
            )),
            before,
            "partitioned run response must not bypass the simulated network"
        );

        sim.heal_all();
        sim.run(2);
        let responses: Vec<_> = sim
            .control_plane
            .received_messages()
            .iter()
            .filter_map(|(_, agent_id, message)| match message {
                WorkerMessage::RunResponse(response) if *agent_id == 0 => Some(response),
                _ => None,
            })
            .collect();
        assert_eq!(responses.len(), before + 1);
        let response = responses.last().expect("run response must be delivered");
        assert_eq!(response.request_id, 81);
        assert_eq!(response.status, 0);
        assert_eq!(response.payload, b"partitioned-response");
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
    fn stop_fault_retains_runtime_resources_and_denies_replacement_gpu() {
        let mut sim = WorkerSimulator::new(1, 0xB2_02);
        sim.network.min_delay = 1;
        sim.network.max_delay = 1;
        sim.set_runtime_faults(
            0,
            FaultConfig {
                stop_failure_rate: crate::prng::Ratio::new(1, 1),
                ..Default::default()
            },
        );
        let gpu_start = |pod_id, deployment_id| {
            ControlMessage::StartPod(StartPodCmd {
                pod_id,
                deployment_id,
                image: "gpu:latest".into(),
                entrypoint: String::new(),
                port: 8080,
                gpu_count: 8,
                gpu_type: GpuType::H100Sxm,
                cpu_millicores: 32_000,
                memory_megabytes: 65_536,
                juicefs_path: String::new(),
                liveness_path: String::new(),
                readiness_path: String::new(),
                env_vars: vec![],
                image_pull_registry: String::new(),
                image_pull_username: String::new(),
                image_pull_password: String::new(),
                image_pull_password_is_secret: false,
            })
        };

        sim.sim_ios[0].push_inbound(gpu_start(900, 9_000));
        sim.run(3);
        assert_eq!(
            sim.workers[0].tracked_pods()[&900].state,
            TrackedPodState::Running
        );
        assert_eq!(sim.workers[0].gpu_allocated(), 8);

        sim.sim_ios[0].push_inbound(stop_cmd(900));
        sim.tick();
        let handle = sim.workers[0].tracked_pods()[&900]
            .handle
            .as_ref()
            .expect("running pod has runtime handle");
        assert_eq!(
            sim.sim_runtimes[0].pod_status(handle).unwrap(),
            PodStatus::Running,
            "deterministic stop fault must leave the runtime running"
        );
        assert_eq!(
            sim.workers[0].tracked_pods()[&900].state,
            TrackedPodState::Stopping
        );
        assert_eq!(sim.workers[0].gpu_allocated(), 8);
        assert_eq!(sim.workers[0].cpu_allocated_millicores(), 32_000);
        assert_eq!(sim.workers[0].memory_allocated_megabytes(), 65_536);

        sim.sim_ios[0].push_inbound(gpu_start(901, 9_001));
        sim.tick();
        assert!(
            !sim.workers[0].tracked_pods().contains_key(&901),
            "replacement GPU admission must fail while the old runtime is unverified"
        );
        assert_eq!(sim.workers[0].gpu_allocated(), 8);
        assert!(!received_pod_statuses(&sim, 900)
            .iter()
            .any(|status| matches!(status, PodStatusReport::Stopped { .. })));

        sim.run(STOP_RETRY_DELAY_TICKS as u64);
        assert!(matches!(
            sim.workers[0].tracked_pods()[&900].state,
            TrackedPodState::Stopped { exit_code: 0 }
        ));
        assert_eq!(sim.workers[0].gpu_allocated(), 0);
        assert_eq!(sim.workers[0].cpu_allocated_millicores(), 0);
        assert_eq!(sim.workers[0].memory_allocated_megabytes(), 0);
        assert_eq!(sim.checker.safety_violations, 0);
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
