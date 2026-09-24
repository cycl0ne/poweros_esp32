// SPDX-License-Identifier: MPL-2.0
//! CloseLibrary: hands an opener back to the library's own Close, which
//! counts it and, at the last close, finishes an expunge that was asked
//! for while it was open.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Library = sdk.exec.Library;

/// Closes a library opened with `OpenLibrary`, through its Close vector.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseLibrary(base: *ExecBase, library: ?*Library) void
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `lib` - what `OpenLibrary` answered, or null, which does nothing. The
///   null case is so that a cleanup path need not test what it is closing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The standard Close (`libClose`) drops `open_cnt` and, when that reaches
/// zero and `LIBF_DELEXP` is set, expunges the library there and then - so
/// a library marked for expunging while it was open goes on its last close.
///
/// A non-null result from the Close vector is the seglist of a library that
/// expunged, and exec drops it: nothing here loads a module, so nothing
/// here unloads one. Whatever has replaced this slot is what takes that up.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here, around the vector.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's open count is given up and the base must not be called
/// again. The library may be gone the moment this returns.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenLibrary`, `RemLibrary`
///
/// EXAMPLES:
/// ```zig
/// const ub = sys.OpenLibrary("utility.library", 1) orelse return;
/// defer sys.CloseLibrary(ub);
/// ```
pub fn CloseLibrary(base: *ExecBase, library: ?*Library) void {
    const lib = library orelse return;
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    // A non-null result is the seglist of an expunged disk-based library;
    // there is no loader yet, so nothing to unload.
    _ = lib.vector(sdk.exec.CloseFn, sdk.exec.LIB_CLOSE)(lib);
}
