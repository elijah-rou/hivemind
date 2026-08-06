use std::fs::{self, File};
use std::os::fd::AsRawFd;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::Duration;

use super::{PodHandle, PodSpec, PodStatus, Runtime, RuntimeError};

const DEFAULT_SOCKET: &str = "/run/containerd/containerd.sock";
const DEFAULT_NAMESPACE: &str = "hivemind";
const CTR_TIMEOUT_SECS: u64 = 30;

pub struct ContainerdRuntime {
    socket_path: String,
    namespace: String,
    runtime_name: String,
    snapshotter: String,
    container_sequence: AtomicU64,
}

impl ContainerdRuntime {
    pub fn new(
        socket_path: Option<&str>,
        namespace: Option<&str>,
        runtime_name: Option<&str>,
        snapshotter: Option<&str>,
    ) -> Result<Self, RuntimeError> {
        Ok(Self {
            socket_path: socket_path.unwrap_or(DEFAULT_SOCKET).to_string(),
            namespace: namespace.unwrap_or(DEFAULT_NAMESPACE).to_string(),
            runtime_name: runtime_name.unwrap_or("io.containerd.runc.v2").to_string(),
            snapshotter: snapshotter.unwrap_or("overlayfs").to_string(),
            container_sequence: AtomicU64::new(0),
        })
    }

    fn container_id_prefix(pod_id: u64) -> String {
        format!("hivemind-pod-{pod_id}")
    }

    fn container_id(&self, pod_id: u64) -> String {
        let sequence = self.container_sequence.fetch_add(1, Ordering::Relaxed) + 1;
        format!("{}-{sequence}", Self::container_id_prefix(pod_id))
    }

    fn gpu_env(&self, spec: &PodSpec) -> Vec<String> {
        if spec.gpu_count == 0 {
            return vec!["NVIDIA_VISIBLE_DEVICES=none".to_string()];
        }
        let ids: Vec<String> = (0..spec.gpu_count).map(|i| i.to_string()).collect();
        vec![
            format!("NVIDIA_VISIBLE_DEVICES={}", ids.join(",")),
            "NVIDIA_DRIVER_CAPABILITIES=compute,utility".to_string(),
        ]
    }

    fn gpu_device_args(&self, spec: &PodSpec) -> Vec<String> {
        let mut args = Vec::new();
        let mut gpu_idx: u8 = 0;
        while gpu_idx < spec.gpu_count {
            args.push("--device".to_string());
            args.push(format!("nvidia.com/gpu={gpu_idx}"));
            gpu_idx += 1;
        }
        args
    }

