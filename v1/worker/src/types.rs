/// Mirrors the Zig GpuType enum(u8) from src/message.zig.
/// Values MUST stay in sync with the control plane.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GpuType {
    None = 0,
    A100_40 = 1,
    A100_80 = 2,
    H100Sxm = 3,
    H100Pcie = 4,
    H200 = 5,
    L40s = 6,
    A10g = 7,
    T4 = 8,
}
