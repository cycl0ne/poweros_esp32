// SPDX-License-Identifier: MIT
//! datatypesclass: what every data type object is, made by the library
//! when it is first opened.
//!
//! It is a gadgetclass gadget, so intuition drives an object like any
//! other gadget and a program may put one in a layout. What this class
//! adds is what every kind of contents has in common: where the source
//! came from, how much of it there is and how much is shown, what it is
//! called, and the methods that work it. A format's class subclasses
//! this one and answers the parts that are its own - reading the file,
//! drawing it, saying how big it is.
//!
//! **The source is the object's.** `DTA_Handle` comes in as a lock for
//! a file or as an open IFF handle for the clipboard, and from then on
//! the object owns it: a subclass reads it in `OM_NEW` and the object
//! closes whatever is left at `OM_DISPOSE`. That is why a program hands
//! a file name to `NewDTObjectA` and never opens anything itself.
//!
//! **Laying out is not done where it is asked for.** `GM_LAYOUT` comes
//! from intuition's input, which may not wait, and reflowing a long text
//! or scaling a large picture takes as long as it takes. The class
//! answers `GM_LAYOUT` by starting a process (`layout/`), and the work
//! happens there as `DTM_ASYNCLAYOUT`.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const iffparse = sdk.iffparse;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const _base = @import("../datatypes_base.zig");
const DataTypesBase = _base.DataTypesBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;

/// datatypesclass's part of an object.
pub const Data = extern struct {
    /// The scroll numbers, which `DTA_Top*` and its like read and write.
    special: dtc.DTSpecialInfo = .{},
    base: *DataTypesBase,
    /// Where the contents came from, and what is left of it to close.
    source_type: u32 = dtc.DTST_FILE,
    handle: ?*anyopaque = null,
    data_type: ?*datatypes.DataType = null,
    /// The file's name and the object's title, both copied.
    name: ?[*:0]u8 = null,
    title: ?[*:0]u8 = null,
    node_name: ?[*:0]const u8 = null,
    /// What the contents say about themselves; the caller's or the
    /// subclass's, not copied.
    obj_name: ?[*:0]const u8 = null,
    obj_author: ?[*:0]const u8 = null,
    obj_annotation: ?[*:0]const u8 = null,
    obj_copyright: ?[*:0]const u8 = null,
    obj_version: ?[*:0]const u8 = null,
    /// The font text in the object is drawn in.
    text_attr: ?*graphics.TextAttr = null,
    text_font: ?*graphics.TextFont = null,
    /// What the object answers and what it can be told to do.
    methods: ?[*]const u32 = null,
    trigger_methods: ?[*]const dtc.DTMethod = null,
    /// What went wrong, for a program to show.
    error_level: i32 = 0,
    error_number: i32 = 0,
    error_string: ?[*:0]const u8 = null,
    /// The size it would like to be, in units.
    nominal_vert: i32 = 0,
    nominal_horiz: i32 = 0,
    object_id: u32 = 0,
    user_data: usize = 0,
    busy: u8 = 0,
    sync: u8 = 0,
    control_panel: u8 = 1,
    immediate: u8 = 0,
    repeat: u8 = 0,
    pad: [3]u8 = @splat(0),
    /// The process laying the object out, while one is running.
    layout_proc: ?*anyopaque = null,
};

/// A string copied into memory of its own, and the old copy given back.
pub fn takeString(db: *DataTypesBase, into: *?[*:0]u8, text: ?[*:0]const u8) void {
    const sys = db.sys_base;
    if (into.*) |old| sys.FreeVec(old);
    into.* = null;
    const from = text orelse return;
    var len: usize = 0;
    while (from[len] != 0) len += 1;
    const memory = sys.AllocVec(len + 1, exec.MEMF_ANY) orelse return;
    const copy: [*]u8 = @ptrCast(memory);
    @memcpy(copy[0..len], from[0..len]);
    copy[len] = 0;
    into.* = @ptrCast(copy);
}

/// Everything the object was given to read from, closed.
pub fn closeSource(db: *DataTypesBase, own: *Data) void {
    const handle = own.handle orelse return;
    own.handle = null;
    switch (own.source_type) {
        dtc.DTST_FILE => db.dos_base.UnLock(@ptrCast(@alignCast(handle))),
        dtc.DTST_CLIPBOARD => {
            const ip = db.iffparse_base;
            const iff: *iffparse.IFFHandle = @ptrCast(@alignCast(handle));
            const clip: ?*iffparse.ClipboardHandle = @ptrFromInt(iff.stream);
            ip.CloseIFF(iff);
            ip.CloseClipboard(clip);
            ip.FreeIFF(iff);
        },
        else => {},
    }
}

