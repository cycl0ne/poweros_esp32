// SPDX-License-Identifier: MIT
//! A TRIM as Dataset Management's list of ranges: the request's blocks
//! from its first, in ranges as long as the controller takes, as many in
//! one command as it takes. What one command cannot take goes in the
//! next.

const std = @import("std");
const regs = @import("regs.zig");

/// The most ranges one command lists: its count is a byte, 0's based,
/// and the list fills a page.
pub const most_ranges = 256;

/// What the controller takes at most, with what it does not say as
/// large as the command allows.
pub const Limits = struct {
    ranges: u32 = most_ranges,
    range_blocks: u32 = std.math.maxInt(u32),
    blocks: u64 = std.math.maxInt(u64),

    pub fn of(said: regs.NvmLimits) Limits {
        var limits = Limits{};
        if (said.ranges != 0) limits.ranges = said.ranges;
        if (said.range_blocks != 0) limits.range_blocks = said.range_blocks;
        if (said.blocks != 0) limits.blocks = said.blocks;
        return limits;
    }
};

/// One command's list: its ranges, and the blocks they cover.
pub const Filled = struct {
    ranges: u32,
    blocks: u64,
};

/// `blocks` from `lba` written to `list` as ranges, as many as one command
/// takes: all of them, or the first of them. `blocks` is not 0.
pub fn fill(list: []regs.Range, lba: u64, blocks: u64, limits: Limits) Filled {
    const most = @min(limits.ranges, list.len);
    var left = @min(blocks, limits.blocks);
    var at = lba;
    var count: u32 = 0;
    while (left != 0 and count < most) : (count += 1) {
        const length: u32 = @intCast(@min(left, limits.range_blocks));
        list[count] = .{
            .blocks = std.mem.nativeToLittle(u32, length),
            .lba = std.mem.nativeToLittle(u64, at),
        };
        at += length;
        left -= length;
    }
    return .{ .ranges = count, .blocks = at - lba };
}

const testing = std.testing;

test "no limits said: a whole SSD past its first MiB in one range" {
    var list: [most_ranges]regs.Range = undefined;
    const limits = Limits.of(.{});
    const filled = fill(&list, 2048, 1_953_525_168 - 2048, limits);
    try testing.expectEqual(@as(u32, 1), filled.ranges);
    try testing.expectEqual(@as(u64, 1_953_525_168 - 2048), filled.blocks);
    try testing.expectEqual(@as(u64, 2048), list[0].lba);
    try testing.expectEqual(@as(u32, 1_953_525_168 - 2048), list[0].blocks);
    try testing.expectEqual(@as(u32, 0), list[0].attributes);
}

test "more blocks than a range holds: ranges one after the other" {
    var list: [most_ranges]regs.Range = undefined;
    const filled = fill(&list, 0, (1 << 33) + 5, .{});
    try testing.expectEqual(@as(u32, 3), filled.ranges);
    try testing.expectEqual(@as(u64, (1 << 33) + 5), filled.blocks);
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), list[0].blocks);
    try testing.expectEqual(@as(u64, std.math.maxInt(u32)), list[1].lba);
    try testing.expectEqual(@as(u64, 2 * @as(u64, std.math.maxInt(u32))), list[2].lba);
    try testing.expectEqual(@as(u32, 7), list[2].blocks);
}

test "the controller's limits: the rest left for the next command" {
    var list: [most_ranges]regs.Range = undefined;
    const limits = Limits.of(.{ .ranges = 3, .range_blocks = 1000 });
    var filled = fill(&list, 4096, 3500, limits);
    try testing.expectEqual(@as(u32, 3), filled.ranges);
    try testing.expectEqual(@as(u64, 3000), filled.blocks);
    try testing.expectEqual(@as(u64, 6096), list[2].lba);
    filled = fill(&list, 4096 + 3000, 500, limits);
    try testing.expectEqual(@as(u32, 1), filled.ranges);
    try testing.expectEqual(@as(u32, 500), list[0].blocks);
    // At most 2500 blocks a command.
    filled = fill(&list, 0, 3500, Limits.of(.{ .range_blocks = 1000, .blocks = 2500 }));
    try testing.expectEqual(@as(u32, 3), filled.ranges);
    try testing.expectEqual(@as(u64, 2500), filled.blocks);
    try testing.expectEqual(@as(u32, 500), list[2].blocks);
}
