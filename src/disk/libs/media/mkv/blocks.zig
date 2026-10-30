// SPDX-License-Identifier: MIT
//! A Matroska track's packets: its walk through the clusters, block by
//! block, and its moves (SeekMedia).
//!
//! **The clusters** hold the packets of every track side by side, in the
//! order they are decoded: each cluster its time and its blocks - a
//! SimpleBlock, or a BlockGroup of a Block and what is said of it. A
//! block names its track by number and its time from the cluster's; it
//! holds one frame, or several laced together - their sizes Xiph's way,
//! EBML's, or all the same.
//!
//! **Each track walks on its own.** ReadMediaPacket on a track reads the
//! elements after the last block it handed out, passes over the other
//! tracks' blocks and hands out the frames of its own next one. What it
//! reads lies in the track's buffer, read from the file in runs of
//! 256 KiB at least: the heads of the blocks it passes over and its own
//! blocks whole, the frames handed out pointing into it. A block larger
//! than what is left of a run starts the next one; what the run still
//! holds of it is kept. The two tracks of a film so each read the file -
//! twice its bytes, which a film's rate leaves room for - but never get in
//! each other's way, however far apart in the file their packets lie.
//!
//! **A move** starts at the cue point the file lists at or before the
//! time - one of the track's own where it has any, else any track's: in
//! the cluster it names, at the block in it where the cue says where. A
//! track of pictures with cues of its own lands on that block; another
//! walks on to its last block at or before the time (for pictures, its
//! last key frame) - sound always, for a cluster of it lasts seconds.
//! Without cues the walk starts at the first cluster.
//!
//! The frames of a track whose blocks leave out the bytes each frame
//! begins with (Matroska's header stripping) are handed out with them put
//! back, out of a second buffer.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const media = sdk.media;
const _file = @import("../file/_file.zig");
const ebml = @import("ebml.zig");

/// The most frames a block laces together.
pub const max_frames = 256;

/// A track's buffer is read in runs at least this long.
pub const min_run = 256 * 1024;

/// The largest block read.
const max_block = 64 * 1024 * 1024;

/// Times past this many ticks are held at it: thousands of years in
/// milliseconds.
const max_ticks: u64 = 1 << 48;

/// What the file says of its segment, its clock and its cues.
pub const File = struct {
    /// Where the segment's body begins and ends in the file.
    segment_at: u64,
    segment_end: u64,
    /// The nanoseconds a tick of its times lasts.
    scale: u64,
    /// Where its first cluster begins: the segment's end when it has
    /// none.
    first_cluster: u64,
    /// The cue points, a table of their own, in the file's order.
    cues: ?[*]Cue,
    cue_count: u32,
};

/// A cue point: where a track's block at a time lies.
pub const Cue = struct {
    /// Its time in ticks; where its cluster begins, from the segment's
    /// body; where the block is in the cluster's body, `no_relative` when
    /// the cue does not say; the track's number.
    time: u64,
    cluster: u64,
    relative: u64,
    track: u64,
};

pub const no_relative = std.math.maxInt(u64);

pub const Track = struct {
    /// Its number in the blocks; its unique one, which its tags name it
    /// by; how long each of its frames lasts in nanoseconds, 0 when not
    /// known; the codec's delay - an encoder's priming, which its
    /// blocks' times count and what is presented does not - in
    /// nanoseconds; whether it is played unless asked for another.
    number: u64,
    uid: u64,
    frame_ns: u64,
    delay_ns: u64,
    default: bool,
    /// Its frames are compressed other than by header stripping, or
    /// encrypted.
    unreadable: bool,
    /// The bytes each of its frames begins with, left out of them: where
    /// they lie in the index, and how many.
    strip: ?[*]const u8,
    strip_length: u32,
    /// A frame with them put back, in memory of its own.
    joined: ?[*]u8,
    joined_size: u32,
    /// A setup made for the track's codec, where the file has none or
    /// one of another form.
    made: [32]u8,
    walk: Walk,
};

pub const Walk = struct {
    /// Where the next element lies; whether it lies in a cluster, where
    /// the cluster's body ends - `ebml.unknown` for one of a size not
    /// known - and its time in ticks.
    at: u64,
    in_cluster: bool,
    cluster_end: u64,
    cluster_time: u64,
    /// The block being handed out: its frames, the next of them and where
    /// it lies in the file; their sizes; its time in nanoseconds, whether
    /// a decoder can start at it, how long each frame lasts.
    frames: u32,
    next: u32,
    frame_at: u64,
    sizes: [max_frames]u32,
    time_ns: i64,
    key: bool,
    each_ns: u64,
    /// Packets handed out since the track last moved.
    index: u32,
};

