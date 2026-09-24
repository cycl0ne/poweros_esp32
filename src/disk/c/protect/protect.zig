// SPDX-License-Identifier: MIT
//! Protect: the protection bits of a file, or of everything a pattern
//! matches. Built against the SDK only.
//!
//!   Protect FILE/A,FLAGS,ADD/S,SUB/S,ALL/S,QUIET/S
//!
//!   Protect file rwed        exactly those bits, the others cleared
//!   Protect file +p          the P bit added, the rest left alone
//!   Protect file -w ALL      the W bit taken from everything below it
//!
//! The letters are HSPARWED, in any order and in either case; '+' means
//! ADD and '-' means SUB, so they may be written either way. ADD and SUB
//! together is an error, as is a FLAGS string with no letter in it.
//!
//! The bottom four bits (RWED) read backwards: a set bit means the thing
//! may *not* be done. Protect hides that - "rwed" sets all four rights -
//! by flipping them on the way in and on the way out.
//!
//! With a pattern, or with ALL, each entry is named as it is done:
//!
//!   ram:t (dir)...done
//!        ram:t/x...done
//!
//! QUIET keeps that quiet. ALL steps into directories, and the directory
//! itself is set as well as what is in it.
//!
//! A file that already has the bits asked for is left alone and still says
//! "done". The H bit (0x80) is among the bits it may set although nothing
//! reads it, so that a script that says "h" does not fail.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Protect";
const VERSION_STRING = "\x00$VER: Protect 1.0 (16.9.2026)\r\n";

const template = "FILE/A,FLAGS,ADD/S,SUB/S,ALL/S,QUIET/S";
const arg_file = 0;
const arg_flags = 1;
const arg_add = 2;
const arg_sub = 3;
const arg_all = 4;
const arg_quiet = 5;

const MSG_BADFLAG = "Invalid flag - must be one of SPARWED\n";
const MSG_SETFAILED = "Can't set protection for %s - ";
const MSG_DONE = "done\n";
const MSG_DIR = " (dir)";
const MSG_BLANKS = "        ";
const MSG_ADDSUB = "Can't specify both ADD (+) and SUB (-)\n";

/// FIBF_HIDDEN, 0x80: no file system reads it,
/// but Protect has always been able to set it.
const FIBF_HIDDEN: u32 = 1 << 7;
const all_prot_bits: u32 = FIBF_HIDDEN | dos.FIBF_SCRIPT | dos.FIBF_PURE |
    dos.FIBF_ARCHIVE | dos.FIBF_READ | dos.FIBF_WRITE | dos.FIBF_EXECUTE | dos.FIBF_DELETE;
/// The bottom four bits are the ones stored the other way round.
const reverse_bits: u32 = 0x0f;

