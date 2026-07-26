use hivemind_worker::{crypto, fingerprint, metrics, real_io, runtime, sim, types, worker};

use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;

static SHUTDOWN: AtomicBool = AtomicBool::new(false);

extern "C" fn handle_signal(_: libc::c_int) {
    SHUTDOWN.store(true, Ordering::SeqCst);
}

const MAX_REPLICA_ADDRS: usize = 64;
const MAX_SHUTDOWN_RECONCILIATION_ATTEMPTS: usize = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
struct RunConfig {
    replica_addr: String,
    runtime_mode: String,
    snapshotter: String,
    metrics_port: Option<u16>,
    encryption_key_hex: String,
}

fn parse_replica_addrs(replica_addr: &str) -> Vec<String> {
    let mut addrs = Vec::new();
    for part in replica_addr.split(',') {
        let addr = part.trim();
        if addr.is_empty() {
            continue;
        }
        if addrs.len() >= MAX_REPLICA_ADDRS {
            break;
        }
        addrs.push(addr.to_string());
    }
    addrs
}

fn parse_run_config<F>(args: &[String], env: F) -> RunConfig
where
    F: Fn(&str) -> Option<String>,
{
    let mut replica_addr = String::new();
    let mut runtime_mode = "process".to_string();
    let mut snapshotter = "overlayfs".to_string();
    let mut metrics_port: Option<u16> = None;
    let mut encryption_key_hex = String::new();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--runtime" if i + 1 < args.len() => {
                runtime_mode = args[i + 1].clone();
                i += 2;
            }
            "--snapshotter" if i + 1 < args.len() => {
                snapshotter = args[i + 1].clone();
                i += 2;
            }
            "--metrics-port" if i + 1 < args.len() => {
                metrics_port = args[i + 1].parse().ok();
                i += 2;
            }
            "--encryption-key" if i + 1 < args.len() => {
                encryption_key_hex = args[i + 1].clone();
                i += 2;
            }
            _ if replica_addr.is_empty() => {
                replica_addr = args[i].clone();
                i += 1;
            }
            _ => i += 1,
        }
    }

    if snapshotter == "overlayfs" {
        if let Some(v) = env("HIVEMIND_SNAPSHOTTER") {
            if !v.is_empty() {
                snapshotter = v;
            }
        }
    }

    if metrics_port.is_none() {
        if let Some(v) = env("HIVEMIND_AGENT_METRICS_PORT") {
            metrics_port = v.parse().ok();
        }
    }

    if encryption_key_hex.is_empty() {
        if let Some(v) = env("HIVEMIND_ENCRYPTION_KEY") {
            encryption_key_hex = v;
        }
    }

    RunConfig {
        replica_addr,
        runtime_mode,
        snapshotter,
        metrics_port,
        encryption_key_hex,
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();

    match args.get(1).map(|s| s.as_str()) {
        Some("fingerprint") => cmd_fingerprint(),
        Some("run") => cmd_run(&args[2..]),
        Some(other) => {
            eprintln!("unknown command: {other}");
            std::process::exit(1);
        }
        None => {
            eprintln!("usage: hivemind-worker <command>");
            eprintln!("commands: fingerprint, run");
            std::process::exit(1);
        }
    }
}

fn cmd_fingerprint() {
    match fingerprint::fingerprint() {
        Ok(fp) => println!("{fp:#?}"),
        Err(e) => {
            eprintln!("fingerprint failed: {e:?}");
            std::process::exit(1);
        }
    }
}

