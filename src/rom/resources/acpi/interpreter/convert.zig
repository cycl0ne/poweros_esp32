// SPDX-License-Identifier: MPL-2.0
//! The conversions between the bytecode's data: integers, strings and
//! buffers, as an operand wants one, as a store writes one over another,
//! and as the explicit operators make one.
//!
//! **An operand wanted as an integer** is an integer as it is; a buffer's
//! first bytes, as many as an integer has, the first the lowest; a
//! string's leading hexadecimal digits - after any spaces, a "0x" and the
//! zeros that lead -, up to as many as an integer holds. Anything else is
//! of the wrong kind.
//!
//! **What an object's bytes are** (`storage`): an integer's, as many as
//! the namespace's integers have, the lowest first; a string's
//! characters, without the NUL that ends them; a buffer's bytes. A store
//! into a name that holds one of the three copies the source's bytes
//! over the name's, the rest of them cleared, and the name keeps its
//! kind and its length.
//!
//! **The explicit ones.** ToInteger reads a string as a number in the C
//! way - decimal, hexadecimal after "0x", octal after a 0 - and a buffer
//! as an integer's bytes. ToBuffer makes an integer its bytes and a
//! string its characters and the NUL. ToHexString writes an integer as
//! "0x" and its digits, and a buffer as each byte's "0x" and two digits,
//! separated by commas; ToDecimalString the same in decimal, without the
//! "0x". ToString takes a buffer's bytes up to a NUL or the length asked
//! for, and Mid a part of a string or a buffer - an integer, and for
//! ToString a string, taken as ToBuffer makes it one. A string given to
//! either of the two string conversions is the string. Concatenate joins two buffers, or two strings - an integer
//! after a string written in hexadecimal, a buffer as ToHexString writes
//! one - or two integers' bytes into a buffer.
//!
//! **A copy** (`copy`) is the object's own: a string's or a buffer's
//! bytes copied, a package's elements each copied in turn. An element of
//! a package that is a reference to a slot of another stays that same
//! reference, so that both see what is stored there later.

const object = @import("../object/_object.zig");
const Object = object.Object;
const interpreter = @import("_interpreter.zig");
const Run = interpreter.Run;
const Item = interpreter.Item;
const Error = interpreter.Error;
const AcpiBase = @import("../acpi_base.zig").AcpiBase;

/// How many bytes the namespace's integers have.
pub fn integerBytes(ab: *const AcpiBase) u32 {
    return ab.integer_bits / 8;
}

/// Every bit of an integer set, as wide as the namespace's are: true.
pub fn ones(ab: *const AcpiBase) u64 {
    return object.clip(ab, ~@as(u64, 0));
}

/// A truth as the bytecode writes it.
pub fn truth(ab: *const AcpiBase, value: bool) u64 {
    return if (value) ones(ab) else 0;
}

/// `item`, an operand, as an integer.
pub fn toInteger(run: *Run, item: Item) Error!u64 {
    return switch (item) {
        .integer => |value| object.clip(run.ab, value),
        .object => |held| integerOf(run.ab, held),
        .none => error.Uninitialized,
        else => error.Type,
    };
}

/// The integer `held` is, as an operand wants it.
pub fn integerOf(ab: *const AcpiBase, held: *const Object) Error!u64 {
    return switch (held.value) {
        .integer => |value| object.clip(ab, value),
        .buffer => |bytes| bytesInteger(ab, bytes.slice()),
        .string => |text| hexInteger(ab, text.slice()),
        .uninitialized => error.Uninitialized,
        else => error.Type,
    };
}

/// A buffer's first bytes, as many as an integer has, as one: the first
/// the lowest; what the buffer lacks is 0.
pub fn bytesInteger(ab: *const AcpiBase, bytes: []const u8) u64 {
    const count = @min(bytes.len, integerBytes(ab));
    var value: u64 = 0;
    for (bytes[0..count], 0..) |byte, index| value |= @as(u64, byte) << @intCast(index * 8);
    return value;
}

