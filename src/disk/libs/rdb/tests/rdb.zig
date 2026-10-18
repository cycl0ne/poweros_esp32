// SPDX-License-Identifier: MIT
//! Host tests of rdb.library as a whole: the library made from its ROM
//! tag on the ROM's exec, opened as a program opens it, and spoken to
//! through its jump table, against a block device of its own here - a
//! small medium in memory that behaves like flash (a write only clears
//! bits, an erase sets a block back to ones), so a block written without
//! its erase reads back wrong. It can also be a medium that does not
//! erase, count its medium changes, and be cut off after so many writes,
//! as a power cut would. MountPartition's tests bring dos.library and
//! expansion.library up beside it, as the ROM has them, and so do those of
//! `sdk.devices.automount`, which mounts a removable unit's first medium
//! through the library.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const rdb = sdk.rdb;
const trackdisk = sdk.devices.trackdisk;
const hardblocks = sdk.dos.hardblocks;
const ExecBase = sdk.interface.exec.ExecBase;
const RDBBase = sdk.interface.rdb.RDBBase;
const rdb_init = @import("../rdb_init.zig");
const rdb_base = @import("../rdb_base.zig");
const host_rom = @import("host_rom");
const kexec = host_rom.exec;
const kutility = host_rom.utility;
const kdos = host_rom.dos;
const kexpansion = host_rom.expansion;
const automount = sdk.devices.automount;

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
    /// The blocks TD_GETGEOMETRY says there are, when not 0: a large
    /// disk, of which only the image's blocks are ever read or written.
    claimed_blocks: u64 = 0,
    /// The erase unit TD_GETGEOMETRY answers: 0 for a medium that does not
    /// erase, whose writes put the bytes down as they are.
    erase_size: u32 = block_bytes,
    /// TD_CHANGENUM's count.
    change_num: u32 = 0,
    /// The CMD_UPDATEs seen.
    updates: u32 = 0,
    /// The writes and erases the medium still takes; it refuses every one
    /// after, as a medium whose power went would.
    changes_left: u32 = std.math.maxInt(u32),
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
            const blocks: u64 = if (medium.claimed_blocks != 0) medium.claimed_blocks else size / medium.sector_size;
            geometry.* = .{
                .sector_size = medium.sector_size,
                .total_sectors = blocks,
                .cylinders = @intCast(@min(blocks, 0xFFFF_FFFF)),
                .cyl_sectors = 1,
                .heads = 1,
                .track_sectors = 1,
                .erase_size = medium.erase_size,
            };
            return 0;
        },
        trackdisk.TD_CHANGENUM => {
            io.actual = medium.change_num;
            return 0;
        },
        exec.CMD_UPDATE => {
            medium.updates += 1;
            return 0;
        },
        exec.CMD_READ, exec.CMD_WRITE, trackdisk.TDCMD_ERASE => {
            if (io.offset + io.length > size) return trackdisk.TDERR_SeekError;
            const at: usize = @intCast(io.offset);
            const length: usize = @intCast(io.length);
            const part = medium.image[at..][0..length];
            if (io.req.command != exec.CMD_READ) {
                if (medium.changes_left == 0) return trackdisk.TDERR_WriteProt;
                medium.changes_left -= 1;
            }
            switch (io.req.command) {
                exec.CMD_READ => @memcpy(@as([*]u8, @ptrCast(io.data.?))[0..length], part),
                exec.CMD_WRITE => {
                    const from: [*]const u8 = @ptrCast(io.data.?);
                    if (medium.erase_size == 0) {
                        @memcpy(part, from[0..length]);
                    } else {
                        for (part, 0..) |*byte, i| byte.* &= from[i];
                    }
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
        return start();
    }

    /// The medium and the library, on the exec that is up.
    fn start() !Rig {
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
        rig.stop();
        try kexec.expectNoLeaks();
        kexec.deinit();
    }

    /// The library closed and expunged - let go of what it mounted, which
    /// dos's list frees here - and the medium removed.
    fn stop(rig: *Rig) void {
        rig.sys.CloseLibrary(rig.rb.lib());
        rdb_base.rdbBase(rig.library).mounted = false;
        _ = rig.sys.RemLibrary(rig.library);
        _ = rig.sys.RemDevice(&rig.medium.dev);
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

    /// The blocks of the first RDB_LOCATION_LIMIT holding a sound
    /// RigidDiskBlock, as a bit each.
    fn tables(rig: *Rig) u32 {
        var found: u32 = 0;
        var number: u32 = 0;
        while (number < hardblocks.RDB_LOCATION_LIMIT) : (number += 1) {
            const table = rig.block(hardblocks.RigidDiskBlock, number).*;
            if (hardblocks.sound(&table, hardblocks.IDNAME_RIGIDDISK)) found |= @as(u32, 1) << @intCast(number);
        }
        return found;
    }
};

/// The rig with utility.library, expansion.library and dos.library up
/// first, as the ROM has them, for MountPartition.
const DosRig = struct {
    rig: Rig,
    db: *kdos.DosBase,
    eb: *kexpansion.ExpansionBase,
    dl: *sdk.interface.dos.DosBase,

    fn init() !DosRig {
        try kexec.setUp();
        _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
        const expansion_made = kexec.InitResident(kexec.SysBase, &kexpansion.expansion_library_tag, null) orelse return error.NoExpansion;
        const dos_made = kexec.InitResident(kexec.SysBase, &kdos.dos_library_tag, null) orelse return error.NoDos;
        const db: *kdos.DosBase = @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(dos_made))));
        return .{
            .rig = try Rig.start(),
            .db = db,
            .eb = @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(expansion_made)))),
            .dl = db.iface(),
        };
    }

    /// The rig taken down, then expansion and dos, which frees what is on
    /// its list and checks that nothing is left.
    fn deinit(dos_rig: *DosRig) !void {
        dos_rig.rig.stop();
        kexpansion.testTakeDown(dos_rig.eb);
        try kdos.testTearDown(dos_rig.db);
        kexec.deinit();
    }

    /// The device node called `name`, or null.
    fn device(dos_rig: *DosRig, name: [*:0]const u8) ?*sdk.dos.DosList {
        const dl = dos_rig.dl;
        const list = dl.LockDosList(sdk.dos.LDF_DEVICES | sdk.dos.LDF_READ) orelse return null;
        defer dl.UnLockDosList(sdk.dos.LDF_DEVICES | sdk.dos.LDF_READ);
        return dl.FindDosEntry(list, name, sdk.dos.LDF_DEVICES);
    }

    /// A node of the name on the list, standing for someone else's drive.
    fn take(dos_rig: *DosRig, name: [*:0]const u8) !void {
        const node = dos_rig.dl.MakeDosEntry(name, sdk.dos.DLT_DEVICE) orelse return error.NoMemory;
        if (!dos_rig.dl.AddDosEntry(node)) return error.Taken;
    }
};

