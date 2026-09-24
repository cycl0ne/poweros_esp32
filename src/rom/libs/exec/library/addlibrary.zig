// SPDX-License-Identifier: MPL-2.0
//! AddLibrary: puts a library on exec's library list by priority, where
//! `OpenLibrary` finds it by name.

const sdk = @import("sdk");
const _library = @import("_library.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Library = sdk.exec.Library;

/// Puts a library on the system library list, where `OpenLibrary` finds it.
///
/// SYNOPSIS:
/// ```zig
/// fn AddLibrary(base: *ExecBase, lib: *Library) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `lib` - a built library, from `MakeLibrary` or laid out by hand. Its
///   `node.name`, `version` and `node.pri` are read here and must already
///   be set.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The node's type becomes `.library` and it is enqueued by priority, so a
/// higher-priority library of the same name is the one `OpenLibrary`
/// finds. The jump table's checksum is taken now, since adding the library
/// is the last legitimate change before anyone can call it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid, which an interrupt must not.
/// - Forbid: taken here, around the list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The system now holds the pointer, and the library
/// must stay where it is until it expunges.
///
/// NOTES:
/// A device goes on the device list instead, with `AddDevice`; the two
/// lists are separate and a name may appear on both.
///
/// The jump table is marked changed and summed before the library goes on
/// the list, so a library that asked for a checksum has one from the first
/// moment anyone can open it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MakeLibrary`, `RemLibrary`, `CreateLibrary`, `AddDevice`
///
/// EXAMPLES:
/// ```zig
/// lib.node.name = "my.library";
/// lib.version = 1;
/// sys.AddLibrary(lib);
/// ```
pub fn AddLibrary(base: *ExecBase, lib: *Library) void {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    lib.node.type = .library;
    lib.flags |= sdk.exec.LIBF_CHANGED;
    _library.SumLibrary(lib);
    sys.Enqueue(&base.lib_list, &lib.node);
}
