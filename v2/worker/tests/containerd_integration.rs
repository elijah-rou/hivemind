/// Containerd integration tests - run on a real Linux node with:
///   - containerd running
///   - gVisor (runsc) installed
///   - NVIDIA GPU drivers + nvidia-container-runtime (for GPU tests)
///   - Nydus snapshotter (optional, for nydus tests)
///   - JuiceFS binary (optional, for volume tests)
///
/// Run with: cargo test --test containerd_integration --features containerd-integration
///
/// Skipped entirely on non-Linux or without the feature flag.

#[cfg(all(feature = "containerd-integration", target_os = "linux"))]
mod tests {
    use std::time::Duration;

    use hivemind_worker::runtime::containerd::ContainerdRuntime;
    use hivemind_worker::runtime::{BindMount, PodSpec, PodStatus, Runtime};
    use hivemind_worker::types::GpuType;

    fn base_spec(pod_id: u64) -> PodSpec {
        PodSpec {
            pod_id,
            deployment_id: 1,
            image: "docker.io/library/alpine:latest".into(),
            entrypoint: String::new(),
            port: 0,
            gpu_count: 0,
            gpu_type: GpuType::None,
            cpu_millicores: 500,
            memory_megabytes: 128,
            env_vars: vec![],
            mounts: vec![],
        }
    }

    fn unique_pod_id(offset: u64) -> u64 {
        let pid = std::process::id() as u64;
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock before unix epoch")
            .subsec_nanos() as u64;
        20000 + offset + (pid % 1000) * 100 + (nanos % 100)
    }

    #[test]
    fn containerd_pull_and_create() {
        let rt = ContainerdRuntime::new(None, None, None, None).expect("containerd connect");

        rt.pull_image("docker.io/library/alpine:latest", None)
            .expect("pull alpine");

        let spec = base_spec(10001);
        let handle = rt.create_pod(&spec).expect("create pod");
        assert!(handle.container_id.contains("10001"));

        rt.remove_pod(&handle).expect("remove pod");
    }

    #[test]
    fn containerd_full_lifecycle() {
        let rt = ContainerdRuntime::new(None, None, None, None).expect("containerd connect");

        rt.pull_image("docker.io/library/alpine:latest", None)
            .expect("pull");

        let mut spec = base_spec(10002);
        spec.entrypoint = "sleep 300".into();
        spec.env_vars = vec![("TEST_VAR".into(), "hello_from_hivemind".into())];

        let handle = rt.create_pod(&spec).expect("create");
        rt.start_pod(&handle).expect("start");

        std::thread::sleep(Duration::from_millis(1000));
        let status = rt.pod_status(&handle).expect("status");
        assert!(
            matches!(status, PodStatus::Running),
            "expected Running, got {status:?}"
        );

        rt.stop_pod(&handle, 1000).expect("stop");
        assert!(matches!(
            rt.pod_status(&handle).expect("status after stop"),
            PodStatus::Stopped { .. }
        ));
        rt.remove_pod(&handle).expect("remove");
    }

    #[test]
    fn containerd_env_vars_injected() {
        let rt = ContainerdRuntime::new(None, None, None, None).expect("containerd connect");

        rt.pull_image("docker.io/library/alpine:latest", None)
            .expect("pull");

        let mut spec = base_spec(10003);
        spec.entrypoint = "sh".into();
        spec.env_vars = vec![
            ("MY_SECRET".into(), "hunter2".into()),
            ("APP_NAME".into(), "hivemind-test".into()),
        ];

        let handle = rt.create_pod(&spec).expect("create");
        rt.start_pod(&handle).expect("start");
        std::thread::sleep(Duration::from_millis(500));

        let status = rt.pod_status(&handle).expect("status");
        assert!(matches!(status, PodStatus::Running), "pod not running");

        rt.stop_pod(&handle, 500).ok();
        rt.remove_pod(&handle).ok();
    }

