// SPDX-License-Identifier: MIT
//! Opus as a stream: Ogg Opus (RFC 7845) - an .opus file, a station's
//! stream - or a track of a container, a WebM's, a Matroska file's or an
//! MP4's. The packets are decoded by `decoder.zig`, SILK, CELT or both,
//! always at 48 kHz.
//!
//! **The head** says the channels, how many samples the decoder's start
//! gives before the sound (the pre-skip, left out), a gain for the output
//! and how the channels are coded: one stream of one or two channels, or
//! for more (mapping family 1, Vorbis's order of channels) several
//! streams, some of them stereo, one packet of each one after another in
//! a packet. Those are mixed into stereo: the fronts whole, the centre and
//! the surrounds at -3 dB, the LFE left out - as AC-3's mix is - scaled so
//! the mix never goes louder than its loudest channel, and its peaks bent
//! below full scale by the soft clipper. Families 2 and 3 (ambisonics) and
//! 255 (channels with no meaning given) are refused.
//!
//! **The length and a seek are exact**, by the pages' granule positions
//! as in Ogg Vorbis: 48 kHz samples counted from the stream's first,
//! the pre-skip among them. A seek begins decoding 160 ms before the frame
//! asked for, for the decoder to settle - twice what RFC 7845 asks for -
//! and passes over what lies before it. A chain is played link by link,
//! each with a head of its own.
//!
//! **A packet that will not decode** is concealed for as long as its TOC
//! says it plays, so the sound keeps time; one that says nothing is passed
//! over.
//!
//! **A container's track** brings the head as an MP4's `dOps` (media.library
//! makes a Matroska file's OpusHead one): the pre-skip is the track's delay
//! there, an edit or CodecDelay, and a seek moves the track 160 ms early.

const sdk = @import("sdk");
const exec = sdk.exec;
const ac = sdk.audiocodec;
const media = sdk.media;
const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;
const _media = @import("../stream/_media.zig");
const ogg = @import("../ogg/_ogg.zig");
const link = @import("../ogg/link.zig");
const comments = @import("../vorbis/comments.zig");
const setup = @import("../vorbis/setup.zig");
const decoder = @import("decoder.zig");

const max_frames = decoder.max_frame_size;
/// The most streams a packet is decoded in: family 1's eight channels
/// take no more.
const max_streams = 8;
/// The room for a packet of one stream: 120 ms at the most Opus codes.
const packet_room_per_stream = 8 * 1024;
/// How long the decoder is given to settle after a seek: 160 ms. RFC 7845
/// asks for 80; a voice's long-term prediction, begun on nothing, can take
/// longer.
const preroll = 7680;

pub const Opus = struct {
    ogg: ogg.Ogg,
    /// The memory of the decoders and the buffers.
    pool: ?*anyopaque,
    /// A decoder for each stream; the packet read whole from the pages;
    /// the sound decoded, the channels handed out interleaved; a stream's
    /// own while a packet's streams are mixed.
    decoders: [*]decoder.Decoder,
    packet: [*]u8,
    packet_room: u32,
    pcm: [*]f32,
    stream_pcm: [*]f32,
    /// What the head says: the channels coded, the streams and how many
    /// of them are stereo, the samples to leave out at the start, the
    /// output gain (Q8 dB) and the rate the sound was recorded at.
    channels: u32,
    streams: u32,
    coupled: u32,
    pre_skip: u32,
    gain: i16,
    input_rate: u32,
    /// The channels handed out, 1 or 2; whether the streams are mixed
    /// into them (family 1), and how much of each stream's channel goes
    /// into each; the soft clipper's curve, which goes on from one packet
    /// to the next.
    out_channels: u32,
    mixed: bool,
    gains: [max_streams][2][2]f32,
    softclip_mem: [2]f32,
    /// The sound decoded: frames in `pcm`, how many handed out.
    ready: u32,
    ready_start: u32,
    /// The granule position at the end of the sound decoded, -1 while not
    /// known; frames decoded while it was not.
    position: i64,
    produced: u64,
    /// After a seek: the granule position the sound goes on from; or,
    /// after one decoded from the start, the frames still to pass over.
    seeking: bool,
    target: u64,
    skip_frames: u64,
    /// The granule position of the first frame.
    start_offset: u64,
    /// Where the link's sound lies in a file.
    extent: link.Link,
    /// The ACERR_* a link broke the stream with, 0 while it has not.
    broken: i32,
};

