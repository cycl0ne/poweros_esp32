// SPDX-License-Identifier: MPL-2.0
//! The power management an x86-64 machine's chipset has (CHIP_ACPI_PM):
//! two register blocks in the I/O port space, whose addresses the
//! firmware's tables name and the kernel puts in the board's description.
//!
//! **The event block** is two halves of the same width: what has
//! happened, and what may be reported. Each bit of the first stands for
//! one thing the hardware noticed - the power button pressed is one of
//! them - and stays set until it is written back, which is how such a bit
//! is cleared. The matching bit of the second half says whether that
//! thing is to raise the machine's power management interrupt at all. A
//! machine with two such blocks has the same bits twice, and both are
//! read and written.
//!
//! **The control block** holds, in its lowest bit, whether the machine is
//! in the mode where this hardware reports to the system at all rather
//! than to the firmware. The firmware may have put the machine in it
//! already; where it did not, the tables name a port to ask on and what
//! to write there, and the bit says when the request was granted.
//!
//! Nothing else of this hardware is touched. What a machine is written to
//! in order to be off is in the tables' own language, which nothing here
//! reads - that is the firmware's call to make
//! (`sdk/hardware/x64uefi/system.zig`).

const sdk = @import("sdk");

/// This hardware is an x86-64 machine's; on any other chip the board
/// describes none and none of this is compiled.
const on_x64 = sdk.hardware.chip == .x64uefi;

/// The power button, in both halves of the event block: pressed, and
/// whether pressing it is reported.
const BUTTON: u16 = 1 << 8;
/// The control block's lowest bit: the machine is in the mode where this
/// hardware reports to the system.
const SYSTEM_MODE: u16 = 1 << 0;

/// How many times the control block is read while waiting for the mode to
/// be granted. The firmware answers in microseconds and a port is read in
/// about one, so this is only so that a machine that never answers stops
/// waiting rather than stopping.
const patience: u32 = 1_000_000;

/// Where the hardware is, as the board describes it. All of it is 0 on a
/// machine whose description has no such part, and nothing is read or
/// written then.
pub const Hardware = extern struct {
    /// The event block, and the second one where the machine has two.
    event: u16 = 0,
    event2: u16 = 0,
    /// The control block, and its second.
    control: u16 = 0,
    control2: u16 = 0,
    /// How many bytes a whole event block is, both halves together.
    event_bytes: u8 = 0,
    /// Where to ask for the mode this hardware reports in, and what to
    /// write there; 0 where the machine is in it already.
    mode_port: u16 = 0,
    mode_value: u8 = 0,
    /// Whether the power button is one of this hardware's own features.
    /// Where it is not, it is described in the tables' language instead,
    /// and nothing here can hear it.
    button: bool = false,
};

fn in16(port: u16) u16 {
    return if (comptime on_x64) sdk.hardware.mmio.in16(port) else 0;
}

fn out16(port: u16, value: u16) void {
    if (comptime on_x64) sdk.hardware.mmio.out16(port, value);
}

fn out8(port: u16, value: u8) void {
    if (comptime on_x64) sdk.hardware.mmio.out8(port, value);
}

/// Where the half that says what may be reported begins: the second half
/// of the block.
fn enableOf(block: u16, hw: Hardware) u16 {
    return block + hw.event_bytes / 2;
}

/// Whether the hardware is there to be used at all: a block, and halves
/// wide enough to hold the bit the button is in.
pub fn usable(hw: Hardware) bool {
    if (!on_x64) return false;
    return hw.event != 0 and hw.control != 0 and hw.event_bytes >= 4;
}

/// The machine put in the mode where this hardware reports to the system,
/// and the power button's press made a thing it reports. False where the
/// machine would not enter that mode, and nothing was changed.
pub fn start(hw: Hardware) bool {
    if (!usable(hw)) return false;
    if (!enterSystemMode(hw)) return false;
    // A press from before this - the firmware's own start, or a machine
    // that was woken by the button - is not this system's to act on.
    clear(hw);
    out16(enableOf(hw.event, hw), in16(enableOf(hw.event, hw)) | BUTTON);
    if (hw.event2 != 0) out16(enableOf(hw.event2, hw), in16(enableOf(hw.event2, hw)) | BUTTON);
    return true;
}

/// The mode asked for where the machine is not in it, and waited for.
fn enterSystemMode(hw: Hardware) bool {
    if (in16(hw.control) & SYSTEM_MODE != 0) return true;
    if (hw.mode_port == 0) return false;
    out8(hw.mode_port, hw.mode_value);
    var waited: u32 = 0;
    while (in16(hw.control) & SYSTEM_MODE == 0) : (waited += 1) {
        if (waited == patience) return false;
    }
    return true;
}

/// Whether the power button has been pressed since this was last cleared.
pub fn pressed(hw: Hardware) bool {
    if (!usable(hw)) return false;
    if (in16(hw.event) & BUTTON != 0) return true;
    return hw.event2 != 0 and in16(hw.event2) & BUTTON != 0;
}

/// The press cleared: the bit written back, which is how this hardware is
/// told that what it noticed has been seen.
pub fn clear(hw: Hardware) void {
    if (!usable(hw)) return;
    out16(hw.event, BUTTON);
    if (hw.event2 != 0) out16(hw.event2, BUTTON);
}
