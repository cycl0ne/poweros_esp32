// SPDX-License-Identifier: MIT
//! sound.prefs: what a beep (`DisplayBeep`) does - one line,
//! `FLASH=YES SOUND=BEEP VOLUME=80 TONE=880 DURATION=80`:
//!
//! - FLASH: whether the display flashes - YES or NO.
//! - SOUND: what is heard - NONE, BEEP (a tone, made from the line) or
//!   SAMPLE (the file SAMPLE names, read whole).
//! - VOLUME: how loud, in percent of as recorded: 1 to 100.
//! - TONE: the beep's pitch, in Hz: 100 to 8000.
//! - DURATION: how long the beep lasts, in milliseconds: 10 to 1000.
//! - SAMPLE: the sound file - any a sound datatype reads - in double
//!   quotes when its name has a space in it.
//!
//! One left out has the value the system starts with: a flash and no
//! sound. `parse` reads the line into `Settings`, `write` writes them as
//! the line, `makeBeep` makes the tone into memory the caller gives, as
//! `IPREFS_BeepSound` takes it, and `header` is the explanation a program
//! that writes the file puts before it. C:SetPrefs hands it to intuition
//! at boot.
//!
//! The tone is a sine at TONE, made at `beep_rate`: it rises over two
//! milliseconds, so it starts without a click, and dies away evenly to
//! nothing at its end, as a struck note does.

const intuition = @import("../intuition/intuition.zig");
const audio = @import("../../devices/audio.zig");
const style = @import("style.zig");

/// What a beep sounds like: `Settings.sound`.
pub const SOUND_NONE: u32 = 0;
pub const SOUND_BEEP: u32 = 1;
pub const SOUND_SAMPLE: u32 = 2;

/// The longest SAMPLE file name, its NUL not counted.
pub const sample_len = 255;

/// The line's settings, each as the system starts when the line leaves
/// it out.
pub const Settings = struct {
    /// 1 when the display flashes.
    flash: u32 = 1,
    /// `SOUND_`.
    sound: u32 = SOUND_NONE,
    /// Percent of as recorded.
    volume: u32 = 80,
    /// Hz.
    tone: u32 = 880,
    /// Milliseconds.
    duration: u32 = 80,
    /// The file, NUL-terminated; empty for none.
    sample: [sample_len:0]u8 = @splat(0),
};

pub const ENV_FILE = "ENV:Sys/sound.prefs";
pub const ENVARC_FILE = "ENVARC:Sys/sound.prefs";

/// The words of SOUND and FLASH, by their value.
pub const sound_names = [3][]const u8{ "NONE", "BEEP", "SAMPLE" };
pub const flash_names = [2][]const u8{ "NO", "YES" };

/// The rate the tone is made at, in frames a second.
pub const beep_rate: u32 = 48_000;

/// The line read into `settings`: null when it is taken, else what is
/// wrong with it.
pub fn parse(text: []const u8, settings: *Settings) ?[*:0]const u8 {
    var i: usize = 0;
    while (true) {
        while (i < text.len and blank(text[i])) i += 1;
        if (i >= text.len) break;
        var end = i;
        while (end < text.len and !blank(text[end]) and text[end] != '=') end += 1;
        const word = text[i..end];
        i = end;
        if (i < text.len and text[i] == '=') i += 1 else {
            while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        }
        var value: []const u8 = undefined;
        if (i < text.len and text[i] == '"') {
            const from = i + 1;
            var close = from;
            while (close < text.len and text[close] != '"') close += 1;
            if (close >= text.len) return "a quoted value has no closing quote";
            value = text[from..close];
            i = close + 1;
        } else {
            var value_end = i;
            while (value_end < text.len and !blank(text[value_end])) value_end += 1;
            value = text[i..value_end];
            i = value_end;
        }
        if (style.same(word, "FLASH")) {
            settings.flash = for (flash_names, 0..) |name, k| {
                if (style.same(value, name)) break @intCast(k);
            } else return "FLASH is YES or NO";
        } else if (style.same(word, "SOUND")) {
            settings.sound = for (sound_names, 0..) |name, k| {
                if (style.same(value, name)) break @intCast(k);
            } else return "SOUND is NONE, BEEP or SAMPLE";
        } else if (style.same(word, "VOLUME")) {
            settings.volume = within(value, 1, 100) orelse return "VOLUME is 1 to 100 percent";
        } else if (style.same(word, "TONE")) {
            settings.tone = within(value, 100, 8000) orelse return "TONE is 100 to 8000 Hz";
        } else if (style.same(word, "DURATION")) {
            settings.duration = within(value, 10, 1000) orelse return "DURATION is 10 to 1000 milliseconds";
        } else if (style.same(word, "SAMPLE")) {
            if (value.len > sample_len) return "SAMPLE's name is longer than 255 characters";
            settings.sample = @splat(0);
            @memcpy(settings.sample[0..value.len], value);
        } else return "not in the form FLASH=YES SOUND=BEEP VOLUME=percent TONE=Hz DURATION=ms SAMPLE=file";
    }
    if (settings.sound == SOUND_SAMPLE and settings.sample[0] == 0) return "SOUND=SAMPLE wants a SAMPLE file";
    return null;
}