/// A table of DH0 on cylinders 16 to 39 and DH1 on 40 to 63, both for
/// `dos_type`, written.
fn writeTwo(rig: *Rig, dos_type: u32) !void {
    const handle = try rig.open();
    defer rig.rb.CloseRDB(handle);
    try testing.expectEqual(rdb.RDBERR_OK, rig.rb.InitRDB(handle));
    try testing.expectEqual(rdb.RDBERR_OK, rig.rb.AddPartition(handle, "DH0", 16, 39, dos_type));
    try testing.expectEqual(rdb.RDBERR_OK, rig.rb.AddPartition(handle, "DH1", 40, 63, dos_type));
    try testing.expectEqual(rdb.RDBERR_OK, rig.rb.WriteRDB(handle));
}

fn nameText(name: *const rdb.MountName) []const u8 {
    return std.mem.sliceTo(name, 0);
}

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

test "a PC's partition table in the first block stays, and the table goes in the second" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const rb = rig.rb;

    // A card as it is sold: block 0 a partition table, one FAT32
    // partition from block 16 to the end.
    const mbr = rig.medium.image[0..block_bytes];
    @memset(mbr, 0);
    const entry = mbr[sdk.dos.fat.partition_table_at..][0..sdk.dos.fat.partition_entry_bytes];
    entry[4] = 0x0C;
    sdk.dos.fat.putU32(entry, 8, 16);
    sdk.dos.fat.putU32(entry, 12, medium_blocks - 16);
    sdk.dos.fat.putU16(mbr, sdk.dos.fat.signature_at, sdk.dos.fat.signature);
    var before: [block_bytes]u8 = undefined;
    @memcpy(&before, mbr);

    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        try testing.expectEqual(rdb.RDBERR_OK, rb.InitRDB(handle));
        try testing.expectEqual(@as(u32, 1), handle.rdb.rdb_blocks_lo);
        try testing.expectEqual(@as(u32, hardblocks.RDB_LOCATION_LIMIT), handle.rdb.lo_cylinder);
        try testing.expectEqual(rdb.RDBERR_OK, rb.AddPartition(handle, "SD0", 16, medium_blocks - 1, sdk.dos.ID_MSDOS_DISK));
        try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));
        const part = rb.FindPartition(handle, "SD0") orelse return error.NotFound;
        try testing.expectEqual(@as(u32, 2), part.at);
    }
    try testing.expectEqualSlices(u8, &before, rig.medium.image[0..block_bytes]);
    const table = rig.block(hardblocks.RigidDiskBlock, 1).*;
    try testing.expect(hardblocks.sound(&table, hardblocks.IDNAME_RIGIDDISK));
    try testing.expectEqual(@as(u32, 2), table.partition_list);

    const handle = try rig.open();
    defer rb.CloseRDB(handle);
    try testing.expectEqual(rdb.RDBF_FOUND, handle.flags);
    try testing.expectEqual(@as(u32, 1), handle.block);
    const part = rb.NextPartition(handle, null) orelse return error.NoPartition;
    try testing.expectEqualStrings("SD0", part.block.name());
    try testing.expectEqual(@as(u32, 16), part.block.environment.low_cyl);
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

