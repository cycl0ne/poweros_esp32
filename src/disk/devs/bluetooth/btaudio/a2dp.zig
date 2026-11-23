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
//! gone, counts in the timestamp alone: the sink hears the gap.

pub const sbc = @import("sbc.zig");
pub const signalling = @import("signalling.zig");
pub const source = @import("source.zig");
pub const Source = source.Source;

/// The longest packet made, whatever the channel takes.
pub const packet_most = 2048;
/// The most samples a packet takes: 15 frames of 16 blocks of 8 subbands,
/// two channels.
pub const pcm_most = 15 * 16 * 8 * 2;

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
        return media.frames > 0;
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

// --- tests -------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test {
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