/// A string's leading hexadecimal digits, as many as an integer holds, as
/// an integer: what an operand makes of a string. Spaces before them, a
/// "0x" and zeros that lead are stepped over.
pub fn hexInteger(ab: *const AcpiBase, text: []const u8) u64 {
    var at: usize = 0;
    while (at < text.len and isSpace(text[at])) at += 1;
    if (text.len - at >= 2 and text[at] == '0' and (text[at + 1] == 'x' or text[at + 1] == 'X')) at += 2;
    while (at < text.len and text[at] == '0') at += 1;
    var value: u64 = 0;
    var digits: u32 = 0;
    for (text[at..]) |char| {
        const digit = hexDigit(char) orelse break;
        if (digits == integerBytes(ab) * 2) break;
        value = value << 4 | digit;
        digits += 1;
    }
    return value;
}

fn isSpace(char: u8) bool {
    return char == ' ' or (char >= 0x09 and char <= 0x0D);
}

fn hexDigit(char: u8) ?u64 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

/// A string as ToInteger reads it: spaces skipped, a sign, then decimal,
/// hexadecimal after "0x" or octal after a 0, up to the first character
/// that is no digit of its base. A number too big for 64 bits is every
/// bit set.
pub fn cInteger(text: []const u8) u64 {
    var at: usize = 0;
    while (at < text.len and isSpace(text[at])) at += 1;
    var negative = false;
    if (at < text.len and (text[at] == '-' or text[at] == '+')) {
        negative = text[at] == '-';
        at += 1;
    }
    var base: u64 = 10;
    if (at < text.len and text[at] == '0') {
        at += 1;
        base = 8;
        if (at < text.len and (text[at] == 'x' or text[at] == 'X')) {
            at += 1;
            base = 16;
        }
    }
    var value: u64 = 0;
    while (at < text.len) : (at += 1) {
        const digit = hexDigit(text[at]) orelse break;
        if (digit >= base) break;
        const shifted = @mulWithOverflow(value, base);
        const sum = @addWithOverflow(shifted[0], digit);
        if (shifted[1] != 0 or sum[1] != 0) {
            value = ~@as(u64, 0);
            break;
        }
        value = sum[0];
    }
    return if (negative) 0 -% value else value;
}

/// The bytes `held` holds, as a store copies them: an integer's in
/// `room`, a string's without its NUL, a buffer's.
pub fn storage(ab: *const AcpiBase, held: *const Object, room: *[8]u8) Error![]u8 {
    switch (held.value) {
        .integer => |value| {
            for (room, 0..) |*byte, index| byte.* = @truncate(value >> @intCast(index * 8));
            return room[0..integerBytes(ab)];
        },
        .string, .buffer => |bytes| return bytes.slice(),
        else => return error.Type,
    }
}

/// `source`'s bytes over `into`'s - an integer, a string or a buffer -
/// the rest of `into` cleared: `into` keeps its kind and its length.
pub fn castInto(ab: *AcpiBase, into: *Object, source: *const Object) Error!void {
    var source_room: [8]u8 = undefined;
    const from = try storage(ab, source, &source_room);
    switch (into.value) {
        .integer => |*value| {
            var room: [8]u8 = @splat(0);
            const count = @min(from.len, integerBytes(ab));
            @memcpy(room[0..count], from[0..count]);
            value.* = object.clip(ab, bytesInteger(ab, &room));
        },
        .string, .buffer => |bytes| {
            const to = bytes.slice();
            const count = @min(from.len, to.len);
            // The two may be the same bytes: copy forward or not at all.
            if (to.ptr != from.ptr) @memmove(to[0..count], from[0..count]);
            @memset(to[count..], 0);
        },
        else => return error.Type,
    }
}

// --- copies ---------------------------------------------------------------------------

