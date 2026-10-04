// SPDX-License-Identifier: MPL-2.0
//! BuildSysRequestTagList: a two-button requester from IntuiTexts - tag
//! lists of `IT_` tags - handed back.

const sdk = @import("sdk");
const exec = sdk.exec;
const intuition = sdk.intuition;
const EasyStruct = intuition.EasyStruct;
const rq = intuition.requesters;
const TagItem = sdk.utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const Window = @import("../window/_window.zig").Window;
const runOf = @import("../render/_render.zig").runOf;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// A two-button requester from IntuiTexts, handed back.
///
/// SYNOPSIS:
/// ```zig
/// fn BuildSysRequestTagList(ib: *IntuitionBase, window: ?*Window, tags: ?[*]const TagItem) ?*Window
/// ```
///
/// SINCE: 0.13. LVO -324.
///
/// INPUTS:
/// - `window` - the reference window: the requester opens on its screen,
///   with its title. Null for the default public screen.
/// - `tags` - `SYSREQ_Body`, what it says, an IntuiText whose every run is
///   a line; `SYSREQ_Positive`, the left button's text - yes, retry, go
///   on - or none; `SYSREQ_Negative`, the right button's text - no,
///   cancel;
///   `SYSREQ_IDCMPFlags`, IDCMP classes of the caller's own that answer it too.
///   The body and the right button are required.
///
/// RESULT:
/// The requester's window, to be answered with `SysReqHandler` - 1 for the
/// left button, 0 for the right, -1 for a class of `SYSREQ_IDCMPFlags` - and
/// closed with `FreeSysRequest`. Null when it could not be made, or the
/// body or the right button is missing.
///
/// BEHAVIOR:
/// The same requester `BuildEasyRequestArgs` makes: a frame with the lines
/// in it and the buttons under them, the left Amiga key with V and B
/// answering for the left and the right one. The runs' `IT_Text` is taken
/// as it is - no format is read in it - and their pens, fonts, styles and
/// places give way to the requester's own look.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore and the layers' locks.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The texts stay the caller's; the requester copies their words. The
/// window is the caller's until `FreeSysRequest`.
///
/// NOTES:
/// A `|` in a button's text divides it into two buttons, as a
/// `gadget_format` would.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AutoRequestTagList`, `BuildEasyRequestArgs`, `SysReqHandler`,
/// `FreeSysRequest`
///
/// EXAMPLES:
/// ```zig
/// const second = intuition.text.plainRun("is not answering.", null);
/// const body = [_]TagItem{
///     .{ .tag = intuition.IT_Text, .data = @intFromPtr("The printer") },
///     .{ .tag = intuition.IT_Next, .data = @intFromPtr(&second) },
///     .{},
/// };
/// const retry = intuition.text.plainRun("Retry", null);
/// const cancel = intuition.text.plainRun("Cancel", null);
/// const req = ib.BuildSysRequestTagList(null, &[_]TagItem{
///     .{ .tag = SYSREQ_Body, .data = @intFromPtr(&body) },
///     .{ .tag = SYSREQ_Positive, .data = @intFromPtr(&retry) },
///     .{ .tag = SYSREQ_Negative, .data = @intFromPtr(&cancel) },
///     .{},
/// }) orelse return;
/// defer ib.FreeSysRequest(req);
/// ```
pub fn BuildSysRequestTagList(ib: *IntuitionBase, window: ?*Window, tags: ?[*]const TagItem) ?*Window {
    const sys = ib.sys_base;
    const ub = ib.utility_base;
    const body = textTag(ub, rq.SYSREQ_Body, tags) orelse return null;
    const positive = textTag(ub, rq.SYSREQ_Positive, tags);
    const negative = textTag(ub, rq.SYSREQ_Negative, tags) orelse return null;
    const idcmp: u32 = @truncate(ub.GetTagData(rq.SYSREQ_IDCMPFlags, 0, tags));

    // The lines, a run each, and the buttons, left to right, as one text
    // each - the words as they are, handed through "%s" so none of them is
    // read as a format.
    var body_length: usize = 0;
    var run: ?[*]const TagItem = body;
    while (run) |r| : (run = runOf(ub, r).next) body_length += textLength(ub, r) + 1;
    const labels_length = textLength(ub, negative) + 1 + if (positive) |p| textLength(ub, p) + 1 else 0;
    const memory = sys.AllocVec(body_length + 1 + labels_length, exec.MEMF_CLEAR) orelse return null;
    defer sys.FreeVec(memory);
    const text: [*]u8 = @ptrCast(memory);

    var at: usize = 0;
    run = body;
    while (run) |r| : (run = runOf(ub, r).next) {
        if (at != 0) {
            text[at] = '\n';
            at += 1;
        }
        at = copy(ub, text, at, r);
    }
    text[at] = 0;
    at += 1;
    const labels = text + at;
    var label_at: usize = 0;
    if (positive) |p| {
        label_at = copy(ub, labels, label_at, p);
        labels[label_at] = '|';
        label_at += 1;
    }
    label_at = copy(ub, labels, label_at, negative);
    labels[label_at] = 0;

    const easy = EasyStruct{ .text_format = "%s", .gadget_format = "%s" };
    const stream = exec.fmtStream(.{ @as([*:0]const u8, @ptrCast(text)), @as([*:0]const u8, @ptrCast(labels)) });
    const made = ib.iface().BuildEasyRequestArgs(@ptrCast(window), &easy, idcmp, &stream) orelse return null;
    return @ptrCast(@alignCast(made));
}

fn textTag(ub: *UtilityBase, tag: sdk.utility.Tag, tags: ?[*]const TagItem) ?[*]const TagItem {
    return @ptrFromInt(ub.GetTagData(tag, 0, tags));
}

fn textLength(ub: *UtilityBase, run: [*]const TagItem) usize {
    const words = runOf(ub, run).text orelse return 0;
    return ub.Strlen(words);
}

/// A run's words into `out` at `at`; where they end.
fn copy(ub: *UtilityBase, out: [*]u8, at: usize, run: [*]const TagItem) usize {
    const words = runOf(ub, run).text orelse return at;
    const n = ub.Strlen(words);
    for (0..n) |i| out[at + i] = words[i];
    return at + n;
}
