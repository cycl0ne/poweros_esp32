// SPDX-License-Identifier: MIT
//! Mount: a device on the list, described by a file.
//!
//!   Mount DEVICE/M,FROM/K
//!
//! A name is looked for in `HANDLERS:<name>`, a file holding one entry's
//! keywords and nothing else; failing that, in `HANDLERS:MountList`, where
//! each entry begins with the device's name and a colon and ends with a `#`
//! on a line of its own. `FROM` names a file to read instead of either.
//!
//! An entry is `Keyword = value` pairs in any order and any case. A value
//! is a number - decimal, or hexadecimal after `0x` - or a word, or a
//! string in quotes; `;` and newlines separate, `/* */` comments nest.
//!
//! ```
//! AUX1:
//!     Handler   = con-handler
//!     Device    = serial.device
//!     Unit      = 1
//!     StackSize = 16384
//!     Priority  = 5
//! #
//! ```
//!
//! What the keywords do:
//!
//! | Keyword | What it sets |
//! |---------|--------------|
//! | `Handler`, `FileSystem` | the code that serves the device. dos looks for it by the name at the end of the path among its segments, where the ROM's handlers are - con-handler, ram-handler, pipe-handler, nil-handler, flashfs-handler - and failing that loads the file, the first time the device is used: the path as written, and a bare name from `HANDLERS:`, where the handlers that are not in the ROM are (fat-handler) |
//! | `StackSize`, `Priority` | the handler process's, when it is started |
//! | `Device`, `Unit`, `Flags` | the exec device under it, which the handler is given as a FileSysStartupMsg |
//! | `Startup` | that startup as a plain number instead, for a handler that reads it as one (a console: 0 a window, 1 a raw window) |
//! | `Baud`, `Control` | the line for a handler on a serial port: its speed, and `"8N1/NONE"` - data bits, parity (N, E or O), stop bits, and the handshake (NONE, RTSCTS or XONXOFF). The handshake may be left off |
//! | `BlockSize`/`SectorSize`, `Surfaces`, `SectorsPerBlock`, `BlocksPerTrack`/`SectorsPerTrack`, `Reserved`, `PreAlloc`, `Interleave`, `LowCyl`, `HighCyl`, `Buffers`, `BufMemType`, `MaxTransfer`, `Mask`, `BootPri`, `DosType` | the medium's geometry and the file system's parameters, the DosEnvec the startup points at |
//! | `Activate`, `Mount` | 1: start the handler now rather than when the device is first used. A handler that does not start takes the device off the list again, so nothing is left mounted that cannot be used |
//!
//! `GlobVec`, `ForceLoad` and `EHandler` are read and ignored, with a line
//! saying so: they are keywords of a machine this is not - a BCPL global
//! vector, and a file system resource to load code out of - and a
//! mountlist written for one should say what it wants rather than fail. A keyword that is not in the table at all is an error, with
//! the line and column it was found at.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const filehandler = dos.filehandler;
const FileSysStartupMsg = filehandler.FileSysStartupMsg;
const DosEnvec = filehandler.DosEnvec;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Mount";
const VERSION_STRING = "\x00$VER: Mount 1.0 (20.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DEVICE/M,FROM/K";
const arg_device = 0;
const arg_from = 1;

/// Where an entry is looked for when FROM says nothing.
const handler_dir = "HANDLERS:";
const mount_list = "HANDLERS:MountList";

/// The keywords, as one string for FindArg. The order is what `Keyword`
/// below counts on.
const keywords = "SECTORSIZE=BLOCKSIZE,SURFACES,SECTORSPERBLOCK," ++
    "SECTORSPERTRACK=BLOCKSPERTRACK,RESERVED,PREALLOC,INTERLEAVE,LOWCYL," ++
    "HIGHCYL,BUFFERS,BUFMEMTYPE,MAXTRANSFER,MASK,BOOTPRI,DOSTYPE,BAUD," ++
    "CONTROL,DEVICE,UNIT,FLAGS,HANDLER,FILESYSTEM,STACKSIZE,PRIORITY," ++
    "STARTUP,ACTIVATE=MOUNT,GLOBVEC,FORCELOAD,EHANDLER";

