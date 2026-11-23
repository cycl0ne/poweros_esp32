// SPDX-License-Identifier: MIT
//! AVDTP's signalling messages as the sound's source sends and reads
//! them (the numbers are sdk.bluetooth.avdtp's): a message put back
//! together from its packets, a command built, a device's end points and
//! their capabilities read, the configurations to offer a sink picked
//! from its SBC element, and a device's own commands answered.
//!
//! **A message** read is its transaction label, its type - a command, an
//! acceptance, a refusal or a general refusal - its signal and what
//! follows. One that came in packets is put together by `Assembler` in
//! a buffer of its own; one that came whole points into the frame it came
//! in.
//!
//! **The source's end point** is one: `LOCAL_SEID`, audio, SBC at 44.1
//! and 48 kHz in every channel mode, block length and allocation, a
//! bitpool of 2 to 53. `Local` says what a stream is doing with it, for
//! the answers.
//!
//! **A configuration** is offered from a sink's element: `candidate`
//! lists those it takes, best first - the rate the sound is at, or 48
//! kHz and then 44.1; joint stereo, stereo, dual channel and mono in
//! that order; for each the most blocks and subbands it takes, loudness
//! before SNR, and a bitpool of 53 for two channels sharing it and of 31
//! for one, within the sink's least and most. A refused one is followed
//! by the next.
//!
//! **A device's commands** are answered by `answer` - its delay reports
//! kept, a stream it starts, suspends, closes or aborts itself followed -
//! and what they mean for the stream is said as an `Event`. Its own
//! configuration of the end point is refused: the source's stream is
//! made from here.
//!
//! **A media packet** begins with `mediaHeader`: RTP's twelve bytes and
//! the byte that counts the frames; `framesPerPacket` says how many whole
//! frames a channel's packet holds.

const sdk = @import("sdk");
const avdtp = sdk.bluetooth.avdtp;
const sbc = @import("sbc.zig");

/// The source's one stream end point.
pub const LOCAL_SEID: u8 = 1;

/// The longest message put back together from packets: far more than the
/// capabilities a device lists.
pub const message_most = 512;

/// The bitpool offered for two channels that share it, and for one.
const bitpool_two = 53;
const bitpool_one = 31;

/// What the source's end point takes, as SBC's element.
pub const local_element = [4]u8{
    avdtp.A2DP_SBC_44100 | avdtp.A2DP_SBC_48000 | avdtp.A2DP_SBC_MONO | avdtp.A2DP_SBC_DUAL_CHANNEL | avdtp.A2DP_SBC_STEREO | avdtp.A2DP_SBC_JOINT_STEREO,
    avdtp.A2DP_SBC_BLOCKS_4 | avdtp.A2DP_SBC_BLOCKS_8 | avdtp.A2DP_SBC_BLOCKS_12 | avdtp.A2DP_SBC_BLOCKS_16 | avdtp.A2DP_SBC_SUBBANDS_4 | avdtp.A2DP_SBC_SUBBANDS_8 | avdtp.A2DP_SBC_SNR | avdtp.A2DP_SBC_LOUDNESS,
    avdtp.A2DP_SBC_BITPOOL_LEAST,
    bitpool_two,
};

/// A message read: what it is and what follows its signal.
pub const Message = struct {
    label: u4,
    /// AVDTP_COMMAND, AVDTP_ACCEPT, AVDTP_REJECT or AVDTP_GENERAL_REJECT.
    kind: u8,
    signal: u8,
    payload: []const u8,
};

/// A message's first byte.
fn firstByte(label: u4, packet: u8, kind: u8) u8 {
    return @as(u8, label) << 4 | packet << 2 | kind;
}

/// A SEID in its byte, and out of it.
pub fn seidByte(seid: u8) u8 {
    return seid << avdtp.AVDTP_SEID_SHIFT;
}
pub fn seidOf(byte: u8) u8 {
    return byte >> avdtp.AVDTP_SEID_SHIFT;
}

/// Messages put back together from their packets: a single packet read
/// as it is, a start packet's and its continue packets' bytes kept until
/// the end packet. A packet out of its order, or of another label, ends
/// the message it would belong to; one too long for the buffer is let
/// go.
pub const Assembler = struct {
    bytes: [message_most]u8 = undefined,
    length: usize = 0,
    label: u4 = 0,
    kind: u8 = 0,
    signal: u8 = 0,
    /// The packets still to come; 0 while no message is being put
    /// together.
    left: u8 = 0,

    /// A frame of the signalling channel: the message it ends, or null.
    pub fn feed(assembler: *Assembler, frame: []const u8) ?Message {
        if (frame.len == 0) return null;
        const label: u4 = @truncate(frame[0] >> 4);
        const packet = (frame[0] >> 2) & 3;
        const kind = frame[0] & 3;
        switch (packet) {
            avdtp.AVDTP_PACKET_SINGLE => {
                assembler.left = 0;
                if (frame.len < 2) return null;
                return .{ .label = label, .kind = kind, .signal = frame[1] & 0x3F, .payload = frame[2..] };
            },
            avdtp.AVDTP_PACKET_START => {
                assembler.left = 0;
                if (frame.len < 3 or frame[1] < 2) return null;
                assembler.* = .{ .label = label, .kind = kind, .signal = frame[2] & 0x3F, .left = frame[1] - 1 };
                _ = assembler.keep(frame[3..]);
                return null;
            },
            else => {
                if (assembler.left == 0 or label != assembler.label) {
                    assembler.left = 0;
                    return null;
                }
                const last = packet == avdtp.AVDTP_PACKET_END;
                // The end packet comes last of all, and only last.
                if (last != (assembler.left == 1)) {
                    assembler.left = 0;
                    return null;
                }
                if (!assembler.keep(frame[1..])) return null;
                assembler.left -= 1;
                if (!last) return null;
                return .{ .label = assembler.label, .kind = assembler.kind, .signal = assembler.signal, .payload = assembler.bytes[0..assembler.length] };
            },
        }
    }

    /// A packet's bytes kept; false, and the message let go, where they
    /// do not fit.
    fn keep(assembler: *Assembler, part: []const u8) bool {
        if (assembler.length + part.len > assembler.bytes.len) {
            assembler.left = 0;
            return false;
        }
        @memcpy(assembler.bytes[assembler.length..][0..part.len], part);
        assembler.length += part.len;
        return true;
    }
};

