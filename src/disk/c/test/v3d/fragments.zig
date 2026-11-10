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
        /// With `load` and an `area`: the tiles the area covers whole are
        /// not loaded, being cleared and wholly drawn over anyway.
        clear_inside: bool = false,
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
            .clear_inside = how.clear_inside,
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
        /// How it is mixed with what the tile holds, for `cfg.blend`. The
        /// default is `cl.Mixing`'s: one of the source and none of what is
        /// there, which is what no blending means.
        mixing: cl.Mixing = .{},
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
            .fragment_threads = how.fragment.threads,
            .center_w = how.fragment.center_w,
            .lock_scoreboard_on_first_thrsw = how.fragment.lock_scoreboard_on_first_thrsw,
            .writes_z = how.fragment.writes_z,
            .disable_ez = how.fragment.disable_ez,
        });
        const vertex_stride: u32 = @sizeOf(Vertex);
        cl.attribute(&list, vertices, 4, 4, 0, vertex_stride);
        cl.attribute(&list, vertices + 16, 4, 2, 4, vertex_stride);
        if (varyings > 0) cl.attribute(&list, vertices + 32, @min(varyings, 4), 0, @min(varyings, 4), vertex_stride);
        if (varyings > 4) cl.attribute(&list, vertices + 48, varyings - 4, 0, varyings - 4, vertex_stride);

        v3d.frame.writeDrawState(&scene.bin, &scene.frame, &.{
            .clip = how.clip,
            .cfg = how.cfg,
            .mixing = how.mixing,
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
        v3d.frame.writeTileList(&tile_list, &scene.frame, scene.frame.load);
        var inside: ?v3d.frame.TileList = null;
        if (scene.frame.clear_inside) {
            var plain = cl.List{ .at = scene.lists.cpu + 512, .address = scene.lists.address + 512 };
            v3d.frame.writeTileList(&plain, &scene.frame, false);
            inside = .{ .start = plain.address, .end = plain.here() };
        }
        var render = cl.List{ .at = scene.lists.cpu + 1024, .address = scene.lists.address + 1024 };
        v3d.frame.writeRender(&render, &scene.frame, .{ .start = tile_list.address, .end = tile_list.here() }, inside);
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

/// The hardware's blend factors, as `facet.BlendFactor` numbers them.
const src_alpha: u32 = @intFromEnum(sdk.facet.BlendFactor.src_alpha);
const one_minus_src_alpha: u32 = @intFromEnum(sdk.facet.BlendFactor.one_minus_src_alpha);

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

/// Many layers of a triangle, which is the QPUs' work rather than memory's,
/// timed with the clock set as slow and as fast as it goes: it should take
/// about as much longer as the clock is slower. Left as fast as it goes.
pub fn clockTest(scene: *Scene, gpu: *const v3d.Gpu) i32 {
    const clocks = gpu.clocks() orelse {
        _ = Printf(scene.dl, "The firmware does not say how fast the clock goes\n", .{});
        return dos.RETURN_FAIL;
    };
    const corners = [3]Vertex{
        at(0, 0.8, 0.5, 1, &.{ 1, 0, 0, 1 }),
        at(-0.8, -0.8, 0.5, 2, &.{ 0, 1, 0, 1 }),
        at(0.8, -0.8, 0.5, 4, &.{ 0, 0, 1, 1 }),
    };
    for ([_]u32{ clocks.least_hz, clocks.most_hz, clocks.least_hz, clocks.most_hz }) |hz| {
        if (!gpu.runAt(hz)) {
            _ = Printf(scene.dl, "The firmware does not set the clock\n", .{});
            return dos.RETURN_FAIL;
        }
        var total: u64 = 0;
        for (0..4) |_| {
            scene.begin(.{});
            for (0..30) |_| scene.draw(.{ .fragment = qpu.color_fragment, .vertices = &corners });
            if (!scene.finish()) return dos.RETURN_FAIL;
            total += scene.took_us;
        }
        _ = Printf(scene.dl, "clock        set to %ld MHz, a picture of 30 layers takes %ld us\n", .{ @as(u64, hz / 1_000_000), total / 4 });
    }
    return dos.RETURN_OK;
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
    const layout = tiling.layoutOf(4, across, down, 1, levels, false);
    const block = scene.space.alloc(layout.bytes) orelse return null;
    if (!scene.space.flush()) return null;
    var picture = Picture{ .block = block, .layout = layout };
    tiling.writeTextureState(&picture.state, &layout, .rgba, tiling.own_picks, block.address, 0, levels - 1, 1, 0);
    return picture;
}

/// A texel that says where it is.
fn placeTexel(level: u32, x: u32, y: u32) u32 {
    return (x & 0xFF) | (y & 0xFF) << 8 | ((level * 16) | (x >> 8 & 3) | (y >> 8 & 3) << 2) << 16 | 0xFF00_0000;
}

/// The two uniforms of a program that samples: its state and a sampler's,
/// placed in the frame. `filter` both ways, `wrap` on every axis, the rest
/// as a fixed form has it.
fn sampling(scene: *Scene, picture: *const Picture, filter: tiling.Filter, wrap: tiling.Wrap) [2]u32 {
    return samplingBy(scene, picture, .{ .mag = filter, .min = filter, .wrap = @splat(wrap) });
}

/// The same, through `state`.
fn samplingBy(scene: *Scene, picture: *const Picture, state: tiling.SamplerState) [2]u32 {
    const texture_cpu, const texture_at = scene.place(tiling.texture_state_bytes, tiling.texture_state_alignment);
    @memcpy(texture_cpu[0..tiling.texture_state_bytes], &picture.state);
    const sampler_cpu, const sampler_at = scene.place(tiling.sampler_state_bytes, tiling.sampler_state_alignment);
    tiling.writeSamplerState(sampler_cpu[0..tiling.sampler_state_bytes], state);
    return .{ tiling.parameter0(texture_at), tiling.parameter1(sampler_at, false) };
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

/// The texel `at_texel` reads, as Vulkan's address modes have it (the
/// spec's "Wrapping Operation"); null for the border.
fn wrapped(at_texel: i32, size: i32, wrap: tiling.Wrap) ?u32 {
    return @intCast(switch (wrap) {
        .repeat => @mod(at_texel, size),
        .clamp => @min(@max(at_texel, 0), size - 1),
        // Every other copy turned round: `(size - 1) - mirror((i mod
        // 2size) - size)`, which is `i mod 2size` folded back at size.
        .mirror => mirror: {
            const folded = @mod(at_texel, 2 * size);
            break :mirror if (folded < size) folded else 2 * size - 1 - folded;
        },
        // `clamp(mirror(i), 0, size - 1)`, mirror(i) being i, or -(1 + i)
        // below 0.
        .mirror_once => @min(if (at_texel >= 0) at_texel else -(1 + at_texel), size - 1),
        .border => if (at_texel < 0 or at_texel >= size) return null else at_texel,
    });
}

/// A small texture past its edges, and between its texels: each filter and
/// each of the TMU's five wraps against the sum done here, the border
/// opaque white. Until 1.140 the wraps were repeat and clamp alone.
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
    for ([_]tiling.Filter{ .nearest, .bilinear }) |filter| for ([_]tiling.Wrap{ .repeat, .clamp, .mirror, .mirror_once, .border }) |wrap| {
        var corners: [6]Vertex = undefined;
        rectangle(&corners, 0, 0, @floatFromInt(drawn), @floatFromInt(drawn), 0.5, Across{ .from = -1, .to = 2 });
        scene.begin(.{});
        const uniforms = samplingBy(scene, &picture, .{ .mag = filter, .min = filter, .wrap = @splat(wrap), .border = .opaque_white });
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
            @as([*:0]const u8, @tagName(wrap)),
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
        const x = wrapped(@intFromFloat(@floor(u)), size, wrap) orelse return 0xFFFF_FFFF;
        const y = wrapped(@intFromFloat(@floor(v)), size, wrap) orelse return 0xFFFF_FFFF;
        return 0xFF00_0000 | x * 16 | (y * 16) << 8;
    }
    const left = @floor(u - 0.5);
    const top = @floor(v - 0.5);
    const across = u - 0.5 - left;
    const down = v - 0.5 - top;
    const x0 = wrapped(@as(i32, @intFromFloat(left)), size, wrap);
    const x1 = wrapped(@as(i32, @intFromFloat(left)) + 1, size, wrap);
    const y0 = wrapped(@as(i32, @intFromFloat(top)), size, wrap);
    const y1 = wrapped(@as(i32, @intFromFloat(top)) + 1, size, wrap);
    // The four texels, a border one white, mixed channel by channel.
    const corners = [4][4]f32{ texelOf(x0, y0), texelOf(x1, y0), texelOf(x0, y1), texelOf(x1, y1) };
    const weights = [4]f32{ (1 - across) * (1 - down), across * (1 - down), (1 - across) * down, across * down };
    var mixed: [4]f32 = @splat(0);
    for (corners, weights) |corner, weight| {
        for (&mixed, corner) |*into, channel| into.* += channel * weight;
    }
    return rgba(mixed[0], mixed[1], mixed[2], mixed[3]);
}

/// A texel of `filterTest`'s texture as four channels, 0 to 1: red its
/// column and green its row, or opaque white for the border.
fn texelOf(x: ?u32, y: ?u32) [4]f32 {
    const column = x orelse return @splat(1);
    const row = y orelse return @splat(1);
    return .{ @as(f32, @floatFromInt(column * 16)) / 255, @as(f32, @floatFromInt(row * 16)) / 255, 0, 1 };
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
    // Half the red over what is there, which is what `want` below works out:
    // without the factors said, the hardware takes all of the source and
    // none of the destination, and blending is switched on to no effect.
    const over = cl.Mixing{ .src_color = src_alpha, .dst_color = one_minus_src_alpha, .src_alpha = src_alpha, .dst_alpha = one_minus_src_alpha };
    scene.draw(.{ .fragment = qpu.flat_fragment, .uniforms = &half_red, .vertices = &corners, .cfg = .{ .blend = true }, .mixing = over });
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

/// The same, with the tiles the area covers whole left unloaded: they are
/// cleared by the renderer and drawn over, so nothing of the image is wanted
/// under them. The area is on a tile's edge to the left and top and ragged
/// to the right and bottom, so that both kinds of tile are drawn - 20 of the
/// 30 here are covered whole, the other 10 must keep what lies outside.
pub fn insideTest(scene: *Scene) i32 {
    var corners: [6]Vertex = undefined;
    scene.begin(.{});
    if (!scene.finish()) return dos.RETURN_FAIL;
    rectangle(&corners, 0, 0, width, height, 0.5, Nothing{});
    const inside = Area{ .left = 128, .top = 128, .right = 500, .bottom = 440 };
    scene.begin(.{ .clear = 0xFF00_0000, .load = true, .area = inside, .clear_inside = true });
    scene.draw(.{ .fragment = qpu.flat_fragment, .uniforms = &a_colour, .vertices = &corners, .clip = inside });
    if (!scene.finish()) return dos.RETURN_FAIL;
    var tally = Tally{};
    for (0..height) |row| for (0..width) |column| {
        const x: u32 = @intCast(column);
        const y: u32 = @intCast(row);
        const in = x >= inside.left and x < inside.right and y >= inside.top and y < inside.bottom;
        tally.check(x, y, scene.pixel(x, y), if (in) a_pixel else backdrop, 0);
    };
    return tally.report(scene.dl, "inside", scene.took_us);
}

// --- what the back end compiles ----------------------------------------------

const compile = v3d.compile;
const ir = sdk.facet.ir;

/// The colour the vertices carry, as a graph: the module facet's own
/// emitter writes for it compiles to `qpu.color_fragment` word for word
/// (the host test says so), so this draw is the whole path from a
/// program's SPIR-V to a picture.
const Interpolated = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.input(0, .f32x4));
    }
});

