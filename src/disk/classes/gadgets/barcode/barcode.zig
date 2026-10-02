// SPDX-License-Identifier: MIT
//! barcode.gadget: a text drawn as Code 128 or EAN-13.
//!
//! The encoders are `_barcode.zig`'s. The modules are worked out when the
//! text or the type is set and kept, a byte each, in the object; the text
//! is copied, so the program's need not stay. `GM_RENDER` fills the box
//! with the background and puts each run of bar modules down as one
//! rectangle, the text centred in a line under them.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const style = intuition.style;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const bc = gadgets.barcode;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;

/// The encoders.
pub const encoder = @import("_barcode.zig");

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = bc.BARCODE_CLASS,
    .version = 1,
    .date = "02.10.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// barcode.gadget's part of an object.
pub const Data = extern struct {
    kind: u32 = bc.BARCODE_CODE128,
    show_text: u32 = 1,
    /// The modules, a byte each; 0 of them for none.
    count: u32 = 0,
    modules: [encoder.max_modules]u8 = @splat(0),
    /// The text written under the bars.
    text: [encoder.max_text + 1]u8 = @splat(0),
};

/// Quiet zones, in modules: either side of Code 128, and EAN-13's left
/// and right.
const quiet_code128 = 10;
const quiet_ean_left = 11;
const quiet_ean_right = 7;
const nominal_height = 48;

fn quietLeft(own: *const Data) u32 {
    return if (own.kind == bc.BARCODE_EAN13) quiet_ean_left else quiet_code128;
}

fn quietRight(own: *const Data) u32 {
    return if (own.kind == bc.BARCODE_EAN13) quiet_ean_right else quiet_code128;
}

/// The modules worked out from `text` as the type.
fn encode(own: *Data, text: ?[*:0]const u8) void {
    own.count = 0;
    own.text[0] = 0;
    const given = text orelse return;
    const bytes = given[0..support.textLen(given)];
    if (own.kind == bc.BARCODE_EAN13) {
        var full: [13]u8 = undefined;
        const n = encoder.ean13Modules(bytes, &own.modules, &full) orelse return;
        own.count = @intCast(n);
        @memcpy(own.text[0..13], &full);
        own.text[13] = 0;
    } else {
        const n = encoder.code128Modules(bytes, &own.modules) orelse return;
        own.count = @intCast(n);
        @memcpy(own.text[0..bytes.len], bytes);
        own.text[bytes.len] = 0;
    }
}

fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem) bool {
    var changed = false;
    var state = tags;
    while (base.utility_base.NextTagItem(&state)) |item| {
        switch (item.tag) {
            bc.BARCODE_Type => own.kind = if (item.data == bc.BARCODE_EAN13) bc.BARCODE_EAN13 else bc.BARCODE_CODE128,
            bc.BARCODE_Text => encode(own, @ptrFromInt(item.data)),
            bc.BARCODE_ShowText => own.show_text = @intFromBool(item.data != 0),
            else => continue,
        }
        changed = true;
    }
    return changed;
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const rp = r.rast_port;
    const own = classes.instData(Data, cl, o);
    const g = gc.gadget(o);
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);
    const b = gc.boxFor(g, info);
    const ground = support.background(ib, info.draw_info, g.style, style.PART_MAIN);
    const ink: Pen = @truncate(ib.GetStyleAttr(info.draw_info, g.style, style.PART_MAIN, style.STATE_NORMAL, style.STYLE_TextPen));
    support.fill(gb, rp, b, ground);
    if (own.count == 0) return;

    var line: u32 = 0;
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&line) }, .{} });
    const text_room: i32 = if (own.show_text != 0) @as(i32, @intCast(line)) + 2 else 0;
    const total: i32 = @intCast(own.count + quietLeft(own) + quietRight(own));
    const module = @divTrunc(b.width, total);
    if (module < 1 or b.height <= text_room) return;
    const left = b.left + @divTrunc(b.width - module * total, 2) + @as(i32, @intCast(quietLeft(own))) * module;
    const bars_bottom = b.top + b.height - text_room;

    support.setPen(gb, rp, ink);
    var i: u32 = 0;
    while (i < own.count) {
        if (own.modules[i] == 0) {
            i += 1;
            continue;
        }
        const from = i;
        while (i < own.count and own.modules[i] != 0) i += 1;
        gb.RectFill(rp, &.{
            .min_x = left + @as(i32, @intCast(from)) * module,
            .min_y = b.top,
            .max_x = left + @as(i32, @intCast(i)) * module,
            .max_y = bars_bottom,
        });
    }
    if (own.show_text != 0) {
        const text: [*:0]const u8 = @ptrCast(&own.text);
        const width = gb.TextLength(rp, text, support.textLen(text));
        support.drawText(gb, rp, b.left + @divTrunc(b.width - width, 2), bars_bottom + 2, text, ink);
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
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
            const ub = base.utility_base;
            if (ub.FindTagItem(gc.GA_Width, new.attr_list) == null and ub.FindTagItem(gc.GA_Height, new.attr_list) == null) {
                var size: gc.GpDomain = .{ .which = gc.GDOMAIN_NOMINAL };
                _ = ib.SendMessage(obj, @ptrCast(&size));
                const tags = [_]TagItem{
                    .{ .tag = gc.GA_Width, .data = @intCast(size.domain.width) },
                    .{ .tag = gc.GA_Height, .data = @intCast(size.domain.height) },
                    .{},
                };
                var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
                _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            }
            return made;
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(base, classes.instData(Data, cl, o.?), set.attr_list)) changed = 1;
            if (changed != 0 and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                support.redraw(ib, o.?, set.gadget_info);
                return 0;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            switch (get.attr_id) {
                bc.BARCODE_Valid => get.storage.* = @intFromBool(own.count != 0),
                bc.BARCODE_Type => get.storage.* = own.kind,
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const modules: i32 = @intCast(@max(own.count, 40) + quietLeft(own) + quietRight(own));
            ask.domain = switch (ask.which) {
                gc.GDOMAIN_MINIMUM => .{ .width = modules, .height = 24 },
                gc.GDOMAIN_NOMINAL => .{ .width = 2 * modules, .height = nominal_height },
                else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = gc.GDOMAIN_UNLIMITED },
            };
            return 1;
        },
        // Never pressed: a press goes through it to the window.
        gc.GM_HITTEST => return 0,
        gc.GM_GOACTIVE => return gc.GMR_NOREUSE,
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
