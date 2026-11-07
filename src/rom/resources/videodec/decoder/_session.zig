// SPDX-License-Identifier: MPL-2.0
//! A decoder on an AMD graphics device's video decoder: what
//! OpenVideoDecoder hands out there - a stream videoparse.library reads,
//! whose pictures the device decodes one at a time, and the frames they
//! come to, in the order they are shown.
//!
//! **The stream** is read by a parser (`read`): a packet fed is copied
//! and handed to it, and its events are taken as they come. The sequence
//! makes the stream on the device (`make`) - a stream the decoder knows by
//! its number, with a context in the device's memory, the firmware's
//! 128 KiB and the decoder's own, a reference surface for each of the
//! firmware's numbers for its pictures, and the target each picture is
//! written to. A sequence of another size, or with more references, ends
//! that and makes another. A picture's slices are put together with a
//! start code before each; at its decode they go to the device with its
//! message, the decoder writes the picture into its reference surface
//! and into the target, and the target is read back into the picture's
//! frame.
//!
//! **The firmware's numbers** (0 to 16) name a picture in a message as
//! long as it is a reference: the number names its reference surface
//! too. Each picture takes the lowest free number; at each picture the
//! numbers of the pictures that are no longer referred to are free again.
//! A reference that has none - one the stream lacks, or one not decoded
//! since a seek - is given one and a grey surface, and named as not
//! there.
//!
//! **The frames** are the parser's slots: each its picture's copy in the
//! system's memory, read back from the target - NV12, the rows the
//! picture shows, a target row apart. A slot is given back to the parser
//! once it said the stream needs it no more, the frame was handed out if
//! it was to be shown, and the caller released it.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const types = sdk.resources.videodec;
const vp = sdk.videoparse;
const utility = sdk.utility;
const timer = sdk.devices.timer;
const systimer = sdk.hardware.systimer;
const ExecBase = sdk.interface.exec.ExecBase;
const VideoParseBase = sdk.interface.videoparse.VideoParseBase;
const base = @import("../videodec_base.zig");
const VideoDecBase = base.VideoDecBase;
const vcn = @import("../codec/_vcn.zig");

/// The slots a parser hands out at most: the stream's buffer and two,
/// and the caller's (`held` and two).
pub const most_slots = 40;
const none: u8 = 0xFF;

/// The bitstream's room on the device, at the least.
const bitstream_least: u32 = 256 * 1024;

/// How long a picture's decode is waited for.
const picture_most_us: u64 = 1_000_000;

/// A frame: a slot's picture in the system's memory.
const Frame = struct {
    /// Its rows of brightness, then of colour pairs, `pitch` bytes
    /// apart, from the first row shown; `left` bytes in is the first
    /// sample shown.
    memory: ?[*]u8 = null,
    bytes: usize = 0,
    pitch: u32 = 0,
    rows: u32 = 0,
    left: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// When it is shown: its picture's time as it was fed, until it is
    /// shown - then the earliest of the pictures decoded and not shown.
    time: i64 = 0,
    /// Decoded, or to be shown as if it were, and not shown yet.
    waiting: bool = false,
    /// The firmware's number for it while it is, or may be, a
    /// reference; whether its reference surface holds what was decoded.
    id: u8 = none,
    decoded: bool = false,
    /// The parser handed the slot out and it was not given back; the
    /// parser needs it no more; it is due to be shown; it is lent to
    /// the caller.
    held: bool = false,
    freed: bool = false,
    due: bool = false,
    lent: bool = false,
};

