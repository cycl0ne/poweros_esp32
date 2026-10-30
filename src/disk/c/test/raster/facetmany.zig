// SPDX-License-Identifier: MIT
//! FacetMany: a textured ball of many triangles, to see what a device does
//! with triangles where C:test/FacetCube sees what it does with pixels.
//!
//!   FacetMany TRIANGLES/N,WIDTH/N,HEIGHT/N,FRAMES/N,V3D/S
//!
//! TRIANGLES triangles (100000 if not given, rounded to what a grid of
//! squares gives), back faces culled, turned a little each frame, are drawn
//! FRAMES times (60 if not given) into a picture of WIDTH x HEIGHT (1920 x
//! 1080) that is not shown, one indexed draw a frame. It prints how long a
//! frame took, from its recording until its fence is signalled, on average
//! and at most, the triangles that makes a second, and how many pixels of the
//! last frame the ball covers: what tells a frame drawn from one that came
//! to nothing. With V3D it is all drawn on the device after the cores, a
//! CM5's GPU.

const std = @import("std");
const sdk = @import("sdk");
const scenes = @import("scenes.zig");
const scene = @import("facetscene.zig");
const facetgpu = @import("facetgpu.zig");
const dos = sdk.dos;
const exec = sdk.exec;
const facet = sdk.facet;
const intuition = sdk.intuition;
const sc = intuition.screens;
const timer = sdk.devices.timer;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TimerBase = timer.TimerBase;
const Printf = dos.stdio.Printf;
const Gpu = facetgpu.Gpu;
const Failure = facetgpu.Failure;

pub const COMMAND_NAME = "FacetMany";
const VERSION_STRING = "\x00$VER: FacetMany 1.0 (30.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TRIANGLES/N,WIDTH/N,HEIGHT/N,FRAMES/N,V3D/S";

const radius = 1.4;
/// How many times the pattern goes round the ball.
const wraps = 8;

/// The ball's buffers filled and bound: `rows` by twice as many columns of
/// squares, each two triangles.
const Ball = struct {
    vertices: *facet.Buffer,
    indices: *facet.Buffer,
    index_count: u32,

    fn make(gpu: *Gpu, rows: u32) Failure!Ball {
        const columns = rows * 2;
        const across = columns + 1;
        const vertex_count = (rows + 1) * across;
        const index_count = rows * columns * 6;
        const vertices, const vertex_bytes = try gpu.buffer(@as(u64, vertex_count) * @sizeOf(scene.Vertex), facet.BUFFER_USAGE_VERTEX_BUFFER);
        const indices, const index_bytes = try gpu.buffer(@as(u64, index_count) * @sizeOf(u32), facet.BUFFER_USAGE_INDEX_BUFFER);
        const vertex_at: [*]scene.Vertex = @ptrCast(@alignCast(vertex_bytes));
        const index_at: [*]u32 = @ptrCast(@alignCast(index_bytes));
        for (0..rows + 1) |row| {
            const v = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(rows));
            const down = v * std.math.pi;
            for (0..across) |column| {
                const u = @as(f32, @floatFromInt(column)) / @as(f32, @floatFromInt(columns));
                const round = u * 2 * std.math.pi;
                vertex_at[row * across + column] = .{
                    .position = .{ radius * @sin(down) * @cos(round), -radius * @cos(down), radius * @sin(down) * @sin(round) },
                    .uv = .{ u * wraps, v * wraps },
                };
            }
        }
        var at: usize = 0;
        for (0..rows) |row| for (0..columns) |column| {
            const corner: u32 = @intCast(row * across + column);
            const below: u32 = corner + across;
            index_at[at..][0..6].* = .{ corner, below, corner + 1, corner + 1, below, below + 1 };
            at += 6;
        };
        return .{ .vertices = vertices, .indices = indices, .index_count = index_count };
    }

    fn free(ball: *const Ball, gpu: *const Gpu) void {
        const device = gpu.device orelse return;
        _ = gpu.fb.DeviceWaitIdle(device);
        gpu.fb.DestroyBuffer(device, ball.vertices);
        gpu.fb.DestroyBuffer(device, ball.indices);
    }

    fn record(ball: *const Ball, gpu: *Gpu, framebuffer: *facet.Framebuffer, width: u32, height: u32, transform: *const [16]f32) Failure!void {
        const fb = gpu.fb;
        const recording = try gpu.begin();
        const area = facet.Rect2D{ .extent = .{ .width = width, .height = height } };
        const black = [2]facet.ClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } }, .{ .depth_stencil = .{ .depth = 1 } } };
        fb.CmdBeginRenderPass(recording, &.{ .render_pass = gpu.pass.?, .framebuffer = framebuffer, .render_area = area, .clear_value_count = 2, .clear_values = &black }, .@"inline");
        const viewport = facet.Viewport{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
        fb.CmdSetViewport(recording, 0, 1, @ptrCast(&viewport));
        fb.CmdSetScissor(recording, 0, 1, @ptrCast(&area));
        const offset: u64 = 0;
        fb.CmdBindVertexBuffers(recording, 0, 1, @ptrCast(&ball.vertices), @ptrCast(&offset));
        fb.CmdBindIndexBuffer(recording, ball.indices, 0, .uint32);
        fb.CmdBindDescriptorSets(recording, .graphics, gpu.layout.?, 0, 1, @ptrCast(&gpu.set), 0, null);
        fb.CmdBindPipeline(recording, .graphics, gpu.box.?);
        fb.CmdPushConstants(recording, gpu.layout.?, facet.SHADER_STAGE_VERTEX, 0, @sizeOf([16]f32), transform);
        fb.CmdDrawIndexed(recording, ball.index_count, 1, 0, 0, 0);
        fb.CmdEndRenderPass(recording);
    }
};