/// A copy of `held`, the copy's own (see the file's header).
pub fn copy(run: *Run, held: *Object) Error!*Object {
    const ab = run.ab;
    switch (held.value) {
        .string, .buffer => |bytes| {
            const copied = object.makeBytes(ab, bytes.length) orelse return error.NoMemory;
            @memcpy(copied.slice(), bytes.slice());
            const value: object.Value = if (held.value == .string) .{ .string = copied } else .{ .buffer = copied };
            return object.make(ab, value) orelse {
                object.freeBytes(ab, copied);
                return error.NoMemory;
            };
        },
        .package => |package| {
            const made = object.makePackage(ab, package.count) orelse return error.NoMemory;
            errdefer object.release(ab, made);
            for (package.elements[0..package.count], 0..) |element, index| {
                const inside = element orelse continue;
                made.value.package.elements[index] = if (isSlotReference(inside)) object.retain(inside) else try copy(run, inside);
            }
            return made;
        },
        .reference => |reference| {
            const value: object.Value = .{ .reference = switch (reference) {
                .node => |node| .{ .node = @import("../namespace/_namespace.zig").hold(node) },
                .object => |inner| .{ .object = object.retain(inner) },
                .element => |element| .{ .element = .{ .container = object.retain(element.container), .index = element.index } },
                .byte => |element| .{ .byte = .{ .container = object.retain(element.container), .index = element.index } },
            } };
            return object.make(ab, value) orelse {
                const made: Object = .{ .value = value };
                releaseValue(ab, made.value);
                return error.NoMemory;
            };
        },
        .name => |name| {
            const made = object.make(ab, held.value) orelse return error.NoMemory;
            _ = @import("../namespace/_namespace.zig").hold(name.scope);
            return made;
        },
        .integer, .uninitialized, .debug => return object.make(ab, held.value) orelse error.NoMemory,
        // Kinds a name alone holds - a device, a mutex, a method, a field
        // - are not copied: the copy is the object itself.
        else => return object.retain(held),
    }
}

/// What a value that was never made into an object holds let go of.
fn releaseValue(ab: *AcpiBase, value: object.Value) void {
    switch (value) {
        .reference => |reference| switch (reference) {
            .node => |node| @import("../namespace/_namespace.zig").unhold(ab, node),
            .object => |inner| object.release(ab, inner),
            .element, .byte => |element| object.release(ab, element.container),
        },
        else => {},
    }
}

/// Whether `held` is a reference to a slot of a package (Index).
pub fn isSlotReference(held: *const Object) bool {
    return switch (held.value) {
        .reference => |reference| reference == .element,
        else => false,
    };
}

// --- the explicit conversions -----------------------------------------------------------

/// A string object of `text`.
fn stringOf(run: *Run, text: []const u8) Error!*Object {
    return object.makeString(run.ab, text) orelse error.NoMemory;
}

/// A buffer object of a copy of `bytes`.
pub fn bufferOfBytes(run: *Run, bytes: []const u8) Error!*Object {
    const made = object.makeBytes(run.ab, @intCast(bytes.len)) orelse return error.NoMemory;
    @memcpy(made.slice(), bytes);
    return object.make(run.ab, .{ .buffer = made }) orelse {
        object.freeBytes(run.ab, made);
        return error.NoMemory;
    };
}

/// The computational data `item` is - an integer, a string or a buffer -
/// as an object, held; an integer made one.
pub fn dataOf(run: *Run, item: Item) Error!*Object {
    const held = switch (item) {
        .integer => |value| return object.makeInteger(run.ab, value) orelse error.NoMemory,
        .object => |held| held,
        .none => return error.Uninitialized,
        else => return error.Type,
    };
    return switch (held.value) {
        .integer, .string, .buffer => object.retain(held),
        .uninitialized => error.Uninitialized,
        else => error.Type,
    };
}

/// ToInteger.
pub fn explicitInteger(run: *Run, item: Item) Error!u64 {
    const held = try dataOf(run, item);
    defer object.release(run.ab, held);
    return switch (held.value) {
        .integer => |value| value,
        .buffer => |bytes| bytesInteger(run.ab, bytes.slice()),
        .string => |text| object.clip(run.ab, cInteger(text.slice())),
        else => unreachable,
    };
}

