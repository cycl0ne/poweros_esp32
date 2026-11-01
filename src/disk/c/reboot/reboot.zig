// SPDX-License-Identifier: MIT
//! Reboot: the machine started again, with every drive held still first
//! so that what its file system is holding is written out. Built against
//! the SDK only.
//!
//!   Reboot TRYBOOT/S,FORCE/S,QUIET/S
//!
//!   Reboot                 after one question
//!   Reboot FORCE           asking nothing
//!   Reboot TRYBOOT         from the other boot partition, this once
//!
//! A reset writes nothing out, so every drive a device feeds is inhibited
//! before it: the handler writes out what it has and closes the medium
//! before it answers. One that will not stop - a program still has
//! something open on it - is named, and the restart goes ahead, since a
//! machine that cannot be restarted is worse than a file that was not
//! written.
//!
//! **TRYBOOT** is for a board whose firmware starts from either of a pair
//! of boot partitions and can be sent to the other for a single start: it
//! sets the firmware's reboot flag (the VideoCore's `SET_REBOOT_FLAGS`,
//! bit 0), the bootloader then reads the partition its `[tryboot]`
//! section names, and the next start after that is back on the usual one
//! unless the system that came up wrote it down. On a board whose
//! firmware has no such flag it says so and does nothing, so a script can
//! ask `If WARN`.
//!
//! The return code is 0 for a machine on its way down - which nothing
//! reads, since the reset comes first - 5 for a question answered with
//! Ctrl-C or a board that has no tried start, and 20 for a flag that
//! could not be set, where the restart is left undone on purpose: a
//! machine that restarts the usual way is not what was asked for.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const videocore = sdk.hardware.videocore;
const drives = dos.blockdrives;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const st_expansion = sdk.expansion;
const st = st_expansion.systemtags;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Reboot";
const VERSION_STRING = "\x00$VER: Reboot 1.0 (02.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TRYBOOT/S,FORCE/S,QUIET/S";
const arg_tryboot = 0;
const arg_force = 1;
const arg_quiet = 2;
const arg_count = 3;

/// The firmware's property message that holds the flags for the next
/// start, and the one flag there is: the bootloader reads what
/// `[tryboot]` names this once.
const TAG_SET_REBOOT_FLAGS: u32 = 0x0003_8064;
const REBOOT_TRYBOOT: u32 = 1 << 0;

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
    const tryboot = argv[arg_tryboot] != 0;
    const quiet = argv[arg_quiet] != 0;

    // Whether this board has a tried start at all is asked before
    // anything is held still, so that a machine on which TRYBOOT means
    // nothing is left running.
    const mailbox = if (tryboot) mailboxOf(sys) orelse {
        _ = Printf(dl, "%s: this machine's firmware has no start it can be sent to for one time only\n", .{COMMAND_NAME});
        return dos.RETURN_WARN;
    } else 0;

    if (argv[arg_force] == 0) {
        if (tryboot) {
            _ = dl.PutStr("Restarting from the other boot partition, this once.\n");
        } else _ = dl.PutStr("Restarting the machine.\n");
        _ = dl.PutStr("Press RETURN to go on, or CTRL-C to stop: ");
        _ = dl.Flush(dl.Output());
        if (!confirm(dl)) {
            _ = dl.PutStr("\n");
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            return dos.RETURN_WARN;
        }
        _ = dl.PutStr("\n");
    }

    if (tryboot and !setFlags(sys, mailbox, REBOOT_TRYBOOT)) {
        _ = Printf(dl, "%s: the firmware does not take the flag for the next start, so nothing was restarted\n", .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }

    var mounted: drives.List = .{};
    mounted.gather(dl);
    var refused: drives.List = .{};
    if (drives.holdAll(dl, &mounted, &refused) != 0 and !quiet) {
        for (refused.all()) |*name| {
            _ = Printf(dl, "  %s would not stop: what it holds may not be written out\n", .{drives.path(name)});
        }
    }
    if (!quiet) _ = dl.PutStr("Restarting.\n");
    _ = dl.Flush(dl.Output());
    sys.ColdReboot();
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

/// The flags for the next start handed to the firmware.
fn setFlags(sys: *ExecBase, mailbox: usize, flags: u32) bool {
    const bytes = 2 * videocore.buffer_bytes;
    const memory = sys.AllocMem(bytes, exec.MEMF_DMA) orelse return false;
    defer sys.FreeMem(memory, bytes);
    const buffer = videocore.bufferIn(memory) orelse return false;
    var value = [_]u32{flags};
    return videocore.call(sys, mailbox, buffer, TAG_SET_REBOOT_FLAGS, &value);
}

/// The firmware's mailbox, which the board names as its RTC's address;
/// null on a board that has none.
fn mailboxOf(sys: *ExecBase) ?usize {
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null;
    defer sys.CloseLibrary(utility_lib);
    const utility: *UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(st_expansion.EXPANSIONNAME, 1) orelse return null;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_RTC, st.CHIP_RPI_RTC) orelse return null;
    const address = utility.GetTagData(st.PART_Address, 0, part.tags);
    return if (address != 0) address else null;
}
