// SPDX-License-Identifier: MPL-2.0
//! The board's engine: FillRect, CopyRect and CopyRects done by the
//! graphics block's DMA engine, whose queue amdgpu.resource runs, on the
//! memory the buffers are in - the machine's, or the device's own.
//!
//! **Which jobs.** The CPU's cores fill and copy what their caches hold
//! many times sooner than the engine reaches the memory; once a job's
//! rectangles are more than the caches hold, the cores work at the
//! memory's own speed, and the engine is as quick and leaves them free.
//! So a job is the engine's where the memory it reads and writes - a
//! fill's rectangle, a copy's source and destination - is more than the
//! CPU's caches below the memory hold together (`cachedBytes`). A copy
//! from the device's own memory, which the cores read uncached, is the
//! engine's from fewer bytes: more than `reading_bytes` of its two
//! rectangles where the machine has that memory, more than
//! `window_reading_bytes` through its memory window. Every smaller job is
//! answered RTGERR_NOT_SUPPORTED before anything is written, and
//! graphics.library does it on the cores. The board's
//! kernels (`kernels.zig`) have rules of their own, and
//! RTGCTRL_AMD_ENGINE sets another for both - every job, or none - for a
//! program that times the engines against the cores (`setRule`). On the NucBox,
//! whose caches hold 24 MiB, with the rectangles just written by the CPU:
//! a copy between two buffers of 10 MiB took the engine 534 us and the
//! cores 69, of 14 MiB 891 and 1166; a fill of 20 MiB 888 and 603, of
//! 28 MiB 1220 and 1257. From a buffer of the device's own memory, where
//! the machine has it, the engine took 77 to 94 us for a copy of any size
//! up to 64 x 64 pixels, the cores 89 for one of 32 x 32 - 8 KiB of its
//! two rectangles - 97 to 98 for 40 x 32 and 255 for 64 x 64; through the
//! window, where the data fabric's clock is at its lowest most of the
//! time, the engine 84 to 110 us, the cores 85 for 8 x 8 - 512 bytes -
//! 134 to 141 for 8 x 12 and 190 to 192 for 8 x 16: the least of three
//! runs of `C:test/Gpu BLITS DEVICE` and `WINDOW`, each run twice, whose
//! copies are on either side of these leasts. A fill there, which the cores write gathered, stays
//! by the caches: one of 256 x 256 pixels took the engine 143 us and the
//! cores 39.
//!
//! **Until the queue runs** every job is refused. The board starts the
//! graphics block and its queue itself, in a process of its own begun as
//! the board is made (`start`), so that neither the start nor the first
//! picture waits for it: it reads the block's firmware from
//! DEVS:firmware/amdgpu/ - the files named for the blocks' versions as
//! the device's table gives them - has the security processor made
//! ready (StartGPUSecurity), the block's firmware loaded and the block
//! started and kept powered (StartGPUGraphics), and the queue started
//! (StartGPUDMA), some 600 ms; each answers at once where it was done
//! before. Where any of it fails the log says why, and the board's engine
//! stays off. Once the queue runs, the process goes on to the board's
//! kernels (`kernels.start`). The board settles (RTGCTRL_SETTLED, which
//! `C:Rtg TRIED` asks for before it says the driver came back) and goes
//! (`stop`) once nothing of the process runs any more.
//!
//! **The memory** a job reads and writes is mapped for it (MapGPUMemory):
//! each buffer's rows from the first the job touches to the last, taken
//! out again once the job is done. The hub snoops the CPU's caches, so
//! nothing is written back or dropped around a job, and the CPU may draw
//! beside the rectangle meanwhile. A buffer of the device's own memory -
//! a frame, the firmware's framebuffer, a piece of AllocGPUMemory's,
//! where the machine has it or in the memory window - takes no mapping:
//! the engine reaches it through the hub's aperture, and the CPU's
//! gathered writes to it are fenced as the job is sent. A buffer's start
//! and its rows' length
//! are whole four bytes, its pixels one, two or four bytes, and the
//! engine's packets hold a column, a width or a height of up to 16384 and
//! a row of up to 2^19 pixels; anything else is refused.
//!
//! **A fill** over whole rows of a buffer, with nothing between one row
//! and the next, is one constant fill over the lot: in words - a 16-bit
//! colour twice in each - or in bytes. Any other is one copy from a row
//! of the colour that the CPU writes into a piece of its own: read with
//! rows four bytes apart, each row of the rectangle reads the same colour
//! a little further on, so the piece is only as long as the rectangle is
//! wide and high. A constant fill for each row would cost the engine
//! some 1.5 us a row.
//!
//! **A copy** is one sub-window copy for each rectangle, CopyRects' all
//! in one job. Within one buffer, where the rectangle lands on itself -
//! a scroll - it is cut into bands of rows each of whose own source and
//! destination are apart (`Bands`), as many rows as it moves up or down,
//! sent from the bottom up when it moves down; the engine runs a job's
//! packets in order, so each band is read before the one after it writes
//! over it. What it reads and writes is then the two rectangles' rows and
//! columns together. A move along its rows alone would be cut into
//! columns, which the engine copies at a third of its speed, and stays
//! with the cores; so does a move of more bands than a job holds
//! (`most_bands`). On the NucBox, at 28 MiB, the engine scrolled by 16
//! rows in 1674 and 1730 us, the cores in 1130 to 1652 where they had just
//! written the buffer and in 1860 to 1887 where they had not; moved along
//! its rows by 16 columns the engine took 4454 us, the cores 1254 to 1987.
//! A source and a destination that share memory any other way are
//! refused, and so are rectangles of another format than the
//! destination's.
//!
//! **Waiting.** The job is sent and waited for (WaitGPUDMA), the task
//! asleep meanwhile. A job not done within a second is taken as a queue
//! that no longer runs: its memory is unmapped all the same - whatever
//! the engine reaches of it after lands on the hub's scratch page - the
//! job answered RTGERR_TIMEOUT, the engine not used from then on, and the
//! log says so once. A job a reset of the whole graphics block gave up -
//! which the resource makes where the compute engine's queue cannot be
//! brought back otherwise, after the DMA engine has had 100 ms to finish
//! its jobs - is answered RTGERR_TIMEOUT too, said, and the library draws
//! it; the engine, started again with the block, is used on. Such a job
//! may have been done in part: a fill or a copy the library draws again
//! comes out the same, a scroll the engine had moved some bands of does
//! not.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const rtg = sdk.rtg;
const err = rtg.errors;
const amdgpu = sdk.resources.amdgpu;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const AMDGPUBase = sdk.interface.amdgpu.AMDGPUBase;
const TagItem = sdk.utility.TagItem;