/// ToBuffer.
pub fn toBuffer(run: *Run, item: Item) Error!*Object {
    const held = try dataOf(run, item);
    defer object.release(run.ab, held);
    var room: [8]u8 = undefined;
    return switch (held.value) {
        .string => |text| bufferOfBytes(run, text.bytes[0 .. text.length + 1]),
        else => bufferOfBytes(run, try storage(run.ab, held, &room)),
    };
}

/// The most characters an integer's text has: 20 decimal digits, or
/// "0x" and 16 hexadecimal ones.
const INTEGER_TEXT = 20;

/// `value` written in `base`, 10 or 16, into `into`: its digits, without
/// leading zeros.
fn digitsOf(value: u64, base: u64, into: *[INTEGER_TEXT]u8) []const u8 {
    const digits = "0123456789ABCDEF";
    var at: usize = into.len;
    var left = value;
    while (true) {
        at -= 1;
        into[at] = digits[@intCast(left % base)];
        left /= base;
        if (left == 0) break;
    }
    return into[at..];
}

/// ToHexString (`hex`) and ToDecimalString.
pub fn toText(run: *Run, item: Item, hex: bool) Error!*Object {
    const held = try dataOf(run, item);
    defer object.release(run.ab, held);
    var room: [INTEGER_TEXT]u8 = undefined;
    switch (held.value) {
        .integer => |value| {
            const digits = digitsOf(value, if (hex) 16 else 10, &room);
            if (!hex) return stringOf(run, digits);
            var text: [INTEGER_TEXT + 2]u8 = undefined;
            text[0] = '0';
            text[1] = 'x';
            @memcpy(text[2 .. 2 + digits.len], digits);
            return stringOf(run, text[0 .. 2 + digits.len]);
        },
        .buffer => |bytes| return bufferText(run, bytes.slice(), if (hex) .hex else .decimal),
        // A string is the string.
        .string => |text| return stringOf(run, text.slice()),
        else => unreachable,
    }
}

/// How a buffer's bytes are written as text.
pub const ByteText = enum { hex, decimal };

/// A buffer's bytes as text, each byte "0x" and two digits or its decimal
/// digits, separated by commas.
pub fn bufferText(run: *Run, bytes: []const u8, how: ByteText) Error!*Object {
    var length: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (index != 0) length += 1;
        length += switch (how) {
            .hex => 4,
            .decimal => if (byte >= 100) 3 else if (byte >= 10) 2 else 1,
        };
    }
    const made = object.makeBytes(run.ab, @intCast(length)) orelse return error.NoMemory;
    var at: usize = 0;
    var room: [INTEGER_TEXT]u8 = undefined;
    for (bytes, 0..) |byte, index| {
        if (index != 0) {
            made.bytes[at] = ',';
            at += 1;
        }
        switch (how) {
            .hex => {
                const digits = "0123456789ABCDEF";
                made.bytes[at] = '0';
                made.bytes[at + 1] = 'x';
                made.bytes[at + 2] = digits[byte >> 4];
                made.bytes[at + 3] = digits[byte & 0xF];
                at += 4;
            },
            .decimal => {
                const digits = digitsOf(byte, 10, &room);
                @memcpy(made.bytes[at .. at + digits.len], digits);
                at += digits.len;
            },
        }
    }
    return object.make(run.ab, .{ .string = made }) orelse {
        object.freeBytes(run.ab, made);
        return error.NoMemory;
    };
}

/// ToString: a buffer's bytes up to its first NUL, or `length` of them;
/// a string or an integer taken as ToBuffer makes it a buffer.
pub fn toString(run: *Run, item: Item, length: u64) Error!*Object {
    const held = try dataOf(run, item);
    defer object.release(run.ab, held);
    var room: [8]u8 = undefined;
    const bytes = try storage(run.ab, held, &room);
    var count: usize = @intCast(@min(length, bytes.len));
    for (bytes[0..count], 0..) |byte, index| {
        if (byte == 0) {
            count = index;
            break;
        }
    }
    return stringOf(run, bytes[0..count]);
}

