// SPDX-License-Identifier: MPL-2.0
//! The board's engine laying and drawing: BlendPixels, BlendRect,
//! ScalePixels, BlitTemplate and BlitPattern done by kernels of the
//! board's own (`kernels/engine.zig`) on the graphics block's compute
//! engine, whose queue amdgpu.resource runs, on the machine's memory the
//! buffers are in. Each pixel is the one graphics.library makes for the
//! same job (`kernels/jobs.zig`, `kernels/pixels.zig`): each kernel is
//! handed its job as the structure `kernels/jobs.zig` has for it, which
//! the board fills in (`blendPixelsJob` and the others).
//!
//! **Which jobs.** A job the cores do sooner, as near as one rule tells
//! it, is answered RTGERR_NOT_SUPPORTED before anything is written, and
//! graphics.library does it on the cores; RTGCTRL_AMD_ENGINE has the kernels take every
//! job they can do, or none, instead (`dma.zig`). By the board's own
//! rule a job is the kernels' where it lands on `least_pixels` pixels or
//! more - below that a job of theirs, some 90 us however small, takes
//! longer than the cores need - but never a shape or a tile in ink
//! alone, which the kernels draw more slowly than in both colours, though
//! they write fewer pixels, and no sooner, taken together, than the
//! cores.
//!
//! On the NucBox, by `C:test/Gpu KERNELS` - every job handed to the
//! kernels, then by this rule, the cores' timed on plain memory and on
//! the board's buffer where the board left a job to them, each drawing
//! begun with nothing it touches in the CPU's caches: a picture laid over
//! 2560 x 2880 pixels took the kernels 2283 to 2331 us and the cores 2763
//! to 2906, over 1024 x 1024 450 to 463 and 559 to 561, over 256 x 256
//! 116 to 117 and 112 to 113, over 64 x 64 88 and 14 to 19; a colour over
//! 1024 x 1024 333 to 334 and 553 to 558, over 256 x 256 105 to 107 and
//! 108 to 109; a picture scaled up twice to the whole buffer 3408 to 3414
//! and 6951 to 7056, as `rgba32` 3444 to 3557 and 7622 to 7669, from 128
//! to 256 pixels a side 145 and 198 to 199; a shape in both colours over
//! the buffer 1480 to 1487 and 1793 to 2047, over 256 x 256 100 to 106
//! and 143 to 145, in ink alone over most of it 1802 and 1647 to 1782; a
//! tile over the buffer 1150 to 1168 and 1678 to 1915, over 256 x 256 122
//! and 97 to 98, in ink alone 1606 and 1771 to 1785. At 256 x 256 the two
//! meet: there a picture or a colour takes either about as long, a scale
//! or a shape is the kernels' sooner and a tile the cores'. A job of the
//! kernels takes some 90 us however small - its memory mapped, the kernel
//! sent and waited for, the mapping taken out - of which an empty job of
//! the queue is 12.
//!
//! **Until the kernels run** every job is refused. The process that
//! starts the DMA engine's queue goes on, once that runs, to start the
//! compute engine's queue (StartGPUCompute), to load the code object the
//! board carries into the device's memory (LoadGPUCode) and to find its
//! five kernels in it (FindGPUKernel); where any of it fails the log
//! says why, and the kernels are not used. The code object is freed as
//! the board goes.
//!
//! **The memory** a job reads and writes is mapped for it
//! (MapGPUMemory), as the DMA engine's is: the buffer's rows from the
//! rectangle's first to its last, and the picture's, the shape's or the
//! tile's from the first byte read to the last, each taken out again once
//! the job is done. The hub snoops the CPU's caches, so nothing is
//! written back or dropped around a job. A buffer or a picture of the
//! device's own memory takes no mapping: the kernels reach it through the
//! hub's aperture, uncached in the block.
//!
//! **A job** is one dispatch over the rectangle, a thread a pixel in
//! groups of 64 along a row, each group on a span of 64 pixels of the
//! buffer's memory (`kernels/jobs.zig`), so that two groups of a row
//! never write parts of one cache line - a row of groups for each row, as
//! many as the spans a row can reach into: pixels laid over a `bgra32`
//! buffer from a picture of `bgra32` or `rgba32`, at a strength or
//! covering fully (`RTGPIXF_OPAQUE`); a colour laid over one; a part of
//! such a picture scaled into one and laid over it by its coverage, or
//! stored there, alpha and all (`RTGPIXF_STORE`) - each pixel mixed from
//! the four round its place, or, made smaller either way, the mean of all
//! the pixels it covers; a shape or a tile in two colours on a buffer of
//! two bytes a pixel or of four, a clear bit leaving its pixel alone
//! where the shape is transparent. Pixels of four bytes lie on four bytes
//! and their rows' lengths are whole four bytes, of two bytes on two, and
//! a picture's sides are at most `most_side`. A picture or a shape that
//! shares memory with the rectangle it lands on is refused - its threads
//! would read what others write - and so is a scale in which one pixel
//! would be the mean of more than `most_covered` of the picture's, which
//! one thread works through alone.
//!
//! **Waiting.** As the DMA engine's: the job is sent and waited for
//! (WaitGPUCompute), the task asleep meanwhile; one not done within a
//! second is taken as a queue that no longer runs - its memory unmapped
//! all the same, the job answered RTGERR_TIMEOUT, no kernel used from
//! then on, and the log says so once.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const err = rtg.errors;
const amdgpu = sdk.resources.amdgpu;
const ExecBase = sdk.interface.exec.ExecBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const AMDGPUBase = sdk.interface.amdgpu.AMDGPUBase;

