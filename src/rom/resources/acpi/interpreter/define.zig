// SPDX-License-Identifier: MPL-2.0
//! The terms that define a name, and the data objects a term makes: each
//! done once its operands are in, the same while a table loads and while
//! a method runs.
//!
//! **What a definition makes.** Scope enters a scope that is there
//! already, its body run within it; Device, Processor, PowerResource and
//! ThermalZone make a name that is a scope as well, and enter it. Name
//! makes a name holding what its operand worked out to. Method makes a
//! name for a body kept where the table has it. Mutex, Event and Alias
//! make what they say; OperationRegion a region at the address and of the
//! length its operands work out to, DataTableRegion one over a table the
//! firmware has. Field, IndexField and BankField make one name for each
//! field unit, in the scope the field is declared in, with its bits
//! counted on from the previous one's end; the CreateField family a field
//! of a buffer, which holds the buffer. External declares and makes
//! nothing.
//!
//! **Kept, or taken out again.** A name the table's own code defines
//! stays. One a method defines is the method's, taken out of the
//! namespace when it returns.
//!
//! **What goes wrong, and how far.** While a table loads, a name that is
//! there already is kept as it was and the term that defines it again is
//! stepped over, a body with it; a Scope, a field's region or an alias's
//! object that is not there leaves the term out; an element of a field's
//! list that cannot be read leaves out the rest of that field. Each is
//! said and counted, and loading goes on. While a method runs, each ends
//! the evaluation.
//!
//! **Data.** Buffer makes a buffer as long as its size operand or its
//! initial bytes, whichever is longer; Package and VarPackage a package
//! of as many elements as their count, each element worked out in turn -
//! one past the count left out, one the count has more of than are
//! written left empty. A name among the elements is kept as the name, to
//! be looked up when it is read.

const sdk = @import("sdk");
const exec = sdk.exec;
const hardware_acpi = sdk.hardware.acpi;
const AcpiBase = @import("../acpi_base.zig").AcpiBase;
const machine = @import("../machine/_machine.zig");
const namespace = @import("../namespace/_namespace.zig");
const Node = namespace.Node;
const Path = namespace.Path;
const object = @import("../object/_object.zig");
const Object = object.Object;
const aml = @import("../aml/_aml.zig");
const Reader = aml.Reader;
const opcodes = @import("../aml/opcodes.zig");
const load = @import("../aml/load.zig");
const interpreter = @import("_interpreter.zig");
const Run = interpreter.Run;
const Frame = interpreter.Frame;
const Op = interpreter.Op;
const Item = interpreter.Item;
const Error = interpreter.Error;
const convert = @import("convert.zig");
const region_area = @import("../region/_region.zig");

/// Whether `code` defines a name.
pub fn isDefinition(code: u16) bool {
    return switch (code) {
        opcodes.ALIAS_OP,
        opcodes.NAME_OP,
        opcodes.SCOPE_OP,
        opcodes.METHOD_OP,
        opcodes.EXTERNAL_OP,
        opcodes.CREATE_DWORD_FIELD_OP,
        opcodes.CREATE_WORD_FIELD_OP,
        opcodes.CREATE_BYTE_FIELD_OP,
        opcodes.CREATE_BIT_FIELD_OP,
        opcodes.CREATE_QWORD_FIELD_OP,
        opcodes.CREATE_FIELD_OP,
        opcodes.MUTEX_OP,
        opcodes.EVENT_OP,
        opcodes.OP_REGION_OP,
        opcodes.FIELD_OP,
        opcodes.DEVICE_OP,
        opcodes.PROCESSOR_OP,
        opcodes.POWER_RES_OP,
        opcodes.THERMAL_ZONE_OP,
        opcodes.INDEX_FIELD_OP,
        opcodes.BANK_FIELD_OP,
        opcodes.DATA_REGION_OP,
        => true,
        else => false,
    };
}

/// The table being loaded where the frame is the table's own code; null
/// in a method.
fn loading(run: *const Run, frame: *const Frame) ?*load.Load {
    return if (frame.method == null) run.load else null;
}

