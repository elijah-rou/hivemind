use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

const MOUNT_BASE: &str = "/tmp/hivemind/mounts";
const MOUNT_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Debug)]
pub struct VolumeMount {
    pub pod_id: u64,
    pub host_path: PathBuf,
    pub container_path: String,
}

/// Mount a JuiceFS volume for a pod. Returns the host-side mount point
/// to bind into the container at `container_path`.
///
/// Requires `juicefs` binary on PATH and JuiceFS metadata config via env:
///   JUICEFS_META_URL - metadata engine URL (e.g. redis://...)
///   JUICEFS_NAME     - filesystem name
pub fn mount_juicefs(pod_id: u64, juicefs_subpath: &str) -> Result<VolumeMount, String> {
    if !juicefs_subpath.starts_with('/') || juicefs_subpath.contains('\0') {
        return Err("juicefs subpath must be a valid absolute path".into());
    }
    let mount_dir = PathBuf::from(format!("{MOUNT_BASE}/{pod_id}/juicefs"));
    fs::create_dir_all(&mount_dir).map_err(|e| format!("mkdir {}: {e}", mount_dir.display()))?;

    let meta_url =
        std::env::var("JUICEFS_META_URL").map_err(|_| "JUICEFS_META_URL not set".to_string())?;
    let fs_name = std::env::var("JUICEFS_NAME").unwrap_or_else(|_| "hivemind".to_string());

    let timeout = format!("{}s", MOUNT_TIMEOUT.as_secs());
    let output = Command::new("timeout")
        .args([
            "--signal=KILL",
            &timeout,
            "juicefs",
            "mount",
            &meta_url,
            &mount_dir.to_string_lossy(),
            "--name",
            &fs_name,
            "--subdir",
            juicefs_subpath,
            "-d",
        ])
        .output()
        .map_err(|e| format!("bounded juicefs mount exec: {e}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if output.status.code() == Some(124) || output.status.code() == Some(137) {
            return Err(format!(
                "juicefs mount timed out after {}s: {stderr}",
                MOUNT_TIMEOUT.as_secs()
            ));
        }
        return Err(format!("juicefs mount failed: {stderr}"));
    }

    Ok(VolumeMount {
        pod_id,
        host_path: mount_dir,
        container_path: "/data".to_string(),
    })
}

/// Unmount and clean up a JuiceFS volume for a pod.
pub fn unmount_juicefs(pod_id: u64) -> Result<(), String> {
    unmount_juicefs_until(pod_id, Instant::now() + Duration::from_secs(20))
}

pub fn unmount_juicefs_until(pod_id: u64, deadline: Instant) -> Result<(), String> {
    if Instant::now() >= deadline {
        return Err("shutdown deadline reached before volume cleanup".into());
    }
    let command_timeout = || -> Result<String, String> {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err("shutdown deadline reached before volume cleanup".into());
        }
        let timeout_ms = remaining.as_millis().clamp(1, u64::MAX as u128) as u64;
        Ok(format!("{timeout_ms}ms"))
    };

    let mount_dir = format!("{MOUNT_BASE}/{pod_id}/juicefs");
    if mount_is_active(&mount_dir)? {
        let _ = Command::new("timeout")
            .args([&command_timeout()?, "juicefs", "umount", &mount_dir])
            .output();
        if mount_is_active(&mount_dir)? {
            let _ = Command::new("timeout")
                .args([&command_timeout()?, "fusermount", "-uz", &mount_dir])
                .output();
        }
        if mount_is_active(&mount_dir)? {
            return Err(format!("mount remains active at {mount_dir}"));
        }
    }

    let pod_dir = PathBuf::from(format!("{MOUNT_BASE}/{pod_id}"));
    match fs::remove_dir_all(&pod_dir) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(format!("remove {}: {error}", pod_dir.display())),
    }
    if pod_dir.exists() {
        return Err(format!(
            "pod mount directory remains at {}",
            pod_dir.display()
        ));
    }
    Ok(())
}

fn mount_is_active(mount_dir: &str) -> Result<bool, String> {
    let mountinfo = fs::read_to_string("/proc/self/mountinfo")
        .map_err(|error| format!("read mount table: {error}"))?;
    Ok(mountinfo.lines().any(|line| {
        line.split_whitespace()
            .nth(4)
            .is_some_and(|mount_point| mount_point == mount_dir)
    }))
}

/// Check if the juicefs binary is available on PATH.
pub fn juicefs_available() -> bool {
    Command::new("juicefs")
        .arg("version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mount_base_path_format() {
        let expected = format!("{MOUNT_BASE}/42/juicefs");
        assert_eq!(
            PathBuf::from(format!("{MOUNT_BASE}/42/juicefs")),
            PathBuf::from(expected)
        );
    }

    #[test]
    fn unmount_nonexistent_is_safe() {
        unmount_juicefs(999999).unwrap();
    }

    #[test]
    fn expired_shutdown_deadline_rejects_volume_cleanup() {
        let error = unmount_juicefs_until(999998, Instant::now()).unwrap_err();
        assert!(error.contains("shutdown deadline"));
    }

    #[test]
    fn mount_rejects_relative_subpath_before_host_side_effects() {
        let error = mount_juicefs(999997, "relative/path").unwrap_err();
        assert!(error.contains("absolute path"));
        assert!(!PathBuf::from(format!("{MOUNT_BASE}/999997")).exists());
    }
}
