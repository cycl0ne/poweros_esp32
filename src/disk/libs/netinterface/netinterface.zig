// SPDX-License-Identifier: MIT
//! The interface files in DEVS:NetInterfaces/, as the `netinterface`
//! module: a file's statements read, and changed where they stand.
//! Compiled into each program that writes such a file - SYS:System/Network
//! for an interface's addresses, SYS:System/WiFi for the network a radio
//! joins at start - so that a file is changed one way.
//!
//! **A file is read as the keyword scanner reads it** (`Statements`): a
//! statement is a keyword at the start of the file, of a line or after a
//! `;`, an `=` and a value - a word, or a string in quotes. Comments, which
//! nest, and strings are passed over, so a keyword in a comment or in a
//! value is no statement.
//!
//! **A file is changed in place** (`withValues`): the first statement of a
//! keyword has its value written over and every other one is taken out, its
//! line with it when nothing else is on it; a keyword with more values than
//! one - `NameServer` - has the others on lines of their own after it; a
//! file without the keyword gets its lines at the end. Everything else stays
//! as it was written, comments and spelling and all. Reading the file whole
//! and writing it back whole is the caller's (`readFile`, `writeFile`), in
//! buffers of its own: `file_max` bytes, which the 16 KiB stack of a 32-bit
//! machine has no room for twice.
//!
//! **A device's file** (`fileNaming`) is the one whose `Device` and `Unit`
//! are that device's unit; a new one (`newFile`) asks DHCP for the
//! address, under the first name of a stem that is free (`freeName`).
//!
//! **An interface is started and stopped** by the commands that do it at
//! every boot (`addInterface`, `remInterface`), run as a shell would run
//! them, and what C:net/AddNetInterface says when it fails is read back
//! from the files it was sent to.

const sdk = @import("sdk");
const dos = sdk.dos;
const TagItem = sdk.utility.TagItem;
const DosBase = sdk.interface.dos.DosBase;

pub const directory = "DEVS:NetInterfaces/";

/// The largest interface file that is changed: a longer one is left to be
/// changed by hand.
pub const file_max: usize = 8192;

/// The room an interface file's path is made in.
pub const Path = [directory.len + 32:0]u8;

/// The file of the interface called `interface`: its name in capitals, as
/// the boot made the interface's name from it in lower case.
pub fn pathOf(interface: []const u8, into: *Path) [*:0]const u8 {
    @memset(into, 0);
    @memcpy(into[0..directory.len], directory);
    for (interface, 0..) |char, at| {
        if (directory.len + at >= into.len) break;
        into[directory.len + at] = upper(char);
    }
    return @ptrCast(into);
}

pub fn upper(char: u8) u8 {
    return if (char >= 'a' and char <= 'z') char - 0x20 else char;
}

pub fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 0x20 else char;
}

/// Whether two words are the same but for the case of their letters, as
/// a keyword is.
pub fn sameWord(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |a, b| if (lower(a) != lower(b)) return false;
    return true;
}

/// Whether `text` can be written as a value: not empty, no quote and no
/// line's end in it.
pub fn writable(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |char| if (char == '"' or char == '\n' or char == '\r' or char == 0) return false;
    return true;
}

// --- reading ------------------------------------------------------------------

/// One statement: where its keyword is, where its value is - without its
/// quotes - and where the statement ends.
pub const Statement = struct {
    start: usize,
    keyword_end: usize,
    /// The value's first byte, its quote for a string.
    value_open: usize,
    value_start: usize,
    value_stop: usize,
    end: usize,

    pub fn keyword(statement: Statement, bytes: []const u8) []const u8 {
        return bytes[statement.start..statement.keyword_end];
    }

    pub fn value(statement: Statement, bytes: []const u8) []const u8 {
        return bytes[statement.value_start..statement.value_stop];
    }
};

