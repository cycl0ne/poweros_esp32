// SPDX-License-Identifier: MIT
//! FacetBoth: the same frames through facet.library on the cores and on the
//! device after them, a CM5's V3D, and each pair compared pixel by pixel:
//! the cores are the reference. A case is a command buffer's worth - a kind
//! of draw, a piece of a pipeline's state, a render area, a format - in
//! pictures the program reads back. The cases called "shipped" draw with
//! fragment shaders whose SPIR-V the module ships beside the functions:
//! the cores run the functions, and the V3D compiles the words.
//!
//!   FacetBoth SIZE/K,ONLY/K
//!
//! Pictures are SIZE big, WIDTHxHEIGHT: 640x360 if not given. ONLY runs the
//! cases with that in their name. A job that never ends stops the V3D until
//! the program goes, and with it the cases after it. It prints for
//! each case how many pixels are further apart than two steps of a channel
//! (five for anisotropic filtering, whose samples Vulkan leaves to the
//! implementation), and returns WARN if any case has more than one in a
//! thousand, with a map
//! of where they are. Textures
//! are drawn no smaller than the level their pixels are on either way: the
//! two choose a level by different sums, and pictures of a texture turned
//! in depth are C:test/FacetCube's to look at. The cases of four samples
//! a pixel (since 1.16) draw into an image of four and resolve it into the
//! first picture, in the pass or by CmdResolveImage after it. The cases of
//! no colour (since 1.18) draw a depth alone, then look at it in a pass of
//! colour: a shadow map sampled, or a subpass after it tested against it;
//! and the cases of no attachment at all count what they draw with an
//! occlusion query, the two counts compared as well. The shipped cases of
//! float arithmetic (since 1.20) are of GLSL.std.450's calls, which the
//! V3D lowers as Mesa does, through an SFU that is not exact, and whose
//! roundings and Fract jump where a varying crosses a whole number: a
//! line of pixels a step apart there is the two devices' interpolation,
//! not a sum gone wrong. The shipped case of chosen floats (since 1.21)
//! is the same where a comparison turns over and Step jumps: Sin, Cos,
//! Tan, FSign, Step and SmoothStep, and OpSelect after each of the
//! comparisons glslc writes but >. The shipped case of selections (since
//! 1.22) is an `if` and `else` and a ternary of calls, which the V3D
//! flattens as Mesa does: both arms run, the merge chooses. The shipped
//! case of variables (since 1.23) is the same GLSL as glslc writes it
//! without -O, in variables of the function's own, which the V3D makes
//! values as Mesa does; the cores run the selections' function. The
//! shipped case of nested selections (since 1.24) is an `else if` and an
//! `if` and `else` in an arm, which the V3D flattens from the inside out.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const facet = sdk.facet;
const shader = facet.shader;
const ir = facet.ir;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const FacetBase = sdk.interface.facet.FacetBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "FacetBoth";
const VERSION_STRING = "\x00$VER: FacetBoth 1.24 (09.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "SIZE/K,ONLY/K";

const Failure = error{ NoMemory, NoDevice, Refused, DeviceLost };

const Vertex = extern struct {
    p: [4]f32,
    c: [4]f32,
    uv: [2]f32,
};

fn at(x: f32, y: f32, z: f32, c: [4]f32, u: f32, v: f32) Vertex {
    return .{ .p = .{ x, y, z, 1 }, .c = c, .uv = .{ u, v } };
}

const red = [4]f32{ 0.9, 0.1, 0.15, 1 };
const green = [4]f32{ 0.1, 0.8, 0.2, 1 };
const blue = [4]f32{ 0.15, 0.2, 0.9, 1 };
const yellow = [4]f32{ 0.9, 0.85, 0.1, 1 };
const see_through = [4]f32{ 0.9, 0.3, 0.1, 0.4 };

// What the cases draw: where each part of `geometry` starts, and it.
const clockwise_at = 0;
const counter_at = 3;
const strip_at = 6;
const fan_at = 11;
const far_at = 16;
const near_at = 19;
const glass_at = 22;
const quad_at = 25;
const wide_at = 31;
const behind_at = 37;

const geometry = [_]Vertex{
    // Clockwise on the picture, y down.
    at(-0.71, -0.63, 0.5, red, 0, 0),
    at(0.27, -0.52, 0.5, green, 1, 0),
    at(-0.33, 0.47, 0.5, blue, 0, 1),
    // The other way round.
    at(0.83, 0.71, 0.5, yellow, 0, 0),
    at(0.17, -0.11, 0.5, blue, 1, 0),
    at(0.09, 0.67, 0.5, green, 0, 1),
    // A strip.
    at(-0.81, 0.53, 0.5, red, 0, 0),
    at(-0.77, -0.47, 0.5, green, 0, 0),
    at(-0.23, 0.61, 0.5, blue, 0, 0),
    at(0.11, -0.59, 0.5, yellow, 0, 0),
    at(0.73, 0.43, 0.5, red, 0, 0),
    // A fan.
    at(0.03, 0.07, 0.5, yellow, 0, 0),
    at(-0.57, -0.73, 0.5, red, 0, 0),
    at(0.47, -0.67, 0.5, green, 0, 0),
    at(0.79, 0.21, 0.5, blue, 0, 0),
    at(-0.13, 0.77, 0.5, red, 0, 0),
    // Far, near and laid over.
    at(-0.73, -0.71, 0.75, blue, 0, 0),
    at(0.41, -0.57, 0.75, blue, 0, 0),
    at(-0.27, 0.59, 0.75, blue, 0, 0),
    at(-0.37, -0.31, 0.25, red, 0, 0),
    at(0.69, -0.17, 0.25, red, 0, 0),
    at(0.07, 0.83, 0.25, red, 0, 0),
    at(-0.51, -0.41, 0.5, see_through, 0, 0),
    at(0.57, -0.23, 0.5, see_through, 0, 0),
    at(-0.03, 0.69, 0.5, see_through, 0, 0),
    // A rectangle over most of the picture, its texture once.
    at(-0.71, -0.73, 0.5, red, 0, 0),
    at(0.73, -0.73, 0.5, green, 1, 0),
    at(-0.71, 0.77, 0.5, blue, 0, 1),
    at(0.73, -0.73, 0.5, green, 1, 0),
    at(0.73, 0.77, 0.5, yellow, 1, 1),
    at(-0.71, 0.77, 0.5, blue, 0, 1),
    // The same past the texture's edges.
    at(-0.71, -0.73, 0.5, red, -1.25, -1.25),
    at(0.73, -0.73, 0.5, green, 2.25, -1.25),
    at(-0.71, 0.77, 0.5, blue, -1.25, 2.25),
    at(0.73, -0.73, 0.5, green, 2.25, -1.25),
    at(0.73, 0.77, 0.5, yellow, 2.25, 2.25),
    at(-0.71, 0.77, 0.5, blue, -1.25, 2.25),
    // A corner behind the eye.
    .{ .p = .{ -0.61, -0.57, 0.3, 1 }, .c = red, .uv = .{ 0, 0 } },
    .{ .p = .{ 0.67, -0.49, 0.3, 1 }, .c = green, .uv = .{ 0, 0 } },
    .{ .p = .{ 0.1, 0.8, -0.5, -0.5 }, .c = blue, .uv = .{ 0, 0 } },
};

/// Index 0 to 4 of the strip, broken after the third.
const restart_indices = [_]u16{ 0, 1, 2, 0xFFFF, 2, 3, 4 };
const indices_16 = [_]u16{ 2, 1, 0 };
const indices_32 = [_]u32{ 0, 1, 2, 3, 4, 1 };
/// Added to each vertex's place, one for each instance.
const instance_places = [_][2]f32{ .{ 0, 0 }, .{ 0.31, 0.23 }, .{ -0.27, 0.19 } };

fn place(vertices: *const shader.Vertices, k: usize) [4]f32 {
    const p = vertices.input(@intCast(k), 0);
    const moved = vertices.input(@intCast(k), 3);
    return .{ p[0] + moved[0] * p[3], p[1] + moved[1] * p[3], p[2], p[3] };
}

fn colorVertex(vertices: *const shader.Vertices) callconv(.c) void {
    for (0..vertices.count) |k| {
        const p = place(vertices, k);
        const c = vertices.input(@intCast(k), 1);
        vertices.output(@intCast(k))[0..8].* = .{ p[0], p[1], p[2], p[3], shader.channel(c[0]), shader.channel(c[1]), shader.channel(c[2]), shader.channel(c[3]) };
    }
}

fn textureVertex(vertices: *const shader.Vertices) callconv(.c) void {
    for (0..vertices.count) |k| {
        const p = place(vertices, k);
        const uv = vertices.input(@intCast(k), 2);
        vertices.output(@intCast(k))[0..6].* = .{ p[0], p[1], p[2], p[3], uv[0], uv[1] };
    }
}

/// `textureVertex`'s, its coordinate scaled by `across` and `down`: the
/// texture several times over, so that its further levels are read, or
/// in texels.
fn scaledVertex(comptime across: f32, comptime down: f32) shader.VertexFn {
    return &struct {
        fn run(vertices: *const shader.Vertices) callconv(.c) void {
            for (0..vertices.count) |k| {
                const p = place(vertices, k);
                const uv = vertices.input(@intCast(k), 2);
                vertices.output(@intCast(k))[0..6].* = .{ p[0], p[1], p[2], p[3], uv[0] * across, uv[1] * down };
            }
        }
    }.run;
}

fn modulateVertex(vertices: *const shader.Vertices) callconv(.c) void {
    for (0..vertices.count) |k| {
        const p = place(vertices, k);
        const c = vertices.input(@intCast(k), 1);
        const uv = vertices.input(@intCast(k), 2);
        vertices.output(@intCast(k))[0..10].* = .{ p[0], p[1], p[2], p[3], uv[0], uv[1], shader.channel(c[0]), shader.channel(c[1]), shader.channel(c[2]), shader.channel(c[3]) };
    }
}

/// The place alone, for a fragment shader that reads no varyings.
fn placeVertex(vertices: *const shader.Vertices) callconv(.c) void {
    for (0..vertices.count) |k| vertices.output(@intCast(k))[0..4].* = place(vertices, k);
}

/// The colour as it is, 0 to 1, as a fragment shader the program ships
/// the SPIR-V of reads it: its function scales it where it writes a pixel
/// on the cores, and the V3D takes it as it is (1.76). Not
/// `shader.channel`, which a fixed form's vertex function calls.
fn asItIsVertex(vertices: *const shader.Vertices) callconv(.c) void {
    for (0..vertices.count) |k| {
        const p = place(vertices, k);
        const c = vertices.input(@intCast(k), 1);
        vertices.output(@intCast(k))[0..8].* = .{ p[0], p[1], p[2], p[3], c[0], c[1], c[2], c[3] };
    }
}

/// The colour as it is and a fifth float, the light, which falls off
/// along the texture's first coordinate.
fn dimmedVertex(vertices: *const shader.Vertices) callconv(.c) void {
    for (0..vertices.count) |k| {
        const p = place(vertices, k);
        const c = vertices.input(@intCast(k), 1);
        const uv = vertices.input(@intCast(k), 2);
        vertices.output(@intCast(k))[0..9].* = .{ p[0], p[1], p[2], p[3], c[0], c[1], c[2], c[3], 1 - 0.5 * uv[0] };
    }
}

/// `modulateVertex`'s coordinate and colour, the colour as it is.
fn modulateAsItIsVertex(vertices: *const shader.Vertices) callconv(.c) void {
    for (0..vertices.count) |k| {
        const p = place(vertices, k);
        const c = vertices.input(@intCast(k), 1);
        const uv = vertices.input(@intCast(k), 2);
        vertices.output(@intCast(k))[0..10].* = .{ p[0], p[1], p[2], p[3], uv[0], uv[1], c[0], c[1], c[2], c[3] };
    }
}

/// The quad's corner as a place at the middle of the picture, `scale` of its
/// size, without the instance's move: the instance here is a layer.
fn plain(vertices: *const shader.Vertices, k: usize, scale: f32) [4]f32 {
    const p = vertices.input(@intCast(k), 0);
    return .{ p[0] * scale, p[1] * scale, p[2], p[3] };
}

fn arrayVertex(vertices: *const shader.Vertices) callconv(.c) void {
    for (0..vertices.count) |k| {
        const p = plain(vertices, k, 1);
        const uv = vertices.input(@intCast(k), 2);
        vertices.output(@intCast(k))[0..7].* = .{ p[0], p[1], p[2], p[3], uv[0], uv[1], @floatFromInt(vertices.instance) };
    }
}

/// So small that its texture's further levels are read.
fn smallArrayVertex(vertices: *const shader.Vertices) callconv(.c) void {
    for (0..vertices.count) |k| {
        const p = plain(vertices, k, 0.1);
        const uv = vertices.input(@intCast(k), 2);
        vertices.output(@intCast(k))[0..7].* = .{ p[0], p[1], p[2], p[3], uv[0], uv[1], @floatFromInt(vertices.instance) };
    }
}

/// A cube's face as it would show flat, for instances 0 to 6; instance 6 looks
/// across the edge of two.
fn cubeVertex(vertices: *const shader.Vertices) callconv(.c) void {
    for (0..vertices.count) |k| {
        const p = plain(vertices, k, 1);
        const uv = vertices.input(@intCast(k), 2);
        const a = uv[0] * 2 - 1;
        const b = uv[1] * 2 - 1;
        const towards: [3]f32 = switch (vertices.instance) {
            0 => .{ 1, -b, -a },
            1 => .{ -1, -b, a },
            2 => .{ a, 1, b },
            3 => .{ a, -1, -b },
            4 => .{ a, -b, 1 },
            5 => .{ -a, -b, -1 },
            else => .{ 1 - uv[0], -b * 0.7, uv[0] },
        };
        vertices.output(@intCast(k))[0..7].* = .{ p[0], p[1], p[2], p[3], towards[0], towards[1], towards[2] };
    }
}

/// A slice of a 3D texture for each instance up to its depth; past that, from
/// the first slice on the left to the last on the right.
fn volumeVertex(vertices: *const shader.Vertices) callconv(.c) void {
    for (0..vertices.count) |k| {
        const p = plain(vertices, k, 1);
        const uv = vertices.input(@intCast(k), 2);
        const r = if (vertices.instance < volume_depth) (@as(f32, @floatFromInt(vertices.instance)) + 0.5) / volume_depth else uv[0];
        vertices.output(@intCast(k))[0..7].* = .{ p[0], p[1], p[2], p[3], uv[0], uv[1], r };
    }
}

/// The vertices' colour, their depth leaning from left to right and a
/// little from top to bottom: a fan drawn with it leaves a depth that
/// slopes, from about 0.3 to about 0.8, in a shadow map (since 1.14).
fn tiltedVertex(vertices: *const shader.Vertices) callconv(.c) void {
    for (0..vertices.count) |k| {
        const p = place(vertices, k);
        const c = vertices.input(@intCast(k), 1);
        const z = 0.5 + 0.35 * p[0] - 0.1 * p[1];
        vertices.output(@intCast(k))[0..8].* = .{ p[0], p[1], z, p[3], shader.channel(c[0]), shader.channel(c[1]), shader.channel(c[2]), shader.channel(c[3]) };
    }
}

/// The whole picture from `quad_at`'s texture coordinates, each pixel's
/// centre on the centre of the shadow map's texel under it, and
/// `reference` the same at every pixel: what is compared at a pixel is
/// the depth drawn there, and no texel is read at an edge (since 1.14).
fn shadowVertex(comptime reference: f32) shader.VertexFn {
    return &struct {
        fn run(vertices: *const shader.Vertices) callconv(.c) void {
            for (0..vertices.count) |k| {
                const uv = vertices.input(@intCast(k), 2);
                vertices.output(@intCast(k))[0..7].* = .{ uv[0] * 2 - 1, uv[1] * 2 - 1, 0.5, 1, uv[0], uv[1], reference };
            }
        }
    }.run;
}

/// A triangle a group makes of the far, near and laid over ones in the
/// geometry, moved along by the push constants.
fn computeVertices(groups: *const shader.Groups) callconv(.c) void {
    const out = groups.resources.storage(Vertex, 0, 0) orelse return;
    const along = groups.resources.constants([2]f32).*;
    const number = groups.group[0];
    for (geometry[far_at + number * 3 ..][0..3], out[number * 3 ..][0..3]) |given, *into| {
        into.* = given;
        into.p[0] += along[0];
        into.p[1] += along[1];
    }
}

/// How many triangles draw, and the first left to the draw after it: the
/// numbers of a draw, and of a dispatch.
fn computeNumbers(groups: *const shader.Groups) callconv(.c) void {
    const out = groups.resources.storage(facet.DrawIndirectCommand, 0, 1) orelse return;
    out[groups.group[0]] = .{ .vertex_count = 3, .instance_count = 1, .first_vertex = far_at + groups.group[0] * 3, .first_instance = 0 };
}

/// Mixed from a patch's corners by where a new vertex lies, bent a little so
/// that how finely it is cut shows on the edges.
fn mixedPoint(evaluations: *const shader.Evaluations, k: usize, weights: []const f32) void {
    const out = evaluations.output(@intCast(k));
    const count = evaluations.output_stride;
    for (0..count) |float| {
        var sum: f32 = 0;
        for (weights, 0..) |weight, corner| sum += evaluations.patch.point(@intCast(corner))[float] * weight;
        out[float] = sum;
    }
    const where = evaluations.coordinates[k];
    out[0] += 0.06 * (where[0] * (1 - where[0]) + where[1] * (1 - where[1])) * 4;
    out[1] -= 0.08 * where[0] * (1 - where[1]) * 4;
}

fn triangleEvaluation(evaluations: *const shader.Evaluations) callconv(.c) void {
    for (0..evaluations.count) |k| {
        mixedPoint(evaluations, k, &evaluations.coordinates[k]);
    }
}

fn quadEvaluation(evaluations: *const shader.Evaluations) callconv(.c) void {
    for (0..evaluations.count) |k| {
        const where = evaluations.coordinates[k];
        mixedPoint(evaluations, k, &.{ (1 - where[0]) * (1 - where[1]), where[0] * (1 - where[1]), (1 - where[0]) * where[1], where[0] * where[1] });
    }
}

fn levelsOf(comptime outer: [4]f32, comptime inner: [2]f32) shader.ControlFn {
    return &struct {
        fn control(patch: *const shader.Patch, levels: *shader.Levels) callconv(.c) void {
            _ = patch;
            levels.outer = outer;
            levels.inner = inner;
        }
    }.control;
}

// Fragment shaders the module ships the SPIR-V of: the cores run each
// graph's function, the V3D compiles its words (since 1.76, through Mesa's
// back end since 1.137). V3DTest's GENERATED and MESA draw these five as
// well, from the V3D's own objects; these go through the library.
const Shipped = struct {
    const Smooth = ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            b.color(b.input(0, .f32x4));
        }
    });
    const Flat = ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            b.color(b.constant(.{ 0.25, 0.5, 0.75, 1 }));
        }
    });
    const Dimmed = ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            b.color(b.scale(b.input(0, .f32x4), b.input(1, .f32x1)));
        }
    });
    /// Set 0, binding 0: a combined image sampler (`Side.sampler_set`).
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
    /// The push constants (`Side.push_layout`): a colour at 0, and a
    /// float at 16 the vertices' colour is scaled by before it is added.
    const Pushed = ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            b.color(b.push(0, .f32x4));
        }
    });
    const Tinted = ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            b.color(b.add(b.scale(b.input(0, .f32x4), b.push(16, .f32x1)), b.push(0, .f32x4)));
        }
    });
    /// The texture with its pixel dropped where its red is under a half,
    /// and where it is over: the checks of `texelAt`'s first level are
    /// 0xF0 and 0x20 of red, so each drops half of them.
    const Cutout = ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const taken = b.sample(0, 0, b.input(0, .f32x2));
            b.discardIf(b.lessThan(b.component(taken, 0), b.scalar(0.5)));
            b.color(taken);
        }
    });
    const CutoutOther = ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const taken = b.sample(0, 0, b.input(0, .f32x2));
            b.discardIf(b.greaterThan(b.component(taken, 0), b.scalar(0.5)));
            b.color(taken);
        }
    });
    /// A shadow sample of `Side.shadow_sets`' map, the reference the
    /// vertices' third float: what passed in red and alpha 1, the colour
    /// the fixed form `texture_shadow` draws (since 1.15). The V3D
    /// compiles its OpImageSampleDrefImplicitLod to a TMUDREF write.
    const Shadowed = ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const passed = b.sampleCompared(0, 0, b.input(0, .f32x2), b.input(1, .f32x1));
            b.color(b.add(b.scale(b.constant(.{ 1, 0, 0, 0 }), passed), b.constant(.{ 0, 0, 0, 1 })));
        }
    });
    /// Float arithmetic through GLSL.std.450, the shader the V3D's host
    /// tests hold to glslc's word for word: Normalize, a dot, FClamp, FMix
    /// of a constant weight, Fract, FAbs, Sqrt, Pow, a negation, FMax and
    /// Length of the colour (since 1.20).
    const Arithmetic = ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const v = b.input(0, .f32x4);
            const x = b.component(v, 0);
            const y = b.component(v, 1);
            const z = b.component(v, 2);
            const w = b.component(v, 3);
            const half = b.scalar(0.5);
            const n = b.normalize(b.sub(b.vector(&.{ x, y, z }), b.constantOf(.f32x3, .{ 0.5, 0.5, 0.5, 0 })));
            const lit = b.clamp(b.dot(n, b.constantOf(.f32x3, .{ 0.267, 0.535, 0.802, 0 })), b.scalar(0), b.scalar(1));
            const r = b.mix(x, lit, b.scalar(0.25));
            const g = b.mul(b.fract(b.mul(y, b.scalar(3))), half);
            const bl = b.max(b.mul(b.sqrt(b.abs(b.sub(z, half))), b.pow(w, b.scalar(2.2))), b.neg(x));
            const a = b.mul(b.length(b.vector(&.{ x, y })), half);
            b.color(b.vector(&.{ r, g, bl, a }));
        }
    });
    /// The rest of the calls the V3D lowers: the four roundings, Exp, Log,
    /// Exp2, Log2, Distance, InverseSqrt, FMin, a division, and FMix of a
    /// weight that varies, green's (since 1.20).
    const Called = ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const v = b.input(0, .f32x4);
            const x = b.component(v, 0);
            const y = b.component(v, 1);
            const scaled = b.mul(v, b.constant(.{ 2.5, 2.5, 2.5, 2.5 }));
            const rounded = b.add(b.add(b.floor(scaled), b.ceil(scaled)), b.add(b.trunc(scaled), b.roundEven(scaled)));
            const grown = b.add(b.exp(x), b.log(b.add(y, b.scalar(1))));
            const twos = b.add(b.exp2(x), b.log2(b.add(y, b.scalar(1))));
            const away = b.distance(b.vector(&.{ x, y }), b.constantOf(.f32x2, .{ 0.25, 0.75, 0, 0 }));
            const sums = b.vector(&.{ b.inverseSqrt(b.add(x, b.scalar(1))), b.mul(b.min(grown, twos), b.scalar(0.25)), b.div(away, b.scalar(2)), b.scalar(1) });
            const weight = b.vector(&.{ y, y, y, y });
            b.color(b.mix(sums, b.mul(rounded, b.constant(.{ 0.1, 0.1, 0.1, 0.1 })), weight));
        }
    });
    /// The shader the V3D's host tests hold to glslc's glslc_chosen word
    /// for word: Sin, Cos, Tan, FClamp to 0 and 1, Step, SmoothStep and
    /// FSign, and OpSelect after <, >=, !=, == and <= (since 1.21).
    const Chosen = ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const v = b.input(0, .f32x4);
            const half = b.scalar(0.5);
            const six = b.scalar(6);
            const quarter = b.scalar(0.25);
            const x = b.component(v, 0);
            const sine = b.add(b.mul(b.sin(b.mul(x, six)), half), half);
            const y = b.component(v, 1);
            const cosine = b.add(b.mul(b.cos(b.mul(y, six)), half), half);
            const z = b.component(v, 2);
            const tangent = b.clamp(b.mul(b.tan(z), quarter), b.scalar(0), b.scalar(1));
            const by_less = b.select(b.lessThan(x, y), sine, cosine);
            const stepped = b.step(b.scalar(0.3), x);
            const eased = b.smoothStep(b.scalar(0.2), b.scalar(0.8), y);
            const by_half = b.select(b.greaterEqual(z, half), stepped, eased);
            const signed = b.add(b.mul(b.sign(b.sub(x, half)), quarter), half);
            const unequal = b.select(b.notEqual(x, y), b.scalar(0.75), b.scalar(1));
            const by_equal = b.select(b.equal(y, z), quarter, unequal);
            const by_order = b.select(b.lessEqual(x, z), signed, by_equal);
            b.color(b.vector(&.{ by_less, by_half, tangent, by_order }));
        }
    });
    /// The shader the V3D's host tests hold to glslc's glslc_branch word
    /// for word: two selections, one with an `else` that changes three
    /// floats of the colour, one a ternary of Pow and Exp2 (since 1.22).
    const Branched = ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const v = b.input(0, .f32x4);
            const half = b.scalar(0.5);
            const x = b.component(v, 0);
            const y = b.component(v, 1);
            const z = b.component(v, 2);
            const w = b.component(v, 3);
            const first = b.ifHolds(b.lessThan(x, half));
            const red_yes = b.add(b.mul(b.sin(b.mul(y, b.scalar(3))), half), half);
            const green_yes = b.mul(z, w);
            b.otherwise(first);
            const red_no = b.mul(y, b.scalar(0.25));
            const blue_no = b.sqrt(z);
            b.endIf(first);
            const r = b.merged(first, red_yes, red_no);
            const g = b.merged(first, green_yes, y);
            const bl = b.merged(first, z, blue_no);
            const second = b.ifHolds(b.greaterThan(w, half));
            const alpha_yes = b.add(b.pow(x, b.scalar(2)), b.scalar(0.1));
            b.otherwise(second);
            const alpha_no = b.mul(b.exp2(y), b.scalar(0.25));
            b.endIf(second);
            const a = b.merged(second, alpha_yes, alpha_no);
            b.color(b.vector(&.{ r, g, bl, a }));
        }
    });
    /// The shader the V3D's host tests hold to glslc's glslc_nested word
    /// for word: an `else if`, and an `if` and `else` in the true arm of
    /// a selection of no false arm (since 1.24).
    const Nested = ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const v = b.input(0, .f32x4);
            const half = b.scalar(0.5);
            const quarter = b.scalar(0.25);
            const x = b.component(v, 0);
            const y = b.component(v, 1);
            const z = b.component(v, 2);
            const w = b.component(v, 3);
            const first = b.ifHolds(b.lessThan(x, quarter));
            const red_first = b.mul(y, b.scalar(2));
            b.otherwise(first);
            const second = b.ifHolds(b.lessThan(x, half));
            const green_second = b.sin(b.mul(z, b.scalar(3)));
            b.otherwise(second);
            const blue_third = b.add(w, b.scalar(0.125));
            b.endIf(second);
            const red_else = b.merged(second, half, x);
            const green_else = b.merged(second, green_second, y);
            const blue_else = b.merged(second, z, blue_third);
            b.endIf(first);
            const r = b.merged(first, red_first, red_else);
            const g = b.merged(first, y, green_else);
            const bl = b.merged(first, z, blue_else);
            const third = b.ifHolds(b.greaterThan(w, half));
            const fourth = b.ifHolds(b.greaterThan(y, half));
            const product = b.mul(x, y);
            b.otherwise(fourth);
            const power = b.exp2(y);
            b.endIf(fourth);
            const chosen = b.merged(fourth, product, power);
            const scaled = b.add(b.mul(chosen, half), quarter);
            b.endIf(third);
            const a = b.merged(third, scaled, z);
            b.color(b.vector(&.{ r, g, bl, a }));
        }
    });
};

