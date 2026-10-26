// SPDX-License-Identifier: MIT
//! audio.prefs: which output audio.device prefers, how loud each output
//! plays and what its equalizer does - a line per output:
//!
//!     OUTPUT=24B61A00 VOLUME=80 EQ=4,3,0,0,0,0,0,2,3,0 NAME="es8311" PREFERRED=YES
//!
//! - OUTPUT: the output's number, eight hexadecimal digits, as `Audio
//!   LIST` shows it - the same from one boot to the next.
//! - VOLUME: how loud everything plays through it, in percent of as
//!   recorded: 0 to 100. Left out, 100.
//! - EQ: its equalizer, ten numbers split by commas - the bands from 31 Hz
//!   to 16 kHz, each raised or lowered that many dB, -12 to 12. Left out,
//!   flat, and written only when it is not.
//! - NAME: its name as the board names the part, in double quotes when it
//!   has a space in it. Only read by people, and shown for an output that
//!   is not there; the number is what counts.
//! - PREFERRED: YES on the output played through whenever it is there -
//!   one that comes, headphones plugged in, takes the sound over - and NO
//!   or left out on the others. With none, the device plays through the
//!   first output its drivers made.
//!
//! An output with no line plays at the volume of the one before it, flat.
//! `parseLine` reads a line into an `Output`, `Settings.load` a file's
//! lines, `write` writes the file, explanation and all; `apply` hands the
//! settings to audio.device, and `gather` reads what it has now - each
//! output on its list, its volume, the preferred one - into settings
//! that keep the outputs the file names and the device has not got.
//! C:SetPrefs hands the file to the device at boot.

const audio = @import("../../devices/audio.zig");
const audiocontrol = @import("../../devices/audiocontrol.zig");
const style = @import("style.zig");
const Lines = @import("prefs.zig").Lines;

pub const ENV_FILE = "ENV:Sys/audio.prefs";
pub const ENVARC_FILE = "ENVARC:Sys/audio.prefs";

/// The most outputs the file holds: as many as the device keeps volumes
/// for.
pub const max_outputs = audio.AUDIO_MAX_VOLUMES;
/// The longest line `write` makes, its newline included.
pub const max_line = 144;

/// PREFERRED's words, for false and true.
pub const preferred_names = [2][]const u8{ "NO", "YES" };

/// One output's line.
pub const Output = struct {
    id: u32 = 0,
    /// Percent of as recorded.
    volume: u32 = 100,
    /// Each band raised or lowered that many dB; all 0 is flat.
    bands: audiocontrol.Bands = @splat(0),
    /// NUL-terminated; empty when the line names none.
    name: [audio.AUDIO_NAME_LEN]u8 = @splat(0),
    preferred: bool = false,

    pub fn nameText(output: *const Output) []const u8 {
        var length: usize = 0;
        while (length < output.name.len and output.name[length] != 0) length += 1;
        return output.name[0..length];
    }

    /// Whether its equalizer is flat.
    pub fn flat(output: *const Output) bool {
        for (output.bands) |band| {
            if (band != 0) return false;
        }
        return true;
    }

    pub fn setName(output: *Output, text: []const u8) void {
        const length = @min(text.len, output.name.len - 1);
        output.name = @splat(0);
        @memcpy(output.name[0..length], text[0..length]);
    }
};

/// Every output's line, in the order of the file.
pub const Settings = struct {
    outputs: [max_outputs]Output = @splat(.{}),
    count: usize = 0,

    /// The output of that number, or null.
    pub fn find(settings: *Settings, id: u32) ?*Output {
        for (settings.outputs[0..settings.count]) |*output| {
            if (output.id == id) return output;
        }
        return null;
    }

    /// The output of that number, put at the end when it is not there;
    /// null when there is no room.
    pub fn need(settings: *Settings, id: u32) ?*Output {
        if (settings.find(id)) |output| return output;
        if (settings.count == max_outputs) return null;
        const output = &settings.outputs[settings.count];
        output.* = .{ .id = id };
        settings.count += 1;
        return output;
    }

    /// The preferred output, or null for none.
    pub fn preferred(settings: *Settings) ?*Output {
        for (settings.outputs[0..settings.count]) |*output| {
            if (output.preferred) return output;
        }
        return null;
    }

    /// The output of that number made the preferred one, and none for 0.
    pub fn prefer(settings: *Settings, id: u32) void {
        for (settings.outputs[0..settings.count]) |*output| output.preferred = false;
        if (id == 0) return;
        if (settings.need(id)) |output| output.preferred = true;
    }

    /// Every line of a file that reads, a line for a number already there
    /// taking its place; how many were passed over.
    pub fn load(settings: *Settings, text: []const u8) u32 {
        var skipped: u32 = 0;
        var lines = Lines{ .text = text };
        while (lines.next()) |line| {
            if (!style.hasWords(line.text)) continue;
            var output: Output = .{};
            if (parseLine(line.text, &output) != null) {
                skipped += 1;
                continue;
            }
            settings.put(&output);
        }
        return skipped;
    }

    /// A line read made the settings': in the place of its number, or at
    /// the end; past the room there is, passed over. Preferred, it is the
    /// only one.
    pub fn put(settings: *Settings, output: *const Output) void {
        const place = settings.need(output.id) orelse return;
        place.* = output.*;
        if (output.preferred) settings.prefer(output.id);
    }
};

