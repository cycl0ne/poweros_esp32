// SPDX-License-Identifier: MIT
//! Ogg Vorbis as a stream: the three headers - what the sound is, its
//! comments, the setup its packets are decoded with - then audio packets,
//! decoded one at a time (`packet.zig`) and handed out across calls.
//!
//! **The length is exact.** Ogg pages carry granule positions - how many
//! samples the stream has given by the end of a page's last packet - and
//! the decoder holds to them: samples an encoder put before the sound are
//! left out where the first page says fewer than its packets give, and
//! the last page cuts the end where it says the sound stops. A stream
//! whose positions begin past 0 - cut from a longer one - counts from its
//! first sample. A file's length is its last page's position, found at
//! its end when it is opened.
//!
//! **A seek is exact.** A search halving the file finds the last page at
//! or before the sample asked for whose last packet begins on it;
//! decoding starts with that packet, which hands nothing out but makes
//! the next one whole, and the page's position says where the sound
//! goes on from. What lies between it and the sample is passed over.
//!
//! The samples are handed out at 16 bits, rounded and held at their ends.
//! A stream of one or two channels is decoded; more are refused, as is
//! a floor of type 0. A chained file - streams one after another - ends
//! with the first.

const sdk = @import("sdk");
const exec = sdk.exec;
const ac = sdk.audiocodec;
const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;
const ogg = @import("../ogg/_ogg.zig");
const setup = @import("setup.zig");
const imdct = @import("imdct.zig");
const packet = @import("packet.zig");
const comments = @import("comments.zig");

pub const Vorbis = struct {
    ogg: ogg.Ogg,
    /// The memory of the setup, the tables and the buffers.
    pool: ?*anyopaque,
    setup: setup.Setup,
    channels: u32,
    blocksizes: [2]u32,
    transforms: [2]imdct.Transform,
    /// For each channel: the block being decoded, the end of the block
    /// before kept to overlap, and the sound handed out.
    buffers: [2][*]f32,
    overlaps: [2][*]f32,
    outputs: [2][*]f32,
    /// The residue's classifications, `class_stride` for each vector.
    classifications: [*]u8,
    class_stride: u32,
    /// Each channel's floor: its points' amplitudes, which are drawn
    /// through, and whether it is used at all.
    final_y: [2][65]i32,
    step2: [2][65]bool,
    used: [2]bool,
    /// The block before - 0 for none - and where its falling slope starts,
    /// from its middle.
    previous_n: u32,
    previous_start: u32,
    /// The sound decoded: frames in the outputs, how many handed out.
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
    /// Where the first audio packet is: its page, and its first segment.
    audio_page: u64,
    audio_segment: u32,
};

