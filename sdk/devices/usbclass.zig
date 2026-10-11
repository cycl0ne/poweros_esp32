// SPDX-License-Identifier: MIT
//! A USB class driver (`DEVIF_USBCLASS`): a device in `DEVS:usb/` that
//! drives one kind of USB thing for the rest of the system - a keyboard,
//! a stick, a serial adapter - and is the device a program or handler
//! opens for it. It has two calls after BeginIO and AbortIO, USBClassBind
//! and USBClassUnbind (`sdk.interface.usbclass`), and a ROM tag that
//! says what it drives, which usb.library reads from the file without
//! loading it: a driver is loaded only when something it drives is
//! plugged in.
//!
//! **Which driver is offered an interface.** Every driver whose table has
//! an entry the interface matches, most specific first: an entry that
//! names the vendor and product above one that names a class, and among
//! equals the higher `priority`. A driver that declines passes it on to
//! the next.

const exec = @import("../libs/exec/exec.zig");

/// The unit usb.library opens a class driver on: the driver itself, for
/// its two calls, and none of its units. A driver's own units - a stick's
/// drive, an adapter's line - are its things, opened by whoever uses them.
pub const USBCLASS_UNIT_BIND: u32 = 0xFFFF_FFFF;

/// USBMatch.fields: which of the entry's fields must match the device's
/// (idVendor, idProduct) or the interface's (class, subclass, protocol).
pub const USBMATCH_VENDOR: u16 = 1 << 0;
pub const USBMATCH_PRODUCT: u16 = 1 << 1;
pub const USBMATCH_CLASS: u16 = 1 << 2;
pub const USBMATCH_SUBCLASS: u16 = 1 << 3;
pub const USBMATCH_PROTOCOL: u16 = 1 << 4;

/// One thing a class driver drives. A table of them ends with an entry
/// whose `fields` is 0.
pub const USBMatch = extern struct {
    /// USBMATCH_* or'd: the fields that must match.
    fields: u16 = 0,
    /// Among entries as specific as each other, the higher is offered
    /// first.
    priority: i8 = 0,
    pad: u8 = 0,
    vendor_id: u16 = 0,
    product_id: u16 = 0,
    interface_class: u8 = 0,
    interface_subclass: u8 = 0,
    interface_protocol: u8 = 0,
    pad2: u8 = 0,
};

/// A class driver's ROM tag: a `ResidentDevice` whose `speaks` lists
/// DEVIF_USBCLASS, and the table of what it drives.
pub const ResidentUSBClass = extern struct {
    device: exec.ResidentDevice,
    /// What it drives, ended by an entry whose `fields` is 0.
    matches: [*]const USBMatch,
};

/// How specific an entry is, for ordering drivers: a vendor and product
/// above any class, then each further field.
pub fn specificity(match: USBMatch) u32 {
    var score: u32 = 0;
    if (match.fields & USBMATCH_VENDOR != 0) score += 16;
    if (match.fields & USBMATCH_PRODUCT != 0) score += 32;
    if (match.fields & USBMATCH_CLASS != 0) score += 1;
    if (match.fields & USBMATCH_SUBCLASS != 0) score += 2;
    if (match.fields & USBMATCH_PROTOCOL != 0) score += 4;
    return score;
}

/// Whether `match` takes an interface of this class, subclass and
/// protocol on a device of this vendor and product.
pub fn matches(match: USBMatch, vendor_id: u16, product_id: u16, class: u8, subclass: u8, protocol: u8) bool {
    if (match.fields == 0) return false;
    if (match.fields & USBMATCH_VENDOR != 0 and match.vendor_id != vendor_id) return false;
    if (match.fields & USBMATCH_PRODUCT != 0 and match.product_id != product_id) return false;
    if (match.fields & USBMATCH_CLASS != 0 and match.interface_class != class) return false;
    if (match.fields & USBMATCH_SUBCLASS != 0 and match.interface_subclass != subclass) return false;
    if (match.fields & USBMATCH_PROTOCOL != 0 and match.interface_protocol != protocol) return false;
    return true;
}
