// SPDX-License-Identifier: MIT
//! Shell: a shell in a window of its own, from an icon. Built against the
//! SDK only.
//!
//!   Shell WINDOW/K,FROM/K
//!
//! Double-clicked on the desktop, it reads its own icon: WINDOW is the
//! console the shell talks on (CON:0/0//300/PowerOS Shell/CLOSE unless
//! given), FROM the script it reads first (S:Shell-Startup, when there is
//! one, unless given). Run from a shell, the same come as its arguments,
//! and they win over the icon's. The shell starts in SYS: and runs on
//! after Shell has returned; Shell prints nothing, so the desktop's
//! console for it never opens.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const icon = sdk.icon;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IconBase = sdk.interface.icon.IconBase;
const rdargs = dos.rdargs;

pub const COMMAND_NAME = "Shell";
const VERSION_STRING = "\x00$VER: Shell 1.0 (09.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "WINDOW/K,FROM/K";
const arg_window = 0;
const arg_from = 1;

const default_window = "CON:0/0//300/PowerOS Shell/CLOSE";
const default_from = "S:Shell-Startup";

/// What the icon says, copied out of it.
const Asked = struct {
    window: [dos.path_max + 1:0]u8 = @splat(0),
    from: [dos.path_max + 1:0]u8 = @splat(0),
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const memory = sys.AllocVec(@sizeOf(Asked), exec.MEMF_CLEAR) orelse return dos.RETURN_FAIL;
    defer sys.FreeVec(memory);
    const asked: *Asked = @ptrCast(@alignCast(memory));
    asked.* = .{};
    readIcon(sys, dl, asked);
    const window: [*:0]const u8 = rdargs.string(argv[arg_window]) orelse if (asked.window[0] != 0) &asked.window else default_window;
    const named_from: ?[*:0]const u8 = rdargs.string(argv[arg_from]) orelse if (asked.from[0] != 0) &asked.from else null;

    // FROM must be there when it is named; the usual script only if it is.
    const script: ?*dos.FileHandle = if (named_from) |from|
        dl.Open(from, dos.MODE_OLDFILE) orelse {
            const code = dl.IoErr();
            _ = dl.PrintFault(code, from);
            return dos.RETURN_ERROR;
        }
    else
        dl.Open(default_from, dos.MODE_OLDFILE);

    // In SYS:, for the shell to inherit; this process's own put back.
    const home = dl.Lock("SYS:", dos.SHARED_LOCK);
    const old = if (home) |lock| dl.CurrentDir(lock) else null;
    defer if (home) |lock| {
        _ = dl.CurrentDir(old);
        dl.UnLock(lock);
    };
    const tags = [_]utility.TagItem{
        .{ .tag = dos.SYS_Window, .data = @intFromPtr(window) },
        .{ .tag = dos.SYS_Asynch, .data = 1 },
        .{ .tag = dos.SYS_UserShell, .data = 1 },
        .{ .tag = dos.SYS_ScriptFile, .data = @intFromPtr(script) },
        .{},
    };
    if (dl.SystemTagList(null, &tags) < 0) {
        const code = dl.IoErr();
        if (script) |file| _ = dl.Close(file);
        _ = dl.PrintFault(code, COMMAND_NAME);
        return dos.RETURN_ERROR;
    }
    return dos.RETURN_OK;
}

/// WINDOW and FROM from the program's own icon, when it was started with
/// one: the first file it was handed is itself.
fn readIcon(sys: *ExecBase, dl: *DosBase, asked: *Asked) void {
    var count: u32 = 0;
    const files = dl.GetArgList(&count) orelse return;
    if (count == 0) return;
    const program = files[0];
    const name = program.name orelse return;
    const icon_lib = sys.OpenLibrary(icon.ICONNAME, 1) orelse return;
    defer sys.CloseLibrary(icon_lib);
    const ib: *IconBase = @ptrCast(icon_lib);
    const old = dl.CurrentDir(program.lock);
    defer _ = dl.CurrentDir(old);
    const object = ib.GetDiskObject(name) orelse return;
    defer ib.FreeDiskObject(object);
    if (ib.FindToolType(object.tool_types, "WINDOW")) |text| copy(&asked.window, text);
    if (ib.FindToolType(object.tool_types, "FROM")) |text| copy(&asked.from, text);
}

fn copy(into: *[dos.path_max + 1:0]u8, text: [*:0]const u8) void {
    var length: usize = 0;
    while (text[length] != 0 and length < dos.path_max) : (length += 1) into[length] = text[length];
    into[length] = 0;
}