/// A command in one packet, into `out`: its bytes.
pub fn command(out: []u8, label: u4, signal: u8, parameters: []const u8) []const u8 {
    return message(out, label, avdtp.AVDTP_COMMAND, signal, parameters);
}

/// A message in one packet, into `out`, which holds it: its bytes.
fn message(out: []u8, label: u4, kind: u8, signal: u8, parameters: []const u8) []const u8 {
    out[0] = firstByte(label, avdtp.AVDTP_PACKET_SINGLE, kind);
    out[1] = signal;
    @memcpy(out[2..][0..parameters.len], parameters);
    return out[0 .. 2 + parameters.len];
}

/// An end point DISCOVER's answer lists.
pub const Endpoint = struct {
    seid: u8,
    in_use: bool,
    /// AVDTP_MEDIA_*.
    media: u8,
    sink: bool,
};

/// The `index`th end point of DISCOVER's answer; null past the last.
pub fn endpoint(payload: []const u8, index: usize) ?Endpoint {
    if (payload.len < (index + 1) * 2) return null;
    const first = payload[index * 2];
    const second = payload[index * 2 + 1];
    return .{
        .seid = seidOf(first),
        .in_use = first & avdtp.AVDTP_IN_USE != 0,
        .media = second >> avdtp.AVDTP_MEDIA_SHIFT,
        .sink = second & avdtp.AVDTP_TSEP_SNK != 0,
    };
}

/// A service capability: its category and what follows its length.
pub const Capability = struct { category: u8, info: []const u8 };

/// The service capabilities of an answer or a configuration, one after
/// another.
pub const Capabilities = struct {
    bytes: []const u8,
    at: usize = 0,
    /// A length ran past the end: what came before it stands.
    broken: bool = false,

    pub fn next(list: *Capabilities) ?Capability {
        if (list.at >= list.bytes.len) return null;
        if (list.at + 2 > list.bytes.len) {
            list.broken = true;
            return null;
        }
        const category = list.bytes[list.at];
        const length: usize = list.bytes[list.at + 1];
        const begin = list.at + 2;
        if (begin + length > list.bytes.len) {
            list.broken = true;
            return null;
        }
        list.at = begin + length;
        return .{ .category = category, .info = list.bytes[begin..list.at] };
    }
};

/// What an end point's capabilities offer the source here.
pub const Offer = struct {
    /// Its SBC element, where its codec is SBC for audio.
    element: ?[4]u8 = null,
    /// The codec it takes otherwise (A2DP_CODEC_*), to say so.
    codec: ?u8 = null,
    media_transport: bool = false,
    delay_reporting: bool = false,
    broken: bool = false,
};

/// An end point's capabilities read.
pub fn offerOf(payload: []const u8) Offer {
    var offer: Offer = .{};
    var list = Capabilities{ .bytes = payload };
    while (list.next()) |capability| {
        switch (capability.category) {
            avdtp.AVDTP_CAT_MEDIA_TRANSPORT => offer.media_transport = true,
            avdtp.AVDTP_CAT_DELAY_REPORTING => offer.delay_reporting = true,
            avdtp.AVDTP_CAT_MEDIA_CODEC => {
                const info = capability.info;
                if (info.len < 2) continue;
                if (info[0] >> avdtp.AVDTP_MEDIA_SHIFT != avdtp.AVDTP_MEDIA_AUDIO) continue;
                if (info[1] == avdtp.A2DP_CODEC_SBC and info.len >= 6) {
                    offer.element = info[2..6].*;
                } else {
                    offer.codec = info[1];
                }
            },
            else => {},
        }
    }
    offer.broken = list.broken;
    return offer;
}

/// A rate's bit in SBC's element.
fn rateBit(rate: u32) u8 {
    return switch (rate) {
        16000 => avdtp.A2DP_SBC_16000,
        32000 => avdtp.A2DP_SBC_32000,
        44100 => avdtp.A2DP_SBC_44100,
        48000 => avdtp.A2DP_SBC_48000,
        else => 0,
    };
}

