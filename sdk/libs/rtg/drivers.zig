// SPDX-License-Identifier: MIT
//! Drivers and devices: what a display's or a bus's driver is to
//! rtg.library, and what it is given to drive.
//!
//! A driver is a description and nothing that runs by itself: a constant
//! `RtgDriverSpec` behind a ROM tag of type `.rtg_driver`
//! (`ResidentRtgDriver`). The tag has no init routine and no start class,
//! so exec starts nothing of it. rtg.library reads the descriptions of the
//! ROM's tags at its own init and puts each on its list (`AddRtgDriver`);
//! from then on the library calls the driver through the description's
//! `ops`, and the driver calls the library through the node it is handed.
//!
//! A **device** is hardware a driver can drive: a panel part of the
//! board's list, or a display function found on PCI. The library keeps
//! the list of them (`RtgDevice`), and a description says which it takes
//! in a table of `RtgMatch` entries. Each device no driver has is offered
//! to the drivers whose table names it, the closest first (`attach`); the
//! driver that answers RTGERR_OK has it for good and has made a board for
//! each of its outputs (`CreateBoard`).
//!
//! What a driver keeps is allocated by the library, cleared, and found
//! again through what an op is handed - a module holds nothing in its own
//! image:
//!
//! - `state_size` bytes behind the driver's node (`RtgDriver.state`), for
//!   what is the driver's and not one board's;
//! - `RtgBoardSpec.instance_size` bytes behind each board
//!   (`RtgBoard.instance`), and `instance_size` bytes of the description
//!   behind each bus a transport driver makes (`RtgTransport.instance`).

const nodes = @import("../exec/nodes.zig");
const resident = @import("../exec/resident.zig");
const boards = @import("boards.zig");
const transport = @import("transport.zig");
const tagitem = @import("../utility/tagitem.zig");
const boardpart = @import("../expansion/boardpart.zig");
const pci = @import("../pci/pci.zig");

const Node = nodes.Node;
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const ExpansionBase = @import("../../interface/expansion.zig").ExpansionBase;
const RtgDriverBase = @import("../../interface/rtgdriver.zig").RtgDriverBase;

/// RtgDriverSpec.kind: what the driver makes - boards, of the devices it
/// is offered (`attach`), or buses (`create_transport`). A driver may be
/// both.
pub const RTGDT_BOARD: u32 = 1 << 0;
pub const RTGDT_TRANSPORT: u32 = 1 << 1;

/// RtgDriverSpec.flags: this driver's node, handles and instances are read
/// from its own interrupts, so they must be in memory the CPU reaches
/// quickly and without waiting on whatever the display is being fed from.
/// Without it they are allocated wherever there is room, which on a
/// machine whose spare memory is the same memory a display streams out of
/// means every read from an interrupt queues behind the stream.
pub const RTGDF_INTERNAL_INSTANCE: u32 = 1 << 0;

/// RtgMatch.fields: which of an entry's fields a device has to have. A
/// part's chip and its bus are those of the board's list (`CHIP_*`,
/// `BUS_*`); a vendor, a device and a class are a PCI function's.
pub const RTGMATCH_CHIP: u32 = 1 << 0;
pub const RTGMATCH_BUS: u32 = 1 << 1;
pub const RTGMATCH_VENDOR: u32 = 1 << 2;
pub const RTGMATCH_DEVICE: u32 = 1 << 3;
pub const RTGMATCH_CLASS: u32 = 1 << 4;

/// One kind of device a driver takes. A driver's table of them ends with
/// an entry whose `fields` is 0. A device is named by an entry when every
/// field the entry counts is the device's. The closer an entry names it,
/// the sooner its driver is asked: a chip, or a vendor with a device,
/// above a bus, a vendor alone or a class.
pub const RtgMatch = extern struct {
    /// RTGMATCH_*: the fields below that count. 0 ends the table.
    fields: u32 = 0,
    /// Among entries that name a device as closely, the higher is asked
    /// first.
    priority: i32 = 0,
    /// A panel part's chip and bus.
    chip: u32 = 0,
    bus: u32 = 0,
    /// A PCI function's vendor and device.
    vendor: u32 = 0,
    device: u32 = 0,
    /// A PCI function's class, compared under `class_mask`.
    class_code: u32 = 0,
    class_mask: u32 = 0,
};

