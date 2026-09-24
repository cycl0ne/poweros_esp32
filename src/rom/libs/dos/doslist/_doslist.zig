// SPDX-License-Identifier: MPL-2.0
//! The device list and what hangs off it: its entries, the handlers
//! started for them (GetDeviceProc), assigns, and the flash disk's
//! partitions mounted at boot.
//!
//! The device list: every device, volume and assign dos knows, as a
//! singly linked list of DosList nodes behind a private head node in the
//! base. The calls - LockDosList, UnLockDosList, AttemptLockDosList,
//! AddDosEntry, RemDosEntry, FindDosEntry, NextDosEntry, MakeDosEntry and
//! FreeDosEntry - share the three semaphores that guard it and the rules
//! for which names may sit side by side.
//!
//! Three semaphores, so that the list can be read while a handler is being
//! started (the entry lock) or a node is being removed (the delete lock),
//! without one long lock around everything. They are always taken in one
//! order - list, entry, delete - which is what keeps two callers from each
//! holding one the other wants. LockDosList takes no Forbid: the
//! semaphores are the whole protection. It returns the head node, a
//! private node FindDosEntry never finds, so a walk starts at a real
//! address. Names are C strings without the colon, compared without case
//! through utility.library. MakeDosEntry makes node and name in one block,
//! so one FreeVec frees both.
//!
//! GetDeviceProc and FreeDeviceProc: a name to its handler's port,
//! starting a device's handler on first use.
//!
//! A DevProc says where a name's packets go: the handler's port, a lock
//! on the directory the rest of the name is relative to (for an assign
//! or the current directory), and the node it came from. The caller
//! frees it with FreeDeviceProc, which also unlocks a lock that was
//! made for it (DVPF_UNLOCK).
//!
//! A device's handler is started under the entry lock, so two callers
//! never start two, and without the list lock, so the handler may add
//! volumes while it starts. Its code is a system segment named by
//! dol_Handler (or the node's own entry). ACTION_STARTUP carries the
//! name asked for, dol_Startup and the node. A handler that claims the
//! node (dol_Task) or answers with a port of its own serves every later
//! name; one that claims neither is started again each time, so every
//! Open of it gets a process to itself. That is what a console in a
//! window is: the name says where the window goes, and two Opens are
//! two windows.
//!
//! A name without a device goes to the current directory's handler,
//! with the directory, or with its volume's root for ":name"; without a
//! current directory to the root of pr_FileSystemTask. CONSOLE: is
//! pr_ConsoleTask, PROGDIR: pr_HomeDir (without one, PROGDIR is looked
//! up like any name). A volume that isn't in gives
//! ERROR_DEVICE_NOT_MOUNTED.
//!
//! Assigns: a plain assign gives its directory, with DVPF_ASSIGN when
//! more follow, and GetDeviceProc(name, dp) moves dp on to the next
//! one; when there is none, dp stays the caller's to free. A late
//! assign's path is locked on first use and the node becomes a plain
//! assign; a non-binding assign's path is locked each time, with
//! DVPF_UNLOCK. The path is locked from a copy with no list lock held -
//! Lock may itself need GetDeviceProc - one task at a time under the
//! bind semaphore and at most max_bind_depth assigns deep
//! (ERROR_TOO_MANY_LEVELS, which also ends an assign to itself); a late
//! node that changed meanwhile is looked up again.
//!
//! The assign calls: AssignLock, AssignLate, AssignPath, AssignAdd and RemAssignList,
//! on DosList nodes of type directory, late and nonbinding. GetDeviceProc is
//! the other half: it binds a late assign on first use, locks a non-binding
//! one's path on each use, and walks the directories of a multi-assign.
//!
//! The first three share `setAssign`: under the device list's write lock the
//! assign of that name is found or made, whatever it held is let go
//! (`clear`), and it takes its new kind with its directory or path. A null
//! lock with no path removes the assign; removing one that isn't there
//! succeeds, since the result the caller wants is already the case.
//!
//! - AssignLock keeps the lock it is given, and on failure the lock stays
//!   the caller's. The name of a device or volume is ERROR_OBJECT_EXISTS,
//!   from AddDosEntry's rules.
//! - AssignLate and AssignPath keep their own copy of the path, so the
//!   caller's string can go as soon as the call returns.
//! - AssignAdd appends a directory to a plain assign; a late or non-binding
//!   one is ERROR_OBJECT_WRONG_TYPE, since it has no directories to add to
//!   until it is used.
//! - RemAssignList finds the directory with SameLock, so a fresh lock of it
//!   is enough, and takes the first directory too: the next moves up, and
//!   the last one takes the assign with it. The caller's lock stays the
//!   caller's.
//!
//! Names are C strings of 1 to 30 characters without the colon; an empty or
//! longer one is ERROR_INVALID_COMPONENT_NAME. Every failure sets IoErr, and
//! no assign of the name is ERROR_OBJECT_NOT_FOUND.
//!
//! Mounting a disk: the device nodes come from the disk's own
//! RigidDiskBlock (`sdk/libs/dos/hardblocks.zig`).
//!
//! There is no list of devices to read - that is what a disk is for -
//! so dos's init looks at the first blocks of the medium for a
//! RigidDiskBlock, walks its chain of PartitionBlocks, and adds a
//! device node for each, named as the partition says (`pb_DriveName`)
//! and with the partition's own DosEnvec as the environment its handler
//! is started with. Nothing about the disk is written down in the
//! kernel: a second partition, or another file system on the same chip,
//! is then a matter of writing blocks.
//!
//! Which handler a partition gets comes from its `de_DosType`. The file
//! systems are in ROM, so a small table here maps a DosType to a
//! handler's name.
//!
//! Without a device, or with no sound RigidDiskBlock on it, there are
//! no nodes at all - which is what a board with no disk, or one with a
//! blank chip, wants. `s3> rdb init` writes a first one.

