// SPDX-License-Identifier: MIT
//! A stream's signalling as its source drives it, on AVDTP's signalling
//! channel: the device's audio sinks found, the first that takes SBC
//! configured, the stream opened, started, suspended and closed, and the
//! device's own commands answered meanwhile. Frames in, frames out: the
//! owner hands `heard` each frame of the signalling channel and sends
//! what comes back, and opens the media channel when `heard` says the
//! stream is open. The messages are signalling.zig's.
//!
//! **Setting up.** `begin` asks the device for its end points
//! (DISCOVER). Each audio sink not in use is asked for its capabilities -
//! all of them (GET_ALL_CAPABILITIES), or the basic ones from a device
//! that does not know that command - until one takes SBC. That one is
//! configured with the first of signalling.candidate's settings, and
//! after each refusal with the next - past the other settings of a rate
//! the device refused - with delay reports where it offers them. Then
//! OPEN: its acceptance is `.opened`, and the owner opens the media
//! channel and calls `start`.
//!
//! **Its own commands** wait for their answers one at a time; the owner
//! gives up on one after a time of its choosing (`timedOut`). `start`,
//! `pause` and `close` - CLOSE, and ABORT where the device refuses that -
//! end in `.started`, `.suspended` and `.closed`; a failure in `.failed`,
//! the reason in `why`, `why_signal` and `why_code`.
//!
//! **The device's commands** are answered as signalling.answer answers
//! them, and what they mean comes back in the same way: a device that
//! starts, suspends or closes the stream itself, a delay it reports.

const sdk = @import("sdk");
const avdtp = sdk.bluetooth.avdtp;
const sbc = @import("sbc.zig");
const signalling = @import("signalling.zig");

/// The device's audio sinks asked about, at most: a sink end point for
/// each codec it takes, and several for some.
const sinks_most = 32;

/// Where the stream is.
pub const Phase = enum {
    idle,
    /// DISCOVER asked.
    discovering,
    /// A sink asked for its capabilities.
    asking,
    /// SET_CONFIGURATION asked.
    configuring,
    /// OPEN asked.
    opening,
    /// Open: the media channel is the owner's to open; not started.
    open,
    starting,
    streaming,
    suspending,
    closing,
    aborting,
    closed,
    failed,
};

/// What a frame, or a command given up on, meant for the owner.
pub const Outcome = enum {
    none,
    /// The stream is open: the media channel to be opened.
    opened,
    /// Started - by `start` or by the device: media to be sent.
    started,
    /// Suspended - by `pause` or by the device: no media meanwhile.
    suspended,
    /// Closed - by `close` or by the device: the media channel to be
    /// closed.
    closed,
    /// Set up no further, or a command refused: `why`.
    failed,
    /// The device reported its delay (signalling.Local.delay).
    delay,
};

/// Why the stream failed.
pub const Why = enum {
    none,
    /// A command went unanswered.
    timeout,
    /// The device refused it: `why_code` says why.
    refused,
    /// The device does not know the command.
    unknown_command,
    /// The device has no audio sink, or none not in use.
    no_sink,
    /// None of its sinks takes SBC.
    no_sbc,
    /// It refused every setting it said it takes, or takes none the
    /// sound is at.
    no_configuration,
};

/// A frame to send on the signalling channel - empty for none - and what
/// came of the one heard.
pub const Step = struct { send: []const u8 = &.{}, outcome: Outcome = .none };

/// A command waiting for its answer.
const Awaiting = struct { label: u4, signal: u8 };

