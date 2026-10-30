// SPDX-License-Identifier: MIT
//! CopyBrokerList: a copy of every broker, onto a list of the caller's.

const sdk = @import("sdk");
const exec = sdk.exec;
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// Copies every broker onto a list of the caller's.
///
/// SYNOPSIS:
/// ```zig
/// fn CopyBrokerList(base: *CxBase, list: *exec.List) i32
/// ```
///
/// SINCE: 1.0. LVO -120.
///
/// INPUTS:
/// - `list` - an initialised list; what CopyBrokerList put on it before
///   is freed first.
///
/// RESULT:
/// How many brokers were copied.
///
/// BEHAVIOR:
/// A `BrokerCopy` for each broker goes on the end of `list`, in the
/// network's order, highest priority first: its name (the node's name),
/// title, description, task, port, and in `flags` COF_ACTIVE and
/// COF_SHOW_HIDE. Memory running out ends the copy where it is.
///
/// CONTEXT:
/// - Waits: for the network's lock.
/// - Interrupts: no.
/// - Locks: takes the network's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The copies are the caller's, to give back with FreeBrokerList. They
/// are a moment's picture: a broker may go while the caller reads its
/// copy, so a copy's task and port are for reading, not for use.
///
/// NOTES:
/// A controller copies the list again on each CXCMD_LIST_CHG.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeBrokerList`, `BrokerCommand`
///
/// EXAMPLES:
/// ```zig
/// var list: exec.List = .{};
/// list.init(.unknown);
/// _ = cb.CopyBrokerList(&list);
/// defer cb.FreeBrokerList(&list);
/// var it = list.iterator();
/// while (it.next()) |node| show(@as(*cx.BrokerCopy, @ptrCast(node)));
/// ```
pub fn CopyBrokerList(base: *CxBase, list: *exec.List) i32 {
    const sys = base.sys_base;
    base.iface().FreeBrokerList(list);
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    var count: i32 = 0;
    var it = base.brokers.iterator();
    while (it.next()) |node| {
        const object: *_base.Object = @ptrCast(@alignCast(node));
        const block = sys.AllocMem(@sizeOf(cx.BrokerCopy), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse break;
        const copy: *cx.BrokerCopy = @ptrCast(@alignCast(block));
        const broker = &object.data.broker;
        copy.* = .{
            .name_buffer = broker.name,
            .title = broker.title,
            .descr = broker.descr,
            .task = broker.task,
            .port = broker.port,
            .flags = object.flags & (cx.COF_ACTIVE | cx.COF_SHOW_HIDE),
        };
        copy.node.name = @ptrCast(&copy.name_buffer);
        copy.node.pri = object.node.pri;
        sys.AddTail(list, &copy.node);
        count += 1;
    }
    return count;
}
