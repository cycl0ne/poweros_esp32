// SPDX-License-Identifier: MIT
//! What getfile.gadget and getfont.gadget both are: a field with a
//! button beside it, the button opening one of asl.library's requesters.
//!
//! It is here rather than beside either class because a module's root
//! directory is the only place it may import from, and the two classes
//! are separate programs. `ClassLibrary` is here for the same reason.
//!
//! The two differ only in which requester the button opens and how the
//! answer is written into the field, so the gadget itself is written
//! once and each class says which it is. They are separate libraries
//! because a program that asks for a file should not have to load the
//! font requester with it.
//!
//! **The requester is opened on a process of its own.** The press that
//! asks for it arrives on the input handler, which may neither draw nor
//! wait, and a requester does both for as long as somebody looks at it.
//! The process holds a lock while it runs and `OM_DISPOSE` takes that
//! lock before letting anything go, so an object is not disposed of out
//! from under a requester. The lock is taken by the process itself,
//! because a semaphore is released by the task that took it and the
//! press was taken on the input handler.
//!
//! The field is a `string.gadget` in no window's list: this gadget
//! places it before every message it hands on, exactly as
//! integer.gadget does with its own. Its `ICA_TARGET` is this gadget,
//! which reads what was typed when the field is done with.
//!
//! What the program hears is an `OM_NOTIFY` on this gadget's own target,
//! carrying the attributes that changed and the gadget's `GA_ID`, so a
//! gadget whose target is `ICTARGET_IDCMP` tells its window.

