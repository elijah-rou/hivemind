use crate::types::GpuType;

#[derive(Debug)]
pub struct NodeFingerprint {
    pub node_name: String,
    pub cpu_millicores: u32,
    pub memory_megabytes: u32,
    pub gpu_type: GpuType,
    pub gpu_count: u8,
    pub gpu_memory_megabytes: u32,
}

#[derive(Debug)]
pub enum FingerprintError {
    CpuInfoRead(std::io::Error),
    CpuInfoParse(String),
    MemInfoRead(std::io::Error),
    MemInfoParse(String),
    Hostname(std::io::Error),
}

pub fn fingerprint() -> Result<NodeFingerprint, FingerprintError> {
    let node_name = get_hostname()?;
    let cpu_millicores = read_cpu_millicores()?;
    let memory_megabytes = read_memory_megabytes()?;
    let (gpu_type, gpu_count, gpu_memory_megabytes) = discover_gpus();

    Ok(NodeFingerprint {
        node_name,
        cpu_millicores,
        memory_megabytes,
        gpu_type,
        gpu_count,
        gpu_memory_megabytes,
    })
}

fn read_cpu_millicores() -> Result<u32, FingerprintError> {
    let content =
        std::fs::read_to_string("/proc/cpuinfo").map_err(FingerprintError::CpuInfoRead)?;
    parse_cpuinfo(&content)
}

fn read_memory_megabytes() -> Result<u32, FingerprintError> {
    let content =
        std::fs::read_to_string("/proc/meminfo").map_err(FingerprintError::MemInfoRead)?;
    parse_meminfo(&content)
}

fn parse_cpuinfo(content: &str) -> Result<u32, FingerprintError> {
    let core_count = content
        .lines()
        .filter(|line| line.starts_with("processor"))
        .count();

    if core_count == 0 {
        return Err(FingerprintError::CpuInfoParse(
            "no processor entries found".into(),
        ));
    }

    Ok(core_count as u32 * 1000)
}

fn parse_meminfo(content: &str) -> Result<u32, FingerprintError> {
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("MemTotal:") {
            let kb_str = rest.trim().trim_end_matches(" kB").trim();
            let kb: u64 = kb_str.parse().map_err(|_| {
                FingerprintError::MemInfoParse(format!("invalid MemTotal value: {kb_str}"))
            })?;
            return Ok((kb / 1024) as u32);
        }
    }

    Err(FingerprintError::MemInfoParse("MemTotal not found".into()))
}

pub fn classify_gpu(name: &str, memory_mb: u32) -> GpuType {
    let upper = name.to_uppercase();

    if upper.contains("A100") {
        if memory_mb <= 42_000 {
            return GpuType::A100_40;
        }
        return GpuType::A100_80;
    }

    if upper.contains("H100") {
        if upper.contains("SXM") {
            return GpuType::H100Sxm;
        }
        return GpuType::H100Pcie;
    }

    if upper.contains("H200") {
        return GpuType::H200;
    }

    if upper.contains("L40S") {
        return GpuType::L40s;
    }

    if upper.contains("A10G") {
        return GpuType::A10g;
    }

    if upper.contains("T4") && !upper.contains("RTX") {
        return GpuType::T4;
    }

    eprintln!("warning: unknown GPU type: {name}");
    GpuType::None
}

#[cfg(target_os = "linux")]
fn discover_gpus() -> (GpuType, u8, u32) {
    let nvml = match nvml_wrapper::Nvml::init() {
        Ok(n) => n,
        Err(_) => return (GpuType::None, 0, 0),
    };

    let count = match nvml.device_count() {
        Ok(c) => c,
        Err(_) => return (GpuType::None, 0, 0),
    };

    if count == 0 {
        return (GpuType::None, 0, 0);
    }

    let device = match nvml.device_by_index(0) {
        Ok(d) => d,
        Err(_) => return (GpuType::None, 0, 0),
    };

    let name = device.name().unwrap_or_default();
    let memory_mb = device
        .memory_info()
        .map(|m| (m.total / (1024 * 1024)) as u32)
        .unwrap_or(0);

    let gpu_type = classify_gpu(&name, memory_mb);

    // Assumes homogeneous GPUs per node (matches control plane model)
    if count > 1 {
        if let Ok(other) = nvml.device_by_index(1) {
            let other_name = other.name().unwrap_or_default();
            if other_name != name {
                eprintln!(
                    "warning: mixed GPU types detected ({name} vs {other_name}), using first device"
                );
            }
        }
    }

    (gpu_type, count as u8, memory_mb)
}

