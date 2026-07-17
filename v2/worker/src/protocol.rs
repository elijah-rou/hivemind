use std::io::{self, Read, Write};

use crate::message::*;
use crate::types::GpuType;

// -- Message type constants --

const MSG_REGISTER_ACK: u8 = 0x01;
const MSG_START_POD: u8 = 0x02;
const MSG_STOP_POD: u8 = 0x03;
const MSG_PROBE_POD: u8 = 0x05;
const MSG_RUN_REQUEST: u8 = 0x04;
/// Must match v2/core/src/request_queue.zig MAX_PAYLOAD.
pub const MAX_RUN_PAYLOAD: usize = 512;
/// Shared worker response-body bound. RunResponse metadata consumes 9 frame-payload bytes.
pub const MAX_RUN_RESPONSE_BODY: usize = MAX_FRAME_PAYLOAD - 9;
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunStatus {
    Ok = 0,
    DeploymentNotFound = 1,
    QueueFull = 2,
    InvalidPayload = 3,
    ResponseTooLarge = 4,
    OutcomeAmbiguous = 5,
    ForwardingFailed = 6,
    NoRunningPod = 7,
    Unavailable = 8,
}

pub const RUN_STATUS_RESPONSE_TOO_LARGE: u8 = RunStatus::ResponseTooLarge as u8;
pub const RUN_STATUS_FORWARDING_FAILED: u8 = RunStatus::ForwardingFailed as u8;
pub const RUN_STATUS_NO_RUNNING_POD: u8 = RunStatus::NoRunningPod as u8;

const MSG_NODE_REGISTER: u8 = 0x10;
const MSG_NODE_HEARTBEAT: u8 = 0x11;
const MSG_POD_STATUS_EVENT: u8 = 0x12;
const MSG_RUN_RESPONSE: u8 = 0x13;

// -- Wire structs: fixed-size, packed, little-endian byte-copy --

// StartPod is parsed field-by-field (no packed struct) to match the Zig
// dispatchPodToAgent layout which includes entrypoint, port, juicefs_path,
// probe paths, and env vars.

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct WireStopPod {
    pod_id: u64,
    grace_period_ms: u64,
}

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct WireProbePod {
    pod_id: u64,
}

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct WireNodeRegister {
    hostname: [u8; 64],
    cpu_millicores: u32,
    memory_megabytes: u32,
    gpu_type: u8,
    gpu_count: u8,
    provider: [u8; 32],
    region: [u8; 32],
}

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct WireNodeHeartbeat {
    timestamp: u64,
    cpu_usage_pct: u8,
    memory_used_mb: u32,
    gpu_utilization: [u8; 8],
    pods_running: u16,
}

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct WirePodStatusEvent {
    pod_id: u64,
    old_phase: u8,
    new_phase: u8,
    timestamp: u64,
    exit_code: i32,
    message: [u8; 128],
}

// -- Frame I/O --
// Frame format: [4B LE len][2B LE version][1B tag][payload...]
// len = 2 (version) + 1 (tag) + payload_len

pub const MAX_FRAME_PAYLOAD: usize = 16 * 1024;
pub const PROTOCOL_VERSION: u16 = 5;
const FRAME_FLAGS_LEN: usize = 1;
const FRAME_INNER_MIN: usize = 3; // version(2) + tag(1)
const ENCRYPTED_FRAME_OVERHEAD: usize = crate::crypto::NONCE_LEN + crate::crypto::TAG_LEN;

fn validate_frame_declaration(
    total_len: usize,
    flags: u8,
    key_configured: bool,
) -> io::Result<usize> {
    if flags != 0x00 && flags != 0x01 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unknown frame flags: 0x{flags:02x}"),
        ));
    }
    if (flags == 0x01) != key_configured {
        let message = if flags == 0x01 {
            "encrypted frame but no key"
        } else {
            "plaintext frame while key configured"
        };
        return Err(io::Error::new(io::ErrorKind::InvalidData, message));
    }

    let remaining = total_len
        .checked_sub(FRAME_FLAGS_LEN)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "frame too short"))?;
    let overhead = if flags == 0x01 {
        ENCRYPTED_FRAME_OVERHEAD
    } else {
        0
    };
    let minimum = overhead + FRAME_INNER_MIN;
    let maximum = overhead + FRAME_INNER_MIN + MAX_FRAME_PAYLOAD;
    if remaining < minimum {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame too short",
        ));
    }
    if remaining > maximum {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame too large: declared={remaining} max={maximum}"),
        ));
    }
    Ok(remaining)
}

fn validate_protocol_version(inner: &[u8]) -> io::Result<()> {
    if inner.len() < FRAME_INNER_MIN {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame payload too short",
        ));
    }
    let version = u16::from_le_bytes(inner[..2].try_into().unwrap());
    if version != PROTOCOL_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unsupported protocol version: {version}"),
        ));
    }
    Ok(())
}

pub fn write_frame(w: &mut impl Write, msg_type: u8, payload: &[u8]) -> io::Result<()> {
    write_frame_encrypted(w, msg_type, payload, None)
}

pub fn write_frame_encrypted(
    w: &mut impl Write,
    msg_type: u8,
    payload: &[u8],
    key: Option<&[u8; crate::crypto::KEY_LEN]>,
) -> io::Result<()> {
    if payload.len() > MAX_FRAME_PAYLOAD {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "frame payload too large: {} > {MAX_FRAME_PAYLOAD}",
                payload.len()
            ),
        ));
    }
    // Build inner: [version(2)][tag(1)][payload...]
    let inner_len = FRAME_INNER_MIN
        .checked_add(payload.len())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "frame length overflow"))?;
    let mut inner = vec![0u8; inner_len];
    inner[0..2].copy_from_slice(&PROTOCOL_VERSION.to_le_bytes());
    inner[2] = msg_type;
    inner[3..].copy_from_slice(payload);

    if let Some(k) = key {
        // Build header first for AAD (must match Zig decodeFrame)
        let enc_payload_len = crate::crypto::NONCE_LEN
            .checked_add(inner.len())
            .and_then(|len| len.checked_add(crate::crypto::TAG_LEN))
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "frame length overflow"))?;
        let frame_len = FRAME_FLAGS_LEN
            .checked_add(enc_payload_len)
            .and_then(|len| u32::try_from(len).ok())
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "frame length overflow"))?;
        let mut header = [0u8; 5];
        header[0..4].copy_from_slice(&frame_len.to_le_bytes());
        header[4] = 0x01; // encrypted

        let encrypted = crate::crypto::encrypt_frame(k, &inner, &header);
        w.write_all(&header)?;
        w.write_all(&encrypted)?;
    } else {
        let frame_len = FRAME_FLAGS_LEN
            .checked_add(inner_len)
            .and_then(|len| u32::try_from(len).ok())
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "frame length overflow"))?;
        w.write_all(&frame_len.to_le_bytes())?;
        w.write_all(&[0x00])?; // flags: plaintext
        w.write_all(&inner)?;
    }
    w.flush()
}