    fn default_platform() -> &'static str {
        match std::env::consts::ARCH {
            "x86_64" => "linux/amd64",
            "aarch64" => "linux/arm64",
            "arm" => "linux/arm/v7",
            _ => "linux/amd64",
        }
    }

    fn pull_image_args(
        &self,
        image: &str,
        auth: Option<&super::ImagePullAuth>,
        platform: Option<&str>,
    ) -> Vec<String> {
        let mut parts: Vec<String> = vec![
            "images".into(),
            "pull".into(),
            "--snapshotter".into(),
            self.snapshotter.clone(),
        ];

        if let Some(platform) = platform {
            parts.push("--platform".into());
            parts.push(platform.to_string());
        }

        if let Some(a) = auth {
            if !a.username.is_empty() || !a.password.is_empty() {
                parts.push("--user".into());
                parts.push(format!("{}:{}", a.username, a.password));
            }
        }

        parts.push(image.to_string());
        parts
    }

    fn run_ctr(&self, args: &[&str]) -> Result<String, String> {
        self.run_ctr_timeout(args, CTR_TIMEOUT_SECS)
    }

    fn run_ctr_timeout(&self, args: &[&str], timeout_secs: u64) -> Result<String, String> {
        // Use timeout(1) to prevent indefinite hangs (e.g. gVisor shim issues)
        let output = Command::new("timeout")
            .arg(timeout_secs.to_string())
            .arg("ctr")
            .args(["-n", &self.namespace, "-a", &self.socket_path])
            .args(args)
            .output()
            .map_err(|e| format!("ctr exec: {e}"))?;

        if !output.status.success() {
            let code = output.status.code().unwrap_or(-1);
            let stdout = String::from_utf8_lossy(&output.stdout);
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(Self::format_ctr_error(
                args,
                code,
                timeout_secs,
                &stdout,
                &stderr,
            ));
        }

        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    fn format_ctr_error(
        args: &[&str],
        code: i32,
        timeout_secs: u64,
        stdout: &str,
        stderr: &str,
    ) -> String {
        let command = args.join(" ");
        if code == 124 {
            return format!("ctr {command}: timed out after {timeout_secs}s");
        }

        let stdout = stdout.trim();
        let stderr = stderr.trim();
        match (stdout.is_empty(), stderr.is_empty()) {
            (true, true) => format!("ctr {command}: exit code {code}"),
            (true, false) => format!("ctr {command}: exit code {code}: stderr: {stderr}"),
            (false, true) => format!("ctr {command}: exit code {code}: stdout: {stdout}"),
            (false, false) => {
                format!("ctr {command}: exit code {code}: stdout: {stdout}; stderr: {stderr}")
            }
        }
    }

    fn image_present_in_listing(listing: &str, image: &str) -> bool {
        listing
            .lines()
            .skip(1)
            .filter_map(|line| line.split_whitespace().next())
            .any(|reference| reference == image)
    }

    fn image_present(&self, image: &str) -> Result<bool, String> {
        let listing = self.run_ctr(&["images", "ls"])?;
        Ok(Self::image_present_in_listing(&listing, image))
    }

    fn task_status_from_listing(listing: &str, container_id: &str) -> Option<PodStatus> {
        for line in listing.lines().skip(1) {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.len() >= 3 && cols[0] == container_id {
                return match cols[2] {
                    "CREATED" => Some(PodStatus::Created),
                    "RUNNING" => Some(PodStatus::Running),
                    "STOPPED" => Some(PodStatus::Stopped { exit_code: 0 }),
                    _ => Some(PodStatus::Unknown),
                };
            }
        }
        None
    }

    fn task_status_by_id(&self, container_id: &str) -> Result<Option<PodStatus>, RuntimeError> {
        let output = self
            .run_ctr(&["tasks", "list"])
            .map_err(|e| RuntimeError::ContainerNotFound(format!("{container_id}: {e}")))?;
        Ok(Self::task_status_from_listing(&output, container_id))
    }

    fn task_shim_dir(&self, container_id: &str) -> String {
        format!(
            "/run/containerd/io.containerd.runtime.v2.task/{}/{}",
            self.namespace, container_id
        )
    }

    fn cleanup_task_state(&self, container_id: &str) {
        let _ = self.run_ctr(&["tasks", "kill", "--signal", "9", container_id]);
        let _ = self.run_ctr(&["tasks", "delete", "--force", container_id]);
        let _ = self.run_ctr(&["containers", "delete", container_id]);
        let _ = fs::remove_dir_all(self.task_shim_dir(container_id));
    }

    fn ids_with_prefix(listing: &str, prefix: &str, max_ids: usize) -> Vec<String> {
        let mut ids = Vec::new();
        for line in listing.lines().skip(1) {
            if ids.len() >= max_ids {
                break;
            }
            let Some(id) = line.split_whitespace().next() else {
                continue;
            };
            if id == prefix || id.starts_with(&format!("{prefix}-")) {
                ids.push(id.to_string());
            }
        }
        ids
    }

    fn cleanup_container_family(&self, pod_id: u64) {
        const MAX_STALE_IDS: usize = 64;
        let prefix = Self::container_id_prefix(pod_id);

        if let Ok(listing) = self.run_ctr(&["tasks", "list"]) {
            for id in Self::ids_with_prefix(&listing, &prefix, MAX_STALE_IDS) {
                self.cleanup_task_state(&id);
            }
        }

        if let Ok(listing) = self.run_ctr(&["containers", "list"]) {
            for id in Self::ids_with_prefix(&listing, &prefix, MAX_STALE_IDS) {
                let _ = self.run_ctr(&["containers", "delete", &id]);
                let _ = fs::remove_dir_all(self.task_shim_dir(&id));
            }
        }
    }

    fn task_adoptable(status: &PodStatus) -> bool {
        matches!(
            status,
            PodStatus::Running | PodStatus::Created | PodStatus::Unknown
        )
    }

    fn task_already_exists_error(error: &str) -> bool {
        error.contains("already exists")
    }

    fn task_pid(&self, container_id: &str) -> Result<i32, RuntimeError> {
        let output = self
            .run_ctr(&["tasks", "list"])
            .map_err(|e| RuntimeError::ContainerNotFound(format!("{container_id}: {e}")))?;

        for line in output.lines().skip(1) {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.len() >= 2 && cols[0] == container_id {
                return cols[1].parse::<i32>().map_err(|e| {
                    RuntimeError::Internal(format!("parse pid for {container_id}: {e}"))
                });
            }
        }

        Err(RuntimeError::ContainerNotFound(container_id.to_string()))
    }

    fn with_task_netns<T, F>(&self, pid: i32, f: F) -> Result<T, RuntimeError>
    where
        F: FnOnce() -> Result<T, RuntimeError>,
    {
        let current_ns = File::open("/proc/self/ns/net")
            .map_err(|e| RuntimeError::Internal(format!("open current netns: {e}")))?;
        let target_ns = File::open(format!("/proc/{pid}/ns/net"))
            .map_err(|e| RuntimeError::Internal(format!("open task netns for pid {pid}: {e}")))?;

        unsafe {
            if libc::setns(target_ns.as_raw_fd(), libc::CLONE_NEWNET) != 0 {
                return Err(RuntimeError::Internal(format!(
                    "setns enter pid {pid}: {}",
                    std::io::Error::last_os_error()
                )));
            }
        }

        let run_result = f();

        let restore_result = unsafe {
            if libc::setns(current_ns.as_raw_fd(), libc::CLONE_NEWNET) != 0 {
                Err(RuntimeError::Internal(format!(
                    "setns restore: {}",
                    std::io::Error::last_os_error()
                )))
            } else {
                Ok(())
            }
        };

        match (run_result, restore_result) {
            (Ok(value), Ok(())) => Ok(value),
            (Err(err), Ok(())) => Err(err),
            (Ok(_), Err(err)) => Err(err),
            (Err(run_err), Err(restore_err)) => {
                Err(RuntimeError::Internal(format!("{run_err}; {restore_err}")))
            }
        }
    }
}

