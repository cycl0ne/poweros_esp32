// SPDX-License-Identifier: MIT
//! The screen's title while the desktop is in front: how much memory is
//! free, the internal and the external (PSRAM) apart, since a picture or
//! a drawer of icons takes the one and anything an interrupt reads the
//! other. Made again every two seconds.

/// "Anvil   Internal 123 KB free   PSRAM 4,512 KB free" into `into`, NUL
/// after it; how long. Without external memory its part is left out.
pub fn memoryTitle(into: []u8, internal: usize, external: usize) usize {
    var n: usize = 0;
    n += put(into[n..], "Anvil   Internal ");
    n += kilobytes(into[n..], internal);
    n += put(into[n..], " KB free");
    if (external != 0) {
        n += put(into[n..], "   PSRAM ");
        n += kilobytes(into[n..], external);
        n += put(into[n..], " KB free");
    }
    into[n] = 0;
    return n;
}

fn put(into: []u8, text: []const u8) usize {
    @memcpy(into[0..text.len], text);
    return text.len;
}

/// Bytes as kilobytes, rounded down, the thousands parted by commas.
fn kilobytes(into: []u8, bytes: usize) usize {
    var digits: [12]u8 = undefined;
    var count: usize = 0;
    var left = bytes / 1024;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    var n: usize = 0;
    var i = count;
    while (i > 0) {
        i -= 1;
        into[n] = digits[i];
        n += 1;
        if (i > 0 and i % 3 == 0) {
            into[n] = ',';
            n += 1;
        }
    }
    return n;
}
