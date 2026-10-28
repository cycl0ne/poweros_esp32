// SPDX-License-Identifier: MIT
//! tapedeck.gadget: a tape deck's buttons, or an animation player's.
//!
//! A gadgetclass gadget of a row of buttons, each a button bevel with a
//! media.image picture in its middle, as large as the bevel leaves room
//! for: raised on the background pen with the picture in the text pen, or
//! pressed on the fill pen with it in the fill-text pen. The deck makes
//! its picture when it is made, through `images/media.image`; without
//! that library its buttons are drawn bare. It is a line of its font high
//! and its bevel, as a chooser or a string gadget is, so they stand in a
//! row at one height.
//!
//! As a tape deck: rewind, play and fast forward, then stop and pause,
//! the two groups a quarter of the height apart; play, stop and pause
//! twice the height wide, the others one and a half. With tracks the song
//! before stands at the left and the song after at the right, each a gap
//! apart. A press on a button ends the press at once: the first four make
//! their mode the deck's, shown pressed, pause turns over, and the song
//! before and after leave the mode as it is. The code is the mode, or
//! `BUT_PREVIOUS` or `BUT_NEXT`, with `TDECK_PAUSED_CODE` added while
//! paused.
//!
//! As an animation control: rewind, play and fast forward, sized from the
//! gadget's width (rewind and fast forward gone below 80 pixels), and in
//! the rest a frame slider - a borderless propgclass gadget of this one's
//! own, a frame to a step, placed inside a bevel and handed the input that
//! lands there. A button's mode is shown while it is held and the pointer
//! on it; let go on it, play stays - or stops when it was already playing
//! - and rewind and fast forward stop. The code is the mode, or for the
//! slider the frame with `TDECK_FRAME_CODE` added. The right button puts
//! back the mode and the frame the press began with.
//!
//! The target hears the mode, whether paused, and the frame with the
//! gadget's `GA_ID` as they change.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const icc = intuition.icclass;
const pg = intuition.propgclass;
const sc = intuition.screens;
const ie = sdk.devices.inputevent;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const td = gadgets.tapedeck;
const media = sdk.images.media;
const exec = sdk.exec;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = td.TDECK_CLASS,
    .version = 1,
    .revision = 1,
    .date = "28.10.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

// --- the pictures --------------------------------------------------------------

/// The picture a button shows, or none.
fn pictureOf(id: u32) u32 {
    return switch (id) {
        td.BUT_REWIND => media.MEDIA_REWIND,
        td.BUT_PLAY => media.MEDIA_PLAY,
        td.BUT_FORWARD => media.MEDIA_FORWARD,
        td.BUT_STOP => media.MEDIA_STOP,
        td.BUT_PAUSE => media.MEDIA_PAUSE,
        td.BUT_PREVIOUS => media.MEDIA_PREVIOUS,
        td.BUT_NEXT => media.MEDIA_NEXT,
        else => media.MEDIA_NONE,
    };
}

// --- the gadget -------------------------------------------------------------------

/// The least either is high, and an animation control's width when it is
/// given none.
const least_height = 16;
const anim_width = 202;
/// The frame slider inside its bevel.
const slider_inset_x = 4;
const slider_inset_y = 2;
/// Room between a button's bevel and its picture, each side.
const picture_inset = 3;

/// tapedeck.gadget's part of an object.
pub const Data = extern struct {
    mode: u32 = td.BUT_STOP,
    /// What a press began with, and the button it began on.
    old_mode: u32 = td.BUT_STOP,
    pressed_on: u32 = td.BUT_STOP,
    old_frame: u32 = 0,
    frames: u32 = 10,
    current_frame: u32 = 0,
    tape: u8 = 0,
    /// The song before and after, round a tape deck.
    tracks: u8 = 0,
    paused: u8 = 0,
    /// The frame slider has the input.
    in_slider: u8 = 0,
    sized: u8 = 0,
    /// The frame slider, and the buttons' bevel.
    slider: ?*Object = null,
    frame: ?*Object = null,
    /// The buttons' picture, and the library it is from.
    picture: ?*Object = null,
    pictures: ?*exec.Library = null,
};

