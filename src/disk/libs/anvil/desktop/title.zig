// SPDX-License-Identifier: MIT
//! The screen's title while the desktop is in front: how much memory is
//! free - the internal and the external (PSRAM) apart, since a picture or
//! a drawer of icons takes the one and anything an interrupt reads the
//! other, or the one figure on a machine whose RAM is one kind
//! (SYSTAG_UnifiedMemory) - and on a board that measures its battery, the
//! charge left. Made again every two seconds.

const battery = @import("sdk").resources.battery;

/// "Anvil   Internal 123 KB free   PSRAM 4.4 MB free" into `into`, NUL
/// after it; how long. Without external memory its part is left out.
/// With `unified` the machine's one RAM, `internal` all of it and
/// `external` not looked at: "Anvil   Memory 7.98 GB free". With a
/// battery's state that has a cell, "   Battery 70%" after it, and
/// ", charging" or ", external power" where the board can tell.
pub fn memoryTitle(into: []u8, internal: usize, external: usize, unified: bool, cell: ?*const battery.BatteryState) usize {
    var n: usize = 0;
    if (unified) {
        n += put(into[n..], "Anvil   Memory ");
        n += amount(into[n..], internal);
        n += put(into[n..], " free");
    } else {
        n += put(into[n..], "Anvil   Internal ");
        n += amount(into[n..], internal);
        n += put(into[n..], " free");
        if (external != 0) {
            n += put(into[n..], "   PSRAM ");
            n += amount(into[n..], external);
            n += put(into[n..], " free");
        }
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

const KiB: u64 = 1024;
const MiB: u64 = 1024 * KiB;
const GiB: u64 = 1024 * MiB;

/// Bytes in the unit that suits them, rounded down - what is free is
/// never made more than it is: kilobytes below a megabyte ("123 KB"),
/// megabytes to a tenth below a gigabyte ("4.4 MB"), gigabytes to a
/// hundredth above ("7.98 GB").
fn amount(into: []u8, bytes: usize) usize {
    const all: u64 = bytes;
    var n: usize = 0;
    if (all < MiB) {
        n += kilobytes(into[n..], bytes);
        n += put(into[n..], " KB");
    } else if (all < GiB) {
        const tenths = all * 10 / MiB;
        n += number(into[n..], @intCast(tenths / 10));
        n += put(into[n..], ".");
        n += number(into[n..], @intCast(tenths % 10));
        n += put(into[n..], " MB");
    } else {
        const hundredths = all * 100 / GiB;
        n += number(into[n..], @intCast(hundredths / 100));
        n += put(into[n..], if (hundredths % 100 < 10) ".0" else ".");
        n += number(into[n..], @intCast(hundredths % 100));
        n += put(into[n..], " GB");
    }
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