const std = @import("std");
const sdk = @import("sdk");
const process = @import("../process/_process.zig");
const DosBase = @import("../dos_base.zig").DosBase;
const packets = @import("../packet/_packet.zig");
const segment = @import("../program/_program.zig");
const locks = @import("../lock/_lock.zig");
const dos = sdk.dos;
const exec = sdk.exec;
const DosList = dos.DosList;
const DevProc = dos.DevProc;
const MsgPort = exec.MsgPort;
const TagItem = sdk.utility.TagItem;
const default_stack_size = 8192;
const max_bind_depth = 4;
const DosListType = dos.DosListType;
const FileLock = dos.FileLock;
const trackdisk = sdk.devices.trackdisk;
const hardblocks = dos.hardblocks;
const flashfs = dos.flashfs;
const ExecBase = sdk.interface.exec.ExecBase;
const max_partitions = 16;
const testing = std.testing;

/// The flags that select a semaphore.
const lock_flags = dos.LDF_ALL | dos.LDF_ENTRY | dos.LDF_DELETE;
/// Every flag LockDosList understands.
const known_flags = dos.LDF_READ | dos.LDF_WRITE | lock_flags;

/// The semaphores LockDosList takes, in the order they are taken, and the
/// flags that select each.
///
/// INPUTS:
/// - `db` - dos.library's base.
pub fn semaphores(db: *DosBase) [3]struct { bits: u32, sem: *exec.SignalSemaphore } {
    return .{
        .{ .bits = dos.LDF_ALL, .sem = &db.dev_lock },
        .{ .bits = dos.LDF_ENTRY, .sem = &db.entry_lock },
        .{ .bits = dos.LDF_DELETE, .sem = &db.delete_lock },
    };
}

/// Whether flags hold exactly one of LDF_READ and LDF_WRITE, and nothing
/// LockDosList doesn't know.
///
/// INPUTS:
/// - `flags` - the flags.
pub fn validFlags(flags: u32) bool {
    const rw = flags & (dos.LDF_READ | dos.LDF_WRITE);
    return (rw == dos.LDF_READ or rw == dos.LDF_WRITE) and flags & ~known_flags == 0;
}

/// Sets up the list's head node and its semaphores, and the assign
/// binding lock, for dos's init.
///
/// INPUTS:
/// - `db` - dos.library's base.
pub fn init(db: *DosBase) void {
    db.dos_list = .{ .type = .private, .name = "" };
    db.sys_base.InitSemaphore(&db.dev_lock);
    db.sys_base.InitSemaphore(&db.entry_lock);
    db.sys_base.InitSemaphore(&db.delete_lock);
    db.sys_base.InitSemaphore(&db.bind_lock);
    db.bind_depth = 0;
}

/// Whether a node is on the list; the caller holds the list.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `dlist` - the node.
pub fn contains(db: *DosBase, dlist: *const DosList) bool {
    var node = db.dos_list.next;
    while (node) |n| : (node = n.next) {
        if (n == dlist) return true;
    }
    return false;
}

/// The LDF_ type flag a node answers to; 0 for the head and other
/// private nodes.
///
/// INPUTS:
/// - `node` - the node.
pub fn typeFlag(node: *const DosList) u32 {
    return switch (node.type) {
        .device => dos.LDF_DEVICES,
        .volume => dos.LDF_VOLUMES,
        .directory, .late, .nonbinding => dos.LDF_ASSIGNS,
        else => 0,
    };
}

/// Whether a new node may not join an old one of the same name: a volume
/// may sit beside a device or an assign, and beside a volume of another
/// date; anything else is a conflict.
///
/// INPUTS:
/// - `old` - the node on the list.
/// - `new` - the node to be added.
pub fn conflicts(old: *const DosList, new: *const DosList) bool {
    if (old.type == .volume) {
        return new.type != .volume or old.misc.volume.volume_date.eql(new.misc.volume.volume_date);
    }
    return new.type != .volume;
}

/// The stack a handler is started with when its node gives none.
/// How many assigns deep a lookup binds (an assign to an assign to ...).
/// Real chains are one or two deep, and each level costs stack in the
/// caller's task.
/// Sets IoErr to `code` and answers null.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `code` - the error for IoErr.
pub fn failNull(db: *DosBase, code: i32) ?*DevProc {
    const dos_lib = db.iface();
    _ = dos_lib.SetIoErr(code);
    return null;
}

