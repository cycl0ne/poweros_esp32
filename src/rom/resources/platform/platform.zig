// SPDX-License-Identifier: MPL-2.0
//! platform.resource: what machine this is, for anything that is not the
//! kernel. `struct ExecBase` is opaque, so a command can't read these
//! facts from `SysBase`, and what a board has to report is the kernel's
//! knowledge anyway: the chip, the clock it measured against the crystal
//! at boot, where the code in IRAM ends and the code in flash begins,
//! whether the PSRAM came up. It is a resource, as watchdog.resource and
//! dma.resource are: OpenResource gets the base, there is no Open, Close
//! or open count, and the functions start in the first slot of the jump
//! table (sdk/fd/platform_lib.fd).
//!
//! It owns no hardware, and what the clocks and the memory are is taken
//! when it is asked for. That matters, because the tag is RTF_SINGLETASK
//! and runs before `timer.init` has measured anything. What the core is
//! does not change, so that is asked once, at init: its name and the
//! instructions a task may use of it (CpuName, CpuFeature), which
//! `identify.zig` makes of the core's own words - an x86-64 core's
//! identification leaves, an AArch64 core's ID registers, a RISC-V
//! machine's ids from the firmware and its ISA string from the device
//! tree - and the base keeps. The one thing it
//! changes is on request: SetMemoryType, a range of memory made uncached,
//! write-combining or cached in the kernel's map, for a driver of a device
//! that keeps memory of its own.
//!
//! GetPlatformInfo takes the size of the caller's structure and answers
//! with how many bytes it wrote. A program on the flash disk outlives the
//! ROM it was built against, so fields are only ever added to the end of
//! PlatformInfo and a caller checks the count before trusting one near it -
//! DosEnvec's `de_TableSize` trick.

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const arch = @import("../../../arch/arch.zig");
const cpu = arch.cpu;
const clock = arch.clock;
const timer = arch.timer;
const psram = arch.psram;
const layout = arch.layout;
const vec = exec.vec;
const types = sdk.resources.platform;
const PlatformInfo = types.PlatformInfo;
const identify = @import("identify.zig");

pub const RESOURCE_NAME = types.PLATFORMNAME;
const RESOURCE_VERSION = 1;
const RESOURCE_REVISION = 3;
const BUILD_DATE = "14.11.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The board's chip, by name: a constant of the chip the kernel is built
/// for.
const CHIP_NAME = switch (sdk.hardware.chip) {
    .esp32s3 => "ESP32-S3",
    .esp32p4 => "ESP32-P4",
    .rv64sbi => "RISC-V 64 under SBI",
    .a64psci => "AArch64 under PSCI",
    .x64uefi => "x86-64 under UEFI",
};
/// What the kernel was built with, as `Version` and `Platform` print it.
const BUILT_WITH = "zig " ++ builtin.zig_version_string ++ ", " ++ @tagName(builtin.mode);

/// Its functions, as the SDK has them (sdk/fd/platform_lib.fd).
pub const interface = sdk.interface.platform;
pub const LVO = interface.LVO;

// Every function in LVO is an lvo* function here, with the SDK's signature
// (after the base), in its slot.
comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("platform.resource's lvo" ++ d.name ++ " doesn't match the SDK's Fn." ++ d.name);
        }
        if (vectors[@divExact(-@field(LVO, d.name), exec.slot_size) - 1] != vec(f)) {
            @compileError("platform.resource's lvo" ++ d.name ++ " isn't in the slot of LVO." ++ d.name);
        }
    }
}

/// The base. It keeps SysBase and what the core is, which init asked
/// once; every other answer is read from the hardware and the kernel's
/// own variables when it is asked for.
const PlatformBase = extern struct {
    lib: exec.Library,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// The core's name, a C string, and the features a task may use of
    /// it: bit CPUF_x for each.
    cpu_name: identify.Name,
    cpu_features: u32,
};

fn platformBase(lib: *exec.Library) *PlatformBase {
    return @fieldParentPtr("lib", lib);
}

/// The clock the system runs and times by. `timer.init` picks it: the
/// configured one while the measurement agrees with it within 5%, else the
/// measured one. It is 0 until then, and the configured one is the best
/// answer there is.
fn cpuClock() u32 {
    return if (timer.cpu_hz != 0) timer.cpu_hz else clock.cpu_hz;
}

