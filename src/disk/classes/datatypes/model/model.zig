// SPDX-License-Identifier: MIT
//! model.datatype: what every model in three dimensions is, whatever file
//! it came out of.
//!
//! A datatypesclass subclass, and a superclass only: a format's class -
//! obj - is a subclass of this one, and reads its file and nothing more.
//! In `OM_NEW` it sets `MDTA_ModelHeader`, which gives the object memory
//! for the model, and hands the vertices, the indices, the materials and
//! the parts over; a material's picture comes as a picture.datatype
//! object, read here at once into a texture's levels and disposed of.
//! Everything else is this class's: drawing the model, turning it,
//! looking at it nearer or further, turning it by itself.
//!
//! **A process draws, `GM_RENDER` only puts up.** The object is a gadget
//! in a window that is not its own, among others perhaps, so it draws
//! where intuition tells it to, with the RastPort intuition hands it and
//! the layers already locked: `GM_RENDER` copies a picture the process
//! drew - in the screen's own pixels, so the copy is a copy - into the
//! window. The process (render.zig) draws through facet.library, a frame
//! at a time, into one of three pictures (state.zig), and asks for the
//! object to be drawn again when one is ready.
//!
//! **The pointer moves the camera; it draws nothing.** Dragging over the
//! model turns it, the wheel takes it nearer or further, and each only
//! changes the numbers and wakes the process, which draws from wherever
//! the camera is when it begins a frame. A drag of many steps is drawn
//! as often as a frame can be, from its latest step: on a machine that
//! takes 170 ms a frame the model keeps up with the pointer, a frame
//! behind, rather than falling a step further behind with every step.
//! Nothing changing, nothing is drawn.
//!
//! **The room is all there is.** The model takes whatever room it is
//! given and has nothing outside it: `DTA_TotalVert` is `DTA_VisibleVert`
//! and the room's height, and the same across, so a window shows no bars
//! for it. A new room is laid out (`DTM_ASYNCLAYOUT`) as a new size for
//! the pictures, which the process makes them at for its next frame.
//!
//! `DTM_TRIGGER` with `STM_PLAY` turns it by itself until `STM_PAUSE`,
//! which turns over, or `STM_STOP`, which takes it back to where it
//! started; the object lists them (`DTA_TriggerMethods`) for a program to
//! offer without knowing what it holds. Without facet.library, or on a
//! screen whose pixels it does not draw in, the object says so in its
//! room rather than failing to be made.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const sc = intuition.screens;
const ie = sdk.devices.inputevent;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const mdt = datatypes.modelclass;
const pic = datatypes.pictureclass;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Base = gadgets.Base;
const Pen = graphics.Pen;
const state = @import("state.zig");
const render = @import("render.zig");
const levels = @import("levels.zig");
const camera = @import("camera.zig");
const Data = state.Data;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
/// datatypes.library because datatypesclass is made by it and a picture
/// handed over is disposed of through it; dos for the process.
pub const Library = gadgets.ClassLibrary(.{
    .name = mdt.MODELDTCLASS,
    .version = 1,
    .date = "30.10.2026",
    .super = dtc.DATATYPESCLASS,
    .opens = &.{ datatypes.DATATYPESNAME, dos.DOSNAME },
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

const opened_datatypes = 0;
const opened_dos = 1;

/// The room it asks for before it is given any.
const nominal_width = 480;
const nominal_height = 360;
/// How far a pixel of the pointer turns it, in radians.
const turn_per_pixel: f32 = 0.01;
/// How much further a notch of the wheel down takes it, and nearer up.
const zoom_per_notch: f32 = 1.15;

/// What it can be told to do, for a program to offer.
const trigger_methods = [_]dtc.DTMethod{
    .{ .label = "Play", .command = "PLAY", .method = dtc.STM_PLAY },
    .{ .label = "Pause", .command = "PAUSE", .method = dtc.STM_PAUSE },
    .{ .label = "Stop", .command = "STOP", .method = dtc.STM_STOP },
    .{},
};

fn dataOf(cl: *Class, o: *Object) *Data {
    return classes.instData(Data, cl, o);
}

fn dosOf(base: *Base) *DosBase {
    return @ptrCast(base.opened[opened_dos].?);
}

fn datatypesOf(base: *Base) *DataTypesBase {
    return @ptrCast(base.opened[opened_datatypes].?);
}

/// The process told there is something to draw.
fn wake(base: *Base, own: *Data) void {
    if (own.renderer) |task| base.sys_base.Signal(task, exec.SIGBREAKF_CTRL_F);
}

// --- the model handed over -------------------------------------------------------

/// Memory for the model `header` says; false when there is none, and
/// then nothing is held.
fn hold(base: *Base, own: *Data, header: *const mdt.ModelHeader) bool {
    const sys = base.sys_base;
    if (own.held) return false;
    own.header = header.*;
    const vertex_bytes = @as(usize, header.vertices) * @sizeOf(mdt.ModelVertex);
    const index_bytes = @as(usize, header.indices) * 4;
    own.vertices = @ptrCast(@alignCast(sys.AllocVec(@max(vertex_bytes, 4), exec.MEMF_ANY | exec.MEMF_CLEAR)));
    own.indices = @ptrCast(@alignCast(sys.AllocVec(@max(index_bytes, 4), exec.MEMF_ANY | exec.MEMF_CLEAR)));
    own.materials = @ptrCast(@alignCast(sys.AllocVec(@max(header.materials, 1) * @sizeOf(state.Material), exec.MEMF_ANY | exec.MEMF_CLEAR)));
    own.parts = @ptrCast(@alignCast(sys.AllocVec(@max(header.parts, 1) * @sizeOf(state.Part), exec.MEMF_ANY | exec.MEMF_CLEAR)));
    if (own.vertices == null or own.indices == null or own.materials == null or own.parts == null) {
        letGo(sys, own);
        return false;
    }
    for (own.materials.?[0..header.materials]) |*material| material.* = .{};
    own.held = true;
    return true;
}

/// What the object holds of the model given back.
fn letGo(sys: *ExecBase, own: *Data) void {
    if (own.materials) |materials| {
        for (materials[0..own.header.materials]) |material| sys.FreeVec(material.texture);
    }
    sys.FreeVec(own.vertices);
    sys.FreeVec(own.indices);
    sys.FreeVec(own.materials);
    sys.FreeVec(own.parts);
    own.vertices = null;
    own.indices = null;
    own.materials = null;
    own.parts = null;
    own.held = false;
}

fn writeVertices(own: *Data, msg: *const mdt.MdtWriteVertices) bool {
    const vertices = own.vertices orelse return false;
    if (!own.held or msg.first > own.header.vertices or msg.count > own.header.vertices - msg.first) return false;
    @memcpy(vertices[msg.first..][0..msg.count], msg.vertices[0..msg.count]);
    return true;
}

fn writeIndices(own: *Data, msg: *const mdt.MdtWriteIndices) bool {
    const indices = own.indices orelse return false;
    if (!own.held or msg.first > own.header.indices or msg.count > own.header.indices - msg.first) return false;
    // An index past the vertices would read past the buffer: such a one
    // is the first vertex instead.
    for (msg.indices[0..msg.count], indices[msg.first..][0..msg.count]) |given, *kept| {
        kept.* = if (given < own.header.vertices) given else 0;
    }
    return true;
}

fn writePart(own: *Data, msg: *const mdt.MdtWritePart) bool {
    const parts = own.parts orelse return false;
    if (!own.held or msg.part >= own.header.parts) return false;
    if (msg.first > own.header.indices or msg.count > own.header.indices - msg.first) return false;
    parts[msg.part] = .{ .first = msg.first, .count = msg.count - msg.count % 3, .material = msg.material };
    return true;
}

/// A material's colour kept, and its picture read into a texture's
/// levels and disposed of, whatever came of it.
fn writeMaterial(base: *Base, own: *Data, msg: *const mdt.MdtWriteMaterial) bool {
    const picture = msg.picture;
    defer if (picture) |object| datatypesOf(base).DisposeDTObject(object);
    const materials = own.materials orelse return false;
    if (!own.held or msg.material >= own.header.materials) return false;
    const material = &materials[msg.material];
    material.color = msg.color;
    const object = picture orelse return true;
    const sys = base.sys_base;
    const ib = base.intuition_base;
    var header: usize = 0;
    var pixels: usize = 0;
    var pitch: usize = 0;
    _ = ib.GetAttr(pic.PDTA_BitMapHeader, object, &header);
    _ = ib.GetAttr(pic.PDTA_Pixels, object, &pixels);
    _ = ib.GetAttr(pic.PDTA_BytesPerRow, object, &pitch);
    if (header == 0 or pixels == 0) return false;
    const bmh: *const pic.BitMapHeader = @ptrFromInt(header);
    if (bmh.width == 0 or bmh.height == 0) return false;
    const shape = levels.Shape.of(bmh.width, bmh.height);
    if (!datatypes.subclass.roomFor(sys, shape.bytes())) return false;
    const memory = sys.AllocVec(shape.bytes(), exec.MEMF_ANY) orelse return false;
    levels.stage(@ptrFromInt(pixels), bmh.width, bmh.height, pitch, shape, @ptrCast(memory));
    sys.FreeVec(material.texture);
    material.texture = @ptrCast(memory);
    material.texture_width = shape.width;
    material.texture_height = shape.height;
    material.texture_levels = shape.levels;
    return true;
}

// --- the process -----------------------------------------------------------------

/// The process, made the first time the object is laid out. False when it
/// could not be.
fn begin(base: *Base, own: *Data) bool {
    if (own.started) return true;
    const sys = base.sys_base;
    sys.InitSemaphore(&own.alive);
    own.start_signal = sys.AllocSignal(-1);
    if (own.start_signal < 0) return false;
    own.starter = sys.FindTask(null);
    const proc = dosOf(base).CreateNewProc(&[_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&render.main) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr("model renderer") },
        .{ .tag = dos.NP_StackSize, .data = render.stack_bytes },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(own) },
        .{},
    });
    // It holds `alive` from its first step, which is what `end` waits on.
    if (proc != null) _ = sys.Wait(@as(u32, 1) << @intCast(own.start_signal));
    sys.FreeSignal(own.start_signal);
    own.start_signal = -1;
    own.starter = null;
    if (proc == null) return false;
    own.renderer = @ptrCast(proc);
    own.started = true;
    return true;
}