/// Microseconds from the timer's start.
fn now(tb: *TimerBase) u64 {
    var ev: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&ev);
    return ev.toTicks() * 1_000_000 / rate;
}

fn run(gpu: *Gpu, dl: *DosBase, tb: *TimerBase, rows: u32, width: u32, height: u32, frames: u32) Failure!void {
    const ball = try Ball.make(gpu, rows);
    defer ball.free(gpu);
    const picture = try gpu.picture(width, height);
    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    var total_us: u64 = 0;
    var most_us: u64 = 0;
    var drawn: u32 = 0;
    while (drawn < frames and dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) : (drawn += 1) {
        const transform = scenes.cubeTransform(@as(f32, @floatFromInt(drawn)) * 0.02, 4.5, aspect);
        const started = now(tb);
        try ball.record(gpu, picture.framebuffer, width, height, &transform);
        try gpu.submitAndWait(null, null);
        const took = now(tb) - started;
        total_us += took;
        most_us = @max(most_us, took);
    }
    if (drawn == 0) return;
    var covered: u64 = 0;
    for (0..height) |y| for (0..width) |x| {
        if (picture.color(x, y) & 0xFF_FFFF != 0) covered += 1;
    };
    const average = total_us / drawn;
    const triangles = @as(u64, ball.index_count / 3);
    _ = Printf(dl, "%lu triangles, %u frames of %ux%u: drawn in %lu.%03lu ms on average, %lu.%03lu ms at most; %lu thousand triangles a second; the last covers %lu pixels\n", .{
        triangles,
        drawn,
        width,
        height,
        average / 1000,
        average % 1000,
        most_us / 1000,
        most_us % 1000,
        if (average == 0) @as(u64, 0) else triangles * 1000 / average,
        covered,
    });
}

/// A number ReadArgs read, at least `least`, or `otherwise` when not given.
fn number(given: usize, otherwise: u32, least: u32) u32 {
    if (given == 0) return otherwise;
    return @intCast(@max(@as(i32, @intCast(least)), @as(*const i32, @ptrFromInt(given)).*));
}

fn failed(dl: *DosBase, gpu: *const Gpu, err: Failure) i32 {
    return say(dl, facetgpu.explain(gpu, err));
}

fn say(dl: *DosBase, text: [*:0]const u8) i32 {
    _ = Printf(dl, "%s\n", .{text});
    return dos.RETURN_FAIL;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [5]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const triangles = number(argv[0], 100_000, 4);
    const width = number(argv[1], 1920, 16);
    const height = number(argv[2], 1080, 16);
    const frames = number(argv[3], 60, 1);
    const on_gpu = argv[4] != 0;
    // Rows by twice as many columns, each square two triangles.
    const rows: u32 = @max(1, std.math.sqrt(triangles / 4));

    const facet_lib = sys.OpenLibrary(facet.FACETNAME, 1) orelse {
        _ = Printf(dl, "No %s\n", .{facet.FACETNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(facet_lib);
    const intuition_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, "No %s\n", .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(intuition_lib);
    const ib: *IntuitionBase = @ptrCast(intuition_lib);

    var timer_req: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &timer_req.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&timer_req.node);
    const tb: *TimerBase = @ptrCast(timer_req.node.device.?);

    const pattern_memory = sys.AllocVec(scenes.textureBytes(.rgba8888), exec.MEMF_ANY) orelse return say(dl, "Not enough memory");
    defer sys.FreeVec(pattern_memory);
    const pattern = scenes.patternTexture(.rgba8888, @ptrCast(pattern_memory));

    // Opened only for the display's format: the picture is not shown.
    var why: u32 = 0;
    const screen = ib.OpenScreenTagList(&[_]TagItem{
        .{ .tag = sc.SA_Quiet, .data = 1 },
        .{ .tag = sc.SA_ErrorCode, .data = @intFromPtr(&why) },
        .{},
    }) orelse {
        _ = Printf(dl, "No screen (%lu)\n", .{@as(u64, why)});
        return dos.RETURN_FAIL;
    };
    defer _ = ib.CloseScreen(screen);
    defer ib.ScreenToBack(screen);

    var gpu = Gpu{ .fb = @ptrCast(facet_lib), .ib = ib };
    defer gpu.down();
    gpu.up(COMMAND_NAME, on_gpu) catch |err| return failed(dl, &gpu, err);
    gpu.onScreen(screen) catch |err| return failed(dl, &gpu, err);
    gpu.prepare(false, &pattern) catch |err| return failed(dl, &gpu, err);
    run(&gpu, dl, tb, rows, width, height, frames) catch |err| return failed(dl, &gpu, err);
    return dos.RETURN_OK;
}
