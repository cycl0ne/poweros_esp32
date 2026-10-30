// SPDX-License-Identifier: MIT
//! V3DTest: the BCM2712's V3D brought up a step at a time.
//!
//!   V3DTest UP/S,CLEAR/S,TRIANGLE/S,OVERFLOW/S,FAULT/S,CLOCK/S,SMOOTH/S,CLIP/S,
//!           TEXTURE/S,MIP/S,FILTER/S,MODULATE/S,DEPTH/S,BLEND/S,AREA/S
//!
//! Alone it asks only what is safe with the core off: the firmware's clock
//! and the power manager's reset word. UP switches the core on and prints
//! what it says it is. CLEAR renders a frame with no
//! binning and no shader: every tile cleared and stored, then every pixel
//! checked from the CPU. TRIANGLE bins and renders one triangle of one
//! colour and prints what came out as a map of letters. OVERFLOW draws it
//! 2000 times with too little memory for the binner, which has to ask for
//! more. FAULT stores to a page that is not mapped, which the MMU has to
//! report. CLOCK times the same picture of many layers with the clock as slow
//! and as fast as it goes, which says what the firmware's figures do not:
//! whether it runs at what it is set to. SMOOTH to AREA draw with the fragment programs and the state
//! a pipeline has, each picture checked against the sum done here
//! (fragments.zig). The core stays on after any of them. Each step is written to the kernel's log before it
//! is taken, since a read of a register nothing answers halts the machine
//! and the log is what is left.

const std = @import("std");
const sdk = @import("sdk");
const v3d = @import("v3d");
const fragments = @import("fragments.zig");
const exec = sdk.exec;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "V3DTest";
const VERSION_STRING = "\x00$VER: V3DTest 0.2 (30.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "UP/S,CLEAR/S,TRIANGLE/S,OVERFLOW/S,FAULT/S,CLOCK/S,SMOOTH/S,CLIP/S,TEXTURE/S,MIP/S,FILTER/S,MODULATE/S,DEPTH/S,BLEND/S,AREA/S";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [15]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const gpu = v3d.Gpu.find(sys) orelse {
        _ = Printf(dl, "This board has no V3D\n", .{});
        return dos.RETURN_WARN;
    };
    _ = Printf(dl, "registers    hub %lx, core %lx, SMS %lx; interrupts %ld and %ld\n", .{
        @as(u64, gpu.hub), @as(u64, gpu.core), @as(u64, gpu.sms), @as(u64, gpu.irq_core), @as(u64, gpu.irq_hub),
    });
    showClock(dl, &gpu);
    step(sys, "reading the reset word");
    const held = gpu.resetWord();
    _ = Printf(dl, "reset word   %08lx: the core is %s\n", .{ @as(u64, held), @as([*:0]const u8, if (held & v3d.regs.PM_V3DRSTN != 0) "out of reset" else "in reset") });
    if (std.mem.allEqual(usize, &argv, 0)) return dos.RETURN_OK;

    step(sys, "switching it on");
    gpu.powerUp() catch |err| {
        _ = Printf(dl, "It did not come up: %s\n", .{@as([*:0]const u8, switch (err) {
            error.NoFirmware => "the firmware does not answer",
            error.NoSms => "its SMS does not get ready",
        })});
        return dos.RETURN_FAIL;
    };
    showClock(dl, &gpu);
    step(sys, "reading its identity");
    const ident = gpu.identify();
    _ = Printf(dl, "V3D          %ld.%ld, IP revision %ld, %ld core(s), TFU %ld, MMU %ld\n", .{
        @as(u64, ident.version),                @as(u64, ident.revision),               @as(u64, ident.ip_revision), @as(u64, ident.cores),
        @as(u64, @intFromBool(ident.with_tfu)), @as(u64, @intFromBool(ident.with_mmu)),
    });
    _ = Printf(dl, "core         %ld slices, %ld QPUs a slice, %ld TMUs, VPM %ld KiB\n", .{
        @as(u64, ident.slices), @as(u64, ident.qpus_per_slice), @as(u64, ident.tmus), @as(u64, ident.vpm_kib),
    });
    _ = Printf(dl, "addresses    %ld bits physical, %ld virtual\n", .{ @as(u64, ident.physical_bits), @as(u64, ident.virtual_bits) });
    if (std.mem.allEqual(usize, argv[1..], 0)) return dos.RETURN_OK;

    step(sys, "its page table");
    var space = v3d.Space.open(&gpu) orelse {
        _ = Printf(dl, "Its page table could not be set up\n", .{});
        return dos.RETURN_FAIL;
    };
    defer space.close();
    step(sys, "its interrupts");
    var engine: v3d.Engine = undefined;
    if (!engine.start(&gpu, &space, ident.virtual_bits)) {
        _ = Printf(dl, "No memory for the binner\n", .{});
        return dos.RETURN_FAIL;
    }
    defer engine.stop();
    if (argv[1] != 0) {
        const result = clearTest(sys, dl, &space, &engine);
        if (result != dos.RETURN_OK) return result;
    }
    if (argv[2] != 0) {
        const result = triangleTest(sys, dl, &space, &engine, .{});
        if (result != dos.RETURN_OK) return result;
    }
    if (argv[3] != 0) {
        const result = triangleTest(sys, dl, &space, &engine, .{ .triangles = 2000, .short_of_lists = true });
        if (result != dos.RETURN_OK) return result;
    }
    if (argv[4] != 0) {
        const result = triangleTest(sys, dl, &space, &engine, .{ .unmapped_image = true });
        if (result != dos.RETURN_OK) return result;
    }
    if (std.mem.allEqual(usize, argv[5..], 0)) return dos.RETURN_OK;
    var scene = fragments.Scene.open(dl, &space, &engine) orelse return noMemory(dl);
    defer scene.close();
    if (argv[5] != 0) {
        const result = fragments.clockTest(&scene, &gpu);
        if (result != dos.RETURN_OK) return result;
    }
    const tests = [_]*const fn (*fragments.Scene) i32{
        &fragments.smoothTest, &fragments.clipTest,     &fragments.textureTest, &fragments.mipTest,
        &fragments.filterTest, &fragments.modulateTest, &fragments.depthTest,   &fragments.blendTest,
        &fragments.areaTest,
    };
    var worst: i32 = dos.RETURN_OK;
    for (tests, argv[6..]) |run, asked| {
        if (asked == 0) continue;
        const result = run(&scene);
        if (result == dos.RETURN_FAIL) return result;
        worst = @max(worst, result);
    }
    return worst;
}