/// A DevProc with its fields set.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `port` - the handler's port.
/// - `lock` - the directory the name is relative to, or null.
/// - `flags` - DVPF_*.
/// - `node` - the node it came from, or null.
///
/// RESULT:
/// The DevProc, or null with ERROR_NO_FREE_STORE.
pub fn newDevProc(db: *DosBase, port: ?*MsgPort, lock: ?*dos.FileLock, flags: u32, node: ?*DosList) ?*DevProc {
    const block = db.sys_base.AllocVec(@sizeOf(DevProc), exec.MEMF_CLEAR) orelse return failNull(db, dos.ERROR_NO_FREE_STORE);
    const dp: *DevProc = @ptrCast(@alignCast(block));
    dp.* = .{ .port = port, .lock = lock, .flags = flags, .dev_node = node };
    return dp;
}

/// Starts a device's handler: a process from its code, and
/// ACTION_STARTUP to it with the name asked for (dp_Arg1), dol_Startup
/// (dp_Arg2) and the node (dp_Arg3).
///
/// INPUTS:
/// - `db` - the library's base.
/// - `node` - the device's node; the caller holds the entry lock.
/// - `name` - the name being looked up.
///
/// RESULT:
/// The port the device is reached on: the one the handler answered with
/// in dp_Arg4, else the node's task if the handler claimed the node,
/// else the new process's own. Null with IoErr when there is no code,
/// no process, no reply port for a plain task (ERROR_NO_FREE_STORE), or
/// the handler refused. The reply port is had before the process is made,
/// so no process is left waiting for a startup that cannot be sent.
pub fn startHandler(db: *DosBase, node: *DosList, name: [*:0]const u8) ?*MsgPort {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    const h = &node.misc.handler;
    const entry = h.entry orelse findHandler(db, h) orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_OBJECT_NOT_FOUND);
        return null;
    };
    const tags = [_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(entry) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(node.name) },
        .{ .tag = dos.NP_StackSize, .data = if (h.stack_size == 0) default_stack_size else h.stack_size },
        .{ .tag = dos.NP_Priority, .data = @bitCast(@as(isize, h.priority)) },
        .{ .tag = dos.NP_CurrentDir, .data = 0 }, // a handler holds no lock
        .{},
    };
    // The reply port first: once the process is made, the startup must go.
    const caller = process.currentProcess(sys);
    const reply_port = if (caller) |p| &p.msg_port else sys.CreateMsgPort() orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
    defer if (caller == null) sys.DeleteMsgPort(reply_port);
    // Code loaded from a file is counted while a process runs it, so the
    // last one to end can give it back.
    const from_file = h.seg_list != null;
    if (from_file) {
        sys.Forbid();
        h.users += 1;
        sys.Permit();
    }
    const proc = dos_lib.CreateNewProc(&tags) orelse {
        if (from_file) releaseHandlerCode(db, node);
        return null;
    };
    // The handler waits for its startup before it can end, so this is in
    // place long before endProcess looks at it.
    if (from_file) proc.handler_node = node;
    const answer = packets.exchangeVia(sys, caller, reply_port, &proc.msg_port, @intFromEnum(dos.ActionCode.startup), .{
        @bitCast(@intFromPtr(name)), @bitCast(h.startup), @bitCast(@intFromPtr(node)), 0, 0,
    });
    if (answer.res1 == 0) {
        _ = dos_lib.SetIoErr(answer.res2);
        return null;
    }
    // Which port the device is reached on from now on: the one the handler
    // answered with (dp_Arg4), else the node's own task if it claimed the
    // node while it started, else this process alone. dos writes nothing
    // into the node: a handler that claims neither is started again for
    // the next name asked of it, which is how one console is one window is
    // one Open.
    const other: ?*MsgPort = @ptrFromInt(@as(usize, @bitCast(answer.args[3])));
    return other orelse node.task orelse &proc.msg_port;
}

/// A device's handler code by its name (dol_Handler), whose entry the
/// node keeps from then on so it is not looked for again.
///
/// A system segment comes first: the ROM's handlers are there, under the
/// name at the end of the path, so `HANDLERS:con-handler` finds the ROM's
/// con-handler. Failing that the name is a file: it is loaded - as it is
/// written, and a bare name from `HANDLERS:` - and the handler's ROM tag
/// is looked for in it, the same tag a handler in the ROM has. The loaded
/// code stays in the node's seglist for as long as the node lasts; two
/// callers that both loaded it keep the first and unload the second.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `h` - the node's handler fields.
///
/// RESULT:
/// The entry, or null when the node names no handler, no segment or file
/// has that name, or the file holds no handler.
fn findHandler(db: *DosBase, h: *dos.DosListHandler) ?exec.TaskFn {
    const dos_lib = db.iface();
    const name = h.handler orelse return null;
    {
        _ = dos_lib.LockSegmentList(true);
        defer dos_lib.UnLockSegmentList();
        if (dos_lib.FindSegment(fileName(name), null, true)) |seg| {
            h.entry = seg.code.entry orelse return null;
            return h.entry;
        }
    }
    return loadHandler(db, h, name);
}

