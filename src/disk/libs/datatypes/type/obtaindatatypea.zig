// SPDX-License-Identifier: MIT
//! ObtainDataTypeA: what kind of file something is.

const sdk = @import("sdk");
const utility = sdk.utility;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const dos = sdk.dos;
const _base = @import("../datatypes_base.zig");
const _type = @import("_type.zig");
const DataTypesBase = _base.DataTypesBase;

/// Says what kind of file something is.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainDataTypeA(db: *DataTypesBase, source_type: u32, handle: ?*anyopaque, attrs: ?[*]const utility.TagItem) ?*datatypes.DataType
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `source_type` - `DTST_FILE` with a `*dos.FileLock` as the handle,
///   or `DTST_CLIPBOARD` with an `*IFFHandle` already opened for
///   reading and walked as far as its first form.
/// - `handle` - the lock or the handle.
/// - `attrs` - `DTA_GroupID` refuses anything not of that group; null
///   for no conditions.
///
/// RESULT:
/// The data type, or null when nothing recognises it - `IoErr` is then
/// `DTERROR_UNKNOWN_DATATYPE` - or when `C:AddDataTypes` has not run.
///
/// BEHAVIOR:
/// The descriptors are tried in the order they were sorted into, highest
/// priority first, and the first that matches wins. A descriptor
/// matches on the type of the file's outermost IFF form, on the bytes
/// it starts with, on its name, or on all of those; one that says none
/// of them catches whatever is left of its kind, which is how plain
/// text and plain bytes are named at the end.
///
/// A descriptor whose class knows how to tell (`RECOGNISE`) has its
/// class library opened and asked, but only after everything else it
/// says has already matched.
///
/// The file is opened and read once and every descriptor is tried
/// against that one reading.
///
/// CONTEXT:
/// - Waits: on the file, and on the list's lock.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: needed - the file is reached through dos.
///
/// OWNERSHIP:
/// The lock or handle stays the caller's. What is answered is the
/// system's and is held until `ReleaseDataType`; a descriptor being
/// held cannot be taken off the list.
///
/// NOTES:
/// `NewDTObjectA` does this itself, so a program that only wants to open
/// a file never calls it. It is for a program that wants to know what a
/// file is without reading it - a file requester showing only pictures.
///
/// SEE ALSO:
/// `ReleaseDataType`, `NewDTObjectA`
///
/// EXAMPLES:
/// ```zig
/// const lock = dl.Lock("SYS:Tests/a.iff", dos.SHARED_LOCK) orelse return;
/// defer dl.UnLock(lock);
/// if (dt.ObtainDataTypeA(dtc.DTST_FILE, lock, null)) |kind| {
///     defer dt.ReleaseDataType(kind);
///     // kind.header.name says what it is
/// }
/// ```
pub fn ObtainDataTypeA(db: *DataTypesBase, source_type: u32, handle: ?*anyopaque, attrs: ?[*]const utility.TagItem) ?*datatypes.DataType {
    const sys = db.sys_base;
    const dl = db.dos_base;
    const list = db.list orelse {
        _ = dl.SetIoErr(datatypes.DTERROR_UNKNOWN_DATATYPE);
        return null;
    };
    const wanted_group: u32 = @truncate(db.utility_base.GetTagData(dtc.DTA_GroupID, 0, attrs));

    var source: _type.Source = undefined;
    if (!_type.open(db, &source, source_type, handle)) {
        _ = dl.SetIoErr(datatypes.DTERROR_COULDNT_OPEN);
        return null;
    }
    defer _type.close(db, &source);

    sys.ObtainSemaphoreShared(&list.lock);
    defer sys.ReleaseSemaphore(&list.lock);
    var it = list.all.iterator();
    while (it.next()) |node| {
        const dt: *datatypes.DataType = @fieldParentPtr("node", node);
        if (wanted_group != 0 and dt.header.group_id != wanted_group) continue;
        if (!_type.matches(db, dt, &source)) continue;
        dt.uses += 1;
        return dt;
    }
    _ = dl.SetIoErr(datatypes.DTERROR_UNKNOWN_DATATYPE);
    return null;
}
