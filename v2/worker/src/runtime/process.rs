use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::process::{Child, Command};
use std::sync::Mutex;
use std::time::Duration;

use crate::runtime::{PodHandle, PodSpec, PodStatus, Runtime, RuntimeError};

const BASE_PORT: u16 = 15000;

struct RunningProcess {
    child: Child,
    port: u16,
}

/// Spawns real OS processes as "containers". Each pod gets a subprocess
/// listening on a unique port. Inference requests are HTTP POSTed to it.
pub struct ProcessRuntime {
    processes: Mutex<HashMap<String, RunningProcess>>,
    next_port: Mutex<u16>,
}

impl ProcessRuntime {
    pub fn new() -> Self {
        Self::with_base_port(BASE_PORT)
    }

    pub fn with_base_port(base_port: u16) -> Self {
        Self {
            processes: Mutex::new(HashMap::new()),
            next_port: Mutex::new(base_port),
        }
    }

    pub fn get_port(&self, container_id: &str) -> Option<u16> {
        self.processes
            .lock()
            .unwrap()
            .get(container_id)
            .map(|p| p.port)
    }
}

impl Runtime for ProcessRuntime {
    fn pull_image(
        &self,
        _image: &str,
        _auth: Option<&super::ImagePullAuth>,
    ) -> Result<(), RuntimeError> {
        Ok(()) // no-op for process runtime
    }

    fn create_pod(&self, spec: &PodSpec) -> Result<PodHandle, RuntimeError> {
        let mut next = self.next_port.lock().unwrap();
        let port = *next;
        *next += 1;

        let container_id = format!("proc-pod-{}:{}", spec.pod_id, port);

        // Spawn a simple HTTP server as the "container".
        // Injects env vars from the pod spec and exposes them via GET /env.
        let mut cmd = Command::new("python3");
        cmd.args([
            "-c",
            &format!(
                r#"
import http.server, json, os, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        response = json.dumps(dict(os.environ))
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(response.encode())
    def do_POST(self):
        length = int(self.headers.get('content-length', 0))
        body = self.rfile.read(length) if length > 0 else b''
        response = json.dumps({{"status": "ok", "echo": body.decode('utf-8', errors='replace'), "pod_id": {}}})
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(response.encode())
    def log_message(self, format, *args): pass
http.server.HTTPServer(('127.0.0.1', {}), H).serve_forever()
"#,
                spec.pod_id, port
            ),
        ]);

        // Pass env vars from pod spec to subprocess
        for (name, value) in &spec.env_vars {
            cmd.env(name, value);
        }
        if spec.port > 0 {
            cmd.env("PORT", spec.port.to_string());
        }

        let child = cmd
            .spawn()
            .map_err(|e| RuntimeError::ContainerCreate(format!("spawn failed: {e}")))?;

        self.processes
            .lock()
            .unwrap()
            .insert(container_id.clone(), RunningProcess { child, port });

        Ok(PodHandle {
            pod_id: spec.pod_id,
            container_id,
        })
    }

    fn start_pod(&self, handle: &PodHandle) -> Result<(), RuntimeError> {
        // Wait for the HTTP server to be ready
        let port = self
            .get_port(&handle.container_id)
            .ok_or_else(|| RuntimeError::ContainerNotFound(handle.container_id.clone()))?;

        for _ in 0..50 {
            if TcpStream::connect(format!("127.0.0.1:{port}")).is_ok() {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        Err(RuntimeError::ContainerStart(
            "server didn't become ready in 5s".into(),
        ))
    }

    fn forward_run(
        &self,
        handle: &PodHandle,
        _port: u16,
        payload: &[u8],
    ) -> Result<Vec<u8>, RuntimeError> {
        let port = self
            .get_port(&handle.container_id)
            .ok_or_else(|| RuntimeError::ContainerNotFound(handle.container_id.clone()))?;

        crate::runtime::process::forward_run(port, payload).map_err(RuntimeError::Internal)
    }

    fn stop_pod(&self, handle: &PodHandle, _grace_period_ms: u64) -> Result<(), RuntimeError> {
        if let Some(mut proc) = self.processes.lock().unwrap().remove(&handle.container_id) {
            let _ = proc.child.kill();
            let _ = proc.child.wait();
        }
        Ok(())
    }

    fn pod_status(&self, handle: &PodHandle) -> Result<PodStatus, RuntimeError> {
        let mut procs = self.processes.lock().unwrap();
        if let Some(proc) = procs.get_mut(&handle.container_id) {
            match proc.child.try_wait() {
                Ok(Some(status)) => Ok(PodStatus::Stopped {
                    exit_code: status.code().unwrap_or(-1),
                }),
                Ok(None) => Ok(PodStatus::Running),
                Err(_) => Ok(PodStatus::Unknown),
            }
        } else {
            Err(RuntimeError::ContainerNotFound(handle.container_id.clone()))
        }
    }

    fn remove_pod(&self, handle: &PodHandle) -> Result<(), RuntimeError> {
        self.stop_pod(handle, 0)
    }
}

/// Send an HTTP GET to a process "container" health endpoint and check for 200.
pub fn probe_http(port: u16, path: &str) -> Result<bool, String> {
    let mut stream =
        TcpStream::connect(format!("127.0.0.1:{port}")).map_err(|e| format!("connect: {e}"))?;
    stream.set_read_timeout(Some(Duration::from_secs(5))).ok();

    let request =
        format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
    stream
        .write_all(request.as_bytes())
        .map_err(|e| format!("write: {e}"))?;

    let mut response = [0u8; 1024];
    let n = stream
        .read(&mut response)
        .map_err(|e| format!("read: {e}"))?;

    let resp_str = String::from_utf8_lossy(&response[..n]);
    Ok(resp_str.contains("200"))
}

/// Send an HTTP POST to a process "container" and return the response body.
pub fn forward_run(port: u16, payload: &[u8]) -> Result<Vec<u8>, String> {
    let url = format!("http://127.0.0.1:{port}/inference");
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(5))
        .timeout_read(Duration::from_secs(30))
        .build();
    let response = agent
        .post(&url)
        .set("Connection", "close")
        .send_bytes(payload);

    let mut reader: Box<dyn Read + Send + Sync + 'static> = match response {
        Ok(resp) => resp.into_reader(),
        Err(ureq::Error::Status(_, resp)) => resp.into_reader(),
        Err(ureq::Error::Transport(err)) => return Err(format!("request: {err}")),
    };

    let mut body = Vec::new();
    reader
        .read_to_end(&mut body)
        .map_err(|e| format!("read body: {e}"))?;
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;
    use std::time::{Duration, Instant};

    #[test]
    fn forward_run_reads_content_length_without_waiting_for_eof() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();

        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buf = [0u8; 4096];
            let _ = stream.read(&mut buf).unwrap();

            let body = br#"{"status":"ok"}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: keep-alive\r\n\r\n",
                body.len()
            );
            stream.write_all(response.as_bytes()).unwrap();
            stream.write_all(body).unwrap();
            stream.flush().unwrap();

            thread::sleep(Duration::from_secs(2));
        });

        let started = Instant::now();
        let body = forward_run(port, br#"{"ping":true}"#).unwrap();
        let elapsed = started.elapsed();

        assert_eq!(body, br#"{"status":"ok"}"#);
        assert!(
            elapsed < Duration::from_secs(1),
            "forward_run waited for EOF: {elapsed:?}"
        );

        server.join().unwrap();
    }
}
