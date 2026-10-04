// SPDX-License-Identifier: MIT
//! Host tests of rdb.library as a whole: the library made from its ROM
//! tag on the ROM's exec, opened as a program opens it, and spoken to
//! through its jump table, against a block device of its own here - a
//! small medium in memory that behaves like flash (a write only clears
//! bits, an erase sets a block back to ones), so a block written without
//! its erase reads back wrong.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const rdb = sdk.rdb;
const trackdisk = sdk.devices.trackdisk;
const hardblocks = sdk.dos.hardblocks;
const ExecBase = sdk.interface.exec.ExecBase;
const RDBBase = sdk.interface.rdb.RDBBase;
const rdb_init = @import("../rdb_init.zig");
const kexec = @import("host_rom").exec;

const testing = std.testing;

test {
    _ = @import("../rdb_lvo.zig");
}

// --- the medium -----------------------------------------------------------------

const MEDIUM_NAME = "rdbtest.device";
const block_bytes = 512;
const medium_blocks = 64;

const Medium = extern struct {
    dev: exec.Device,
    sys: *ExecBase,
    unit: exec.Unit = .{},
    /// The block size TD_GETGEOMETRY answers.
    sector_size: u32 = block_bytes,
    erases: u32 = 0,
    image: [medium_blocks * block_bytes]u8 = @splat(0xFF),
};

fn mediumOf(dev: *exec.Device) *Medium {
    return @fieldParentPtr("dev", dev);
}

fn mediumInit(dev: *exec.Device, _: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Device {
    const medium = mediumOf(dev);
    const header = dev.*;
    medium.* = .{ .dev = header, .sys = sys };
    return dev;
}

fn mediumOpen(dev: *exec.Device, io: *exec.IORequest, unit: u32, _: u32) callconv(.c) i32 {
    if (unit != 0) return exec.IOERR_OPENFAIL;
    const medium = mediumOf(dev);
    io.unit = &medium.unit;
    dev.open_cnt += 1;
    return 0;
}

fn mediumClose(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    io.unit = null;
    dev.open_cnt -= 1;
    return null;
}

fn mediumExpunge(dev: *exec.Device) callconv(.c) ?*anyopaque {
    const sys = mediumOf(dev).sys;
    sys.DetachLibrary(dev);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(dev) - dev.neg_size);
    sys.FreeMem(start, @as(usize, dev.neg_size) + dev.pos_size);
    return null;
}

fn mediumBeginIO(dev: *exec.Device, request: *exec.IORequest) callconv(.c) void {
    const medium = mediumOf(dev);
    const io: *exec.IOStdReq = @ptrCast(@alignCast(request));
    request.err = serve(medium, io);
    if (request.flags & exec.IOF_QUICK == 0) medium.sys.ReplyMsg(&request.message);
}

fn serve(medium: *Medium, io: *exec.IOStdReq) i8 {
    const size = medium.image.len;
    switch (io.req.command) {
        trackdisk.TD_GETGEOMETRY => {
            const geometry: *trackdisk.DriveGeometry = @ptrCast(@alignCast(io.data.?));
            geometry.* = .{
                .sector_size = medium.sector_size,
                .total_sectors = size / medium.sector_size,
                .cylinders = @intCast(size / medium.sector_size),
                .cyl_sectors = 1,
                .heads = 1,
                .track_sectors = 1,
                .erase_size = block_bytes,
            };
            return 0;
        },
        exec.CMD_READ, exec.CMD_WRITE, trackdisk.TDCMD_ERASE => {
            if (io.offset + io.length > size) return trackdisk.TDERR_SeekError;
            const at: usize = @intCast(io.offset);
            const length: usize = @intCast(io.length);
            const part = medium.image[at..][0..length];
            switch (io.req.command) {
                exec.CMD_READ => @memcpy(@as([*]u8, @ptrCast(io.data.?))[0..length], part),
                exec.CMD_WRITE => {
                    const from: [*]const u8 = @ptrCast(io.data.?);
                    for (part, 0..) |*byte, i| byte.* &= from[i];
                },
                else => {
                    if (at % block_bytes != 0 or length % block_bytes != 0) return trackdisk.TDERR_SeekError;
                    @memset(part, 0xFF);
                    medium.erases += 1;
                },
            }
            io.actual = io.length;
            return 0;
        },
        else => return exec.IOERR_NOCMD,
    }
}

