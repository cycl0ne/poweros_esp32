// SPDX-License-Identifier: MIT
//! bluetooth/btaudio.device: Bluetooth headphones and speakers as sound
//! outputs. A profile driver (sdk/devices/btprofile.zig): bluetooth.library
//! offers it the audio sink service of each device this machine is bonded
//! with over BR/EDR, and while a stream to one is open the device is a
//! sink of rta.library, driver "btaudio", that audio.device plays through
//! as it plays through a board's codec. The stream is SBC over AVDTP - the
//! inner module a2dp: the codec, the signalling, the media packets - with
//! this machine its source.
//!
//! **The stream** is made by whichever side begins. A headphone switched
//! on reaches this machine, opens AVDTP's signalling channel (PSM 25,
//! served while the driver drives a device, only over a link encrypted
//! with the bond's key), configures the source's end point - SBC at
//! 48 kHz, the one rate it offers - opens the stream and opens its media
//! channel. A device that leaves that to the source is reached two
//! seconds after its link comes up: the signalling channel opened from
//! here, the device's audio sink found and configured at 48 kHz, the
//! stream opened and its media channel with it. A device that refuses the
//! channel - one opening its own to this machine meanwhile - is asked
//! again two seconds later, four times in all. The source's record
//! (an Audio Source, a player) is served while the driver drives a device,
//! so that a device looking for one finds it.
//!
//! **The sink** is there while the stream is open: made once its media
//! channel is, named as the device's bond names it, and deleted once the
//! stream or its link ends - audio.device moves to the next output before
//! it goes. It has one mode, 48 kHz stereo, a mono stream sent as the two
//! sides' mean. It comes after the board's own outputs (priority -20):
//! it is played through where it is the preferred output (C:Audio PREFER,
//! audio.prefs), where it is chosen (C:Audio OUTPUT), or where nothing
//! above it is there.
//!
//! **Playing.** audio.device's task is given a buffer of 512 frames each
//! time one would have played - on timer.device's E-clock, counted from
//! the start, and one it was late for at once, 16 at the most, so that
//! the sound stays whole - and hands it back filled; the sink puts it in
//! a ring of 32
//! and signals the driver's task, which gathers the frames into packets -
//! as many SBC frames as the media channel takes - and sends them. The
//! stream is started when a buffer that is not silence comes, the ring
//! holding what comes meanwhile, which is sent once it has; it is
//! suspended after five seconds without sound - stopped by audio.device,
//! the sink hands over nothing, and that is silence too. A device that
//! suspends the stream itself, or refuses to start it, is left so until a
//! new sound begins after a second of silence. A buffer that finds the
//! ring full is let go of.
//!
//! **One task for every device.** The channels' messages, the listener's,
//! the commands, the sinks' signal and the controllers' changes come to
//! one task, which opens, reads and closes every channel, and makes and
//! deletes every sink. Binding runs on bluetooth.library's binder: the
//! device's memory taken, the task told. Unbinding is a command to the
//! task, waited for: the sink deleted - waited for, as audio.device stops
//! it first where it plays through it - the channels closed, the memory
//! freed; the listener and the record go with the last device. The task
//! waits while it opens a channel - OpenBTChannel - and every device's
//! stream waits with it.
//!
//! The device's own units are none: bluetooth.library opens it on
//! `BTPROFILE_UNIT_BIND` for its two calls. It stays once loaded.

const std = @import("std");
const sdk = @import("sdk");
const a2dp = @import("a2dp");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const avdtp = bluetooth.avdtp;
const sdp = bluetooth.sdp;
const l2cap = bluetooth.l2cap;
const btprofile = sdk.devices.btprofile;
const timer = sdk.devices.timer;
const rta = sdk.rta;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const devices = sdk.expansion.devices;
const ExecBase = sdk.interface.exec.ExecBase;
const BluetoothBase = sdk.interface.bluetooth.BluetoothBase;
const RtaBase = sdk.interface.rta.RtaBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const TimerBase = sdk.interface.timer.TimerBase;
const err = rta.errors;
const signalling = a2dp.signalling;
const sbc = a2dp.sbc;

pub const DEVICE_NAME = "btaudio.device";
const DRIVER_NAME = "btaudio";
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "23.11.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// The most devices driven at once.
const max_devices = 4;
/// The standard stack: 32 KiB on a 64-bit machine, 16 KiB on a 32-bit one.
const stack_size = 4096 * @sizeOf(usize);
/// Above dos's processes: the packets go out while a program computes.
const task_pri = 10;

/// The rate every stream runs at: one every audio sink takes.
const rate: u32 = 48_000;
/// A buffer audio.device fills - 512 frames, 10.7 ms - and the buffers
/// the ring holds for the task: 341 ms.
const buffer_frames: u32 = 512;
const buffer_samples = buffer_frames * 2;
const sink_buffers: u32 = 2;
const ring_slots = 32;
/// The buffers held while the stream starts or is suspended, the oldest
/// let go of past them: room for audio.device's next.
const ring_kept = ring_slots - 2;
/// The buffers audio.device is given at once where it was late for them,
/// 171 ms of sound - the older ones let go of: the ring takes them, the
/// packets go out as they fill and the device's own buffer evens them
/// out.
const catch_up: u32 = 16;
/// After the board's own outputs, above the null one.
const priority: i8 = -20;
/// The bytes of a name rta.library keeps, with its NUL.
const name_len = 32;

/// How long a device whose link came up is given to open the stream
/// itself; the tries at the signalling channel from here, and the pause
/// between them.
const open_wait_ms = 2000;
const open_tries = 4;
const open_pause_ms = 2000;
/// How long a command waits for its answer, and the device's media
/// channel for the device after its OPEN.
const answer_ms = 4000;
const media_wait_ms = 4000;
/// Without sound this long a stream is suspended; with silence this long
/// a device's own suspension is over.
const idle_ms = 5000;
const hold_ms = 1000;

/// A sink's tag, this driver's own: the device it plays to.
const BTA_Headphone = utility.TAG_USER | 0x4254;

const Kind = enum(u32) { bound, unbind };

/// A command to the task, about one device: `bound` one-way, `unbind`
/// replied once it is done - or, the device's own, one-way too.
const Command = extern struct {
    message: exec.Message = .{},
    kind: Kind = .bound,
    flags: u32 = 0,
    device: ?*anyopaque = null,
};

/// The time a started sink keeps, on audio.device's task: the port its
/// request comes back to - that task's, on its own signal - the request,
/// and the E-clock at the start, its rate and the buffers played since.
const Clock = struct {
    port: exec.MsgPort = .{},
    timer_io: timer.TimeRequest = .{},
    /// The request is with the device.
    waiting: bool = false,
    start_ticks: u64 = 0,
    eclock_hz: u64 = 0,
    played: u64 = 0,
};

