// SPDX-License-Identifier: MIT
//! NewDTObjectA: an object for what a file holds.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const iffparse = sdk.iffparse;
const clipboard = sdk.devices.clipboard;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const _base = @import("../datatypes_base.zig");
const _type = @import("../type/_type.zig");
const DataTypesBase = _base.DataTypesBase;
const ObtainDataTypeA = @import("../type/obtaindatatypea.zig").ObtainDataTypeA;
const ReleaseDataType = @import("../type/releasedatatype.zig").ReleaseDataType;

/// Makes an object for what a file holds.
///
/// SYNOPSIS:
/// ```zig
/// fn NewDTObjectA(db: *DataTypesBase, name: ?[*:0]const u8, attrs: ?[*]const utility.TagItem) ?*classusr.Object
/// ```
///
/// SINCE: 1.0; `DTST_MEMORY` 1.2; `DTST_RAM` 1.5. LVO -28.
///
/// INPUTS:
/// - `name` - the file's name, or null when `DTA_Handle` says where the
///   contents are. For bytes in memory, the name they would have as a
///   file, or null. For an empty object, the name it is known by, or
///   null.
/// - `attrs` - `DTA_SourceType` (`DTST_FILE` unless given),
///   `DTA_GroupID` to refuse anything of another group, `DTA_Handle`,
///   `DTA_SourceSize` for memory, `DTA_BaseName` for an empty object of
///   a class of its own, and any attribute of the object's own class.
///   `GA_Left` and its like place the object in the window it will be
///   added to.
///
/// RESULT:
/// The object, or null with `IoErr` saying why:
/// `DTERROR_UNKNOWN_DATATYPE` when nothing recognises the file or its
/// class cannot be loaded, `DTERROR_COULDNT_OPEN` when the file cannot
/// be opened or its class does not read from memory,
/// `ERROR_OBJECT_WRONG_TYPE` when it is not of the group that was asked
/// for, `ERROR_REQUIRED_ARG_MISSING` when bytes in memory come without
/// their size or an empty object without a group or a class,
/// `ERROR_BAD_NUMBER` for an empty object of a group with no class of
/// its own, `ERROR_NOT_IMPLEMENTED` for any other source type.
///
/// BEHAVIOR:
/// The file is recognised (`ObtainDataTypeA`), its class library is
/// opened and the object is made of that class. From then on the object
/// owns the source: the lock for a file, the open handle for the
/// clipboard, and it closes them when it is disposed of.
///
/// `DTST_CLIPBOARD` takes the clipboard's unit number in place of a
/// name, and the object reads the IFF that is on it.
///
/// `DTST_MEMORY` takes bytes a program holds - a picture a song's tags
/// carry, one fetched over the network - with `DTA_Handle` the first of
/// them and `DTA_SourceSize` how many. They are recognised as a file's
/// are (`ObtainDataTypeA`), by `name` too when one is given, and the
/// object reads them while it is made: once this returns they are the
/// caller's again, to free or to change.
///
/// `DTST_RAM` reads nothing: the object is an empty one, to be filled
/// by the program and written out with `DTM_WRITE`. It is made of the
/// class `DTA_BaseName` names - `png` makes a png.datatype object,
/// which writes a PNG for `DTWM_RAW` - or else of the group's own:
/// `ascii` for `GID_TEXT`, `document`, `sound`, `instrument`, `music`,
/// `picture`, `animation`, `movie`, `model` for the others. No
/// descriptor is asked, and the object has none (`DTA_DataType` is
/// null).
///
/// The class library is closed again straight away. It stays loaded
/// because it has an object, and goes when the last one is disposed of.
///
/// CONTEXT:
/// - Waits: on the file, for memory, and for the class library to load.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: needed - a file is reached through dos, and a class is
///   loaded through it.
///
/// OWNERSHIP:
/// The object is the caller's, to give back with `DisposeDTObject`.
/// `name` is copied; bytes in memory are read and not kept.
///
/// NOTES:
/// - The object is a gadget: it is not shown until `AddDTObject` puts it
///   in a window, or until a layout it was put in is laid out.
/// - Whether a class can be made empty is the class's to say: a class
///   that cannot answers no object, `DTERROR_COULDNT_OPEN`. picture.
///   datatype can; png.datatype since 1.3.
/// - The classes that read the whole of their source at once read from
///   memory: JPEG, PNG, GIF, BMP, text, models, Markdown, HTML, Lottie.
///   ILBM, 8SVX and the sound of an audio codec read a file as they go,
///   and a font's sizes are files beside its contents file: they refuse
///   bytes in memory with `DTERROR_COULDNT_OPEN`.
///
/// SEE ALSO:
/// `DisposeDTObject`, `AddDTObject`, `ObtainDataTypeA`
///
/// EXAMPLES:
/// ```zig
/// const picture = dt.NewDTObjectA("SYS:Tests/a.iff", &.{
///     .{ .tag = gc.GA_Left, .data = 4 },
///     .{ .tag = gc.GA_Top, .data = 4 },
///     .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_PICTURE },
///     .{},
/// }) orelse return;
/// defer dt.DisposeDTObject(picture);
///
/// // A picture held in memory, `bytes` long.
/// const cover = dt.NewDTObjectA(null, &.{
///     .{ .tag = dtc.DTA_SourceType, .data = dtc.DTST_MEMORY },
///     .{ .tag = dtc.DTA_Handle, .data = @intFromPtr(bytes.ptr) },
///     .{ .tag = dtc.DTA_SourceSize, .data = bytes.len },
///     .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_PICTURE },
///     .{},
/// }) orelse return;
/// defer dt.DisposeDTObject(cover);
///
/// // An empty picture, filled and saved as an IFF ILBM.
/// const empty = dt.NewDTObjectA(null, &.{
///     .{ .tag = dtc.DTA_SourceType, .data = dtc.DTST_RAM },
///     .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_PICTURE },
///     .{},
/// }) orelse return;
/// defer dt.DisposeDTObject(empty);
/// ```
pub fn NewDTObjectA(db: *DataTypesBase, name: ?[*:0]const u8, attrs: ?[*]const utility.TagItem) ?*classusr.Object {
    const sys = db.sys_base;
    const dl = db.dos_base;
    const ub = db.utility_base;
    const ib = db.intuition_base;
    const source_type: u32 = @truncate(ub.GetTagData(dtc.DTA_SourceType, dtc.DTST_FILE, attrs));
    const wanted_group: u32 = @truncate(ub.GetTagData(dtc.DTA_GroupID, 0, attrs));

    var handle: ?*anyopaque = @ptrFromInt(ub.GetTagData(dtc.DTA_Handle, 0, attrs));
    var dt: ?*datatypes.DataType = @ptrFromInt(ub.GetTagData(dtc.DTA_DataType, 0, attrs));
    var lock: ?*dos.FileLock = null;
    var iff: ?*iffparse.IFFHandle = null;

    if (dt == null and source_type == dtc.DTST_RAM) return empty(db, name, wanted_group, attrs);
    if (dt == null) {
        switch (source_type) {
            dtc.DTST_FILE => {
                const file_name = name orelse {
                    _ = dl.SetIoErr(dos.ERROR_REQUIRED_ARG_MISSING);
                    return null;
                };
                const given: ?*dos.FileLock = @ptrCast(@alignCast(handle));
                lock = given orelse dl.Lock(file_name, dos.SHARED_LOCK) orelse {
                    _ = dl.SetIoErr(datatypes.DTERROR_COULDNT_OPEN);
                    return null;
                };
                dt = ObtainDataTypeA(db, source_type, lock, attrs);
                handle = lock;
            },
            dtc.DTST_MEMORY => {
                if (handle == null or ub.GetTagData(dtc.DTA_SourceSize, 0, attrs) == 0) {
                    _ = dl.SetIoErr(dos.ERROR_REQUIRED_ARG_MISSING);
                    return null;
                }
                // The name, when there is one, is matched as a file's.
                const named = [_]utility.TagItem{
                    .{ .tag = if (name != null) dtc.DTA_Name else utility.TAG_IGNORE, .data = @intFromPtr(name) },
                    .{ .tag = utility.TAG_MORE, .data = @intFromPtr(attrs) },
                };
                dt = ObtainDataTypeA(db, source_type, handle, &named);
            },
            dtc.DTST_CLIPBOARD => {
                const unit: u32 = if (name) |text| unitOf(text) else clipboard.PRIMARY_CLIP;
                iff = openClip(db, unit) orelse {
                    _ = dl.SetIoErr(datatypes.DTERROR_COULDNT_OPEN_CLIPBOARD);
                    return null;
                };
                dt = ObtainDataTypeA(db, source_type, iff, attrs);
                handle = iff;
            },
            else => {
                _ = dl.SetIoErr(dos.ERROR_NOT_IMPLEMENTED);
                return null;
            },
        }
    }

    const kind = dt orelse {
        closeAll(db, lock, iff);
        return null;
    };
    if (wanted_group != 0 and kind.header.group_id != wanted_group) {
        ReleaseDataType(db, kind);
        closeAll(db, lock, iff);
        _ = dl.SetIoErr(dos.ERROR_OBJECT_WRONG_TYPE);
        return null;
    }

    var class_name: [64]u8 = @splat(0);
    if (!_type.className(kind.header.base_name, &class_name)) {
        ReleaseDataType(db, kind);
        closeAll(db, lock, iff);
        _ = dl.SetIoErr(datatypes.DTERROR_UNKNOWN_DATATYPE);
        return null;
    }
    const lib = sys.OpenLibrary(@ptrCast(&class_name), 0) orelse {
        ReleaseDataType(db, kind);
        closeAll(db, lock, iff);
        _ = dl.SetIoErr(datatypes.DTERROR_UNKNOWN_DATATYPE);
        return null;
    };
    // Closed again at once: the class stays loaded while it has an
    // object, and goes with the last of them.
    defer sys.CloseLibrary(lib);

    const first = [_]utility.TagItem{
        .{ .tag = dtc.DTA_Name, .data = @intFromPtr(name) },
        .{ .tag = dtc.DTA_DataType, .data = @intFromPtr(kind) },
        .{ .tag = dtc.DTA_Handle, .data = @intFromPtr(handle) },
        .{ .tag = dtc.DTA_SourceType, .data = source_type },
        .{ .tag = if (kind.attrs != null) utility.TAG_MORE else utility.TAG_IGNORE, .data = @intFromPtr(kind.attrs) },
        .{ .tag = utility.TAG_MORE, .data = @intFromPtr(attrs) },
    };
    const object = ib.NewObjectTagList(null, @ptrCast(&class_name[datatypes.class_prefix.len]), &first) orelse {
        ReleaseDataType(db, kind);
        closeAll(db, lock, iff);
        if (dl.IoErr() == 0) _ = dl.SetIoErr(datatypes.DTERROR_COULDNT_OPEN);
        return null;
    };
    return object;
}

