// SPDX-License-Identifier: MIT
//! MemMap's arithmetic that needs no window: an amount of memory as text,
//! and the pixels of the one band a region gets on a machine whose RAM is
//! one kind.

const KiB: u64 = 1024;
const MiB: u64 = 1024 * KiB;
const GiB: u64 = 1024 * MiB;

/// Bytes in the unit that suits them, rounded down, into `into` with a NUL
/// after: bytes below a kilobyte ("238 bytes", "1 byte"), kilobytes below a megabyte
/// ("123 KB"), megabytes to a tenth below a gigabyte ("4.4 MB"),
/// gigabytes to a hundredth above ("7.98 GB"). How long.
pub fn amount(into: []u8, bytes: usize) usize {
    const all: u64 = bytes;
    var n: usize = 0;
    if (all < KiB) {
        n += number(into[n..], all);
        n += put(into[n..], if (all == 1) " byte" else " bytes");
    } else if (all < MiB) {
        n += number(into[n..], all / KiB);
        n += put(into[n..], " KB");
    } else if (all < GiB) {
        const tenths = all * 10 / MiB;
        n += number(into[n..], tenths / 10);
        n += put(into[n..], ".");
        n += number(into[n..], tenths % 10);
        n += put(into[n..], " MB");
    } else {
        const hundredths = all * 100 / GiB;
        n += number(into[n..], hundredths / 100);
        n += put(into[n..], if (hundredths % 100 < 10) ".0" else ".");
        n += number(into[n..], hundredths % 100);
        n += put(into[n..], " GB");
    }
    into[n] = 0;
    return n;
}

/// A region's run of the band's pixels: from `first`, `pixels` long.
pub const Piece = struct {
    first: usize,
    pixels: usize,
};

/// The pixels of a band of `pixels` that a region of `size` bytes gets
/// when the regions ahead of it hold `before` bytes and all of them
/// `total`: in proportion, so a pixel is the same number of bytes all
/// along, and the pieces follow one another with no gap.
pub fn share(before: usize, size: usize, total: usize, pixels: usize) Piece {
    const whole: u64 = @max(total, 1);
    const start = @as(u64, before) * pixels / whole;
    const end = (@as(u64, before) + size) * pixels / whole;
    return .{ .first = @intCast(start), .pixels = @intCast(end - start) };
}

fn number(into: []u8, value: u64) usize {
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var left = value;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    var i: usize = 0;
    while (i < count) : (i += 1) into[i] = digits[count - 1 - i];
    return count;
}

fn put(into: []u8, text: []const u8) usize {
    @memcpy(into[0..text.len], text);
    return text.len;
}