const test_width = 1280;
const test_height = 720;
const test_clear: u32 = 0xFF33_66CC;

/// The whole image cleared, with its bytes checked from the CPU.
fn clearTest(sys: *ExecBase, dl: *DosBase, space: *v3d.Space, engine: *v3d.Engine) i32 {
    const stride: u32 = test_width * 4;
    var image = space.alloc(stride * test_height) orelse return noMemory(dl);
    defer space.free(&image);
    var lists = space.alloc(4096) orelse return noMemory(dl);
    defer space.free(&lists);
    // What the store does not reach stays this, and shows.
    const pixels: [*]u32 = @ptrCast(@alignCast(image.cpu));
    @memset(pixels[0 .. test_width * test_height], 0xDEAD_BEEF);
    space.toGpu(&image);

    const frame = v3d.frame.Frame{
        .width = test_width,
        .height = test_height,
        .image = image.address,
        .stride = stride,
        .swap_rb = false,
        .clear = test_clear,
        .tile_lists = lists.address,
        .binned = false,
    };
    var tile_list = v3d.cl.List{ .at = lists.cpu, .address = lists.address };
    v3d.frame.writeTileList(&tile_list, &frame);
    var render_list = v3d.cl.List{ .at = lists.cpu + 1024, .address = lists.address + 1024 };
    v3d.frame.writeRender(&render_list, &frame, tile_list.address, tile_list.here());
    space.toGpu(&lists);
    if (!space.flush()) {
        _ = Printf(dl, "Its MMU does not flush\n", .{});
        return dos.RETURN_FAIL;
    }

    step(sys, "rendering");
    const began = sdk.hardware.systimer.uptimeUs();
    const finished = engine.render(render_list.address, render_list.here());
    const took = sdk.hardware.systimer.uptimeUs() - began;
    space.fromGpu(&image);
    if (finished != .done) return reportLost(dl, engine, finished);

    var wrong: u64 = 0;
    var first_wrong: u32 = 0;
    for (pixels[0 .. test_width * test_height]) |pixel| {
        if (pixel == test_clear) continue;
        if (wrong == 0) first_wrong = pixel;
        wrong += 1;
    }
    _ = Printf(dl, "cleared      %ldx%ld in %ld us, %ld interrupt(s); %ld pixels wrong\n", .{
        @as(u64, test_width), @as(u64, test_height), took, @as(u64, engine.core_interrupts), wrong,
    });
    if (wrong != 0) {
        _ = Printf(dl, "the first of them reads %08lx\n", .{@as(u64, first_wrong)});
        return dos.RETURN_WARN;
    }
    return dos.RETURN_OK;
}

