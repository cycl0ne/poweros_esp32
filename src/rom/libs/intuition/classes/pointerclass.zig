// SPDX-License-Identifier: MPL-2.0
//! pointerclass: a mouse pointer a window can have.
//!
//! An object is a picture - a surface with an alpha channel, the
//! caller's - and where it goes from the pointer's point
//! (`POINTERA_XOffset`, `POINTERA_YOffset`, 0 or less). It draws nothing
//! and answers nothing of its own: the pointer reads it when a window that
//! has it (`WA_Pointer`) becomes active, and hands the picture to the
//! board, which makes its own copy. So a change to an object the pointer
//! is showing is shown at once, and an object disposed of is taken off
//! every window first (`input/pointer.zig`).

const sdk = @import("sdk");
const utility = sdk.utility;
const rtg = sdk.rtg;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const pc = intuition.pointerclass;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const pointer = @import("../input/pointer.zig");

/// pointerclass's part of an object.
pub const Data = extern struct {
    bitmap: ?*const rtg.Surface = null,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
};

/// An object's picture and offsets.
pub fn dataOf(ib: *IntuitionBase, o: *Object) *Data {
    return classes.instData(Data, ib.pointer_class.?, o);
}

/// Make pointerclass, from rootclass, and put it on the public list.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.POINTERCLASS, classusr.ROOTCLASS, null, @sizeOf(Data)) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

/// Whether any of the tags was one of this class's.
fn setAttrs(ib: *IntuitionBase, own: *Data, tags: ?[*]const TagItem) bool {
    var state = tags;
    var any = false;
    while (ib.utility_base.NextTagItem(&state)) |item| {
        switch (item.tag) {
            pc.POINTERA_BitMap => own.bitmap = @ptrFromInt(item.data),
            pc.POINTERA_XOffset => own.x_offset = @truncate(@as(isize, @bitCast(item.data))),
            pc.POINTERA_YOffset => own.y_offset = @truncate(@as(isize, @bitCast(item.data))),
            else => continue,
        }
        any = true;
    }
    return any;
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
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            _ = setAttrs(ib, classes.instData(Data, cl, @ptrFromInt(made)), set.attr_list);
            return made;
        },
        classusr.OM_SET => {
            _ = it.SendSuperMessage(cl, o, msg);
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            if (!setAttrs(ib, classes.instData(Data, cl, o.?), set.attr_list)) return 0;
            pointer.changed(ib, o.?);
            return 1;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            switch (get.attr_id) {
                pc.POINTERA_BitMap => get.storage.* = @intFromPtr(own.bitmap),
                pc.POINTERA_XOffset => get.storage.* = @bitCast(@as(isize, own.x_offset)),
                pc.POINTERA_YOffset => get.storage.* = @bitCast(@as(isize, own.y_offset)),
                else => return it.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        classusr.OM_DISPOSE => {
            pointer.forget(ib, o.?);
            return it.SendSuperMessage(cl, o, msg);
        },
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
