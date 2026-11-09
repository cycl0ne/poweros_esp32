// SPDX-License-Identifier: MIT
//! The screen's title while the desktop is in front: how much memory is
//! free - the internal and the external (PSRAM) apart, since a picture or
//! a drawer of icons takes the one and anything an interrupt reads the
//! other, or the one figure on a machine whose RAM is one kind
//! (SYSTAG_UnifiedMemory) - and on a board that measures its battery, the
//! charge left. Made again every two seconds.

const battery = @import("sdk").resources.battery;

/// The title's words, in the language the desktop speaks, and what parts
/// its numbers, as the default locale writes them; English as built in.
pub const Words = struct {
    memory: [*:0]const u8 = "Memory",
    internal: [*:0]const u8 = "Internal",
    psram: [*:0]const u8 = "PSRAM",
    free: [*:0]const u8 = "free",
    battery: [*:0]const u8 = "Battery",
    charging: [*:0]const u8 = "charging",
    external_power: [*:0]const u8 = "external power",
    /// What parts the thousands, and what comes before the decimals.
    group: [*:0]const u8 = ",",
    point: [*:0]const u8 = ".",
};

/// "Anvil   Internal 123 KB free   PSRAM 4.4 MB free" into `into`, NUL
/// after it and cut to fit; how long. Without external memory its part
/// is left out. With `unified` the machine's one RAM, `internal` all of
/// it and `external` not looked at: "Anvil   Memory 7.98 GB free". With a
/// battery's state that has a cell, "   Battery 70%" after it, and
/// ", charging" or ", external power" where the board can tell - each
/// word from `words`.
pub fn memoryTitle(into: []u8, internal: usize, external: usize, unified: bool, cell: ?*const battery.BatteryState, words: *const Words) usize {
    const room = into[0 .. into.len - 1];
    var n: usize = 0;
    n += put(room[n..], "Anvil   ");
    if (unified) {
        n += free(room[n..], words.memory, internal, words);
    } else {
        n += free(room[n..], words.internal, internal, words);
        if (external != 0) {
            n += put(room[n..], "   ");
            n += free(room[n..], words.psram, external, words);
        }
    }
    if (cell) |state| {
        if (state.flags & battery.BATTF_PRESENT != 0) {
            n += put(room[n..], "   ");
            n += put(room[n..], textOf(words.battery));
            n += put(room[n..], " ");
            n += number(room[n..], state.percent);
            n += put(room[n..], "%");
            if (state.flags & battery.BATTF_CHARGING != 0) {
                n += put(room[n..], ", ");
                n += put(room[n..], textOf(words.charging));
            } else if (state.flags & battery.BATTF_EXTERNAL != 0) {
                n += put(room[n..], ", ");
                n += put(room[n..], textOf(words.external_power));
            }
        }
    }
    into[n] = 0;
    return n;
}

/// "Internal 123 KB free": a kind of memory, how much of it, `words`'
/// word for free after.
fn free(into: []u8, kind: [*:0]const u8, bytes: usize, words: *const Words) usize {
    var n: usize = 0;
    n += put(into[n..], textOf(kind));
    n += put(into[n..], " ");
    n += amount(into[n..], bytes, words);
    n += put(into[n..], " ");
    n += put(into[n..], textOf(words.free));
    return n;
}

fn textOf(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}

const KiB: u64 = 1024;
const MiB: u64 = 1024 * KiB;
const GiB: u64 = 1024 * MiB;

/// Bytes in the unit that suits them, rounded down - what is free is
/// never made more than it is: kilobytes below a megabyte ("123 KB"),
/// megabytes to a tenth below a gigabyte ("4.4 MB"), gigabytes to a
/// hundredth above ("7.98 GB"); parted and pointed as `words` says.
fn amount(into: []u8, bytes: usize, words: *const Words) usize {
    const all: u64 = bytes;
    const point = textOf(words.point);
    var n: usize = 0;
    if (all < MiB) {
        n += kilobytes(into[n..], bytes, words.group);
        n += put(into[n..], " KB");
    } else if (all < GiB) {
        const tenths = all * 10 / MiB;
        n += number(into[n..], @intCast(tenths / 10));
        n += put(into[n..], point);
        n += number(into[n..], @intCast(tenths % 10));
        n += put(into[n..], " MB");
    } else {
        const hundredths = all * 100 / GiB;
        n += number(into[n..], @intCast(hundredths / 100));
        n += put(into[n..], point);
        if (hundredths % 100 < 10) n += put(into[n..], "0");
        n += number(into[n..], @intCast(hundredths % 100));
        n += put(into[n..], " GB");
    }
    return n;
}

fn number(into: []u8, value: u32) usize {
    var digits: [10]u8 = undefined;
    var at: usize = digits.len;
    var left = value;
    while (true) {
        at -= 1;
        digits[at] = '0' + @as(u8, @intCast(left % 10));
        left /= 10;
        if (left == 0) break;
    }
    return put(into, digits[at..]);
}

/// `text` copied, as much of it as there is room for; how much.
fn put(into: []u8, text: []const u8) usize {
    const take = @min(text.len, into.len);
    @memcpy(into[0..take], text[0..take]);
    return take;
}

/// Bytes as kilobytes, rounded down, the thousands parted by `group`.
fn kilobytes(into: []u8, bytes: usize, group: [*:0]const u8) usize {
    var digits: [12]u8 = undefined;
    var count: usize = 0;
    var left = bytes / 1024;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    const separator = textOf(group);
    var n: usize = 0;
    var i = count;
    while (i > 0) {
        i -= 1;
        n += put(into[n..], digits[i..][0..1]);
        if (i > 0 and i % 3 == 0) n += put(into[n..], separator);
    }
    return n;
}
