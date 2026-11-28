// SPDX-License-Identifier: MPL-2.0
//! Reading what a name, a local or a reference holds, and storing into
//! them: the rules of Store and CopyObject, RefOf and DerefOf.
//!
//! **Reading a name** gives its object - an integer, a string, a buffer,
//! a package - shared with the name, not a copy: whatever keeps it copies
//! it. A field is read, through its region, a field of a buffer from its
//! buffer: an integer where its bits fit one, a buffer where they do not
//! - or always, for one CreateField made. A name that holds a reference
//! reads what the reference refers to. A device, a mutex, a region and
//! the other kinds only a name holds read as a reference to the name.
//!
//! **A reference** (RefOf, Index) refers to a name, to the object a local
//! or an argument held, to a slot of a package or to a byte of a buffer
//! or a string. Followed (`endOf`), it ends at the first of these that
//! holds no reference itself: DerefOf follows every reference to its end.
//!
//! **Store** into
//! - a local: replaces it with a copy of the value, but where the local
//!   holds a reference, the value is stored into what that refers to, as
//!   into a name;
//! - an argument: the same, but where it holds a reference, what that
//!   refers to is replaced - an error where that is a device, a mutex or
//!   another kind only a name holds;
//! - a name: the value is cast into what the name holds - its bytes
//!   copied over an integer's, a string's or a buffer's, which keep
//!   their kind and their length (convert.zig);
//! - a slot of a package (Index): replaces the slot's object, but where
//!   the slot holds a reference, stores into what that refers to;
//! - a field, a field of a buffer or a byte of a buffer, however reached:
//!   written in place, never replaced - an integer whole, a string or a
//!   buffer as its last piece the size of the field (the field's bytes,
//!   or the one byte);
//! - Debug: the value said in the log.
//!
//! **CopyObject** replaces what it is given: a local, an argument, a
//! name, a slot - each with a copy of the value, of whatever kind -
//! where an argument or a name holds a reference, what that refers to;
//! a field, a field of a buffer and a byte are written as Store writes
//! them.
//!
//! **RefOf** of a local or an argument refers to the object it holds
//! when RefOf is done: a later store to the local replaces that object,
//! and the reference keeps the one it had.

const sdk = @import("sdk");
const exec = sdk.exec;
const machine = @import("../machine/_machine.zig");
const namespace = @import("../namespace/_namespace.zig");
const Node = namespace.Node;
const object = @import("../object/_object.zig");
const Object = object.Object;
const interpreter = @import("_interpreter.zig");
const Run = interpreter.Run;
const Frame = interpreter.Frame;
const Item = interpreter.Item;
const Place = interpreter.Place;
const Error = interpreter.Error;
const convert = @import("convert.zig");
const region = @import("../region/_region.zig");

/// The deepest references are followed through one another.
const MOST_REFERENCES = 64;

/// Where a reference, or a chain of them, ends.
pub const End = union(enum) {
    node: *Node,
    object: *Object,
    element: object.Element,
    byte: object.Element,
};

// --- reading -------------------------------------------------------------------------

/// What the name `node` is as an operand (see the file's header).
pub fn readNode(run: *Run, node: *Node) Error!Item {
    const at = namespace.target(node);
    const held = at.object orelse return referenceTo(run, at);
    return switch (held.value) {
        .integer, .string, .buffer, .package, .uninitialized => .{ .object = object.retain(held) },
        .field_unit => region.readField(run, at, held),
        .buffer_field => |field| readBufferField(run, field),
        .reference => endValue(run, try endOf(held)),
        .debug => .{ .place = .debug },
        else => referenceTo(run, at),
    };
}

/// A reference to `node`, as an operand.
fn referenceTo(run: *Run, node: *Node) Error!Item {
    const made = object.make(run.ab, .{ .reference = .{ .node = node } }) orelse return error.NoMemory;
    _ = namespace.hold(node);
    return .{ .object = made };
}

/// What `end` holds, as an operand.
pub fn endValue(run: *Run, end: End) Error!Item {
    switch (end) {
        .node => |node| return readNode(run, node),
        .object => |held| return valueOf(run, held),
        .element => |element| {
            const slot = try slotOf(element);
            const held = slot.* orelse return .{ .object = object.make(run.ab, .{ .uninitialized = {} }) orelse return error.NoMemory };
            return valueOf(run, held);
        },
        .byte => |element| return .{ .integer = (try bytesOf(element.container))[element.index] },
    }
}

