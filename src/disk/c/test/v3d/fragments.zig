// SPDX-License-Identifier: MIT
//! What V3DTest draws with the fragment programs: each picture worked out
//! from the CPU as well, and the two compared pixel for pixel.

const sdk = @import("sdk");
const v3d = @import("v3d");
const exec = sdk.exec;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;
const qpu = v3d.qpu;
const cl = v3d.cl;
const Frame = v3d.frame.Frame;
const DrawState = v3d.frame.DrawState;
const Area = v3d.frame.Area;
const tiling = v3d.tiling;
const Block = v3d.Block;

const width: u32 = 1280;
const height: u32 = 720;
const half_width: f32 = 640;
const half_height: f32 = 360;
const stride: u32 = width * 4;
const whole = Area{ .left = 0, .top = 0, .right = width, .bottom = height };
const backdrop: u32 = 0xFF20_1008;

/// A vertex as the programs read it: the clip position for the binner, its
/// place on screen, depth and 1/w for the renderer, and what it carries.
pub const Vertex = extern struct {
    clip: [4]f32,
    screen_x: i32,
    screen_y: i32,
    depth: f32,
    one_over_w: f32,
    varyings: [8]f32 = @splat(0),
};

/// A vertex at (x, y) of the image's -1 to 1.
fn at(x: f32, y: f32, depth: f32, w: f32, varyings: []const f32) Vertex {
    var made = Vertex{
        .clip = .{ x * w, y * w, depth * w, w },
        .screen_x = @intFromFloat(x * half_width * 64.0),
        .screen_y = @intFromFloat(y * half_height * 64.0),
        .depth = depth,
        .one_over_w = 1 / w,
    };
    @memcpy(made.varyings[0..varyings.len], varyings);
    return made;
}

/// The pixel `x` across as the image's -1 to 1, on its left edge.
fn acrossAt(x: f32) f32 {
    return x / half_width - 1;
}

fn downAt(y: f32) f32 {
    return y / half_height - 1;
}

