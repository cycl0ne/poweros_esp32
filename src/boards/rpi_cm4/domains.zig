// SPDX-License-Identifier: MPL-2.0
//! The VideoCore firmware's power domains the Compute Module 4's parts
//! need (`boards.firmware_power`): the USB block's, which holds the xHCI
//! that is the board's USB part. The firmware leaves it off until it is
//! asked - the device tree's xhci@7e9c0000 names it (`power-domains`),
//! and Linux's raspberrypi-power asks for it before xhci-plat starts.
//! It is asked as Linux asks it, through the old interface
//! (SET_POWER_STATE, device 3, on), so that any firmware answers; it
//! does in about 25 ms.
//!
//! **Not on a start over USB.** When a PC sent the kernel (rpiboot, the
//! bootloader's `boot-mode` 3) the firmware never answers this request,
//! with the PC's cable in or out, and answers nothing after it either:
//! the cores' clock, the RTC and the next start's flags would go
//! unanswered for the rest of that run. USB stays off then, and the log
//! says so.

const sdk = @import("sdk");
const exec = sdk.exec;
const videocore = sdk.hardware.videocore;
const ExecBase = sdk.interface.exec.ExecBase;
const system = @import("system.zig");

const TAG_SET_POWER_STATE: u32 = 0x0002_8001;
/// The firmware's number for the USB block.
const DEVICE_USB: u32 = 3;
/// Asked: on. Answered: on, and no such device.
const STATE_ON: u32 = 1 << 0;
const STATE_MISSING: u32 = 1 << 1;
/// The bootloader's `boot-mode` for a kernel a PC sent over USB.
pub const BOOT_MODE_RPIBOOT: u32 = 3;

/// The domains on, or the log told why not. The message goes in
/// MEMF_DMA, the RAM the firmware reads.
pub fn powerUp(sys: *ExecBase) void {
    if (system.boot_mode == BOOT_MODE_RPIBOOT) {
        exec.kprintf(sys, "USB stays off: on a start over USB (rpiboot) the firmware does not answer when asked to power it\n", .{});
        return;
    }
    const bytes = 2 * videocore.buffer_bytes;
    const memory = sys.AllocMem(bytes, exec.MEMF_DMA) orelse return failed(sys, "no memory for the message");
    defer sys.FreeMem(memory, bytes);
    const buffer = videocore.bufferIn(memory) orelse return failed(sys, "no memory for the message");
    var state = [_]u32{ DEVICE_USB, STATE_ON };
    if (!videocore.call(sys, system.mailbox, buffer, TAG_SET_POWER_STATE, &state)) return failed(sys, "the firmware does not answer");
    if (state[1] & STATE_MISSING != 0) return failed(sys, "the firmware has no USB block");
    if (state[1] & STATE_ON == 0) return failed(sys, "the firmware left it off");
}

fn failed(sys: *ExecBase, why: [*:0]const u8) void {
    exec.kprintf(sys, "USB stays off: %s\n", .{why});
}
