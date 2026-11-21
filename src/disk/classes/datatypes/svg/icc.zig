// SPDX-License-Identifier: MIT
//! ICC profiles: a colour given in a profile's colour space - CMYK, RGB,
//! grey, Lab or any other of up to eight values - taken to sRGB, for an
//! `icc-color` of a `color-profile` (`toSrgb`).
//!
//! A profile is a header of 128 bytes, a count of tags and a record of
//! each: its signature, where it is and how long. The colour is taken to
//! the profile's connection space - CIE XYZ or CIE Lab, both under D50 -
//! by the first that is there of:
//!
//!   - the table for the rendering intent asked (`A2B0` perceptual,
//!     `A2B1` relative colorimetric, `A2B2` saturation), else `A2B0`:
//!     of 8 bits (`mft1`), of 16 (`mft2`) - curves in, a grid looked up
//!     between its points, curves out - or of the fourth version
//!     (`mAB `), its curves, grid, curves, matrix and curves in that
//!     order, each there or not;
//!   - for RGB, three columns of XYZ (`rXYZ`, `gXYZ`, `bXYZ`) after a
//!     curve each (`rTRC`, `gTRC`, `bTRC`); for grey, its curve (`kTRC`)
//!     times D50's white.
//!
//! A curve is a gamma or a table of 16-bit steps (`curv`), or one of the
//! five parametric forms (`para`). A grid of n inputs is read between the
//! 2^n points round the colour, each weighted by how near it is. Lab is
//! read as its encoding says - the 16-bit tables' of the second version,
//! 0xFF00 for 100, and everything else's, 0xFFFF; XYZ as 1.15 fixed. The
//! connection space's XYZ is taken from D50 to D65 by Bradford's
//! transform and so to linear sRGB, then encoded.
//!
//! Nothing is allocated; a profile is read from its bytes each time,
//! every place checked against its length. Null for a profile that is
//! damaged, of another connection space, or without a way from its
//! colour space, and for a colour of more or fewer values than it has.

const sdk = @import("sdk");
const vector = sdk.vector;
const Colour = vector.Colour;

/// The most values of a colour: the profile's channels.
pub const most_channels = 8;

/// Rendering intents, as `color-profile`'s `rendering-intent` names them.
pub const INTENT_PERCEPTUAL = 0;
pub const INTENT_RELATIVE = 1;
pub const INTENT_SATURATION = 2;
pub const INTENT_ABSOLUTE = 3;

/// D50's white, as the connection space has it.
const white_d50 = [3]f32{ 0.9642, 1.0, 0.8249 };

/// A profile's bytes, read big-endian, every read inside them.
const Bytes = struct {
    bytes: []const u8,

    fn byte(held: Bytes, at: usize) ?u8 {
        if (at >= held.bytes.len) return null;
        return held.bytes[at];
    }
    fn word(held: Bytes, at: usize) ?u16 {
        if (at + 2 > held.bytes.len or at + 2 < at) return null;
        return @as(u16, held.bytes[at]) << 8 | held.bytes[at + 1];
    }
    fn long(held: Bytes, at: usize) ?u32 {
        if (at + 4 > held.bytes.len or at + 4 < at) return null;
        return @as(u32, held.bytes[at]) << 24 | @as(u32, held.bytes[at + 1]) << 16 | @as(u32, held.bytes[at + 2]) << 8 | held.bytes[at + 3];
    }
    /// A signed 15.16 number.
    fn fixed(held: Bytes, at: usize) ?f32 {
        const raw: i32 = @bitCast(held.long(at) orelse return null);
        return @as(f32, @floatFromInt(raw)) / 65536.0;
    }
    /// The part from `at`, `len` long; null past the end.
    fn part(held: Bytes, at: usize, len: usize) ?Bytes {
        if (at > held.bytes.len or len > held.bytes.len - at) return null;
        return .{ .bytes = held.bytes[at..][0..len] };
    }
    fn from(held: Bytes, at: usize) ?Bytes {
        if (at > held.bytes.len) return null;
        return .{ .bytes = held.bytes[at..] };
    }
};

fn tag(comptime name: *const [4]u8) u32 {
    return @as(u32, name[0]) << 24 | @as(u32, name[1]) << 16 | @as(u32, name[2]) << 8 | name[3];
}

