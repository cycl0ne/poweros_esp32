// SPDX-License-Identifier: MIT
//! Dir: what is in a directory, directories first and files sorted after them.
//! Built against the SDK only.
//!
//!   Dir DIR,OPT/K,ALL/S,DIRS/S,FILES/S,INTER/S
//!
//! DIR may be a pattern. ALL goes into every directory as well, indented.
//! DIRS and FILES show only the one kind; neither shows both. OPT takes
//! the letters A, D, F and I and means the same as the switches; a letter
//! that is none of them is "<c> option ignored". With no name the current
//! directory is listed.
//!
//! It walks with one MatchFirst and then MatchNext: setting APF_DODIR makes the
//! next MatchNext step into the directory it just gave, and it sets APF_DIDDIR
//! when that directory is done, which ends the level. With a pattern at the top
//! level it does not step in at all unless ALL is given, so `Dir RAM:#?` shows
//! only what is in the root, and a directory it matched is printed with its
//! full path.
//!
//! The layout: a directory to a line, indented five spaces per
//! level, and the files after them two to a line, indented two more, each
//! name in a column of 31. There is no size and no window width: nothing in
//! this system can say how wide a terminal is.
//!
//! INTER asks what to do with each entry, reading the answer with ReadArgs
//! so that the words may be shortened:
//!
//!   for a file        T=TYPE/S,B=BACK/S,DEL=DELETE/S,Q=QUIT/S,C=COM/S,COMMAND
//!   for a directory   E=ENTER/S,B=BACK/S,DEL=DELETE/S,Q=QUIT/S,C=COM/S,COMMAND
//!
//! TYPE writes a file out, ENTER goes into a directory, BACK leaves one,
//! DELETE deletes, COM runs a command (or asks for one), QUIT stops, and
//! RETURN alone moves on. Anything else is "Invalid response - try again".
//! Deleting a directory waits until after the next MatchNext:
//! taking it away under the Match routines pulls the walk apart.
//!
//! A lone last file is printed without padding after it; there is no
//! ST_LINKDIR to mark and no circular-link check, since there are no links
//! yet; and the recursion is capped, since a command runs on the shell's
//! stack. Files are sorted as utility.library's Stricmp
//! orders them (Latin-1, case ignored), done here so that Dir opens nothing
//! but dos.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Dir";
const VERSION_STRING = "\x00$VER: Dir 1.0 (16.9.2026)\r\n";

const template = "DIR,OPT/K,ALL/S,DIRS/S,FILES/S,INTER/S";
const arg_dir = 0;
const arg_opt = 1;
const arg_all = 2;
const arg_dirs = 3;
const arg_files = 4;
const arg_inter = 5;

/// The two templates for the answer to its prompt.
const inter_file_template = "T=TYPE/S,B=BACK/S,DEL=DELETE/S,Q=QUIT/S,C=COM/S,COMMAND";
const inter_dir_template = "E=ENTER/S,B=BACK/S,DEL=DELETE/S,Q=QUIT/S,C=COM/S,COMMAND";
const inter_enter_type = 0;
const inter_back = 1;
const inter_delete = 2;
const inter_quit = 3;
const inter_com = 4;
const inter_command = 5;

const MSG_OPTION_IGNORED = " option ignored\n";
const MSG_OUT_OF_MEM_INC = "List incomplete - ";
const MSG_DELETED = "Deleted\n";
const MSG_COMMAND_PROMPT = "\nCommand ? ";
const MSG_INVALID_RESPONSE = "Invalid response - try again\n";

/// The path, name and command buffers.
const max_path = 256;
const max_name = 32;
const command_size = 256;
/// A directory is indented five spaces per level and a file two more.
const indent_step = 5;
const file_indent = 2;
/// The column a file's name is printed in.
const name_column = 31;
/// How deep it goes. A command runs on the shell's stack, which is 8 KiB unless
/// `Stack` says otherwise.
const max_depth = 15;

/// One file, kept until the level's walk is over so that they can be
/// sorted and printed in columns.
const Entry = struct {
    next: ?*Entry = null,
    name: [max_name:0]u8 = @splat(0),
};

/// What an interactive answer came to. `delete_dir`: the directory goes, but
/// only after the next MatchNext.
const Answer = enum { next, repeat, enter, back, quit, delete_dir };

