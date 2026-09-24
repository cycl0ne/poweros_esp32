// SPDX-License-Identifier: MPL-2.0
//! FindResident: a resident module by name, from the table the boot scan
//! made. The table does not change after the scan, so this needs no
//! Forbid.

const sdk = @import("sdk");
const _resident = @import("_resident.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Resident = sdk.exec.Resident;

/// Finds a resident module by name.
///
/// SYNOPSIS:
/// ```zig
/// fn FindResident(base: *ExecBase, name: [*:0]const u8) ?*const Resident
/// ```
///
/// SINCE: 1.0. LVO -352.
///
/// INPUTS:
/// - `name` - the tag's name, matched exactly.
///
/// RESULT:
/// The tag, or null if there is none of that name.
///
/// BEHAVIOR:
/// Where two tags share a name the boot scan kept only the higher version,
/// so this answers that one and there is no second to find.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. **The list does not change after the boot scan**,
///   which is why this needs no lock at all.
/// - Forbid: not needed, for the same reason.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The tag is in the ROM image and outlives
/// everything.
///
/// NOTES:
/// This is how dos finds a handler: a device node names its handler, and
/// the first use looks the tag up here rather than loading anything.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitResident`, `InitCode`, `ResModules`
///
/// EXAMPLES:
/// ```zig
/// const tag = sys.FindResident("con-handler") orelse return;
/// ```
pub fn FindResident(base: *ExecBase, name: [*:0]const u8) ?*const Resident {
    const table = base.res_modules orelse return null;
    var index: usize = 0;
    while (table[index]) |tag| : (index += 1) {
        if (_resident.sameName(tag.name, name)) return tag;
    }
    return null;
}
