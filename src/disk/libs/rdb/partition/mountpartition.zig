// SPDX-License-Identifier: MIT
//! MountPartition: a partition of a handle's table put on dos's list, as
//! the device node its file system's handler is started from.
//!
//! The node is the one a MountList entry for the partition would make -
//! expansion.library's MakeDosNode with the handle's device and unit, the
//! partition's device flags and a copy of its environment - with the
//! handler its DosType asks for (`sdk.dos.filesystems`). The check that
//! nobody has the partition's blocks yet and the adding are done under
//! one lock of the list, so two mounters of one disk cannot both get in.
//!
//! **Code the table brings.** Where the table keeps a file system for the
//! DosType that wins over the ROM's handler (`storedWins`), the node gets
//! a FileSysEntry with a copy of the code, which dos loads when the
//! handler is first started. The nodes of one unit's partitions of that
//! file system share one entry: the first one made is found on the list
//! by its DosType and version. An entry is the system's, as the node is.
//!
//! **A table in a container.** Its partitions count their cylinders from
//! the container's first block, so the node's environment gets the
//! container's cylinders added: the container starts on a multiple of a
//! cylinder, as InitRDB makes it.
//!
//! `add` and `start` are MountGPTPartition's too.

const sdk = @import("sdk");
const exec = sdk.exec;
const rdb = sdk.rdb;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const RDBBase = @import("../rdb_base.zig").RDBBase;
const _handle = @import("../handle/_handle.zig");
const _partition = @import("_partition.zig");

/// The list locked for the check and the adding as one.
const list_lock = dos.LDF_DEVICES | dos.LDF_WRITE;

