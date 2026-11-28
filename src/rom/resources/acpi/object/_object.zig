// SPDX-License-Identifier: MPL-2.0
//! What a name in the namespace holds: an object - an integer, a string,
//! a buffer, a package, a method, a device, a region of an address space
//! and the fields in it, a mutex - each counted by how many hold it.
//!
//! **Kinds.** An object's kind is the number the bytecode's ObjectType
//! answers for it (`Kind`, 0 to 16), and two of the interpreter's own
//! above them: a name a package holds that is looked up only when it is
//! read (`name`), and another name for a node (`alias`). A field unit
//! says itself which of the three declarations made it, a region's, a
//! bank's or an index's.
//!
//! **What is kept, and where.** A string's and a buffer's bytes are the
//! object's own, copied out of the table: the bytecode may change them,
//! and the table stays as the firmware wrote it. A method keeps its body
//! where it is, in the table, which stays in memory as long as the system
//! runs: it is read only when the method runs. What the bytecode leaves
//! to be worked out later - a region whose address is an expression, a
//! field of a buffer declared outside any method - keeps the bytes of
//! those expressions (`Deferred`) for the step that evaluates them.
//!
//! **Counting.** `make` hands out an object held once; whoever else keeps
//! it calls `retain`, and everyone lets go with `release`, which frees
//! the object, and what it holds, once nobody does.

const machine = @import("../machine/_machine.zig");
const AcpiBase = @import("../acpi_base.zig").AcpiBase;
const Node = @import("../namespace/_namespace.zig").Node;

/// An object's kind: the bytecode's ObjectType numbers, then the
/// interpreter's own.
pub const Kind = enum(u8) {
    uninitialized = 0,
    integer = 1,
    string = 2,
    buffer = 3,
    package = 4,
    field_unit = 5,
    device = 6,
    event = 7,
    method = 8,
    mutex = 9,
    region = 10,
    power_resource = 11,
    processor = 12,
    thermal_zone = 13,
    buffer_field = 14,
    debug = 16,
    /// A package's element that names an object, looked up when it is read.
    name = 0x80,
    /// Another name for a node (Alias).
    alias = 0x81,
};

/// An object, and how many hold it.
pub const Object = struct {
    references: u32 = 1,
    value: Value,

    pub fn kind(object: *const Object) Kind {
        return object.value;
    }
};

pub const Value = union(Kind) {
    uninitialized: void,
    integer: u64,
    string: Bytes,
    buffer: Bytes,
    package: Package,
    field_unit: Field,
    device: void,
    event: void,
    method: Method,
    mutex: Mutex,
    region: Region,
    power_resource: PowerResource,
    processor: Processor,
    thermal_zone: void,
    buffer_field: Deferred,
    debug: void,
    name: NameRef,
    alias: *Node,
};

/// A string's or a buffer's bytes, the object's own: `length` of them,
/// and a NUL after them that `length` does not count.
pub const Bytes = struct {
    bytes: [*]u8,
    length: u32,

    pub fn slice(bytes: Bytes) []u8 {
        return bytes.bytes[0..bytes.length];
    }
};

/// A package's elements: each an object, or null where the package was
/// declared longer than the elements it was given.
pub const Package = struct {
    elements: [*]?*Object,
    count: u32,
};

/// A method's flags byte: how many arguments it takes, whether only one
/// task at a time may run it, and the level of the mutexes it may take.
pub const METHOD_ARGS: u8 = 0x07;
pub const METHOD_SERIALIZED: u8 = 0x08;
pub const METHOD_SYNC_SHIFT = 4;

/// A method: its body where the table has it, and its flags. A method
/// the interpreter answers itself (`\_OSI`) has no body.
pub const Method = struct {
    code: ?[*]const u8 = null,
    length: u32 = 0,
    flags: u8 = 0,
    builtin: Builtin = .none,

    pub fn args(method: Method) u8 {
        return method.flags & METHOD_ARGS;
    }
};

/// The methods the interpreter answers itself.
pub const Builtin = enum(u8) { none, osi };

/// A mutex, and the level a task must not hold a higher one than to take
/// it.
pub const Mutex = struct {
    sync_level: u8 = 0,
};

