// SPDX-License-Identifier: MPL-2.0
//! A table loaded: its terms run in order from its first, past the
//! header, at the namespace's root - each definition making its name, to
//! stay, and the code outside any method running as it is met
//! (interpreter/). What a table defines is in interpreter/define.zig;
//! this file starts the run and says what went wrong while it ran.
//!
//! **What goes wrong, and how far.** A name a table defines that is there
//! already - one an earlier table defined - is kept as it was, and the
//! term that defines it again is stepped over, a scope's contents with
//! it. A Scope, a field's region or an alias's object that no table has
//! made leaves that term out. An opcode the interpreter does not know, or
//! a term that cannot be read, leaves out the rest of the list it is in -
//! nothing says where the next term would start - and no more: a scope's
//! or a device's body ends where its package says, and the list around it
//! goes on; a term whose own end its bytes say is left out alone. Code
//! outside any method that ends with an error - a name it refers to not
//! there, an operand of the wrong kind - leaves out the term it is. Each
//! is said in the log, at the table and the offset, and counted
//! (`Loaded`); the rest of the table is loaded all the same.

const sdk = @import("sdk");
const exec = sdk.exec;
const hardware_acpi = sdk.hardware.acpi;
const AcpiBase = @import("../acpi_base.zig").AcpiBase;
const Loaded = @import("../acpi_base.zig").Loaded;
const machine = @import("../machine/_machine.zig");
const namespace = @import("../namespace/_namespace.zig");
const Node = namespace.Node;
const Path = namespace.Path;
const aml = @import("_aml.zig");
const Reader = aml.Reader;
const interpreter = @import("../interpreter/_interpreter.zig");

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

/// A table being loaded: what it is, and what has been found so far.
pub const Load = struct {
    ab: *AcpiBase,
    table: Table,
    signature: [5]u8 = .{ '?', '?', '?', '?', 0 },
    loaded: Loaded = .{},
    /// Who holds the mutexes its code takes: the evaluation that loads
    /// it (Load, LoadTable); null for its own.
    owner: ?*const anyopaque = null,
};

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
    interpreter.runTable(ab, &load, Reader.of(table.code, HEADER_SIZE), root);
    return finish(&load);
}

/// The longest table Load copies in.
pub const MOST_LOADED = hardware_acpi.MOST_TABLE_BYTES;

/// How long a table's header says it is.
pub fn lengthOf(header: *const [HEADER_SIZE]u8) u32 {
    return @as(u32, header[4]) | @as(u32, header[5]) << 8 | @as(u32, header[6]) << 16 | @as(u32, header[7]) << 24;
}

/// A table that Load or LoadTable names, `code` header first, loaded at
/// `scope` by the evaluation `owner`: copied first where `copy` - what
/// Load reads is the bytecode's, and gone when it is done - and kept as
/// long as the namespace is; the regions it defines in a space already
/// connected told so once it is loaded. False where its header does not
/// hold: too short, or longer than `code`.
pub fn loadMore(ab: *AcpiBase, code: []const u8, scope: *Node, owner: ?*const anyopaque, copy: bool) bool {
    if (code.len < HEADER_SIZE) return false;
    const length = lengthOf(code[0..HEADER_SIZE]);
    if (length < HEADER_SIZE or length > code.len) return false;
    const bytes = if (copy) keepCopy(ab, code[0..length]) orelse return false else code[0..length];
    var loading: Load = .{ .ab = ab, .table = .{ .code = bytes, .index = ab.tables + 1 }, .owner = owner };
    for (bytes[0..4], 0..) |char, index| loading.signature[index] = char;
    interpreter.runTable(ab, &loading, Reader.of(bytes, HEADER_SIZE), scope);
    @import("../region/_region.zig").tellLoaded(ab);
    const loaded = finish(&loading);
    machine.log(ab, exec.LOG_INFO, "%s loaded: %u names\n", .{ signatureOf(&loading), loaded.names });
    return true;
}

/// A table Load copied in, and the next: the bytes follow it.
const Copy = struct {
    next: ?*Copy,
    length: usize,
};

/// `bytes` copied into the interpreter's memory, kept on the base's list
/// until the namespace is discarded.
fn keepCopy(ab: *AcpiBase, bytes: []const u8) ?[]const u8 {
    const total = @sizeOf(Copy) + bytes.len;
    const memory = machine.allocBytes(ab, total) orelse return null;
    const copy: *Copy = @ptrCast(@alignCast(memory));
    copy.* = .{ .next = @ptrCast(@alignCast(ab.copies)), .length = bytes.len };
    ab.copies = copy;
    const kept = memory[@sizeOf(Copy)..total];
    @memcpy(kept, bytes);
    return kept;
}

