// SPDX-License-Identifier: MIT
//! Brokers: what one keeps, and a command sent to one.

const sdk = @import("sdk");
const exec = sdk.exec;
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const _message = @import("../message/_message.zig");
const CxBase = _base.CxBase;
const Object = _base.Object;

/// `to` filled with as much of `from` as fits, the end of string
/// included.
fn copyName(to: []u8, from: [*:0]const u8) void {
    var n: usize = 0;
    while (n < to.len - 1 and from[n] != 0) : (n += 1) to[n] = from[n];
    @memset(to[n..], 0);
}

/// A new broker's object from its NewBroker: the strings copied, the
/// calling task kept, inactive.
pub fn initBroker(base: *CxBase, object: *Object, nb: *const cx.NewBroker) void {
    object.data = .{ .broker = .{} };
    const broker = &object.data.broker;
    copyName(&broker.name, nb.name);
    copyName(&broker.title, nb.title);
    copyName(&broker.descr, nb.descr);
    broker.task = base.sys_base.FindTask(null);
    broker.port = nb.port;
    object.flags = (object.flags | (nb.flags & cx.COF_SHOW_HIDE)) & ~_base.COF_ENABLE;
    object.node.name = @ptrCast(&broker.name);
    object.node.pri = @intCast(@max(-128, @min(127, nb.pri)));
}

/// Command `id` to `object`'s program: CMDE_.
pub fn command(base: *CxBase, object: ?*Object, id: i32) i32 {
    const broker = &(object orelse return cx.CMDE_NOBROKER).data.broker;
    const sys = base.sys_base;
    const port = broker.port orelse {
        // A program that takes no commands is told to go by Ctrl-E.
        if (id == cx.CXCMD_KILL) {
            if (broker.task) |task| sys.Signal(task, exec.SIGBREAKF_CTRL_E);
        }
        return cx.CMDE_NOPORT;
    };
    const message = _message.create(base, cx.CXM_COMMAND, null) orelse return cx.CMDE_NOMEM;
    message.id = id;
    sys.PutMsg(port, &message.msg);
    return cx.CMDE_OK;
}

/// The broker called `name`, under the network's lock.
pub fn find(base: *CxBase, name: [*:0]const u8) ?*Object {
    return @ptrCast(@alignCast(base.sys_base.FindName(&base.brokers, name)));
}
