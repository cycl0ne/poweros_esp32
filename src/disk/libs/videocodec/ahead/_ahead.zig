// SPDX-License-Identifier: MIT
//! A film's pictures decoded ahead (`VCA_DecodeAhead`, SINCE 1.14): a
//! process of the library's ("videocodec pictures") decodes them into a
//! queue a few frames long, and DecodeVideoFrame takes the next from its
//! front. How long a frame takes to decode varies with the frame: a key
//! frame of a 4K AV1 film takes the AMD decoder up to 40 ms, the frames
//! between it a few. Decoded on the task that shows them, each large one
//! is late; decoded ahead, the frames around it make up for it, and the
//! film keeps its rate while the queue has frames in it.
//!
//! **Who calls the decoder.** The process, while it runs: for each frame
//! it holds `decoder_lock` over the frames given back, the frame decoded
//! and its place in the queue. The caller takes the lock for what has to
//! reach the decoder itself - a seek, what the decoder read of the
//! stream - and so waits at most for the frame being decoded. Every call
//! into the codec module and every read of the picture track is under
//! the lock, so the module is called by one task at a time.
//!
//! **The queue and what is given back** are under `lock`, held for a few
//! words at a time. The process appends a frame, or why there was none,
//! and signals `filled`. The caller takes from the front, and a frame it
//! gives back goes into `given_back`, which the process hands to the
//! decoder before it decodes again. Either signals `wanted` to wake the
//! process. The decoder lends a frame for each place in the queue on top
//! of the caller's VIDEO_HELD_FRAMES, so a slot is free whenever the
//! queue has room; `taken` says which are in use - queued, held or given
//! back and not yet handed over.
//!
//! **The end, and errors.** VCERR_END, or an error the decoder does not
//! go past, is queued like a frame and stops the process until a seek;
//! once the queue is empty the caller is handed it again. A picture the
//! decoder stopped on (VCERR_CORRUPT) is queued, and the next decoded.
//!
//! **Decoded in line** - the caller decodes the next frame when the
//! queue is empty - when no process can be made, and on the host, whose
//! tests' exec runs none (`decode_inline`).

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const vc = sdk.videocodec;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;
const _codec = @import("../codec/_codec.zig");

/// Decoded on the caller's task, not a process: set by the host's tests.
pub var decode_inline = false;

const process_name = "videocodec pictures";
/// The decoders run on it: a software decoder's share of each picture,
/// as on the task that would have asked.
const process_stack = 8192 * @sizeOf(usize);

/// A frame decoded, lent in `slot`, or why there was none.
const Entry = struct {
    result: i32 = vc.VCERR_OK,
    slot: u32 = 0,
    frame: vc.VideoFrame = .{},
};

pub const Ahead = struct {
    sys: *ExecBase,
    stream: *Stream,
    /// How many frames are decoded ahead.
    depth: u32,

    /// Held by whoever calls the decoder or reads the picture track.
    decoder_lock: exec.SignalSemaphore,
    /// The decoder's slots in use, a bit each; under `decoder_lock`.
    taken: u32,

    // Under `lock`.
    lock: exec.SignalSemaphore,
    queue: [vc.VIDEO_MOST_AHEAD]Entry,
    first: u32,
    count: u32,
    /// The slots of the frames the caller gave back, a bit each.
    given_back: u32,
    /// What stopped the decoding - VCERR_END or an error - 0 while it
    /// goes on.
    stopped: i32,
    quit: bool,
    /// Signalled when a frame is queued.
    filled: exec.Waitable,
    /// Signalled when the process has something to do: room in the
    /// queue, a frame given back, a seek, its end.
    wanted: exec.Waitable,

    process: ?*dos.Process,
    ended: exec.Message,
};

