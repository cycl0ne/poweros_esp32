// SPDX-License-Identifier: MIT
//! audio.device's outputs and volumes, from a program: an open that takes
//! no stream, and the commands that list the outputs, choose one, prefer
//! one and set their volumes - what a shell command, a preferences editor
//! or a window with a volume slider all do.
//!
//! `Control.open` opens the device for triggers alone (`AUDIOF_TRIGGER`),
//! which takes none of its streams, on a port of its own, and refuses a
//! device older than 2.9, which has no preferred output and one volume
//! for every output. Each call is a DoIO on that request: it waits
//! for the device's task where the command is the task's to carry out (a
//! change of output). `Outputs` is the list read once, with its names as a
//! chooser gadget takes its labels.
//!
//! A volume here is in percent of as recorded, 0 to 100, as a person sets
//! it; `percentOf` and `volumeOf` turn it into the device's and back.
//!
//! **A percent is as loud as it sounds**, not as large as the wave: the
//! ear hears decibels, and a volume in proportion to the wave put all of
//! quiet to loud into the first tenth of a slider - 50% was -6 dB, 90%
//! -0.9 dB. Up to 100 the device's volume is the percent's cube, as ALSA
//! maps a mixer's volume: 10% is -60 dB, 50% -18 dB, 90% -2.7 dB. Past
//! 100, where a player or a recorder boosts what is quiet, it grows in
//! proportion again: 200% is twice as recorded, +6 dB. Every program that
//! takes a volume in percent turns it with `volumeOf`, so that a percent
//! is the same wherever it is set.

const exec = @import("../libs/exec/exec.zig");
const audio = @import("audio.zig");
const ExecBase = @import("../interface/exec.zig").ExecBase;
const IOAudio = audio.IOAudio;

/// The oldest device that has every command here: 2.9.
pub const AUDIO_CONTROL_VERSION = 2;
pub const AUDIO_CONTROL_REVISION = 9;

/// The most outputs `Outputs` holds.
pub const max_outputs = 8;

/// A volume in percent as the device has it: up to 100 the percent's
/// cube of `AUDIO_VOLUME_UNITY`, past it in proportion, at most
/// `AUDIO_VOLUME_MAX`.
///
/// Below -90 dB, where nothing is heard and the cube rounds to the same
/// step of the device's volume for 1% and 2%, each percent keeps a step
/// of its own, so that every percent comes back from `percentOf` as it
/// went in.
pub fn volumeOf(percent: u32) u32 {
    const unity: u64 = audio.AUDIO_VOLUME_UNITY;
    if (percent > 100) return @intCast(@min(@as(u64, percent) * unity / 100, audio.AUDIO_VOLUME_MAX));
    const p: u64 = percent;
    const cube = (p * p * p * unity + 500_000) / 1_000_000;
    return @intCast(@max(cube, p));
}

/// The device's volume in percent, at most 100: the percent whose volume
/// is nearest.
pub fn percentOf(volume: u32) u32 {
    if (volume >= audio.AUDIO_VOLUME_UNITY) return 100;
    var best: u32 = 0;
    var percent: u32 = 1;
    while (percent <= 100) : (percent += 1) {
        const step = volumeOf(percent);
        if (distance(step, volume) < distance(volumeOf(best), volume)) best = percent;
        // The volumes only grow, so past the volume asked for nothing
        // comes nearer.
        if (step > volume) break;
    }
    return best;
}

