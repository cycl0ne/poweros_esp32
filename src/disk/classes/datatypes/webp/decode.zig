// SPDX-License-Identifier: MIT
//! What a WebP file says (RFC 9649), and the pixels its pictures unpack
//! into.
//!
//! A file is a RIFF file of the form `WEBP`: chunks, each a name of four
//! letters, a length and the bytes, padded to an even length. **The
//! simple forms** are one chunk: `VP8 ` a lossy picture (lossy.zig),
//! `VP8L` a lossless one (lossless.zig). **The extended form** begins
//! with `VP8X` - what the file has, and the canvas's size - and then
//! holds a picture with the coverage of a lossy one beside it (`ALPH`,
//! alpha.zig), or an animation: `ANIM` and a frame after another
//! (`ANMF`), each its place on the canvas, how long it stays, whether it
//! is laid over what is there or replaces it, and whether its area is
//! cleared after it. A colour profile, Exif and XMP chunks, and chunks
//! of names nothing knows, are passed over.
//!
//! Pixels are alpha, red, green and blue in a word (0xAARRGGBB), as the
//! lossless stream has them.

const lossless = @import("lossless.zig");
const lossy = @import("lossy.zig");
const alpha = @import("alpha.zig");

pub const Env = lossless.Env;
pub const Error = lossless.Error;
pub const Lossy = lossy;
pub const Lossless = lossless;
/// A lossy picture's coverage from its chunk (alpha.zig).
pub const alphaOf = alpha.decode;

/// One picture's chunks: its stream, and a lossy one's coverage.
pub const Image = struct {
    data: []const u8,
    lossless: bool,
    alpha: ?[]const u8 = null,
};

/// What a file is.
pub const Info = struct {
    width: u32,
    height: u32,
    /// Some pixel may be less than opaque.
    alpha: bool = false,
    animated: bool = false,
    /// A still picture's chunks.
    image: ?Image = null,
    /// An animation's: where its first frame is, and how often it plays
    /// (0 for ever).
    frames_at: usize = 0,
    loops: u32 = 0,
};

/// One frame of an animation.
pub const Frame = struct {
    left: u32,
    top: u32,
    width: u32,
    height: u32,
    /// How long it stays, in thousandths of a second.
    duration: u32,
    /// Laid over what is there by its coverage, rather than replacing
    /// it.
    blend: bool,
    /// Its area cleared before the next frame.
    dispose: bool,
    /// Its picture says it has coverage: a lossy one's chunk, or the
    /// lossless stream's hint.
    has_alpha: bool,
    image: Image,
    /// Where the chunk after it begins.
    next_at: usize,
};

/// A chunk: its name, its bytes, and where the next begins.
const Chunk = struct {
    name: [4]u8,
    data: []const u8,
    next: usize,
};

fn le24(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | @as(u32, bytes[1]) << 8 | @as(u32, bytes[2]) << 16;
}

fn le32(bytes: []const u8) u32 {
    return le24(bytes) | @as(u32, bytes[3]) << 24;
}

/// The chunk at `at` of the bytes up to `end`, or null past them.
fn chunkAt(bytes: []const u8, at: usize, end: usize) Error!?Chunk {
    if (at + 8 > end) return null;
    const length = le32(bytes[at + 4 ..]);
    if (length > end - at - 8) return Error.Corrupt;
    return .{
        .name = bytes[at..][0..4].*,
        .data = bytes[at + 8 ..][0..length],
        .next = at + 8 + length + (length & 1),
    };
}

fn named(chunk: Chunk, name: *const [4]u8) bool {
    return sameName(&chunk.name, name);
}

fn sameName(first: *const [4]u8, second: *const [4]u8) bool {
    return @as(u32, @bitCast(first.*)) == @as(u32, @bitCast(second.*));
}

/// Where the file's chunks end: what its RIFF header says, or the
/// file's end when that is sooner.
fn chunksEnd(file: []const u8) Error!usize {
    if (file.len < 12) return Error.Corrupt;
    if (!sameName(file[0..4], "RIFF") or !sameName(file[8..12], "WEBP")) return Error.Corrupt;
    const riff_length = le32(file[4..]);
    return @min(file.len, @as(usize, riff_length) + 8);
}

