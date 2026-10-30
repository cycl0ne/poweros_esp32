// SPDX-License-Identifier: MIT
//! CxBroker: a program's place in the network.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const _broker = @import("_broker.zig");
const _input = @import("../input/_input.zig");
const CxBase = _base.CxBase;

/// Makes a broker and puts it on the network's list.
///
/// SYNOPSIS:
/// ```zig
/// fn CxBroker(base: *CxBase, nb: *const cx.NewBroker, err: ?*i32) ?*cx.CxObj
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `nb` - what the broker is: its name, its title and description for
///   the controller, what to do about a broker of the same name, its
///   priority, its port for commands. Copied: it may go once the call is
///   back.
/// - `err` - where to put why it failed, or null.
///
/// RESULT:
/// The broker, inactive; null when it is not made. `err` gets CBERR_OK,
/// CBERR_SYSERR (no memory), CBERR_DUP (`nb.unique` has NBU_UNIQUE and a
/// broker of the name is there) or CBERR_VERSION (`nb.version` is not
/// NB_VERSION).
///
/// BEHAVIOR:
/// A broker of the name already there is sent CXCMD_UNIQUE when
/// `nb.unique` has NBU_NOTIFY - the usual answer is for that program to
/// show its window - and with NBU_UNIQUE no second one is made. The new
/// broker goes on the network's list by its priority, highest first. The
/// first broker puts the library's handler on input.device's chain, at
/// priority 53, before the windowing system; any other is told to the
/// controller (CXCMD_LIST_CHG). The broker stays inactive until
/// ActivateCxObj, so a program builds its tree first.
///
/// CONTEXT:
/// - Waits: for the network's lock, and for input.device for the first
///   broker.
/// - Interrupts: no.
/// - Locks: takes the network's lock.
/// - Process: a Task will do; never a custom object's function. The
///   calling task is the broker's: CXCMD_KILL is Ctrl-E to it when the
///   broker has no port.
///
/// OWNERSHIP:
/// The broker is the caller's, to delete with DeleteCxObjAll before it
/// ends; everything attached to it goes with it.
///
/// NOTES:
/// The name is how BrokerCommand and the controller find the program:
/// one that should run once gives NBU_UNIQUE | NBU_NOTIFY and ends when
/// it gets CBERR_DUP.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ActivateCxObj`, `DeleteCxObjAll`, `BrokerCommand`, `CopyBrokerList`
///
/// EXAMPLES:
/// ```zig
/// var why: i32 = 0;
/// const broker = cb.CxBroker(&.{
///     .name = "Clock", .title = "Clock", .descr = "The time on a key",
///     .unique = cx.NBU_UNIQUE | cx.NBU_NOTIFY, .port = port,
/// }, &why) orelse return if (why == cx.CBERR_DUP) dos.RETURN_OK else dos.RETURN_FAIL;
/// ```
pub fn CxBroker(base: *CxBase, nb: *const cx.NewBroker, err: ?*i32) ?*cx.CxObj {
    var why: i32 = cx.CBERR_OK;
    defer if (err) |e| {
        e.* = why;
    };
    if (nb.version != cx.NB_VERSION) {
        why = cx.CBERR_VERSION;
        return null;
    }
    const sys = base.sys_base;
    const library = base.iface();
    sys.ObtainSemaphore(&base.lock);
    if (_broker.find(base, nb.name)) |there| {
        if (nb.unique & cx.NBU_NOTIFY != 0) _ = _broker.command(base, there, cx.CXCMD_UNIQUE);
        if (nb.unique & cx.NBU_UNIQUE != 0) {
            sys.ReleaseSemaphore(&base.lock);
            why = cx.CBERR_DUP;
            return null;
        }
    }
    sys.ReleaseSemaphore(&base.lock);

    const handle = library.CreateCxObj(cx.CX_BROKER, @intFromPtr(nb), 0) orelse {
        why = cx.CBERR_SYSERR;
        return null;
    };
    const object = _base.objectOf(handle);
    sys.ObtainSemaphore(&base.lock);
    // Looked at again: another program may have made one meanwhile.
    if (nb.unique & cx.NBU_UNIQUE != 0 and _broker.find(base, nb.name) != null) {
        sys.ReleaseSemaphore(&base.lock);
        library.DeleteCxObj(handle);
        why = cx.CBERR_DUP;
        return null;
    }
    const first = base.brokers.isEmpty();
    sys.Enqueue(&base.brokers, &object.node);
    object.flags |= _base.COF_INLIST;
    sys.ReleaseSemaphore(&base.lock);

    if (first) _input.updateHandler(base) else _ = library.BrokerCommand(null, cx.CXCMD_LIST_CHG);
    return handle;
}