const dcn = @import("dcn.zig");
const dma_file = @import("dma.zig");
const Dma = dma_file.Dma;
const pixels = @import("kernels/pixels.zig");
const jobs = @import("kernels/jobs.zig");

/// The board's kernels as the board keeps them, beside its DMA engine.
pub const Kernels = struct {
    /// The code object the board carries.
    image: []const u8 = &.{},
    /// It loaded, and each kernel found in it.
    code: amdgpu.GPUCode = .{},
    blend_pixels: amdgpu.GPUKernel = .{},
    blend_rect: amdgpu.GPUKernel = .{},
    scale_pixels: amdgpu.GPUKernel = .{},
    blit_template: amdgpu.GPUKernel = .{},
    blit_pattern: amdgpu.GPUKernel = .{},
    /// Whether the kernels run and take the board's jobs: set and read
    /// atomically.
    ready: bool = false,
    /// Whether the log has said a job was not done: swapped atomically.
    failed: bool = false,
};

/// The kernels, by the names the code object has them under, which are
/// `Kernels`' fields too.
const kernel_names = .{ "blend_pixels", "blend_rect", "scale_pixels", "blit_template", "blit_pattern" };

/// How long a job is waited for before the queue is taken as no longer
/// running.
const job_most_ms: u32 = 1000;
/// The threads of a group, along a row, as the kernels are built for.
const group: u32 = 64;
/// The most a side of a rectangle or of a picture's part is.
const most_side: u32 = 1 << 16;
/// The most of a picture's pixels one pixel of a scale that makes it
/// smaller may be the mean of, counted as the stretches it covers across
/// and down are, each a pixel longer than the scale: one thread adds them
/// all up.
const most_covered: u64 = 4096;
/// The fewest pixels a job lands on for the board's own rule to hand it
/// to the kernels: 256 x 256, about where the time a job of theirs takes
/// however small is the cores' for the same pixels.
const least_pixels: u64 = 1 << 16;

// --- the kernels started --------------------------------------------------------------

/// The compute engine's queue started, the board's code object loaded and
/// its kernels found, by the process that starts the DMA engine's queue,
/// once that runs: the kernels take their jobs from then on. Said on the
/// log either way.
pub fn start(compute: *Kernels, sys: *ExecBase, gpu: *AMDGPUBase) void {
    if (!gpu.StartGPUCompute()) {
        exec.kprintf(sys, "%s: the compute engine's queue did not start: the board's kernels are not used\n", .{dcn.owner});
        return;
    }
    if (!gpu.LoadGPUCode(compute.image.ptr, @intCast(compute.image.len), &compute.code)) {
        exec.kprintf(sys, "%s: the board's kernels did not load: they are not used\n", .{dcn.owner});
        return;
    }
    inline for (kernel_names) |name| {
        if (!gpu.FindGPUKernel(&compute.code, name, &@field(compute, name))) {
            exec.kprintf(sys, "%s: the board's code holds no kernel %s: its kernels are not used\n", .{ dcn.owner, @as([*:0]const u8, name) });
            gpu.FreeGPUCode(&compute.code);
            return;
        }
    }
    exec.kprintf(sys, "%s: the graphics block's compute engine runs the board's kernels: pictures and colours laid, scales, and shapes and tiles in both colours over %lu pixels and more are theirs\n", .{ dcn.owner, least_pixels });
    @atomicStore(bool, &compute.ready, true, .release);
}