test "a disk of 2^32 blocks or more gets cylinders of several blocks" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const rb = rig.rb;

    const Case = struct { blocks: u64, cyl_blocks: u32, lo: u32, hi: u32 };
    const cases = [_]Case{
        // The most blocks one-block cylinders count, the last one's number
        // and one more still 32-bit.
        .{ .blocks = 0xFFFF_FFFF, .cyl_blocks = 1, .lo = 16, .hi = 0xFFFF_FFFE },
        .{ .blocks = 1 << 32, .cyl_blocks = 2, .lo = 8, .hi = (1 << 31) - 1 },
        // Just short of 16 TiB of 512-byte blocks: eight to a cylinder,
        // and the five past the last whole one are no partition's.
        .{ .blocks = (1 << 35) - 3, .cyl_blocks = 8, .lo = 2, .hi = 0xFFFF_FFFE },
        .{ .blocks = 1 << 40, .cyl_blocks = 512, .lo = 1, .hi = (1 << 31) - 1 },
    };
    for (cases) |case| {
        rig.medium.claimed_blocks = case.blocks;
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        try testing.expectEqual(rdb.RDBERR_OK, rb.InitRDB(handle));
        const table = &handle.rdb;
        try testing.expectEqual(case.cyl_blocks, table.cyl_blocks);
        try testing.expectEqual(case.cyl_blocks, table.heads * table.sectors);
        try testing.expectEqual(case.lo, table.lo_cylinder);
        try testing.expectEqual(case.hi, table.hi_cylinder);
        try testing.expectEqual(@as(u32, case.hi) + 1, table.cylinders);

        // A partition over all of it starts past the table's blocks and
        // covers the disk to its last whole cylinder.
        try testing.expectEqual(rdb.RDBERR_OK, rb.AddPartition(handle, "DH0", 0, 0, fls));
        const env = &rb.FindPartition(handle, "DH0").?.block.environment;
        try testing.expect(env.byteOf(0) >= hardblocks.RDB_LOCATION_LIMIT * block_bytes);
        const end = env.byteOf(env.blocks()) / block_bytes;
        try testing.expect(end <= case.blocks and case.blocks - end < case.cyl_blocks);
    }
}

test "a partition's blocks, to the last cylinder a table can name" {
    const DosEnvec = sdk.dos.filehandler.DosEnvec;
    const top: DosEnvec = .{ .low_cyl = 0, .high_cyl = 0xFFFF_FFFF, .blocks_per_track = 2 };
    try testing.expectEqual(@as(u64, 1 << 33), top.blocks());
    const backwards: DosEnvec = .{ .low_cyl = 10, .high_cyl = 4 };
    try testing.expectEqual(@as(u64, 0), backwards.blocks());
    const one: DosEnvec = .{ .low_cyl = 7, .high_cyl = 7, .surfaces = 2, .blocks_per_track = 3 };
    try testing.expectEqual(@as(u64, 6), one.blocks());
}

test "a rewritten table goes in blocks the old one is not in, and the old one stays whole until the new is down" {
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
        // The RigidDiskBlock in the first block the old table is not in,
        // the PartitionBlocks after it.
        try testing.expectEqual(@as(u32, 3), handle.block);
        try testing.expectEqual(@as(u32, 4), rb.FindPartition(handle, "DH1").?.at);
        try testing.expectEqual(@as(u32, 5), rb.FindPartition(handle, "WORK").?.at);
    }
    // The old chain is still there, sound, in blocks 1 and 2; its
    // RigidDiskBlock is wiped, and the new one is the only one.
    try testing.expect(hardblocks.sound(rig.block(hardblocks.PartitionBlock, 1), hardblocks.IDNAME_PARTITION));
    try testing.expect(hardblocks.sound(rig.block(hardblocks.PartitionBlock, 2), hardblocks.IDNAME_PARTITION));
    try testing.expectEqual(@as(u32, 1 << 3), rig.tables());

    const handle = try rig.open();
    defer rb.CloseRDB(handle);
    var text: [64]u8 = undefined;
    try testing.expectEqualStrings("DH1 WORK", names(rb, handle, &text));
    try testing.expectEqual(@as(u32, 16), rb.FindPartition(handle, "work").?.block.environment.low_cyl);
}

test "a file system's blocks are kept, and the table's own blocks run out" {
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
    hardblocks.makeLoadSeg(rig.medium.image[2 * block_bytes ..][0..block_bytes], "code", hardblocks.end_of_list);
    var table = rig.block(hardblocks.RigidDiskBlock, 0).*;
    table.file_sys_header_list = 1;
    table.checksum = hardblocks.checksumOf(&table);
    @memset(rig.medium.image[0..block_bytes], 0xFF);
    @memcpy(rig.medium.image[0..@sizeOf(hardblocks.RigidDiskBlock)], std.mem.asBytes(&table));

    const handle = try rig.open();
    defer rb.CloseRDB(handle);
    try testing.expectEqual(rdb.RDBF_FOUND, handle.flags);
    const kept = rb.NextFileSystem(handle, null).?;
    try testing.expectEqual(@as(u32, 1), kept.at);
    try testing.expectEqual(@as(u32, 4), kept.size);
    try testing.expectEqual(@as(u32, 1), kept.blocks);
    try testing.expect(rb.NextFileSystem(handle, kept) == null);
    // 16 blocks less the RigidDiskBlock's and the file system's two: 13
    // partitions. With all of them written the header has nowhere to go
    // but its old block, and the RigidDiskBlock its own.
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

test "a write cut off before the old RigidDiskBlock is wiped leaves a whole table, the new one above the old or below it" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const rb = rig.rb;
    try writeTwo(&rig, fls);
    var text: [64]u8 = undefined;

    // The new table above the old: until the old is wiped, a reader takes
    // the old one. Two PartitionBlocks and the RigidDiskBlock, each erased
    // and written, and the cut comes before the wipe.
    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        @memcpy(rb.FindPartition(handle, "DH1").?.block.drive_name[0..3], "WRK");
        rig.medium.changes_left = 6;
        try testing.expectEqual(rdb.RDBERR_IO, rb.WriteRDB(handle));
    }
    rig.medium.changes_left = std.math.maxInt(u32);
    try testing.expectEqual(@as(u32, 1 << 0 | 1 << 3), rig.tables());
    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        try testing.expectEqual(@as(u32, 0), handle.block);
        try testing.expectEqualStrings("DH0 DH1", names(rb, handle, &text));
        // Written again, the stray one goes too.
        @memcpy(rb.FindPartition(handle, "DH1").?.block.drive_name[0..3], "WRK");
        try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));
        try testing.expectEqual(@as(u32, 3), handle.block);
    }
    try testing.expectEqual(@as(u32, 1 << 3), rig.tables());

    // The new table below the old: a reader takes the new one as soon as
    // it is written.
    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        try testing.expectEqualStrings("DH0 WRK", names(rb, handle, &text));
        @memcpy(rb.FindPartition(handle, "DH0").?.block.drive_name[0..3], "SYS");
        rig.medium.changes_left = 6;
        try testing.expectEqual(rdb.RDBERR_IO, rb.WriteRDB(handle));
    }
    rig.medium.changes_left = std.math.maxInt(u32);
    try testing.expectEqual(@as(u32, 1 << 0 | 1 << 3), rig.tables());
    const handle = try rig.open();
    defer rb.CloseRDB(handle);
    try testing.expectEqual(@as(u32, 0), handle.block);
    try testing.expectEqualStrings("SYS WRK", names(rb, handle, &text));
    try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));
    try testing.expectEqual(@as(u32, 1 << 3), rig.tables());
}