/// How many values a colour of the colour space `space` has; 0 for one
/// not known.
fn channelsOf(space: u32) u32 {
    return switch (space) {
        tag("GRAY") => 1,
        tag("XYZ "), tag("Lab "), tag("Luv "), tag("YCbr"), tag("Yxy "), tag("RGB "), tag("HSV "), tag("HLS "), tag("CMY ") => 3,
        tag("CMYK") => 4,
        tag("2CLR") => 2,
        tag("3CLR") => 3,
        tag("4CLR") => 4,
        tag("5CLR") => 5,
        tag("6CLR") => 6,
        tag("7CLR") => 7,
        tag("8CLR") => 8,
        else => 0,
    };
}

/// The colour `input` - its values in the profile's colour space, each
/// 0 to 1, except Lab's: L 0 to 100, a and b -128 to 127 - in sRGB.
pub fn toSrgb(profile: []const u8, intent: u32, input: []const f32) ?Colour {
    const reading = Bytes{ .bytes = profile };
    if (profile.len < 132) return null;
    const size = reading.long(0).?;
    if (size < 132 or size > profile.len) return null;
    const whole = reading.part(0, size).?;
    const space = whole.long(16).?;
    const connection = whole.long(20).?;
    if (connection != tag("XYZ ") and connection != tag("Lab ")) return null;
    const channels = channelsOf(space);
    if (channels == 0 or input.len != channels) return null;

    // The device values, 0 to 1.
    var device: [most_channels]f32 = undefined;
    for (input, 0..) |value, nth| device[nth] = if (space == tag("Lab ")) switch (nth) {
        0 => value / 100,
        else => (value + 128) / 255,
    } else @min(@max(value, 0), 1);

    var pcs: [3]f32 = undefined;
    var lab_encoding: Encoding = .modern;
    const names = [_]u32{ tag("A2B0"), tag("A2B1"), tag("A2B2") };
    const asked = if (intent == INTENT_ABSOLUTE) tag("A2B1") else names[@min(intent, 2)];
    if (findTag(whole, asked) orelse findTag(whole, tag("A2B0"))) |table| {
        const kind = table.long(0) orelse return null;
        switch (kind) {
            tag("mft1") => lut(table, device[0..channels], &pcs, 1) orelse return null,
            // Its Lab is the second version's, in either version.
            tag("mft2") => {
                lut(table, device[0..channels], &pcs, 2) orelse return null;
                lab_encoding = .legacy;
            },
            tag("mAB ") => lutAtoB(table, device[0..channels], &pcs) orelse return null,
            else => return null,
        }
    } else if (space == tag("RGB ")) {
        pcs = .{ 0, 0, 0 };
        for ([_]u32{ tag("rXYZ"), tag("gXYZ"), tag("bXYZ") }, [_]u32{ tag("rTRC"), tag("gTRC"), tag("bTRC") }, 0..) |column_tag, curve_tag, nth| {
            const column = findTag(whole, column_tag) orelse return null;
            if (column.long(0) != tag("XYZ ")) return null;
            const curve = findTag(whole, curve_tag) orelse return null;
            const level = curveAt(curve, device[nth]) orelse return null;
            for (0..3) |axis| pcs[axis] += (column.fixed(8 + axis * 4) orelse return null) * level;
        }
        return srgbOf(pcs);
    } else if (space == tag("GRAY")) {
        const curve = findTag(whole, tag("kTRC")) orelse return null;
        const level = curveAt(curve, device[0]) orelse return null;
        if (connection == tag("Lab ")) return srgbOf(xyzOfLab(.{ level * 100, 0, 0 }));
        return srgbOf(.{ white_d50[0] * level, white_d50[1] * level, white_d50[2] * level });
    } else return null;

    if (connection == tag("Lab ")) {
        const scale: f32 = if (lab_encoding == .legacy) 65535.0 / 65280.0 else 1;
        return srgbOf(xyzOfLab(.{ pcs[0] * scale * 100, pcs[1] * scale * 255 - 128, pcs[2] * scale * 255 - 128 }));
    }
    // XYZ as 1.15: 0xFFFF is 1 + 32767 / 32768.
    const xyz_scale: f32 = 65535.0 / 32768.0;
    return srgbOf(.{ pcs[0] * xyz_scale, pcs[1] * xyz_scale, pcs[2] * xyz_scale });
}

