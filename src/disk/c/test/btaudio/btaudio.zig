// SPDX-License-Identifier: MIT
//! BTAudio: a sound file or a tone played to a Bluetooth headphone or
//! speaker without audio.device - this machine A2DP's source, the sound
//! SBC over AVDTP - and so a test of the stream btaudio.device sends.
//! Built against the SDK, with the stream's parts (a2dp) built in.
//!
//!   BTAudio DEVICE/A [FILE/K] [TONE/K/N] [SECONDS/K/N] [CONTROLLER/K/N]
//!
//!   DEVICE <address>   the sink: a headphone or a speaker bonded with
//!                      this machine over BR/EDR
//!   FILE <name>        a sound file audiocodec.library reads, sent at its
//!                      own rate - 16, 32, 44.1 or 48 kHz - a mono one on
//!                      both sides
//!   TONE <hz>          a sine of that frequency at -20 dBFS on both
//!                      sides; 1000 Hz where neither is given
//!   SECONDS <n>        how long: a tone 10 seconds where not given, a
//!                      file to its end
//!   CONTROLLER <n>     the controller to reach the device over
//!
//! It says the stream's configuration - rate, channel mode, blocks,
//! subbands, allocation and bitpool, the frame's length, the frames to a
//! packet and the bytes the media channel takes, the bit rate - and the
//! delay the device reports; a device that suspends the stream and starts
//! it again is followed. At its end it says the packets sent and those
//! dropped - a packet not handed on before its time has gone is let go
//! of - and how late the latest left. CTRL-C stops.
//!
//! The packets go out as the sound's time passes, on timer.device's
//! E-clock, two ahead of it; the stream is closed once the last has
//! played - after the delay the device reported, or 150 ms. A device
//! that refuses the signalling channel is asked again, two seconds
//! later, four times in all: one that opens its own channel to this
//! machine at the time - as a computer does to a source it knows -
//! refuses this one, and this command takes no channel of a device's.

const sdk = @import("sdk");
const a2dp = @import("a2dp");
const exec = sdk.exec;
const dos = sdk.dos;
const timer = sdk.devices.timer;
const utility = sdk.utility;
const bluetooth = sdk.bluetooth;
const avdtp = bluetooth.avdtp;
const l2cap = bluetooth.l2cap;
const ac = sdk.audiocodec;
const sbc = a2dp.sbc;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const BluetoothBase = sdk.interface.bluetooth.BluetoothBase;
const AudioCodecBase = sdk.interface.audiocodec.AudioCodecBase;
const TimerBase = sdk.interface.timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "BTAudio";
const VERSION_STRING = "\x00$VER: BTAudio 1.1 (23.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DEVICE/A,FILE/K,TONE/K/N,SECONDS/K/N,CONTROLLER/K/N";
const arg_device = 0;
const arg_file = 1;
const arg_tone = 2;
const arg_seconds = 3;
const arg_controller = 4;
const arg_count = 5;

const tone_default = 1000;
const seconds_default = 10;
/// -20 dBFS.
const tone_level: f32 = 3277.0;
/// The packets sent ahead of their time.
const lead = 2;
/// How long a command waits for its answer, in seconds.
const answer_seconds = 6;
/// How long the last packet is given to play where the device reported
/// no delay, in tenths of a millisecond.
const playout_default = 1500;
/// The tries at the signalling channel, and the seconds between them: a
/// device opening its own channel to this machine at the time refuses
/// this one.
const open_tries = 4;
const open_pause_seconds = 2;

/// Where the command is.
const Stage = enum {
    setting_up,
    playing,
    /// The device suspended the stream.
    paused,
    /// The sound is over: its last packets playing.
    ending,
    /// CLOSE or ABORT asked.
    closing,
    done,
};

