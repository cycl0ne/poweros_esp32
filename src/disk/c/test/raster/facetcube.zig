// SPDX-License-Identifier: MIT
//! FacetCube: C:test/Cube's textured cube turning in front of its
//! backdrop, drawn through facet.library into an 800 x 600 view in the
//! middle of a screen of its own. The screen's buffers are a swapchain's
//! images; the backdrop and the box are each a pipeline whose shaders are
//! this program's functions (facetscene.zig), the box turned by its push
//! constants. What is made through facet.library is facetgpu.zig's, which
//! C:test/FacetWindow shares.
//!
//!   FacetCube FRAMES/N,NEAREST/S
//!
//! Each frame an image is acquired, a command buffer recorded - the
//! render pass over the view, the backdrop, the box - and submitted, and
//! the image presented once it is drawn: shown from the display's next
//! frame on, while the next is drawn into the other. FRAMES of them (600
//! if not given), or until Ctrl-C. Where the display's memory has no room
//! for a second buffer, the swapchain has one image, drawn while it is
//! shown. With NEAREST the box takes the nearest texel instead of four.
//! At the end the time a frame took to draw - from its recording until
//! its fence is signalled - is printed, on average and at most, and how
//! many frames were shown a second, as C:test/Cube prints them.

const sdk = @import("sdk");
const scenes = @import("scenes.zig");
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
const FacetBase = sdk.interface.facet.FacetBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TimerBase = timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "FacetCube";
const VERSION_STRING = "\x00$VER: FacetCube 1.2 (20.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FRAMES/N,NEAREST/S";

const view_width = 800;
const view_height = 600;

const Gpu = facetgpu.Gpu;
const Failure = facetgpu.Failure;

/// What a run took.
const Run = struct {
    frames: u32 = 0,
    drawn_us: u64 = 0,
    most_us: u64 = 0,
    out_of_date: bool = false,
};

/// The cube turning, `frames` of it, or until Ctrl-C.
fn spin(gpu: *Gpu, dl: *DosBase, tb: *TimerBase, frames: u32) Failure!Run {
    const fb = gpu.fb;
    var run = Run{};
    while (run.frames < frames and dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) {
        var index: u32 = 0;
        switch (fb.AcquireNextImage(gpu.device.?, gpu.swapchain.?, facet.WAIT_FOREVER_NS, gpu.acquired, null, &index)) {
            .success, .suboptimal => {},
            .error_out_of_date => {
                run.out_of_date = true;
                break;
            },
            else => return error.NoSwapchain,
        }
        // Black round the view the first time, outside the frame's time.
        const waits_for_acquire = gpu.cleared[index];
        if (!gpu.cleared[index]) try gpu.clear(index);
        const angle = @as(f32, @floatFromInt(run.frames)) * 0.02;
        const transform = scenes.cubeTransform(angle, 4.5, @as(f32, view_width) / view_height);
        const started = now(tb);
        try gpu.record(index, viewArea(gpu), &transform);
        try gpu.submitAndWait(if (waits_for_acquire) gpu.acquired else null, gpu.rendered);
        const took = now(tb) - started;
        run.drawn_us += took;
        run.most_us = @max(run.most_us, took);
        switch (gpu.present(index)) {
            .success, .suboptimal => {},
            .error_out_of_date => {
                run.out_of_date = true;
                break;
            },
            else => return error.NoSwapchain,
        }
        run.frames += 1;
    }
    return run;
}

/// The view in the middle of the screen.
fn viewArea(gpu: *const Gpu) facet.Rect2D {
    return .{
        .offset = .{ .x = @intCast((gpu.width - view_width) / 2), .y = @intCast((gpu.height - view_height) / 2) },
        .extent = .{ .width = view_width, .height = view_height },
    };
}

/// Microseconds from the timer's start.
fn now(tb: *TimerBase) u64 {
    var ev: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&ev);
    return ev.toTicks() * 1_000_000 / rate;
}

fn attr(ib: *IntuitionBase, screen: *intuition.Screen, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetScreenAttrs(screen, &ask);
    return value;
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
    if (attr(ib, screen, sc.SA_Width) < view_width or attr(ib, screen, sc.SA_Height) < view_height) {
        _ = Printf(dl, "The display is smaller than %ux%u\n", .{ @as(u32, view_width), @as(u32, view_height) });
        return dos.RETURN_FAIL;
    }

    var gpu = Gpu{ .fb = @ptrCast(facet_lib), .sys = sys };
    defer gpu.down();
    gpu.up(COMMAND_NAME) catch |err| return failed(dl, &gpu, err);
    gpu.onScreen(screen) catch |err| return failed(dl, &gpu, err);
    gpu.prepare(nearest, &pattern) catch |err| return failed(dl, &gpu, err);
    gpu.chain(2) catch |err| return failed(dl, &gpu, err);

    const began = now(tb);
    const run = spin(&gpu, dl, tb, frames) catch |err| return failed(dl, &gpu, err);
    const elapsed = now(tb) - began;

    const average = if (run.frames == 0) 0 else run.drawn_us / run.frames;
    _ = Printf(dl, "%u frames of %ux%u through facet.library, %s: drawn in %lu.%03lu ms on average, %lu.%03lu ms at most; %lu shown a second\n", .{
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
    if (gpu.image_count == 1) _ = Printf(dl, "  one image, no room for another: drawn while it is shown\n", .{});
    if (run.out_of_date) _ = Printf(dl, "  the screen changed: the swapchain is out of date\n", .{});
    return dos.RETURN_OK;
}

fn failed(dl: *DosBase, gpu: *const Gpu, err: Failure) i32 {
    return say(dl, facetgpu.explain(gpu, err));
}

fn say(dl: *DosBase, text: [*:0]const u8) i32 {
    _ = Printf(dl, "%s\n", .{text});
    return dos.RETURN_FAIL;
}