/// A device driven: the audio sink service of a bonded device. Its fields
/// are the task's, but for the sink's part, which audio.device's task
/// uses while the sink is there.
const Headphone = struct {
    base: *Base,
    /// The device, as the binding names it, and its name as its bond has
    /// it.
    controller: u32,
    address: bluetooth.BTAddress,
    name: [name_len]u8,
    /// The command that tells the task of the device, sent once; and the
    /// one that lets go of it where its unbinding cannot wait for it.
    bound: Command,
    unbind: Command,
    /// Told of: the task drives it.
    driven: bool,
    /// AVDTP's channels while they are open.
    signalling_channel: ?*bluetooth.BTChannel,
    media_channel: ?*bluetooth.BTChannel,
    /// The stream's signalling, and its media packets.
    source: a2dp.Source,
    media: a2dp.Media,
    /// Its link was up at the last look.
    linked: bool,
    /// When the signalling channel is opened from here, 0 for not, and
    /// the tries since its link came up.
    open_at: u64,
    tries: u32,
    /// When the command out is given up on, and the device's media
    /// channel; 0 for neither.
    answer_by: u64,
    media_by: u64,
    /// When a buffer that was not silence was last sent - or the stream
    /// started; when the silence began since a suspension of the
    /// device's own, 0 during a sound; whether that suspension holds.
    last_sound: u64,
    quiet_since: u64,
    held: bool,
    /// Since the stream last started: packets sent, and those the channel
    /// would not take; when the last went, and the most E-clock ticks
    /// between two; the sink's missed buffers then.
    sent: u32,
    lost: u32,
    last_sent: u64,
    widest: u64,
    missed_before: u32,
    /// The delay the device reported last that the log has, in tenths of
    /// a millisecond.
    delay_said: u16,

    // The sink's: made and deleted by the task, used by audio.device's.
    sink: ?*rta.AudioSink,
    mode: rta.AudioMode,
    /// Set from the sink's making until its destroy; while audio.device
    /// plays through it; while the task deletes it.
    alive: u8,
    playing: u8,
    leaving: u8,
    /// Buffers that found the ring full.
    overflows: u32,
    clock: Clock,
    frames: [buffer_samples]i16,
    ring: a2dp.Ring(ring_slots, buffer_samples),
};

const BtAudioBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    bt_base: ?*BluetoothBase = null,
    rta_base: ?*RtaBase = null,
    utility_base: ?*UtilityBase = null,
    driver: rta.RtaDriver = .{},
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    /// The task's ports: the channels' and the listener's messages, the
    /// commands, and its timer's request.
    port: ?*exec.MsgPort = null,
    command_port: ?*exec.MsgPort = null,
    timer_port: ?*exec.MsgPort = null,
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    /// The task's own signals: the sinks' - a buffer handed over, a sink
    /// started or stopped - a sink gone, the controllers changed.
    sound_signal: i8 = -1,
    gone_signal: i8 = -1,
    notify_signal: i8 = -1,
    /// The task got all it needs.
    ready: bool = false,
    /// The task's timer: its request, whether it is out and for when,
    /// and the E-clock's rate.
    timer_out: bool = false,
    timer_io: timer.TimeRequest = .{},
    timer_at: u64 = 0,
    eclock_hz: u64 = 0,
    /// The task's: the controllers' changes told; while it drives a
    /// device, the listener on PSM 25 and the record served.
    notify: ?*bluetooth.BTNotify = null,
    listener: ?*bluetooth.BTListener = null,
    record: ?*bluetooth.BTRecord = null,
    /// The devices driven, a slot each: added by the binder (a bind),
    /// taken by the task (an unbind), under the lock.
    devices: [max_devices]?*anyopaque = @splat(null),
    lock: exec.SignalSemaphore = .{},
};

const Base = BtAudioBase;

fn baseOf(dev: *exec.Device) *Base {
    return @alignCast(@fieldParentPtr("dev", dev));
}

fn headphoneOf(raw: ?*anyopaque) ?*Headphone {
    return @ptrCast(@alignCast(raw orelse return null));
}

fn bit(signal: i8) u32 {
    return @as(u32, 1) << @intCast(signal);
}

// --- the record -------------------------------------------------------------------

fn uint16(comptime value: u16) [3]u8 {
    return .{ sdp.DE_UINT << 3 | 1, value >> 8, value & 0xFF };
}
fn uuid16(comptime value: u16) [3]u8 {
    return .{ sdp.DE_UUID << 3 | 1, value >> 8, value & 0xFF };
}
fn text(comptime bytes: []const u8) [2 + bytes.len]u8 {
    return header(sdp.DE_TEXT, bytes.len) ++ bytes[0..bytes.len].*;
}
fn sequence(comptime items: []const u8) [2 + items.len]u8 {
    return header(sdp.DE_SEQUENCE, items.len) ++ items[0..items.len].*;
}
/// A text's or a sequence's descriptor, its length in a byte.
fn header(comptime kind: u8, comptime length: usize) [2]u8 {
    if (length > 0xFF) @compileError("the record's parts are shorter than 256 bytes");
    return .{ kind << 3 | sdp.DE_SIZE_LENGTH8, length };
}
fn attribute(comptime id: u16, comptime value: []const u8) [3 + value.len]u8 {
    return uint16(id) ++ value[0..value.len].*;
}

/// The source's record: an Audio Source reached over AVDTP on PSM 25,
/// the profile and the protocol at 1.3, a player.
const record = sequence(&(attribute(sdp.ATTR_SERVICE_CLASS_ID_LIST, &sequence(&uuid16(avdtp.UUID_AUDIO_SOURCE))) ++
    attribute(sdp.ATTR_PROTOCOL_DESCRIPTOR_LIST, &sequence(&(sequence(&(uuid16(sdp.UUID_L2CAP) ++ uint16(l2cap.PSM_AVDTP))) ++ sequence(&(uuid16(avdtp.UUID_AVDTP) ++ uint16(avdtp.AVDTP_VERSION)))))) ++
    attribute(sdp.ATTR_BROWSE_GROUP_LIST, &sequence(&uuid16(sdp.UUID_PUBLIC_BROWSE_ROOT))) ++
    attribute(sdp.ATTR_LANGUAGE_BASE_LIST, &sequence(&(uint16(0x656E) ++ uint16(0x006A) ++ uint16(0x0100)))) ++
    attribute(sdp.ATTR_PROFILE_DESCRIPTOR_LIST, &sequence(&sequence(&(uuid16(avdtp.UUID_ADVANCED_AUDIO) ++ uint16(avdtp.A2DP_VERSION))))) ++
    attribute(sdp.ATTR_SERVICE_NAME, &text("Audio Source")) ++
    attribute(avdtp.ATTR_SUPPORTED_FEATURES, &uint16(avdtp.A2DP_SOURCE_PLAYER))));

// --- the task ---------------------------------------------------------------------

