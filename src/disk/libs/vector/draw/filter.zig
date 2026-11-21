// SPDX-License-Identifier: MIT
//! A filter: what was drawn on a layer through SVG's filter primitives,
//! one after another, the last one's result put back on the layer. Since
//! 1.5.
//!
//! **The pixels** a filter works on are the region's - the filter region
//! the caller gives, in pixels, cut to the canvas - premultiplied,
//! 0xAARRGGBB as a pen is, eight bits a channel, as browsers filter. Each
//! primitive's result is pixels of the region's size of its own, clear
//! outside the primitive's subregion, and is kept until the last
//! primitive that reads it has run. The source is the layer's pens in
//! the region; its alpha is the same with no colour.
//!
//! **Colour spaces**: a result says which it is in. A primitive works in
//! linear light or in sRGB (`FILTERF_LINEARRGB`), and an input in the
//! other is turned into its space first, through the tables of
//! `blend.zig`; the colours a primitive is given in numbers - a flood's,
//! a light's - are sRGB and turned too. The last result is turned into
//! sRGB as it is put back.
//!
//! **What each primitive does** is SVG's Filter Effects: offsets moved
//! by whole pixels, cut toward 0; colour matrices and transfer
//! functions on the colours not premultiplied; Porter and Duff's
//! operators and the blend modes of `blend.zig` premultiplied; a
//! convolution by its kernel turned round, as SVG has it; a morphology a
//! box of whole pixels, its rows then its columns, in time of the
//! region's size whatever the radius; a displacement to the nearest pixel; turbulence
//! Perlin's noise by SVG's own code, each pixel's corner taken back into
//! the units it is made in; and lighting's normals by Sobel's kernels,
//! those at the edges the ones SVG gives for them. A convolution's
//! edges, a morphology's and a lighting's are the region's, past which
//! the input is not. Distances - offsets, radii, deviations, a light's
//! place - are the caller's, in pixels.

const sdk = @import("sdk");
const vector = sdk.vector;
const Pen = sdk.graphics.Pen;
const memory_ = @import("memory.zig");
const Memory = memory_.Memory;
const blend = @import("blend.zig");
const blur = @import("blur.zig");

/// Rows and columns of the region, from `left`, `top` to before `right`,
/// `bottom`.
pub const Box = struct {
    left: u32 = 0,
    top: u32 = 0,
    right: u32 = 0,
    bottom: u32 = 0,

    fn empty(box: Box) bool {
        return box.left >= box.right or box.top >= box.bottom;
    }

    fn holds(box: Box, x: i64, y: i64) bool {
        return x >= box.left and x < box.right and y >= box.top and y < box.bottom;
    }
};

/// Where the region is on the canvas, and its size.
pub const Area = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    fn count(area: Area) usize {
        return @as(usize, area.width) * area.height;
    }

    fn whole(area: Area) Box {
        return .{ .right = area.width, .bottom = area.height };
    }
};

/// The canvas pixels `rect` covers - from the pixel its left and top
/// edges are in, as many whole pixels as it is wide and high - cut to
/// `width` by `height`; null for none. A region and a subregion keep
/// their size in whole pixels wherever they lie.
pub fn areaOf(rect: vector.Rect, width: u32, height: u32) ?Area {
    const box = boxOf(rect, 0, 0, width, height);
    if (box.empty()) return null;
    return .{ .x = box.left, .y = box.top, .width = box.right - box.left, .height = box.bottom - box.top };
}

/// The pixels a rectangle of the canvas covers, as `areaOf` takes them,
/// made relative to the region at (`x`, `y`) and held to its `width` by
/// `height`.
fn boxOf(rect: vector.Rect, x: u32, y: u32, width: u32, height: u32) Box {
    const limit: f32 = 1 << 24;
    const left = @floor(@min(@max(rect.x, -limit), limit)) - @as(f32, @floatFromInt(x));
    const top = @floor(@min(@max(rect.y, -limit), limit)) - @as(f32, @floatFromInt(y));
    const right = left + @ceil(@min(@max(rect.width, 0), 2 * limit));
    const bottom = top + @ceil(@min(@max(rect.height, 0), 2 * limit));
    if (!(right > left) or !(bottom > top)) return .{};
    const most_x: f32 = @floatFromInt(width);
    const most_y: f32 = @floatFromInt(height);
    return .{
        .left = @intFromFloat(@min(@max(left, 0), most_x)),
        .top = @intFromFloat(@min(@max(top, 0), most_y)),
        .right = @intFromFloat(@min(@max(right, 0), most_x)),
        .bottom = @intFromFloat(@min(@max(bottom, 0), most_y)),
    };
}

/// A result: its pixels, which space they are in, and where they are not
/// clear.
const Image = struct {
    pixels: []Pen,
    linear: bool,
    box: Box,
};

pub const Failure = error{NoMemory};

/// The filter run over `layer` - the canvas's `width` by `height` pens,
/// not premultiplied - in `area`, the last result put back there and the
/// layer cleared round it in `drawn`, the rows and columns it had been
/// drawn on. What the layer holds now, in the canvas's pixels.
pub fn run(memory: Memory, layer: []Pen, width: u32, drawn: Box, area: Area, primitives: []const vector.FilterPrimitive) Failure!Box {
    var filter = Filter{ .memory = memory, .area = area, .primitives = primitives };
    defer filter.deinit();
    filter.source = try filter.alloc();
    const source = filter.source.?;
    @memset(source, 0);
    // The layer's pens premultiplied, where they were drawn.
    const read = Box{
        .left = @max(drawn.left, area.x),
        .top = @max(drawn.top, area.y),
        .right = @min(drawn.right, area.x + area.width),
        .bottom = @min(drawn.bottom, area.y + area.height),
    };
    if (!read.empty()) {
        var y = read.top;
        while (y < read.bottom) : (y += 1) {
            const from = layer[@as(usize, y) * width ..];
            const into = source[@as(usize, y - area.y) * area.width ..];
            var x = read.left;
            while (x < read.right) : (x += 1) into[x - area.x] = blur.premultiply(from[x]);
        }
    }
    filter.source_box = if (read.empty()) .{} else .{ .left = read.left - area.x, .top = read.top - area.y, .right = read.right - area.x, .bottom = read.bottom - area.y };

    for (primitives, 0..) |*primitive, index| try filter.step(primitive, index);

    // The layer emptied where it was drawn, and the last result put back.
    if (!drawn.empty()) {
        var y = drawn.top;
        while (y < drawn.bottom) : (y += 1) @memset(layer[@as(usize, y) * width ..][drawn.left..drawn.right], 0);
    }
    if (primitives.len == 0) return .{};
    const last = filter.results[primitives.len - 1] orelse return .{};
    if (last.box.empty()) return .{};
    var y = last.box.top;
    while (y < last.box.bottom) : (y += 1) {
        const from = last.pixels[@as(usize, y) * area.width ..];
        const into = layer[@as(usize, y + area.y) * width ..];
        var x = last.box.left;
        while (x < last.box.right) : (x += 1) {
            const pen = if (last.linear) toSpace(from[x], false) else from[x];
            into[x + area.x] = blur.unpremultiply(pen);
        }
    }
    return .{ .left = last.box.left + area.x, .top = last.box.top + area.y, .right = last.box.right + area.x, .bottom = last.box.bottom + area.y };
}

