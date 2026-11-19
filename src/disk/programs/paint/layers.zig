// SPDX-License-Identifier: MIT
//! Paint's layers: the stack of them from the bottom up, and the picture
//! they make together.
//!
//! **A layer** is a picture the size of the others, with a name, an
//! opacity in percent, a blend mode and whether it is shown, and an id
//! that stays with it wherever it moves - the history names layers by
//! it. Its pixels are in memory of the program's (`memory`), which the
//! program gives back when the layer goes for good.
//!
//! **The composite** is what the layers shown make, the bottom one laid
//! first over nothing: each layer's pixels are blended with what is under
//! them by its mode and laid over it by its alpha times its opacity
//! (`blendOver`). It is made again over the area a change touched
//! (`compose`), a row at a time, so the view and a saved picture read a
//! single picture. A stack of one layer, shown and wholly opaque, is
//! that layer as it is (`plain`), and needs no composite.
//!
//! **Blending** follows the compositing rule for a source laid over a
//! backdrop: where the backdrop is covered, the layer's colour is first
//! put together with the backdrop's by the mode; the result goes over the
//! backdrop by the layer's coverage, and is divided by the coverage of
//! the two together. Add adds the two by their coverage instead. The
//! modes from hue to luminosity take the brightness as 30 % red, 59 %
//! green and 11 % blue, and pull a colour that brightness has put out of
//! range back towards its grey. Everything is in whole numbers, 255 for
//! one; soft light's square root comes from a table made as the program
//! is built.

const picture_zig = @import("picture.zig");
const Picture = picture_zig.Picture;
const Pixel = picture_zig.Pixel;
const Area = picture_zig.Area;

/// The most layers a picture has.
pub const max_layers = 64;
/// The bytes a layer's name has room for, its NUL among them.
pub const name_size = 32;

/// How a layer's colours are put together with what is under it; in the
/// order the project file numbers them.
pub const Blend = enum(u8) {
    normal,
    add,
    multiply,
    screen,
    overlay,
    darken,
    lighten,
    colour_dodge,
    colour_burn,
    hard_light,
    soft_light,
    hue,
    saturation,
    colour,
    luminosity,

    pub const count = @typeInfo(Blend).@"enum".fields.len;
};

pub const Layer = struct {
    picture: Picture,
    /// Where its pixels are: the program's, from AllocVec.
    memory: *anyopaque,
    name: [name_size]u8 = @splat(0),
    /// How much of it shows, 0 to 100.
    opacity: u8 = 100,
    blend: Blend = .normal,
    shown: bool = true,
    id: u32 = 0,

    /// The name, without its NUL.
    pub fn nameText(layer: *const Layer) []const u8 {
        var length: usize = 0;
        while (length < name_size and layer.name[length] != 0) length += 1;
        return layer.name[0..length];
    }

    /// The name set from `text`, cut to its room.
    pub fn setName(layer: *Layer, text: []const u8) void {
        layer.name = @splat(0);
        const length = @min(text.len, name_size - 1);
        @memcpy(layer.name[0..length], text[0..length]);
    }
};