fn modeBit(mode: sbc.Mode) u8 {
    return switch (mode) {
        .mono => avdtp.A2DP_SBC_MONO,
        .dual_channel => avdtp.A2DP_SBC_DUAL_CHANNEL,
        .stereo => avdtp.A2DP_SBC_STEREO,
        .joint_stereo => avdtp.A2DP_SBC_JOINT_STEREO,
    };
}

fn blocksBit(blocks: u8) u8 {
    return switch (blocks) {
        4 => avdtp.A2DP_SBC_BLOCKS_4,
        8 => avdtp.A2DP_SBC_BLOCKS_8,
        12 => avdtp.A2DP_SBC_BLOCKS_12,
        else => avdtp.A2DP_SBC_BLOCKS_16,
    };
}

/// The `index`th configuration to offer a sink whose element is
/// `element`, best first; `rate` the rate the sound is at, or 0 for 48
/// kHz and then 44.1. Null past the last.
pub fn candidate(element: [4]u8, rate: u32, index: usize) ?sbc.Config {
    const rates: []const u32 = if (rate != 0) &[_]u32{rate} else &[_]u32{ 48000, 44100 };
    const modes = [_]sbc.Mode{ .joint_stereo, .stereo, .dual_channel, .mono };
    var counted: usize = 0;
    for (rates) |each_rate| {
        if (element[0] & rateBit(each_rate) == 0) continue;
        for (modes) |mode| {
            if (element[0] & modeBit(mode) == 0) continue;
            const config = best(element, each_rate, mode) orelse continue;
            if (counted == index) return config;
            counted += 1;
        }
    }
    return null;
}

/// The best configuration a sink's element takes at a rate and a mode;
/// null where it takes no block length, subbands, allocation or bitpool
/// the encoder can make.
fn best(element: [4]u8, rate: u32, mode: sbc.Mode) ?sbc.Config {
    const blocks: u8 = for ([_]u8{ 16, 12, 8, 4 }) |each| {
        if (element[1] & blocksBit(each) != 0) break each;
    } else return null;
    const subbands: u8 = if (element[1] & avdtp.A2DP_SBC_SUBBANDS_8 != 0) 8 else if (element[1] & avdtp.A2DP_SBC_SUBBANDS_4 != 0) 4 else return null;
    const allocation: sbc.Allocation = if (element[1] & avdtp.A2DP_SBC_LOUDNESS != 0) .loudness else if (element[1] & avdtp.A2DP_SBC_SNR != 0) .snr else return null;
    const least = @max(element[2], avdtp.A2DP_SBC_BITPOOL_LEAST);
    const most = element[3];
    if (least > most) return null;
    const wanted: u8 = if (mode == .mono or mode == .dual_channel) bitpool_one else bitpool_two;
    const config = sbc.Config{
        .rate = rate,
        .subbands = subbands,
        .blocks = blocks,
        .mode = mode,
        .allocation = allocation,
        .bitpool = @min(@max(wanted, least), most),
    };
    return if (sbc.valid(config)) config else null;
}

/// A configuration as SBC's element: one bit a field, `least_bitpool` as
/// the least and the configuration's as the most.
pub fn elementOf(config: sbc.Config, least_bitpool: u8) [4]u8 {
    const subbands: u8 = if (config.subbands == 8) avdtp.A2DP_SBC_SUBBANDS_8 else avdtp.A2DP_SBC_SUBBANDS_4;
    const allocation: u8 = if (config.allocation == .snr) avdtp.A2DP_SBC_SNR else avdtp.A2DP_SBC_LOUDNESS;
    return .{
        rateBit(config.rate) | modeBit(config.mode),
        blocksBit(config.blocks) | subbands | allocation,
        @min(least_bitpool, config.bitpool),
        config.bitpool,
    };
}

/// SET_CONFIGURATION's parameters, into `out`: the sink's end point and
/// the source's, the media transport, the codec, and delay reports where
/// the sink offers them.
pub fn setConfiguration(out: []u8, acp_seid: u8, config: sbc.Config, least_bitpool: u8, delay_reporting: bool) []const u8 {
    out[0] = seidByte(acp_seid);
    out[1] = seidByte(LOCAL_SEID);
    const capabilities = capabilitiesInto(out[2..], elementOf(config, least_bitpool), delay_reporting);
    return out[0 .. 2 + capabilities.len];
}

/// What a stream is doing with the source's end point.
pub const State = enum { idle, configured, open, streaming };

/// The source's end point, as its answers need it.
pub const Local = struct {
    /// A stream is being made with it, or has it.
    in_use: bool = false,
    state: State = .idle,
    /// The configuration in force: SBC's element, and whether delay
    /// reports were configured.
    element: [4]u8 = @splat(0),
    delay_reporting: bool = false,
    /// The device's last delay report, in tenths of a millisecond.
    delay: ?u16 = null,

    /// The stream ended: the end point free again, its configuration
    /// gone; the last delay reported kept.
    pub fn release(local: *Local) void {
        local.* = .{ .delay = local.delay };
    }
};

/// What a device's command meant for the stream.
pub const Event = enum { none, started, suspended, closed, aborted, delay };

