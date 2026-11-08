// SPDX-License-Identifier: MPL-2.0
//! DecodeJPEG: a file decoded by the codec into a picture the resource
//! allocates.

const sdk = @import("sdk");
const exec = sdk.exec;
const types = sdk.resources.jpeg;
const timer = sdk.devices.timer;
const hardware = sdk.hardware;
const ExecBase = sdk.interface.exec.ExecBase;
const JpegBase = @import("../jpeg_base.zig").JpegBase;
const _header = @import("../header/_header.zig");
const engine = @import("../jpeg_init.zig").engine;
const codaj12 = @import("../codec/_codaj12.zig");
const amd = @import("../codec/_amdgpu.zig");
const ycc = @import("../codec/ycc.zig");
const amdgpu = sdk.resources.amdgpu;
const watchdog = sdk.resources.watchdog;
const WatchdogBase = sdk.interface.watchdog.WatchdogBase;

/// Decodes a JPEG file with the chip's codec.
///
/// SYNOPSIS:
/// ```zig
/// fn DecodeJPEG(jb: *JpegBase, file: [*]const u8, length: u32,
///     picture: *JPEGPicture) u32
/// ```
///
/// SINCE: 1.0. LVO -8.
///
/// INPUTS:
/// - `file` - the file's bytes, from its start. On the ESP32-P4 in memory
///   the 2D-DMA reads: the PSRAM or the internal memory (what AllocVec
///   gives); on the JH7110 and an AMD graphics device anywhere.
/// - `length` - how many there are.
/// - `picture` - filled in.
///
/// RESULT:
/// JPEGERR_OK, and `picture` holds the pixels - `width` x `height` of
/// them from `pixels` on, `pitch` bytes from one row to the next, in
/// `format` (JPEGFMT_BGR24, or JPEGFMT_GREY8 for a grey file). Otherwise
/// why not, and `picture` is all zero: what ExamineJPEG answers for the
/// file, JPEGERR_UNSUPPORTED as well for a file the 2D-DMA cannot read
/// or a picture less than 64 pixels across or down on an AMD graphics
/// device, JPEGERR_NO_MEMORY, JPEGERR_FAILED when the codec stopped on
/// the file or did not finish in time, JPEGERR_NO_ENGINE when there is no
/// codec, it would not wake, or an AMD device's decoder is not started
/// yet and the watchdog is not armed.
///
/// BEHAVIOR:
/// The headers are read and their tables written into the codec, and the
/// picture made in memory the resource allocates on whole cache lines -
/// whole blocks of the file's sampling, so `pitch` and the rows may run
/// past the picture. On the ESP32-P4 the 2D-DMA feeds the codec the file
/// from its scan on and writes the picture, turned into red, green and
/// blue with JFIF's matrix; the caller's task waits on the 2D-DMA's end
/// interrupt, or the codec's error interrupt. On the JH7110 the file is
/// copied below 4 GiB, where the codec reads it, and the codec writes the
/// picture's planes - a grey one straight into the picture - which are
/// then turned into blue, green and red with the same matrix; the first
/// decode wakes the codec and its power domain. On an AMD graphics device
/// the file is copied into the device's own memory without its
/// application data and comments, which the decoder has no use for; the
/// decoder writes the samples there in the form the file's sampling has,
/// and they are copied out and turned into blue, green and red with the
/// same matrix - a grey picture's rows copied as they are. The first
/// decode there finds the decoder through amdgpu.resource and starts it,
/// and starts it only while the watchdog is armed, so that a decoder
/// which stops the machine as it starts has the machine reset. Each
/// waits for at most a quarter of a second and a microsecond for each
/// eight pixels; the CPU is free meanwhile. One decode at a time: a
/// second caller waits for the first.
///
/// The ESP32-P4's and the JH7110's codecs write behind the data cache's
/// back: the file's bytes are written back out of the cache before, the
/// picture dropped from it after, so the caller reads what the codec
/// wrote. An AMD device's memory is written gathered and read by
/// streaming loads, neither of which goes through the cache, so neither
/// is needed there.
///
/// CONTEXT:
/// - Waits: yes, for the codec, and for a decode another task has under
///   way. - Interrupts: no.
/// - Locks: takes the resource's semaphore for the decode.
/// - Process: a Task will do; it opens timer.device for the timeout.
///
/// OWNERSHIP:
/// The picture is the caller's until it gives it to FreeJPEGPicture.
/// `file` is only read, and only during the call.
///
/// NOTES:
/// The codec brings the colour's halved samples to full size its own way
/// - the 2D-DMA, the JH7110's format converter: the picture is close to
/// a software decoder's, not equal.
///
/// BUGS:
/// An AMD device's decoder that does not finish a picture in time is not
/// asked again until the machine restarts, and the device's memory that
/// picture was given stays the decoder's.
///
/// SEE ALSO:
/// `ExamineJPEG`, `FreeJPEGPicture`
///
/// EXAMPLES:
/// ```zig
/// var picture: sdk.resources.jpeg.JPEGPicture = .{};
/// if (jb.DecodeJPEG(bytes.ptr, @intCast(bytes.len), &picture) == jpeg.JPEGERR_OK) {
///     defer jb.FreeJPEGPicture(&picture);
///     // rows from picture.pixels, picture.pitch apart
/// }
/// ```
pub fn DecodeJPEG(jb: *JpegBase, file: [*]const u8, length: u32, picture: *types.JPEGPicture) u32 {
    picture.* = .{};
    const sys = jb.sys_base;
    const memory = sys.AllocVec(@sizeOf(_header.Header), exec.MEMF_ANY) orelse return types.JPEGERR_NO_MEMORY;
    defer sys.FreeVec(memory);
    const h: *_header.Header = @ptrCast(@alignCast(memory));
    _header.read(file[0..length], h) catch |failure| return _header.errorOf(failure);
    return switch (comptime engine) {
        .esp32p4 => decode(jb, file, length, h, picture),
        .codaj12 => decodeJpu(jb, file[0..length], h, picture),
        .amdgpu => decodeGpu(jb, file[0..length], h, picture),
        .none => types.JPEGERR_NO_ENGINE,
    };
}