const Error = error{ End, Read, NoMemory, Corrupt, NoSeek };

fn code(err: Error) i32 {
    return switch (err) {
        error.End => media.MERR_END,
        error.NoSeek => media.MERR_NOSEEK,
        error.Read => media.MERR_READ,
        error.NoMemory => media.MERR_NOMEMORY,
        error.Corrupt => media.MERR_CORRUPT,
    };
}

/// The walk set at the first cluster, as the file was opened.
pub fn rewind(file: *_file.File, track: *_file.Track) void {
    const w = &track.mkv.walk;
    w.at = file.mkv.first_cluster;
    w.in_cluster = false;
    w.frames = 0;
    w.next = 0;
    w.index = 0;
}

// --- reading ----------------------------------------------------------------------

/// At least `need` bytes of the file from `offset` in the track's buffer,
/// and as many after them as it holds: there already, or read in a run
/// from `offset` on - what the buffer held of the run kept, moved to its
/// front, so a read function's bytes are read once.
fn bytesAt(file: *_file.File, track: *_file.Track, offset: u64, need: usize) Error![]const u8 {
    if (track.buffer) |buffer| {
        if (offset >= track.cached_at and offset + need <= track.cached_at + track.cached) {
            return buffer[@intCast(offset - track.cached_at)..track.cached];
        }
    }
    if (need > max_block) return error.Corrupt;
    const sys = file.base.sys_base;
    var keep: usize = 0;
    var from: ?[*]u8 = null;
    if (track.buffer) |buffer| {
        if (offset >= track.cached_at and offset < track.cached_at + track.cached) {
            keep = @intCast(track.cached_at + track.cached - offset);
            from = buffer + @as(usize, @intCast(offset - track.cached_at));
        }
    }
    if (_file.behind(file, offset + keep)) return error.NoSeek;
    if (track.buffer == null or need > track.buffer_size) {
        const room: u32 = @intCast(@max(min_run, need + min_run / 4));
        const memory = sys.AllocVec(room, exec.MEMF_ANY) orelse return error.NoMemory;
        const fresh: [*]u8 = @ptrCast(memory);
        if (keep != 0) @memcpy(fresh[0..keep], from.?[0..keep]);
        if (track.buffer) |old| sys.FreeVec(old);
        track.buffer = fresh;
        track.buffer_size = room;
    } else if (keep != 0) {
        std.mem.copyForwards(u8, track.buffer.?[0..keep], from.?[0..keep]);
    }
    var want: u64 = track.buffer_size;
    if (file.size != 0) want = @max(@min(want, file.size -| offset), keep);
    track.cached_at = offset;
    track.cached = @intCast(keep);
    if (want > keep) {
        sys.ObtainSemaphore(&file.lock);
        const got = _file.readSome(file, offset + keep, track.buffer.?[keep..@intCast(want)]);
        sys.ReleaseSemaphore(&file.lock);
        track.cached += @intCast(got);
    }
    if (track.cached < need) {
        const ends = file.size == 0 or offset + need > file.size;
        return if (ends) error.End else error.Read;
    }
    return track.buffer.?[0..track.cached];
}

/// The head of the element at `at`.
fn headAt(file: *_file.File, track: *_file.Track, at: u64) Error!ebml.Head {
    var want: u64 = ebml.max_head;
    if (file.size != 0) want = @min(want, file.size -| at);
    if (want < 2) return error.End;
    const bytes = try bytesAt(file, track, at, @intCast(want));
    return ebml.head(bytes[0..@min(bytes.len, ebml.max_head)]) orelse error.Corrupt;
}

/// A block of the track, as the walk came upon it.
const Found = struct {
    /// Where its element begins, and the walk's cluster then.
    at: u64,
    cluster_end: u64,
    cluster_time: u64,
    time_ns: i64,
    key: bool,
};

