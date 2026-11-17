// SPDX-License-Identifier: MPL-2.0
//! RtgCicp: One of H.273's numbers for a picture's colours, as rtg says
//! it.
//!
//! A stream's parameter set and a container's own element both describe
//! the colours in the numbering of ITU-T H.273 - the code points the
//! standards share - where 2 is "unspecified", which is what a file that
//! says nothing of itself leaves. `RtgYuv` says the same things in
//! numbers of its own, and fewer of them: what the boards here show.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Turns one of H.273's numbers for a picture's colours into rtg's.
///
/// SYNOPSIS:
/// ```zig
/// fn RtgCicp(_: *RtgBase, kind: u32, value: u32) i32
/// ```
///
/// SINCE: 1.15. LVO -204.
///
/// INPUTS:
/// - `kind` - which of H.273's tables `value` is of: `RTGCICP_MATRIX`
///   (matrix coefficients, its Table 4), `RTGCICP_TRANSFER` (transfer
///   characteristics, Table 3) or `RTGCICP_PRIMARIES` (colour primaries,
///   Table 2).
/// - `value` - the number, as the stream or the container has it.
///
/// RESULT:
/// What `RtgYuv`'s field of that kind takes - `RTGYUV_BT601`,
/// `RTGYUV_BT709` or `RTGYUV_BT2020` for a matrix; `RTGYUV_SDR`,
/// `RTGYUV_PQ` or `RTGYUV_HLG` for a transfer; `RTGYUV_BT709`,
/// `RTGYUV_BT2020` or `RTGYUV_P3` for primaries - or -1: for a number
/// that says nothing ("unspecified" among them), one that names what no
/// board here shows, and a `kind` that is none of the three.
///
/// BEHAVIOR:
/// Several of H.273's numbers are one of rtg's: every matrix a
/// television has had is `RTGYUV_BT601`, both BT.2020 matrices
/// `RTGYUV_BT2020`; BT.709's curve, BT.601's and BT.2020's at either
/// depth are the one `RTGYUV_SDR`; BT.601's primaries are taken as
/// BT.709's, which they are within a step.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// On -1 what the caller had stands: the decoder's own word, or what a
/// picture of that size would be guessed to be.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenVideoLayer`, `ShowVideoFrame`
///
/// EXAMPLES:
/// ```zig
/// const told = rb.RtgCicp(rtg.RTGCICP_MATRIX, track.matrix);
/// if (told >= 0) picture.matrix = @intCast(told);
/// ```
pub fn RtgCicp(_: *RtgBase, kind: u32, value: u32) i32 {
    return switch (kind) {
        rtg.RTGCICP_MATRIX => switch (value) {
            1 => rtg.RTGYUV_BT709,
            // FCC, BT.470 B/G, BT.601 and SMPTE 240M are a television's.
            4, 5, 6, 7 => rtg.RTGYUV_BT601,
            // BT.2020, of either luminance.
            9, 10 => rtg.RTGYUV_BT2020,
            else => -1,
        },
        rtg.RTGCICP_TRANSFER => switch (value) {
            // BT.709's curve, BT.601's, and BT.2020's at either depth:
            // one curve, the television's.
            1, 6, 14, 15 => rtg.RTGYUV_SDR,
            16 => rtg.RTGYUV_PQ,
            18 => rtg.RTGYUV_HLG,
            else => -1,
        },
        rtg.RTGCICP_PRIMARIES => switch (value) {
            1, 5, 6, 7 => rtg.RTGYUV_BT709,
            9 => rtg.RTGYUV_BT2020,
            11, 12 => rtg.RTGYUV_P3,
            else => -1,
        },
        else => -1,
    };
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "a stream's colour numbers as a picture says them, and nothing where they say nothing" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const matrix = rtg.RTGCICP_MATRIX;
    const transfer = rtg.RTGCICP_TRANSFER;
    const primaries = rtg.RTGCICP_PRIMARIES;

    try testing.expectEqual(@as(i32, rtg.RTGYUV_BT709), fixture.base(rb).RtgCicp(matrix, 1));
    for ([_]u32{ 4, 5, 6, 7 }) |television| try testing.expectEqual(@as(i32, rtg.RTGYUV_BT601), fixture.base(rb).RtgCicp(matrix, television));
    for ([_]u32{ 9, 10 }) |wide| try testing.expectEqual(@as(i32, rtg.RTGYUV_BT2020), fixture.base(rb).RtgCicp(matrix, wide));

    for ([_]u32{ 1, 6, 14, 15 }) |curve| try testing.expectEqual(@as(i32, rtg.RTGYUV_SDR), fixture.base(rb).RtgCicp(transfer, curve));
    try testing.expectEqual(@as(i32, rtg.RTGYUV_PQ), fixture.base(rb).RtgCicp(transfer, 16));
    try testing.expectEqual(@as(i32, rtg.RTGYUV_HLG), fixture.base(rb).RtgCicp(transfer, 18));

    for ([_]u32{ 1, 5, 6, 7 }) |television| try testing.expectEqual(@as(i32, rtg.RTGYUV_BT709), fixture.base(rb).RtgCicp(primaries, television));
    try testing.expectEqual(@as(i32, rtg.RTGYUV_BT2020), fixture.base(rb).RtgCicp(primaries, 9));
    for ([_]u32{ 11, 12 }) |cinema| try testing.expectEqual(@as(i32, rtg.RTGYUV_P3), fixture.base(rb).RtgCicp(primaries, cinema));

    // "Unspecified", a number nothing here shows, one past a byte, and a
    // table that is none of the three.
    for ([_]u32{ matrix, transfer, primaries }) |kind| {
        for ([_]u32{ 0, 2, 3, 8, 13, 255, 256, ~@as(u32, 0) }) |silent| {
            try testing.expect(fixture.base(rb).RtgCicp(kind, silent) < 0);
        }
    }
    try testing.expect(fixture.base(rb).RtgCicp(3, 1) < 0);
    try fixture.tearDown(rb);
}
