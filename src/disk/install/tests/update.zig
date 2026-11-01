// SPDX-License-Identifier: MIT
//! Host tests of what an update does with one path (`sdk.install.update`):
//! every line of the rule, the file read only where the two lists differ,
//! and what FORCE changes.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const update = sdk.install.update;

fn file(crc: u32, size: u64) update.Entry {
    return .{ .kind = .file, .path = "system/C/List", .crc = crc, .size = size };
}

const drawer: update.Entry = .{ .kind = .drawer, .path = "system/C" };

test "a file both lists say the same about is left alone, unread" {
    const had = file(0x1234, 100);
    const want = file(0x1234, 100);
    try testing.expect(update.agree(had, want));
    try testing.expectEqual(update.Action.keep, update.actionFor(had, want, .unread, false));
}

test "a file both lists say the same about but is gone comes back" {
    // Where the lists agree the path is looked for and not read, so this
    // is the one thing that happens to a file the build left alone.
    const had = file(0x1234, 100);
    const want = file(0x1234, 100);
    try testing.expectEqual(update.Action.write, update.actionFor(had, want, .gone, false));
    try testing.expectEqual(update.Action.make, update.actionFor(drawer, drawer, .gone, false));
}

test "a file the build changed is written, whatever is here" {
    const had = file(0x1234, 100);
    const want = file(0x9999, 120);
    try testing.expect(!update.agree(had, want));
    try testing.expectEqual(update.Action.write, update.actionFor(had, want, .same, false));
    try testing.expectEqual(update.Action.write, update.actionFor(had, want, .gone, false));
}

test "a file changed here is kept and named, and FORCE writes it" {
    const had = file(0x1234, 100);
    const want = file(0x9999, 120);
    try testing.expectEqual(update.Action.kept, update.actionFor(had, want, .changed, false));
    try testing.expectEqual(update.Action.write, update.actionFor(had, want, .changed, true));
}

test "a file only the package names is fetched" {
    const want = file(0x9999, 120);
    try testing.expect(!update.agree(null, want));
    try testing.expectEqual(update.Action.write, update.actionFor(null, want, .gone, false));
}

test "the machine's own file at a path the build now ships is kept" {
    // No list the machine was given names it, so nothing can say the
    // file is the build's: it counts as changed here.
    const want = file(0x9999, 120);
    try testing.expectEqual(update.Action.kept, update.actionFor(null, want, .changed, false));
    try testing.expectEqual(update.Action.write, update.actionFor(null, want, .changed, true));
}

test "a file the build dropped is deleted, unless it was changed here" {
    const had = file(0x1234, 100);
    try testing.expectEqual(update.Action.delete, update.actionFor(had, null, .same, false));
    try testing.expectEqual(update.Action.kept, update.actionFor(had, null, .changed, false));
    try testing.expectEqual(update.Action.delete, update.actionFor(had, null, .changed, true));
    // Already gone: nothing to do.
    try testing.expectEqual(update.Action.keep, update.actionFor(had, null, .gone, false));
}

test "drawers are made, kept and dropped" {
    try testing.expectEqual(update.Action.make, update.actionFor(null, drawer, .gone, false));
    try testing.expectEqual(update.Action.keep, update.actionFor(drawer, drawer, .unread, false));
    try testing.expect(update.agree(drawer, drawer));
    try testing.expectEqual(update.Action.delete, update.actionFor(drawer, null, .unread, false));
}

test "a file already the package's is left alone: an update cut off" {
    // Written by a run that ended before its list was written.
    const had = file(0x1234, 100);
    const want = file(0x9999, 120);
    try testing.expectEqual(update.Action.keep, update.actionFor(had, want, .wanted, false));
    try testing.expectEqual(update.Action.keep, update.actionFor(null, want, .wanted, false));
}

test "a path in neither list is nothing to do" {
    try testing.expectEqual(update.Action.keep, update.actionFor(null, null, .unread, false));
}

test "a drawer that became a file, and the other way" {
    const want = file(0x1234, 100);
    try testing.expect(!update.agree(drawer, want));
    try testing.expectEqual(update.Action.write, update.actionFor(drawer, want, .same, false));
    try testing.expectEqual(update.Action.make, update.actionFor(want, drawer, .unread, false));
}
