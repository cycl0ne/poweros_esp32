// SPDX-License-Identifier: MIT
//! ilbm.datatype: an IFF `ILBM` as a picture.
//!
//! A picture.datatype subclass. It walks the form in `OM_NEW` - what the
//! picture is (`BMHD`), its palette (`CMAP`), what the machine's display
//! was set to (`CAMG`) and the rows themselves (`BODY`) - and hands the
//! pixels to its superclass; everything after that is the superclass's.
//!
//! **The walk is iffparse's.** The chunks that say what the picture is
//! are asked for as properties and the rows are stopped on, so the form
//! is read once and in one pass, and a `LIST` whose properties stand
//! outside the form is read the same way as a plain `FORM`.
//!
//! That is also what lets a picture be read straight off the clipboard:
//! there the object is handed an IFF stream that is already open, and
//! the only difference is that this class does not open or close it.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gadgets = sdk.gadgets;
const iffparse = sdk.iffparse;
const datatypes = sdk.datatypes;
const subclass = datatypes.subclass;
const dtc = datatypes.datatypesclass;
const pic = datatypes.pictureclass;
const planes = @import("planes.zig");
const IFFParseBase = sdk.interface.iffparse.IFFParseBase;
const DosBase = sdk.interface.dos.DosBase;
const Class = classes.Class;
const Object = classes.Object;
const Base = gadgets.Base;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = "ilbm.datatype",
    .version = 1,
    .date = "29.09.2026",
    .super = pic.PICTUREDTCLASS,
    .opens = &.{ pic.PICTURE_LIBRARY, iffparse.IFFPARSENAME },
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// ilbm.datatype's part of an object: nothing. The picture is the
/// superclass's the moment it has been read.
pub const Data = extern struct {
    unused: u32 = 0,
};

const ID_CAMG = iffparse.MakeID("CAMG");

/// The largest palette a file may hold, which is what eight planes
/// reach.
const max_colors = 256;

/// A two-byte number as the file holds it, high byte first.
fn half(from: [*]const u8) u16 {
    return @as(u16, from[0]) << 8 | from[1];
}

/// `BMHD` read into the header every picture has.
fn readHeader(from: []const u8) ?pic.BitMapHeader {
    if (from.len < 20) return null;
    return .{
        .width = half(from.ptr),
        .height = half(from.ptr + 2),
        .left = @bitCast(half(from.ptr + 4)),
        .top = @bitCast(half(from.ptr + 6)),
        .depth = from[8],
        .masking = from[9],
        .compression = from[10],
        .transparent = half(from.ptr + 12),
        .x_aspect = from[14],
        .y_aspect = from[15],
        .page_width = @bitCast(half(from.ptr + 16)),
        .page_height = @bitCast(half(from.ptr + 18)),
    };
}

