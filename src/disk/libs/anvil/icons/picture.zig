// SPDX-License-Identifier: MIT
//! An icon's picture as the desktop shows it: no larger than the icon
//! size, each way.
//!
//! A picture that fits is drawn as icon.library holds it. One that does
//! not is shrunk once - each pixel the average of those it covers, the
//! colour weighted by coverage so a soft edge stays soft - and the shrunk
//! copy is kept for as long as an icon shows it. Many files share one
//! default picture, so the copies are kept by the picture they came from
//! and counted: a drawer of files without icons shrinks the default
//! once.

const sdk = @import("sdk");
const exec = sdk.exec;
const icon = sdk.icon;
const ExecBase = sdk.interface.exec.ExecBase;

/// A width and a height.
pub const Size = struct { width: u32, height: u32 };

/// The size a picture `width` by `height` is shown at: itself when it
/// fits in `most` each way, else made smaller with its shape kept, at
/// least a pixel each way.
pub fn fitted(width: u32, height: u32, most: u32) Size {
    if (width <= most and height <= most) return .{ .width = width, .height = height };
    if (width >= height) {
        return .{ .width = most, .height = @max(1, height * most / width) };
    }
    return .{ .width = @max(1, width * most / height), .height = most };
}

/// `from`, `width` by `height` pixels of rgba32, shrunk to `to.width` by
/// `to.height` into `into`: each pixel the average of the pixels it
/// covers, red, green and blue weighted by their coverage.
pub fn shrink(from: []const u8, width: u32, height: u32, into: []u8, to: Size) void {
    var y: u32 = 0;
    while (y < to.height) : (y += 1) {
        const top = y * height / to.height;
        const bottom = @max(top + 1, (y + 1) * height / to.height);
        var x: u32 = 0;
        while (x < to.width) : (x += 1) {
            const left = x * width / to.width;
            const right = @max(left + 1, (x + 1) * width / to.width);
            var red: u32 = 0;
            var green: u32 = 0;
            var blue: u32 = 0;
            var cover: u32 = 0;
            var count: u32 = 0;
            var sy = top;
            while (sy < bottom) : (sy += 1) {
                var sx = left;
                while (sx < right) : (sx += 1) {
                    const at = (sy * width + sx) * 4;
                    const alpha: u32 = from[at + 3];
                    red += @as(u32, from[at]) * alpha;
                    green += @as(u32, from[at + 1]) * alpha;
                    blue += @as(u32, from[at + 2]) * alpha;
                    cover += alpha;
                    count += 1;
                }
            }
            const out = (y * to.width + x) * 4;
            into[out + 3] = @intCast(cover / count);
            if (cover == 0) {
                into[out] = 0;
                into[out + 1] = 0;
                into[out + 2] = 0;
            } else {
                into[out] = @intCast(red / cover);
                into[out + 1] = @intCast(green / cover);
                into[out + 2] = @intCast(blue / cover);
            }
        }
    }
}

/// A shrunk copy of a picture, kept while icons show it.
const Shrunk = struct {
    node: exec.Node = .{},
    source: *const icon.IconImage,
    size: Size,
    users: u32 = 0,
    /// The pixels, in the same block, after this.
    pixels: [*]u8,
};

/// The shrunk copies the desktop keeps: one per picture and size.
pub const Pictures = struct {
    list: exec.List = .{},

    pub fn init(pictures: *Pictures) void {
        pictures.list.init(.unknown);
    }

    /// The pixels of `source` shown at most `most` each way, and their
    /// size: the picture itself when it fits, else a shrunk copy shared
    /// with every icon that shows the same picture at the same size.
    /// Null without memory for a copy. Each answer is given back with
    /// `release`.
    pub fn obtain(pictures: *Pictures, sys: *ExecBase, source: *const icon.IconImage, most: u32) ?Shown {
        const size = fitted(source.width, source.height, most);
        if (size.width == source.width and size.height == source.height) {
            return .{ .pixels = source.pixels, .size = size, .shrunk = null };
        }
        var it = pictures.list.iterator();
        while (it.next()) |node| {
            const kept: *Shrunk = @fieldParentPtr("node", node);
            if (kept.source == source and kept.size.width == size.width and kept.size.height == size.height) {
                kept.users += 1;
                return .{ .pixels = kept.pixels, .size = size, .shrunk = kept };
            }
        }
        const bytes = @sizeOf(Shrunk) + size.width * size.height * 4;
        const memory = sys.AllocVec(@intCast(bytes), exec.MEMF_ANY) orelse return null;
        const kept: *Shrunk = @ptrCast(@alignCast(memory));
        const pixels: [*]u8 = @as([*]u8, @ptrCast(memory)) + @sizeOf(Shrunk);
        kept.* = .{ .source = source, .size = size, .users = 1, .pixels = pixels };
        const from = source.pixels[0 .. source.width * source.height * 4];
        shrink(from, source.width, source.height, pixels[0 .. size.width * size.height * 4], size);
        sys.AddTail(&pictures.list, &kept.node);
        return .{ .pixels = pixels, .size = size, .shrunk = kept };
    }

    /// An answer of `obtain` given back: a shrunk copy goes with the last
    /// icon that showed it.
    pub fn release(pictures: *Pictures, sys: *ExecBase, shown: Shown) void {
        _ = pictures;
        const kept = shown.shrunk orelse return;
        kept.users -= 1;
        if (kept.users != 0) return;
        sys.Remove(&kept.node);
        sys.FreeVec(kept);
    }
};

/// A picture as shown: its pixels (rgba32, a row `size.width * 4`
/// bytes) and size, and the copy they are in, if they were shrunk.
pub const Shown = struct {
    pixels: [*]const u8,
    size: Size,
    shrunk: ?*Shrunk,
};
