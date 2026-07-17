use std::collections::HashMap;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use crate::io::Io;
use crate::message::*;
use crate::runtime::{
    BindMount, ImagePullAuth, PodHandle, PodSpec, PodStatus, Runtime, RuntimeError,
};
use crate::secrets::SecretResolver;
use crate::types::GpuType;
use crate::volumes;

const HEARTBEAT_INTERVAL_TICKS: u64 = 100;
pub const LIFECYCLE_RETRY_MAX: u8 = 3;
pub const LIFECYCLE_RETRY_DELAY_TICKS: u64 = 25;
pub const LIFECYCLE_FIRST_RETRY_DELAY_TICKS: u64 = LIFECYCLE_RETRY_DELAY_TICKS * 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TrackedPodState {
    ImagePulling,
    Creating,
    Starting,
    Running,
    Stopping,
    Stopped { exit_code: i32 },
    Failed { reason: String },
}

pub struct TrackedPod {
    pub pod_id: u64,
    pub deployment_id: u64,
    pub image: String,
    pub entrypoint: String,
    pub state: TrackedPodState,
    pub handle: Option<PodHandle>,
    pub state_changed_at: u64,
    pub gpu_count: u8,
    pub cpu_millicores: u32,
    pub memory_megabytes: u32,
    pub grace_period_ms: u64,
    pub port: u16,
    pub liveness_path: String,
    pub readiness_path: String,
    pub probe_interval_ms: u64,
    pub last_probe_tick: u64,
    pub consecutive_failures: u8,
    pub env_vars: Vec<(String, String)>,
    pub juicefs_path: String,
    pub image_pull_auth: Option<ImagePullAuth>,
    pub lifecycle_failures: u8,
    pub lifecycle_retry_after_tick: u64,
}

pub struct Worker {
    pub node_name: String,
    pub gpu_type: GpuType,
    pub gpu_total: u8,
    pub cpu_millicores: u32,
    pub memory_megabytes: u32,

    pods: HashMap<u64, TrackedPod>,
    last_heartbeat_tick: u64,
    registered: bool,
    gpu_allocated: u8,
    cpu_allocated_millicores: u32,
    memory_allocated_megabytes: u32,
    lifecycle_concurrency: usize,
    secret_resolver: SecretResolver,
}

fn now_wall_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock must be after unix epoch")
        .as_millis()
        .min(u64::MAX as u128) as u64
}

fn log_pod_event(
    node: &str,
    pod_id: u64,
    deployment_id: u64,
    phase: &str,
    tick: u64,
    duration_ms: Option<u128>,
) {
    let duration = duration_ms.unwrap_or(0).min(u64::MAX as u128) as u64;
    let start_ms = tick;
    let end_ms = tick.saturating_add(duration);
    log_pod_event_span(node, pod_id, deployment_id, phase, tick, start_ms, end_ms);
}

fn log_pod_event_span(
    node: &str,
    pod_id: u64,
    deployment_id: u64,
    phase: &str,
    tick: u64,
    start_ms: u64,
    end_ms: u64,
) {
    let duration = end_ms.saturating_sub(start_ms);
    eprintln!(
        "hivemind_worker_pod_event system=hivemind component=worker node={} pod_id={} deployment_id={} name=- op=start_pod phase={} tick={} start_ms={} end_ms={} duration_ms={} count=1 source=worker/src/worker.rs",
        node, pod_id, deployment_id, phase, tick, start_ms, end_ms, duration
    );
}

impl Worker {
    pub fn new(
        node_name: String,
        gpu_type: GpuType,
        gpu_total: u8,
        cpu_millicores: u32,
        memory_megabytes: u32,
    ) -> Self {
        Self {
            node_name,
            gpu_type,
            gpu_total,
            cpu_millicores,
            memory_megabytes,
            pods: HashMap::new(),
            last_heartbeat_tick: 0,
            registered: false,
            gpu_allocated: 0,
            cpu_allocated_millicores: 0,
            memory_allocated_megabytes: 0,
            lifecycle_concurrency: 4,
            secret_resolver: SecretResolver::new(),
        }
    }

    pub fn new_with_lifecycle_concurrency(
        node_name: String,
        gpu_type: GpuType,
        gpu_total: u8,
        cpu_millicores: u32,
        memory_megabytes: u32,
        lifecycle_concurrency: usize,
    ) -> Self {
        let mut worker = Self::new(
            node_name,
            gpu_type,
            gpu_total,
            cpu_millicores,
            memory_megabytes,
        );
        worker.lifecycle_concurrency = lifecycle_concurrency.clamp(1, 32);
        worker
    }

    /// TCP/session to the control plane was lost; send `NodeRegister` again after reconnect.
    pub fn on_connection_lost(&mut self) {
        self.registered = false;
    }

    pub fn tick(&mut self, io: &mut dyn Io, runtime: &dyn Runtime) {
        let now = io.now();

        if !self.registered {
            io.send(WorkerMessage::NodeRegister(NodeRegisterMsg {
                node_name: self.node_name.clone(),
                cpu_millicores: self.cpu_millicores,
                memory_megabytes: self.memory_megabytes,
                gpu_type: self.gpu_type,
                gpu_count: self.gpu_total,
            }));
            self.registered = true;
            self.last_heartbeat_tick = now;
        }

        while let Some(msg) = io.recv() {
            self.handle_message(io, runtime, msg, now);
        }

        self.drive_pods(io, runtime, now);

        if now >= self.last_heartbeat_tick + HEARTBEAT_INTERVAL_TICKS {
            let active_pods = self
                .pods
                .values()
                .filter(|p| p.state == TrackedPodState::Running)
                .count() as u32;

            io.send(WorkerMessage::NodeHeartbeat(NodeHeartbeatMsg {
                tick: now,
                active_pods,
                gpu_free: self.gpu_total.saturating_sub(self.gpu_allocated),
            }));
            self.last_heartbeat_tick = now;
        }
    }

    fn handle_message(
        &mut self,
        io: &mut dyn Io,
        runtime: &dyn Runtime,
        msg: ControlMessage,
        now: u64,
    ) {
        match msg {
            ControlMessage::StartPod(cmd) => self.handle_start_pod(io, cmd, now),
            ControlMessage::StopPod(cmd) => self.handle_stop_pod(cmd, now),
            ControlMessage::ProbePod(cmd) => self.handle_probe_pod(io, cmd),
            ControlMessage::RunRequest(cmd) => self.handle_run_request(io, runtime, cmd),
        }
    }

    fn handle_run_request(&self, io: &mut dyn Io, runtime: &dyn Runtime, cmd: RunRequestCmd) {
        // Find a running pod for this deployment.
        let pod = self.pods.values().find(|p| {
            p.deployment_id == cmd.deployment_id
                && p.state == TrackedPodState::Running
                && p.port > 0
                && p.handle.is_some()
        });

        match pod {
            Some(pod) => {
                let handle = pod.handle.as_ref().expect("running pod handle must exist");
                match runtime.forward_run(handle, pod.port, &cmd.payload) {
                    Ok(response) => {
                        io.send(WorkerMessage::RunResponse(RunResponseMsg {
                            request_id: cmd.request_id,
                            status: 0,
                            payload: response,
                        }));
                    }
                    Err(e) => {
                        eprintln!("inference forward failed: {e}");
                        io.send(WorkerMessage::RunResponse(RunResponseMsg {
                            request_id: cmd.request_id,
                            status: crate::protocol::RUN_STATUS_FORWARDING_FAILED,
                            payload: e.to_string().into_bytes(),
                        }));
                    }
                }
            }
            None => {
                io.send(WorkerMessage::RunResponse(RunResponseMsg {
                    request_id: cmd.request_id,
                    status: crate::protocol::RUN_STATUS_NO_RUNNING_POD,
                    payload: format!("no running pod for deployment {}", cmd.deployment_id)
                        .into_bytes(),
                }));
            }
        }
    }

