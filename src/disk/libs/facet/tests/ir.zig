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

/// A depth compared with the reference the vertices carry, (1, 0, 0, 1)
/// times what passed: `min_shadow` (since 1.143).
const Shadowed = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.scale(b.constant(.{ 1, 0, 0, 1 }), b.sampleCompared(0, 0, b.input(0, .f32x2), b.input(1, .f32x1))));
    }
});

/// The same with alpha 1, which is the colour the fixed form
/// `texture_shadow` draws through a view of a depth: what passed in red.
const ShadowedOpaque = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const passed = b.sampleCompared(0, 0, b.input(0, .f32x2), b.input(1, .f32x1));
        b.color(b.add(b.scale(b.constant(.{ 1, 0, 0, 0 }), passed), b.constant(.{ 0, 0, 0, 1 })));
    }
});

test "a shadow sample is the module an assembler writes: a depth image, and the reference its own operand" {
    try expectWords(&reference.min_shadow, Shadowed.words);
    try std.testing.expectEqual(@as(u32, 3), Shadowed.varyings);
    try std.testing.expectEqual(@as(usize, 1), Shadowed.graph.sampled.len);
    try std.testing.expect(Shadowed.graph.sampled[0].compared);
}

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
    inline for (.{ Flat, Smooth, Textured, Modulated, Cutout, Shadowed, ShadowedOpaque }) |Shape| {
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

/// The colour the vertices carry times a float of the push constants,
/// plus a vector of them: a block of a `vec4` at 0 and a `float` at 16
/// (since 1.138).
const PushTinted = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.add(b.scale(b.input(0, .f32x4), b.push(16, .f32x1)), b.push(0, .f32x4)));
    }
});

/// What PushTinted comes to on a pixel whose colour is (0.5, 0.25, 0, 1),
/// pushed (0, 0.25, 0.5, 0) and 0.5: every product and sum of it exact.
const PushTintedMade = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.constant(.{ 0.25, 0.375, 0.5, 0.5 }));
    }
});

test "the push constants are a block the reader counts, in the words Khronos' validator takes" {
    try expectWords(&reference.min_push, PushTinted.words);
    try std.testing.expectEqual(@as(u32, 4), PushTinted.varyings);
    try std.testing.expectEqual(@as(usize, 2), PushTinted.graph.pushes.len);
    switch (spirv.look(PushTinted.words, spirv.facet_profile)) {
        .fault => |fault| {
            std.debug.print("refused: {s}\n", .{@tagName(fault)});
            return error.TestUnexpectedResult;
        },
        .seen => |seen| {
            try std.testing.expectEqual(@as(u32, 1), seen.push_constants);
            try std.testing.expectEqual(@as(u32, 1), seen.inputs);
        },
    }
}

test "a generated colour reads the push constants the draw set, at their offsets" {
    var mine = Batch.flat(1, &.{ 0.5, 0.25, 0, 1 });
    const tint = [4]f32{ 0, 0.25, 0.5, 0 };
    const light: f32 = 0.5;
    @memcpy(mine.resources.push[0..16], std.mem.asBytes(&tint));
    @memcpy(mine.resources.push[16..20], std.mem.asBytes(&light));
    const made = mine.fragments(5);
    PushTinted.function(&made);

    var theirs = Batch.flat(1, &.{});
    const constant = theirs.fragments(1);
    PushTintedMade.function(&constant);
    try std.testing.expectEqualSlices(u32, &theirs.colors[0], &mine.colors[0]);
    // And nothing pushed is nothing added and nothing to scale by.
    var zero = Batch.flat(1, &.{ 0.5, 0.25, 0, 1 });
    const unpushed = zero.fragments(5);
    PushTinted.function(&unpushed);
    try std.testing.expectEqual(@as(u32, 0), zero.colors[0][0]);
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

/// The nearest texel at a constant offset from it, in texels: SPIR-V's
/// `ConstOffset`, which every Vulkan 1.0 implementation takes on an
/// `OpImageSample*` (item 28). A type for each offset, because the offset
/// is part of the graph and the graph is comptime.
fn Offset(comptime at: [2]i32) type {
    return ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            b.color(b.sampleOffsetBy(0, 0, b.input(0, .f32x2), nearest, at));
        }
    });
}

