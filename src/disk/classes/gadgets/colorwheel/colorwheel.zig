// SPDX-License-Identifier: MIT
//! colorwheel.gadget: a wheel of hues and saturations, and a dot on it.
//!
//! A gadgetclass gadget. Its picture is worked out a pixel at a time into
//! a buffer of its own: round the wheel, the hue (red at the top, going
//! clockwise); out from the middle, the saturation; everything at full
//! brightness; a rim two pixels wide in the shadow pen, and the ground
//! round it in the background pen. A disabled wheel has every other pixel
//! of it in the shadow pen. The buffer is made again only when the
//! gadget's size or its being disabled changes, and drawing the wheel is
//! putting it down with `WritePixelArray`.
//!
//! The wheel is round, the largest circle in the middle of the box: the
//! pixels are square, so it has no need to be drawn as an ellipse.
//!
//! The dot is a disc in the shine pen ringed in the shadow pen, where the
//! colour's hue and saturation put it. Moving it puts back the buffer's
//! pixels where it was and draws it anew. The wheel keeps a dot's radius
//! clear inside its box, so the dot never leaves what the buffer holds.
//! With `WHEEL_BevelBox` the box has a button bevel round it as well.
//!
//! A press on the wheel - anywhere in the box, with a bevel - keeps the
//! colour as it was and moves the dot to the pointer; the dot follows it,
//! and each change is told to the target as `WHEEL_Hue` and
//! `WHEEL_Saturation` with the gadget's `GA_ID`. Let go, or the right
//! button - which first puts the colour back - ends the press the way that
//! counts.
//!
//! The library's own calls, `ConvertHSBToRGB` and `ConvertRGBToHSB`, are
//! in their own files; the arithmetic they share with the class is
//! `_colour.zig`.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const sc = intuition.screens;
const ie = sdk.devices.inputevent;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const cw = gadgets.colorwheel;
const gs = gadgets.gradientslider;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;
const colour = @import("_colour.zig");
const ConvertHSBToRGB = @import("converthsbtorgb.zig").ConvertHSBToRGB;
const ConvertRGBToHSB = @import("convertrgbtohsb.zig").ConvertRGBToHSB;

fn lvoConvertHSBToRGB(base: *gadgets.Base, hsb: *const cw.ColorWheelHSB, rgb: *cw.ColorWheelRGB) callconv(.c) void {
    ConvertHSBToRGB(base, hsb, rgb);
}
fn lvoConvertRGBToHSB(base: *gadgets.Base, rgb: *const cw.ColorWheelRGB, hsb: *cw.ColorWheelHSB) callconv(.c) void {
    ConvertRGBToHSB(base, rgb, hsb);
}

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = cw.WHEEL_CLASS,
    .version = 1,
    .date = "25.09.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
    .functions = &.{ exec.libraries.vec(lvoConvertHSBToRGB), exec.libraries.vec(lvoConvertRGBToHSB) },
});
comptime {
    _ = Library;
}

/// How wide the rim is, and how big the dot.
const rim_width = 2;
const dot_radius = 3;
/// A wheel's size as it looks right, and at the least.
const nominal_size = 100;
const least_size = 2 * (dot_radius + 8);

/// colorwheel.gadget's part of an object.
pub const Data = extern struct {
    /// The colour, each component to 0xFFFF.
    hue: u32 = 0,
    saturation: u32 = 0xFFFF,
    brightness: u32 = 0xFFFF,
    /// What the colour was when a press began, for the right button.
    saved_hue: u32 = 0,
    saved_saturation: u32 = 0,
    bevel: u8 = 0,
    sized: u8 = 0,
    /// The dot is drawn, at `dot_x`, `dot_y` from the box's corner.
    dot_shown: u8 = 0,
    /// The buffer was worked out disabled.
    picture_disabled: u8 = 0,
    dot_x: i32 = 0,
    dot_y: i32 = 0,
    /// The picture of the box, a pen per pixel, and its size.
    picture: ?[*]Pen = null,
    picture_width: i32 = 0,
    picture_height: i32 = 0,
    /// The button bevel, with `WHEEL_BevelBox`.
    frame: ?*Object = null,
    /// `WHEEL_GradientSlider`: where the brightness is picked.
    gradient_slider: ?*Object = null,
};