const dcn = @import("dcn.zig");
const dmub = @import("dmub.zig");
const kernels = @import("kernels.zig");

/// The board's engine as the board keeps it, beside the board: it does
/// not move while the board is there.
pub const Dma = struct {
    /// The device, as the jobs and the process starting the queue reach
    /// it.
    gpu: ?*AMDGPUBase = null,
    /// What the CPU's caches hold (`cachedBytes`): the bytes a job may
    /// read and write that the cores do sooner.
    cached: u64 = 0,
    /// The bytes a job has to be more than to be an engine's, under the
    /// rule `rule` (RTG_AMD_ENGINE_*): `cached` by size, 0 for every job,
    /// all ones for none. Both set and read atomically.
    least: u64 = 0,
    rule: isize = rtg.tags.RTG_AMD_ENGINE_SIZE,
    /// The device's own memory as the CPU reaches it - where the machine
    /// has it, and the memory window - which the cores read uncached.
    device_memory: [2]Addresses = @splat(.{}),
    /// The board's kernels, which the process starting the queue starts
    /// once it runs.
    kernels: ?*kernels.Kernels = null,
    /// Whether the queue runs and takes the board's jobs: set and read
    /// atomically.
    ready: bool = false,
    /// Whether the log has said a job was not done: swapped atomically.
    failed: bool = false,
    /// The process that starts the queue, while it may still run: dos
    /// replies `ended` to `end_port` once nothing of it runs any more -
    /// only then may the board, and the driver's code, go. The port is
    /// never signalled; `settle` looks at it, and says the reply was
    /// taken in `starter_ended`, set and read atomically.
    starter_made: bool = false,
    starter_ended: bool = false,
    ended: exec.Message = .{},
    end_port: exec.MsgPort = .{ .flags = exec.PA_IGNORE },
};

/// A run of the machine's addresses, `bytes` from `start`.
pub const Addresses = struct { start: u64 = 0, bytes: u64 = 0 };

/// Where an address is in the device's own memory: not in it, where the
/// machine has it, or in the memory window.
pub const DeviceMemory = enum { not, machine, window };

/// The bytes a copy that reads the device's own memory has to be more
/// than to be the engine's by the board's own rule, the source's and the
/// destination's together, where the machine has that memory and through
/// the memory window: where the engine, some 90 us a job however small,
/// and the cores, which read that memory uncached, take as long - 32 x 32
/// pixels of four bytes, and 8 x 8 through the window.
const reading_bytes: u64 = 8 * 1024;
const window_reading_bytes: u64 = 512;

/// How long a job is waited for before the queue is taken as no longer
/// running: the engine fills the largest buffer, 16384 x 16384 pixels of
/// four bytes, in some 45 ms.
const job_most_ms: u32 = 1000;
/// The words of the engine's sub-window copy and of its constant fill,
/// and the most bands a move within one buffer is cut into - a job of
/// them is some 13 KiB of the queue's ring of 64.
const copy_words = 13;
const fill_words = 5;
const most_bands: u32 = 256;
/// The most a sub-window copy's column, width or height holds, and its
/// rows' length in pixels.
const most_side: u32 = 1 << 14;
const most_pitch: u32 = 1 << 19;
/// How far apart a copied fill's source rows are: four bytes, the least
/// a surface's rows may be.
const fill_step_bytes: u32 = 4;
/// The process that starts the queue.
const starter_name = "rtg-amd engine";
const starter_stack: u32 = 65536;

// --- the queue started ---------------------------------------------------------------

/// The board's engine set up as the board is made: what a job has to be
/// more than, and the process that starts the graphics block and its
/// queue begun, which starts `compute` after. Nothing where the CPU does
/// not say what its caches hold, or where the board is made in a task,
/// which starts no process.
pub fn start(dma: *Dma, sys: *ExecBase, gpu: *AMDGPUBase, compute: *kernels.Kernels) void {
    const cached = cachedBytes(sys);
    dma.* = .{ .gpu = gpu, .cached = cached, .least = cached, .kernels = compute };
    var info: amdgpu.GPUInfo = .{};
    if (!gpu.GetGPUInfo(&info)) return;
    dma.device_memory = .{
        .{ .start = info.memory_machine, .bytes = if (info.memory_machine != 0) info.memory_bytes else 0 },
        .{ .start = info.window, .bytes = info.window_bytes },
    };
    if (dma.cached == 0) {
        exec.kprintf(sys, "%s: the CPU does not say what its caches hold: the graphics block's DMA engine is not used\n", .{dcn.owner});
        return;
    }
    if (sys.FindTask(null).?.node.type != .process) return;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    dma.end_port.msg_list.init(.message);
    dma.ended = .{ .reply_port = &dma.end_port };
    const process_tags = [_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&starter) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(@as([*:0]const u8, starter_name)) },
        .{ .tag = dos.NP_StackSize, .data = starter_stack },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(dma) },
        .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&dma.ended) },
        .{},
    };
    if (dl.CreateNewProc(&process_tags) == null) {
        exec.kprintf(sys, "%s: no process to start the graphics block's DMA engine\n", .{dcn.owner});
        return;
    }
    dma.starter_made = true;
}