fn btAudioTask(sys: *ExecBase) callconv(.c) void {
    const base: *Base = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    base.ready = setUpTask(base);
    started(base);
    if (!base.ready) return;
    const port = base.port.?;
    const commands = base.command_port.?;
    const timer_port = base.timer_port.?;
    const signals = port.sigMask() | commands.sigMask() | timer_port.sigMask() | bit(base.sound_signal) | bit(base.notify_signal);
    while (true) {
        const got = sys.Wait(signals);
        checkTimer(base);
        while (sys.GetMsg(commands)) |message| {
            // Read first: a one-way unbind is in the memory it frees.
            const command: *Command = @fieldParentPtr("message", message);
            const replied = message.reply_port != null;
            const kind = command.kind;
            const flags = command.flags;
            if (headphoneOf(command.device)) |device| switch (kind) {
                .bound => drive(base, device),
                .unbind => letGo(base, device, flags),
            };
            if (replied) sys.ReplyMsg(message);
        }
        while (sys.GetMsg(port)) |message| {
            const told: *bluetooth.BTChannelMessage = @fieldParentPtr("message", message);
            heard(base, told);
        }
        if (got & bit(base.notify_signal) != 0) links(base);
        var driven: [max_devices]?*Headphone = undefined;
        snapshot(base, &driven);
        for (driven) |slot| {
            if (slot) |device| tend(base, device);
        }
        wakeAt(base, nextWake(base));
    }
}

/// The task's ports, signals and timer, and the controllers' changes
/// asked for: false where any is missing.
fn setUpTask(base: *Base) bool {
    const sys = base.sys_base;
    base.port = sys.CreateMsgPort();
    base.command_port = sys.CreateMsgPort();
    base.timer_port = sys.CreateMsgPort();
    base.sound_signal = sys.AllocSignal(-1);
    base.gone_signal = sys.AllocSignal(-1);
    base.notify_signal = sys.AllocSignal(-1);
    if (base.port == null or base.command_port == null) return false;
    if (base.sound_signal < 0 or base.gone_signal < 0 or base.notify_signal < 0) return false;
    const timer_port = base.timer_port orelse return false;
    base.timer_io = .{};
    base.timer_io.node.message.reply_port = timer_port;
    base.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_WAITECLOCK, &base.timer_io.node, 0) != 0) return false;
    const device: *TimerBase = @ptrCast(base.timer_io.node.device.?);
    var value: timer.EClockVal = .{};
    base.eclock_hz = device.ReadEClock(&value);
    base.notify = base.bt_base.?.AddBTNotify(&base.task, bit(base.notify_signal));
    return base.notify != null;
}

fn started(base: *Base) void {
    const starter = base.starter orelse return;
    base.starter = null;
    base.sys_base.Signal(starter, bit(base.start_signal));
}

