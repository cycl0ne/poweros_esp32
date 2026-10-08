// SPDX-License-Identifier: MIT
//! BumpRevision: the name for a copy.

const sdk = @import("sdk");
const IconBase = @import("../icon_base.zig").IconBase;
const _tooltype = @import("../tooltype/_tooltype.zig");

/// The longest name written, as dos takes one.
const NAME_MAX = 255;

/// Writes into `into` the name a copy of `name` gets.
///
/// SYNOPSIS:
/// ```zig
/// fn BumpRevision(base: *IconBase, into: [*]u8, name: [*:0]const u8) [*:0]u8
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `into` - room for 256 bytes.
/// - `name` - the name copied.
///
/// RESULT:
/// `into`, holding the copy's name.
///
/// BEHAVIOR:
/// A first copy is `Copy_of_<name>`. A name that is already a copy's -
/// `Copy_of_x`, `Copy_2_of_x`, `copy of x`, any case, a space or an
/// underscore between the words - becomes the next: `Copy_2_of_x`,
/// `Copy_3_of_x`. A name that starts with `Copy` but goes on otherwise
/// is copied as any other. The answer is cut at 255 characters.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: any.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `into` is the caller's.
///
/// NOTES:
/// It only makes the name: whether a file of that name is there already
/// is the caller's to ask, and to bump again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PutDiskObject`
///
/// EXAMPLES:
/// ```zig
/// // "foo" -> "Copy_of_foo", "Copy_of_foo" -> "Copy_2_of_foo",
/// // "Copy_2_of_foo" -> "Copy_3_of_foo", "copy_0_of_foo" ->
/// // "Copy_1_of_foo", "copy foo" -> "Copy_of_copy foo".
/// var name: [256]u8 = undefined;
/// _ = ib.BumpRevision(&name, "Notes");
/// ```
pub fn BumpRevision(base: *IconBase, into: [*]u8, name: [*:0]const u8) [*:0]u8 {
    _ = base;
    // What is copied, and which copy this is.
    var real: [*:0]const u8 = name;
    var revision: u32 = 0;
    var first = true;
    if (_tooltype.startsWith(name, "copy ") or _tooltype.startsWith(name, "copy_")) {
        var at: usize = 5;
        var digits = false;
        while (name[at] >= '0' and name[at] <= '9') : (at += 1) {
            digits = true;
            revision = revision *% 10 +% (name[at] - '0');
        }
        if (digits and name[at] != 0) at += 1;
        if (_tooltype.startsWith(name + at, "of ") or _tooltype.startsWith(name + at, "of_")) {
            real = name + at + 3;
            first = false;
            revision += if (digits) 1 else 2;
        } else {
            revision = 0;
        }
    }

    var out: usize = 0;
    const head = "Copy_";
    @memcpy(into[0..head.len], head);
    out = head.len;
    if (!first) {
        var digits: [10]u8 = undefined;
        var at: usize = digits.len;
        var rest = revision;
        while (true) {
            at -= 1;
            digits[at] = '0' + @as(u8, @intCast(rest % 10));
            rest /= 10;
            if (rest == 0) break;
        }
        @memcpy(into[out..][0 .. digits.len - at], digits[at..]);
        out += digits.len - at;
        into[out] = '_';
        out += 1;
    }
    @memcpy(into[out..][0..3], "of_");
    out += 3;
    var index: usize = 0;
    while (out < NAME_MAX and real[index] != 0) : (index += 1) {
        into[out] = real[index];
        out += 1;
    }
    into[out] = 0;
    return @ptrCast(into);
}
