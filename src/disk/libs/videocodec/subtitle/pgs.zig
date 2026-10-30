// SPDX-License-Identifier: MIT
//! Subtitles as pictures: a Blu-ray's Presentation Graphic Stream (PGS),
//! as Matroska keeps it (S_HDMV/PGS) - each block one display set, its
//! segments one after another: a type, a 16-bit length, the segment.
//!
//! A display set is a presentation (0x16) - the canvas's size, which
//! objects are placed where, cropped or whole, with which palette -
//! the windows (0x17), palettes (0x14), objects (0x15) and an end
//! (0x80). The objects and palettes hold from set to set until an epoch
//! starts: a set may only place again what an earlier one sent, or send
//! a palette alone. A set that places nothing clears the screen.
//!
//! An object is run-length coded, a line at a time: a byte not 0 is a
//! pixel of that colour; 0 starts a code - 0 again ends the line, else
//! two bits say what follows: `00LLLLLL` L pixels of colour 0, `01LLLLLL
//! LLLLLLLL` as many, `10LLLLLL CC` L of colour C, `11LLLLLL LLLLLLLL CC`.
//! A palette's entries are Y, Cr, Cb in studio range - BT.709 above a
//! canvas 576 lines high, BT.601 below, as FFmpeg reads them - and alpha.
//! An object larger than a segment comes in several, the first marked so
//! and carrying the whole's length, the last marked too.
//!
//! What is drawn is the box around the objects placed, 0xAARRGGBB, alpha
//! 0 between them.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

pub const max_objects = 8;
const max_placed = 4;

/// An object as its segments sent it: its size and its coded lines.
const Object = struct {
    id: u16 = 0,
    used: bool = false,
    width: u16 = 0,
    height: u16 = 0,
    data: ?[*]u8 = null,
    capacity: usize = 0,
    length: usize = 0,
};

/// Where a presentation places an object, and what of it.
const Placed = struct {
    object: u16 = 0,
    x: u16 = 0,
    y: u16 = 0,
    cropped: bool = false,
    crop_x: u16 = 0,
    crop_y: u16 = 0,
    crop_width: u16 = 0,
    crop_height: u16 = 0,
};

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const State = struct {
    palettes: [8][256]u32 = @splat(@splat(0)),
    objects: [max_objects]Object = @splat(.{}),
    /// The canvas the objects are placed on: the film's size, as the disc
    /// was made.
    canvas_width: u32 = 0,
    canvas_height: u32 = 0,
    /// The presentation of the set being read.
    palette: u8 = 0,
    placed: [max_placed]Placed = @splat(.{}),
    placed_count: u32 = 0,
    presented: bool = false,
};

/// What a display set came to.
pub const Outcome = enum {
    /// Not a whole set.
    nothing,
    /// Nothing is shown from it on.
    clear,
    /// A picture: `bounds` and `draw` make it.
    picture,
};

/// A packet's segments read: what its display set comes to.
pub fn read(state: *State, sys: *ExecBase, data: []const u8) Outcome {
    var outcome: Outcome = .nothing;
    var at: usize = 0;
    while (at + 3 <= data.len) {
        const kind = data[at];
        const size = be16(data[at + 1 ..]);
        const body_end = @min(at + 3 + size, data.len);
        const body = data[at + 3 .. body_end];
        at = body_end;
        switch (kind) {
            0x16 => presentation(state, body),
            0x14 => palette(state, body),
            0x15 => object(state, sys, body),
            0x80 => if (state.presented) {
                state.presented = false;
                outcome = if (state.placed_count == 0) .clear else .picture;
            },
            else => {},
        }
    }
    return outcome;
}

fn presentation(state: *State, body: []const u8) void {
    if (body.len < 11) return;
    state.canvas_width = be16(body[0..]);
    state.canvas_height = be16(body[2..]);
    // An epoch starts afresh: nothing an earlier set sent holds.
    if (body[7] & 0xC0 == 0x80) reset(state);
    state.palette = body[9] & 7;
    state.placed_count = 0;
    state.presented = true;
    var at: usize = 11;
    for (0..body[10]) |_| {
        if (at + 8 > body.len) break;
        var placed = Placed{
            .object = be16(body[at..]),
            .x = be16(body[at + 4 ..]),
            .y = be16(body[at + 6 ..]),
            .cropped = body[at + 3] & 0x80 != 0,
        };
        at += 8;
        if (placed.cropped) {
            if (at + 8 > body.len) break;
            placed.crop_x = be16(body[at..]);
            placed.crop_y = be16(body[at + 2 ..]);
            placed.crop_width = be16(body[at + 4 ..]);
            placed.crop_height = be16(body[at + 6 ..]);
            at += 8;
        }
        if (state.placed_count < max_placed) {
            state.placed[state.placed_count] = placed;
            state.placed_count += 1;
        }
    }
}