/// The kernels let go of as the board goes, once nothing of the process
/// starting them runs any more: no job is theirs, and their code object
/// is freed.
pub fn stop(compute: *Kernels, gpu: *AMDGPUBase) void {
    @atomicStore(bool, &compute.ready, false, .release);
    if (compute.code.bytes != 0) gpu.FreeGPUCode(&compute.code);
}

// --- the jobs ------------------------------------------------------------------------

/// BlendPixels: `picture` laid over `area` of `dest` at `alpha` by a
/// kernel - or RTGERR_NOT_SUPPORTED, nothing written, for a job the cores
/// do sooner or the kernel does not take.
pub fn blendPixels(compute: *Kernels, dma: *const Dma, sys: *ExecBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, picture: *const rtg.RtgPixels, alpha: u32) i32 {
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    if (!taken(compute, dma, @as(u64, width) * height >= least_pixels)) return err.RTGERR_NOT_SUPPORTED;
    const strength = @min(alpha, 255);
    if (strength == 0) return err.RTGERR_OK;
    if (dest.format != .bgra32) return err.RTGERR_NOT_SUPPORTED;
    _ = rgbaOf(picture.format) orelse return err.RTGERR_NOT_SUPPORTED;
    const target = Target.of(dest, area, 4) orelse return err.RTGERR_NOT_SUPPORTED;
    const part = Part.of(picture, width, height) orelse return err.RTGERR_NOT_SUPPORTED;
    if (target.meets(part.start, part.bytes)) return err.RTGERR_NOT_SUPPORTED;
    const gpu = dma.gpu.?;
    var into: amdgpu.GPUMemory = .{};
    if (!target.map(gpu, &into)) return err.RTGERR_NOT_SUPPORTED;
    defer gpu.UnmapGPUMemory(&into);
    var from: amdgpu.GPUMemory = .{};
    if (!gpu.MapGPUMemory(@ptrFromInt(part.start), @intCast(part.bytes), &from)) return err.RTGERR_NOT_SUPPORTED;
    defer gpu.UnmapGPUMemory(&from);
    const job = blendPixelsJob(dest, area, picture, alpha, target.device(into), from.device);
    return run(compute, sys, gpu, &compute.blend_pixels, &job, width, height);
}

/// What blend_pixels is handed for `picture` laid over `area` of `dest`
/// at `alpha`, the rectangle's first pixel reached at `dest_at` and the
/// picture's pixel on it at `picture_at`.
pub fn blendPixelsJob(dest: *const rtg.RtgBitMap, area: *const rtg.RtgRect, picture: *const rtg.RtgPixels, alpha: u32, dest_at: u64, picture_at: u64) jobs.BlendPixels {
    const rgba = picture.format == .rgba32;
    const whole = picture.flags & rtg.RTGPIXF_OPAQUE != 0;
    return .{
        .dest = dest_at,
        .picture = picture_at,
        .dest_pitch = dest.pitch,
        .picture_pitch = picture.pitch,
        .width = @intCast(area.width),
        .height = @intCast(area.height),
        .alpha = @min(alpha, 255),
        .flags = (if (rgba) pixels.rgba else 0) | (if (whole) pixels.whole else 0),
    };
}

/// BlendRect: `pen` laid over `area` of `dest` by its alpha by a kernel -
/// or RTGERR_NOT_SUPPORTED, nothing written.
pub fn blendRect(compute: *Kernels, dma: *const Dma, sys: *ExecBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pen: u32) i32 {
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    if (!taken(compute, dma, @as(u64, width) * height >= least_pixels)) return err.RTGERR_NOT_SUPPORTED;
    if (pen >> 24 == 0) return err.RTGERR_OK;
    if (dest.format != .bgra32) return err.RTGERR_NOT_SUPPORTED;
    const target = Target.of(dest, area, 4) orelse return err.RTGERR_NOT_SUPPORTED;
    const gpu = dma.gpu.?;
    var into: amdgpu.GPUMemory = .{};
    if (!target.map(gpu, &into)) return err.RTGERR_NOT_SUPPORTED;
    defer gpu.UnmapGPUMemory(&into);
    const job = blendRectJob(dest, area, pen, target.device(into));
    return run(compute, sys, gpu, &compute.blend_rect, &job, width, height);
}

