// SPDX-License-Identifier: MPL-2.0
//! The console handler's line editor and input queue, without devices:
//! it takes the terminal's bytes (`key`) and the program's output
//! (`write`), and answers READs (`read`); what goes to the terminal (echo,
//! redraws, output) goes to its sink.
//!
//! Cooked mode is line editing on a serial terminal: ^A/^Z start/end of line, ^X kill the line, ^B the same and
//! the history scan reset, ^K kill to the end (into the kill buffer), ^Y
//! yank, ^U delete to the start, ^W delete a word, BS delete left, ^R
//! history search (the text before the cursor as a prefix, any case), CR
//! ends a line, ^S holds what programs write until the next character
//! comes in (which is all ^Q is), Ctrl-\ ends the input; the terminal's
//! ESC [ sequences (and
//! the one-byte CSI, 0x9B): arrows, Home/End, Delete, shift-up (search).
//! History is a 2 KiB ring of lines, a line equal to the newest isn't
//! added. Ctrl-C to Ctrl-F become break signals (swallowed in cooked mode,
//! passed on in raw mode). A READ gets one line at most; the rest of it
//! stays for the next READ. Raw mode: every byte goes to the reader at
//! once, without echo or editing, and there is no hold - ^S is a byte like
//! another there.
//!
//! **Text can also be handed to a console from elsewhere** (`pushIn`), to
//! go in as though it were typed: `nextPushed` gives it out a character at
//! a time, and only while there is room for one, so a line that fills up
//! makes the rest of it wait rather than lose it. A break throws away what
//! is left of it.
//!
//! LF ends a line too (CR LF counts once), and 0x7F deletes left like BS
//! (terminals send it for Backspace; Delete is ESC [ 3 ~); other control
//! characters are dropped; output while a line is typed goes out on a line
//! of its own and the typed line is redrawn after it, so the writer never
//! waits for the line to be done; a raw READ doesn't stop at a LF; output
//! LF becomes CR LF in cooked mode, as a serial terminal needs.

const std = @import("std");
const exec = @import("sdk").exec;

/// The longest line (with room for its LF).
pub const max_line = 256;
const ready_size = 512;
/// Text pushed into the input from elsewhere, waiting to be typed in.
const pushed_size = 512;
/// The most of a prompt that is put back after other output interrupts it.
const prompt_max = 128;
const history_size = 2048;

const ESC = 0x1B;
const CSI = 0x9B;
const BEL = 0x07;

/// Where the terminal's bytes go.
pub const Sink = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, bytes: []const u8) void,
};

/// The history: lines in a ring of bytes, each ended by a 0, the oldest
/// dropped for room.
pub const History = struct {
    buf: [history_size]u8 = undefined,
    used: usize = 0,

    /// The n-th newest line (0: the newest), or null.
    pub fn entry(h: *const History, n: usize) ?[]const u8 {
        var end = h.used;
        var i: usize = 0;
        while (end > 0) : (i += 1) {
            const zero = end - 1;
            var start = zero;
            while (start > 0 and h.buf[start - 1] != 0) start -= 1;
            if (i == n) return h.buf[start..zero];
            end = start;
        }
        return null;
    }

    pub fn add(h: *History, line: []const u8) void {
        if (line.len == 0 or line.len + 1 > history_size) return;
        if (h.entry(0)) |newest| {
            if (std.mem.eql(u8, newest, line)) return;
        }
        while (h.used + line.len + 1 > history_size) {
            const first = std.mem.indexOfScalar(u8, h.buf[0..h.used], 0).? + 1;
            std.mem.copyForwards(u8, h.buf[0 .. h.used - first], h.buf[first..h.used]);
            h.used -= first;
        }
        @memcpy(h.buf[h.used..][0..line.len], line);
        h.used += line.len;
        h.buf[h.used] = 0;
        h.used += 1;
    }
};