/// The statements of a file, one after the other.
pub const Statements = struct {
    bytes: []const u8,
    at: usize = 0,
    depth: usize = 0,
    starting: bool = true,

    pub fn next(it: *Statements) ?Statement {
        const bytes = it.bytes;
        while (it.at < bytes.len) {
            const char = bytes[it.at];
            if (char == '/' and it.at + 1 < bytes.len and bytes[it.at + 1] == '*') {
                it.depth += 1;
                it.at += 2;
                continue;
            }
            if (it.depth > 0) {
                if (char == '*' and it.at + 1 < bytes.len and bytes[it.at + 1] == '/') {
                    it.depth -= 1;
                    it.at += 2;
                } else it.at += 1;
                continue;
            }
            switch (char) {
                '\n', ';' => {
                    it.starting = true;
                    it.at += 1;
                },
                ' ', '\t', '\r' => it.at += 1,
                '"' => {
                    it.at = endOfString(bytes, it.at);
                    it.starting = false;
                },
                else => {
                    const word_start = it.at;
                    while (it.at < bytes.len and !endsWord(bytes[it.at])) it.at += 1;
                    if (it.at == word_start) it.at += 1;
                    const was_starting = it.starting;
                    it.starting = false;
                    if (!was_starting or it.at == word_start + 1 and endsWord(char)) continue;
                    const found = valueAfter(bytes, it.at) orelse continue;
                    const statement: Statement = .{
                        .start = word_start,
                        .keyword_end = it.at,
                        .value_open = found.open,
                        .value_start = found.start,
                        .value_stop = found.stop,
                        .end = found.end,
                    };
                    it.at = found.end;
                    return statement;
                },
            }
        }
        return null;
    }
};

fn endsWord(char: u8) bool {
    return switch (char) {
        ' ', '\t', '\r', '\n', ';', '=', '"' => true,
        else => false,
    };
}

/// Past a string that starts at `at`: after its closing quote, or at the
/// end of its line when it has none.
fn endOfString(bytes: []const u8, at: usize) usize {
    var place = at + 1;
    while (place < bytes.len and bytes[place] != '"' and bytes[place] != '\n') place += 1;
    if (place < bytes.len and bytes[place] == '"') place += 1;
    return place;
}

const Found = struct { open: usize, start: usize, stop: usize, end: usize };

/// The value after a keyword that ends at `at`: past spaces, `=` and
/// spaces, a string or a word. Null when no `=` follows.
fn valueAfter(bytes: []const u8, at: usize) ?Found {
    var place = at;
    while (place < bytes.len and (bytes[place] == ' ' or bytes[place] == '\t')) place += 1;
    if (place == bytes.len or bytes[place] != '=') return null;
    place += 1;
    while (place < bytes.len and (bytes[place] == ' ' or bytes[place] == '\t')) place += 1;
    if (place < bytes.len and bytes[place] == '"') {
        const end = endOfString(bytes, place);
        const stop = if (end > place + 1 and bytes[end - 1] == '"') end - 1 else end;
        return .{ .open = place, .start = place + 1, .stop = stop, .end = end };
    }
    const start = place;
    while (place < bytes.len and !endsWord(bytes[place])) place += 1;
    return .{ .open = start, .start = start, .stop = place, .end = place };
}

/// The first statement of `keyword`; null when the file has none.
pub fn find(bytes: []const u8, keyword: []const u8) ?Statement {
    var it: Statements = .{ .bytes = bytes };
    while (it.next()) |statement| {
        if (sameWord(statement.keyword(bytes), keyword)) return statement;
    }
    return null;
}

/// The value of the first statement of `keyword`; null when there is none,
/// or it is empty.
pub fn valueOf(bytes: []const u8, keyword: []const u8) ?[]const u8 {
    const statement = find(bytes, keyword) orelse return null;
    const value = statement.value(bytes);
    return if (value.len == 0) null else value;
}

/// The values of every statement of `keyword`, as many as `into` holds:
/// how many there are.
pub fn valuesOf(bytes: []const u8, keyword: []const u8, into: [][]const u8) usize {
    var count: usize = 0;
    var it: Statements = .{ .bytes = bytes };
    while (it.next()) |statement| {
        if (count == into.len) break;
        if (!sameWord(statement.keyword(bytes), keyword)) continue;
        const value = statement.value(bytes);
        if (value.len == 0) continue;
        into[count] = value;
        count += 1;
    }
    return count;
}

// --- changing -----------------------------------------------------------------

/// A value to be written, and whether it goes in quotes even where it
/// would read as one word without them - a Wi-Fi network's name, which
/// could be a number.
pub const Value = struct {
    text: []const u8,
    quoted: bool = false,
};