/// The buttons: at most seven, each a box from the gadget's corner and
/// what it is.
pub const Buttons = struct {
    boxes: [7]gc.Box = @splat(.{}),
    ids: [7]u32 = @splat(td.BUT_STOP),
    count: usize = 0,
    /// Where the last ends.
    right: i32 = 0,

    fn add(buttons: *Buttons, box: gc.Box, id: u32) void {
        buttons.boxes[buttons.count] = box;
        buttons.ids[buttons.count] = id;
        buttons.count += 1;
        buttons.right = box.left + box.width;
    }

    /// The next button after the last, `width` wide, or a gap after it
    /// first.
    fn next(buttons: *Buttons, width: i32, height: i32, gap: i32, id: u32) void {
        buttons.add(.{ .left = buttons.right + gap, .width = width, .height = height }, id);
    }

    /// A tape deck's buttons at a height: the wide ones twice it, the
    /// narrow one and a half, the groups a quarter of it apart.
    pub fn ofTape(tracks: bool, height: i32) Buttons {
        var buttons = Buttons{};
        const wide = 2 * height;
        const narrow = @divTrunc(3 * height, 2);
        const gap = @max(@divTrunc(height, 4), 3);
        if (tracks) buttons.next(narrow, height, 0, td.BUT_PREVIOUS);
        buttons.next(narrow, height, if (tracks) gap else 0, td.BUT_REWIND);
        buttons.next(wide, height, 0, td.BUT_PLAY);
        buttons.next(narrow, height, 0, td.BUT_FORWARD);
        buttons.next(wide, height, gap, td.BUT_STOP);
        buttons.next(wide, height, 0, td.BUT_PAUSE);
        if (tracks) buttons.next(narrow, height, gap, td.BUT_NEXT);
        return buttons;
    }

    pub fn of(tape: bool, tracks: bool, width: i32, height: i32) Buttons {
        if (tape) return ofTape(tracks, height);
        var buttons = Buttons{};
        const h = height;
        // The buttons grow with the gadget; rewind and fast forward go when
        // it is too narrow for them.
        var side = @max(@divTrunc(width * 100, 748), 23);
        const middle = @max(@divTrunc(width * 100, 420), 14);
        if (width < 80) side = 0;
        buttons.add(.{ .left = 0, .width = side, .height = h }, td.BUT_REWIND);
        buttons.add(.{ .left = side, .width = middle, .height = h }, td.BUT_PLAY);
        buttons.add(.{ .left = side + middle, .width = side, .height = h }, td.BUT_FORWARD);
        const left = 2 * side + middle;
        buttons.add(.{ .left = left, .width = @max(width - left, 0), .height = h }, td.BUT_FRAME);
        return buttons;
    }

    /// The button a point is on, if any.
    pub fn at(buttons: Buttons, x: i32, y: i32) ?u32 {
        for (buttons.boxes[0..buttons.count], buttons.ids[0..buttons.count]) |box, id| {
            if (box.width > 0 and support.inside(x - box.left, y - box.top, box.width, box.height)) return id;
        }
        return null;
    }

    /// The frame slider's place, inside the frame button's bevel.
    fn sliderBox(buttons: Buttons) gc.Box {
        const box = buttons.boxes[3];
        return .{ .left = box.left + slider_inset_x, .top = box.top + slider_inset_y, .width = @max(box.width - 2 * slider_inset_x, 1), .height = @max(box.height - 2 * slider_inset_y, 1) };
    }
};

fn buttonsOf(own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) Buttons {
    const b = gc.boxFor(gc.gadget(o), gi);
    return Buttons.of(own.tape != 0, own.tracks != 0, b.width, b.height);
}