/// How Lab is held in the connection space's 0 to 1.
const Encoding = enum { modern, legacy };

/// The tag `name`'s data; null for none, or one past the profile.
fn findTag(profile: Bytes, name: u32) ?Bytes {
    const count = profile.long(128) orelse return null;
    if (count > (profile.bytes.len - 132) / 12) return null;
    var nth: u32 = 0;
    while (nth < count) : (nth += 1) {
        const record = 132 + @as(usize, nth) * 12;
        if (profile.long(record).? != name) continue;
        const at = profile.long(record + 4).?;
        const len = profile.long(record + 8).?;
        return profile.part(at, len);
    }
    return null;
}

/// A table of 8 or 16 bits (`bytes` the width of its entries): curves
/// in, the grid, curves out, each value 0 to 1.
fn lut(table: Bytes, input: []const f32, out: *[3]f32, comptime bytes: u32) ?void {
    const ins = table.byte(8) orelse return null;
    const outs = table.byte(9) orelse return null;
    const grid = table.byte(10) orelse return null;
    if (ins != input.len or outs != 3 or grid < 2) return null;
    const in_entries: u32 = if (bytes == 1) 256 else table.word(48) orelse return null;
    const out_entries: u32 = if (bytes == 1) 256 else table.word(50) orelse return null;
    if (in_entries < 2 or out_entries < 2) return null;
    const in_tables: usize = if (bytes == 1) 48 else 52;
    const clut = in_tables + @as(usize, ins) * in_entries * bytes;
    var points: usize = 1;
    for (0..ins) |_| points *= grid;
    const out_tables = clut + points * outs * bytes;
    if (out_tables + @as(usize, outs) * out_entries * bytes > table.bytes.len) return null;

    var through: [most_channels]f32 = undefined;
    for (input, 0..) |value, nth| through[nth] = tableAt(table, in_tables + nth * in_entries * bytes, in_entries, bytes, value) orelse return null;
    var looked: [3]f32 = undefined;
    const points_along: [most_channels]u8 = @splat(grid);
    gridAt(table, clut, &points_along, ins, 3, bytes, through[0..ins], &looked) orelse return null;
    for (0..3) |nth| out[nth] = tableAt(table, out_tables + nth * out_entries * bytes, out_entries, bytes, looked[nth]) orelse return null;
}

/// A table of `entries` steps of `bytes` each at `at`, read at `value`
/// between its steps.
fn tableAt(table: Bytes, at: usize, entries: u32, comptime bytes: u32, value: f32) ?f32 {
    const place = @min(@max(value, 0), 1) * @as(f32, @floatFromInt(entries - 1));
    const low: u32 = @intFromFloat(@floor(place));
    const high = @min(low + 1, entries - 1);
    const share = place - @as(f32, @floatFromInt(low));
    const first = entryAt(table, at + low * bytes, bytes) orelse return null;
    const second = entryAt(table, at + high * bytes, bytes) orelse return null;
    return first + (second - first) * share;
}

fn entryAt(table: Bytes, at: usize, comptime bytes: u32) ?f32 {
    return if (bytes == 1)
        @as(f32, @floatFromInt(table.byte(at) orelse return null)) / 255
    else
        @as(f32, @floatFromInt(table.word(at) orelse return null)) / 65535;
}

