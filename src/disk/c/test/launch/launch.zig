// SPDX-License-Identifier: MIT
//! Launch: starts a program with files the way the desktop does, and
//! waits for it to end. Built against the SDK only.
//!
//!   Launch TOOL/A,FILES/M,STACK/K/N,PRI/K/N
//!
//! TOOL runs in a shell of its own, beside the one Launch runs in. Its
//! files go to it twice: on its command line, each full name quoted
//! (dos.rdargs.quote), for ReadArgs; and as lock-and-name pairs
//! (NP_ArgList) - TOOL itself first, then each file as a lock on its
//! drawer and its name, a drawer or a volume as a lock on itself and an
//! empty name - for GetArgList. Its input is NIL:, its output a console
//! that opens only when it prints and stays until it is closed. STACK and
//! PRI are its stack and priority. Launch hears of the end through the
//! shell's exit hook (NP_ExitCode), and says so; Ctrl-C stops waiting.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Launch";
const VERSION_STRING = "\x00$VER: Launch 1.0 (08.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TOOL/A,FILES/M,STACK/K/N,PRI/K/N";
const arg_tool = 0;
const arg_files = 1;
const arg_stack = 2;
const arg_pri = 3;

/// The most files handed on, and the longest command line made.
const files_max = 16;
const line_max = 4096;

/// What the exit hook is handed: who to tell, and how.
const Told = struct {
    sys: *ExecBase,
    task: *exec.Task,
    signal: u5,
};

