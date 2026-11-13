// SPDX-License-Identifier: MPL-2.0
//! NoteBootDrive: the drive of the system on the disk the firmware
//! started from, said by the disk's driver.

const sdk = @import("sdk");
const ExpansionBase = @import("../expansion_base.zig").ExpansionBase;

/// Names the drive the system is to start from.
///
/// SYNOPSIS:
/// ```zig
/// fn NoteBootDrive(eb: *ExpansionBase, name: [*:0]const u8, boot_pri: i32) void
/// ```
///
/// SINCE: 1.5. LVO -52.
///
/// INPUTS:
/// - `name` - the drive's name, as its device node has it, without the
///   colon.
/// - `boot_pri` - the partition's boot priority (de_BootPri).
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Called by a disk's driver for each bootable partition it has given a
/// device node, on the disk that holds the partition the firmware
/// started from (IsBootPartition). The name is copied; of several, the
/// one with the highest boot priority is kept, and the first of equals.
/// dos.library asks for it with BootDrive when it chooses the system's
/// disk, and waits for it where the firmware named a partition and no
/// drive is noted yet - a disk on a bus that is found only after
/// dos.library is up.
///
/// CONTEXT:
/// - Waits: for the boot nodes' semaphore.
/// - Interrupts: no.
/// - Locks: takes the boot nodes' semaphore; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `name` stays the caller's.
///
/// NOTES:
/// A name longer than a drive's may be is not kept.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `IsBootPartition`, `BootDrive`, `AddBootNode`
///
/// EXAMPLES:
/// ```zig
/// if (boot_disk and bootable) eb.NoteBootDrive(node.name, pb.environment.boot_pri);
/// ```
pub fn NoteBootDrive(eb: *ExpansionBase, name: [*:0]const u8, boot_pri: i32) void {
    const sys = eb.sys_base;
    var length: usize = 0;
    while (name[length] != 0) length += 1;
    if (length == 0 or length >= eb.boot_drive.len) return;
    sys.ObtainSemaphore(&eb.boot_lock);
    defer sys.ReleaseSemaphore(&eb.boot_lock);
    if (eb.boot_drive_known and boot_pri <= eb.boot_drive_pri) return;
    eb.boot_drive = @splat(0);
    @memcpy(eb.boot_drive[0..length], name[0..length]);
    eb.boot_drive_pri = boot_pri;
    eb.boot_drive_known = true;
}
