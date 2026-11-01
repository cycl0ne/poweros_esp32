// SPDX-License-Identifier: MIT
//! The units an install can go onto, listed with what each one holds.
//! This is what `Install` with no DEVICE prints: the machine's block
//! devices, their units and sizes, what table each unit has, and which
//! one the running system is on - which is the one not to install over.

const sdk = @import("sdk");
const dos = sdk.dos;
const rdb = sdk.rdb;
const devices = sdk.expansion.devices;
const shared = @import("_install.zig");
const Run = shared.Run;
const Printf = dos.stdio.Printf;

const row = "  %-16s %4d  %8s  %s\n";

/// Every unit of every block device that has a medium in it, with what
/// that medium holds. A device offers every unit it could ever have -
/// eight of them each here - and a unit with nothing in it says nothing
/// worth a line, so those are counted instead. The return code is 0, or
/// a warning when there is no medium anywhere.
pub fn list(run: *Run) i32 {
    const dl = run.dl;
    const list_of_units = run.eb.ObtainDeviceUnits(devices.DEVIF_BLOCK, null) orelse {
        return shared.failed(run, shared.COMMAND_NAME, dos.ERROR_NO_FREE_STORE);
    };
    defer run.eb.ReleaseDeviceUnits(list_of_units);

    _ = dl.PutStr("The units an install can go onto:\n\n");
    _ = Printf(dl, "  %-16s %4s  %8s  %s\n", .{ "Device", "Unit", "Size", "What it holds" });
    var count: u32 = 0;
    var empty: u32 = 0;
    var walk = list_of_units.iterator();
    while (walk.next()) |node| {
        const unit: *const devices.DeviceUnit = @ptrCast(@alignCast(node));
        const name = unit.node.name orelse continue;
        var size: [16:0]u8 = @splat(0);
        var holds: [120:0]u8 = @splat(0);
        if (!look(run, name, unit.unit, &size, &holds)) {
            empty += 1;
            continue;
        }
        count += 1;
        _ = Printf(dl, row, .{ name, unit.unit, @as([*:0]const u8, @ptrCast(&size)), @as([*:0]const u8, @ptrCast(&holds)) });
    }
    if (count == 0) _ = dl.PutStr("  (none: no medium in any unit of any block device)\n");
    if (empty != 0) {
        _ = Printf(dl, "  (%d other units have no medium in them; a card or a stick put in now shows up here)\n", .{empty});
    }
    if (count == 0) return dos.RETURN_WARN;
    _ = Printf(dl, "\nInstall <device> [<unit>] puts a system on one. %s ? says what else it takes.\n", .{shared.COMMAND_NAME});
    return dos.RETURN_OK;
}

/// What a unit holds, as text: its size, and its table with how many
/// partitions are in it. False for a unit with no medium in it, which is
/// counted rather than printed; a medium that cannot be read is worth a
/// line, since it is one an install would put a table on.
fn look(run: *Run, name: [*:0]const u8, unit: u32, size: *[16:0]u8, holds: *[120:0]u8) bool {
    var err: i32 = rdb.RDBERR_OK;
    const handle = run.rb.OpenRDB(name, unit, &err) orelse {
        if (err == rdb.RDBERR_DEVICE) return false;
        size[shared.copy(size, "-")] = 0;
        holds[shared.copy(holds, "cannot be read")] = 0;
        return true;
    };
    defer run.rb.CloseRDB(handle);

    shared.bytesAsText(size, handle.disk_blocks * handle.geometry.sector_size);

    var at: usize = 0;
    if (handle.flags & rdb.RDBF_GPT != 0) {
        at += shared.copy(holds[at..], "a GPT");
        if (handle.flags & rdb.RDBF_GPTDAMAGED != 0) at += shared.copy(holds[at..], " that is not sound");
        at += shared.copy(holds[at..], ", ");
        at += shared.copy(holds[at..], if (handle.flags & rdb.RDBF_CONTAINER != 0) "a PowerOS container in it" else "no PowerOS container");
    } else if (handle.flags & rdb.RDBF_FOREIGN != 0) {
        at += shared.copy(holds[at..], "a table for another block size");
    } else if (handle.flags & rdb.RDBF_FOUND != 0) {
        at += shared.copy(holds[at..], "a table over the whole disk");
    } else {
        at += shared.copy(holds[at..], "nothing: no table");
    }

    var partitions: u32 = 0;
    var part = run.rb.NextPartition(handle, null);
    while (part) |one| : (part = run.rb.NextPartition(handle, one)) partitions += 1;
    if (partitions != 0) {
        at += shared.copy(holds[at..], ", ");
        at += shared.decimal(holds[at..], partitions);
        at += shared.copy(holds[at..], if (partitions == 1) " partition" else " partitions");
    }
    if (onIt(run, name, unit)) at += shared.copy(holds[at..], " - the running system is on it");
    holds[at] = 0;
    return true;
}

/// Whether a drive of this unit holds the volume SYS: is on: the disk an
/// install would be writing over while it runs from it.
pub fn onIt(run: *Run, name: [*:0]const u8, unit: u32) bool {
    const dl = run.dl;
    const dp = dl.GetDeviceProc("SYS:", null) orelse return false;
    defer dl.FreeDeviceProc(dp);
    const node = dp.dev_node orelse return false;
    // SYS: is an assign to a volume, whose node names no device: the
    // drive it is in is the device node of the same handler task.
    const task = node.task orelse return false;
    const flags = dos.LDF_DEVICES | dos.LDF_READ;
    const devices_list = dl.LockDosList(flags) orelse return false;
    defer dl.UnLockDosList(flags);
    var entry = dl.NextDosEntry(devices_list, dos.LDF_DEVICES);
    while (entry) |one| : (entry = dl.NextDosEntry(one, dos.LDF_DEVICES)) {
        if (one.task != task) continue;
        const startup = dos.filehandler.startupOf(one.misc.handler.startup) orelse continue;
        if (dos.filehandler.opensUnit(startup, name, unit)) return true;
    }
    return false;
}
