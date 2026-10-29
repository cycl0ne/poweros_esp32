// SPDX-License-Identifier: MIT
//! FormatString: values written out by a template, as RawDoFmt writes
//! them, picked by their place and with their digits grouped.

const sdk = @import("sdk");
const utility = sdk.utility;
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const _format = @import("_format.zig");
const LocaleBase = _base.LocaleBase;
const Out = _format.Out;

/// The most values a template may use.
const max_values = 32;

/// Writes values out by a template, as RawDoFmt does, a value picked by
/// its place and the digits of a number grouped as the locale groups them.
///
/// SYNOPSIS:
/// ```zig
/// fn FormatString(lb: *LocaleBase, loc: *const locale.Locale, template: [*:0]const u8, data_stream: ?*const anyopaque, put_char_func: *utility.Hook) ?*const anyopaque
/// ```
///
/// SINCE: 1.0. LVO -104.
///
/// INPUTS:
/// - `loc` - a locale, from OpenLocale: its group separator and grouping.
/// - `template` - `%[n$][-][0][width][.limit][l|z]{d,D,u,U,x,X,s,c}`, as
///   RawDoFmt takes it, and `n$` to take the n-th value, from 1.
/// - `data_stream` - the values, packed and read with unaligned loads, as
///   RawDoFmt reads them: 32 bits for `d u x c`, 64 with `l`, a usize
///   with `z`, a pointer for `s`. Null reads 0 and null for each.
/// - `put_char_func` - called through utility's CallHookPkt with the
///   locale as the object and each byte as the message, then with 0.
///
/// RESULT:
/// The data stream past the last value the template uses; null when it
/// was null.
///
/// BEHAVIOR:
/// Each conversion takes the next value unless it names one by its place
/// (`%2$s`): a translation can put the values of a sentence in another
/// order and still be handed the same stream. The values are where their
/// sizes put them, so a template that names its values by place must use
/// each value up to the last it names, and each with one size.
///
/// `%D` and `%U` write a signed and an unsigned number with the locale's
/// group separator between groups of digits (`1.234.567`); `%d` and `%u`
/// do not group. `%x` and `%X` write capitals. A width and a limit count
/// characters. With zero fill the sign comes before the zeros; a null
/// `%s` writes nothing, padding included. Any other character after a
/// `%` is written as it is, so `%%` is one `%`.
///
/// CONTEXT:
/// - Waits: no, but the hook may.
/// - Interrupts: no; the hook is called through utility.library.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// A template uses 32 values at most; a conversion that names one past
/// them is written as its text. sdk.exec's `fmtStream` packs the values,
/// and sdk.locale's `BufferHook` takes the text.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FormatDate`, exec.library `RawDoFmt`, `GetCatalogStr`
///
/// EXAMPLES:
/// ```zig
/// var text: [80]u8 = undefined;
/// var out = locale.BufferHook.init(&text);
/// const stream = exec.fmtStream(.{ name, size });
/// _ = lb.FormatString(loc, "%2$D bytes in %1$s", &stream, &out.hook);
/// ```
pub fn FormatString(lb: *LocaleBase, loc: *const locale.Locale, template: [*:0]const u8, data_stream: ?*const anyopaque, put_char_func: *utility.Hook) ?*const anyopaque {
    const out = Out{ .lb = lb, .loc = loc, .hook = put_char_func };
    const data: ?[*]const u8 = @ptrCast(data_stream);

    // Each value's size, then where it starts.
    var sizes: [max_values]u8 = @splat(0);
    var at: usize = 0;
    var sequence: usize = 0;
    while (template[at] != 0) : (at += 1) {
        if (template[at] != '%') continue;
        const spec = Spec.read(template, at + 1);
        at = spec.end - 1;
        if (!spec.takes) continue;
        const index = spec.index orelse sequence;
        sequence += 1;
        if (index < max_values) sizes[index] = spec.size;
    }
    var offsets: [max_values]usize = undefined;
    var total: usize = 0;
    for (sizes, &offsets) |size, *offset| {
        offset.* = total;
        total += size;
    }

    at = 0;
    sequence = 0;
    while (template[at] != 0) {
        if (template[at] != '%') {
            out.put(template[at]);
            at += 1;
            continue;
        }
        const spec = Spec.read(template, at + 1);
        if (!spec.takes) {
            if (spec.conversion != 0) out.put(spec.conversion);
            at = spec.end;
            continue;
        }
        const index = spec.index orelse sequence;
        sequence += 1;
        if (index >= max_values) {
            out.text(template[at..spec.end]);
            at = spec.end;
            continue;
        }
        writeValue(&out, &spec, if (data) |from| from + offsets[index] else null);
        at = spec.end;
    }
    out.put(0);
    return if (data) |from| from + total else null;
}