/// What blend_rect is handed for `pen` laid over `area` of `dest`, the
/// rectangle's first pixel reached at `dest_at`.
pub fn blendRectJob(dest: *const rtg.RtgBitMap, area: *const rtg.RtgRect, pen: u32, dest_at: u64) jobs.BlendRect {
    return .{ .dest = dest_at, .dest_pitch = dest.pitch, .width = @intCast(area.width), .height = @intCast(area.height), .pen = pen };
}

/// ScalePixels: a `src_width` x `src_height` part of `picture` scaled to
/// `area` of `dest` and laid over it by a kernel - or
/// RTGERR_NOT_SUPPORTED, nothing written.
pub fn scalePixels(compute: *Kernels, dma: *const Dma, sys: *ExecBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, picture: *const rtg.RtgPixels, src_width: u32, src_height: u32) i32 {
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    if (!taken(compute, dma, @as(u64, width) * height >= least_pixels)) return err.RTGERR_NOT_SUPPORTED;
    if (width > most_side or height > most_side or src_width > most_side or src_height > most_side) return err.RTGERR_NOT_SUPPORTED;
    const shrinks = src_width > width or src_height > height;
    if (shrinks and covered(width, src_width) * covered(height, src_height) > most_covered) return err.RTGERR_NOT_SUPPORTED;
    if (dest.format != .bgra32) return err.RTGERR_NOT_SUPPORTED;
    _ = rgbaOf(picture.format) orelse return err.RTGERR_NOT_SUPPORTED;
    const target = Target.of(dest, area, 4) orelse return err.RTGERR_NOT_SUPPORTED;
    const part = Part.of(picture, src_width, src_height) orelse return err.RTGERR_NOT_SUPPORTED;
    if (target.meets(part.start, part.bytes)) return err.RTGERR_NOT_SUPPORTED;
    const gpu = dma.gpu.?;
    var into: amdgpu.GPUMemory = .{};
    if (!target.map(gpu, &into)) return err.RTGERR_NOT_SUPPORTED;
    defer gpu.UnmapGPUMemory(&into);
    var from: amdgpu.GPUMemory = .{};
    if (!gpu.MapGPUMemory(@ptrFromInt(part.start), @intCast(part.bytes), &from)) return err.RTGERR_NOT_SUPPORTED;
    defer gpu.UnmapGPUMemory(&from);
    const job = scalePixelsJob(dest, area, picture, src_width, src_height, target.device(into), from.device);
    return run(compute, sys, gpu, &compute.scale_pixels, &job, width, height);
}

/// What scale_pixels is handed for a `src_width` x `src_height` part of
/// `picture` scaled to `area` of `dest`, the rectangle's first pixel
/// reached at `dest_at` and the part's top left at `picture_at`.
pub fn scalePixelsJob(dest: *const rtg.RtgBitMap, area: *const rtg.RtgRect, picture: *const rtg.RtgPixels, src_width: u32, src_height: u32, dest_at: u64, picture_at: u64) jobs.ScalePixels {
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    const rgba = picture.format == .rgba32;
    const shrinks = src_width > width or src_height > height;
    const store = picture.flags & rtg.RTGPIXF_STORE != 0;
    return .{
        .dest = dest_at,
        .picture = picture_at,
        .dest_pitch = dest.pitch,
        .picture_pitch = picture.pitch,
        .width = width,
        .height = height,
        .src_width = src_width,
        .src_height = src_height,
        .flags = (if (rgba) pixels.rgba else 0) | (if (shrinks) pixels.shrinks else 0) | (if (store) pixels.store else 0),
    };
}