/// The same through whatever sampler is bound, for the slow path: a
/// sampler no `Sampling` can say sends the sample through
/// `texture.sampleBy`, which applies the offset in a different place
/// again (`sampledAt`), so both paths have to be held.
fn OffsetAnyhow(comptime at: [2]i32) type {
    return ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            b.color(b.sampleOffset(0, 0, b.input(0, .f32x2), at));
        }
    });
}

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

    // A sampler asking for something a `Sampling` cannot say used to be
    // drawn by neither device - the pixel was `shader.missing`, a wrong
    // colour on purpose - and since 1.83 the cores carry the whole
    // sampler instead. `mirrored_repeat` is one of the three wraps the
    // TMU's state has no word for, so it is on the slow path and must
    // still paint a colour of the texture.
    const beyond: texture.Sampler = .{ .wrap = @splat(.mirrored_repeat) };
    for (throughSampler(Near, &beyond, u, v)) |pixel| {
        try std.testing.expect(pixel != shader.missing);
    }
}

/// Four levels of an 8x8 texture, each level a flat colour of its own, so
/// that which level a sample read is visible in what it painted.
var levelled: [1024]u8 align(8) = undefined;

/// One quad drawn twice over the same four-level texture with the same
/// sampler bound: by the graph's own function, and by the fixed form
/// `shader.texturedBy`, which is the one the cores reach for a sampled
/// form. Both take the whole of the sampler through `texture.sampleBy`,
/// so what comes back has to agree.
fn bothThroughSampler(comptime Shape: type, sampler: *const texture.Sampler, u: shader.Plane, v: shader.Plane) [2][4]u32 {
    var picture = texture.Texture.init(.argb8888, 8, 8, 4, &levelled) catch unreachable;
    for (0..4) |lod| {
        const side = @as(u32, 8) >> @intCast(lod);
        for (0..side) |y| for (0..side) |x| {
            // The level in the red channel and the texel in the other
            // two, so a mixed level and a mixed texel are both visible.
            picture.setColor(0, @intCast(lod), @intCast(x), @intCast(y), 0xFF00_0000 |
                @as(u32, @intCast(lod * 60)) << 16 |
                @as(u32, @intCast(x * 36)) << 8 |
                @as(u32, @intCast(y * 36)));
        };
    }
    const slots = [1]shader.Slot{.{ .pointer = &picture, .sampler = sampler }};
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
    // The form's own `sampling` is ignored by `texturedBy`, which takes
    // everything from the sampler - which is the whole point of it.
    shader.texturedBy(false, .{}, &theirs, &picture, sampler);
    return .{ fixed[0], generated[0] };
}