const Anchor = extern struct {
    ap: dos.AnchorPath = .{},
    buf: [max_path]u8 = @splat(0),
};

const Run = struct {
    sys: *ExecBase,
    dl: *DosBase,
    anchor: *Anchor,
    all: bool,
    dirs: bool,
    files: bool,
    inter: bool,
    /// Set by ENTER, for one directory only.
    enter: bool = false,
    quit: bool = false,
    failed: bool = false,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [6]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    var all = argv[arg_all] != 0;
    var dirs = argv[arg_dirs] != 0;
    var files = argv[arg_files] != 0;
    var inter = argv[arg_inter] != 0;
    // OPT A/D/F/I, the same as the switches.
    if (rdargs.string(argv[arg_opt])) |opt| {
        var p = opt;
        while (p[0] != 0) : (p += 1) switch (p[0]) {
            'i', 'I' => inter = true,
            'a', 'A' => all = true,
            'd', 'D' => dirs = true,
            'f', 'F' => files = true,
            else => {
                _ = Printf(dl, "%c", .{@as(u32, p[0])});
                _ = dl.PutStr(MSG_OPTION_IGNORED);
            },
        };
    }
    // Neither means both.
    if (!dirs and !files) {
        dirs = true;
        files = true;
    }

    var anchor: Anchor = .{};
    anchor.ap.strlen = anchor.buf.len;
    anchor.ap.break_bits = exec.SIGBREAKF_CTRL_C;
    anchor.ap.flags = dos.APF_DOWILD;
    var run: Run = .{
        .sys = sys,
        .dl = dl,
        .anchor = &anchor,
        .all = all,
        .dirs = dirs,
        .files = files,
        .inter = inter,
    };

    // MatchFirst will not take a null name; "" is the current directory.
    const where = rdargs.string(argv[arg_dir]) orelse "";
    const err = dl.MatchFirst(where, &anchor.ap);
    if (err == 0) {
        doDir(&run, 0);
    } else if (err != dos.ERROR_NO_MORE_ENTRIES) {
        _ = dl.PrintFault(err, where);
        run.failed = true;
    }
    dl.MatchEnd(&anchor.ap);
    _ = dl.Flush(dl.Output());
    return if (run.failed) dos.RETURN_ERROR else dos.RETURN_OK;
}

/// The AnchorPath is sitting on an entry; if it is a
/// directory, step into it and walk what is inside.
fn doDir(run: *Run, level: u32) void {
    const dl = run.dl;
    const ap = &run.anchor.ap;
    run.enter = false; // one directory only

    var err: i32 = 0;
    if (ap.info.dir_entry_type > 0) {
        // A pattern at the top level lists what it matched; it does not go
        // into it unless ALL says so.
        if (!(level == 0 and ap.flags & dos.APF_ITSWILD != 0)) {
            ap.flags |= dos.APF_DODIR;
            err = dl.MatchNext(ap);
        }
    }
    // The directory being walked, for INTER's TYPE and DELETE, which work
    // from a name rather than a path.
    const here = if (err == 0) dl.DupLock(if (ap.last) |node| node.lock else null) else null;
    defer if (here) |lock| dl.UnLock(lock);

    var files: ?*Entry = null;
    defer freeList(run, files);

    while (err == 0) {
        if (ap.flags & dos.APF_DIDDIR != 0) {
            ap.flags &= ~dos.APF_DIDDIR;
            break;
        }
        if (ap.found_break & exec.SIGBREAKF_CTRL_C != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            run.quit = true;
            break;
        }

        // A directory goes out as it is met, unsorted.
        var doomed: [max_name:0]u8 = @splat(0);
        var remove_dir = false;
        if (ap.info.dir_entry_type > 0) {
            if (run.dirs) {
                var shown: [max_path:0]u8 = @splat(0);
                const name = dirName(run, level, &shown);
                switch (offerDir(run, name, level)) {
                    .quit => run.quit = true,
                    .back => break,
                    .enter => run.enter = true,
                    .delete_dir => {
                        // Its name has to be kept: MatchNext moves on to
                        // the next entry before it can go.
                        remove_dir = true;
                        const own = &ap.info.file_name;
                        var i: usize = 0;
                        while (own[i] != 0 and i < doomed.len) : (i += 1) doomed[i] = own[i];
                    },
                    .next, .repeat => {},
                }
            }
            if (run.quit) break;
            if ((run.all or run.enter) and level < max_depth) {
                doDir(run, level + 1);
                ap.flags &= ~dos.APF_DIDDIR;
                if (run.quit) break;
            }
        } else if (run.files) {
            if (!collect(run, &files)) break;
        }

        err = dl.MatchNext(ap);
        // A directory is taken away only after the next MatchNext: doing it
        // under the Match routines pulls the walk apart.
        if (remove_dir) deleteOne(run, here, @ptrCast(&doomed));
    }
    if (err != 0 and err != dos.ERROR_NO_MORE_ENTRIES) {
        _ = dl.PrintFault(err, null);
        run.failed = true;
    }
    if (!run.quit) showFiles(run, files, here, level);
}