fn mediumAbortIO(_: *exec.Device, _: *exec.IORequest) callconv(.c) i32 {
    return 0;
}

const medium_vectors = [_]*const anyopaque{
    exec.vec(mediumOpen),
    exec.vec(mediumClose),
    exec.vec(mediumExpunge),
    exec.vec(exec.libExtFunc),
    exec.vec(mediumBeginIO),
    exec.vec(mediumAbortIO),
};

const medium_table = exec.InitTable{
    .data_size = @sizeOf(Medium),
    .vectors = &medium_vectors,
    .vector_count = medium_vectors.len,
    .init = &mediumInit,
};

const medium_tag: exec.Resident = .{
    .match_tag = &medium_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = 1,
    .type = .device,
    .pri = 0,
    .name = MEDIUM_NAME,
    .id_string = "rdbtest.device 1.0",
    .init = &medium_table,
};

// --- the rig --------------------------------------------------------------------

/// exec, the medium and the library; the base the tests open is theirs.
const Rig = struct {
    sys: *ExecBase,
    library: *exec.Library,
    medium: *Medium,
    rb: *RDBBase,

    fn init() !Rig {
        try kexec.setUp();
        const sys = kexec.SysBase.iface();
        const device = kexec.InitResident(kexec.SysBase, &medium_tag, null) orelse return error.NoDevice;
        const made = kexec.InitResident(kexec.SysBase, &rdb_init.rdb_library_tag, null) orelse return error.NoLibrary;
        const opened = sys.OpenLibrary(rdb.RDBNAME, 1) orelse return error.NoBase;
        return .{
            .sys = sys,
            .library = @ptrCast(@alignCast(made)),
            .medium = mediumOf(@ptrCast(@alignCast(device))),
            .rb = @ptrCast(opened),
        };
    }

    /// The library closed and expunged, the medium removed, and nothing
    /// left behind.
    fn deinit(rig: *Rig) !void {
        rig.sys.CloseLibrary(rig.rb.lib());
        _ = rig.sys.RemLibrary(rig.library);
        _ = rig.sys.RemDevice(&rig.medium.dev);
        try kexec.expectNoLeaks();
        kexec.deinit();
    }

    fn open(rig: *Rig) !*rdb.RDBHandle {
        var err: i32 = 99;
        const handle = rig.rb.OpenRDB(MEDIUM_NAME, 0, &err) orelse return error.NotOpened;
        try testing.expectEqual(rdb.RDBERR_OK, err);
        return handle;
    }

    /// A block of the medium as the structure at its start.
    fn block(rig: *Rig, comptime T: type, number: u32) *align(1) T {
        return @ptrCast(&rig.medium.image[number * block_bytes]);
    }
};

fn names(rb: *RDBBase, handle: *rdb.RDBHandle, into: []u8) []const u8 {
    var length: usize = 0;
    var part = rb.NextPartition(handle, null);
    while (part) |p| : (part = rb.NextPartition(handle, p)) {
        const name = p.block.name();
        if (length != 0) {
            into[length] = ' ';
            length += 1;
        }
        @memcpy(into[length..][0..name.len], name);
        length += name.len;
    }
    return into[0..length];
}

const fls = sdk.dos.flashfs.ID_FLASHFS_DISK;

// --- tests ----------------------------------------------------------------------

test "a blank medium: no table until InitRDB, and nothing to write before it" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const rb = rig.rb;

    const handle = try rig.open();
    defer rb.CloseRDB(handle);
    try testing.expectEqual(@as(u32, 0), handle.flags & (rdb.RDBF_FOUND | rdb.RDBF_DAMAGED | rdb.RDBF_FOREIGN));
    try testing.expectEqual(@as(u32, block_bytes), handle.geometry.sector_size);
    try testing.expect(rb.NextPartition(handle, null) == null);
    try testing.expectEqual(rdb.RDBERR_NORDB, rb.AddPartition(handle, "DH0", 0, 0, fls));
    try testing.expectEqual(rdb.RDBERR_NORDB, rb.WriteRDB(handle));
    try testing.expectEqual(@as(u32, 0), rig.medium.erases);
}

