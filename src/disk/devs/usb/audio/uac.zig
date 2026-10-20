// SPDX-License-Identifier: MIT
//! usb/uac.device: USB speakers, headsets and sound adapters of the audio
//! class, as sound outputs - each one a sink of rta.library, which
//! audio.device plays through as it plays through a board's codec.
//!
//! **What it takes** is a streaming interface with a setting it can play
//! through (`stream.zig`): an isochronous OUT endpoint, linear PCM, one
//! or two channels of 16, 24 or 32 bits, at 48 kHz. A function with a
//! microphone as well has that offered as another streaming interface,
//! which is declined. So is any interface on a bus whose controller has
//! no isochronous transfers: a packet of silence sent as it is bound
//! comes back IOERR_NOCMD.
//!
//! **A bound output** is a sink of the driver "uac", named as the device
//! names its product, at the bottom of the board's own outputs; it is
//! made as the device is plugged in and deleted as it goes. Deleted while
//! it plays, audio.device moves to the next output before it goes.
//!
//! **Playing** is a ring of three buffers of ten milliseconds, each an
//! isochronous transfer of ten packets on a pipe of its own, all sent at
//! the start: the controller plays them one after the other, and each
//! one's reply - on a port that raises the playing task's signal - is a
//! buffer played, filled again and sent again. A reply with nothing else
//! left on the bus means the stream ran dry: an underrun. Started, the
//! interface is put in its setting and its rate set where the endpoint
//! has the control; the feature unit's mute is lifted and its volume set
//! to 0 dB, or the most it has below that. Stopped, the transfers are
//! taken back and the interface goes back to its empty setting.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const usb = sdk.usb;
const d = usb.descriptors;
const usbhc = sdk.devices.usbhc;
const usbclass = sdk.devices.usbclass;
const devices = sdk.expansion.devices;
const rta = sdk.rta;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const UsbBase = sdk.interface.usb.UsbBase;
const RtaBase = sdk.interface.rta.RtaBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const err = rta.errors;
const stream = @import("stream.zig");

pub const DEVICE_NAME = "uac.device";
const DRIVER_NAME = "uac";
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "20.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// The rate it plays at: whole frames a millisecond, so every packet is
/// as long as the next.
const rate: u32 = 48_000;
/// A buffer's milliseconds, and the buffers on the bus at once.
const buffer_ms = 10;
const ring = 3;
const max_frames = rate / 1000 * buffer_ms;
const max_bytes = max_frames * 2 * 4;

/// The bytes of a name rta.library keeps, with its NUL.
const name_len = 32;

/// A sink's tag, this driver's own: the output it is.
const UAC_Speaker = utility.TAG_USER | 0x5541;

/// The device's base: usb.library, rta.library and utility.library, and
/// the driver it registered.
const Base = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    usb_base: ?*UsbBase = null,
    rta_base: ?*RtaBase = null,
    utility_base: ?*UtilityBase = null,
    driver: rta.RtaDriver = .{},
};

fn baseOf(dev: *exec.Device) *Base {
    return @alignCast(@fieldParentPtr("dev", dev));
}

/// A bound output: its device, its setting and feature unit, its sink,
/// its pipes and their buffers.
const Speaker = struct {
    base: *Base,
    device: *usb.USBDevice,
    setting: stream.Setting,
    feature: ?stream.Feature,
    sink: ?*rta.AudioSink = null,
    mode: rta.AudioMode = .{},
    name: [name_len]u8 = @splat(0),
    /// A buffer's packets, and bytes.
    packets: u32 = 0,
    bytes: u32 = 0,
    pipes: [ring]*usb.USBPipe = undefined,
    /// The port the transfers come back to: the playing task's signal
    /// while started, nobody's otherwise.
    port: exec.MsgPort = .{ .flags = exec.PA_IGNORE },
    /// Which transfers are on the bus, how many, and the one whose
    /// buffer is being filled.
    out: [ring]u8 = @splat(0),
    in_flight: u32 = 0,
    ready: ?u32 = null,
    /// Set by the unbind: nothing is sent after it.
    leaving: u8 = 0,
    /// Who waits for the sink to be gone, on which signal.
    unbinder: ?*exec.Task = null,
    unbind_signal: i8 = -1,
    frames: [max_frames * 2]i16 = @splat(0),
    data: [ring][max_bytes]u8 = undefined,
};

