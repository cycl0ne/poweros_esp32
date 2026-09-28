// SPDX-License-Identifier: MIT
//! AllocAslRequest: a requester made and set up from its tags.

const sdk = @import("sdk");
const exec = sdk.exec;
const asl = sdk.asl;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const AslBase = @import("../asl_base.zig").AslBase;
const _request = @import("_request.zig");
const Requester = _request.Requester;

/// A requester of `kind`, set up from `tags`.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocAslRequest(ab: *AslBase, kind: u32, tags: ?[*]const TagItem) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `ab` - asl.library's base.
/// - `kind` - `ASL_FileRequest`, `ASL_FontRequest` or
///   `ASL_ScreenModeRequest`.
/// - `tags` - what the requester starts as; null for none. `AslRequest`
///   reads the same tags and may change any of them for one showing.
///
/// RESULT:
/// The requester, which is the request structure of that kind, or null
/// for a kind it does not know or no memory.
///
/// BEHAVIOR:
/// The structure is the library's: the program reads it and never writes
/// it or frees it. It holds what the requester was answered with until
/// the next `AslRequest` on it or until `FreeAslRequest`, so a requester
/// asked twice opens where it was left - same place, same size, same
/// drawer, file and pattern.
///
/// A file requester starts with its three fields empty unless
/// `ASLFR_InitialFile`, `ASLFR_InitialDrawer` or `ASLFR_InitialPattern`
/// says otherwise, and with no place of its own, so the first showing is
/// put in the middle of the screen it opens on.
///
/// CONTEXT:
/// - Waits: for memory.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The requester is the caller's to free with `FreeAslRequest`. Every
/// pointer the tags give - the title, the patterns, the hooks - stays the
/// caller's and must outlive the requester; the three text fields are
/// copied into the requester's own buffers.
///
/// NOTES:
/// The tags of the three kinds share their numbers where they mean the
/// same thing, and have their own meanings where they do not, so the kind
/// is what decides how a number is read.
///
/// SEE ALSO:
/// `AslRequest`, `FreeAslRequest`
///
/// EXAMPLES:
/// ```zig
/// const req: *asl.FileRequester = @ptrCast(@alignCast(ab.AllocAslRequest(asl.ASL_FileRequest, &.{
///     .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr("Open") },
///     .{ .tag = asl.ASLFR_InitialDrawer, .data = @intFromPtr("SYS:") },
///     .{},
/// }) orelse return));
/// defer ab.FreeAslRequest(req);
/// ```
pub fn AllocAslRequest(ab: *AslBase, kind: u32, tags: ?[*]const TagItem) ?*anyopaque {
    if (kind > asl.ASL_ScreenModeRequest) return null;
    const sys = ab.sys_base;
    const block = sys.AllocVec(@sizeOf(Requester), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const r: *Requester = @ptrCast(@alignCast(block));
    r.* = .{ .public = .{ .file = .{} }, .base = ab, .kind = kind };
    _request.takeTags(r, tags);
    sys.Forbid();
    sys.AddTail(@ptrCast(&ab.requesters), @ptrCast(&r.node));
    sys.Permit();
    return @ptrCast(r);
}
