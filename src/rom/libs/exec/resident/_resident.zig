// SPDX-License-Identifier: MPL-2.0
//! Resident modules (ROM tags). A Resident marks a module in the kernel
//! image: its name, version, type, priority, when to start it, and how.
//! At boot exec scans the image for them and keeps the list in
//! SysBase.res_modules; InitCode starts every resident of a start class,
//! InitResident one of them.
//!
//! A resident with RTF_AUTOINIT is a library or device that exec builds
//! from an InitTable (MakeLibrary, then AddLibrary or AddDevice); any other
//! resident has an init routine that exec calls. Both get SysBase. The
//! Resident, the InitTable and the RTF_* flags are the SDK's
//! (sdk/libs/exec/resident.zig).
//!
//! The calls are a file each in this folder; this file is everything else.
//! The boot scan that makes SysBase.res_modules and its undoing, which
//! exec's init calls; the tag lookup the bootstrap uses to find exec's own
//! tag; and the scan step, the name comparison and the table's size that
//! these and the calls share.
//!
//! `findTag` alone takes no ExecBase: it runs before there is one.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Resident = sdk.exec.Resident;

/// Bytes allocated for SysBase.res_modules, so that the table can be freed
/// with the size it was taken with. It is exec's own state rather than a
/// module's, like `SysBase` beside it.
pub var table_size: usize = 0;

/// The next ROM tag at or after `address.*` and below `end`: one with the
/// right match word whose match tag points back at it. `address.*` is moved
/// on past it - to its rt_EndSkip when that is further - or to `end` when
/// there is none.
///
/// INPUTS:
/// - `address` - where to look from; updated for the next call.
/// - `end` - the first address not to look at.
///
/// RESULT:
/// The tag, or null when the range holds no more.
pub fn nextTag(address: *usize, end: usize) ?*const Resident {
    const step = @alignOf(Resident);
    var candidate = (address.* + (step - 1)) & ~@as(usize, step - 1);
    while (candidate + @sizeOf(Resident) <= end) : (candidate += step) {
        const tag: *const Resident = @ptrFromInt(candidate);
        if (tag.match_word != sdk.exec.RTC_MATCHWORD or tag.match_tag != tag) continue;
        const skip = if (tag.end_skip) |end_skip| @intFromPtr(end_skip) else 0;
        address.* = @max(candidate + @sizeOf(Resident), skip);
        return tag;
    }
    address.* = end;
    return null;
}

/// Whether two NUL-terminated names are the same, byte for byte. It is a
/// leaf of exec's own: exec runs before utility.library exists and cannot
/// call it (codex rule 3).
///
/// INPUTS:
/// - `left`, `right` - the names to compare.
pub fn sameName(left: [*:0]const u8, right: [*:0]const u8) bool {
    var index: usize = 0;
    while (left[index] == right[index]) : (index += 1) {
        if (left[index] == 0) return true;
    }
    return false;
}

// --- the boot scan ---------------------------------------------------------

/// Scans [start, end) for ROM tags and makes SysBase.res_modules of them,
/// freeing any table an earlier scan made.
///
/// INPUTS:
/// - `base` - exec: where the table goes, and the jump table `AllocMem`
///   goes through.
/// - `start`, `end` - the range to scan; the kernel's `.resident` section.
///
/// RESULT:
/// `error.OutOfMemory` when the table cannot be had.
pub fn initResidents(base: *ExecBase, start: usize, end: usize) error{OutOfMemory}!void {
    deinitResidents(base);
    var found: usize = 0;
    var address = start;
    while (nextTag(&address, end)) |_| found += 1;

    const size = (found + 1) * @sizeOf(?*const Resident);
    const block = base.iface().AllocMem(size, sdk.exec.MEMF_CLEAR) orelse return error.OutOfMemory;
    const table: [*]?*const Resident = @ptrCast(@alignCast(block));
    var count: usize = 0;
    address = start;
    while (nextTag(&address, end)) |tag| {
        if (indexOf(table[0..count], tag.name)) |index| {
            if (tag.version > table[index].?.version) table[index] = tag;
            continue;
        }
        table[count] = tag;
        count += 1;
    }
    sortByPriority(table[0..count]);
    base.res_modules = table;
    table_size = size;
}

