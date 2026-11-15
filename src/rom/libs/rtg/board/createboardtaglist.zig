// SPDX-License-Identifier: MPL-2.0
//! CreateBoardTagList: A board from that driver, set up by the tags
//! (RTGA_*).

const sdk = @import("sdk");
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const RtgBase = @import("../rtg.zig").RtgBase;
const claimOf = _board.claimOf;
const countModes = _board.countModes;
const capsOf = _board.capsOf;
const setName = _board.setName;
const Private = _board.Private;
const err = rtg.errors;
const registry = @import("../driver/_driver.zig");
const memory_mod = @import("../memory/_memory.zig");
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
///   talks through, whether to switch the display on, a brightness,
///   whether its screens' windows are composed (`RTGA_Compose`), and data
///   for the driver.
///
/// RESULT:
/// The board, or null: for no driver of that name that makes boards, no
/// memory, or a driver that could not make it.
///
/// BEHAVIOR:
/// The board's handle and the driver's instance come from memory the
/// driver can read from its interrupts. The driver fills the handle in:
/// its modes, its display memory and what its engine can do. A board comes
/// up in no mode and showing nothing; `SetBoardMode` and `ShowBitMap` are
/// what put a picture up. Without `RTGA_BoardName` the board is named after
/// the driver and a number: rgb0, rgb1. It has its name once the driver
/// has made it, as it joins the list. `RTGA_Compose` is kept as
/// `RTGBF_COMPOSE` in the board's flags for intuition to read; the driver
/// does nothing for it.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the board list, and if the
///   driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: no spinlock may be held: a driver may wait.
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

    const driver = registry.findDriverOfType(rb, driver_name, rtg.drivers.RTGDT_BOARD) orelse {
        return null;
    };
    const spec = driver.spec;
    const create = spec.ops.create_board orelse {
        return null;
    };

    // A driver whose interrupts read its handle wants that handle in
    // memory it can read without queueing behind a display's own stream.
    const where = registry.memoryFor(spec);
    const memory = sys.AllocVec(@sizeOf(Private), where) orelse {
        return null;
    };
    const private: *Private = @ptrCast(@alignCast(memory));
    private.* = .{};
    sys.InitSemaphore(&private.lock);
    const board = &private.board;

    board.node.type = .graphics;
    board.rtg_base = @ptrCast(rb);
    board.driver = driver;
    board.transport = request.transport;
    board.user_data = request.user_data;
    board.info.driver = spec.name;
    board.info.id_string = spec.id_string;
    sys.NewList(&board.modes);
    sys.NewList(&board.bitmaps);
    for (&board.event_lists) |*list| sys.NewList(list);

    if (spec.instance_size != 0) {
        board.instance = sys.AllocVec(spec.instance_size, where) orelse {
            sys.FreeVec(memory);
            return null;
        };
        board.instance_size = spec.instance_size;
    }

    const code = create(driver, board, tag_list);
    if (code != err.RTGERR_OK) {
        if (board.instance) |instance| sys.FreeVec(instance);
        sys.FreeVec(memory);
        return null;
    }

    // What the driver said it can do, and what it left to the caller.
    board.info.caps = if (board.ops) |ops| capsOf(ops) else 0;
    // Whether its screens' windows are composed is the board's to say,
    // for intuition to read: the driver has nothing to do with it.
    if (request.compose) board.info.flags |= rtg.boards.RTGBF_COMPOSE;
    board.info.modes = countModes(board);

    // The display memory it reported, cut up from here on by the library.
    const alignment: u32 = if (request.alignment != 0)
        request.alignment
    else if (board.region.alignment != 0)
        board.region.alignment
    else
        0;
    if (board.region.flags & rtg.boards.RTGRF_SYSTEM_MEMORY != 0) {
        private.arena.initSystem(sys, board.region.size, alignment, memory_mod.attributesOf(board.region.flags));
    } else {
        private.arena.init(sys, @intFromPtr(board.region.base), board.region.size, alignment);
    }
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
    driver.boards += 1;

    // Named as it joins the list, under the list's lock: the number is
    // read and raised by one board at a time, and only a board that was
    // made takes one.
    sys.ObtainSemaphore(&rb.board_lock);
    setName(rb, private, driver_name, request.name, rb.board_serial);
    board.info.name = board.node.name;
    rb.board_serial += 1;
    sys.AddTail(&rb.boards, &board.node);
    sys.ReleaseSemaphore(&rb.board_lock);

    if (request.display_on) _ = rtg_lib.SetBoardDisplay(board, true);
    if (request.brightness) |percent| _ = rtg_lib.SetBoardBrightness(board, percent);

    return board;
}
