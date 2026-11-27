// SPDX-License-Identifier: MPL-2.0
//! Host tests of the board's kernels: each job built as the board builds
//! it (`../kernels.zig`), run over the host's own memory pixel after
//! pixel as the kernel's threads run it (`jobs.zig`) - a whole group of
//! 64 along each row and a row past the end, as a dispatch has threads
//! past the rectangle - and held, byte for byte over the whole buffer, to
//! what graphics.library makes of the same job on the same pixels in
//! software: BlendBitMapPixels, BlendBitMapRect, ScalePixelArray with
//! RPTAG_Smooth, BltTemplate and BltPattern on a buffer of the host's
//! memory, which no board is behind. A job that lays what it lands on
//! goes through its marks, as the kernel's threads do, and is run again
//! after a run a reset ended part way, and once more, as a reset and a
//! second send run it: each pixel laid once. And the code object the
//! build makes of the kernels for the board, read as amdgpu.resource
//! reads it.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const graphics = sdk.graphics;
const TagItem = sdk.utility.TagItem;
const GraphicsLibrary = sdk.interface.graphics.GraphicsBase;

const kexec = @import("../../../exec/exec.zig");
const kutility = @import("../../../utility/utility.zig");
const krtg = @import("../../../rtg/rtg.zig");
const kgraphics = @import("../../../graphics/graphics.zig");
const krastport = @import("../../../graphics/rastport/_rastport.zig");

const kernels = @import("../kernels.zig");
const jobs = @import("jobs.zig");
const amdgpu = sdk.resources.amdgpu;
const code = @import("../../../../resources/amdgpu/code/_code.zig");
const compute = @import("../../../../resources/amdgpu/compute/_compute.zig");

// --- the library stood up ------------------------------------------------------------

