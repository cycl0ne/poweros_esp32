// SPDX-License-Identifier: MPL-2.0
//! The operators: each term that works something out or changes
//! something, done once its operands are in - arithmetic, logic, the
//! conversions, references, Match, the mutexes and events, Notify, Load -
//! and the method the interpreter answers itself, `\_OSI`.
//!
//! **Operands and targets.** An operand an operator wants as an integer
//! is made one as convert.zig says. A target is where the result goes as
//! well, stored there as Store stores (store.zig) before the result goes
//! on to the term the operator is an operand of; a Zero there is none.
//!
//! **Arithmetic** is at the namespace's integer width: a result is cut
//! to it, a shift by as many bits as it has or more is 0, a division by
//! zero is an error. Increment and Decrement change what their operand
//! names - through a reference, into a field - and answer the new value.
//! FindSetLeftBit and FindSetRightBit count bits from 1, and answer 0
//! where none is set. FromBCD reads each digit as it is, even one above
//! 9.
//!
//! **Logic.** LAnd and LOr read a buffer's first four bytes and a string
//! as ToInteger does. LEqual, LGreater and LLess compare the second
//! operand made the first's kind: integers by value, strings and buffers
//! byte by byte - where one begins with the other, the shorter is the
//! lesser; anything else is never equal, greater or less. True is every
//! bit set, false 0.
//!
//! **References.** Index refers to one byte of a buffer or a string, or
//! to one element of a package - of the object itself, a reference
//! followed to it, never of a copy. DerefOf follows a reference to its
//! end, takes a string as the name it spells, and gives anything else
//! as it is. SizeOf is a string's length, a buffer's, a package's count,
//! an integer's bytes. ObjectType is the kind of what its operand names,
//! references followed: 0 for nothing, 14 for a byte of a buffer.
//!
//! **Match** finds the first integer element, from the start it is
//! given, that both of two comparisons hold for, and answers Ones where
//! none does.
//!
//! **Notify** is kept for whatever takes the system's notifications
//! (notice.zig); what it is about must be a device, a processor or a
//! thermal zone.
//!
//! **Load** loads a table from a region of memory, a field or a buffer -
//! copied, as long as its header says -, LoadTable one of the firmware's
//! by its signature and names, at the scope it names, then stores a value
//! where it says; each answers whether the table was loaded. Unload is
//! said in the log and does nothing.
//!
//! **Fatal** is said in the log, and the bytecode goes on.
//!
//! **\_OSI** answers true for the interfaces the system offers - each
//! version of Windows from "Windows 2000" to "Windows 2022", and the
//! extended address space descriptor - and false for any other, "Linux"
//! among them.

const sdk = @import("sdk");
const exec = sdk.exec;
const hardware_acpi = sdk.hardware.acpi;
const machine = @import("../machine/_machine.zig");
const namespace = @import("../namespace/_namespace.zig");
const Node = namespace.Node;
const object = @import("../object/_object.zig");
const Object = object.Object;
const load = @import("../aml/load.zig");
const interpreter = @import("_interpreter.zig");
const Run = interpreter.Run;
const Frame = interpreter.Frame;
const Op = interpreter.Op;
const Item = interpreter.Item;
const Place = interpreter.Place;
const Error = interpreter.Error;
const convert = @import("convert.zig");
const store = @import("store.zig");
const sync = @import("sync.zig");
const notice = @import("notice.zig");
const region = @import("../region/_region.zig");
const EXT = @import("../aml/_aml.zig").EXT;