const Filter = struct {
    memory: Memory,
    area: Area,
    primitives: []const vector.FilterPrimitive,
    source: ?[]Pen = null,
    source_box: Box = .{},
    /// The source's alpha, and either in linear light, made when first
    /// asked for.
    alpha: ?[]Pen = null,
    source_linear: ?[]Pen = null,
    results: [vector.MAX_FILTER_PRIMITIVES]?Image = @splat(null),

    fn alloc(filter: *Filter) Failure![]Pen {
        return filter.memory.alloc(Pen, filter.area.count()) orelse error.NoMemory;
    }

    fn cleared(filter: *Filter) Failure![]Pen {
        const pixels = try filter.alloc();
        @memset(pixels, 0);
        return pixels;
    }

    fn deinit(filter: *Filter) void {
        if (filter.source) |pixels| filter.memory.free(Pen, pixels);
        if (filter.alpha) |pixels| filter.memory.free(Pen, pixels);
        if (filter.source_linear) |pixels| filter.memory.free(Pen, pixels);
        for (&filter.results) |*held| if (held.*) |made| {
            filter.memory.free(Pen, made.pixels);
            held.* = null;
        };
    }

    /// Whether a primitive after `index` reads result `index`, or it is the
    /// last.
    fn stillWanted(filter: *const Filter, index: usize) bool {
        if (index + 1 == filter.primitives.len) return true;
        for (filter.primitives[index + 1 ..]) |*later| {
            if (later.in == index or (later.in2 == index and twoInputs(later.kind))) return true;
            if (later.kind == vector.FILTER_MERGE) if (later.as.merge.inputs) |inputs| {
                for (inputs[0..later.as.merge.count]) |wanted| if (wanted == index) return true;
            };
        }
        return false;
    }

    /// Input `which` in the space `linear` asks for, and where it is not
    /// clear: the result itself, or one made for the call, which `done`
    /// gives back.
    fn input(filter: *Filter, which: i32, linear: bool) Failure!Input {
        var found: Image = switch (which) {
            vector.FILTERIN_SOURCE => .{ .pixels = filter.source.?, .linear = false, .box = filter.source_box },
            vector.FILTERIN_SOURCEALPHA => alpha: {
                if (filter.alpha == null) {
                    const pixels = try filter.alloc();
                    for (pixels, filter.source.?) |*into, from| into.* = from & 0xFF00_0000;
                    filter.alpha = pixels;
                }
                // Black is black in either space.
                break :alpha .{ .pixels = filter.alpha.?, .linear = linear, .box = filter.source_box };
            },
            else => found: {
                if (which < 0 or which >= filter.primitives.len) break :found .{ .pixels = &.{}, .linear = linear, .box = .{} };
                break :found filter.results[@intCast(which)] orelse .{ .pixels = &.{}, .linear = linear, .box = .{} };
            },
        };
        if (found.pixels.len == 0) {
            // A result not made - one that comes later, or past the list:
            // clear.
            const pixels = try filter.cleared();
            return .{ .image = .{ .pixels = pixels, .linear = linear, .box = .{} }, .owned = true };
        }
        if (found.linear == linear) return .{ .image = found, .owned = false };
        if (which == vector.FILTERIN_SOURCE and linear) {
            if (filter.source_linear == null) {
                const pixels = try filter.alloc();
                for (pixels, filter.source.?) |*into, from| into.* = toSpace(from, true);
                filter.source_linear = pixels;
            }
            return .{ .image = .{ .pixels = filter.source_linear.?, .linear = true, .box = found.box }, .owned = false };
        }
        const pixels = try filter.alloc();
        for (pixels, found.pixels) |*into, from| into.* = toSpace(from, linear);
        found.pixels = pixels;
        found.linear = linear;
        return .{ .image = found, .owned = true };
    }

    fn done(filter: *Filter, in: Input) void {
        if (in.owned) filter.memory.free(Pen, in.image.pixels);
    }

    fn step(filter: *Filter, primitive: *const vector.FilterPrimitive, index: usize) Failure!void {
        const area = filter.area;
        const linear = primitive.flags & vector.FILTERF_LINEARRGB != 0;
        const box = boxOf(primitive.region, area.x, area.y, area.width, area.height);
        const out = try filter.cleared();
        errdefer filter.memory.free(Pen, out);
        const result = Image{ .pixels = out, .linear = linear, .box = box };
        if (!box.empty()) switch (primitive.kind) {
            vector.FILTER_FLOOD => flood(out, area, box, colourIn(primitive.as.flood.colour, linear)),
            vector.FILTER_OFFSET => {
                const in = try filter.input(primitive.in, linear);
                defer filter.done(in);
                offset(out, in.image, area, box, primitive.as.offset.dx, primitive.as.offset.dy);
            },
            vector.FILTER_GAUSSIAN_BLUR => {
                const in = try filter.input(primitive.in, linear);
                defer filter.done(in);
                try gaussian(filter.memory, out, in.image, area, box, primitive.as.blur.deviation_x, primitive.as.blur.deviation_y);
            },
            vector.FILTER_COLOUR_MATRIX => {
                const in = try filter.input(primitive.in, linear);
                defer filter.done(in);
                colourMatrix(out, in.image.pixels, area, box, &primitive.as.colour_matrix.values);
            },
            vector.FILTER_COMPONENT_TRANSFER => {
                const in = try filter.input(primitive.in, linear);
                defer filter.done(in);
                transfer(out, in.image.pixels, area, box, &primitive.as.transfer);
            },
            vector.FILTER_COMPOSITE => {
                const in = try filter.input(primitive.in, linear);
                defer filter.done(in);
                const in2 = try filter.input(primitive.in2, linear);
                defer filter.done(in2);
                composite(out, in.image.pixels, in2.image.pixels, area, box, &primitive.as.composite);
            },
            vector.FILTER_BLEND => {
                const in = try filter.input(primitive.in, linear);
                defer filter.done(in);
                const in2 = try filter.input(primitive.in2, linear);
                defer filter.done(in2);
                blendOf(out, in.image.pixels, in2.image.pixels, area, box, primitive.as.blend.mode);
            },
            vector.FILTER_MERGE => {
                if (primitive.as.merge.inputs) |inputs| for (inputs[0..primitive.as.merge.count]) |which| {
                    const in = try filter.input(which, linear);
                    defer filter.done(in);
                    blendOf(out, in.image.pixels, out, area, box, vector.BLEND_NORMAL);
                };
            },
            vector.FILTER_TILE => {
                const in = try filter.input(primitive.in, linear);
                defer filter.done(in);
                tile(out, in.image, area, box);
            },
            vector.FILTER_IMAGE => placeImage(out, area, box, &primitive.as.image, linear),
            vector.FILTER_MORPHOLOGY => {
                const in = try filter.input(primitive.in, linear);
                defer filter.done(in);
                try morphology(filter.memory, out, in.image.pixels, area, box, &primitive.as.morphology);
            },
            vector.FILTER_CONVOLVE => {
                const in = try filter.input(primitive.in, linear);
                defer filter.done(in);
                convolve(out, in.image.pixels, area, box, &primitive.as.convolve);
            },
            vector.FILTER_DISPLACEMENT_MAP => {
                const in = try filter.input(primitive.in, linear);
                defer filter.done(in);
                const in2 = try filter.input(primitive.in2, linear);
                defer filter.done(in2);
                displace(out, in.image.pixels, in2.image.pixels, area, box, &primitive.as.displacement);
            },
            vector.FILTER_TURBULENCE => turbulence(out, area, box, &primitive.as.turbulence),
            vector.FILTER_DIFFUSE_LIGHTING, vector.FILTER_SPECULAR_LIGHTING => {
                const in = try filter.input(primitive.in, linear);
                defer filter.done(in);
                lighting(out, in.image.pixels, area, box, &primitive.as.lighting, primitive.kind == vector.FILTER_SPECULAR_LIGHTING, linear);
            },
            vector.FILTER_DROP_SHADOW => {
                const in = try filter.input(primitive.in, linear);
                defer filter.done(in);
                try dropShadow(filter.memory, out, in.image, area, box, &primitive.as.drop_shadow, linear);
            },
            else => {},
        };
        filter.results[index] = result;
        // What nothing reads any more goes.
        for (filter.results[0..index], 0..) |*held, place| {
            if (held.* == null or filter.stillWanted(place)) continue;
            filter.memory.free(Pen, held.*.?.pixels);
            held.* = null;
        }
    }
};