/// exec on its test memory, then utility, rtg and graphics from their
/// tags, the order a cold start takes them in.
fn setUp() !*kgraphics.GraphicsBase {
    try kexec.setUp();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    _ = kexec.InitResident(kexec.SysBase, &krtg.rtg_library_tag, null) orelse return error.NoRtg;
    const made = kexec.InitResident(kexec.SysBase, &kgraphics.graphics_library_tag, null) orelse return error.NoGraphics;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

/// The library through its interface, as a program calls it.
fn library(gb: *kgraphics.GraphicsBase) *GraphicsLibrary {
    return @ptrCast(gb);
}

/// Every open given back and the three libraries freed: graphics closes
/// rtg and utility, rtg closes utility. Then nothing may be left.
fn tearDown(gb: *kgraphics.GraphicsBase) !void {
    const rb: *krtg.RtgBase = @ptrCast(@alignCast(gb.rtg_base));
    const ub: *kutility.UtilityBase = @ptrCast(@alignCast(gb.utility_base));
    kgraphics.freeOwnedForTests(gb);
    kexec.CloseLibrary(kexec.SysBase, &rb.lib);
    kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    kexec.Remove(kexec.SysBase, &gb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &gb.lib);
    kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    kexec.Remove(kexec.SysBase, &rb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &rb.lib);
    kutility.freeForTests(ub);
    try kexec.expectNoLeaks();
}

// --- the pixels ----------------------------------------------------------------------

/// The same numbers every run: xorshift.
const Numbers = struct {
    state: u32,

    fn next(numbers: *Numbers) u32 {
        var value = numbers.state;
        value ^= value << 13;
        value ^= value >> 17;
        value ^= value << 5;
        numbers.state = value;
        return value;
    }
};

/// The coverages a picture's pixels take: the ends, either side of them
/// and of the middle, and some between.
const coverages = [_]u32{ 0, 1, 2, 3, 64, 127, 128, 129, 200, 253, 254, 255 };

/// Colours of every kind, with coverages from `coverages` and, one in
/// four, any.
fn fillPicture(words: []u32, seed: u32) void {
    var numbers: Numbers = .{ .state = seed };
    for (words) |*word| {
        const colour = numbers.next() & 0x00FF_FFFF;
        const chosen = numbers.next();
        const coverage = if (chosen & 3 == 0) chosen >> 24 else coverages[(chosen >> 8) % coverages.len];
        word.* = colour | (coverage << 24);
    }
}

/// Any bytes, for a background or a shape's bits.
fn fillBytes(bytes: []u8, seed: u32) void {
    var numbers: Numbers = .{ .state = seed };
    for (bytes) |*byte| byte.* = @truncate(numbers.next() >> 11);
}

/// The buffer the work lands on: `width` x `height` pixels of
/// `bytes_each`, its rows `pitch` bytes apart, a little more than a row
/// of pixels, in the host's memory.
const Scene = struct {
    const width = 41;
    const height = 13;
    const most_bytes = 4;
    const pitch = width * most_bytes + 12;
    /// Where the work lands in it, away from every edge.
    const area: rtg.RtgRect = .{ .x = 3, .y = 2, .width = 33, .height = 9 };

    library: [pitch * height]u8 align(4) = undefined,
    kernel: [pitch * height]u8 align(4) = undefined,
    /// The marks of a job over the buffer or a part of it.
    marks: [kernels.marksBytes(width, height)]u8 = undefined,

    /// Both buffers the same background.
    fn paint(scene: *Scene, seed: u32) void {
        fillBytes(&scene.library, seed);
        scene.kernel = scene.library;
    }

    /// The marks cleared, as the board clears a piece of its own for a
    /// job, which it sends at generation 1, and their address.
    fn clearedMarks(scene: *Scene) u64 {
        @memset(&scene.marks, 0);
        return @intFromPtr(&scene.marks);
    }

    /// The marks as a piece of the board's holds them after a job before
    /// - each the generation before this job's, or any other but this
    /// one's, `generation` - and their address.
    fn usedMarks(scene: *Scene, generation: u8) u64 {
        for (&scene.marks, 0..) |*each, index| each.* = if (index % 3 == 0) generation -% 1 else generation +% @as(u8, @intCast(index % 7)) +% 1;
        return @intFromPtr(&scene.marks);
    }

    fn bitmap(pixels: []u8, format: rtg.PixelFormat) rtg.RtgBitMap {
        return .{ .pixels = pixels.ptr, .width = width, .height = height, .pitch = pitch, .size_bytes = pixels.len, .format = format };
    }

    fn surface(pixels: []u8, format: rtg.PixelFormat) rtg.Surface {
        return .{ .pixels = pixels.ptr, .width = width, .height = height, .pitch = pitch, .size_bytes = pixels.len, .format = format };
    }

    /// The device's address of the area's first pixel, as the board
    /// works it out: here the host's.
    fn first(scene: *Scene, bytes_each: u32) u64 {
        return @intFromPtr(&scene.kernel) + @as(u64, @intCast(area.y)) * pitch + @as(u64, @intCast(area.x)) * bytes_each;
    }

    /// The kernel's threads over the job's rectangle: as many groups
    /// along each row as a dispatch over it has, and a row more than it,
    /// whose threads must leave every pixel alone.
    fn run(scene: *Scene, comptime work: anytype, job: anytype) void {
        _ = scene;
        const groups_across = (job.width + 2 * jobs.group - 2) / jobs.group;
        var y: u32 = 0;
        while (y <= job.height) : (y += 1) {
            var x: u32 = 0;
            while (x < groups_across * jobs.group) : (x += 1) work(.generic, job, x, y);
        }
    }

    /// The same for a job that lays what it lands on, through its marks,
    /// a wave at a time as the engine runs one, its threads in step: each
    /// reads the wave's mark before its first thread sets it
    /// (`jobs.layOnce`). Each
    /// wave whose number among the job's, counted along its rows, leaves
    /// `left_out` - a number of 2 or more - no remainder is left out, as
    /// if a reset had ended the job before it; with `left_out` 0 none is.
    fn lay(scene: *Scene, comptime work: anytype, job: anytype, left_out: u32) void {
        _ = scene;
        const waves_across = jobs.wavesAcross(job.width);
        var y: u32 = 0;
        while (y <= job.height) : (y += 1) {
            var each_wave: u32 = 0;
            while (each_wave < waves_across) : (each_wave += 1) {
                if (left_out != 0 and (y * waves_across + each_wave) % left_out == 0) continue;
                const first_column = each_wave * jobs.wave;
                if (y >= job.height) {
                    // The row past the job's: its threads touch nothing.
                    for (first_column..first_column + jobs.wave) |column| jobs.layOnce(.generic, work, job, @intCast(column), y);
                    continue;
                }
                const own = jobs.markOf(.generic, job, first_column, y);
                const laid = jobs.laidBefore(own, job);
                for (first_column..first_column + jobs.wave) |column| work(.generic, job, @intCast(column), y, laid);
                jobs.markLaid(own, job);
            }
        }
    }

    /// The two buffers the same, or the first pixel where they are not.
    fn expectSame(scene: *const Scene, bytes_each: u32) !void {
        if (std.mem.eql(u8, &scene.library, &scene.kernel)) return;
        var y: usize = 0;
        while (y < height) : (y += 1) {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const at = y * pitch + x * bytes_each;
                const theirs = scene.library[at..][0..bytes_each];
                const ours = scene.kernel[at..][0..bytes_each];
                if (!std.mem.eql(u8, theirs, ours)) {
                    std.debug.print("pixel {d},{d}: the library's {x}, the kernel's {x}\n", .{ x, y, theirs, ours });
                    return error.TestExpectedEqual;
                }
            }
        }
        return error.TestExpectedEqual;
    }
};