/// The attributes among `tags` that are this class's. Whether anything
/// that shows changed.
fn setAttrs(db: *DataTypesBase, own: *Data, tags: ?[*]const TagItem, new: bool) bool {
    const ub = db.utility_base;
    var changed = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        const value: i32 = @truncate(@as(isize, @bitCast(item.data)));
        switch (item.tag) {
            dtc.DTA_TopVert => {
                own.special.old_top_vert = own.special.top_vert;
                own.special.top_vert = value;
                changed = true;
            },
            dtc.DTA_TopHoriz => {
                own.special.old_top_horiz = own.special.top_horiz;
                own.special.top_horiz = value;
                changed = true;
            },
            dtc.DTA_VisibleVert => own.special.vis_vert = value,
            dtc.DTA_VisibleHoriz => own.special.vis_horiz = value,
            dtc.DTA_TotalVert => own.special.tot_vert = value,
            dtc.DTA_TotalHoriz => own.special.tot_horiz = value,
            dtc.DTA_VertUnit => own.special.vert_unit = @max(value, 1),
            dtc.DTA_HorizUnit => own.special.horiz_unit = @max(value, 1),
            dtc.DTA_NominalVert => own.nominal_vert = value,
            dtc.DTA_NominalHoriz => own.nominal_horiz = value,
            dtc.DTA_Title => {
                takeString(db, &own.title, @ptrFromInt(item.data));
                changed = true;
            },
            dtc.DTA_NodeName => own.node_name = @ptrFromInt(item.data),
            dtc.DTA_ObjName => own.obj_name = @ptrFromInt(item.data),
            dtc.DTA_ObjAuthor => own.obj_author = @ptrFromInt(item.data),
            dtc.DTA_ObjAnnotation => own.obj_annotation = @ptrFromInt(item.data),
            dtc.DTA_ObjCopyright => own.obj_copyright = @ptrFromInt(item.data),
            dtc.DTA_ObjVersion => own.obj_version = @ptrFromInt(item.data),
            dtc.DTA_TextAttr => own.text_attr = @ptrFromInt(item.data),
            dtc.DTA_TextFont => own.text_font = @ptrFromInt(item.data),
            dtc.DTA_Methods => own.methods = @ptrFromInt(item.data),
            dtc.DTA_TriggerMethods => own.trigger_methods = @ptrFromInt(item.data),
            dtc.DTA_ErrorLevel => own.error_level = value,
            dtc.DTA_ErrorNumber => own.error_number = value,
            dtc.DTA_ErrorString => own.error_string = @ptrFromInt(item.data),
            dtc.DTA_ObjectID => own.object_id = @truncate(item.data),
            dtc.DTA_UserData => own.user_data = item.data,
            dtc.DTA_Busy => own.busy = @intFromBool(item.data != 0),
            dtc.DTA_Sync => {
                own.sync = @intFromBool(item.data != 0);
                changed = true;
            },
            dtc.DTA_ControlPanel => own.control_panel = @intFromBool(item.data != 0),
            dtc.DTA_Immediate => own.immediate = @intFromBool(item.data != 0),
            dtc.DTA_Repeat => own.repeat = @intFromBool(item.data != 0),
            else => if (new) switch (item.tag) {
                dtc.DTA_Name => takeString(db, &own.name, @ptrFromInt(item.data)),
                dtc.DTA_SourceType => own.source_type = @truncate(item.data),
                dtc.DTA_Handle => own.handle = @ptrFromInt(item.data),
                dtc.DTA_DataType => own.data_type = @ptrFromInt(item.data),
                else => {},
            },
        }
    }
    return changed;
}