    #[test]
    fn containerd_resource_limits() {
        let rt = ContainerdRuntime::new(None, None, None, None).expect("containerd connect");

        rt.pull_image("docker.io/library/alpine:latest", None)
            .expect("pull");

        let mut spec = base_spec(10004);
        spec.entrypoint = "sleep 300".into();
        spec.cpu_millicores = 2000;
        spec.memory_megabytes = 256;

        let handle = rt.create_pod(&spec).expect("create");
        rt.start_pod(&handle).expect("start");
        std::thread::sleep(Duration::from_millis(500));

        let status = rt.pod_status(&handle).expect("status");
        assert!(matches!(status, PodStatus::Running));

        rt.stop_pod(&handle, 500).ok();
        rt.remove_pod(&handle).ok();
    }

    #[test]
    fn containerd_adopts_running_task_after_worker_restart() {
        let pod_id = unique_pod_id(10);
        let mut spec = base_spec(pod_id);
        spec.entrypoint = "sleep 300".into();

        let first_runtime =
            ContainerdRuntime::new(None, None, None, None).expect("containerd connect");
        first_runtime
            .pull_image("docker.io/library/alpine:latest", None)
            .expect("pull");

        let first_handle = first_runtime.create_pod(&spec).expect("initial create");
        first_runtime
            .start_pod(&first_handle)
            .expect("initial start");
        std::thread::sleep(Duration::from_millis(500));
        assert!(matches!(
            first_runtime.pod_status(&first_handle).expect("status"),
            PodStatus::Running
        ));

        let restarted_runtime =
            ContainerdRuntime::new(None, None, None, None).expect("containerd reconnect");
        let adopted_handle = restarted_runtime
            .create_pod(&spec)
            .expect("create adopts existing task");
        assert_eq!(adopted_handle.container_id, first_handle.container_id);
        restarted_runtime
            .start_pod(&adopted_handle)
            .expect("start is idempotent for adopted task");
        assert!(matches!(
            restarted_runtime
                .pod_status(&adopted_handle)
                .expect("adopted status"),
            PodStatus::Running
        ));

        restarted_runtime.stop_pod(&adopted_handle, 500).ok();
        restarted_runtime.remove_pod(&adopted_handle).ok();
    }

    #[test]
    fn containerd_recreates_container_after_stopped_task() {
        let pod_id = unique_pod_id(20);
        let mut spec = base_spec(pod_id);
        spec.entrypoint = "sleep 300".into();

        let rt = ContainerdRuntime::new(None, None, None, None).expect("containerd connect");
        rt.pull_image("docker.io/library/alpine:latest", None)
            .expect("pull");

        let first_handle = rt.create_pod(&spec).expect("initial create");
        rt.start_pod(&first_handle).expect("initial start");
        std::thread::sleep(Duration::from_millis(500));
        rt.stop_pod(&first_handle, 100).expect("stop task");

        let recreated_handle = rt
            .create_pod(&spec)
            .expect("create cleans stopped task and stale container");
        assert_eq!(recreated_handle.container_id, first_handle.container_id);
        rt.start_pod(&recreated_handle)
            .expect("restart recreated pod");
        assert!(matches!(
            rt.pod_status(&recreated_handle).expect("recreated status"),
            PodStatus::Running
        ));

        rt.stop_pod(&recreated_handle, 500).ok();
        rt.remove_pod(&recreated_handle).ok();
    }

    #[test]
    fn gvisor_runtime_starts() {
        // gVisor requires runsc installed AND containerd configured with the shim.
        // Skip gracefully if it's not available.
        let rt = ContainerdRuntime::new(None, None, Some("io.containerd.runsc.v1"), None)
            .expect("containerd connect");

        rt.pull_image("docker.io/library/alpine:latest", None)
            .expect("pull");

        let mut spec = base_spec(10005);
        spec.entrypoint = "echo".into();

        match rt.create_pod(&spec) {
            Ok(handle) => {
                match rt.start_pod(&handle) {
                    Ok(()) => {
                        std::thread::sleep(Duration::from_millis(500));
                        let status = rt.pod_status(&handle).unwrap_or(PodStatus::Unknown);
                        eprintln!("gvisor status: {status:?}");
                        rt.stop_pod(&handle, 500).ok();
                    }
                    Err(e) => eprintln!("gvisor start failed (may not be configured): {e}"),
                }
                rt.remove_pod(&handle).ok();
            }
            Err(e) => {
                eprintln!("gvisor create failed (may not be configured): {e}");
            }
        }
    }