// --- BlendPixels ---------------------------------------------------------------------

/// The picture laid: larger than the area, its part taken from a corner
/// away from its own top left.
const Picture = struct {
    const width = 47;
    const height = 17;
    const pitch = width * 4 + 8;
    words: [pitch / 4 * height]u32 = undefined,

    fn pixels(picture: *const Picture, format: rtg.PixelFormat, flags: u8, x: i32, y: i32) rtg.RtgPixels {
        return .{ .pixels = @ptrCast(&picture.words), .pitch = pitch, .format = format, .flags = flags, .x = x, .y = y };
    }

    /// The address of its pixel (x, y).
    fn at(picture: *const Picture, x: i32, y: i32) u64 {
        return @intFromPtr(&picture.words) + @as(u64, @intCast(y)) * pitch + @as(u64, @intCast(x)) * 4;
    }
};

test "blend_pixels lays every pixel as BlendBitMapPixels does: both formats, each strength, with and without the picture covering fully" {
    const gb = try setUp();
    defer kexec.deinit();
    var scene: Scene = .{};
    var picture: Picture = .{};
    fillPicture(&picture.words, 0x1234_5678);
    var seed: u32 = 1;
    for ([_]rtg.PixelFormat{ .bgra32, .rgba32 }) |format| {
        for ([_]u8{ 0, rtg.RTGPIXF_OPAQUE }) |flags| {
            for ([_]u32{ 255, 254, 200, 128, 127, 2, 1, 1000 }) |alpha| {
                seed += 1;
                scene.paint(seed);
                const described = picture.pixels(format, flags, 5, 3);
                var theirs = Scene.bitmap(&scene.library, .bgra32);
                try testing.expectEqual(graphics.GERR_OK, library(gb).BlendBitMapPixels(&theirs, &Scene.area, &described, alpha));
                const ours = Scene.bitmap(&scene.kernel, .bgra32);
                const job = kernels.blendPixelsJob(&ours, &Scene.area, &described, alpha, scene.first(4), picture.at(5, 3), scene.clearedMarks(), 1);
                scene.lay(jobs.blendPixels, job, 0);
                scene.expectSame(4) catch |failed| {
                    std.debug.print("{s}, flags {d}, alpha {d}\n", .{ @tagName(format), flags, alpha });
                    return failed;
                };
            }
        }
    }
    try tearDown(gb);
}

// --- BlendRect -----------------------------------------------------------------------

test "blend_rect lays a colour as BlendBitMapRect does, at every coverage" {
    const gb = try setUp();
    defer kexec.deinit();
    var scene: Scene = .{};
    var numbers: Numbers = .{ .state = 0x0bad_cafe };
    var seed: u32 = 100;
    for (coverages) |coverage| {
        for (0..3) |_| {
            seed += 1;
            scene.paint(seed);
            const pen = (numbers.next() & 0x00FF_FFFF) | (coverage << 24);
            var theirs = Scene.bitmap(&scene.library, .bgra32);
            try testing.expectEqual(graphics.GERR_OK, library(gb).BlendBitMapRect(&theirs, &Scene.area, pen));
            const ours = Scene.bitmap(&scene.kernel, .bgra32);
            scene.lay(jobs.blendRect, kernels.blendRectJob(&ours, &Scene.area, pen, scene.first(4), scene.clearedMarks(), 1), 0);
            scene.expectSame(4) catch |failed| {
                std.debug.print("pen {x}\n", .{pen});
                return failed;
            };
        }
    }
    try tearDown(gb);
}

