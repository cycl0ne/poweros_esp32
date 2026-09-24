// SPDX-License-Identifier: MIT
//! Assign: a name for a directory, or a look at what is on the device list.
//! Built against the SDK only.
//!
//!   Assign NAME,TARGET/M,LIST/S,EXISTS/S,DISMOUNT/S,DEFER/S,PATH/S,ADD/S,
//!          REMOVE/S,VOLS/S,DIRS/S,DEVICES/S
//!
//!   Assign                      everything: volumes, directories, devices
//!   Assign LIBS: SYS:libs       LIBS: is that directory
//!   Assign LIBS:                the assign goes
//!   Assign LIBS: SYS:libs ADD   another directory under the same name
//!   Assign LIBS: dir REMOVE     one of them goes
//!   Assign C: SYS:c DEFER       bound when it is first used (a late assign)
//!   Assign T: RAM:t PATH        bound afresh at every use
//!   Assign LIBS: EXISTS         says what it is, and sets the return code
//!
//! DISMOUNT takes an entry off the device list without freeing it: a handler
//! may still be holding it, and the odds of a crash are worse than the leak.
//!
//! A name may be given with or without its colon.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Assign";
const VERSION_STRING = "\x00$VER: Assign 1.0 (16.9.2026)\r\n";

const template = "NAME,TARGET/M,LIST/S,EXISTS/S,DISMOUNT/S,DEFER/S,PATH/S,ADD/S,REMOVE/S,VOLS/S,DIRS/S,DEVICES/S";
const arg_name = 0;
const arg_target = 1;
const arg_list = 2;
const arg_exists = 3;
const arg_dismount = 4;
const arg_defer = 5;
const arg_path = 6;
const arg_add = 7;
const arg_remove = 8;
const arg_vols = 9;
const arg_dirs = 10;
const arg_devices = 11;

const MSG_BADDEV = "Invalid device name %s\n";
const MSG_IDUNNO = "Can't assign %s\n";
const MSG_INUSE = "Can't cancel %s\n";
const MSG_VOLUMES = "Volumes:\n";
const MSG_ASSIGNS = "\nDirectories:\n";
const MSG_DEVICES = "\nDevices:\n";
const MSG_NOTASSIGNED = "%s: not assigned\n";
const MSG_MOUNTED = " [Mounted]\n";
const MSG_CONFLICT = "Only one of ADD, SUB, PATH, or DEFER allowed\n";

const max_name = dos.MAX_DEVICE_NAME;
const max_path = 256;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [12]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const given = rdargs.string(argv[arg_name]);
    const targets = rdargs.multi(argv[arg_target]);

    // Only one of the four ways of assigning.
    var ways: u32 = 0;
    for ([_]usize{ argv[arg_defer], argv[arg_path], argv[arg_add], argv[arg_remove] }) |set| {
        if (set != 0) ways += 1;
    }
    if (ways > 1) {
        _ = dl.PutStr(MSG_CONFLICT);
        return dos.RETURN_ERROR;
    }

    if (given == null) return listAll(dl, argv[arg_vols] != 0, argv[arg_dirs] != 0, argv[arg_devices] != 0);

    var name: [max_name:0]u8 = @splat(0);
    if (!withoutColon(&name, given.?)) {
        _ = Printf(dl, MSG_BADDEV, .{given.?});
        return dos.RETURN_ERROR;
    }
    const bare: [*:0]const u8 = @ptrCast(&name);

    // DISMOUNT takes the entry off the list and does not free it.
    if (argv[arg_dismount] != 0) {
        const flags = dos.LDF_ALL | dos.LDF_WRITE;
        const list = dl.LockDosList(flags) orelse return dos.RETURN_FAIL;
        defer dl.UnLockDosList(flags);
        const node = dl.FindDosEntry(list, bare, dos.LDF_ALL) orelse {
            _ = Printf(dl, MSG_INUSE, .{bare});
            return dos.RETURN_ERROR;
        };
        if (!dl.RemDosEntry(node)) {
            _ = Printf(dl, MSG_INUSE, .{bare});
            return dos.RETURN_ERROR;
        }
        return dos.RETURN_OK;
    }

    if (argv[arg_exists] != 0 or (targets.len == 0 and argv[arg_list] != 0)) {
        return exists(dl, bare);
    }
    if (targets.len == 0) {
        // Just the name: the assign goes.
        if (!dl.AssignLock(bare, null)) {
            _ = Printf(dl, MSG_INUSE, .{bare});
            return dos.RETURN_ERROR;
        }
        return dos.RETURN_OK;
    }

    var failed = false;
    for (targets) |target| {
        const ok = if (argv[arg_defer] != 0)
            dl.AssignLate(bare, target)
        else if (argv[arg_path] != 0)
            dl.AssignPath(bare, target)
        else
            byLock(dl, bare, target, argv[arg_add] != 0, argv[arg_remove] != 0);
        if (!ok) {
            _ = Printf(dl, MSG_IDUNNO, .{target});
            failed = true;
        }
    }
    return if (failed) dos.RETURN_ERROR else dos.RETURN_OK;
}