/// Ctrl-\\: what has been typed goes to the reader, and the read after
/// it ends. A window's close gadget is the same thing said with the
/// pointer, so the handler sends this when one is used.
pub const END_OF_INPUT: u8 = 0x1C;

pub const Editor = struct {
    sink: Sink,
    raw: bool = false,

    /// Input waiting for READs, a ring.
    ready: [ready_size]u8 = undefined,
    ready_start: usize = 0,
    ready_len: usize = 0,
    /// How many LFs `ready` holds (whole lines).
    lines: usize = 0,
    /// Ctrl-\ was typed: the end comes after what `ready` holds.
    eof: bool = false,

    /// The line being typed, and the cursor in it (the terminal's cursor
    /// is always there, relative to the line's start).
    line: [max_line]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    kill: [max_line]u8 = undefined,
    kill_len: usize = 0,
    history: History = .{},
    /// The history line shown (0: the newest), null when not in it.
    scan: ?usize = null,

    esc: enum { none, esc, csi, ss3 } = .none,
    param: [8]u8 = undefined,
    param_len: usize = 0,
    intermediate: u8 = 0,
    /// The last byte was CR: a LF right after it belongs to it.
    after_cr: bool = false,
    /// Break signals typed (SIGBREAKF_CTRL_C..F), for the handler.
    breaks: u32 = 0,
    /// Ctrl-S was typed: what programs write is to stand still until the
    /// next character comes in, whatever it is. The handler is what holds
    /// the writes - the editor only knows the key was pressed.
    hold: bool = false,
    /// Text handed to this console to go in as though it were typed, and
    /// where the next character of it is.
    pushed: [pushed_size]u8 = undefined,
    pushed_start: usize = 0,
    pushed_len: usize = 0,

    out: [512]u8 = undefined,
    out_len: usize = 0,

    /// What has been written since the last newline: the prompt, as far as
    /// the terminal is concerned. When something else writes while a READ
    /// is waiting, this is put back so the line the cursor sits on still
    /// reads as a prompt.
    prompt: [prompt_max]u8 = undefined,
    prompt_len: usize = 0,
    /// A READ is waiting, so the line on the screen is one somebody is
    /// being asked to type into. The handler sets it.
    waiting: bool = false,

    /// A fresh start for the first open: no input, the node's mode. The
    /// history stays.
    pub fn reset(ed: *Editor, raw: bool) void {
        ed.raw = raw;
        ed.ready_start = 0;
        ed.ready_len = 0;
        ed.lines = 0;
        ed.eof = false;
        ed.len = 0;
        ed.cursor = 0;
        ed.scan = null;
        ed.esc = .none;
        ed.after_cr = false;
        ed.breaks = 0;
        ed.hold = false;
        ed.prompt_len = 0;
        ed.waiting = false;
    }

    // --- Output ---

    fn emit(ed: *Editor, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            if (ed.out_len == ed.out.len) ed.flush();
            const n = @min(rest.len, ed.out.len - ed.out_len);
            @memcpy(ed.out[ed.out_len..][0..n], rest[0..n]);
            ed.out_len += n;
            rest = rest[n..];
        }
    }

    /// What was emitted, to the sink.
    pub fn flush(ed: *Editor) void {
        if (ed.out_len == 0) return;
        ed.sink.write(ed.sink.ctx, ed.out[0..ed.out_len]);
        ed.out_len = 0;
    }

    fn cursorMove(ed: *Editor, n: usize, direction: u8) void {
        if (n == 0) return;
        var b: [16]u8 = undefined;
        ed.emit(std.fmt.bufPrint(&b, "\x1b[{d}{c}", .{ n, direction }) catch unreachable);
    }

    fn moveLeft(ed: *Editor, n: usize) void {
        ed.cursorMove(n, 'D');
    }

    fn moveRight(ed: *Editor, n: usize) void {
        ed.cursorMove(n, 'C');
    }

    /// The program's output. In cooked mode LF goes out as CR LF, and a
    /// line being typed is set aside: the output on a line of its own,
    /// the typed line again below it.
    pub fn write(ed: *Editor, data: []const u8) void {
        // Something is on the line the cursor sits on - a prompt, a line
        // being typed, or both - and a READ is waiting for it to be
        // answered. Whatever is written now goes below it, and the line is
        // put back underneath so the terminal still reads as a prompt.
        // Without this a background CLI's output buries the foreground
        // shell's prompt and the console looks stuck.
        // A line being typed is on the screen whether or not a READ is
        // waiting for it. A bare prompt only counts when one is, or every
        // ordinary write would bounce its own tail around.
        const held = !ed.raw and (ed.len > 0 or (ed.waiting and ed.prompt_len > 0));
        const kept = ed.prompt_len;
        if (held) {
            // The line goes off the screen rather than being left above:
            // a background CLI writing line by line would otherwise leave
            // a copy of the prompt between every one of them.
            ed.emit("\r\x1b[K");
        }
        if (ed.raw) {
            ed.emit(data);
        } else {
            var start: usize = 0;
            for (data, 0..) |b, i| {
                if (b != '\n') continue;
                ed.emit(data[start..i]);
                ed.emit("\r\n");
                start = i + 1;
            }
            ed.emit(data[start..]);
        }
        if (held) {
            if (data.len > 0 and data[data.len - 1] != '\n') ed.emit("\r\n");
            ed.emit(ed.prompt[0..kept]);
            ed.emit(ed.line[0..ed.len]);
            ed.moveLeft(ed.len - ed.cursor);
            return; // the line still reads as it did: the prompt is unchanged
        }
        ed.trackPrompt(data);
    }

    /// The tail of what was written, after the last newline in it. That is
    /// the prompt a READ will be answered under.
    fn trackPrompt(ed: *Editor, data: []const u8) void {
        var tail = data;
        var fresh = false;
        if (std.mem.lastIndexOfScalar(u8, data, '\n')) |at| {
            tail = data[at + 1 ..];
            fresh = true;
        }
        if (fresh) ed.prompt_len = 0;
        if (tail.len >= ed.prompt.len) {
            // Only the end of it can be on the line anyway.
            const cut = tail[tail.len - ed.prompt.len ..];
            @memcpy(&ed.prompt, cut);
            ed.prompt_len = ed.prompt.len;
            return;
        }
        if (ed.prompt_len + tail.len > ed.prompt.len) {
            const drop = ed.prompt_len + tail.len - ed.prompt.len;
            std.mem.copyForwards(u8, ed.prompt[0 .. ed.prompt_len - drop], ed.prompt[drop..ed.prompt_len]);
            ed.prompt_len -= drop;
        }
        @memcpy(ed.prompt[ed.prompt_len..][0..tail.len], tail);
        ed.prompt_len += tail.len;
    }

    // --- Input for READs ---

    fn push(ed: *Editor, bytes: []const u8) bool {
        if (ed.ready_len + bytes.len > ready_size) return false;
        for (bytes) |b| {
            ed.ready[(ed.ready_start + ed.ready_len) % ready_size] = b;
            ed.ready_len += 1;
            if (b == '\n') ed.lines += 1;
        }
        return true;
    }

    // --- Text pushed in from elsewhere ---

    /// Where pushed text goes: in front of what is already waiting, or
    /// behind it.
    pub const Push = enum { first, last };

    /// Text to be typed into this console by something other than a
    /// keyboard. False: it does not fit, and none of it was taken - the
    /// caller is told a number, so half of a line would be worse than
    /// none.
    pub fn pushIn(ed: *Editor, text: []const u8, at: Push) bool {
        if (text.len == 0 or ed.pushed_len + text.len > pushed_size) return false;
        if (at == .first) ed.pushed_start = (ed.pushed_start + pushed_size - text.len) % pushed_size;
        const from = if (at == .first) ed.pushed_start else (ed.pushed_start + ed.pushed_len) % pushed_size;
        for (text, 0..) |b, i| ed.pushed[(from + i) % pushed_size] = b;
        ed.pushed_len += text.len;
        return true;
    }

    /// Text is waiting to go in.
    pub fn pushedIn(ed: *const Editor) bool {
        return ed.pushed_len > 0;
    }

    /// The next character of it, if there is one and there is room for it
    /// to be typed. Null while the line is full, so pushed text waits
    /// rather than being lost - a person typing would have to wait too.
    pub fn nextPushed(ed: *Editor) ?u8 {
        if (ed.pushed_len == 0) return null;
        if (ed.raw) {
            if (ed.ready_len == ready_size) return null;
        } else if (ed.len + 1 >= max_line or ed.ready_len + ed.len + 2 > ready_size) {
            // The line being typed has to fit the queue whole, with the
            // LF that ends it.
            return null;
        }
        const c = ed.pushed[ed.pushed_start];
        ed.pushed_start = (ed.pushed_start + 1) % pushed_size;
        ed.pushed_len -= 1;
        return c;
    }

    /// Everything pushed in and not yet typed.
    pub fn dropPushed(ed: *Editor) void {
        ed.pushed_len = 0;
        ed.pushed_start = 0;
    }

    /// Whole lines waiting, as WAIT_CHAR counts them: text pushed in and
    /// not yet typed counts as one more, since it is about to become one.
    pub fn lineCount(ed: *const Editor) usize {
        return ed.lines + @intFromBool(ed.pushed_len > 0);
    }

    /// Whether a READ can be answered now (and WAIT_CHAR says yes):
    /// cooked, a whole line or the end; raw, any byte.
    pub fn readable(ed: *const Editor) bool {
        if (ed.eof) return true;
        return if (ed.raw) ed.ready_len > 0 else ed.lines > 0;
    }

    /// A READ's bytes (after `readable`): cooked, up to the end of one
    /// line (the rest stays); raw, what is there. 0 is the end.
    pub fn read(ed: *Editor, dest: []u8) usize {
        if (ed.ready_len == 0) {
            ed.eof = false;
            return 0;
        }
        var n: usize = 0;
        while (n < dest.len and ed.ready_len > 0) {
            const b = ed.ready[ed.ready_start];
            ed.ready_start = (ed.ready_start + 1) % ready_size;
            ed.ready_len -= 1;
            dest[n] = b;
            n += 1;
            if (b == '\n') {
                ed.lines -= 1;
                if (!ed.raw) break;
            }
        }
        return n;
    }

    /// SCREEN_MODE: into raw mode, what was typed so far goes to the
    /// reader as it is.
    pub fn setRaw(ed: *Editor, on: bool) void {
        if (on and !ed.raw and ed.len > 0) {
            _ = ed.push(ed.line[0..ed.len]);
            ed.len = 0;
            ed.cursor = 0;
        }
        ed.raw = on;
        ed.esc = .none;
    }

    // --- Keys ---

    /// A byte from the terminal.
    pub fn key(ed: *Editor, c: u8) void {
        // Any character at all lets held output go again - which is what
        // Ctrl-Q is, and why it needs nothing of its own. Ctrl-S sets it
        // again below.
        ed.hold = false;
        if (c >= 3 and c <= 6) {
            ed.breaks |= exec.SIGBREAKF_CTRL_C << @intCast(c - 3);
            // A break stops text that is being typed in from elsewhere,
            // and takes the part of it already on the line with it.
            if (ed.pushed_len > 0) {
                ed.dropPushed();
                if (!ed.raw) ed.replace("", 0);
            }
            if (!ed.raw) return;
        }
        if (ed.raw) {
            if (!ed.push(&.{c})) ed.emit(&.{BEL});
            return;
        }
        const after_cr = ed.after_cr;
        ed.after_cr = false;
        switch (ed.esc) {
            .esc => {
                ed.esc = switch (c) {
                    '[' => .csi,
                    'O' => .ss3,
                    else => .none,
                };
                ed.param_len = 0;
                ed.intermediate = 0;
                return;
            },
            .csi => return ed.csiByte(c),
            .ss3 => {
                ed.esc = .none;
                return ed.sequence(c, 0, 0);
            },
            .none => {},
        }
        switch (c) {
            ESC => ed.esc = .esc,
            CSI => {
                ed.esc = .csi;
                ed.param_len = 0;
                ed.intermediate = 0;
            },
            '\r' => {
                ed.commit();
                ed.after_cr = true;
            },
            '\n' => if (!after_cr) ed.commit(),
            0x08, 0x7F => if (ed.cursor > 0) ed.remove(ed.cursor - 1, ed.cursor),
            0x01 => ed.home(),
            0x1A => ed.end(),
            0x02 => {
                ed.replace("", 0);
                ed.scan = null;
            },
            0x18 => ed.replace("", 0),
            0x0B => {
                ed.kill_len = ed.len - ed.cursor;
                @memcpy(ed.kill[0..ed.kill_len], ed.line[ed.cursor..ed.len]);
                ed.remove(ed.cursor, ed.len);
            },
            0x19 => ed.insert(ed.kill[0..ed.kill_len]),
            0x15 => ed.remove(0, ed.cursor),
            0x17 => {
                var start = ed.cursor;
                while (start > 0 and ed.line[start - 1] == ' ') start -= 1;
                while (start > 0 and ed.line[start - 1] != ' ') start -= 1;
                ed.remove(start, ed.cursor);
            },
            0x12 => ed.search(),
            0x13 => ed.hold = true, // Ctrl-S: hold what is written
            // Ctrl-Q: nothing to do. Any key at all lets held output go
            // again, and this is a key like another; it is here so that it
            // is not typed into the line, which is what a person pressing
            // it means by it.
            0x11 => {},
            END_OF_INPUT => ed.endOfInput(),
            0x20...0x7E, 0xA0...0xFF => ed.insert(&.{c}),
            else => {},
        }
    }

    /// A byte of an ESC [ (or CSI) sequence.
    fn csiByte(ed: *Editor, c: u8) void {
        if (c >= 0x30 and c <= 0x3F) {
            if (ed.param_len < ed.param.len) {
                ed.param[ed.param_len] = c;
                ed.param_len += 1;
            }
            return;
        }
        if (c >= 0x20 and c <= 0x2F) {
            ed.intermediate = c;
            return;
        }
        ed.esc = .none;
        if (c < 0x40 or c > 0x7E) return; // broken off
        var numbers = [2]usize{ 0, 0 };
        var which: usize = 0;
        for (ed.param[0..ed.param_len]) |p| {
            if (p == ';') {
                which = 1;
            } else if (p >= '0' and p <= '9') {
                numbers[which] = numbers[which] *| 10 +| (p - '0');
            }
        }
        ed.sequence(c, numbers[0], numbers[1]);
    }

    fn sequence(ed: *Editor, final: u8, first: usize, modifier: usize) void {
        switch (final) {
            'A' => if (modifier == 2) ed.search() else ed.older(),
            'B' => ed.newer(),
            'C' => if (ed.cursor < ed.len) {
                ed.cursor += 1;
                ed.moveRight(1);
            },
            'D' => if (ed.cursor > 0) {
                ed.cursor -= 1;
                ed.moveLeft(1);
            },
            'H' => ed.home(),
            'F' => ed.end(),
            'T' => ed.search(),
            '~' => switch (first) {
                1, 7 => ed.home(),
                4, 8 => ed.end(),
                3 => if (ed.cursor < ed.len) ed.remove(ed.cursor, ed.cursor + 1),
                else => {},
            },
            else => {},
        }
    }

    // --- Editing ---

    fn insert(ed: *Editor, text: []const u8) void {
        if (text.len == 0) return;
        if (ed.len + text.len > max_line - 1) return ed.emit(&.{BEL});
        std.mem.copyBackwards(u8, ed.line[ed.cursor + text.len .. ed.len + text.len], ed.line[ed.cursor..ed.len]);
        @memcpy(ed.line[ed.cursor..][0..text.len], text);
        ed.len += text.len;
        ed.emit(ed.line[ed.cursor..ed.len]);
        ed.cursor += text.len;
        ed.moveLeft(ed.len - ed.cursor);
    }

    /// line[from..to] out (from is at most the cursor), the cursor at
    /// `from`, the rest redrawn.
    fn remove(ed: *Editor, from: usize, to: usize) void {
        if (from == to) return;
        ed.moveLeft(ed.cursor - from);
        std.mem.copyForwards(u8, ed.line[from .. ed.len - (to - from)], ed.line[to..ed.len]);
        ed.len -= to - from;
        ed.cursor = from;
        ed.emit(ed.line[from..ed.len]);
        ed.emit("\x1b[K");
        ed.moveLeft(ed.len - from);
    }

    /// The whole line becomes `text`, the cursor at `at`.
    fn replace(ed: *Editor, text: []const u8, at: usize) void {
        ed.moveLeft(ed.cursor);
        const n = @min(text.len, max_line - 1);
        std.mem.copyForwards(u8, ed.line[0..n], text[0..n]);
        ed.len = n;
        ed.emit(ed.line[0..n]);
        ed.emit("\x1b[K");
        ed.cursor = @min(at, n);
        ed.moveLeft(n - ed.cursor);
    }

    fn home(ed: *Editor) void {
        ed.moveLeft(ed.cursor);
        ed.cursor = 0;
    }

    fn end(ed: *Editor) void {
        ed.moveRight(ed.len - ed.cursor);
        ed.cursor = ed.len;
    }

    fn older(ed: *Editor) void {
        const next = if (ed.scan) |s| s + 1 else 0;
        const text = ed.history.entry(next) orelse return ed.emit(&.{BEL});
        ed.scan = next;
        ed.replace(text, text.len);
    }

    fn newer(ed: *Editor) void {
        const s = ed.scan orelse return ed.emit(&.{BEL});
        if (s == 0) {
            ed.scan = null;
            return ed.replace("", 0);
        }
        ed.scan = s - 1;
        const text = ed.history.entry(s - 1).?;
        ed.replace(text, text.len);
    }

    /// An older line that starts with the text before the cursor; the
    /// cursor stays after that prefix, so the next search uses it too.
    fn search(ed: *Editor) void {
        const prefix_len = ed.cursor;
        var i: usize = if (ed.scan) |s| s + 1 else 0;
        while (ed.history.entry(i)) |text| : (i += 1) {
            if (text.len >= prefix_len and std.ascii.eqlIgnoreCase(text[0..prefix_len], ed.line[0..prefix_len])) {
                ed.scan = i;
                return ed.replace(text, prefix_len);
            }
        }
        ed.emit(&.{BEL});
    }

    /// Enter: the line (and a LF) for the readers, into the history.
    fn commit(ed: *Editor) void {
        ed.moveRight(ed.len - ed.cursor);
        ed.emit("\r\n");
        ed.history.add(ed.line[0..ed.len]);
        if (ed.ready_len + ed.len + 1 > ready_size) {
            ed.emit(&.{BEL}); // no room: the line is lost
        } else {
            _ = ed.push(ed.line[0..ed.len]);
            _ = ed.push("\n");
        }
        ed.len = 0;
        ed.cursor = 0;
        ed.scan = null;
    }

    /// Ctrl-\: what was typed goes to the reader without a LF, then the end.
    fn endOfInput(ed: *Editor) void {
        ed.moveRight(ed.len - ed.cursor);
        ed.emit("\r\n");
        ed.history.add(ed.line[0..ed.len]);
        _ = ed.push(ed.line[0..ed.len]);
        ed.eof = true;
        ed.len = 0;
        ed.cursor = 0;
        ed.scan = null;
    }
};
