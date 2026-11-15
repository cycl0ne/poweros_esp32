// SPDX-License-Identifier: MIT
//! Drivers: what a display's or a bus's driver is to rtg.library.
//!
//! A driver is a description and nothing that runs by itself: a constant
//! `RtgDriverSpec` behind a ROM tag of type `.rtg_driver`
//! (`ResidentRtgDriver`). The tag has no init routine and no start class,
//! so exec starts nothing of it. rtg.library reads the descriptions of the
//! ROM's tags at its own init and puts each on its list (`AddRtgDriver`);
//! from then on the library calls the driver through the description's
//! `ops`, and the driver calls the library through the node it is handed.
//!
//! What a driver keeps is allocated by the library, cleared, and found
//! again through what an op is handed - a module holds nothing in its own
//! image:
//!
//! - `state_size` bytes behind the driver's node (`RtgDriver.state`), for
//!   what is the driver's and not one board's;
//! - `instance_size` bytes behind each board or bus it makes
//!   (`RtgBoard.instance`, `RtgTransport.instance`).

const nodes = @import("../exec/nodes.zig");
const resident = @import("../exec/resident.zig");
const boards = @import("boards.zig");
const transport = @import("transport.zig");
const tagitem = @import("../utility/tagitem.zig");

const Node = nodes.Node;
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const ExpansionBase = @import("../../interface/expansion.zig").ExpansionBase;
const RtgDriverBase = @import("../../interface/rtgdriver.zig").RtgDriverBase;

/// RtgDriverSpec.kind: which of the two creates the driver fills in. A
/// driver may be both.
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
/// an entry whose `fields` is 0.
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
    /// Fill the board in from the tags: its ops, its info, its modes, its
    /// region, its instance. The library has allocated and cleared it and
    /// has already read the tags every driver shares; the board gets its
    /// name once this has answered. RTGERR_OK or why not.
    create_board: ?*const fn (*RtgDriver, *boards.RtgBoard, ?[*]const tagitem.TagItem) callconv(.c) i32 = null,
    /// The same for a command bus.
    create_transport: ?*const fn (*RtgDriver, *transport.RtgTransport, ?[*]const tagitem.TagItem) callconv(.c) i32 = null,
};

/// A driver's constant description: what it is called, what it takes and
/// what the library calls. It lies in the driver's image and is read
/// there.
pub const RtgDriverSpec = extern struct {
    /// The name a board is made by ("rgb", "qspi").
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
    /// Bytes of the driver's own the library allocates behind each board
    /// or bus it makes, and clears. 0: none.
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
    /// Boards and buses of it alive. RemRtgDriver refuses while either is
    /// not zero.
    boards: u32 = 0,
    buses: u32 = 0,
};
