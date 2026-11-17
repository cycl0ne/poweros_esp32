// SPDX-License-Identifier: MPL-2.0
//! An H.264 decoder on the BCM2711, behind the VideoCore's firmware: its
//! MMAL component "ril.video_decode", reached through vchiq.resource
//! (sdk.hardware.mmal). The BCM2711's session (`_bcm2711.zig`) hands an
//! H.264 stream's calls here.
//!
//! **The component** is made when the decoder is opened: its input takes
//! H.264 in Annex B form, a picture a buffer; its output gives NV12. The
//! output port is enabled with no buffers, so that the component can say
//! the stream's format (EVENT_FORMAT_CHANGED) once it read the first
//! picture's parameter sets; then the port is set to that format, and
//! its buffers - as many as the component asks for, the firmware's own
//! in the VideoCore's memory - are handed to it.
//!
//! **The stream is read** by videoparse.library as well, as the H.265
//! block's is, for what the firmware does not tell: the profile, the
//! depth and the frame rate, from the sequence parameter set. A stream of
//! other than 8-bit 4:2:0 - High 10, 4:2:2, 4:4:4, grey - is refused
//! there, before the firmware sees it. Each slot the parser hands out is
//! given back as soon as it lets go of it: nothing here is kept by slot.
//!
//! **A picture fed** is read by the parser, then copied into one of the
//! input buffers here and handed over - its message, then its bytes as a
//! bulk the firmware reads. A picture larger than a buffer goes over several. The buffer
//! is free again once the component handed it back and the firmware read
//! the bulk. Feeding waits while every buffer is out, unless a frame is
//! waiting to be handed out: then it says VDERR_FULL.
//!
//! **A frame** comes back in an output buffer's message, its bytes in a
//! bulk the firmware writes into one of the frames here - the caller's
//! frames held and three more - and the output buffer goes back to the
//! component at once. The component gives its frames in the order they
//! are shown, each with the time its picture was fed with. One that
//! comes while every frame here is lent waits for one to be released.
//!
//! **The samples** are the decoder's, but for one thing the firmware does
//! on the way out, in NV12, I420 and its own column layout alike: a
//! sample of 1 to 15 comes out one lower (0 stays 0). The pictures the
//! decoder predicts from are not touched - nothing else differs, and
//! h264-1080.264's 90 frames are ffmpeg's to the byte once that is
//! allowed for. Video range starts at 16, so it is never seen.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const types = sdk.resources.videodec;
const vchiq = sdk.resources.vchiq;
const mmal = sdk.hardware.mmal;
const ExecBase = sdk.interface.exec.ExecBase;
const VchiqBase = sdk.interface.vchiq.VchiqBase;
const vp = sdk.videoparse;
const VideoParseBase = sdk.interface.videoparse.VideoParseBase;
const base = @import("../videodec_base.zig");
const VideoDecBase = base.VideoDecBase;

/// The input buffers, and the bytes each takes.
const in_count = 3;
const in_bytes: u32 = 2 * 1024 * 1024;
/// The output buffers the firmware keeps, at the least.
const out_least = 3;
/// The frames here beyond those the caller holds.
const frames_spare = 3;
const most_frames = 20;
/// Output buffers that came while no frame was free.
const most_pending = 8;
/// How long the component is waited for: a buffer back, the last frame.
const wait_us: u64 = 3_000_000;
const bulk_us: u64 = 1_000_000;

const InSlot = struct {
    memory: ?*anyopaque = null,
    data: [*]u8 = undefined,
    /// The component has its buffer; the firmware has not read its bulk.
    with_vpu: bool = false,
    bulk: vchiq.VchiqBulk = .{},

    fn free(slot: *InSlot) bool {
        return !slot.with_vpu and (slot.bulk.size == 0 or slot.bulk.done.signalled != 0);
    }
};

const Frame = struct {
    memory: ?*anyopaque = null,
    data: [*]u8 = undefined,
    ready: bool = false,
    lent: bool = false,
    time: i64 = 0,
};

