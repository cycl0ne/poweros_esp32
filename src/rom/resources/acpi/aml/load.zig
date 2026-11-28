// SPDX-License-Identifier: MPL-2.0
//! A table loaded: its terms read in order from its first, past the
//! header, and each name it defines made where it says, with what the
//! name holds - the namespace a table describes, built as it is read.
//!
//! **What a term makes.** Scope opens a scope that is there already, the
//! terms inside it read within it; Device, Processor, PowerResource and
//! ThermalZone make a name that is a scope as well. Name makes a name and
//! the data it holds - an integer, a string, a buffer, a package, whose
//! elements may be names, kept to be looked up when they are read. Method
//! makes a name for a body kept where the table has it. Mutex, Event and
//! Alias make what they say; OperationRegion a region, whose address and
//! length are kept as numbers where the table writes them as constants
//! and as bytecode to evaluate otherwise; Field, IndexField and BankField
//! one name for each field unit, in the scope the field is declared in,
//! with its bits counted from the previous one's end; the CreateField
//! family, met outside any method, a field of a buffer whose operands are
//! kept for later. External declares and makes nothing.
//!
//! **Code at a table's own level** - an If, a Store, a call outside any
//! method - is stepped over whole and counted: running it is the
//! executor's.
//!
//! **What goes wrong, and how far.** A name a table defines that is there
//! already - one an earlier table defined - is kept as it was, and the
//! term that defines it again is stepped over, a scope's contents with
//! it. A Scope, or a field's region, that no table has made leaves that
//! term out. An opcode the interpreter does not know, or a term that
//! cannot be read, leaves out the rest of the list it is in - nothing
//! says where the next term would start - and no more: a scope's or a
//! device's body ends where its package says, and the list around it
//! goes on; one inside a buffer or a package loses the Name it is in, one
//! in a field the rest of that field. Each is said in the log, at the
//! table and the offset, and counted (`Loaded`); the rest of the table is
//! loaded all the same.

const sdk = @import("sdk");
const exec = sdk.exec;
const hardware_acpi = sdk.hardware.acpi;
const AcpiBase = @import("../acpi_base.zig").AcpiBase;
const Loaded = @import("../acpi_base.zig").Loaded;
const machine = @import("../machine/_machine.zig");
const namespace = @import("../namespace/_namespace.zig");
const Node = namespace.Node;
const Path = namespace.Path;
const object = @import("../object/_object.zig");
const Object = object.Object;
const aml = @import("_aml.zig");
const Reader = aml.Reader;
const opcodes = @import("opcodes.zig");
const Fault = opcodes.Fault;

/// A table as the loader is given it: its bytes, header first, as long
/// as its header says; its place in the order the tables are loaded,
/// from 1; and its place among the tables with its signature, from 1,
/// for the log ("SSDT 22").
pub const Table = struct {
    code: []const u8,
    index: u16,
    place: u16 = 1,
};

/// Where a table's terms start: past its header.
pub const HEADER_SIZE = 36;

/// `table` loaded into the namespace: what loading it found, which the
/// base's sums count as well. A DSDT sets how wide the namespace's
/// integers are: 32 bits under a revision below 2, 64 from 2.
pub fn loadTable(ab: *AcpiBase, table: Table) Loaded {
    var load: Load = .{ .ab = ab, .table = table };
    if (table.code.len < HEADER_SIZE) {
        load.loaded.broken += 1;
        return finish(&load);
    }
    for (table.code[0..4], 0..) |char, index| load.signature[index] = char;
    if (sameSignature(table.code, "DSDT")) ab.integer_bits = if (table.code[8] < 2) 32 else 64;
    const root = ab.root orelse return finish(&load);
    var reader = Reader.of(table.code, HEADER_SIZE);
    terms(&load, &reader, root);
    return finish(&load);
}

fn finish(load: *Load) Loaded {
    load.ab.tables += 1;
    load.ab.loaded.add(load.loaded);
    return load.loaded;
}

fn sameSignature(code: []const u8, signature: *const [4]u8) bool {
    return code[0] == signature[0] and code[1] == signature[1] and code[2] == signature[2] and code[3] == signature[3];
}

/// A table being loaded: what it is, and what has been found so far.
const Load = struct {
    ab: *AcpiBase,
    table: Table,
    signature: [5]u8 = .{ '?', '?', '?', '?', 0 },
    loaded: Loaded = .{},
};

/// The terms from the reader to its end, in `scope`; those after a term
/// that cannot be read are left out.
fn terms(load: *Load, reader: *Reader, scope: *Node) void {
    while (!reader.atEnd()) {
        if (!term(load, reader, scope)) return;
    }
}

/// The term at the reader, in `scope`. False where the rest of the list
/// cannot be read - an opcode not known, a term past its end - which has
/// been said and counted.
fn term(load: *Load, reader: *Reader, scope: *Node) bool {
    const start = reader.at;
    if (reader.atName()) return levelCode(load, reader, scope);
    const code_at = reader.peekOpcode() orelse return broken(load, start, scope, .rest);
    switch (code_at) {
        opcodes.SCOPE_OP => return scopeTerm(load, reader, scope),
        opcodes.NAME_OP => return nameTerm(load, reader, scope),
        opcodes.METHOD_OP => return methodTerm(load, reader, scope),
        opcodes.DEVICE_OP, opcodes.THERMAL_ZONE_OP, opcodes.PROCESSOR_OP, opcodes.POWER_RES_OP => return deviceTerm(load, reader, scope, code_at),
        opcodes.MUTEX_OP, opcodes.EVENT_OP => return syncTerm(load, reader, scope, code_at),
        opcodes.ALIAS_OP => return aliasTerm(load, reader, scope),
        opcodes.OP_REGION_OP, opcodes.DATA_REGION_OP => return regionTerm(load, reader, scope, code_at),
        opcodes.FIELD_OP, opcodes.INDEX_FIELD_OP, opcodes.BANK_FIELD_OP => return fieldTerm(load, reader, scope, code_at),
        opcodes.CREATE_DWORD_FIELD_OP,
        opcodes.CREATE_WORD_FIELD_OP,
        opcodes.CREATE_BYTE_FIELD_OP,
        opcodes.CREATE_BIT_FIELD_OP,
        opcodes.CREATE_QWORD_FIELD_OP,
        opcodes.CREATE_FIELD_OP,
        => return bufferFieldTerm(load, reader, scope, code_at),
        opcodes.EXTERNAL_OP => return stepOver(load, reader, scope, .rest),
        else => return levelCode(load, reader, scope),
    }
}

