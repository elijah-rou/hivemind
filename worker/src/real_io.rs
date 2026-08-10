use std::io::{self, ErrorKind, Read};
use std::net::{Shutdown, SocketAddr, TcpStream};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::io::Io;
use crate::message::{ControlMessage, WorkerMessage};
use crate::prng::Prng;
use crate::protocol;

const READ_BUFFER_SIZE: usize = 32 * 1024;

pub struct RealIo {
    stream: TcpStream,
    read_buf: [u8; protocol::MAX_FRAME_PAYLOAD],
    frame_buf: [u8; READ_BUFFER_SIZE],
    frame_pos: usize,
    write_buf: [u8; protocol::MAX_FRAME_PAYLOAD],
    prng: Prng,
    connected: bool,
    encryption_key: Option<[u8; crate::crypto::KEY_LEN]>,
}

impl RealIo {
    pub fn connect(
        addr: &str,
        encryption_key: Option<[u8; crate::crypto::KEY_LEN]>,
    ) -> io::Result<Self> {
        Self::connect_timeout(addr, encryption_key, Duration::from_secs(2))
    }

    pub fn connect_timeout(
        addr: &str,
        encryption_key: Option<[u8; crate::crypto::KEY_LEN]>,
        timeout: Duration,
    ) -> io::Result<Self> {
        if timeout.is_zero() {
            return Err(io::Error::new(
                ErrorKind::InvalidInput,
                "connect timeout is zero",
            ));
        }
        // Resolving hostnames can block outside the deadline. Replica endpoints
        // are therefore explicit IP socket addresses at this runtime boundary.
        let socket_addr: SocketAddr = addr.parse().map_err(|_| {
            io::Error::new(
                ErrorKind::InvalidInput,
                "replica address must be an IP socket address",
            )
        })?;
        let stream = TcpStream::connect_timeout(&socket_addr, timeout)?;
        stream.set_nonblocking(true)?;
        stream.set_nodelay(true)?;

        let seed = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos() as u64;

        Ok(Self {
            stream,
            read_buf: [0u8; protocol::MAX_FRAME_PAYLOAD],
            frame_buf: [0u8; READ_BUFFER_SIZE],
            frame_pos: 0,
            write_buf: [0u8; protocol::MAX_FRAME_PAYLOAD],
            prng: Prng::init(seed),
            connected: true,
            encryption_key,
        })
    }

    pub fn is_connected(&self) -> bool {
        self.connected
    }

    fn decode_buffered_frame(&mut self) -> Option<ControlMessage> {
        match protocol::try_decode_frame(
            &self.frame_buf[..self.frame_pos],
            &mut self.read_buf,
            self.encryption_key.as_ref(),
        ) {
            Ok(Some((msg_type, payload_len, consumed))) => {
                self.frame_buf.copy_within(consumed..self.frame_pos, 0);
                self.frame_pos -= consumed;
                match protocol::decode_control_message(msg_type, &self.read_buf[..payload_len]) {
                    Ok(msg) => Some(msg),
                    Err(e) => {
                        eprintln!("decode failed; terminating control session: {e}");
                        let _ = self.stream.shutdown(Shutdown::Both);
                        self.connected = false;
                        None
                    }
                }
            }
            Ok(None) => None,
            Err(e) => {
                eprintln!("recv failed: {e}");
                self.connected = false;
                None
            }
        }
    }
}

impl Io for RealIo {
    fn now(&self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64
    }

    fn send(&mut self, msg: WorkerMessage) {
        if !self.connected {
            return;
        }

        let result = (|| -> io::Result<()> {
            let (msg_type, payload_len) =
                protocol::encode_agent_message(&msg, &mut self.write_buf)?;
            protocol::write_frame_encrypted(
                &mut self.stream,
                msg_type,
                &self.write_buf[..payload_len],
                self.encryption_key.as_ref(),
            )
        })();

        if let Err(e) = result {
            eprintln!("send failed: {e}");
            self.connected = false;
        }
    }

    fn recv(&mut self) -> Option<ControlMessage> {
        if !self.connected {
            return None;
        }

        loop {
            if let Some(msg) = self.decode_buffered_frame() {
                return Some(msg);
            }
            if !self.connected {
                return None;
            }

            let space = &mut self.frame_buf[self.frame_pos..];
            if space.is_empty() {
                eprintln!("recv failed: frame buffer full");
                self.connected = false;
                return None;
            }

            match self.stream.read(space) {
                Ok(0) => {
                    self.connected = false;
                    return None;
                }
                Ok(n) => {
                    self.frame_pos += n;
                }
                Err(ref e) if e.kind() == ErrorKind::WouldBlock => return None,
                Err(ref e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(e) => {
                    eprintln!("recv failed: {e}");
                    self.connected = false;
                    return None;
                }
            }
        }
    }

    fn random_u64(&mut self) -> u64 {
        self.prng.next()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::io::Io;
    use std::io::Write;
    use std::net::TcpListener;
    use std::thread;
    use std::time::Duration;

    fn run_request_frame(request_id: u64, deployment_id: u64, body: &[u8]) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&request_id.to_le_bytes());
        payload.extend_from_slice(&deployment_id.to_le_bytes());
        payload.extend_from_slice(&(body.len() as u32).to_le_bytes());
        payload.extend_from_slice(body);

        let mut frame = Vec::new();
        protocol::write_frame(&mut frame, 0x04, &payload).unwrap();
        frame
    }