/// A colour of its own, which the draw hands over as four uniforms: the
/// first generated program whose words no hand-written one matches.
const OwnColour = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.constant(.{ 0.25, 0.5, 0.75, 1 }));
    }
});

/// The colour the vertices carry, dimmed by a fifth varying they carry
/// beside it: five varyings, a vector times a scalar, and a scalar that
/// every part of the product reads and none may write over.
const Dimmed = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.scale(b.input(0, .f32x4), b.input(1, .f32x1)));
    }
});

/// A texture sampled at the coordinate the vertices carry, drawn as it
/// comes: `qpu.texture_code`'s shape, and the first generated program that
/// writes the TMU and reads it back. The TMU hands over two words of two
/// half-floats each, which is the form the tile buffer takes, so nothing
/// here touches the texel.
const Textured = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.sample(0, 0, b.input(0, .f32x2)));
    }
});

/// That texel times the colour the vertices carry beside it, which is
/// `qpu.texture_color_fragment` word for word: the multiply is where a
/// half of a word can be read as a float, so each product reads one.
const Modulated = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.mul(b.sample(0, 0, b.input(0, .f32x2)), b.input(1, .f32x4)));
    }
});

/// A module compiled and made ready to draw with. The code is in
/// `work.code` and lives until the next `compile`, which is long enough:
/// `Scene.draw` copies it into the V3D's objects as it records the draw.
///
/// `tmu` is what `sampling` answered for the draw, for a program that
/// samples: the back end says where in the stream the TMU's two
/// configuration parameters go, and only a draw with a texture bound
/// knows what they are. A program that wants them where the caller has
/// none is not drawn with a stream it cannot read - it is refused here,
/// as a program the back end would not compile is.
fn compiled(back: Back, work: *compile.Work, words: []const u32, stream: *[compile.most_uniforms]u32, tmu: ?[2]u32) ?struct { qpu.Fragment, []const u32 } {
    const code = switch (back) {
        .plan => compile.compile(work, words),
        .mesa => |sys| compile.compileThroughMesa(work, words, v3d.heap.of(sys), .{}),
    } catch return null;
    for (code.stream(), 0..) |word, k| stream[k] = switch (word) {
        .float => |each| @bitCast(each),
        // The texture's state, as the first `wrtmuc` takes it, and the
        // sampler's as the second does: by the word's tag and not by
        // where it sits, because the order is the back end's to pick.
        .texture => (tmu orelse return null)[0],
        .sampler => (tmu orelse return null)[1],
        // No scene here pushes constants or binds a uniform buffer: the
        // library's draws are where a program that reads them is held to
        // the cores (FacetBoth). Nor is a fragment program's stream ever
        // of the viewport or the first vertex, which a vertex program's
        // alone is (since 1.192), nor has one a spill buffer (the
        // library's pipelines make it), nor does one ask a view's sizes,
        // which the library's draws measure (since 1.181).
        .push, .ubo, .ssbo, .viewport, .first_vertex, .spill_offset, .spill_size_per_thread, .texture_size => return null,
    };
    return .{
        .{
            .code = code.words,
            .varyings = code.varyings,
            .uniforms = code.uniform_count,
            .threads = code.threads,
            .center_w = code.center_w,
            .lock_scoreboard_on_first_thrsw = code.lock_scoreboard_on_first_thrsw,
            .writes_z = code.writes_z,
            .disable_ez = code.disable_ez,
        },
        stream[0..code.uniform_count],
    };
}