/// The answer to a device's command - empty where none is sent - and what
/// it meant.
pub const Answer = struct { reply: []const u8, event: Event = .none };

/// A device's command answered, into `out` (32 bytes hold any answer).
pub fn answer(local: *Local, request: Message, out: []u8) Answer {
    const parameters = request.payload;
    const seid: u8 = if (parameters.len > 0) seidOf(parameters[0]) else 0;
    const ours = seid == LOCAL_SEID;
    const label = request.label;
    const signal = request.signal;
    switch (signal) {
        avdtp.AVDTP_DISCOVER => {
            const in_use: u8 = if (local.in_use) avdtp.AVDTP_IN_USE else 0;
            return accept(out, label, signal, &.{ seidByte(LOCAL_SEID) | in_use, avdtp.AVDTP_MEDIA_AUDIO << avdtp.AVDTP_MEDIA_SHIFT });
        },
        avdtp.AVDTP_GET_CAPABILITIES, avdtp.AVDTP_GET_ALL_CAPABILITIES => {
            if (parameters.len < 1) return refuse(out, label, signal, &.{avdtp.AVDTP_BAD_LENGTH});
            if (!ours) return refuse(out, label, signal, &.{avdtp.AVDTP_BAD_ACP_SEID});
            var capabilities: [12]u8 = undefined;
            return accept(out, label, signal, capabilitiesInto(&capabilities, local_element, false));
        },
        avdtp.AVDTP_GET_CONFIGURATION => {
            if (parameters.len < 1) return refuse(out, label, signal, &.{avdtp.AVDTP_BAD_LENGTH});
            if (!ours) return refuse(out, label, signal, &.{avdtp.AVDTP_BAD_ACP_SEID});
            if (local.state == .idle) return refuse(out, label, signal, &.{avdtp.AVDTP_BAD_STATE});
            var capabilities: [12]u8 = undefined;
            return accept(out, label, signal, capabilitiesInto(&capabilities, local.element, local.delay_reporting));
        },
        avdtp.AVDTP_SET_CONFIGURATION => {
            const why = if (local.in_use) avdtp.AVDTP_SEP_IN_USE else avdtp.AVDTP_BAD_STATE;
            return refuse(out, label, signal, &.{ 0, why });
        },
        avdtp.AVDTP_RECONFIGURE => return refuse(out, label, signal, &.{ 0, avdtp.AVDTP_NOT_SUPPORTED_COMMAND }),
        avdtp.AVDTP_OPEN => {
            if (parameters.len < 1) return refuse(out, label, signal, &.{avdtp.AVDTP_BAD_LENGTH});
            if (!ours) return refuse(out, label, signal, &.{avdtp.AVDTP_BAD_ACP_SEID});
            return refuse(out, label, signal, &.{avdtp.AVDTP_BAD_STATE});
        },
        avdtp.AVDTP_START => {
            if (parameters.len < 1) return refuse(out, label, signal, &.{ 0, avdtp.AVDTP_BAD_LENGTH });
            if (!ours) return refuse(out, label, signal, &.{ parameters[0], avdtp.AVDTP_BAD_ACP_SEID });
            if (local.state != .open) return refuse(out, label, signal, &.{ parameters[0], avdtp.AVDTP_BAD_STATE });
            local.state = .streaming;
            return .{ .reply = message(out, label, avdtp.AVDTP_ACCEPT, signal, &.{}), .event = .started };
        },
        avdtp.AVDTP_SUSPEND => {
            if (parameters.len < 1) return refuse(out, label, signal, &.{ 0, avdtp.AVDTP_BAD_LENGTH });
            if (!ours) return refuse(out, label, signal, &.{ parameters[0], avdtp.AVDTP_BAD_ACP_SEID });
            if (local.state != .streaming) return refuse(out, label, signal, &.{ parameters[0], avdtp.AVDTP_BAD_STATE });
            local.state = .open;
            return .{ .reply = message(out, label, avdtp.AVDTP_ACCEPT, signal, &.{}), .event = .suspended };
        },
        avdtp.AVDTP_CLOSE => {
            if (parameters.len < 1) return refuse(out, label, signal, &.{avdtp.AVDTP_BAD_LENGTH});
            if (!ours) return refuse(out, label, signal, &.{avdtp.AVDTP_BAD_ACP_SEID});
            if (local.state != .open and local.state != .streaming) return refuse(out, label, signal, &.{avdtp.AVDTP_BAD_STATE});
            local.release();
            return .{ .reply = message(out, label, avdtp.AVDTP_ACCEPT, signal, &.{}), .event = .closed };
        },
        avdtp.AVDTP_ABORT => {
            // An abort of an end point there is not goes unanswered.
            if (!ours) return .{ .reply = &.{} };
            local.release();
            return .{ .reply = message(out, label, avdtp.AVDTP_ACCEPT, signal, &.{}), .event = .aborted };
        },
        avdtp.AVDTP_SECURITY_CONTROL => return refuse(out, label, signal, &.{avdtp.AVDTP_NOT_SUPPORTED_COMMAND}),
        avdtp.AVDTP_DELAYREPORT => {
            if (parameters.len < 3) return refuse(out, label, signal, &.{avdtp.AVDTP_BAD_LENGTH});
            if (!ours) return refuse(out, label, signal, &.{avdtp.AVDTP_BAD_ACP_SEID});
            local.delay = @as(u16, parameters[1]) << 8 | parameters[2];
            return .{ .reply = message(out, label, avdtp.AVDTP_ACCEPT, signal, &.{}), .event = .delay };
        },
        else => return .{ .reply = message(out, label, avdtp.AVDTP_GENERAL_REJECT, signal, &.{}) },
    }
}

