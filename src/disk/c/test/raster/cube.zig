// SPDX-License-Identifier: MIT
//! Cube: a textured cube turning in front of its backdrop, drawn by
//! facet.library's rasterizer core into an 800 x 600 view in the middle of
//! a screen of its own. Built against the SDK and the core itself, which
//! is compiled in.
//!
//!   Cube FRAMES/N,NEAREST/S
//!
//! Each frame is drawn into one of the screen's two buffers while the
//! other is shown, and shown from the display's next frame on: FRAMES of
//! them (600 if not given), or until Ctrl-C. Where the display's memory
//! has no room for the second buffer, each frame is drawn into the one
//! that is shown. The texture is 256 x 256 and
//! has its levels; it is filtered bilinear, or with NEAREST the nearest
//! texel is taken. At the end the time a frame took to draw is printed, on
//! average and at most, and how many frames were shown a second - no more
//! than the display's rate, as a buffer is shown from a frame on.
//!
//! The screen and its second buffer each take a picture of the display's
//! memory, as does every other screen open.

const sdk = @import("sdk");
const raster = @import("raster");
const board = @import("board.zig");
const scenes = @import("scenes.zig");
const dos = sdk.dos;
const exec = sdk.exec;
const rtg = sdk.rtg;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const sc = intuition.screens;
const timer = sdk.devices.timer;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TimerBase = timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Cube";
const VERSION_STRING = "\x00$VER: Cube 1.1 (19.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FRAMES/N,NEAREST/S";

/// RefreshRect came with this revision.
const rtg_revision = 5;

const view_width = 800;
const view_height = 600;

const Backdrop = raster.Pipeline(.{ .color = .smooth, .cull = .none, .depth = .less });

fn Box(comptime filter: raster.Filter) type {
    return raster.Pipeline(.{ .color = .texture, .sampling = .{ .filter = filter }, .front = .clockwise, .depth = .less });
}

/// One of the screen's buffers, and the target drawing into it.
const Buffer = struct {
    shown: *sc.ScreenBuffer,
    system: board.System,
    target: raster.Target,
};

/// What a run took.
const Run = struct {
    frames: u32 = 0,
    drawn_us: u64 = 0,
    most_us: u64 = 0,
    refused: u32 = 0,
    stats: raster.Stats = .{},
    done: raster.Finished = .{},
};

/// The cube turning, `frames` of it, drawn into the buffers in turn and
/// each shown when done - or, with one buffer, drawn where it is shown.
fn spin(
    comptime filter: raster.Filter,
    dl: *DosBase,
    ib: *IntuitionBase,
    tb: *TimerBase,
    screen: *intuition.Screen,
    buffers: []Buffer,
    texture: *const raster.Texture,
    frames: u32,
) ?Run {
    const Kind = Box(filter);
    const area = buffers[0].target.area;
    const viewport = raster.Viewport{ .x = @floatFromInt(area.x), .y = @floatFromInt(area.y), .width = view_width, .height = view_height };
    const backdrop = Backdrop{ .viewport = viewport };
    const backdrop_vertices = scenes.backdrop(Backdrop.Vertex);
    const vertices = scenes.cube(Kind.Vertex);
    var box = Kind{ .viewport = viewport, .texture = texture };
    var run = Run{};
    var drawing: usize = buffers.len - 1;
    while (run.frames < frames and dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) {
        const angle = @as(f32, @floatFromInt(run.frames)) * 0.02;
        box.transform = scenes.cubeTransform(angle, 4.5, @as(f32, view_width) / view_height);
        const target = &buffers[drawing].target;
        const started = board.now(tb);
        target.begin();
        raster.draw(target, &backdrop, &backdrop_vertices, &scenes.quad_indices) catch return null;
        raster.draw(target, &box, &vertices, &scenes.cube_indices) catch return null;
        run.stats = target.stats;
        run.done = target.finish();
        const took = board.now(tb) - started;
        run.drawn_us += took;
        run.most_us = @max(run.most_us, took);
        if (buffers.len == 2) {
            while (!ib.ChangeScreenBuffer(screen, buffers[drawing].shown)) {
                run.refused += 1;
                dl.Delay(1);
            }
            drawing ^= 1;
        }
        run.frames += 1;
    }
    return run;
}

fn attr(ib: *IntuitionBase, screen: *intuition.Screen, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetScreenAttrs(screen, &ask);
    return value;
}

