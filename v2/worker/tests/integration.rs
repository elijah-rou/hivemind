/// Integration tests for the agent pipeline.
///
/// These tests exercise the real process runtime (spawns Python subprocesses)
/// to verify env vars, entrypoint, port injection, and the full pod lifecycle.
///
/// Run with: cargo test --test integration -- --test-threads=1
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use hivemind_worker::message::*;
use hivemind_worker::runtime::process::{forward_run, ProcessRuntime};
use hivemind_worker::runtime::{PodSpec, PodStatus, Runtime};
use hivemind_worker::types::GpuType;

fn http_get(port: u16, path: &str) -> Result<String, String> {
    let mut stream =
        TcpStream::connect(format!("127.0.0.1:{port}")).map_err(|e| format!("connect: {e}"))?;
    stream.set_read_timeout(Some(Duration::from_secs(5))).ok();

    let req = format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
    stream
        .write_all(req.as_bytes())
        .map_err(|e| format!("write: {e}"))?;

    let mut buf = Vec::new();
    stream
        .read_to_end(&mut buf)
        .map_err(|e| format!("read: {e}"))?;

    let resp = String::from_utf8_lossy(&buf);
    if let Some(pos) = resp.find("\r\n\r\n") {
        Ok(resp[pos + 4..].to_string())
    } else {
        Ok(resp.to_string())
    }
}

fn make_spec(pod_id: u64, env_vars: Vec<(&str, &str)>, port: u16) -> PodSpec {
    PodSpec {
        pod_id,
        deployment_id: 100,
        image: "test:latest".into(),
        entrypoint: String::new(),
        port,
        gpu_count: 0,
        gpu_type: GpuType::None,
        cpu_millicores: 1000,
        memory_megabytes: 512,
        env_vars: env_vars
            .into_iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
        mounts: vec![],
    }
}

#[test]
fn env_vars_reach_subprocess() {
    let rt = ProcessRuntime::with_base_port(16000);
    let spec = make_spec(
        1001,
        vec![
            ("MY_SECRET", "hunter2"),
            ("APP_NAME", "test-app"),
            ("GPU_MODE", "disabled"),
        ],
        8080,
    );

    let handle = rt.create_pod(&spec).expect("create_pod");
    rt.start_pod(&handle).expect("start_pod");

    let port: u16 = handle
        .container_id
        .rsplit(':')
        .next()
        .unwrap()
        .parse()
        .unwrap();

    let body = http_get(port, "/env").expect("http_get /env");
    let env: HashMap<String, String> = serde_json::from_str(&body).expect("parse env json");

    assert_eq!(
        env.get("MY_SECRET").map(|s| s.as_str()),
        Some("hunter2"),
        "MY_SECRET not found in env: {env:?}"
    );
    assert_eq!(env.get("APP_NAME").map(|s| s.as_str()), Some("test-app"));
    assert_eq!(env.get("PORT").map(|s| s.as_str()), Some("8080"));

    rt.stop_pod(&handle, 0).ok();
}

#[test]
fn pod_lifecycle_full_pipeline() {
    let rt = ProcessRuntime::with_base_port(16100);
    let spec = make_spec(2001, vec![("STAGE", "integration")], 0);

    let handle = rt.create_pod(&spec).expect("create_pod");
    rt.start_pod(&handle).expect("start_pod");

    let status = rt.pod_status(&handle).expect("pod_status");
    assert!(
        matches!(status, PodStatus::Running),
        "expected Running, got {status:?}"
    );

    let port: u16 = handle
        .container_id
        .rsplit(':')
        .next()
        .unwrap()
        .parse()
        .unwrap();

    let resp = forward_run(port, b"hello").expect("forward_run");
    let body: serde_json::Value = serde_json::from_slice(&resp).expect("parse response");
    assert_eq!(body["status"], "ok");
    assert_eq!(body["echo"], "hello");

    rt.stop_pod(&handle, 0).expect("stop_pod");
}

#[test]
fn multiple_pods_isolated_envs() {
    let rt = ProcessRuntime::with_base_port(16200);

    let spec_a = make_spec(3001, vec![("ROLE", "worker-a")], 0);
    let spec_b = make_spec(3002, vec![("ROLE", "worker-b")], 0);

    let handle_a = rt.create_pod(&spec_a).expect("create a");
    let handle_b = rt.create_pod(&spec_b).expect("create b");
    rt.start_pod(&handle_a).expect("start a");
    rt.start_pod(&handle_b).expect("start b");

    let port_a: u16 = handle_a
        .container_id
        .rsplit(':')
        .next()
        .unwrap()
        .parse()
        .unwrap();
    let port_b: u16 = handle_b
        .container_id
        .rsplit(':')
        .next()
        .unwrap()
        .parse()
        .unwrap();

    let env_a: HashMap<String, String> =
        serde_json::from_str(&http_get(port_a, "/env").unwrap()).unwrap();
    let env_b: HashMap<String, String> =
        serde_json::from_str(&http_get(port_b, "/env").unwrap()).unwrap();

    assert_eq!(env_a.get("ROLE").map(|s| s.as_str()), Some("worker-a"));
    assert_eq!(env_b.get("ROLE").map(|s| s.as_str()), Some("worker-b"));

    rt.stop_pod(&handle_a, 0).ok();
    rt.stop_pod(&handle_b, 0).ok();
}

#[test]
fn secret_resolver_plain_passthrough() {
    use hivemind_worker::secrets::SecretResolver;

    let mut resolver = SecretResolver::new();
    let entries = vec![
        EnvEntry {
            name: "DB_HOST".into(),
            value: "postgres:5432".into(),
            is_secret_ref: false,
        },
        EnvEntry {
            name: "API_KEY".into(),
            value: "sk-test-123".into(),
            is_secret_ref: false,
        },
    ];

    let resolved = resolver.resolve(&entries);
    assert_eq!(resolved.len(), 2);
    assert_eq!(resolved[0].0, "DB_HOST");
    assert_eq!(resolved[0].1, "postgres:5432");
}

#[test]
fn volume_mount_cleanup() {
    use hivemind_worker::volumes;
    volumes::unmount_juicefs(99999).expect("nonexistent mount cleanup");
}