    fn recv_until(io: &mut RealIo) -> ControlMessage {
        for _ in 0..32 {
            if let Some(msg) = io.recv() {
                return msg;
            }
            thread::sleep(Duration::from_millis(1));
        }
        panic!("timed out waiting for message");
    }

    #[test]
    fn bounded_connect_rejects_unbounded_hostname_resolution_and_zero_timeout() {
        let hostname_error =
            RealIo::connect_timeout("replica.example:9000", None, Duration::from_secs(1))
                .err()
                .expect("hostname must be rejected");
        assert_eq!(hostname_error.kind(), ErrorKind::InvalidInput);

        let timeout_error = RealIo::connect_timeout("127.0.0.1:9000", None, Duration::ZERO)
            .err()
            .expect("zero timeout must be rejected");
        assert_eq!(timeout_error.kind(), ErrorKind::InvalidInput);
    }

    #[test]
    fn recv_preserves_partial_frame_and_decodes_following_frames() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let mut io = RealIo::connect(&addr.to_string(), None).unwrap();
        let (mut server, _) = listener.accept().unwrap();

        let frame_one = run_request_frame(7, 11, b"first");
        let frame_two = run_request_frame(8, 12, b"second");

        server.write_all(&frame_one[..4]).unwrap();
        assert!(io.recv().is_none());
        assert!(io.is_connected());

        server.write_all(&frame_one[4..]).unwrap();
        server.write_all(&frame_two).unwrap();

        match recv_until(&mut io) {
            ControlMessage::RunRequest(cmd) => {
                assert_eq!(cmd.request_id, 7);
                assert_eq!(cmd.deployment_id, 11);
                assert_eq!(cmd.payload, b"first");
            }
            _ => panic!("expected first run request"),
        }

        match recv_until(&mut io) {
            ControlMessage::RunRequest(cmd) => {
                assert_eq!(cmd.request_id, 8);
                assert_eq!(cmd.deployment_id, 12);
                assert_eq!(cmd.payload, b"second");
            }
            _ => panic!("expected second run request"),
        }
    }

    fn assert_malformed_session_terminates(tag: u8, payload: &[u8]) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let mut io = RealIo::connect(&addr.to_string(), None).unwrap();
        let (mut server, _) = listener.accept().unwrap();

        let mut frame = Vec::new();
        protocol::write_frame(&mut frame, tag, payload).unwrap();
        frame.extend_from_slice(&run_request_frame(9, 10, b"must-not-decode"));
        server.write_all(&frame).unwrap();

        for _ in 0..32 {
            assert!(io.recv().is_none());
            if !io.is_connected() {
                break;
            }
            thread::sleep(Duration::from_millis(1));
        }
        assert!(
            !io.is_connected(),
            "malformed control frame must terminate session"
        );
        assert!(io.recv().is_none());
    }

    #[test]
    fn malformed_control_message_disconnects_session() {
        let mut malformed_start = vec![0u8; 797];
        malformed_start[531] = 0xff;
        assert_malformed_session_terminates(0x02, &malformed_start);
    }

    #[test]
    fn trailing_stop_pod_payload_disconnects_session() {
        assert_malformed_session_terminates(0x03, &[0u8; 17]);
    }

    #[test]
    fn trailing_probe_pod_payload_disconnects_session() {
        assert_malformed_session_terminates(0x05, &[0u8; 9]);
    }

    #[test]
    fn recv_decodes_burst_larger_than_read_buffer_without_disconnect() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let mut io = RealIo::connect(&addr.to_string(), None).unwrap();
        let (mut server, _) = listener.accept().unwrap();

        // Stay within MAX_RUN_PAYLOAD while still exceeding the TCP read staging buffer.
        let body = vec![0x5a; protocol::MAX_RUN_PAYLOAD];
        let mut burst = Vec::new();
        for request_id in 0..80 {
            burst.extend_from_slice(&run_request_frame(request_id, 99, &body));
        }
        assert!(burst.len() > READ_BUFFER_SIZE);
        server.write_all(&burst).unwrap();

        for request_id in 0..80 {
            match recv_until(&mut io) {
                ControlMessage::RunRequest(cmd) => {
                    assert_eq!(cmd.request_id, request_id);
                    assert_eq!(cmd.deployment_id, 99);
                    assert_eq!(cmd.payload, body);
                }
                _ => panic!("expected run request"),
            }
            assert!(io.is_connected());
        }
    }
}