/// Code at the table's level, stepped over and counted.
fn levelCode(load: *Load, reader: *Reader, scope: *Node) bool {
    if (!stepOver(load, reader, scope, .rest)) return false;
    load.loaded.code += 1;
    return true;
}

/// The term at the reader stepped over whole; false, said and counted,
/// where it cannot be, as leaving out `left`.
fn stepOver(load: *Load, reader: *Reader, scope: *Node, left: Left) bool {
    var fault: Fault = .{};
    if (opcodes.skip(load.ab, reader, scope, &fault)) return true;
    _ = faulted(load, fault, scope, left);
    return false;
}

/// What a term that cannot be read leaves out: the rest of the list it
/// is in, where nothing says where the next term would start; the term
/// alone, where its package says where it ends; the rest of a field's
/// list.
const Left = enum { rest, term, field };

/// `fault` said and counted, with what it leaves out in `scope`: true
/// where the list it is in goes on after it.
fn faulted(load: *Load, fault: Fault, scope: *Node, left: Left) bool {
    var where: [PATH_ROOM]u8 = undefined;
    _ = namespace.pathOf(scope, &where);
    const leaves: [*:0]const u8 = switch (left) {
        .rest => "the rest of",
        .term => "the term in",
        .field => "the rest of a field in",
    };
    switch (fault.why) {
        .none => {},
        .unknown => {
            load.loaded.unknown += 1;
            machine.log(load.ab, exec.LOG_ERROR, "%s %u: opcode 0x%x at 0x%x not known: %s %s left out\n", .{
                @as([*:0]const u8, @ptrCast(&load.signature)), @as(u32, load.table.place), @as(u32, fault.code), @as(u32, @intCast(fault.at)), leaves, @as([*:0]const u8, @ptrCast(&where)),
            });
        },
        .broken => {
            load.loaded.broken += 1;
            machine.log(load.ab, exec.LOG_ERROR, "%s %u: the term at 0x%x cannot be read: %s %s left out\n", .{
                @as([*:0]const u8, @ptrCast(&load.signature)), @as(u32, load.table.place), @as(u32, @intCast(fault.at)), leaves, @as([*:0]const u8, @ptrCast(&where)),
            });
        },
    }
    return left != .rest;
}

fn broken(load: *Load, at: usize, scope: *Node, left: Left) bool {
    return faulted(load, .{ .why = .broken, .at = at }, scope, left);
}

/// Room for a path in the log.
const PATH_ROOM = 160;

/// `path`, which `scope` refers to, as text for the log.
fn nameText(scope: *Node, path: Path, into: *[PATH_ROOM]u8) [*:0]const u8 {
    var length: usize = 0;
    if (path.root) {
        into[0] = '\\';
        length = 1;
    } else {
        var start = scope;
        var up: u8 = 0;
        while (up < path.parents) : (up += 1) start = start.parent orelse break;
        length = namespace.pathOf(start, into);
        // The root's path is "\\", which the first name follows directly.
        if (length > 1 and path.count > 0 and length + 1 < into.len) {
            into[length] = '.';
            length += 1;
        }
    }
    var index: u8 = 0;
    while (index < path.count) : (index += 1) {
        const text = namespace.textOf(path.segment(index));
        var shown: usize = 4;
        while (shown > 1 and text[shown - 1] == '_') shown -= 1;
        for (text[0..shown]) |char| {
            if (length + 1 < into.len) into[length] = char;
            length += 1;
        }
        if (index + 1 < path.count and length + 1 < into.len) {
            into[length] = '.';
            length += 1;
        }
    }
    into[@min(length, into.len - 1)] = 0;
    return @ptrCast(into);
}

/// `held` given the name `path` names from `scope`, which is made: the
/// node, or null - the name there already, or its scope missing - with
/// `held` let go of and what happened said and counted.
fn define(load: *Load, scope: *Node, path: Path, held: ?*Object) ?*Node {
    const ab = load.ab;
    var text: [PATH_ROOM]u8 = undefined;
    switch (namespace.create(ab, scope, path, load.table.index)) {
        .made => |node| {
            node.object = held;
            load.loaded.names += 1;
            return node;
        },
        .there => |node| {
            load.loaded.again += 1;
            _ = namespace.pathOf(node, &text);
            machine.log(ab, exec.LOG_WARNING, "%s %u: %s defined again, the first kept\n", .{
                @as([*:0]const u8, @ptrCast(&load.signature)), @as(u32, load.table.place), @as([*:0]const u8, @ptrCast(&text)),
            });
        },
        .missing => {
            load.loaded.missing += 1;
            machine.log(ab, exec.LOG_WARNING, "%s %u: %s is defined in a scope that is not there, and left out\n", .{
                @as([*:0]const u8, @ptrCast(&load.signature)), @as(u32, load.table.place), nameText(scope, path, &text),
            });
        },
        .no_memory => {
            load.loaded.broken += 1;
            machine.log(ab, exec.LOG_ERROR, "%s %u: no memory for %s\n", .{
                @as([*:0]const u8, @ptrCast(&load.signature)), @as(u32, load.table.place), nameText(scope, path, &text),
            });
        },
    }
    object.release(ab, held);
    return null;
}

/// An object `make`s, said and counted where there is no memory for it.
fn made(load: *Load, held: ?*Object) ?*Object {
    if (held == null) {
        load.loaded.broken += 1;
        machine.log(load.ab, exec.LOG_ERROR, "%s %u: no memory\n", .{ @as([*:0]const u8, @ptrCast(&load.signature)), @as(u32, load.table.place) });
    }
    return held;
}

/// A name the term refers to, looked up by the search rules: null, said
/// and counted, where it is not there.
fn referred(load: *Load, scope: *Node, path: Path, what: [*:0]const u8) ?*Node {
    if (namespace.find(load.ab, scope, path, .search)) |node| return node;
    load.loaded.missing += 1;
    var text: [PATH_ROOM]u8 = undefined;
    machine.log(load.ab, exec.LOG_WARNING, "%s %u: %s %s is not there, and what it is for left out\n", .{
        @as([*:0]const u8, @ptrCast(&load.signature)), @as(u32, load.table.place), what, nameText(scope, path, &text),
    });
    return null;
}