/// The entries that ship words, after all the others, and the words of
/// each in the same order: `shader.Module.spirv` is index for index.
const shipped_entries = [_]shader.Entry{
    shader.vertex("place", &placeVertex, 0),
    shader.vertex("as it is", &asItIsVertex, 4),
    shader.vertex("dimmed", &dimmedVertex, 5),
    shader.vertex("modulate as it is", &modulateAsItIsVertex, 6),
    Shipped.Smooth.entry("shipped smooth"),
    Shipped.Flat.entry("shipped flat"),
    Shipped.Dimmed.entry("shipped dimmed"),
    Shipped.Textured.entry("shipped texture"),
    Shipped.Modulated.entry("shipped modulated"),
    Shipped.Pushed.entry("shipped pushed"),
    Shipped.Tinted.entry("shipped tinted"),
    Shipped.Cutout.entry("shipped cutout"),
    Shipped.CutoutOther.entry("shipped cutout other"),
    Shipped.Shadowed.entry("shipped shadow"),
    Shipped.Arithmetic.entry("shipped arithmetic"),
    Shipped.Called.entry("shipped called"),
    Shipped.Chosen.entry("shipped chosen"),
    Shipped.Branched.entry("shipped branched"),
    Shipped.Branched.entry("shipped unoptimized"),
    Shipped.Nested.entry("shipped nested"),
};
const shipped_words = [_]shader.Spirv{
    .{},                       .{},                    .{},                                  .{},
    Shipped.Smooth.spirv,      Shipped.Flat.spirv,     Shipped.Dimmed.spirv,                 Shipped.Textured.spirv,
    Shipped.Modulated.spirv,   Shipped.Pushed.spirv,   Shipped.Tinted.spirv,                 Shipped.Cutout.spirv,
    Shipped.CutoutOther.spirv, Shipped.Shadowed.spirv, Shipped.Arithmetic.spirv,             Shipped.Called.spirv,
    Shipped.Chosen.spirv,      Shipped.Branched.spirv, shader.Spirv.of(&branch_unoptimized), Shipped.Nested.spirv,
};

/// glslc's own output for `Shipped.Branched`'s GLSL without -O, which the
/// V3D's host tests hold to compile to the program of glslc's optimized
/// module, word for word: `c` and `k` in variables of the function's own,
/// floats of `c` stored through access chains in the arms (since 1.23).
///
/// ```sh
/// glslc -fshader-stage=frag branch.frag -o branch_O0.spv   # 454 words
/// spirv-val --target-env vulkan1.0 branch_O0.spv         # no output, and 0
/// ```
const branch_unoptimized = [_]u32{
    0x07230203, 0x00010000, 0x000D000B, 0x00000050, 0x00000000, 0x00020011,
    0x00000001, 0x0006000B, 0x00000001, 0x4C534C47, 0x6474732E, 0x3035342E,
    0x00000000, 0x0003000E, 0x00000000, 0x00000001, 0x0007000F, 0x00000004,
    0x00000004, 0x6E69616D, 0x00000000, 0x0000000B, 0x00000047, 0x00030010,
    0x00000004, 0x00000007, 0x00030003, 0x00000002, 0x000001C2, 0x000A0004,
    0x475F4C47, 0x4C474F4F, 0x70635F45, 0x74735F70, 0x5F656C79, 0x656E696C,
    0x7269645F, 0x69746365, 0x00006576, 0x00080004, 0x475F4C47, 0x4C474F4F,
    0x6E695F45, 0x64756C63, 0x69645F65, 0x74636572, 0x00657669, 0x00040005,
    0x00000004, 0x6E69616D, 0x00000000, 0x00030005, 0x00000009, 0x00000063,
    0x00040005, 0x0000000B, 0x6C6F6376, 0x0000726F, 0x00030005, 0x00000033,
    0x0000006B, 0x00040005, 0x00000047, 0x6C6F636F, 0x0000726F, 0x00040047,
    0x0000000B, 0x0000001E, 0x00000000, 0x00040047, 0x00000047, 0x0000001E,
    0x00000000, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002,
    0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006,
    0x00000004, 0x00040020, 0x00000008, 0x00000007, 0x00000007, 0x00040020,
    0x0000000A, 0x00000001, 0x00000007, 0x0004003B, 0x0000000A, 0x0000000B,
    0x00000001, 0x00040015, 0x0000000D, 0x00000020, 0x00000000, 0x0004002B,
    0x0000000D, 0x0000000E, 0x00000000, 0x00040020, 0x0000000F, 0x00000001,
    0x00000006, 0x0004002B, 0x00000006, 0x00000012, 0x3F000000, 0x00020014,
    0x00000013, 0x0004002B, 0x0000000D, 0x00000017, 0x00000001, 0x0004002B,
    0x00000006, 0x0000001A, 0x40400000, 0x00040020, 0x0000001F, 0x00000007,
    0x00000006, 0x0004002B, 0x0000000D, 0x00000021, 0x00000002, 0x0004002B,
    0x0000000D, 0x00000024, 0x00000003, 0x0004002B, 0x00000006, 0x0000002C,
    0x3E800000, 0x0004002B, 0x00000006, 0x0000003C, 0x40000000, 0x0004002B,
    0x00000006, 0x0000003E, 0x3DCCCCCD, 0x00040020, 0x00000046, 0x00000003,
    0x00000007, 0x0004003B, 0x00000046, 0x00000047, 0x00000003, 0x00050036,
    0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200F8, 0x00000005,
    0x0004003B, 0x00000008, 0x00000009, 0x00000007, 0x0004003B, 0x0000001F,
    0x00000033, 0x00000007, 0x0004003B, 0x0000001F, 0x00000037, 0x00000007,
    0x0004003D, 0x00000007, 0x0000000C, 0x0000000B, 0x0003003E, 0x00000009,
    0x0000000C, 0x00050041, 0x0000000F, 0x00000010, 0x0000000B, 0x0000000E,
    0x0004003D, 0x00000006, 0x00000011, 0x00000010, 0x000500B8, 0x00000013,
    0x00000014, 0x00000011, 0x00000012, 0x000300F7, 0x00000016, 0x00000000,
    0x000400FA, 0x00000014, 0x00000015, 0x00000029, 0x000200F8, 0x00000015,
    0x00050041, 0x0000000F, 0x00000018, 0x0000000B, 0x00000017, 0x0004003D,
    0x00000006, 0x00000019, 0x00000018, 0x00050085, 0x00000006, 0x0000001B,
    0x00000019, 0x0000001A, 0x0006000C, 0x00000006, 0x0000001C, 0x00000001,
    0x0000000D, 0x0000001B, 0x00050085, 0x00000006, 0x0000001D, 0x0000001C,
    0x00000012, 0x00050081, 0x00000006, 0x0000001E, 0x0000001D, 0x00000012,
    0x00050041, 0x0000001F, 0x00000020, 0x00000009, 0x0000000E, 0x0003003E,
    0x00000020, 0x0000001E, 0x00050041, 0x0000000F, 0x00000022, 0x0000000B,
    0x00000021, 0x0004003D, 0x00000006, 0x00000023, 0x00000022, 0x00050041,
    0x0000000F, 0x00000025, 0x0000000B, 0x00000024, 0x0004003D, 0x00000006,
    0x00000026, 0x00000025, 0x00050085, 0x00000006, 0x00000027, 0x00000023,
    0x00000026, 0x00050041, 0x0000001F, 0x00000028, 0x00000009, 0x00000017,
    0x0003003E, 0x00000028, 0x00000027, 0x000200F9, 0x00000016, 0x000200F8,
    0x00000029, 0x00050041, 0x0000000F, 0x0000002A, 0x0000000B, 0x00000017,
    0x0004003D, 0x00000006, 0x0000002B, 0x0000002A, 0x00050085, 0x00000006,
    0x0000002D, 0x0000002B, 0x0000002C, 0x00050041, 0x0000001F, 0x0000002E,
    0x00000009, 0x0000000E, 0x0003003E, 0x0000002E, 0x0000002D, 0x00050041,
    0x0000000F, 0x0000002F, 0x0000000B, 0x00000021, 0x0004003D, 0x00000006,
    0x00000030, 0x0000002F, 0x0006000C, 0x00000006, 0x00000031, 0x00000001,
    0x0000001F, 0x00000030, 0x00050041, 0x0000001F, 0x00000032, 0x00000009,
    0x00000021, 0x0003003E, 0x00000032, 0x00000031, 0x000200F9, 0x00000016,
    0x000200F8, 0x00000016, 0x00050041, 0x0000000F, 0x00000034, 0x0000000B,
    0x00000024, 0x0004003D, 0x00000006, 0x00000035, 0x00000034, 0x000500BA,
    0x00000013, 0x00000036, 0x00000035, 0x00000012, 0x000300F7, 0x00000039,
    0x00000000, 0x000400FA, 0x00000036, 0x00000038, 0x00000040, 0x000200F8,
    0x00000038, 0x00050041, 0x0000000F, 0x0000003A, 0x0000000B, 0x0000000E,
    0x0004003D, 0x00000006, 0x0000003B, 0x0000003A, 0x0007000C, 0x00000006,
    0x0000003D, 0x00000001, 0x0000001A, 0x0000003B, 0x0000003C, 0x00050081,
    0x00000006, 0x0000003F, 0x0000003D, 0x0000003E, 0x0003003E, 0x00000037,
    0x0000003F, 0x000200F9, 0x00000039, 0x000200F8, 0x00000040, 0x00050041,
    0x0000000F, 0x00000041, 0x0000000B, 0x00000017, 0x0004003D, 0x00000006,
    0x00000042, 0x00000041, 0x0006000C, 0x00000006, 0x00000043, 0x00000001,
    0x0000001D, 0x00000042, 0x00050085, 0x00000006, 0x00000044, 0x00000043,
    0x0000002C, 0x0003003E, 0x00000037, 0x00000044, 0x000200F9, 0x00000039,
    0x000200F8, 0x00000039, 0x0004003D, 0x00000006, 0x00000045, 0x00000037,
    0x0003003E, 0x00000033, 0x00000045, 0x00050041, 0x0000001F, 0x00000048,
    0x00000009, 0x0000000E, 0x0004003D, 0x00000006, 0x00000049, 0x00000048,
    0x00050041, 0x0000001F, 0x0000004A, 0x00000009, 0x00000017, 0x0004003D,
    0x00000006, 0x0000004B, 0x0000004A, 0x00050041, 0x0000001F, 0x0000004C,
    0x00000009, 0x00000021, 0x0004003D, 0x00000006, 0x0000004D, 0x0000004C,
    0x0004003D, 0x00000006, 0x0000004E, 0x00000033, 0x00070050, 0x00000007,
    0x0000004F, 0x00000049, 0x0000004B, 0x0000004D, 0x0000004E, 0x0003003E,
    0x00000047, 0x0000004F, 0x000100FD, 0x00010038,
};

const plain_entries = [_]shader.Entry{
    shader.compute("vertices", &computeVertices),
    shader.compute("numbers", &computeNumbers),
    shader.control("even", levelsOf(.{ 4, 4, 4, 4 }, .{ 4, 4 }), 0),
    shader.control("uneven", levelsOf(.{ 2, 3, 5, 7 }, .{ 3, 6 }), 0),
    shader.control("lines", levelsOf(.{ 5, 12, 1, 1 }, .{ 1, 1 }), 0),
    shader.evaluation("triangles", &triangleEvaluation, 4, .{ .domain = .triangles }),
    shader.evaluation("triangles other way", &triangleEvaluation, 4, .{ .domain = .triangles, .clockwise = true }),
    shader.evaluation("quads", &quadEvaluation, 4, .{ .domain = .quads }),
    shader.evaluation("isolines", &quadEvaluation, 4, .{ .domain = .isolines }),
    shader.vertex("color", &colorVertex, 4),
    shader.vertex("texture", &textureVertex, 2),
    shader.vertex("tiled", scaledVertex(8, 8), 2),
    shader.vertex("stretched", scaledVertex(32, 1), 2),
    shader.vertex("in texels", scaledVertex(texture_side, texture_side), 2),
    shader.vertex("modulate", &modulateVertex, 6),
    shader.vertex("array", &arrayVertex, 3),
    shader.vertex("small array", &smallArrayVertex, 3),
    shader.vertex("cube", &cubeVertex, 3),
    shader.vertex("volume", &volumeVertex, 3),
    shader.vertex("tilted", &tiltedVertex, 4),
    shader.vertex("whole at a half", shadowVertex(0.5), 3),
    shader.vertex("whole at 0.6", shadowVertex(0.6), 3),
    shader.fixedFragment("array", .{ .kind = .texture_array, .sampling = .{ .filter = .nearest } }),
    shader.fixedFragment("array bilinear", .{ .kind = .texture_array, .sampling = .{ .filter = .bilinear } }),
    shader.fixedFragment("cube", .{ .kind = .texture_cube, .sampling = .{ .filter = .nearest } }),
    shader.fixedFragment("cube bilinear", .{ .kind = .texture_cube, .sampling = .{ .filter = .bilinear } }),
    shader.fixedFragment("volume", .{ .kind = .texture_3d, .sampling = .{ .filter = .nearest } }),
    shader.fixedFragment("volume bilinear", .{ .kind = .texture_3d, .sampling = .{ .filter = .bilinear } }),
    shader.fixedFragment("sampled", .{ .kind = .texture_sampled }),
    shader.fixedFragment("array sampled", .{ .kind = .texture_array_sampled }),
    shader.fixedFragment("cube sampled", .{ .kind = .texture_cube_sampled }),
    shader.fixedFragment("volume sampled", .{ .kind = .texture_3d_sampled }),
    shader.fixedFragment("shadow", .{ .kind = .texture_shadow }),
    shader.fixedFragment("color", .{ .kind = .color }),
    shader.fixedFragment("texture", .{ .kind = .texture, .sampling = .{ .filter = .bilinear } }),
    shader.fixedFragment("nearest", .{ .kind = .texture, .sampling = .{ .filter = .nearest } }),
    shader.fixedFragment("nearest 565", .{ .kind = .texture, .sampling = .{ .format = .rgb565, .filter = .nearest } }),
    shader.fixedFragment("clamp", .{ .kind = .texture, .sampling = .{ .filter = .bilinear, .address = .clamp } }),
    shader.fixedFragment("modulate", .{ .kind = .texture_color, .sampling = .{ .filter = .nearest } }),
};
const entries = plain_entries ++ shipped_entries;
const words = [_]shader.Spirv{.{}} ** plain_entries.len ++ shipped_words;
const code = shader.Module{ .entry_count = entries.len, .entries = &entries, .spirv = &words, .spirv_count = words.len };

const texture_side: u32 = 64;
const picture_usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT | facet.IMAGE_USAGE_TRANSFER_SRC | facet.IMAGE_USAGE_TRANSFER_DST;
const texture_levels = 7;
const formats = [_]facet.Format{ .b8g8r8a8_unorm, .r8g8b8a8_unorm, .r5g6b5_unorm_pack16 };

/// A sampler a texture is drawn through, as a case of its own: the
/// fragment shader that samples, the vertex function and the part of
/// `geometry` it is drawn with, which say what of the sampler shows, and
/// the texture. Each is in a set of its own beside `Side.sampler_set`. The
/// case is called `label` and then `what`.
const Through = struct {
    label: [:0]const u8 = "shipped texture",
    what: [:0]const u8,
    /// The shipped shader that samples, or a fixed form that reads the
    /// bound sampler.
    fragment: [*:0]const u8 = "shipped texture",
    info: facet.SamplerCreateInfo,
    vertex: [*:0]const u8,
    first: u32 = quad_at,
    instance: u32 = 0,
    view: View = .texture,
    /// `Case.slack`.
    slack: ?u32 = null,

    const View = enum {
        /// The first texture, all its levels.
        texture,
        /// Its first level alone, which a sampler in texels is read
        /// through: Vulkan has such a sampler read a view of one level.
        first_level,
        array,
        cube,
        volume,
    };
};

/// What a sampler says beyond one filter, one wrap and every level as it
/// is: until 1.140 the V3D painted `shader.missing` for each of these, and
/// they are the TMU's own since (`tiling.samplerOf`). "tiled" reads the
/// texture eight times over the quad, which is about level 1; the wide
/// quad reads it from -1.25 to 2.25, at level 0.
const shipped_throughs = [_]Through{
    .{
        .what = "levels mixed and shifted",
        .info = .{ .mipmap_mode = .linear, .mip_lod_bias = 1.5, .max_lod = facet.texture.lod_unclamped },
        .vertex = "tiled",
    },
    .{
        .what = "levels held to 3 and 4",
        .info = .{ .mag_filter = .nearest, .min_filter = .nearest, .min_lod = 3, .max_lod = 4 },
        .vertex = "tiled",
    },
    .{
        .what = "mirrored across and held down",
        .info = .{ .address_mode_u = .mirrored_repeat, .address_mode_v = .clamp_to_edge, .max_lod = facet.texture.lod_unclamped },
        .vertex = "texture",
        .first = wide_at,
    },
    .{
        .what = "bordered in white",
        .info = .{ .address_mode_u = .clamp_to_border, .address_mode_v = .clamp_to_border, .border_color = .float_opaque_white, .max_lod = facet.texture.lod_unclamped },
        .vertex = "texture",
        .first = wide_at,
    },
    .{
        .what = "mirrored once",
        .info = .{ .mag_filter = .nearest, .min_filter = .nearest, .address_mode_u = .mirror_clamp_to_edge, .address_mode_v = .mirror_clamp_to_edge, .max_lod = facet.texture.lod_unclamped },
        .vertex = "texture",
        .first = wide_at,
    },
    // Vulkan leaves the samples of anisotropic filtering to the
    // implementation, and the two take theirs differently: the cores
    // average up to four bilinear samples along the longer axis, each
    // rounded to 8 bits first (`texture.tapped`), and the TMU its own
    // way. On the board in 1.140 they agree within two steps over most
    // of the quad, and within five on about one pixel in a hundred, all
    // at its left - from x 93 to about 210 - and a few near x 480. The
    // same pixels differ when the coordinate is moved on by 16 repeats,
    // which reads the same texels, so it is where the pixel is on the
    // screen and not where it is in the texture; why is not known. A
    // TMU that took one sample would read about two levels further, each
    // a colour of its own, which is far past five steps.
    .{
        .what = "four samples along",
        .info = .{ .mipmap_mode = .linear, .anisotropy_enable = true, .max_anisotropy = 4, .max_lod = facet.texture.lod_unclamped },
        .vertex = "stretched",
        .slack = 5,
    },
    .{
        .what = "in texels",
        .info = .{ .mag_filter = .nearest, .min_filter = .nearest, .address_mode_u = .clamp_to_edge, .address_mode_v = .clamp_to_edge, .unnormalized_coordinates = true },
        .vertex = "in texels",
        .first = wide_at,
        .view = .first_level,
    },
};

/// The same through the fixed form that reads the bound sampler,
/// `texture_sampled`, which the V3D draws since 1.141 with the program of
/// `texture` and the TMU told the sampler.
const formed_throughs = formed: {
    var made = shipped_throughs;
    for (&made) |*each| {
        each.label = "sampled form";
        each.fragment = "sampled";
    }
    break :formed made;
};

/// A layer of an array, a cube and a 3D texture through a sampler: the
/// fixed forms `texture_array_sampled`, `texture_cube_sampled` and
/// `texture_3d_sampled`, which the V3D draws the same way since 1.141.
/// "small array" reads the array's further levels; "cube" at instance 6
/// looks across the edge of two faces, which a cube is read over whatever
/// the sampler's wraps, here the default `repeat`; "volume" at instance
/// `volume_depth` goes across the slices from left to right, so that a
/// border past them shows at both sides.
const layered_throughs = [_]Through{
    .{
        .label = "array",
        .what = "through a sampler, levels mixed and shifted",
        .fragment = "array sampled",
        .info = .{ .mipmap_mode = .linear, .mip_lod_bias = 1, .max_lod = facet.texture.lod_unclamped },
        .vertex = "small array",
        .instance = 2,
        .view = .array,
    },
    .{
        .label = "array",
        .what = "through a sampler, past the last",
        .fragment = "array sampled",
        .info = .{ .mag_filter = .nearest, .min_filter = .nearest, .max_lod = facet.texture.lod_unclamped },
        .vertex = "array",
        .instance = 7,
        .view = .array,
    },
    .{
        .label = "cube",
        .what = "through a sampler, +z",
        .fragment = "cube sampled",
        .info = .{ .mag_filter = .nearest, .min_filter = .nearest, .max_lod = facet.texture.lod_unclamped },
        .vertex = "cube",
        .instance = 4,
        .view = .cube,
    },
    .{
        .label = "cube",
        .what = "through a sampler, across an edge",
        .fragment = "cube sampled",
        .info = .{ .max_lod = facet.texture.lod_unclamped },
        .vertex = "cube",
        .instance = 6,
        .view = .cube,
    },
    .{
        .label = "3D",
        .what = "through a sampler, across, bordered",
        .fragment = "volume sampled",
        .info = .{ .address_mode_w = .clamp_to_border, .border_color = .float_opaque_white, .max_lod = facet.texture.lod_unclamped },
        .vertex = "volume",
        .instance = volume_depth,
        .view = .volume,
    },
    .{
        .label = "3D",
        .what = "through a sampler, a slice held to its edges",
        .fragment = "volume sampled",
        .info = .{ .mag_filter = .nearest, .min_filter = .nearest, .address_mode_u = .clamp_to_edge, .address_mode_v = .mirrored_repeat, .max_lod = facet.texture.lod_unclamped },
        .vertex = "volume",
        .instance = 3,
        .view = .volume,
    },
};

const throughs = shipped_throughs ++ formed_throughs ++ layered_throughs;

/// What the shadow-map cases compare with (`Cases.shadowed`): the
/// reference less than the depth, and greater (since 1.14).
const shadow_ops = [_]facet.CompareOp{ .less, .greater };

const layer_side: u32 = 32;
const array_layers = 4;
const array_levels = 3;
const volume_side: u32 = 16;
const volume_depth = 8;
const unpacked_side: u32 = 16;