test "a medium that does not erase: the old RigidDiskBlock written over with zeroes, and CMD_UPDATE at the end" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    rig.medium.erase_size = 0;
    try writeTwo(&rig, sdk.dos.ID_MSDOS_DISK);
    try testing.expectEqual(@as(u32, 0), rig.medium.erases);
    try testing.expectEqual(@as(u32, 1), rig.medium.updates);
    {
        const handle = try rig.open();
        defer rig.rb.CloseRDB(handle);
        try testing.expectEqual(rdb.RDBERR_OK, rig.rb.WriteRDB(handle));
        try testing.expectEqual(@as(u32, 3), handle.block);
    }
    try testing.expectEqual(@as(u32, 0), rig.medium.erases);
    try testing.expectEqual(@as(u32, 2), rig.medium.updates);
    try testing.expectEqual(@as(u32, 1 << 3), rig.tables());
    for (rig.medium.image[0..block_bytes]) |byte| try testing.expectEqual(@as(u8, 0), byte);
}

test "another medium in the unit: nothing written, nothing mounted" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const rb = rig.rb;
    rig.medium.change_num = 4;
    const handle = try rig.open();
    defer rb.CloseRDB(handle);
    try testing.expectEqual(@as(u32, 4), handle.change_num);
    try testing.expectEqual(rdb.RDBERR_OK, rb.InitRDB(handle));
    try testing.expectEqual(rdb.RDBERR_OK, rb.AddPartition(handle, "DH0", 0, 0, fls));
    rig.medium.change_num = 5;
    try testing.expectEqual(rdb.RDBERR_CHANGED, rb.WriteRDB(handle));
    try testing.expectEqual(rdb.RDBERR_CHANGED, rb.MountPartition(handle, rb.FindPartition(handle, "DH0").?, null, 0));
    try testing.expectEqual(@as(u32, 0), rig.medium.erases);
    try testing.expectEqual(@as(u32, 0), rig.medium.updates);
}

test "a partition mounted: a node of its own, with a copy of its environment and its file system's handler" {
    var dos_rig = try DosRig.init();
    defer dos_rig.deinit() catch unreachable;
    const rig = &dos_rig.rig;
    const rb = rig.rb;
    try writeTwo(rig, sdk.dos.posfs.ID_POSFS_DISK);
    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        var name: rdb.MountName = @splat('x');
        try testing.expectEqual(rdb.RDBERR_OK, rb.MountPartition(handle, rb.FindPartition(handle, "DH1").?, &name, 0));
        try testing.expectEqualStrings("DH1", nameText(&name));
    }
    // The handle and its partitions are freed; the node has its own.
    const node = dos_rig.device("DH1") orelse return error.NotMounted;
    try testing.expectEqualStrings(sdk.dos.posfs.HANDLER_NAME, std.mem.span(node.misc.handler.handler.?));
    const startup = sdk.dos.filehandler.startupOf(node.misc.handler.startup) orelse return error.NoStartup;
    try testing.expectEqual(@as(u32, 0), startup.unit);
    try testing.expectEqualStrings(MEDIUM_NAME, std.mem.span(startup.device.?));
    const env = startup.environ.?;
    try testing.expectEqual(@as(u32, 40), env.low_cyl);
    try testing.expectEqual(@as(u32, 63), env.high_cyl);
    try testing.expectEqual(@as(u32, block_bytes), env.size_block);
    try testing.expectEqual(sdk.dos.posfs.ID_POSFS_DISK, env.dos_type);
    try testing.expect(dos_rig.device("DH0") == null);

    // Mounted once only, by whichever handle.
    const handle = try rig.open();
    defer rb.CloseRDB(handle);
    const dh1 = rb.FindPartition(handle, "DH1").?;
    try testing.expectEqual(rdb.RDBERR_MOUNTED, rb.MountPartition(handle, dh1, null, 0));
    // A partition given some of DH1's cylinders since is DH1's still.
    const dh0 = rb.FindPartition(handle, "DH0").?;
    dh0.block.environment.high_cyl = 40;
    try testing.expectEqual(rdb.RDBERR_MOUNTED, rb.MountPartition(handle, dh0, null, 0));
    dh0.block.environment.high_cyl = 39;
    try testing.expectEqual(rdb.RDBERR_OK, rb.MountPartition(handle, dh0, null, 0));
    try testing.expect(dos_rig.device("DH0") != null);
}