/// A rectangle of pixels as two triangles, carrying what `carry` says of
/// each corner: 0 to 1 across it, and down.
fn rectangle(into: []Vertex, left: f32, top: f32, right: f32, bottom: f32, depth: f32, carry: anytype) void {
    const corners = [6][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
    for (into[0..6], corners) |*vertex, corner| {
        const across = left + (right - left) * corner[0];
        const down = top + (bottom - top) * corner[1];
        const values = carry.of(corner[0], corner[1]);
        vertex.* = at(acrossAt(across), downAt(down), depth, 1, &values);
    }
}

const Nothing = struct {
    fn of(_: Nothing, _: f32, _: f32) [0]f32 {
        return .{};
    }
};

const half_one: u32 = 0x3C00;

fn half(value: f32) u32 {
    const small: f16 = @floatCast(value);
    const bits: u16 = @bitCast(small);
    return bits;
}

/// A colour as the flat program's two uniforms.
fn flat(red: f32, green: f32, blue: f32, alpha: f32) [2]u32 {
    return .{ half(red) | half(green) << 16, half(blue) | half(alpha) << 16 };
}

pub const Scene = struct {
    dl: *DosBase,
    space: *v3d.Space,
    engine: *v3d.Engine,
    image: Block,
    lists: Block,
    objects: Block,
    vertices: Block,
    tile_lists: Block,
    tile_state: Block,
    objects_used: u32 = 0,
    vertices_used: u32 = 0,
    frame: Frame = undefined,
    bin: cl.List = undefined,
    took_us: u64 = 0,

    pub fn open(dl: *DosBase, space: *v3d.Space, engine: *v3d.Engine) ?Scene {
        const tiles = ((width + 63) / 64) * ((height + 63) / 64);
        const image = space.alloc(stride * height) orelse return null;
        const lists = space.alloc(64 * 1024) orelse return null;
        const objects = space.alloc(64 * 1024) orelse return null;
        const vertices = space.alloc(64 * 1024) orelse return null;
        const tile_lists = space.alloc(tiles * 128 + 512 * 1024) orelse return null;
        const tile_state = space.alloc(tiles * 256) orelse return null;
        if (!space.flush()) return null;
        return .{ .dl = dl, .space = space, .engine = engine, .image = image, .lists = lists, .objects = objects, .vertices = vertices, .tile_lists = tile_lists, .tile_state = tile_state };
    }

    pub fn close(scene: *Scene) void {
        const space = scene.space;
        space.free(&scene.image);
        space.free(&scene.lists);
        space.free(&scene.objects);
        space.free(&scene.vertices);
        space.free(&scene.tile_lists);
        space.free(&scene.tile_state);
    }

    fn pixels(scene: *const Scene) [*]u32 {
        return @ptrCast(@alignCast(scene.image.cpu));
    }

    pub fn pixel(scene: *const Scene, x: u32, y: u32) u32 {
        return scene.pixels()[y * width + x];
    }

    const Begin = struct {
        clear: u32 = backdrop,
        depth: bool = false,
        clear_depth: f32 = 1,
        load: bool = false,
        area: ?Area = null,
    };

    /// A new frame: nothing of the last but the image.
    fn begin(scene: *Scene, how: Begin) void {
        scene.objects_used = 0;
        scene.vertices_used = 0;
        scene.frame = .{
            .width = width,
            .height = height,
            .image = scene.image.address,
            .stride = stride,
            .swap_rb = false,
            .clear = how.clear,
            .tile_lists = scene.tile_lists.address,
            .binned = true,
            .load = how.load,
            .depth = how.depth,
            .clear_depth = how.clear_depth,
            .area = how.area,
        };
        scene.bin = .{ .at = scene.lists.cpu + 8192, .address = scene.lists.address + 8192 };
        v3d.frame.beginBin(&scene.bin, &scene.frame);
    }

    fn place(scene: *Scene, bytes: u32, alignment: u32) struct { [*]u8, u32 } {
        const start = (scene.objects_used + alignment - 1) & ~(alignment - 1);
        scene.objects_used = start + bytes;
        return .{ scene.objects.cpu + start, scene.objects.address + start };
    }

    fn program(scene: *Scene, code: []const u64) u32 {
        const cpu, const address = scene.place(@intCast(code.len * 8), 8);
        const words: [*]u64 = @ptrCast(@alignCast(cpu));
        @memcpy(words[0..code.len], code);
        return address;
    }

    const Draw = struct {
        fragment: qpu.Fragment,
        uniforms: []const u32 = &.{},
        vertices: []const Vertex,
        cfg: cl.Cfg = .{},
        clip: Area = whole,
    };

    fn draw(scene: *Scene, how: Draw) void {
        const varyings = how.fragment.varyings;
        const uniforms_cpu, const uniforms = scene.place(@intCast(@max(how.uniforms.len, 1) * 4), 4);
        const words: [*]u32 = @ptrCast(@alignCast(uniforms_cpu));
        @memcpy(words[0..how.uniforms.len], how.uniforms);

        const vertex_bytes = how.vertices.len * @sizeOf(Vertex);
        const into: [*]Vertex = @ptrCast(@alignCast(scene.vertices.cpu + scene.vertices_used));
        @memcpy(into[0..how.vertices.len], how.vertices);
        const vertices = scene.vertices.address + scene.vertices_used;
        scene.vertices_used += @intCast(vertex_bytes);

        const attributes: u32 = 2 + @as(u32, @intFromBool(varyings > 0)) + @as(u32, @intFromBool(varyings > 4));
        const record_cpu, const record = scene.place(cl.shader_record_bytes + 16 * attributes, 32);
        var list = cl.List{ .at = record_cpu, .address = record };
        const pass = qpu.coordinate_program[0..];
        cl.shaderRecord(&list, .{
            .fragment = scene.program(how.fragment.code),
            .fragment_uniforms = uniforms,
            .vertex = scene.program(qpu.vertexProgram(varyings)),
            .vertex_uniforms = uniforms,
            .coordinate = scene.program(pass),
            .coordinate_uniforms = uniforms,
            .varyings = varyings,
        });
        const vertex_stride: u32 = @sizeOf(Vertex);
        cl.attribute(&list, vertices, 4, 4, 0, vertex_stride);
        cl.attribute(&list, vertices + 16, 4, 2, 4, vertex_stride);
        if (varyings > 0) cl.attribute(&list, vertices + 32, @min(varyings, 4), 0, @min(varyings, 4), vertex_stride);
        if (varyings > 4) cl.attribute(&list, vertices + 48, varyings - 4, 0, varyings - 4, vertex_stride);

        v3d.frame.writeDrawState(&scene.bin, &.{
            .clip = how.clip,
            .cfg = how.cfg,
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
        });
        cl.glShaderState(&scene.bin, record, attributes);
        cl.vertexArrayPrims(&scene.bin, cl.PRIM_TRIANGLES, @intCast(how.vertices.len), 0);
    }

    /// The frame drawn: false, and it said why, when it could not be.
    fn finish(scene: *Scene) bool {
        v3d.frame.endBin(&scene.bin);
        var tile_list = cl.List{ .at = scene.lists.cpu, .address = scene.lists.address };
        v3d.frame.writeTileList(&tile_list, &scene.frame);
        var render = cl.List{ .at = scene.lists.cpu + 1024, .address = scene.lists.address + 1024 };
        v3d.frame.writeRender(&render, &scene.frame, tile_list.address, tile_list.here());
        const space = scene.space;
        space.toGpu(&scene.image);
        space.toGpu(&scene.lists);
        space.toGpu(&scene.objects);
        space.toGpu(&scene.vertices);
        const began = sdk.hardware.systimer.uptimeUs();
        const engine = scene.engine;
        const binned = engine.bin(scene.bin.address, scene.bin.here(), &scene.tile_lists, &scene.tile_state);
        if (binned != .done) {
            lost(scene.dl, engine, binned, "binning");
            return false;
        }
        const rendered = engine.render(render.address, render.here());
        scene.took_us = sdk.hardware.systimer.uptimeUs() - began;
        space.fromGpu(&scene.image);
        if (rendered != .done) {
            lost(scene.dl, engine, rendered, "rendering");
            return false;
        }
        return true;
    }
};

fn lost(dl: *DosBase, engine: *const v3d.Engine, finished: v3d.Engine.Finished, what: [*:0]const u8) void {
    switch (finished) {
        .fault => _ = Printf(dl, "%s: MMU fault %02lx from client %lx at %lx\n", .{
            what, @as(u64, engine.last_fault.status), @as(u64, engine.last_fault.client), engine.last_fault.address,
        }),
        else => _ = Printf(dl, "%s: it did not finish, %ld core interrupt(s), %ld hub\n", .{
            what, @as(u64, engine.core_interrupts), @as(u64, engine.hub_interrupts),
        }),
    }
}

/// How far apart two colours are, in the channel furthest apart, alpha left
/// out when `colour_only`.
fn apart(one: u32, other: u32, colour_only: bool) u32 {
    var most: u32 = 0;
    for ([_]u5{ 0, 8, 16, 24 }) |shift| {
        if (colour_only and shift == 24) continue;
        const a: i32 = @intCast(one >> shift & 0xFF);
        const b: i32 = @intCast(other >> shift & 0xFF);
        most = @max(most, @abs(a - b));
    }
    return most;
}

fn rgba(red: f32, green: f32, blue: f32, alpha: f32) u32 {
    return byteOf(red) | byteOf(green) << 8 | byteOf(blue) << 16 | byteOf(alpha) << 24;
}

fn byteOf(value: f32) u32 {
    return @intFromFloat(@min(@max(value, 0), 1) * 255 + 0.5);
}

/// A comparison's tally.
const Tally = struct {
    checked: u64 = 0,
    wrong: u64 = 0,
    worst: u32 = 0,
    first_x: u32 = 0,
    first_y: u32 = 0,
    first_got: u32 = 0,
    first_want: u32 = 0,

    fn check(tally: *Tally, x: u32, y: u32, got: u32, want: u32, slack: u32) void {
        tally.checked += 1;
        const distance = apart(got, want, false);
        tally.worst = @max(tally.worst, distance);
        if (distance <= slack) return;
        if (tally.wrong == 0) {
            tally.first_x = x;
            tally.first_y = y;
            tally.first_got = got;
            tally.first_want = want;
        }
        tally.wrong += 1;
    }

    fn report(tally: *const Tally, dl: *DosBase, what: [*:0]const u8, took_us: u64) i32 {
        _ = Printf(dl, "%s: %ld us, %ld pixels checked, %ld wrong, %ld at worst\n", .{ what, took_us, tally.checked, tally.wrong, @as(u64, tally.worst) });
        if (tally.wrong != 0) {
            _ = Printf(dl, "  the first at %ld,%ld reads %08lx, not %08lx\n", .{ @as(u64, tally.first_x), @as(u64, tally.first_y), @as(u64, tally.first_got), @as(u64, tally.first_want) });
            return dos.RETURN_WARN;
        }
        if (tally.checked == 0) return dos.RETURN_WARN;
        return dos.RETURN_OK;
    }
};

/// Where the pixel centre (x, y) lies in a triangle given by its clip
/// positions: each corner's share, mixed as w has it, or null past the
/// clip plane w = 0 or where the three do not make a triangle.
fn shares(corners: *const [3]Vertex, x: u32, y: u32) ?[3]f64 {
    const px = @as(f64, acrossAt(@as(f32, @floatFromInt(x)) + 0.5));
    const py = @as(f64, downAt(@as(f32, @floatFromInt(y)) + 0.5));
    const a: [3]f64 = .{ corners[0].clip[0], corners[1].clip[0], corners[2].clip[0] };
    const b: [3]f64 = .{ corners[0].clip[1], corners[1].clip[1], corners[2].clip[1] };
    const c: [3]f64 = .{ corners[0].clip[3], corners[1].clip[3], corners[2].clip[3] };
    const whole_det = a[0] * (b[1] * c[2] - b[2] * c[1]) - a[1] * (b[0] * c[2] - b[2] * c[0]) + a[2] * (b[0] * c[1] - b[1] * c[0]);
    if (whole_det == 0) return null;
    const s0 = (px * (b[1] * c[2] - b[2] * c[1]) - a[1] * (py * c[2] - b[2]) + a[2] * (py * c[1] - b[1])) / whole_det;
    const s1 = (a[0] * (py * c[2] - b[2]) - px * (b[0] * c[2] - b[2] * c[0]) + a[2] * (b[0] - py * c[0])) / whole_det;
    const s2 = (a[0] * (b[1] - py * c[1]) - a[1] * (b[0] - py * c[0]) + px * (b[0] * c[1] - b[1] * c[0])) / whole_det;
    const sum = s0 + s1 + s2;
    if (sum <= 0) return null;
    return .{ s0 / sum, s1 / sum, s2 / sum };
}

const edge_margin: f64 = 0.01;

/// Three colours mixed over a triangle whose corners are at different
/// distances: the colours at each pixel as w mixes them.
pub fn smoothTest(scene: *Scene) i32 {
    const corners = [3]Vertex{
        at(0, 0.8, 0.5, 1, &.{ 1, 0, 0, 1 }),
        at(-0.8, -0.8, 0.5, 2, &.{ 0, 1, 0, 1 }),
        at(0.8, -0.8, 0.5, 4, &.{ 0, 0, 1, 1 }),
    };
    scene.begin(.{});
    scene.draw(.{ .fragment = qpu.color_fragment, .vertices = &corners });
    if (!scene.finish()) return dos.RETURN_FAIL;
    var tally = Tally{};
    for (0..height) |row| for (0..width) |column| {
        const x: u32 = @intCast(column);
        const y: u32 = @intCast(row);
        const got = scene.pixel(x, y);
        const each = shares(&corners, x, y) orelse continue;
        const inside = each[0] > edge_margin and each[1] > edge_margin and each[2] > edge_margin;
        const outside = each[0] < -edge_margin or each[1] < -edge_margin or each[2] < -edge_margin;
        if (inside) {
            tally.check(x, y, got, rgba(@floatCast(each[0]), @floatCast(each[1]), @floatCast(each[2]), 1), 2);
        } else if (outside) {
            tally.check(x, y, got, backdrop, 0);
        }
    };
    return tally.report(scene.dl, "smooth", scene.took_us);
}

/// A triangle with a corner behind the eye: what is drawn is what lies in
/// front of it, as far as the clipper goes.
pub fn clipTest(scene: *Scene) i32 {
    const colour = [_]f32{ 1, 1, 1, 1 };
    var corners = [3]Vertex{
        at(-0.5, -0.5, 0.5, 1, &colour),
        at(0.5, -0.5, 0.5, 1, &colour),
        at(0, 1, 0.5, -0.5, &colour),
    };
    corners[2].depth = 0.5;
    scene.begin(.{});
    scene.draw(.{ .fragment = qpu.color_fragment, .vertices = &corners });
    if (!scene.finish()) return dos.RETURN_FAIL;
    var tally = Tally{};
    var drawn: u64 = 0;
    for (0..height) |row| for (0..width) |column| {
        const x: u32 = @intCast(column);
        const y: u32 = @intCast(row);
        const got = scene.pixel(x, y);
        if (got != backdrop) drawn += 1;
        const each = shares(&corners, x, y) orelse {
            tally.check(x, y, got, backdrop, 0);
            continue;
        };
        const inside = each[0] > edge_margin and each[1] > edge_margin and each[2] > edge_margin;
        const outside = each[0] < -edge_margin or each[1] < -edge_margin or each[2] < -edge_margin;
        if (inside) {
            tally.check(x, y, got, 0xFFFF_FFFF, 0);
        } else if (outside) {
            tally.check(x, y, got, backdrop, 0);
        }
    };
    _ = Printf(scene.dl, "clip: %ld pixels drawn\n", .{drawn});
    return tally.report(scene.dl, "clip", scene.took_us);
}

/// A texture in memory the V3D reaches.
const Picture = struct {
    block: Block,
    layout: tiling.Layout,
    state: [tiling.texture_state_bytes]u8 = undefined,

    fn put(picture: *Picture, level: u32, x: u32, y: u32, texel: u32) void {
        const words: [*]align(1) u32 = @ptrCast(picture.block.cpu + tiling.texelOffset(&picture.layout, level, x, y));
        words[0] = texel;
    }
};

fn makePicture(scene: *Scene, across: u32, down: u32, levels: u32) ?Picture {
    const layout = tiling.layoutOf(4, across, down, levels);
    const block = scene.space.alloc(layout.bytes) orelse return null;
    if (!scene.space.flush()) return null;
    var picture = Picture{ .block = block, .layout = layout };
    tiling.writeTextureState(&picture.state, &layout, .rgba, block.address, 0, levels - 1);
    return picture;
}

/// A texel that says where it is.
fn placeTexel(level: u32, x: u32, y: u32) u32 {
    return (x & 0xFF) | (y & 0xFF) << 8 | ((level * 16) | (x >> 8 & 3) | (y >> 8 & 3) << 2) << 16 | 0xFF00_0000;
}

/// The two uniforms of a program that samples: its state and a sampler's,
/// placed in the frame.
fn sampling(scene: *Scene, picture: *const Picture, filter: tiling.Filter, wrap: tiling.Wrap) [2]u32 {
    const texture_cpu, const texture_at = scene.place(tiling.texture_state_bytes, tiling.texture_state_alignment);
    @memcpy(texture_cpu[0..tiling.texture_state_bytes], &picture.state);
    const sampler_cpu, const sampler_at = scene.place(tiling.sampler_state_bytes, tiling.sampler_state_alignment);
    tiling.writeSamplerState(sampler_cpu[0..tiling.sampler_state_bytes], filter, wrap);
    return .{ tiling.parameter0(texture_at), tiling.parameter1(sampler_at) };
}

const Across = struct {
    /// What the corners carry: from `from` to `to`, both ways.
    from: f32 = 0,
    to: f32 = 1,

    fn of(carry: Across, x: f32, y: f32) [2]f32 {
        return .{ carry.from + (carry.to - carry.from) * x, carry.from + (carry.to - carry.from) * y };
    }
};

/// `picture`'s `level` drawn one texel to a pixel, in the image's corner:
/// what the TMU reads against where it was put.
fn drawnOneToOne(scene: *Scene, picture: *Picture, level: u32, tally: *Tally) bool {
    const across = @max(picture.layout.levels[level].width, 1);
    const down = @max(picture.layout.levels[level].height, 1);
    var corners: [6]Vertex = undefined;
    rectangle(&corners, 0, 0, @floatFromInt(across), @floatFromInt(down), 0.5, Across{});
    scene.begin(.{});
    const uniforms = sampling(scene, picture, .nearest, .repeat);
    scene.draw(.{ .fragment = qpu.texture_fragment, .uniforms = &uniforms, .vertices = &corners });
    if (!scene.finish()) return false;
    for (0..@min(down, height)) |row| for (0..@min(across, width)) |column| {
        const x: u32 = @intCast(column);
        const y: u32 = @intCast(row);
        tally.check(x, y, scene.pixel(x, y), placeTexel(level, x, y), 0);
    };
    return true;
}

/// Textures of each layout the TMU knows, each texel where it should be.
pub fn textureTest(scene: *Scene) i32 {
    const sizes = [_][2]u32{ .{ 4, 4 }, .{ 8, 8 }, .{ 16, 16 }, .{ 32, 32 }, .{ 64, 64 }, .{ 128, 128 }, .{ 256, 256 }, .{ 1024, 1024 }, .{ 256, 64 }, .{ 64, 256 }, .{ 2, 2 }, .{ 1, 1 } };
    var result: i32 = dos.RETURN_OK;
    for (sizes) |size| {
        var picture = makePicture(scene, size[0], size[1], 1) orelse return dos.RETURN_FAIL;
        defer scene.space.free(&picture.block);
        for (0..size[1]) |y| for (0..size[0]) |x| picture.put(0, @intCast(x), @intCast(y), placeTexel(0, @intCast(x), @intCast(y)));
        scene.space.toGpu(&picture.block);
        var tally = Tally{};
        if (!drawnOneToOne(scene, &picture, 0, &tally)) return dos.RETURN_FAIL;
        _ = Printf(scene.dl, "texture %ldx%ld: %ld us, %ld wrong of %ld\n", .{ @as(u64, size[0]), @as(u64, size[1]), scene.took_us, tally.wrong, tally.checked });
        if (tally.wrong != 0) {
            _ = Printf(scene.dl, "  the first at %ld,%ld reads %08lx, not %08lx\n", .{ @as(u64, tally.first_x), @as(u64, tally.first_y), @as(u64, tally.first_got), @as(u64, tally.first_want) });
            result = dos.RETURN_WARN;
        }
    }
    return result;
}

/// A texture's levels each drawn at the size that picks it: the level's own
/// texels, each where it should be.
pub fn mipTest(scene: *Scene) i32 {
    var result: i32 = dos.RETURN_OK;
    for ([_][2]u32{ .{ 256, 256 }, .{ 64, 64 }, .{ 128, 32 } }) |size| {
        const levels: u32 = sizeLevels(size[0], size[1]);
        var picture = makePicture(scene, size[0], size[1], levels) orelse return dos.RETURN_FAIL;
        defer scene.space.free(&picture.block);
        for (0..levels) |index| {
            const level: u32 = @intCast(index);
            const across = picture.layout.levels[level].width;
            const down = picture.layout.levels[level].height;
            for (0..down) |y| for (0..across) |x| picture.put(level, @intCast(x), @intCast(y), placeTexel(level, @intCast(x), @intCast(y)));
        }
        scene.space.toGpu(&picture.block);
        for (0..levels) |index| {
            const level: u32 = @intCast(index);
            var tally = Tally{};
            if (!drawnOneToOne(scene, &picture, level, &tally)) return dos.RETURN_FAIL;
            _ = Printf(scene.dl, "mip %ldx%ld level %ld: %ld wrong of %ld\n", .{ @as(u64, size[0]), @as(u64, size[1]), @as(u64, level), tally.wrong, tally.checked });
            if (tally.wrong != 0) {
                _ = Printf(scene.dl, "  the first at %ld,%ld reads %08lx, not %08lx\n", .{ @as(u64, tally.first_x), @as(u64, tally.first_y), @as(u64, tally.first_got), @as(u64, tally.first_want) });
                result = dos.RETURN_WARN;
            }
        }
    }
    return result;
}

fn sizeLevels(across: u32, down: u32) u32 {
    var levels: u32 = 1;
    var most = @max(across, down);
    while (most > 1) : (most >>= 1) levels += 1;
    return levels;
}

fn wrapped(at_texel: i32, size: i32, wrap: tiling.Wrap) u32 {
    return @intCast(switch (wrap) {
        .repeat => @mod(at_texel, size),
        .clamp => @min(@max(at_texel, 0), size - 1),
    });
}

/// A small texture past its edges, and between its texels: each filter and
/// each wrap against the sum done here.
pub fn filterTest(scene: *Scene) i32 {
    const side: u32 = 16;
    const scale: u32 = 4;
    var picture = makePicture(scene, side, side, 1) orelse return dos.RETURN_FAIL;
    defer scene.space.free(&picture.block);
    for (0..side) |y| for (0..side) |x| picture.put(0, @intCast(x), @intCast(y), 0xFF00_0000 | @as(u32, @intCast(x * 16)) | @as(u32, @intCast(y * 16)) << 8);
    scene.space.toGpu(&picture.block);
    var result: i32 = dos.RETURN_OK;
    // From -1 to 2: the texture three times across, at 4 pixels a texel.
    const drawn = 3 * side * scale;
    for ([_]tiling.Filter{ .nearest, .bilinear }) |filter| for ([_]tiling.Wrap{ .repeat, .clamp }) |wrap| {
        var corners: [6]Vertex = undefined;
        rectangle(&corners, 0, 0, @floatFromInt(drawn), @floatFromInt(drawn), 0.5, Across{ .from = -1, .to = 2 });
        scene.begin(.{});
        const uniforms = sampling(scene, &picture, filter, wrap);
        scene.draw(.{ .fragment = qpu.texture_fragment, .uniforms = &uniforms, .vertices = &corners });
        if (!scene.finish()) return dos.RETURN_FAIL;
        var tally = Tally{};
        for (0..drawn) |row| for (0..drawn) |column| {
            const x: u32 = @intCast(column);
            const y: u32 = @intCast(row);
            const u = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, scale) - @as(f32, side);
            const v = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, scale) - @as(f32, side);
            const want = filtered(filter, wrap, side, u, v);
            tally.check(x, y, scene.pixel(x, y), want, if (filter == .nearest) 0 else 3);
        };
        _ = Printf(scene.dl, "%s, %s: %ld wrong of %ld, %ld at worst\n", .{
            @as([*:0]const u8, if (filter == .nearest) "nearest" else "bilinear"),
            @as([*:0]const u8, if (wrap == .repeat) "repeat" else "clamp"),
            tally.wrong,
            tally.checked,
            @as(u64, tally.worst),
        });
        if (tally.wrong != 0) {
            _ = Printf(scene.dl, "  the first at %ld,%ld reads %08lx, not %08lx\n", .{ @as(u64, tally.first_x), @as(u64, tally.first_y), @as(u64, tally.first_got), @as(u64, tally.first_want) });
            result = dos.RETURN_WARN;
        }
    };
    return result;
}

