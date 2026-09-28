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
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `name` - the file's name, or null when `DTA_Handle` says where the
///   contents are.
/// - `attrs` - `DTA_SourceType` (`DTST_FILE` unless given),
///   `DTA_GroupID` to refuse anything of another group, `DTA_Handle`,
///   and any attribute of the object's own class. `GA_Left` and its
///   like place the object in the window it will be added to.
///
/// RESULT:
/// The object, or null with `IoErr` saying why:
/// `DTERROR_UNKNOWN_DATATYPE` when nothing recognises the file or its
/// class cannot be loaded, `DTERROR_COULDNT_OPEN` when the file cannot
/// be opened, `ERROR_OBJECT_WRONG_TYPE` when it is not of the group
/// that was asked for.
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
/// The class library is closed again straight away. It stays loaded
/// because it has an object, and goes when the last one is disposed of.
///
/// CONTEXT:
/// - Waits: on the file, for memory, and for the class library to load.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: needed - the file is reached through dos.
///
/// OWNERSHIP:
/// The object is the caller's, to give back with `DisposeDTObject`.
/// `name` is copied.
///
/// NOTES:
/// The object is a gadget: it is not shown until `AddDTObject` puts it
/// in a window, or until a layout it was put in is laid out.
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
