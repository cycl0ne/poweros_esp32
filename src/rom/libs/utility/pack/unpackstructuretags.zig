// SPDX-License-Identifier: MPL-2.0
//! UnpackStructureTags: copies the fields of a structure out to where the
//! tags point, as a pack table lays them out.

const std = @import("std");
const sdk = @import("sdk");
const _pack = @import("_pack.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const Tag = sdk.utility.Tag;
const TagItem = sdk.utility.TagItem;
const PSTF_SIGNED = sdk.utility.pack.PSTF_SIGNED;
const PSTF_UNPACK = sdk.utility.pack.PSTF_UNPACK;
const PACK_ENDTABLE = sdk.utility.pack.PACK_ENDTABLE;
const PACK_NEWOFFSET = sdk.utility.pack.PACK_NEWOFFSET;

/// Copies the fields of a structure out to where the items of a tag list
/// point, as a pack table lays them out.
///
/// SYNOPSIS:
/// ```zig
/// fn UnpackStructureTags(ub: *UtilityBase, structure: ?*const anyopaque, pack_table: ?[*]const u32, tag_list: ?[*]const TagItem) u32
/// ```
///
/// SINCE: 1.0. LVO -144.
///
/// INPUTS:
/// - `structure` - the structure to read. Null does nothing.
/// - `pack_table` - the table: a base tag, then one entry per field made
///   with `packEntry` or `packBit`, then `PACK_ENDTABLE`. `PACK_NEWOFFSET`
///   followed by a new base tag switches the base. Null does nothing.
/// - `tag_list` - each item's data is the address of a `u32` that receives
///   its field. An item with a null address is passed over.
///
/// RESULT:
/// How many entries found their tag and were unpacked.
///
/// BEHAVIOR:
/// Every entry whose tag the list has, and that is not marked pack-only
/// (`PSTF_UNPACK`), writes a whole `u32`, whatever the field's size:
///
/// - **Byte, word:** zero-extended, or sign-extended for a signed field.
/// - **Long:** as it is.
/// - **Bit:** all ones when set, 0 when clear; `PKCTRL_FLIPBIT` inverts it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads only its inputs and allocates nothing.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The values are written where the caller's tags
/// point.
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
/// `PackStructureTags`
///
/// EXAMPLES:
/// ```zig
/// var width: u32 = 0;
/// const query = [_]TagItem{ .{ .tag = MY_Width, .data = @intFromPtr(&width) }, .{} };
/// _ = ub.UnpackStructureTags(&box, &table, &query);
/// ```
pub fn UnpackStructureTags(ub: *UtilityBase, structure: ?*const anyopaque, pack_table: ?[*]const u32, tag_list: ?[*]const TagItem) u32 {
    const utility = ub.iface();
    const base: [*]const u8 = @ptrCast(structure orelse return 0);
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
        if (entry & PSTF_UNPACK != 0) continue;
        const item = utility.FindTagItem(tag_base +% _pack.tagDelta(entry), tag_list) orelse continue;
        const dest = @as(?*u32, @ptrFromInt(item.data)) orelse continue;
        const field = base + _pack.offsetOf(entry);
        const signed = entry & PSTF_SIGNED != 0;
        dest.* = switch (_pack.sizeOf(entry)) {
            .bit => if ((field[0] & @as(u8, 1) << _pack.bitNumber(entry) != 0) != signed) 0xFFFF_FFFF else 0,
            .byte => if (signed) @bitCast(@as(i32, @as(i8, @bitCast(field[0])))) else field[0],
            .word => word: {
                const w = @as(*align(1) const u16, @ptrCast(field)).*;
                break :word if (signed) @bitCast(@as(i32, @as(i16, @bitCast(w)))) else w;
            },
            .long => @as(*align(1) const u32, @ptrCast(field)).*,
        };
        count += 1;
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

test "UnpackStructureTags: sign extension, bits as TRUE or FALSE, null pointers" {
    const ub = try library.setUp();
    defer kexec.deinit();
    const rec: Record = .{ .long = 0x8000_0001, .word = -2, .flags = 0x0102, .small = 0xFF };
    var small: u32 = 7;
    var word: u32 = 7;
    var long: u32 = 7;
    var bit: u32 = 7;
    var flip: u32 = 7;
    var exists: u32 = 7;
    var signed_long: u32 = 7;
    const tags = [_]TagItem{
        .{ .tag = base_tag + 1, .data = @intFromPtr(&small) },
        .{ .tag = base_tag + 2, .data = @intFromPtr(&word) },
        .{ .tag = base_tag + 3, .data = @intFromPtr(&long) }, // pack only
        .{ .tag = base_tag + 4, .data = @intFromPtr(&bit) },
        .{ .tag = base_tag + 5, .data = @intFromPtr(&flip) },
        .{ .tag = base_tag + 6, .data = @intFromPtr(&exists) },
        .{ .tag = other_tag + 1, .data = @intFromPtr(&signed_long) },
        .{},
    };
    try testing.expectEqual(@as(u32, 6), UnpackStructureTags(ub, &rec, &_pack.test_table, &tags));
    try testing.expectEqual(@as(u32, 0xFF), small);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFE), word);
    try testing.expectEqual(@as(u32, 7), long);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), bit);
    try testing.expectEqual(@as(u32, 0), flip);
    try testing.expectEqual(@as(u32, 0), exists);
    try testing.expectEqual(@as(u32, 0x8000_0001), signed_long);

    const nowhere = [_]TagItem{ .{ .tag = base_tag + 1, .data = 0 }, .{} };
    try testing.expectEqual(@as(u32, 0), UnpackStructureTags(ub, &rec, &_pack.test_table, &nowhere));
    try library.tearDown(ub);
}
