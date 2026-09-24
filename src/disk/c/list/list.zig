// SPDX-License-Identifier: MIT
//! List: what is in a directory, one entry to a line with its size, its bits,
//! its date and its comment. Built against the SDK only.
//!
//!   List DIR/M,P=PAT/K,KEYS/S,DATES/S,NODATES/S,TO/K,SUB/K,SINCE/K,
//!        UPTO/K,QUICK/S,BLOCK/S,NOHEAD/S,FILES/S,DIRS/S,LFORMAT/K,ALL/S
//!
//!   List                       the current directory
//!   List DH0:C ALL             everything below it, directory by directory
//!   List PAT #?.info           only what the pattern matches
//!   List SUB hello             only names with "hello" in them
//!   List SINCE Yesterday       only what changed since then
//!   List QUICK                 names alone
//!   List LFORMAT "%s%s"        each entry as path and name, nothing else
//!
//! The line is built once, before the walk, as a RawDoFmt format string
//! (`lformat`) and a string of one-letter codes (`lorder`) that says which
//! value goes in each slot; every value is passed as a string, numbers
//! included, which is why a user's LFORMAT can put them in any order.
//!
//! **LFORMAT** takes these letters, in either case:
//!
//!   %A  the protection bits ("hsparwed", a '-' where a bit is off)
//!   %B  the size in blocks ("Dir" for a directory, "empty" for a size of 0)
//!   %C  the comment
//!   %D  the date
//!   %E  the part of the name after the last '.'
//!   %F  the full path of the directory, with its separator
//!   %K  the handler's key for the entry
//!   %L  the size in bytes ("Dir", "empty" as %B)
//!   %M  the name without that extension
//!   %N  the name
//!   %P  the path of the directory as it was walked to, with its separator
//!   %S  the name, or the path then the name - see below
//!   %T  the time
//!
//! `%S` is the old form and depends on how many there are in the string:
//! one is the name; two make the first the path and the second the name;
//! four make the first and third paths and the second and fourth names. So
//! `LFORMAT "copy %s%s to ram:"` writes a line that copies each file.
//! Width and precision (`%-20s`, `%.3s`) work as RawDoFmt has them.
//! Anything else after a `%` is printed as it stands.
//!
//! With LFORMAT there are no headers, no totals and no blank lines: the
//! output is meant to be fed to something.
//!
//! - **Dates.** dos.library's DateToStr writes the year with its century
//!   ("16-Sep-2026").
//! - **CompareDates** answers the way round its name reads (negative when
//!   the first date is the earlier), and SINCE and UPTO compare that way.
//! - **A `%S` with a width counts.** The count of `%S`s skips the width
//!   first, so `LFORMAT "%-20s %s"` is a path and a name, not the name
//!   twice.
//! - There is no `DATES`/`NODATES` difference in what is *read*, only in
//!   what is printed: NODATES drops the two date columns and DATES puts
//!   them back on a QUICK listing.
//! - The recursion is a FIFO of directory names, so ALL costs one
//!   allocation per directory and no stack.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "List";
const VERSION_STRING = "\x00$VER: List 1.0 (16.9.2026)\r\n";

const template = "DIR/M,P=PAT/K,KEYS/S,DATES/S,NODATES/S,TO/K,SUB/K,SINCE/K," ++
    "UPTO/K,QUICK/S,BLOCK/S,NOHEAD/S,FILES/S,DIRS/S,LFORMAT/K,ALL/S";
const arg_dir = 0;
const arg_pat = 1;
const arg_keys = 2;
const arg_dates = 3;
const arg_nodates = 4;
const arg_to = 5;
const arg_sub = 6;
const arg_since = 7;
const arg_upto = 8;
const arg_quick = 9;
const arg_block = 10;
const arg_nohead = 11;
const arg_files = 12;
const arg_dirs = 13;
const arg_lformat = 14;
const arg_all = 15;
const arg_count = 16;