/// The name a directory is printed under: its own, or the full path when a
/// pattern matched it at the top level.
fn dirName(run: *Run, level: u32, into: *[max_path:0]u8) [*:0]const u8 {
    const ap = &run.anchor.ap;
    const own: [*:0]const u8 = @ptrCast(&ap.info.file_name);
    if (level != 0 or ap.flags & dos.APF_ITSWILD == 0) return own;
    const lock = if (ap.last) |node| node.lock else null;
    if (!run.dl.NameFromLock(lock, @ptrCast(into), into.len)) return own;
    if (!run.dl.AddPart(@ptrCast(into), own, into.len)) return own;
    return @ptrCast(into);
}

/// A directory printed, and in interactive mode asked about.
fn offerDir(run: *Run, name: [*:0]const u8, level: u32) Answer {
    const dl = run.dl;
    var indent: [indent_step * (max_depth + 1):0]u8 = @splat(' ');
    indent[@min((level + 1) * indent_step, indent.len)] = 0;
    const lead: [*:0]const u8 = @ptrCast(&indent);
    if (!run.inter) {
        _ = Printf(dl, "%s%s (dir)\n", .{ lead, name });
        return .next;
    }
    while (true) {
        _ = Printf(dl, "%s%s (dir) ? ", .{ lead, name });
        _ = dl.Flush(dl.Output());
        switch (interact(run, true, null, name)) {
            .repeat => continue,
            else => |answer| return answer,
        }
    }
}

/// One file's name onto the level's list, in order. Answers false when
/// there was no memory for it, which stops the level.
fn collect(run: *Run, head: *?*Entry) bool {
    const block = run.sys.AllocVec(@sizeOf(Entry), exec.MEMF_CLEAR) orelse {
        _ = run.dl.PutStr(MSG_OUT_OF_MEM_INC);
        run.failed = true;
        return false;
    };
    const entry: *Entry = @ptrCast(@alignCast(block));
    const from = &run.anchor.ap.info.file_name;
    var i: usize = 0;
    while (from[i] != 0 and i < entry.name.len) : (i += 1) entry.name[i] = from[i];

    var at = head;
    while (at.*) |there| {
        if (before(entry, there)) break;
        at = &there.next;
    }
    entry.next = at.*;
    at.* = entry;
    return true;
}

fn freeList(run: *Run, head: ?*Entry) void {
    var it = head;
    while (it) |entry| {
        const following = entry.next;
        run.sys.FreeVec(entry);
        it = following;
    }
}

/// The level's files, two to a line, or one at a time
/// with a prompt in interactive mode.
fn showFiles(run: *Run, head: ?*Entry, here: ?*dos.FileLock, level: u32) void {
    const dl = run.dl;
    var indent: [indent_step * (max_depth + 1) + file_indent:0]u8 = @splat(' ');
    indent[@min(level * indent_step + file_indent, indent.len)] = 0;
    const lead: [*:0]const u8 = @ptrCast(&indent);

    var it = head;
    var waiting: ?*Entry = null;
    while (it) |entry| : (it = entry.next) {
        const name: [*:0]const u8 = @ptrCast(&entry.name);
        if (run.inter) {
            if (run.quit) return;
            offerFile(run, entry, here, lead);
            continue;
        }
        if (waiting) |first| {
            _ = Printf(dl, "%s%-31s  %s\n", .{ lead, @as([*:0]const u8, @ptrCast(&first.name)), name });
            waiting = null;
        } else {
            waiting = entry;
        }
    }
    // A lone last name goes in its column without padding after it.
    if (waiting) |first| _ = Printf(dl, "%s%s\n", .{ lead, @as([*:0]const u8, @ptrCast(&first.name)) });
}

