// SPDX-License-Identifier: MPL-2.0
//! windowclass: a window described by an object, opened and closed on
//! request, with a layout of gadgets in it.
//!
//! The object keeps a copy of the tags it was made with - flat, so that
//! a `TAG_MORE` of the maker's need not outlive the call - and every
//! `WM_OPEN` hands them to `OpenWindowTagList`, behind the few the object
//! decides itself: the title (which may change while it is open), the
//! IDCMP classes it cannot do without, a size from the layout's nominal
//! one and a place in the middle of the screen, the last two only where
//! the tags say nothing of their own. The first found is what a tag list
//! answers, so the object's own go first.
//!
//! Once the window is open, its border is known: the layout is set to fill
//! what is inside it (`GA_RelWidth`, `GA_RelHeight`) and added, which lays
//! it out and gives the window its smallest size. Closing the window gives
//! the layout back to the object, to be added again at the next open.
//!
//! `WM_HANDLEINPUT` turns one message into one word and replies to it
//! there and then - the program never holds a message, so there is
//! nothing it can forget to reply.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// windowclass's part of an object.
pub const Data = extern struct {
    /// The tags it was made with, copied.
    tags: ?[*]TagItem = null,
    layout: ?*Object = null,
    /// `WA_Title`: kept apart from the copy, since it may be set again.
    title: ?[*:0]const u8 = null,
    /// The window while it is open.
    window: ?*intuition.Window = null,
};

/// What the window hears whatever it is told: what `WM_HANDLEINPUT` is
/// for. The keys are among them because a key may be one that works a
/// gadget of the layout, which is the window's own business; one that
/// works none is handed on as `WMHI_VANILLAKEY`.
const idcmp_always = wn.IDCMP_CLOSEWINDOW | wn.IDCMP_GADGETUP | wn.IDCMP_GADGETDOWN | wn.IDCMP_MENUPICK | wn.IDCMP_VANILLAKEY;

/// Make windowclass, from rootclass, and put it on the public list.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.WINDOWCLASS, classusr.ROOTCLASS, null, @sizeOf(Data)) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

fn own(cl: *Class, o: *Object) *Data {
    return classes.instData(Data, cl, o);
}

fn windowAttr(ib: *IntuitionBase, window: *intuition.Window, tag: utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.iface().GetWindowAttrs(window, &ask);
    return value;
}

/// The window opened from the object's tags, the layout put in it.
fn open(ib: *IntuitionBase, p: *Data) ?*intuition.Window {
    if (p.window) |window| return window;
    const it = ib.iface();
    const ub = ib.utility_base;
    const tags = p.tags;
    const has = struct {
        fn tag(u: anytype, t: utility.Tag, list: ?[*]const TagItem) bool {
            return u.FindTagItem(t, list) != null;
        }
    }.tag;

    // The layout's nominal size, where the tags give none.
    var nominal = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    const sized = p.layout != null and it.SendMessage(p.layout, @ptrCast(&nominal)) != 0;
    const own_width = sized and !has(ub, wn.WA_Width, tags) and !has(ub, wn.WA_InnerWidth, tags);
    const own_height = sized and !has(ub, wn.WA_Height, tags) and !has(ub, wn.WA_InnerHeight, tags);
    const own_place = !has(ub, wn.WA_Left, tags) and !has(ub, wn.WA_Top, tags) and !has(ub, wn.WA_Position, tags);
    const ignore = utility.TAG_IGNORE;
    const first = [_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr(p.title) },
        .{ .tag = wn.WA_IDCMP, .data = ub.GetTagData(wn.WA_IDCMP, 0, tags) | idcmp_always },
        .{ .tag = if (own_width) wn.WA_InnerWidth else ignore, .data = @intCast(@max(nominal.domain.width, 1)) },
        .{ .tag = if (own_height) wn.WA_InnerHeight else ignore, .data = @intCast(@max(nominal.domain.height, 1)) },
        .{ .tag = if (own_place) wn.WA_Position else ignore, .data = wn.WPOS_CENTERSCREEN },
        .{ .tag = if (tags != null) utility.TAG_MORE else utility.TAG_DONE, .data = @intFromPtr(tags) },
    };
    const window = it.OpenWindowTagList(&first) orelse return null;
    p.window = window;

    const layout = p.layout orelse return window;
    // Inside the border - or, in a GimmeZeroZero window, the whole of the
    // inner part, whose corner is its own 0,0.
    const gzz = ub.GetTagData(wn.WA_GimmeZeroZero, 0, tags) != 0;
    const left: i32 = if (gzz) 0 else @intCast(windowAttr(ib, window, wn.WA_BorderLeft));
    const top: i32 = if (gzz) 0 else @intCast(windowAttr(ib, window, wn.WA_BorderTop));
    const right: i32 = if (gzz) 0 else @intCast(windowAttr(ib, window, wn.WA_BorderRight));
    const bottom: i32 = if (gzz) 0 else @intCast(windowAttr(ib, window, wn.WA_BorderBottom));
    const fill = [_]TagItem{
        .{ .tag = gc.GA_Left, .data = @bitCast(@as(isize, left)) },
        .{ .tag = gc.GA_Top, .data = @bitCast(@as(isize, top)) },
        .{ .tag = gc.GA_RelWidth, .data = @bitCast(@as(isize, -(left + right))) },
        .{ .tag = gc.GA_RelHeight, .data = @bitCast(@as(isize, -(top + bottom))) },
        .{},
    };
    _ = it.SetAttrsTagList(layout, &fill);
    _ = it.AddGList(window, layout, -1, 1);
    it.RefreshGList(layout, window, 1);
    return window;
}

