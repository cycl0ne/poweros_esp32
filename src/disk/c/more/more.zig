// SPDX-License-Identifier: MIT
//! More: text a screenful at a time, as a program on disk, built as a load
//! file by sdk/tools/elf2seg.
//!
//! `MORE [FILE]`: the file, or without one the command's own input, so it
//! ends a pipeline: `dir all | more`. The keys come from the console ("*"),
//! a key at a time in raw mode, whichever way the text comes in.
//!
//! The keys - `h` shows them:
//!
//!   Space, Down, PageDown    the next page; on the last one, the end
//!   Return                   the next line
//!   b, Backspace, Up, PageUp the page before
//!   <, Left                  the first page
//!   >, Right                 the last page
//!   %N                       N per cent into the text
//!   /text, .text             the next row with the text in it; / minds
//!                            case, . does not
//!   \text, ,text             the same, backwards
//!   n, p                     the last search again, forwards or backwards
//!   Ctrl-L                   the page drawn again
//!   h, Help                  the keys
//!   q, Esc, Ctrl-C           the end
//!
//! What has been read is kept, so text from a pipe pages back as a file
//! does. It is read only as far as the screen needs, so `>`, `%` and a
//! search read on to the end. A line wider than the window goes on in the
//! next row, and a search looks at one row at a time. The window's size
//! comes from the console (`CSI 18 t`), 24 rows of 80 when it does not
//! answer.
//!
//! Output that is not a console, or no console to take keys from, gets the
//! text copied through as it is, as Type does. Without FILE and with
//! nothing piped in there is nothing to show, and More says so.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const FileHandle = dos.FileHandle;
const rdargs = dos.rdargs;

const NAME = "More";
const VERSION_STRING = "\x00$VER: More 1.0 (06.10.2026)\r\n";

/// How much is read at a time.
const read_size = 4096;
const tab_width = 8;
/// The longest search text.
const search_max = 80;
/// A key that is not there within this is waited for again, after a look
/// for Ctrl-C.
const key_wait = 200_000;

const help_text =
    \\  Space, Down, PageDown     next page (the end, on the last one)
    \\  Return                    next line
    \\  b, Backspace, Up, PageUp  page before
    \\  <, Left                   first page
    \\  >, Right                  last page
    \\  %N                        N per cent into the text
    \\  /text                     search forwards, case minded
    \\  .text                     search forwards, any case
    \\  \text  ,text              the same, backwards
    \\  n, p                      search again, forwards or backwards
    \\  Ctrl-L                    draw the page again
    \\  h, Help                   these keys
    \\  q, Esc, Ctrl-C            quit
    \\
;

/// A row on the screen: where its text starts in `Text.bytes` and how many
/// bytes it is, its newline left out.
const Row = extern struct { start: u32, len: u32 };

/// What an escape sequence in the text has got to: it takes no room on
/// the screen.
const Escape = enum { none, esc, csi };

