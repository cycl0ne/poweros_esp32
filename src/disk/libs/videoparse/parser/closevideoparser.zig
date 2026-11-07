// SPDX-License-Identifier: MIT
//! CloseVideoParser: a parser given back.

const sdk = @import("sdk");
const vp = sdk.videoparse;
const VideoParseBase = @import("../videoparse_base.zig").VideoParseBase;
const _parser = @import("_parser.zig");
const h264 = @import("../h264/_h264.zig");
const hevc = @import("../hevc/_hevc.zig");
const vp9 = @import("../vp9/_vp9.zig");
const av1 = @import("../av1/_av1.zig");

/// Closes a parser.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseVideoParser(base: *VideoParseBase, parser: ?*vp.VideoParser) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `parser`: what OpenVideoParser made, or null.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Its parameter sets, its pictures' bookkeeping and its buffers are
/// freed, whatever it was doing: events not asked for are dropped, and
/// the slots are gone with it, those the caller has not given back too.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// The parser is gone after the call, and everything its events pointed
/// at. The packet's bytes are still the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenVideoParser`
///
/// EXAMPLES:
/// ```zig
/// vpb.CloseVideoParser(parser);
/// ```
pub fn CloseVideoParser(base: *VideoParseBase, parser: ?*vp.VideoParser) void {
    const handle = parser orelse return;
    const p = _parser.of(handle);
    if (p.h264) |st| h264.destroy(p, st);
    if (p.hevc) |st| hevc.destroy(p, st);
    if (p.vp9) |st| vp9.destroy(p, st);
    if (p.av1) |st| av1.destroy(p, st);
    base.sys_base.FreeVec(@ptrCast(p));
}
