// SPDX-License-Identifier: MIT
//! What the power-cut tests of both file systems share: a step - a file
//! written, deleted, opened over and rewritten, cut short, made longer,
//! renamed into a directory, a directory grown by a cluster, one made -
//! run on a fresh volume once for every block it writes, the card going
//! after that many, and the volume judged as it mounts again. Then once
//! whole, after which the volume is marked clean.
//!
//! Every free cluster holds bytes that are not the pattern before the
//! step runs, so a chain or an entry that reached the medium before what
//! it names reads as wrong bytes, a free cluster or, in a directory, as
//! entries that should not be there.
//!
//! **The cache's own order is set against the file system's.** The block
//! cache writes back in the order of its slots, which is the order it
//! read the blocks in. A step whose barrier keeps an entry back is run on
//! clusters from a part of the table the cache has not read yet
//! (`startAllocationFar`), so the entry's block comes first in that
//! order; a step whose barrier keeps clusters taken until their entry is
//! gone works on a file in a directory read after the table, so the
//! table's block comes first. Without the barrier either one goes to the
//! medium in the wrong order, and the test sees it.
//!
//! `Rig` is either test file's. Besides the packets (`open`, `read`,
//! `close`, `sendArgs`, `setSize`, `writeFile`, `mkdir`, `delete`, `rename`) it has `init`, `deinit`, `testMedia`, `fillFree`,
//! `startAllocationFar`, `restartAfterCut`, `checkTree` and
//! `cleanOnMedium`, and `full_dir_files`: how many files of a short name
//! fill a new directory's one cluster.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const FileHandle = dos.FileHandle;

const testing = std.testing;

/// What a cut is tried against.
pub const Step = enum { write, delete, empty, shorten, extend, rename, grow, mkdir };

/// One form a file may have: `len` bytes, the first `pattern_len` of them
/// what the pattern `seed` makes and the rest zeroes.
const Form = struct {
    len: usize,
    seed: u8 = 0,
    pattern_len: usize = std.math.maxInt(usize),
};

/// The file every step starts with, three clusters of one sector and a
/// piece of a fourth, what it is replaced or cut down to, and what it is
/// made longer to.
const old_bytes = 1636;
const new_bytes = 700;
const long_bytes = 3000;
const old_form: Form = .{ .len = old_bytes, .seed = 1 };
const nothing: Form = .{ .len = 0 };

/// Bytes that say where they are, so a piece read from the wrong place
/// shows.
fn pattern(into: []u8, seed: u8) void {
    for (into, 0..) |*byte, at| byte.* = @truncate(at * 7 + seed + at / 509);
}

/// The file a step works on: in the directory, where the table is read
/// before its block; in the root for a rename into the directory, whose
/// block then comes after the root's.
fn subject(step: Step) [*:0]const u8 {
    return switch (step) {
        .rename, .grow, .mkdir => "F",
        else => "D/F",
    };
}

/// The names that fill the directory before it grows: D/F00, D/F01, ...
fn fillName(into: *[5:0]u8, number: usize) [*:0]const u8 {
    into.* = "D/F00".*;
    into[3] = '0' + @as(u8, @intCast(number / 10));
    into[4] = '0' + @as(u8, @intCast(number % 10));
    return into;
}

/// The step run on a fresh volume made with `options`, cut after every
/// number of blocks it writes in turn; then whole.
pub fn everywhere(comptime Rig: type, options: anytype, step: Step) !void {
    var blocks: u32 = 0;
    while (true) : (blocks += 1) {
        try testing.expect(blocks < 300);
        var rig: Rig = undefined;
        try rig.init(options);
        defer rig.deinit();
        try prepare(&rig, step);
        rig.testMedia().budget = blocks;
        try perform(&rig, step);
        const whole = rig.testMedia().budget.? > 0;
        try rig.restartAfterCut();
        try judge(&rig, step);
        if (whole) {
            try testing.expect(try rig.cleanOnMedium());
            return;
        }
    }
}

/// What the step starts from, written whole: a directory, the file and,
/// to grow, the directory full; then the free clusters filled.
fn prepare(rig: anytype, step: Step) !void {
    var old: [old_bytes]u8 = undefined;
    pattern(&old, old_form.seed);
    try rig.mkdir("D");
    try rig.writeFile(subject(step), &old);
    if (step == .grow) {
        var name: [5:0]u8 = undefined;
        for (0..@TypeOf(rig.*).full_dir_files) |number| try rig.writeFile(fillName(&name, number), "");
    }
    try rig.fillFree();
}

