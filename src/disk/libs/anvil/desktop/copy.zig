// SPDX-License-Identifier: MIT
//! A drag's copy to another volume: the job that does it.

const work = @import("work.zig");
const Desktop = @import("_desktop.zig").Desktop;

/// `from` copied into the drawer `into`, on the worker's process.
pub fn start(d: *Desktop, from: [*:0]const u8, into: [*:0]const u8) void {
    work.start(d, .copy, &.{textOf(from)}, textOf(into));
}

fn textOf(text: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return text[0..n];
}