    fn handle_start_pod(&mut self, io: &mut dyn Io, cmd: StartPodCmd, now: u64) {
        if self.pods.contains_key(&cmd.pod_id) {
            return;
        }

        eprintln!(
            "worker: start pod pod_id={} deployment_id={} image={} port={} gpu_count={}",
            cmd.pod_id, cmd.deployment_id, cmd.image, cmd.port, cmd.gpu_count
        );
        log_pod_event(
            &self.node_name,
            cmd.pod_id,
            cmd.deployment_id,
            "start_pod_received",
            now,
            None,
        );

        if self.gpu_allocated.saturating_add(cmd.gpu_count) > self.gpu_total {
            self.reject_start(io, cmd.pod_id, "insufficient GPU capacity");
            return;
        }
        if self
            .cpu_allocated_millicores
            .saturating_add(cmd.cpu_millicores)
            > self.cpu_millicores
        {
            self.reject_start(io, cmd.pod_id, "insufficient CPU capacity");
            return;
        }
        if self
            .memory_allocated_megabytes
            .saturating_add(cmd.memory_megabytes)
            > self.memory_megabytes
        {
            self.reject_start(io, cmd.pod_id, "insufficient memory capacity");
            return;
        }

        self.gpu_allocated += cmd.gpu_count;
        self.cpu_allocated_millicores += cmd.cpu_millicores;
        self.memory_allocated_megabytes += cmd.memory_megabytes;
        let pod_id = cmd.pod_id;

        // Resolve secret refs before storing
        let env_vars = self.secret_resolver.resolve(&cmd.env_vars);

        let image_pull_password = self
            .secret_resolver
            .resolve_plain_or_secret(&cmd.image_pull_password, cmd.image_pull_password_is_secret)
            .unwrap_or_default();

        let image_pull_auth =
            if !cmd.image_pull_username.is_empty() || !image_pull_password.is_empty() {
                Some(ImagePullAuth {
                    registry: cmd.image_pull_registry.clone(),
                    username: cmd.image_pull_username.clone(),
                    password: image_pull_password,
                })
            } else {
                None
            };

        self.pods.insert(
            pod_id,
            TrackedPod {
                pod_id,
                deployment_id: cmd.deployment_id,
                image: cmd.image,
                entrypoint: cmd.entrypoint,
                state: TrackedPodState::ImagePulling,
                handle: None,
                state_changed_at: now,
                gpu_count: cmd.gpu_count,
                cpu_millicores: cmd.cpu_millicores,
                memory_megabytes: cmd.memory_megabytes,
                grace_period_ms: 0,
                port: cmd.port,
                liveness_path: cmd.liveness_path,
                readiness_path: cmd.readiness_path,
                probe_interval_ms: 10000,
                last_probe_tick: now,
                consecutive_failures: 0,
                env_vars,
                juicefs_path: cmd.juicefs_path,
                image_pull_auth,
                lifecycle_failures: 0,
                lifecycle_retry_after_tick: 0,
            },
        );

        io.send(WorkerMessage::PodStatusEvent(PodStatusEventMsg {
            pod_id,
            status: PodStatusReport::ImagePulling,
        }));
    }

    fn reject_start(&self, io: &mut dyn Io, pod_id: u64, reason: &str) {
        eprintln!("worker: reject pod {pod_id}: {reason}");
        io.send(WorkerMessage::PodStatusEvent(PodStatusEventMsg {
            pod_id,
            status: PodStatusReport::Failed {
                reason: reason.into(),
            },
        }));
    }

    fn release_pod_resources(&mut self, pod_id: u64) {
        let Some(pod) = self.pods.get(&pod_id) else {
            return;
        };
        self.gpu_allocated = self.gpu_allocated.saturating_sub(pod.gpu_count);
        self.cpu_allocated_millicores = self
            .cpu_allocated_millicores
            .saturating_sub(pod.cpu_millicores);
        self.memory_allocated_megabytes = self
            .memory_allocated_megabytes
            .saturating_sub(pod.memory_megabytes);
    }

    fn handle_stop_pod(&mut self, cmd: StopPodCmd, now: u64) {
        if let Some(pod) = self.pods.get_mut(&cmd.pod_id) {
            if matches!(
                pod.state,
                TrackedPodState::ImagePulling
                    | TrackedPodState::Creating
                    | TrackedPodState::Starting
                    | TrackedPodState::Running
            ) {
                pod.state = TrackedPodState::Stopping;
                pod.state_changed_at = now;
                pod.grace_period_ms = cmd.grace_period_ms;
            }
        }
    }

    fn handle_probe_pod(&self, io: &mut dyn Io, cmd: ProbePodCmd) {
        let Some(pod) = self.pods.get(&cmd.pod_id) else {
            return;
        };

        let status = match &pod.state {
            TrackedPodState::Running => PodStatusReport::Running,
            TrackedPodState::Stopped { exit_code } => PodStatusReport::Stopped {
                exit_code: *exit_code,
            },
            TrackedPodState::Failed { reason } => PodStatusReport::Failed {
                reason: reason.clone(),
            },
            TrackedPodState::ImagePulling => PodStatusReport::ImagePulling,
            TrackedPodState::Creating | TrackedPodState::Starting => PodStatusReport::Creating,
            TrackedPodState::Stopping => PodStatusReport::Running,
        };

        io.send(WorkerMessage::PodStatusEvent(PodStatusEventMsg {
            pod_id: cmd.pod_id,
            status,
        }));
    }