fn fresh(stream: *Stream) ?*Opus {
    const o = _stream.stateOf(stream, Opus) orelse return null;
    o.* = .{
        .ogg = undefined,
        .pool = null,
        .decoders = undefined,
        .packet = undefined,
        .packet_room = 0,
        .pcm = undefined,
        .stream_pcm = undefined,
        .channels = 0,
        .streams = 0,
        .coupled = 0,
        .pre_skip = 0,
        .gain = 0,
        .input_rate = 0,
        .out_channels = 0,
        .mixed = false,
        .gains = @splat(@splat(.{ 0, 0 })),
        .softclip_mem = .{ 0, 0 },
        .ready = 0,
        .ready_start = 0,
        .position = -1,
        .produced = 0,
        .seeking = false,
        .target = 0,
        .skip_frames = 0,
        .start_offset = 0,
        .extent = .{ .audio_page = 0, .audio_segment = 0, .end = 0 },
        .broken = 0,
    };
    return o;
}

/// The head and the comments read: the info filled in, the stream at the
/// first audio packet.
pub fn open(stream: *Stream) i32 {
    const o = fresh(stream) orelse return ac.ACERR_NOMEMORY;
    ogg.begin(&o.ogg, null);
    const result = headers(stream, o);
    if (result != ac.ACERR_OK) return result;
    return settle(stream, o);
}

/// A track of a container: its `dOps` the head, the info filled in.
pub fn openTrack(stream: *Stream, track: *const media.MediaTrack) i32 {
    const o = fresh(stream) orelse return ac.ACERR_NOMEMORY;
    var head: Head = undefined;
    if (track.config) |config| {
        head = readDops(config[0..track.config_size]) orelse return ac.ACERR_CORRUPT;
    } else {
        // No head: one stream of the track's channels.
        head = .{ .channels = track.channels, .pre_skip = 0, .input_rate = track.rate, .gain = 0, .family = 0, .streams = 0, .coupled = 0, .mapping = undefined };
        head = mappingOf(&head, &.{}) orelse return ac.ACERR_CORRUPT;
    }
    const result = prepare(stream, o, &head);
    if (result != ac.ACERR_OK) return result;
    restart(o);
    describe(stream, o);
    return ac.ACERR_OK;
}

/// What a head says, the Ogg OpusHead's or a container's dOps.
const Head = struct {
    channels: u32,
    pre_skip: u32,
    input_rate: u32,
    gain: i16,
    family: u8,
    streams: u32,
    coupled: u32,
    mapping: [255]u8,
};

/// An Ogg OpusHead: "OpusHead", the version, then the fields
/// little-endian.
fn readOpusHead(bytes: []const u8) ?Head {
    if (bytes.len < 19 or !_stream.same(bytes, "OpusHead")) return null;
    // A version of another major one is not this format.
    if (bytes[8] >> 4 != 0) return null;
    var head: Head = .{
        .channels = bytes[9],
        .pre_skip = _stream.le16(bytes[10..12]),
        .input_rate = _stream.le32(bytes[12..16]),
        .gain = @bitCast(_stream.le16(bytes[16..18])),
        .family = bytes[18],
        .streams = 0,
        .coupled = 0,
        .mapping = undefined,
    };
    return mappingOf(&head, bytes[19..]);
}

/// A dOps box's body: the version, then the fields big-endian.
fn readDops(bytes: []const u8) ?Head {
    if (bytes.len < 11 or bytes[0] != 0) return null;
    var head: Head = .{
        .channels = bytes[1],
        .pre_skip = be16(bytes[2..4]),
        .input_rate = @as(u32, be16(bytes[4..6])) << 16 | be16(bytes[6..8]),
        .gain = @bitCast(be16(bytes[8..10])),
        .family = bytes[10],
        .streams = 0,
        .coupled = 0,
        .mapping = undefined,
    };
    return mappingOf(&head, bytes[11..]);
}