/// A process running a device's loaded handler code has ended. The last
/// one gives the code back and clears the node's entry, so the next use
/// of the device loads the file again: a handler that did not start, or
/// that has finished, leaves nothing of itself behind.
///
/// Called from endProcess, on the ending process, after its own code has
/// returned: nothing of what is unloaded is running any more.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `node` - the device node the process's handler served.
pub fn releaseHandlerCode(db: *DosBase, node: *DosList) void {
    const sys = db.sys_base;
    const h = &node.misc.handler;
    sys.Forbid();
    if (h.users > 0) h.users -= 1;
    const done = h.users == 0;
    const seg_list = if (done) h.seg_list else null;
    if (done and seg_list != null) {
        h.seg_list = null;
        h.entry = null;
    }
    sys.Permit();
    if (seg_list) |code| db.iface().UnLoadSeg(@ptrCast(@alignCast(code)));
}

/// Where the handlers are when a name says nothing else.
const handler_dir = "HANDLERS:";
/// The longest handler path, directory and all.
const max_handler_path = 96;

/// The part of a path after its last `:` or `/`.
fn fileName(path: [*:0]const u8) [*:0]const u8 {
    var start: usize = 0;
    var at: usize = 0;
    while (path[at] != 0) : (at += 1) {
        if (path[at] == ':' or path[at] == '/') start = at + 1;
    }
    return path + start;
}

/// A handler from the disk: the file loaded, its tag found, and the
/// seglist and entry put in the node.
fn loadHandler(db: *DosBase, h: *dos.DosListHandler, name: [*:0]const u8) ?exec.TaskFn {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    const seg_list = dos_lib.LoadSeg(name) orelse blk: {
        // A bare name is looked for where the handlers are.
        if (fileName(name) != name) return null;
        var path: [max_handler_path]u8 = undefined;
        var at: usize = 0;
        for (handler_dir) |char| {
            path[at] = char;
            at += 1;
        }
        var from: usize = 0;
        while (name[from] != 0) : (from += 1) {
            if (at + 1 >= path.len) return null;
            path[at] = name[from];
            at += 1;
        }
        path[at] = 0;
        break :blk dos_lib.LoadSeg(@ptrCast(&path)) orelse return null;
    };
    const tag = handlerTag(seg_list) orelse {
        dos_lib.UnLoadSeg(seg_list);
        _ = dos_lib.SetIoErr(dos.ERROR_OBJECT_WRONG_TYPE);
        return null;
    };
    // Someone else may have loaded it meanwhile: theirs is kept.
    sys.Forbid();
    const first = h.seg_list == null;
    if (first) {
        h.seg_list = seg_list;
        h.entry = tag.handler;
    }
    const entry = h.entry;
    sys.Permit();
    if (!first) dos_lib.UnLoadSeg(seg_list);
    return entry;
}

/// The handler's ROM tag in a loaded file: the match word and the
/// self-pointer the boot scan looks for, of a tag that says handler, over
/// every segment. A tag is laid out by the compiler on its own alignment,
/// so the scan steps by that.
fn handlerTag(seg_list: *dos.SegList) ?*const exec.ResidentHandler {
    var seg: ?*dos.SegList = seg_list;
    while (seg) |part| : (seg = part.next) {
        const bytes = part.data orelse continue;
        const step = @alignOf(exec.ResidentHandler);
        var at: usize = 0;
        while (at + @sizeOf(exec.ResidentHandler) <= part.mem_size) : (at += step) {
            const tag: *const exec.ResidentHandler = @ptrCast(@alignCast(bytes + at));
            if (tag.resident.match_word != exec.RTC_MATCHWORD) continue;
            if (tag.resident.match_tag != &tag.resident) continue;
            if (tag.resident.type != .handler) continue;
            return tag;
        }
    }
    return null;
}

/// The body of GetDeviceProc with an old DevProc: a non-binding
/// assign's lock is unlocked; for a multi-assign dp moves on to the
/// directory after its own.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `dp` - the DevProc of the last directory.
///
/// RESULT:
/// `dp`, changed, or null with ERROR_NO_MORE_ENTRIES when there is no
/// next directory; dp then stays the caller's to free.
pub fn nextDirectory(db: *DosBase, dp: *DevProc) ?*DevProc {
    const dos_lib = db.iface();
    if (dp.flags & dos.DVPF_UNLOCK != 0) {
        dos_lib.UnLock(dp.lock);
        dp.lock = null;
        dp.flags &= ~dos.DVPF_UNLOCK;
    }
    if (dp.flags & dos.DVPF_ASSIGN == 0) return failNull(db, dos.ERROR_NO_MORE_ENTRIES);
    const node = dp.dev_node orelse return failNull(db, dos.ERROR_NO_MORE_ENTRIES);
    const read = dos.LDF_ALL | dos.LDF_READ;
    _ = dos_lib.LockDosList(read);
    defer dos_lib.UnLockDosList(read);
    if (!contains(db, node) or node.type != .directory) return failNull(db, dos.ERROR_NO_MORE_ENTRIES);
    var next = node.misc.assign.list;
    if (dp.lock != node.lock) {
        while (next) |entry| {
            next = entry.next;
            if (entry.lock == dp.lock) break;
        } else return failNull(db, dos.ERROR_NO_MORE_ENTRIES);
    }
    const found = next orelse return failNull(db, dos.ERROR_NO_MORE_ENTRIES);
    dp.lock = found.lock;
    dp.port = if (found.lock) |l| l.task else locks.fileSystemTask(db);
    if (found.next == null) dp.flags &= ~dos.DVPF_ASSIGN;
    return dp;
}