/// The sum for `filterTest`: `u`, `v` in texels of the texture it fills.
fn filtered(filter: tiling.Filter, wrap: tiling.Wrap, side: u32, u: f32, v: f32) u32 {
    const size: i32 = @intCast(side);
    if (filter == .nearest) {
        const x = wrapped(@intFromFloat(@floor(u)), size, wrap);
        const y = wrapped(@intFromFloat(@floor(v)), size, wrap);
        return 0xFF00_0000 | x * 16 | (y * 16) << 8;
    }
    const left = @floor(u - 0.5);
    const top = @floor(v - 0.5);
    const across = u - 0.5 - left;
    const down = v - 0.5 - top;
    const x0: f32 = @floatFromInt(wrapped(@as(i32, @intFromFloat(left)), size, wrap));
    const x1: f32 = @floatFromInt(wrapped(@as(i32, @intFromFloat(left)) + 1, size, wrap));
    const y0: f32 = @floatFromInt(wrapped(@as(i32, @intFromFloat(top)), size, wrap));
    const y1: f32 = @floatFromInt(wrapped(@as(i32, @intFromFloat(top)) + 1, size, wrap));
    const red = (x0 * (1 - across) + x1 * across) * 16 / 255;
    const green = (y0 * (1 - down) + y1 * down) * 16 / 255;
    return rgba(red, green, 0, 1);
}