/// The op on top, a definition or a data object, done.
pub fn execute(run: *Run, frame: *Frame, op: *Op) Error!void {
    switch (op.code) {
        opcodes.SCOPE_OP => return scopeOp(run, frame, op),
        opcodes.DEVICE_OP, opcodes.THERMAL_ZONE_OP, opcodes.PROCESSOR_OP, opcodes.POWER_RES_OP => return deviceOp(run, frame, op),
        opcodes.METHOD_OP => return methodOp(run, frame, op),
        opcodes.NAME_OP => return nameOp(run, frame, op),
        opcodes.MUTEX_OP => {
            const level: u8 = @intCast(op.items[1].integer & 0x0F);
            return made(run, frame, op.items[0].path, object.make(run.ab, .{ .mutex = .{ .sync_level = level } }));
        },
        opcodes.EVENT_OP => return made(run, frame, op.items[0].path, object.make(run.ab, .{ .event = .{} })),
        opcodes.ALIAS_OP => {
            const source = try referred(run, frame, op.items[0].path, "the alias's object") orelse return interpreter.finish(run, frame, .none);
            return made(run, frame, op.items[1].path, object.make(run.ab, .{ .alias = source }));
        },
        opcodes.OP_REGION_OP => return regionOp(run, frame, op),
        opcodes.DATA_REGION_OP => return dataRegionOp(run, frame, op),
        opcodes.FIELD_OP, opcodes.INDEX_FIELD_OP, opcodes.BANK_FIELD_OP => return fieldOp(run, frame, op),
        opcodes.CREATE_DWORD_FIELD_OP,
        opcodes.CREATE_WORD_FIELD_OP,
        opcodes.CREATE_BYTE_FIELD_OP,
        opcodes.CREATE_BIT_FIELD_OP,
        opcodes.CREATE_QWORD_FIELD_OP,
        opcodes.CREATE_FIELD_OP,
        => return bufferFieldOp(run, frame, op),
        opcodes.EXTERNAL_OP => return interpreter.finish(run, frame, .none),
        opcodes.BUFFER_OP => return bufferOp(run, frame, op),
        opcodes.PACKAGE_OP, opcodes.VAR_PACKAGE_OP => return packageOp(run, frame, op),
        else => unreachable,
    }
}

// --- names ----------------------------------------------------------------------------

/// `held` (taken over) given the name `path` makes from the frame's scope:
/// the node; null, said and counted, where the table's own code defines a
/// name that is there already or in a scope that is not.
fn defineName(run: *Run, frame: *Frame, path: Path, held: *Object) Error!?*Node {
    const ab = run.ab;
    const table = loading(run, frame);
    const index: u16 = if (table) |loaded| loaded.table.index else if (frame.method) |method| method.table else 0;
    switch (namespace.create(ab, frame.scope, path, index)) {
        .made => |node| {
            node.object = held;
            if (table) |loaded| {
                loaded.loaded.names += 1;
            } else {
                const kept = run.temporaries.push(ab) orelse {
                    namespace.remove(ab, node);
                    return error.NoMemory;
                };
                kept.* = node;
            }
            return node;
        },
        .there => |node| {
            object.release(ab, held);
            if (table) |loaded| {
                load.again(loaded, node);
                return null;
            }
            _ = namespace.pathOf(node, &run.detail);
            run.has_detail = true;
            return error.Exists;
        },
        .missing => {
            object.release(ab, held);
            if (table) |loaded| {
                load.noScope(loaded, frame.scope, path);
                return null;
            }
            return interpreter.notFound(run, frame.scope, path);
        },
        .no_memory => {
            object.release(ab, held);
            return error.NoMemory;
        },
    }
}

/// A definition whose object `maybe` is, made: the op done.
fn made(run: *Run, frame: *Frame, path: Path, maybe: ?*Object) Error!void {
    const held = maybe orelse return error.NoMemory;
    _ = try defineName(run, frame, path, held);
    return interpreter.finish(run, frame, .none);
}

/// A name a definition refers to, looked up by the search rules: null,
/// said and counted, where the table's own code refers to one that is
/// not there; an error in a method.
fn referred(run: *Run, frame: *Frame, path: Path, what: [*:0]const u8) Error!?*Node {
    if (namespace.find(run.ab, frame.scope, path, .search)) |node| return node;
    if (loading(run, frame)) |table| {
        load.notThere(table, frame.scope, path, what);
        return null;
    }
    return interpreter.notFound(run, frame.scope, path);
}

fn scopeOp(run: *Run, frame: *Frame, op: *Op) Error!void {
    const inside = try referred(run, frame, op.items[1].path, "the scope") orelse return interpreter.finish(run, frame, .none);
    return interpreter.enterBlock(run, frame, .scope, inside);
}