/// Whether the bytes begin as a WebP file does.
pub fn isWebp(file: []const u8) bool {
    _ = chunksEnd(file) catch return false;
    return true;
}

/// How many of a file's first bytes say whether it is an animation.
pub const animation_test_bytes = 21;

/// Whether a file's first bytes say it is an animation: an extended
/// file whose `VP8X` says so.
pub fn isAnimation(start: []const u8) bool {
    if (start.len < animation_test_bytes or !isWebp(start)) return false;
    if (!sameName(start[12..16], "VP8X")) return false;
    return start[20] & 0x02 != 0;
}

/// The size a picture's stream says.
fn sizeOfImage(image: Image) Error![2]u32 {
    if (image.lossless) {
        const header = try lossless.readHeader(image.data);
        return .{ header.width, header.height };
    }
    return lossy.sizeOf(image.data) orelse Error.Corrupt;
}

/// A picture's chunks from `at` to `end`: its coverage, if lossy, and
/// its stream; what else is there is passed over.
fn imageAt(bytes: []const u8, at: usize, end: usize) Error!?Image {
    var place = at;
    var coverage: ?[]const u8 = null;
    while (try chunkAt(bytes, place, end)) |chunk| {
        if (named(chunk, "ALPH")) {
            coverage = chunk.data;
        } else if (named(chunk, "VP8 ")) {
            return .{ .data = chunk.data, .lossless = false, .alpha = coverage };
        } else if (named(chunk, "VP8L")) {
            return .{ .data = chunk.data, .lossless = true };
        }
        place = chunk.next;
    }
    return null;
}

/// What the file is: its size, and its picture or where its frames are.
pub fn readInfo(file: []const u8) Error!Info {
    const end = try chunksEnd(file);
    const first = try chunkAt(file, 12, end) orelse return Error.Corrupt;
    if (named(first, "VP8 ") or named(first, "VP8L")) {
        const image = Image{ .data = first.data, .lossless = named(first, "VP8L") };
        const size = try sizeOfImage(image);
        const hinted = image.lossless and (try lossless.readHeader(image.data)).alpha;
        return .{ .width = size[0], .height = size[1], .alpha = hinted, .image = image };
    }
    if (!named(first, "VP8X") or first.data.len < 10) return Error.Corrupt;
    const flags = first.data[0];
    var info = Info{
        .width = le24(first.data[4..]) + 1,
        .height = le24(first.data[7..]) + 1,
        .alpha = flags & 0x10 != 0,
        .animated = flags & 0x02 != 0,
    };
    if (info.animated) {
        var at = first.next;
        while (try chunkAt(file, at, end)) |chunk| {
            if (named(chunk, "ANIM") and chunk.data.len >= 6) {
                info.loops = @as(u32, chunk.data[4]) | @as(u32, chunk.data[5]) << 8;
            } else if (named(chunk, "ANMF")) {
                info.frames_at = at;
                return info;
            }
            at = chunk.next;
        }
        return Error.Corrupt;
    }
    const image = try imageAt(file, first.next, end) orelse return Error.Corrupt;
    const size = try sizeOfImage(image);
    if (size[0] != info.width or size[1] != info.height) return Error.Corrupt;
    if (image.alpha != null) info.alpha = true;
    info.image = image;
    return info;
}

/// The frame whose chunk is at or after `at`, or null when there are no
/// more.
pub fn readFrame(file: []const u8, info: *const Info, at: usize) Error!?Frame {
    const end = try chunksEnd(file);
    var place = at;
    while (try chunkAt(file, place, end)) |chunk| {
        if (!named(chunk, "ANMF")) {
            place = chunk.next;
            continue;
        }
        const data = chunk.data;
        if (data.len < 16) return Error.Corrupt;
        const start = @intFromPtr(data.ptr) - @intFromPtr(file.ptr);
        const image = try imageAt(file, start + 16, start + data.len) orelse return Error.Corrupt;
        const frame = Frame{
            .left = le24(data[0..]) * 2,
            .top = le24(data[3..]) * 2,
            .width = le24(data[6..]) + 1,
            .height = le24(data[9..]) + 1,
            .duration = le24(data[12..]),
            .blend = data[15] & 0x02 == 0,
            .dispose = data[15] & 0x01 != 0,
            .has_alpha = image.alpha != null or (image.lossless and (try lossless.readHeader(image.data)).alpha),
            .image = image,
            .next_at = chunk.next,
        };
        if (frame.left + frame.width > info.width or frame.top + frame.height > info.height) return Error.Corrupt;
        const size = try sizeOfImage(image);
        if (size[0] != frame.width or size[1] != frame.height) return Error.Corrupt;
        return frame;
    }
    return null;
}

