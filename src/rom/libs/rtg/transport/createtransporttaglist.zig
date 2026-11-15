// SPDX-License-Identifier: MPL-2.0
//! CreateTransportTagList: A bus from that driver, set up by the tags
//! (RTGA_*).

const sdk = @import("sdk");
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const RtgBase = @import("../rtg.zig").RtgBase;
const setName = _transport.setName;
const Private = _transport.Private;
const err = rtg.errors;
const registry = @import("../driver/_driver.zig");
const tags = rtg.tags;
const _transport = @import("_transport.zig");

/// Makes a bus from a driver, for boards to talk through.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateTransportTagList(rb: *RtgBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) ?*rtg.RtgTransport
/// ```
///
/// SINCE: 1.0. LVO -172.
///
/// INPUTS:
/// - `driver_name` - the driver to make it with.
/// - `tag_list` - the `RTGA_` options: the transport's name, and data for
///   the driver.
///
/// RESULT:
/// The transport, or null: for no driver of that name that makes buses,
/// no memory, or a driver that could not make it.
///
/// BEHAVIOR:
/// A panel on a bus is two drivers: one for the bus and one for the panel,
/// which names the transport with `RTGA_Transport` when its board is made.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the board list, and if the
///   driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: no spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `DeleteTransport`. The driver is held open
/// meanwhile.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeleteTransport`, `CreateBoardTagList`, `TxParam`
///
/// EXAMPLES:
/// ```zig
/// const io = rb.CreateTransportTagList("qspi", &tags) orelse return error.NoBus;
/// ```
pub fn CreateTransportTagList(rb: *RtgBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) ?*rtg.RtgTransport {
    const sys = rb.sys_base;
    const ub = rb.utility_base;

    const driver = registry.findDriverOfType(rb, driver_name, rtg.boards.RTGDT_TRANSPORT) orelse {
        return null;
    };
    const create = driver.ops.?.create_transport orelse {
        return null;
    };

    const where = @import("../board/_board.zig").memoryFor(driver);
    const memory = sys.AllocVec(@sizeOf(Private), where) orelse {
        return null;
    };
    const private: *Private = @ptrCast(@alignCast(memory));
    private.* = .{};
    const io = &private.io;
    io.rtg_base = @ptrCast(rb);
    io.driver = @ptrCast(driver);
    setName(rb, private, driver_name, @ptrFromInt(ub.GetTagData(tags.RTGA_BoardName, 0, tag_list)));

    if (driver.instance_size != 0) {
        io.instance = sys.AllocVec(driver.instance_size, where) orelse {
            sys.FreeVec(memory);
            return null;
        };
        io.instance_size = driver.instance_size;
    }

    const code = create(driver, io, tag_list);
    if (code != err.RTGERR_OK) {
        if (io.instance) |instance| sys.FreeVec(instance);
        sys.FreeVec(memory);
        return null;
    }

    driver.open_cnt += 1;
    sys.ObtainSemaphore(&rb.board_lock);
    sys.AddTail(&rb.transports, &io.node);
    sys.ReleaseSemaphore(&rb.board_lock);

    return io;
}
