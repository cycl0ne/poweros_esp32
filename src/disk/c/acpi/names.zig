// SPDX-License-Identifier: MIT
//! The names Acpi saves the tables under: a table's four letters and
//! ".aml", and where the root's list has more than one table with those
//! letters, its place among them as well, from 1 in the list's order -
//! FACP.aml, APIC.aml, SSDT1.aml, SSDT2.aml - so that a disassembler finds
//! the main table and each one it needs beside it by name, and the order
//! they are loaded in is the order of their numbers.

const acpi = @import("sdk").hardware.acpi;

/// Room for a name: four letters, a place of up to ten digits, ".aml".
pub const NAME_ROOM = 20;

/// Where a table stands among those the list has with its letters: its
/// place, from 1, and how many there are.
pub const Place = struct {
    place: u32 = 1,
    of: u32 = 1,
};

/// The place of the list's `index`th table among the tables the list has
/// with the same four letters, counted in the list's order. A table the
/// list names whose checksum does not hold is counted all the same: the
/// numbers follow the list, whatever is saved.
pub fn placeOf(root: *const acpi.Root, index: u32) Place {
    const table = root.table(index);
    if (table == 0) return .{};
    const letters = acpi.headerOf(table).signature;
    var place: Place = .{ .place = 0, .of = 0 };
    var other: u32 = 0;
    while (other < root.count) : (other += 1) {
        const at = root.table(other);
        if (at == 0) continue;
        if (!sameLetters(acpi.headerOf(at).signature, letters)) continue;
        place.of += 1;
        if (other <= index) place.place += 1;
    }
    return place;
}

/// The file name for a table with `letters` at `place` among `of` of
/// them, written into `into`. A letter a file name should not carry - a
/// table written over can have any bytes there - is written as "_".
pub fn nameOf(letters: [4]u8, place: Place, into: *[NAME_ROOM:0]u8) [*:0]const u8 {
    var at: usize = 0;
    for (letters) |char| {
        into[at] = fileChar(char);
        at += 1;
    }
    if (place.of > 1) at += writeNumber(place.place, into[at..]);
    for (".aml") |char| {
        into[at] = char;
        at += 1;
    }
    into[at] = 0;
    return into;
}

fn sameLetters(one: [4]u8, other: [4]u8) bool {
    for (one, other) |a, b| {
        if (a != b) return false;
    }
    return true;
}

fn fileChar(char: u8) u8 {
    return switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9', '_' => char,
        else => '_',
    };
}

/// `value` in decimal at the start of `into`: how many digits.
fn writeNumber(value: u32, into: []u8) usize {
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var rest = value;
    while (true) {
        digits[count] = @intCast('0' + rest % 10);
        count += 1;
        rest /= 10;
        if (rest == 0) break;
    }
    for (0..count) |at| into[at] = digits[count - 1 - at];
    return count;
}