const Keyword = enum(i32) {
    sector_size = 0,
    surfaces,
    sectors_per_block,
    sectors_per_track,
    reserved,
    pre_alloc,
    interleave,
    low_cyl,
    high_cyl,
    buffers,
    buf_mem_type,
    max_transfer,
    mask,
    boot_pri,
    dos_type,
    baud,
    control,
    device,
    unit,
    flags,
    handler,
    file_system,
    stack_size,
    priority,
    startup,
    activate,
    // Read, and nothing here to do with them.
    glob_vec,
    force_load,
    ehandler,
};

/// The longest a value or a name may be.
const max_token = 128;

const MSG_NOENTRY = "%s: no entry for %s in %s\n";
const MSG_OPEN = "%s: can't open %s\n";
const MSG_MOUNTED = "%s: %s is already mounted\n";
const MSG_NOMEM = "%s: out of memory\n";
const MSG_UNKNOWN = "%s: unknown keyword '%s' in %s, line %u column %u\n";
const MSG_EQUAL = "%s: '=' expected in %s, line %u column %u\n";
const MSG_NUMBER = "%s: a number was expected for %s in %s, line %u column %u\n";
const MSG_STRING = "%s: a name was expected for %s in %s, line %u column %u\n";
const MSG_MISSING = "%s: %s says nothing about what serves it (Handler)\n";
const MSG_IGNORED = "%s: %s ignored - this machine has no use for it\n";
const MSG_NOSTART = "%s: %s's handler did not start, so it is not mounted\n";
const MSG_NOCODE = "%s: %s names no handler - nothing in the ROM is called %s, and there is no such file\n";

/// What an entry says, before any of it becomes a node.
const Entry = struct {
    env: DosEnvec = .{},
    device: ?[*:0]u8 = null,
    unit: u32 = 0,
    flags: u32 = 0,
    handler: ?[*:0]u8 = null,
    stack_size: u32 = 0,
    priority: i32 = 5,
    /// A startup given as a plain number, for a handler that reads one.
    startup: usize = 0,
    activate: bool = false,
    /// Device, Unit or Flags were given, so the handler gets a
    /// FileSysStartupMsg rather than the number.
    on_device: bool = false,
};

// --- reading the file -------------------------------------------------------

const Kind = enum { word, string, number };