fn cmd_run(args: &[String]) {
    let cfg = parse_run_config(args, |key| std::env::var(key).ok());
    let replica_addr = cfg.replica_addr;
    let runtime_mode = cfg.runtime_mode;
    let snapshotter = cfg.snapshotter;
    let metrics_port = cfg.metrics_port;
    let encryption_key_hex = cfg.encryption_key_hex;

    #[cfg(not(target_os = "linux"))]
    let _ = &snapshotter;

    let encryption_key = if !encryption_key_hex.is_empty() {
        match crypto::EncryptionState::from_hex(&encryption_key_hex) {
            Ok(state) => {
                eprintln!("hivemind-worker: frame encryption enabled (XChaCha20-Poly1305)");
                Some(state.worker_key)
            }
            Err(e) => {
                eprintln!("hivemind-worker: invalid encryption key: {e}");
                std::process::exit(1);
            }
        }
    } else {
        None
    };

    let replica_addrs = parse_replica_addrs(&replica_addr);
    if replica_addrs.is_empty() {
        eprintln!("usage: hivemind-worker run <replica-host:port>[,<replica-host:port>...] [--runtime process|simulated|containerd] [--snapshotter overlayfs|nydus] [--metrics-port PORT] [--encryption-key HEX]");
        std::process::exit(1);
    }

    let metrics_server = metrics_port.and_then(|port| match metrics::MetricsServer::new(port) {
        Ok(s) => {
            eprintln!("worker: metrics on :{port}");
            Some(s)
        }
        Err(e) => {
            eprintln!("worker: metrics server failed: {e}");
            None
        }
    });

    let node_fp = match fingerprint::fingerprint() {
        Ok(fp) => fp,
        Err(e) => {
            eprintln!("worker: fingerprint failed: {e:?}; falling back to conservative defaults");
            let node_name = {
                let mut buf = [0u8; 64];
                let ret =
                    unsafe { libc::gethostname(buf.as_mut_ptr() as *mut libc::c_char, buf.len()) };
                if ret != 0 {
                    "unknown".to_string()
                } else {
                    let len = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
                    String::from_utf8_lossy(&buf[..len]).into_owned()
                }
            };

            fingerprint::NodeFingerprint {
                node_name,
                cpu_millicores: 1000,
                memory_megabytes: 1024,
                gpu_type: types::GpuType::None,
                gpu_count: 0,
                gpu_memory_megabytes: 0,
            }
        }
    };

    let node_name = node_fp.node_name.clone();
    let mut node_worker = worker::Worker::new(
        node_fp.node_name,
        node_fp.gpu_type,
        node_fp.gpu_count,
        node_fp.cpu_millicores,
        node_fp.memory_megabytes,
    );

    eprintln!(
        "worker {node_name}: runtime={runtime_mode} connecting to {} replica(s) [{}] cpu={}m mem={}Mi gpu={:?}x{}",
        replica_addrs.len(),
        replica_addrs.join(","),
        node_fp.cpu_millicores,
        node_fp.memory_megabytes,
        node_fp.gpu_type,
        node_fp.gpu_count,
    );

    unsafe {
        libc::signal(
            libc::SIGTERM,
            handle_signal as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGINT,
            handle_signal as *const () as libc::sighandler_t,
        );
    }

    let mut backoff_ms: u64 = 100;
    let max_backoff_ms: u64 = 10_000;
    let mut replica_idx: usize = 0;

    loop {
        if SHUTDOWN.load(Ordering::SeqCst) {
            break;
        }

        let current_replica_addr = replica_addrs[replica_idx].clone();
        match real_io::RealIo::connect(&current_replica_addr, encryption_key) {
            Ok(mut rio) => {
                eprintln!("worker {node_name}: connected to {current_replica_addr}");
                backoff_ms = 100;

                match runtime_mode.as_str() {
                    "process" => {
                        let rt = runtime::process::ProcessRuntime::new();
                        run_worker_loop(&mut node_worker, &mut rio, &rt, &metrics_server);
                    }
                    "simulated" => {
                        let rt = sim::runtime::SimulatedRuntime::new(0, Default::default());
                        run_worker_loop(&mut node_worker, &mut rio, &rt, &metrics_server);
                    }
                    #[cfg(target_os = "linux")]
                    "containerd" => {
                        let snap = if snapshotter == "overlayfs" {
                            None
                        } else {
                            Some(snapshotter.as_str())
                        };
                        let rt =
                            runtime::containerd::ContainerdRuntime::new(None, None, None, snap)
                                .expect("failed to init containerd runtime");
                        run_worker_loop(&mut node_worker, &mut rio, &rt, &metrics_server);
                    }
                    other => {
                        eprintln!("unknown runtime: {other}");
                        std::process::exit(1);
                    }
                }

                if SHUTDOWN.load(Ordering::SeqCst) {
                    eprintln!("worker {node_name}: shutdown complete");
                } else {
                    node_worker.on_connection_lost();
                    replica_idx = (replica_idx + 1) % replica_addrs.len();
                    eprintln!("worker {node_name}: disconnected from {current_replica_addr}");
                }
            }
            Err(e) => {
                eprintln!("worker {node_name}: connect to {current_replica_addr} failed: {e}");
                replica_idx = (replica_idx + 1) % replica_addrs.len();
            }
        }

        if SHUTDOWN.load(Ordering::SeqCst) {
            break;
        }
        eprintln!("worker {node_name}: reconnecting in {backoff_ms}ms");
        thread::sleep(Duration::from_millis(backoff_ms));
        backoff_ms = (backoff_ms * 2).min(max_backoff_ms);
    }
}