fn palette(state: *State, body: []const u8) void {
    if (body.len < 2) return;
    const colours = &state.palettes[body[0] & 7];
    const bt709 = state.canvas_height > 576;
    var at: usize = 2;
    while (at + 5 <= body.len) : (at += 5) {
        colours[body[at]] = colour(body[at + 1], body[at + 2], body[at + 3], body[at + 4], bt709);
    }
}

fn object(state: *State, sys: *ExecBase, body: []const u8) void {
    if (body.len < 4) return;
    const id = be16(body[0..]);
    const first = body[3] & 0x80 != 0;
    const slot = find(state, id) orelse return;
    var rest = body[4..];
    if (first) {
        if (rest.len < 7) return;
        const whole = (@as(usize, rest[0]) << 16 | @as(usize, rest[1]) << 8 | rest[2]) -| 4;
        slot.width = be16(rest[3..]);
        slot.height = be16(rest[5..]);
        rest = rest[7..];
        slot.length = 0;
        if (whole > slot.capacity) {
            if (slot.data) |old| sys.FreeVec(old);
            slot.data = null;
            slot.capacity = 0;
            const memory = sys.AllocVec(whole, exec.MEMF_ANY) orelse return;
            slot.data = @ptrCast(memory);
            slot.capacity = whole;
        }
        slot.used = true;
    }
    if (!slot.used) return;
    const data = slot.data orelse return;
    const take = @min(rest.len, slot.capacity - slot.length);
    @memcpy(data[slot.length..][0..take], rest[0..take]);
    slot.length += take;
}

/// The object `id`'s slot: its own, or a free one taken for it.
fn find(state: *State, id: u16) ?*Object {
    for (&state.objects) |*slot| {
        if (slot.used and slot.id == id) return slot;
    }
    for (&state.objects) |*slot| {
        if (!slot.used) {
            slot.id = id;
            slot.length = 0;
            return slot;
        }
    }
    return null;
}

/// The objects and palettes dropped - their memory kept for the next.
pub fn reset(state: *State) void {
    for (&state.objects) |*slot| {
        slot.used = false;
        slot.length = 0;
    }
    state.palettes = @splat(@splat(0));
    state.placed_count = 0;
    state.presented = false;
}

/// Everything given back.
pub fn free(state: *State, sys: *ExecBase) void {
    for (&state.objects) |*slot| {
        if (slot.data) |data| sys.FreeVec(data);
        slot.* = .{};
    }
}