fn deviceOp(run: *Run, frame: *Frame, op: *Op) Error!void {
    const value: object.Value = switch (op.code) {
        opcodes.DEVICE_OP => .{ .device = {} },
        opcodes.THERMAL_ZONE_OP => .{ .thermal_zone = {} },
        opcodes.PROCESSOR_OP => .{ .processor = .{
            .id = @intCast(op.items[2].integer),
            .block_address = @intCast(op.items[3].integer),
            .block_length = @intCast(op.items[4].integer),
        } },
        else => .{ .power_resource = .{
            .system_level = @intCast(op.items[2].integer),
            .resource_order = @intCast(op.items[3].integer),
        } },
    };
    const held = object.make(run.ab, value) orelse return error.NoMemory;
    const node = try defineName(run, frame, op.items[1].path, held) orelse return interpreter.finish(run, frame, .none);
    return interpreter.enterBlock(run, frame, .scope, node);
}

fn methodOp(run: *Run, frame: *Frame, op: *Op) Error!void {
    const reader = &frame.reader;
    const body = reader.code[reader.at..op.end];
    const held = object.make(run.ab, .{ .method = .{
        .code = body.ptr,
        .length = @intCast(body.len),
        .flags = @intCast(op.items[2].integer),
    } }) orelse return error.NoMemory;
    _ = try defineName(run, frame, op.items[1].path, held);
    return interpreter.finish(run, frame, .none);
}

fn nameOp(run: *Run, frame: *Frame, op: *Op) Error!void {
    const item = op.items[1];
    op.items[1] = .none;
    const held = switch (item) {
        .object => |kept| if (kept.references == 1) kept else copied: {
            defer object.release(run.ab, kept);
            break :copied try convert.copy(run, kept);
        },
        else => interpreter.objectOf(run, item) catch |err| {
            interpreter.release(run.ab, item);
            return err;
        },
    };
    _ = try defineName(run, frame, op.items[0].path, held);
    return interpreter.finish(run, frame, .none);
}

// --- regions and fields ------------------------------------------------------------------

fn regionOp(run: *Run, frame: *Frame, op: *Op) Error!void {
    const region: object.Region = .{
        .space = @intCast(op.items[1].integer),
        .offset = try convert.toInteger(run, op.items[2]),
        .length = try convert.toInteger(run, op.items[3]),
    };
    const held = object.make(run.ab, .{ .region = region }) orelse return error.NoMemory;
    if (try defineName(run, frame, op.items[0].path, held)) |node| region_area.regionMade(run, node);
    return interpreter.finish(run, frame, .none);
}

/// A region over a table the firmware has, found by its signature and
/// its maker's and its own name.
fn dataRegionOp(run: *Run, frame: *Frame, op: *Op) Error!void {
    var texts: [3][]const u8 = undefined;
    for (op.items[1..4], 0..) |item, index| {
        texts[index] = switch (item) {
            .object => |held| switch (held.value) {
                .string => |bytes| bytes.slice(),
                else => return error.Type,
            },
            else => return error.Type,
        };
    }
    if (texts[0].len != 4) return error.Type;
    const table = run.ab.machine.findTable(run.ab, texts[0][0..4], texts[1], texts[2]) orelse {
        _ = namespace.pathText(frame.scope, op.items[0].path, &run.detail);
        run.has_detail = true;
        return error.NotFound;
    };
    const region: object.Region = .{
        .space = hardware_acpi.SPACE_SYSTEM_MEMORY,
        .offset = @intFromPtr(table.ptr),
        .length = table.len,
        .table = true,
    };
    return made(run, frame, op.items[0].path, object.make(run.ab, .{ .region = region }));
}

fn fieldOp(run: *Run, frame: *Frame, op: *Op) Error!void {
    var unit: object.Field = .{ .container = undefined };
    switch (op.code) {
        opcodes.FIELD_OP => {
            unit.kind = .region;
            unit.container = try referred(run, frame, op.items[1].path, "the field's region") orelse return interpreter.finish(run, frame, .none);
        },
        opcodes.INDEX_FIELD_OP => {
            unit.kind = .index;
            unit.container = try referred(run, frame, op.items[1].path, "the index field's index") orelse return interpreter.finish(run, frame, .none);
            unit.second = try referred(run, frame, op.items[2].path, "the index field's data") orelse return interpreter.finish(run, frame, .none);
        },
        else => {
            unit.kind = .bank;
            unit.container = try referred(run, frame, op.items[1].path, "the bank field's region") orelse return interpreter.finish(run, frame, .none);
            unit.second = try referred(run, frame, op.items[2].path, "the bank field's bank") orelse return interpreter.finish(run, frame, .none);
            unit.bank_value = try convert.toInteger(run, op.items[3]);
        },
    }
    const reader = &frame.reader;
    var body = reader.within(reader.at, op.end);
    unit.flags = @intCast(body.number(1) orelse return lost(run, frame, op.start));
    try fieldList(run, frame, &body, unit);
    return interpreter.finish(run, frame, .none);
}