/// Locks a late or non-binding assign's path, under the bind semaphore:
/// one task binds at a time, and bind_depth counts how deep its lookups
/// nest. A late node that is still the same late assign becomes a plain
/// assign to the lock; a non-binding one gives the lock with
/// DVPF_UNLOCK.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `name` - the name being looked up, to look it up again if the node
///   changed.
/// - `node` - the assign's node.
/// - `kind` - the node's type when it was found.
/// - `original` - the node's path when it was found, to tell whether it
///   changed.
/// - `copy` - the copy of the path; freed here.
///
/// RESULT:
/// The DevProc, or null with IoErr.
pub fn bindAssign(db: *DosBase, name: [*:0]const u8, node: *DosList, kind: dos.DosListType, original: ?[*:0]const u8, copy: [*:0]u8) ?*DevProc {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    defer sys.FreeVec(copy);
    sys.ObtainSemaphore(&db.bind_lock);
    defer sys.ReleaseSemaphore(&db.bind_lock);
    if (db.bind_depth >= max_bind_depth) return failNull(db, dos.ERROR_TOO_MANY_LEVELS);
    db.bind_depth += 1;
    const locked = dos_lib.Lock(copy, dos.SHARED_LOCK);
    db.bind_depth -= 1;
    const dir = locked orelse return null;
    if (kind == .nonbinding) {
        return newDevProc(db, dir.task, dir, dos.DVPF_UNLOCK, node) orelse {
            dos_lib.UnLock(dir);
            return null;
        };
    }
    const flags = dos.LDF_ALL | dos.LDF_WRITE;
    _ = dos_lib.LockDosList(flags);
    if (!contains(db, node) or node.type != .late or node.misc.assign.assign_name != original) {
        dos_lib.UnLockDosList(flags);
        dos_lib.UnLock(dir);
        return dos_lib.GetDeviceProc(name, null);
    }
    if (original) |p| sys.FreeVec(@ptrCast(@constCast(p)));
    node.misc.assign.assign_name = null;
    node.type = .directory;
    node.lock = dir;
    node.task = dir.task;
    dos_lib.UnLockDosList(flags);
    return newDevProc(db, dir.task, dir, 0, node);
}

/// The device list's lock for changing assigns: assigns only, for writing.
pub const write = dos.LDF_ASSIGNS | dos.LDF_WRITE;

/// Sets IoErr to `code` and answers false, the way every call here fails.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `code` - the error code (ERROR_*).
pub fn fail(db: *DosBase, code: i32) bool {
    const dos_lib = db.iface();
    _ = dos_lib.SetIoErr(code);
    return false;
}

/// Frees a path copied by `copyPath`, if there is one.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `text` - the copy, or null.
fn freePath(db: *DosBase, text: ?[*:0]const u8) void {
    if (text) |p| db.sys_base.FreeVec(@ptrCast(@constCast(p)));
}

/// A copy of a path for a late or non-binding assign, in a block of its
/// own. Null with ERROR_NO_FREE_STORE when there is no memory.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `text` - the path to copy.
///
/// OWNERSHIP:
/// The copy belongs to whoever gets it; `setAssign` takes it over, and
/// frees it itself when it fails.
pub fn copyPath(db: *DosBase, text: [*:0]const u8) ?[*:0]u8 {
    const dos_lib = db.iface();
    const len = db.utility_base.Strlen(text);
    const block = db.sys_base.AllocVec(len + 1, exec.MEMF_ANY) orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
    const copy: [*]u8 = @ptrCast(block);
    @memcpy(copy[0..len], text[0..len]);
    copy[len] = 0;
    return @ptrCast(copy);
}

/// Lets go of what an assign held: its lock, its further directories and
/// their locks, and a late or non-binding path. The node is left empty, of
/// the same type, still on the list.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `node` - the assign; the device list is locked for writing.
/// - `keep` - a lock not to unlock, because it is the one taking the
///   assign's place; null to unlock them all.
fn clear(db: *DosBase, node: *DosList, keep: ?*FileLock) void {
    const dos_lib = db.iface();
    freePath(db, node.misc.assign.assign_name);
    if (node.lock) |l| if (l != keep) dos_lib.UnLock(l);
    var more = node.misc.assign.list;
    while (more) |entry| {
        more = entry.next;
        if (entry.lock) |l| if (l != keep) dos_lib.UnLock(l);
        db.sys_base.FreeVec(entry);
    }
    node.lock = null;
    node.task = null;
    node.misc = .{ .assign = .{} };
}

