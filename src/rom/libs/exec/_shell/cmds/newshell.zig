// SPDX-License-Identifier: MPL-2.0
//! newshell [console]: the shell (src/rom/shell) on a console, in SYS:,
//! reading S:Shell-Startup.
//!
//! The console is AUX: - this terminal - unless one is named: `newshell
//! CON:` puts the shell in a window on the display instead, and any
//! console name works, window options and all. On this terminal it runs
//! until it ends (EndShell, EndCLI, Ctrl-\\), with this shell's console
//! reads paused meanwhile: two readers on one serial port would share
//! every line between them. A shell in a window has its own console and
//! is left running.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const DosBase = sdk.interface.dos.DosBase;

pub const name = "newshell";
pub const usage = "newshell [console]";
pub const help =
    \\  newshell [console]   the PowerOS-Shell (src/rom/shell) in SYS:, reading
    \\                       S:Shell-Startup. On AUX: (this terminal) unless a
    \\                       console is named: CON: is a window on the display.
    \\                       Until EndShell, EndCLI or Ctrl-\
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const window = args.next() orelse "AUX:";
    const dl = _shell.openDos(shell) orelse return;
    defer shell.base.iface().CloseLibrary(dl.lib());
    const serial_console = window.len >= 4 and window[0] == 'A' and window[1] == 'U' and window[2] == 'X';
    var paused: [shell.con_units.len]?*_shell.ConsoleUnit = @splat(null);
    if (serial_console) {
        for (&shell.con_units, 0..) |*unit, i| {
            if (unit.open) paused[i] = _shell.pauseConsole(shell, unit.device, unit.unit);
        }
    }
    defer for (paused) |unit| _shell.resumeConsole(shell, unit);
    const rc = newShell(dl, window.ptr, !serial_console);
    if (rc < 0) return shell.print("no shell on %s (%d)\n", .{ window.ptr, dl.IoErr() });
    if (serial_console) shell.print("PowerOS-Shell ended (%d)\n", .{rc}) else shell.print("PowerOS-Shell is CLI %d\n", .{rc});
}

/// A shell on `window`, reading S:Shell-Startup - the script every new
/// shell runs. Not S:Startup-Sequence: that sets the machine up once, and
/// dos's init has run it already in the boot shell, so running it again
/// would make every assign a second time and start what User-Startup
/// starts a second time too. The shell closes the script itself when it
/// reaches the end of it.
///
/// `asynch` leaves it running and answers its CLI number, so this shell
/// keeps its own terminal; otherwise this waits for the shell to end and
/// answers its return code. Below 0: it did not start (dos says why).
fn newShell(dl: *DosBase, window: [*:0]const u8, asynch: bool) i32 {
    const script = dl.Open("S:Shell-Startup", sdk.dos.MODE_OLDFILE);
    const tags = [_]sdk.utility.TagItem{
        // dos opens the console once and gives the shell both directions
        // of it: a name that makes a window makes one per Open.
        .{ .tag = sdk.dos.SYS_Window, .data = @intFromPtr(window) },
        .{ .tag = sdk.dos.SYS_UserShell, .data = 1 },
        .{ .tag = sdk.dos.SYS_ScriptFile, .data = @intFromPtr(script) },
        .{ .tag = if (asynch) sdk.dos.SYS_Asynch else sdk.utility.TAG_IGNORE, .data = 1 },
        .{ .tag = sdk.dos.NP_CurrentDir, .data = @intFromPtr(dl.Lock("SYS:", sdk.dos.SHARED_LOCK) orelse dl.Lock("RAM:", sdk.dos.SHARED_LOCK)) },
        .{},
    };
    const rc = dl.SystemTagList(null, &tags);
    if (rc < 0) {
        if (script) |file| _ = dl.Close(file);
    }
    return rc;
}
