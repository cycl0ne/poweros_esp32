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
//! cores. A job that reads the device's own memory - a picture or a
//! colour laid over a buffer there, a scale laid over one, a picture
//! there - is theirs from fewer pixels, as the cores read that memory
//! uncached: from `blend_reading`, `colour_reading` and `scale_reading`,
//! each with a size where the machine has that memory and one for its
//! memory window. A colour takes the cores a steady time a pixel, so its
//! sizes are where that passes the kernels' job, bracketed by `C:test/Gpu
//! KERNELS DEVICE` and `WINDOW`, the least of three runs: where the
//! machine has the memory the cores take 0.25 us a pixel, 95 us over 16 x
//! 24 pixels against the kernels' 70 to 91 and 63 to 65 over 16 x 16
//! against 77 to 91; through the window 1.0 to 1.3 us, 82 to 104 over 8 x
//! 8 against the kernels' 64 to 91 - quicker in four of five rounds of
//! three runs - and 41 to 60 over 8 x 4 against 66 to 90. A picture's and
//! a scale's time goes by the share of its pixels that cover partly, as
//! only those read what they land on, so theirs stay the sizes tried with
//! the test's pictures: where the machine has the memory, a picture laid
//! over 64 x 64 pixels took the kernels 93 us and the cores 410, over 32
//! x 32 the cores 5; a scale from 64 to 128 pixels a side 127 and 1099,
//! from 32 to 64 the cores 71 against 99 to 122; through the window a
//! scale from 32 to 64 189 against 109, from 16 to 32 24 against 114.
//! Shapes and tiles, which do not read what they land on, keep the rule
//! for any memory.
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
//! **Waiting.** The job is sent and waited for (WaitGPUCompute), the task
//! asleep meanwhile. One not done within a second has the queue reset
//! (ResetGPUCompute), which gives up the jobs it ends and writes the rest
//! to the queue again: where this one is written again, it is waited for
//! again; where it is given up - by that reset, or by another task's - it
//! is sent again at once and waited for the same way, the log saying so,
//! and how many of its waves had set their marks; given up a second time,
//! it is answered RTGERR_TIMEOUT - its memory unmapped all the same, and
//! the library draws it - and the kernels go on. A job written or sent
//! again may have been drawn in part, or whole. A shape, a tile and a
//! stored scale come out the same; a job that lays what it lands on - a
//! picture, a colour, a scale laid - goes by its marks, a byte for each
//! wave of its groups, which its kernel sets once the wave has laid its
//! pixels, and a wave whose mark is set leaves its pixels as they are
//! (`kernels/jobs.zig`). A job's marks are one of the `marks_pieces` pieces
//! of `marks_piece_bytes` of the machine's memory the board maps once its
//! kernels are found, cached in the graphics block (GPUMAP_CACHED). On the
//! NucBox they take the large jobs 1 to 5 per cent longer - a blend over
//! 2560 x 2880 pixels 2348 us against 2325 without them, a scale up by 2
//! 3633 against 3567; uncached, as the pixels are, each wave's read and
//! write of its mark was a trip to the memory of its own, and those took
//! 6110 and 6823 us. A job whose marks are past a piece, or that finds
//! every piece taken, is the library's. A job's marks are set when they
//! hold its generation, a piece's next as the job takes it, so the CPU
//! clears a piece only once its generations have gone round. A job answered
//! RTGERR_TIMEOUT may leave what its waves wrote in its piece in the
//! block's cache, to be written back at any time, over a clearing too; so
//! the piece is marked until a job of it is done, whose start writes the
//! cache back, and a marked piece whose generations have gone round is
//! cleared once a job of nothing sent first is done - the job is the
//! library's where that one is not. The reset lets the queue's waves finish
//! before it gives a job up, so that each wave of it has laid its pixels
//! and set its mark, or not begun: on the NucBox nine resets 200 to 1000 us
//! into a job give it up with 6 to 61 per cent of its waves done, and every
//! pixel comes out the library's; with the waves reset at once, 1009 pixels
//! were laid twice, a wave's at a time. Only waves still running after 100
//! ms - a kernel's that spins - are reset then, by when the board's, of
//! some microseconds each, have finished; and where a job sent again is
//! given up as well, the library lays the whole of it over what the kernels
//! laid. Where the queue cannot be reset, the resource resets the whole
//! graphics block, which gives up every job not done, the board's with
//! them, and starts the queues again - the board's job is sent again then
//! as after any reset that gives it up, the block's caches having been
//! written back first, so that every mark set is in memory. Where the
//! block cannot be reset either no kernel is used from then on, and the
//! log says so once.

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
    /// The jobs' marks: `marks_pieces` pieces of `marks_piece_bytes`, one
    /// block of the machine's memory mapped at `marks_mapped`, cached in
    /// the graphics block; a bit for each piece not taken, and one for
    /// each whose last job sent was given up, so that the block's cache
    /// may hold lines of it not written back - set and cleared
    /// atomically; and the generation each piece last gave a job, 0
    /// before the first, read and written by the job holding it.
    marks: ?[*]u8 = null,
    marks_mapped: amdgpu.GPUMemory = .{},
    marks_free: u32 = 0,
    marks_dirty: u32 = 0,
    generations: [marks_pieces]u8 = @splat(0),
};

