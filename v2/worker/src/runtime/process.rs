use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::process::{Child, Command};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::protocol::MAX_RUN_RESPONSE_BODY;
use crate::runtime::{PodHandle, PodSpec, PodStatus, Runtime, RuntimeError};

const BASE_PORT: u16 = 15000;
const PROBE_DEADLINE: Duration = Duration::from_secs(5);
const PROBE_PATH_MAX: usize = 1024;
const HTTP_STATUS_LINE_MAX: usize = 1024;

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

        crate::runtime::process::forward_run(port, payload)
    }

    fn probe_pod(&self, handle: &PodHandle, _port: u16, path: &str) -> Result<bool, RuntimeError> {
        let port = self
            .get_port(&handle.container_id)
            .ok_or_else(|| RuntimeError::ContainerNotFound(handle.container_id.clone()))?;
        probe_http(port, path).map_err(RuntimeError::Internal)
    }

    fn stop_pod(&self, handle: &PodHandle, _grace_period_ms: u64) -> Result<(), RuntimeError> {
        let mut processes = self.processes.lock().unwrap();
        let proc = processes
            .get_mut(&handle.container_id)
            .ok_or_else(|| RuntimeError::ContainerNotFound(handle.container_id.clone()))?;
        match proc.child.try_wait() {
            Ok(Some(_)) => return Ok(()),
            Ok(None) => {}
            Err(error) => {
                return Err(RuntimeError::ContainerStop(format!(
                    "{} status before kill: {error}",
                    handle.container_id
                )))
            }
        }
        proc.child.kill().map_err(|error| {
            RuntimeError::ContainerStop(format!("{} kill: {error}", handle.container_id))
        })?;
        proc.child.wait().map_err(|error| {
            RuntimeError::ContainerStop(format!("{} wait: {error}", handle.container_id))
        })?;
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
        self.stop_pod(handle, 0)?;
        let removed = self.processes.lock().unwrap().remove(&handle.container_id);
        assert!(
            removed.is_some(),
            "stopped process must remain owned until removal"
        );
        Ok(())
    }
}

/// Send a bounded HTTP GET and accept exactly a well-formed `200` status line.
pub fn probe_http(port: u16, path: &str) -> Result<bool, String> {
    validate_probe_path(path)?;
    let started = Instant::now();
    let address = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    let mut stream = TcpStream::connect_timeout(&address, PROBE_DEADLINE)
        .map_err(|e| format!("connect: {e}"))?;

    let request =
        format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
    stream
        .set_write_timeout(Some(probe_time_remaining(started)?))
        .map_err(|e| format!("set write timeout: {e}"))?;
    stream
        .write_all(request.as_bytes())
        .map_err(|e| format!("write: {e}"))?;

    let mut status_line = [0u8; HTTP_STATUS_LINE_MAX + 1];
    let mut length = 0;
    loop {
        if length == status_line.len() {
            return Err(format!(
                "HTTP status line exceeds {HTTP_STATUS_LINE_MAX} bytes"
            ));
        }
        stream
            .set_read_timeout(Some(probe_time_remaining(started)?))
            .map_err(|e| format!("set read timeout: {e}"))?;
        let read = stream
            .read(&mut status_line[length..])
            .map_err(|e| format!("read status line: {e}"))?;
        if read == 0 {
            return Err("HTTP response ended before status line".into());
        }
        length += read;
        if let Some(line_end) = status_line[..length].iter().position(|byte| *byte == b'\n') {
            if line_end + 1 > HTTP_STATUS_LINE_MAX {
                return Err(format!(
                    "HTTP status line exceeds {HTTP_STATUS_LINE_MAX} bytes"
                ));
            }
            return parse_http_status_line(&status_line[..=line_end]);
        }
    }
}

fn probe_time_remaining(started: Instant) -> Result<Duration, String> {
    PROBE_DEADLINE
        .checked_sub(started.elapsed())
        .filter(|remaining| !remaining.is_zero())
        .ok_or_else(|| "HTTP probe exceeded total deadline".into())
}

fn validate_probe_path(path: &str) -> Result<(), String> {
    if path.is_empty() || path.len() > PROBE_PATH_MAX || !path.starts_with('/') {
        return Err(format!(
            "probe path must start with '/' and contain at most {PROBE_PATH_MAX} bytes"
        ));
    }
    if !path.bytes().all(|byte| (b'!'..=b'~').contains(&byte)) {
        return Err("probe path contains unsafe request-target bytes".into());
    }
    Ok(())
}

