// SPDX-License-Identifier: MIT
//! The disk laid out: a GPT with the boot partitions the firmware reads
//! and a container over the rest, a table in that container with the
//! system and the work partition in it, each written, mounted and given
//! an empty volume.
//!
//! It is the disks guide's recipe in one go, through the same library the
//! partitioner and HDToolBox use: `INIT GPT`, `ADDGPT` per boot
//! partition, the container, `ADD` twice, `MOUNT`, and a format each. The
//! boot partitions come first because a firmware looks for its files in
//! the first ones, and because the container takes what they leave.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const rdb = sdk.rdb;
const gpt = dos.gpt;
const hardblocks = dos.hardblocks;
const shared = @import("_install.zig");
const Run = shared.Run;
const Drive = shared.Drive;
const Printf = dos.stdio.Printf;

/// The system partition's boot priority: above a disk image's `DH0`,
/// which has none, so a machine with both starts from the medium.
const boot_priority: i32 = 5;

/// How long a new volume is waited for after its drive is let go, in
/// ticks between two looks and in looks.
const settle_ticks = 15;
const settle_tries = 100;

/// The whole of it. The handle is left open on the run, so that the
/// caller can say what the disk now holds; `done` closes it.
pub fn prepare(run: *Run) i32 {
    if (dismount(run)) |code| return code;

    var err: i32 = rdb.RDBERR_OK;
    const handle = run.rb.OpenRDB(run.device, run.unit, &err) orelse {
        return shared.fail(run, "%s unit %d: %s\n", .{ run.device, run.unit, errorText(err) });
    };
    run.handle = handle;

    if (table(run, handle)) |code| return code;
    if (mount(run, handle)) |code| return code;
    if (formatAll(run)) |code| return code;
    return dos.RETURN_OK;
}

/// The handle given back once the files are on the disk: the partitions
/// stay mounted, so the install writes to them through dos as to any
/// other drive.
pub fn done(run: *Run) void {
    if (run.handle) |handle| run.rb.CloseRDB(handle);
    run.handle = null;
}

/// How large the medium in the unit is, for the question before the
/// install: null when it cannot be read at all.
pub fn size(run: *Run) ?u64 {
    var err: i32 = rdb.RDBERR_OK;
    const handle = run.rb.OpenRDB(run.device, run.unit, &err) orelse return null;
    defer run.rb.CloseRDB(handle);
    return handle.disk_blocks * handle.geometry.sector_size;
}

/// A drive of this unit that holds blocks the install is about to write -
/// the drive over the whole medium a unit with no table gets (`NV0:`), or
/// a partition of the table being replaced - taken off dos's list. It is
/// not freed: a handler may still hold it, and the odds of a crash are
/// worse than the leak.
fn dismount(run: *Run) ?i32 {
    const dl = run.dl;
    while (true) {
        var name: [dos.MAX_DEVICE_NAME + 2:0]u8 = @splat(0);
        {
            const flags = dos.LDF_DEVICES | dos.LDF_WRITE;
            const list = dl.LockDosList(flags) orelse return shared.fail(run, "dos's list of devices cannot be locked\n", .{});
            defer dl.UnLockDosList(flags);
            var entry = dl.NextDosEntry(list, dos.LDF_DEVICES);
            const found = while (entry) |node| : (entry = dl.NextDosEntry(node, dos.LDF_DEVICES)) {
                const startup = dos.filehandler.startupOf(node.misc.handler.startup) orelse continue;
                if (dos.filehandler.opensUnit(startup, run.device, run.unit)) break node;
            } else null;
            const node = found orelse return null;
            const text = node.name;
            const at = shared.copy(&name, text[0..shared.length(text)]);
            name[at] = ':';
            if (!dl.RemDosEntry(node)) {
                return shared.fail(run, "%s has some of the disk's blocks and will not let go: close what is open on it\n", .{@as([*:0]const u8, @ptrCast(&name))});
            }
        }
        shared.say(run, "  %s taken off dos's list: it has blocks this install writes\n", .{@as([*:0]const u8, @ptrCast(&name))});
    }
}

