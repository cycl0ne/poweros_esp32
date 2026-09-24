// SPDX-License-Identifier: MIT
//! TestLib: open a library and call it, to see that a module which was
//! never in the ROM is a library like any other. Built against the SDK
//! only.
//!
//!   TestLib LIBRARY,VERSION/N,QUIET/S
//!
//! With nothing named it asks for `hello.library`, which is on the disk in
//! `LIBS:` and in no ROM. Opening it is an ordinary `OpenLibrary`: the name
//! is on no list, ramlib loads the file, finds the tag in it, lets exec
//! make the library, and the open answers with a base. Nothing here knows
//! any of that happened.
//!
//! What it then does is the half that a loaded library cannot prove about
//! itself: it calls a function through the jump table from outside, in
//! another program's process, and prints what comes back. A library that
//! was loaded has code in memory that was written through the data bus and
//! is run through the instruction bus; if the loader had got that wrong the
//! call would land somewhere that is not a function.
//!
//! A real library has a `.fd` and a generated interface, and a caller says
//! `hb.Hello()`. This one is a demonstration and has neither, so it names
//! the slot itself - which is all an interface does.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "TestLib";
const VERSION_STRING = "\x00$VER: TestLib 1.0 (17.9.2026)\r\n";

const template = "LIBRARY,VERSION/N,QUIET/S";
const arg_library = 0;
const arg_version = 1;
const arg_quiet = 2;

/// What it asks for when nothing is named: the module that is only ever on
/// the disk.
const DEFAULT_LIBRARY = "hello.library";

/// hello.library's one function, in the first slot after the standard
/// four. A library with an interface of its own says this in its `.fd`.
const HelloFn = *const fn (*exec.Library) callconv(.c) [*:0]const u8;
const LVO_HELLO = exec.libraries.lvo(4);

const MSG_NOOPEN = "%s: cannot open %s version %d\n";
const MSG_OPENED = "%s %d.%d opened at 0x%08x, open count %d\n";
const MSG_ANSWER = "%s() says: %s\n";
const MSG_NOCALL = "%s has no function this command knows; opened it only\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const name: [*:0]const u8 = if (argv[arg_library] != 0)
        @ptrFromInt(argv[arg_library])
    else
        DEFAULT_LIBRARY;
    const version: u32 = if (argv[arg_version] != 0) blk: {
        const asked: *const i32 = @ptrFromInt(argv[arg_version]);
        break :blk if (asked.* < 0) 0 else @intCast(asked.*);
    } else 0;
    const quiet = argv[arg_quiet] != 0;

    // An ordinary open. Whether it comes off a list or off a disk is not
    // this program's business, which is the point.
    const lib = sys.OpenLibrary(name, version) orelse {
        _ = Printf(dl, MSG_NOOPEN, .{ COMMAND_NAME, name, version });
        return dos.RETURN_ERROR;
    };
    defer sys.CloseLibrary(lib);

    if (!quiet) {
        _ = Printf(dl, MSG_OPENED, .{
            lib.name(),
            lib.version,
            lib.revision,
            @intFromPtr(lib),
            lib.open_cnt,
        });
    }

    // Only the library this command knows the shape of: the slot of any
    // other library holds something else entirely, and calling it would be
    // a way of finding that out the hard way.
    if (!sameName(lib.name(), DEFAULT_LIBRARY)) {
        if (!quiet) _ = Printf(dl, MSG_NOCALL, .{lib.name()});
        return dos.RETURN_OK;
    }

    const hello = lib.vector(HelloFn, LVO_HELLO);
    _ = Printf(dl, MSG_ANSWER, .{ "Hello", hello(lib) });
    return dos.RETURN_OK;
}

fn sameName(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (true) : (i += 1) {
        const x = lower(a[i]);
        const y = lower(b[i]);
        if (x != y) return false;
        if (x == 0) return true;
    }
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// The "$VER:" string every module carries, which `Version <file>` looks
/// for. Nothing refers to it, so it needs an export and a section of its
/// own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