pub const Stack = struct {
    /// Room for every layer there can be, the program's: the stack is
    /// kept in memory rather than on the program's stack.
    layers: *[max_layers]Layer,
    count: u32 = 0,
    /// The layer being painted.
    current: u32 = 0,
    /// The id the next layer gets.
    next_id: u32 = 1,
    /// What the layers make together, in memory of the program's; null
    /// until the stack first needs one.
    composite: ?Picture = null,

    pub fn all(stack: *Stack) []Layer {
        return stack.layers[0..stack.count];
    }

    pub fn currentLayer(stack: *Stack) *Layer {
        return &stack.layers[stack.current];
    }

    /// One layer, shown, wholly opaque: the picture is that layer.
    pub fn plain(stack: *const Stack) bool {
        return stack.count == 1 and stack.layers[0].shown and stack.layers[0].opacity == 100;
    }

    /// The picture that is shown: the bottom layer of a plain stack, the
    /// composite otherwise, which the program has given it by then.
    pub fn shown(stack: *const Stack) *const Picture {
        if (stack.plain()) return &stack.layers[0].picture;
        return &stack.composite.?;
    }

    /// Where the layer with that id is, if it is in the stack.
    pub fn placeOf(stack: *const Stack, id: u32) ?u32 {
        for (stack.layers[0..stack.count], 0..) |layer, place| {
            if (layer.id == id) return @intCast(place);
        }
        return null;
    }

    /// A new id for a layer made.
    pub fn newId(stack: *Stack) u32 {
        const id = stack.next_id;
        stack.next_id += 1;
        return id;
    }

    /// `layer` put in at `place`, the layers from there up a place
    /// higher; the layer painted stays the one it was. The stack has room.
    pub fn insert(stack: *Stack, place: u32, layer: Layer) void {
        var at = stack.count;
        while (at > place) : (at -= 1) stack.layers[at] = stack.layers[at - 1];
        stack.layers[place] = layer;
        if (stack.count > 0 and stack.current >= place) stack.current += 1;
        stack.count += 1;
    }

    /// The layer at `place` taken out, the ones above it down a place.
    /// When it was the one painted, the one under it is painted - the
    /// new bottom one when it was at the bottom.
    pub fn remove(stack: *Stack, place: u32) Layer {
        const layer = stack.layers[place];
        var at = place;
        while (at + 1 < stack.count) : (at += 1) stack.layers[at] = stack.layers[at + 1];
        stack.count -= 1;
        if (stack.current > place or (stack.current == place and place > 0)) stack.current -= 1;
        if (stack.current >= stack.count and stack.count > 0) stack.current = stack.count - 1;
        return layer;
    }

    /// The layer at `from` moved to `to`, those between closing up; the
    /// layer painted stays the one it was.
    pub fn move(stack: *Stack, from: u32, to: u32) void {
        if (from == to) return;
        const painted = stack.layers[stack.current].id;
        const layer = stack.layers[from];
        if (from < to) {
            var at = from;
            while (at < to) : (at += 1) stack.layers[at] = stack.layers[at + 1];
        } else {
            var at = from;
            while (at > to) : (at -= 1) stack.layers[at] = stack.layers[at - 1];
        }
        stack.layers[to] = layer;
        stack.current = stack.placeOf(painted).?;
    }

    /// The composite made again over `area`, cut to the picture; nothing
    /// for a plain stack.
    pub fn compose(stack: *Stack, area: Area) void {
        if (stack.plain()) return;
        const composite = &(stack.composite orelse return);
        const cut = area.clip(composite.width, composite.height);
        if (cut.isEmpty()) return;
        const from: usize = @intCast(cut.min_x);
        const to: usize = @intCast(cut.max_x);
        var y: u32 = @intCast(cut.min_y);
        while (y < cut.max_y) : (y += 1) {
            const into = composite.row(y)[from..to];
            @memset(into, 0);
            for (stack.layers[0..stack.count]) |*layer| {
                if (!layer.shown or layer.opacity == 0) continue;
                blendRow(into, layer.picture.row(y)[from..to], layer.blend, layer.opacity);
            }
        }
    }

    /// What is shown at (`x`, `y`), inside the picture.
    pub fn pixelAt(stack: *const Stack, x: u32, y: u32) Pixel {
        var colour: Pixel = 0;
        for (stack.layers[0..stack.count]) |*layer| {
            if (!layer.shown or layer.opacity == 0) continue;
            colour = blendOver(colour, layer.picture.get(x, y), layer.blend, layer.opacity);
        }
        return colour;
    }
};

/// A row of a layer laid over the row `into` holds, in place.
pub fn blendRow(into: []Pixel, layer: []const Pixel, mode: Blend, opacity: u8) void {
    for (into, layer) |*below, above| below.* = blendOver(below.*, above, mode, opacity);
}