/// The process told to go, and waited for: it gives back what it made
/// through facet.library on its way out.
fn end(base: *Base, own: *Data) void {
    const sys = base.sys_base;
    const task = own.renderer orelse return;
    own.quitting = true;
    sys.Signal(task, exec.SIGBREAKF_CTRL_C);
    sys.ObtainSemaphore(&own.alive);
    sys.ReleaseSemaphore(&own.alive);
    own.renderer = null;
    own.started = false;
}

// --- the room ------------------------------------------------------------------------

fn tellSuper(base: *Base, cl: *Class, o: *Object, tags: [*]const TagItem) void {
    datatypes.subclass.superTell(base.intuition_base, cl, o, tags);
}

/// The room laid out: its size is the model's, all of it seen, and the
/// pictures are drawn that size in the screen's pixels from now on.
fn layOut(base: *Base, cl: *Class, o: *Object, own: *Data, lay: *gc.GpLayout) void {
    const info = lay.gadget_info orelse return;
    const ib = base.intuition_base;
    const sys = base.sys_base;
    const box = gc.boxFor(gc.gadget(o), info);
    const width: u32 = @intCast(@max(box.width, 0));
    const height: u32 = @intCast(@max(box.height, 0));
    const tags = [_]TagItem{
        .{ .tag = dtc.DTA_VisibleHoriz, .data = width },
        .{ .tag = dtc.DTA_VisibleVert, .data = height },
        .{ .tag = dtc.DTA_TotalHoriz, .data = width },
        .{ .tag = dtc.DTA_TotalVert, .data = height },
        .{ .tag = dtc.DTA_TopHoriz, .data = 0 },
        .{ .tag = dtc.DTA_TopVert, .data = 0 },
        .{},
    };
    tellSuper(base, cl, o, &tags);
    var pixels: usize = state.unknown_format;
    ib.GetScreenAttrs(info.screen, &[_]TagItem{ .{ .tag = sc.SA_PixelFormat, .data = @intFromPtr(&pixels) }, .{} });
    const ground = support.background(ib, info.draw_info, gc.gadget(o).style, intuition.style.PART_MAIN);
    sys.AcquireLock(&own.lock);
    own.width = width;
    own.height = height;
    own.format = @truncate(pixels);
    own.ground = ground;
    own.changes +%= 1;
    sys.ReleaseLock(&own.lock);
    if (begin(base, own)) wake(base, own);
}

