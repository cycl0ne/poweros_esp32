// SPDX-License-Identifier: MPL-2.0
//! ParsePath: splits a path into its device and the rest.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;

/// Splits a path into its device and the rest.
///
/// SYNOPSIS:
/// ```zig
/// fn ParsePath(db: *DosBase, name: [*:0]const u8, parsed: *dos.ParsedPath) bool
/// ```
///
/// SINCE: 1.0. LVO -120.
///
/// INPUTS:
/// - `name` - the path.
/// - `parsed` - filled in: the kind of path, the device name, the rest.
///
/// RESULT:
/// True with `parsed` filled in; false, with IoErr
/// ERROR_INVALID_COMPONENT_NAME, when the part before the colon is longer
/// than MAX_DEVICE_NAME.
///
/// BEHAVIOR:
/// "DEV:rest" is absolute: `volume` is "DEV" and `remainder` "rest".
/// ":rest" is from the current volume's root: `path_type` is root and
/// `volume` empty. Anything without a colon is relative, `remainder` the
/// whole name. Only the first colon counts. `parsed` is cleared first, so
/// it holds the defaults when the call fails.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no; it sets IoErr.
/// - Forbid: not needed.
/// - Process: a Task will do; IoErr is then not set.
///
/// OWNERSHIP:
/// Nothing is allocated. `remainder` points into `name`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PathPart`, `GetDeviceProc`
///
/// EXAMPLES:
/// ```zig
/// var parsed: dos.ParsedPath = .{};
/// if (!dos_lib.ParsePath("SYS:s/startup", &parsed)) return dos_lib.IoErr();
/// // parsed.path_type == .absolute, volume "SYS", remainder "s/startup"
/// ```
pub fn ParsePath(db: *DosBase, name: [*:0]const u8, parsed: *dos.ParsedPath) bool {
    const dos_lib = db.iface();
    parsed.* = .{};
    const colon_at = db.utility_base.Strchr(name, ':') orelse {
        parsed.remainder = name;
        return true;
    };
    const colon = @intFromPtr(colon_at) - @intFromPtr(name);
    if (colon == 0) {
        parsed.path_type = .root;
        parsed.remainder = name + 1;
        return true;
    }
    if (colon > dos.MAX_DEVICE_NAME) {
        _ = dos_lib.SetIoErr(dos.ERROR_INVALID_COMPONENT_NAME);
        return false;
    }
    @memcpy(parsed.volume[0..colon], name[0..colon]);
    parsed.path_type = .absolute;
    parsed.remainder = name + colon + 1;
    return true;
}