fn blank(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\r' or char == '\n';
}

fn hexDigit(char: u8) ?u32 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

/// EQ's numbers into `bands`: as many as there are bands, split by
/// commas, each a whole number of dB in the range; false when they are
/// not.
pub fn bandsOf(text: []const u8, bands: *audiocontrol.Bands) bool {
    var band: usize = 0;
    var at: usize = 0;
    while (true) : (band += 1) {
        if (band == bands.len) return false;
        var end = at;
        while (end < text.len and text[end] != ',') end += 1;
        var digits = text[at..end];
        const negative = digits.len != 0 and digits[0] == '-';
        if (negative or (digits.len != 0 and digits[0] == '+')) digits = digits[1..];
        const value = style.decimal(digits) orelse return false;
        if (value > audio.AUDIO_EQ_RANGE) return false;
        const db: i8 = @intCast(value);
        bands[band] = if (negative) -db else db;
        if (end == text.len) break;
        at = end + 1;
    }
    return band + 1 == bands.len;
}

/// An output's number: one to eight hexadecimal digits, not 0.
pub fn numberOf(text: []const u8) ?u32 {
    if (text.len == 0 or text.len > 8) return null;
    var value: u32 = 0;
    for (text) |char| value = value << 4 | (hexDigit(char) orelse return null);
    return if (value == 0) null else value;
}

/// A line read into `output`: null when it is taken, else what is wrong
/// with it.
pub fn parseLine(text: []const u8, output: *Output) ?[*:0]const u8 {
    var given = false;
    var i: usize = 0;
    while (true) {
        while (i < text.len and blank(text[i])) i += 1;
        if (i >= text.len) break;
        var end = i;
        while (end < text.len and !blank(text[end]) and text[end] != '=') end += 1;
        const word = text[i..end];
        i = end;
        if (i < text.len and text[i] == '=') i += 1;
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
        if (style.same(word, "OUTPUT")) {
            output.id = numberOf(value) orelse return "OUTPUT is an output's number, as Audio LIST shows it";
            given = true;
        } else if (style.same(word, "VOLUME")) {
            const percent = style.decimal(value) orelse return "VOLUME is 0 to 100 percent";
            if (percent > 100) return "VOLUME is 0 to 100 percent";
            output.volume = percent;
        } else if (style.same(word, "EQ")) {
            if (!bandsOf(value, &output.bands)) return "EQ is ten numbers of dB, -12 to 12, split by commas";
        } else if (style.same(word, "NAME")) {
            if (value.len >= output.name.len) return "NAME is longer than 31 characters";
            output.setName(value);
        } else if (style.same(word, "PREFERRED")) {
            output.preferred = for (preferred_names, 0..) |name, k| {
                if (style.same(value, name)) break k == 1;
            } else return "PREFERRED is YES or NO";
        } else return "not in the form OUTPUT=number VOLUME=percent EQ=dB,... NAME=name PREFERRED=YES";
    }
    if (!given) return "a line names its OUTPUT";
    return null;
}

fn put(into: []u8, at: *usize, text: []const u8) void {
    @memcpy(into[at.*..][0..text.len], text);
    at.* += text.len;
}

fn decimalText(into: []u8, at: *usize, value: u32) void {
    var digits: [10]u8 = undefined;
    var n: usize = 0;
    var left = value;
    while (true) {
        digits[n] = '0' + @as(u8, @intCast(left % 10));
        n += 1;
        left /= 10;
        if (left == 0) break;
    }
    for (0..n) |k| into[at.* + k] = digits[n - 1 - k];
    at.* += n;
}

/// An equalizer's bands as EQ has them - each band's dB, split by commas -
/// into `into` (40 bytes will do); how many bytes.
pub fn bandsText(bands: *const audiocontrol.Bands, into: []u8) usize {
    var n: usize = 0;
    for (bands, 0..) |band, at| {
        if (at != 0) put(into, &n, ",");
        if (band < 0) put(into, &n, "-");
        decimalText(into, &n, @abs(band));
    }
    return n;
}