/// The devices the task drives, as they are now.
fn snapshot(base: *Base, into: *[max_devices]?*Headphone) void {
    const sys = base.sys_base;
    sys.ObtainSemaphoreShared(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    for (base.devices, into) |slot, *each| {
        const device = headphoneOf(slot);
        each.* = if (device != null and device.?.driven) device else null;
    }
}

/// The device driven with this address on this controller.
fn findByAddress(base: *Base, controller: u32, address: bluetooth.BTAddress) ?*Headphone {
    var driven: [max_devices]?*Headphone = undefined;
    snapshot(base, &driven);
    for (driven) |slot| {
        const device = slot orelse continue;
        if (device.controller == controller and sameAddress(device.address, address)) return device;
    }
    return null;
}

/// The device whose channel this is.
fn findByChannel(base: *Base, channel: *bluetooth.BTChannel) ?*Headphone {
    var driven: [max_devices]?*Headphone = undefined;
    snapshot(base, &driven);
    for (driven) |slot| {
        const device = slot orelse continue;
        if (device.signalling_channel == channel or device.media_channel == channel) return device;
    }
    return null;
}

// --- the time -----------------------------------------------------------------------

/// The E-clock now.
fn now(base: *Base) u64 {
    const device: *TimerBase = @ptrCast(base.timer_io.node.device.?);
    var value: timer.EClockVal = .{};
    _ = device.ReadEClock(&value);
    return value.toTicks();
}

/// E-clock ticks of `ms` milliseconds.
fn ticksOf(base: *const Base, ms: u64) u64 {
    return ms * base.eclock_hz / 1000;
}

/// The task's request out to come back at `at`, or taken back for none.
fn wakeAt(base: *Base, at: ?u64) void {
    const sys = base.sys_base;
    const ticks = at orelse return cancelTimer(base);
    if (base.timer_out and base.timer_at == ticks) return;
    cancelTimer(base);
    _ = sys.SetSignal(0, base.timer_port.?.sigMask());
    const eclock: *timer.EClockVal = @ptrCast(&base.timer_io.time);
    eclock.* = timer.EClockVal.fromTicks(ticks);
    base.timer_io.node.command = timer.TR_ADDREQUEST;
    sys.SendIO(&base.timer_io.node);
    base.timer_out = true;
    base.timer_at = ticks;
}

fn cancelTimer(base: *Base) void {
    if (!base.timer_out) return;
    const sys = base.sys_base;
    _ = sys.AbortIO(&base.timer_io.node);
    _ = sys.WaitIO(&base.timer_io.node);
    base.timer_out = false;
}

/// The request taken back, where it has come back.
fn checkTimer(base: *Base) void {
    const sys = base.sys_base;
    if (!base.timer_out or sys.CheckIO(&base.timer_io.node) == null) return;
    _ = sys.WaitIO(&base.timer_io.node);
    base.timer_out = false;
}

/// When the task is next to look: a channel to open, a command or a
/// media channel given up on, a stream without sound to suspend.
fn nextWake(base: *Base) ?u64 {
    var driven: [max_devices]?*Headphone = undefined;
    snapshot(base, &driven);
    var earliest: ?u64 = null;
    for (driven) |slot| {
        const device = slot orelse continue;
        const source = &device.source;
        var times: [4]u64 = @splat(0);
        if (device.signalling_channel == null) times[0] = device.open_at;
        if (source.waiting()) times[1] = device.answer_by;
        times[2] = device.media_by;
        if (source.phase == .streaming and !source.waiting()) times[3] = device.last_sound +% ticksOf(base, idle_ms);
        for (times) |ticks| {
            if (ticks == 0) continue;
            earliest = if (earliest) |other| @min(other, ticks) else ticks;
        }
    }
    return earliest;
}

// --- the channels -------------------------------------------------------------------

/// A message about a channel: a device's channel to the listener, a
/// frame, a channel's end. Replied - a frame once it is read, since its
/// bytes are the library's until then - before anything closes the
/// channel.
fn heard(base: *Base, told: *bluetooth.BTChannelMessage) void {
    const sys = base.sys_base;
    const channel = told.channel orelse return sys.ReplyMsg(&told.message);
    switch (told.kind) {
        bluetooth.BTCM_OPENED => {
            sys.ReplyMsg(&told.message);
            opened(base, channel);
        },
        bluetooth.BTCM_DATA => {
            const device = findByChannel(base, channel) orelse return sys.ReplyMsg(&told.message);
            const data = told.data orelse return sys.ReplyMsg(&told.message);
            if (channel != device.signalling_channel) return sys.ReplyMsg(&told.message);
            const step = device.source.heard(data[0..told.length]);
            sys.ReplyMsg(&told.message);
            send(base, device, step.send);
            outcome(base, device, step.outcome, step.device);
        },
        bluetooth.BTCM_CLOSED => {
            sys.ReplyMsg(&told.message);
            closed(base, channel);
        },
        else => sys.ReplyMsg(&told.message),
    }
}

/// A device's channel to the listener: its signalling channel where it
/// has none - the device makes the stream, or leaves it to this side -
/// its media channel where its stream waits for one; closed again where
/// it is neither, or the device is not one driven.
fn opened(base: *Base, channel: *bluetooth.BTChannel) void {
    const bt = base.bt_base.?;
    const device = findByAddress(base, channel.controller, channel.address) orelse {
        say(base, "%s: %02x:%02x:%02x:%02x:%02x:%02x is no device it drives: its channel closed\n", channel.address, .{});
        return bt.CloseBTChannel(channel);
    };
    if (device.signalling_channel == null) {
        device.signalling_channel = channel;
        device.open_at = 0;
        device.source.reset();
        return;
    }
    if (device.media_by != 0 and device.media_channel == null) {
        device.media_by = 0;
        device.media_channel = channel;
        return streamOpen(base, device);
    }
    // A second signalling channel - the device's, opened as this side
    // opened its own - or a media channel nothing waits for.
    bt.CloseBTChannel(channel);
}

/// A channel the device or its link ended: the signalling channel ends
/// the stream with it; the media channel the stream, which is closed.
fn closed(base: *Base, channel: *bluetooth.BTChannel) void {
    if (findByChannel(base, channel)) |device| {
        if (channel == device.signalling_channel) {
            device.signalling_channel = null;
            streamEnded(base, device);
            device.source.reset();
            device.answer_by = 0;
        } else if (channel == device.media_channel) {
            device.media_channel = null;
            closeStream(base, device);
        }
    }
    base.bt_base.?.CloseBTChannel(channel);
}

/// A frame sent on the signalling channel; a command's answer waited for
/// from now on. One the channel does not take is let go of: the channel
/// is closing, and says so.
fn send(base: *Base, device: *Headphone, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const channel = device.signalling_channel orelse return;
    if (bytes[0] & 3 == avdtp.AVDTP_COMMAND) device.answer_by = now(base) +% ticksOf(base, answer_ms);
    _ = base.bt_base.?.SendBTChannel(channel, bytes.ptr, @intCast(bytes.len));
}

/// The signalling channel opened from here, the stream set up on it at
/// 48 kHz; asked again two seconds later where the device refuses it
/// or the controller is busy, `open_tries` times in all.
fn openFromHere(base: *Base, device: *Headphone) void {
    device.open_at = 0;
    device.tries += 1;
    var channel: ?*bluetooth.BTChannel = null;
    const result = base.bt_base.?.OpenBTChannel(device.controller, &device.address, l2cap.PSM_AVDTP, base.port.?, &channel);
    if (result == 0) {
        device.signalling_channel = channel;
        device.source.reset();
        return send(base, device, device.source.begin(rate));
    }
    // The device's own channel may be on the port: it is taken there.
    if ((result == bluetooth.BTERR_REFUSED or result == bluetooth.BTERR_BUSY) and device.tries < open_tries) {
        device.open_at = now(base) +% ticksOf(base, open_pause_ms);
        return;
    }
    say(base, "%s: %02x:%02x:%02x:%02x:%02x:%02x: no stream: its channel not opened (%ld)\n", device.address, .{@as(i64, result)});
}

/// The media channel opened from here, after the stream's OPEN.
fn openMedia(base: *Base, device: *Headphone) void {
    var channel: ?*bluetooth.BTChannel = null;
    const result = base.bt_base.?.OpenBTChannel(device.controller, &device.address, l2cap.PSM_AVDTP, base.port.?, &channel);
    if (result != 0) {
        say(base, "%s: %02x:%02x:%02x:%02x:%02x:%02x: its media channel not opened (%ld)\n", device.address, .{@as(i64, result)});
        return closeStream(base, device);
    }
    device.media_channel = channel;
    streamOpen(base, device);
}

// --- the stream ---------------------------------------------------------------------

/// What came of a frame of the signalling channel, or of a command given
/// up on; `by_device` where it was the device's own command.
fn outcome(base: *Base, device: *Headphone, what: a2dp.source.Outcome, by_device: bool) void {
    switch (what) {
        .none, .configured => {},
        .delay => if (device.source.local.delay) |delay| if (delay != device.delay_said) {
            device.delay_said = delay;
            sayAt(base, exec.LOG_DEBUG, "%s: %02x:%02x:%02x:%02x:%02x:%02x: its delay %ld.%ld ms\n", device.address, .{ @as(i64, delay / 10), @as(i64, delay % 10) });
        },
        .device_opened => device.media_by = now(base) +% ticksOf(base, media_wait_ms),
        .opened => openMedia(base, device),
        .started => {
            device.last_sound = now(base);
            device.held = false;
            device.sent = 0;
            device.lost = 0;
            device.last_sent = 0;
            device.widest = 0;
            device.missed_before = if (device.sink) |sink| sink.underruns else 0;
            sayAt(base, exec.LOG_DEBUG, "%s: %02x:%02x:%02x:%02x:%02x:%02x: playing, %ld buffers waiting\n", device.address, .{@as(i64, device.ring.waiting())});
        },
        .suspended => if (by_device) {
            tally(base, device);
            hold(device);
        },
        .closed => streamEnded(base, device),
        .failed => failed(base, device),
    }
}

/// The stream left suspended until a new sound begins after silence.
fn hold(device: *Headphone) void {
    device.held = true;
    device.quiet_since = 0;
}

/// A command refused or given up on: a setup from here ended - the
/// stream closed - or a START held until a new sound, a SUSPEND passed
/// over.
fn failed(base: *Base, device: *Headphone) void {
    const source = &device.source;
    if (source.phase != .failed) {
        // Neither asked again at once: a START once a new sound begins,
        // a SUSPEND after another while without sound.
        if (source.why_signal == avdtp.AVDTP_START) hold(device);
        if (source.why_signal == avdtp.AVDTP_SUSPEND) device.last_sound = now(base);
        return;
    }
    const why: [*:0]const u8 = switch (source.why) {
        .timeout => "it did not answer",
        .refused => signalling.refusalText(source.why_code),
        .unknown_command => "it does not know a command",
        .no_sink => "it has no audio sink free",
        .no_sbc => "none of its sinks takes SBC",
        .no_configuration => "it takes no SBC at 48 kHz",
        .none => "it failed",
    };
    say(base, "%s: %02x:%02x:%02x:%02x:%02x:%02x: no stream: %s\n", device.address, .{why});
    closeStream(base, device);
}

/// The media channel open: its packets set up, the sink made.
fn streamOpen(base: *Base, device: *Headphone) void {
    const channel = device.media_channel.?;
    const config = device.source.config;
    if (!device.media.init(config, channel.mtu_out)) {
        say(base, "%s: %02x:%02x:%02x:%02x:%02x:%02x takes media packets of %ld bytes, too few for a frame\n", device.address, .{@as(i64, channel.mtu_out)});
        return closeStream(base, device);
    }
    const mode: [*:0]const u8 = switch (config.mode) {
        .mono => "mono",
        .dual_channel => "dual channel",
        .stereo => "stereo",
        .joint_stereo => "joint stereo",
    };
    say(base, "%s: %02x:%02x:%02x:%02x:%02x:%02x: SBC at %ld Hz, %s, bitpool %ld, %ld frames a packet, %ld kbit/s\n", device.address, .{
        @as(i64, config.rate),                   mode,                                    @as(i64, config.bitpool),
        @as(i64, @intCast(device.media.frames)), @as(i64, device.media.bitrate() / 1000),
    });
    device.held = false;
    makeSink(base, device);
}

/// The stream ended from here - CLOSE, ABORT, or nothing where the
/// device has no part of it - and its sink and media channel with it at
/// once: nothing plays through it from now on.
fn closeStream(base: *Base, device: *Headphone) void {
    const step = device.source.close();
    send(base, device, step.send);
    streamEnded(base, device);
}

/// The stream gone: its sink deleted, its media channel closed.
fn streamEnded(base: *Base, device: *Headphone) void {
    tally(base, device);
    dropSink(base, device);
    device.media_by = 0;
    if (device.media_channel) |channel| {
        device.media_channel = null;
        base.bt_base.?.CloseBTChannel(channel);
    }
}

/// Each device looked at: a channel to open from here, a command or the
/// device's media channel waited for too long, the sound.
fn tend(base: *Base, device: *Headphone) void {
    if (device.signalling_channel == null) {
        if (device.open_at != 0 and now(base) >= device.open_at) openFromHere(base, device);
    } else {
        if (!device.source.waiting()) device.answer_by = 0;
        if (device.answer_by != 0 and now(base) >= device.answer_by) {
            device.answer_by = 0;
            outcome(base, device, device.source.timedOut(), false);
        }
        if (device.media_by != 0 and now(base) >= device.media_by) {
            say(base, "%s: %02x:%02x:%02x:%02x:%02x:%02x opened no media channel\n", device.address, .{});
            closeStream(base, device);
        }
    }
    pump(base, device);
}

/// The buffers the sink handed over: sent while the stream plays, the
/// stream suspended after `idle_ms` without sound; while it is suspended
/// silence let go of, and the stream started for a sound - held while it
/// starts or suspends, the oldest let go of past `ring_kept`; let go of
/// where there is no stream.
fn pump(base: *Base, device: *Headphone) void {
    const ring = &device.ring;
    const source = &device.source;
    switch (source.phase) {
        .streaming => {
            const channel = device.media_channel orelse return ring.empty();
            if (device.media.samples == 0) return ring.empty();
            const time = now(base);
            while (ring.toRead()) |buffer| {
                if (!a2dp.silent(buffer)) device.last_sound = time;
                sendBuffer(base, device, channel, buffer);
                ring.done();
            }
            if (!source.waiting() and time -% device.last_sound >= ticksOf(base, idle_ms)) {
                tally(base, device);
                send(base, device, source.pause());
            }
        },
        .open => {
            // A sound left from before audio.device stopped the sink is
            // not started for once it plays again; and what plays after a
            // stop is a new sound.
            const playing = @atomicLoad(u8, &device.playing, .acquire) != 0;
            if (!playing) {
                device.held = false;
                return ring.empty();
            }
            const time = now(base);
            while (ring.toRead()) |buffer| {
                const quiet = a2dp.silent(buffer);
                if (device.held) {
                    if (!quiet) {
                        device.quiet_since = 0;
                    } else if (device.quiet_since == 0) {
                        device.quiet_since = time;
                    } else if (time -% device.quiet_since >= ticksOf(base, hold_ms)) {
                        device.held = false;
                    }
                } else if (!quiet) break;
                ring.done();
            }
            if (ring.waiting() != 0 and device.media_channel != null and !source.waiting()) send(base, device, source.start());
        },
        .starting, .suspending => while (ring.waiting() > ring_kept) ring.done(),
        else => ring.empty(),
    }
}

/// What the stream's playing came to, in the log's debug lines: the
/// packets sent and not, the widest gap between two sent, and the buffers
/// audio.device was later for than the sink catches up; counted afresh
/// from the next start.
fn tally(base: *Base, device: *Headphone) void {
    if (device.sent == 0 and device.lost == 0) return;
    const missed: u32 = if (device.sink) |sink| sink.underruns -% device.missed_before else 0;
    const widest_ms = device.widest * 1000 / @max(base.eclock_hz, 1);
    sayAt(base, exec.LOG_DEBUG, "%s: %02x:%02x:%02x:%02x:%02x:%02x: %ld packets sent, %ld not, at most %ld ms apart; %ld buffers missed\n", device.address, .{
        @as(i64, device.sent), @as(i64, device.lost), @as(i64, @intCast(widest_ms)), @as(i64, missed),
    });
    device.sent = 0;
    device.lost = 0;
}

/// A buffer's frames gathered into packets, each sent as it is full.
fn sendBuffer(base: *Base, device: *Headphone, channel: *bluetooth.BTChannel, buffer: *const [buffer_samples]i16) void {
    const bt = base.bt_base.?;
    var at: usize = 0;
    while (at < buffer_frames) {
        at += device.media.gather(buffer[at * 2 ..]);
        // Not full: the buffer's frames all taken, the packet's rest to
        // come with the next.
        if (!device.media.full()) break;
        const packet = device.media.packetGathered();
        if (bt.SendBTChannel(channel, packet.ptr, @intCast(packet.len)) == 0) {
            device.sent +%= 1;
            const time = now(base);
            if (device.last_sent != 0) device.widest = @max(device.widest, time -% device.last_sent);
            device.last_sent = time;
        } else {
            device.lost +%= 1;
        }
    }
}

// --- the links ----------------------------------------------------------------------

/// The controllers changed: a device whose link came up, and has no
/// signalling channel, is given `open_wait_ms` to open its own before it
/// is opened from here.
fn links(base: *Base) void {
    var driven: [max_devices]?*Headphone = undefined;
    snapshot(base, &driven);
    for (driven) |slot| {
        const device = slot orelse continue;
        const up = isLinked(base, device);
        if (up and !device.linked and device.signalling_channel == null) {
            device.open_at = now(base) +% ticksOf(base, open_wait_ms);
            device.tries = 0;
        }
        if (!up) device.open_at = 0;
        device.linked = up;
    }
}

/// Whether the device has a link to its controller.
fn isLinked(base: *Base, device: *const Headphone) bool {
    const bt = base.bt_base.?;
    const list = bt.ObtainBTConnections(device.controller) orelse return false;
    defer bt.ReleaseBTConnections(list);
    var it = list.iterator();
    while (it.next()) |node| {
        const connection: *const bluetooth.BTConnection = @fieldParentPtr("node", node);
        if (sameAddress(connection.address, device.address)) return true;
    }
    return false;
}

fn sameAddress(one: bluetooth.BTAddress, other: bluetooth.BTAddress) bool {
    if (one.kind != other.kind) return false;
    for (one.bytes, other.bytes) |mine, theirs| {
        if (mine != theirs) return false;
    }
    return true;
}

/// A line in the log about a device: the driver's name and the address,
/// most significant first, then `rest`.
fn say(base: *Base, comptime format: [:0]const u8, address: bluetooth.BTAddress, rest: anytype) void {
    exec.kprintf(base.sys_base, format, addressed(address) ++ rest);
}

/// The same at a level of the log's other than information.
fn sayAt(base: *Base, comptime level: u32, comptime format: [:0]const u8, address: bluetooth.BTAddress, rest: anytype) void {
    exec.klog(base.sys_base, level, format, addressed(address) ++ rest);
}

/// The driver's name and the address's bytes, most significant first.
fn addressed(address: bluetooth.BTAddress) struct { [*:0]const u8, u32, u32, u32, u32, u32, u32 } {
    const bytes = address.bytes;
    return .{ DEVICE_NAME, bytes[5], bytes[4], bytes[3], bytes[2], bytes[1], bytes[0] };
}

// --- the devices --------------------------------------------------------------------

/// A device just bound, on the task: named, its end point offered for
/// the device to configure, the listener and the record added with the
/// first, and its channel opened from here before long where it has a
/// link - its pairing has just ended.
fn drive(base: *Base, device: *Headphone) void {
    nameOf(base, device);
    device.source = .{};
    device.source.serve(signalling.served_element);
    device.driven = true;
    if (!serve(base)) say(base, "%s: %02x:%02x:%02x:%02x:%02x:%02x: PSM 25 is served already - its own channels are refused\n", device.address, .{});
    device.linked = isLinked(base, device);
    if (device.linked) {
        device.open_at = now(base) +% ticksOf(base, open_wait_ms);
        device.tries = 0;
    }
    const name: [*:0]const u8 = @ptrCast(&device.name);
    say(base, "%s: %02x:%02x:%02x:%02x:%02x:%02x driven: %s\n", device.address, .{name});
}

/// The device's name as its bond has it, cut before a whole character
/// to what rta.library keeps; "Bluetooth audio" where it has none.
fn nameOf(base: *Base, device: *Headphone) void {
    const bt = base.bt_base.?;
    const fallback = "Bluetooth audio";
    device.name = @splat(0);
    @memcpy(device.name[0..fallback.len], fallback);
    const list = bt.ObtainBTBonds(device.controller) orelse return;
    defer bt.ReleaseBTBonds(list);
    var it = list.iterator();
    while (it.next()) |node| {
        const bond: *const bluetooth.BTBond = @fieldParentPtr("node", node);
        if (!sameAddress(bond.address, device.address)) continue;
        const name = bond.node.name orelse return;
        var length: usize = 0;
        while (name[length] != 0 and length < name_len - 1) length += 1;
        // Not into a character the end would cut.
        if (name[length] != 0) {
            while (length > 0 and name[length] & 0xC0 == 0x80) length -= 1;
        }
        if (length == 0) return;
        device.name = @splat(0);
        @memcpy(device.name[0..length], name[0..length]);
        return;
    }
}

/// The listener on PSM 25 and the source's record, added where they are
/// not: false where the PSM is served by someone else.
fn serve(base: *Base) bool {
    const bt = base.bt_base.?;
    if (base.record == null) base.record = bt.AddBTService(&record, record.len);
    if (base.listener == null) base.listener = bt.AddBTListener(l2cap.PSM_AVDTP, base.port.?, bluetooth.BTLSF_SECURE);
    return base.listener != null;
}

/// A device let go of, on the task: its sink deleted, its channels
/// closed, the media's first, its slot freed - and the listener and the
/// record taken away with the last device. What the listener leaves on
/// the port is read as a device's channel it does not drive: closed.
fn letGo(base: *Base, device: *Headphone, flags: u32) void {
    _ = flags;
    const sys = base.sys_base;
    const bt = base.bt_base.?;
    streamEnded(base, device);
    if (device.signalling_channel) |channel| {
        device.signalling_channel = null;
        bt.CloseBTChannel(channel);
    }
    sys.ObtainSemaphore(&base.lock);
    var left: usize = 0;
    for (&base.devices) |*slot| {
        if (headphoneOf(slot.*) == device) slot.* = null;
        if (slot.* != null) left += 1;
    }
    sys.ReleaseSemaphore(&base.lock);
    say(base, "%s: %02x:%02x:%02x:%02x:%02x:%02x let go of\n", device.address, .{});
    sys.FreeMem(device, @sizeOf(Headphone));
    if (left == 0) {
        bt.RemBTListener(base.listener);
        bt.RemBTService(base.record);
        base.listener = null;
        base.record = null;
    }
}

// --- the sink -----------------------------------------------------------------------

/// The device's sink made, its ring empty: audio.device plays through it
/// where it chooses it.
fn makeSink(base: *Base, device: *Headphone) void {
    if (device.sink != null) return;
    const rb = base.rta_base.?;
    // Nothing writes the ring while there is no sink.
    device.ring.empty();
    device.overflows = 0;
    const tags = [_]TagItem{
        .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr(&device.name) },
        .{ .tag = rta.tags.RTAA_Priority, .data = @bitCast(@as(isize, priority)) },
        .{ .tag = BTA_Headphone, .data = @intFromPtr(device) },
        .{},
    };
    device.sink = rb.CreateSinkTagList(DRIVER_NAME, &tags);
    if (device.sink == null) {
        @atomicStore(u8, &device.alive, 0, .release);
        say(base, "%s: %02x:%02x:%02x:%02x:%02x:%02x: no sink: %s\n", device.address, .{rb.RtaErrorText(rb.RtaLastError())});
    }
}