pub const Session = struct {
    vb: *VideoDecBase,
    /// Its place in the base's table of open decoders.
    slot: u32,
    codec: u32,
    /// How many frames the caller holds at once (VDA_HeldFrames).
    held: u32,
    /// videoparse.library and the stream's parser.
    library: ?*VideoParseBase = null,
    parser: ?*vp.VideoParser = null,
    /// The packet fed last, which the parser reads until it asks for
    /// another, and its buffer's room.
    packet: ?[*]u8 = null,
    packet_room: u32 = 0,
    /// The packet still has events to give: the parser waits for a slot.
    reading: bool = false,
    /// The stream's end was fed; every event of it was taken.
    end_fed: bool = false,
    ended: bool = false,
    /// Why the stream stopped (VDERR_*); VDERR_OK while it runs.
    failed: u32 = types.VDERR_OK,
    /// The sequence as it was said, without its parameter set: whether
    /// one was, and what it is.
    told: bool = false,
    sequence: vp.VideoSequence = .{},
    /// The stream on the decoder: its number, made or not, the layout it
    /// was made for and its pieces of the device's memory - the context
    /// (the firmware's, then the decoder's), the reference surfaces, the
    /// target, the slices.
    stream: u32 = 0,
    made: bool = false,
    layout: vcn.Layout = .{},
    context: amdgpu.GPUMemory = .{},
    surfaces: amdgpu.GPUMemory = .{},
    target: amdgpu.GPUMemory = .{},
    bitstream: amdgpu.GPUMemory = .{},
    /// Each firmware number's slot, or none.
    owners: [vcn.most_ids]u8 = @splat(none),
    /// The picture being read, and its slices' units put together, each
    /// after a start code.
    picture: vp.VideoPicture = .{},
    open_picture: bool = false,
    staged: ?[*]u8 = null,
    staged_room: u32 = 0,
    staged_bytes: u32 = 0,
    /// The frames by slot, and the slots due to be shown, in their order.
    frames: [most_slots]Frame = @splat(.{}),
    due: [most_slots]u8 = @splat(none),
    due_first: u32 = 0,
    due_count: u32 = 0,
    /// Frames handed out.
    shown: u32 = 0,
    /// Pictures decoded, and how long the device took over them and the
    /// reading back of their frames, in microseconds.
    decoded: u32 = 0,
    decode_us: u64 = 0,
    read_us: u64 = 0,
    /// A picture's message, and its scaling lists, put together here.
    message: vcn.AvcMessage = .{},
    scaling: vcn.AvcScaling = .{},

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
        const lib = s.sys().OpenLibrary(vp.VIDEOPARSENAME, 1) orelse {
            exec.kprintf(s.sys(), "%s: no %s for the AMD video decoder\n", .{ types.VIDEODECNAME, vp.VIDEOPARSENAME });
            return types.VDERR_NO_ENGINE;
        };
        const library: *VideoParseBase = @ptrCast(lib);
        s.library = library;
        const tags = [_]utility.TagItem{
            .{ .tag = vp.VPA_Slots, .data = s.held + 2 },
            .{ .tag = vp.VPA_MaxWidth, .data = vcn.avc_most },
            .{ .tag = vp.VPA_MaxHeight, .data = vcn.avc_most },
            .{},
        };
        var why: i32 = vp.VPERR_OK;
        s.parser = library.OpenVideoParser(vp.VPCODEC_H264, null, 0, &tags, &why) orelse
            return if (why == vp.VPERR_NOMEMORY) types.VDERR_NO_MEMORY else types.VDERR_UNSUPPORTED;
        return types.VDERR_OK;
    }

    // --- the calls ------------------------------------------------------------

    /// A packet copied and read: as FeedVideoDecoder answers.
    pub fn feed(s: *Session, data: ?[*]const u8, length: u32, time: u64, flags: u32) u32 {
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
        while (true) {
            if (s.failed != types.VDERR_OK) return s.failed;
            if (s.due_count > 0) {
                s.hand(frame);
                return types.VDERR_OK;
            }
            if (!s.reading) return if (s.ended) types.VDERR_END else types.VDERR_NEED_DATA;
            s.read();
            if (s.reading and s.due_count == 0 and s.failed == types.VDERR_OK) {
                // The parser waits for a slot, which only a frame given
                // back makes.
                for (s.frames) |f| {
                    if (f.lent) return types.VDERR_FULL;
                }
                exec.kprintf(s.sys(), "%s: the AMD video decoder's stream %d has no slot free and no frame lent\n", .{ types.VIDEODECNAME, s.stream });
                s.fail(types.VDERR_CORRUPT);
            }
        }
    }

    /// A frame handed back: its slot is given back once the stream needs
    /// it no more.
    pub fn release(s: *Session, frame: *types.VideoDecFrame) void {
        const kept = frame.private[0];
        frame.* = .{};
        if (kept == 0 or kept > most_slots) return;
        const slot = kept - 1;
        const f = &s.frames[slot];
        if (!f.lent) return;
        f.lent = false;
        s.giveBack(slot);
    }

    /// What was fed and not handed out dropped, for a seek: the parser
    /// starts again at the next key picture; the frames lent stay lent.
    pub fn flush(s: *Session) void {
        if (s.parser) |parser| s.library.?.ResetVideoParser(parser);
        s.reading = false;
        s.open_picture = false;
        s.end_fed = false;
        s.ended = false;
        s.due_first = 0;
        s.due_count = 0;
        for (&s.frames, 0..) |*f, slot| {
            f.due = false;
            f.waiting = false;
            if (!f.held) continue;
            f.freed = true;
            s.dropId(f);
            s.giveBack(@intCast(slot));
        }
    }

    /// What the stream is: as GetVideoDecoderInfo answers.
    pub fn info(s: *Session, into: *types.VideoDecInfo) u32 {
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

    /// The stream ended on the decoder and everything of the decoder
    /// freed but itself - the frames lent too. The caller holds the
    /// resource's lock.
    pub fn end(s: *Session) void {
        const sys_base = s.sys();
        if (s.decoded > 0) {
            exec.kprintf(sys_base, "%s: the AMD video decoder's stream %d: %u pictures, %lu us each on the decoder, %lu us each read back\n", .{
                types.VIDEODECNAME, s.stream, s.decoded, s.decode_us / s.decoded, s.read_us / s.decoded,
            });
        }
        s.unmake();
        if (s.library) |library| {
            library.CloseVideoParser(s.parser);
            sys_base.CloseLibrary(library.lib());
        }
        s.parser = null;
        s.library = null;
        for (&s.frames) |*f| {
            if (f.memory) |memory| sys_base.FreeMem(memory, f.bytes);
            f.* = .{};
        }
        if (s.packet) |packet| sys_base.FreeMem(packet, s.packet_room);
        if (s.staged) |staged| sys_base.FreeMem(staged, s.staged_room);
        s.packet = null;
        s.staged = null;
    }

    // --- the parser's events ---------------------------------------------------

    /// The packet's events taken, until it is read or the parser waits for
    /// a slot.
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

    /// A sequence: the stream made on the decoder for it, unless the one
    /// made takes its pictures.
    fn begin(s: *Session, seq: *const vp.VideoSequence) void {
        const sps = seq.h264_sps orelse return s.fail(types.VDERR_CORRUPT);
        if (vcn.avcProfile(sps) == null or seq.chroma_format != 1 or seq.bit_depth_luma != 8 or
            seq.bit_depth_chroma != 8 or seq.slots > most_slots or seq.width == 0 or seq.height == 0)
        {
            exec.kprintf(s.sys(), "%s: the AMD video decoder does not take an H.264 stream of profile %d, %d bits, chroma %d, %d slots\n", .{
                types.VIDEODECNAME,          @as(u32, sps.profile_idc), @as(u32, seq.bit_depth_luma),
                @as(u32, seq.chroma_format), seq.slots,
            });
            return s.fail(types.VDERR_UNSUPPORTED);
        }
        const layout = vcn.Layout.avc(seq.coded_width, seq.coded_height, vcn.avcIds(sps));
        if (layout.width > vcn.avc_most or layout.height > vcn.avc_most) return s.fail(types.VDERR_UNSUPPORTED);
        s.sequence = seq.*;
        s.sequence.h264_sps = null;
        s.sequence.hevc_sps = null;
        s.told = true;
        if (s.made and s.layout.width == layout.width and s.layout.height == layout.height and s.layout.ids >= layout.ids) return;
        s.unmake();
        if (s.failed == types.VDERR_OK) s.make(layout);
    }

    /// A slot that stands for a picture the stream lacks: its frame grey.
    /// It is given a surface when a picture refers to it.
    fn missing(s: *Session, slot: u32, time: i64) void {
        if (slot >= most_slots) return s.fail(types.VDERR_CORRUPT);
        const f = &s.frames[slot];
        s.dropId(f);
        f.held = true;
        f.freed = false;
        f.due = false;
        f.waiting = false;
        f.time = time;
        if (!s.frameRoom(f)) return s.fail(types.VDERR_NO_MEMORY);
        grey(f);
    }

    /// A picture begins: its firmware number, and its references'.
    fn beginPicture(s: *Session, pic: *const vp.VideoPicture) void {
        if (pic.slot >= most_slots) return s.fail(types.VDERR_CORRUPT);
        if (pic.h264_pps) |pps| {
            if (pps.num_slice_groups > 1) {
                exec.kprintf(s.sys(), "%s: the AMD video decoder does not take slice groups\n", .{types.VIDEODECNAME});
                return s.fail(types.VDERR_UNSUPPORTED);
            }
        }
        s.picture = pic.*;
        s.open_picture = true;
        s.staged_bytes = 0;
        const f = &s.frames[pic.slot];
        if (!pic.second_field) {
            s.dropId(f);
            f.held = true;
            f.freed = false;
            f.due = false;
            f.decoded = false;
            f.waiting = true;
            f.time = pic.time;
        }
        s.giveIds(pic);
    }

    /// The firmware's numbers at picture `pic`: kept for it and the
    /// references it holds, the others free again; one taken for it and
    /// for each reference that has none.
    fn giveIds(s: *Session, pic: *const vp.VideoPicture) void {
        var keep: [vcn.most_ids]bool = @splat(false);
        const f = &s.frames[pic.slot];
        if (f.id != none) keep[f.id] = true;
        for (pic.refs[0..pic.ref_count]) |r| {
            if (r.slot >= most_slots) continue;
            const id = s.frames[r.slot].id;
            if (id != none) keep[id] = true;
        }
        for (&s.owners, 0..) |*owner, id| {
            if (owner.* == none or keep[id]) continue;
            s.frames[owner.*].id = none;
            owner.* = none;
        }
        if (f.id == none) f.id = s.takeId(pic.slot);
        for (pic.refs[0..pic.ref_count]) |r| {
            if (r.slot >= most_slots) continue;
            const ref = &s.frames[r.slot];
            if (ref.id != none) continue;
            ref.id = s.takeId(r.slot);
            ref.decoded = false;
            if (ref.id != none and s.made) vcn.fillDevice(s.surface(ref.id), s.layout.refBytes(), 0x8080_8080_8080_8080);
        }
    }

    /// The lowest firmware number free, taken for `slot`; none when every
    /// one is taken.
    fn takeId(s: *Session, slot: u32) u8 {
        for (&s.owners, 0..) |*owner, id| {
            if (id >= s.layout.ids) break;
            if (owner.* != none) continue;
            owner.* = @intCast(slot);
            return @intCast(id);
        }
        return none;
    }

    fn dropId(s: *Session, f: *Frame) void {
        if (f.id == none) return;
        s.owners[f.id] = none;
        f.id = none;
    }

    /// A slice: its unit put after the others, behind a start code.
    fn slice(s: *Session, sl: *const vp.VideoSlice) void {
        if (!s.open_picture) return;
        if (sl.partitioned) {
            exec.kprintf(s.sys(), "%s: the AMD video decoder does not take data partitions\n", .{types.VIDEODECNAME});
            return s.fail(types.VDERR_UNSUPPORTED);
        }
        const need = s.staged_bytes + 3 + sl.unit_bytes;
        if (!s.stageRoom(need + 128)) return s.fail(types.VDERR_NO_MEMORY);
        const into = s.staged.?;
        into[s.staged_bytes] = 0;
        into[s.staged_bytes + 1] = 0;
        into[s.staged_bytes + 2] = 1;
        s.sys().CopyMem(sl.unit, into + s.staged_bytes + 3, sl.unit_bytes);
        s.staged_bytes = need;
    }

    /// The picture's slices given: it is decoded and its frame read back.
    /// A picture that cannot be - no stream made, no slice, no number -
    /// keeps the frame grey.
    fn decode(s: *Session) void {
        if (!s.open_picture) return;
        s.open_picture = false;
        const sys_base = s.sys();
        const vb = s.vb;
        const pic = &s.picture;
        const f = &s.frames[pic.slot];
        if (!s.frameRoom(f)) return s.fail(types.VDERR_NO_MEMORY);
        const sps = pic.h264_sps orelse return grey(f);
        const pps = pic.h264_pps orelse return grey(f);
        if (!s.made or f.id == none or s.staged_bytes == 0) return grey(f);

        // The references with a surface, in the order the picture holds
        // them.
        var refs: [16]vcn.AvcRef = undefined;
        var addresses: [16]u64 = undefined;
        var count: usize = 0;
        for (pic.refs[0..pic.ref_count]) |r| {
            if (r.slot >= most_slots or count == refs.len) continue;
            const ref = &s.frames[r.slot];
            if (ref.id == none) continue;
            refs[count] = .{ .id = ref.id, .decoded = ref.decoded and !r.missing, .ref = r };
            addresses[count] = s.surface(ref.id);
            count += 1;
        }

        const bytes = (s.staged_bytes + 127) / 128 * 128;
        if (!s.bitstreamRoom(bytes)) return s.fail(types.VDERR_NO_MEMORY);
        const staged = s.staged.?;
        for (staged[s.staged_bytes..bytes]) |*b| b.* = 0;
        vcn.copyToDevice(s.bitstream.cpu, staged[0..bytes]);
        vcn.avcPart(&s.message.avc, &s.scaling, sps, pps, pic, f.id, refs[0..count]);
        vcn.avcMessage(&s.message, s.layout, s.stream, s.decoded, bytes, s.surface(f.id), addresses[0..count]);

        const timeout = Timeout.open(sys_base) orelse return s.fail(types.VDERR_NO_MEMORY);
        defer timeout.close(sys_base);
        const started = systimer.uptimeUs();
        vcn.decodeAvc(&vb.vcn, &s.message, &s.scaling, .{
            .flags = vcn.decode_buffers,
            .message = 0,
            .session = s.context.device,
            .context = s.context.device + vcn.session_bytes,
            .bitstream = s.bitstream.device,
            .target = s.target.device,
        });
        if (!vcn.fenced(&vb.vcn, picture_most_us, Pause{ .timeout = timeout, .sys = sys_base })) {
            // The decoder may still write the stream's pieces: they are
            // kept, and it is not asked again.
            vcn.report(sys_base, &vb.vcn, "did not finish a picture");
            vb.state = base.STATE_DEAD;
            return s.fail(types.VDERR_CORRUPT);
        }
        const done = systimer.uptimeUs();
        f.decoded = true;
        s.readBack(f);
        s.decode_us += done - started;
        s.read_us += systimer.uptimeUs() - done;
        s.decoded += 1;
    }

    /// A picture due to be shown, after those due before it: with the
    /// earliest time of the pictures decoded and not shown - its own,
    /// where they were fed with the times they are shown at.
    fn show(s: *Session, slot: u32, time: i64) void {
        if (slot >= most_slots) return;
        const f = &s.frames[slot];
        if (f.memory == null) {
            if (!s.frameRoom(f)) return s.fail(types.VDERR_NO_MEMORY);
            grey(f);
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
        f.due = true;
        s.due[(s.due_first + s.due_count) % most_slots] = @intCast(slot);
        s.due_count += 1;
    }

    /// A slot the stream needs no more: no reference now, and given back
    /// unless its frame is still to be handed out or is lent.
    fn free(s: *Session, slot: u32) void {
        if (slot >= most_slots) return;
        const f = &s.frames[slot];
        f.freed = true;
        // Never to be shown, its time with it.
        f.waiting = false;
        s.dropId(f);
        s.giveBack(slot);
    }

    fn giveBack(s: *Session, slot: u32) void {
        const f = &s.frames[slot];
        if (!f.held or !f.freed or f.due or f.lent) return;
        f.held = false;
        s.library.?.ReleaseVideoSlot(s.parser.?, slot);
    }

    /// The first frame due handed out in `frame`.
    fn hand(s: *Session, frame: *types.VideoDecFrame) void {
        const slot: u32 = s.due[s.due_first];
        s.due_first = (s.due_first + 1) % most_slots;
        s.due_count -= 1;
        const f = &s.frames[slot];
        f.due = false;
        f.lent = true;
        const memory = f.memory.?;
        frame.* = .{
            .y = memory + f.left,
            .cbcr = memory + @as(usize, f.rows) * f.pitch + f.left,
            .pitch = f.pitch,
            .width = f.width,
            .height = f.height,
            .format = types.VDFMT_NV12,
            .time = @bitCast(f.time),
            .number = s.shown,
            .private = .{ slot + 1, s.slot, 0 },
        };
        s.shown += 1;
    }

    // --- the stream on the device ------------------------------------------------

    fn surface(s: *const Session, id: u8) u64 {
        return s.surfaces.device + @as(u64, id) * s.layout.refBytes();
    }

    /// The stream made on the decoder for `layout`: its pieces taken, its
    /// context cleared, the making sent. On failure the stream stops: no
    /// room, or a decoder that did not answer - which is then taken as
    /// dead.
    fn make(s: *Session, layout: vcn.Layout) void {
        const vb = s.vb;
        const sys_base = s.sys();
        const gpu = vb.vcn.gpu orelse return s.fail(types.VDERR_NO_ENGINE);
        if (!gpu.AllocGPUMemory(vcn.session_bytes + layout.hw_bytes, 4096, &s.context) or
            !gpu.AllocGPUMemory(layout.ids * layout.refBytes(), 4096, &s.surfaces) or
            !gpu.AllocGPUMemory(layout.targetBytes(), 4096, &s.target))
        {
            exec.kprintf(sys_base, "%s: no room for a %u x %u stream on the AMD video decoder\n", .{ types.VIDEODECNAME, layout.width, layout.height });
            s.freePieces();
            return s.fail(types.VDERR_NO_MEMORY);
        }
        vcn.clear(s.context.cpu, vcn.session_bytes);
        vb.vcn.streams +%= 1;
        s.stream = vb.vcn.streams;
        var message: [16]u32 = undefined;
        const words = vcn.createMessage(&message, s.stream, vcn.streamKind(s.codec), layout.width, layout.height);
        if (!vcn.send(sys_base, &vb.vcn, message[0..words], s.context.device, "does not answer a stream's making")) {
            vb.state = base.STATE_DEAD;
            return s.fail(types.VDERR_NO_ENGINE);
        }
        s.made = true;
        s.layout = layout;
        s.owners = @splat(none);
        for (&s.frames) |*f| {
            f.id = none;
            f.decoded = false;
        }
        exec.kprintf(sys_base, "%s: the AMD video decoder made stream %d for %u x %u, %u references: context %u KiB, surfaces %u KiB, target %u KiB\n", .{
            types.VIDEODECNAME,     s.stream,                layout.width,          layout.height, layout.ids - 1,
            s.context.bytes / 1024, s.surfaces.bytes / 1024, s.target.bytes / 1024,
        });
    }

    /// The stream ended on the decoder and its pieces given back. A
    /// decoder that does not answer, or is dead, keeps them - it may still
    /// write them.
    fn unmake(s: *Session) void {
        const vb = s.vb;
        if (vb.state != base.STATE_RUNNING) return;
        if (s.made) {
            s.made = false;
            var message: [8]u32 = undefined;
            const words = vcn.destroyMessage(&message, s.stream);
            if (!vcn.send(s.sys(), &vb.vcn, message[0..words], s.context.device, "does not answer a stream's end")) {
                vb.state = base.STATE_DEAD;
                return;
            }
        }
        s.freePieces();
    }

    fn freePieces(s: *Session) void {
        const gpu = s.vb.vcn.gpu orelse return;
        for ([_]*amdgpu.GPUMemory{ &s.context, &s.surfaces, &s.target, &s.bitstream }) |piece| {
            if (piece.bytes != 0) gpu.FreeGPUMemory(piece);
        }
    }

    /// The bitstream's piece as large as `bytes` at least.
    fn bitstreamRoom(s: *Session, bytes: u32) bool {
        if (s.bitstream.bytes >= bytes) return true;
        const gpu = s.vb.vcn.gpu orelse return false;
        if (s.bitstream.bytes != 0) gpu.FreeGPUMemory(&s.bitstream);
        const room = @max(bitstream_least, (bytes + 0xFFFF) & ~@as(u32, 0xFFFF));
        return gpu.AllocGPUMemory(room, 4096, &s.bitstream);
    }

    // --- the system's memory -------------------------------------------------------

    /// Frame `f` laid out for the sequence and its memory as large as that
    /// takes: the rows shown, a target row apart.
    fn frameRoom(s: *Session, f: *Frame) bool {
        const q = &s.sequence;
        const pitch = if (s.layout.target_pitch != 0) s.layout.target_pitch else (q.coded_width + 255) & ~@as(u32, 255);
        const rows = q.height;
        const bytes: usize = @as(usize, pitch) * (rows + (rows + 1) / 2);
        if (bytes == 0) return false;
        if (f.bytes < bytes) {
            if (f.memory) |memory| s.sys().FreeMem(memory, f.bytes);
            f.bytes = 0;
            f.memory = @ptrCast(s.sys().AllocMem(bytes, exec.MEMF_ANY | exec.MEMF_SYSTEM) orelse {
                f.memory = null;
                return false;
            });
            f.bytes = bytes;
        }
        f.pitch = pitch;
        f.rows = rows;
        f.left = q.left & ~@as(u32, 1);
        f.width = q.width;
        f.height = q.height;
        return true;
    }

    /// The target read back into frame `f`: the rows it shows of
    /// brightness, then of colour.
    fn readBack(s: *Session, f: *Frame) void {
        const top = s.sequence.top & ~@as(u32, 1);
        const pitch: usize = f.pitch;
        const memory = f.memory.?;
        vcn.streamFromDevice(memory, s.target.cpu + top * pitch, f.rows * pitch);
        vcn.streamFromDevice(memory + f.rows * pitch, s.target.cpu + s.layout.targetLuma() + top / 2 * pitch, (f.rows + 1) / 2 * pitch);
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

    /// The staged slices' room as large as `bytes` at least, what they
    /// hold kept.
    fn stageRoom(s: *Session, bytes: u32) bool {
        if (s.staged_room >= bytes) return true;
        const room = @max(bitstream_least, (bytes + 0xFFFF) & ~@as(u32, 0xFFFF));
        const memory: [*]u8 = @ptrCast(s.sys().AllocMem(room, exec.MEMF_ANY | exec.MEMF_SYSTEM) orelse return false);
        if (s.staged) |old| {
            s.sys().CopyMem(old, memory, s.staged_bytes);
            s.sys().FreeMem(old, s.staged_room);
        }
        s.staged = memory;
        s.staged_room = room;
        return true;
    }
};

/// A frame grey: its brightness and colour all the middle value.
fn grey(f: *Frame) void {
    const memory = f.memory orelse return;
    for (memory[0..f.bytes]) |*b| b.* = 0x80;
}

/// A wait of so many microseconds on a timer.device request, for a
/// picture's fence.
const Pause = struct {
    timeout: Timeout,
    sys: *ExecBase,

    pub fn wait(p: Pause, us: u32) void {
        p.timeout.start(p.sys, us);
        _ = p.sys.WaitIO(&p.timeout.request.node);
    }
};

/// timer.device at its microsecond unit, opened for the task that waits.
const Timeout = struct {
    request: *timer.TimeRequest,

    fn open(sys_base: *ExecBase) ?Timeout {
        const port = sys_base.CreateMsgPort() orelse return null;
        const io = sys_base.CreateIORequest(port, @sizeOf(timer.TimeRequest)) orelse {
            sys_base.DeleteMsgPort(port);
            return null;
        };
        if (sys_base.OpenDevice(timer.TIMERNAME, timer.UNIT_MICROHZ, io, 0) != 0) {
            sys_base.DeleteIORequest(io);
            sys_base.DeleteMsgPort(port);
            return null;
        }
        return .{ .request = @fieldParentPtr("node", io) };
    }

    fn close(t: Timeout, sys_base: *ExecBase) void {
        const port = t.request.node.message.reply_port;
        sys_base.CloseDevice(&t.request.node);
        sys_base.DeleteIORequest(&t.request.node);
        sys_base.DeleteMsgPort(port);
    }

    fn start(t: Timeout, sys_base: *ExecBase, us: u64) void {
        _ = sys_base.SetSignal(0, t.request.node.message.reply_port.?.sigMask());
        t.request.node.command = timer.TR_ADDREQUEST;
        t.request.time = timer.TimeVal.fromMicros(us);
        sys_base.SendIO(&t.request.node);
    }
};