/// Once nothing of the process starting the queue runs any more: at
/// once where there is none, or it has ended before. Any number of tasks
/// may wait at once.
pub fn settle(dma: *Dma, sys: *ExecBase) void {
    if (!dma.starter_made) return;
    while (!@atomicLoad(bool, &dma.starter_ended, .acquire)) {
        if (sys.GetMsg(&dma.end_port) != null) {
            @atomicStore(bool, &dma.starter_ended, true, .release);
        } else dcn.pause(sys, 10_000);
    }
}

/// The board's engine let go of as the board goes: once nothing of the
/// process starting the queue runs any more, no job is the engine's, and
/// the board's kernels are let go of too. The queues are
/// amdgpu.resource's and run on.
pub fn stop(dma: *Dma, sys: *ExecBase) void {
    settle(dma, sys);
    @atomicStore(bool, &dma.ready, false, .release);
    if (dma.kernels) |compute| if (dma.gpu) |gpu| kernels.stop(compute, sys, gpu);
}

/// The bytes a job has to be more than to be an engine's, under the rule
/// in force.
pub fn cutOff(dma: *const Dma) u64 {
    return @atomicLoad(u64, &dma.least, .acquire);
}

/// The bytes a job that reads the device's own memory has to be more
/// than to be an engine's, under the rule in force: by size the fewer of
/// the caches' and `by_size`; under the others what any job has to be.
pub fn cutOffReading(dma: *const Dma, by_size: u64) u64 {
    return switch (ruleOf(dma)) {
        rtg.tags.RTG_AMD_ENGINE_SIZE => @min(by_size, cutOff(dma)),
        else => cutOff(dma),
    };
}

/// Where `address` is in the device's own memory, as the CPU reaches it.
pub fn deviceMemoryOf(dma: *const Dma, address: usize) DeviceMemory {
    for (dma.device_memory, [2]DeviceMemory{ .machine, .window }) |run, place| {
        if (address >= run.start and address - run.start < run.bytes) return place;
    }
    return .not;
}

/// The rule in force (RTG_AMD_ENGINE_*).
pub fn ruleOf(dma: *const Dma) isize {
    return @atomicLoad(isize, &dma.rule, .acquire);
}

/// RTGCTRL_AMD_ENGINE: which jobs the engines take from now on - by size,
/// every one or none. The rule before, or null for another value.
pub fn setRule(dma: *Dma, rule: isize) ?isize {
    const least: u64 = switch (rule) {
        rtg.tags.RTG_AMD_ENGINE_SIZE => dma.cached,
        rtg.tags.RTG_AMD_ENGINE_ALL => 0,
        rtg.tags.RTG_AMD_ENGINE_NONE => ~@as(u64, 0),
        else => return null,
    };
    @atomicStore(u64, &dma.least, least, .release);
    return @atomicRmw(isize, &dma.rule, .Xchg, rule, .acq_rel);
}

/// The process that starts the graphics block and its queue: the board's
/// engine is ready once both run.
fn starter(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const dma: *Dma = @ptrCast(@alignCast(me.user_data orelse return));
    if (!bringUp(sys, dma.gpu.?)) return;
    exec.kprintf(sys, "%s: the graphics block's DMA engine runs: fills and copies of more than %lu bytes are its, copies from the device's own memory of more than %lu\n", .{ dcn.owner, dma.cached, reading_bytes });
    @atomicStore(bool, &dma.ready, true, .release);
    if (dma.kernels) |compute| kernels.start(compute, sys, dma.gpu.?);
}

/// The graphics block's firmware read, the block started and its queue
/// started: true once both run, false with why said on the log.
fn bringUp(sys: *ExecBase, gpu: *AMDGPUBase) bool {
    var graphics: amdgpu.GPUBlock = .{};
    var engine: amdgpu.GPUBlock = .{};
    var security: amdgpu.GPUBlock = .{};
    if (!gpu.FindGPUBlock(amdgpu.GPUBLOCK_GRAPHICS, 0, &graphics) or
        !gpu.FindGPUBlock(amdgpu.GPUBLOCK_DMA, 0, &engine) or
        !gpu.FindGPUBlock(amdgpu.GPUBLOCK_SECURITY, 0, &security))
    {
        exec.kprintf(sys, "%s: the device names no graphics block, DMA engine or security processor: its DMA engine is not used\n", .{dcn.owner});
        return false;
    }
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return false;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    const version = [3]u8{ graphics.major, graphics.minor, graphics.revision };
    var files: amdgpu.GPUGraphicsFiles = .{};
    defer for ([_]amdgpu.GPUFile{ files.pfp, files.me, files.mec, files.rlc, files.mes, files.mes_kiq, files.imu, files.dma }) |file| {
        if (file.image) |image| sys.FreeVec(@constCast(image));
    };
    const read_all = readInto(sys, dl, &files.pfp, "gc", version, "_pfp") and
        readInto(sys, dl, &files.me, "gc", version, "_me") and
        readInto(sys, dl, &files.mec, "gc", version, "_mec") and
        readInto(sys, dl, &files.rlc, "gc", version, "_rlc") and
        readInto(sys, dl, &files.mes, "gc", version, "_mes_2") and
        readInto(sys, dl, &files.mes_kiq, "gc", version, "_mes1") and
        readInto(sys, dl, &files.dma, "sdma", .{ engine.major, engine.minor, engine.revision }, "");
    if (!read_all) return false;
    // The power controller's own file where there is one; the machine's
    // copy runs otherwise.
    var imu_room: [64]u8 = undefined;
    var imu_length: usize = 0;
    if (dl.ReadFile(dmub.path(sys, &imu_room, "gc", version, "_imu"), ~@as(usize, 0), exec.MEMF_ANY, &imu_length)) |image| {
        files.imu = .{ .image = image, .bytes = @intCast(imu_length) };
    }
    var toc_room: [64]u8 = undefined;
    const toc = dmub.readFile(sys, dl, dmub.path(sys, &toc_room, "psp", .{ security.major, security.minor, security.revision }, "_toc")) orelse return false;
    defer sys.FreeVec(toc.ptr);

    if (!gpu.StartGPUSecurity(toc.ptr, @intCast(toc.len))) {
        exec.kprintf(sys, "%s: the security processor is not ready: the DMA engine is not used\n", .{dcn.owner});
        return false;
    }
    if (!gpu.StartGPUGraphics(&files)) {
        exec.kprintf(sys, "%s: the graphics block did not start: the DMA engine is not used\n", .{dcn.owner});
        return false;
    }
    if (!gpu.StartGPUDMA()) {
        exec.kprintf(sys, "%s: the DMA engine's queue did not start: the engine is not used\n", .{dcn.owner});
        return false;
    }
    return true;
}