/// What a driver fills in for the library to call.
pub const RtgDriverOps = extern struct {
    /// A device the driver's table names is offered, with its tags. The
    /// driver looks at the hardware, makes a board for each output it
    /// finds (`CreateBoard`) and brings each up as far as its first show
    /// needs: its ops are in the board's description, and its modes, its
    /// display memory (`RtgBoard.region`) and its info it fills in before
    /// it answers. RTGERR_OK: it has the device from now on, and its
    /// boards join the library's list. Anything else: it declines - it
    /// has given back what it took, and deleted the boards it made
    /// (`DeleteBoard`) - and the next driver is asked. May wait.
    attach: ?*const fn (*RtgDriver, *RtgDevice, ?[*]const tagitem.TagItem) callconv(.c) i32 = null,
    /// The device is taken from the driver (`RemRtgDevice`): stop the
    /// hardware. The library has marked its boards as gone already, and
    /// they stay handles. Null for a driver whose devices never go.
    detach: ?*const fn (*RtgDriver, *RtgDevice) callconv(.c) void = null,
    /// A transport driver's: make the bus `OpenTransport` asks for, from
    /// the device's tags. The library has allocated and cleared the
    /// handle and its instance. RTGERR_OK or why not.
    create_transport: ?*const fn (*RtgDriver, *transport.RtgTransport, ?[*]const tagitem.TagItem) callconv(.c) i32 = null,
};

/// A driver's constant description: what it is called, what it takes and
/// what the library calls. It lies in the driver's image and is read
/// there.
pub const RtgDriverSpec = extern struct {
    /// The driver's name ("rgb", "qspi"): its boards are called by it and
    /// a number ("rgb.0").
    name: [*:0]const u8,
    /// What the driver calls itself, with its version and date.
    id_string: ?[*:0]const u8 = null,
    version: u16 = 0,
    revision: u16 = 0,
    /// RTGDT_*
    kind: u32 = 0,
    /// RTGDF_*
    flags: u32 = 0,
    /// Where it stands on the library's list, highest first.
    priority: i8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// The devices it takes, ended by an entry whose `fields` is 0; null
    /// for a driver that says none.
    matches: ?[*]const RtgMatch = null,
    ops: *const RtgDriverOps,
    /// Bytes of the driver's own the library allocates behind its node and
    /// clears (`RtgDriver.state`). 0: none.
    state_size: u32 = 0,
    /// Bytes of the driver's own the library allocates behind each bus a
    /// transport driver makes, and clears. 0: none. What a board's driver
    /// keeps with a board is in the board's description
    /// (`RtgBoardSpec.instance_size`).
    instance_size: u32 = 0,
};

/// A driver's ROM tag: rt_Type is NT_RTG_DRIVER (.rtg_driver), rt_Flags 0
/// and rt_Init null, so InitCode never starts it and InitResident does
/// nothing with it. rtg.library finds it by its type and reads `spec`.
pub const ResidentRtgDriver = extern struct {
    resident: resident.Resident,
    spec: RtgDriverSpec,
};

// tools/ressize.zig finds a driver's module in a 32-bit image by the ops
// its tag names, which it reads at this place.
comptime {
    if (@sizeOf(usize) == 4 and @offsetOf(ResidentRtgDriver, "spec") + @offsetOf(RtgDriverSpec, "ops") != 56) {
        @compileError("ResidentRtgDriver's ops moved: tools/ressize.zig reads them 56 bytes into the tag");
    }
}

/// A driver on the library's list: the node `AddRtgDriver` made for a
/// description. It is the library's; a driver reads it and writes only
/// what `state` points at.
pub const RtgDriver = extern struct {
    /// ln_Name is the description's name; ln_Pri its priority, which
    /// orders the list, highest first.
    node: Node = .{},
    spec: *const RtgDriverSpec,
    /// The driver's own: `spec.state_size` bytes, cleared when the driver
    /// joined the list. Null for a driver that asks for none.
    state: ?*anyopaque = null,
    /// exec, for the driver's calls.
    sys_base: *ExecBase,
    /// rtg.library as a driver calls it.
    rtg_base: *RtgDriverBase,
    /// expansion.library, open for as long as the driver is on the list;
    /// null on a machine that has none.
    expansion_base: ?*ExpansionBase = null,
    /// The segments of a driver that was loaded, or null for one in ROM.
    seg_list: ?*anyopaque = null,
    /// The devices it has, and the boards and buses of it alive.
    /// RemRtgDriver refuses while any is not zero.
    devices: u32 = 0,
    boards: u32 = 0,
    buses: u32 = 0,
};

