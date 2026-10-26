// SPDX-License-Identifier: MIT
//! Audio: the machine's sound outputs - which plays, which is preferred,
//! how loud each is and what its equalizer does - shown and set. Built
//! against the SDK only.
//!
//!   Audio OUTPUT/K,VOLUME/K/N,EQ/K,PREFER/K,LIST/S,SAVE/S
//!
//! On its own it shows what plays: the output played through, its rate,
//! its sides and its volume, and its equalizer - the preset it is, or its
//! bands; the output preferred, and whether it is there; the streams open
//! and the sounds playing by trigger; the way in.
//!
//!   Output     es8311 (24B61A00), 48000 Hz, one side, volume 80%
//!   Equalizer  Techno (7,6,3,0,-2,-2,0,2,4,5)
//!   Preferred  QEMU USB Audio (ECD5FB99), not there
//!   Streams    1 of 16, 0 of 8 sounds triggered
//!   Input      es8311, one side
//!
//! LIST lists every output instead, its number, its sides and rates, its
//! volume, and which is played through and which preferred; a preferred
//! output that is not there by the name ENV:Sys/audio.prefs gives it. An
//! output is named by its name, any case, or by its number as LIST shows
//! it:
//!
//! - OUTPUT plays through that one from now on, every sound going on;
//! - PREFER makes that one preferred - played through whenever it is
//!   there, and taking the sound over when it comes. A number names one
//!   not plugged in, and so does a name the settings file has; NONE
//!   prefers none;
//! - VOLUME sets how loud everything plays through the output played
//!   through - OUTPUT's, when both are given - in percent of as recorded,
//!   0 to 100; the device keeps it for that output;
//! - EQ sets the equalizer of the same output: a preset by its name, any
//!   case (`Audio EQ Techno`, `Audio EQ "More bass"`, `Audio EQ Flat`),
//!   or ten numbers of dB split by commas, 31 Hz to 16 kHz, each -12 to
//!   12 (`Audio EQ 4,3,0,0,0,0,0,2,3,0`); the device keeps it for that
//!   output;
//! - SAVE keeps what the device has now in ENV:Sys/audio.prefs and
//!   ENVARC:Sys/audio.prefs - each output's volume and equalizer, and the
//!   one preferred - so C:SetPrefs gives it back at the next boot; outputs
//!   the file names that are not plugged in keep their lines.
//!
//! Given any of these, it prints nothing unless something goes wrong, so
//! a script can set the sound up.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const audio = sdk.devices.audio;
const audiocontrol = sdk.devices.audiocontrol;
const prefs = sdk.prefs;
const audio_file = prefs.audio;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Audio";
const VERSION_STRING = "\x00$VER: Audio 1.3 (26.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "OUTPUT/K,VOLUME/K/N,EQ/K,PREFER/K,LIST/S,SAVE/S";
const arg_output = 0;
const arg_volume = 1;
const arg_equalizer = 2;
const arg_prefer = 3;
const arg_list = 4;
const arg_save = 5;
const arg_count = 6;

const MSG_NODEVICE = "%s: no %s - this machine has no sound\n";
const MSG_NOOUTPUT = "%s: no output %s\n";
const MSG_NOSTART = "%s: %s would not start\n";
const MSG_BADVOLUME = "%s: VOLUME is 0 to 100 percent\n";
const MSG_BADEQ = "%s: EQ is a preset - %s - or ten numbers of dB, -12 to 12, split by commas\n";
const MSG_NOEQ = "%s: %s has no equalizer\n";
const MSG_NOTSAVED = "%s: %s could not be written\n";
const MSG_OUTPUT = "Output     %s (%s), %u Hz, %s, volume %u%%\n";
const MSG_SILENT = "Output     none\n";
const MSG_EQUALIZER = "Equalizer  %s (%s)\n";
const MSG_EQUALIZER_BANDS = "Equalizer  %s\n";
const MSG_FLAT = "Equalizer  flat\n";
const MSG_PREFERRED = "Preferred  %s (%s)%s\n";
const MSG_PREFERRED_NUMBER = "Preferred  %s%s\n";
const MSG_PREFERRED_FILED = "Preferred  %s (%s)%s\n";
const MSG_STREAMS = "Streams    %u of %u, %u of %u sounds triggered\n";
const MSG_INPUT = "Input      %s, %s\n";
const MSG_LISTED = "%-20s %s  %s, ";
const MSG_RATE = "%u ";
const MSG_LISTED_END = "Hz, volume %u%%";
const MSG_PLAYING = ", playing";
const MSG_PREFERS = ", preferred";
const MSG_NEWLINE = "\n";
const MSG_ABSENT = "%-20s %s  preferred, not there\n";

