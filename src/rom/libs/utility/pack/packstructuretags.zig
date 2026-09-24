// SPDX-License-Identifier: MPL-2.0
//! PackStructureTags: copies tag data into the fields of a structure, as a
//! pack table lays them out.

const std = @import("std");
const sdk = @import("sdk");
const _pack = @import("_pack.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const Tag = sdk.utility.Tag;
const TagItem = sdk.utility.TagItem;
const PSTF_SIGNED = sdk.utility.pack.PSTF_SIGNED;
const PSTF_PACK = sdk.utility.pack.PSTF_PACK;
const PSTF_EXISTS = sdk.utility.pack.PSTF_EXISTS;
const PACK_ENDTABLE = sdk.utility.pack.PACK_ENDTABLE;
const PACK_NEWOFFSET = sdk.utility.pack.PACK_NEWOFFSET;

/// Copies the data of a tag list into the fields of a structure, as a pack
/// table lays them out.
///
/// SYNOPSIS:
/// ```zig
/// fn PackStructureTags(ub: *UtilityBase, structure: ?*anyopaque, pack_table: ?[*]const u32, tag_list: ?[*]const TagItem) u32
/// ```
///
/// SINCE: 1.0. LVO -140.
///
/// INPUTS:
/// - `structure` - the structure to fill. Null does nothing.
/// - `pack_table` - the table: a base tag, then one entry per field made
///   with `packEntry` or `packBit`, then `PACK_ENDTABLE`. `PACK_NEWOFFSET`
///   followed by a new base tag switches the base. Null does nothing.
/// - `tag_list` - the values.
///
/// RESULT:
/// How many entries found their tag and were packed.
///
/// BEHAVIOR:
/// Every entry whose tag the list has, and that is not marked unpack-only
/// (`PSTF_PACK`), takes the tag's data:
///
/// - **Byte, word, long:** the data truncated to the field, in the CPU's
///   byte order.
/// - **Bit:** set when the data is not zero - always, with `PSTF_EXISTS` -
///   and cleared otherwise; `PKCTRL_FLIPBIT` inverts it.
///
/// A field whose tag the list does not have is left as it is. The tag is
/// found with `FindTagItem`, so the first item with it wins.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads only its inputs and allocates nothing.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The fields are written in the caller's structure.
///
/// NOTES:
/// An entry holds the field's offset in 13 bits and the tag's distance from
/// the base tag in 10, so a field lies within the first 8 KiB of the
/// structure and a tag within 1023 of its base. An entry of 0 ends the
/// table, so the base tag itself cannot describe an unsigned byte at offset
/// 0.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnpackStructureTags`, `PackBoolTags`
///
/// EXAMPLES:
/// ```zig
/// const table = [_]u32{
///     MY_Dummy,
///     pack.packEntry(MY_Dummy, MY_Width, @offsetOf(Box, "width"), pack.PKCTRL_ULONG),
///     pack.packBit(MY_Dummy, MY_Framed, @offsetOf(Box, "flags"), pack.PKCTRL_BIT, BOXF_FRAMED),
///     pack.PACK_ENDTABLE,
/// };
/// _ = ub.PackStructureTags(&box, &table, tags);
/// ```
pub fn PackStructureTags(ub: *UtilityBase, structure: ?*anyopaque, pack_table: ?[*]const u32, tag_list: ?[*]const TagItem) u32 {
    const utility = ub.iface();
    const base: [*]u8 = @ptrCast(structure orelse return 0);
    const table = pack_table orelse return 0;
    var tag_base: Tag = table[0];
    var count: u32 = 0;
    var i: usize = 1;
    while (table[i] != PACK_ENDTABLE) : (i += 1) {
        const entry = table[i];
        if (entry == PACK_NEWOFFSET) {
            i += 1;
            tag_base = table[i];
            continue;
        }
        if (entry & PSTF_PACK != 0) continue;
        const item = utility.FindTagItem(tag_base +% _pack.tagDelta(entry), tag_list) orelse continue;
        count += 1;
        const field = base + _pack.offsetOf(entry);
        switch (_pack.sizeOf(entry)) {
            .bit => {
                var set = entry & PSTF_EXISTS != 0 or item.data != 0;
                if (entry & PSTF_SIGNED != 0) set = !set;
                const mask = @as(u8, 1) << _pack.bitNumber(entry);
                if (set) field[0] |= mask else field[0] &= ~mask;
            },
            .byte => field[0] = @truncate(item.data),
            .word => @as(*align(1) u16, @ptrCast(field)).* = @truncate(item.data),
            .long => @as(*align(1) u32, @ptrCast(field)).* = @truncate(item.data),
        }
    }
    return count;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");
const Record = _pack.Record;
const base_tag = _pack.base_tag;
const other_tag = _pack.other_tag;

test "PackStructureTags: sizes, bits, PSTF_EXISTS, pack-only and unpack-only" {
    const ub = try library.setUp();
    defer kexec.deinit();
    var rec: Record = .{};
    const tags = [_]TagItem{
        .{ .tag = base_tag + 1, .data = 0x1FF }, // truncated to the byte
        .{ .tag = base_tag + 2, .data = @bitCast(@as(isize, -2)) },
        .{ .tag = base_tag + 3, .data = 0x1234_5678 },
        .{ .tag = base_tag + 4, .data = 1 },
        .{ .tag = base_tag + 5, .data = 0 }, // inverted: set
        .{ .tag = base_tag + 6, .data = 0 }, // exists: set anyway
        .{ .tag = other_tag + 1, .data = 0xDEAD }, // unpack only
        .{},
    };
    try testing.expectEqual(@as(u32, 6), PackStructureTags(ub, &rec, &_pack.test_table, &tags));
    try testing.expectEqual(Record{ .long = 0x1234_5678, .word = -2, .flags = 0x0106, .small = 0xFF }, rec);

    // Without the tags nothing changes, the PSTF_EXISTS bit included.
    try testing.expectEqual(@as(u32, 0), PackStructureTags(ub, &rec, &_pack.test_table, null));
    try testing.expectEqual(@as(u16, 0x0106), rec.flags);
    try library.tearDown(ub);
}