/// `held`, an object a reference or a slot ends at, as an operand: a
/// field read, a name an element of a package kept looked up and read.
pub fn valueOf(run: *Run, held: *Object) Error!Item {
    return switch (held.value) {
        .buffer_field => |field| readBufferField(run, field),
        .name => |name| readNode(run, try nameOf(run, name)),
        .reference => endValue(run, try endOf(held)),
        // A field unit is reached only through its name.
        .field_unit => error.Type,
        else => .{ .object = object.retain(held) },
    };
}

/// The node a name an element of a package keeps stands for.
pub fn nameOf(run: *Run, name: object.NameRef) Error!*Node {
    var reader = @import("../aml/_aml.zig").Reader.of(name.path[0..name.length], 0);
    const path = reader.name() orelse return error.Broken;
    return namespace.find(run.ab, name.scope, path, .search) orelse interpreter.notFound(run, name.scope, path);
}

/// The slot of a package an element refers to.
pub fn slotOf(element: object.Element) Error!*?*Object {
    const package = switch (element.container.value) {
        .package => |package| package,
        else => return error.Type,
    };
    if (element.index >= package.count) return error.Range;
    return &package.elements[element.index];
}

/// The bytes of the string or the buffer a byte reference is in.
fn bytesOf(container: *Object) Error![]u8 {
    return switch (container.value) {
        .string, .buffer => |bytes| bytes.slice(),
        else => error.Type,
    };
}

/// Where the reference `start` ends: followed on through each reference
/// what it refers to holds.
pub fn endOf(start: *Object) Error!End {
    var held = start;
    var depth: u32 = 0;
    while (depth < MOST_REFERENCES) : (depth += 1) {
        const reference = switch (held.value) {
            .reference => |reference| reference,
            else => return .{ .object = held },
        };
        const end: End = switch (reference) {
            .node => |node| .{ .node = namespace.target(node) },
            .object => |inner| .{ .object = inner },
            .element => |element| .{ .element = element },
            .byte => |element| return .{ .byte = element },
        };
        const inner: ?*Object = switch (end) {
            .node => |node| node.object,
            .object => |inner| inner,
            .element => |element| (try slotOf(element)).*,
            .byte => unreachable,
        };
        const next = inner orelse return end;
        if (next.value != .reference) return end;
        held = next;
    }
    return error.Limit;
}

/// Where a place ends, for the operators that ask about what it holds -
/// Increment, SizeOf, ObjectType, the mutex and event operators.
pub fn placeEnd(frame: *Frame, place: Place) Error!End {
    return switch (place) {
        .node => |node| nodeEnd(node),
        .local => |index| slotEnd(frame.locals[index]),
        .arg => |index| slotEnd(frame.args[index]),
        .reference, .object => |held| endOf(held),
        .none, .debug, .missing => error.Type,
    };
}

fn nodeEnd(node: *Node) Error!End {
    const at = namespace.target(node);
    if (at.object) |held| {
        if (held.value == .reference) return endOf(held);
    }
    return .{ .node = at };
}

fn slotEnd(slot: ?*Object) Error!End {
    const held = slot orelse return error.Uninitialized;
    return endOf(held);
}

/// The object `end` holds; null where it holds none (a scope, an empty
/// slot) or is a byte.
pub fn endObject(end: End) Error!?*Object {
    return switch (end) {
        .node => |node| node.object,
        .object => |held| held,
        .element => |element| (try slotOf(element)).*,
        .byte => null,
    };
}

// --- storing -------------------------------------------------------------------------

/// Store: `value`, which stays the caller's, into `place`.
pub fn store(run: *Run, frame: *Frame, place: Place, value: *Object) Error!void {
    switch (place) {
        .none => {},
        .debug => debugOut(run, value),
        .local => |index| try storeSlot(run, &frame.locals[index], value, false),
        .arg => |index| try storeSlot(run, &frame.args[index], value, true),
        .node => |node| try storeName(run, node, value),
        .reference => |held| try storeReference(run, held, value),
        .object => |held| try castAt(run, .{ .object = held }, value),
        .missing => return error.NotFound,
    }
}

fn storeSlot(run: *Run, slot: *?*Object, value: *Object, is_arg: bool) Error!void {
    if (slot.*) |held| {
        if (held.value == .reference) {
            const end = try endOf(held);
            if (end == .byte) return writeByte(end.byte, value, run);
            var overwrite = is_arg;
            if (overwrite and try namespaceOnly(end)) return error.Type;
            if (try isUninitialized(end)) overwrite = true;
            if (try writtenInPlace(end)) overwrite = false;
            if (overwrite) return replaceAt(run, end, try copyForOverwrite(run, value));
            return castAt(run, end, value);
        }
    }
    try replaceSlot(run, slot, value);
}