fn perform(rig: anytype, step: Step) !void {
    var new: [old_bytes]u8 = undefined;
    switch (step) {
        .write => {
            rig.startAllocationFar();
            pattern(&new, 3);
            try rig.writeFile("D/G", &new);
        },
        .delete => try testing.expectEqual(dos.DOSTRUE, rig.delete(subject(step)).res1),
        .empty => {
            pattern(&new, 2);
            try rig.writeFile(subject(step), new[0..new_bytes]);
        },
        .shorten, .extend => {
            const size: i64 = if (step == .shorten) new_bytes else long_bytes;
            if (step == .extend) rig.startAllocationFar();
            var fh: FileHandle = undefined;
            try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findupdate, subject(step)).res1);
            const sized = rig.setSize(&fh, size);
            try testing.expectEqual(dos.DOSTRUE, sized.reply.res1);
            try testing.expectEqual(size, sized.answer);
            try rig.close(&fh);
        },
        .rename => try testing.expectEqual(dos.DOSTRUE, rig.rename(subject(step), "D/G").res1),
        .grow => {
            pattern(&new, 2);
            try rig.writeFile("D/NEW", new[0..new_bytes]);
        },
        .mkdir => {
            rig.startAllocationFar();
            try rig.mkdir("D/SUB");
        },
    }
}

/// What may be found after a cut: each file as it was, as it was to
/// become, or - where the step goes through it - empty; never a byte that
/// is not the pattern or zero where zeroes were asked for, and never a
/// file lost that was not being deleted.
fn judge(rig: anytype, step: Step) !void {
    try rig.checkTree(step == .rename);
    const file = subject(step);
    switch (step) {
        .write => {
            try expectForm(rig, file, &.{old_form}, false);
            try expectForm(rig, "D/G", &.{ nothing, .{ .len = old_bytes, .seed = 3 } }, true);
        },
        .delete => try expectForm(rig, file, &.{old_form}, true),
        .empty => try expectForm(rig, file, &.{ old_form, nothing, .{ .len = new_bytes, .seed = 2 } }, false),
        .shorten => try expectForm(rig, file, &.{ old_form, .{ .len = new_bytes, .seed = 1 } }, false),
        .extend => try expectForm(rig, file, &.{ old_form, .{ .len = long_bytes, .seed = 1, .pattern_len = old_bytes } }, false),
        .rename => {
            var fh: FileHandle = undefined;
            const there = rig.open(&fh, .findinput, file).res1 == dos.DOSTRUE;
            if (there) try rig.close(&fh);
            try expectForm(rig, file, &.{old_form}, true);
            try expectForm(rig, "D/G", &.{old_form}, there);
        },
        .grow => {
            var name: [5:0]u8 = undefined;
            for (0..@TypeOf(rig.*).full_dir_files) |number| try expectForm(rig, fillName(&name, number), &.{nothing}, false);
            try expectForm(rig, "D/NEW", &.{ nothing, .{ .len = new_bytes, .seed = 2 } }, true);
        },
        .mkdir => try expectForm(rig, file, &.{old_form}, false),
    }
}

/// Whether `name` is one of `forms`, or gone when `may_be_gone`.
fn expectForm(rig: anytype, name: [*:0]const u8, forms: []const Form, may_be_gone: bool) !void {
    var fh: FileHandle = undefined;
    if (rig.open(&fh, .findinput, name).res1 != dos.DOSTRUE) {
        try testing.expect(may_be_gone);
        return;
    }
    var into: [long_bytes + 1]u8 = undefined;
    const count = rig.read(&fh, &into);
    try rig.close(&fh);
    var want: [long_bytes]u8 = undefined;
    for (forms) |form| {
        if (count != form.len) continue;
        const patterned = @min(form.len, form.pattern_len);
        pattern(want[0..patterned], form.seed);
        @memset(want[patterned..form.len], 0);
        if (std.mem.eql(u8, want[0..form.len], into[0..form.len])) return;
    }
    return error.TestUnexpectedResult;
}
