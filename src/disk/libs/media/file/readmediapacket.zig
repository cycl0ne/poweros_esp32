// SPDX-License-Identifier: MIT
//! ReadMediaPacket: a track's next packet.

const sdk = @import("sdk");
const exec = sdk.exec;
const media = sdk.media;
const MediaBase = @import("../media_base.zig").MediaBase;
const _file = @import("_file.zig");
const File = _file.File;
const Track = _file.Track;
const cursor = @import("../mp4/cursor.zig");
const blocks = @import("../mkv/blocks.zig");

/// Hands out a track's next packet, as it is coded.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadMediaPacket(base: *MediaBase, file: *media.MediaFile, track: u32, packet: *media.MediaPacket) i32
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `file`: an open file.
/// - `track`: which track, as GetMediaTrack numbers them.
/// - `packet`: where it goes.
///
/// RESULT:
/// MERR_OK; MERR_END after the track's last packet; MERR_NOTRACK,
/// MERR_READ, MERR_NOMEMORY, MERR_CORRUPT, MERR_NOSEEK for a packet
/// behind what a read function has read, or MERR_UNSUPPORTED for a
/// Matroska track compressed or encrypted. Only with MERR_OK is `packet`
/// filled in.
///
/// BEHAVIOR:
/// The packet the track's cursor is at - its first after OpenMedia, the
/// one a seek found after SeekMedia - and the cursor on to the next, in
/// the order they are decoded. Its bytes, its size, whether a decoder can
/// start at it (MPKT_KEY), when it is due and when it is decoded in
/// microseconds from the start of what the file presents - below 0 for
/// priming - how long it lasts, its number in the track, and its decode
/// time in the track's own ticks. The bytes are read with the rest of
/// their chunk, as far as the track's buffer holds them, so the packets
/// after it come out of the buffer.
///
/// A Matroska track walks the clusters from where it is to its next
/// block, past the other tracks', reading the file in runs into its
/// buffer; the frames of a block laced are handed out one at a time, the
/// time of each after the first from how long the track says a frame
/// lasts (SINCE 1.2).
///
/// CONTEXT:
/// - Waits: yes, on the file, and while another task reads another track
///   of it.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process for a file; a task will do with MDA_ReadFunc.
///
/// OWNERSHIP:
/// The bytes are the library's, good until the next ReadMediaPacket or
/// SeekMedia on the same track, or CloseMedia.
///
/// NOTES:
/// Two tasks may each read a track of their own at once - the sound and
/// the picture of a film; the file is read by one of them at a time. One
/// track is read by one task at a time.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SeekMedia`, `GetMediaTrack`
///
/// EXAMPLES:
/// ```zig
/// var packet: media.MediaPacket = .{};
/// while (mb.ReadMediaPacket(film, info.video, &packet) == media.MERR_OK) {
///     decode(packet.data.?[0..packet.size], packet.pts);
/// }
/// ```
pub fn ReadMediaPacket(_: *MediaBase, file: *media.MediaFile, track: u32, packet: *media.MediaPacket) i32 {
    const own = _file.fileOf(file);
    if (track >= own.track_count) return media.MERR_NOTRACK;
    const t = &own.tracks[track];
    if (own.info.kind == media.MEDIA_MKV) return blocks.read(own, t, packet);
    const tables = &t.tables;
    const at = &t.at;
    if (at.sample >= tables.samples) return media.MERR_END;
    const size = tables.sizeOf(at.sample);
    const result = bytesOf(own, t, at.offset, size);
    if (result != media.MERR_OK) return result;

    const timescale = t.info.timescale;
    const dts: i64 = @intCast(at.dts);
    packet.* = .{
        .data = t.buffer.? + @as(usize, @intCast(at.offset - t.cached_at)),
        .size = size,
        .flags = if (cursor.isKey(tables, at)) media.MPKT_KEY else 0,
        .pts = _file.micros(dts + cursor.showOffset(tables, at) - t.media_start, timescale) + t.empty_us,
        .dts = _file.micros(dts - t.media_start, timescale) + t.empty_us,
        .duration = @intCast(@min(_file.micros(cursor.duration(tables, at), timescale), ~@as(u32, 0))),
        .index = at.sample,
        .ticks = at.dts,
    };
    cursor.step(tables, at, size);
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
    const tables = &track.tables;
    var want: u64 = size;
    var next = track.at.sample + 1;
    var left = track.at.chunk_samples -| (track.at.in_chunk + 1);
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
    var read = _file.readAt(file, offset, track.buffer.?[0..@intCast(want)]);
    if (!read and want > size and _file.seekable(file)) {
        got = size;
        read = _file.readAt(file, offset, track.buffer.?[0..size]);
    }
    sys.ReleaseSemaphore(&file.lock);
    if (!read) {
        track.cached = 0;
        return media.MERR_READ;
    }
    track.cached_at = offset;
    track.cached = @intCast(got);
    return media.MERR_OK;
}