pub fn read_frame(r: &mut impl Read, buf: &mut [u8]) -> io::Result<(u8, usize)> {
    read_frame_encrypted(r, buf, None)
}

pub fn try_decode_frame(
    data: &[u8],
    buf: &mut [u8],
    key: Option<&[u8; crate::crypto::KEY_LEN]>,
) -> io::Result<Option<(u8, usize, usize)>> {
    if data.len() < 5 {
        return Ok(None);
    }

    let total_len = u32::from_le_bytes(data[0..4].try_into().unwrap()) as usize;
    let flags = data[4];
    let remaining = validate_frame_declaration(total_len, flags, key.is_some())?;
    let frame_len = 4usize
        .checked_add(total_len)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "frame length overflow"))?;
    if data.len() < frame_len {
        return Ok(None);
    }
    let frame_payload = &data[5..frame_len];

    let decrypted;
    let plaintext = if flags == 0x01 {
        decrypted = crate::crypto::decrypt_frame(key.unwrap(), frame_payload, &data[0..5])
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        decrypted.as_slice()
    } else {
        frame_payload
    };
    validate_protocol_version(plaintext)?;

    let msg_type = plaintext[2];
    let payload_len = plaintext.len() - FRAME_INNER_MIN;
    if payload_len > buf.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "frame too large: payload={payload_len} buffer={}",
                buf.len()
            ),
        ));
    }
    if payload_len > 0 {
        buf[..payload_len].copy_from_slice(&plaintext[FRAME_INNER_MIN..]);
    }
    debug_assert_eq!(remaining, frame_payload.len());
    Ok(Some((msg_type, payload_len, frame_len)))
}

pub fn read_frame_encrypted(
    r: &mut impl Read,
    buf: &mut [u8],
    key: Option<&[u8; crate::crypto::KEY_LEN]>,
) -> io::Result<(u8, usize)> {
    let mut len_bytes = [0u8; 4];
    r.read_exact(&mut len_bytes)?;
    let total_len = u32::from_le_bytes(len_bytes) as usize;

    let mut flags = [0u8; 1];
    r.read_exact(&mut flags)?;
    let remaining = validate_frame_declaration(total_len, flags[0], key.is_some())?;

    if flags[0] == 0x01 {
        // The declaration is bounded before this allocation.
        let mut enc_buf = vec![0u8; remaining];
        r.read_exact(&mut enc_buf)?;

        let mut aad = [0u8; 5];
        aad[0..4].copy_from_slice(&len_bytes);
        aad[4] = flags[0];
        let plaintext = crate::crypto::decrypt_frame(key.unwrap(), &enc_buf, &aad)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        validate_protocol_version(&plaintext)?;

        let msg_type = plaintext[2];
        let payload_len = plaintext.len() - FRAME_INNER_MIN;
        if payload_len > buf.len() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "frame too large: payload={payload_len} buffer={}",
                    buf.len()
                ),
            ));
        }
        buf[..payload_len].copy_from_slice(&plaintext[FRAME_INNER_MIN..]);
        return Ok((msg_type, payload_len));
    }

    let mut inner_header = [0u8; FRAME_INNER_MIN];
    r.read_exact(&mut inner_header)?;
    validate_protocol_version(&inner_header)?;
    let payload_len = remaining - FRAME_INNER_MIN;
    if payload_len > buf.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "frame too large: payload={payload_len} buffer={}",
                buf.len()
            ),
        ));
    }
    if payload_len > 0 {
        r.read_exact(&mut buf[..payload_len])?;
    }
    Ok((inner_header[2], payload_len))
}

// -- Encode agent messages to wire bytes --

pub fn encode_agent_message(msg: &WorkerMessage, buf: &mut [u8]) -> io::Result<(u8, usize)> {
    match msg {
        WorkerMessage::NodeRegister(m) => {
            let wire = WireNodeRegister {
                hostname: str_to_fixed(&m.node_name),
                cpu_millicores: m.cpu_millicores,
                memory_megabytes: m.memory_megabytes,
                gpu_type: m.gpu_type as u8,
                gpu_count: m.gpu_count,
                provider: [0u8; 32],
                region: [0u8; 32],
            };
            let bytes = as_bytes(&wire);
            buf[..bytes.len()].copy_from_slice(bytes);
            Ok((MSG_NODE_REGISTER, bytes.len()))
        }

        WorkerMessage::NodeHeartbeat(m) => {
            let wire = WireNodeHeartbeat {
                timestamp: m.tick,
                cpu_usage_pct: 0,
                memory_used_mb: 0,
                gpu_utilization: [0u8; 8],
                pods_running: m.active_pods as u16,
            };
            let bytes = as_bytes(&wire);
            buf[..bytes.len()].copy_from_slice(bytes);
            Ok((MSG_NODE_HEARTBEAT, bytes.len()))
        }

        WorkerMessage::PodStatusEvent(m) => {
            let (new_phase, exit_code, message) = match &m.status {
                PodStatusReport::ImagePulling => (0u8, 0i32, "pulling"),
                PodStatusReport::Creating => (1, 0, "creating"),
                PodStatusReport::Running => (2, 0, "running"),
                PodStatusReport::Stopped { exit_code } => (3, *exit_code, "stopped"),
                PodStatusReport::Failed { reason } => (4, 1, reason.as_str()),
            };

            let wire = WirePodStatusEvent {
                pod_id: m.pod_id,
                old_phase: 0,
                new_phase,
                timestamp: 0,
                exit_code,
                message: str_to_fixed(message),
            };
            let bytes = as_bytes(&wire);
            buf[..bytes.len()].copy_from_slice(bytes);
            Ok((MSG_POD_STATUS_EVENT, bytes.len()))
        }

        WorkerMessage::RunResponse(m) => {
            // Payload: request_id(u64) + status(u8) + response_data.
            // Oversize output is an explicit error response, never successful truncation.
            const HEADER: usize = 9;
            if buf.len() < HEADER {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "RunResponse buffer too small",
                ));
            }
            buf[0..8].copy_from_slice(&m.request_id.to_le_bytes());
            if m.payload.len() > MAX_RUN_RESPONSE_BODY {
                buf[8] = RUN_STATUS_RESPONSE_TOO_LARGE;
                return Ok((MSG_RUN_RESPONSE, HEADER));
            }
            if m.payload.len() > buf.len() - HEADER {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "RunResponse buffer too small",
                ));
            }
            buf[8] = m.status;
            buf[HEADER..HEADER + m.payload.len()].copy_from_slice(&m.payload);
            Ok((MSG_RUN_RESPONSE, HEADER + m.payload.len()))
        }
    }
}