/// BlitTemplate: `shape` in its two colours over `area` of `dest` by a
/// kernel - or RTGERR_NOT_SUPPORTED, nothing written.
pub fn blitTemplate(compute: *Kernels, dma: *const Dma, sys: *ExecBase, rb: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, shape: *const rtg.RtgTemplate) i32 {
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    if (!taken(compute, dma, bothColours(shape.flags) and @as(u64, width) * height >= least_pixels)) return err.RTGERR_NOT_SUPPORTED;
    const bytes_each = shapeBytes(rb, dest.format) orelse return err.RTGERR_NOT_SUPPORTED;
    const target = Target.of(dest, area, bytes_each) orelse return err.RTGERR_NOT_SUPPORTED;
    // The rows of bits from the shape's first, each to the byte of its
    // last bit.
    const first_row: u64 = @intFromPtr(shape.bits.?) + @as(u64, shape.src_y) * shape.pitch;
    const bits_bytes = @as(u64, height - 1) * shape.pitch + (@as(u64, shape.src_x) + width + 7) / 8;
    if (bits_bytes > 0xffff_ffff or target.meets(first_row, bits_bytes)) return err.RTGERR_NOT_SUPPORTED;
    const gpu = dma.gpu.?;
    var into: amdgpu.GPUMemory = .{};
    if (!target.map(gpu, &into)) return err.RTGERR_NOT_SUPPORTED;
    defer gpu.UnmapGPUMemory(&into);
    var from: amdgpu.GPUMemory = .{};
    if (!gpu.MapGPUMemory(@ptrFromInt(first_row), @intCast(bits_bytes), &from)) return err.RTGERR_NOT_SUPPORTED;
    defer gpu.UnmapGPUMemory(&from);
    const job = blitTemplateJob(dest, area, shape, bytes_each, target.device(into), from.device);
    return run(compute, sys, gpu, &compute.blit_template, &job, width, height);
}

/// What blit_template is handed for `shape` over `area` of `dest`, of
/// `bytes_each` bytes a pixel, the rectangle's first pixel reached at
/// `dest_at` and the shape's first row of bits at `bits_at`.
pub fn blitTemplateJob(dest: *const rtg.RtgBitMap, area: *const rtg.RtgRect, shape: *const rtg.RtgTemplate, bytes_each: u32, dest_at: u64, bits_at: u64) jobs.BlitTemplate {
    return .{
        .dest = dest_at,
        .bits = bits_at,
        .dest_pitch = dest.pitch,
        .bits_pitch = shape.pitch,
        .width = @intCast(area.width),
        .height = @intCast(area.height),
        .first_bit = shape.src_x,
        .fg = shape.fg,
        .bg = shape.bg,
        .flags = shapeFlags(shape.flags, bytes_each),
    };
}

/// BlitPattern: `tile` in its two colours repeated over `area` of `dest`
/// by a kernel - or RTGERR_NOT_SUPPORTED, nothing written.
pub fn blitPattern(compute: *Kernels, dma: *const Dma, sys: *ExecBase, rb: *RtgBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, tile: *const rtg.RtgPattern) i32 {
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    if (!taken(compute, dma, bothColours(tile.flags) and @as(u64, width) * height >= least_pixels)) return err.RTGERR_NOT_SUPPORTED;
    const bytes_each = shapeBytes(rb, dest.format) orelse return err.RTGERR_NOT_SUPPORTED;
    const target = Target.of(dest, area, bytes_each) orelse return err.RTGERR_NOT_SUPPORTED;
    const tile_start: u64 = @intFromPtr(tile.bits.?);
    const tile_bytes = @as(u64, tile.height - 1) * tile.pitch + (@as(u64, tile.width) + 7) / 8;
    if (tile_bytes > 0xffff_ffff or target.meets(tile_start, tile_bytes)) return err.RTGERR_NOT_SUPPORTED;
    const gpu = dma.gpu.?;
    var into: amdgpu.GPUMemory = .{};
    if (!target.map(gpu, &into)) return err.RTGERR_NOT_SUPPORTED;
    defer gpu.UnmapGPUMemory(&into);
    var from: amdgpu.GPUMemory = .{};
    if (!gpu.MapGPUMemory(@ptrFromInt(tile_start), @intCast(tile_bytes), &from)) return err.RTGERR_NOT_SUPPORTED;
    defer gpu.UnmapGPUMemory(&from);
    const job = blitPatternJob(dest, area, tile, bytes_each, target.device(into), from.device);
    return run(compute, sys, gpu, &compute.blit_pattern, &job, width, height);
}