/// A region of an address space: which space (`SPACE_*` of
/// sdk.hardware.acpi, as a register's), where it starts and how long it
/// is - or, where the bytecode gives either as an expression, those
/// expressions to evaluate (`deferred`), and the two numbers 0 until
/// then. A region over a table in memory (DataTableRegion) has its three
/// strings deferred, and `table` set.
pub const Region = struct {
    space: u8 = 0,
    offset: u64 = 0,
    length: u64 = 0,
    deferred: ?Deferred = null,
    table: bool = false,
};

/// Which declaration made a field unit.
pub const FieldKind = enum(u8) {
    /// Field: bits of a region.
    region,
    /// BankField: bits of a region, reached after a bank register is set.
    bank,
    /// IndexField: bits reached through an index register and a data one.
    index,
};

/// The flags byte of a field declaration: how wide each access is
/// (`FIELD_ACCESS`: any, byte, word, dword, qword, buffer), whether the
/// firmware's global lock is taken around it, and what is written to the
/// bits of an access unit the field does not cover.
pub const FIELD_ACCESS: u8 = 0x0F;
pub const FIELD_LOCK: u8 = 0x10;
pub const FIELD_UPDATE_SHIFT = 5;
pub const FIELD_UPDATE: u8 = 0x60;

/// The access types of a field's flags.
pub const ACCESS_ANY: u8 = 0;
pub const ACCESS_BYTE: u8 = 1;
pub const ACCESS_WORD: u8 = 2;
pub const ACCESS_DWORD: u8 = 3;
pub const ACCESS_QWORD: u8 = 4;
pub const ACCESS_BUFFER: u8 = 5;

/// A field unit: its bits within what it is a field of, and how they are
/// reached. `container` is the region (a Field's and a BankField's) or
/// the index register (an IndexField's); `second` the bank register or
/// the data register. A BankField's bank value is `bank_value`, or its
/// expression where it is one. `attributes`, `attribute_kind` (the top
/// two bits of the access type: none, bytes, raw bytes, raw process
/// bytes) and `access_length` are the last AccessAs before the field;
/// `connection` the last Connection, a resource buffer or the name of
/// one.
pub const Field = struct {
    kind: FieldKind = .region,
    container: *Node,
    second: ?*Node = null,
    bank_value: u64 = 0,
    bank_deferred: ?Deferred = null,
    bit_offset: u32 = 0,
    bit_length: u32 = 0,
    flags: u8 = 0,
    attributes: u8 = 0,
    attribute_kind: u8 = 0,
    access_length: u8 = 0,
    connection: ?*Object = null,

    pub fn access(field: Field) u8 {
        return field.flags & FIELD_ACCESS;
    }
};

/// A processor declared with the old Processor term: its number, and the
/// block of registers its idle states once were in.
pub const Processor = struct {
    id: u8 = 0,
    block_address: u32 = 0,
    block_length: u8 = 0,
};

/// A power resource: the deepest sleep state it can stay on in, and its
/// place among the others when they are turned on and off.
pub const PowerResource = struct {
    system_level: u8 = 0,
    resource_order: u16 = 0,
};

/// Bytecode kept to be evaluated later, in the scope it was met in: the
/// operands of a term whose result is wanted only when it is used. A
/// field of a buffer (CreateDWordField and its family) keeps its opcode
/// with them.
pub const Deferred = struct {
    scope: *Node,
    code: [*]const u8,
    length: u32,
    opcode: u16 = 0,
};

/// A name as the bytecode wrote it, and the scope it is looked up from.
pub const NameRef = struct {
    scope: *Node,
    path: [*]const u8,
    length: u8,
};

/// An object holding `value`, held once; null without memory.
pub fn make(ab: *AcpiBase, value: Value) ?*Object {
    const object = machine.alloc(ab, Object) orelse return null;
    object.* = .{ .value = value };
    return object;
}

/// An integer object, cut to the namespace's width.
pub fn makeInteger(ab: *AcpiBase, value: u64) ?*Object {
    return make(ab, .{ .integer = clip(ab, value) });
}