test "a name in use gets a dot, as many as fit" {
    var dos_rig = try DosRig.init();
    defer dos_rig.deinit() catch unreachable;
    const rig = &dos_rig.rig;
    const rb = rig.rb;
    try writeTwo(rig, fls);
    try dos_rig.take("DH0");
    try dos_rig.take("DH0.");
    const long = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123";
    try dos_rig.take(long);

    const handle = try rig.open();
    defer rb.CloseRDB(handle);
    var name: rdb.MountName = undefined;
    try testing.expectEqual(rdb.RDBERR_OK, rb.MountPartition(handle, rb.FindPartition(handle, "DH0").?, &name, 0));
    try testing.expectEqualStrings("DH0..", nameText(&name));
    try testing.expect(dos_rig.device("DH0..") != null);

    // A name of MAX_DEVICE_NAME characters has no room for a dot.
    const dh1 = rb.FindPartition(handle, "DH1").?;
    @memcpy(dh1.block.drive_name[0..long.len], long);
    try testing.expectEqual(rdb.RDBERR_NAME, rb.MountPartition(handle, dh1, &name, 0));
}

test "a partition's file system must suit it, and a drive over the whole medium has every partition" {
    var dos_rig = try DosRig.init();
    defer dos_rig.deinit() catch unreachable;
    const rig = &dos_rig.rig;
    const rb = rig.rb;
    try writeTwo(rig, fls);
    const handle = try rig.open();
    defer rb.CloseRDB(handle);
    const dh0 = rb.FindPartition(handle, "DH0").?;
    const env = &dh0.block.environment;
    // FAT on a medium that erases; a partition table inside a partition;
    // a DosType no handler serves.
    for ([_]u32{ sdk.dos.ID_MSDOS_DISK, sdk.dos.ID_MSDOS_DISK_HD, sdk.dos.posfs.ID_POSFS_MBR, 0x444F_5300 }) |dos_type| {
        env.dos_type = dos_type;
        try testing.expectEqual(rdb.RDBERR_FILESYSTEM, rb.MountPartition(handle, dh0, null, 0));
    }
    env.dos_type = fls;

    // A drive of another unit is no claim; one over this unit's whole
    // medium, named by the device's path, is.
    const expansion_lib = rig.sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return error.NoExpansion;
    defer rig.sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const whole: sdk.dos.DosEnvec = .{ .dos_type = sdk.dos.ID_MSDOS_DISK_HD };
    const other_unit = eb.MakeDosNode("SD8", "DEVS:" ++ MEDIUM_NAME, 1, 0, &whole) orelse return error.NoMemory;
    try testing.expect(dos_rig.dl.AddDosEntry(other_unit));
    try testing.expectEqual(rdb.RDBERR_OK, rb.MountPartition(handle, dh0, null, 0));
    const this_unit = eb.MakeDosNode("SD9", "DEVS:tests/" ++ MEDIUM_NAME, 0, 0, &whole) orelse return error.NoMemory;
    try testing.expect(dos_rig.dl.AddDosEntry(this_unit));
    try testing.expectEqual(rdb.RDBERR_MOUNTED, rb.MountPartition(handle, rb.FindPartition(handle, "DH1").?, null, 0));
}

test "a library that has mounted a partition stays" {
    var dos_rig = try DosRig.init();
    defer dos_rig.deinit() catch unreachable;
    const rig = &dos_rig.rig;
    try writeTwo(rig, fls);
    {
        const handle = try rig.open();
        defer rig.rb.CloseRDB(handle);
        try testing.expectEqual(rdb.RDBERR_OK, rig.rb.MountPartition(handle, rig.rb.FindPartition(handle, "DH0").?, null, 0));
    }
    rig.sys.CloseLibrary(rig.rb.lib());
    _ = rig.sys.RemLibrary(rig.library);
    // Still there to be opened: the node names its handler by a string of
    // the library's.
    const again = rig.sys.OpenLibrary(rdb.RDBNAME, 1) orelse return error.Expunged;
    rig.rb = @ptrCast(again);
}

test "which unit a startup message opens, and which areas share a block" {
    const filehandler = sdk.dos.filehandler;
    const startup: filehandler.FileSysStartupMsg = .{ .unit = 2, .device = "DEVS:usb/disk.device" };
    try testing.expect(filehandler.opensUnit(&startup, "disk.device", 2));
    try testing.expect(filehandler.opensUnit(&startup, "usb/disk.device", 2));
    try testing.expect(!filehandler.opensUnit(&startup, "disk.device", 0));
    try testing.expect(!filehandler.opensUnit(&startup, "Disk.device", 2));
    try testing.expect(!filehandler.opensUnit(&startup, "disk.devices", 2));
    try testing.expect(!filehandler.opensUnit(&startup, "sk.device", 2));

    const low: sdk.dos.DosEnvec = .{ .low_cyl = 16, .high_cyl = 39 };
    const high: sdk.dos.DosEnvec = .{ .low_cyl = 40, .high_cyl = 63 };
    const across: sdk.dos.DosEnvec = .{ .low_cyl = 39, .high_cyl = 40 };
    const whole: sdk.dos.DosEnvec = .{};
    // The same blocks counted in larger cylinders.
    const doubled: sdk.dos.DosEnvec = .{ .low_cyl = 20, .high_cyl = 31, .blocks_per_track = 2 };
    try testing.expect(!filehandler.sharesBlocks(&low, &high));
    try testing.expect(filehandler.sharesBlocks(&low, &across));
    try testing.expect(filehandler.sharesBlocks(&high, &across));
    try testing.expect(filehandler.sharesBlocks(&whole, &high));
    try testing.expect(filehandler.sharesBlocks(null, &high));
    try testing.expect(filehandler.sharesBlocks(&high, &doubled));
    try testing.expect(!filehandler.sharesBlocks(&low, &doubled));
    // Cylinders no medium has, read off one that says what it likes: past
    // every other area, and no overflow.
    const huge: sdk.dos.DosEnvec = .{ .low_cyl = 0xFFFF_FFFE, .high_cyl = 0xFFFF_FFFF, .surfaces = 0xFFFF, .blocks_per_track = 0xFFFF_FFFF };
    try testing.expect(!filehandler.sharesBlocks(&huge, &low));
}

