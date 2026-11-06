// SPDX-License-Identifier: MIT
//! A shader written once: that its words are the words Khronos' own
//! assembler writes, and that the function the same graph generates
//! paints what a hand-written fixed form paints.
//!
//! The first half is a comparison with `tests/spirv_reference.zig`, which
//! `spirv-val` has accepted. It is the strong check: if the five shapes
//! the V3D already has QPU programs for come out word for word, then the
//! graph says what a Vulkan driver would read, and a desktop driver can
//! be handed the same module.
//!
//! The second half is the one that matters on this machine. The cores run
//! the generated function, so it has to be right, and it has to be right
//! in the same arithmetic as `shader.smooth`: the pictures the reference
//! images were drawn with came out of that function, and a generated one
//! is compared against it rather than put in its place.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const shader = facet.shader;
const ir = facet.ir;
const spirv = facet.spirv;
const texture = facet.texture;
const reference = @import("spirv_reference.zig");

fn expectWords(want: []const u32, made: []const u32) !void {
    try std.testing.expectEqual(want.len, made.len);
    for (want, made, 0..) |a, b, at| {
        if (at == 2) continue; // the generator word is the emitter's own
        if (a != b) {
            std.debug.print("word {d}: want 0x{X:0>8}, made 0x{X:0>8}\n", .{ at, a, b });
            return error.TestExpectedEqual;
        }
    }
}

// --- the five shapes the V3D has hand-written programs for -----------------

const Flat = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.constant(.{ 1, 0, 0, 1 }));
    }
});

const Smooth = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.input(0, .f32x4));
    }
});

const Textured = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.sample(0, 0, b.input(0, .f32x2)));
    }
});

const Modulated = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.mul(b.sample(0, 0, b.input(0, .f32x2)), b.input(1, .f32x4)));
    }
});

const Cutout = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const taken = b.sample(0, 0, b.input(0, .f32x2));
        b.discardIf(b.lessThan(b.component(taken, 3), b.scalar(0.5)));
        b.color(taken);
    }
});

test "a colour of its own is the module an assembler writes" {
    try expectWords(&reference.min_flat, Flat.words);
    try std.testing.expectEqual(@as(u32, 0), Flat.varyings);
    try std.testing.expect(!Flat.discards);
}

test "an interpolated colour is the module an assembler writes" {
    try expectWords(&reference.min_interp, Smooth.words);
    try std.testing.expectEqual(@as(u32, 4), Smooth.varyings);
}

test "a texture is the module an assembler writes" {
    try expectWords(&reference.min_tex, Textured.words);
    try std.testing.expectEqual(@as(u32, 2), Textured.varyings);
}

test "a texture times a colour is the module an assembler writes" {
    try expectWords(&reference.min_texmod, Modulated.words);
    try std.testing.expectEqual(@as(u32, 6), Modulated.varyings);
}

test "a dropped pixel is the module an assembler writes" {
    try expectWords(&reference.min_discard, Cutout.words);
    try std.testing.expectEqual(@as(u32, 2), Cutout.varyings);
    try std.testing.expect(Cutout.discards);
}

test "what the graph says about itself is what the reader sees in the words" {
    inline for (.{ Flat, Smooth, Textured, Modulated, Cutout }) |Shape| {
        switch (spirv.look(Shape.words, spirv.facet_profile)) {
            .fault => |fault| {
                std.debug.print("refused: {s}\n", .{@tagName(fault)});
                return error.TestUnexpectedResult;
            },
            .seen => |seen| {
                try std.testing.expectEqual(spirv.ExecutionModel.fragment, seen.stage);
                try std.testing.expectEqual(@as(u32, 1), seen.outputs);
                try std.testing.expectEqual(Shape.graph.inputs.len, seen.inputs);
                try std.testing.expectEqual(Shape.graph.sampled.len, seen.samplers);
                try std.testing.expectEqual(Shape.discards, seen.discards);
            },
        }
    }
}

