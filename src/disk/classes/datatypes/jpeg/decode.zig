// SPDX-License-Identifier: MIT
//! What a JPEG file says, and the pixels it unpacks into.
//!
//! A file is a run of segments, each named by a marker: the tables that
//! say how finely each of the sixty-four numbers of a block was kept
//! (`DQT`), the codes the numbers are written in (`DHT`), what the
//! picture is (`SOF0`), and then the scan itself (`SOS`), which is the
//! whole picture as one stream of codes.
//!
//! A picture is not read as pixels but as **blocks of eight by eight**,
//! one set for brightness and one for each of the two colour differences
//! - and the colour ones are usually kept at half the size, because the
//! eye notices less there. So each component is unpacked into a plane of
//! its own at its own size, and the pixels are made at the end by
//! reading all three and turning them into red, green and blue.
//!
//! **Baseline only.** A file whose picture is written in several passes
//! of increasing detail (`SOF2`, progressive) says so and is refused
//! rather than half read: that is a second decoder, not a flag.
//!
//! Numbers in the segments are two bytes, high byte first. Inside the
//! scan a 0xFF byte is written as 0xFF 0x00, so that a marker can still
//! be found by looking for 0xFF.

const idct = @import("idct.zig");

pub const Error = error{
    /// It does not begin the way a JPEG does.
    NotJpeg,
    /// It does, and then says something the format does not allow.
    Corrupt,
    /// Something the format allows and this decoder does not.
    Unsupported,
};

/// The markers that matter, past the 0xFF that introduces each.
pub const M_SOF0: u8 = 0xC0;
pub const M_SOF1: u8 = 0xC1;
pub const M_SOF2: u8 = 0xC2;
pub const M_DHT: u8 = 0xC4;
pub const M_SOI: u8 = 0xD8;
pub const M_EOI: u8 = 0xD9;
pub const M_SOS: u8 = 0xDA;
pub const M_DQT: u8 = 0xDB;
pub const M_DRI: u8 = 0xDD;
pub const M_RST0: u8 = 0xD0;
pub const M_RST7: u8 = 0xD7;

/// The order the sixty-four numbers of a block are written in: out from
/// the flat one, corner by corner, so that the ones most often nothing
/// come last and a run of them is one code.
pub const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

/// One of the codes a file writes its numbers in: how many codes there
/// are of each length, and what each stands for, in order.
pub const Huffman = struct {
    count: [17]u16 = @splat(0),
    symbol: [256]u8 = @splat(0),

    /// The code `from` describes: sixteen counts and then the symbols.
    /// How many bytes it took.
    pub fn read(self: *Huffman, from: []const u8) Error!usize {
        if (from.len < 16) return Error.Corrupt;
        var total: usize = 0;
        for (0..16) |i| {
            self.count[i + 1] = from[i];
            total += from[i];
        }
        if (total > self.symbol.len or 16 + total > from.len) return Error.Corrupt;
        for (0..total) |i| self.symbol[i] = from[16 + i];
        return 16 + total;
    }
};

/// One of the pictures a file is made of: brightness, or a colour
/// difference.
pub const Component = struct {
    id: u8 = 0,
    /// How many blocks of this component there are across and down in
    /// one unit of the picture.
    across: u32 = 1,
    down: u32 = 1,
    quant: u8 = 0,
    dc_table: u8 = 0,
    ac_table: u8 = 0,
    /// Its own plane: how wide a row of it is, how many rows, and where
    /// it is. The plane is the caller's memory.
    stride: u32 = 0,
    lines: u32 = 0,
    plane: [*]u8 = undefined,
    /// What the last block's flat number was, which the next one is
    /// written as a difference from.
    predicted: i32 = 0,
};

/// Everything reading a file needs besides the file: the tables, the
/// components, and the block being worked on. Far too much to stand on
/// a stack, so it is the caller's to allocate.
pub const Work = struct {
    quant: [4][64]u16 = @splat(@splat(0)),
    dc: [4]Huffman = @splat(.{}),
    ac: [4]Huffman = @splat(.{}),
    component: [4]Component = @splat(.{}),
    count: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// The largest `across` and `down` of any component, which is what
    /// one unit of the picture is measured in.
    max_across: u32 = 1,
    max_down: u32 = 1,
    /// How many units apart the stream starts again, 0 for never.
    restart: u32 = 0,
    /// Where the scan's codes begin.
    scan_at: usize = 0,
    block: [64]i32 = @splat(0),
};

/// A two-byte number as the file holds it, high byte first.
pub fn half(from: []const u8) u32 {
    return @as(u32, from[0]) << 8 | from[1];
}

