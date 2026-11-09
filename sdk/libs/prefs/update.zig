// SPDX-License-Identifier: MIT
//! update.prefs: where this machine looks for a newer system, and what
//! it does about one - one line,
//! `SOURCE="http://poweros.local/qemu_virt/" ATSTART=YES APPLY=NO
//! BOOT=NO`:
//!
//! - SOURCE: the release package to look at - a path or an address -
//!   which `C:Update` reads when it is told no other. Empty, the one the
//!   install wrote down is used.
//! - ATSTART: YES to look once at every start, from
//!   `S:Network-Startup`, after the network is up.
//! - APPLY: YES to write what was found without asking, NO to say what
//!   there is and let it be asked for. A build changes daily, so NO is
//!   what a machine does unless it was told otherwise.
//! - BOOT: YES for the files the firmware reads to be written too, where
//!   what was found is applied. On a machine whose firmware starts from
//!   either of a pair of partitions a kernel that does not come up costs
//!   one start; where it reads one, the kernel being replaced is kept
//!   beside the new one.
//!
//! The file is what the machine is to do, so `C:SetPrefs` puts it in
//! `ENV:` as well and `C:Update AUTO` reads it from there. Without the
//! file nothing looks anywhere: a machine says nothing to a server it
//! was never told about.

const prefs = @import("prefs.zig");
const style = @import("style.zig");
const UtilityBase = @import("../../interface/utility.zig").UtilityBase;

/// Where the file is kept, and where a running system reads it.
pub const ENVARC_FILE = "ENVARC:Sys/update.prefs";
pub const ENV_FILE = "ENV:Sys/update.prefs";

/// The longest SOURCE may be, its NUL not counted: a path or an address.
pub const source_len = 255;

/// The bytes `write` writes at most.
pub const max_line: usize = 384;

/// ATSTART's, APPLY's and BOOT's words, for false and true.
pub const yes_no = prefs.yes_no;

/// What the line says.
pub const Settings = struct {
    /// The package to look at, NUL-terminated; empty for the one the
    /// install wrote down.
    source: [source_len:0]u8 = @splat(0),
    /// Whether to look once at every start.
    at_start: bool = true,
    /// Whether what is found is written without being asked for.
    apply: bool = false,
    /// Whether the files the firmware reads are written with it.
    boot: bool = false,
};

/// The line read into `settings`: null when it is taken, else what is
/// wrong with it.
pub fn parse(ub: *UtilityBase, text: []const u8, settings: *Settings) ?[*:0]const u8 {
    var pairs = prefs.Pairs.init(ub, text);
    while (pairs.next() catch return prefs.Pairs.quote_not_closed) |pair| {
        const key = pair.key;
        const value = pair.value;
        if (style.same(key, "SOURCE")) {
            if (value.len > settings.source.len) return "SOURCE is longer than 255 characters";
            settings.source = @splat(0);
            @memcpy(settings.source[0..value.len], value);
        } else if (style.same(key, "ATSTART")) {
            settings.at_start = prefs.yesOrNo(value) orelse return "ATSTART is YES or NO";
        } else if (style.same(key, "APPLY")) {
            settings.apply = prefs.yesOrNo(value) orelse return "APPLY is YES or NO";
        } else if (style.same(key, "BOOT")) {
            settings.boot = prefs.yesOrNo(value) orelse return "BOOT is YES or NO";
        } else return "not in the form SOURCE=<where> ATSTART=YES APPLY=NO BOOT=NO";
    }
    return null;
}

/// `settings` written as the line into `into` (`max_line` bytes will
/// do): how many bytes, no newline.
pub fn write(settings: *const Settings, into: []u8) usize {
    var at: usize = 0;
    const source = sourceText(settings);
    if (source.len != 0) {
        put(into, &at, "SOURCE=");
        quoted(into, &at, source);
        put(into, &at, " ");
    }
    put(into, &at, "ATSTART=");
    put(into, &at, yes_no[@intFromBool(settings.at_start)]);
    put(into, &at, " APPLY=");
    put(into, &at, yes_no[@intFromBool(settings.apply)]);
    put(into, &at, " BOOT=");
    put(into, &at, yes_no[@intFromBool(settings.boot)]);
    return at;
}

/// SOURCE's text, up to its NUL.
pub fn sourceText(settings: *const Settings) []const u8 {
    var length: usize = 0;
    while (length < settings.source.len and settings.source[length] != 0) length += 1;
    return settings.source[0..length];
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
    \\# ENVARC:Sys/update.prefs - where this machine looks for a newer
    \\# system, and what it does about one. One line:
    \\#
    \\# SOURCE   the release package to look at: a path - a stick, a
    \\#          share, a second disk - or an http(s) address. Empty,
    \\#          C:Update takes the one the install wrote down.
    \\# ATSTART  YES to look once at every start, after the network is
    \\#          up (S:Network-Startup).
    \\# APPLY    YES to write what was found without asking. NO says
    \\#          what there is, on the desktop where there is one, and
    \\#          waits to be asked.
    \\# BOOT     YES for the files the firmware reads to be written with
    \\#          it, so that the kernel and the system go together.
    \\#
    \\# Without this file nothing looks anywhere. `C:Update AUTO` is what
    \\# reads it, and SYS:Programs/Prefs has a page for it.
    \\
;
