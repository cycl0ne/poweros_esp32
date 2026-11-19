// SPDX-License-Identifier: MIT
//! The Image menu's changes to a whole picture, a layer at a time: each
//! layer - and its mask - is made anew from the old one at the size the
//! change gives it (`sizeAfter`, `apply`).
//!
//! A turn or a flip moves every pixel to its new place. Placing the
//! picture on a canvas of another size puts its top left corner at a
//! place of the canvas: what lies past the canvas is cut away and the
//! canvas round it is filled. Cropping and trimming are such a placing,
//! the corner at minus the area's own, and so is a larger canvas
//! (`placed`, which puts the picture in one of nine places).
//!
//! Scaling is a change of size too (`sizeAfter`), but its pixels are
//! paintfx.library's to make: `apply` leaves `into` to the caller then.
//!
//! `trimmed` finds what Trim keeps: the least area holding every pixel
//! unlike the top left one.

const picture_zig = @import("picture.zig");
const Picture = picture_zig.Picture;
const Pixel = picture_zig.Pixel;
const Area = picture_zig.Area;

pub const Change = union(enum) {
    /// A quarter turn clockwise, anticlockwise, a half turn.
    turn_right,
    turn_left,
    turn_half,
    /// Left to right, top to bottom.
    flip_across,
    flip_down,
    place: Place,
    /// The picture made another size (paintfx.library's ScalePixels).
    scale: Scale,
};

/// The picture scaled to `width` by `height`, smoothly or with the
/// nearest pixel.
pub const Scale = struct { width: u32, height: u32, smooth: bool };

/// The picture on a canvas `width` by `height`, its top left corner at
/// (`left`, `top`) of the canvas.
pub const Place = struct { width: u32, height: u32, left: i32, top: i32 };

/// A picture's size after `change`.
pub fn sizeAfter(change: Change, width: u32, height: u32) [2]u32 {
    return switch (change) {
        .turn_right, .turn_left => .{ height, width },
        .turn_half, .flip_across, .flip_down => .{ width, height },
        .place => |place| .{ place.width, place.height },
        .scale => |scale| .{ scale.width, scale.height },
    };
}

/// The size `asked` for a picture `was`, the side left as it was
/// following the other in proportion, at least a pixel; as asked when
/// both sides or neither changed.
pub fn proportioned(was: [2]u32, asked: [2]u32) [2]u32 {
    const across = asked[0] != was[0];
    const down = asked[1] != was[1];
    if (across == down) return asked;
    if (across) return .{ asked[0], @intCast(@max(1, (@as(u64, was[1]) * asked[0] + was[0] / 2) / was[0])) };
    return .{ @intCast(@max(1, (@as(u64, was[0]) * asked[1] + was[1] / 2) / was[1])), asked[1] };
}

/// A picture `width` by `height` on a canvas `canvas_width` by
/// `canvas_height`, at the place `where` names - 0 to 8, by rows from
/// the top left; past its sides where the canvas is smaller.
pub fn placed(width: u32, height: u32, canvas_width: u32, canvas_height: u32, where: u32) Place {
    const spare_x = @as(i32, @intCast(canvas_width)) - @as(i32, @intCast(width));
    const spare_y = @as(i32, @intCast(canvas_height)) - @as(i32, @intCast(height));
    return .{
        .width = canvas_width,
        .height = canvas_height,
        .left = share(spare_x, where % 3),
        .top = share(spare_y, where / 3),
    };
}

/// None of `spare`, half of it, or all of it, by `third`.
fn share(spare: i32, third: u32) i32 {
    return switch (third) {
        0 => 0,
        1 => @divFloor(spare, 2),
        else => spare,
    };
}

/// `from` made into `into` - the size `sizeAfter` gives - by `change`;
/// a canvas's new part `fill`. A scale is not made here: `into` is left
/// as it is.
pub fn apply(change: Change, from: *const Picture, into: *Picture, fill: Pixel) void {
    if (change == .scale) return;
    if (change == .place) {
        const place = change.place;
        into.fill(fill);
        const area = (Area{
            .min_x = place.left,
            .min_y = place.top,
            .max_x = place.left + @as(i32, @intCast(from.width)),
            .max_y = place.top + @as(i32, @intCast(from.height)),
        }).clip(into.width, into.height);
        if (area.isEmpty()) return;
        var y = area.min_y;
        while (y < area.max_y) : (y += 1) {
            const source = from.row(@intCast(y - place.top))[@intCast(area.min_x - place.left)..][0..area.width()];
            @memcpy(into.row(@intCast(y))[@intCast(area.min_x)..@intCast(area.max_x)], source);
        }
        return;
    }
    var y: u32 = 0;
    while (y < into.height) : (y += 1) {
        const row = into.row(y);
        for (row, 0..) |*pixel, column| {
            const x: u32 = @intCast(column);
            const source: [2]u32 = switch (change) {
                // The left column, read upwards, is the top row.
                .turn_right => .{ y, from.height - 1 - x },
                // The right column, read downwards, is the top row.
                .turn_left => .{ from.width - 1 - y, x },
                .turn_half => .{ from.width - 1 - x, from.height - 1 - y },
                .flip_across => .{ from.width - 1 - x, y },
                .flip_down => .{ x, from.height - 1 - y },
                .place, .scale => unreachable,
            };
            pixel.* = from.get(source[0], source[1]);
        }
    }
}

/// The least area of `picture` holding every pixel unlike its top left
/// one; empty when every pixel is alike.
pub fn trimmed(picture: *const Picture) Area {
    const corner = picture.get(0, 0);
    var area = Area.none;
    var y: u32 = 0;
    while (y < picture.height) : (y += 1) {
        const row = picture.row(y);
        var first: ?usize = null;
        var last: usize = 0;
        for (row, 0..) |pixel, x| {
            if (pixel == corner) continue;
            if (first == null) first = x;
            last = x;
        }
        const start = first orelse continue;
        area = area.add(.{ .min_x = @intCast(start), .min_y = @intCast(y), .max_x = @intCast(last + 1), .max_y = @intCast(y + 1) });
    }
    return area;
}