/// A cache line: the picture starts on one and is whole ones.
const line = hardware.DCACHE_LINE_SIZE;

fn lineUp(n: usize) usize {
    return (n + line - 1) & ~@as(usize, line - 1);
}

/// Whether the 2D-DMA reads `length` bytes from `start`: the PSRAM and the
/// internal memory.
fn reachable(start: usize, length: usize) bool {
    const map = hardware.map;
    const end: u64 = @as(u64, start) + length;
    if (start >= map.PSRAM_START and end <= map.PSRAM_END) return true;
    return start >= map.DRAM_START and end <= map.DRAM_END;
}

/// The decode itself, on the chip.
fn decode(jb: *JpegBase, file: [*]const u8, length: u32, h: *const _header.Header, picture: *types.JPEGPicture) u32 {
    const codec = @import("../codec/_codec.zig");
    const dma2d = hardware.dma2d;
    const sys = jb.sys_base;
    if (jb.dma == null) return types.JPEGERR_NO_ENGINE;
    const scan_at = @intFromPtr(file) + h.scan;
    const scan_length = length - h.scan;
    if (scan_length > dma2d.line_max or !reachable(@intFromPtr(file), length)) return types.JPEGERR_UNSUPPORTED;

    const bytes: u32 = @intCast(lineUp(h.bytes()));
    const memory_size = bytes + line;
    const memory = sys.AllocMem(memory_size, exec.MEMF_ANY) orelse return types.JPEGERR_NO_MEMORY;
    const pixels = lineUp(@intFromPtr(memory));
    const timeout = Timeout.open(sys) orelse {
        sys.FreeMem(memory, memory_size);
        return types.JPEGERR_NO_MEMORY;
    };
    defer timeout.close(sys);

    sys.ObtainSemaphore(&jb.lock);
    defer sys.ReleaseSemaphore(&jb.lock);
    var cached: u32 = scan_length;
    _ = sys.CachePreDMA(@ptrFromInt(scan_at), &cached, exec.DMAF_ReadFromRAM);
    cached = bytes;
    _ = sys.CachePreDMA(@ptrFromInt(pixels), &cached, 0);

    codec.load(h);
    const room = @intFromPtr(&jb.descriptors);
    const parts: codec.Descriptors = .{ .send = @ptrFromInt(room), .receive = @ptrFromInt(room + @sizeOf(dma2d.Descriptor)) };
    const connected = codec.connect(h, parts, scan_at, scan_length, pixels);
    cached = @sizeOf(@TypeOf(jb.descriptors));
    _ = sys.CachePreDMA(@ptrCast(&jb.descriptors), &cached, exec.DMAF_ReadFromRAM);

    var ended: u32 = 0;
    var errors: u32 = 0;
    if (connected) {
        const signal = sys.AllocSignal(-1);
        if (signal >= 0) {
            const mask = @as(u32, 1) << @intCast(signal);
            sys.Disable();
            jb.errors = 0;
            jb.ended = 0;
            jb.waiter_mask = mask;
            jb.waiter = sys.FindTask(null);
            sys.Enable();
            codec.armErrors();
            timeout.start(sys, 250_000 + @as(u64, h.padded_width) * h.padded_height / 8);
            codec.start(room, room + @sizeOf(dma2d.Descriptor));
            while (true) {
                sys.Disable();
                ended = jb.ended;
                errors = jb.errors;
                sys.Enable();
                if (ended != 0 or errors != 0 or timeout.over(sys)) break;
                _ = sys.Wait(mask | timeout.mask());
            }
            timeout.stop(sys);
            sys.Disable();
            jb.waiter = null;
            sys.Enable();
            _ = sys.SetSignal(0, mask);
            sys.FreeSignal(signal);
        }
    }
    codec.finish();

    if (errors != 0 or !dma2d.endedWell(ended)) {
        sys.FreeMem(memory, memory_size);
        return types.JPEGERR_FAILED;
    }
    cached = bytes;
    sys.CachePostDMA(@ptrFromInt(pixels), &cached, 0);
    picture.* = .{
        .pixels = @ptrFromInt(pixels),
        .pitch = h.pitch(),
        .width = h.width,
        .height = h.height,
        .format = h.format(),
        .memory = memory,
        .memory_size = memory_size,
    };
    return types.JPEGERR_OK;
}