pub const Source = struct {
    phase: Phase = .idle,
    /// The rate the sound is at; 0 for the best the device takes.
    rate: u32 = 0,
    /// The source's end point, as the device's commands see it.
    local: signalling.Local = .{},
    assembler: signalling.Assembler = .{},
    /// The next command's label, and the command waiting for its answer.
    label: u4 = 0,
    awaiting: ?Awaiting = null,
    /// The device's audio sinks not in use, as DISCOVER listed them, and
    /// the one being asked or configured.
    sinks: [sinks_most]u8 = @splat(0),
    sink_count: usize = 0,
    sink_index: usize = 0,
    /// The sink is asked for all its capabilities, not the basic ones.
    asking_all: bool = true,
    /// What the sink offered, and the setting offered it.
    offer: signalling.Offer = .{},
    candidate_index: usize = 0,
    /// The stream's: the sink's end point and the configuration in force.
    remote_seid: u8 = 0,
    config: sbc.Config = .{},
    why: Why = .none,
    /// The command refused or given up on, and the device's code.
    why_signal: u8 = 0,
    why_code: u8 = 0,
    /// The frame to send.
    out: [64]u8 = undefined,

    /// The setup begun at `rate` (0 for the best the device takes): the
    /// frame that asks for the device's end points.
    pub fn begin(source: *Source, rate: u32) []const u8 {
        source.* = .{ .rate = rate, .local = .{ .delay = source.local.delay } };
        source.phase = .discovering;
        return source.command(avdtp.AVDTP_DISCOVER, &.{});
    }

    /// A frame of the signalling channel: what to send back, and what it
    /// meant.
    pub fn heard(source: *Source, frame: []const u8) Step {
        const message = source.assembler.feed(frame) orelse return .{};
        if (message.kind == avdtp.AVDTP_COMMAND) return source.theirs(message);
        const awaited = source.awaiting orelse return .{};
        if (message.label != awaited.label) return .{};
        // A general reject may name another signal: the label is enough.
        if (message.kind != avdtp.AVDTP_GENERAL_REJECT and message.signal != awaited.signal) return .{};
        source.awaiting = null;
        if (source.phase == .closed or source.phase == .failed) return .{};
        return source.answered(awaited.signal, message);
    }

    /// The stream started: the frame that asks for it. Empty unless it is
    /// open and not started.
    pub fn start(source: *Source) []const u8 {
        if (source.phase != .open or source.awaiting != null) return &.{};
        source.phase = .starting;
        return source.command(avdtp.AVDTP_START, &.{signalling.seidByte(source.remote_seid)});
    }

    /// The stream suspended: the frame that asks for it. Empty unless it
    /// is streaming.
    pub fn pause(source: *Source) []const u8 {
        if (source.phase != .streaming or source.awaiting != null) return &.{};
        source.phase = .suspending;
        return source.command(avdtp.AVDTP_SUSPEND, &.{signalling.seidByte(source.remote_seid)});
    }

    /// The stream closed: CLOSE where it is open, ABORT where it is being
    /// set up or a command is out, nothing where the device has no part
    /// of it yet - then `.closed` at once.
    pub fn close(source: *Source) Step {
        switch (source.phase) {
            .closed, .closing, .aborting => return .{},
            .open, .streaming => if (source.awaiting == null) {
                source.phase = .closing;
                return .{ .send = source.command(avdtp.AVDTP_CLOSE, &.{signalling.seidByte(source.remote_seid)}) };
            },
            else => {},
        }
        if (source.remote_seid == 0 or (!source.local.in_use and source.phase != .configuring)) {
            source.closed();
            return .{ .outcome = .closed };
        }
        source.phase = .aborting;
        return .{ .send = source.command(avdtp.AVDTP_ABORT, &.{signalling.seidByte(source.remote_seid)}) };
    }

    /// The command out given up on: `.closed` for a CLOSE or an ABORT -
    /// the stream is let go of - `.failed` for any other.
    pub fn timedOut(source: *Source) Outcome {
        const awaited = source.awaiting orelse return .none;
        source.awaiting = null;
        if (source.phase == .closing or source.phase == .aborting) {
            source.closed();
            return .closed;
        }
        return source.fail(.timeout, awaited.signal, 0).outcome;
    }

    /// A command into `out`, its label taken: the frame.
    fn command(source: *Source, signal: u8, parameters: []const u8) []const u8 {
        const label = source.label;
        source.label +%= 1;
        source.awaiting = .{ .label = label, .signal = signal };
        return signalling.command(&source.out, label, signal, parameters);
    }

    /// A command of the device's answered.
    fn theirs(source: *Source, message: signalling.Message) Step {
        const told = signalling.answer(&source.local, message, &source.out);
        const outcome: Outcome = switch (told.event) {
            .none => .none,
            .delay => .delay,
            .started => started: {
                source.phase = .streaming;
                break :started .started;
            },
            .suspended => suspended: {
                source.phase = .open;
                break :suspended .suspended;
            },
            .closed, .aborted => ended: {
                source.closed();
                break :ended .closed;
            },
        };
        return .{ .send = told.reply, .outcome = outcome };
    }

    /// The answer to a command of the source's.
    fn answered(source: *Source, signal: u8, message: signalling.Message) Step {
        const accepted = message.kind == avdtp.AVDTP_ACCEPT;
        switch (signal) {
            avdtp.AVDTP_DISCOVER => {
                if (!accepted) return source.refused(signal, message, 0);
                source.sink_count = 0;
                var index: usize = 0;
                while (signalling.endpoint(message.payload, index)) |each| : (index += 1) {
                    if (!each.sink or each.in_use or each.media != avdtp.AVDTP_MEDIA_AUDIO) continue;
                    if (each.seid == 0 or source.sink_count == sinks_most) continue;
                    source.sinks[source.sink_count] = each.seid;
                    source.sink_count += 1;
                }
                if (source.sink_count == 0) return source.fail(.no_sink, signal, 0);
                source.sink_index = 0;
                source.asking_all = true;
                return source.ask();
            },
            avdtp.AVDTP_GET_ALL_CAPABILITIES, avdtp.AVDTP_GET_CAPABILITIES => {
                if (!accepted) {
                    // A device that does not know the command answers the
                    // basic one.
                    if (signal == avdtp.AVDTP_GET_ALL_CAPABILITIES) {
                        source.asking_all = false;
                        return source.ask();
                    }
                    return source.nextSink();
                }
                source.offer = signalling.offerOf(message.payload);
                if (source.offer.element == null) return source.nextSink();
                source.remote_seid = source.sinks[source.sink_index];
                source.candidate_index = 0;
                return source.configure();
            },
            avdtp.AVDTP_SET_CONFIGURATION => {
                if (!accepted) {
                    // [the category that failed, why]
                    source.why_code = codeAt(message, 1);
                    const refused_rate = source.config.rate;
                    source.candidate_index += 1;
                    if (rateRefused(source.why_code)) {
                        while (signalling.candidate(source.offer.element.?, source.rate, source.candidate_index)) |next| {
                            if (next.rate != refused_rate) break;
                            source.candidate_index += 1;
                        }
                    }
                    return source.configure();
                }
                source.local = .{
                    .in_use = true,
                    .state = .configured,
                    .element = signalling.elementOf(source.config, leastBitpool(source.offer.element.?)),
                    .delay_reporting = source.offer.delay_reporting,
                    .delay = source.local.delay,
                };
                source.phase = .opening;
                return .{ .send = source.command(avdtp.AVDTP_OPEN, &.{signalling.seidByte(source.remote_seid)}) };
            },
            avdtp.AVDTP_OPEN => {
                if (!accepted) return source.refused(signal, message, 0);
                source.local.state = .open;
                source.phase = .open;
                return .{ .outcome = .opened };
            },
            avdtp.AVDTP_START => {
                // The device may have started it meanwhile.
                if (source.phase == .streaming) return .{};
                if (!accepted) {
                    source.phase = .open;
                    return source.refusedOnly(signal, message, 1);
                }
                source.local.state = .streaming;
                source.phase = .streaming;
                return .{ .outcome = .started };
            },
            avdtp.AVDTP_SUSPEND => {
                if (source.phase == .open) return .{};
                if (!accepted) {
                    source.phase = .streaming;
                    return source.refusedOnly(signal, message, 1);
                }
                source.local.state = .open;
                source.phase = .open;
                return .{ .outcome = .suspended };
            },
            avdtp.AVDTP_CLOSE => {
                if (!accepted) {
                    source.phase = .aborting;
                    return .{ .send = source.command(avdtp.AVDTP_ABORT, &.{signalling.seidByte(source.remote_seid)}) };
                }
                source.closed();
                return .{ .outcome = .closed };
            },
            avdtp.AVDTP_ABORT => {
                source.closed();
                return .{ .outcome = .closed };
            },
            else => return .{},
        }
    }

    /// The sink at `sink_index` asked for its capabilities.
    fn ask(source: *Source) Step {
        source.phase = .asking;
        const signal = if (source.asking_all) avdtp.AVDTP_GET_ALL_CAPABILITIES else avdtp.AVDTP_GET_CAPABILITIES;
        return .{ .send = source.command(signal, &.{signalling.seidByte(source.sinks[source.sink_index])}) };
    }

    /// The next sink asked, past one without SBC.
    fn nextSink(source: *Source) Step {
        source.sink_index += 1;
        source.asking_all = true;
        if (source.sink_index >= source.sink_count) return source.fail(.no_sbc, avdtp.AVDTP_GET_CAPABILITIES, 0);
        return source.ask();
    }

    /// The sink configured with the setting at `candidate_index`.
    fn configure(source: *Source) Step {
        const element = source.offer.element.?;
        const config = signalling.candidate(element, source.rate, source.candidate_index) orelse
            return source.fail(.no_configuration, avdtp.AVDTP_SET_CONFIGURATION, source.why_code);
        source.config = config;
        source.phase = .configuring;
        var parameters: [24]u8 = undefined;
        const bytes = signalling.setConfiguration(&parameters, source.remote_seid, config, leastBitpool(element), source.offer.delay_reporting);
        return .{ .send = source.command(avdtp.AVDTP_SET_CONFIGURATION, bytes) };
    }

    /// The stream let go of: the end point free.
    fn closed(source: *Source) void {
        source.phase = .closed;
        source.awaiting = null;
        source.local.release();
    }

    /// A command refused, the setup ended: the device's code at `at`.
    fn refused(source: *Source, signal: u8, message: signalling.Message, at: usize) Step {
        if (message.kind == avdtp.AVDTP_GENERAL_REJECT) return source.fail(.unknown_command, signal, 0);
        return source.fail(.refused, signal, codeAt(message, at));
    }

    /// A command refused, the stream going on as it was.
    fn refusedOnly(source: *Source, signal: u8, message: signalling.Message, at: usize) Step {
        source.why = if (message.kind == avdtp.AVDTP_GENERAL_REJECT) .unknown_command else .refused;
        source.why_signal = signal;
        source.why_code = if (message.kind == avdtp.AVDTP_GENERAL_REJECT) 0 else codeAt(message, at);
        return .{ .outcome = .failed };
    }

    fn fail(source: *Source, why: Why, signal: u8, code: u8) Step {
        source.phase = .failed;
        source.awaiting = null;
        source.why = why;
        source.why_signal = signal;
        source.why_code = code;
        return .{ .outcome = .failed };
    }
};

