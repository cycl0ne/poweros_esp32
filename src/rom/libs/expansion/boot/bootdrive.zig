// SPDX-License-Identifier: MPL-2.0
//! BootDrive: the drive NoteBootDrive named, for dos.library to start
//! the system from.

const sdk = @import("sdk");
const ExpansionBase = @import("../expansion_base.zig").ExpansionBase;

/// Says which drive holds the system on the disk the firmware started
/// from.
///
/// SYNOPSIS:
/// ```zig
/// fn BootDrive(eb: *ExpansionBase) ?[*:0]const u8
/// ```
///
/// SINCE: 1.5. LVO -56.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The drive's name, without the colon, or null when none was noted.
///
/// BEHAVIOR:
/// dos.library's, as it chooses the system's disk: where the firmware
/// named the partition it started from (IsBootPartition with null) the
/// system is on that disk and nowhere else, so dos takes the drive
/// answered here over the boot nodes' priorities, and waits for one
/// while there is none.
///
/// CONTEXT:
/// - Waits: for the boot nodes' semaphore.
/// - Interrupts: no.
/// - Locks: takes the boot nodes' semaphore; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The name is the library's and stays where it is; a drive noted later
/// with a higher boot priority is written over it, so a caller that
/// keeps it copies it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NoteBootDrive`, `IsBootPartition`, `EnterBootNodes`
///
/// EXAMPLES:
/// ```zig
/// if (eb.BootDrive()) |name| assignSystem(name);
/// ```
pub fn BootDrive(eb: *ExpansionBase) ?[*:0]const u8 {
    const sys = eb.sys_base;
    sys.ObtainSemaphore(&eb.boot_lock);
    defer sys.ReleaseSemaphore(&eb.boot_lock);
    if (!eb.boot_drive_known) return null;
    return @ptrCast(&eb.boot_drive);
}
