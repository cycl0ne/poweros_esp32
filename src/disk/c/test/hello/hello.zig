// SPDX-License-Identifier: MIT
//! hello: the first program loaded from a file instead of the ROM.
//!
//! It is built for the same target as the kernel but linked on its own
//! (program.ld) and turned into a load file by sdk/tools/elf2seg, which
//! dos.library's LoadSeg reads. `_program_entry` is a dos CommandFn, so the
//! shell runs it through RunCommand like any other command: it reads its
//! arguments with ReadArgs from Input(), where RunCommand put the line.
//!
//! What it proves: the code runs where the loader put it (PSRAM, through
//! the instruction bus), a call through a relocated address works, and
//! strings and variables of its own are reachable.

const sdk = @import("sdk");
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

const NAME = "hello";
const VERSION_STRING = "\x00$VER: hello 1.0 (16.9.2026)\r\n";

/// Its own data: a string in the data segment, and a counter in bss.
const greeting: [:0]const u8 = "hello from a loaded program";
var runs: u32 = 0;

/// Called through a pointer that the loader relocated.
fn total(items: []const [*:0]const u8) u32 {
    var n: u32 = 0;
    for (items) |item| {
        var p = item;
        while (p[0] != 0) : (p += 1) n += 1;
    }
    return n;
}

const Counter = *const fn (items: []const [*:0]const u8) u32;
var counter: Counter = &total;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs("WORDS/M,QUIET/S", &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);

    runs +%= 1;
    const words = rdargs.multi(argv[0]);
    if (argv[1] == 0) {
        _ = Printf(dl, "%s (run %u, %u words, %u characters)\n", .{
            greeting,
            runs,
            @as(u32, @intCast(words.len)),
            counter(words),
        });
    }
    for (words, 1..) |word, i| _ = Printf(dl, "  %u: %s\n", .{ @as(u32, @intCast(i)), word });
    _ = dl.Flush(dl.Output());
    return @intCast(words.len);
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs: the linker collects unused
/// sections, and a plain constant never reaches the file at all - which is
/// all the comptime reference that used to stand here achieved.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