// --- the terms ----------------------------------------------------------------------

/// The opcode, the package's end and the name behind it: what most
/// defining terms start with. Null, said and counted, where the bytes are
/// not that - with the reader at the package's end where that could be
/// read, so that the list goes on after it (`goesOn`), and where it was
/// otherwise.
const Opened = struct { end: usize, path: Path };

fn open(load: *Load, reader: *Reader, scope: *Node) ?Opened {
    const start = reader.at;
    _ = reader.opcode();
    const end = reader.pkgEnd() orelse {
        _ = broken(load, start, scope, .rest);
        reader.at = start;
        return null;
    };
    const path = reader.name() orelse {
        _ = broken(load, start, scope, .term);
        reader.at = end;
        return null;
    };
    return .{ .end = end, .path = path };
}

/// Whether the list goes on after a term that could not be read: where
/// the reader was moved past it.
fn goesOn(reader: *const Reader, start: usize) bool {
    return reader.at != start;
}

/// A term inside a package whose end is known that could not be read:
/// said and counted, and the list goes on after the package.
fn skipped(load: *Load, at: usize, scope: *Node) bool {
    return broken(load, at, scope, .term);
}

fn scopeTerm(load: *Load, reader: *Reader, scope: *Node) bool {
    const start = reader.at;
    const opened = open(load, reader, scope) orelse return goesOn(reader, start);
    defer reader.at = opened.end;
    const inside = referred(load, scope, opened.path, "the scope") orelse return true;
    var body = reader.within(reader.at, opened.end);
    terms(load, &body, inside);
    return true;
}

fn deviceTerm(load: *Load, reader: *Reader, scope: *Node, code_at: u16) bool {
    const start = reader.at;
    const opened = open(load, reader, scope) orelse return goesOn(reader, start);
    defer reader.at = opened.end;
    const value: object.Value = switch (code_at) {
        opcodes.DEVICE_OP => .{ .device = {} },
        opcodes.THERMAL_ZONE_OP => .{ .thermal_zone = {} },
        opcodes.PROCESSOR_OP => .{ .processor = .{
            .id = @intCast(reader.number(1) orelse return skipped(load, start, scope)),
            .block_address = @intCast(reader.number(4) orelse return skipped(load, start, scope)),
            .block_length = @intCast(reader.number(1) orelse return skipped(load, start, scope)),
        } },
        else => .{ .power_resource = .{
            .system_level = @intCast(reader.number(1) orelse return skipped(load, start, scope)),
            .resource_order = @intCast(reader.number(2) orelse return skipped(load, start, scope)),
        } },
    };
    const held = made(load, object.make(load.ab, value)) orelse return true;
    const node = define(load, scope, opened.path, held) orelse return true;
    var body = reader.within(reader.at, opened.end);
    terms(load, &body, node);
    return true;
}

fn methodTerm(load: *Load, reader: *Reader, scope: *Node) bool {
    const start = reader.at;
    const opened = open(load, reader, scope) orelse return goesOn(reader, start);
    defer reader.at = opened.end;
    const flags: u8 = @intCast(reader.number(1) orelse return skipped(load, start, scope));
    const body = reader.code[reader.at..opened.end];
    const held = made(load, object.make(load.ab, .{ .method = .{
        .code = body.ptr,
        .length = @intCast(body.len),
        .flags = flags,
    } })) orelse return true;
    _ = define(load, scope, opened.path, held);
    return true;
}

fn nameTerm(load: *Load, reader: *Reader, scope: *Node) bool {
    const start = reader.at;
    _ = reader.opcode();
    const path = reader.name() orelse return broken(load, start, scope, .rest);
    var fault: Fault = .{};
    const data_at = reader.at;
    const held = data(load, reader, scope, &fault) orelse {
        if (fault.why == .none) return true; // no memory, said
        // Inside a buffer or a package, whose end is known, the term
        // alone is lost.
        return faulted(load, fault, scope, if (reader.at != data_at) .term else .rest);
    };
    _ = define(load, scope, path, held);
    return true;
}

fn syncTerm(load: *Load, reader: *Reader, scope: *Node, code_at: u16) bool {
    const start = reader.at;
    _ = reader.opcode();
    const path = reader.name() orelse return broken(load, start, scope, .rest);
    const value: object.Value = if (code_at == opcodes.MUTEX_OP)
        .{ .mutex = .{ .sync_level = @intCast((reader.number(1) orelse return broken(load, start, scope, .rest)) & 0x0F) } }
    else
        .{ .event = {} };
    const held = made(load, object.make(load.ab, value)) orelse return true;
    _ = define(load, scope, path, held);
    return true;
}

fn aliasTerm(load: *Load, reader: *Reader, scope: *Node) bool {
    const start = reader.at;
    _ = reader.opcode();
    const source = reader.name() orelse return broken(load, start, scope, .rest);
    const alias = reader.name() orelse return broken(load, start, scope, .rest);
    const node = referred(load, scope, source, "the alias's object") orelse return true;
    const held = made(load, object.make(load.ab, .{ .alias = node })) orelse return true;
    _ = define(load, scope, alias, held);
    return true;
}

/// The operands from `start` to the reader, kept for later in `scope`.
fn deferredOf(reader: *const Reader, start: usize, scope: *Node, code_at: u16) object.Deferred {
    return .{ .scope = scope, .code = reader.code[start..].ptr, .length = @intCast(reader.at - start), .opcode = code_at };
}