/// The device's sink deleted, and waited for: where audio.device plays
/// through it, it stops it - moving to the next output - and only then
/// is it destroyed.
fn dropSink(base: *Base, device: *Headphone) void {
    const sink = device.sink orelse return;
    const sys = base.sys_base;
    const gone = bit(base.gone_signal);
    @atomicStore(u8, &device.leaving, 1, .release);
    _ = sys.SetSignal(0, gone);
    base.rta_base.?.DeleteSink(sink);
    while (@atomicLoad(u8, &device.alive, .acquire) != 0) _ = sys.Wait(gone);
    device.sink = null;
    @atomicStore(u8, &device.playing, 0, .release);
    @atomicStore(u8, &device.leaving, 0, .release);
    if (device.overflows != 0) say(base, "%s: %02x:%02x:%02x:%02x:%02x:%02x: %ld buffers found no room\n", device.address, .{@as(i64, device.overflows)});
}

fn sinkHeadphone(sink: *rta.AudioSink) *Headphone {
    const held: **Headphone = @ptrCast(@alignCast(sink.instance.?));
    return held.*;
}

/// The task told: a buffer handed over, the sink started or stopped.
fn wakeTask(device: *Headphone) void {
    const base = device.base;
    base.sys_base.Signal(&base.task, bit(base.sound_signal));
}