/// The JH7110's codec: a page of its bit buffer, which the file's copy
/// and the planes start on.
const page = 256;

fn pageUp(n: usize) usize {
    return (n + page - 1) & ~@as(usize, page - 1);
}

/// The decode itself, on the JH7110's codec.
fn decodeJpu(jb: *JpegBase, file: []const u8, h: *const _header.Header, picture: *types.JPEGPicture) u32 {
    const sys = jb.sys_base;
    if (jb.jpu == 0 or jb.jpu_dead) return types.JPEGERR_NO_ENGINE;
    const coded = codaj12.codedStart(file, h) orelse return types.JPEGERR_CORRUPT;
    const length: u32 = @intCast(file.len);

    // The file's copy on whole pages, and two pages of zeros past it: the
    // codec fetches two pages at a time.
    const stream_bytes: u32 = @intCast(pageUp(length) + 2 * page);
    const stream_size = stream_bytes + page;
    const stream_memory = sys.AllocMem(stream_size, exec.MEMF_DMA) orelse return types.JPEGERR_NO_MEMORY;
    defer sys.FreeMem(stream_memory, stream_size);
    const stream = pageUp(@intFromPtr(stream_memory));
    sys.CopyMem(file.ptr, @ptrFromInt(stream), length);
    sys.SetMem(@ptrFromInt(stream + length), 0, stream_bytes - length);

    // The picture; a grey one is the codec's plane itself, below 4 GiB.
    // A colour one's three planes are the codec's, at full size, apart.
    const grey = h.count == 1;
    const bytes: u32 = @intCast(lineUp(h.bytes()));
    const memory_size = bytes + line;
    const memory = sys.AllocMem(memory_size, if (grey) exec.MEMF_DMA else exec.MEMF_ANY) orelse return types.JPEGERR_NO_MEMORY;
    const pixels = lineUp(@intFromPtr(memory));
    const plane: u32 = @intCast(pageUp(h.padded_width * h.padded_height));
    const planes_size: u32 = if (grey) 0 else 3 * plane + page;
    const planes_memory: ?*anyopaque = if (grey) null else sys.AllocMem(planes_size, exec.MEMF_DMA) orelse {
        sys.FreeMem(memory, memory_size);
        return types.JPEGERR_NO_MEMORY;
    };
    defer if (planes_memory) |m| sys.FreeMem(m, planes_size);
    const y = if (planes_memory) |m| pageUp(@intFromPtr(m)) else pixels;
    const frame: codaj12.Frame = .{
        .stream = stream,
        .length = length,
        .coded = coded,
        .y = y,
        .cb = if (grey) 0 else y + plane,
        .cr = if (grey) 0 else y + 2 * plane,
        .stride = h.padded_width,
    };

    const answer = runJpu(jb, h, frame, stream_bytes, if (grey) bytes else 3 * plane);
    if (answer != types.JPEGERR_OK) {
        sys.FreeMem(memory, memory_size);
        return answer;
    }
    if (!grey) {
        const planes: ycc.Planes = .{
            .y = @ptrFromInt(frame.y),
            .cb = @ptrFromInt(frame.cb),
            .cr = @ptrFromInt(frame.cr),
            .stride = frame.stride,
        };
        ycc.toBgr(planes, @ptrFromInt(pixels), h.pitch(), h.width, h.height);
    }
    picture.* = .{
        .pixels = @ptrFromInt(pixels),
        .pitch = h.pitch(),
        .width = h.width,
        .height = h.height,
        .format = h.format(),
        .memory = memory,
        .memory_size = memory_size,
    };
    return types.JPEGERR_OK;
}