test "a fresh table with one partition over the whole medium, written and read back" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const rb = rig.rb;

    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        try testing.expectEqual(rdb.RDBERR_OK, rb.InitRDB(handle));
        try testing.expect(handle.flags & rdb.RDBF_CHANGED != 0);
        try testing.expectEqual(@as(u32, hardblocks.RDB_LOCATION_LIMIT), handle.rdb.lo_cylinder);
        try testing.expectEqual(@as(u32, medium_blocks - 1), handle.rdb.hi_cylinder);
        try testing.expectEqual(rdb.RDBERR_OK, rb.AddPartition(handle, "DH0", 0, 0, fls));
        try testing.expectEqual(rdb.RDBERR_RANGE, rb.AddPartition(handle, "DH1", 0, 0, fls));
        const part = rb.FindPartition(handle, "dh0") orelse return error.NotFound;
        part.block.flags |= hardblocks.PBFF_BOOTABLE;
        try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));
        try testing.expectEqual(@as(u32, 0), handle.flags & rdb.RDBF_CHANGED);
        try testing.expectEqual(@as(u32, 1), part.at);
    }

    // What dos reads at boot: a sound RigidDiskBlock in block 0 and a
    // sound PartitionBlock where it points.
    const table = rig.block(hardblocks.RigidDiskBlock, 0).*;
    try testing.expect(hardblocks.sound(&table, hardblocks.IDNAME_RIGIDDISK));
    try testing.expectEqual(@as(u32, 1), table.partition_list);
    const written = rig.block(hardblocks.PartitionBlock, 1).*;
    try testing.expect(hardblocks.sound(&written, hardblocks.IDNAME_PARTITION));
    try testing.expectEqual(hardblocks.end_of_list, written.next);

    const handle = try rig.open();
    defer rb.CloseRDB(handle);
    try testing.expectEqual(rdb.RDBF_FOUND, handle.flags);
    const part = rb.NextPartition(handle, null) orelse return error.NoPartition;
    try testing.expectEqualStrings("DH0", part.block.name());
    try testing.expectEqualStrings("DH0", std.mem.span(part.node.name.?));
    const env = &part.block.environment;
    try testing.expectEqual(@as(u32, hardblocks.RDB_LOCATION_LIMIT), env.low_cyl);
    try testing.expectEqual(@as(u32, medium_blocks - 1), env.high_cyl);
    try testing.expectEqual(@as(u32, block_bytes), env.size_block);
    try testing.expectEqual(fls, env.dos_type);
    try testing.expectEqual(@as(u64, medium_blocks - hardblocks.RDB_LOCATION_LIMIT), env.blocks());
    try testing.expect(part.block.flags & hardblocks.PBFF_BOOTABLE != 0);
    try testing.expect(rb.NextPartition(handle, part) == null);
}