/// The sink of the device its tags name: its one mode, 48 kHz stereo.
fn createSink(made_by: *rta.RtaDriver, sink: *rta.AudioSink, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const base: *Base = @alignCast(@fieldParentPtr("driver", made_by));
    const named: ?*Headphone = @ptrFromInt(base.utility_base.?.GetTagData(BTA_Headphone, 0, tag_list));
    const device = named orelse return err.RTAERR_BAD_TAGS;
    const held: **Headphone = @ptrCast(@alignCast(sink.instance.?));
    held.* = device;
    device.mode = .{
        .node = .{ .name = "48000 Hz stereo" },
        .id = 0,
        .rate = rate,
        .bits = 16,
        .channels = 2,
        .sides = rta.AUDIOSIDES_LEFT_FIRST,
        .flags = rta.sinks.AUDIOMF_DEFAULT,
    };
    base.sys_base.AddTail(&sink.modes, &device.mode.node);
    sink.ops = &ops;
    sink.buffer_frames = buffer_frames;
    sink.buffers = sink_buffers;
    @atomicStore(u8, &device.alive, 1, .release);
    return err.RTAERR_OK;
}

/// The sink gone: the task, which waits for it, told.
fn destroySink(sink: *rta.AudioSink) callconv(.c) void {
    const device = sinkHeadphone(sink);
    const base = device.base;
    @atomicStore(u8, &device.alive, 0, .release);
    base.sys_base.Signal(&base.task, bit(base.gone_signal));
}