/// Which back end compiles: the plan's, which `compile.compile` is, or the
/// one ported from Mesa (`compile.compileThroughMesa`), whose working
/// memory is the task's.
pub const Back = union(enum) {
    plan,
    mesa: *ExecBase,

    /// What a picture is called in the report: the plan's are
    /// "generated", as they were before there was a second back end.
    fn named(back: Back, comptime what: []const u8) [*:0]const u8 {
        return switch (back) {
            .plan => "generated " ++ what,
            .mesa => "mesa " ++ what,
        };
    }
};

/// What Mesa's back end made, said before it is run: the host tests pin
/// its words, and a board that compiled something else says so here
/// rather than by a renderer that does not finish.
fn said(scene: *const Scene, back: Back, comptime what: []const u8, fragment: qpu.Fragment, uniforms: []const u32) void {
    if (back == .plan) return;
    _ = Printf(scene.dl, "%s: %ld instructions, %ld threads, %ld uniforms, centre W %ld, scoreboard on the first switch %ld\n", .{
        back.named(what),
        @as(u64, fragment.code.len),
        @as(u64, fragment.threads),
        @as(u64, uniforms.len),
        @as(u64, @intFromBool(fragment.center_w)),
        @as(u64, @intFromBool(fragment.lock_scoreboard_on_first_thrsw)),
    });
}

