// SPDX-License-Identifier: MPL-2.0
//! A decoder on the BCM2711's H.265 block (`codec/_bcm2711.zig`): what
//! OpenVideoDecoder hands out there - an H.265 stream videoparse.library
//! reads, whose pictures the block decodes one at a time, and the frames
//! they come to, in the order they are shown. An H.264 stream goes to the
//! VideoCore's firmware instead (`_mmal.zig`), and every call is handed
//! on to that.
//!
//! **The stream** is read by a parser (`read`): a packet fed is copied
//! and handed to it, and its events are taken as they come. A sequence
//! the block takes lays out its frames; one it does not - 4:2:2, 12
//! bits, larger than 4096 x 4096, the range extensions' tools -
//! stops the stream (VDERR_UNSUPPORTED). Each slice segment's unit is
//! copied into the picture's bitstream as it came, its emulation
//! prevention bytes in it - the block takes them out itself - and its
//! commands put down; at the picture's decode the rest are, phase 1 runs
//! over the list, then phase 2 into the picture's frame, and the frame
//! is copied out as NV12. A picture whose phase 1 stops on its data is
//! left grey and the stream goes on.
//!
//! **The references** a picture holds are the block's 16 slots, in the
//! order the picture holds them; a slot it does not use names the
//! picture's own frame. Every frame has its motion vectors' buffer, which
//! a later picture takes as its collocated picture's; a reference the
//! stream lacks is a grey frame with no motion.
//!
//! **The frames** are the parser's slots: each its picture's frame in
//! the block's columns, and its copy in the system's memory as NV12, the
//! rows the picture shows, the columns' width apart. A slot is given back
//! to the parser once it said the stream needs it no more, the frame was
//! handed out as often as it was to be shown, and the caller released
//! each.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const types = sdk.resources.videodec;
const vp = sdk.videoparse;
const hevc = vp.hevc;
const utility = sdk.utility;
const systimer = sdk.hardware.systimer;
const ExecBase = sdk.interface.exec.ExecBase;
const VideoParseBase = sdk.interface.videoparse.VideoParseBase;
const base = @import("../videodec_base.zig");
const VideoDecBase = base.VideoDecBase;
const bcm = @import("../codec/_bcm2711.zig");
const MmalSession = @import("_mmal.zig").MmalSession;

/// The slots a parser hands out at most.
pub const most_slots = 40;
const none: u8 = 0xFF;

/// The most slice segments a picture has.
const most_segments = 1024;

/// The bitstream's and the command list's room, at the least.
const bitstream_least: u32 = 256 * 1024;
const commands_least: u32 = 8192;

/// How long each phase is waited for.
const phase_most_us: u64 = 1_000_000;

/// How often phase 1 is run again with its buffers made larger.
const regrowths = 4;

/// Memory the block reads or writes: on a 64-byte boundary.
const Dma = struct {
    memory: ?*anyopaque = null,
    size: usize = 0,
    address: usize = 0,
    bytes: usize = 0,

    fn alloc(sys: *ExecBase, bytes: usize) ?Dma {
        const size = bytes + 64;
        const memory = sys.AllocMem(size, exec.MEMF_ANY | exec.MEMF_SYSTEM) orelse return null;
        const address = (@intFromPtr(memory) + 63) & ~@as(usize, 63);
        return .{ .memory = memory, .size = size, .address = address, .bytes = bytes };
    }

    /// Memory the block writes: no line of it left in the caches - one
    /// its last owner left dirty would be written back over what the
    /// block writes, whenever the caches let it go.
    fn forBlock(sys: *ExecBase, bytes: usize) ?Dma {
        const d = alloc(sys, bytes) orelse return null;
        d.fromBlock(sys, bytes);
        return d;
    }

    fn free(d: *Dma, sys: *ExecBase) void {
        if (d.memory) |memory| sys.FreeMem(memory, d.size);
        d.* = .{};
    }

    fn ptr(d: Dma) [*]u8 {
        return @ptrFromInt(d.address);
    }

    /// Its first `bytes` written back from the caches, for the block to
    /// read.
    fn toBlock(d: Dma, sys: *ExecBase, bytes: usize) void {
        var length: u32 = @intCast(bytes);
        _ = sys.CachePreDMA(@ptrFromInt(d.address), &length, 0);
    }

    /// Dropped from the caches, what the block wrote read from memory.
    fn fromBlock(d: Dma, sys: *ExecBase, bytes: usize) void {
        var length: u32 = @intCast(bytes);
        sys.CachePostDMA(@ptrFromInt(d.address), &length, 0);
    }
};