/// The box on the canvas the placed objects cover; null when they cover
/// nothing.
pub fn bounds(state: *const State) ?Rect {
    var left: u32 = ~@as(u32, 0);
    var top: u32 = ~@as(u32, 0);
    var right: u32 = 0;
    var bottom: u32 = 0;
    for (state.placed[0..state.placed_count]) |*placed| {
        const area = placedArea(state, placed) orelse continue;
        left = @min(left, placed.x);
        top = @min(top, placed.y);
        right = @max(right, placed.x + area.width);
        bottom = @max(bottom, placed.y + area.height);
    }
    if (right <= left or bottom <= top) return null;
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

/// The part of a placed object that shows: its crop within it, or all.
fn placedArea(state: *const State, placed: *const Placed) ?Rect {
    const slot = for (&state.objects) |*slot| {
        if (slot.used and slot.id == placed.object) break slot;
    } else return null;
    if (slot.width == 0 or slot.height == 0 or slot.data == null) return null;
    if (!placed.cropped) return .{ .x = 0, .y = 0, .width = slot.width, .height = slot.height };
    const x = @min(placed.crop_x, slot.width);
    const y = @min(placed.crop_y, slot.height);
    return .{
        .x = x,
        .y = y,
        .width = @min(placed.crop_width, slot.width - x),
        .height = @min(placed.crop_height, slot.height - y),
    };
}

/// The placed objects drawn into `pixels`, the box `box` of the canvas
/// (from `bounds`), `box.width` a row; what they leave is left as it was.
pub fn draw(state: *const State, pixels: []u32, box: Rect) void {
    const colours = &state.palettes[state.palette];
    for (state.placed[0..state.placed_count]) |*placed| {
        const area = placedArea(state, placed) orelse continue;
        const slot = for (&state.objects) |*slot| {
            if (slot.used and slot.id == placed.object) break slot;
        } else continue;
        const offset = (placed.y - box.y) * box.width + (placed.x - box.x);
        drawObject(slot.data.?[0..slot.length], slot.width, slot.height, colours, pixels[offset..], box.width, area);
    }
}

/// An object's coded lines drawn: the part `area` of it into `out`, its
/// top left at `out[0]`, `stride` pixels a row.
pub fn drawObject(coded: []const u8, width: u32, height: u32, colours: *const [256]u32, out: []u32, stride: usize, area: Rect) void {
    var at: usize = 0;
    var x: u32 = 0;
    var y: u32 = 0;
    while (at < coded.len and y < height) {
        var run: u32 = 1;
        var index: u8 = coded[at];
        at += 1;
        if (index == 0) {
            if (at >= coded.len) break;
            const code = coded[at];
            at += 1;
            if (code == 0) {
                x = 0;
                y += 1;
                continue;
            }
            run = code & 0x3F;
            if (code & 0x40 != 0) {
                if (at >= coded.len) break;
                run = run << 8 | coded[at];
                at += 1;
            }
            if (code & 0x80 != 0) {
                if (at >= coded.len) break;
                index = coded[at];
                at += 1;
            }
        }
        // The run, as much of it as lies in the line and the area.
        if (y >= area.y and y < area.y + area.height) {
            const from = @max(x, area.x);
            const to = @min(@min(x + run, width), area.x + area.width);
            if (from < to) {
                const row = (y - area.y) * stride;
                const value = colours[index];
                for (from..to) |column| {
                    const place = row + (column - area.x);
                    if (place < out.len) out[place] = value;
                }
            }
        }
        x +|= run;
    }
}

/// A palette entry, studio range, as 0xAARRGGBB.
pub fn colour(y: u8, cr: u8, cb: u8, alpha: u8, bt709: bool) u32 {
    // 16.16: 255 / 219 for Y, and the matrix's terms for Cr and Cb.
    const luma = (@as(i32, y) - 16) * 76309;
    const v = @as(i32, cr) - 128;
    const u = @as(i32, cb) - 128;
    const terms: [4]i32 = if (bt709) .{ 117489, 13975, 34925, 138438 } else .{ 104597, 25675, 53279, 132201 };
    const r = luma + terms[0] * v;
    const g = luma - terms[1] * u - terms[2] * v;
    const b = luma + terms[3] * u;
    return @as(u32, alpha) << 24 | @as(u32, clamp(r)) << 16 | @as(u32, clamp(g)) << 8 | clamp(b);
}

fn clamp(value: i32) u8 {
    return @intCast(@min(@max((value + 32768) >> 16, 0), 255));
}

fn be16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

test "a palette's studio-range colours, as BT.601 and BT.709 make them" {
    // White, black and grey are the same in both; alpha as it is.
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), colour(235, 128, 128, 255, true));
    try testing.expectEqual(@as(u32, 0x80000000), colour(16, 128, 128, 128, false));
    try testing.expectEqual(@as(u32, 0x00808080), colour(126, 128, 128, 0, true));
    // BT.601's red (82, 240, 90) and BT.709's (63, 240, 102), within a step.
    const red601 = colour(82, 240, 90, 255, false);
    const red709 = colour(63, 240, 102, 255, true);
    for ([_]u32{ red601, red709 }) |red| {
        try testing.expect(red >> 16 & 0xFF >= 254);
        try testing.expect(red >> 8 & 0xFF <= 1);
        try testing.expect(red & 0xFF <= 1);
    }
}

test "an object's coded lines: each code, a line's end, a crop" {
    var colours: [256]u32 = @splat(0);
    colours[1] = 0xFF111111;
    colours[7] = 0xFF777777;
    colours[0] = 0x00000000;
    // A 6 x 3 object: 1 1, then 2 of colour 0, then 2 of 7 / 6 of 7 (long) / 4 of 0 (long) 7 7.
    const coded = [_]u8{
        1, 1,    0, 0x02, 0, 0x82, 7, 0,    0,
        0, 0xC0, 6, 7,    0, 0,    0, 0x40, 4,
        7, 7,    0, 0,
    };
    var out: [18]u32 = @splat(0xDEAD);
    drawObject(&coded, 6, 3, &colours, &out, 6, .{ .x = 0, .y = 0, .width = 6, .height = 3 });
    const want = [_]u32{
        0xFF111111, 0xFF111111, 0,          0,          0xFF777777, 0xFF777777,
        0xFF777777, 0xFF777777, 0xFF777777, 0xFF777777, 0xFF777777, 0xFF777777,
        0,          0,          0,          0,          0xFF777777, 0xFF777777,
    };
    try testing.expectEqualSlices(u32, &want, &out);

    // Its middle 2 x 2 from (3, 1).
    var part: [4]u32 = @splat(0xDEAD);
    drawObject(&coded, 6, 3, &colours, &part, 2, .{ .x = 3, .y = 1, .width = 2, .height = 2 });
    try testing.expectEqualSlices(u32, &[_]u32{ 0xFF777777, 0xFF777777, 0, 0xFF777777 }, &part);
}