pub const MmalSession = struct {
    vb: *VideoDecBase,
    vq: *VchiqBase = undefined,
    c: mmal.Client = undefined,
    open: bool = false,
    held: u32,
    component: u32 = 0,
    made: bool = false,
    control: mmal.PortInfo = undefined,
    input: mmal.PortInfo = undefined,
    output: mmal.PortInfo = undefined,
    failed: u32 = types.VDERR_OK,
    end_fed: bool = false,
    /// The end of stream is fed and waits for an input buffer to go in:
    /// it is never refused for want of one.
    eos_pending: bool = false,
    ended: bool = false,
    told: bool = false,
    /// videoparse.library and the stream's parser.
    library: ?*VideoParseBase = null,
    parser: ?*vp.VideoParser = null,
    /// What the last sequence parameter set said: profile_idc, and the
    /// frame rate where its VUI gives one.
    profile: u32 = 0,
    rate_num: u32 = 0,
    rate_den: u32 = 0,
    /// The output buffers' round: a buffer of an earlier one that comes
    /// back is not handed to the component again.
    generation: u32 = 0,
    out_count: u32 = 0,
    /// Whether the output port is enabled: from the start, with no
    /// buffers until the stream's format is known.
    out_enabled: bool = false,
    in_slots: [in_count]InSlot = @splat(.{}),
    frames: [most_frames]Frame = @splat(.{}),
    frame_count: u32 = 0,
    frame_bytes: u32 = 0,
    frame_size: usize = 0,
    ready: [most_frames]u8 = undefined,
    ready_first: u32 = 0,
    ready_count: u32 = 0,
    pending: [most_pending]mmal.BufferMessage = undefined,
    pending_count: u32 = 0,
    shown: u32 = 0,
    /// The bulk a frame's bytes come in, one at a time: here and not on
    /// the stack, for one that does not end in time is still out.
    rx_bulk: vchiq.VchiqBulk = .{},
    /// The end of stream's eight bytes, which the firmware sends as a
    /// bulk of their own: into a line of their own in here.
    scratch: [192]u8 = undefined,

    fn sys(s: *MmalSession) *ExecBase {
        return s.vb.sys_base;
    }

    fn log(s: *MmalSession, comptime fmt: []const u8, args: anytype) void {
        exec.kprintf(s.sys(), "%s: the H.264 decoder: " ++ fmt ++ "\n", .{types.VIDEODECNAME} ++ args);
    }

    fn fail(s: *MmalSession, why: u32) void {
        if (s.failed == types.VDERR_OK) s.failed = why;
    }

    /// The stream's parser opened, the component made and its ports set:
    /// VDERR_OK, VDERR_NO_ENGINE without videoparse.library, the
    /// firmware's queue or its decoder, VDERR_NO_MEMORY.
    pub fn start(s: *MmalSession) u32 {
        const sys_base = s.sys();
        const lib = sys_base.OpenLibrary(vp.VIDEOPARSENAME, 1) orelse {
            s.log("no %s to read the stream with", .{vp.VIDEOPARSENAME});
            return types.VDERR_NO_ENGINE;
        };
        const library: *VideoParseBase = @ptrCast(lib);
        s.library = library;
        var why: i32 = vp.VPERR_OK;
        s.parser = library.OpenVideoParser(vp.VPCODEC_H264, null, 0, null, &why) orelse
            return if (why == vp.VPERR_NOMEMORY) types.VDERR_NO_MEMORY else types.VDERR_UNSUPPORTED;
        s.vq = @ptrCast(sys_base.OpenResource(vchiq.VCHIQNAME) orelse return types.VDERR_NO_ENGINE);
        const opened = s.c.open(s.vq);
        if (opened != vchiq.VCHIQERR_OK) {
            s.log("the firmware's mmal service did not open (%u)", .{opened});
            return types.VDERR_NO_ENGINE;
        }
        s.open = true;
        var reply: mmal.ComponentCreateReply = undefined;
        if (s.c.create("ril.video_decode", 0, &reply) != vchiq.VCHIQERR_OK or reply.status != mmal.STATUS_SUCCESS) {
            s.log("the firmware made no ril.video_decode", .{});
            return types.VDERR_NO_ENGINE;
        }
        s.component = reply.component_handle;
        s.made = true;
        const h = s.component;
        if (s.c.portInfo(h, mmal.PORT_CONTROL, 0, &s.control) != mmal.STATUS_SUCCESS or
            s.c.portInfo(h, mmal.PORT_INPUT, 0, &s.input) != mmal.STATUS_SUCCESS or
            s.c.portInfo(h, mmal.PORT_OUTPUT, 0, &s.output) != mmal.STATUS_SUCCESS) return s.broken("its ports");
        _ = s.c.setParameter32(h, s.control.port_handle, mmal.PARAMETER_VIDEO_STOP_ON_PAR_COLOUR_CHANGE, 1);
        _ = s.c.setParameter32(h, s.output.port_handle, mmal.PARAMETER_VIDEO_VALIDATE_TIMESTAMPS, 0);
        s.input.format.type = mmal.ES_TYPE_VIDEO;
        s.input.format.encoding = mmal.ENCODING_H264;
        s.input.format.encoding_variant = 0;
        s.input.format.flags = 0;
        s.input.es = .{};
        s.input.port.buffer_num = in_count;
        s.input.port.buffer_size = in_bytes;
        if (s.c.setPort(&s.input) != mmal.STATUS_SUCCESS) return s.broken("its input");
        s.output.format.encoding = mmal.ENCODING_NV12;
        if (s.c.setPort(&s.output) != mmal.STATUS_SUCCESS) return s.broken("its output");
        if (s.c.component(mmal.MSG_COMPONENT_ENABLE, h) != mmal.STATUS_SUCCESS) return s.broken("enabled");
        if (s.c.portAction(&s.output, mmal.ACTION_ENABLE) != mmal.STATUS_SUCCESS) return s.broken("its output enabled");
        s.out_enabled = true;
        if (s.c.portAction(&s.input, mmal.ACTION_ENABLE) != mmal.STATUS_SUCCESS) return s.broken("its input enabled");
        for (&s.in_slots) |*slot| {
            const memory = sys_base.AllocMem(in_bytes + 64, exec.MEMF_ANY | exec.MEMF_SYSTEM) orelse return types.VDERR_NO_MEMORY;
            slot.memory = memory;
            slot.data = @ptrFromInt((@intFromPtr(memory) + 63) & ~@as(usize, 63));
        }
        return types.VDERR_OK;
    }

    fn broken(s: *MmalSession, what: [*:0]const u8) u32 {
        s.log("ril.video_decode refused %s", .{what});
        return types.VDERR_NO_ENGINE;
    }

    // --- the calls ----------------------------------------------------------

    pub fn feed(s: *MmalSession, data: ?[*]const u8, length: u32, time: u64, flags: u32) u32 {
        if (s.failed != types.VDERR_OK) return s.failed;
        if (s.end_fed) return types.VDERR_END;
        s.pumpAll();
        const ending = flags & types.VDFEED_END != 0;
        const given: ?[*]const u8 = if (length > 0) data orelse return types.VDERR_CORRUPT else null;
        // The buffers it takes are waited for first: once the parser has
        // read the packet it is taken, and not read again when it is fed
        // again after VDERR_FULL.
        const pieces = (length + in_bytes - 1) / in_bytes;
        if (pieces == 0 and !ending) return types.VDERR_OK;
        if (pieces > in_count) {
            s.log("a picture of %u bytes is too large", .{length});
            return types.VDERR_CORRUPT;
        }
        if (pieces > 0 and !s.waitForSlots(pieces)) return if (s.failed != types.VDERR_OK) s.failed else types.VDERR_FULL;
        s.read(given, length, time, ending);
        if (s.failed != types.VDERR_OK) return s.failed;
        if (given) |bytes| {
            var at: u32 = 0;
            var piece: u32 = 0;
            while (at < length) : (piece += 1) {
                const n = @min(length - at, in_bytes);
                var piece_flags: u32 = 0;
                if (piece == 0) piece_flags |= mmal.BUFFER_FLAG_FRAME_START;
                if (at + n == length) piece_flags |= mmal.BUFFER_FLAG_FRAME_END;
                if (!s.sendInput(bytes[at .. at + n], piece_flags, @bitCast(time))) return s.failed;
                at += n;
            }
        }
        if (ending) {
            s.end_fed = true;
            s.eos_pending = true;
            s.sendEos();
        }
        return s.failed;
    }

    /// The end of stream handed over, once an input buffer is free.
    fn sendEos(s: *MmalSession) void {
        if (!s.eos_pending or s.freeSlots() == 0) return;
        s.eos_pending = false;
        _ = s.sendInput(&.{}, mmal.BUFFER_FLAG_EOS, 0);
    }

    pub fn next(s: *MmalSession, frame: *types.VideoDecFrame) u32 {
        s.pumpAll();
        while (true) {
            if (s.failed != types.VDERR_OK) return s.failed;
            if (s.ready_count > 0) {
                s.hand(frame);
                return types.VDERR_OK;
            }
            if (s.ended) return types.VDERR_END;
            if (!s.end_fed) return types.VDERR_NEED_DATA;
            if (s.pending_count > 0 and s.freeFrame() == null) return types.VDERR_FULL;
            if (s.eos_pending) {
                // False when a frame came first, which is handed out.
                _ = s.waitForSlots(1);
                s.sendEos();
                continue;
            }
            if (!s.pump(wait_us)) {
                s.log("the last frames did not come", .{});
                s.fail(types.VDERR_CORRUPT);
            }
        }
    }

    pub fn release(s: *MmalSession, frame: *types.VideoDecFrame) void {
        const kept = frame.private[0];
        frame.* = .{};
        if (kept == 0 or kept > s.frame_count) return;
        s.frames[kept - 1].lent = false;
    }

    /// What was fed and not handed out dropped: the pictures out waited
    /// for, the frames they come to dropped, both ports started over.
    pub fn flush(s: *MmalSession) void {
        const until = s.sys().UptimeUs() + wait_us;
        while (s.failed == types.VDERR_OK and !s.allSlotsFree() and s.sys().UptimeUs() < until) _ = s.pump(10_000);
        s.pumpAll();
        if (s.parser) |parser| s.library.?.ResetVideoParser(parser);
        s.generation += 1;
        _ = s.c.portAction(&s.input, mmal.ACTION_DISABLE);
        const output_was = s.out_enabled;
        if (output_was) _ = s.c.portAction(&s.output, mmal.ACTION_DISABLE);
        s.pumpAll();
        for (&s.frames) |*f| f.ready = false;
        s.ready_count = 0;
        s.pending_count = 0;
        _ = s.c.portAction(&s.input, mmal.ACTION_ENABLE);
        if (output_was) {
            _ = s.c.portAction(&s.output, mmal.ACTION_ENABLE);
            if (s.out_count > 0) s.handOutputs();
        }
        s.end_fed = false;
        s.eos_pending = false;
        s.ended = false;
    }

    pub fn info(s: *MmalSession, into: *types.VideoDecInfo) u32 {
        if (s.failed != types.VDERR_OK) return s.failed;
        s.pumpAll();
        if (!s.told) return types.VDERR_NEED_DATA;
        const es = s.output.es;
        into.* = .{
            .width = @intCast(es.crop.width),
            .height = @intCast(es.crop.height),
            .coded_width = es.width,
            .coded_height = es.height,
            .left = @intCast(es.crop.x),
            .top = @intCast(es.crop.y),
            .bit_depth = 8,
            .profile = s.profile,
            .rate_num = if (s.rate_den != 0) s.rate_num else if (es.frame_rate.den > 0) @intCast(es.frame_rate.num) else 0,
            .rate_den = if (s.rate_den != 0) s.rate_den else if (es.frame_rate.den > 0) @intCast(es.frame_rate.den) else 0,
            .frames = s.frame_count,
        };
        return types.VDERR_OK;
    }

    pub fn end(s: *MmalSession) void {
        const sys_base = s.sys();
        if (s.made) {
            _ = s.c.component(mmal.MSG_COMPONENT_DISABLE, s.component);
            _ = s.c.component(mmal.MSG_COMPONENT_DESTROY, s.component);
        }
        if (s.open) s.c.close();
        s.open = false;
        s.made = false;
        if (s.library) |library| {
            library.CloseVideoParser(s.parser);
            sys_base.CloseLibrary(library.lib());
        }
        s.library = null;
        s.parser = null;
        for (&s.in_slots) |*slot| {
            if (slot.memory) |memory| sys_base.FreeMem(memory, in_bytes + 64);
            slot.* = .{};
        }
        s.freeFrames();
    }

    // --- the parser -----------------------------------------------------------

    /// The packet read by the parser, every event it has taken: a
    /// sequence's numbers kept, a slot given back as soon as it is let go
    /// of. A stream the firmware does not decode fails the session.
    fn read(s: *MmalSession, data: ?[*]const u8, length: u32, time: u64, ending: bool) void {
        const library = s.library.?;
        const parser = s.parser.?;
        var packet: vp.VideoPacket = .{ .data = data, .bytes = length, .flags = vp.VPPKT_ACCESS_UNIT, .time = @bitCast(time) };
        if (ending) packet.flags |= vp.VPPKT_END;
        if (library.ParseVideoPacket(parser, &packet) != vp.VPERR_OK) return s.fail(types.VDERR_CORRUPT);
        var said: vp.VideoEvent = .{};
        while (s.failed == types.VDERR_OK) {
            switch (library.NextVideoEvent(parser, &said)) {
                vp.VPERR_OK => switch (said.kind) {
                    vp.VPEV_SEQUENCE => if (said.sequence) |sequence| s.begin(sequence),
                    vp.VPEV_FREE => library.ReleaseVideoSlot(parser, said.slot),
                    else => {},
                },
                vp.VPERR_NEED_DATA, vp.VPERR_END => return,
                // A unit passed over: the firmware may make more of it.
                vp.VPERR_CORRUPT => {},
                vp.VPERR_UNSUPPORTED => s.fail(types.VDERR_UNSUPPORTED),
                vp.VPERR_NOMEMORY => s.fail(types.VDERR_NO_MEMORY),
                // Every slot is given back when it is let go of, so the
                // parser never waits for one.
                else => {
                    s.log("the parser waits for a slot", .{});
                    s.fail(types.VDERR_CORRUPT);
                },
            }
        }
    }

    /// A sequence: its profile and frame rate kept, or the stream refused
    /// when it is not 8-bit 4:2:0.
    fn begin(s: *MmalSession, q: *const vp.VideoSequence) void {
        if (q.chroma_format != 1 or q.bit_depth_luma != 8 or q.bit_depth_chroma != 8) {
            s.log("profile %u, chroma format %u, %u bits: the firmware decodes 8-bit 4:2:0 alone", .{ q.profile, q.chroma_format, q.bit_depth_luma });
            return s.fail(types.VDERR_UNSUPPORTED);
        }
        s.profile = q.profile;
        s.rate_num = q.rate_num;
        s.rate_den = q.rate_den;
    }

    // --- input --------------------------------------------------------------

    fn allSlotsFree(s: *MmalSession) bool {
        for (&s.in_slots) |*slot| {
            if (!slot.free()) return false;
        }
        return true;
    }

    fn freeSlots(s: *MmalSession) u32 {
        var n: u32 = 0;
        for (&s.in_slots) |*slot| {
            if (slot.free()) n += 1;
        }
        return n;
    }

    /// Until `pieces` input buffers are free: true; false when a frame is
    /// waiting first (the caller is to take it), or the component failed.
    fn waitForSlots(s: *MmalSession, pieces: u32) bool {
        const until = s.sys().UptimeUs() + wait_us;
        while (s.freeSlots() < pieces) {
            if (s.failed != types.VDERR_OK) return false;
            if (s.ready_count > 0) return false;
            const now = s.sys().UptimeUs();
            if (now > until) {
                s.log("no input buffer came back", .{});
                s.fail(types.VDERR_CORRUPT);
                return false;
            }
            // A bulk the firmware read ends without a message.
            if (!s.pump(10_000)) continue;
        }
        return true;
    }

    /// One input buffer handed over: its message, then its bytes.
    fn sendInput(s: *MmalSession, bytes: []const u8, flags: u32, time: i64) bool {
        const index = for (&s.in_slots, 0..) |*slot, n| {
            if (slot.free()) break n;
        } else unreachable;
        const slot = &s.in_slots[index];
        @memcpy(slot.data[0..bytes.len], bytes);
        var m: mmal.BufferMessage = .{
            .drvbuf = .{ .component_handle = s.component, .port_handle = s.input.port_handle, .client_context = @intCast(index + 1) },
            .buffer = .{
                .data = @truncate(@intFromPtr(slot.data)),
                .alloc_size = in_bytes,
                .length = @intCast(bytes.len),
                .flags = flags,
                .pts = if (flags & mmal.BUFFER_FLAG_EOS != 0) 0 else time,
                .dts = mmal.TIME_UNKNOWN,
            },
        };
        m.h.context = @intCast(index + 1);
        if (s.c.send(&m) != vchiq.VCHIQERR_OK) {
            s.log("an input buffer could not go", .{});
            s.fail(types.VDERR_NO_ENGINE);
            return false;
        }
        slot.with_vpu = true;
        slot.bulk = .{};
        if (bytes.len == 0) return true;
        // A whole number of words: the bytes past the picture are the
        // slot's own.
        slot.bulk = .{ .data = slot.data, .size = mmal.bulkBytes(@intCast(bytes.len)), .direction = vchiq.VCHIQBULK_TRANSMIT };
        const queued = s.vq.QueueBulk(s.c.service, &slot.bulk);
        if (queued != vchiq.VCHIQERR_OK) {
            slot.bulk = .{};
            s.log("an input buffer's bytes could not go (%u)", .{queued});
            s.fail(types.VDERR_NO_ENGINE);
            return false;
        }
        return true;
    }

    // --- what the component sends ---------------------------------------------

    /// Everything waiting taken, without waiting: the pending output
    /// buffers first, as frames are free.
    fn pumpAll(s: *MmalSession) void {
        s.drainPending();
        while (s.failed == types.VDERR_OK and s.pump(0)) {}
    }

    /// One message from the component dealt with, waiting up to `wait`
    /// for it: false when none came.
    fn pump(s: *MmalSession, wait: u64) bool {
        var m: mmal.Message = .{};
        const got = s.c.next(&m, wait);
        if (got == vchiq.VCHIQERR_TIMEOUT) return false;
        if (got != vchiq.VCHIQERR_OK) {
            s.log("the firmware's service closed (%u)", .{got});
            s.fail(types.VDERR_NO_ENGINE);
            return false;
        }
        switch (m.header().type) {
            mmal.MSG_BUFFER_TO_HOST => {
                const b = m.as(mmal.BufferMessage).?;
                if (b.drvbuf.port_handle == s.input.port_handle) {
                    const n = b.drvbuf.client_context;
                    if (n >= 1 and n <= in_count) s.in_slots[n - 1].with_vpu = false;
                    if (b.buffer.flags & mmal.BUFFER_FLAG_TRANSMISSION_FAILED != 0) {
                        s.log("the firmware could not take a picture's bytes", .{});
                        s.fail(types.VDERR_NO_ENGINE);
                    }
                } else if (b.drvbuf.port_handle == s.output.port_handle) {
                    s.outputBack(b);
                }
            },
            mmal.MSG_EVENT_TO_HOST => s.event(m.as(mmal.EventToHost).?),
            else => s.log("message %u not known", .{m.header().type}),
        }
        return true;
    }

    fn event(s: *MmalSession, e: *const mmal.EventToHost) void {
        switch (e.cmd) {
            mmal.EVENT_FORMAT_CHANGED => s.formatChanged(@ptrCast(@alignCast(&e.data))),
            mmal.EVENT_ERROR => {
                const code = std.mem.readInt(u32, e.data[0..4], .little);
                s.log("the component failed (%u)", .{code});
                s.fail(types.VDERR_CORRUPT);
            },
            else => {},
        }
    }

    /// The stream's format: the output port set to it, its frames made
    /// and its buffers handed to the component.
    fn formatChanged(s: *MmalSession, f: *const mmal.FormatChanged) void {
        const changed: mmal.FormatChanged = f.*;
        // The port is set only while it is disabled: it was enabled from
        // the start, with no buffers, or with the last format's.
        if (s.out_enabled) {
            _ = s.c.portAction(&s.output, mmal.ACTION_DISABLE);
            s.out_enabled = false;
        }
        s.out_count = 0;
        s.generation += 1;
        s.output.format = changed.format;
        s.output.format.encoding = mmal.ENCODING_NV12;
        s.output.es = changed.es;
        s.output.port.buffer_num = @max(changed.buffer_num_min, out_least);
        s.output.port.buffer_size = @max(changed.buffer_size_min, changed.buffer_size_recommended);
        if (s.c.setPort(&s.output) != mmal.STATUS_SUCCESS) {
            s.log("its output did not take the stream's format", .{});
            return s.fail(types.VDERR_UNSUPPORTED);
        }
        const es = s.output.es;
        s.log("%ux%u (shown %dx%d), %u buffers of %u bytes", .{ es.width, es.height, es.crop.width, es.crop.height, s.output.port.buffer_num, s.output.port.buffer_size });
        if (!s.makeFrames(s.output.port.buffer_size)) return s.fail(types.VDERR_NO_MEMORY);
        if (s.c.portAction(&s.output, mmal.ACTION_ENABLE) != mmal.STATUS_SUCCESS) {
            s.log("its output was not enabled", .{});
            return s.fail(types.VDERR_NO_ENGINE);
        }
        s.out_enabled = true;
        s.handOutputs();
        s.told = true;
    }

    /// Every output buffer of this round handed to the component.
    fn handOutputs(s: *MmalSession) void {
        s.out_count = s.output.port.buffer_num;
        var n: u32 = 0;
        while (n < s.out_count) : (n += 1) s.giveOutput(s.generation << 8 | n);
    }

    fn giveOutput(s: *MmalSession, context: u32) void {
        var m: mmal.BufferMessage = .{
            .drvbuf = .{ .component_handle = s.component, .port_handle = s.output.port_handle, .client_context = context },
            .buffer = .{ .data = context, .alloc_size = s.output.port.buffer_size },
        };
        m.h.context = context;
        if (s.c.send(&m) != vchiq.VCHIQERR_OK) s.fail(types.VDERR_NO_ENGINE);
    }

    /// An output buffer back: its frame's bytes received, or kept until a
    /// frame is free; the buffer handed back, unless it is of an earlier
    /// round.
    fn outputBack(s: *MmalSession, b: *const mmal.BufferMessage) void {
        if (b.h.status != 0) s.log("an output buffer came back with status %u", .{b.h.status});
        if (b.buffer.length == 0 or b.buffer.cmd != 0) {
            if (b.buffer.flags & mmal.BUFFER_FLAG_EOS != 0) {
                // Its eight bytes come as a bulk all the same.
                const line: *anyopaque = @ptrFromInt((@intFromPtr(&s.scratch) + 63) & ~@as(usize, 63));
                s.rx_bulk = .{ .data = line, .size = 8, .direction = vchiq.VCHIQBULK_RECEIVE };
                if (s.vq.QueueBulk(s.c.service, &s.rx_bulk) != vchiq.VCHIQERR_OK or s.vq.WaitBulk(&s.rx_bulk, bulk_us) != vchiq.VCHIQERR_OK) {
                    s.log("the end of stream's bytes did not come", .{});
                    return s.fail(types.VDERR_NO_ENGINE);
                }
                s.ended = true;
            } else if (b.drvbuf.client_context >> 8 == s.generation and s.out_count > 0) {
                s.giveOutput(b.drvbuf.client_context);
            }
            return;
        }
        if (s.pending_count > 0 or s.freeFrame() == null) {
            if (s.pending_count == most_pending) {
                s.log("too many frames came at once", .{});
                return s.fail(types.VDERR_CORRUPT);
            }
            s.pending[s.pending_count] = b.*;
            s.pending_count += 1;
            return;
        }
        s.receive(b);
    }

    fn drainPending(s: *MmalSession) void {
        while (s.pending_count > 0 and s.failed == types.VDERR_OK) {
            if (s.freeFrame() == null) return;
            const b = s.pending[0];
            std.mem.copyForwards(mmal.BufferMessage, s.pending[0 .. s.pending_count - 1], s.pending[1..s.pending_count]);
            s.pending_count -= 1;
            s.receive(&b);
        }
    }

    /// A frame's bytes received into a free frame, and its output buffer
    /// handed back.
    fn receive(s: *MmalSession, b: *const mmal.BufferMessage) void {
        const index = s.freeFrame().?;
        const f = &s.frames[index];
        const length = @min(mmal.bulkBytes(b.buffer.length), s.frame_bytes);
        if (b.payload_in_message != 0) {
            const n = @min(b.payload_in_message, mmal.short_data);
            @memcpy(f.data[0..n], b.short_data[0..n]);
        } else {
            s.rx_bulk = .{ .data = f.data, .size = length, .direction = vchiq.VCHIQBULK_RECEIVE };
            const queued = s.vq.QueueBulk(s.c.service, &s.rx_bulk);
            if (queued != vchiq.VCHIQERR_OK or s.vq.WaitBulk(&s.rx_bulk, bulk_us) != vchiq.VCHIQERR_OK) {
                s.log("a frame's bytes did not come (%u)", .{queued});
                return s.fail(types.VDERR_NO_ENGINE);
            }
        }
        const current = b.drvbuf.client_context >> 8 == s.generation;
        if (current) {
            f.ready = true;
            f.time = if (b.buffer.pts == mmal.TIME_UNKNOWN) 0 else b.buffer.pts;
            s.ready[(s.ready_first + s.ready_count) % most_frames] = @intCast(index);
            s.ready_count += 1;
            if (s.out_count > 0) s.giveOutput(b.drvbuf.client_context);
        }
        if (b.buffer.flags & mmal.BUFFER_FLAG_EOS != 0) s.ended = true;
    }

    // --- frames -------------------------------------------------------------

    fn freeFrame(s: *MmalSession) ?u32 {
        var n: u32 = 0;
        while (n < s.frame_count) : (n += 1) {
            const f = &s.frames[n];
            if (!f.ready and !f.lent) return n;
        }
        return null;
    }

    /// The frames made for `bytes` each, unless they are already.
    fn makeFrames(s: *MmalSession, bytes: u32) bool {
        const rounded = (bytes + 63) & ~@as(u32, 63);
        if (s.frame_count > 0 and rounded <= s.frame_bytes) return true;
        s.freeFrames();
        const count = @min(s.held + frames_spare, most_frames);
        s.frame_size = @as(usize, rounded) + 64;
        var n: u32 = 0;
        while (n < count) : (n += 1) {
            const memory = s.sys().AllocMem(s.frame_size, exec.MEMF_ANY | exec.MEMF_SYSTEM) orelse return false;
            s.frames[n] = .{ .memory = memory, .data = @ptrFromInt((@intFromPtr(memory) + 63) & ~@as(usize, 63)) };
            s.frame_count = n + 1;
        }
        s.frame_bytes = rounded;
        return true;
    }

    fn freeFrames(s: *MmalSession) void {
        for (&s.frames) |*f| {
            if (f.memory) |memory| s.sys().FreeMem(memory, s.frame_size);
            f.* = .{};
        }
        s.frame_count = 0;
        s.ready_count = 0;
    }

    fn hand(s: *MmalSession, frame: *types.VideoDecFrame) void {
        const index = s.ready[s.ready_first];
        s.ready_first = (s.ready_first + 1) % most_frames;
        s.ready_count -= 1;
        const f = &s.frames[index];
        f.ready = false;
        f.lent = true;
        const es = s.output.es;
        const pitch = es.width;
        const left: usize = @intCast(es.crop.x);
        const top: usize = @intCast(es.crop.y);
        const chroma = f.data + @as(usize, pitch) * es.height;
        frame.* = .{
            .y = f.data + top * pitch + left,
            .cbcr = chroma + top / 2 * pitch + left,
            .pitch = pitch,
            .width = @intCast(es.crop.width),
            .height = @intCast(es.crop.height),
            .format = types.VDFMT_NV12,
            .time = @bitCast(f.time),
            .number = s.shown,
        };
        frame.private[0] = index + 1;
        s.shown += 1;
    }
};
