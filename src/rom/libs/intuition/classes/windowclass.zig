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
//! `WM_RETHINK` lays it out again in the open window as its first
//! layout did - so the smallest size is set again - and draws the room
//! aside, in one copy, as a size does.
//!
//! `WM_HANDLEINPUT` turns one message into one word and replies to it
//! itself - the program never holds a message, so there is nothing it can
//! forget to reply. It replies most there and then, and `IDCMP_NEWSIZE`
//! at the next `WM_HANDLEINPUT`: by then the program has done what the
//! size asked of it, such as drawing its picture again. A sizing takes its
//! next step once the last step's message is back (input/_input.zig
//! `pace`), so it waits for that drawing too. Closing the window replies
//! one still held. What the word has no room for - the keys held with the
//! message, the gadget it came from - is kept to be read
//! (`WINDOWA_Qualifier`, `WINDOWA_GadgetID`); an update's `GA_ID` is read
//! from its tag list before the reply, since the list goes with the
//! message.
//!
//! The scroll bars in the borders are scroller.gadgets, which the object
//! opens the library of when it is made with one. They are made at the
//! first open, once the borders' depth is known, from the object's place
//! and size and the program's tags behind them; at every later open they
//! are placed again for the borders that window has and put back. Closing
//! the window takes them out of it with the layout, and they go when the
//! object goes.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const pg = intuition.propgclass;
const sr = sdk.gadgets.scroller;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const _gadget = @import("../gadget/_gadget.zig");

/// windowclass's part of an object.
pub const Data = extern struct {
    /// The tags it was made with, copied.
    tags: ?[*]TagItem = null,
    layout: ?*Object = null,
    /// `WA_Title`: kept apart from the copy, since it may be set again.
    title: ?[*:0]const u8 = null,
    /// The window while it is open.
    window: ?*intuition.Window = null,
    /// What `WINDOWA_Qualifier` and `WINDOWA_GadgetID` read: the message
    /// `WM_HANDLEINPUT` answered last.
    qualifier: u32 = 0,
    gadget_id: usize = wc.WINDOW_NOGADGET,
    /// The `IDCMP_NEWSIZE` `WM_HANDLEINPUT` answered last, replied at its
    /// next call or when the window closes.
    held: ?*intuition.IntuiMessage = null,
    /// The border bars asked for (`BAR_`), the program's tags for each,
    /// copied, and the bars once made.
    bars: u32 = 0,
    vert_tags: ?[*]TagItem = null,
    horiz_tags: ?[*]TagItem = null,
    vert: ?*Object = null,
    horiz: ?*Object = null,
    /// scroller.gadget, open while there are bars to make.
    scroller_lib: ?*exec.Library = null,
};

const BAR_VERT: u32 = 1 << 0;
const BAR_HORIZ: u32 = 1 << 1;

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
        // A bar needs its border as deep as a sizing gadget makes it.
        .{ .tag = if (p.bars != 0) wn.WA_SizeGadget else ignore, .data = 1 },
        .{ .tag = if (p.bars & BAR_VERT != 0) wn.WA_SizeBRight else ignore, .data = 1 },
        .{ .tag = if (p.bars & BAR_HORIZ != 0) wn.WA_SizeBBottom else ignore, .data = 1 },
        .{ .tag = if (tags != null) utility.TAG_MORE else utility.TAG_DONE, .data = @intFromPtr(tags) },
    };
    const window = it.OpenWindowTagList(&first) orelse return null;
    p.window = window;

    // The bars after the layout, so the smallest size they keep is on top
    // of the one the layout set when it was added.
    defer {
        placeBars(ib, p, window);
        keepBarRoom(ib, p, window);
    }
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
    // Squeezed onto a small screen, the layout may need more than the
    // window was given - its rows wrapped deeper: the window grows to it.
    _window.fitLayout(ib, @ptrCast(@alignCast(window)));
    return window;
}