    fn drive_pods(&mut self, io: &mut dyn Io, runtime: &dyn Runtime, now: u64) {
        #[derive(Clone)]
        enum LifecycleOp {
            Pull {
                pod_id: u64,
                deployment_id: u64,
                image: String,
                auth: Option<ImagePullAuth>,
            },
            Create {
                pod_id: u64,
                deployment_id: u64,
                spec: PodSpec,
            },
            Start {
                pod_id: u64,
                deployment_id: u64,
                handle: PodHandle,
            },
            Stop {
                pod_id: u64,
                handle: Option<PodHandle>,
            },
        }

        enum LifecycleResult {
            Pull(Result<(), RuntimeError>),
            Create(Result<PodHandle, RuntimeError>),
            Start(Result<(), RuntimeError>),
            Stop(Result<(), RuntimeError>),
        }

        struct LifecycleCompletion {
            op: LifecycleOp,
            result: LifecycleResult,
            start_ms: u64,
            end_ms: u64,
        }

        let mut pod_ids: Vec<u64> = self.pods.keys().copied().collect();
        pod_ids.sort_unstable();
        let mut lifecycle_ops = Vec::new();

        for pod_id in pod_ids {
            let state = self.pods[&pod_id].state.clone();

            match state {
                TrackedPodState::ImagePulling => {
                    let pod = &self.pods[&pod_id];
                    lifecycle_ops.push(LifecycleOp::Pull {
                        pod_id,
                        deployment_id: pod.deployment_id,
                        image: pod.image.clone(),
                        auth: pod.image_pull_auth.clone(),
                    });
                }

                TrackedPodState::Creating => {
                    if self.pods[&pod_id].lifecycle_retry_after_tick > now {
                        continue;
                    }
                    let spec = {
                        let pod = &self.pods[&pod_id];

                        // Mount JuiceFS if a path is specified. This remains on the main
                        // worker thread because mount setup mutates host state; containerd
                        // create/start/pull work below is the expensive bounded-concurrent path.
                        let mut mounts = Vec::new();
                        if !pod.juicefs_path.is_empty() {
                            match volumes::mount_juicefs(pod_id, &pod.juicefs_path) {
                                Ok(vol) => {
                                    mounts.push(BindMount {
                                        host_path: vol.host_path.to_string_lossy().to_string(),
                                        container_path: vol.container_path,
                                    });
                                }
                                Err(e) => {
                                    eprintln!("juicefs mount failed for pod {pod_id}: {e}");
                                }
                            }
                        }

                        PodSpec {
                            pod_id,
                            deployment_id: pod.deployment_id,
                            image: pod.image.clone(),
                            entrypoint: pod.entrypoint.clone(),
                            port: pod.port,
                            gpu_count: pod.gpu_count,
                            gpu_type: self.gpu_type,
                            cpu_millicores: pod.cpu_millicores,
                            memory_megabytes: pod.memory_megabytes,
                            env_vars: pod.env_vars.clone(),
                            mounts,
                        }
                    };
                    lifecycle_ops.push(LifecycleOp::Create {
                        pod_id,
                        deployment_id: spec.deployment_id,
                        spec,
                    });
                }

                TrackedPodState::Starting => {
                    if self.pods[&pod_id].lifecycle_retry_after_tick > now {
                        continue;
                    }
                    if let Some(handle) = self.pods[&pod_id].handle.clone() {
                        lifecycle_ops.push(LifecycleOp::Start {
                            pod_id,
                            deployment_id: self.pods[&pod_id].deployment_id,
                            handle,
                        });
                    }
                }

                TrackedPodState::Running => {
                    // Check for spontaneous crashes via runtime
                    let mut crashed = false;
                    if let Some(ref handle) = self.pods[&pod_id].handle {
                        if let Ok(status) = runtime.pod_status(handle) {
                            if let PodStatus::Stopped { exit_code } = status {
                                let pod = self.pods.get_mut(&pod_id).unwrap();
                                pod.state = TrackedPodState::Stopped { exit_code };
                                pod.state_changed_at = now;
                                self.release_pod_resources(pod_id);
                                io.send(WorkerMessage::PodStatusEvent(PodStatusEventMsg {
                                    pod_id,
                                    status: PodStatusReport::Stopped { exit_code },
                                }));
                                crashed = true;
                            }
                        }
                    }

                    // Health probe check (only if pod didn't just crash)
                    if !crashed {
                        let should_probe = {
                            let pod = &self.pods[&pod_id];
                            !pod.liveness_path.is_empty()
                                && pod.port > 0
                                && now >= pod.last_probe_tick + pod.probe_interval_ms
                        };
                        if should_probe {
                            let port = self.pods[&pod_id].port;
                            let path = self.pods[&pod_id].liveness_path.clone();
                            self.pods.get_mut(&pod_id).unwrap().last_probe_tick = now;

                            match crate::runtime::process::probe_http(port, &path) {
                                Ok(true) => {
                                    self.pods.get_mut(&pod_id).unwrap().consecutive_failures = 0;
                                }
                                _ => {
                                    let pod = self.pods.get_mut(&pod_id).unwrap();
                                    pod.consecutive_failures += 1;
                                    if pod.consecutive_failures >= 3 {
                                        self.fail_pod(
                                            io,
                                            pod_id,
                                            "liveness probe failed".into(),
                                            now,
                                        );
                                    }
                                }
                            }
                        }
                    }
                }

                TrackedPodState::Stopping => {
                    lifecycle_ops.push(LifecycleOp::Stop {
                        pod_id,
                        handle: self.pods[&pod_id].handle.clone(),
                    });
                }

                _ => {}
            }
        }

        let phase_concurrency = |op: &LifecycleOp| -> usize {
            match op {
                LifecycleOp::Start { .. } => self.lifecycle_concurrency.max(1),
                LifecycleOp::Pull { .. }
                | LifecycleOp::Create { .. }
                | LifecycleOp::Stop { .. } => {
                    self.lifecycle_concurrency.saturating_mul(4).clamp(1, 32)
                }
            }
        };
        let mut completions = Vec::with_capacity(lifecycle_ops.len());
        let mut offset = 0;
        while offset < lifecycle_ops.len() {
            let concurrency = phase_concurrency(&lifecycle_ops[offset]);
            let end = offset.saturating_add(concurrency).min(lifecycle_ops.len());
            let chunk = &lifecycle_ops[offset..end];
            std::thread::scope(|scope| {
                let mut handles = Vec::with_capacity(chunk.len());
                for op in chunk.iter().cloned() {
                    let node_name = self.node_name.clone();
                    handles.push(scope.spawn(move || {
                        let phase_start = Instant::now();
                        let start_ms = now_wall_ms();
                        match &op {
                            LifecycleOp::Pull {
                                pod_id,
                                deployment_id,
                                ..
                            } => log_pod_event_span(
                                &node_name,
                                *pod_id,
                                *deployment_id,
                                "image_pull_start",
                                now,
                                start_ms,
                                start_ms,
                            ),
                            LifecycleOp::Create {
                                pod_id,
                                deployment_id,
                                ..
                            } => log_pod_event_span(
                                &node_name,
                                *pod_id,
                                *deployment_id,
                                "container_create_start",
                                now,
                                start_ms,
                                start_ms,
                            ),
                            LifecycleOp::Start {
                                pod_id,
                                deployment_id,
                                ..
                            } => log_pod_event_span(
                                &node_name,
                                *pod_id,
                                *deployment_id,
                                "container_start_start",
                                now,
                                start_ms,
                                start_ms,
                            ),
                            LifecycleOp::Stop { .. } => {}
                        }
                        let result = match &op {
                            LifecycleOp::Pull { image, auth, .. } => {
                                LifecycleResult::Pull(runtime.pull_image(image, auth.as_ref()))
                            }
                            LifecycleOp::Create { spec, .. } => {
                                LifecycleResult::Create(runtime.create_pod(spec))
                            }
                            LifecycleOp::Start { handle, .. } => {
                                LifecycleResult::Start(runtime.start_pod(handle))
                            }
                            LifecycleOp::Stop { handle, .. } => {
                                let result = if let Some(handle) = handle {
                                    runtime.stop_pod(handle, 0)
                                } else {
                                    Ok(())
                                };
                                LifecycleResult::Stop(result)
                            }
                        };
                        let elapsed_ms =
                            phase_start.elapsed().as_millis().min(u64::MAX as u128) as u64;
                        LifecycleCompletion {
                            op,
                            result,
                            start_ms,
                            end_ms: start_ms.saturating_add(elapsed_ms),
                        }
                    }));
                }

                for handle in handles {
                    completions.push(handle.join().expect("lifecycle worker panicked"));
                }
            });
            offset = end;
        }

        for completion in completions {
            match completion.op {
                LifecycleOp::Pull {
                    pod_id,
                    deployment_id,
                    ..
                } => {
                    if self.pods.get(&pod_id).map(|p| &p.state)
                        != Some(&TrackedPodState::ImagePulling)
                    {
                        continue;
                    }
                    match completion.result {
                        LifecycleResult::Pull(Ok(())) => {
                            log_pod_event_span(
                                &self.node_name,
                                pod_id,
                                deployment_id,
                                "image_pull_end",
                                now,
                                completion.start_ms,
                                completion.end_ms,
                            );
                            let pod = self.pods.get_mut(&pod_id).unwrap();
                            pod.state = TrackedPodState::Creating;
                            pod.state_changed_at = now;
                            io.send(WorkerMessage::PodStatusEvent(PodStatusEventMsg {
                                pod_id,
                                status: PodStatusReport::Creating,
                            }));
                        }
                        LifecycleResult::Pull(Err(e)) => {
                            eprintln!("worker: pod {pod_id} image pull failed: {e}");
                            self.fail_pod(io, pod_id, e.to_string(), now)
                        }
                        _ => unreachable!("pull op returned wrong result"),
                    }
                }
                LifecycleOp::Create {
                    pod_id,
                    deployment_id,
                    ..
                } => {
                    if self.pods.get(&pod_id).map(|p| &p.state) != Some(&TrackedPodState::Creating)
                    {
                        continue;
                    }
                    match completion.result {
                        LifecycleResult::Create(Ok(handle)) => {
                            log_pod_event_span(
                                &self.node_name,
                                pod_id,
                                deployment_id,
                                "container_create_end",
                                now,
                                completion.start_ms,
                                completion.end_ms,
                            );
                            let pod = self.pods.get_mut(&pod_id).unwrap();
                            pod.handle = Some(handle);
                            pod.state = TrackedPodState::Starting;
                            pod.state_changed_at = now;
                            pod.lifecycle_retry_after_tick = 0;
                        }
                        LifecycleResult::Create(Err(e)) => {
                            eprintln!("worker: pod {pod_id} container create failed: {e}");
                            self.fail_pod(io, pod_id, e.to_string(), now)
                        }
                        _ => unreachable!("create op returned wrong result"),
                    }
                }
                LifecycleOp::Start {
                    pod_id,
                    deployment_id,
                    handle,
                } => {
                    if self.pods.get(&pod_id).map(|p| &p.state) != Some(&TrackedPodState::Starting)
                    {
                        continue;
                    }
                    match completion.result {
                        LifecycleResult::Start(Ok(())) => {
                            log_pod_event_span(
                                &self.node_name,
                                pod_id,
                                deployment_id,
                                "container_start_end",
                                now,
                                completion.start_ms,
                                completion.end_ms,
                            );
                            let pod = self.pods.get_mut(&pod_id).unwrap();
                            pod.state = TrackedPodState::Running;
                            pod.state_changed_at = now;
                            pod.lifecycle_failures = 0;
                            pod.lifecycle_retry_after_tick = 0;
                            io.send(WorkerMessage::PodStatusEvent(PodStatusEventMsg {
                                pod_id,
                                status: PodStatusReport::Running,
                            }));
                            log_pod_event_span(
                                &self.node_name,
                                pod_id,
                                deployment_id,
                                "running_status_sent",
                                now,
                                completion.end_ms,
                                completion.end_ms,
                            );
                        }
                        LifecycleResult::Start(Err(e)) => {
                            if self.retry_lifecycle_pod(pod_id, now) {
                                let _ = runtime.remove_pod(&handle);
                                if let Some(pod) = self.pods.get_mut(&pod_id) {
                                    pod.handle = None;
                                    pod.state = TrackedPodState::Creating;
                                    pod.state_changed_at = now;
                                }
                                eprintln!(
                                    "worker: pod {pod_id} container start failed transiently, recreating before retry: {e}"
                                );
                            } else {
                                eprintln!("worker: pod {pod_id} container start failed: {e}");
                                self.fail_pod(io, pod_id, e.to_string(), now)
                            }
                        }
                        _ => unreachable!("start op returned wrong result"),
                    }
                }
                LifecycleOp::Stop { pod_id, .. } => {
                    if self.pods.get(&pod_id).map(|p| &p.state) != Some(&TrackedPodState::Stopping)
                    {
                        continue;
                    }
                    if let LifecycleResult::Stop(Err(e)) = completion.result {
                        eprintln!("worker: pod {pod_id} container stop failed: {e}");
                    }
                    volumes::unmount_juicefs(pod_id);
                    let pod = self.pods.get_mut(&pod_id).unwrap();
                    pod.state = TrackedPodState::Stopped { exit_code: 0 };
                    pod.state_changed_at = now;
                    self.release_pod_resources(pod_id);
                    io.send(WorkerMessage::PodStatusEvent(PodStatusEventMsg {
                        pod_id,
                        status: PodStatusReport::Stopped { exit_code: 0 },
                    }));
                }
            }
        }
    }