/// An element of a field list that cannot be read: said and counted while
/// the table's own code runs, the rest of the field left out; an error in
/// a method.
fn lost(run: *Run, frame: *Frame, at: usize) Error!void {
    if (loading(run, frame)) |table| {
        load.lostField(table, at, frame.scope);
        return;
    }
    return error.Broken;
}

/// A field's elements, each field unit made as it is met in the frame's
/// scope, `first_unit` holding what the declaration set.
fn fieldList(run: *Run, frame: *Frame, body: *Reader, first_unit: object.Field) Error!void {
    const ab = run.ab;
    var unit = first_unit;
    defer object.release(ab, unit.connection);
    var offset: u64 = 0;
    while (!body.atEnd()) {
        const start = body.at;
        const lead = body.peek().?;
        switch (lead) {
            0x00 => { // a reserved field: bits left out
                body.at += 1;
                offset += body.lengthValue() orelse return lost(run, frame, start);
            },
            0x01, 0x03 => { // AccessAs: how the fields after it are reached
                body.at += 1;
                const access = body.number(1) orelse return lost(run, frame, start);
                const attributes = body.number(1) orelse return lost(run, frame, start);
                unit.flags = (unit.flags & ~object.FIELD_ACCESS) | @as(u8, @intCast(access & 0x0F));
                unit.attributes = @intCast(attributes);
                unit.attribute_kind = @intCast(access >> 6);
                unit.access_length = if (lead == 0x03) @intCast(body.number(1) orelse return lost(run, frame, start)) else 0;
            },
            0x02 => { // Connection: the resource the fields after it are reached through
                body.at += 1;
                const connection = connectionOf(run, frame, body) orelse return lost(run, frame, start);
                object.release(ab, unit.connection);
                unit.connection = connection;
                unit.connection_at = @intCast(@min(offset, 0xFFFF_FFFF));
            },
            else => { // a named field
                if (!namespace.isLead(lead) or body.end - body.at < 4) return lost(run, frame, start);
                const path: Path = .{ .count = 1, .segments = body.code[body.at..].ptr };
                body.at += 4;
                for (namespace.textOf(path.segment(0))[1..]) |char| {
                    if (!namespace.isNameChar(char)) return lost(run, frame, start);
                }
                const width = body.lengthValue() orelse return lost(run, frame, start);
                if (offset + width > 0xFFFF_FFFF) return lost(run, frame, start);
                var this_unit = unit;
                this_unit.bit_offset = @intCast(offset);
                this_unit.bit_length = width;
                if (this_unit.connection) |connection| this_unit.connection = object.retain(connection);
                offset += width;
                const held = object.make(ab, .{ .field_unit = this_unit }) orelse {
                    object.release(ab, this_unit.connection);
                    return error.NoMemory;
                };
                _ = try defineName(run, frame, path, held);
            },
        }
    }
}

/// A Connection's operand: the name of a resource buffer, kept to be
/// looked up when the field is reached, or the buffer itself. Null where
/// the bytes are neither.
fn connectionOf(run: *Run, frame: *Frame, body: *Reader) ?*Object {
    const start = body.at;
    if (body.atName()) {
        _ = body.name() orelse return null;
        const held = object.make(run.ab, .{ .name = .{
            .scope = frame.scope,
            .path = body.code[start..].ptr,
            .length = @intCast(body.at - start),
        } }) orelse return null;
        _ = namespace.hold(frame.scope);
        return held;
    }
    if (body.opcode() != opcodes.BUFFER_OP) {
        body.at = start;
        return null;
    }
    const end = body.pkgEnd() orelse {
        body.at = start;
        return null;
    };
    var inside = body.within(body.at, end);
    body.at = end;
    const size = inside.constant(run.ab.integer_bits) orelse return null;
    const initial = inside.code[inside.at..end];
    return bufferOf(run, size, initial) catch null;
}