/// A refusal's code, at its place in the answer; 0 where it is missing.
fn codeAt(message: signalling.Message, at: usize) u8 {
    return if (message.payload.len > at) message.payload[at] else 0;
}

/// Whether a refused configuration was refused for its rate.
fn rateRefused(code: u8) bool {
    return code == avdtp.A2DP_INVALID_SAMPLING_FREQUENCY or code == avdtp.A2DP_NOT_SUPPORTED_SAMPLING_FREQUENCY;
}

/// The least bitpool offered a sink: its own least, 2 at the lowest.
fn leastBitpool(element: [4]u8) u8 {
    return @max(element[2], avdtp.A2DP_SBC_BITPOOL_LEAST);
}

// --- tests -------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// An answer of the sink's to the command in `sent`, into `out`.
fn reply(out: []u8, sent: []const u8, kind: u8, payload: []const u8) []const u8 {
    out[0] = (sent[0] & 0xF0) | kind;
    out[1] = sent[1];
    @memcpy(out[2..][0..payload.len], payload);
    return out[0 .. 2 + payload.len];
}

/// A command of the sink's own, label `label`.
fn theirCommand(out: []u8, label: u4, signal: u8, parameters: []const u8) []const u8 {
    return signalling.command(out, label, signal, parameters);
}