// --- where the wheel is ------------------------------------------------------

/// The wheel in a box `width` by `height`: its middle and radii, from the
/// box's corner.
pub const Wheel = struct {
    cx: i32,
    cy: i32,
    xr: i32,
    yr: i32,

    /// Round, as big as the box allows, in its middle: the pixels here
    /// are square.
    pub fn of(bevel: bool, width: i32, height: i32) Wheel {
        const cx = @divTrunc(width - 1, 2);
        const cy = @divTrunc(height - 1, 2);
        // Room for the dot at the rim, and for a bevel round it.
        const in_x: i32 = dot_radius + @as(i32, if (bevel) 4 else 0);
        const in_y: i32 = dot_radius + @as(i32, if (bevel) 2 else 0);
        const radius = @max(@min(cx - in_x, cy - in_y), 1);
        return .{ .cx = cx, .cy = cy, .xr = radius, .yr = radius };
    }

    /// Where the dot is for a hue and saturation.
    pub fn dot(wheel: Wheel, hue: u32, saturation: u32) struct { x: i32, y: i32 } {
        const at = colour.dotAt(hue, saturation, wheel.xr, wheel.yr);
        return .{ .x = wheel.cx + at.x, .y = wheel.cy + at.y };
    }

    /// Whether a point is on the wheel, the dot's reach round its rim
    /// counted in.
    pub fn contains(wheel: Wheel, x: i32, y: i32) bool {
        const xf = wheel.xr + dot_radius - 1;
        const yf = wheel.yr + dot_radius - 1;
        const xoff: i64 = x - wheel.cx;
        const yoff: i64 = colour.roundDiv((y - wheel.cy) * xf, yf);
        return xoff * xoff + yoff * yoff <= @as(i64, xf) * xf;
    }
};

fn wheelOf(own: *const Data, b: gc.Box) Wheel {
    return Wheel.of(own.bevel != 0, b.width, b.height);
}

// --- the picture ----------------------------------------------------------------

/// A colour of 16-bit components as a pen.
fn penOf(rgb: colour.Rgb) Pen {
    return 0xFF000000 | ((rgb.red >> 8) << 16) | ((rgb.green >> 8) << 8) | (rgb.blue >> 8);
}

/// Every pixel of the box: ground, wheel, rim, and the ghost when
/// disabled.
pub fn paint(into: [*]Pen, width: i32, height: i32, wheel: Wheel, pens: [*]const Pen, disabled: bool) void {
    const ground = pens[sc.BACKGROUNDPEN];
    const shadow = pens[sc.SHADOWPEN];
    const rim = wheel.xr - rim_width + 1;
    var y: i32 = 0;
    while (y < height) : (y += 1) {
        const yoff = colour.roundDiv((y - wheel.cy) * wheel.xr, wheel.yr);
        var x: i32 = 0;
        while (x < width) : (x += 1) {
            const xoff = x - wheel.cx;
            const d2: i64 = @as(i64, xoff) * xoff + @as(i64, yoff) * yoff;
            var pen = ground;
            // The rounded distance, so the edge has no corners standing
            // out of it where it crosses the axes.
            const d: i32 = @intCast(colour.roundSqrt(@intCast(@min(d2, 0x3FFFFFFF))));
            if (d <= wheel.xr) {
                if (d >= rim) {
                    pen = shadow;
                } else {
                    const hs = colour.hueSatAt(xoff, y - wheel.cy, wheel.xr, wheel.yr);
                    pen = penOf(colour.hsbToRgb(.{ .hue = hs.hue, .saturation = hs.saturation, .brightness = 0xFFFF }));
                }
                if (disabled and (x + y) & 1 == 0) pen = shadow;
            }
            into[@intCast(y * width + x)] = pen;
        }
    }
}