/// timer.device's E-clock, and one request on it at a time.
const Clock = struct {
    port: *exec.MsgPort,
    io: timer.TimeRequest = .{},
    device: *TimerBase,
    hz: u64,
    out: bool = false,
    target: u64 = 0,

    fn now(clock: *Clock) u64 {
        var value: timer.EClockVal = .{};
        _ = clock.device.ReadEClock(&value);
        return value.toTicks();
    }

    /// The request out to come back at `ticks`.
    fn at(clock: *Clock, sys: *ExecBase, ticks: u64) void {
        if (clock.out and clock.target == ticks) return;
        clock.cancel(sys);
        _ = sys.SetSignal(0, clock.port.sigMask());
        const eclock: *timer.EClockVal = @ptrCast(&clock.io.time);
        eclock.* = timer.EClockVal.fromTicks(ticks);
        clock.io.node.command = timer.TR_ADDREQUEST;
        sys.SendIO(&clock.io.node);
        clock.out = true;
        clock.target = ticks;
    }

    fn cancel(clock: *Clock, sys: *ExecBase) void {
        if (!clock.out) return;
        _ = sys.AbortIO(&clock.io.node);
        _ = sys.WaitIO(&clock.io.node);
        clock.out = false;
    }

    /// The request taken back, where it has come back.
    fn check(clock: *Clock, sys: *ExecBase) void {
        if (!clock.out or sys.CheckIO(&clock.io.node) == null) return;
        _ = sys.WaitIO(&clock.io.node);
        clock.out = false;
    }
};