/// The text, as far as it has been read, and the rows it makes at the
/// window's width.
const Text = struct {
    sys: *ExecBase,
    dl: *DosBase,
    file: ?*FileHandle,
    cols: u32,
    /// The file's size, 0 when it is not known (a pipe).
    size: u64 = 0,
    bytes: ?[*]u8 = null,
    len: u32 = 0,
    cap: u32 = 0,
    rows: ?[*]Row = null,
    row_count: u32 = 0,
    row_cap: u32 = 0,
    /// The row being read: where it starts, and how wide it is so far.
    open_start: u32 = 0,
    open_width: u32 = 0,
    escape: Escape = .none,
    /// Everything has been read, or no more could be kept.
    ended: bool = false,
    /// Ctrl-C while reading.
    broken: bool = false,

    fn free(text: *Text) void {
        if (text.bytes) |bytes| text.sys.FreeVec(bytes);
        if (text.rows) |rows| text.sys.FreeVec(rows);
    }

    fn row(text: *const Text, index: u32) Row {
        return text.rows.?[index];
    }

    fn rowBytes(text: *const Text, index: u32) []const u8 {
        const entry = text.row(index);
        return text.bytes.?[entry.start..][0..entry.len];
    }

    /// Room for `extra` more bytes, the buffer doubled as often as that
    /// takes.
    fn roomForBytes(text: *Text, extra: u32) bool {
        if (text.len + extra <= text.cap) return true;
        var cap: u32 = if (text.cap == 0) 16 * 1024 else text.cap;
        while (cap < text.len + extra) cap *= 2;
        const fresh: [*]u8 = @ptrCast(text.sys.AllocVec(cap, exec.MEMF_ANY) orelse return false);
        if (text.bytes) |old| {
            @memcpy(fresh[0..text.len], old[0..text.len]);
            text.sys.FreeVec(old);
        }
        text.bytes = fresh;
        text.cap = cap;
        return true;
    }

    /// The row from `open_start` to `end` closed, and a new one opened at
    /// `next`.
    fn closeRow(text: *Text, end: u32, next: u32) bool {
        if (text.row_count == text.row_cap) {
            const cap: u32 = if (text.row_cap == 0) 1024 else text.row_cap * 2;
            const fresh: [*]Row = @ptrCast(@alignCast(text.sys.AllocVec(cap * @sizeOf(Row), exec.MEMF_ANY) orelse return false));
            if (text.rows) |old| {
                @memcpy(fresh[0..text.row_count], old[0..text.row_count]);
                text.sys.FreeVec(old);
            }
            text.rows = fresh;
            text.row_cap = cap;
        }
        text.rows.?[text.row_count] = .{ .start = text.open_start, .len = end - text.open_start };
        text.row_count += 1;
        text.open_start = next;
        text.open_width = 0;
        return true;
    }

    /// Reads on until `want` rows are there or the text ends.
    fn readTo(text: *Text, want: u32) void {
        while (text.row_count < want and !text.ended) {
            if (text.dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
                text.broken = true;
                text.ended = true;
                return;
            }
            if (!text.roomForBytes(read_size)) {
                text.ended = true;
                return;
            }
            const got = text.dl.Read(text.file, text.bytes.? + text.len, read_size);
            if (got <= 0) {
                // A last line without a newline is a row all the same.
                if (text.len > text.open_start) _ = text.closeRow(text.len, text.len);
                text.ended = true;
                return;
            }
            const from = text.len;
            text.len += @intCast(got);
            if (!text.split(from)) text.ended = true;
        }
    }

    fn readAll(text: *Text) void {
        text.readTo(0xFFFF_FFFF);
    }

    /// The bytes from `from` to `len` made into rows.
    fn split(text: *Text, from: u32) bool {
        var at = from;
        while (at < text.len) : (at += 1) {
            const byte = text.bytes.?[at];
            switch (text.escape) {
                .esc => {
                    text.escape = if (byte == '[') .csi else .none;
                    continue;
                },
                .csi => {
                    if (byte >= 0x40 and byte <= 0x7E) text.escape = .none;
                    continue;
                },
                .none => {},
            }
            switch (byte) {
                '\n' => if (!text.closeRow(at, at + 1)) return false,
                0x1B => text.escape = .esc,
                0x9B => text.escape = .csi,
                '\t' => {
                    const width = (text.open_width / tab_width + 1) * tab_width;
                    if (width > text.cols) {
                        if (!text.closeRow(at, at)) return false;
                        text.open_width = tab_width;
                    } else text.open_width = width;
                },
                else => {
                    if (byte < 0x20) continue;
                    if (text.open_width == text.cols) {
                        if (!text.closeRow(at, at)) return false;
                    }
                    text.open_width += 1;
                },
            }
        }
        return true;
    }
};