/// `bytes` with `keyword` given `values` - none to take it out - into
/// `into`; null when it does not fit.
pub fn withValues(bytes: []const u8, keyword: []const u8, values: []const Value, into: []u8) ?[]const u8 {
    var out = Out{ .into = into };
    var copied: usize = 0;
    var placed = false;
    var it: Statements = .{ .bytes = bytes };
    while (it.next()) |statement| {
        if (!sameWord(statement.keyword(bytes), keyword)) continue;
        if (!placed and values.len != 0) {
            // The first one keeps its spelling and spacing: only its value
            // is written over, and any more come on lines after it.
            out.put(bytes[copied..statement.value_open]);
            out.value(values[0]);
            for (values[1..]) |more| {
                out.put("\n");
                out.statement(keyword, more);
            }
            copied = statement.end;
            placed = true;
            continue;
        }
        const cut = removal(bytes, statement);
        out.put(bytes[copied..@max(copied, cut.start)]);
        copied = @max(copied, cut.end);
    }
    out.put(bytes[copied..]);
    if (!placed and values.len != 0) {
        if (bytes.len != 0 and bytes[bytes.len - 1] != '\n') out.put("\n");
        for (values) |one| {
            out.statement(keyword, one);
            out.put("\n");
        }
    }
    return out.done();
}

const Cut = struct { start: usize, end: usize };

/// What goes when `statement` is taken out: its line, when nothing else is
/// on it; with the `;` after it, when others follow on its line; with the
/// `;` before it, when it ends a line others started.
fn removal(bytes: []const u8, statement: Statement) Cut {
    var after = statement.end;
    while (after < bytes.len and (bytes[after] == ' ' or bytes[after] == '\t')) after += 1;
    var before = statement.start;
    while (before > 0 and (bytes[before - 1] == ' ' or bytes[before - 1] == '\t')) before -= 1;
    if (after < bytes.len and bytes[after] == ';') {
        after += 1;
        var next = after;
        while (next < bytes.len and (bytes[next] == ' ' or bytes[next] == '\t' or bytes[next] == '\r')) next += 1;
        const line_starts = before == 0 or bytes[before - 1] == '\n';
        // A `;` with nothing after it on the line: the line goes, when the
        // statement also began it.
        if (line_starts and (next == bytes.len or bytes[next] == '\n')) {
            return .{ .start = before, .end = if (next < bytes.len) next + 1 else next };
        }
        while (after < bytes.len and (bytes[after] == ' ' or bytes[after] == '\t')) after += 1;
        return .{ .start = statement.start, .end = after };
    }
    var line_end = after;
    while (line_end < bytes.len and bytes[line_end] == '\r') line_end += 1;
    const alone_after = line_end == bytes.len or bytes[line_end] == '\n';
    if (before == 0 or bytes[before - 1] == '\n') {
        if (alone_after) return .{ .start = before, .end = if (line_end < bytes.len) line_end + 1 else line_end };
        return .{ .start = statement.start, .end = after };
    }
    if (bytes[before - 1] == ';' and alone_after) return .{ .start = before - 1, .end = statement.end };
    return .{ .start = statement.start, .end = statement.end };
}

/// Whether `text` needs quotes to be read as one value.
fn needsQuotes(text: []const u8) bool {
    if (text.len == 0) return true;
    for (text, 0..) |char, at| {
        switch (char) {
            ' ', '\t', ';', '=' => return true,
            '/' => if (at + 1 < text.len and text[at + 1] == '*') return true,
            else => {},
        }
    }
    return false;
}

/// Where an `=` stands in a line the module writes: after the longest
/// keyword the files have, as the files the system comes with write them.
const equals_column: usize = 11;

const Out = struct {
    into: []u8,
    length: usize = 0,
    full: bool = false,

    fn put(out: *Out, bytes: []const u8) void {
        if (out.length + bytes.len > out.into.len) {
            out.full = true;
            return;
        }
        @memcpy(out.into[out.length..][0..bytes.len], bytes);
        out.length += bytes.len;
    }

    fn value(out: *Out, one: Value) void {
        if (one.quoted or needsQuotes(one.text)) {
            out.put("\"");
            out.put(one.text);
            out.put("\"");
        } else out.put(one.text);
    }

    fn statement(out: *Out, keyword: []const u8, one: Value) void {
        out.put(keyword);
        var column = keyword.len;
        out.put(" ");
        column += 1;
        while (column < equals_column) : (column += 1) out.put(" ");
        out.put("= ");
        out.value(one);
    }

    fn done(out: *Out) ?[]const u8 {
        return if (out.full) null else out.into[0..out.length];
    }
};

