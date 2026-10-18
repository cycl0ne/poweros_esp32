// SPDX-License-Identifier: MIT
//! Host tests of nvme.device's parts that need no controller: CAP's
//! fields and where the doorbells are, a completion's phase and status,
//! and what the device reads of Identify's pages (regs.zig). The PRP
//! entries are prp.zig's own tests.

const std = @import("std");
const regs = @import("../regs.zig");

const testing = std.testing;

test "CAP: the queues' size, the doorbells' stride, the time to ready, the command sets and pages" {
    // 2048 entries, stride 4, 7.5 s, NVM, pages of 4 to 64 KiB.
    const cap: u64 = 0x0040_0020_0F01_07FF;
    try testing.expectEqual(@as(u32, 2048), regs.maxEntries(cap));
    try testing.expectEqual(@as(u32, 4), regs.doorbellStride(cap));
    try testing.expectEqual(@as(u32, 7500), regs.readyMs(cap));
    try testing.expect(regs.speaksNvm(cap));
    try testing.expectEqual(@as(u4, 0), regs.minPageShift(cap));
    // A stride of 16 bytes: queue 1's doorbells.
    const wide = cap | (2 << 32);
    try testing.expectEqual(@as(u32, 16), regs.doorbellStride(wide));
    try testing.expectEqual(@as(usize, 0x1000), regs.tailDoorbell(0, 4));
    try testing.expectEqual(@as(usize, 0x1004), regs.headDoorbell(0, 4));
    try testing.expectEqual(@as(usize, 0x1020), regs.tailDoorbell(1, 16));
    try testing.expectEqual(@as(usize, 0x1030), regs.headDoorbell(1, 16));
}

test "a completion: its phase in the status's lowest bit, the status above it" {
    const ok = regs.Completion{ .result = 0, .reserved = 0, .sq_head = 3, .sq_id = 1, .id = 5, .status = 1 };
    try testing.expectEqual(@as(u1, 1), ok.phase());
    try testing.expectEqual(@as(u15, 0), ok.code());
    // LBA out of range, generic, phase 0.
    const range = regs.Completion{ .result = 0, .reserved = 0, .sq_head = 0, .sq_id = 1, .id = 0, .status = 0x80 << 1 };
    try testing.expectEqual(@as(u1, 0), range.phase());
    try testing.expectEqual(regs.SC_LBA_RANGE, regs.statusCode(range.code()));
    try testing.expectEqual(regs.SCT_GENERIC, regs.statusType(range.code()));
    // Media errors are type 2.
    const media = regs.Completion{ .result = 0, .reserved = 0, .sq_head = 0, .sq_id = 1, .id = 0, .status = (2 << 8 | 0x81) << 1 };
    try testing.expectEqual(@as(u3, 2), regs.statusType(media.code()));
}

test "Identify: the controller's names, its largest transfer, its namespaces and its cache" {
    var page: [4096]u8 = @splat(0);
    std.mem.writeInt(u16, page[0..2], 0x1344, .little);
    @memcpy(page[4..24], "2246E25A0C1D        ");
    @memcpy(page[24..64], "Micron 2550 NVMe 1024GB                 ");
    @memcpy(page[64..72], "P9CR413 ");
    page[77] = 5;
    std.mem.writeInt(u32, page[516..520], 1, .little);
    page[525] = 1;
    const info = regs.ControllerInfo.of(&page);
    try testing.expectEqual(@as(u16, 0x1344), info.vendor);
    try testing.expectEqualStrings("Micron 2550 NVMe 1024GB", regs.trimmed(&info.model));
    try testing.expectEqualStrings("P9CR413", regs.trimmed(&info.firmware));
    try testing.expectEqual(@as(u8, 5), info.mdts);
    try testing.expectEqual(@as(u32, 1), info.namespaces);
    try testing.expect(info.volatile_cache);
}

test "Identify: a namespace's blocks and the format it is in, four bits of index or six" {
    var page: [4096]u8 = @splat(0);
    std.mem.writeInt(u64, page[0..8], 1_953_525_168, .little);
    // Two formats: 512 bytes, and 4 KiB in use.
    page[25] = 1;
    page[26] = 1;
    page[128 + 2] = 9;
    page[132 + 2] = 12;
    var info = regs.NamespaceInfo.of(&page);
    try testing.expectEqual(@as(u64, 1_953_525_168), info.blocks);
    try testing.expectEqual(@as(u8, 12), info.block_shift);
    try testing.expectEqual(@as(u16, 0), info.metadata);
    // Format 17 of 20: its upper bits in FLBAS's bits 5 and 6, past the
    // extended-metadata bit.
    page[25] = 19;
    page[26] = 0x01 | 1 << 5 | 1 << 4;
    page[128 + 17 * 4 + 2] = 9;
    std.mem.writeInt(u16, page[128 + 17 * 4 ..][0..2], 8, .little);
    info = regs.NamespaceInfo.of(&page);
    try testing.expectEqual(@as(u8, 9), info.block_shift);
    try testing.expectEqual(@as(u16, 8), info.metadata);
}
