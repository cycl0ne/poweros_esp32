// SPDX-License-Identifier: MIT
//! hid.library's types: what a keyboard's or a mouse's reports mean, for
//! the drivers that carry them - USB's, Bluetooth's - so that a report
//! becomes keys, moves and buttons in one place, whatever brought it.
//!
//! **A function** is one device's reports read by its report descriptor
//! (`OpenHID`): a keyboard collection makes it a source of
//! keyboard.device, a mouse or a tablet one of mouse.device, a descriptor
//! with both both - their reports told apart by their IDs. A driver hands
//! it each input report as it comes (`HIDInput`) and closes it when the
//! device goes (`CloseHID`), which lets go of the keys and buttons the
//! device still held.
//!
//! **A boot interface** - a USB keyboard or mouse that also speaks the
//! boot protocol - names its kind with `HIDA_Boot`: where its descriptor
//! does not describe that kind, the function reads the boot protocol's
//! report of it instead and says so in its flags (`HIDF_BOOT`), and the
//! driver puts the device in that protocol.
//!
//! **What goes back to the device** - a keyboard's LEDs, Caps Lock's
//! following its key - is an output report the function hands to the
//! driver's hook (`HIDA_OutputHook`) as an `HIDOutputMessage`, for the
//! driver to send as its transport sends one.

const utility = @import("../utility/utility.zig");

pub const HIDNAME = "hid.library";

// --- OpenHID's tags ---------------------------------------------------------------

pub const HIDA_Dummy = utility.TAG_USER + 0x61500;
/// u32: a boot interface's kind, HIDBOOT_KEYBOARD or HIDBOOT_MOUSE. Where
/// the descriptor does not describe that kind, the function reads the
/// boot protocol's report of it alone (HIDF_BOOT).
pub const HIDA_Boot = HIDA_Dummy + 1;
/// *utility.Hook: called with the function and an HIDOutputMessage when an
/// output report is to go to the device; on the task that calls
/// HIDInput. Without one nothing goes back.
pub const HIDA_OutputHook = HIDA_Dummy + 2;
/// *exec.MsgPort: where the requests to keyboard.device and mouse.device
/// are replied - a port of the task that calls HIDInput and CloseHID.
/// Without one OpenHID makes one for the task that calls it.
pub const HIDA_ReplyPort = HIDA_Dummy + 3;

/// HIDA_Boot's kinds.
pub const HIDBOOT_KEYBOARD: u32 = 1;
pub const HIDBOOT_MOUSE: u32 = 2;

// --- a function --------------------------------------------------------------------

/// HIDFunction.flags: what it drives, and how it reads it.
/// A keyboard: a source of keyboard.device.
pub const HIDF_KEYBOARD: u32 = 1 << 0;
/// A mouse, whose X and Y are moves: a source of mouse.device.
pub const HIDF_MOUSE: u32 = 1 << 1;
/// A tablet, whose X and Y are a place: a source of mouse.device.
pub const HIDF_TABLET: u32 = 1 << 2;
/// Its reports are the boot protocol's, not its descriptor's: the driver
/// puts the device in the boot protocol.
pub const HIDF_BOOT: u32 = 1 << 3;

/// A function, the library's from OpenHID to CloseHID. Its fields are read,
/// never written; what follows them is the library's own.
pub const HIDFunction = extern struct {
    /// HIDF_* or'd.
    flags: u32 = 0,
};

/// HIDOutputMessage.kind: the report's kind, as HID numbers them.
pub const HIDREPORT_INPUT: u8 = 1;
pub const HIDREPORT_OUTPUT: u8 = 2;
pub const HIDREPORT_FEATURE: u8 = 3;

/// What HIDA_OutputHook is called with: a report to send to the device,
/// the library's for the call alone.
pub const HIDOutputMessage = extern struct {
    /// The report's bytes, without its ID.
    data: [*]const u8,
    length: u32,
    /// Its ID; 0 for a device whose reports have none.
    id: u8,
    /// HIDREPORT_OUTPUT.
    kind: u8,
    pad: [2]u8 = .{ 0, 0 },
};