/// The file, a character at a time, with where in it each token began.
const Scanner = struct {
    dl: *DosBase,
    file: *dos.FileHandle,
    last: u8 = ' ',
    line: u32 = 1,
    column: u32 = 0,
    token: [max_token:0]u8 = @splat(0),
    len: usize = 0,
    kind: Kind = .word,
    quoted: bool = false,
    token_line: u32 = 1,
    token_column: u32 = 0,
    number: i32 = 0,

    fn getCh(s: *Scanner) u8 {
        const c = s.dl.FGetC(s.file);
        if (s.last == '\n') {
            s.line += 1;
            s.column = 0;
        }
        s.column += 1;
        s.last = if (c < 0) 0 else @intCast(c);
        return s.last;
    }

    fn put(s: *Scanner, c: u8) void {
        if (s.len < max_token) {
            s.token[s.len] = c;
            s.len += 1;
        }
    }

    /// The next token. False at the end of the file.
    fn next(s: *Scanner) bool {
        s.len = 0;
        s.quoted = false;
        var c = s.last;
        while (c == '\t' or c == ' ' or c == '\n' or c == '\r' or c == ';') {
            while (c == '\t' or c == ' ' or c == '\n' or c == '\r' or c == ';') c = s.getCh();
            // /* a comment, which may hold comments */
            if (c == '/') {
                s.token_line = s.line;
                s.token_column = s.column;
                c = s.getCh();
                if (c == '*') {
                    var deep: u32 = 1;
                    var before: u8 = ' ';
                    while (deep != 0 and c != 0) {
                        c = s.getCh();
                        if (c == '/' and before == '*') {
                            deep -= 1;
                            before = ' ';
                        } else if (c == '*' and before == '/') {
                            deep += 1;
                            before = ' ';
                        } else before = c;
                    }
                    c = s.getCh();
                } else {
                    s.put('/');
                }
            }
        }
        if (s.len == 0) {
            s.token_line = s.line;
            s.token_column = s.column;
        }
        if (c == '"') {
            c = s.getCh();
            while (c != '"' and c != '\n' and c != 0) {
                s.put(c);
                c = s.getCh();
            }
            if (c == '"') {
                _ = s.getCh();
                s.quoted = true;
            }
            s.kind = .string;
        } else if (c == '=') {
            s.put('=');
            _ = s.getCh();
            s.kind = .string;
        } else {
            while (c != '\t' and c != ' ' and c != '\n' and c != '\r' and c != ';' and c != '=' and c != 0) {
                s.put(c);
                c = s.getCh();
            }
            s.kind = if (s.len > 0 and s.asNumber()) .number else .word;
        }
        s.token[s.len] = 0;
        return s.len > 0 or s.quoted;
    }

    /// Whether the token is a number, and what it is. Decimal, or
    /// hexadecimal after `0x`, with a sign either way.
    fn asNumber(s: *Scanner) bool {
        if (s.quoted) return false;
        var i: usize = 0;
        var negate = false;
        if (s.token[0] == '-') {
            negate = true;
            i = 1;
        }
        var base: u32 = 10;
        if (s.token[i] == '0' and (s.token[i + 1] == 'x' or s.token[i + 1] == 'X')) {
            base = 16;
            i += 2;
        }
        var value: u32 = 0;
        var digits: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s.token[i];
            const d: u32 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => if (base == 16) c - 'a' + 10 else return false,
                'A'...'F' => if (base == 16) c - 'A' + 10 else return false,
                else => return false,
            };
            value = value *% base +% d;
            digits += 1;
        }
        if (digits == 0) return false;
        s.number = @bitCast(value);
        if (negate) s.number = -s.number;
        return true;
    }
};

/// The words a handshake is written with, and the letter each becomes.
const handshakes = [_]struct { name: []const u8, letter: u8 }{
    .{ .name = "NONE", .letter = 'N' },
    .{ .name = "RTSCTS", .letter = 'R' },
    .{ .name = "7WIRE", .letter = 'R' },
    .{ .name = "XONXOFF", .letter = 'X' },
};

/// `"8N1"`, or `"8N1/NONE"` and its like: the data bits, the parity (N, E
/// or O), the stop bits, and after the slash how the two ends hold each
/// other back. Into de_Control's four bytes; null if it does not read as
/// one.
fn parseControl(text: [*:0]const u8, len: usize) ?u32 {
    if (len < 3) return null;
    const data = text[0];
    const parity = upper(text[1]);
    const stop = text[2];
    if (data < '5' or data > '9') return null;
    if (parity != 'N' and parity != 'E' and parity != 'O') return null;
    if (stop != '1' and stop != '2') return null;
    var hand: u8 = 0;
    if (len > 3) {
        if (text[3] != '/') return null;
        const rest = len - 4;
        for (handshakes) |h| {
            if (rest != h.name.len) continue;
            var same = true;
            for (h.name, 0..) |c, i| {
                if (upper(text[4 + i]) != c) same = false;
            }
            if (same) hand = h.letter;
        }
        if (hand == 0) return null;
    }
    return filehandler.controlWord(data - '0', parity, stop - '0', hand);
}