/// What the object is drawn with.
const Look = struct { ground: Pen, text: Pen };

fn lookOf(ib: *IntuitionBase, o: *Object, info: *classusr.GadgetInfo) Look {
    const pens = support.pensFor(ib, info.draw_info, gc.gadget(o).style, intuition.style.PART_MAIN, null);
    return .{ .ground = support.background(ib, info.draw_info, gc.gadget(o).style, intuition.style.PART_MAIN), .text = pens[sc.TEXTPEN] };
}

/// The object in `box`: the picture last drawn - the one ready made the
/// one on show first - and the ground where it does not reach; or what
/// keeps it from being drawn.
fn paint(base: *Base, own: *Data, rp: *graphics.RastPort, box: gc.Box, look: Look) void {
    const sys = base.sys_base;
    const gb = base.graphics_base;
    if (box.width <= 0 or box.height <= 0) return;

    sys.AcquireLock(&own.lock);
    var promoted = false;
    for (&own.slots, 0..) |*slot, index| {
        if (slot.state != state.READY) continue;
        if (own.shown >= 0) own.slots[@intCast(own.shown)].state = state.FREE;
        slot.state = state.SHOWN;
        own.shown = @intCast(index);
        promoted = true;
    }
    const trouble = own.trouble;
    const held: ?*state.Slot = if (trouble == null and own.shown >= 0) &own.slots[@intCast(own.shown)] else null;
    var slot: state.Slot = .{};
    if (held) |it| {
        it.readers += 1;
        slot = it.*;
    }
    sys.ReleaseLock(&own.lock);
    // A picture freed: the process may draw the next.
    if (promoted) wake(base, own);

    if (trouble) |text| {
        support.fill(gb, rp, box, look.ground);
        say(gb, rp, box, text, look.text);
        return;
    }
    const pixels = slot.pixels orelse {
        support.fill(gb, rp, box, look.ground);
        return;
    };
    const width = @min(@as(i32, @intCast(slot.width)), box.width);
    const height = @min(@as(i32, @intCast(slot.height)), box.height);
    const area = graphics.Rect{ .min_x = box.left, .min_y = box.top, .max_x = box.left + width, .max_y = box.top + height };
    gb.WritePixelArray(rp, pixels, slot.pitch, slot.format, 0, 0, &area);
    sys.AcquireLock(&own.lock);
    held.?.readers -= 1;
    sys.ReleaseLock(&own.lock);
    // A picture of the room before, smaller than this one: the ground
    // round it until the next is drawn.
    if (width < box.width) support.fill(gb, rp, .{ .left = box.left + width, .top = box.top, .width = box.width - width, .height = box.height }, look.ground);
    if (height < box.height) support.fill(gb, rp, .{ .left = box.left, .top = box.top + height, .width = width, .height = box.height - height }, look.ground);
}