    fn retry_lifecycle_pod(&mut self, pod_id: u64, now: u64) -> bool {
        let Some(pod) = self.pods.get_mut(&pod_id) else {
            return false;
        };
        if pod.lifecycle_failures.saturating_add(1) >= LIFECYCLE_RETRY_MAX {
            return false;
        }
        pod.lifecycle_failures += 1;
        let delay = LIFECYCLE_RETRY_DELAY_TICKS.saturating_mul(1u64 << pod.lifecycle_failures);
        pod.lifecycle_retry_after_tick = now.saturating_add(delay);
        true
    }

    fn fail_pod(&mut self, io: &mut dyn Io, pod_id: u64, reason: String, now: u64) {
        eprintln!("worker: pod {pod_id} failed: {reason}");
        volumes::unmount_juicefs(pod_id);
        let pod = self.pods.get_mut(&pod_id).unwrap();
        pod.state = TrackedPodState::Failed {
            reason: reason.clone(),
        };
        pod.state_changed_at = now;
        self.release_pod_resources(pod_id);

        io.send(WorkerMessage::PodStatusEvent(PodStatusEventMsg {
            pod_id,
            status: PodStatusReport::Failed { reason },
        }));
    }

    pub fn shutdown(&mut self, io: &mut dyn Io, runtime: &dyn Runtime) {
        /// Default SIGTERM-style drain when the scheduler did not set a pod grace period.
        const DEFAULT_SHUTDOWN_GRACE_MS: u64 = 30_000;

        let pod_ids: Vec<u64> = self.pods.keys().copied().collect();

        for pod_id in pod_ids {
            let snapshot = self
                .pods
                .get(&pod_id)
                .map(|pod| (pod.handle.clone(), pod.state.clone(), pod.grace_period_ms));

            let Some((handle_opt, state, grace_period_ms)) = snapshot else {
                continue;
            };

            let terminal = matches!(
                state,
                TrackedPodState::Stopped { .. } | TrackedPodState::Failed { .. }
            );

            if let Some(ref handle) = handle_opt {
                let grace = if grace_period_ms > 0 {
                    grace_period_ms
                } else {
                    DEFAULT_SHUTDOWN_GRACE_MS
                };
                let _ = runtime.stop_pod(handle, grace);
                let _ = runtime.remove_pod(handle);
            }

            volumes::unmount_juicefs(pod_id);

            if !terminal {
                self.release_pod_resources(pod_id);
                io.send(WorkerMessage::PodStatusEvent(PodStatusEventMsg {
                    pod_id,
                    status: PodStatusReport::Stopped { exit_code: 0 },
                }));
            }
        }

        self.pods.clear();
        eprintln!("agent: all pods stopped");
    }

    // -- Accessors for checker --

    pub fn tracked_pods(&self) -> &HashMap<u64, TrackedPod> {
        &self.pods
    }

    pub fn gpu_allocated(&self) -> u8 {
        self.gpu_allocated
    }

    pub fn cpu_allocated_millicores(&self) -> u32 {
        self.cpu_allocated_millicores
    }

    pub fn memory_allocated_megabytes(&self) -> u32 {
        self.memory_allocated_megabytes
    }

    pub fn pod_counts(&self) -> (usize, usize) {
        let running = self
            .pods
            .values()
            .filter(|p| matches!(p.state, TrackedPodState::Running))
            .count();
        (running, self.pods.len())
    }

    pub fn is_registered(&self) -> bool {
        self.registered
    }

