// SPDX-License-Identifier: MIT
//! keyboard.gadget: keys on the screen, written to input.device.
//!
//! **The layout** is a table of rows, each key a raw key code and a width
//! in quarters of a key; every row is 54 quarters wide, so a quarter is a
//! 54th of the box and a row a fifth of it. A key's label is what
//! keymap.library's `MapRawKey` answers for its code with the page's and
//! Shift's qualifiers; the keys that are not characters - Shift, the page,
//! backspace, return, the cursor keys - have labels of their own.
//!
//! **A press** finds the key under the pointer. Shift and the page key
//! turn over and are done. Any other key is written down and up through
//! input.device (`IND_WRITEEVENT`, the request this gadget opened, a port
//! of the caller's own on the stack as intuition does), drawn pressed and
//! shown again above itself, and held: each tick of input.device after
//! the third writes it again. Letting go draws it as it was; a Shift used
//! for one key lets go with it.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const exec = sdk.exec;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const style = intuition.style;
const ie = sdk.devices.inputevent;
const input = sdk.devices.input;
const keymap = sdk.keymap;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const kb = gadgets.keyboard;
const KeymapBase = sdk.interface.keymap.KeymapBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = kb.KEYBOARD_CLASS,
    .version = 1,
    .date = "02.10.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

pub const Kind = enum(u8) { char, shift, page, back, enter, space, left, right, gap };

pub const Key = struct { code: u8 = 0, quarters: u8 = 4, kind: Kind = .char };

fn chars(comptime from: u8, comptime to: u8) [to - from + 1]Key {
    var made: [to - from + 1]Key = undefined;
    for (&made, 0..) |*k, i| k.* = .{ .code = from + i };
    return made;
}

/// The rows, each 54 quarters wide.
pub const rows = [_][]const Key{
    &(chars(0x01, 0x0C) ++ [_]Key{.{ .code = 0x41, .quarters = 6, .kind = .back }}),
    &([_]Key{.{ .quarters = 2, .kind = .gap }} ++ chars(0x10, 0x1B) ++ [_]Key{.{ .quarters = 4, .kind = .gap }}),
    &(chars(0x20, 0x2B) ++ [_]Key{.{ .code = 0x44, .quarters = 6, .kind = .enter }}),
    &([_]Key{.{ .code = 0x60, .quarters = 6, .kind = .shift }} ++ chars(0x30, 0x3A) ++ [_]Key{.{ .code = 0x60, .quarters = 4, .kind = .shift }}),
    &[_]Key{
        .{ .quarters = 8, .kind = .page },
        .{ .code = 0x40, .quarters = 34, .kind = .space },
        .{ .code = 0x4F, .quarters = 6, .kind = .left },
        .{ .code = 0x4E, .quarters = 6, .kind = .right },
    },
};
const row_quarters = 54;
const row_count: i32 = rows.len;
/// A key held writes itself again from this tick on.
const repeat_after = 3;

/// keyboard.gadget's part of an object.
pub const Data = extern struct {
    shift: u8 = 0,
    symbols: u8 = 0,
    /// The key held, as its row and place; 0xFF for none.
    held_row: u8 = 0xFF,
    held_at: u8 = 0,
    ticks: u32 = 0,
    keymap_base: ?*KeymapBase = null,
    /// input.device, opened with the gadget: where the keys are written.
    io: exec.IOStdReq = .{},
    io_open: u32 = 0,
};

/// Where key `at` of row `row` is in a box of `w` by `h`, as its left,
/// top, width and height.
pub fn keyBox(w: i32, h: i32, row: usize, at: usize) gc.Box {
    var quarters: i32 = 0;
    for (rows[row][0..at]) |k| quarters += k.quarters;
    const left = @divTrunc(quarters * w, row_quarters);
    const right = @divTrunc((quarters + rows[row][at].quarters) * w, row_quarters);
    const top = @divTrunc(@as(i32, @intCast(row)) * h, row_count);
    const bottom = @divTrunc(@as(i32, @intCast(row + 1)) * h, row_count);
    return .{ .left = left, .top = top, .width = right - left, .height = bottom - top };
}

/// The key at (`x`, `y`) in a box of `w` by `h`, as row and place.
pub fn keyAt(w: i32, h: i32, x: i32, y: i32) ?[2]usize {
    if (x < 0 or y < 0 or x >= w or y >= h) return null;
    const row: usize = @intCast(@divTrunc(y * row_count, h));
    for (rows[row], 0..) |k, at| {
        const b = keyBox(w, h, row, at);
        if (x >= b.left and x < b.left + b.width) return if (k.kind == .gap) null else .{ row, at };
    }
    return null;
}

/// The qualifier the keys are written and labelled with.
fn qualifierOf(own: *const Data) u32 {
    var q: u32 = 0;
    if (own.shift != 0) q |= ie.IEQUALIFIER_LSHIFT;
    if (own.symbols != 0) q |= ie.IEQUALIFIER_LALT;
    return q;
}