fn parse_http_status_line(line: &[u8]) -> Result<bool, String> {
    let line = line
        .strip_suffix(b"\r\n")
        .ok_or_else(|| "HTTP status line must end with CRLF".to_string())?;
    let Some(version_end) = line.iter().position(|byte| *byte == b' ') else {
        return Err("HTTP status line is missing status code".into());
    };
    let version = &line[..version_end];
    if version != b"HTTP/1.0" && version != b"HTTP/1.1" {
        return Err("HTTP status line has unsupported version".into());
    }

    let status_and_reason = &line[version_end + 1..];
    if status_and_reason.len() < 3 {
        return Err("HTTP status code must contain three digits".into());
    }
    let status = &status_and_reason[..3];
    if !status.iter().all(u8::is_ascii_digit) {
        return Err("HTTP status code must contain three digits".into());
    }
    let reason = &status_and_reason[3..];
    if reason.first() != Some(&b' ') {
        return Err("HTTP status code must be followed by one space".into());
    }
    if !reason[1..].iter().all(|byte| (b' '..=b'~').contains(byte)) {
        return Err("HTTP reason phrase contains unsafe bytes".into());
    }
    Ok(status == b"200")
}

/// Send an HTTP POST to a process "container" and return the response body.
pub fn forward_run(port: u16, payload: &[u8]) -> Result<Vec<u8>, RuntimeError> {
    forward_run_with_deadline(port, payload, Duration::from_secs(25))
}