/// A texture times the colour the vertices carry.
pub fn modulateTest(scene: *Scene) i32 {
    const side: u32 = 64;
    var picture = makePicture(scene, side, side, 1) orelse return dos.RETURN_FAIL;
    defer scene.space.free(&picture.block);
    for (0..side) |y| for (0..side) |x| picture.put(0, @intCast(x), @intCast(y), 0xFF80_0000 | @as(u32, @intCast(x * 4)) | @as(u32, @intCast(y * 4)) << 8);
    scene.space.toGpu(&picture.block);
    const Carry = struct {
        fn of(_: @This(), x: f32, y: f32) [6]f32 {
            return .{ x, y, 0.5, 1, 0.25, 0.75 };
        }
    };
    var corners: [6]Vertex = undefined;
    rectangle(&corners, 0, 0, @floatFromInt(side), @floatFromInt(side), 0.5, Carry{});
    scene.begin(.{});
    const uniforms = sampling(scene, &picture, .nearest, .repeat);
    scene.draw(.{ .fragment = qpu.texture_color_fragment, .uniforms = &uniforms, .vertices = &corners });
    if (!scene.finish()) return dos.RETURN_FAIL;
    var tally = Tally{};
    for (0..side) |row| for (0..side) |column| {
        const x: u32 = @intCast(column);
        const y: u32 = @intCast(row);
        const want = rgba(@as(f32, @floatFromInt(x * 4)) / 255 * 0.5, @as(f32, @floatFromInt(y * 4)) / 255, 128.0 / 255.0 * 0.25, 0.75);
        tally.check(x, y, scene.pixel(x, y), want, 2);
    };
    return tally.report(scene.dl, "modulate", scene.took_us);
}