/// The kernels, by the names the code object has them under, which are
/// `Kernels`' fields too.
const kernel_names = .{ "blend_pixels", "blend_rect", "scale_pixels", "blit_template", "blit_pattern" };

/// How long a job is waited for before the queue is taken as no longer
/// running, and what the log says of a job the board gave up so.
const job_most_ms: u32 = 1000;
const not_done_in_time = @import("std").fmt.comptimePrint("was not done within {d} ms: given up, the queue reset", .{job_most_ms});
/// The threads of a group, along a row, as the kernels are built for.
const group = jobs.group;
/// The pieces of the machine's memory for jobs' marks, and the bytes of
/// each: a byte for each wave of a job's groups, so that a piece holds
/// the marks of a job over 7680 x 4320 pixels, 1045440 bytes, and of
/// smaller ones.
const marks_pieces: u5 = 4;
const marks_piece_bytes: u32 = 1024 * 1024;
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

/// The fewest pixels a job that reads the device's own memory - a buffer
/// it lays over, or a picture it lays - lands on for the board's own rule
/// to hand it to the kernels, where the machine has that memory and
/// through the memory window: about where the kernels, some 60 to 120 us
/// a job however small, are sooner than the cores, which read that memory
/// uncached - a picture laid, a colour, a scale. A colour takes the cores
/// a steady time a pixel, 0.25 us where the machine has the memory and
/// 1.0 to 1.3 through the window, so its sizes are where that passes the
/// kernels' job; a picture's and a scale's time goes by how many of its
/// pixels cover partly, as only those read what they land on, so theirs
/// are the sizes tried where the kernels were sooner.
const Reading = struct { machine: u64, window: u64 };
const blend_reading: Reading = .{ .machine = 64 * 64, .window = 64 * 64 };
const colour_reading: Reading = .{ .machine = 16 * 24, .window = 8 * 8 };
const scale_reading: Reading = .{ .machine = 128 * 64, .window = 64 * 64 };

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
    const marks_bytes = @as(u32, marks_pieces) * marks_piece_bytes;
    // The board's for as long as it lives, past the process starting it.
    const marks = sys.AllocVec(marks_bytes, exec.MEMF_ANY | exec.MEMF_SYSTEM) orelse {
        exec.kprintf(sys, "%s: no memory for the marks of the board's kernels' jobs: the kernels are not used\n", .{dcn.owner});
        gpu.FreeGPUCode(&compute.code);
        return;
    };
    if (!gpu.MapGPUMemory(marks, marks_bytes, amdgpu.GPUMAP_CACHED, &compute.marks_mapped)) {
        exec.kprintf(sys, "%s: the marks of the board's kernels' jobs are not mapped: the kernels are not used\n", .{dcn.owner});
        sys.FreeVec(marks);
        gpu.FreeGPUCode(&compute.code);
        return;
    }
    compute.marks = @ptrCast(marks);
    compute.generations = @splat(0);
    @atomicStore(u32, &compute.marks_dirty, 0, .release);
    @atomicStore(u32, &compute.marks_free, (@as(u32, 1) << marks_pieces) - 1, .release);
    exec.kprintf(sys, "%s: the graphics block's compute engine runs the board's kernels: pictures and colours laid, scales, and shapes and tiles in both colours over %lu pixels and more are theirs, and fewer where they read the device's own memory\n", .{ dcn.owner, least_pixels });
    @atomicStore(bool, &compute.ready, true, .release);
}