/// The border bars made, or placed again for this window's borders, and
/// put in it. A bar down the right border reaches from below the title
/// bar to the sizing gadget, one along the bottom from the left border to
/// it; each fills its border's depth, and its arrows are as long as the
/// bottom border is deep - half again for the bar that runs across, whose
/// arrows are drawn longer - so the two sets look alike.
fn placeBars(ib: *IntuitionBase, p: *Data, window: *intuition.Window) void {
    if (p.bars == 0 or p.scroller_lib == null) return;
    const it = ib.iface();
    const left: isize = @bitCast(windowAttr(ib, window, wn.WA_BorderLeft));
    const top: isize = @bitCast(windowAttr(ib, window, wn.WA_BorderTop));
    const right: isize = @bitCast(windowAttr(ib, window, wn.WA_BorderRight));
    const bottom: isize = @bitCast(windowAttr(ib, window, wn.WA_BorderBottom));
    const Bar = struct { want: u32, tags: ?[*]TagItem, made: *?*Object, place: [7]TagItem };
    const bars = [_]Bar{
        .{ .want = BAR_VERT, .tags = p.vert_tags, .made = &p.vert, .place = .{
            .{ .tag = gc.GA_RightBorder, .data = 1 },
            .{ .tag = gc.GA_RelRight, .data = @bitCast(-(right - 1)) },
            .{ .tag = gc.GA_Top, .data = @bitCast(top) },
            .{ .tag = gc.GA_Width, .data = @bitCast(right) },
            .{ .tag = gc.GA_RelHeight, .data = @bitCast(-(top + bottom)) },
            .{ .tag = pg.PGA_Freedom, .data = pg.FREEVERT },
            .{ .tag = sr.SCROLLER_Arrows, .data = @bitCast(bottom) },
        } },
        .{ .want = BAR_HORIZ, .tags = p.horiz_tags, .made = &p.horiz, .place = .{
            .{ .tag = gc.GA_BottomBorder, .data = 1 },
            .{ .tag = gc.GA_Left, .data = @bitCast(left) },
            .{ .tag = gc.GA_RelBottom, .data = @bitCast(-(bottom - 1)) },
            .{ .tag = gc.GA_RelWidth, .data = @bitCast(-(left + right)) },
            .{ .tag = gc.GA_Height, .data = @bitCast(bottom) },
            .{ .tag = pg.PGA_Freedom, .data = pg.FREEHORIZ },
            .{ .tag = sr.SCROLLER_Arrows, .data = @bitCast(@divTrunc(bottom * 16, 11)) },
        } },
    };
    for (bars) |bar| {
        if (p.bars & bar.want == 0) continue;
        var tags: [8]TagItem = undefined;
        @memcpy(tags[0..7], &bar.place);
        if (bar.made.*) |made| {
            // Placed again: the program's numbers are its own by now.
            tags[7] = .{};
            _ = it.SetAttrsTagList(made, &tags);
        } else {
            tags[7] = if (bar.tags) |more| .{ .tag = utility.TAG_MORE, .data = @intFromPtr(more) } else .{};
            bar.made.* = it.NewObjectTagList(null, sr.SCROLLER_CLASS, &tags);
        }
        if (bar.made.*) |made| _ = it.AddGList(window, made, -1, 1);
    }
}

/// The window kept from being sized smaller than its bars' arrows and as
/// much again, on top of what the layout needs - but never more than the
/// window is now, which `WindowLimits` would refuse outright; the border
/// drawn with the bars in it.
fn keepBarRoom(ib: *IntuitionBase, p: *Data, window: *intuition.Window) void {
    if (p.vert == null and p.horiz == null) return;
    const it = ib.iface();
    const left: i32 = @intCast(windowAttr(ib, window, wn.WA_BorderLeft));
    const top: i32 = @intCast(windowAttr(ib, window, wn.WA_BorderTop));
    const right: i32 = @intCast(windowAttr(ib, window, wn.WA_BorderRight));
    const bottom: i32 = @intCast(windowAttr(ib, window, wn.WA_BorderBottom));
    const width: i32 = @intCast(windowAttr(ib, window, wn.WA_Width));
    const height: i32 = @intCast(windowAttr(ib, window, wn.WA_Height));
    const min_width: i32 = @intCast(windowAttr(ib, window, wn.WA_MinWidth));
    const min_height: i32 = @intCast(windowAttr(ib, window, wn.WA_MinHeight));
    const wanted_width = @min(@max(min_width, left + right + 4 * bottom), width);
    const wanted_height = @min(@max(min_height, top + bottom + 4 * right), height);
    _ = it.WindowLimits(window, wanted_width, wanted_height, 0, 0);
    it.RefreshWindowFrame(window);
}

/// A bar's tags copied, when the object is made with it: whether there is
/// one, and false when there was no memory to copy them.
fn takeBar(ib: *IntuitionBase, p: *Data, attrs: ?[*]const TagItem, attr: utility.Tag, want: u32, into: *?[*]TagItem) bool {
    const ub = ib.utility_base;
    const item = ub.FindTagItem(attr, attrs) orelse return true;
    p.bars |= want;
    if (item.data == 0) return true;
    into.* = ub.CloneTagItems(@ptrFromInt(item.data)) orelse return false;
    return true;
}

/// The bars, their tags and their library given back.
fn dropBars(ib: *IntuitionBase, p: *Data) void {
    const it = ib.iface();
    it.DisposeObject(p.vert);
    it.DisposeObject(p.horiz);
    if (p.vert_tags) |tags| ib.utility_base.FreeTagItems(tags);
    if (p.horiz_tags) |tags| ib.utility_base.FreeTagItems(tags);
    if (p.scroller_lib) |lib| ib.sys_base.CloseLibrary(lib);
    p.vert = null;
    p.horiz = null;
    p.vert_tags = null;
    p.horiz_tags = null;
    p.scroller_lib = null;
}