/// `above`, at `opacity` percent, blended by `mode` with `below` and laid
/// over it.
pub fn blendOver(below: Pixel, above: Pixel, mode: Blend, opacity: u8) Pixel {
    const source_alpha = ((above >> 24) * opacity + 50) / 100;
    if (source_alpha == 0) return below;
    const backdrop_alpha = below >> 24;
    // Over nothing every mode is the layer's own colour.
    if (backdrop_alpha == 0) return (above & 0x00FF_FFFF) | (source_alpha << 24);
    if (mode == .normal and source_alpha == 255) return above | 0xFF00_0000;
    const source = channels(above);
    const backdrop = channels(below);
    if (mode == .add) return added(backdrop, backdrop_alpha, source, source_alpha);
    const blended = blend(mode, backdrop, source);
    const alpha = source_alpha + backdrop_alpha * (255 - source_alpha) / 255;
    var result: Pixel = alpha << 24;
    for (0..3) |at| {
        // Where the backdrop is covered the blend shows, elsewhere the
        // layer's own colour; that is laid over the backdrop.
        const mixed = ((255 - backdrop_alpha) * source[at] + backdrop_alpha * blended[at]) / 255;
        const covered = source_alpha * mixed * 255 + (255 - source_alpha) * backdrop_alpha * backdrop[at];
        const scale = alpha * 255;
        const value: u32 = @min(255, (covered + scale / 2) / scale);
        result |= value << shifts[at];
    }
    return result;
}

const shifts = [3]u5{ 16, 8, 0 };

/// Red, green and blue, 0 to 255 each.
fn channels(pixel: Pixel) [3]u32 {
    return .{ (pixel >> 16) & 0xFF, (pixel >> 8) & 0xFF, pixel & 0xFF };
}

/// Add: the two by their coverage, added and held to one.
fn added(backdrop: [3]u32, backdrop_alpha: u32, source: [3]u32, source_alpha: u32) Pixel {
    const alpha: u32 = @min(255, source_alpha + backdrop_alpha);
    var result: Pixel = alpha << 24;
    for (0..3) |at| {
        const covered: u32 = @min(255 * 255, source_alpha * source[at] + backdrop_alpha * backdrop[at]);
        const value: u32 = @min(255, (covered + alpha / 2) / alpha);
        result |= value << shifts[at];
    }
    return result;
}

/// The mode's colour from what is under (`backdrop`) and the layer's
/// (`source`).
fn blend(mode: Blend, backdrop: [3]u32, source: [3]u32) [3]u32 {
    switch (mode) {
        .hue => return withBrightness(withSaturation(signed(source), saturationOf(signed(backdrop))), brightnessOf(signed(backdrop))),
        .saturation => return withBrightness(withSaturation(signed(backdrop), saturationOf(signed(source))), brightnessOf(signed(backdrop))),
        .colour => return withBrightness(signed(source), brightnessOf(signed(backdrop))),
        .luminosity => return withBrightness(signed(backdrop), brightnessOf(signed(source))),
        else => {
            var result: [3]u32 = undefined;
            for (0..3) |at| result[at] = separate(mode, backdrop[at], source[at]);
            return result;
        },
    }
}

/// A mode that takes red, green and blue one at a time.
fn separate(mode: Blend, backdrop: u32, source: u32) u32 {
    return switch (mode) {
        .multiply => backdrop * source / 255,
        .screen => screen(backdrop, source),
        .overlay => hardLight(source, backdrop),
        .darken => @min(backdrop, source),
        .lighten => @max(backdrop, source),
        .colour_dodge => if (backdrop == 0) 0 else if (source >= 255) 255 else @min(255, backdrop * 255 / (255 - source)),
        .colour_burn => if (backdrop >= 255) 255 else if (source == 0) 0 else 255 - @min(255, (255 - backdrop) * 255 / source),
        .hard_light => hardLight(backdrop, source),
        .soft_light => softLight(backdrop, source),
        else => source,
    };
}

