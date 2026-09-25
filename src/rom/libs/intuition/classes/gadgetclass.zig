// SPDX-License-Identifier: MPL-2.0
//! gadgetclass: what every gadget is.
//!
//! It keeps what intuition.library needs to drive a gadget - its box, its
//! flags, its ID, the next gadget in its window's list - and what it tells
//! when something changes: `ICA_TARGET` and `ICA_MAP`, as icclass has them.
//! It draws nothing and takes no input: it answers `GM_HITTEST` with a hit
//! everywhere in its box and refuses `GM_GOACTIVE`, so a class made from it
//! decides what it looks like and what the pointer does to it.
//!
//! `OM_NOTIFY` is how a gadget tells: the changed attributes are mapped in a
//! copy and sent to the target as `OM_UPDATE`, or, for `ICTARGET_IDCMP`, to
//! the gadget's window as `IDCMP_IDCMPUPDATE` - which is where the window
//! comes from the message's GadgetInfo. A gadget already passing something
//! on passes nothing more, so two gadgets that are each other's target stop
//! after one round.

const sdk = @import("sdk");
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const icc = intuition.icclass;
const ic = intuition.imageclass;
const sc = intuition.screens;
const graphics = sdk.graphics;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");

/// gadgetclass's part of an object: the gadget.
pub const Data = extern struct {
    /// The next gadget in its list.
    next: ?*Object = null,
    /// The box, as given: GFLG_REL* say which are measured from the window's
    /// right and bottom edges.
    left: i32 = 0,
    top: i32 = 0,
    /// A gadget made without a size gets one, rather than a box of nothing
    /// that can be neither seen nor pressed. The numbers say nothing in
    /// particular - they are there so that a gadget whose maker forgot is
    /// visibly wrong rather than invisibly absent.
    width: i32 = 80,
    height: i32 = 40,
    flags: u32 = 0,
    activation: u32 = 0,
    id: u32 = 0,
    user_data: usize = 0,
    image: ?*Object = null,
    /// What it shows while selected, for `GFLG_GADGHIMAGE`.
    select_render: ?*Object = null,
    /// Its label: one of the three at a time - a string, a chain of
    /// IntuiTexts, or an image.
    text: ?[*:0]const u8 = null,
    itext: ?*const intuition.IntuiText = null,
    label_image: ?*Object = null,
    /// `GFLG_GADGH*`: how it shows being selected.
    highlight: u32 = gc.GFLG_GADGHCOMP,
    /// `GA_Bounds`, when `GFLG_BOUNDS`.
    bounds: gc.Box = .{},
    /// `GTYP_*` of the window gadget it stands for, when `GA_SysGadget`.
    sys_type: u32 = 0,
    draw_info: ?*intuition.DrawInfo = null,
    /// ICA_TARGET, ICA_MAP (not copied), and how deep in telling it is.
    target: usize = 0,
    map: ?[*]const TagItem = null,
    loop_count: u32 = 0,
    /// The window it is in, while it is in one.
    window: ?*_window.Window = null,
    /// The requester of that window it is in, while that is up; null for
    /// one of the window's own.
    requester: ?*intuition.Requester = null,
};

pub const GFLG_SELECTED: u32 = 1 << 0;
pub const GFLG_DISABLED: u32 = 1 << 1;
pub const GFLG_RELRIGHT: u32 = 1 << 2;
pub const GFLG_RELBOTTOM: u32 = 1 << 3;
pub const GFLG_RELWIDTH: u32 = 1 << 4;
pub const GFLG_RELHEIGHT: u32 = 1 << 5;
pub const GFLG_RELATIVE: u32 = GFLG_RELRIGHT | GFLG_RELBOTTOM | GFLG_RELWIDTH | GFLG_RELHEIGHT;
/// Tab moves the keyboard to this gadget.
pub const GFLG_TABCYCLE: u32 = 1 << 6;
/// It belongs to the border of a GimmeZeroZero window, not to the part
/// inside it.
pub const GFLG_GZZGADGET: u32 = 1 << 7;
/// It has something to say under gadget help (`GA_GadgetHelp`).
pub const GFLG_GADGETHELP: u32 = 1 << 8;
/// It has a bounding box of its own (`GA_Bounds`).
pub const GFLG_BOUNDS: u32 = 1 << 9;
/// It stands for one of the window's own gadgets (`GA_SysGadget`).
pub const GFLG_SYSGADGET: u32 = 1 << 10;

