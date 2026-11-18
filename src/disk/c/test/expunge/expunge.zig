// SPDX-License-Identifier: MIT
//! Expunge: libraries and devices nobody has open expunged one at a time,
//! by name, or one low-memory handler asked for all it can give - to find
//! which of them a machine does not come back from. Built against the SDK
//! only.
//!
//!   Expunge NAME/M,HANDLER/K
//!
//! Each NAME is looked for among the libraries, then the devices. Its
//! name is written out before it is asked to go (RemLibrary, RemDevice),
//! and after that whether it went or stays; one that is open is only
//! said to be. HANDLER names a memory handler on exec's list - exec's own
//! is "library flusher", diskfont.library's has the library's name - and
//! runs it alone, as FlushMemory runs each: with MEMHF_FLUSH, and again
//! with MEMHF_RECYCLE while it answers MEM_TRY_AGAIN.
//!
//! Every line is flushed as it is written, so over a remote shell the
//! last one that arrives names what was under way when the machine
//! stopped - which a screen that shows a frame drawn earlier may not.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;
const rdargs = dos.rdargs;

pub const COMMAND_NAME = "Expunge";
const VERSION_STRING = "\x00$VER: Expunge 1.0 (18.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "NAME/M,HANDLER/K";
const arg_name = 0;
const arg_handler = 1;

/// How often a handler is asked again with MEMHF_RECYCLE before it is
/// taken to free forever.
const most_rounds = 100_000;

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

    var result: i32 = dos.RETURN_OK;
    if (argv[arg_handler] != 0) {
        const name: [*:0]const u8 = @ptrFromInt(argv[arg_handler]);
        if (!runHandler(sys, dl, name)) result = dos.RETURN_WARN;
    }
    for (rdargs.multi(argv[arg_name])) |name| {
        if (!expungeOne(sys, dl, name)) result = dos.RETURN_WARN;
    }
    return result;
}

/// A line out at once.
fn say(dl: *DosBase, comptime format: [:0]const u8, values: anytype) void {
    _ = Printf(dl, format, values);
    _ = dl.Flush(dl.Output());
}

/// The library or device of that name, and its open count, looked up
/// under exec's list lock and let go of again: RemLibrary takes the list
/// itself.
fn find(sys: *ExecBase, which: u32, name: [*:0]const u8) ?struct { lib: *exec.Library, open: u32 } {
    const list = sys.LockExecList(which) orelse return null;
    defer sys.UnlockExecList(which);
    const node = sys.FindName(list, name) orelse return null;
    const lib: *exec.Library = @fieldParentPtr("node", node);
    return .{ .lib = lib, .open = lib.open_cnt };
}

/// Whether `lib` is still on list `which` - by address only.
fn stillThere(sys: *ExecBase, which: u32, lib: *exec.Library) bool {
    const list = sys.LockExecList(which) orelse return false;
    defer sys.UnlockExecList(which);
    var it = list.iterator();
    while (it.next()) |node| {
        if (@intFromPtr(node) == @intFromPtr(&lib.node)) return true;
    }
    return false;
}

/// One library or device asked to go. False when there is none of that
/// name.
fn expungeOne(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8) bool {
    const which: u32, const found = if (find(sys, exec.EXECLIST_LIBRARIES, name)) |library|
        .{ exec.EXECLIST_LIBRARIES, library }
    else if (find(sys, exec.EXECLIST_DEVICES, name)) |device|
        .{ exec.EXECLIST_DEVICES, device }
    else {
        say(dl, "%s: no such library or device\n", .{name});
        return false;
    };
    if (found.open != 0) {
        say(dl, "%s: open %u times, left alone\n", .{ name, found.open });
        return true;
    }
    const before = sys.AvailMem(exec.MEMF_ANY);
    say(dl, "%s: expunging ... ", .{name});
    if (which == exec.EXECLIST_LIBRARIES) {
        _ = sys.RemLibrary(found.lib);
    } else {
        _ = sys.RemDevice(found.lib);
    }
    if (stillThere(sys, which, found.lib)) {
        say(dl, "stays\n", .{});
    } else {
        say(dl, "expunged, %zd bytes freed\n", .{sys.AvailMem(exec.MEMF_ANY) -| before});
    }
    return true;
}

/// One memory handler run alone until it has nothing more. False when
/// there is none of that name.
fn runHandler(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8) bool {
    const before = sys.AvailMem(exec.MEMF_ANY);
    const list = sys.LockExecList(exec.EXECLIST_MEM_HANDLERS) orelse return false;
    defer sys.UnlockExecList(exec.EXECLIST_MEM_HANDLERS);
    const node = sys.FindName(list, name) orelse {
        say(dl, "%s: no such memory handler\n", .{name});
        return false;
    };
    const handler: *exec.Interrupt = @fieldParentPtr("node", node);
    const code: exec.MemHandlerFn = @ptrCast(@alignCast(handler.code.?));
    var data: exec.MemHandlerData = .{
        .request_size = ~@as(u32, 0),
        .request_flags = exec.MEMF_ANY,
        .flags = exec.MEMHF_FLUSH,
    };
    say(dl, "%s: running ... ", .{name});
    var rounds: u32 = 1;
    while (code(&data, handler.data) == exec.MEM_TRY_AGAIN) : (rounds += 1) {
        if (rounds == most_rounds) {
            say(dl, "still freeing after %u rounds, stopped\n", .{rounds});
            return true;
        }
        data.flags = exec.MEMHF_FLUSH | exec.MEMHF_RECYCLE;
    }
    say(dl, "done in %u rounds, %zd bytes freed\n", .{ rounds, sys.AvailMem(exec.MEMF_ANY) -| before });
    return true;
}
