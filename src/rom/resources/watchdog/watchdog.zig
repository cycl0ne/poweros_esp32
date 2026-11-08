// SPDX-License-Identifier: MPL-2.0
//! watchdog.resource: the machine's watchdog timer for programs - TIMG0's
//! MWDT on the ESPs (mwdt.zig), the chipset's on an x86-64 machine whose
//! chipset is AMD's (x64uefi/fch.zig). It is a resource, as a piece of
//! hardware with one owner at a time is: OpenResource gets its base, there
//! is no Open, Close or open count, and its functions start in the first
//! slot of its jump table (sdk/fd/watchdog_lib.fd).
//!
//! ArmWatchdog(ms, action) starts it: after that many ms without a
//! FeedWatchdog it resets the chip (WATCHDOG_RESET_SYSTEM) or the CPU cores
//! (WATCHDOG_RESET_CPU). Whoever arms it feeds it; DisarmWatchdog stops it.
//! ReadWatchdog gives the armed time.
//!
//! On the ESPs only stage 0 is used. kmain stopped the ROM's watchdogs
//! (wdt.disableAll) long before this comes up, and its init leaves the
//! watchdog disarmed. RTF_SINGLETASK: it is there before multitasking
//! starts.
//!
//! On an x86-64 machine the chipset is a function on PCI, so the resource
//! comes up after pci.library, as a cold-start module, and its init
//! starts nothing: it reads whether the chipset is one whose watchdog this
//! drives, and whether the last restart was the watchdog's, and clears
//! the bit that said so. The chipset's watchdog
//! counts whole seconds and only resets the whole machine. A machine
//! without one has the resource all the same, and ArmWatchdog refuses.
//!
//! It builds against the SDK.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const mwdt = @import("mwdt.zig");
const fch = @import("x64uefi/fch.zig");
const vec = exec.vec;
const types = sdk.resources.watchdog;

pub const RESOURCE_NAME = types.WATCHDOGNAME;
const RESOURCE_VERSION = 1;
const RESOURCE_REVISION = 1;
const BUILD_DATE = "07.11.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// Its functions, as the SDK has them (sdk/fd/watchdog_lib.fd).
pub const interface = sdk.interface.watchdog;
pub const LVO = interface.LVO;

/// Whether the watchdog is the chipset's (an x86-64 machine) rather than
/// the chip's own timer group's.
const on_chipset = switch (sdk.hardware.chip) {
    .esp32s3, .esp32p4 => false,
    .x64uefi => true,
    .rv64sbi, .a64psci => @compileError("watchdog.resource: no watchdog this drives on this chip"),
};

// Every function in LVO is an lvo* function here, with the SDK's signature
// (after the base), in its slot.
comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("watchdog.resource's lvo" ++ d.name ++ " doesn't match the SDK's Fn." ++ d.name);
        }
        if (vectors[@divExact(-@field(LVO, d.name), exec.slot_size) - 1] != vec(f)) {
            @compileError("watchdog.resource's lvo" ++ d.name ++ " isn't in the slot of LVO." ++ d.name);
        }
    }
}

/// The base.
const WatchdogBase = extern struct {
    lib: exec.Library,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// The armed time in ms, 0 while disarmed.
    armed_ms: u32,
    /// The chipset watchdog's registers, 0 where there is none: always on
    /// the ESPs.
    registers: usize,
};

fn watchdogBase(lib: *exec.Library) *WatchdogBase {
    return @fieldParentPtr("lib", lib);
}

/// The longest time: stage 0's 32-bit count of 0.5 ms ticks.
const max_ms = std.math.maxInt(u32) / mwdt.ticks_per_ms;

fn lvoArmWatchdog(wb: *WatchdogBase, millis: u32, action: u32) callconv(.c) bool {
    if (on_chipset) {
        if (action != types.WATCHDOG_RESET_SYSTEM or millis == 0 or millis > fch.max_ms) return false;
        wb.sys_base.Disable();
        defer wb.sys_base.Enable();
        if (!fch.arm(wb.registers, millis)) return false;
        wb.armed_ms = millis;
        return true;
    }
    const stage_action: mwdt.Action = switch (action) {
        types.WATCHDOG_RESET_SYSTEM => .reset_system,
        types.WATCHDOG_RESET_CPU => .reset_cpu,
        else => return false,
    };
    if (millis == 0 or millis > max_ms) return false;
    wb.sys_base.Disable();
    defer wb.sys_base.Enable();
    mwdt.arm(millis * mwdt.ticks_per_ms, stage_action);
    wb.armed_ms = millis;
    return true;
}

fn lvoFeedWatchdog(wb: *WatchdogBase) callconv(.c) void {
    if (on_chipset) fch.feed(wb.registers) else mwdt.feed();
}

fn lvoDisarmWatchdog(wb: *WatchdogBase) callconv(.c) void {
    wb.sys_base.Disable();
    defer wb.sys_base.Enable();
    if (on_chipset) fch.disarm(wb.registers) else mwdt.disarm();
    wb.armed_ms = 0;
}

fn lvoReadWatchdog(wb: *WatchdogBase) callconv(.c) u32 {
    return wb.armed_ms;
}

/// exec has copied the tag's name, version and ID string into the base.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const wb = watchdogBase(lib);
    lib.revision = RESOURCE_REVISION;
    wb.sys_base = sys_base;
    wb.armed_ms = 0;
    wb.registers = if (on_chipset) fch.find(sys_base) else 0;
    return lib;
}

const vectors = [_]*const anyopaque{
    vec(lvoArmWatchdog),
    vec(lvoFeedWatchdog),
    vec(lvoDisarmWatchdog),
    vec(lvoReadWatchdog),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(WatchdogBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

export const watchdog_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &watchdog_resource_tag,
    // The chipset's watchdog is found through pci.library, a cold-start
    // module at 49.
    .flags = if (on_chipset) exec.RTF_COLDSTART | exec.RTF_AUTOINIT else exec.RTF_SINGLETASK | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = if (on_chipset) 44 else 100,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