/// The headers read: the info filled in, the stream at the first audio
/// packet.
pub fn open(stream: *Stream) i32 {
    stream.codec = .{ .vorbis = undefined };
    const v = &stream.codec.vorbis;
    v.* = .{
        .ogg = undefined,
        .pool = null,
        .setup = undefined,
        .channels = 0,
        .blocksizes = .{ 0, 0 },
        .transforms = undefined,
        .buffers = undefined,
        .overlaps = undefined,
        .outputs = undefined,
        .classifications = undefined,
        .class_stride = 0,
        .final_y = undefined,
        .step2 = undefined,
        .used = .{ false, false },
        .previous_n = 0,
        .previous_start = 0,
        .ready = 0,
        .ready_start = 0,
        .position = -1,
        .produced = 0,
        .seeking = false,
        .target = 0,
        .skip_frames = 0,
        .start_offset = 0,
        .audio_page = 0,
        .audio_segment = 0,
    };
    ogg.begin(&v.ogg, null);

    // What the sound is.
    if (!ogg.startPacket(stream, &v.ogg)) return failure(stream);
    var head: [30]u8 = undefined;
    const got = ogg.readBytes(stream, &v.ogg, &head);
    ogg.endPacket(stream, &v.ogg);
    if (got < head.len or head[0] != 1 or !_stream.same(head[1..], "vorbis")) return ac.ACERR_CORRUPT;
    const channels: u32 = head[11];
    const rate = _stream.le32(head[12..16]);
    const nominal: i32 = @bitCast(_stream.le32(head[20..24]));
    const short_bits = head[28] & 0x0F;
    const long_bits = head[28] >> 4;
    if (_stream.le32(head[7..11]) != 0 or channels == 0 or rate == 0 or head[29] & 1 == 0) return ac.ACERR_CORRUPT;
    if (short_bits < 6 or long_bits > 13 or short_bits > long_bits) return ac.ACERR_CORRUPT;
    if (channels > 2) return ac.ACERR_UNSUPPORTED;
    v.channels = channels;
    v.blocksizes = .{ @as(u32, 1) << @intCast(short_bits), @as(u32, 1) << @intCast(long_bits) };

    // Its comments.
    if (!ogg.startPacket(stream, &v.ogg)) return failure(stream);
    var kind: [7]u8 = undefined;
    if (ogg.readBytes(stream, &v.ogg, &kind) != kind.len or kind[0] != 3 or !_stream.same(kind[1..], "vorbis")) return ac.ACERR_CORRUPT;
    var reader: ogg.PacketReader = .{ .stream = stream, .ogg = &v.ogg };
    comments.read(&reader, stream);
    ogg.endPacket(stream, &v.ogg);

    // The setup.
    if (!ogg.startPacket(stream, &v.ogg)) return failure(stream);
    if (ogg.readBytes(stream, &v.ogg, &kind) != kind.len or kind[0] != 5 or !_stream.same(kind[1..], "vorbis")) return ac.ACERR_CORRUPT;
    const sys = stream.base.sys_base;
    const pool = sys.CreatePool(exec.MEMF_ANY | exec.MEMF_CLEAR, 32 * 1024, 8 * 1024) orelse return ac.ACERR_NOMEMORY;
    v.pool = pool;
    var bits: ogg.Bits = .{ .stream = stream, .ogg = &v.ogg };
    const result = setup.read(&bits, sys, pool, channels, &v.setup);
    ogg.endPacket(stream, &v.ogg);
    if (result != ac.ACERR_OK) return result;

    // The tables and the buffers.
    const long = v.blocksizes[1];
    for (0..2) |size| {
        if (!imdct.init(sys, pool, v.blocksizes[size], &v.transforms[size])) return ac.ACERR_NOMEMORY;
    }
    for (0..channels) |channel| {
        v.buffers[channel] = setup.allocate(sys, pool, f32, long) orelse return ac.ACERR_NOMEMORY;
        v.overlaps[channel] = setup.allocate(sys, pool, f32, long / 2) orelse return ac.ACERR_NOMEMORY;
        v.outputs[channel] = setup.allocate(sys, pool, f32, long) orelse return ac.ACERR_NOMEMORY;
    }
    var stride: u32 = 1;
    for (v.setup.residues[0..v.setup.residue_count]) |*residue| {
        const actual = (long / 2) * (if (residue.kind == 2) channels else 1);
        const begin = @min(residue.begin, actual);
        const end = @min(residue.end, actual);
        if (end > begin) stride = @max(stride, (end - begin) / residue.partition_size);
    }
    v.class_stride = stride;
    v.classifications = setup.allocate(sys, pool, u8, stride * channels) orelse return ac.ACERR_NOMEMORY;

    // Where the sound begins, where its positions start, how long it is.
    if (v.ogg.segment < v.ogg.segments) {
        v.audio_page = v.ogg.page_offset;
        v.audio_segment = v.ogg.segment;
    } else {
        v.audio_page = _stream.tell(stream);
        v.audio_segment = 0;
        v.start_offset = startOffset(stream, v);
    }
    var frames: u64 = 0;
    if (stream.file != null and stream.has_end) {
        const last = lastGranule(stream, v);
        if (last > 0 and @as(u64, @intCast(last)) > v.start_offset) frames = @as(u64, @intCast(last)) - v.start_offset;
        if (!positionAt(stream, v, v.audio_page, v.audio_segment)) return ac.ACERR_READ;
    }

    stream.info.codec = ac.ACODEC_VORBIS;
    stream.info.rate = rate;
    stream.info.channels = channels;
    stream.info.bits = 16;
    stream.info.frames = @intCast(@min(frames, 0xFFFF_FFFF));
    if (nominal > 0) {
        stream.info.bitrate = @intCast(nominal);
    } else if (frames != 0 and stream.end > v.audio_page) {
        stream.info.bitrate = @intCast(@min((stream.end - v.audio_page) * 8 * rate / frames, 0xFFFF_FFFF));
    }
    comments.finishChapters(stream, @intCast(@min(frames * 1000 / rate, 0xFFFF_FFFF)));
    return ac.ACERR_OK;
}

fn failure(stream: *Stream) i32 {
    return if (stream.failed) ac.ACERR_READ else ac.ACERR_CORRUPT;
}

/// The memory a stream's Vorbis holds given back.
pub fn free(stream: *Stream, v: *Vorbis) void {
    if (v.pool) |pool| stream.base.sys_base.DeletePool(pool);
    v.pool = null;
}

