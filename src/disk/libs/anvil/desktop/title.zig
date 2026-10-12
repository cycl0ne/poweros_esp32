// SPDX-License-Identifier: MIT
//! The screen's title while the desktop is in front: how much memory is
//! free, the internal and the external (PSRAM) apart, since a picture or
//! a drawer of icons takes the one and anything an interrupt reads the
//! other - and on a board that measures its battery, the charge left.
//! Made again every two seconds.

const battery = @import("sdk").resources.battery;

/// "Anvil   Internal 123 KB free   PSRAM 4,512 KB free" into `into`, NUL
/// after it; how long. Without external memory its part is left out.
/// With a battery's state that has a cell, "   Battery 70%" after it,
/// and ", charging" or ", external power" where the board can tell.
pub fn memoryTitle(into: []u8, internal: usize, external: usize, cell: ?*const battery.BatteryState) usize {
    var n: usize = 0;
    n += put(into[n..], "Anvil   Internal ");
    n += kilobytes(into[n..], internal);
    n += put(into[n..], " KB free");
    if (external != 0) {
        n += put(into[n..], "   PSRAM ");
        n += kilobytes(into[n..], external);
        n += put(into[n..], " KB free");
    }
    if (cell) |state| {
        if (state.flags & battery.BATTF_PRESENT != 0) {
            n += put(into[n..], "   Battery ");
            n += number(into[n..], state.percent);
            n += put(into[n..], "%");
            if (state.flags & battery.BATTF_CHARGING != 0) {
                n += put(into[n..], ", charging");
            } else if (state.flags & battery.BATTF_EXTERNAL != 0) {
                n += put(into[n..], ", external power");
            }
        }
    }
    into[n] = 0;
    return n;
}

fn number(into: []u8, value: u32) usize {
    var digits: [10]u8 = undefined;
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