/// The screen and what is on it.
const Pager = struct {
    dl: *DosBase,
    text: *Text,
    out: ?*FileHandle,
    keys: ?*FileHandle,
    /// The rows of text a page shows: the window's, less the prompt's.
    page: u32,
    /// The first row on the screen, and the first not shown yet.
    top: u32 = 0,
    next: u32 = 0,
    search: [search_max + 1]u8 = @splat(0),
    search_len: usize = 0,
    case_minded: bool = true,
    found: bool = true,
    /// The last key was a Return, so a line feed after it is part of it.
    after_return: bool = false,

    fn put(pager: *Pager, bytes: []const u8) void {
        _ = pager.dl.Write(pager.out, bytes.ptr, @intCast(bytes.len));
    }

    /// The rows from `first` up to `end`.
    fn showRows(pager: *Pager, first: u32, end: u32) void {
        var index = first;
        while (index < end) : (index += 1) {
            pager.put(pager.text.rowBytes(index));
            pager.put("\n");
        }
    }

    fn clearPrompt(pager: *Pager) void {
        pager.put("\r\x1b[0m\x1b[K");
    }

    /// The page that starts at row `first`, on a cleared screen.
    fn drawPage(pager: *Pager, first: u32) void {
        pager.text.readTo(first + pager.page);
        const start = @min(first, pager.text.row_count);
        const end = @min(start + pager.page, pager.text.row_count);
        pager.put("\x1b[0m\x1b[H\x1b[2J");
        pager.showRows(start, end);
        pager.top = start;
        pager.next = end;
    }

    /// `count` more rows, scrolled in under what is there.
    fn forward(pager: *Pager, count: u32) void {
        pager.text.readTo(pager.next + count);
        const end = @min(pager.next + count, pager.text.row_count);
        pager.clearPrompt();
        pager.showRows(pager.next, end);
        pager.next = end;
        pager.top = pager.next -| pager.page;
    }

    fn atEnd(pager: *Pager) bool {
        pager.text.readTo(pager.next + 1);
        return pager.text.ended and pager.next >= pager.text.row_count;
    }

    /// The line at the bottom: where the text has got to, in reverse.
    fn prompt(pager: *Pager) void {
        var line: [48]u8 = undefined;
        var used: usize = 0;
        const say = struct {
            fn append(buffer: []u8, at: *usize, bytes: []const u8) void {
                const room = @min(bytes.len, buffer.len - at.*);
                @memcpy(buffer[at.*..][0..room], bytes[0..room]);
                at.* += room;
            }
        }.append;
        say(&line, &used, "\x1b[7m");
        if (!pager.found) {
            say(&line, &used, "--Not found--");
            pager.found = true;
        } else if (pager.atEnd()) {
            say(&line, &used, "--End--");
        } else {
            say(&line, &used, "--More--");
            if (pager.percent()) |shown| {
                var digits: [3]u8 = undefined;
                var count: usize = 0;
                var value = shown;
                while (true) {
                    digits[count] = '0' + @as(u8, @intCast(value % 10));
                    count += 1;
                    value /= 10;
                    if (value == 0) break;
                }
                say(&line, &used, "(");
                while (count > 0) {
                    count -= 1;
                    say(&line, &used, digits[count..][0..1]);
                }
                say(&line, &used, "%)");
            }
        }
        say(&line, &used, "\x1b[0m");
        pager.put(line[0..used]);
    }

    /// How far into the text the screen's end is, when that is known: by
    /// bytes in a file, by rows once a pipe has ended.
    fn percent(pager: *Pager) ?u32 {
        const text = pager.text;
        if (pager.next == 0) return 0;
        if (text.size != 0) {
            const last = text.row(pager.next - 1);
            const shown: u64 = last.start + last.len;
            return @intCast(@min(shown * 100 / text.size, 100));
        }
        if (text.ended and text.row_count != 0) return pager.next * 100 / text.row_count;
        return null;
    }

    /// The next key, the console's sequences made into the plain keys they
    /// stand for; 'q' for Ctrl-C, and 0 for a key that means nothing here.
    fn key(pager: *Pager) u8 {
        const dl = pager.dl;
        const byte = pager.waitByte() orelse return 'q';
        const was_return = pager.after_return;
        pager.after_return = false;
        return switch (byte) {
            0x03 => 'q',
            '\r' => blk: {
                pager.after_return = true;
                break :blk '\r';
            },
            '\n' => if (was_return) 0 else '\r',
            0x08, 0x7F => 'b',
            0x0C => 0x0C,
            0x1B => if (dl.WaitForChar(pager.keys, 50_000) and pager.readByte() == '[') pager.sequence() else 'q',
            0x9B => pager.sequence(),
            else => byte,
        };
    }

    /// The next byte typed, waited for with an eye on Ctrl-C: null for
    /// Ctrl-C, or a console that has ended.
    fn waitByte(pager: *Pager) ?u8 {
        while (!pager.dl.WaitForChar(pager.keys, key_wait)) {
            if (pager.dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) return null;
        }
        return pager.readByte();
    }

    fn readByte(pager: *Pager) ?u8 {
        var byte: u8 = 0;
        if (pager.dl.Read(pager.keys, @ptrCast(&byte), 1) != 1) return null;
        return byte;
    }

    /// The rest of a control sequence, as the key it is.
    fn sequence(pager: *Pager) u8 {
        var body: [8]u8 = undefined;
        var used: usize = 0;
        while (true) {
            const byte = pager.readByte() orelse return 'q';
            if (byte >= 0x40 and byte <= 0x7E) {
                const params = body[0..used];
                return switch (byte) {
                    'A' => 'b',
                    'B' => ' ',
                    'C' => '>',
                    'D' => '<',
                    '~' => if (same(params, "5")) 'b' else if (same(params, "6")) ' ' else if (same(params, "?") or same(params, "28")) 'h' else 0,
                    else => 0,
                };
            }
            if (used < body.len) {
                body[used] = byte;
                used += 1;
            }
        }
    }

    /// A line typed at the bottom after `lead`, still in raw mode, so what
    /// was typed ahead is kept and the Return scrolls nothing: echoed here,
    /// Backspace takes back the last character, Return ends it, and Esc or
    /// Ctrl-C give it up. Null when nothing was typed or it was given up.
    fn ask(pager: *Pager, lead: []const u8, into: []u8) ?[]u8 {
        pager.clearPrompt();
        pager.put(lead);
        var len: usize = 0;
        while (true) {
            const byte = pager.waitByte() orelse return null;
            switch (byte) {
                '\r', '\n' => {
                    pager.after_return = byte == '\r';
                    break;
                },
                0x08, 0x7F => if (len > 0) {
                    len -= 1;
                    pager.put("\x08 \x08");
                },
                0x03, 0x1B, 0x9B => return null,
                else => if (byte >= 0x20 and len < into.len) {
                    into[len] = byte;
                    len += 1;
                    pager.put(into[len - 1 .. len]);
                },
            }
        }
        if (len == 0) return null;
        return into[0..len];
    }

    /// The search again from the row after the top (forwards) or before it
    /// (backwards); the page drawn from the row it is found on.
    fn find(pager: *Pager, backwards: bool) void {
        if (pager.search_len == 0) return;
        const needle = pager.search[0..pager.search_len];
        const text = pager.text;
        if (backwards) {
            var index = pager.top;
            while (index > 0) {
                index -= 1;
                if (pager.matches(text.rowBytes(index), needle)) return pager.drawPage(index);
            }
        } else {
            var index = pager.top + 1;
            while (true) : (index += 1) {
                text.readTo(index + 1);
                if (index >= text.row_count) break;
                if (pager.matches(text.rowBytes(index), needle)) return pager.drawPage(index);
            }
        }
        pager.found = false;
        pager.clearPrompt();
    }

    fn matches(pager: *Pager, row_text: []const u8, needle: []const u8) bool {
        if (needle.len > row_text.len) return false;
        var start: usize = 0;
        while (start + needle.len <= row_text.len) : (start += 1) {
            var at: usize = 0;
            while (at < needle.len) : (at += 1) {
                var have = row_text[start + at];
                var want = needle[at];
                if (!pager.case_minded) {
                    have = lower(have);
                    want = lower(want);
                }
                if (have != want) break;
            }
            if (at == needle.len) return true;
        }
        return false;
    }

    fn help(pager: *Pager) bool {
        pager.put("\x1b[0m\x1b[H\x1b[2J");
        pager.put(help_text);
        pager.put("\x1b[7m--Any key--\x1b[0m");
        const typed = pager.key();
        pager.drawPage(pager.top);
        return typed != 'q';
    }

    /// One key's worth. False to end.
    fn step(pager: *Pager) bool {
        pager.prompt();
        const typed = pager.key();
        if (pager.text.broken) return false;
        switch (typed) {
            'q', 'Q' => return false,
            ' ' => {
                if (pager.atEnd()) return false;
                pager.forward(pager.page);
            },
            '\r' => pager.forward(1),
            'b' => pager.drawPage(pager.top -| pager.page),
            '<' => pager.drawPage(0),
            '>' => {
                pager.text.readAll();
                pager.drawPage(pager.text.row_count -| pager.page);
            },
            0x0C => pager.drawPage(pager.top),
            'h', 'H' => return pager.help(),
            '%' => {
                var typed_number: [8]u8 = undefined;
                const answer = pager.ask("%", &typed_number) orelse {
                    pager.clearPrompt();
                    return true;
                };
                var value: u32 = 0;
                for (answer) |digit| {
                    if (digit < '0' or digit > '9') break;
                    value = @min(value * 10 + (digit - '0'), 100);
                }
                pager.text.readAll();
                pager.drawPage(pager.text.row_count * value / 100);
            },
            '/', '.', '\\', ',' => {
                const lead: []const u8 = switch (typed) {
                    '/' => "/",
                    '.' => ".",
                    '\\' => "\\",
                    else => ",",
                };
                const answer = pager.ask(lead, pager.search[0..search_max]) orelse {
                    pager.clearPrompt();
                    return true;
                };
                pager.search_len = answer.len;
                pager.case_minded = typed == '/' or typed == '\\';
                pager.find(typed == '\\' or typed == ',');
            },
            'n' => pager.find(false),
            'p' => pager.find(true),
            else => pager.clearPrompt(),
        }
        return !pager.text.broken;
    }
};

fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn same(bytes: []const u8, comptime word: []const u8) bool {
    if (bytes.len != word.len) return false;
    for (bytes, word) |have, want| {
        if (have != want) return false;
    }
    return true;
}

/// How big the console says it is: `CSI 18 t` asked, and `CSI 8;rows;cols
/// t` read back in raw mode. What has not answered in half a second does
/// not answer, and `rows` and `cols` stay as they are.
fn askSize(dl: *DosBase, out: ?*FileHandle, keys: ?*FileHandle, rows: *u32, cols: *u32) void {
    if (dl.Write(out, "\x1b[18t", 5) < 0) return;
    var reply: [24]u8 = undefined;
    var len: usize = 0;
    var waits: u32 = 0;
    while (len < reply.len and waits < 5) {
        if (!dl.WaitForChar(keys, 100_000)) {
            waits += 1;
            continue;
        }
        var byte: u8 = 0;
        if (dl.Read(keys, @ptrCast(&byte), 1) != 1) return;
        // What was typed before the answer - the Return that started More,
        // most often - is not part of it.
        if (len == 0 and byte != 0x1B) continue;
        reply[len] = byte;
        len += 1;
        if (byte == 't') break;
    }
    // ESC [ 8 ; rows ; cols t
    if (len < 6 or reply[1] != '[' or reply[2] != '8' or reply[3] != ';' or reply[len - 1] != 't') return;
    var values: [2]u32 = .{ 0, 0 };
    var which: usize = 0;
    for (reply[4 .. len - 1]) |byte| {
        if (byte == ';') {
            which += 1;
            if (which == values.len) return;
        } else if (byte >= '0' and byte <= '9') {
            values[which] = values[which] * 10 + (byte - '0');
        } else return;
    }
    // A window of one row or one column is an answer nothing fits in.
    if (which != 1 or values[0] < 2 or values[1] < 2) return;
    rows.* = values[0];
    cols.* = values[1];
}

