// SPDX-License-Identifier: MIT
//! ReleaseVideoSlot: a slot the caller is done with given back.

const sdk = @import("sdk");
const vp = sdk.videoparse;
const VideoParseBase = @import("../videoparse_base.zig").VideoParseBase;
const _parser = @import("_parser.zig");

/// Gives a slot back to the parser once the caller is done with it.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseVideoSlot(base: *VideoParseBase, parser: *vp.VideoParser, slot: u32) void
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `parser`: what OpenVideoParser made.
/// - `slot`: a slot VPEV_PICTURE or VPEV_MISSING handed out.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A slot is the caller's from the event that handed it out until it
/// gives it back, and the stream's until it said VPEV_FREE of it; it is
/// handed out again only when it is neither. The caller gives each slot
/// back once, when the stream let go of it and its own use of it is
/// over: at once for a decoder that is done with a picture when the
/// stream is, later for one whose cores still read the picture or that
/// has lent it out. A slot given back before VPEV_FREE is free once the
/// stream lets go of it.
///
/// After `ResetVideoParser` no VPEV_FREE comes for the slots the caller
/// holds: it gives each back when its own use of it is over.
///
/// A slot past the last one is passed over.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a task will do; not while another task calls the parser.
///
/// OWNERSHIP:
/// What the caller keeps by the slot - samples, a chip's surface - is
/// still its own; the slot's next picture is a new one.
///
/// NOTES:
/// A picture waiting for a slot (VPERR_FULL) takes the slot given back
/// when `NextVideoEvent` is called next.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NextVideoEvent`
///
/// EXAMPLES:
/// ```zig
/// if (event.kind == vp.VPEV_FREE) vpb.ReleaseVideoSlot(parser, event.slot);
/// ```
pub fn ReleaseVideoSlot(_: *VideoParseBase, parser: *vp.VideoParser, slot: u32) void {
    _parser.unlend(_parser.of(parser), slot);
}