/// The core asked what it is, into the base: the core init runs on, which
/// is the first.
fn identifyCore(pb: *PlatformBase) void {
    pb.cpu_features = 0;
    switch (comptime sdk.hardware.chip) {
        // One core each, with nothing to ask it: the chips' engines for
        // AES and SHA are peripherals, crypto.library's to drive.
        .esp32s3 => identify.fixed(&pb.cpu_name, "Xtensa LX7"),
        .esp32p4 => identify.fixed(&pb.cpu_name, "RISC-V RV32IMAFC"),
        .rv64sbi => {
            const sbi = sdk.hardware.sbi;
            identify.riscvName(&pb.cpu_name, sbi.machineVendor(), sbi.machineArch());
            var length: usize = 0;
            while (length < cpu.isa.len and cpu.isa[length] != 0) length += 1;
            pb.cpu_features = identify.riscvFeatures(cpu.isa[0..length]);
        },
        .a64psci => {
            identify.armName(&pb.cpu_name, cpu.midr());
            pb.cpu_features = identify.armFeatures(cpu.isar0());
        },
        .x64uefi => {
            // The brand string is leaves 0x8000_0002 to 0x8000_0004, each
            // register's bytes lowest first; the vendor's is leaf 0's EBX,
            // EDX and ECX.
            var brand: [48]u8 = @splat(0);
            if (cpu.leaf(0x8000_0000, 0).eax >= 0x8000_0004) {
                for (0..3) |index| {
                    const part = cpu.leaf(0x8000_0002 + @as(u32, @intCast(index)), 0);
                    for ([_]u32{ part.eax, part.ebx, part.ecx, part.edx }, 0..) |word, register| {
                        for (0..4) |byte| brand[index * 16 + register * 4 + byte] = @truncate(word >> @intCast(byte * 8));
                    }
                }
            }
            var vendor: [12]u8 = undefined;
            const first = cpu.leaf(0, 0);
            for ([_]u32{ first.ebx, first.edx, first.ecx }, 0..) |word, register| {
                for (0..4) |byte| vendor[register * 4 + byte] = @truncate(word >> @intCast(byte * 8));
            }
            identify.x86Name(&pb.cpu_name, &brand, &vendor);
            const leaf7_ebx = if (first.eax >= 7) cpu.leaf(7, 0).ebx else 0;
            pb.cpu_features = identify.x86Features(cpu.leaf(1, 0).ecx, leaf7_ebx);
        },
    }
}

fn lvoGetPlatformInfo(pb: *PlatformBase, info: *PlatformInfo, size: u32) callconv(.c) u32 {
    const whole: PlatformInfo = .{
        .chip = CHIP_NAME,
        .core = @ptrCast(&pb.cpu_name),
        .built = BUILT_WITH,
        .prid = cpu.prid(),
        .vecbase = cpu.vecbase(),

        .cpu_hz = clock.cpu_hz,
        .measured_cpu_hz = timer.measured_cpu_hz,
        .xtal_hz = clock.xtal_hz,
        .pll_calibrated = @intFromBool(clock.pll_calibrated),
        .tick_hz = timer.tick_hz,
        .tick_irq = timer.tick_irq,

        .iram_lower = layout.iramStart(),
        .iram_upper = layout.iramEnd(),
        .dram_lower = layout.dramStart(),
        .dram_upper = layout.bssEnd(),
        .flash_text_lower = layout.flashTextStart(),
        .flash_text_upper = layout.flashTextEnd(),
        .stack_lower = layout.stackBottom(),
        .stack_upper = layout.stackTop(),

        .psram_base = if (psram.size != 0) psram.base else 0,
        .psram_size = psram.size,
        .psram_vendor = psram.vendor,
    };
    // As much of it as the caller has room for, and never a partial field:
    // a caller built against another SDK gets whole fields and a count.
    const fits = @min(size, @sizeOf(PlatformInfo));
    if (fits == 0) return 0;
    const from: [*]const u8 = @ptrCast(&whole);
    const into: [*]u8 = @ptrCast(info);
    @memcpy(into[0..fits], from[0..fits]);
    return fits;
}

fn lvoPlatformName(_: *PlatformBase) callconv(.c) [*:0]const u8 {
    return CHIP_NAME;
}

fn lvoCpuClock(_: *PlatformBase) callconv(.c) u32 {
    return cpuClock();
}

fn lvoTickRate(_: *PlatformBase) callconv(.c) u32 {
    return timer.tick_hz;
}

/// The kernel's map and the cores' hold, on the one chip whose map kinds
/// are changed at run time.
const x64 = struct {
    const mmu = @import("../../../arch/x64uefi/mmu.zig");
    const rendezvous = @import("../../../arch/x64uefi/rendezvous.zig");
    const core = @import("../../../arch/x64uefi/cpu.zig");
};