pub const GACT_IMMEDIATE: u32 = 1 << 0;
pub const GACT_RELVERIFY: u32 = 1 << 1;
/// A press turns it on or off and leaves it that way, rather than selecting
/// it only for as long as the button is held.
pub const GACT_TOGGLESELECT: u32 = 1 << 2;
/// In a requester, finishing the way that counts ends the requester.
pub const GACT_ENDGADGET: u32 = 1 << 3;
/// It lives in that border of its window (`GA_RightBorder`, ...).
pub const GACT_RIGHTBORDER: u32 = 1 << 4;
pub const GACT_LEFTBORDER: u32 = 1 << 5;
pub const GACT_TOPBORDER: u32 = 1 << 6;
pub const GACT_BOTTOMBORDER: u32 = 1 << 7;
pub const GACT_BORDER: u32 = GACT_RIGHTBORDER | GACT_LEFTBORDER | GACT_TOPBORDER | GACT_BOTTOMBORDER;
/// While held, the window hears the pointer's moves (`GA_FollowMouse`).
pub const GACT_FOLLOWMOUSE: u32 = 1 << 8;

/// The state a gadget of `highlight` is drawn in: its own selected look
/// for `GFLG_GADGHCOMP` and `GFLG_GADGHIMAGE`, its normal one for
/// `GFLG_GADGHBOX` and `GFLG_GADGHNONE`, which show being selected some
/// other way or not at all.
pub fn drawnState(g: *const Data, state: u32) u32 {
    if (g.highlight != gc.GFLG_GADGHBOX and g.highlight != gc.GFLG_GADGHNONE) return state;
    return switch (state) {
        ic.IDS_SELECTED => ic.IDS_NORMAL,
        ic.IDS_INACTIVESELECTED => ic.IDS_INACTIVENORMAL,
        else => state,
    };
}

/// The image a gadget shows: `GA_SelectRender` while it is selected and
/// highlights so, else `GA_Image`.
pub fn shownImage(g: *const Data) ?*Object {
    if (g.flags & GFLG_SELECTED != 0 and g.highlight == gc.GFLG_GADGHIMAGE) {
        if (g.select_render) |other| return other;
    }
    return g.image;
}

/// A selected gadget of `GFLG_GADGHBOX`: its box outlined the other way
/// round.
pub fn drawHighlightBox(ib: *IntuitionBase, g: *const Data, rp: *graphics.RastPort, left: i32, top: i32, width: i32, height: i32) void {
    if (g.highlight != gc.GFLG_GADGHBOX or g.flags & GFLG_SELECTED == 0) return;
    const gb = ib.graphics_base;
    var mode: u32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = @intFromPtr(&mode) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    const complement = [_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_COMPLEMENT }, .{} };
    gb.SetRPAttrs(rp, &complement);
    gb.DrawRect(rp, &.{ .min_x = left, .min_y = top, .max_x = left + width, .max_y = top + height });
    const put = [_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = mode }, .{} };
    gb.SetRPAttrs(rp, &put);
}

/// How big a gadget's label is: its string in the RastPort's font, its
/// IntuiTexts, or its image; zero without one.
pub fn labelSize(ib: *IntuitionBase, g: *const Data, rp: ?*graphics.RastPort, font: ?*graphics.TextFont) struct { width: i32, height: i32 } {
    const it = ib.iface();
    if (g.label_image) |image| {
        var width: usize = 0;
        var height: usize = 0;
        _ = it.GetAttr(ic.IA_Width, image, &width);
        _ = it.GetAttr(ic.IA_Height, image, &height);
        return .{ .width = @intCast(width), .height = @intCast(height) };
    }
    const gb = ib.graphics_base;
    var height: u32 = 0;
    if (rp) |port| {
        const metric = [_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) }, .{} };
        gb.GetRPAttrs(port, &metric);
    } else if (font) |f| {
        var extent = graphics.FontExtent{};
        gb.FontExtent(f, &extent);
        height = @intCast(extent.height);
    }
    if (g.itext) |run| return .{ .width = it.IntuiTextLength(run), .height = @intCast(height) };
    if (g.text) |text| {
        const run = intuition.IntuiText{ .font = font, .text = text };
        const width: i32 = if (rp) |port| @intCast(gb.TextLength(port, text, textLen(text))) else it.IntuiTextLength(&run);
        return .{ .width = width, .height = @intCast(height) };
    }
    return .{ .width = 0, .height = 0 };
}