const Input = struct { image: Image, owned: bool };

fn twoInputs(kind: u32) bool {
    return kind == vector.FILTER_COMPOSITE or kind == vector.FILTER_BLEND or kind == vector.FILTER_DISPLACEMENT_MAP;
}

// --- pixels -------------------------------------------------------------------

/// A premultiplied pixel as four numbers 0 to 1, red, green, blue, alpha.
fn unpack(pen: Pen) [4]f32 {
    return .{
        @as(f32, @floatFromInt((pen >> 16) & 0xFF)) / 255,
        @as(f32, @floatFromInt((pen >> 8) & 0xFF)) / 255,
        @as(f32, @floatFromInt(pen & 0xFF)) / 255,
        @as(f32, @floatFromInt(pen >> 24)) / 255,
    };
}

fn byte(value: f32) Pen {
    return @intFromFloat(@min(@max(value * 255 + 0.5, 0), 255));
}

/// Four numbers 0 to 1, premultiplied, as a pixel: each held to 0 to 1
/// and the colours to no more than the alpha.
fn pack(colour: [4]f32) Pen {
    const alpha = @min(@max(colour[3], 0), 1);
    const red = @min(@max(colour[0], 0), alpha);
    const green = @min(@max(colour[1], 0), alpha);
    const blue = @min(@max(colour[2], 0), alpha);
    return byte(alpha) << 24 | byte(red) << 16 | byte(green) << 8 | byte(blue);
}

/// Not premultiplied: the colours over the alpha.
fn straight(colour: [4]f32) [4]f32 {
    if (colour[3] <= 0) return .{ 0, 0, 0, 0 };
    return .{ colour[0] / colour[3], colour[1] / colour[3], colour[2] / colour[3], colour[3] };
}

fn premultiplied(colour: [4]f32) [4]f32 {
    const alpha = @min(@max(colour[3], 0), 1);
    return .{ @min(@max(colour[0], 0), 1) * alpha, @min(@max(colour[1], 0), 1) * alpha, @min(@max(colour[2], 0), 1) * alpha, alpha };
}

/// A premultiplied pixel turned into linear light, or out of it.
pub fn toSpace(pen: Pen, linear: bool) Pen {
    const alpha = pen >> 24;
    if (alpha == 0) return 0;
    const lut = if (linear) &blend.to_linear else &blend.to_srgb;
    var out: Pen = alpha << 24;
    inline for (.{ 16, 8, 0 }) |shift| {
        const channel = (pen >> shift) & 0xFF;
        const unpremultiplied = @min(channel * 255 / alpha, 255);
        out |= (@as(Pen, lut[unpremultiplied]) * alpha + 127) / 255 << shift;
    }
    return out;
}

fn colourIn(colour: vector.Colour, linear: bool) vector.Colour {
    return if (linear) blend.linearColour(colour) else colour;
}

fn at(area: Area, x: u32, y: u32) usize {
    return @as(usize, y) * area.width + x;
}

// --- the primitives -----------------------------------------------------------

fn flood(out: []Pen, area: Area, box: Box, colour: vector.Colour) void {
    const pen = pack(premultiplied(.{ colour.r, colour.g, colour.b, colour.a }));
    var y = box.top;
    while (y < box.bottom) : (y += 1) @memset(out[at(area, box.left, y)..at(area, box.right, y)], pen);
}

fn offset(out: []Pen, in: Image, area: Area, box: Box, dx_f: f32, dy_f: f32) void {
    const limit: f32 = 1 << 24;
    const dx: i64 = @intFromFloat(@trunc(@min(@max(dx_f, -limit), limit)));
    const dy: i64 = @intFromFloat(@trunc(@min(@max(dy_f, -limit), limit)));
    var y = box.top;
    while (y < box.bottom) : (y += 1) {
        var x = box.left;
        while (x < box.right) : (x += 1) {
            const sx = @as(i64, x) - dx;
            const sy = @as(i64, y) - dy;
            if (!in.box.holds(sx, sy)) continue;
            out[at(area, x, y)] = in.pixels[at(area, @intCast(sx), @intCast(sy))];
        }
    }
}

fn gaussian(memory: Memory, out: []Pen, in: Image, area: Area, box: Box, sx: f32, sy: f32) Failure!void {
    // A negative deviation is an error, which SVG makes the primitive's
    // result clear; none at all is the input as it is.
    if (sx < 0 or sy < 0) return;
    const work = memory.alloc(Pen, area.count()) orelse return error.NoMemory;
    defer memory.free(Pen, work);
    @memcpy(work, in.pixels);
    if (!in.box.empty()) {
        const region = blur.Region{ .left = in.box.left, .top = in.box.top, .right = in.box.right, .bottom = in.box.bottom };
        _ = blur.blurPremultiplied(work, area.width, area.height, region, sx, sy, memory) orelse return error.NoMemory;
    }
    copyIn(out, work, area, box);
}

fn copyIn(out: []Pen, from: []const Pen, area: Area, box: Box) void {
    var y = box.top;
    while (y < box.bottom) : (y += 1) @memcpy(out[at(area, box.left, y)..at(area, box.right, y)], from[at(area, box.left, y)..at(area, box.right, y)]);
}

fn colourMatrix(out: []Pen, in: []const Pen, area: Area, box: Box, matrix: *const [20]f32) void {
    var y = box.top;
    while (y < box.bottom) : (y += 1) {
        var x = box.left;
        while (x < box.right) : (x += 1) {
            const colour = straight(unpack(in[at(area, x, y)]));
            var result: [4]f32 = undefined;
            for (0..4) |row| {
                const coefficients = matrix[row * 5 ..][0..5];
                result[row] = coefficients[0] * colour[0] + coefficients[1] * colour[1] + coefficients[2] * colour[2] + coefficients[3] * colour[3] + coefficients[4];
            }
            out[at(area, x, y)] = pack(premultiplied(result));
        }
    }
}

fn transferred(function: *const vector.FilterTransfer, value: f32) f32 {
    const result: f32 = switch (function.kind) {
        vector.TRANSFER_TABLE => table: {
            const values = function.table orelse break :table value;
            if (function.table_count == 0) break :table value;
            if (function.table_count == 1) break :table values[0];
            const steps: f32 = @floatFromInt(function.table_count - 1);
            const place_f = @min(@floor(value * steps), steps - 1);
            const place: usize = @intFromFloat(@max(place_f, 0));
            break :table values[place] + (value - place_f / steps) * steps * (values[place + 1] - values[place]);
        },
        vector.TRANSFER_DISCRETE => discrete: {
            const values = function.table orelse break :discrete value;
            if (function.table_count == 0) break :discrete value;
            const steps: f32 = @floatFromInt(function.table_count);
            const place: usize = @intFromFloat(@min(@max(@floor(value * steps), 0), steps - 1));
            break :discrete values[place];
        },
        vector.TRANSFER_LINEAR => function.slope * value + function.intercept,
        vector.TRANSFER_GAMMA => function.amplitude * blend.pow(f32, value, function.exponent) + function.offset,
        else => value,
    };
    return @min(@max(result, 0), 1);
}

fn transfer(out: []Pen, in: []const Pen, area: Area, box: Box, component_transfer: *const vector.FilterComponentTransfer) void {
    var y = box.top;
    while (y < box.bottom) : (y += 1) {
        var x = box.left;
        while (x < box.right) : (x += 1) {
            const colour = straight(unpack(in[at(area, x, y)]));
            var result: [4]f32 = undefined;
            for (0..4) |channel| result[channel] = transferred(&component_transfer.functions[channel], colour[channel]);
            out[at(area, x, y)] = pack(premultiplied(result));
        }
    }
}

