// SPDX-License-Identifier: MIT
//! FLAC as a stream: "fLaC", the metadata blocks after it, then frames -
//! each a block of samples, decoded whole (`frame.zig`) and handed out
//! across calls.
//!
//! **The metadata**: STREAMINFO says what the sound is - its rate, its
//! channels, its sample size, how many samples, the largest block; a
//! SEEKTABLE where frames begin; VORBIS_COMMENT its tags; PICTURE a
//! picture, kept when the program asked for one (`../vorbis/comments.zig`
//! reads both). The rest is passed over. An ID3v2 tag some programs put
//! in front of "fLaC" is read as an MP3's is.
//!
//! **The samples** are handed out at 16 bits: the top 16 of a wider
//! sample, a narrower one moved up. FLAC of one or two channels and up
//! to 24 bits a sample is decoded; more is refused when the stream is
//! opened, as is FLAC carried in Ogg.
//!
//! **A seek is exact.** It starts from the seek table's point before the
//! frame asked for, or - without a table - from the frame a search
//! halving the file finds before it; then frames are decoded, and passed
//! over, up to the one that holds it. Each frame's header says which
//! sample it begins with.

const sdk = @import("sdk");
const exec = sdk.exec;
const ac = sdk.audiocodec;
const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;
const frame = @import("frame.zig");
const comments = @import("../vorbis/comments.zig");
const mp3 = @import("../mp3/_mp3.zig");

/// A seek table's point: a sample a frame begins with, and where the frame
/// lies after the first.
const SeekPoint = extern struct {
    sample: u64,
    offset: u64,
};

/// The most seek points kept.
const points_max = 65536;

pub const Flac = struct {
    format: frame.Format,
    min_block: u32,
    /// How many samples a channel has, 0 when not known.
    total: u64,
    /// Where the first frame lies.
    first_frame: u64,
    /// A block of samples for each channel, and the seek table's points -
    /// memory of their own, freed with the stream.
    samples: [2][*]i32,
    buffers: ?*anyopaque,
    points: ?[*]SeekPoint,
    point_count: u32,
    /// The block decoded: its frames, how many have been handed out, and
    /// the sample it begins with.
    block: u32,
    given: u32,
    block_start: u64,
    /// After a seek: the samples before `target` are passed over; whether
    /// decoding has gone back to the first frame once already.
    seeking: bool,
    target: u64,
    restarted: bool,
};