/// An empty object (`DTST_RAM`): of the class `DTA_BaseName` names, or
/// of the group's own, with no source and no descriptor.
fn empty(db: *DataTypesBase, name: ?[*:0]const u8, group: u32, attrs: ?[*]const utility.TagItem) ?*classusr.Object {
    const sys = db.sys_base;
    const dl = db.dos_base;
    const ub = db.utility_base;
    const named: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(dtc.DTA_BaseName, 0, attrs));
    const base_name = named orelse (if (group != 0) _type.groupClass(group) else null) orelse {
        _ = dl.SetIoErr(if (group != 0) dos.ERROR_BAD_NUMBER else dos.ERROR_REQUIRED_ARG_MISSING);
        return null;
    };
    var class_name: [64]u8 = @splat(0);
    if (!_type.className(base_name, &class_name)) {
        _ = dl.SetIoErr(datatypes.DTERROR_UNKNOWN_DATATYPE);
        return null;
    }
    const lib = sys.OpenLibrary(@ptrCast(&class_name), 0) orelse {
        _ = dl.SetIoErr(datatypes.DTERROR_UNKNOWN_DATATYPE);
        return null;
    };
    defer sys.CloseLibrary(lib);
    const first = [_]utility.TagItem{
        .{ .tag = dtc.DTA_Name, .data = @intFromPtr(name) },
        .{ .tag = dtc.DTA_SourceType, .data = dtc.DTST_RAM },
        .{ .tag = utility.TAG_MORE, .data = @intFromPtr(attrs) },
    };
    _ = dl.SetIoErr(0);
    return db.intuition_base.NewObjectTagList(null, @ptrCast(&class_name[datatypes.class_prefix.len]), &first) orelse {
        if (dl.IoErr() == 0) _ = dl.SetIoErr(datatypes.DTERROR_COULDNT_OPEN);
        return null;
    };
}