/// The kernels let go of as the board goes, once nothing of the process
/// starting them runs any more: no job is theirs, their code object is
/// freed, and so are the jobs' marks - where a piece's last job was given
/// up, once a job of nothing is done, which writes back what the graphics
/// block's cache may still hold of it; where that job is not done, the
/// marks are left as they are, and the log says so.
pub fn stop(compute: *Kernels, sys: *ExecBase, gpu: *AMDGPUBase) void {
    @atomicStore(bool, &compute.ready, false, .release);
    if (compute.code.bytes != 0) gpu.FreeGPUCode(&compute.code);
    const marks = compute.marks orelse return;
    if (@atomicLoad(u32, &compute.marks_dirty, .acquire) != 0 and !cacheWrittenBack(gpu)) {
        exec.kprintf(sys, "%s: the marks of the board's kernels' jobs are kept, as the graphics block's cache may still write them\n", .{dcn.owner});
        return;
    }
    gpu.UnmapGPUMemory(&compute.marks_mapped);
    sys.FreeVec(marks);
    compute.marks = null;
}

/// Whether a job of nothing sent now is done within `job_most_ms`: its
/// start and its end write the graphics block's caches back.
fn cacheWrittenBack(gpu: *AMDGPUBase) bool {
    const nothing = [_]u32{0};
    const job = gpu.SendGPUCompute(&nothing, 0);
    return job != 0 and gpu.WaitGPUCompute(job, job_most_ms);
}

// --- the jobs' marks -----------------------------------------------------------------

/// A job's marks (`kernels/jobs.zig`): a piece of the board's, and the
/// generation that sets them.
const Marks = struct {
    /// Where the engine reaches them.
    device: u64,
    generation: u8,
    piece: u5,

    /// The marks of a job over `width` x `height` pixels: a free piece at
    /// its next generation, cleared first where its generations have gone
    /// round - once a job of nothing is done, where the piece's last job
    /// sent was given up; null where they are past a piece, every piece
    /// is taken, or that job is not done.
    fn take(compute: *Kernels, sys: *ExecBase, gpu: *AMDGPUBase, width: u32, height: u32) ?Marks {
        if (marksBytes(width, height) > marks_piece_bytes) return null;
        const marks = compute.marks orelse return null;
        const piece = takePiece(&compute.marks_free) orelse return null;
        const offset = @as(usize, piece) * marks_piece_bytes;
        const generation = nextGeneration(compute.generations[piece]);
        if (generation == 1) {
            const bit = @as(u32, 1) << piece;
            if (@atomicLoad(u32, &compute.marks_dirty, .acquire) & bit != 0) {
                if (!cacheWrittenBack(gpu)) {
                    givePiece(&compute.marks_free, piece);
                    return null;
                }
                _ = @atomicRmw(u32, &compute.marks_dirty, .And, ~bit, .acq_rel);
            }
            sys.SetMem(marks + offset, 0, marks_piece_bytes);
        }
        compute.generations[piece] = generation;
        return .{ .device = compute.marks_mapped.device + offset, .generation = generation, .piece = piece };
    }

    /// The piece given back once its job is answered `status`, and
    /// `status` answered: marked where the job was given up
    /// (RTGERR_TIMEOUT), as the graphics block's cache may still hold what
    /// its waves wrote there, and no longer where it is done (RTGERR_OK),
    /// its start having written the cache back; as it was where the job
    /// was never sent.
    fn after(marks: Marks, compute: *Kernels, status: i32) i32 {
        const bit = @as(u32, 1) << marks.piece;
        if (status == err.RTGERR_TIMEOUT) {
            _ = @atomicRmw(u32, &compute.marks_dirty, .Or, bit, .acq_rel);
        } else if (status == err.RTGERR_OK) {
            _ = @atomicRmw(u32, &compute.marks_dirty, .And, ~bit, .acq_rel);
        }
        givePiece(&compute.marks_free, marks.piece);
        return status;
    }
};

/// The generation a piece gives its next job after `last`: 1 to 255, 1
/// again after 255 - and 1 the first time - when the piece is cleared
/// first, as a mark may hold any generation before.
fn nextGeneration(last: u8) u8 {
    return if (last == 0xFF) 1 else last + 1;
}

/// The bytes of the marks of a job over `width` x `height` pixels: a
/// byte for each wave of its groups.
pub fn marksBytes(width: u32, height: u32) u64 {
    return @as(u64, jobs.wavesAcross(width)) * height;
}