/// A file in interactive mode: the name, the prompt, and what the answer
/// asks for.
fn offerFile(run: *Run, entry: *Entry, here: ?*dos.FileLock, lead: [*:0]const u8) void {
    const dl = run.dl;
    const name: [*:0]const u8 = @ptrCast(&entry.name);
    while (true) {
        _ = Printf(dl, "%s%s ? ", .{ lead, name });
        _ = dl.Flush(dl.Output());
        switch (interact(run, false, here, name)) {
            .repeat => continue,
            .quit => {
                run.quit = true;
                return;
            },
            else => return,
        }
    }
}

/// The answer to the prompt, read with ReadArgs from
/// Input() so that TYPE, T, DELETE, DEL and the rest all work.
fn interact(run: *Run, is_dir: bool, here: ?*dos.FileLock, name: [*:0]const u8) Answer {
    const dl = run.dl;
    var opts: [6]usize = @splat(0);
    const rda = dl.ReadArgs(
        if (is_dir) inter_dir_template else inter_file_template,
        &opts,
        null,
    ) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        run.failed = true;
        return .quit;
    };
    defer dl.FreeArgs(rda);

    // TYPE, on a file only.
    if (opts[inter_enter_type] != 0 and !is_dir) {
        typeOut(run, here, name);
        return .repeat;
    }
    // COM, with the command after it or asked for.
    if (opts[inter_com] != 0) {
        if (rdargs.string(opts[inter_command])) |command| {
            _ = dl.Execute(command, null, null);
        } else {
            _ = dl.PutStr(MSG_COMMAND_PROMPT);
            _ = dl.Flush(dl.Output());
            var command: [command_size:0]u8 = @splat(0);
            if (dl.FGets(dl.Input(), @ptrCast(&command), command.len) != null) {
                _ = dl.Execute(@ptrCast(&command), null, null);
            }
        }
        _ = dl.PutStr("\n");
        return .repeat;
    }
    // Anything the template did not know is a word in COMMAND.
    if (opts[inter_command] != 0) {
        _ = dl.PutStr(MSG_INVALID_RESPONSE);
        return .repeat;
    }
    if (opts[inter_quit] != 0) return .quit;
    if (opts[inter_back] != 0) return .back;
    if (opts[inter_enter_type] != 0 and is_dir) return .enter;
    if (opts[inter_delete] != 0) {
        // A directory is taken away after the next MatchNext; a file can go
        // now.
        if (is_dir) return .delete_dir;
        deleteOne(run, here, name);
        return .next;
    }
    return .next; // RETURN alone
}

fn deleteOne(run: *Run, here: ?*dos.FileLock, name: [*:0]const u8) void {
    const dl = run.dl;
    const was = dl.CurrentDir(here);
    defer _ = dl.CurrentDir(was);
    if (dl.DeleteFile(name)) {
        _ = dl.PutStr(MSG_DELETED);
    } else {
        _ = dl.PrintFault(dl.IoErr(), name);
        run.failed = true;
    }
}

/// A file written out, as INTER's TYPE does, stopping at Ctrl-C.
fn typeOut(run: *Run, here: ?*dos.FileLock, name: [*:0]const u8) void {
    const dl = run.dl;
    const was = dl.CurrentDir(here);
    defer _ = dl.CurrentDir(was);
    const fh = dl.Open(name, dos.MODE_OLDFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), name);
        run.failed = true;
        return;
    };
    defer _ = dl.Close(fh);
    while (true) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            break;
        }
        const c = dl.FGetC(fh);
        if (c < 0) break;
        var one: [1]u8 = .{@intCast(c)};
        _ = dl.WriteChars(&one, 1);
    }
}

/// By name, ignoring case as utility.library's Stricmp does (Latin-1).
fn before(a: *const Entry, b: *const Entry) bool {
    var i: usize = 0;
    while (true) : (i += 1) {
        const x = upper(a.name[i]);
        const y = upper(b.name[i]);
        if (x != y) return x < y;
        if (x == 0) return false;
    }
}

fn upper(c: u8) u8 {
    return switch (c) {
        'a'...'z', 0xE0...0xF6, 0xF8...0xFE => c - 0x20,
        else => c,
    };
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs: the linker collects unused
/// sections, and a plain constant never reaches the file at all - which is
/// all the comptime reference that used to stand here achieved.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
