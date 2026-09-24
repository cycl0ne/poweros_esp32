// SPDX-License-Identifier: MPL-2.0
//! CreateBoardTagList: A board from that driver, set up by the tags
//! (RTGA_*).

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const claimOf = _board.claimOf;
const countModes = _board.countModes;
const capsOf = _board.capsOf;
const setName = _board.setName;
const Private = _board.Private;
const memoryFor = _board.memoryFor;
const err = rtg.errors;
const fail = _board.fail;
const registry = @import("../driver/_driver.zig");
const readRequest = _board.readRequest;
const _board = @import("_board.zig");

/// Makes a board from a driver.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateBoardTagList(rb: *RtgBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) ?*rtg.RtgBoard
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `driver_name` - the driver to make it with.
/// - `tag_list` - the `RTGA_` options: the board's name, a transport it
///   talks through, whether to switch the display on, a brightness, data
///   for the driver, and `RTGA_ErrorPtr` for the reason if it fails.
///
/// RESULT:
/// The board, or null. `RtgLastError` - and `RTGA_ErrorPtr`, if given -
/// then says why: `RTGERR_NO_DRIVER`, `RTGERR_NO_MEMORY`, or what the
/// driver answered.
///
/// BEHAVIOR:
/// The board's handle and the driver's instance come from memory the
/// driver can read from its interrupts. The driver fills the handle in:
/// its modes, its display memory and what its engine can do. A board comes
/// up in no mode and showing nothing; `SetBoardMode` and `ShowBitMap` are
/// what put a picture up. Without `RTGA_BoardName` the board is named after
/// the driver and a number: rgb0, rgb1.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the board list, and if the
///   driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Forbid: must not be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The board is the caller's until `DeleteBoard`. The driver and a
/// transport it names are held open meanwhile.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeleteBoard`, `SetBoardMode`, `FindBoard`
///
/// EXAMPLES:
/// ```zig
/// const tags = [_]TagItem{ .{ .tag = rtg.tags.RTGA_BoardName, .data = @intFromPtr("panel") }, .{} };
/// const board = rb.CreateBoardTagList("rgb", &tags) orelse return error.NoBoard;
/// ```
pub fn CreateBoardTagList(rb: *RtgBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) ?*rtg.RtgBoard {
    const rtg_lib = rb.iface();
    const sys = rb.sys_base;
    const request = readRequest(rb, tag_list);

    const driver = registry.findDriverOfType(rb, driver_name, rtg.boards.RTGDT_BOARD) orelse {
        fail(rb, err.RTGERR_NO_DRIVER, request.error_ptr);
        return null;
    };
    const create = driver.ops.?.create_board orelse {
        fail(rb, err.RTGERR_NO_DRIVER, request.error_ptr);
        return null;
    };

    // A driver whose interrupts read its handle wants that handle in
    // memory it can read without queueing behind a display's own stream.
    const where = memoryFor(driver);
    const memory = sys.AllocVec(@sizeOf(Private), where) orelse {
        fail(rb, err.RTGERR_NO_MEMORY, request.error_ptr);
        return null;
    };
    const private: *Private = @ptrCast(@alignCast(memory));
    private.* = .{};
    const board = &private.board;

    board.node.type = .graphics;
    board.rtg_base = @ptrCast(rb);
    board.driver = driver;
    board.transport = request.transport;
    board.user_data = request.user_data;
    board.info.driver = driver.node.name;
    board.info.id_string = driver.id_string;
    setName(rb, private, driver_name, request.name, rb.board_serial);
    board.info.name = board.node.name;
    sys.NewList(&board.modes);
    sys.NewList(&board.bitmaps);
    for (&board.event_lists) |*list| sys.NewList(list);

    if (driver.instance_size != 0) {
        board.instance = sys.AllocVec(driver.instance_size, where) orelse {
            sys.FreeVec(memory);
            fail(rb, err.RTGERR_NO_MEMORY, request.error_ptr);
            return null;
        };
        board.instance_size = driver.instance_size;
    }

    const code = create(driver, board, tag_list);
    if (code != err.RTGERR_OK) {
        if (board.instance) |instance| sys.FreeVec(instance);
        sys.FreeVec(memory);
        fail(rb, code, request.error_ptr);
        return null;
    }

    // What the driver said it can do, and what it left to the caller.
    board.info.caps = if (board.ops) |ops| capsOf(ops) else 0;
    board.info.modes = countModes(board);

    // The display memory it reported, cut up from here on by the library.
    private.arena.init(sys, @intFromPtr(board.region.base), board.region.size, if (request.alignment != 0)
        request.alignment
    else if (board.region.alignment != 0)
        board.region.alignment
    else
        0);
    board.region.alignment = private.arena.alignment;
    board.info.memory_total = private.arena.free_bytes;

    // A driver that came to a display already running hands back the
    // buffer it is being refreshed from. That memory is spoken for: it is
    // taken out of what the library may hand to anybody else.
    if (board.showing) |shown| {
        if (claimOf(board, &private.arena, shown)) |claim| {
            _ = private.arena.reserve(sys, claim.offset, claim.bytes);
        }
        shown.flags |= rtg.bitmaps.RTGBMF_SHOWING;
        board.info.flags |= rtg.boards.RTGBF_SHOWING;
    }

    if (request.transport) |io| io.open_cnt += 1;
    driver.open_cnt += 1;

    sys.ObtainSemaphore(&rb.board_lock);
    sys.AddTail(&rb.boards, &board.node);
    rb.board_serial += 1;
    sys.ReleaseSemaphore(&rb.board_lock);

    if (request.display_on) _ = rtg_lib.SetBoardDisplay(board, true);
    if (request.brightness) |percent| _ = rtg_lib.SetBoardBrightness(board, percent);

    rb.last_error = err.RTGERR_OK;
    if (request.error_ptr) |p| p.* = err.RTGERR_OK;
    return board;
}