const MSG_ARGS_EXCL = "'DATES' and 'NODATES' are mutually exclusive\n";
const MSG_CANT_OPEN = "*** Can't open %s - ";
const MSG_INVALID_SINCE_UPTO = "*** Invalid 'UPTO' or 'SINCE' parameter - ignored\n";
const MSG_DIR = "Directory \"%s\" ";
const MSG_DIR_EMPTY = "is empty\n";
const MSG_DIR_ON = "on %s %s\n";
const MSG_DIR_TYPE = "Dir";
const MSG_NO_INFO = "No information for \"%s\"";
const MSG_EMPTY = "empty";
const MSG_TOTAL = "\nTOTAL: ";
const MSG_MANY_FILES = "files";
const MSG_ONE_FILE = "file";
const MSG_MANY_DIRS = "directories";
const MSG_ONE_DIR = "directory";
const MSG_MANY_BLOCKS = "blocks";
const MSG_ONE_BLOCK = "block";
const MSG_PROTBITS = "hsparwed";
const MSG_CANT_LIST = "\" cannot be listed: not a FileSystem device\n";
const MSG_INVALID_DS = "<invalid>";

/// The length of every path buffer it keeps.
const max_path = 256;
/// What the built-in format needs when there is no
/// LFORMAT to size the workspace from.
const min_buffer = 32;
/// How many bytes a number written out can take.
const number_size = 24;

/// A directory kept for the ALL option, to be walked when the ones named
/// on the command line are done.
const DirNode = extern struct {
    next: ?*DirNode = null,
    name: [max_path:0]u8 = @splat(0),
};

const Anchor = extern struct {
    ap: dos.AnchorPath = .{},
    buf: [max_path]u8 = @splat(0),
};