/// RtgDevice.kind: a panel part of the board's list - or a device made
/// from tags that say what such a part says (`AddRtgDevice`) - and a
/// display function on PCI.
pub const RTGDEV_PART: u32 = 1;
pub const RTGDEV_PCI: u32 = 2;

/// RtgDevice.flags
/// The firmware lit it: its picture is there before any driver.
pub const RTGDVF_FIRMWARE: u32 = 1 << 0;
/// No driver from the disk is bound to it.
pub const RTGDVF_DRIVER_OFF: u32 = 1 << 1;

/// Hardware a driver can drive, as the library keeps it. The library's: a
/// driver reads it and writes only `driver_data`.
pub const RtgDevice = extern struct {
    /// ln_Name is the device's name: `panel.` and its number among the
    /// board's panels ("panel.0"), or a PCI function's place
    /// ("pci.01:00.0").
    node: Node = .{},
    /// RTGDEV_*
    kind: u32 = 0,
    /// RTGDVF_*
    flags: u32 = 0,
    /// The part of the board's list it is; null for a function on PCI and
    /// for a device made from tags.
    part: ?*const boardpart.BoardPart = null,
    /// The function on PCI it is; null for a part.
    pci: ?*pci.PCIDevice = null,
    /// A part's chip and bus (`CHIP_*`, `BUS_*`); CHIP_NONE and BUS_PCI
    /// for a function on PCI.
    chip: u32 = 0,
    bus: u32 = 0,
    /// Its tags: a part's own, as the board wrote them. Null for a
    /// function on PCI, which says what it is by itself.
    tags: ?[*]const tagitem.TagItem = null,
    /// The driver that has it, or null while none does.
    driver: ?*RtgDriver = null,
    /// For the firmware's framebuffer: the function on PCI whose memory it
    /// lies in, or null where it lies in none that was found.
    behind: ?*RtgDevice = null,
    /// The driver's own, for what it keeps with the device and not with
    /// one board of it. The library never reads it.
    driver_data: ?*anyopaque = null,
};

/// The most characters of a name `RtgDriverInfo` and `RtgDeviceInfo`
/// carry, the NUL included.
pub const RTG_NAME_MAX = 32;

/// A driver, as `GetRtgDrivers` copies it out. A program on the disk may
/// be older or newer than the ROM answering it, so fields are only ever
/// added at the end.
pub const RtgDriverInfo = extern struct {
    name: [RTG_NAME_MAX]u8 = @splat(0),
    /// What the driver calls itself, with its version and date.
    id_string: [64]u8 = @splat(0),
    version: u16 = 0,
    revision: u16 = 0,
    /// RTGDT_*
    kind: u32 = 0,
    /// RTGDF_*
    flags: u32 = 0,
    priority: i32 = 0,
    /// The devices it has, and the boards and buses of it alive.
    devices: u32 = 0,
    boards: u32 = 0,
    buses: u32 = 0,
    /// Whether it was loaded from a file; a driver in ROM is not.
    loaded: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
};

/// A device, as `GetRtgDevices` copies it out. Fields are only ever added
/// at the end.
pub const RtgDeviceInfo = extern struct {
    name: [RTG_NAME_MAX]u8 = @splat(0),
    /// What the hardware is called, for people to read: a part's chip
    /// name; empty for a function on PCI.
    chip_name: [RTG_NAME_MAX]u8 = @splat(0),
    /// The driver that has it; empty while none does.
    driver: [RTG_NAME_MAX]u8 = @splat(0),
    /// The device the firmware's framebuffer lies behind; empty for any
    /// other device and where it lies behind none.
    behind: [RTG_NAME_MAX]u8 = @splat(0),
    /// RTGDEV_*
    kind: u32 = 0,
    /// RTGDVF_*
    flags: u32 = 0,
    chip: u32 = 0,
    bus: u32 = 0,
    /// A PCI function's vendor, device and class code; 0 for a part.
    vendor: u32 = 0,
    device: u32 = 0,
    class_code: u32 = 0,
    /// How many boards its driver made of it.
    boards: u32 = 0,
};
