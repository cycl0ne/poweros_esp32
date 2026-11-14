// SPDX-License-Identifier: MIT
//! platform.resource: what machine this is. `struct ExecBase` is opaque,
//! and the facts a board has to report (the chip, its clocks, where the
//! code and the stacks are, whether there is PSRAM) are the kernel's, not
//! exec's. So they come through a resource, as other machine-level things
//! do - the same shape watchdog.resource and dma.resource already have.
//!
//! Get its base with OpenResource(PLATFORMNAME); its functions are in
//! sdk/interface/platform.zig.

/// The resource's name, for OpenResource.
pub const PLATFORMNAME = "platform.resource";

/// struct PlatformInfo: what GetPlatformInfo fills in. Clear it, pass its
/// size, and trust the bytes it says it wrote - a program on the disk may
/// be older or newer than the ROM that answers it, so fields are only ever
/// added at the end, and the count that comes back says how far the answer
/// reaches. That is `de_TableSize`'s trick, which DosEnvec already uses.
pub const PlatformInfo = extern struct {
    /// The chip, as its maker names it ("ESP32-S3").
    chip: ?[*:0]const u8 = null,
    /// The core inside it, as CpuName has it ("Xtensa LX7").
    core: ?[*:0]const u8 = null,
    /// What it was built with ("zig 0.16.0-xtensa, ReleaseSafe").
    built: ?[*:0]const u8 = null,
    /// PRID: the processor id register, which tells the cores apart.
    prid: u32 = 0,
    /// VECBASE: where the exception vectors are.
    vecbase: usize = 0,

    /// The clock the CPU is configured for, and the one the system
    /// measured against the crystal and actually runs by.
    cpu_hz: u32 = 0,
    measured_cpu_hz: u32 = 0,
    /// The crystal the rest is derived from.
    xtal_hz: u32 = 0,
    /// Whether the PLL was calibrated at boot; without it the configured
    /// clock is a guess and the measured one is what counts.
    pll_calibrated: u32 = 0,
    /// The kernel tick, and the interrupt it runs on. Not timer.device's
    /// units and not Delay's 1/50 s.
    tick_hz: u32 = 0,
    tick_irq: u32 = 0,

    /// The code in internal RAM: the vectors, the exception entry and the
    /// boot code.
    iram_lower: usize = 0,
    iram_upper: usize = 0,
    /// The data and bss, which stay in internal RAM.
    dram_lower: usize = 0,
    dram_upper: usize = 0,
    /// The code in flash, mapped for the instruction bus.
    flash_text_lower: usize = 0,
    flash_text_upper: usize = 0,
    /// The boot stack, which the first task runs on.
    stack_lower: usize = 0,
    stack_upper: usize = 0,

    /// PSRAM: where it is, how many bytes (0: none), and its vendor id.
    psram_base: usize = 0,
    psram_size: usize = 0,
    psram_vendor: u32 = 0,
};

/// CpuFeature's features: instructions a core may bring beyond what every
/// program for its chip is built to. Each is a number, never a mask, and
/// the numbers mean the same on every chip.
///
/// The AES round instructions, both directions.
pub const CPUF_AES: u32 = 0;
/// A carry-less product of two 64-bit words, all 128 bits of it.
pub const CPUF_CLMUL: u32 = 1;
/// The SHA-1 instructions.
pub const CPUF_SHA1: u32 = 2;
/// The SHA-224 and SHA-256 instructions.
pub const CPUF_SHA256: u32 = 3;
/// The SHA-384 and SHA-512 instructions.
pub const CPUF_SHA512: u32 = 4;
/// CRC-32 with the polynomial 0x04C11DB7, Ethernet's and zlib's.
pub const CPUF_CRC32: u32 = 5;
/// CRC-32C, with the polynomial 0x1EDC6F41 (Castagnoli).
pub const CPUF_CRC32C: u32 = 6;
/// One past the last feature there is.
pub const CPUF_COUNT: u32 = 7;

/// The most a CpuName is long, its NUL included.
pub const CPU_NAME_SIZE = 64;

/// SetMemoryType's kinds: every access reaching the machine on its own;
/// writes gathered into bursts, reads as uncached (write-combining); or
/// cached, as memory is.
pub const MEMTYPE_UNCACHED: u32 = 0;
pub const MEMTYPE_GATHERED: u32 = 1;
pub const MEMTYPE_CACHED: u32 = 2;

/// The resource's base, with its functions.
pub const PlatformBase = @import("../interface/platform.zig").PlatformBase;
