// SPDX-License-Identifier: MPL-2.0
//! The fields' and the regions' tests: a field's bits read and written
//! through the test machine's address spaces, unit by unit, as the
//! accesses it was asked for show; the index and bank fields, the lock
//! rule, PCI's configuration space, the fields of a buffer, and `_REG`.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const hardware_acpi = sdk.hardware.acpi;
const AcpiBase = @import("../acpi_base.zig").AcpiBase;
const namespace = @import("../namespace/_namespace.zig");
const load = @import("../aml/load.zig");
const interpreter = @import("../interpreter/_interpreter.zig");
const region = @import("../region/_region.zig");
const testmachine = @import("machine.zig");
const TestMachine = testmachine.TestMachine;
const Traced = testmachine.Traced;
const run = @import("run.zig");
const loaded = run.loaded;
const evaluate = run.evaluate;
const integerAt = run.integerAt;
const expectInteger = run.expectInteger;
const expectBuffer = run.expectBuffer;
const aml = @import("aml.zig");
const code = aml.code;
const method = aml.method;
const name = aml.name;
const byte = aml.byte;
const word = aml.word;
const dword = aml.dword;
const text = aml.text;
const buffer = aml.buffer;
const nameOf = aml.nameOf;
const unit = aml.unit;
const skip = aml.skip;

const ZERO = aml.ZERO;
const ONE = aml.ONE;
const ONES = aml.ONES;
const ARG0 = aml.ARG0;
const ARG1 = aml.ARG1;
const RETURN = aml.RETURN;
const STORE = aml.STORE;

const MEMORY = hardware_acpi.SPACE_SYSTEM_MEMORY;
const IO = hardware_acpi.SPACE_SYSTEM_IO;
const PCI = hardware_acpi.SPACE_PCI_CONFIG;
const EC = hardware_acpi.SPACE_EMBEDDED_CONTROL;

/// The field flags: the access type, the lock, the update rule.
const ANY_ACC = 0x00;
const BYTE_ACC = 0x01;
const WORD_ACC = 0x02;
const DWORD_ACC = 0x03;
const LOCK = 0x10;
const WRITE_AS_ONES = 0x20;
const WRITE_AS_ZEROS = 0x40;

fn call(ab: *AcpiBase, path: [*:0]const u8) !void {
    interpreter.release(ab, try evaluate(ab, path, &.{}));
}

fn expectAccess(traced: Traced, space: u8, address: u64, width: u8, write: bool, value: u64) !void {
    try testing.expectEqual(space, traced.space);
    try testing.expectEqual(address, traced.address);
    try testing.expectEqual(width, traced.width);
    try testing.expectEqual(write, traced.write);
    try testing.expectEqual(value, traced.value);
}

// --- units -------------------------------------------------------------------------------

const units = aml.table("DSDT", 2, code(.{
    aml.region("RG00", MEMORY, word(0x1000), byte(0x20)),
    aml.field("RG00", BYTE_ACC, code(.{ unit("F000", 4), unit("F001", 12), unit("F002", 8) })),
    aml.field("RG00", WORD_ACC | WRITE_AS_ONES, code(.{ skip(32), unit("W000", 4) })),
    aml.field("RG00", DWORD_ACC | WRITE_AS_ZEROS, code(.{ skip(64), unit("D000", 8) })),
    aml.field("RG00", BYTE_ACC, code(.{ skip(128), unit("LONG", 128) })),
    aml.field("RG00", ANY_ACC, code(.{ skip(0x60), unit("A000", 3) })),
    aml.region("RG01", MEMORY, word(0x2000), byte(3)),
    aml.field("RG01", DWORD_ACC, code(.{unit("X000", 8)})),
    aml.region("RG02", IO, byte(0x60), ONE),
    aml.field("RG02", BYTE_ACC, code(.{unit("P000", 8)})),
    method("FR01", 0, code(.{ RETURN, name("F000") })),
    method("FR02", 0, code(.{ RETURN, name("F001") })),
    method("FW01", 0, code(.{ STORE, word(0x123), name("F001") })),
    method("FW02", 0, code(.{ STORE, ZERO, name("W000") })),
    method("FW03", 0, code(.{ STORE, byte(0x5A), name("D000") })),
    method("FR03", 0, code(.{ RETURN, name("LONG") })),
    method("FR04", 0, code(.{ RETURN, name("X000") })),
    method("FR05", 0, code(.{ RETURN, name("P000") })),
    // A buffer is written in pieces the size of the field: the last stays.
    method("FW04", 0, code(.{ STORE, buffer(byte(4), &.{ 1, 2, 3, 4 }), name("F002") })),
    // An integer into a field wider than it, filled out with zeros.
    method("FW05", 0, code(.{ STORE, ONES, name("LONG") })),
    method("FW06", 0, code(.{ STORE, byte(0xFF), name("A000") })),
    // Increment reads, changes and writes back.
    method("FW07", 0, code(.{ RETURN, aml.INCREMENT, name("F002") })),
}));