/// The textures of layers, and their views.
const Layered = enum(u8) {
    array,
    cube,
    volume,
    /// One of the array's layers, as a texture of one.
    array_layer,
    /// Filled by a case, from the array.
    copied,
    bc1,
    bc1_clear,
    bc2,
    bc3,
    half,
    float,
    packed_float,
    shared_exponent,
};
const layered_count = @typeInfo(Layered).@"enum".fields.len;
const compressed_and_float = [_]struct { which: Layered, format: facet.Format }{
    .{ .which = .bc1, .format = .bc1_rgb_unorm_block },
    .{ .which = .bc1_clear, .format = .bc1_rgba_unorm_block },
    .{ .which = .bc2, .format = .bc2_unorm_block },
    .{ .which = .bc3, .format = .bc3_unorm_block },
    .{ .which = .half, .format = .r16g16b16a16_sfloat },
    .{ .which = .float, .format = .r32g32b32a32_sfloat },
    .{ .which = .packed_float, .format = .b10g11r11_ufloat_pack32 },
    .{ .which = .shared_exponent, .format = .e5b9g9r9_ufloat_pack32 },
};
const layer_colors = [8][3]u8{ .{ 0xE0, 0x30, 0x30 }, .{ 0x30, 0xD0, 0x40 }, .{ 0x30, 0x50, 0xE0 }, .{ 0xE0, 0xD0, 0x30 }, .{ 0xD0, 0x30, 0xD0 }, .{ 0x30, 0xD0, 0xD0 }, .{ 0xF0, 0x90, 0x30 }, .{ 0x90, 0x90, 0x90 } };

/// A layer's checks in a colour of its own, a level's bluer, and a white corner
/// that shows which way up it lies.
fn layerTexel(layer: usize, level: u32, x: usize, y: usize) [4]u8 {
    if (x < 4 and y < 4) return .{ 0xFF, 0xFF, 0xFF, 0xFF };
    const color = layer_colors[layer];
    const shift: u3 = @intCast(((x >> 2) ^ (y >> 2)) & 1);
    return .{ color[0] >> shift, color[1] >> shift, @intCast(@min(@as(u32, color[2] >> shift) + level * 0x30, 0xFF)), 0xFF };
}

fn rgb565(r: u32, g: u32, b: u32) u16 {
    return @intCast((r >> 3) << 11 | (g >> 2) << 5 | b >> 3);
}

/// A block's two colours, by where it is, and the order that makes a colour
/// block of four colours, or of three and clear.
fn blockColors(into: []u8, row: u32, column: u32, four: bool) void {
    const a = rgb565(0xF0, 0x40 + column * 0x30, 0x20 + row * 0x30);
    const b = rgb565(0x10, 0x80, 0xF0 - row * 0x20);
    const high = @max(a, b);
    const low = @min(a, b);
    std.mem.writeInt(u16, into[0..2], if (four) high else low, .little);
    std.mem.writeInt(u16, into[2..4], if (four) low else high, .little);
    std.mem.writeInt(u32, into[4..8], 0xE4E4_E4E4, .little);
}

/// A compressed format's 16 x 16 texels, as blocks: 4 x 4 of them.
fn stageBlocks(format: facet.Format, into: []u8) usize {
    var used: usize = 0;
    for (0..4) |row| for (0..4) |column| {
        const r: u32 = @intCast(row);
        const c: u32 = @intCast(column);
        switch (format) {
            .bc1_rgb_unorm_block, .bc1_rgba_unorm_block => {
                blockColors(into[used..], r, c, (r + c) % 2 == 0);
                used += 8;
            },
            .bc2_unorm_block => {
                // Each texel's alpha of its own, rising.
                std.mem.writeInt(u64, into[used..][0..8], 0xFEDC_BA98_7654_3210, .little);
                blockColors(into[used + 8 ..], r, c, true);
                used += 16;
            },
            else => {
                // Two alphas and the six between, in turn.
                into[used] = 0xFF;
                into[used + 1] = 0x20;
                var bits: u64 = 0;
                for (0..16) |k| bits |= @as(u64, k % 8) << @intCast(k * 3);
                for (0..6) |k| into[used + 2 + k] = @truncate(bits >> @intCast(k * 8));
                blockColors(into[used + 8 ..], r, c, true);
                used += 16;
            },
        }
    };
    return used;
}

/// A float's exponent and mantissa, without its sign, zero below a small one.
fn floatParts(value: f32) struct { exponent: u32, mantissa: u32 } {
    const bits: u32 = @bitCast(value);
    const exponent: i32 = @as(i32, @intCast(bits >> 23 & 0xFF)) - 127 + 15;
    if (exponent <= 0) return .{ .exponent = 0, .mantissa = 0 };
    return .{ .exponent = @intCast(exponent), .mantissa = bits & 0x7F_FFFF };
}

/// A texel of a float format at (x, y): red from 0 to 2 across, so that its
/// right half is cut to 1, green from 0 to 1 down, and blue a quarter.
fn stageFloat(format: facet.Format, x: usize, y: usize, into: []u8) usize {
    const across: f32 = @floatFromInt(x);
    const down: f32 = @floatFromInt(y);
    const r = across / 15 * 2;
    const g = down / 15;
    const b: f32 = 0.25;
    switch (format) {
        .r16g16b16a16_sfloat => {
            for ([4]f32{ r, g, b, 1 }, 0..) |value, k| {
                const parts = floatParts(value);
                std.mem.writeInt(u16, into[k * 2 ..][0..2], @intCast(parts.exponent << 10 | parts.mantissa >> 13), .little);
            }
            return 8;
        },
        .r32g32b32a32_sfloat => {
            for ([4]f32{ r, g, b, 1 }, 0..) |value, k| std.mem.writeInt(u32, into[k * 4 ..][0..4], @bitCast(value), .little);
            return 16;
        },
        .b10g11r11_ufloat_pack32 => {
            const of_r = floatParts(r);
            const of_g = floatParts(g);
            const of_b = floatParts(b);
            std.mem.writeInt(u32, into[0..4], (of_r.exponent << 6 | of_r.mantissa >> 17) | (of_g.exponent << 6 | of_g.mantissa >> 17) << 11 | (of_b.exponent << 5 | of_b.mantissa >> 18) << 22, .little);
            return 4;
        },
        else => {
            // An exponent of 16: 256 is 1.
            const word = @as(u32, @intFromFloat(@min(r * 256, 511))) | @as(u32, @intFromFloat(g * 256)) << 9 | @as(u32, @intFromFloat(b * 256)) << 18 | 16 << 27;
            std.mem.writeInt(u32, into[0..4], word, .little);
            return 4;
        },
    }
}
const Target = enum(u32) { bgra, rgba, rgb565 };
/// The attachment a stencil case draws with, on a picture in bgra.
const Stencil = enum(u32) { none, with_depth, alone };
const stencil_formats = [2]facet.Format{ .d16_unorm_s8_uint, .s8_uint };

/// What a pipeline of a case is.
const Options = struct {
    vertex: [*:0]const u8 = "color",
    fragment: [*:0]const u8 = "color",
    topology: facet.PrimitiveTopology = .triangle_list,
    restart: bool = false,
    /// Tessellated, patches of this many: functions of these names.
    patch_points: u32 = 0,
    control: [*:0]const u8 = "even",
    evaluation: [*:0]const u8 = "triangles",
    polygon_mode: facet.PolygonMode = .fill,
    line_width: f32 = 1,
    cull: u32 = facet.CULL_MODE_NONE,
    winding: facet.FrontFace = .clockwise,
    test_depth: bool = false,
    write_depth: bool = false,
    compare: facet.CompareOp = .less,
    blend: bool = false,
    /// Blended: added to what is there, not laid over it.
    add: bool = false,
    /// All of how it mixes, in place of `blend` and `add`.
    mixing: ?facet.PipelineColorBlendAttachmentState = null,
    constants: [4]f32 = .{ 0, 0, 0, 0 },
    /// The constants are left to CmdSetBlendConstants.
    dynamic_constants: bool = false,
    /// In a pass of its own, its subpass and the colour attachments of that.
    pass: ?*facet.RenderPass = null,
    subpass: u32 = 0,
    colors: u32 = 1,
    stencil: Stencil = .none,
    stencil_test: bool = false,
    front: facet.StencilOpState = .{},
    back: facet.StencilOpState = .{},
    /// The reference is left to CmdSetStencilReference.
    dynamic_reference: bool = false,
    target: Target = .bgra,
    depth: bool = true,
    load: bool = false,
    /// In place of `Side.layout`, whose set 0 is a sampled image.
    layout: ?*facet.PipelineLayout = null,
    /// Its samples a pixel, its pass's, and the mask of them it writes:
    /// all where null (since 1.16).
    samples: u32 = 1,
    sample_mask: ?u32 = null,
    /// Colour 0's alpha cuts the samples a pixel covers (since 1.17).
    alpha_to_coverage: bool = false,
    /// No fragment stage at all: the vertex stage alone (since 1.18).
    no_fragment: bool = false,
};

/// What a pass of a case is.
const Pass = struct {
    target: Target = .bgra,
    depth: bool = true,
    load: bool = false,
    /// Parts of 1 of the picture; all of it if null.
    area: ?[4]f32 = null,
    clear: [4]f32 = .{ 0.06, 0.09, 0.2, 1 },
    stencil: Stencil = .none,
    clear_stencil: u32 = 0,
};