test "a sampler no Sampling can say is drawn by the cores, as the fixed form draws it" {
    // Until 1.83 every one of these painted `shader.missing` on both
    // devices: `texture.samplingOf` cannot collapse any of them into a
    // `Sampling`, and the IR dropped the texture when it could not. The
    // cores carry the sampler whole now and take it through
    // `texture.sampleBy` - the same call the fixed form makes - so the
    // two have to paint the same thing, bit for bit, and neither may
    // paint magenta. The V3D samples each of them through its TMU since
    // 1.140, and FacetBoth compares the two on the board.
    const u = shader.Plane{ .origin = 0.3125, .dx = 0.07, .dy = 0.11 };
    const v = shader.Plane{ .origin = 0.4375, .dx = 0.13, .dy = 0.03 };
    const beyond = [_]struct { what: []const u8, sampler: texture.Sampler }{
        // The three wraps a `Sampling`'s `Address` has no word for.
        .{ .what = "mirrored_repeat", .sampler = .{ .wrap = @splat(.mirrored_repeat) } },
        .{ .what = "clamp_to_border", .sampler = .{ .wrap = @splat(.clamp_to_border), .border = 0xFF00_FF00 } },
        .{ .what = "mirror_clamp_to_edge", .sampler = .{ .wrap = @splat(.mirror_clamp_to_edge) } },
        // One wrap across and another down, which a `Sampling` has one of.
        .{ .what = "two wraps", .sampler = .{ .wrap = .{ .repeat, .clamp_to_edge, .repeat } } },
        // A filter each way, likewise.
        .{ .what = "two filters", .sampler = .{ .mag_filter = .nearest, .min_filter = .bilinear } },
        // The levels: mixed, shifted, and held.
        .{ .what = "linear mipmapping", .sampler = .{ .mipmap = .linear } },
        .{ .what = "a lod bias", .sampler = .{ .lod_bias = 1.5 } },
        .{ .what = "a lod clamp", .sampler = .{ .min_lod = 1, .max_lod = 2 } },
        // Several samples along the longer axis.
        .{ .what = "anisotropy", .sampler = .{ .anisotropy = 4 } },
        // A comparison, which the graph has no reference for, so it is
        // made against 0 - undefined by Vulkan, which forbids the
        // pairing, and the same undefined thing the fixed form does,
        // which is what this test is for.
        .{ .what = "a comparison", .sampler = .{ .compare = .less } },
        // Coordinates in texels rather than 0 to 1.
        .{ .what = "unnormalized coordinates", .sampler = .{
            .unnormalized = true,
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .max_lod = 0,
            .wrap = @splat(.clamp_to_edge),
        } },
    };
    for (beyond) |each| {
        // It is on the slow path at all: that is what this tests, and a
        // sampler that quietly collapsed would make the rest vacuous.
        try std.testing.expectEqual(@as(?texture.Sampling, null), texture.samplingOf(&each.sampler, .argb8888));
        const fixed, const generated = bothThroughSampler(Near, &each.sampler, u, v);
        for (fixed, generated, 0..) |want, made, pixel| {
            if (want != made) {
                std.debug.print("{s}, pixel {d}: the fixed form 0x{X:0>8}, the generated 0x{X:0>8}\n", .{ each.what, pixel, want, made });
            }
            try std.testing.expectEqual(want, made);
            try std.testing.expect(made != shader.missing);
        }
        // And the graph's own sampling no longer decides anything, so a
        // graph that asked to mix paints what one that asked for the
        // nearest texel paints.
        const mixed_fixed, const mixed_generated = bothThroughSampler(Mixed, &each.sampler, u, v);
        try std.testing.expectEqualSlices(u32, &mixed_fixed, &mixed_generated);
        try std.testing.expectEqualSlices(u32, &generated, &mixed_generated);
    }
}

// --- 1.87: a constant texel offset -----------------------------------------

/// The offsets held: the four unit steps, a pair of each sign, and the two
/// ends of Vulkan's required range, which reaches one further down than up.
const offsets = [_][2]i32{
    .{ 1, 0 },  .{ 0, 1 },  .{ -1, 0 }, .{ 0, -1 },
    .{ 2, -3 }, .{ -3, 2 }, .{ 7, 7 },  .{ -8, -8 },
    .{ -8, 7 }, .{ 7, -8 },
};