/// The file read as far as its scan: the tables, what the picture is,
/// and where the codes begin. The planes are not touched; the caller
/// gives each component one and calls `readScan`.
pub fn readHeaders(file: []const u8, work: *Work) Error!void {
    if (file.len < 4 or file[0] != 0xFF or file[1] != M_SOI) return Error.NotJpeg;
    var at: usize = 2;
    var seen_frame = false;
    while (at + 4 <= file.len) {
        if (file[at] != 0xFF) return Error.Corrupt;
        const marker = file[at + 1];
        // A run of 0xFF bytes is padding before a marker.
        if (marker == 0xFF) {
            at += 1;
            continue;
        }
        if (marker == M_EOI) return Error.Corrupt;
        const length = half(file[at + 2 ..]);
        if (length < 2 or at + 2 + length > file.len) return Error.Corrupt;
        const body = file[at + 4 ..][0 .. length - 2];
        switch (marker) {
            M_DQT => try readQuant(work, body),
            M_DHT => try readCodes(work, body),
            M_DRI => work.restart = if (body.len >= 2) half(body) else 0,
            M_SOF0, M_SOF1 => {
                try readFrame(work, body);
                seen_frame = true;
            },
            // Written in passes of increasing detail, or with a
            // different kind of coding: a second decoder either way.
            M_SOF2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF => return Error.Unsupported,
            M_SOS => {
                if (!seen_frame) return Error.Corrupt;
                try readScanHeader(work, body);
                work.scan_at = at + 2 + length;
                return;
            },
            else => {},
        }
        at += 2 + length;
    }
    return Error.Corrupt;
}

/// `DQT`: how finely each of a block's sixty-four numbers was kept.
fn readQuant(work: *Work, body: []const u8) Error!void {
    var at: usize = 0;
    while (at < body.len) {
        const which = body[at] & 0x0F;
        const wide = body[at] >> 4 != 0;
        at += 1;
        if (which >= work.quant.len) return Error.Corrupt;
        const bytes: usize = if (wide) 128 else 64;
        if (at + bytes > body.len) return Error.Corrupt;
        for (0..64) |i| {
            work.quant[which][i] = if (wide) @intCast(half(body[at + i * 2 ..])) else body[at + i];
        }
        at += bytes;
    }
}

/// `DHT`: the codes the numbers are written in.
fn readCodes(work: *Work, body: []const u8) Error!void {
    var at: usize = 0;
    while (at < body.len) {
        const which = body[at] & 0x0F;
        const is_ac = body[at] >> 4 != 0;
        at += 1;
        if (which >= work.dc.len) return Error.Corrupt;
        const table = if (is_ac) &work.ac[which] else &work.dc[which];
        at += try table.read(body[at..]);
    }
}

/// `SOF0`: what the picture is, and what it is made of.
fn readFrame(work: *Work, body: []const u8) Error!void {
    if (body.len < 6) return Error.Corrupt;
    if (body[0] != 8) return Error.Unsupported; // eight bits a number
    work.height = half(body[1..]);
    work.width = half(body[3..]);
    work.count = body[5];
    if (work.width == 0 or work.height == 0) return Error.Corrupt;
    if (work.count == 0 or work.count > work.component.len) return Error.Unsupported;
    if (body.len < 6 + work.count * 3) return Error.Corrupt;
    work.max_across = 1;
    work.max_down = 1;
    for (0..work.count) |i| {
        const at = 6 + i * 3;
        const component = &work.component[i];
        component.* = .{
            .id = body[at],
            .across = body[at + 1] >> 4,
            .down = body[at + 1] & 0x0F,
            .quant = body[at + 2],
        };
        if (component.across == 0 or component.across > 4) return Error.Corrupt;
        if (component.down == 0 or component.down > 4) return Error.Corrupt;
        if (component.quant >= work.quant.len) return Error.Corrupt;
        work.max_across = @max(work.max_across, component.across);
        work.max_down = @max(work.max_down, component.down);
    }
}

/// `SOS`: which code each component's numbers are written in.
fn readScanHeader(work: *Work, body: []const u8) Error!void {
    if (body.len < 1) return Error.Corrupt;
    const count = body[0];
    if (count != work.count) return Error.Unsupported;
    if (body.len < 1 + @as(usize, count) * 2 + 3) return Error.Corrupt;
    for (0..count) |i| {
        const id = body[1 + i * 2];
        const tables = body[2 + i * 2];
        var found = false;
        for (work.component[0..work.count]) |*component| {
            if (component.id != id) continue;
            component.dc_table = tables >> 4;
            component.ac_table = tables & 0x0F;
            if (component.dc_table >= work.dc.len or component.ac_table >= work.ac.len) return Error.Corrupt;
            found = true;
        }
        if (!found) return Error.Corrupt;
    }
}

