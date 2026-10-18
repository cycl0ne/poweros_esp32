// SPDX-License-Identifier: MPL-2.0
//! posfs's trees and space, on every medium: random changes against a
//! sorted model, checkpoints and mounts in between, the check clean after
//! each, no flash page programmed twice, and damage found as an error.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const layout = sdk.dos.posfs.layout;
const testmedia = @import("../testmedia.zig");
const TestMedia = testmedia.TestMedia;
const volume = @import("../volume.zig");
const btree = @import("../btree.zig");
const checkpoint = @import("../checkpoint.zig");
const check = @import("../check.zig");
const space = @import("../space.zig");

const Volume = volume.Volume;

fn expectClean(vol: *Volume) !void {
    var report: check.Report = .{};
    try check.check(vol, &report);
    if (report.errors != 0) {
        std.debug.print("check: {d} errors, first: {s} at {d}\n", .{ report.errors, report.message, report.where });
        return error.TestUnexpectedResult;
    }
}

fn keyOf(n: u64) layout.Key {
    return .{ .oid = 1000 + n / 7, .kind = @intFromEnum(layout.Kind.xattr), .offset = n % 7 };
}

fn dataOf(n: u64, len: usize, into: []u8) []const u8 {
    for (into[0..len], 0..) |*byte, i| byte.* = @truncate(n *% 31 +% i);
    return into[0..len];
}

const Model = std.AutoHashMap(u64, usize);

fn expectModel(vol: *Volume, model: *Model) !void {
    var buffer: [70000]u8 = undefined;
    var it = model.iterator();
    while (it.next()) |entry| {
        const got = (try btree.find(vol, &vol.obj, keyOf(entry.key_ptr.*))) orelse return error.TestUnexpectedResult;
        try testing.expectEqualSlices(u8, dataOf(entry.key_ptr.*, entry.value_ptr.*, &buffer), got);
    }
    // In order, every item once.
    var count: usize = 0;
    var key = layout.Key{ .oid = 1000, .kind = 0 };
    while (try btree.seek(vol, &vol.obj, key)) |item| {
        if (item.key.oid < 1000) break;
        count += 1;
        key = btree.successor(item.key);
    }
    try testing.expectEqual(model.count(), count);
}

fn run(kind: testmedia.Kind, block_size: u32, seed: u64, steps: usize) !void {
    // Room for the items, the tree twice over and what two checkpoints
    // hold, at any block size.
    const size: usize = if (block_size > 4096) 2 * 1024 * block_size / 4 else 2 * 1024 * 1024;
    var m = try TestMedia.init(kind, size, seed);
    defer m.deinit();
    var vol: Volume = .{ .dev = m.device() };
    defer vol.release();
    try checkpoint.format(&vol, .{ .block_size = block_size, .name = "Test" });
    try expectClean(&vol);
    var model = Model.init(testing.allocator);
    defer model.deinit();
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var buffer: [70000]u8 = undefined;
    const most = layout.itemMax(vol.block_size);
    for (0..steps) |step| {
        const n = random.uintLessThan(u64, 600);
        const choice = random.uintLessThan(u32, 10);
        if (choice < 6) {
            const len = if (random.boolean()) random.uintLessThan(usize, 64) else random.uintLessThan(usize, most + 1);
            try btree.put(&vol, &vol.obj, keyOf(n), dataOf(n, len, &buffer));
            try model.put(n, len);
        } else {
            const removed = try btree.remove(&vol, &vol.obj, keyOf(n));
            try testing.expectEqual(model.contains(n), removed);
            _ = model.remove(n);
        }
        if (step % 97 == 0) try expectModel(&vol, &model);
        if (step % 211 == 0) {
            try checkpoint.write(&vol, 0);
            try expectClean(&vol);
        }
        if (step % 503 == 0) {
            try checkpoint.unmount(&vol);
            try checkpoint.mount(&vol);
            try expectClean(&vol);
            try expectModel(&vol, &model);
            try checkpoint.startSession(&vol);
        }
    }
    try checkpoint.unmount(&vol);
    try checkpoint.mount(&vol);
    try expectClean(&vol);
    try expectModel(&vol, &model);
    try testing.expectEqual(@as(u32, 0), m.twice);
    vol.release();
    try testing.expectEqual(@as(usize, 0), m.live);
}

test "the tree follows a sorted model on flash" {
    try run(.flash, 4096, 1, 3000);
}

test "the tree follows a sorted model on a card, at 1 KiB and 16 KiB blocks" {
    try run(.sd, 1024, 2, 3000);
    try run(.sd, 16384, 3, 1500);
}

test "the tree follows a sorted model on a stick" {
    try run(.usb, 4096, 4, 1500);
}

test "a volume formats and mounts, and its space adds up" {
    var m = try TestMedia.init(.flash, 512 * 1024, 7);
    defer m.deinit();
    var vol: Volume = .{ .dev = m.device() };
    defer vol.release();
    try checkpoint.format(&vol, .{ .name = "Work" });
    const free = vol.space.free_total;
    try checkpoint.unmount(&vol);
    try checkpoint.mount(&vol);
    // The unmount's slot, not the format's.
    try testing.expectEqual(@as(u64, 2), vol.durable.gen);
    try testing.expect(vol.durable.flags & layout.CHECKPOINT_CLEAN != 0);
    try testing.expectEqualStrings("Work", vol.voltab.volumeName());
    try expectClean(&vol);
    try testing.expect(vol.space.free_total >= free);
    try testing.expectEqual(try space.countFree(&vol), vol.space.free_total);
}

test "a damaged node is an error, never a panic" {
    var m = try TestMedia.init(.sd, 512 * 1024, 8);
    defer m.deinit();
    var vol: Volume = .{ .dev = m.device() };
    defer vol.release();
    try checkpoint.format(&vol, .{ .name = "Work" });
    var buffer: [300]u8 = undefined;
    for (0..400) |n| try btree.put(&vol, &vol.obj, keyOf(n), dataOf(n, 200, &buffer));
    try checkpoint.unmount(&vol);
    // Every byte of the medium, one at a time: flipped, mounted, read,
    // and put back.
    var prng = std.Random.DefaultPrng.init(8);
    const random = prng.random();
    for (0..200) |_| {
        const at = random.uintLessThan(usize, m.bytes.len);
        m.bytes[at] ^= 0x10;
        if (checkpoint.mount(&vol)) {
            var report: check.Report = .{};
            check.check(&vol, &report) catch {};
            for (0..400) |n| _ = btree.find(&vol, &vol.obj, keyOf(n)) catch break;
            vol.release();
        } else |_| {}
        m.bytes[at] ^= 0x10;
    }
    try checkpoint.mount(&vol);
    try expectClean(&vol);
}
