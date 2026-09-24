// SPDX-License-Identifier: MPL-2.0
//! PathPart: where the directory part of a path ends.

const DosBase = @import("../dos_base.zig").DosBase;

/// Finds where the directory part of a path ends.
///
/// SYNOPSIS:
/// ```zig
/// fn PathPart(db: *DosBase, name: [*:0]const u8) [*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -112.
///
/// INPUTS:
/// - `name` - the path.
///
/// RESULT:
/// A pointer into `name` just past the directory part: "xxx:yyy/zzz/qqq"
/// gives "/qqq", "xxx:yyy" gives "yyy", a name with neither gives itself.
/// Writing a NUL there leaves the directory.
///
/// BEHAVIOR:
/// The last '/' ends the directory, unless it follows another '/' or a
/// colon, or starts the name: such a slash is a way up and belongs to the
/// directory, so the result is past it. Without a slash the part after the
/// colon is the name.
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
/// `FilePart`, `AddPart`
///
/// EXAMPLES:
/// ```zig
/// const end = dos_lib.PathPart(path);
/// end[0] = 0; // path is now the directory it named a file in
/// ```
pub fn PathPart(db: *DosBase, name: [*:0]const u8) [*:0]const u8 {
    const utility_lib = db.utility_base;
    const last_slash = utility_lib.Strrchr(name, '/') orelse {
        const colon = utility_lib.Strchr(name, ':') orelse return name;
        return colon + 1;
    };
    const slash = @intFromPtr(last_slash) - @intFromPtr(name);
    if (slash == 0 or name[slash - 1] == '/' or name[slash - 1] == ':') return name + slash + 1;
    return name + slash;
}