fn be16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

/// The streams and which stream's channel each channel is: for family 0
/// one stream, stereo for two channels; otherwise the table after the
/// fields, checked.
fn mappingOf(head: *Head, rest: []const u8) ?Head {
    const channels = head.channels;
    if (channels == 0) return null;
    head.mapping = @splat(255);
    if (head.family == 0) {
        if (channels > 2) return null;
        head.streams = 1;
        head.coupled = channels - 1;
        head.mapping[0] = 0;
        head.mapping[1] = 1;
        return head.*;
    }
    if (rest.len < 2 + channels) return null;
    head.streams = rest[0];
    head.coupled = rest[1];
    if (head.streams == 0 or head.coupled > head.streams or head.streams + head.coupled > 255) return null;
    for (rest[2..][0..channels], 0..) |value, c| {
        if (value != 255 and value >= head.streams + head.coupled) return null;
        head.mapping[c] = value;
    }
    return head.*;
}

/// A link's head and comments read, the reader at its first page; then
/// where its sound begins.
fn headers(stream: *Stream, o: *Opus) i32 {
    if (!ogg.startPacket(stream, &o.ogg)) return failure(stream);
    var bytes: [19 + 2 + 255]u8 = undefined;
    const got = ogg.readBytes(stream, &o.ogg, &bytes);
    ogg.endPacket(stream, &o.ogg);
    const head = readOpusHead(bytes[0..got]) orelse return ac.ACERR_CORRUPT;
    var result = prepare(stream, o, &head);
    if (result != ac.ACERR_OK) return result;

    // The comments, as Vorbis's are, after their name.
    if (!ogg.startPacket(stream, &o.ogg)) return failure(stream);
    var kind: [8]u8 = undefined;
    if (ogg.readBytes(stream, &o.ogg, &kind) != kind.len or !_stream.same(&kind, "OpusTags")) result = ac.ACERR_CORRUPT;
    if (result == ac.ACERR_OK) {
        var reader: ogg.PacketReader = .{ .stream = stream, .ogg = &o.ogg };
        comments.read(&reader, stream);
    }
    ogg.endPacket(stream, &o.ogg);
    if (result != ac.ACERR_OK) return result;

    // Where the sound begins, and where its positions start.
    o.start_offset = 0;
    if (o.ogg.segment < o.ogg.segments) {
        o.extent.audio_page = o.ogg.page_offset;
        o.extent.audio_segment = o.ogg.segment;
    } else {
        o.extent.audio_page = _stream.tell(stream);
        o.extent.audio_segment = 0;
        o.start_offset = startOffset(stream, o);
    }
    o.ogg.chained = true;
    return ac.ACERR_OK;
}

/// The decoders and buffers the head asks for, in memory of their own -
/// the link before's given back - and how the streams are mixed.
fn prepare(stream: *Stream, o: *Opus, head: *const Head) i32 {
    if (head.family != 0 and head.family != 1) return ac.ACERR_UNSUPPORTED;
    if (head.family == 1 and head.channels > 8) return ac.ACERR_UNSUPPORTED;
    if (head.streams > max_streams) return ac.ACERR_UNSUPPORTED;
    o.channels = head.channels;
    o.streams = head.streams;
    o.coupled = head.coupled;
    o.pre_skip = head.pre_skip;
    o.gain = head.gain;
    o.input_rate = head.input_rate;
    o.out_channels = if (head.channels == 1) 1 else 2;
    o.mixed = head.family != 0;
    mixOf(o, head);

    const sys = stream.base.sys_base;
    if (o.pool) |before| sys.DeletePool(before);
    o.pool = null;
    const pool = sys.CreatePool(exec.MEMF_ANY | exec.MEMF_CLEAR, 32 * 1024, 8 * 1024) orelse return ac.ACERR_NOMEMORY;
    o.pool = pool;
    o.decoders = setup.allocate(sys, pool, decoder.Decoder, o.streams) orelse return ac.ACERR_NOMEMORY;
    o.packet_room = packet_room_per_stream * o.streams;
    o.packet = setup.allocate(sys, pool, u8, o.packet_room) orelse return ac.ACERR_NOMEMORY;
    o.pcm = setup.allocate(sys, pool, f32, max_frames * o.out_channels) orelse return ac.ACERR_NOMEMORY;
    if (o.mixed) {
        o.stream_pcm = setup.allocate(sys, pool, f32, max_frames * 2) orelse return ac.ACERR_NOMEMORY;
    }
    for (0..o.streams) |s| {
        const d = &o.decoders[s];
        d.init(if (s < o.coupled) 2 else 1);
        d.decode_gain = o.gain;
    }
    return ac.ACERR_OK;
}

