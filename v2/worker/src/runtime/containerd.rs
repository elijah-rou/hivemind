use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use super::{PodHandle, PodSpec, PodStatus, Runtime, RuntimeError, MAX_STOP_GRACE_MS};

const DEFAULT_SOCKET: &str = "/run/containerd/containerd.sock";
const DEFAULT_NAMESPACE: &str = "hivemind";
const CTR_TIMEOUT_SECS: u64 = 30;
const AUTH_CONFIG_MAX_BYTES: usize = 4096;
static AUTH_CONFIG_SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct RegistryHosts {
    root: PathBuf,
    redactions: Vec<String>,
}

impl Drop for RegistryHosts {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.root) {
            eprintln!("containerd: protected registry configuration cleanup failed: {error}");
        }
    }
}

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

    fn base64(input: &[u8]) -> String {
        const ALPHABET: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut encoded = String::with_capacity(input.len().div_ceil(3) * 4);
        for chunk in input.chunks(3) {
            let value = (u32::from(chunk[0]) << 16)
                | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
                | u32::from(*chunk.get(2).unwrap_or(&0));
            encoded.push(ALPHABET[((value >> 18) & 0x3f) as usize] as char);
            encoded.push(ALPHABET[((value >> 12) & 0x3f) as usize] as char);
            encoded.push(if chunk.len() > 1 {
                ALPHABET[((value >> 6) & 0x3f) as usize] as char
            } else {
                '='
            });
            encoded.push(if chunk.len() > 2 {
                ALPHABET[(value & 0x3f) as usize] as char
            } else {
                '='
            });
        }
        encoded
    }

    fn registry_hosts_toml(auth: &super::ImagePullAuth) -> Result<String, RuntimeError> {
        if auth.registry.is_empty()
            || !auth.registry.bytes().all(|byte| {
                byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b':' | b'[' | b']')
            })
        {
            return Err(RuntimeError::ImagePull(
                "registry host contains unsupported characters".into(),
            ));
        }
        let credentials = format!("{}:{}", auth.username, auth.password);
        let authorization = Self::base64(credentials.as_bytes());
        let config = format!(
            "server = \"https://{0}\"\n\n[host.\"https://{0}\"]\n  capabilities = [\"pull\", \"resolve\"]\n  [host.\"https://{0}\".header]\n    authorization = \"Basic {1}\"\n",
            auth.registry, authorization
        );
        if config.len() > AUTH_CONFIG_MAX_BYTES {
            return Err(RuntimeError::ImagePull(
                "registry authentication configuration exceeds size limit".into(),
            ));
        }
        Ok(config)
    }

    fn prepare_registry_hosts(auth: &super::ImagePullAuth) -> Result<RegistryHosts, RuntimeError> {
        let config = Self::registry_hosts_toml(auth)?;
        let sequence = AUTH_CONFIG_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "hivemind-registry-auth-{}-{sequence}",
            std::process::id()
        ));
        fs::create_dir(&root).map_err(|error| {
            RuntimeError::ImagePull(format!("create protected registry config: {error}"))
        })?;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).map_err(|error| {
            let _ = fs::remove_dir_all(&root);
            RuntimeError::ImagePull(format!("protect registry config directory: {error}"))
        })?;
        let host_dir = root.join(&auth.registry);
        fs::create_dir(&host_dir).map_err(|error| {
            let _ = fs::remove_dir_all(&root);
            RuntimeError::ImagePull(format!("create registry host config: {error}"))
        })?;
        let config_path = host_dir.join("hosts.toml");
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&config_path)
            .map_err(|error| {
                let _ = fs::remove_dir_all(&root);
                RuntimeError::ImagePull(format!("create registry hosts config: {error}"))
            })?;
        file.write_all(config.as_bytes()).map_err(|error| {
            let _ = fs::remove_dir_all(&root);
            RuntimeError::ImagePull(format!("write registry hosts config: {error}"))
        })?;
        file.sync_all().map_err(|error| {
            let _ = fs::remove_dir_all(&root);
            RuntimeError::ImagePull(format!("sync registry hosts config: {error}"))
        })?;
        Ok(RegistryHosts {
            root,
            redactions: vec![
                auth.username.clone(),
                auth.password.clone(),
                Self::base64(format!("{}:{}", auth.username, auth.password).as_bytes()),
            ],
        })
    }

    fn pull_image_args(
        &self,
        image: &str,
        hosts_dir: Option<&str>,
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

        if let Some(hosts_dir) = hosts_dir {
            parts.push("--hosts-dir".into());
            parts.push(hosts_dir.to_string());
        }

        parts.push(image.to_string());
        parts
    }

    fn run_ctr(&self, args: &[&str]) -> Result<String, String> {
        self.run_ctr_timeout(args, CTR_TIMEOUT_SECS)
    }

    fn run_ctr_timeout(&self, args: &[&str], timeout_secs: u64) -> Result<String, String> {
        self.run_ctr_duration(args, Duration::from_secs(timeout_secs), &[])
    }

    fn run_ctr_until(&self, args: &[&str], deadline: Instant) -> Result<String, String> {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err("ctr shutdown deadline reached".into());
        }
        self.run_ctr_duration(args, remaining, &[])
    }

    fn run_ctr_duration(
        &self,
        args: &[&str],
        timeout: Duration,
        redactions: &[String],
    ) -> Result<String, String> {
        assert!(!timeout.is_zero(), "ctr timeout must be positive");
        let timeout_ms = timeout.as_millis().clamp(1, u64::MAX as u128) as u64;
        // Use timeout(1) to prevent indefinite hangs (e.g. gVisor shim issues).
        let output = Command::new("timeout")
            .arg(format!("{timeout_ms}ms"))
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
                args, code, timeout_ms, &stdout, &stderr, redactions,
            ));
        }

        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    fn format_ctr_error(
        args: &[&str],
        code: i32,
        timeout_ms: u64,
        stdout: &str,
        stderr: &str,
        redactions: &[String],
    ) -> String {
        let redact = |value: &str| {
            redactions.iter().fold(value.to_string(), |text, secret| {
                if secret.is_empty() {
                    text
                } else {
                    text.replace(secret, "[REDACTED]")
                }
            })
        };
        let command = redact(&args.join(" "));
        if code == 124 {
            return format!("ctr {command}: timed out after {timeout_ms}ms");
        }

        let stdout = redact(stdout.trim());
        let stderr = redact(stderr.trim());
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

    fn cleanup_task_state(&self, container_id: &str) -> Result<(), RuntimeError> {
        self.cleanup_task_state_until(
            container_id,
            Instant::now() + Duration::from_secs(CTR_TIMEOUT_SECS * 5),
        )
    }

    fn cleanup_task_state_until(
        &self,
        container_id: &str,
        deadline: Instant,
    ) -> Result<(), RuntimeError> {
        let kill_error = self
            .run_ctr_until(&["tasks", "kill", "--signal", "9", container_id], deadline)
            .err();
        let task_delete_error = self
            .run_ctr_until(&["tasks", "delete", "--force", container_id], deadline)
            .err();
        let container_delete_error = self
            .run_ctr_until(&["containers", "delete", container_id], deadline)
            .err();
        let shim_dir = self.task_shim_dir(container_id);
        let shim_remove_error = match fs::remove_dir_all(&shim_dir) {
            Ok(()) => None,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => Some(error.to_string()),
        };

        let tasks = self
            .run_ctr_until(&["tasks", "list"], deadline)
            .map_err(|error| {
                RuntimeError::ContainerStop(format!(
                    "{container_id} cleanup task verification failed: {error}"
                ))
            })?;
        let containers = self
            .run_ctr_until(&["containers", "list"], deadline)
            .map_err(|error| {
                RuntimeError::ContainerStop(format!(
                    "{container_id} cleanup container verification failed: {error}"
                ))
            })?;
        let task_remains = Self::listing_contains_exact_id(&tasks, container_id);
        let container_remains = Self::listing_contains_exact_id(&containers, container_id);
        let shim_remains = Path::new(&shim_dir).exists();
        if task_remains || container_remains || shim_remains {
            return Err(RuntimeError::ContainerStop(format!(
                "{container_id} cleanup remains unverified: task_remains={task_remains} container_remains={container_remains} shim_remains={shim_remains}; kill={}; task_delete={}; container_delete={}; shim_remove={}",
                kill_error.as_deref().unwrap_or("ok"),
                task_delete_error.as_deref().unwrap_or("ok"),
                container_delete_error.as_deref().unwrap_or("ok"),
                shim_remove_error.as_deref().unwrap_or("ok")
            )));
        }
        Ok(())
    }

    fn listing_contains_exact_id(listing: &str, container_id: &str) -> bool {
        listing
            .lines()
            .skip(1)
            .filter_map(|line| line.split_whitespace().next())
            .any(|id| id == container_id)
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

    fn adoptable_container_id_from_listings(
        pod_id: u64,
        task_listing: &str,
        container_listing: &str,
    ) -> Result<Option<String>, RuntimeError> {
        const MAX_FAMILY_IDS: usize = 64;
        let prefix = Self::container_id_prefix(pod_id);
        let task_ids = Self::ids_with_prefix(task_listing, &prefix, MAX_FAMILY_IDS + 1);
        let container_ids = Self::ids_with_prefix(container_listing, &prefix, MAX_FAMILY_IDS + 1);
        if task_ids.len() > MAX_FAMILY_IDS || container_ids.len() > MAX_FAMILY_IDS {
            return Err(RuntimeError::ContainerCreate(format!(
                "{prefix} runtime family exceeds {MAX_FAMILY_IDS} entries"
            )));
        }
        let mut adoptable = task_ids.into_iter().filter(|id| {
            container_ids.contains(id)
                && Self::task_status_from_listing(task_listing, id)
                    .is_some_and(|status| Self::task_adoptable(&status))
        });
        let candidate = adoptable.next();
        if adoptable.next().is_some() {
            return Err(RuntimeError::ContainerCreate(format!(
                "{prefix} has multiple adoptable owned tasks"
            )));
        }
        Ok(candidate)
    }

    fn find_adoptable_container(&self, pod_id: u64) -> Result<Option<String>, RuntimeError> {
        let prefix = Self::container_id_prefix(pod_id);
        let tasks = self.run_ctr(&["tasks", "list"]).map_err(|error| {
            RuntimeError::ContainerCreate(format!("{prefix} task inventory failed: {error}"))
        })?;
        let containers = self.run_ctr(&["containers", "list"]).map_err(|error| {
            RuntimeError::ContainerCreate(format!("{prefix} container inventory failed: {error}"))
        })?;
        Self::adoptable_container_id_from_listings(pod_id, &tasks, &containers)
    }

    fn cleanup_container_family(&self, pod_id: u64) -> Result<(), RuntimeError> {
        const MAX_STALE_IDS: usize = 64;
        let prefix = Self::container_id_prefix(pod_id);
        let task_listing = self.run_ctr(&["tasks", "list"]).map_err(|error| {
            RuntimeError::ContainerCreate(format!("{prefix} task inventory failed: {error}"))
        })?;
        let container_listing = self.run_ctr(&["containers", "list"]).map_err(|error| {
            RuntimeError::ContainerCreate(format!("{prefix} container inventory failed: {error}"))
        })?;
        let mut ids = Self::ids_with_prefix(&task_listing, &prefix, MAX_STALE_IDS + 1);
        let container_ids = Self::ids_with_prefix(&container_listing, &prefix, MAX_STALE_IDS + 1);
        if ids.len() > MAX_STALE_IDS || container_ids.len() > MAX_STALE_IDS {
            return Err(RuntimeError::ContainerCreate(format!(
                "{prefix} stale runtime family exceeds {MAX_STALE_IDS} entries"
            )));
        }
        for id in container_ids {
            if !ids.contains(&id) {
                if ids.len() >= MAX_STALE_IDS {
                    return Err(RuntimeError::ContainerCreate(format!(
                        "{prefix} stale runtime family exceeds {MAX_STALE_IDS} entries"
                    )));
                }
                ids.push(id);
            }
        }
        for id in ids {
            self.cleanup_task_state(&id)?;
        }
        Ok(())
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
        T: Send,
        F: FnOnce() -> Result<T, RuntimeError> + Send,
    {
        std::thread::scope(|scope| {
            scope
                .spawn(move || {
                    let current_ns = File::open("/proc/self/ns/net")
                        .map_err(|e| RuntimeError::Internal(format!("open current netns: {e}")))?;
                    let target_ns = File::open(format!("/proc/{pid}/ns/net")).map_err(|e| {
                        RuntimeError::Internal(format!("open task netns for pid {pid}: {e}"))
                    })?;

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
                })
                .join()
                .expect("network namespace worker panicked")
        })
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

        let registry_hosts = auth.map(Self::prepare_registry_hosts).transpose()?;
        let hosts_dir = match registry_hosts.as_ref() {
            Some(hosts) => Some(hosts.root.to_str().ok_or_else(|| {
                RuntimeError::ImagePull("registry hosts path is not UTF-8".into())
            })?),
            None => None,
        };
        let parts = self.pull_image_args(image, hosts_dir, None);
        let refs: Vec<&str> = parts.iter().map(|s| s.as_str()).collect();
        let redactions = registry_hosts
            .as_ref()
            .map(|hosts| hosts.redactions.as_slice())
            .unwrap_or(&[]);

        // Image pulls can be slow, use a longer timeout.
        match self.run_ctr_duration(&refs, Duration::from_secs(300), redactions) {
            Ok(_) => {}
            Err(e) if e.contains("no unpack platforms defined") => {
                let platform = Self::default_platform();
                eprintln!(
                    "containerd: retrying image pull for {image} with explicit platform {platform}"
                );
                let retry_parts = self.pull_image_args(image, hosts_dir, Some(platform));
                let retry_refs: Vec<&str> = retry_parts.iter().map(|s| s.as_str()).collect();
                match self.run_ctr_duration(&retry_refs, Duration::from_secs(300), redactions) {
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
        if spec.gpu_count > 0 {
            return Err(RuntimeError::ContainerCreate(
                "GPU workload rejected: physical device reservation is not implemented".into(),
            ));
        }
        if let Some(container_id) = self.find_adoptable_container(spec.pod_id)? {
            return Ok(PodHandle {
                pod_id: spec.pod_id,
                container_id,
            });
        }
        self.cleanup_container_family(spec.pod_id)?;
        let container_id = self.container_id(spec.pod_id);

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
            Err(error) if Self::task_already_exists_error(&error) => {
                if let Some(status) = self.task_status_by_id(&handle.container_id)? {
                    if Self::task_adoptable(&status) {
                        return Ok(());
                    }
                }
                Err(RuntimeError::ContainerStart(format!(
                    "{}: {error}",
                    handle.container_id
                )))
            }
            Err(error) => Err(RuntimeError::ContainerStart(format!(
                "{}: {error}",
                handle.container_id
            ))),
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

    fn probe_pod(&self, handle: &PodHandle, port: u16, path: &str) -> Result<bool, RuntimeError> {
        let pid = self.task_pid(&handle.container_id)?;
        self.with_task_netns(pid, || {
            crate::runtime::process::probe_http(port, path).map_err(RuntimeError::Internal)
        })
        .map_err(|error| {
            RuntimeError::Internal(format!("probe pod {}: {error}", handle.container_id))
        })
    }

    fn stop_pod(&self, handle: &PodHandle, grace_period_ms: u64) -> Result<(), RuntimeError> {
        self.stop_pod_until(
            handle,
            grace_period_ms,
            Instant::now()
                + Duration::from_millis(grace_period_ms.min(MAX_STOP_GRACE_MS))
                + Duration::from_secs(CTR_TIMEOUT_SECS * 4),
        )
    }

    fn pod_status(&self, handle: &PodHandle) -> Result<PodStatus, RuntimeError> {
        let output = self.run_ctr(&["tasks", "list"]).map_err(|e| {
            RuntimeError::ContainerNotFound(format!("{}: {e}", handle.container_id))
        })?;

        Self::task_status_from_listing(&output, &handle.container_id)
            .ok_or_else(|| RuntimeError::ContainerNotFound(handle.container_id.clone()))
    }

    fn remove_pod(&self, handle: &PodHandle) -> Result<(), RuntimeError> {
        self.cleanup_task_state(&handle.container_id)
    }

    fn stop_pod_until(
        &self,
        handle: &PodHandle,
        grace_period_ms: u64,
        deadline: Instant,
    ) -> Result<(), RuntimeError> {
        let terminate_error = self
            .run_ctr_until(
                &["tasks", "kill", "--signal", "15", &handle.container_id],
                deadline,
            )
            .err();
        let grace_deadline = (Instant::now()
            + Duration::from_millis(grace_period_ms.min(MAX_STOP_GRACE_MS)))
        .min(deadline);
        loop {
            if matches!(
                self.pod_status_until(handle, deadline),
                Ok(PodStatus::Stopped { .. })
            ) {
                return Ok(());
            }
            let now = Instant::now();
            if now >= grace_deadline {
                break;
            }
            thread::sleep((grace_deadline - now).min(Duration::from_millis(100)));
        }

        let kill_error = self
            .run_ctr_until(
                &["tasks", "kill", "--signal", "9", &handle.container_id],
                deadline,
            )
            .err();
        match self.pod_status_until(handle, deadline) {
            Ok(PodStatus::Stopped { .. }) => Ok(()),
            Ok(status) => Err(RuntimeError::ContainerStop(format!(
                "{} remains {status:?} after TERM/KILL; TERM={}; KILL={}",
                handle.container_id,
                terminate_error.as_deref().unwrap_or("ok"),
                kill_error.as_deref().unwrap_or("ok")
            ))),
            Err(status_error) => Err(RuntimeError::ContainerStop(format!(
                "{} terminal status unverified after TERM/KILL: {status_error}; TERM={}; KILL={}",
                handle.container_id,
                terminate_error.as_deref().unwrap_or("ok"),
                kill_error.as_deref().unwrap_or("ok")
            ))),
        }
    }

    fn pod_status_until(
        &self,
        handle: &PodHandle,
        deadline: Instant,
    ) -> Result<PodStatus, RuntimeError> {
        let output = self
            .run_ctr_until(&["tasks", "list"], deadline)
            .map_err(|e| {
                RuntimeError::ContainerNotFound(format!("{}: {e}", handle.container_id))
            })?;
        Self::task_status_from_listing(&output, &handle.container_id)
            .ok_or_else(|| RuntimeError::ContainerNotFound(handle.container_id.clone()))
    }

    fn remove_pod_until(&self, handle: &PodHandle, deadline: Instant) -> Result<(), RuntimeError> {
        self.cleanup_task_state_until(&handle.container_id, deadline)
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
    fn pull_image_credentials_are_not_exposed_in_argv_or_config_errors() {
        let runtime = ContainerdRuntime::new(None, None, None, Some("overlayfs")).unwrap();
        let auth = super::super::ImagePullAuth {
            registry: "docker.io".into(),
            username: "private-user".into(),
            password: "private-password".into(),
        };
        let args = runtime.pull_image_args(
            "docker.io/library/alpine:latest",
            Some("/tmp/protected-hosts"),
            Some("linux/amd64"),
        );
        let command = args.join(" ");
        assert!(command.contains("--hosts-dir /tmp/protected-hosts"));
        assert!(!command.contains("private-user"));
        assert!(!command.contains("private-password"));

        let config = ContainerdRuntime::registry_hosts_toml(&auth).unwrap();
        assert!(!config.contains("private-user"));
        assert!(!config.contains("private-password"));
        let error = ContainerdRuntime::format_ctr_error(
            &["images", "pull", "--hosts-dir", "/tmp/protected-hosts"],
            1,
            30_000,
            "authentication failed for private-user",
            "bad password private-password",
            &["private-user".into(), "private-password".into()],
        );
        assert!(!error.contains("private-user"));
        assert!(!error.contains("private-password"));
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
    fn exact_id_listing_verification_rejects_prefix_matches() {
        let listing = "TASK PID STATUS\n\
hivemind-pod-7-1 123 RUNNING\n\
hivemind-pod-70-1 456 RUNNING\n";
        assert!(ContainerdRuntime::listing_contains_exact_id(
            listing,
            "hivemind-pod-7-1"
        ));
        assert!(!ContainerdRuntime::listing_contains_exact_id(
            listing,
            "hivemind-pod-7"
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
    fn adoption_selects_one_live_task_before_stale_cleanup() {
        let tasks = "TASK PID STATUS\n\
hivemind-pod-42-1 123 RUNNING\n\
hivemind-pod-42-2 0 STOPPED\n";
        let containers = "CONTAINER IMAGE RUNTIME\n\
hivemind-pod-42-1 image runtime\n\
hivemind-pod-42-2 image runtime\n";
        assert_eq!(
            ContainerdRuntime::adoptable_container_id_from_listings(42, tasks, containers).unwrap(),
            Some("hivemind-pod-42-1".to_string())
        );
    }

    #[test]
    fn adoption_rejects_ambiguous_live_task_family() {
        let tasks = "TASK PID STATUS\n\
hivemind-pod-42-1 123 RUNNING\n\
hivemind-pod-42-2 456 RUNNING\n";
        let containers = "CONTAINER IMAGE RUNTIME\n\
hivemind-pod-42-1 image runtime\n\
hivemind-pod-42-2 image runtime\n";
        assert!(
            ContainerdRuntime::adoptable_container_id_from_listings(42, tasks, containers).is_err()
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
            30_000,
            "actual stdout",
            "warning plus failure",
            &[],
        );
        assert!(error.contains("ctr tasks start --detach hivemind-pod-1"));
        assert!(error.contains("exit code 1"));
        assert!(error.contains("stdout: actual stdout"));
        assert!(error.contains("stderr: warning plus failure"));
    }

    #[test]
    fn format_ctr_error_identifies_timeout() {
        let error =
            ContainerdRuntime::format_ctr_error(&["tasks", "start"], 124, 30_000, "", "", &[]);
        assert_eq!(error, "ctr tasks start: timed out after 30000ms");
    }

    #[test]
    fn gpu_workload_is_rejected_without_physical_device_reservation() {
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

        let error = runtime
            .create_pod(&spec)
            .expect_err("GPU create must fail closed");
        assert!(error.to_string().contains("physical device reservation"));
    }
}