const NOT_THERE = ", not there";

/// One or two sides, in words.
fn sidesText(channels: u32) [*:0]const u8 {
    return if (channels == 1) "one side" else "two sides";
}

/// An output's number as LIST shows it, NUL after it.
fn hex(into: *[8:0]u8, id: u32) [*:0]const u8 {
    audio_file.hexText(into[0..8], id);
    into[8] = 0;
    return into;
}

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + ('a' - 'A') else char;
}

/// Whether `name` is `wanted`, whatever the case of its letters.
fn sameName(name: []const u8, wanted: []const u8) bool {
    if (name.len != wanted.len) return false;
    for (name, wanted) |a, b| {
        if (lower(a) != lower(b)) return false;
    }
    return true;
}

fn span(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}

/// The bands EQ names: a preset's, or ten numbers; null for neither.
fn bandsNamed(wanted: []const u8) ?audiocontrol.Bands {
    if (audiocontrol.presetNamed(wanted)) |preset| return preset.bands;
    var bands: audiocontrol.Bands = undefined;
    return if (audio_file.bandsOf(wanted, &bands)) bands else null;
}

/// Every preset's name, split by commas, NUL after it, into `into`.
fn presetNames(into: []u8) [*:0]const u8 {
    var n: usize = 0;
    for (audiocontrol.presets, 0..) |preset, at| {
        const name = span(preset.name);
        const gap: []const u8 = if (at == 0) "" else ", ";
        if (n + gap.len + name.len >= into.len) break;
        @memcpy(into[n..][0..gap.len], gap);
        n += gap.len;
        @memcpy(into[n..][0..name.len], name);
        n += name.len;
    }
    into[n] = 0;
    return @ptrCast(into.ptr);
}

/// The listed output `wanted` names, by its number or its name; null for
/// none.
fn listed(outputs: *const audiocontrol.Outputs, wanted: []const u8) ?u32 {
    if (audio_file.numberOf(wanted)) |id| {
        if (outputs.indexOf(id) != null) return id;
    }
    for (outputs.infos[0..outputs.count]) |*info| {
        if (sameName(audiocontrol.nameOf(info), wanted)) return info.id;
    }
    return null;
}

/// The settings file's outputs, as ENV: has them now; none when it is not
/// there.
fn loadFile(dl: *DosBase, settings: *audio_file.Settings, text: []u8) void {
    const read = prefs.load(dl, audio_file.ENV_FILE, text) orelse return;
    _ = settings.load(read);
}

/// The output PREFER names: one listed, a number of one not there, a name
/// the settings file has, or 0 for NONE; null for none of those.
fn preferredNamed(dl: *DosBase, outputs: *const audiocontrol.Outputs, wanted: []const u8, text: []u8) ?u32 {
    if (sameName(wanted, "NONE")) return 0;
    if (listed(outputs, wanted)) |id| return id;
    if (audio_file.numberOf(wanted)) |id| return id;
    var settings: audio_file.Settings = .{};
    loadFile(dl, &settings, text);
    for (settings.outputs[0..settings.count]) |*output| {
        if (sameName(output.nameText(), wanted)) return output.id;
    }
    return null;
}