/// What each coded channel adds to the left and right handed out, in
/// Vorbis's order of channels (RFC 7845 5.1.1.2).
const Role = enum { mono, left, right, centre, side_left, side_right, rear_centre, lfe };

const layouts = [8][]const Role{
    &.{.mono},
    &.{ .left, .right },
    &.{ .left, .centre, .right },
    &.{ .left, .right, .side_left, .side_right },
    &.{ .left, .centre, .right, .side_left, .side_right },
    &.{ .left, .centre, .right, .side_left, .side_right, .lfe },
    &.{ .left, .centre, .right, .side_left, .side_right, .rear_centre, .lfe },
    &.{ .left, .centre, .right, .side_left, .side_right, .side_left, .side_right, .lfe },
};

fn shareOf(role: Role) [2]f32 {
    const h = 0.7071067811865476;
    return switch (role) {
        .mono => .{ 1, 1 },
        .left => .{ 1, 0 },
        .right => .{ 0, 1 },
        .centre => .{ h, h },
        .side_left => .{ h, 0 },
        .side_right => .{ 0, h },
        .rear_centre => .{ 0.5, 0.5 },
        .lfe => .{ 0, 0 },
    };
}

/// How much of each stream's channels goes into the left and right
/// handed out: each coded channel's share by its place, scaled so each
/// side's shares add up to 1.
fn mixOf(o: *Opus, head: *const Head) void {
    o.gains = @splat(@splat(.{ 0, 0 }));
    // Family 0's one stream is handed out as it decodes.
    if (head.family == 0) return;
    const layout = layouts[head.channels - 1];
    var sums: [2]f32 = .{ 0, 0 };
    for (layout) |role| {
        const share = shareOf(role);
        sums[0] += share[0];
        sums[1] += share[1];
    }
    for (layout, 0..) |role, c| {
        const at = head.mapping[c];
        if (at == 255) continue;
        const share = shareOf(role);
        const s: usize = if (at < 2 * head.coupled) at / 2 else at - head.coupled;
        const k: usize = if (at < 2 * head.coupled) at % 2 else 0;
        o.gains[s][k][0] += share[0] / sums[0];
        o.gains[s][k][1] += share[1] / sums[1];
    }
}

/// The link's length and the info: a file's link measured and the reader
/// set at its first sound again; for a stream read once, the decoder made
/// fresh.
fn settle(stream: *Stream, o: *Opus) i32 {
    var frames: u64 = 0;
    o.extent.end = stream.end;
    if (stream.file != null and stream.has_end) {
        const last = link.measure(stream, &o.ogg, &o.extent);
        const first = o.start_offset + o.pre_skip;
        if (last > 0 and @as(u64, @intCast(last)) > first) frames = @as(u64, @intCast(last)) - first;
        if (!positionAt(stream, o, o.extent.audio_page, o.extent.audio_segment)) return ac.ACERR_READ;
    } else {
        restart(o);
    }
    o.skip_frames = o.pre_skip;
    describe(stream, o);
    stream.info.frames = @intCast(@min(frames, 0xFFFF_FFFF));
    if (frames != 0 and o.extent.end > o.extent.audio_page) {
        stream.info.bitrate = @intCast(@min((o.extent.end - o.extent.audio_page) * 8 * 48000 / frames, 0xFFFF_FFFF));
    }
    comments.finishChapters(stream, @intCast(@min(frames * 1000 / 48000, 0xFFFF_FFFF)));
    return ac.ACERR_OK;
}