/// The picture for the box as it is, worked out again when it is not.
/// Null without memory.
fn pictureFor(base: *gadgets.Base, own: *Data, b: gc.Box, pens: [*]const Pen, disabled: bool) ?[*]Pen {
    if (own.picture) |picture| {
        if (own.picture_width == b.width and own.picture_height == b.height and (own.picture_disabled != 0) == disabled) return picture;
        base.sys_base.FreeVec(picture);
        own.picture = null;
    }
    if (b.width <= 0 or b.height <= 0) return null;
    const bytes: usize = @intCast(@as(i64, b.width) * b.height * @sizeOf(Pen));
    const block = base.sys_base.AllocVec(bytes, exec.MEMF_ANY) orelse return null;
    const picture: [*]Pen = @ptrCast(@alignCast(block));
    paint(picture, b.width, b.height, wheelOf(own, b), pens, disabled);
    own.picture = picture;
    own.picture_width = b.width;
    own.picture_height = b.height;
    own.picture_disabled = @intFromBool(disabled);
    return picture;
}

/// Part of the picture put down: `area` from the box's corner, at the box
/// `b` in the window.
fn putPicture(base: *gadgets.Base, rp: *graphics.RastPort, picture: [*]Pen, b: gc.Box, area: gc.Box) void {
    const left = @max(area.left, 0);
    const top = @max(area.top, 0);
    const right = @min(area.left + area.width, b.width);
    const bottom = @min(area.top + area.height, b.height);
    if (right <= left or bottom <= top) return;
    base.graphics_base.WritePixelArray(
        rp,
        @ptrCast(picture),
        @intCast(b.width * @sizeOf(Pen)),
        @intFromEnum(sdk.rtg.bitmaps.PixelFormat.bgra32),
        left,
        top,
        &.{ .min_x = b.left + left, .min_y = b.top + top, .max_x = b.left + right, .max_y = b.top + bottom },
    );
}

/// A filled disc, a span of a row at a time.
fn disc(gb: *sdk.interface.graphics.GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32, radius: i32, pen: Pen) void {
    support.setPen(gb, rp, pen);
    var dy: i32 = -radius;
    while (dy <= radius) : (dy += 1) {
        const half: i32 = @intCast(colour.roundSqrt(@intCast(radius * radius - dy * dy)));
        gb.RectFill(rp, &.{ .min_x = x - half, .min_y = y + dy, .max_x = x + half + 1, .max_y = y + dy + 1 });
    }
}

/// The dot, taken away from where it was and drawn where the colour puts
/// it.
fn moveDot(base: *gadgets.Base, own: *Data, rp: *graphics.RastPort, b: gc.Box, pens: [*]const Pen) void {
    const gb = base.graphics_base;
    const picture = own.picture orelse return;
    const at = wheelOf(own, b).dot(own.hue, own.saturation);
    if (own.dot_shown != 0) {
        if (own.dot_x == at.x and own.dot_y == at.y) return;
        const span = 2 * dot_radius + 1;
        putPicture(base, rp, picture, b, .{ .left = own.dot_x - dot_radius, .top = own.dot_y - dot_radius, .width = span, .height = span });
    }
    disc(gb, rp, b.left + at.x, b.top + at.y, dot_radius, pens[sc.SHADOWPEN]);
    disc(gb, rp, b.left + at.x, b.top + at.y, dot_radius - 2, pens[sc.SHINEPEN]);
    own.dot_x = at.x;
    own.dot_y = at.y;
    own.dot_shown = 1;
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const gb = base.graphics_base;
    const own = classes.instData(Data, cl, o);
    const g = gc.gadget(o);
    const b = gc.boxFor(g, info);
    const styled = support.pensFor(base.intuition_base, info.draw_info, g.style, sdk.intuition.style.PART_MAIN, null);
    const pens: [*]const graphics.Pen = &styled;
    const disabled = g.flags & gc.GFLG_DISABLED != 0;
    const saved = support.Saved.of(gb, r.rast_port);
    defer saved.restore(gb, r.rast_port);
    const picture = pictureFor(base, own, b, pens, disabled) orelse return;
    if (r.redraw == gc.GREDRAW_UPDATE and own.dot_shown != 0 and !disabled) {
        moveDot(base, own, r.rast_port, b, pens);
        return;
    }
    // The bevel first - it fills what it frames - and the picture inside
    // it.
    var inside = gc.Box{ .width = b.width, .height = b.height };
    if (own.frame) |frame| {
        support.drawFrame(base.intuition_base, frame, r.rast_port, b, ic.IDS_NORMAL, info.draw_info, gc.gadget(o).style);
        const inset = support.frameInset(base.intuition_base, frame, info.draw_info);
        inside = .{ .left = inset.left, .top = inset.top, .width = b.width - inset.width, .height = b.height - inset.height };
    }
    putPicture(base, r.rast_port, picture, b, inside);
    own.dot_shown = 0;
    if (own.frame != null and disabled) support.ghost(gb, r.rast_port, b, info.block_pen);
    if (!disabled) moveDot(base, own, r.rast_port, b, pens);
}