/// A range of memory made uncached, write-combining or cached to the
/// cores.
///
/// SYNOPSIS:
/// ```zig
/// fn SetMemoryType(pb: *PlatformBase, start: usize, length: usize,
///     kind: u32) bool
/// ```
///
/// SINCE: 1.2. LVO -20.
///
/// INPUTS:
/// - `start` - where the range starts, as the CPU addresses it.
/// - `length` - how many bytes.
/// - `kind` - MEMTYPE_UNCACHED, every access reaching the machine on its
///   own; MEMTYPE_GATHERED, writes gathered into bursts and reads as
///   uncached; MEMTYPE_CACHED, as memory is.
///
/// RESULT:
/// True once every core reaches the range as `kind`. False, and nothing
/// changed, where `kind` is none of the three, the range is not mapped in
/// blocks the kernel's map can mark - it lies across two gibibytes, or in
/// the bottom 2 MiB or the kernel's code, or every gibibyte the map keeps
/// for splitting is split already - and on a chip whose memory kinds are
/// fixed, which every chip but x86-64 is.
///
/// BEHAVIOR:
/// The range is taken out to whole 2 MiB blocks, so what shares a block
/// with it changes too. The other cores are held while the map changes and
/// each reloads its map as it is let go. A range that was cached and is
/// not any more has its lines written back and dropped from every core's
/// caches, so nothing of it is written over the memory later.
///
/// CONTEXT:
/// - Waits: no; the other cores are held for a few microseconds.
/// - Interrupts: no - this core's are masked meanwhile.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The range is the caller's to know: the kernel takes the kind it is
/// asked for and checks nothing about what the memory holds. Nothing is
/// allocated.
///
/// NOTES:
/// For a device that keeps its own memory outside the cores' coherent
/// view: gathered for the CPU writing it, cached for the CPU reading it -
/// the caller then drops the lines around the device's use itself, since
/// CachePreDMA and CachePostDMA do nothing on a machine whose devices
/// otherwise see memory as the cores do. Memory the system hands out is
/// cached already and stays so.
///
/// BUGS:
/// A gibibyte once split stays split, and there are four tables to split
/// with: the screen takes one.
///
/// SEE ALSO:
/// `GetPlatformInfo`
///
/// EXAMPLES:
/// ```zig
/// if (!pb.SetMemoryType(piece, 2 * 1024 * 1024, platform.MEMTYPE_GATHERED)) {
///     // stays uncached
/// }
/// ```
pub fn SetMemoryType(_: *PlatformBase, start: usize, length: usize, kind: u32) bool {
    if (comptime sdk.hardware.chip != .x64uefi) return false;
    const wanted: x64.mmu.Kind = switch (kind) {
        types.MEMTYPE_UNCACHED => .uncached,
        types.MEMTYPE_GATHERED => .gathered,
        types.MEMTYPE_CACHED => .cached,
        else => return false,
    };
    if (length == 0 or start +% length < start) return false;
    const range: x64.mmu.Range = .{ .start = start, .end = start + length };
    const state = x64.core.disableInterrupts();
    x64.rendezvous.holdOther();
    const was_cached = x64.mmu.mark(range, wanted);
    x64.rendezvous.releaseOther();
    x64.core.restoreInterrupts(state);
    const cached_before = was_cached orelse return false;
    if (cached_before and wanted != .cached) x64.mmu.dropLines(range);
    return true;
}

fn lvoSetMemoryType(pb: *PlatformBase, start: usize, length: usize, kind: u32) callconv(.c) bool {
    return SetMemoryType(pb, start, length, kind);
}

/// The core the system runs on, by its own name.
///
/// SYNOPSIS:
/// ```zig
/// fn CpuName(pb: *PlatformBase) [*:0]const u8
/// ```
///
/// SINCE: 1.3. LVO -24.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// A C string of at most CPU_NAME_SIZE bytes, its NUL included. Never
/// null and never empty.
///
/// BEHAVIOR:
/// The name is what the core says of itself where it can be asked: an
/// x86-64 core's brand string with the spaces around it dropped
/// ("AMD Ryzen 7 7840HS w/ Radeon 780M Graphics"), its vendor's string
/// where it has none; an AArch64 core's maker and part ("ARM
/// Cortex-A76"), or the two numbers in hexadecimal for a part not known
/// ("AArch64 41:d4f"); a RISC-V 64 core's own name for one whose ids are
/// known ("SiFive U74"), "RISC-V RV64GC" for any other. An ESP32's core
/// is its chip's: "Xtensa LX7", "RISC-V RV32IMAFC". It is asked once,
/// when the resource is made, and is GetPlatformInfo's `core`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The string is the resource's and stays where it is for as long as the
/// machine runs: read it, keep the pointer, never write to it.
///
/// NOTES:
/// For a person to read. A program that picks its code by what the core
/// can do asks CpuFeature; a name says nothing a program can rely on.
/// PlatformName is the chip or the kind of machine, this the core in it.
///
/// BUGS:
/// The name is the first core's. A machine whose cores are not all alike
/// is named for that one.
///
/// SEE ALSO:
/// `CpuFeature`, `PlatformName`, `GetPlatformInfo`
///
/// EXAMPLES:
/// ```zig
/// _ = Printf(dl, "%s at %d MHz\n", .{ pr.CpuName(), pr.CpuClock() / 1_000_000 });
/// ```
pub fn CpuName(pb: *PlatformBase) [*:0]const u8 {
    return @ptrCast(&pb.cpu_name);
}