/// One of the block's firmware files, DEVS:firmware/amdgpu/<prefix>_<a>_<b>_<c><suffix>.bin,
/// read into `into`: false, with why said on the log, where it cannot be.
fn readInto(sys: *ExecBase, dl: *DosBase, into: *amdgpu.GPUFile, comptime prefix: [:0]const u8, version: [3]u8, comptime suffix: [:0]const u8) bool {
    var room: [64]u8 = undefined;
    const file = dmub.readFile(sys, dl, dmub.path(sys, &room, prefix, version, suffix)) orelse return false;
    into.* = .{ .image = file.ptr, .bytes = @intCast(file.len) };
    return true;
}

/// What the CPU's caches below the memory hold together: each data cache
/// from the second level on, counted once for each group of the running
/// cores that shares one, as the core's cache leaves (0x8000_001D)
/// describe them. 0 where the core does not describe them.
fn cachedBytes(sys: *ExecBase) u64 {
    const cpu = sdk.hardware.cpu;
    if (cpu.leaf(0x8000_0000, 0).eax < 0x8000_001d) return 0;
    const cores = sys.CoreCount();
    var total: u64 = 0;
    var index: u32 = 0;
    while (index < 8) : (index += 1) {
        const found = cpu.leaf(0x8000_001d, index);
        const cache = cacheOf(found.eax, found.ebx, found.ecx) orelse break;
        if (cache.level < 2 or !cache.data) continue;
        total += cache.bytes * ((cores + cache.sharing - 1) / cache.sharing);
    }
    return total;
}

/// One cache as a cache leaf describes it: its level, whether it holds
/// data, how many bytes, and how many of the machine's cores share one.
/// Null for the leaf past the last cache.
pub const Cache = struct { level: u32, data: bool, bytes: u64, sharing: u32 };

pub fn cacheOf(eax: u32, ebx: u32, ecx: u32) ?Cache {
    const kind = eax & 0x1f;
    if (kind == 0) return null;
    const ways: u64 = (ebx >> 22 & 0x3ff) + 1;
    const partitions: u64 = (ebx >> 12 & 0x3ff) + 1;
    const line: u64 = (ebx & 0xfff) + 1;
    const sets: u64 = @as(u64, ecx) + 1;
    return .{ .level = eax >> 5 & 7, .data = kind != 2, .bytes = ways * partitions * line * sets, .sharing = (eax >> 14 & 0xfff) + 1 };
}

// --- the jobs ------------------------------------------------------------------------

/// FillRect: `area` of `bitmap` filled with `colour`, in the buffer's
/// format, by the engine - or RTGERR_NOT_SUPPORTED, nothing written, for
/// a fill the cores do sooner or the engine does not take.
pub fn fill(dma: *Dma, sys: *ExecBase, rb: *RtgBase, bitmap: *rtg.RtgBitMap, area: *const rtg.RtgRect, colour: u32) i32 {
    const width: u32 = @intCast(area.width);
    const height: u32 = @intCast(area.height);
    // Most fills end here, four bytes a pixel the most they could be.
    if (@as(u64, width) * height * 4 <= cutOff(dma) or !@atomicLoad(bool, &dma.ready, .acquire)) return err.RTGERR_NOT_SUPPORTED;
    const gpu = dma.gpu.?;
    const bytes_each = pixelBytes(rb, bitmap.format) orelse return err.RTGERR_NOT_SUPPORTED;
    if (@as(u64, width) * height * bytes_each <= cutOff(dma)) return err.RTGERR_NOT_SUPPORTED;
    const pixels = bitmap.pixels orelse return err.RTGERR_NOT_SUPPORTED;
    if (!lined(pixels, bitmap.pitch)) return err.RTGERR_NOT_SUPPORTED;
    const x: u32 = @intCast(area.x);
    const y: u32 = @intCast(area.y);
    var target: amdgpu.GPUMemory = .{};
    if (!mapRows(gpu, pixels, bitmap.pitch, y, height, (x + width) * bytes_each, &target)) return err.RTGERR_NOT_SUPPORTED;
    defer gpu.UnmapGPUMemory(&target);

    if (x == 0 and width * bytes_each == bitmap.pitch) {
        const run_bytes = @as(u64, bitmap.pitch) * height;
        if (run_bytes > 1 << 30) return err.RTGERR_NOT_SUPPORTED;
        const words = constantFill(target.device, @intCast(run_bytes), colour, bytes_each);
        return send(dma, sys, &words, words.len);
    }
    const pitch = bitmap.pitch / bytes_each;
    if (x >= most_side or width > most_side or height > most_side or pitch > most_pitch) return err.RTGERR_NOT_SUPPORTED;
    // A row of the colour, read `step` pixels on for each row.
    const step = fill_step_bytes / bytes_each;
    const row_pixels = width + step * (height - 1);
    const row_bytes = row_pixels * bytes_each;
    const row = sys.AllocVec(row_bytes, exec.MEMF_ANY) orelse return err.RTGERR_NOT_SUPPORTED;
    defer sys.FreeVec(row);
    paintRow(@ptrCast(row), row_pixels, colour, bytes_each);
    var source: amdgpu.GPUMemory = .{};
    if (!gpu.MapGPUMemory(row, row_bytes, 0, &source)) return err.RTGERR_NOT_SUPPORTED;
    defer gpu.UnmapGPUMemory(&source);
    const words = subWindow(shiftOf(bytes_each), source.device, step, 0, target.device, pitch, x, width, height);
    return send(dma, sys, &words, words.len);
}