// --- a removable unit's drives (sdk.devices.automount) ----------------------------

/// The medium as a removable unit `SD0` whose drives automount makes.
fn removable(medium: *automount.MediumNode) automount.Unit {
    return .{ .device = MEDIUM_NAME, .number = 0, .name = "SD0", .block_bytes = block_bytes, .medium = medium };
}

test "a unit's first medium with a table: a drive per partition, dotted where the name is taken, none of its own" {
    var dos_rig = try DosRig.init();
    defer dos_rig.deinit() catch unreachable;
    const rig = &dos_rig.rig;
    // A card: no erase unit, and FAT in its partitions.
    rig.medium.erase_size = 0;
    try writeTwo(rig, sdk.dos.ID_MSDOS_DISK);
    {
        const handle = try rig.open();
        defer rig.rb.CloseRDB(handle);
        rig.rb.FindPartition(handle, "DH1").?.block.flags |= hardblocks.PBFF_NOMOUNT;
        try testing.expectEqual(rdb.RDBERR_OK, rig.rb.WriteRDB(handle));
    }
    try dos_rig.take("DH0");

    var medium: automount.MediumNode = .{};
    var drives: automount.Drives = .{};
    automount.mountMedium(rig.sys, dos_rig.dl, removable(&medium), &drives);
    try testing.expectEqual(@as(u32, 1), drives.count);
    try testing.expectEqualStrings("DH0.", nameText(&drives.names[0]));
    const node = dos_rig.device("DH0.") orelse return error.NotMounted;
    try testing.expectEqualStrings(sdk.dos.filesystems.fat_handler, std.mem.span(node.misc.handler.handler.?));
    try testing.expect(dos_rig.device("DH1") == null);
    try testing.expect(dos_rig.device("SD0") == null);
}

test "a unit's first medium with no table: its own drive as its first block says, and a unit with a drive is left alone" {
    var dos_rig = try DosRig.init();
    defer dos_rig.deinit() catch unreachable;
    const rig = &dos_rig.rig;
    rig.medium.erase_size = 0;
    @memset(rig.medium.image[0..block_bytes], 0);
    std.mem.writeInt(u32, rig.medium.image[0..4], sdk.dos.posfs.layout.label_magic, .little);

    var medium: automount.MediumNode = .{};
    var drives: automount.Drives = .{};
    automount.mountMedium(rig.sys, dos_rig.dl, removable(&medium), &drives);
    try testing.expectEqual(@as(u32, 1), drives.count);
    try testing.expectEqualStrings("SD0", nameText(&drives.names[0]));
    const node = dos_rig.device("SD0") orelse return error.NotMounted;
    try testing.expectEqualStrings(sdk.dos.posfs.HANDLER_NAME, std.mem.span(node.misc.handler.handler.?));
    const startup = sdk.dos.filehandler.startupOf(node.misc.handler.startup) orelse return error.NoStartup;
    try testing.expectEqual(&medium.startup, startup);
    try testing.expectEqual(sdk.dos.posfs.ID_POSFS_DISK, startup.environ.?.dos_type);
    try testing.expect(startup.environ.?.wholeMedium());

    // The unit has a drive now: another look makes none, and names that
    // drive to be started.
    var again: automount.MediumNode = .{};
    var more: automount.Drives = .{};
    automount.mountMedium(rig.sys, dos_rig.dl, removable(&again), &more);
    try testing.expectEqual(@as(u32, 1), more.count);
    try testing.expectEqualStrings("SD0", nameText(&more.names[0]));
    try testing.expect(dos_rig.device("SD0.") == null);
}

// --- file systems kept in the table --------------------------------------------

/// A DosType no handler of the system serves.
const tes: u32 = 0x5445_5300;

/// A handler's load file filling `into`: the header, one data segment
/// with a ROM tag at its start naming "test-handler", version `version`
/// and the revision its ID string `id` gives, then bytes that count up.
fn handlerFile(into: []u8, version: u8, id: []const u8) void {
    const put32 = struct {
        fn put(file: []u8, at: usize, value: u32) void {
            std.mem.writeInt(u32, file[at..][0..4], value, .little);
        }
    }.put;
    for (into, 0..) |*byte, index| byte.* = @truncate(index * 13 + 7);
    const segment = 20 + 16;
    const size: u32 = @intCast(into.len - segment);
    @memset(into[0 .. segment + 80], 0);
    @memcpy(into[0..4], &sdk.dos.loadfile.MAGIC);
    std.mem.writeInt(u16, into[4..6], sdk.dos.loadfile.VERSION, .little);
    std.mem.writeInt(u16, into[6..8], 1, .little);
    std.mem.writeInt(u16, into[10..12], sdk.dos.loadfile.native_machine, .little);
    into[16] = 4;
    into[20] = @intFromEnum(sdk.dos.loadfile.SegmentKind.data);
    put32(into, 24, size);
    put32(into, 28, size);
    std.mem.writeInt(u16, into[segment..][0..2], 0x4AFC, .little);
    put32(into, segment + 4, 0);
    into[segment + 13] = version;
    into[segment + 14] = @intFromEnum(exec.NodeType.handler);
    put32(into, segment + 16, 32);
    put32(into, segment + 20, 48);
    @memcpy(into[segment + 32 ..][0.."test-handler".len], "test-handler");
    @memcpy(into[segment + 48 ..][0..id.len], id);
}