/// Drawn again, if it is in a window: all of it, or only the dot.
fn redraw(base: *gadgets.Base, o: *Object, gi: ?*classusr.GadgetInfo, how: u32) void {
    const ib = base.intuition_base;
    const rp = ib.ObtainGIRPort(gi) orelse return;
    defer ib.ReleaseGIRPort(rp);
    var msg = gc.GpRender{ .gadget_info = gi, .rast_port = rp, .redraw = how };
    _ = ib.SendMessage(o, @ptrCast(&msg));
}

// --- attributes ------------------------------------------------------------------

/// The colour's attributes among `tags`, and `WHEEL_BevelBox` when the
/// gadget is made. Answers whether the hue or saturation changed - what
/// the dot shows.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem, new: bool, gi: ?*classusr.GadgetInfo) bool {
    const ub = base.utility_base;
    const was_brightness = own.brightness;
    const was_hue = own.hue;
    const was_saturation = own.saturation;
    var rgb: colour.Rgb = .{};
    var red = false;
    var green = false;
    var blue = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        const value: u32 = @truncate(item.data);
        switch (item.tag) {
            cw.WHEEL_Hue => own.hue = colour.narrow(value),
            cw.WHEEL_Saturation => own.saturation = colour.narrow(value),
            cw.WHEEL_Brightness => own.brightness = colour.narrow(value),
            cw.WHEEL_HSB => if (item.data != 0) {
                const hsb: *const cw.ColorWheelHSB = @ptrFromInt(item.data);
                own.hue = colour.narrow(hsb.hue);
                own.saturation = colour.narrow(hsb.saturation);
                own.brightness = colour.narrow(hsb.brightness);
            },
            cw.WHEEL_Red => {
                rgb.red = colour.narrow(value);
                red = true;
            },
            cw.WHEEL_Green => {
                rgb.green = colour.narrow(value);
                green = true;
            },
            cw.WHEEL_Blue => {
                rgb.blue = colour.narrow(value);
                blue = true;
            },
            cw.WHEEL_RGB => if (item.data != 0) {
                const given: *const cw.ColorWheelRGB = @ptrFromInt(item.data);
                rgb = .{ .red = colour.narrow(given.red), .green = colour.narrow(given.green), .blue = colour.narrow(given.blue) };
                red = true;
                green = true;
                blue = true;
            },
            cw.WHEEL_BevelBox => if (new) {
                own.bevel = @intFromBool(item.data != 0);
            },
            cw.WHEEL_GradientSlider => own.gradient_slider = @ptrFromInt(item.data),
            else => {},
        }
    }
    // A component of red, green and blue given: the others as they are.
    if (red or green or blue) {
        var current = colour.hsbToRgb(.{ .hue = own.hue, .saturation = own.saturation, .brightness = own.brightness });
        if (red) current.red = rgb.red;
        if (green) current.green = rgb.green;
        if (blue) current.blue = rgb.blue;
        const hsb = colour.rgbToHsb(current);
        own.hue = hsb.hue;
        own.saturation = hsb.saturation;
        own.brightness = hsb.brightness;
    }
    // The slider follows the brightness: bright at its start.
    if (own.brightness != was_brightness or new) {
        if (own.gradient_slider) |slider| {
            const value = [_]TagItem{ .{ .tag = gs.GRAD_CurVal, .data = 0xFFFF - own.brightness }, .{} };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &value, .gadget_info = gi };
            _ = base.intuition_base.SendMessage(slider, @ptrCast(&set));
        }
    }
    return own.hue != was_hue or own.saturation != was_saturation;
}

