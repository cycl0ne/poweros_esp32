// SPDX-License-Identifier: MIT
//! NAL units (7.3.1, annex B): finding them in a byte stream or after
//! their lengths, their header, and their payload with the emulation
//! prevention bytes taken out.

const Error = @import("bits.zig").Error;

pub const Type = struct {
    pub const slice: u5 = 1;
    pub const partition_a: u5 = 2;
    pub const partition_b: u5 = 3;
    pub const partition_c: u5 = 4;
    pub const idr: u5 = 5;
    pub const sei: u5 = 6;
    pub const sps: u5 = 7;
    pub const pps: u5 = 8;
    pub const aud: u5 = 9;
    pub const end_of_seq: u5 = 10;
    pub const end_of_stream: u5 = 11;
    pub const filler: u5 = 12;
    pub const sps_ext: u5 = 13;
    pub const prefix: u5 = 14;
    pub const subset_sps: u5 = 15;
    pub const aux_slice: u5 = 19;
    pub const ext_slice: u5 = 20;
};

pub const Header = struct {
    ref_idc: u2,
    kind: u5,
};

pub fn header(byte: u8) Error!Header {
    if (byte & 0x80 != 0) return error.Corrupt;
    return .{ .ref_idc = @intCast((byte >> 5) & 3), .kind = @intCast(byte & 31) };
}

/// The payload of a NAL unit (its bytes after the header) with every
/// emulation prevention byte - the 3 of 00 00 03 - taken out, into `out`,
/// which is at least as long. The bytes written.
pub fn unescape(payload: []const u8, out: []u8) usize {
    var n: usize = 0;
    var zeros: u32 = 0;
    for (payload) |byte| {
        if (zeros >= 2 and byte == 3) {
            zeros = 0;
            continue;
        }
        out[n] = byte;
        n += 1;
        zeros = if (byte == 0) zeros + 1 else 0;
    }
    return n;
}

/// The NAL units of an annex B byte stream, each without its start code
/// and without the zero bytes trailing it.
pub const AnnexB = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn next(it: *AnnexB) ?[]const u8 {
        const d = it.data;
        // The next start code.
        var i = it.pos;
        while (i + 3 <= d.len) : (i += 1) {
            if (d[i] == 0 and d[i + 1] == 0 and d[i + 2] == 1) break;
        } else {
            it.pos = d.len;
            return null;
        }
        const start = i + 3;
        var j = start;
        while (j + 3 <= d.len) : (j += 1) {
            if (d[j] == 0 and d[j + 1] == 0 and (d[j + 2] == 1 or d[j + 2] == 0)) break;
        } else j = d.len;
        var end = j;
        // A zero_byte or trailing_zero_8bits belongs to no unit.
        while (end > start and d[end - 1] == 0) end -= 1;
        it.pos = j;
        if (end == start) return it.next();
        return d[start..end];
    }
};

/// The NAL units of a packet as an MP4 or Matroska file holds them, each
/// after its length in `length_size` bytes.
pub const Sized = struct {
    data: []const u8,
    length_size: u8,
    pos: usize = 0,

    pub fn next(it: *Sized) Error!?[]const u8 {
        if (it.pos >= it.data.len) return null;
        if (it.pos + it.length_size > it.data.len) return error.Corrupt;
        var len: usize = 0;
        for (it.data[it.pos..][0..it.length_size]) |byte| len = len << 8 | byte;
        it.pos += it.length_size;
        if (len > it.data.len - it.pos) return error.Corrupt;
        const unit = it.data[it.pos..][0..len];
        it.pos += len;
        return unit;
    }
};

/// What an `avcC` box (ISO 14496-15) says: how long a unit's length is,
/// and its parameter sets, each a NAL unit.
pub const AvcConfig = struct {
    length_size: u8,
    data: []const u8,

    pub fn parse(data: []const u8) Error!AvcConfig {
        if (data.len < 7 or data[0] != 1) return error.Corrupt;
        return .{ .length_size = (data[4] & 3) + 1, .data = data };
    }

    /// Each sequence then picture parameter set in turn.
    pub const Units = struct {
        data: []const u8,
        pos: usize = 5,
        left: u32 = 0,
        pps_next: bool = false,
        done_sps: bool = false,

        pub fn next(it: *Units) Error!?[]const u8 {
            while (it.left == 0) {
                if (!it.done_sps) {
                    if (it.pos >= it.data.len) return null;
                    it.left = it.data[it.pos] & 31;
                    it.pos += 1;
                    it.done_sps = true;
                } else if (!it.pps_next) {
                    if (it.pos >= it.data.len) return null;
                    it.left = it.data[it.pos];
                    it.pos += 1;
                    it.pps_next = true;
                } else return null;
            }
            if (it.pos + 2 > it.data.len) return error.Corrupt;
            const len = @as(usize, it.data[it.pos]) << 8 | it.data[it.pos + 1];
            it.pos += 2;
            if (len > it.data.len - it.pos) return error.Corrupt;
            const unit = it.data[it.pos..][0..len];
            it.pos += len;
            it.left -= 1;
            return unit;
        }
    };

    pub fn units(c: AvcConfig) Units {
        return .{ .data = c.data };
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "annex B units, lengths before units, and the emulation prevention bytes" {
    const stream = [_]u8{ 0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 0, 1, 0x65, 0, 0, 3, 1, 9 };
    var it = AnnexB{ .data = &stream };
    try testing.expectEqualSlices(u8, &.{ 0x67, 1, 2 }, it.next().?);
    try testing.expectEqualSlices(u8, &.{ 0x68, 3 }, it.next().?);
    const idr = it.next().?;
    try testing.expectEqualSlices(u8, &.{ 0x65, 0, 0, 3, 1, 9 }, idr);
    try testing.expect(it.next() == null);
    var out: [8]u8 = undefined;
    const n = unescape(idr[1..], &out);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 9 }, out[0..n]);
    const sized = [_]u8{ 0, 2, 0x41, 7, 0, 1, 0x01 };
    var s = Sized{ .data = &sized, .length_size = 2 };
    try testing.expectEqualSlices(u8, &.{ 0x41, 7 }, (try s.next()).?);
    try testing.expectEqualSlices(u8, &.{0x01}, (try s.next()).?);
    try testing.expect((try s.next()) == null);
    const h = try header(0x65);
    try testing.expectEqual(@as(u5, Type.idr), h.kind);
    try testing.expectEqual(@as(u2, 3), h.ref_idc);
}