/// The unit number a clipboard name says, 0 when it says nothing.
fn unitOf(text: [*:0]const u8) u32 {
    var value: u32 = 0;
    var i: usize = 0;
    while (text[i] >= '0' and text[i] <= '9') : (i += 1) value = value * 10 + (text[i] - '0');
    return value;
}

/// The clipboard opened and walked as far as its first form, ready to
/// be recognised and then read by the object.
fn openClip(db: *DataTypesBase, unit: u32) ?*iffparse.IFFHandle {
    const ip = db.iffparse_base;
    const iff = ip.AllocIFF() orelse return null;
    const clip = ip.OpenClipboard(unit) orelse {
        ip.FreeIFF(iff);
        return null;
    };
    iff.stream = @intFromPtr(clip);
    ip.InitIFFasClip(iff);
    if (ip.OpenIFF(iff, iffparse.IFFF_READ) != 0 or ip.ParseIFF(iff, iffparse.IFFPARSE_STEP) != 0) {
        ip.CloseIFF(iff);
        ip.CloseClipboard(clip);
        ip.FreeIFF(iff);
        return null;
    }
    return iff;
}

fn closeAll(db: *DataTypesBase, lock: ?*dos.FileLock, iff: ?*iffparse.IFFHandle) void {
    if (lock) |it| db.dos_base.UnLock(it);
    if (iff) |it| {
        const ip = db.iffparse_base;
        const clip: ?*iffparse.ClipboardHandle = @ptrFromInt(it.stream);
        ip.CloseIFF(it);
        ip.CloseClipboard(clip);
        ip.FreeIFF(it);
    }
}