/// The pictures of `s` decoded ahead, `depth` frames - by a process of
/// its own, or in line when none can be made - or null without memory.
pub fn create(s: *Stream, depth: u32) ?*Ahead {
    const sys = s.sys;
    // Cleared: every field starts at zero.
    const memory = sys.AllocVec(@sizeOf(Ahead), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const a: *Ahead = @ptrCast(@alignCast(memory));
    a.sys = sys;
    a.stream = s;
    a.depth = depth;
    sys.InitSemaphore(&a.decoder_lock);
    sys.InitSemaphore(&a.lock);
    a.queue = @splat(.{});
    a.ended = .{ .length = @sizeOf(exec.Message) };
    if (decode_inline) return a;
    // A step below the caller, which wants a core at once when a frame
    // is due.
    const priority = @max(@as(isize, sys.FindTask(null).?.node.pri) - 1, -128);
    const tags = [_]utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&decoderEntry) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(process_name) },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(a) },
        .{ .tag = dos.NP_StackSize, .data = process_stack },
        .{ .tag = dos.NP_Priority, .data = @bitCast(priority) },
        .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&a.ended) },
        .{},
    };
    a.process = s.base.dos_base.CreateNewProc(&tags);
    return a;
}

/// The process told to end and waited for, and the queue given back.
/// The frames in it, and those given back, are still lent: they go with
/// the decoder.
pub fn destroy(a: *Ahead) void {
    const sys = a.sys;
    if (a.process != null) {
        // The word that it is gone comes to a port of the task closing.
        const port = sys.CreateMsgPort();
        sys.ObtainSemaphore(&a.lock);
        a.ended.reply_port = port;
        a.quit = true;
        sys.SignalWaitable(&a.wanted);
        sys.ReleaseSemaphore(&a.lock);
        if (port) |own| {
            gone: while (true) {
                _ = sys.WaitPort(own);
                while (sys.GetMsg(own)) |message| {
                    if (message == &a.ended) break :gone;
                }
            }
            sys.DeleteMsgPort(own);
        } else {
            // No port to hear it on: the message comes back freed.
            while (a.ended.node.type != .freemsg) a.stream.base.dos_base.Delay(1);
        }
    }
    sys.FreeVec(a);
}

/// The next frame into `frame` and the slot it is lent in, from the
/// queue - waited for while it is empty, or decoded here in line: its
/// result, VCERR_OK for a frame.
pub fn take(a: *Ahead, frame: *vc.VideoFrame, slot: *u32) i32 {
    const sys = a.sys;
    const filled = [1]*exec.Waitable{&a.filled};
    while (true) {
        sys.ObtainSemaphore(&a.lock);
        if (a.count != 0) {
            const entry = a.queue[a.first];
            a.first = (a.first + 1) % @as(u32, a.queue.len);
            a.count -= 1;
            sys.SignalWaitable(&a.wanted);
            sys.ReleaseSemaphore(&a.lock);
            if (entry.result == vc.VCERR_OK) {
                frame.* = entry.frame;
                slot.* = entry.slot;
            }
            return entry.result;
        }
        const stopped = a.stopped;
        // Reset while the queue is seen empty: a frame queued after it
        // signals again.
        if (stopped == 0) sys.ResetWaitable(&a.filled);
        sys.ReleaseSemaphore(&a.lock);
        if (stopped != 0) return stopped;
        if (a.process == null) {
            if (step(a) == .idle) return vc.VCERR_BUSY;
            continue;
        }
        _ = sys.WaitForAny(&filled, 1, exec.WAIT_FOREVER);
    }
}

/// A frame in `slot` the caller gave back, handed to the decoder by the
/// process before it decodes again.
pub fn giveBack(a: *Ahead, slot: u32) void {
    const sys = a.sys;
    sys.ObtainSemaphore(&a.lock);
    a.given_back |= bitOf(slot);
    sys.SignalWaitable(&a.wanted);
    sys.ReleaseSemaphore(&a.lock);
}

/// The decoder the caller's until `letGo`: the frame being decoded is
/// done first.
pub fn hold(a: *Ahead) void {
    a.sys.ObtainSemaphore(&a.decoder_lock);
}

/// The decoder the process's again, and the process woken.
pub fn letGo(a: *Ahead) void {
    a.sys.ReleaseSemaphore(&a.decoder_lock);
    a.sys.SignalWaitable(&a.wanted);
}