const exec = @import("../exec/exec.zig");
const dos = @import("../dos/dos.zig");
const utility = @import("../utility/utility.zig");
const graphics = @import("../graphics/graphics.zig");
const classes = @import("../intuition/classes.zig");
const classusr = @import("../intuition/classusr.zig");
const gc = @import("../intuition/gadgetclass.zig");
const ic = @import("../intuition/imageclass.zig");
const icc = @import("../intuition/icclass.zig");
const sc = @import("../intuition/screens.zig");
const ie = @import("../../devices/inputevent.zig");
const asl = @import("../asl/asl.zig");
const gadgets = @import("gadgets.zig");
const support = @import("support.zig");
const st = @import("string.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const DosBase = @import("../../interface/dos.zig").DosBase;
const AslBase = @import("../../interface/asl.zig").AslBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Base = @import("classlibrary.zig").Base;

/// Which requester the button opens.
pub const Kind = enum { file, font };

/// What a class of this shape says about itself.
pub const Spec = struct {
    /// The library's name, which is also the class's.
    name: [:0]const u8,
    kind: Kind,
    /// Where its attributes start.
    dummy: utility.Tag,
};

/// The attributes, at the same places in both classes.
pub fn titleText(comptime spec: Spec) utility.Tag {
    return spec.dummy + 0x01;
}
pub fn readOnly(comptime spec: Spec) utility.Tag {
    return spec.dummy + 0x02;
}
/// The drawer, or the font's name.
pub fn firstValue(comptime spec: Spec) utility.Tag {
    return spec.dummy + 0x03;
}
/// The file's own name, or the font's size.
pub fn secondValue(comptime spec: Spec) utility.Tag {
    return spec.dummy + 0x04;
}
/// The two joined, or the font's style.
pub fn thirdValue(comptime spec: Spec) utility.Tag {
    return spec.dummy + 0x05;
}
/// The pattern, or the font as a TextAttr.
pub fn fourthValue(comptime spec: Spec) utility.Tag {
    return spec.dummy + 0x06;
}
/// Save mode; a font gadget has none.
pub fn fifthValue(comptime spec: Spec) utility.Tag {
    return spec.dummy + 0x07;
}
/// Drawers only; a font gadget has none.
pub fn sixthValue(comptime spec: Spec) utility.Tag {
    return spec.dummy + 0x08;
}

/// How long a drawer and a file may be, and the two joined.
const drawer_room = 512;
const name_room = 256;
const shown_room = drawer_room + name_room + 2;

/// How wide the button is beside the field, in characters of the
/// screen's font, and what is drawn in it.
const button_text = "...";

/// The gadget's part of an object.
pub const Data = extern struct {
    /// The field, which is no window's.
    field: ?*Object = null,
    /// The button's frame.
    frame: ?*Object = null,
    /// What the requester is called, the caller's.
    title: ?[*:0]const u8 = null,
    /// The pattern the file requester shows, copied.
    pattern: [name_room]u8 = @splat(0),
    /// A file's drawer, or a font's name.
    drawer: [drawer_room]u8 = @splat(0),
    /// A file's own name.
    file: [name_room]u8 = @splat(0),
    /// The two joined, which is what the field shows.
    shown: [shown_room]u8 = @splat(0),
    /// A font's size and style, and the two together for a program to
    /// read.
    size: u16 = 8,
    style: u16 = 0,
    attr: graphics.TextAttr = .{ .name = "", .y_size = 8 },
    /// The button is held, and the pointer is still on it.
    held: u8 = 0,
    over: u8 = 0,
    read_only: u8 = 0,
    save_mode: u8 = 0,
    drawers_only: u8 = 0,
    asking: u8 = 0,
    pad: [2]u8 = @splat(0),
    /// Held while a requester is open, so that nothing disposes of the
    /// object while one is.
    lock: exec.SignalSemaphore = .{},
};

/// A string copied into a fixed room, ending in a NUL.
fn copyInto(into: []u8, from: ?[*:0]const u8) void {
    @memset(into, 0);
    const text = from orelse return;
    var i: usize = 0;
    while (text[i] != 0 and i + 1 < into.len) : (i += 1) into[i] = text[i];
    into[i] = 0;
}

fn asString(from: []const u8) [*:0]const u8 {
    return @ptrCast(from.ptr);
}

/// The drawer and the file joined the way dos joins them: a drawer that
/// ends in a colon or a slash takes the name straight after it.
fn joinPath(own: *Data) void {
    @memset(&own.shown, 0);
    var at: usize = 0;
    var i: usize = 0;
    while (own.drawer[i] != 0 and at + 1 < own.shown.len) : (i += 1) {
        own.shown[at] = own.drawer[i];
        at += 1;
    }
    if (at != 0 and own.shown[at - 1] != ':' and own.shown[at - 1] != '/' and at + 1 < own.shown.len) {
        own.shown[at] = '/';
        at += 1;
    }
    i = 0;
    while (own.file[i] != 0 and at + 1 < own.shown.len) : (i += 1) {
        own.shown[at] = own.file[i];
        at += 1;
    }
    own.shown[at] = 0;
}

/// A path typed into the field split back into a drawer and a name, at
/// the last colon or slash.
fn splitPath(own: *Data) void {
    var length: usize = 0;
    while (length < own.shown.len and own.shown[length] != 0) length += 1;
    var cut: usize = 0;
    var i: usize = 0;
    while (i < length) : (i += 1) {
        if (own.shown[i] == '/' or own.shown[i] == ':') cut = i + 1;
    }
    @memset(&own.drawer, 0);
    @memset(&own.file, 0);
    const drawer_len = @min(cut, own.drawer.len - 1);
    @memcpy(own.drawer[0..drawer_len], own.shown[0..drawer_len]);
    const name_len = @min(length - cut, own.file.len - 1);
    @memcpy(own.file[0..name_len], own.shown[cut..][0..name_len]);
}

/// A font's name and size as the field shows them.
fn joinFont(own: *Data) void {
    @memset(&own.shown, 0);
    var at: usize = 0;
    var i: usize = 0;
    while (own.drawer[i] != 0 and at + 1 < own.shown.len) : (i += 1) {
        own.shown[at] = own.drawer[i];
        at += 1;
    }
    if (at + 8 < own.shown.len) {
        own.shown[at] = ' ';
        at += 1;
        at += writeNumber(own.shown[at..], own.size);
    }
    own.shown[at] = 0;
    own.attr = .{ .name = asString(&own.drawer), .y_size = own.size, .style = @truncate(own.style) };
}

/// A name and a size typed into the field, split at the last space.
fn splitFont(own: *Data) void {
    var length: usize = 0;
    while (length < own.shown.len and own.shown[length] != 0) length += 1;
    var cut = length;
    while (cut > 0 and own.shown[cut - 1] != ' ') cut -= 1;
    var size: u32 = 0;
    var digits: usize = cut;
    while (digits < length and own.shown[digits] >= '0' and own.shown[digits] <= '9') : (digits += 1) {
        size = size * 10 + (own.shown[digits] - '0');
    }
    // A number at the end is the size; without one the whole of it is
    // the name.
    const name_end = if (size != 0 and digits == length and cut != 0) cut - 1 else length;
    @memset(&own.drawer, 0);
    const name_len = @min(name_end, own.drawer.len - 1);
    @memcpy(own.drawer[0..name_len], own.shown[0..name_len]);
    if (size != 0) own.size = @intCast(@min(size, 0xFFFF));
    own.attr = .{ .name = asString(&own.drawer), .y_size = own.size, .style = @truncate(own.style) };
}

/// A number written into `into`, without a NUL. How many characters it
/// took.
fn writeNumber(into: []u8, value: u32) usize {
    var digits: [8]u8 = undefined;
    var count: usize = 0;
    var left = value;
    while (true) {
        digits[count] = '0' + @as(u8, @truncate(left % 10));
        count += 1;
        left /= 10;
        if (left == 0 or count == digits.len) break;
    }
    const room = @min(count, into.len);
    for (0..room) |i| into[i] = digits[count - 1 - i];
    return room;
}

pub fn Library(comptime spec: Spec) type {
    return struct {
        const Self = @This();

        /// What the field shows, told to it.
        fn showText(base: *Base, own: *Data) void {
            const field = own.field orelse return;
            const tags = [_]TagItem{
                .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(&own.shown) },
                .{},
            };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
            _ = base.intuition_base.SendMessage(field, @ptrCast(&set));
        }

        /// The value rebuilt from its parts and shown.
        fn refresh(base: *Base, own: *Data) void {
            switch (spec.kind) {
                .file => joinPath(own),
                .font => joinFont(own),
            }
            showText(base, own);
        }

        /// What was typed into the field taken as the value.
        fn takeTyped(base: *Base, own: *Data) void {
            const field = own.field orelse return;
            var storage: usize = 0;
            if (base.intuition_base.GetAttr(gc.STRINGA_TextVal, field, &storage) == 0) return;
            copyInto(&own.shown, @ptrFromInt(storage));
            switch (spec.kind) {
                .file => splitPath(own),
                .font => splitFont(own),
            }
        }

        /// The gadget's target told what changed.
        fn tell(base: *Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
            const id: usize = @intCast(gc.gadget(o).id);
            const tags = switch (spec.kind) {
                .file => [_]TagItem{
                    .{ .tag = firstValue(spec), .data = @intFromPtr(&own.drawer) },
                    .{ .tag = secondValue(spec), .data = @intFromPtr(&own.file) },
                    .{ .tag = thirdValue(spec), .data = @intFromPtr(&own.shown) },
                    .{ .tag = gc.GA_ID, .data = id },
                    .{},
                },
                .font => [_]TagItem{
                    .{ .tag = firstValue(spec), .data = @intFromPtr(&own.drawer) },
                    .{ .tag = secondValue(spec), .data = own.size },
                    .{ .tag = fourthValue(spec), .data = @intFromPtr(&own.attr) },
                    .{ .tag = gc.GA_ID, .data = id },
                    .{},
                },
            };
            support.notify(base.intuition_base, o, gi, &tags, 0);
        }

        // --- where the parts are ------------------------------------------

        /// How wide and tall the screen's font is, which is what the
        /// gadget is measured in.
        const Size = struct { width: i32, height: i32 };

        fn fontSize(base: *Base, o: ?*Object, gi: ?*const classusr.GadgetInfo) Size {
            const ib = base.intuition_base;
            const g = if (o) |it| gc.gadget(it) else null;
            const measure = if (g) |it| support.Measure.of(ib, it, gi) else support.Measure{};
            defer measure.done(ib);
            return .{
                .width = @max(measure.width(ib, "M"), 1),
                .height = measure.lineHeight(base.graphics_base),
            };
        }

        /// How wide the button is: as wide as what is drawn in it, with
        /// room round it, and never so wide that the field has none.
        fn buttonWidth(base: *Base, o: *Object, gi: ?*const classusr.GadgetInfo, whole: i32) i32 {
            const size = fontSize(base, o, gi);
            const want = size.width * button_text.len + 8;
            return @max(@min(want, whole - 8), 0);
        }

        const Parts = struct { field: gc.Box, button: gc.Box };

        fn partsOf(base: *Base, o: *Object, gi: ?*const classusr.GadgetInfo) Parts {
            const b = gc.boxFor(gc.gadget(o), gi);
            const wide = buttonWidth(base, o, gi, b.width);
            return .{
                .field = .{ .left = 0, .top = 0, .width = b.width - wide, .height = b.height },
                .button = .{ .left = b.width - wide, .top = 0, .width = wide, .height = b.height },
            };
        }

        /// The field put where it belongs; its place in the gadget's box.
        fn placeField(base: *Base, own: *Data, o: *Object, gi: ?*const classusr.GadgetInfo) gc.Box {
            const b = gc.boxFor(gc.gadget(o), gi);
            const at = partsOf(base, o, gi).field;
            support.place(base.intuition_base, own.field.?, .{
                .left = b.left + at.left,
                .top = b.top + at.top,
                .width = at.width,
                .height = at.height,
            });
            return at;
        }

        fn onButton(base: *Base, o: *Object, gi: ?*const classusr.GadgetInfo, x: i32, y: i32) bool {
            const at = partsOf(base, o, gi).button;
            return x >= at.left and y >= at.top and x < at.left + at.width and y < at.top + at.height;
        }

        // --- drawing -------------------------------------------------------

        fn drawButton(base: *Base, own: *Data, o: *Object, rp: *graphics.RastPort, info: *classusr.GadgetInfo) void {
            const b = gc.boxFor(gc.gadget(o), info);
            const at = partsOf(base, o, info).button;
            if (at.width <= 0) return;
            const box = gc.Box{
                .left = b.left + at.left,
                .top = b.top + at.top,
                .width = at.width,
                .height = at.height,
            };
            const pressed = own.held != 0 and own.over != 0;
            support.drawFrame(
                base.intuition_base,
                own.frame.?,
                rp,
                box,
                if (pressed) ic.IDS_SELECTED else ic.IDS_NORMAL,
                info.draw_info,
                gc.gadget(o).style,
            );
            const size = fontSize(base, o, info);
            const wide: i32 = size.width * button_text.len;
            const tall: i32 = size.height;
            support.drawText(
                base.graphics_base,
                rp,
                box.left + @divTrunc(box.width - wide, 2),
                box.top + @divTrunc(box.height - tall, 2),
                button_text,
                info.draw_info.pens[sc.TEXTPEN],
            );
        }

        fn render(base: *Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
            const info = r.gadget_info orelse return;
            const gb = base.graphics_base;
            const own = classes.instData(Data, cl, o);
            const saved = support.Saved.of(gb, r.rast_port);
            defer saved.restore(gb, r.rast_port);
            _ = placeField(base, own, o, info);
            _ = base.intuition_base.SendMessage(own.field.?, @ptrCast(r));
            drawButton(base, own, o, r.rast_port, info);
            if (gc.gadget(o).flags & gc.GFLG_DISABLED != 0) {
                support.ghost(gb, r.rast_port, gc.boxFor(gc.gadget(o), info), info.block_pen);
            }
        }

        /// The button drawn again, if it is in a window.
        fn redrawButton(base: *Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
            const info = gi orelse return;
            const ib = base.intuition_base;
            const rp = ib.ObtainGIRPort(gi) orelse return;
            defer ib.ReleaseGIRPort(rp);
            const saved = support.Saved.of(base.graphics_base, rp);
            defer saved.restore(base.graphics_base, rp);
            drawButton(base, own, o, rp, info);
        }

        // --- the requester --------------------------------------------------

        /// What the process that opens the requester is given.
        const Job = extern struct {
            base: *Base,
            own: *Data,
            object: *Object,
            info: classusr.GadgetInfo,
        };

        /// The requester opened, and what was picked put in the field.
        fn askProcess(sys: *ExecBase) callconv(.c) void {
            const me = sys.FindTask(null).?;
            const job: *Job = @ptrCast(@alignCast(me.user_data orelse return));
            const base = job.base;
            const own = job.own;
            // The lock is taken here and not where the process was
            // started: a semaphore is released by the task that took
            // it, and that task was the input handler.
            sys.ObtainSemaphore(&own.lock);
            defer {
                own.asking = 0;
                sys.ReleaseSemaphore(&own.lock);
                sys.FreeVec(job);
            }
            const asl_lib = sys.OpenLibrary(asl.ASLNAME, 0) orelse return;
            defer sys.CloseLibrary(asl_lib);
            const al: *AslBase = @ptrCast(asl_lib);

            const picked = switch (spec.kind) {
                .file => askFile(base, al, own, &job.info),
                .font => askFont(base, al, own, &job.info),
            };
            if (!picked) return;
            refresh(base, own);
            support.redraw(base.intuition_base, job.object, &job.info);
            tell(base, own, job.object, &job.info);
        }

        fn askFile(base: *Base, al: *AslBase, own: *Data, info: *classusr.GadgetInfo) bool {
            _ = base;
            const request = al.AllocAslRequest(asl.ASL_FileRequest, &[_]TagItem{
                .{ .tag = asl.ASLFR_Window, .data = @intFromPtr(info.window) },
                .{ .tag = if (own.title != null) asl.ASLFR_TitleText else utility.TAG_IGNORE, .data = @intFromPtr(own.title) },
                .{ .tag = asl.ASLFR_InitialDrawer, .data = @intFromPtr(&own.drawer) },
                .{ .tag = asl.ASLFR_InitialFile, .data = @intFromPtr(&own.file) },
                .{ .tag = if (own.pattern[0] != 0) asl.ASLFR_InitialPattern else utility.TAG_IGNORE, .data = @intFromPtr(&own.pattern) },
                .{ .tag = if (own.pattern[0] != 0) asl.ASLFR_DoPatterns else utility.TAG_IGNORE, .data = 1 },
                .{ .tag = asl.ASLFR_DoSaveMode, .data = own.save_mode },
                .{ .tag = asl.ASLFR_DrawersOnly, .data = own.drawers_only },
                .{},
            }) orelse return false;
            defer al.FreeAslRequest(request);
            if (!al.AslRequest(request, null)) return false;
            const answer: *asl.FileRequester = @ptrCast(@alignCast(request));
            copyInto(&own.drawer, answer.drawer);
            copyInto(&own.file, answer.file);
            return true;
        }

        fn askFont(base: *Base, al: *AslBase, own: *Data, info: *classusr.GadgetInfo) bool {
            _ = base;
            const request = al.AllocAslRequest(asl.ASL_FontRequest, &[_]TagItem{
                .{ .tag = asl.ASLFO_Window, .data = @intFromPtr(info.window) },
                .{ .tag = if (own.title != null) asl.ASLFO_TitleText else utility.TAG_IGNORE, .data = @intFromPtr(own.title) },
                .{ .tag = asl.ASLFO_InitialName, .data = @intFromPtr(&own.drawer) },
                .{ .tag = asl.ASLFO_InitialSize, .data = own.size },
                .{ .tag = asl.ASLFO_InitialStyle, .data = own.style },
                .{},
            }) orelse return false;
            defer al.FreeAslRequest(request);
            if (!al.AslRequest(request, null)) return false;
            const answer: *asl.FontRequester = @ptrCast(@alignCast(request));
            copyInto(&own.drawer, answer.attr.name);
            own.size = answer.attr.y_size;
            own.style = answer.attr.style;
            return true;
        }

        /// The process started. Nothing happens if one is already open,
        /// which is what keeps a second press from asking twice.
        fn ask(base: *Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
            const sys = base.sys_base;
            const info = gi orelse return;
            if (own.asking != 0) return;
            // dos.library is one the class holds open: this runs on the
            // input handler, which may not wait for one to be loaded.
            const dl: *DosBase = @ptrCast(base.opened[2] orelse return);

            const memory = sys.AllocVec(@sizeOf(Job), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return;
            const job: *Job = @ptrCast(@alignCast(memory));
            job.* = .{ .base = base, .own = own, .object = o, .info = info.* };
            own.asking = 1;
            const tags = [_]TagItem{
                .{ .tag = dos.NP_Entry, .data = @intFromPtr(&askProcess) },
                .{ .tag = dos.NP_Name, .data = @intFromPtr(spec.name.ptr) },
                .{ .tag = dos.NP_StackSize, .data = 16384 },
                .{ .tag = dos.NP_UserData, .data = @intFromPtr(job) },
                .{},
            };
            if (dl.CreateNewProc(&tags) == null) {
                own.asking = 0;
                sys.FreeVec(memory);
            }
        }

        // --- the attributes -------------------------------------------------

        /// `typing` for the field's word of a key typed while it is still
        /// being edited: what it holds is taken once it is done with, as
        /// setting its text back would move its cursor to the start.
        fn setAttrs(base: *Base, own: *Data, tags: ?[*]const TagItem, new: bool, typing: bool) bool {
            const ub = base.utility_base;
            var changed = false;
            var state = tags;
            while (ub.NextTagItem(&state)) |item| {
                if (item.tag == titleText(spec)) {
                    own.title = @ptrFromInt(item.data);
                } else if (item.tag == readOnly(spec)) {
                    own.read_only = @intFromBool(item.data != 0);
                } else if (item.tag == firstValue(spec)) {
                    copyInto(&own.drawer, @ptrFromInt(item.data));
                    changed = true;
                } else if (item.tag == secondValue(spec)) {
                    switch (spec.kind) {
                        .file => copyInto(&own.file, @ptrFromInt(item.data)),
                        .font => own.size = @truncate(item.data),
                    }
                    changed = true;
                } else if (item.tag == thirdValue(spec) and spec.kind == .font) {
                    own.style = @truncate(item.data);
                    changed = true;
                } else if (item.tag == fourthValue(spec) and spec.kind == .file) {
                    copyInto(&own.pattern, @ptrFromInt(item.data));
                } else if (item.tag == fifthValue(spec) and spec.kind == .file) {
                    own.save_mode = @intFromBool(item.data != 0);
                } else if (item.tag == sixthValue(spec) and spec.kind == .file) {
                    own.drawers_only = @intFromBool(item.data != 0);
                } else if (item.tag == gc.STRINGA_TextVal and !new and !typing) {
                    // The field said what was typed in it.
                    takeTyped(base, own);
                    changed = true;
                }
            }
            if (changed) refresh(base, own);
            return changed;
        }

        fn getAttr(own: *Data, attr: utility.Tag, storage: *usize) bool {
            if (attr == firstValue(spec)) {
                storage.* = @intFromPtr(&own.drawer);
            } else if (attr == secondValue(spec)) {
                storage.* = switch (spec.kind) {
                    .file => @intFromPtr(&own.file),
                    .font => own.size,
                };
            } else if (attr == thirdValue(spec)) {
                storage.* = switch (spec.kind) {
                    .file => @intFromPtr(&own.shown),
                    .font => own.style,
                };
            } else if (attr == fourthValue(spec) and spec.kind == .font) {
                storage.* = @intFromPtr(&own.attr);
            } else if (attr == titleText(spec)) {
                storage.* = @intFromPtr(own.title);
            } else if (attr == readOnly(spec)) {
                storage.* = own.read_only;
            } else {
                return false;
            }
            return true;
        }

        /// Its size: the field's, and the button beside it.
        fn domain(base: *Base, o: ?*Object, gi: ?*const classusr.GadgetInfo, which: u32) gc.Box {
            const size = fontSize(base, o, gi);
            const tall: i32 = size.height + 6;
            const wide: i32 = size.width;
            return switch (which) {
                gc.GDOMAIN_MINIMUM => .{ .width = wide * 8, .height = tall },
                gc.GDOMAIN_NOMINAL => .{ .width = wide * 32, .height = tall },
                else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = tall },
            };
        }

        fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
            const cl: *Class = @ptrCast(hook);
            const base = @import("classlibrary.zig").baseOf(cl);
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
                    base.sys_base.InitSemaphore(&own.lock);
                    const frame_tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
                    own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
                    const field_tags = [_]TagItem{
                        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(obj) },
                        .{},
                    };
                    own.field = ib.NewObjectTagList(null, st.STRING_CLASS, &field_tags);
                    if (own.field == null or own.frame == null) {
                        ib.DisposeObject(obj);
                        return 0;
                    }
                    _ = setAttrs(base, own, new.attr_list, true, false);
                    refresh(base, own);
                    return made;
                },
                classusr.OM_DISPOSE => {
                    const own = classes.instData(Data, cl, o orelse return 0);
                    // Nothing goes while a requester is open.
                    base.sys_base.ObtainSemaphore(&own.lock);
                    base.sys_base.ReleaseSemaphore(&own.lock);
                    ib.DisposeObject(own.field);
                    ib.DisposeObject(own.frame);
                    own.field = null;
                    own.frame = null;
                    return ib.SendSuperMessage(cl, o, msg);
                },
                classusr.OM_SET, classusr.OM_UPDATE => {
                    const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
                    const own = classes.instData(Data, cl, o.?);
                    var changed = ib.SendSuperMessage(cl, o, msg);
                    const typing = msg.method_id == classusr.OM_UPDATE and
                        @as(*classusr.OpUpdate, @ptrCast(@alignCast(msg))).flags & classusr.OPUF_INTERIM != 0;
                    if (setAttrs(base, own, set.attr_list, false, typing)) changed = 1;
                    if (changed != 0 and msg.method_id == classusr.OM_UPDATE and set.gadget_info != null) {
                        support.redraw(ib, o.?, set.gadget_info);
                    }
                    return changed;
                },
                classusr.OM_GET => {
                    const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
                    const own = classes.instData(Data, cl, o.?);
                    if (getAttr(own, get.attr_id, get.storage)) return 1;
                    return ib.SendSuperMessage(cl, o, msg);
                },
                gc.GM_DOMAIN => {
                    const ask_domain: *gc.GpDomain = @ptrCast(@alignCast(msg));
                    ask_domain.domain = domain(base, o, ask_domain.gadget_info, ask_domain.which);
                    return 1;
                },
                gc.GM_HITTEST => {
                    const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
                    const b = gc.boxFor(gc.gadget(o.?), ht.gadget_info);
                    return if (support.inside(ht.mouse.x, ht.mouse.y, b.width, b.height)) gc.GMR_GADGETHIT else 0;
                },
                gc.GM_RENDER => {
                    render(base, cl, o.?, @ptrCast(@alignCast(msg)));
                    return 0;
                },
                // The key works the button, which is what the gadget is
                // for; a read-only field has nothing else to give it to.
                gc.GM_KEY => {
                    const k: *gc.GpKey = @ptrCast(@alignCast(msg));
                    return if (gc.keyIsFor(o.?, k)) gc.GMKR_ACTIVATE else gc.GMKR_NOTHING;
                },
                gc.GM_GOACTIVE => {
                    const in: *gc.GpInput = @ptrCast(@alignCast(msg));
                    const own = classes.instData(Data, cl, o.?);
                    // With no press behind it - the key, or a program
                    // asking - the button is what is meant.
                    if (in.event == null or onButton(base, o.?, in.gadget_info, in.mouse.x, in.mouse.y)) {
                        own.held = 1;
                        own.over = 1;
                        redrawButton(base, own, o.?, in.gadget_info);
                        if (in.event == null) {
                            own.held = 0;
                            own.over = 0;
                            redrawButton(base, own, o.?, in.gadget_info);
                            ask(base, own, o.?, in.gadget_info);
                            return gc.GMR_NOREUSE;
                        }
                        return gc.GMR_MEACTIVE;
                    }
                    if (own.read_only != 0) return gc.GMR_NOREUSE;
                    const at = placeField(base, own, o.?, in.gadget_info);
                    return support.handOnInput(ib, own.field.?, in, at);
                },
                gc.GM_HANDLEINPUT => {
                    const in: *gc.GpInput = @ptrCast(@alignCast(msg));
                    const own = classes.instData(Data, cl, o.?);
                    if (own.held == 0) {
                        const at = placeField(base, own, o.?, in.gadget_info);
                        return support.handOnInput(ib, own.field.?, in, at);
                    }
                    const e = in.event orelse return gc.GMR_MEACTIVE;
                    const over: u8 = @intFromBool(onButton(base, o.?, in.gadget_info, in.mouse.x, in.mouse.y));
                    if (over != own.over) {
                        own.over = over;
                        redrawButton(base, own, o.?, in.gadget_info);
                    }
                    // The press ends as a raw mouse event or as a
                    // pointer move that carries the button's state,
                    // depending on how the pointer got there.
                    const up = e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX and
                        (e.class == ie.IECLASS_RAWMOUSE or e.class == ie.IECLASS_NEWPOINTERPOS);
                    if (up) {
                        const asked = own.over != 0;
                        own.held = 0;
                        own.over = 0;
                        redrawButton(base, own, o.?, in.gadget_info);
                        if (asked) ask(base, own, o.?, in.gadget_info);
                        return gc.GMR_NOREUSE;
                    }
                    return gc.GMR_MEACTIVE;
                },
                gc.GM_GOINACTIVE => {
                    const gone: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
                    const own = classes.instData(Data, cl, o.?);
                    if (own.held != 0) {
                        own.held = 0;
                        own.over = 0;
                        redrawButton(base, own, o.?, gone.gadget_info);
                        return 0;
                    }
                    return ib.SendSuperMessage(cl, o, msg);
                },
                else => return ib.SendSuperMessage(cl, o, msg),
            }
        }

        pub const Made = @import("classlibrary.zig").ClassLibrary(.{
            .name = spec.name,
            .version = 1,
            .revision = 1,
            .date = "08.10.2026",
            .super = classusr.GADGETCLASS,
            .Instance = Data,
            .dispatch = Self.dispatch,
            // The field it makes is a string.gadget, and asl.library
            // holds the requester the button opens.
            .opens = &.{ st.STRING_LIBRARY, asl.ASLNAME, dos.DOSNAME },
        });
    };
}