/// A grid of `ins` inputs, `grid[n]` points along input n, the last
/// input's the fastest, each point `outs` entries of `bytes`, at `at`:
/// read at `input` between the 2^ins points round it.
fn gridAt(table: Bytes, at: usize, grid: *const [most_channels]u8, ins: u32, outs: u32, comptime bytes: u32, input: []const f32, out: *[3]f32) ?void {
    var below: [most_channels]u32 = undefined;
    var share: [most_channels]f32 = undefined;
    var stride: [most_channels]usize = undefined;
    var step: usize = outs;
    var nth = ins;
    while (nth > 0) {
        nth -= 1;
        stride[nth] = step;
        step *= grid[nth];
        const place = @min(@max(input[nth], 0), 1) * @as(f32, @floatFromInt(grid[nth] - 1));
        below[nth] = @min(@as(u32, @intFromFloat(@floor(place))), grid[nth] - 1);
        share[nth] = place - @as(f32, @floatFromInt(below[nth]));
    }
    if (at + step * bytes > table.bytes.len) return null;
    out.* = .{ 0, 0, 0 };
    var corner: u32 = 0;
    while (corner < (@as(u32, 1) << @intCast(ins))) : (corner += 1) {
        var weight: f32 = 1;
        var place: usize = at;
        for (0..ins) |axis| {
            const up = corner >> @intCast(axis) & 1 != 0;
            const point = if (up) @min(below[axis] + 1, grid[axis] - 1) else below[axis];
            weight *= if (up) share[axis] else 1 - share[axis];
            place += point * stride[axis] * bytes;
        }
        if (weight == 0) continue;
        for (0..3) |channel| out[channel] += weight * (entryAt(table, place + channel * bytes, bytes) orelse return null);
    }
}

/// A table of the fourth version: A curves, the grid, M curves, the
/// matrix and B curves, each where its offset is not 0.
fn lutAtoB(table: Bytes, input: []const f32, out: *[3]f32) ?void {
    const ins = table.byte(8) orelse return null;
    const outs = table.byte(9) orelse return null;
    if (ins != input.len or outs != 3) return null;
    const b_curves = table.long(12) orelse return null;
    const matrix = table.long(16) orelse return null;
    const m_curves = table.long(20) orelse return null;
    const clut = table.long(24) orelse return null;
    const a_curves = table.long(28) orelse return null;

    var values: [most_channels]f32 = undefined;
    @memcpy(values[0..ins], input);
    if (a_curves != 0) curvesAt(table, a_curves, values[0..ins]) orelse return null;
    var three: [3]f32 = undefined;
    if (clut != 0) {
        var grid: [most_channels]u8 = undefined;
        for (0..ins) |nth| grid[nth] = table.byte(clut + nth) orelse return null;
        for (grid[0..ins]) |points| if (points < 2) return null;
        const precision = table.byte(clut + 16) orelse return null;
        switch (precision) {
            1 => gridAt(table, clut + 20, &grid, ins, 3, 1, values[0..ins], &three) orelse return null,
            2 => gridAt(table, clut + 20, &grid, ins, 3, 2, values[0..ins], &three) orelse return null,
            else => return null,
        }
    } else {
        if (ins != 3) return null;
        three = values[0..3].*;
    }
    if (m_curves != 0) curvesAt(table, m_curves, &three) orelse return null;
    if (matrix != 0) {
        var made: [3]f32 = undefined;
        for (0..3) |row| {
            made[row] = table.fixed(matrix + 36 + row * 4) orelse return null;
            for (0..3) |column| made[row] += (table.fixed(matrix + (row * 3 + column) * 4) orelse return null) * three[column];
        }
        three = made;
    }
    if (b_curves != 0) curvesAt(table, b_curves, &three) orelse return null;
    out.* = three;
}

/// One curve for each of `values`, one after another from `at`, each at
/// a multiple of four.
fn curvesAt(table: Bytes, at: usize, values: []f32) ?void {
    var place = at;
    for (values) |*value| {
        const curve = table.from(place) orelse return null;
        value.* = curveAt(curve, value.*) orelse return null;
        place += ((curveLength(curve) orelse return null) + 3) & ~@as(usize, 3);
    }
}

fn curveLength(curve: Bytes) ?usize {
    return switch (curve.long(0) orelse return null) {
        tag("curv") => 12 + @as(usize, curve.long(8) orelse return null) * 2,
        tag("para") => 12 + @as(usize, switch (curve.word(8) orelse return null) {
            0 => 1,
            1 => 3,
            2 => 4,
            3 => 5,
            4 => 7,
            else => return null,
        }) * 4,
        else => null,
    };
}

