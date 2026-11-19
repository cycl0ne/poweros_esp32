// SPDX-License-Identifier: MIT
//! Host tests of paintio.library: the format's parts on their own, and the
//! library made from its ROM tag on the ROM's exec, beside iffparse and
//! compression made from theirs, writing projects to a RAM disk (WORK:)
//! and reading them back through its jump table. A project comes back
//! layer for layer, pixel for pixel; one no file holds is refused before
//! a file is made; a damaged one, a missing one and one that is not a
//! project are refused for their reasons, and leave nothing behind.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const paintio = sdk.paintio;
const host = @import("host_rom");
const kexec = host.exec;
const paintio_init = @import("../paintio_init.zig");
const iffparse_init = @import("../../iffparse/iffparse_init.zig");
const compression_init = @import("../../compression/compression_init.zig");
const _project = @import("../project/_project.zig");

const testing = std.testing;
const DosBase = sdk.interface.dos.DosBase;
const PaintIOBase = sdk.interface.paintio.PaintIOBase;

test {
    _ = @import("../paintio_lvo.zig");
}

// --- the format's parts -----------------------------------------------------------

test "paintio: a header and a layer's header read back as they were written" {
    var layer = paintio.Layer{ .opacity = 0x80, .flags = paintio.LAYERF_HIDDEN };
    @memcpy(layer.name[0..6], "Clouds");
    const project = paintio.Project{ .width = 640, .height = 480, .layer_count = 3, .current = 2 };
    var header: [_project.header_size]u8 = undefined;
    _project.headerBytes(&project, &header);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 2, 128, 0, 0, 1, 224, 0, 0, 0, 3, 0, 0, 0, 2 }, &header);
    var back = paintio.Project{};
    try testing.expect(_project.readHeader(&header, &back));
    try testing.expectEqual(@as(u32, 640), back.width);
    try testing.expectEqual(@as(u32, 480), back.height);
    try testing.expectEqual(@as(u32, 3), back.layer_count);
    try testing.expectEqual(@as(u32, 2), back.current);

    var layer_header: [_project.layer_header_size]u8 = undefined;
    const length = _project.layerHeaderBytes(&layer, &layer_header);
    try testing.expectEqual(@as(usize, 10), length);
    var layer_back = paintio.Layer{};
    _project.readLayerHeader(layer_header[0..length], &layer_back);
    try testing.expectEqual(@as(u8, 0x80), layer_back.opacity);
    try testing.expectEqual(paintio.LAYERF_HIDDEN, layer_back.flags);
    try testing.expectEqualStrings("Clouds", std.mem.sliceTo(&layer_back.name, 0));
}