const background: u32 = 0xFF20_1008;
/// Red, as the store writes it with no swap of red and blue.
const triangle_colour: u32 = 0xFF00_00FF;
const half_float_one: u32 = 0x3C00;
/// Stride and offsets of a vertex in memory: 8 words.
const vertex_bytes = 32;
const map_columns = 72;
const map_rows = 27;

const Vertex = extern struct {
    clip: [4]f32,
    screen_x: i32,
    screen_y: i32,
    depth: f32,
    one_over_w: f32,
};

/// A vertex at `x`, `y` of the image's -1 to 1: its position in 1/64 pixel
/// from the middle, with the middle where the viewport offset puts it.
fn vertexAt(x: f32, y: f32) Vertex {
    const half_width: f32 = test_width / 2;
    const half_height: f32 = test_height / 2;
    return .{
        .clip = .{ x, y, 0.0, 1.0 },
        .screen_x = @intFromFloat(x * half_width * 64.0),
        .screen_y = @intFromFloat(y * half_height * 64.0),
        .depth = 0.5,
        .one_over_w = 1.0,
    };
}

const TriangleTest = struct {
    /// All in the same place.
    triangles: u32 = 1,
    /// Only what the binner takes at its start, so that it has to ask.
    short_of_lists: bool = false,
    /// The store goes to a page nothing is mapped at.
    unmapped_image: bool = false,
};

/// Nothing is ever allocated this low, where the kernel lies.
const unmapped_address: u32 = 0x1000;