fn speakerOf(sink: *rta.AudioSink) *Speaker {
    const held: **Speaker = @ptrCast(@alignCast(sink.instance.?));
    return held.*;
}

// --- the device -------------------------------------------------------------------

/// usb.library's open, for the two class calls; it has no units.
fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    if (unit_number != usbclass.USBCLASS_UNIT_BIND) return exec.IOERR_OPENFAIL;
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

/// The device stays: its driver is on rta.library's list for good.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    io.err = exec.IOERR_NOCMD;
    baseOf(dev).sys_base.ReplyIO(io);
}

fn abortIO(_: *exec.Device, _: *exec.IORequest) callconv(.c) i32 {
    return -1;
}

// --- binding ----------------------------------------------------------------------

/// A control transfer to the speaker's device: whether it was answered.
fn control(speaker: *Speaker, request_type: u8, request: u8, value: u16, index: u16, data: ?*anyopaque, length: u16) bool {
    const setup = usb.SetupPacket{ .request_type = request_type, .request = request, .value = value, .index = index, .length = length };
    return speaker.base.usb_base.?.DoUSBControl(speaker.device, &setup, data, null) == 0;
}

fn setInterface(speaker: *Speaker, alternate: u8) bool {
    return control(speaker, d.USB_DIR_OUT | d.USB_RECIP_INTERFACE, d.USB_REQ_SET_INTERFACE, alternate, speaker.setting.interface, null, 0);
}

/// One packet of silence sent on the speaker's setting and waited for:
/// whether the bus's controller has isochronous transfers.
fn probe(speaker: *Speaker) bool {
    const sys = speaker.base.sys_base;
    const port = sys.CreateMsgPort() orelse return false;
    defer sys.DeleteMsgPort(port);
    if (!setInterface(speaker, speaker.setting.alternate)) return false;
    defer _ = setInterface(speaker, 0);
    const io = &speaker.pipes[0].io;
    @memset(speaker.data[0][0..speaker.bytes], 0);
    io.std.req.message.reply_port = port;
    io.std.data = &speaker.data[0];
    io.std.length = speaker.bytes / speaker.packets;
    const answer = sys.DoIO(&io.std.req);
    io.std.req.message.reply_port = &speaker.port;
    return answer != exec.IOERR_NOCMD;
}

/// A streaming interface with a setting to play through: its pipes
/// opened, the controller asked whether it can, and its sink made.
fn bind(base: *Base, binding: *usb.USBBinding) bool {
    const sys = base.sys_base;
    const ub = base.usb_base orelse return false;
    const rb = base.rta_base orelse return false;
    const device = binding.device.?;
    const interface = binding.interface.?;
    if (interface.interface_class != d.USB_CLASS_AUDIO or interface.interface_subclass != d.AUDIO_SUBCLASS_STREAMING) return false;
    const config = (device.config orelse return false)[0..device.config_length];
    const setting = stream.findSetting(config, interface.interface_number, rate) orelse return false;

    const memory = sys.AllocMem(@sizeOf(Speaker), exec.MEMF_CLEAR) orelse return false;
    const speaker: *Speaker = @ptrCast(@alignCast(memory));
    speaker.* = .{ .base = base, .device = device, .setting = setting, .feature = stream.findFeature(config, setting.terminal) };
    speaker.port.msg_list.init(.message);
    speaker.packets = @max(buffer_ms / setting.intervalMs(), 1);
    speaker.bytes = speaker.packets * stream.packetBytes(setting, rate);
    var opened: u32 = 0;
    while (opened < ring) : (opened += 1) {
        const pipe = ub.OpenUSBPipe(device, setting.endpoint, &speaker.port) orelse break;
        pipe.io.iso_packet = stream.packetBytes(setting, rate);
        speaker.pipes[opened] = pipe;
    }
    if (opened < ring or !probe(speaker)) {
        if (opened == ring) exec.kprintf(sys, "%s: the bus has no isochronous transfers\n", .{DEVICE_NAME});
        for (speaker.pipes[0..opened]) |pipe| ub.CloseUSBPipe(pipe);
        sys.FreeMem(memory, @sizeOf(Speaker));
        return false;
    }

    const product = device.product orelse "USB audio";
    var at: usize = 0;
    while (product[at] != 0 and at < speaker.name.len - 1) : (at += 1) speaker.name[at] = product[at];
    const sink_tags = [_]TagItem{
        .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr(&speaker.name) },
        .{ .tag = UAC_Speaker, .data = @intFromPtr(speaker) },
        .{},
    };
    if (rb.CreateSinkTagList(DRIVER_NAME, &sink_tags) == null) {
        exec.kprintf(sys, "%s: no sink: %s\n", .{ DEVICE_NAME, rb.RtaErrorText(rb.RtaLastError()) });
        for (speaker.pipes) |pipe| ub.CloseUSBPipe(pipe);
        sys.FreeMem(memory, @sizeOf(Speaker));
        return false;
    }
    binding.driver_data = speaker;
    binding.unit = 0;
    return true;
}