/// The GPT and the table in the container, written.
fn table(run: *Run, handle: *rdb.RDBHandle) ?i32 {
    const rb = run.rb;

    // A GPT of its own, whatever the disk had: the install was confirmed.
    if (fails(run, "the GPT", rb.InitGPT(handle))) return dos.RETURN_FAIL;

    const block_bytes = handle.geometry.sector_size;
    const boot_blocks = (shared.boot_bytes + block_bytes - 1) / block_bytes;
    for (run.boot[0..run.slots]) |*drive| {
        var entry: gpt.Entry = .{ .partition_type_guid = gpt.TYPE_BASIC_DATA };
        const text = drive.name[0..shared.length(drive.name)];
        gpt.setName(&entry, text);
        // What the firmware reads is the firmware's: no drive is made
        // for it when the medium comes in, so it is not a volume to
        // work in by accident. The install mounts it itself to write
        // it, and an update asks rdb.library for it by the name
        // install.prefs keeps.
        entry.attributes |= gpt.ATTR_NO_AUTOMOUNT;
        entry.starting_lba = freeBlocks(run, handle, boot_blocks) orelse {
            var wanted_text: [16:0]u8 = @splat(0);
            shared.bytesAsText(&wanted_text, shared.boot_bytes);
            return shared.fail(run, "the disk has no room for a boot partition of %s\n", .{@as([*:0]const u8, @ptrCast(&wanted_text))});
        };
        entry.ending_lba = entry.starting_lba + boot_blocks - 1;
        var err: i32 = rdb.RDBERR_OK;
        if (rb.AddGPTPartition(handle, &entry, &err) == null) {
            return shared.fail(run, "%s: %s\n", .{ drive.name, errorText(err) });
        }
    }

    // The container over what the boot partitions leave.
    var entry: gpt.Entry = .{ .partition_type_guid = gpt.TYPE_CONTAINER };
    gpt.setName(&entry, "PowerOS");
    var err: i32 = rdb.RDBERR_OK;
    if (rb.AddGPTPartition(handle, &entry, &err) == null) {
        return shared.fail(run, "the PowerOS container: %s\n", .{errorText(err)});
    }
    if (fails(run, "the GPT", rb.WriteGPT(handle))) return dos.RETURN_FAIL;

    // The table in the container, and the two partitions in that.
    if (fails(run, "the table", rb.InitRDB(handle))) return dos.RETURN_FAIL;
    const cylinder_bytes = @as(u64, handle.rdb.cyl_blocks) * handle.rdb.block_bytes;
    if (cylinder_bytes == 0) return shared.fail(run, "the container has no cylinders\n", .{});
    const cylinders = @as(u64, handle.rdb.hi_cylinder - handle.rdb.lo_cylinder + 1);
    const container_bytes = cylinders * cylinder_bytes;

    var wanted = run.size;
    if (wanted == 0) wanted = @min(shared.system_bytes, container_bytes / 2);
    const count = (wanted + cylinder_bytes - 1) / cylinder_bytes;
    const low = freeCylinders(run, handle, count) orelse {
        var wanted_text: [16:0]u8 = @splat(0);
        var held_text: [16:0]u8 = @splat(0);
        shared.bytesAsText(&wanted_text, wanted);
        shared.bytesAsText(&held_text, container_bytes);
        return shared.fail(run, "the container has no %s in a row: it holds %s\n", .{
            @as([*:0]const u8, @ptrCast(&wanted_text)),
            @as([*:0]const u8, @ptrCast(&held_text)),
        });
    };
    if (fails(run, run.system.name, rb.AddPartition(handle, run.system.name, low, @intCast(low + count - 1), run.system.dos_type))) return dos.RETURN_FAIL;
    if (rb.FindPartition(handle, run.system.name)) |part| {
        part.block.flags |= hardblocks.PBFF_BOOTABLE;
        part.block.environment.boot_pri = boot_priority;
    }

    // The rest of the container, where there is a cylinder left for it.
    if (freeCylinders(run, handle, 1) != null) {
        if (fails(run, run.work.name, rb.AddPartition(handle, run.work.name, 0, 0, run.work.dos_type))) return dos.RETURN_FAIL;
    } else {
        run.work.name = "";
        shared.say(run, "  (no room left for %s: the system partition has the container)\n", .{shared.default_work});
    }
    if (fails(run, "the table", rb.WriteRDB(handle))) return dos.RETURN_FAIL;
    return null;
}

/// Every partition mounted and its handler started, so that the install
/// writes to them through dos.
fn mount(run: *Run, handle: *rdb.RDBHandle) ?i32 {
    const rb = run.rb;
    for (run.boot[0..run.slots]) |*drive| {
        const part = gptPartitionNamed(run, handle, drive.name) orelse {
            return shared.fail(run, "%s is not in the GPT that was just written\n", .{drive.name});
        };
        // A partition whose first block is all zeroes is a new one, which
        // MountGPTPartition mounts for FAT and C:Format gives a volume.
        if (!clearFirstBlock(run, handle, part)) return dos.RETURN_FAIL;
        var name: rdb.MountName = @splat(0);
        const flags = rdb.RDBMF_START | rdb.RDBMF_FAT | rdb.mountFormat(dos.fat.formatOfType(drive.dos_type));
        const err = rb.MountGPTPartition(handle, part, drive.name, &name, flags);
        if (err != rdb.RDBERR_OK) return shared.fail(run, "%s: %s\n", .{ drive.name, errorText(err) });
        shared.mountedName(&drive.mounted, &name);
    }
    for ([_]*Drive{ &run.system, &run.work }) |drive| {
        if (drive.name[0] == 0) continue;
        const part = rb.FindPartition(handle, drive.name) orelse {
            return shared.fail(run, "%s is not in the table that was just written\n", .{drive.name});
        };
        var name: rdb.MountName = @splat(0);
        const err = rb.MountPartition(handle, part, &name, rdb.RDBMF_START);
        if (err != rdb.RDBERR_OK) return shared.fail(run, "%s: %s\n", .{ drive.name, errorText(err) });
        shared.mountedName(&drive.mounted, &name);
    }
    return null;
}