test "a generated shader samples at the constant offset it was built with, on both paths" {
    // The test is a coordinate moved against a texel offset: on an 8-wide
    // texture, sampling at (u, v) with an offset of (dx, dy) must read
    // exactly the texel that sampling at (u + dx/8, v + dy/8) with no
    // offset reads, because `nearest` takes floor(u * 8) and
    // floor(u * 8 + dx) is floor(u * 8) + dx for a whole dx.
    //
    // This is the test the feature can be shipped green without. The
    // offset lives in `ir.Op`, which is comptime, and every other
    // sampling test in this file compares a generated function against a
    // fixed form - and no fixed form has an offset. So if the offset were
    // recorded in the graph, emitted into the words, reported in the
    // limits and never once passed to `sampleLayerAt`, all of them would
    // still pass and the cores would quietly ignore it.
    const u = shader.Plane{ .origin = 0.3125, .dx = 0.07, .dy = 0.11 };
    const v = shader.Plane{ .origin = 0.4375, .dx = 0.13, .dy = 0.03 };

    // The fast path: a sampler `texture.samplingOf` collapses, so the
    // sample goes through `Texture.sampleLayerAt`.
    const collapses: texture.Sampler = .{ .mag_filter = .nearest, .min_filter = .nearest };
    // And the slow path: `mirrored_repeat` is one of the three wraps a
    // `Sampling` has no word for, so the whole sampler is carried and the
    // sample goes through `texture.sampleBy` instead (1.83).
    const does_not: texture.Sampler = .{
        .wrap = @splat(.mirrored_repeat),
        .mag_filter = .nearest,
        .min_filter = .nearest,
    };
    try std.testing.expectEqual(@as(?texture.Sampling, null), texture.samplingOf(&does_not, .argb8888));
    try std.testing.expect(texture.samplingOf(&collapses, .argb8888) != null);

    inline for (offsets) |at| {
        const moved_u = shader.Plane{ .origin = u.origin + @as(f32, @floatFromInt(at[0])) / 8, .dx = u.dx, .dy = u.dy };
        const moved_v = shader.Plane{ .origin = v.origin + @as(f32, @floatFromInt(at[1])) / 8, .dx = v.dx, .dy = v.dy };
        inline for ([2]*const texture.Sampler{ &collapses, &does_not }) |each| {
            const offset_drawn = throughSampler(Offset(at), each, u, v);
            const coordinate_moved = throughSampler(Near, each, moved_u, moved_v);
            if (!std.mem.eql(u32, &offset_drawn, &coordinate_moved)) {
                std.debug.print("offset ({d}, {d}): drew {any}, where moving the coordinate drew {any}\n", .{ at[0], at[1], offset_drawn, coordinate_moved });
            }
            try std.testing.expectEqualSlices(u32, &coordinate_moved, &offset_drawn);
            // And it is not the un-offset picture, or the whole test
            // would hold for an offset that was thrown away. Not for an
            // offset that is a whole turn of this texture on both axes,
            // though: -8 on an eight-wide texture that repeats reads the
            // very texel it started from, and reading it is right.
            if (at[0] & 7 != 0 or at[1] & 7 != 0) {
                try std.testing.expect(!std.mem.eql(u32, &offset_drawn, &throughSampler(Near, each, u, v)));
            }
        }
    }
}

test "a constant texel offset is in the words, as the one image operand facet writes" {
    const Shape = Offset(.{ 1, -2 });
    // The library's own profile takes it, because the cores apply it:
    // `CreateShaderModule` must not turn away a module this library's own
    // builder writes.
    switch (spirv.look(Shape.words, spirv.facet_profile)) {
        .seen => {},
        .fault => |fault| {
            std.debug.print("the library refused a module it wrote itself: {s}\n", .{@tagName(fault)});
            return error.TestUnexpectedResult;
        },
    }

    // The instruction carries the mask and one id where a graph with no
    // offset carries neither, and there is exactly one sample either way.
    var found: u32 = 0;
    var reader = spirv.Reader.of(Shape.words);
    while (try reader.next()) |instruction| {
        if (instruction.op != .image_sample_implicit_lod) continue;
        found += 1;
        const operands = instruction.operands();
        try std.testing.expectEqual(@as(usize, 6), operands.len);
        try std.testing.expectEqual(@intFromEnum(spirv.ImageOperands.const_offset), operands[4]);
    }
    try std.testing.expectEqual(@as(u32, 1), found);

    var plain: u32 = 0;
    var walk = spirv.Reader.of(Textured.words);
    while (try walk.next()) |instruction| {
        if (instruction.op != .image_sample_implicit_lod) continue;
        plain += 1;
        try std.testing.expectEqual(@as(usize, 4), instruction.operands().len);
    }
    try std.testing.expectEqual(@as(u32, 1), plain);

    // Word for word against a module written by hand as SPIR-V assembly,
    // assembled by Khronos' own tool and accepted by Khronos' own
    // validator under Vulkan 1.0 - so these are not facet's idea of a
    // ConstOffset module, they are one (`tests/spirv_reference.zig`,
    // `scripts/spirv-check.sh`).
    try expectWords(&reference.min_offset, Shape.words);

    // An offset of nothing is no operand at all: the reference modules
    // are held word for word, the id bound among them, so a `.{ 0, 0 }`
    // that allocated an integer type would fail every one of them.
    try expectWords(Textured.words, Offset(.{ 0, 0 }).words);

    // The reader is what refuses the operands no device here answers for,
    // and it refuses them by the profile and not by the opcode: the same
    // module with the mask changed to a lod, or to a lod beside the
    // offset, comes back refused.
    var patched: [256]u32 = undefined;
    try std.testing.expect(Shape.words.len <= patched.len);
    const sample_word: u32 = 7 << 16 | @as(u32, @intFromEnum(spirv.Op.image_sample_implicit_lod));
    const at = std.mem.indexOfScalar(u32, Shape.words, sample_word) orelse return error.TestUnexpectedResult;
    for ([_]u32{ 2, 2 | 8, 1, 16 }) |mask| {
        @memcpy(patched[0..Shape.words.len], Shape.words);
        patched[at + 5] = mask;
        const answer = spirv.look(patched[0..Shape.words.len], spirv.facet_profile);
        try std.testing.expectEqual(spirv.Fault.image_operand_refused, answer.fault);
        // And it is the unsupported tier, not the malformed one: another
        // device may yet run those words.
        try std.testing.expect(!answer.fault.malformed());
    }
}

