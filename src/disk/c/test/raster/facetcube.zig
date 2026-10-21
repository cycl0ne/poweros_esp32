// SPDX-License-Identifier: MIT
//! FacetCube: C:test/Cube's textured cube turning in front of its
//! backdrop, drawn through facet.library into a view in the middle of a
//! screen of its own. The screen's buffers are a swapchain's images; the
//! backdrop and the box are each a pipeline whose shaders are this
//! program's functions (facetscene.zig), the box turned by its push
//! constants. What is made through facet.library is facetgpu.zig's, which
//! C:test/FacetWindow shares.
//!
//!   FacetCube FRAMES/N,NEAREST/S,SIZE/K,CHECK/S,TO/K
//!
//! The view is SIZE big, WIDTHxHEIGHT: 800x600 if not given. Each frame
//! an image is acquired, a command buffer recorded - the render pass over
//! the view, the backdrop, the box - and submitted, and the image
//! presented once it is drawn: shown from the display's next frame on,
//! while the next is drawn into the other. FRAMES of them (600 if not
//! given), or until Ctrl-C. Where the display's memory has no room for a
//! second buffer, the swapchain has one image, drawn while it is shown.
//! With NEAREST the box takes the nearest texel instead of four. At the
//! end the time a frame took to draw - from its recording until its fence
//! is signalled - is printed, on average and at most, and how many frames
//! were shown a second, as C:test/Cube prints them.
//!
//! With CHECK or TO no frames are shown: the cube is drawn once, still,
//! turned as reference/cube.ppm holds it, into a picture of the display's
//! format the program reads back - SIZE big, 160x120 if not given - the
//! screen opened only for that format. CHECK compares it with the picture
//! the rasterizer's tests keep (reference/cube.ppm, cube-565.ppm in 565)
//! as they compare theirs: it may differ by 2 in a channel anywhere - in
//! 565 by a step - and by more in one pixel in a thousand. It prints how
//! many pixels are the same, near and further, and returns WARN when more
//! than that many are further. TO writes the picture to a file, a PPM as
//! reference/ keeps them: 8 bits a channel, 565 widened as the display
//! shows it.

const std = @import("std");
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
const VERSION_STRING = "\x00$VER: FacetCube 1.5 (21.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FRAMES/N,NEAREST/S,SIZE/K,CHECK/S,TO/K";

/// A view's size, or a still picture's.
const View = struct {
    width: u32,
    height: u32,

    fn aspect(view: View) f32 {
        return @as(f32, @floatFromInt(view.width)) / @as(f32, @floatFromInt(view.height));
    }
};

const turning = View{ .width = 800, .height = 600 };
/// reference/cube.ppm's: what CHECK compares.
const still = View{ .width = 160, .height = 120 };
/// How far reference/cube.ppm's cube is turned.
const still_angle = 0.6;

const reference_header = "P6\n160 120\n255\n";
const reference_32 = @embedFile("reference/cube.ppm");
const reference_565 = @embedFile("reference/cube-565.ppm");

comptime {
    for ([_][]const u8{ reference_32, reference_565 }) |kept| {
        if (kept.len != reference_header.len + still.width * still.height * 3 or !std.mem.eql(u8, kept[0..reference_header.len], reference_header))
            @compileError("reference/cube.ppm and cube-565.ppm are pictures of 160 x 120");
    }
}