fn regionTerm(load: *Load, reader: *Reader, scope: *Node, code_at: u16) bool {
    const start = reader.at;
    _ = reader.opcode();
    const path = reader.name() orelse return broken(load, start, scope, .rest);
    var region: object.Region = .{};
    if (code_at == opcodes.DATA_REGION_OP) {
        // The signature, the maker's and the table's name of the table
        // the region covers, which is in memory.
        region.space = hardware_acpi.SPACE_SYSTEM_MEMORY;
        region.table = true;
        const operands = reader.at;
        var index: u32 = 0;
        while (index < 3) : (index += 1) {
            if (!stepOver(load, reader, scope, .rest)) return false;
        }
        region.deferred = deferredOf(reader, operands, scope, code_at);
    } else {
        region.space = @intCast(reader.number(1) orelse return broken(load, start, scope, .rest));
        const operands = reader.at;
        const bits = load.ab.integer_bits;
        const offset = reader.constant(bits);
        const length = if (offset != null) reader.constant(bits) else null;
        if (offset != null and length != null) {
            region.offset = offset.?;
            region.length = length.?;
        } else {
            reader.at = operands;
            if (!stepOver(load, reader, scope, .rest) or !stepOver(load, reader, scope, .rest)) return false;
            region.deferred = deferredOf(reader, operands, scope, code_at);
        }
    }
    const held = made(load, object.make(load.ab, .{ .region = region })) orelse return true;
    _ = define(load, scope, path, held);
    return true;
}

fn bufferFieldTerm(load: *Load, reader: *Reader, scope: *Node, code_at: u16) bool {
    const start = reader.at;
    _ = reader.opcode();
    const operands = reader.at;
    const count: u32 = if (code_at == opcodes.CREATE_FIELD_OP) 3 else 2;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        if (!stepOver(load, reader, scope, .rest)) return false;
    }
    const kept = deferredOf(reader, operands, scope, code_at);
    const path = reader.name() orelse return broken(load, start, scope, .rest);
    const held = made(load, object.make(load.ab, .{ .buffer_field = kept })) orelse return true;
    _ = define(load, scope, path, held);
    return true;
}

fn fieldTerm(load: *Load, reader: *Reader, scope: *Node, code_at: u16) bool {
    const start = reader.at;
    _ = reader.opcode();
    const end = reader.pkgEnd() orelse return broken(load, start, scope, .rest);
    defer reader.at = end;
    var body = reader.within(reader.at, end);
    const first = body.name() orelse return skipped(load, start, scope);
    var unit: object.Field = .{ .container = undefined };
    switch (code_at) {
        opcodes.FIELD_OP => {
            unit.kind = .region;
            unit.container = referred(load, scope, first, "the field's region") orelse return true;
        },
        opcodes.INDEX_FIELD_OP => {
            unit.kind = .index;
            const data_path = body.name() orelse return skipped(load, start, scope);
            unit.container = referred(load, scope, first, "the index field's index") orelse return true;
            unit.second = referred(load, scope, data_path, "the index field's data") orelse return true;
        },
        else => {
            unit.kind = .bank;
            const bank_path = body.name() orelse return skipped(load, start, scope);
            unit.container = referred(load, scope, first, "the bank field's region") orelse return true;
            unit.second = referred(load, scope, bank_path, "the bank field's bank") orelse return true;
            const operand = body.at;
            if (body.constant(load.ab.integer_bits)) |value| {
                unit.bank_value = value;
            } else {
                if (!stepOver(load, &body, scope, .term)) return true;
                unit.bank_deferred = deferredOf(&body, operand, scope, code_at);
            }
        },
    }
    unit.flags = @intCast(body.number(1) orelse return skipped(load, start, scope));
    fieldList(load, &body, scope, unit);
    return true;
}

/// A field's elements, each field unit made as it is met in `scope`,
/// `unit` holding what the ones before it set. An element that cannot be
/// read leaves out the rest of the field, which has been said.
fn fieldList(load: *Load, body: *Reader, scope: *Node, first_unit: object.Field) void {
    var unit = first_unit;
    defer object.release(load.ab, unit.connection);
    var offset: u64 = 0;
    while (!body.atEnd()) {
        const start = body.at;
        const lead = body.peek().?;
        switch (lead) {
            0x00 => { // a reserved field: bits left out
                body.at += 1;
                offset += body.lengthValue() orelse return lost(load, start, scope);
            },
            0x01, 0x03 => { // AccessAs: how the fields after it are reached
                body.at += 1;
                const access = body.number(1) orelse return lost(load, start, scope);
                const attributes = body.number(1) orelse return lost(load, start, scope);
                unit.flags = (unit.flags & ~object.FIELD_ACCESS) | @as(u8, @intCast(access & 0x0F));
                unit.attributes = @intCast(attributes);
                unit.attribute_kind = @intCast(access >> 6);
                unit.access_length = if (lead == 0x03) @intCast(body.number(1) orelse return lost(load, start, scope)) else 0;
            },
            0x02 => { // Connection: the resource the fields after it are reached through
                body.at += 1;
                var fault: Fault = .{};
                const connection = if (body.atName()) blk: {
                    const name_start = body.at;
                    _ = body.name() orelse return lost(load, start, scope);
                    break :blk made(load, object.make(load.ab, .{ .name = .{
                        .scope = scope,
                        .path = body.code[name_start..].ptr,
                        .length = @intCast(body.at - name_start),
                    } }));
                } else data(load, body, scope, &fault);
                if (connection == null and fault.why != .none) {
                    _ = faulted(load, fault, scope, .field);
                    return;
                }
                object.release(load.ab, unit.connection);
                unit.connection = connection;
            },
            else => { // a named field
                if (!namespace.isLead(lead) or body.end - body.at < 4) return lost(load, start, scope);
                const path: Path = .{ .count = 1, .segments = body.code[body.at..].ptr };
                body.at += 4;
                for (namespace.textOf(path.segment(0))[1..]) |char| {
                    if (!namespace.isNameChar(char)) return lost(load, start, scope);
                }
                const width = body.lengthValue() orelse return lost(load, start, scope);
                if (offset + width > 0xFFFF_FFFF) return lost(load, start, scope);
                var this_unit = unit;
                this_unit.bit_offset = @intCast(offset);
                this_unit.bit_length = width;
                if (this_unit.connection) |connection| this_unit.connection = object.retain(connection);
                offset += width;
                const held = made(load, object.make(load.ab, .{ .field_unit = this_unit })) orelse {
                    object.release(load.ab, this_unit.connection);
                    continue;
                };
                _ = define(load, scope, path, held);
            },
        }
    }
}

/// An element of a field list that cannot be read: said and counted.
fn lost(load: *Load, at: usize, scope: *Node) void {
    _ = broken(load, at, scope, .field);
}

// --- data --------------------------------------------------------------------------

