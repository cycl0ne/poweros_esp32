// SPDX-License-Identifier: MIT
//! Info: what is mounted, how full it is, and which volumes are in. Built
//! against the SDK only.
//!
//!   Info DEVICE
//!
//!   Info          every mounted disk, then every volume
//!   Info DH0:     that one, with the volume in it
//!
//! It asks each device's handler ACTION_DISK_INFO and prints two
//! sections:
//!
//!   Mounted disks:
//!   Unit      Size    Used    Free Full Errs   Status   Name
//!   DH0:     14932K      27    3796   1%   0   Read/Write System
//!
//!   Volumes available:
//!   System [Mounted]
//!
//! It copies each node and its InfoData while the DosList is locked, lets the
//! lock go, and only then prints. Printing can block on a console, and nothing
//! else could add or remove a device meanwhile. The data may be stale by the
//! time it reaches the screen - a disk could have gone - and that is accepted.
//!
//! - **`ID_FLASHFS_DISK` counts as a file system.** A DosType that is not
//!   in the list is unreadable; the flash disk's is `FLS\0`, so it is in the
//!   list. An unformatted partition still answers `ID_NOT_REALLY_DOS` and
//!   still prints "Not a DOS disk", which is what it is.
//! - **Sizes are 64-bit.** id_NumBlocks and id_NumBlocksUsed are u64 here,
//!   so a disk larger than 4 GiB counts correctly; a 32-bit product would
//!   wrap.
//! - **Names are C strings**, not BSTRs, and `id_VolumeNode` is a pointer,
//!   so the volume's name is read straight off the node instead of through
//!   BADDR twice.
//! - A handler that does not answer DISK_INFO (NIL:, PIPE:) is skipped.
//! - **A console is skipped too.** CON: and RAW: do answer DISK_INFO, with
//!   `ID_CON` and `ID_RAWCON`, which are not file systems, so they would
//!   print as "CON: Unreadable disk", which is not true of anything. The
//!   shell opens CON: at boot, so it would be on every listing. Info is
//!   about disks, and a console says plainly that it is not one.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Info";
const VERSION_STRING = "\x00$VER: Info 1.0 (16.9.2026)\r\n";

const template = "DEVICE";
const arg_device = 0;

const MSG_VOL_MOUNTED = "[Mounted]";
const MSG_DEV_HEADER = "\nMounted disks:\n" ++
    "Unit      Size    Used    Free Full Errs   Status   Name\n";
const MSG_VOL_HEADER = "\nVolumes available:\n";
const MSG_PROT_READ_ONLY = "Read Only";
const MSG_PROT_VALIDATING = "Validating";
const MSG_PROT_READ_WRITE = "Read/Write";
const MSG_TYPE_NONE = "No disk present";
const MSG_TYPE_BAD = "Unreadable disk";
const MSG_TYPE_KICK = "Kickstart disk";
const MSG_TYPE_NDOS = "Not a DOS disk";
/// Kept apart from the format strings, because another
/// language's "Kilo" and "Mega" may not begin with K and M.
const MSG_KILOBYTES = "K";
const MSG_MEGABYTES = "M";

/// The most a device name may be: 30, the colon and the NUL.
const max_name = dos.MAX_DEVICE_NAME + 2;

/// A node and its InfoData, copied out from
/// under the list lock so that printing happens without it.
const Keeper = extern struct {
    next: ?*Keeper = null,
    node: dos.DosList = .{},
    info: dos.InfoData = .{},
};

/// A console, which is not a disk and is left out altogether.
fn isConsole(disk_type: u32) bool {
    return disk_type == dos.ID_CON or disk_type == dos.ID_RAWCON;
}

/// The DosTypes that are a file system with blocks to count, the flash
/// disk's among them - a `FLS\0` volume is as real as a `DOS\0` one.
fn isFileSystem(disk_type: u32) bool {
    return switch (disk_type) {
        dos.ID_DOS_DISK,
        dos.ID_FFS_DISK,
        dos.ID_INTER_DOS_DISK,
        dos.ID_INTER_FFS_DISK,
        dos.ID_FASTDIR_DOS_DISK,
        dos.ID_FASTDIR_FFS_DISK,
        dos.ID_MSDOS_DISK,
        dos.flashfs.ID_FLASHFS_DISK,
        => true,
        else => false,
    };
}