/// One device and everything drawn with it.
const Side = struct {
    fb: *FacetBase,
    width: u32,
    height: u32,
    physical: *facet.PhysicalDevice,
    memory: facet.PhysicalDeviceMemoryProperties = undefined,
    device: ?*facet.Device = null,
    queue: *facet.Queue = undefined,
    blocks: [40]?*facet.DeviceMemory = @splat(null),
    block_count: u32 = 0,
    vertices: ?*facet.Buffer = null,
    places: ?*facet.Buffer = null,
    indices: ?*facet.Buffer = null,
    staging: ?*facet.Buffer = null,
    pictures: [formats.len]?*facet.Image = @splat(null),
    picture_views: [formats.len]?*facet.ImageView = @splat(null),
    picture_bytes: [formats.len][*]const u8 = undefined,
    picture_pitch: [formats.len]usize = undefined,
    depth: ?*facet.Image = null,
    depth_view: ?*facet.ImageView = null,
    textures: [formats.len]?*facet.Image = @splat(null),
    texture_views: [formats.len]?*facet.ImageView = @splat(null),
    layered_images: [layered_count]?*facet.Image = @splat(null),
    layered_views: [layered_count]?*facet.ImageView = @splat(null),
    layered_sets: [layered_count]?*facet.DescriptorSet = @splat(null),
    layered_staging: ?*facet.Buffer = null,
    /// A pass of four subpasses over two pictures, and one of two attachments.
    subpassed: ?*facet.RenderPass = null,
    subpassed_frame: ?*facet.Framebuffer = null,
    two_colors: ?*facet.RenderPass = null,
    two_colors_frame: ?*facet.Framebuffer = null,
    /// Render passes by format, depth and load.
    passes: [formats.len][2][2]?*facet.RenderPass = @splat(@splat(@splat(null))),
    framebuffers: [formats.len][2]?*facet.Framebuffer = @splat(@splat(null)),
    stencil_images: [2]?*facet.Image = @splat(null),
    stencil_views: [2]?*facet.ImageView = @splat(null),
    stencil_passes: [2]?*facet.RenderPass = @splat(null),
    stencil_framebuffers: [2]?*facet.Framebuffer = @splat(null),
    set_layout: ?*facet.DescriptorSetLayout = null,
    descriptor_pool: ?*facet.DescriptorPool = null,
    sets: [formats.len]?*facet.DescriptorSet = @splat(null),
    layout: ?*facet.PipelineLayout = null,
    module: ?*facet.ShaderModule = null,
    /// What a shipped shader that samples reads: the first texture
    /// through a sampler of its own, as a combined image sampler at set
    /// 0, binding 0.
    sampler: ?*facet.Sampler = null,
    sampler_set_layout: ?*facet.DescriptorSetLayout = null,
    sampler_layout: ?*facet.PipelineLayout = null,
    sampler_set: ?*facet.DescriptorSet = null,
    /// `throughs`, each in a set of its own (`upThroughs`), and the first
    /// texture's first level alone (`Through.View.first_level`).
    through: [throughs.len]?*facet.Sampler = @splat(null),
    through_sets: [throughs.len]?*facet.DescriptorSet = @splat(null),
    first_level: ?*facet.ImageView = null,
    /// A depth as large as the picture that is sampled too, a shadow map,
    /// the pass that draws it and keeps it, and the samplers that compare
    /// with it, `shadow_ops`, each in a set of its own (since 1.14).
    shadow: ?*facet.Image = null,
    shadow_view: ?*facet.ImageView = null,
    shadow_pass: ?*facet.RenderPass = null,
    shadow_frame: ?*facet.Framebuffer = null,
    shadow_samplers: [shadow_ops.len]?*facet.Sampler = @splat(null),
    shadow_sets: [shadow_ops.len]?*facet.DescriptorSet = @splat(null),
    /// The same shadow map drawn in a pass of it alone, no colour (since
    /// 1.18).
    shadow_alone: ?*facet.RenderPass = null,
    shadow_alone_frame: ?*facet.Framebuffer = null,
    /// And one that begins with what the map holds, to draw over a part
    /// of it, its layout the one the first leaves it in (since 1.19).
    shadow_again: ?*facet.RenderPass = null,
    /// A pass of the first picture and the depth whose first subpass draws
    /// the depth alone, and one whose first subpass names its colour
    /// ATTACHMENT_UNUSED; each's second draws the picture tested against
    /// what the first left. And a pass of no attachment, whose draws an
    /// occlusion query counts (since 1.18).
    prepassed: ?*facet.RenderPass = null,
    unused_first: ?*facet.RenderPass = null,
    prepassed_frame: ?*facet.Framebuffer = null,
    /// Their depth, kept from the one subpass to the next, so in memory
    /// that is there, which `depth` is not.
    pre_depth: ?*facet.Image = null,
    pre_depth_view: ?*facet.ImageView = null,
    empty: ?*facet.RenderPass = null,
    empty_frame: ?*facet.Framebuffer = null,
    queries: ?*facet.QueryPool = null,
    /// Four samples a pixel (since 1.16): a colour of them in the first
    /// picture's format and a depth in the tiles alone, a pass that
    /// resolves the colour into the first picture as it ends, and one that
    /// leaves it for CmdResolveImage.
    four: ?*facet.Image = null,
    four_view: ?*facet.ImageView = null,
    four_depth: ?*facet.Image = null,
    four_depth_view: ?*facet.ImageView = null,
    resolving: ?*facet.RenderPass = null,
    resolving_frame: ?*facet.Framebuffer = null,
    four_alone: ?*facet.RenderPass = null,
    four_alone_frame: ?*facet.Framebuffer = null,
    /// What a shipped shader that reads the push constants is made with:
    /// no set, and the fragment stage's 20 bytes of them.
    push_layout: ?*facet.PipelineLayout = null,
    command_pool: ?*facet.CommandPool = null,
    commands: ?*facet.CommandBuffer = null,
    fence: ?*facet.Fence = null,
    secondary: ?*facet.CommandBuffer = null,
    /// What the indirect and compute cases write, and what they bind it with.
    computed: ?*facet.Buffer = null,
    numbers: ?*facet.Buffer = null,
    number_bytes: [*]u8 = undefined,
    compute_set_layout: ?*facet.DescriptorSetLayout = null,
    compute_set: ?*facet.DescriptorSet = null,
    compute_layout: ?*facet.PipelineLayout = null,
    compute_pipelines: [2]?*facet.Pipeline = @splat(null),
    /// The pipelines of the case being drawn.
    made: [8]?*facet.Pipeline = @splat(null),
    made_count: u32 = 0,

    fn expect(result: facet.Result, failure: Failure) Failure!void {
        if (result == .error_device_lost) return error.DeviceLost;
        if (result != .success) return failure;
    }

    fn up(side: *Side) Failure!void {
        const fb = side.fb;
        fb.GetPhysicalDeviceMemoryProperties(side.physical, &side.memory);
        const queue_info = facet.DeviceQueueCreateInfo{};
        try expect(fb.CreateDevice(side.physical, &.{ .queue_create_info_count = 1, .queue_create_infos = @ptrCast(&queue_info) }, &side.device), error.NoDevice);
        var queue: ?*facet.Queue = null;
        fb.GetDeviceQueue(side.device.?, 0, 0, &queue);
        side.queue = queue.?;
        const device = side.device.?;

        var bytes = try side.buffer(@sizeOf(@TypeOf(geometry)), facet.BUFFER_USAGE_VERTEX_BUFFER, &side.vertices);
        @memcpy(bytes[0..@sizeOf(@TypeOf(geometry))], std.mem.asBytes(&geometry));
        bytes = try side.buffer(@sizeOf(@TypeOf(instance_places)), facet.BUFFER_USAGE_VERTEX_BUFFER, &side.places);
        @memcpy(bytes[0..@sizeOf(@TypeOf(instance_places))], std.mem.asBytes(&instance_places));
        const index_bytes = @sizeOf(@TypeOf(restart_indices)) + @sizeOf(@TypeOf(indices_16)) + @sizeOf(@TypeOf(indices_32)) + 8;
        bytes = try side.buffer(index_bytes, facet.BUFFER_USAGE_INDEX_BUFFER, &side.indices);
        @memcpy(bytes[0..@sizeOf(@TypeOf(restart_indices))], std.mem.asBytes(&restart_indices));
        @memcpy(bytes[offset_16..][0..@sizeOf(@TypeOf(indices_16))], std.mem.asBytes(&indices_16));
        @memcpy(bytes[offset_32..][0..@sizeOf(@TypeOf(indices_32))], std.mem.asBytes(&indices_32));

        // The depth, in the tiles alone.
        const extent = facet.Extent3D{ .width = side.width, .height = side.height };
        try side.image(.{ .format = .d16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, facet.MEMORY_PROPERTY_LAZILY_ALLOCATED, &side.depth);
        side.depth_view = try side.view(side.depth.?, .d16_unorm, facet.IMAGE_ASPECT_DEPTH, 1);

        for (formats, 0..) |format, f| {
            for (0..2) |with_depth| for (0..2) |load| {
                const attachments = [2]facet.AttachmentDescription{
                    .{ .format = format, .load_op = if (load != 0) .load else .clear, .store_op = .store, .final_layout = .general },
                    .{ .format = .d16_unorm, .load_op = .clear, .final_layout = .depth_stencil_attachment_optimal },
                };
                const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
                const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
                const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = if (with_depth != 0) &depth else null };
                try expect(fb.CreateRenderPass(device, &.{ .attachment_count = @intCast(1 + with_depth), .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &side.passes[f][with_depth][load]), error.Refused);
            };
            const block = try side.imageGiving(.{ .format = format, .extent = extent, .tiling = .linear, .usage = picture_usage }, facet.MEMORY_PROPERTY_HOST_VISIBLE, &side.pictures[f]);
            side.picture_views[f] = try side.view(side.pictures[f].?, format, facet.IMAGE_ASPECT_COLOR, 1);
            var data: ?*anyopaque = null;
            try expect(fb.MapMemory(device, block, 0, facet.WHOLE_SIZE, 0, &data), error.Refused);
            var layout: facet.SubresourceLayout = undefined;
            fb.GetImageSubresourceLayout(device, side.pictures[f].?, &.{}, &layout);
            side.picture_bytes[f] = @as([*]const u8, @ptrCast(data.?)) + @as(usize, @intCast(layout.offset));
            side.picture_pitch[f] = @intCast(layout.row_pitch);
            for (0..2) |with_depth| {
                const views = [2]*facet.ImageView{ side.picture_views[f].?, side.depth_view.? };
                try expect(fb.CreateFramebuffer(device, &.{ .render_pass = side.passes[f][with_depth][0].?, .attachment_count = @intCast(1 + with_depth), .attachments = &views, .width = side.width, .height = side.height }, &side.framebuffers[f][with_depth]), error.Refused);
            }
            try side.image(.{ .format = format, .extent = .{ .width = texture_side, .height = texture_side }, .mip_levels = texture_levels, .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST }, 0, &side.textures[f]);
            side.texture_views[f] = try side.view(side.textures[f].?, format, facet.IMAGE_ASPECT_COLOR, texture_levels);
        }

        for (stencil_formats, 0..) |format, k| {
            try side.image(.{ .format = format, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, facet.MEMORY_PROPERTY_LAZILY_ALLOCATED, &side.stencil_images[k]);
            side.stencil_views[k] = try side.view(side.stencil_images[k].?, format, facet.IMAGE_ASPECT_STENCIL, 1);
            const attachments = [2]facet.AttachmentDescription{
                .{ .format = formats[0], .load_op = .clear, .store_op = .store, .final_layout = .general },
                .{ .format = format, .load_op = .clear, .stencil_load_op = .clear, .final_layout = .depth_stencil_attachment_optimal },
            };
            const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
            const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
            const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = &depth };
            try expect(fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &side.stencil_passes[k]), error.Refused);
            const views = [2]*facet.ImageView{ side.picture_views[0].?, side.stencil_views[k].? };
            try expect(fb.CreateFramebuffer(device, &.{ .render_pass = side.stencil_passes[k].?, .attachment_count = 2, .attachments = &views, .width = side.width, .height = side.height }, &side.stencil_framebuffers[k]), error.Refused);
        }

        const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
        try expect(fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &side.set_layout), error.Refused);
        try expect(fb.CreateDescriptorPool(device, &.{ .max_sets = formats.len + 2 + layered_count + throughs.len + shadow_ops.len }, &side.descriptor_pool), error.Refused);
        const layouts: [formats.len]?*facet.DescriptorSetLayout = @splat(side.set_layout);
        try expect(fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = side.descriptor_pool.?, .descriptor_set_count = formats.len, .set_layouts = @ptrCast(&layouts) }, &side.sets), error.Refused);
        for (side.sets, side.texture_views) |set, texture_view| {
            const image_info = facet.DescriptorImageInfo{ .image_view = texture_view };
            const write = facet.WriteDescriptorSet{ .dst_set = set.?, .dst_binding = 0, .descriptor_type = .sampled_image, .image_info = @ptrCast(&image_info) };
            fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
        }
        const combined = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .combined_image_sampler, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
        try expect(fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&combined) }, &side.sampler_set_layout), error.Refused);
        try expect(fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&side.sampler_set_layout) }, &side.sampler_layout), error.Refused);
        const fragment_push = facet.PushConstantRange{ .stage_flags = facet.SHADER_STAGE_FRAGMENT, .size = 20 };
        try expect(fb.CreatePipelineLayout(device, &.{ .push_constant_range_count = 1, .push_constant_ranges = @ptrCast(&fragment_push) }, &side.push_layout), error.Refused);
        // The texture's own levels: the V3D samples through no sampler
        // that holds them to fewer (`texture.samplingOf`), and draws the
        // missing colour instead.
        try expect(fb.CreateSampler(device, &.{ .mag_filter = .nearest, .min_filter = .nearest, .max_lod = facet.texture.lod_unclamped }, &side.sampler), error.Refused);
        var sampled_sets: [1]?*facet.DescriptorSet = undefined;
        try expect(fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = side.descriptor_pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&side.sampler_set_layout) }, &sampled_sets), error.Refused);
        side.sampler_set = sampled_sets[0];
        const sampled_info = facet.DescriptorImageInfo{ .sampler = side.sampler, .image_view = side.texture_views[0] };
        const sampled_write = facet.WriteDescriptorSet{ .dst_set = side.sampler_set.?, .dst_binding = 0, .descriptor_type = .combined_image_sampler, .image_info = @ptrCast(&sampled_info) };
        fb.UpdateDescriptorSets(device, 1, @ptrCast(&sampled_write), 0, null);
        side.first_level = try side.view(side.textures[0].?, formats[0], facet.IMAGE_ASPECT_COLOR, 1);
        // The module ships the SPIR-V of the shaders above beside the
        // functions: the flag says so, and `code_size` that the program's
        // memory is a `shader.Module` wide.
        try expect(fb.CreateShaderModule(device, &.{ .flags = facet.SHADER_MODULE_CREATE_SPIRV, .code_size = @sizeOf(shader.Module), .code = &code }, &side.module), error.Refused);
        try expect(fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&side.set_layout) }, &side.layout), error.Refused);
        try expect(fb.CreateCommandPool(device, &.{ .flags = facet.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER }, &side.command_pool), error.Refused);
        var commands: [1]?*facet.CommandBuffer = undefined;
        try expect(fb.AllocateCommandBuffers(device, &.{ .command_pool = side.command_pool.?, .command_buffer_count = 1 }, &commands), error.Refused);
        side.commands = commands[0];
        try expect(fb.AllocateCommandBuffers(device, &.{ .command_pool = side.command_pool.?, .level = .secondary }, &commands), error.Refused);
        side.secondary = commands[0];
        _ = try side.buffer(@sizeOf(@TypeOf(geometry)), facet.BUFFER_USAGE_STORAGE_BUFFER | facet.BUFFER_USAGE_VERTEX_BUFFER, &side.computed);
        side.number_bytes = try side.buffer(256, facet.BUFFER_USAGE_STORAGE_BUFFER | facet.BUFFER_USAGE_INDIRECT_BUFFER, &side.numbers);
        const compute_bindings = [2]facet.DescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptor_type = .storage_buffer, .stage_flags = facet.SHADER_STAGE_COMPUTE },
            .{ .binding = 1, .descriptor_type = .storage_buffer, .stage_flags = facet.SHADER_STAGE_COMPUTE },
        };
        try expect(fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 2, .bindings = &compute_bindings }, &side.compute_set_layout), error.Refused);
        var made_sets: [1]?*facet.DescriptorSet = undefined;
        try expect(fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = side.descriptor_pool.?, .descriptor_set_count = 1, .set_layouts = @ptrCast(&side.compute_set_layout) }, &made_sets), error.Refused);
        side.compute_set = made_sets[0];
        const buffer_infos = [2]facet.DescriptorBufferInfo{ .{ .buffer = side.computed }, .{ .buffer = side.numbers } };
        const buffer_writes = [2]facet.WriteDescriptorSet{
            .{ .dst_set = side.compute_set.?, .dst_binding = 0, .descriptor_type = .storage_buffer, .buffer_info = @ptrCast(&buffer_infos[0]) },
            .{ .dst_set = side.compute_set.?, .dst_binding = 1, .descriptor_type = .storage_buffer, .buffer_info = @ptrCast(&buffer_infos[1]) },
        };
        fb.UpdateDescriptorSets(device, 2, &buffer_writes, 0, null);
        const compute_push = facet.PushConstantRange{ .stage_flags = facet.SHADER_STAGE_COMPUTE, .size = 8 };
        try expect(fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&side.compute_set_layout), .push_constant_range_count = 1, .push_constant_ranges = @ptrCast(&compute_push) }, &side.compute_layout), error.Refused);
        const compute_infos = [2]facet.ComputePipelineCreateInfo{
            .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = side.module.?, .name = "vertices" }, .layout = side.compute_layout.? },
            .{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = side.module.?, .name = "numbers" }, .layout = side.compute_layout.? },
        };
        try expect(fb.CreateComputePipelines(device, null, 2, &compute_infos, &side.compute_pipelines), error.Refused);
        try expect(fb.CreateFence(device, &.{}, &side.fence), error.Refused);
        try side.stageTextures();
        try side.upLayered();
        try side.upThroughs();
        try side.upPasses();
        try side.upShadow();
        try side.upFour();
    }

    /// The image of four samples, its depth, and the two passes over them:
    /// `resolving`, whose subpass resolves the colour into the first
    /// picture, and `four_alone`, which keeps it for a transfer.
    fn upFour(side: *Side) Failure!void {
        const fb = side.fb;
        const device = side.device.?;
        const extent = facet.Extent3D{ .width = side.width, .height = side.height };
        try side.image(.{ .format = formats[0], .extent = extent, .samples = 4, .usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT | facet.IMAGE_USAGE_TRANSFER_SRC }, 0, &side.four);
        side.four_view = try side.view(side.four.?, formats[0], facet.IMAGE_ASPECT_COLOR, 1);
        try side.image(.{ .format = .d16_unorm, .extent = extent, .samples = 4, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT }, facet.MEMORY_PROPERTY_LAZILY_ALLOCATED, &side.four_depth);
        side.four_depth_view = try side.view(side.four_depth.?, .d16_unorm, facet.IMAGE_ASPECT_DEPTH, 1);
        const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
        {
            const attachments = [3]facet.AttachmentDescription{
                .{ .format = formats[0], .samples = 4, .load_op = .clear, .store_op = .store, .final_layout = .color_attachment_optimal },
                .{ .format = formats[0], .load_op = .dont_care, .store_op = .store, .final_layout = .general },
                .{ .format = .d16_unorm, .samples = 4, .load_op = .clear, .final_layout = .depth_stencil_attachment_optimal },
            };
            const resolve = facet.AttachmentReference{ .attachment = 1, .layout = .color_attachment_optimal };
            const depth = facet.AttachmentReference{ .attachment = 2, .layout = .depth_stencil_attachment_optimal };
            const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .resolve_attachments = @ptrCast(&resolve), .depth_stencil_attachment = &depth };
            try expect(fb.CreateRenderPass(device, &.{ .attachment_count = 3, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &side.resolving), error.Refused);
            const views = [3]*facet.ImageView{ side.four_view.?, side.picture_views[0].?, side.four_depth_view.? };
            try expect(fb.CreateFramebuffer(device, &.{ .render_pass = side.resolving.?, .attachment_count = 3, .attachments = &views, .width = side.width, .height = side.height }, &side.resolving_frame), error.Refused);
        }
        const attachments = [2]facet.AttachmentDescription{
            .{ .format = formats[0], .samples = 4, .load_op = .clear, .store_op = .store, .final_layout = .transfer_src_optimal },
            .{ .format = .d16_unorm, .samples = 4, .load_op = .clear, .final_layout = .depth_stencil_attachment_optimal },
        };
        const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
        const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = &depth };
        try expect(fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &side.four_alone), error.Refused);
        const views = [2]*facet.ImageView{ side.four_view.?, side.four_depth_view.? };
        try expect(fb.CreateFramebuffer(device, &.{ .render_pass = side.four_alone.?, .attachment_count = 2, .attachments = &views, .width = side.width, .height = side.height }, &side.four_alone_frame), error.Refused);
    }

    /// The shadow map, its pass over the first picture and it, and a set
    /// for each of `shadow_ops`: a sampler that reads the nearest texel,
    /// held to the edges, and compares.
    fn upShadow(side: *Side) Failure!void {
        const fb = side.fb;
        const device = side.device.?;
        const extent = facet.Extent3D{ .width = side.width, .height = side.height };
        try side.image(.{ .format = .d16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_SAMPLED }, 0, &side.shadow);
        side.shadow_view = try side.view(side.shadow.?, .d16_unorm, facet.IMAGE_ASPECT_DEPTH, 1);
        const attachments = [2]facet.AttachmentDescription{
            .{ .format = formats[0], .load_op = .clear, .store_op = .store, .final_layout = .general },
            .{ .format = .d16_unorm, .load_op = .clear, .store_op = .store, .final_layout = .shader_read_only_optimal },
        };
        const color = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
        const depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
        const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color), .depth_stencil_attachment = &depth };
        try expect(fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &side.shadow_pass), error.Refused);
        const views = [2]*facet.ImageView{ side.picture_views[0].?, side.shadow_view.? };
        try expect(fb.CreateFramebuffer(device, &.{ .render_pass = side.shadow_pass.?, .attachment_count = 2, .attachments = &views, .width = side.width, .height = side.height }, &side.shadow_frame), error.Refused);
        // The depth alone, as a shadow map's pass is (since 1.18).
        const alone = [1]facet.AttachmentDescription{attachments[1]};
        const alone_depth = facet.AttachmentReference{ .attachment = 0, .layout = .depth_stencil_attachment_optimal };
        const alone_subpass = facet.SubpassDescription{ .depth_stencil_attachment = &alone_depth };
        try expect(fb.CreateRenderPass(device, &.{ .attachment_count = 1, .attachments = &alone, .subpass_count = 1, .subpasses = @ptrCast(&alone_subpass) }, &side.shadow_alone), error.Refused);
        var again = alone;
        again[0].initial_layout = .shader_read_only_optimal;
        try expect(fb.CreateRenderPass(device, &.{ .attachment_count = 1, .attachments = &again, .subpass_count = 1, .subpasses = @ptrCast(&alone_subpass) }, &side.shadow_again), error.Refused);
        const alone_views = [1]*facet.ImageView{side.shadow_view.?};
        try expect(fb.CreateFramebuffer(device, &.{ .render_pass = side.shadow_alone.?, .attachment_count = 1, .attachments = &alone_views, .width = side.width, .height = side.height }, &side.shadow_alone_frame), error.Refused);
        const layouts: [shadow_ops.len]?*facet.DescriptorSetLayout = @splat(side.sampler_set_layout);
        try expect(fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = side.descriptor_pool.?, .descriptor_set_count = shadow_ops.len, .set_layouts = @ptrCast(&layouts) }, &side.shadow_sets), error.Refused);
        for (shadow_ops, &side.shadow_samplers, side.shadow_sets) |op, *made, set| {
            try expect(fb.CreateSampler(device, &.{
                .mag_filter = .nearest,
                .min_filter = .nearest,
                .address_mode_u = .clamp_to_edge,
                .address_mode_v = .clamp_to_edge,
                .compare_enable = true,
                .compare_op = op,
            }, made), error.Refused);
            const info = facet.DescriptorImageInfo{ .sampler = made.*, .image_view = side.shadow_view, .image_layout = .shader_read_only_optimal };
            const write = facet.WriteDescriptorSet{ .dst_set = set.?, .dst_binding = 0, .descriptor_type = .combined_image_sampler, .image_info = @ptrCast(&info) };
            fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
        }
    }

    /// `throughs`' samplers, each in a set of its own with its texture:
    /// after the layered ones, which some of them read.
    fn upThroughs(side: *Side) Failure!void {
        const fb = side.fb;
        const device = side.device.?;
        const through_layouts: [throughs.len]?*facet.DescriptorSetLayout = @splat(side.sampler_set_layout);
        try expect(fb.AllocateDescriptorSets(device, &.{ .descriptor_pool = side.descriptor_pool.?, .descriptor_set_count = throughs.len, .set_layouts = @ptrCast(&through_layouts) }, &side.through_sets), error.Refused);
        for (throughs, &side.through, side.through_sets) |each, *made, set| {
            try expect(fb.CreateSampler(device, &each.info, made), error.Refused);
            const read = switch (each.view) {
                .texture => side.texture_views[0],
                .first_level => side.first_level,
                .array => side.layered_views[@intFromEnum(Layered.array)],
                .cube => side.layered_views[@intFromEnum(Layered.cube)],
                .volume => side.layered_views[@intFromEnum(Layered.volume)],
            };
            const info = facet.DescriptorImageInfo{ .sampler = made.*, .image_view = read };
            const write = facet.WriteDescriptorSet{ .dst_set = set.?, .dst_binding = 0, .descriptor_type = .combined_image_sampler, .image_info = @ptrCast(&info) };
            fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
        }
    }

    fn upPasses(side: *Side) Failure!void {
        const fb = side.fb;
        const device = side.device.?;
        const attachments = [3]facet.AttachmentDescription{
            .{ .format = formats[0], .load_op = .clear, .store_op = .store, .final_layout = .general },
            .{ .format = formats[1], .load_op = .clear, .store_op = .store, .final_layout = .general },
            .{ .format = .d16_unorm, .load_op = .clear, .final_layout = .depth_stencil_attachment_optimal },
        };
        const first = [1]facet.AttachmentReference{.{ .attachment = 0, .layout = .color_attachment_optimal }};
        const second = [1]facet.AttachmentReference{.{ .attachment = 1, .layout = .color_attachment_optimal }};
        const both = [2]facet.AttachmentReference{ .{ .attachment = 0, .layout = .color_attachment_optimal }, .{ .attachment = 1, .layout = .color_attachment_optimal } };
        const depth = facet.AttachmentReference{ .attachment = 2, .layout = .depth_stencil_attachment_optimal };
        const subpasses = [4]facet.SubpassDescription{
            .{ .color_attachment_count = 1, .color_attachments = &first, .depth_stencil_attachment = &depth },
            .{ .color_attachment_count = 1, .color_attachments = &first, .depth_stencil_attachment = &depth },
            .{ .color_attachment_count = 1, .color_attachments = &second },
            .{ .color_attachment_count = 2, .color_attachments = &both },
        };
        try expect(fb.CreateRenderPass(device, &.{ .attachment_count = 3, .attachments = &attachments, .subpass_count = 4, .subpasses = &subpasses }, &side.subpassed), error.Refused);
        const one = facet.SubpassDescription{ .color_attachment_count = 2, .color_attachments = &both, .depth_stencil_attachment = &depth };
        try expect(fb.CreateRenderPass(device, &.{ .attachment_count = 3, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&one) }, &side.two_colors), error.Refused);
        const views = [3]*facet.ImageView{ side.picture_views[0].?, side.picture_views[1].?, side.depth_view.? };
        try expect(fb.CreateFramebuffer(device, &.{ .render_pass = side.subpassed.?, .attachment_count = 3, .attachments = &views, .width = side.width, .height = side.height }, &side.subpassed_frame), error.Refused);
        try expect(fb.CreateFramebuffer(device, &.{ .render_pass = side.two_colors.?, .attachment_count = 3, .attachments = &views, .width = side.width, .height = side.height }, &side.two_colors_frame), error.Refused);

        // The depth drawn first in a subpass of its own, and then the
        // picture tested against it, the depth kept between the two: in a
        // subpass of no colour attachment, or of one ATTACHMENT_UNUSED.
        // The two passes are compatible, so the one framebuffer serves
        // both (since 1.18).
        const unused = [1]facet.AttachmentReference{.{ .attachment = facet.ATTACHMENT_UNUSED, .layout = .color_attachment_optimal }};
        const pre = [2]facet.AttachmentDescription{ attachments[0], attachments[2] };
        const pre_depth = facet.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
        const prepasses = [2]facet.SubpassDescription{
            .{ .depth_stencil_attachment = &pre_depth },
            .{ .color_attachment_count = 1, .color_attachments = &first, .depth_stencil_attachment = &pre_depth },
        };
        try expect(fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &pre, .subpass_count = 2, .subpasses = &prepasses }, &side.prepassed), error.Refused);
        const unused_first = [2]facet.SubpassDescription{
            .{ .color_attachment_count = 1, .color_attachments = &unused, .depth_stencil_attachment = &pre_depth },
            prepasses[1],
        };
        try expect(fb.CreateRenderPass(device, &.{ .attachment_count = 2, .attachments = &pre, .subpass_count = 2, .subpasses = &unused_first }, &side.unused_first), error.Refused);
        const extent = facet.Extent3D{ .width = side.width, .height = side.height };
        try side.image(.{ .format = .d16_unorm, .extent = extent, .usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT }, 0, &side.pre_depth);
        side.pre_depth_view = try side.view(side.pre_depth.?, .d16_unorm, facet.IMAGE_ASPECT_DEPTH, 1);
        const pre_views = [2]*facet.ImageView{ side.picture_views[0].?, side.pre_depth_view.? };
        try expect(fb.CreateFramebuffer(device, &.{ .render_pass = side.prepassed.?, .attachment_count = 2, .attachments = &pre_views, .width = side.width, .height = side.height }, &side.prepassed_frame), error.Refused);

        // No attachment at all: a framebuffer that is a size alone, and a
        // query that counts the samples drawn in it.
        const nothing = facet.SubpassDescription{};
        try expect(fb.CreateRenderPass(device, &.{ .subpass_count = 1, .subpasses = @ptrCast(&nothing) }, &side.empty), error.Refused);
        try expect(fb.CreateFramebuffer(device, &.{ .render_pass = side.empty.?, .attachment_count = 0, .width = side.width, .height = side.height }, &side.empty_frame), error.Refused);
        try expect(fb.CreateQueryPool(device, &.{ .query_type = .occlusion, .query_count = 1 }, &side.queries), error.Refused);
    }

    /// A pass of its own begun, the first picture and the second cleared in
    /// colours of their own.
    fn beginOwn(side: *Side, pass: *facet.RenderPass, frame: *facet.Framebuffer) void {
        const clears = [3]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0.06, 0.09, 0.2, 1 } } }, .{ .color = .{ .float32 = .{ 0.25, 0.1, 0.05, 1 } } }, .{ .depth_stencil = .{ .depth = 1 } } };
        side.fb.CmdBeginRenderPass(side.commands.?, &.{ .render_pass = pass, .framebuffer = frame, .render_area = .{ .extent = .{ .width = side.width, .height = side.height } }, .clear_value_count = 3, .clear_values = &clears }, .@"inline");
        side.state();
    }

    /// The textures of layers, each a descriptor set of its own, their texels
    /// copied in.
    fn upLayered(side: *Side) Failure!void {
        const fb = side.fb;
        const usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST;
        const square = facet.Extent3D{ .width = layer_side, .height = layer_side };
        const kept = facet.Format.r8g8b8a8_unorm;
        try side.image(.{ .format = kept, .extent = square, .mip_levels = array_levels, .array_layers = array_layers, .usage = usage | facet.IMAGE_USAGE_TRANSFER_SRC }, 0, side.layeredImage(.array));
        try side.image(.{ .format = kept, .flags = facet.IMAGE_CREATE_CUBE_COMPATIBLE, .extent = square, .array_layers = 6, .usage = usage }, 0, side.layeredImage(.cube));
        try side.image(.{ .format = kept, .image_type = .@"3d", .extent = .{ .width = volume_side, .height = volume_side, .depth = volume_depth }, .usage = usage }, 0, side.layeredImage(.volume));
        try side.image(.{ .format = kept, .extent = square, .array_layers = 2, .usage = usage }, 0, side.layeredImage(.copied));
        const small = facet.Extent3D{ .width = unpacked_side, .height = unpacked_side };
        for (compressed_and_float) |each| try side.image(.{ .format = each.format, .extent = small, .usage = usage }, 0, side.layeredImage(each.which));

        const array = side.layeredImage(.array).*.?;
        try side.layeredView(.array, .{ .image = array, .format = kept, .view_type = .@"2d_array" });
        try side.layeredView(.cube, .{ .image = side.layeredImage(.cube).*.?, .format = kept, .view_type = .cube });
        try side.layeredView(.volume, .{ .image = side.layeredImage(.volume).*.?, .format = kept, .view_type = .@"3d" });
        try side.layeredView(.array_layer, .{ .image = array, .format = kept, .subresource_range = .{ .level_count = 1, .base_array_layer = 2, .layer_count = 1 } });
        try side.layeredView(.copied, .{ .image = side.layeredImage(.copied).*.?, .format = kept, .subresource_range = .{ .base_array_layer = 1, .layer_count = 1 } });
        for (compressed_and_float) |each| try side.layeredView(each.which, .{ .image = side.layeredImage(each.which).*.?, .format = each.format });

        const layouts: [layered_count]?*facet.DescriptorSetLayout = @splat(side.set_layout);
        try expect(fb.AllocateDescriptorSets(side.device.?, &.{ .descriptor_pool = side.descriptor_pool.?, .descriptor_set_count = layered_count, .set_layouts = @ptrCast(&layouts) }, &side.layered_sets), error.Refused);
        for (side.layered_sets, side.layered_views) |set, texture_view| {
            const image_info = facet.DescriptorImageInfo{ .image_view = texture_view };
            const write = facet.WriteDescriptorSet{ .dst_set = set.?, .dst_binding = 0, .descriptor_type = .sampled_image, .image_info = @ptrCast(&image_info) };
            fb.UpdateDescriptorSets(side.device.?, 1, @ptrCast(&write), 0, null);
        }

        // A level at a time, all an array's layers in one region; all a
        // volume's slices in one; a cube's faces each in one.
        const staged = try side.buffer(1 << 20, facet.BUFFER_USAGE_TRANSFER_SRC, &side.layered_staging);
        const commands = side.commands.?;
        try expect(fb.BeginCommandBuffer(commands, &.{ .flags = facet.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT }), error.Refused);
        var used: usize = 0;
        for (0..array_levels) |l| {
            const level: u32 = @intCast(l);
            const across: u32 = layer_side >> @intCast(level);
            const region = facet.BufferImageCopy{ .buffer_offset = used, .image_subresource = .{ .mip_level = level, .layer_count = array_layers }, .image_extent = .{ .width = across, .height = across } };
            for (0..array_layers) |layer| for (0..across) |y| for (0..across) |x| {
                staged[used..][0..4].* = layerTexel(layer, level, x, y);
                used += 4;
            };
            fb.CmdCopyBufferToImage(commands, side.layered_staging.?, array, .transfer_dst_optimal, 1, @ptrCast(&region));
        }
        for (0..6) |face| {
            const region = facet.BufferImageCopy{ .buffer_offset = used, .image_subresource = .{ .base_array_layer = @intCast(face) }, .image_extent = square };
            for (0..layer_side) |y| for (0..layer_side) |x| {
                staged[used..][0..4].* = layerTexel(face, 0, x, y);
                used += 4;
            };
            fb.CmdCopyBufferToImage(commands, side.layered_staging.?, side.layeredImage(.cube).*.?, .transfer_dst_optimal, 1, @ptrCast(&region));
        }
        const slices = facet.BufferImageCopy{ .buffer_offset = used, .image_extent = .{ .width = volume_side, .height = volume_side, .depth = volume_depth } };
        for (0..volume_depth) |slice| for (0..volume_side) |y| for (0..volume_side) |x| {
            staged[used..][0..4].* = layerTexel(slice, 0, x, y);
            used += 4;
        };
        fb.CmdCopyBufferToImage(commands, side.layered_staging.?, side.layeredImage(.volume).*.?, .transfer_dst_optimal, 1, @ptrCast(&slices));
        for (compressed_and_float) |each| {
            const region = facet.BufferImageCopy{ .buffer_offset = used, .image_extent = small };
            switch (each.format) {
                .bc1_rgb_unorm_block, .bc1_rgba_unorm_block, .bc2_unorm_block, .bc3_unorm_block => used += stageBlocks(each.format, staged[used..(1 << 20)]),
                else => for (0..unpacked_side) |y| for (0..unpacked_side) |x| {
                    used += stageFloat(each.format, x, y, staged[used..(1 << 20)]);
                },
            }
            fb.CmdCopyBufferToImage(commands, side.layered_staging.?, side.layeredImage(each.which).*.?, .transfer_dst_optimal, 1, @ptrCast(&region));
        }
        try side.submit();
    }

    fn layeredImage(side: *Side, which: Layered) *?*facet.Image {
        return &side.layered_images[@intFromEnum(which)];
    }

    fn layeredView(side: *Side, which: Layered, info: facet.ImageViewCreateInfo) Failure!void {
        try expect(side.fb.CreateImageView(side.device.?, &info, &side.layered_views[@intFromEnum(which)]), error.Refused);
    }

    fn layeredTexture(side: *Side, which: Layered) void {
        side.fb.CmdBindDescriptorSets(side.commands.?, .graphics, side.layout.?, 0, 1, @ptrCast(&side.layered_sets[@intFromEnum(which)]), 0, null);
    }

    /// Each texture's levels, a level's checks of a colour of its own, so
    /// that a level read for another shows.
    fn stageTextures(side: *Side) Failure!void {
        const fb = side.fb;
        var total: u64 = 0;
        for (formats) |format| {
            const texel_bytes: u64 = if (format == .r5g6b5_unorm_pack16) 2 else 4;
            for (0..texture_levels) |level| total += @as(u64, texture_side >> @intCast(level)) * (texture_side >> @intCast(level)) * texel_bytes;
        }
        const staged = try side.buffer(total, facet.BUFFER_USAGE_TRANSFER_SRC, &side.staging);
        try expect(fb.BeginCommandBuffer(side.commands.?, &.{ .flags = facet.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT }), error.Refused);
        var used: usize = 0;
        for (formats, side.textures) |format, target_image| {
            var regions: [texture_levels]facet.BufferImageCopy = undefined;
            for (&regions, 0..) |*region, l| {
                const level: u32 = @intCast(l);
                const across: u32 = texture_side >> @intCast(level);
                region.* = .{ .buffer_offset = used, .image_subresource = .{ .mip_level = level }, .image_extent = .{ .width = across, .height = across } };
                for (0..across) |y| for (0..across) |x| {
                    const texel = texelAt(level, @intCast(x), @intCast(y));
                    switch (format) {
                        .b8g8r8a8_unorm => std.mem.writeInt(u32, staged[used..][0..4], texel, .little),
                        .r8g8b8a8_unorm => std.mem.writeInt(u32, staged[used..][0..4], texel & 0xFF00_FF00 | (texel >> 16 & 0xFF) | (texel & 0xFF) << 16, .little),
                        else => {
                            const packed565: u16 = @intCast((texel >> 8 & 0xF800) | (texel >> 5 & 0x07E0) | (texel >> 3 & 0x1F));
                            std.mem.writeInt(u16, staged[used..][0..2], packed565, .little);
                        },
                    }
                    used += if (format == .r5g6b5_unorm_pack16) 2 else 4;
                };
            }
            fb.CmdCopyBufferToImage(side.commands.?, side.staging.?, target_image.?, .transfer_dst_optimal, texture_levels, &regions);
        }
        try side.submit();
    }

    fn texelAt(level: u32, x: u32, y: u32) u32 {
        const check = ((x >> 2) ^ (y >> 2)) & 1;
        const tint = 0x20 + level * 0x20;
        const r = if (check != 0) 0xF0 else tint;
        const g = if (check != 0) tint else 0x40 + x;
        const b = 0x20 + y;
        return 0xFF00_0000 | r << 16 | (g & 0xFF) << 8 | (b & 0xFF);
    }

    fn buffer(side: *Side, bytes: u64, usage: u32, into: *?*facet.Buffer) Failure![*]u8 {
        const fb = side.fb;
        try expect(fb.CreateBuffer(side.device.?, &.{ .size = bytes, .usage = usage }, into), error.Refused);
        var needs: facet.MemoryRequirements = undefined;
        fb.GetBufferMemoryRequirements(side.device.?, into.*.?, &needs);
        const block = try side.allocate(needs, facet.MEMORY_PROPERTY_HOST_VISIBLE);
        try expect(fb.BindBufferMemory(side.device.?, into.*.?, block, 0), error.Refused);
        var data: ?*anyopaque = null;
        try expect(fb.MapMemory(side.device.?, block, 0, facet.WHOLE_SIZE, 0, &data), error.Refused);
        return @ptrCast(data.?);
    }

    fn image(side: *Side, info: facet.ImageCreateInfo, wanted: u32, into: *?*facet.Image) Failure!void {
        _ = try side.imageGiving(info, wanted, into);
    }

    fn imageGiving(side: *Side, info: facet.ImageCreateInfo, wanted: u32, into: *?*facet.Image) Failure!*facet.DeviceMemory {
        const fb = side.fb;
        try expect(fb.CreateImage(side.device.?, &info, into), error.Refused);
        var needs: facet.MemoryRequirements = undefined;
        fb.GetImageMemoryRequirements(side.device.?, into.*.?, &needs);
        const block = try side.allocate(needs, wanted);
        try expect(fb.BindImageMemory(side.device.?, into.*.?, block, 0), error.Refused);
        return block;
    }

    fn view(side: *Side, of: *facet.Image, format: facet.Format, aspect: u32, levels: u32) Failure!*facet.ImageView {
        var made: ?*facet.ImageView = null;
        try expect(side.fb.CreateImageView(side.device.?, &.{ .image = of, .format = format, .subresource_range = .{ .aspect_mask = aspect, .level_count = levels } }, &made), error.Refused);
        return made.?;
    }

    fn allocate(side: *Side, needs: facet.MemoryRequirements, wanted: u32) Failure!*facet.DeviceMemory {
        if (side.block_count == side.blocks.len) return error.NoMemory;
        for (side.memory.memory_types[0..side.memory.memory_type_count], 0..) |kind, k| {
            if (needs.memory_type_bits & @as(u32, 1) << @intCast(k) != 0 and kind.property_flags & wanted == wanted) {
                const slot = &side.blocks[side.block_count];
                try expect(side.fb.AllocateMemory(side.device.?, &.{ .allocation_size = needs.size, .memory_type_index = @intCast(k) }, slot), error.NoMemory);
                side.block_count += 1;
                return slot.*.?;
            }
        }
        return error.NoMemory;
    }

    fn down(side: *Side) void {
        const fb = side.fb;
        const device = side.device orelse return;
        _ = fb.DeviceWaitIdle(device);
        for (side.compute_pipelines) |each| fb.DestroyPipeline(device, each);
        fb.DestroyPipelineLayout(device, side.compute_layout);
        fb.DestroyDescriptorSetLayout(device, side.compute_set_layout);
        fb.DestroyBuffer(device, side.computed);
        fb.DestroyBuffer(device, side.numbers);
        fb.DestroyFence(device, side.fence);
        fb.DestroyFramebuffer(device, side.resolving_frame);
        fb.DestroyFramebuffer(device, side.four_alone_frame);
        fb.DestroyRenderPass(device, side.resolving);
        fb.DestroyRenderPass(device, side.four_alone);
        fb.DestroyImageView(device, side.four_view);
        fb.DestroyImageView(device, side.four_depth_view);
        fb.DestroyImage(device, side.four);
        fb.DestroyImage(device, side.four_depth);
        fb.DestroyQueryPool(device, side.queries);
        fb.DestroyFramebuffer(device, side.empty_frame);
        fb.DestroyRenderPass(device, side.empty);
        fb.DestroyFramebuffer(device, side.prepassed_frame);
        fb.DestroyRenderPass(device, side.prepassed);
        fb.DestroyRenderPass(device, side.unused_first);
        fb.DestroyImageView(device, side.pre_depth_view);
        fb.DestroyImage(device, side.pre_depth);
        fb.DestroyFramebuffer(device, side.subpassed_frame);
        fb.DestroyFramebuffer(device, side.two_colors_frame);
        fb.DestroyRenderPass(device, side.subpassed);
        fb.DestroyRenderPass(device, side.two_colors);
        fb.DestroyCommandPool(device, side.command_pool);
        fb.DestroyPipelineLayout(device, side.layout);
        fb.DestroyPipelineLayout(device, side.sampler_layout);
        fb.DestroyPipelineLayout(device, side.push_layout);
        fb.DestroyShaderModule(device, side.module);
        fb.DestroyDescriptorPool(device, side.descriptor_pool);
        fb.DestroyDescriptorSetLayout(device, side.set_layout);
        fb.DestroyDescriptorSetLayout(device, side.sampler_set_layout);
        fb.DestroySampler(device, side.sampler);
        for (side.through) |each| fb.DestroySampler(device, each);
        fb.DestroyImageView(device, side.first_level);
        for (side.shadow_samplers) |each| fb.DestroySampler(device, each);
        fb.DestroyFramebuffer(device, side.shadow_alone_frame);
        fb.DestroyRenderPass(device, side.shadow_alone);
        fb.DestroyRenderPass(device, side.shadow_again);
        fb.DestroyFramebuffer(device, side.shadow_frame);
        fb.DestroyRenderPass(device, side.shadow_pass);
        fb.DestroyImageView(device, side.shadow_view);
        fb.DestroyImage(device, side.shadow);
        for (&side.framebuffers) |*pair| for (pair) |each| fb.DestroyFramebuffer(device, each);
        for (side.stencil_framebuffers) |each| fb.DestroyFramebuffer(device, each);
        for (side.stencil_passes) |each| fb.DestroyRenderPass(device, each);
        for (side.stencil_views) |each| fb.DestroyImageView(device, each);
        for (side.stencil_images) |each| fb.DestroyImage(device, each);
        for (side.picture_views) |each| fb.DestroyImageView(device, each);
        for (side.pictures) |each| fb.DestroyImage(device, each);
        for (side.texture_views) |each| fb.DestroyImageView(device, each);
        for (side.textures) |each| fb.DestroyImage(device, each);
        for (side.layered_views) |each| fb.DestroyImageView(device, each);
        for (side.layered_images) |each| fb.DestroyImage(device, each);
        fb.DestroyBuffer(device, side.layered_staging);
        fb.DestroyImageView(device, side.depth_view);
        fb.DestroyImage(device, side.depth);
        for (&side.passes) |*by_depth| for (by_depth) |*by_load| for (by_load) |each| fb.DestroyRenderPass(device, each);
        fb.DestroyBuffer(device, side.vertices);
        fb.DestroyBuffer(device, side.places);
        fb.DestroyBuffer(device, side.indices);
        fb.DestroyBuffer(device, side.staging);
        for (side.blocks[0..side.block_count]) |block| fb.FreeMemory(device, block);
        fb.DestroyDevice(device);
        side.device = null;
    }

    fn submit(side: *Side) Failure!void {
        const fb = side.fb;
        try expect(fb.EndCommandBuffer(side.commands.?), error.Refused);
        const info = facet.SubmitInfo{ .command_buffer_count = 1, .command_buffers = @ptrCast(&side.commands) };
        try expect(fb.QueueSubmit(side.queue, 1, @ptrCast(&info), side.fence), error.Refused);
        try expect(fb.WaitForFences(side.device.?, 1, @ptrCast(&side.fence), true, facet.WAIT_FOREVER_NS), error.Refused);
        try expect(fb.ResetFences(side.device.?, 1, @ptrCast(&side.fence)), error.Refused);
    }

    /// A pass begun over the picture, the whole viewport and scissor set and
    /// the vertex buffers bound.
    fn begin(side: *Side, pass: Pass) void {
        const fb = side.fb;
        const commands = side.commands.?;
        const t = @intFromEnum(pass.target);
        const d = @intFromBool(pass.depth);
        const clears = [2]facet.ClearValue{ .{ .color = .{ .float32 = pass.clear } }, .{ .depth_stencil = .{ .depth = 1, .stencil = pass.clear_stencil } } };
        const area = side.areaOf(pass.area);
        const s = @intFromEnum(pass.stencil) -| 1;
        const stenciled = pass.stencil != .none;
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = if (stenciled) side.stencil_passes[s].? else side.passes[t][d][@intFromBool(pass.load)].?, .framebuffer = if (stenciled) side.stencil_framebuffers[s].? else side.framebuffers[t][d].?, .render_area = area, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
        side.state();
    }

    /// Parts of 1 of the picture as a render area; all of it if null.
    fn areaOf(side: *const Side, part: ?[4]f32) facet.Rect2D {
        const given = part orelse return .{ .extent = .{ .width = side.width, .height = side.height } };
        return .{
            .offset = .{ .x = side.partOf(side.width, given[0]), .y = side.partOf(side.height, given[1]) },
            .extent = .{
                .width = @intCast(side.partOf(side.width, given[2]) - side.partOf(side.width, given[0])),
                .height = @intCast(side.partOf(side.height, given[3]) - side.partOf(side.height, given[1])),
            },
        };
    }

    /// A pass of four samples begun over `area`: `resolving`, or
    /// `four_alone`, each clearing the colour to a red of its own and the
    /// depth to 1 (since 1.16).
    fn beginFour(side: *Side, resolves: bool, area: ?[4]f32) void {
        const color = facet.ClearValue{ .color = .{ .float32 = .{ 0.3, 0.12, 0.05, 1 } } };
        const depth = facet.ClearValue{ .depth_stencil = .{ .depth = 1 } };
        const clears = if (resolves) [3]facet.ClearValue{ color, color, depth } else [3]facet.ClearValue{ color, depth, depth };
        side.fb.CmdBeginRenderPass(side.commands.?, &.{
            .render_pass = if (resolves) side.resolving.? else side.four_alone.?,
            .framebuffer = if (resolves) side.resolving_frame.? else side.four_alone_frame.?,
            .render_area = side.areaOf(area),
            .clear_value_count = if (resolves) 3 else 2,
            .clear_values = &clears,
        }, .@"inline");
        side.state();
    }

    /// The whole viewport and scissor set and the vertex buffers bound.
    fn state(side: *Side) void {
        const fb = side.fb;
        const commands = side.commands.?;
        side.setViewport(0, 0, @floatFromInt(side.width), @floatFromInt(side.height), 0, 1);
        const whole = facet.Rect2D{ .extent = .{ .width = side.width, .height = side.height } };
        fb.CmdSetScissor(commands, 0, 1, @ptrCast(&whole));
        const buffers = [2]*facet.Buffer{ side.vertices.?, side.places.? };
        const offsets = [2]u64{ 0, 0 };
        fb.CmdBindVertexBuffers(commands, 0, 2, &buffers, &offsets);
    }

    /// The computed buffer in place of the vertices.
    fn drawComputed(side: *Side) void {
        const buffers = [2]*facet.Buffer{ side.computed.?, side.places.? };
        const offsets = [2]u64{ 0, 0 };
        side.fb.CmdBindVertexBuffers(side.commands.?, 0, 2, &buffers, &offsets);
    }

    /// A compute pipeline bound, with the set they write through.
    fn compute(side: *Side, which: usize, push: [2]f32) void {
        const fb = side.fb;
        const commands = side.commands.?;
        fb.CmdBindPipeline(commands, .compute, side.compute_pipelines[which].?);
        fb.CmdBindDescriptorSets(commands, .compute, side.compute_layout.?, 0, 1, @ptrCast(&side.compute_set), 0, null);
        fb.CmdPushConstants(commands, side.compute_layout.?, facet.SHADER_STAGE_COMPUTE, 0, 8, &push);
    }

    fn partOf(_: *const Side, whole: u32, part: f32) i32 {
        return @intFromFloat(@as(f32, @floatFromInt(whole)) * part);
    }

    fn setViewport(side: *Side, x: f32, y: f32, width: f32, height: f32, min_depth: f32, max_depth: f32) void {
        const viewport = facet.Viewport{ .x = x, .y = y, .width = width, .height = height, .min_depth = min_depth, .max_depth = max_depth };
        side.fb.CmdSetViewport(side.commands.?, 0, 1, @ptrCast(&viewport));
    }

    fn end(side: *Side) void {
        side.fb.CmdEndRenderPass(side.commands.?);
    }

    /// A pipeline as `options` say, made for this case and bound.
    fn use(side: *Side, options: Options) Failure!void {
        const fb = side.fb;
        const stages = [4]facet.PipelineShaderStageCreateInfo{
            .{ .stage = facet.SHADER_STAGE_VERTEX, .module = side.module.?, .name = options.vertex },
            .{ .stage = facet.SHADER_STAGE_FRAGMENT, .module = side.module.?, .name = options.fragment },
            .{ .stage = facet.SHADER_STAGE_TESSELLATION_CONTROL, .module = side.module.?, .name = options.control },
            .{ .stage = facet.SHADER_STAGE_TESSELLATION_EVALUATION, .module = side.module.?, .name = options.evaluation },
        };
        const tessellation = facet.PipelineTessellationStateCreateInfo{ .patch_control_points = options.patch_points };
        const bindings = [2]facet.VertexInputBindingDescription{
            .{ .binding = 0, .stride = @sizeOf(Vertex) },
            .{ .binding = 1, .stride = @sizeOf([2]f32), .input_rate = .instance },
        };
        const attributes = [4]facet.VertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "p") },
            .{ .location = 1, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "c") },
            .{ .location = 2, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "uv") },
            .{ .location = 3, .binding = 1, .format = .r32g32_sfloat },
        };
        const input = facet.PipelineVertexInputStateCreateInfo{ .vertex_binding_description_count = 2, .vertex_binding_descriptions = &bindings, .vertex_attribute_description_count = 4, .vertex_attribute_descriptions = &attributes };
        const assembly = facet.PipelineInputAssemblyStateCreateInfo{ .topology = if (options.patch_points != 0) .patch_list else options.topology, .primitive_restart_enable = options.restart };
        const viewports = facet.PipelineViewportStateCreateInfo{};
        const dynamic_states = [3]facet.DynamicState{ .viewport, .scissor, if (options.dynamic_reference) .stencil_reference else .blend_constants };
        const dynamic = facet.PipelineDynamicStateCreateInfo{ .dynamic_state_count = if (options.dynamic_constants or options.dynamic_reference) 3 else 2, .dynamic_states = &dynamic_states };
        const rasterization = facet.PipelineRasterizationStateCreateInfo{ .cull_mode = options.cull, .front_face = options.winding, .polygon_mode = options.polygon_mode, .line_width = options.line_width };
        const depth = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = options.test_depth, .depth_write_enable = options.write_depth, .depth_compare_op = options.compare, .stencil_test_enable = options.stencil_test, .front = options.front, .back = options.back };
        const blend_attachment = options.mixing orelse facet.PipelineColorBlendAttachmentState{
            .blend_enable = options.blend,
            .src_color_blend_factor = if (options.blend) .src_alpha else .one,
            .dst_color_blend_factor = if (options.add) .one else if (options.blend) .one_minus_src_alpha else .zero,
            .src_alpha_blend_factor = if (options.blend) .src_alpha else .one,
            .dst_alpha_blend_factor = if (options.blend) .one_minus_src_alpha else .zero,
        };
        const blend_attachments: [4]facet.PipelineColorBlendAttachmentState = @splat(blend_attachment);
        const blend = facet.PipelineColorBlendStateCreateInfo{ .attachment_count = options.colors, .attachments = &blend_attachments, .blend_constants = options.constants };
        const mask = [1]u32{options.sample_mask orelse 0xFFFF_FFFF};
        const multisample = facet.PipelineMultisampleStateCreateInfo{ .rasterization_samples = options.samples, .sample_mask = if (options.sample_mask != null) &mask else null, .alpha_to_coverage_enable = options.alpha_to_coverage };
        const info = facet.GraphicsPipelineCreateInfo{
            .stage_count = if (options.patch_points != 0) 4 else if (options.no_fragment) 1 else 2,
            .stages = &stages,
            .vertex_input_state = &input,
            .input_assembly_state = &assembly,
            .tessellation_state = if (options.patch_points != 0) &tessellation else null,
            .viewport_state = &viewports,
            .rasterization_state = &rasterization,
            .depth_stencil_state = &depth,
            .multisample_state = if (options.samples != 1) &multisample else null,
            .color_blend_state = &blend,
            .dynamic_state = &dynamic,
            .layout = options.layout orelse side.layout.?,
            .render_pass = options.pass orelse if (options.stencil != .none) side.stencil_passes[@intFromEnum(options.stencil) - 1].? else side.passes[@intFromEnum(options.target)][@intFromBool(options.depth)][@intFromBool(options.load)].?,
            .subpass = options.subpass,
        };
        const slot = &side.made[side.made_count];
        var made: [1]?*facet.Pipeline = undefined;
        try expect(fb.CreateGraphicsPipelines(side.device.?, null, 1, @ptrCast(&info), &made), error.Refused);
        slot.* = made[0];
        side.made_count += 1;
        fb.CmdBindPipeline(side.commands.?, .graphics, made[0].?);
    }

    fn forgetPipelines(side: *Side) void {
        for (side.made[0..side.made_count]) |each| side.fb.DestroyPipeline(side.device.?, each);
        side.made_count = 0;
    }

    fn draw(side: *Side, first: u32, count: u32) void {
        side.fb.CmdDraw(side.commands.?, count, 1, first, 0);
    }

    fn texture(side: *Side, format: usize) void {
        side.fb.CmdBindDescriptorSets(side.commands.?, .graphics, side.layout.?, 0, 1, @ptrCast(&side.sets[format]), 0, null);
    }

    /// The combined image sampler a shipped shader samples through.
    fn sampled(side: *Side) void {
        side.fb.CmdBindDescriptorSets(side.commands.?, .graphics, side.sampler_layout.?, 0, 1, @ptrCast(&side.sampler_set), 0, null);
    }
};