test "names and cylinders a partition may not have" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const rb = rig.rb;
    const handle = try rig.open();
    defer rb.CloseRDB(handle);
    try testing.expectEqual(rdb.RDBERR_OK, rb.InitRDB(handle));

    try testing.expectEqual(rdb.RDBERR_OK, rb.AddPartition(handle, "DH0", 20, 29, fls));
    try testing.expectEqual(rdb.RDBERR_NAME, rb.AddPartition(handle, "dh0", 30, 39, fls));
    try testing.expectEqual(rdb.RDBERR_NAME, rb.AddPartition(handle, "", 30, 39, fls));
    try testing.expectEqual(rdb.RDBERR_NAME, rb.AddPartition(handle, "DH:1", 30, 39, fls));
    try testing.expectEqual(rdb.RDBERR_NAME, rb.AddPartition(handle, "ABCDEFGHIJKLMNOPQRSTUVWXYZ01234", 30, 39, fls));
    try testing.expectEqual(rdb.RDBERR_RANGE, rb.AddPartition(handle, "DH1", 25, 35, fls));
    try testing.expectEqual(rdb.RDBERR_RANGE, rb.AddPartition(handle, "DH1", 10, 15, fls));
    try testing.expectEqual(rdb.RDBERR_RANGE, rb.AddPartition(handle, "DH1", 40, 64, fls));
    try testing.expectEqual(rdb.RDBERR_RANGE, rb.AddPartition(handle, "DH1", 39, 30, fls));

    // 0 and 0: the longest free run, here past DH0 (30 to 63) rather than
    // before it (16 to 19).
    try testing.expectEqual(rdb.RDBERR_OK, rb.AddPartition(handle, "DH1", 0, 0, fls));
    const dh1 = rb.FindPartition(handle, "DH1").?;
    try testing.expectEqual(@as(u32, 30), dh1.block.environment.low_cyl);
    try testing.expectEqual(@as(u32, 63), dh1.block.environment.high_cyl);
    try testing.expectEqual(rdb.RDBERR_OK, rb.AddPartition(handle, "DH2", 0, 0, fls));
    const dh2 = rb.FindPartition(handle, "DH2").?;
    try testing.expectEqual(@as(u32, 16), dh2.block.environment.low_cyl);
    try testing.expectEqual(@as(u32, 19), dh2.block.environment.high_cyl);

    // What the program changes is checked when it is written.
    dh2.block.environment.high_cyl = 20;
    try testing.expectEqual(rdb.RDBERR_RANGE, rb.WriteRDB(handle));
    dh2.block.environment.high_cyl = 19;
    @memcpy(dh2.block.drive_name[0..3], "DH1");
    try testing.expectEqual(rdb.RDBERR_NAME, rb.WriteRDB(handle));
    @memcpy(dh2.block.drive_name[0..3], "DH2");
    try testing.expectEqual(@as(u32, 0), rig.medium.erases);
    try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));

    var text: [64]u8 = undefined;
    try testing.expectEqualStrings("DH0 DH1 DH2", names(rb, handle, &text));
}

test "a rewritten chain goes in blocks the old one is not in, and the old one stays whole" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const rb = rig.rb;
    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        try testing.expectEqual(rdb.RDBERR_OK, rb.InitRDB(handle));
        try testing.expectEqual(rdb.RDBERR_OK, rb.AddPartition(handle, "DH0", 16, 39, fls));
        try testing.expectEqual(rdb.RDBERR_OK, rb.AddPartition(handle, "DH1", 40, 63, fls));
        try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));
    }
    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        rb.RemPartition(handle, rb.FindPartition(handle, "DH0").?);
        try testing.expect(handle.flags & rdb.RDBF_CHANGED != 0);
        try testing.expectEqual(rdb.RDBERR_OK, rb.AddPartition(handle, "WORK", 0, 0, fls));
        try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));
        try testing.expectEqual(@as(u32, 3), rb.FindPartition(handle, "DH1").?.at);
        try testing.expectEqual(@as(u32, 4), rb.FindPartition(handle, "WORK").?.at);
    }
    // The old chain is still there, sound, in blocks 1 and 2.
    try testing.expect(hardblocks.sound(rig.block(hardblocks.PartitionBlock, 1), hardblocks.IDNAME_PARTITION));
    try testing.expect(hardblocks.sound(rig.block(hardblocks.PartitionBlock, 2), hardblocks.IDNAME_PARTITION));

    const handle = try rig.open();
    defer rb.CloseRDB(handle);
    var text: [64]u8 = undefined;
    try testing.expectEqualStrings("DH1 WORK", names(rb, handle, &text));
    try testing.expectEqual(@as(u32, 16), rb.FindPartition(handle, "work").?.block.environment.low_cyl);
}