/// Mid: `length` bytes of a string or a buffer from `index`, as many as
/// it has - a string or a buffer as the source is, an integer's bytes a
/// buffer.
pub fn mid(run: *Run, item: Item, index: u64, length: u64) Error!*Object {
    const held = try dataOf(run, item);
    defer object.release(run.ab, held);
    var room: [8]u8 = undefined;
    const bytes = try storage(run.ab, held, &room);
    const is_string = held.value == .string;
    const start: usize = @intCast(@min(index, bytes.len));
    const count: usize = @intCast(@min(length, bytes.len - start));
    const part = bytes[start .. start + count];
    return if (is_string) stringOf(run, part) else bufferOfBytes(run, part);
}

/// Concatenate's result.
pub fn concatenate(run: *Run, first_item: Item, second_item: Item) Error!*Object {
    const ab = run.ab;
    const first = try dataOf(run, first_item);
    defer object.release(ab, first);
    const second = try dataOf(run, second_item);
    defer object.release(ab, second);
    switch (first.value) {
        .integer => |value| {
            // Two integers' bytes; the second read as ToInteger reads it.
            const width = integerBytes(ab);
            const other = switch (second.value) {
                .integer => |integer| integer,
                .buffer => |bytes| bytesInteger(ab, bytes.slice()),
                .string => |text| object.clip(ab, cInteger(text.slice())),
                else => unreachable,
            };
            var room: [16]u8 = undefined;
            for (0..width) |index| {
                room[index] = @truncate(value >> @intCast(index * 8));
                room[width + index] = @truncate(other >> @intCast(index * 8));
            }
            return bufferOfBytes(run, room[0 .. 2 * width]);
        },
        .buffer => |bytes| {
            // A string after a buffer brings its NUL.
            var room: [8]u8 = undefined;
            const tail: []const u8 = switch (second.value) {
                .string => |text| text.bytes[0 .. text.length + 1],
                else => try storage(ab, second, &room),
            };
            return joined(run, bytes.slice(), tail, .buffer);
        },
        .string => |text| {
            switch (second.value) {
                .integer => |integer| {
                    var room: [INTEGER_TEXT]u8 = undefined;
                    const digits = digitsOf(integer, 16, &room);
                    var lower: [INTEGER_TEXT]u8 = undefined;
                    for (digits, 0..) |char, index| lower[index] = if (char >= 'A') char + ('a' - 'A') else char;
                    return joined(run, text.slice(), lower[0..digits.len], .string);
                },
                .string => |tail| return joined(run, text.slice(), tail.slice(), .string),
                .buffer => |bytes| {
                    const written = try bufferText(run, bytes.slice(), .hex);
                    defer object.release(ab, written);
                    return joined(run, text.slice(), written.value.string.slice(), .string);
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

/// `head` then `tail`, a string or a buffer as `kind` says.
fn joined(run: *Run, head: []const u8, tail: []const u8, kind: object.Kind) Error!*Object {
    const length = head.len + tail.len;
    if (length > MOST_BYTES) return error.Range;
    const made = object.makeBytes(run.ab, @intCast(length)) orelse return error.NoMemory;
    @memcpy(made.bytes[0..head.len], head);
    @memcpy(made.bytes[head.len..length], tail);
    const value: object.Value = if (kind == .string) .{ .string = made } else .{ .buffer = made };
    return object.make(run.ab, value) orelse {
        object.freeBytes(run.ab, made);
        return error.NoMemory;
    };
}

/// The most bytes a string or a buffer the interpreter makes may have.
pub const MOST_BYTES = 1 << 20;

/// The end of a resource template's descriptors: where its end tag is,
/// or its length where it has none.
fn templateEnd(bytes: []const u8) usize {
    var at: usize = 0;
    while (at < bytes.len) {
        const tag = bytes[at];
        if (tag & 0x80 == 0) {
            if (tag >> 3 == 0x0F) return at; // the end tag
            at += 1 + (tag & 0x07);
        } else {
            if (at + 3 > bytes.len) break;
            at += 3 + (@as(usize, bytes[at + 1]) | @as(usize, bytes[at + 2]) << 8);
        }
    }
    return bytes.len;
}

/// ConcatenateResTemplate: the descriptors of two resource templates,
/// and an end tag after them.
pub fn concatenateTemplates(run: *Run, first_item: Item, second_item: Item) Error!*Object {
    const first = try bufferBytes(first_item);
    const second = try bufferBytes(second_item);
    const head = first[0..templateEnd(first)];
    const tail = second[0..templateEnd(second)];
    const length = head.len + tail.len + 2;
    if (length > MOST_BYTES) return error.Range;
    const made = object.makeBytes(run.ab, @intCast(length)) orelse return error.NoMemory;
    @memcpy(made.bytes[0..head.len], head);
    @memcpy(made.bytes[head.len .. head.len + tail.len], tail);
    made.bytes[length - 2] = 0x79; // the end tag, its checksum 0
    made.bytes[length - 1] = 0;
    return object.make(run.ab, .{ .buffer = made }) orelse {
        object.freeBytes(run.ab, made);
        return error.NoMemory;
    };
}

/// A buffer operand's bytes.
pub fn bufferBytes(item: Item) Error![]u8 {
    const held = switch (item) {
        .object => |held| held,
        else => return error.Type,
    };
    return switch (held.value) {
        .buffer => |bytes| bytes.slice(),
        else => error.Type,
    };
}

// --- tests ------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "a string as an operand is its leading hexadecimal digits, and as ToInteger reads it a C number" {
    var ab: AcpiBase = .{ .lib = undefined, .sys_base = undefined, .machine = undefined };
    try testing.expectEqual(@as(u64, 0x12AB), hexInteger(&ab, "12abz9"));
    try testing.expectEqual(@as(u64, 0x12), hexInteger(&ab, " 0x12"));
    try testing.expectEqual(@as(u64, 0x1234_5678_9ABC_DEF0), hexInteger(&ab, "123456789ABCDEF0FF"));
    try testing.expectEqual(@as(u64, 0x1234_5678_9ABC_DEF0), hexInteger(&ab, "000123456789ABCDEF0FF"));
    try testing.expectEqual(@as(u64, 0x1F), cInteger("0X1f"));
    ab.integer_bits = 32;
    try testing.expectEqual(@as(u64, 0x1234_5678), hexInteger(&ab, "123456789"));
    try testing.expectEqual(@as(u64, 123), cInteger("  123x"));
    try testing.expectEqual(@as(u64, 0x1F), cInteger("0x1f"));
    try testing.expectEqual(@as(u64, 8), cInteger("010"));
    try testing.expectEqual(@as(u64, 0) -% 5, cInteger("-5"));
    try testing.expectEqual(~@as(u64, 0), cInteger("99999999999999999999999"));
}

test "a buffer as an operand is its first bytes, the first the lowest" {
    var ab: AcpiBase = .{ .lib = undefined, .sys_base = undefined, .machine = undefined };
    try testing.expectEqual(@as(u64, 0x0302_01), bytesInteger(&ab, &.{ 1, 2, 3 }));
    try testing.expectEqual(@as(u64, 0x0807_0605_0403_0201), bytesInteger(&ab, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }));
    ab.integer_bits = 32;
    try testing.expectEqual(@as(u64, 0x0403_0201), bytesInteger(&ab, &.{ 1, 2, 3, 4, 5 }));
}

test "templates joined end at the first one's end tag and get one of their own" {
    try testing.expectEqual(@as(usize, 3), templateEnd(&.{ 0x22, 0x01, 0x00, 0x79, 0x00 }));
    try testing.expectEqual(@as(usize, 12), templateEnd(&.{ 0x86, 0x09, 0x00, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0x79, 0 }));
    try testing.expectEqual(@as(usize, 2), templateEnd(&.{ 0x22, 0x01 }));
}