/// Under the lock: the codec woken if it sleeps, the file decoded into
/// `frame`'s planes - `written` bytes from the first on - and waited for.
/// JPEGERR_OK when the codec says done, the planes then out of the cache.
fn runJpu(jb: *JpegBase, h: *const _header.Header, frame: codaj12.Frame, stream_bytes: u32, written: u32) u32 {
    const sys = jb.sys_base;
    const timeout = Timeout.open(sys) orelse return types.JPEGERR_NO_MEMORY;
    defer timeout.close(sys);
    sys.ObtainSemaphore(&jb.lock);
    defer sys.ReleaseSemaphore(&jb.lock);
    if (jb.jpu_dead) return types.JPEGERR_NO_ENGINE;
    if (!jb.jpu_awake) {
        if (!codaj12.wake(jb.jpu, sys, Pause{ .timeout = timeout, .sys = sys })) {
            jb.jpu_dead = true;
            exec.kprintf(sys, "%s: the jh7110 jpu does not wake\n", .{types.JPEGNAME});
            return types.JPEGERR_NO_ENGINE;
        }
        jb.jpu_awake = true;
    }

    var cached: u32 = stream_bytes;
    _ = sys.CachePreDMA(@ptrFromInt(frame.stream), &cached, exec.DMAF_ReadFromRAM);
    cached = written;
    _ = sys.CachePreDMA(@ptrFromInt(frame.y), &cached, 0);

    const ends = codaj12.STATUS_DONE | codaj12.STATUS_ERROR | codaj12.STATUS_EMPTY;
    var ended: u32 = 0;
    const signal = sys.AllocSignal(-1);
    if (signal >= 0) {
        const mask = @as(u32, 1) << @intCast(signal);
        sys.Disable();
        jb.ended = 0;
        jb.waiter_mask = mask;
        jb.waiter = sys.FindTask(null);
        sys.Enable();
        timeout.start(sys, 250_000 + @as(u64, h.padded_width) * h.padded_height / 8);
        if (codaj12.start(jb.jpu, h, frame)) {
            while (true) {
                sys.Disable();
                ended = jb.ended;
                sys.Enable();
                if (ended & ends != 0 or timeout.over(sys)) break;
                _ = sys.Wait(mask | timeout.mask());
            }
        }
        timeout.stop(sys);
        sys.Disable();
        jb.waiter = null;
        sys.Enable();
        _ = sys.SetSignal(0, mask);
        sys.FreeSignal(signal);
    }
    codaj12.finish(jb.jpu);
    if (ended & ends != codaj12.STATUS_DONE) {
        _ = codaj12.reset(jb.jpu);
        return types.JPEGERR_FAILED;
    }
    cached = written;
    sys.CachePostDMA(@ptrFromInt(frame.y), &cached, 0);
    return types.JPEGERR_OK;
}

