// SPDX-License-Identifier: MIT
//! qrcode.gadget: a text drawn as a QR code.
//!
//! The encoding is `_qr.zig`'s. When the text or the level is set, a work
//! buffer for the version is allocated, the symbol built in it, and its
//! modules kept as bits, a row after another, in a block of their own; the
//! work buffer goes again at once. `GM_RENDER` fills the box with the
//! light colour and puts each row's runs of dark modules down as single
//! rectangles.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const exec = sdk.exec;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const style = intuition.style;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const qc = gadgets.qrcode;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;

/// The encoder.
pub const encoder = @import("_qr.zig");

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = qc.QR_CLASS,
    .version = 1,
    .date = "02.10.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// qrcode.gadget's part of an object.
pub const Data = extern struct {
    level: u32 = qc.QR_LEVEL_M,
    version: u32 = 0,
    /// Modules a side, and the modules: a bit each, row after row.
    size: u32 = 0,
    modules: ?[*]u8 = null,
};

/// The quiet zone, in modules.
const quiet = 4;
const nominal_size = 116;
const least_size = 29;

/// Whether the module at (`x`, `y`) is dark.
pub fn darkAt(own: *const Data, x: u32, y: u32) bool {
    const modules = own.modules orelse return false;
    const i = y * own.size + x;
    return (modules[i >> 3] >> @intCast(i & 7)) & 1 != 0;
}

/// The code let go.
fn forget(base: *gadgets.Base, own: *Data) void {
    if (own.modules) |modules| base.sys_base.FreeVec(modules);
    own.modules = null;
    own.size = 0;
    own.version = 0;
}

/// `text` encoded and kept; nothing kept when it does not fit or there is
/// no memory.
fn encode(base: *gadgets.Base, own: *Data, text: ?[*:0]const u8) void {
    forget(base, own);
    const given = text orelse return;
    const bytes = given[0..support.textLen(given)];
    const level: encoder.Level = @enumFromInt(own.level);
    const version = encoder.versionFor(bytes.len, level) orelse return;
    const sys = base.sys_base;
    const work_size = encoder.workSize(version);
    const work: [*]u8 = @ptrCast(sys.AllocVec(@intCast(work_size), exec.MEMF_ANY) orelse return);
    defer sys.FreeVec(work);
    const symbol = encoder.encode(bytes, level, version, work[0..work_size]);
    const count = symbol.size * symbol.size;
    const modules: [*]u8 = @ptrCast(sys.AllocVec((count + 7) / 8, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return);
    for (0..symbol.size) |yi| {
        for (0..symbol.size) |xi| {
            const x: u32 = @intCast(xi);
            const y: u32 = @intCast(yi);
            if (!symbol.dark(x, y)) continue;
            const i = y * symbol.size + x;
            modules[i >> 3] |= @as(u8, 1) << @intCast(i & 7);
        }
    }
    own.modules = modules;
    own.size = symbol.size;
    own.version = version;
}

fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem) bool {
    var changed = false;
    var state = tags;
    while (base.utility_base.NextTagItem(&state)) |item| {
        switch (item.tag) {
            qc.QR_Level => own.level = @as(u32, @truncate(item.data)) & 3,
            qc.QR_Text => encode(base, own, @ptrFromInt(item.data)),
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
    const light = support.background(ib, info.draw_info, g.style, style.PART_MAIN);
    const dark: Pen = @truncate(ib.GetStyleAttr(info.draw_info, g.style, style.PART_MAIN, style.STATE_NORMAL, style.STYLE_TextPen));
    support.fill(gb, rp, b, light);
    if (own.modules == null) return;
    const side: i32 = @intCast(own.size + 2 * quiet);
    const module = @divTrunc(@min(b.width, b.height), side);
    if (module < 1) return;
    const left = b.left + @divTrunc(b.width - module * side, 2) + quiet * module;
    const top = b.top + @divTrunc(b.height - module * side, 2) + quiet * module;
    support.setPen(gb, rp, dark);
    for (0..own.size) |yi| {
        const y: u32 = @intCast(yi);
        var x: u32 = 0;
        while (x < own.size) {
            if (!darkAt(own, x, y)) {
                x += 1;
                continue;
            }
            const from = x;
            while (x < own.size and darkAt(own, x, y)) x += 1;
            const row_top = top + @as(i32, @intCast(y)) * module;
            gb.RectFill(rp, &.{
                .min_x = left + @as(i32, @intCast(from)) * module,
                .min_y = row_top,
                .max_x = left + @as(i32, @intCast(x)) * module,
                .max_y = row_top + module,
            });
        }
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
                const tags = [_]TagItem{
                    .{ .tag = gc.GA_Width, .data = nominal_size },
                    .{ .tag = gc.GA_Height, .data = nominal_size },
                    .{},
                };
                var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
                _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            }
            return made;
        },
        classusr.OM_DISPOSE => {
            forget(base, classes.instData(Data, cl, o orelse return 0));
            return ib.SendSuperMessage(cl, o, msg);
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
                qc.QR_Version => get.storage.* = own.version,
                qc.QR_Level => get.storage.* = own.level,
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            // A pixel a module at the least; four at its natural size.
            const modules: i32 = if (own.size > 0) @intCast(own.size + 2 * quiet) else least_size;
            const side: i32 = switch (ask.which) {
                gc.GDOMAIN_MINIMUM => modules,
                gc.GDOMAIN_NOMINAL => @max(4 * modules, nominal_size),
                else => gc.GDOMAIN_UNLIMITED,
            };
            ask.domain = .{ .width = side, .height = side };
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