fn accept(out: []u8, label: u4, signal: u8, parameters: []const u8) Answer {
    return .{ .reply = message(out, label, avdtp.AVDTP_ACCEPT, signal, parameters) };
}

fn refuse(out: []u8, label: u4, signal: u8, parameters: []const u8) Answer {
    return .{ .reply = message(out, label, avdtp.AVDTP_REJECT, signal, parameters) };
}

/// Service capabilities for SBC's element, into `out` (12 bytes): the
/// media transport, the codec and, with `delay_reporting`, delay reports.
fn capabilitiesInto(out: []u8, element: [4]u8, delay_reporting: bool) []const u8 {
    const fixed = [_]u8{
        avdtp.AVDTP_CAT_MEDIA_TRANSPORT,                    0,
        avdtp.AVDTP_CAT_MEDIA_CODEC,                        6,
        avdtp.AVDTP_MEDIA_AUDIO << avdtp.AVDTP_MEDIA_SHIFT, avdtp.A2DP_CODEC_SBC,
        element[0],                                         element[1],
        element[2],                                         element[3],
    };
    @memcpy(out[0..fixed.len], &fixed);
    if (!delay_reporting) return out[0..fixed.len];
    out[fixed.len] = avdtp.AVDTP_CAT_DELAY_REPORTING;
    out[fixed.len + 1] = 0;
    return out[0 .. fixed.len + 2];
}

/// The bytes before a media packet's frames, and the identifier the
/// source here sends them under.
pub const media_header = avdtp.RTP_HDR + 1;
pub const SSRC: u32 = 1;

/// A media packet's header: RTP's - its sequence number and the
/// timestamp of its first sample - and the byte that counts its frames.
pub fn mediaHeader(out: *[media_header]u8, sequence: u16, timestamp: u32, frames: usize) void {
    out[0] = avdtp.RTP_VERSION;
    out[1] = avdtp.RTP_PAYLOAD_DYNAMIC;
    out[2] = @truncate(sequence >> 8);
    out[3] = @truncate(sequence);
    out[4] = @truncate(timestamp >> 24);
    out[5] = @truncate(timestamp >> 16);
    out[6] = @truncate(timestamp >> 8);
    out[7] = @truncate(timestamp);
    out[8] = @truncate(SSRC >> 24);
    out[9] = @truncate(SSRC >> 16);
    out[10] = @truncate(SSRC >> 8);
    out[11] = @truncate(SSRC);
    out[12] = @as(u8, @intCast(frames)) & avdtp.A2DP_SBC_FRAMES_MASK;
}

/// How many whole frames of `frame_length` bytes a packet of `mtu` bytes
/// holds after its header, 15 at the most; 0 where not one does.
pub fn framesPerPacket(mtu: usize, frame_length: usize) usize {
    if (mtu <= media_header or frame_length == 0) return 0;
    return @min((mtu - media_header) / frame_length, avdtp.A2DP_SBC_FRAMES_MOST);
}

/// A device's reason for refusing a command, in words.
pub fn refusalText(code: u8) [*:0]const u8 {
    return switch (code) {
        avdtp.AVDTP_BAD_HEADER_FORMAT => "a header it could not read",
        avdtp.AVDTP_BAD_LENGTH => "a length it did not expect",
        avdtp.AVDTP_BAD_ACP_SEID => "no such end point",
        avdtp.AVDTP_SEP_IN_USE => "the end point is in use",
        avdtp.AVDTP_SEP_NOT_IN_USE => "the end point is not in use",
        avdtp.AVDTP_BAD_SERV_CATEGORY => "a category it does not know",
        avdtp.AVDTP_BAD_PAYLOAD_FORMAT => "parameters it could not read",
        avdtp.AVDTP_NOT_SUPPORTED_COMMAND => "a command it does not take",
        avdtp.AVDTP_INVALID_CAPABILITIES => "capabilities that cannot be changed",
        avdtp.AVDTP_BAD_MEDIA_TRANSPORT_FORMAT => "a media transport it could not read",
        avdtp.AVDTP_UNSUPPORTED_CONFIGURATION => "a configuration it does not take",
        avdtp.AVDTP_BAD_STATE => "not now - its stream is in another state",
        avdtp.A2DP_INVALID_CODEC_TYPE, avdtp.A2DP_NOT_SUPPORTED_CODEC_TYPE => "a codec it does not take",
        avdtp.A2DP_INVALID_SAMPLING_FREQUENCY, avdtp.A2DP_NOT_SUPPORTED_SAMPLING_FREQUENCY => "a rate it does not take",
        avdtp.A2DP_INVALID_CHANNEL_MODE, avdtp.A2DP_NOT_SUPPORTED_CHANNEL_MODE => "a channel mode it does not take",
        avdtp.A2DP_INVALID_SUBBANDS, avdtp.A2DP_NOT_SUPPORTED_SUBBANDS => "subbands it does not take",
        avdtp.A2DP_INVALID_ALLOCATION_METHOD, avdtp.A2DP_NOT_SUPPORTED_ALLOCATION_METHOD => "an allocation it does not take",
        avdtp.A2DP_INVALID_MINIMUM_BITPOOL_VALUE, avdtp.A2DP_NOT_SUPPORTED_MINIMUM_BITPOOL_VALUE => "a least bitpool it does not take",
        avdtp.A2DP_INVALID_MAXIMUM_BITPOOL_VALUE, avdtp.A2DP_NOT_SUPPORTED_MAXIMUM_BITPOOL_VALUE => "a bitpool it does not take",
        avdtp.A2DP_INVALID_BLOCK_LENGTH => "a block length it does not take",
        avdtp.A2DP_INVALID_CODEC_PARAMETER, avdtp.A2DP_NOT_SUPPORTED_CODEC_PARAMETER => "codec settings it does not take",
        else => "a reason of its own",
    };
}