fn composite(out: []Pen, in: []const Pen, in2: []const Pen, area: Area, box: Box, op: *const vector.FilterComposite) void {
    var y = box.top;
    while (y < box.bottom) : (y += 1) {
        var x = box.left;
        while (x < box.right) : (x += 1) {
            const first = unpack(in[at(area, x, y)]);
            const second = unpack(in2[at(area, x, y)]);
            var result: [4]f32 = undefined;
            for (0..4) |channel| result[channel] = switch (op.operator) {
                vector.COMPOSITE_IN => first[channel] * second[3],
                vector.COMPOSITE_OUT => first[channel] * (1 - second[3]),
                vector.COMPOSITE_ATOP => first[channel] * second[3] + second[channel] * (1 - first[3]),
                vector.COMPOSITE_XOR => first[channel] * (1 - second[3]) + second[channel] * (1 - first[3]),
                vector.COMPOSITE_ARITHMETIC => op.k[0] * first[channel] * second[channel] + op.k[1] * first[channel] + op.k[2] * second[channel] + op.k[3],
                vector.COMPOSITE_LIGHTER => first[channel] + second[channel],
                else => first[channel] + second[channel] * (1 - first[3]),
            };
            out[at(area, x, y)] = pack(result);
        }
    }
}

/// `in` over `in2` in `mode`, into `out` - which may be `in2`.
fn blendOf(out: []Pen, in: []const Pen, in2: []const Pen, area: Area, box: Box, mode: u32) void {
    var y = box.top;
    while (y < box.bottom) : (y += 1) {
        var x = box.left;
        while (x < box.right) : (x += 1) {
            const top = in[at(area, x, y)];
            const under = in2[at(area, x, y)];
            out[at(area, x, y)] = if (top == 0) under else if (under == 0 and mode != vector.BLEND_PLUS_LIGHTER) top else pack(blend.compose(mode, unpack(under), unpack(top)));
        }
    }
}

fn tile(out: []Pen, in: Image, area: Area, box: Box) void {
    const source = in.box;
    if (source.empty()) return;
    const source_width = source.right - source.left;
    const source_height = source.bottom - source.top;
    var y = box.top;
    while (y < box.bottom) : (y += 1) {
        const sy = source.top + @as(u32, @intCast(@mod(@as(i64, y) - source.top, source_height)));
        var x = box.left;
        while (x < box.right) : (x += 1) {
            const sx = source.left + @as(u32, @intCast(@mod(@as(i64, x) - source.left, source_width)));
            out[at(area, x, y)] = in.pixels[at(area, sx, sy)];
        }
    }
}

fn placeImage(out: []Pen, area: Area, box: Box, image: *const vector.FilterImage, linear: bool) void {
    const pens = image.pens orelse return;
    if (image.width == 0 or image.height == 0) return;
    const stride = if (image.bytes_per_row >= image.width * 4) image.bytes_per_row / 4 else image.width;
    var y = box.top;
    while (y < box.bottom) : (y += 1) {
        const iy = @as(i64, y) + area.y - image.y;
        if (iy < 0 or iy >= image.height) continue;
        var x = box.left;
        while (x < box.right) : (x += 1) {
            const ix = @as(i64, x) + area.x - image.x;
            if (ix < 0 or ix >= image.width) continue;
            const pen = blur.premultiply(pens[@as(usize, @intCast(iy)) * stride + @as(usize, @intCast(ix))]);
            out[at(area, x, y)] = if (linear) toSpace(pen, true) else pen;
        }
    }
}

/// The darkest or lightest of each channel in a box of whole pixels
/// round each pixel, cut to the region: a box is a row's window of
/// each column's, so the rows are gone through first, into room of the
/// region's size, and the columns of that after - each line in time of
/// its length, whatever the radius.
fn morphology(memory: Memory, out: []Pen, in: []const Pen, area: Area, box: Box, operation: *const vector.FilterMorphology) Failure!void {
    // A radius of nothing, or less, leaves the input as it is.
    if (!(operation.radius_x > 0) and !(operation.radius_y > 0)) return copyIn(out, in, area, box);
    if (operation.radius_x < 0 or operation.radius_y < 0) return;
    if (box.empty()) return;
    // A window past the region's size each way is the whole line.
    const across: u32 = @intFromFloat(@min(@round(@max(operation.radius_x, 0)), @as(f32, @floatFromInt(area.width - 1))));
    const down: u32 = @intFromFloat(@min(@round(@max(operation.radius_y, 0)), @as(f32, @floatFromInt(area.height - 1))));
    const dilate = operation.operator == vector.MORPHOLOGY_DILATE;
    const rows = memory.alloc(Pen, area.count()) orelse return error.NoMemory;
    defer memory.free(Pen, rows);
    const longest = @max(area.width, area.height);
    const room = memory.alloc(Pen, 6 * @as(usize, longest)) orelse return error.NoMemory;
    defer memory.free(Pen, room);
    // The rows the columns' windows reach.
    const top = box.top -| down;
    const bottom = @min(box.bottom +| down, area.height);
    var y = top;
    while (y < bottom) : (y += 1) {
        const line = Line{ .start = at(area, 0, y), .step = 1, .length = area.width, .kept = .{ 0, area.width } };
        line.extremes(in, rows, .{ box.left, box.right }, across, dilate, room);
    }
    var x = box.left;
    while (x < box.right) : (x += 1) {
        const line = Line{ .start = at(area, x, 0), .step = area.width, .length = area.height, .kept = .{ top, bottom } };
        line.extremes(rows, out, .{ box.top, box.bottom }, down, dilate, room);
    }
}

/// A row or a column of the region: where it starts, the step from one
/// pixel to the next, how many it has, and those of them read.
const Line = struct {
    start: usize,
    step: usize,
    length: u32,
    kept: [2]u32,

    /// Each of the `wanted` pixels of `to` the darkest or lightest
    /// of `from` within `radius` along the line, by van Herk's and Gil
    /// and Werman's way: the line in blocks of a window's length, the
    /// extremes from each block's start forward and from its end back;
    /// a window is the end of one block and the start of the next.
    fn extremes(line: Line, from: []const Pen, to: []Pen, wanted: [2]u32, radius: u32, dilate: bool, room: []Pen) void {
        const window = 2 * @as(usize, radius) + 1;
        const length = line.length + 2 * @as(usize, radius);
        const forward = room[0..length];
        const backward = room[length .. 2 * length];
        for (forward, 0..) |*pen, index| {
            const here = line.read(from, index, radius, dilate);
            pen.* = if (index % window == 0) here else extreme(forward[index - 1], here, dilate);
        }
        var index = length;
        while (index > 0) {
            index -= 1;
            const here = line.read(from, index, radius, dilate);
            backward[index] = if (index % window == window - 1 or index == length - 1) here else extreme(backward[index + 1], here, dilate);
        }
        var pixel = wanted[0];
        while (pixel < wanted[1]) : (pixel += 1) {
            to[line.start + pixel * line.step] = extreme(backward[pixel], forward[pixel + 2 * @as(usize, radius)], dilate);
        }
    }

    /// The line's pixel `index - radius`; one that changes nothing
    /// before its first and past its last, and outside those read.
    fn read(line: Line, from: []const Pen, index: usize, radius: u32, dilate: bool) Pen {
        const nothing: Pen = if (dilate) 0 else 0xFFFFFFFF;
        if (index < radius) return nothing;
        const pixel = index - radius;
        if (pixel < line.kept[0] or pixel >= line.kept[1]) return nothing;
        return from[line.start + pixel * line.step];
    }
};

/// Each channel the larger of two, or the smaller.
fn extreme(one: Pen, other: Pen, dilate: bool) Pen {
    var result: Pen = 0;
    inline for (0..4) |channel| {
        const shift = 8 * channel;
        const first = (one >> shift) & 0xFF;
        const second = (other >> shift) & 0xFF;
        result |= (if (dilate) @max(first, second) else @min(first, second)) << shift;
    }
    return result;
}