/// A name without the path in front of it: what `HANDLERS:con-handler`
/// and `L:Aux-Handler` are called.
/// Whether the handler's file is there, where dos will look for it: the
/// path as written, and a bare name in HANDLERS:.
fn handlerFile(dl: *DosBase, handler: [*:0]const u8, code: [*:0]const u8) bool {
    var path: [max_token + 16:0]u8 = @splat(0);
    var at: usize = 0;
    if (code == handler) {
        for ("HANDLERS:") |char| {
            path[at] = char;
            at += 1;
        }
    }
    var from: usize = 0;
    while (handler[from] != 0 and at < max_token + 15) : (from += 1) {
        path[at] = handler[from];
        at += 1;
    }
    const lock = dl.Lock(&path, dos.SHARED_LOCK) orelse return false;
    dl.UnLock(lock);
    return true;
}

fn lastPart(name: [*:0]const u8) [*:0]const u8 {
    var start: usize = 0;
    var i: usize = 0;
    while (name[i] != 0) : (i += 1) {
        if (name[i] == ':' or name[i] == '/') start = i + 1;
    }
    return name + start;
}

fn upper(c: u8) u8 {
    return switch (c) {
        'a'...'z', 0xE0...0xF6, 0xF8...0xFE => c - 0x20,
        else => c,
    };
}

/// The same name, whatever case either is written in (Latin-1, as
/// utility.library's Stricmp reads it).
fn sameName(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (true) : (i += 1) {
        const x = upper(a[i]);
        if (x != upper(b[i])) return false;
        if (x == 0) return true;
    }
}

/// A copy of the token, for a node to keep.
fn keepToken(sys: *ExecBase, s: *const Scanner) ?[*:0]u8 {
    const block = sys.AllocVec(s.len + 1, exec.MEMF_CLEAR) orelse return null;
    const text: [*]u8 = @ptrCast(block);
    for (0..s.len) |i| text[i] = s.token[i];
    return @ptrCast(text);
}

// --- what a keyword does ----------------------------------------------------

const Problem = enum { none, memory, number, name, unknown };

fn keywordValue(sys: *ExecBase, dl: *DosBase, entry: *Entry, which: Keyword, s: *Scanner) Problem {
    const number: u32 = @bitCast(s.number);
    // Everything but a handful wants a number.
    switch (which) {
        .device, .handler, .file_system, .control, .ehandler => {},
        .startup => {},
        else => if (s.kind != .number) return .number,
    }
    switch (which) {
        .sector_size => entry.env.size_block = number,
        .surfaces => entry.env.surfaces = number,
        .sectors_per_block => entry.env.sector_per_block = number,
        .sectors_per_track => entry.env.blocks_per_track = number,
        .reserved => entry.env.reserved = number,
        .pre_alloc => entry.env.pre_alloc = number,
        .interleave => entry.env.interleave = number,
        .low_cyl => entry.env.low_cyl = number,
        .high_cyl => entry.env.high_cyl = number,
        .buffers => entry.env.num_buffers = number,
        .buf_mem_type => entry.env.buf_mem_type = number,
        .max_transfer => entry.env.max_transfer = number,
        .mask => entry.env.mask = number,
        .boot_pri => entry.env.boot_pri = s.number,
        .dos_type => entry.env.dos_type = number,
        .baud => {
            entry.env.baud = number;
            entry.on_device = true;
        },
        .control => {
            // "8N1": the data bits, the parity and the stop bits. A plain
            // number is the word itself, for whoever would rather say it
            // that way.
            entry.env.control = if (s.kind == .number) number else parseControl(&s.token, s.len) orelse return .name;
            entry.on_device = true;
        },
        .device => {
            if (s.kind == .number) return .name;
            entry.device = keepToken(sys, s) orelse return .memory;
            entry.on_device = true;
        },
        .unit => {
            entry.unit = number;
            entry.on_device = true;
        },
        .flags => {
            entry.flags = number;
            entry.on_device = true;
        },
        .handler, .file_system => {
            if (s.kind == .number) return .name;
            entry.handler = keepToken(sys, s) orelse return .memory;
        },
        .stack_size => entry.stack_size = number,
        .priority => entry.priority = s.number,
        .startup => {
            // A number is what a handler that reads its startup as one
            // wants; a name has nothing here to mean.
            if (s.kind != .number) return .number;
            entry.startup = number;
        },
        .activate => entry.activate = number != 0,
        .glob_vec, .force_load, .ehandler => {
            _ = Printf(dl, MSG_IGNORED, .{ COMMAND_NAME, @as([*:0]const u8, &s.token) });
        },
    }
    return .none;
}