/// One conversion of a template, from the character after its `%`.
const Spec = struct {
    /// The value it names by place, from 0; null for the next.
    index: ?usize = null,
    left: bool = false,
    zero: bool = false,
    width: usize = 0,
    /// The most characters written; 0 for no limit.
    limit: usize = 0,
    /// The bytes its value takes in the stream.
    size: u8 = 4,
    conversion: u8 = 0,
    /// Whether it takes a value.
    takes: bool = false,
    /// Just past it.
    end: usize = 0,

    fn read(template: [*:0]const u8, from: usize) Spec {
        var spec: Spec = .{};
        var at = from;
        // A number and a `$` name a value; a number without is the width.
        const place_start = at;
        const place = digits(template, &at);
        if (template[at] == '$' and at > place_start and place > 0) {
            spec.index = place - 1;
            at += 1;
        } else {
            at = place_start;
        }
        if (template[at] == '-') {
            spec.left = true;
            at += 1;
        }
        spec.zero = template[at] == '0';
        spec.width = digits(template, &at);
        if (template[at] == '.') {
            at += 1;
            spec.limit = digits(template, &at);
        }
        var long = false;
        if (template[at] == 'l') {
            long = true;
            at += 1;
        } else if (template[at] == 'z') {
            long = @sizeOf(usize) == 8;
            at += 1;
        }
        spec.conversion = template[at];
        if (spec.conversion == 0) {
            spec.end = at;
            return spec;
        }
        spec.end = at + 1;
        switch (spec.conversion) {
            'd', 'D', 'u', 'U', 'x', 'X', 'c' => {
                spec.takes = true;
                spec.size = if (long) 8 else 4;
            },
            's' => {
                spec.takes = true;
                spec.size = @sizeOf(usize);
            },
            else => {},
        }
        return spec;
    }
};

fn digits(template: [*:0]const u8, at: *usize) usize {
    var value: usize = 0;
    while (template[at.*] >= '0' and template[at.*] <= '9') : (at.* += 1) {
        value = value *| 10 +| (template[at.*] - '0');
    }
    return value;
}

/// The value at `from`, of the size the conversion gives it; 0 without
/// a stream.
fn load(comptime T: type, from: ?[*]const u8) T {
    const at = from orelse return 0;
    return @as(*align(1) const T, @ptrCast(at)).*;
}

fn writeValue(out: *const Out, spec: *const Spec, from: ?[*]const u8) void {
    const loc = out.loc;
    const long = spec.size == 8;
    var buffer: [80]u8 = undefined;
    var text: []const u8 = switch (spec.conversion) {
        'd', 'D' => signed: {
            const value: i64 = if (long) load(i64, from) else load(i32, from);
            const magnitude = _format.decimal(buffer[1..32], @abs(value), 1);
            const number = if (spec.conversion == 'D') grouped(loc, buffer[32..], magnitude) else magnitude;
            if (value >= 0) break :signed number;
            // Both leave the byte before the digits free for the sign.
            const start = @intFromPtr(number.ptr) - @intFromPtr(&buffer);
            buffer[start - 1] = '-';
            break :signed buffer[start - 1 .. start + number.len];
        },
        'u', 'U' => unsigned: {
            const value: u64 = if (long) load(u64, from) else load(u32, from);
            const number = _format.decimal(buffer[1..32], value, 1);
            break :unsigned if (spec.conversion == 'U') grouped(loc, buffer[32..], number) else number;
        },
        'x', 'X' => _format.hexadecimal(buffer[0..32], if (long) load(u64, from) else load(u32, from)),
        'c' => char: {
            buffer[0] = @truncate(if (long) load(u64, from) else load(u32, from));
            break :char buffer[0..1];
        },
        's' => string: {
            const pointer: ?[*:0]const u8 = @ptrFromInt(load(usize, from));
            const string = pointer orelse return;
            break :string string[0.._format.length(string)];
        },
        else => unreachable,
    };
    if (spec.limit != 0) text = _format.cut(loc, text, spec.limit);
    const pad = spec.width -| _format.width(loc, text);
    if (spec.left) {
        out.text(text);
        out.repeat(' ', pad);
        return;
    }
    const numeric = spec.conversion != 's' and spec.conversion != 'c';
    if (spec.zero and numeric and text.len != 0 and text[0] == '-') {
        out.put('-');
        text = text[1..];
    }
    out.repeat(if (spec.zero) '0' else ' ', pad);
    out.text(text);
}

/// `number`'s digits with the locale's group separator between the
/// groups its grouping counts from the right, into the end of `into`,
/// with a byte left free before them for a sign.
fn grouped(loc: *const locale.Locale, into: []u8, number: []const u8) []const u8 {
    const separator = loc.group_separator[0.._format.length(loc.group_separator)];
    var at = into.len;
    var group: usize = 0;
    var size: u8 = loc.grouping[0];
    var in_group: usize = 0;
    var digit = number.len;
    while (digit > 0) {
        if (size != 0 and size != locale.GROUPING_NONE and in_group == size) {
            if (at < separator.len + 2) break;
            at -= separator.len;
            @memcpy(into[at..][0..separator.len], separator);
            in_group = 0;
            const following = loc.grouping[group + 1];
            if (following != 0) {
                group += 1;
                size = following;
            }
        }
        if (at < 2) break;
        digit -= 1;
        at -= 1;
        into[at] = number[digit];
        in_group += 1;
    }
    return into[at..];
}
