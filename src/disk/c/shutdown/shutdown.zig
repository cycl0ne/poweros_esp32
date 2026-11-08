// SPDX-License-Identifier: MIT
//! Shutdown: the machine turned off, with every drive held still first so
//! that what its file system is holding is written out. Built against the
//! SDK only.
//!
//!   Shutdown FORCE/S,QUIET/S
//!
//!   Shutdown               after one question
//!   Shutdown FORCE         asking nothing
//!
//! Nothing is written out as a machine goes off, so every drive a device
//! feeds is inhibited first: the handler writes out what it has and
//! closes the medium before it answers. One that will not stop - a
//! program still has something open on it - is named, and the machine
//! goes off anyway, since what was asked for was the machine off.
//!
//! **Not every machine can do this.** It takes hardware that turns its
//! own power off, and firmware that says how (power.resource,
//! PowerAbilities): a machine without it is told to go off and goes on
//! running, which it says rather than leaving the machine looking hung.
//! Restarting such a machine is `Reboot`.
//!
//! The return code is 0 for a machine on its way off - which nothing
//! reads, since the machine goes first - 5 for a question answered with
//! Ctrl-C or a machine that cannot turn itself off, and 20 for one that
//! was asked and went on running, which is a machine still to be seen to.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const power = sdk.resources.power;
const drives = dos.blockdrives;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const PowerBase = sdk.interface.power.PowerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Shutdown";
const VERSION_STRING = "\x00$VER: Shutdown 1.0 (04.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FORCE/S,QUIET/S";
const arg_force = 0;
const arg_quiet = 1;
const arg_count = 2;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const quiet = argv[arg_quiet] != 0;

    // Whether this machine can do it at all is asked before anything is
    // held still, so that a machine that cannot is left running and
    // working.
    const pb = powerBase(sys) orelse {
        _ = Printf(dl, "%s: this machine does not turn itself off\n", .{COMMAND_NAME});
        return dos.RETURN_WARN;
    };

    if (argv[arg_force] == 0) {
        _ = dl.PutStr("Turning the machine off.\n");
        _ = dl.PutStr("Press RETURN to go on, or CTRL-C to stop: ");
        _ = dl.Flush(dl.Output());
        if (!confirm(dl)) {
            _ = dl.PutStr("\n");
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            return dos.RETURN_WARN;
        }
        _ = dl.PutStr("\n");
    }

    var mounted: drives.List = .{};
    mounted.gather(dl);
    var refused: drives.List = .{};
    if (drives.holdAll(dl, &mounted, &refused) != 0 and !quiet) {
        for (refused.all()) |*name| {
            _ = Printf(dl, "  %s would not stop: what it holds may not be written out\n", .{drives.path(name)});
        }
    }
    if (!quiet) _ = dl.PutStr("Going off.\n");
    _ = dl.Flush(dl.Output());
    pb.PowerOff();

    // Still here: the machine would not go off. The drives are let go
    // again, since it is still a machine to be used.
    drives.releaseAll(dl, &mounted);
    _ = Printf(dl, "%s: the machine was told to go off and did not\n", .{COMMAND_NAME});
    return dos.RETURN_FAIL;
}

/// power.resource, where this machine has it and it can turn the machine
/// off; null where either is missing.
fn powerBase(sys: *ExecBase) ?*PowerBase {
    const base: *PowerBase = @ptrCast(sys.OpenResource(power.POWERNAME) orelse return null);
    return if (base.PowerAbilities() & power.POWERF_OFF != 0) base else null;
}

/// A line waited for: true for RETURN, false for Ctrl-C or a stream that
/// has ended.
fn confirm(dl: *DosBase) bool {
    while (true) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) return false;
        const char = dl.FGetC(dl.Input());
        if (char < 0) return false;
        if (char == '\n') return true;
    }
}