/// One triangle pointing to the bottom of the image, if y grows down as
/// facet's clip space has it. Binned, rendered, and every pixel counted.
fn triangleTest(sys: *ExecBase, dl: *DosBase, space: *v3d.Space, engine: *v3d.Engine, how: TriangleTest) i32 {
    const stride: u32 = test_width * 4;
    const tiles_x: u32 = (test_width + v3d.frame.tile_pixels - 1) / v3d.frame.tile_pixels;
    const tiles_y: u32 = (test_height + v3d.frame.tile_pixels - 1) / v3d.frame.tile_pixels;
    var image = space.alloc(stride * test_height) orelse return noMemory(dl);
    defer space.free(&image);
    var lists = space.alloc(16 * 1024) orelse return noMemory(dl);
    defer space.free(&lists);
    var objects = space.alloc(8 * 1024) orelse return noMemory(dl);
    defer space.free(&objects);
    // As Mesa has them: 128 bytes a tile, and the first blocks the binner
    // takes, with something over before it has to ask.
    const tile_list_bytes = ((tiles_x * tiles_y * 128 + 4095) & ~@as(u32, 4095)) + 8192;
    var tile_lists = space.alloc(if (how.short_of_lists) tile_list_bytes else tile_list_bytes + 512 * 1024) orelse return noMemory(dl);
    defer space.free(&tile_lists);
    var tile_state = space.alloc(tiles_x * tiles_y * 256) orelse return noMemory(dl);
    defer space.free(&tile_state);
    var vertex_block = space.alloc(how.triangles * 3 * vertex_bytes) orelse return noMemory(dl);
    defer space.free(&vertex_block);

    const pixels: [*]u32 = @ptrCast(@alignCast(image.cpu));
    @memset(pixels[0 .. test_width * test_height], 0xDEAD_BEEF);
    space.toGpu(&image);

    // Objects, each aligned as it must be: code to 8, the record to 32.
    const coordinate_at = 0;
    const vertex_at = 512;
    const fragment_at = 1024;
    const uniforms_at = 1536;
    const record_at = 2048;
    copyProgram(objects.cpu + coordinate_at, &v3d.qpu.coordinate_program);
    copyProgram(objects.cpu + vertex_at, &v3d.qpu.vertex_program);
    copyProgram(objects.cpu + fragment_at, v3d.qpu.flat_fragment.code);
    const uniforms: [*]u32 = @ptrCast(@alignCast(objects.cpu + uniforms_at));
    uniforms[0] = half_float_one;
    uniforms[1] = half_float_one << 16;
    const vertices: [*]Vertex = @ptrCast(@alignCast(vertex_block.cpu));
    for (0..how.triangles) |triangle| {
        vertices[3 * triangle] = vertexAt(0.0, 0.75);
        vertices[3 * triangle + 1] = vertexAt(-0.75, -0.75);
        vertices[3 * triangle + 2] = vertexAt(0.75, -0.75);
    }
    space.toGpu(&vertex_block);
    var record = v3d.cl.List{ .at = objects.cpu + record_at, .address = objects.address + record_at };
    v3d.cl.shaderRecord(&record, .{
        .fragment = objects.address + fragment_at,
        .fragment_uniforms = objects.address + uniforms_at,
        .vertex = objects.address + vertex_at,
        .vertex_uniforms = objects.address + uniforms_at,
        .coordinate = objects.address + coordinate_at,
        .coordinate_uniforms = objects.address + uniforms_at,
        .varyings = 0,
    });
    v3d.cl.attribute(&record, vertex_block.address, 4, 4, 0, vertex_bytes);
    v3d.cl.attribute(&record, vertex_block.address + 16, 4, 2, 4, vertex_bytes);
    space.toGpu(&objects);

    const frame = v3d.frame.Frame{
        .width = test_width,
        .height = test_height,
        .image = if (how.unmapped_image) unmapped_address else image.address,
        .stride = stride,
        .swap_rb = false,
        .clear = background,
        .tile_lists = tile_lists.address,
        .binned = true,
    };
    var tile_list = v3d.cl.List{ .at = lists.cpu, .address = lists.address };
    v3d.frame.writeTileList(&tile_list, &frame);
    var render_list = v3d.cl.List{ .at = lists.cpu + 1024, .address = lists.address + 1024 };
    v3d.frame.writeRender(&render_list, &frame, tile_list.address, tile_list.here());
    var bin_list = v3d.cl.List{ .at = lists.cpu + 8192, .address = lists.address + 8192 };
    v3d.frame.writeBin(&bin_list, &frame, objects.address + record_at, 2, 3 * how.triangles);
    space.toGpu(&lists);
    if (!space.flush()) {
        _ = Printf(dl, "Its MMU does not flush\n", .{});
        return dos.RETURN_FAIL;
    }

    step(sys, "binning");
    const began = sdk.hardware.systimer.uptimeUs();
    const binned = engine.bin(bin_list.address, bin_list.here(), &tile_lists, &tile_state);
    const bin_took = sdk.hardware.systimer.uptimeUs() - began;
    if (binned != .done) {
        _ = Printf(dl, "binning: list at %lx, now at %lx\n", .{ @as(u64, bin_list.here()), @as(u64, engine.gpu.coreRead(v3d.regs.CLE_CT0CA)) });
        return reportLost(dl, engine, binned);
    }
    step(sys, "rendering");
    // Timed apart: that line takes the console longer than the frame.
    const render_began = sdk.hardware.systimer.uptimeUs();
    const rendered = engine.render(render_list.address, render_list.here());
    const took = bin_took + sdk.hardware.systimer.uptimeUs() - render_began;
    space.fromGpu(&image);
    if (how.unmapped_image) {
        if (rendered != .fault) {
            _ = Printf(dl, "The MMU reported no fault\n", .{});
            return dos.RETURN_WARN;
        }
        // The address is one of the image's, wherever the store got to.
        _ = Printf(dl, "fault        status %02lx from id %lx at %lx, in the image from %lx\n", .{
            @as(u64, engine.last_fault.status), @as(u64, engine.last_fault.client), engine.last_fault.address, @as(u64, unmapped_address),
        });
        return dos.RETURN_OK;
    }
    if (rendered != .done) {
        _ = Printf(dl, "rendering: list at %lx, now at %lx\n", .{ @as(u64, render_list.here()), @as(u64, engine.gpu.coreRead(v3d.regs.CLE_CT1CA)) });
        return reportLost(dl, engine, rendered);
    }

    var coloured: u64 = 0;
    var cleared: u64 = 0;
    var other: u64 = 0;
    var first_other: u32 = 0;
    for (pixels[0 .. test_width * test_height]) |pixel| {
        if (pixel == triangle_colour) {
            coloured += 1;
        } else if (pixel == background) {
            cleared += 1;
        } else {
            if (other == 0) first_other = pixel;
            other += 1;
        }
    }
    _ = Printf(dl, "drawn        binned in %ld us, all in %ld us; %ld interrupt(s), binner given %ld block(s)\n", .{
        bin_took, took, @as(u64, engine.core_interrupts), @as(u64, engine.overflow_used),
    });
    _ = Printf(dl, "pixels       %ld of the triangle, %ld of the background, %ld of neither (%08lx)\n", .{ coloured, cleared, other, @as(u64, first_other) });
    if (how.short_of_lists and engine.overflow_used == 0) {
        _ = Printf(dl, "The binner never asked for memory\n", .{});
        return dos.RETURN_WARN;
    }
    var row: u32 = 0;
    while (row < map_rows) : (row += 1) {
        var line: [map_columns + 1:0]u8 = undefined;
        for (0..map_columns) |column| {
            const pixel = pixels[
                (row * test_height / map_rows + test_height / (2 * map_rows)) * test_width +
                    column * test_width / map_columns + test_width / (2 * map_columns)
            ];
            line[column] = if (pixel == triangle_colour) 'X' else if (pixel == background) '.' else '?';
        }
        line[map_columns] = 0;
        _ = Printf(dl, "%s\n", .{@as([*:0]const u8, &line)});
    }
    return if (other == 0 and coloured != 0) dos.RETURN_OK else dos.RETURN_WARN;
}

