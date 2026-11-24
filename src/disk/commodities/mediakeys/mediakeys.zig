// SPDX-License-Identifier: MIT
//! MediaKeys: the media keys for the whole system - play/pause, play,
//! pause, stop, previous, next, rewind, fast forward, mute and the volume
//! down and up - from every keyboard that has them and from a headphone's
//! buttons, wherever the active window is. Built against the SDK only.
//!
//!   MediaKeys STEP/K/N,CX_PRIORITY/K/N
//!
//! The volume keys turn the output played through up and down by STEP
//! percent (5), 1 to 50, onto the steps of STEP - from 52% up to 55 and
//! down to 50 - between 0 and 100: a percent as loud as it sounds, as on
//! Volume's slider and in `Audio VOLUME`. Held, they repeat. Mute switches
//! the output's sound off and on again, its volume kept; a volume key
//! while it is off switches it on.
//!
//! The others go to the Player that runs (SYS:Programs/Player) as a
//! `sdk.player.Key` on its port, and the Player carries them out as its
//! window's own keys: play/pause pauses and goes on, play and pause do
//! only that, stop stops, previous and next go to the song before and
//! after, rewind and fast forward jump ten seconds. With no Player running
//! they do nothing. A Player slow to answer holds up only its own keys:
//! `in_flight` are on their way at most, a key pressed past them is let
//! go, and the volume keys work on.
//!
//! While it is active the eleven keys go no further - no window sees
//! them, down or up. Made inactive by the controller
//! (SYS:Commodities/Exchange) they reach the active window as before, and
//! the Player's carries them out there. It has no window: the controller
//! removes it, and Ctrl-C from the shell it was started in ends it.
//! S:Startup-Sequence starts it.
//!
//! CX_PRIORITY is its place among the commodities: one of higher priority
//! sees the keys before it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const kb = sdk.devices.keyboard;
const audio = sdk.devices.audio;
const audiocontrol = sdk.devices.audiocontrol;
const player = sdk.player;
const frame = @import("commodity");
const step_file = @import("step.zig");
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const CxBase = sdk.interface.commodities.CxBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "MediaKeys";
const VERSION = "1.0";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (24.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "STEP/K/N,CX_PRIORITY/K/N";
const arg_step = 0;
const arg_priority = 1;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOMEMORY = "No memory\n";
const MSG_DUPLICATE = "%s runs already\n";
const MSG_BADSTEP = "%s: STEP is 1 to 50 percent\n";

/// The keys it takes.
const keys = [_]u32{
    kb.RAWKEY_MEDIA_STOP,
    kb.RAWKEY_MEDIA_PLAYPAUSE,
    kb.RAWKEY_MEDIA_PREVIOUS,
    kb.RAWKEY_MEDIA_NEXT,
    kb.RAWKEY_MEDIA_REWIND,
    kb.RAWKEY_MEDIA_FASTFORWARD,
    kb.RAWKEY_MEDIA_PLAY,
    kb.RAWKEY_MEDIA_PAUSE,
    kb.RAWKEY_MUTE,
    kb.RAWKEY_VOLUMEDOWN,
    kb.RAWKEY_VOLUMEUP,
};

/// The Player's keys that may be on their way to it at once.
const in_flight = 4;

/// The keys sent to the Player and not yet answered, in this program's
/// memory until each comes back to `port`.
const Sent = struct {
    port: *exec.MsgPort,
    keys: [in_flight]player.Key = @splat(.{}),
    out: [in_flight]bool = @splat(false),

    /// The key to the Player that runs, in a message not on its way; let
    /// go when there is no Player, or none free.
    fn send(sent: *Sent, sys: *ExecBase, code: u32) void {
        for (&sent.keys, &sent.out) |*key, *out| {
            if (out.*) continue;
            key.* = .{ .message = .{ .reply_port = sent.port, .length = @sizeOf(player.Key) }, .code = code };
            out.* = sys.SafePutToPort(&key.message, player.PORT_NAME);
            return;
        }
    }

    /// The answers come back: their messages free again.
    fn collect(sent: *Sent, sys: *ExecBase) void {
        while (sys.GetMsg(sent.port)) |message| {
            for (&sent.keys, &sent.out) |*key, *out| {
                if (&key.message == message) out.* = false;
            }
        }
    }

    /// Every message back, before their memory goes.
    fn drain(sent: *Sent, sys: *ExecBase) void {
        while (true) {
            sent.collect(sys);
            for (sent.out) |out| {
                if (out) break;
            } else return;
            _ = sys.WaitPort(sent.port);
        }
    }
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [2]usize = @splat(0);
    var settings = frame.Settings.read(sys, dl, COMMAND_NAME, template, &argv) orelse return dos.RETURN_FAIL;
    defer settings.done();
    var step: i32 = step_file.default_step;
    var priority: i32 = 0;
    settings.number("STEP", arg_step, &step);
    settings.number("CX_PRIORITY", arg_priority, &priority);
    if (step < 1 or step > step_file.most_step) {
        _ = Printf(dl, MSG_BADSTEP, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_ERROR;
    }

    const cx_lib = sys.OpenLibrary(cx.COMMODITIESNAME, cx.COMMODITIES_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{@as([*:0]const u8, cx.COMMODITIESNAME)});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(cx_lib);
    const cb: *CxBase = @ptrCast(cx_lib);

    // The sound, where the machine has some: without, the volume keys and
    // mute do nothing, and the Player's keys work all the same.
    var control = audiocontrol.Control.open(sys);
    defer if (control) |*open| open.close();

    const reply_port = sys.CreateMsgPort() orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer sys.DeleteMsgPort(reply_port);
    var sent = Sent{ .port = reply_port };
    defer sent.drain(sys);

    const commodity = frame.Commodity.open(sys, cb, .{
        .name = COMMAND_NAME,
        .title = "MediaKeys",
        .descr = "Play, pause and the volume from any window",
        .unique = cx.NBU_UNIQUE | cx.NBU_NOTIFY,
        .pri = priority,
    }) catch |err| {
        switch (err) {
            // The one running was told; it has no window to show.
            error.Duplicate => _ = Printf(dl, MSG_DUPLICATE, .{@as([*:0]const u8, COMMAND_NAME)}),
            error.NoMemory => _ = Printf(dl, MSG_NOMEMORY, .{}),
        }
        return if (err == error.Duplicate) dos.RETURN_WARN else dos.RETURN_FAIL;
    };
    defer commodity.close();

    // Each key, down and up, whatever is held with it: a sender to this
    // program with the key as its id, and a translator with nothing in
    // it, so the key itself goes no further.
    for (keys) |code| {
        const filter = cx.CxFilter(cb, null);
        cb.SetFilterIX(filter, &.{
            .class = ie.IECLASS_RAWKEY,
            .code = code,
            .code_mask = ~ie.IECODE_UP_PREFIX,
            .qualifier = 0,
            .qual_mask = 0,
        });
        cb.AttachCxObj(filter, cx.CxSender(cb, commodity.port, @intCast(code)));
        cb.AttachCxObj(filter, cx.CxTranslate(cb, null));
        if (!commodity.attach(filter)) {
            _ = Printf(dl, MSG_NOMEMORY, .{});
            return dos.RETURN_FAIL;
        }
    }
    commodity.activate(true);

    const reply_mask = reply_port.sigMask();
    loop: while (true) {
        const got = sys.Wait(commodity.signals() | reply_mask);
        if (got & reply_mask != 0) sent.collect(sys);
        if (frame.Commodity.stopped(got)) break;
        while (commodity.next()) |event| switch (event) {
            .end => break :loop,
            // A key let go does nothing; one held down comes again as
            // input.device repeats it.
            .input => |in| if (in.event.code & ie.IECODE_UP_PREFIX == 0) {
                pressed(sys, if (control) |*open| open else null, &sent, @intCast(in.id), @intCast(step));
            },
            // No window, and the list is the controller's business.
            // Made inactive, the filters stop matching and the keys reach
            // the windows: nothing to put back.
            .disabled, .enabled, .show, .hide, .list_changed => {},
        };
    }
    return dos.RETURN_OK;
}

/// A key pressed: the volume keys and mute here, the rest to the Player.
fn pressed(sys: *ExecBase, control: ?*audiocontrol.Control, sent: *Sent, code: u32, step: u32) void {
    switch (code) {
        kb.RAWKEY_VOLUMEUP, kb.RAWKEY_VOLUMEDOWN => if (control) |open| turn(open, code == kb.RAWKEY_VOLUMEUP, step),
        kb.RAWKEY_MUTE => if (control) |open| toggleMute(open),
        else => sent.send(sys, code),
    }
}

/// The output played through a step louder or quieter, and its sound on.
fn turn(control: *audiocontrol.Control, up: bool, step: u32) void {
    var info: audio.AudioInfo = .{};
    if (!control.query(&info) or info.output_id == 0) return;
    control.setVolume(0, step_file.stepped(audiocontrol.percentOf(info.master), up, step));
}

/// The sound of the output played through off, or on again.
fn toggleMute(control: *audiocontrol.Control) void {
    var info: audio.AudioInfo = .{};
    if (!control.query(&info) or info.output_id == 0) return;
    _ = control.setMuted(0, info.muted == 0);
}