test "paintio: a header no project has is refused" {
    var project = paintio.Project{};
    const cases = [_][16]u8{
        .{ 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0 }, // no width
        .{ 0, 0, 0x40, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0 }, // too wide
        .{ 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // no layers
        .{ 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 65, 0, 0, 0, 0 }, // too many
        .{ 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 2, 0, 0, 0, 2 }, // past the last
    };
    for (cases) |bytes| try testing.expect(!_project.readHeader(&bytes, &project));
    try testing.expect(!_project.readHeader(&[_]u8{ 0, 0, 1 }, &project));
}

test "paintio: pixels are the bytes alpha, red, green, blue, and back" {
    const pixels = [_]u32{ 0x80FF4020, 0x00000000, 0xFFFFFFFF, 0x01020304 };
    var bytes: [16]u8 = undefined;
    _project.toFile(&pixels, &bytes);
    try testing.expectEqualSlices(u8, &.{ 0x80, 0xFF, 0x40, 0x20, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 1, 2, 3, 4 }, &bytes);
    var back: [4]u32 = undefined;
    @memcpy(std.mem.sliceAsBytes(&back), &bytes);
    _project.fromFile(&back);
    try testing.expectEqualSlices(u32, &pixels, &back);
}

// --- the rig ----------------------------------------------------------------------

/// The RAM disk behind WORK:, answering the test process's packets.
const Disk = struct {
    var port: exec.MsgPort = undefined;
    var disk: host.ram.RamDisk = undefined;
    var dl: *DosBase = undefined;

    fn wait(proc: *dos.Process, sys: *sdk.interface.exec.ExecBase) callconv(.c) *exec.Message {
        const pkt = dos.DosPacket.fromMessage(sys.GetMsg(&port).?);
        const reply = disk.answer(pkt);
        dl.ReplyPkt(pkt, reply.res1, reply.res2);
        return sys.GetMsg(&proc.msg_port).?;
    }
};

/// Memory lent to exec: Deflate's state is larger than the test RAM exec
/// starts with.
var lent: [2 * 1024 * 1024]u8 align(16) = undefined;

/// exec, utility and dos with memory lent; a process with WORK: behind
/// it; iffparse, compression and paintio made, and paintio opened.
const Rig = struct {
    db: *host.dos.DosBase,
    region: *exec.MemHeader = undefined,
    proc: dos.Process = .{},
    saved: ?*kexec.Task = null,
    libraries: [3]*exec.Library = undefined,
    pio: *PaintIOBase = undefined,

    fn init(rig: *Rig) !void {
        rig.* = .{ .db = try host.dos.testSetUp() };
        rig.region = rig.sysLib().AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent").?;
        rig.proc.task.node.name = "test process";
        host.dos_process.initMsgPort(&rig.proc);
        rig.saved = kexec.SysBase.cpu().this_task;
        kexec.SysBase.cpu().this_task = &rig.proc.task;

        const dl = rig.dosLib();
        Disk.dl = dl;
        Disk.port = .{ .flags = exec.PA_IGNORE };
        Disk.port.msg_list.init(.message);
        Disk.disk = try host.ram.RamDisk.init(rig.db.sys_base, dl, rig.db.utility_base, &Disk.port);
        const node = dl.MakeDosEntry("WORK", dos.DLT_DEVICE).?;
        node.task = &Disk.port;
        try testing.expect(dl.AddDosEntry(node));
        rig.proc.pkt_wait = &Disk.wait;

        const tags = [_]*const exec.Resident{ &iffparse_init.iffparse_library_tag, &compression_init.compression_library_tag, &paintio_init.paintio_library_tag };
        for (tags, &rig.libraries) |tag, *library| {
            const made = kexec.InitResident(kexec.SysBase, tag, null) orelse return error.NoLibrary;
            library.* = @ptrCast(@alignCast(made));
        }
        rig.pio = @ptrCast(rig.sysLib().OpenLibrary(paintio.PAINTIONAME, 1) orelse return error.NoBase);
    }

    fn sysLib(_: *Rig) *sdk.interface.exec.ExecBase {
        return kexec.SysBase.iface();
    }

    fn dosLib(rig: *Rig) *DosBase {
        return host.dos.testBase(rig.db);
    }

    /// The libraries closed and expunged, the disk taken down, and
    /// nothing left behind.
    fn deinit(rig: *Rig) !void {
        rig.sysLib().CloseLibrary(rig.pio.lib());
        for (rig.libraries) |library| _ = rig.sysLib().RemLibrary(library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, paintio.PAINTIONAME) == null);
        Disk.disk.deinit();
        kexec.SysBase.cpu().this_task = rig.saved.?;
        try host.dos.testTearDown(rig.db);
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        rig.sysLib().Remove(&rig.region.node);
        kexec.deinit();
    }

    /// A file on the disk, made of `bytes`.
    fn write(rig: *Rig, name: [*:0]const u8, bytes: []const u8) !void {
        const dl = rig.dosLib();
        const fh = dl.Open(name, dos.MODE_NEWFILE) orelse return error.NoFile;
        defer _ = dl.Close(fh);
        try testing.expectEqual(@as(isize, @intCast(bytes.len)), dl.Write(fh, bytes.ptr, @intCast(bytes.len)));
    }

    /// The file's bytes, as many as fit.
    fn read(rig: *Rig, name: [*:0]const u8, into: []u8) !usize {
        const dl = rig.dosLib();
        const fh = dl.Open(name, dos.MODE_OLDFILE) orelse return error.NoFile;
        defer _ = dl.Close(fh);
        const got = dl.Read(fh, into.ptr, @intCast(into.len));
        try testing.expect(got >= 0);
        return @intCast(got);
    }

    fn exists(rig: *Rig, name: [*:0]const u8) bool {
        const dl = rig.dosLib();
        const lock = dl.Lock(name, dos.ACCESS_READ) orelse return false;
        dl.UnLock(lock);
        return true;
    }
};

const width = 37;
const height = 23;

/// A layer's pixels that differ from place to place and from layer to
/// layer, with every alpha.
fn pattern(pixels: *[width * height]u32, seed: u32) void {
    for (pixels, 0..) |*pixel, at| {
        const place: u32 = @intCast(at);
        pixel.* = (place * 7 + seed) % 256 << 24 | (place * 13 + seed) % 256 << 16 | (place / width * 11) % 256 << 8 | (place % width + seed) % 256;
    }
}