/// `value` as wide as the namespace's integers are.
pub fn clip(ab: *const AcpiBase, value: u64) u64 {
    return if (ab.integer_bits == 32) value & 0xFFFF_FFFF else value;
}

/// The bytes of a string or a buffer, `length` of them and a NUL past
/// them, cleared; null without memory.
pub fn makeBytes(ab: *AcpiBase, length: u32) ?Bytes {
    const bytes = machine.allocBytes(ab, @as(usize, length) + 1) orelse return null;
    @memset(bytes[0 .. @as(usize, length) + 1], 0);
    return .{ .bytes = bytes, .length = length };
}

/// A string object holding a copy of `text`; null without memory.
pub fn makeString(ab: *AcpiBase, text: []const u8) ?*Object {
    const bytes = makeBytes(ab, @intCast(text.len)) orelse return null;
    @memcpy(bytes.bytes[0..text.len], text);
    return make(ab, .{ .string = bytes }) orelse {
        freeBytes(ab, bytes);
        return null;
    };
}

/// A package of `count` elements, every one null; null without memory.
pub fn makePackage(ab: *AcpiBase, count: u32) ?*Object {
    const elements = machine.allocArray(ab, ?*Object, count) orelse return null;
    for (elements[0..count]) |*element| element.* = null;
    return make(ab, .{ .package = .{ .elements = elements, .count = count } }) orelse {
        machine.freeArray(ab, ?*Object, elements, count);
        return null;
    };
}

/// One more holder of `object`.
pub fn retain(object: *Object) *Object {
    object.references += 1;
    return object;
}

/// One holder fewer: the object, and what only it held, freed when it was
/// the last. Null is ignored.
pub fn release(ab: *AcpiBase, maybe: ?*Object) void {
    const object = maybe orelse return;
    object.references -= 1;
    if (object.references != 0) return;
    switch (object.value) {
        .string, .buffer => |bytes| freeBytes(ab, bytes),
        .package => |package| {
            for (package.elements[0..package.count]) |element| release(ab, element);
            machine.freeArray(ab, ?*Object, package.elements, package.count);
        },
        .field_unit => |field| release(ab, field.connection),
        else => {},
    }
    machine.free(ab, Object, object);
}

/// A string's or a buffer's bytes from `makeBytes` given back.
pub fn freeBytes(ab: *AcpiBase, bytes: Bytes) void {
    machine.freeBytes(ab, bytes.bytes, @as(usize, bytes.length) + 1);
}

/// The text of a compressed EISA identity (`EisaId ("PNP0C0C")` in the
/// source is the integer 0x0C0CD041): three letters of five bits each and
/// four hexadecimal digits, the integer's bytes in their written order.
/// False where `value` is not one - wider than 32 bits, or a letter out
/// of range.
pub fn eisaText(value: u64, into: *[8]u8) bool {
    if (value > 0xFFFF_FFFF) return false;
    const low: u32 = @intCast(value);
    const id = @byteSwap(low);
    if (id & 0x8000_0000 != 0) return false;
    const letters = [3]u32{ id >> 26 & 0x1F, id >> 21 & 0x1F, id >> 16 & 0x1F };
    for (letters, 0..) |letter, index| {
        if (letter < 1 or letter > 26) return false;
        into[index] = @intCast('@' + letter);
    }
    const digits = "0123456789ABCDEF";
    var shift: u5 = 12;
    var index: usize = 3;
    while (index < 7) : (index += 1) {
        into[index] = digits[id >> shift & 0xF];
        shift -%= 4;
    }
    into[7] = 0;
    return true;
}

// --- tests ------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "an EISA identity is read back as its text" {
    var text: [8]u8 = undefined;
    try testing.expect(eisaText(0x0C0CD041, &text));
    try testing.expectEqualStrings("PNP0C0C", text[0..7]);
    try testing.expect(eisaText(0x080AD041, &text));
    try testing.expectEqualStrings("PNP0A08", text[0..7]);
    try testing.expect(eisaText(0x030AD041, &text));
    try testing.expectEqualStrings("PNP0A03", text[0..7]);
    try testing.expect(!eisaText(0x1_0000_0000, &text));
    try testing.expect(!eisaText(0, &text));
}
