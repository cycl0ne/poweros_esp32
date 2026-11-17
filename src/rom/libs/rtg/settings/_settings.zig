// SPDX-License-Identifier: MPL-2.0
//! The settings: what `display.prefs` says of the devices and the
//! outputs, held as two lists of lines, read from the file's text,
//! written as it, and applied to the boards.
//!
//! **The lines.** A device's line is found by the device's name
//! ("pci.01:00.0"), an output's by its board's name ("amd.0") and the
//! monitor it is for. An output may have several: one for each monitor
//! it was set up with, and one that names none, which is a panel's, or
//! for whatever is on the connector. The line in force for a board
//! (`lineOf`) is the one that names the monitor on it now, else the one
//! that names none.
//!
//! **Applied** (`applyTo`), a line does five things to its board. Its
//! MODE is the mode the board comes up in - the board's default - where
//! the board has it, and its TIMINGS a mode of a monitor that names none
//! (`monitor/_monitor.zig` asks for both as it makes the list). MIRROR
//! and BRIGHTNESS are set through the library's own calls. RANGE is put
//! in the board's info, and a board whose driver reads it is shown again.
//! FIRST puts the board in front of the others on the library's list.
//! What a line does not say is left as it is; a board with no line has
//! the default its driver or its monitor gave it, the range its monitor
//! asks for, and its own place on the list.
//!
//! A device's line is put in front of the device's tags, for the driver
//! that is offered the device afterwards (`dress`): BUFFERS as
//! `RTGA_Buffers`, COMPOSE as `RTGA_Compose`. A device a driver has
//! already keeps the tags it was offered with.
//!
//! **Locks.** The two lists are under the base's `settings_lock`. It is
//! the last taken: a board's lock may be held when it is asked for, and
//! nothing waits for a board while holding it.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const SettingScan = sdk.utility.SettingScan;
const err = rtg.errors;
const tags = rtg.tags;
const monitor_flags = rtg.modes;

const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const devices = @import("../device/_device.zig");
const modes = @import("../mode/_mode.zig");
const monitors = @import("../monitor/_monitor.zig");
const shows = @import("../display/_display.zig");

/// An output's line: the board's name and what the line says.
pub const Line = struct {
    node: exec.Node = .{},
    /// The board's name, NUL-terminated.
    name: [rtg.drivers.RTG_NAME_MAX]u8 = @splat(0),
    settings: rtg.RtgSettings = .{},
};

/// A device's line.
pub const DeviceLine = struct {
    node: exec.Node = .{},
    /// The device's name, NUL-terminated.
    name: [rtg.drivers.RTG_NAME_MAX]u8 = @splat(0),
    /// DEVSET_*
    flags: u32 = 0,
    /// With `DEVSET_BUFFERS`.
    buffers: u32 = 0,
};

/// DeviceLine.flags
/// No driver from the disk is bound to the device.
pub const DEVSET_DRIVER_OFF: u32 = 1 << 0;
/// `buffers` is the most pictures at once on each of its boards.
pub const DEVSET_BUFFERS: u32 = 1 << 1;
/// The line says whether its screens' windows are composed: they are
/// with `DEVSET_COMPOSE_ON`.
pub const DEVSET_COMPOSE: u32 = 1 << 2;
pub const DEVSET_COMPOSE_ON: u32 = 1 << 3;

/// The longest line the file is written with, its newline included, and
/// the largest file that is read.
pub const line_most = 288;
pub const file_most = 64 * 1024;

/// What the file starts with.
pub const header =
    \\# ENVARC:Sys/display.prefs - the displays: a line for a device or for
    \\# an output, which C:SetPrefs hands to rtg.library at boot.
    \\#
    \\# DEVICE      a device's name, as Rtg DEVICES shows it.
    \\#   DRIVER    OFF: no driver from the disk is bound to it.
    \\#   BUFFERS   the most pictures at once on each of its boards.
    \\#   COMPOSE   YES or NO: whether each window draws into a buffer of
    \\#             its own.
    \\# OUTPUT      a board's name, as Rtg shows it.
    \\#   MONITOR   the monitor the line is for - maker:product:serial -
    \\#             and no other; left out, a panel or whatever is there.
    \\#   MODE      the mode it comes up in: WIDTHxHEIGHT or
    \\#             WIDTHxHEIGHT@HZ.
    \\#   FIRST     YES: this board is the first, the machine's display.
    \\#   MIRROR    X, Y, XY or NONE.
    \\#   BRIGHTNESS  0 to 100.
    \\#   RANGE     FULL or LIMITED: the colour range, for a television.
    \\#   TIMINGS   for a monitor that says nothing of itself: the pixel
    \\#             clock in Hz, the width, front porch, sync and back
    \\#             porch, the same four in lines, +H or -H, +V or -V.
    \\#
    \\