// --- ScalePixels ---------------------------------------------------------------------

/// A RastPort on `surface` that scales smoothly.
fn smoothOn(gb: *kgraphics.GraphicsBase, surface: *rtg.Surface) !*graphics.RastPort {
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(surface) },
        .{ .tag = graphics.RPTAG_Smooth, .data = 1 },
        .{},
    };
    return library(gb).CreateRastPortTagList(&tags) orelse error.NoRastPort;
}

test "scale_pixels scales and lays a picture's part as a smooth ScalePixelArray does, and stores it as a smooth BitMapScale does: larger, smaller, the same, and smaller one way only" {
    const gb = try setUp();
    defer kexec.deinit();
    var scene: Scene = .{};
    var picture: Picture = .{};
    fillPicture(&picture.words, 0x9e37_79b9);
    var surface = Scene.surface(&scene.library, .bgra32);
    const rp = try smoothOn(gb, &surface);
    // The part's corner and size in the picture, and the area's size it
    // is scaled to.
    const Case = struct { x: i32, y: i32, width: u32, height: u32, to_width: i32, to_height: i32 };
    const cases = [_]Case{
        .{ .x = 3, .y = 2, .width = 7, .height = 5, .to_width = 33, .to_height = 9 }, // larger
        .{ .x = 0, .y = 0, .width = 2, .height = 2, .to_width = 31, .to_height = 7 }, // much larger
        .{ .x = 4, .y = 1, .width = 33, .height = 9, .to_width = 33, .to_height = 9 }, // the same
        .{ .x = 1, .y = 3, .width = 43, .height = 14, .to_width = 33, .to_height = 9 }, // smaller
        .{ .x = 0, .y = 0, .width = 47, .height = 17, .to_width = 5, .to_height = 3 }, // much smaller
        .{ .x = 2, .y = 2, .width = 40, .height = 3, .to_width = 13, .to_height = 9 }, // narrower, taller
        .{ .x = 6, .y = 0, .width = 9, .height = 17, .to_width = 33, .to_height = 4 }, // wider, shorter
    };
    var seed: u32 = 200;
    for ([_]rtg.PixelFormat{ .bgra32, .rgba32 }) |format| {
        for (cases) |case| {
            seed += 1;
            scene.paint(seed);
            const area: rtg.RtgRect = .{ .x = Scene.area.x, .y = Scene.area.y, .width = case.to_width, .height = case.to_height };
            const src_area: graphics.Rect = .{ .min_x = case.x, .min_y = case.y, .max_x = case.x + @as(i32, @intCast(case.width)), .max_y = case.y + @as(i32, @intCast(case.height)) };
            const dest_area: graphics.Rect = .{ .min_x = area.x, .min_y = area.y, .max_x = area.x + area.width, .max_y = area.y + area.height };
            library(gb).ScalePixelArray(rp, @ptrCast(&picture.words), Picture.pitch, @intFromEnum(format), &src_area, &dest_area);
            // What the library hands the engine for it (ScalePixels).
            const described = picture.pixels(format, 0, case.x, case.y);
            const ours = Scene.bitmap(&scene.kernel, .bgra32);
            const job = kernels.scalePixelsJob(&ours, &area, &described, case.width, case.height, scene.first(4), picture.at(case.x, case.y), scene.clearedMarks(), 1);
            scene.lay(jobs.scalePixels, job, 0);
            scene.expectSame(4) catch |failed| {
                std.debug.print("{s}, {d}x{d} at {d},{d} to {d}x{d}\n", .{ @tagName(format), case.width, case.height, case.x, case.y, case.to_width, case.to_height });
                return failed;
            };
        }
    }
    // Stored: BitMapScale between two surfaces of one format hands the
    // engine its picture with RTGPIXF_STORE.
    var source = rtg.Surface{ .pixels = @ptrCast(&picture.words), .width = Picture.width, .height = Picture.height, .pitch = Picture.pitch, .size_bytes = @sizeOf(@TypeOf(picture.words)), .format = .bgra32 };
    for (cases) |case| {
        seed += 1;
        scene.paint(seed);
        const area: rtg.RtgRect = .{ .x = Scene.area.x, .y = Scene.area.y, .width = case.to_width, .height = case.to_height };
        const src_area: graphics.Rect = .{ .min_x = case.x, .min_y = case.y, .max_x = case.x + @as(i32, @intCast(case.width)), .max_y = case.y + @as(i32, @intCast(case.height)) };
        const dest_area: graphics.Rect = .{ .min_x = area.x, .min_y = area.y, .max_x = area.x + area.width, .max_y = area.y + area.height };
        library(gb).BitMapScale(&source, &src_area, rp, &dest_area);
        const described = picture.pixels(.bgra32, rtg.RTGPIXF_STORE, case.x, case.y);
        const ours = Scene.bitmap(&scene.kernel, .bgra32);
        const job = kernels.scalePixelsJob(&ours, &area, &described, case.width, case.height, scene.first(4), picture.at(case.x, case.y), scene.clearedMarks(), 1);
        try testing.expect(job.flags & @import("pixels.zig").store != 0);
        scene.lay(jobs.scalePixels, job, 0);
        scene.expectSame(4) catch |failed| {
            std.debug.print("stored, {d}x{d} at {d},{d} to {d}x{d}\n", .{ case.width, case.height, case.x, case.y, case.to_width, case.to_height });
            return failed;
        };
    }
    library(gb).FreeRastPort(rp);
    try tearDown(gb);
}

