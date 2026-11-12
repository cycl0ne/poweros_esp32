// SPDX-License-Identifier: MPL-2.0
//! reboot [tryboot]: exec's ColdReboot, which resets the chip - with
//! `tryboot` after the firmware's flag for the next start is set, so that
//! the bootloader starts from the partition `autoboot.txt`'s `[tryboot]`
//! names, this once.
//!
//! That is C:Reboot TRYBOOT with nothing loaded from a disk, which is
//! what is left where the system on the disk is not the one this kernel
//! was built with: an update whose start on its new kernel never came,
//! after which every program the disk gives this kernel may fail. Held at
//! boot with Ctrl-D on the console (dos.library's `startupHeld`), this
//! shell is all that runs, and `reboot tryboot` starts the kernel the
//! disk belongs to; C:Update CONFIRM there keeps it. No drive is held
//! still first, as C:Reboot does: `reboot` never did, and a held start
//! has nothing open.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const exec = sdk.exec;
const videocore = sdk.hardware.videocore;
const st = sdk.expansion.systemtags;

pub const name = "reboot";
pub const usage = "reboot [tryboot]";
pub const help =
    \\  reboot [tryboot]     ColdReboot: reset the chip; tryboot: from the other
    \\                       boot partition, this once (the firmware's flag)
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    if (args.next()) |word| {
        if (!_shell.same(word, "tryboot")) return error.Usage;
        // The firmware's mailbox, which the board names as its RTC's
        // address, as C:Reboot finds it.
        const mailbox = _shell.chipFact(shell, st.PARTKIND_RTC, st.CHIP_RPI_RTC, st.PART_Address, 0);
        if (mailbox == 0) {
            shell.print("this machine's firmware has no start it can be sent to for one time only\n", .{});
            return;
        }
        if (!setFlags(shell, mailbox, videocore.REBOOT_TRYBOOT)) {
            shell.print("the firmware does not take the flag for the next start, so nothing was restarted\n", .{});
            return;
        }
        shell.print("rebooting from the other boot partition, this once...\n", .{});
    } else shell.print("rebooting...\n", .{});
    shell.base.iface().ColdReboot();
}

/// The flags for the next start handed to the firmware, in a buffer where
/// its DMA reaches.
fn setFlags(shell: *Shell, mailbox: usize, flags: u32) bool {
    const sys = shell.base.iface();
    const bytes = 2 * videocore.buffer_bytes;
    const memory = sys.AllocMem(bytes, exec.MEMF_DMA) orelse return false;
    defer sys.FreeMem(memory, bytes);
    const buffer = videocore.bufferIn(memory) orelse return false;
    var value = [_]u32{flags};
    return videocore.call(sys, mailbox, buffer, videocore.TAG_SET_REBOOT_FLAGS, &value);
}