const offset_16 = @sizeOf(@TypeOf(restart_indices)) + 2;
const offset_32 = (offset_16 + @sizeOf(@TypeOf(indices_16)) + 3) / 4 * 4;

const Case = struct {
    name: [*:0]const u8,
    target: Target = .bgra,
    run: *const fn (side: *Side) Failure!void,
    /// How many steps of a channel two pixels may be apart and count as
    /// the same, where it is not `compare`'s own: only where Vulkan
    /// leaves the answer to the implementation (since 1.140).
    slack: ?u32 = null,
    /// The case counts what it draws with `Side.queries`, and the two
    /// counts are compared as well as the pictures (since 1.18).
    counted: bool = false,
};

const Cases = struct {
    fn clear(side: *Side) Failure!void {
        side.begin(.{});
        side.end();
    }
    fn triangles(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(clockwise_at, 6);
        side.end();
    }
    fn strip(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .topology = .triangle_strip });
        side.draw(strip_at, 5);
        side.end();
    }
    fn fan(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .topology = .triangle_fan });
        side.draw(fan_at, 5);
        side.end();
    }
    fn restart(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .topology = .triangle_strip, .restart = true });
        side.fb.CmdBindIndexBuffer(side.commands.?, side.indices.?, 0, .uint16);
        side.fb.CmdDrawIndexed(side.commands.?, restart_indices.len, 1, 0, strip_at, 0);
        side.end();
    }
    fn indexed16(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.fb.CmdBindIndexBuffer(side.commands.?, side.indices.?, offset_16, .uint16);
        side.fb.CmdDrawIndexed(side.commands.?, indices_16.len, 1, 0, counter_at, 0);
        side.end();
    }
    fn indexed32(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.fb.CmdBindIndexBuffer(side.commands.?, side.indices.?, offset_32, .uint32);
        side.fb.CmdDrawIndexed(side.commands.?, indices_32.len, 1, 0, 0, 0);
        side.end();
    }
    fn instances(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .blend = true });
        side.fb.CmdDraw(side.commands.?, 3, instance_places.len, glass_at, 0);
        side.end();
    }
    fn cullBack(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .cull = facet.CULL_MODE_BACK, .winding = .clockwise });
        side.draw(clockwise_at, 6);
        side.end();
    }
    fn cullFront(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .cull = facet.CULL_MODE_FRONT, .winding = .clockwise });
        side.draw(clockwise_at, 6);
        side.end();
    }
    fn cullBackCounter(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .cull = facet.CULL_MODE_BACK, .winding = .counter_clockwise });
        side.draw(clockwise_at, 6);
        side.end();
    }
    fn depthLess(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .test_depth = true, .write_depth = true });
        side.draw(far_at, 3);
        side.draw(near_at, 3);
        side.end();
    }
    fn depthNearFirst(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .test_depth = true, .write_depth = true });
        side.draw(near_at, 3);
        side.draw(far_at, 3);
        side.end();
    }
    fn depthGreater(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .test_depth = true, .write_depth = true, .compare = .always });
        side.draw(near_at, 3);
        try side.use(.{ .test_depth = true, .write_depth = true, .compare = .greater });
        side.draw(far_at, 3);
        side.end();
    }
    fn depthNoWrite(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .test_depth = true, .write_depth = false });
        side.draw(near_at, 3);
        side.draw(far_at, 3);
        side.end();
    }
    fn noDepthAttachment(side: *Side) Failure!void {
        side.begin(.{ .depth = false });
        try side.use(.{ .depth = false });
        side.draw(near_at, 3);
        side.draw(far_at, 3);
        side.end();
    }
    fn blend(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(far_at, 3);
        try side.use(.{ .blend = true });
        side.draw(glass_at, 3);
        side.end();
    }
    fn blendAdded(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(far_at, 3);
        try side.use(.{ .blend = true, .add = true });
        side.draw(glass_at, 3);
        side.draw(glass_at, 3);
        side.end();
    }
    /// Over the far triangle in opaque colour, glass drawn as `mixing` says.
    fn mixed(comptime mixing: facet.PipelineColorBlendAttachmentState, comptime constants: [4]f32) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                side.begin(.{});
                try side.use(.{});
                side.draw(far_at, 3);
                try side.use(.{ .mixing = mixing, .constants = constants });
                side.draw(glass_at, 3);
                side.draw(near_at, 3);
                side.end();
            }
        }.run;
    }
    /// A step of a stencil case: `count` vertices from `first`, as its test
    /// says; nothing written of the colour unless `shows`.
    const StencilStep = struct {
        first: u32,
        count: u32,
        topology: facet.PrimitiveTopology = .triangle_list,
        front: facet.StencilOpState = .{},
        /// The front's if null.
        back: ?facet.StencilOpState = null,
        test_depth: bool = false,
        write_depth: bool = false,
        shows: bool = false,
    };
    /// Steps drawn on a picture cleared with a stencil of `cleared`, and
    /// then the rectangle wherever the stencil and `last` agree.
    fn stencilSteps(comptime kind: Stencil, comptime cleared: u32, comptime steps: []const StencilStep, comptime last: facet.StencilOpState) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                side.begin(.{ .stencil = kind, .clear_stencil = cleared });
                for (steps) |step| {
                    try side.use(.{
                        .stencil = kind,
                        .stencil_test = true,
                        .topology = step.topology,
                        .front = step.front,
                        .back = step.back orelse step.front,
                        .test_depth = step.test_depth,
                        .write_depth = step.write_depth,
                        .mixing = .{ .color_write_mask = if (step.shows) facet.COLOR_COMPONENT_ALL else 0 },
                    });
                    side.draw(step.first, step.count);
                }
                try side.use(.{ .stencil = kind, .stencil_test = true, .front = last, .back = last });
                side.draw(quad_at, 6);
                side.end();
            }
        }.run;
    }
    fn stencilByCommands(side: *Side) Failure!void {
        side.begin(.{ .stencil = .with_depth });
        const mark = facet.StencilOpState{ .pass_op = .replace, .compare_op = .always, .write_mask = 0xFF };
        try side.use(.{ .stencil = .with_depth, .stencil_test = true, .dynamic_reference = true, .front = mark, .back = mark, .mixing = .{ .color_write_mask = 0 } });
        side.fb.CmdSetStencilReference(side.commands.?, facet.STENCIL_FACE_FRONT_AND_BACK, 7);
        side.draw(far_at, 3);
        side.fb.CmdSetStencilReference(side.commands.?, facet.STENCIL_FACE_FRONT_AND_BACK, 9);
        side.draw(near_at, 3);
        const equal = facet.StencilOpState{ .compare_op = .equal, .compare_mask = 0xFF };
        try side.use(.{ .stencil = .with_depth, .stencil_test = true, .dynamic_reference = true, .front = equal, .back = equal });
        side.fb.CmdSetStencilReference(side.commands.?, facet.STENCIL_FACE_FRONT_AND_BACK, 7);
        side.draw(quad_at, 6);
        side.end();
    }
    /// A picture to read from: a strip of triangles over the clear colour.
    fn drawnPicture(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(clockwise_at, 6);
        side.end();
    }
    fn copied(side: *Side) Failure!void {
        try Cases.drawnPicture(side);
        side.begin(.{ .target = .rgba });
        side.end();
        const moved = facet.ImageCopy{ .src_offset = .{ .x = 20, .y = 10 }, .dst_offset = .{ .x = 40, .y = 30 }, .extent = .{ .width = side.width - 100, .height = side.height - 50 } };
        side.fb.CmdCopyImage(side.commands.?, side.pictures[0].?, .general, side.pictures[1].?, .general, 1, @ptrCast(&moved));
    }
    fn copiedTexture(side: *Side) Failure!void {
        side.begin(.{});
        side.end();
        const levels = [3]facet.ImageCopy{
            .{ .dst_offset = .{ .x = 10, .y = 10 }, .extent = .{ .width = 64, .height = 64 } },
            .{ .src_subresource = .{ .mip_level = 1 }, .dst_offset = .{ .x = 90, .y = 10 }, .extent = .{ .width = 32, .height = 32 } },
            .{ .src_subresource = .{ .mip_level = 3 }, .src_offset = .{ .x = 2, .y = 3 }, .dst_offset = .{ .x = 140, .y = 10 }, .extent = .{ .width = 4, .height = 4 } },
        };
        side.fb.CmdCopyImage(side.commands.?, side.textures[0].?, .general, side.pictures[0].?, .general, levels.len, &levels);
    }
    fn blitted(comptime filter: facet.Filter, comptime turned: bool, comptime target: Target) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                try Cases.drawnPicture(side);
                if (target != .bgra) {
                    side.begin(.{ .target = target });
                    side.end();
                }
                const w: i32 = @intCast(side.width);
                const h: i32 = @intCast(side.height);
                const blit = facet.ImageBlit{
                    .src_offsets = .{ .{ .x = 0, .y = 0 }, .{ .x = w, .y = h, .z = 1 } },
                    .dst_offsets = if (turned) .{ .{ .x = w - 20, .y = h - 40 }, .{ .x = 30, .y = 20, .z = 1 } } else .{ .{ .x = 30, .y = 20 }, .{ .x = w - 20, .y = h - 40, .z = 1 } },
                };
                if (target == .bgra) {
                    // Into itself would read what it wrote: a copy first.
                    const whole = facet.ImageCopy{ .extent = .{ .width = side.width, .height = side.height } };
                    side.fb.CmdCopyImage(side.commands.?, side.pictures[0].?, .general, side.pictures[1].?, .general, 1, @ptrCast(&whole));
                    side.fb.CmdBlitImage(side.commands.?, side.pictures[1].?, .general, side.pictures[0].?, .general, 1, @ptrCast(&blit), filter);
                } else {
                    side.fb.CmdBlitImage(side.commands.?, side.pictures[0].?, .general, side.pictures[@intFromEnum(target)].?, .general, 1, @ptrCast(&blit), filter);
                }
            }
        }.run;
    }
    fn blittedTexture(side: *Side) Failure!void {
        side.begin(.{});
        side.end();
        const blit = facet.ImageBlit{
            .src_subresource = .{ .mip_level = 1 },
            .src_offsets = .{ .{}, .{ .x = 32, .y = 32, .z = 1 } },
            .dst_offsets = .{ .{ .x = 10, .y = 10 }, .{ .x = 300, .y = 200, .z = 1 } },
        };
        side.fb.CmdBlitImage(side.commands.?, side.textures[1].?, .general, side.pictures[0].?, .general, 1, @ptrCast(&blit), .nearest);
    }
    /// A texture written from a picture, then drawn: last of the cases, as it
    /// changes the texture.
    fn intoTexture(side: *Side) Failure!void {
        try Cases.drawnPicture(side);
        const blit = facet.ImageBlit{
            .src_offsets = .{ .{}, .{ .x = @intCast(side.width), .y = @intCast(side.height), .z = 1 } },
            .dst_offsets = .{ .{}, .{ .x = 64, .y = 64, .z = 1 } },
        };
        side.fb.CmdBlitImage(side.commands.?, side.pictures[0].?, .general, side.textures[0].?, .general, 1, @ptrCast(&blit), .linear);
        side.begin(.{});
        side.texture(0);
        try side.use(.{ .vertex = "texture", .fragment = "nearest" });
        side.draw(quad_at, 6);
        side.end();
    }
    fn readBack(side: *Side) Failure!void {
        try Cases.drawnPicture(side);
        side.begin(.{ .target = .rgba, .clear = .{ 0, 0, 0, 1 } });
        side.end();
        const there = facet.BufferImageCopy{ .image_offset = .{ .x = 150, .y = 100 }, .image_extent = .{ .width = 64, .height = 64 } };
        side.fb.CmdCopyImageToBuffer(side.commands.?, side.pictures[0].?, .general, side.staging.?, 1, @ptrCast(&there));
        const back = facet.BufferImageCopy{ .image_offset = .{ .x = 10, .y = 10 }, .image_extent = .{ .width = 64, .height = 64 } };
        side.fb.CmdCopyBufferToImage(side.commands.?, side.staging.?, side.pictures[1].?, .general, 1, @ptrCast(&back));
    }
    fn clearOf(comptime aspect: u32) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                const stenciled = aspect & facet.IMAGE_ASPECT_STENCIL != 0;
                side.begin(.{ .stencil = if (stenciled) .with_depth else .none });
                const kind: Stencil = if (stenciled) .with_depth else .none;
                try side.use(.{ .stencil = kind, .test_depth = true, .write_depth = true });
                side.draw(near_at, 3);
                const attachment = facet.ClearAttachment{ .aspect_mask = aspect, .clear_value = if (aspect & facet.IMAGE_ASPECT_COLOR != 0) .{ .color = .{ .float32 = .{ 0.8, 0.5, 0.2, 1 } } } else .{ .depth_stencil = .{ .depth = 1, .stencil = 4 } } };
                const rects = [2]facet.ClearRect{
                    .{ .rect = .{ .offset = .{ .x = 100, .y = 80 }, .extent = .{ .width = 200, .height = 100 } } },
                    .{ .rect = .{ .offset = .{ .x = 340, .y = 200 }, .extent = .{ .width = 90, .height = 60 } } },
                };
                side.fb.CmdClearAttachments(side.commands.?, 1, @ptrCast(&attachment), rects.len, &rects);
                const four = facet.StencilOpState{ .compare_op = .equal, .compare_mask = 0xFF, .reference = 4 };
                try side.use(.{ .stencil = kind, .test_depth = true, .stencil_test = stenciled, .front = four, .back = four });
                side.draw(quad_at, 6);
                side.end();
            }
        }.run;
    }
    fn indirect(side: *Side) Failure!void {
        const draws = [2]facet.DrawIndirectCommand{
            .{ .vertex_count = 3, .instance_count = 1, .first_vertex = far_at, .first_instance = 0 },
            .{ .vertex_count = 3, .instance_count = 1, .first_vertex = near_at, .first_instance = 0 },
        };
        side.number_bytes[0..@sizeOf(@TypeOf(draws))].* = std.mem.toBytes(draws);
        side.begin(.{});
        try side.use(.{});
        side.fb.CmdDrawIndirect(side.commands.?, side.numbers.?, 0, 2, @sizeOf(facet.DrawIndirectCommand));
        side.end();
    }
    fn indirectIndexed(side: *Side) Failure!void {
        const draw = facet.DrawIndexedIndirectCommand{ .index_count = 6, .instance_count = 2, .first_index = 0, .vertex_offset = 0, .first_instance = 0 };
        side.number_bytes[8..][0..@sizeOf(@TypeOf(draw))].* = std.mem.toBytes(draw);
        side.begin(.{});
        try side.use(.{ .vertex = "color" });
        side.fb.CmdBindIndexBuffer(side.commands.?, side.indices.?, offset_32, .uint32);
        side.fb.CmdDrawIndexedIndirect(side.commands.?, side.numbers.?, 8, 1, 0);
        side.end();
    }
    /// A draw, a secondary's draw and another, all in the primary's pass.
    fn inSecondary(side: *Side) Failure!void {
        const fb = side.fb;
        side.begin(.{});
        try side.use(.{});
        side.draw(far_at, 3);
        const primary = side.commands;
        side.commands = side.secondary;
        try expectOk(fb.BeginCommandBuffer(side.commands.?, &.{ .flags = facet.COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE }));
        side.state();
        try side.use(.{ .blend = true });
        side.draw(glass_at, 3);
        try expectOk(fb.EndCommandBuffer(side.commands.?));
        side.commands = primary;
        fb.CmdExecuteCommands(side.commands.?, 1, @ptrCast(&side.secondary));
        side.state();
        try side.use(.{});
        side.draw(near_at, 3);
        side.end();
    }
    fn expectOk(result: facet.Result) Failure!void {
        return Side.expect(result, error.Refused);
    }
    /// Two passes in a secondary, the primary only playing it.
    fn wholeSecondary(side: *Side) Failure!void {
        const fb = side.fb;
        const primary = side.commands;
        side.commands = side.secondary;
        try expectOk(fb.BeginCommandBuffer(side.commands.?, &.{}));
        side.begin(.{});
        try side.use(.{});
        side.draw(0, 3);
        side.end();
        side.begin(.{ .load = true, .depth = false });
        try side.use(.{ .depth = false, .load = true });
        side.draw(3, 3);
        side.end();
        try expectOk(fb.EndCommandBuffer(side.commands.?));
        side.commands = primary;
        fb.CmdExecuteCommands(side.commands.?, 1, @ptrCast(&side.secondary));
    }
    /// The triangles written by groups of a compute function, then drawn.
    fn computedVertices(side: *Side) Failure!void {
        side.compute(0, .{ 0.05, -0.07 });
        side.fb.CmdDispatch(side.commands.?, 3, 1, 1);
        side.begin(.{});
        try side.use(.{ .blend = true });
        side.drawComputed();
        side.draw(0, 9);
        side.end();
    }
    /// A draw's numbers written by a compute function, how many groups read
    /// from a buffer too: what is bound to draw stays apart from it.
    fn computedNumbers(side: *Side) Failure!void {
        const dispatch = facet.DispatchIndirectCommand{ .x = 3, .y = 1, .z = 1 };
        side.number_bytes[200..][0..@sizeOf(@TypeOf(dispatch))].* = std.mem.toBytes(dispatch);
        side.compute(1, .{ 0, 0 });
        side.fb.CmdDispatchIndirect(side.commands.?, side.numbers.?, 200);
        side.begin(.{});
        try side.use(.{ .blend = true });
        side.fb.CmdDrawIndirect(side.commands.?, side.numbers.?, 0, 3, @sizeOf(facet.DrawIndirectCommand));
        side.end();
    }
    fn tessellated(comptime options: Options, comptime first: u32, comptime count: u32) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                side.begin(.{});
                try side.use(options);
                side.draw(first, count);
                side.end();
            }
        }.run;
    }
    fn drawnAs(comptime options: Options, comptime first: u32, comptime count: u32) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                side.begin(.{});
                try side.use(options);
                side.draw(first, count);
                side.end();
            }
        }.run;
    }
    fn mixedDynamic(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(far_at, 3);
        try side.use(.{ .dynamic_constants = true, .mixing = .{ .blend_enable = true, .src_color_blend_factor = .constant_color, .dst_color_blend_factor = .one_minus_constant_alpha } });
        side.fb.CmdSetBlendConstants(side.commands.?, &.{ 0.25, 0.75, 0.5, 0.5 });
        side.draw(glass_at, 3);
        side.fb.CmdSetBlendConstants(side.commands.?, &.{ 0.75, 0.25, 0.125, 0.25 });
        side.draw(near_at, 3);
        side.end();
    }
    /// What is there given an alpha of its own, then mixed by it.
    fn mixedByTheirAlpha(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .mixing = .{ .blend_enable = true, .src_color_blend_factor = .one, .dst_color_blend_factor = .zero, .src_alpha_blend_factor = .src_alpha, .dst_alpha_blend_factor = .zero } });
        side.draw(glass_at, 3);
        try side.use(.{ .mixing = .{ .blend_enable = true, .src_color_blend_factor = .dst_alpha, .dst_color_blend_factor = .one_minus_dst_alpha, .src_alpha_blend_factor = .one, .dst_alpha_blend_factor = .one } });
        side.draw(far_at, 3);
        side.end();
    }
    fn onTargetMixed(comptime target: Target) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                side.begin(.{ .target = target });
                try side.use(.{ .target = target });
                side.draw(far_at, 3);
                try side.use(.{ .target = target, .mixing = .{ .blend_enable = true, .src_color_blend_factor = .one_minus_dst_alpha, .dst_color_blend_factor = .dst_alpha } });
                side.draw(glass_at, 3);
                side.end();
            }
        }.run;
    }
    fn scissor(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        const part = facet.Rect2D{
            .offset = .{ .x = @intCast(side.width / 5), .y = @intCast(side.height / 4) },
            .extent = .{ .width = side.width / 2, .height = side.height / 3 },
        };
        side.fb.CmdSetScissor(side.commands.?, 0, 1, @ptrCast(&part));
        side.draw(clockwise_at, 6);
        side.end();
    }
    fn viewport(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        const w: f32 = @floatFromInt(side.width);
        const h: f32 = @floatFromInt(side.height);
        side.setViewport(w * 0.3, h * 0.2, w * 0.6, h * 0.7, 0, 1);
        side.draw(clockwise_at, 6);
        side.setViewport(-w * 0.2, -h * 0.25, w * 0.6, h * 0.7, 0, 1);
        side.draw(strip_at, 3);
        side.end();
    }
    fn depthRange(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .test_depth = true, .write_depth = true });
        const w: f32 = @floatFromInt(side.width);
        const h: f32 = @floatFromInt(side.height);
        side.setViewport(0, 0, w, h, 0.5, 1);
        side.draw(near_at, 3);
        side.setViewport(0, 0, w, h, 0, 0.5);
        side.draw(far_at, 3);
        side.end();
    }
    fn behind(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(behind_at, 3);
        side.end();
    }
    fn areaClear(side: *Side) Failure!void {
        side.begin(.{ .clear = .{ 0.5, 0.2, 0.1, 1 } });
        side.end();
        side.begin(.{ .area = .{ 0.125, 0.125, 0.875, 0.875 } });
        side.end();
    }
    fn areaClearDraw(side: *Side) Failure!void {
        side.begin(.{ .clear = .{ 0.5, 0.2, 0.1, 1 } });
        side.end();
        side.begin(.{ .area = .{ 0.125, 0.125, 0.875, 0.875 } });
        try side.use(.{ .test_depth = true, .write_depth = true });
        side.draw(far_at, 3);
        side.draw(near_at, 3);
        side.end();
    }
    fn areaKeep(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(far_at, 3);
        side.end();
        side.begin(.{ .load = true, .area = .{ 0.25, 0.25, 0.75, 0.75 } });
        try side.use(.{ .load = true, .test_depth = true, .write_depth = true });
        side.draw(near_at, 3);
        side.end();
    }
    fn wholeKeep(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(far_at, 3);
        side.end();
        side.begin(.{ .load = true });
        try side.use(.{ .load = true, .test_depth = true, .write_depth = true });
        side.draw(near_at, 3);
        side.end();
    }
    fn areaTexture(side: *Side) Failure!void {
        side.begin(.{ .clear = .{ 0.5, 0.2, 0.1, 1 } });
        side.end();
        side.begin(.{ .area = .{ 0.125, 0.125, 0.875, 0.875 } });
        side.texture(0);
        try side.use(.{ .vertex = "texture", .fragment = "nearest", .test_depth = true, .write_depth = true });
        side.draw(quad_at, 6);
        try side.use(.{ .test_depth = true, .write_depth = true });
        side.draw(far_at, 3);
        side.end();
    }
    fn areaTextureOnly(side: *Side) Failure!void {
        side.begin(.{ .clear = .{ 0.5, 0.2, 0.1, 1 } });
        side.end();
        side.begin(.{ .area = .{ 0.125, 0.125, 0.875, 0.875 } });
        side.texture(0);
        try side.use(.{ .vertex = "texture", .fragment = "nearest" });
        side.draw(quad_at, 6);
        side.end();
    }
    fn keptTexture(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(far_at, 3);
        side.end();
        side.begin(.{ .load = true });
        side.texture(0);
        try side.use(.{ .load = true, .vertex = "texture", .fragment = "nearest" });
        side.draw(quad_at, 6);
        side.end();
    }
    fn partKeptTexture(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{});
        side.draw(far_at, 3);
        side.end();
        side.begin(.{ .load = true, .area = .{ 0.25, 0.25, 0.75, 0.75 } });
        side.texture(0);
        try side.use(.{ .load = true, .vertex = "texture", .fragment = "nearest" });
        side.draw(quad_at, 6);
        side.end();
    }
    fn areaColorOnly(side: *Side) Failure!void {
        side.begin(.{ .clear = .{ 0.5, 0.2, 0.1, 1 } });
        side.end();
        side.begin(.{ .area = .{ 0.125, 0.125, 0.875, 0.875 } });
        try side.use(.{});
        side.draw(far_at, 3);
        side.end();
    }
    fn areaColorDepth(side: *Side) Failure!void {
        side.begin(.{ .clear = .{ 0.5, 0.2, 0.1, 1 } });
        side.end();
        side.begin(.{ .area = .{ 0.125, 0.125, 0.875, 0.875 } });
        try side.use(.{ .test_depth = true, .write_depth = true });
        side.draw(far_at, 3);
        side.end();
    }
    fn underTexture(comptime load: bool, comptime part: bool, comptime tested: bool) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                side.begin(.{});
                side.end();
                side.begin(.{ .load = load, .area = if (part) .{ 0.125, 0.125, 0.875, 0.875 } else null });
                side.texture(0);
                try side.use(.{ .load = load, .test_depth = tested, .write_depth = tested });
                side.draw(far_at, 3);
                try side.use(.{ .load = load, .vertex = "texture", .fragment = "nearest", .test_depth = tested, .write_depth = tested });
                side.draw(quad_at, 6);
                side.end();
            }
        }.run;
    }
    fn textured(comptime fragment: [*:0]const u8, comptime format: usize, comptime first: u32) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                side.begin(.{});
                side.texture(format);
                try side.use(.{ .vertex = "texture", .fragment = fragment });
                side.draw(first, 6);
                side.end();
            }
        }.run;
    }
    fn layer(comptime which: Layered, comptime vertex: [*:0]const u8, comptime fragment: [*:0]const u8, comptime instance: u32) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                side.begin(.{});
                side.layeredTexture(which);
                try side.use(.{ .vertex = vertex, .fragment = fragment });
                side.fb.CmdDraw(side.commands.?, 6, 1, quad_at, instance);
                side.end();
            }
        }.run;
    }
    fn layerAs2d(comptime which: Layered, comptime blended: bool) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                side.begin(.{});
                side.layeredTexture(which);
                try side.use(.{ .vertex = "texture", .fragment = "nearest", .blend = blended });
                side.draw(quad_at, 6);
                side.end();
            }
        }.run;
    }
    /// A layer and level of the array over the second of another's, by a copy.
    fn copiedLayer(side: *Side) Failure!void {
        const copy = facet.ImageCopy{ .src_subresource = .{ .base_array_layer = 3 }, .dst_subresource = .{ .base_array_layer = 1 }, .extent = .{ .width = layer_side, .height = layer_side } };
        side.fb.CmdCopyImage(side.commands.?, side.layeredImage(.array).*.?, .general, side.layeredImage(.copied).*.?, .general, 1, @ptrCast(&copy));
        try layerAs2d(.copied, false)(side);
    }
    /// The picture blitted into a layer of an array, then read from it.
    fn blittedLayer(side: *Side) Failure!void {
        try Cases.drawnPicture(side);
        const blit = facet.ImageBlit{
            .src_offsets = .{ .{}, .{ .x = @intCast(side.width), .y = @intCast(side.height), .z = 1 } },
            .dst_subresource = .{ .base_array_layer = 1 },
            .dst_offsets = .{ .{}, .{ .x = layer_side, .y = layer_side, .z = 1 } },
        };
        side.fb.CmdBlitImage(side.commands.?, side.pictures[0].?, .general, side.layeredImage(.copied).*.?, .general, 1, @ptrCast(&blit), .linear);
        try layerAs2d(.copied, false)(side);
    }
    /// Far and near, tested over two subpasses that keep the depth; then the
    /// second picture alone; then the two of them.
    fn subpasses(side: *Side) Failure!void {
        const pass = side.subpassed.?;
        side.beginOwn(pass, side.subpassed_frame.?);
        try side.use(.{ .pass = pass, .test_depth = true, .write_depth = true, .depth = true });
        side.draw(near_at, 3);
        side.fb.CmdNextSubpass(side.commands.?, .@"inline");
        try side.use(.{ .pass = pass, .subpass = 1, .test_depth = true, .write_depth = true, .depth = true });
        side.draw(far_at, 3);
        side.fb.CmdNextSubpass(side.commands.?, .@"inline");
        try side.use(.{ .pass = pass, .subpass = 2, .depth = false, .target = .rgba });
        side.draw(clockwise_at, 3);
        side.fb.CmdNextSubpass(side.commands.?, .@"inline");
        try side.use(.{ .pass = pass, .subpass = 3, .colors = 2, .depth = false, .blend = true });
        side.draw(glass_at, 3);
        side.end();
    }
    /// One subpass of both pictures: the second of each drawn over again, what
    /// was bound put back. The pipeline bound before the pass stays the one
    /// the second time begins with.
    fn twoColors(side: *Side) Failure!void {
        const pass = side.two_colors.?;
        try side.use(.{ .pass = pass, .colors = 2, .test_depth = true, .write_depth = true });
        side.beginOwn(pass, side.two_colors_frame.?);
        side.draw(near_at, 3);
        side.draw(far_at, 3);
        try side.use(.{ .pass = pass, .colors = 2, .blend = true });
        side.draw(glass_at, 3);
        side.end();
    }
    fn modulate(side: *Side) Failure!void {
        side.begin(.{});
        side.texture(0);
        try side.use(.{ .vertex = "modulate", .fragment = "modulate" });
        side.draw(quad_at, 6);
        side.end();
    }
    /// A fragment shader the module ships the words of, drawn with the
    /// vertex function `vertex` over the geometry at `first`; through the
    /// combined image sampler where it samples.
    fn shipped(comptime vertex: [*:0]const u8, comptime fragment: [*:0]const u8, comptime samples: bool, comptime first: u32) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                side.begin(.{});
                if (samples) side.sampled();
                try side.use(.{ .vertex = vertex, .fragment = fragment, .layout = if (samples) side.sampler_layout.? else null });
                side.draw(first, 6);
                side.end();
            }
        }.run;
    }
    /// A shadow map drawn and then compared with, over the whole picture,
    /// through `fragment` - the fixed form `texture_shadow`, or a
    /// generated shader that compares (since 1.15) - and the sampler of
    /// `shadow_ops[which]`:
    /// red where the comparison passed and black where it did not, since a
    /// view of a depth reads (D, 0, 0, 1). The map is the far and the near
    /// triangle at 0.75 and 0.25 in the clear's 1, or, `tilted`, a fan
    /// whose depth slopes past the reference; `vertex` sets the reference.
    /// The pass leaves the map for the shader to read, and the barrier
    /// says the sample comes after the depth was written, as Vulkan asks.
    fn shadowed(comptime tilted: bool, comptime which: usize, comptime vertex: [*:0]const u8, comptime fragment: [*:0]const u8) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                try shadowMap(side, tilted, .with_color);
                try lookAtShadow(side, which, vertex, fragment);
            }
        }.run;
    }
    /// How a shadow map is drawn: in its pass with the first picture, as
    /// it was until 1.18; or in a pass of it alone, by the fixed form of
    /// colour, by a shipped shader that the V3D compiles for a subpass of
    /// no colour, or by no fragment stage at all (since 1.18).
    const Drawn = enum { with_color, fixed, shipped, stageless };
    /// The shadow map less than a half, drawn as `drawn` says.
    fn shadowedAlone(comptime tilted: bool, comptime drawn: Drawn) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                try shadowMap(side, tilted, drawn);
                try lookAtShadow(side, 0, "whole at a half", "shadow");
            }
        }.run;
    }
    fn shadowMap(side: *Side, tilted: bool, drawn: Drawn) Failure!void {
        const fb = side.fb;
        const commands = side.commands.?;
        const clears = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } }, .{ .depth_stencil = .{ .depth = 1 } } };
        const alone = drawn != .with_color;
        fb.CmdBeginRenderPass(commands, &.{
            .render_pass = if (alone) side.shadow_alone.? else side.shadow_pass.?,
            .framebuffer = if (alone) side.shadow_alone_frame.? else side.shadow_frame.?,
            .render_area = .{ .extent = .{ .width = side.width, .height = side.height } },
            .clear_value_count = if (alone) 1 else 2,
            .clear_values = if (alone) clears[1..] else &clears,
        }, .@"inline");
        side.state();
        var options = Options{ .test_depth = true, .write_depth = true, .pass = if (alone) side.shadow_alone.? else side.shadow_pass.?, .colors = if (alone) 0 else 1 };
        switch (drawn) {
            .with_color, .fixed => {},
            .shipped => {
                options.vertex = "as it is";
                options.fragment = "shipped smooth";
            },
            .stageless => options.no_fragment = true,
        }
        if (tilted) {
            options.vertex = "tilted";
            options.topology = .triangle_fan;
            try side.use(options);
            side.draw(fan_at, 5);
        } else {
            try side.use(options);
            side.draw(far_at, 3);
            side.draw(near_at, 3);
        }
        side.end();
        const written = facet.ImageMemoryBarrier{
            .src_access_mask = facet.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE,
            .dst_access_mask = facet.ACCESS_SHADER_READ,
            .old_layout = .shader_read_only_optimal,
            .new_layout = .shader_read_only_optimal,
            .image = side.shadow.?,
            .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH },
        };
        fb.CmdPipelineBarrier(commands, facet.PIPELINE_STAGE_LATE_FRAGMENT_TESTS, facet.PIPELINE_STAGE_FRAGMENT_SHADER, 0, 0, null, 0, null, 1, @ptrCast(&written));
    }
    /// The shadow map drawn whole in a pass of it alone, then cleared and
    /// the far triangle drawn over a part of it in another, which stores
    /// it: the map outside the part is what the first pass left, where a
    /// tile the second renders across the part's edge has to write it back
    /// as it was. The near triangle's 0.25 below the part is in such tiles
    /// on the V3D, and every depth is clear of the half it is compared
    /// with (since 1.19).
    fn shadowedOverPart(side: *Side) Failure!void {
        const fb = side.fb;
        const commands = side.commands.?;
        try shadowMap(side, false, .fixed);
        const far_away = facet.ClearValue{ .depth_stencil = .{ .depth = 1 } };
        fb.CmdBeginRenderPass(commands, &.{ .render_pass = side.shadow_again.?, .framebuffer = side.shadow_alone_frame.?, .render_area = side.areaOf(.{ 0.1, 0.15, 0.6, 0.6 }), .clear_value_count = 1, .clear_values = @ptrCast(&far_away) }, .@"inline");
        side.state();
        try side.use(.{ .test_depth = true, .write_depth = true, .pass = side.shadow_again.?, .colors = 0 });
        side.draw(far_at, 3);
        side.end();
        const written = facet.ImageMemoryBarrier{
            .src_access_mask = facet.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE,
            .dst_access_mask = facet.ACCESS_SHADER_READ,
            .old_layout = .shader_read_only_optimal,
            .new_layout = .shader_read_only_optimal,
            .image = side.shadow.?,
            .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH },
        };
        fb.CmdPipelineBarrier(commands, facet.PIPELINE_STAGE_LATE_FRAGMENT_TESTS, facet.PIPELINE_STAGE_FRAGMENT_SHADER, 0, 0, null, 0, null, 1, @ptrCast(&written));
        try lookAtShadow(side, 0, "whole at a half", "shadow");
    }
    /// The quad over the first picture, the shadow map compared with as
    /// `shadow_ops[which]` says.
    fn lookAtShadow(side: *Side, which: usize, vertex: [*:0]const u8, fragment: [*:0]const u8) Failure!void {
        side.begin(.{});
        side.fb.CmdBindDescriptorSets(side.commands.?, .graphics, side.sampler_layout.?, 0, 1, @ptrCast(&side.shadow_sets[which]), 0, null);
        try side.use(.{ .vertex = vertex, .fragment = fragment, .layout = side.sampler_layout.? });
        side.draw(quad_at, 6);
        side.end();
    }
    /// The far and the near triangle's depths drawn in a subpass of no
    /// colour - none, or one ATTACHMENT_UNUSED - by the fixed form of
    /// colour or by no fragment stage, cleared back to 1 over two
    /// rectangles where `cleared`; then the near and the far drawn in
    /// colour in the next subpass, tested less or equal against what the
    /// first left and writing none. Where the first kept its depth the far
    /// is hidden behind the near, and where the clear reached it is not
    /// (since 1.18).
    fn prepassed(comptime unused: bool, comptime stageless: bool, comptime cleared: bool) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                const pass = if (unused) side.unused_first.? else side.prepassed.?;
                const commands = side.commands.?;
                const clears = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0.06, 0.09, 0.2, 1 } } }, .{ .depth_stencil = .{ .depth = 1 } } };
                side.fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass, .framebuffer = side.prepassed_frame.?, .render_area = .{ .extent = .{ .width = side.width, .height = side.height } }, .clear_value_count = 2, .clear_values = &clears }, .@"inline");
                side.state();
                try side.use(.{ .pass = pass, .test_depth = true, .write_depth = true, .no_fragment = stageless, .colors = if (unused) 1 else 0 });
                side.draw(far_at, 3);
                side.draw(near_at, 3);
                if (cleared) {
                    const attachment = facet.ClearAttachment{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH, .clear_value = .{ .depth_stencil = .{ .depth = 1 } } };
                    const rects = [2]facet.ClearRect{
                        .{ .rect = .{ .offset = .{ .x = side.partOf(side.width, 0.3), .y = side.partOf(side.height, 0.3) }, .extent = .{ .width = @intCast(side.partOf(side.width, 0.25)), .height = @intCast(side.partOf(side.height, 0.25)) } } },
                        .{ .rect = .{ .offset = .{ .x = side.partOf(side.width, 0.05), .y = side.partOf(side.height, 0.05) }, .extent = .{ .width = @intCast(side.partOf(side.width, 0.2)), .height = @intCast(side.partOf(side.height, 0.3)) } } },
                    };
                    side.fb.CmdClearAttachments(commands, 1, @ptrCast(&attachment), rects.len, &rects);
                }
                side.fb.CmdNextSubpass(commands, .@"inline");
                try side.use(.{ .pass = pass, .subpass = 1, .test_depth = true, .compare = .less_or_equal });
                side.draw(near_at, 3);
                side.draw(far_at, 3);
                side.end();
            }
        }.run;
    }
    /// The near triangle, then the far one's depth alone by a pipeline of
    /// no fragment stage in a pass of colour, then the glass over both
    /// tested against them: the far leaves its colour as it was, which
    /// the cores keep by writing none and the V3D by a program that writes
    /// none (since 1.18).
    fn stagelessInColor(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .test_depth = true, .write_depth = true });
        side.draw(near_at, 3);
        try side.use(.{ .test_depth = true, .write_depth = true, .no_fragment = true });
        side.draw(far_at, 3);
        try side.use(.{ .test_depth = true, .blend = true });
        side.draw(glass_at, 3);
        side.end();
    }
    /// The picture cleared, then the far, the near and the glass drawn in
    /// a pass of no attachment at `samples` a pixel, counted by an
    /// occlusion query: every sample of them, there being no depth to
    /// fail. The pass draws at its pipeline's count, the V3D's frame
    /// started again at four where it has four (since 1.18).
    fn counted(comptime samples: u32) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                const fb = side.fb;
                const commands = side.commands.?;
                side.begin(.{ .depth = false });
                side.end();
                fb.CmdResetQueryPool(commands, side.queries.?, 0, 1);
                fb.CmdBeginRenderPass(commands, &.{ .render_pass = side.empty.?, .framebuffer = side.empty_frame.?, .render_area = .{ .extent = .{ .width = side.width, .height = side.height } } }, .@"inline");
                side.state();
                fb.CmdBeginQuery(commands, side.queries.?, 0, facet.QUERY_CONTROL_PRECISE);
                try side.use(.{ .pass = side.empty.?, .samples = samples, .colors = 0 });
                side.draw(far_at, 3);
                side.draw(near_at, 3);
                side.draw(glass_at, 3);
                fb.CmdEndQuery(commands, side.queries.?, 0);
                side.end();
            }
        }.run;
    }
    /// A texture through `throughs[k]`.
    fn through(comptime k: usize) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                const each = throughs[k];
                side.begin(.{});
                side.fb.CmdBindDescriptorSets(side.commands.?, .graphics, side.sampler_layout.?, 0, 1, @ptrCast(&side.through_sets[k]), 0, null);
                try side.use(.{ .vertex = each.vertex, .fragment = each.fragment, .layout = side.sampler_layout.? });
                side.fb.CmdDraw(side.commands.?, 6, 1, each.first, each.instance);
                side.end();
            }
        }.run;
    }
    /// A colour pushed, drawn; then its green alone pushed again, by
    /// four bytes at offset 4, and drawn over another part of the
    /// picture. Each draw reads what was pushed before it, and the bytes
    /// not pushed again keep what they were.
    fn pushed(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .vertex = "place", .fragment = "shipped pushed", .layout = side.push_layout.? });
        const first = [4]f32{ 0.25, 0.5, 0.75, 1 };
        side.fb.CmdPushConstants(side.commands.?, side.push_layout.?, facet.SHADER_STAGE_FRAGMENT, 0, 16, &first);
        side.draw(clockwise_at, 6);
        const green_only: f32 = 0.125;
        side.fb.CmdPushConstants(side.commands.?, side.push_layout.?, facet.SHADER_STAGE_FRAGMENT, 4, 4, &green_only);
        side.draw(glass_at, 3);
        side.end();
    }
    /// The vertices' colour times a pushed float, plus a pushed colour.
    fn tinted(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .vertex = "as it is", .fragment = "shipped tinted", .layout = side.push_layout.? });
        const values = [5]f32{ 0.125, 0, 0.25, 0, 0.5 };
        side.fb.CmdPushConstants(side.commands.?, side.push_layout.?, facet.SHADER_STAGE_FRAGMENT, 0, 20, &values);
        side.draw(clockwise_at, 6);
        side.end();
    }
    /// The texture with half its checks dropped, in front of the far
    /// triangle and drawn first: the triangle shows where a pixel was
    /// dropped, and only there. A dropped pixel that wrote its depth
    /// all the same would hide it.
    fn cutoutInFront(side: *Side) Failure!void {
        side.begin(.{});
        side.sampled();
        try side.use(.{ .vertex = "texture", .fragment = "shipped cutout", .layout = side.sampler_layout.?, .test_depth = true, .write_depth = true });
        side.draw(quad_at, 6);
        try side.use(.{ .test_depth = true, .write_depth = true });
        side.draw(far_at, 3);
        side.end();
    }
    fn missing(side: *Side) Failure!void {
        side.begin(.{});
        try side.use(.{ .vertex = "texture", .fragment = "nearest" });
        side.draw(quad_at, 6);
        side.end();
    }
    /// The far and the near triangle, the depth tested, and glass blended
    /// over them, at four samples a pixel and with the pipelines' sample
    /// `mask` - all four where null - over `area` of the picture, all of it
    /// where null: resolved into the first picture as the pass ends, which
    /// keeps outside the area the clear of a pass before it (since 1.16).
    fn resolved(comptime area: ?[4]f32, comptime mask: ?u32) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                side.begin(.{ .depth = false });
                side.end();
                side.beginFour(true, area);
                try side.use(.{ .pass = side.resolving.?, .samples = 4, .sample_mask = mask, .test_depth = true, .write_depth = true });
                side.draw(far_at, 3);
                side.draw(near_at, 3);
                try side.use(.{ .pass = side.resolving.?, .samples = 4, .sample_mask = mask, .blend = true });
                side.draw(glass_at, 3);
                side.end();
            }
        }.run;
    }
    /// The far triangle, opaque, and the glass in front of it, its alpha
    /// 0.4, at four samples with alpha to coverage and no blending, through
    /// the shipped shader that hands the colour on, which the V3D compiles
    /// with its FTOC (since 1.17): resolved, a pixel of the glass is the
    /// average of the samples its alpha covered. Vulkan leaves which those
    /// are to the implementation - the cores dither them - so two pixels
    /// one sample apart are the same here, a sample being at most 51 steps
    /// of a channel of the glass over the blue.
    fn covered(side: *Side) Failure!void {
        side.begin(.{ .depth = false });
        side.end();
        side.beginFour(true, null);
        try side.use(.{ .vertex = "as it is", .fragment = "shipped smooth", .pass = side.resolving.?, .samples = 4, .test_depth = true, .write_depth = true, .alpha_to_coverage = true });
        side.draw(far_at, 3);
        side.draw(glass_at, 3);
        side.end();
    }
    /// The same over all of the picture in a pass that keeps its four
    /// samples, resolved into the first picture by CmdResolveImage after a
    /// barrier that says the colour was written (since 1.16).
    fn resolvedAfter(side: *Side) Failure!void {
        const fb = side.fb;
        side.beginFour(false, null);
        try side.use(.{ .pass = side.four_alone.?, .samples = 4, .test_depth = true, .write_depth = true });
        side.draw(far_at, 3);
        side.draw(near_at, 3);
        try side.use(.{ .pass = side.four_alone.?, .samples = 4, .blend = true });
        side.draw(glass_at, 3);
        side.end();
        const written = facet.ImageMemoryBarrier{
            .src_access_mask = facet.ACCESS_COLOR_ATTACHMENT_WRITE,
            .dst_access_mask = facet.ACCESS_TRANSFER_READ,
            .old_layout = .transfer_src_optimal,
            .new_layout = .transfer_src_optimal,
            .image = side.four.?,
            .subresource_range = .{ .aspect_mask = facet.IMAGE_ASPECT_COLOR },
        };
        fb.CmdPipelineBarrier(side.commands.?, facet.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT, facet.PIPELINE_STAGE_TRANSFER, 0, 0, null, 0, null, 1, @ptrCast(&written));
        const region = facet.ImageResolve{ .extent = .{ .width = side.width, .height = side.height, .depth = 1 } };
        fb.CmdResolveImage(side.commands.?, side.four.?, .transfer_src_optimal, side.pictures[0].?, .general, 1, @ptrCast(&region));
    }
    fn onTarget(comptime target: Target) *const fn (side: *Side) Failure!void {
        return &struct {
            fn run(side: *Side) Failure!void {
                side.begin(.{ .target = target });
                try side.use(.{ .target = target });
                side.draw(clockwise_at, 6);
                try side.use(.{ .target = target, .blend = true });
                side.draw(glass_at, 3);
                side.end();
            }
        }.run;
    }
};

