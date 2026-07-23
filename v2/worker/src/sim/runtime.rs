use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;

use crate::prng::{Prng, Ratio};
use crate::protocol::MAX_RUN_RESPONSE_BODY;
use crate::runtime::{PodHandle, PodSpec, PodStatus, Runtime, RuntimeError};

const PROBE_SCRIPT_MAX: usize = 64;
const RUN_SCRIPT_MAX: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeOutcome {
    Healthy,
    Unhealthy,
    Error,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunOutcome {
    Echo,
    ExactResponseBoundary,
    ResponseBoundaryOverflow,
    ForwardingFailure,
    Timeout,
}

#[derive(Debug, Clone)]
pub struct FaultConfig {
    pub image_pull_failure_rate: Ratio,
    pub container_crash_rate: Ratio,
    pub gpu_failure_rate: Ratio,
    pub create_failure_rate: Ratio,
    pub stop_failure_rate: Ratio,
}

impl Default for FaultConfig {
    fn default() -> Self {
        Self {
            image_pull_failure_rate: Ratio::zero(),
            container_crash_rate: Ratio::zero(),
            gpu_failure_rate: Ratio::zero(),
            create_failure_rate: Ratio::zero(),
            stop_failure_rate: Ratio::zero(),
        }
    }
}

struct Inner {
    pods: HashMap<String, PodStatus>,
    pull_attempts: HashMap<String, u64>,
    create_attempts: HashMap<u64, u64>,
    start_attempts: HashMap<u64, u64>,
    stop_attempts: HashMap<u64, u64>,
    probe_outcomes: HashMap<u64, VecDeque<ProbeOutcome>>,
    run_outcomes: HashMap<u64, VecDeque<RunOutcome>>,
    crash_round: u64,
}

/// Simulated container runtime with configurable fault injection.
pub struct SimulatedRuntime {
    pub fault_config: FaultConfig,
    seed: u64,
    inner: Mutex<Inner>,
}

impl SimulatedRuntime {
    pub fn new(seed: u64, fault_config: FaultConfig) -> Self {
        Self {
            fault_config,
            seed,
            inner: Mutex::new(Inner {
                pods: HashMap::new(),
                pull_attempts: HashMap::new(),
                create_attempts: HashMap::new(),
                start_attempts: HashMap::new(),
                stop_attempts: HashMap::new(),
                probe_outcomes: HashMap::new(),
                run_outcomes: HashMap::new(),
                crash_round: 0,
            }),
        }
    }

    pub fn script_probe_outcomes(&self, pod_id: u64, outcomes: &[ProbeOutcome]) {
        assert!(!outcomes.is_empty(), "probe script must not be empty");
        assert!(
            outcomes.len() <= PROBE_SCRIPT_MAX,
            "probe script exceeds bounded capacity"
        );
        let previous = self
            .inner
            .lock()
            .unwrap()
            .probe_outcomes
            .insert(pod_id, outcomes.iter().copied().collect());
        assert!(
            previous.is_none(),
            "probe script may only be set once per pod"
        );
    }

    pub fn script_run_outcomes(&self, pod_id: u64, outcomes: &[RunOutcome]) {
        assert!(!outcomes.is_empty(), "run script must not be empty");
        assert!(
            outcomes.len() <= RUN_SCRIPT_MAX,
            "run script exceeds bounded capacity"
        );
        let previous = self
            .inner
            .lock()
            .unwrap()
            .run_outcomes
            .insert(pod_id, outcomes.iter().copied().collect());
        assert!(
            previous.is_none(),
            "run script may only be set once per pod"
        );
    }

    pub fn crash_pod(&self, pod_id: u64, exit_code: i32) {
        let mut inner = self.inner.lock().unwrap();
        let container_id = format!("sim-pod-{pod_id}");
        let status = inner
            .pods
            .get_mut(&container_id)
            .expect("scripted crash requires an existing pod");
        assert_eq!(*status, PodStatus::Running);
        *status = PodStatus::Stopped { exit_code };
    }

    /// Simulate spontaneous container crashes. Called by the simulator each tick.
    pub fn maybe_crash_pods(&self) {
        if self.fault_config.container_crash_rate.is_zero() {
            return;
        }

        let mut inner = self.inner.lock().unwrap();
        let crash_round = inner.crash_round;
        inner.crash_round = inner.crash_round.wrapping_add(1);

        let mut ids: Vec<String> = inner.pods.keys().cloned().collect();
        ids.sort();
        for id in ids {
            if let Some(status) = inner.pods.get(&id) {
                if *status == PodStatus::Running
                    && deterministic_chance(
                        self.seed,
                        0x4352_4153_4800_0000,
                        stable_hash(id.as_bytes()).wrapping_add(crash_round),
                        self.fault_config.container_crash_rate,
                    )
                {
                    inner.pods.insert(id, PodStatus::Stopped { exit_code: 137 });
                }
            }
        }
    }
}

fn next_attempt<K>(attempts: &mut HashMap<K, u64>, key: K) -> u64
where
    K: Eq + std::hash::Hash,
{
    let entry = attempts.entry(key).or_insert(0);
    let attempt = *entry;
    *entry = entry.wrapping_add(1);
    attempt
}

fn deterministic_chance(seed: u64, domain: u64, key: u64, ratio: Ratio) -> bool {
    if ratio.is_zero() {
        return false;
    }

    let mut prng = Prng::init(mix64(seed ^ domain ^ key));
    prng.chance_ratio(ratio)
}

fn stable_hash(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for byte in bytes {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

fn mix64(mut value: u64) -> u64 {
    value ^= value >> 30;
    value = value.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    value ^= value >> 27;
    value = value.wrapping_mul(0x94d0_49bb_1331_11eb);
    value ^= value >> 31;
    value
}

impl Runtime for SimulatedRuntime {
    fn pull_image(
        &self,
        image: &str,
        _auth: Option<&crate::runtime::ImagePullAuth>,
    ) -> Result<(), RuntimeError> {
        let mut inner = self.inner.lock().unwrap();
        let attempt = next_attempt(&mut inner.pull_attempts, image.to_string());
        drop(inner);

        if attempt == 0
            && deterministic_chance(
                self.seed,
                0x5055_4c4c_0000_0000,
                stable_hash(image.as_bytes()),
                self.fault_config.image_pull_failure_rate,
            )
        {
            return Err(RuntimeError::ImagePull("simulated pull failure".into()));
        }
        Ok(())
    }

    fn create_pod(&self, spec: &PodSpec) -> Result<PodHandle, RuntimeError> {
        let mut inner = self.inner.lock().unwrap();
        let attempt = next_attempt(&mut inner.create_attempts, spec.pod_id);
        drop(inner);

        if attempt == 0
            && deterministic_chance(
                self.seed,
                0x4352_4541_5445_0000,
                spec.pod_id,
                self.fault_config.create_failure_rate,
            )
        {
            return Err(RuntimeError::ContainerCreate(
                "simulated create failure".into(),
            ));
        }

        let mut inner = self.inner.lock().unwrap();
        let container_id = format!("sim-pod-{}", spec.pod_id);
        match inner.pods.get(&container_id) {
            Some(PodStatus::Running | PodStatus::Created) => {}
            _ => {
                inner.pods.insert(container_id.clone(), PodStatus::Created);
            }
        }

        Ok(PodHandle {
            pod_id: spec.pod_id,
            container_id,
        })
    }

    fn start_pod(&self, handle: &PodHandle) -> Result<(), RuntimeError> {
        let mut inner = self.inner.lock().unwrap();
        let attempt = next_attempt(&mut inner.start_attempts, handle.pod_id);
        drop(inner);

        if attempt == 0
            && deterministic_chance(
                self.seed,
                0x5354_4152_5400_0000,
                handle.pod_id,
                self.fault_config.gpu_failure_rate,
            )
        {
            return Err(RuntimeError::ContainerStart("simulated GPU failure".into()));
        }

        let mut inner = self.inner.lock().unwrap();
        if matches!(
            inner.pods.get(&handle.container_id),
            Some(PodStatus::Running)
        ) {
            return Ok(());
        }

        inner
            .pods
            .insert(handle.container_id.clone(), PodStatus::Running);
        Ok(())
    }

    fn forward_run(
        &self,
        handle: &PodHandle,
        _port: u16,
        payload: &[u8],
    ) -> Result<Vec<u8>, RuntimeError> {
        let mut inner = self.inner.lock().unwrap();
        match inner.pods.get(&handle.container_id) {
            Some(PodStatus::Running) => {}
            Some(_) => {
                return Err(RuntimeError::ContainerStart(
                    "simulated pod not running".into(),
                ));
            }
            None => return Err(RuntimeError::ContainerNotFound(handle.container_id.clone())),
        }
        let outcome = match inner.run_outcomes.get_mut(&handle.pod_id) {
            Some(script) => script
                .pop_front()
                .ok_or_else(|| RuntimeError::Internal("scripted run outcomes exhausted".into()))?,
            None => RunOutcome::Echo,
        };
        match outcome {
            RunOutcome::Echo => Ok(payload.to_vec()),
            RunOutcome::ExactResponseBoundary => Ok(vec![0x5a; MAX_RUN_RESPONSE_BODY]),
            RunOutcome::ResponseBoundaryOverflow => Ok(vec![0x6b; MAX_RUN_RESPONSE_BODY + 1]),
            RunOutcome::ForwardingFailure => Err(RuntimeError::Internal(
                "simulated forwarding failure".into(),
            )),
            RunOutcome::Timeout => Err(RuntimeError::Internal(
                "simulated forwarding timeout".into(),
            )),
        }
    }

    fn probe_pod(&self, handle: &PodHandle, _port: u16, _path: &str) -> Result<bool, RuntimeError> {
        let mut inner = self.inner.lock().unwrap();
        if !matches!(
            inner.pods.get(&handle.container_id),
            Some(PodStatus::Running)
        ) {
            return Err(RuntimeError::ContainerNotFound(handle.container_id.clone()));
        }
        let outcome = match inner.probe_outcomes.get_mut(&handle.pod_id) {
            Some(script) => script.pop_front().ok_or_else(|| {
                RuntimeError::Internal("scripted probe outcomes exhausted".into())
            })?,
            None => ProbeOutcome::Healthy,
        };
        match outcome {
            ProbeOutcome::Healthy => Ok(true),
            ProbeOutcome::Unhealthy => Ok(false),
            ProbeOutcome::Error => Err(RuntimeError::Internal("scripted probe error".into())),
        }
    }

    fn stop_pod(&self, handle: &PodHandle, _grace_period_ms: u64) -> Result<(), RuntimeError> {
        let mut inner = self.inner.lock().unwrap();
        let attempt = next_attempt(&mut inner.stop_attempts, handle.pod_id);
        if attempt == 0
            && deterministic_chance(
                self.seed,
                0x5354_4f50_0000_0000,
                handle.pod_id,
                self.fault_config.stop_failure_rate,
            )
        {
            return Err(RuntimeError::ContainerStop("simulated stop failure".into()));
        }
        let status = inner
            .pods
            .get_mut(&handle.container_id)
            .ok_or_else(|| RuntimeError::ContainerNotFound(handle.container_id.clone()))?;
        *status = PodStatus::Stopped { exit_code: 0 };
        Ok(())
    }

    fn pod_status(&self, handle: &PodHandle) -> Result<PodStatus, RuntimeError> {
        let inner = self.inner.lock().unwrap();
        inner
            .pods
            .get(&handle.container_id)
            .cloned()
            .ok_or_else(|| RuntimeError::ContainerNotFound(handle.container_id.clone()))
    }

    fn remove_pod(&self, handle: &PodHandle) -> Result<(), RuntimeError> {
        let mut inner = self.inner.lock().unwrap();
        inner.pods.remove(&handle.container_id);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::ImagePullAuth;
    use crate::types::GpuType;

    fn test_spec(pod_id: u64) -> PodSpec {
        PodSpec {
            pod_id,
            deployment_id: 100,
            image: "test:latest".into(),
            entrypoint: String::new(),
            port: 0,
            gpu_count: 1,
            gpu_type: GpuType::H100Sxm,
            cpu_millicores: 2000,
            memory_megabytes: 4096,
            env_vars: vec![],
            mounts: vec![],
        }
    }

    #[test]
    fn pull_image_accepts_optional_registry_credentials() {
        let rt = SimulatedRuntime::new(9, FaultConfig::default());
        let auth = ImagePullAuth {
            registry: "registry.example".into(),
            username: "user".into(),
            password: "pw".into(),
        };
        assert!(rt.pull_image("test:latest", Some(&auth)).is_ok());
    }

    #[test]
    fn happy_path() {
        let rt = SimulatedRuntime::new(42, FaultConfig::default());
        rt.pull_image("test:latest", None).unwrap();
        let handle = rt.create_pod(&test_spec(1)).unwrap();
        rt.start_pod(&handle).unwrap();
        assert_eq!(rt.pod_status(&handle).unwrap(), PodStatus::Running);
        rt.stop_pod(&handle, 5000).unwrap();
        assert_eq!(
            rt.pod_status(&handle).unwrap(),
            PodStatus::Stopped { exit_code: 0 }
        );
    }

    #[test]
    fn create_start_adopts_existing_running_pod() {
        let rt = SimulatedRuntime::new(42, FaultConfig::default());
        let spec = test_spec(1);
        let handle = rt.create_pod(&spec).unwrap();
        rt.start_pod(&handle).unwrap();

        let adopted = rt.create_pod(&spec).unwrap();
        assert_eq!(adopted.container_id, handle.container_id);
        assert_eq!(rt.pod_status(&adopted).unwrap(), PodStatus::Running);
        rt.start_pod(&adopted).unwrap();
        assert_eq!(rt.pod_status(&adopted).unwrap(), PodStatus::Running);
    }

    #[test]
    fn image_pull_failure_injection() {
        let rt = SimulatedRuntime::new(
            42,
            FaultConfig {
                image_pull_failure_rate: Ratio::new(1, 1), // 100%
                ..Default::default()
            },
        );
        assert!(rt.pull_image("test:latest", None).is_err());
    }

    #[test]
    fn deterministic_stop_failure_keeps_runtime_running_until_retry() {
        let rt = SimulatedRuntime::new(
            0xB2_01,
            FaultConfig {
                stop_failure_rate: Ratio::new(1, 1),
                ..Default::default()
            },
        );
        let handle = rt.create_pod(&test_spec(1)).unwrap();
        rt.start_pod(&handle).unwrap();

        assert!(matches!(
            rt.stop_pod(&handle, 0),
            Err(RuntimeError::ContainerStop(_))
        ));
        assert_eq!(rt.pod_status(&handle).unwrap(), PodStatus::Running);

        rt.stop_pod(&handle, 0).unwrap();
        assert_eq!(
            rt.pod_status(&handle).unwrap(),
            PodStatus::Stopped { exit_code: 0 }
        );
    }

    #[test]
    fn spontaneous_crash() {
        let rt = SimulatedRuntime::new(
            42,
            FaultConfig {
                container_crash_rate: Ratio::new(1, 1), // 100%
                ..Default::default()
            },
        );
        let handle = rt.create_pod(&test_spec(1)).unwrap();
        rt.start_pod(&handle).unwrap();
        assert_eq!(rt.pod_status(&handle).unwrap(), PodStatus::Running);

        rt.maybe_crash_pods();
        assert_eq!(
            rt.pod_status(&handle).unwrap(),
            PodStatus::Stopped { exit_code: 137 }
        );
    }

    #[test]
    fn fault_outcomes_do_not_depend_on_call_order() {
        let fault_config = FaultConfig {
            image_pull_failure_rate: Ratio::new(25, 100),
            create_failure_rate: Ratio::new(25, 100),
            gpu_failure_rate: Ratio::new(25, 100),
            ..Default::default()
        };
        let rt_a = SimulatedRuntime::new(99, fault_config.clone());
        let rt_b = SimulatedRuntime::new(99, fault_config);

        let spec_1 = test_spec(1);
        let spec_2 = test_spec(2);

        let image_1_a = rt_a.pull_image("image:1", None).is_ok();
        let image_2_a = rt_a.pull_image("image:2", None).is_ok();
        let create_1_a = rt_a.create_pod(&spec_1).is_ok();
        let create_2_a = rt_a.create_pod(&spec_2).is_ok();
        let start_1_a = rt_a
            .start_pod(&PodHandle {
                pod_id: 1,
                container_id: "sim-pod-1".into(),
            })
            .is_ok();
        let start_2_a = rt_a
            .start_pod(&PodHandle {
                pod_id: 2,
                container_id: "sim-pod-2".into(),
            })
            .is_ok();

        let start_2_b = rt_b
            .start_pod(&PodHandle {
                pod_id: 2,
                container_id: "sim-pod-2".into(),
            })
            .is_ok();
        let create_2_b = rt_b.create_pod(&spec_2).is_ok();
        let image_2_b = rt_b.pull_image("image:2", None).is_ok();
        let start_1_b = rt_b
            .start_pod(&PodHandle {
                pod_id: 1,
                container_id: "sim-pod-1".into(),
            })
            .is_ok();
        let create_1_b = rt_b.create_pod(&spec_1).is_ok();
        let image_1_b = rt_b.pull_image("image:1", None).is_ok();

        assert_eq!(image_1_a, image_1_b);
        assert_eq!(image_2_a, image_2_b);
        assert_eq!(create_1_a, create_1_b);
        assert_eq!(create_2_a, create_2_b);
        assert_eq!(start_1_a, start_1_b);
        assert_eq!(start_2_a, start_2_b);
    }

    #[test]
    fn forward_run_echoes_payload_for_running_pod() {
        let rt = SimulatedRuntime::new(42, FaultConfig::default());
        let handle = rt.create_pod(&test_spec(9)).unwrap();
        rt.start_pod(&handle).unwrap();

        let response = rt.forward_run(&handle, 8080, b"poc-run").unwrap();
        assert_eq!(response, b"poc-run");
    }
}
