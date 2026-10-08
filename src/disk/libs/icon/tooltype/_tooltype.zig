// SPDX-License-Identifier: MIT
//! What the tool type calls and BumpRevision share: letters compared
//! without regard to case. A tool type's name, its values and the
//! `copy` a copy's name starts with are all taken in any case.

/// Whether `text` starts with `prefix`, in any case.
pub fn startsWith(text: [*:0]const u8, prefix: []const u8) bool {
    for (prefix, 0..) |char, index| {
        if (text[index] == 0 or upper(text[index]) != upper(char)) return false;
    }
    return true;
}

/// Whether two runs of letters are the same, in any case.
pub fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (upper(x) != upper(y)) return false;
    return true;
}

pub fn length(text: [*:0]const u8) usize {
    var at: usize = 0;
    while (text[at] != 0) at += 1;
    return at;
}

fn upper(char: u8) u8 {
    return if (char >= 'a' and char <= 'z') char - 32 else char;
}