/// `text` in the middle of `box`, its end cut where it does not fit.
fn say(gb: *GraphicsBase, rp: *graphics.RastPort, box: gc.Box, text: [*:0]const u8, pen: Pen) void {
    var count: u32 = support.textLen(text);
    while (count > 0 and gb.TextLength(rp, text, count) > box.width - 8) count -= 1;
    if (count == 0) return;
    var cut: [96:0]u8 = @splat(0);
    const kept = @min(count, cut.len);
    for (0..kept) |i| cut[i] = text[i];
    var font_height: u32 = 8;
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&font_height) }, .{} });
    const width = gb.TextLength(rp, &cut, kept);
    support.drawText(gb, rp, box.left + @divTrunc(box.width - width, 2), box.top + @divTrunc(box.height - @as(i32, @intCast(font_height)), 2), &cut, pen);
}

// --- the pointer, the wheel and the triggers ----------------------------------------

fn turnBy(base: *Base, own: *Data, x: i32, y: i32) void {
    const sys = base.sys_base;
    sys.AcquireLock(&own.lock);
    const across = x - own.drag_x;
    const down = y - own.drag_y;
    own.drag_x = x;
    own.drag_y = y;
    if (across != 0 or down != 0) {
        // The side under the pointer follows it.
        own.yaw -= @as(f32, @floatFromInt(across)) * turn_per_pixel;
        own.pitch = @min(@max(own.pitch - @as(f32, @floatFromInt(down)) * turn_per_pixel, -camera.Camera.most_pitch), camera.Camera.most_pitch);
        own.changes +%= 1;
    }
    sys.ReleaseLock(&own.lock);
    if (across != 0 or down != 0) wake(base, own);
}