fn blank(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\r' or char == '\n';
}

/// A number from `low` to `high`, or null.
fn within(value: []const u8, low: u32, high: u32) ?u32 {
    const got = style.decimal(value) orelse return null;
    return if (got < low or got > high) null else got;
}

fn number(value: u32, into: []u8) usize {
    var digits: [10]u8 = undefined;
    var n: usize = 0;
    var left = value;
    while (true) {
        digits[n] = '0' + @as(u8, @intCast(left % 10));
        n += 1;
        left /= 10;
        if (left == 0) break;
    }
    for (0..n) |i| into[i] = digits[n - 1 - i];
    return n;
}

/// `settings` written as the line, SAMPLE only when it names a file,
/// into `into` (352 bytes will do); how many bytes, no newline.
pub fn write(settings: *const Settings, into: []u8) usize {
    var n: usize = 0;
    const put = struct {
        fn text(dst: []u8, at: *usize, s: []const u8) void {
            @memcpy(dst[at.*..][0..s.len], s);
            at.* += s.len;
        }
    }.text;
    put(into, &n, "FLASH=");
    put(into, &n, flash_names[@min(settings.flash, 1)]);
    put(into, &n, " SOUND=");
    put(into, &n, sound_names[@min(settings.sound, 2)]);
    put(into, &n, " VOLUME=");
    n += number(settings.volume, into[n..]);
    put(into, &n, " TONE=");
    n += number(settings.tone, into[n..]);
    put(into, &n, " DURATION=");
    n += number(settings.duration, into[n..]);
    var length: usize = 0;
    while (length < sample_len and settings.sample[length] != 0) length += 1;
    if (length != 0) {
        const name = settings.sample[0..length];
        var spaced = false;
        for (name) |char| {
            if (char == ' ') spaced = true;
        }
        put(into, &n, " SAMPLE=");
        if (spaced) put(into, &n, "\"");
        put(into, &n, name);
        if (spaced) put(into, &n, "\"");
    }
    return n;
}

/// How many frames the tone takes at `beep_rate`.
pub fn beepFrames(settings: *const Settings) u32 {
    return beep_rate * settings.duration / 1000;
}

/// audio.device's volume for the line's percent.
pub fn volumeOf(settings: *const Settings) u32 {
    return audio.AUDIO_VOLUME_UNITY * settings.volume / 100;
}

/// One cycle of a sine, a little below full scale, worked out while
/// compiling.
const sine_len = 256;
const sine: [sine_len]i32 = blk: {
    @setEvalBranchQuota(10_000);
    var table: [sine_len]i32 = undefined;
    for (0..sine_len) |i| {
        const angle = 2.0 * 3.141592653589793 * @as(f64, @floatFromInt(i)) / sine_len;
        table[i] = @intFromFloat(@round(@sin(angle) * 30000.0));
    }
    break :blk table;
};

/// The tone made into `samples`, which holds `beepFrames` of them at
/// least, one channel: what `IPREFS_BeepSound` takes, pointing at them.
pub fn makeBeep(settings: *const Settings, samples: []i16) intuition.BeepSound {
    const frames = beepFrames(settings);
    const rise: u32 = beep_rate * 2 / 1000;
    // The position in the cycle, in 2^32ths of it, and its step a frame.
    const step: u32 = @intCast((@as(u64, settings.tone) << 32) / beep_rate);
    var phase: u32 = 0;
    for (0..frames) |at| {
        const index = phase >> 24;
        const fine: i32 = @intCast((phase >> 16) & 0xFF);
        const here = sine[index];
        const next = sine[(index + 1) % sine_len];
        const wave: i64 = here + @divFloor((next - here) * fine, 256);
        const frame: u32 = @intCast(at);
        const rising: i64 = @min(frame, rise);
        const level = @divTrunc(wave * rising * (frames - frame), @as(i64, rise) * frames);
        samples[at] = @intCast(level);
        phase +%= step;
    }
    return .{
        .samples = samples.ptr,
        .frames = frames,
        .rate = beep_rate,
        .channels = 1,
        .volume = volumeOf(settings),
    };
}

/// The file's explanation, every line a comment.
pub const header =
    \\# ENVARC:Sys/sound.prefs - what a beep does: the flash of the display
    \\# and the sound, which C:SetPrefs hands to intuition at boot. One line:
    \\#
    \\# FLASH     whether the display flashes: YES or NO.
    \\# SOUND     what is heard: NONE, BEEP (a tone) or SAMPLE (the file
    \\#           SAMPLE names).
    \\# VOLUME    how loud, in percent of as recorded: 1 to 100.
    \\# TONE      the beep's pitch, in Hz: 100 to 8000.
    \\# DURATION  how long the beep lasts, in milliseconds: 10 to 1000.
    \\# SAMPLE    a sound file, any a sound datatype reads, played whole -
    \\#           in double quotes when its name has a space in it.
    \\#
    \\# One left out has the value the system starts with. A beep that has
    \\# a sound and cannot be heard - no audio.device - flashes instead.
    \\# These are the system's own:
    \\#
    \\# FLASH=YES SOUND=NONE VOLUME=80 TONE=880 DURATION=80
    \\
;