/// The frames queued and given back handed to the decoder, and the
/// decoding going on from where the track is now: for a seek, between
/// `hold` and `letGo`.
pub fn empty(a: *Ahead) void {
    const sys = a.sys;
    sys.ObtainSemaphore(&a.lock);
    var slots = a.given_back;
    a.given_back = 0;
    while (a.count != 0) {
        const entry = a.queue[a.first];
        if (entry.result == vc.VCERR_OK) slots |= bitOf(entry.slot);
        a.first = (a.first + 1) % @as(u32, a.queue.len);
        a.count -= 1;
    }
    a.stopped = 0;
    sys.ReleaseSemaphore(&a.lock);
    handOver(a, slots);
}

// --- the process ------------------------------------------------------------------

pub const Stepped = enum { decoded, idle, quit };

fn decoderEntry(sys: *ExecBase) callconv(.c) void {
    const a: *Ahead = @ptrCast(@alignCast(sys.FindTask(null).?.user_data.?));
    const wanted = [1]*exec.Waitable{&a.wanted};
    while (true) {
        switch (step(a)) {
            .decoded => {},
            .idle => _ = sys.WaitForAny(&wanted, 1, exec.WAIT_FOREVER),
            .quit => return,
        }
    }
}

/// One round of the process's work: the frames given back handed to the
/// decoder, then the next frame decoded into the queue when it has room.
/// `.idle` when there was nothing to decode - the queue full, the
/// decoding stopped - with `wanted` reset under the lock it was seen
/// under, so whatever changes that wakes the process.
pub fn step(a: *Ahead) Stepped {
    const sys = a.sys;
    sys.ObtainSemaphore(&a.decoder_lock);
    defer sys.ReleaseSemaphore(&a.decoder_lock);

    sys.ObtainSemaphore(&a.lock);
    const quit = a.quit;
    const given = a.given_back;
    a.given_back = 0;
    const room = a.stopped == 0 and a.count < a.depth;
    if (!room) sys.ResetWaitable(&a.wanted);
    sys.ReleaseSemaphore(&a.lock);
    handOver(a, given);
    if (quit) return .quit;
    if (!room) return .idle;

    const slot = freeSlot(a) orelse return waitForFrames(a);
    var frame: vc.VideoFrame = .{};
    const result = _codec.decode(a.stream, &frame, slot);
    // The decoder lends no more: until one is given back.
    if (result == vc.VCERR_BUSY) return waitForFrames(a);
    if (result == vc.VCERR_OK) a.taken |= bitOf(slot);

    sys.ObtainSemaphore(&a.lock);
    a.queue[(a.first + a.count) % @as(u32, a.queue.len)] = .{ .result = result, .slot = slot, .frame = frame };
    a.count += 1;
    if (result != vc.VCERR_OK and result != vc.VCERR_CORRUPT) a.stopped = result;
    sys.SignalWaitable(&a.filled);
    sys.ReleaseSemaphore(&a.lock);
    return .decoded;
}

/// No slot to decode into: `.idle` until a frame is given back - at once
/// when one already was.
fn waitForFrames(a: *Ahead) Stepped {
    const sys = a.sys;
    sys.ObtainSemaphore(&a.lock);
    const waiting = a.given_back == 0 and !a.quit;
    if (waiting) sys.ResetWaitable(&a.wanted);
    sys.ReleaseSemaphore(&a.lock);
    return if (waiting) .idle else .decoded;
}

/// The frames in `slots`, a bit each, handed to the decoder; under
/// `decoder_lock`.
fn handOver(a: *Ahead, slots: u32) void {
    var left = slots;
    while (left != 0) : (left &= left - 1) {
        const slot: u32 = @ctz(left);
        _codec.release(a.stream, slot);
        a.taken &= ~bitOf(slot);
    }
}

/// A slot of the decoder's that no frame is in; under `decoder_lock`.
fn freeSlot(a: *const Ahead) ?u32 {
    var slot: u32 = 0;
    while (slot < a.stream.slots) : (slot += 1) {
        if (a.taken & bitOf(slot) == 0) return slot;
    }
    return null;
}

fn bitOf(slot: u32) u32 {
    return @as(u32, 1) << @intCast(slot);
}