fn handleInput(base: *Base, own: *Data, in: *gc.GpInput) usize {
    const e = in.event orelse return gc.GMR_MEACTIVE;
    if (e.class != ie.IECLASS_NEWPOINTERPOS) return gc.GMR_MEACTIVE;
    turnBy(base, own, in.mouse.x, in.mouse.y);
    if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
        own.dragging = false;
        return gc.GMR_NOREUSE;
    }
    return gc.GMR_MEACTIVE;
}

fn wheel(base: *Base, own: *Data, wh: *gc.GpWheel) usize {
    const notches = gc.wheelNotches(wh, true);
    if (notches == 0) return gc.GMWR_NOTHING;
    const sys = base.sys_base;
    var factor: f32 = 1;
    var left = @abs(notches);
    while (left > 0) : (left -= 1) factor *= zoom_per_notch;
    sys.AcquireLock(&own.lock);
    const zoom = if (notches > 0) own.zoom * factor else own.zoom / factor;
    own.zoom = @min(@max(zoom, camera.Camera.least_zoom), camera.Camera.most_zoom);
    own.changes +%= 1;
    sys.ReleaseLock(&own.lock);
    wake(base, own);
    return gc.GMWR_TAKEN;
}

fn trigger(base: *Base, own: *Data, function: u32) void {
    const sys = base.sys_base;
    sys.AcquireLock(&own.lock);
    switch (function) {
        dtc.STM_PLAY, dtc.STM_RESUME => own.turning = true,
        dtc.STM_PAUSE => own.turning = !own.turning,
        dtc.STM_STOP => {
            const start = camera.Camera{};
            own.turning = false;
            own.yaw = start.yaw;
            own.pitch = start.pitch;
            own.zoom = start.zoom;
            own.changes +%= 1;
        },
        else => {},
    }
    sys.ReleaseLock(&own.lock);
    wake(base, own);
}

fn frameBox(frame: *dtc.DtFrameBox) void {
    const want = frame.frame_info;
    want.* = frame.contents_info.*;
    want.width = nominal_width;
    want.height = nominal_height;
    want.flags = 0;
}

