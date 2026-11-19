// SPDX-License-Identifier: MIT
//! Paint's selection: which pixels a change may touch - the stencil - and
//! the outline that shows them.
//!
//! It is a byte a pixel, as large as the picture: 255 chosen, 0 not, and
//! between for a pixel chosen in part (from a layer's alpha). With nothing
//! chosen, every pixel may change. Its `box` is the least area holding
//! every pixel chosen at all, so most work is cut to it.
//!
//! A new choice - a rectangle, a lasso's shape, the pixels a wand
//! reaches, the pixels of a colour - is made in a scratch mask of the same
//! size (`Scratch`) and laid into the selection as the press asked: in its
//! place, added, or taken away. The scratch is left empty again.
//!
//! The stencil is laid over a change once it is made: inside the
//! selection the change stays, outside it the picture is put back from
//! `kept`, its copy from before the change, and a pixel chosen in part
//! keeps that part of the change.
//!
//! The outline is the edge of what is chosen - a pixel chosen half or
//! more beside one that is not - which the view draws in dashes of black
//! and white over what it shows (view.zig).

const picture_zig = @import("picture.zig");
const fill_zig = @import("fill.zig");
const shapes = @import("shapes.zig");
const Picture = picture_zig.Picture;
const Pixel = picture_zig.Pixel;
const Area = picture_zig.Area;
const Point = shapes.Point;

/// How a new choice meets the selection there is: in its place, added to
/// it, or taken from it.
pub const How = enum { replace, add, take };

/// The most edges of a lasso's shape that cross one row and are counted.
pub const max_crossings = 256;

/// Pixels chosen, a byte each, a row after another, and the least area
/// holding them: the selection's, or a choice being made.
pub const Outline = struct {
    mask: []const u8,
    width: u32,
    box: Area,

    /// Whether (`x`, `y`) is chosen half or more; nothing past the
    /// picture is.
    pub fn chosen(outline: *const Outline, x: i32, y: i32) bool {
        const box = outline.box;
        if (x < box.min_x or y < box.min_y or x >= box.max_x or y >= box.max_y) return false;
        return outline.mask[@as(usize, @intCast(y)) * outline.width + @as(usize, @intCast(x))] >= 128;
    }
};

pub const Selection = struct {
    /// A byte a pixel; empty before the picture has a selection.
    mask: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    /// The least area holding every pixel chosen at all; empty when none
    /// is.
    box: Area = .{},

    /// Whether anything is chosen.
    pub fn any(selection: *const Selection) bool {
        return !selection.box.isEmpty();
    }

    pub fn outline(selection: *const Selection) Outline {
        return .{ .mask = selection.mask, .width = selection.width, .box = selection.box };
    }

    pub fn whole(selection: *const Selection) Area {
        return .{ .max_x = @intCast(selection.width), .max_y = @intCast(selection.height) };
    }

    /// How much of (`x`, `y`) is chosen, 0 to 255; past the picture none.
    pub fn at(selection: *const Selection, x: i32, y: i32) u8 {
        if (x < 0 or y < 0 or x >= selection.width or y >= selection.height) return 0;
        return selection.mask[@as(usize, @intCast(y)) * selection.width + @as(usize, @intCast(x))];
    }

    /// Nothing chosen.
    pub fn clear(selection: *Selection) void {
        fillArea(selection.mask, selection.width, selection.box, 0);
        selection.box = .{};
    }

    /// Every pixel chosen.
    pub fn all(selection: *Selection) void {
        @memset(selection.mask, 255);
        selection.box = selection.whole();
    }

    /// What is chosen let go, and what is not chosen.
    pub fn invert(selection: *Selection) void {
        for (selection.mask) |*part| part.* = 255 - part.*;
        selection.box = boxWithin(selection.mask, selection.width, selection.whole());
    }

    /// The choice in `scratch` laid into the selection as `how` says, and
    /// the scratch emptied.
    pub fn take(selection: *Selection, scratch: *Scratch, how: How) void {
        const area = scratch.box;
        if (how == .replace) selection.clear();
        if (!area.isEmpty()) {
            var y: u32 = @intCast(area.min_y);
            while (y < area.max_y) : (y += 1) {
                const into = rowOf(selection.mask, selection.width, y)[@intCast(area.min_x)..@intCast(area.max_x)];
                const from = rowOf(scratch.mask, scratch.width, y)[@intCast(area.min_x)..@intCast(area.max_x)];
                for (into, from) |*part, chosen| part.* = switch (how) {
                    .replace => chosen,
                    .add => @max(part.*, chosen),
                    .take => @intCast((@as(u32, part.*) * (255 - chosen) + 127) / 255),
                };
            }
        }
        selection.box = switch (how) {
            .replace => boxWithin(selection.mask, selection.width, area),
            .add => boxWithin(selection.mask, selection.width, selection.box.add(area)),
            .take => boxWithin(selection.mask, selection.width, selection.box),
        };
        scratch.empty();
    }

    /// The selection laid over a change of `area` in `picture`: outside
    /// it the picture as `kept` has it, a pixel chosen in part that part
    /// of the change. Nothing when nothing is chosen.
    pub fn stencil(selection: *const Selection, picture: *Picture, kept: *const Picture, area: Area) void {
        if (!selection.any()) return;
        const cut = area.clip(picture.width, picture.height);
        if (cut.isEmpty()) return;
        const from: usize = @intCast(cut.min_x);
        const to: usize = @intCast(cut.max_x);
        const box = selection.box;
        var y: u32 = @intCast(cut.min_y);
        while (y < cut.max_y) : (y += 1) {
            const into = picture.row(y)[from..to];
            const before = kept.row(y)[from..to];
            if (y < box.min_y or y >= box.max_y) {
                @memcpy(into, before);
                continue;
            }
            const parts = rowOf(selection.mask, selection.width, y)[from..to];
            for (into, before, parts) |*pixel, was, part| switch (part) {
                255 => {},
                0 => pixel.* = was,
                else => pixel.* = mix(was, pixel.*, part),
            };
        }
    }
};

