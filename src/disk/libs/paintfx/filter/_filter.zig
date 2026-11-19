// SPDX-License-Identifier: MIT
//! The blur BlurPixels and SharpenPixels share: three box passes across
//! each row, then three down each column - close to a Gaussian whose
//! spread is about the radius.
//!
//! A row is read into a line of weighted colours (`_pixels.Weighed`),
//! passed three times between two lines - each pass the average of the
//! `2r + 1` around a place, the edge pixels standing in for what lies
//! past the edge - and written into `into` weighted (`packWeighed`). The
//! columns are then read from there, passed the same way, and written as
//! plain pixels. A row or a column is read whole before it is written,
//! so `from` may be `into`.

const sdk = @import("sdk");
const exec = sdk.exec;
const paintfx = sdk.paintfx;
const ExecBase = sdk.interface.exec.ExecBase;
const _pixels = @import("../pixels/_pixels.zig");
const Weighed = _pixels.Weighed;

/// `from` blurred over `radius` into `into`, the same size; false when
/// there is no memory for the lines.
pub fn blur(sys: *ExecBase, from: *const paintfx.Pixels, into: *const paintfx.Pixels, radius: u32) bool {
    const width = from.width;
    const height = from.height;
    const longest: usize = @max(width, height);
    const memory = sys.AllocVec(2 * longest * @sizeOf(Weighed), exec.MEMF_ANY) orelse return false;
    defer sys.FreeVec(memory);
    const lines: [*]Weighed = @ptrCast(@alignCast(memory));
    const line = lines[0..longest];
    const other = lines[longest .. 2 * longest];

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const source = _pixels.row(from, y);
        for (line[0..width], source) |*place, pixel| place.* = _pixels.weighed(pixel);
        passes(line[0..width], other[0..width], radius);
        for (_pixels.row(into, y), line[0..width]) |*pixel, colour| pixel.* = _pixels.packWeighed(colour);
    }
    var x: u32 = 0;
    while (x < width) : (x += 1) {
        var down: u32 = 0;
        while (down < height) : (down += 1) line[down] = _pixels.unpackWeighed(_pixels.row(into, down)[x]);
        passes(line[0..height], other[0..height], radius);
        down = 0;
        while (down < height) : (down += 1) _pixels.row(into, down)[x] = _pixels.unweighed(line[down]);
    }
    return true;
}

/// Three box passes over `line`, `spare` between them; the result ends
/// in `line`.
fn passes(line: []Weighed, spare: []Weighed, radius: u32) void {
    if (radius == 0 or line.len < 2) return;
    box(line, spare, radius);
    box(spare, line, radius);
    box(line, spare, radius);
    @memcpy(line, spare);
}

/// Each place of `into` the average of the `2 radius + 1` places of
/// `from` round it, the ends standing in past the ends.
fn box(from: []const Weighed, into: []Weighed, radius: u32) void {
    const last: i64 = @intCast(from.len - 1);
    const span: i64 = @intCast(radius);
    const count: u64 = 2 * @as(u64, radius) + 1;
    // Dividing by the count as a multiplication, 8.24.
    const share: u64 = ((1 << 24) + count / 2) / count;
    var sum = [4]u64{ 0, 0, 0, 0 };
    var at: i64 = -span;
    while (at <= span) : (at += 1) add(&sum, from[clamp(at, last)]);
    for (into, 0..) |*place, index| {
        inline for (0..4) |channel| place[channel] = @intCast((sum[channel] * share + (1 << 23)) >> 24);
        const here: i64 = @intCast(index);
        add(&sum, from[clamp(here + span + 1, last)]);
        const gone = from[clamp(here - span, last)];
        inline for (0..4) |channel| sum[channel] -= gone[channel];
    }
}

fn add(sum: *[4]u64, colour: Weighed) void {
    inline for (0..4) |channel| sum[channel] += colour[channel];
}

fn clamp(at: i64, last: i64) usize {
    return @intCast(@max(0, @min(last, at)));
}