fn screen(backdrop: u32, source: u32) u32 {
    return backdrop + source - backdrop * source / 255;
}

fn hardLight(backdrop: u32, source: u32) u32 {
    if (source <= 127) return backdrop * 2 * source / 255;
    return screen(backdrop, 2 * source - 255);
}

fn softLight(backdrop: u32, source: u32) u32 {
    const under: i32 = @intCast(backdrop);
    const over: i32 = @intCast(source);
    const result = if (over <= 127)
        under - @divTrunc((255 - 2 * over) * under * (255 - under), 255 * 255)
    else
        under + @divTrunc((2 * over - 255) * (@as(i32, soft_light_curve[backdrop]) - under), 255);
    return @intCast(@max(0, @min(255, result)));
}

/// The curve soft light lightens by: for a dark value a polynomial, for
/// a lighter one its square root, 0 to 255.
const soft_light_curve = blk: {
    @setEvalBranchQuota(20_000);
    var table: [256]u8 = undefined;
    for (0..256) |at| {
        const value = @as(f64, @floatFromInt(at)) / 255.0;
        const curve = if (value <= 0.25) ((16 * value - 12) * value + 4) * value else @sqrt(value);
        table[at] = @intFromFloat(@round(curve * 255.0));
    }
    break :blk table;
};

// --- the modes of the colour as a whole --------------------------------------------

fn signed(colour: [3]u32) [3]i32 {
    return .{ @intCast(colour[0]), @intCast(colour[1]), @intCast(colour[2]) };
}

fn brightnessOf(colour: [3]i32) i32 {
    return @divTrunc(30 * colour[0] + 59 * colour[1] + 11 * colour[2], 100);
}

fn saturationOf(colour: [3]i32) i32 {
    return @max(colour[0], @max(colour[1], colour[2])) - @min(colour[0], @min(colour[1], colour[2]));
}

/// The colour moved to `brightness`, and pulled back towards its grey
/// where that took a part of it out of range - below 0 and above 255 by
/// the extremes it had once moved.
fn withBrightness(colour: [3]i32, brightness: i32) [3]u32 {
    const shift = brightness - brightnessOf(colour);
    var moved = [3]i32{ colour[0] + shift, colour[1] + shift, colour[2] + shift };
    const grey = brightnessOf(moved);
    const least = @min(moved[0], @min(moved[1], moved[2]));
    const most = @max(moved[0], @max(moved[1], moved[2]));
    if (least < 0 and grey != least) {
        for (&moved) |*part| part.* = grey + @divTrunc((part.* - grey) * grey, grey - least);
    }
    if (most > 255 and most != grey) {
        for (&moved) |*part| part.* = grey + @divTrunc((part.* - grey) * (255 - grey), most - grey);
    }
    var result: [3]u32 = undefined;
    for (moved, 0..) |part, at| result[at] = @intCast(@max(0, @min(255, part)));
    return result;
}

/// The colour given `saturation`, its hue kept: the largest part becomes
/// the saturation, the least 0, the middle one in proportion.
fn withSaturation(colour: [3]i32, saturation: i32) [3]i32 {
    // The parts' places from the least to the largest.
    var order = [3]usize{ 0, 1, 2 };
    sortPair(colour, &order, 0, 1);
    sortPair(colour, &order, 1, 2);
    sortPair(colour, &order, 0, 1);
    const least = colour[order[0]];
    const middle = colour[order[1]];
    const most = colour[order[2]];
    var result = [3]i32{ 0, 0, 0 };
    if (most > least) {
        result[order[1]] = @divTrunc((middle - least) * saturation, most - least);
        result[order[2]] = saturation;
    }
    return result;
}

/// The places at `first` and `second` of `order` swapped when the first
/// names the larger part.
fn sortPair(colour: [3]i32, order: *[3]usize, first: usize, second: usize) void {
    if (colour[order[first]] <= colour[order[second]]) return;
    const held = order[first];
    order[first] = order[second];
    order[second] = held;
}