/// Puts a partition on dos's list as a device node, so that its file
/// system can be started.
///
/// SYNOPSIS:
/// ```zig
/// fn MountPartition(base: *RDBBase, handle: *rdb.RDBHandle, partition: *rdb.RDBPartition, name: ?*rdb.MountName, flags: u32) i32
/// ```
///
/// SINCE: 1.2. LVO -52.
///
/// INPUTS:
/// - `handle`: from OpenRDB.
/// - `partition`: one of the handle's partitions.
/// - `name`: where the name the node got goes, without the colon, or
///   null.
/// - `flags`: RDBMF_START to start the handler before the call returns;
///   0 leaves it to the drive's first use.
///
/// RESULT:
/// RDBERR_OK when the node is on the list, and `name` holds its name.
/// RDBERR_FILESYSTEM for a DosType no handler serves and the table brings
/// no code for, or whose file system cannot go on this medium or inside a
/// partition (`MSH`, `POS\1`, which want a whole medium); RDBERR_IO when
/// the table's code cannot be read; RDBERR_NAME for a partition name that is
/// empty or too long, or one taken on the list with every dot that fits;
/// RDBERR_CHANGED when the medium in the unit is not the one the table
/// was read from; RDBERR_MOUNTED when a device node on the list already
/// opens some of the partition's blocks; RDBERR_RANGE for a partition of
/// a container that does not start on a multiple of the partition's
/// cylinder, or that reaches past the cylinders 32 bits count;
/// RDBERR_NOMEM for no memory. The list is unchanged by a failure.
///
/// BEHAVIOR:
/// The node is named as the partition is. Where the list has a device or
/// an assign of that name, a dot is added and the name tried again - `DH0`,
/// `DH0.`, `DH0..` - as far as MAX_DEVICE_NAME characters, so a second
/// disk whose table names its partitions as the first's gets drives of
/// its own. The node opens the handle's device and unit with the
/// partition's device flags, its environment is a copy of the
/// partition's - with the container's cylinders added for a table in a
/// GPT's container (RDBF_CONTAINER), so it names the partition's blocks
/// on the disk - and its handler is the one its DosType asks for: the
/// flash file system's for `FLS\0`, posfs's for `POS\0`, fat-handler for
/// `MSD\0`.
///
/// Where the handle's table keeps a file system for the DosType, its
/// code is what the node runs when the ROM has no handler for the DosType
/// or an older one (`sdk.dos.filesystems.storedWins`) - HANDLERS: plays
/// no part in it. The code is copied into memory for the node, or the
/// copy a node of the same unit got for the same DosType and version is
/// shared; dos loads it when the handler is first started, and starts the
/// handler its DosType names when the code does not load. A DosType that
/// names no handler is mounted when the table brings its code.
///
/// A node of the same unit whose area shares a block with the
/// partition's is the partition's already, or a drive over the whole
/// medium, or one over cylinders the table has since given another
/// partition: in each case a second file system on those blocks would
/// wreck the first, so nothing is mounted. Devices are compared by what
/// they are called, the part of the name after its last `/` or `:`:
/// `DEVS:usb/disk.device` is `disk.device`.
///
/// With RDBMF_START the handler is started, which reads the partition and
/// puts its volume on the list. A handler that cannot be started leaves
/// the node there all the same, and the drive's first use says why.
///
/// CONTEXT:
/// - Waits: yes, for the dos list's lock, and with RDBMF_START for the
///   handler.
/// - Interrupts: no.
/// - Locks: no spinlock may be held, nor the dos list.
/// - Process: a Task will do; a Process with RDBMF_START.
///
/// OWNERSHIP:
/// The node is the list's, for the system's life, and so is the copy of
/// the table's code; the handle and the partition stay the caller's, and
/// may be closed and freed at once.
///
/// NOTES:
/// Mount what WriteRDB has put on the disk: a partition only in the
/// handle is mounted all the same, but the disk does not have it at the
/// next start. PBFF_NOMOUNT is the caller's to honour: it says a
/// partition is left alone when a whole table is mounted, and
/// MountPartition mounts what it is given.
///
/// The node names its handler by a string the library holds, so once a
/// partition is mounted the library stays in memory for the system's
/// life.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenRDB`, `FindPartition`, `WriteRDB`, `AddFileSystem`
///
/// EXAMPLES:
/// ```zig
/// var name: rdb.MountName = undefined;
/// const part = rb.FindPartition(handle, "DH1") orelse return;
/// if (rb.MountPartition(handle, part, &name, rdb.RDBMF_START) == rdb.RDBERR_OK) {
///     _ = Printf(dl, "mounted as %s:\n", .{@as([*:0]const u8, &name)});
/// }
/// ```
pub fn MountPartition(base: *RDBBase, handle: *rdb.RDBHandle, partition: *rdb.RDBPartition, name: ?*rdb.MountName, flags: u32) i32 {
    const sys = base.sys_base;
    const private = _handle.handleOf(handle);
    const dos_type = partition.block.environment.dos_type;
    // A file system known to be wrong for the medium stays off it,
    // whatever code the table brings.
    const known = dos.filesystems.of(dos_type) != null;
    if (known and !dos.filesystems.suits(dos_type, handle.geometry.erase_size, false)) return rdb.RDBERR_FILESYSTEM;
    const handler = dos.filesystems.handlerFor(dos_type);
    const stored = winner(sys, handle, dos_type);
    if (handler == null and stored == null) return rdb.RDBERR_FILESYSTEM;
    const drive = _partition.driveName(partition);
    if (!_partition.validName(drive)) return rdb.RDBERR_NAME;
    var env = partition.block.environment;
    if (!onDisk(handle, &env)) return rdb.RDBERR_RANGE;
    if (_handle.changed(private)) return rdb.RDBERR_CHANGED;

    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 1) orelse return rdb.RDBERR_NOMEM;
    defer sys.CloseLibrary(dos_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return rdb.RDBERR_NOMEM;
    defer sys.CloseLibrary(expansion_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);

    var entry: ?*dos.FileSysEntry = null;
    var made = false;
    if (stored) |file_system| {
        entry = shared(dl, private, file_system);
        if (entry == null) {
            var err: i32 = rdb.RDBERR_OK;
            entry = makeEntry(private, file_system, &err) orelse return err;
            made = true;
        }
    }
    var text: rdb.MountName = @splat(0);
    @memcpy(text[0..drive.len], drive);
    const answer = add(dl, eb, private, &env, partition.block.dev_flags, handler, entry, &text, drive.len);
    if (answer != rdb.RDBERR_OK) {
        if (made) freeEntry(sys, entry.?);
        return answer;
    }
    @atomicStore(bool, &base.mounted, true, .release);
    if (name) |into| into.* = text;
    if (flags & rdb.RDBMF_START != 0) start(dl, &text, drive.len);
    return rdb.RDBERR_OK;
}

/// An environment of the table's moved to the disk's cylinders: the
/// container's added for a table in one. False when the container does
/// not start on a multiple of the environment's cylinder, or the sum does
/// not fit.
fn onDisk(handle: *rdb.RDBHandle, env: *dos.DosEnvec) bool {
    if (handle.flags & rdb.RDBF_CONTAINER == 0) return true;
    const cylinder = @as(u64, env.surfaces) * env.blocks_per_track;
    if (cylinder == 0 or handle.container % cylinder != 0) return false;
    const offset = handle.container / cylinder;
    if (offset + env.high_cyl > 0xFFFF_FFFF) return false;
    env.low_cyl += @intCast(offset);
    env.high_cyl += @intCast(offset);
    return true;
}

/// The node made with `env` and `dev_flags` and put on the list under
/// `text`, dotted while the name is taken, with the list locked from the
/// check to the adding.
pub fn add(
    dl: *DosBase,
    eb: *ExpansionBase,
    handle: *_handle.Handle,
    env: *const dos.DosEnvec,
    dev_flags: u32,
    handler: ?[*:0]const u8,
    entry: ?*dos.FileSysEntry,
    text: *rdb.MountName,
    drive_length: usize,
) i32 {
    const device = handle.device orelse return rdb.RDBERR_NOMEM;
    const list = dl.LockDosList(list_lock) orelse return rdb.RDBERR_NOMEM;
    defer dl.UnLockDosList(list_lock);
    if (claimed(dl, list, device, handle.unit, env)) return rdb.RDBERR_MOUNTED;
    var length = drive_length;
    while (true) {
        const node = eb.MakeDosNode(text, device, handle.unit, dev_flags, env) orelse return rdb.RDBERR_NOMEM;
        node.misc.handler.handler = handler;
        node.misc.handler.file_sys = entry;
        if (dl.AddDosEntry(node)) return rdb.RDBERR_OK;
        handle.sys.FreeVec(node);
        if (length == dos.MAX_DEVICE_NAME) return rdb.RDBERR_NAME;
        text[length] = '.';
        length += 1;
    }
}