    pub fn last_heartbeat_tick(&self) -> u64 {
        self.last_heartbeat_tick
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::{ImagePullAuth, PodHandle, PodSpec, PodStatus, Runtime, RuntimeError};
    use std::collections::VecDeque;
    use std::sync::Mutex;

    #[test]
    fn connection_loss_forces_reregister() {
        let mut a = Worker::new("node-a".into(), GpuType::None, 0, 1000, 512);
        a.registered = true;
        a.on_connection_lost();
        assert!(!a.is_registered());
    }

    struct CapturedSpec {
        pod_id: u64,
        cpu_millicores: u32,
        memory_megabytes: u32,
    }

    struct CapturingRuntime {
        specs: Mutex<Vec<CapturedSpec>>,
    }

    impl CapturingRuntime {
        fn new() -> Self {
            Self {
                specs: Mutex::new(Vec::new()),
            }
        }
    }

    impl Runtime for CapturingRuntime {
        fn pull_image(
            &self,
            _image: &str,
            _auth: Option<&ImagePullAuth>,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }
        fn create_pod(&self, spec: &PodSpec) -> Result<PodHandle, RuntimeError> {
            self.specs.lock().unwrap().push(CapturedSpec {
                pod_id: spec.pod_id,
                cpu_millicores: spec.cpu_millicores,
                memory_megabytes: spec.memory_megabytes,
            });
            Ok(PodHandle {
                pod_id: spec.pod_id,
                container_id: format!("cap-{}:0", spec.pod_id),
            })
        }
        fn start_pod(&self, _handle: &PodHandle) -> Result<(), RuntimeError> {
            Ok(())
        }
        fn forward_run(
            &self,
            _handle: &PodHandle,
            _port: u16,
            payload: &[u8],
        ) -> Result<Vec<u8>, RuntimeError> {
            Ok(payload.to_vec())
        }
        fn stop_pod(&self, _handle: &PodHandle, _grace_period_ms: u64) -> Result<(), RuntimeError> {
            Ok(())
        }
        fn pod_status(&self, _handle: &PodHandle) -> Result<PodStatus, RuntimeError> {
            Ok(PodStatus::Running)
        }
        fn remove_pod(&self, _handle: &PodHandle) -> Result<(), RuntimeError> {
            Ok(())
        }
    }

    struct TestIo {
        sent: Vec<WorkerMessage>,
        inbox: VecDeque<ControlMessage>,
        tick: u64,
    }

    impl Io for TestIo {
        fn now(&self) -> u64 {
            self.tick
        }
        fn send(&mut self, msg: WorkerMessage) {
            self.sent.push(msg);
        }
        fn recv(&mut self) -> Option<ControlMessage> {
            self.inbox.pop_front()
        }
        fn random_u64(&mut self) -> u64 {
            0
        }
    }

    /// Regression: worker must use the *pod-level* cpu/memory limits supplied
    /// by the control plane, not the node-wide totals, otherwise every pod on
    /// a node competes for the entire cgroup budget.
    #[test]
    fn pod_spec_uses_per_pod_cpu_and_memory_limits() {
        let mut worker = Worker::new("big-node".into(), GpuType::None, 0, 64000, 262144);
        let runtime = CapturingRuntime::new();
        let mut io = TestIo {
            sent: Vec::new(),
            inbox: VecDeque::new(),
            tick: 0,
        };

        let cmd = StartPodCmd {
            pod_id: 7,
            deployment_id: 1,
            image: "demo:v1".into(),
            entrypoint: String::new(),
            port: 8080,
            gpu_count: 0,
            gpu_type: GpuType::None,
            cpu_millicores: 1500,
            memory_megabytes: 2048,
            juicefs_path: String::new(),
            liveness_path: String::new(),
            readiness_path: String::new(),
            env_vars: vec![],
            image_pull_registry: String::new(),
            image_pull_username: String::new(),
            image_pull_password: String::new(),
            image_pull_password_is_secret: false,
        };

        worker.handle_start_pod(&mut io, cmd, 0);
        worker.drive_pods(&mut io, &runtime, 1); // ImagePulling -> Creating
        worker.drive_pods(&mut io, &runtime, 2); // Creating    -> Starting (captures spec)

        let captured = runtime.specs.lock().unwrap();
        assert_eq!(captured.len(), 1, "runtime.create_pod called exactly once");
        assert_eq!(captured[0].pod_id, 7);
        assert_eq!(
            captured[0].cpu_millicores, 1500,
            "must reflect cmd, not node total 64000"
        );
        assert_eq!(
            captured[0].memory_megabytes, 2048,
            "must reflect cmd, not node total 262144"
        );
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
                | (TrackedPodState::Starting, TrackedPodState::Failed { .. })
                | (TrackedPodState::Running, TrackedPodState::Stopping)
                | (TrackedPodState::Running, TrackedPodState::Stopped { .. })
                | (TrackedPodState::Running, TrackedPodState::Failed { .. })
                | (TrackedPodState::Stopping, TrackedPodState::Stopped { .. })
                | (TrackedPodState::Stopping, TrackedPodState::Failed { .. })
        )
    }

    #[test]
    fn valid_transitions() {
        assert!(is_legal_transition(
            &TrackedPodState::ImagePulling,
            &TrackedPodState::Creating
        ));
        assert!(is_legal_transition(
            &TrackedPodState::Starting,
            &TrackedPodState::Creating
        ));
        assert!(is_legal_transition(
            &TrackedPodState::Running,
            &TrackedPodState::Stopping
        ));
        assert!(is_legal_transition(
            &TrackedPodState::Running,
            &TrackedPodState::Stopped { exit_code: 137 }
        ));
    }

    #[test]
    fn invalid_transitions() {
        assert!(!is_legal_transition(
            &TrackedPodState::Running,
            &TrackedPodState::ImagePulling
        ));
        assert!(!is_legal_transition(
            &TrackedPodState::Stopped { exit_code: 0 },
            &TrackedPodState::Running
        ));
    }

    #[test]
    fn running_pod_keeps_declared_service_port() {
        let mut worker = Worker::new("node-port".into(), GpuType::None, 0, 4000, 8192);
        let runtime = CapturingRuntime::new();
        let mut io = TestIo {
            sent: Vec::new(),
            inbox: VecDeque::new(),
            tick: 0,
        };

        let cmd = StartPodCmd {
            pod_id: 11,
            deployment_id: 2,
            image: "demo:v1".into(),
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
        };

        worker.handle_start_pod(&mut io, cmd, 0);
        worker.drive_pods(&mut io, &runtime, 1);
        worker.drive_pods(&mut io, &runtime, 2);
        worker.drive_pods(&mut io, &runtime, 3);

        let pod = worker.tracked_pods().get(&11).expect("pod exists");
        assert!(matches!(pod.state, TrackedPodState::Running));
        assert_eq!(
            pod.port, 8080,
            "must keep service port for runtime forwarding"
        );
    }

    struct ForwardingRuntime {
        seen: Mutex<Vec<(String, u16, Vec<u8>)>>,
        fail: bool,
    }

    impl ForwardingRuntime {
        fn new() -> Self {
            Self {
                seen: Mutex::new(Vec::new()),
                fail: false,
            }
        }

        fn failing() -> Self {
            Self {
                seen: Mutex::new(Vec::new()),
                fail: true,
            }
        }
    }

    impl Runtime for ForwardingRuntime {
        fn pull_image(
            &self,
            _image: &str,
            _auth: Option<&ImagePullAuth>,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }
        fn create_pod(&self, _spec: &PodSpec) -> Result<PodHandle, RuntimeError> {
            unreachable!("not used in run forwarding test")
        }
        fn start_pod(&self, _handle: &PodHandle) -> Result<(), RuntimeError> {
            Ok(())
        }
        fn forward_run(
            &self,
            handle: &PodHandle,
            port: u16,
            payload: &[u8],
        ) -> Result<Vec<u8>, RuntimeError> {
            self.seen
                .lock()
                .unwrap()
                .push((handle.container_id.clone(), port, payload.to_vec()));
            if self.fail {
                return Err(RuntimeError::Internal("forward exploded".into()));
            }
            Ok(br#"{"status":"ok"}"#.to_vec())
        }
        fn stop_pod(&self, _handle: &PodHandle, _grace_period_ms: u64) -> Result<(), RuntimeError> {
            Ok(())
        }
        fn pod_status(&self, _handle: &PodHandle) -> Result<PodStatus, RuntimeError> {
            Ok(PodStatus::Running)
        }
        fn remove_pod(&self, _handle: &PodHandle) -> Result<(), RuntimeError> {
            Ok(())
        }
    }