/// How high it is: a line of its font and its bevel, and never less than
/// `least_height`.
fn heightOf(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo) i32 {
    const ib = base.intuition_base;
    const measure = support.Measure.of(ib, g, gi);
    defer measure.done(ib);
    const line = measure.lineHeight(base.graphics_base);
    const dri = if (gi) |info| info.draw_info else g.draw_info;
    const inset = if (own.frame) |frame| support.frameInset(ib, frame, dri, g.style) else gc.Box{ .width = 4, .height = 4 };
    return @max(line + inset.height, least_height);
}

/// The slider put where it belongs; its place in the gadget's box.
fn placeSlider(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) gc.Box {
    const b = gc.boxFor(gc.gadget(o), gi);
    const at = buttonsOf(own, o, gi).sliderBox();
    support.place(base.intuition_base, own.slider.?, .{ .left = b.left + at.left, .top = b.top + at.top, .width = at.width, .height = at.height });
    return at;
}

// --- drawing ------------------------------------------------------------------------

/// Whether a button shows pressed.
fn pressed(own: *const Data, g: *const gc.Gadget, id: u32) bool {
    if (id == td.BUT_PAUSE) return own.paused != 0;
    if (id != own.mode) return false;
    const held = g.flags & gc.GFLG_SELECTED != 0;
    return ((held or own.tape != 0) and own.mode != td.BUT_FRAME) or (own.mode == td.BUT_PLAY and own.tape == 0);
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const own = classes.instData(Data, cl, o);
    const g = gc.gadget(o);
    const b = gc.boxFor(g, info);
    const styled = support.pensFor(ib, info.draw_info, g.style, sdk.intuition.style.PART_MAIN, null);
    const pens: [*]const graphics.Pen = &styled;
    const rp = r.rast_port;
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);
    const buttons = buttonsOf(own, o, info);
    for (buttons.boxes[0..buttons.count], buttons.ids[0..buttons.count]) |part, id| {
        if (part.width <= 0) continue;
        const box = gc.Box{ .left = b.left + part.left, .top = b.top + part.top, .width = part.width, .height = part.height };
        const down = pressed(own, g, id);
        support.drawFrame(ib, own.frame.?, rp, box, if (down) ic.IDS_SELECTED else ic.IDS_NORMAL, info.draw_info, gc.gadget(o).style);
        support.fill(gb, rp, .{ .left = box.left + 2, .top = box.top + 1, .width = box.width - 4, .height = box.height - 2 }, if (down) pens[sc.FILLPEN] else pens[sc.BACKGROUNDPEN]);
        drawPicture(base, own, rp, info, box, id, down);
    }
    if (own.slider) |slider| {
        _ = placeSlider(base, own, o, info);
        var slider_render = r.*;
        slider_render.redraw = gc.GREDRAW_REDRAW;
        _ = ib.SendMessage(slider, @ptrCast(&slider_render));
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

/// A button's picture in the middle of its box, as large as the bevel
/// leaves room for, in the colours the screen and the gadget's style give
/// that button - pressed, on the fill.
fn drawPicture(base: *gadgets.Base, own: *const Data, rp: *graphics.RastPort, info: *classusr.GadgetInfo, box: gc.Box, id: u32, down: bool) void {
    const picture = own.picture orelse return;
    const which = pictureOf(id);
    if (which == media.MEDIA_NONE) return;
    const ib = base.intuition_base;
    const size = @min(box.width, box.height) - 2 * picture_inset;
    if (size < 4) return;
    _ = ib.SetAttrsTagList(picture, &[_]TagItem{ .{ .tag = media.MEDIA_Glyph, .data = which }, .{} });
    var draw = ic.ImpDraw{
        .method_id = ic.IM_DRAWFRAME,
        .rast_port = rp,
        .offset = .{ .x = box.left + @divTrunc(box.width - size, 2), .y = box.top + @divTrunc(box.height - size, 2) },
        .state = if (down) ic.IDS_SELECTED else ic.IDS_NORMAL,
        .draw_info = info.draw_info,
        .dimensions = .{ .width = size, .height = size },
    };
    _ = ib.SendMessage(picture, @ptrCast(&draw));
}

fn redraw(base: *gadgets.Base, o: *Object, gi: ?*classusr.GadgetInfo) void {
    support.redraw(base.intuition_base, o, gi);
}

/// The target told the deck's state.
fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo, flags: u32) void {
    const tags = [_]TagItem{
        .{ .tag = td.TDECK_Mode, .data = own.mode },
        .{ .tag = td.TDECK_Paused, .data = own.paused },
        .{ .tag = td.TDECK_CurrentFrame, .data = own.current_frame },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, flags);
}