fn startSink(sink: *rta.AudioSink, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    _ = mode;
    const device = sinkHeadphone(sink);
    if (@atomicLoad(u8, &device.leaving, .acquire) != 0) return err.RTAERR_NO_OUTPUT;
    const result = clockStart(device.base.sys_base, &device.clock, task, signal_mask);
    if (result != err.RTAERR_OK) return result;
    @atomicStore(u8, &device.playing, 1, .release);
    wakeTask(device);
    return err.RTAERR_OK;
}

fn stopSink(sink: *rta.AudioSink) callconv(.c) void {
    const device = sinkHeadphone(sink);
    clockStop(device.base.sys_base, &device.clock);
    @atomicStore(u8, &device.playing, 0, .release);
    wakeTask(device);
}

/// A buffer once its time has come.
fn bufferSink(sink: *rta.AudioSink) callconv(.c) ?[*]i16 {
    const device = sinkHeadphone(sink);
    if (!clockTick(device.base.sys_base, &device.clock, &sink.underruns)) return null;
    return &device.frames;
}

/// The buffer into the ring for the task - let go of where the ring is
/// full - and the task told.
fn playSink(sink: *rta.AudioSink, frames: [*]i16) callconv(.c) i32 {
    const device = sinkHeadphone(sink);
    if (device.ring.toWrite()) |slot| {
        @memcpy(slot, frames[0..buffer_samples]);
        device.ring.wrote();
    } else {
        device.overflows +%= 1;
    }
    wakeTask(device);
    return err.RTAERR_OK;
}

const ops = rta.AudioSinkOps{
    .destroy = &destroySink,
    .start = &startSink,
    .stop = &stopSink,
    .buffer = &bufferSink,
    .play = &playSink,
};

const driver_ops = rta.RtaDriverOps{ .create_sink = &createSink };

/// When buffer `n` has played, on the E-clock. Worked out wide: a
/// 16 MHz clock times the frames of a year's buffers is past 64 bits.
fn deadline(clock: *const Clock, n: u64) u64 {
    const since: u128 = @as(u128, n) * buffer_frames * clock.eclock_hz / rate;
    return clock.start_ticks +% @as(u64, @truncate(since));
}

/// The timer asked to come back once buffer `played + 1` has played.
fn arm(sys: *ExecBase, clock: *Clock) void {
    const eclock: *timer.EClockVal = @ptrCast(&clock.timer_io.time);
    eclock.* = timer.EClockVal.fromTicks(deadline(clock, clock.played + 1));
    clock.timer_io.node.command = timer.TR_ADDREQUEST;
    sys.SendIO(&clock.timer_io.node);
    clock.waiting = true;
}

/// The clock started for `task`, its first wake asked for: the request
/// comes back on a port that raises the task's signal, the one it waits
/// on for a buffer.
fn clockStart(sys: *ExecBase, clock: *Clock, task: *exec.Task, signal_mask: u32) i32 {
    if (signal_mask == 0) return err.RTAERR_BAD_ARG;
    clock.port = .{
        .flags = exec.PA_SIGNAL,
        .sig_bit = @intCast(@ctz(signal_mask)),
        .sig_task = task,
    };
    clock.port.msg_list.init(.message);
    clock.timer_io = .{};
    clock.timer_io.node.message.reply_port = &clock.port;
    clock.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_WAITECLOCK, &clock.timer_io.node, 0) != 0) return err.RTAERR_NO_OUTPUT;
    const device: *TimerBase = @ptrCast(clock.timer_io.node.device.?);
    var value: timer.EClockVal = .{};
    clock.eclock_hz = device.ReadEClock(&value);
    clock.start_ticks = value.toTicks();
    clock.played = 0;
    arm(sys, clock);
    return err.RTAERR_OK;
}

fn clockStop(sys: *ExecBase, clock: *Clock) void {
    if (clock.waiting) {
        _ = sys.AbortIO(&clock.timer_io.node);
        _ = sys.WaitIO(&clock.timer_io.node);
        clock.waiting = false;
    }
    if (clock.timer_io.node.device != null) sys.CloseDevice(&clock.timer_io.node);
    clock.timer_io = .{};
}

/// Whether a buffer's time has come: the timer back, the next wake set
/// for the buffer after it - at once where its time is past, so that a
/// caller late by a few buffers is given each of them and the sound stays
/// whole. One later than `catch_up` buffers is let go of the older ones,
/// counted in `missed`.
fn clockTick(sys: *ExecBase, clock: *Clock, missed: *u32) bool {
    if (sys.GetMsg(&clock.port) == null) return false;
    clock.waiting = false;
    clock.played += 1;
    const device: *TimerBase = @ptrCast(clock.timer_io.node.device.?);
    var value: timer.EClockVal = .{};
    _ = device.ReadEClock(&value);
    while (deadline(clock, clock.played + catch_up) <= value.toTicks()) {
        clock.played += 1;
        missed.* +%= 1;
    }
    arm(sys, clock);
    return true;
}

// --- the profile driver's calls -----------------------------------------------------

