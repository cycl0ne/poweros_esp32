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
const on_chip = @import("../jpeg_init.zig").on_chip;

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
/// - `file` - the file's bytes, from its start, in memory the 2D-DMA
///   reads: the PSRAM or the internal memory (what AllocVec gives).
/// - `length` - how many there are.
/// - `picture` - filled in.
///
/// RESULT:
/// JPEGERR_OK, and `picture` holds the pixels - `width` x `height` of
/// them from `pixels` on, `pitch` bytes from one row to the next, in
/// `format` (JPEGFMT_BGR24, or JPEGFMT_GREY8 for a grey file). Otherwise
/// why not, and `picture` is all zero: what ExamineJPEG answers for the
/// file, JPEGERR_UNSUPPORTED as well for a file the 2D-DMA cannot read,
/// JPEGERR_NO_MEMORY, JPEGERR_FAILED when the codec stopped on the file
/// or did not finish in time, JPEGERR_NO_ENGINE when there is no codec.
///
/// BEHAVIOR:
/// The headers are read and their tables written into the codec; the
/// 2D-DMA feeds it the file from its scan on and writes the picture,
/// turned into red, green and blue with JFIF's matrix, into memory the
/// resource allocates on whole cache lines - whole blocks of the file's
/// sampling, so `pitch` and the rows may run past the picture. The
/// caller's task waits on the 2D-DMA's end interrupt, or the codec's
/// error interrupt, for at most a quarter of a second and a microsecond
/// for each eight pixels; the CPU is free meanwhile. One decode at a time:
/// a second caller waits for the first.
///
/// The codec writes behind the data cache's back: the file's bytes are
/// written back out of the cache before, the picture dropped from it
/// after, so the caller reads what the codec wrote.
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
/// The 2D-DMA brings the colour's halved samples to full size its own
/// way: the picture is close to a software decoder's, not equal.
///
/// BUGS:
/// None known.
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
    return if (comptime on_chip) decode(jb, file, length, h, picture) else types.JPEGERR_NO_ENGINE;
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
