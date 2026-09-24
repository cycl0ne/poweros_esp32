// SPDX-License-Identifier: MPL-2.0
//! Execute: one of the shell's built-ins, so a script runs before there is
//! a disk to load a command from. "EXECUTE file [arguments]" runs
//! a script in the shell that calls it:
//! - A script that doesn't start with a directive, run from the console,
//!   becomes cli_CurrentInput as it is.
//! - Otherwise its lines are copied to a work file, T:Command-nn-Tnn (nn the
//!   CLI number; the digit before it alternates, so a script can execute
//!   another), with the directives done and <key> replaced by the
//!   arguments, and the work file becomes cli_CurrentInput. Run from a
//!   script, the rest of that script is appended and it ends there (its work
//!   file is deleted); the shell deletes the last one (cli_CommandFile).
//! - Directives (dirch, default "."): KEY (K) template, the arguments read
//!   with ReadArgs; DEFAULT (DEF) key value; BRA, KET, DOLLAR, DOT set the
//!   characters "<", ">", "$" and ".". "<key$default>" falls back to the
//!   default, "<$$>" is the CLI number. A line starting with ";" is copied
//!   as it is.
//! - The file is looked for as given, then in S:.
//!
//! /N keys give their number and /M keys their words; "<$$>" in a .DEF
//! value goes into the value; T: is a late assign to RAM:T whose directory
//! is made when missing; no arguments is "required argument missing".

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const FileHandle = dos.FileHandle;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const workfile = dos.workfile;

pub const COMMAND_NAME = "Execute";
const TEMPLATE = "FILE/A";
const END = -1;
const MAXDEF = 500;
const MAXKEYCHARS = 21;
const MAXKEYS = 100;
/// The work file name's digit that alternates between nested scripts.
const SWITCHPOS = 11;

const Failed = error{Failed};

/// The state of one Execute.
const Global = struct {
    dl: *DosBase,
    proc: *dos.Process,
    cli: *dos.CommandLineInterface,
    subch: u8 = '<',
    busch: u8 = '>',
    defch: u8 = '$',
    dirch: u8 = '.',
    instream: ?*FileHandle = null,
    outstream: ?*FileHandle = null,
    /// The caller's Output() and Input() (the argument line).
    sys_stream: ?*FileHandle,
    par_stream: ?*FileHandle,
    keygiven: bool = false,
    defstart: usize = 0,
    newfile: [32]u8 = @splat(0),
    keyword: [80]u8 = @splat(0),
    rdargskey: [200]u8 = @splat(0),
    parameters: [MAXKEYS]usize = @splat(0),
    /// Set by .DEF: the slot is a string whatever the key's type.
    defaulted: [MAXKEYS]bool = @splat(false),
    defbuf: [MAXDEF]u8 = @splat(0),
    rda: ?*dos.RDArgs = null,

    fn getc(gv: *Global) i32 {
        return gv.dl.FGetC(gv.dl.Input());
    }

    fn ungetc(gv: *Global) void {
        _ = gv.dl.UnGetC(gv.dl.Input(), -1);
    }

    fn putc(gv: *Global, ch: i32) void {
        _ = gv.dl.FPutC(gv.dl.Output(), ch);
    }
};

