// SPDX-License-Identifier: MPL-2.0
//! FindSegResident: the ROM tags in a loaded file.
//!
//! A file that is a module - a library, a device, a handler, a keymap -
//! says so with a ROM tag somewhere in its segments, as the modules in
//! the ROM do. The tag is found as the boot scan finds one: by its match
//! word and its pointer to itself. A tag is data the compiler laid out on
//! its own alignment, so the walk steps by that, through each segment in
//! the list's order.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const DosBase = @import("../dos_base.zig").DosBase;

/// Finds a ROM tag in the segments of a loaded file.
///
/// SYNOPSIS:
/// ```zig
/// fn FindSegResident(db: *DosBase, seg_list: ?*dos.SegList, after: ?*const exec.Resident, kind: exec.NodeType) ?*const exec.Resident
/// ```
///
/// SINCE: 1.25. LVO -644.
///
/// INPUTS:
/// - `seg_list` - the chain LoadSeg answered; null finds nothing.
/// - `after` - a tag this call answered before, to go on behind it, or
///   null for the first.
/// - `kind` - the type the tag has to have (`.library`, `.device`,
///   `.handler`, `.keymap`, ...); `.unknown` takes a tag of any type.
///
/// RESULT:
/// The tag, or null when the segments hold no further one.
///
/// BEHAVIOR:
/// The segments are walked in the chain's order and each from its start.
/// A tag is where the match word stands and the pointer after it points
/// at the word itself; bytes that only look like the word are passed by.
/// The name and the version are the caller's to judge: a file may hold a
/// module other than the one it was loaded for, and with `after` the
/// caller looks at each in turn.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: callable, the segments staying loaded.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The tag is in the segments: it is there until UnLoadSeg.
///
/// NOTES:
/// A tag whose type is `.handler` is an `exec.ResidentHandler`, one whose
/// type is `.keymap` has a `keymap.KeyMapFile` as its init.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LoadSeg`, `UnLoadSeg`, exec's `FindResident`, `InitResident`
///
/// EXAMPLES:
/// ```zig
/// const seg_list = dos_lib.LoadSeg("DEVS:Keymaps/inscript") orelse return null;
/// var tag = dos_lib.FindSegResident(seg_list, null, .keymap);
/// while (tag) |found| : (tag = dos_lib.FindSegResident(seg_list, found, .keymap)) {
///     // found.name, found.version, found.init
/// }
/// ```
pub fn FindSegResident(_: *DosBase, seg_list: ?*dos.SegList, after: ?*const exec.Resident, kind: exec.NodeType) ?*const exec.Resident {
    var passed = after == null;
    var seg = seg_list;
    while (seg) |part| : (seg = part.next) {
        const bytes = part.data orelse continue;
        const step = @alignOf(exec.Resident);
        var at: usize = 0;
        while (at + @sizeOf(exec.Resident) <= part.mem_size) : (at += step) {
            const tag: *const exec.Resident = @ptrCast(@alignCast(bytes + at));
            if (tag.match_word != exec.RTC_MATCHWORD) continue;
            if (tag.match_tag != tag) continue;
            if (!passed) {
                passed = tag == after;
                continue;
            }
            if (kind != .unknown and tag.type != kind) continue;
            return tag;
        }
    }
    return null;
}
