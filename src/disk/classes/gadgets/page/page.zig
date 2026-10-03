// SPDX-License-Identifier: MIT
//! page.gadget: several gadgets in one place, one of them shown.
//!
//! It is a groupgclass group whose one member is the page that is shown:
//! turning the page takes that member out and puts the next one in. Being
//! a group is what makes everything else fall out - the hit test that
//! says which gadget the press is over, the press itself, the keys and
//! the drawing all reach the page that is shown and no other, and a
//! gadget on that page reports to the window in its own name, because
//! intuition can see through a group to the gadget inside it that
//! answered.
//!
//! Every page, member or not, is given the whole of the gadget's box when
//! the gadget is laid out, so turning to a page draws it where it already
//! stands. Its size is the largest of its pages' sizes, so that a window
//! built round it is big enough for every page and never changes size
//! when the page turns.
//!
//! The pages go with the gadget: the one that is its member is disposed
//! of by the group, the rest by this class.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const sc = intuition.screens;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const pg = gadgets.page;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = pg.PAGE_CLASS,
    .version = 1,
    .revision = 1,
    .date = "03.10.2026",
    .super = classusr.GROUPGCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// page.gadget's part of an object.
pub const Data = extern struct {
    pages: ?[*]const ?*Object = null,
    count: u32 = 0,
    current: u32 = 0,
    /// The page that is the group's member now, which is the one shown.
    member: ?*Object = null,
};

fn pageAt(own: *const Data, which: u32) ?*Object {
    if (which >= own.count) return null;
    return own.pages.?[which];
}

/// The page that is shown made the group's one member, and the one that
/// was taken out again.
fn takeMember(base: *gadgets.Base, cl: *Class, o: *Object, own: *Data) void {
    const ib = base.intuition_base;
    const wanted = pageAt(own, own.current);
    if (own.member == wanted) return;
    // A group grows round a member as it joins, and moves it by its own
    // corner. A page gadget is the size its pages need and no other, and
    // its box is the layout's to set, so the box it had is put back.
    const g = gc.gadget(o);
    const was_width = g.width;
    const was_height = g.height;
    if (own.member) |old| {
        var off = classusr.OpMember{ .method_id = classusr.OM_REMMEMBER, .object = old };
        _ = ib.SendSuperMessage(cl, o, @ptrCast(&off));
    }
    own.member = null;
    if (wanted) |page| {
        var on = classusr.OpMember{ .method_id = classusr.OM_ADDMEMBER, .object = page };
        if (ib.SendSuperMessage(cl, o, @ptrCast(&on)) != 0) own.member = page;
    }
    g.width = was_width;
    g.height = was_height;
}

/// The attributes among `tags`: whether the page shown changed.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem) bool {
    const ub = base.utility_base;
    var changed = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        switch (item.tag) {
            pg.PAGE_Pages => {
                const pages: ?[*]const ?*Object = @ptrFromInt(item.data);
                own.pages = pages;
                own.count = 0;
                if (pages) |list| while (list[own.count] != null) {
                    own.count += 1;
                };
                changed = true;
            },
            pg.PAGE_Current => {
                const which: u32 = @truncate(item.data);
                if (which != own.current) changed = true;
                own.current = which;
            },
            else => {},
        }
    }
    if (own.count == 0) own.current = 0 else if (own.current >= own.count) own.current = own.count - 1;
    return changed;
}

/// One page given the gadget's whole box, and laid out in it. The box is
/// written rather than set, as a layout writes its children's: set, a
/// page would take the size as the one it asks for next time.
fn placePage(base: *gadgets.Base, page: *Object, box: gc.Box, lay: *gc.GpLayout) void {
    const ib = base.intuition_base;
    const g = gc.gadget(page);
    g.flags &= ~gc.GFLG_RELATIVE;
    g.width = box.width;
    g.height = box.height;
    const tags = [_]TagItem{
        .{ .tag = gc.GA_Left, .data = @bitCast(@as(isize, box.left)) },
        .{ .tag = gc.GA_Top, .data = @bitCast(@as(isize, box.top)) },
        .{},
    };
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
    _ = ib.SendMessage(page, @ptrCast(&set));
    _ = ib.SendMessage(page, @ptrCast(lay));
}