impl Runtime for ContainerdRuntime {
    fn pull_image(
        &self,
        image: &str,
        auth: Option<&super::ImagePullAuth>,
    ) -> Result<(), RuntimeError> {
        if self
            .image_present(image)
            .map_err(|e| RuntimeError::ImagePull(format!("{image}: {e}")))?
        {
            return Ok(());
        }

        let parts = self.pull_image_args(image, auth, None);
        let refs: Vec<&str> = parts.iter().map(|s| s.as_str()).collect();

        // Image pulls can be slow, use a longer timeout
        match self.run_ctr_timeout(&refs, 300) {
            Ok(_) => {}
            Err(e) if e.contains("no unpack platforms defined") => {
                let platform = Self::default_platform();
                eprintln!(
                    "containerd: retrying image pull for {image} with explicit platform {platform}"
                );
                let retry_parts = self.pull_image_args(image, auth, Some(platform));
                let retry_refs: Vec<&str> = retry_parts.iter().map(|s| s.as_str()).collect();
                match self.run_ctr_timeout(&retry_refs, 300) {
                    Ok(_) => {}
                    Err(retry_err) => {
                        if self.image_present(image).unwrap_or(false) {
                            return Ok(());
                        }
                        return Err(RuntimeError::ImagePull(format!("{image}: {retry_err}")));
                    }
                }
            }
            Err(e) => return Err(RuntimeError::ImagePull(format!("{image}: {e}"))),
        }
        Ok(())
    }