// --- the node ---------------------------------------------------------------

/// The entry as a device on the list. The startup and its environment are
/// the node's from now on, as the node is the system's.
fn addNode(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8, entry: *const Entry) Problem {
    // A device's name is written in capitals on the list, whatever case it
    // was mounted in, so every entry on it reads the same way.
    var upper_name: [max_token:0]u8 = @splat(0);
    var i: usize = 0;
    while (name[i] != 0 and i < max_token - 1) : (i += 1) upper_name[i] = upper(name[i]);
    upper_name[i] = 0;
    const node = dl.MakeDosEntry(&upper_name, dos.DLT_DEVICE) orelse return .memory;
    // The name dos will look up, which for a handler written as a file is
    // the file's own name without the path.
    node.misc.handler.handler = if (entry.handler) |h| lastPart(h) else null;
    node.misc.handler.stack_size = entry.stack_size;
    node.misc.handler.priority = entry.priority;
    node.misc.handler.startup = entry.startup;
    if (entry.on_device) {
        const startup_block = sys.AllocVec(@sizeOf(FileSysStartupMsg), exec.MEMF_CLEAR) orelse {
            dl.FreeDosEntry(node);
            return .memory;
        };
        const env_block = sys.AllocVec(@sizeOf(DosEnvec), exec.MEMF_CLEAR) orelse {
            sys.FreeVec(startup_block);
            dl.FreeDosEntry(node);
            return .memory;
        };
        const env: *DosEnvec = @ptrCast(@alignCast(env_block));
        env.* = entry.env;
        const startup: *FileSysStartupMsg = @ptrCast(@alignCast(startup_block));
        startup.* = .{
            .unit = entry.unit,
            .device = entry.device,
            .environ = env,
            .flags = entry.flags,
        };
        node.misc.handler.startup = @intFromPtr(startup);
    }
    if (!dl.AddDosEntry(node)) {
        dl.FreeDosEntry(node);
        return .unknown; // taken: already mounted
    }
    return .none;
}

/// The node addNode made taken off the list again and given back, with
/// what it was given: the startup message and environment, and the
/// handler's and device's names.
///
/// The handler that refused to start may still be ending, and until it
/// has, dos is counting it on the node (`users`). So the node goes only
/// once nothing runs its handler any more; a handler that has not ended
/// after a second is left with its node rather than have that taken from
/// under it.
fn unmount(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8, entry: *const Entry) void {
    var upper_name: [max_token:0]u8 = @splat(0);
    var i: usize = 0;
    while (name[i] != 0 and i < max_token - 1) : (i += 1) upper_name[i] = upper(name[i]);
    const flags = dos.LDF_DEVICES | dos.LDF_WRITE;
    var waited: u32 = 0;
    while (true) : (waited += 1) {
        const list = dl.LockDosList(flags) orelse return;
        const node = dl.FindDosEntry(list, &upper_name, dos.LDF_DEVICES) orelse {
            dl.UnLockDosList(flags);
            return;
        };
        sys.Forbid();
        const running = node.task != null or node.misc.handler.users != 0;
        sys.Permit();
        if (!running) {
            const removed = dl.RemDosEntry(node);
            dl.UnLockDosList(flags);
            if (!removed) return;
            if (entry.on_device and node.misc.handler.startup != 0) {
                const startup: *FileSysStartupMsg = @ptrFromInt(node.misc.handler.startup);
                if (startup.environ) |env| sys.FreeVec(@constCast(env));
                sys.FreeVec(startup);
            }
            if (entry.handler) |handler| sys.FreeVec(handler);
            if (entry.device) |device| sys.FreeVec(device);
            dl.FreeDosEntry(node);
            return;
        }
        dl.UnLockDosList(flags);
        if (waited == 50) return;
        dl.Delay(1);
    }
}

