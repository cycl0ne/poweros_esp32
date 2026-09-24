// SPDX-License-Identifier: MPL-2.0
//! groupgclass: a gadget made of gadgets.
//!
//! Members go in with `OM_ADDMEMBER` and come out with `OM_REMMEMBER`, and
//! the group stands in for all of them: it draws each in turn, hands a
//! press to whichever one is under it, and passes on what that one
//! answers, so the window sees one gadget where the program keeps several.
//!
//! **A member is placed inside the group and kept in the window.** Its
//! `GA_Left` and `GA_Top` when it joins are where it sits in the group;
//! the group adds its own corner to them there and then, so from that
//! moment the member is a gadget of the window like any other and draws
//! itself where it is. The group grows to hold it. Moving the group moves
//! every member by the same amount.
//!
//! Disposing of the group disposes of its members, since they are its.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const gadgetclass = @import("gadgetclass.zig");
const _gadget = @import("../gadget/_gadget.zig");

/// groupgclass's part of an object.
pub const Data = extern struct {
    /// Its members, on a list through each object's own node - the one
    /// `OM_ADDTAIL` puts there and `NextObject` walks. A list rather than a
    /// fixed few, so that a group holds what it is given and anything that
    /// can walk a list of objects can walk this one.
    members: exec.MinList = .{},
    /// The member a hit test last landed in: the one that goes active.
    active: ?*Object = null,
};

/// Each member in turn.
const Walk = struct {
    ib: *IntuitionBase,
    state: ?*exec.MinNode,

    fn over(ib: *IntuitionBase, p: *Data) Walk {
        return .{ .ib = ib, .state = p.members.head };
    }

    fn next(w: *Walk) ?*Object {
        return w.ib.iface().NextObject(&w.state);
    }
};

/// Make groupgclass, from gadgetclass, and put it on the public list.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.GROUPGCLASS, classusr.GADGETCLASS, null, @sizeOf(Data)) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

fn own(cl: *Class, o: *Object) *Data {
    return classes.instData(Data, cl, o);
}

/// Where a gadget is, with `GA_Rel*` worked out against the room it is
/// measured in - which is the window's, since a member is a gadget of the
/// window once it has joined. Without the GadgetInfo there is no room to
/// measure against and the raw edges are all there is.
fn cornerOf(ib: *IntuitionBase, o: *Object, gi: ?*classusr.GadgetInfo) _gadget.Box {
    const g = gadgetclass.gadgetOf(ib, o);
    if (gi) |info| return _gadget.boxIn(g, info.domain_width, info.domain_height);
    return .{ .left = g.left, .top = g.top, .width = g.width, .height = g.height };
}

/// A member put somewhere else. The GadgetInfo goes with it, because that
/// is what tells the member which window it is in - without one it changes
/// where it thinks it is and never draws itself there.
fn moveTo(ib: *IntuitionBase, o: *Object, gi: ?*classusr.GadgetInfo, left: i32, top: i32) void {
    const tags = [_]TagItem{
        .{ .tag = gc.GA_Left, .data = @bitCast(@as(isize, left)) },
        .{ .tag = gc.GA_Top, .data = @bitCast(@as(isize, top)) },
        .{},
    };
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags, .gadget_info = gi };
    _ = ib.iface().SendMessage(o, @ptrCast(&set));
}

/// The member a point in the group is over, and the point in its own
/// coordinates. The point comes in relative to the group.
fn propagateHit(ib: *IntuitionBase, cl: *Class, o: *Object, gi: ?*classusr.GadgetInfo, x: i32, y: i32) ?*Object {
    const it = ib.iface();
    const p = own(cl, o);
    const group = cornerOf(ib, o, gi);
    // Back to the window's coordinates, which is what a member's own left
    // and top are counted in once it has joined.
    const at_x = x + group.left;
    const at_y = y + group.top;
    var walk = Walk.over(ib, p);
    while (walk.next()) |member| {
        const b = cornerOf(ib, member, gi);
        const in_x = at_x - b.left;
        const in_y = at_y - b.top;
        if (in_x < 0 or in_y < 0 or in_x >= b.width or in_y >= b.height) continue;
        var ht = gc.GpHitTest{ .gadget_info = gi, .mouse = .{ .x = in_x, .y = in_y } };
        if (it.SendMessage(member, @ptrCast(&ht)) == 0) continue;
        if (gadgetclass.gadgetOf(ib, member).flags & gadgetclass.GFLG_DISABLED != 0) return null;
        p.active = member;
        return member;
    }
    return null;
}