/// A curve at `value`, 0 to 1: a gamma, a table, or a parametric one.
fn curveAt(curve: Bytes, value_in: f32) ?f32 {
    const value = @min(@max(value_in, 0), 1);
    switch (curve.long(0) orelse return null) {
        tag("curv") => {
            const count = curve.long(8) orelse return null;
            if (count == 0) return value;
            if (count == 1) {
                const gamma = @as(f32, @floatFromInt(curve.word(12) orelse return null)) / 256;
                return power(value, gamma);
            }
            if (count > (curve.bytes.len -| 12) / 2) return null;
            return tableAt(curve, 12, count, 2, value);
        },
        tag("para") => {
            const kind = curve.word(8) orelse return null;
            var params: [7]f32 = .{ 1, 1, 0, 0, 0, 0, 0 };
            const count: usize = switch (kind) {
                0 => 1,
                1 => 3,
                2 => 4,
                3 => 5,
                4 => 7,
                else => return null,
            };
            for (0..count) |nth| params[nth] = curve.fixed(12 + nth * 4) orelse return null;
            // Y = (aX + b)^g past -b / a or d; c, e and f added or the
            // line below.
            const gamma = params[0];
            const slope = params[1];
            const offset = params[2];
            return switch (kind) {
                0 => power(value, gamma),
                1 => if (value >= -offset / slope) power(slope * value + offset, gamma) else 0,
                2 => if (value >= -offset / slope) power(slope * value + offset, gamma) + params[3] else params[3],
                3 => if (value >= params[4]) power(slope * value + offset, gamma) else params[3] * value,
                else => if (value >= params[4]) power(slope * value + offset, gamma) + params[5] else params[3] * value + params[6],
            };
        },
        else => return null,
    }
}

fn power(base: f32, exponent: f32) f32 {
    if (!(base > 0)) return 0;
    return @exp(exponent * @log(base));
}

/// CIE Lab under D50 in XYZ.
fn xyzOfLab(lab: [3]f32) [3]f32 {
    const fy = (lab[0] + 16) / 116;
    const fx = fy + lab[1] / 500;
    const fz = fy - lab[2] / 200;
    return .{ white_d50[0] * labInverse(fx), white_d50[1] * labInverse(fy), white_d50[2] * labInverse(fz) };
}

fn labInverse(level: f32) f32 {
    const delta: f32 = 6.0 / 29.0;
    return if (level > delta) level * level * level else 3 * delta * delta * (level - 4.0 / 29.0);
}

/// XYZ under D50 in sRGB: to D65 by Bradford's transform and on to linear
/// sRGB in one matrix, then encoded.
fn srgbOf(xyz: [3]f32) Colour {
    const into = [3][3]f32{
        .{ 3.1338561, -1.6168667, -0.4906146 },
        .{ -0.9787684, 1.9161415, 0.0334540 },
        .{ 0.0719453, -0.2289914, 1.4052427 },
    };
    var rgb: [3]f32 = undefined;
    for (into, 0..) |row, nth| {
        const linear = row[0] * xyz[0] + row[1] * xyz[1] + row[2] * xyz[2];
        rgb[nth] = encoded(@min(@max(linear, 0), 1));
    }
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 1 };
}

fn encoded(level: f32) f32 {
    if (level <= 0.0031308) return level * 12.92;
    return 1.055 * power(level, 1.0 / 2.4) - 0.055;
}

// --- tests ---------------------------------------------------------------------

const testing = @import("std").testing;

/// A profile's header and tag table of `tags`, the tags' data after it.
const Built = struct {
    bytes: [4096]u8 = @splat(0),
    len: usize = 0,

    fn put(built: *Built, value: u32, width: usize) void {
        var nth = width;
        while (nth > 0) {
            nth -= 1;
            built.bytes[built.len] = @truncate(value >> @intCast(nth * 8));
            built.len += 1;
        }
    }
    fn fixed(built: *Built, value: f32) void {
        built.put(@bitCast(@as(i32, @intFromFloat(@round(value * 65536)))), 4);
    }

    fn start(built: *Built, space: *const [4]u8, connection: *const [4]u8, version: u8, tags: []const *const [4]u8) void {
        built.len = 128;
        built.bytes[8] = version;
        @memcpy(built.bytes[16..20], space);
        @memcpy(built.bytes[20..24], connection);
        built.put(@intCast(tags.len), 4);
        for (tags) |name| {
            @memcpy(built.bytes[built.len..][0..4], name);
            built.len += 12;
        }
    }
    /// The tag `nth` starts here.
    fn begin(built: *Built, nth: usize) void {
        while (built.len % 4 != 0) built.len += 1;
        const record = 132 + nth * 12 + 4;
        const at = built.len;
        built.len = record;
        built.put(@intCast(at), 4);
        built.len = at;
    }
    fn finish(built: *Built, nth: usize, began: usize) void {
        const record = 132 + nth * 12 + 8;
        const end = built.len;
        built.len = record;
        built.put(@intCast(end - began), 4);
        built.len = end;
    }
    fn done(built: *Built) []const u8 {
        const end = built.len;
        built.len = 0;
        built.put(@intCast(end), 4);
        built.len = end;
        return built.bytes[0..end];
    }
};