/// CopyRect and CopyRects: each of `copies` from `src` to `dest` by the
/// engine, as one job - or RTGERR_NOT_SUPPORTED, nothing written, for
/// copies the cores do sooner or the engine does not take.
pub fn copy(dma: *Dma, sys: *ExecBase, rb: *RtgBase, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copies: []const rtg.RtgCopy) i32 {
    // A copy whose source is the device's own memory, which the cores
    // read uncached, is the engine's from fewer bytes.
    const src_pixels = src.pixels orelse return err.RTGERR_NOT_SUPPORTED;
    const least = switch (deviceMemoryOf(dma, @intFromPtr(src_pixels))) {
        .not => cutOff(dma),
        .machine => cutOffReading(dma, reading_bytes),
        .window => cutOffReading(dma, window_reading_bytes),
    };
    // Most copies end here, two rectangles of four bytes a pixel the most
    // each could be.
    var most: u64 = 0;
    for (copies) |one| most += 8 * @as(u64, @intCast(one.width)) * @as(u64, @intCast(one.height));
    if (most <= least or !@atomicLoad(bool, &dma.ready, .acquire)) return err.RTGERR_NOT_SUPPORTED;
    const gpu = dma.gpu.?;
    if (src.format != dest.format) return err.RTGERR_NOT_SUPPORTED;
    const bytes_each = pixelBytes(rb, dest.format) orelse return err.RTGERR_NOT_SUPPORTED;
    const dest_pixels = dest.pixels orelse return err.RTGERR_NOT_SUPPORTED;
    if (!lined(src_pixels, src.pitch) or !lined(dest_pixels, dest.pitch)) return err.RTGERR_NOT_SUPPORTED;
    const src_pitch = src.pitch / bytes_each;
    const dest_pitch = dest.pitch / bytes_each;
    if (src_pitch > most_pitch or dest_pitch > most_pitch) return err.RTGERR_NOT_SUPPORTED;
    for (copies) |one| {
        if (one.src_x >= most_side or one.dest_x >= most_side or one.width > most_side or one.height > most_side) return err.RTGERR_NOT_SUPPORTED;
    }
    const from = spanOf(copies, .source, bytes_each);
    const to = spanOf(copies, .destination, bytes_each);
    const from_start = @intFromPtr(src_pixels) + @as(usize, from.first) * src.pitch;
    const from_end = from_start + @as(usize, from.rows - 1) * src.pitch + from.end_bytes;
    const to_start = @intFromPtr(dest_pixels) + @as(usize, to.first) * dest.pitch;
    const to_end = to_start + @as(usize, to.rows - 1) * dest.pitch + to.end_bytes;
    const shared = from_start < to_end and to_start < from_end;

    // One buffer, one move: cut into bands where it lands on itself.
    var bands: ?Bands = null;
    if (shared) {
        if (copies.len != 1 or src_pixels != dest_pixels or src.pitch != dest.pitch) return err.RTGERR_NOT_SUPPORTED;
        const cut = Bands.of(copies[0]) orelse return err.RTGERR_NOT_SUPPORTED;
        if (cut.count > most_bands) return err.RTGERR_NOT_SUPPORTED;
        bands = cut;
    }
    var touched: u64 = 0;
    if (bands != null and bands.?.count > 1) {
        const move = copies[0];
        const columns = @as(u64, @intCast(move.width)) + @abs(move.dest_x - move.src_x);
        const rows = @as(u64, @intCast(move.height)) + @abs(move.dest_y - move.src_y);
        touched = columns * rows * bytes_each;
    } else for (copies) |one| {
        touched += 2 * @as(u64, @intCast(one.width)) * @as(u64, @intCast(one.height)) * bytes_each;
    }
    if (touched <= least) return err.RTGERR_NOT_SUPPORTED;

    var source: amdgpu.GPUMemory = .{};
    if (!mapRows(gpu, src_pixels, src.pitch, from.first, from.rows, from.end_bytes, &source)) return err.RTGERR_NOT_SUPPORTED;
    defer gpu.UnmapGPUMemory(&source);
    var target: amdgpu.GPUMemory = .{};
    if (!mapRows(gpu, dest_pixels, dest.pitch, to.first, to.rows, to.end_bytes, &target)) return err.RTGERR_NOT_SUPPORTED;
    defer gpu.UnmapGPUMemory(&target);
    const count: u32 = if (bands) |cut| cut.count else @intCast(copies.len);
    const memory = sys.AllocVec(count * copy_words * 4, exec.MEMF_ANY) orelse return err.RTGERR_NOT_SUPPORTED;
    defer sys.FreeVec(memory);
    const words: [*]u32 = @ptrCast(@alignCast(memory));
    for (0..count) |index| {
        const one = if (bands) |cut| cut.band(@intCast(index)) else copies[index];
        const packet = subWindow(
            shiftOf(bytes_each),
            source.device + @as(u64, @as(u32, @intCast(one.src_y)) - from.first) * src.pitch,
            src_pitch,
            @intCast(one.src_x),
            target.device + @as(u64, @as(u32, @intCast(one.dest_y)) - to.first) * dest.pitch,
            dest_pitch,
            @intCast(one.dest_x),
            @intCast(one.width),
            @intCast(one.height),
        );
        @memcpy(words[index * copy_words ..][0..copy_words], &packet);
    }
    return send(dma, sys, words, count * copy_words);
}

