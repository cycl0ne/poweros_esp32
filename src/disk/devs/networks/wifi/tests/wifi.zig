// SPDX-License-Identifier: MIT
//! Host tests of wifi.device's own code that needs neither the radio nor
//! its libraries: the C formats, the queues' ring, which timer runs next,
//! and the layouts the libraries read. The adapter's waiting is exec's
//! Signal and Wait and is proved on the board.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const kexec = @import("host_rom").exec;
const osi_timer = @import("../osi/timer.zig");
const regulatory = @import("../regulatory.zig");

const testing = std.testing;

test {
    _ = @import("../format.zig");
    _ = @import("../osi/queue.zig");
}

test "the next timer is the first one due" {
    try kexec.setUp();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    var timers: exec.List = .{};
    timers.init(.unknown);
    var records = [_]osi_timer.Record{ .{ .due = 0 }, .{ .due = 500 }, .{ .due = 300 }, .{ .due = 900 } };
    for (&records) |*record| sys.AddTail(&timers, &record.node);

    var nearest: u64 = 0;
    try testing.expect(osi_timer.nextDue(&timers, 100, &nearest) == null);
    try testing.expectEqual(@as(u64, 300), nearest);
    try testing.expect(osi_timer.nextDue(&timers, 600, &nearest) == &records[1]);
    records[1].due = 0;
    records[2].due = 0;
    try testing.expect(osi_timer.nextDue(&timers, 600, &nearest) == null);
    try testing.expectEqual(@as(u64, 900), nearest);
    records[3].due = 0;
    try testing.expect(osi_timer.nextDue(&timers, 600, &nearest) == null);
    try testing.expectEqual(@as(u64, 0), nearest);
    try kexec.expectNoLeaks();
}

test "the layouts the libraries read" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(regulatory.Rule));
    try testing.expectEqual(@as(usize, 10), @sizeOf(regulatory.Regulatory));
    try testing.expectEqual(@as(usize, 3), @sizeOf(regulatory.Domain));
    try testing.expectEqualStrings("##", &regulatory.regdomain_table[regulatory.regdomain_table.len - 1].code);
}