fn getAttr(own: *Data, attr: utility.Tag, storage: *usize) bool {
    storage.* = switch (attr) {
        dtc.DTA_TopVert => @bitCast(@as(isize, own.special.top_vert)),
        dtc.DTA_VisibleVert => @bitCast(@as(isize, own.special.vis_vert)),
        dtc.DTA_TotalVert => @bitCast(@as(isize, own.special.tot_vert)),
        dtc.DTA_VertUnit => @bitCast(@as(isize, own.special.vert_unit)),
        dtc.DTA_TopHoriz => @bitCast(@as(isize, own.special.top_horiz)),
        dtc.DTA_VisibleHoriz => @bitCast(@as(isize, own.special.vis_horiz)),
        dtc.DTA_TotalHoriz => @bitCast(@as(isize, own.special.tot_horiz)),
        dtc.DTA_HorizUnit => @bitCast(@as(isize, own.special.horiz_unit)),
        dtc.DTA_NominalVert => @bitCast(@as(isize, own.nominal_vert)),
        dtc.DTA_NominalHoriz => @bitCast(@as(isize, own.nominal_horiz)),
        dtc.DTA_Name => @intFromPtr(own.name),
        dtc.DTA_Title => @intFromPtr(own.title),
        dtc.DTA_NodeName => @intFromPtr(own.node_name),
        dtc.DTA_ObjName => @intFromPtr(own.obj_name),
        dtc.DTA_ObjAuthor => @intFromPtr(own.obj_author),
        dtc.DTA_ObjAnnotation => @intFromPtr(own.obj_annotation),
        dtc.DTA_ObjCopyright => @intFromPtr(own.obj_copyright),
        dtc.DTA_ObjVersion => @intFromPtr(own.obj_version),
        dtc.DTA_SourceType => own.source_type,
        dtc.DTA_Handle => @intFromPtr(own.handle),
        dtc.DTA_DataType => @intFromPtr(own.data_type),
        dtc.DTA_BaseName => if (own.data_type) |dt| @intFromPtr(dt.header.base_name) else 0,
        dtc.DTA_GroupID => if (own.data_type) |dt| dt.header.group_id else 0,
        dtc.DTA_TextAttr => @intFromPtr(own.text_attr),
        dtc.DTA_TextFont => @intFromPtr(own.text_font),
        dtc.DTA_Methods => @intFromPtr(own.methods),
        dtc.DTA_TriggerMethods => @intFromPtr(own.trigger_methods),
        dtc.DTA_Data => @intFromPtr(own),
        dtc.DTA_ErrorLevel => @bitCast(@as(isize, own.error_level)),
        dtc.DTA_ErrorNumber => @bitCast(@as(isize, own.error_number)),
        dtc.DTA_ErrorString => @intFromPtr(own.error_string),
        dtc.DTA_ObjectID => own.object_id,
        dtc.DTA_UserData => own.user_data,
        dtc.DTA_Busy => own.busy,
        dtc.DTA_Sync => own.sync,
        dtc.DTA_ControlPanel => own.control_panel,
        dtc.DTA_Immediate => own.immediate,
        dtc.DTA_Repeat => own.repeat,
        dtc.DTA_LayoutProc => @intFromPtr(own.layout_proc),
        else => return false,
    };
    return true;
}

/// The class's part of an object, for the library's own calls and for a
/// subclass that asks for `DTA_Data`.
pub fn dataOf(db: *DataTypesBase, o: *Object) ?*Data {
    var storage: usize = 0;
    if (db.intuition_base.GetAttr(dtc.DTA_Data, o, &storage) == 0) return null;
    return @ptrFromInt(storage);
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const db: *DataTypesBase = @ptrFromInt(cl.user_data);
    const ib = db.intuition_base;
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = ib.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const obj: *Object = @ptrFromInt(made);
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, obj);
            own.* = .{ .base = db };
            db.sys_base.InitSemaphore(&own.special.lock);
            _ = setAttrs(db, own, new.attr_list, true);
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            // Nothing goes while the object is being laid out.
            db.sys_base.ObtainSemaphore(&own.special.lock);
            db.sys_base.ReleaseSemaphore(&own.special.lock);
            closeSource(db, own);
            takeString(db, &own.name, null);
            takeString(db, &own.title, null);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(db, own, set.attr_list, false)) changed = 1;
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (getAttr(own, get.attr_id, get.storage)) return 1;
            return ib.SendSuperMessage(cl, o, msg);
        },
        // What the object would like to be, in pixels: its units are
        // what it counts in.
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const width = own.nominal_horiz * own.special.horiz_unit;
            const height = own.nominal_vert * own.special.vert_unit;
            ask.domain = switch (ask.which) {
                gc.GDOMAIN_MINIMUM => .{ .width = 0, .height = 0 },
                gc.GDOMAIN_NOMINAL => .{ .width = width, .height = height },
                else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = gc.GDOMAIN_UNLIMITED },
            };
            return 1;
        },
        // The work is done on a process, because whoever asked may not
        // wait for it.
        gc.GM_LAYOUT => {
            const lay: *gc.GpLayout = @ptrCast(@alignCast(msg));
            return @import("../layout/doasynclayout.zig").DoAsyncLayout(db, o.?, lay);
        },
        // What a format's class answers for itself; here they do
        // nothing, so an object of a class that has not been written yet
        // is still a gadget that behaves.
        dtc.DTM_PROCLAYOUT, dtc.DTM_ASYNCLAYOUT => return 0,
        dtc.DTM_FRAMEBOX => {
            const frame: *dtc.DtFrameBox = @ptrCast(@alignCast(msg));
            frame.frame_info.* = frame.contents_info.*;
            return 1;
        },
        dtc.DTM_REMOVEDTOBJECT,
        dtc.DTM_CLEARSELECTED,
        dtc.DTM_SELECT,
        dtc.DTM_COPY,
        dtc.DTM_WRITE,
        dtc.DTM_GOTO,
        dtc.DTM_TRIGGER,
        dtc.DTM_OBTAINDRAWINFO,
        dtc.DTM_DRAW,
        dtc.DTM_RELEASEDRAWINFO,
        => return 0,
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}

/// datatypesclass made and put on the public list, from gadgetclass.
pub fn make(db: *DataTypesBase) ?*Class {
    const ib = db.intuition_base;
    const cl = ib.MakeClass(dtc.DATATYPESCLASS, classusr.GADGETCLASS, null, @sizeOf(Data)) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(db);
    ib.AddClass(cl);
    return cl;
}