/// The slider's frame count and frame.
fn putSlider(base: *gadgets.Base, own: *const Data, gi: ?*classusr.GadgetInfo) void {
    const slider = own.slider orelse return;
    const tags = [_]TagItem{
        .{ .tag = pg.PGA_Total, .data = @max(own.frames, 1) },
        .{ .tag = pg.PGA_Visible, .data = 1 },
        .{ .tag = pg.PGA_Top, .data = own.current_frame },
        .{},
    };
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags, .gadget_info = gi };
    _ = base.intuition_base.SendMessage(slider, @ptrCast(&set));
}

// --- attributes ---------------------------------------------------------------------

/// The attributes among `tags`; whether anything that shows changed.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem, new: bool) bool {
    const ub = base.utility_base;
    var changed = false;
    var frames_changed = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        const value: u32 = @truncate(item.data);
        switch (item.tag) {
            td.TDECK_Tape => if (new) {
                own.tape = @intFromBool(item.data != 0);
            },
            td.TDECK_Tracks => if (new) {
                own.tracks = @intFromBool(item.data != 0);
            },
            td.TDECK_Mode => if (value <= td.BUT_STOP) {
                if (value != own.mode) changed = true;
                own.mode = value;
            } else if (value == td.BUT_PAUSE) {
                own.paused ^= 1;
                changed = true;
            },
            td.TDECK_Paused => {
                own.paused = @intFromBool(item.data != 0);
                changed = true;
            },
            td.TDECK_CurrentFrame => {
                if (value != own.current_frame) changed = true;
                own.current_frame = value;
                frames_changed = true;
            },
            td.TDECK_Frames => {
                own.frames = value;
                frames_changed = true;
            },
            else => {},
        }
    }
    if (frames_changed and !new) putSlider(base, own, null);
    return changed;
}

// --- input ----------------------------------------------------------------------------

/// A tape deck's press: the button's mode, or pause turned over, or the
/// song before or after asked for, and done.
fn pressTape(base: *gadgets.Base, own: *Data, o: *Object, in: *gc.GpInput) usize {
    const buttons = buttonsOf(own, o, in.gadget_info);
    var code = own.mode;
    if (buttons.at(in.mouse.x, in.mouse.y)) |id| {
        if (id == td.BUT_PREVIOUS or id == td.BUT_NEXT) {
            code = id;
        } else {
            if (id == td.BUT_PAUSE) own.paused ^= 1 else own.mode = id;
            code = own.mode;
            redraw(base, o, in.gadget_info);
            tell(base, own, o, in.gadget_info, 0);
        }
    }
    in.termination.* = @intCast(code | (if (own.paused != 0) td.TDECK_PAUSED_CODE else 0));
    return gc.GMR_NOREUSE | gc.GMR_VERIFY;
}

/// The slider handed input, and what it leaves: the frame, and its code.
fn toSlider(base: *gadgets.Base, own: *Data, o: *Object, in: *gc.GpInput) usize {
    const at = placeSlider(base, own, o, in.gadget_info);
    const result = support.handOnInput(base.intuition_base, own.slider.?, in, at);
    own.in_slider = @intFromBool(result == gc.GMR_MEACTIVE);
    in.termination.* = @intCast(td.TDECK_FRAME_CODE | own.current_frame);
    return result;
}