/// An empty volume on each of them.
fn formatAll(run: *Run) ?i32 {
    for (run.boot[0..run.slots]) |*drive| {
        if (format(run, drive)) |code| return code;
    }
    for ([_]*Drive{ &run.system, &run.work }) |drive| {
        if (!drive.there()) continue;
        if (format(run, drive)) |code| return code;
    }
    return null;
}

/// One drive given a fresh volume: held still, written, let go, and
/// waited for until it shows the volume. The drive's own DosType says
/// which file system it gets, so the format is told none.
fn format(run: *Run, drive: *const Drive) ?i32 {
    const dl = run.dl;
    const name = drive.path();
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.FORMAT_BlockSize, .data = 0 },
        .{ .tag = sdk.utility.TAG_DONE, .data = 0 },
    };
    shared.say(run, "  %-10s %s\n", .{ name, drive.label });
    if (!dl.Inhibit(name, true)) return shared.failed(run, name, dl.IoErr());
    const made = dl.FormatTags(name, drive.label, 0, &tags);
    const code = dl.IoErr();
    _ = dl.Inhibit(name, false);
    if (!made) return shared.failed(run, name, code);
    if (!settled(run, name)) return shared.failed(run, name, dos.ERROR_NOT_A_DOS_DISK);
    return null;
}

/// Whether a drive shows a volume again once let go: it reads the medium
/// when the last inhibit is taken back, and a file system may then still
/// be checking what it found.
fn settled(run: *Run, name: [*:0]const u8) bool {
    const dl = run.dl;
    var tries: u32 = 0;
    while (tries < settle_tries) : (tries += 1) {
        const dp = dl.GetDeviceProc(name, null);
        if (dp) |proc| {
            defer dl.FreeDeviceProc(proc);
            if (proc.port) |port| {
                var info: dos.InfoData = .{};
                if (dl.DoPkt(port, @intFromEnum(dos.ActionCode.disk_info), @bitCast(@intFromPtr(&info)), 0, 0, 0, 0) != dos.DOSFALSE and
                    info.disk_state != dos.ID_VALIDATING and readable(info.disk_type)) return true;
            }
        }
        dl.Delay(settle_ticks);
    }
    return false;
}

/// Whether an id_DiskType names a volume a file system reads.
fn readable(disk_type: u32) bool {
    return switch (disk_type) {
        dos.ID_NO_DISK_PRESENT, dos.ID_UNREADABLE_DISK, dos.ID_NOT_REALLY_DOS, dos.ID_BUSY_DISK => false,
        else => true,
    };
}

/// The first block of a GPT partition cleared, so that what was on the
/// disk before is not taken for a volume.
fn clearFirstBlock(run: *Run, handle: *rdb.RDBHandle, part: *const rdb.GPTPartition) bool {
    const sys = run.sys;
    const bytes = handle.geometry.sector_size;
    const port = sys.CreateMsgPort() orelse return notCleared(run, "not enough memory");
    defer sys.DeleteMsgPort(port);
    const request = sys.CreateIORequest(port, @sizeOf(exec.IOStdReq)) orelse return notCleared(run, "not enough memory");
    defer sys.DeleteIORequest(request);
    const block = sys.AllocVec(bytes, exec.MEMF_CLEAR) orelse return notCleared(run, "not enough memory");
    defer sys.FreeVec(block);
    if (sys.OpenDevice(run.device, run.unit, request, 0) != 0) return notCleared(run, "the device cannot be opened");
    defer sys.CloseDevice(request);
    const io: *exec.IOStdReq = @ptrCast(@alignCast(request));
    io.req.command = exec.CMD_WRITE;
    io.data = block;
    io.length = bytes;
    io.offset = part.entry.starting_lba * bytes;
    if (sys.DoIO(request) != 0) return notCleared(run, "the device refused the write");
    io.req.command = exec.CMD_UPDATE;
    _ = sys.DoIO(request);
    return true;
}