/// Everything the command keeps, in memory of its own.
const Player = struct {
    sys: *ExecBase,
    dl: *DosBase,
    bt: *BluetoothBase,
    controller: u32,
    address: bluetooth.BTAddress,
    port: *exec.MsgPort,
    clock: Clock,
    signalling: ?*bluetooth.BTChannel,
    media_channel: ?*bluetooth.BTChannel,
    source: a2dp.Source,
    media: a2dp.Media,
    stage: Stage,
    result: i32,
    /// When the command out has waited long enough, on the E-clock.
    answer_by: u64,
    /// The file and its channels; null for the tone.
    acb: ?*AudioCodecBase,
    stream: ?*ac.AudioStream,
    file_channels: usize,
    file_ended: bool,
    decode_error: i32,
    /// The rate the sound is at, 0 for the tone's: the device's best.
    rate: u32,
    tone_hz: u32,
    phase: f32,
    step: f32,
    seconds: u32,
    /// The samples of each channel to send, 0 for the file's all, and
    /// those made so far.
    total: u64,
    made: u64,
    /// The E-clock at the start - or at the device's start again - the
    /// packets since then, and those sent and let go of.
    start_ticks: u64,
    packet: u64,
    sent: u32,
    dropped: u32,
    /// The most a packet was sent after its time, in E-clock ticks.
    latest: u64,
    /// When the stream may close, once the sound is over.
    end_ticks: u64,
    told_delay: ?u16,
    pcm: [a2dp.pcm_most]i16,
    decoded: [a2dp.pcm_most]i16,

    // --- the time --------------------------------------------------------------

    /// E-clock ticks of `samples` samples at the stream's rate.
    fn ticksOf(player: *const Player, samples: u64) u64 {
        const ticks: u128 = @as(u128, samples) * player.clock.hz / player.media.config.rate;
        return @truncate(ticks);
    }

    /// When packet `number` since the start begins to play.
    fn playsAt(player: *const Player, number: u64) u64 {
        return player.start_ticks +% player.ticksOf(number * player.media.samples);
    }

    /// When packet `number` is sent: `lead` packets before it plays.
    fn sentAt(player: *const Player, number: u64) u64 {
        return player.playsAt(@max(number, lead) - lead);
    }

    /// When the clock is to come back: the command's time up, the next
    /// packet's, the end's; null for none.
    fn wake(player: *const Player) ?u64 {
        var earliest: ?u64 = null;
        if (player.source.awaiting != null and player.answer_by != 0) earliest = player.answer_by;
        const next: ?u64 = switch (player.stage) {
            .playing => player.sentAt(player.packet),
            .ending => player.end_ticks,
            else => null,
        };
        if (next) |ticks| earliest = if (earliest) |other| @min(other, ticks) else ticks;
        return earliest;
    }

    // --- the sound -------------------------------------------------------------

    fn soundOver(player: *const Player) bool {
        if (player.total != 0 and player.made >= player.total) return true;
        return player.file_ended;
    }

    /// The packets whose time has come: sent, or let go of where their
    /// time has gone.
    fn sendDue(player: *Player) void {
        while (player.stage == .playing) {
            const now = player.clock.now();
            if (now < player.sentAt(player.packet)) return;
            if (player.soundOver()) {
                const playout: u64 = player.told_delay orelse playout_default;
                player.end_ticks = player.playsAt(player.packet) +% playout * player.clock.hz / 10_000;
                player.stage = .ending;
                return;
            }
            player.fill();
            player.latest = @max(player.latest, now -% player.sentAt(player.packet));
            if (now >= player.playsAt(player.packet + 1)) {
                player.media.skip();
                player.dropped += 1;
            } else {
                const channel = player.media_channel orelse return player.finish();
                const packet = player.media.packetOf(player.pcm[0 .. player.media.samples * player.media.channels()]);
                if (player.bt.SendBTChannel(channel, packet.ptr, @intCast(packet.len)) == 0) {
                    player.sent += 1;
                } else {
                    player.dropped += 1;
                }
            }
            player.packet += 1;
        }
    }

    /// A packet's samples made: the file's next, or the tone's.
    fn fill(player: *Player) void {
        const samples = player.media.samples;
        const channels = player.media.channels();
        if (player.stream) |stream| {
            const file_channels = player.file_channels;
            var got: usize = 0;
            while (got < samples and !player.file_ended) {
                const decoded = player.acb.?.DecodeAudio(stream, player.decoded[got * file_channels ..].ptr, @intCast(samples - got));
                if (decoded <= 0) {
                    player.file_ended = true;
                    if (decoded < 0) player.decode_error = decoded;
                    break;
                }
                got += @intCast(decoded);
            }
            for (0..samples) |at| {
                const left: i16 = if (at < got) player.decoded[at * file_channels] else 0;
                const right: i16 = if (at < got) player.decoded[at * file_channels + file_channels - 1] else 0;
                if (channels == 2) {
                    player.pcm[at * 2] = left;
                    player.pcm[at * 2 + 1] = right;
                } else {
                    player.pcm[at] = @intCast((@as(i32, left) + right) >> 1);
                }
            }
        } else {
            for (0..samples) |at| {
                const value: i16 = @intFromFloat(tone_level * @sin(player.phase * 2.0 * pi));
                player.phase += player.step;
                if (player.phase >= 1.0) player.phase -= 1.0;
                for (0..channels) |channel| player.pcm[at * channels + channel] = value;
            }
        }
        player.made += samples;
    }

    // --- the signalling --------------------------------------------------------

    /// A frame sent on the signalling channel; a command's answer waited
    /// for from now on.
    fn sendSignal(player: *Player, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const channel = player.signalling orelse return;
        const result = player.bt.SendBTChannel(channel, bytes.ptr, @intCast(bytes.len));
        if (result != 0) {
            _ = Printf(player.dl, "%s: the signalling channel: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), failure(result) });
            player.result = dos.RETURN_ERROR;
            player.stage = .done;
            return;
        }
        if (bytes[0] & 3 == avdtp.AVDTP_COMMAND) player.answer_by = player.clock.now() +% answer_seconds * player.clock.hz;
    }

    /// The channels' messages.
    fn messages(player: *Player) void {
        const sys = player.sys;
        while (sys.GetMsg(player.port)) |message| {
            const told: *bluetooth.BTChannelMessage = @fieldParentPtr("message", message);
            const channel = told.channel;
            switch (told.kind) {
                bluetooth.BTCM_DATA => {
                    if (channel == null or channel != player.signalling or told.data == null) {
                        sys.ReplyMsg(message);
                        continue;
                    }
                    const step = player.source.heard(told.data.?[0..told.length]);
                    sys.ReplyMsg(message);
                    player.sendSignal(step.send);
                    player.outcome(step.outcome);
                },
                bluetooth.BTCM_CLOSED => {
                    const why = told.result;
                    sys.ReplyMsg(message);
                    if (channel != null and channel == player.signalling) {
                        player.signalling = null;
                        player.bt.CloseBTChannel(channel);
                        if (player.stage != .closing and player.stage != .done) {
                            _ = Printf(player.dl, "The device closed the stream's channel (%d)\n", .{why});
                            player.result = dos.RETURN_ERROR;
                        }
                        player.stage = .done;
                    } else if (channel != null and channel == player.media_channel) {
                        player.media_channel = null;
                        player.bt.CloseBTChannel(channel);
                        if (player.stage != .closing and player.stage != .done) {
                            _ = player.dl.PutStr("The device closed the media channel\n");
                            player.result = dos.RETURN_ERROR;
                            player.finish();
                        }
                    }
                },
                else => sys.ReplyMsg(message),
            }
        }
    }

    /// What came of a frame, or of a command given up on.
    fn outcome(player: *Player, what: a2dp.source.Outcome) void {
        switch (what) {
            // The device configures nothing here: the end point is not
            // served to it.
            .none, .configured, .device_opened => {},
            .delay => player.sayDelay(),
            .opened => player.opened(),
            .started => player.started(),
            .suspended => if (player.stage == .playing) {
                _ = player.dl.PutStr("The device suspended the stream\n");
                player.stage = .paused;
            },
            .closed => {
                if (player.stage != .closing and player.stage != .done) {
                    _ = player.dl.PutStr("The device closed the stream\n");
                    player.result = dos.RETURN_ERROR;
                }
                player.stage = .done;
            },
            .failed => {
                player.sayWhy();
                player.result = dos.RETURN_ERROR;
                player.finish();
            },
        }
    }

    /// The stream open: its media channel opened, the configuration said,
    /// the stream started.
    fn opened(player: *Player) void {
        const result = player.bt.OpenBTChannel(player.controller, &player.address, l2cap.PSM_AVDTP, player.port, &player.media_channel);
        if (result != 0) {
            _ = Printf(player.dl, "%s: the media channel: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), failure(result) });
            player.result = dos.RETURN_ERROR;
            return player.finish();
        }
        const mtu = player.media_channel.?.mtu_out;
        if (!player.media.init(player.source.config, mtu)) {
            _ = Printf(player.dl, "%s: the device takes media packets of %u bytes, too few for a frame\n", .{ @as([*:0]const u8, COMMAND_NAME), @as(u32, mtu) });
            player.result = dos.RETURN_ERROR;
            return player.finish();
        }
        player.sayConfiguration(mtu);
        const rate = player.media.config.rate;
        player.step = @as(f32, @floatFromInt(player.tone_hz)) / @as(f32, @floatFromInt(rate));
        player.total = @as(u64, player.seconds) * rate;
        player.sendSignal(player.source.start());
    }

    fn started(player: *Player) void {
        switch (player.stage) {
            .setting_up => _ = player.dl.PutStr("Playing; CTRL-C stops\n"),
            .paused => _ = player.dl.PutStr("The device started the stream again\n"),
            else => return,
        }
        player.stage = .playing;
        player.start_ticks = player.clock.now();
        // The packets counted from this start on.
        player.packet = 0;
    }

    /// The stream closed - CLOSE, ABORT, or nothing where the device has
    /// no part of it yet - and the command done once it is.
    fn finish(player: *Player) void {
        if (player.stage == .closing or player.stage == .done) return;
        const step = player.source.close();
        player.stage = .closing;
        player.sendSignal(step.send);
        if (player.source.phase == .closed) player.stage = .done;
    }

    /// The command out given up on, where its time is up.
    fn timeouts(player: *Player) void {
        if (player.source.awaiting == null or player.answer_by == 0) return;
        if (player.clock.now() < player.answer_by) return;
        player.answer_by = 0;
        const what = player.source.timedOut();
        if (player.stage == .closing and what == .closed) {
            player.stage = .done;
            return;
        }
        player.outcome(what);
    }

    // --- what is said ----------------------------------------------------------

    fn sayConfiguration(player: *Player, mtu: u16) void {
        const config = player.media.config;
        const mode: [*:0]const u8 = switch (config.mode) {
            .mono => "mono",
            .dual_channel => "dual channel",
            .stereo => "stereo",
            .joint_stereo => "joint stereo",
        };
        const allocation: [*:0]const u8 = if (config.allocation == .snr) "SNR" else "loudness";
        _ = Printf(player.dl, "Sink end point %u: SBC at %u Hz, %s, %u blocks, %u subbands, %s, bitpool %u\n", .{
            @as(u32, player.source.remote_seid), config.rate, mode,                     @as(u32, config.blocks),
            @as(u32, config.subbands),           allocation,  @as(u32, config.bitpool),
        });
        _ = Printf(player.dl, "Frames of %u bytes, %u to a packet (the media channel takes %u bytes), %u kbit/s\n", .{
            @as(u32, @intCast(player.media.frame_length)), @as(u32, @intCast(player.media.frames)), @as(u32, mtu), player.media.bitrate() / 1000,
        });
    }

    fn sayDelay(player: *Player) void {
        const delay = player.source.local.delay orelse return;
        if (player.told_delay != null and player.told_delay.? == delay) return;
        player.told_delay = delay;
        _ = Printf(player.dl, "The device's delay: %u.%u ms\n", .{ @as(u32, delay / 10), @as(u32, delay % 10) });
    }

    fn sayWhy(player: *Player) void {
        const source = &player.source;
        const name: [*:0]const u8 = COMMAND_NAME;
        const signal = signalName(source.why_signal);
        switch (source.why) {
            .none => {},
            .timeout => _ = Printf(player.dl, "%s: the device did not answer %s\n", .{ name, signal }),
            .refused => _ = Printf(player.dl, "%s: the device refused %s: %s\n", .{ name, signal, a2dp.signalling.refusalText(source.why_code) }),
            .unknown_command => _ = Printf(player.dl, "%s: the device does not know %s\n", .{ name, signal }),
            .no_sink => _ = Printf(player.dl, "%s: the device plays no sound - it has no audio sink, or none free\n", .{name}),
            .no_sbc => _ = Printf(player.dl, "%s: none of the device's audio sinks takes SBC\n", .{name}),
            .no_configuration => if (source.why_code != 0) {
                _ = Printf(player.dl, "%s: the device refused each setting it offered, the last for %s\n", .{ name, a2dp.signalling.refusalText(source.why_code) });
            } else if (player.rate != 0) {
                _ = Printf(player.dl, "%s: the device takes no sound at %u Hz\n", .{ name, player.rate });
            } else {
                _ = Printf(player.dl, "%s: the device takes neither 48 nor 44.1 kHz\n", .{name});
            },
        }
    }
};

const pi: f32 = 3.14159265358979;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const name: [*:0]const u8 = COMMAND_NAME;
    const device_text: [*:0]const u8 = @ptrFromInt(argv[arg_device]);
    const bytes = parseAddress(device_text) orelse {
        _ = Printf(dl, "%s: %s is not an address (00:00:5E:EF:10:01)\n", .{ name, device_text });
        return dos.RETURN_ERROR;
    };
    if (argv[arg_file] != 0 and argv[arg_tone] != 0) {
        _ = Printf(dl, "%s: FILE or TONE, not both\n", .{name});
        return dos.RETURN_ERROR;
    }
    const tone_hz: i32 = dos.rdargs.number(argv[arg_tone]) orelse tone_default;
    if (tone_hz < 20 or tone_hz > 20_000) {
        _ = Printf(dl, "%s: a tone of 20 to 20000 Hz\n", .{name});
        return dos.RETURN_ERROR;
    }
    const seconds_given = dos.rdargs.number(argv[arg_seconds]);
    if (seconds_given) |seconds| if (seconds <= 0) {
        _ = Printf(dl, "%s: SECONDS takes a number above 0\n", .{name});
        return dos.RETURN_ERROR;
    };

    const bt_lib = sys.OpenLibrary(bluetooth.BLUETOOTHNAME, 1) orelse {
        _ = Printf(dl, "no %s\n", .{@as([*:0]const u8, bluetooth.BLUETOOTHNAME)});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(bt_lib);

    const player: *Player = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(Player), exec.MEMF_CLEAR) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }));
    defer sys.FreeVec(player);
    player.sys = sys;
    player.dl = dl;
    player.bt = @ptrCast(bt_lib);
    player.controller = if (dos.rdargs.number(argv[arg_controller])) |value| @bitCast(value) else bluetooth.BT_ALL_CONTROLLERS;
    player.address = .{ .bytes = bytes };
    player.signalling = null;
    player.media_channel = null;
    player.source = .{};
    player.stage = .setting_up;
    player.result = dos.RETURN_OK;
    player.answer_by = 0;
    player.acb = null;
    player.stream = null;
    player.file_ended = false;
    player.decode_error = 0;
    player.rate = 0;
    player.tone_hz = @intCast(tone_hz);
    player.phase = 0;
    player.step = 0;
    player.seconds = if (seconds_given) |seconds| @intCast(seconds) else if (argv[arg_file] != 0) 0 else seconds_default;
    player.made = 0;
    player.packet = 0;
    player.sent = 0;
    player.dropped = 0;
    player.latest = 0;
    player.told_delay = null;

    // The file, and the rate it fixes.
    var codec_lib: ?*exec.Library = null;
    defer if (codec_lib) |library| sys.CloseLibrary(library);
    if (argv[arg_file] != 0) {
        const file: [*:0]const u8 = @ptrFromInt(argv[arg_file]);
        codec_lib = sys.OpenLibrary(ac.AUDIOCODECNAME, 1) orelse {
            _ = Printf(dl, "%s: no %s\n", .{ name, @as([*:0]const u8, ac.AUDIOCODECNAME) });
            return dos.RETURN_FAIL;
        };
        const acb: *AudioCodecBase = @ptrCast(codec_lib.?);
        var err: i32 = 0;
        player.stream = acb.OpenAudioStream(&[_]utility.TagItem{
            .{ .tag = ac.ACA_Name, .data = @intFromPtr(file) },
            .{},
        }, &err) orelse {
            _ = Printf(dl, "%s: %s: %s\n", .{ name, file, acb.AudioErrorText(err) });
            return dos.RETURN_ERROR;
        };
        player.acb = acb;
        var info: ac.AudioStreamInfo = .{};
        acb.GetAudioStreamInfo(player.stream.?, &info);
        if (info.channels < 1 or info.channels > 2) {
            _ = Printf(dl, "%s: %s has %u channels; one or two are sent\n", .{ name, file, info.channels });
            acb.CloseAudioStream(player.stream);
            return dos.RETURN_ERROR;
        }
        player.file_channels = info.channels;
        player.rate = info.rate;
        _ = Printf(dl, "%s: %u Hz, %s\n", .{ file, info.rate, @as([*:0]const u8, if (info.channels == 2) "stereo" else "mono") });
    }
    defer if (player.acb) |acb| acb.CloseAudioStream(player.stream);

    player.port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(player.port);
    const clock_port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(clock_port);
    player.clock = .{ .port = clock_port, .device = undefined, .hz = 0 };
    player.clock.io.node.message.reply_port = clock_port;
    player.clock.io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_WAITECLOCK, &player.clock.io.node, 0) != 0) {
        _ = Printf(dl, "%s: no timer.device\n", .{name});
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&player.clock.io.node);
    player.clock.device = @ptrCast(player.clock.io.node.device.?);
    var now: timer.EClockVal = .{};
    player.clock.hz = player.clock.device.ReadEClock(&now);

    const result = run(player);
    player.clock.cancel(sys);
    close(player.bt, &player.media_channel);
    close(player.bt, &player.signalling);
    return result;
}

