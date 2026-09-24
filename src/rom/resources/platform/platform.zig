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
//! It owns no hardware and sets nothing up, so it only reads: every answer
//! is taken when it is asked for, not at init. That matters, because the
//! tag is RTF_SINGLETASK and runs before `timer.init` has measured
//! anything.
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
const cpu = @import("../../../arch/esp32s3/cpu.zig");
const clock = @import("../../../arch/esp32s3/clock.zig");
const timer = @import("../../../arch/esp32s3/timer.zig");
const psram = @import("../../../arch/esp32s3/psram.zig");
const layout = @import("../../../arch/esp32s3/layout.zig");
const vec = exec.vec;
const types = sdk.resources.platform;
const PlatformInfo = types.PlatformInfo;

pub const RESOURCE_NAME = types.PLATFORMNAME;
const RESOURCE_VERSION = 1;
const RESOURCE_REVISION = 1;
const BUILD_DATE = "22.9.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The board's chip and its core, by name. Constants: every board has the
/// same chip.
const CHIP_NAME = "ESP32-S3";
const CORE_NAME = "Xtensa LX7";
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

/// The base. It keeps nothing but SysBase: every answer is read from the
/// hardware and the kernel's own variables when it is asked for.
const PlatformBase = extern struct {
    lib: exec.Library,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
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

fn lvoGetPlatformInfo(_: *PlatformBase, info: *PlatformInfo, size: u32) callconv(.c) u32 {
    const whole: PlatformInfo = .{
        .chip = CHIP_NAME,
        .core = CORE_NAME,
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

/// exec has copied the tag's name, version and ID string into the base.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const pb = platformBase(lib);
    lib.revision = RESOURCE_REVISION;
    pb.sys_base = sys_base;
    return lib;
}

const vectors = [_]*const anyopaque{
    vec(lvoGetPlatformInfo),
    vec(lvoPlatformName),
    vec(lvoCpuClock),
    vec(lvoTickRate),
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