/// The text copied through to the output as it is.
fn copyThrough(dl: *DosBase, file: ?*FileHandle, out: ?*FileHandle) i32 {
    var buffer: [read_size]u8 = undefined;
    while (true) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, NAME);
            return dos.RETURN_WARN;
        }
        const got = dl.Read(file, &buffer, buffer.len);
        if (got < 0) {
            _ = dl.PrintFault(dl.IoErr(), NAME);
            return dos.RETURN_ERROR;
        }
        if (got == 0) return dos.RETURN_OK;
        if (dl.Write(out, &buffer, got) != got) return dos.RETURN_ERROR;
    }
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs("FILE", &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);

    // The text: the file, or what is piped in.
    var opened: ?*FileHandle = null;
    defer if (opened) |fh| {
        _ = dl.Close(fh);
    };
    const file = if (rdargs.string(argv[0])) |name| blk: {
        opened = dl.Open(name, dos.MODE_OLDFILE) orelse {
            _ = dl.PrintFault(dl.IoErr(), name);
            return dos.RETURN_ERROR;
        };
        break :blk opened;
    } else blk: {
        const input = dl.Input();
        if (dl.IsInteractive(input)) {
            _ = dl.PutStr("More shows a FILE, or text piped into it: dir all | more\n");
            return dos.RETURN_WARN;
        }
        break :blk input;
    };

    // The keys come from the console, wherever the text comes from.
    const out = dl.Output();
    const keys = dl.Open("*", dos.MODE_OLDFILE);
    defer if (keys) |fh| {
        _ = dl.Close(fh);
    };
    if (!dl.IsInteractive(out) or keys == null or !dl.IsInteractive(keys)) return copyThrough(dl, file, out);
    if (!dl.SetMode(keys, 1)) return copyThrough(dl, file, out);
    defer _ = dl.SetMode(keys, 0);

    var rows: u32 = 24;
    var cols: u32 = 80;
    askSize(dl, out, keys, &rows, &cols);

    var text: Text = .{ .sys = sys, .dl = dl, .file = file, .cols = cols };
    defer text.free();
    if (opened != null) {
        var fib: dos.FileInfoBlock = .{};
        if (dl.ExamineFH(file, &fib)) text.size = fib.size;
    }

    var pager: Pager = .{ .dl = dl, .text = &text, .out = out, .keys = keys, .page = rows - 1 };
    pager.drawPage(0);
    while (pager.step()) {}
    pager.clearPrompt();
    return dos.RETURN_OK;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