/// `slot`, a local or an argument, holding a copy of `value`.
fn replaceSlot(run: *Run, slot: *?*Object, value: *Object) Error!void {
    const copied = try copyForOverwrite(run, value);
    object.release(run.ab, slot.*);
    slot.* = copied;
}

fn storeName(run: *Run, node: *Node, value: *Object) Error!void {
    const at = namespace.target(node);
    const held = at.object orelse return error.Type;
    if (held.value == .reference) return storeThrough(run, try endOf(held), value);
    return castAt(run, .{ .node = at }, value);
}

/// `value` stored into where a reference ends, as into a name.
fn storeThrough(run: *Run, end: End, value: *Object) Error!void {
    if (end != .byte and try isUninitialized(end)) return replaceAt(run, end, try copyForOverwrite(run, value));
    return castAt(run, end, value);
}

/// A store into what a term answered as a reference: a slot of a package
/// replaced unless it holds a reference, a byte written, a name's or an
/// object's reference stored through.
fn storeReference(run: *Run, held: *Object, value: *Object) Error!void {
    switch (held.value.reference) {
        .byte => |element| return writeByte(element, value, run),
        .element => |element| {
            const slot = try slotOf(element);
            if (slot.*) |inside| {
                if (inside.value == .reference) return storeThrough(run, try endOf(inside), value);
            }
            return replaceAt(run, .{ .element = element }, try copyForOverwrite(run, value));
        },
        .node, .object => return storeThrough(run, try endOf(held), value),
    }
}

/// `value` cast into what `end` holds (see the file's header).
fn castAt(run: *Run, end: End, value: *Object) Error!void {
    switch (end) {
        .byte => |element| return writeByte(element, value, run),
        .node => |node| {
            const held = node.object orelse return error.Type;
            return castInto(run, end, held, value);
        },
        .object => |held| return castInto(run, end, held, value),
        .element => |element| {
            const held = (try slotOf(element)).* orelse return replaceAt(run, end, try copyForOverwrite(run, value));
            return castInto(run, end, held, value);
        },
    }
}

/// `value` cast into `held`, which `end` keeps.
fn castInto(run: *Run, end: End, held: *Object, value: *Object) Error!void {
    switch (held.value) {
        .field_unit => {
            const node = switch (end) {
                .node => |node| node,
                else => return error.Type,
            };
            return region.writeField(run, node, held, value);
        },
        .buffer_field => |field| return writeBufferField(run, field, value),
        .integer, .string, .buffer => return convert.castInto(run.ab, held, value),
        .uninitialized => return replaceAt(run, end, try copyForOverwrite(run, value)),
        // A package stored over a package replaces it.
        .package => {
            if (value.value != .package) return error.Type;
            return replaceAt(run, end, try copyForOverwrite(run, value));
        },
        else => return error.Type,
    }
}

/// What `end` holds replaced with `made`, which the caller gives up.
fn replaceAt(run: *Run, end: End, made: *Object) Error!void {
    const ab = run.ab;
    switch (end) {
        .node => |node| {
            object.release(ab, node.object);
            node.object = made;
        },
        .object => |held| {
            // The object stays, for whoever holds it; its value is what
            // changes - from an object of the caller's own.
            const own = if (made.references == 1) made else own: {
                defer object.release(ab, made);
                break :own try convert.copy(run, made);
            };
            const old = held.value;
            held.value = own.value;
            own.value = old;
            object.release(ab, own);
        },
        .element => |element| {
            const slot = slotOf(element) catch |err| {
                object.release(ab, made);
                return err;
            };
            object.release(ab, slot.*);
            slot.* = made;
        },
        .byte => unreachable,
    }
}

/// What a store that replaces keeps of `value`: a copy, but a reference
/// to a slot of a package itself.
fn copyForOverwrite(run: *Run, value: *Object) Error!*Object {
    if (convert.isSlotReference(value)) return object.retain(value);
    return convert.copy(run, value);
}

/// Whether what `end` holds is written in place: a field, a field of a
/// buffer, a byte.
fn writtenInPlace(end: End) Error!bool {
    if (end == .byte) return true;
    const held = try endObject(end) orelse return false;
    return held.value == .field_unit or held.value == .buffer_field;
}

/// Whether what `end` holds is of a kind only a name holds.
fn namespaceOnly(end: End) Error!bool {
    const held = try endObject(end) orelse return end == .node;
    return switch (held.value) {
        .device, .event, .method, .mutex, .region, .power_resource, .processor, .thermal_zone => true,
        else => false,
    };
}