const marks = facet.StencilOpState{ .pass_op = .replace, .compare_op = .always, .write_mask = 0xFF, .reference = 1 };
const counts = facet.StencilOpState{ .pass_op = .increment_and_clamp, .compare_op = .always, .write_mask = 0xFF };
const equal_1 = facet.StencilOpState{ .compare_op = .equal, .compare_mask = 0xFF, .reference = 1 };

const cases = [_]Case{
    .{ .name = "clear", .run = &Cases.clear },
    .{ .name = "triangles", .run = &Cases.triangles },
    .{ .name = "strip", .run = &Cases.strip },
    .{ .name = "fan", .run = &Cases.fan },
    .{ .name = "restart", .run = &Cases.restart },
    .{ .name = "indices of 16 bits", .run = &Cases.indexed16 },
    .{ .name = "indices of 32 bits", .run = &Cases.indexed32 },
    .{ .name = "instances", .run = &Cases.instances },
    .{ .name = "cull back", .run = &Cases.cullBack },
    .{ .name = "cull front", .run = &Cases.cullFront },
    .{ .name = "cull back, front the other way", .run = &Cases.cullBackCounter },
    .{ .name = "depth, far first", .run = &Cases.depthLess },
    .{ .name = "depth, near first", .run = &Cases.depthNearFirst },
    .{ .name = "depth, greater", .run = &Cases.depthGreater },
    .{ .name = "depth, not written", .run = &Cases.depthNoWrite },
    .{ .name = "no depth attachment", .run = &Cases.noDepthAttachment },
    .{ .name = "blend", .run = &Cases.blend },
    .{ .name = "blend, added", .run = &Cases.blendAdded },
    .{ .name = "blend, multiplied", .run = Cases.mixed(.{ .blend_enable = true, .src_color_blend_factor = .dst_color, .dst_color_blend_factor = .zero }, .{ 0, 0, 0, 0 }) },
    .{ .name = "blend, one and one", .run = Cases.mixed(.{ .blend_enable = true, .src_color_blend_factor = .one, .dst_color_blend_factor = .one, .src_alpha_blend_factor = .one, .dst_alpha_blend_factor = .one }, .{ 0, 0, 0, 0 }) },
    .{ .name = "blend, the alpha kept", .run = Cases.mixed(.{ .blend_enable = true, .src_color_blend_factor = .src_alpha, .dst_color_blend_factor = .one_minus_src_alpha, .src_alpha_blend_factor = .zero, .dst_alpha_blend_factor = .one }, .{ 0, 0, 0, 0 }) },
    .{ .name = "blend, the alpha replaced", .run = Cases.mixed(.{ .blend_enable = true, .src_color_blend_factor = .src_alpha, .dst_color_blend_factor = .one_minus_src_alpha, .src_alpha_blend_factor = .one, .dst_alpha_blend_factor = .zero }, .{ 0, 0, 0, 0 }) },
    .{ .name = "blend, added, the alpha kept", .run = Cases.mixed(.{ .blend_enable = true, .src_color_blend_factor = .src_alpha, .dst_color_blend_factor = .one, .src_alpha_blend_factor = .zero, .dst_alpha_blend_factor = .one }, .{ 0, 0, 0, 0 }) },
    .{ .name = "blend, subtracted", .run = Cases.mixed(.{ .blend_enable = true, .src_color_blend_factor = .one, .dst_color_blend_factor = .one, .color_blend_op = .subtract, .src_alpha_blend_factor = .zero, .dst_alpha_blend_factor = .one }, .{ 0, 0, 0, 0 }) },
    .{ .name = "blend, subtracted the other way", .run = Cases.mixed(.{ .blend_enable = true, .src_color_blend_factor = .one, .dst_color_blend_factor = .one, .color_blend_op = .reverse_subtract, .src_alpha_blend_factor = .zero, .dst_alpha_blend_factor = .one }, .{ 0, 0, 0, 0 }) },
    .{ .name = "blend, the least", .run = Cases.mixed(.{ .blend_enable = true, .color_blend_op = .min, .alpha_blend_op = .min }, .{ 0, 0, 0, 0 }) },
    .{ .name = "blend, the most", .run = Cases.mixed(.{ .blend_enable = true, .color_blend_op = .max, .alpha_blend_op = .max }, .{ 0, 0, 0, 0 }) },
    .{ .name = "blend, by their colour", .run = Cases.mixed(.{ .blend_enable = true, .src_color_blend_factor = .one_minus_dst_color, .dst_color_blend_factor = .src_color }, .{ 0, 0, 0, 0 }) },
    .{ .name = "blend, by a constant", .run = Cases.mixed(.{ .blend_enable = true, .src_color_blend_factor = .constant_color, .dst_color_blend_factor = .one_minus_constant_color, .src_alpha_blend_factor = .constant_alpha, .dst_alpha_blend_factor = .one_minus_constant_alpha }, .{ 0.25, 0.5, 0.75, 0.5 }) },
    .{ .name = "blend, saturated", .run = Cases.mixed(.{ .blend_enable = true, .src_color_blend_factor = .src_alpha_saturate, .dst_color_blend_factor = .one }, .{ 0, 0, 0, 0 }) },
    .{ .name = "blend, constants set by a command", .run = &Cases.mixedDynamic },
    .{ .name = "blend, by their alpha", .run = &Cases.mixedByTheirAlpha },
    .{ .name = "written: red alone", .run = Cases.mixed(.{ .color_write_mask = facet.COLOR_COMPONENT_R }, .{ 0, 0, 0, 0 }) },
    .{ .name = "written: green and alpha", .run = Cases.mixed(.{ .color_write_mask = facet.COLOR_COMPONENT_G | facet.COLOR_COMPONENT_A }, .{ 0, 0, 0, 0 }) },
    .{ .name = "written: nothing", .run = Cases.mixed(.{ .color_write_mask = 0 }, .{ 0, 0, 0, 0 }) },
    .{ .name = "written: blue, blended", .run = Cases.mixed(.{ .blend_enable = true, .src_color_blend_factor = .src_alpha, .dst_color_blend_factor = .one_minus_src_alpha, .color_write_mask = facet.COLOR_COMPONENT_B }, .{ 0, 0, 0, 0 }) },
    .{ .name = "lines", .run = Cases.drawnAs(.{ .topology = .line_list }, clockwise_at, 6) },
    .{ .name = "line strip", .run = Cases.drawnAs(.{ .topology = .line_strip }, strip_at, 5) },
    .{ .name = "lines, wide", .run = Cases.drawnAs(.{ .topology = .line_list, .line_width = 5 }, clockwise_at, 6) },
    .{ .name = "points", .run = Cases.drawnAs(.{ .topology = .point_list }, clockwise_at, 22) },
    .{ .name = "triangles as edges", .run = Cases.drawnAs(.{ .polygon_mode = .line }, clockwise_at, 6) },
    .{ .name = "triangles as corners", .run = Cases.drawnAs(.{ .polygon_mode = .point }, clockwise_at, 6) },
    .{ .name = "triangles as edges, culled", .run = Cases.drawnAs(.{ .polygon_mode = .line, .cull = facet.CULL_MODE_BACK, .winding = .clockwise }, clockwise_at, 6) },
    .{ .name = "a line behind the eye", .run = Cases.drawnAs(.{ .topology = .line_strip }, behind_at, 3) },
    .{ .name = "stencil: where marked", .run = Cases.stencilSteps(.with_depth, 0, &.{.{ .first = far_at, .count = 3, .front = marks }}, equal_1) },
    .{ .name = "stencil: where not marked", .run = Cases.stencilSteps(.with_depth, 0, &.{.{ .first = far_at, .count = 3, .front = marks }}, .{ .compare_op = .not_equal, .compare_mask = 0xFF, .reference = 1 }) },
    .{ .name = "stencil: its attachment alone", .run = Cases.stencilSteps(.alone, 0, &.{.{ .first = far_at, .count = 3, .front = marks }}, equal_1) },
    .{ .name = "stencil: cleared to something", .run = Cases.stencilSteps(.with_depth, 3, &.{.{ .first = far_at, .count = 3, .front = .{ .pass_op = .decrement_and_clamp, .compare_op = .always, .write_mask = 0xFF } }}, .{ .compare_op = .equal, .compare_mask = 0xFF, .reference = 3 }) },
    .{ .name = "stencil: counted", .run = Cases.stencilSteps(.with_depth, 0, &.{ .{ .first = far_at, .count = 3, .front = counts }, .{ .first = near_at, .count = 3, .front = counts }, .{ .first = glass_at, .count = 3, .front = counts } }, .{ .compare_op = .equal, .compare_mask = 0xFF, .reference = 2 }) },
    .{ .name = "stencil: wrapped", .run = Cases.stencilSteps(.with_depth, 255, &.{.{ .first = far_at, .count = 3, .front = .{ .pass_op = .increment_and_wrap, .compare_op = .always, .write_mask = 0xFF } }}, .{ .compare_op = .equal, .compare_mask = 0xFF, .reference = 0 }) },
    .{ .name = "stencil: stopped at the top", .run = Cases.stencilSteps(.with_depth, 255, &.{.{ .first = far_at, .count = 3, .front = .{ .pass_op = .increment_and_clamp, .compare_op = .always, .write_mask = 0xFF } }}, .{ .compare_op = .equal, .compare_mask = 0xFF, .reference = 255 }) },
    .{ .name = "stencil: wrapped downwards", .run = Cases.stencilSteps(.with_depth, 0, &.{.{ .first = far_at, .count = 3, .front = .{ .pass_op = .decrement_and_wrap, .compare_op = .always, .write_mask = 0xFF } }}, .{ .compare_op = .equal, .compare_mask = 0xFF, .reference = 255 }) },
    .{ .name = "stencil: inverted", .run = Cases.stencilSteps(.with_depth, 0x0F, &.{.{ .first = far_at, .count = 3, .front = .{ .pass_op = .invert, .compare_op = .always, .write_mask = 0xFF } }}, .{ .compare_op = .equal, .compare_mask = 0xFF, .reference = 0xF0 }) },
    .{ .name = "stencil: zeroed", .run = Cases.stencilSteps(.with_depth, 5, &.{.{ .first = far_at, .count = 3, .front = .{ .pass_op = .zero, .compare_op = .always, .write_mask = 0xFF } }}, .{ .compare_op = .equal, .compare_mask = 0xFF, .reference = 0 }) },
    .{ .name = "stencil: masks", .run = Cases.stencilSteps(.with_depth, 0xA0, &.{.{ .first = far_at, .count = 3, .front = .{ .pass_op = .replace, .compare_op = .always, .write_mask = 0x0F, .reference = 0xFB } }}, .{ .compare_op = .equal, .compare_mask = 0x0F, .reference = 0x0B }) },
    .{ .name = "stencil: a test that fails", .run = Cases.stencilSteps(.with_depth, 2, &.{.{ .first = far_at, .count = 3, .front = .{ .fail_op = .replace, .compare_op = .never, .write_mask = 0xFF, .reference = 1 } }}, equal_1) },
    .{ .name = "stencil: less than kept", .run = Cases.stencilSteps(.with_depth, 2, &.{.{ .first = far_at, .count = 3, .front = marks }}, .{ .compare_op = .less, .compare_mask = 0xFF, .reference = 1 }) },
    .{ .name = "stencil: front and back apart", .run = Cases.stencilSteps(.with_depth, 0, &.{.{ .first = clockwise_at, .count = 6, .front = marks, .back = .{ .pass_op = .replace, .compare_op = .always, .write_mask = 0xFF, .reference = 2 } }}, .{ .compare_op = .equal, .compare_mask = 0xFF, .reference = 2 }) },
    .{ .name = "stencil: where the depth fails", .run = Cases.stencilSteps(.with_depth, 0, &.{ .{ .first = near_at, .count = 3, .front = .{ .compare_op = .always }, .test_depth = true, .write_depth = true }, .{ .first = far_at, .count = 3, .front = .{ .depth_fail_op = .replace, .compare_op = .always, .write_mask = 0xFF, .reference = 1 }, .test_depth = true } }, equal_1) },
    .{ .name = "stencil: drawn in colour as it marks", .run = Cases.stencilSteps(.with_depth, 0, &.{.{ .first = far_at, .count = 3, .front = marks, .shows = true }}, .{ .compare_op = .not_equal, .compare_mask = 0xFF, .reference = 1 }) },
    .{ .name = "stencil: lines mark", .run = Cases.stencilSteps(.with_depth, 0, &.{.{ .first = clockwise_at, .count = 6, .topology = .line_list, .front = marks, .back = .{ .compare_op = .never } }}, equal_1) },
    .{ .name = "stencil: set by commands", .run = &Cases.stencilByCommands },
    .{ .name = "copied: picture to picture", .target = .rgba, .run = &Cases.copied },
    .{ .name = "copied: levels of a texture", .run = &Cases.copiedTexture },
    .{ .name = "copied: to a buffer and back", .target = .rgba, .run = &Cases.readBack },
    .{ .name = "blit: nearest", .run = Cases.blitted(.nearest, false, .bgra) },
    .{ .name = "blit: linear", .run = Cases.blitted(.linear, false, .bgra) },
    .{ .name = "blit: turned round", .run = Cases.blitted(.nearest, true, .bgra) },
    .{ .name = "blit: into rgba", .target = .rgba, .run = Cases.blitted(.linear, false, .rgba) },
    .{ .name = "blit: into 565", .target = .rgb565, .run = Cases.blitted(.nearest, true, .rgb565) },
    .{ .name = "blit: from a texture", .run = &Cases.blittedTexture },
    .{ .name = "cleared in the pass: colour", .run = Cases.clearOf(facet.IMAGE_ASPECT_COLOR) },
    .{ .name = "cleared in the pass: depth", .run = Cases.clearOf(facet.IMAGE_ASPECT_DEPTH) },
    .{ .name = "cleared in the pass: stencil", .run = Cases.clearOf(facet.IMAGE_ASPECT_STENCIL) },
    .{ .name = "scissor", .run = &Cases.scissor },
    .{ .name = "viewport", .run = &Cases.viewport },
    .{ .name = "depth range", .run = &Cases.depthRange },
    .{ .name = "a corner behind the eye", .run = &Cases.behind },
    .{ .name = "part cleared", .run = &Cases.areaClear },
    .{ .name = "part cleared, drawn with depth", .run = &Cases.areaClearDraw },
    .{ .name = "part kept, drawn with depth", .run = &Cases.areaKeep },
    .{ .name = "all kept, drawn with depth", .run = &Cases.wholeKeep },
    .{ .name = "part cleared, texture and colour with depth", .run = &Cases.areaTexture },
    .{ .name = "part cleared, one colour", .run = &Cases.areaColorOnly },
    .{ .name = "part cleared, one with depth", .run = &Cases.areaColorDepth },
    .{ .name = "part cleared, texture alone", .run = &Cases.areaTextureOnly },
    .{ .name = "all kept, texture", .run = &Cases.keptTexture },
    .{ .name = "part kept, texture", .run = &Cases.partKeptTexture },
    .{ .name = "under: cleared, all", .run = Cases.underTexture(false, false, false) },
    .{ .name = "under: cleared, all, depth", .run = Cases.underTexture(false, false, true) },
    .{ .name = "under: kept, all", .run = Cases.underTexture(true, false, false) },
    .{ .name = "under: kept, all, depth", .run = Cases.underTexture(true, false, true) },
    .{ .name = "under: kept, part", .run = Cases.underTexture(true, true, false) },
    .{ .name = "under: kept, part, depth", .run = Cases.underTexture(true, true, true) },
    .{ .name = "texture bilinear", .run = Cases.textured("texture", 0, quad_at) },
    .{ .name = "texture nearest", .run = Cases.textured("nearest", 0, quad_at) },
    .{ .name = "texture repeated", .run = Cases.textured("nearest", 0, wide_at) },
    .{ .name = "texture clamped", .run = Cases.textured("clamp", 0, wide_at) },
    .{ .name = "texture in rgba", .run = Cases.textured("nearest", 1, quad_at) },
    .{ .name = "texture in 565", .run = Cases.textured("nearest 565", 2, quad_at) },
    .{ .name = "texture times colour", .run = &Cases.modulate },
    .{ .name = "shipped colour", .run = Cases.shipped("as it is", "shipped smooth", false, clockwise_at) },
    .{ .name = "shipped flat", .run = Cases.shipped("place", "shipped flat", false, clockwise_at) },
    .{ .name = "shipped dimmed", .run = Cases.shipped("dimmed", "shipped dimmed", false, clockwise_at) },
    .{ .name = "shipped texture", .run = Cases.shipped("texture", "shipped texture", true, quad_at) },
    .{ .name = "shipped texture times colour", .run = Cases.shipped("modulate as it is", "shipped modulated", true, quad_at) },
    .{ .name = "shipped push, pushed again", .run = Cases.pushed },
    .{ .name = "shipped push times colour", .run = Cases.tinted },
    .{ .name = "shipped cutout", .run = Cases.shipped("texture", "shipped cutout", true, quad_at) },
    .{ .name = "shipped cutout the other way", .run = Cases.shipped("texture", "shipped cutout other", true, quad_at) },
    .{ .name = "shipped cutout in front", .run = Cases.cutoutInFront },
    .{ .name = "shipped float arithmetic", .run = Cases.shipped("as it is", "shipped arithmetic", false, clockwise_at) },
    .{ .name = "shipped GLSL.std.450 calls", .run = Cases.shipped("as it is", "shipped called", false, clockwise_at) },
    .{ .name = "shipped chosen floats", .run = Cases.shipped("as it is", "shipped chosen", false, clockwise_at) },
    .{ .name = "shipped selections", .run = Cases.shipped("as it is", "shipped branched", false, clockwise_at) },
    .{ .name = "shipped variables", .run = Cases.shipped("as it is", "shipped unoptimized", false, clockwise_at) },
    .{ .name = "shipped nested selections", .run = Cases.shipped("as it is", "shipped nested", false, clockwise_at) },
} ++ throughCases() ++ [_]Case{
    .{ .name = "no texture", .run = &Cases.missing },
    .{ .name = "drawn in rgba", .target = .rgba, .run = Cases.onTarget(.rgba) },
    .{ .name = "drawn in 565", .target = .rgb565, .run = Cases.onTarget(.rgb565) },
    .{ .name = "mixed by their alpha in rgba", .target = .rgba, .run = Cases.onTargetMixed(.rgba) },
    .{ .name = "mixed by their alpha in 565", .target = .rgb565, .run = Cases.onTargetMixed(.rgb565) },
    .{ .name = "blit: into a texture, then drawn", .run = &Cases.intoTexture },
    .{ .name = "indirect: two draws", .run = &Cases.indirect },
    .{ .name = "indirect: indexed, instanced", .run = &Cases.indirectIndexed },
    .{ .name = "secondary: in a pass", .run = &Cases.inSecondary },
    .{ .name = "secondary: with its own passes", .run = &Cases.wholeSecondary },
    .{ .name = "compute: writes vertices", .run = &Cases.computedVertices },
    .{ .name = "compute: writes a draw's numbers", .run = &Cases.computedNumbers },
    .{ .name = "patches: triangles, even", .run = Cases.tessellated(.{ .patch_points = 3 }, 0, 3) },
    .{ .name = "patches: triangles, uneven", .run = Cases.tessellated(.{ .patch_points = 3, .control = "uneven" }, 0, 6) },
    .{ .name = "patches: triangles, edges", .run = Cases.tessellated(.{ .patch_points = 3, .control = "uneven", .polygon_mode = .line }, 0, 3) },
    .{ .name = "patches: triangles, culled", .run = Cases.tessellated(.{ .patch_points = 3, .cull = facet.CULL_MODE_BACK }, 0, 6) },
    .{ .name = "patches: triangles, culled the other way", .run = Cases.tessellated(.{ .patch_points = 3, .evaluation = "triangles other way", .cull = facet.CULL_MODE_BACK }, 0, 6) },
    .{ .name = "patches: quads, even", .run = Cases.tessellated(.{ .patch_points = 4, .evaluation = "quads" }, quad_at, 4) },
    .{ .name = "patches: quads, uneven", .run = Cases.tessellated(.{ .patch_points = 4, .evaluation = "quads", .control = "uneven", .polygon_mode = .line }, quad_at, 4) },
    .{ .name = "patches: isolines", .run = Cases.tessellated(.{ .patch_points = 4, .evaluation = "isolines", .control = "lines", .line_width = 3 }, quad_at, 4) },
    .{ .name = "array, layer 0", .run = Cases.layer(.array, "array", "array", 0) },
    .{ .name = "array, layer 1", .run = Cases.layer(.array, "array", "array", 1) },
    .{ .name = "array, layer 3", .run = Cases.layer(.array, "array", "array", 3) },
    .{ .name = "array, past the last", .run = Cases.layer(.array, "array", "array", 7) },
    .{ .name = "array, filtered", .run = Cases.layer(.array, "array", "array bilinear", 2) },
    .{ .name = "array, small", .run = Cases.layer(.array, "small array", "array", 2) },
    .{ .name = "array, a layer as a texture", .run = Cases.layerAs2d(.array_layer, false) },
    .{ .name = "array, a layer copied", .run = &Cases.copiedLayer },
    .{ .name = "array, a layer blitted", .run = &Cases.blittedLayer },
    .{ .name = "cube, +x", .run = Cases.layer(.cube, "cube", "cube", 0) },
    .{ .name = "cube, -x", .run = Cases.layer(.cube, "cube", "cube", 1) },
    .{ .name = "cube, +y", .run = Cases.layer(.cube, "cube", "cube", 2) },
    .{ .name = "cube, -y", .run = Cases.layer(.cube, "cube", "cube", 3) },
    .{ .name = "cube, +z", .run = Cases.layer(.cube, "cube", "cube", 4) },
    .{ .name = "cube, -z", .run = Cases.layer(.cube, "cube", "cube", 5) },
    .{ .name = "cube, across an edge", .run = Cases.layer(.cube, "cube", "cube", 6) },
    .{ .name = "cube, filtered", .run = Cases.layer(.cube, "cube", "cube bilinear", 4) },
    .{ .name = "3D, slice 0", .run = Cases.layer(.volume, "volume", "volume", 0) },
    .{ .name = "3D, slice 3", .run = Cases.layer(.volume, "volume", "volume", 3) },
    .{ .name = "3D, slice 7", .run = Cases.layer(.volume, "volume", "volume", 7) },
    .{ .name = "3D, across", .run = Cases.layer(.volume, "volume", "volume", volume_depth) },
    .{ .name = "3D, filtered", .run = Cases.layer(.volume, "volume", "volume bilinear", volume_depth) },
    .{ .name = "BC1", .run = Cases.layerAs2d(.bc1, false) },
    .{ .name = "BC1, with clear texels", .run = Cases.layerAs2d(.bc1_clear, true) },
    .{ .name = "BC2", .run = Cases.layerAs2d(.bc2, true) },
    .{ .name = "BC3", .run = Cases.layerAs2d(.bc3, true) },
    .{ .name = "half-floats", .run = Cases.layerAs2d(.half, false) },
    .{ .name = "floats", .run = Cases.layerAs2d(.float, false) },
    .{ .name = "packed floats", .run = Cases.layerAs2d(.packed_float, false) },
    .{ .name = "shared exponent", .run = Cases.layerAs2d(.shared_exponent, false) },
    .{ .name = "subpasses, first picture", .run = &Cases.subpasses },
    .{ .name = "subpasses, second picture", .target = .rgba, .run = &Cases.subpasses },
    .{ .name = "two attachments, first", .run = &Cases.twoColors },
    .{ .name = "two attachments, second", .target = .rgba, .run = &Cases.twoColors },
    .{ .name = "shadow map, less than a half", .run = Cases.shadowed(false, 0, "whole at a half", "shadow") },
    .{ .name = "shadow map, greater than 0.6", .run = Cases.shadowed(false, 1, "whole at 0.6", "shadow") },
    .{ .name = "shadow map, a slope less than a half", .run = Cases.shadowed(true, 0, "whole at a half", "shadow") },
    // The same through a generated shader, which the V3D compiles
    // (since 1.15).
    .{ .name = "shadow map, generated, less than a half", .run = Cases.shadowed(false, 0, "whole at a half", "shipped shadow") },
    .{ .name = "shadow map, generated, greater than 0.6", .run = Cases.shadowed(false, 1, "whole at 0.6", "shipped shadow") },
    .{ .name = "shadow map, generated, a slope less than a half", .run = Cases.shadowed(true, 0, "whole at a half", "shipped shadow") },
    // Four samples a pixel (since 1.16), which the V3D draws since facet
    // 1.148: resolved in its tiles over all of the picture or over a part
    // of whole supertiles - at 640 wide, a quarter is five tiles of 32 -
    // and on the CPU after the pass over any other.
    .{ .name = "four samples, resolved in the pass", .run = Cases.resolved(null, null) },
    .{ .name = "four samples, resolved over a part to the edges", .run = Cases.resolved(.{ 0.25, 0, 1, 1 }, null) },
    .{ .name = "four samples, resolved over a part", .run = Cases.resolved(.{ 0.1, 0.15, 0.7, 0.8 }, null) },
    .{ .name = "four samples, two of them written", .run = Cases.resolved(null, 0x5) },
    .{ .name = "four samples, resolved by CmdResolveImage", .run = &Cases.resolvedAfter },
    .{ .name = "four samples, covered by alpha", .run = &Cases.covered, .slack = 52 },
    // No colour (since 1.18), which the V3D draws since facet 1.150: a
    // shadow map drawn in a pass of it alone, and a depth drawn in a
    // subpass of its own before the colour is, as a pre-pass is.
    .{ .name = "shadow map alone, less than a half", .run = Cases.shadowedAlone(false, .fixed) },
    .{ .name = "shadow map alone, a slope less than a half", .run = Cases.shadowedAlone(true, .fixed) },
    .{ .name = "shadow map alone, generated", .run = Cases.shadowedAlone(false, .shipped) },
    .{ .name = "shadow map alone, no fragment stage", .run = Cases.shadowedAlone(false, .stageless) },
    // Drawn again over a part, which keeps the rest (since 1.19).
    .{ .name = "shadow map alone, drawn again over a part", .run = &Cases.shadowedOverPart },
    .{ .name = "pre-pass of no colour", .run = Cases.prepassed(false, false, false) },
    .{ .name = "pre-pass of no colour, no fragment stage", .run = Cases.prepassed(false, true, false) },
    .{ .name = "pre-pass of no colour, cleared in it", .run = Cases.prepassed(false, false, true) },
    .{ .name = "pre-pass of an unused colour", .run = Cases.prepassed(true, false, false) },
    .{ .name = "no fragment stage, in a pass of colour", .run = &Cases.stagelessInColor },
    // No attachment at all: what is drawn, counted.
    .{ .name = "no attachment, counted", .run = Cases.counted(1), .counted = true },
    .{ .name = "no attachment, four samples, counted", .run = Cases.counted(4), .counted = true },
};