#[cfg(not(target_os = "linux"))]
fn discover_gpus() -> (GpuType, u8, u32) {
    (GpuType::None, 0, 0)
}

fn get_hostname() -> Result<String, FingerprintError> {
    let mut buf = [0u8; 64];

    // SAFETY: gethostname writes into a fixed buffer, we check the return value
    let ret = unsafe { libc::gethostname(buf.as_mut_ptr() as *mut libc::c_char, buf.len()) };

    if ret != 0 {
        return Err(FingerprintError::Hostname(std::io::Error::last_os_error()));
    }

    let len = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    Ok(String::from_utf8_lossy(&buf[..len]).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gpu_type_enum_values_match_zig() {
        assert_eq!(GpuType::None as u8, 0);
        assert_eq!(GpuType::A100_40 as u8, 1);
        assert_eq!(GpuType::A100_80 as u8, 2);
        assert_eq!(GpuType::H100Sxm as u8, 3);
        assert_eq!(GpuType::H100Pcie as u8, 4);
        assert_eq!(GpuType::H200 as u8, 5);
        assert_eq!(GpuType::L40s as u8, 6);
        assert_eq!(GpuType::A10g as u8, 7);
        assert_eq!(GpuType::T4 as u8, 8);
    }

    #[test]
    fn parse_cpuinfo_four_cores() {
        let content = "\
processor\t: 0
model name\t: Intel(R) Xeon(R)
cpu MHz\t\t: 2400.000

processor\t: 1
model name\t: Intel(R) Xeon(R)
cpu MHz\t\t: 2400.000

processor\t: 2
model name\t: Intel(R) Xeon(R)
cpu MHz\t\t: 2400.000

processor\t: 3
model name\t: Intel(R) Xeon(R)
cpu MHz\t\t: 2400.000
";
        assert_eq!(parse_cpuinfo(content).unwrap(), 4000);
    }

    #[test]
    fn parse_cpuinfo_single_core() {
        let content = "processor\t: 0\nmodel name\t: ARM\n";
        assert_eq!(parse_cpuinfo(content).unwrap(), 1000);
    }

    #[test]
    fn parse_cpuinfo_empty_fails() {
        assert!(parse_cpuinfo("").is_err());
    }

    #[test]
    fn parse_meminfo_16gb() {
        let content = "\
MemTotal:       16384000 kB
MemFree:         8192000 kB
MemAvailable:   12000000 kB
";
        assert_eq!(parse_meminfo(content).unwrap(), 16000);
    }

    #[test]
    fn parse_meminfo_512gb() {
        let content = "MemTotal:       536870912 kB\n";
        assert_eq!(parse_meminfo(content).unwrap(), 524288);
    }

    #[test]
    fn parse_meminfo_missing_fails() {
        assert!(parse_meminfo("Buffers: 1234 kB\n").is_err());
    }

    #[test]
    fn classify_a100_40gb() {
        assert_eq!(
            classify_gpu("NVIDIA A100-SXM4-40GB", 40960),
            GpuType::A100_40
        );
    }

    #[test]
    fn classify_a100_80gb() {
        assert_eq!(
            classify_gpu("NVIDIA A100-SXM4-80GB", 81920),
            GpuType::A100_80
        );
    }

    #[test]
    fn classify_h100_sxm() {
        assert_eq!(
            classify_gpu("NVIDIA H100 80GB HBM3 SXM", 81920),
            GpuType::H100Sxm
        );
    }

    #[test]
    fn classify_h100_pcie() {
        assert_eq!(classify_gpu("NVIDIA H100 PCIe", 81920), GpuType::H100Pcie);
    }

    #[test]
    fn classify_h200() {
        assert_eq!(classify_gpu("NVIDIA H200", 143360), GpuType::H200);
    }

    #[test]
    fn classify_l40s() {
        assert_eq!(classify_gpu("NVIDIA L40S", 49152), GpuType::L40s);
    }

    #[test]
    fn classify_a10g() {
        assert_eq!(classify_gpu("NVIDIA A10G", 24576), GpuType::A10g);
    }

    #[test]
    fn classify_t4() {
        assert_eq!(classify_gpu("Tesla T4", 16384), GpuType::T4);
    }

    #[test]
    fn classify_unknown() {
        assert_eq!(classify_gpu("NVIDIA RTX 4090", 24576), GpuType::None);
    }

    #[test]
    fn hostname_returns_something() {
        let name = get_hostname().unwrap();
        assert!(!name.is_empty());
    }
}