/// The work of AssignLock, AssignLate and AssignPath: the assign `name`
/// becomes `kind`, with the directory `dir` or the path `text`, made if it
/// isn't there. With neither, the assign is removed. False with IoErr on
/// failure; `text` is then freed and `dir` stays the caller's.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `name` - the assign's name, without the colon.
/// - `kind` - directory, late or nonbinding.
/// - `dir` - the directory for a plain assign, which dos keeps on success.
/// - `text` - the path for a late or non-binding one, a `copyPath` copy
///   that dos keeps on success.
///
/// NOTES:
/// dol_Task is set to the directory's handler, since callers read it to
/// find the handler an assign is on.
pub fn setAssign(db: *DosBase, name: [*:0]const u8, kind: DosListType, dir: ?*FileLock, text: ?[*:0]u8) bool {
    const dos_lib = db.iface();
    const len = db.utility_base.Strlen(name);
    if (len == 0 or len > dos.MAX_DEVICE_NAME) {
        freePath(db, text);
        return fail(db, dos.ERROR_INVALID_COMPONENT_NAME);
    }
    const remove = dir == null and text == null;
    const start = dos_lib.LockDosList(write).?;
    defer dos_lib.UnLockDosList(write);
    const node = dos_lib.FindDosEntry(start, name, dos.LDF_ASSIGNS) orelse blk: {
        if (remove) return true;
        const made = dos_lib.MakeDosEntry(name, @intFromEnum(kind)) orelse {
            freePath(db, text);
            return false;
        };
        made.misc = .{ .assign = .{} };
        if (!dos_lib.AddDosEntry(made)) {
            dos_lib.FreeDosEntry(made);
            freePath(db, text);
            return false;
        }
        break :blk made;
    };
    clear(db, node, dir);
    if (remove) {
        _ = dos_lib.RemDosEntry(node);
        dos_lib.FreeDosEntry(node);
        return true;
    }
    node.type = kind;
    node.lock = dir;
    // Callers read dol_Task to find the handler an assign is on.
    node.task = if (dir) |d| d.task else null;
    node.misc.assign.assign_name = text;
    return true;
}

/// The disk: which device and unit it is. What is on it, and what the
/// partitions are called, comes from the disk.
pub const DISK_DEVICE = sdk.devices.trackdisk.FLASHNAME;
pub const DISK_UNIT: u32 = 0;

/// The flash file system's handler, a ROM tag (src/rom/handler/flashfs).
pub const FLASHFS_HANDLER = "flashfs-handler";
/// The card's: not in the ROM but in HANDLERS: (src/disk/handlers/fat),
/// which is where a bare name is loaded from.
pub const FAT_HANDLER = "fat-handler";

/// Which handler a partition's de_DosType asks for.
const file_systems = [_]struct { dos_type: u32, handler: [*:0]const u8 }{
    .{ .dos_type = flashfs.ID_FLASHFS_DISK, .handler = FLASHFS_HANDLER },
    .{ .dos_type = dos.ID_MSDOS_DISK, .handler = FAT_HANDLER },
};

/// A runaway partition chain stops here.
/// What a mounted partition needs to outlive dos's init: the startup
/// message its handler is given and the environment that points at. One
/// allocation per partition, never freed - the node isn't either.
const Mounted = extern struct {
    startup: dos.FileSysStartupMsg,
    environ: dos.DosEnvec,
};

/// What mounting a disk came to: how many nodes it made, and which
/// partition is the one to boot from - the bootable one with the highest
/// de_BootPri. The name belongs to its node, which is never removed.
pub const Mount = struct {
    count: u32 = 0,
    boot: ?[*:0]const u8 = null,
    boot_pri: i32 = -128,
};

/// Every partition the disk describes, as a device node on the list.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `sys_base` - exec, to open and read the disk's device.
///
/// RESULT:
/// How many nodes were made, and the partition to boot from. No disk,
/// no RigidDiskBlock, or one written for another block size gives none.
pub fn mountDisk(db: *DosBase, sys_base: *ExecBase) Mount {
    var io: exec.IOStdReq = .{ .req = .{ .message = .{ .length = @sizeOf(exec.IOStdReq) } } };
    var geo: trackdisk.DriveGeometry = .{};
    var mounted: Mount = .{};
    if (sys_base.OpenDevice(DISK_DEVICE, DISK_UNIT, &io.req, 0) != 0) return mounted;
    defer sys_base.CloseDevice(&io.req);
    io.req.command = trackdisk.TD_GETGEOMETRY;
    io.data = &geo;
    io.length = @sizeOf(trackdisk.DriveGeometry);
    if (sys_base.DoIO(&io.req) != 0) return mounted;
    if (geo.sector_size == 0 or geo.total_sectors == 0) return mounted;

    var rdb: hardblocks.RigidDiskBlock = undefined;
    if (!findRdb(sys_base, &io, &geo, &rdb)) return mounted;
    // The block numbers in these structures count the device's blocks; a
    // disk written for another block size is not ours to read.
    if (rdb.block_bytes != geo.sector_size) return mounted;

    var next = rdb.partition_list;
    var seen: u32 = 0;
    while (next != hardblocks.end_of_list and seen < max_partitions) : (seen += 1) {
        var pb: hardblocks.PartitionBlock = undefined;
        if (!readBlock(sys_base, &io, next, geo.sector_size, &pb)) break;
        if (!hardblocks.sound(&pb, hardblocks.IDNAME_PARTITION)) break;
        next = pb.next;
        if (pb.flags & hardblocks.PBFF_NOMOUNT != 0) continue;
        const node = addPartition(db, sys_base, &pb) orelse continue;
        mounted.count += 1;
        const bootable = pb.flags & hardblocks.PBFF_BOOTABLE != 0;
        if (bootable and (mounted.boot == null or pb.environment.boot_pri > mounted.boot_pri)) {
            mounted.boot = node.name;
            mounted.boot_pri = pb.environment.boot_pri;
        }
    }
    return mounted;
}