/// The window closed; the layout stays the object's.
fn close(ib: *IntuitionBase, p: *Data) bool {
    const window = p.window orelse return false;
    ib.iface().CloseWindow(window);
    p.window = null;
    return true;
}

/// What the key `said` does in the layout: null when no gadget there
/// answers to it, so the key is the program's; `WMHI_LASTMSG` when a
/// gadget took it and has nothing to report; and a `WMHI_GADGETUP` word
/// with the code when it has.
fn keyGadget(ib: *IntuitionBase, p: *Data, said: u32, qualifier: u32, code: ?*u32) ?usize {
    const it = ib.iface();
    const layout = p.layout orelse return null;
    const window = p.window orelse return null;
    var termination: i32 = 0;
    var key = gc.GpKey{ .key = said, .qualifier = qualifier, .termination = &termination };
    const answer = it.DoGadgetMethodA(layout, window, null, @ptrCast(&key));
    if (answer == gc.GMKR_NOTHING) return null;
    const worked = key.gadget orelse return null;
    if (answer & gc.GMKR_ACTIVATE != 0) {
        _ = it.ActivateGadget(worked, window, null);
        return wc.WMHI_LASTMSG;
    }
    if (answer & gc.GMKR_VERIFY == 0) return wc.WMHI_LASTMSG;
    var id: usize = 0;
    _ = it.GetAttr(gc.GA_ID, worked, &id);
    if (code) |out| out.* = @bitCast(termination);
    return wc.WMHI_GADGETUP | (id & wc.WMHI_GADGETMASK);
}