/// How wide one unit of the picture is, in pixels, and how tall.
pub fn unitWidth(work: *const Work) u32 {
    return work.max_across * 8;
}
pub fn unitHeight(work: *const Work) u32 {
    return work.max_down * 8;
}

/// How many units there are across the picture, and down it.
pub fn unitsAcross(work: *const Work) u32 {
    return (work.width + unitWidth(work) - 1) / unitWidth(work);
}
pub fn unitsDown(work: *const Work) u32 {
    return (work.height + unitHeight(work) - 1) / unitHeight(work);
}

/// How big a component's plane has to be: whole units, since the last
/// unit of a row is unpacked whether or not the picture reaches the end
/// of it.
pub fn planeStride(work: *const Work, component: *const Component) u32 {
    return unitsAcross(work) * component.across * 8;
}
pub fn planeLines(work: *const Work, component: *const Component) u32 {
    return unitsDown(work) * component.down * 8;
}

// --- the scan ---------------------------------------------------------------

/// The scan's codes, read a bit at a time, high bit first.
const Bits = struct {
    from: []const u8,
    at: usize,
    /// The bits of the current byte that are left, and how many.
    held: u32 = 0,
    count: u5 = 0,
    /// A marker was met: the rest of the scan is zeroes, so that a file
    /// that stops early leaves what it did say.
    ended: bool = false,

    fn takeBit(self: *Bits) u32 {
        if (self.count == 0) {
            if (self.ended or self.at >= self.from.len) {
                self.ended = true;
                return 0;
            }
            const byte = self.from[self.at];
            if (byte == 0xFF) {
                // 0xFF 0x00 is a 0xFF of the scan's own; anything else
                // is a marker, and the codes stop in front of it. The
                // marker itself is left where it is, for `restart` to
                // find or for the picture to end on.
                const next: u8 = if (self.at + 1 < self.from.len) self.from[self.at + 1] else M_EOI;
                if (next != 0) {
                    self.ended = true;
                    return 0;
                }
                self.at += 1;
            }
            self.at += 1;
            self.held = byte;
            self.count = 8;
        }
        self.count -= 1;
        return (self.held >> @truncate(self.count)) & 1;
    }

    fn take(self: *Bits, bits: u5) u32 {
        var value: u32 = 0;
        var i: u5 = 0;
        while (i < bits) : (i += 1) value = value << 1 | self.takeBit();
        return value;
    }

    /// The next symbol of a code, high bit first: for each length in
    /// turn, the codes of that length are a run of numbers.
    fn takeSymbol(self: *Bits, table: *const Huffman) Error!u8 {
        var value: u32 = 0;
        var first: u32 = 0;
        var index: u32 = 0;
        var length: usize = 1;
        while (length <= 16) : (length += 1) {
            value = value << 1 | self.takeBit();
            const count = table.count[length];
            if (value - first < count) return table.symbol[index + (value - first)];
            index += count;
            first = (first + count) << 1;
        }
        return Error.Corrupt;
    }

    /// The next byte boundary, for a stream starting again.
    fn toByte(self: *Bits) void {
        self.count = 0;
    }

    /// Past the marker that says the codes start again here.
    fn restart(self: *Bits) void {
        self.toByte();
        while (self.at + 1 < self.from.len) {
            if (self.from[self.at] == 0xFF and self.from[self.at + 1] >= M_RST0 and
                self.from[self.at + 1] <= M_RST7)
            {
                self.at += 2;
                self.ended = false;
                return;
            }
            self.at += 1;
        }
        self.ended = true;
    }
};

/// A number written as how many bits it takes and then those bits: the
/// lower half of the range stands for the negatives.
fn extend(value: u32, bits: u5) i32 {
    if (bits == 0) return 0;
    const signed: i32 = @bitCast(value);
    if (value < (@as(u32, 1) << (bits - 1))) {
        return signed - (@as(i32, 1) << bits) + 1;
    }
    return signed;
}

/// The whole scan unpacked into the components' planes.
pub fn readScan(file: []const u8, work: *Work) Error!void {
    var bits = Bits{ .from = file, .at = work.scan_at };
    const across = unitsAcross(work);
    const down = unitsDown(work);
    var since_restart: u32 = 0;
    var unit_y: u32 = 0;
    while (unit_y < down) : (unit_y += 1) {
        var unit_x: u32 = 0;
        while (unit_x < across) : (unit_x += 1) {
            if (work.restart != 0 and since_restart == work.restart) {
                bits.restart();
                since_restart = 0;
                for (work.component[0..work.count]) |*component| component.predicted = 0;
            }
            for (work.component[0..work.count]) |*component| {
                var y: u32 = 0;
                while (y < component.down) : (y += 1) {
                    var x: u32 = 0;
                    while (x < component.across) : (x += 1) {
                        try readBlock(&bits, work, component, unit_x * component.across + x, unit_y * component.down + y);
                    }
                }
            }
            since_restart += 1;
        }
    }
}