const Run = struct {
    sys: *ExecBase,
    dl: *DosBase,
    head: ?*Keeper = null,
    tail: ?*Keeper = null,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    var run: Run = .{ .sys = sys, .dl = dl };
    defer freeAll(&run);

    var info: dos.InfoData = .{};
    if (rdargs.string(argv[arg_device])) |asked| {
        return one(&run, asked, &info);
    }
    return all(&run, &info);
}

/// Every device, then every volume - two passes, each collecting
/// under the lock and printing after it.
fn all(run: *Run, info: *dos.InfoData) i32 {
    const dl = run.dl;
    var stopped = false;

    const devices = dos.LDF_DEVICES | dos.LDF_READ;
    if (dl.LockDosList(devices)) |start| {
        var node: ?*dos.DosList = start;
        while (dl.NextDosEntry(node.?, devices)) |entry| {
            node = entry;
            // Ctrl-C gets out of the middle of the walk.
            if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
                stopped = true;
                break;
            }
            const port = entry.task orelse continue;
            if (!diskInfo(dl, port, info)) continue;
            if (isConsole(info.disk_type)) continue;
            if (!keep(run, entry, info)) break;
        }
        dl.UnLockDosList(devices);
    }
    if (stopped) {
        // Printed with the lock let go, as everything else is.
        _ = dl.PrintFault(dos.ERROR_BREAK, null);
    }

    _ = dl.PutStr(MSG_DEV_HEADER);
    printAll(run, false);
    if (stopped) return dos.RETURN_WARN;

    const volumes = dos.LDF_VOLUMES | dos.LDF_READ;
    if (dl.LockDosList(volumes)) |start| {
        var node: ?*dos.DosList = start;
        while (dl.NextDosEntry(node.?, volumes)) |entry| {
            node = entry;
            if (!keep(run, entry, info)) break;
        }
        dl.UnLockDosList(volumes);
    }
    _ = dl.PutStr(MSG_VOL_HEADER);
    printAll(run, true);
    return dos.RETURN_OK;
}

/// One name: its device node and the volume in it, each under its own
/// header. It finds the node, asks it, and then walks the list again for
/// the other node with the same handler port - a device and the volume it
/// holds share one.
fn one(run: *Run, asked: [*:0]const u8, info: *dos.InfoData) i32 {
    const dl = run.dl;

    // The list is found by name without the colon.
    var name: [max_name:0]u8 = @splat(0);
    var at: usize = 0;
    while (asked[at] != 0 and asked[at] != ':' and at + 1 < name.len) : (at += 1) name[at] = asked[at];
    name[at] = 0;

    var device: dos.DosList = .{};
    var volume: dos.DosList = .{};
    var found = false;

    const both = dos.LDF_DEVICES | dos.LDF_VOLUMES | dos.LDF_READ;
    if (dl.LockDosList(both)) |start| {
        if (dl.FindDosEntry(start, @ptrCast(&name), both)) |entry| {
            if (entry.task) |port| {
                if (diskInfo(dl, port, info) and !isConsole(info.disk_type)) {
                    device = entry.*;
                    volume = entry.*;
                    // The partner node: the other type on the same port.
                    var node: ?*dos.DosList = start;
                    while (dl.NextDosEntry(node.?, dos.LDF_DEVICES | dos.LDF_VOLUMES)) |other| {
                        node = other;
                        if (other.task != entry.task) continue;
                        if (other.type == entry.type) continue;
                        if (entry.type == .device) volume = other.* else device = other.*;
                        break;
                    }
                    found = true;
                }
            }
        }
        dl.UnLockDosList(both);
    }

    if (!found) {
        _ = dl.PrintFault(dos.ERROR_DEVICE_NOT_MOUNTED, asked);
        return dos.RETURN_FAIL;
    }
    _ = dl.PutStr(MSG_DEV_HEADER);
    printOne(run, info, &device, false);
    _ = dl.PutStr(MSG_VOL_HEADER);
    printOne(run, info, &volume, true);
    return dos.RETURN_OK;
}

/// ACTION_DISK_INFO to a handler. False when it does not know the packet
/// (NIL:, PIPE:) or has nothing to say.
fn diskInfo(dl: *DosBase, port: *exec.MsgPort, info: *dos.InfoData) bool {
    info.* = .{};
    const action = @intFromEnum(dos.ActionCode.disk_info);
    return dl.DoPkt(port, action, @bitCast(@intFromPtr(info)), 0, 0, 0, 0) != dos.DOSFALSE;
}