test "a field is read and written in units of its access width, the bits around it kept, or ones, or zeros" {
    var test_machine: TestMachine = .{};
    defer test_machine.deinit();
    const ab = try loaded(&test_machine, units);
    defer namespace.discard(ab);
    try test_machine.poke(MEMORY, 0x1000, 0xAB);
    try test_machine.poke(MEMORY, 0x1001, 0xCD);
    try test_machine.poke(MEMORY, 0x1002, 0xEF);
    try expectInteger(ab, "FR01", 0xB);
    var from = test_machine.accesses;
    try expectInteger(ab, "FR02", 0xCDA);
    const read = test_machine.since(from);
    try testing.expectEqual(@as(usize, 2), read.len);
    try expectAccess(read[0], MEMORY, 0x1000, 1, false, 0xAB);
    try expectAccess(read[1], MEMORY, 0x1001, 1, false, 0xCD);

    // Preserve: the unit F001 shares with F000 read first.
    from = test_machine.accesses;
    try call(ab, "FW01");
    try testing.expectEqual(@as(u8, 0x3B), test_machine.peek(MEMORY, 0x1000));
    try testing.expectEqual(@as(u8, 0x12), test_machine.peek(MEMORY, 0x1001));
    try testing.expectEqual(@as(u8, 0xEF), test_machine.peek(MEMORY, 0x1002));
    const written = test_machine.since(from);
    try testing.expectEqual(@as(usize, 3), written.len);
    try expectAccess(written[0], MEMORY, 0x1000, 1, false, 0xAB);
    try expectAccess(written[1], MEMORY, 0x1000, 1, true, 0x3B);
    try expectAccess(written[2], MEMORY, 0x1001, 1, true, 0x12);

    // WriteAsOnes, a word: nothing read.
    from = test_machine.accesses;
    try call(ab, "FW02");
    try testing.expectEqual(@as(usize, 1), test_machine.since(from).len);
    try expectAccess(test_machine.since(from)[0], MEMORY, 0x1004, 2, true, 0xFFF0);

    // WriteAsZeros, a double word.
    for (0..4) |index| try test_machine.poke(MEMORY, 0x1008 + index, 0xFF);
    from = test_machine.accesses;
    try call(ab, "FW03");
    try testing.expectEqual(@as(usize, 1), test_machine.since(from).len);
    try expectAccess(test_machine.since(from)[0], MEMORY, 0x1008, 4, true, 0x5A);

    // Wider than an integer: a buffer of its bytes.
    for (0..16) |index| try test_machine.poke(MEMORY, 0x1010 + index, @intCast(index + 1));
    try expectBuffer(ab, "FR03", &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    try call(ab, "FW05");
    for (0..16) |index| {
        try testing.expectEqual(@as(u8, if (index < 8) 0xFF else 0), test_machine.peek(MEMORY, 0x1010 + index));
    }

    // A unit past the region's end; a space the machine cannot reach.
    try testing.expectError(error.Range, evaluate(ab, "FR04", &.{}));
    test_machine.unreachable_space = IO;
    try testing.expectError(error.Access, evaluate(ab, "FR05", &.{}));
    test_machine.unreachable_space = null;
    try expectInteger(ab, "FR05", 0);

    from = test_machine.accesses;
    try call(ab, "FW04");
    try testing.expectEqual(@as(u8, 4), test_machine.peek(MEMORY, 0x1002));
    try testing.expectEqual(@as(usize, 4), test_machine.since(from).len);

    // AnyAcc reaches a byte; Preserve keeps the five bits around three.
    try test_machine.poke(MEMORY, 0x100C, 0xA0);
    try call(ab, "FW06");
    try testing.expectEqual(@as(u8, 0xA7), test_machine.peek(MEMORY, 0x100C));

    try expectInteger(ab, "FW07", 5);
    try testing.expectEqual(@as(u8, 5), test_machine.peek(MEMORY, 0x1002));
}

// --- index and bank fields, the lock -----------------------------------------------------------

const indexed = aml.table("DSDT", 2, code(.{
    aml.region("IDXR", IO, byte(0x70), byte(2)),
    aml.field("IDXR", BYTE_ACC, code(.{ unit("INDX", 8), unit("DATA", 8) })),
    aml.indexField("INDX", "DATA", BYTE_ACC, code(.{ skip(0x80), unit("IF00", 8), unit("IF01", 16) })),
    aml.region("BNKR", IO, byte(0x80), byte(4)),
    aml.field("BNKR", BYTE_ACC, code(.{unit("BANK", 8)})),
    aml.bankField("BNKR", "BANK", byte(2), BYTE_ACC, code(.{ skip(8), unit("BF00", 8) })),
    aml.bankField("BNKR", "BANK", word(0x100), BYTE_ACC, code(.{ skip(16), unit("BF01", 8) })),
    aml.region("LKR0", MEMORY, word(0x4000), ONE),
    aml.field("LKR0", BYTE_ACC | LOCK, code(.{unit("LK00", 8)})),
    method("IW01", 0, code(.{ STORE, byte(0x5A), name("IF00") })),
    method("IW02", 0, code(.{ STORE, word(0x1234), name("IF01") })),
    method("IR01", 0, code(.{ RETURN, name("IF00") })),
    method("BW01", 0, code(.{ STORE, byte(0x77), name("BF00") })),
    method("BW02", 0, code(.{ STORE, ONE, name("BF01") })),
    method("LK01", 0, code(.{ STORE, byte(9), name("LK00"), RETURN, name("LK00") })),
    // Held already by the evaluation: taken over once more.
    method("LK02", 0, code(.{ aml.ACQUIRE, name("\\_GL"), 0xFF, 0xFF, STORE, byte(7), name("LK00"), aml.RELEASE, name("\\_GL"), RETURN, name("LK00") })),
}));

test "an index field writes each unit's offset into its index, a bank field its bank first, a locked one holds \\_GL" {
    var test_machine: TestMachine = .{};
    defer test_machine.deinit();
    const ab = try loaded(&test_machine, indexed);
    defer namespace.discard(ab);
    var from = test_machine.accesses;
    try call(ab, "IW01");
    var seen = test_machine.since(from);
    try testing.expectEqual(@as(usize, 2), seen.len);
    try expectAccess(seen[0], IO, 0x70, 1, true, 0x10);
    try expectAccess(seen[1], IO, 0x71, 1, true, 0x5A);

    from = test_machine.accesses;
    try call(ab, "IW02");
    seen = test_machine.since(from);
    try testing.expectEqual(@as(usize, 4), seen.len);
    try expectAccess(seen[0], IO, 0x70, 1, true, 0x11);
    try expectAccess(seen[1], IO, 0x71, 1, true, 0x34);
    try expectAccess(seen[2], IO, 0x70, 1, true, 0x12);
    try expectAccess(seen[3], IO, 0x71, 1, true, 0x12);

    from = test_machine.accesses;
    try expectInteger(ab, "IR01", 0x12);
    seen = test_machine.since(from);
    try testing.expectEqual(@as(usize, 2), seen.len);
    try expectAccess(seen[0], IO, 0x70, 1, true, 0x10);
    try expectAccess(seen[1], IO, 0x71, 1, false, 0x12);

    from = test_machine.accesses;
    try call(ab, "BW01");
    seen = test_machine.since(from);
    try testing.expectEqual(@as(usize, 2), seen.len);
    try expectAccess(seen[0], IO, 0x80, 1, true, 2);
    try expectAccess(seen[1], IO, 0x81, 1, true, 0x77);
    // A bank's number its bank field cannot hold.
    try testing.expectError(error.Range, evaluate(ab, "BW02", &.{}));

    from = test_machine.accesses;
    try expectInteger(ab, "LK01", 9);
    for (test_machine.since(from)) |traced| try testing.expect(traced.locked);
    from = test_machine.accesses;
    try expectInteger(ab, "LK02", 7);
    for (test_machine.since(from)) |traced| try testing.expect(traced.locked);
    const global = ab.root.?;
    const lock = namespace.child(global, namespace.nameOf("_GL_")).?.object.?;
    try testing.expect(lock.value.mutex.owner == null);
    // A field without the rule does not take it.
    from = test_machine.accesses;
    try call(ab, "IW01");
    for (test_machine.since(from)) |traced| try testing.expect(!traced.locked);
}

// --- PCI's configuration space ---------------------------------------------------------------

const pci = aml.table("DSDT", 2, code(.{
    aml.pkg(aml.SCOPE, name("\\_SB") ++ aml.pkg(aml.DEVICE, name("PCI0") ++ code(.{
        nameOf("_HID", dword(0x080AD041)),
        nameOf("_ADR", ZERO),
        method("_BBN", 0, code(.{ RETURN, ZERO })),
        aml.region("PCF0", PCI, ZERO, word(0x100)),
        aml.field("PCF0", WORD_ACC, code(.{unit("RVID", 16)})),
        aml.pkg(aml.DEVICE, name("BR01") ++ code(.{
            nameOf("_ADR", dword(0x001C_0000)),
            aml.pkg(aml.DEVICE, name("DEV2") ++ code(.{
                nameOf("_ADR", dword(0x0000_0002)),
                aml.region("PCFG", PCI, ZERO, word(0x100)),
                aml.field("PCFG", DWORD_ACC, code(.{ unit("VID0", 16), unit("DID0", 16) })),
            })),
        })),
    }))),
    method("PR01", 0, code(.{ RETURN, name("\\_SB.PCI0.BR01.DEV2.VID0") })),
    method("PR02", 0, code(.{ RETURN, name("\\_SB.PCI0.RVID") })),
}));

/// A function's key in the test machine's configuration space.
fn functionKey(bus: u8, device: u8, function: u8) u32 {
    return @as(u32, bus) << 16 | @as(u32, device) << 8 | function;
}

test "a region of configuration space is of its device's function, on the bus the bridges above it lead to" {
    var test_machine: TestMachine = .{};
    defer test_machine.deinit();
    const ab = try loaded(&test_machine, pci);
    defer namespace.discard(ab);
    // The bridge at 0:1c.0, a PCI-to-PCI bridge to bus 3.
    try test_machine.pokeAt(PCI, functionKey(0, 0x1C, 0), 0x0E, 0x01);
    try test_machine.pokeAt(PCI, functionKey(0, 0x1C, 0), 0x19, 3);
    // The device at 3:00.2.
    for ([_]u8{ 0x86, 0x80, 0x34, 0x12 }, 0..) |value, at| try test_machine.pokeAt(PCI, functionKey(3, 0, 2), at, value);
    try expectInteger(ab, "PR01", 0x8086);
    const access = test_machine.last_access;
    try testing.expectEqual(@as(u8, 3), access.pci.bus);
    try testing.expectEqual(@as(u8, 0), access.pci.device);
    try testing.expectEqual(@as(u8, 2), access.pci.function);
    try testing.expectEqual(@as(u8, 4), access.width);
    // Worked out once: the second read asks the bridge nothing.
    const from = test_machine.accesses;
    try expectInteger(ab, "PR01", 0x8086);
    try testing.expectEqual(@as(usize, 1), test_machine.since(from).len);
    // The root bridge's own, on the bus its _BBN names.
    try test_machine.pokeAt(PCI, functionKey(0, 0, 0), 0, 0x22);
    try test_machine.pokeAt(PCI, functionKey(0, 0, 0), 1, 0x10);
    try expectInteger(ab, "PR02", 0x1022);
}

// --- the fields of a buffer, a table's region --------------------------------------------------

const pieces = aml.table("DSDT", 2, code(.{
    nameOf("BUF0", buffer(byte(8), &.{})),
    aml.CREATE_DWORD_FIELD,
    name("BUF0"),
    byte(2),
    name("DW00"),
    aml.CREATE_BIT_FIELD,
    name("BUF0"),
    byte(0x30),
    name("BT00"),
    aml.CREATE_FIELD,
    name("BUF0"),
    byte(0x38),
    byte(8),
    name("CF00"),
    aml.CREATE_QWORD_FIELD,
    name("BUF0"),
    ZERO,
    name("QW00"),
    aml.CREATE_WORD_FIELD,
    name("BUF0"),
    ZERO,
    name("WD00"),
    method("BF01", 0, code(.{ STORE, dword(0x1122_3344), name("DW00"), STORE, ONE, name("BT00"), STORE, byte(0xAB), name("CF00"), RETURN, name("BUF0") })),
    method("BF02", 0, code(.{ RETURN, name("QW00") })),
    // One CreateField made reads as a buffer, however few its bits.
    method("BF03", 0, code(.{ RETURN, name("CF00") })),
    // A buffer stored into one: its last piece the field's size.
    method("BF04", 0, code(.{ STORE, buffer(byte(4), &.{ 1, 2, 3, 4 }), name("WD00"), RETURN, name("WD00") })),
    // Made in a method from its argument.
    method("BF05", 1, code(.{ aml.CREATE_BYTE_FIELD, ARG0, ONE, name("BY00"), RETURN, name("BY00") })),
    aml.DATA_REGION,
    name("DTR0"),
    text("SSDT"),
    text("POWER"),
    text("TESTTABL"),
    aml.field("DTR0", ANY_ACC, code(.{unit("SIG0", 32)})),
    method("BF06", 0, code(.{ RETURN, name("SIG0") })),
}));

const other = aml.table("SSDT", 2, &.{});

test "Create*Field makes fields of a buffer, written in place; a table's region reads the table" {
    var test_machine: TestMachine = .{ .tables = &.{other} };
    defer test_machine.deinit();
    const ab = try loaded(&test_machine, pieces);
    defer namespace.discard(ab);
    try expectBuffer(ab, "BF01", &.{ 0, 0, 0x44, 0x33, 0x22, 0x11, 0x01, 0xAB });
    try expectInteger(ab, "BF02", 0xAB01_1122_3344_0000);
    try expectBuffer(ab, "BF03", &.{0xAB});
    try expectInteger(ab, "BF04", 0x0403);
    const argument = interpreter.Item{ .object = try objectOfBuffer(ab, &.{ 9, 8, 7 }) };
    defer interpreter.release(ab, argument);
    try run.expectIntegerWith(ab, "BF05", &.{argument}, 8);
    try expectInteger(ab, "BF06", 0x5444_5353);
}

fn objectOfBuffer(ab: *AcpiBase, bytes: []const u8) !*@import("../object/_object.zig").Object {
    const object = @import("../object/_object.zig");
    const made = object.makeBytes(ab, @intCast(bytes.len)) orelse return error.NoMemory;
    @memcpy(made.bytes[0..bytes.len], bytes);
    return object.make(ab, .{ .buffer = made }) orelse error.NoMemory;
}

// --- _REG ------------------------------------------------------------------------------------

const registered = aml.table("DSDT", 2, code(.{
    aml.pkg(aml.DEVICE, name("EC00") ++ code(.{
        nameOf("REGC", ZERO),
        nameOf("REGS", ONES),
        aml.region("ECR0", EC, ZERO, byte(0x10)),
        aml.field("ECR0", BYTE_ACC, code(.{unit("ECF0", 8)})),
        aml.region("MEM0", MEMORY, word(0x3000), byte(0x10)),
        method("_REG", 2, code(.{
            aml.ifThen(code(.{ARG1}), code(.{ aml.INCREMENT, name("REGC") })),
            aml.orElse(code(.{ aml.DECREMENT, name("REGC") })),
            STORE,
            ARG0,
            name("REGS"),
        })),
        // A region a method makes, in the device's scope.
        method("MKR0", 0, code(.{ aml.pkg(aml.SCOPE, name("\\EC00") ++ aml.region("ECR1", EC, byte(0x10), byte(0x10))), RETURN, name("REGC") })),
        method("RD00", 0, code(.{ RETURN, name("ECF0") })),
    })),
    // Controllers reached through memory alone: told all the same.
    aml.pkg(aml.DEVICE, name("ECM0") ++ code(.{
        nameOf("_HID", dword(0x090CD041)),
        nameOf("REGC", ZERO),
        aml.region("ERAM", MEMORY, word(0x5000), byte(0x10)),
        method("_REG", 2, code(.{ aml.INCREMENT, name("REGC") })),
    })),
    aml.pkg(aml.DEVICE, name("ECM1") ++ code(.{
        nameOf("_HID", text("ABCD0001")),
        method("_CID", 0, code(.{ RETURN, aml.package(2, code(.{ dword(0x030AD041), text("PNP0C09") })) })),
        nameOf("REGC", ZERO),
        method("_REG", 2, code(.{ aml.INCREMENT, name("REGC") })),
    })),
    // Not a controller: not told.
    aml.pkg(aml.DEVICE, name("DEV0") ++ code(.{
        nameOf("REGC", ZERO),
        method("_REG", 2, code(.{ aml.INCREMENT, name("REGC") })),
    })),
}));

/// A table loaded later, whose region comes before its scope's `_REG`.
const later = aml.table("SSDT", 2, code(.{
    aml.pkg(aml.DEVICE, name("\\EC01") ++ code(.{
        nameOf("REGC", ZERO),
        aml.region("ECR2", EC, ZERO, ONE),
        method("_REG", 2, code(.{ STORE, ARG1, name("REGC") })),
    })),
}));

test "_REG is run for a space's regions when it is connected, one a method makes, and one a table loaded later defines" {
    var test_machine: TestMachine = .{};
    defer test_machine.deinit();
    const ab = try loaded(&test_machine, registered);
    defer namespace.discard(ab);
    try testing.expectEqual(@as(u64, 0), try integerAt(ab, "\\EC00.REGC"));
    region.connectSpace(ab, MEMORY);
    try testing.expectEqual(@as(u64, 0), try integerAt(ab, "\\EC00.REGC"));
    region.connectSpace(ab, EC);
    try testing.expectEqual(@as(u64, 1), try integerAt(ab, "\\EC00.REGC"));
    try testing.expectEqual(@as(u64, EC), try integerAt(ab, "\\EC00.REGS"));
    try testing.expectEqual(@as(u64, 1), try integerAt(ab, "\\ECM0.REGC"));
    try testing.expectEqual(@as(u64, 1), try integerAt(ab, "\\ECM1.REGC"));
    try testing.expectEqual(@as(u64, 0), try integerAt(ab, "\\DEV0.REGC"));
    // Connected again, nothing is told twice.
    region.connectSpace(ab, EC);
    try testing.expectEqual(@as(u64, 1), try integerAt(ab, "\\EC00.REGC"));
    try testing.expectEqual(@as(u64, 1), try integerAt(ab, "\\ECM0.REGC"));
    try testing.expectEqual(@as(u64, 1), try integerAt(ab, "\\ECM1.REGC"));
    // Told it is there as it is made, and gone as the method returns.
    try expectInteger(ab, "\\EC00.MKR0", 2);
    try testing.expectEqual(@as(u64, 1), try integerAt(ab, "\\EC00.REGC"));
    try testing.expect(run.nodeAt(ab, "\\EC00.ECR1") == null);
    try test_machine.poke(EC, 0, 0x42);
    try expectInteger(ab, "\\EC00.RD00", 0x42);
    try testing.expect(load.loadMore(ab, later, ab.root.?, null, false));
    try testing.expectEqual(@as(u64, 1), try integerAt(ab, "\\EC01.REGC"));
}
