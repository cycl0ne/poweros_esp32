// SPDX-License-Identifier: MIT
//! AslRequest: a requester put up, and answered or given up - on the
//! caller's process, or on one of its own with the answer sent as a
//! message.

const sdk = @import("sdk");
const dos = sdk.dos;
const asl = sdk.asl;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const asl_base = @import("../asl_base.zig");
const AslBase = asl_base.AslBase;
const _request = @import("_request.zig");
const Requester = _request.Requester;
const file = @import("../file/ask.zig");
const font = @import("../font/ask.zig");
const device = @import("../device/ask.zig");

/// A requester put up, and answered or given up.
///
/// SYNOPSIS:
/// ```zig
/// fn AslRequest(ab: *AslBase, requester: *anyopaque, tags: ?[*]const TagItem) bool
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `ab` - asl.library's base.
/// - `requester` - what `AllocAslRequest` made.
/// - `tags` - what to change about it for this showing; null to put it up
///   as it stands. They are the tags `AllocAslRequest` takes, and what
///   they set stays set for the requests after this one.
///
/// RESULT:
/// True when the requester was answered, false when it was given up -
/// the Cancel button, the close gadget, Ctrl-C - or could not be shown.
/// With `ASLFR_ReplyPort`: true when it is up, false when it could not be
/// started or is up already.
///
/// BEHAVIOR:
/// The requester opens on the screen of `ASLFR_Window`, or on
/// `ASLFR_Screen`, or on the public screen `ASLFR_PubScreenName` names,
/// or on the default public screen; with `ASLFR_SleepWindow` the parent
/// window shows the busy pointer and takes no input while it is up. It
/// opens where it was left the time before, at the size it was left, so
/// a program that asks twice asks in the same place.
///
/// The call runs the requester on the caller's process and returns when
/// the user has answered: it does not come back to the program in
/// between, which is why a program with a window of its own hands one in
/// (`ASLFR_Window`) rather than leaving it to look stopped.
///
/// **Given a port** (`ASLFR_ReplyPort`) it runs the requester on a
/// process of its own, which holds the library open while it runs, and
/// returns at once. When the requester is answered or given up, its
/// message (`asl.AslMessage`) goes to the port, saying which requester and
/// whether it was answered; the program takes it with GetMsg and does not
/// reply it. The process starts in the caller's current drawer, so a
/// drawer named relative to it is found. `AbortAslRequest` takes it down
/// before it is answered.
///
/// A drawer is read while the requester is up rather than before it
/// shows, so a drawer of some thousands of entries can be answered as
/// soon as the wanted one is there. A device requester lists the units
/// expansion.library's ObtainDeviceUnits answers for its command set,
/// one line each - the device, the unit, and what the board calls it -
/// and nothing is opened or loaded to find them.
///
/// What it was answered with is in the request structure and holds until
/// the next call on that requester or until `FreeAslRequest`.
///
/// CONTEXT:
/// - Waits: for input, for the screen, and for the drawer to be read;
///   with a port, only for the process to be started.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Process, not a bare Task: it opens a window and reads a
///   drawer, or starts the process that does.
///
/// OWNERSHIP:
/// Everything the requester makes is its own and goes at the next request
/// or at `FreeAslRequest`. The locks of a multi-select answer are the
/// library's: they are not to be unlocked by the program. A requester up
/// on its own process is the library's until its message has arrived:
/// the program reads nothing in it, asks nothing of it and does not free
/// it, and the port, the window and the screen it was given stay until
/// then.
///
/// NOTES:
/// The screen mode requester is not built yet and answers false.
///
/// SEE ALSO:
/// `AllocAslRequest`, `FreeAslRequest`, `AbortAslRequest`
///
/// EXAMPLES:
/// ```zig
/// if (ab.AslRequest(req, &.{
///     .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr("Save as") },
///     .{ .tag = asl.ASLFR_DoSaveMode, .data = 1 },
///     .{},
/// })) save(req.drawer, req.file);
///
/// // Asked without waiting; the answer comes on `port`.
/// _ = ab.AslRequest(req, &.{
///     .{ .tag = asl.ASLFR_Window, .data = @intFromPtr(window) },
///     .{ .tag = asl.ASLFR_ReplyPort, .data = @intFromPtr(port) },
///     .{},
/// });
/// ```
pub fn AslRequest(ab: *AslBase, requester: *anyopaque, tags: ?[*]const TagItem) bool {
    const r = _request.requesterOf(requester);
    const sys = ab.sys_base;
    // Up on its own process already: not touched until it ends.
    sys.ObtainSemaphore(&r.asker_lock);
    const busy = r.asker != null;
    sys.ReleaseSemaphore(&r.asker_lock);
    if (busy) return false;
    _request.takeTags(r, tags);
    _request.dropArgs(r);
    if (r.reply_port == null) return askNow(ab, r);
    return startAsker(ab, r);
}

/// The requester run here, on the process calling.
fn askNow(ab: *AslBase, r: *Requester) bool {
    return switch (r.kind) {
        asl.ASL_FileRequest => file.ask(ab, r),
        asl.ASL_FontRequest => font.ask(ab, r),
        asl.ASL_DeviceRequest => device.ask(ab, r),
        else => false,
    };
}

/// The process the requester is run on started, holding the library open
/// and named as the requester's asker before anything can ask for it.
/// The semaphore is held across the start, so a process that ends at
/// once lets its name go only after it was given.
fn startAsker(ab: *AslBase, r: *Requester) bool {
    const sys = ab.sys_base;
    r.message = .{
        .message = .{ .length = @sizeOf(asl.AslMessage) },
        .requester = @ptrCast(r),
    };
    sys.ObtainSemaphore(&r.asker_lock);
    defer sys.ReleaseSemaphore(&r.asker_lock);
    asl_base.holdLibrary(ab, 1);
    const process = ab.dos_base.CreateNewProc(&[_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&askerMain) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr("asl requester") },
        .{ .tag = dos.NP_StackSize, .data = 16384 },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(r) },
        .{ .tag = dos.NP_HoldLibrary, .data = @intFromPtr(&ab.lib) },
        .{},
    }) orelse {
        asl_base.holdLibrary(ab, -1);
        return false;
    };
    r.asker = &process.task;
    return true;
}

/// The requester's own process: it asks, lets its name go, and sends the
/// message - the last it does with the requester, which may be freed the
/// moment the message is taken.
fn askerMain(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const r: *Requester = @ptrCast(@alignCast(me.user_data orelse return));
    const answered = askNow(r.base, r);
    const port = r.reply_port.?;
    sys.ObtainSemaphore(&r.asker_lock);
    r.asker = null;
    r.message.answered = @intFromBool(answered);
    sys.ReleaseSemaphore(&r.asker_lock);
    sys.PutMsg(port, &r.message.message);
}