/// A node and its InfoData onto the list, to be printed once the DosList
/// lock is gone. False when there was no memory, which stops the walk.
fn keep(run: *Run, entry: *dos.DosList, info: *const dos.InfoData) bool {
    const raw = run.sys.AllocVec(@sizeOf(Keeper), exec.MEMF_CLEAR) orelse {
        _ = run.dl.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return false;
    };
    const it: *Keeper = @ptrCast(@alignCast(raw));
    it.node = entry.*;
    it.info = info.*;
    it.next = null;
    if (run.tail) |t| t.next = it else run.head = it;
    run.tail = it;
    return true;
}

fn printAll(run: *Run, volume: bool) void {
    while (run.head) |it| {
        printOne(run, &it.info, &it.node, volume);
        run.head = it.next;
        if (run.head == null) run.tail = null;
        run.sys.FreeVec(it);
    }
}

fn freeAll(run: *Run) void {
    while (run.head) |it| {
        run.head = it.next;
        run.sys.FreeVec(it);
    }
    run.tail = null;
}

/// One line, for a volume or for a device.
fn printOne(run: *Run, info: *const dos.InfoData, node: *const dos.DosList, volume: bool) void {
    const dl = run.dl;

    var unit: [max_name:0]u8 = @splat(0);
    copyZ(&unit, node.name);

    if (volume) {
        // A volume says only whether its handler is there.
        _ = Printf(dl, "%s %s\n", .{
            @as([*:0]const u8, @ptrCast(&unit)),
            if (node.task != null) @as([*:0]const u8, MSG_VOL_MOUNTED) else "",
        });
        return;
    }

    // The colon was cut for the lookup; a device is printed with it.
    var end: usize = 0;
    while (unit[end] != 0) end += 1;
    if (end + 1 < unit.len) {
        unit[end] = ':';
        unit[end + 1] = 0;
    }
    const unit_name: [*:0]const u8 = @ptrCast(&unit);

    if (!isFileSystem(info.disk_type)) {
        const what: [*:0]const u8 = switch (info.disk_type) {
            dos.ID_NO_DISK_PRESENT => MSG_TYPE_NONE,
            dos.ID_KICKSTART_DISK => MSG_TYPE_KICK,
            dos.ID_NOT_REALLY_DOS => MSG_TYPE_NDOS,
            else => MSG_TYPE_BAD,
        };
        _ = Printf(dl, "%-10s%s\n", .{ unit_name, what });
        return;
    }

    // The volume's own name, off the node the handler pointed at.
    var volname: [max_name:0]u8 = @splat(0);
    if (info.volume_node) |vol| copyZ(&volname, vol.name);

    const used = info.num_blocks_used;
    const free = if (info.num_blocks > used) info.num_blocks - used else 0;

    // The reserved blocks are left out of the size on purpose: they can
    // never be used, so counting them would overstate the disk.
    const bytes = info.num_blocks * info.bytes_per_block;
    var size = bytes >> 10;
    var mult: [*:0]const u8 = MSG_KILOBYTES;
    if (size > 9999) {
        size = bytes >> 20;
        mult = MSG_MEGABYTES;
    }

    // Percent full, one more when the remainder is at least half a block.
    const percent: u64 = if (info.num_blocks == 0)
        0
    else
        (used * 100 + info.num_blocks / 2) / info.num_blocks;

    const status: [*:0]const u8 = switch (info.disk_state) {
        dos.ID_WRITE_PROTECTED => MSG_PROT_READ_ONLY,
        dos.ID_VALIDATING => MSG_PROT_VALIDATING,
        else => MSG_PROT_READ_WRITE,
    };

    _ = Printf(dl, "%-8s%5ld%s%8ld%8ld %3ld%% %3d  %-10s %s\n", .{
        unit_name,
        size,
        mult,
        used,
        free,
        percent,
        info.num_soft_errors,
        status,
        @as([*:0]const u8, @ptrCast(&volname)),
    });
}

/// A NUL-terminated name into a buffer, cut if it does not fit.
fn copyZ(into: anytype, text: [*:0]const u8) void {
    const limit = into.len;
    var i: usize = 0;
    while (text[i] != 0 and i < limit) : (i += 1) into[i] = text[i];
    into[i] = 0;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
