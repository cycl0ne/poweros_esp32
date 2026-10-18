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

const sdk = @import("sdk");
const rdb = sdk.rdb;
const dos = sdk.dos;
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
/// RDBERR_FILESYSTEM for a DosType no handler serves, or whose file
/// system cannot go on this medium or inside a partition (`MSH`, `POS\1`,
/// which want a whole medium); RDBERR_NAME for a partition name that is
/// empty or too long, or one taken on the list with every dot that fits;
/// RDBERR_CHANGED when the medium in the unit is not the one the table
/// was read from; RDBERR_MOUNTED when a device node on the list already
/// opens some of the partition's blocks; RDBERR_NOMEM for no memory. The
/// list is unchanged by a failure.
///
/// BEHAVIOR:
/// The node is named as the partition is. Where the list has a device or
/// an assign of that name, a dot is added and the name tried again - `DH0`,
/// `DH0.`, `DH0..` - as far as MAX_DEVICE_NAME characters, so a second
/// disk whose table names its partitions as the first's gets drives of
/// its own. The node opens the handle's device and unit with the
/// partition's device flags, its environment is a copy of the
/// partition's, and its handler is the one its DosType asks for: the
/// flash file system's for `FLS\0`, posfs's for `POS\0`, fat-handler for
/// `MSD\0`.
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
/// The node is the list's, for the system's life; the handle and the
/// partition stay the caller's, and may be closed and freed at once.
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
/// `OpenRDB`, `FindPartition`, `WriteRDB`
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
    if (!dos.filesystems.suits(dos_type, handle.geometry.erase_size, false)) return rdb.RDBERR_FILESYSTEM;
    const handler = dos.filesystems.handlerFor(dos_type) orelse return rdb.RDBERR_FILESYSTEM;
    const drive = _partition.driveName(partition);
    if (!_partition.validName(drive)) return rdb.RDBERR_NAME;
    if (_handle.changed(private)) return rdb.RDBERR_CHANGED;

    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 1) orelse return rdb.RDBERR_NOMEM;
    defer sys.CloseLibrary(dos_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return rdb.RDBERR_NOMEM;
    defer sys.CloseLibrary(expansion_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);

    var text: rdb.MountName = @splat(0);
    @memcpy(text[0..drive.len], drive);
    const answer = add(dl, eb, private, partition, handler, &text, drive.len);
    if (answer != rdb.RDBERR_OK) return answer;
    @atomicStore(bool, &base.mounted, true, .release);
    if (name) |into| into.* = text;
    if (flags & rdb.RDBMF_START != 0) start(dl, &text, drive.len);
    return rdb.RDBERR_OK;
}

/// The node made and put on the list under `text`, dotted while the name
/// is taken, with the list locked from the check to the adding.
fn add(
    dl: *DosBase,
    eb: *ExpansionBase,
    handle: *_handle.Handle,
    partition: *rdb.RDBPartition,
    handler: [*:0]const u8,
    text: *rdb.MountName,
    drive_length: usize,
) i32 {
    const device = handle.device orelse return rdb.RDBERR_NOMEM;
    const env = &partition.block.environment;
    const list = dl.LockDosList(list_lock) orelse return rdb.RDBERR_NOMEM;
    defer dl.UnLockDosList(list_lock);
    if (claimed(dl, list, device, handle.unit, env)) return rdb.RDBERR_MOUNTED;
    var length = drive_length;
    while (true) {
        const node = eb.MakeDosNode(text, device, handle.unit, partition.block.dev_flags, env) orelse return rdb.RDBERR_NOMEM;
        node.misc.handler.handler = handler;
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

/// The drive's handler started: asking dos for its port starts it.
fn start(dl: *DosBase, text: *const rdb.MountName, drive_length: usize) void {
    var length = drive_length;
    while (length < text.len and text[length] != 0) length += 1;
    var drive: [dos.MAX_DEVICE_NAME + 1:0]u8 = @splat(0);
    @memcpy(drive[0..length], text[0..length]);
    drive[length] = ':';
    const dp = dl.GetDeviceProc(&drive, null) orelse return;
    dl.FreeDeviceProc(dp);
}