/// The layout measured and placed again in the open window, as when it
/// was added - so the window's smallest size is the one it fits in now -
/// the room drawn again in one copy, and the window grown to it where it
/// is smaller.
fn rethink(ib: *IntuitionBase, p: *Data) bool {
    const window = p.window orelse return false;
    const layout = p.layout orelse return false;
    const w: *_window.Window = @ptrCast(@alignCast(window));
    _window.lock(ib);
    defer _window.unlock(ib);
    w.layout_width = 0;
    w.layout_height = 0;
    _gadget.layoutRange(ib, w, layout, layout, true);
    _gadget.redrawRoom(ib, w, &.{});
    _window.fitLayout(ib, w);
    return true;
}

/// The window closed; the layout stays the object's.
fn close(ib: *IntuitionBase, p: *Data) bool {
    replyHeld(ib, p);
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
    p.gadget_id = id;
    if (code) |out| out.* = @bitCast(termination);
    return wc.WMHI_GADGETUP | (id & wc.WMHI_GADGETMASK);
}

/// The size answered last replied, as the program is done with it.
fn replyHeld(ib: *IntuitionBase, p: *Data) void {
    const message = p.held orelse return;
    p.held = null;
    ib.iface().ReplyIMsg(message);
}

/// The next message of a class it has a word for, replied, as that word;
/// `WMHI_LASTMSG` when there is none. A size is held until the next call.
fn handleInput(ib: *IntuitionBase, p: *Data, code: ?*u32) usize {
    const it = ib.iface();
    replyHeld(ib, p);
    const window = p.window orelse return wc.WMHI_LASTMSG;
    while (it.GetIMsg(window)) |im| {
        const class = im.class;
        const said = im.code;
        const address = im.iaddress;
        const qualifier = im.qualifier;
        // An update's tag list is the message's, and goes with the reply.
        const update_id: usize = if (class == wn.IDCMP_IDCMPUPDATE)
            ib.utility_base.GetTagData(gc.GA_ID, wc.WINDOW_NOGADGET, @ptrCast(@alignCast(address)))
        else
            wc.WINDOW_NOGADGET;
        if (class == wn.IDCMP_NEWSIZE) p.held = im else it.ReplyIMsg(im);
        p.qualifier = qualifier;
        p.gadget_id = wc.WINDOW_NOGADGET;
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
                p.gadget_id = id;
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
            wn.IDCMP_IDCMPUPDATE => blk: {
                p.gadget_id = update_id;
                break :blk wc.WMHI_IDCMPUPDATE | (said & wc.WMHI_GADGETMASK);
            },
            wn.IDCMP_MOUSEWHEEL => wc.WMHI_MOUSEWHEEL | (said & 0xFFFF),
            wn.IDCMP_USBCHANGE => wc.WMHI_USBCHANGE | (said & 0xFFFF),
            wn.IDCMP_CHANGEWINDOW => wc.WMHI_CHANGEWINDOW,
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
            const copied = takeBar(ib, p, new.attr_list, wc.WINDOWA_VertScroller, BAR_VERT, &p.vert_tags) and
                takeBar(ib, p, new.attr_list, wc.WINDOWA_HorizScroller, BAR_HORIZ, &p.horiz_tags);
            if (copied and new.attr_list != null) p.tags = ub.CloneTagItems(new.attr_list);
            if (!copied or (new.attr_list != null and p.tags == null)) {
                // Given up on through the superclass: the layout is not
                // ours until the object is made.
                p.layout = null;
                dropBars(ib, p);
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = it.SendSuperMessage(cl, obj, &gone);
                return 0;
            }
            // Without the class there are no bars; the window works without.
            if (p.bars != 0) p.scroller_lib = ib.sys_base.OpenLibrary(sr.SCROLLER_LIBRARY, 0);
            return made;
        },
        classusr.OM_DISPOSE => {
            const p = own(cl, o orelse return 0);
            _ = close(ib, p);
            dropBars(ib, p);
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
                wc.WINDOWA_Qualifier => get.storage.* = p.qualifier,
                wc.WINDOWA_GadgetID => get.storage.* = p.gadget_id,
                wc.WINDOWA_VertScroller => get.storage.* = @intFromPtr(p.vert),
                wc.WINDOWA_HorizScroller => get.storage.* = @intFromPtr(p.horiz),
                else => return it.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        wc.WM_OPEN => return @intFromPtr(open(ib, own(cl, o.?))),
        wc.WM_CLOSE => return @intFromBool(close(ib, own(cl, o.?))),
        wc.WM_RETHINK => return @intFromBool(rethink(ib, own(cl, o.?))),
        wc.WM_HANDLEINPUT => {
            const handle: *wc.WmHandleInput = @ptrCast(@alignCast(msg));
            return handleInput(ib, own(cl, o.?), handle.code);
        },
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