const STORE: u16 = 0x70;
const REF_OF: u16 = 0x71;
const ADD: u16 = 0x72;
const CONCATENATE: u16 = 0x73;
const SUBTRACT: u16 = 0x74;
const INCREMENT: u16 = 0x75;
const DECREMENT: u16 = 0x76;
const MULTIPLY: u16 = 0x77;
const DIVIDE: u16 = 0x78;
const SHIFT_LEFT: u16 = 0x79;
const SHIFT_RIGHT: u16 = 0x7A;
const AND: u16 = 0x7B;
const NAND: u16 = 0x7C;
const OR: u16 = 0x7D;
const NOR: u16 = 0x7E;
const XOR: u16 = 0x7F;
const NOT: u16 = 0x80;
const FIND_SET_LEFT_BIT: u16 = 0x81;
const FIND_SET_RIGHT_BIT: u16 = 0x82;
const DEREF_OF: u16 = 0x83;
const CONCATENATE_TEMPLATES: u16 = 0x84;
const MOD: u16 = 0x85;
const NOTIFY: u16 = 0x86;
const SIZE_OF: u16 = 0x87;
const INDEX: u16 = 0x88;
const MATCH: u16 = 0x89;
const OBJECT_TYPE: u16 = 0x8E;
const LAND: u16 = 0x90;
const LOR: u16 = 0x91;
const LNOT: u16 = 0x92;
const LEQUAL: u16 = 0x93;
const LGREATER: u16 = 0x94;
const LLESS: u16 = 0x95;
const TO_BUFFER: u16 = 0x96;
const TO_DECIMAL_STRING: u16 = 0x97;
const TO_HEX_STRING: u16 = 0x98;
const TO_INTEGER: u16 = 0x99;
const TO_STRING: u16 = 0x9C;
const COPY_OBJECT: u16 = 0x9D;
const MID: u16 = 0x9E;
const COND_REF_OF: u16 = EXT | 0x12;
const LOAD_TABLE: u16 = EXT | 0x1F;
const LOAD: u16 = EXT | 0x20;
const STALL: u16 = EXT | 0x21;
const SLEEP: u16 = EXT | 0x22;
const ACQUIRE: u16 = EXT | 0x23;
const SIGNAL: u16 = EXT | 0x24;
const WAIT: u16 = EXT | 0x25;
const RESET: u16 = EXT | 0x26;
const RELEASE: u16 = EXT | 0x27;
const FROM_BCD: u16 = EXT | 0x28;
const TO_BCD: u16 = EXT | 0x29;
const UNLOAD: u16 = EXT | 0x2A;
const FATAL: u16 = EXT | 0x32;
const TIMER: u16 = EXT | 0x33;