fn textLen(s: [*:0]const u8) u32 {
    var n: u32 = 0;
    while (s[n] != 0) n += 1;
    return n;
}

/// The label in the middle of the box: a string in the text pen - the
/// fill-text pen while selected - IntuiTexts in their own pens, an image
/// in the gadget's state.
pub fn drawLabel(ib: *IntuitionBase, g: *const Data, rp: *graphics.RastPort, left: i32, top: i32, width: i32, height: i32, dri: *intuition.DrawInfo, state: u32) void {
    const it = ib.iface();
    const gb = ib.graphics_base;
    const size = labelSize(ib, g, rp, null);
    const x = left + @divTrunc(width - size.width, 2);
    const y = top + @divTrunc(height - size.height, 2);
    if (g.label_image) |image| return it.DrawImageState(rp, image, x, y, state, dri);
    if (g.itext) |run| return it.PrintIText(rp, run, x, y);
    const text = g.text orelse return;
    var baseline: u32 = 0;
    const metric = [_]TagItem{ .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) }, .{} };
    gb.GetRPAttrs(rp, &metric);
    const pens = dri.pens;
    const selected = state == ic.IDS_SELECTED or state == ic.IDS_INACTIVESELECTED;
    const ink = if (selected) pens[sc.FILLTEXTPEN] else pens[sc.TEXTPEN];
    const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = ink }, .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} };
    gb.SetRPAttrs(rp, &tags);
    gb.Move(rp, x, y + @as(i32, @intCast(baseline)));
    gb.Text(rp, text, textLen(text));
}

/// Make gadgetclass, from rootclass, and put it on the public list.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.GADGETCLASS, classusr.ROOTCLASS, null, @sizeOf(Data)) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

/// The gadget of any object made from gadgetclass.
pub fn gadgetOf(ib: *IntuitionBase, o: *Object) *Data {
    return classes.instData(Data, ib.gadget_class.?, o);
}

/// Whether an object is a gadget: gadgetclass is its class or one of the
/// classes it is made from.
pub fn isGadget(ib: *IntuitionBase, o: *Object) bool {
    var cl: ?*Class = classes.objectClass(o);
    while (cl) |c| : (cl = c.super) {
        if (c == ib.gadget_class) return true;
    }
    return false;
}

fn setFlag(word: *u32, bit: u32, on: bool) void {
    if (on) word.* |= bit else word.* &= ~bit;
}