test "a sink found past others, its capabilities asked the old way, a rate refused, opened and started" {
    var source = Source{};
    var frame: [64]u8 = undefined;
    var sent = source.begin(0);
    try testing.expectEqualSlices(u8, &.{ 0x00, avdtp.AVDTP_DISCOVER }, sent);
    // A sink in use, a video sink, a source, and two audio sinks.
    var step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x06, 0x08, 0x08, 0x18, 0x0C, 0x00, 0x10, 0x08, 0x14, 0x08 }));
    try testing.expectEqual(@as(usize, 2), source.sink_count);
    try testing.expectEqualSlices(u8, &.{ 0x10, avdtp.AVDTP_GET_ALL_CAPABILITIES, 0x10 }, step.send);
    // The first takes only a maker's codec.
    sent = step.send;
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x01, 0x00, 0x07, 0x08, 0x00, 0xFF, 0x4F, 0x00, 0x00, 0x00, 0x01, 0x00 }));
    try testing.expectEqualSlices(u8, &.{ 0x20, avdtp.AVDTP_GET_ALL_CAPABILITIES, 0x14 }, step.send);
    // The second does not know GET_ALL_CAPABILITIES; asked the basic
    // ones, it takes SBC.
    sent = step.send;
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_GENERAL_REJECT, &.{}));
    try testing.expectEqualSlices(u8, &.{ 0x30, avdtp.AVDTP_GET_CAPABILITIES, 0x14 }, step.send);
    sent = step.send;
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x01, 0x00, 0x07, 0x06, 0x00, 0x00, 0x3F, 0xFF, 0x02, 0x35 }));
    // 48 kHz joint stereo offered, without delay reports.
    try testing.expectEqualSlices(u8, &.{ 0x40, avdtp.AVDTP_SET_CONFIGURATION, 0x14, 0x04, 0x01, 0x00, 0x07, 0x06, 0x00, 0x00, 0x11, 0x15, 0x02, 0x35 }, step.send);
    // Refused for its rate: 44.1 kHz offered next, not 48 kHz stereo.
    sent = step.send;
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_REJECT, &.{ avdtp.AVDTP_CAT_MEDIA_CODEC, avdtp.A2DP_NOT_SUPPORTED_SAMPLING_FREQUENCY }));
    try testing.expectEqual(Phase.configuring, source.phase);
    try testing.expectEqual(@as(u32, 44100), source.config.rate);
    try testing.expectEqual(sbc.Mode.joint_stereo, source.config.mode);
    try testing.expectEqual(@as(u8, 0x21), step.send[10]);
    // Accepted: OPEN.
    sent = step.send;
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{}));
    try testing.expectEqualSlices(u8, &.{ 0x60, avdtp.AVDTP_OPEN, 0x14 }, step.send);
    try testing.expect(source.local.in_use);
    // The device's delay report before OPEN's answer, answered.
    const open = step.send[0];
    var theirs: [16]u8 = undefined;
    step = source.heard(theirCommand(&theirs, 9, avdtp.AVDTP_DELAYREPORT, &.{ 0x04, 0x07, 0xD0 }));
    try testing.expectEqualSlices(u8, &.{ 0x92, avdtp.AVDTP_DELAYREPORT }, step.send);
    try testing.expectEqual(Outcome.delay, step.outcome);
    try testing.expectEqual(@as(u16, 2000), source.local.delay.?);
    // An answer of another label passed over; then OPEN accepted.
    try testing.expectEqual(Outcome.none, source.heard(&.{ 0x72, avdtp.AVDTP_OPEN }).outcome);
    step = source.heard(&.{ open | avdtp.AVDTP_ACCEPT, avdtp.AVDTP_OPEN });
    try testing.expectEqual(Outcome.opened, step.outcome);
    try testing.expectEqual(@as(usize, 0), step.send.len);
    // Started.
    sent = source.start();
    try testing.expectEqualSlices(u8, &.{ 0x70, avdtp.AVDTP_START, 0x14 }, sent);
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{}));
    try testing.expectEqual(Outcome.started, step.outcome);
    try testing.expectEqual(Phase.streaming, source.phase);
    try testing.expectEqual(signalling.State.streaming, source.local.state);
}