/// An output gone: its transfers taken back, its sink deleted - once
/// whatever plays through it has stopped, which is waited for - its
/// pipes closed.
fn unbind(base: *Base, binding: *usb.USBBinding) void {
    const sys = base.sys_base;
    const raw = binding.driver_data orelse return;
    const speaker: *Speaker = @ptrCast(@alignCast(raw));
    @atomicStore(u8, &speaker.leaving, 1, .release);
    for (speaker.pipes, 0..) |pipe, n| {
        if (@atomicLoad(u8, &speaker.out[n], .acquire) != 0) _ = sys.AbortIO(&pipe.io.std.req);
    }
    if (speaker.sink) |sink| {
        const signal = sys.AllocSignal(-1);
        if (signal >= 0) {
            speaker.unbind_signal = @intCast(signal);
            speaker.unbinder = sys.FindTask(null);
        }
        base.rta_base.?.DeleteSink(sink);
        if (signal >= 0) {
            _ = sys.Wait(@as(u32, 1) << @intCast(signal));
            sys.FreeSignal(signal);
        }
    }
    for (speaker.pipes) |pipe| base.usb_base.?.CloseUSBPipe(pipe);
    sys.FreeMem(speaker, @sizeOf(Speaker));
    binding.driver_data = null;
}

fn lvoUSBClassBind(base: *Base, binding: *usb.USBBinding) callconv(.c) bool {
    return bind(base, binding);
}
fn lvoUSBClassUnbind(base: *Base, binding: *usb.USBBinding) callconv(.c) void {
    unbind(base, binding);
}

comptime {
    const interface = sdk.interface.usbclass;
    if (!exec.libraries.sameSignature(@TypeOf(&lvoUSBClassBind), interface.Fn.USBClassBind) or
        !exec.libraries.sameSignature(@TypeOf(&lvoUSBClassUnbind), interface.Fn.USBClassUnbind))
        @compileError("uac.device: a class call does not match the SDK's type");
}

// --- the sink ---------------------------------------------------------------------

/// The sink of the speaker its tags name: its one mode, its ring.
fn createSink(made_by: *rta.RtaDriver, sink: *rta.AudioSink, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const base: *Base = @alignCast(@fieldParentPtr("driver", made_by));
    const named: ?*Speaker = @ptrFromInt(base.utility_base.?.GetTagData(UAC_Speaker, 0, tag_list));
    const speaker = named orelse return err.RTAERR_BAD_TAGS;
    const held: **Speaker = @ptrCast(@alignCast(sink.instance.?));
    held.* = speaker;
    const setting = speaker.setting;
    speaker.mode = .{
        .node = .{ .name = if (setting.channels == 1) "48000 Hz mono" else "48000 Hz stereo" },
        .id = 0,
        .rate = rate,
        .bits = setting.bits,
        .channels = setting.channels,
        .sides = if (setting.channels == 1) rta.sinks.AUDIOSIDES_MONO else rta.AUDIOSIDES_LEFT_FIRST,
        .flags = rta.sinks.AUDIOMF_DEFAULT,
    };
    base.sys_base.AddTail(&sink.modes, &speaker.mode.node);
    sink.ops = &ops;
    sink.buffer_frames = speaker.packets * stream.packetFrames(setting, rate);
    sink.buffers = ring;
    speaker.sink = sink;
    return err.RTAERR_OK;
}

