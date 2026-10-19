// SPDX-License-Identifier: MIT
//! The board's parts, as any code finds them: the system tag list the
//! board's ROM carries (the "system" resident's rt_Init), reached through
//! exec's FindResident - no library to open, so any code may call this,
//! a program's copy of the SDK or the kernel's. Nothing is kept: each
//! call walks the list.

const exec = @import("../../libs/exec/exec.zig");
const st = @import("../../libs/expansion/systemtags.zig");
const SYSTEM_RESIDENT = @import("../../libs/expansion/expansion.zig").SYSTEM_RESIDENT;
const tagitem = @import("../../libs/utility/tagitem.zig");

pub const Part = [*]const tagitem.TagItem;

fn sysBase() *exec.ExecBase {
    const cell: *const volatile *exec.ExecBase = exec.AbsExecBase;
    return cell.*;
}

/// The value of `tag` in `part`, or null.
pub fn value(part: Part, tag: tagitem.Tag) ?usize {
    var at: usize = 0;
    while (part[at].tag != tagitem.TAG_DONE) : (at += 1) {
        if (part[at].tag == tag) return part[at].data;
    }
    return null;
}

/// The board's first part of kind `kind` (PARTKIND_*) that is chip
/// `chip` (CHIP_*), or null.
pub fn find(kind: u32, chip: u32) ?Part {
    const tag = sysBase().FindResident(SYSTEM_RESIDENT) orelse return null;
    if (tag.type != .board) return null;
    const root: Part = @ptrCast(@alignCast(tag.init orelse return null));
    var at: usize = 0;
    while (root[at].tag != tagitem.TAG_DONE) : (at += 1) {
        if (root[at].tag != st.SYSTAG_Part) continue;
        const part: Part = @ptrFromInt(root[at].data);
        if (value(part, st.PART_Kind) != kind) continue;
        if (value(part, st.PART_Chip) != chip) continue;
        return part;
    }
    return null;
}
