// SPDX-License-Identifier: MIT
//! Host tests of `autoboot.txt` (`sdk.install.autoboot`): the file read,
//! the file written, the swap that makes a tried partition the one the
//! machine starts from, what a file that says nothing comes to, and which
//! system may keep the tried partition.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const autoboot = sdk.install.autoboot;

test "the two sections read" {
    const settings = autoboot.parse(
        \\[all]
        \\tryboot_a_b=1
        \\boot_partition=1
        \\[tryboot]
        \\boot_partition=2
        \\
    );
    try testing.expectEqual(@as(u32, 1), settings.normal);
    try testing.expectEqual(@as(u32, 2), settings.tried);
    try testing.expect(settings.a_b);
}

test "a file that says nothing is the firmware's own choice" {
    const settings = autoboot.parse("");
    try testing.expectEqual(@as(u32, 0), settings.normal);
    try testing.expectEqual(@as(u32, 0), settings.tried);
    try testing.expect(!settings.a_b);
}

test "comments, blanks and a host's line ends are passed over" {
    const settings = autoboot.parse("# which partition\r\n [ALL] \r\n\r\nboot_partition = 2 # the system\r\n[TryBoot]\r\nboot_partition=1\r\n");
    try testing.expectEqual(@as(u32, 2), settings.normal);
    try testing.expectEqual(@as(u32, 1), settings.tried);
}

test "a key outside the two sections is not taken" {
    const settings = autoboot.parse(
        \\[none]
        \\boot_partition=4
        \\[pi5]
        \\boot_partition=5
        \\
    );
    try testing.expectEqual(@as(u32, 0), settings.normal);
    try testing.expectEqual(@as(u32, 0), settings.tried);
}

test "what is not a number is left as it was" {
    const settings = autoboot.parse("[all]\nboot_partition=first\n");
    try testing.expectEqual(@as(u32, 0), settings.normal);
}

test "written and read back" {
    var bytes: [autoboot.max_bytes]u8 = undefined;
    const settings: autoboot.Settings = .{ .normal = 2, .tried = 1, .a_b = true };
    const length = autoboot.write(settings, &bytes);
    try testing.expectEqualStrings("[all]\ntryboot_a_b=1\nboot_partition=2\n[tryboot]\nboot_partition=1\n", bytes[0..length]);
    const read = autoboot.parse(bytes[0..length]);
    try testing.expectEqual(settings.normal, read.normal);
    try testing.expectEqual(settings.tried, read.tried);
    try testing.expectEqual(settings.a_b, read.a_b);
}

test "one partition is written without a tryboot section" {
    var bytes: [autoboot.max_bytes]u8 = undefined;
    const length = autoboot.write(.{ .normal = 1 }, &bytes);
    try testing.expectEqualStrings("[all]\nboot_partition=1\n", bytes[0..length]);
}

test "the swap makes the tried partition the one it starts from" {
    const settings: autoboot.Settings = .{ .normal = 1, .tried = 2, .a_b = true };
    const after = settings.swapped();
    try testing.expectEqual(@as(u32, 2), after.normal);
    try testing.expectEqual(@as(u32, 1), after.tried);
    try testing.expect(after.a_b);
    // And back again, so a pair of updates is where it started.
    const again = after.swapped();
    try testing.expectEqual(settings.normal, again.normal);
    try testing.expectEqual(settings.tried, again.tried);
}

test "only the system started from the tried partition keeps it" {
    const written: autoboot.Settings = .{ .normal = 2, .tried = 3, .a_b = true };
    // Before the restart, and after a try that did not come up: started
    // from the partition that worked.
    try testing.expectEqual(autoboot.Keeping.not_this_one, autoboot.keeping(written, 2));
    // The new kernel, come up on its try.
    try testing.expectEqual(autoboot.Keeping.this_one, autoboot.keeping(written, 3));
    // After the swap the file names the old partition to try; the system
    // the firmware now starts from has nothing to keep.
    const kept = written.swapped();
    try testing.expectEqual(autoboot.Keeping.not_this_one, autoboot.keeping(kept, 3));
}

test "keeping with nothing tried, or the start not known" {
    try testing.expectEqual(autoboot.Keeping.nothing_tried, autoboot.keeping(.{ .normal = 2 }, 2));
    try testing.expectEqual(autoboot.Keeping.nothing_tried, autoboot.keeping(.{}, 0));
    try testing.expectEqual(autoboot.Keeping.start_unknown, autoboot.keeping(.{ .normal = 2, .tried = 3 }, 0));
}
