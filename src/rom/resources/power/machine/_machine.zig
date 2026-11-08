// SPDX-License-Identifier: MPL-2.0
//! What the machine itself can do about its power, which is one thing:
//! turn off. It is the firmware's to do - what a machine is written to in
//! order to be off is described in the firmware's own tables, in the
//! language nothing here reads, and the firmware wrote that description -
//! so this asks the chip's system file, where the kernel left the
//! firmware's call as it started.
//!
//! A chip whose machines cannot do it compiles none of this and answers
//! that they cannot.

const sdk = @import("sdk");

/// The chips whose machines have firmware that can turn them off.
const by_firmware = sdk.hardware.chip == .x64uefi;

/// Whether this machine can be turned off at all.
pub fn canOff() bool {
    if (comptime by_firmware) return sdk.hardware.system.canPowerOff();
    return false;
}

/// The machine off. It returns only where it could not be done.
pub fn off() void {
    if (comptime by_firmware) sdk.hardware.system.powerOffChip();
}
