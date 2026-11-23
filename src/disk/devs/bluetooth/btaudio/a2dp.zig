// SPDX-License-Identifier: MIT
//! Sound sent to a Bluetooth headphone or speaker: SBC (sbc.zig), AVDTP's
//! messages (signalling.zig), the stream's signalling as this machine,
//! the source, drives it (source.zig), and the media channel's packets
//! (`Media`). Built by name into the programs that import it - a2dp -
//! C:test/BTAudio and btaudio.device; the owner opens the channels and
//! sends what these make.
//!
//! **A media packet** is RTP's header - its sequence number counting the
//! packets sent, its timestamp the samples sent before its first - the
//! byte that counts its frames, and as many SBC frames as the media
//! channel's MTU takes, 15 at the most. A packet let go of, its time
//! gone, counts in the timestamp alone: the sink hears the gap. The
//! samples of a packet are handed over whole (`packetOf`), or gathered
//! from buffers of 16-bit stereo of any length (`gather`), the two
//! sides' mean where the stream is mono.
//!
//! **Between two tasks** sound goes in a `Ring` of buffers, one task
//! writing them, the other reading: each side moves its own count alone,
//! so neither waits for the other, and a writer that finds every buffer
//! waiting to be read lets its own go. `silent` says whether a buffer is
//! silence, as the owner starts and suspends a stream by it.

pub const sbc = @import("sbc.zig");
pub const signalling = @import("signalling.zig");
pub const source = @import("source.zig");
pub const Source = source.Source;

/// The longest packet made, whatever the channel takes.
pub const packet_most = 2048;
/// The most samples a packet takes: 15 frames of 16 blocks of 8 subbands,
/// two channels.
pub const pcm_most = 15 * 16 * 8 * 2;

/// The level at or below which a sample is silence: about -66 dBFS, the
/// dither of a sound that has ended.
pub const silence_level = 16;

/// The packets of a stream, made one after another.
pub const Media = struct {
    encoder: sbc.Encoder = undefined,
    config: sbc.Config = .{},
    frame_length: usize = 0,
    /// The frames a packet holds, and the samples of each channel in them.
    frames: usize = 0,
    samples: usize = 0,
    sequence: u16 = 0,
    timestamp: u32 = 0,
    packet: [packet_most]u8 = undefined,
    /// The samples gathered for the next packet, of each channel, and the
    /// samples themselves.
    gathered: usize = 0,
    pcm: [pcm_most]i16 = undefined,

    /// Packets of `config`'s frames, for a channel that takes `mtu`
    /// bytes: false where not one frame fits.
    pub fn init(media: *Media, config: sbc.Config, mtu: usize) bool {
        media.encoder = sbc.Encoder.init(config);
        media.config = config;
        media.frame_length = sbc.frameLength(config);
        media.frames = signalling.framesPerPacket(@min(mtu, packet_most), media.frame_length);
        media.samples = media.frames * sbc.samplesPerFrame(config);
        media.sequence = 0;
        media.timestamp = 0;
        media.gathered = 0;
        return media.frames > 0;
    }

    /// Frames of 16-bit stereo, the left side first, gathered for the
    /// next packet - as many as it still takes, the two sides' mean
    /// where the stream is mono: the frames taken.
    pub fn gather(media: *Media, stereo: []const i16) usize {
        const frames = @min(media.samples - media.gathered, stereo.len / 2);
        const sides = media.channels();
        for (0..frames) |index| {
            const left = stereo[index * 2];
            const right = stereo[index * 2 + 1];
            const at = (media.gathered + index) * sides;
            if (sides == 2) {
                media.pcm[at] = left;
                media.pcm[at + 1] = right;
            } else {
                media.pcm[at] = @intCast((@as(i32, left) + right) >> 1);
            }
        }
        media.gathered += frames;
        return frames;
    }

    /// Whether the next packet's samples are all gathered.
    pub fn full(media: *const Media) bool {
        return media.samples != 0 and media.gathered == media.samples;
    }

    /// The packet of the samples gathered, which begin again.
    pub fn packetGathered(media: *Media) []const u8 {
        media.gathered = 0;
        return media.packetOf(media.pcm[0 .. media.samples * media.channels()]);
    }

    /// The channels of a packet's samples.
    pub fn channels(media: *const Media) usize {
        return sbc.channelsOf(media.config.mode);
    }

    /// The next packet: `pcm` - `samples` samples of each channel,
    /// interleaved - encoded behind its header.
    pub fn packetOf(media: *Media, pcm: []const i16) []const u8 {
        signalling.mediaHeader(media.packet[0..signalling.media_header], media.sequence, media.timestamp, media.frames);
        const per_frame = sbc.samplesPerFrame(media.config) * media.channels();
        var at: usize = signalling.media_header;
        for (0..media.frames) |index| {
            at += media.encoder.encode(pcm[index * per_frame ..][0..per_frame], media.packet[at..]);
        }
        media.sequence +%= 1;
        media.timestamp +%= @intCast(media.samples);
        return media.packet[0..at];
    }

    /// A packet let go of: its samples counted, nothing sent.
    pub fn skip(media: *Media) void {
        media.timestamp +%= @intCast(media.samples);
    }

    /// The bits a second the stream takes, its headers left out.
    pub fn bitrate(media: *const Media) u32 {
        const bits: u64 = @as(u64, media.frame_length) * 8 * media.config.rate;
        return @intCast(bits / sbc.samplesPerFrame(media.config));
    }
};