/// A job's `count` words sent and waited for: RTGERR_OK once the engine
/// has done it; RTGERR_NOT_SUPPORTED, nothing written, where it was not
/// sent. One a reset of the whole block gave up is answered
/// RTGERR_TIMEOUT, said. One not done within `job_most_ms` is taken as a
/// queue that no longer runs - no job is the engine's from then on - and
/// said once.
fn send(dma: *Dma, sys: *ExecBase, words: [*]const u32, count: u32) i32 {
    const gpu = dma.gpu.?;
    const job = gpu.SendGPUDMA(words, count);
    if (job == 0) return err.RTGERR_NOT_SUPPORTED;
    if (gpu.WaitGPUDMA(job, job_most_ms)) return err.RTGERR_OK;
    var state: amdgpu.GPUDMAState = .{};
    if (gpu.GetGPUDMAState(&state) and givenUp(state, job)) {
        exec.kprintf(sys, "%s: a job of the graphics block's DMA engine was given up by a reset of the whole block: the library draws it\n", .{dcn.owner});
        return err.RTGERR_TIMEOUT;
    }
    @atomicStore(bool, &dma.ready, false, .release);
    if (!@atomicRmw(bool, &dma.failed, .Xchg, true, .acq_rel)) {
        exec.kprintf(sys, "%s: a job of the graphics block's DMA engine was not done within %u ms: the engine is not used from now on\n", .{ dcn.owner, job_most_ms });
    }
    return err.RTGERR_TIMEOUT;
}

/// Whether job `job`, which WaitGPUDMA answered false, is one a reset of
/// the whole block gave up: one at or before the last such, its number
/// done - a job that was done would have been answered true.
fn givenUp(state: amdgpu.GPUDMAState, job: u32) bool {
    return state.given_up != 0 and @as(i32, @bitCast(state.given_up -% job)) >= 0 and @as(i32, @bitCast(state.done -% job)) >= 0;
}

/// Bytes a pixel of `format` is, where the engine takes it: one, two or
/// four.
pub fn pixelBytes(rb: *RtgBase, format: rtg.PixelFormat) ?u32 {
    return switch (rb.RtgFormatBits(@intFromEnum(format))) {
        8 => 1,
        16 => 2,
        32 => 4,
        else => null,
    };
}

/// A pixel's bytes as the sub-window copy's header gives them: their
/// log2.
fn shiftOf(bytes_each: u32) u32 {
    return switch (bytes_each) {
        1 => 0,
        2 => 1,
        else => 2,
    };
}

/// Whether a buffer's start and its rows' length are whole four bytes,
/// as the engine takes them.
pub fn lined(pixels: [*]u8, pitch: u32) bool {
    return @intFromPtr(pixels) % 4 == 0 and pitch % 4 == 0 and pitch != 0;
}

/// `rows` rows of a buffer from row `first`, the last of them to its
/// byte `end_bytes`, mapped for a job into `into`: false where they
/// cannot be.
pub fn mapRows(gpu: *AMDGPUBase, pixels: [*]u8, pitch: u32, first: u32, rows: u32, end_bytes: u32, into: *amdgpu.GPUMemory) bool {
    const bytes = @as(u64, rows - 1) * pitch + end_bytes;
    if (bytes > 0xffff_ffff) return false;
    return gpu.MapGPUMemory(pixels + @as(usize, first) * pitch, @intCast(bytes), 0, into);
}

/// `count` pixels of `colour` in a row of `bytes_each` bytes a pixel.
fn paintRow(row: [*]u8, count: u32, colour: u32, bytes_each: u32) void {
    switch (bytes_each) {
        4 => @memset(@as([*]u32, @ptrCast(@alignCast(row)))[0..count], colour),
        2 => @memset(@as([*]u16, @ptrCast(@alignCast(row)))[0..count], @truncate(colour)),
        else => @memset(row[0..count], @truncate(colour)),
    }
}

/// The rows a list of copies reads of its source, or writes of its
/// destination: the first, how many, and where the last of them ends -
/// the furthest any rectangle reaches into a row.
const Span = struct { first: u32, rows: u32, end_bytes: u32 };
const Side = enum { source, destination };

fn spanOf(copies: []const rtg.RtgCopy, side: Side, bytes_each: u32) Span {
    var first: u32 = ~@as(u32, 0);
    var end: u32 = 0;
    var end_bytes: u32 = 0;
    for (copies) |one| {
        const width: u32 = @intCast(one.width);
        const height: u32 = @intCast(one.height);
        const top: u32 = @intCast(if (side == .source) one.src_y else one.dest_y);
        const left: u32 = @intCast(if (side == .source) one.src_x else one.dest_x);
        first = @min(first, top);
        end = @max(end, top + height);
        end_bytes = @max(end_bytes, (left + width) * bytes_each);
    }
    return .{ .first = first, .rows = end - first, .end_bytes = end_bytes };
}

/// Whether a move within one buffer lands clear of where it starts: its
/// two rectangles share no pixel.
pub fn apart(move: rtg.RtgCopy) bool {
    return @abs(move.dest_x - move.src_x) >= @as(u32, @intCast(move.width)) or
        @abs(move.dest_y - move.src_y) >= @as(u32, @intCast(move.height));
}

/// A move within one buffer cut into bands of rows, each of whose own
/// source and destination are apart, in the order they are sent: as many
/// rows as the move goes up or down, from the bottom up when it goes
/// down. A move that lands clear of itself is one band; one that lands
/// on itself going along its rows alone has none (null).
pub const Bands = struct {
    move: rtg.RtgCopy,
    /// How many rows a band has, and how many bands.
    step: u32,
    count: u32,
    /// Sent last first.
    backwards: bool,

    pub fn of(move: rtg.RtgCopy) ?Bands {
        const height: u32 = @intCast(move.height);
        if (apart(move)) return .{ .move = move, .step = height, .count = 1, .backwards = false };
        const rows = @abs(move.dest_y - move.src_y);
        if (rows == 0) return null;
        return .{ .move = move, .step = rows, .count = (height + rows - 1) / rows, .backwards = move.dest_y > move.src_y };
    }

    /// The `index`th band sent.
    pub fn band(bands: Bands, index: u32) rtg.RtgCopy {
        const piece = if (bands.backwards) bands.count - 1 - index else index;
        const height: u32 = @intCast(bands.move.height);
        const first = piece * bands.step;
        var cut = bands.move;
        cut.src_y += @intCast(first);
        cut.dest_y += @intCast(first);
        cut.height = @intCast(@min(bands.step, height - first));
        return cut;
    }
};