const a_colour = flat(1, 0, 0, 1);
const b_colour = flat(0, 1, 0, 1);
const a_pixel: u32 = 0xFF00_00FF;
const b_pixel: u32 = 0xFF00_FF00;

/// Two rectangles over each other, tested and written as each case says.
fn depthCase(scene: *Scene, name: [*:0]const u8, first_depth: f32, second_depth: f32, compare: u32, write: bool, clear_depth: f32, want: u32) ?i32 {
    var first: [6]Vertex = undefined;
    var second: [6]Vertex = undefined;
    rectangle(&first, 100, 100, 300, 300, first_depth, Nothing{});
    rectangle(&second, 100, 100, 300, 300, second_depth, Nothing{});
    const cfg = cl.Cfg{ .compare = compare, .depth_write = write };
    scene.begin(.{ .depth = true, .clear_depth = clear_depth });
    scene.draw(.{ .fragment = qpu.flat_fragment, .uniforms = &a_colour, .vertices = &first, .cfg = cfg });
    scene.draw(.{ .fragment = qpu.flat_fragment, .uniforms = &b_colour, .vertices = &second, .cfg = cfg });
    if (!scene.finish()) return dos.RETURN_FAIL;
    var tally = Tally{};
    for (100..300) |y| for (100..300) |x| tally.check(@intCast(x), @intCast(y), scene.pixel(@intCast(x), @intCast(y)), want, 0);
    const result = tally.report(scene.dl, name, scene.took_us);
    return if (result == dos.RETURN_OK) null else result;
}

