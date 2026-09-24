// SPDX-License-Identifier: MPL-2.0
//! InitResident: starts one resident. One with RTF_AUTOINIT is a library,
//! device or resource exec builds from its InitTable - MakeLibrary, the
//! tag's name, type, version and ID string, the table's init routine, and
//! then onto the list its type names. Any other has an init routine of its
//! own, which is called. Both get SysBase.

const sdk = @import("sdk");
const exec = @import("../exec.zig");
const exec_init = @import("../exec_init.zig");
const _library = @import("../library/_library.zig");

const ExecBase = exec.ExecBase;
const InitTable = sdk.exec.InitTable;
const Resident = sdk.exec.Resident;
const ResidentInitFn = sdk.exec.ResidentInitFn;

/// Starts one resident module.
///
/// SYNOPSIS:
/// ```zig
/// fn InitResident(base: *ExecBase, tag: *const Resident,
///     seg_list: ?*anyopaque) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -360.
///
/// INPUTS:
/// - `tag` - the ROM tag, from `FindResident` or found in a loaded image.
/// - `seg_list` - the module's segments, for a module that was loaded, or
///   null for one in the ROM. It is handed to the init routine and kept by
///   the library, so that expunging it can give the code back.
///
/// RESULT:
/// The library, device or resource base for an `RTF_AUTOINIT` tag; whatever
/// the init routine answered otherwise, or SysBase if it had none. Null if
/// the tag is not one, or the module refused.
///
/// BEHAVIOR:
/// **With `RTF_AUTOINIT`**: exec builds the module from the InitTable, puts
/// the tag's name, type, version and ID string into the base, runs the
/// table's init routine, and then adds it to the library, device or
/// resource list according to the tag's type. A refused init has its memory
/// freed before returning.
///
/// **Without it**: the tag's init routine is called with `seg_list` and
/// SysBase, and does whatever it likes - starting a process, for instance,
/// which is what a dos handler's tag does.
///
/// exec's own tag is refused: exec is built once, by the bootstrap, before
/// there is anything to build it with.
///
/// CONTEXT:
/// - Waits: whatever the module does.
/// - Interrupts: no. It allocates.
/// - Forbid: not taken, and not needed.
/// - Process: a Task will do, unless the module wants more.
///
/// OWNERSHIP:
/// The module owns itself from here and goes on its expunge.
///
/// NOTES:
/// This is the call that makes a module loaded from a disk no different
/// from one in the ROM: ramlib loads the file, finds the tag in it and
/// calls this, and what comes out is on the same list as everything else.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitCode`, `FindResident`, `MakeLibrary`
///
/// EXAMPLES:
/// ```zig
/// const base = sys.InitResident(tag, seg_list) orelse return;
/// ```
pub fn InitResident(base: *ExecBase, tag: *const Resident, seg_list: ?*anyopaque) ?*anyopaque {
    if (tag.match_word != sdk.exec.RTC_MATCHWORD) return null;
    if (tag == &exec_init.exec_tag) return null; // exec is made once, by the bootstrap
    const sys = base.iface();
    if (tag.flags & sdk.exec.RTF_AUTOINIT == 0) {
        const init: ResidentInitFn = @ptrCast(@alignCast(tag.init orelse return base));
        return init(seg_list, sys);
    }
    const table: *const InitTable = @ptrCast(@alignCast(tag.init orelse return null));
    const made = sys.MakeLibrary(table.vectors, table.vector_count, table.data_size, null, seg_list) orelse return null;
    made.node.name = tag.name;
    made.node.type = tag.type;
    made.version = tag.version;
    made.id_string = tag.id_string;
    const lib = if (table.init) |init| init(made, seg_list, sys) orelse {
        _library.freeLibraryMemory(base, made);
        return null;
    } else made;
    switch (tag.type) {
        .library => sys.AddLibrary(lib),
        .device => sys.AddDevice(lib),
        .resource => sys.AddResource(lib),
        else => {},
    }
    return lib;
}
