// SPDX-License-Identifier: MPL-2.0
//! CreateBoard: A board for one output of a device, from the driver's
//! attach.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const Private = _board.Private;
const registry = @import("../driver/_driver.zig");
const devices = @import("../device/_device.zig");
const _board = @import("_board.zig");

/// Makes a board for one output of a device.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateBoard(rb: *RtgBase, driver: *rtg.RtgDriver, device: *rtg.RtgDevice, spec: *const rtg.RtgBoardSpec) ?*rtg.RtgBoard
/// ```
///
/// SINCE: 1.18. LVO -340.
///
/// INPUTS:
/// - `driver` - the driver that makes it: the one whose `attach` is
///   running for `device`.
/// - `device` - the device the board is an output of.
/// - `spec` - what the driver says of the board: its ops, what the output
///   is called, how many bytes of its own it keeps with the board, what
///   is true of it from the start, where its buffers come from, and which
///   output of the device it is. Read during the call and not kept; the
///   label's string stays the driver's.
///
/// RESULT:
/// The board, or null: when `driver` is not being offered `device`, and
/// without memory.
///
/// BEHAVIOR:
/// The board's handle and the driver's instance come from memory the
/// driver can read from its interrupts (`RTGDF_INTERNAL_INSTANCE`), the
/// instance cleared. The handle has the driver, the device, the ops, the
/// region and the flags of the description; the driver fills in the
/// rest - its modes (`AddBoardMode`), its info, the region where it was
/// not known - before its `attach` answers. The board is on no list yet and has no name: it
/// joins the library's list once the `attach` has answered `RTGERR_OK`,
/// named after its driver and a number in the order the driver's boards
/// were made ("rgb.0"), the firmware's picture last on the list. A board
/// comes up in no mode and showing nothing; `SetBoardMode` and
/// `ShowBitMap` are what put a picture up.
///
/// An `attach` that fails after making a board deletes it (`DeleteBoard`);
/// one it leaves is freed by the library.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: called inside `attach`, with the device list's and the driver
///   list's locks held by the caller's task.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The board is the library's from when it joins the list, and is never
/// freed for a program; until then it is the driver's to delete. The
/// driver is one board more.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeleteBoard`, `AddBoardMode`, `BindRtgDrivers`, `AddRtgDevice`,
/// `NextBoard`
///
/// EXAMPLES:
/// ```zig
/// const board = rb.CreateBoard(driver, device, &.{ .ops = &ops, .instance_size = @sizeOf(Panel) }) orelse return rtg.errors.RTGERR_NO_MEMORY;
/// ```
pub fn CreateBoard(rb: *RtgBase, driver: *rtg.RtgDriver, device: *rtg.RtgDevice, spec: *const rtg.RtgBoardSpec) ?*rtg.RtgBoard {
    const sys = rb.sys_base;
    const of_device = devices.privateOf(device);
    // Only the driver the device is being offered to makes a board of it.
    if (of_device.offered_to != driver) return null;

    // A driver whose interrupts read its handle wants that handle in
    // memory it can read without queueing behind a display's own stream.
    const where = registry.memoryFor(driver.spec);
    const memory = sys.AllocVec(@sizeOf(Private), where) orelse return null;
    const private: *Private = @ptrCast(@alignCast(memory));
    private.* = .{};
    sys.InitSemaphore(&private.lock);
    const board = &private.board;

    board.node.type = .graphics;
    board.rtg_base = @ptrCast(rb);
    board.driver = driver;
    board.device = device;
    board.unit = spec.unit;
    board.ops = spec.ops;
    board.region = spec.region;
    board.info.driver = driver.spec.name;
    board.info.id_string = driver.spec.id_string;
    board.info.label = spec.label;
    board.info.flags = spec.flags;
    sys.NewList(&private.modes);
    sys.NewList(&board.bitmaps);
    for (&board.event_lists) |*events| sys.NewList(events);

    if (spec.instance_size != 0) {
        board.instance = sys.AllocVec(spec.instance_size, where) orelse {
            sys.FreeVec(memory);
            return null;
        };
        board.instance_size = spec.instance_size;
    }

    driver.boards += 1;
    sys.AddTail(&of_device.boards, &private.device_link);
    return board;
}