fn forward_run_with_deadline(
    port: u16,
    payload: &[u8],
    hard_deadline: Duration,
) -> Result<Vec<u8>, RuntimeError> {
    assert!(!hard_deadline.is_zero(), "run deadline must be positive");
    let url = format!("http://127.0.0.1:{port}/inference");
    let agent = ureq::AgentBuilder::new()
        .timeout(hard_deadline)
        .timeout_connect(Duration::from_secs(5).min(hard_deadline))
        .build();
    let response = agent
        .post(&url)
        .set("Connection", "close")
        .send_bytes(payload);

    let response = match response {
        Ok(resp) => resp,
        Err(ureq::Error::Status(_, resp)) => resp,
        Err(ureq::Error::Transport(err)) => {
            return Err(RuntimeError::Internal(format!("request: {err}")))
        }
    };
    if let Some(content_length) = response.header("Content-Length") {
        let declared = content_length
            .parse::<usize>()
            .map_err(|_| RuntimeError::Internal("invalid Content-Length".into()))?;
        if declared > MAX_RUN_RESPONSE_BODY {
            return Err(RuntimeError::ResponseTooLarge(format!(
                "body exceeds {MAX_RUN_RESPONSE_BODY} bytes"
            )));
        }
    }

    let mut reader = response
        .into_reader()
        .take((MAX_RUN_RESPONSE_BODY + 1) as u64);
    let mut body = Vec::with_capacity(MAX_RUN_RESPONSE_BODY.min(4096));
    reader
        .read_to_end(&mut body)
        .map_err(|e| RuntimeError::Internal(format!("read body: {e}")))?;
    if body.len() > MAX_RUN_RESPONSE_BODY {
        return Err(RuntimeError::ResponseTooLarge(format!(
            "body exceeds {MAX_RUN_RESPONSE_BODY} bytes"
        )));
    }
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
    fn process_runtime_probe_uses_owned_process_port() {
        let runtime = ProcessRuntime::with_base_port(24_500);
        let handle = runtime
            .create_pod(&PodSpec {
                pod_id: 78,
                deployment_id: 1,
                image: "process".into(),
                entrypoint: String::new(),
                port: 8080,
                gpu_count: 0,
                gpu_type: crate::types::GpuType::None,
                cpu_millicores: 100,
                memory_megabytes: 128,
                env_vars: Vec::new(),
                mounts: Vec::new(),
            })
            .unwrap();
        runtime.start_pod(&handle).unwrap();

        assert!(runtime.probe_pod(&handle, 1, "/health").unwrap());
        runtime.remove_pod(&handle).unwrap();
    }

    #[test]
    fn stopped_process_remains_queryable_until_remove() {
        let runtime = ProcessRuntime::with_base_port(24_000);
        let handle = runtime
            .create_pod(&PodSpec {
                pod_id: 77,
                deployment_id: 1,
                image: "process".into(),
                entrypoint: String::new(),
                port: 0,
                gpu_count: 0,
                gpu_type: crate::types::GpuType::None,
                cpu_millicores: 100,
                memory_megabytes: 128,
                env_vars: Vec::new(),
                mounts: Vec::new(),
            })
            .unwrap();

        runtime.stop_pod(&handle, 0).unwrap();
        assert!(matches!(
            runtime.pod_status(&handle),
            Ok(PodStatus::Stopped { .. })
        ));
        runtime.remove_pod(&handle).unwrap();
        assert!(matches!(
            runtime.pod_status(&handle),
            Err(RuntimeError::ContainerNotFound(_))
        ));
    }

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

    fn serve_response(response: Vec<u8>) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 4096];
            let _ = stream.read(&mut request);
            let _ = stream.write_all(&response);
        });
        port
    }

    #[test]
    fn probe_accepts_only_exact_200_status() {
        assert!(probe_http(
            serve_response(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".to_vec()),
            "/health?full=1"
        )
        .unwrap());
        assert!(!probe_http(
            serve_response(b"HTTP/1.0 204 No Content\r\n\r\n".to_vec()),
            "/health"
        )
        .unwrap());
    }

    #[test]
    fn probe_rejects_500_response_with_200_in_body() {
        let response =
            b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 3\r\n\r\n200".to_vec();
        assert!(!probe_http(serve_response(response), "/health").unwrap());
    }

    #[test]
    fn probe_rejects_malformed_oversized_and_unsafe_status_lines() {
        for response in [
            b"not-http 200\r\n\r\n".to_vec(),
            b"HTTP/1.1 200\r\n".to_vec(),
            {
                let mut line = b"HTTP/1.1 200 ".to_vec();
                line.extend(std::iter::repeat_n(b'x', 1024));
                line.extend_from_slice(b"\r\n\r\n");
                line
            },
            b"HTTP/1.1 200 OK\0unsafe\r\n\r\n".to_vec(),
        ] {
            assert!(probe_http(serve_response(response), "/health").is_err());
        }
    }

    #[test]
    fn probe_total_deadline_stops_trickle_status_line() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 4096];
            let _ = stream.read(&mut request);
            for byte in b"HTTP/1.1 200 OK\r\n" {
                if stream.write_all(&[*byte]).is_err() {
                    return;
                }
                thread::sleep(Duration::from_millis(350));
            }
        });

        let started = Instant::now();
        assert!(probe_http(port, "/health").is_err());
        assert!(
            started.elapsed() < Duration::from_millis(5_750),
            "probe exceeded its total deadline: {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn probe_rejects_request_target_header_injection() {
        let error = probe_http(1, "/health\r\nX-Injected: yes").unwrap_err();
        assert!(error.contains("unsafe request-target bytes"));
    }

    #[test]
    fn forward_run_accepts_exact_maximum_body() {
        let body = vec![b'x'; MAX_RUN_RESPONSE_BODY];
        let mut response =
            format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", body.len()).into_bytes();
        response.extend_from_slice(&body);
        assert_eq!(
            forward_run(serve_response(response), b"x").unwrap().len(),
            MAX_RUN_RESPONSE_BODY
        );
    }

    #[test]
    fn forward_run_rejects_oversized_declared_and_chunked_bodies() {
        let declared = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n",
            MAX_RUN_RESPONSE_BODY + 1
        )
        .into_bytes();
        assert!(matches!(
            forward_run(serve_response(declared), b"x"),
            Err(RuntimeError::ResponseTooLarge(_))
        ));

        let body = vec![b'y'; MAX_RUN_RESPONSE_BODY + 1];
        let mut chunked = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".to_vec();
        chunked.extend_from_slice(format!("{:x}\r\n", body.len()).as_bytes());
        chunked.extend_from_slice(&body);
        chunked.extend_from_slice(b"\r\n0\r\n\r\n");
        assert!(matches!(
            forward_run(serve_response(chunked), b"x"),
            Err(RuntimeError::ResponseTooLarge(_))
        ));
    }

    #[test]
    fn forward_run_total_deadline_stops_trickle_body() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 4096];
            let _ = stream.read(&mut request);
            let _ = stream.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
            for _ in 0..20 {
                let _ = stream.write_all(b"1\r\nx\r\n");
                thread::sleep(Duration::from_millis(20));
            }
        });
        let started = Instant::now();
        assert!(forward_run_with_deadline(port, b"x", Duration::from_millis(80)).is_err());
        assert!(started.elapsed() < Duration::from_millis(250));
    }
}