/// A source set up as far as streaming with a sink of SEID 1 that offers
/// delay reports.
fn streaming(source: *Source) !void {
    var frame: [64]u8 = undefined;
    var sent = source.begin(48000);
    var step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x04, 0x08 }));
    sent = step.send;
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x01, 0x00, 0x07, 0x06, 0x00, 0x00, 0x3F, 0xFF, 0x02, 0x35, 0x08, 0x00 }));
    // Delay reports configured with the rest.
    try testing.expectEqual(@as(usize, 16), step.send.len);
    try testing.expectEqualSlices(u8, &.{ avdtp.AVDTP_CAT_DELAY_REPORTING, 0 }, step.send[14..16]);
    sent = step.send;
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{}));
    sent = step.send;
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{}));
    try testing.expectEqual(Outcome.opened, step.outcome);
    sent = source.start();
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{}));
    try testing.expectEqual(Outcome.started, step.outcome);
}

test "a device that suspends and starts the stream itself, and a close it refuses ended by an abort" {
    var source = Source{};
    try streaming(&source);
    var theirs: [16]u8 = undefined;
    var frame: [64]u8 = undefined;
    var step = source.heard(theirCommand(&theirs, 2, avdtp.AVDTP_SUSPEND, &.{0x04}));
    try testing.expectEqualSlices(u8, &.{ 0x22, avdtp.AVDTP_SUSPEND }, step.send);
    try testing.expectEqual(Outcome.suspended, step.outcome);
    try testing.expectEqual(Phase.open, source.phase);
    // Nothing to suspend now; the device starts it again.
    try testing.expectEqual(@as(usize, 0), source.pause().len);
    step = source.heard(theirCommand(&theirs, 3, avdtp.AVDTP_START, &.{0x04}));
    try testing.expectEqual(Outcome.started, step.outcome);
    // Suspended from here, then started from here.
    var sent = source.pause();
    try testing.expectEqual(avdtp.AVDTP_SUSPEND, sent[1]);
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{}));
    try testing.expectEqual(Outcome.suspended, step.outcome);
    sent = source.start();
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{}));
    try testing.expectEqual(Outcome.started, step.outcome);
    // CLOSE refused: ABORT, and the stream let go of.
    step = source.close();
    try testing.expectEqual(avdtp.AVDTP_CLOSE, step.send[1]);
    sent = step.send;
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_REJECT, &.{avdtp.AVDTP_BAD_STATE}));
    try testing.expectEqual(avdtp.AVDTP_ABORT, step.send[1]);
    try testing.expectEqual(Phase.aborting, source.phase);
    sent = step.send;
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{}));
    try testing.expectEqual(Outcome.closed, step.outcome);
    try testing.expect(!source.local.in_use);
}

