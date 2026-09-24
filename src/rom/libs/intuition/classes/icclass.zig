// SPDX-License-Identifier: MPL-2.0
//! icclass: a connection that passes on what changed.
//!
//! What arrives as `OM_NOTIFY` or `OM_UPDATE` goes to the target as
//! `OM_UPDATE`, its tags translated through the map. Two things are done
//! differently from the obvious way, both so a sender gets back exactly
//! what it sent: the tags are mapped in a copy rather than in the sender's
//! own list, and the message passed on is a new one rather than the
//! sender's with its method changed.
//!
//! The loop count is what stops two connections that are each other's
//! targets: one that is already passing something on passes nothing more.
//! It is also sent as `ICM_SETLOOP`/`ICM_CLEARLOOP`/`ICM_CHECKLOOP`, which
//! is how modelclass holds it for the length of a broadcast.

const sdk = @import("sdk");
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const icc = intuition.icclass;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");

/// icclass's part of an object.
pub const Data = extern struct {
    /// ICA_TARGET: null passes nothing on; `ICTARGET_IDCMP` is kept for
    /// windows.
    target: usize = 0,
    /// ICA_MAP, not copied.
    map: ?[*]const TagItem = null,
    /// How deep in passing something on it is. 0 is free.
    loop_count: u32 = 0,
};

/// Make icclass, from rootclass, and put it on the public list.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.ICCLASS, classusr.ROOTCLASS, null, @sizeOf(Data)) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

fn setAttrs(ib: *IntuitionBase, d: *Data, tags: ?[*]const TagItem) void {
    if (ib.utility_base.FindTagItem(icc.ICA_MAP, tags)) |item| d.map = @ptrFromInt(item.data);
    if (ib.utility_base.FindTagItem(icc.ICA_TARGET, tags)) |item| d.target = item.data;
}

/// Pass an update on to the target, mapped, unless this connection is
/// already passing one on.
fn forward(ib: *IntuitionBase, d: *Data, msg: *const classusr.OpUpdate) void {
    if (d.target == 0 or d.loop_count != 0) return;
    const ub = ib.utility_base;

    d.loop_count += 1;
    defer d.loop_count -%= 1;

    var out = classusr.OpUpdate{
        .method_id = classusr.OM_UPDATE,
        .attr_list = msg.attr_list,
        .gadget_info = msg.gadget_info,
        .flags = msg.flags,
    };
    // A window's message port is a target like any other, but it is told
    // by having a list of its own put in an IDCMP message rather than by a
    // method: the window keeps that list until the program replies. Which
    // window is the one the update came through.
    if (d.target == icc.ICTARGET_IDCMP) {
        const tags = msg.attr_list orelse return;
        const gi = msg.gadget_info orelse return;
        const told = ub.CloneTagItems(tags) orelse return;
        if (d.map != null) ub.MapTags(told, d.map, utility.tagitem.MAP_KEEP_NOT_FOUND);
        const interim = msg.flags & classusr.OPUF_INTERIM != 0;
        if (!_window.sendUpdate(ib, @ptrCast(@alignCast(gi.window)), told, interim)) ub.FreeTagItems(told);
        return;
    }

    var copy: ?[*]TagItem = null;
    defer ub.FreeTagItems(copy);
    if (d.map != null and msg.attr_list != null) {
        // A copy, so the sender's list comes back as it went.
        copy = ub.CloneTagItems(msg.attr_list) orelse return;
        ub.MapTags(copy, d.map, utility.tagitem.MAP_KEEP_NOT_FOUND);
        out.attr_list = copy;
    }
    _ = ib.iface().SendMessage(@ptrFromInt(d.target), @ptrCast(&out));
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const ib: *IntuitionBase = @ptrFromInt(cl.user_data);
    const it = ib.iface();
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = it.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            setAttrs(ib, classes.instData(Data, cl, @ptrFromInt(made)), new.attr_list);
            return made;
        },
        classusr.OM_SET => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            setAttrs(ib, classes.instData(Data, cl, o orelse return 0), set.attr_list);
            return it.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_GET => {
            // The target and the map are given, not asked for.
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            if (get.attr_id == icc.ICA_TARGET or get.attr_id == icc.ICA_MAP) return 0;
            return it.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_NOTIFY, classusr.OM_UPDATE => {
            forward(ib, classes.instData(Data, cl, o orelse return 0), @ptrCast(@alignCast(msg)));
            return 1;
        },
        icc.ICM_SETLOOP => {
            classes.instData(Data, cl, o orelse return 0).loop_count += 1;
            return 1;
        },
        icc.ICM_CLEARLOOP => {
            classes.instData(Data, cl, o orelse return 0).loop_count -%= 1;
            return 1;
        },
        icc.ICM_CHECKLOOP => return classes.instData(Data, cl, o orelse return 0).loop_count,
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