const LESS: u32 = 1;
const GREATER: u32 = 4;

pub fn depthTest(scene: *Scene) i32 {
    var result: i32 = dos.RETURN_OK;
    const cases = .{
        .{ "near first, less", 0.25, 0.75, LESS, true, 1.0, a_pixel },
        .{ "far first, less", 0.75, 0.25, LESS, true, 1.0, b_pixel },
        .{ "near first, not written", 0.25, 0.75, LESS, false, 1.0, b_pixel },
        .{ "near first, greater", 0.25, 0.75, GREATER, true, 0.0, b_pixel },
    };
    inline for (cases) |case| {
        if (depthCase(scene, case[0], case[1], case[2], case[3], case[4], case[5], case[6])) |failed| result = @max(result, failed);
    }
    // Depth from -0.5 to 0.5 across it: the left half is in front of the
    // near plane and is clipped away.
    const Clipped = struct {
        fn make(x: f32, y: f32, depth: f32) Vertex {
            return at(acrossAt(x), downAt(y), depth, 1, &.{});
        }
    };
    const corners = [6]Vertex{
        Clipped.make(100, 100, -0.5), Clipped.make(300, 100, 0.5), Clipped.make(100, 300, -0.5),
        Clipped.make(300, 100, 0.5),  Clipped.make(300, 300, 0.5), Clipped.make(100, 300, -0.5),
    };
    scene.begin(.{ .depth = true });
    scene.draw(.{ .fragment = qpu.flat_fragment, .uniforms = &a_colour, .vertices = &corners, .cfg = .{ .compare = LESS, .depth_write = true } });
    if (!scene.finish()) return dos.RETURN_FAIL;
    var tally = Tally{};
    for (100..300) |row| for (100..300) |column| {
        const x: u32 = @intCast(column);
        const y: u32 = @intCast(row);
        if (x >= 198 and x <= 201) continue;
        tally.check(x, y, scene.pixel(x, y), if (x > 200) a_pixel else backdrop, 0);
    };
    return @max(result, tally.report(scene.dl, "clipped at the near plane", scene.took_us));
}