/// A piece not taken of those whose bits `free` holds, taken - its bit
/// cleared - or null where every one is.
fn takePiece(free: *u32) ?u5 {
    var seen = @atomicLoad(u32, free, .acquire);
    while (seen != 0) {
        const piece: u5 = @intCast(@ctz(seen));
        seen = @cmpxchgWeak(u32, free, seen, seen & ~(@as(u32, 1) << piece), .acq_rel, .acquire) orelse return piece;
    }
    return null;
}

/// Piece `piece` given back: its bit set.
fn givePiece(free: *u32, piece: u5) void {
    _ = @atomicRmw(u32, free, .Or, @as(u32, 1) << piece, .release);
}

// --- the jobs ------------------------------------------------------------------------

/// BlendPixels: `picture` laid over `area` of `dest` at `alpha` by a
/// kernel - or RTGERR_NOT_SUPPORTED, nothing written, for a job the cores
/// do sooner or the kernel does not take.
pub fn blendPixels(compute: *Kernels, dma: *const Dma, sys: *ExecBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, picture: *const rtg.RtgPixels, alpha: u32) i32 {
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    const least = @min(leastFor(dma, dest.pixels, blend_reading), leastFor(dma, picture.pixels, blend_reading));
    if (!taken(compute, dma, @as(u64, width) * height >= least)) return err.RTGERR_NOT_SUPPORTED;
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
    if (!gpu.MapGPUMemory(@ptrFromInt(part.start), @intCast(part.bytes), 0, &from)) return err.RTGERR_NOT_SUPPORTED;
    defer gpu.UnmapGPUMemory(&from);
    const marks = Marks.take(compute, sys, gpu, width, height) orelse return err.RTGERR_NOT_SUPPORTED;
    const job = blendPixelsJob(dest, area, picture, alpha, target.device(into), from.device, marks.device, marks.generation);
    return marks.after(compute, run(compute, sys, gpu, &compute.blend_pixels, &job, width, height));
}

/// What blend_pixels is handed for `picture` laid over `area` of `dest`
/// at `alpha`, the rectangle's first pixel reached at `dest_at`, the
/// picture's pixel on it at `picture_at` and the job's marks at
/// `marks_at`, set by `generation`.
pub fn blendPixelsJob(dest: *const rtg.RtgBitMap, area: *const rtg.RtgRect, picture: *const rtg.RtgPixels, alpha: u32, dest_at: u64, picture_at: u64, marks_at: u64, generation: u8) jobs.BlendPixels {
    const rgba = picture.format == .rgba32;
    const whole = picture.flags & rtg.RTGPIXF_OPAQUE != 0;
    return .{
        .dest = dest_at,
        .picture = picture_at,
        .marks = marks_at,
        .dest_pitch = dest.pitch,
        .picture_pitch = picture.pitch,
        .width = @intCast(area.width),
        .height = @intCast(area.height),
        .alpha = @min(alpha, 255),
        .flags = (if (rgba) pixels.rgba else 0) | (if (whole) pixels.whole else 0),
        .generation = generation,
    };
}

/// BlendRect: `pen` laid over `area` of `dest` by its alpha by a kernel -
/// or RTGERR_NOT_SUPPORTED, nothing written.
pub fn blendRect(compute: *Kernels, dma: *const Dma, sys: *ExecBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pen: u32) i32 {
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    if (!taken(compute, dma, @as(u64, width) * height >= leastFor(dma, dest.pixels, colour_reading))) return err.RTGERR_NOT_SUPPORTED;
    if (pen >> 24 == 0) return err.RTGERR_OK;
    if (dest.format != .bgra32) return err.RTGERR_NOT_SUPPORTED;
    const target = Target.of(dest, area, 4) orelse return err.RTGERR_NOT_SUPPORTED;
    const gpu = dma.gpu.?;
    var into: amdgpu.GPUMemory = .{};
    if (!target.map(gpu, &into)) return err.RTGERR_NOT_SUPPORTED;
    defer gpu.UnmapGPUMemory(&into);
    const marks = Marks.take(compute, sys, gpu, width, height) orelse return err.RTGERR_NOT_SUPPORTED;
    const job = blendRectJob(dest, area, pen, target.device(into), marks.device, marks.generation);
    return marks.after(compute, run(compute, sys, gpu, &compute.blend_rect, &job, width, height));
}