/// The data object at the reader, read in `scope`: an object held once.
/// Null without memory (said), or with `fault` filled in where the
/// bytes are no data object the loader can make - the reader then past
/// a buffer or a package whose end could be read, and where it was
/// otherwise.
fn data(load: *Load, reader: *Reader, scope: *Node, fault: *Fault) ?*Object {
    const ab = load.ab;
    const start = reader.at;
    if (reader.constant(ab.integer_bits)) |value| return made(load, object.makeInteger(ab, value));
    const code_at = reader.opcode() orelse return failedData(fault, .broken, start, 0);
    switch (code_at) {
        aml.STRING_PREFIX => {
            const text = reader.string() orelse return unread(reader, fault, .broken, start, code_at);
            return made(load, object.makeString(ab, text));
        },
        opcodes.BUFFER_OP => {
            const end = reader.pkgEnd() orelse return unread(reader, fault, .broken, start, code_at);
            var body = reader.within(reader.at, end);
            reader.at = end;
            var size: u64 = 0;
            if (body.constant(ab.integer_bits)) |declared| {
                size = declared;
            } else if (!opcodes.skip(ab, &body, scope, fault)) return null;
            const initial = body.code[body.at..end];
            const length = @max(size, initial.len);
            if (length > MOST_BUFFER) return failedData(fault, .broken, start, code_at);
            const bytes = object.makeBytes(ab, @intCast(length)) orelse return made(load, null);
            @memcpy(bytes.bytes[0..initial.len], initial);
            return made(load, object.make(ab, .{ .buffer = bytes })) orelse {
                object.freeBytes(ab, bytes);
                return null;
            };
        },
        opcodes.PACKAGE_OP, opcodes.VAR_PACKAGE_OP => {
            const end = reader.pkgEnd() orelse return unread(reader, fault, .broken, start, code_at);
            var body = reader.within(reader.at, end);
            reader.at = end;
            var declared: ?u64 = null;
            if (code_at == opcodes.PACKAGE_OP) {
                declared = body.number(1) orelse return failedData(fault, .broken, start, code_at);
            } else if (body.constant(ab.integer_bits)) |count| {
                declared = count;
            } else if (!opcodes.skip(ab, &body, scope, fault)) return null;
            return package(load, &body, scope, declared, fault);
        },
        else => return unread(reader, fault, .unknown, start, code_at),
    }
}

/// A data object that could not be read, with the reader back at its
/// start: nothing says where it ends.
fn unread(reader: *Reader, fault: *Fault, why: Fault.Why, start: usize, code_at: u16) ?*Object {
    reader.at = start;
    return failedData(fault, why, start, code_at);
}

/// The most bytes a buffer the loader makes may have.
const MOST_BUFFER = 1 << 20;

fn failedData(fault: *Fault, why: Fault.Why, at: usize, code_at: u16) ?*Object {
    fault.* = .{ .why = why, .at = at, .code = code_at };
    return null;
}

/// A package's elements from the reader to its end: as many as
/// `declared` - those past it left out, those it has more of than are
/// written null - or, where the count is an expression, as many as are
/// written.
fn package(load: *Load, body: *Reader, scope: *Node, declared: ?u64, fault: *Fault) ?*Object {
    const ab = load.ab;
    const count: u32 = if (declared) |value| @intCast(@min(value, MOST_ELEMENTS)) else blk: {
        var counter = body.*;
        var written: u32 = 0;
        while (!counter.atEnd()) : (written += 1) {
            if (counter.atName()) {
                _ = counter.name() orelse return failedData(fault, .broken, counter.at, 0);
            } else if (!opcodes.skip(ab, &counter, scope, fault)) return null;
        }
        break :blk written;
    };
    const held = made(load, object.makePackage(ab, count)) orelse return null;
    const elements = held.value.package.elements;
    var index: u32 = 0;
    while (!body.atEnd()) : (index += 1) {
        if (index >= count) break; // more written than declared: left out
        if (body.atName()) {
            const name_start = body.at;
            _ = body.name() orelse {
                object.release(ab, held);
                return failedData(fault, .broken, name_start, 0);
            };
            elements[index] = made(load, object.make(ab, .{ .name = .{
                .scope = scope,
                .path = body.code[name_start..].ptr,
                .length = @intCast(body.at - name_start),
            } }));
        } else {
            elements[index] = data(load, body, scope, fault) orelse {
                object.release(ab, held);
                return null;
            };
        }
    }
    return held;
}

/// The most elements a package the loader makes may have.
const MOST_ELEMENTS = 1 << 16;

// --- tests ------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;
const testmachine = @import("../tests/machine.zig");
const builder = @import("../tests/builder.zig");
const Table_ = builder.Table;

fn found(ab: *AcpiBase, path: [*:0]const u8) ?*Node {
    var text: namespace.TextPath = undefined;
    if (!namespace.parseText(path, &text)) return null;
    return namespace.find(ab, ab.root.?, text.path, .exact);
}

fn heldAt(ab: *AcpiBase, path: [*:0]const u8) !*Object {
    const node = found(ab, path) orelse return error.NotFound;
    return node.object orelse error.Empty;
}

fn integerAt(ab: *AcpiBase, path: [*:0]const u8) !u64 {
    const held = try heldAt(ab, path);
    return switch (held.value) {
        .integer => |value| value,
        else => error.NotAnInteger,
    };
}

fn nothing(_: *Table_) anyerror!void {}