// --- a job run again ------------------------------------------------------------------

test "a job that lays what it lands on, run again after a run a reset ended part way and once more, lays each pixel once: a picture, a colour and a scale" {
    const gb = try setUp();
    defer kexec.deinit();
    var scene: Scene = .{};
    var picture: Picture = .{};
    fillPicture(&picture.words, 0x2545_f491);
    var surface = Scene.surface(&scene.library, .bgra32);
    const rp = try smoothOn(gb, &surface);
    var seed: u32 = 300;
    // Every second, third and fifth wave left out of the first run, the
    // marks a piece's after jobs before it, at a generation in the middle,
    // the last and the first after they went round.
    const rounds = [_]struct { left_out: u32, generation: u8 }{ .{ .left_out = 2, .generation = 7 }, .{ .left_out = 3, .generation = 255 }, .{ .left_out = 5, .generation = 1 } };
    for (rounds) |round| {
        const left_out = round.left_out;
        const generation = round.generation;
        // A picture laid at half strength, its pixels covering by their
        // own, none and all.
        seed += 1;
        scene.paint(seed);
        const described = picture.pixels(.bgra32, 0, 5, 3);
        var theirs = Scene.bitmap(&scene.library, .bgra32);
        try testing.expectEqual(graphics.GERR_OK, library(gb).BlendBitMapPixels(&theirs, &Scene.area, &described, 128));
        const ours = Scene.bitmap(&scene.kernel, .bgra32);
        const blend = kernels.blendPixelsJob(&ours, &Scene.area, &described, 128, scene.first(4), picture.at(5, 3), scene.usedMarks(generation), generation);
        scene.lay(jobs.blendPixels, blend, left_out);
        scene.lay(jobs.blendPixels, blend, 0);
        scene.lay(jobs.blendPixels, blend, 0);
        try scene.expectSame(4);

        // A colour covering in part.
        seed += 1;
        scene.paint(seed);
        theirs = Scene.bitmap(&scene.library, .bgra32);
        try testing.expectEqual(graphics.GERR_OK, library(gb).BlendBitMapRect(&theirs, &Scene.area, 0x80_30_C0_60));
        const colour = kernels.blendRectJob(&ours, &Scene.area, 0x80_30_C0_60, scene.first(4), scene.usedMarks(generation), generation);
        scene.lay(jobs.blendRect, colour, left_out);
        scene.lay(jobs.blendRect, colour, 0);
        scene.lay(jobs.blendRect, colour, 0);
        try scene.expectSame(4);

        // A part of the picture scaled up and laid.
        seed += 1;
        scene.paint(seed);
        const src_area: graphics.Rect = .{ .min_x = 3, .min_y = 2, .max_x = 10, .max_y = 7 };
        const dest_area: graphics.Rect = .{ .min_x = Scene.area.x, .min_y = Scene.area.y, .max_x = Scene.area.x + Scene.area.width, .max_y = Scene.area.y + Scene.area.height };
        library(gb).ScalePixelArray(rp, @ptrCast(&picture.words), Picture.pitch, @intFromEnum(rtg.PixelFormat.bgra32), &src_area, &dest_area);
        const part = picture.pixels(.bgra32, 0, 3, 2);
        const scale = kernels.scalePixelsJob(&ours, &Scene.area, &part, 7, 5, scene.first(4), picture.at(3, 2), scene.usedMarks(generation), generation);
        scene.lay(jobs.scalePixels, scale, left_out);
        scene.lay(jobs.scalePixels, scale, 0);
        scene.lay(jobs.scalePixels, scale, 0);
        try scene.expectSame(4);
    }
    library(gb).FreeRastPort(rp);
    try tearDown(gb);
}

