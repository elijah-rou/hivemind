use crate::prng::{Prng, Ratio};
use crate::worker::{TrackedPodState, LIFECYCLE_FIRST_RETRY_DELAY_TICKS};

use super::runtime::FaultConfig;
use super::simulator::WorkerSimulator;

pub const LIVENESS_RETRY_GRACE_TICKS: u64 = if LIFECYCLE_FIRST_RETRY_DELAY_TICKS + 100 > 200 {
    LIFECYCLE_FIRST_RETRY_DELAY_TICKS + 100
} else {
    200
};

#[derive(Debug, Clone)]
pub struct SimConfig {
    pub seed: u64,
    pub agent_count: usize,
    pub safety_ticks: u64,
    pub liveness_ticks: u64,
    pub pod_count: u32,

    // Fault injection (ratio-based for fine-grained control)
    pub partition_probability: Ratio,
    pub heal_probability: Ratio,
    pub pause_probability: Ratio,
    pub image_pull_failure_rate: Ratio,
    pub container_crash_rate: Ratio,
    pub gpu_failure_rate: Ratio,

    // Stability (min ticks before fault state changes)
    pub partition_stability: u64,
    pub heal_stability: u64,
    pub pause_stability: u64,

    // Network faults
    pub drop_rate: Ratio,
    pub replay_rate: Ratio,
    pub path_max_capacity: usize,
}