fn convolve(out: []Pen, in: []const Pen, area: Area, box: Box, convolution: *const vector.FilterConvolve) void {
    const kernel = convolution.kernel orelse return;
    if (convolution.order_x == 0 or convolution.order_y == 0 or convolution.order_x > 64 or convolution.order_y > 64) return;
    if (convolution.target_x < 0 or convolution.target_y < 0 or convolution.target_x >= convolution.order_x or convolution.target_y >= convolution.order_y) return;
    const divisor = if (convolution.divisor == 0) 1 else convolution.divisor;
    // The edges are the region's: the input is the region's size.
    const edges = area.whole();
    const width: i64 = edges.right - edges.left;
    const height: i64 = edges.bottom - edges.top;
    var y = box.top;
    while (y < box.bottom) : (y += 1) {
        var x = box.left;
        while (x < box.right) : (x += 1) {
            var sum: [4]f32 = .{ 0, 0, 0, 0 };
            var row: u32 = 0;
            while (row < convolution.order_y) : (row += 1) {
                var column: u32 = 0;
                while (column < convolution.order_x) : (column += 1) {
                    var sx = @as(i64, x) - convolution.target_x + column;
                    var sy = @as(i64, y) - convolution.target_y + row;
                    // What is past the primitive's subregion, by the edge
                    // mode.
                    var clear = false;
                    if (sx < edges.left or sx >= edges.right or sy < edges.top or sy >= edges.bottom) switch (convolution.edge) {
                        vector.EDGE_WRAP => {
                            sx = edges.left + @mod(sx - edges.left, width);
                            sy = edges.top + @mod(sy - edges.top, height);
                        },
                        vector.EDGE_NONE => clear = true,
                        else => {
                            sx = @min(@max(sx, edges.left), edges.right - 1);
                            sy = @min(@max(sy, edges.top), edges.bottom - 1);
                        },
                    };
                    if (clear) continue;
                    var pixel = unpack(in[at(area, @intCast(sx), @intCast(sy))]);
                    if (convolution.preserve_alpha != 0) pixel = straight(pixel);
                    const weight = kernel[(convolution.order_y - row - 1) * convolution.order_x + (convolution.order_x - column - 1)];
                    for (0..4) |channel| sum[channel] += pixel[channel] * weight;
                }
            }
            const own = unpack(in[at(area, x, y)]);
            if (convolution.preserve_alpha != 0) {
                var result: [4]f32 = undefined;
                for (0..3) |channel| result[channel] = sum[channel] / divisor + convolution.bias;
                result[3] = own[3];
                out[at(area, x, y)] = pack(premultiplied(result));
            } else {
                var result: [4]f32 = undefined;
                const alpha = @min(@max(sum[3] / divisor + convolution.bias, 0), 1);
                for (0..3) |channel| result[channel] = sum[channel] / divisor + convolution.bias * alpha;
                result[3] = alpha;
                out[at(area, x, y)] = pack(result);
            }
        }
    }
}

fn channelOf(pen: Pen, channel: u32) f32 {
    const colour = straight(unpack(pen));
    return switch (channel) {
        vector.CHANNEL_R => colour[0],
        vector.CHANNEL_G => colour[1],
        vector.CHANNEL_B => colour[2],
        else => colour[3],
    };
}

fn displace(out: []Pen, in: []const Pen, map: []const Pen, area: Area, box: Box, displacement: *const vector.FilterDisplacement) void {
    var y = box.top;
    while (y < box.bottom) : (y += 1) {
        var x = box.left;
        while (x < box.right) : (x += 1) {
            const mapped = map[at(area, x, y)];
            const fx = @as(f32, @floatFromInt(x)) + displacement.scale_x * (channelOf(mapped, displacement.x_channel) - 0.5);
            const fy = @as(f32, @floatFromInt(y)) + displacement.scale_y * (channelOf(mapped, displacement.y_channel) - 0.5);
            const limit: f32 = 1 << 24;
            const sx: i64 = @intFromFloat(@round(@min(@max(fx, -limit), limit)));
            const sy: i64 = @intFromFloat(@round(@min(@max(fy, -limit), limit)));
            if (sx < 0 or sy < 0 or sx >= area.width or sy >= area.height) continue;
            out[at(area, x, y)] = in[at(area, @intCast(sx), @intCast(sy))];
        }
    }
}

/// SVG's own steps: the input's coverage in the shadow's colour,
/// blurred where it is, then moved - a region's edge cuts the shadow
/// blurred, not fading - and the input over it.
fn dropShadow(memory: Memory, out: []Pen, in: Image, area: Area, box: Box, drop: *const vector.FilterDropShadow, linear: bool) Failure!void {
    const shadow = memory.alloc(Pen, area.count()) orelse return error.NoMemory;
    defer memory.free(Pen, shadow);
    @memset(shadow, 0);
    const colour = colourIn(drop.colour, linear);
    const tint = premultiplied(.{ colour.r, colour.g, colour.b, colour.a });
    var y = in.box.top;
    while (y < in.box.bottom) : (y += 1) {
        var x = in.box.left;
        while (x < in.box.right) : (x += 1) {
            const alpha = @as(f32, @floatFromInt(in.pixels[at(area, x, y)] >> 24)) / 255;
            if (alpha <= 0) continue;
            shadow[at(area, x, y)] = pack(.{ tint[0] * alpha, tint[1] * alpha, tint[2] * alpha, tint[3] * alpha });
        }
    }
    if (drop.deviation_x > 0 or drop.deviation_y > 0) {
        const whole = blur.Region{ .left = 0, .top = 0, .right = area.width, .bottom = area.height };
        _ = blur.blurPremultiplied(shadow, area.width, area.height, whole, @max(drop.deviation_x, 0), @max(drop.deviation_y, 0), memory) orelse return error.NoMemory;
    }
    const moved = memory.alloc(Pen, area.count()) orelse return error.NoMemory;
    defer memory.free(Pen, moved);
    @memset(moved, 0);
    const limit: f32 = 1 << 24;
    const dx: i64 = @intFromFloat(@trunc(@min(@max(drop.dx, -limit), limit)));
    const dy: i64 = @intFromFloat(@trunc(@min(@max(drop.dy, -limit), limit)));
    const whole = area.whole();
    y = box.top;
    while (y < box.bottom) : (y += 1) {
        var x = box.left;
        while (x < box.right) : (x += 1) {
            const sx = @as(i64, x) - dx;
            const sy = @as(i64, y) - dy;
            if (!whole.holds(sx, sy)) continue;
            moved[at(area, x, y)] = shadow[at(area, @intCast(sx), @intCast(sy))];
        }
    }
    blendOf(out, moved, out, area, box, vector.BLEND_NORMAL);
    blendOf(out, in.pixels, out, area, box, vector.BLEND_NORMAL);
}

// --- lighting -----------------------------------------------------------------