    #[test]
    fn run_request_without_running_pod_returns_error() {
        let worker = Worker::new("node-run-missing".into(), GpuType::None, 0, 4000, 8192);
        let runtime = ForwardingRuntime::new();
        let mut io = TestIo {
            sent: Vec::new(),
            inbox: VecDeque::new(),
            tick: 0,
        };

        worker.handle_run_request(
            &mut io,
            &runtime,
            RunRequestCmd {
                request_id: 8,
                deployment_id: 56,
                payload: b"payload".to_vec(),
            },
        );

        assert!(runtime.seen.lock().unwrap().is_empty());
        match &io.sent[0] {
            WorkerMessage::RunResponse(resp) => {
                assert_eq!(resp.request_id, 8);
                assert_eq!(resp.status, crate::protocol::RUN_STATUS_NO_RUNNING_POD);
                assert_eq!(resp.payload, b"no running pod for deployment 56");
            }
            other => panic!("unexpected worker message: {other:?}"),
        }
    }

    #[test]
    fn run_request_uses_runtime_forwarder_for_running_pod() {
        let mut worker = Worker::new("node-run".into(), GpuType::None, 0, 4000, 8192);
        let runtime = ForwardingRuntime::new();
        let mut io = TestIo {
            sent: Vec::new(),
            inbox: VecDeque::new(),
            tick: 0,
        };

        worker.pods.insert(
            99,
            TrackedPod {
                pod_id: 99,
                deployment_id: 55,
                image: "demo".into(),
                entrypoint: String::new(),
                state: TrackedPodState::Running,
                handle: Some(PodHandle {
                    pod_id: 99,
                    container_id: "cap-99".into(),
                }),
                state_changed_at: 0,
                gpu_count: 0,
                cpu_millicores: 500,
                memory_megabytes: 512,
                grace_period_ms: 0,
                port: 8080,
                liveness_path: String::new(),
                readiness_path: String::new(),
                probe_interval_ms: 10000,
                last_probe_tick: 0,
                consecutive_failures: 0,
                env_vars: Vec::new(),
                juicefs_path: String::new(),
                image_pull_auth: None,
                lifecycle_failures: 0,
                lifecycle_retry_after_tick: 0,
            },
        );

        worker.handle_run_request(
            &mut io,
            &runtime,
            RunRequestCmd {
                request_id: 7,
                deployment_id: 55,
                payload: b"smoke-body".to_vec(),
            },
        );

        let seen = runtime.seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].0, "cap-99");
        assert_eq!(seen[0].1, 8080);
        assert_eq!(seen[0].2, b"smoke-body");

        match &io.sent[0] {
            WorkerMessage::RunResponse(resp) => {
                assert_eq!(resp.request_id, 7);
                assert_eq!(resp.status, 0);
                assert_eq!(resp.payload, br#"{"status":"ok"}"#);
            }
            other => panic!("unexpected worker message: {other:?}"),
        }
    }

    #[test]
    fn run_forwarding_failure_has_distinct_status() {
        let mut worker = Worker::new("node-run-fail".into(), GpuType::None, 0, 4000, 8192);
        let runtime = ForwardingRuntime::failing();
        let mut io = TestIo {
            sent: Vec::new(),
            inbox: VecDeque::new(),
            tick: 0,
        };
        worker.pods.insert(
            100,
            TrackedPod {
                pod_id: 100,
                deployment_id: 60,
                image: "demo".into(),
                entrypoint: String::new(),
                state: TrackedPodState::Running,
                handle: Some(PodHandle {
                    pod_id: 100,
                    container_id: "cap-100".into(),
                }),
                state_changed_at: 0,
                gpu_count: 0,
                cpu_millicores: 500,
                memory_megabytes: 512,
                grace_period_ms: 0,
                port: 8080,
                liveness_path: String::new(),
                readiness_path: String::new(),
                probe_interval_ms: 10000,
                last_probe_tick: 0,
                consecutive_failures: 0,
                env_vars: Vec::new(),
                juicefs_path: String::new(),
                image_pull_auth: None,
                lifecycle_failures: 0,
                lifecycle_retry_after_tick: 0,
            },
        );

        worker.handle_run_request(
            &mut io,
            &runtime,
            RunRequestCmd {
                request_id: 10,
                deployment_id: 60,
                payload: b"request".to_vec(),
            },
        );
        match &io.sent[0] {
            WorkerMessage::RunResponse(resp) => {
                assert_eq!(resp.status, crate::protocol::RUN_STATUS_FORWARDING_FAILED);
                assert_ne!(resp.status, crate::protocol::RUN_STATUS_NO_RUNNING_POD);
            }
            other => panic!("unexpected worker message: {other:?}"),
        }
    }

    struct StopRecordingRuntime {
        stop_calls: Mutex<Vec<(String, u64)>>,
    }

    impl Runtime for StopRecordingRuntime {
        fn pull_image(
            &self,
            _image: &str,
            _auth: Option<&ImagePullAuth>,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn create_pod(&self, _spec: &PodSpec) -> Result<PodHandle, RuntimeError> {
            unreachable!("not used in stop test")
        }

        fn start_pod(&self, _handle: &PodHandle) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn forward_run(
            &self,
            _handle: &PodHandle,
            _port: u16,
            _payload: &[u8],
        ) -> Result<Vec<u8>, RuntimeError> {
            Ok(Vec::new())
        }

        fn stop_pod(&self, handle: &PodHandle, grace_period_ms: u64) -> Result<(), RuntimeError> {
            self.stop_calls
                .lock()
                .unwrap()
                .push((handle.container_id.clone(), grace_period_ms));
            Ok(())
        }

        fn pod_status(&self, _handle: &PodHandle) -> Result<PodStatus, RuntimeError> {
            Ok(PodStatus::Running)
        }

        fn remove_pod(&self, _handle: &PodHandle) -> Result<(), RuntimeError> {
            Ok(())
        }
    }

    #[test]
    fn stop_pod_cancels_before_runtime_handle_exists() {
        for state in [TrackedPodState::ImagePulling, TrackedPodState::Creating] {
            let mut worker = Worker::new("node-cancel".into(), GpuType::None, 0, 4000, 8192);
            let runtime = StopRecordingRuntime {
                stop_calls: Mutex::new(Vec::new()),
            };
            let mut io = TestIo {
                sent: Vec::new(),
                inbox: VecDeque::new(),
                tick: 0,
            };

            worker.pods.insert(
                41,
                TrackedPod {
                    pod_id: 41,
                    deployment_id: 9,
                    image: "demo".into(),
                    entrypoint: String::new(),
                    state: state.clone(),
                    handle: None,
                    state_changed_at: 0,
                    gpu_count: 0,
                    cpu_millicores: 500,
                    memory_megabytes: 512,
                    grace_period_ms: 0,
                    port: 8080,
                    liveness_path: String::new(),
                    readiness_path: String::new(),
                    probe_interval_ms: 10000,
                    last_probe_tick: 0,
                    consecutive_failures: 0,
                    env_vars: Vec::new(),
                    juicefs_path: String::new(),
                    image_pull_auth: None,
                    lifecycle_failures: 0,
                    lifecycle_retry_after_tick: 0,
                },
            );

            worker.handle_stop_pod(
                StopPodCmd {
                    pod_id: 41,
                    grace_period_ms: 10,
                },
                100,
            );
            worker.drive_pods(&mut io, &runtime, 100);

            assert!(runtime.stop_calls.lock().unwrap().is_empty());
            assert!(matches!(
                worker.tracked_pods()[&41].state,
                TrackedPodState::Stopped { exit_code: 0 }
            ));
            assert_eq!(worker.cpu_allocated_millicores(), 0);
            assert_eq!(worker.memory_allocated_megabytes(), 0);
            assert!(io.sent.iter().any(|msg| matches!(
                msg,
                WorkerMessage::PodStatusEvent(PodStatusEventMsg {
                    pod_id: 41,
                    status: PodStatusReport::Stopped { exit_code: 0 }
                })
            )));
        }
    }