fn notCleared(run: *Run, why: [*:0]const u8) bool {
    _ = shared.fail(run, "a boot partition's first block is not cleared: %s\n", .{why});
    return false;
}

/// The GPT's partition of that name.
fn gptPartitionNamed(run: *Run, handle: *rdb.RDBHandle, name: [*:0]const u8) ?*rdb.GPTPartition {
    const wanted = name[0..shared.length(name)];
    var part = run.rb.NextGPTPartition(handle, null);
    while (part) |one| : (part = run.rb.NextGPTPartition(handle, one)) {
        var text: [gpt.name_units:0]u8 = @splat(0);
        _ = gpt.nameText(&one.entry, &text);
        const got: [*:0]const u8 = @ptrCast(&text);
        if (sameText(got, wanted)) return one;
    }
    return null;
}

fn sameText(text: [*:0]const u8, wanted: []const u8) bool {
    for (wanted, 0..) |char, at| {
        if (text[at] != char) return false;
    }
    return text[wanted.len] == 0;
}

/// The first block of the first `count` free blocks in a row of the
/// GPT's usable ones that starts on a MiB, or null.
fn freeBlocks(run: *Run, handle: *rdb.RDBHandle, count: u64) ?u64 {
    const block_bytes = handle.geometry.sector_size;
    var best: ?u64 = null;
    var start = handle.gpt_header.first_usable_lba;
    var part: ?*rdb.GPTPartition = null;
    while (true) {
        const first = gpt.alignUp(start, block_bytes);
        if (blocksFree(run, handle, first, count) and (best == null or first < best.?)) best = first;
        part = run.rb.NextGPTPartition(handle, part);
        const one = part orelse break;
        start = one.entry.ending_lba + 1;
    }
    return best;
}

fn blocksFree(run: *Run, handle: *rdb.RDBHandle, first: u64, count: u64) bool {
    const last = first + count - 1;
    if (count == 0 or last > handle.gpt_header.last_usable_lba) return false;
    var part = run.rb.NextGPTPartition(handle, null);
    while (part) |one| : (part = run.rb.NextGPTPartition(handle, one)) {
        if (first <= one.entry.ending_lba and one.entry.starting_lba <= last) return false;
    }
    return true;
}

/// The first of the first `count` free cylinders in a row of the table's
/// usable ones, or null.
fn freeCylinders(run: *Run, handle: *rdb.RDBHandle, count: u64) ?u32 {
    var best: ?u64 = null;
    var first: u64 = handle.rdb.lo_cylinder;
    var part: ?*rdb.RDBPartition = null;
    while (true) {
        if (cylindersFree(run, handle, first, count) and (best == null or first < best.?)) best = first;
        part = run.rb.NextPartition(handle, part);
        const one = part orelse break;
        first = @as(u64, one.block.environment.high_cyl) + 1;
    }
    return if (best) |cylinder| @intCast(cylinder) else null;
}

fn cylindersFree(run: *Run, handle: *rdb.RDBHandle, first: u64, count: u64) bool {
    const last = first + count - 1;
    if (count == 0 or last > handle.rdb.hi_cylinder) return false;
    var part = run.rb.NextPartition(handle, null);
    while (part) |one| : (part = run.rb.NextPartition(handle, one)) {
        const env = &one.block.environment;
        if (first <= env.high_cyl and env.low_cyl <= last) return false;
    }
    return true;
}

/// Whether a library call failed; if it did, what it said.
fn fails(run: *Run, what: [*:0]const u8, err: i32) bool {
    if (err == rdb.RDBERR_OK) return false;
    _ = shared.fail(run, "%s: %s\n", .{ what, errorText(err) });
    return true;
}

fn errorText(err: i32) [*:0]const u8 {
    return switch (err) {
        rdb.RDBERR_NOMEM => "not enough memory",
        rdb.RDBERR_DEVICE => "no such device or unit, or no medium in it",
        rdb.RDBERR_IO => "the device refused a transfer",
        rdb.RDBERR_NORDB => "the disk has no table",
        rdb.RDBERR_BLOCKSIZE => "the medium cannot take blocks of this size",
        rdb.RDBERR_NAME => "a name that is empty, too long, holds a colon or a slash, or is taken",
        rdb.RDBERR_RANGE => "blocks outside the usable ones, the wrong way round, or taken",
        rdb.RDBERR_FULL => "no room in the table's blocks for another partition",
        rdb.RDBERR_FILESYSTEM => "no handler serves its DosType here",
        rdb.RDBERR_CHANGED => "the medium in the unit is not the one the table was read from",
        rdb.RDBERR_MOUNTED => "a drive has some of its blocks already",
        rdb.RDBERR_GPT => "the call does not go with the disk's GPT",
        rdb.RDBERR_NOGPT => "the disk has no sound GPT",
        else => "failed",
    };
}