fn lighting(out: []Pen, in: []const Pen, area: Area, box: Box, settings: *const vector.FilterLighting, specular: bool, linear: bool) void {
    const colour = colourIn(settings.colour, linear);
    const light = &settings.light;
    const radians = 3.14159265358979 / 180.0;
    const surface_scale = settings.surface_scale;
    // A spot's way, and the cosine of its cone.
    var sx: f32 = 0;
    var sy: f32 = 0;
    var sz: f32 = 0;
    if (light.kind == vector.LIGHT_SPOT) {
        sx = light.at_x - light.x;
        sy = light.at_y - light.y;
        sz = light.at_z - light.z;
        const spot_length = @sqrt(sx * sx + sy * sy + sz * sz);
        if (spot_length > 0) {
            sx /= spot_length;
            sy /= spot_length;
            sz /= spot_length;
        }
    }
    const cone_cos = if (light.cone > 0 and light.cone < 90) @cos(light.cone * radians) else -1.0;
    var y = box.top;
    while (y < box.bottom) : (y += 1) {
        var x = box.left;
        while (x < box.right) : (x += 1) {
            const normal = normalOf(in, area, area.whole(), x, y, surface_scale);
            const height = surface_scale * alphaAt(in, area, x, y);
            var lx: f32 = undefined;
            var ly: f32 = undefined;
            var lz: f32 = undefined;
            if (light.kind == vector.LIGHT_DISTANT) {
                lx = @cos(light.azimuth * radians) * @cos(light.elevation * radians);
                ly = @sin(light.azimuth * radians) * @cos(light.elevation * radians);
                lz = @sin(light.elevation * radians);
            } else {
                lx = light.x - @as(f32, @floatFromInt(x + area.x));
                ly = light.y - @as(f32, @floatFromInt(y + area.y));
                lz = light.z - height;
                const len = @sqrt(lx * lx + ly * ly + lz * lz);
                if (len > 0) {
                    lx /= len;
                    ly /= len;
                    lz /= len;
                }
            }
            var lr = [3]f32{ colour.r, colour.g, colour.b };
            if (light.kind == vector.LIGHT_SPOT) {
                const minus_ls = -(lx * sx + ly * sy + lz * sz);
                if (minus_ls <= 0 or minus_ls < cone_cos) {
                    lr = .{ 0, 0, 0 };
                } else {
                    const falloff = blend.pow(f32, minus_ls, light.spot_exponent);
                    for (&lr) |*channel| channel.* *= falloff;
                }
            }
            var factor: f32 = undefined;
            if (specular) {
                var hx = lx;
                var hy = ly;
                var hz = lz + 1;
                const len = @sqrt(hx * hx + hy * hy + hz * hz);
                if (len > 0) {
                    hx /= len;
                    hy /= len;
                    hz /= len;
                }
                const nh = normal[0] * hx + normal[1] * hy + normal[2] * hz;
                factor = settings.constant * blend.pow(f32, nh, settings.exponent);
            } else {
                factor = settings.constant * (normal[0] * lx + normal[1] * ly + normal[2] * lz);
            }
            const red = @min(@max(factor * lr[0], 0), 1);
            const green = @min(@max(factor * lr[1], 0), 1);
            const blue = @min(@max(factor * lr[2], 0), 1);
            const alpha: f32 = if (specular) @max(red, @max(green, blue)) else 1;
            out[at(area, x, y)] = pack(.{ red, green, blue, alpha });
        }
    }
}

fn alphaAt(in: []const Pen, area: Area, x: u32, y: u32) f32 {
    return @as(f32, @floatFromInt(in[at(area, x, y)] >> 24)) / 255;
}

/// The surface's normal at (x, y): Sobel's kernels over the pixels round
/// it inside `box` - the region - scaled as SVG scales them at its edges
/// and corners: the derivative over the rows and columns there are.
fn normalOf(in: []const Pen, area: Area, box: Box, x: u32, y: u32, surface_scale: f32) [3]f32 {
    const left = if (x > box.left) x - 1 else x;
    const right = if (x + 1 < box.right) x + 1 else x;
    const up = if (y > box.top) y - 1 else y;
    const down = if (y + 1 < box.bottom) y + 1 else y;
    var nx: f32 = 0;
    var ny: f32 = 0;
    if (right > left) {
        var sum: f32 = 0;
        var weights: f32 = 0;
        var row = up;
        while (row <= down) : (row += 1) {
            const weight: f32 = if (row == y) 2 else 1;
            sum += weight * (alphaAt(in, area, right, row) - alphaAt(in, area, left, row));
            weights += weight;
        }
        nx = -surface_scale * 2 / (weights * @as(f32, @floatFromInt(right - left))) * sum;
    }
    if (down > up) {
        var sum: f32 = 0;
        var weights: f32 = 0;
        var column = left;
        while (column <= right) : (column += 1) {
            const weight: f32 = if (column == x) 2 else 1;
            sum += weight * (alphaAt(in, area, column, down) - alphaAt(in, area, column, up));
            weights += weight;
        }
        ny = -surface_scale * 2 / (weights * @as(f32, @floatFromInt(down - up))) * sum;
    }
    const len = @sqrt(nx * nx + ny * ny + 1);
    return .{ nx / len, ny / len, 1 / len };
}

// --- turbulence: SVG's own reference code -------------------------------------

const b_size = 0x100;
const b_mask = 0xFF;
const perlin_n = 0x1000;

const Lattice = struct {
    selector: [b_size + b_size + 2]i32,
    gradient: [4][b_size + b_size + 2][2]f64,

    fn init(seed_in: f64) Lattice {
        var lattice: Lattice = undefined;
        var seed = setupSeed(seed_in);
        for (0..4) |channel| {
            var cell: usize = 0;
            while (cell < b_size) : (cell += 1) {
                lattice.selector[cell] = @intCast(cell);
                for (0..2) |axis| {
                    seed = random(seed);
                    lattice.gradient[channel][cell][axis] = @as(f64, @floatFromInt(@mod(seed, b_size + b_size) - b_size)) / b_size;
                }
                const gradient = &lattice.gradient[channel][cell];
                const length = @sqrt(gradient[0] * gradient[0] + gradient[1] * gradient[1]);
                if (length != 0) {
                    gradient[0] /= length;
                    gradient[1] /= length;
                }
            }
        }
        var cell: usize = b_size - 1;
        while (cell > 0) : (cell -= 1) {
            const held = lattice.selector[cell];
            seed = random(seed);
            const other: usize = @intCast(@mod(seed, b_size));
            lattice.selector[cell] = lattice.selector[other];
            lattice.selector[other] = held;
        }
        cell = 0;
        while (cell < b_size + 2) : (cell += 1) {
            lattice.selector[b_size + cell] = lattice.selector[cell];
            for (0..4) |channel| lattice.gradient[channel][b_size + cell] = lattice.gradient[channel][cell];
        }
        return lattice;
    }
};

const random_m: i64 = 2147483647;
const random_a: i64 = 16807;
const random_q: i64 = 127773;
const random_r: i64 = 2836;

fn setupSeed(seed_in: f64) i64 {
    var seed: i64 = @intFromFloat(@min(@max(@round(seed_in), -1e9), 1e9));
    if (seed <= 0) seed = -@rem(seed, random_m - 1) + 1;
    if (seed > random_m - 1) seed = random_m - 1;
    return seed;
}

fn random(seed: i64) i64 {
    var next = random_a * @rem(seed, random_q) - random_r * @divTrunc(seed, random_q);
    if (next <= 0) next += random_m;
    return next;
}

/// A tile the noise is stitched to: its size in lattice cells, and where
/// it wraps back, each less `perlin_n` - so that an octave doubles them
/// all.
const Stitch = struct { width: i32, height: i32, wrap_x: i32, wrap_y: i32 };

fn sCurve(fraction: f64) f64 {
    return fraction * fraction * (3 - 2 * fraction);
}

fn lerp(fraction: f64, from: f64, to: f64) f64 {
    return from + fraction * (to - from);
}