/// The stream opened, played and closed.
fn run(player: *Player) i32 {
    const sys = player.sys;
    const dl = player.dl;
    var shown: [18]u8 = undefined;
    _ = Printf(dl, "Opening the stream to %s\n", .{addressText(&player.address.bytes, &shown)});
    var tries: u32 = 1;
    while (true) : (tries += 1) {
        const opened = player.bt.OpenBTChannel(player.controller, &player.address, l2cap.PSM_AVDTP, player.port, &player.signalling);
        if (opened == 0) break;
        if (opened != bluetooth.BTERR_REFUSED or tries == open_tries) {
            _ = Printf(dl, "%s: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), failure(opened) });
            return dos.RETURN_ERROR;
        }
        _ = dl.PutStr("The device refused the channel; trying again\n");
        player.clock.at(sys, player.clock.now() +% open_pause_seconds * player.clock.hz);
        const got = sys.Wait(player.clock.port.sigMask() | exec.SIGBREAKF_CTRL_C);
        player.clock.check(sys);
        if (got & exec.SIGBREAKF_CTRL_C != 0) {
            _ = dl.PutStr("***Break\n");
            return dos.RETURN_WARN;
        }
    }
    player.sendSignal(player.source.begin(player.rate));
    const signals = player.port.sigMask() | player.clock.port.sigMask() | exec.SIGBREAKF_CTRL_C;
    while (player.stage != .done) {
        player.sendDue();
        if (player.stage == .ending and player.clock.now() >= player.end_ticks) player.finish();
        if (player.stage == .done) break;
        if (player.wake()) |ticks| player.clock.at(sys, ticks) else player.clock.cancel(sys);
        const got = sys.Wait(signals);
        if (got & exec.SIGBREAKF_CTRL_C != 0) {
            if (player.stage == .closing) break;
            _ = dl.PutStr("***Break\n");
            player.result = dos.RETURN_WARN;
            player.finish();
        }
        player.messages();
        player.clock.check(sys);
        player.timeouts();
    }
    if (player.decode_error != 0) {
        _ = Printf(dl, "%s: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), player.acb.?.AudioErrorText(player.decode_error) });
        if (player.result == dos.RETURN_OK) player.result = dos.RETURN_ERROR;
    }
    if (player.sent != 0 or player.dropped != 0) {
        const tenths: u32 = @intCast(@min(player.latest * 10_000 / player.clock.hz, 0xFFFF_FFFF));
        _ = Printf(dl, "%u packets sent, %u dropped; the latest left %u.%u ms after its time\n", .{ player.sent, player.dropped, tenths / 10, tenths % 10 });
    }
    return player.result;
}

fn signalName(signal: u8) [*:0]const u8 {
    return switch (signal) {
        avdtp.AVDTP_DISCOVER => "DISCOVER",
        avdtp.AVDTP_GET_CAPABILITIES => "GET_CAPABILITIES",
        avdtp.AVDTP_SET_CONFIGURATION => "SET_CONFIGURATION",
        avdtp.AVDTP_GET_CONFIGURATION => "GET_CONFIGURATION",
        avdtp.AVDTP_RECONFIGURE => "RECONFIGURE",
        avdtp.AVDTP_OPEN => "OPEN",
        avdtp.AVDTP_START => "START",
        avdtp.AVDTP_CLOSE => "CLOSE",
        avdtp.AVDTP_SUSPEND => "SUSPEND",
        avdtp.AVDTP_ABORT => "ABORT",
        avdtp.AVDTP_SECURITY_CONTROL => "SECURITY_CONTROL",
        avdtp.AVDTP_GET_ALL_CAPABILITIES => "GET_ALL_CAPABILITIES",
        avdtp.AVDTP_DELAYREPORT => "DELAYREPORT",
        else => "a command",
    };
}

fn close(bt: *BluetoothBase, slot: *?*bluetooth.BTChannel) void {
    const channel = slot.* orelse return;
    slot.* = null;
    bt.CloseBTChannel(channel);
}

fn failure(result: i32) [*:0]const u8 {
    return switch (result) {
        bluetooth.BTERR_NOMEM => "no memory, or no room for another channel",
        bluetooth.BTERR_NOCONTROLLER => "no Bluetooth controller",
        bluetooth.BTERR_NOTUP => "the controller is not up",
        bluetooth.BTERR_OFF => "the controller is off (Bluetooth POWER ON)",
        bluetooth.BTERR_REFUSED => "the device refused the channel - is it bonded with this machine?",
        bluetooth.BTERR_UNSUPPORTED => "the device takes no AVDTP channel: it plays no sound",
        bluetooth.BTERR_BUSY => "the device has no room for another channel, or the controller is busy",
        bluetooth.BTERR_TIMEOUT => "the device did not answer in time",
        bluetooth.BTERR_PROTOCOL => "the device's answer made no sense",
        bluetooth.BTERR_DETACHED => "the controller has gone",
        bluetooth.BTERR_NOTCONNECTED => "the link to the device is gone",
        bluetooth.BTERR_TOOLONG => "a frame too long for the channel",
        else => if (result > 0) "the link could not be made - is the device on, near, and free?" else "it failed",
    };
}

/// An address as it is written, the most significant byte first.
fn addressText(address: *const [6]u8, into: *[18]u8) [*:0]const u8 {
    const hex = "0123456789ABCDEF";
    for (0..6) |index| {
        const octet = address[5 - index];
        into[index * 3] = hex[octet >> 4];
        into[index * 3 + 1] = hex[octet & 0xF];
        into[index * 3 + 2] = if (index == 5) 0 else ':';
    }
    return @ptrCast(into);
}

/// An address written as six pairs of hexadecimal digits with colons,
/// the most significant first; null for anything else.
fn parseAddress(text_address: [*:0]const u8) ?[6]u8 {
    var bytes: [6]u8 = undefined;
    var at: usize = 0;
    for (0..6) |index| {
        var octet: u8 = 0;
        for (0..2) |_| {
            const char = text_address[at];
            const digit: u8 = switch (char) {
                '0'...'9' => char - '0',
                'a'...'f' => char - 'a' + 10,
                'A'...'F' => char - 'A' + 10,
                else => return null,
            };
            octet = octet << 4 | digit;
            at += 1;
        }
        bytes[5 - index] = octet;
        if (index < 5) {
            if (text_address[at] != ':') return null;
            at += 1;
        }
    }
    return if (text_address[at] == 0) bytes else null;
}