;

// --- the lists ----------------------------------------------------------------

/// Takes the settings' lock.
///
/// INPUTS:
/// - `rb` - the library.
pub fn obtain(rb: *RtgBase) void {
    rb.sys_base.ObtainSemaphore(&rb.settings_lock);
}

/// Gives the settings' lock back.
///
/// INPUTS:
/// - `rb` - the library.
pub fn release(rb: *RtgBase) void {
    rb.sys_base.ReleaseSemaphore(&rb.settings_lock);
}

fn lineOfNode(node: *exec.Node) *Line {
    return @fieldParentPtr("node", node);
}

fn deviceLineOfNode(node: *exec.Node) *DeviceLine {
    return @fieldParentPtr("node", node);
}

/// Every line given back.
///
/// INPUTS:
/// - `rb` - the library; the settings' lock is held, or nothing else
///   runs.
pub fn clear(rb: *RtgBase) void {
    const sys = rb.sys_base;
    while (sys.RemHead(&rb.output_lines)) |node| sys.FreeVec(lineOfNode(node));
    while (sys.RemHead(&rb.device_lines)) |node| sys.FreeVec(deviceLineOfNode(node));
}

/// A monitor as a line names it.
pub const Identity = struct {
    maker: [4]u8 = @splat(0),
    product: u32 = 0,
    serial: u32 = 0,
};

/// The monitor on a board, as a line would name it: null on a panel's
/// board, with nothing on the connector, and for a monitor that does not
/// say who it is.
///
/// INPUTS:
/// - `board` - the board; its lock is held, or it is on no list yet.
pub fn identityOf(board: *rtg.RtgBoard) ?Identity {
    const state = boards.privateOf(board).monitor orelse return null;
    if (state.info.flags & monitor_flags.RTGMON_EDID == 0) return null;
    return .{ .maker = state.info.maker, .product = state.info.product, .serial = state.info.serial };
}

/// Whether a line's monitor is that one.
fn forMonitor(settings: *const rtg.RtgSettings, identity: Identity) bool {
    return same(text(&settings.maker), text(&identity.maker)) and
        settings.product == identity.product and settings.serial == identity.serial;
}

/// The line of that output for that monitor - or, for null, the one that
/// names no monitor.
fn find(rb: *RtgBase, name: []const u8, identity: ?Identity) ?*Line {
    var node = rb.output_lines.first();
    while (node) |n| : (node = n.next()) {
        const line = lineOfNode(n);
        if (!same(text(&line.name), name)) continue;
        const names = line.settings.flags & rtg.RTGSET_MONITOR != 0;
        if (identity) |who| {
            if (names and forMonitor(&line.settings, who)) return line;
        } else if (!names) return line;
    }
    return null;
}

/// The line in force for a board, copied out: the one for the monitor on
/// it now, else the one that names none.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its lock is held, or it is on no list yet.
/// - `into` - takes the line; flags of 0 where the board has none.
///
/// RESULT:
/// Whether the board has a line.
pub fn lineOf(rb: *RtgBase, board: *rtg.RtgBoard, into: *rtg.RtgSettings) bool {
    into.* = .{};
    const name = text(&boards.privateOf(board).name_buf);
    if (name.len == 0) return false;
    const identity = identityOf(board);
    obtain(rb);
    defer release(rb);
    const line = (if (identity) |who| find(rb, name, who) else null) orelse find(rb, name, null) orelse return false;
    into.* = line.settings;
    return true;
}