/// The RigidDiskBlock, in the first RDB_LOCATION_LIMIT blocks of the
/// medium.
///
/// INPUTS:
/// - `sys_base` - exec, for DoIO.
/// - `io` - the open disk.
/// - `geo` - its geometry.
/// - `into` - where the block goes.
///
/// RESULT:
/// True when a sound one was found.
fn findRdb(
    sys_base: *ExecBase,
    io: *exec.IOStdReq,
    geo: *const trackdisk.DriveGeometry,
    into: *hardblocks.RigidDiskBlock,
) bool {
    var block: u32 = 0;
    while (block < hardblocks.RDB_LOCATION_LIMIT and block < geo.total_sectors) : (block += 1) {
        if (!readBlock(sys_base, io, block, geo.sector_size, into)) continue;
        if (hardblocks.sound(into, hardblocks.IDNAME_RIGIDDISK)) return true;
    }
    return false;
}

/// One of the disk's blocks, as far as the structure wanted goes: they
/// all live at the start of a block.
///
/// INPUTS:
/// - `sys_base` - exec, for DoIO.
/// - `io` - the open disk.
/// - `block` - the block's number.
/// - `block_bytes` - the disk's block size.
/// - `into` - the structure to read into.
///
/// RESULT:
/// True when it was read.
fn readBlock(sys_base: *ExecBase, io: *exec.IOStdReq, block: u32, block_bytes: u32, into: anytype) bool {
    io.req.command = exec.CMD_READ;
    io.offset = @as(u64, block) * block_bytes;
    io.length = @sizeOf(@TypeOf(into.*));
    io.data = into;
    return sys_base.DoIO(&io.req) == 0;
}

/// A partition's node on the list: its name, the handler its DosType
/// asks for, and a startup message saying which device, unit and blocks
/// are its own.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `sys_base` - exec, to allocate.
/// - `pb` - the partition's block.
///
/// RESULT:
/// The node, or null for a partition without a name or a known file
/// system, for no memory, or when AddDosEntry refused it (a name
/// already there).
fn addPartition(db: *DosBase, sys_base: *ExecBase, pb: *const hardblocks.PartitionBlock) ?*dos.DosList {
    const dos_lib = db.iface();
    const name = pb.name();
    if (name.len == 0) return null;
    const handler = handlerFor(pb.environment.dos_type) orelse return null;

    const block = sys_base.AllocVec(@sizeOf(Mounted), exec.MEMF_CLEAR) orelse return null;
    const mounted: *Mounted = @ptrCast(@alignCast(block));
    mounted.environ = pb.environment;
    mounted.startup = .{
        .unit = DISK_UNIT,
        .device = DISK_DEVICE,
        .environ = &mounted.environ,
        .flags = pb.dev_flags,
    };

    // MakeDosEntry copies the name, which the partition block holds as a C
    // string of at most 31 characters.
    var zero: [pb.drive_name.len + 1:0]u8 = @splat(0);
    @memcpy(zero[0..name.len], name);
    const node = dos_lib.MakeDosEntry(&zero, dos.DLT_DEVICE) orelse {
        sys_base.FreeVec(block);
        return null;
    };
    node.misc.handler.handler = handler;
    node.misc.handler.startup = @intFromPtr(&mounted.startup);
    node.misc.handler.priority = 5;
    node.misc.handler.stack_size = 16384; // a file system does more than RAM:
    if (!dos_lib.AddDosEntry(node)) {
        dos_lib.FreeDosEntry(node);
        sys_base.FreeVec(block);
        return null;
    }
    return node;
}

/// The handler for a DosType, from file_systems.
///
/// INPUTS:
/// - `dos_type` - the partition's de_DosType.
///
/// RESULT:
/// The handler's name, or null for a file system there is none for.
fn handlerFor(dos_type: u32) ?[*:0]const u8 {
    for (file_systems) |fs| {
        if (fs.dos_type == dos_type) return fs.handler;
    }
    return null;
}