/// A graph carrying every varying the library takes: sixteen locations of
/// four floats, which is `shader.MAX_VARYINGS`. The bound `ir.Build.input`
/// holds a graph to is a `@compileError`, so there is no way to assert
/// that one past it is refused - what can be asserted is that one *at* it
/// builds, which is what says the bound is 64 and not the 8 it was until
/// 1.90. Item 17 of docs/facet-vulkan10.md.
const Widest = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        var sum = b.input(0, .f32x4);
        inline for (1..shader.MAX_VARYINGS / 4) |location| {
            sum = b.add(sum, b.input(location, .f32x4));
        }
        b.color(sum);
    }
});

test "a graph carrying every varying the library takes: built, and a module a device would read" {
    // The graph's own count, the entry's low 8 bits, and the limit the
    // cores report are one number.
    try std.testing.expectEqual(@as(u32, shader.MAX_VARYINGS), Widest.varyings);
    const entry = Widest.entry("main");
    try std.testing.expectEqual(@as(u32, shader.MAX_VARYINGS), entry.varyingCount());
    // Sixty-four fits in the low 8 bits with room over, so the fixed-form
    // bits above them are untouched - which is the half of this item's
    // description that was wrong about needing to move.
    try std.testing.expectEqual(shader.FixedKind.none, entry.fixed().?.kind);
    // And the words are a module: every input read, every id inside the
    // bound. `facet_profile` is the cores' own, which takes what this
    // library emits.
    switch (facet.spirv.look(Widest.words, facet.spirv.facet_profile)) {
        .seen => |seen| {
            // Sixteen inputs of four floats, which is what the graph
            // declares, and one colour out. Which locations they are is
            // a back end's to read beside each variable, as the V3D's
            // does: until 1.95 `look` said it as well, and said the
            // largest location decorated for both sides, sixteen where
            // this graph has one output (item 84 of
            // docs/facet-vulkan10.md).
            try std.testing.expectEqual(@as(u32, shader.MAX_VARYINGS / 4), seen.inputs);
            try std.testing.expectEqual(@as(u32, 1), seen.outputs);
        },
        .fault => |fault| {
            std.debug.print("the widest graph is not a module: {t}\n", .{fault});
            return error.TestUnexpectedResult;
        },
    }
}

// --- a shadow sample (since 1.143) -------------------------------------------

/// An 8x8 depth, a slope from 0 at the top left to about 0.9 at the bottom
/// right, so that a reference across a quad passes at some pixels and not
/// at others.
var depths: [8 * 8 * 2]u8 align(8) = undefined;

