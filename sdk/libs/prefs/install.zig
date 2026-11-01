// SPDX-License-Identifier: MIT
//! install.prefs: what a system was installed onto, left behind by the
//! install so that the machine can be brought up to date and its kernel
//! replaced without being told all of it again - one line,
//! `DEVICE=nvme.device UNIT=0 SYSTEM=DH0 WORK=DH1 BOOT=BOOT BOOTB=BOOTB
//! BOARD=visionfive2 SOURCE=SYS: INSTALLED="01.11.2026 21:30:04"`:
//!
//! - DEVICE: the block device the system is on, as exec has it.
//! - UNIT: its unit.
//! - SYSTEM, WORK: the drives of the two partitions in the container.
//! - BOOT: the name in the GPT of the partition the machine's firmware
//!   reads. It is not what that partition's drive is called at a later
//!   start - a GPT's partitions are mounted under the unit's own name
//!   (`NV0`, then `NV0P2`) - so this is how it is found again, through
//!   rdb.library, and not a name to open.
//! - BOOTB: the second one, where the firmware starts from either of a
//!   pair (`SYSTAG_BootSlots`); left out where there is one.
//! - BOARD: the board the files were built for, as the package's list
//!   names it; left out where the source named none.
//! - SOURCE: where the files came from - a path, or an address - which is
//!   where an update looks unless it is told another.
//! - INSTALLED: when, in the machine's own time.
//!
//! One left out is empty, or 0 for UNIT. `parse` reads the line into
//! `Settings`, `write` writes them as the line, and `header` is the
//! explanation the install puts before it.
//!
//! The file is ENVARC:'s alone: it says what was done to this machine,
//! not what the machine is to do, so nothing hands it to the system at
//! boot and ENV: has no copy.

const dos = @import("../dos/dos.zig");
const manifest = @import("../install/manifest.zig");
const prefs = @import("prefs.zig");
const style = @import("style.zig");
const UtilityBase = @import("../../interface/utility.zig").UtilityBase;

/// The longest an exec device's name may be here, its NUL not counted.
pub const device_len = 63;

/// The longest a drive's name may be: what dos holds (`MAX_DEVICE_NAME`).
pub const drive_len = dos.MAX_DEVICE_NAME;

/// The longest SOURCE may be, its NUL not counted: a path or an address.
pub const source_len = 255;

/// The longest INSTALLED may be, its NUL not counted.
pub const when_len = 31;

/// The line's settings, each empty where the line leaves it out.
pub const Settings = struct {
    /// The block device, NUL-terminated.
    device: [device_len:0]u8 = @splat(0),
    /// Its unit.
    unit: u32 = 0,
    /// The system partition's drive.
    system: [drive_len:0]u8 = @splat(0),
    /// The work partition's drive; empty where there is none.
    work: [drive_len:0]u8 = @splat(0),
    /// The name in the GPT of the partition the firmware reads, which is
    /// how it is found again - not what its drive is called.
    boot: [drive_len:0]u8 = @splat(0),
    /// The second one; empty where the firmware reads one.
    boot_b: [drive_len:0]u8 = @splat(0),
    /// The board the files were built for; empty where none was named.
    board: [manifest.max_board:0]u8 = @splat(0),
    /// Where the files came from.
    source: [source_len:0]u8 = @splat(0),
    /// When, as the machine said it.
    installed: [when_len:0]u8 = @splat(0),
};

pub const ENVARC_FILE = "ENVARC:Sys/install.prefs";

/// The bytes `write` writes at most, every field at its longest.
pub const max_line: usize = 512;