// --- the files ----------------------------------------------------------------

/// The file at `path` read whole into `into`; null when it cannot be
/// opened, or does not fit.
pub fn readFile(dl: *DosBase, path: [*:0]const u8, into: []u8) ?[]u8 {
    const file = dl.Open(path, dos.MODE_OLDFILE) orelse return null;
    defer _ = dl.Close(file);
    var length: usize = 0;
    while (length < into.len) {
        const got = dl.Read(file, into.ptr + length, @intCast(into.len - length));
        if (got < 0) return null;
        if (got == 0) return into[0..length];
        length += @intCast(got);
    }
    // Full: whatever is past it would be lost if it were written back.
    var probe: [1]u8 = undefined;
    if (dl.Read(file, &probe, 1) != 0) return null;
    return into[0..length];
}

/// `bytes` written as the file at `path`, the drawers on the way to it
/// made first: false when it could not be, and IoErr says why.
pub fn writeFile(dl: *DosBase, path: [*:0]const u8, bytes: []const u8) bool {
    if (!dl.CreateDirs(path, false)) return false;
    const file = dl.Open(path, dos.MODE_NEWFILE) orelse return false;
    const written = dl.Write(file, bytes.ptr, @intCast(bytes.len));
    const closed = dl.Close(file);
    return written == bytes.len and closed;
}

// --- the file of a device ------------------------------------------------------

/// A file's name in DEVS:NetInterfaces/.
pub const Name = [32:0]u8;

/// The number `text` says in decimal, or null for anything else.
pub fn numberOf(text: []const u8) ?u32 {
    if (text.len == 0 or text.len > 9) return null;
    var value: u32 = 0;
    for (text) |char| {
        if (char < '0' or char > '9') return null;
        value = value * 10 + (char - '0');
    }
    return value;
}

/// Whether the file `bytes` is an interface on `device`'s `unit`: its
/// `Device` the same but for the case of its letters, its `Unit` the same
/// number - 0 when it names none, as C:net/AddNetInterface takes it.
pub fn names(bytes: []const u8, device: []const u8, unit: u32) bool {
    const said = valueOf(bytes, "Device") orelse return false;
    if (!sameWord(said, device)) return false;
    return (numberOf(valueOf(bytes, "Unit") orelse "0") orelse return false) == unit;
}

/// The file in DEVS:NetInterfaces/ whose interface is on `device`'s
/// `unit`, its name into `name`, each file read into `buffer` as it is
/// looked at: whether there is one. A name with a dot in it is no
/// interface's and is passed over, as a drawer is.
pub fn fileNaming(dl: *DosBase, device: []const u8, unit: u32, name: *Name, buffer: []u8) bool {
    const lock = dl.Lock("DEVS:NetInterfaces", dos.ACCESS_READ) orelse return false;
    defer dl.UnLock(lock);
    const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_FIB, null) orelse return false));
    defer dl.FreeDosObject(dos.DOS_FIB, fib);
    if (!dl.Examine(lock, fib)) return false;
    while (dl.ExNext(lock, fib)) {
        if (dos.isDirectory(fib.dir_entry_type)) continue;
        const found = untilNul(&fib.file_name);
        if (found.len == 0 or found.len >= name.len) continue;
        const dot = for (found) |char| {
            if (char == '.') break true;
        } else false;
        if (dot) continue;
        var path: Path = undefined;
        const bytes = readFile(dl, pathOf(found, &path), buffer) orelse continue;
        if (!names(bytes, device, unit)) continue;
        @memset(name, 0);
        @memcpy(name[0..found.len], found);
        return true;
    }
    return false;
}