/// The metadata read up to the first frame: the info filled in and the
/// stream at the first frame.
pub fn open(stream: *Stream) i32 {
    _stream.fill(stream);
    if (_stream.same(_stream.available(stream), "ID3")) mp3.skipId3v2(stream);
    if (stream.stop - stream.start < 8) _stream.fill(stream);
    const head = _stream.available(stream);
    if (_stream.same(head, "OggS")) return ac.ACERR_UNSUPPORTED;
    if (!_stream.same(head, "fLaC")) return if (stream.failed) ac.ACERR_READ else ac.ACERR_CORRUPT;
    _stream.consume(stream, 4);

    stream.codec = .{ .flac = undefined };
    const f = &stream.codec.flac;
    f.* = .{
        .format = .{ .channels = 0, .bits = 0, .rate = 0, .max_block = 0 },
        .min_block = 0,
        .total = 0,
        .first_frame = 0,
        .samples = undefined,
        .buffers = null,
        .points = null,
        .point_count = 0,
        .block = 0,
        .given = 0,
        .block_start = 0,
        .seeking = false,
        .target = 0,
        .restarted = false,
    };

    var have_info = false;
    while (true) {
        if (stream.stop - stream.start < 4) _stream.fill(stream);
        const bytes = _stream.available(stream);
        if (bytes.len < 4) return if (stream.failed) ac.ACERR_READ else ac.ACERR_CORRUPT;
        const final = bytes[0] & 0x80 != 0;
        const kind = bytes[0] & 0x7F;
        const length: u32 = @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | bytes[3];
        _stream.consume(stream, 4);
        var reader: comments.BlockReader = .{ .stream = stream, .left = length };
        switch (kind) {
            0 => {
                var info: [34]u8 = undefined;
                if (length < info.len or reader.read(&info) != info.len) return ac.ACERR_CORRUPT;
                streamInfo(f, &info);
                if (f.format.channels > 2 or f.format.bits > 24) return ac.ACERR_UNSUPPORTED;
                have_info = true;
            },
            3 => seekTable(stream, f, &reader),
            4 => comments.read(&reader, stream),
            6 => if (stream.tags.keep_picture) comments.picture(&reader, stream),
            127 => return ac.ACERR_CORRUPT,
            else => {},
        }
        reader.skip(reader.left);
        if (final) break;
    }
    if (!have_info) return ac.ACERR_CORRUPT;
    const format = &f.format;
    if (format.rate == 0 or format.bits < 4 or format.max_block < 16) return ac.ACERR_CORRUPT;

    const sys = stream.base.sys_base;
    const each: usize = @as(usize, format.max_block) * @sizeOf(i32);
    const memory = sys.AllocVec(@intCast(each * 2), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return ac.ACERR_NOMEMORY;
    f.buffers = memory;
    const base: [*]u8 = @ptrCast(memory);
    f.samples = .{ @ptrCast(@alignCast(base)), @ptrCast(@alignCast(base + each)) };

    f.first_frame = _stream.tell(stream);
    stream.info.codec = ac.ACODEC_FLAC;
    stream.info.rate = format.rate;
    stream.info.channels = format.channels;
    stream.info.bits = format.bits;
    stream.info.frames = @intCast(@min(f.total, 0xFFFF_FFFF));
    if (f.total != 0 and stream.has_end and stream.end > f.first_frame) {
        stream.info.bitrate = @intCast(@min((stream.end - f.first_frame) * 8 * format.rate / f.total, 0xFFFF_FFFF));
    }
    const milliseconds = if (format.rate != 0) f.total * 1000 / format.rate else 0;
    comments.finishChapters(stream, @intCast(@min(milliseconds, 0xFFFF_FFFF)));
    return ac.ACERR_OK;
}

/// STREAMINFO's 34 bytes: the smallest and largest block, the smallest
/// and largest frame, then the rate (20 bits), channels (3), bits a
/// sample (5) and samples (36), and an MD5 of the sound.
fn streamInfo(f: *Flac, info: *const [34]u8) void {
    f.min_block = @as(u32, info[0]) << 8 | info[1];
    f.format.max_block = @as(u32, info[2]) << 8 | info[3];
    f.format.rate = @as(u32, info[10]) << 12 | @as(u32, info[11]) << 4 | info[12] >> 4;
    f.format.channels = ((info[12] >> 1) & 0x07) + 1;
    f.format.bits = ((@as(u32, info[12]) & 1) << 4 | info[13] >> 4) + 1;
    f.total = @as(u64, info[13] & 0x0F) << 32 | @as(u64, info[14]) << 24 | @as(u64, info[15]) << 16 | @as(u64, info[16]) << 8 | info[17];
}

/// A SEEKTABLE: its points, 18 bytes each - the sample, the offset, the
/// frame's samples - kept but for the placeholders.
fn seekTable(stream: *Stream, f: *Flac, reader: *comments.BlockReader) void {
    if (f.points != null) return;
    const count: u32 = @intCast(@min(reader.left / 18, points_max));
    if (count == 0) return;
    const memory = stream.base.sys_base.AllocVec(count * @sizeOf(SeekPoint), exec.MEMF_ANY) orelse return;
    const points: [*]SeekPoint = @ptrCast(@alignCast(memory));
    f.points = points;
    var kept: u32 = 0;
    for (0..count) |_| {
        var point: [18]u8 = undefined;
        if (reader.read(&point) != point.len) break;
        const sample = be64(point[0..8]);
        if (sample == 0xFFFF_FFFF_FFFF_FFFF) continue;
        points[kept] = .{ .sample = sample, .offset = be64(point[8..16]) };
        kept += 1;
    }
    f.point_count = kept;
}

fn be64(bytes: []const u8) u64 {
    var value: u64 = 0;
    for (bytes[0..8]) |byte| value = value << 8 | byte;
    return value;
}

/// The memory a stream's FLAC holds given back.
pub fn free(stream: *Stream, f: *Flac) void {
    const sys = stream.base.sys_base;
    if (f.buffers) |memory| sys.FreeVec(memory);
    if (f.points) |points| sys.FreeVec(points);
    f.buffers = null;
    f.points = null;
}

/// Up to `frames` frames into `out`: how many, 0 at the end.
pub fn decode(stream: *Stream, f: *Flac, out: [*]i16, frames: u32) i32 {
    const channels: usize = f.format.channels;
    var done: u32 = 0;
    while (done < frames) {
        if (f.given == f.block) {
            if (!nextBlock(stream, f)) break;
            continue;
        }
        const count = @min(f.block - f.given, frames - done);
        const into = out + @as(usize, done) * channels;
        for (0..channels) |channel| {
            const from = f.samples[channel] + f.given;
            for (0..count) |i| into[i * channels + channel] = toSixteen(from[i], f.format.bits);
        }
        f.given += count;
        done += count;
    }
    if (done == 0 and stream.failed) return ac.ACERR_READ;
    return @intCast(done);
}

/// A sample of `bits` at 16 bits: the top 16 of a wider one, a narrower
/// one moved up.
fn toSixteen(sample: i32, bits: u32) i16 {
    if (bits >= 16) return @truncate(sample >> @intCast(bits - 16));
    return @truncate(sample *% (@as(i32, 1) << @intCast(16 - bits)));
}

/// The next frame decoded into the block, what a seek passes over left
/// out: false at the end.
fn nextBlock(stream: *Stream, f: *Flac) bool {
    var header: frame.Header = undefined;
    if (frame.decode(stream, &f.format, f.samples, &header) == .end) return false;
    f.block = header.blocksize;
    f.given = 0;
    f.block_start = sampleOf(f, &header);
    if (f.seeking) {
        if (f.block_start > f.target) {
            // A search led past the frame wanted: from the start again,
            // once.
            if (!f.restarted and _stream.seekSource(stream, f.first_frame)) {
                f.restarted = true;
                f.block = 0;
                return true;
            }
            f.seeking = false;
            return true;
        }
        if (f.block_start + f.block <= f.target) {
            f.given = f.block;
            return true;
        }
        f.given = @intCast(f.target - f.block_start);
        f.seeking = false;
    }
    return true;
}

/// The sample a frame begins with: its header's number, or its number
/// times the block every frame but the last has.
fn sampleOf(f: *const Flac, header: *const frame.Header) u64 {
    if (header.variable) return header.number;
    const fixed: u64 = if (f.min_block == f.format.max_block) f.format.max_block else header.blocksize;
    return header.number *% fixed;
}

/// The stream moved to `target` exactly: decoding goes on from a frame
/// before it, what lies between passed over.
pub fn seek(stream: *Stream, f: *Flac, target: u32) i32 {
    if (stream.file == null) return ac.ACERR_NOSEEK;
    var start: u64 = f.first_frame;
    if (f.points) |points| {
        for (points[0..f.point_count]) |point| {
            if (point.sample > target) break;
            start = f.first_frame + point.offset;
        }
    } else if (stream.has_end) {
        start = search(stream, f, target);
    }
    if (!_stream.seekSource(stream, start)) return ac.ACERR_NOSEEK;
    f.block = 0;
    f.given = 0;
    f.seeking = true;
    f.target = target;
    f.restarted = false;
    return ac.ACERR_OK;
}

/// Where a frame before `target` begins, found by halving the file: the
/// first frame when no better is found.
fn search(stream: *Stream, f: *Flac, target: u64) u64 {
    var low: u64 = f.first_frame;
    var high: u64 = stream.end;
    var rounds: u32 = 0;
    while (high > low and high - low > 64 * 1024 and rounds < 40) : (rounds += 1) {
        const middle = low + (high - low) / 2;
        if (!_stream.seekSource(stream, middle)) break;
        var header: frame.Header = undefined;
        if (!frame.find(stream, &f.format, &header)) {
            high = middle;
            continue;
        }
        const at = _stream.tell(stream);
        if (sampleOf(f, &header) > target or at >= high) {
            high = middle;
        } else {
            low = at;
        }
    }
    return low;
}