// --- tests -------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "a command built, and a discovery's answer with two end points read" {
    var out: [16]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ 0x50, avdtp.AVDTP_DISCOVER }, command(&out, 5, avdtp.AVDTP_DISCOVER, &.{}));
    try testing.expectEqualSlices(u8, &.{ 0x60, avdtp.AVDTP_GET_ALL_CAPABILITIES, 0x04 }, command(&out, 6, avdtp.AVDTP_GET_ALL_CAPABILITIES, &.{seidByte(1)}));
    // A sink not in use, then a source a stream has.
    var assembler = Assembler{};
    const answered = assembler.feed(&.{ 0x52, avdtp.AVDTP_DISCOVER, 0x04, 0x08, 0x0E, 0x00 }).?;
    try testing.expectEqual(@as(u4, 5), answered.label);
    try testing.expectEqual(avdtp.AVDTP_ACCEPT, answered.kind);
    try testing.expectEqual(avdtp.AVDTP_DISCOVER, answered.signal);
    const sink = endpoint(answered.payload, 0).?;
    try testing.expectEqual(@as(u8, 1), sink.seid);
    try testing.expect(!sink.in_use and sink.sink);
    try testing.expectEqual(avdtp.AVDTP_MEDIA_AUDIO, sink.media);
    const source = endpoint(answered.payload, 1).?;
    try testing.expectEqual(@as(u8, 3), source.seid);
    try testing.expect(source.in_use and !source.sink);
    try testing.expect(endpoint(answered.payload, 2) == null);
}

test "a message in packets put back together, and packets out of their order let go" {
    var assembler = Assembler{};
    // Label 7, an acceptance of GET_ALL_CAPABILITIES in three packets.
    try testing.expect(assembler.feed(&.{ 0x76, 3, avdtp.AVDTP_GET_ALL_CAPABILITIES, 0x01, 0x00 }) == null);
    try testing.expect(assembler.feed(&.{ 0x7A, 0x07, 0x06 }) == null);
    const whole = assembler.feed(&.{ 0x7E, 0x00, 0x00, 0x3F, 0xFF, 0x02, 0x35 }).?;
    try testing.expectEqual(@as(u4, 7), whole.label);
    try testing.expectEqual(avdtp.AVDTP_GET_ALL_CAPABILITIES, whole.signal);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x07, 0x06, 0x00, 0x00, 0x3F, 0xFF, 0x02, 0x35 }, whole.payload);
    // An end packet without its start, one of another label, one too early.
    try testing.expect(assembler.feed(&.{ 0x7E, 0x00 }) == null);
    try testing.expect(assembler.feed(&.{ 0x76, 3, avdtp.AVDTP_DISCOVER, 0x04 }) == null);
    try testing.expect(assembler.feed(&.{ 0x8A, 0x08 }) == null);
    try testing.expect(assembler.feed(&.{ 0x7E, 0x08 }) == null);
    try testing.expect(assembler.feed(&.{ 0x76, 3, avdtp.AVDTP_DISCOVER, 0x04 }) == null);
    try testing.expect(assembler.feed(&.{ 0x7E, 0x08 }) == null);
    // A single packet after all that is read as it is.
    try testing.expect(assembler.feed(&.{ 0x12, avdtp.AVDTP_OPEN }) != null);
}

