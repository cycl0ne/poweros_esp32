// SPDX-License-Identifier: MIT
//! fkey.keys: the keys FKey puts functions on, as a file - a line for
//! each key, in the order they are tried:
//!
//!     KEY="ctrl alt f1" COMMAND=CYCLEWINDOWS
//!     KEY="f12" COMMAND=INSERT ARGS="Kind regards,\n"
//!     KEY="ctrl alt n" COMMAND=PROGRAM ARGS="SYS:Programs/Notepad"
//!
//! - KEY: what the key is, as a filter's description - the qualifiers
//!   held and the key itself ("ctrl alt f1", "shift f5", "help").
//! - COMMAND: what it does, one of `names`.
//! - ARGS: the text INSERT types or the command PROGRAM runs; the other
//!   commands take none.
//!
//! `Keys` reads them a line at a time, `keyLine` writes one, and `header`
//! is the explanation FKey puts before them. The file lives in ENV:Sys
//! while the machine runs and in ENVARC:Sys across a boot; FKey writes
//! both when it is asked to save, and reads ENV: first.

const sdk = @import("sdk");
const prefs = sdk.prefs;
const style = prefs.style;
const UtilityBase = sdk.interface.utility.UtilityBase;

pub const ENV_FILE = "ENV:Sys/fkey.keys";
pub const ENVARC_FILE = "ENVARC:Sys/fkey.keys";

/// What a key does.
pub const Command = enum(u8) {
    cycle_windows,
    cycle_screens,
    enlarge,
    shrink,
    toggle,
    insert,
    program,
};

/// COMMAND's words, in the enum's order.
pub const names = [_][]const u8{
    "CYCLEWINDOWS",
    "CYCLESCREENS",
    "ENLARGE",
    "SHRINK",
    "TOGGLE",
    "INSERT",
    "PROGRAM",
};

/// What the window's chooser shows for each, in the same order.
pub const labels = [_:null]?[*:0]const u8{
    "Cycle Windows",
    "Cycle Screens",
    "Enlarge Window",
    "Shrink Window",
    "Toggle Window",
    "Insert Text",
    "Run Program",
};

/// Whether ARGS means anything to a command.
pub fn takesArgs(command: Command) bool {
    return command == .insert or command == .program;
}

/// One key as the file has it. The text is the file's, which the caller
/// keeps while it uses it.
pub const Key = struct {
    description: []const u8,
    command: Command,
    args: []const u8 = &.{},
};

/// The keys of a file, a line at a time.
pub const Keys = struct {
    ub: *UtilityBase,
    lines: prefs.Lines,
    /// The number of the last line passed over as not a key, and what is
    /// wrong with it; 0 and null while there is none.
    bad_line: u32 = 0,
    problem: ?[*:0]const u8 = null,

    pub fn init(ub: *UtilityBase, text: []const u8) Keys {
        return .{ .ub = ub, .lines = .{ .text = text } };
    }

    /// The next key, null at the end of the file.
    pub fn next(keys: *Keys) ?Key {
        while (keys.lines.next()) |line| {
            if (!style.hasWords(line.text)) continue;
            var problem: [*:0]const u8 = undefined;
            if (parseKey(keys.ub, line.text, &problem)) |key| return key;
            keys.bad_line = line.number;
            keys.problem = problem;
        }
        return null;
    }
};

/// One line as a key; null, with `problem` saying why, when it is not
/// one.
fn parseKey(ub: *UtilityBase, text: []const u8, problem: *[*:0]const u8) ?Key {
    const form = "not in the form KEY=\"ctrl alt f1\" COMMAND=CYCLEWINDOWS";
    var description: []const u8 = &.{};
    var command: ?Command = null;
    var args: []const u8 = &.{};
    var pairs = prefs.Pairs.init(ub, text);
    while (pairs.next() catch {
        problem.* = prefs.Pairs.quote_not_closed;
        return null;
    }) |pair| {
        if (style.same(pair.key, "KEY")) {
            description = pair.value;
        } else if (style.same(pair.key, "COMMAND")) {
            command = named(pair.value) orelse {
                problem.* = "COMMAND is CYCLEWINDOWS, CYCLESCREENS, ENLARGE, SHRINK, TOGGLE, INSERT or PROGRAM";
                return null;
            };
        } else if (style.same(pair.key, "ARGS")) {
            args = pair.value;
        } else {
            problem.* = form;
            return null;
        }
    }
    if (description.len == 0 or command == null) {
        problem.* = form;
        return null;
    }
    return .{ .description = description, .command = command.?, .args = args };
}

/// The command of that word, or null.
pub fn named(word: []const u8) ?Command {
    for (names, 0..) |name, i| {
        if (style.same(word, name)) return @enumFromInt(i);
    }
    return null;
}

/// `key` written into `into` as its line, with the newline; how many
/// bytes, or null when it does not fit or a value holds a quote, which
/// the form has no way of writing.
pub fn keyLine(key: Key, into: []u8) ?usize {
    for (key.description) |c| if (c == '"') return null;
    for (key.args) |c| if (c == '"') return null;
    const name = names[@intFromEnum(key.command)];
    const with_args = takesArgs(key.command) and key.args.len > 0;
    const length = "KEY=\"".len + key.description.len + "\" COMMAND=".len + name.len +
        (if (with_args) " ARGS=\"".len + key.args.len + 1 else 0) + 1;
    if (length > into.len) return null;
    var at: usize = 0;
    at += put(into[at..], "KEY=\"");
    at += put(into[at..], key.description);
    at += put(into[at..], "\" COMMAND=");
    at += put(into[at..], name);
    if (with_args) {
        at += put(into[at..], " ARGS=\"");
        at += put(into[at..], key.args);
        at += put(into[at..], "\"");
    }
    at += put(into[at..], "\n");
    return at;
}

fn put(into: []u8, text: []const u8) usize {
    @memcpy(into[0..text.len], text);
    return text.len;
}

/// fkey.keys' explanation, every line a comment.
pub const header =
    \\# ENVARC:Sys/fkey.keys - the keys SYS:Commodities/FKey puts
    \\# functions on, which it writes when it is asked to save and reads
    \\# when it starts. A line for each key, in the order they are tried:
    \\#
    \\# KEY="ctrl alt f1" COMMAND=CYCLEWINDOWS
    \\# KEY="f12" COMMAND=INSERT ARGS="Kind regards,\n"
    \\# KEY="ctrl alt n" COMMAND=PROGRAM ARGS="SYS:Programs/Notepad"
    \\#
    \\# KEY is a filter description: the qualifiers that must be held and
    \\# the key itself. COMMAND is CYCLEWINDOWS, CYCLESCREENS, ENLARGE,
    \\# SHRINK, TOGGLE, INSERT or PROGRAM. ARGS is the text INSERT types -
    \\# \n a Return, \t a Tab, <f1> a key by its description - or the
    \\# command PROGRAM runs; the others take none.
    \\
;
