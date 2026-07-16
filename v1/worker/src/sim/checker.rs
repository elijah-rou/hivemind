use std::collections::HashMap;

use crate::worker::{TrackedPodState, Worker};

const HEARTBEAT_INTERVAL_TICKS: u64 = 100;
const HEARTBEAT_TOLERANCE_TICKS: u64 = 20;

pub struct WorkerChecker {
    pub safety_violations: u64,
    violations: Vec<String>,
    last_heartbeat: Vec<u64>,
    last_pod_states: Vec<HashMap<u64, TrackedPodState>>,
}

impl WorkerChecker {
    pub fn new(agent_count: usize) -> Self {
        Self {
            safety_violations: 0,
            violations: Vec::new(),
            last_heartbeat: vec![0; agent_count],
            last_pod_states: (0..agent_count).map(|_| HashMap::new()).collect(),
        }
    }

    pub fn check(&mut self, tick: u64, wk_id: usize, wk: &Worker, is_partitioned: bool) {
        self.check_gpu_accounting(tick, wk_id, wk);
        self.check_cpu_memory_accounting(tick, wk_id, wk);
        self.check_pod_transitions(tick, wk_id, wk);

        if !is_partitioned {
            self.check_heartbeat_liveness(tick, wk_id, wk);
        }
    }

    fn check_gpu_accounting(&mut self, tick: u64, wk_id: usize, wk: &Worker) {
        if wk.gpu_allocated() > wk.gpu_total {
            self.record_violation(format!(
                "tick {tick}: worker {wk_id}: gpu_allocated ({}) > gpu_total ({})",
                wk.gpu_allocated(),
                wk.gpu_total
            ));
        }

        let sum: u8 = wk
            .tracked_pods()
            .values()
            .filter(|p| {
                !matches!(
                    p.state,
                    TrackedPodState::Stopped { .. } | TrackedPodState::Failed { .. }
                )
            })
            .map(|p| p.gpu_count)
            .sum();

        if sum != wk.gpu_allocated() {
            self.record_violation(format!(
                "tick {tick}: worker {wk_id}: pod GPU sum ({sum}) != gpu_allocated ({})",
                wk.gpu_allocated()
            ));
        }
    }

    fn check_cpu_memory_accounting(&mut self, tick: u64, wk_id: usize, wk: &Worker) {
        if wk.cpu_allocated_millicores() > wk.cpu_millicores {
            self.record_violation(format!(
                "tick {tick}: worker {wk_id}: cpu_allocated ({}) > cpu_total ({})",
                wk.cpu_allocated_millicores(),
                wk.cpu_millicores
            ));
        }
        if wk.memory_allocated_megabytes() > wk.memory_megabytes {
            self.record_violation(format!(
                "tick {tick}: worker {wk_id}: memory_allocated ({}) > memory_total ({})",
                wk.memory_allocated_megabytes(),
                wk.memory_megabytes
            ));
        }

        let cpu_sum: u32 = wk
            .tracked_pods()
            .values()
            .filter(|p| {
                !matches!(
                    p.state,
                    TrackedPodState::Stopped { .. } | TrackedPodState::Failed { .. }
                )
            })
            .map(|p| p.cpu_millicores)
            .sum();
        let memory_sum: u32 = wk
            .tracked_pods()
            .values()
            .filter(|p| {
                !matches!(
                    p.state,
                    TrackedPodState::Stopped { .. } | TrackedPodState::Failed { .. }
                )
            })
            .map(|p| p.memory_megabytes)
            .sum();

        if cpu_sum != wk.cpu_allocated_millicores() {
            self.record_violation(format!(
                "tick {tick}: worker {wk_id}: pod CPU sum ({cpu_sum}) != cpu_allocated ({})",
                wk.cpu_allocated_millicores()
            ));
        }
        if memory_sum != wk.memory_allocated_megabytes() {
            self.record_violation(format!(
                "tick {tick}: worker {wk_id}: pod memory sum ({memory_sum}) != memory_allocated ({})",
                wk.memory_allocated_megabytes()
            ));
        }
    }

