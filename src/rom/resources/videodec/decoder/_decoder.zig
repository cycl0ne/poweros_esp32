// SPDX-License-Identifier: MPL-2.0
//! A decoder: the resource's half of what OpenVideoDecoder hands out, and
//! what the calls share - the stream's ring, the times of its pictures,
//! the frames, and the waits for the chip.
//!
//! **The ring**: the stream's bytes as they were fed, in DMA memory the
//! chip reads; the resource writes from `wr`, the chip reads from where it
//! last said (`rd`). One byte stays free, so a full ring is not an empty
//! one.
//!
//! **The times**: each picture fed puts its time in `fed`; each picture
//! the chip decodes takes the oldest from there into `waiting`; each frame
//! shown takes the earliest of those - the order frames are shown in is
//! the order of their times.
//!
//! **The frames**: when the sequence is read, one block for all of them -
//! the compressed frames the chip keeps for reference with their motion
//! vectors and offset tables, the shown frames in NV12, the task buffer -
//! each piece on a page.

const sdk = @import("sdk");
const exec = sdk.exec;
const types = sdk.resources.videodec;
const ExecBase = sdk.interface.exec.ExecBase;
const VideoDecBase = @import("../videodec_base.zig").VideoDecBase;
const wave511 = @import("../codec/_wave511.zig");

/// How long the chip may take over a command it queued: far longer than
/// a 4K picture takes.
pub const patience_us: u64 = 500_000;

/// How many pictures may be fed and not yet decoded.
pub const fed_max = 64;

/// The most frames the caller may hold at once.
pub const held_max = 16;