/// The walk on to the track's next block, and past it: where it lies, its
/// time, whether a decoder can start at it. With `load` its frames are
/// made ready to hand out.
fn nextBlock(file: *_file.File, track: *_file.Track, load: bool) Error!Found {
    const w = &track.mkv.walk;
    const m = &file.mkv;
    while (true) {
        if (w.in_cluster and w.cluster_end != ebml.unknown and w.at >= w.cluster_end) w.in_cluster = false;
        if (w.at >= m.segment_end) return error.End;
        const h = try headAt(file, track, w.at);
        const body = w.at + h.length;
        if (!w.in_cluster or ebml.topLevel(h.id)) {
            // Between clusters, or past the end of one of a size not known.
            w.in_cluster = false;
            if (h.id == ebml.Cluster) {
                w.in_cluster = true;
                w.cluster_end = if (h.size == ebml.unknown) ebml.unknown else body + h.size;
                w.cluster_time = 0;
                w.at = body;
                continue;
            }
            if (h.size == ebml.unknown) return error.End;
            w.at = body + h.size;
            continue;
        }
        if (h.size == ebml.unknown) return error.Corrupt;
        const after = body + h.size;
        switch (h.id) {
            ebml.Timestamp => {
                const length: usize = @intCast(@min(h.size, 8));
                const bytes = try bytesAt(file, track, body, length);
                w.cluster_time = ebml.uint(bytes[0..length]);
            },
            ebml.SimpleBlock, ebml.BlockGroup => {
                const found = try block(file, track, w.at, h, load);
                w.at = after;
                if (found) |own| return own;
                continue;
            },
            else => {},
        }
        w.at = after;
    }
}

/// A block's element: null when it is another track's. Its frames' sizes
/// are read with `load`, and its bytes are then whole in the buffer.
fn block(file: *_file.File, track: *_file.Track, at: u64, h: ebml.Head, load: bool) Error!?Found {
    const own = &track.mkv;
    const w = &own.walk;
    const body = at + h.length;
    const group = h.id == ebml.BlockGroup;
    // Enough to name the track: a Block's head first in a group, then the
    // block's own head - its track, its time, its flags.
    const most: u64 = if (group) ebml.max_head + 11 else 11;
    const peek: usize = @intCast(@min(h.size, most));
    var bytes = try bytesAt(file, track, body, peek);
    var data_at = body;
    var data: []const u8 = bytes[0..peek];
    if (group) {
        const inner = ebml.head(data) orelse return error.Corrupt;
        if (inner.id != ebml.Block) {
            // A group that does not begin with its Block: read whole.
            bytes = try bytesAt(file, track, body, @intCast(h.size));
            data = ebml.child(bytes[0..@intCast(h.size)], ebml.Block) orelse return null;
            data_at = body + (@intFromPtr(data.ptr) - @intFromPtr(bytes.ptr));
        } else {
            data_at = body + inner.length;
            data = data[inner.length..];
        }
    }
    var cursor: usize = 0;
    const number = ebml.number(data, &cursor) orelse return error.Corrupt;
    if (number != own.number) return null;
    if (cursor + 3 > data.len) return error.Corrupt;
    const relative: i16 = @bitCast(@as(u16, data[cursor]) << 8 | data[cursor + 1]);
    const flags = data[cursor + 2];
    const head_length = cursor + 3;

    var key = flags & 0x80 != 0;
    var duration: ?u64 = null;
    var data_length: usize = 0;
    if (group) {
        // What is said of the block: how long it lasts, and the blocks it
        // needs - none for a key frame.
        bytes = try bytesAt(file, track, body, @intCast(h.size));
        var elements = ebml.Elements{ .rest = bytes[0..@intCast(h.size)] };
        key = true;
        while (elements.next()) |element| switch (element.id) {
            ebml.Block => data_length = element.body.len,
            ebml.BlockDuration => duration = ebml.uint(element.body),
            ebml.ReferenceBlock => key = false,
            else => {},
        };
    } else {
        data_length = @intCast(h.size);
    }
    if (track.info.kind != media.MTRACK_VIDEO) key = true;
    const m = &file.mkv;
    const found = Found{
        .at = at,
        .cluster_end = w.cluster_end,
        .cluster_time = w.cluster_time,
        .time_ns = nanos(m, w.cluster_time, relative),
        .key = key,
    };
    if (!load) return found;

    if (data_length < head_length) return error.Corrupt;
    const all = try bytesAt(file, track, data_at, data_length);
    try lace(w, all[head_length..data_length], (flags >> 1) & 3);
    w.frame_at = data_at + head_length + w.frame_at;
    w.next = 0;
    w.time_ns = found.time_ns;
    w.key = key;
    w.each_ns = own.frame_ns;
    if (duration) |ticks| w.each_ns = @min(ticks, max_ticks) * m.scale / w.frames;
    return found;
}

/// Nanoseconds in ticks of `timescale`, rounded down.
pub fn ticksOf(ns: u64, timescale: u32) u64 {
    return @intCast(@as(u128, ns) * timescale / 1_000_000_000);
}