/// The granule position of the first frame: the first page with a
/// position, less what the packets that end on it and the pages before
/// give - 0 when that is less, or the pages are not all in the read-ahead
/// to be looked at.
fn startOffset(stream: *Stream, v: *const Vorbis) u64 {
    _stream.fill(stream);
    const bytes = _stream.available(stream);
    var at: usize = 0;
    var last_block: u32 = 0;
    var given: u64 = 0;
    var first_byte: ?u8 = null;
    var inside = false;
    while (at < bytes.len) {
        const head = ogg.pageAt(bytes[at..]) orelse return 0;
        if (at + head.bytes > bytes.len) return 0;
        if (head.serial == v.ogg.serial) {
            var offset = at + head.head_bytes;
            for (bytes[at + 27 .. at + head.head_bytes]) |value| {
                if (!inside) {
                    inside = true;
                    first_byte = if (value > 0) bytes[offset] else null;
                }
                offset += value;
                if (value == 255) continue;
                inside = false;
                const block = blockOf(v, first_byte orelse continue);
                if (block == 0) continue;
                if (last_block != 0) given += (last_block + block) / 4;
                last_block = block;
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

/// The block size of the audio packet whose first byte is `byte`, 0 for
/// one that is no audio.
fn blockOf(v: *const Vorbis, byte: u8) u32 {
    if (byte & 1 != 0) return 0;
    const mask = (@as(u32, 1) << @intCast(v.setup.mode_bits)) - 1;
    const mode = (@as(u32, byte) >> 1) & mask;
    if (mode >= v.setup.mode_count) return 0;
    return v.blocksizes[@intFromBool(v.setup.modes[mode].long)];
}

/// The last granule position of the stream in the file, looked for in
/// more and more of its end: -1 when there is none.
fn lastGranule(stream: *Stream, v: *const Vorbis) i64 {
    var span: u64 = 32 * 1024;
    while (true) {
        const from = if (stream.end - v.audio_page > span) stream.end - span else v.audio_page;
        if (!_stream.seekSource(stream, from)) return -1;
        var probe: ogg.Ogg = undefined;
        ogg.begin(&probe, v.ogg.serial);
        var last: i64 = -1;
        while (ogg.nextPage(stream, &probe)) {
            if (probe.granule >= 0) last = probe.granule;
            _stream.skip(stream, bodyOf(&probe));
        }
        if (last >= 0 or from == v.audio_page) return last;
        span *= 4;
    }
}

/// The bytes of a page's segments.
fn bodyOf(probe: *const ogg.Ogg) u64 {
    var length: u64 = 0;
    for (probe.lacing[0..probe.segments]) |value| length += value;
    return length;
}

/// The reader set at segment `segment` of the page at `offset`, and the
/// decoder made fresh: no block before, no position known.
fn positionAt(stream: *Stream, v: *Vorbis, offset: u64, segment: u32) bool {
    if (!_stream.seekSource(stream, offset)) return false;
    ogg.begin(&v.ogg, v.ogg.serial);
    if (!ogg.nextPage(stream, &v.ogg) or segment > v.ogg.segments) return false;
    var before: u64 = 0;
    for (v.ogg.lacing[0..segment]) |value| before += value;
    _stream.skip(stream, before);
    v.ogg.segment = segment;
    v.ogg.pass_continued = false;
    v.previous_n = 0;
    v.ready = 0;
    v.ready_start = 0;
    v.position = -1;
    v.produced = 0;
    v.seeking = false;
    v.skip_frames = 0;
    return true;
}

// --- handing out ------------------------------------------------------------------

/// Up to `frames` frames into `out`: how many, 0 at the end.
pub fn decode(stream: *Stream, v: *Vorbis, out: [*]i16, frames: u32) i32 {
    const channels: usize = v.channels;
    var done: u32 = 0;
    while (done < frames) {
        if (v.ready_start >= v.ready) {
            switch (packet.decode(stream, v)) {
                .end => break,
                .passed => {},
                .decoded => account(v),
            }
            continue;
        }
        const count = @min(v.ready - v.ready_start, frames - done);
        const into = out + @as(usize, done) * channels;
        for (0..channels) |channel| {
            const from = v.outputs[channel] + v.ready_start;
            for (0..count) |i| into[i * channels + channel] = toSixteen(from[i]);
        }
        v.ready_start += count;
        done += count;
    }
    if (done == 0 and stream.failed) return ac.ACERR_READ;
    return @intCast(done);
}

/// A sample at 16 bits: rounded to the nearest, held at the ends.
fn toSixteen(sample: f32) i16 {
    const scaled = @max(-32768.0, @min(sample * 32768.0, 32767.0));
    // Added to 1.5 * 2^23, the sum's low bits are the rounded value.
    const sum: f32 = scaled + 12582912.0;
    const word: u32 = @bitCast(sum);
    return @truncate(@as(i32, @bitCast(word)) - 0x4B40_0000);
}

/// A packet's sound held to the granule positions: the start of the
/// stream cut where the first page says, its end where the last does;
/// after a seek, what lies before the target passed over.
fn account(v: *Vorbis) void {
    const length: u64 = v.ready;
    const granule = v.ogg.packet_granule;
    const ends = v.ogg.packet_ends_stream;
    if (v.position < 0) {
        v.produced += length;
        if (granule >= 0) {
            const known: u64 = @intCast(granule);
            if (v.produced > known) {
                const extra: u32 = @intCast(@min(v.produced - known, length));
                if (ends) v.ready -= extra else v.ready_start += extra;
            }
            v.position = granule;
        }
    } else {
        v.position += @intCast(length);
        if (granule >= 0 and granule != v.position) {
            if (v.position > granule and ends) {
                const extra: u32 = @intCast(@min(@as(u64, @intCast(v.position - granule)), length));
                v.ready -= extra;
            }
            v.position = granule;
        }
    }
    if (v.skip_frames != 0) {
        const drop = @min(v.skip_frames, v.ready - v.ready_start);
        v.ready_start += @intCast(drop);
        v.skip_frames -= drop;
    }
    if (!v.seeking) return;
    if (v.position < 0) {
        v.ready_start = v.ready;
        return;
    }
    const end: u64 = @intCast(v.position);
    const left: u64 = v.ready - v.ready_start;
    if (end <= v.target) {
        v.ready_start = v.ready;
        if (end == v.target) v.seeking = false;
        return;
    }
    const first = end - left;
    if (first < v.target) v.ready_start += @intCast(v.target - first);
    v.seeking = false;
}

// --- seeking ----------------------------------------------------------------------

/// The stream moved to `frame` exactly.
pub fn seek(stream: *Stream, v: *Vorbis, frame: u32) i32 {
    if (stream.file == null) return ac.ACERR_NOSEEK;
    const target = @as(u64, frame) + v.start_offset;
    if (frame != 0 and stream.has_end) {
        if (findPage(stream, v, target)) |place| {
            if (!positionAt(stream, v, place.offset, place.segment)) return ac.ACERR_NOSEEK;
            v.seeking = true;
            v.target = target;
            return ac.ACERR_OK;
        }
    }
    // From the first packet, as when the stream was opened, the frames
    // before `frame` passed over.
    if (!positionAt(stream, v, v.audio_page, v.audio_segment)) return ac.ACERR_NOSEEK;
    v.skip_frames = frame;
    return ac.ACERR_OK;
}

const Place = struct { offset: u64, segment: u32 };

/// The last page with a granule position no later than `target` whose
/// last packet begins on it: where that packet begins.
fn findPage(stream: *Stream, v: *const Vorbis, target: u64) ?Place {
    var probe: ogg.Ogg = undefined;
    var low = v.audio_page;
    var high = stream.end;
    var rounds: u32 = 0;
    while (high > low and high - low > 64 * 1024 and rounds < 40) : (rounds += 1) {
        const middle = low + (high - low) / 2;
        if (!_stream.seekSource(stream, middle)) return null;
        ogg.begin(&probe, v.ogg.serial);
        var found: ?u64 = null;
        var granule: i64 = -1;
        while (ogg.nextPage(stream, &probe)) {
            if (probe.page_offset >= high) break;
            if (probe.granule >= 0) {
                found = probe.page_offset;
                granule = probe.granule;
                break;
            }
            _stream.skip(stream, bodyOf(&probe));
        }
        if (found == null or granule > @as(i64, @intCast(target))) {
            high = middle;
        } else {
            low = found.?;
        }
    }
    // From there page by page, to the last that will do.
    if (!_stream.seekSource(stream, low)) return null;
    ogg.begin(&probe, v.ogg.serial);
    var best: ?Place = null;
    while (ogg.nextPage(stream, &probe)) {
        if (probe.granule > @as(i64, @intCast(target))) break;
        if (probe.granule >= 0) {
            if (lastPacketStart(&probe)) |segment| best = .{ .offset = probe.page_offset, .segment = segment };
        }
        _stream.skip(stream, bodyOf(&probe));
    }
    return best;
}

/// The segment the last packet to end on the page begins with, when it
/// begins on this page.
fn lastPacketStart(probe: *const ogg.Ogg) ?u32 {
    if (probe.last_end < 0) return null;
    var index: i32 = probe.last_end - 1;
    while (index >= 0 and probe.lacing[@intCast(index)] == 255) index -= 1;
    if (index < 0 and probe.flags & ogg.continued != 0) return null;
    return @intCast(index + 1);
}
