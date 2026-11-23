// SPDX-License-Identifier: MIT
//! A Bluetooth profile driver (`DEVIF_BTPROFILE`): a device in
//! `DEVS:bluetooth/` that drives one kind of service of the devices this
//! machine is bonded with - a keyboard's, a mouse's - for the rest of the
//! system. It has two calls after BeginIO and AbortIO, BTProfileBind and
//! BTProfileUnbind (`sdk.interface.btprofile`), and a ROM tag that says
//! what it drives, which bluetooth.library reads from the file without
//! loading it: a driver is loaded only when a device it drives is bonded
//! with, or a controller comes up that is.
//!
//! **Which driver is offered a service.** A pairing that makes a bond has
//! the device's services listed (ObtainBTServices); each is offered to
//! every driver whose table has an entry it matches - the kind of link
//! it is reached over, and its class - the higher `priority` first, until
//! one takes it. The services taken are kept with the bond, and offered
//! again each time its controller comes up.

const exec = @import("../libs/exec/exec.zig");
const bluetooth = @import("../libs/bluetooth/bluetooth.zig");

/// The unit bluetooth.library opens a profile driver on: the driver
/// itself, for its two calls, and none of its units.
pub const BTPROFILE_UNIT_BIND: u32 = 0xFFFF_FFFF;

/// BTMatch.over: the services an entry takes.
/// A BR/EDR one, by its SDP record (BTSF_SDP).
pub const BTMATCH_BREDR: u8 = 1;
/// An LE device's GATT service (BTSF_GATT).
pub const BTMATCH_LE: u8 = 2;

/// One kind of service a profile driver drives. A table of them ends with
/// an entry whose `over` is 0.
pub const BTMatch = extern struct {
    /// BTMATCH_*.
    over: u8 = 0,
    /// Among the entries a service matches, the higher is offered first.
    priority: i8 = 0,
    /// The service's class in 16 bits (BTService.class16); 0 to match by
    /// `class` instead.
    class16: u16 = 0,
    /// Its class as 128 bits, where `class16` is 0.
    class: bluetooth.BTUUID = .{},
};

/// A profile driver's ROM tag: a `ResidentDevice` whose `speaks` lists
/// DEVIF_BTPROFILE, and the table of what it drives.
pub const ResidentBTProfile = extern struct {
    device: exec.ResidentDevice,
    /// What it drives, ended by an entry whose `over` is 0.
    matches: [*]const BTMatch,
};