fn getAttr(own: *Data, attr: utility.Tag, storage: *usize) bool {
    storage.* = switch (attr) {
        mdt.MDTA_ModelHeader => if (own.held) @intFromPtr(&own.header) else 0,
        mdt.MDTA_Turning => @intFromBool(own.turning),
        else => return false,
    };
    return true;
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
            const own = dataOf(cl, obj);
            own.* = .{};
            const start = camera.Camera{};
            own.yaw = start.yaw;
            own.pitch = start.pitch;
            own.zoom = start.zoom;
            own.object = obj;
            own.base = base;
            base.sys_base.InitLock(&own.lock, "model", exec.LOCKORDER_DRIVER, 0);
            const tags = [_]TagItem{
                .{ .tag = dtc.DTA_NominalHoriz, .data = nominal_width },
                .{ .tag = dtc.DTA_NominalVert, .data = nominal_height },
                .{ .tag = dtc.DTA_HorizUnit, .data = 1 },
                .{ .tag = dtc.DTA_VertUnit, .data = 1 },
                .{ .tag = dtc.DTA_TriggerMethods, .data = @intFromPtr(&trigger_methods) },
                .{},
            };
            tellSuper(base, cl, obj, &tags);
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = dataOf(cl, o.?);
            end(base, own);
            letGo(base.sys_base, own);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = dataOf(cl, o.?);
            if (base.utility_base.FindTagItem(mdt.MDTA_ModelHeader, set.attr_list)) |item| {
                if (item.data != 0) _ = hold(base, own, @ptrFromInt(item.data));
            }
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            if (getAttr(dataOf(cl, o.?), get.attr_id, get.storage)) return 1;
            return ib.SendSuperMessage(cl, o, msg);
        },
        mdt.MDTM_WRITEVERTICES => return @intFromBool(writeVertices(dataOf(cl, o.?), @ptrCast(@alignCast(msg)))),
        mdt.MDTM_WRITEINDICES => return @intFromBool(writeIndices(dataOf(cl, o.?), @ptrCast(@alignCast(msg)))),
        mdt.MDTM_WRITEMATERIAL => return @intFromBool(writeMaterial(base, dataOf(cl, o.?), @ptrCast(@alignCast(msg)))),
        mdt.MDTM_WRITEPART => return @intFromBool(writePart(dataOf(cl, o.?), @ptrCast(@alignCast(msg)))),
        gc.GM_RENDER => {
            const r: *gc.GpRender = @ptrCast(@alignCast(msg));
            const info = r.gadget_info orelse return 0;
            const gb = base.graphics_base;
            const own = dataOf(cl, o.?);
            const saved = support.Saved.of(gb, r.rast_port);
            defer saved.restore(gb, r.rast_port);
            const look = lookOf(ib, o.?, info);
            // The ground the frames are cleared to, as the window shows it.
            const sys = base.sys_base;
            sys.AcquireLock(&own.lock);
            const new_ground = own.ground != look.ground;
            if (new_ground) {
                own.ground = look.ground;
                own.changes +%= 1;
            }
            sys.ReleaseLock(&own.lock);
            if (new_ground) wake(base, own);
            paint(base, own, r.rast_port, gc.boxFor(gc.gadget(o.?), info), look);
            return 0;
        },
        gc.GM_HITTEST => return gc.GMR_GADGETHIT,
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = dataOf(cl, o.?);
            if (in.event == null) return gc.GMR_NOREUSE;
            const sys = base.sys_base;
            sys.AcquireLock(&own.lock);
            own.dragging = true;
            own.drag_x = in.mouse.x;
            own.drag_y = in.mouse.y;
            sys.ReleaseLock(&own.lock);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => return handleInput(base, dataOf(cl, o.?), @ptrCast(@alignCast(msg))),
        gc.GM_GOINACTIVE => {
            dataOf(cl, o.?).dragging = false;
            return 0;
        },
        gc.GM_WHEEL => return wheel(base, dataOf(cl, o.?), @ptrCast(@alignCast(msg))),
        dtc.DTM_PROCLAYOUT, dtc.DTM_ASYNCLAYOUT => {
            layOut(base, cl, o.?, dataOf(cl, o.?), @ptrCast(@alignCast(msg)));
            return 1;
        },
        dtc.DTM_FRAMEBOX => {
            frameBox(@ptrCast(@alignCast(msg)));
            return 1;
        },
        dtc.DTM_TRIGGER => {
            const t: *dtc.DtTrigger = @ptrCast(@alignCast(msg));
            trigger(base, dataOf(cl, o.?), t.function);
            return 1;
        },
        dtc.DTM_DRAW => {
            const draw: *dtc.DtDraw = @ptrCast(@alignCast(msg));
            const gb = base.graphics_base;
            const saved = support.Saved.of(gb, draw.rast_port);
            defer saved.restore(gb, draw.rast_port);
            paint(base, dataOf(cl, o.?), draw.rast_port, .{ .left = draw.left, .top = draw.top, .width = draw.width, .height = draw.height }, .{ .ground = 0xFF00_0000, .text = 0xFFFF_FFFF });
            return 1;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