fn placePages(base: *gadgets.Base, own: *const Data, o: *Object, lay: *gc.GpLayout) void {
    const box = gc.boxFor(gc.gadget(o), lay.gadget_info);
    for (0..own.count) |i| {
        const page = own.pages.?[i] orelse continue;
        placePage(base, page, box, lay);
    }
}

/// The largest of what the pages need.
fn domain(base: *gadgets.Base, own: *const Data, ask: *const gc.GpDomain) gc.Box {
    const ib = base.intuition_base;
    var box = gc.Box{};
    for (0..own.count) |i| {
        const page = own.pages.?[i] orelse continue;
        var one = gc.GpDomain{ .gadget_info = ask.gadget_info, .which = ask.which };
        if (ib.SendMessage(page, @ptrCast(&one)) == 0) continue;
        box.width = @max(box.width, @min(one.domain.width, gc.GDOMAIN_UNLIMITED));
        box.height = @max(box.height, @min(one.domain.height, gc.GDOMAIN_UNLIMITED));
    }
    return box;
}

/// The page turned: the new page put where the gadget is - joining the
/// group moved it - the box cleared of what the last page left, and the
/// new one drawn whole, labels and frames included, which an update would
/// not draw.
fn turn(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const info = gi orelse return;
    const ib = base.intuition_base;
    const box = gc.boxFor(gc.gadget(o), info);
    if (own.member) |page| {
        var lay = gc.GpLayout{ .gadget_info = info, .initial = 0 };
        placePage(base, page, box, &lay);
    }
    const rp = ib.ObtainGIRPort(gi) orelse return;
    defer ib.ReleaseGIRPort(rp);
    const saved = support.Saved.of(base.graphics_base, rp);
    defer saved.restore(base.graphics_base, rp);
    // The window's ground under the page, as the window paints it: a page
    // is a stretch of the window, not a part with a look of its own.
    const ground = graphics.Rect{ .min_x = box.left, .min_y = box.top, .max_x = box.left + box.width, .max_y = box.top + box.height };
    base.graphics_base.EraseRect(rp, &ground);
    const page = own.member orelse return;
    var msg = gc.GpRender{ .gadget_info = info, .rast_port = rp, .redraw = gc.GREDRAW_REDRAW };
    _ = ib.SendMessage(page, @ptrCast(&msg));
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const base = gadgets.baseOf(cl);
    const ib = base.intuition_base;
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = ib.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const obj: *Object = @ptrFromInt(made);
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, obj);
            own.* = .{};
            _ = setAttrs(base, own, new.attr_list);
            takeMember(base, cl, obj, own);
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            // The page that is the group's member goes with the group;
            // the rest are this gadget's to free.
            for (0..own.count) |i| {
                const page = own.pages.?[i] orelse continue;
                if (page != own.member) ib.DisposeObject(page);
            }
            own.pages = null;
            own.count = 0;
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(base, own, set.attr_list)) {
                takeMember(base, cl, o.?, own);
                changed = 1;
            }
            if (changed != 0 and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                turn(base, own, o.?, set.gadget_info);
                return 0;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            switch (get.attr_id) {
                pg.PAGE_Current => get.storage.* = own.current,
                pg.PAGE_NumPages => get.storage.* = own.count,
                pg.PAGE_Pages => get.storage.* = @intFromPtr(own.pages),
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        // A group is the size its members make it; a page gadget is the
        // size the largest of its pages needs, member or not.
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            ask.domain = domain(base, classes.instData(Data, cl, o.?), ask);
            return 1;
        },
        // Every page, not only the member: a page laid out before it is
        // turned to is drawn and nothing more when it is.
        gc.GM_LAYOUT => {
            const lay: *gc.GpLayout = @ptrCast(@alignCast(msg));
            placePages(base, classes.instData(Data, cl, o.?), o.?, lay);
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