/// Whether every sample of `pcm` is silence (`silence_level`).
pub fn silent(pcm: []const i16) bool {
    for (pcm) |sample| {
        if (sample > silence_level or sample < -silence_level) return false;
    }
    return true;
}

/// `slots` buffers of `samples` samples handed from one task to another:
/// the writer takes `toWrite`'s buffer and says `wrote`, the reader takes
/// `toRead`'s and says `done`. The two counts only grow, wrapping - the
/// buffers waiting are the one less the other - and each is moved by its
/// own side alone, so neither waits. `slots` is a power of two, so a
/// count's wrap falls on a buffer's bound.
pub fn Ring(comptime slots: u32, comptime samples: usize) type {
    if (slots == 0 or slots & (slots - 1) != 0) @compileError("a ring's slots are a power of two");
    return struct {
        const Self = @This();

        /// The buffers written, and those read or let go of.
        written: u32 = 0,
        read: u32 = 0,
        data: [slots][samples]i16 = undefined,

        /// The writer's next buffer; null where every one waits to be
        /// read.
        pub fn toWrite(ring: *Self) ?*[samples]i16 {
            const read = @atomicLoad(u32, &ring.read, .acquire);
            if (ring.written -% read >= slots) return null;
            return &ring.data[ring.written % slots];
        }

        /// The buffer `toWrite` gave written: the reader's from now on.
        pub fn wrote(ring: *Self) void {
            @atomicStore(u32, &ring.written, ring.written +% 1, .release);
        }

        /// The buffers waiting to be read.
        pub fn waiting(ring: *Self) u32 {
            return @atomicLoad(u32, &ring.written, .acquire) -% ring.read;
        }

        /// The oldest buffer waiting; null for none.
        pub fn toRead(ring: *Self) ?*const [samples]i16 {
            if (ring.waiting() == 0) return null;
            return &ring.data[ring.read % slots];
        }

        /// The oldest buffer read, or let go of.
        pub fn done(ring: *Self) void {
            @atomicStore(u32, &ring.read, ring.read +% 1, .release);
        }

        /// Every buffer waiting let go of.
        pub fn empty(ring: *Self) void {
            @atomicStore(u32, &ring.read, @atomicLoad(u32, &ring.written, .acquire), .release);
        }
    };
}

// --- tests -------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test {
    _ = sbc;
    _ = signalling;
    _ = source;
}

test "media packets: as many frames as the channel takes, counted in the header, a skipped one in the timestamp" {
    const media = try testing.allocator.create(Media);
    defer testing.allocator.destroy(media);
    media.* = .{};
    try testing.expect(media.init(.{}, 895));
    try testing.expectEqual(@as(usize, 7), media.frames);
    try testing.expectEqual(@as(usize, 896), media.samples);
    try testing.expectEqual(@as(u32, 357000), media.bitrate());
    var pcm: [pcm_most]i16 = @splat(0);
    for (0..media.samples) |at| {
        pcm[at * 2] = @intCast(@as(i32, @intCast(at % 64)) * 100 - 3200);
        pcm[at * 2 + 1] = -pcm[at * 2];
    }
    var packet = media.packetOf(pcm[0 .. media.samples * 2]);
    try testing.expectEqual(@as(usize, 13 + 7 * 119), packet.len);
    try testing.expectEqualSlices(u8, &.{ 0x80, 96, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 7 }, packet[0..13]);
    for (0..7) |frame| try testing.expectEqual(sbc.SYNCWORD, packet[13 + frame * 119]);
    packet = media.packetOf(pcm[0 .. media.samples * 2]);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 0, 0, 0x03, 0x80 }, packet[2..8]);
    media.skip();
    packet = media.packetOf(pcm[0 .. media.samples * 2]);
    try testing.expectEqualSlices(u8, &.{ 0, 2, 0, 0, 0x0A, 0x80 }, packet[2..8]);
    // A channel of the least MTU, and one too small for a frame.
    try testing.expect(media.init(.{}, 672));
    try testing.expectEqual(@as(usize, 5), media.frames);
    try testing.expect(!media.init(.{}, 120));
    // Mono at 31: frames of 70 bytes, 15 to a packet whatever the MTU.
    try testing.expect(media.init(.{ .mode = .mono, .bitpool = 31 }, 4096));
    try testing.expectEqual(@as(usize, 15), media.frames);
    try testing.expectEqual(@as(usize, 1), media.channels());
    packet = media.packetOf(pcm[0..media.samples]);
    try testing.expectEqual(@as(usize, 13 + 15 * 70), packet.len);
    // Dual channel at 31 fills the buffer before 15 frames.
    try testing.expect(media.init(.{ .mode = .dual_channel, .bitpool = 31 }, 4096));
    try testing.expectEqual(@as(usize, (packet_most - 13) / sbc.frameLength(.{ .mode = .dual_channel, .bitpool = 31 })), media.frames);
}