test "a job's marks: a byte for each wave of its groups, two a group, the groups as many as the spans of 64 pixels a row reaches into" {
    try testing.expectEqual(@as(u32, 2), jobs.wavesAcross(1));
    try testing.expectEqual(@as(u32, 4), jobs.wavesAcross(2));
    try testing.expectEqual(@as(u32, 4), jobs.wavesAcross(65));
    try testing.expectEqual(@as(u32, 6), jobs.wavesAcross(66));
    try testing.expectEqual(@as(u32, 82), jobs.wavesAcross(2560));
    try testing.expectEqual(@as(u64, 82 * 2880), kernels.marksBytes(2560, 2880));
    try testing.expectEqual(@as(u64, 242 * 4320), kernels.marksBytes(7680, 4320));
}

test "a job's marks: each wave's a byte of its own among the job's, the next wave's the next" {
    const job: jobs.BlendRect = .{ .dest = 0, .marks = 0x4_0000, .dest_pitch = 0, .width = 2560, .height = 900, .pen = 0, .generation = 1 };
    const bytes = kernels.marksBytes(job.width, job.height);
    const seen = try testing.allocator.alloc(bool, @intCast(bytes));
    defer testing.allocator.free(seen);
    @memset(seen, false);
    const waves_across = jobs.wavesAcross(job.width);
    var y: u32 = 0;
    while (y < job.height) : (y += 1) {
        var each_wave: u32 = 0;
        while (each_wave < waves_across) : (each_wave += 1) {
            const at: usize = @intCast(jobs.markAt(job, each_wave * jobs.wave, y) - job.marks);
            try testing.expect(at < bytes);
            try testing.expect(!seen[at]);
            seen[at] = true;
        }
    }
    // A wave's threads share it, and the next wave's, in the same row and
    // the next, is the next byte.
    try testing.expectEqual(jobs.markAt(job, 0, 0), jobs.markAt(job, jobs.wave - 1, 0));
    try testing.expectEqual(@as(u64, 1), jobs.markAt(job, jobs.wave, 0) - jobs.markAt(job, 0, 0));
    try testing.expectEqual(@as(u64, 1), jobs.markAt(job, 0, 1) - jobs.markAt(job, (waves_across - 1) * jobs.wave, 0));
}

// --- BlitTemplate and BlitPattern ----------------------------------------------------------

/// A RastPort on `surface` drawing in `mode` with two opaque pens.
fn shapesOn(gb: *kgraphics.GraphicsBase, surface: *rtg.Surface, mode: graphics.DrawMode) !*graphics.RastPort {
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(surface) },
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(0xE0, 0x30, 0x91) },
        .{ .tag = graphics.RPTAG_BPen, .data = graphics.penRGB(0x12, 0xC4, 0x5D) },
        .{ .tag = graphics.RPTAG_DrMd, .data = mode },
        .{},
    };
    return library(gb).CreateRastPortTagList(&tags) orelse error.NoRastPort;
}

