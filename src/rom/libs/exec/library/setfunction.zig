// SPDX-License-Identifier: MPL-2.0
//! SetFunction: replaces one slot of a library's jump table and answers
//! what was there. Every call that goes through the table sees the new
//! function from then on, which is what makes patching, tracing and
//! replacing a function possible at all.

const sdk = @import("sdk");
const _library = @import("_library.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Library = sdk.exec.Library;

/// Replaces one entry of a library's jump table and answers the old one.
///
/// SYNOPSIS:
/// ```zig
/// fn SetFunction(base: *ExecBase, lib: *Library, offset: isize,
///     new: *const anyopaque) *const anyopaque
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `lib` - the library to patch.
/// - `offset` - the slot's LVO. Negative, and a whole number of slots, and
///   within the table: `-offset <= lib.neg_size`.
/// - `new` - the function to put there. It is called with the library's own
///   base as its first argument, exactly as the one it replaces was, so it
///   must have that signature.
///
/// RESULT:
/// The function that was in the slot. A patch keeps it and calls it to pass
/// the work on, which is how a replacement adds behaviour rather than
/// replacing it.
///
/// BEHAVIOR:
/// The table's checksum is taken again, so a patched library does not look
/// corrupted afterwards.
///
/// This is the one place an LVO arrives at run time rather than as a
/// constant, so it is the one place the range is worth checking: writing
/// outside the table would put a function pointer into somebody else's
/// memory and be found later, somewhere else. The check costs nothing,
/// because it runs when a module patches a vector and not when anything
/// calls one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here, around the write and the checksum. That stops
///   another task being switched to mid-patch; it does not stop one that is
///   already inside the old function.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The old function pointer is the caller's to keep
/// and to put back.
///
/// NOTES:
/// A task may be executing the old function while it is replaced, so a
/// patch cannot assume the old one is idle, and code that is patched out
/// cannot be freed on the strength of having been patched out.
///
/// This is the mechanism the whole tree's first rule exists for: every call
/// to a function that has an LVO goes through the jump table, so that
/// anything can be stood in front of. A module that calls its own
/// implementation directly has a private door that no patch can see.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetRamLib`, `MakeLibrary`
///
/// EXAMPLES:
/// ```zig
/// const old = sys.SetFunction(&sys.lib, exec.LVO.OpenLibrary,
///     exec.vec(myOpenLibrary));
/// ```
pub fn SetFunction(base: *ExecBase, lib: *Library, offset: isize, new: *const anyopaque) *const anyopaque {
    // The one place an LVO arrives at run time rather than as a constant,
    // so the one place it is worth checking. Writing outside the jump
    // table would put a function pointer into somebody else's memory and
    // be found later, somewhere else; a caller that got this wrong should
    // hear about it here. It costs nothing - this runs when a module
    // patches a vector, not when anything calls one.
    if (offset >= 0 or -offset > lib.neg_size) @panic("SetFunction: offset outside the jump table");
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    const slot = lib.slot(offset);
    const old = slot.*;
    slot.* = new;
    lib.flags |= sdk.exec.LIBF_CHANGED;
    _library.SumLibrary(lib);
    return old;
}