/// A choice being made: a byte a pixel as large as the picture, what it
/// chooses over 0, and the least area holding that. It is empty between
/// choices.
pub const Scratch = struct {
    mask: []u8,
    width: u32,
    height: u32,
    box: Area = .{},

    pub fn outline(scratch: *const Scratch) Outline {
        return .{ .mask = scratch.mask, .width = scratch.width, .box = scratch.box };
    }

    pub fn empty(scratch: *Scratch) void {
        fillArea(scratch.mask, scratch.width, scratch.box, 0);
        scratch.box = .{};
    }

    /// The pixels of `area`, cut to the picture.
    pub fn rectangle(scratch: *Scratch, area: Area) void {
        scratch.empty();
        const cut = area.clip(scratch.width, scratch.height);
        fillArea(scratch.mask, scratch.width, cut, 255);
        scratch.box = cut;
    }

    /// The pixels whose middles the polygon through `points` holds,
    /// closed, by the even-odd rule.
    pub fn polygon(scratch: *Scratch, points: []const Point) void {
        scratch.empty();
        var crossings: [max_crossings]i64 = undefined;
        const Spans = struct {
            scratch: *Scratch,

            fn put(spans: @This(), y: i32, first: i32, last: i32) void {
                const into = spans.scratch;
                const left = @max(first, 0);
                const right = @min(last + 1, @as(i32, @intCast(into.width)));
                if (right <= left) return;
                @memset(rowOf(into.mask, into.width, @intCast(y))[@intCast(left)..@intCast(right)], 255);
                into.box = into.box.add(.{ .min_x = left, .min_y = y, .max_x = right, .max_y = y + 1 });
            }
        };
        scratch.box = Area.none;
        shapes.polygonSpans(points, scratch.height, &crossings, Spans{ .scratch = scratch }, Spans.put);
        if (scratch.box.isEmpty()) scratch.box = .{};
    }

    /// The pixels of the colour at (`x`, `y`) in `picture` joined to it,
    /// side by side or above and below - what a magic wand takes. False
    /// when `seeds` could not grow and it stopped short.
    pub fn wand(scratch: *Scratch, picture: *const Picture, x: i32, y: i32, seeds: *fill_zig.Seeds) bool {
        scratch.empty();
        if (!picture.inside(x, y)) return true;
        const old = picture.get(@intCast(x), @intCast(y));
        var box = Area.none;
        defer scratch.box = if (box.isEmpty()) Area{} else box;
        seeds.len = 0;
        if (!seeds.push(.{ x, y })) return false;
        const last_x: i32 = @as(i32, @intCast(picture.width)) - 1;
        while (seeds.len > 0) {
            seeds.len -= 1;
            const seed = seeds.items[seeds.len];
            const row = picture.row(@intCast(seed[1]));
            const marks = rowOf(scratch.mask, scratch.width, @intCast(seed[1]));
            if (row[@intCast(seed[0])] != old or marks[@intCast(seed[0])] != 0) continue;
            var left = seed[0];
            while (left > 0 and row[@intCast(left - 1)] == old) left -= 1;
            var right = seed[0];
            while (right < last_x and row[@intCast(right + 1)] == old) right += 1;
            @memset(marks[@intCast(left)..@intCast(right + 1)], 255);
            box = box.add(.{ .min_x = left, .min_y = seed[1], .max_x = right + 1, .max_y = seed[1] + 1 });
            for ([_]i32{ seed[1] - 1, seed[1] + 1 }) |near| {
                if (near < 0 or near >= picture.height) continue;
                const other = picture.row(@intCast(near));
                const other_marks = rowOf(scratch.mask, scratch.width, @intCast(near));
                var along = left;
                while (along <= right) : (along += 1) {
                    const open = other[@intCast(along)] == old and other_marks[@intCast(along)] == 0;
                    if (!open) continue;
                    // The first pixel of each run still to take.
                    const before_open = along > left and other[@intCast(along - 1)] == old and other_marks[@intCast(along - 1)] == 0;
                    if (!before_open and !seeds.push(.{ along, near })) return false;
                }
            }
        }
        return true;
    }

    /// Every pixel of `picture` that is `colour`.
    pub fn colour(scratch: *Scratch, picture: *const Picture, wanted: Pixel) void {
        scratch.chooseEach(picture, wanted, ofColour);
    }

    /// Every pixel of `picture` as far as it is there - its alpha - or,
    /// `see_through`, as far as it is not.
    pub fn alpha(scratch: *Scratch, picture: *const Picture, see_through: bool) void {
        scratch.chooseEach(picture, see_through, ofAlpha);
    }

    /// Every pixel of `picture` that is there and is none of `palette`'s
    /// colours.
    pub fn notIn(scratch: *Scratch, picture: *const Picture, palette: []const Pixel) void {
        scratch.chooseEach(picture, palette, notInPalette);
    }

    /// Each pixel chosen as far as `part` says.
    fn chooseEach(scratch: *Scratch, picture: *const Picture, context: anytype, comptime part: fn (@TypeOf(context), Pixel) u8) void {
        scratch.empty();
        var box = Area.none;
        var y: u32 = 0;
        while (y < picture.height) : (y += 1) {
            const marks = rowOf(scratch.mask, scratch.width, y);
            var first: ?usize = null;
            var last: usize = 0;
            for (picture.row(y), marks, 0..) |pixel, *mark, x| {
                mark.* = part(context, pixel);
                if (mark.* == 0) continue;
                if (first == null) first = x;
                last = x;
            }
            const left = first orelse continue;
            box = box.add(.{ .min_x = @intCast(left), .min_y = @intCast(y), .max_x = @intCast(last + 1), .max_y = @intCast(y + 1) });
        }
        scratch.box = if (box.isEmpty()) Area{} else box;
    }
};