    #[test]
    fn stopping_pod_stops_immediately_with_zero_runtime_grace() {
        let mut worker = Worker::new("node-stop".into(), GpuType::None, 0, 4000, 8192);
        let runtime = StopRecordingRuntime {
            stop_calls: Mutex::new(Vec::new()),
        };
        let mut io = TestIo {
            sent: Vec::new(),
            inbox: VecDeque::new(),
            tick: 0,
        };

        worker.pods.insert(
            42,
            TrackedPod {
                pod_id: 42,
                deployment_id: 9,
                image: "demo".into(),
                entrypoint: String::new(),
                state: TrackedPodState::Running,
                handle: Some(PodHandle {
                    pod_id: 42,
                    container_id: "cap-42".into(),
                }),
                state_changed_at: 0,
                gpu_count: 0,
                cpu_millicores: 500,
                memory_megabytes: 512,
                grace_period_ms: 0,
                port: 8080,
                liveness_path: String::new(),
                readiness_path: String::new(),
                probe_interval_ms: 10000,
                last_probe_tick: 0,
                consecutive_failures: 0,
                env_vars: Vec::new(),
                juicefs_path: String::new(),
                image_pull_auth: None,
                lifecycle_failures: 0,
                lifecycle_retry_after_tick: 0,
            },
        );

        worker.handle_stop_pod(
            StopPodCmd {
                pod_id: 42,
                grace_period_ms: 10,
            },
            100,
        );
        worker.drive_pods(&mut io, &runtime, 100);
        assert_eq!(
            runtime.stop_calls.lock().unwrap().as_slice(),
            &[("cap-42".to_string(), 0)]
        );
        assert!(matches!(
            worker.tracked_pods()[&42].state,
            TrackedPodState::Stopped { exit_code: 0 }
        ));
    }

    struct CreateFailingRuntime;

    impl Runtime for CreateFailingRuntime {
        fn pull_image(
            &self,
            _image: &str,
            _auth: Option<&ImagePullAuth>,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn create_pod(&self, spec: &PodSpec) -> Result<PodHandle, RuntimeError> {
            Err(RuntimeError::ContainerCreate(format!(
                "{}: create exploded",
                spec.pod_id
            )))
        }

        fn start_pod(&self, _handle: &PodHandle) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn forward_run(
            &self,
            _handle: &PodHandle,
            _port: u16,
            _payload: &[u8],
        ) -> Result<Vec<u8>, RuntimeError> {
            Ok(Vec::new())
        }

        fn stop_pod(&self, _handle: &PodHandle, _grace_period_ms: u64) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn pod_status(&self, _handle: &PodHandle) -> Result<PodStatus, RuntimeError> {
            Ok(PodStatus::Unknown)
        }

        fn remove_pod(&self, _handle: &PodHandle) -> Result<(), RuntimeError> {
            Ok(())
        }
    }

    #[test]
    fn create_failure_is_reported_and_releases_gpu_allocation() {
        let mut worker = Worker::new("node-gpu".into(), GpuType::T4, 1, 4000, 8192);
        let runtime = CreateFailingRuntime;
        let mut io = TestIo {
            sent: Vec::new(),
            inbox: VecDeque::new(),
            tick: 0,
        };

        worker.handle_start_pod(
            &mut io,
            StartPodCmd {
                pod_id: 21,
                deployment_id: 9,
                image: "demo:v1".into(),
                entrypoint: String::new(),
                port: 8080,
                gpu_count: 1,
                gpu_type: GpuType::T4,
                cpu_millicores: 1000,
                memory_megabytes: 1024,
                juicefs_path: String::new(),
                liveness_path: String::new(),
                readiness_path: String::new(),
                env_vars: vec![],
                image_pull_registry: String::new(),
                image_pull_username: String::new(),
                image_pull_password: String::new(),
                image_pull_password_is_secret: false,
            },
            0,
        );

        worker.drive_pods(&mut io, &runtime, 1);
        worker.drive_pods(&mut io, &runtime, 2);

        let pod = worker.tracked_pods().get(&21).expect("pod exists");
        match &pod.state {
            TrackedPodState::Failed { reason } => {
                assert!(reason.contains("container create failed"));
                assert!(reason.contains("create exploded"));
            }
            other => panic!("unexpected state: {other:?}"),
        }

        assert_eq!(
            worker.gpu_allocated(),
            0,
            "failed pod must release GPU allocation"
        );

        let failed = io
            .sent
            .iter()
            .rev()
            .find_map(|msg| match msg {
                WorkerMessage::PodStatusEvent(event) => Some(event),
                _ => None,
            })
            .expect("expected pod status event");
        match &failed.status {
            PodStatusReport::Failed { reason } => {
                assert!(reason.contains("container create failed"));
                assert!(reason.contains("create exploded"));
            }
            other => panic!("unexpected status: {other:?}"),
        }
    }

    struct BlockingRuntime {
        active: std::sync::atomic::AtomicUsize,
        max_active: std::sync::atomic::AtomicUsize,
    }

    impl BlockingRuntime {
        fn new() -> Self {
            Self {
                active: std::sync::atomic::AtomicUsize::new(0),
                max_active: std::sync::atomic::AtomicUsize::new(0),
            }
        }

        fn enter(&self) {
            use std::sync::atomic::Ordering;
            let current = self.active.fetch_add(1, Ordering::SeqCst) + 1;
            let mut observed = self.max_active.load(Ordering::SeqCst);
            while current > observed {
                match self.max_active.compare_exchange(
                    observed,
                    current,
                    Ordering::SeqCst,
                    Ordering::SeqCst,
                ) {
                    Ok(_) => break,
                    Err(next) => observed = next,
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(25));
            self.active.fetch_sub(1, Ordering::SeqCst);
        }
    }

    impl Runtime for BlockingRuntime {
        fn pull_image(
            &self,
            _image: &str,
            _auth: Option<&ImagePullAuth>,
        ) -> Result<(), RuntimeError> {
            self.enter();
            Ok(())
        }
        fn create_pod(&self, spec: &PodSpec) -> Result<PodHandle, RuntimeError> {
            Ok(PodHandle {
                pod_id: spec.pod_id,
                container_id: format!("blk-{}", spec.pod_id),
            })
        }
        fn start_pod(&self, _handle: &PodHandle) -> Result<(), RuntimeError> {
            Ok(())
        }
        fn forward_run(
            &self,
            _handle: &PodHandle,
            _port: u16,
            payload: &[u8],
        ) -> Result<Vec<u8>, RuntimeError> {
            Ok(payload.to_vec())
        }
        fn stop_pod(&self, _handle: &PodHandle, _grace_period_ms: u64) -> Result<(), RuntimeError> {
            Ok(())
        }
        fn pod_status(&self, _handle: &PodHandle) -> Result<PodStatus, RuntimeError> {
            Ok(PodStatus::Running)
        }
        fn remove_pod(&self, _handle: &PodHandle) -> Result<(), RuntimeError> {
            Ok(())
        }
    }