fn noise2(lattice: *const Lattice, channel: usize, vx: f64, vy: f64, stitch: ?*const Stitch) f64 {
    var position = vx + perlin_n;
    var bx0: i32 = @intFromFloat(@floor(position));
    var bx1 = bx0 + 1;
    const rx0 = position - @floor(position);
    const rx1 = rx0 - 1;
    position = vy + perlin_n;
    var by0: i32 = @intFromFloat(@floor(position));
    var by1 = by0 + 1;
    const ry0 = position - @floor(position);
    const ry1 = ry0 - 1;
    if (stitch) |stitched| {
        if (bx0 - perlin_n >= stitched.wrap_x) bx0 -= stitched.width;
        if (bx1 - perlin_n >= stitched.wrap_x) bx1 -= stitched.width;
        if (by0 - perlin_n >= stitched.wrap_y) by0 -= stitched.height;
        if (by1 - perlin_n >= stitched.wrap_y) by1 -= stitched.height;
    }
    bx0 &= b_mask;
    bx1 &= b_mask;
    by0 &= b_mask;
    by1 &= b_mask;
    const row0 = lattice.selector[@intCast(bx0)];
    const row1 = lattice.selector[@intCast(bx1)];
    const b00 = lattice.selector[@intCast(row0 + by0)];
    const b10 = lattice.selector[@intCast(row1 + by0)];
    const b01 = lattice.selector[@intCast(row0 + by1)];
    const b11 = lattice.selector[@intCast(row1 + by1)];
    const sx = sCurve(rx0);
    const sy = sCurve(ry0);
    const gradients = &lattice.gradient[channel];
    var corner = gradients[@intCast(b00)];
    var near = rx0 * corner[0] + ry0 * corner[1];
    corner = gradients[@intCast(b10)];
    var far = rx1 * corner[0] + ry0 * corner[1];
    const upper = lerp(sx, near, far);
    corner = gradients[@intCast(b01)];
    near = rx0 * corner[0] + ry1 * corner[1];
    corner = gradients[@intCast(b11)];
    far = rx1 * corner[0] + ry1 * corner[1];
    const lower = lerp(sx, near, far);
    return lerp(sy, upper, lower);
}

fn turbulenceAt(lattice: *const Lattice, channel: usize, px: f64, py: f64, settings: *const vector.FilterTurbulence) f64 {
    var base_x: f64 = settings.base_x;
    var base_y: f64 = settings.base_y;
    var stitch_data: Stitch = undefined;
    var stitch: ?*Stitch = null;
    if (settings.stitch != 0) {
        // The frequencies moved so that a whole number of waves fits the
        // tile.
        if (base_x != 0) {
            const lo = @floor(settings.tile_width * base_x) / settings.tile_width;
            const hi = @ceil(settings.tile_width * base_x) / settings.tile_width;
            base_x = if (lo != 0 and base_x / lo < hi / base_x) lo else hi;
        }
        if (base_y != 0) {
            const lo = @floor(settings.tile_height * base_y) / settings.tile_height;
            const hi = @ceil(settings.tile_height * base_y) / settings.tile_height;
            base_y = if (lo != 0 and base_y / lo < hi / base_y) lo else hi;
        }
        stitch_data.width = @intFromFloat(settings.tile_width * base_x + 0.5);
        stitch_data.wrap_x = @as(i32, @intFromFloat(settings.tile_x * base_x + perlin_n + @as(f64, @floatFromInt(stitch_data.width)))) - perlin_n;
        stitch_data.height = @intFromFloat(settings.tile_height * base_y + 0.5);
        stitch_data.wrap_y = @as(i32, @intFromFloat(settings.tile_y * base_y + perlin_n + @as(f64, @floatFromInt(stitch_data.height)))) - perlin_n;
        stitch = &stitch_data;
    }
    var sum: f64 = 0;
    var vx = px * base_x;
    var vy = py * base_y;
    var ratio: f64 = 1;
    var octave: u32 = 0;
    while (octave < settings.octaves) : (octave += 1) {
        const noise = noise2(lattice, channel, vx, vy, stitch);
        sum += (if (settings.fractal != 0) noise else @abs(noise)) / ratio;
        vx *= 2;
        vy *= 2;
        ratio *= 2;
        if (stitch) |stitched| {
            stitched.width *= 2;
            stitched.wrap_x *= 2;
            stitched.height *= 2;
            stitched.wrap_y *= 2;
        }
    }
    return sum;
}

fn turbulence(out: []Pen, area: Area, box: Box, settings: *const vector.FilterTurbulence) void {
    if (settings.base_x < 0 or settings.base_y < 0) return;
    const inverse = settings.matrix.invert() orelse return;
    const lattice = Lattice.init(settings.seed);
    var y = box.top;
    while (y < box.bottom) : (y += 1) {
        var x = box.left;
        while (x < box.right) : (x += 1) {
            const point = inverse.apply(.{ .x = @floatFromInt(x + area.x), .y = @floatFromInt(y + area.y) });
            var colour: [4]f32 = undefined;
            for (0..4) |channel| {
                var value = turbulenceAt(&lattice, channel, point.x, point.y, settings);
                if (settings.fractal != 0) value = (value + 1) / 2;
                colour[channel] = @floatCast(@min(@max(value, 0), 1));
            }
            out[at(area, x, y)] = pack(premultiplied(colour));
        }
    }
}

// --- tests ---------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;
const test_memory = memory_.test_memory;

fn runOn(layer: []Pen, width: u32, height: u32, primitives: []const vector.FilterPrimitive) !Box {
    return run(test_memory, layer, width, .{ .right = width, .bottom = height }, .{ .x = 0, .y = 0, .width = width, .height = height }, primitives);
}

const everywhere = vector.Rect{ .width = 8, .height = 8 };

test "a region's pixels: from the one its corner is in, its size in whole pixels" {
    const area = areaOf(.{ .x = 1.6, .y = 0.2, .width = 2.2, .height = 1 }, 8, 8).?;
    try testing.expectEqual(@as(u32, 1), area.x);
    try testing.expectEqual(@as(u32, 0), area.y);
    try testing.expectEqual(@as(u32, 3), area.width);
    try testing.expectEqual(@as(u32, 1), area.height);
    try testing.expect(areaOf(.{ .x = 9, .y = 0, .width = 2, .height = 2 }, 8, 8) == null);
}

test "a flood, an offset and a merge: the source moved and laid over a colour" {
    var layer: [64]Pen = @splat(0);
    layer[0] = 0xFFFF0000;
    const inputs = [_]i32{ 0, 1 };
    const primitives = [_]vector.FilterPrimitive{
        .{ .kind = vector.FILTER_FLOOD, .region = everywhere, .flags = 0, .as = .{ .flood = .{ .colour = .{ .g = 1 } } } },
        .{ .kind = vector.FILTER_OFFSET, .region = everywhere, .flags = 0, .as = .{ .offset = .{ .dx = 2, .dy = 1 } } },
        .{ .kind = vector.FILTER_MERGE, .region = everywhere, .flags = 0, .as = .{ .merge = .{ .inputs = &inputs, .count = 2 } } },
    };
    _ = try runOn(&layer, 8, 8, &primitives);
    try testing.expectEqual(@as(Pen, 0xFF00FF00), layer[0]);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), layer[1 * 8 + 2]);
}

test "a subregion clips the result, and a filter of nothing clears the layer" {
    var layer: [64]Pen = @splat(0xFF0000FF);
    const primitives = [_]vector.FilterPrimitive{
        .{ .kind = vector.FILTER_OFFSET, .region = .{ .x = 2, .y = 2, .width = 2, .height = 2 }, .flags = 0, .as = .{ .offset = .{} } },
    };
    const box = try runOn(&layer, 8, 8, &primitives);
    try testing.expectEqual(Box{ .left = 2, .top = 2, .right = 4, .bottom = 4 }, box);
    try testing.expectEqual(@as(Pen, 0), layer[0]);
    try testing.expectEqual(@as(Pen, 0xFF0000FF), layer[2 * 8 + 2]);
    _ = try runOn(&layer, 8, 8, &.{});
    for (layer) |pen| try testing.expectEqual(@as(Pen, 0), pen);
}