/// The bits of a buffer a CreateField term names, made a field of it.
fn bufferFieldOp(run: *Run, frame: *Frame, op: *Op) Error!void {
    const buffer = switch (op.items[0]) {
        .object => |held| switch (held.value) {
            .buffer => held,
            else => return error.Type,
        },
        else => return error.Type,
    };
    const index = try convert.toInteger(run, op.items[1]);
    // A byte's index, or for CreateBitField and CreateField a bit's.
    const bytes_offset = @mulWithOverflow(index, 8);
    var bit_offset: u64 = bytes_offset[0];
    var bit_length: u64 = 0;
    var too_far = bytes_offset[1] != 0;
    const path = switch (op.code) {
        opcodes.CREATE_FIELD_OP => op.items[3].path,
        else => op.items[2].path,
    };
    switch (op.code) {
        opcodes.CREATE_BIT_FIELD_OP => {
            bit_offset = index;
            bit_length = 1;
            too_far = false;
        },
        opcodes.CREATE_BYTE_FIELD_OP => bit_length = 8,
        opcodes.CREATE_WORD_FIELD_OP => bit_length = 16,
        opcodes.CREATE_DWORD_FIELD_OP => bit_length = 32,
        opcodes.CREATE_QWORD_FIELD_OP => bit_length = 64,
        else => { // CreateField: a bit index and a width in bits
            bit_offset = index;
            bit_length = try convert.toInteger(run, op.items[2]);
            too_far = false;
        },
    }
    const size: u64 = @as(u64, buffer.value.buffer.length) * 8;
    if (too_far or bit_length > 0xFFFF_FFFF or bit_offset > size or bit_length > size - bit_offset) {
        _ = namespace.pathText(frame.scope, path, &run.detail);
        run.has_detail = true;
        return error.Range;
    }
    const field: object.BufferField = .{
        .buffer = object.retain(buffer),
        .bit_offset = @intCast(bit_offset),
        .bit_length = @intCast(bit_length),
        .as_buffer = op.code == opcodes.CREATE_FIELD_OP,
    };
    const held = object.make(run.ab, .{ .buffer_field = field }) orelse {
        object.release(run.ab, buffer);
        return error.NoMemory;
    };
    _ = try defineName(run, frame, path, held);
    return interpreter.finish(run, frame, .none);
}

// --- data objects -----------------------------------------------------------------------

/// The most bytes a buffer may have, and the most elements a package.
pub const MOST_BUFFER = 1 << 20;
pub const MOST_ELEMENTS = 1 << 16;

/// A buffer of `size` bytes, or as many as `initial` where that is more,
/// `initial` first and the rest cleared.
pub fn bufferOf(run: *Run, size: u64, initial: []const u8) Error!*Object {
    const length = @max(size, initial.len);
    if (length > MOST_BUFFER) return error.Range;
    const bytes = object.makeBytes(run.ab, @intCast(length)) orelse return error.NoMemory;
    @memcpy(bytes.bytes[0..initial.len], initial);
    return object.make(run.ab, .{ .buffer = bytes }) orelse {
        object.freeBytes(run.ab, bytes);
        return error.NoMemory;
    };
}

fn bufferOp(run: *Run, frame: *Frame, op: *Op) Error!void {
    const size = try convert.toInteger(run, op.items[1]);
    const reader = &frame.reader;
    const held = try bufferOf(run, size, reader.code[reader.at..op.end]);
    return interpreter.finish(run, frame, .{ .object = held });
}

/// Package and VarPackage: the package made, as long as its count says,
/// and filled from the elements that follow (`fill`).
fn packageOp(run: *Run, frame: *Frame, op: *Op) Error!void {
    _ = frame;
    const count = try convert.toInteger(run, op.items[1]);
    if (count > MOST_ELEMENTS) return error.Range;
    const held = object.makePackage(run.ab, @intCast(count)) orelse return error.NoMemory;
    op.items[2] = .{ .object = held };
    op.filling = true;
}

/// The next element of the package the op on top fills worked out, or
/// the package done at its end.
pub fn fill(run: *Run, frame: *Frame, op: *Op) Error!void {
    if (frame.reader.at >= op.end) {
        const result = op.items[2];
        op.items[2] = .none;
        return interpreter.finish(run, frame, result);
    }
    return interpreter.startElement(run, frame);
}

/// `item`, the next element worked out, put into the package `op` fills:
/// one past its count left out.
pub fn element(run: *Run, op: *Op, item: Item) Error!void {
    const package = op.items[2].object.value.package;
    const index = op.count;
    op.count += 1;
    if (index >= package.count) {
        interpreter.release(run.ab, item);
        return;
    }
    package.elements[index] = switch (item) {
        .none => null,
        // An element another holds as well - a local's, a name's - is the
        // package's own copy.
        .object => |held| if (held.references == 1) held else copied: {
            defer object.release(run.ab, held);
            break :copied try convert.copy(run, held);
        },
        .integer => |value| object.makeInteger(run.ab, value) orelse return error.NoMemory,
        else => {
            interpreter.release(run.ab, item);
            return error.Type;
        },
    };
}