/// An AMD graphics device's decoder reads the file's copy in steps of 128
/// bytes, and the device's memory is handed out in pages.
const stream_step = 128;
const gpu_page = 4096;

fn stepUp(n: usize, step: usize) usize {
    return (n + step - 1) / step * step;
}

/// The decode itself, on an AMD graphics device's decoder.
fn decodeGpu(jb: *JpegBase, file: []const u8, h: *const _header.Header, picture: *types.JPEGPicture) u32 {
    const sys = jb.sys_base;
    if (jb.gpu.dead) return types.JPEGERR_NO_ENGINE;
    const layout = amd.layoutOf(h) orelse return types.JPEGERR_UNSUPPORTED;
    if (h.width < amd.side_least or h.height < amd.side_least) return types.JPEGERR_UNSUPPORTED;

    // The decoder's copy of the file, with zeros up to a whole step.
    const copy_bytes: u32 = @intCast(stepUp(file.len, stream_step));
    const copy_memory = sys.AllocVec(copy_bytes, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return types.JPEGERR_NO_MEMORY;
    defer sys.FreeVec(copy_memory);
    const copy: [*]u8 = @ptrCast(copy_memory);
    const length = amd.stream(file, h, copy[0..copy_bytes]) orelse return types.JPEGERR_CORRUPT;
    const stream_bytes: u32 = @intCast(stepUp(length, stream_step));

    // The picture, and the samples copied out as the decoder laid them
    // out: a grey picture's rows copied from them, a colour one's turned.
    const bytes: u32 = @intCast(lineUp(h.bytes()));
    const memory_size = bytes + line;
    const memory = sys.AllocMem(memory_size, exec.MEMF_ANY) orelse return types.JPEGERR_NO_MEMORY;
    const pixels = lineUp(@intFromPtr(memory));
    const samples_memory = sys.AllocVec(layout.bytes, exec.MEMF_ANY) orelse {
        sys.FreeMem(memory, memory_size);
        return types.JPEGERR_NO_MEMORY;
    };
    defer sys.FreeVec(samples_memory);
    const samples: [*]u8 = @ptrCast(samples_memory);

    const answer = runGpu(jb, h, copy, stream_bytes, layout, samples);
    if (answer != types.JPEGERR_OK) {
        sys.FreeMem(memory, memory_size);
        return answer;
    }
    const to: [*]u8 = @ptrFromInt(pixels);
    switch (h.sampling) {
        types.JPEGSAMP_GREY => {
            var row: u32 = 0;
            while (row < h.padded_height) : (row += 1) sys.CopyMem(samples + @as(usize, row) * layout.pitch, to + @as(usize, row) * h.pitch(), h.pitch());
        },
        types.JPEGSAMP_420 => ycc.halvedToBgr(samples, samples + layout.chroma, layout.pitch, to, h.pitch(), h.width, h.height),
        types.JPEGSAMP_422 => ycc.pairsToBgr(samples, layout.pitch, to, h.pitch(), h.width, h.height),
        else => ycc.toBgr(.{ .y = samples, .cb = samples + layout.chroma, .cr = samples + layout.chromav, .stride = layout.pitch }, to, h.pitch(), h.width, h.height),
    }
    picture.* = .{
        .pixels = @ptrFromInt(pixels),
        .pitch = h.pitch(),
        .width = h.width,
        .height = h.height,
        .format = h.format(),
        .memory = memory,
        .memory_size = memory_size,
    };
    return types.JPEGERR_OK;
}

/// Under the lock: the AMD device's decoder found and started if it is
/// not, the file's copy - `stream_bytes` of `copy` - decoded in the
/// device's memory and waited for, and the samples copied out to `out`
/// as `layout` has them.
fn runGpu(jb: *JpegBase, h: *const _header.Header, copy: [*]const u8, stream_bytes: u32, layout: amd.Layout, out: [*]u8) u32 {
    const sys = jb.sys_base;
    const timeout = Timeout.open(sys) orelse return types.JPEGERR_NO_MEMORY;
    defer timeout.close(sys);
    const waiter = Pause{ .timeout = timeout, .sys = sys };
    sys.ObtainSemaphore(&jb.lock);
    defer sys.ReleaseSemaphore(&jb.lock);
    if (jb.gpu.dead) return types.JPEGERR_NO_ENGINE;
    if (!jb.gpu.awake) {
        if (jb.gpu.gpu == null and !amd.find(sys, &jb.gpu)) {
            jb.gpu.dead = true;
            return types.JPEGERR_NO_ENGINE;
        }
        if (!mayStart(sys)) return types.JPEGERR_NO_ENGINE;
        if (!amd.wake(sys, &jb.gpu, waiter)) {
            jb.gpu.dead = true;
            return types.JPEGERR_NO_ENGINE;
        }
        jb.gpu.awake = true;
    }
    const gpu = jb.gpu.gpu.?;

    // The file's copy, then the samples, in one piece of the device's
    // memory.
    const target_at: u32 = @intCast(stepUp(stream_bytes, gpu_page));
    var piece: amdgpu.GPUMemory = .{};
    if (!gpu.AllocGPUMemory(target_at + layout.bytes, gpu_page, &piece)) return types.JPEGERR_NO_MEMORY;
    amd.toDevice(piece.cpu, copy[0..stream_bytes]);
    if (!amd.decode(&jb.gpu, piece.device, stream_bytes, piece.device + target_at, layout)) {
        gpu.FreeGPUMemory(&piece);
        return types.JPEGERR_FAILED;
    }
    if (!amd.waitFence(&jb.gpu, 250_000 + @as(u64, h.padded_width) * h.padded_height / 8, waiter)) {
        // The decoder may still read and write the piece: it keeps it,
        // and is not asked again.
        amd.report(sys, &jb.gpu, "did not finish a picture");
        jb.gpu.dead = true;
        return types.JPEGERR_FAILED;
    }
    amd.streamFromDevice(out, piece.cpu + target_at, layout.bytes);
    gpu.FreeGPUMemory(&piece);
    return types.JPEGERR_OK;
}

/// Whether the AMD device's decoder may be started: only while the
/// watchdog is armed.
fn mayStart(sys: *ExecBase) bool {
    const wb: *WatchdogBase = @ptrCast(@alignCast(sys.OpenResource(watchdog.WATCHDOGNAME) orelse return false));
    return wb.ReadWatchdog() != 0;
}

/// A wait of so many microseconds on the decode's timer, for waking the
/// codec and, on an AMD device, for its fence.
const Pause = struct {
    timeout: Timeout,
    sys: *ExecBase,

    pub fn wait(p: Pause, us: u32) void {
        p.timeout.start(p.sys, us);
        _ = p.sys.WaitIO(&p.timeout.request.node);
    }
};

/// timer.device, for how long a decode may take.
const Timeout = struct {
    request: *timer.TimeRequest,

    fn open(sys: *ExecBase) ?Timeout {
        const port = sys.CreateMsgPort() orelse return null;
        const io = sys.CreateIORequest(port, @sizeOf(timer.TimeRequest)) orelse {
            sys.DeleteMsgPort(port);
            return null;
        };
        if (sys.OpenDevice(timer.TIMERNAME, timer.UNIT_MICROHZ, io, 0) != 0) {
            sys.DeleteIORequest(io);
            sys.DeleteMsgPort(port);
            return null;
        }
        return .{ .request = @fieldParentPtr("node", io) };
    }

    fn close(t: Timeout, sys: *ExecBase) void {
        const port = t.request.node.message.reply_port;
        sys.CloseDevice(&t.request.node);
        sys.DeleteIORequest(&t.request.node);
        sys.DeleteMsgPort(port);
    }

    fn mask(t: Timeout) u32 {
        return t.request.node.message.reply_port.?.sigMask();
    }

    fn start(t: Timeout, sys: *ExecBase, us: u64) void {
        _ = sys.SetSignal(0, t.mask());
        t.request.node.command = timer.TR_ADDREQUEST;
        t.request.time = timer.TimeVal.fromMicros(us);
        sys.SendIO(&t.request.node);
    }

    fn over(t: Timeout, sys: *ExecBase) bool {
        return sys.CheckIO(&t.request.node) != null;
    }

    fn stop(t: Timeout, sys: *ExecBase) void {
        _ = sys.AbortIO(&t.request.node);
        _ = sys.WaitIO(&t.request.node);
    }
};
