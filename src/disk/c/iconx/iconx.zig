// SPDX-License-Identifier: MIT
//! IconX: a script run from its icon. Built against the SDK only.
//!
//!   IconX SCRIPT/A,FILES/M
//!
//! The desktop runs a script - a file with its script bit and no tool of
//! its own - through IconX, the script first and the other icons picked
//! after it. IconX runs it with `Execute` in a shell of its own, on a
//! console of its own, the other files its arguments, and with `FailAt
//! 100` so a command that fails does not end it. The script's icon says
//! how, in its tool types:
//!
//!   WINDOW=<console>  the console (CON:0/50//80/IconX/AUTO unless given:
//!                     it opens when the script reads or prints)
//!   STACK=<bytes>     the stack its commands run on
//!   WAIT=<seconds>    how long the console stays after the script ends;
//!                     0 keeps it until it is closed
//!   DELAY=<ticks>     the same in fiftieths of a second, without WAIT
//!
//! Without WAIT or DELAY the console stays two seconds. The return code is
//! the script's.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const icon = sdk.icon;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IconBase = sdk.interface.icon.IconBase;
const rdargs = dos.rdargs;

pub const COMMAND_NAME = "IconX";
const VERSION_STRING = "\x00$VER: IconX 1.0 (09.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "SCRIPT/A,FILES/M";
const arg_script = 0;
const arg_files = 1;

const default_window = "CON:0/50//80/IconX/AUTO";
/// Ticks a second.
const ticks_per_second = 50;
/// How long the console stays without WAIT or DELAY: two seconds.
const default_delay = 2 * ticks_per_second;
/// The longest command made.
const line_max = 2048;

/// What the script's icon asks for.
const Asked = struct {
    window: [dos.path_max + 1:0]u8 = @splat(0),
    stack: u32 = 0,
    /// Ticks the console stays; null keeps it until it is closed.
    delay: ?u32 = default_delay,
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
    const script = rdargs.string(argv[arg_script]) orelse return dos.RETURN_FAIL;

    // Too big for a command's stack: in memory of its own.
    const memory = sys.AllocVec(@sizeOf(Asked) + line_max, exec.MEMF_CLEAR) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const asked: *Asked = @ptrCast(@alignCast(memory));
    asked.* = .{};
    const line: []u8 = (@as([*]u8, @ptrCast(memory)) + @sizeOf(Asked))[0..line_max];
    @memcpy(asked.window[0..default_window.len], default_window);
    readIcon(sys, script, asked);

    // FailAt 100, then Execute with the script and its files, quoted.
    const head = "FailAt 100\nExecute ";
    @memcpy(line[0..head.len], head);
    var at: usize = head.len;
    at += rdargs.quote(line[at .. line_max - 2], textOf(script)) orelse return tooLong(dl);
    for (rdargs.multi(argv[arg_files])) |file| {
        line[at] = ' ';
        at += 1;
        at += rdargs.quote(line[at .. line_max - 2], textOf(file)) orelse return tooLong(dl);
    }
    line[at] = '\n';
    line[at + 1] = 0;

    // The console, both ways: the shell is given the one handle, and it
    // is closed here once the script is done and the delay is over.
    if (asked.delay == null) appendWait(&asked.window);
    const console = dl.Open(&asked.window, dos.MODE_OLDFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), &asked.window);
        return dos.RETURN_FAIL;
    };
    defer _ = dl.Close(console);
    const tags = [_]utility.TagItem{
        .{ .tag = dos.SYS_Input, .data = @intFromPtr(console) },
        .{ .tag = dos.SYS_Output, .data = @intFromPtr(console) },
        .{ .tag = if (asked.stack != 0) dos.NP_StackSize else utility.TAG_IGNORE, .data = asked.stack },
        .{},
    };
    const code = dl.SystemTagList(@ptrCast(line.ptr), &tags);
    if (code < 0) {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    if (asked.delay) |ticks| {
        if (ticks > 0) dl.Delay(ticks);
    }
    return code;
}

/// The script's icon's tool types, when it has an icon.
fn readIcon(sys: *ExecBase, script: [*:0]const u8, asked: *Asked) void {
    const icon_lib = sys.OpenLibrary(icon.ICONNAME, 1) orelse return;
    defer sys.CloseLibrary(icon_lib);
    const ib: *IconBase = @ptrCast(icon_lib);
    const object = ib.GetDiskObject(script) orelse return;
    defer ib.FreeDiskObject(object);
    const types = object.tool_types;
    if (ib.FindToolType(types, "WINDOW")) |window| {
        const text = textOf(window);
        if (text.len > 0 and text.len < asked.window.len - 12) {
            @memcpy(asked.window[0..text.len], text);
            asked.window[text.len] = 0;
        }
    }
    if (ib.FindToolType(types, "STACK")) |stack| {
        if (number(textOf(stack))) |bytes| asked.stack = bytes;
    }
    if (ib.FindToolType(types, "WAIT")) |wait| {
        if (number(textOf(wait))) |seconds| asked.delay = if (seconds == 0) null else seconds * ticks_per_second;
    } else if (ib.FindToolType(types, "DELAY")) |delay| {
        if (number(textOf(delay))) |ticks| asked.delay = if (ticks == 0) null else ticks;
    }
}

/// The console made to stay until it is closed.
fn appendWait(window: *[dos.path_max + 1:0]u8) void {
    const length = textOf(window).len;
    const tail = "/CLOSE/WAIT";
    if (length + tail.len >= window.len) return;
    @memcpy(window[length..][0..tail.len], tail);
    window[length + tail.len] = 0;
}

/// A tool type's number, up to a million; null for anything else.
fn number(text: []const u8) ?u32 {
    if (text.len == 0 or text.len > 7) return null;
    var value: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return @min(value, 1_000_000);
}

fn tooLong(dl: *DosBase) i32 {
    _ = dl.PrintFault(dos.ERROR_LINE_TOO_LONG, COMMAND_NAME);
    return dos.RETURN_FAIL;
}

fn textOf(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}