impl Default for SimConfig {
    fn default() -> Self {
        Self {
            seed: 42,
            agent_count: 3,
            safety_ticks: 500,
            liveness_ticks: LIVENESS_RETRY_GRACE_TICKS,
            pod_count: 20,
            partition_probability: Ratio::new(2, 100),
            heal_probability: Ratio::new(5, 100),
            pause_probability: Ratio::new(1, 100),
            image_pull_failure_rate: Ratio::new(5, 100),
            container_crash_rate: Ratio::new(1, 100),
            gpu_failure_rate: Ratio::new(1, 100),
            partition_stability: 15,
            heal_stability: 10,
            pause_stability: 10,
            drop_rate: Ratio::zero(),
            replay_rate: Ratio::zero(),
            path_max_capacity: 0,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Passed,
    SafetyViolation,
    LivenessFailure,
}

#[derive(Debug)]
pub struct SimResult {
    pub seed: u64,
    pub phase1_ticks: u64,
    pub phase2_ticks: u64,
    pub safety_violations: u64,
    pub outcome: Outcome,
    pub convergence_ticks: u64,
    pub messages_sent: u64,
}

pub fn run(config: &SimConfig) -> SimResult {
    let mut fault_prng = Prng::init(config.seed.wrapping_add(0xFA17));

    let mut sim = WorkerSimulator::new(config.agent_count, config.seed);

    // Configure network
    sim.network.drop_rate_percent = 0; // legacy, unused with ratio
    sim.network.replay_percent = 0;
    sim.network.path_max_capacity = config.path_max_capacity;
    sim.network.partition_stability = config.partition_stability;
    sim.network.heal_stability = config.heal_stability;

    let fault_config = FaultConfig {
        image_pull_failure_rate: config.image_pull_failure_rate,
        container_crash_rate: config.container_crash_rate,
        gpu_failure_rate: config.gpu_failure_rate,
        create_failure_rate: Ratio::zero(),
    };
    for i in 0..config.agent_count {
        sim.set_runtime_faults(i, fault_config.clone());
    }

    sim.control_plane
        .generate_workload(config.agent_count, config.pod_count, config.safety_ticks);

    // Pause tracking
    let mut pause_until = vec![0u64; config.agent_count];

    // -- Phase 1: Safety --

    let mut phase1_ticks: u64 = 0;

    for tick in 0..config.safety_ticks {
        // Partition
        if fault_prng.chance_ratio(config.partition_probability) {
            let target = fault_prng.bounded(config.agent_count as u64) as usize;
            sim.partition_agent(target);
        }

        // Heal
        if fault_prng.chance_ratio(config.heal_probability) {
            sim.heal_all();
        }

        // Pause
        if fault_prng.chance_ratio(config.pause_probability) {
            let target = fault_prng.bounded(config.agent_count as u64) as usize;
            if pause_until[target] <= tick {
                let duration = config.pause_stability + fault_prng.bounded(30);
                pause_until[target] = tick + duration;
                sim.partition_agent(target); // no messages while paused
            }
        }

        // Resume paused workers
        for i in 0..config.agent_count {
            if pause_until[i] > 0 && tick >= pause_until[i] {
                pause_until[i] = 0;
                sim.network.heal_one(i, tick);
            }
        }

        sim.tick();
        phase1_ticks = tick + 1;

        let msgs = sim.network.stats.control_sent + sim.network.stats.worker_sent;
        if sim.checker.safety_violations > 0 {
            return SimResult {
                seed: config.seed,
                phase1_ticks,
                phase2_ticks: 0,
                safety_violations: sim.checker.safety_violations,
                outcome: Outcome::SafetyViolation,
                convergence_ticks: 0,
                messages_sent: msgs,
            };
        }
    }

    // -- Phase 2: Liveness --

    sim.heal_all();
    for i in 0..config.agent_count {
        sim.set_runtime_faults(i, FaultConfig::default());
    }

    let mut phase2_ticks: u64 = 0;

    for tick in 0..config.liveness_ticks {
        sim.tick();
        phase2_ticks = tick + 1;

        let msgs = sim.network.stats.control_sent + sim.network.stats.worker_sent;
        if sim.checker.safety_violations > 0 {
            return SimResult {
                seed: config.seed,
                phase1_ticks,
                phase2_ticks,
                safety_violations: sim.checker.safety_violations,
                outcome: Outcome::SafetyViolation,
                convergence_ticks: 0,
                messages_sent: msgs,
            };
        }

        if check_convergence(&sim) {
            return SimResult {
                seed: config.seed,
                phase1_ticks,
                phase2_ticks,
                safety_violations: 0,
                outcome: Outcome::Passed,
                convergence_ticks: phase2_ticks,
                messages_sent: msgs,
            };
        }
    }

    let msgs = sim.network.stats.control_sent + sim.network.stats.worker_sent;
    SimResult {
        seed: config.seed,
        phase1_ticks,
        phase2_ticks,
        safety_violations: sim.checker.safety_violations,
        outcome: Outcome::LivenessFailure,
        convergence_ticks: 0,
        messages_sent: msgs,
    }
}

fn check_convergence(sim: &WorkerSimulator) -> bool {
    for wk in &sim.workers {
        for pod in wk.tracked_pods().values() {
            match pod.state {
                TrackedPodState::Running
                | TrackedPodState::Stopped { .. }
                | TrackedPodState::Failed { .. } => {}
                _ => return false,
            }
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sim_default_seed_passes() {
        let result = run(&SimConfig::default());
        assert_eq!(
            result.outcome,
            Outcome::Passed,
            "seed {}: violations={}, phase1={}, phase2={}",
            result.seed,
            result.safety_violations,
            result.phase1_ticks,
            result.phase2_ticks,
        );
    }

    #[test]
    fn sim_no_faults_passes() {
        let config = SimConfig {
            seed: 123,
            partition_probability: Ratio::zero(),
            heal_probability: Ratio::zero(),
            image_pull_failure_rate: Ratio::zero(),
            container_crash_rate: Ratio::zero(),
            gpu_failure_rate: Ratio::zero(),
            ..Default::default()
        };
        let result = run(&config);
        assert_eq!(result.outcome, Outcome::Passed);
        assert_eq!(result.safety_violations, 0);
    }

    #[test]
    fn sim_heavy_faults_no_safety_violations() {
        let config = SimConfig {
            seed: 456,
            partition_probability: Ratio::new(10, 100),
            heal_probability: Ratio::new(15, 100),
            image_pull_failure_rate: Ratio::new(20, 100),
            container_crash_rate: Ratio::new(5, 100),
            gpu_failure_rate: Ratio::new(5, 100),
            liveness_ticks: LIVENESS_RETRY_GRACE_TICKS,
            ..Default::default()
        };
        let result = run(&config);
        assert_eq!(
            result.safety_violations, 0,
            "safety violations with seed {}: {:?}",
            config.seed, result
        );
    }

    #[test]
    fn fuzz_regression_seeds_78_and_81_converge_with_retry_grace() {
        let seed_78 = run(&SimConfig {
            seed: 78,
            ..Default::default()
        });
        assert_eq!(seed_78.outcome, Outcome::Passed, "seed 78: {seed_78:?}");
        assert!(
            seed_78.convergence_ticks <= LIVENESS_RETRY_GRACE_TICKS,
            "seed 78 convergence exceeded retry grace: {seed_78:?}"
        );

        let seed_81 = run(&SimConfig {
            seed: 81,
            heal_probability: Ratio::new(4, 100),
            ..Default::default()
        });
        assert_eq!(seed_81.outcome, Outcome::Passed, "seed 81: {seed_81:?}");
        assert!(
            seed_81.convergence_ticks <= LIVENESS_RETRY_GRACE_TICKS,
            "seed 81 convergence exceeded retry grace: {seed_81:?}"
        );
    }

    #[test]
    fn sim_deterministic() {
        let config = SimConfig {
            seed: 789,
            ..Default::default()
        };
        let r1 = run(&config);
        let r2 = run(&config);

        assert_eq!(r1.outcome, r2.outcome);
        assert_eq!(r1.phase1_ticks, r2.phase1_ticks);
        assert_eq!(r1.phase2_ticks, r2.phase2_ticks);
        assert_eq!(r1.safety_violations, r2.safety_violations);
    }

    #[test]
    fn sim_concurrent_runs_match_sequential_runs() {
        let configs: Vec<SimConfig> = (0..32)
            .map(|seed| SimConfig {
                seed,
                safety_ticks: 200,
                liveness_ticks: LIVENESS_RETRY_GRACE_TICKS,
                pod_count: 10,
                image_pull_failure_rate: Ratio::new(5, 100),
                container_crash_rate: Ratio::new(2, 100),
                gpu_failure_rate: Ratio::new(2, 100),
                ..Default::default()
            })
            .collect();

        let sequential: Vec<SimResult> = configs.iter().map(run).collect();
        let concurrent = std::thread::scope(|scope| {
            let mut handles = Vec::with_capacity(configs.len());
            for config in &configs {
                handles.push(scope.spawn(move || run(config)));
            }
            handles
                .into_iter()
                .map(|handle| handle.join().expect("sim runner thread panicked"))
                .collect::<Vec<SimResult>>()
        });

        for (expected, actual) in sequential.iter().zip(concurrent.iter()) {
            assert_eq!(expected.seed, actual.seed);
            assert_eq!(expected.outcome, actual.outcome, "seed {}", expected.seed);
            assert_eq!(
                expected.phase1_ticks, actual.phase1_ticks,
                "seed {}",
                expected.seed
            );
            assert_eq!(
                expected.phase2_ticks, actual.phase2_ticks,
                "seed {}",
                expected.seed
            );
            assert_eq!(
                expected.safety_violations, actual.safety_violations,
                "seed {}",
                expected.seed
            );
            assert_eq!(
                expected.messages_sent, actual.messages_sent,
                "seed {}",
                expected.seed
            );
        }
    }

    #[test]
    fn sim_multi_seed_sweep() {
        for seed in 0..50 {
            let config = SimConfig {
                seed,
                safety_ticks: 200,
                liveness_ticks: LIVENESS_RETRY_GRACE_TICKS,
                pod_count: 10,
                ..Default::default()
            };
            let result = run(&config);
            assert_eq!(
                result.safety_violations, 0,
                "safety violation at seed {seed}: {:?}",
                result
            );
        }
    }
}