/// The op on top, an operator with all its operands, done: its result,
/// for the term it is an operand of.
pub fn execute(run: *Run, frame: *Frame, op: *Op) Error!Item {
    const ab = run.ab;
    const items = &op.items;
    switch (op.code) {
        STORE, COPY_OBJECT => {
            const value = try ownObject(run, items[0]);
            errdefer object.release(ab, value);
            if (op.code == STORE) {
                try store.store(run, frame, placeAt(op, 1), value);
            } else {
                try store.copyObject(run, frame, placeAt(op, 1), value);
            }
            return .{ .object = value };
        },
        REF_OF => return .{ .object = try store.refOf(run, frame, placeAt(op, 0)) },
        ADD, SUBTRACT, MULTIPLY, SHIFT_LEFT, SHIFT_RIGHT, AND, NAND, OR, NOR, XOR, MOD => {
            const first = try convert.toInteger(run, items[0]);
            const second = try convert.toInteger(run, items[1]);
            const value = object.clip(ab, try arithmetic(run, op.code, first, second));
            return toTarget(run, frame, op, 2, .{ .integer = value });
        },
        DIVIDE => {
            const dividend = try convert.toInteger(run, items[0]);
            const divisor = try convert.toInteger(run, items[1]);
            if (divisor == 0) return error.DivideByZero;
            const quotient = dividend / divisor;
            _ = try toTarget(run, frame, op, 3, .{ .integer = quotient });
            _ = try toTarget(run, frame, op, 2, .{ .integer = dividend % divisor });
            return .{ .integer = quotient };
        },
        NOT, FIND_SET_LEFT_BIT, FIND_SET_RIGHT_BIT => {
            const operand = try convert.toInteger(run, items[0]);
            const value: u64 = switch (op.code) {
                NOT => object.clip(ab, ~operand),
                FIND_SET_LEFT_BIT => if (operand == 0) 0 else 64 - @as(u64, @clz(operand)),
                else => if (operand == 0) 0 else @as(u64, @ctz(operand)) + 1,
            };
            return toTarget(run, frame, op, 1, .{ .integer = value });
        },
        INCREMENT, DECREMENT => return step(run, frame, placeAt(op, 0), op.code == INCREMENT),
        CONCATENATE, CONCATENATE_TEMPLATES => {
            const made = if (op.code == CONCATENATE)
                try convert.concatenate(run, items[0], items[1])
            else
                try convert.concatenateTemplates(run, items[0], items[1]);
            return toTarget(run, frame, op, 2, .{ .object = made });
        },
        DEREF_OF => return derefOf(run, frame, items[0]),
        NOTIFY => {
            try notice.queue(run, placeAt(op, 0), try convert.toInteger(run, items[1]));
            return .none;
        },
        SIZE_OF => return .{ .integer = try sizeOf(run, frame, placeAt(op, 0)) },
        INDEX => return index(run, frame, op),
        MATCH => return .{ .integer = try match(run, op) },
        OBJECT_TYPE => return .{ .integer = try objectType(frame, placeAt(op, 0)) },
        LAND, LOR => {
            const first = try logicInteger(run, items[0]) != 0;
            const second = try logicInteger(run, items[1]) != 0;
            return .{ .integer = convert.truth(ab, if (op.code == LAND) first and second else first or second) };
        },
        LNOT => return .{ .integer = convert.truth(ab, try convert.toInteger(run, items[0]) == 0) },
        LEQUAL, LGREATER, LLESS => {
            const order = try compare(run, items[0], items[1]);
            const true_of = switch (op.code) {
                LEQUAL => order == .equal,
                LGREATER => order == .greater,
                else => order == .less,
            };
            return .{ .integer = convert.truth(ab, true_of) };
        },
        TO_BUFFER => return toTarget(run, frame, op, 1, .{ .object = try convert.toBuffer(run, items[0]) }),
        TO_DECIMAL_STRING, TO_HEX_STRING => return toTarget(run, frame, op, 1, .{ .object = try convert.toText(run, items[0], op.code == TO_HEX_STRING) }),
        TO_INTEGER => return toTarget(run, frame, op, 1, .{ .integer = try convert.explicitInteger(run, items[0]) }),
        TO_STRING => {
            const length = try convert.toInteger(run, items[1]);
            return toTarget(run, frame, op, 2, .{ .object = try convert.toString(run, items[0], length) });
        },
        MID => {
            const start = try convert.toInteger(run, items[1]);
            const length = try convert.toInteger(run, items[2]);
            return toTarget(run, frame, op, 3, .{ .object = try convert.mid(run, items[0], start, length) });
        },
        COND_REF_OF => {
            const place = placeAt(op, 0);
            if (place == .missing) return .{ .integer = 0 };
            const made = try store.refOf(run, frame, place);
            defer object.release(ab, made);
            if (placeAt(op, 1) != .none) try store.store(run, frame, placeAt(op, 1), made);
            return .{ .integer = convert.ones(ab) };
        },
        LOAD => return loadOp(run, frame, op),
        LOAD_TABLE => return .{ .integer = convert.truth(ab, try loadTableOp(run, frame, op)) },
        UNLOAD => {
            machine.log(ab, exec.LOG_WARNING, "Unload: a table stays loaded\n", .{});
            return .none;
        },
        STALL => {
            sync.stall(run, try convert.toInteger(run, items[0]));
            return .none;
        },
        SLEEP => {
            sync.sleep(run, try convert.toInteger(run, items[0]));
            return .none;
        },
        ACQUIRE => {
            const timed_out = try sync.acquire(run, try endObjectOf(frame, placeAt(op, 0)), items[1].integer);
            return .{ .integer = convert.truth(ab, timed_out) };
        },
        RELEASE => {
            try sync.release(run, try endObjectOf(frame, placeAt(op, 0)));
            return .none;
        },
        SIGNAL => {
            try sync.signal(try endObjectOf(frame, placeAt(op, 0)));
            return .none;
        },
        RESET => {
            try sync.reset(try endObjectOf(frame, placeAt(op, 0)));
            return .none;
        },
        WAIT => {
            const timeout = try convert.toInteger(run, items[1]);
            const timed_out = try sync.wait(run, try endObjectOf(frame, placeAt(op, 0)), timeout);
            return .{ .integer = convert.truth(ab, timed_out) };
        },
        FROM_BCD => return toTarget(run, frame, op, 1, .{ .integer = object.clip(ab, fromBcd(try convert.toInteger(run, items[0]))) }),
        TO_BCD => return toTarget(run, frame, op, 1, .{ .integer = object.clip(ab, toBcd(try convert.toInteger(run, items[0]))) }),
        TIMER => return .{ .integer = ab.machine.time(ab) },
        FATAL => {
            machine.log(ab, exec.LOG_ERROR, "the firmware's Fatal: type 0x%x, code 0x%x, argument 0x%lx\n", .{
                @as(u32, @intCast(items[0].integer)), @as(u32, @intCast(items[1].integer)), convert.toInteger(run, items[2]) catch 0,
            });
            return .none;
        },
        else => return error.Unknown,
    }
}

