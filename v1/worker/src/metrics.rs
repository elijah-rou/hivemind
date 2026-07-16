use std::io::Write;
use std::net::TcpListener;

use crate::worker::{TrackedPodState, Worker};

/// Serve Prometheus metrics and health probe on a TCP socket. Non-blocking:
/// call from the main loop each tick. Accepts one connection per call.
///
/// Endpoints:
///   GET /healthz  → 200 OK (liveness probe)
///   GET /metrics  → Prometheus text (default for any other path)
pub struct MetricsServer {
    listener: TcpListener,
    start_time: std::time::Instant,
}

impl MetricsServer {
    pub fn new(port: u16) -> std::io::Result<Self> {
        let listener = TcpListener::bind(format!("0.0.0.0:{port}"))?;
        listener.set_nonblocking(true)?;
        Ok(Self {
            listener,
            start_time: std::time::Instant::now(),
        })
    }

    pub fn poll(&self, worker: &Worker) {
        let stream = match self.listener.accept() {
            Ok((stream, _)) => stream,
            Err(_) => return,
        };

        let mut req_buf = [0u8; 512];
        let _ = stream.set_nonblocking(false);
        let _ = stream.set_read_timeout(Some(std::time::Duration::from_millis(100)));
        let n = match std::io::Read::read(&mut &stream, &mut req_buf) {
            Ok(n) => n,
            Err(_) => 0,
        };

        let req = std::str::from_utf8(&req_buf[..n]).unwrap_or("");
        let mut writer = std::io::BufWriter::new(&stream);

        if req.contains("GET /healthz") {
            let resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
            let _ = writer.write_all(resp.as_bytes());
        } else {
            let body = format_metrics(worker, self.start_time.elapsed().as_secs());
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = writer.write_all(response.as_bytes());
        }
        let _ = writer.flush();
    }
}

fn format_metrics(worker: &Worker, uptime_secs: u64) -> String {
    let mut out = String::with_capacity(2048);

    let (running, total) = worker.pod_counts();
    let gpu_free = worker.gpu_total.saturating_sub(worker.gpu_allocated());

    out.push_str("# HELP hivemind_worker_pods_running Number of pods in Running state\n");
    out.push_str("# TYPE hivemind_worker_pods_running gauge\n");
    out.push_str(&format!("hivemind_worker_pods_running {running}\n"));

    out.push_str("# HELP hivemind_worker_pods_total Total tracked pods\n");
    out.push_str("# TYPE hivemind_worker_pods_total gauge\n");
    out.push_str(&format!("hivemind_worker_pods_total {total}\n"));

    // Per-state pod counts
    let pods = worker.tracked_pods();
    let mut image_pulling: u32 = 0;
    let mut creating: u32 = 0;
    let mut starting: u32 = 0;
    let mut run_count: u32 = 0;
    let mut stopping: u32 = 0;
    let mut failed: u32 = 0;
    for pod in pods.values() {
        match &pod.state {
            TrackedPodState::ImagePulling => image_pulling += 1,
            TrackedPodState::Creating => creating += 1,
            TrackedPodState::Starting => starting += 1,
            TrackedPodState::Running => run_count += 1,
            TrackedPodState::Stopping => stopping += 1,
            TrackedPodState::Failed { .. } => failed += 1,
            TrackedPodState::Stopped { .. } => {}
        }
    }
    out.push_str("# HELP hivemind_worker_pods Per-state pod counts\n");
    out.push_str("# TYPE hivemind_worker_pods gauge\n");
    out.push_str(&format!(
        "hivemind_worker_pods{{state=\"image_pulling\"}} {image_pulling}\n"
    ));
    out.push_str(&format!(
        "hivemind_worker_pods{{state=\"creating\"}} {creating}\n"
    ));
    out.push_str(&format!(
        "hivemind_worker_pods{{state=\"starting\"}} {starting}\n"
    ));
    out.push_str(&format!(
        "hivemind_worker_pods{{state=\"running\"}} {run_count}\n"
    ));
    out.push_str(&format!(
        "hivemind_worker_pods{{state=\"stopping\"}} {stopping}\n"
    ));
    out.push_str(&format!(
        "hivemind_worker_pods{{state=\"failed\"}} {failed}\n"
    ));

    out.push_str("# HELP hivemind_worker_gpu_free Available GPUs\n");
    out.push_str("# TYPE hivemind_worker_gpu_free gauge\n");
    out.push_str(&format!("hivemind_worker_gpu_free {gpu_free}\n"));

    out.push_str("# HELP hivemind_worker_gpu_total Total GPUs on node\n");
    out.push_str("# TYPE hivemind_worker_gpu_total gauge\n");
    out.push_str(&format!("hivemind_worker_gpu_total {}\n", worker.gpu_total));

    out.push_str("# HELP hivemind_worker_gpu_allocated GPUs allocated to pods\n");
    out.push_str("# TYPE hivemind_worker_gpu_allocated gauge\n");
    out.push_str(&format!(
        "hivemind_worker_gpu_allocated {}\n",
        worker.gpu_allocated()
    ));

    let connected: u8 = if worker.is_registered() { 1 } else { 0 };
    out.push_str(
        "# HELP hivemind_worker_connected Whether agent is registered with control plane\n",
    );
    out.push_str("# TYPE hivemind_worker_connected gauge\n");
    out.push_str(&format!("hivemind_worker_connected {connected}\n"));

    out.push_str("# HELP hivemind_worker_uptime_seconds Worker process uptime\n");
    out.push_str("# TYPE hivemind_worker_uptime_seconds counter\n");
    out.push_str(&format!("hivemind_worker_uptime_seconds {uptime_secs}\n"));

    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::GpuType;

    #[test]
    fn metrics_format_valid() {
        let worker = Worker::new("test".into(), GpuType::None, 0, 4000, 8192);
        let body = format_metrics(&worker, 42);
        assert!(body.contains("hivemind_worker_pods_running 0"));
        assert!(body.contains("hivemind_worker_gpu_total 0"));
        assert!(body.contains("hivemind_worker_gpu_allocated 0"));
        assert!(body.contains("hivemind_worker_connected 0"));
        assert!(body.contains("hivemind_worker_pods{state=\"running\"} 0"));
        assert!(body.contains("hivemind_worker_pods{state=\"failed\"} 0"));
        assert!(body.contains("hivemind_worker_uptime_seconds 42"));
    }
}
