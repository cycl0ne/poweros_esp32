// SPDX-License-Identifier: MPL-2.0
//! modelclass: a connection with members.
//!
//! What arrives as `OM_NOTIFY` or `OM_UPDATE` goes to every member as
//! `OM_UPDATE`, then to the model's own target through icclass. The model
//! holds icclass's loop count for the length of the broadcast, so a member
//! that answers by notifying the model again is not heard.
//!
//! Every member gets the same tags. A member may not change them, but the
//! broadcast does not rely on that: it sends a copy, and puts the copy
//! back from the original after each member.
//!
//! A model owns its members: disposing of the model disposes of them.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const icc = intuition.icclass;
const Class = classes.Class;
const Object = classes.Object;
const Msg = classusr.Msg;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// modelclass's part of an object.
pub const Data = extern struct {
    /// The members, by the node in each one's header.
    members: exec.MinList = .{},
};

/// Make modelclass, from icclass, and put it on the public list.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.MODELCLASS, classusr.ICCLASS, null, @sizeOf(Data)) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

/// Every member told, then the target.
fn broadcast(ib: *IntuitionBase, cl: *Class, o: *Object, d: *Data, msg: *classusr.OpUpdate) void {
    const it = ib.iface();
    const ub = ib.utility_base;
    var check = Msg{ .method_id = icc.ICM_CHECKLOOP };
    if (it.SendSuperMessage(cl, o, &check) != 0) return;

    var set_loop = Msg{ .method_id = icc.ICM_SETLOOP };
    _ = it.SendSuperMessage(cl, o, &set_loop);
    // With no memory for the copy the members hear nothing; the target
    // still does, below, since it is sent the original.
    const copy = ub.CloneTagItems(msg.attr_list);
    defer ub.FreeTagItems(copy);
    if (msg.attr_list == null or copy != null) {
        var out = classusr.OpUpdate{
            .method_id = classusr.OM_UPDATE,
            .attr_list = copy,
            .gadget_info = msg.gadget_info,
            .flags = msg.flags,
        };
        var at = d.members.head;
        while (it.NextObject(&at)) |member| {
            _ = it.SendMessage(member, @ptrCast(&out));
            ub.RefreshTagItemClones(copy, msg.attr_list);
        }
    }
    var clear_loop = Msg{ .method_id = icc.ICM_CLEARLOOP };
    _ = it.SendSuperMessage(cl, o, &clear_loop);

    // Then icclass passes it to the model's own target.
    _ = it.SendSuperMessage(cl, o, @ptrCast(msg));
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const ib: *IntuitionBase = @ptrFromInt(cl.user_data);
    const it = ib.iface();
    const msg: *Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = it.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            classes.instData(Data, cl, @ptrFromInt(made)).members.init();
            return made;
        },
        classusr.OM_NOTIFY, classusr.OM_UPDATE => {
            const self = o orelse return 0;
            broadcast(ib, cl, self, classes.instData(Data, cl, self), @ptrCast(@alignCast(msg)));
            return 1;
        },
        classusr.OM_ADDMEMBER => {
            const d = classes.instData(Data, cl, o orelse return 0);
            const add: *classusr.OpMember = @ptrCast(@alignCast(msg));
            var tail = classusr.OpAddTail{ .method_id = classusr.OM_ADDTAIL, .list = &d.members };
            return it.SendMessage(add.object, @ptrCast(&tail));
        },
        classusr.OM_REMMEMBER => {
            const rem: *classusr.OpMember = @ptrCast(@alignCast(msg));
            var remove = Msg{ .method_id = classusr.OM_REMOVE };
            return it.SendMessage(rem.object, &remove);
        },
        classusr.OM_DISPOSE => {
            const d = classes.instData(Data, cl, o orelse return 0);
            var at = d.members.head;
            while (it.NextObject(&at)) |member| {
                var remove = Msg{ .method_id = classusr.OM_REMOVE };
                _ = it.SendMessage(member, &remove);
                it.DisposeObject(member);
            }
            return it.SendSuperMessage(cl, o, msg);
        },
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