/// The attributes; nonzero when something that shows changed.
fn setAttrs(ib: *IntuitionBase, g: *Data, tags: ?[*]const TagItem) usize {
    var changed: usize = 0;
    var state = tags;
    while (ib.utility_base.NextTagItem(&state)) |item| {
        const v = item.data;
        const n: i32 = @bitCast(@as(u32, @truncate(v)));
        switch (item.tag) {
            gc.GA_Left, gc.GA_RelRight => {
                g.left = n;
                setFlag(&g.flags, GFLG_RELRIGHT, item.tag == gc.GA_RelRight);
                changed = 1;
            },
            gc.GA_Top, gc.GA_RelBottom => {
                g.top = n;
                setFlag(&g.flags, GFLG_RELBOTTOM, item.tag == gc.GA_RelBottom);
                changed = 1;
            },
            gc.GA_Width, gc.GA_RelWidth => {
                g.width = n;
                setFlag(&g.flags, GFLG_RELWIDTH, item.tag == gc.GA_RelWidth);
                changed = 1;
            },
            gc.GA_Height, gc.GA_RelHeight => {
                g.height = n;
                setFlag(&g.flags, GFLG_RELHEIGHT, item.tag == gc.GA_RelHeight);
                changed = 1;
            },
            gc.GA_Text => {
                g.text = @ptrFromInt(v);
                g.itext = null;
                g.label_image = null;
                changed = 1;
            },
            gc.GA_IntuiText => {
                g.itext = @ptrFromInt(v);
                g.text = null;
                g.label_image = null;
                changed = 1;
            },
            gc.GA_LabelImage => {
                g.label_image = @ptrFromInt(v);
                g.text = null;
                g.itext = null;
                changed = 1;
            },
            gc.GA_SelectRender => {
                g.select_render = @ptrFromInt(v);
                changed = 1;
            },
            gc.GA_Highlight => {
                g.highlight = @as(u32, @truncate(v)) & 3;
                changed = 1;
            },
            gc.GA_Bounds => if (v != 0) {
                g.bounds = @as(*const gc.Box, @ptrFromInt(v)).*;
                g.flags |= GFLG_BOUNDS;
            } else {
                g.flags &= ~GFLG_BOUNDS;
            },
            gc.GA_Next => g.next = @ptrFromInt(v),
            gc.GA_SysGadget => setFlag(&g.flags, GFLG_SYSGADGET, v != 0),
            gc.GA_SysGType => g.sys_type = @truncate(v),
            gc.GA_FollowMouse => setFlag(&g.activation, GACT_FOLLOWMOUSE, v != 0),
            gc.GA_Image => {
                g.image = @ptrFromInt(v);
                changed = 1;
            },
            gc.GA_Disabled => {
                setFlag(&g.flags, GFLG_DISABLED, v != 0);
                changed = 1;
            },
            gc.GA_Selected => {
                setFlag(&g.flags, GFLG_SELECTED, v != 0);
                changed = 1;
            },
            gc.GA_TabCycle => setFlag(&g.flags, GFLG_TABCYCLE, v != 0),
            gc.GA_GZZGadget => setFlag(&g.flags, GFLG_GZZGADGET, v != 0),
            gc.GA_GadgetHelp => setFlag(&g.flags, GFLG_GADGETHELP, v != 0),
            gc.GA_ToggleSelect => setFlag(&g.activation, GACT_TOGGLESELECT, v != 0),
            gc.GA_EndGadget => setFlag(&g.activation, GACT_ENDGADGET, v != 0),
            gc.GA_RightBorder => setFlag(&g.activation, GACT_RIGHTBORDER, v != 0),
            gc.GA_LeftBorder => setFlag(&g.activation, GACT_LEFTBORDER, v != 0),
            gc.GA_TopBorder => setFlag(&g.activation, GACT_TOPBORDER, v != 0),
            gc.GA_BottomBorder => setFlag(&g.activation, GACT_BOTTOMBORDER, v != 0),
            gc.GA_ID => g.id = @truncate(v),
            gc.GA_UserData => g.user_data = v,
            gc.GA_Immediate => setFlag(&g.activation, GACT_IMMEDIATE, v != 0),
            gc.GA_RelVerify => setFlag(&g.activation, GACT_RELVERIFY, v != 0),
            gc.GA_DrawInfo => g.draw_info = @ptrFromInt(v),
            icc.ICA_TARGET => g.target = v,
            icc.ICA_MAP => g.map = @ptrFromInt(v),
            else => {},
        }
    }
    return changed;
}

fn get(g: *Data, msg: *classusr.OpGet) bool {
    const out = msg.storage;
    switch (msg.attr_id) {
        gc.GA_ID => out.* = g.id,
        gc.GA_UserData => out.* = g.user_data,
        gc.GA_Selected => out.* = @intFromBool(g.flags & GFLG_SELECTED != 0),
        gc.GA_Disabled => out.* = @intFromBool(g.flags & GFLG_DISABLED != 0),
        gc.GA_Text => out.* = @intFromPtr(g.text),
        gc.GA_IntuiText => out.* = @intFromPtr(g.itext),
        gc.GA_LabelImage => out.* = @intFromPtr(g.label_image),
        gc.GA_SelectRender => out.* = @intFromPtr(g.select_render),
        gc.GA_Highlight => out.* = g.highlight,
        gc.GA_Next => out.* = @intFromPtr(g.next),
        gc.GA_SysGadget => out.* = @intFromBool(g.flags & GFLG_SYSGADGET != 0),
        gc.GA_SysGType => out.* = g.sys_type,
        gc.GA_FollowMouse => out.* = @intFromBool(g.activation & GACT_FOLLOWMOUSE != 0),
        gc.GA_GadgetHelp => out.* = @intFromBool(g.flags & GFLG_GADGETHELP != 0),
        gc.GA_Image => out.* = @intFromPtr(g.image),
        gc.GA_Left, gc.GA_RelRight => out.* = @bitCast(@as(isize, g.left)),
        gc.GA_Top, gc.GA_RelBottom => out.* = @bitCast(@as(isize, g.top)),
        gc.GA_Width, gc.GA_RelWidth => out.* = @bitCast(@as(isize, g.width)),
        gc.GA_Height, gc.GA_RelHeight => out.* = @bitCast(@as(isize, g.height)),
        else => return false,
    }
    return true;
}