/// Below this a dol_Startup is a plain number (RAW:'s 1, a window's 0),
/// not a FileSysStartupMsg: no structure lives in the first page.
const startup_numbers: usize = 0x1000;

/// A device node's dol_Startup as a FileSysStartupMsg, or null where it is
/// none: zero, a plain number, or a value no structure could sit at.
///
/// INPUTS:
/// - `startup` - the node's `startup` field.
fn startupMsgOf(startup: usize) ?*const dos.FileSysStartupMsg {
    if (startup < startup_numbers) return null;
    if (startup % @alignOf(dos.FileSysStartupMsg) != 0) return null;
    return @ptrFromInt(startup);
}

/// Whether the device nodes two handlers answer for name one medium: the
/// same unit of the same exec device. The device list stays locked while
/// both startups are read and compared, so neither node can go under it.
/// SameDevice asks this to tell two names for one medium apart.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `first_port` - one handler's port.
/// - `second_port` - the other's.
pub fn sameMedium(db: *DosBase, first_port: ?*exec.MsgPort, second_port: ?*exec.MsgPort) bool {
    const dos_lib = db.iface();
    const first_task = first_port orelse return false;
    const second_task = second_port orelse return false;
    const list = dos_lib.LockDosList(dos.LDF_DEVICES | dos.LDF_READ) orelse return false;
    defer dos_lib.UnLockDosList(dos.LDF_DEVICES | dos.LDF_READ);
    var first: ?*const dos.FileSysStartupMsg = null;
    var second: ?*const dos.FileSysStartupMsg = null;
    var entry = dos_lib.NextDosEntry(list, dos.LDF_DEVICES);
    while (entry) |node| : (entry = dos_lib.NextDosEntry(node, dos.LDF_DEVICES)) {
        const startup = node.misc.handler.startup;
        if (first == null and node.task == first_task) first = startupMsgOf(startup);
        if (second == null and node.task == second_task) second = startupMsgOf(startup);
    }
    const one = first orelse return false;
    const other = second orelse return false;
    if (one.unit != other.unit) return false;
    const one_device = one.device orelse return false;
    const other_device = other.device orelse return false;
    return db.utility_base.Strcmp(one_device, other_device) == 0;
}

// --- tests ------------------------------------------------------------------

test "a RigidDiskBlock and a PartitionBlock are sound once they carry their checksum" {
    var rdb: hardblocks.RigidDiskBlock = .{
        .block_bytes = 4096,
        .partition_list = 1,
        .cylinders = 3840,
        .sectors = 1,
        .heads = 1,
        .rdb_blocks_hi = hardblocks.RDB_LOCATION_LIMIT - 1,
        .lo_cylinder = hardblocks.RDB_LOCATION_LIMIT,
        .hi_cylinder = 3839,
        .cyl_blocks = 1,
    };
    try testing.expect(!hardblocks.sound(&rdb, hardblocks.IDNAME_RIGIDDISK));
    rdb.checksum = hardblocks.checksumOf(&rdb);
    try testing.expect(hardblocks.sound(&rdb, hardblocks.IDNAME_RIGIDDISK));
    // Computing it again over a sound block gives the same answer.
    try testing.expectEqual(rdb.checksum, hardblocks.checksumOf(&rdb));
    // The identifier is checked too, and any change breaks the sum.
    try testing.expect(!hardblocks.sound(&rdb, hardblocks.IDNAME_PARTITION));
    rdb.cylinders += 1;
    try testing.expect(!hardblocks.sound(&rdb, hardblocks.IDNAME_RIGIDDISK));

    var part: hardblocks.PartitionBlock = .{
        .flags = hardblocks.PBFF_BOOTABLE,
        .environment = .{
            .size_block = 4096,
            .low_cyl = 16,
            .high_cyl = 3839,
            .dos_type = flashfs.ID_FLASHFS_DISK,
        },
    };
    @memcpy(part.drive_name[0..3], "DH0");
    part.checksum = hardblocks.checksumOf(&part);
    try testing.expect(hardblocks.sound(&part, hardblocks.IDNAME_PARTITION));
    try testing.expectEqualStrings("DH0", part.name());
    try testing.expectEqual(@as(u64, 3824), part.environment.blocks());
    try testing.expectEqual(@as(u64, 16 * 4096), part.environment.byteOf(0));
    try testing.expectEqual(FLASHFS_HANDLER, handlerFor(part.environment.dos_type).?);
    try testing.expectEqual(@as(?[*:0]const u8, null), handlerFor(0x444F5300)); // "DOS\0"
}

test "a block of ones is not a RigidDiskBlock" {
    var rdb: hardblocks.RigidDiskBlock = undefined;
    @memset(std.mem.asBytes(&rdb), 0xFF);
    try testing.expect(!hardblocks.sound(&rdb, hardblocks.IDNAME_RIGIDDISK));
    @memset(std.mem.asBytes(&rdb), 0);
    try testing.expect(!hardblocks.sound(&rdb, hardblocks.IDNAME_RIGIDDISK));
}