/// Whether a predicate holds: an If's, a While's.
pub fn truth(run: *Run, item: Item) Error!bool {
    return try convert.toInteger(run, item) != 0;
}

// --- operands and targets -------------------------------------------------------------------

/// The op's operand `at`, a target: where its result goes.
fn placeAt(op: *const Op, at: usize) Place {
    return switch (op.items[at]) {
        .place => |place| place,
        else => .none,
    };
}

/// `item` as an object the caller holds: one more hold of an object, an
/// integer made one, nothing an uninitialized one.
fn ownObject(run: *Run, item: Item) Error!*Object {
    return switch (item) {
        .object => |held| object.retain(held),
        else => interpreter.objectOf(run, item),
    };
}

/// `result`, the op's, stored into its target `at` where it has one, and
/// handed on: what the caller made it holds is the result's.
fn toTarget(run: *Run, frame: *Frame, op: *const Op, at: usize, result: Item) Error!Item {
    errdefer interpreter.release(run.ab, result);
    const place = placeAt(op, at);
    if (place == .none) return result;
    switch (result) {
        .integer => |value| {
            const made = object.makeInteger(run.ab, value) orelse return error.NoMemory;
            defer object.release(run.ab, made);
            try store.store(run, frame, place, made);
        },
        .object => |held| try store.store(run, frame, place, held),
        else => return error.Type,
    }
    return result;
}

/// What `place` holds, as an operand: a name read, a local's or an
/// argument's object, a reference followed to its end.
fn readPlace(run: *Run, frame: *Frame, place: Place) Error!Item {
    switch (place) {
        .node => |node| return store.readNode(run, node),
        .local, .arg => {
            const slot = if (place == .local) frame.locals[place.local] else frame.args[place.arg];
            const held = slot orelse return error.Uninitialized;
            if (held.value == .reference) return store.endValue(run, try store.endOf(held));
            return .{ .object = object.retain(held) };
        },
        .reference => |held| return store.endValue(run, try store.endOf(held)),
        .object => |held| return store.valueOf(run, held),
        .none, .debug, .missing => return error.Type,
    }
}

/// The object `place` names at the end of its references: a mutex, an
/// event, for the operators on them.
fn endObjectOf(frame: *Frame, place: Place) Error!*Object {
    const end = try store.placeEnd(frame, place);
    return try store.endObject(end) orelse error.Type;
}

// --- arithmetic --------------------------------------------------------------------------

fn arithmetic(run: *const Run, code: u16, first: u64, second: u64) Error!u64 {
    const bits = run.ab.integer_bits;
    return switch (code) {
        ADD => first +% second,
        SUBTRACT => first -% second,
        MULTIPLY => first *% second,
        SHIFT_LEFT => if (second >= bits) 0 else first << @intCast(second),
        SHIFT_RIGHT => if (second >= bits) 0 else first >> @intCast(second),
        AND => first & second,
        NAND => ~(first & second),
        OR => first | second,
        NOR => ~(first | second),
        XOR => first ^ second,
        MOD => if (second == 0) error.DivideByZero else first % second,
        else => unreachable,
    };
}

/// Increment (`up`) and Decrement: what `place` names, one more or one
/// less, stored back and answered.
fn step(run: *Run, frame: *Frame, place: Place, up: bool) Error!Item {
    const current = try readPlace(run, frame, place);
    defer interpreter.release(run.ab, current);
    const old = try convert.toInteger(run, current);
    const value = object.clip(run.ab, if (up) old +% 1 else old -% 1);
    const made = object.makeInteger(run.ab, value) orelse return error.NoMemory;
    defer object.release(run.ab, made);
    try store.store(run, frame, place, made);
    return .{ .integer = value };
}