fn formatOf(bitmap: *const rtg.RtgBitMap) ?raster.Format {
    return switch (bitmap.format) {
        .bgra32 => .bgra32,
        .rgba32 => .rgba32,
        else => null,
    };
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
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const frames: u32 = if (argv[0] != 0) @intCast(@max(1, @as(*const i32, @ptrFromInt(argv[0])).*)) else 600;
    const nearest = argv[1] != 0;

    const rtg_lib = sys.OpenLibrary(rtg.RTGNAME, 1) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(rtg_lib);
    if (rtg_lib.revision < rtg_revision) {
        _ = Printf(dl, "%s is older than 1.%u\n", .{ rtg.RTGNAME, @as(u32, rtg_revision) });
        return dos.RETURN_FAIL;
    }
    const rb: *RtgBase = @ptrCast(rtg_lib);
    const graphics_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(graphics_lib);
    const gb: *GraphicsBase = @ptrCast(graphics_lib);
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

    const texture_format = raster.TextureFormat.rgba8888;
    const texture_memory = sys.AllocVec(scenes.textureBytes(texture_format), exec.MEMF_ANY) orelse return noMemory(dl);
    defer sys.FreeVec(texture_memory);
    const texture = scenes.patternTexture(texture_format, @ptrCast(texture_memory));

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
    // Put behind before it closes, so the display goes straight back to
    // the screen that was in front.
    defer ib.ScreenToBack(screen);
    const width: u32 = @intCast(attr(ib, screen, sc.SA_Width));
    const height: u32 = @intCast(attr(ib, screen, sc.SA_Height));
    if (width < view_width or height < view_height) {
        _ = Printf(dl, "The display is smaller than %ux%u\n", .{ @as(u32, view_width), @as(u32, view_height) });
        return dos.RETURN_FAIL;
    }

    const own = ib.AllocScreenBuffer(screen, sc.SB_SCREEN_BITMAP) orelse return noBuffer(dl);
    defer ib.FreeScreenBuffer(screen, own);
    const second = ib.AllocScreenBuffer(screen, 0);
    defer if (second) |buffer| ib.FreeScreenBuffer(screen, buffer);
    const shown_buffers = [2]?*sc.ScreenBuffer{ own, second };
    const count: usize = if (second != null) 2 else 1;

    const area = raster.Rect{ .x = (width - view_width) / 2, .y = (height - view_height) / 2, .width = view_width, .height = view_height };
    var buffers: [2]Buffer = undefined;
    var made: usize = 0;
    defer for (buffers[0..made]) |*buffer| buffer.target.deinit();
    for (buffers[0..count], shown_buffers[0..count]) |*buffer, maybe_shown| {
        const shown = maybe_shown.?;
        const bitmap = shown.bitmap;
        const format = formatOf(bitmap) orelse {
            _ = Printf(dl, "The display is not 32 bits a pixel\n", .{});
            return dos.RETURN_FAIL;
        };
        // Black round the view, once.
        const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = 0xFF00_0000 }, .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} };
        gb.SetRPAttrs(shown.rast_port, &tags);
        gb.RectFill(shown.rast_port, &.{ .max_x = @intCast(width), .max_y = @intCast(height) });
        buffer.shown = shown;
        buffer.system = .{ .sys = sys, .rb = rb, .tb = tb, .bitmap = bitmap };
        const surface = raster.Surface{ .pixels = bitmap.pixels.?, .pitch = bitmap.pitch, .width = bitmap.width, .height = bitmap.height, .format = format };
        buffer.target = raster.Target.init(buffer.system.host(), surface, area, .{ .depth = .{ .used = true } }) catch return noMemory(dl);
        made += 1;
    }
    // The targets' hosts point into the buffers, which stay where they are.

    const began = board.now(tb);
    const run = (if (nearest)
        spin(.nearest, dl, ib, tb, screen, buffers[0..count], &texture, frames)
    else
        spin(.bilinear, dl, ib, tb, screen, buffers[0..count], &texture, frames)) orelse return noMemory(dl);
    const elapsed = board.now(tb) - began;

    const average = if (run.frames == 0) 0 else run.drawn_us / run.frames;
    _ = Printf(dl, "%u frames of %ux%u, %s: drawn in %lu.%03lu ms on average, %lu.%03lu ms at most; %lu shown a second\n", .{
        run.frames,
        @as(u32, view_width),
        @as(u32, view_height),
        @as([*:0]const u8, if (nearest) "nearest" else "bilinear"),
        average / 1000,
        average % 1000,
        run.most_us / 1000,
        run.most_us % 1000,
        if (elapsed == 0) @as(u64, 0) else @as(u64, run.frames) * 1_000_000 / elapsed,
    });
    _ = Printf(dl, "  the last: %u triangles set up, %u tiles, %u parts; set up %lu us, binned %lu us\n", .{
        run.stats.set_up, run.done.tiles, run.done.parts, run.stats.setup_us, run.stats.binning_us,
    });
    if (count == 1) _ = Printf(dl, "  one buffer, no room for another: drawn where it is shown\n", .{});
    if (run.refused != 0) _ = Printf(dl, "  %u times a buffer could not be shown yet\n", .{run.refused});
    return dos.RETURN_OK;
}

fn noMemory(dl: *DosBase) i32 {
    _ = Printf(dl, "Not enough memory\n", .{});
    return dos.RETURN_FAIL;
}

fn noBuffer(dl: *DosBase) i32 {
    _ = Printf(dl, "No buffer of the screen's\n", .{});
    return dos.RETURN_FAIL;
}
