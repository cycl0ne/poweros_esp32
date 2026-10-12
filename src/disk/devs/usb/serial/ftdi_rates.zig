// SPDX-License-Identifier: MIT
//! An FTDI chip's rate as SET_BAUD_RATE takes it - with no hardware and
//! no system, so the host tests hold it.

/// The divisor for `baud`, as SET_BAUD_RATE takes it: 3 MHz over the
/// rate in eighths, the integer part in bits 0-13 and the eighths coded
/// in bits 14-16 - which spill into the request's index. 3 MBd and
/// 2 MBd have codes of their own.
pub fn divisorOf(baud: u32) u32 {
    const eighths_code = [8]u32{ 0, 3, 2, 4, 1, 5, 6, 7 };
    const divisor8 = (24_000_000 + baud / 2) / @max(baud, 1);
    var divisor = (divisor8 >> 3) | (eighths_code[divisor8 & 7] << 14);
    if (divisor == 1) divisor = 0;
    if (divisor == 0x4001) divisor = 1;
    return divisor;
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

test "FTDI's divisors: whole, in eighths, and the two coded rates" {
    // 9600: 3 MHz / 9600 = 312.5, which is 312 and four eighths (code 1).
    try testing.expectEqual(@as(u32, 312 | (1 << 14)), divisorOf(9600));
    // 115200: 26.04, which rounds to 26 whole.
    try testing.expectEqual(@as(u32, 26), divisorOf(115_200));
    try testing.expectEqual(@as(u32, 0), divisorOf(3_000_000));
    try testing.expectEqual(@as(u32, 1), divisorOf(2_000_000));
}