// --- the function the cores run --------------------------------------------

/// A batch to colour: one quad at the tile's corner, every pixel covered,
/// and planes that are flat - 1 / w of 1 everywhere - so that
/// interpolation is exact and a comparison with a fixed form is of the
/// arithmetic and nothing else.
const Batch = struct {
    quads: [4]shader.Quad,
    colors: [4][4]u32,
    planes: [9]shader.Plane,
    resources: shader.Resources,
    count: u32,

    fn flat(count: u32, values: []const f32) Batch {
        var made = Batch{
            .quads = undefined,
            .colors = @splat(@splat(0)),
            .planes = @splat(.{ .origin = 0, .dx = 0, .dy = 0 }),
            .resources = .{},
            .count = count,
        };
        for (&made.quads, 0..) |*quad, k| quad.* = .{ .x = @intCast(2 * k), .y = 0, .covered = 0xF, .kept = 0xF };
        made.planes[0] = .{ .origin = 1, .dx = 0, .dy = 0 };
        for (values, 0..) |value, k| made.planes[1 + k] = .{ .origin = value, .dx = 0, .dy = 0 };
        return made;
    }

    fn fragments(batch: *Batch, planes: u32) shader.Fragments {
        return .{
            .quads = &batch.quads,
            .count = batch.count,
            .colors = &batch.colors,
            .planes = &batch.planes,
            .plane_count = planes,
            .x = 0,
            .y = 0,
            .exact = true,
            .resources = &batch.resources,
        };
    }
};

test "a generated colour of its own" {
    var batch = Batch.flat(1, &.{});
    const made = batch.fragments(1);
    Flat.function(&made);
    try std.testing.expectEqual(@as(u32, 0xFFFF_0000), batch.colors[0][0]);
    try std.testing.expectEqual(@as(u32, 0xFFFF_0000), batch.colors[0][3]);
}

test "a generated interpolated colour against shader.smooth, bit for bit" {
    // The fixed form's varyings carry a channel already scaled by
    // `shader.channel`; a generated shader's carry 0 to 1 and the scaling
    // is in the function. With 1 / w flat the two are the same arithmetic,
    // so the colours have to be the same bits - which is the whole claim
    // this test makes.
    const channels = [_][4]f32{
        .{ 1, 0, 0, 1 },
        .{ 0, 0.5, 0.25, 1 },
        .{ 0.125, 0.375, 0.625, 0.875 },
        .{ 0, 0, 0, 0 },
    };
    for (channels) |colour| {
        var mine = Batch.flat(1, &colour);
        const made = mine.fragments(5);
        Smooth.function(&made);

        var theirs = Batch.flat(1, &.{
            shader.channel(colour[0]),
            shader.channel(colour[1]),
            shader.channel(colour[2]),
            shader.channel(colour[3]),
        });
        const fixed = theirs.fragments(5);
        shader.smooth(&fixed);

        for (0..4) |pixel| {
            if (mine.colors[0][pixel] != theirs.colors[0][pixel]) {
                std.debug.print("{any}: generated 0x{X:0>8}, smooth 0x{X:0>8}\n", .{ colour, mine.colors[0][pixel], theirs.colors[0][pixel] });
                return error.TestExpectedEqual;
            }
        }
    }
}

test "a generated shader holds a colour inside its channel" {
    // Arithmetic of a shader's own can leave 0 to 1 - this one doubles a
    // channel - and what reaches the tile is held inside, as a fixed
    // form's is, rather than wrapping or trapping.
    const Doubled = ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            b.color(b.mul(b.input(0, .f32x4), b.constant(.{ 2, 2, 2, 2 })));
        }
    });
    var batch = Batch.flat(1, &.{ 0.75, 0.25, 0, 1 });
    const made = batch.fragments(5);
    Doubled.function(&made);
    // 1.5 and 2 are held at 255; 0.5 is 0.5 * 255 + 0.5, which cut to a
    // whole number is 128; 0 is 0.
    try std.testing.expectEqual(@as(u32, 0xFFFF_8000), batch.colors[0][0]);
}