// -- Decode control plane messages from wire bytes --

pub fn decode_control_message(msg_type: u8, payload: &[u8]) -> io::Result<ControlMessage> {
    match msg_type {
        MSG_START_POD => {
            // Fixed header: pod_id(8) + dep_id(8) + image(256) + entrypoint(256) +
            //   port(2) + gpu_count(1) + gpu_type(1) + cpu(4) + mem(4) +
            //   juicefs_path(128) + liveness_path(64) + readiness_path(64) + env_count(1)
            const FIXED_SIZE: usize = 8 + 8 + 256 + 256 + 2 + 1 + 1 + 4 + 4 + 128 + 64 + 64 + 1;
            if payload.len() < FIXED_SIZE {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "StartPod payload too short",
                ));
            }
            let mut pos = 0;
            let pod_id = u64::from_le_bytes(payload[pos..pos + 8].try_into().unwrap());
            pos += 8;
            let deployment_id = u64::from_le_bytes(payload[pos..pos + 8].try_into().unwrap());
            pos += 8;
            let image = fixed_to_string(&payload[pos..pos + 256]);
            pos += 256;
            let entrypoint = fixed_to_string(&payload[pos..pos + 256]);
            pos += 256;
            let port = u16::from_le_bytes(payload[pos..pos + 2].try_into().unwrap());
            pos += 2;
            let gpu_count = payload[pos];
            pos += 1;
            let gpu_type = u8_to_gpu_type(payload[pos])?;
            pos += 1;
            let cpu_millicores = u32::from_le_bytes(payload[pos..pos + 4].try_into().unwrap());
            pos += 4;
            let memory_megabytes = u32::from_le_bytes(payload[pos..pos + 4].try_into().unwrap());
            pos += 4;
            let juicefs_path = fixed_to_string(&payload[pos..pos + 128]);
            pos += 128;
            let liveness_path = fixed_to_string(&payload[pos..pos + 64]);
            pos += 64;
            let readiness_path = fixed_to_string(&payload[pos..pos + 64]);
            pos += 64;
            let env_count = payload[pos] as usize;
            pos += 1;
            const ENV_ENTRY_SIZE: usize = 64 + 256 + 1; // name + value + is_secret
            let env_bytes = env_count.checked_mul(ENV_ENTRY_SIZE).ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "StartPod env length overflow")
            })?;
            let env_end = pos.checked_add(env_bytes).ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "StartPod env length overflow")
            })?;
            if env_end > payload.len() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "StartPod env entries truncated",
                ));
            }
            let mut env_vars = Vec::with_capacity(env_count);
            for _ in 0..env_count {
                let name = fixed_to_string(&payload[pos..pos + 64]);
                pos += 64;
                let value = fixed_to_string(&payload[pos..pos + 256]);
                pos += 256;
                let is_secret_ref = decode_bool(payload[pos], "StartPod env secret flag")?;
                pos += 1;
                env_vars.push(EnvEntry {
                    name,
                    value,
                    is_secret_ref,
                });
            }

            let mut image_pull_registry = String::new();
            let mut image_pull_username = String::new();
            let mut image_pull_password = String::new();
            let mut image_pull_password_is_secret = false;

            const REGISTRY_AUTH_TRAILER_SIZE: usize = 1 + 128 + 64 + 256 + 1;
            let remaining = payload.len() - pos;
            if remaining != 0 {
                if remaining != REGISTRY_AUTH_TRAILER_SIZE || payload[pos] != 0x01 {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "StartPod registry auth trailer invalid",
                    ));
                }
                pos += 1;
                image_pull_registry = fixed_to_string(&payload[pos..pos + 128]);
                pos += 128;
                image_pull_username = fixed_to_string(&payload[pos..pos + 64]);
                pos += 64;
                image_pull_password = fixed_to_string(&payload[pos..pos + 256]);
                pos += 256;
                image_pull_password_is_secret =
                    decode_bool(payload[pos], "StartPod image pull secret flag")?;
                pos += 1;
            }
            if pos != payload.len() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "StartPod payload has trailing bytes",
                ));
            }

            Ok(ControlMessage::StartPod(StartPodCmd {
                pod_id,
                deployment_id,
                image,
                entrypoint,
                port,
                gpu_count,
                gpu_type,
                cpu_millicores,
                memory_megabytes,
                juicefs_path,
                liveness_path,
                readiness_path,
                env_vars,
                image_pull_registry,
                image_pull_username,
                image_pull_password,
                image_pull_password_is_secret,
            }))
        }

        MSG_STOP_POD => {
            if payload.len() != std::mem::size_of::<WireStopPod>() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "StopPod payload length invalid",
                ));
            }
            let wire: WireStopPod = from_bytes(payload);
            Ok(ControlMessage::StopPod(StopPodCmd {
                pod_id: wire.pod_id,
                grace_period_ms: wire.grace_period_ms,
            }))
        }

        MSG_PROBE_POD => {
            if payload.len() != std::mem::size_of::<WireProbePod>() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "ProbePod payload length invalid",
                ));
            }
            let wire: WireProbePod = from_bytes(payload);
            Ok(ControlMessage::ProbePod(ProbePodCmd {
                pod_id: wire.pod_id,
            }))
        }

        MSG_RUN_REQUEST => {
            // Payload: request_id(u64) + deployment_id(u64) + payload_len(u32) + payload
            // Exact length contract: declared len must match trailing bytes; <= MAX_RUN_PAYLOAD.
            const HEADER: usize = 20;
            if payload.len() < HEADER {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "RunRequest payload too short",
                ));
            }
            let request_id = u64::from_le_bytes(payload[0..8].try_into().unwrap());
            let deployment_id = u64::from_le_bytes(payload[8..16].try_into().unwrap());
            let declared_len = u32::from_le_bytes(payload[16..20].try_into().unwrap()) as usize;
            let body = &payload[HEADER..];
            if declared_len > MAX_RUN_PAYLOAD || body.len() != declared_len {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "RunRequest payload length mismatch",
                ));
            }
            Ok(ControlMessage::RunRequest(RunRequestCmd {
                request_id,
                deployment_id,
                payload: body.to_vec(),
            }))
        }

        _ => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unknown message type: 0x{msg_type:02x}"),
        )),
    }
}