fn lvoCpuName(pb: *PlatformBase) callconv(.c) [*:0]const u8 {
    return CpuName(pb);
}

/// Whether a task may use one of the instruction sets a core can bring
/// beyond its chip's base.
///
/// SYNOPSIS:
/// ```zig
/// fn CpuFeature(pb: *PlatformBase, feature: u32) bool
/// ```
///
/// SINCE: 1.3. LVO -28.
///
/// INPUTS:
/// - `feature` - one of CPUF_AES, the AES rounds in both directions;
///   CPUF_CLMUL, the carry-less product of two 64-bit words; CPUF_SHA1;
///   CPUF_SHA256, with SHA-224; CPUF_SHA512, with SHA-384; CPUF_CRC32,
///   the polynomial 0x04C11DB7; CPUF_CRC32C, the polynomial 0x1EDC6F41.
///
/// RESULT:
/// True where the core has the instructions and the system keeps the
/// registers they work in across a task switch: a task may then run them
/// as it runs any other. False where either is missing, and for a number
/// that names no feature.
///
/// BEHAVIOR:
/// The answer is made once, when the resource is made, of what the core
/// says: an x86-64 core's identification leaves 1 and 7, an AArch64
/// core's ID_AA64ISAR0_EL1, a RISC-V core's ISA string in the device
/// tree (Zkne with Zknd, Zbc or Zbkc, Zknh, or Zkn and Zk for all of
/// them). The call itself tests a bit. A feature means the same
/// operation on every chip, in that chip's own instructions; the
/// instructions are the caller's to write.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// Only what is beyond the base is asked: what every program for a chip
/// is built to - SSE4.2's vectors on x86-64, the vector registers on
/// AArch64 - is there without asking. An ESP32's AES and SHA engines are
/// peripherals, not instructions, and crypto.library drives them: every
/// feature is false there. On x86-64 CPUF_SHA512 is false whatever the
/// core has, since those instructions work in registers no task keeps,
/// and CPUF_CRC32 is false because the core's instruction is CRC-32C.
/// Ask once and keep the answer; it never changes.
///
/// BUGS:
/// The answer is the first core's. A machine whose cores are not all
/// alike may say true of a feature a task then meets a core without.
///
/// SEE ALSO:
/// `CpuName`, `GetPlatformInfo`
///
/// EXAMPLES:
/// ```zig
/// const found = sys.OpenResource(platform.PLATFORMNAME) orelse return;
/// const pr: *PlatformBase = @ptrCast(@alignCast(found));
/// const fast = pr.CpuFeature(platform.CPUF_AES) and pr.CpuFeature(platform.CPUF_CLMUL);
/// ```
pub fn CpuFeature(pb: *PlatformBase, feature: u32) bool {
    return identify.has(pb.cpu_features, feature);
}

fn lvoCpuFeature(pb: *PlatformBase, feature: u32) callconv(.c) bool {
    return CpuFeature(pb, feature);
}

/// exec has copied the tag's name, version and ID string into the base.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const pb = platformBase(lib);
    lib.revision = RESOURCE_REVISION;
    pb.sys_base = sys_base;
    identifyCore(pb);
    return lib;
}

const vectors = [_]*const anyopaque{
    vec(lvoGetPlatformInfo),
    vec(lvoPlatformName),
    vec(lvoCpuClock),
    vec(lvoTickRate),
    vec(lvoSetMemoryType),
    vec(lvoCpuName),
    vec(lvoCpuFeature),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(PlatformBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// Before multitasking, as watchdog.resource is: it owns nothing and reads
/// everything late, so there is nothing for it to be too early for, and
/// anything that starts after it can ask what machine it is on.
export const platform_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &platform_resource_tag,
    .flags = exec.RTF_SINGLETASK | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 99,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