test "every kind of name is made where the table says, holding what it says" {
    var test_machine: testmachine.TestMachine = .{};
    const ab = test_machine.base();
    try testing.expect(namespace.make(ab));
    defer namespace.discard(ab);
    var table = Table_.init(testing.allocator, "DSDT", 2);
    defer table.deinit();
    try table.nameInteger("INT0", 0x1234_5678_9ABC);
    try table.nameText("STR0", "text");
    try table.nameOf("BUF0", struct {
        fn data(it: *Table_) anyerror!void {
            try it.buffer(8, &.{ 1, 2, 3 });
        }
    }.data);
    try table.nameOf("BUF1", struct {
        fn data(it: *Table_) anyerror!void {
            try it.buffer(2, &.{ 1, 2, 3, 4 });
        }
    }.data);
    try table.nameOf("PKG0", struct {
        fn data(it: *Table_) anyerror!void {
            try it.packageOf(3, struct {
                fn elements(list: *Table_) anyerror!void {
                    try list.integer(5);
                    try list.string("five");
                    try list.name("INT0");
                }
            }.elements);
        }
    }.data);
    try table.nameOf("PKG1", struct {
        fn data(it: *Table_) anyerror!void {
            try it.packageOf(4, struct {
                fn elements(list: *Table_) anyerror!void {
                    try list.integer(1);
                }
            }.elements);
        }
    }.data);
    try table.nameOf("PKG2", struct {
        fn data(it: *Table_) anyerror!void {
            try it.packageOf(1, struct {
                fn elements(list: *Table_) anyerror!void {
                    try list.integer(1);
                    try list.integer(2);
                }
            }.elements);
        }
    }.data);
    try table.method("MTH0", 0x0B, &.{ 0xA4, 0x01 }); // three arguments, serialized: Return (One)
    try table.mutex("MUT0", 0x17);
    try table.event("EVT0");
    try table.alias("INT0", "INT1");
    try table.processor("\\_PR.CPU0", 1, 0x810, 6, nothing);
    try table.powerResource("PWR0", 0, 1, nothing);
    try table.thermalZone("\\_TZ.TZ00", nothing);
    try table.external("\\_SB.XTRN", 8, 2);
    try table.region("REG0", 1, 0x80, 4);
    try table.field("REG0", 0x01, &.{
        .{ .name = "FLD0", .bits = 8 },
        .{ .bits = 4 },
        .{ .name = "FLD1", .bits = 4 },
        .{ .access = .{ 0x43, 0 } },
        .{ .name = "FLD2", .bits = 16 },
    });
    // CreateDWordField (BUF0, 0x04, CDW0), outside any method.
    try table.raw(&.{0x8A});
    try table.name("BUF0");
    try table.integer(4);
    try table.name("CDW0");
    const loaded = loadTable(ab, .{ .code = try table.finish(), .index = 1 });

    try testing.expectEqual(@as(u32, 19), loaded.names);
    try testing.expectEqual(@as(u32, 0), loaded.code + loaded.again + loaded.missing + loaded.unknown + loaded.broken);
    try testing.expectEqual(@as(u32, 0), test_machine.lines);
    try testing.expectEqual(@as(u16, 1), ab.tables);

    try testing.expectEqual(@as(u64, 0x1234_5678_9ABC), try integerAt(ab, "INT0"));
    try testing.expectEqualStrings("text", (try heldAt(ab, "STR0")).value.string.slice());
    const buffer = (try heldAt(ab, "BUF0")).value.buffer;
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 0, 0, 0, 0, 0 }, buffer.slice());
    // A buffer is as long as it is declared or as its bytes, whichever is more.
    try testing.expectEqual(@as(u32, 4), (try heldAt(ab, "BUF1")).value.buffer.length);

    const elements = (try heldAt(ab, "PKG0")).value.package;
    try testing.expectEqual(@as(u32, 3), elements.count);
    try testing.expectEqual(@as(u64, 5), elements.elements[0].?.value.integer);
    try testing.expectEqualStrings("five", elements.elements[1].?.value.string.slice());
    const reference = elements.elements[2].?.value.name;
    try testing.expectEqualSlices(u8, "INT0", reference.path[0..reference.length]);
    // Declared longer than written: the rest null. Written longer than
    // declared: the rest left out.
    const longer = (try heldAt(ab, "PKG1")).value.package;
    try testing.expectEqual(@as(u32, 4), longer.count);
    try testing.expect(longer.elements[1] == null and longer.elements[3] == null);
    try testing.expectEqual(@as(u32, 1), (try heldAt(ab, "PKG2")).value.package.count);

    const method = (try heldAt(ab, "MTH0")).value.method;
    try testing.expectEqual(@as(u8, 3), method.args());
    try testing.expect(method.flags & object.METHOD_SERIALIZED != 0);
    try testing.expectEqualSlices(u8, &.{ 0xA4, 0x01 }, method.code.?[0..method.length]);
    try testing.expectEqual(@as(u8, 7), (try heldAt(ab, "MUT0")).value.mutex.sync_level);
    try testing.expectEqual(object.Kind.event, (try heldAt(ab, "EVT0")).kind());
    try testing.expectEqual(found(ab, "INT0").?, namespace.target(found(ab, "INT1").?));

    const cpu = (try heldAt(ab, "\\_PR.CPU0")).value.processor;
    try testing.expectEqual(@as(u8, 1), cpu.id);
    try testing.expectEqual(@as(u32, 0x810), cpu.block_address);
    try testing.expectEqual(@as(u8, 6), cpu.block_length);
    try testing.expectEqual(@as(u16, 1), (try heldAt(ab, "PWR0")).value.power_resource.resource_order);
    try testing.expectEqual(object.Kind.thermal_zone, (try heldAt(ab, "\\_TZ.TZ00")).kind());
    // External declares and makes nothing.
    try testing.expect(found(ab, "\\_SB.XTRN") == null);

    const region = (try heldAt(ab, "REG0")).value.region;
    try testing.expectEqual(@as(u8, 1), region.space);
    try testing.expectEqual(@as(u64, 0x80), region.offset);
    try testing.expectEqual(@as(u64, 4), region.length);
    try testing.expect(region.deferred == null);
    const first = (try heldAt(ab, "FLD0")).value.field_unit;
    try testing.expectEqual(found(ab, "REG0").?, first.container);
    try testing.expectEqual(@as(u32, 0), first.bit_offset);
    try testing.expectEqual(@as(u32, 8), first.bit_length);
    try testing.expectEqual(object.ACCESS_BYTE, first.access());
    // Counted on from the reserved bits; the AccessAs before the last
    // makes it a dword's, of the first attribute kind.
    try testing.expectEqual(@as(u32, 12), (try heldAt(ab, "FLD1")).value.field_unit.bit_offset);
    const last = (try heldAt(ab, "FLD2")).value.field_unit;
    try testing.expectEqual(@as(u32, 16), last.bit_offset);
    try testing.expectEqual(object.ACCESS_DWORD, last.access());
    try testing.expectEqual(@as(u8, 1), last.attribute_kind);

    const created = (try heldAt(ab, "CDW0")).value.buffer_field;
    try testing.expectEqual(opcodes.CREATE_DWORD_FIELD_OP, created.opcode);
    try testing.expectEqual(@as(u32, 6), created.length); // BUF0, 0x04
}