/// What the form says, read once through iffparse and then the rows.
/// What went wrong, or 0.
fn readForm(base: *Base, cl: *Class, o: *Object, ip: *IFFParseBase, iff: *iffparse.IFFHandle) i32 {
    const sys = base.sys_base;
    const ib = base.intuition_base;

    // What the picture is, its colours and what the display was set to
    // are kept as the walk goes past them; the rows stop it.
    _ = ip.PropChunk(iff, pic.ID_ILBM, pic.ID_BMHD);
    _ = ip.PropChunk(iff, pic.ID_ILBM, pic.ID_CMAP);
    _ = ip.PropChunk(iff, pic.ID_ILBM, ID_CAMG);
    _ = ip.StopChunk(iff, pic.ID_ILBM, pic.ID_BODY);
    if (ip.ParseIFF(iff, iffparse.IFFPARSE_SCAN) != 0) return datatypes.DTERROR_INVALID_DATA;

    const said = ip.FindProp(iff, pic.ID_ILBM, pic.ID_BMHD) orelse
        return datatypes.DTERROR_INVALID_DATA;
    const header = readHeader(@as([*]const u8, @ptrCast(said.data))[0..@intCast(said.size)]) orelse
        return datatypes.DTERROR_INVALID_DATA;
    if (header.width == 0 or header.height == 0) return datatypes.DTERROR_INVALID_DATA;
    if (header.depth == 0 or header.depth > 32) return datatypes.DTERROR_INVALID_DATA;
    if (header.compression > pic.cmpByteRun1) return datatypes.DTERROR_UNKNOWN_COMPRESSION;

    var palette: [max_colors]pic.ColorRegister = @splat(.{});
    var colors: u32 = 0;
    if (ip.FindProp(iff, pic.ID_ILBM, pic.ID_CMAP)) |cmap| {
        const bytes: [*]const u8 = @ptrCast(cmap.data);
        colors = @min(@as(u32, @intCast(cmap.size)) / 3, max_colors);
        for (0..colors) |i| {
            palette[i] = .{ .red = bytes[i * 3], .green = bytes[i * 3 + 1], .blue = bytes[i * 3 + 2] };
        }
    }
    var mode: u32 = 0;
    if (ip.FindProp(iff, pic.ID_ILBM, ID_CAMG)) |camg| {
        if (camg.size >= 4) {
            const bytes: [*]const u8 = @ptrCast(camg.data);
            mode = @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 |
                @as(u32, bytes[2]) << 8 | bytes[3];
        }
    }

    const width: u32 = header.width;
    const height: u32 = header.height;
    const depth: u32 = header.depth;
    // A mask is a plane of its own on every row, read and passed over:
    // what it says is already in the transparent colour or the alpha.
    const rows_planes = depth + @as(u32, if (header.masking == pic.mskHasMask) 1 else 0);
    const stride = planes.planeStride(width);
    const transparent: ?u32 = if (header.masking == pic.mskHasTransparentColor) header.transparent else null;

    // The whole `BODY`, because a packed row says how long it is only by
    // being unpacked, and the rows are read one after another anyway.
    const chunk = ip.CurrentChunk(iff) orelse return datatypes.DTERROR_INVALID_DATA;
    if (chunk.id != pic.ID_BODY or chunk.size <= 0) return datatypes.DTERROR_NOT_ENOUGH_DATA;
    const body_size: usize = @intCast(chunk.size);
    const body_memory = sys.AllocVec(body_size, exec.MEMF_ANY) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(body_memory);
    const body: [*]u8 = @ptrCast(body_memory);
    if (ip.ReadChunkBytes(iff, body, chunk.size) != chunk.size) return datatypes.DTERROR_NOT_ENOUGH_DATA;

    // Room for one row: its planes, the numbers they make and the
    // colour they come to.
    const row_memory = sys.AllocVec(rows_planes * stride, exec.MEMF_ANY) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(row_memory);
    const row: [*]u8 = @ptrCast(row_memory);
    const number_memory = sys.AllocVec(width * @sizeOf(u32), exec.MEMF_ANY) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(number_memory);
    const numbers: [*]u32 = @ptrCast(@alignCast(number_memory));
    const colour_memory = sys.AllocVec(width * 4, exec.MEMF_ANY) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(colour_memory);
    const colour: [*]u8 = @ptrCast(colour_memory);

    const alpha = depth >= 32 or transparent != null;
    if (!subclass.setPicture(ib, cl, o, &header, if (alpha) pic.PBPAFMT_RGBA else pic.PBPAFMT_LUT8)) {
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    }

    var at: usize = 0;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        if (header.compression == pic.cmpByteRun1) {
            var plane: u32 = 0;
            while (plane < rows_planes) : (plane += 1) {
                const took = planes.unpackRow(body[at..body_size], (row + plane * stride)[0..stride]) catch break;
                at += took;
            }
        } else {
            const want = rows_planes * stride;
            if (at + want > body_size) break;
            @memcpy(row[0..want], body[at..][0..want]);
            at += want;
        }
        planes.gather(row[0 .. rows_planes * stride], stride, depth, width, numbers[0..width]);
        planes.toRGBA(numbers[0..width], width, depth, mode, palette[0..colors], transparent, colour[0 .. width * 4]);
        subclass.putRow(ib, cl, o, 0, y, width, colour);
    }
    return 0;
}

/// The object's own source walked: a file opened from its lock, or the
/// clipboard stream it was handed.
fn readSource(base: *Base, cl: *Class, o: *Object, dl: *DosBase, ip: *IFFParseBase) i32 {
    const ib = base.intuition_base;
    const source = subclass.superAsk(ib, cl, o, dtc.DTA_SourceType);
    const handle: ?*anyopaque = @ptrFromInt(subclass.superAsk(ib, cl, o, dtc.DTA_Handle));

    if (source == dtc.DTST_CLIPBOARD) {
        const iff: *iffparse.IFFHandle = @ptrCast(@alignCast(handle orelse
            return datatypes.DTERROR_COULDNT_OPEN));
        return readForm(base, cl, o, ip, iff);
    }

    const lock: ?*dos.FileLock = @ptrCast(@alignCast(handle));
    const copy = dl.DupLock(lock orelse return datatypes.DTERROR_COULDNT_OPEN) orelse
        return datatypes.DTERROR_COULDNT_OPEN;
    const file = dl.OpenFromLock(copy) orelse {
        dl.UnLock(copy);
        return datatypes.DTERROR_COULDNT_OPEN;
    };
    defer _ = dl.Close(file);

    const iff = ip.AllocIFF() orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer ip.FreeIFF(iff);
    iff.stream = @intFromPtr(file);
    ip.InitIFFasDOS(iff);
    if (ip.OpenIFF(iff, iffparse.IFFF_READ) != 0) return datatypes.DTERROR_COULDNT_OPEN;
    defer ip.CloseIFF(iff);
    return readForm(base, cl, o, ip, iff);
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
            const dos_lib = base.sys_base.OpenLibrary(dos.DOSNAME, 0) orelse {
                ib.DisposeObject(obj);
                return 0;
            };
            const dl: *DosBase = @ptrCast(dos_lib);
            defer base.sys_base.CloseLibrary(dos_lib);
            const ip: *IFFParseBase = @ptrCast(base.opened[1] orelse {
                ib.DisposeObject(obj);
                return 0;
            });

            const failure = readSource(base, cl, obj, dl, ip);
            if (failure != 0) {
                _ = dl.SetIoErr(failure);
                ib.DisposeObject(obj);
                return 0;
            }
            return made;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