/// A time of `ticks` and `relative` more, in nanoseconds.
fn nanos(m: *const File, ticks: u64, relative: i64) i64 {
    const sum = @as(i64, @intCast(@min(ticks, max_ticks))) + relative;
    return sum *| @as(i64, @intCast(m.scale));
}

/// A block's frames: their sizes, and where the first lies from the
/// start of `data` (in `frame_at`).
fn lace(w: *Walk, data: []const u8, lacing: u8) Error!void {
    if (lacing == 0) {
        w.frames = 1;
        w.sizes[0] = @intCast(data.len);
        w.frame_at = 0;
        return;
    }
    if (data.len == 0) return error.Corrupt;
    const count: usize = @as(usize, data[0]) + 1;
    var at: usize = 1;
    var total: u64 = 0;
    switch (lacing) {
        // Xiph's: each size but the last in bytes of 255 and the byte that
        // ends it.
        1 => for (0..count - 1) |n| {
            var size: u64 = 0;
            while (true) {
                if (at >= data.len) return error.Corrupt;
                const byte = data[at];
                at += 1;
                size += byte;
                if (byte != 255) break;
            }
            w.sizes[n] = @intCast(@min(size, max_block));
            total += size;
        },
        // EBML's: the first size, then each the one before and a
        // difference.
        3 => {
            var size: i64 = @intCast(ebml.number(data, &at) orelse return error.Corrupt);
            for (0..count - 1) |n| {
                if (n != 0) size += ebml.signedNumber(data, &at) orelse return error.Corrupt;
                if (size < 0 or size > max_block) return error.Corrupt;
                w.sizes[n] = @intCast(size);
                total += @intCast(size);
            }
        },
        // All of a size.
        else => {
            if ((data.len - 1) % count != 0) return error.Corrupt;
            const each: u32 = @intCast((data.len - 1) / count);
            for (0..count - 1) |n| w.sizes[n] = each;
            total = @as(u64, each) * (count - 1);
        },
    }
    if (at + total > data.len) return error.Corrupt;
    w.sizes[count - 1] = @intCast(data.len - at - total);
    w.frames = @intCast(count);
    w.frame_at = at;
}

/// The track's next packet into `packet`.
pub fn read(file: *_file.File, track: *_file.Track, packet: *media.MediaPacket) i32 {
    const own = &track.mkv;
    const w = &own.walk;
    if (own.unreadable) return media.MERR_UNSUPPORTED;
    if (w.next >= w.frames) {
        w.frames = 0;
        w.next = 0;
        _ = nextBlock(file, track, true) catch |err| return code(err);
    }
    const n = w.next;
    const size = w.sizes[n];
    var data: [*]const u8 = track.buffer.? + @as(usize, @intCast(w.frame_at - track.cached_at));
    var length = size;
    if (own.strip_length != 0) {
        data = join(file, own, data[0..size]) orelse return media.MERR_NOMEMORY;
        length += own.strip_length;
    }
    const time_ns = w.time_ns + @as(i64, @intCast(w.each_ns * n));
    const shown_us = @divFloor(time_ns - @as(i64, @intCast(own.delay_ns)), 1000);
    packet.* = .{
        .data = data,
        .size = length,
        .flags = if (w.key) media.MPKT_KEY else 0,
        .pts = shown_us,
        .dts = shown_us,
        .duration = @intCast(@min(w.each_ns / 1000, std.math.maxInt(u32))),
        .index = w.index,
        .ticks = ticksOf(@intCast(@max(0, time_ns)), track.info.timescale),
    };
    w.frame_at += size;
    w.next += 1;
    w.index += 1;
    return media.MERR_OK;
}

/// A frame with the bytes left out of it put back, in the track's second
/// buffer.
fn join(file: *_file.File, own: *Track, frame: []const u8) ?[*]const u8 {
    const total = own.strip_length + frame.len;
    if (own.joined == null or total > own.joined_size) {
        const sys = file.base.sys_base;
        if (own.joined) |old| sys.FreeVec(old);
        own.joined = null;
        const room: u32 = @intCast(@max(total, 64 * 1024));
        own.joined = @ptrCast(sys.AllocVec(room, exec.MEMF_ANY) orelse return null);
        own.joined_size = room;
    }
    const into = own.joined.?;
    @memcpy(into[0..own.strip_length], own.strip.?[0..own.strip_length]);
    @memcpy(into[own.strip_length..][0..frame.len], frame);
    return into;
}

