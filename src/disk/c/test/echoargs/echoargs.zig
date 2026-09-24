// SPDX-License-Identifier: MIT
//! echoargs: a program on disk (disk/c), built as a load file by
//! sdk/tools/elf2seg and run by the shell through LoadSeg. It reads its
//! arguments with ReadArgs ("ITEMS/M,QUIET/S,N=NUMBER/N") from Input(),
//! where RunCommand put the argument line, and prints them, GetArgStr's
//! line and the stack it runs on to Output(). Its return code is the number
//! of items. Built against the SDK only.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "echoargs";
const VERSION_STRING = "\x00$VER: echoargs 1.0 (16.9.2026)\r\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs("ITEMS/M,QUIET/S,N=NUMBER/N", &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const items = rdargs.multi(argv[0]);
    for (items, 1..) |item, i| _ = Printf(dl, "item %u: %s\n", .{ @as(u32, @intCast(i)), item });
    if (argv[1] != 0) _ = Printf(dl, "QUIET\n", .{});
    if (rdargs.number(argv[2])) |n| _ = Printf(dl, "NUMBER %d\n", .{n});
    if (dl.GetArgStr()) |line| _ = Printf(dl, "line: %s", .{line});
    const task = sys.FindTask(null).?;
    _ = Printf(dl, "stack at 0x%08x in 0x%08x..0x%08x\n", .{
        @as(u32, @truncate(@frameAddress())),
        @as(u32, @truncate(task.sp_lower)),
        @as(u32, @truncate(task.sp_upper)),
    });
    _ = dl.Flush(dl.Output());
    return @intCast(items.len);
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs: the linker collects unused
/// sections, and a plain constant never reaches the file at all - which is
/// all the comptime reference that used to stand here achieved.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
