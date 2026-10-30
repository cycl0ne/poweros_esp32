// SPDX-License-Identifier: MIT
//! FacetWindow: C:test/Cube's textured cube turning in front of its
//! backdrop, drawn through facet.library inside a window on the desktop -
//! the default public screen - which can be moved, sized, put behind
//! others and brought forward while it turns, the desktop beside it used
//! as ever.
//!
//!   FacetWindow WIDTH/N,HEIGHT/N,NEAREST/S,FRAMES/N,CLOSE/S,V3D/S,CORES/S
//!
//! The window is WIDTH x HEIGHT inside its border (480 x 360 if not
//! given). Its surface (CreateWindowSurface) hands out pictures in memory
//! of that size, two of them, and each frame one is acquired, drawn and
//! presented: copied into the window at the display's next frame, through
//! its layer, while the next is drawn into the other. Once the window is
//! made bigger or smaller, the swapchain is out of date, and a new one of
//! the window's new size takes its place, the cube drawn to fill it. It
//! turns until the window's close gadget is pressed, Ctrl-C, or FRAMES
//! frames; then how many frames it showed, how many a second, and how
//! often the swapchain was made anew are printed. With NEAREST the box
//! takes the nearest texel instead of four. With CLOSE the window is
//! closed as soon as the first frame is presented, while that frame is
//! still on its way - as intuition closes the windows of a program that
//! ends with them open - and the surface must then say it is lost
//! (`error_surface_lost`) rather than have the frame drawn into a window
//! that has gone. It is all drawn on the device after the cores where there
//! is one, a CM5's GPU, and with CORES on the cores. With V3D a machine
//! without a GPU says there is no device. What is made through facet.library
//! is facetgpu.zig's, which C:test/FacetCube shares.

const sdk = @import("sdk");
const scenes = @import("scenes.zig");
const facetgpu = @import("facetgpu.zig");
const dos = sdk.dos;
const exec = sdk.exec;
const facet = sdk.facet;
const intuition = sdk.intuition;
const wn = intuition.windows;
const timer = sdk.devices.timer;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TimerBase = timer.TimerBase;
const Printf = dos.stdio.Printf;
const Gpu = facetgpu.Gpu;
const Failure = facetgpu.Failure;

pub const COMMAND_NAME = "FacetWindow";
const VERSION_STRING = "\x00$VER: FacetWindow 1.6 (30.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "WIDTH/N,HEIGHT/N,NEAREST/S,FRAMES/N,CLOSE/S,V3D/S,CORES/S";

/// What a run came to.
const Run = struct {
    frames: u32 = 0,
    /// Swapchains made after the first: once for each time the window's
    /// size changed while it turned.
    remade: u32 = 0,
};

/// The cube turning in the window until it is closed, Ctrl-C, or
/// `frames` frames (0: no end).
fn spin(gpu: *Gpu, ib: *IntuitionBase, dl: *DosBase, window: *intuition.Window, frames: u32) Failure!Run {
    const fb = gpu.fb;
    var run = Run{};
    var turned: u32 = 0;
    while (frames == 0 or run.frames < frames) : (turned += 1) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) break;
        if (closing(ib, window)) break;
        var index: u32 = 0;
        switch (fb.AcquireNextImage(gpu.device.?, gpu.swapchain.?, facet.WAIT_FOREVER_NS, gpu.acquired, null, &index)) {
            .success, .suboptimal => {},
            .error_out_of_date => {
                try gpu.chain(2);
                run.remade += 1;
                continue;
            },
            .error_device_lost => return error.DeviceLost,
            else => return error.NoSwapchain,
        }
        const waits_for_acquire = gpu.cleared[index];
        if (!gpu.cleared[index]) try gpu.clear(index);
        const area = facet.Rect2D{ .extent = .{ .width = gpu.width, .height = gpu.height } };
        const aspect = @as(f32, @floatFromInt(gpu.width)) / @as(f32, @floatFromInt(gpu.height));
        const transform = scenes.cubeTransform(@as(f32, @floatFromInt(turned)) * 0.02, 4.5, aspect);
        try gpu.record(index, area, &transform);
        try gpu.submitAndWait(if (waits_for_acquire) gpu.acquired else null, gpu.rendered);
        switch (gpu.present(index)) {
            .success, .suboptimal => run.frames += 1,
            .error_out_of_date => {
                try gpu.chain(2);
                run.remade += 1;
            },
            .error_device_lost => return error.DeviceLost,
            else => return error.NoSwapchain,
        }
    }
    return run;
}