    fn check_pod_transitions(&mut self, tick: u64, wk_id: usize, wk: &Worker) {
        let current = wk.tracked_pods();
        let prev = &self.last_pod_states[wk_id];

        // Collect violations first to avoid borrow conflict
        let mut violations = Vec::new();
        for (pod_id, pod) in current.iter() {
            if let Some(prev_state) = prev.get(pod_id) {
                if prev_state != &pod.state && !is_legal_transition(prev_state, &pod.state) {
                    violations.push(format!(
                        "tick {tick}: worker {wk_id}: pod {pod_id}: \
                         illegal transition {prev_state:?} -> {:?}",
                        pod.state
                    ));
                }
            }
        }

        for v in violations {
            self.record_violation(v);
        }

        self.last_pod_states[wk_id] = current
            .iter()
            .map(|(&id, p)| (id, p.state.clone()))
            .collect();
    }

    fn check_heartbeat_liveness(&mut self, tick: u64, wk_id: usize, wk: &Worker) {
        if !wk.is_registered() {
            return;
        }

        let last = wk.last_heartbeat_tick();
        if last > self.last_heartbeat[wk_id] {
            self.last_heartbeat[wk_id] = last;
        }

        if tick > HEARTBEAT_INTERVAL_TICKS + HEARTBEAT_TOLERANCE_TICKS {
            let gap = tick.saturating_sub(self.last_heartbeat[wk_id]);
            if gap > HEARTBEAT_INTERVAL_TICKS + HEARTBEAT_TOLERANCE_TICKS {
                self.record_violation(format!(
                    "tick {tick}: worker {wk_id}: heartbeat gap {gap} ticks exceeds threshold"
                ));
            }
        }
    }

    fn record_violation(&mut self, msg: String) {
        self.safety_violations += 1;
        eprintln!("SAFETY VIOLATION: {msg}");
        self.violations.push(msg);
    }

    pub fn violations(&self) -> &[String] {
        &self.violations
    }
}

fn is_legal_transition(from: &TrackedPodState, to: &TrackedPodState) -> bool {
    matches!(
        (from, to),
        (TrackedPodState::ImagePulling, TrackedPodState::Creating)
            | (
                TrackedPodState::ImagePulling,
                TrackedPodState::Failed { .. }
            )
            | (TrackedPodState::Creating, TrackedPodState::Starting)
            | (TrackedPodState::Creating, TrackedPodState::Failed { .. })
            | (TrackedPodState::Starting, TrackedPodState::Creating)
            | (TrackedPodState::Starting, TrackedPodState::Running)
            | (TrackedPodState::Starting, TrackedPodState::Stopped { .. })
            | (TrackedPodState::Starting, TrackedPodState::Failed { .. })
            | (TrackedPodState::Running, TrackedPodState::Stopping)
            | (TrackedPodState::Running, TrackedPodState::Stopped { .. })
            | (TrackedPodState::Running, TrackedPodState::Failed { .. })
            | (TrackedPodState::Stopping, TrackedPodState::Stopped { .. })
            | (TrackedPodState::Stopping, TrackedPodState::Failed { .. })
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_valid_transitions() {
        let pairs = [
            (TrackedPodState::ImagePulling, TrackedPodState::Creating),
            (
                TrackedPodState::ImagePulling,
                TrackedPodState::Failed { reason: "x".into() },
            ),
            (TrackedPodState::Creating, TrackedPodState::Starting),
            (TrackedPodState::Starting, TrackedPodState::Creating),
            (TrackedPodState::Starting, TrackedPodState::Running),
            (
                TrackedPodState::Starting,
                TrackedPodState::Stopped { exit_code: 0 },
            ),
            (TrackedPodState::Running, TrackedPodState::Stopping),
            (
                TrackedPodState::Running,
                TrackedPodState::Stopped { exit_code: 137 },
            ),
            (
                TrackedPodState::Stopping,
                TrackedPodState::Stopped { exit_code: 0 },
            ),
        ];

        for (from, to) in &pairs {
            assert!(
                is_legal_transition(from, to),
                "expected legal: {from:?} -> {to:?}"
            );
        }
    }

    #[test]
    fn illegal_transitions() {
        let pairs = [
            (TrackedPodState::Running, TrackedPodState::ImagePulling),
            (
                TrackedPodState::Stopped { exit_code: 0 },
                TrackedPodState::Running,
            ),
            (TrackedPodState::Creating, TrackedPodState::Running),
        ];

        for (from, to) in &pairs {
            assert!(
                !is_legal_transition(from, to),
                "expected illegal: {from:?} -> {to:?}"
            );
        }
    }
}