fn distance(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

/// An output's name, as the device wrote it, up to its NUL.
pub fn nameOf(info: *const audio.AudioOutputInfo) []const u8 {
    var length: usize = 0;
    while (length < info.name.len and info.name[length] != 0) length += 1;
    return info.name[0..length];
}

pub const Control = struct {
    sys: *ExecBase,
    port: *exec.MsgPort,
    io: *IOAudio,

    /// The device opened for triggers alone: null when there is none, or
    /// one older than `AUDIO_CONTROL_VERSION`.`AUDIO_CONTROL_REVISION`, or
    /// no memory.
    pub fn open(sys: *ExecBase) ?Control {
        const port = sys.CreateMsgPort() orelse return null;
        const made = sys.CreateIORequest(port, @sizeOf(IOAudio)) orelse {
            sys.DeleteMsgPort(port);
            return null;
        };
        const io: *IOAudio = @ptrCast(@alignCast(made));
        io.* = .{ .std = io.std };
        if (sys.OpenDevice(audio.AUDIONAME, audio.AUDIO_UNIT_PLAY, &io.std.req, audio.AUDIOF_TRIGGER) != 0) {
            sys.DeleteIORequest(&io.std.req);
            sys.DeleteMsgPort(port);
            return null;
        }
        const device = io.std.req.device.?;
        if (device.version < AUDIO_CONTROL_VERSION or
            (device.version == AUDIO_CONTROL_VERSION and device.revision < AUDIO_CONTROL_REVISION))
        {
            sys.CloseDevice(&io.std.req);
            sys.DeleteIORequest(&io.std.req);
            sys.DeleteMsgPort(port);
            return null;
        }
        return .{ .sys = sys, .port = port, .io = io };
    }

    pub fn close(control: *Control) void {
        const sys = control.sys;
        sys.CloseDevice(&control.io.std.req);
        sys.DeleteIORequest(&control.io.std.req);
        sys.DeleteMsgPort(control.port);
    }

    fn send(control: *Control, command: u16, output: u32, data: ?*anyopaque, length: usize) i8 {
        const io = control.io;
        io.std.req.command = command;
        io.std.req.flags = 0;
        io.std.data = data;
        io.std.length = length;
        io.output = output;
        return @truncate(control.sys.DoIO(&io.std.req));
    }

    /// What the device says of itself: false when it would not.
    pub fn query(control: *Control, info: *audio.AudioInfo) bool {
        info.* = .{};
        return control.send(audio.AUDIOCMD_QUERY, 0, info, @sizeOf(audio.AudioInfo)) == 0;
    }

    /// The output after the one numbered `after` (0: the first) into
    /// `info`: false past the last.
    pub fn next(control: *Control, after: u32, info: *audio.AudioOutputInfo) bool {
        info.* = .{};
        return control.send(audio.AUDIOCMD_NEXTOUTPUT, after, info, @sizeOf(audio.AudioOutputInfo)) == 0;
    }

    /// The output played through into `info`: false when there is none.
    pub fn current(control: *Control, info: *audio.AudioOutputInfo) bool {
        info.* = .{};
        return control.send(audio.AUDIOCMD_GETOUTPUT, 0, info, @sizeOf(audio.AudioOutputInfo)) == 0;
    }

    /// Played through the output of that number from now on (0: the
    /// first on the list): 0, or the device's error - AUDIOERR_NOOUTPUT
    /// for one not there or that would not start.
    pub fn play(control: *Control, id: u32) i8 {
        return control.send(audio.AUDIOCMD_SETOUTPUT, id, null, 0);
    }

    /// The output of that number preferred, there or not (0: none); the
    /// number of the one played through after it, 0 for none.
    pub fn prefer(control: *Control, id: u32) u32 {
        _ = control.send(audio.AUDIOCMD_PREFEROUTPUT, id, null, 0);
        return control.io.output;
    }

    /// The volume of the output of that number, there or not (0: the one
    /// played through), in percent.
    pub fn setVolume(control: *Control, id: u32, percent: u32) void {
        control.io.volume = volumeOf(percent);
        _ = control.send(audio.AUDIOCMD_MASTER, id, null, 0);
    }
};

/// The outputs on the device's list, read at once, and their names as a
/// chooser's labels.
pub const Outputs = struct {
    infos: [max_outputs]audio.AudioOutputInfo = undefined,
    count: usize = 0,
    labels: [max_outputs:null]?[*:0]const u8 = @splat(null),

    /// Read again from the device: past `max_outputs`, the rest are left
    /// out.
    pub fn read(outputs: *Outputs, control: *Control) void {
        outputs.count = 0;
        var after: u32 = 0;
        while (outputs.count < max_outputs) {
            const info = &outputs.infos[outputs.count];
            if (!control.next(after, info)) break;
            // A name the device filled to the end gets its NUL here.
            info.name[info.name.len - 1] = 0;
            outputs.labels[outputs.count] = @ptrCast(&info.name);
            after = info.id;
            outputs.count += 1;
        }
        for (outputs.labels[outputs.count..]) |*label| label.* = null;
    }

    /// Where the output of that number is in the list, or null.
    pub fn indexOf(outputs: *const Outputs, id: u32) ?usize {
        for (outputs.infos[0..outputs.count], 0..) |*info, at| {
            if (info.id == id) return at;
        }
        return null;
    }

    /// Where the one played through is, or null for none.
    pub fn currentIndex(outputs: *const Outputs) ?usize {
        for (outputs.infos[0..outputs.count], 0..) |*info, at| {
            if (info.flags & audio.AUDIOOF_CURRENT != 0) return at;
        }
        return null;
    }

    /// Whether the two hold the same outputs in the same order, and the
    /// same one played through.
    pub fn same(outputs: *const Outputs, other: *const Outputs) bool {
        if (outputs.count != other.count) return false;
        for (outputs.infos[0..outputs.count], other.infos[0..other.count]) |*one, *two| {
            if (one.id != two.id) return false;
            if (one.flags & audio.AUDIOOF_CURRENT != two.flags & audio.AUDIOOF_CURRENT) return false;
        }
        return true;
    }
};