test "a packet's samples gathered from buffers of any length, the two sides made one for mono" {
    const media = try testing.allocator.create(Media);
    defer testing.allocator.destroy(media);
    media.* = .{};
    // 7 frames of 128 samples: 896, gathered from buffers of 512 frames.
    try testing.expect(media.init(.{}, 895));
    var buffer: [1024]i16 = undefined;
    for (0..512) |frame| {
        buffer[frame * 2] = @intCast(frame);
        buffer[frame * 2 + 1] = -@as(i16, @intCast(frame));
    }
    try testing.expectEqual(@as(usize, 512), media.gather(&buffer));
    try testing.expect(!media.full());
    try testing.expectEqual(@as(usize, 384), media.gather(&buffer));
    try testing.expect(media.full());
    try testing.expectEqual(@as(i16, 383), media.pcm[895 * 2]);
    try testing.expectEqual(@as(i16, -383), media.pcm[895 * 2 + 1]);
    // Full: nothing more taken until its packet is made.
    try testing.expectEqual(@as(usize, 0), media.gather(buffer[384 * 2 ..]));
    const packet = media.packetGathered();
    try testing.expectEqual(@as(usize, 13 + 7 * 119), packet.len);
    try testing.expectEqual(@as(usize, 0), media.gathered);
    try testing.expectEqual(@as(usize, 128), media.gather(buffer[384 * 2 ..]));
    // Mono: each frame the two sides' mean.
    try testing.expect(media.init(.{ .mode = .mono, .bitpool = 31 }, 4096));
    const sides = [_]i16{ 1000, 3000, -32768, -32768, 32767, 32767, 7, -8 };
    try testing.expectEqual(@as(usize, 4), media.gather(&sides));
    try testing.expectEqualSlices(i16, &.{ 2000, -32768, 32767, -1 }, media.pcm[0..4]);
    // Not set up: nothing taken, never full.
    media.* = .{};
    try testing.expectEqual(@as(usize, 0), media.gather(&buffer));
    try testing.expect(!media.full());
}

test "silence: within the level each side of 0" {
    try testing.expect(silent(&.{ 0, 16, -16, 3 }));
    try testing.expect(!silent(&.{ 0, 17 }));
    try testing.expect(!silent(&.{ -17, 0 }));
    try testing.expect(silent(&.{}));
}

test "a ring: written and read in turn, full, emptied, its counts wrapping" {
    const Small = Ring(4, 2);
    var ring = Small{};
    try testing.expect(ring.toRead() == null);
    for (0..4) |n| {
        const slot = ring.toWrite().?;
        slot.* = .{ @intCast(n), 0 };
        ring.wrote();
    }
    // Every buffer waits: the writer's next is let go of.
    try testing.expect(ring.toWrite() == null);
    try testing.expectEqual(@as(u32, 4), ring.waiting());
    try testing.expectEqual(@as(i16, 0), ring.toRead().?[0]);
    ring.done();
    try testing.expectEqual(@as(i16, 1), ring.toRead().?[0]);
    ring.toWrite().?.* = .{ 4, 0 };
    ring.wrote();
    ring.empty();
    try testing.expect(ring.toRead() == null);
    try testing.expectEqual(@as(u32, 0), ring.waiting());
    // Across the counts' wrap, buffer by buffer.
    ring = .{ .written = 0xFFFF_FFFE, .read = 0xFFFF_FFFE };
    for (0..3) |n| {
        ring.toWrite().?.* = .{ @intCast(10 + n), 0 };
        ring.wrote();
    }
    try testing.expectEqual(@as(u32, 3), ring.waiting());
    for (0..3) |n| {
        try testing.expectEqual(@as(i16, @intCast(10 + n)), ring.toRead().?[0]);
        ring.done();
    }
    try testing.expectEqual(@as(u32, 1), ring.written);
}