/// What blend_rect is handed for `pen` laid over `area` of `dest`, the
/// rectangle's first pixel reached at `dest_at` and the job's marks at
/// `marks_at`, set by `generation`.
pub fn blendRectJob(dest: *const rtg.RtgBitMap, area: *const rtg.RtgRect, pen: u32, dest_at: u64, marks_at: u64, generation: u8) jobs.BlendRect {
    return .{ .dest = dest_at, .marks = marks_at, .dest_pitch = dest.pitch, .width = @intCast(area.width), .height = @intCast(area.height), .pen = pen, .generation = generation };
}

/// ScalePixels: a `src_width` x `src_height` part of `picture` scaled to
/// `area` of `dest` and laid over it by a kernel - or
/// RTGERR_NOT_SUPPORTED, nothing written.
pub fn scalePixels(compute: *Kernels, dma: *const Dma, sys: *ExecBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, picture: *const rtg.RtgPixels, src_width: u32, src_height: u32) i32 {
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    // A stored scale does not read the buffer it lands on.
    const lays = picture.flags & rtg.RTGPIXF_STORE == 0;
    const dest_least = if (lays) leastFor(dma, dest.pixels, scale_reading) else least_pixels;
    const least = @min(dest_least, leastFor(dma, picture.pixels, scale_reading));
    if (!taken(compute, dma, @as(u64, width) * height >= least)) return err.RTGERR_NOT_SUPPORTED;
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
    if (!gpu.MapGPUMemory(@ptrFromInt(part.start), @intCast(part.bytes), 0, &from)) return err.RTGERR_NOT_SUPPORTED;
    defer gpu.UnmapGPUMemory(&from);
    const marks = Marks.take(compute, sys, gpu, width, height) orelse return err.RTGERR_NOT_SUPPORTED;
    const job = scalePixelsJob(dest, area, picture, src_width, src_height, target.device(into), from.device, marks.device, marks.generation);
    return marks.after(compute, run(compute, sys, gpu, &compute.scale_pixels, &job, width, height));
}