/// A frame: a slot's picture as the block wrote it, its motion vectors,
/// and its copy in the system's memory.
const Frame = struct {
    sand: Dma = .{},
    mv: Dma = .{},
    /// Its rows of brightness, then of colour pairs, `pitch` bytes apart,
    /// the picture's whole height of each; the first sample shown is
    /// `top` rows down and `left` bytes in.
    memory: ?[*]u8 = null,
    bytes: usize = 0,
    pitch: u32 = 0,
    rows: u32 = 0,
    left: u32 = 0,
    top: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// When it is shown: its picture's time as it was fed, until it is
    /// shown - then the earliest of the pictures decoded and not shown.
    time: i64 = 0,
    /// Decoded, or to be shown as if it were, and not shown yet.
    waiting: bool = false,
    /// The parser handed the slot out and it was not given back; the
    /// parser needs it no more; how often it is due to be shown, and how
    /// often it is lent to the caller.
    held: bool = false,
    freed: bool = false,
    due: u8 = 0,
    lent: u8 = 0,
};

/// Where a segment's slice data is among the picture's bitstream, and
/// the command that names it.
const Placed = struct { entry: u32, offset: u32 };

pub const Session = struct {
    vb: *VideoDecBase,
    /// Its place in the base's table of open decoders.
    slot: u32,
    codec: u32,
    /// How many frames the caller holds at once (VDA_HeldFrames).
    held: u32,
    /// An H.264 stream's decoder, in the firmware: every call is its.
    h264: ?*MmalSession = null,
    library: ?*VideoParseBase = null,
    parser: ?*vp.VideoParser = null,
    packet: ?[*]u8 = null,
    packet_room: u32 = 0,
    reading: bool = false,
    end_fed: bool = false,
    ended: bool = false,
    failed: u32 = types.VDERR_OK,
    told: bool = false,
    sequence: vp.VideoSequence = .{},
    /// The frames' layout, and the two buffers between the phases.
    layout: bcm.Layout = .{},
    pu: Dma = .{},
    coeff: Dma = .{},
    /// The picture being read: its program, its commands and their
    /// memory, its slices' units and where each segment's data is.
    picture: vp.VideoPicture = .{},
    open_picture: bool = false,
    /// The picture is passed over: its first segment is not at CTB 0, it
    /// has too many, or no room was made for them.
    passed: bool = false,
    program: bcm.Program = .{},
    commands: Dma = .{},
    command_room: u32 = 0,
    command_count: u32 = 0,
    stage: Dma = .{},
    staged: u32 = 0,
    placed: [most_segments]Placed = undefined,
    segments: u32 = 0,
    /// Each slot's place among the block's 16 for this picture, and the
    /// collocated picture's slot.
    place_of: [most_slots]u8 = @splat(none),
    collocated: u8 = none,
    said: [bcm.max_messages]u16 = undefined,
    frames: [most_slots]Frame = @splat(.{}),
    due: [most_slots]u8 = @splat(none),
    due_time: [most_slots]i64 = @splat(0),
    due_first: u32 = 0,
    due_count: u32 = 0,
    shown: u32 = 0,
    /// Pictures decoded, and how long the two phases and the copying out
    /// took over them, in microseconds.
    decoded: u32 = 0,
    phase1_us: u64 = 0,
    phase2_us: u64 = 0,
    copy_us: u64 = 0,

    pub fn of(h: *types.VideoDecoder) *Session {
        return @ptrCast(@alignCast(h));
    }

    pub fn handle(s: *Session) *types.VideoDecoder {
        return @ptrCast(s);
    }

    fn sys(s: *Session) *ExecBase {
        return s.vb.sys_base;
    }

    fn fail(s: *Session, why: u32) void {
        if (s.failed == types.VDERR_OK) s.failed = why;
    }

    /// The stream's parser opened: VDERR_OK, VDERR_NO_ENGINE without
    /// videoparse.library, VDERR_NO_MEMORY.
    pub fn start(s: *Session) u32 {
        if (s.codec == types.VDCODEC_H264) {
            const memory = s.sys().AllocMem(@sizeOf(MmalSession), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return types.VDERR_NO_MEMORY;
            const m: *MmalSession = @ptrCast(@alignCast(memory));
            m.* = .{ .vb = s.vb, .held = s.held };
            s.h264 = m;
            return m.start();
        }
        const lib = s.sys().OpenLibrary(vp.VIDEOPARSENAME, 1) orelse {
            exec.kprintf(s.sys(), "%s: no %s for the H.265 block\n", .{ types.VIDEODECNAME, vp.VIDEOPARSENAME });
            return types.VDERR_NO_ENGINE;
        };
        const library: *VideoParseBase = @ptrCast(lib);
        s.library = library;
        const tags = [_]utility.TagItem{
            .{ .tag = vp.VPA_Slots, .data = s.held + 2 },
            .{ .tag = vp.VPA_MaxWidth, .data = bcm.most_width },
            .{ .tag = vp.VPA_MaxHeight, .data = bcm.most_height },
            .{},
        };
        var why: i32 = vp.VPERR_OK;
        s.parser = library.OpenVideoParser(vp.VPCODEC_HEVC, null, 0, &tags, &why) orelse
            return if (why == vp.VPERR_NOMEMORY) types.VDERR_NO_MEMORY else types.VDERR_UNSUPPORTED;
        return types.VDERR_OK;
    }

    // --- the calls ------------------------------------------------------------

    /// A packet copied and read: as FeedVideoDecoder answers.
    pub fn feed(s: *Session, data: ?[*]const u8, length: u32, time: u64, flags: u32) u32 {
        if (s.h264) |m| return m.feed(data, length, time, flags);
        if (s.failed != types.VDERR_OK) return s.failed;
        if (s.end_fed) return types.VDERR_END;
        if (s.reading) {
            s.read();
            if (s.failed != types.VDERR_OK) return s.failed;
            if (s.reading) return types.VDERR_FULL;
        }
        var given: vp.VideoPacket = .{ .flags = vp.VPPKT_ACCESS_UNIT, .time = @bitCast(time) };
        if (length > 0) {
            const bytes = data orelse return types.VDERR_CORRUPT;
            if (!s.packetRoom(length)) return types.VDERR_NO_MEMORY;
            s.sys().CopyMem(bytes, s.packet.?, length);
            given.data = s.packet;
            given.bytes = length;
        }
        if (flags & types.VDFEED_END != 0) {
            given.flags |= vp.VPPKT_END;
            s.end_fed = true;
        } else if (length == 0) return types.VDERR_OK;
        if (s.library.?.ParseVideoPacket(s.parser.?, &given) != vp.VPERR_OK) return types.VDERR_CORRUPT;
        s.reading = true;
        s.read();
        return s.failed;
    }

    /// The next frame to be shown, into `frame`: as DecodeVideoFrame
    /// answers.
    pub fn next(s: *Session, frame: *types.VideoDecFrame) u32 {
        if (s.h264) |m| return m.next(frame);
        while (true) {
            if (s.failed != types.VDERR_OK) return s.failed;
            if (s.due_count > 0) {
                s.hand(frame);
                return types.VDERR_OK;
            }
            if (!s.reading) return if (s.ended) types.VDERR_END else types.VDERR_NEED_DATA;
            s.read();
            if (s.reading and s.due_count == 0 and s.failed == types.VDERR_OK) {
                for (s.frames) |f| {
                    if (f.lent != 0) return types.VDERR_FULL;
                }
                exec.kprintf(s.sys(), "%s: the H.265 block's stream has no slot free and no frame lent\n", .{types.VIDEODECNAME});
                s.fail(types.VDERR_CORRUPT);
            }
        }
    }

    /// A frame handed back: its slot is given back once the stream needs
    /// it no more.
    pub fn release(s: *Session, frame: *types.VideoDecFrame) void {
        if (s.h264) |m| return m.release(frame);
        const kept = frame.private[0];
        frame.* = .{};
        if (kept == 0 or kept > most_slots) return;
        const slot = kept - 1;
        const f = &s.frames[slot];
        if (f.lent == 0) return;
        f.lent -= 1;
        s.giveBack(slot);
    }

    /// What was fed and not handed out dropped, for a seek.
    pub fn flush(s: *Session) void {
        if (s.h264) |m| return m.flush();
        if (s.parser) |parser| s.library.?.ResetVideoParser(parser);
        s.reading = false;
        s.open_picture = false;
        s.end_fed = false;
        s.ended = false;
        s.due_first = 0;
        s.due_count = 0;
        for (&s.frames, 0..) |*f, slot| {
            f.due = 0;
            f.waiting = false;
            if (!f.held) continue;
            f.freed = true;
            s.giveBack(@intCast(slot));
        }
    }

    /// What the stream is: as GetVideoDecoderInfo answers.
    pub fn info(s: *Session, into: *types.VideoDecInfo) u32 {
        if (s.h264) |m| return m.info(into);
        if (s.failed != types.VDERR_OK) return s.failed;
        if (!s.told) return types.VDERR_NEED_DATA;
        const q = &s.sequence;
        into.* = .{
            .width = q.width,
            .height = q.height,
            .coded_width = q.coded_width,
            .coded_height = q.coded_height,
            .left = q.left,
            .top = q.top,
            .bit_depth = q.bit_depth_luma,
            .profile = q.profile,
            .rate_num = q.rate_num,
            .rate_den = q.rate_den,
            .frames = q.slots,
        };
        return types.VDERR_OK;
    }

    /// Everything of the decoder freed but itself - the frames lent too.
    /// The caller holds the resource's lock. A block taken as dead may
    /// still write the frames and buffers: they are kept.
    pub fn end(s: *Session) void {
        const sys_base = s.sys();
        if (s.h264) |m| {
            m.end();
            sys_base.FreeMem(m, @sizeOf(MmalSession));
            s.h264 = null;
            return;
        }
        if (s.decoded > 0) {
            exec.kprintf(sys_base, "%s: the H.265 block: %u pictures, %lu us each in phase 1, %lu us in phase 2, %lu us copied out\n", .{
                types.VIDEODECNAME, s.decoded, s.phase1_us / s.decoded, s.phase2_us / s.decoded, s.copy_us / s.decoded,
            });
        }
        if (s.library) |library| {
            library.CloseVideoParser(s.parser);
            sys_base.CloseLibrary(library.lib());
        }
        s.parser = null;
        s.library = null;
        const alive = s.vb.state == base.STATE_RUNNING;
        for (&s.frames) |*f| {
            if (f.memory) |memory| sys_base.FreeMem(memory, f.bytes);
            if (alive) {
                f.sand.free(sys_base);
                f.mv.free(sys_base);
            }
            f.* = .{};
        }
        if (alive) {
            s.pu.free(sys_base);
            s.coeff.free(sys_base);
            s.commands.free(sys_base);
            s.stage.free(sys_base);
        }
        if (s.packet) |packet| sys_base.FreeMem(packet, s.packet_room);
        s.packet = null;
    }

    // --- the parser's events ---------------------------------------------------

    fn read(s: *Session) void {
        const library = s.library.?;
        const parser = s.parser.?;
        var event: vp.VideoEvent = .{};
        while (s.reading and s.failed == types.VDERR_OK) {
            switch (library.NextVideoEvent(parser, &event)) {
                vp.VPERR_OK => s.take(&event),
                vp.VPERR_NEED_DATA => s.reading = false,
                vp.VPERR_END => {
                    s.reading = false;
                    s.ended = true;
                },
                vp.VPERR_FULL => return,
                vp.VPERR_UNSUPPORTED => s.fail(types.VDERR_UNSUPPORTED),
                vp.VPERR_NOMEMORY => s.fail(types.VDERR_NO_MEMORY),
                // A unit that is not right, passed over.
                else => {},
            }
        }
    }

    fn take(s: *Session, event: *const vp.VideoEvent) void {
        switch (event.kind) {
            vp.VPEV_SEQUENCE => s.begin(event.sequence orelse return),
            vp.VPEV_MISSING => s.missing(event.slot, event.time),
            vp.VPEV_PICTURE => s.beginPicture(event.picture orelse return),
            vp.VPEV_SLICE => s.slice(event.slice orelse return),
            vp.VPEV_DECODE => s.decode(),
            vp.VPEV_SHOW => s.show(event.slot, event.time),
            vp.VPEV_FREE => s.free(event.slot),
            else => {},
        }
    }

    /// A sequence: its frames laid out, and the buffers between the
    /// phases made for them - anew when its size or depth differs.
    fn begin(s: *Session, seq: *const vp.VideoSequence) void {
        const sps = seq.hevc_sps orelse return s.fail(types.VDERR_CORRUPT);
        const depth = sps.bit_depth_luma;
        if (sps.chroma_format_idc != 1 or depth != sps.bit_depth_chroma or (depth != 8 and depth != 10) or
            sps.width > bcm.most_width or sps.height > bcm.most_height or seq.slots > most_slots or
            seq.width == 0 or seq.height == 0)
        {
            exec.kprintf(s.sys(), "%s: the H.265 block does not take a stream of profile %d, %d bits (chroma %d), chroma format %d, %u x %u, %d slots\n", .{
                types.VIDEODECNAME,       @as(u32, sps.profile_idc),       @as(u32, depth), @as(u32, sps.bit_depth_chroma),
                @as(u32, sps.chroma_format_idc), sps.width, sps.height,
                seq.slots,
            });
            return s.fail(types.VDERR_UNSUPPORTED);
        }
        s.sequence = seq.*;
        s.sequence.h264_sps = null;
        s.sequence.hevc_sps = null;
        s.sequence.av1 = null;
        s.told = true;
        const layout = bcm.Layout.of(sps.width, sps.height, depth == 10);
        if (s.layout.same(layout)) return;
        const sys_base = s.sys();
        // The frames of the size before are made anew as their slots are
        // used again; a lent one's copy stays until it is.
        for (&s.frames) |*f| {
            f.sand.free(sys_base);
            f.mv.free(sys_base);
        }
        s.pu.free(sys_base);
        s.coeff.free(sys_base);
        s.layout = layout;
        s.pu = Dma.forBlock(sys_base, layout.pu_bytes) orelse return s.fail(types.VDERR_NO_MEMORY);
        s.coeff = Dma.forBlock(sys_base, layout.coeff_bytes) orelse return s.fail(types.VDERR_NO_MEMORY);
        exec.kprintf(sys_base, "%s: the H.265 block lays out %u x %u at %d bits: frames of %u KiB, buffers of %u and %u KiB\n", .{
            types.VIDEODECNAME,      layout.width,          layout.height,             @as(u32, depth),
            layout.bytes / 1024, layout.pu_bytes / 1024, layout.coeff_bytes / 1024,
        });
    }

    /// A slot that stands for a picture the stream lacks: its frame grey,
    /// no motion in it.
    fn missing(s: *Session, slot: u32, time: i64) void {
        if (slot >= most_slots) return s.fail(types.VDERR_CORRUPT);
        const f = &s.frames[slot];
        f.held = true;
        f.freed = false;
        f.due = 0;
        f.waiting = false;
        f.time = time;
        if (!s.frameRoom(f)) return s.fail(types.VDERR_NO_MEMORY);
        s.greyFrame(f);
    }

    /// A picture begins: its program, and its references' places among
    /// the block's slots.
    fn beginPicture(s: *Session, pic: *const vp.VideoPicture) void {
        if (pic.slot >= most_slots) return s.fail(types.VDERR_CORRUPT);
        const sps = pic.hevc_sps orelse return s.fail(types.VDERR_CORRUPT);
        const pps = pic.hevc_pps orelse return s.fail(types.VDERR_CORRUPT);
        if (!bcm.Program.takes(sps, pps)) {
            exec.kprintf(s.sys(), "%s: the H.265 block does not take this stream's tools (range extensions, or wavefronts over tiles)\n", .{types.VIDEODECNAME});
            return s.fail(types.VDERR_UNSUPPORTED);
        }
        s.picture = pic.*;
        s.open_picture = true;
        s.passed = false;
        s.staged = 0;
        s.segments = 0;
        s.command_count = 0;
        s.collocated = none;
        s.program.begin(sps, pps);
        s.place_of = @splat(none);
        for (pic.refs[0..@min(pic.ref_count, bcm.ref_slots)], 0..) |r, j| {
            if (r.slot < most_slots) s.place_of[r.slot] = @intCast(j);
        }
        const f = &s.frames[pic.slot];
        f.held = true;
        f.freed = false;
        f.due = 0;
        f.waiting = true;
        f.time = pic.time;
    }

    /// A slice segment: its unit after the others in the bitstream, its
    /// commands put down.
    fn slice(s: *Session, sl: *const vp.VideoSlice) void {
        if (!s.open_picture or s.passed) return;
        const h = sl.hevc orelse return;
        if (s.segments == 0 and h.segment_address != 0) {
            s.passed = true;
            return;
        }
        if (s.segments == most_segments) {
            exec.kprintf(s.sys(), "%s: the H.265 block takes %d slice segments a picture at most\n", .{ types.VIDEODECNAME, @as(u32, most_segments) });
            s.passed = true;
            return;
        }
        const data_at = codedOffset(sl.unit[0..sl.unit_bytes], h.data_offset) orelse {
            s.passed = true;
            return;
        };
        const bytes = sl.unit_bytes - data_at;
        if (!s.stageRoom(s.staged + bytes) or !s.commandRoom(s.command_count + bcm.segmentRoom(&s.program))) {
            s.passed = true;
            return s.fail(types.VDERR_NO_MEMORY);
        }
        s.sys().CopyMem(sl.unit + data_at, s.stage.ptr() + s.staged, bytes);
        var refs: [2][bcm.ref_slots]bcm.Ref = @splat(@splat(.{}));
        for (0..2) |l| {
            for (sl.lists[l][0..@min(sl.count[l], bcm.ref_slots)], 0..) |entry, i| {
                const place = if (entry.slot < most_slots) s.place_of[entry.slot] else none;
                refs[l][i] = .{ .slot = if (place != none) place else 0, .long_term = entry.long_term, .poc = entry.poc[0] };
            }
        }
        if (s.segments == 0 or !h.dependent) {
            if (h.temporal_mvp and h.slice_type != .i and sl.collocated < most_slots) s.collocated = sl.collocated;
        }
        const pic_temporal_mvp = if (s.segments == 0) h.temporal_mvp else s.program.temporal_mvp;
        const n = bcm.messages(&s.said, h, s.program.pps, &refs, s.picture.poc[0], pic_temporal_mvp);
        var c = s.commandList();
        const entry = s.program.segment(&c, h, s.said[0..n], bytes);
        s.command_count = c.len;
        s.placed[s.segments] = .{ .entry = entry, .offset = s.staged };
        s.segments += 1;
        s.staged += bytes;
    }

    fn commandList(s: *Session) bcm.Commands {
        return .{ .list = @ptrFromInt(s.commands.address), .room = s.command_room, .len = s.command_count };
    }

    /// The picture's segments given: the rest of its commands put down,
    /// both phases run, its frame copied out. One the block cannot decode
    /// is grey.
    fn decode(s: *Session) void {
        if (!s.open_picture) return;
        s.open_picture = false;
        const sys_base = s.sys();
        const vb = s.vb;
        const pic = &s.picture;
        const f = &s.frames[pic.slot];
        if (!s.frameRoom(f)) return s.fail(types.VDERR_NO_MEMORY);
        if (s.passed or s.segments == 0) return s.greyFrame(f);
        var c = s.commandList();
        s.program.finish(&c);
        for (s.placed[0..s.segments]) |p| c.place(p.entry, s.stage.address + p.offset);
        s.stage.toBlock(sys_base, s.staged);
        s.commands.toBlock(sys_base, @as(usize, c.len) * @sizeOf(bcm.Command));
        const regs = vb.vpu;
        const rows = s.program.h;

        const started = systimer.uptimeUs();
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            const pu_stride = bcm.rowStride(@intCast(s.pu.bytes), rows);
            const coeff_stride = bcm.rowStride(@intCast(s.coeff.bytes), rows);
            s.forgetRaised();
            bcm.runPhase1(regs, s.commands.address, c.len, s.pu.address, pu_stride, s.coeff.address, coeff_stride);
            if (!s.waitFor(bcm.ACTIVE1)) return s.dead("did not end phase 1");
            switch (bcm.phase1Ended(regs)) {
                .done => break,
                .short => |which| {
                    if (tries == regrowths or !s.grow(which)) {
                        exec.kprintf(sys_base, "%s: the H.265 block's buffers between the phases ran out\n", .{types.VIDEODECNAME});
                        return s.greyFrame(f);
                    }
                },
                .failed => |done| {
                    exec.kprintf(sys_base, "%s: the H.265 block stopped a picture's phase 1 at command %u of %u\n", .{ types.VIDEODECNAME, done, c.len });
                    return s.greyFrame(f);
                },
            }
        }
        const ended1 = systimer.uptimeUs();

        var phase2: bcm.Phase2 = .{
            .pu = s.pu.address,
            .pu_stride = bcm.rowStride(@intCast(s.pu.bytes), rows),
            .coeff = s.coeff.address,
            .coeff_stride = bcm.rowStride(@intCast(s.coeff.bytes), rows),
            .frame = f.sand.address,
            .refs = @splat(f.sand.address),
            .layout = &s.layout,
            .config2 = s.program.config2(pic.hevc_sps.?.temporal_mvp),
            .framesize = s.program.framesize(),
            .poc = pic.poc[0],
            .mv = if (pic.hevc_sps.?.temporal_mvp) f.mv.address else 0,
            .col = 0,
            .rows = rows,
        };
        for (pic.refs[0..@min(pic.ref_count, bcm.ref_slots)], 0..) |r, j| {
            if (r.slot >= most_slots) continue;
            const ref = &s.frames[r.slot];
            if (ref.sand.memory != null) phase2.refs[j] = ref.sand.address;
        }
        if (s.collocated != none and s.program.temporal_mvp) {
            const col = &s.frames[s.collocated];
            if (col.mv.memory != null) phase2.col = col.mv.address;
        }
        s.forgetRaised();
        bcm.runPhase2(regs, &phase2);
        if (!s.waitFor(bcm.ACTIVE2)) return s.dead("did not end phase 2");
        const ended2 = systimer.uptimeUs();

        f.sand.fromBlock(sys_base, s.layout.bytes);
        s.copyOut(f);
        s.phase1_us += ended1 - started;
        s.phase2_us += ended2 - ended1;
        s.copy_us += systimer.uptimeUs() - ended2;
        s.decoded += 1;
    }

    /// A buffer between the phases twice as large, for each that ran out:
    /// false when there is no room.
    fn grow(s: *Session, which: u32) bool {
        const sys_base = s.sys();
        for ([_]struct { bit: u32, buffer: *Dma }{ .{ .bit = bcm.PU_SHORT, .buffer = &s.pu }, .{ .bit = bcm.COEFF_SHORT, .buffer = &s.coeff } }) |b| {
            if (which & b.bit == 0) continue;
            const bytes = b.buffer.bytes * 2;
            b.buffer.free(sys_base);
            b.buffer.* = Dma.forBlock(sys_base, bytes) orelse return false;
        }
        return true;
    }

    /// The block did not end a phase: taken as dead - it may still write
    /// what it was given, which is kept - and the stream stopped.
    fn dead(s: *Session, what: [*:0]const u8) void {
        const r = bcm.registers(s.vb.vpu);
        exec.kprintf(s.sys(), "%s: the H.265 block %s within a second (ICTRL %08x, STATUS %08x, %u of %u commands); it is not used again\n", .{
            types.VIDEODECNAME, what, r.ictrl, r.status, r.done, r.count,
        });
        s.vb.state = base.STATE_DEAD;
        s.fail(types.VDERR_CORRUPT);
    }

    fn forgetRaised(s: *Session) void {
        const sys_base = s.sys();
        sys_base.Disable();
        s.vb.hevc.raised = 0;
        sys_base.ResetWaitable(&s.vb.hevc.done);
        sys_base.Enable();
    }

    /// The interrupt server took `bit` from the block: false when it did
    /// not within a second.
    fn waitFor(s: *Session, bit: u32) bool {
        const sys_base = s.sys();
        const h = &s.vb.hevc;
        const waitables = [_]*exec.Waitable{&h.done};
        const until = systimer.uptimeUs() + phase_most_us;
        while (true) {
            sys_base.Disable();
            const got = h.raised & bit != 0;
            if (got) h.raised &= ~bit;
            sys_base.ResetWaitable(&h.done);
            sys_base.Enable();
            if (got) {
                sdk.hardware.barrier.fromDevice();
                return true;
            }
            const now = systimer.uptimeUs();
            if (now >= until) {
                // The block ended the phase and its interrupt was not
                // taken: said, and gone on with.
                sys_base.Disable();
                const late = bcm.takeInterrupt(s.vb.vpu) orelse 0;
                h.raised |= late;
                const got_late = h.raised & bit != 0;
                h.raised &= ~bit;
                sys_base.Enable();
                if (!got_late) return false;
                exec.kprintf(sys_base, "%s: the H.265 block's interrupt did not come; ICTRL said the phase ended\n", .{types.VIDEODECNAME});
                sdk.hardware.barrier.fromDevice();
                return true;
            }
            _ = sys_base.WaitForAny(&waitables, 1, until - now);
        }
    }

    /// A picture due to be shown, after those due before it: with the
    /// earliest time of the pictures decoded and not shown - its own,
    /// where they were fed with the times they are shown at.
    fn show(s: *Session, slot: u32, time: i64) void {
        if (slot >= most_slots) return;
        const f = &s.frames[slot];
        if (f.memory == null) {
            if (!s.frameRoom(f)) return s.fail(types.VDERR_NO_MEMORY);
            s.greyFrame(f);
        }
        if (f.waiting) {
            var earliest = f;
            for (&s.frames) |*other| {
                if (other.waiting and other.time < earliest.time) earliest = other;
            }
            const own = f.time;
            f.time = earliest.time;
            earliest.time = own;
            f.waiting = false;
        } else f.time = time;
        if (s.due_count == most_slots) return s.fail(types.VDERR_CORRUPT);
        f.due += 1;
        const at = (s.due_first + s.due_count) % most_slots;
        s.due[at] = @intCast(slot);
        s.due_time[at] = f.time;
        s.due_count += 1;
    }

    fn free(s: *Session, slot: u32) void {
        if (slot >= most_slots) return;
        const f = &s.frames[slot];
        f.freed = true;
        f.waiting = false;
        s.giveBack(slot);
    }

    fn giveBack(s: *Session, slot: u32) void {
        const f = &s.frames[slot];
        if (!f.held or !f.freed or f.due != 0 or f.lent != 0) return;
        f.held = false;
        s.library.?.ReleaseVideoSlot(s.parser.?, slot);
    }

    /// The first frame due handed out in `frame`.
    fn hand(s: *Session, frame: *types.VideoDecFrame) void {
        const slot: u32 = s.due[s.due_first];
        const time = s.due_time[s.due_first];
        s.due_first = (s.due_first + 1) % most_slots;
        s.due_count -= 1;
        const f = &s.frames[slot];
        f.due -= 1;
        f.lent += 1;
        const memory = f.memory.?;
        const pitch: usize = f.pitch;
        frame.* = .{
            .y = memory + f.top * pitch + f.left,
            .cbcr = memory + (@as(usize, f.rows) + f.top / 2) * pitch + f.left,
            .pitch = f.pitch,
            .width = f.width,
            .height = f.height,
            .format = types.VDFMT_NV12,
            .time = @bitCast(time),
            .number = s.shown,
            .private = .{ slot + 1, s.slot, 0 },
        };
        s.shown += 1;
    }

    // --- memory ---------------------------------------------------------------------

    /// Frame `f` laid out for the stream: the block's frame and motion
    /// vectors, and the copy - the columns' width a row, the picture's
    /// whole height.
    fn frameRoom(s: *Session, f: *Frame) bool {
        const l = s.layout;
        if (l.bytes == 0) return false;
        const sys_base = s.sys();
        if (f.sand.memory == null) {
            f.sand = Dma.forBlock(sys_base, l.bytes) orelse return false;
            f.mv = Dma.forBlock(sys_base, l.mv_bytes) orelse {
                f.sand.free(sys_base);
                return false;
            };
        }
        const pitch = l.width_al + 63 & ~@as(u32, 63);
        const bytes: usize = @as(usize, pitch) * (l.height + l.height / 2);
        if (f.bytes < bytes) {
            if (f.memory) |memory| sys_base.FreeMem(memory, f.bytes);
            f.bytes = 0;
            f.memory = @ptrCast(sys_base.AllocMem(bytes, exec.MEMF_ANY | exec.MEMF_SYSTEM) orelse {
                f.memory = null;
                return false;
            });
            f.bytes = bytes;
        }
        const q = &s.sequence;
        f.pitch = pitch;
        f.rows = l.height;
        f.left = q.left & ~@as(u32, 1);
        f.top = q.top & ~@as(u32, 1);
        f.width = q.width;
        f.height = q.height;
        return true;
    }

    /// A frame grey - the block's, written back for it to read, with no
    /// motion - and its copy.
    fn greyFrame(s: *Session, f: *Frame) void {
        const sys_base = s.sys();
        if (f.sand.memory != null) {
            bcm.grey(f.sand.ptr(), s.layout);
            @memset(f.mv.ptr()[0..s.layout.mv_bytes], 0);
            f.sand.toBlock(sys_base, s.layout.bytes);
            f.mv.toBlock(sys_base, s.layout.mv_bytes);
        }
        const memory = f.memory orelse return;
        @memset(memory[0..f.bytes], 0x80);
    }

    /// The block's frame copied out as NV12.
    fn copyOut(s: *Session, f: *Frame) void {
        const memory = f.memory.?;
        const pitch: usize = f.pitch;
        bcm.copyOut(f.sand.ptr(), s.layout, memory, memory + @as(usize, f.rows) * pitch, pitch);
    }

    fn packetRoom(s: *Session, bytes: u32) bool {
        if (s.packet_room >= bytes) return true;
        if (s.packet) |packet| s.sys().FreeMem(packet, s.packet_room);
        s.packet_room = 0;
        const room = (bytes + 0xFFFF) & ~@as(u32, 0xFFFF);
        s.packet = @ptrCast(s.sys().AllocMem(room, exec.MEMF_ANY | exec.MEMF_SYSTEM) orelse {
            s.packet = null;
            return false;
        });
        s.packet_room = room;
        return true;
    }

    /// The bitstream's room as large as `bytes` at least, what it holds
    /// kept.
    fn stageRoom(s: *Session, bytes: u32) bool {
        if (s.stage.bytes >= bytes) return true;
        const room = @max(bitstream_least, (bytes + 0xFFFF) & ~@as(u32, 0xFFFF));
        const made = Dma.alloc(s.sys(), room) orelse return false;
        if (s.stage.memory != null) s.sys().CopyMem(s.stage.ptr(), made.ptr(), s.staged);
        s.stage.free(s.sys());
        s.stage = made;
        return true;
    }

    /// The command list's room as large as `count` commands at least,
    /// those put down kept.
    fn commandRoom(s: *Session, count: u32) bool {
        if (s.command_room >= count) return true;
        const room = @max(commands_least, std.math.ceilPowerOfTwoAssert(u32, count));
        const made = Dma.alloc(s.sys(), @as(usize, room) * @sizeOf(bcm.Command)) orelse return false;
        if (s.commands.memory != null) s.sys().CopyMem(s.commands.ptr(), made.ptr(), @as(usize, s.command_count) * @sizeOf(bcm.Command));
        s.commands.free(s.sys());
        s.commands = made;
        s.command_room = room;
        return true;
    }
};