#[cfg(test)]
mod tests {
    use super::{
        parse_replica_addrs, parse_run_config, reconcile_shutdown, RunConfig, MAX_REPLICA_ADDRS,
        MAX_SHUTDOWN_RECONCILIATION_ATTEMPTS,
    };
    use std::collections::HashMap;

    fn parse(args: &[&str], env_pairs: &[(&str, &str)]) -> RunConfig {
        let args: Vec<String> = args.iter().map(|s| (*s).to_string()).collect();
        let env_map: HashMap<String, String> = env_pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect();
        parse_run_config(&args, |key| env_map.get(key).cloned())
    }

    #[test]
    fn replica_addr_list_splits_trims_and_bounds() {
        let parsed = parse_replica_addrs(" 10.0.0.1:9000,10.0.0.2:9000,, 10.0.0.3:9000 ");
        assert_eq!(
            parsed,
            vec![
                "10.0.0.1:9000".to_string(),
                "10.0.0.2:9000".to_string(),
                "10.0.0.3:9000".to_string(),
            ]
        );

        let many = (0..(MAX_REPLICA_ADDRS + 8))
            .map(|i| format!("10.0.0.{i}:9000"))
            .collect::<Vec<_>>()
            .join(",");
        assert_eq!(parse_replica_addrs(&many).len(), MAX_REPLICA_ADDRS);
    }

    #[test]
    fn snapshotter_flag_beats_env_var() {
        let cfg = parse(
            &["127.0.0.1:9000", "--snapshotter", "nydus"],
            &[("HIVEMIND_SNAPSHOTTER", "overlayfs")],
        );
        assert_eq!(cfg.snapshotter, "nydus");
    }

    #[test]
    fn snapshotter_env_fills_default() {
        let cfg = parse(&["127.0.0.1:9000"], &[("HIVEMIND_SNAPSHOTTER", "nydus")]);
        assert_eq!(cfg.snapshotter, "nydus");
    }

    #[test]
    fn shutdown_reconciliation_is_bounded() {
        let mut attempts = 0;
        let mut waits = 0;

        assert!(!reconcile_shutdown(
            || {
                attempts += 1;
                false
            },
            || waits += 1,
        ));
        assert_eq!(attempts, MAX_SHUTDOWN_RECONCILIATION_ATTEMPTS);
        assert_eq!(waits, MAX_SHUTDOWN_RECONCILIATION_ATTEMPTS - 1);
    }

    #[test]
    fn metrics_port_still_uses_env_when_flag_missing() {
        let cfg = parse(
            &["127.0.0.1:9000"],
            &[("HIVEMIND_AGENT_METRICS_PORT", "8081")],
        );
        assert_eq!(cfg.metrics_port, Some(8081));
    }
}

fn reconcile_shutdown<F, S>(mut shutdown: F, mut wait: S) -> bool
where
    F: FnMut() -> bool,
    S: FnMut(),
{
    for attempt in 0..MAX_SHUTDOWN_RECONCILIATION_ATTEMPTS {
        if shutdown() {
            return true;
        }
        if attempt + 1 < MAX_SHUTDOWN_RECONCILIATION_ATTEMPTS {
            wait();
        }
    }
    false
}

fn run_worker_loop(
    node_worker: &mut worker::Worker,
    rio: &mut real_io::RealIo,
    rt: &dyn runtime::Runtime,
    metrics_server: &Option<metrics::MetricsServer>,
) {
    while rio.is_connected() && !SHUTDOWN.load(Ordering::SeqCst) {
        node_worker.tick(rio, rt);
        if let Some(ref srv) = metrics_server {
            srv.poll(node_worker);
        }
        thread::sleep(Duration::from_millis(1));
    }

    if SHUTDOWN.load(Ordering::SeqCst) {
        eprintln!("worker: shutting down gracefully...");
        if !reconcile_shutdown(
            || node_worker.shutdown(rio, rt),
            || thread::sleep(Duration::from_secs(1)),
        ) {
            eprintln!(
                "worker: shutdown cleanup remains unverified after {} reconciliation attempts",
                MAX_SHUTDOWN_RECONCILIATION_ATTEMPTS
            );
            std::process::exit(1);
        }
    }
}
