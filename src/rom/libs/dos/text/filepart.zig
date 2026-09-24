// SPDX-License-Identifier: MPL-2.0
//! FilePart: the last component of a path.

const DosBase = @import("../dos_base.zig").DosBase;

/// Finds the last component of a path.
///
/// SYNOPSIS:
/// ```zig
/// fn FilePart(db: *DosBase, name: [*:0]const u8) [*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -108.
///
/// INPUTS:
/// - `name` - the path.
///
/// RESULT:
/// A pointer into `name` where its last component starts:
/// "xxx:yyy/zzz/qqq" gives "qqq", "xxx:yyy" gives "yyy", a name without
/// a colon or a slash gives itself. A path that ends in '/' gives "".
///
/// BEHAVIOR:
/// `PathPart`, past the slash it stops at.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It only reads `name`.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The result points into `name`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PathPart`, `AddPart`
///
/// EXAMPLES:
/// ```zig
/// const leaf = dos_lib.FilePart("SYS:c/dir"); // "dir"
/// ```
pub fn FilePart(db: *DosBase, name: [*:0]const u8) [*:0]const u8 {
    const dos_lib = db.iface();
    const p = dos_lib.PathPart(name);
    return if (p[0] == '/') p + 1 else p;
}
