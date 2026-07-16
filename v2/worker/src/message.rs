use crate::types::GpuType;

// -- Control Plane -> Agent --

#[derive(Debug, Clone)]
pub enum ControlMessage {
    StartPod(StartPodCmd),
    StopPod(StopPodCmd),
    ProbePod(ProbePodCmd),
    RunRequest(RunRequestCmd),
}

#[derive(Debug, Clone)]
pub struct EnvEntry {
    pub name: String,
    pub value: String,
    pub is_secret_ref: bool,
}

#[derive(Debug, Clone)]
pub struct StartPodCmd {
    pub pod_id: u64,
    pub deployment_id: u64,
    pub image: String,
    pub entrypoint: String,
    pub port: u16,
    pub gpu_count: u8,
    pub gpu_type: GpuType,
    pub cpu_millicores: u32,
    pub memory_megabytes: u32,
    pub juicefs_path: String,
    pub liveness_path: String,
    pub readiness_path: String,
    pub env_vars: Vec<EnvEntry>,
    /// Optional registry host hint (informational; image should remain fully qualified).
    pub image_pull_registry: String,
    pub image_pull_username: String,
    pub image_pull_password: String,
    pub image_pull_password_is_secret: bool,
}

#[derive(Debug, Clone)]
pub struct StopPodCmd {
    pub pod_id: u64,
    pub grace_period_ms: u64,
}

#[derive(Debug, Clone)]
pub struct ProbePodCmd {
    pub pod_id: u64,
}

#[derive(Debug, Clone)]
pub struct RunRequestCmd {
    pub request_id: u64,
    pub deployment_id: u64,
    pub payload: Vec<u8>,
}

// -- Agent -> Control Plane --

#[derive(Debug, Clone)]
pub enum WorkerMessage {
    NodeRegister(NodeRegisterMsg),
    NodeHeartbeat(NodeHeartbeatMsg),
    PodStatusEvent(PodStatusEventMsg),
    RunResponse(RunResponseMsg),
}

#[derive(Debug, Clone)]
pub struct NodeRegisterMsg {
    pub node_name: String,
    pub cpu_millicores: u32,
    pub memory_megabytes: u32,
    pub gpu_type: GpuType,
    pub gpu_count: u8,
}

#[derive(Debug, Clone)]
pub struct NodeHeartbeatMsg {
    pub tick: u64,
    pub active_pods: u32,
    pub gpu_free: u8,
}

#[derive(Debug, Clone)]
pub struct PodStatusEventMsg {
    pub pod_id: u64,
    pub status: PodStatusReport,
}

#[derive(Debug, Clone)]
pub struct RunResponseMsg {
    pub request_id: u64,
    pub status: u8,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PodStatusReport {
    ImagePulling,
    Creating,
    Running,
    Stopped { exit_code: i32 },
    Failed { reason: String },
}