/// FromBCD: each four bits a decimal digit, the highest first.
fn fromBcd(value: u64) u64 {
    var result: u64 = 0;
    var shift: u7 = 64;
    while (shift > 0) {
        shift -= 4;
        result = result *% 10 +% (value >> @intCast(shift) & 0xF);
    }
    return result;
}

/// ToBCD: each decimal digit four bits, the lowest lowest.
fn toBcd(value: u64) u64 {
    var result: u64 = 0;
    var left = value;
    var shift: u7 = 0;
    while (left != 0 and shift < 64) : (shift += 4) {
        result |= (left % 10) << @intCast(shift);
        left /= 10;
    }
    return result;
}

// --- logic --------------------------------------------------------------------------------

/// An operand of LAnd or LOr as an integer: a buffer's first four bytes,
/// a string as ToInteger reads one.
fn logicInteger(run: *Run, item: Item) Error!u64 {
    const held = switch (item) {
        .object => |held| held,
        else => return convert.toInteger(run, item),
    };
    return switch (held.value) {
        .buffer => |bytes| convert.bytesInteger(run.ab, bytes.slice()[0..@min(bytes.length, 4)]),
        .string => |text| object.clip(run.ab, convert.cInteger(text.slice())),
        else => convert.toInteger(run, item),
    };
}

const Order = enum { less, equal, greater, none };

/// How `first` and `second` compare, the second made the first's kind.
fn compare(run: *Run, first: Item, second: Item) Error!Order {
    const held = switch (first) {
        .object => |held| held,
        else => return orderOf(try convert.toInteger(run, first), try convert.toInteger(run, second)),
    };
    switch (held.value) {
        .integer => |value| return orderOf(object.clip(run.ab, value), try convert.toInteger(run, second)),
        .string, .buffer => |bytes| {
            var room: [16]u8 = undefined;
            const other = try comparedBytes(run, second, held.value == .string, &room);
            return orderOfBytes(bytes.slice(), other);
        },
        else => return .none,
    }
}

fn orderOf(first: u64, second: u64) Order {
    if (first < second) return .less;
    if (first > second) return .greater;
    return .equal;
}

/// The bytes `item` is compared as against a string (`as_text`) or a
/// buffer: a string's, a buffer's; an integer's own bytes against a
/// buffer, its hexadecimal digits against a string.
fn comparedBytes(run: *Run, item: Item, as_text: bool, room: *[16]u8) Error![]const u8 {
    const value: u64 = switch (item) {
        .integer => |value| value,
        .object => |held| switch (held.value) {
            .string, .buffer => |bytes| return bytes.slice(),
            .integer => |value| value,
            else => return error.Type,
        },
        .none => return error.Uninitialized,
        else => return error.Type,
    };
    const count = convert.integerBytes(run.ab);
    if (!as_text) {
        for (room[0..count], 0..) |*byte, at| byte.* = @truncate(value >> @intCast(at * 8));
        return room[0..count];
    }
    const digits = "0123456789ABCDEF";
    const length = count * 2;
    for (room[0..length], 0..) |*char, at| char.* = digits[@intCast(value >> @intCast((length - 1 - at) * 4) & 0xF)];
    return room[0..length];
}

fn orderOfBytes(first: []const u8, second: []const u8) Order {
    const shorter = @min(first.len, second.len);
    for (first[0..shorter], second[0..shorter]) |one, other| {
        if (one < other) return .less;
        if (one > other) return .greater;
    }
    return orderOf(first.len, second.len);
}

// --- references ---------------------------------------------------------------------------

fn derefOf(run: *Run, frame: *Frame, item: Item) Error!Item {
    const held = switch (item) {
        .object => |held| held,
        .integer => return item,
        else => return error.Type,
    };
    switch (held.value) {
        .reference => return store.derefOf(run, item),
        .string => |text| {
            var spelled: namespace.TextPath = .{};
            if (!namespace.parseText(@ptrCast(text.bytes), &spelled)) return error.Type;
            const node = try interpreter.findName(run, frame, spelled.path);
            return store.readNode(run, node);
        },
        else => return .{ .object = object.retain(held) },
    }
}