/// The first of `stem` followed by a digit - WLAN0, WLAN1, ... - that no
/// file in DEVS:NetInterfaces/ has, into `name`; false when all ten are
/// taken.
pub fn freeName(dl: *DosBase, stem: []const u8, name: *Name) bool {
    if (stem.len + 1 >= name.len) return false;
    var digit: u8 = '0';
    while (digit <= '9') : (digit += 1) {
        @memset(name, 0);
        @memcpy(name[0..stem.len], stem);
        name[stem.len] = digit;
        var path: Path = undefined;
        const lock = dl.Lock(pathOf(untilNul(name), &path), dos.ACCESS_READ) orelse {
            if (dl.IoErr() == dos.ERROR_OBJECT_NOT_FOUND) return true;
            continue;
        };
        dl.UnLock(lock);
    }
    return false;
}

/// A new interface file `name` on `device`'s `unit`, whose address DHCP
/// gives, into `into`: null when it does not fit, or `device` cannot be
/// written as a value.
pub fn newFile(name: []const u8, device: []const u8, unit: u32, into: []u8) ?[]const u8 {
    if (!writable(device)) return null;
    var out = Out{ .into = into };
    out.put("/* " ++ directory);
    out.put(name);
    out.put(": ");
    out.put(device);
    out.put(" unit ");
    var digits: [10]u8 = undefined;
    const unit_text = decimal(unit, &digits);
    out.put(unit_text);
    out.put(", brought up as ");
    for (name) |char| out.put(&[_]u8{lower(char)});
    out.put("\n * at every start. SYS:System/Network sets its addresses. */\n");
    out.statement("Device", .{ .text = device });
    out.put("\n");
    out.statement("Unit", .{ .text = unit_text });
    out.put("\n");
    out.statement("Configure", .{ .text = "DHCP" });
    out.put("\n");
    return out.done();
}

fn decimal(number: u32, into: *[10]u8) []const u8 {
    var at: usize = into.len;
    var rest = number;
    while (true) {
        at -= 1;
        into[at] = '0' + @as(u8, @intCast(rest % 10));
        rest /= 10;
        if (rest == 0) break;
    }
    return into[at..];
}

pub fn untilNul(bytes: []const u8) []const u8 {
    for (bytes, 0..) |byte, at| if (byte == 0) return bytes[0..at];
    return bytes;
}

// --- starting and stopping ------------------------------------------------------

/// What starting an interface takes beside the stack, kept by the caller
/// where it has room: the command's line, and the room a file the command
/// wrote is read into.
pub const Work = struct {
    command: [192:0]u8 = @splat(0),
    said: [256]u8 = @splat(0),
};

/// How a start went: the command's return code, and the first line it
/// said - on its error stream, else on its output - or "" for none.
pub const Started = struct {
    code: i32,
    said: []const u8 = "",
};

/// The interface of the file `file` in DEVS:NetInterfaces/ started by
/// C:net/AddNetInterface NOWAIT: what it answered. What it says goes to
/// T:`owner`.out and T:`owner`.err, read for the first line said, and
/// deleted.
pub fn addInterface(dl: *DosBase, file: []const u8, comptime owner: []const u8, work: *Work) Started {
    const out_file = "T:" ++ owner ++ ".out";
    const err_file = "T:" ++ owner ++ ".err";
    var line = Out{ .into = work.command[0 .. work.command.len - 1] };
    line.put("C:net/AddNetInterface ");
    line.put(file);
    line.put(" NOWAIT <NIL: >" ++ out_file ++ " *>" ++ err_file);
    const length = (line.done() orelse return .{ .code = dos.RETURN_FAIL }).len;
    work.command[length] = 0;
    const code = run(dl, &work.command);
    defer {
        _ = dl.DeleteFile(out_file);
        _ = dl.DeleteFile(err_file);
    }
    if (code == dos.RETURN_OK) return .{ .code = code };
    const said = firstLine(dl, err_file, &work.said) orelse firstLine(dl, out_file, &work.said) orelse "";
    return .{ .code = code, .said = said };
}

/// The interface `interface` taken down by C:net/RemNetInterface, which
/// says nothing - one that is not up is no fault.
pub fn remInterface(dl: *DosBase, interface: []const u8, work: *Work) void {
    var line = Out{ .into = work.command[0 .. work.command.len - 1] };
    line.put("C:net/RemNetInterface ");
    line.put(interface);
    line.put(" QUIET <NIL: >NIL:");
    const length = (line.done() orelse return).len;
    work.command[length] = 0;
    _ = run(dl, &work.command);
}