test "a file system header's blocks are kept, and the table's own blocks run out" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const rb = rig.rb;
    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        try testing.expectEqual(rdb.RDBERR_OK, rb.InitRDB(handle));
        try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));
    }
    // A FileSysHeaderBlock in block 1 and its code in block 2, as a tool
    // that puts a file system on the disk would leave them.
    var header: hardblocks.FileSysHeaderBlock = .{ .dos_type = fls, .seg_list_blocks = 2 };
    header.checksum = hardblocks.checksumOf(&header);
    @memcpy(rig.medium.image[block_bytes..][0..@sizeOf(hardblocks.FileSysHeaderBlock)], std.mem.asBytes(&header));
    const code: hardblocks.LoadSegBlock = .{};
    @memcpy(rig.medium.image[2 * block_bytes ..][0..@sizeOf(hardblocks.LoadSegBlock)], std.mem.asBytes(&code));
    var table = rig.block(hardblocks.RigidDiskBlock, 0).*;
    table.file_sys_header_list = 1;
    table.checksum = hardblocks.checksumOf(&table);
    @memset(rig.medium.image[0..block_bytes], 0xFF);
    @memcpy(rig.medium.image[0..@sizeOf(hardblocks.RigidDiskBlock)], std.mem.asBytes(&table));

    const handle = try rig.open();
    defer rb.CloseRDB(handle);
    try testing.expectEqual(rdb.RDBF_FOUND, handle.flags);
    // 16 blocks less the RigidDiskBlock's and the two kept: 13 partitions.
    var name: [4:0]u8 = .{ 'P', '0', '0', 0 };
    var cylinder: u32 = 16;
    while (cylinder < 16 + 13) : (cylinder += 1) {
        name[1] = '0' + @as(u8, @intCast(cylinder / 10));
        name[2] = '0' + @as(u8, @intCast(cylinder % 10));
        try testing.expectEqual(rdb.RDBERR_OK, rb.AddPartition(handle, &name, cylinder, cylinder, fls));
    }
    try testing.expectEqual(rdb.RDBERR_FULL, rb.AddPartition(handle, "LAST", 40, 40, fls));
    try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));
    var part = rb.NextPartition(handle, null);
    while (part) |p| : (part = rb.NextPartition(handle, p)) {
        try testing.expect(p.at != 1 and p.at != 2 and p.at != 0 and p.at < 16);
    }
    try testing.expect(hardblocks.sound(rig.block(hardblocks.FileSysHeaderBlock, 1), hardblocks.IDNAME_FILESYSHEADER));
    try testing.expectEqual(@as(u32, 1), rig.block(hardblocks.RigidDiskBlock, 0).file_sys_header_list);
}

test "a broken chain and a table for another block size" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const rb = rig.rb;
    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        try testing.expectEqual(rdb.RDBERR_OK, rb.InitRDB(handle));
        try testing.expectEqual(rdb.RDBERR_OK, rb.AddPartition(handle, "DH0", 16, 39, fls));
        try testing.expectEqual(rdb.RDBERR_OK, rb.AddPartition(handle, "DH1", 40, 63, fls));
        try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));
    }
    // DH1's block, one bit off.
    rig.medium.image[2 * block_bytes + 100] ^= 1;
    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        try testing.expectEqual(rdb.RDBF_FOUND | rdb.RDBF_DAMAGED, handle.flags);
        var text: [64]u8 = undefined;
        try testing.expectEqualStrings("DH0", names(rb, handle, &text));
        // Written as it now is, the chain is whole again.
        try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));
        try testing.expectEqual(rdb.RDBF_FOUND, handle.flags);
    }

    // The medium's blocks change size under the table.
    rig.medium.sector_size = 2 * block_bytes;
    const handle = try rig.open();
    defer rb.CloseRDB(handle);
    try testing.expectEqual(rdb.RDBF_FOREIGN, handle.flags);
    try testing.expectEqual(rdb.RDBERR_NORDB, rb.WriteRDB(handle));
}

test "a device that is not there" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    var err: i32 = 0;
    try testing.expect(rig.rb.OpenRDB("nothing.device", 0, &err) == null);
    try testing.expectEqual(rdb.RDBERR_DEVICE, err);
    try testing.expect(rig.rb.OpenRDB(MEDIUM_NAME, 3, &err) == null);
    try testing.expectEqual(rdb.RDBERR_DEVICE, err);
    try testing.expect(rig.rb.OpenRDB(MEDIUM_NAME, 3, null) == null);
    rig.rb.CloseRDB(null);
}