/// The sink gone: the unbind, if it waits, told.
fn destroy(sink: *rta.AudioSink) callconv(.c) void {
    const speaker = speakerOf(sink);
    speaker.sink = null;
    if (speaker.unbinder) |task| {
        speaker.base.sys_base.Signal(task, @as(u32, 1) << @intCast(speaker.unbind_signal));
    }
}

/// The feature unit's mute lifted and its volume set to 0 dB - or the
/// most it has below that - on every channel that has them.
fn unmute(speaker: *Speaker) void {
    const feature = speaker.feature orelse return;
    const to_unit = d.USB_DIR_OUT | d.USB_TYPE_CLASS | d.USB_RECIP_INTERFACE;
    const from_unit = d.USB_DIR_IN | d.USB_TYPE_CLASS | d.USB_RECIP_INTERFACE;
    const index = @as(u16, feature.unit) << 8 | feature.interface;
    var channel: u5 = 0;
    while (channel <= speaker.setting.channels) : (channel += 1) {
        const bit = @as(u32, 1) << channel;
        if (feature.mutes & bit != 0) {
            var off: [1]u8 = .{0};
            _ = control(speaker, to_unit, d.UAC_SET_CUR, @as(u16, d.UAC_FU_MUTE) << 8 | channel, index, &off, 1);
        }
        if (feature.volumes & bit != 0) {
            var most: [2]u8 = .{ 0, 0 };
            const value = @as(u16, d.UAC_FU_VOLUME) << 8 | channel;
            if (control(speaker, from_unit, d.UAC_GET_MAX, value, index, &most, 2)) {
                const max: i16 = @bitCast(@as(u16, most[0]) | @as(u16, most[1]) << 8);
                if (max < 0) {
                    _ = control(speaker, to_unit, d.UAC_SET_CUR, value, index, &most, 2);
                    continue;
                }
            }
            var zero: [2]u8 = .{ 0, 0 };
            _ = control(speaker, to_unit, d.UAC_SET_CUR, value, index, &zero, 2);
        }
    }
}

/// A buffer's transfer sent: its pipe on the bus.
fn send(speaker: *Speaker, n: u32) void {
    const io = &speaker.pipes[n].io;
    io.std.data = &speaker.data[n];
    io.std.length = speaker.bytes;
    io.std.actual = 0;
    @atomicStore(u8, &speaker.out[n], 1, .release);
    speaker.in_flight += 1;
    speaker.base.sys_base.SendIO(&io.std.req);
}

fn start(sink: *rta.AudioSink, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) callconv(.c) i32 {
    _ = mode;
    const speaker = speakerOf(sink);
    if (signal_mask == 0) return err.RTAERR_BAD_ARG;
    if (@atomicLoad(u8, &speaker.leaving, .acquire) != 0) return err.RTAERR_NO_OUTPUT;
    if (!setInterface(speaker, speaker.setting.alternate)) return err.RTAERR_NO_OUTPUT;
    if (speaker.setting.rate_control) {
        var frequency: [3]u8 = .{ @truncate(rate), @truncate(rate >> 8), @truncate(rate >> 16) };
        _ = control(speaker, d.USB_DIR_OUT | d.USB_TYPE_CLASS | d.USB_RECIP_ENDPOINT, d.UAC_SET_CUR, @as(u16, d.UAC_EP_SAMPLING_FREQ) << 8, speaker.setting.endpoint, &frequency, 3);
    }
    unmute(speaker);
    speaker.port.sig_bit = @intCast(@ctz(signal_mask));
    speaker.port.sig_task = task;
    speaker.port.flags = exec.PA_SIGNAL;
    speaker.in_flight = 0;
    speaker.ready = null;
    var n: u32 = 0;
    while (n < ring) : (n += 1) {
        @memset(speaker.data[n][0..speaker.bytes], 0);
        send(speaker, n);
    }
    return err.RTAERR_OK;
}