/// One block read, undone by its table, transformed and written into its
/// component's plane at (`block_x`, `block_y`) blocks from the corner.
fn readBlock(bits: *Bits, work: *Work, component: *Component, block_x: u32, block_y: u32) Error!void {
    const numbers = &work.block;
    @memset(numbers, 0);
    const quant = &work.quant[component.quant];

    // The flat number, as a difference from the block before it.
    const size = try bits.takeSymbol(&work.dc[component.dc_table]);
    if (size > 16) return Error.Corrupt;
    component.predicted += extend(bits.take(@truncate(size)), @truncate(size));
    numbers[0] = component.predicted * quant[0];

    // The rest, as runs of nothing and a number.
    var k: usize = 1;
    while (k < 64) {
        const symbol = try bits.takeSymbol(&work.ac[component.ac_table]);
        const run = symbol >> 4;
        const width = symbol & 0x0F;
        if (width == 0) {
            // Sixteen of nothing, or nothing at all to the end.
            if (run != 15) break;
            k += 16;
            continue;
        }
        k += run;
        if (k >= 64) break;
        numbers[zigzag[k]] = extend(bits.take(@truncate(width)), @truncate(width)) * quant[k];
        k += 1;
    }

    const at = block_y * 8 * component.stride + block_x * 8;
    if (at + 7 * component.stride + 8 > component.stride * component.lines) return;
    idct.block(numbers, component.plane + at, component.stride);
}

// --- what the planes make ---------------------------------------------------

/// Red, green and blue from brightness and the two colour differences,
/// in sixteenths of a thousandth so that no division is needed.
pub fn toRGB(y: u8, cb: u8, cr: u8, into: []u8) void {
    const bright: i32 = @as(i32, y) << 16;
    const blue_diff: i32 = @as(i32, cb) - 128;
    const red_diff: i32 = @as(i32, cr) - 128;
    into[0] = idct.clamp((bright + 91881 * red_diff + 32768) >> 16);
    into[1] = idct.clamp((bright - 22554 * blue_diff - 46802 * red_diff + 32768) >> 16);
    into[2] = idct.clamp((bright + 116130 * blue_diff + 32768) >> 16);
}

const std = @import("std");
const testing = std.testing;

test "a code table read back" {
    var table = Huffman{};
    // One code of two bits, two of three.
    var body: [16 + 3]u8 = @splat(0);
    body[1] = 1;
    body[2] = 2;
    body[16] = 7;
    body[17] = 8;
    body[18] = 9;
    try testing.expectEqual(@as(usize, 19), try table.read(&body));
    try testing.expectEqual(@as(u16, 1), table.count[2]);
    try testing.expectEqual(@as(u16, 2), table.count[3]);
    try testing.expectEqual(@as(u8, 9), table.symbol[2]);
}

test "a number written as its width comes back with its sign" {
    try testing.expectEqual(@as(i32, 0), extend(0, 0));
    // Three bits: 0 to 3 are the negatives -7 to -4, 4 to 7 are 4 to 7.
    try testing.expectEqual(@as(i32, -7), extend(0, 3));
    try testing.expectEqual(@as(i32, -4), extend(3, 3));
    try testing.expectEqual(@as(i32, 4), extend(4, 3));
    try testing.expectEqual(@as(i32, 7), extend(7, 3));
}

test "brightness alone is grey" {
    var into: [3]u8 = undefined;
    toRGB(128, 128, 128, &into);
    try testing.expectEqualSlices(u8, &.{ 128, 128, 128 }, &into);
    toRGB(0, 128, 128, &into);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, &into);
    toRGB(255, 128, 128, &into);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255 }, &into);
}

test "what is not a JPEG says so" {
    var work = Work{};
    const file = [_]u8{ 0xFF, 0xD9, 0, 0 };
    try testing.expectError(Error.NotJpeg, readHeaders(&file, &work));
}

test "a picture written in passes is refused rather than half read" {
    var work = Work{};
    const file = [_]u8{ 0xFF, M_SOI, 0xFF, M_SOF2, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0 };
    try testing.expectError(Error.Unsupported, readHeaders(&file, &work));
}
