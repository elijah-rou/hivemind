use crate::types::GpuType;

#[cfg(target_os = "linux")]
pub mod containerd;
pub mod process;

#[derive(Clone)]
pub struct BindMount {
    pub host_path: String,
    pub container_path: String,
}

/// Optional credentials for `ctr images pull --user user:pass`.
#[derive(Debug, Clone, Default)]
pub struct ImagePullAuth {
    pub registry: String,
    pub username: String,
    pub password: String,
}

#[derive(Clone)]
pub struct PodSpec {
    pub pod_id: u64,
    pub deployment_id: u64,
    pub image: String,
    pub entrypoint: String,
    pub port: u16,
    pub gpu_count: u8,
    pub gpu_type: GpuType,
    pub cpu_millicores: u32,
    pub memory_megabytes: u32,
    pub env_vars: Vec<(String, String)>,
    pub mounts: Vec<BindMount>,
}

#[derive(Clone, Debug)]
pub struct PodHandle {
    pub pod_id: u64,
    pub container_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PodStatus {
    Created,
    Running,
    Stopped { exit_code: i32 },
    Unknown,
}

#[derive(Debug)]
pub enum RuntimeError {
    ImagePull(String),
    ContainerCreate(String),
    ContainerStart(String),
    ContainerStop(String),
    ContainerNotFound(String),
    ResponseTooLarge(String),
    Internal(String),
}

impl std::fmt::Display for RuntimeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ImagePull(msg) => write!(f, "image pull failed: {msg}"),
            Self::ContainerCreate(msg) => write!(f, "container create failed: {msg}"),
            Self::ContainerStart(msg) => write!(f, "container start failed: {msg}"),
            Self::ContainerStop(msg) => write!(f, "container stop failed: {msg}"),
            Self::ContainerNotFound(msg) => write!(f, "container not found: {msg}"),
            Self::ResponseTooLarge(msg) => write!(f, "response too large: {msg}"),
            Self::Internal(msg) => write!(f, "internal error: {msg}"),
        }
    }
}

/// Abstraction over container runtimes. Sync interface -- async runtimes
/// (containerd/tokio) block internally. This keeps the trait compatible
/// with deterministic simulation testing in Phase 2.
pub trait Runtime: Sync {
    fn pull_image(&self, image: &str, auth: Option<&ImagePullAuth>) -> Result<(), RuntimeError>;
    fn create_pod(&self, spec: &PodSpec) -> Result<PodHandle, RuntimeError>;
    fn start_pod(&self, handle: &PodHandle) -> Result<(), RuntimeError>;
    fn forward_run(
        &self,
        handle: &PodHandle,
        port: u16,
        payload: &[u8],
    ) -> Result<Vec<u8>, RuntimeError>;
    fn stop_pod(&self, handle: &PodHandle, grace_period_ms: u64) -> Result<(), RuntimeError>;
    fn pod_status(&self, handle: &PodHandle) -> Result<PodStatus, RuntimeError>;
    fn remove_pod(&self, handle: &PodHandle) -> Result<(), RuntimeError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pod_spec_construction() {
        let spec = PodSpec {
            pod_id: 1,
            deployment_id: 100,
            image: "nginx:latest".into(),
            entrypoint: "/bin/sh".into(),
            port: 8080,
            gpu_count: 2,
            gpu_type: GpuType::H100Sxm,
            cpu_millicores: 4000,
            memory_megabytes: 8192,
            env_vars: vec![("FOO".into(), "bar".into())],
            mounts: vec![],
        };
        assert_eq!(spec.pod_id, 1);
        assert_eq!(spec.gpu_type, GpuType::H100Sxm);
        assert_eq!(spec.env_vars.len(), 1);
    }

    #[test]
    fn pod_status_eq() {
        assert_eq!(PodStatus::Running, PodStatus::Running);
        assert_eq!(
            PodStatus::Stopped { exit_code: 0 },
            PodStatus::Stopped { exit_code: 0 }
        );
        assert_ne!(PodStatus::Running, PodStatus::Created);
    }

    #[test]
    fn runtime_error_display() {
        let err = RuntimeError::ImagePull("timeout".into());
        assert_eq!(format!("{err}"), "image pull failed: timeout");
    }

    // Verify Runtime is object-safe (can be used as dyn Runtime)
    fn _assert_object_safe(_r: &dyn Runtime) {}
}