test "linear light: a primitive's input turned into it and its result back" {
    var layer: [64]Pen = @splat(0xFF808080);
    const primitives = [_]vector.FilterPrimitive{
        .{ .kind = vector.FILTER_OFFSET, .region = everywhere, .as = .{ .offset = .{} } },
    };
    _ = try runOn(&layer, 8, 8, &primitives);
    // Out and back by the tables: within a step.
    const back = layer[9] & 0xFF;
    try testing.expect(back >= 0x7E and back <= 0x82);
    // A flood of 50 % grey in linear light comes back as itself.
    const flood_only = [_]vector.FilterPrimitive{
        .{ .kind = vector.FILTER_FLOOD, .region = everywhere, .as = .{ .flood = .{ .colour = .{ .r = 0.5, .g = 0.5, .b = 0.5 } } } },
    };
    _ = try runOn(&layer, 8, 8, &flood_only);
    const grey = layer[9] & 0xFF;
    try testing.expect(grey >= 0x7E and grey <= 0x81);
}

test "a colour matrix, a transfer table and composites" {
    var layer: [64]Pen = @splat(0xFFFF0000);
    // Red into green.
    var swap = vector.FilterColourMatrix{ .values = @splat(0) };
    swap.values[1 * 5 + 0] = 1;
    swap.values[3 * 5 + 3] = 1;
    const matrix = [_]vector.FilterPrimitive{.{ .kind = vector.FILTER_COLOUR_MATRIX, .region = everywhere, .flags = 0, .as = .{ .colour_matrix = swap } }};
    _ = try runOn(&layer, 8, 8, &matrix);
    try testing.expectEqual(@as(Pen, 0xFF00FF00), layer[0]);
    // Green through a table of one step down.
    const half = [_]f32{ 0, 0.5 };
    var stepped = vector.FilterComponentTransfer{};
    stepped.functions[1] = .{ .kind = vector.TRANSFER_TABLE, .table = &half, .table_count = 2 };
    const table = [_]vector.FilterPrimitive{.{ .kind = vector.FILTER_COMPONENT_TRANSFER, .region = everywhere, .flags = 0, .as = .{ .transfer = stepped } }};
    _ = try runOn(&layer, 8, 8, &table);
    try testing.expectEqual(@as(Pen, 0xFF008000), layer[0]);
    // The source out of itself is nothing; in itself, itself.
    const out = [_]vector.FilterPrimitive{.{ .kind = vector.FILTER_COMPOSITE, .region = everywhere, .flags = 0, .in2 = vector.FILTERIN_SOURCE, .as = .{ .composite = .{ .operator = vector.COMPOSITE_OUT } } }};
    _ = try runOn(&layer, 8, 8, &out);
    try testing.expectEqual(@as(Pen, 0), layer[0]);
}

test "erode and dilate, a tile, and an image placed on the canvas" {
    var layer: [64]Pen = @splat(0);
    layer[3 * 8 + 3] = 0xFFFFFFFF;
    const dilate = [_]vector.FilterPrimitive{.{ .kind = vector.FILTER_MORPHOLOGY, .region = everywhere, .flags = 0, .as = .{ .morphology = .{ .operator = vector.MORPHOLOGY_DILATE, .radius_x = 1, .radius_y = 1 } } }};
    _ = try runOn(&layer, 8, 8, &dilate);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), layer[2 * 8 + 2]);
    try testing.expectEqual(@as(Pen, 0), layer[1 * 8 + 1]);
    const erode = [_]vector.FilterPrimitive{.{ .kind = vector.FILTER_MORPHOLOGY, .region = everywhere, .flags = 0, .as = .{ .morphology = .{ .radius_x = 1, .radius_y = 1 } } }};
    _ = try runOn(&layer, 8, 8, &erode);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), layer[3 * 8 + 3]);
    try testing.expectEqual(@as(Pen, 0), layer[2 * 8 + 2]);
    // A radius past the region's size: every pixel the region's darkest,
    // or here its lightest, at once.
    layer = @splat(0);
    layer[6 * 8 + 1] = 0xFF402010;
    const huge = [_]vector.FilterPrimitive{.{ .kind = vector.FILTER_MORPHOLOGY, .region = everywhere, .flags = 0, .as = .{ .morphology = .{ .operator = vector.MORPHOLOGY_DILATE, .radius_x = 9999, .radius_y = 9999 } } }};
    _ = try runOn(&layer, 8, 8, &huge);
    try testing.expectEqual(@as(Pen, 0xFF402010), layer[0]);
    try testing.expectEqual(@as(Pen, 0xFF402010), layer[63]);
    // One way only: a row of it.
    layer = @splat(0);
    layer[4 * 8 + 4] = 0xFFFFFFFF;
    const wide = [_]vector.FilterPrimitive{.{ .kind = vector.FILTER_MORPHOLOGY, .region = everywhere, .flags = 0, .as = .{ .morphology = .{ .operator = vector.MORPHOLOGY_DILATE, .radius_x = 2, .radius_y = 0.25 } } }};
    _ = try runOn(&layer, 8, 8, &wide);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), layer[4 * 8 + 2]);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), layer[4 * 8 + 6]);
    try testing.expectEqual(@as(Pen, 0), layer[4 * 8 + 7]);
    try testing.expectEqual(@as(Pen, 0), layer[3 * 8 + 4]);

    const pixels = [_]Pen{ 0xFFFF0000, 0xFF00FF00 };
    const tiled = [_]vector.FilterPrimitive{
        .{ .kind = vector.FILTER_IMAGE, .region = .{ .x = 0, .y = 0, .width = 2, .height = 1 }, .flags = 0, .as = .{ .image = .{ .pens = &pixels, .width = 2, .height = 1, .bytes_per_row = 8 } } },
        .{ .kind = vector.FILTER_TILE, .in = 0, .region = everywhere, .flags = 0 },
    };
    _ = try runOn(&layer, 8, 8, &tiled);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), layer[5 * 8 + 4]);
    try testing.expectEqual(@as(Pen, 0xFF00FF00), layer[5 * 8 + 5]);
}

test "turbulence: the same from the same seed, coloured, within range; lighting: a flat surface lit straight down" {
    var layer: [64]Pen = @splat(0);
    const noise = [_]vector.FilterPrimitive{.{ .kind = vector.FILTER_TURBULENCE, .region = everywhere, .flags = 0, .as = .{ .turbulence = .{ .base_x = 0.1, .base_y = 0.1, .octaves = 2, .seed = 3, .fractal = 1 } } }};
    _ = try runOn(&layer, 8, 8, &noise);
    const first = layer;
    _ = try runOn(&layer, 8, 8, &noise);
    try testing.expectEqualSlices(Pen, &first, &layer);
    var differs = false;
    for (layer[1..]) |pen| if (pen != layer[0]) {
        differs = true;
    };
    try testing.expect(differs);

    @memset(&layer, 0);
    const lit = [_]vector.FilterPrimitive{.{ .kind = vector.FILTER_DIFFUSE_LIGHTING, .region = everywhere, .flags = 0, .as = .{ .lighting = .{ .light = .{ .elevation = 90 } } } }};
    _ = try runOn(&layer, 8, 8, &lit);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), layer[27]);
}

test "a drop shadow under the source, and a blur that spreads" {
    var layer: [64]Pen = @splat(0);
    layer[0] = 0xFF0000FF;
    const shadow = [_]vector.FilterPrimitive{.{ .kind = vector.FILTER_DROP_SHADOW, .region = everywhere, .flags = 0, .as = .{ .drop_shadow = .{ .dx = 1, .dy = 1, .deviation_x = 0, .deviation_y = 0 } } }};
    _ = try runOn(&layer, 8, 8, &shadow);
    try testing.expectEqual(@as(Pen, 0xFF0000FF), layer[0]);
    try testing.expectEqual(@as(Pen, 0xFF000000), layer[9]);
    const soft = [_]vector.FilterPrimitive{.{ .kind = vector.FILTER_GAUSSIAN_BLUR, .region = everywhere, .flags = 0, .as = .{ .blur = .{ .deviation_x = 1, .deviation_y = 1 } } }};
    _ = try runOn(&layer, 8, 8, &soft);
    try testing.expect(layer[2] >> 24 > 0);
}