/// The name the settings file gives the output of that number, NUL after
/// it, into `into`; null when it gives none.
fn filedName(dl: *DosBase, id: u32, text: []u8, into: *[audio.AUDIO_NAME_LEN:0]u8) ?[*:0]const u8 {
    var settings: audio_file.Settings = .{};
    loadFile(dl, &settings, text);
    const output = settings.find(id) orelse return null;
    const name = output.nameText();
    if (name.len == 0) return null;
    into.* = @splat(0);
    @memcpy(into[0..name.len], name);
    return into;
}

/// What plays: the output, the one preferred, the streams, the way in.
fn showState(dl: *DosBase, control: *audiocontrol.Control, text: []u8) void {
    var device: audio.AudioInfo = .{};
    _ = control.query(&device);
    var info: audio.AudioOutputInfo = .{};
    var number: [8:0]u8 = undefined;
    if (control.current(&info)) {
        info.name[info.name.len - 1] = 0;
        _ = Printf(dl, MSG_OUTPUT, .{
            @as([*:0]const u8, @ptrCast(&info.name)),
            hex(&number, info.id),
            device.rate,
            sidesText(device.channels),
            audiocontrol.percentOf(device.master),
        });
        if (control.hasEqualizer()) showEqualizer(dl, &info.equalizer);
    } else _ = Printf(dl, MSG_SILENT, .{});
    if (device.preferred_id != 0) {
        var outputs: audiocontrol.Outputs = .{};
        outputs.read(control);
        if (outputs.indexOf(device.preferred_id)) |at| {
            _ = Printf(dl, MSG_PREFERRED, .{ outputs.labels[at].?, hex(&number, device.preferred_id), @as([*:0]const u8, "") });
        } else {
            var name: [audio.AUDIO_NAME_LEN:0]u8 = undefined;
            if (filedName(dl, device.preferred_id, text, &name)) |filed| {
                _ = Printf(dl, MSG_PREFERRED_FILED, .{ filed, hex(&number, device.preferred_id), @as([*:0]const u8, NOT_THERE) });
            } else _ = Printf(dl, MSG_PREFERRED_NUMBER, .{ hex(&number, device.preferred_id), @as([*:0]const u8, NOT_THERE) });
        }
    }
    _ = Printf(dl, MSG_STREAMS, .{ device.streams, device.max_streams, device.triggers, device.max_triggers });
    if (device.input) |input| _ = Printf(dl, MSG_INPUT, .{ input, sidesText(device.input_channels) });
}

/// An equalizer: flat, the preset it is with its bands, or its bands.
fn showEqualizer(dl: *DosBase, bands: *const audiocontrol.Bands) void {
    var text: [48:0]u8 = @splat(0);
    _ = audio_file.bandsText(bands, &text);
    const preset = audiocontrol.presetOf(bands);
    if (preset == 0) {
        _ = Printf(dl, MSG_FLAT, .{});
    } else if (preset < audiocontrol.presets.len) {
        _ = Printf(dl, MSG_EQUALIZER, .{ audiocontrol.presets[preset].name, @as([*:0]const u8, &text) });
    } else _ = Printf(dl, MSG_EQUALIZER_BANDS, .{@as([*:0]const u8, &text)});
}

/// Every output, a line each, and the preferred one when it is not there
/// - by the name the settings file gives it, if it gives one.
fn listOutputs(dl: *DosBase, control: *audiocontrol.Control, text: []u8) void {
    var outputs: audiocontrol.Outputs = .{};
    outputs.read(control);
    var number: [8:0]u8 = undefined;
    for (outputs.infos[0..outputs.count], 0..) |*info, at| {
        _ = Printf(dl, MSG_LISTED, .{ outputs.labels[at].?, hex(&number, info.id), sidesText(info.channels) });
        for (info.rates[0..info.rate_count]) |rate| _ = Printf(dl, MSG_RATE, .{rate});
        _ = Printf(dl, MSG_LISTED_END, .{audiocontrol.percentOf(info.volume)});
        if (info.flags & audio.AUDIOOF_CURRENT != 0) _ = Printf(dl, MSG_PLAYING, .{});
        if (info.flags & audio.AUDIOOF_PREFERRED != 0) _ = Printf(dl, MSG_PREFERS, .{});
        _ = Printf(dl, MSG_NEWLINE, .{});
    }
    var device: audio.AudioInfo = .{};
    if (control.query(&device) and device.preferred_id != 0 and outputs.indexOf(device.preferred_id) == null) {
        var name: [audio.AUDIO_NAME_LEN:0]u8 = undefined;
        const filed = filedName(dl, device.preferred_id, text, &name) orelse "";
        _ = Printf(dl, MSG_ABSENT, .{ filed, hex(&number, device.preferred_id) });
    }
}