/// The code of the chain of LoadSegBlocks from `first` on the medium,
/// into `into`: the bytes put there.
fn chainOf(rig: *Rig, first: u32, into: []u8) !usize {
    var next = first;
    var length: usize = 0;
    while (next != hardblocks.end_of_list) {
        const block = rig.medium.image[next * block_bytes ..][0..block_bytes];
        const data = hardblocks.loadSegData(block) orelse return error.Broken;
        @memcpy(into[length..][0..data.len], data);
        length += data.len;
        next = rig.block(hardblocks.LoadSegBlock, next).next;
    }
    return length;
}

test "a file system kept in the table: added, written as a header and a chain of code, read back, replaced and taken out" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const rb = rig.rb;
    var code: [2000]u8 = undefined;
    handlerFile(&code, 2, "test-handler 2.5 (18.10.2026)\r\n");
    const room = comptime hardblocks.loadSegRoom(block_bytes);
    const code_blocks = (code.len + room - 1) / room;
    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        // Nothing to keep it in before there is a table, and code that
        // is no handler's load file is refused.
        try testing.expectEqual(rdb.RDBERR_NORDB, rb.AddFileSystem(handle, tes, &code, code.len));
        try testing.expectEqual(rdb.RDBERR_OK, rb.InitRDB(handle));
        try testing.expectEqual(rdb.RDBERR_OK, rb.AddPartition(handle, "DH0", 16, 63, tes));
        const rubbish = [_]u8{0x55} ** 64;
        try testing.expectEqual(rdb.RDBERR_FILESYSTEM, rb.AddFileSystem(handle, tes, &rubbish, rubbish.len));
        try testing.expect(rb.NextFileSystem(handle, null) == null);

        try testing.expectEqual(rdb.RDBERR_OK, rb.AddFileSystem(handle, tes, &code, code.len));
        const added = rb.NextFileSystem(handle, null).?;
        try testing.expectEqual(tes, added.header.dos_type);
        try testing.expectEqual(@as(u32, 0x0002_0005), added.header.version);
        try testing.expectEqual(hardblocks.FHBF_SEGLIST, added.header.patch_flags);
        try testing.expectEqual(@as(u32, code.len), added.size);
        try testing.expectEqual(@as(u32, 0), added.blocks);
        try testing.expectEqual(hardblocks.end_of_list, added.at);
        try testing.expect(rb.NextFileSystem(handle, added) == null);

        try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));
        try testing.expectEqual(@as(u32, code_blocks), added.blocks);
        try testing.expect(added.at < 16);
        try testing.expectEqual(added.at, rig.block(hardblocks.RigidDiskBlock, handle.block).file_sys_header_list);
    }

    // Read back as written: the header, and the code in its chain.
    var first_code: u32 = undefined;
    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        try testing.expectEqual(rdb.RDBF_FOUND, handle.flags);
        const read = rb.NextFileSystem(handle, null).?;
        try testing.expectEqual(@as(u32, 0x0002_0005), read.header.version);
        try testing.expectEqual(@as(u32, code.len), read.size);
        try testing.expectEqual(@as(u32, code_blocks), read.blocks);
        const header = rig.block(hardblocks.FileSysHeaderBlock, read.at);
        try testing.expect(hardblocks.sound(header, hardblocks.IDNAME_FILESYSHEADER));
        try testing.expectEqual(tes, header.dos_type);
        first_code = @bitCast(header.seg_list_blocks);
        var back: [code.len]u8 = undefined;
        try testing.expectEqual(@as(usize, code.len), try chainOf(&rig, first_code, &back));
        try testing.expectEqualSlices(u8, &code, &back);

        // Written again, the code stays where it is under a new header.
        const old_header = read.at;
        try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));
        try testing.expect(read.at != old_header);
        try testing.expectEqual(first_code, @as(u32, @bitCast(rig.block(hardblocks.FileSysHeaderBlock, read.at).seg_list_blocks)));
    }

    // A newer version for the same DosType takes the old one's place.
    var newer: [1000]u8 = undefined;
    handlerFile(&newer, 2, "test-handler 2.6 (19.10.2026)\r\n");
    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        try testing.expectEqual(rdb.RDBERR_OK, rb.AddFileSystem(handle, tes, &newer, newer.len));
        const only = rb.NextFileSystem(handle, null).?;
        try testing.expectEqual(@as(u32, 0x0002_0006), only.header.version);
        try testing.expect(rb.NextFileSystem(handle, only) == null);
        try testing.expect(handle.flags & rdb.RDBF_CHANGED != 0);
        try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));
    }
    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        const only = rb.NextFileSystem(handle, null).?;
        try testing.expectEqual(@as(u32, 0x0002_0006), only.header.version);
        try testing.expectEqual(@as(u32, newer.len), only.size);
        var back: [newer.len]u8 = undefined;
        _ = try chainOf(&rig, @bitCast(only.header.seg_list_blocks), &back);
        try testing.expectEqualSlices(u8, &newer, &back);
        try testing.expect(rb.NextFileSystem(handle, only) == null);

        rb.RemFileSystem(handle, only);
        try testing.expect(rb.NextFileSystem(handle, null) == null);
        try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));
        try testing.expectEqual(hardblocks.end_of_list, rig.block(hardblocks.RigidDiskBlock, handle.block).file_sys_header_list);
    }
    const handle = try rig.open();
    defer rb.CloseRDB(handle);
    try testing.expect(rb.NextFileSystem(handle, null) == null);
    try testing.expectEqualStrings("DH0", rb.NextPartition(handle, null).?.block.name());
}