// --- the engine's packets ----------------------------------------------------------------

/// The engine's sub-window copy: `width` x `height` pixels of
/// `1 << shift` bytes, from column `src_x` of rows `src_pitch` pixels
/// apart that start at `src`, to column `dest_x` of rows `dest_pitch`
/// apart that start at `dest` - each address that of the first row the
/// rectangle is in.
pub fn subWindow(shift: u32, src: u64, src_pitch: u32, src_x: u32, dest: u64, dest_pitch: u32, dest_x: u32, width: u32, height: u32) [copy_words]u32 {
    return .{
        amdgpu.GPUDMA_OP_COPY | amdgpu.GPUDMA_COPY_SUB_WINDOW | shift << amdgpu.GPUDMA_COPY_ELEMENT_SHIFT,
        @truncate(src),
        @truncate(src >> 32),
        src_x,
        (src_pitch - 1) << amdgpu.GPUDMA_COPY_PITCH_SHIFT,
        slice(src_pitch, height),
        @truncate(dest),
        @truncate(dest >> 32),
        dest_x,
        (dest_pitch - 1) << amdgpu.GPUDMA_COPY_PITCH_SHIFT,
        slice(dest_pitch, height),
        (width - 1) | (height - 1) << 16,
        0,
    };
}

/// A slice's pixels less one, as the packet holds them: never stepped
/// over in a copy of one slice, and kept to its 28 bits.
fn slice(pitch: u32, height: u32) u32 {
    return @intCast(@min(@as(u64, pitch) * height, 1 << 28) - 1);
}

/// The engine's constant fill of `bytes` from `device` with pixels of
/// `bytes_each` bytes of `colour`: in words, a 16-bit colour twice in
/// each, or in bytes.
pub fn constantFill(device: u64, bytes: u32, colour: u32, bytes_each: u32) [fill_words]u32 {
    const value = switch (bytes_each) {
        4 => colour,
        2 => (colour & 0xffff) * 0x1_0001,
        else => colour & 0xff,
    };
    const size: u32 = if (bytes_each == 1) 0 else amdgpu.GPUDMA_FILL_WORDS;
    return .{ amdgpu.GPUDMA_OP_CONST_FILL | size, @truncate(device), @truncate(device >> 32), value, bytes - 1 };
}

// --- tests (host: ./zig build test) -------------------------------------------------

const testing = @import("std").testing;

test "a copy's packet is the sub-window copy's thirteen words" {
    const words = subWindow(2, 0x7FFF_0000_1000, 2560, 13, 0x7FFF_00E1_0000, 2560, 101, 333, 111);
    try testing.expectEqual(@as(u32, 0x4000_0401), words[0]);
    try testing.expectEqual(@as(u32, 0x0000_1000), words[1]);
    try testing.expectEqual(@as(u32, 0x7FFF), words[2]);
    try testing.expectEqual(@as(u32, 13), words[3]);
    try testing.expectEqual(@as(u32, 2559 << 13), words[4]);
    try testing.expectEqual(@as(u32, 2560 * 111 - 1), words[5]);
    try testing.expectEqual(@as(u32, 0x00E1_0000), words[6]);
    try testing.expectEqual(@as(u32, 101), words[8]);
    try testing.expectEqual(@as(u32, 332 | 110 << 16), words[11]);
    try testing.expectEqual(@as(u32, 0), words[12]);
    // Two bytes a pixel, and a slice larger than its 28 bits.
    const halves = subWindow(1, 0, 524288, 0, 0, 2, 0, 16384, 16384);
    try testing.expectEqual(@as(u32, 0x2000_0401), halves[0]);
    try testing.expectEqual(@as(u32, (1 << 28) - 1), halves[5]);
    try testing.expectEqual(@as(u32, 1 << 13), halves[9]);
}

test "a fill over whole rows is one constant fill, a 16-bit colour twice a word" {
    const words = constantFill(0x7FFF_0000_0000, 10240 * 2880, 0xFF12_3456, 4);
    try testing.expectEqual(@as(u32, 11 | 2 << 30), words[0]);
    try testing.expectEqual(@as(u32, 0xFF12_3456), words[3]);
    try testing.expectEqual(@as(u32, 10240 * 2880 - 1), words[4]);
    try testing.expectEqual(@as(u32, 0xBEEF_BEEF), constantFill(0, 4, 0xBEEF, 2)[3]);
    const bytes = constantFill(0, 8, 0x1234_5678, 1);
    try testing.expectEqual(@as(u32, 11), bytes[0]);
    try testing.expectEqual(@as(u32, 0x78), bytes[3]);
}

test "a move within one buffer is cut into bands of rows that are read before they are written over" {
    // Down three rows: bands of three rows from the bottom up, the last
    // band first.
    const down = Bands.of(.{ .src_x = 10, .src_y = 10, .width = 300, .height = 10, .dest_x = 15, .dest_y = 13 }).?;
    try testing.expectEqual(@as(u32, 4), down.count);
    try testing.expect(down.backwards);
    const first = down.band(0);
    try testing.expectEqual(@as(i32, 19), first.src_y);
    try testing.expectEqual(@as(i32, 22), first.dest_y);
    try testing.expectEqual(@as(i32, 1), first.height);
    try testing.expectEqual(@as(i32, 15), first.dest_x);
    const last = down.band(3);
    try testing.expectEqual(@as(i32, 10), last.src_y);
    try testing.expectEqual(@as(i32, 3), last.height);
    // Up: from the top down.
    const up = Bands.of(.{ .src_x = 0, .src_y = 20, .width = 300, .height = 200, .dest_x = 2, .dest_y = 17 }).?;
    try testing.expect(!up.backwards);
    try testing.expectEqual(@as(u32, 67), up.count);
    try testing.expectEqual(@as(i32, 20), up.band(0).src_y);
    try testing.expectEqual(@as(i32, 2), up.band(66).height);
    // Along the rows alone: no bands of rows.
    try testing.expect(Bands.of(.{ .src_x = 10, .src_y = 10, .width = 300, .height = 200, .dest_x = 17, .dest_y = 10 }) == null);
    // Clear of itself: one band, the whole move.
    const clear = Bands.of(.{ .src_x = 0, .src_y = 0, .width = 100, .height = 100, .dest_x = 0, .dest_y = 100 }).?;
    try testing.expectEqual(@as(u32, 1), clear.count);
    try testing.expectEqual(@as(i32, 100), clear.band(0).height);
    try testing.expect(apart(.{ .src_x = 100, .src_y = 50, .width = 100, .height = 100, .dest_x = 0, .dest_y = 0 }));
    try testing.expect(!apart(.{ .src_x = 0, .src_y = 0, .width = 2544, .height = 2880, .dest_x = 16, .dest_y = 0 }));
}