/// The spaces a file is indented past its directory, and the spaces each
/// level adds.
const norm_indent = 3;
const tab_size = 5;
const max_path = 256;

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

    var argv: [6]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    var add = argv[arg_add] != 0;
    var sub = argv[arg_sub] != 0;
    const all = argv[arg_all] != 0;
    const quiet = argv[arg_quiet] != 0;
    const name = rdargs.string(argv[arg_file]).?;

    // The letters, in either case, with '+' and '-' standing for ADD and
    // SUB so that "protect file +p" reads the way people write it.
    var umask: u32 = 0;
    if (rdargs.string(argv[arg_flags])) |flags| {
        var p = flags;
        while (p[0] != 0) : (p += 1) switch (p[0]) {
            'h', 'H' => umask |= FIBF_HIDDEN,
            's', 'S' => umask |= dos.FIBF_SCRIPT,
            'p', 'P' => umask |= dos.FIBF_PURE,
            'a', 'A' => umask |= dos.FIBF_ARCHIVE,
            'r', 'R' => umask |= dos.FIBF_READ,
            'w', 'W' => umask |= dos.FIBF_WRITE,
            'e', 'E' => umask |= dos.FIBF_EXECUTE,
            'd', 'D' => umask |= dos.FIBF_DELETE,
            '+' => add = true,
            '-' => sub = true,
            else => {
                _ = dl.PutStr(MSG_BADFLAG);
                return dos.RETURN_FAIL;
            },
        };
        if (umask == 0) {
            _ = dl.PutStr(MSG_BADFLAG);
            return dos.RETURN_FAIL;
        }
    }
    if (add and sub) {
        _ = dl.PutStr(MSG_ADDSUB);
        return dos.RETURN_FAIL;
    }
    // SUB takes bits away: what it will keep is everything but those.
    if (sub) umask = (~umask & all_prot_bits) | ~all_prot_bits;

    var anchor: Anchor = .{};
    anchor.ap.strlen = anchor.buf.len;
    anchor.ap.break_bits = exec.SIGBREAKF_CTRL_C;
    anchor.ap.flags = dos.APF_DOWILD;

    var rc: i32 = dos.RETURN_FAIL;
    var err = dl.MatchFirst(name, &anchor.ap);
    defer dl.MatchEnd(&anchor.ap);

    var indent: i32 = 0;
    // The path that would not take its bits, kept for the one message
    // Protect has to print after MatchEnd.
    var failed_path: ?[*:0]const u8 = null;

    while (err == 0) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            err = dos.ERROR_BREAK;
            break;
        }
        const ap = &anchor.ap;
        if (ap.flags & dos.APF_DIDDIR != 0) {
            // On the way out of a directory: it was done on the way in.
            ap.flags &= ~dos.APF_DIDDIR;
            indent -= 1;
            err = dl.MatchNext(ap);
            continue;
        }

        const is_dir = ap.info.dir_entry_type >= 0;
        if (is_dir and all) {
            ap.flags |= dos.APF_DODIR;
            indent += 1;
        }

        // Only a pattern or ALL names what it is doing: one plain file is
        // done silently.
        var named = false;
        if (ap.flags & dos.APF_ITSWILD != 0 or all) {
            named = true;
            if (!quiet) {
                var left = indent;
                while (left > 0) : (left -= 1) _ = dl.WriteChars(MSG_BLANKS, tab_size);
                if (!is_dir) _ = dl.WriteChars(MSG_BLANKS, norm_indent);
                const own: [*:0]const u8 = @ptrCast(&ap.info.file_name);
                _ = dl.PutStr(if (own[0] != 0) own else name);
                if (is_dir) _ = dl.PutStr(MSG_DIR);
                _ = dl.PutStr("..");
            }
        }

        var mask = umask;
        if (add or sub) {
            // The bits as the user thinks of them, RWED the right way up.
            const old = ap.info.protection ^ reverse_bits;
            if (add) mask |= old else mask &= old;
        }
        mask ^= reverse_bits;

        // SetProtection works from the name, so the entry's own directory
        // has to be the current one while it runs.
        const here = dl.CurrentDir(if (ap.last) |node| node.lock else null);
        const own: [*:0]const u8 = @ptrCast(&ap.info.file_name);
        if (mask != ap.info.protection and !dl.SetProtection(own, mask)) {
            rc = dos.RETURN_FAIL;
            err = dl.IoErr();
            failed_path = @ptrCast(ap.buffer());
            _ = dl.PutStr("\n");
        } else if (named and !quiet) {
            _ = dl.PutStr(MSG_DONE);
        }
        _ = dl.CurrentDir(here);

        if (err == 0) err = dl.MatchNext(&anchor.ap);
    }

    if (err == dos.ERROR_NO_MORE_ENTRIES) {
        err = 0;
        rc = dos.RETURN_OK;
    } else if (err == dos.ERROR_BREAK) {
        rc = dos.RETURN_WARN;
    }

    if (failed_path) |path| _ = Printf(dl, MSG_SETFAILED, .{path});
    if (err != 0) _ = dl.PrintFault(err, null);
    _ = dl.SetIoErr(err);
    return rc;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