fn describe(stream: *Stream, o: *const Opus) void {
    stream.info.codec = ac.ACODEC_OPUS;
    stream.info.rate = 48000;
    stream.info.channels = o.out_channels;
    stream.info.bits = 16;
    stream.info.bitrate = 0;
}

/// What a link's end came to: the next begun, none following, or one that
/// cannot be decoded - why.
const Next = union(enum) { begun, none, failed: i32 };

/// The next link of a chain begun, when one follows: its head read, its
/// comments the tags, the info its own, and the count of links one more.
fn nextLink(stream: *Stream, o: *Opus) Next {
    if (!link.nextStart(stream, &o.ogg, "OpusHead")) return .none;
    _stream.clearTags(stream);
    var result = headers(stream, o);
    if (result == ac.ACERR_OK) result = settle(stream, o);
    if (result != ac.ACERR_OK) {
        o.broken = result;
        return .{ .failed = result };
    }
    _stream.nameInfo(stream);
    stream.links += 1;
    return .begun;
}

fn failure(stream: *Stream) i32 {
    return if (stream.failed) ac.ACERR_READ else ac.ACERR_CORRUPT;
}

/// The memory a stream's Opus holds given back.
pub fn free(stream: *Stream, o: *Opus) void {
    if (o.pool) |pool| stream.base.sys_base.DeletePool(pool);
    o.pool = null;
}

/// The samples a packet plays a channel, by its TOC (and frame count):
/// null for one that says nothing it could.
fn durationOf(bytes: []const u8) ?u32 {
    if (bytes.len == 0) return null;
    const toc = bytes[0];
    const count: u32 = switch (toc & 3) {
        0 => 1,
        1, 2 => 2,
        else => if (bytes.len < 2) return null else bytes[1] & 0x3F,
    };
    const samples = count * decoder.packetSamplesPerFrame(toc);
    if (samples == 0 or samples > max_frames) return null;
    return samples;
}

/// The granule position of the first frame: the first page with a
/// position, less what the packets that end on it and the pages before
/// play - 0 when that is less, or the pages are not all in the read-ahead
/// to be looked at.
fn startOffset(stream: *Stream, o: *const Opus) u64 {
    _stream.fill(stream);
    const bytes = _stream.available(stream);
    var at: usize = 0;
    var given: u64 = 0;
    var inside = false;
    var pending: u32 = 0;
    while (at < bytes.len) {
        const head = ogg.pageAt(bytes[at..]) orelse return 0;
        if (at + head.bytes > bytes.len) return 0;
        if (head.serial == o.ogg.serial) {
            var offset = at + head.head_bytes;
            for (bytes[at + 27 .. at + head.head_bytes]) |value| {
                // A packet's first two bytes lie in its first segment
                // unless it is shorter; it counts once it ends.
                if (!inside) pending = durationOf(bytes[offset..][0..@min(value, 2)]) orelse 0;
                offset += value;
                inside = value == 255;
                if (!inside) given += pending;
            }
            if (head.granule >= 0) {
                const granule: u64 = @intCast(head.granule);
                return if (granule > given) granule - given else 0;
            }
        }
        at += head.bytes;
    }
    return 0;
}

/// The reader set at segment `segment` of the page at `offset`, and the
/// decoder made fresh.
fn positionAt(stream: *Stream, o: *Opus, offset: u64, segment: u32) bool {
    if (!link.readFrom(stream, &o.ogg, offset, segment)) return false;
    restart(o);
    return true;
}

/// The decoders made fresh: nothing before, no position known, nothing
/// to hand out.
fn restart(o: *Opus) void {
    for (0..o.streams) |s| o.decoders[s].reset();
    o.softclip_mem = .{ 0, 0 };
    o.ready = 0;
    o.ready_start = 0;
    o.position = -1;
    o.produced = 0;
    o.seeking = false;
    o.skip_frames = 0;
}