test "capabilities with SBC's, delay reports and categories passed over" {
    const payload = [_]u8{
        avdtp.AVDTP_CAT_MEDIA_TRANSPORT,    0,
        avdtp.AVDTP_CAT_CONTENT_PROTECTION, 2,
        0x02,                               0x00,
        avdtp.AVDTP_CAT_MEDIA_CODEC,        6,
        0x00,                               avdtp.A2DP_CODEC_SBC,
        0x3F,                               0xFF,
        0x02,                               0x35,
        avdtp.AVDTP_CAT_DELAY_REPORTING,    0,
        0x2A,                               1,
        0x00,
    };
    const offer = offerOf(&payload);
    try testing.expect(offer.media_transport and offer.delay_reporting and !offer.broken);
    try testing.expectEqualSlices(u8, &.{ 0x3F, 0xFF, 0x02, 0x35 }, &offer.element.?);
    // A maker's own codec: no SBC element, the codec named.
    const vendor = offerOf(&.{ avdtp.AVDTP_CAT_MEDIA_TRANSPORT, 0, avdtp.AVDTP_CAT_MEDIA_CODEC, 8, 0x00, avdtp.A2DP_CODEC_VENDOR, 0x4F, 0x00, 0x00, 0x00, 0x01, 0x00 });
    try testing.expect(vendor.element == null);
    try testing.expectEqual(avdtp.A2DP_CODEC_VENDOR, vendor.codec.?);
    // A length past the end: what came before stands.
    const broken = offerOf(&.{ avdtp.AVDTP_CAT_DELAY_REPORTING, 0, avdtp.AVDTP_CAT_MEDIA_CODEC, 6, 0x00, 0x00 });
    try testing.expect(broken.broken and broken.delay_reporting and broken.element == null);
}

test "the configurations a sink takes, best first, the next after a refusal" {
    const everything = [4]u8{ 0x3F, 0xFF, 2, 53 };
    const first = candidate(everything, 0, 0).?;
    try testing.expectEqual(@as(u32, 48000), first.rate);
    try testing.expectEqual(sbc.Mode.joint_stereo, first.mode);
    try testing.expectEqual(@as(u8, 16), first.blocks);
    try testing.expectEqual(@as(u8, 8), first.subbands);
    try testing.expectEqual(sbc.Allocation.loudness, first.allocation);
    try testing.expectEqual(@as(u8, 53), first.bitpool);
    try testing.expectEqual(sbc.Mode.stereo, candidate(everything, 0, 1).?.mode);
    const dual = candidate(everything, 0, 2).?;
    try testing.expectEqual(sbc.Mode.dual_channel, dual.mode);
    try testing.expectEqual(@as(u8, 31), dual.bitpool);
    try testing.expectEqual(sbc.Mode.mono, candidate(everything, 0, 3).?.mode);
    const refused_rate = candidate(everything, 0, 4).?;
    try testing.expectEqual(@as(u32, 44100), refused_rate.rate);
    try testing.expectEqual(sbc.Mode.joint_stereo, refused_rate.mode);
    try testing.expect(candidate(everything, 0, 8) == null);
    // The sound's own rate, and none other.
    try testing.expectEqual(@as(u32, 44100), candidate(everything, 44100, 0).?.rate);
    try testing.expect(candidate(everything, 44100, 4) == null);
    try testing.expect(candidate(everything, 22050, 0) == null);
    // A sink of 44.1 kHz joint stereo alone, 8 blocks, 4 subbands, SNR,
    // a bitpool up to 35.
    const narrow = [4]u8{ 0x21, 0x4A, 2, 35 };
    const only = candidate(narrow, 0, 0).?;
    try testing.expectEqual(@as(u32, 44100), only.rate);
    try testing.expectEqual(@as(u8, 8), only.blocks);
    try testing.expectEqual(@as(u8, 4), only.subbands);
    try testing.expectEqual(sbc.Allocation.snr, only.allocation);
    try testing.expectEqual(@as(u8, 35), only.bitpool);
    try testing.expect(candidate(narrow, 0, 1) == null);
    try testing.expect(candidate(narrow, 48000, 0) == null);
    // A least bitpool above the one wanted is taken; one above the most
    // leaves nothing.
    try testing.expectEqual(@as(u8, 60), candidate(.{ 0x11, 0x15, 60, 64 }, 0, 0).?.bitpool);
    try testing.expect(candidate(.{ 0x11, 0x15, 60, 50 }, 0, 0) == null);
}

test "a configuration's element, and SET_CONFIGURATION's parameters" {
    const config = sbc.Config{};
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x15, 2, 53 }, &elementOf(config, 2));
    var out: [16]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ 0x08, 0x04, 0x01, 0x00, 0x07, 0x06, 0x00, 0x00, 0x11, 0x15, 0x02, 0x35, 0x08, 0x00 }, setConfiguration(&out, 2, config, 2, true));
    try testing.expectEqual(@as(usize, 12), setConfiguration(&out, 2, config, 2, false).len);
    const snr44 = sbc.Config{ .rate = 44100, .mode = .stereo, .allocation = .snr, .blocks = 12, .subbands = 4, .bitpool = 30 };
    try testing.expectEqualSlices(u8, &.{ 0x22, 0x2A, 2, 30 }, &elementOf(snr44, 2));
}

