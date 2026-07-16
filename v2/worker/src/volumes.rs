use std::fs;
use std::path::PathBuf;
use std::process::Command;

const MOUNT_BASE: &str = "/tmp/hivemind/mounts";

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
    let mount_dir = PathBuf::from(format!("{MOUNT_BASE}/{pod_id}/juicefs"));
    fs::create_dir_all(&mount_dir).map_err(|e| format!("mkdir {}: {e}", mount_dir.display()))?;

    let meta_url =
        std::env::var("JUICEFS_META_URL").map_err(|_| "JUICEFS_META_URL not set".to_string())?;
    let fs_name = std::env::var("JUICEFS_NAME").unwrap_or_else(|_| "hivemind".to_string());

    let mut cmd = Command::new("juicefs");
    cmd.args([
        "mount",
        &meta_url,
        &mount_dir.to_string_lossy(),
        "--name",
        &fs_name,
        "--subdir",
        juicefs_subpath,
        "-d", // daemonize
    ]);

    let output = cmd
        .output()
        .map_err(|e| format!("juicefs mount exec: {e}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("juicefs mount failed: {stderr}"));
    }

    Ok(VolumeMount {
        pod_id,
        host_path: mount_dir,
        container_path: "/data".to_string(),
    })
}

/// Unmount and clean up a JuiceFS volume for a pod.
pub fn unmount_juicefs(pod_id: u64) {
    let mount_dir = format!("{MOUNT_BASE}/{pod_id}/juicefs");

    let _ = Command::new("juicefs")
        .args(["umount", &mount_dir])
        .output();

    // Also try fusermount as fallback
    let _ = Command::new("fusermount")
        .args(["-uz", &mount_dir])
        .output();

    let pod_dir = format!("{MOUNT_BASE}/{pod_id}");
    let _ = fs::remove_dir_all(&pod_dir);
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
        // Should not panic
        unmount_juicefs(999999);
    }
}