/// Runs on the started shell's process as it ends: a signal, nothing
/// that waits.
fn ended(return_code: i32, data: isize) callconv(.c) i32 {
    _ = return_code;
    const told: *const Told = @ptrFromInt(@as(usize, @bitCast(data)));
    told.sys.Signal(told.task, @as(u32, 1) << told.signal);
    return 0;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const tool: [*:0]const u8 = @ptrFromInt(argv[arg_tool]);
    const given = dos.rdargs.multi(argv[arg_files]);
    const names = given[0..@min(given.len, files_max)];

    // The pairs: the tool, then each file. Each lock is Launch's until the
    // end; CreateNewProc makes the shell copies of its own.
    var pairs: [files_max + 1]dos.WBArg = undefined;
    var spelled: [files_max + 1][dos.name_max + 1]u8 = undefined;
    var count: usize = 0;
    defer for (pairs[0..count]) |pair| dl.UnLock(pair.lock);
    if (!pairOf(sys, dl, tool, &pairs[count], &spelled[count])) return fault(dl, tool);
    count += 1;
    for (names) |name| {
        if (!pairOf(sys, dl, name, &pairs[count], &spelled[count])) return fault(dl, name);
        count += 1;
    }

    // The line: each full name, quoted.
    const line_memory = sys.AllocVec(line_max, exec.MEMF_ANY) orelse return dos.RETURN_FAIL;
    defer sys.FreeVec(line_memory);
    const line: [*]u8 = @ptrCast(line_memory);
    var at: usize = 0;
    for (pairs[0..count]) |pair| {
        var full: [dos.path_max]u8 = @splat(0);
        if (!dl.NameFromLock(pair.lock, &full, full.len)) return fault(dl, tool);
        if (pair.name.?[0] != 0 and !dl.AddPart(@ptrCast(&full), pair.name.?, full.len)) return fault(dl, tool);
        var full_len: usize = 0;
        while (full[full_len] != 0) full_len += 1;
        if (at > 0) {
            line[at] = ' ';
            at += 1;
        }
        at += dos.rdargs.quote(line[at .. line_max - 2], full[0..full_len]) orelse {
            _ = Printf(dl, "%s: the names are too long for one line\n", .{COMMAND_NAME});
            return dos.RETURN_FAIL;
        };
    }
    line[at] = '\n';
    line[at + 1] = 0;

    // Its console, open only once it prints; NIL: for its input.
    var window: [160]u8 = undefined;
    const title = dl.FilePart(tool);
    const window_name = spell(&window, &.{ "CON:40/60/560/240/", title, "/AUTO/CLOSE/WAIT" });
    const output = dl.Open(window_name, dos.MODE_NEWFILE) orelse return fault(dl, window_name);
    const input = dl.Open("NIL:", dos.MODE_OLDFILE) orelse {
        _ = dl.Close(output);
        return fault(dl, "NIL:");
    };

    const signal = sys.AllocSignal(-1);
    if (signal < 0) {
        _ = dl.Close(input);
        _ = dl.Close(output);
        return dos.RETURN_FAIL;
    }
    defer sys.FreeSignal(signal);
    var told = Told{ .sys = sys, .task = sys.FindTask(null).?, .signal = @intCast(signal) };

    var tags: [12]TagItem = undefined;
    var tag_count: usize = 0;
    const add = struct {
        fn one(into: []TagItem, at_tag: *usize, tag: u32, data: usize) void {
            into[at_tag.*] = .{ .tag = tag, .data = data };
            at_tag.* += 1;
        }
    }.one;
    add(&tags, &tag_count, dos.SYS_Asynch, 1);
    add(&tags, &tag_count, dos.SYS_Input, @intFromPtr(input));
    add(&tags, &tag_count, dos.SYS_Output, @intFromPtr(output));
    add(&tags, &tag_count, dos.NP_ArgList, @intFromPtr(&pairs));
    add(&tags, &tag_count, dos.NP_NumArgs, count);
    add(&tags, &tag_count, dos.NP_ExitCode, @intFromPtr(&ended));
    add(&tags, &tag_count, dos.NP_ExitData, @intFromPtr(&told));
    if (dos.rdargs.number(argv[arg_stack])) |stack| add(&tags, &tag_count, dos.NP_StackSize, @intCast(@max(stack, 0)));
    if (dos.rdargs.number(argv[arg_pri])) |pri| add(&tags, &tag_count, dos.NP_Priority, @bitCast(@as(isize, pri)));
    tags[tag_count] = .{};

    _ = Printf(dl, "starting %s", .{@as([*:0]const u8, @ptrCast(line))});
    _ = dl.Flush(dl.Output());
    if (dl.SystemTagList(@ptrCast(line), &tags) < 0) {
        const failure = dl.IoErr();
        _ = dl.Close(input);
        _ = dl.Close(output);
        _ = dl.PrintFault(failure, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }

    const got = sys.Wait((@as(u32, 1) << @intCast(signal)) | exec.SIGBREAKF_CTRL_C);
    if (got & (@as(u32, 1) << @intCast(signal)) != 0) {
        _ = Printf(dl, "%s has ended\n", .{title});
    } else {
        // It runs on and will signal a task that has gone: wait for it
        // after all, since its exit hook reads `told` on this stack.
        _ = Printf(dl, "waiting for %s to end, as its exit hook needs this program\n", .{title});
        _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    }
    return dos.RETURN_OK;
}

/// A name as the desktop hands it on: a file as a lock on its drawer and
/// its name, a drawer or a volume as a lock on itself and an empty name.
fn pairOf(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8, pair: *dos.WBArg, spelled: *[dos.name_max + 1]u8) bool {
    const lock = dl.Lock(name, dos.SHARED_LOCK) orelse return false;
    const memory = sys.AllocVec(@sizeOf(dos.FileInfoBlock), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        dl.UnLock(lock);
        return false;
    };
    defer sys.FreeVec(memory);
    const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(memory));
    if (!dl.Examine(lock, fib)) {
        dl.UnLock(lock);
        return false;
    }
    if (fib.dir_entry_type > 0) {
        spelled[0] = 0;
        pair.* = .{ .lock = lock, .name = @ptrCast(spelled) };
        return true;
    }
    const parent = dl.ParentDir(lock);
    dl.UnLock(lock);
    const drawer = parent orelse return false;
    @memcpy(spelled, &fib.file_name);
    pair.* = .{ .lock = drawer, .name = @ptrCast(spelled) };
    return true;
}

fn spell(into: *[160]u8, parts: []const [*:0]const u8) [*:0]const u8 {
    var at: usize = 0;
    for (parts) |part| {
        var index: usize = 0;
        while (part[index] != 0 and at < into.len - 1) : (index += 1) {
            into[at] = part[index];
            at += 1;
        }
    }
    into[at] = 0;
    return @ptrCast(into);
}

fn fault(dl: *DosBase, name: [*:0]const u8) i32 {
    _ = dl.PrintFault(dl.IoErr(), name);
    return dos.RETURN_FAIL;
}