/// An audio sink service taken over BR/EDR - one whose record came from
/// the device's SDP server - and the task told of the device; the rest
/// declined. The contract is btprofile's (sdk/fd/btprofile_lib.fd).
///
/// INPUTS:
/// - `base` - the driver's base.
/// - `binding` - the device and the service offered.
pub fn BTProfileBind(base: *BtAudioBase, binding: *bluetooth.BTBinding) bool {
    const sys = base.sys_base;
    const service = binding.service orelse return false;
    if (service.flags & bluetooth.BTSF_SDP == 0 or service.class16 != avdtp.UUID_AUDIO_SINK) return false;
    if (binding.address.kind != bluetooth.BTADDR_BREDR) return false;
    // Cleared memory is each field's start but the few set here and on
    // the task: the whole is too big to be put together on a stack.
    const memory = sys.AllocMem(@sizeOf(Headphone), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return false;
    const device: *Headphone = @ptrCast(@alignCast(memory));
    device.base = base;
    device.controller = binding.controller;
    device.address = binding.address;
    device.bound = .{ .kind = .bound, .device = device };
    device.bound.message.length = @sizeOf(Command);
    device.unbind = .{ .kind = .unbind };

    sys.ObtainSemaphore(&base.lock);
    var slot_index: ?usize = null;
    var twice = false;
    for (base.devices, 0..) |slot, index| {
        const other = headphoneOf(slot) orelse {
            slot_index = index;
            continue;
        };
        // A second audio sink of a device driven: its stream is the
        // first one's.
        if (other.controller == device.controller and sameAddress(other.address, device.address)) twice = true;
    }
    if (twice) slot_index = null;
    if (slot_index) |index| base.devices[index] = device;
    sys.ReleaseSemaphore(&base.lock);
    if (twice) {
        sys.FreeMem(memory, @sizeOf(Headphone));
        return false;
    }
    const free_slot = slot_index orelse {
        say(base, "%s: %02x:%02x:%02x:%02x:%02x:%02x not driven: %ld devices are already\n", device.address, .{@as(i64, max_devices)});
        sys.FreeMem(memory, @sizeOf(Headphone));
        return false;
    };
    binding.driver_data = device;
    binding.unit = @intCast(free_slot);
    sys.PutMsg(base.command_port.?, &device.bound.message);
    return true;
}

/// A device let go of, by the task, and waited for - where a port to wait
/// on cannot be made, only sent. The contract is btprofile's
/// (sdk/fd/btprofile_lib.fd).
///
/// INPUTS:
/// - `base` - the driver's base.
/// - `binding` - what BTProfileBind took.
/// - `flags` - BTPU_*.
pub fn BTProfileUnbind(base: *BtAudioBase, binding: *bluetooth.BTBinding, flags: u32) void {
    const sys = base.sys_base;
    const device = headphoneOf(binding.driver_data) orelse return;
    binding.driver_data = null;
    const reply = sys.CreateMsgPort() orelse {
        // Sent alone: the task reads nothing of the binding.
        device.unbind = .{ .kind = .unbind, .flags = flags, .device = device };
        device.unbind.message.length = @sizeOf(Command);
        return sys.PutMsg(base.command_port.?, &device.unbind.message);
    };
    defer sys.DeleteMsgPort(reply);
    var command = Command{ .kind = .unbind, .flags = flags, .device = device };
    command.message.reply_port = reply;
    command.message.length = @sizeOf(Command);
    sys.PutMsg(base.command_port.?, &command.message);
    _ = sys.WaitPort(reply);
    _ = sys.GetMsg(reply);
}

fn lvoBTProfileBind(base: *BtAudioBase, binding: *bluetooth.BTBinding) callconv(.c) bool {
    return BTProfileBind(base, binding);
}
fn lvoBTProfileUnbind(base: *BtAudioBase, binding: *bluetooth.BTBinding, flags: u32) callconv(.c) void {
    return BTProfileUnbind(base, binding, flags);
}

comptime {
    const interface = sdk.interface.btprofile;
    if (!exec.libraries.sameSignature(@TypeOf(&lvoBTProfileBind), interface.Fn.BTProfileBind) or
        !exec.libraries.sameSignature(@TypeOf(&lvoBTProfileUnbind), interface.Fn.BTProfileUnbind))
        @compileError("btaudio.device: a profile call does not match the SDK's type");
}

// --- the device -------------------------------------------------------------------

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    io.err = exec.IOERR_NOCMD;
    baseOf(dev).sys_base.ReplyIO(io);
}

fn abortIO(_: *exec.Device, _: *exec.IORequest) callconv(.c) i32 {
    return -1;
}

/// Only bluetooth.library's open, on `BTPROFILE_UNIT_BIND`: the device has
/// no units of its own.
fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    if (unit_number != btprofile.BTPROFILE_UNIT_BIND) return exec.IOERR_OPENFAIL;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    io.unit = null;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    _ = io;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: its task and its driver have no way to end yet.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// bluetooth.library, rta.library and utility.library opened, the driver
/// registered, and the task started and waited for.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = baseOf(dev);
    base.sys_base = sys_base;
    base.seg_list = seg_list;
    base.devices = @splat(null);
    sys_base.InitSemaphore(&base.lock);
    base.bt_base = @ptrCast(sys_base.OpenLibrary(bluetooth.BLUETOOTHNAME, 1) orelse return null);
    base.utility_base = @ptrCast(sys_base.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return closeLibraries(base));
    base.rta_base = @ptrCast(sys_base.OpenLibrary(rta.RTANAME, rta.RTA_VERSION) orelse return closeLibraries(base));
    base.driver = .{
        .node = .{ .name = DRIVER_NAME, .pri = 0 },
        .version = DEVICE_VERSION,
        .revision = DEVICE_REVISION,
        .id_string = DEVICE_VERSION_STRING[1..],
        .type = rta.sinks.RTADT_SINK,
        .ops = &driver_ops,
        .instance_size = @sizeOf(*Headphone),
    };
    if (!base.rta_base.?.AddRtaDriver(&base.driver)) return closeLibraries(base);
    const stack = sys_base.AllocMem(stack_size, exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return dropDriver(base);
    base.stack = stack;
    base.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    const signal = sys_base.AllocSignal(-1);
    if (signal < 0) {
        sys_base.FreeMem(stack, stack_size);
        return dropDriver(base);
    }
    base.starter = sys_base.FindTask(null);
    base.start_signal = signal;
    _ = sys_base.AddTask(&base.task, &btAudioTask, null);
    _ = sys_base.Wait(bit(signal));
    sys_base.FreeSignal(signal);
    // A task that lacks something has ended: what it made is lost.
    if (!base.ready) return dropDriver(base);
    return dev;
}

/// The driver taken back and the libraries closed: null, init's answer.
fn dropDriver(base: *Base) ?*exec.Device {
    _ = base.rta_base.?.RemRtaDriver(&base.driver);
    return closeLibraries(base);
}

/// The libraries init opened, closed where it cannot go on: null, init's
/// answer then.
fn closeLibraries(base: *Base) ?*exec.Device {
    const sys = base.sys_base;
    if (base.rta_base) |lib| sys.CloseLibrary(@ptrCast(@alignCast(lib)));
    if (base.utility_base) |lib| sys.CloseLibrary(@ptrCast(@alignCast(lib)));
    if (base.bt_base) |lib| sys.CloseLibrary(@ptrCast(@alignCast(lib)));
    return null;
}

/// The jump table: the six standard vectors, then the profile driver's
/// two.
const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
    vec(lvoBTProfileBind),
    vec(lvoBTProfileUnbind),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(Base),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

const speaks = [_]u32{ devices.DEVIF_BTPROFILE, 0 };

/// What it drives: the audio sink service over BR/EDR.
const matches = [_]btprofile.BTMatch{
    .{ .over = btprofile.BTMATCH_BREDR, .class16 = avdtp.UUID_AUDIO_SINK },
    .{},
};

/// AUTOINIT and DEVICEINFO: made when bluetooth.library opens it, and its
/// match table read from the file without loading it.
export const btaudio_device_tag: btprofile.ResidentBTProfile linksection(".resident") = .{
    .device = .{
        .resident = .{
            .match_tag = @ptrCast(&btaudio_device_tag),
            .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
            .version = DEVICE_VERSION,
            .pri = 0,
            .type = .device,
            .name = DEVICE_NAME,
            .id_string = DEVICE_VERSION_STRING[1..],
            .init = &init_table,
        },
        .speaks = &speaks,
        .units = 0,
    },
    .matches = &matches,
};

/// A device is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a device, not a command\n", .{DEVICE_NAME});
    return 20;
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;