/// What blit_pattern is handed for `tile` over `area` of `dest`, of
/// `bytes_each` bytes a pixel, the rectangle's first pixel reached at
/// `dest_at` and the tile at `tile_at`. The tile's bit on the buffer's
/// pixel (x, y) is its bit (x less the origin, y less it), each counted
/// round the tile.
pub fn blitPatternJob(dest: *const rtg.RtgBitMap, area: *const rtg.RtgRect, tile: *const rtg.RtgPattern, bytes_each: u32, dest_at: u64, tile_at: u64) jobs.BlitPattern {
    return .{
        .dest = dest_at,
        .tile = tile_at,
        .dest_pitch = dest.pitch,
        .tile_pitch = tile.pitch,
        .width = @intCast(area.width),
        .height = @intCast(area.height),
        .first_column = @intCast(@mod(@as(i64, area.x) - tile.origin_x, @as(i64, tile.width))),
        .first_row = @intCast(@mod(@as(i64, area.y) - tile.origin_y, @as(i64, tile.height))),
        .tile_width = tile.width,
        .tile_height = tile.height,
        .fg = tile.fg,
        .bg = tile.bg,
        .flags = shapeFlags(tile.flags, bytes_each),
    };
}

/// Whether the kernels take a job, once they run: by the board's own
/// rule, what `by_size` says of it; every one where RTGCTRL_AMD_ENGINE
/// has them take every job, none where it has them take none.
fn taken(compute: *const Kernels, dma: *const Dma, by_size: bool) bool {
    if (!@atomicLoad(bool, &compute.ready, .acquire)) return false;
    return switch (dma_file.ruleOf(dma)) {
        rtg.tags.RTG_AMD_ENGINE_ALL => true,
        rtg.tags.RTG_AMD_ENGINE_NONE => false,
        else => by_size,
    };
}

/// Whether a shape or a tile is drawn in both its colours, by its
/// RtgTemplate's or RtgPattern's flags.
fn bothColours(flags: u32) bool {
    return flags & rtg.bitmaps.RTGTF_TRANSPARENT == 0;
}

/// A picture's format as the kernels take it: whether it is `rgba32`,
/// else `bgra32`. Null for any other.
fn rgbaOf(format: rtg.PixelFormat) ?bool {
    return switch (format) {
        .bgra32 => false,
        .rgba32 => true,
        else => null,
    };
}

/// Bytes a pixel of a buffer a shape or a tile is drawn on is, where the
/// kernels take it: two or four.
fn shapeBytes(rb: *RtgBase, format: rtg.PixelFormat) ?u32 {
    const bytes_each = dma_file.pixelBytes(rb, format) orelse return null;
    return if (bytes_each == 2 or bytes_each == 4) bytes_each else null;
}

/// RtgTemplate's or RtgPattern's flags as the kernels take them, on a
/// buffer of `bytes_each` bytes a pixel.
pub fn shapeFlags(flags: u32, bytes_each: u32) u32 {
    var kernel_flags: u32 = 0;
    if (flags & rtg.bitmaps.RTGTF_TRANSPARENT != 0) kernel_flags |= pixels.transparent;
    if (flags & rtg.bitmaps.RTGTF_INVERT != 0) kernel_flags |= pixels.invert;
    if (bytes_each == 2) kernel_flags |= pixels.halves;
    return kernel_flags;
}

/// How many of a picture's pixels along one axis the stretch one pixel
/// of a scale covers can reach.
fn covered(size: u32, src_size: u32) u64 {
    return (@as(u64, src_size) + size - 1) / size + 1;
}

/// The rectangle of a buffer a job lands on: the buffer's rows from the
/// rectangle's first to its last, and where in them it lies.
const Target = struct {
    bitmap: *rtg.RtgBitMap,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    bytes_each: u32,

    /// `area` of `bitmap`, of `bytes_each` bytes a pixel: null for a
    /// buffer the kernels do not draw on - its pixels or rows not on
    /// their size.
    fn of(bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, bytes_each: u32) ?Target {
        const buffer = bitmap.pixels orelse return null;
        if (@intFromPtr(buffer) % bytes_each != 0 or bitmap.pitch % bytes_each != 0 or bitmap.pitch == 0) return null;
        if (area.width > most_side or area.height > most_side) return null;
        return .{ .bitmap = bitmap, .x = @intCast(area.x), .y = @intCast(area.y), .width = @intCast(area.width), .height = @intCast(area.height), .bytes_each = bytes_each };
    }

    /// Its rows mapped for the job into `into`.
    fn map(target: Target, gpu: *AMDGPUBase, into: *amdgpu.GPUMemory) bool {
        return dma_file.mapRows(gpu, target.bitmap.pixels.?, target.bitmap.pitch, target.y, target.height, (target.x + target.width) * target.bytes_each, into);
    }

    /// The device's address of its first pixel, its rows mapped at `into`.
    fn device(target: Target, into: amdgpu.GPUMemory) u64 {
        return into.device + @as(u64, target.x) * target.bytes_each;
    }

    /// Whether `bytes` from `first` share memory with the rows it lands
    /// on.
    fn meets(target: Target, first: u64, bytes: u64) bool {
        const corner = @intFromPtr(target.bitmap.pixels.?) + @as(u64, target.y) * target.bitmap.pitch + @as(u64, target.x) * target.bytes_each;
        const end = corner + @as(u64, target.height - 1) * target.bitmap.pitch + @as(u64, target.width) * target.bytes_each;
        return first < end and corner < first + bytes;
    }
};