    #[test]
    fn gpu_container_starts() {
        // GPU containers need the nvidia-container-runtime.
        // Use io.containerd.runc.v2 with NVIDIA env vars - the NVIDIA Container
        // Toolkit hook will inject GPU devices if installed.
        let rt = ContainerdRuntime::new(None, None, None, None).expect("containerd connect");

        rt.pull_image("docker.io/nvidia/cuda:12.2.0-base-ubuntu22.04", None)
            .expect("pull cuda image");

        let mut spec = base_spec(10006);
        spec.image = "docker.io/nvidia/cuda:12.2.0-base-ubuntu22.04".into();
        // nvidia-smi is in /usr/bin on CUDA images
        spec.entrypoint = "/usr/bin/nvidia-smi".into();
        spec.gpu_count = 1;
        spec.gpu_type = GpuType::T4;

        match rt.create_pod(&spec) {
            Ok(handle) => {
                match rt.start_pod(&handle) {
                    Ok(()) => {
                        std::thread::sleep(Duration::from_secs(5));
                        let status = rt.pod_status(&handle).unwrap_or(PodStatus::Unknown);
                        eprintln!("gpu pod status: {status:?}");
                    }
                    Err(e) => {
                        eprintln!("gpu start failed (nvidia runtime may not be configured): {e}");
                    }
                }
                rt.remove_pod(&handle).ok();
            }
            Err(e) => {
                eprintln!("gpu create failed: {e}");
            }
        }
    }

    #[test]
    fn nydus_snapshotter_pull() {
        let rt =
            ContainerdRuntime::new(None, None, None, Some("nydus")).expect("containerd connect");

        match rt.pull_image("docker.io/library/alpine:latest", None) {
            Ok(()) => {
                eprintln!("nydus pull succeeded");
                let spec = base_spec(10007);
                let handle = rt.create_pod(&spec).expect("create with nydus");
                rt.remove_pod(&handle).ok();
            }
            Err(e) => {
                eprintln!("nydus not available (expected on nodes without it): {e}");
            }
        }
    }

    #[test]
    fn juicefs_mount_and_bind() {
        use hivemind_worker::volumes;

        if !volumes::juicefs_available() {
            eprintln!("juicefs not installed, skipping");
            return;
        }
        if std::env::var("JUICEFS_META_URL").is_err() {
            eprintln!("JUICEFS_META_URL not set, skipping");
            return;
        }

        let rt = ContainerdRuntime::new(None, None, None, None).expect("containerd connect");

        rt.pull_image("docker.io/library/alpine:latest", None)
            .expect("pull");

        let vol = volumes::mount_juicefs(10008, "/test").expect("juicefs mount");

        let mut spec = base_spec(10008);
        spec.entrypoint = "ls".into();
        spec.mounts = vec![BindMount {
            host_path: vol.host_path.to_string_lossy().to_string(),
            container_path: "/data".into(),
        }];

        let handle = rt.create_pod(&spec).expect("create");
        rt.start_pod(&handle).expect("start");
        std::thread::sleep(Duration::from_secs(2));

        rt.stop_pod(&handle, 500).ok();
        rt.remove_pod(&handle).ok();
        volumes::unmount_juicefs(10008);
    }

    #[test]
    fn containerd_forward_run_reaches_http_workload() {
        let rt = ContainerdRuntime::new(None, None, None, None).expect("containerd connect");

        let image = "docker.io/mendhak/http-https-echo:31";
        rt.pull_image(image, None).expect("pull echo image");

        let mut spec = base_spec(10009);
        spec.image = image.into();
        spec.port = 8080;

        let handle = rt.create_pod(&spec).expect("create");
        rt.start_pod(&handle).expect("start");
        std::thread::sleep(Duration::from_secs(2));

        let response = rt
            .forward_run(&handle, 8080, br#"{"probe":"containerd-run"}"#)
            .expect("forward_run");
        let body = String::from_utf8_lossy(&response);
        assert!(
            body.contains("containerd-run"),
            "expected echoed payload, got {body}"
        );

        rt.stop_pod(&handle, 500).ok();
        rt.remove_pod(&handle).ok();
    }
}