/// The next message of a class it has a word for, replied, as that word;
/// `WMHI_LASTMSG` when there is none.
fn handleInput(ib: *IntuitionBase, p: *Data, code: ?*u32) usize {
    const it = ib.iface();
    const window = p.window orelse return wc.WMHI_LASTMSG;
    while (it.GetIMsg(window)) |im| {
        const class = im.class;
        const said = im.code;
        const address = im.iaddress;
        const qualifier = im.qualifier;
        it.ReplyIMsg(im);
        // A key that works a gadget of the layout is that gadget's, not
        // the program's: what it did is reported in the gadget's name, or
        // not at all.
        if (class == wn.IDCMP_VANILLAKEY) {
            if (keyGadget(ib, p, said, qualifier, code)) |worked| {
                if (worked == wc.WMHI_LASTMSG) continue;
                return worked;
            }
        }
        const word: usize = switch (class) {
            wn.IDCMP_CLOSEWINDOW => wc.WMHI_CLOSEWINDOW,
            wn.IDCMP_GADGETUP, wn.IDCMP_GADGETDOWN => blk: {
                // The gadget outlives the message: it is the program's.
                var id: usize = 0;
                _ = it.GetAttr(gc.GA_ID, @ptrCast(address), &id);
                const kind = if (class == wn.IDCMP_GADGETUP) wc.WMHI_GADGETUP else wc.WMHI_GADGETDOWN;
                break :blk kind | (id & wc.WMHI_GADGETMASK);
            },
            wn.IDCMP_MENUPICK => wc.WMHI_MENUPICK | (said & wc.WMHI_MENUMASK),
            wn.IDCMP_VANILLAKEY => wc.WMHI_VANILLAKEY | (said & wc.WMHI_KEYMASK),
            wn.IDCMP_RAWKEY => wc.WMHI_RAWKEY | (said & wc.WMHI_KEYMASK),
            wn.IDCMP_NEWSIZE => wc.WMHI_NEWSIZE,
            wn.IDCMP_ACTIVEWINDOW => wc.WMHI_ACTIVE,
            wn.IDCMP_INACTIVEWINDOW => wc.WMHI_INACTIVE,
            wn.IDCMP_DISKINSERTED => wc.WMHI_DISKINSERTED,
            wn.IDCMP_DISKREMOVED => wc.WMHI_DISKREMOVED,
            wn.IDCMP_NEWPREFS => wc.WMHI_NEWPREFS,
            else => continue,
        };
        if (code) |out| out.* = said;
        return word;
    }
    return wc.WMHI_LASTMSG;
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const ib: *IntuitionBase = @ptrFromInt(cl.user_data);
    const it = ib.iface();
    const ub = ib.utility_base;
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = it.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const obj: *Object = @ptrFromInt(made);
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const p = own(cl, obj);
            p.* = .{
                .layout = @ptrFromInt(ub.GetTagData(wc.WINDOWA_Layout, 0, new.attr_list)),
                .title = @ptrFromInt(ub.GetTagData(wn.WA_Title, 0, new.attr_list)),
            };
            if (new.attr_list != null) {
                p.tags = ub.CloneTagItems(new.attr_list) orelse {
                    // Given up on through the superclass: the layout is
                    // not ours until the object is made.
                    p.layout = null;
                    var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                    _ = it.SendSuperMessage(cl, obj, &gone);
                    return 0;
                };
            }
            return made;
        },
        classusr.OM_DISPOSE => {
            const p = own(cl, o orelse return 0);
            _ = close(ib, p);
            it.DisposeObject(p.layout);
            if (p.tags) |tags| ub.FreeTagItems(tags);
            return it.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const p = own(cl, o.?);
            var changed = it.SendSuperMessage(cl, o, msg);
            if (ub.FindTagItem(wn.WA_Title, set.attr_list)) |item| {
                p.title = @ptrFromInt(item.data);
                if (p.window) |window| it.SetWindowTitles(window, p.title, wn.TITLE_UNCHANGED);
                changed = 1;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const p = own(cl, o.?);
            switch (get.attr_id) {
                wc.WINDOWA_Window => get.storage.* = @intFromPtr(p.window),
                wc.WINDOWA_Layout => get.storage.* = @intFromPtr(p.layout),
                wc.WINDOWA_SigMask => get.storage.* = if (p.window) |window| blk: {
                    const port: ?*exec.MsgPort = @ptrFromInt(windowAttr(ib, window, wn.WA_UserPort));
                    break :blk if (port) |mp| @as(usize, 1) << @intCast(mp.sig_bit) else 0;
                } else 0,
                wn.WA_Title => get.storage.* = @intFromPtr(p.title),
                else => return it.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        wc.WM_OPEN => return @intFromPtr(open(ib, own(cl, o.?))),
        wc.WM_CLOSE => return @intFromBool(close(ib, own(cl, o.?))),
        wc.WM_HANDLEINPUT => {
            const handle: *wc.WmHandleInput = @ptrCast(@alignCast(msg));
            return handleInput(ib, own(cl, o.?), handle.code);
        },
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
