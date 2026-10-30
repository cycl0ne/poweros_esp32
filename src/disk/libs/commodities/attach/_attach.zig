// SPDX-License-Identifier: MIT
//! Attaching: an object onto another's list.
//!
//! The three ways - at the end, by priority, after another - differ only
//! in the list call. A missing head deletes the object and its tree, and
//! a missing object is recorded in the head, so a tree is built in one
//! line per object - `AttachCxObj(filter, CxSender(...))` - and checked
//! once at the end.

const sdk = @import("sdk");
const exec = sdk.exec;
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

pub const Where = union(enum) {
    tail,
    priority,
    /// After this node; null for the head of the list.
    after: ?*exec.Node,
};

pub fn attach(base: *CxBase, head_obj: ?*cx.CxObj, co: ?*cx.CxObj, where: Where) void {
    const sys = base.sys_base;
    const head = _base.objectOf(head_obj orelse {
        base.iface().DeleteCxObjAll(co);
        return;
    });
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    const object = _base.objectOf(co orelse {
        head.err |= cx.COERR_NULLATTACH;
        return;
    });
    switch (where) {
        .tail => sys.AddTail(&head.list, &object.node),
        .priority => sys.Enqueue(&head.list, &object.node),
        .after => |pred| sys.Insert(&head.list, &object.node, pred),
    }
    object.flags |= _base.COF_INLIST;
}