/// The line read into `settings`: null when it is taken, else what is
/// wrong with it.
pub fn parse(ub: *UtilityBase, text: []const u8, settings: *Settings) ?[*:0]const u8 {
    var pairs = prefs.Pairs.init(ub, text);
    while (pairs.next() catch return prefs.Pairs.quote_not_closed) |pair| {
        const key = pair.key;
        const value = pair.value;
        if (style.same(key, "DEVICE")) {
            if (!set(&settings.device, value)) return "DEVICE is longer than 63 characters";
        } else if (style.same(key, "UNIT")) {
            settings.unit = style.decimal(value) orelse return "UNIT is a number";
        } else if (style.same(key, "SYSTEM")) {
            if (!set(&settings.system, value)) return "SYSTEM is longer than a drive's name may be";
        } else if (style.same(key, "WORK")) {
            if (!set(&settings.work, value)) return "WORK is longer than a drive's name may be";
        } else if (style.same(key, "BOOT")) {
            if (!set(&settings.boot, value)) return "BOOT is longer than a drive's name may be";
        } else if (style.same(key, "BOOTB")) {
            if (!set(&settings.boot_b, value)) return "BOOTB is longer than a drive's name may be";
        } else if (style.same(key, "BOARD")) {
            if (!manifest.boardOk(value)) return "BOARD is letters, digits, `_` and `-`, up to 31 of them";
            _ = set(&settings.board, value);
        } else if (style.same(key, "SOURCE")) {
            if (!set(&settings.source, value)) return "SOURCE is longer than 255 characters";
        } else if (style.same(key, "INSTALLED")) {
            if (!set(&settings.installed, value)) return "INSTALLED is longer than 31 characters";
        } else {
            return "not in the form DEVICE=<device> UNIT=<n> SYSTEM=<drive> WORK=<drive> BOOT=<drive> BOOTB=<drive> BOARD=<board> SOURCE=<where> INSTALLED=<when>";
        }
    }
    return null;
}

/// `value` into a field, NUL-terminated; false when it does not fit, and
/// the field is left as it was.
fn set(field: anytype, value: []const u8) bool {
    if (value.len > field.len) return false;
    field.* = @splat(0);
    @memcpy(field[0..value.len], value);
    return true;
}

/// `settings` written as the line into `into` (`max_line` bytes will do):
/// how many bytes, no newline. A field that is empty is left out, so a
/// line says only what is known.
pub fn write(settings: *const Settings, into: []u8) usize {
    var at: usize = 0;
    put(into, &at, "DEVICE=");
    quoted(into, &at, textOf(&settings.device));
    put(into, &at, " UNIT=");
    at += prefs.number(settings.unit, into[at..]);
    setting(into, &at, " SYSTEM=", textOf(&settings.system));
    setting(into, &at, " WORK=", textOf(&settings.work));
    setting(into, &at, " BOOT=", textOf(&settings.boot));
    setting(into, &at, " BOOTB=", textOf(&settings.boot_b));
    setting(into, &at, " BOARD=", textOf(&settings.board));
    setting(into, &at, " SOURCE=", textOf(&settings.source));
    setting(into, &at, " INSTALLED=", textOf(&settings.installed));
    return at;
}

/// A field's text, up to its NUL.
pub fn textOf(field: anytype) []const u8 {
    var length: usize = 0;
    while (length < field.len and field[length] != 0) length += 1;
    return field[0..length];
}

/// `key` and `value`, or nothing at all when the value is empty.
fn setting(into: []u8, at: *usize, key: []const u8, value: []const u8) void {
    if (value.len == 0) return;
    put(into, at, key);
    quoted(into, at, value);
}

/// A value, in double quotes where it has a blank in it.
fn quoted(into: []u8, at: *usize, value: []const u8) void {
    var spaced = false;
    for (value) |char| {
        if (char == ' ') spaced = true;
    }
    if (spaced) put(into, at, "\"");
    put(into, at, value);
    if (spaced) put(into, at, "\"");
}

fn put(into: []u8, at: *usize, from: []const u8) void {
    @memcpy(into[at.*..][0..from.len], from);
    at.* += from.len;
}

/// The file's explanation, every line a comment.
pub const header =
    \\# ENVARC:Sys/install.prefs - what C:Install put on this machine, and
    \\# where it came from. One line:
    \\#
    \\# DEVICE     the block device the system is on, as exec has it.
    \\# UNIT       its unit.
    \\# SYSTEM     the drive of the system partition.
    \\# WORK       the drive of the other partition in the container.
    \\# BOOT       the partition the firmware reads, by its name in the
    \\#            GPT: a GPT's partitions are mounted under the unit's
    \\#            own name, so this is how it is found, not opened.
    \\# BOOTB      the second one, where the firmware starts from either
    \\#            of a pair; left out where there is one.
    \\# BOARD      the board the files were built for.
    \\# SOURCE     where they came from - a path or an address - which is
    \\#            where C:Update looks unless it is told another.
    \\# INSTALLED  when, in this machine's time.
    \\#
    \\# C:Install writes this file. Changing SOURCE by hand is the way to
    \\# point the machine at another package; the rest says what was done
    \\# and is not read as an instruction.
    \\
;