/// A block of memory the chip reads or writes: below 4 GiB, on a page,
/// the system's - so it outlives a task that ends with the decoder open,
/// as the chip may still write it.
pub const Block = struct {
    memory: ?*anyopaque = null,
    size: usize = 0,
    address: usize = 0,

    pub fn alloc(sys: *ExecBase, bytes: usize) ?Block {
        const size = bytes + wave511.page;
        const memory = sys.AllocMem(size, exec.MEMF_DMA | exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return null;
        const address = (@intFromPtr(memory) + wave511.page - 1) & ~@as(usize, wave511.page - 1);
        if (address + bytes > 0x1_0000_0000) {
            sys.FreeMem(memory, size);
            return null;
        }
        // Written back, cleared, before the chip writes into it.
        var length: u32 = @intCast(bytes);
        _ = sys.CachePreDMA(@ptrFromInt(address), &length, 0);
        return .{ .memory = memory, .size = size, .address = address };
    }

    pub fn free(b: *Block, sys: *ExecBase) void {
        if (b.memory) |memory| sys.FreeMem(memory, b.size);
        b.* = .{};
    }

    /// Where the chip sees it.
    pub fn bus(b: Block) u32 {
        return @intCast(b.address);
    }
};

/// Times in the order they were put, `fed_max` at most.
pub const Fifo = struct {
    times: [fed_max]u64 = undefined,
    first: u32 = 0,
    count: u32 = 0,

    pub fn full(f: *const Fifo) bool {
        return f.count == fed_max;
    }

    pub fn put(f: *Fifo, time: u64) void {
        f.times[(f.first + f.count) % fed_max] = time;
        f.count += 1;
    }

    /// The oldest, taken; 0 when there is none.
    pub fn take(f: *Fifo) u64 {
        if (f.count == 0) return 0;
        const time = f.times[f.first];
        f.first = (f.first + 1) % fed_max;
        f.count -= 1;
        return time;
    }

    pub fn clear(f: *Fifo) void {
        f.first = 0;
        f.count = 0;
    }
};

/// Times in no order, the earliest taken first: the pictures decoded and
/// not yet shown. As many as the chip holds back.
pub const Waiting = struct {
    times: [wave511.max_frames + 1]u64 = undefined,
    count: u32 = 0,

    /// A time put in; when there is no room, the earliest goes first.
    pub fn put(w: *Waiting, time: u64) void {
        if (w.count == w.times.len) _ = w.takeEarliest();
        w.times[w.count] = time;
        w.count += 1;
    }

    /// The earliest, taken; 0 when there is none.
    pub fn takeEarliest(w: *Waiting) u64 {
        if (w.count == 0) return 0;
        var best: u32 = 0;
        var k: u32 = 1;
        while (k < w.count) : (k += 1) {
            if (w.times[k] < w.times[best]) best = k;
        }
        const time = w.times[best];
        w.count -= 1;
        w.times[best] = w.times[w.count];
        return time;
    }

    pub fn clear(w: *Waiting) void {
        w.count = 0;
    }
};

/// The bytes that can still be written into a ring of `size` bytes,
/// written up to `wr` and read up to `rd`.
pub fn room(rd: u32, wr: u32, size: u32) u32 {
    return if (wr < rd) rd - wr - 1 else size - (wr - rd) - 1;
}

/// Where a decoder is.
pub const Phase = enum(u8) {
    /// Its sequence not read yet.
    fresh,
    /// Its frames made; pictures are decoded.
    running,
    /// The chip stopped on its stream, or the stream is one it does not
    /// take: what is left is CloseVideoDecoder.
    broken,
};

/// What the chip is still doing for it: a command queued and not done.
pub const Pending = enum(u8) { none, sequence, picture };

pub const Decoder = struct {
    vb: *VideoDecBase,
    instance: wave511.Instance,
    codec: u32,
    /// The frames the caller may hold, besides what the stream needs.
    held: u32,
    work: Block = .{},
    ring: Block = .{},
    ring_size: u32 = 0,
    wr: u32 = 0,
    rd: u32 = 0,
    fed: Fifo = .{},
    waiting: Waiting = .{},
    /// The stream's end fed, and every frame handed out since.
    end_fed: bool = false,
    ended: bool = false,
    phase: Phase = .fresh,
    pending: Pending = .none,
    seq: wave511.Sequence = .{},
    layout: wave511.Layout = undefined,
    /// The frames: their block, the shown ones' addresses, how many of
    /// each kind, which shown ones are lent to the caller.
    frames: Block = .{},
    linear: [wave511.max_frames]u32 = @splat(0),
    linear_count: u32 = 0,
    fbc_count: u32 = 0,
    lent: u32 = 0,
    /// How many frames were shown.
    shown: u32 = 0,
    /// What the chip finished for this instance (wave511.INT_INIT_SEQ,
    /// INT_DEC_PIC), and the waitable the server signals: both the
    /// server's to set.
    raised: u32 = 0,
    done: exec.Waitable = .{},

    pub fn of(h: *types.VideoDecoder) *Decoder {
        return @ptrCast(@alignCast(h));
    }

    pub fn handle(d: *Decoder) *types.VideoDecoder {
        return @ptrCast(d);
    }

    fn sys(d: *Decoder) *ExecBase {
        return d.vb.sys_base;
    }

    /// The chip's answer to a queued command: until it raised `bit` for
    /// this instance - true - or the time ran out. One command is queued
    /// at a time, so whatever else it raised is from before, and dropped.
    fn waitFor(d: *Decoder, bit: u32) bool {
        const s = d.sys();
        const waitables = [_]*exec.Waitable{&d.done};
        const until = sdk.hardware.systimer.uptimeUs() + patience_us;
        while (true) {
            s.Disable();
            const got = d.raised & bit != 0;
            d.raised = 0;
            s.ResetWaitable(&d.done);
            s.Enable();
            if (got) return true;
            const now = sdk.hardware.systimer.uptimeUs();
            if (now >= until) return false;
            _ = s.WaitForAny(&waitables, 1, until - now);
        }
    }

    /// What the chip raised for this instance forgotten.
    pub fn forgetRaised(d: *Decoder) void {
        const s = d.sys();
        s.Disable();
        d.raised = 0;
        s.ResetWaitable(&d.done);
        s.Enable();
    }

    /// Where the chip reads the stream, as an offset in the ring; kept
    /// as it was when the chip would not say.
    fn readBack(d: *Decoder) void {
        const at = d.instance.readPointer() orelse return;
        if (at >= d.ring.bus() and at < d.ring.bus() + d.ring_size) d.rd = at - d.ring.bus();
    }

    /// The command the chip queued for this instance waited for and its
    /// result fetched; false, and the decoder broken, when it did not
    /// come.
    fn finish(d: *Decoder, bit: u32) bool {
        d.pending = .none;
        if (!d.waitFor(bit) or !d.instance.fetchResult()) {
            d.phase = .broken;
            return false;
        }
        return true;
    }

    /// The sequence read from what was fed, and the frames made for it:
    /// VDERR_OK, VDERR_NEED_DATA when what was fed holds none yet, or why
    /// not.
    pub fn startSequence(d: *Decoder) u32 {
        if (d.phase == .broken) return types.VDERR_CORRUPT;
        if (d.phase == .running) return types.VDERR_OK;
        if (d.fed.count == 0 and !d.end_fed) return types.VDERR_NEED_DATA;
        const ring = d.ring.bus();
        d.forgetRaised();
        if (!d.instance.initSeq(ring + d.rd, ring + d.wr, d.end_fed)) {
            d.phase = .broken;
            return types.VDERR_CORRUPT;
        }
        d.pending = .sequence;
        if (!d.finish(wave511.INT_INIT_SEQ)) return types.VDERR_CORRUPT;
        const seq = d.instance.sequence();
        d.readBack();
        if (!seq.ok) {
            // No sequence in what was fed: those pictures cannot be
            // decoded, and are passed over.
            d.fed.clear();
            if (d.end_fed) {
                d.phase = .broken;
                return types.VDERR_CORRUPT;
            }
            return types.VDERR_NEED_DATA;
        }
        if (seq.luma_depth > 8 or seq.chroma_depth > 8 or seq.width == 0 or seq.height == 0 or
            seq.width > 8192 or seq.height > 4320 or seq.left + seq.right >= seq.width or
            seq.top + seq.bottom >= seq.height)
        {
            d.phase = .broken;
            return types.VDERR_UNSUPPORTED;
        }
        d.seq = seq;
        const made = d.makeFrames();
        if (made != types.VDERR_OK) {
            d.phase = .broken;
            return made;
        }
        d.phase = .running;
        return types.VDERR_OK;
    }

    /// The frames the sequence needs made and given to the chip.
    fn makeFrames(d: *Decoder) u32 {
        const s = d.sys();
        const l = wave511.Layout.of(d.instance.std, d.seq.width, d.seq.height);
        d.layout = l;
        d.fbc_count = @min(d.seq.frames + 1, wave511.max_frames);
        d.linear_count = @min(d.seq.frames + 1 + d.held, wave511.max_frames);
        const fbc_one = pageUp(l.fbc_bytes) + l.y_table + l.c_table + l.mv;
        const linear_one = pageUp(l.linear_bytes);
        const task_size = wave511.taskSize(d.seq);
        const total = @as(usize, d.fbc_count) * fbc_one + @as(usize, d.linear_count) * linear_one + pageUp(task_size);
        d.frames = Block.alloc(s, total) orelse return types.VDERR_NO_MEMORY;

        var fbc: [wave511.max_frames]wave511.Frame = undefined;
        var linear: [wave511.max_frames]wave511.Frame = undefined;
        var next = d.frames.bus();
        for (fbc[0..d.fbc_count]) |*f| {
            f.* = .{ .y = next, .cb = next + l.fbc_luma };
            next += pageUp(l.fbc_bytes);
            f.y_table = next;
            next += l.y_table;
            f.c_table = next;
            next += l.c_table;
            f.mv = next;
            next += l.mv;
        }
        for (linear[0..d.linear_count], 0..) |*f, k| {
            f.* = .{ .y = next, .cb = next + l.linear_luma, .cr = next + l.linear_luma + l.linear_luma / 4 };
            d.linear[k] = next;
            next += linear_one;
        }
        const task = next;

        const ok = d.instance.setFrames(.{
            .linear = true,
            .width = d.seq.width,
            .height = d.seq.height,
            .stride = l.stride,
            .frames = linear[0..d.linear_count],
            .count = d.linear_count,
        }) and d.instance.setFrames(.{
            .linear = false,
            .width = d.seq.width,
            .height = d.seq.height,
            .stride = l.stride,
            .frames = fbc[0..d.fbc_count],
            .count = d.fbc_count,
            .task = task,
            .task_size = task_size,
        });
        if (!ok) {
            d.frames.free(s);
            return types.VDERR_CORRUPT;
        }
        // Every shown frame free for the chip to write.
        var k: u32 = 0;
        while (k < d.linear_count) : (k += 1) _ = d.instance.releaseFrame(k);
        d.lent = 0;
        return types.VDERR_OK;
    }

    /// The next frame to be shown, into `frame`: as DecodeVideoFrame
    /// answers.
    pub fn nextFrame(d: *Decoder, frame: *types.VideoDecFrame) u32 {
        const started = d.startSequence();
        if (started != types.VDERR_OK) return started;
        if (d.ended) return types.VDERR_END;
        const ring = d.ring.bus();
        // Each picture fed is decoded once, each frame shown once: a chip
        // that answers neither for longer than that has lost the stream.
        var tries: u32 = d.fed.count + d.linear_count + 4;
        while (tries > 0) : (tries -= 1) {
            if (d.pending == .none) {
                if (d.fed.count == 0 and !d.end_fed) return types.VDERR_NEED_DATA;
                d.forgetRaised();
                if (!d.instance.decodePicture(ring + d.rd, ring + d.wr, d.end_fed)) {
                    d.phase = .broken;
                    return types.VDERR_CORRUPT;
                }
                d.pending = .picture;
            }
            if (!d.finish(wave511.INT_DEC_PIC)) return types.VDERR_CORRUPT;
            const pic = d.instance.picture();
            d.readBack();
            if (pic.decoded >= 0) {
                d.waiting.put(d.fed.take());
            } else if (pic.decoded == wave511.DECODED_SKIPPED) {
                _ = d.fed.take();
            }
            if (pic.changed) {
                const now = d.instance.sequence();
                if (now.width != d.seq.width or now.height != d.seq.height or now.frames > d.seq.frames or
                    now.luma_depth != d.seq.luma_depth)
                {
                    d.phase = .broken;
                    return types.VDERR_UNSUPPORTED;
                }
            }
            if (pic.shown >= 0 and pic.shown < d.linear_count) {
                d.hand(@intCast(pic.shown), frame);
                return types.VDERR_OK;
            }
            if (pic.shown == wave511.SHOWN_END) {
                d.ended = true;
                return types.VDERR_END;
            }
            // Nothing decoded and nothing to show: every shown frame lent,
            // or the stream holds no picture where it was read.
            if (pic.decoded == wave511.DECODED_NONE and !d.end_fed) {
                return if (d.fed.count == 0) types.VDERR_NEED_DATA else types.VDERR_FULL;
            }
        }
        d.phase = .broken;
        return types.VDERR_CORRUPT;
    }

    /// Shown frame `index` handed out in `frame`, its bytes dropped from
    /// the caches first.
    fn hand(d: *Decoder, index: u32, frame: *types.VideoDecFrame) void {
        const l = d.layout;
        const y = d.linear[index];
        var length: u32 = l.linear_bytes;
        d.sys().CachePostDMA(@ptrFromInt(y), &length, 0);
        const left = d.seq.left & ~@as(u32, 1);
        const top = d.seq.top & ~@as(u32, 1);
        frame.* = .{
            .y = @ptrFromInt(y + top * l.stride + left),
            .cbcr = @ptrFromInt(y + l.linear_luma + top / 2 * l.stride + left),
            .pitch = l.stride,
            .width = d.seq.width - d.seq.left - d.seq.right,
            .height = d.seq.height - d.seq.top - d.seq.bottom,
            .format = types.VDFMT_NV12,
            .time = d.waiting.takeEarliest(),
            .number = d.shown,
            .private = .{ index + 1, d.instance.id, 0 },
        };
        d.shown += 1;
        d.lent |= @as(u32, 1) << @intCast(index);
    }

    /// A frame the caller hands back: the chip may write it again.
    pub fn release(d: *Decoder, frame: *types.VideoDecFrame) void {
        const number = frame.private[0];
        frame.* = .{};
        if (number == 0 or number > d.linear_count) return;
        const index = number - 1;
        const bit = @as(u32, 1) << @intCast(index);
        if (d.lent & bit == 0) return;
        d.lent &= ~bit;
        if (d.phase == .running) _ = d.instance.releaseFrame(index);
    }

    /// One picture's bytes written into the ring and the chip told:
    /// as FeedVideoDecoder answers.
    pub fn feed(d: *Decoder, data: ?[*]const u8, length: u32, time: u64, flags: u32) u32 {
        if (d.phase == .broken) return types.VDERR_CORRUPT;
        if (d.end_fed) return types.VDERR_END;
        if (length > 0) {
            const bytes = data orelse return types.VDERR_CORRUPT;
            if (d.fed.full() or length > room(d.rd, d.wr, d.ring_size)) {
                d.readBack();
                if (d.fed.full() or length > room(d.rd, d.wr, d.ring_size)) return types.VDERR_FULL;
            }
            const s = d.sys();
            const first = @min(length, d.ring_size - d.wr);
            const into: [*]u8 = @ptrFromInt(d.ring.address);
            s.CopyMem(bytes, into + d.wr, first);
            var flushed: u32 = first;
            _ = s.CachePreDMA(into + d.wr, &flushed, exec.DMAF_ReadFromRAM);
            if (first < length) {
                s.CopyMem(bytes + first, into, length - first);
                flushed = length - first;
                _ = s.CachePreDMA(into, &flushed, exec.DMAF_ReadFromRAM);
            }
            d.wr = (d.wr + length) % d.ring_size;
            d.fed.put(time);
        }
        if (flags & types.VDFEED_END != 0) d.end_fed = true;
        if (!d.instance.updateStream(d.ring.bus() + d.wr, d.end_fed)) {
            d.phase = .broken;
            return types.VDERR_CORRUPT;
        }
        return types.VDERR_OK;
    }

    /// What was fed and not shown dropped: the ring empty from where the
    /// chip reads, the stream not ended.
    pub fn flush(d: *Decoder) void {
        if (d.pending != .none) {
            _ = d.waitFor(if (d.pending == .sequence) wave511.INT_INIT_SEQ else wave511.INT_DEC_PIC);
            _ = d.instance.fetchResult();
            d.pending = .none;
        }
        if (!d.instance.flush()) d.phase = .broken;
        d.readBack();
        d.wr = d.rd;
        d.fed.clear();
        d.waiting.clear();
        d.end_fed = false;
        d.ended = false;
        d.forgetRaised();
        if (d.phase != .broken) _ = d.instance.updateStream(d.ring.bus() + d.wr, false);
    }

    /// The instance ended and everything of the decoder freed but itself.
    pub fn end(d: *Decoder) void {
        const s = d.sys();
        if (d.pending != .none) {
            _ = d.waitFor(if (d.pending == .sequence) wave511.INT_INIT_SEQ else wave511.INT_DEC_PIC);
            _ = d.instance.fetchResult();
            d.pending = .none;
        }
        _ = d.instance.flush();
        const gone = d.instance.destroy();
        if (gone) {
            d.frames.free(s);
            d.ring.free(s);
            d.work.free(s);
        }
        // An instance the firmware would not let go keeps its memory: the
        // chip may still write it.
    }
};

inline fn pageUp(v: u32) u32 {
    return (v + wave511.page - 1) & ~(wave511.page - 1);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "the ring's room: one byte stays free, a wrapped write counts from the end" {
    try testing.expectEqual(@as(u32, 99), room(0, 0, 100));
    try testing.expectEqual(@as(u32, 59), room(0, 40, 100));
    try testing.expectEqual(@as(u32, 0), room(41, 40, 100));
    try testing.expectEqual(@as(u32, 29), room(70, 40, 100));
    try testing.expectEqual(@as(u32, 79), room(90, 10, 100));
    try testing.expectEqual(@as(u32, 99), room(55, 55, 100));
}

test "the fed times come out oldest first, as many as were put" {
    var f: Fifo = .{};
    var k: u64 = 0;
    while (k < fed_max) : (k += 1) f.put(k * 40);
    try testing.expect(f.full());
    try testing.expectEqual(@as(u64, 0), f.take());
    try testing.expectEqual(@as(u64, 40), f.take());
    f.put(9999);
    while (f.count > 1) _ = f.take();
    try testing.expectEqual(@as(u64, 9999), f.take());
    try testing.expectEqual(@as(u64, 0), f.take());
}

test "the decoded ones are shown earliest first, as a B frame reorders them" {
    // Decode order I0 P3 B1 B2: shown 0, 1, 2, 3.
    var w: Waiting = .{};
    w.put(0);
    w.put(120);
    try testing.expectEqual(@as(u64, 0), w.takeEarliest());
    w.put(40);
    w.put(80);
    try testing.expectEqual(@as(u64, 40), w.takeEarliest());
    try testing.expectEqual(@as(u64, 80), w.takeEarliest());
    try testing.expectEqual(@as(u64, 120), w.takeEarliest());
    try testing.expectEqual(@as(u64, 0), w.takeEarliest());
}
