// SPDX-License-Identifier: MIT
//! What a device speaks: the command sets (`DEVIF_*`) a device lists in
//! its `ResidentDevice` tag. A program that needs a kind of device - a
//! serial line, a block device, a USB host controller - looks for the
//! command set, not for a name, and finds every device that speaks it:
//! ObtainDeviceUnits lists the units of every such device, a
//! `DeviceUnit` each.

const exec = @import("../exec/exec.zig");

/// Bytes read and written as a stream: CMD_READ, CMD_WRITE, CMD_FLUSH.
pub const DEVIF_STREAM: u32 = 1;
/// A serial line: the stream, IOExtSer, SDCMD_SETPARAMS, SDCMD_QUERY,
/// SDCMD_BREAK (sdk/devices/serial.zig).
pub const DEVIF_SERIAL: u32 = 2;
/// Whole frames on an RS-485 bus (sdk/devices/rs485.zig).
pub const DEVIF_RS485: u32 = 3;
/// A network interface: SANA-II (sdk/devices/network.zig).
pub const DEVIF_SANA2: u32 = 4;
/// Blocks by offset, as file systems use them (sdk/devices/trackdisk.zig).
pub const DEVIF_BLOCK: u32 = 5;
/// audio.device's commands (sdk/devices/audio.zig).
pub const DEVIF_AUDIO: u32 = 6;
/// Keys (sdk/devices/keyboard.zig).
pub const DEVIF_KEYBOARD: u32 = 7;
/// Movement and buttons (sdk/devices/mouse.zig).
pub const DEVIF_MOUSE: u32 = 8;
/// Contacts at positions (sdk/devices/touch.zig).
pub const DEVIF_TOUCH: u32 = 9;
/// Transfers on an I2C bus (sdk/devices/i2c.zig).
pub const DEVIF_I2C: u32 = 10;
/// timer.device's commands (sdk/devices/timer.zig).
pub const DEVIF_TIMER: u32 = 11;
/// A USB host controller: transfers to the devices on its bus
/// (sdk/devices/usbhc.zig). usb.library runs a bus on each unit of every
/// device that speaks it.
pub const DEVIF_USBHC: u32 = 12;
/// A USB class driver: USBClassBind and USBClassUnbind after BeginIO and
/// AbortIO, and a `ResidentUSBClass` tag whose match table says what it
/// drives (sdk/devices/usbclass.zig).
pub const DEVIF_USBCLASS: u32 = 13;

/// A unit of a device, as ObtainDeviceUnits lists it: a node of the list
/// it answers, given back whole with ReleaseDeviceUnits.
pub const DeviceUnit = extern struct {
    /// `name`: what OpenDevice takes - a ROM device's name, or a disk
    /// device's path under DEVS: ("usb/acm.device").
    node: exec.Node = .{},
    /// The unit to open.
    unit: u32 = 0,
    /// What the board calls the unit (its part's PART_Label), or the
    /// device's own label for it; null for neither.
    label: ?[*:0]const u8 = null,
    /// The device's version and revision, from its ROM tag.
    version: u16 = 0,
    revision: u16 = 0,
    /// The command sets it speaks, DEVIF_*, ended by 0.
    speaks: [*]const u32,
    /// DUF_*.
    flags: u32 = 0,
};

/// DeviceUnit.flags: the device is in the ROM, not a file in DEVS:.
pub const DUF_ROM: u32 = 1 << 0;
