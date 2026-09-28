// SPDX-License-Identifier: MIT
//! AslRequest: a requester put up, and answered or given up.

const sdk = @import("sdk");
const asl = sdk.asl;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const AslBase = @import("../asl_base.zig").AslBase;
const _request = @import("_request.zig");
const file = @import("../file/ask.zig");

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
/// A drawer is read while the requester is up rather than before it
/// shows, so a drawer of some thousands of entries can be answered as
/// soon as the wanted one is there.
///
/// What it was answered with is in the request structure and holds until
/// the next call on that requester or until `FreeAslRequest`.
///
/// CONTEXT:
/// - Waits: for input, for the screen, and for the drawer to be read.
/// - Interrupts: no.
/// - Forbid: not held and not to be held.
/// - Process: a Process, not a bare Task: it opens a window and reads a
///   drawer.
///
/// OWNERSHIP:
/// Everything the requester makes is its own and goes at the next request
/// or at `FreeAslRequest`. The locks of a multi-select answer are the
/// library's: they are not to be unlocked by the program.
///
/// NOTES:
/// The font and the screen mode requesters answer false for now: only the
/// file requester is built (`todo/asl` 6 and 7).
///
/// SEE ALSO:
/// `AllocAslRequest`, `FreeAslRequest`
///
/// EXAMPLES:
/// ```zig
/// if (ab.AslRequest(req, &.{
///     .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr("Save as") },
///     .{ .tag = asl.ASLFR_DoSaveMode, .data = 1 },
///     .{},
/// })) save(req.drawer, req.file);
/// ```
pub fn AslRequest(ab: *AslBase, requester: *anyopaque, tags: ?[*]const TagItem) bool {
    const r = _request.requesterOf(requester);
    _request.takeTags(r, tags);
    _request.dropArgs(r);
    return switch (r.kind) {
        asl.ASL_FileRequest => file.ask(ab, r),
        else => false,
    };
}