/// A case for each of `throughs`, after the shipped ones.
fn throughCases() [throughs.len]Case {
    var made: [throughs.len]Case = undefined;
    inline for (&made, throughs, 0..) |*into, each, k| into.* = .{ .name = each.label ++ ", " ++ each.what, .run = Cases.through(k), .slack = each.slack };
    return made;
}

/// How far apart two pixels are, in the channel furthest apart: in steps of
/// a channel of 8 bits, or of 565.
fn apart(target: Target, one: [*]const u8, other: [*]const u8) u32 {
    var most: u32 = 0;
    if (target == .rgb565) {
        const a: u32 = std.mem.readInt(u16, one[0..2], .little);
        const b: u32 = std.mem.readInt(u16, other[0..2], .little);
        for ([_]u5{ 0, 5, 11 }, [_]u32{ 0x1F, 0x3F, 0x1F }) |shift, mask| {
            const x: i32 = @intCast(a >> shift & mask);
            const y: i32 = @intCast(b >> shift & mask);
            most = @max(most, @abs(x - y));
        }
        return most;
    }
    for (0..4) |k| {
        const x: i32 = one[k];
        const y: i32 = other[k];
        most = @max(most, @abs(x - y));
    }
    return most;
}

fn compare(dl: *DosBase, case: *const Case, cores: *const Side, gpu: *const Side) bool {
    const t = @intFromEnum(case.target);
    const bytes: usize = if (case.target == .rgb565) 2 else 4;
    // 565 is dithered on the cores: a step either way is no difference.
    const slack: u32 = case.slack orelse if (case.target == .rgb565) 1 else 2;
    var wrong: u64 = 0;
    var worst: u32 = 0;
    var first_x: usize = 0;
    var first_y: usize = 0;
    var first_cores: u32 = 0;
    var first_gpu: u32 = 0;
    for (0..cores.height) |y| {
        const on_cores = cores.picture_bytes[t] + y * cores.picture_pitch[t];
        const on_gpu = gpu.picture_bytes[t] + y * gpu.picture_pitch[t];
        for (0..cores.width) |x| {
            const distance = apart(case.target, on_cores + x * bytes, on_gpu + x * bytes);
            worst = @max(worst, distance);
            if (distance <= slack) continue;
            if (wrong == 0) {
                first_x = x;
                first_y = y;
                first_cores = pixelAt(on_cores + x * bytes, bytes);
                first_gpu = pixelAt(on_gpu + x * bytes, bytes);
            }
            wrong += 1;
        }
    }
    const pixels = @as(u64, cores.width) * cores.height;
    _ = Printf(dl, "%s: %lu of %lu apart, %lu at worst\n", .{ case.name, wrong, pixels, @as(u64, worst) });
    if (wrong != 0) _ = Printf(dl, "  the first at %lu,%lu: %08lx on the cores, %08lx on the other\n", .{ @as(u64, first_x), @as(u64, first_y), @as(u64, first_cores), @as(u64, first_gpu) });
    const like = wrong <= pixels / 1000;
    if (!like) printMap(dl, case.target, cores, gpu, slack);
    return like;
}