/// An animation control's press.
fn pressAnim(base: *gadgets.Base, own: *Data, o: *Object, in: *gc.GpInput) usize {
    const g = gc.gadget(o);
    const buttons = buttonsOf(own, o, in.gadget_info);
    const under = buttons.at(in.mouse.x, in.mouse.y) orelse td.BUT_STOP;
    own.old_frame = own.current_frame;
    own.old_mode = own.mode;
    own.pressed_on = under;
    g.flags |= gc.GFLG_SELECTED;
    if (under == td.BUT_FRAME) {
        own.mode = td.BUT_STOP;
        redraw(base, o, in.gadget_info);
        return toSlider(base, own, o, in);
    }
    // Play pressed while playing: stopped.
    if (under == own.old_mode) {
        own.mode = td.BUT_STOP;
        g.flags &= ~gc.GFLG_SELECTED;
        redraw(base, o, in.gadget_info);
        tell(base, own, o, in.gadget_info, 0);
        in.termination.* = @intCast(own.mode);
        return gc.GMR_NOREUSE | gc.GMR_VERIFY;
    }
    own.mode = under;
    redraw(base, o, in.gadget_info);
    tell(base, own, o, in.gadget_info, classusr.OPUF_INTERIM);
    return gc.GMR_MEACTIVE;
}

fn handleAnim(base: *gadgets.Base, own: *Data, o: *Object, in: *gc.GpInput) usize {
    const g = gc.gadget(o);
    const e = in.event orelse return gc.GMR_MEACTIVE;
    if (e.class != ie.IECLASS_NEWPOINTERPOS) {
        if (own.in_slider != 0) return toSlider(base, own, o, in);
        return gc.GMR_MEACTIVE;
    }
    // The right button: as it was when the press began.
    if (e.code == ie.IECODE_RBUTTON) {
        own.current_frame = own.old_frame;
        putSlider(base, own, in.gadget_info);
        own.mode = own.old_mode;
        own.in_slider = 0;
        g.flags &= ~gc.GFLG_SELECTED;
        redraw(base, o, in.gadget_info);
        tell(base, own, o, in.gadget_info, 0);
        return gc.GMR_NOREUSE;
    }
    if (own.pressed_on == td.BUT_FRAME) return toSlider(base, own, o, in);

    const buttons = buttonsOf(own, o, in.gadget_info);
    const under = buttons.at(in.mouse.x, in.mouse.y) orelse td.BUT_STOP;
    const was = own.mode;
    var result: usize = gc.GMR_MEACTIVE;
    if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
        result = gc.GMR_NOREUSE | gc.GMR_VERIFY;
        var mode = under;
        if (under != own.pressed_on or under == own.old_mode) {
            mode = td.BUT_STOP;
        } else if (mode == td.BUT_REWIND or mode == td.BUT_FORWARD) {
            mode = td.BUT_STOP;
        }
        own.mode = mode;
        g.flags &= ~gc.GFLG_SELECTED;
        in.termination.* = @intCast(own.mode);
    } else if (under != own.pressed_on) {
        // Off the button: stopped while it is off.
        g.flags &= ~gc.GFLG_SELECTED;
        own.mode = td.BUT_STOP;
    } else {
        g.flags |= gc.GFLG_SELECTED;
        own.mode = own.pressed_on;
    }
    redraw(base, o, in.gadget_info);
    if (own.mode != was or result != gc.GMR_MEACTIVE) tell(base, own, o, in.gadget_info, if (result != gc.GMR_MEACTIVE) 0 else classusr.OPUF_INTERIM);
    return result;
}