/// Where two programs of the same length first differ, or null where they
/// are the same program word for word.
fn differingAt(made: []const u64, want: []const u64) ?u32 {
    for (made, want, 0..) |one, other, which| if (one != other) return @intCast(which);
    return null;
}

/// Five fragment programs compiled from their SPIR-V and drawn with, each
/// picture checked against the arithmetic worked out here. The last two
/// sample a texture, and what they read the TMU with is the stream the
/// back end laid out with the draw's two parameters written into it. This
/// is the first thing the QPUs run that nobody wrote by hand, and it is a
/// command of its own rather than a pipeline on purpose: a program that
/// hangs the renderer here costs a reboot, and one that hangs it inside
/// the library costs the display.
///
/// With `back` Mesa's, the same five pictures from the code Mesa's back
/// end makes of the same words: the host tests pin that code, so what is
/// held to the programs written by hand here is held to them only for
/// the plan's, and the pictures are checked the same for both.
pub fn generatedTest(scene: *Scene, sys: *ExecBase, back: Back) i32 {
    const memory = sys.AllocVec(@sizeOf(compile.Work), exec.MEMF_CLEAR) orelse {
        _ = Printf(scene.dl, "No memory for the compiler\n", .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const work: *compile.Work = @ptrCast(@alignCast(memory));
    var stream: [compile.most_uniforms]u32 = @splat(0);
    var worst: i32 = dos.RETURN_OK;

    // The interpolated colour, over the same triangle `smoothTest` draws:
    // three colours mixed as w has them.
    {
        const fragment, const uniforms = compiled(back, work, Interpolated.words, &stream, null) orelse {
            _ = Printf(scene.dl, "%s: the back end would not compile it\n", .{back.named("smooth")});
            return dos.RETURN_FAIL;
        };
        said(scene, back, "smooth", fragment, uniforms);
        if (back == .plan and fragment.code.len != qpu.color_fragment.code.len) {
            _ = Printf(scene.dl, "generated smooth: %ld instructions, not the %ld of the one written by hand\n", .{ @as(u64, fragment.code.len), @as(u64, qpu.color_fragment.code.len) });
            return dos.RETURN_FAIL;
        }
        const corners = [3]Vertex{
            at(0, 0.8, 0.5, 1, &.{ 1, 0, 0, 1 }),
            at(-0.8, -0.8, 0.5, 2, &.{ 0, 1, 0, 1 }),
            at(0.8, -0.8, 0.5, 4, &.{ 0, 0, 1, 1 }),
        };
        scene.begin(.{});
        scene.draw(.{ .fragment = fragment, .uniforms = uniforms, .vertices = &corners });
        if (!scene.finish()) return dos.RETURN_FAIL;
        var tally = Tally{};
        for (0..height) |row| for (0..width) |column| {
            const x: u32 = @intCast(column);
            const y: u32 = @intCast(row);
            const each = shares(&corners, x, y) orelse continue;
            const inside = each[0] > edge_margin and each[1] > edge_margin and each[2] > edge_margin;
            const outside = each[0] < -edge_margin or each[1] < -edge_margin or each[2] < -edge_margin;
            if (inside) {
                tally.check(x, y, scene.pixel(x, y), rgba(@floatCast(each[0]), @floatCast(each[1]), @floatCast(each[2]), 1), 2);
            } else if (outside) {
                tally.check(x, y, scene.pixel(x, y), backdrop, 0);
            }
        };
        worst = @max(worst, tally.report(scene.dl, back.named("smooth"), scene.took_us));
    }

    // A colour of its own: four uniforms read, packed and written out.
    {
        const fragment, const uniforms = compiled(back, work, OwnColour.words, &stream, null) orelse {
            _ = Printf(scene.dl, "%s: the back end would not compile it\n", .{back.named("flat")});
            return dos.RETURN_FAIL;
        };
        said(scene, back, "flat", fragment, uniforms);
        // Mesa's packs the four into halves as it compiles (opt.zig's
        // constant ALU), so it reads fewer.
        if (back == .plan and uniforms.len != 4) {
            _ = Printf(scene.dl, "generated flat: %ld uniforms, not four\n", .{@as(u64, uniforms.len)});
            return dos.RETURN_FAIL;
        }
        var quad: [6]Vertex = undefined;
        // In pixels, as `rectangle` wants them: the middle half of the
        // image, which is -0.5 to 0.5 of it where the check below looks.
        rectangle(&quad, 320, 180, 960, 540, 0.5, Nothing{});
        scene.begin(.{});
        scene.draw(.{ .fragment = fragment, .uniforms = uniforms, .vertices = &quad });
        if (!scene.finish()) return dos.RETURN_FAIL;
        const want = rgba(0.25, 0.5, 0.75, 1);
        var tally = Tally{};
        for (0..height) |row| for (0..width) |column| {
            const x: u32 = @intCast(column);
            const y: u32 = @intCast(row);
            const across = acrossAt(@as(f32, @floatFromInt(x)) + 0.5);
            const down = downAt(@as(f32, @floatFromInt(y)) + 0.5);
            // A margin round the edges, where a pixel is half covered.
            const inside = across > -0.49 and across < 0.49 and down > -0.49 and down < 0.49;
            const outside = across < -0.51 or across > 0.51 or down < -0.51 or down > 0.51;
            if (inside) {
                tally.check(x, y, scene.pixel(x, y), want, 2);
            } else if (outside) {
                tally.check(x, y, scene.pixel(x, y), backdrop, 0);
            }
        };
        worst = @max(worst, tally.report(scene.dl, back.named("flat"), scene.took_us));
    }

    // A vector times a scalar: five varyings, and the light each corner
    // carries dimming the colour it carries.
    {
        const fragment, const uniforms = compiled(back, work, Dimmed.words, &stream, null) orelse {
            _ = Printf(scene.dl, "%s: the back end would not compile it\n", .{back.named("scaled")});
            return dos.RETURN_FAIL;
        };
        said(scene, back, "scaled", fragment, uniforms);
        if (fragment.varyings != 5) {
            _ = Printf(scene.dl, "%s: %ld varyings, not five\n", .{ back.named("scaled"), @as(u64, fragment.varyings) });
            return dos.RETURN_FAIL;
        }
        const corners = [3]Vertex{
            at(0, 0.8, 0.5, 1, &.{ 1, 1, 1, 1, 1 }),
            at(-0.8, -0.8, 0.5, 1, &.{ 1, 1, 1, 1, 0.5 }),
            at(0.8, -0.8, 0.5, 1, &.{ 1, 1, 1, 1, 0 }),
        };
        scene.begin(.{});
        scene.draw(.{ .fragment = fragment, .uniforms = uniforms, .vertices = &corners });
        if (!scene.finish()) return dos.RETURN_FAIL;
        var tally = Tally{};
        for (0..height) |row| for (0..width) |column| {
            const x: u32 = @intCast(column);
            const y: u32 = @intCast(row);
            const each = shares(&corners, x, y) orelse continue;
            const inside = each[0] > edge_margin and each[1] > edge_margin and each[2] > edge_margin;
            const outside = each[0] < -edge_margin or each[1] < -edge_margin or each[2] < -edge_margin;
            if (inside) {
                const light: f32 = @floatCast(each[0] * 1 + each[1] * 0.5 + each[2] * 0);
                tally.check(x, y, scene.pixel(x, y), rgba(light, light, light, light), 2);
            } else if (outside) {
                tally.check(x, y, scene.pixel(x, y), backdrop, 0);
            }
        };
        worst = @max(worst, tally.report(scene.dl, back.named("scaled"), scene.took_us));
    }

    // A texture drawn one texel to a pixel, as `textureTest` draws it with
    // the program written by hand: every texel says where it was put, so
    // the picture is the TMU's answer against where it went in. Nothing
    // multiplies the texel, so it goes to the tile buffer as the two words
    // it came back as, and the pixels are exact.
    {
        const side: u32 = 256;
        var picture = makePicture(scene, side, side, 1) orelse return dos.RETURN_FAIL;
        defer scene.space.free(&picture.block);
        for (0..side) |y| for (0..side) |x| picture.put(0, @intCast(x), @intCast(y), placeTexel(0, @intCast(x), @intCast(y)));
        scene.space.toGpu(&picture.block);
        var corners: [6]Vertex = undefined;
        rectangle(&corners, 0, 0, @floatFromInt(side), @floatFromInt(side), 0.5, Across{});
        // The frame is begun first: `sampling` places the texture's state
        // and the sampler's in it, and hands back the two words the stream
        // wants, which is what `compiled` has been given them for.
        scene.begin(.{});
        const tmu = sampling(scene, &picture, .nearest, .repeat);
        const fragment, const uniforms = compiled(back, work, Textured.words, &stream, tmu) orelse {
            _ = Printf(scene.dl, "%s: the back end would not compile it\n", .{back.named("textured")});
            return dos.RETURN_FAIL;
        };
        said(scene, back, "textured", fragment, uniforms);
        // The same instructions as the hand-written program, in the same
        // places: only the two registers the texel comes back in differ,
        // which is rf6 and rf7 here because that is what the varyings left
        // free. The host test holds the words themselves to it.
        if (back == .plan and fragment.code.len != qpu.texture_fragment.code.len) {
            _ = Printf(scene.dl, "generated textured: %ld instructions, not the %ld of the one written by hand\n", .{ @as(u64, fragment.code.len), @as(u64, qpu.texture_fragment.code.len) });
            return dos.RETURN_FAIL;
        }
        // Two varyings for the coordinate, and the TMU's two words and
        // nothing else in the stream.
        if (fragment.varyings != 2 or uniforms.len != 2) {
            _ = Printf(scene.dl, "%s: %ld varyings and %ld uniforms, not two and two\n", .{ back.named("textured"), @as(u64, fragment.varyings), @as(u64, uniforms.len) });
            return dos.RETURN_FAIL;
        }
        scene.draw(.{ .fragment = fragment, .uniforms = uniforms, .vertices = &corners });
        if (!scene.finish()) return dos.RETURN_FAIL;
        var tally = Tally{};
        for (0..side) |row| for (0..side) |column| {
            const x: u32 = @intCast(column);
            const y: u32 = @intCast(row);
            tally.check(x, y, scene.pixel(x, y), placeTexel(0, x, y), 0);
        };
        worst = @max(worst, tally.report(scene.dl, back.named("textured"), scene.took_us));
    }

    // That texel times the colour the vertices carry, over the geometry
    // `modulateTest` draws: the same texture, the same colour in the same
    // varyings, and the same sum here, because the code is the same code.
    {
        const side: u32 = 64;
        var picture = makePicture(scene, side, side, 1) orelse return dos.RETURN_FAIL;
        defer scene.space.free(&picture.block);
        for (0..side) |y| for (0..side) |x| picture.put(0, @intCast(x), @intCast(y), 0xFF80_0000 | @as(u32, @intCast(x * 4)) | @as(u32, @intCast(y * 4)) << 8);
        scene.space.toGpu(&picture.block);
        // What `modulateTest` carries: the coordinate, then the colour.
        const Carry = struct {
            fn of(_: @This(), x: f32, y: f32) [6]f32 {
                return .{ x, y, 0.5, 1, 0.25, 0.75 };
            }
        };
        var corners: [6]Vertex = undefined;
        rectangle(&corners, 0, 0, @floatFromInt(side), @floatFromInt(side), 0.5, Carry{});
        scene.begin(.{});
        const tmu = sampling(scene, &picture, .nearest, .repeat);
        const fragment, const uniforms = compiled(back, work, Modulated.words, &stream, tmu) orelse {
            _ = Printf(scene.dl, "%s: the back end would not compile it\n", .{back.named("modulated")});
            return dos.RETURN_FAIL;
        };
        said(scene, back, "modulated", fragment, uniforms);
        // This one is the hand-written program word for word, so it is
        // held to it before it is run: the host test says the same, and a
        // board that disagrees with the host is what this is here to say.
        // A wrong instruction hangs the renderer, so it is said before the
        // draw and not after it.
        if (back == .plan and fragment.code.len != qpu.texture_color_fragment.code.len) {
            _ = Printf(scene.dl, "generated modulated: %ld instructions, not the %ld of the one written by hand\n", .{ @as(u64, fragment.code.len), @as(u64, qpu.texture_color_fragment.code.len) });
            return dos.RETURN_FAIL;
        }
        const differing = if (back == .plan) differingAt(fragment.code, qpu.texture_color_fragment.code) else null;
        if (differing) |which| {
            _ = Printf(scene.dl, "generated modulated: instruction %ld is %016lx, not the %016lx of the one written by hand\n", .{ @as(u64, which), fragment.code[which], qpu.texture_color_fragment.code[which] });
            return dos.RETURN_FAIL;
        }
        if (fragment.varyings != 6 or uniforms.len != 2) {
            _ = Printf(scene.dl, "%s: %ld varyings and %ld uniforms, not six and two\n", .{ back.named("modulated"), @as(u64, fragment.varyings), @as(u64, uniforms.len) });
            return dos.RETURN_FAIL;
        }
        scene.draw(.{ .fragment = fragment, .uniforms = uniforms, .vertices = &corners });
        if (!scene.finish()) return dos.RETURN_FAIL;
        var tally = Tally{};
        for (0..side) |row| for (0..side) |column| {
            const x: u32 = @intCast(column);
            const y: u32 = @intCast(row);
            // The texel's red times 0.5 and its green times 1, its blue
            // 0x80 times 0.25, and the alpha 1 times 0.75.
            const want = rgba(@as(f32, @floatFromInt(x * 4)) / 255 * 0.5, @as(f32, @floatFromInt(y * 4)) / 255, 128.0 / 255.0 * 0.25, 0.75);
            tally.check(x, y, scene.pixel(x, y), want, 2);
        };
        worst = @max(worst, tally.report(scene.dl, back.named("modulated"), scene.took_us));
    }

    return worst;
}