// --- moving -----------------------------------------------------------------------

/// The track moved to its packet a decoder can start at, at or before
/// `time` microseconds of what is presented - the codec's delay later in
/// the blocks' times.
pub fn seek(file: *_file.File, track: *_file.Track, time: i64) i32 {
    if (!_file.seekable(file)) return media.MERR_NOSEEK;
    const own = &track.mkv;
    const w = &own.walk;
    const m = &file.mkv;
    const target_ns: i64 = @max(0, (time *| 1000) +| @as(i64, @intCast(own.delay_ns)));
    const target: u64 = @intCast(@divFloor(target_ns, @as(i64, @intCast(m.scale))));

    // The cue to start at: the track's own where it has any.
    const cues: []const Cue = if (m.cues) |list| list[0..m.cue_count] else &.{};
    var own_cues = false;
    for (cues) |cue| {
        if (cue.track == own.number) {
            own_cues = true;
            break;
        }
    }
    var start: ?Cue = null;
    for (cues) |cue| {
        if (own_cues and cue.track != own.number) continue;
        if (cue.time > target) continue;
        if (start == null or cue.time >= start.?.time) start = cue;
    }

    w.frames = 0;
    w.next = 0;
    w.in_cluster = false;
    w.at = m.first_cluster;
    // Pictures start at their cue's key frame. Sound, a decoder can start
    // at any block of, walks on from it to the last block before the time:
    // a cluster of sound lasts seconds, and its blocks are small.
    const sound = track.info.kind == media.MTRACK_AUDIO;
    var cue_ns: ?i64 = null;
    if (start) |cue| {
        const cluster = m.segment_at + cue.cluster;
        w.at = cluster;
        if (own_cues) {
            if (!sound) cue_ns = nanos(m, cue.time, 0);
            if (cue.relative != no_relative) {
                if (clusterAt(file, cluster)) |place| {
                    w.in_cluster = true;
                    w.cluster_end = place.end;
                    w.cluster_time = place.time;
                    w.at = place.body + cue.relative;
                    w.index = indexAt(own, nanos(m, cue.time, 0));
                    if (!sound) return media.MERR_OK;
                }
            }
        }
    }

    // On to the last block at or before the time that a decoder can start
    // at - with cues of its own, the one the cue named.
    var best: ?Found = null;
    while (true) {
        const found = nextBlock(file, track, false) catch |err| switch (err) {
            error.End => break,
            else => return code(err),
        };
        if (found.time_ns > target_ns and best != null) break;
        if (!found.key) continue;
        best = found;
        if (found.time_ns >= target_ns) break;
        if (cue_ns) |at| {
            if (found.time_ns >= at) break;
        }
    }
    if (best) |found| {
        w.at = found.at;
        w.in_cluster = true;
        w.cluster_end = found.cluster_end;
        w.cluster_time = found.cluster_time;
        w.index = indexAt(own, found.time_ns);
    } else {
        w.at = m.segment_end;
    }
    w.frames = 0;
    w.next = 0;
    return media.MERR_OK;
}

/// The packet's number at a time, from the track's frames a second.
fn indexAt(own: *const Track, time_ns: i64) u32 {
    if (own.frame_ns == 0 or time_ns <= 0) return 0;
    return @intCast(@min(@as(u64, @intCast(time_ns)) / own.frame_ns, std.math.maxInt(u32)));
}

const Place = struct {
    body: u64,
    end: u64,
    time: u64,
};

/// The cluster at `at`: where its body begins and ends, and its time -
/// read from its first elements, past a CRC or a void.
fn clusterAt(file: *_file.File, at: u64) ?Place {
    var bytes: [64]u8 = undefined;
    const sys = file.base.sys_base;
    sys.ObtainSemaphore(&file.lock);
    const got = _file.readSome(file, at, &bytes);
    sys.ReleaseSemaphore(&file.lock);
    const h = ebml.head(bytes[0..got]) orelse return null;
    if (h.id != ebml.Cluster) return null;
    const body = at + h.length;
    var elements = ebml.Elements{ .rest = bytes[h.length..got] };
    while (elements.next()) |element| {
        switch (element.id) {
            ebml.Timestamp => return .{
                .body = body,
                .end = if (h.size == ebml.unknown) ebml.unknown else body + h.size,
                .time = ebml.uint(element.body),
            },
            ebml.CRC32, ebml.Void => {},
            else => return null,
        }
    }
    return null;
}