test "a copy reading the device's memory is the engine's from fewer bytes, by size alone" {
    var dma: Dma = .{ .cached = 24 << 20, .least = 24 << 20 };
    dma.device_memory = .{ .{ .start = 0x8_4000_0000, .bytes = 512 << 20 }, .{ .start = 0x7c_0000_0000, .bytes = 256 << 20 } };
    try testing.expectEqual(DeviceMemory.machine, deviceMemoryOf(&dma, 0x8_4000_0000));
    try testing.expectEqual(DeviceMemory.machine, deviceMemoryOf(&dma, 0x8_4000_0000 + (512 << 20) - 1));
    try testing.expectEqual(DeviceMemory.not, deviceMemoryOf(&dma, 0x8_4000_0000 + (512 << 20)));
    try testing.expectEqual(DeviceMemory.not, deviceMemoryOf(&dma, 0x8_4000_0000 - 1));
    try testing.expectEqual(DeviceMemory.window, deviceMemoryOf(&dma, 0x7c_0000_0000 + 4096));
    try testing.expectEqual(DeviceMemory.not, deviceMemoryOf(&dma, 0x1000_0000));
    try testing.expectEqual(reading_bytes, cutOffReading(&dma, reading_bytes));
    try testing.expectEqual(@as(u64, 24 << 20), cutOff(&dma));
    _ = setRule(&dma, rtg.tags.RTG_AMD_ENGINE_ALL);
    try testing.expectEqual(@as(u64, 0), cutOffReading(&dma, reading_bytes));
    _ = setRule(&dma, rtg.tags.RTG_AMD_ENGINE_NONE);
    try testing.expectEqual(~@as(u64, 0), cutOffReading(&dma, reading_bytes));
    try testing.expectEqual(~@as(u64, 0), cutOff(&dma));
    _ = setRule(&dma, rtg.tags.RTG_AMD_ENGINE_SIZE);
    try testing.expectEqual(window_reading_bytes, cutOffReading(&dma, window_reading_bytes));
    // Caches smaller than the copy's own least leave it the caches'.
    dma.cached = 4 * 1024;
    _ = setRule(&dma, rtg.tags.RTG_AMD_ENGINE_SIZE);
    try testing.expectEqual(@as(u64, 4 * 1024), cutOffReading(&dma, reading_bytes));
}

test "a cache leaf says the cache's level, size and sharing" {
    // An L2 of 1 MiB, eight ways of 2048 sets of 64 bytes, two cores to one.
    const second = cacheOf(0x0000_4143, 0x01C0_003F, 0x0000_07FF).?;
    try testing.expectEqual(@as(u32, 2), second.level);
    try testing.expect(second.data);
    try testing.expectEqual(@as(u64, 1 << 20), second.bytes);
    try testing.expectEqual(@as(u32, 2), second.sharing);
    // An L3 of 16 MiB shared by sixteen.
    const third = cacheOf(0x0003_C163, 0x03C0_003F, 0x0000_3FFF).?;
    try testing.expectEqual(@as(u32, 3), third.level);
    try testing.expectEqual(@as(u64, 16 << 20), third.bytes);
    try testing.expectEqual(@as(u32, 16), third.sharing);
    // An instruction cache, and the leaf past the last.
    try testing.expect(!cacheOf(0x0000_4122, 0x01C0_003F, 0x3F).?.data);
    try testing.expect(cacheOf(0, 0, 0) == null);
}

test "a list of copies spans the rows of each side" {
    const copies = [_]rtg.RtgCopy{
        .{ .src_x = 0, .src_y = 5, .width = 10, .height = 3, .dest_x = 20, .dest_y = 0 },
        .{ .src_x = 4, .src_y = 1, .width = 10, .height = 2, .dest_x = 0, .dest_y = 9 },
    };
    const from = spanOf(&copies, .source, 4);
    try testing.expectEqual(@as(u32, 1), from.first);
    try testing.expectEqual(@as(u32, 7), from.rows);
    try testing.expectEqual(@as(u32, 14 * 4), from.end_bytes);
    const to = spanOf(&copies, .destination, 4);
    try testing.expectEqual(@as(u32, 0), to.first);
    try testing.expectEqual(@as(u32, 11), to.rows);
    try testing.expectEqual(@as(u32, 30 * 4), to.end_bytes);
}

test "a job a reset of the whole block gave up, told from one not done in time" {
    // Jobs 6 to 9 given up, the page reading 9 done.
    const after_reset: amdgpu.GPUDMAState = .{ .sent = 9, .done = 9, .given_up = 9 };
    try testing.expect(givenUp(after_reset, 6));
    try testing.expect(givenUp(after_reset, 9));
    // Job 10, sent after and not done in time: the engine's own fault.
    const later: amdgpu.GPUDMAState = .{ .sent = 10, .done = 9, .given_up = 9 };
    try testing.expect(!givenUp(later, 10));
    // No reset yet.
    try testing.expect(!givenUp(.{ .sent = 3, .done = 2 }, 3));
    // Across the wrap.
    try testing.expect(givenUp(.{ .sent = 2, .done = 2, .given_up = 2 }, 0xffff_ffff));
}
