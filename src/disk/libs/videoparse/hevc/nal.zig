// SPDX-License-Identifier: MIT
//! NAL units (7.3.1, annex B): finding them in a byte stream or after
//! their lengths, their two-byte header, and their payload with the
//! emulation prevention bytes taken out.

const Error = @import("bits.zig").Error;

/// nal_unit_type (Table 7-1).
pub const Type = struct {
    pub const trail_n: u6 = 0;
    pub const trail_r: u6 = 1;
    pub const tsa_n: u6 = 2;
    pub const tsa_r: u6 = 3;
    pub const stsa_n: u6 = 4;
    pub const stsa_r: u6 = 5;
    pub const radl_n: u6 = 6;
    pub const radl_r: u6 = 7;
    pub const rasl_n: u6 = 8;
    pub const rasl_r: u6 = 9;
    pub const bla_w_lp: u6 = 16;
    pub const bla_w_radl: u6 = 17;
    pub const bla_n_lp: u6 = 18;
    pub const idr_w_radl: u6 = 19;
    pub const idr_n_lp: u6 = 20;
    pub const cra: u6 = 21;
    /// The last of the IRAP types (RSV_IRAP_VCL23).
    pub const irap_last: u6 = 23;
    pub const vps: u6 = 32;
    pub const sps: u6 = 33;
    pub const pps: u6 = 34;
    pub const aud: u6 = 35;
    pub const end_of_seq: u6 = 36;
    pub const end_of_stream: u6 = 37;
    pub const filler: u6 = 38;
    pub const prefix_sei: u6 = 39;
    pub const suffix_sei: u6 = 40;
};

pub const Header = struct {
    kind: u6,
    layer: u6,
    /// TemporalId: nuh_temporal_id_plus1 - 1.
    tid: u3,

    /// A coded slice segment of a picture of a type this standard
    /// defines (the reserved VCL types are passed over).
    pub fn isSlice(h: Header) bool {
        return h.kind <= Type.rasl_r or (h.kind >= Type.bla_w_lp and h.kind <= Type.cra);
    }
    /// An intra random access point: BLA, IDR or CRA.
    pub fn isIrap(h: Header) bool {
        return h.kind >= Type.bla_w_lp and h.kind <= Type.irap_last;
    }
    pub fn isIdr(h: Header) bool {
        return h.kind == Type.idr_w_radl or h.kind == Type.idr_n_lp;
    }
    pub fn isBla(h: Header) bool {
        return h.kind >= Type.bla_w_lp and h.kind <= Type.bla_n_lp;
    }
    pub fn isRasl(h: Header) bool {
        return h.kind == Type.rasl_n or h.kind == Type.rasl_r;
    }
    pub fn isRadl(h: Header) bool {
        return h.kind == Type.radl_n or h.kind == Type.radl_r;
    }
    /// A sub-layer non-reference picture (the _N types below 16), which
    /// no picture of its own sub-layer refers to.
    pub fn isSubLayerNonRef(h: Header) bool {
        return h.kind < 16 and h.kind & 1 == 0;
    }
};

/// The two header bytes read (7.3.1.2).
pub fn header(unit: []const u8) Error!Header {
    if (unit.len < 2 or unit[0] & 0x80 != 0) return error.Corrupt;
    const plus1: u3 = @intCast(unit[1] & 7);
    if (plus1 == 0) return error.Corrupt;
    return .{
        .kind = @intCast((unit[0] >> 1) & 63),
        .layer = @intCast(((unit[0] & 1) << 5) | (unit[1] >> 3)),
        .tid = plus1 - 1,
    };
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

/// What an `hvcC` box (ISO 14496-15 8.3.3) says: how long a unit's
/// length is in the packets, and its parameter sets and SEI, each a NAL
/// unit.
pub const HevcConfig = struct {
    length_size: u8,
    data: []const u8,

    /// configurationVersion, the profile, tier and level, ... then
    /// lengthSizeMinusOne in byte 21 and numOfArrays in byte 22.
    pub fn parse(data: []const u8) Error!HevcConfig {
        if (data.len < 23 or data[0] != 1) return error.Corrupt;
        const size = (data[21] & 3) + 1;
        if (size == 3) return error.Corrupt;
        return .{ .length_size = size, .data = data };
    }

    /// Each unit of each array in turn.
    pub const Units = struct {
        data: []const u8,
        pos: usize = 23,
        arrays: u32,
        left: u32 = 0,

        pub fn next(it: *Units) Error!?[]const u8 {
            while (it.left == 0) {
                if (it.arrays == 0) return null;
                if (it.pos + 3 > it.data.len) return error.Corrupt;
                // array_completeness, reserved, NAL_unit_type; numNalus.
                it.left = @as(u32, it.data[it.pos + 1]) << 8 | it.data[it.pos + 2];
                it.pos += 3;
                it.arrays -= 1;
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

    pub fn units(c: HevcConfig) Units {
        return .{ .data = c.data, .arrays = c.data[22] };
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "two-byte headers, annex B units, hvcC arrays, emulation prevention" {
    const stream = [_]u8{ 0, 0, 0, 1, 0x40, 0x01, 7, 0, 0, 1, 0x26, 0x01, 0, 0, 3, 1, 9 };
    var it = AnnexB{ .data = &stream };
    const vps = it.next().?;
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x01, 7 }, vps);
    const h = try header(vps);
    try testing.expectEqual(Type.vps, h.kind);
    try testing.expectEqual(@as(u3, 0), h.tid);
    const idr = it.next().?;
    const hi = try header(idr);
    try testing.expectEqual(Type.idr_w_radl, hi.kind);
    try testing.expect(hi.isIrap() and hi.isIdr() and hi.isSlice() and !hi.isSubLayerNonRef());
    try testing.expect(it.next() == null);
    var out: [8]u8 = undefined;
    const n = unescape(idr[2..], &out);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 9 }, out[0..n]);
    // A forbidden bit, and a TemporalId plus 1 of 0.
    try testing.expectError(error.Corrupt, header(&.{ 0xC0, 1 }));
    try testing.expectError(error.Corrupt, header(&.{ 0x40, 0 }));
    var config = [_]u8{0} ** 23 ++ [_]u8{ 0xA0, 0, 1, 0, 2, 0x40, 0x01, 0xA1, 0, 2, 0, 1, 0x42, 0, 1, 0x44 };
    config[0] = 1;
    config[21] = 0xFF;
    config[22] = 2;
    const c = try HevcConfig.parse(&config);
    try testing.expectEqual(@as(u8, 4), c.length_size);
    var u = c.units();
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x01 }, (try u.next()).?);
    try testing.expectEqualSlices(u8, &.{0x42}, (try u.next()).?);
    try testing.expectEqualSlices(u8, &.{0x44}, (try u.next()).?);
    try testing.expect((try u.next()) == null);
}