/// The assigns that hold a lock: dos keeps the lock when it takes it, and
/// it is ours again when it does not.
fn byLock(dl: *DosBase, name: [*:0]const u8, target: [*:0]const u8, add: bool, remove: bool) bool {
    const lock = dl.Lock(target, dos.SHARED_LOCK) orelse return false;
    if (remove) {
        defer dl.UnLock(lock); // only compared against the ones on the list
        return dl.RemAssignList(name, lock);
    }
    const ok = if (add) dl.AssignAdd(name, lock) else dl.AssignLock(name, lock);
    if (!ok) dl.UnLock(lock);
    return ok;
}

/// EXISTS: what the name stands for, and a return code a script can read.
fn exists(dl: *DosBase, name: [*:0]const u8) i32 {
    const list = dl.LockDosList(dos.LDF_ALL | dos.LDF_READ) orelse return dos.RETURN_FAIL;
    defer dl.UnLockDosList(dos.LDF_ALL | dos.LDF_READ);
    const node = dl.FindDosEntry(list, name, dos.LDF_ALL) orelse {
        _ = Printf(dl, MSG_NOTASSIGNED, .{name});
        return dos.RETURN_WARN;
    };
    print(dl, node);
    return dos.RETURN_OK;
}

/// The whole device list: volumes, then the assigns, then
/// the devices. With none of VOLS, DIRS and DEVICES, all three.
fn listAll(dl: *DosBase, vols: bool, dirs: bool, devices: bool) i32 {
    const every = !vols and !dirs and !devices;
    const flags = dos.LDF_ALL | dos.LDF_READ;
    const list = dl.LockDosList(flags) orelse return dos.RETURN_FAIL;
    defer dl.UnLockDosList(flags);

    const groups = [_]struct { what: dos.DosListType, title: [:0]const u8, wanted: bool }{
        .{ .what = .volume, .title = MSG_VOLUMES, .wanted = every or vols },
        .{ .what = .directory, .title = MSG_ASSIGNS, .wanted = every or dirs },
        .{ .what = .device, .title = MSG_DEVICES, .wanted = every or devices },
    };
    for (groups) |group| {
        if (!group.wanted) continue;
        _ = dl.PutStr(group.title);
        var node = dl.NextDosEntry(list, dos.LDF_ALL);
        while (node) |entry| : (node = dl.NextDosEntry(entry, dos.LDF_ALL)) {
            // Ctrl-C gets out of a long listing, as it does everywhere
            // else. The list lock is let go on the way out.
            if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
                _ = dl.PrintFault(dos.ERROR_BREAK, null);
                dl.UnLockDosList(dos.LDF_ALL | dos.LDF_READ);
                return dos.RETURN_WARN;
            }
            // An assign of any kind counts as a directory.
            const kind: dos.DosListType = switch (entry.type) {
                .late, .nonbinding => .directory,
                else => entry.type,
            };
            if (kind != group.what) continue;
            print(dl, entry);
        }
    }
    _ = dl.Flush(dl.Output());
    return dos.RETURN_OK;
}

/// One entry: the name, then what it stands for.
fn print(dl: *DosBase, node: *dos.DosList) void {
    const name = node.name;
    switch (node.type) {
        .volume => {
            _ = Printf(dl, "%s", .{name});
            _ = dl.PutStr(MSG_MOUNTED);
        },
        .device => _ = Printf(dl, "%s\n", .{name}),
        .late => _ = Printf(dl, "%-10s <%s>\n", .{ name, node.misc.assign.assign_name orelse @as([*:0]const u8, "") }),
        .nonbinding => _ = Printf(dl, "%-10s [%s]\n", .{ name, node.misc.assign.assign_name orelse @as([*:0]const u8, "") }),
        else => {
            var path: [max_path:0]u8 = @splat(0);
            const shown: [*:0]const u8 = if (dl.NameFromLock(node.lock, @ptrCast(&path), path.len))
                @ptrCast(&path)
            else
                "?";
            _ = Printf(dl, "%-10s %s\n", .{ name, shown });
            var more = node.misc.assign.list;
            while (more) |extra| : (more = extra.next) {
                var another: [max_path:0]u8 = @splat(0);
                const also: [*:0]const u8 = if (dl.NameFromLock(extra.lock, @ptrCast(&another), another.len))
                    @ptrCast(&another)
                else
                    "?";
                _ = Printf(dl, "%-10s + %s\n", .{ "", also });
            }
        },
    }
}

/// A name with its colon taken off, and checked for length.
fn withoutColon(into: *[max_name:0]u8, given: [*:0]const u8) bool {
    var i: usize = 0;
    while (given[i] != 0) : (i += 1) {
        if (i >= into.len) return false;
        if (given[i] == ':' and given[i + 1] == 0) break;
        into[i] = given[i];
    }
    into[i] = 0;
    return i != 0;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs: the linker collects unused
/// sections, and a plain constant never reaches the file at all - which is
/// all the comptime reference that used to stand here achieved.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
