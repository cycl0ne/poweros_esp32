// SPDX-License-Identifier: MPL-2.0
//! PIPE, the shell's built-in behind `a | b`: it splits its line at the pipe
//! character and runs each part as its own shell, with a PIPE: channel
//! between one's output and the next one's input (src/rom/handler/pipe).
//!
//! On seeing the character (the local variable `_pchar`) the shell hands
//! the whole line to the command called PIPE, which is this one. It is a
//! built-in, not a program on disk, because `|` works
//! from the first prompt, before there is anything to load from.
//!
//! Every stage but the last is started with SystemTagList and runs on its
//! own; the last runs here, so the shell waits for the pipeline the way it
//! waits for any command, and its return code is the pipeline's.
//!
//! The channels are named `PIPE:p<cli>-<n>`: a channel without a name can't
//! be opened a second time, and the two sides of a junction are two opens.
//! Both ends are opened here, before any stage starts, so a writer never
//! finds itself without a reader.
//!
//! The first stage reads NIL:, as Run's command does: the terminal's input
//! belongs to the shell that is waiting for the pipeline.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "PIPE";

/// Commands in one line, so `a | b | c` is three.
const max_stages = 8;
const max_line = 512;

/// The pipe character: the local `_pchar`, "|" without one.
pub fn pipeChar(dl: *DosBase) u8 {
    var value: [8]u8 = undefined;
    if (dl.GetVar("_pchar", &value, value.len - 1, dos.LV_VAR | dos.GVF_LOCAL_ONLY) <= 0) return '|';
    return value[0];
}

fn fail(dl: *DosBase, code: i32) i32 {
    _ = dl.PrintFault(code, COMMAND_NAME);
    _ = dl.SetIoErr(code);
    return dos.RETURN_FAIL;
}

pub fn run(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    // The line RunCommand lent us, without its newline.
    var line: [max_line]u8 = @splat(0);
    const n = @min(len, max_line - 1);
    @memcpy(line[0..n], args[0..n]);
    var text: []u8 = line[0..n];
    while (text.len > 0 and (text[text.len - 1] == '\n' or text[text.len - 1] == '\r')) text = text[0 .. text.len - 1];

    // Split at the pipe character, outside quotes; each part becomes a C
    // string where the character was.
    const pc = pipeChar(dl);
    var stages: [max_stages][*:0]u8 = undefined;
    var count: usize = 0;
    var start: usize = 0;
    var quoted = false;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const end = i == text.len;
        const c = if (end) 0 else text[i];
        if (!end and c == '"') quoted = !quoted;
        if (!end and (c != pc or quoted)) continue;
        if (count == max_stages) return fail(dl, dos.ERROR_LINE_TOO_LONG);
        if (!end) text[i] = 0;
        var part = line[start..i];
        while (part.len > 0 and (part[0] == ' ' or part[0] == '\t')) part = part[1..];
        if (part.len == 0) return fail(dl, dos.ERROR_LINE_TOO_LONG); // "a || b"
        stages[count] = @ptrCast(part.ptr);
        count += 1;
        start = i + 1;
    }
    if (count == 0) return dos.RETURN_OK;

    const me: *dos.Process = @fieldParentPtr("task", sys.FindTask(null).?);
    // A channel per junction, both ends open before anything starts.
    var writers: [max_stages]?*dos.FileHandle = @splat(null);
    var readers: [max_stages]?*dos.FileHandle = @splat(null);
    var made: usize = 0;
    while (made + 1 < count) : (made += 1) {
        var name: [40]u8 = undefined;
        const channel = std.fmt.bufPrintZ(&name, "PIPE:p{d}-{d}", .{ me.task_num, made }) catch unreachable;
        writers[made] = dl.Open(channel.ptr, dos.MODE_NEWFILE);
        if (writers[made] != null) readers[made] = dl.Open(channel.ptr, dos.MODE_OLDFILE);
        if (readers[made] == null) {
            const err = dl.IoErr();
            closeAll(dl, &writers, &readers, made + 1);
            return fail(dl, if (err != 0) err else dos.ERROR_NO_FREE_STORE);
        }
    }

    // Every stage but the last on its own; the last one here, so the shell
    // waits for it. An asynchronous shell closes the streams it was given,
    // which is what lets the next stage see the end of its input.
    var rc: i32 = dos.RETURN_OK;
    var stage: usize = 0;
    while (stage < count) : (stage += 1) {
        const last = stage + 1 == count;
        const input: ?*dos.FileHandle = if (stage == 0)
            dl.Open("NIL:", dos.MODE_OLDFILE)
        else
            readers[stage - 1];
        const output: ?*dos.FileHandle = if (last) dl.Output() else writers[stage];
        const tags = [_]sdk.utility.TagItem{
            .{ .tag = dos.SYS_Input, .data = @intFromPtr(input) },
            .{ .tag = dos.SYS_Output, .data = @intFromPtr(output) },
            .{ .tag = dos.SYS_Asynch, .data = if (last) 0 else 1 },
            .{ .tag = dos.SYS_UserShell, .data = 1 },
            .{},
        };
        const res = dl.SystemTagList(stages[stage], &tags);
        if (last) {
            // Ours to close: a shell that waits closes nothing.
            if (count > 1) _ = dl.Close(readers[count - 2]);
            readers[count - 2] = null;
            if (res < 0) {
                const err = dl.IoErr();
                return fail(dl, if (err != 0) err else dos.ERROR_NO_FREE_STORE);
            }
            rc = res;
        } else if (res < 0) {
            const err = dl.IoErr();
            // The stages that did start close their own; these never will.
            if (input) |fh| _ = dl.Close(fh);
            closeAll(dl, &writers, &readers, count - 1);
            return fail(dl, if (err != 0) err else dos.ERROR_NO_FREE_STORE);
        }
    }
    return rc;
}

/// The handles of junctions nobody took over.
fn closeAll(dl: *DosBase, writers: *[max_stages]?*dos.FileHandle, readers: *[max_stages]?*dos.FileHandle, made: usize) void {
    for (writers[0..made], readers[0..made]) |*w, *r| {
        if (w.*) |fh| _ = dl.Close(fh);
        if (r.*) |fh| _ = dl.Close(fh);
        w.* = null;
        r.* = null;
    }
}
