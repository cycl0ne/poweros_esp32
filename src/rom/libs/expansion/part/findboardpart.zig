// SPDX-License-Identifier: MPL-2.0
//! FindBoardPart: a part of the board, by kind and chip.

const sdk = @import("sdk");
const st = sdk.expansion.systemtags;
const BoardPart = sdk.expansion.BoardPart;
const ExpansionBase = @import("../expansion_base.zig").ExpansionBase;

/// The next part of the board after `old` whose kind and chip match.
///
/// SYNOPSIS:
/// ```zig
/// fn FindBoardPart(eb: *ExpansionBase, old: ?*const BoardPart, kind: u32, chip: u32) ?*const BoardPart
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `old` - the part to go on from, as this call gave it; null starts at
///   the board's first part.
/// - `kind` - PARTKIND_*, or PARTKIND_ANY for every kind.
/// - `chip` - CHIP_*, or CHIP_ANY for every chip.
///
/// RESULT:
/// The part, or null when there is no further one.
///
/// BEHAVIOR:
/// The parts come in the order the board lists them, so the first I2C bus
/// found is unit 0. Passing each answer back as `old` walks every match.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: yes; nothing is locked.
/// - Forbid: not needed: the parts are made once, at the library's init,
///   and never change.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The library's, for as long as the machine runs. The caller reads it and
/// never changes it.
///
/// NOTES:
/// A part's facts are in its tags: `ub.GetTagData(PART_Address, 0,
/// part.tags)`.
///
/// BUGS:
/// An `old` that is not one of the library's parts starts at the first.
///
/// SEE ALSO:
/// `SystemTags`, sdk/libs/expansion/systemtags.zig
///
/// EXAMPLES:
/// ```zig
/// const slot = eb.FindBoardPart(null, st.PARTKIND_SDSLOT, st.CHIP_ANY) orelse return null;
/// const clock = BoardPin.of(ub.GetTagData(st.PART_PinClock, 0, slot.tags));
/// ```
pub fn FindBoardPart(eb: *ExpansionBase, old: ?*const BoardPart, kind: u32, chip: u32) ?*const BoardPart {
    const parts = eb.parts orelse return null;
    const all = parts[0..eb.part_count];
    var index: usize = 0;
    if (old) |previous| {
        for (all, 0..) |*part, at| {
            if (part == previous) {
                index = at + 1;
                break;
            }
        }
    }
    while (index < all.len) : (index += 1) {
        const part = &all[index];
        if (kind != st.PARTKIND_ANY and part.kind != kind) continue;
        if (chip != st.CHIP_ANY and part.chip != chip) continue;
        return part;
    }
    return null;
}