/// One quad compared twice with the same depth, sampler and reference: by
/// the graph's own function and by the fixed form `texture_shadow`
/// (`shader.texturedBy` with `shadow`), which both take the sampler whole
/// through `texture.sampleBy`. The texture reads as a view of a depth
/// does, green and blue 0 and alpha 1 (`createimageview.zig`'s
/// `depthRead`).
fn bothCompared(sampler: *const texture.Sampler, u: shader.Plane, v: shader.Plane, r: shader.Plane) [2][4]u32 {
    var picture = texture.Texture.init(.d16, 8, 8, 1, &depths) catch unreachable;
    picture.swizzle = .{ .g = .zero, .b = .zero, .a = .one };
    for (0..8) |y| for (0..8) |x| {
        picture.setParts(0, 0, @intCast(x), @intCast(y), .{ @as(f32, @floatFromInt(x + y)) / 15.5, 0, 0, 0 });
    };
    const slots = [1]shader.Slot{.{ .pointer = &picture, .sampler = sampler }};
    const firsts = [2]u16{ 0, 1 };
    const set = shader.Set{ .first = &firsts, .binding_count = 1, .slots = &slots };
    var resources = shader.Resources{};
    resources.sets[0] = &set;

    var quads = [1]shader.Quad{.{ .x = 0, .y = 0, .covered = 0xF, .kept = 0xF }};
    var planes = [4]shader.Plane{ .{ .origin = 1, .dx = 0, .dy = 0 }, u, v, r };
    var generated = [1][4]u32{@splat(0)};
    var fixed = [1][4]u32{@splat(0)};
    const mine = shader.Fragments{ .quads = &quads, .count = 1, .colors = &generated, .planes = &planes, .plane_count = 4, .x = 0, .y = 0, .exact = true, .resources = &resources };
    ShadowedOpaque.function(&mine);
    const theirs = shader.Fragments{ .quads = &quads, .count = 1, .colors = &fixed, .planes = &planes, .plane_count = 4, .x = 0, .y = 0, .exact = true, .resources = &resources };
    shader.texturedBy(true, .{}, &theirs, &picture, sampler);
    return .{ fixed[0], generated[0] };
}

test "a generated shadow sample is the fixed form texture_shadow, bit for bit, and compares as its sampler says" {
    // Across the slope, so that the depth under the four pixels differs
    // - from about 0.26 to 0.52 - and a reference between them.
    const u = shader.Plane{ .origin = 0.3, .dx = 0.13, .dy = 0.02 };
    const v = shader.Plane{ .origin = 0.35, .dx = 0.03, .dy = 0.15 };
    const r = shader.Plane{ .origin = 0.42, .dx = 0, .dy = 0 };
    const samplers = [_]texture.Sampler{
        .{ .mag_filter = .nearest, .min_filter = .nearest, .compare = .less },
        .{ .mag_filter = .nearest, .min_filter = .nearest, .compare = .greater },
        // Percentage-closer filtering: the four texels compared, what
        // passed mixed.
        .{ .compare = .less_or_equal },
    };
    var answers: [samplers.len][4]u32 = undefined;
    for (&samplers, &answers) |*sampler, *answer| {
        const both = bothCompared(sampler, u, v, r);
        try std.testing.expectEqualSlices(u32, &both[0], &both[1]);
        // Green and blue 0 and alpha 1 at every pixel: what passed is red.
        for (both[1]) |pixel| try std.testing.expectEqual(@as(u32, 0xFF00_0000), pixel & 0xFF00_FFFF);
        answer.* = both[1];
    }
    // At nearest, `less` and `greater` answer each pixel the other way
    // round, the reference never landing on a depth exactly here, and
    // both pass somewhere and fail somewhere.
    var passed_less: u32 = 0;
    for (answers[0], answers[1]) |less, greater| {
        try std.testing.expect((less == 0xFFFF_0000) != (greater == 0xFFFF_0000));
        if (less == 0xFFFF_0000) passed_less += 1;
    }
    try std.testing.expect(passed_less > 0 and passed_less < 4);
    // And a mix is a fraction somewhere: neither 0 nor 1 at one pixel.
    var mixed = false;
    for (answers[2]) |pixel| {
        const red = pixel >> 16 & 0xFF;
        if (red != 0 and red != 0xFF) mixed = true;
    }
    try std.testing.expect(mixed);
}