/// A member's mouse: the group's, less how far the member is from the
/// group's own corner.
fn translate(ib: *IntuitionBase, o: *Object, member: *Object, gi: ?*classusr.GadgetInfo, mouse: graphics.Point) graphics.Point {
    const group = cornerOf(ib, o, gi);
    const b = cornerOf(ib, member, gi);
    return .{ .x = mouse.x - (b.left - group.left), .y = mouse.y - (b.top - group.top) };
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
            const p = own(cl, @ptrFromInt(made));
            p.* = .{};
            // A list has to be told it is empty: its head points at its own
            // tail until something joins.
            p.members.init();
            // A group is as big as its members make it, and starts with
            // none: not gadgetclass's default box, which would stand round
            // members smaller than it as room nothing is in.
            const g = gadgetclass.gadgetOf(ib, @ptrFromInt(made));
            g.width = 0;
            g.height = 0;
            return made;
        },
        classusr.OM_DISPOSE => {
            const p = own(cl, o orelse return 0);
            // Off the list before it is freed: the node being walked is in
            // the object about to go.
            while (true) {
                var state: ?*exec.MinNode = p.members.head;
                const member = it.NextObject(&state) orelse break;
                var off = classusr.Msg{ .method_id = classusr.OM_REMOVE };
                _ = it.SendMessage(member, &off);
                it.DisposeObject(member);
            }
            return it.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            // Moving the group moves what is in it by the same amount.
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const was = cornerOf(ib, o.?, set.gadget_info);
            const changed = it.SendSuperMessage(cl, o, msg);
            const now = cornerOf(ib, o.?, set.gadget_info);
            const dx = now.left - was.left;
            const dy = now.top - was.top;
            if (dx != 0 or dy != 0) {
                const p = own(cl, o.?);
                var walk = Walk.over(ib, p);
                while (walk.next()) |member| {
                    const b = cornerOf(ib, member, set.gadget_info);
                    moveTo(ib, member, set.gadget_info, b.left + dx, b.top + dy);
                }
            }
            return changed;
        },
        classusr.OM_ADDMEMBER => {
            const m: *classusr.OpMember = @ptrCast(@alignCast(msg));
            const p = own(cl, o.?);
            const member = m.object;
            var tail = classusr.OpAddTail{ .method_id = classusr.OM_ADDTAIL, .list = @ptrCast(&p.members) };
            if (it.SendMessage(member, @ptrCast(&tail)) == 0) return 0;
            // Where it says it is, is where it is in the group: the group
            // grows to hold it, and then it is put there in the window,
            // which is where a member's own left and top count from
            // thereafter.
            const b = cornerOf(ib, member, null);
            const group = gadgetclass.gadgetOf(ib, o.?);
            group.width = @max(group.width, b.left + b.width);
            group.height = @max(group.height, b.top + b.height);
            moveTo(ib, member, null, group.left + b.left, group.top + b.top);
            return 1;
        },
        classusr.OM_REMMEMBER => {
            const m: *classusr.OpMember = @ptrCast(@alignCast(msg));
            const p = own(cl, o.?);
            var walk = Walk.over(ib, p);
            while (walk.next()) |member| {
                if (member != m.object) continue;
                // Put back where it said it was when it joined, so that a
                // member handed to another group is placed once and not
                // twice. The reference leaves it moved and says so
                // (ggclass.c:204, "not recalculating gadget box"); a member
                // that cannot be moved between groups is worth the two
                // lines it takes to fix.
                const group = cornerOf(ib, o.?, null);
                const b = cornerOf(ib, member, null);
                moveTo(ib, member, null, b.left - group.left, b.top - group.top);
                var off = classusr.Msg{ .method_id = classusr.OM_REMOVE };
                _ = it.SendMessage(member, &off);
                if (p.active == m.object) p.active = null;
                return 1;
            }
            return 0;
        },
        gc.GM_HITTEST => {
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            return if (propagateHit(ib, cl, o.?, ht.gadget_info, ht.mouse.x, ht.mouse.y) != null) gc.GMR_GADGETHIT else 0;
        },
        gc.GM_RENDER => {
            // A member is a gadget of the window with a box of its own, so
            // it needs nothing said to it but the message as it came.
            const p = own(cl, o.?);
            var walk = Walk.over(ib, p);
            while (walk.next()) |member| _ = it.SendMessage(member, @ptrCast(msg));
            return 0;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const p = own(cl, o.?);
            // Nothing under the press to hand it to: the group refuses it
            // rather than swallowing it, so the press can be reconsidered.
            const member = p.active orelse return gc.GMR_REUSE;
            var one = gc.GpInput{
                .method_id = gc.GM_GOACTIVE,
                .gadget_info = in.gadget_info,
                .event = in.event,
                .termination = in.termination,
                .mouse = translate(ib, o.?, member, in.gadget_info, in.mouse),
            };
            // Which member has the input is let go of in GM_GOINACTIVE and
            // nowhere else: that is the message telling the member it is
            // done, and it cannot be sent to a member already forgotten.
            return it.SendMessage(member, @ptrCast(&one));
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const p = own(cl, o.?);
            const member = p.active orelse return gc.GMR_NOREUSE;
            var one = gc.GpInput{
                .method_id = gc.GM_HANDLEINPUT,
                .gadget_info = in.gadget_info,
                .event = in.event,
                .termination = in.termination,
                .mouse = translate(ib, o.?, member, in.gadget_info, in.mouse),
            };
            return it.SendMessage(member, @ptrCast(&one));
        },
        gc.GM_GOINACTIVE => {
            const gi: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            const p = own(cl, o.?);
            const member = p.active orelse return 0;
            var one = gc.GpGoInactive{ .gadget_info = gi.gadget_info, .abort = gi.abort };
            _ = it.SendMessage(member, @ptrCast(&one));
            p.active = null;
            return 0;
        },
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