// --- decoding ---------------------------------------------------------------------

/// A packet's sound into `pcm`: its frames. One that will not decode is
/// concealed for as long as it plays.
fn decodePacket(o: *Opus, bytes: []const u8) u32 {
    const duration = durationOf(bytes) orelse return 0;
    const oc = o.out_channels;
    if (!o.mixed) {
        const got = o.decoders[0].decode(bytes, o.pcm[0 .. max_frames * oc], max_frames, false, true) catch
            return conceal(o, duration);
        return got.samples;
    }
    @memset(o.pcm[0 .. duration * oc], 0);
    var rest = bytes;
    for (0..o.streams) |s| {
        const last = s == o.streams - 1;
        const d = &o.decoders[s];
        const got = d.decode(rest, o.stream_pcm[0 .. max_frames * 2], max_frames, !last, false) catch
            return conceal(o, duration);
        if (got.samples != duration or got.packet_len > rest.len) return conceal(o, duration);
        mix(o, s, got.samples);
        rest = rest[got.packet_len..];
    }
    decoder.softClip(o.pcm[0 .. duration * oc], oc, &o.softclip_mem);
    return duration;
}

/// `samples` of every stream concealed, mixed as decoded ones are.
fn conceal(o: *Opus, samples: u32) u32 {
    const oc = o.out_channels;
    if (!o.mixed) {
        _ = o.decoders[0].decodeLost(o.pcm[0 .. max_frames * oc], samples, true) catch
            @memset(o.pcm[0 .. samples * oc], 0);
        return samples;
    }
    @memset(o.pcm[0 .. samples * oc], 0);
    for (0..o.streams) |s| {
        const got = o.decoders[s].decodeLost(o.stream_pcm[0 .. max_frames * 2], samples, false) catch continue;
        if (got == samples) mix(o, s, samples);
    }
    decoder.softClip(o.pcm[0 .. samples * oc], oc, &o.softclip_mem);
    return samples;
}

/// Stream `s`'s sound added into the channels handed out.
fn mix(o: *Opus, s: usize, samples: u32) void {
    const sc: usize = if (s < o.coupled) 2 else 1;
    const oc: usize = o.out_channels;
    const g = &o.gains[s];
    for (0..samples) |i| {
        for (0..sc) |k| {
            const v = o.stream_pcm[i * sc + k];
            o.pcm[i * oc] += g[k][0] * v;
            if (oc == 2) o.pcm[i * oc + 1] += g[k][1] * v;
        }
    }
}

const Outcome = enum { end, passed, decoded };

/// The next packet of the pages decoded.
fn decodeNext(stream: *Stream, o: *Opus) Outcome {
    if (!ogg.startPacket(stream, &o.ogg)) return .end;
    const got = ogg.readBytes(stream, &o.ogg, o.packet[0..o.packet_room]);
    ogg.endPacket(stream, &o.ogg);
    const bytes = o.packet[0..got];
    if (got == o.packet_room) {
        // Longer than any Opus codes: what it plays is concealed.
        o.ready = conceal(o, durationOf(bytes) orelse return .passed);
    } else {
        o.ready = decodePacket(o, bytes);
    }
    o.ready_start = 0;
    return if (o.ready == 0) .passed else .decoded;
}

/// Up to `frames` frames into `out`: how many, 0 at the end. A call ends
/// with a link's last frame; the next goes on with the link after it.
pub fn decode(stream: *Stream, o: *Opus, out: [*]i16, frames: u32) i32 {
    if (o.broken != 0) return 0;
    var done: u32 = 0;
    while (done < frames) {
        if (o.ready_start >= o.ready and stream.media.base != null) {
            if (!nextPacket(stream, o)) break;
            continue;
        }
        if (o.ready_start >= o.ready) {
            switch (decodeNext(stream, o)) {
                .end => {
                    if (done != 0) break;
                    switch (nextLink(stream, o)) {
                        .begun => continue,
                        .none => break,
                        .failed => |code| return code,
                    }
                },
                .passed => {},
                .decoded => account(o),
            }
            continue;
        }
        const channels: usize = o.out_channels;
        const count = @min(o.ready - o.ready_start, frames - done);
        const from = o.pcm + @as(usize, o.ready_start) * channels;
        const into = out + @as(usize, done) * channels;
        for (0..count * channels) |i| into[i] = decoder.toInt16(from[i]);
        o.ready_start += count;
        done += count;
    }
    if (done == 0 and stream.failed) return ac.ACERR_READ;
    return @intCast(done);
}

