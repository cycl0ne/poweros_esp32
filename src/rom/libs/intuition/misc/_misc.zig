// SPDX-License-Identifier: MPL-2.0
//! What the beep, the alerts and the clock share: a wait of so many
//! microseconds on timer.device, an alert's hold on the input, and the
//! beep's sound.
//!
//! timer.device is opened the first time something waits, into a request
//! each wait copies with a reply port on its caller's own stack: any task
//! may be the one waiting.
//!
//! The beep's sound is a trigger of audio.device's: one request in the
//! base, sent again for every beep - the last taken back first if it
//! still sounds - on an open for triggers alone, made the first time a
//! beep is heard. Its port signals nobody: a beep never waits for the
//! one before to end, it finds it there or takes it back.
//!
//! An alert, while it is up, takes every input event: a press of a button
//! is its answer - the left one yes, the right one no - and nothing else
//! reaches a window. A touch has only the one button, so a press on the
//! right half of the display counts as the right button.

const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const audio = sdk.devices.audio;
const BeepSound = sdk.intuition.BeepSound;
const ie = sdk.devices.inputevent;
const InputEvent = ie.InputEvent;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// An alert's state, in the base.
pub const AlertState = extern struct {
    /// Up: the input is the alert's.
    active: bool = false,
    /// Its answer: none yet, yes or no.
    answer: Answer = .none,
    pad: [2]u8 = .{ 0, 0 },
    /// Where the right half of the display begins, for a touch.
    half: i32 = 0,
};

pub const Answer = enum(u8) { none, yes, no };

/// A frame of a 60 Hz panel, what an alert's time-out counts in.
pub const frame_us = 16_667;

/// timer.device opened the first time it is wanted; whether it is open.
fn openTimer(ib: *IntuitionBase) bool {
    if (ib.timer_open) return true;
    ib.timer_io = .{};
    ib.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (ib.sys_base.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &ib.timer_io.node, 0) != 0) return false;
    ib.timer_open = true;
    return true;
}

/// Wait `us` microseconds, or not at all when timer.device cannot be had.
pub fn wait(ib: *IntuitionBase, us: u64) void {
    const sys = ib.sys_base;
    if (!openTimer(ib)) return;
    const bit = sys.AllocSignal(-1);
    if (bit < 0) return;
    defer sys.FreeSignal(bit);
    var port: exec.MsgPort = .{ .sig_bit = @intCast(bit), .sig_task = sys.FindTask(null) };
    port.msg_list.init(.message);
    var io = ib.timer_io;
    io.node.message.reply_port = &port;
    io.node.command = timer.TR_ADDREQUEST;
    io.time = timer.TimeVal.fromMicros(us);
    _ = sys.DoIO(&io.node);
}

/// The system's time, in microseconds; null when timer.device cannot be
/// had.
pub fn now(ib: *IntuitionBase) ?u64 {
    if (!openTimer(ib)) return null;
    const tmb: *sdk.interface.timer.TimerBase = @ptrCast(ib.timer_io.node.device orelse return null);
    var time: timer.TimeVal = .{};
    tmb.GetSysTime(&time);
    return time.toMicros();
}

/// timer.device given back, if it was opened.
pub fn close(ib: *IntuitionBase) void {
    if (ib.timer_open) ib.sys_base.CloseDevice(&ib.timer_io.node);
    ib.timer_open = false;
}

/// An input event while an alert is up: a press answers it, and nothing
/// goes anywhere else. On the input task.
pub fn alertInput(ib: *IntuitionBase, e: *const InputEvent) void {
    if (e.class != ie.IECLASS_NEWPOINTERPOS) return;
    const alert = &ib.alert;
    if (alert.answer != .none) return;
    if (e.code == ie.IECODE_LBUTTON) {
        alert.answer = if (e.x >= alert.half) .no else .yes;
    } else if (e.code == ie.IECODE_RBUTTON) {
        alert.answer = .no;
    }
}

// --- the beep's sound ---------------------------------------------------------

/// A beep's priority among the sounds played by trigger: above a
/// program's (0), so a beep is heard when every trigger voice is taken.
const beep_pri: i8 = 85;