/// Where the slice data starts in the unit as it came: the byte the
/// payload's `offset` is at - the payload after the unit's two-byte
/// header, without its emulation prevention bytes. Null when the unit
/// ends first.
fn codedOffset(unit: []const u8, offset: u32) ?u32 {
    var zeros: u32 = 0;
    var payload: u32 = 0;
    var i: u32 = 2;
    while (i < unit.len) : (i += 1) {
        const b = unit[i];
        if (zeros >= 2 and b == 3) {
            zeros = 0;
            continue;
        }
        if (payload == offset) return i;
        payload += 1;
        zeros = if (b == 0) zeros + 1 else 0;
    }
    return null;
}

// --- tests (host: ./zig build test) ----------------------------------------------

const testing = std.testing;

test "the slice data's start in the unit as it came, its escapes counted" {
    // Header 0x26 0x01, payload 00 00 [03] 01 80 | data...
    const unit = [_]u8{ 0x26, 0x01, 0x00, 0x00, 0x03, 0x01, 0x80, 0xAB, 0xCD };
    try testing.expectEqual(@as(?u32, 2), codedOffset(&unit, 0));
    try testing.expectEqual(@as(?u32, 5), codedOffset(&unit, 2));
    try testing.expectEqual(@as(?u32, 7), codedOffset(&unit, 4));
    try testing.expectEqual(@as(?u32, null), codedOffset(&unit, 6));
}