/// How many frames an animation has, `most` at the most.
pub fn countFrames(file: []const u8, info: *const Info, most: u32) Error!u32 {
    var count: u32 = 0;
    var at = info.frames_at;
    while (count < most) {
        const frame = try readFrame(file, info, at) orelse break;
        count += 1;
        at = frame.next_at;
    }
    return count;
}

/// A picture of `width` by `height` unpacked into `pixels`, a word a
/// pixel.
pub fn decodeImage(env: Env, image: Image, width: u32, height: u32, pixels: []u32) Error!void {
    const total = @as(usize, width) * height;
    if (pixels.len < total) return Error.NoMemory;
    if (image.lossless) {
        const header = try lossless.decode(env, image.data, pixels);
        if (header.width != width or header.height != height) return Error.Corrupt;
        return;
    }
    var picture = try lossy.decode(env, image.data);
    defer picture.deinit();
    if (picture.width != width or picture.height != height) return Error.Corrupt;
    const bytes: [*]u8 = @ptrCast(pixels.ptr);
    for (0..height) |y| {
        const row = bytes + y * width * 4;
        lossy.row(&picture, @intCast(y), row);
        // The row as words: red, green, blue, coverage made 0xAARRGGBB.
        for (pixels[y * width ..][0..width], 0..) |*pixel, x| {
            const at = row + x * 4;
            pixel.* = 0xFF000000 | @as(u32, at[0]) << 16 | @as(u32, at[1]) << 8 | at[2];
        }
    }
    if (image.alpha) |chunk| {
        const coverage = env.slice(u8, total) orelse return Error.NoMemory;
        defer env.freeSlice(u8, coverage);
        // A broken coverage leaves the picture opaque, as it would be
        // without one.
        alpha.decode(env, chunk, width, height, coverage) catch return;
        for (pixels[0..total], coverage) |*pixel, value| pixel.* = (pixel.* & 0x00FFFFFF) | @as(u32, value) << 24;
    }
}

/// The canvas an animation's frames are laid on, one after another, and
/// what it keeps of the frame before.
///
/// Before a frame, the one before has its area cleared when it said so.
/// A frame is then put in its place, or laid over what is there by its
/// coverage. **A frame that starts afresh** - the first; one that covers
/// the whole canvas and replaces it or has no coverage; one after a
/// frame that cleared the whole canvas, or cleared its area after
/// starting afresh itself - clears the canvas and is put in its place,
/// and a frame is put in its place over the area the one before
/// cleared: what is under it there is nothing anyway, and this is where
/// the format's own decoder lays nothing over and so is followed, to
/// the last bit of a colour.
pub const Canvas = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    previous: ?Frame = null,
    previous_fresh: bool = false,

    /// Empty, as before the first frame.
    pub fn reset(canvas: *Canvas) void {
        @memset(canvas.pixels, 0);
        canvas.previous = null;
        canvas.previous_fresh = false;
    }

    fn covers(canvas: *const Canvas, frame: *const Frame) bool {
        return frame.width == canvas.width and frame.height == canvas.height;
    }

    /// A frame's pixels laid on, after the frame before is done with.
    pub fn add(canvas: *Canvas, frame: *const Frame, pixels: []const u32) void {
        const fresh = if (canvas.previous) |previous|
            ((!frame.has_alpha or !frame.blend) and canvas.covers(frame)) or
                (previous.dispose and (canvas.covers(&previous) or canvas.previous_fresh))
        else
            true;
        if (fresh) {
            @memset(canvas.pixels, 0);
        } else if (canvas.previous) |previous| {
            if (previous.dispose) canvas.clearArea(&previous);
        }
        const cleared: ?Frame = if (canvas.previous) |previous| (if (previous.dispose) previous else null) else null;
        for (0..frame.height) |row| {
            const y = frame.top + @as(u32, @intCast(row));
            const into = canvas.pixels[@as(usize, y) * canvas.width + frame.left ..][0..frame.width];
            const from = pixels[row * frame.width ..][0..frame.width];
            if (fresh or !frame.blend) {
                @memcpy(into, from);
                continue;
            }
            for (into, from, 0..) |*under, over, column| {
                const x = frame.left + @as(u32, @intCast(column));
                const inside = if (cleared) |area|
                    x >= area.left and x < area.left + area.width and y >= area.top and y < area.top + area.height
                else
                    false;
                under.* = if (inside) over else blend(over, under.*);
            }
        }
        canvas.previous = frame.*;
        canvas.previous_fresh = fresh;
    }

    fn clearArea(canvas: *Canvas, frame: *const Frame) void {
        for (0..frame.height) |row| {
            @memset(canvas.pixels[(frame.top + row) * canvas.width + frame.left ..][0..frame.width], 0);
        }
    }
};