/// The tables Load copied in given back: once nothing of the namespace
/// refers to them any more.
pub fn discardCopies(ab: *AcpiBase) void {
    var at: ?*Copy = @ptrCast(@alignCast(ab.copies));
    while (at) |copy| {
        at = copy.next;
        machine.freeBytes(ab, @ptrCast(copy), @sizeOf(Copy) + copy.length);
    }
    ab.copies = null;
}

fn finish(load: *Load) Loaded {
    load.ab.tables += 1;
    load.ab.loaded.add(load.loaded);
    return load.loaded;
}

fn sameSignature(code: []const u8, signature: *const [4]u8) bool {
    return code[0] == signature[0] and code[1] == signature[1] and code[2] == signature[2] and code[3] == signature[3];
}

fn signatureOf(load: *const Load) [*:0]const u8 {
    return @ptrCast(&load.signature);
}

// --- what went wrong, said and counted --------------------------------------------------

/// What a term that went wrong leaves out: the rest of the list it is in,
/// where nothing says where the next term would start, or the term alone.
pub const Left = enum { rest, term };

/// `node`, which a table defines again: the first kept.
pub fn again(load: *Load, node: *Node) void {
    load.loaded.again += 1;
    var text: [namespace.PATH_ROOM]u8 = undefined;
    _ = namespace.pathOf(node, &text);
    machine.log(load.ab, exec.LOG_WARNING, "%s %u: %s defined again, the first kept\n", .{
        signatureOf(load), @as(u32, load.table.place), @as([*:0]const u8, @ptrCast(&text)),
    });
}

/// `path`, defined from `scope`, in a scope that is not there.
pub fn noScope(load: *Load, scope: *Node, path: Path) void {
    load.loaded.missing += 1;
    var text: [namespace.PATH_ROOM]u8 = undefined;
    machine.log(load.ab, exec.LOG_WARNING, "%s %u: %s is defined in a scope that is not there, and left out\n", .{
        signatureOf(load), @as(u32, load.table.place), namespace.pathText(scope, path, &text),
    });
}

/// `path`, which a definition in `scope` refers to as `what`, is not there.
pub fn notThere(load: *Load, scope: *Node, path: Path, what: [*:0]const u8) void {
    load.loaded.missing += 1;
    var text: [namespace.PATH_ROOM]u8 = undefined;
    machine.log(load.ab, exec.LOG_WARNING, "%s %u: %s %s is not there, and what it is for left out\n", .{
        signatureOf(load), @as(u32, load.table.place), what, namespace.pathText(scope, path, &text),
    });
}

/// An element of a field's list at `at`, in `scope`, cannot be read: the
/// rest of the field left out.
pub fn lostField(load: *Load, at: usize, scope: *Node) void {
    load.loaded.broken += 1;
    var where: [namespace.PATH_ROOM]u8 = undefined;
    _ = namespace.pathOf(scope, &where);
    machine.log(load.ab, exec.LOG_ERROR, "%s %u: the term at 0x%x cannot be read: the rest of a field in %s left out\n", .{
        signatureOf(load), @as(u32, load.table.place), @as(u32, @intCast(at)), @as([*:0]const u8, @ptrCast(&where)),
    });
}

/// No memory for the run that loads the table.
pub fn noMemory(load: *Load) void {
    load.loaded.broken += 1;
    machine.log(load.ab, exec.LOG_ERROR, "%s %u: no memory\n", .{ signatureOf(load), @as(u32, load.table.place) });
}

