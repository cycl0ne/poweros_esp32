// SPDX-License-Identifier: MPL-2.0
//! rootclass: the top of every class, and the one that makes an object
//! exist.
//!
//! It adds no instance data. What it does is allocate an object - the
//! header and the data of every class from here down to the true class,
//! in one block, cleared - and free it again, and put an object on a list
//! and take it off. Every other method it answers with 0, which is what a
//! class that passes on a message it does not know is told.
//!
//! Its dispatcher reaches the library through the class's `user_data`,
//! which is where a class's owner keeps what its dispatcher needs; a
//! module has no globals to keep it in.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const Class = classes.Class;
const Object = classes.Object;
const ObjectHeader = classes.ObjectHeader;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Make rootclass and put it on the public list. Null if there was no
/// memory.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.ROOTCLASS, null, null, 0) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const ib: *IntuitionBase = @ptrFromInt(cl.user_data);
    const it = ib.iface();
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    switch (msg.method_id) {
        classusr.OM_NEW => {
            // The object is the true class while OM_NEW runs: there is no
            // object yet, and this is how the root learns how big one of
            // that class is.
            const true_class: *Class = @ptrCast(@alignCast(object orelse return 0));
            const size = classes.sizeofInstance(true_class);
            const memory = ib.sys_base.AllocMem(size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return 0;
            const header: *ObjectHeader = @ptrCast(@alignCast(memory));
            header.* = .{ .class = true_class };
            // Counted under the class list's semaphore, which FreeClass
            // holds while it looks at the count.
            _ = it.LockClassList();
            true_class.object_count += 1;
            it.UnlockClassList();
            return @intFromPtr(memory) + @sizeOf(ObjectHeader);
        },
        classusr.OM_DISPOSE => {
            const o: *Object = @ptrCast(object orelse return 0);
            const header = classes.objectHeader(o);
            const true_class = header.class;
            _ = it.LockClassList();
            true_class.object_count -= 1;
            it.UnlockClassList();
            ib.sys_base.FreeMem(header, classes.sizeofInstance(true_class));
            return 0;
        },
        classusr.OM_ADDTAIL => {
            const o: *Object = @ptrCast(object orelse return 0);
            const add: *classusr.OpAddTail = @ptrCast(@alignCast(msg));
            ib.sys_base.AddTail(@ptrCast(add.list), @ptrCast(&classes.objectHeader(o).node));
            return 1;
        },
        classusr.OM_REMOVE => {
            const o: *Object = @ptrCast(object orelse return 0);
            ib.sys_base.Remove(@ptrCast(&classes.objectHeader(o).node));
            return 1;
        },
        else => return 0,
    }
}
