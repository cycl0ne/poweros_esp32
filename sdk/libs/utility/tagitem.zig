// SPDX-License-Identifier: MIT
//! Tag lists. A tag list is an array of TagItems ended by TAG_DONE.
//! TAG_MORE links it to the next array, TAG_IGNORE and TAG_SKIP pass over
//! items.

/// ti_Tag. The values below TAG_USER belong to the system.
pub const Tag = u32;

/// struct TagItem.
pub const TagItem = extern struct {
    /// ti_Tag
    tag: Tag = TAG_DONE,
    /// ti_Data: a value or a pointer, so it is pointer-sized.
    data: usize = 0,
};

/// A TagItem for a list that is data in the image rather than built at
/// run time - a board's system tag list in the ROM. Its `ti_Data` is a
/// value or a pointer, and a pointer written here is one the linker fills
/// in: an address cannot be made an integer before the image is linked.
/// It is laid out as TagItem is, so a list of these is read as a list of
/// TagItems with every tag call there is.
pub const FixedTagItem = extern struct {
    tag: Tag = TAG_DONE,
    data: extern union {
        value: usize,
        pointer: ?*const anyopaque,
    } = .{ .value = 0 },

    /// A tag whose data is a number.
    pub fn value(tag: Tag, data: usize) FixedTagItem {
        return .{ .tag = tag, .data = .{ .value = data } };
    }

    /// A tag whose data is a pointer: a string, another list, a table.
    pub fn pointer(tag: Tag, data: *const anyopaque) FixedTagItem {
        return .{ .tag = tag, .data = .{ .pointer = data } };
    }

    /// The end of the list.
    pub const done: FixedTagItem = .{};
};

comptime {
    if (@sizeOf(FixedTagItem) != @sizeOf(TagItem) or @offsetOf(FixedTagItem, "data") != @offsetOf(TagItem, "data"))
        @compileError("FixedTagItem must be laid out as TagItem");
}

/// The list a FixedTagItem array is, as the TagItems every tag call reads.
pub fn fixedList(list: []const FixedTagItem) [*]const TagItem {
    return @ptrCast(list.ptr);
}

/// The end of the list.
pub const TAG_DONE: Tag = 0;
pub const TAG_END: Tag = TAG_DONE;
/// Pass over this item.
pub const TAG_IGNORE: Tag = 1;
/// ti_Data points to the next array; this one ends here.
pub const TAG_MORE: Tag = 2;
/// Pass over this item and the next ti_Data items.
pub const TAG_SKIP: Tag = 3;
/// Where the tags of applications and libraries start.
pub const TAG_USER: Tag = 1 << 31;

/// FilterTagItems' logic: keep the tags in the array, or those not in it.
pub const TAGFILTER_AND: u32 = 0;
pub const TAGFILTER_NOT: u32 = 1;

/// MapTags' mapType: what happens to tags the map doesn't have.
pub const MAP_REMOVE_NOT_FOUND: u32 = 0;
pub const MAP_KEEP_NOT_FOUND: u32 = 1;