/// Where a tag of that name already is in the table, or null.
///
/// INPUTS:
/// - `tags` - the part of the table filled so far.
/// - `name` - the name to look for.
fn indexOf(tags: []const ?*const Resident, name: [*:0]const u8) ?usize {
    for (tags, 0..) |tag, index| {
        if (sameName(tag.?.name, name)) return index;
    }
    return null;
}

/// Orders the table by priority, highest first. Stable, so tags of equal
/// priority keep their order in memory; an insertion sort, because the
/// table is a few dozen entries and is sorted once.
///
/// INPUTS:
/// - `tags` - the filled part of the table, every entry set.
fn sortByPriority(tags: []?*const Resident) void {
    var index: usize = 1;
    while (index < tags.len) : (index += 1) {
        const tag = tags[index];
        var place = index;
        while (place > 0 and tags[place - 1].?.pri < tag.?.pri) : (place -= 1) {
            tags[place] = tags[place - 1];
        }
        tags[place] = tag;
    }
}

/// Frees SysBase.res_modules, if there is one.
///
/// INPUTS:
/// - `base` - exec: where the table is, and the jump table `FreeMem` goes
///   through.
pub fn deinitResidents(base: *ExecBase) void {
    const table = base.res_modules orelse return;
    base.res_modules = null;
    base.iface().FreeMem(@ptrCast(table), table_size);
}

/// The ROM tag called `name` in [start, end), or null.
///
/// INPUTS:
/// - `start`, `end` - the range to scan, the kernel's `.resident` section.
/// - `name` - the tag's name, matched exactly.
pub fn findTag(start: usize, end: usize, name: [*:0]const u8) ?*const Resident {
    var address = start;
    while (nextTag(&address, end)) |tag| {
        if (sameName(tag.name, name)) return tag;
    }
    return null;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "sameName: exact, case included, prefixes differ" {
    try testing.expect(sameName("exec.library", "exec.library"));
    try testing.expect(!sameName("exec.library", "Exec.library"));
    try testing.expect(!sameName("exec", "exec.library"));
    try testing.expect(!sameName("exec.library", "exec"));
    try testing.expect(sameName("", ""));
}

test "findTag finds a tag by name in a range, and skips what is not one" {
    var tags: [3]Resident = undefined;
    for (&tags, [_][*:0]const u8{ "first", "second", "third" }) |*tag, name| {
        tag.* = .{ .match_tag = tag, .name = name };
    }
    tags[1].match_word = 0; // not a tag: the match word is wrong
    const start = @intFromPtr(&tags);
    const end = start + @sizeOf(@TypeOf(tags));
    try testing.expectEqual(&tags[0], findTag(start, end, "first").?);
    try testing.expectEqual(&tags[2], findTag(start, end, "third").?);
    try testing.expect(findTag(start, end, "second") == null);
    try testing.expect(findTag(start, end, "thir") == null);
    try testing.expect(findTag(start, start + @sizeOf(Resident), "third") == null);
}

test "sortByPriority: highest first, equal priorities keep their order" {
    var tags: [4]Resident = undefined;
    for (&tags, [_]i8{ 0, 10, 0, -5 }) |*tag, pri| tag.* = .{ .match_tag = tag, .name = "tag", .pri = pri };
    var table = [_]?*const Resident{ &tags[0], &tags[1], &tags[2], &tags[3] };
    sortByPriority(&table);
    try testing.expectEqual(@as(?*const Resident, &tags[1]), table[0]);
    try testing.expectEqual(@as(?*const Resident, &tags[0]), table[1]);
    try testing.expectEqual(@as(?*const Resident, &tags[2]), table[2]);
    try testing.expectEqual(@as(?*const Resident, &tags[3]), table[3]);
}