    fn create_pod(&self, spec: &PodSpec) -> Result<PodHandle, RuntimeError> {
        self.cleanup_container_family(spec.pod_id);
        let container_id = self.container_id(spec.pod_id);

        if let Some(status) = self.task_status_by_id(&container_id)? {
            if Self::task_adoptable(&status) {
                return Ok(PodHandle {
                    pod_id: spec.pod_id,
                    container_id,
                });
            }
        }

        // Build env vars
        let mut env = self.gpu_env(spec);
        for (name, value) in &spec.env_vars {
            env.push(format!("{name}={value}"));
        }
        if spec.port > 0 {
            env.push(format!("PORT={}", spec.port));
        }

        let mut args: Vec<String> = vec![
            "containers".into(),
            "create".into(),
            "--runtime".into(),
            self.runtime_name.clone(),
            "--snapshotter".into(),
            self.snapshotter.clone(),
        ];

        args.extend(self.gpu_device_args(spec));

        for e in &env {
            args.push("--env".into());
            args.push(e.clone());
        }

        for m in &spec.mounts {
            args.push("--mount".into());
            args.push(format!(
                "type=bind,src={},dst={},options=rbind:rw",
                m.host_path, m.container_path
            ));
        }

        // Positional: image, container_id, command args
        args.push(spec.image.clone());
        args.push(container_id.clone());

        if !spec.entrypoint.is_empty() {
            for part in spec.entrypoint.split_whitespace() {
                args.push(part.to_string());
            }
        }

        let arg_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
        self.run_ctr(&arg_refs)
            .map_err(|e| RuntimeError::ContainerCreate(format!("{container_id}: {e}")))?;

        self.apply_cgroup_limits(spec, &container_id);

        Ok(PodHandle {
            pod_id: spec.pod_id,
            container_id,
        })
    }

    fn start_pod(&self, handle: &PodHandle) -> Result<(), RuntimeError> {
        match self.run_ctr(&["tasks", "start", "--detach", &handle.container_id]) {
            Ok(_) => Ok(()),
            Err(e) if Self::task_already_exists_error(&e) => {
                if let Some(status) = self.task_status_by_id(&handle.container_id)? {
                    if Self::task_adoptable(&status) {
                        return Ok(());
                    }
                }
                self.cleanup_task_state(&handle.container_id);
                self.run_ctr(&["tasks", "start", "--detach", &handle.container_id])
                    .map(|_| ())
                    .map_err(|retry_err| {
                        RuntimeError::ContainerStart(format!(
                            "{}: {retry_err}",
                            handle.container_id
                        ))
                    })
            }
            Err(e) => {
                self.cleanup_task_state(&handle.container_id);
                self.run_ctr(&["tasks", "start", "--detach", &handle.container_id])
                    .map(|_| ())
                    .map_err(|retry_err| {
                        RuntimeError::ContainerStart(format!(
                            "{}: first start failed: {e}; retry after cleanup failed: {retry_err}",
                            handle.container_id
                        ))
                    })
            }
        }
    }

    fn forward_run(
        &self,
        handle: &PodHandle,
        port: u16,
        payload: &[u8],
    ) -> Result<Vec<u8>, RuntimeError> {
        let pid = self.task_pid(&handle.container_id)?;
        self.with_task_netns(pid, || crate::runtime::process::forward_run(port, payload))
            .map_err(|e| match e {
                RuntimeError::ResponseTooLarge(_) => e,
                other => {
                    RuntimeError::Internal(format!("forward run {}: {other}", handle.container_id))
                }
            })
    }

    fn stop_pod(&self, handle: &PodHandle, grace_period_ms: u64) -> Result<(), RuntimeError> {
        let _ = self.run_ctr(&["tasks", "kill", "--signal", "15", &handle.container_id]);
        thread::sleep(Duration::from_millis(grace_period_ms));
        let _ = self.run_ctr(&["tasks", "kill", "--signal", "9", &handle.container_id]);
        Ok(())
    }

    fn pod_status(&self, handle: &PodHandle) -> Result<PodStatus, RuntimeError> {
        let output = self.run_ctr(&["tasks", "list"]).map_err(|e| {
            RuntimeError::ContainerNotFound(format!("{}: {e}", handle.container_id))
        })?;

        Self::task_status_from_listing(&output, &handle.container_id)
            .ok_or_else(|| RuntimeError::ContainerNotFound(handle.container_id.clone()))
    }

