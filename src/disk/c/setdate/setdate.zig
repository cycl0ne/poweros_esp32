// SPDX-License-Identifier: MIT
//! SetDate: the date a file carries, or everything a pattern matches,
//! set. Built against the SDK only.
//!
//!   SetDate FILE/A,WEEKDAY,DATE,TIME,ALL/S
//!
//!   SetDate notes              now
//!   SetDate #?.txt 01-Jan-2026 12:00
//!   SetDate work ALL           the directory and everything below it
//!
//! WEEKDAY, DATE and TIME are each read as a date - dd-mmm-yyyy, a
//! weekday, today, tomorrow, yesterday - and else as a time, hh:mm or
//! hh:mm:ss, so they may come in any order; what is not given is now's.
//! WEEKDAY is there so that what Date prints ("Friday 25-Sep-2026
//! 22:43:11") can be handed back as it is. ALL steps into directories,
//! and a directory is set as well as what is in it. It says nothing when
//! it succeeds; Ctrl-C stops it with a warning.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;

pub const COMMAND_NAME = "SetDate";
const VERSION_STRING = "\x00$VER: SetDate 1.0 (25.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE/A,WEEKDAY,DATE,TIME,ALL/S";
const arg_file = 0;
const arg_weekday = 1;
const arg_date = 2;
const arg_time = 3;
const arg_all = 4;

const MSG_FAILED = "SetDate failed";
const MSG_BADDATE = "SetDate failed: Invalid DATE or TIME string!\n";

/// The longest path, dos's limit: a name of the full length in a
/// drawer several deep.
const max_path = dos.path_max;

const Anchor = extern struct {
    ap: dos.AnchorPath = .{},
    buf: [max_path]u8 = @splat(0),
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [5]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const name = rdargs.string(argv[arg_file]).?;
    const all = argv[arg_all] != 0;

    // Now, with what was given read over it: each string as a date, and
    // failing that as a time.
    var datetime: dos.DateTime = .{ .format = dos.datetime.FORMAT_DOS, .flags = dos.datetime.DTF_FUTURE };
    _ = dl.DateStamp(&datetime.stamp);
    for ([_]usize{ arg_weekday, arg_date, arg_time }) |slot| {
        const text = rdargs.string(argv[slot]) orelse continue;
        datetime.str_date = @constCast(text);
        datetime.str_time = null;
        if (dl.StrToDate(&datetime)) continue;
        datetime.str_date = null;
        datetime.str_time = @constCast(text);
        if (dl.StrToDate(&datetime)) continue;
        _ = dl.PutStr(MSG_BADDATE);
        return dos.RETURN_FAIL;
    }

    var anchor: Anchor = .{};
    anchor.ap.strlen = anchor.buf.len;
    anchor.ap.break_bits = exec.SIGBREAKF_CTRL_C;
    anchor.ap.flags = dos.APF_DOWILD;
    var err = dl.MatchFirst(name, &anchor.ap);
    defer dl.MatchEnd(&anchor.ap);

    while (err == 0) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            err = dos.ERROR_BREAK;
            break;
        }
        const ap = &anchor.ap;
        if (ap.flags & dos.APF_DIDDIR != 0) {
            // On the way out of a directory: it was set on the way in.
            ap.flags &= ~dos.APF_DIDDIR;
            err = dl.MatchNext(ap);
            continue;
        }
        if (ap.info.dir_entry_type >= 0 and all) ap.flags |= dos.APF_DODIR;

        // SetFileDate works from the name, so the entry's own directory
        // has to be the current one while it runs.
        const here = dl.CurrentDir(if (ap.last) |node| node.lock else null);
        const own: [*:0]const u8 = @ptrCast(&ap.info.file_name);
        const done = dl.SetFileDate(own, &datetime.stamp);
        _ = dl.CurrentDir(here);
        if (!done) {
            err = dl.IoErr();
            break;
        }
        err = dl.MatchNext(ap);
    }

    if (err == dos.ERROR_NO_MORE_ENTRIES) return dos.RETURN_OK;
    _ = dl.PrintFault(err, MSG_FAILED);
    return if (err == dos.ERROR_BREAK) dos.RETURN_WARN else dos.RETURN_FAIL;
}
