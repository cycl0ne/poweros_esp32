// SPDX-License-Identifier: MIT
//! ParseVideoPacket: a packet handed over, to be read as the events are
//! asked for.

const sdk = @import("sdk");
const vp = sdk.videoparse;
const VideoParseBase = @import("../videoparse_base.zig").VideoParseBase;
const _parser = @import("_parser.zig");

/// Hands a parser the stream's next packet.
///
/// SYNOPSIS:
/// ```zig
/// fn ParseVideoPacket(base: *VideoParseBase, parser: *vp.VideoParser, packet: *const vp.VideoPacket) i32
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `parser`: what OpenVideoParser made.
/// - `packet`: its bytes (`data`, `bytes`) - units after start codes, or
///   each after its length where the setup said so; a VP9 frame or
///   superframe, as a WebM or Matroska block holds it - when its picture is
///   shown (`time`, in the caller's units), and `flags`:
///   `VPPKT_ACCESS_UNIT` where the packet is one access unit, as an MP4's
///   or a Matroska track's is, so its picture ends with it;
///   `VPPKT_END` at the stream's end, with or without bytes: every
///   picture held is shown, and every slot let go of (VPEV_FREE).
///
/// RESULT:
/// VPERR_OK; VPERR_FULL while the packet before still has events to ask
/// for - the packet is not taken.
///
/// BEHAVIOR:
/// Nothing is read yet: `NextVideoEvent` reads the packet a unit at a
/// time, and answers VPERR_NEED_DATA once it is read through, which is
/// when the next is to be handed over. A picture whose packet did not say
/// VPPKT_ACCESS_UNIT ends when the next picture's first slice comes, or
/// a unit that comes only between pictures (a parameter set, an access
/// unit delimiter, SEI).
///
/// A VP9 packet's frames are read one after the other, by the index at
/// its end where it is a superframe; `VPPKT_ACCESS_UNIT` says nothing
/// more of it.
///
/// A picture takes the time of the packet its first slice came in. Where
/// pictures come out in another order than they came in, each is shown
/// at the earliest time of those waiting: the same where the container
/// gave each packet the time its picture is shown, and still rising
/// where it gave the time it is decoded.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// The bytes stay the caller's, and must stay as they are until
/// `NextVideoEvent` answers VPERR_NEED_DATA or VPERR_END, the parser is
/// reset or closed. The packet structure itself is copied.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NextVideoEvent`, `ResetVideoParser`
///
/// EXAMPLES:
/// ```zig
/// const packet: vp.VideoPacket = .{ .data = got.data, .bytes = got.bytes, .flags = vp.VPPKT_ACCESS_UNIT, .time = got.time };
/// _ = vpb.ParseVideoPacket(parser, &packet);
/// ```
pub fn ParseVideoPacket(_: *VideoParseBase, parser: *vp.VideoParser, packet: *const vp.VideoPacket) i32 {
    const p = _parser.of(parser);
    if (p.has_packet) return vp.VPERR_FULL;
    p.take(packet);
    return vp.VPERR_OK;
}
