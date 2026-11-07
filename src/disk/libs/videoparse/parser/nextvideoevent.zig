// SPDX-License-Identifier: MIT
//! NextVideoEvent: the stream read on to its next event.
//!
//! Each call hands out what the queue holds first; with nothing on it,
//! the packet's next unit is read, and what that comes to goes onto the
//! queue. A unit that needs a slot none is free for is not gone past: it
//! is read again on the next call, the events before its stop handed out
//! first. At the packet's end its access unit is ended (VPPKT_ACCESS_UNIT)
//! and the stream (VPPKT_END), each once.

const sdk = @import("sdk");
const vp = sdk.videoparse;
const VideoParseBase = @import("../videoparse_base.zig").VideoParseBase;
const _parser = @import("_parser.zig");

/// Reads the stream on to its next event.
///
/// SYNOPSIS:
/// ```zig
/// fn NextVideoEvent(base: *VideoParseBase, parser: *vp.VideoParser, event: *vp.VideoEvent) i32
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `parser`: what OpenVideoParser made.
/// - `event`: where the event goes.
///
/// RESULT:
/// - VPERR_OK: `event` holds the next event.
/// - VPERR_NEED_DATA: the packet is read through; the next is to be
///   handed over with `ParseVideoPacket`.
/// - VPERR_END: after VPPKT_END, every event said.
/// - VPERR_FULL: a picture needs a slot and none is free; one is to be
///   given back with `ReleaseVideoSlot` before the next call.
/// - VPERR_CORRUPT: a unit that is not right was passed over - or the
///   rest of the packet, where a unit's length went past its end.
/// - VPERR_UNSUPPORTED: a unit the library does not read was passed over
///   (a picture larger than VPA_MaxWidth or VPA_MaxHeight).
/// - VPERR_NOMEMORY: a unit was passed over for want of memory.
///
/// After an error the next call goes on with the next unit.
///
/// BEHAVIOR:
/// The events of a picture come in this order: VPEV_SEQUENCE when it
/// begins a sequence that is new or says something else than the last
/// one did (the pictures of the last one shown first where its pictures'
/// size or kind changes); VPEV_MISSING for each frame a gap in H.264's
/// frame numbers skipped; VPEV_PICTURE; a VPEV_SLICE for each slice;
/// VPEV_DECODE once its slices are all given - when the next picture
/// begins, its access unit or the stream ends. After VPEV_DECODE come the
/// pictures the marking and the buffer let go of: VPEV_SHOW for each
/// picture due, in the order shown, VPEV_FREE for each slot the stream
/// needs no more.
///
/// VPEV_SEQUENCE's `sequence` is what the active sequence parameter set
/// says. VPEV_PICTURE's `picture` holds the picture's slot - the second
/// field of a pair in its first field's - its order counts, its parameter
/// sets and the reference pictures the stream holds before the picture is
/// marked, the first field of its own frame among them. VPEV_SLICE's
/// `slice` holds the unit as it came, its payload unescaped and the bit
/// its data starts at, the parsed header and its two lists, each entry
/// with its picture's slot, number and order counts. VPEV_MISSING's
/// `picture` holds the missing frame's slot, number and order counts: the
/// caller fills it - with grey, or a copy of the last reference - and it
/// is referred to as if it were there; it is never shown. VPEV_SHOW's
/// `slot` and `time` say which picture is due and when, VPEV_FREE's
/// `slot` which the stream let go of.
///
/// A slice whose parameter sets were never given, a picture that names
/// another picture parameter set than its first slice did, a redundant
/// picture's slices are passed over.
///
/// Of a VP9 stream (SINCE 1.1) each frame is VPEV_SEQUENCE before the
/// first and before one of another size, depth or colour; VPEV_PICTURE,
/// its `picture` holding the frame's header (`vp9`) and as `refs` the
/// pictures in the eight reference slots, in their order, VP_NO_SLOT
/// where one is empty; one VPEV_SLICE, the frame's bytes whole, its
/// compressed header at `data_bit`; VPEV_DECODE; VPEV_SHOW when it is
/// shown; then VPEV_FREE for each picture no reference slot holds any
/// more, the frame's own where it went into none. A frame that only shows
/// a reference is a VPEV_SHOW of that reference's slot, alone. A frame
/// that is not a key frame or an intra-only one is passed over
/// (VPERR_CORRUPT) at the start, after a reset and after a frame that was
/// not right, and so is one whose references are empty or of another
/// depth or sampling.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// What an event points at - the sequence, the picture, the slice, the
/// parameter sets and the header, and the slice's units and payload - is
/// the parser's, and good until the next call on it. A slot an event
/// hands out is the caller's until it gives it back (`ReleaseVideoSlot`).
///
/// NOTES:
/// The pictures are numbered too (`uid`), the missing ones with them, and
/// a number is never given twice: a list entry and a reference name their
/// picture by it as well as by its slot, which a later picture reuses.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ParseVideoPacket`, `ReleaseVideoSlot`, `ResetVideoParser`
///
/// EXAMPLES:
/// ```zig
/// var event: vp.VideoEvent = .{};
/// while (true) {
///     switch (vpb.NextVideoEvent(parser, &event)) {
///         vp.VPERR_OK => {},
///         vp.VPERR_NEED_DATA, vp.VPERR_END => break,
///         vp.VPERR_FULL => return, // a shown picture is to be given back first
///         else => continue, // a unit passed over
///     }
///     switch (event.kind) {
///         vp.VPEV_SLICE => decodeSlice(event.slice.?),
///         vp.VPEV_SHOW => show(event.slot, event.time),
///         vp.VPEV_FREE => vpb.ReleaseVideoSlot(parser, event.slot),
///         else => {},
///     }
/// }
/// ```
pub fn NextVideoEvent(_: *VideoParseBase, parser: *vp.VideoParser, event: *vp.VideoEvent) i32 {
    const p = _parser.of(parser);
    while (true) {
        if (p.events.pop()) |next| {
            event.* = next;
            return vp.VPERR_OK;
        }
        if (!p.has_packet) return if (p.stream_ended) vp.VPERR_END else vp.VPERR_NEED_DATA;
        const found = p.peek() catch {
            // A length past the packet's end: nothing after it is a unit.
            p.at = p.packet.bytes;
            return vp.VPERR_CORRUPT;
        };
        if (found) |u| {
            // The slice waiting for its partitions said first.
            var step = _parser.before(p, u) catch |e| return _parser.codeOf(e);
            if (step == .done) {
                step = _parser.unit(p, u) catch |e| {
                    p.advance();
                    return _parser.codeOf(e);
                };
                if (step == .done) p.advance();
            }
            if (step == .full and p.events.count == 0) return vp.VPERR_FULL;
            continue;
        }
        // The packet is read through: its access unit ends, and the
        // stream with the last one.
        const flags = p.packet.flags;
        if (flags & vp.VPPKT_ACCESS_UNIT != 0 and !p.unit_ended) {
            const step = _parser.endAccessUnit(p) catch |e| return _parser.codeOf(e);
            if (step == .done) p.unit_ended = true else if (p.events.count == 0) return vp.VPERR_FULL;
            continue;
        }
        if (flags & vp.VPPKT_END != 0 and !p.stream_ended) {
            const step = _parser.flush(p) catch |e| return _parser.codeOf(e);
            if (step == .done) p.stream_ended = true else if (p.events.count == 0) return vp.VPERR_FULL;
            continue;
        }
        p.has_packet = false;
    }
}