/// Every transfer taken back, and the interface in its empty setting
/// again - unless the device is going.
fn stop(sink: *rta.AudioSink) callconv(.c) void {
    const speaker = speakerOf(sink);
    const sys = speaker.base.sys_base;
    for (speaker.pipes, 0..) |pipe, n| {
        if (@atomicLoad(u8, &speaker.out[n], .acquire) == 0) continue;
        _ = sys.AbortIO(&pipe.io.std.req);
        _ = sys.WaitIO(&pipe.io.std.req);
        @atomicStore(u8, &speaker.out[n], 0, .release);
    }
    speaker.port.flags = exec.PA_IGNORE;
    speaker.in_flight = 0;
    speaker.ready = null;
    if (@atomicLoad(u8, &speaker.leaving, .acquire) == 0) _ = setInterface(speaker, 0);
}

/// The buffer of a transfer that has come back; none from one taken
/// back or from a device that has gone.
fn buffer(sink: *rta.AudioSink) callconv(.c) ?[*]i16 {
    const speaker = speakerOf(sink);
    const sys = speaker.base.sys_base;
    while (sys.GetMsg(&speaker.port)) |message| {
        const n = for (speaker.pipes, 0..) |pipe, at| {
            if (message == &pipe.io.std.req.message) break @as(u32, @intCast(at));
        } else continue;
        @atomicStore(u8, &speaker.out[n], 0, .release);
        speaker.in_flight -= 1;
        const answer = speaker.pipes[n].io.std.req.err;
        if (answer == usbhc.UHIOERR_DETACHED or answer == exec.IOERR_ABORTED) continue;
        if (@atomicLoad(u8, &speaker.leaving, .acquire) != 0) continue;
        if (speaker.in_flight == 0) sink.underruns +%= 1;
        speaker.ready = n;
        return &speaker.frames;
    }
    return null;
}

/// The buffer as the setting's samples, sent again.
fn play(sink: *rta.AudioSink, frames: [*]i16) callconv(.c) i32 {
    const speaker = speakerOf(sink);
    const n = speaker.ready orelse return err.RTAERR_NOT_RUNNING;
    speaker.ready = null;
    if (@atomicLoad(u8, &speaker.leaving, .acquire) != 0) return err.RTAERR_OK;
    _ = stream.convert(speaker.setting, frames, sink.buffer_frames, &speaker.data[n]);
    send(speaker, n);
    return err.RTAERR_OK;
}

const ops = rta.AudioSinkOps{
    .destroy = &destroy,
    .start = &start,
    .stop = &stop,
    .buffer = &buffer,
    .play = &play,
};

const driver_ops = rta.RtaDriverOps{ .create_sink = &createSink };

// --- the start --------------------------------------------------------------------

/// usb.library, rta.library and utility.library opened, the driver
/// registered. Null when any of it cannot be had.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = baseOf(dev);
    base.sys_base = sys;
    base.seg_list = seg_list;
    base.usb_base = @ptrCast(sys.OpenLibrary(usb.USBNAME, 1) orelse return null);
    base.utility_base = @ptrCast(sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null);
    const rb: *RtaBase = @ptrCast(sys.OpenLibrary(rta.RTANAME, rta.RTA_VERSION) orelse return null);
    base.rta_base = rb;
    base.driver = .{
        .node = .{ .name = DRIVER_NAME, .pri = 0 },
        .version = DEVICE_VERSION,
        .revision = DEVICE_REVISION,
        .id_string = DEVICE_VERSION_STRING[1..],
        .type = rta.sinks.RTADT_SINK,
        .ops = &driver_ops,
        .instance_size = @sizeOf(*Speaker),
    };
    if (!rb.AddRtaDriver(&base.driver)) return null;
    return dev;
}

const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
    vec(lvoUSBClassBind),
    vec(lvoUSBClassUnbind),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(Base),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

const speaks = [_]u32{ devices.DEVIF_USBCLASS, 0 };

/// What it drives: the audio class's streaming interfaces.
const matches = [_]usbclass.USBMatch{
    .{
        .fields = usbclass.USBMATCH_CLASS | usbclass.USBMATCH_SUBCLASS,
        .interface_class = d.USB_CLASS_AUDIO,
        .interface_subclass = d.AUDIO_SUBCLASS_STREAMING,
    },
    .{},
};

export const uac_device_tag: usbclass.ResidentUSBClass linksection(".resident") = .{
    .device = .{
        .resident = .{
            .match_tag = @ptrCast(&uac_device_tag),
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

export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;
