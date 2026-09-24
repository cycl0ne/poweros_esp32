// SPDX-License-Identifier: MPL-2.0
//! watchdog.resource: the chip's watchdog timer (TIMG0's MWDT, mwdt.zig)
//! for programs. It is a resource, as a piece of hardware with one owner
//! at a time is: OpenResource gets its base, there is
//! no Open, Close or open count, and its functions start in the first slot
//! of its jump table (sdk/fd/watchdog_lib.fd).
//!
//! ArmWatchdog(ms, action) starts it: after that many ms without a
//! FeedWatchdog it resets the chip (WATCHDOG_RESET_SYSTEM) or the CPU cores
//! (WATCHDOG_RESET_CPU). Whoever arms it feeds it; DisarmWatchdog stops it.
//! Only stage 0 is used. The chip has no readable count, so ReadWatchdog
//! gives the armed time.
//!
//! kmain stopped the ROM's watchdogs (wdt.disableAll) long before this
//! comes up, and its init leaves the watchdog disarmed. RTF_SINGLETASK:
//! it is there before multitasking starts. It builds against the SDK.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const mwdt = @import("mwdt.zig");
const vec = exec.vec;
const types = sdk.resources.watchdog;

pub const RESOURCE_NAME = types.WATCHDOGNAME;
const RESOURCE_VERSION = 1;
const RESOURCE_REVISION = 0;
const BUILD_DATE = "15.9.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// Its functions, as the SDK has them (sdk/fd/watchdog_lib.fd).
pub const interface = sdk.interface.watchdog;
pub const LVO = interface.LVO;

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
};

fn watchdogBase(lib: *exec.Library) *WatchdogBase {
    return @fieldParentPtr("lib", lib);
}

/// The longest time: stage 0's 32-bit count of 0.5 ms ticks.
const max_ms = std.math.maxInt(u32) / mwdt.ticks_per_ms;

fn lvoArmWatchdog(wb: *WatchdogBase, millis: u32, action: u32) callconv(.c) bool {
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

fn lvoFeedWatchdog(_: *WatchdogBase) callconv(.c) void {
    mwdt.feed();
}

fn lvoDisarmWatchdog(wb: *WatchdogBase) callconv(.c) void {
    wb.sys_base.Disable();
    defer wb.sys_base.Enable();
    mwdt.disarm();
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
    .flags = exec.RTF_SINGLETASK | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 100,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