test "paintio: a project of two layers comes back as it was saved" {
    var rig: Rig = undefined;
    try rig.init();
    var bottom: [width * height]u32 = undefined;
    var top: [width * height]u32 = undefined;
    pattern(&bottom, 0);
    pattern(&top, 99);
    var layers = [_]paintio.Layer{ .{ .pixels = &bottom }, .{ .pixels = &top, .opacity = 0x40, .flags = paintio.LAYERF_HIDDEN } };
    @memcpy(layers[0].name[0..10], "Background");
    @memcpy(layers[1].name[0..31], "a name that is longer than room");
    var project = paintio.Project{ .width = width, .height = height, .layer_count = 2, .current = 1, .layers = &layers, .palette_count = 3 };
    project.palette[0] = 0xFF000000;
    project.palette[1] = 0xFFFFFFFF;
    project.palette[2] = 0x80FF8000;
    try testing.expectEqual(@as(i32, 0), rig.pio.SaveProject("WORK:two.paint", &project));

    // The file starts as a project.
    var start: [12]u8 = undefined;
    try testing.expectEqual(@as(usize, 12), try rig.read("WORK:two.paint", &start));
    try testing.expectEqualStrings("FORM", start[0..4]);
    try testing.expectEqualStrings("PNTG", start[8..12]);

    var back = paintio.Project{};
    try testing.expectEqual(@as(i32, 0), rig.pio.LoadProject("WORK:two.paint", &back));
    try testing.expectEqual(paintio.PIOKIND_PROJECT, back.kind);
    try testing.expectEqual(@as(u32, width), back.width);
    try testing.expectEqual(@as(u32, height), back.height);
    try testing.expectEqual(@as(u32, 2), back.layer_count);
    try testing.expectEqual(@as(u32, 1), back.current);
    try testing.expectEqual(@as(u32, 3), back.palette_count);
    try testing.expectEqualSlices(u32, project.palette[0..3], back.palette[0..3]);
    const read_layers = back.layers.?;
    for (layers, read_layers[0..2]) |saved, read| {
        try testing.expectEqualSlices(u32, saved.pixels.?[0 .. width * height], read.pixels.?[0 .. width * height]);
        try testing.expectEqual(saved.opacity, read.opacity);
        try testing.expectEqual(saved.flags, read.flags);
        try testing.expectEqualStrings(std.mem.sliceTo(&saved.name, 0), std.mem.sliceTo(&read.name, 0));
    }
    rig.pio.FreeProject(&back);
    try testing.expect(back.layers == null);
    try testing.expectEqual(@as(u32, 0), back.layer_count);
    try rig.deinit();
}

test "paintio: a project no file holds is refused before a file is made" {
    var rig: Rig = undefined;
    try rig.init();
    var pixels: [width * height]u32 = @splat(0);
    var layer = [_]paintio.Layer{.{ .pixels = &pixels }};
    var none = [_]paintio.Layer{.{}};
    const cases = [_]paintio.Project{
        .{ .width = 0, .height = height, .layer_count = 1, .layers = &layer },
        .{ .width = width, .height = paintio.MAX_SIDE + 1, .layer_count = 1, .layers = &layer },
        .{ .width = width, .height = height, .layer_count = 0, .layers = &layer },
        .{ .width = width, .height = height, .layer_count = 1, .current = 1, .layers = &layer },
        .{ .width = width, .height = height, .layer_count = 1, .layers = &none },
        .{ .width = width, .height = height, .layer_count = 1 },
        .{ .width = width, .height = height, .layer_count = 1, .layers = &layer, .palette_count = paintio.MAX_PALETTE + 1 },
    };
    for (&cases) |*bad| try testing.expectEqual(dos.ERROR_BAD_NUMBER, rig.pio.SaveProject("WORK:bad.paint", bad));
    try testing.expect(!rig.exists("WORK:bad.paint"));
    try testing.expectEqual(dos.ERROR_BAD_NUMBER, rig.pio.SavePicture("WORK:bad.png", &pixels, 0, height, paintio.PIOFORMAT_PNG));
    try testing.expectEqual(dos.ERROR_BAD_NUMBER, rig.pio.SavePicture("WORK:bad.png", &pixels, width, height, 7));
    try rig.deinit();
}

test "paintio: a damaged project, a missing file and a picture without datatypes are refused, leaving nothing" {
    var rig: Rig = undefined;
    try rig.init();
    var pixels: [width * height]u32 = undefined;
    pattern(&pixels, 5);
    var layer = [_]paintio.Layer{.{ .pixels = &pixels }};
    const project = paintio.Project{ .width = width, .height = height, .layer_count = 1, .layers = &layer };
    try testing.expectEqual(@as(i32, 0), rig.pio.SaveProject("WORK:whole.paint", &project));
    var file: [8192]u8 = undefined;
    const length = try rig.read("WORK:whole.paint", &file);
    try testing.expect(length < file.len);

    var back = paintio.Project{};
    // Cut short in the body: the stream ends early.
    try rig.write("WORK:cut.paint", file[0 .. length - 20]);
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, rig.pio.LoadProject("WORK:cut.paint", &back));
    try testing.expect(back.layers == null);
    // A byte of the packed pixels changed: the checksum is wrong.
    var changed = file;
    changed[length - 30] ^= 0x55;
    try rig.write("WORK:changed.paint", changed[0..length]);
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, rig.pio.LoadProject("WORK:changed.paint", &back));
    try testing.expect(back.layers == null);
    // A form with no header.
    try rig.write("WORK:empty.paint", "FORM\x00\x00\x00\x04PNTG");
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, rig.pio.LoadProject("WORK:empty.paint", &back));

    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, rig.pio.LoadProject("WORK:none.paint", &back));
    // Not a project: a picture for datatypes, which the host has not.
    try rig.write("WORK:text", "not a picture at all");
    try testing.expectEqual(dos.ERROR_INVALID_RESIDENT_LIBRARY, rig.pio.LoadProject("WORK:text", &back));
    try testing.expect(back.layers == null);
    try rig.deinit();
}