test "a generated shader drops the pixels it says it does" {
    // Two by two, alpha falling across the quad: the two pixels under a
    // half lose their `kept` bit, the other two keep theirs.
    const Dropping = ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const colour = b.input(0, .f32x4);
            b.discardIf(b.lessThan(b.component(colour, 3), b.scalar(0.5)));
            b.color(colour);
        }
    });
    var batch = Batch.flat(1, &.{ 1, 1, 1, 0 });
    // Alpha 0 at the left of the quad, 1 at its right.
    batch.planes[4] = .{ .origin = 0, .dx = 1, .dy = 0 };
    const made = batch.fragments(5);
    Dropping.function(&made);
    // Pixels 0 and 2 are the left column, where alpha is 0.
    try std.testing.expectEqual(@as(u8, 0b1010), batch.quads[0].kept);
}

test "a graph of its own is still a module a reader takes" {
    const Lit = ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const colour = b.input(0, .f32x4);
            const light = b.input(1, .f32x1);
            b.color(b.scale(colour, light));
        }
    });
    try std.testing.expectEqual(@as(u32, 5), Lit.varyings);
    switch (spirv.look(Lit.words, spirv.facet_profile)) {
        .fault => return error.TestUnexpectedResult,
        .seen => |seen| try std.testing.expectEqual(@as(u32, 2), seen.inputs),
    }
    // And it paints: a white colour at half light is grey.
    var batch = Batch.flat(1, &.{ 1, 1, 1, 1, 0.5 });
    const made = batch.fragments(6);
    Lit.function(&made);
    try std.testing.expectEqual(@as(u32, 0x8080_8080), batch.colors[0][0]);
}

/// A varying of one float, which is a float and not a vector of one:
/// SPIR-V has no vector of one component, and facet wrote one until the
/// QPU back end's reader turned such a module down.
const Dimmed = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.scale(b.input(0, .f32x4), b.input(1, .f32x1)));
    }
});

test "a varying of one float is a float: the module Khronos' validator takes" {
    try expectWords(&reference.min_scaled, Dimmed.words);
    try std.testing.expectEqual(@as(u32, 5), Dimmed.varyings);
}

// --- rung 4 for the sampler family -----------------------------------------
//
// The generated function that samples against `shader.textured`, which is
// the fixed form it mirrors. This is the half of rung 4 that could not be
// written until `ir.zig`'s `sampleAt` compiled: `function` is a lazy
// declaration and every sampling graph in the tree had been asked only
// for its `.words`, so it had never been instantiated at all.

const nearest: texture.Sampling = .{ .format = .argb8888, .filter = .nearest };
const bilinear: texture.Sampling = .{ .format = .argb8888, .filter = .bilinear };

const Near = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.sampleBy(0, 0, b.input(0, .f32x2), nearest));
    }
});

const Mixed = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.sampleBy(0, 0, b.input(0, .f32x2), bilinear));
    }
});

var texels: [64 * 8]u8 align(8) = undefined;

/// Eight by eight, no two alike and no two a swap of x and y apart, so
/// neither picking the wrong texel nor swapping the axes can go unseen.
fn texelAt(x: u32, y: u32) u32 {
    return 0xFF00_0000 | (x * 36) << 16 | (y * 36) << 8 | ((x ^ y) * 36);
}

