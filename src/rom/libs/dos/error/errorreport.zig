// SPDX-License-Identifier: MPL-2.0
//! ErrorReport: the question an error deserves, and the answer.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const intuition = sdk.intuition;
const utility = sdk.utility;
const DosBase = @import("../dos_base.zig").DosBase;
const _error = @import("_error.zig");
const _process = @import("../process/_process.zig");
const _text = @import("../text/_text.zig");

/// The words of a question, built here so that neither way of asking has
/// to build them.
const line_max = 128;

/// Asks the user about an error, and answers whether to give up.
///
/// SYNOPSIS:
/// ```zig
/// fn ErrorReport(db: *DosBase, code: i32, report_type: u32, arg: usize, device: ?*MsgPort) bool
/// ```
///
/// SINCE: 1.1. LVO -552.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `code` - the error: `ERROR_DEVICE_NOT_MOUNTED` (which is the
///   "please insert" question), `ERROR_DISK_WRITE_PROTECTED`,
///   `ERROR_DISK_FULL`, `ERROR_DISK_NOT_VALIDATED`,
///   `ERROR_NOT_A_DOS_DISK`, `ERROR_NO_DISK`, `ABORT_DISK_ERROR`.
/// - `report_type` - what `arg` is: `REPORT_INSERT` a volume's name,
///   `REPORT_VOLUME` a DosList, `REPORT_LOCK` a FileLock,
///   `REPORT_STREAM` a FileHandle, `REPORT_TASK` a task.
/// - `arg` - as `report_type` says, 0 for none.
/// - `device` - the handler's port, or null. Not read yet; it is here so
///   that a question can one day say which drive it is about.
///
/// RESULT:
/// True when the user gave up, or when nothing could ask - a code with
/// no question, a process told not to be asked, no screen and no
/// console. False to try again.
///
/// BEHAVIOR:
/// The question goes up as a requester with Retry and Cancel on the
/// screen, and as a line of text on the process's own console when there
/// is no screen - a Shell on the serial line or over telnet has none, and
/// an error it can do nothing about is worse than one it can answer.
/// `Y`, `R` or Return retries there; anything else gives up.
///
/// A process whose `pr_WindowPtr` is -1 is never asked anything and this
/// answers true at once, which is how a program says it will handle its
/// own errors.
///
/// CONTEXT:
/// - Waits: for the answer, which is as long as the user takes; and for
///   intuition.library to open the first time a question goes on screen.
/// - Interrupts: no.
/// - Forbid: not held and not to be held.
/// - Process: a Process, not a bare Task: it reads `pr_WindowPtr` and
///   the process's console.
///
/// OWNERSHIP:
/// Nothing is kept. What `arg` points at is only read, and only while
/// the question is being built.
///
/// NOTES:
/// The caller retries what it was doing when this answers false; nothing
/// is retried here.
///
/// SEE ALSO:
/// `Fault`, `PrintFault`, `IoErr`
///
/// EXAMPLES:
/// ```zig
/// while (dos_lib.ErrorReport(dos.ERROR_DEVICE_NOT_MOUNTED, dos.REPORT_INSERT, @intFromPtr("Work"), null) == false) {
///     if (tryAgain()) break;
/// }
/// ```
pub fn ErrorReport(db: *DosBase, code: i32, report_type: u32, arg: usize, device: ?*exec.MsgPort) bool {
    _ = device;
    const question = _error.questionFor(code) orelse return true;
    const proc = _process.currentProcess(db.sys_base) orelse return true;
    if (@intFromPtr(proc.window_ptr) == _error.no_window) return true;

    var line: [line_max]u8 = @splat(0);
    const name = _error.volumeName(db, report_type, arg) orelse "";
    const len = build(db, &line, question, name);
    if (len == 0) return true;

    if (askOnScreen(db, proc, @ptrCast(&line))) |gave_up| return gave_up;
    if (askOnConsole(db, @ptrCast(&line))) |gave_up| return gave_up;
    return true;
}

/// The question's words, with the volume's name in them where it belongs.
/// How many bytes, 0 when it will not fit.
fn build(db: *DosBase, into: *[line_max]u8, question: _error.Question, name: [*:0]const u8) usize {
    var at: usize = 0;
    var i: usize = 0;
    const text = question.text;
    while (i < text.len) : (i += 1) {
        if (question.names_volume and text[i] == '%' and i + 1 < text.len and text[i + 1] == 's') {
            i += 1;
            var j: usize = 0;
            while (name[j] != 0) : (j += 1) {
                if (at + 1 >= into.len) return 0;
                into[at] = name[j];
                at += 1;
            }
            continue;
        }
        if (at + 1 >= into.len) return 0;
        into[at] = text[i];
        at += 1;
    }
    into[at] = 0;
    _ = db;
    return at;
}

/// The question as a requester. Null when there is no screen to put one
/// on, which is not a failure: the console is asked instead.
fn askOnScreen(db: *DosBase, proc: *dos.Process, line: [*:0]const u8) ?bool {
    const sys = db.sys_base;
    const lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse return null;
    defer sys.CloseLibrary(lib);
    const ib: *sdk.interface.intuition.IntuitionBase = @ptrCast(lib);
    // A screen of its own is not opened for a question: with none there,
    // the console is where it goes.
    const screen = ib.LockPubScreen(null) orelse return null;
    ib.UnlockPubScreen(null, screen);
    const easy = intuition.EasyStruct{
        .title = "System Request",
        .text_format = line,
        .gadget_format = "Retry|Cancel",
    };
    const window: ?*intuition.Window = @ptrCast(@alignCast(proc.window_ptr));
    const pressed = ib.EasyRequestArgs(window, &easy, null, null);
    // 1 is Retry, 0 the rightmost, which is Cancel.
    return pressed != 1;
}

/// The question as a line on the process's console. Null when it has
/// none to ask on.
fn askOnConsole(db: *DosBase, line: [*:0]const u8) ?bool {
    const dos_lib = db.iface();
    const out = dos_lib.Output() orelse return null;
    const in = dos_lib.Input() orelse return null;
    _ = dos_lib.FPuts(out, line);
    _ = dos_lib.FPuts(out, "\nRetry or Cancel? ");
    _ = dos_lib.Flush(out);
    var answer: [8]u8 = @splat(0);
    const got = dos_lib.FGets(in, @ptrCast(&answer), answer.len);
    if (got == null) return true;
    const first = answer[0];
    return !(first == 'r' or first == 'R' or first == 'y' or first == 'Y' or first == '\n' or first == 0);
}