/// One frame presented, and the window closed while it is on its way:
/// true when the surface then says it is lost.
fn closeInFlight(gpu: *Gpu, ib: *IntuitionBase, dl: *DosBase, window: *intuition.Window) Failure!bool {
    _ = try spin(gpu, ib, dl, window, 1);
    ib.CloseWindow(window);
    var index: u32 = 0;
    return gpu.fb.AcquireNextImage(gpu.device.?, gpu.swapchain.?, facet.WAIT_FOREVER_NS, gpu.acquired, null, &index) == .error_surface_lost;
}

/// The window's messages answered: true once its close gadget was
/// pressed. A new size needs nothing here - the swapchain says it is out
/// of date.
fn closing(ib: *IntuitionBase, window: *intuition.Window) bool {
    var closed = false;
    while (ib.GetIMsg(window)) |message| {
        if (message.class == wn.IDCMP_CLOSEWINDOW) closed = true;
        ib.ReplyIMsg(message);
    }
    return closed;
}

/// Microseconds from the timer's start.
fn now(tb: *TimerBase) u64 {
    var ev: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&ev);
    return ev.toTicks() * 1_000_000 / rate;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [7]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const width = number(argv[0], 480, 64);
    const height = number(argv[1], 360, 48);
    const nearest = argv[2] != 0;
    const frames = number(argv[3], 0, 1);
    const close = argv[4] != 0;
    const wanted = facetgpu.Wanted.of(argv[5], argv[6]);

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

    const as_large_as_the_screen: usize = @bitCast(@as(isize, -1));
    const window = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_InnerWidth, .data = width },
        .{ .tag = wn.WA_InnerHeight, .data = height },
        .{ .tag = wn.WA_Position, .data = wn.WPOS_CENTERSCREEN },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("FacetWindow") },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_MinWidth, .data = 96 },
        .{ .tag = wn.WA_MinHeight, .data = 72 },
        .{ .tag = wn.WA_MaxWidth, .data = as_large_as_the_screen },
        .{ .tag = wn.WA_MaxHeight, .data = as_large_as_the_screen },
        // Every picture covers the whole inside: nothing to keep of what
        // is covered, nothing to draw again when it is not.
        .{ .tag = wn.WA_SimpleRefresh, .data = 1 },
        .{ .tag = wn.WA_NoCareRefresh, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW | wn.IDCMP_NEWSIZE },
        .{},
    }) orelse return say(dl, "No window");
    var open = true;
    defer if (open) ib.CloseWindow(window);

    var gpu = Gpu{ .fb = @ptrCast(facet_lib), .ib = ib };
    // Given back before the window closes: the surface is over it.
    defer gpu.down();
    gpu.up(COMMAND_NAME, wanted) catch |err| return failed(dl, &gpu, err);
    gpu.onWindow(window) catch |err| return failed(dl, &gpu, err);
    gpu.prepare(nearest, &pattern) catch |err| return failed(dl, &gpu, err);
    gpu.chain(2) catch |err| return failed(dl, &gpu, err);

    if (close) {
        open = false;
        const lost = closeInFlight(&gpu, ib, dl, window) catch |err| return failed(dl, &gpu, err);
        if (!lost) return say(dl, "The window closed with a frame on its way, and the surface was not lost");
        _ = Printf(dl, "The window closed with a frame on its way: the surface is lost\n", .{});
        return dos.RETURN_OK;
    }

    const began = now(tb);
    const run = spin(&gpu, ib, dl, window, frames) catch |err| return failed(dl, &gpu, err);
    const elapsed = now(tb) - began;

    _ = Printf(dl, "%u frames through facet.library in a window of %ux%u, %s: %lu shown a second; the swapchain made anew %u times\n", .{
        run.frames,
        gpu.width,
        gpu.height,
        @as([*:0]const u8, if (nearest) "nearest" else "bilinear"),
        if (elapsed == 0) @as(u64, 0) else @as(u64, run.frames) * 1_000_000 / elapsed,
        run.remade,
    });
    return dos.RETURN_OK;
}

/// A number ReadArgs read, at least `least`, or `otherwise` when not
/// given.
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