/// One quad of four pixels drawn twice over the same texture at the same
/// coordinates: by the graph's own function, and by the fixed form. The
/// planes are flat in 1 / w, so the interpolation is exact and what is
/// left between the two is the sampling and nothing else.
fn bothWays(comptime Shape: type, comptime sampling: texture.Sampling, u: shader.Plane, v: shader.Plane) [2][4]u32 {
    var picture = texture.Texture.init(sampling.format, 8, 8, 1, &texels) catch unreachable;
    for (0..8) |y| for (0..8) |x| {
        picture.setColor(0, 0, @intCast(x), @intCast(y), texelAt(@intCast(x), @intCast(y)));
    };
    const slots = [1]shader.Slot{.{ .pointer = &picture }};
    const firsts = [2]u16{ 0, 1 };
    const set = shader.Set{ .first = &firsts, .binding_count = 1, .slots = &slots };
    var resources = shader.Resources{};
    resources.sets[0] = &set;

    var quads = [1]shader.Quad{.{ .x = 0, .y = 0, .covered = 0xF, .kept = 0xF }};
    var planes = [3]shader.Plane{ .{ .origin = 1, .dx = 0, .dy = 0 }, u, v };
    var generated = [1][4]u32{@splat(0)};
    var fixed = [1][4]u32{@splat(0)};
    const mine = shader.Fragments{
        .quads = &quads,
        .count = 1,
        .colors = &generated,
        .planes = &planes,
        .plane_count = 3,
        .x = 0,
        .y = 0,
        .exact = true,
        .resources = &resources,
    };
    Shape.function(&mine);
    const theirs = shader.Fragments{
        .quads = &quads,
        .count = 1,
        .colors = &fixed,
        .planes = &planes,
        .plane_count = 3,
        .x = 0,
        .y = 0,
        .exact = true,
        .resources = &resources,
    };
    shader.textured(sampling, &theirs, &picture);
    return .{ fixed[0], generated[0] };
}

test "a generated sampling function at the nearest texel is the fixed form, bit for bit" {
    // Equality and not nearness, which is why `nearest` is the one held
    // this way: the fixed form picks its texel in 1/256ths
    // (`texture.place`, then a shift) and the generated function in
    // floats (`@floor(u * 8)`), scaling by 256 is exact in binary, and
    // `trunc(256 y) >> 8` is `@floor(y)` for y >= 0 - so the two pick the
    // same texel. A byte through `ir.bytesOf(b / 255)` comes back as `b`
    // for all 256 of them, so the texel's colour survives the trip
    // through the graph's floats.
    var apart: u32 = 0;
    var cases: u32 = 0;
    for (0..17) |a| for (0..17) |b| {
        const u = shader.Plane{ .origin = @as(f32, @floatFromInt(a)) / 16, .dx = 0.07, .dy = 0.11 };
        const v = shader.Plane{ .origin = @as(f32, @floatFromInt(b)) / 16, .dx = 0.13, .dy = 0.03 };
        const fixed, const generated = bothWays(Near, nearest, u, v);
        cases += 1;
        for (fixed, generated) |want, made| if (want != made) {
            std.debug.print("u={d}/16 v={d}/16: fixed 0x{X:0>8}, generated 0x{X:0>8}\n", .{ a, b, want, made });
            apart += 1;
        };
    };
    try std.testing.expectEqual(@as(u32, 289), cases);
    try std.testing.expectEqual(@as(u32, 0), apart);
}

test "a generated sampling function that mixes is the fixed form to within a step of two" {
    // Not bit for bit, and it cannot be: `ir.zig`'s `sampleAt` asks the
    // texture for a whole mixed colour, and `texture.sampleLayer` mixes
    // across and then down with a rounding at each step, where the
    // generated function then takes that colour back into floats and out
    // again. Two of 255 is what those roundings come to here, which is
    // written down so that a change in either mix is noticed.
    var worst: u32 = 0;
    for (0..17) |a| for (0..17) |b| {
        const u = shader.Plane{ .origin = @as(f32, @floatFromInt(a)) / 16, .dx = 0.07, .dy = 0.11 };
        const v = shader.Plane{ .origin = @as(f32, @floatFromInt(b)) / 16, .dx = 0.13, .dy = 0.03 };
        const fixed, const generated = bothWays(Mixed, bilinear, u, v);
        for (fixed, generated) |want, made| {
            inline for (0..4) |channel| {
                const shift = channel * 8;
                const one = want >> shift & 0xFF;
                const other = made >> shift & 0xFF;
                worst = @max(worst, if (one > other) one - other else other - one);
            }
        }
    };
    try std.testing.expect(worst <= 2);
}

