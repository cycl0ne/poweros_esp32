// SPDX-License-Identifier: MIT
//! obj.datatype: a Wavefront OBJ file, the plain-text form most programs
//! that make models write, as a model.
//!
//! A model.datatype subclass, and a reader only: the file is read
//! (`parse.zig`) into its vertices and triangles, its MTL into the
//! materials they name, and everything is handed to the superclass in
//! `OM_NEW` - the header first, which gives the object the memory, then
//! the vertices, the indices, the materials and the parts, a run of one
//! material each. A material's picture (`map_Kd`) is opened through the
//! picture datatypes, whatever its format, and handed over as it is.
//! What is drawn, and how, is the superclass's.
//!
//! The MTL and the pictures are named in the file from the file's own
//! directory, often as another system writes a name; one that is not
//! there is looked for beside the file under its last part, and one not
//! there either leaves its material the colour alone.
//!
//! The library's recognise call looks at the first bytes of a text, the
//! ones datatypes.library has already read, for OBJ's lines: `.obj` is
//! also what a compiler names its object files, and they are not models.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gadgets = sdk.gadgets;
const datatypes = sdk.datatypes;
const subclass = datatypes.subclass;
const dtc = datatypes.datatypesclass;
const mdt = datatypes.modelclass;
const parse = @import("parse.zig");
const DosBase = sdk.interface.dos.DosBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const ExecBase = sdk.interface.exec.ExecBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Base = gadgets.Base;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
/// Its one call, after the standard four, is the recognise function
/// datatypes.library asks. datatypes.library to open the pictures with,
/// dos for the files.
pub const Library = gadgets.ClassLibrary(.{
    .name = "obj.datatype",
    .version = 1,
    .date = "20.10.2026",
    .super = mdt.MODELDTCLASS,
    .opens = &.{ mdt.MODEL_LIBRARY, datatypes.DATATYPESNAME, dos.DOSNAME },
    .Instance = Data,
    .dispatch = dispatch,
    .functions = &.{exec.libraries.vec(recognise)},
});
comptime {
    _ = Library;
}

const opened_datatypes = 1;
const opened_dos = 2;

comptime {
    // The vertices are handed over as they are read.
    if (@sizeOf(parse.Vertex) != @sizeOf(mdt.ModelVertex) or
        @offsetOf(parse.Vertex, "normal") != @offsetOf(mdt.ModelVertex, "normal") or
        @offsetOf(parse.Vertex, "uv") != @offsetOf(mdt.ModelVertex, "uv"))
        @compileError("parse.Vertex is not a ModelVertex");
}

/// obj.datatype's part of an object: nothing. The model is the
/// superclass's the moment it has been read.
pub const Data = extern struct {
    unused: u32 = 0,
};

/// The longest name of a file it opens, its directory's with it.
const path_bytes = 512;
/// When the bytes datatypes.library read are comments and nothing else,
/// this much more is looked at before saying no.
const recognise_more = 4096;

fn dosOf(base: *Base) *DosBase {
    return @ptrCast(base.opened[opened_dos].?);
}

fn datatypesOf(base: *Base) *DataTypesBase {
    return @ptrCast(base.opened[opened_datatypes].?);
}

/// A file named in the model's file, from `dir`, the model's directory:
/// as it is written, and failing that, under its last part, beside the
/// model. Into `path`; false when neither fits.
const Named = struct {
    dir: *dos.FileLock,
    name: []const u8,
    tried: u8 = 0,

    fn next(named: *Named, dl: *DosBase, path: *[path_bytes:0]u8) bool {
        while (named.tried < 2) {
            const which = named.tried;
            named.tried += 1;
            var name = named.name;
            if (which == 1) {
                const last = std.mem.lastIndexOfAny(u8, name, "/\\:") orelse continue;
                name = name[last + 1 ..];
            }
            @memset(path, 0);
            if (!dl.NameFromLock(named.dir, path, path_bytes)) return false;
            var written: [path_bytes:0]u8 = @splat(0);
            const made = parse.portable(name, &written) orelse continue;
            if (made.len == 0) continue;
            if (dl.AddPart(path, &written, path_bytes)) return true;
        }
        return false;
    }
};

/// The MTL the model names, read whole; null when there is none to read.
fn readLibrary(sys: *ExecBase, dl: *DosBase, dir: *dos.FileLock, name: []const u8) ?[]u8 {
    if (name.len == 0) return null;
    var named = Named{ .dir = dir, .name = name };
    var path: [path_bytes:0]u8 = @splat(0);
    while (named.next(dl, &path)) {
        const lock = dl.Lock(&path, dos.SHARED_LOCK) orelse continue;
        defer dl.UnLock(lock);
        switch (subclass.readWhole(sys, dl, lock)) {
            .got => |text| return text,
            else => {},
        }
    }
    return null;
}

/// The picture a material names, as a picture.datatype object; null when
/// it could not be opened as one.
fn openPicture(base: *Base, dir: *dos.FileLock, name: []const u8) ?*Object {
    if (name.len == 0) return null;
    const dl = dosOf(base);
    var named = Named{ .dir = dir, .name = name };
    var path: [path_bytes:0]u8 = @splat(0);
    while (named.next(dl, &path)) {
        if (datatypesOf(base).NewDTObjectA(&path, &[_]TagItem{
            .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_PICTURE },
            .{},
        })) |picture| return picture;
    }
    return null;
}

/// A colour of three from 0 to 1 as a pen.
fn penOf(diffuse: [3]f32) graphics.Pen {
    var pen: graphics.Pen = 0xFF00_0000;
    for (diffuse, 0..) |value, k| {
        const byte: u32 = @intFromFloat(@min(@max(value, 0), 1) * 255 + 0.5);
        pen |= byte << @intCast(16 - 8 * k);
    }
    return pen;
}