/// One pixel laid over another by its coverage, neither premultiplied:
/// the coverage they make together, and each colour the mix of the two
/// by what each gives - in the integer steps the format's own decoder
/// takes, which leaves an opaque pixel as it is.
fn blend(over: u32, under: u32) u32 {
    const over_alpha = over >> 24;
    if (over_alpha == 0xFF) return over;
    if (over_alpha == 0) return under;
    const under_alpha = under >> 24;
    const under_share = (under_alpha * (256 - over_alpha)) >> 8;
    const together = over_alpha + under_share;
    const scale = (@as(u32, 1) << 24) / together;
    var result: u32 = together << 24;
    inline for (.{ 0, 8, 16 }) |shift| {
        const top = (over >> shift) & 0xFF;
        const bottom = (under >> shift) & 0xFF;
        const mixed = (top * over_alpha + bottom * under_share) * scale >> 24;
        result |= @as(u32, @intCast(mixed & 0xFF)) << shift;
    }
    return result;
}

const std = @import("std");
const testing = std.testing;

test {
    _ = lossless;
    _ = lossy;
    _ = alpha;
    _ = @import("tests/files.zig");
}

test "what is not a WebP says so" {
    try testing.expectError(Error.Corrupt, readInfo("RIFF\x04\x00\x00\x00WAVE"));
    try testing.expect(!isWebp("GIF89a"));
}

test "a lossless file's size from its one chunk" {
    const bits: u32 = 9 | (4 << 14);
    const file = "RIFF\x12\x00\x00\x00WEBPVP8L\x05\x00\x00\x00" ++
        [_]u8{ lossless.signature, @truncate(bits), @truncate(bits >> 8), @truncate(bits >> 16), @truncate(bits >> 24) } ++ "\x00";
    const info = try readInfo(file);
    try testing.expectEqual(@as(u32, 10), info.width);
    try testing.expectEqual(@as(u32, 5), info.height);
    try testing.expect(info.image.?.lossless);
    try testing.expect(!info.animated);
}

test "a pixel laid over another" {
    // Opaque over anything is itself; nothing over anything leaves it.
    try testing.expectEqual(@as(u32, 0xFF102030), blend(0xFF102030, 0x80FFFFFF));
    try testing.expectEqual(@as(u32, 0x80FFFFFF), blend(0x00102030, 0x80FFFFFF));
    // Half over nothing stays half; half over opaque is opaque, between.
    try testing.expectEqual(@as(u32, 0x80FF0000), blend(0x80FF0000, 0x00000000));
    const mixed = blend(0x80FF0000, 0xFF0000FF);
    try testing.expectEqual(@as(u32, 0xFF), mixed >> 24);
    try testing.expect((mixed >> 16) & 0xFF > 0x70 and (mixed >> 16) & 0xFF < 0x90);
}
