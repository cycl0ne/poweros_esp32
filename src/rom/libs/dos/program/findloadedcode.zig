// SPDX-License-Identifier: MPL-2.0
//! FindLoadedCode: which file loaded from disk an address is the code of,
//! and how far into it - what a Guru prints after `in`, for a program
//! that looks at a task (`GetTaskSpot`). The list of loaded files is the
//! one LoadSeg adds to and UnLoadSeg takes from, under dos's code lock.

const DosBase = @import("../dos_base.zig").DosBase;
const _program = @import("_program.zig");

/// The loaded file whose code holds an address, and the offset into it.
///
/// SYNOPSIS:
/// ```zig
/// fn FindLoadedCode(db: *DosBase, address: usize, name: [*]u8, size: u32, offset: *usize) bool
/// ```
///
/// SINCE: 1.28. LVO -648.
///
/// INPUTS:
/// - `address` - an address in code: an instruction, a return address.
/// - `name` - where the file's name goes, as LoadSeg was given it, ending
///   in a NUL; cut to fit.
/// - `size` - how many bytes `name` has room for, the NUL included; 0
///   writes no name.
/// - `offset` - where the offset into the file's code goes.
///
/// RESULT:
/// True with the name and the offset written; false when no file loaded
/// from disk has its code there - the ROM's code, data, or nothing -
/// and nothing is written.
///
/// BEHAVIOR:
/// Every file LoadSeg loaded and UnLoadSeg has not let go is looked at,
/// each code segment against the address. The offset is the address in
/// the file's linked ELF, whose code is linked at 0: what
/// `llvm-symbolizer --obj=<the ELF> <offset>` turns into a line. A
/// return address is just past its call.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: never; it takes dos's code lock, a spinlock, for the
///   moment of the walk.
/// - Locks: dos's code lock; the caller holds no spinlock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The name is copied into the caller's buffer: the file may be unloaded
/// once the call returns.
///
/// NOTES:
/// exec's `GetTaskSpot` marks the ROM's addresses itself; the ROM's code
/// is named with the kernel's ELF of the same build.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// exec's `GetTaskSpot`, `LoadSeg`, `UnLoadSeg`
///
/// EXAMPLES:
/// ```zig
/// var name: [64]u8 = undefined;
/// var offset: usize = 0;
/// if (dos_lib.FindLoadedCode(spot.pc, &name, name.len, &offset)) {
///     // "in <name> at +<offset>"
/// }
/// ```
pub fn FindLoadedCode(db: *DosBase, address: usize, name: [*]u8, size: u32, offset: *usize) bool {
    const sys = db.sys_base;
    sys.AcquireLock(&db.code_lock);
    defer sys.ReleaseLock(&db.code_lock);
    const place = _program.codeAt(db, address) orelse return false;
    offset.* = place.offset;
    if (size > 0) {
        var at: u32 = 0;
        while (at + 1 < size and place.name[at] != 0) : (at += 1) name[at] = place.name[at];
        name[at] = 0;
    }
    return true;
}