/// An output's line made, changed or - for one that says nothing - taken
/// off the list.
///
/// INPUTS:
/// - `rb` - the library; the settings' lock is held.
/// - `name` - the board's name.
/// - `settings` - what the line says, the monitor it is for with it.
///
/// RESULT:
/// False without memory for a new line.
pub fn put(rb: *RtgBase, name: []const u8, settings: *const rtg.RtgSettings) bool {
    const sys = rb.sys_base;
    const identity: ?Identity = if (settings.flags & rtg.RTGSET_MONITOR != 0)
        .{ .maker = settings.maker, .product = settings.product, .serial = settings.serial }
    else
        null;
    const says = settings.flags & ~@as(u32, rtg.RTGSET_MONITOR) != 0;
    if (find(rb, name, identity)) |line| {
        if (says) {
            line.settings = settings.*;
        } else {
            sys.Remove(&line.node);
            sys.FreeVec(line);
        }
        return true;
    }
    if (!says) return true;
    const memory = sys.AllocVec(@sizeOf(Line), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
    const line: *Line = @ptrCast(@alignCast(memory));
    line.* = .{ .settings = settings.* };
    _ = copy(&line.name, 0, name);
    sys.AddTail(&rb.output_lines, &line.node);
    return true;
}

/// A board's name, as its line carries it.
///
/// INPUTS:
/// - `board` - the board.
pub fn nameOf(board: *rtg.RtgBoard) []const u8 {
    return text(&boards.privateOf(board).name_buf);
}

/// FIRST taken from every line but those of one output: one board is the
/// first.
///
/// INPUTS:
/// - `rb` - the library; the settings' lock is held.
/// - `name` - the output that keeps it.
pub fn onlyFirst(rb: *RtgBase, name: []const u8) void {
    var node = rb.output_lines.first();
    while (node) |n| {
        node = n.next();
        const line = lineOfNode(n);
        if (same(text(&line.name), name)) continue;
        line.settings.flags &= ~@as(u32, rtg.RTGSET_FIRST);
        // A line that said nothing else is gone with it.
        if (line.settings.flags & ~@as(u32, rtg.RTGSET_MONITOR) == 0) {
            rb.sys_base.Remove(n);
            rb.sys_base.FreeVec(line);
        }
    }
}

/// A device's line, or null.
///
/// INPUTS:
/// - `rb` - the library; the settings' lock is held.
/// - `name` - the device's name.
pub fn findDevice(rb: *RtgBase, name: []const u8) ?*DeviceLine {
    var node = rb.device_lines.first();
    while (node) |n| : (node = n.next()) {
        const line = deviceLineOfNode(n);
        if (same(text(&line.name), name)) return line;
    }
    return null;
}

/// A device's line, made where the device has none. Null without memory.
///
/// INPUTS:
/// - `rb` - the library; the settings' lock is held.
/// - `name` - the device's name.
pub fn needDevice(rb: *RtgBase, name: []const u8) ?*DeviceLine {
    if (findDevice(rb, name)) |line| return line;
    const sys = rb.sys_base;
    const memory = sys.AllocVec(@sizeOf(DeviceLine), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const line: *DeviceLine = @ptrCast(@alignCast(memory));
    line.* = .{};
    _ = copy(&line.name, 0, name);
    sys.AddTail(&rb.device_lines, &line.node);
    return line;
}

/// A device's line that says nothing taken off the list.
///
/// INPUTS:
/// - `rb` - the library; the settings' lock is held.
/// - `line` - the line.
pub fn dropIfEmpty(rb: *RtgBase, line: *DeviceLine) void {
    if (line.flags != 0) return;
    rb.sys_base.Remove(&line.node);
    rb.sys_base.FreeVec(line);
}

// --- text ---------------------------------------------------------------------

/// A NUL-terminated buffer's characters.
fn text(buffer: []const u8) []const u8 {
    var length: usize = 0;
    while (length < buffer.len and buffer[length] != 0) length += 1;
    return buffer[0..length];
}

fn upper(char: u8) u8 {
    return if (char >= 'a' and char <= 'z') char - ('a' - 'A') else char;
}

/// Whether two texts are one, whatever the case of their letters.
fn same(first: []const u8, second: []const u8) bool {
    if (first.len != second.len) return false;
    for (first, second) |one, other| {
        if (upper(one) != upper(other)) return false;
    }
    return true;
}

/// `source` into `buffer` from `at` on, as far as it fits with a NUL to
/// follow; where the next character goes.
fn copy(buffer: []u8, at: usize, source: []const u8) usize {
    var index = at;
    for (source) |char| {
        if (index + 1 >= buffer.len) break;
        buffer[index] = char;
        index += 1;
    }
    buffer[index] = 0;
    return index;
}

/// A number in `radix`, the whole of `digits`; null for none, for a
/// character that is no digit, and for one that does not fit 32 bits.
fn number(digits: []const u8, radix: u32) ?u32 {
    if (digits.len == 0) return null;
    var value: u64 = 0;
    for (digits) |char| {
        const digit: u32 = switch (upper(char)) {
            '0'...'9' => char - '0',
            'A'...'F' => upper(char) - 'A' + 10,
            else => return null,
        };
        if (digit >= radix) return null;
        value = value * radix + digit;
        if (value > 0xFFFF_FFFF) return null;
    }
    return @intCast(value);
}

/// What is left of `rest` after its first part, cut at `mark`: the part
/// is answered and `rest` moved past the mark. The whole of it where the
/// mark is not there.
fn part(rest: *[]const u8, mark: u8) []const u8 {
    const whole = rest.*;
    for (whole, 0..) |char, at| {
        if (char != mark) continue;
        rest.* = whole[at + 1 ..];
        return whole[0..at];
    }
    rest.* = whole[whole.len..];
    return whole;
}

/// Where the file's text is written: a buffer, and how much of it is
/// taken. What does not fit is left out.
const Out = struct {
    into: []u8,
    at: usize = 0,

    fn put(out: *Out, source: []const u8) void {
        for (source) |char| {
            if (out.at >= out.into.len) return;
            out.into[out.at] = char;
            out.at += 1;
        }
    }

    fn value(out: *Out, figure: u32, digits: usize, radix: u32) void {
        var reversed: [10]u8 = undefined;
        var count: usize = 0;
        var left = figure;
        while (left != 0 or count < digits) {
            reversed[count] = "0123456789ABCDEF"[left % radix];
            count += 1;
            left /= radix;
        }
        while (count > 0) {
            count -= 1;
            out.put(reversed[count .. count + 1]);
        }
    }
};

// --- read ---------------------------------------------------------------------

/// "DEL:A0C4:00012345" into a line's monitor.
fn readMonitor(value: []const u8, settings: *rtg.RtgSettings) bool {
    var rest = value;
    const maker = part(&rest, ':');
    const product = part(&rest, ':');
    if (maker.len == 0 or maker.len > 3) return false;
    settings.maker = @splat(0);
    for (maker, 0..) |char, at| settings.maker[at] = upper(char);
    settings.product = number(product, 16) orelse return false;
    settings.serial = number(rest, 16) orelse return false;
    settings.flags |= rtg.RTGSET_MONITOR;
    return true;
}

/// "2560x1440" or "2560x1440@60" into a line's mode.
fn readMode(value: []const u8, settings: *rtg.RtgSettings) bool {
    var rest = value;
    const size = part(&rest, '@');
    var across = size;
    var width = part(&across, 'x');
    if (across.len == 0) {
        across = size;
        width = part(&across, 'X');
    }
    const wide = number(width, 10) orelse return false;
    const high = number(across, 10) orelse return false;
    if (wide == 0 or high == 0) return false;
    var refresh: u32 = 0;
    // An '@' is followed by the refresh.
    if (size.len != value.len) {
        const hertz = number(rest, 10) orelse return false;
        if (hertz == 0 or hertz > 1000) return false;
        refresh = hertz * 1000;
    }
    settings.mode_width = wide;
    settings.mode_height = high;
    settings.mode_refresh_mhz = refresh;
    settings.flags |= rtg.RTGSET_MODE;
    return true;
}

/// "148500000,1920,88,44,148,1080,4,5,36,+H,+V" into a line's timings.
fn readTimings(value: []const u8, settings: *rtg.RtgSettings) bool {
    var rest = value;
    var figures: [9]u32 = undefined;
    for (&figures) |*figure| figure.* = number(part(&rest, ','), 10) orelse return false;
    var timings: rtg.RtgTimings = .{
        .pixel_clock_hz = figures[0],
        .h_active = figures[1],
        .h_front = figures[2],
        .h_sync = figures[3],
        .h_back = figures[4],
        .v_active = figures[5],
        .v_front = figures[6],
        .v_sync = figures[7],
        .v_back = figures[8],
    };
    if (!timingsMakeSense(&timings)) return false;
    while (rest.len != 0) {
        const way = part(&rest, ',');
        if (same(way, "+H")) {
            timings.flags |= monitor_flags.RTGTM_HSYNC_HIGH;
        } else if (same(way, "+V")) {
            timings.flags |= monitor_flags.RTGTM_VSYNC_HIGH;
        } else if (!same(way, "-H") and !same(way, "-V")) return false;
    }
    settings.timings = timings;
    settings.flags |= rtg.RTGSET_TIMINGS;
    return true;
}

/// Whether timings are a picture a clock can time: a clock, a size, and
/// a sync pulse each way.
pub fn timingsMakeSense(timings: *const rtg.RtgTimings) bool {
    return timings.pixel_clock_hz != 0 and timings.h_active != 0 and timings.v_active != 0 and
        timings.h_sync != 0 and timings.v_sync != 0;
}

/// One pair of an output's line taken; false for a key that is not an
/// output's and a value that cannot be read.
fn readOutputPair(key: []const u8, value: []const u8, settings: *rtg.RtgSettings) bool {
    if (same(key, "MONITOR")) return readMonitor(value, settings);
    if (same(key, "MODE")) return readMode(value, settings);
    if (same(key, "TIMINGS")) return readTimings(value, settings);
    if (same(key, "FIRST")) {
        if (same(value, "YES")) settings.flags |= rtg.RTGSET_FIRST else if (!same(value, "NO")) return false;
        return true;
    }
    if (same(key, "MIRROR")) {
        const axes: u32 = if (same(value, "X"))
            rtg.RTGSET_MIRROR_X
        else if (same(value, "Y"))
            rtg.RTGSET_MIRROR_Y
        else if (same(value, "XY"))
            rtg.RTGSET_MIRROR_X | rtg.RTGSET_MIRROR_Y
        else if (same(value, "NONE"))
            0
        else
            return false;
        settings.flags |= rtg.RTGSET_MIRROR | axes;
        return true;
    }
    if (same(key, "BRIGHTNESS")) {
        const percent = number(value, 10) orelse return false;
        if (percent > 100) return false;
        settings.brightness = percent;
        settings.flags |= rtg.RTGSET_BRIGHTNESS;
        return true;
    }
    if (same(key, "RANGE")) {
        if (same(value, "LIMITED")) {
            settings.flags |= rtg.RTGSET_RANGE | rtg.RTGSET_LIMITED_RANGE;
        } else if (same(value, "FULL")) {
            settings.flags |= rtg.RTGSET_RANGE;
        } else return false;
        return true;
    }
    return false;
}

/// One pair of a device's line taken; false for a key that is not a
/// device's and a value that cannot be read.
fn readDevicePair(key: []const u8, value: []const u8, line: *DeviceLine) bool {
    if (same(key, "DRIVER")) {
        if (same(value, "OFF")) line.flags |= DEVSET_DRIVER_OFF else if (!same(value, "ON")) return false;
        return true;
    }
    if (same(key, "BUFFERS")) {
        const count = number(value, 10) orelse return false;
        if (count == 0) return false;
        line.buffers = count;
        line.flags |= DEVSET_BUFFERS;
        return true;
    }
    if (same(key, "COMPOSE")) {
        if (same(value, "YES")) {
            line.flags |= DEVSET_COMPOSE | DEVSET_COMPOSE_ON;
        } else if (same(value, "NO")) {
            line.flags |= DEVSET_COMPOSE;
        } else return false;
        return true;
    }
    return false;
}

/// One line of the file taken onto the lists.
///
/// RESULT:
/// False for a line that cannot be read - one that names neither a
/// device nor an output, a key its kind has not got, a value out of its
/// range - and without memory. Nothing of such a line is kept.
fn readLine(rb: *RtgBase, line_text: []const u8) bool {
    const ub = rb.utility_base;
    var scan: SettingScan = .{ .text = line_text.ptr, .length = line_text.len };
    if (ub.NextSetting(&scan) != 1) return false;
    const name = scan.valueText();
    if (name.len == 0 or name.len >= rtg.drivers.RTG_NAME_MAX) return false;
    if (same(scan.keyText(), "OUTPUT")) {
        var settings: rtg.RtgSettings = .{};
        while (true) {
            switch (ub.NextSetting(&scan)) {
                0 => break,
                1 => if (!readOutputPair(scan.keyText(), scan.valueText(), &settings)) return false,
                else => return false,
            }
        }
        return put(rb, name, &settings);
    }
    if (same(scan.keyText(), "DEVICE")) {
        var said: DeviceLine = .{};
        while (true) {
            switch (ub.NextSetting(&scan)) {
                0 => break,
                1 => if (!readDevicePair(scan.keyText(), scan.valueText(), &said)) return false,
                else => return false,
            }
        }
        if (said.flags == 0) return true;
        const line = needDevice(rb, name) orelse return false;
        line.flags = said.flags;
        line.buffers = said.buffers;
        return true;
    }
    return false;
}

/// Whether a line holds anything but blanks and a comment.
fn hasWords(line_text: []const u8) bool {
    for (line_text) |char| {
        if (char == ' ' or char == '\t' or char == '\r') continue;
        return char != '#' and char != ';';
    }
    return false;
}

/// The file's text read in place of the lines held.
///
/// INPUTS:
/// - `rb` - the library; the settings' lock is held.
/// - `file` - the text.
///
/// RESULT:
/// How many lines could not be read; each is said on the log with its
/// number and passed over.
pub fn read(rb: *RtgBase, file: []const u8) u32 {
    clear(rb);
    var unread: u32 = 0;
    var line_number: u32 = 0;
    var at: usize = 0;
    while (at < file.len) {
        var end = at;
        while (end < file.len and file[end] != '\n') end += 1;
        const line_text = file[at..end];
        at = end + 1;
        line_number += 1;
        if (!hasWords(line_text)) continue;
        if (readLine(rb, line_text)) continue;
        unread += 1;
        exec.kprintf(rb.sys_base, "rtg.library: display.prefs, line %d cannot be read\n", .{line_number});
    }
    return unread;
}

// --- written ------------------------------------------------------------------

fn writeOutput(out: *Out, line: *const Line) void {
    const settings = &line.settings;
    out.put("OUTPUT=");
    out.put(text(&line.name));
    if (settings.flags & rtg.RTGSET_MONITOR != 0) {
        out.put(" MONITOR=");
        out.put(text(&settings.maker));
        out.put(":");
        out.value(settings.product, 4, 16);
        out.put(":");
        out.value(settings.serial, 8, 16);
    }
    if (settings.flags & rtg.RTGSET_MODE != 0) {
        out.put(" MODE=");
        out.value(settings.mode_width, 1, 10);
        out.put("x");
        out.value(settings.mode_height, 1, 10);
        if (settings.mode_refresh_mhz != 0) {
            out.put("@");
            out.value((settings.mode_refresh_mhz + 500) / 1000, 1, 10);
        }
    }
    if (settings.flags & rtg.RTGSET_FIRST != 0) out.put(" FIRST=YES");
    if (settings.flags & rtg.RTGSET_MIRROR != 0) {
        const both = rtg.RTGSET_MIRROR_X | rtg.RTGSET_MIRROR_Y;
        out.put(" MIRROR=");
        out.put(switch (settings.flags & both) {
            rtg.RTGSET_MIRROR_X => "X",
            rtg.RTGSET_MIRROR_Y => "Y",
            both => "XY",
            else => "NONE",
        });
    }
    if (settings.flags & rtg.RTGSET_BRIGHTNESS != 0) {
        out.put(" BRIGHTNESS=");
        out.value(@min(settings.brightness, 100), 1, 10);
    }
    if (settings.flags & rtg.RTGSET_RANGE != 0) {
        out.put(if (settings.flags & rtg.RTGSET_LIMITED_RANGE != 0) " RANGE=LIMITED" else " RANGE=FULL");
    }
    if (settings.flags & rtg.RTGSET_TIMINGS != 0) {
        const timings = &settings.timings;
        out.put(" TIMINGS=");
        const figures = [_]u32{
            timings.pixel_clock_hz, timings.h_active, timings.h_front, timings.h_sync, timings.h_back,
            timings.v_active,       timings.v_front,  timings.v_sync,  timings.v_back,
        };
        for (figures) |figure| {
            out.value(figure, 1, 10);
            out.put(",");
        }
        out.put(if (timings.flags & monitor_flags.RTGTM_HSYNC_HIGH != 0) "+H," else "-H,");
        out.put(if (timings.flags & monitor_flags.RTGTM_VSYNC_HIGH != 0) "+V" else "-V");
    }
    out.put("\n");
}

fn writeDevice(out: *Out, line: *const DeviceLine) void {
    out.put("DEVICE=");
    out.put(text(&line.name));
    if (line.flags & DEVSET_DRIVER_OFF != 0) out.put(" DRIVER=OFF");
    if (line.flags & DEVSET_BUFFERS != 0) {
        out.put(" BUFFERS=");
        out.value(line.buffers, 1, 10);
    }
    if (line.flags & DEVSET_COMPOSE != 0) {
        out.put(if (line.flags & DEVSET_COMPOSE_ON != 0) " COMPOSE=YES" else " COMPOSE=NO");
    }
    out.put("\n");
}

/// How many bytes the file takes at the most: room for `write`.
///
/// INPUTS:
/// - `rb` - the library; the settings' lock is held.
pub fn bytes(rb: *RtgBase) usize {
    var lines: usize = 0;
    var node = rb.device_lines.first();
    while (node) |n| : (node = n.next()) lines += 1;
    node = rb.output_lines.first();
    while (node) |n| : (node = n.next()) lines += 1;
    return header.len + lines * line_most;
}

/// The file's text: the explanation, the devices' lines, the outputs'.
///
/// INPUTS:
/// - `rb` - the library; the settings' lock is held.
/// - `into` - takes the text; `bytes` says how much room it needs.
///
/// RESULT:
/// How many bytes were written.
pub fn write(rb: *RtgBase, into: []u8) usize {
    var out: Out = .{ .into = into };
    out.put(header);
    var node = rb.device_lines.first();
    while (node) |n| : (node = n.next()) writeDevice(&out, deviceLineOfNode(n));
    node = rb.output_lines.first();
    while (node) |n| : (node = n.next()) writeOutput(&out, lineOfNode(n));
    return out.at;
}

// --- applied ------------------------------------------------------------------

/// The mode a board's line names, where the board offers it: of that
/// size, and at that refresh to the nearest Hertz where the line says
/// one - else at the board's default of that size, else its fastest.
///
/// INPUTS:
/// - `board` - the board; its lock is held, or it is on no list yet.
/// - `settings` - the board's line.
pub fn modeOf(board: *rtg.RtgBoard, settings: *const rtg.RtgSettings) ?*modes.Record {
    if (settings.flags & rtg.RTGSET_MODE == 0) return null;
    var first: ?*modes.Record = null;
    var node = boards.privateOf(board).modes.first();
    while (node) |n| : (node = n.next()) {
        const record = modes.recordOf(n);
        const mode = &record.mode;
        if (mode.width != settings.mode_width or mode.height != settings.mode_height) continue;
        if (settings.mode_refresh_mhz != 0) {
            if ((mode.refresh_mhz + 500) / 1000 != (settings.mode_refresh_mhz + 500) / 1000) continue;
            return record;
        }
        if (record.marked_default) return record;
        if (first == null) first = record;
    }
    return first;
}

/// The default of a board's modes chosen: the mode its line names where
/// the board offers it, else the one its driver or its monitor made the
/// default.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its lock is held, or it is on no list yet.
pub fn chooseDefault(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const own = modes.ownDefault(board) orelse return;
    var settings: rtg.RtgSettings = .{};
    _ = lineOf(rb, board, &settings);
    modes.setDefault(board, modeOf(board, &settings) orelse own);
}

/// What a line says of the colour range, as a board's info carries it.
fn rangeOf(settings: *const rtg.RtgSettings) u8 {
    if (settings.flags & rtg.RTGSET_RANGE == 0) return rtg.RTGRANGE_AUTO;
    return if (settings.flags & rtg.RTGSET_LIMITED_RANGE != 0) rtg.RTGRANGE_LIMITED else rtg.RTGRANGE_FULL;
}

/// A board's line applied to it: its modes made again with the line's
/// default and timings, then what `applyRest` does. A board with no line
/// gets back the default and the place it has by itself, and the range
/// its monitor asks for; how it is mirrored and how bright it is are
/// left.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, on the library's list.
///
/// CONTEXT:
/// In a task; a driver's `show` and its bus may wait. It takes the
/// board's lock, and the board list's after it has given that back. The
/// settings' lock is not held.
pub fn applyTo(rb: *RtgBase, board: *rtg.RtgBoard) void {
    boards.obtain(rb, board);
    if (!boards.dark(board)) monitors.renew(rb, board);
    boards.release(rb, board);
    applyRest(rb, board);
}

/// What a board's line says beside its modes, applied: the colour range,
/// the mirror, the brightness and the board's place on the list. For a
/// board whose modes were just made with its line.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, on the library's list.
///
/// CONTEXT:
/// As `applyTo`.
pub fn applyRest(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const private = boards.privateOf(board);
    var settings: rtg.RtgSettings = .{};
    boards.obtain(rb, board);
    if (boards.dark(board)) {
        boards.release(rb, board);
        return;
    }
    _ = lineOf(rb, board, &settings);
    const range = rangeOf(&settings);
    if (board.info.color_range != range) {
        board.info.color_range = range;
        // The link again, with its colours in the new range.
        if (board.info.caps & rtg.boards.RTGBC_COLOR_RANGE != 0 and private.mode != null) shows.again(rb, board);
    }
    boards.release(rb, board);

    if (settings.flags & rtg.RTGSET_MIRROR != 0) {
        _ = rb.iface().MirrorBoard(board, settings.flags & rtg.RTGSET_MIRROR_X != 0, settings.flags & rtg.RTGSET_MIRROR_Y != 0);
    }
    if (settings.flags & rtg.RTGSET_BRIGHTNESS != 0) _ = rb.iface().SetBoardBrightness(board, settings.brightness);
    boards.setFirst(rb, board, settings.flags & rtg.RTGSET_FIRST != 0);
}

/// Every board's line applied to it.
///
/// INPUTS:
/// - `rb` - the library.
///
/// CONTEXT:
/// As `applyTo`.
pub fn applyAll(rb: *RtgBase) void {
    var board = rb.iface().NextBoard(null);
    // The walk's next board is asked for before this one is applied: a
    // board made the first moves to the front of the list.
    while (board) |one| {
        board = rb.iface().NextBoard(one);
        applyTo(rb, one);
    }
}

/// A device's line put in front of its tags, for the driver it is
/// offered to next; a device with no line, or one that says nothing a
/// tag carries, gets its own tags back.
///
/// INPUTS:
/// - `rb` - the library; the device list's lock is held.
/// - `device` - the device; no driver has it.
pub fn dress(rb: *RtgBase, device: *rtg.RtgDevice) void {
    const private = devices.privateOf(device);
    if (!private.dressed) private.own_tags = device.tags;
    private.dressed = false;
    device.tags = private.own_tags;
    obtain(rb);
    defer release(rb);
    const line = findDevice(rb, text(&private.name_buf)) orelse return;
    var count: usize = 0;
    if (line.flags & DEVSET_BUFFERS != 0) {
        private.dress[count] = .{ .tag = tags.RTGA_Buffers, .data = line.buffers };
        count += 1;
    }
    if (line.flags & DEVSET_COMPOSE != 0) {
        private.dress[count] = .{ .tag = tags.RTGA_Compose, .data = @intFromBool(line.flags & DEVSET_COMPOSE_ON != 0) };
        count += 1;
    }
    if (count == 0) return;
    private.dress[count] = if (private.own_tags) |own|
        .{ .tag = sdk.utility.TAG_MORE, .data = @intFromPtr(own) }
    else
        .{ .tag = sdk.utility.TAG_DONE, .data = 0 };
    private.dressed = true;
    device.tags = &private.dress;
}

/// Every device no driver has dressed in its line.
///
/// INPUTS:
/// - `rb` - the library.
///
/// CONTEXT:
/// In a task: it takes the device list's lock, and the settings' inside
/// it.
pub fn dressAll(rb: *RtgBase) void {
    const sys = rb.sys_base;
    sys.ObtainSemaphore(&rb.device_lock);
    defer sys.ReleaseSemaphore(&rb.device_lock);
    var node = rb.devices.first();
    while (node) |n| : (node = n.next()) {
        const device = devices.deviceOf(n);
        if (device.driver == null) dress(rb, device);
    }
}

/// dos.library, opened the first time a settings file is read or
/// written, and kept. Null where it cannot be opened: before the disk is
/// there.
///
/// INPUTS:
/// - `rb` - the library.
pub fn dosBase(rb: *RtgBase) ?*sdk.interface.dos.DosBase {
    obtain(rb);
    defer release(rb);
    if (rb.dos_base == null) rb.dos_base = @ptrCast(rb.sys_base.OpenLibrary(sdk.interface.dos.NAME, 0));
    return rb.dos_base;
}

/// The file a call is given, or the running system's.
///
/// INPUTS:
/// - `path` - the caller's, or null.
pub fn pathOf(path: ?[*:0]const u8) [*:0]const u8 {
    return path orelse rtg.RTG_SETTINGS_ENV;
}