/// The draw modes the library hands the engine: ink alone or both
/// colours, each with its colours swapped.
const modes = [_]graphics.DrawMode{
    graphics.DRMD_JAM1,
    graphics.DRMD_JAM2,
    graphics.DRMD_JAM1 | graphics.DRMD_INVERSVID,
    graphics.DRMD_JAM2 | graphics.DRMD_INVERSVID,
};

/// The flags the library gives the engine for `mode`.
fn shapeFlagsOf(mode: graphics.DrawMode) u32 {
    var flags: u32 = 0;
    if (mode & graphics.DRMD_JAM2 == 0) flags |= rtg.bitmaps.RTGTF_TRANSPARENT;
    if (mode & graphics.DRMD_INVERSVID != 0) flags |= rtg.bitmaps.RTGTF_INVERT;
    return flags;
}

/// The two formats of pixel the kernels draw shapes on.
const Kind = struct { format: rtg.PixelFormat, bytes_each: u32 };
const kinds = [_]Kind{ .{ .format = .bgra32, .bytes_each = 4 }, .{ .format = .rgb565, .bytes_each = 2 } };

test "blit_template draws a shape as BltTemplate does: each draw mode, on pixels of four bytes and of two, from a bit within a byte" {
    const gb = try setUp();
    defer kexec.deinit();
    var scene: Scene = .{};
    // Eleven bytes a row, of which the shape takes from bit 5 on; its
    // first row is its second.
    const bits_pitch = 11;
    var bits: [bits_pitch * 12]u8 = undefined;
    fillBytes(&bits, 0x5eed_1e55);
    const src_x = 5;
    const src_y = 1;
    var seed: u32 = 300;
    for (kinds) |kind| {
        for (modes) |mode| {
            seed += 1;
            scene.paint(seed);
            var surface = Scene.surface(&scene.library, kind.format);
            const rp = try shapesOn(gb, &surface, mode);
            const area = Scene.area;
            library(gb).BltTemplate(rp, &bits, bits_pitch, src_x, src_y, &.{ .min_x = area.x, .min_y = area.y, .max_x = area.x + area.width, .max_y = area.y + area.height });
            // What the library hands the engine for it (BlitTemplate).
            const pens: *krastport.RastPort = @ptrCast(@alignCast(rp));
            const shape: rtg.RtgTemplate = .{ .bits = &bits, .pitch = bits_pitch, .src_x = src_x, .src_y = src_y, .fg = pens.fg_packed, .bg = pens.bg_packed, .flags = shapeFlagsOf(mode) };
            const ours = Scene.bitmap(&scene.kernel, kind.format);
            const job = kernels.blitTemplateJob(&ours, &area, &shape, kind.bytes_each, scene.first(kind.bytes_each), @intFromPtr(&bits) + src_y * bits_pitch);
            scene.run(jobs.blitTemplate, job);
            library(gb).FreeRastPort(rp);
            scene.expectSame(kind.bytes_each) catch |failed| {
                std.debug.print("{s}, mode {d}\n", .{ @tagName(kind.format), mode });
                return failed;
            };
        }
    }
    try tearDown(gb);
}

test "blit_pattern repeats a tile as BltPattern does: anchored to the buffer, each draw mode, a tile of an odd size, on pixels of four bytes and of two" {
    const gb = try setUp();
    defer kexec.deinit();
    var scene: Scene = .{};
    // A tile of 11 x 5 bits, two bytes a row and one more.
    const tile_pitch = 3;
    const tile_width = 11;
    const tile_height = 5;
    var tile_bits: [tile_pitch * tile_height]u8 = undefined;
    fillBytes(&tile_bits, 0x7175_0ff5);
    var seed: u32 = 400;
    for (kinds) |kind| {
        for (modes) |mode| {
            seed += 1;
            scene.paint(seed);
            var surface = Scene.surface(&scene.library, kind.format);
            const rp = try shapesOn(gb, &surface, mode);
            const area = Scene.area;
            library(gb).BltPattern(rp, &tile_bits, tile_pitch, tile_width, tile_height, &.{ .min_x = area.x, .min_y = area.y, .max_x = area.x + area.width, .max_y = area.y + area.height });
            // What the library hands the engine for it (BlitPattern).
            const pens: *krastport.RastPort = @ptrCast(@alignCast(rp));
            const tile: rtg.RtgPattern = .{ .bits = &tile_bits, .pitch = tile_pitch, .width = tile_width, .height = tile_height, .fg = pens.fg_packed, .bg = pens.bg_packed, .flags = shapeFlagsOf(mode) };
            const ours = Scene.bitmap(&scene.kernel, kind.format);
            const job = kernels.blitPatternJob(&ours, &area, &tile, kind.bytes_each, scene.first(kind.bytes_each), @intFromPtr(&tile_bits));
            scene.run(jobs.blitPattern, job);
            library(gb).FreeRastPort(rp);
            scene.expectSame(kind.bytes_each) catch |failed| {
                std.debug.print("{s}, mode {d}\n", .{ @tagName(kind.format), mode });
                return failed;
            };
        }
    }
    try tearDown(gb);
}