// -- Helpers --

fn str_to_fixed<const N: usize>(s: &str) -> [u8; N] {
    let mut buf = [0u8; N];
    let len = s.len().min(N);
    buf[..len].copy_from_slice(&s.as_bytes()[..len]);
    buf
}

fn fixed_to_string(buf: &[u8]) -> String {
    let len = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..len]).into_owned()
}

fn decode_bool(value: u8, field: &'static str) -> io::Result<bool> {
    match value {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{field} must be 0 or 1, got {value}"),
        )),
    }
}

fn u8_to_gpu_type(v: u8) -> io::Result<GpuType> {
    match v {
        0 => Ok(GpuType::None),
        1 => Ok(GpuType::A100_40),
        2 => Ok(GpuType::A100_80),
        3 => Ok(GpuType::H100Sxm),
        4 => Ok(GpuType::H100Pcie),
        5 => Ok(GpuType::H200),
        6 => Ok(GpuType::L40s),
        7 => Ok(GpuType::A10g),
        8 => Ok(GpuType::T4),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid StartPod GPU type: {v}"),
        )),
    }
}

fn as_bytes<T: Copy>(val: &T) -> &[u8] {
    unsafe { std::slice::from_raw_parts(val as *const T as *const u8, std::mem::size_of::<T>()) }
}