    fn remove_pod(&self, handle: &PodHandle) -> Result<(), RuntimeError> {
        self.cleanup_task_state(&handle.container_id);
        Ok(())
    }
}

impl ContainerdRuntime {
    fn apply_cgroup_limits(&self, spec: &PodSpec, container_id: &str) {
        let cgroup_base = format!("/sys/fs/cgroup/system.slice/containerd-{container_id}.scope");

        if spec.cpu_millicores > 0 {
            let quota = (spec.cpu_millicores as i64) * 100;
            let _ = fs::write(format!("{cgroup_base}/cpu.max"), format!("{quota} 100000"));
        }

        if spec.memory_megabytes > 0 {
            let limit = (spec.memory_megabytes as u64) * 1024 * 1024;
            let _ = fs::write(format!("{cgroup_base}/memory.max"), limit.to_string());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pull_image_args_include_snapshotter_and_image() {
        let runtime = ContainerdRuntime::new(None, None, None, Some("overlayfs")).unwrap();
        let args = runtime.pull_image_args("docker.io/library/alpine:latest", None, None);
        assert_eq!(
            args,
            vec![
                "images",
                "pull",
                "--snapshotter",
                "overlayfs",
                "docker.io/library/alpine:latest",
            ]
        );
    }

    #[test]
    fn pull_image_args_include_platform_and_auth_when_requested() {
        let runtime = ContainerdRuntime::new(None, None, None, Some("overlayfs")).unwrap();
        let auth = super::super::ImagePullAuth {
            registry: "docker.io".into(),
            username: "user".into(),
            password: "pass".into(),
        };
        let args = runtime.pull_image_args(
            "docker.io/library/alpine:latest",
            Some(&auth),
            Some("linux/amd64"),
        );
        assert_eq!(
            args,
            vec![
                "images",
                "pull",
                "--snapshotter",
                "overlayfs",
                "--platform",
                "linux/amd64",
                "--user",
                "user:pass",
                "docker.io/library/alpine:latest",
            ]
        );
    }

    #[test]
    fn default_platform_maps_common_architectures() {
        let platform = ContainerdRuntime::default_platform();
        assert!(matches!(
            platform,
            "linux/amd64" | "linux/arm64" | "linux/arm/v7"
        ));
    }

    #[test]
    fn image_present_in_listing_matches_exact_reference() {
        let listing = "\
REF TYPE DIGEST SIZE PLATFORMS LABELS
docker.io/mendhak/http-https-echo:31 application/vnd.oci.image.index.v1+json sha256:abc 42.7 MiB linux/amd64 -
docker.io/library/busybox:1.36 application/vnd.oci.image.index.v1+json sha256:def 2.1 MiB linux/amd64 -
";
        assert!(ContainerdRuntime::image_present_in_listing(
            listing,
            "docker.io/mendhak/http-https-echo:31"
        ));
        assert!(ContainerdRuntime::image_present_in_listing(
            listing,
            "docker.io/library/busybox:1.36"
        ));
        assert!(!ContainerdRuntime::image_present_in_listing(
            listing,
            "docker.io/library/alpine:3.20"
        ));
    }

    #[test]
    fn task_status_from_listing_parses_container_status() {
        let listing = "TASK PID STATUS
hivemind-pod-7 123 RUNNING
hivemind-pod-8 0 CREATED
hivemind-pod-9 0 STOPPED
";

        assert_eq!(
            ContainerdRuntime::task_status_from_listing(listing, "hivemind-pod-7"),
            Some(PodStatus::Running)
        );
        assert_eq!(
            ContainerdRuntime::task_status_from_listing(listing, "hivemind-pod-8"),
            Some(PodStatus::Created)
        );
        assert_eq!(
            ContainerdRuntime::task_status_from_listing(listing, "hivemind-pod-9"),
            Some(PodStatus::Stopped { exit_code: 0 })
        );
        assert_eq!(
            ContainerdRuntime::task_status_from_listing(listing, "hivemind-pod-10"),
            None
        );
    }

    #[test]
    fn task_adoptable_accepts_live_or_unknown_tasks_only() {
        assert!(ContainerdRuntime::task_adoptable(&PodStatus::Running));
        assert!(ContainerdRuntime::task_adoptable(&PodStatus::Created));
        assert!(ContainerdRuntime::task_adoptable(&PodStatus::Unknown));
        assert!(!ContainerdRuntime::task_adoptable(&PodStatus::Stopped {
            exit_code: 0
        }));
    }

    #[test]
    fn task_shim_dir_uses_configured_namespace() {
        let runtime = ContainerdRuntime::new(None, Some("custom"), None, None).unwrap();
        assert_eq!(
            runtime.task_shim_dir("hivemind-pod-7"),
            "/run/containerd/io.containerd.runtime.v2.task/custom/hivemind-pod-7"
        );
    }

    #[test]
    fn container_id_adds_bounded_unique_attempt_suffix() {
        let runtime = ContainerdRuntime::new(None, None, None, None).unwrap();
        assert_eq!(runtime.container_id(42), "hivemind-pod-42-1");
        assert_eq!(runtime.container_id(42), "hivemind-pod-42-2");
        assert_eq!(
            ContainerdRuntime::container_id_prefix(42),
            "hivemind-pod-42"
        );
    }

    #[test]
    fn ids_with_prefix_matches_legacy_and_attempt_ids_only() {
        let listing = "CONTAINER IMAGE RUNTIME\n\
hivemind-pod-42 docker.io/library/nginx io.containerd.runc.v2\n\
hivemind-pod-42-1 docker.io/library/nginx io.containerd.runc.v2\n\
hivemind-pod-420-1 docker.io/library/nginx io.containerd.runc.v2\n\
other docker.io/library/nginx io.containerd.runc.v2\n";
        assert_eq!(
            ContainerdRuntime::ids_with_prefix(listing, "hivemind-pod-42", 64),
            vec![
                "hivemind-pod-42".to_string(),
                "hivemind-pod-42-1".to_string()
            ]
        );
    }

    #[test]
    fn task_already_exists_error_matches_ctr_output() {
        assert!(ContainerdRuntime::task_already_exists_error(
            "ctr: task hivemind-pod-1: already exists"
        ));
        assert!(!ContainerdRuntime::task_already_exists_error(
            "ctr: task hivemind-pod-1: not found"
        ));
    }

    #[test]
    fn format_ctr_error_includes_command_exit_stdout_and_stderr() {
        let error = ContainerdRuntime::format_ctr_error(
            &["tasks", "start", "--detach", "hivemind-pod-1"],
            1,
            30,
            "actual stdout",
            "warning plus failure",
        );
        assert!(error.contains("ctr tasks start --detach hivemind-pod-1"));
        assert!(error.contains("exit code 1"));
        assert!(error.contains("stdout: actual stdout"));
        assert!(error.contains("stderr: warning plus failure"));
    }

    #[test]
    fn format_ctr_error_identifies_timeout() {
        let error = ContainerdRuntime::format_ctr_error(&["tasks", "start"], 124, 30, "", "");
        assert_eq!(error, "ctr tasks start: timed out after 30s");
    }

    #[test]
    fn gpu_device_args_use_cdi_devices_per_requested_gpu() {
        let runtime = ContainerdRuntime::new(None, None, None, Some("overlayfs")).unwrap();
        let spec = PodSpec {
            pod_id: 7,
            deployment_id: 1,
            image: "docker.io/mendhak/http-https-echo:31".into(),
            cpu_millicores: 500,
            memory_megabytes: 512,
            env_vars: vec![],
            mounts: vec![],
            entrypoint: String::new(),
            port: 8080,
            gpu_count: 2,
            gpu_type: crate::types::GpuType::T4,
        };

        assert_eq!(runtime.runtime_name, "io.containerd.runc.v2");
        assert_eq!(
            runtime.gpu_device_args(&spec),
            vec![
                "--device",
                "nvidia.com/gpu=0",
                "--device",
                "nvidia.com/gpu=1",
            ]
        );
    }
}
