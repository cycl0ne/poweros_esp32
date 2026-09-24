// SPDX-License-Identifier: MPL-2.0
//! ResModules: the table of resident modules the boot scan made, in the
//! order they were started. It is in the image and never moves.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Resident = sdk.exec.Resident;

/// Hands back the table of resident modules.
///
/// SYNOPSIS:
/// ```zig
/// fn ResModules(base: *ExecBase) ?[*]const ?*const Resident
/// ```
///
/// SINCE: 1.0. LVO -436.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The tags in priority order, **null-terminated**, or null if the scan
/// never ran - which is the case in a host test, where exec is built
/// without a boot image.
///
/// BEHAVIOR:
/// Priority order is boot order, so reading this is reading the order the
/// machine started its modules in.
///
/// **No lock is needed**: the table is built once by the boot scan and
/// never changes afterwards. It is the one piece of exec's state that can
/// be walked freely.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The table is exec's and the tags are in the ROM
/// image.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindResident`, `InitCode`, `ExecList`
///
/// EXAMPLES:
/// ```zig
/// const table = sys.ResModules() orelse return;
/// var i: usize = 0;
/// while (table[i]) |tag| : (i += 1) { ... }
/// ```
pub fn ResModules(base: *ExecBase) ?[*]const ?*const Resident {
    return base.res_modules;
}
