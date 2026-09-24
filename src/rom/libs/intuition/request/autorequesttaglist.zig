// SPDX-License-Identifier: MPL-2.0
//! AutoRequestTagList: asks with two buttons made from IntuiTexts and
//! waits.

const sdk = @import("sdk");
const utility = sdk.utility;
const intuition = sdk.intuition;
const rq = intuition.requesters;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const Window = @import("../window/_window.zig").Window;

/// Asks with two buttons made from IntuiTexts and waits.
///
/// SYNOPSIS:
/// ```zig
/// fn AutoRequestTagList(ib: *IntuitionBase, window: ?*Window, tags: ?[*]const TagItem) bool
/// ```
///
/// SINCE: 0.13. LVO -320.
///
/// INPUTS:
/// - `window` - the reference window, as for `BuildSysRequestTagList`, or
///   null.
/// - `tags` - `SYSREQ_Body`, `SYSREQ_Positive` and `SYSREQ_Negative`, what
///   it says and its two buttons, as for `BuildSysRequestTagList`;
///   `SYSREQ_PositiveFlags`, IDCMP classes that answer it as the left
///   button, and `SYSREQ_NegativeFlags`, as the right one.
///
/// RESULT:
/// True for the left button or a class of `SYSREQ_PositiveFlags`; false
/// for the right button, a class of `SYSREQ_NegativeFlags`, or when the
/// requester could not be made.
///
/// BEHAVIOR:
/// `BuildSysRequestTagList` with both sets of classes as its
/// `SYSREQ_IDCMPFlags`, `SysReqHandler` until it is answered, and
/// `FreeSysRequest`. The left Amiga key with V answers as the left button
/// and with B as the right one.
///
/// CONTEXT:
/// - Waits: for the answer, and for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: must not be held: it waits.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The texts and the tags stay the caller's.
///
/// NOTES:
/// `EasyRequestArgs` asks the same with formats and any number of buttons.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BuildSysRequestTagList`, `EasyRequestArgs`, `SysReqHandler`
///
/// EXAMPLES:
/// ```zig
/// const save = ib.AutoRequestTagList(window, &[_]TagItem{
///     .{ .tag = SYSREQ_Body, .data = @intFromPtr(&body) },
///     .{ .tag = SYSREQ_Positive, .data = @intFromPtr(&yes) },
///     .{ .tag = SYSREQ_Negative, .data = @intFromPtr(&no) },
///     .{},
/// });
/// ```
pub fn AutoRequestTagList(ib: *IntuitionBase, window: ?*Window, tags: ?[*]const TagItem) bool {
    const it = ib.iface();
    const ub = ib.utility_base;
    const positive_flags: u32 = @truncate(ub.GetTagData(rq.SYSREQ_PositiveFlags, 0, tags));
    const negative_flags: u32 = @truncate(ub.GetTagData(rq.SYSREQ_NegativeFlags, 0, tags));
    const build = [_]TagItem{
        .{ .tag = rq.SYSREQ_Body, .data = ub.GetTagData(rq.SYSREQ_Body, 0, tags) },
        .{ .tag = rq.SYSREQ_Positive, .data = ub.GetTagData(rq.SYSREQ_Positive, 0, tags) },
        .{ .tag = rq.SYSREQ_Negative, .data = ub.GetTagData(rq.SYSREQ_Negative, 0, tags) },
        .{ .tag = rq.SYSREQ_IDCMPFlags, .data = positive_flags | negative_flags },
        .{},
    };
    const req = it.BuildSysRequestTagList(@ptrCast(window), &build) orelse return false;
    defer it.FreeSysRequest(req);
    var class: u32 = 0;
    while (true) {
        const answer = it.SysReqHandler(req, &class, true);
        if (answer == rq.SYSREQ_PENDING) continue;
        if (answer == rq.SYSREQ_IDCMP) return class & positive_flags != 0;
        return answer != 0;
    }
}