/// `command` run to its end, as a shell runs a line, on a stack as large
/// as a shell's.
fn run(dl: *DosBase, command: [*:0]const u8) i32 {
    return dl.SystemTagList(command, &[_]TagItem{
        .{ .tag = dos.NP_StackSize, .data = dos.CLI_DEFAULT_STACK },
        .{},
    });
}

/// The first line with something on it of the file at `path`, read into
/// `into`; null when there is none.
fn firstLine(dl: *DosBase, path: [*:0]const u8, into: []u8) ?[]const u8 {
    const file = dl.Open(path, dos.MODE_OLDFILE) orelse return null;
    const got = dl.Read(file, into.ptr, @intCast(into.len));
    _ = dl.Close(file);
    if (got <= 0) return null;
    const length: usize = @intCast(got);
    var start: usize = 0;
    while (start < length) {
        var end = start;
        while (end < length and into[end] != '\n') end += 1;
        const line = trimmed(into[start..end]);
        if (line.len != 0) return line;
        start = end + 1;
    }
    return null;
}

fn trimmed(bytes: []const u8) []const u8 {
    var start: usize = 0;
    var end = bytes.len;
    while (start < end and isSpace(bytes[start])) start += 1;
    while (end > start and isSpace(bytes[end - 1])) end -= 1;
    return bytes[start..end];
}

fn isSpace(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\r';
}

// --- tests (host) -------------------------------------------------------------

const testing = @import("std").testing;

const sample =
    \\/* DEVS:NetInterfaces/WLAN0
    \\ *   Network = "<network>"   in a comment: not the file's
    \\ */
    \\Device     = networks/cyw43455.device
    \\Unit       = 0
    \\Configure  = DHCP
    \\
;

fn change(bytes: []const u8, keyword: []const u8, values: []const Value, room: []u8) ![]const u8 {
    return withValues(bytes, keyword, values, room) orelse error.NoRoom;
}

test "statements as the scanner reads them: comments, nested, and values are passed over" {
    try testing.expect(valueOf(sample, "Network") == null);
    try testing.expectEqualStrings("DHCP", valueOf(sample, "configure").?);
    try testing.expect(valueOf("/* a /* b */ Network = \"x\" */\nDevice = y\n", "Network") == null);
    try testing.expect(valueOf("Configure = Network\n", "Network") == null);
    try testing.expectEqualStrings("Mine", valueOf("/* a /* b */ c */ Network=\"Mine\"\n", "Network").?);
    try testing.expectEqualStrings("Cafe", valueOf("Device = x.device; Network = Cafe; Unit = 1\n", "Network").?);
}

test "a keyword the file lacks: its line added at the end, nothing taken out" {
    var room: [512]u8 = undefined;
    const added = try change(sample, "Network", &.{.{ .text = "Home net", .quoted = true }}, &room);
    try testing.expectEqualStrings(sample ++ "Network    = \"Home net\"\n", added);
    try testing.expectEqualStrings("Home net", valueOf(added, "Network").?);
    var again: [512]u8 = undefined;
    try testing.expectEqualStrings(sample, try change(sample, "Network", &.{}, &again));
}

test "a value written over in the statement's own spelling, and taken out with its line" {
    const with = sample ++ "network = \"Old\"\n";
    var room: [512]u8 = undefined;
    try testing.expectEqualStrings(sample ++ "network = \"New\"\n", try change(with, "Network", &.{.{ .text = "New", .quoted = true }}, &room));
    var gone: [512]u8 = undefined;
    try testing.expectEqualStrings(sample, try change(with, "Network", &.{}, &gone));
    var fixed: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "Device     = networks/cyw43455.device\nUnit       = 0\nConfigure  = FIXED\n",
        try change("Device     = networks/cyw43455.device\nUnit       = 0\nConfigure  = DHCP\n", "Configure", &.{.{ .text = "FIXED" }}, &fixed),
    );
}

