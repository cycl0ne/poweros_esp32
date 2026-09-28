// SPDX-License-Identifier: MIT
//! Log: shows, follows and saves the system log. Built against the SDK
//! only.
//!
//!   Log LINES/N,FOLLOW/S,SAVE/S,TO/K
//!
//!   Log                 everything exec's ring still holds
//!   Log LINES 20        its last twenty lines
//!   Log FOLLOW          and then what comes, until Ctrl-C
//!   Log SAVE            into RAM:Log/system.log
//!   Log TO SD0:boot.log into that file
//!
//! The log is what the kernel and every module wrote to the raw port since
//! the boot, each line with its time and writer in front; exec keeps its
//! last 16 KiB (`ReadLog`). When the ring has already dropped the start of
//! the oldest line, that part-line is left out.
//!
//! FOLLOW asks exec for a signal when the log grows (`SetLogSignal`), at
//! most every ten ticks, and reads what came each time. Ctrl-C ends it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Log";
const VERSION_STRING = "\x00$VER: Log 1.0 (28.09.2026)\r\n";

const template = "LINES/N,FOLLOW/S,SAVE/S,TO/K";
const arg_lines = 0;
const arg_follow = 1;
const arg_save = 2;
const arg_to = 3;

/// Where SAVE writes without TO, and the drawer made for it.
const default_dir = "RAM:Log";
const default_file = "RAM:Log/system.log";

/// Room for the whole ring and what comes while it is read.
const buffer_size = 32 * 1024;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const memory = sys.AllocVec(buffer_size, exec.MEMF_ANY) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const buffer: [*]u8 = @ptrCast(memory);

    // Everything the ring holds, from its oldest byte.
    var position: u64 = 0;
    var total: usize = 0;
    while (total < buffer_size) {
        const count = sys.ReadLog(&position, buffer + total, @intCast(buffer_size - total));
        if (count == 0) break;
        total += count;
    }
    var text = buffer[0..total];
    // The ring dropped the start of its oldest line: leave that part out.
    if (position - total > 0) {
        var at: usize = 0;
        while (at < text.len and text[at] != '\n') at += 1;
        text = text[@min(at + 1, text.len)..];
    }

    const to = rdargs.string(argv[arg_to]);
    if (argv[arg_save] != 0 or to != null) {
        return save(dl, to orelse default_file, to == null, text);
    }

    if (rdargs.number(argv[arg_lines])) |lines| text = lastLines(text, if (lines < 0) 0 else @intCast(lines));
    _ = dl.Write(dl.Output(), text.ptr, @intCast(text.len));
    if (argv[arg_follow] == 0) return dos.RETURN_OK;
    return follow(sys, dl, &position, buffer);
}

/// The last `lines` lines of `text`, the line it ends in included.
fn lastLines(text: []u8, lines: u32) []u8 {
    var seen: u32 = 0;
    var at = text.len;
    // A final newline ends the last line rather than starting another.
    if (at > 0 and text[at - 1] == '\n') at -= 1;
    while (at > 0) : (at -= 1) {
        if (text[at - 1] == '\n') {
            seen += 1;
            if (seen == lines) break;
        }
    }
    return text[at..];
}

/// Writes `text` to `name`, making RAM:Log first when it is the default.
fn save(dl: *DosBase, name: [*:0]const u8, make_dir: bool, text: []const u8) i32 {
    if (make_dir) {
        // Already there is as good as made.
        if (dl.CreateDir(default_dir)) |lock| dl.UnLock(lock);
    }
    const file = dl.Open(name, dos.MODE_NEWFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), name);
        return dos.RETURN_FAIL;
    };
    const written = dl.Write(file, text.ptr, @intCast(text.len));
    _ = dl.Close(file);
    if (written != @as(isize, @intCast(text.len))) {
        _ = dl.PrintFault(dl.IoErr(), name);
        return dos.RETURN_FAIL;
    }
    _ = Printf(dl, "%lu bytes of the log to %s\n", .{ @as(u64, text.len), name });
    return dos.RETURN_OK;
}

/// What comes after `position`, as it comes, until Ctrl-C.
fn follow(sys: *ExecBase, dl: *DosBase, position: *u64, buffer: [*]u8) i32 {
    const bit = sys.AllocSignal(-1);
    if (bit < 0) {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    defer sys.FreeSignal(bit);
    const mask = @as(u32, 1) << @intCast(bit);
    if (!sys.SetLogSignal(null, mask)) {
        _ = Printf(dl, "%s: four tasks follow the log already\n", .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }
    defer _ = sys.SetLogSignal(null, 0);
    _ = dl.Flush(dl.Output());
    while (true) {
        const got = sys.Wait(mask | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            return dos.RETURN_WARN;
        }
        while (true) {
            const count = sys.ReadLog(position, buffer, buffer_size);
            if (count == 0) break;
            _ = dl.Write(dl.Output(), buffer, @intCast(count));
        }
        _ = dl.Flush(dl.Output());
    }
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
