// SPDX-License-Identifier: MPL-2.0
//! The board this image is built for. `-Dboard` picks the directory, and
//! each board's directory holds what is true of that board: `system.zig`,
//! its system tag list (a ROM tag of its own, which expansion.library
//! reads), and `romtags.zig`, the drivers its parts want in the image.
//!
//! The kernel's own code reads the same list at compile time, through
//! `fact` and `partFact`, so a fact is written once whoever reads it.
//!
//! Only the kernel reads this - `main.zig`, `src/arch/`, the debug shell.
//! A module asks expansion.library.

const build_options = @import("build_options");
const sdk = @import("sdk");
const Tag = sdk.utility.Tag;
const FixedTagItem = sdk.utility.FixedTagItem;
const st = sdk.expansion.systemtags;

pub const system = switch (build_options.board) {
    .waveshare_7b => @import("waveshare_7b/system.zig"),
    .es3c35p => @import("es3c35p/system.zig"),
    .qemu => @import("qemu/system.zig"),
};

pub const romtags = switch (build_options.board) {
    .waveshare_7b => @import("waveshare_7b/romtags.zig"),
    .es3c35p => @import("es3c35p/romtags.zig"),
    .qemu => @import("qemu/romtags.zig"),
};

/// The first item of `list` with `tag`, or null. A list's tags are plain
/// here: none of the kernel's facts are behind TAG_MORE. Run at compile
/// time only.
fn findIn(list: [*]const FixedTagItem, tag: Tag) ?FixedTagItem {
    var at: usize = 0;
    while (list[at].tag != sdk.utility.TAG_DONE) : (at += 1) {
        if (list[at].tag == tag) return list[at];
    }
    return null;
}

/// A number from the board's root list, `default` when it is absent.
pub fn fact(comptime tag: Tag, comptime default: usize) usize {
    const found = comptime findIn(&system.root, tag);
    return if (found) |item| comptime item.data.value else default;
}

/// A string from the board's root list (SYSTAG_Name).
pub fn text(comptime tag: Tag) [*:0]const u8 {
    const found = comptime findIn(&system.root, tag).?;
    return comptime @ptrCast(found.data.pointer.?);
}

/// A number from the board's first part of `kind`, `default` when the
/// board has no such part or the part no such tag.
pub fn partFact(comptime kind: u32, comptime tag: Tag, comptime default: usize) usize {
    return comptime partFactOf(kind, tag, default);
}

fn partFactOf(kind: u32, tag: Tag, default: usize) usize {
    var at: usize = 0;
    while (system.root[at].tag != sdk.utility.TAG_DONE) : (at += 1) {
        if (system.root[at].tag != st.SYSTAG_Part) continue;
        const part: [*]const FixedTagItem = @ptrCast(@alignCast(system.root[at].data.pointer.?));
        const kind_item = findIn(part, st.PART_Kind) orelse continue;
        if (kind_item.data.value != kind) continue;
        return if (findIn(part, tag)) |item| item.data.value else default;
    }
    return default;
}