/// A half-seen colour over what the tiles were cleared to.
pub fn blendTest(scene: *Scene) i32 {
    var corners: [6]Vertex = undefined;
    rectangle(&corners, 100, 100, 300, 300, 0.5, Nothing{});
    const half_red = flat(1, 0, 0, 0.5);
    scene.begin(.{ .clear = 0xFFC0_8040 });
    scene.draw(.{ .fragment = qpu.flat_fragment, .uniforms = &half_red, .vertices = &corners, .cfg = .{ .blend = true } });
    if (!scene.finish()) return dos.RETURN_FAIL;
    var tally = Tally{};
    const want = rgba((0.5 + 64.0 / 255.0 * 0.5), 128.0 / 255.0 * 0.5, 192.0 / 255.0 * 0.5, 0.75);
    for (100..300) |y| for (100..300) |x| tally.check(@intCast(x), @intCast(y), scene.pixel(@intCast(x), @intCast(y)), want, 2);
    return tally.report(scene.dl, "blend", scene.took_us);
}

/// A frame cleared, then a part of it drawn over from what it holds: all
/// outside that part stays, through tiles loaded and tiles not touched.
pub fn areaTest(scene: *Scene) i32 {
    var corners: [6]Vertex = undefined;
    scene.begin(.{});
    if (!scene.finish()) return dos.RETURN_FAIL;
    rectangle(&corners, 0, 0, width, height, 0.5, Nothing{});
    const inside = Area{ .left = 70, .top = 90, .right = 190, .bottom = 200 };
    scene.begin(.{ .clear = 0xFF00_0000, .load = true, .area = inside });
    scene.draw(.{ .fragment = qpu.flat_fragment, .uniforms = &a_colour, .vertices = &corners, .clip = inside });
    if (!scene.finish()) return dos.RETURN_FAIL;
    var tally = Tally{};
    for (0..height) |row| for (0..width) |column| {
        const x: u32 = @intCast(column);
        const y: u32 = @intCast(row);
        const in = x >= inside.left and x < inside.right and y >= inside.top and y < inside.bottom;
        tally.check(x, y, scene.pixel(x, y), if (in) a_pixel else backdrop, 0);
    };
    return tally.report(scene.dl, "area", scene.took_us);
}