/// What the walk and the main routine share. It is
/// one allocation because a command's stack is 8 KiB and this is most of
/// that on its own.
const Run = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ub: *UtilityBase,

    pat: ?[*:0]const u8,
    sub: ?[*:0]const u8,
    since: ?[*:0]const u8,
    upto: ?[*:0]const u8,
    lformat: ?[*:0]const u8,
    keys: bool,
    dates: bool,
    nodates: bool,
    quick: bool,
    block: bool,
    nohead: bool,
    files: bool,
    dirs: bool,
    all: bool,

    /// The line's RawDoFmt format, and one code letter per slot in it.
    format: [*:0]u8,
    order: [*:0]u8,
    order_len: usize,
    /// The values the format is printed with, all of them strings.
    fields: [*]usize,
    /// What goes in front of a comment: "\n: " on a full listing, nothing
    /// under LFORMAT.
    comdef: [4:0]u8 = @splat(0),

    dircount: u32 = 0,
    filecount: u32 = 0,
    // Blocks are what the handler counts them in, which is 64-bit here.
    numblocks: u64 align(4) = 0,
    totaldirs: u32 = 0,
    totalfiles: u32 = 0,
    totalblocks: u64 align(4) = 0,
    /// Something has been printed, so the next header wants a blank line
    /// before it.
    notfirst: bool = false,
    rc: i32 = dos.RETURN_OK,

    now: dos.DateStamp = .{},
    since_stamp: dos.DateStamp = .{},
    upto_stamp: dos.DateStamp = .{},
    dow: [dos.LEN_DATSTRING:0]u8 = @splat(0),
    date: [dos.LEN_DATSTRING:0]u8 = @splat(0),
    time: [dos.LEN_DATSTRING:0]u8 = @splat(0),

    /// PAT and SUB, as utility.library's tokens.
    patbuf: [max_path * 2]u8 = @splat(0),
    subbuf: [max_path * 2]u8 = @splat(0),

    /// The directories ALL still has to walk, oldest first.
    dhead: ?*DirNode = null,

    /// Scratch for one entry, too big for a stack frame.
    namebuf: [max_path:0]u8 = @splat(0),
    dirbuf: [max_path:0]u8 = @splat(0),
    fulldir: [max_path:0]u8 = @splat(0),
    combuf: [max_path:0]u8 = @splat(0),
    minusbuf: [max_path:0]u8 = @splat(0),
    extbuf: [max_path:0]u8 = @splat(0),
    blkbuf: [number_size:0]u8 = @splat(0),
    keybuf: [number_size:0]u8 = @splat(0),
    lenbuf: [number_size:0]u8 = @splat(0),
    protbits: [8:0]u8 = @splat(0),
    curbuf: [max_path:0]u8 = @splat(0),
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    // Version 1: pattern matching lives in utility.library.
    const ulib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse {
        _ = dl.PrintFault(dos.ERROR_INVALID_RESIDENT_LIBRARY, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(ulib);
    const ub: *UtilityBase = @ptrCast(ulib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    if (argv[arg_dates] != 0 and argv[arg_nodates] != 0) {
        _ = dl.PutStr(MSG_ARGS_EXCL);
        return dos.RETURN_FAIL;
    }

    const block = sys.AllocVec(@sizeOf(Run), exec.MEMF_CLEAR) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(block);
    const run: *Run = @ptrCast(@alignCast(block));
    run.* = .{
        .sys = sys,
        .dl = dl,
        .ub = ub,
        .pat = rdargs.string(argv[arg_pat]),
        .sub = rdargs.string(argv[arg_sub]),
        .since = rdargs.string(argv[arg_since]),
        .upto = rdargs.string(argv[arg_upto]),
        .lformat = rdargs.string(argv[arg_lformat]),
        .keys = argv[arg_keys] != 0,
        .dates = argv[arg_dates] != 0,
        .nodates = argv[arg_nodates] != 0,
        .quick = argv[arg_quick] != 0,
        .block = argv[arg_block] != 0,
        .nohead = argv[arg_nohead] != 0,
        .files = argv[arg_files] != 0,
        .dirs = argv[arg_dirs] != 0,
        .all = argv[arg_all] != 0,
        .format = undefined,
        .order = undefined,
        .order_len = 0,
        .fields = undefined,
    };

    // The workspace is sized from the LFORMAT string: a '%X' can only
    // grow to '%%X', so twice its length and a NUL is always enough.
    const source_len = if (run.lformat) |f| length(f) else min_buffer;
    const format_bytes = source_len * 2 + 2;
    const order_bytes = source_len + 2;
    const work = sys.AllocVec(format_bytes + order_bytes, exec.MEMF_CLEAR) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(work);
    const bytes: [*]u8 = @ptrCast(work);
    run.format = @ptrCast(bytes);
    run.order = @ptrCast(bytes + format_bytes);

    buildFormat(run);

    const fields = sys.AllocVec(@max(run.order_len, 1) * @sizeOf(usize), exec.MEMF_CLEAR) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(fields);
    run.fields = @ptrCast(@alignCast(fields));

    // TO sends everything somewhere else, the whole run of it.
    var to_file: ?*dos.FileHandle = null;
    var old_output: ?*dos.FileHandle = null;
    if (rdargs.string(argv[arg_to])) |name| {
        to_file = dl.Open(name, dos.MODE_NEWFILE) orelse {
            _ = Printf(dl, MSG_CANT_OPEN, .{name});
            _ = dl.PrintFault(dl.IoErr(), null);
            return dos.RETURN_FAIL;
        };
        old_output = dl.SelectOutput(to_file);
    }
    defer if (to_file) |file| {
        _ = dl.SelectOutput(old_output);
        _ = dl.Close(file);
    };

    _ = dl.DateStamp(&run.now);
    readSince(run);
    readUpto(run);

    // PAT and SUB are one pattern for the whole run; SUB is PAT with "#?"
    // around it, which is what makes it a substring match.
    if (run.pat) |pattern| {
        _ = ub.ParsePatternNoCase(pattern, &run.patbuf, run.patbuf.len);
    } else if (run.sub) |text| {
        var wrapped: [max_path:0]u8 = @splat(0);
        var at: usize = 0;
        wrapped[at] = '#';
        at += 1;
        wrapped[at] = '?';
        at += 1;
        var i: usize = 0;
        while (text[i] != 0 and at + 3 < wrapped.len) : (i += 1) {
            wrapped[at] = text[i];
            at += 1;
        }
        wrapped[at] = '#';
        at += 1;
        wrapped[at] = '?';
        _ = ub.ParsePatternNoCase(@ptrCast(&wrapped), &run.subbuf, run.subbuf.len);
    }

    const anchor_block = sys.AllocVec(@sizeOf(Anchor), exec.MEMF_CLEAR) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(anchor_block);
    const anchor: *Anchor = @ptrCast(@alignCast(anchor_block));

    // Every DIR given, and then every directory ALL collected on the way.
    // With no DIR at all there is still one name to list: "", the current
    // directory, from a one-entry array kept for exactly this.
    const nothing = [_][*:0]const u8{""};
    const asked = rdargs.multi(argv[arg_dir]);
    const given = if (asked.len == 0) nothing[0..] else asked;
    var next: usize = 0;
    while (next < given.len or run.dhead != null) {
        if (run.dhead) |node| {
            copyZ(&run.curbuf, @ptrCast(&node.name));
            run.dhead = node.next;
            sys.FreeVec(node);
        } else {
            run.curbuf[0] = 0;
            _ = dl.AddPart(@ptrCast(&run.curbuf), given[next], run.curbuf.len);
            next += 1;
        }
        if (listDir(run, anchor) > dos.RETURN_WARN) break;
        if (run.rc != dos.RETURN_OK) break;
    }
    // Whatever is left of the queue when it stopped early.
    while (run.dhead) |node| {
        run.dhead = node.next;
        sys.FreeVec(node);
    }

    if (run.lformat == null and !run.nohead and run.all and run.totalfiles + run.totaldirs != 0) {
        _ = dl.PutStr(MSG_TOTAL);
        if (!run.dirs and run.totalfiles != 0) {
            _ = Printf(dl, "%d %s - ", .{ run.totalfiles, plural(run.totalfiles, MSG_ONE_FILE, MSG_MANY_FILES) });
        }
        if (!run.files and run.totaldirs != 0) {
            _ = Printf(dl, "%d %s - ", .{ run.totaldirs, plural(run.totaldirs, MSG_ONE_DIR, MSG_MANY_DIRS) });
        }
        _ = Printf(dl, "%ld %s used\n", .{ run.totalblocks, plural64(run.totalblocks, MSG_ONE_BLOCK, MSG_MANY_BLOCKS) });
    }
    _ = dl.Flush(dl.Output());
    return run.rc;
}

// --- the line's shape -----------------------------------------------------

/// The format string and the order of the values
/// in it, built once, either from LFORMAT or from the switches.
fn buildFormat(run: *Run) void {
    var out: Writer = .{ .into = run.format };
    var order: Writer = .{ .into = run.order };

    if (run.lformat) |source| {
        // How many `%S`s there are decides what each of them means.
        var total: u32 = 0;
        var i: usize = 0;
        while (source[i] != 0) : (i += 1) {
            if (source[i] != '%') continue;
            var j = i + 1;
            while (isWidth(source[j])) j += 1;
            if (upper(source[j]) == 'S') total += 1;
        }

        var seen: u32 = 0;
        i = 0;
        while (source[i] != 0) {
            if (source[i] != '%') {
                out.put(source[i]);
                i += 1;
                continue;
            }
            out.put('%');
            i += 1;
            const width_at = i;
            while (isWidth(source[i])) i += 1;
            const width = source[width_at..i];
            const spec = upper(source[i]);
            switch (spec) {
                'A', 'B', 'C', 'D', 'E', 'F', 'K', 'L', 'M', 'N', 'P', 'T' => {
                    order.put(spec + 0x20);
                    out.write(width);
                    out.put('s');
                    i += 1;
                },
                'S' => {
                    seen += 1;
                    // One `%s` is the name; two make it path then name;
                    // four make the first and third paths.
                    const is_path = if (total > 3)
                        (seen == 1 or seen == 3)
                    else
                        (total > 1 and seen == 1);
                    order.put(if (is_path) 'p' else 'n');
                    out.write(width);
                    out.put('s');
                    i += 1;
                },
                else => {
                    // Not a code: a second '%' makes RawDoFmt print the
                    // one the user wrote, and the character follows.
                    out.put('%');
                    out.write(width);
                },
            }
        }
    } else {
        // The name is always there; the rest is what the switches asked
        // for.
        order.put('n');
        if (!run.quick) {
            if (run.keys) {
                out.write("%-17s [%5s]");
                order.put('k');
            } else {
                out.write("%-24s");
            }
            out.write(" %7s");
            order.put(if (run.block) 'b' else 'l');
            out.write(" %s");
            order.put('a');
            if (!run.nodates) {
                out.write(" %-9s %s");
                order.put('d');
                order.put('t');
            }
            copyZ(&run.comdef, "\n: ");
            out.write("%s");
            order.put('c');
        } else if (run.dates) {
            out.write("%-25s %-9s %s");
            order.put('d');
            order.put('t');
        } else {
            out.write("%s");
        }
    }
    out.end();
    order.end();
    run.order_len = order.at;
}

/// A NUL-terminated string built up a piece at a time. It never runs past
/// the buffer that was sized for it.
const Writer = struct {
    into: [*:0]u8,
    at: usize = 0,

    fn put(w: *Writer, c: u8) void {
        w.into[w.at] = c;
        w.at += 1;
    }
    fn write(w: *Writer, text: []const u8) void {
        for (text) |c| w.put(c);
    }
    fn end(w: *Writer) void {
        w.into[w.at] = 0;
    }
};

fn isWidth(c: u8) bool {
    return c == '-' or c == '.' or (c >= '0' and c <= '9');
}

fn upper(c: u8) u8 {
    return c & 0x5f;
}

// --- SINCE and UPTO -------------------------------------------------------

/// The value is tried as a date first, with midnight for the time, and
/// then as a time on today's date.
fn readSince(run: *Run) void {
    const text = run.since orelse return;
    if (!readWhen(run, text, "00:00:00", &run.since_stamp)) {
        _ = run.dl.PutStr(MSG_INVALID_SINCE_UPTO);
        run.since = null;
    }
}

fn readUpto(run: *Run) void {
    const text = run.upto orelse return;
    if (!readWhen(run, text, "23:59:59", &run.upto_stamp)) {
        _ = run.dl.PutStr(MSG_INVALID_SINCE_UPTO);
        run.upto = null;
    }
}

fn readWhen(run: *Run, text: [*:0]const u8, default_time: [:0]const u8, into: *dos.DateStamp) bool {
    var when: dos.DateTime = .{
        .stamp = run.now,
        .format = dos.FORMAT_DOS,
        .flags = dos.DTF_SUBST,
        .str_date = @constCast(text),
        .str_time = @constCast(default_time.ptr),
    };
    if (run.dl.StrToDate(&when)) {
        into.* = when.stamp;
        return true;
    }
    // Not a date: a time on today's, which is what "List SINCE 12:00"
    // means.
    when = .{
        .stamp = run.now,
        .format = dos.FORMAT_DOS,
        .flags = dos.DTF_SUBST,
        .str_date = null,
        .str_time = @constCast(text),
    };
    if (!run.dl.StrToDate(&when)) return false;
    into.* = when.stamp;
    return true;
}

// --- the walk -------------------------------------------------------------

/// Everything under one name, with the header, the entries
/// and the totals for it.
fn listDir(run: *Run, anchor: *Anchor) i32 {
    const dl = run.dl;
    const name: [*:0]const u8 = @ptrCast(&run.curbuf);
    var didhdr = false;
    var head: ?*DirNode = null;
    var tail: ?*DirNode = null;

    run.rc = dos.RETURN_FAIL;
    anchor.* = .{};
    anchor.ap.break_bits = exec.SIGBREAKF_CTRL_C;
    anchor.ap.flags = dos.APF_DOWILD;
    anchor.ap.strlen = anchor.buf.len;

    var err = dl.MatchFirst(name, &anchor.ap);
    defer dl.MatchEnd(&anchor.ap);

    if (err == 0) {
        if (!dl.IsFileSystem(name)) {
            _ = dl.PutStr("\"");
            _ = dl.PutStr(name);
            _ = dl.PutStr(MSG_CANT_LIST);
            return run.rc;
        }
        // A plain directory: step into it. A pattern already gave what it
        // matched, and is listed as it stands.
        if (anchor.ap.info.dir_entry_type >= 0 and anchor.ap.flags & dos.APF_ITSWILD == 0) {
            anchor.ap.flags |= dos.APF_DODIR;
            err = dl.MatchNext(&anchor.ap);
            if (err == 0 and anchor.ap.flags & dos.APF_DIDDIR != 0) {
                // It came straight back out: there is nothing in it.
                anchor.ap.flags &= ~dos.APF_DIDDIR;
                if (run.lformat == null and !run.nohead) {
                    if (run.notfirst) _ = dl.PutStr("\n");
                    _ = Printf(dl, MSG_DIR, .{name});
                    _ = dl.PutStr(MSG_DIR_EMPTY);
                }
                run.notfirst = true;
                run.rc = dos.RETURN_OK;
                return run.rc;
            }
        }
    }

    if (err == dos.ERROR_NO_MORE_ENTRIES) {
        run.rc = dos.RETURN_OK;
        return run.rc;
    }
    if (err == dos.ERROR_BREAK) {
        _ = dl.PrintFault(err, null);
        run.rc = dos.RETURN_WARN;
        return run.rc;
    }
    if (err != 0) {
        if (run.lformat == null and !run.nohead) _ = Printf(dl, MSG_NO_INFO, .{name});
        _ = dl.PrintFault(err, "");
        return run.rc;
    }

    anchor.ap.flags &= ~dos.APF_DIDDIR;
    while (true) {
        const ap = &anchor.ap;
        // MatchNext moved to another directory: the one before it is done.
        if (ap.flags & dos.APF_DirChanged != 0) {
            printDirStats(run);
            didhdr = false;
        }
        if (ap.flags & dos.APF_DIDDIR != 0) {
            ap.flags &= ~dos.APF_DIDDIR;
            err = dl.MatchNext(ap);
            if (err != 0) break;
            continue;
        }

        if (!didhdr) {
            header(run, ap);
            didhdr = true;
        }

        const entry_type = ap.info.dir_entry_type;

        // ALL keeps every directory it meets for later, in the order it
        // met them.
        if (run.all and entry_type >= 0) {
            if (run.sys.AllocVec(@sizeOf(DirNode), exec.MEMF_CLEAR)) |raw| {
                const node: *DirNode = @ptrCast(@alignCast(raw));
                copyZ(&node.name, @ptrCast(&run.namebuf));
                _ = dl.AddPart(@ptrCast(&node.name), @ptrCast(&ap.info.file_name), node.name.len);
                if (tail) |t| t.next = node else head = node;
                tail = node;
            }
        }

        if (wanted(run, ap)) {
            printEntry(run, ap, entry_type);
            if (entry_type >= 0) {
                if (!run.files) {
                    run.dircount += 1;
                    run.totaldirs += 1;
                }
            } else if (!run.dirs) {
                run.filecount += 1;
                run.totalfiles += 1;
            }
            // One block more for the entry itself.
            run.numblocks += ap.info.num_blocks + 1;
            run.totalblocks += ap.info.num_blocks + 1;
        }

        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            _ = dl.SetIoErr(dos.ERROR_BREAK);
            err = dos.ERROR_BREAK;
            break;
        }
        err = dl.MatchNext(ap);
        if (err != 0) break;
    }

    if (err == dos.ERROR_NO_MORE_ENTRIES or err == 0) run.rc = dos.RETURN_OK;
    if (err == dos.ERROR_BREAK) {
        _ = dl.PrintFault(dos.ERROR_BREAK, null);
        run.rc = dos.RETURN_WARN;
    }

    // What ALL collected goes in front of what was already waiting, so the
    // walk stays depth-first.
    if (head) |first| {
        tail.?.next = run.dhead;
        run.dhead = first;
    }
    printDirStats(run);
    return run.rc;
}

/// The two lines above a directory's entries, and the paths that go with
/// the `%p` and `%f` codes.
fn header(run: *Run, ap: *dos.AnchorPath) void {
    const dl = run.dl;
    // The relative path, as the walk reached it: what ap_Buf holds with
    // the entry's own name cut off.
    copyZ(&run.dirbuf, @ptrCast(ap.buffer()));
    const cut = dl.PathPart(@ptrCast(&run.dirbuf));
    run.dirbuf[@intFromPtr(cut) - @intFromPtr(&run.dirbuf)] = 0;
    copyZ(&run.namebuf, @ptrCast(&run.dirbuf));

    // The full path, which only `%f` asks for.
    if (!dl.NameFromLock(if (ap.last) |node| node.lock else null, @ptrCast(&run.fulldir), run.fulldir.len)) {
        run.fulldir[0] = 0;
    }
    _ = dl.AddPart(@ptrCast(&run.fulldir), "", run.fulldir.len);
    _ = dl.AddPart(@ptrCast(&run.dirbuf), "", run.dirbuf.len);

    // No header for a name that named one entry, and none under LFORMAT or
    // QUICK.
    if (run.namebuf[0] == 0 or run.nohead or run.quick or run.lformat != null) {
        run.notfirst = true;
        return;
    }
    if (run.notfirst) _ = dl.PutStr("\n");
    _ = Printf(dl, MSG_DIR, .{@as([*:0]const u8, @ptrCast(&run.namebuf))});

    var when: dos.DateTime = .{
        .stamp = run.now,
        .format = dos.FORMAT_DOS,
        .flags = 0,
        .str_day = &run.dow,
        .str_date = &run.date,
        .str_time = &run.time,
    };
    if (!dl.DateToStr(&when)) {
        copyZ(&run.dow, MSG_INVALID_DS);
        copyZ(&run.date, MSG_INVALID_DS);
    }
    _ = Printf(dl, MSG_DIR_ON, .{
        @as([*:0]const u8, @ptrCast(&run.dow)),
        @as([*:0]const u8, @ptrCast(&run.date)),
    });
    run.notfirst = true;
}

/// FILES, DIRS, SINCE, UPTO, PAT and SUB, in that order.
fn wanted(run: *Run, ap: *dos.AnchorPath) bool {
    const entry_type = ap.info.dir_entry_type;
    // One of the two switches keeps the other kind out; both (or neither)
    // let everything through.
    if ((entry_type < 0 and run.dirs) or (entry_type > 0 and run.files)) {
        if (!run.dirs or !run.files) return false;
    }
    // CompareDates is negative when the first date is the earlier: an entry
    // no later than SINCE, or no earlier than UPTO, is left out.
    if (run.since != null and run.dl.CompareDates(&ap.info.date, &run.since_stamp) <= 0) return false;
    if (run.upto != null and run.dl.CompareDates(&ap.info.date, &run.upto_stamp) >= 0) return false;

    const own: [*:0]const u8 = @ptrCast(&ap.info.file_name);
    if (run.patbuf[0] != 0) {
        if (!run.ub.MatchPatternNoCase(@ptrCast(&run.patbuf), own)) return false;
    } else if (run.subbuf[0] != 0) {
        if (!run.ub.MatchPatternNoCase(@ptrCast(&run.subbuf), own)) return false;
    }
    return true;
}

/// One entry: every value the format asks for, then the line.
fn printEntry(run: *Run, ap: *dos.AnchorPath, entry_type: i32) void {
    const dl = run.dl;

    var when: dos.DateTime = .{
        .stamp = ap.info.date,
        .format = dos.FORMAT_DOS,
        // Without DATES a recent date comes out as "Today" or a weekday,
        // which is what a listing normally shows.
        .flags = if (!run.dates) dos.DTF_SUBST else 0,
        .str_day = &run.dow,
        .str_date = &run.date,
        .str_time = &run.time,
    };
    if (!dl.DateToStr(&when)) {
        copyZ(&run.date, MSG_INVALID_DS);
        copyZ(&run.time, MSG_INVALID_DS);
    }

    // The name split at the last '.', for %M and %E.
    copyZ(&run.minusbuf, @ptrCast(&ap.info.file_name));
    run.extbuf[0] = 0;
    var dot: ?usize = null;
    var i: usize = 0;
    while (run.minusbuf[i] != 0) : (i += 1) {
        if (run.minusbuf[i] == '.') dot = i;
    }
    if (dot) |at| {
        copyZ(&run.extbuf, @ptrCast(&run.minusbuf[at + 1]));
        run.minusbuf[at] = 0;
    }

    decimal64(&run.blkbuf, @intCast(ap.info.num_blocks));
    decimal64(&run.keybuf, @intCast(ap.info.disk_key));
    decimal64(&run.lenbuf, @intCast(ap.info.size));

    // "hsparwed", with a '-' where the right is not there. The bottom four
    // read backwards: a set bit means the thing may not be done.
    copyZ(&run.protbits, MSG_PROTBITS);
    i = 0;
    while (i < 8) : (i += 1) {
        const bit = @as(u32, 1) << @intCast(7 - i);
        const on = if (i < 4) (ap.info.protection & bit) != 0 else (ap.info.protection & bit) == 0;
        if (!on) run.protbits[i] = '-';
    }

    var slot: usize = 0;
    while (slot < run.order_len) : (slot += 1) {
        run.fields[slot] = switch (run.order[slot]) {
            'a' => @intFromPtr(&run.protbits),
            'b' => size(entry_type, ap.info.size, &run.blkbuf),
            'c' => comment: {
                if (ap.info.comment[0] != 0) {
                    copyZ(&run.combuf, @ptrCast(&run.comdef));
                    appendZ(&run.combuf, @ptrCast(&ap.info.comment));
                } else {
                    run.combuf[0] = 0;
                }
                break :comment @intFromPtr(&run.combuf);
            },
            'd' => @intFromPtr(&run.date),
            'e' => @intFromPtr(&run.extbuf),
            'f' => @intFromPtr(&run.fulldir),
            'k' => @intFromPtr(&run.keybuf),
            'l' => size(entry_type, ap.info.size, &run.lenbuf),
            'm' => @intFromPtr(&run.minusbuf),
            'n' => @intFromPtr(&ap.info.file_name),
            'p' => @intFromPtr(&run.dirbuf),
            't' => @intFromPtr(&run.time),
            else => @intFromPtr(""),
        };
    }
    _ = dl.VPrintf(run.format, run.fields);
    _ = dl.PutStr("\n");
}

/// What goes in a size column: "Dir" for a directory, "empty" for nothing
/// in it, else the number already written out.
fn size(entry_type: i32, bytes: u64, text: *const [number_size:0]u8) usize {
    if (entry_type >= 0) return @intFromPtr(MSG_DIR_TYPE);
    if (bytes == 0) return @intFromPtr(MSG_EMPTY);
    return @intFromPtr(text);
}

/// The counts for one directory, printed under its entries.
fn printDirStats(run: *Run) void {
    const dl = run.dl;
    if (run.lformat == null and !run.nohead and run.filecount + run.dircount != 0) {
        if (!run.dirs and run.filecount != 0) {
            _ = Printf(dl, "%d %s - ", .{ run.filecount, plural(run.filecount, MSG_ONE_FILE, MSG_MANY_FILES) });
        }
        if (!run.files and run.dircount != 0) {
            _ = Printf(dl, "%d %s - ", .{ run.dircount, plural(run.dircount, MSG_ONE_DIR, MSG_MANY_DIRS) });
        }
        _ = Printf(dl, "%ld %s used\n", .{ run.numblocks, plural64(run.numblocks, MSG_ONE_BLOCK, MSG_MANY_BLOCKS) });
    }
    run.dircount = 0;
    run.filecount = 0;
    run.numblocks = 0;
}

fn plural(count: u32, one: [:0]const u8, many: [:0]const u8) [*:0]const u8 {
    return if (count > 1) many.ptr else one.ptr;
}

fn plural64(count: u64, one: [:0]const u8, many: [:0]const u8) [*:0]const u8 {
    return if (count > 1) many.ptr else one.ptr;
}

// --- strings --------------------------------------------------------------

fn length(text: [*:0]const u8) usize {
    var i: usize = 0;
    while (text[i] != 0) i += 1;
    return i;
}

/// A NUL-terminated string into a buffer, cut if it does not fit.
fn copyZ(into: anytype, text: [*:0]const u8) void {
    const limit = into.len;
    var i: usize = 0;
    while (text[i] != 0 and i < limit) : (i += 1) into[i] = text[i];
    into[i] = 0;
}

/// A NUL-terminated string onto the end of one, cut if it does not fit.
fn appendZ(into: anytype, text: [*:0]const u8) void {
    const limit = into.len;
    var at: usize = 0;
    while (at < limit and into[at] != 0) at += 1;
    var i: usize = 0;
    while (text[i] != 0 and at + i < limit) : (i += 1) into[at + i] = text[i];
    into[at + i] = 0;
}

fn decimal64(into: *[number_size:0]u8, value: i64) void {
    var digits: [number_size]u8 = undefined;
    var n: usize = 0;
    var left: u64 = if (value < 0) @intCast(-value) else @intCast(value);
    while (true) {
        digits[n] = '0' + @as(u8, @intCast(left % 10));
        n += 1;
        left /= 10;
        if (left == 0) break;
    }
    var at: usize = 0;
    if (value < 0) {
        into[at] = '-';
        at += 1;
    }
    while (n > 0) {
        n -= 1;
        into[at] = digits[n];
        at += 1;
    }
    into[at] = 0;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