/// What became of a beep's sound: there was none to play, it plays, or
/// there was one and it cannot be heard.
pub const Heard = enum { none, heard, unheard };

/// The beep's sound, if one is set, sent to audio.device as a trigger.
pub fn soundBeep(ib: *IntuitionBase) Heard {
    const sys = ib.sys_base;
    sys.ObtainSemaphore(&ib.beep_lock);
    defer sys.ReleaseSemaphore(&ib.beep_lock);
    const sound = ib.beep_sound orelse return .none;
    if (!openAudio(ib)) return .unheard;
    takeBack(ib);
    const io = &ib.beep_io;
    io.std.req.command = audio.AUDIOCMD_TRIGGER;
    io.std.req.flags = 0;
    io.std.req.message.node.pri = beep_pri;
    io.std.data = @constCast(sound.samples);
    io.std.length = @as(u64, sound.frames) * sound.channels * @sizeOf(i16);
    io.format = audio.AUDIO_S16;
    io.channels = @intCast(sound.channels);
    io.rate = sound.rate;
    io.volume = sound.volume;
    io.pan = 0;
    io.loops = 1;
    sys.SendIO(&io.std.req);
    // One refused at once - every trigger voice at a higher priority - is
    // not heard.
    if (sys.CheckIO(&io.std.req) != null and io.std.req.err != 0) {
        _ = sys.WaitIO(&io.std.req);
        return .unheard;
    }
    ib.beep_sent = true;
    return .heard;
}

/// The beep's sound replaced by a copy of `given`, or by none for null -
/// the last beep taken back first if it still sounds, the old copy freed.
/// False for a sound that means nothing or no memory for its copy: the
/// old one stays then.
pub fn setBeepSound(ib: *IntuitionBase, given: ?*const BeepSound) bool {
    const sys = ib.sys_base;
    var copy: ?*BeepSound = null;
    if (given) |sound| {
        if (sound.frames == 0 or sound.rate == 0 or sound.rate > audio.AUDIO_MAX_RATE) return false;
        if (sound.channels != 1 and sound.channels != 2) return false;
        if (sound.volume > audio.AUDIO_VOLUME_MAX) return false;
        const samples = @as(usize, sound.frames) * sound.channels;
        const memory = sys.AllocVec(@sizeOf(BeepSound) + samples * @sizeOf(i16), exec.MEMF_ANY) orelse return false;
        const made: *BeepSound = @ptrCast(@alignCast(memory));
        const into: [*]i16 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(memory)) + @sizeOf(BeepSound)));
        @memcpy(into[0..samples], sound.samples[0..samples]);
        made.* = sound.*;
        made.samples = into;
        copy = made;
    }
    sys.ObtainSemaphore(&ib.beep_lock);
    defer sys.ReleaseSemaphore(&ib.beep_lock);
    takeBack(ib);
    if (ib.beep_sound) |old| sys.FreeVec(old);
    ib.beep_sound = copy;
    // A new sound: the device is tried again.
    ib.beep_unheard = false;
    return true;
}

/// audio.device open for triggers alone; whether it is. Under
/// `beep_lock`.
fn openAudio(ib: *IntuitionBase) bool {
    if (ib.beep_open) return true;
    if (ib.beep_unheard) return false;
    ib.beep_io = .{};
    ib.beep_io.std.req.message.reply_port = &ib.beep_port;
    ib.beep_io.std.req.message.length = @sizeOf(audio.IOAudio);
    if (ib.sys_base.OpenDevice(audio.AUDIONAME, audio.AUDIO_UNIT_PLAY, &ib.beep_io.std.req, audio.AUDIOF_TRIGGER) != 0) {
        ib.beep_unheard = true;
        return false;
    }
    ib.beep_open = true;
    return true;
}

/// The last beep taken back, sounding or come back. audio.device answers
/// an abort at once, so the wait finds it on the port. Under `beep_lock`.
fn takeBack(ib: *IntuitionBase) void {
    if (!ib.beep_sent) return;
    const sys = ib.sys_base;
    _ = sys.AbortIO(&ib.beep_io.std.req);
    _ = sys.WaitIO(&ib.beep_io.std.req);
    ib.beep_sent = false;
}