/// `bothWays`, but with a sampler bound beside the texture, and the
/// generated function alone: what it draws is then the *sampler's*
/// answer, whatever the graph asked for.
fn throughSampler(comptime Shape: type, sampler: *const texture.Sampler, u: shader.Plane, v: shader.Plane) [4]u32 {
    var picture = texture.Texture.init(.argb8888, 8, 8, 1, &texels) catch unreachable;
    for (0..8) |y| for (0..8) |x| {
        picture.setColor(0, 0, @intCast(x), @intCast(y), texelAt(@intCast(x), @intCast(y)));
    };
    const slots = [1]shader.Slot{.{ .pointer = &picture, .sampler = sampler }};
    const firsts = [2]u16{ 0, 1 };
    const set = shader.Set{ .first = &firsts, .binding_count = 1, .slots = &slots };
    var resources = shader.Resources{};
    resources.sets[0] = &set;

    var quads = [1]shader.Quad{.{ .x = 0, .y = 0, .covered = 0xF, .kept = 0xF }};
    var planes = [3]shader.Plane{ .{ .origin = 1, .dx = 0, .dy = 0 }, u, v };
    var out = [1][4]u32{@splat(0)};
    const made = shader.Fragments{
        .quads = &quads,
        .count = 1,
        .colors = &out,
        .planes = &planes,
        .plane_count = 3,
        .x = 0,
        .y = 0,
        .exact = true,
        .resources = &resources,
    };
    Shape.function(&made);
    return out[0];
}

test "a generated shader samples as the draw's sampler says, not as the graph asked" {
    // The point of `texture.samplingOf` being in neither device: Vulkan
    // puts filtering in the sampler object and SPIR-V has nowhere to
    // carry what a graph asked for, so the V3D reads the bound sampler.
    // If the cores read the graph instead, one pipeline would draw two
    // ways depending on which device took it - and nothing would say so,
    // because both pictures look reasonable.
    const u = shader.Plane{ .origin = 0.3125, .dx = 0.07, .dy = 0.11 };
    const v = shader.Plane{ .origin = 0.4375, .dx = 0.13, .dy = 0.03 };

    // `Mixed` asked for bilinear. With a NEAREST sampler bound it has to
    // paint what `Near` paints with the same sampler.
    const near: texture.Sampler = .{ .mag_filter = .nearest, .min_filter = .nearest };
    try std.testing.expectEqualSlices(u32, &throughSampler(Near, &near, u, v), &throughSampler(Mixed, &near, u, v));
    // And `Near`, which asked for nearest, has to mix where the bound
    // sampler says bilinear - so the two are not simply always equal.
    const mixing: texture.Sampler = .{};
    const mixed = throughSampler(Near, &mixing, u, v);
    try std.testing.expect(!std.mem.eql(u32, &mixed, &throughSampler(Near, &near, u, v)));
    try std.testing.expectEqualSlices(u32, &mixed, &throughSampler(Mixed, &mixing, u, v));

    // A sampler asking for something a `Sampling` cannot say is drawn by
    // neither device: the pixel is `shader.missing`, which is a wrong
    // colour on purpose rather than two devices quietly drawing
    // different right ones. `mirrored_repeat` is one of the three wraps
    // the TMU's state has no word for.
    const beyond: texture.Sampler = .{ .wrap = .{ .mirrored_repeat, .mirrored_repeat, .mirrored_repeat } };
    for (throughSampler(Near, &beyond, u, v)) |pixel| {
        try std.testing.expectEqual(shader.missing, pixel);
    }
}