/// What scale_pixels is handed for a `src_width` x `src_height` part of
/// `picture` scaled to `area` of `dest`, the rectangle's first pixel
/// reached at `dest_at`, the part's top left at `picture_at` and the
/// job's marks at `marks_at`, set by `generation`.
pub fn scalePixelsJob(dest: *const rtg.RtgBitMap, area: *const rtg.RtgRect, picture: *const rtg.RtgPixels, src_width: u32, src_height: u32, dest_at: u64, picture_at: u64, marks_at: u64, generation: u8) jobs.ScalePixels {
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    const rgba = picture.format == .rgba32;
    const shrinks = src_width > width or src_height > height;
    const store = picture.flags & rtg.RTGPIXF_STORE != 0;
    return .{
        .dest = dest_at,
        .picture = picture_at,
        .marks = marks_at,
        .dest_pitch = dest.pitch,
        .picture_pitch = picture.pitch,
        .width = width,
        .height = height,
        .src_width = src_width,
        .src_height = src_height,
        .flags = (if (rgba) pixels.rgba else 0) | (if (shrinks) pixels.shrinks else 0) | (if (store) pixels.store else 0),
        .generation = generation,
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
    if (!gpu.MapGPUMemory(@ptrFromInt(first_row), @intCast(bits_bytes), 0, &from)) return err.RTGERR_NOT_SUPPORTED;
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
    if (!gpu.MapGPUMemory(@ptrFromInt(tile_start), @intCast(tile_bytes), 0, &from)) return err.RTGERR_NOT_SUPPORTED;
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

/// The fewest pixels a job that reads the memory at `memory` lands on for
/// the board's own rule to hand it to the kernels: `least_pixels`, or
/// fewer, as `reading` says, where that is the device's own memory.
fn leastFor(dma: *const Dma, memory: ?[*]const u8, reading: Reading) u64 {
    const first = memory orelse return least_pixels;
    return switch (dma_file.deviceMemoryOf(dma, @intFromPtr(first))) {
        .not => least_pixels,
        .machine => @min(reading.machine, least_pixels),
        .window => @min(reading.window, least_pixels),
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
/// done within `job_most_ms` has the queue reset, and is waited for again
/// where the reset writes it to the queue again; given up, it is sent
/// again at once, said, and waited for the same way - given up a second
/// time, or not taken again, it is answered RTGERR_TIMEOUT, said. Where
/// the queue cannot be reset no job is the kernels' from then on, said
/// once.
fn run(compute: *Kernels, sys: *ExecBase, gpu: *AMDGPUBase, kernel: *const amdgpu.GPUKernel, job: anytype, width: u32, height: u32) i32 {
    const dispatch: amdgpu.GPUDispatch = .{
        // A group more than the pixels fill, for the part of the first
        // group's span before the row's first pixel.
        .groups = .{ (width + 2 * group - 2) / group, height, 1 },
        .threads = .{ group, 1, 1 },
        .arguments = job,
        .argument_bytes = @sizeOf(@TypeOf(job.*)),
    };
    var sent = gpu.SendGPUKernel(kernel, &dispatch);
    if (sent == 0) return err.RTGERR_NOT_SUPPORTED;
    var again = false;
    while (true) {
        // A reset that gave up a job before this one leaves it on the
        // queue; one that gave it up - this task's or another's - answers
        // it false at once, and the next finds nothing to reset.
        var reset_here = false;
        while (!gpu.WaitGPUCompute(sent, job_most_ms)) {
            if (gpu.ResetGPUCompute(sent, 0) == 0) break;
            reset_here = true;
        }
        if (gpu.WaitGPUCompute(sent, 0)) return err.RTGERR_OK;
        var state: amdgpu.GPUComputeState = .{};
        if (!gpu.GetGPUComputeState(&state)) break;
        if (again) {
            if (reset_here) {
                exec.kprintf(sys, "%s: a job of the board's kernels sent again was not done within %u ms either: given up, the queue reset\n", .{ dcn.owner, job_most_ms });
            } else exec.kprintf(sys, "%s: a job of the board's kernels sent again was given up by a reset of the queue as well\n", .{dcn.owner});
            return err.RTGERR_TIMEOUT;
        }
        const why: [*:0]const u8 = if (reset_here) not_done_in_time else "was given up by a reset of the queue";
        const marked = markedWaves(compute, job);
        // Its waves that laid their pixels marked, it is sent again for
        // the rest.
        sent = gpu.SendGPUKernel(kernel, &dispatch);
        if (sent == 0) {
            exec.kprintf(sys, "%s: a job of the board's kernels %s, and was not taken again\n", .{ dcn.owner, why });
            return err.RTGERR_TIMEOUT;
        }
        if (marked.all != 0) {
            exec.kprintf(sys, "%s: a job of the board's kernels %s, %lu of its %lu waves' marks set, and was sent again as job %u\n", .{ dcn.owner, why, marked.set, marked.all, sent });
        } else exec.kprintf(sys, "%s: a job of the board's kernels %s, and was sent again as job %u\n", .{ dcn.owner, why, sent });
        again = true;
    }
    @atomicStore(bool, &compute.ready, false, .release);
    if (!@atomicRmw(bool, &compute.failed, .Xchg, true, .acq_rel)) {
        exec.kprintf(sys, "%s: a job of the board's kernels was not done within %u ms, and the queue cannot be reset: they are not used from now on\n", .{ dcn.owner, job_most_ms });
    }
    return err.RTGERR_TIMEOUT;
}

/// The waves of `job` whose marks hold its generation, as the CPU reads
/// them once a reset has given the job up and its end has come, which
/// writes the graphics block's cache back; and all its waves - both 0 for
/// a job without marks.
fn markedWaves(compute: *const Kernels, job: anytype) struct { set: u64, all: u64 } {
    if (!@hasField(@TypeOf(job.*), "marks")) return .{ .set = 0, .all = 0 };
    const marks = compute.marks orelse return .{ .set = 0, .all = 0 };
    const all = marksBytes(job.width, job.height);
    const first = marks + @as(usize, @intCast(job.marks - compute.marks_mapped.device));
    const generation: u8 = @truncate(job.generation);
    var set: u64 = 0;
    for (first[0..@intCast(all)]) |mark| set += @intFromBool(mark == generation);
    return .{ .set = set, .all = all };
}

// --- tests (host: ./zig build test) -----------------------------------------
//
// A scale's work for one thread; the jobs themselves, built here and run
// on the host over the library's own pixels, are in kernels/tests.zig.

const testing = @import("std").testing;

test "a job reading the device's memory is the kernels' from fewer pixels" {
    var dma: Dma = .{};
    dma.device_memory = .{ .{ .start = 0x8_4000_0000, .bytes = 512 << 20 }, .{ .start = 0x7c_0000_0000, .bytes = 256 << 20 } };
    try testing.expectEqual(least_pixels, leastFor(&dma, @ptrFromInt(0x1000_0000), colour_reading));
    try testing.expectEqual(least_pixels, leastFor(&dma, null, colour_reading));
    try testing.expectEqual(colour_reading.machine, leastFor(&dma, @ptrFromInt(0x8_4000_0000 + 64), colour_reading));
    try testing.expectEqual(colour_reading.window, leastFor(&dma, @ptrFromInt(0x7c_0000_0000), colour_reading));
    try testing.expectEqual(blend_reading.machine, leastFor(&dma, @ptrFromInt(0x8_4000_0000), blend_reading));
}

test "every job fits the arguments a dispatch hands a kernel" {
    inline for (.{ jobs.BlendPixels, jobs.BlendRect, jobs.ScalePixels, jobs.BlitTemplate, jobs.BlitPattern }) |Job| {
        try testing.expect(@sizeOf(Job) <= amdgpu.GPUKERNEL_ARGUMENTS_MAX);
    }
}

test "a job's marks are a piece of the board's while one is free, each taken once and given back" {
    var free: u32 = (@as(u32, 1) << marks_pieces) - 1;
    var taken_pieces: u32 = 0;
    for (0..marks_pieces) |_| {
        const piece = takePiece(&free) orelse return error.NoPiece;
        try testing.expect(taken_pieces & @as(u32, 1) << piece == 0);
        taken_pieces |= @as(u32, 1) << piece;
    }
    try testing.expectEqual(@as(?u5, null), takePiece(&free));
    givePiece(&free, 2);
    try testing.expectEqual(@as(?u5, 2), takePiece(&free));
    try testing.expectEqual(@as(?u5, null), takePiece(&free));
    // A piece holds the marks of a job over 7680 x 4320 pixels.
    try testing.expect(marksBytes(7680, 4320) <= marks_piece_bytes);
}

test "a piece's generations go from 1 to 255, and round to 1, when it is cleared" {
    try testing.expectEqual(@as(u8, 1), nextGeneration(0));
    try testing.expectEqual(@as(u8, 2), nextGeneration(1));
    try testing.expectEqual(@as(u8, 255), nextGeneration(254));
    try testing.expectEqual(@as(u8, 1), nextGeneration(255));
}

test "a piece is given back however its job ends, marked once the job is given up until one of it is done" {
    var compute: Kernels = .{};
    const marks: Marks = .{ .device = 0x4_0000, .generation = 7, .piece = 2 };
    const piece_bit: u32 = 1 << 2;
    // Given up: marked, and given back all the same.
    try testing.expectEqual(err.RTGERR_TIMEOUT, marks.after(&compute, err.RTGERR_TIMEOUT));
    try testing.expectEqual(piece_bit, compute.marks_dirty);
    try testing.expectEqual(piece_bit, compute.marks_free);
    // Never sent: as it was.
    compute.marks_free = 0;
    try testing.expectEqual(err.RTGERR_NOT_SUPPORTED, marks.after(&compute, err.RTGERR_NOT_SUPPORTED));
    try testing.expectEqual(piece_bit, compute.marks_dirty);
    try testing.expectEqual(piece_bit, compute.marks_free);
    // Another piece's job done: this one's mark kept.
    compute.marks_free = 0;
    const other: Marks = .{ .device = 0x4_0000, .generation = 3, .piece = 0 };
    try testing.expectEqual(err.RTGERR_OK, other.after(&compute, err.RTGERR_OK));
    try testing.expectEqual(piece_bit, compute.marks_dirty);
    try testing.expectEqual(@as(u32, 1), compute.marks_free);
    // Its own job done: no longer marked.
    try testing.expectEqual(err.RTGERR_OK, marks.after(&compute, err.RTGERR_OK));
    try testing.expectEqual(@as(u32, 0), compute.marks_dirty);
    try testing.expectEqual(@as(u32, 1) | piece_bit, compute.marks_free);
}

test "a scale's pixel covers the picture's stretch, a pixel longer than the scale either way" {
    try testing.expectEqual(@as(u64, 2), covered(100, 100));
    try testing.expectEqual(@as(u64, 5), covered(640, 2560));
    try testing.expectEqual(@as(u64, 6), covered(600, 2560));
    // 64 times smaller either way is more than one thread is given.
    try testing.expect(covered(40, 2560) * covered(45, 2880) > most_covered);
    try testing.expect(covered(160, 2560) * covered(180, 2880) <= most_covered);
}