test "a tile's origin moves its bits by as much, counted round the tile either way" {
    const area: rtg.RtgRect = .{ .x = 3, .y = 2, .width = 4, .height = 4 };
    const bitmap: rtg.RtgBitMap = .{ .pitch = 64, .format = .bgra32 };
    const anchored = kernels.blitPatternJob(&bitmap, &area, &.{ .width = 11, .height = 5 }, 4, 0, 0);
    try testing.expectEqual(@as(u32, 3), anchored.first_column);
    try testing.expectEqual(@as(u32, 2), anchored.first_row);
    const moved = kernels.blitPatternJob(&bitmap, &area, &.{ .width = 11, .height = 5, .origin_x = 7, .origin_y = -9 }, 4, 0, 0);
    try testing.expectEqual(@as(u32, 7), moved.first_column); // 3 - 7 round 11
    try testing.expectEqual(@as(u32, 1), moved.first_row); // 2 + 9 round 5
}

// --- the code object ---------------------------------------------------------------------

test "the board's code object as the build makes it: each kernel found as FindGPUKernel finds it, handed its job, and taken by SendGPUKernel for the largest rectangle" {
    const image: []const u8 = @embedFile("amd_engine_code");
    const head = code.header(image, code.EF_AMDGPU_MACH_GFX1103) orelse return error.NotACodeObject;
    const covered = code.span(image, head) orelse return error.NoSegments;
    const asked = code.relocations(image, head) orelse return error.UnknownRelocations;
    try testing.expectEqual(@as(u64, 0), asked.bytes);
    const each = .{
        .{ "blend_pixels", jobs.BlendPixels },
        .{ "blend_rect", jobs.BlendRect },
        .{ "scale_pixels", jobs.ScalePixels },
        .{ "blit_template", jobs.BlitTemplate },
        .{ "blit_pattern", jobs.BlitPattern },
    };
    inline for (each) |named| {
        const at = code.kernelDescriptor(image, head, named[0]) orelse return error.NoKernel;
        const found = code.descriptorAt(image, code.offsetOf(image, head, at, code.descriptor_bytes).?).?;
        const entry = at +% @as(u64, @bitCast(found.entry));
        try testing.expectEqual(@as(u64, 0), entry % 256);
        try testing.expect(entry > at and entry < covered.bytes);
        try testing.expectEqual(@as(u16, 0), found.preloaded);
        try testing.expectEqual(@as(u32, 0), found.private_bytes);
        try testing.expectEqual(@as(u32, @sizeOf(named[1])), found.argument_bytes);
        const kernel: amdgpu.GPUKernel = .{
            .code = 0x80_0000_0000 + entry,
            .rsrc1 = found.rsrc1,
            .rsrc2 = found.rsrc2,
            .rsrc3 = found.rsrc3,
            .argument_bytes = found.argument_bytes,
            .group_bytes = found.group_bytes,
            .private_bytes = found.private_bytes,
            .properties = found.properties,
        };
        // A rectangle of the largest sides the board hands a kernel, in
        // groups of 64 along its rows.
        if (compute.refusal(&kernel, .{ (1 << 16) / 64 + 1, 1 << 16, 1 }, .{ 64, 1, 1 }, @sizeOf(named[1]), 0)) |why| {
            std.debug.print("{s}: {s}\n", .{ named[0], why });
            return error.Refused;
        }
    }
}