pub fn run(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    const cli = dl.Cli() orelse {
        _ = dl.PrintFault(dos.ERROR_OBJECT_WRONG_TYPE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    const block = sys.AllocVec(@sizeOf(Global), exec.MEMF_CLEAR) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(block);
    const gv: *Global = @ptrCast(@alignCast(block));
    gv.* = .{
        .dl = dl,
        .proc = @fieldParentPtr("task", sys.FindTask(null).?),
        .cli = cli,
        .sys_stream = dl.Output(),
        .par_stream = dl.Input(),
    };
    const rc = execute(gv) catch dos.RETURN_ERROR;
    if (gv.rda) |r| dl.FreeArgs(r);
    _ = dl.SelectInput(gv.par_stream);
    _ = dl.SelectOutput(gv.sys_stream);
    if (rc != dos.RETURN_OK) {
        const res2 = dl.IoErr();
        if (res2 != 0) _ = dl.PrintFault(res2, null);
        _ = dl.SetIoErr(res2);
    }
    return rc;
}

fn execute(gv: *Global) Failed!i32 {
    const dl = gv.dl;
    const cli = gv.cli;
    var cfile: [80]u8 = @splat(0);
    var item = dl.ReadItem(&cfile, cfile.len, null);
    if (item > 0 and std.mem.eql(u8, span(&cfile), "?")) {
        _ = Printf(dl, "%s: ", .{@as([:0]const u8, TEMPLATE)});
        _ = dl.Flush(dl.Output());
        var ch = gv.getc();
        while (ch != '\n' and ch != END) ch = gv.getc();
        item = dl.ReadItem(&cfile, cfile.len, null);
    }
    if (item <= 0) {
        if (item != 0) return fail(gv, "Incorrect file name", .{});
        _ = dl.SetIoErr(dos.ERROR_REQUIRED_ARG_MISSING);
        return dos.RETURN_FAIL;
    }
    const name: [*:0]const u8 = @ptrCast(&cfile);
    gv.instream = dl.Open(name, dos.MODE_OLDFILE);
    if (gv.instream == null) { // then in S:
        const err = dl.IoErr();
        if (dl.Lock("S:", dos.SHARED_LOCK)) |s| {
            const old = dl.CurrentDir(s);
            gv.instream = dl.Open(name, dos.MODE_OLDFILE);
            dl.UnLock(dl.CurrentDir(old));
        }
        if (gv.instream == null) _ = dl.SetIoErr(err);
    }
    if (gv.instream == null) return fail(gv, "Can't open {s}", .{span(&cfile)});

    _ = dl.SelectInput(gv.instream);
    var ch = gv.getc();
    while (ch == '\n') ch = gv.getc();
    // No directive, from the console: the script as it is.
    if (ch != '.' and cli.current_input == cli.standard_input) {
        gv.ungetc();
        if (cli.interactive) _ = dl.CheckSignal(exec.SIGBREAKF_CTRL_D);
        cli.current_input = gv.instream;
        gv.instream = null;
        return dos.RETURN_OK;
    }

    // The work file: T:Command-0x-Tnn.
    const nested = cli.current_input != cli.standard_input;
    const t = gv.proc.task_num;
    _ = std.fmt.bufPrintZ(&gv.newfile, "T:Command-00-T{d}{d}", .{ (t / 10) % 10, t % 10 }) catch unreachable;
    const old_file: [*:0]u8 = cli.command_file orelse @constCast("");
    if (nested and std.mem.len(old_file) > SWITCHPOS) gv.newfile[SWITCHPOS] = old_file[SWITCHPOS] ^ 1;
    const work: [*:0]const u8 = @ptrCast(&gv.newfile);
    gv.outstream = workfile.open(dl, work, dos.MODE_NEWFILE);
    if (gv.outstream == null and dl.IoErr() == dos.ERROR_DELETE_PROTECTED) {
        _ = dl.SetProtection(work, 0);
        gv.outstream = dl.Open(work, dos.MODE_NEWFILE);
    }
    if (gv.outstream == null) return fail(gv, "Can't open work file \"{s}\"", .{span(&gv.newfile)});
    _ = dl.SelectOutput(gv.outstream);
    if (cli.interactive) _ = dl.CheckSignal(exec.SIGBREAKF_CTRL_D);

    while (ch != END) {
        ch = if (ch == gv.dirch) try handleDirective(gv) else try substitute(gv, ch);
    }
    _ = dl.SelectInput(gv.par_stream);
    _ = dl.Close(gv.instream);
    gv.instream = null;

    // Run from a script: the rest of it goes on in the work file.
    if (nested) {
        _ = dl.SelectInput(cli.current_input);
        while (true) {
            const c = gv.getc();
            if (c == END) break;
            gv.putc(c);
        }
        _ = dl.SelectInput(gv.par_stream);
    }
    _ = dl.SelectOutput(gv.sys_stream);
    const written = dl.Close(gv.outstream);
    gv.outstream = null;
    const newstream = if (written) dl.Open(work, dos.MODE_OLDFILE) else null;
    if (newstream == null) {
        _ = dl.DeleteFile(work);
        return fail(gv, "Can't open work file \"{s}\"", .{span(&gv.newfile)});
    }
    if (nested) {
        _ = dl.Close(cli.current_input);
        if (old_file[0] != 0 and !dl.DeleteFile(old_file)) {
            _ = dl.SetProtection(old_file, 0);
            _ = dl.DeleteFile(old_file);
        }
    }
    cli.current_input = newstream;
    if (cli.command_file) |cf| {
        const len = @min(std.mem.len(work), dos.CLI_MAX_COMMAND_FILE - 1);
        @memcpy(cf[0..len], work[0..len]);
        cf[len] = 0;
    }
    return dos.RETURN_OK;
}

/// A directive line (the dirch read): what it says done, the rest of the
/// line skipped; returns the next line's first character.
fn handleDirective(gv: *Global) Failed!i32 {
    const dl = gv.dl;
    var ch = gv.getc();
    if (ch != '\n' and ch != '\t' and ch != ' ' and ch != END) {
        gv.ungetc();
        const item = dl.ReadItem(&gv.keyword, gv.keyword.len, null);
        const c = if (item == dos.ITEM_UNQUOTED) dl.FindArg("KEY,K,DEFAULT,DEF,BRA,KET,DOLLAR,DOT", @ptrCast(&gv.keyword)) else -1;
        if (c < 0) return fail(gv, "Invalid directive", .{});
        switch (c) {
            0, 1 => { // .KEY template
                if (gv.keygiven) return fail(gv, "More than one .KEY directive", .{});
                if (dl.ReadItem(&gv.rdargskey, gv.rdargskey.len, null) <= 0) return fail(gv, "Illegal KEY directive", .{});
                _ = dl.SelectInput(gv.par_stream);
                _ = dl.SelectOutput(gv.sys_stream);
                gv.parameters = @splat(0);
                gv.rda = dl.ReadArgs(@ptrCast(&gv.rdargskey), &gv.parameters, gv.rda);
                gv.ungetc();
                _ = dl.SelectOutput(gv.outstream);
                _ = dl.SelectInput(gv.instream);
                if (gv.rda == null) return fail(gv, "Parameters unsuitable for key \"{s}\"", .{span(&gv.rdargskey)});
                gv.keygiven = true;
            },
            2, 3 => defaults: { // .DEF key value
                const got = dl.ReadItem(&gv.keyword, gv.keyword.len, null);
                if (got < 0) return fail(gv, "Illegal key", .{});
                if (got == 0) break :defaults;
                if (!gv.keygiven) return fail(gv, "Missing .KEY directive", .{});
                const keyn = dl.FindArg(@ptrCast(&gv.rdargskey), @ptrCast(&gv.keyword));
                if (keyn < 0 or keyn >= MAXKEYS or gv.parameters[@intCast(keyn)] != 0) break :defaults;
                const into = gv.defbuf[gv.defstart..];
                var value = try substReadItem(gv, into);
                if (value == -2) value = try substReadItem(gv, into); // "key = value"
                if (value <= 0) {
                    if (value != 0) return fail(gv, "Illegal data item", .{});
                    break :defaults;
                }
                gv.parameters[@intCast(keyn)] = @intFromPtr(into.ptr);
                gv.defaulted[@intCast(keyn)] = true;
                gv.defstart += std.mem.len(@as([*:0]u8, @ptrCast(into.ptr))) + 1;
            },
            4 => gv.subch = try getch(gv),
            5 => gv.busch = try getch(gv),
            6 => gv.defch = try getch(gv),
            7 => gv.dirch = try getch(gv),
            else => {},
        }
        ch = gv.getc();
    }
    while (ch != '\n' and ch != END) ch = gv.getc();
    return gv.getc();
}

/// A script line (its first character read) to the work file, with <key>
/// replaced; returns the next line's first character.
fn substitute(gv: *Global, first: i32) Failed!i32 {
    var ch = first;
    var writing = true;
    var substituting = false;
    const comline = ch != ';';
    while (ch != '\n' and ch != END) {
        if (ch == gv.subch and writing and gv.keygiven and comline) {
            ch = gv.getc();
            writing = false;
            substituting = true;
            var cliflag = false;
            if (ch == gv.defch) {
                if (gv.getc() == gv.defch) {
                    cliflag = true;
                    putNumber(gv, gv.proc.task_num);
                } else gv.ungetc();
            }
            if (!cliflag) {
                const keyn = try readKey(gv, &ch);
                if (keyn) |k| {
                    var text: [256]u8 = undefined;
                    _ = gv.dl.PutStr(valueText(gv, k, &text));
                } else writing = true; // not given: the default after defch is written
                if (ch == gv.defch) ch = gv.getc();
            }
        } else {
            if (ch == gv.busch and substituting) {
                writing = true;
                substituting = false;
            } else if (writing) {
                gv.putc(ch);
            }
            ch = gv.getc();
        }
    }
    gv.putc('\n');
    return gv.getc();
}

/// A key's name after subch (`ch` its first character, left on what ended
/// it); the key's slot if it was given (or defaulted).
fn readKey(gv: *Global, ch: *i32) Failed!?usize {
    var l: usize = 0;
    while (ch.* != gv.busch and ch.* != gv.defch and ch.* != '\n' and ch.* != END) {
        if (l >= MAXKEYCHARS) return fail(gv, "Key too long", .{});
        gv.keyword[l] = @truncate(@as(u32, @bitCast(ch.*)));
        l += 1;
        ch.* = gv.getc();
    }
    gv.keyword[l] = 0;
    const keyn = gv.dl.FindArg(@ptrCast(&gv.rdargskey), @ptrCast(&gv.keyword));
    if (keyn < 0 or keyn >= MAXKEYS or gv.parameters[@intCast(keyn)] == 0) return null;
    return @intCast(keyn);
}

const Kind = struct { number: bool = false, multi: bool = false, flag: bool = false };

/// The modifiers of the template's item `keyn` (/N, /M, /S or /T).
fn keyKind(template: []const u8, keyn: usize) Kind {
    var items = std.mem.splitScalar(u8, template, ',');
    var i: usize = 0;
    while (items.next()) |item| : (i += 1) {
        if (i != keyn) continue;
        var kind: Kind = .{};
        var j: usize = 0;
        while (j + 1 < item.len) : (j += 1) {
            if (item[j] != '/') continue;
            switch (std.ascii.toUpper(item[j + 1])) {
                'N' => kind.number = true,
                'M' => kind.multi = true,
                'S', 'T' => kind.flag = true,
                else => {},
            }
        }
        return kind;
    }
    return .{};
}

/// A given key's value as text: a switch gives its name, /N its
/// number, /M its words.
fn valueText(gv: *Global, keyn: usize, buf: *[256]u8) [*:0]const u8 {
    const slot = gv.parameters[keyn];
    if (gv.defaulted[keyn]) return @ptrFromInt(slot);
    const kind = keyKind(span(&gv.rdargskey), keyn);
    if (kind.flag or slot == @as(usize, @bitCast(@as(isize, dos.DOSTRUE)))) return @ptrCast(&gv.keyword);
    if (kind.number) return (std.fmt.bufPrintZ(buf, "{d}", .{rdargs.number(slot).?}) catch unreachable).ptr;
    if (kind.multi) {
        var n: usize = 0;
        for (rdargs.multi(slot), 0..) |word, i| {
            const w = std.mem.span(word);
            if (n + w.len + 2 > buf.len) break;
            if (i > 0) {
                buf[n] = ' ';
                n += 1;
            }
            @memcpy(buf[n..][0..w.len], w);
            n += w.len;
        }
        buf[n] = 0;
        return @ptrCast(buf);
    }
    return @ptrFromInt(slot);
}

fn putNumber(gv: *Global, n: u32) void {
    var text: [12]u8 = undefined;
    _ = gv.dl.PutStr((std.fmt.bufPrintZ(&text, "{d}", .{n}) catch unreachable).ptr);
}

/// One character of a directive: .BRA and the others. At the line's end,
/// -2 (that character then never matches).
fn getch(gv: *Global) Failed!u8 {
    const item = gv.dl.ReadItem(&gv.keyword, gv.keyword.len, null);
    if (item == 0) {
        const ch = gv.getc();
        gv.ungetc();
        if (ch == '\n' or ch == END) return @truncate(@as(u32, @bitCast(@as(i32, -2))));
    }
    if (item <= 0 or std.mem.len(@as([*:0]u8, @ptrCast(&gv.keyword))) != 1) return fail(gv, "Invalid directive argument", .{});
    return gv.keyword[0];
}

/// An item of a .DEF line into `v`, with <key>
/// replaced. -2 "=", -1 an error, 0 nothing, 1 an unquoted item, 2 a
/// quoted one.
fn substReadItem(gv: *Global, v: []u8) Failed!i32 {
    @memset(v, 0);
    var p: usize = 0;
    var quoted = false;
    var substituting = false;
    var writing = true;
    var ch = gv.getc();
    while (ch == ' ') ch = gv.getc();
    if (ch == '"') {
        quoted = true;
        ch = gv.getc();
    }
    while (ch != '\n' and ch != END) {
        if (ch == gv.subch and writing and gv.keygiven) {
            ch = gv.getc();
            substituting = true;
            var cliflag = false;
            if (ch == gv.defch) {
                if (gv.getc() == gv.defch) {
                    cliflag = true;
                    var text: [12]u8 = undefined;
                    if (!put(v, &p, std.fmt.bufPrint(&text, "{d}", .{gv.proc.task_num}) catch unreachable)) return -1;
                } else gv.ungetc();
            }
            if (!cliflag) {
                const keyn = try readKey(gv, &ch);
                if (keyn) |k| {
                    var text: [256]u8 = undefined;
                    if (!put(v, &p, std.mem.span(valueText(gv, k, &text)))) return -1;
                } else writing = true;
                if (ch == gv.defch) ch = gv.getc();
            }
        } else {
            if (ch == gv.busch and substituting) {
                writing = true;
                substituting = false;
            } else {
                if (quoted) {
                    if (ch == '"') return 2;
                    if (ch == '*') {
                        ch = gv.getc();
                        switch (std.ascii.toUpper(@truncate(@as(u32, @bitCast(ch))))) {
                            'E' => ch = 0x1B,
                            'N' => ch = '\n',
                            else => {},
                        }
                    }
                } else if (ch == ';' or ch == ' ' or ch == '=') break;
                if (writing and !put(v, &p, &.{@truncate(@as(u32, @bitCast(ch)))})) return -1;
            }
            ch = gv.getc();
        }
    }
    gv.ungetc();
    if (quoted) return -1;
    if (p == 0) {
        if (ch == '=') {
            _ = gv.getc();
            return -2;
        }
        return 0;
    }
    return 1;
}

/// Bytes into `v` at `p.*`, a NUL kept after them; false when full.
fn put(v: []u8, p: *usize, bytes: []const u8) bool {
    if (p.* + bytes.len >= v.len) return false;
    @memcpy(v[p.*..][0..bytes.len], bytes);
    p.* += bytes.len;
    return true;
}

fn span(buf: []const u8) []const u8 {
    return buf[0 .. std.mem.indexOfScalar(u8, buf, 0) orelse buf.len];
}

/// The work file deleted, the script closed,
/// "EXECUTE: text" printed, IoErr kept.
fn fail(gv: *Global, comptime fmt: []const u8, args: anytype) Failed {
    const dl = gv.dl;
    const res2 = dl.IoErr();
    _ = dl.SelectOutput(gv.sys_stream);
    _ = dl.SelectInput(gv.par_stream);
    if (gv.outstream) |o| {
        _ = dl.Close(o);
        _ = dl.DeleteFile(@ptrCast(&gv.newfile));
        gv.outstream = null;
    }
    if (gv.instream) |i| {
        _ = dl.Close(i);
        gv.instream = null;
    }
    var line: [160]u8 = undefined;
    const text = std.fmt.bufPrintZ(&line, "EXECUTE: " ++ fmt ++ "\n", args) catch "EXECUTE: ?\n";
    _ = dl.PutStr(text.ptr);
    _ = dl.SetIoErr(res2);
    return error.Failed;
}
