// SPDX-License-Identifier: MIT
//! An MP4 track's packets: read from where its sample tables say they lie,
//! each with the rest of its chunk where the buffer has room, and the
//! cursor moved for a seek.

const sdk = @import("sdk");
const exec = sdk.exec;
const media = sdk.media;
const _file = @import("../file/_file.zig");
const File = _file.File;
const Track = _file.Track;
const cursor = @import("cursor.zig");
const mp4 = @import("_mp4.zig");

/// The track's next packet into `packet`.
pub fn read(file: *File, t: *Track, packet: *media.MediaPacket) i32 {
    const own = mp4.own(t);
    const tables = &own.tables;
    const at = &own.at;
    if (at.sample >= tables.samples) return media.MERR_END;
    const size = tables.sizeOf(at.sample);
    const result = bytesOf(file, t, at.offset, size);
    if (result != media.MERR_OK) return result;

    const timescale = t.info.timescale;
    const dts: i64 = @intCast(at.dts);
    packet.* = .{
        .data = t.buffer.? + @as(usize, @intCast(at.offset - t.cached_at)),
        .size = size,
        .flags = if (cursor.isKey(tables, at)) media.MPKT_KEY else 0,
        .pts = _file.micros(dts + cursor.showOffset(tables, at) - own.media_start, timescale) + own.empty_us,
        .dts = _file.micros(dts - own.media_start, timescale) + own.empty_us,
        .duration = @intCast(@min(_file.micros(cursor.duration(tables, at), timescale), ~@as(u32, 0))),
        .index = at.sample,
        .ticks = at.dts,
    };
    cursor.step(tables, at, size);
    return media.MERR_OK;
}

/// The track at the key packet at or before `time`.
pub fn seek(_: *File, t: *Track, time: i64) i32 {
    const own = mp4.own(t);
    const ticks = _file.ticksOf(time - own.empty_us, t.info.timescale) + own.media_start;
    const sample = cursor.sampleAt(&own.tables, @intCast(@max(ticks, 0)));
    cursor.moveTo(&own.tables, &own.at, own.tables.keyAtOrBefore(sample));
    return media.MERR_OK;
}

/// The packet's `size` bytes at `offset` in the track's buffer: there
/// already, or read with as much of the rest of its chunk as the buffer
/// holds.
fn bytesOf(file: *File, track: *Track, offset: u64, size: u32) i32 {
    if (track.buffer != null and offset >= track.cached_at and offset + size <= track.cached_at + track.cached) return media.MERR_OK;
    const sys = file.base.sys_base;
    if (track.buffer == null or size > track.buffer_size) {
        if (track.buffer) |old| sys.FreeVec(old);
        track.buffer = null;
        track.cached = 0;
        const room: u32 = @max(_file.min_buffer, track.info.max_packet, size);
        const memory = sys.AllocVec(room, exec.MEMF_ANY) orelse return media.MERR_NOMEMORY;
        track.buffer = @ptrCast(memory);
        track.buffer_size = room;
    }
    if (!_file.seekable(file) and offset < file.position) return media.MERR_NOSEEK;

    // The rest of the chunk: the samples after this one in it lie right
    // behind it.
    const own = mp4.own(track);
    const tables = &own.tables;
    var want: u64 = size;
    var next = own.at.sample + 1;
    var left = own.at.chunk_samples -| (own.at.in_chunk + 1);
    while (left > 0 and next < tables.samples) : ({
        left -= 1;
        next += 1;
    }) {
        const more = tables.sizeOf(next);
        if (want + more > track.buffer_size) break;
        want += more;
    }
    if (file.size != 0 and offset + want > file.size) want = @max(size, file.size -| offset);

    // A chunk the file ends inside of: the packet alone, then.
    sys.ObtainSemaphore(&file.lock);
    var got = want;
    var whole = _file.readAt(file, offset, track.buffer.?[0..@intCast(want)]);
    if (!whole and want > size and _file.seekable(file)) {
        got = size;
        whole = _file.readAt(file, offset, track.buffer.?[0..size]);
    }
    sys.ReleaseSemaphore(&file.lock);
    if (!whole) {
        track.cached = 0;
        return media.MERR_READ;
    }
    track.cached_at = offset;
    track.cached = @intCast(got);
    return media.MERR_OK;
}