/// Whether `end` holds nothing yet.
fn isUninitialized(end: End) Error!bool {
    if (end == .node) {
        const held = end.node.object orelse return false;
        return held.value == .uninitialized;
    }
    const held = try endObject(end) orelse return true;
    return held.value == .uninitialized;
}

/// CopyObject: `value`, which stays the caller's, into `place`.
pub fn copyObject(run: *Run, frame: *Frame, place: Place, value: *Object) Error!void {
    switch (place) {
        .none => {},
        .debug => debugOut(run, value),
        .local => |index| {
            // A local that holds a byte of a buffer writes the byte.
            if (frame.locals[index]) |held| {
                if (held.value == .reference and held.value.reference == .byte) return writeByte(held.value.reference.byte, value, run);
            }
            try replaceSlot(run, &frame.locals[index], value);
        },
        .arg => |index| {
            if (frame.args[index]) |held| {
                if (held.value == .reference) return copyAt(run, try endOf(held), value);
            }
            try replaceSlot(run, &frame.args[index], value);
        },
        .node => |node| {
            const at = namespace.target(node);
            if (at.object) |held| {
                if (held.value == .reference and !convert.isSlotReference(held)) return copyAt(run, try endOf(held), value);
            }
            try copyAt(run, .{ .node = at }, value);
        },
        .reference => |held| switch (held.value.reference) {
            .element => |element| try copyAt(run, .{ .element = element }, value),
            .byte => |element| try writeByte(element, value, run),
            .node, .object => try copyAt(run, try endOf(held), value),
        },
        .object => |held| try copyAt(run, .{ .object = held }, value),
        .missing => return error.NotFound,
    }
}

fn copyAt(run: *Run, end: End, value: *Object) Error!void {
    if (try writtenInPlace(end)) return castAt(run, end, value);
    return replaceAt(run, end, try copyForOverwrite(run, value));
}

// --- references ----------------------------------------------------------------------

/// RefOf: a reference to what `place` names.
pub fn refOf(run: *Run, frame: *Frame, place: Place) Error!*Object {
    const reference: object.Reference = switch (place) {
        .node => |node| .{ .node = namespace.target(node) },
        .local => |index| .{ .object = try slotObject(run, &frame.locals[index]) },
        .arg => |index| .{ .object = try slotObject(run, &frame.args[index]) },
        .reference, .object => |held| .{ .object = held },
        .none, .debug, .missing => return error.Type,
    };
    const made = object.make(run.ab, .{ .reference = reference }) orelse return error.NoMemory;
    switch (reference) {
        .node => |node| _ = namespace.hold(node),
        .object => |held| _ = object.retain(held),
        else => unreachable,
    }
    return made;
}

/// The object a local or an argument holds, one made for it where it
/// holds none - so a reference to it has something to refer to.
fn slotObject(run: *Run, slot: *?*Object) Error!*Object {
    if (slot.*) |held| return held;
    const made = object.make(run.ab, .{ .uninitialized = {} }) orelse return error.NoMemory;
    slot.* = made;
    return made;
}

/// DerefOf: what the reference `item` refers to, at its end.
pub fn derefOf(run: *Run, item: Item) Error!Item {
    const held = switch (item) {
        .object => |held| held,
        else => return error.Type,
    };
    if (held.value != .reference) return error.Type;
    return endValue(run, try endOf(held));
}

// --- fields of buffers, and bytes ------------------------------------------------------

/// The bits of a field of a buffer, read.
pub fn readBufferField(run: *Run, field: object.BufferField) Error!Item {
    const bytes = try fieldBytes(field);
    if (!field.as_buffer and field.bit_length <= run.ab.integer_bits) {
        var room: [8]u8 = @splat(0);
        copyBits(&room, 0, bytes, field.bit_offset, field.bit_length);
        return .{ .integer = convert.bytesInteger(run.ab, &room) };
    }
    const length = (field.bit_length + 7) / 8;
    const made = object.makeBytes(run.ab, length) orelse return error.NoMemory;
    copyBits(made.slice(), 0, bytes, field.bit_offset, field.bit_length);
    return .{ .object = object.make(run.ab, .{ .buffer = made }) orelse {
        object.freeBytes(run.ab, made);
        return error.NoMemory;
    } };
}