/// The object an operand is, a reference followed to where it ends - the
/// object itself, not a copy.
fn containerOf(run: *Run, item: Item) Error!*Object {
    const held = switch (item) {
        .object => |held| held,
        .none => return error.Uninitialized,
        else => return error.Type,
    };
    if (held.value != .reference) return object.retain(held);
    const value = try store.derefOf(run, item);
    return switch (value) {
        .object => |inside| inside,
        else => {
            interpreter.release(run.ab, value);
            return error.Type;
        },
    };
}

fn index(run: *Run, frame: *Frame, op: *Op) Error!Item {
    const container = try containerOf(run, op.items[0]);
    defer object.release(run.ab, container);
    const at = try convert.toInteger(run, op.items[1]);
    const reference: object.Reference = switch (container.value) {
        .buffer, .string => |bytes| reference: {
            if (at >= bytes.length) return error.Range;
            break :reference .{ .byte = .{ .container = container, .index = @intCast(at) } };
        },
        .package => |package| reference: {
            if (at >= package.count) return error.Range;
            break :reference .{ .element = .{ .container = container, .index = @intCast(at) } };
        },
        else => return error.Type,
    };
    const made = object.make(run.ab, .{ .reference = reference }) orelse return error.NoMemory;
    _ = object.retain(container);
    return toTarget(run, frame, op, 2, .{ .object = made });
}

fn sizeOf(run: *Run, frame: *Frame, place: Place) Error!u64 {
    const held = try endObjectOf(frame, place);
    return switch (held.value) {
        .string, .buffer => |bytes| bytes.length,
        .package => |package| package.count,
        .integer => convert.integerBytes(run.ab),
        else => error.Type,
    };
}

fn objectType(frame: *Frame, place: Place) Error!u64 {
    switch (place) {
        .debug => return @intFromEnum(object.Kind.debug),
        .local => |at| if (frame.locals[at] == null) return 0,
        .arg => |at| if (frame.args[at] == null) return 0,
        else => {},
    }
    const end = try store.placeEnd(frame, place);
    if (end == .byte) return @intFromEnum(object.Kind.buffer_field);
    const held = try store.endObject(end) orelse return 0;
    return switch (held.value) {
        .name => @intFromEnum(object.Kind.string),
        .alias, .reference => 0,
        else => @intFromEnum(held.kind()),
    };
}

// --- Match --------------------------------------------------------------------------------

fn match(run: *Run, op: *Op) Error!u64 {
    const package_object = try containerOf(run, op.items[0]);
    defer object.release(run.ab, package_object);
    const package = switch (package_object.value) {
        .package => |package| package,
        else => return error.Type,
    };
    const first_test = op.items[1].integer;
    const first_value = try convert.toInteger(run, op.items[2]);
    const second_test = op.items[3].integer;
    const second_value = try convert.toInteger(run, op.items[4]);
    if (first_test > 5 or second_test > 5) return error.Range;
    var at = try convert.toInteger(run, op.items[5]);
    while (at < package.count) : (at += 1) {
        const element = package.elements[@intCast(at)] orelse continue;
        const value = switch (element.value) {
            .integer => |value| value,
            else => continue,
        };
        if (matches(first_test, value, first_value) and matches(second_test, value, second_value)) return at;
    }
    return convert.ones(run.ab);
}

/// Match's comparisons: true, equal, less or equal, less, greater or
/// equal, greater.
fn matches(comparison: u64, element: u64, value: u64) bool {
    return switch (comparison) {
        0 => true,
        1 => element == value,
        2 => element <= value,
        3 => element < value,
        4 => element >= value,
        else => element > value,
    };
}

// --- Load and LoadTable ------------------------------------------------------------------------

/// The text of a string operand.
fn textOf(item: Item) Error![]const u8 {
    const held = switch (item) {
        .object => |held| held,
        else => return error.Type,
    };
    return switch (held.value) {
        .string => |text| text.slice(),
        else => error.Type,
    };
}