test "a device that closes the stream, and one that does not answer" {
    var source = Source{};
    try streaming(&source);
    var theirs: [16]u8 = undefined;
    const step = source.heard(theirCommand(&theirs, 5, avdtp.AVDTP_CLOSE, &.{0x04}));
    try testing.expectEqualSlices(u8, &.{ 0x52, avdtp.AVDTP_CLOSE }, step.send);
    try testing.expectEqual(Outcome.closed, step.outcome);
    try testing.expectEqual(Phase.closed, source.phase);
    try testing.expectEqual(@as(usize, 0), source.close().send.len);

    // A configuration that goes unanswered fails the setup.
    var frame: [64]u8 = undefined;
    var sent = source.begin(0);
    var asked = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x04, 0x08 }));
    sent = asked.send;
    asked = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x07, 0x06, 0x00, 0x00, 0x3F, 0xFF, 0x02, 0x35 }));
    try testing.expectEqual(avdtp.AVDTP_SET_CONFIGURATION, asked.send[1]);
    try testing.expectEqual(Outcome.failed, source.timedOut());
    try testing.expectEqual(Why.timeout, source.why);
    try testing.expectEqual(avdtp.AVDTP_SET_CONFIGURATION, source.why_signal);
    // Its late answer is passed over.
    try testing.expectEqual(Outcome.none, source.heard(reply(&frame, asked.send, avdtp.AVDTP_ACCEPT, &.{})).outcome);
    // The close of a stream being configured aborts it; that unanswered
    // lets it go.
    sent = source.begin(0);
    asked = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x04, 0x08 }));
    sent = asked.send;
    _ = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x07, 0x06, 0x00, 0x00, 0x3F, 0xFF, 0x02, 0x35 }));
    const ended = source.close();
    try testing.expectEqual(avdtp.AVDTP_ABORT, ended.send[1]);
    try testing.expectEqual(Outcome.closed, source.timedOut());
}

