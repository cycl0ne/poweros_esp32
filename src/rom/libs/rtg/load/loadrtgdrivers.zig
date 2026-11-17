// SPDX-License-Identifier: MPL-2.0
//! LoadRtgDrivers: The drivers on the disk that take a device of this
//! machine, loaded and bound.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const dos = sdk.dos;
const RtgBase = @import("../rtg.zig").RtgBase;
const devices = @import("../device/_device.zig");
const settings = @import("../settings/_settings.zig");
const load = @import("_load.zig");

/// Loads the display drivers in `DEVS:gfxdrv/` that take a device no
/// driver has, and binds them.
///
/// SYNOPSIS:
/// ```zig
/// fn LoadRtgDrivers(rb: *RtgBase) u32
/// ```
///
/// SINCE: 1.35. LVO -124.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// How many boards were made. 0 where there is nothing to load, and
/// where dos.library cannot be opened.
///
/// BEHAVIOR:
/// Every file of `DEVS:gfxdrv/` is read for its ROM tag. One of the
/// type of a display driver says its name and what it takes - a part's
/// chip or bus, a function on PCI by vendor, device or class - and that
/// is read out of the file: nothing is loaded for it and no code of the
/// file runs.
///
/// A file is loaded where its table names a device of this machine
/// that no driver has. Passed over are a driver whose name is on the
/// list already - the ROM's is the one used, and a second call loads
/// nothing twice - and a device whose settings line says `DRIVER=OFF`
/// (`SetRtgDeviceDriver`). The function a card is on PCI is such a
/// device even while the picture its firmware lit is shown by another
/// driver.
///
/// Before a file is loaded, the driver's name is written to
/// `ENVARC:Sys/display.trying`, a name a line. A driver that hangs the
/// machine as it is bound, or as it first shows a picture, leaves its
/// name there, and a name found there is not loaded again: the
/// system's log says so. `C:Rtg TRIED`, which the startup-sequence runs
/// once the desktop is up, takes the names of the drivers on the list
/// out of the file; `C:Rtg RETRY` deletes it and loads again.
///
/// Then every device no driver has is given its settings line in front
/// of its tags, and the drivers are bound as `BindRtgDrivers` binds
/// them: each such device is offered to the drivers whose table names
/// it, the loaded ones among them. A loaded driver stays on the list
/// whether it took a device or not. The tasks that asked are told of
/// each board made (`AddRtgNotify`).
///
/// CONTEXT:
/// - Waits: yes, for the file system, and where a driver waits for its
///   hardware.
/// - Interrupts: no.
/// - Locks: takes the device list's lock while it reads what the files
///   say, and gives it back before a file is loaded. No spinlock may
///   be held.
/// - Process: a Process, for the files.
///
/// OWNERSHIP:
/// A loaded driver's segments are the library's from then on, with its
/// node. A file that is loaded and holds no driver after all is
/// unloaded.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BindRtgDrivers`, `GetRtgDrivers`, `SetRtgDeviceDriver`,
/// `LoadBoardSettings`
///
/// EXAMPLES:
/// ```zig
/// // What C:BindDrivers does before the desktop opens.
/// const made = rb.LoadRtgDrivers();
/// ```
pub fn LoadRtgDrivers(rb: *RtgBase) u32 {
    const sys = rb.sys_base;
    const dl = settings.dosBase(rb) orelse return 0;

    // The machine's own devices are on the list before a file's table
    // is held against them.
    sys.ObtainSemaphore(&rb.device_lock);
    devices.listMachine(rb);
    sys.ReleaseSemaphore(&rb.device_lock);

    if (dl.Lock(load.directory, dos.SHARED_LOCK)) |dir| {
        defer dl.UnLock(dir);
        var names: [load.trying_most]u8 = undefined;
        var fib: dos.FileInfoBlock = .{};
        if (dl.Examine(dir, &fib)) {
            while (dl.ExNext(dir, &fib)) {
                if (dos.isDirectory(fib.dir_entry_type)) continue;
                loadOne(rb, dl, &fib, &names);
            }
        }
    }

    settings.dressAll(rb);
    return rb.iface().BindRtgDrivers();
}

/// One file of the directory: read for what it says, and loaded where
/// it is a driver this machine wants.
fn loadOne(rb: *RtgBase, dl: *sdk.interface.dos.DosBase, fib: *const dos.FileInfoBlock, names: *[load.trying_most]u8) void {
    const sys = rb.sys_base;
    var path: [load.directory.len + 1 + dos.name_max + 1]u8 = @splat(0);
    @memcpy(path[0..load.directory.len], load.directory);
    path[load.directory.len] = '/';
    var length: usize = 0;
    while (length < fib.file_name.len and fib.file_name[length] != 0) : (length += 1) {
        path[load.directory.len + 1 + length] = fib.file_name[length];
    }
    const file_path: [*:0]const u8 = @ptrCast(&path);

    var described: load.Described = .{};
    {
        const file = dl.Open(file_path, dos.MODE_OLDFILE) orelse return;
        defer _ = dl.Close(file);
        var opened = load.DosFile{ .dl = dl, .file = file };
        if (!load.describe(opened.source(), &described)) return;
    }
    sys.ObtainSemaphore(&rb.device_lock);
    const wanted = load.wanted(rb, &described);
    sys.ReleaseSemaphore(&rb.device_lock);
    if (!wanted) return;

    const name = described.nameText();
    const before = load.readTrying(dl, names);
    if (load.tried(before, name)) {
        exec.kprintf(sys, "rtg.library: the driver %s did not come back the last time it was tried, and is not loaded (Rtg RETRY)\n", .{@as([*:0]const u8, @ptrCast(&described.name))});
        return;
    }
    _ = load.noteTrying(dl, before, name);

    const segments = dl.LoadSeg(file_path) orelse return;
    const tag = dl.FindSegResident(segments, null, .rtg_driver) orelse {
        dl.UnLoadSeg(segments);
        return;
    };
    const in_file: *const rtg.ResidentRtgDriver = @fieldParentPtr("resident", tag);
    if (rb.driverIface().AddRtgDriver(&in_file.spec, segments) == null) dl.UnLoadSeg(segments);
}