/// An output's number as the file and `Audio LIST` write it: eight
/// hexadecimal digits.
pub fn hexText(into: *[8]u8, id: u32) void {
    const digits = "0123456789ABCDEF";
    for (into, 0..) |*char, k| char.* = digits[(id >> @intCast(28 - 4 * k)) & 0xF];
}

/// One output's line into `into` (`max_line` will do), no newline; how
/// many bytes.
pub fn writeLine(output: *const Output, into: []u8) usize {
    var n: usize = 0;
    put(into, &n, "OUTPUT=");
    var number: [8]u8 = undefined;
    hexText(&number, output.id);
    put(into, &n, &number);
    put(into, &n, " VOLUME=");
    decimalText(into, &n, @min(output.volume, 100));
    if (!output.flat()) {
        put(into, &n, " EQ=");
        n += bandsText(&output.bands, into[n..]);
    }
    const name = output.nameText();
    if (name.len != 0) {
        var spaced = false;
        for (name) |char| {
            if (char == ' ') spaced = true;
        }
        put(into, &n, " NAME=");
        if (spaced) put(into, &n, "\"");
        put(into, &n, name);
        if (spaced) put(into, &n, "\"");
    }
    if (output.preferred) put(into, &n, " PREFERRED=YES");
    return n;
}

/// How many bytes the whole file takes at most: room for `write`.
pub const max_file = header.len + max_outputs * max_line;

/// The whole file - the explanation, then a line for each output - into
/// `into` (`max_file` will do); how many bytes.
pub fn write(settings: *const Settings, into: []u8) usize {
    var n: usize = 0;
    put(into, &n, header);
    for (settings.outputs[0..settings.count]) |*output| {
        n += writeLine(output, into[n..]);
        into[n] = '\n';
        n += 1;
    }
    return n;
}

/// The settings handed to audio.device: each output's volume and
/// equalizer, there or not, then the preferred output - none, without
/// one. A device without an equalizer takes the volumes.
pub fn apply(control: *audiocontrol.Control, settings: *Settings) void {
    const equalizes = control.hasEqualizer();
    for (settings.outputs[0..settings.count]) |*output| {
        control.setVolume(output.id, output.volume);
        if (equalizes) _ = control.setEqualizer(output.id, &output.bands);
    }
    const preferred: u32 = if (settings.preferred()) |output| output.id else 0;
    _ = control.prefer(preferred);
}

/// What audio.device has now into `settings`: each output on its list
/// with its name, volume and equalizer - put in the place of its number,
/// or at the end - and which is preferred. Outputs the settings name and
/// the device has not got are kept as they are.
pub fn gather(control: *audiocontrol.Control, settings: *Settings) void {
    var info: audio.AudioOutputInfo = .{};
    var after: u32 = 0;
    while (control.next(after, &info)) : (after = info.id) {
        const output = settings.need(info.id) orelse continue;
        output.volume = audiocontrol.percentOf(info.volume);
        output.bands = info.equalizer;
        info.name[info.name.len - 1] = 0;
        output.setName(audiocontrol.nameOf(&info));
    }
    var device: audio.AudioInfo = .{};
    if (control.query(&device)) settings.prefer(device.preferred_id);
}

/// The file's explanation, every line a comment.
pub const header =
    \\# ENVARC:Sys/audio.prefs - the outputs audio.device plays through: a
    \\# line each, which C:SetPrefs hands to the device at boot.
    \\#
    \\# OUTPUT     the output's number, as Audio LIST shows it.
    \\# VOLUME     how loud everything plays through it, in percent of as
    \\#            recorded: 0 to 100.
    \\# EQ         its equalizer: ten numbers split by commas, the bands
    \\#            31 62 125 250 500 1k 2k 4k 8k 16k Hz, each raised or
    \\#            lowered that many dB, -12 to 12. Left out, flat.
    \\# NAME       its name - in double quotes when it has a space in it -
    \\#            for reading: the number is what counts.
    \\# PREFERRED  YES on the output played through whenever it is there,
    \\#            headphones that are plugged in taking the sound over.
    \\#
    \\# An output with no line plays at the volume of the one before it,
    \\# flat; with none preferred, the device plays through the first its
    \\# drivers made. As:
    \\#
    \\# OUTPUT=24B61A00 VOLUME=80 EQ=4,3,0,0,0,0,0,2,3,0 NAME=es8311 PREFERRED=YES
    \\
;