test "a device's commands answered, and what they mean for the stream" {
    var local = Local{ .in_use = true, .state = .streaming, .element = .{ 0x11, 0x15, 2, 53 }, .delay_reporting = true };
    var out: [32]u8 = undefined;
    // A delay report of 150 ms, kept.
    var told = answer(&local, .{ .label = 3, .kind = avdtp.AVDTP_COMMAND, .signal = avdtp.AVDTP_DELAYREPORT, .payload = &.{ 0x04, 0x05, 0xDC } }, &out);
    try testing.expectEqualSlices(u8, &.{ 0x32, avdtp.AVDTP_DELAYREPORT }, told.reply);
    try testing.expectEqual(Event.delay, told.event);
    try testing.expectEqual(@as(u16, 1500), local.delay.?);
    // Suspended by the device, started again, a start of another end
    // point refused.
    told = answer(&local, .{ .label = 4, .kind = avdtp.AVDTP_COMMAND, .signal = avdtp.AVDTP_SUSPEND, .payload = &.{0x04} }, &out);
    try testing.expectEqualSlices(u8, &.{ 0x42, avdtp.AVDTP_SUSPEND }, told.reply);
    try testing.expectEqual(Event.suspended, told.event);
    try testing.expectEqual(State.open, local.state);
    told = answer(&local, .{ .label = 5, .kind = avdtp.AVDTP_COMMAND, .signal = avdtp.AVDTP_START, .payload = &.{0x08} }, &out);
    try testing.expectEqualSlices(u8, &.{ 0x53, avdtp.AVDTP_START, 0x08, avdtp.AVDTP_BAD_ACP_SEID }, told.reply);
    told = answer(&local, .{ .label = 5, .kind = avdtp.AVDTP_COMMAND, .signal = avdtp.AVDTP_START, .payload = &.{0x04} }, &out);
    try testing.expectEqual(Event.started, told.event);
    try testing.expectEqual(State.streaming, local.state);
    // Its own questions: the end point, its capabilities, the
    // configuration in force.
    told = answer(&local, .{ .label = 6, .kind = avdtp.AVDTP_COMMAND, .signal = avdtp.AVDTP_DISCOVER, .payload = &.{} }, &out);
    try testing.expectEqualSlices(u8, &.{ 0x62, avdtp.AVDTP_DISCOVER, 0x06, 0x00 }, told.reply);
    told = answer(&local, .{ .label = 7, .kind = avdtp.AVDTP_COMMAND, .signal = avdtp.AVDTP_GET_ALL_CAPABILITIES, .payload = &.{0x04} }, &out);
    try testing.expectEqualSlices(u8, &.{ 0x72, avdtp.AVDTP_GET_ALL_CAPABILITIES, 0x01, 0x00, 0x07, 0x06, 0x00, 0x00, 0x3F, 0xFF, 0x02, 0x35 }, told.reply);
    told = answer(&local, .{ .label = 8, .kind = avdtp.AVDTP_COMMAND, .signal = avdtp.AVDTP_GET_CONFIGURATION, .payload = &.{0x04} }, &out);
    try testing.expectEqualSlices(u8, &.{ 0x82, avdtp.AVDTP_GET_CONFIGURATION, 0x01, 0x00, 0x07, 0x06, 0x00, 0x00, 0x11, 0x15, 0x02, 0x35, 0x08, 0x00 }, told.reply);
    // Its own configuration refused while the stream has the end point;
    // a signal it made up refused in general.
    told = answer(&local, .{ .label = 9, .kind = avdtp.AVDTP_COMMAND, .signal = avdtp.AVDTP_SET_CONFIGURATION, .payload = &.{ 0x04, 0x04 } }, &out);
    try testing.expectEqualSlices(u8, &.{ 0x93, avdtp.AVDTP_SET_CONFIGURATION, 0x00, avdtp.AVDTP_SEP_IN_USE }, told.reply);
    told = answer(&local, .{ .label = 10, .kind = avdtp.AVDTP_COMMAND, .signal = 0x3E, .payload = &.{} }, &out);
    try testing.expectEqualSlices(u8, &.{ 0xA1, 0x3E }, told.reply);
    // An abort of an end point there is not goes unanswered; a close
    // ends the stream.
    told = answer(&local, .{ .label = 11, .kind = avdtp.AVDTP_COMMAND, .signal = avdtp.AVDTP_ABORT, .payload = &.{0x0C} }, &out);
    try testing.expectEqual(@as(usize, 0), told.reply.len);
    told = answer(&local, .{ .label = 12, .kind = avdtp.AVDTP_COMMAND, .signal = avdtp.AVDTP_CLOSE, .payload = &.{0x04} }, &out);
    try testing.expectEqualSlices(u8, &.{ 0xC2, avdtp.AVDTP_CLOSE }, told.reply);
    try testing.expectEqual(Event.closed, told.event);
    try testing.expectEqual(State.idle, local.state);
    try testing.expect(!local.in_use);
    try testing.expectEqual(@as(u16, 1500), local.delay.?);
}

test "a media packet's header, and the frames a packet holds" {
    var header: [media_header]u8 = undefined;
    mediaHeader(&header, 0x1234, 0x00010203, 7);
    try testing.expectEqualSlices(u8, &.{ 0x80, 96, 0x12, 0x34, 0x00, 0x01, 0x02, 0x03, 0x00, 0x00, 0x00, 0x01, 0x07 }, &header);
    try testing.expectEqual(@as(usize, 7), framesPerPacket(895, 119));
    try testing.expectEqual(@as(usize, 5), framesPerPacket(672, 119));
    try testing.expectEqual(@as(usize, 15), framesPerPacket(2048, 119));
    try testing.expectEqual(@as(usize, 0), framesPerPacket(100, 119));
}