/// Its size: a tape deck its buttons at its height; an animation control
/// as wide as there is room.
fn domain(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, which: u32) gc.Box {
    const height = heightOf(base, own, g, gi);
    const width: i32 = if (own.tape != 0) Buttons.ofTape(own.tracks != 0, height).right else switch (which) {
        gc.GDOMAIN_MINIMUM => 40,
        gc.GDOMAIN_NOMINAL => if (own.sized != 0) g.given_width else anim_width,
        else => gc.GDOMAIN_UNLIMITED,
    };
    return .{ .width = width, .height = height };
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
            _ = setAttrs(base, own, new.attr_list, true);
            const frame_tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
            own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
            var ok = own.frame != null;
            if (ok and own.tape == 0) {
                const slider_tags = [_]TagItem{
                    .{ .tag = pg.PGA_Freedom, .data = pg.FREEHORIZ },
                    .{ .tag = pg.PGA_Borderless, .data = 1 },
                    .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(obj) },
                    .{},
                };
                own.slider = ib.NewObjectTagList(null, classusr.PROPGCLASS, &slider_tags);
                ok = own.slider != null;
                if (ok) putSlider(base, own, null);
            }
            if (!ok) {
                ib.DisposeObject(own.slider);
                ib.DisposeObject(own.frame);
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendSuperMessage(cl, obj, &gone);
                return 0;
            }
            // The buttons' picture; without its library they are bare.
            own.pictures = base.sys_base.OpenLibrary(media.MEDIA_LIBRARY, 0);
            if (own.pictures != null) own.picture = ib.NewObjectTagList(null, media.MEDIA_CLASS, null);
            // Reported when a press ends; made without a size, as large
            // as it is meant to be.
            const ub = base.utility_base;
            own.sized = @intFromBool(ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null);
            const size = domain(base, own, gc.gadget(obj), null, gc.GDOMAIN_NOMINAL);
            const tags = [_]TagItem{
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = if (own.sized != 0) utility.TAG_DONE else gc.GA_Width, .data = @intCast(size.width) },
                .{ .tag = gc.GA_Height, .data = @intCast(size.height) },
                .{},
            };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
            _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            ib.DisposeObject(own.slider);
            ib.DisposeObject(own.frame);
            ib.DisposeObject(own.picture);
            if (own.pictures) |lib| base.sys_base.CloseLibrary(lib);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            // The frame slider moving: the frame follows it, and is told.
            if (msg.method_id == classusr.OM_UPDATE) if (base.utility_base.FindTagItem(pg.PGA_Top, set.attr_list)) |item| {
                const update: *classusr.OpUpdate = @ptrCast(@alignCast(msg));
                const frame: u32 = @truncate(item.data);
                const moved = frame != own.current_frame;
                own.current_frame = frame;
                if (moved or update.flags & classusr.OPUF_INTERIM == 0) tell(base, own, o.?, update.gadget_info, update.flags);
                return 0;
            };
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(base, own, set.attr_list, false)) changed = 1;
            if (changed != 0 and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                redraw(base, o.?, set.gadget_info);
                return 0;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            switch (get.attr_id) {
                td.TDECK_Mode => get.storage.* = own.mode,
                td.TDECK_Paused => get.storage.* = own.paused,
                td.TDECK_CurrentFrame => get.storage.* = own.current_frame,
                td.TDECK_Frames => get.storage.* = own.frames,
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            ask.domain = domain(base, own, gc.gadget(o.?), ask.gadget_info, ask.which);
            return 1;
        },
        gc.GM_HITTEST => return gc.GMR_GADGETHIT,
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            if (in.event == null) return gc.GMR_NOREUSE;
            const own = classes.instData(Data, cl, o.?);
            return if (own.tape != 0) pressTape(base, own, o.?, in) else pressAnim(base, own, o.?, in);
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (own.tape != 0) return gc.GMR_NOREUSE;
            return handleAnim(base, own, o.?, in);
        },
        gc.GM_GOINACTIVE => {
            const gone: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            gc.gadget(o.?).flags &= ~gc.GFLG_SELECTED;
            if (own.in_slider != 0) {
                own.in_slider = 0;
                _ = placeSlider(base, own, o.?, gone.gadget_info);
                _ = ib.SendMessage(own.slider.?, msg);
            }
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