/// A key's label, into `into`.
fn labelOf(own: *const Data, k: Key, into: *[8]u8) [*:0]const u8 {
    switch (k.kind) {
        .shift => return "Shift",
        .page => return if (own.symbols != 0) "abc" else "!#$",
        .back => return "<-",
        .enter => return "Return",
        .space, .gap => return "",
        .left => return "<",
        .right => return ">",
        .char => {},
    }
    const map = own.keymap_base orelse return "";
    const e = ie.InputEvent{ .class = ie.IECLASS_RAWKEY, .code = k.code, .qualifier = qualifierOf(own) };
    const n = map.MapRawKey(&e, into, 7, null);
    if (n <= 0) return "";
    into[@intCast(n)] = 0;
    return @ptrCast(into);
}

/// A key written down and up through input.device.
fn write(base: *gadgets.Base, own: *Data, k: Key) void {
    if (own.io_open == 0) return;
    const sys = base.sys_base;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return;
    defer sys.FreeSignal(signal);
    var port: exec.MsgPort = .{ .flags = exec.PA_SIGNAL, .sig_bit = @intCast(signal), .sig_task = sys.FindTask(null) };
    port.msg_list.init(.message);
    for ([_]u32{ 0, ie.IECODE_UP_PREFIX }) |up| {
        var e = ie.InputEvent{ .class = ie.IECLASS_RAWKEY, .code = k.code | up, .qualifier = qualifierOf(own) };
        var io = own.io;
        io.req.message.reply_port = &port;
        io.req.message.length = @sizeOf(exec.IOStdReq);
        io.req.command = input.IND_WRITEEVENT;
        io.data = &e;
        io.length = @sizeOf(ie.InputEvent);
        _ = sys.DoIO(&io.req);
    }
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
    const dri = info.draw_info;
    support.fill(gb, rp, b, support.background(ib, dri, g.style, style.PART_MAIN));
    var line_u: u32 = 0;
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&line_u) }, .{} });
    const line: i32 = @intCast(line_u);

    var held: ?gc.Box = null;
    // The held key's label, kept apart: `labels` is every key's in turn.
    var held_label: [8]u8 = @splat(0);
    var labels: [8]u8 = undefined;
    for (rows, 0..) |row, ri| {
        for (row, 0..) |k, at| {
            if (k.kind == .gap) continue;
            const kb_ = keyBox(b.width, b.height, ri, at);
            const box = graphics.Rect{ .min_x = b.left + kb_.left + 1, .min_y = b.top + kb_.top + 1, .max_x = b.left + kb_.left + kb_.width - 1, .max_y = b.top + kb_.top + kb_.height - 1 };
            const is_held = own.held_row == ri and own.held_at == at;
            const checked = (k.kind == .shift and own.shift != 0) or (k.kind == .page and own.symbols != 0);
            const state: u32 = if (is_held) style.STATE_PRESSED else if (checked) style.STATE_CHECKED else style.STATE_NORMAL;
            ib.DrawPart(rp, dri, g.style, style.PART_MAIN, state, 0, &box, null);
            const label = labelOf(own, k, &labels);
            const ink: Pen = @truncate(ib.GetStyleAttr(dri, g.style, style.PART_MAIN, state, style.STYLE_TextPen));
            const w = gb.TextLength(rp, label, support.textLen(label));
            support.drawText(gb, rp, box.min_x + @divTrunc(box.width() - w, 2), box.min_y + @divTrunc(box.height() - line, 2), label, ink);
            if (is_held and k.kind == .char) {
                held = .{ .left = box.min_x, .top = box.min_y, .width = box.width(), .height = box.height() };
                const n = @min(support.textLen(label), held_label.len - 1);
                @memcpy(held_label[0..n], label[0..n]);
                held_label[n] = 0;
            }
        }
    }
    // The key held, again and larger above itself, inside the box.
    if (held) |k| {
        const grow = @divTrunc(k.width, 3);
        const pop = graphics.Rect{
            .min_x = @max(b.left, k.left - grow),
            .min_y = @max(b.top, k.top - k.height - grow),
            .max_x = @min(b.left + b.width, k.left + k.width + grow),
            .max_y = @max(b.top, k.top - k.height - grow) + k.height + grow,
        };
        ib.DrawPart(rp, dri, g.style, style.PART_MAIN, style.STATE_NORMAL, 0, &pop, null);
        const ink: Pen = @truncate(ib.GetStyleAttr(dri, g.style, style.PART_MAIN, style.STATE_NORMAL, style.STYLE_TextPen));
        _ = gb.SetSoftStyle(rp, graphics.FSF_BOLD, 0xFF);
        const text: [*:0]const u8 = @ptrCast(&held_label);
        const w = gb.TextLength(rp, text, support.textLen(text));
        support.drawText(gb, rp, pop.min_x + @divTrunc(pop.width() - w, 2), pop.min_y + @divTrunc(pop.height() - line, 2), text, ink);
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

fn press(base: *gadgets.Base, own: *Data, o: *Object, in: *gc.GpInput) usize {
    const b = gc.boxFor(gc.gadget(o), in.gadget_info);
    const found = keyAt(b.width, b.height, in.mouse.x, in.mouse.y) orelse return gc.GMR_NOREUSE;
    const k = rows[found[0]][found[1]];
    switch (k.kind) {
        .shift => {
            own.shift ^= 1;
            support.redraw(base.intuition_base, o, in.gadget_info);
            return gc.GMR_NOREUSE;
        },
        .page => {
            own.symbols ^= 1;
            support.redraw(base.intuition_base, o, in.gadget_info);
            return gc.GMR_NOREUSE;
        },
        else => {},
    }
    write(base, own, k);
    own.held_row = @intCast(found[0]);
    own.held_at = @intCast(found[1]);
    own.ticks = 0;
    support.redraw(base.intuition_base, o, in.gadget_info);
    return gc.GMR_MEACTIVE;
}

fn handle(base: *gadgets.Base, own: *Data, o: *Object, in: *gc.GpInput) usize {
    const e = in.event orelse return gc.GMR_MEACTIVE;
    if (own.held_row == 0xFF) return gc.GMR_NOREUSE;
    const k = rows[own.held_row][own.held_at];
    if (e.class == ie.IECLASS_TIMER) {
        own.ticks += 1;
        if (own.ticks >= repeat_after) write(base, own, k);
        return gc.GMR_MEACTIVE;
    }
    if (e.class == ie.IECLASS_NEWPOINTERPOS and e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
        own.held_row = 0xFF;
        // A Shift for one key lets go with it.
        if (k.kind == .char) own.shift = 0;
        support.redraw(base.intuition_base, o, in.gadget_info);
        return gc.GMR_NOREUSE;
    }
    return gc.GMR_MEACTIVE;
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
            const ub = base.utility_base;
            own.shift = @intFromBool(ub.GetTagData(kb.KEYBOARD_Shift, 0, new.attr_list) != 0);
            own.symbols = @intFromBool(ub.GetTagData(kb.KEYBOARD_Symbols, 0, new.attr_list) != 0);
            own.keymap_base = @ptrCast(base.sys_base.OpenLibrary(keymap.KEYMAPNAME, 0));
            // The request is only ever copied to write with: its own port is
            // never waited on, but input.device wants its length.
            own.io.req.message.length = @sizeOf(exec.IOStdReq);
            if (base.sys_base.OpenDevice(input.INPUTNAME, 0, &own.io.req, 0) == 0) own.io_open = 1;
            const sized = ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null or
                ub.FindTagItem(gc.GA_RelWidth, new.attr_list) != null or ub.FindTagItem(gc.GA_RelHeight, new.attr_list) != null;
            if (!sized) {
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
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            if (own.io_open != 0) base.sys_base.CloseDevice(&own.io.req);
            if (own.keymap_base) |map| base.sys_base.CloseLibrary(map.lib());
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            var changed = ib.SendSuperMessage(cl, o, msg);
            const own = classes.instData(Data, cl, o.?);
            var state = set.attr_list;
            while (base.utility_base.NextTagItem(&state)) |item| {
                switch (item.tag) {
                    kb.KEYBOARD_Shift => own.shift = @intFromBool(item.data != 0),
                    kb.KEYBOARD_Symbols => own.symbols = @intFromBool(item.data != 0),
                    else => continue,
                }
                changed = 1;
            }
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
                kb.KEYBOARD_Shift => get.storage.* = own.shift,
                kb.KEYBOARD_Symbols => get.storage.* = own.symbols,
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const measure = support.Measure.of(ib, gc.gadget(o.?), ask.gadget_info);
            defer measure.done(ib);
            const row_h = measure.lineHeight(base.graphics_base) + 12;
            const key_w = measure.width(ib, "MM") + 8;
            const count: i32 = rows.len;
            ask.domain = switch (ask.which) {
                gc.GDOMAIN_MINIMUM => .{ .width = 13 * (key_w - 4), .height = count * (row_h - 6) },
                gc.GDOMAIN_NOMINAL => .{ .width = 14 * key_w, .height = count * row_h },
                else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = count * row_h * 2 },
            };
            return 1;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            if (in.event == null) return gc.GMR_NOREUSE;
            return press(base, classes.instData(Data, cl, o.?), o.?, in);
        },
        gc.GM_HANDLEINPUT => return handle(base, classes.instData(Data, cl, o.?), o.?, @ptrCast(@alignCast(msg))),
        gc.GM_GOINACTIVE => {
            const own = classes.instData(Data, cl, o.?);
            if (own.held_row != 0xFF) {
                own.held_row = 0xFF;
                const away: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
                if (away.gadget_info) |gi| support.redraw(ib, o.?, gi);
            }
            return 0;
        },
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