fn copyProgram(to: [*]u8, program: []const u64) void {
    const words: [*]u64 = @ptrCast(@alignCast(to));
    @memcpy(words[0..program.len], program);
}

fn noMemory(dl: *DosBase) i32 {
    _ = Printf(dl, "Not enough memory\n", .{});
    return dos.RETURN_FAIL;
}

fn reportLost(dl: *DosBase, engine: *const v3d.Engine, finished: v3d.Engine.Finished) i32 {
    switch (finished) {
        .fault => _ = Printf(dl, "MMU fault %02lx from client %lx at %lx\n", .{
            @as(u64, engine.last_fault.status), @as(u64, engine.last_fault.client), engine.last_fault.address,
        }),
        else => _ = Printf(dl, "It did not finish: %ld core interrupt(s), %ld hub\n", .{
            @as(u64, engine.core_interrupts), @as(u64, engine.hub_interrupts),
        }),
    }
    return dos.RETURN_FAIL;
}

fn step(sys: *ExecBase, what: [*:0]const u8) void {
    exec.kprintf(sys, "V3DTest: %s\n", .{what});
}

fn showClock(dl: *DosBase, gpu: *const v3d.Gpu) void {
    const clock = gpu.clock() orelse {
        _ = Printf(dl, "clock        the firmware does not answer\n", .{});
        return;
    };
    _ = Printf(dl, "clock        %s, %ld MHz, at most %ld\n", .{
        @as([*:0]const u8, if (clock.on) "on" else "off"), @as(u64, clock.hz / 1_000_000), @as(u64, clock.most_hz / 1_000_000),
    });
}