/// Load: the table the region, field or buffer the name names holds.
fn loadOp(run: *Run, frame: *Frame, op: *Op) Error!Item {
    const ab = run.ab;
    const node = namespace.target(try interpreter.findName(run, frame, op.items[0].path));
    const held = node.object orelse return error.Type;
    var loaded = false;
    switch (held.value) {
        .region => |source| {
            if (source.space != hardware_acpi.SPACE_SYSTEM_MEMORY or source.length < load.HEADER_SIZE) return error.Type;
            var header: [load.HEADER_SIZE]u8 = undefined;
            try region.readBytes(run, node, 0, &header);
            const length = load.lengthOf(&header);
            if (length < load.HEADER_SIZE or length > source.length or length > load.MOST_LOADED) return error.Range;
            const bytes = machine.allocBytes(ab, length) orelse return error.NoMemory;
            defer machine.freeBytes(ab, bytes, length);
            try region.readBytes(run, node, 0, bytes[0..length]);
            loaded = load.loadMore(ab, bytes[0..length], ab.root.?, interpreter.ownerOf(run), true);
        },
        .buffer => |bytes| loaded = load.loadMore(ab, bytes.slice(), ab.root.?, interpreter.ownerOf(run), true),
        .field_unit => {
            const value = try region.readField(run, node, held);
            defer interpreter.release(ab, value);
            const bytes = switch (value) {
                .object => |inside| inside.value.buffer.slice(),
                else => return error.Type,
            };
            loaded = load.loadMore(ab, bytes, ab.root.?, interpreter.ownerOf(run), true);
        },
        else => return error.Type,
    }
    return toTarget(run, frame, op, 1, .{ .integer = convert.truth(ab, loaded) });
}

/// LoadTable: one of the firmware's tables, at the scope its fourth
/// operand names - the root where it names none -, and its last operand
/// stored where its fifth names, from that scope.
fn loadTableOp(run: *Run, frame: *Frame, op: *Op) Error!bool {
    const ab = run.ab;
    const signature = try textOf(op.items[0]);
    if (signature.len != 4) return error.Type;
    const table = ab.machine.findTable(ab, signature[0..4], try textOf(op.items[1]), try textOf(op.items[2])) orelse return false;
    const root = ab.root.?;
    var scope = root;
    const root_text = try textOf(op.items[3]);
    if (root_text.len != 0) scope = try nodeOfText(run, root_text, frame.scope);
    const parameter_text = try textOf(op.items[4]);
    if (!load.loadMore(ab, table, scope, interpreter.ownerOf(run), false)) return false;
    if (parameter_text.len != 0) {
        const parameter = try nodeOfText(run, parameter_text, scope);
        const value = try ownObject(run, op.items[5]);
        defer object.release(ab, value);
        try store.store(run, frame, .{ .node = parameter }, value);
    }
    return true;
}

/// The name a string spells, looked up from `scope`.
fn nodeOfText(run: *Run, text: []const u8, scope: *Node) Error!*Node {
    var spelled: namespace.TextPath = .{};
    if (!namespace.parseText(@ptrCast(text.ptr), &spelled)) return error.Type;
    return namespace.find(run.ab, scope, spelled.path, .search) orelse interpreter.notFound(run, scope, spelled.path);
}

// --- \_OSI ------------------------------------------------------------------------------------

/// The interfaces `\_OSI` answers true for.
const interfaces = [_][]const u8{
    "Windows 2000",
    "Windows 2001",
    "Windows 2001 SP1",
    "Windows 2001.1",
    "Windows 2001 SP2",
    "Windows 2001.1 SP1",
    "Windows 2006",
    "Windows 2006.1",
    "Windows 2006 SP1",
    "Windows 2006 SP2",
    "Windows 2009",
    "Windows 2012",
    "Windows 2013",
    "Windows 2015",
    "Windows 2016",
    "Windows 2017",
    "Windows 2017.2",
    "Windows 2018",
    "Windows 2018.2",
    "Windows 2019",
    "Windows 2020",
    "Windows 2021",
    "Windows 2022",
    "Extended Address Space Descriptor",
};

/// The method `which` the interpreter answers itself, with `args`.
pub fn builtin(run: *Run, args: []const Item, which: object.Builtin) Error!Item {
    switch (which) {
        .none => return error.Type,
        .osi => {
            if (args.len < 1) return error.Type;
            const asked = try textOf(args[0]);
            for (interfaces) |offered| {
                if (sameText(asked, offered)) return .{ .integer = convert.ones(run.ab) };
            }
            return .{ .integer = 0 };
        },
    }
}

fn sameText(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |a, b| {
        if (a != b) return false;
    }
    return true;
}