fn from_bytes<T: Copy>(data: &[u8]) -> T {
    assert!(data.len() >= std::mem::size_of::<T>());
    unsafe { std::ptr::read_unaligned(data.as_ptr() as *const T) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_struct_sizes() {
        assert_eq!(std::mem::size_of::<WireStopPod>(), 16);
        assert_eq!(std::mem::size_of::<WireProbePod>(), 8);
        assert_eq!(std::mem::size_of::<WireNodeRegister>(), 138);
        assert_eq!(std::mem::size_of::<WireNodeHeartbeat>(), 23);
        assert_eq!(std::mem::size_of::<WirePodStatusEvent>(), 150);
    }

    #[test]
    fn frame_round_trip() {
        let mut buf = Vec::new();
        write_frame(&mut buf, 0x42, b"hello").unwrap();

        let mut read_buf = [0u8; 256];
        let mut cursor = std::io::Cursor::new(&buf);
        let (msg_type, len) = read_frame(&mut cursor, &mut read_buf).unwrap();

        assert_eq!(msg_type, 0x42);
        assert_eq!(len, 5);
        assert_eq!(&read_buf[..5], b"hello");
    }

    #[test]
    fn frame_empty_payload() {
        let mut buf = Vec::new();
        write_frame(&mut buf, MSG_REGISTER_ACK, &[]).unwrap();

        let mut read_buf = [0u8; 256];
        let mut cursor = std::io::Cursor::new(&buf);
        let (msg_type, len) = read_frame(&mut cursor, &mut read_buf).unwrap();

        assert_eq!(msg_type, MSG_REGISTER_ACK);
        assert_eq!(len, 0);
    }

    #[test]
    fn frame_writer_rejects_oversize_before_writing() {
        let mut output = Vec::new();
        let payload = vec![0x5a; MAX_FRAME_PAYLOAD + 1];
        let error = write_frame(&mut output, 0x42, &payload).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        assert!(output.is_empty());
    }

    #[test]
    fn run_status_wire_golden() {
        let statuses = [
            (RunStatus::Ok, 0),
            (RunStatus::DeploymentNotFound, 1),
            (RunStatus::QueueFull, 2),
            (RunStatus::InvalidPayload, 3),
            (RunStatus::ResponseTooLarge, 4),
            (RunStatus::OutcomeAmbiguous, 5),
            (RunStatus::ForwardingFailed, 6),
            (RunStatus::NoRunningPod, 7),
            (RunStatus::Unavailable, 8),
        ];
        for (status, wire) in statuses {
            assert_eq!(status as u8, wire);
        }
    }

    #[test]
    fn run_response_exact_bound_and_overflow_status() {
        let exact = WorkerMessage::RunResponse(RunResponseMsg {
            request_id: 7,
            status: 0,
            payload: vec![0x5a; MAX_RUN_RESPONSE_BODY],
        });
        let mut buf = [0u8; MAX_FRAME_PAYLOAD];
        let (tag, len) = encode_agent_message(&exact, &mut buf).unwrap();
        assert_eq!(tag, MSG_RUN_RESPONSE);
        assert_eq!(len, MAX_FRAME_PAYLOAD);
        assert_eq!(buf[8], 0);
        assert_eq!(&buf[9..], vec![0x5a; MAX_RUN_RESPONSE_BODY]);

        let overflow = WorkerMessage::RunResponse(RunResponseMsg {
            request_id: 8,
            status: 0,
            payload: vec![0x6b; MAX_RUN_RESPONSE_BODY + 1],
        });
        let (_, len) = encode_agent_message(&overflow, &mut buf).unwrap();
        assert_eq!(len, 9);
        assert_eq!(u64::from_le_bytes(buf[0..8].try_into().unwrap()), 8);
        assert_eq!(buf[8], RUN_STATUS_RESPONSE_TOO_LARGE);
    }

    fn test_frame(
        flags: u8,
        version: u16,
        msg_type: u8,
        key: Option<&[u8; crate::crypto::KEY_LEN]>,
    ) -> Vec<u8> {
        let mut inner = Vec::from(version.to_le_bytes());
        inner.push(msg_type);
        if flags == 0x01 {
            let key = key.expect("encrypted test frame requires key");
            let total_len = 1 + crate::crypto::NONCE_LEN + inner.len() + crate::crypto::TAG_LEN;
            let mut header = [0u8; 5];
            header[..4].copy_from_slice(&(total_len as u32).to_le_bytes());
            header[4] = flags;
            let encrypted = crate::crypto::encrypt_frame(key, &inner, &header);
            return header.into_iter().chain(encrypted).collect();
        }

        let mut frame = Vec::with_capacity(5 + inner.len());
        frame.extend_from_slice(&(1u32 + inner.len() as u32).to_le_bytes());
        frame.push(flags);
        frame.extend_from_slice(&inner);
        frame
    }

    #[test]
    fn streaming_frame_contract_table() {
        let state = crate::crypto::EncryptionState::from_hex(
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        )
        .unwrap();
        let mut oversize = Vec::from(((MAX_FRAME_PAYLOAD + 45) as u32).to_le_bytes());
        oversize.push(0x01);

        let cases = [
            (
                "unknown flags",
                test_frame(0x02, PROTOCOL_VERSION, 0x42, None),
                None,
                false,
            ),
            (
                "bad plaintext version",
                test_frame(0x00, PROTOCOL_VERSION + 1, 0x42, None),
                None,
                false,
            ),
            (
                "bad encrypted version",
                test_frame(0x01, PROTOCOL_VERSION + 1, 0x42, Some(&state.worker_key)),
                Some(&state.worker_key),
                false,
            ),
            (
                "plaintext while key configured",
                test_frame(0x00, PROTOCOL_VERSION, 0x42, None),
                Some(&state.worker_key),
                false,
            ),
            (
                "encrypted without key",
                test_frame(0x01, PROTOCOL_VERSION, 0x42, Some(&state.worker_key)),
                None,
                false,
            ),
            ("short plaintext", vec![1, 0, 0, 0, 0x00], None, false),
            (
                "short encrypted",
                vec![1, 0, 0, 0, 0x01],
                Some(&state.worker_key),
                false,
            ),
            (
                "oversize declaration",
                oversize,
                Some(&state.worker_key),
                false,
            ),
            (
                "valid plaintext minimum",
                test_frame(0x00, PROTOCOL_VERSION, 0x42, None),
                None,
                true,
            ),
            (
                "valid encrypted minimum",
                test_frame(0x01, PROTOCOL_VERSION, 0x42, Some(&state.worker_key)),
                Some(&state.worker_key),
                true,
            ),
        ];

        for (name, frame, key, valid) in cases {
            let mut payload = [0u8; MAX_FRAME_PAYLOAD];
            let streaming =
                read_frame_encrypted(&mut std::io::Cursor::new(&frame), &mut payload, key);
            assert_eq!(streaming.is_ok(), valid, "streaming {name}: {streaming:?}");

            let buffered = try_decode_frame(&frame, &mut payload, key);
            assert_eq!(
                matches!(buffered, Ok(Some(_))),
                valid,
                "buffered {name}: {buffered:?}"
            );
        }
    }

    #[test]
    fn streaming_frame_accepts_exact_payload_boundary() {
        let payload = vec![0x5a; MAX_FRAME_PAYLOAD];
        let mut frame = Vec::new();
        write_frame(&mut frame, 0x42, &payload).unwrap();
        let mut decoded = [0u8; MAX_FRAME_PAYLOAD];
        let (msg_type, payload_len) =
            read_frame(&mut std::io::Cursor::new(frame), &mut decoded).unwrap();
        assert_eq!(msg_type, 0x42);
        assert_eq!(payload_len, MAX_FRAME_PAYLOAD);
        assert_eq!(decoded, payload.as_slice());
    }

    #[test]
    fn buffered_frame_contract_rejects_oversize_before_full_frame_arrives() {
        let mut declaration = [0u8; 5];
        declaration[..4].copy_from_slice(&((MAX_FRAME_PAYLOAD + 5) as u32).to_le_bytes());
        declaration[4] = 0x00;
        let mut payload = [0u8; MAX_FRAME_PAYLOAD];
        let result = try_decode_frame(&declaration, &mut payload, None);
        assert!(
            result.is_err(),
            "oversize declaration must fail immediately"
        );
    }

    #[test]
    fn buffered_frame_leaves_trailing_frame_for_next_decode() {
        let first = test_frame(0x00, PROTOCOL_VERSION, 0x41, None);
        let second = test_frame(0x00, PROTOCOL_VERSION, 0x42, None);
        let stream: Vec<u8> = first.iter().chain(&second).copied().collect();
        let mut payload = [0u8; MAX_FRAME_PAYLOAD];
        let (_, _, consumed) = try_decode_frame(&stream, &mut payload, None)
            .unwrap()
            .unwrap();
        assert_eq!(consumed, first.len());
        let (msg_type, _, second_consumed) =
            try_decode_frame(&stream[consumed..], &mut payload, None)
                .unwrap()
                .unwrap();
        assert_eq!(msg_type, 0x42);
        assert_eq!(second_consumed, second.len());
    }

    #[test]
    fn control_message_tags_match_zig_worker_tags() {
        assert_eq!(MSG_REGISTER_ACK, 0x01);
        assert_eq!(MSG_START_POD, 0x02);
        assert_eq!(MSG_STOP_POD, 0x03);
        assert_eq!(MSG_RUN_REQUEST, 0x04);
    }

    #[test]
    fn encode_decode_node_register() {
        let msg = WorkerMessage::NodeRegister(NodeRegisterMsg {
            node_name: "gpu-worker-01".into(),
            cpu_millicores: 64000,
            memory_megabytes: 512000,
            gpu_type: GpuType::H100Sxm,
            gpu_count: 8,
        });

        let mut buf = [0u8; 256];
        let (msg_type, len) = encode_agent_message(&msg, &mut buf).unwrap();

        assert_eq!(msg_type, MSG_NODE_REGISTER);
        assert_eq!(len, 138);

        // Verify hostname at offset 0
        assert_eq!(&buf[..13], b"gpu-worker-01");
        assert_eq!(buf[13], 0); // null terminated
    }

    fn build_start_pod_payload(
        pod_id: u64,
        deployment_id: u64,
        image: &str,
        entrypoint: &str,
        port: u16,
        gpu_count: u8,
        gpu_type: u8,
        cpu_millicores: u32,
        memory_megabytes: u32,
        juicefs_path: &str,
        liveness_path: &str,
        readiness_path: &str,
        env_vars: &[(String, String, bool)],
    ) -> Vec<u8> {
        let mut buf = Vec::new();
        buf.extend_from_slice(&pod_id.to_le_bytes());
        buf.extend_from_slice(&deployment_id.to_le_bytes());
        let mut img = [0u8; 256];
        let len = image.len().min(256);
        img[..len].copy_from_slice(&image.as_bytes()[..len]);
        buf.extend_from_slice(&img);
        let mut ep = [0u8; 256];
        let len = entrypoint.len().min(256);
        ep[..len].copy_from_slice(&entrypoint.as_bytes()[..len]);
        buf.extend_from_slice(&ep);
        buf.extend_from_slice(&port.to_le_bytes());
        buf.push(gpu_count);
        buf.push(gpu_type);
        buf.extend_from_slice(&cpu_millicores.to_le_bytes());
        buf.extend_from_slice(&memory_megabytes.to_le_bytes());
        let mut jfs = [0u8; 128];
        let len = juicefs_path.len().min(128);
        jfs[..len].copy_from_slice(&juicefs_path.as_bytes()[..len]);
        buf.extend_from_slice(&jfs);
        let mut lp = [0u8; 64];
        let len = liveness_path.len().min(64);
        lp[..len].copy_from_slice(&liveness_path.as_bytes()[..len]);
        buf.extend_from_slice(&lp);
        let mut rp = [0u8; 64];
        let len = readiness_path.len().min(64);
        rp[..len].copy_from_slice(&readiness_path.as_bytes()[..len]);
        buf.extend_from_slice(&rp);
        buf.push(env_vars.len() as u8);
        for (name, value, is_secret) in env_vars {
            let mut n = [0u8; 64];
            let len = name.len().min(64);
            n[..len].copy_from_slice(&name.as_bytes()[..len]);
            buf.extend_from_slice(&n);
            let mut v = [0u8; 256];
            let len = value.len().min(256);
            v[..len].copy_from_slice(&value.as_bytes()[..len]);
            buf.extend_from_slice(&v);
            buf.push(if *is_secret { 1 } else { 0 });
        }
        buf
    }

    fn append_start_pod_registry_trailer(
        buf: &mut Vec<u8>,
        registry: &str,
        username: &str,
        password: &str,
        password_is_secret: bool,
    ) {
        buf.push(0x01);
        let mut reg = [0u8; 128];
        let len = registry.len().min(128);
        reg[..len].copy_from_slice(&registry.as_bytes()[..len]);
        buf.extend_from_slice(&reg);
        let mut user = [0u8; 64];
        let len = username.len().min(64);
        user[..len].copy_from_slice(&username.as_bytes()[..len]);
        buf.extend_from_slice(&user);
        let mut pw = [0u8; 256];
        let len = password.len().min(256);
        pw[..len].copy_from_slice(&password.as_bytes()[..len]);
        buf.extend_from_slice(&pw);
        buf.push(if password_is_secret { 1 } else { 0 });
    }

    #[test]
    fn decode_start_pod() {
        let payload = build_start_pod_payload(
            42,
            100,
            "nginx:latest",
            "serve",
            8080,
            2,
            GpuType::H100Sxm as u8,
            4000,
            8192,
            "/data",
            "/health",
            "/ready",
            &[],
        );

        let msg = decode_control_message(MSG_START_POD, &payload).unwrap();

        match msg {
            ControlMessage::StartPod(cmd) => {
                assert_eq!(cmd.pod_id, 42);
                assert_eq!(cmd.deployment_id, 100);
                assert_eq!(cmd.image, "nginx:latest");
                assert_eq!(cmd.entrypoint, "serve");
                assert_eq!(cmd.port, 8080);
                assert_eq!(cmd.gpu_count, 2);
                assert_eq!(cmd.gpu_type, GpuType::H100Sxm);
                assert_eq!(cmd.cpu_millicores, 4000);
                assert_eq!(cmd.memory_megabytes, 8192);
                assert_eq!(cmd.juicefs_path, "/data");
                assert_eq!(cmd.liveness_path, "/health");
                assert_eq!(cmd.readiness_path, "/ready");
                assert_eq!(cmd.env_vars.len(), 0);
                assert!(cmd.image_pull_registry.is_empty());
                assert!(cmd.image_pull_username.is_empty());
                assert!(cmd.image_pull_password.is_empty());
                assert!(!cmd.image_pull_password_is_secret);
            }
            _ => panic!("expected StartPod"),
        }
    }

    #[test]
    fn decode_start_pod_registry_auth_trailer() {
        let mut payload = build_start_pod_payload(
            7,
            200,
            "registry.io/app:1",
            "",
            9090,
            1,
            GpuType::None as u8,
            1000,
            512,
            "",
            "",
            "",
            &[("TOKEN".into(), "doppler-token".into(), true)],
        );
        append_start_pod_registry_trailer(&mut payload, "registry.io", "alice", "s3cr3t", true);
        assert_eq!(payload.len(), 797 + 321 + 450);

        let msg = decode_control_message(MSG_START_POD, &payload).unwrap();
        match msg {
            ControlMessage::StartPod(cmd) => {
                assert_eq!(cmd.pod_id, 7);
                assert_eq!(cmd.deployment_id, 200);
                assert_eq!(cmd.env_vars.len(), 1);
                assert!(cmd.env_vars[0].is_secret_ref);
                assert_eq!(cmd.image_pull_registry, "registry.io");
                assert_eq!(cmd.image_pull_username, "alice");
                assert_eq!(cmd.image_pull_password, "s3cr3t");
                assert!(cmd.image_pull_password_is_secret);
            }
            _ => panic!("expected StartPod"),
        }
    }

    #[test]
    fn decode_start_pod_rejects_missing_env_secret_trailer_and_trailing_bytes() {
        let mut missing_env =
            build_start_pod_payload(1, 2, "img", "", 0, 0, 0, 1, 1, "", "", "", &[]);
        missing_env[796] = 1;
        assert!(decode_control_message(MSG_START_POD, &missing_env).is_err());

        let mut missing_secret_flag =
            build_start_pod_payload(1, 2, "img", "", 0, 0, 0, 1, 1, "", "", "", &[]);
        append_start_pod_registry_trailer(
            &mut missing_secret_flag,
            "registry",
            "user",
            "secret",
            true,
        );
        missing_secret_flag.pop();
        assert!(decode_control_message(MSG_START_POD, &missing_secret_flag).is_err());

        let mut trailing = build_start_pod_payload(1, 2, "img", "", 0, 0, 0, 1, 1, "", "", "", &[]);
        trailing.push(0xff);
        assert!(decode_control_message(MSG_START_POD, &trailing).is_err());
    }

    #[test]
    fn decode_stop_pod() {
        let wire = WireStopPod {
            pod_id: 99,
            grace_period_ms: 5000,
        };

        let bytes = as_bytes(&wire);
        let msg = decode_control_message(MSG_STOP_POD, bytes).unwrap();

        match msg {
            ControlMessage::StopPod(cmd) => {
                assert_eq!(cmd.pod_id, 99);
                assert_eq!(cmd.grace_period_ms, 5000);
            }
            _ => panic!("expected StopPod"),
        }
    }

    #[test]
    fn fixed_control_payloads_require_exact_lengths() {
        let stop = WireStopPod {
            pod_id: 1,
            grace_period_ms: 2,
        };
        let probe = WireProbePod { pod_id: 3 };

        for (tag, exact) in [
            (MSG_STOP_POD, as_bytes(&stop)),
            (MSG_PROBE_POD, as_bytes(&probe)),
        ] {
            assert!(decode_control_message(tag, &exact[..exact.len() - 1]).is_err());
            let mut trailing = exact.to_vec();
            trailing.push(0xff);
            assert!(decode_control_message(tag, &trailing).is_err());
            assert!(decode_control_message(tag, exact).is_ok());
        }
    }

    #[test]
    fn zig_start_pod_tag_decodes_as_start_pod() {
        let payload = build_start_pod_payload(
            42,
            100,
            "nginx:latest",
            "serve",
            8080,
            0,
            GpuType::None as u8,
            1000,
            512,
            "",
            "",
            "",
            &[],
        );

        let msg = decode_control_message(0x02, &payload).unwrap();
        match msg {
            ControlMessage::StartPod(cmd) => {
                assert_eq!(cmd.pod_id, 42);
                assert_eq!(cmd.deployment_id, 100);
            }
            _ => panic!("expected StartPod"),
        }
    }

    #[test]
    fn zig_stop_pod_tag_decodes_as_stop_pod() {
        let wire = WireStopPod {
            pod_id: 77,
            grace_period_ms: 1234,
        };

        let msg = decode_control_message(0x03, as_bytes(&wire)).unwrap();
        match msg {
            ControlMessage::StopPod(cmd) => {
                assert_eq!(cmd.pod_id, 77);
                assert_eq!(cmd.grace_period_ms, 1234);
            }
            _ => panic!("expected StopPod"),
        }
    }

    #[test]
    fn encode_pod_status_event() {
        let msg = WorkerMessage::PodStatusEvent(PodStatusEventMsg {
            pod_id: 7,
            status: PodStatusReport::Running,
        });

        let mut buf = [0u8; 256];
        let (msg_type, len) = encode_agent_message(&msg, &mut buf).unwrap();

        assert_eq!(msg_type, MSG_POD_STATUS_EVENT);
        assert_eq!(len, 150);

        // pod_id at offset 0
        assert_eq!(u64::from_le_bytes(buf[..8].try_into().unwrap()), 7);
        // new_phase at offset 9
        assert_eq!(buf[9], 2); // Running
    }

    #[test]
    fn encode_heartbeat() {
        let msg = WorkerMessage::NodeHeartbeat(NodeHeartbeatMsg {
            tick: 12345,
            active_pods: 3,
            gpu_free: 5,
        });

        let mut buf = [0u8; 64];
        let (msg_type, len) = encode_agent_message(&msg, &mut buf).unwrap();

        assert_eq!(msg_type, MSG_NODE_HEARTBEAT);
        assert_eq!(len, 23);

        // timestamp at offset 0
        assert_eq!(u64::from_le_bytes(buf[..8].try_into().unwrap()), 12345);
    }

    #[test]
    fn str_to_fixed_truncates() {
        let long = "a".repeat(300);
        let fixed: [u8; 64] = str_to_fixed(&long);
        assert_eq!(&fixed[..64], &[b'a'; 64]);
    }

    #[test]
    fn fixed_to_string_strips_nulls() {
        let mut buf = [0u8; 64];
        buf[..5].copy_from_slice(b"hello");
        assert_eq!(fixed_to_string(&buf), "hello");
    }

    #[test]
    fn gpu_type_round_trip() {
        for v in 0u8..=8 {
            let gt = u8_to_gpu_type(v).unwrap();
            assert_eq!(gt as u8, v);
        }
        assert_eq!(
            u8_to_gpu_type(99).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn decode_start_pod_rejects_noncanonical_scalars() {
        let mut invalid_gpu =
            build_start_pod_payload(1, 2, "img", "", 0, 0, 9, 1, 1, "", "", "", &[]);
        let err = decode_control_message(MSG_START_POD, &invalid_gpu).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);

        let mut invalid_env_flag = build_start_pod_payload(
            1,
            2,
            "img",
            "",
            0,
            0,
            0,
            1,
            1,
            "",
            "",
            "",
            &[("TOKEN".into(), "value".into(), false)],
        );
        invalid_env_flag[797 + 64 + 256] = 2;
        let err = decode_control_message(MSG_START_POD, &invalid_env_flag).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);

        invalid_gpu[531] = 0;
        append_start_pod_registry_trailer(&mut invalid_gpu, "registry", "user", "secret", false);
        *invalid_gpu.last_mut().unwrap() = 2;
        let err = decode_control_message(MSG_START_POD, &invalid_gpu).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn full_write_read_round_trip() {
        let msg = WorkerMessage::NodeRegister(NodeRegisterMsg {
            node_name: "test-node".into(),
            cpu_millicores: 8000,
            memory_megabytes: 16384,
            gpu_type: GpuType::T4,
            gpu_count: 1,
        });

        let mut payload_buf = [0u8; 256];
        let (msg_type, payload_len) = encode_agent_message(&msg, &mut payload_buf).unwrap();

        let mut frame_buf = Vec::new();
        write_frame(&mut frame_buf, msg_type, &payload_buf[..payload_len]).unwrap();

        let mut read_buf = [0u8; 256];
        let mut cursor = std::io::Cursor::new(&frame_buf);
        let (read_type, read_len) = read_frame(&mut cursor, &mut read_buf).unwrap();

        assert_eq!(read_type, MSG_NODE_REGISTER);
        assert_eq!(read_len, 138);
    }

    #[test]
    fn encrypted_frame_round_trip_large_payload() {
        let key_state = crate::crypto::EncryptionState::from_hex(
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
        )
        .unwrap();
        let payload = vec![0x5a; 8192];

        let mut frame_buf = Vec::new();
        write_frame_encrypted(
            &mut frame_buf,
            MSG_RUN_REQUEST,
            &payload,
            Some(&key_state.worker_key),
        )
        .unwrap();

        let mut read_buf = [0u8; MAX_FRAME_PAYLOAD];
        let mut cursor = std::io::Cursor::new(&frame_buf);
        let (read_type, read_len) =
            read_frame_encrypted(&mut cursor, &mut read_buf, Some(&key_state.worker_key)).unwrap();

        assert_eq!(read_type, MSG_RUN_REQUEST);
        assert_eq!(read_len, payload.len());
        assert_eq!(&read_buf[..read_len], payload.as_slice());
    }

    // =================================================================
    // Cross-language golden byte tests
    //
    // These use the same known values as src/wire_compat_test.zig.
    // Both sides produce identical packed bytes for the same input.
    // =================================================================

    fn golden_register_msg() -> WorkerMessage {
        WorkerMessage::NodeRegister(NodeRegisterMsg {
            node_name: "test-agent-01".into(),
            cpu_millicores: 32000,
            memory_megabytes: 65536,
            gpu_type: GpuType::H100Sxm,
            gpu_count: 8,
        })
    }

    fn golden_heartbeat_msg() -> WorkerMessage {
        WorkerMessage::NodeHeartbeat(NodeHeartbeatMsg {
            tick: 1234567890,
            active_pods: 4,
            gpu_free: 0,
        })
    }

    fn golden_start_pod_payload() -> Vec<u8> {
        build_start_pod_payload(
            42,
            100,
            "registry.io/model:v1",
            "",
            8080,
            2,
            GpuType::H100Sxm as u8,
            4000,
            8192,
            "",
            "",
            "",
            &[],
        )
    }

    #[test]
    fn golden_register_payload_matches_zig() {
        let msg = golden_register_msg();
        let mut buf = [0u8; 256];
        let (msg_type, len) = encode_agent_message(&msg, &mut buf).unwrap();

        assert_eq!(msg_type, MSG_NODE_REGISTER);
        assert_eq!(len, 138);

        // Hostname at offset 0: "test-agent-01"
        assert_eq!(&buf[..13], b"test-agent-01");
        assert_eq!(buf[13], 0);

        // cpu_millicores at offset 64: 32000 = 0x00007D00 LE
        assert_eq!(buf[64], 0x00);
        assert_eq!(buf[65], 0x7D);
        assert_eq!(buf[66], 0x00);
        assert_eq!(buf[67], 0x00);

        // gpu_type at offset 72: h100_sxm = 3
        assert_eq!(buf[72], 3);
        // gpu_count at offset 73: 8
        assert_eq!(buf[73], 8);
    }

    #[test]
    fn golden_heartbeat_payload_matches_zig() {
        let msg = golden_heartbeat_msg();
        let mut buf = [0u8; 64];
        let (msg_type, len) = encode_agent_message(&msg, &mut buf).unwrap();

        assert_eq!(msg_type, MSG_NODE_HEARTBEAT);
        assert_eq!(len, 23);

        // timestamp at offset 0: 1234567890
        assert_eq!(u64::from_le_bytes(buf[..8].try_into().unwrap()), 1234567890);

        // cpu_usage_pct at offset 8: 0 (we don't expose this field yet)
        assert_eq!(buf[8], 0);

        // pods_running at offset 21: 4 (u16 LE)
        assert_eq!(u16::from_le_bytes(buf[21..23].try_into().unwrap()), 4);
    }

    #[test]
    fn golden_start_pod_decode_matches_zig() {
        let payload = golden_start_pod_payload();

        let msg = decode_control_message(MSG_START_POD, &payload).unwrap();
        match msg {
            ControlMessage::StartPod(cmd) => {
                assert_eq!(cmd.pod_id, 42);
                assert_eq!(cmd.deployment_id, 100);
                assert_eq!(cmd.image, "registry.io/model:v1");
                assert_eq!(cmd.gpu_count, 2);
                assert_eq!(cmd.gpu_type, GpuType::H100Sxm);
                assert_eq!(cmd.cpu_millicores, 4000);
                assert_eq!(cmd.memory_megabytes, 8192);
                assert!(cmd.image_pull_registry.is_empty());
                assert!(cmd.image_pull_username.is_empty());
                assert!(cmd.image_pull_password.is_empty());
                assert!(!cmd.image_pull_password_is_secret);
            }
            _ => panic!("expected StartPod"),
        }
    }

    #[test]
    fn golden_start_pod_bytes_match_zig() {
        let bytes = golden_start_pod_payload();

        // Fixed header: 8+8+256+256+2+1+1+4+4+128+64+64+1 = 797 + 0 env entries
        assert_eq!(bytes.len(), 797);

        // pod_id at offset 0: 42
        assert_eq!(u64::from_le_bytes(bytes[0..8].try_into().unwrap()), 42);
        // deployment_id at offset 8: 100
        assert_eq!(u64::from_le_bytes(bytes[8..16].try_into().unwrap()), 100);
        // image at offset 16: "registry.io/model:v1"
        assert_eq!(&bytes[16..36], b"registry.io/model:v1");
        assert_eq!(bytes[36], 0);
        // entrypoint at offset 272: empty
        assert_eq!(bytes[272], 0);
        // port at offset 528: 8080 LE
        assert_eq!(
            u16::from_le_bytes(bytes[528..530].try_into().unwrap()),
            8080
        );
        // gpu_count at offset 530: 2
        assert_eq!(bytes[530], 2);
        // gpu_type at offset 531: h100_sxm = 3
        assert_eq!(bytes[531], 3);
        // cpu_millicores at offset 532: 4000
        assert_eq!(
            u32::from_le_bytes(bytes[532..536].try_into().unwrap()),
            4000
        );
    }

    fn build_run_request_payload(
        request_id: u64,
        deployment_id: u64,
        declared_len: u32,
        body: &[u8],
    ) -> Vec<u8> {
        let mut payload = Vec::with_capacity(20 + body.len());
        payload.extend_from_slice(&request_id.to_le_bytes());
        payload.extend_from_slice(&deployment_id.to_le_bytes());
        payload.extend_from_slice(&declared_len.to_le_bytes());
        payload.extend_from_slice(body);
        payload
    }

    #[test]
    fn run_request_requires_exact_declared_payload_length() {
        let cases = [
            ("exact zero", 0u32, 0usize, true),
            ("exact max", MAX_RUN_PAYLOAD as u32, MAX_RUN_PAYLOAD, true),
            ("declared short", 8u32, 4usize, false),
            ("declared long trailing", 2u32, 4usize, false),
            (
                "513 byte payload",
                (MAX_RUN_PAYLOAD + 1) as u32,
                MAX_RUN_PAYLOAD + 1,
                false,
            ),
            ("integer overflow size", u32::MAX, 4usize, false),
        ];

        for (name, declared, body_len, expect_ok) in cases {
            let body = vec![0x22u8; body_len];
            let payload = build_run_request_payload(9, 3, declared, &body);
            let result = decode_control_message(MSG_RUN_REQUEST, &payload);
            if expect_ok {
                let msg = result.unwrap_or_else(|e| panic!("{name}: unexpected err {e}"));
                match msg {
                    ControlMessage::RunRequest(cmd) => {
                        assert_eq!(cmd.request_id, 9, "{name}");
                        assert_eq!(cmd.deployment_id, 3, "{name}");
                        assert_eq!(cmd.payload.len(), body_len, "{name}");
                    }
                    _ => panic!("{name}: expected RunRequest"),
                }
            } else {
                assert!(result.is_err(), "{name}: expected rejection");
            }
        }
    }
}