test "index and bank fields reach their registers, and a region written with expressions is kept to be worked out" {
    var test_machine: testmachine.TestMachine = .{};
    const ab = test_machine.base();
    try testing.expect(namespace.make(ab));
    defer namespace.discard(ab);
    var table = Table_.init(testing.allocator, "SSDT", 2);
    defer table.deinit();
    try table.region("REG0", 1, 0x70, 2);
    try table.field("REG0", 0x01, &.{ .{ .name = "IDX0", .bits = 8 }, .{ .name = "DAT0", .bits = 8 } });
    try table.indexField("IDX0", "DAT0", 0x01, &.{ .{ .name = "IF00", .bits = 8 }, .{ .name = "IF01", .bits = 8 } });
    try table.bankField("REG0", "IDX0", 2, 0x01, &.{.{ .name = "BK00", .bits = 8 }});
    try table.nameInteger("BASE", 0x1000);
    // OperationRegion (REG1, SystemMemory, BASE, 0x10)
    try table.raw(&.{ 0x5B, 0x80 });
    try table.name("REG1");
    try table.raw(&.{0x00});
    try table.name("BASE");
    try table.integer(0x10);
    // OperationRegion (REG2, SystemIO, Add (BASE, 4), 8)
    try table.raw(&.{ 0x5B, 0x80 });
    try table.name("REG2");
    try table.raw(&.{ 0x01, 0x72 });
    try table.name("BASE");
    try table.raw(&.{ 0x0A, 0x04, 0x00 });
    try table.integer(8);
    try table.nameInteger("LAST", 1);
    const loaded = loadTable(ab, .{ .code = try table.finish(), .index = 1 });
    try testing.expectEqual(@as(u32, 0), loaded.code + loaded.again + loaded.missing + loaded.unknown + loaded.broken);
    try testing.expectEqual(@as(u32, 10), loaded.names);

    const index = (try heldAt(ab, "IF01")).value.field_unit;
    try testing.expectEqual(object.FieldKind.index, index.kind);
    try testing.expectEqual(found(ab, "IDX0").?, index.container);
    try testing.expectEqual(found(ab, "DAT0").?, index.second.?);
    try testing.expectEqual(@as(u32, 8), index.bit_offset);
    const bank = (try heldAt(ab, "BK00")).value.field_unit;
    try testing.expectEqual(object.FieldKind.bank, bank.kind);
    try testing.expectEqual(found(ab, "REG0").?, bank.container);
    try testing.expectEqual(found(ab, "IDX0").?, bank.second.?);
    try testing.expectEqual(@as(u64, 2), bank.bank_value);

    const by_name = (try heldAt(ab, "REG1")).value.region;
    try testing.expectEqual(@as(u32, 6), by_name.deferred.?.length); // BASE, 0x10
    try testing.expectEqual(@as(u64, 0), by_name.offset);
    const by_sum = (try heldAt(ab, "REG2")).value.region;
    try testing.expectEqual(@as(u8, 1), by_sum.space);
    try testing.expectEqual(@as(u32, 10), by_sum.deferred.?.length); // Add (BASE, 0x04, Zero), 0x08
    try testing.expectEqual(@as(u64, 1), try integerAt(ab, "LAST"));
}

test "a name defined again keeps the first, and the term that defines it again is left out whole" {
    var test_machine: testmachine.TestMachine = .{};
    const ab = test_machine.base();
    try testing.expect(namespace.make(ab));
    defer namespace.discard(ab);
    var first = Table_.init(testing.allocator, "DSDT", 2);
    defer first.deinit();
    try first.device("\\_SB.DEV0", struct {
        fn body(device: *Table_) anyerror!void {
            try device.nameInteger("_ADR", 1);
        }
    }.body);
    try first.device("\\_SB.DEV0", struct {
        fn body(device: *Table_) anyerror!void {
            try device.nameInteger("_ADR", 2);
            try device.nameInteger("NEW0", 3);
        }
    }.body);
    try first.nameInteger("INT0", 1);
    try first.nameInteger("INT0", 2);
    try first.nameInteger("LAST", 9);
    const loaded = loadTable(ab, .{ .code = try first.finish(), .index = 1 });
    try testing.expectEqual(@as(u32, 2), loaded.again);
    try testing.expectEqual(@as(u32, 4), loaded.names);
    try testing.expectEqual(@as(u64, 1), try integerAt(ab, "\\_SB.DEV0._ADR"));
    try testing.expect(found(ab, "\\_SB.DEV0.NEW0") == null);
    try testing.expectEqual(@as(u64, 1), try integerAt(ab, "INT0"));
    try testing.expectEqual(@as(u64, 9), try integerAt(ab, "LAST"));

    // A later table that defines one of the first's names again.
    var second = Table_.init(testing.allocator, "SSDT", 2);
    defer second.deinit();
    try second.scope("\\_SB.DEV0", struct {
        fn body(device: *Table_) anyerror!void {
            try device.nameInteger("_ADR", 5);
            try device.nameInteger("NEW1", 6);
        }
    }.body);
    const more = loadTable(ab, .{ .code = try second.finish(), .index = 2, .place = 1 });
    try testing.expectEqual(@as(u32, 1), more.again);
    try testing.expectEqual(@as(u32, 1), more.names);
    try testing.expectEqual(@as(u64, 1), try integerAt(ab, "\\_SB.DEV0._ADR"));
    try testing.expectEqual(@as(u64, 6), try integerAt(ab, "\\_SB.DEV0.NEW1"));
    try testing.expectEqual(@as(u16, 2), found(ab, "\\_SB.DEV0.NEW1").?.table);
    // The base sums both tables, and each was said.
    try testing.expectEqual(@as(u32, 3), ab.loaded.again);
    try testing.expectEqual(@as(u32, 3), test_machine.lines);
}