/// Where the pixels apart are, a letter for each part of the picture: `.`
/// none, then more of them.
fn printMap(dl: *DosBase, target: Target, cores: *const Side, gpu: *const Side, slack: u32) void {
    const across = 64;
    const down = 24;
    const t = @intFromEnum(target);
    const bytes: usize = if (target == .rgb565) 2 else 4;
    for (0..down) |row| {
        var line: [across + 1:0]u8 = undefined;
        for (0..across) |column| {
            const left = column * cores.width / across;
            const right = (column + 1) * cores.width / across;
            const top = row * cores.height / down;
            const bottom = (row + 1) * cores.height / down;
            var seen: usize = 0;
            for (top..bottom) |y| for (left..right) |x| {
                const on_cores = cores.picture_bytes[t] + y * cores.picture_pitch[t] + x * bytes;
                const on_gpu = gpu.picture_bytes[t] + y * gpu.picture_pitch[t] + x * bytes;
                if (apart(target, on_cores, on_gpu) > slack) seen += 1;
            };
            line[column] = if (seen == 0) '.' else if (seen * 4 < (right - left) * (bottom - top)) '-' else '#';
        }
        line[across] = '\n';
        line[across + 1] = 0;
        _ = Printf(dl, "%s", .{@as([*:0]const u8, &line)});
    }
}

fn pixelAt(at_pixel: [*]const u8, bytes: usize) u32 {
    return if (bytes == 2) std.mem.readInt(u16, at_pixel[0..2], .little) else std.mem.readInt(u32, at_pixel[0..4], .little);
}

fn parseSize(text: [*:0]const u8) ?[2]u32 {
    var sides = [2]u32{ 0, 0 };
    var side: usize = 0;
    var k: usize = 0;
    while (text[k] != 0) : (k += 1) {
        if (text[k] == 'x' and side == 0) {
            side = 1;
        } else if (text[k] >= '0' and text[k] <= '9') {
            sides[side] = sides[side] * 10 + (text[k] - '0');
        } else return null;
    }
    if (side != 1 or sides[0] == 0 or sides[1] == 0) return null;
    return sides;
}

fn named(case: *const Case, only: ?[*:0]const u8) bool {
    const wanted = std.mem.span(only orelse return true);
    return std.mem.indexOf(u8, std.mem.span(case.name), wanted) != null;
}

fn runAll(dl: *DosBase, cores: *Side, gpu: *Side, only: ?[*:0]const u8) Failure!i32 {
    try cores.up();
    try gpu.up();
    var result: i32 = dos.RETURN_OK;
    for (&cases) |*case| {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) break;
        if (!named(case, only)) continue;
        for ([2]*Side{ cores, gpu }) |side| {
            try Side.expect(side.fb.BeginCommandBuffer(side.commands.?, &.{ .flags = facet.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT }), error.Refused);
            try case.run(side);
            try side.submit();
            side.forgetPipelines();
        }
        if (!compare(dl, case, cores, gpu)) result = dos.RETURN_WARN;
        if (case.counted and !compareCounts(dl, case, cores, gpu)) result = dos.RETURN_WARN;
    }
    return result;
}

/// What a case's occlusion query counted on each side: the same within a
/// sample in 200, or 64, the two rasterizers' edges being their own
/// (since 1.18).
fn compareCounts(dl: *DosBase, case: *const Case, cores: *const Side, gpu: *const Side) bool {
    var tallies: [2]u64 = undefined;
    for ([2]*const Side{ cores, gpu }, &tallies) |side, *count| {
        count.* = 0;
        if (side.fb.GetQueryPoolResults(side.device.?, side.queries.?, 0, 1, @sizeOf(u64), count, @sizeOf(u64), facet.QUERY_RESULT_64 | facet.QUERY_RESULT_WAIT) != .success) {
            _ = Printf(dl, "%s: no count from a query\n", .{case.name});
            return false;
        }
    }
    const apart_by = if (tallies[0] > tallies[1]) tallies[0] - tallies[1] else tallies[1] - tallies[0];
    const like = apart_by <= @max(64, tallies[0] / 200);
    _ = Printf(dl, "%s: counted %lu on the cores, %lu on the other%s\n", .{ case.name, tallies[0], tallies[1], @as([*:0]const u8, if (like) "" else ", too far apart") });
    return like;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const size: [2]u32 = if (argv[0] != 0) parseSize(@ptrFromInt(argv[0])) orelse {
        _ = Printf(dl, "SIZE is WIDTHxHEIGHT\n", .{});
        return dos.RETURN_FAIL;
    } else .{ 640, 360 };

    const facet_lib = sys.OpenLibrary(facet.FACETNAME, 1) orelse {
        _ = Printf(dl, "No %s\n", .{facet.FACETNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(facet_lib);
    const fb: *FacetBase = @ptrCast(facet_lib);
    var instance: ?*facet.Instance = null;
    if (fb.CreateInstance(&.{ .application_name = COMMAND_NAME }, &instance) != .success) return dos.RETURN_FAIL;
    defer fb.DestroyInstance(instance.?);
    var count: u32 = 2;
    var physical: [2]*facet.PhysicalDevice = undefined;
    if (fb.EnumeratePhysicalDevices(instance.?, &count, &physical) != .success or count < 2) {
        _ = Printf(dl, "There is no device after the cores to compare\n", .{});
        return dos.RETURN_WARN;
    }
    var cores = Side{ .fb = fb, .width = size[0], .height = size[1], .physical = physical[0] };
    var gpu = Side{ .fb = fb, .width = size[0], .height = size[1], .physical = physical[1] };
    defer cores.down();
    defer gpu.down();
    const only: ?[*:0]const u8 = if (argv[1] != 0) @ptrFromInt(argv[1]) else null;
    return runAll(dl, &cores, &gpu, only) catch |err| {
        _ = Printf(dl, "It stopped: %s\n", .{@as([*:0]const u8, switch (err) {
            error.NoMemory => "not enough memory",
            error.NoDevice => "no device",
            error.Refused => "facet.library refused something",
            error.DeviceLost => "the device is lost",
        })});
        return dos.RETURN_FAIL;
    };
}