/// What the device has now, over the file's outputs, written to ENV: and
/// ENVARC:. Whether both were.
fn save(dl: *DosBase, control: *audiocontrol.Control, text: []u8) bool {
    var settings: audio_file.Settings = .{};
    loadFile(dl, &settings, text);
    audio_file.gather(control, &settings);
    const length = audio_file.write(&settings, text);
    var ok = true;
    for ([_][*:0]const u8{ audio_file.ENV_FILE, audio_file.ENVARC_FILE }) |path| {
        if (prefs.save(dl, path, text[0..length])) continue;
        _ = Printf(dl, MSG_NOTSAVED, .{ COMMAND_NAME, path });
        ok = false;
    }
    return ok;
}

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
    const volume = rdargs.number(argv[arg_volume]);
    if (volume) |percent| {
        if (percent < 0 or percent > 100) {
            _ = Printf(dl, MSG_BADVOLUME, .{COMMAND_NAME});
            return dos.RETURN_ERROR;
        }
    }

    var control = audiocontrol.Control.open(sys) orelse {
        _ = Printf(dl, MSG_NODEVICE, .{ COMMAND_NAME, @as([*:0]const u8, audio.AUDIONAME) });
        return dos.RETURN_WARN;
    };
    defer control.close();
    var text: [audio_file.max_file]u8 = undefined;
    var outputs: audiocontrol.Outputs = .{};
    outputs.read(&control);

    const equalizer = rdargs.string(argv[arg_equalizer]);
    const bands: ?audiocontrol.Bands = if (equalizer) |wanted| bandsNamed(span(wanted)) orelse {
        var names: [256]u8 = undefined;
        _ = Printf(dl, MSG_BADEQ, .{ COMMAND_NAME, presetNames(&names) });
        return dos.RETURN_ERROR;
    } else null;

    const output = rdargs.string(argv[arg_output]);
    const prefer = rdargs.string(argv[arg_prefer]);
    const acted = output != null or prefer != null or volume != null or equalizer != null or argv[arg_save] != 0;
    if (output) |wanted| {
        const id = listed(&outputs, span(wanted)) orelse {
            _ = Printf(dl, MSG_NOOUTPUT, .{ COMMAND_NAME, wanted });
            return dos.RETURN_ERROR;
        };
        if (control.play(id) != 0) {
            _ = Printf(dl, MSG_NOSTART, .{ COMMAND_NAME, wanted });
            return dos.RETURN_ERROR;
        }
    }
    if (prefer) |wanted| {
        const id = preferredNamed(dl, &outputs, span(wanted), &text) orelse {
            _ = Printf(dl, MSG_NOOUTPUT, .{ COMMAND_NAME, wanted });
            return dos.RETURN_ERROR;
        };
        _ = control.prefer(id);
    }
    if (volume) |percent| control.setVolume(0, @intCast(percent));
    if (bands) |*wanted| {
        if (!control.hasEqualizer()) {
            _ = Printf(dl, MSG_NOEQ, .{ COMMAND_NAME, @as([*:0]const u8, audio.AUDIONAME) });
            return dos.RETURN_ERROR;
        }
        _ = control.setEqualizer(0, wanted);
    }
    if (argv[arg_save] != 0 and !save(dl, &control, &text)) return dos.RETURN_ERROR;

    if (argv[arg_list] != 0) {
        listOutputs(dl, &control, &text);
    } else if (!acted) showState(dl, &control, &text);
    return dos.RETURN_OK;
}