/// The term at `at`, in `scope`, ended with `err`: said and counted, as
/// leaving out `left`. `detail` names what the error is about, where
/// `has_detail`.
pub fn failed(load: *Load, err: interpreter.Error, at: usize, scope: *Node, left: Left, has_detail: bool, detail: *const [namespace.PATH_ROOM]u8) void {
    var where: [namespace.PATH_ROOM]u8 = undefined;
    _ = namespace.pathOf(scope, &where);
    const leaves: [*:0]const u8 = switch (left) {
        .rest => "the rest of",
        .term => "the term in",
    };
    const in_scope: [*:0]const u8 = @ptrCast(&where);
    const place: u32 = load.table.place;
    switch (err) {
        error.Unknown => {
            load.loaded.unknown += 1;
            var probe = Reader.of(load.table.code, at);
            const code: u32 = probe.opcode() orelse 0;
            machine.log(load.ab, exec.LOG_ERROR, "%s %u: opcode 0x%x at 0x%x not known: %s %s left out\n", .{
                signatureOf(load), place, code, @as(u32, @intCast(at)), leaves, in_scope,
            });
        },
        error.Broken => {
            load.loaded.broken += 1;
            machine.log(load.ab, exec.LOG_ERROR, "%s %u: the term at 0x%x cannot be read: %s %s left out\n", .{
                signatureOf(load), place, @as(u32, @intCast(at)), leaves, in_scope,
            });
        },
        else => {
            load.loaded.failed += 1;
            const about: [*:0]const u8 = if (has_detail) @ptrCast(detail) else "";
            machine.log(load.ab, exec.LOG_ERROR, "%s %u: the code at 0x%x outside any method: %s%s%s; %s %s left out\n", .{
                signatureOf(load),                               place, @as(u32, @intCast(at)), interpreter.reason(err),
                @as([*:0]const u8, if (has_detail) " " else ""), about, leaves,                 in_scope,
            });
        },
    }
}

// --- tests ------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;
const object = @import("../object/_object.zig");
const Object = object.Object;
const opcodes = @import("opcodes.zig");
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

    // A field of BUF0's own object, its bytes 4 to 7.
    const created = (try heldAt(ab, "CDW0")).value.buffer_field;
    try testing.expectEqual(try heldAt(ab, "BUF0"), created.buffer);
    try testing.expectEqual(@as(u32, 32), created.bit_offset);
    try testing.expectEqual(@as(u32, 32), created.bit_length);
    try testing.expect(!created.as_buffer);
}

test "index and bank fields reach their registers, and a region's address is worked out from what its operands say" {
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
    try testing.expectEqual(@as(u64, 0x1000), by_name.offset);
    try testing.expectEqual(@as(u64, 0x10), by_name.length);
    const by_sum = (try heldAt(ab, "REG2")).value.region;
    try testing.expectEqual(@as(u8, 1), by_sum.space);
    try testing.expectEqual(@as(u64, 0x1004), by_sum.offset);
    try testing.expectEqual(@as(u64, 8), by_sum.length);
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
    // A package with an element cut short - a Store with nothing to
    // store, its package ending first: that Name alone.
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
    try testing.expectEqual(@as(u32, 1), loaded.unknown);
    try testing.expectEqual(@as(u32, 1), loaded.broken);
    try testing.expect(found(ab, "\\_SB.DEV0.BFOR") != null);
    try testing.expect(found(ab, "\\_SB.DEV0.AFTR") == null);
    try testing.expect(found(ab, "PKG0") == null);
    try testing.expectEqual(@as(u64, 3), try integerAt(ab, "NEXT"));
}

test "code outside any method runs as it is met, names it defines staying" {
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
    try testing.expectEqual(@as(u32, 4), loaded.names);
    try testing.expectEqual(@as(u32, 0), loaded.failed + loaded.unknown + loaded.broken);
    try testing.expectEqual(@as(u64, 5), try integerAt(ab, "INSD"));
    try testing.expectEqual(@as(u64, 5), try integerAt(ab, "INT0"));
    try testing.expectEqual(@as(u64, 7), try integerAt(ab, "LAST"));
    try testing.expectEqual(@as(u32, 0), test_machine.lines);
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
    var text: [namespace.PATH_ROOM]u8 = undefined;
    var parsed: namespace.TextPath = undefined;
    try testing.expect(namespace.parseText("^FOO", &parsed));
    try testing.expectEqualStrings("\\_SB.FOO", std.mem.span(namespace.pathText(device, parsed.path, &text)));
    try testing.expect(namespace.parseText("FOO.BAR", &parsed));
    try testing.expectEqualStrings("\\_SB.DEV0.FOO.BAR", std.mem.span(namespace.pathText(device, parsed.path, &text)));
    try testing.expectEqualStrings("\\FOO.BAR", std.mem.span(namespace.pathText(ab.root.?, parsed.path, &text)));
    try testing.expect(namespace.parseText("\\_SB.PCI0", &parsed));
    try testing.expectEqualStrings("\\_SB.PCI0", std.mem.span(namespace.pathText(device, parsed.path, &text)));
}