test "a scope, or a field's region, that is not there is left out, and the table goes on after it" {
    var test_machine: testmachine.TestMachine = .{};
    const ab = test_machine.base();
    try testing.expect(namespace.make(ab));
    defer namespace.discard(ab);
    var table = Table_.init(testing.allocator, "SSDT", 2);
    defer table.deinit();
    try table.scope("\\_SB.NONE", struct {
        fn body(inner: *Table_) anyerror!void {
            try inner.nameInteger("LOST", 1);
        }
    }.body);
    try table.field("NONE", 0x01, &.{.{ .name = "GONE", .bits = 8 }});
    try table.nameInteger("KEPT", 2);
    const loaded = loadTable(ab, .{ .code = try table.finish(), .index = 1 });
    try testing.expectEqual(@as(u32, 2), loaded.missing);
    try testing.expectEqual(@as(u32, 1), loaded.names);
    try testing.expect(found(ab, "LOST") == null and found(ab, "GONE") == null);
    try testing.expectEqual(@as(u64, 2), try integerAt(ab, "KEPT"));
    try testing.expectEqual(@as(u32, 2), test_machine.lines);
}

test "an opcode not known leaves out the rest of its list, and nothing outside it" {
    var test_machine: testmachine.TestMachine = .{};
    const ab = test_machine.base();
    try testing.expect(namespace.make(ab));
    defer namespace.discard(ab);
    var table = Table_.init(testing.allocator, "SSDT", 2);
    defer table.deinit();
    try table.device("\\_SB.DEV0", struct {
        fn body(device: *Table_) anyerror!void {
            try device.nameInteger("BFOR", 1);
            try device.raw(&.{ 0x5B, 0x99 });
            try device.nameInteger("AFTR", 2);
        }
    }.body);
    // A package with an element that is no data object: that Name alone.
    try table.nameOf("PKG0", struct {
        fn data(it: *Table_) anyerror!void {
            try it.packageOf(2, struct {
                fn elements(list: *Table_) anyerror!void {
                    try list.integer(1);
                    try list.raw(&.{0x70});
                }
            }.elements);
        }
    }.data);
    try table.nameInteger("NEXT", 3);
    const loaded = loadTable(ab, .{ .code = try table.finish(), .index = 1 });
    try testing.expectEqual(@as(u32, 2), loaded.unknown);
    try testing.expect(found(ab, "\\_SB.DEV0.BFOR") != null);
    try testing.expect(found(ab, "\\_SB.DEV0.AFTR") == null);
    try testing.expect(found(ab, "PKG0") == null);
    try testing.expectEqual(@as(u64, 3), try integerAt(ab, "NEXT"));
}

test "code outside any method is counted and stepped over whole, a call with its arguments" {
    var test_machine: testmachine.TestMachine = .{};
    const ab = test_machine.base();
    try testing.expect(namespace.make(ab));
    defer namespace.discard(ab);
    var table = Table_.init(testing.allocator, "SSDT", 2);
    defer table.deinit();
    // If (One) { Name (INSD, 5) }
    try table.ifThen(&.{0x01}, &.{ 0x08, 'I', 'N', 'S', 'D', 0x0A, 0x05 });
    try table.nameInteger("INT0", 0);
    // Store (0x05, INT0)
    try table.raw(&.{ 0x70, 0x0A, 0x05, 'I', 'N', 'T', '0' });
    // MTH1 (One, 2), a method of two arguments
    try table.method("MTH1", 2, &.{ 0xA4, 0x68 });
    try table.raw("MTH1");
    try table.raw(&.{ 0x01, 0x0A, 0x02 });
    // CondRefOf (MTH1, Local0): a name in a target's place calls nothing.
    try table.raw(&.{ 0x5B, 0x12 });
    try table.raw("MTH1");
    try table.raw(&.{0x60});
    try table.nameInteger("LAST", 7);
    const loaded = loadTable(ab, .{ .code = try table.finish(), .index = 1 });
    try testing.expectEqual(@as(u32, 4), loaded.code);
    try testing.expectEqual(@as(u32, 3), loaded.names);
    try testing.expectEqual(@as(u32, 0), loaded.unknown + loaded.broken);
    try testing.expect(found(ab, "INSD") == null);
    try testing.expectEqual(@as(u64, 0), try integerAt(ab, "INT0"));
    try testing.expectEqual(@as(u64, 7), try integerAt(ab, "LAST"));
}

test "a DSDT below revision 2 makes the namespace's integers 32 bits wide" {
    var test_machine: testmachine.TestMachine = .{};
    const ab = test_machine.base();
    try testing.expect(namespace.make(ab));
    defer namespace.discard(ab);
    var table = Table_.init(testing.allocator, "DSDT", 1);
    defer table.deinit();
    try table.nameInteger("WIDE", 0x1_2345_6789);
    try table.raw(&.{ 0x08, 'O', 'N', 'E', 'S', 0xFF });
    _ = loadTable(ab, .{ .code = try table.finish(), .index = 1 });
    try testing.expectEqual(@as(u8, 32), ab.integer_bits);
    try testing.expectEqual(@as(u64, 0x2345_6789), try integerAt(ab, "WIDE"));
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF), try integerAt(ab, "ONES"));
}

test "a name is written for the log from the scope it is read in" {
    var test_machine: testmachine.TestMachine = .{};
    const ab = test_machine.base();
    try testing.expect(namespace.make(ab));
    defer namespace.discard(ab);
    var table = Table_.init(testing.allocator, "DSDT", 2);
    defer table.deinit();
    try table.device("\\_SB.DEV0", nothing);
    _ = loadTable(ab, .{ .code = try table.finish(), .index = 1 });
    const device = found(ab, "\\_SB.DEV0").?;
    var text: [PATH_ROOM]u8 = undefined;
    var parsed: namespace.TextPath = undefined;
    try testing.expect(namespace.parseText("^FOO", &parsed));
    try testing.expectEqualStrings("\\_SB.FOO", std.mem.span(nameText(device, parsed.path, &text)));
    try testing.expect(namespace.parseText("FOO.BAR", &parsed));
    try testing.expectEqualStrings("\\_SB.DEV0.FOO.BAR", std.mem.span(nameText(device, parsed.path, &text)));
    try testing.expectEqualStrings("\\FOO.BAR", std.mem.span(nameText(ab.root.?, parsed.path, &text)));
    try testing.expect(namespace.parseText("\\_SB.PCI0", &parsed));
    try testing.expectEqualStrings("\\_SB.PCI0", std.mem.span(nameText(device, parsed.path, &text)));
}