/// The file read and handed to the superclass. What went wrong, or 0.
fn readFile(base: *Base, cl: *Class, o: *Object, text: []const u8, dir: ?*dos.FileLock) i32 {
    const sys = base.sys_base;
    const ib = base.intuition_base;
    const dl = dosOf(base);
    const sizes = parse.count(text) catch return datatypes.DTERROR_INVALID_DATA;
    if (!subclass.roomFor(sys, sizes.bytes())) return datatypes.DTERROR_TOO_LARGE;
    const memory = sys.AllocVec(sizes.bytes(), exec.MEMF_ANY) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(memory);
    const model = parse.read(text, sizes, @ptrCast(@alignCast(memory))) catch return datatypes.DTERROR_INVALID_DATA;

    // The materials, if the file names a library of them and it is there.
    const library: ?[]u8 = if (dir) |d| readLibrary(sys, dl, d, model.library) else null;
    defer if (library) |bytes| sys.FreeVec(bytes.ptr);
    var materials: []parse.Material = &.{};
    var material_memory: ?*anyopaque = null;
    defer sys.FreeVec(material_memory);
    if (library) |bytes| {
        const found = parse.countMaterials(bytes);
        if (found != 0) {
            material_memory = sys.AllocVec(found * @sizeOf(parse.Material), exec.MEMF_ANY) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
            const first: [*]parse.Material = @ptrCast(@alignCast(material_memory));
            materials = first[0..found];
            parse.readMaterials(bytes, materials);
        }
    }

    const header = mdt.ModelHeader{
        .vertices = @intCast(model.vertices.len),
        .indices = @intCast(model.indices.len),
        .materials = @intCast(materials.len),
        .parts = @intCast(model.runs.len),
        .low = model.low,
        .high = model.high,
    };
    subclass.superTell(ib, cl, o, &[_]TagItem{ .{ .tag = mdt.MDTA_ModelHeader, .data = @intFromPtr(&header) }, .{} });
    if (subclass.superAsk(ib, cl, o, mdt.MDTA_ModelHeader) == 0) return datatypes.DTERROR_NOT_ENOUGH_DATA;

    var vertices = mdt.MdtWriteVertices{ .vertices = @ptrCast(model.vertices.ptr), .first = 0, .count = header.vertices };
    _ = ib.SendSuperMessage(cl, o, @ptrCast(&vertices));
    var indices = mdt.MdtWriteIndices{ .indices = model.indices.ptr, .first = 0, .count = header.indices };
    _ = ib.SendSuperMessage(cl, o, @ptrCast(&indices));
    for (materials, 0..) |material, k| {
        var write = mdt.MdtWriteMaterial{
            .material = @intCast(k),
            .color = penOf(material.diffuse),
            .picture = if (dir) |d| openPicture(base, d, material.picture) else null,
        };
        _ = ib.SendSuperMessage(cl, o, @ptrCast(&write));
    }
    for (model.runs, 0..) |run, k| {
        const material: u32 = if (parse.find(materials, run.material)) |found|
            @intCast((@intFromPtr(found) - @intFromPtr(materials.ptr)) / @sizeOf(parse.Material))
        else
            mdt.NO_MATERIAL;
        var write = mdt.MdtWritePart{ .part = @intCast(k), .first = run.first, .count = run.count, .material = material };
        _ = ib.SendSuperMessage(cl, o, @ptrCast(&write));
    }
    return 0;
}

/// datatypes.library's question: whether the text's first lines are a
/// model's.
fn recognise(base: *Base, context: *datatypes.DTHookContext) callconv(.c) bool {
    const start = context.buffer orelse return false;
    const length = context.buffer_length;
    const size: u64 = if (context.fib) |fib| fib.size else length;
    switch (parse.looks(start[0..length], size <= length)) {
        .model => return true,
        .not => return false,
        .unsure => {},
    }
    // A long comment at the top: a little further, from the file.
    const file = context.file orelse return false;
    const dl: *DosBase = @ptrCast(@alignCast(context.dos_base));
    const sys = base.sys_base;
    const memory = sys.AllocVec(recognise_more, exec.MEMF_ANY) orelse return false;
    defer sys.FreeVec(memory);
    const bytes: [*]u8 = @ptrCast(memory);
    const got = dl.Read(file, bytes, recognise_more);
    if (got <= 0) return false;
    const read: usize = @intCast(got);
    return parse.looks(bytes[0..read], size <= read) == .model;
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const base = gadgets.baseOf(cl);
    const ib = base.intuition_base;
    const sys = base.sys_base;
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = ib.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const obj: *Object = @ptrFromInt(made);
            classes.instData(Data, cl, obj).* = .{};
            const dl = dosOf(base);
            const lock: ?*dos.FileLock = @ptrFromInt(subclass.superAsk(ib, cl, obj, dtc.DTA_Handle));
            const text = switch (subclass.readWhole(sys, dl, lock)) {
                .got => |read| read,
                .too_large => {
                    _ = dl.SetIoErr(datatypes.DTERROR_TOO_LARGE);
                    ib.DisposeObject(obj);
                    return 0;
                },
                .no_file => {
                    _ = dl.SetIoErr(datatypes.DTERROR_COULDNT_OPEN);
                    ib.DisposeObject(obj);
                    return 0;
                },
            };
            defer sys.FreeVec(text.ptr);
            const dir = dl.ParentDir(lock);
            defer dl.UnLock(dir);
            const failure = readFile(base, cl, obj, text, dir);
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