// --- one entry --------------------------------------------------------------

const Scan = enum { device, keyword, equal, argument, done };

/// The entry for `name` out of `file`. `named` says the file holds a whole
/// mountlist, where an entry begins with the device's name and a colon;
/// without it the file is one entry's keywords and nothing else.
fn mountOne(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8, file: [*:0]const u8, named: bool, quiet: bool) i32 {
    const fh = dl.Open(file, dos.MODE_OLDFILE) orelse {
        if (!quiet) _ = Printf(dl, MSG_OPEN, .{ COMMAND_NAME, file });
        return dos.RETURN_FAIL;
    };
    defer _ = dl.Close(fh);

    var wanted: [max_token:0]u8 = @splat(0);
    var n: usize = 0;
    while (name[n] != 0 and n < max_token - 1) : (n += 1) wanted[n] = name[n];
    wanted[n] = ':';
    wanted[n + 1] = 0;

    var s: Scanner = .{ .dl = dl, .file = fh };
    var entry: Entry = .{};
    var state: Scan = if (named) .device else .keyword;
    var found = !named;
    var which: Keyword = .device;
    var trouble: Problem = .none;

    while (trouble == .none and state != .done and s.next()) {
        switch (state) {
            .device => {
                if (sameName(&s.token, &wanted)) found = true;
                state = .keyword;
            },
            .keyword => {
                if (s.token[0] == '#' and s.len == 1) {
                    state = if (found) .done else .device;
                    continue;
                }
                if (!found) continue;
                const slot = dl.FindArg(keywords, &s.token);
                if (slot < 0) {
                    trouble = .unknown;
                    continue;
                }
                which = @enumFromInt(slot);
                state = .equal;
            },
            .equal => {
                if (s.token[0] != '=' or s.len != 1) {
                    _ = Printf(dl, MSG_EQUAL, .{ COMMAND_NAME, file, s.token_line, s.token_column });
                    return dos.RETURN_FAIL;
                }
                state = .argument;
            },
            .argument => {
                if (found) trouble = keywordValue(sys, dl, &entry, which, &s);
                state = .keyword;
            },
            .done => {},
        }
    }

    switch (trouble) {
        .none => {},
        .memory => {
            _ = Printf(dl, MSG_NOMEM, .{COMMAND_NAME});
            return dos.RETURN_FAIL;
        },
        .number => {
            _ = Printf(dl, MSG_NUMBER, .{ COMMAND_NAME, @as([*:0]const u8, &s.token), file, s.token_line, s.token_column });
            return dos.RETURN_FAIL;
        },
        .name => {
            _ = Printf(dl, MSG_STRING, .{ COMMAND_NAME, @as([*:0]const u8, &s.token), file, s.token_line, s.token_column });
            return dos.RETURN_FAIL;
        },
        .unknown => {
            _ = Printf(dl, MSG_UNKNOWN, .{ COMMAND_NAME, @as([*:0]const u8, &s.token), file, s.token_line, s.token_column });
            return dos.RETURN_FAIL;
        },
    }

    if (!found) {
        if (!quiet) _ = Printf(dl, MSG_NOENTRY, .{ COMMAND_NAME, name, file });
        return dos.RETURN_FAIL;
    }
    const handler = entry.handler orelse {
        _ = Printf(dl, MSG_MISSING, .{ COMMAND_NAME, name });
        return dos.RETURN_FAIL;
    };
    // dos starts a handler by looking the name at the end of its path up
    // among the segments, where the ROM's handlers are, and failing that
    // by loading the file - the path as written, or a bare name from
    // HANDLERS:. It loads it only when the device is first used, so what
    // is in neither place is said here and now, rather than at the first
    // Open, where the reason would be a long way from the cause.
    const code = lastPart(handler);
    const in_rom = blk: {
        _ = dl.LockSegmentList(false);
        defer dl.UnLockSegmentList();
        break :blk dl.FindSegment(code, null, true) != null;
    };
    if (!in_rom and !handlerFile(dl, handler, code)) {
        _ = Printf(dl, MSG_NOCODE, .{ COMMAND_NAME, handler, code });
        return dos.RETURN_FAIL;
    }

    switch (addNode(sys, dl, name, &entry)) {
        .none => {},
        .memory => {
            _ = Printf(dl, MSG_NOMEM, .{COMMAND_NAME});
            return dos.RETURN_FAIL;
        },
        else => {
            _ = Printf(dl, MSG_MOUNTED, .{ COMMAND_NAME, name });
            return dos.RETURN_FAIL;
        },
    }

    // Activate: the handler starts now rather than when the device is
    // first used, which is what asking dos for its port does.
    if (entry.activate) {
        var with_colon: [max_token + 2:0]u8 = @splat(0);
        var i: usize = 0;
        while (name[i] != 0 and i < max_token) : (i += 1) with_colon[i] = name[i];
        with_colon[i] = ':';
        if (dl.GetDeviceProc(&with_colon, null)) |dp| {
            dl.FreeDeviceProc(dp);
        } else {
            // A device whose handler will not start is not left on the
            // list: the node goes again, and so does what it was given.
            // The entry can be mounted again once the handler can start.
            const reason = dl.IoErr();
            unmount(sys, dl, name, &entry);
            _ = Printf(dl, MSG_NOSTART, .{ COMMAND_NAME, name });
            _ = dl.SetIoErr(reason);
            return dos.RETURN_FAIL;
        }
    }
    return dos.RETURN_OK;
}