/// The part of a picture a job reads: from its pixel at its corner, the
/// rows of `width` pixels of four bytes, `height` of them.
const Part = struct {
    start: u64,
    bytes: u64,

    /// Null for a picture whose corner is before its first byte, or whose
    /// pixels or rows are not on four bytes.
    fn of(picture: *const rtg.RtgPixels, width: u32, height: u32) ?Part {
        if (picture.x < 0 or picture.y < 0 or width > most_side or height > most_side) return null;
        const first = picture.pixels orelse return null;
        const corner = @intFromPtr(first) + @as(u64, @intCast(picture.y)) * picture.pitch + @as(u64, @intCast(picture.x)) * 4;
        if (corner % 4 != 0 or picture.pitch % 4 != 0) return null;
        const bytes = @as(u64, height - 1) * picture.pitch + @as(u64, width) * 4;
        if (bytes > 0xffff_ffff) return null;
        return .{ .start = corner, .bytes = bytes };
    }
};

/// One dispatch of `kernel` over `width` x `height` pixels, handed
/// `job`, sent and waited for: RTGERR_OK once it is done;
/// RTGERR_NOT_SUPPORTED, nothing written, where it was not sent. One not
/// done within `job_most_ms` is taken as a queue that no longer runs - no
/// job is the kernels' from then on - and said once.
fn run(compute: *Kernels, sys: *ExecBase, gpu: *AMDGPUBase, kernel: *const amdgpu.GPUKernel, job: anytype, width: u32, height: u32) i32 {
    const dispatch: amdgpu.GPUDispatch = .{
        // A group more than the pixels fill, for the part of the first
        // group's span before the row's first pixel.
        .groups = .{ (width + 2 * group - 2) / group, height, 1 },
        .threads = .{ group, 1, 1 },
        .arguments = job,
        .argument_bytes = @sizeOf(@TypeOf(job.*)),
    };
    const sent = gpu.SendGPUKernel(kernel, &dispatch);
    if (sent == 0) return err.RTGERR_NOT_SUPPORTED;
    if (gpu.WaitGPUCompute(sent, job_most_ms)) return err.RTGERR_OK;
    @atomicStore(bool, &compute.ready, false, .release);
    if (!@atomicRmw(bool, &compute.failed, .Xchg, true, .acq_rel)) {
        exec.kprintf(sys, "%s: a job of the board's kernels was not done within %u ms: they are not used from now on\n", .{ dcn.owner, job_most_ms });
    }
    return err.RTGERR_TIMEOUT;
}

// --- tests (host: ./zig build test) -----------------------------------------
//
// A scale's work for one thread; the jobs themselves, built here and run
// on the host over the library's own pixels, are in kernels/tests.zig.

const testing = @import("std").testing;

test "every job fits the arguments a dispatch hands a kernel" {
    inline for (.{ jobs.BlendPixels, jobs.BlendRect, jobs.ScalePixels, jobs.BlitTemplate, jobs.BlitPattern }) |Job| {
        try testing.expect(@sizeOf(Job) <= amdgpu.GPUKERNEL_ARGUMENTS_MAX);
    }
}

test "a scale's pixel covers the picture's stretch, a pixel longer than the scale either way" {
    try testing.expectEqual(@as(u64, 2), covered(100, 100));
    try testing.expectEqual(@as(u64, 5), covered(640, 2560));
    try testing.expectEqual(@as(u64, 6), covered(600, 2560));
    // 64 times smaller either way is more than one thread is given.
    try testing.expect(covered(40, 2560) * covered(45, 2880) > most_covered);
    try testing.expect(covered(160, 2560) * covered(180, 2880) <= most_covered);
}