/// Whether a device node on the list opens the unit and shares a block
/// with the area.
fn claimed(dl: *DosBase, list: *dos.DosList, device: [*:0]const u8, unit: u32, env: *const dos.DosEnvec) bool {
    var entry = dl.NextDosEntry(list, dos.LDF_DEVICES);
    while (entry) |node| : (entry = dl.NextDosEntry(node, dos.LDF_DEVICES)) {
        const startup = dos.filehandler.startupOf(node.misc.handler.startup) orelse continue;
        if (!dos.filehandler.opensUnit(startup, device, unit)) continue;
        if (dos.filehandler.sharesBlocks(startup.environ, env)) return true;
    }
    return false;
}

/// The table's file system for `dos_type` when its partitions are to run
/// it: the ROM has no handler for the DosType, or an older one.
fn winner(sys: *ExecBase, handle: *rdb.RDBHandle, dos_type: u32) ?*rdb.RDBFileSystem {
    var node = handle.file_systems.first();
    while (node) |it| : (node = it.next()) {
        const file_system: *rdb.RDBFileSystem = @fieldParentPtr("node", it);
        if (file_system.header.dos_type != dos_type) continue;
        if (!dos.filesystems.storedWins(file_system.header.version, dos.filesystems.romVersion(sys, dos_type))) return null;
        return file_system;
    }
    return null;
}

/// The entry a node of the handle's unit has for the file system - the
/// same DosType and version - or null. An entry is never freed, so it
/// stays good once the list is let go of.
fn shared(dl: *DosBase, handle: *_handle.Handle, file_system: *const rdb.RDBFileSystem) ?*dos.FileSysEntry {
    const device = handle.device orelse return null;
    const flags = dos.LDF_DEVICES | dos.LDF_READ;
    const list = dl.LockDosList(flags) orelse return null;
    defer dl.UnLockDosList(flags);
    var entry = dl.NextDosEntry(list, dos.LDF_DEVICES);
    while (entry) |node| : (entry = dl.NextDosEntry(node, dos.LDF_DEVICES)) {
        const file_sys = node.misc.handler.file_sys orelse continue;
        if (file_sys.dos_type != file_system.header.dos_type or file_sys.version != file_system.header.version) continue;
        const startup = dos.filehandler.startupOf(node.misc.handler.startup) orelse continue;
        if (dos.filehandler.opensUnit(startup, device, handle.unit)) return file_sys;
    }
    return null;
}

/// An entry with the file system's code copied into memory, both the
/// system's, named after the handler the code holds; null, and why in
/// `err`, for no memory or code that cannot be read.
fn makeEntry(handle: *_handle.Handle, file_system: *rdb.RDBFileSystem, err: *i32) ?*dos.FileSysEntry {
    const sys = handle.sys;
    const size = file_system.size;
    const image_memory = sys.AllocVec(size, exec.MEMF_ANY | exec.MEMF_SYSTEM) orelse {
        err.* = rdb.RDBERR_NOMEM;
        return null;
    };
    const image: [*]u8 = @ptrCast(image_memory);
    _ = _handle.readCode(handle, file_system, image[0..size]) orelse {
        sys.FreeVec(image_memory);
        err.* = rdb.RDBERR_IO;
        return null;
    };
    const entry_memory = sys.AllocVec(@sizeOf(dos.FileSysEntry), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse {
        sys.FreeVec(image_memory);
        err.* = rdb.RDBERR_NOMEM;
        return null;
    };
    const entry: *dos.FileSysEntry = @ptrCast(@alignCast(entry_memory));
    entry.* = .{ .dos_type = file_system.header.dos_type, .version = file_system.header.version, .image = image, .image_size = size };
    if (_handle.handlerIn(image[0..size])) |tag| entry.name = tag.name;
    return entry;
}

/// An entry no node took freed, with its code.
fn freeEntry(sys: *ExecBase, entry: *dos.FileSysEntry) void {
    sys.FreeVec(entry.image);
    sys.FreeVec(entry);
}

/// The drive's handler started: asking dos for its port starts it.
pub fn start(dl: *DosBase, text: *const rdb.MountName, drive_length: usize) void {
    var length = drive_length;
    while (length < text.len and text[length] != 0) length += 1;
    var drive: [dos.MAX_DEVICE_NAME + 1:0]u8 = @splat(0);
    @memcpy(drive[0..length], text[0..length]);
    drive[length] = ':';
    const dp = dl.GetDeviceProc(&drive, null) orelse return;
    dl.FreeDeviceProc(dp);
}