/// A name, without its colon, mounted from wherever it is described.
fn mount(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8, from: ?[*:0]const u8) i32 {
    if (from) |file| return mountOne(sys, dl, name, file, true, false);

    // Its own file first, then the entry of that name in the mountlist.
    var path: [max_token + handler_dir.len:0]u8 = @splat(0);
    for (handler_dir, 0..) |c, i| path[i] = c;
    var n: usize = handler_dir.len;
    var i: usize = 0;
    while (name[i] != 0 and n < path.len - 1) : (i += 1) {
        path[n] = name[i];
        n += 1;
    }
    path[n] = 0;
    if (dl.Lock(&path, dos.SHARED_LOCK)) |lock| {
        dl.UnLock(lock);
        return mountOne(sys, dl, name, &path, false, false);
    }
    return mountOne(sys, dl, name, mount_list, true, false);
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const names = rdargs.multi(argv[arg_device]);
    if (names.len == 0) {
        _ = dl.PrintFault(dos.ERROR_REQUIRED_ARG_MISSING, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    const from = rdargs.string(argv[arg_from]);

    var worst: i32 = dos.RETURN_OK;
    for (names) |name| {
        // A colon at the end is how a device is written; the list keeps
        // the name without it.
        var plain: [max_token:0]u8 = @splat(0);
        var n: usize = 0;
        while (name[n] != 0 and n < max_token - 1) : (n += 1) plain[n] = name[n];
        if (n > 0 and plain[n - 1] == ':') n -= 1;
        plain[n] = 0;
        const rc = mount(sys, dl, &plain, from);
        if (rc > worst) worst = rc;
    }
    return worst;
}
