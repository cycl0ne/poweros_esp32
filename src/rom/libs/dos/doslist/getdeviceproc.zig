// SPDX-License-Identifier: MPL-2.0
//! GetDeviceProc: the handler, and the directory, a name's packets go
//! to.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _doslist = @import("_doslist.zig");
const process = @import("../process/_process.zig");
const bindAssign = _doslist.bindAssign;
const copyPath = @import("_doslist.zig").copyPath;
const startHandler = _doslist.startHandler;
const newDevProc = _doslist.newDevProc;
const failNull = _doslist.failNull;
const nextDirectory = _doslist.nextDirectory;
const DevProc = dos.DevProc;

/// Finds the handler a name's packets go to, and the directory the name
/// is relative to.
///
/// SYNOPSIS:
/// ```zig
/// fn GetDeviceProc(db: *DosBase, name: [*:0]const u8, olddp: ?*DevProc) ?*DevProc
/// ```
///
/// SINCE: 1.0. LVO -96.
///
/// INPUTS:
/// - `name` - the name: "DF0:file", "NIL:", "CONSOLE:", an assign, or a
///   path without a device.
/// - `olddp` - null for a new lookup; the last answer to move on to the
///   next directory of a multi-assign.
///
/// RESULT:
/// A DevProc with the handler's port (dvp_Port), the directory's lock
/// or null (dvp_Lock), DVPF_ASSIGN when a multi-assign has more
/// directories, and the node it came from. Null with IoErr on failure:
/// ERROR_DEVICE_NOT_MOUNTED, ERROR_NO_PROCESS, ERROR_OBJECT_NOT_FOUND,
/// ERROR_TOO_MANY_LEVELS, ERROR_NO_FREE_STORE, ERROR_NO_MORE_ENTRIES
/// (with `olddp`), or what a starting handler answered.
///
/// BEHAVIOR:
/// The name is parsed with ParsePath. Without a device it goes to the
/// current directory's handler with the directory (":name": the
/// volume's root), or to pr_FileSystemTask. CONSOLE: is pr_ConsoleTask
/// and PROGDIR: pr_HomeDir. Anything else is looked up on the device
/// list: a device whose handler isn't running has it started; a volume
/// gives its handler; an assign gives its directory, a late one binding
/// it first, a non-binding one locking it anew with DVPF_UNLOCK. With
/// `olddp` the next directory of the assign is given in `olddp` itself,
/// after unlocking a lock made for it.
///
/// CONTEXT:
/// - Waits: yes: for the device list's locks, and for a starting
///   handler's answer.
/// - Interrupts: not safe.
/// - Forbid: not to be held; it waits.
/// - Process: a Task will do for a name with a device; a name without
///   one, CONSOLE: and PROGDIR: need a Process.
///
/// OWNERSHIP:
/// The DevProc is the caller's, to give back with FreeDeviceProc; when
/// a call with `olddp` answers null, `olddp` is still the caller's to
/// free. The port and node stay dos's and the handler's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeDeviceProc`, `Lock`, `Open`, `AssignAdd`
///
/// EXAMPLES:
/// ```zig
/// var dp = dos_lib.GetDeviceProc("C:dir", null) orelse return dos_lib.IoErr();
/// while (true) {
///     if (tryIn(dp)) break;
///     dp = dos_lib.GetDeviceProc("C:dir", dp) orelse break;
/// }
/// dos_lib.FreeDeviceProc(dp);
/// ```
pub fn GetDeviceProc(db: *DosBase, name: [*:0]const u8, olddp: ?*DevProc) ?*DevProc {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    if (olddp) |dp| return nextDirectory(db, dp);

    var parsed: dos.ParsedPath = .{};
    if (!dos_lib.ParsePath(name, &parsed)) return null;
    if (parsed.path_type != .absolute) {
        // No device: the current directory's handler with the directory,
        // or for ":path" its volume's root; without a current directory
        // the root of the process's file system.
        const proc = process.currentProcess(sys) orelse return failNull(db, dos.ERROR_NO_PROCESS);
        if (proc.current_dir) |dir| {
            const volume_task = if (dir.volume) |v| v.task else null;
            const port = volume_task orelse dir.task orelse return failNull(db, dos.ERROR_DEVICE_NOT_MOUNTED);
            return newDevProc(db, port, if (parsed.path_type == .root) null else dir, 0, null);
        }
        const port = proc.file_system_task orelse return failNull(db, dos.ERROR_DEVICE_NOT_MOUNTED);
        return newDevProc(db, port, null, 0, null);
    }
    const device_name: [*:0]const u8 = @ptrCast(&parsed.volume);

    if (db.utility_base.Stricmp(device_name, "CONSOLE") == 0) {
        const proc = process.currentProcess(sys) orelse return failNull(db, dos.ERROR_NO_PROCESS);
        const port = proc.console_task orelse return failNull(db, dos.ERROR_DEVICE_NOT_MOUNTED);
        return newDevProc(db, port, null, 0, null);
    }
    if (db.utility_base.Stricmp(device_name, "PROGDIR") == 0) {
        if (process.currentProcess(sys)) |proc| {
            if (proc.home_dir) |home| return newDevProc(db, home.task, home, 0, null);
        }
    }

    const read = dos.LDF_ALL | dos.LDF_READ;
    const start = dos_lib.LockDosList(read).?;
    const node = dos_lib.FindDosEntry(start, device_name, dos.LDF_ALL) orelse {
        dos_lib.UnLockDosList(read);
        return failNull(db, dos.ERROR_DEVICE_NOT_MOUNTED);
    };
    switch (node.type) {
        .device => {
            if (node.task) |port| {
                dos_lib.UnLockDosList(read);
                return newDevProc(db, port, null, 0, node);
            }
            // Start its handler: under the entry lock, without the list
            // lock, so the handler may add volumes while it starts.
            const entry = dos.LDF_ENTRY | dos.LDF_WRITE;
            _ = dos_lib.LockDosList(entry);
            dos_lib.UnLockDosList(read);
            defer dos_lib.UnLockDosList(entry);
            const port = node.task orelse startHandler(db, node, name) orelse return null;
            return newDevProc(db, port, null, 0, node);
        },
        .volume => {
            const port = node.task;
            dos_lib.UnLockDosList(read);
            return newDevProc(db, port orelse return failNull(db, dos.ERROR_DEVICE_NOT_MOUNTED), null, 0, node);
        },
        .directory => {
            const port = node.task;
            const lock = node.lock;
            const flags: u32 = if (node.misc.assign.list != null) dos.DVPF_ASSIGN else 0;
            dos_lib.UnLockDosList(read);
            return newDevProc(db, port, lock, flags, node);
        },
        .late, .nonbinding => {
            // Its path is locked like any name, with no list lock held:
            // a copy, since the node may change meanwhile.
            const kind = node.type;
            const original = node.misc.assign.assign_name;
            const path = original orelse {
                dos_lib.UnLockDosList(read);
                return failNull(db, dos.ERROR_OBJECT_NOT_FOUND);
            };
            const copy = copyPath(db, path) orelse {
                dos_lib.UnLockDosList(read);
                return null;
            };
            dos_lib.UnLockDosList(read);
            return bindAssign(db, name, node, kind, original, copy);
        },
        else => {
            dos_lib.UnLockDosList(read);
            return failNull(db, dos.ERROR_NOT_IMPLEMENTED);
        },
    }
}