/// A container's next packet decoded and placed: false at the end.
fn nextPacket(stream: *Stream, o: *Opus) bool {
    var info: media.MediaPacket = .{};
    const bytes = _media.next(stream, &info) orelse return false;
    const count = decodePacket(o, bytes);
    o.ready = 0;
    o.ready_start = 0;
    if (count == 0) return true;
    const start = _media.place(&stream.media, info.ticks);
    _media.advance(&stream.media, count);
    const span = _media.window(&stream.media, start, count, 0) orelse return true;
    o.ready_start = span.first;
    o.ready = span.last;
    return true;
}

/// A packet's sound held to the granule positions: the start of the
/// stream cut where the first page says, its end where the last does;
/// the pre-skip left out; after a seek, what lies before the target
/// passed over.
fn account(o: *Opus) void {
    const length: u64 = o.ready;
    const granule = o.ogg.packet_granule;
    const ends = o.ogg.packet_ends_stream;
    if (o.position < 0) {
        o.produced += length;
        if (granule >= 0) {
            const known: u64 = @intCast(granule);
            if (o.produced > known) {
                const extra: u32 = @intCast(@min(o.produced - known, length));
                if (ends) o.ready -= extra else o.ready_start += extra;
            }
            o.position = granule;
        }
    } else {
        o.position += @intCast(length);
        if (granule >= 0 and granule != o.position) {
            if (o.position > granule and ends) {
                const extra: u32 = @intCast(@min(@as(u64, @intCast(o.position - granule)), length));
                o.ready -= extra;
            }
            o.position = granule;
        }
    }
    if (o.ready_start > o.ready) o.ready_start = o.ready;
    if (o.skip_frames != 0) {
        const drop = @min(o.skip_frames, o.ready - o.ready_start);
        o.ready_start += @intCast(drop);
        o.skip_frames -= drop;
    }
    if (!o.seeking) return;
    if (o.position < 0) {
        o.ready_start = o.ready;
        return;
    }
    const end: u64 = @intCast(o.position);
    const left: u64 = o.ready - o.ready_start;
    if (end <= o.target) {
        o.ready_start = o.ready;
        if (end == o.target) o.seeking = false;
        return;
    }
    const first = end -| left;
    if (first < o.target) o.ready_start += @intCast(o.target - first);
    o.seeking = false;
}

// --- seeking ----------------------------------------------------------------------

/// The stream moved to `frame` of the link being played, exactly: decoding
/// begins 160 ms before it.
pub fn seek(stream: *Stream, o: *Opus, frame: u32) i32 {
    if (stream.media.base != null) {
        const result = _media.seek(stream, frame, preroll);
        if (result != ac.ACERR_OK) return result;
        restart(o);
        return ac.ACERR_OK;
    }
    if (stream.file == null) return ac.ACERR_NOSEEK;
    if (o.broken != 0) return o.broken;
    const first = o.start_offset + o.pre_skip;
    const target = first + frame;
    if (target >= first + preroll and stream.has_end) {
        if (link.findPage(stream, &o.ogg, &o.extent, target - preroll)) |place| {
            if (!positionAt(stream, o, place.offset, place.segment)) return ac.ACERR_NOSEEK;
            o.seeking = true;
            o.target = target;
            return ac.ACERR_OK;
        }
    }
    // From the first packet, as when the stream was opened, the frames
    // before `frame` passed over.
    if (!positionAt(stream, o, o.extent.audio_page, o.extent.audio_segment)) return ac.ACERR_NOSEEK;
    o.skip_frames = @as(u64, o.pre_skip) + frame;
    return ac.ACERR_OK;
}