fn ofColour(wanted: Pixel, pixel: Pixel) u8 {
    return if (pixel == wanted) 255 else 0;
}

fn ofAlpha(see_through: bool, pixel: Pixel) u8 {
    const there: u8 = @intCast(pixel >> 24);
    return if (see_through) 255 - there else there;
}

fn notInPalette(palette: []const Pixel, pixel: Pixel) u8 {
    if (pixel >> 24 == 0) return 0;
    const opaque_colour = pixel | 0xFF000000;
    for (palette) |offered| if (offered | 0xFF000000 == opaque_colour) return 0;
    return 255;
}

/// What of `pixel` is chosen when `part` of it is: its colour, that
/// part of its alpha.
pub fn partOf(pixel: Pixel, part: u8) Pixel {
    const alpha = ((pixel >> 24) * part + 127) / 255;
    return (alpha << 24) | (pixel & 0x00FFFFFF);
}

/// What is left of `pixel` when `part` of it is taken away and the place
/// left is `empty`: see-through (0), or that colour.
pub fn takenFrom(pixel: Pixel, part: u8, empty: Pixel) Pixel {
    if (empty == 0) return partOf(pixel, 255 - part);
    return mix(pixel, empty, part);
}

/// `before` and `after` mixed, `part` / 255 of `after`, a byte at a time.
fn mix(before: Pixel, after: Pixel, part: u8) Pixel {
    const share: u32 = part;
    var mixed: Pixel = 0;
    var shift: u5 = 0;
    while (true) : (shift += 8) {
        const was = (before >> shift) & 0xFF;
        const now = (after >> shift) & 0xFF;
        mixed |= ((was * (255 - share) + now * share + 127) / 255) << shift;
        if (shift == 24) break;
    }
    return mixed;
}

fn rowOf(mask: []u8, width: u32, y: u32) []u8 {
    const start = @as(usize, y) * width;
    return mask[start .. start + width];
}

/// The area of `mask`, cut to it, all `value`.
fn fillArea(mask: []u8, width: u32, area: Area, value: u8) void {
    if (area.isEmpty() or mask.len == 0) return;
    var y: u32 = @intCast(area.min_y);
    while (y < area.max_y) : (y += 1) @memset(rowOf(mask, width, y)[@intCast(area.min_x)..@intCast(area.max_x)], value);
}

/// The least area within `area` holding every byte of `mask` that is
/// not 0; empty when there is none.
fn boxWithin(mask: []u8, width: u32, area: Area) Area {
    if (area.isEmpty() or mask.len == 0) return .{};
    var box = Area.none;
    var y: u32 = @intCast(area.min_y);
    while (y < area.max_y) : (y += 1) {
        const row = rowOf(mask, width, y)[@intCast(area.min_x)..@intCast(area.max_x)];
        var first: ?usize = null;
        var last: usize = 0;
        for (row, 0..) |part, x| if (part != 0) {
            if (first == null) first = x;
            last = x;
        };
        const left = first orelse continue;
        box = box.add(.{
            .min_x = area.min_x + @as(i32, @intCast(left)),
            .min_y = @intCast(y),
            .max_x = area.min_x + @as(i32, @intCast(last + 1)),
            .max_y = @intCast(y + 1),
        });
    }
    return if (box.isEmpty()) Area{} else box;
}
