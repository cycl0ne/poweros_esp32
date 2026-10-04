// SPDX-License-Identifier: MPL-2.0
//! motion.library's ROM tag, and the init routine it names: the base set
//! up and timer.device opened for the clock. The clock's task is not made
//! here but the first time something is due (`clock/_clock.zig`), so a
//! system where nothing moves never has it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const motion_lvo = @import("motion_lvo.zig");
const MotionBase = @import("motion_base.zig").MotionBase;

/// The name it is opened by. The SDK's.
pub const LIBRARY_NAME = sdk.motion.MOTIONNAME;
pub const LIBRARY_VERSION = 1;
/// 1: easing (Ease, EaseBezier). 2: animations (CreateAnimationTagList
/// and the calls on one), MixColour and MixRect. 3: timers
/// (CreateTimerTagList and the calls on one). 4: timelines
/// (CreateTimelineTagList and the calls on one).
pub const LIBRARY_REVISION = 4;
const BUILD_DATE = "02.10.2026";
const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn motionBase(lib: *exec.Library) *MotionBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

/// LibInit: the list of what is due made empty, its semaphore set up, and
/// timer.device opened on its microsecond unit for the clock.
///
/// INPUTS:
/// - `lib` - the base exec made from the init table.
/// - `seg_list` - null: a module in the ROM has no segments.
/// - `sys_base` - SysBase, kept in the base.
///
/// RESULT:
/// The base, or null without utility.library. Without timer.device it
/// still starts: the clock then reads
/// the time the host tests set by hand, and no task is ever made.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no; it runs on the exec task at cold start.
/// - Locks: none needed. - Process: a Task will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const mb = motionBase(lib);
    lib.revision = LIBRARY_REVISION;
    const header = mb.lib;
    const utility_base: *sdk.interface.utility.UtilityBase = @ptrCast(sys_base.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null);
    mb.* = .{ .lib = header, .sys_base = sys_base, .utility_base = utility_base };
    sys_base.InitSemaphore(&mb.lock);
    mb.running.init();
    mb.owners.init();
    // The port is the clock task's: no signal until the task allocates
    // one, and nothing is sent before then.
    mb.port.msg_list.init(.message);
    mb.port.flags = exec.PA_IGNORE;
    mb.tick.node.message.reply_port = &mb.port;
    mb.tick.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys_base.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &mb.tick.node, 0) != 0) {
        mb.tick.node.device = null;
    }
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(MotionBase),
    .vectors = &motion_lvo.vectors,
    .vector_count = motion_lvo.vectors.len,
    .init = &init,
};

/// Cold start below timer.device (50), whose clock it reads.
pub export const motion_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &motion_library_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .pri = 40,
    .type = .library,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..],
    .init = &init_table,
};
