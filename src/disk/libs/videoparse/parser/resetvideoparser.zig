// SPDX-License-Identifier: MIT
//! ResetVideoParser: everything the stream held dropped, for a seek.

const sdk = @import("sdk");
const vp = sdk.videoparse;
const VideoParseBase = @import("../videoparse_base.zig").VideoParseBase;
const _parser = @import("_parser.zig");

/// Drops what a parser holds of the stream, for a seek.
///
/// SYNOPSIS:
/// ```zig
/// fn ResetVideoParser(base: *VideoParseBase, parser: *vp.VideoParser) void
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `parser`: what OpenVideoParser made.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The packet being read is let go of, the events not asked for are
/// dropped, and the pictures the stream held - references, pictures
/// waiting to be shown, the one being read - are forgotten without a
/// VPEV_SHOW or VPEV_FREE. The parameter sets stay: the next packet is
/// read as a stream's first - VPEV_SEQUENCE comes again with its first
/// picture - and pictures before its first IDR picture that refer to
/// others are read with the references they lack.
///
/// The slots the caller holds stay its own: it gives each back with
/// `ReleaseVideoSlot` when its own use of it is over. A slot handed out
/// by an event that was dropped is free at once.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// The last packet's bytes are the caller's again.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ParseVideoPacket`, `ReleaseVideoSlot`
///
/// EXAMPLES:
/// ```zig
/// _ = mb.SeekMedia(film, track, time);
/// vpb.ResetVideoParser(parser);
/// ```
pub fn ResetVideoParser(_: *VideoParseBase, parser: *vp.VideoParser) void {
    const p = _parser.of(parser);
    // The slots of pictures the caller never heard of are not its.
    while (p.events.pop()) |event| {
        const hands_out = event.kind == vp.VPEV_MISSING or
            (event.kind == vp.VPEV_PICTURE and !event.picture.?.second_field);
        if (hands_out) _parser.unlend(p, event.slot);
    }
    p.has_packet = false;
    p.unit_ended = false;
    p.stream_ended = false;
    _parser.reset(p);
}