test "a statement beside others on its line: only it changes" {
    const line = "Device = x.device; Network = Cafe; Unit = 1\n";
    var room: [128]u8 = undefined;
    try testing.expectEqualStrings("Device = x.device; Network = \"Bar\"; Unit = 1\n", try change(line, "Network", &.{.{ .text = "Bar", .quoted = true }}, &room));
    var gone: [128]u8 = undefined;
    try testing.expectEqualStrings("Device = x.device; Unit = 1\n", try change(line, "Network", &.{}, &gone));
    var last: [128]u8 = undefined;
    try testing.expectEqualStrings("Device = x.device\nUnit = 1\n", try change("Device = x.device; Network = Cafe\nUnit = 1\n", "Network", &.{}, &last));
    var first: [128]u8 = undefined;
    try testing.expectEqualStrings("Unit = 1\n", try change("Network = Cafe;\nUnit = 1\n", "Network", &.{}, &first));
}

test "a keyword of many values: the first written over, the rest after it, the old ones gone" {
    const file =
        \\Device     = x.device
        \\NameServer = 1.1.1.1
        \\Configure  = DHCP
        \\NameServer = 8.8.8.8
        \\
    ;
    var buffer: [16][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 2), valuesOf(file, "NameServer", &buffer));
    try testing.expectEqualStrings("8.8.8.8", buffer[1]);
    var room: [256]u8 = undefined;
    const three = try change(file, "NameServer", &.{ .{ .text = "9.9.9.9" }, .{ .text = "2620:fe::fe" }, .{ .text = "149.112.112.112" } }, &room);
    try testing.expectEqualStrings(
        \\Device     = x.device
        \\NameServer = 9.9.9.9
        \\NameServer = 2620:fe::fe
        \\NameServer = 149.112.112.112
        \\Configure  = DHCP
        \\
    , three);
    var none: [256]u8 = undefined;
    try testing.expectEqualStrings("Device     = x.device\nConfigure  = DHCP\n", try change(file, "NameServer", &.{}, &none));
}

test "a value that would not read as one word goes in quotes" {
    var room: [128]u8 = undefined;
    try testing.expectEqualStrings("Domain     = \"my home\"\n", try change("", "Domain", &.{.{ .text = "my home" }}, &room));
    var plain: [128]u8 = undefined;
    try testing.expectEqualStrings("Address    = 192.168.1.20\n", try change("", "Address", &.{.{ .text = "192.168.1.20" }}, &plain));
}

test "the room it is written in: null when it does not fit" {
    var room: [8]u8 = undefined;
    try testing.expect(withValues(sample, "Network", &.{.{ .text = "Home" }}, &room) == null);
}

test "an interface's file, by its name in capitals" {
    var path: Path = undefined;
    const at = pathOf("wlan0", &path);
    var length: usize = 0;
    while (at[length] != 0) length += 1;
    try testing.expectEqualStrings("DEVS:NetInterfaces/WLAN0", at[0..length]);
    try testing.expect(writable("Home net"));
    try testing.expect(!writable("say \"hi\""));
    try testing.expect(!writable(""));
}

test "a file names a device's unit: the device's case aside, unit 0 without one" {
    try testing.expect(names(sample, "networks/CYW43455.device", 0));
    try testing.expect(!names(sample, "networks/cyw43455.device", 1));
    try testing.expect(!names(sample, "networks/emac.device", 0));
    try testing.expect(names("Device = usb/aic8800.device; Unit = 2", "usb/aic8800.device", 2));
    try testing.expect(!names("Unit = 0", "usb/aic8800.device", 0));
}

test "a new file asks DHCP, and reads back as the device's" {
    var room: [512]u8 = undefined;
    const made = newFile("WLAN1", "networks/cyw43455.device", 0, &room).?;
    try testing.expectEqualStrings(
        \\/* DEVS:NetInterfaces/WLAN1: networks/cyw43455.device unit 0, brought up as wlan1
        \\ * at every start. SYS:System/Network sets its addresses. */
        \\Device     = networks/cyw43455.device
        \\Unit       = 0
        \\Configure  = DHCP
        \\
    , made);
    try testing.expect(names(made, "networks/cyw43455.device", 0));
    try testing.expectEqualStrings("DHCP", valueOf(made, "Configure").?);
    var small: [40]u8 = undefined;
    try testing.expect(newFile("WLAN1", "networks/cyw43455.device", 0, &small) == null);
}