test "code that does not fit in the table's area grows it up to the first partition, and no further" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const rb = rig.rb;
    const room = comptime hardblocks.loadSegRoom(block_bytes);
    // Twenty blocks of code: the area's sixteen hold the RigidDiskBlock,
    // the PartitionBlock, the header and thirteen of them.
    var code: [20 * room]u8 = undefined;
    handlerFile(&code, 1, "test-handler 1.0 (18.10.2026)\r\n");
    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        try testing.expectEqual(rdb.RDBERR_OK, rb.InitRDB(handle));
        try testing.expectEqual(rdb.RDBERR_OK, rb.AddPartition(handle, "DH0", 40, 63, tes));
        try testing.expectEqual(rdb.RDBERR_OK, rb.AddFileSystem(handle, tes, &code, code.len));
        try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));
        try testing.expectEqual(@as(u32, 22), handle.rdb.rdb_blocks_hi);
        try testing.expectEqual(@as(u32, 23), handle.rdb.lo_cylinder);
        // The free cylinders before DH0 start past the area now.
        try testing.expectEqual(rdb.RDBERR_RANGE, rb.AddPartition(handle, "DH1", 22, 30, tes));
    }
    const handle = try rig.open();
    defer rb.CloseRDB(handle);
    try testing.expectEqual(@as(u32, 22), handle.rdb.rdb_blocks_hi);
    const kept = rb.NextFileSystem(handle, null).?;
    try testing.expectEqual(@as(u32, 20), kept.blocks);
    var back: [code.len]u8 = undefined;
    _ = try chainOf(&rig, @bitCast(kept.header.seg_list_blocks), &back);
    try testing.expectEqualSlices(u8, &code, &back);

    // Forty blocks do not fit before DH0 at block 40, beside the old
    // table or over it: nothing is written.
    var larger: [40 * room]u8 = undefined;
    handlerFile(&larger, 1, "test-handler 1.1 (18.10.2026)\r\n");
    try testing.expectEqual(rdb.RDBERR_OK, rb.AddFileSystem(handle, tes, &larger, larger.len));
    const before = rig.medium.image;
    try testing.expectEqual(rdb.RDBERR_FULL, rb.WriteRDB(handle));
    try testing.expectEqualSlices(u8, &before, &rig.medium.image);
}

test "a partition runs the code its table brings, and the unit's partitions share one copy" {
    var dos_rig = try DosRig.init();
    defer dos_rig.deinit() catch unreachable;
    const rig = &dos_rig.rig;
    const rb = rig.rb;
    var code: [2000]u8 = undefined;
    handlerFile(&code, 2, "test-handler 2.5 (18.10.2026)\r\n");
    try writeTwo(rig, tes);
    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        // No handler for the DosType, and no code for it yet.
        try testing.expectEqual(rdb.RDBERR_FILESYSTEM, rb.MountPartition(handle, rb.FindPartition(handle, "DH0").?, null, 0));
        try testing.expectEqual(rdb.RDBERR_OK, rb.AddFileSystem(handle, tes, &code, code.len));
        try testing.expectEqual(rdb.RDBERR_OK, rb.WriteRDB(handle));
    }
    {
        const handle = try rig.open();
        defer rb.CloseRDB(handle);
        // Code the chain no longer holds whole cannot be copied.
        const first: u32 = @bitCast(rb.NextFileSystem(handle, null).?.header.seg_list_blocks);
        rig.medium.image[first * block_bytes + 40] ^= 1;
        try testing.expectEqual(rdb.RDBERR_IO, rb.MountPartition(handle, rb.FindPartition(handle, "DH0").?, null, 0));
        try testing.expect(dos_rig.device("DH0") == null);
        rig.medium.image[first * block_bytes + 40] ^= 1;

        try testing.expectEqual(rdb.RDBERR_OK, rb.MountPartition(handle, rb.FindPartition(handle, "DH0").?, null, 0));
        try testing.expectEqual(rdb.RDBERR_OK, rb.MountPartition(handle, rb.FindPartition(handle, "DH1").?, null, 0));
    }
    const dh0 = dos_rig.device("DH0") orelse return error.NotMounted;
    const dh1 = dos_rig.device("DH1") orelse return error.NotMounted;
    try testing.expect(dh0.misc.handler.handler == null);
    const entry = dh0.misc.handler.file_sys orelse return error.NoCode;
    try testing.expectEqual(@as(?*sdk.dos.FileSysEntry, entry), dh1.misc.handler.file_sys);
    try testing.expectEqual(tes, entry.dos_type);
    try testing.expectEqual(@as(u32, 0x0002_0005), entry.version);
    try testing.expectEqualStrings("test-handler", std.mem.sliceTo(&entry.name, 0));
    try testing.expectEqualSlices(u8, &code, entry.image.?[0..entry.image_size]);
    // The entry is the system's, for its life; the test gives it back.
    rig.sys.FreeVec(entry.image);
    rig.sys.FreeVec(entry);
}