/// The brightness as the slider has it, when there is one.
fn brightnessFromSlider(base: *gadgets.Base, own: *Data) void {
    const slider = own.gradient_slider orelse return;
    var value: usize = 0;
    if (base.intuition_base.GetAttr(gs.GRAD_CurVal, slider, &value) == 0) return;
    own.brightness = 0xFFFF - @min(@as(u32, @truncate(value)), 0xFFFF);
}

fn get(own: *const Data, msg: *classusr.OpGet) bool {
    const out = msg.storage;
    const rgb = colour.hsbToRgb(.{ .hue = own.hue, .saturation = own.saturation, .brightness = own.brightness });
    switch (msg.attr_id) {
        cw.WHEEL_Hue => out.* = colour.widen(own.hue),
        cw.WHEEL_Saturation => out.* = colour.widen(own.saturation),
        cw.WHEEL_Brightness => out.* = colour.widen(own.brightness),
        cw.WHEEL_HSB => {
            const hsb: *cw.ColorWheelHSB = @ptrCast(@alignCast(out));
            hsb.* = .{ .hue = colour.widen(own.hue), .saturation = colour.widen(own.saturation), .brightness = colour.widen(own.brightness) };
        },
        cw.WHEEL_Red => out.* = colour.widen(rgb.red),
        cw.WHEEL_Green => out.* = colour.widen(rgb.green),
        cw.WHEEL_Blue => out.* = colour.widen(rgb.blue),
        cw.WHEEL_RGB => {
            const into: *cw.ColorWheelRGB = @ptrCast(@alignCast(out));
            into.* = .{ .red = colour.widen(rgb.red), .green = colour.widen(rgb.green), .blue = colour.widen(rgb.blue) };
        },
        else => return false,
    }
    return true;
}

// --- input -------------------------------------------------------------------------

/// The hue and saturation under the pointer, and the dot moved there.
fn track(base: *gadgets.Base, own: *Data, o: *Object, in: *gc.GpInput) void {
    const b = gc.boxFor(gc.gadget(o), in.gadget_info);
    const wheel = wheelOf(own, b);
    const hs = colour.hueSatAt(in.mouse.x - wheel.cx, in.mouse.y - wheel.cy, wheel.xr, wheel.yr);
    own.hue = hs.hue;
    own.saturation = hs.saturation;
    redraw(base, o, in.gadget_info, gc.GREDRAW_UPDATE);
}

/// The target told the hue and saturation.
fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo, flags: u32) void {
    const tags = [_]TagItem{
        .{ .tag = cw.WHEEL_Hue, .data = colour.widen(own.hue) },
        .{ .tag = cw.WHEEL_Saturation, .data = colour.widen(own.saturation) },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, flags);
}