    fn test_start_cmd(pod_id: u64, cpu_millicores: u32, memory_megabytes: u32) -> StartPodCmd {
        StartPodCmd {
            pod_id,
            deployment_id: 1,
            image: "demo:v1".into(),
            entrypoint: String::new(),
            port: 8080,
            gpu_count: 0,
            gpu_type: GpuType::None,
            cpu_millicores,
            memory_megabytes,
            juicefs_path: String::new(),
            liveness_path: String::new(),
            readiness_path: String::new(),
            env_vars: vec![],
            image_pull_registry: String::new(),
            image_pull_username: String::new(),
            image_pull_password: String::new(),
            image_pull_password_is_secret: false,
        }
    }

    #[test]
    fn drive_pods_runs_lifecycle_ops_with_bounded_parallelism() {
        let mut worker = Worker::new_with_lifecycle_concurrency(
            "node-par".into(),
            GpuType::None,
            0,
            4000,
            8192,
            2,
        );
        let runtime = BlockingRuntime::new();
        let mut io = TestIo {
            sent: Vec::new(),
            inbox: VecDeque::new(),
            tick: 0,
        };

        for pod_id in 1..=10 {
            worker.handle_start_pod(&mut io, test_start_cmd(pod_id, 100, 128), 0);
        }
        worker.drive_pods(&mut io, &runtime, 1);

        let max_active = runtime.max_active.load(std::sync::atomic::Ordering::SeqCst);
        assert_eq!(
            max_active, 8,
            "pull/create lifecycle concurrency must be bounded at 4x base concurrency"
        );
        for pod_id in 1..=10 {
            assert_eq!(
                worker.tracked_pods()[&pod_id].state,
                TrackedPodState::Creating
            );
        }
    }

    struct FlakyStartRuntime {
        start_calls: Mutex<u32>,
    }

    impl Runtime for FlakyStartRuntime {
        fn pull_image(
            &self,
            _image: &str,
            _auth: Option<&ImagePullAuth>,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }
        fn create_pod(&self, spec: &PodSpec) -> Result<PodHandle, RuntimeError> {
            Ok(PodHandle {
                pod_id: spec.pod_id,
                container_id: format!("flaky-{}", spec.pod_id),
            })
        }
        fn start_pod(&self, _handle: &PodHandle) -> Result<(), RuntimeError> {
            let mut calls = self.start_calls.lock().unwrap();
            *calls += 1;
            if *calls == 1 {
                return Err(RuntimeError::ContainerStart(
                    "transient start failure".into(),
                ));
            }
            Ok(())
        }
        fn forward_run(
            &self,
            _handle: &PodHandle,
            _port: u16,
            payload: &[u8],
        ) -> Result<Vec<u8>, RuntimeError> {
            Ok(payload.to_vec())
        }
        fn stop_pod(&self, _handle: &PodHandle, _grace_period_ms: u64) -> Result<(), RuntimeError> {
            Ok(())
        }
        fn pod_status(&self, _handle: &PodHandle) -> Result<PodStatus, RuntimeError> {
            Ok(PodStatus::Running)
        }
        fn remove_pod(&self, _handle: &PodHandle) -> Result<(), RuntimeError> {
            Ok(())
        }
    }

    #[test]
    fn transient_start_failure_retries_without_failed_status() {
        let mut worker = Worker::new_with_lifecycle_concurrency(
            "node-retry".into(),
            GpuType::None,
            0,
            4000,
            8192,
            2,
        );
        let runtime = FlakyStartRuntime {
            start_calls: Mutex::new(0),
        };
        let mut io = TestIo {
            sent: Vec::new(),
            inbox: VecDeque::new(),
            tick: 0,
        };

        worker.handle_start_pod(&mut io, test_start_cmd(7, 100, 128), 0);
        worker.drive_pods(&mut io, &runtime, 1);
        worker.drive_pods(&mut io, &runtime, 2);
        worker.drive_pods(&mut io, &runtime, 3);
        assert_eq!(worker.tracked_pods()[&7].lifecycle_failures, 1);
        assert_eq!(worker.tracked_pods()[&7].state, TrackedPodState::Creating);
        assert!(worker.tracked_pods()[&7].handle.is_none());

        let retry_at = worker.tracked_pods()[&7].lifecycle_retry_after_tick;
        worker.drive_pods(&mut io, &runtime, retry_at);
        assert_eq!(worker.tracked_pods()[&7].state, TrackedPodState::Starting);
        worker.drive_pods(&mut io, &runtime, retry_at + 1);

        assert_eq!(worker.tracked_pods()[&7].state, TrackedPodState::Running);
        assert_eq!(*runtime.start_calls.lock().unwrap(), 2);
        assert!(!io.sent.iter().any(|msg| matches!(
            msg,
            WorkerMessage::PodStatusEvent(PodStatusEventMsg {
                pod_id: 7,
                status: PodStatusReport::Failed { .. }
            })
        )));
    }

    #[test]
    fn repeated_start_failures_eventually_report_failed_status() {
        let mut worker = Worker::new_with_lifecycle_concurrency(
            "node-retry-cap".into(),
            GpuType::None,
            0,
            4000,
            8192,
            2,
        );
        let runtime = FlakyStartRuntime {
            start_calls: Mutex::new(0),
        };
        let mut io = TestIo {
            sent: Vec::new(),
            inbox: VecDeque::new(),
            tick: 0,
        };

        worker.handle_start_pod(&mut io, test_start_cmd(8, 100, 128), 0);
        worker.drive_pods(&mut io, &runtime, 1);
        worker.drive_pods(&mut io, &runtime, 2);

        // Force every start attempt to fail by resetting the observed call count
        // before each start tick. Create success must not reset lifecycle_failures,
        // or this loops forever in Creating/Starting without notifying core.
        for _ in 0..LIFECYCLE_RETRY_MAX {
            *runtime.start_calls.lock().unwrap() = 0;
            let now = worker.tracked_pods()[&8].lifecycle_retry_after_tick.max(3);
            if worker.tracked_pods()[&8].state == TrackedPodState::Creating {
                worker.drive_pods(&mut io, &runtime, now);
            }
            worker.drive_pods(&mut io, &runtime, now + 1);
        }

        match &worker.tracked_pods()[&8].state {
            TrackedPodState::Failed { reason } => {
                assert!(reason.contains("transient start failure"));
            }
            other => panic!("expected failed pod after capped retries, got {other:?}"),
        }
        assert!(io.sent.iter().any(|msg| matches!(
            msg,
            WorkerMessage::PodStatusEvent(PodStatusEventMsg {
                pod_id: 8,
                status: PodStatusReport::Failed { .. }
            })
        )));
    }

    #[test]
    fn start_pod_rejects_cpu_memory_overcommit_before_insert() {
        let mut worker = Worker::new("node-small".into(), GpuType::None, 0, 100, 100);
        let mut io = TestIo {
            sent: Vec::new(),
            inbox: VecDeque::new(),
            tick: 0,
        };

        worker.handle_start_pod(&mut io, test_start_cmd(1, 80, 80), 0);
        worker.handle_start_pod(&mut io, test_start_cmd(2, 30, 30), 0);

        assert!(worker.tracked_pods().contains_key(&1));
        assert!(!worker.tracked_pods().contains_key(&2));
        assert_eq!(worker.cpu_allocated_millicores(), 80);
        assert_eq!(worker.memory_allocated_megabytes(), 80);
        let failed = io
            .sent
            .iter()
            .rev()
            .find_map(|msg| match msg {
                WorkerMessage::PodStatusEvent(event) if event.pod_id == 2 => Some(event),
                _ => None,
            })
            .expect("expected rejection status");
        assert!(matches!(failed.status, PodStatusReport::Failed { .. }));
    }
}