test "no sink, no SBC, and every setting refused" {
    var source = Source{};
    var frame: [64]u8 = undefined;
    // Only sources, and a sink in use.
    var sent = source.begin(0);
    var step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x04, 0x00, 0x0A, 0x08 }));
    try testing.expectEqual(Outcome.failed, step.outcome);
    try testing.expectEqual(Why.no_sink, source.why);
    // A sink whose capabilities have no SBC, and none after it.
    sent = source.begin(0);
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x04, 0x08 }));
    sent = step.send;
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x01, 0x00, 0x07, 0x06, 0x00, avdtp.A2DP_CODEC_AAC, 0x80, 0x01, 0x8C, 0x00 }));
    try testing.expectEqual(Why.no_sbc, source.why);
    // A sink of 44.1 kHz joint stereo alone that refuses it: nothing left.
    sent = source.begin(0);
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x04, 0x08 }));
    sent = step.send;
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x07, 0x06, 0x00, 0x00, 0x21, 0x15, 0x02, 0x35 }));
    sent = step.send;
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_REJECT, &.{ avdtp.AVDTP_CAT_MEDIA_CODEC, avdtp.A2DP_NOT_SUPPORTED_MAXIMUM_BITPOOL_VALUE }));
    try testing.expectEqual(Outcome.failed, step.outcome);
    try testing.expectEqual(Why.no_configuration, source.why);
    try testing.expectEqual(avdtp.A2DP_NOT_SUPPORTED_MAXIMUM_BITPOOL_VALUE, source.why_code);
    // A sound at a rate the sink does not take.
    sent = source.begin(32000);
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x04, 0x08 }));
    sent = step.send;
    step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x07, 0x06, 0x00, 0x00, 0x3F, 0xFF, 0x02, 0x35 }));
    try testing.expectEqual(Why.no_configuration, source.why);
}

test "a capabilities answer in packets" {
    var source = Source{};
    var frame: [64]u8 = undefined;
    const sent = source.begin(0);
    var step = source.heard(reply(&frame, sent, avdtp.AVDTP_ACCEPT, &.{ 0x04, 0x08 }));
    const label = step.send[0] & 0xF0;
    try testing.expectEqual(Outcome.none, source.heard(&.{ label | 0x04 | avdtp.AVDTP_ACCEPT, 2, avdtp.AVDTP_GET_ALL_CAPABILITIES, 0x01, 0x00, 0x07, 0x06 }).outcome);
    step = source.heard(&.{ label | 0x0C | avdtp.AVDTP_ACCEPT, 0x00, 0x00, 0x3F, 0xFF, 0x02, 0x35 });
    try testing.expectEqual(avdtp.AVDTP_SET_CONFIGURATION, step.send[1]);
    try testing.expectEqual(Phase.configuring, source.phase);
}