fn expectColour(colour: ?Colour, red: f32, green: f32, blue: f32) !void {
    const got = colour orelse return error.NoColour;
    try testing.expectApproxEqAbs(red, got.r, 0.01);
    try testing.expectApproxEqAbs(green, got.g, 0.01);
    try testing.expectApproxEqAbs(blue, got.b, 0.01);
}

test "a matrix and curves: sRGB's own primaries come back as they went in" {
    var built: Built = .{};
    const names = [_]*const [4]u8{ "rXYZ", "gXYZ", "bXYZ", "rTRC", "gTRC", "bTRC" };
    built.start("RGB ", "XYZ ", 2, &names);
    // sRGB's primaries under D50, and a gamma of 2.2 for each curve.
    const columns = [3][3]f32{ .{ 0.4360, 0.2225, 0.0139 }, .{ 0.3851, 0.7169, 0.0971 }, .{ 0.1431, 0.0606, 0.7141 } };
    for (columns, 0..) |column, nth| {
        built.begin(nth);
        const began = built.len;
        built.put(tag("XYZ "), 4);
        built.put(0, 4);
        for (column) |value| built.fixed(value);
        built.finish(nth, began);
    }
    for (3..6) |nth| {
        built.begin(nth);
        const began = built.len;
        built.put(tag("curv"), 4);
        built.put(0, 4);
        built.put(1, 4);
        built.put(563, 2);
        built.finish(nth, began);
    }
    const profile = built.done();
    try expectColour(toSrgb(profile, INTENT_PERCEPTUAL, &.{ 1, 0, 0 }), 1, 0, 0);
    try expectColour(toSrgb(profile, INTENT_PERCEPTUAL, &.{ 1, 1, 1 }), 1, 1, 1);
    try expectColour(toSrgb(profile, INTENT_PERCEPTUAL, &.{ 0, 0, 0 }), 0, 0, 0);
    // Too few values, and a profile cut short.
    try testing.expect(toSrgb(profile, INTENT_PERCEPTUAL, &.{ 1, 0 }) == null);
    try testing.expect(toSrgb(profile[0 .. profile.len - 8], INTENT_PERCEPTUAL, &.{ 1, 0, 0 }) == null);
}

test "a table of CMYK to Lab: the grid read between its points, white paper and full black" {
    var built: Built = .{};
    built.start("CMYK", "Lab ", 2, &.{"A2B0"});
    built.begin(0);
    const began = built.len;
    // 8 bits, four in, three out, a grid of two points along each.
    built.put(tag("mft1"), 4);
    built.put(0, 4);
    built.put(4, 1);
    built.put(3, 1);
    built.put(2, 1);
    built.put(0, 1);
    for (0..9) |nth| built.fixed(if (nth % 4 == 0) 1 else 0);
    for (0..4) |_| for (0..256) |entry| built.put(@intCast(entry), 1);
    // Each point: white (L 100, a and b 0) where no ink is, else black.
    for (0..16) |point| {
        const ink = point != 0;
        built.put(if (ink) 0 else 255, 1);
        built.put(128, 1);
        built.put(128, 1);
    }
    for (0..3) |_| for (0..256) |entry| built.put(@intCast(entry), 1);
    built.finish(0, began);
    const profile = built.done();
    try expectColour(toSrgb(profile, INTENT_PERCEPTUAL, &.{ 0, 0, 0, 0 }), 1, 1, 1);
    try expectColour(toSrgb(profile, INTENT_PERCEPTUAL, &.{ 0, 0, 0, 1 }), 0, 0, 0);
    // Half black: L 50, a mid grey.
    try expectColour(toSrgb(profile, INTENT_RELATIVE, &.{ 0, 0, 0, 0.5 }), 0.467, 0.467, 0.467);
}