fn handle(base: *gadgets.Base, own: *Data, o: *Object, in: *gc.GpInput) usize {
    const e = in.event orelse return gc.GMR_MEACTIVE;
    if (e.class != ie.IECLASS_NEWPOINTERPOS) return gc.GMR_MEACTIVE;
    const was_hue = own.hue;
    const was_saturation = own.saturation;
    var result: usize = gc.GMR_MEACTIVE;
    if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
        result = gc.GMR_NOREUSE | gc.GMR_VERIFY;
    } else if (e.code == ie.IECODE_RBUTTON) {
        // The menu button: back as it was.
        own.hue = own.saved_hue;
        own.saturation = own.saved_saturation;
        redraw(base, o, in.gadget_info, gc.GREDRAW_UPDATE);
        result = gc.GMR_NOREUSE | gc.GMR_VERIFY;
    } else {
        track(base, own, o, in);
    }
    if (result != gc.GMR_MEACTIVE or own.hue != was_hue or own.saturation != was_saturation) {
        tell(base, own, o, in.gadget_info, if (result != gc.GMR_MEACTIVE) 0 else classusr.OPUF_INTERIM);
    }
    return result;
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
            _ = setAttrs(base, own, new.attr_list, true, null);
            if (own.bevel != 0) {
                const frame_tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
                own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags) orelse {
                    var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                    _ = ib.SendSuperMessage(cl, obj, &gone);
                    return 0;
                };
            }
            const ub = base.utility_base;
            own.sized = @intFromBool(ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null);
            const tags = [_]TagItem{
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = if (own.sized != 0) utility.TAG_DONE else gc.GA_Width, .data = nominal_size },
                .{ .tag = gc.GA_Height, .data = nominal_size },
                .{},
            };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
            _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            if (own.picture) |picture| base.sys_base.FreeVec(picture);
            ib.DisposeObject(own.frame);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const changed = ib.SendSuperMessage(cl, o, msg);
            const moved = setAttrs(base, classes.instData(Data, cl, o.?), set.attr_list, false, set.gadget_info);
            if (classes.objectClass(o.?) == cl and set.gadget_info != null) {
                // The gadget's own attributes - being disabled - redraw it
                // all; a new colour only the dot.
                if (changed != 0) {
                    redraw(base, o.?, set.gadget_info, gc.GREDRAW_REDRAW);
                } else if (moved) {
                    redraw(base, o.?, set.gadget_info, gc.GREDRAW_UPDATE);
                }
                return 0;
            }
            return changed | @intFromBool(moved);
        },
        classusr.OM_GET => {
            const msg_get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            brightnessFromSlider(base, own);
            if (get(own, msg_get)) return 1;
            return ib.SendSuperMessage(cl, o, msg);
        },
        // Square at the least and as it looks right, as big as there is
        // room at the most.
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const g = gc.gadget(o.?);
            ask.domain = switch (ask.which) {
                gc.GDOMAIN_MINIMUM => .{ .width = least_size, .height = least_size },
                gc.GDOMAIN_NOMINAL => if (own.sized != 0) .{ .width = g.given_width, .height = g.given_height } else .{ .width = nominal_size, .height = nominal_size },
                else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = gc.GDOMAIN_UNLIMITED },
            };
            return 1;
        },
        gc.GM_HITTEST, gc.GM_HELPTEST => {
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const b = gc.boxFor(gc.gadget(o.?), ht.gadget_info);
            const hit = if (own.bevel != 0) support.inside(ht.mouse.x, ht.mouse.y, b.width, b.height) else wheelOf(own, b).contains(ht.mouse.x, ht.mouse.y);
            if (msg.method_id == gc.GM_HELPTEST) return if (hit) gc.GMR_HELPHIT else gc.GMR_NOHELPHIT;
            return if (hit) gc.GMR_GADGETHIT else 0;
        },
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        // The colour kept as it was, and the dot moved to the press.
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            if (in.event == null) return gc.GMR_NOREUSE;
            const own = classes.instData(Data, cl, o.?);
            own.saved_hue = own.hue;
            own.saved_saturation = own.saturation;
            gc.gadget(o.?).flags |= gc.GFLG_SELECTED;
            // The press itself: the dot goes where it landed.
            track(base, own, o.?, in);
            if (own.hue != own.saved_hue or own.saturation != own.saved_saturation) tell(base, own, o.?, in.gadget_info, classusr.OPUF_INTERIM);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => return handle(base, classes.instData(Data, cl, o.?), o.?, @ptrCast(@alignCast(msg))),
        gc.GM_GOINACTIVE => {
            gc.gadget(o.?).flags &= ~gc.GFLG_SELECTED;
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