/// `value` written into a field of a buffer: an integer whole, a string
/// or a buffer as its last piece the size of the field.
pub fn writeBufferField(run: *Run, field: object.BufferField, value: *Object) Error!void {
    const bytes = try fieldBytes(field);
    var room: [8]u8 = undefined;
    var source = try convert.storage(run.ab, value, &room);
    const piece = (field.bit_length + 7) / 8;
    if (piece == 0 or source.len == 0) return;
    if (value.value != .integer) source = source[(source.len - 1) / piece * piece ..];
    putBits(bytes, field.bit_offset, source, field.bit_length);
}

/// The bytes of the buffer a field is of, which hold the field's bits.
fn fieldBytes(field: object.BufferField) Error![]u8 {
    const bytes = switch (field.buffer.value) {
        .buffer => |bytes| bytes.slice(),
        else => return error.Type,
    };
    if (@as(u64, field.bit_offset) + field.bit_length > @as(u64, bytes.len) * 8) return error.Range;
    return bytes;
}

/// `count` bits of `from` at bit `from_bit` into `into` at bit `into_bit`;
/// bits past the end of `from` are 0.
pub fn copyBits(into: []u8, into_bit: usize, from: []const u8, from_bit: usize, count: usize) void {
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const at = from_bit + index;
        const bit: u8 = if (at / 8 < from.len) from[at / 8] >> @intCast(at % 8) & 1 else 0;
        const to = into_bit + index;
        const mask = @as(u8, 1) << @intCast(to % 8);
        into[to / 8] = (into[to / 8] & ~mask) | (bit << @intCast(to % 8));
    }
}

/// `count` bits of `from`, from its first, zero-extended, put into
/// `into` at bit `into_bit`; the bits around them kept.
pub fn putBits(into: []u8, into_bit: usize, from: []const u8, count: usize) void {
    if (into_bit % 8 == 0 and count % 8 == 0) {
        const start = into_bit / 8;
        const length = count / 8;
        const have = @min(length, from.len);
        @memcpy(into[start .. start + have], from[0..have]);
        @memset(into[start + have .. start + length], 0);
        return;
    }
    copyBits(into, into_bit, from, 0, count);
}

/// `value` written into the byte `element` refers to: an integer's low
/// byte, a string's or a buffer's last; nothing from an empty one.
fn writeByte(element: object.Element, value: *Object, run: *Run) Error!void {
    const bytes = try bytesOf(element.container);
    if (element.index >= bytes.len) return error.Range;
    var room: [8]u8 = undefined;
    const source = try convert.storage(run.ab, value, &room);
    if (source.len == 0) return;
    bytes[element.index] = if (value.value == .integer) source[0] else source[source.len - 1];
}

// --- Debug ---------------------------------------------------------------------------

/// What is stored into Debug, said in the log at debug level.
pub fn debugOut(run: *Run, value: *Object) void {
    const ab = run.ab;
    switch (value.value) {
        .integer => |integer| machine.log(ab, exec.LOG_DEBUG, "Debug: 0x%lx\n", .{integer}),
        .string => |text| machine.log(ab, exec.LOG_DEBUG, "Debug: \"%s\"\n", .{@as([*:0]const u8, @ptrCast(text.bytes))}),
        .buffer => |bytes| machine.log(ab, exec.LOG_DEBUG, "Debug: a buffer of %u bytes\n", .{bytes.length}),
        .package => |package| machine.log(ab, exec.LOG_DEBUG, "Debug: a package of %u elements\n", .{package.count}),
        .reference => |reference| switch (reference) {
            .node => |node| {
                var text: [namespace.PATH_ROOM]u8 = undefined;
                _ = namespace.pathOf(node, &text);
                machine.log(ab, exec.LOG_DEBUG, "Debug: a reference to %s\n", .{@as([*:0]const u8, @ptrCast(&text))});
            },
            else => machine.log(ab, exec.LOG_DEBUG, "Debug: a reference\n", .{}),
        },
        else => machine.log(ab, exec.LOG_DEBUG, "Debug: an object of kind %u\n", .{@as(u32, @intFromEnum(value.kind()))}),
    }
}

// --- tests ------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "bits are copied across bytes, and bits past the source are 0" {
    var into = [_]u8{ 0xFF, 0xFF, 0xFF };
    copyBits(&into, 4, &.{0x00}, 0, 8);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0xF0, 0xFF }, &into);
    var read: [2]u8 = @splat(0);
    copyBits(&read, 0, &.{ 0x34, 0x12 }, 4, 12);
    try testing.expectEqualSlices(u8, &.{ 0x23, 0x01 }, &read);
    var aligned = [_]u8{ 0xAA, 0xAA, 0xAA };
    putBits(&aligned, 8, &.{0x55}, 16);
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0x55, 0x00 }, &aligned);
}