/// The pixels of a still picture that may differ from the reference by
/// more than the format's slack.
const most_apart = still.width * still.height / 1000;

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
fn spin(gpu: *Gpu, dl: *DosBase, tb: *TimerBase, view: View, frames: u32) Failure!Run {
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
        const transform = scenes.cubeTransform(angle, 4.5, view.aspect());
        const started = now(tb);
        try gpu.record(index, viewArea(gpu, view), &transform);
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
fn viewArea(gpu: *const Gpu, view: View) facet.Rect2D {
    return .{
        .offset = .{ .x = @intCast((gpu.width - view.width) / 2), .y = @intCast((gpu.height - view.height) / 2) },
        .extent = .{ .width = view.width, .height = view.height },
    };
}

/// The cube drawn once, still, into a picture of `view`'s size: compared
/// with the reference for CHECK, written to `to` for TO.
fn drawStill(dl: *DosBase, gpu: *Gpu, view: View, check: bool, to: ?[*:0]const u8) Failure!i32 {
    const picture = try gpu.picture(view.width, view.height);
    const transform = scenes.cubeTransform(still_angle, 4.5, view.aspect());
    try gpu.recordInto(picture.framebuffer, .{ .extent = .{ .width = view.width, .height = view.height } }, &transform);
    try gpu.submitAndWait(null, null);
    var result: i32 = dos.RETURN_OK;
    if (check) result = compare(dl, &picture);
    if (to) |name| {
        if (!writePicture(dl, &picture, name)) {
            _ = dl.PrintFault(dl.IoErr(), name);
            return dos.RETURN_ERROR;
        }
        _ = Printf(dl, "%s: the cube still, %ux%u in %s\n", .{ name, view.width, view.height, formatName(picture.format) });
    }
    return result;
}

/// The still picture, 160 x 120, against the rasterizer's reference of
/// it, as reference.zig compares them, and what came of it printed: OK,
/// or WARN when too many pixels are further from it than the slack.
fn compare(dl: *DosBase, picture: *const facetgpu.Picture) i32 {
    const in_565 = picture.format == .r5g6b5_unorm_pack16;
    const kept = if (in_565) reference_565 else reference_32;
    // In steps of the format: 2 of 8 bits, one of 565.
    const slack: u32 = if (in_565) 1 else 2;
    const shifts: [3]u3 = if (in_565) .{ 3, 2, 3 } else .{ 0, 0, 0 };
    var same: u32 = 0;
    var near: u32 = 0;
    var apart: u32 = 0;
    var worst: u32 = 0;
    for (0..still.height) |y| for (0..still.width) |x| {
        const pixel = picture.color(x, y);
        var most: u32 = 0;
        for (0..3, shifts) |channel, shift| {
            const got: i32 = @intCast((pixel >> @intCast(16 - channel * 8) & 0xFF) >> shift);
            const want: i32 = kept[reference_header.len + (y * still.width + x) * 3 + channel] >> shift;
            most = @max(most, @abs(got - want));
        }
        worst = @max(worst, most);
        if (most == 0) {
            same += 1;
        } else if (most <= slack) {
            near += 1;
        } else apart += 1;
    };
    const like = apart <= most_apart;
    _ = Printf(dl, "The cube still, 160x120 in %s, against reference/%s.ppm: %lu pixels the same, %lu off by %lu or less, %lu by more (%lu may be), %lu at worst: %s\n", .{
        formatName(picture.format),
        @as([*:0]const u8, if (in_565) "cube-565" else "cube"),
        @as(u64, same),
        @as(u64, near),
        @as(u64, slack),
        @as(u64, apart),
        @as(u64, most_apart),
        @as(u64, worst),
        @as([*:0]const u8, if (like) "alike" else "DIFFERENT"),
    });
    return if (like) dos.RETURN_OK else dos.RETURN_WARN;
}

/// The picture written to `name` as a PPM, 8 bits a channel; false when
/// it could not be, the reason in IoErr.
fn writePicture(dl: *DosBase, picture: *const facetgpu.Picture, name: [*:0]const u8) bool {
    const file = dl.Open(name, dos.MODE_NEWFILE) orelse return false;
    var out = Output{ .dl = dl, .file = file };
    out.text("P6\n");
    out.number(picture.width);
    out.text(" ");
    out.number(picture.height);
    out.text("\n255\n");
    for (0..picture.height) |y| for (0..picture.width) |x| {
        const pixel = picture.color(x, y);
        inline for (.{ 16, 8, 0 }) |shift| out.byte(@truncate(pixel >> shift));
    };
    const written = out.flush();
    return dl.Close(file) and written;
}

/// Bytes gathered and written to a file a buffer at a time.
const Output = struct {
    dl: *DosBase,
    file: *dos.FileHandle,
    buffer: [768]u8 = undefined,
    used: usize = 0,
    failed: bool = false,

    fn byte(out: *Output, value: u8) void {
        if (out.used == out.buffer.len) _ = out.flush();
        out.buffer[out.used] = value;
        out.used += 1;
    }

    fn text(out: *Output, bytes: []const u8) void {
        for (bytes) |each| out.byte(each);
    }

    fn number(out: *Output, value: u32) void {
        var digits: [10]u8 = undefined;
        var at: usize = digits.len;
        var left = value;
        while (true) {
            at -= 1;
            digits[at] = @intCast('0' + left % 10);
            left /= 10;
            if (left == 0) break;
        }
        out.text(digits[at..]);
    }

    /// What is gathered written; false once a write has failed.
    fn flush(out: *Output) bool {
        if (out.used != 0 and out.dl.Write(out.file, &out.buffer, @intCast(out.used)) != out.used) out.failed = true;
        out.used = 0;
        return !out.failed;
    }
};

fn formatName(format: facet.Format) [*:0]const u8 {
    return switch (format) {
        .r5g6b5_unorm_pack16 => "rgb565",
        .r8g8b8a8_unorm => "rgba32",
        else => "bgra32",
    };
}

/// SIZE's "WIDTHxHEIGHT", each side 16 or more; null if it is not that.
fn parseSize(text: [*:0]const u8) ?View {
    var sides = [2]u32{ 0, 0 };
    var side: usize = 0;
    var digits: u32 = 0;
    var at: usize = 0;
    while (text[at] != 0) : (at += 1) {
        switch (text[at]) {
            '0'...'9' => |digit| {
                if (digits == 5) return null;
                sides[side] = sides[side] * 10 + (digit - '0');
                digits += 1;
            },
            'x', 'X' => {
                if (side == 1 or digits == 0) return null;
                side = 1;
                digits = 0;
            },
            else => return null,
        }
    }
    if (side != 1 or digits == 0 or sides[0] < 16 or sides[1] < 16) return null;
    return .{ .width = sides[0], .height = sides[1] };
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
    var argv: [5]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const frames: u32 = if (argv[0] != 0) @intCast(@max(1, @as(*const i32, @ptrFromInt(argv[0])).*)) else 600;
    const nearest = argv[1] != 0;
    const check = argv[3] != 0;
    const to: ?[*:0]const u8 = if (argv[4] != 0) @ptrFromInt(argv[4]) else null;
    const stands = check or to != null;
    const view = if (argv[2] != 0) parseSize(@ptrFromInt(argv[2])) orelse {
        _ = Printf(dl, "SIZE is WIDTHxHEIGHT, each 16 or more: 800x600\n", .{});
        return dos.RETURN_ERROR;
    } else if (stands) still else turning;
    if (check and nearest) return say(dl, "CHECK compares the box drawn bilinear, not NEAREST");
    if (check and (view.width != still.width or view.height != still.height)) return say(dl, "CHECK compares a picture of 160x120, its reference's size");

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
    if (!stands and (attr(ib, screen, sc.SA_Width) < view.width or attr(ib, screen, sc.SA_Height) < view.height)) {
        _ = Printf(dl, "The display is smaller than %ux%u\n", .{ view.width, view.height });
        return dos.RETURN_FAIL;
    }

    var gpu = Gpu{ .fb = @ptrCast(facet_lib), .ib = ib };
    defer gpu.down();
    gpu.up(COMMAND_NAME) catch |err| return failed(dl, &gpu, err);
    gpu.onScreen(screen) catch |err| return failed(dl, &gpu, err);
    gpu.prepare(nearest, &pattern) catch |err| return failed(dl, &gpu, err);
    if (stands) return drawStill(dl, &gpu, view, check, to) catch |err| failed(dl, &gpu, err);
    gpu.chain(2) catch |err| return failed(dl, &gpu, err);

    const began = now(tb);
    const run = spin(&gpu, dl, tb, view, frames) catch |err| return failed(dl, &gpu, err);
    const elapsed = now(tb) - began;

    const average = if (run.frames == 0) 0 else run.drawn_us / run.frames;
    _ = Printf(dl, "%u frames of %ux%u through facet.library, %s: drawn in %lu.%03lu ms on average, %lu.%03lu ms at most; %lu shown a second\n", .{
        run.frames,
        view.width,
        view.height,
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