/// Tell the target what changed, mapped, unless already telling it.
fn notify(ib: *IntuitionBase, g: *Data, msg: *const classusr.OpUpdate) void {
    if (g.target == 0 or g.loop_count != 0 or msg.attr_list == null) return;
    const ub = ib.utility_base;
    g.loop_count += 1;
    defer g.loop_count -= 1;

    // A copy, so the sender's list comes back as it went.
    const copy = ub.CloneTagItems(msg.attr_list) orelse return;
    if (g.map != null) ub.MapTags(copy, g.map, utility.tagitem.MAP_KEEP_NOT_FOUND);
    if (g.target == icc.ICTARGET_IDCMP) {
        // The window keeps the copy until the message is replied.
        const gi = msg.gadget_info orelse {
            ub.FreeTagItems(copy);
            return;
        };
        const interim = msg.flags & classusr.OPUF_INTERIM != 0;
        if (!_window.sendUpdate(ib, @ptrCast(@alignCast(gi.window)), copy, interim)) ub.FreeTagItems(copy);
        return;
    }
    defer ub.FreeTagItems(copy);
    var out = classusr.OpUpdate{
        .method_id = classusr.OM_UPDATE,
        .attr_list = copy,
        .gadget_info = msg.gadget_info,
        .flags = msg.flags,
    };
    _ = ib.iface().SendMessage(@ptrFromInt(g.target), @ptrCast(&out));
}

/// `GA_Previous`: where in a window's list this gadget goes.
///
/// **Only when the gadget is made.** A gadget is linked in after the one
/// named, keeping the rest of the chain behind it. Setting it again on a
/// gadget already in a list would splice it a second time and lose
/// whatever followed, so a gadget that is already somewhere is moved with
/// `RemoveGList` and `AddGList`, which is what those calls are for.
fn linkAfter(ib: *IntuitionBase, o: *Object, g: *Data, tags: ?[*]const TagItem) void {
    const item = ib.utility_base.FindTagItem(gc.GA_Previous, tags) orelse return;
    if (item.data == 0) return;
    const prev = gadgetOf(ib, @ptrFromInt(item.data));
    g.next = prev.next;
    prev.next = o;
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
            const obj: *Object = @ptrFromInt(made);
            const g = classes.instData(Data, cl, obj);
            _ = setAttrs(ib, g, new.attr_list);
            linkAfter(ib, obj, g, new.attr_list);
            return made;
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const obj = o orelse return 0;
            return setAttrs(ib, classes.instData(Data, cl, obj), set.attr_list) | it.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_GET => {
            if (get(classes.instData(Data, cl, o orelse return 0), @ptrCast(@alignCast(msg)))) return 1;
            return it.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_NOTIFY => {
            notify(ib, classes.instData(Data, cl, o orelse return 0), @ptrCast(@alignCast(msg)));
            return 1;
        },
        gc.GM_HITTEST => return gc.GMR_GADGETHIT,
        gc.GM_RENDER, gc.GM_GOINACTIVE => return 0,
        // Asked about a point already known to be in the box: it is this
        // gadget's, and it has nothing more particular to say about which
        // part of itself was pointed at.
        gc.GM_HELPTEST => return gc.GMR_HELPHIT,
        gc.GM_GOACTIVE, gc.GM_HANDLEINPUT => return gc.GMR_NOREUSE,
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
