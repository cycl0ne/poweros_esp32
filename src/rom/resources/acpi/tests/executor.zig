// SPDX-License-Identifier: MPL-2.0
//! The executor's tests, a family of operators each: a table of methods
//! loaded on the test machine, each method called and what it returned
//! checked - the rules of each family case by case, at both widths of
//! the namespace's integers where the width matters.

const std = @import("std");
const testing = std.testing;
const AcpiBase = @import("../acpi_base.zig").AcpiBase;
const base = @import("../acpi_base.zig");
const namespace = @import("../namespace/_namespace.zig");
const Node = namespace.Node;
const object = @import("../object/_object.zig");
const load = @import("../aml/load.zig");
const interpreter = @import("../interpreter/_interpreter.zig");
const Item = interpreter.Item;
const notice = @import("../interpreter/notice.zig");
const TestMachine = @import("machine.zig").TestMachine;
const run = @import("run.zig");
const loaded = run.loaded;
const nodeAt = run.nodeAt;
const evaluate = run.evaluate;
const integerOf = run.integerOf;
const integerAt = run.integerAt;
const expectInteger = run.expectInteger;
const expectIntegerWith = run.expectIntegerWith;
const expectString = run.expectString;
const expectBuffer = run.expectBuffer;
const ALL = run.ALL;
const aml = @import("aml.zig");
const code = aml.code;
const method = aml.method;
const name = aml.name;
const byte = aml.byte;
const word = aml.word;
const dword = aml.dword;
const qword = aml.qword;
const text = aml.text;
const buffer = aml.buffer;
const package = aml.package;
const nameOf = aml.nameOf;
const ifThen = aml.ifThen;
const orElse = aml.orElse;
const whileDo = aml.whileDo;

const ZERO = aml.ZERO;
const ONE = aml.ONE;
const ONES = aml.ONES;
const LOCAL0 = aml.LOCAL0;
const LOCAL1 = aml.LOCAL1;
const LOCAL2 = aml.LOCAL2;
const ARG0 = aml.ARG0;
const ARG1 = aml.ARG1;
const RETURN = aml.RETURN;
const STORE = aml.STORE;

// --- arithmetic --------------------------------------------------------------------------

const arithmetic = aml.table("DSDT", 2, code(.{
    method("A001", 0, code(.{ RETURN, aml.ADD, ONES, byte(2), ZERO })),
    method("A002", 0, code(.{ RETURN, aml.SUBTRACT, ONE, byte(2), ZERO })),
    method("A003", 0, code(.{ RETURN, aml.MULTIPLY, qword(0x1_0000_0000), qword(0x1_0000_0000), ZERO })),
    method("A004", 0, code(.{ RETURN, aml.SHIFT_LEFT, ONE, byte(64), ZERO })),
    method("A005", 0, code(.{ RETURN, aml.SHIFT_LEFT, ONE, byte(63), ZERO })),
    method("A006", 0, code(.{ RETURN, aml.SHIFT_RIGHT, byte(0x80), byte(3), ZERO })),
    // Divide (17, 5, Local0, Local1): the remainder, then the quotient.
    method("A007", 0, code(.{ aml.DIVIDE, byte(17), byte(5), LOCAL0, LOCAL1, RETURN, aml.OR, aml.SHIFT_LEFT, LOCAL1, byte(8), ZERO, LOCAL0, ZERO })),
    method("A008", 0, code(.{ RETURN, aml.MOD, byte(17), byte(5), ZERO })),
    method("A009", 0, code(.{ RETURN, aml.NAND, byte(0xF0), byte(0xFF), ZERO })),
    method("A010", 0, code(.{ RETURN, aml.NOR, byte(0xF0), byte(0x0F), ZERO })),
    method("A011", 0, code(.{ RETURN, aml.XOR, byte(0xFF), byte(0x0F), ZERO })),
    method("A012", 0, code(.{ RETURN, aml.NOT, ZERO, ZERO })),
    method("A013", 0, code(.{ RETURN, aml.FIND_SET_LEFT_BIT, byte(0x80), ZERO })),
    method("A014", 0, code(.{ RETURN, aml.FIND_SET_RIGHT_BIT, byte(0x0C), ZERO })),
    method("A015", 0, code(.{ RETURN, aml.FIND_SET_LEFT_BIT, ZERO, ZERO })),
    method("A016", 0, code(.{ RETURN, aml.FROM_BCD, word(0x1234), ZERO })),
    method("A017", 0, code(.{ RETURN, aml.TO_BCD, word(1234), ZERO })),
    // Local0 = 5; Local0++; Local0++; Local0--; Return (Local0)
    method("A018", 0, code(.{ STORE, byte(5), LOCAL0, aml.INCREMENT, LOCAL0, aml.INCREMENT, LOCAL0, aml.DECREMENT, LOCAL0, RETURN, LOCAL0 })),
    // Increment answers the new value.
    method("A019", 0, code(.{ STORE, byte(5), LOCAL0, RETURN, aml.INCREMENT, LOCAL0 })),
    nameOf("CNT0", ONE),
    method("A020", 0, code(.{ aml.INCREMENT, name("CNT0"), RETURN, name("CNT0") })),
    // Through a reference a local holds.
    nameOf("CNT1", byte(7)),
    method("A021", 0, code(.{ STORE, aml.REF_OF, name("CNT1"), LOCAL0, aml.DECREMENT, LOCAL0, RETURN, name("CNT1") })),
    // A target gets the result, which goes on as well.
    method("A022", 0, code(.{ RETURN, aml.ADD, aml.ADD, byte(2), byte(3), LOCAL0, LOCAL0, ZERO })),
    method("A023", 0, code(.{ RETURN, aml.DIVIDE, ONE, ZERO, ZERO, ZERO })),
    method("A024", 0, code(.{ RETURN, aml.MOD, ONE, ZERO, ZERO })),
}));

test "arithmetic wraps at the namespace's width, a shift by the width or more is 0, Divide stores both results" {
    var test_machine: TestMachine = .{};
    defer test_machine.deinit();
    const ab = try loaded(&test_machine, arithmetic);
    defer namespace.discard(ab);
    try expectInteger(ab, "A001", 1);
    try expectInteger(ab, "A002", ALL);
    try expectInteger(ab, "A003", 0);
    try expectInteger(ab, "A004", 0);
    try expectInteger(ab, "A005", 0x8000_0000_0000_0000);
    try expectInteger(ab, "A006", 0x10);
    try expectInteger(ab, "A007", 0x0302);
    try expectInteger(ab, "A008", 2);
    try expectInteger(ab, "A009", 0xFFFF_FFFF_FFFF_FF0F);
    try expectInteger(ab, "A010", 0xFFFF_FFFF_FFFF_FF00);
    try expectInteger(ab, "A011", 0xF0);
    try expectInteger(ab, "A012", ALL);
    try expectInteger(ab, "A013", 8);
    try expectInteger(ab, "A014", 3);
    try expectInteger(ab, "A015", 0);
    try expectInteger(ab, "A016", 1234);
    try expectInteger(ab, "A017", 0x1234);
    try expectInteger(ab, "A018", 6);
    try expectInteger(ab, "A019", 6);
    try expectInteger(ab, "A020", 2);
    try expectInteger(ab, "A021", 6);
    try expectInteger(ab, "A022", 10);
    const lines = test_machine.lines;
    try testing.expectError(error.DivideByZero, evaluate(ab, "A023", &.{}));
    try testing.expectError(error.DivideByZero, evaluate(ab, "A024", &.{}));
    try testing.expectEqual(lines + 2, test_machine.lines);
    try testing.expect(test_machine.said("at 0x"));
}

const narrow = aml.table("DSDT", 1, code(.{
    method("B001", 0, code(.{ RETURN, aml.ADD, dword(0xFFFF_FFFF), ONE, ZERO })),
    method("B002", 0, code(.{ RETURN, aml.NOT, ZERO, ZERO })),
    method("B003", 0, code(.{ RETURN, ONES })),
    method("B004", 0, code(.{ RETURN, aml.SHIFT_LEFT, ONE, byte(32), ZERO })),
    method("B005", 0, code(.{ RETURN, aml.SUBTRACT, ZERO, ONE, ZERO })),
    method("B006", 0, code(.{ RETURN, aml.CONCATENATE, ONE, byte(2), ZERO })),
    method("B007", 0, code(.{ STORE, byte(5), LOCAL0, RETURN, aml.SIZE_OF, LOCAL0 })),
    method("B008", 0, code(.{ RETURN, qword(0x1_0000_0001) })),
    method("B009", 0, code(.{ RETURN, aml.LEQUAL, text("0000001F"), byte(0x1F) })),
    method("B010", 0, code(.{ RETURN, aml.TO_BUFFER, dword(0x0403_0201), ZERO })),
    method("B011", 0, code(.{ RETURN, aml.ADD, text("123456789"), ZERO, ZERO })),
    method("B012", 0, code(.{ RETURN, aml.TO_BCD, dword(0xFFFF_FFFF), ZERO })),
}));

test "a DSDT below revision 2 works out every integer in 32 bits" {
    var test_machine: TestMachine = .{};
    defer test_machine.deinit();
    const ab = try loaded(&test_machine, narrow);
    defer namespace.discard(ab);
    try testing.expectEqual(@as(u8, 32), ab.integer_bits);
    try expectInteger(ab, "B001", 0);
    try expectInteger(ab, "B002", 0xFFFF_FFFF);
    try expectInteger(ab, "B003", 0xFFFF_FFFF);
    try expectInteger(ab, "B004", 0);
    try expectInteger(ab, "B005", 0xFFFF_FFFF);
    try expectBuffer(ab, "B006", &.{ 1, 0, 0, 0, 2, 0, 0, 0 });
    try expectInteger(ab, "B007", 4);
    try expectInteger(ab, "B008", 1);
    try expectInteger(ab, "B009", 0xFFFF_FFFF);
    try expectBuffer(ab, "B010", &.{ 1, 2, 3, 4 });
    try expectInteger(ab, "B011", 0x1234_5678);
    try expectInteger(ab, "B012", 0x9496_7295);
}

// --- logic -------------------------------------------------------------------------------

const logic = aml.table("DSDT", 2, code(.{
    method("L001", 0, code(.{ RETURN, aml.LAND, ONE, byte(2) })),
    method("L002", 0, code(.{ RETURN, aml.LAND, ONE, ZERO })),
    method("L003", 0, code(.{ RETURN, aml.LOR, ZERO, ZERO })),
    method("L004", 0, code(.{ RETURN, aml.LNOT, byte(5) })),
    method("L005", 0, code(.{ RETURN, aml.LNOT, ZERO })),
    method("L006", 0, code(.{ RETURN, aml.LEQUAL, text("abc"), text("abc") })),
    method("L007", 0, code(.{ RETURN, aml.LLESS, text("ab"), text("abc") })),
    method("L008", 0, code(.{ RETURN, aml.LGREATER, text("abd"), text("abc") })),
    // The second made the first's kind: a string read as an integer...
    method("L009", 0, code(.{ RETURN, aml.LEQUAL, byte(0x1F), text("1F") })),
    // ...an integer written as all its hexadecimal digits...
    method("L010", 0, code(.{ RETURN, aml.LEQUAL, text("000000000000001F"), byte(0x1F) })),
    method("L011", 0, code(.{ RETURN, aml.LEQUAL, text("1F"), byte(0x1F) })),
    method("L012", 0, code(.{ RETURN, aml.LEQUAL, buffer(byte(2), &.{ 1, 2 }), buffer(byte(2), &.{ 1, 2 }) })),
    method("L013", 0, code(.{ RETURN, aml.LLESS, buffer(byte(2), &.{ 1, 2 }), buffer(byte(3), &.{ 1, 2, 0 }) })),
    // ...or as its bytes.
    method("L014", 0, code(.{ RETURN, aml.LEQUAL, buffer(byte(8), &.{1}), ONE })),
    // LAnd reads a buffer's first four bytes, LOr a string as ToInteger does.
    method("L015", 0, code(.{ RETURN, aml.LAND, buffer(byte(5), &.{ 0, 0, 0, 0, 1 }), ONE })),
    method("L016", 0, code(.{ RETURN, aml.LOR, text("0x10"), ZERO })),
    method("L017", 0, code(.{ RETURN, aml.LOR, text("0"), ZERO })),
    // Packages are never equal.
    method("L018", 0, code(.{ RETURN, aml.LEQUAL, package(1, code(.{ONE})), package(1, code(.{ONE})) })),
    method("L019", 0, code(.{ RETURN, aml.LGREATER, byte(3), byte(2) })),
}));

test "the logical operators answer every bit set or none, comparing the second operand made the first's kind" {
    var test_machine: TestMachine = .{};
    defer test_machine.deinit();
    const ab = try loaded(&test_machine, logic);
    defer namespace.discard(ab);
    try expectInteger(ab, "L001", ALL);
    try expectInteger(ab, "L002", 0);
    try expectInteger(ab, "L003", 0);
    try expectInteger(ab, "L004", 0);
    try expectInteger(ab, "L005", ALL);
    try expectInteger(ab, "L006", ALL);
    try expectInteger(ab, "L007", ALL);
    try expectInteger(ab, "L008", ALL);
    try expectInteger(ab, "L009", ALL);
    try expectInteger(ab, "L010", ALL);
    try expectInteger(ab, "L011", 0);
    try expectInteger(ab, "L012", ALL);
    try expectInteger(ab, "L013", ALL);
    try expectInteger(ab, "L014", ALL);
    try expectInteger(ab, "L015", 0);
    try expectInteger(ab, "L016", ALL);
    try expectInteger(ab, "L017", 0);
    try expectInteger(ab, "L018", 0);
    try expectInteger(ab, "L019", ALL);
}

// --- control and calls -------------------------------------------------------------------

const control = aml.table("DSDT", 2, code(.{
    // If (Arg0 == 1) { Return (10) } Else { Return (20) }
    method("C001", 1, code(.{ ifThen(code(.{ aml.LEQUAL, ARG0, ONE }), code(.{ RETURN, byte(10) })), orElse(code(.{ RETURN, byte(20) })) })),
    // Sum of 1..9 leaving out 3, stopping at 7.
    method("C002", 0, code(.{
        STORE,  ZERO,   LOCAL0, STORE, ZERO, LOCAL1,
        whileDo(code(.{ aml.LLESS, LOCAL0, byte(10) }), code(.{
            aml.INCREMENT,                                                         LOCAL0,
            ifThen(code(.{ aml.LEQUAL, LOCAL0, byte(3) }), code(.{aml.CONTINUE})), ifThen(code(.{ aml.LEQUAL, LOCAL0, byte(7) }), code(.{aml.BREAK})),
            aml.ADD,                                                               LOCAL1,
            LOCAL0,                                                                LOCAL1,
        })),
        RETURN, LOCAL1,
    })),
    method("C003", 0, code(.{ RETURN, aml.ADD, name("C004"), byte(2), byte(3), ONE, ZERO })),
    method("C004", 2, code(.{ RETURN, aml.MULTIPLY, ARG0, ARG1, ZERO })),
    // C005 (n): n + C005 (n - 1), down to 0.
    method("C005", 1, code(.{
        ifThen(code(.{ aml.LEQUAL, ARG0, ZERO }), code(.{ RETURN, ZERO })),
        RETURN,
        aml.ADD,
        ARG0,
        name("C005"),
        aml.SUBTRACT,
        ARG0,
        ONE,
        ZERO,
        ZERO,
    })),
    method("C006", 0, code(.{ RETURN, name("C006") })),
    // What a method returns is a copy: changing it changes nothing of
    // the name it was.
    nameOf("S000", text("abc")),
    method("C007", 0, code(.{ RETURN, name("S000") })),
    method("C008", 0, code(.{
        STORE,     name("C007"), LOCAL0,
        aml.INDEX, LOCAL0,       ZERO,
        LOCAL1,    STORE,        byte(0x7A),
        LOCAL1,    RETURN,       aml.CONCATENATE,
        LOCAL0,    name("S000"), ZERO,
    })),
    // A buffer argument is the caller's: what the method writes into it
    // the caller sees.
    nameOf("B000", buffer(byte(3), &.{ 1, 2, 3 })),
    method("C009", 1, code(.{ aml.INDEX, ARG0, ZERO, LOCAL0, STORE, byte(9), LOCAL0 })),
    method("C010", 0, code(.{ name("C009"), name("B000"), RETURN, aml.DEREF_OF, aml.INDEX, name("B000"), ZERO, ZERO })),
    // An integer argument is the method's own.
    nameOf("I000", byte(5)),
    method("C011", 1, code(.{ STORE, byte(9), ARG0 })),
    method("C012", 0, code(.{ name("C011"), name("I000"), RETURN, name("I000") })),
    // A reference argument is stored through.
    nameOf("I001", ONE),
    method("C013", 0, code(.{ name("C011"), aml.REF_OF, name("I001"), RETURN, name("I001") })),
    // A name a method makes is gone when it returns.
    method("C014", 0, code(.{ nameOf("TMP0", byte(3)), RETURN, name("TMP0") })),
    method("C015", 0, code(.{ aml.NOOP, RETURN, ZERO })),
    // A While that does not end meets the limit: two seconds a turn.
    method("C016", 0, code(.{whileDo(code(.{ONE}), code(.{ aml.SLEEP, word(2000) }))})),
}));

test "If, Else, While, Break, Continue and calls nested in one another, each method's names its own" {
    var test_machine: TestMachine = .{};
    defer test_machine.deinit();
    const ab = try loaded(&test_machine, control);
    defer namespace.discard(ab);
    try expectIntegerWith(ab, "C001", &.{.{ .integer = 1 }}, 10);
    try expectIntegerWith(ab, "C001", &.{.{ .integer = 2 }}, 20);
    try expectInteger(ab, "C002", 18);
    try expectInteger(ab, "C003", 7);
    try expectIntegerWith(ab, "C005", &.{.{ .integer = 10 }}, 55);
    try testing.expectError(error.Limit, evaluate(ab, "C006", &.{}));
    try expectString(ab, "C008", "zbcabc");
    try expectInteger(ab, "C010", 9);
    try expectInteger(ab, "C012", 5);
    try expectInteger(ab, "C013", 9);
    try expectInteger(ab, "C014", 3);
    try testing.expect(nodeAt(ab, "\\C014.TMP0") == null);
    try expectInteger(ab, "C015", 0);
    try testing.expectError(error.Limit, evaluate(ab, "C016", &.{}));
}

// --- conversions -------------------------------------------------------------------------

const conversions = aml.table("DSDT", 2, code(.{
    // A string as an operand: its leading hexadecimal digits.
    method("V001", 0, code(.{ RETURN, aml.ADD, text("0x1F"), ONE, ZERO })),
    method("V002", 0, code(.{ RETURN, aml.ADD, text(" 12"), ZERO, ZERO })),
    method("V003", 0, code(.{ RETURN, aml.ADD, text("000F"), ZERO, ZERO })),
    method("V004", 0, code(.{ RETURN, aml.ADD, text("12z"), ZERO, ZERO })),
    // A buffer: its first bytes, the first the lowest.
    method("V005", 0, code(.{ RETURN, aml.ADD, buffer(byte(2), &.{ 1, 2 }), ZERO, ZERO })),
    // ToInteger reads a string the C way.
    method("V006", 0, code(.{ RETURN, aml.TO_INTEGER, text("0x1F"), ZERO })),
    method("V007", 0, code(.{ RETURN, aml.TO_INTEGER, text("31"), ZERO })),
    method("V008", 0, code(.{ RETURN, aml.TO_INTEGER, text("010"), ZERO })),
    method("V009", 0, code(.{ RETURN, aml.TO_INTEGER, buffer(byte(2), &.{ 1, 2 }), ZERO })),
    method("V010", 0, code(.{ RETURN, aml.TO_BUFFER, word(0x0201), ZERO })),
    method("V011", 0, code(.{ RETURN, aml.TO_BUFFER, text("ab"), ZERO })),
    method("V012", 0, code(.{ RETURN, aml.TO_HEX_STRING, byte(0x1F), ZERO })),
    method("V013", 0, code(.{ RETURN, aml.TO_HEX_STRING, buffer(byte(2), &.{ 1, 0xAB }), ZERO })),
    method("V014", 0, code(.{ RETURN, aml.TO_DECIMAL_STRING, byte(123), ZERO })),
    method("V015", 0, code(.{ RETURN, aml.TO_DECIMAL_STRING, buffer(byte(2), &.{ 1, 200 }), ZERO })),
    method("V016", 0, code(.{ RETURN, aml.TO_STRING, buffer(byte(4), &.{ 0x61, 0x62, 0, 0x63 }), ONES, ZERO })),
    method("V017", 0, code(.{ RETURN, aml.TO_STRING, buffer(byte(3), &.{ 0x61, 0x62, 0x63 }), byte(2), ZERO })),
    method("V018", 0, code(.{ RETURN, aml.MID, text("abcdef"), byte(2), byte(3), ZERO })),
    method("V019", 0, code(.{ RETURN, aml.MID, buffer(byte(3), &.{ 1, 2, 3 }), ONE, byte(10), ZERO })),
    method("V020", 0, code(.{ RETURN, aml.MID, text("abc"), byte(5), ONE, ZERO })),
    method("V021", 0, code(.{ RETURN, aml.CONCATENATE, text("ab"), byte(0x1F), ZERO })),
    method("V022", 0, code(.{ RETURN, aml.CONCATENATE, buffer(byte(1), &.{1}), text("a"), ZERO })),
    method("V023", 0, code(.{ RETURN, aml.CONCATENATE, ONE, byte(2), ZERO })),
    method("V024", 0, code(.{ RETURN, aml.CONCATENATE, text("x"), buffer(byte(2), &.{ 1, 2 }), ZERO })),
    // A store into a name copies the bytes, and the name keeps its kind
    // and its length.
    nameOf("I002", byte(5)),
    method("V025", 0, code(.{ STORE, text("0x10"), name("I002"), RETURN, name("I002") })),
    nameOf("S001", text("abcd")),
    method("V026", 0, code(.{ STORE, byte(0x41), name("S001"), RETURN, name("S001") })),
    nameOf("B001", buffer(byte(4), &.{})),
    method("V027", 0, code(.{ STORE, buffer(byte(6), &.{ 1, 2, 3, 4, 5, 6 }), name("B001"), RETURN, name("B001") })),
    method("V028", 0, code(.{ STORE, buffer(byte(1), &.{9}), name("B001"), RETURN, name("B001") })),
    // A store into a local replaces what it held.
    method("V029", 0, code(.{ STORE, text("abc"), LOCAL0, STORE, byte(5), LOCAL0, RETURN, aml.OBJECT_TYPE, LOCAL0 })),
    // CopyObject replaces a name's object, of whatever kind.
    nameOf("I003", byte(5)),
    method("V030", 0, code(.{ aml.COPY_OBJECT, text("xyz"), name("I003"), RETURN, name("I003") })),
    // A conversion's target gets the result.
    method("V031", 0, code(.{ aml.TO_HEX_STRING, byte(0xAB), LOCAL0, RETURN, LOCAL0 })),
    method("V032", 0, code(.{ RETURN, aml.CONCATENATE_RES_TEMPLATE, buffer(byte(5), &.{ 0x22, 0x01, 0x00, 0x79, 0x00 }), buffer(byte(2), &.{ 0x79, 0x00 }), ZERO })),
}));

test "operands, stores and the explicit conversions make one kind of data another, case by case" {
    var test_machine: TestMachine = .{};
    defer test_machine.deinit();
    const ab = try loaded(&test_machine, conversions);
    defer namespace.discard(ab);
    try expectInteger(ab, "V001", 0x20);
    try expectInteger(ab, "V002", 0x12);
    try expectInteger(ab, "V003", 0xF);
    try expectInteger(ab, "V004", 0x12);
    try expectInteger(ab, "V005", 0x0201);
    try expectInteger(ab, "V006", 31);
    try expectInteger(ab, "V007", 31);
    try expectInteger(ab, "V008", 8);
    try expectInteger(ab, "V009", 0x0201);
    try expectBuffer(ab, "V010", &.{ 1, 2, 0, 0, 0, 0, 0, 0 });
    try expectBuffer(ab, "V011", "ab\x00");
    try expectString(ab, "V012", "0x1F");
    try expectString(ab, "V013", "0x01,0xAB");
    try expectString(ab, "V014", "123");
    try expectString(ab, "V015", "1,200");
    try expectString(ab, "V016", "ab");
    try expectString(ab, "V017", "ab");
    try expectString(ab, "V018", "cde");
    try expectBuffer(ab, "V019", &.{ 2, 3 });
    try expectString(ab, "V020", "");
    try expectString(ab, "V021", "ab1f");
    try expectBuffer(ab, "V022", &.{ 1, 'a', 0 });
    try expectBuffer(ab, "V023", &.{ 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0 });
    try expectString(ab, "V024", "x0x01,0x02");
    try expectInteger(ab, "V025", 0x3031_7830);
    try expectString(ab, "V026", "A\x00\x00\x00");
    try expectBuffer(ab, "V027", &.{ 1, 2, 3, 4 });
    try expectBuffer(ab, "V028", &.{ 9, 0, 0, 0 });
    try expectInteger(ab, "V029", 1);
    try expectString(ab, "V030", "xyz");
    try expectString(ab, "V031", "0xAB");
    try expectBuffer(ab, "V032", &.{ 0x22, 0x01, 0x00, 0x79, 0x00 });
}

// --- references and packages ---------------------------------------------------------------

const references = aml.table("DSDT", 2, code(.{
    nameOf("P000", package(3, code(.{ ONE, text("two"), buffer(byte(1), &.{3}) }))),
    method("R001", 0, code(.{ RETURN, aml.DEREF_OF, aml.INDEX, name("P000"), ONE, ZERO })),
    method("R002", 0, code(.{ STORE, byte(7), aml.INDEX, name("P000"), ZERO, ZERO, RETURN, aml.DEREF_OF, aml.INDEX, name("P000"), ZERO, ZERO })),
    nameOf("B002", buffer(byte(3), &.{ 1, 2, 3 })),
    method("R003", 0, code(.{ STORE, byte(0x55), aml.INDEX, name("B002"), ONE, ZERO, RETURN, name("B002") })),
    method("R004", 0, code(.{ RETURN, aml.DEREF_OF, aml.INDEX, name("B002"), ONE, ZERO })),
    method("R005", 0, code(.{ RETURN, aml.COND_REF_OF, name("NONE"), LOCAL0 })),
    nameOf("I004", byte(0x2A)),
    method("R006", 0, code(.{ ifThen(code(.{ aml.COND_REF_OF, name("I004"), LOCAL0 }), code(.{ RETURN, aml.DEREF_OF, LOCAL0 })), RETURN, ZERO })),
    method("R007", 0, code(.{ RETURN, aml.SIZE_OF, name("P000") })),
    method("R008", 0, code(.{ RETURN, aml.SIZE_OF, name("B002") })),
    nameOf("P001", package(5, code(.{ ONE, byte(5), text("x"), byte(9), byte(12) }))),
    // Match (P001, MEQ, 9, MTR, 0, 0)
    method("R009", 0, code(.{ RETURN, aml.MATCH, name("P001"), 1, byte(9), 0, ZERO, ZERO })),
    // Match (P001, MGT, 5, MLT, 12, 0)
    method("R010", 0, code(.{ RETURN, aml.MATCH, name("P001"), 5, byte(5), 3, byte(12), ZERO })),
    // Match (P001, MEQ, 100, MTR, 0, 0): none
    method("R011", 0, code(.{ RETURN, aml.MATCH, name("P001"), 1, byte(100), 0, ZERO, ZERO })),
    // Match (P001, MTR, 0, MTR, 0, 2): from the third, which is no integer
    method("R012", 0, code(.{ RETURN, aml.MATCH, name("P001"), 0, ZERO, 0, ZERO, byte(2) })),
    // An element that names something is read where it is.
    nameOf("P002", package(1, name("I004"))),
    method("R013", 0, code(.{ RETURN, aml.DEREF_OF, aml.INDEX, name("P002"), ZERO, ZERO })),
    // Index's own target holds the reference.
    method("R014", 0, code(.{ aml.INDEX, name("P000"), byte(2), LOCAL0, RETURN, aml.SIZE_OF, LOCAL0 })),
    aml.MUTEX,
    name("MX00"),
    0x00,
    aml.EVENT,
    name("EV00"),
    aml.pkg(aml.DEVICE, name("DEV0")),
    aml.REGION,
    name("RG00"),
    0x00,
    word(0x1000),
    byte(0x10),
    method("R015", 0, code(.{ RETURN, aml.OBJECT_TYPE, name("P000") })),
    method("R016", 0, code(.{ RETURN, aml.OBJECT_TYPE, name("MX00") })),
    method("R017", 0, code(.{ RETURN, aml.OBJECT_TYPE, name("EV00") })),
    method("R018", 0, code(.{ RETURN, aml.OBJECT_TYPE, name("DEV0") })),
    method("R019", 0, code(.{ RETURN, aml.OBJECT_TYPE, name("RG00") })),
    method("R020", 0, code(.{ RETURN, aml.OBJECT_TYPE, LOCAL0 })),
    method("R021", 0, code(.{ RETURN, aml.OBJECT_TYPE, aml.DEBUG })),
    method("R022", 0, code(.{ RETURN, aml.OBJECT_TYPE, name("R001") })),
    method("R023", 0, code(.{ aml.INDEX, name("B002"), ZERO, LOCAL0, RETURN, aml.OBJECT_TYPE, LOCAL0 })),
    // A name holding a reference reads what it refers to.
    nameOf("RF00", ZERO),
    method("R024", 0, code(.{ aml.COPY_OBJECT, aml.REF_OF, name("I004"), name("RF00"), RETURN, name("RF00") })),
    method("R025", 0, code(.{ RETURN, aml.INDEX, name("P000"), byte(3), ZERO })),
}));

test "Index refers into the object itself, DerefOf follows, and the operators that ask about a name" {
    var test_machine: TestMachine = .{};
    defer test_machine.deinit();
    const ab = try loaded(&test_machine, references);
    defer namespace.discard(ab);
    try expectString(ab, "R001", "two");
    try expectInteger(ab, "R002", 7);
    try expectBuffer(ab, "R003", &.{ 1, 0x55, 3 });
    try expectInteger(ab, "R004", 0x55);
    try expectInteger(ab, "R005", 0);
    try expectInteger(ab, "R006", 0x2A);
    try expectInteger(ab, "R007", 3);
    try expectInteger(ab, "R008", 3);
    try expectInteger(ab, "R009", 3);
    try expectInteger(ab, "R010", 3);
    try expectInteger(ab, "R011", ALL);
    try expectInteger(ab, "R012", 3);
    try expectInteger(ab, "R013", 0x2A);
    try expectInteger(ab, "R014", 1);
    try expectInteger(ab, "R015", 4);
    try expectInteger(ab, "R016", 9);
    try expectInteger(ab, "R017", 7);
    try expectInteger(ab, "R018", 6);
    try expectInteger(ab, "R019", 10);
    try expectInteger(ab, "R020", 0);
    try expectInteger(ab, "R021", 16);
    try expectInteger(ab, "R022", 8);
    try expectInteger(ab, "R023", 14);
    try expectInteger(ab, "R024", 0x2A);
    try testing.expectError(error.Range, evaluate(ab, "R025", &.{}));
}

// --- mutexes, events, waits ------------------------------------------------------------------

const ACQUIRE_FOREVER = [_]u8{ 0xFF, 0xFF };

const waits = aml.table("DSDT", 2, code(.{
    aml.MUTEX,
    name("MX01"),
    0x01,
    aml.MUTEX,
    name("MX03"),
    0x03,
    method("M001", 0, code(.{ RETURN, aml.ACQUIRE, name("MX01"), ACQUIRE_FOREVER })),
    // A mutex below the level held is not taken: the Acquire times out.
    method("M002", 0, code(.{ aml.ACQUIRE, name("MX03"), ACQUIRE_FOREVER, STORE, aml.ACQUIRE, name("MX01"), ACQUIRE_FOREVER, LOCAL0, aml.RELEASE, name("MX03"), RETURN, LOCAL0 })),
    // One released that is not held is said, and left.
    method("M003", 0, code(.{ aml.RELEASE, name("MX01"), RETURN, ONE })),
    // Serialized at level 2.
    method("M004", 0x28, code(.{ RETURN, ONE })),
    method("M005", 0, code(.{ aml.ACQUIRE, name("MX03"), ACQUIRE_FOREVER, STORE, name("M004"), LOCAL0, aml.RELEASE, name("MX03"), RETURN, LOCAL0 })),
    method("M006", 0, code(.{ STORE, name("M004"), LOCAL0, RETURN, LOCAL0 })),
    // Taken twice over, given back twice.
    method("M007", 0, code(.{ aml.ACQUIRE, name("MX01"), ACQUIRE_FOREVER, aml.ACQUIRE, name("MX01"), ACQUIRE_FOREVER, aml.RELEASE, name("MX01"), aml.RELEASE, name("MX01"), RETURN, ONE })),
    // Given back out of order: said, and left until it is the last.
    method("M008", 0, code(.{ aml.ACQUIRE, name("MX01"), ACQUIRE_FOREVER, aml.ACQUIRE, name("MX03"), ACQUIRE_FOREVER, aml.RELEASE, name("MX01"), aml.RELEASE, name("MX03"), aml.RELEASE, name("MX01"), RETURN, ONE })),
    // Left held: given back when the evaluation ends.
    method("M009", 0, code(.{ aml.ACQUIRE, name("MX03"), ACQUIRE_FOREVER })),
    aml.EVENT,
    name("EV01"),
    // Two signals taken, a third waited for 10 ms in vain.
    method("E001", 0, code(.{
        aml.SIGNAL,   name("EV01"), aml.SIGNAL,   name("EV01"),
        STORE,        aml.WAIT,     name("EV01"), ZERO,
        LOCAL0,       STORE,        aml.WAIT,     name("EV01"),
        ZERO,         LOCAL1,       STORE,        aml.WAIT,
        name("EV01"), byte(10),     LOCAL2,       RETURN,
        aml.ADD,      aml.ADD,      LOCAL0,       LOCAL1,
        ZERO,         aml.AND,      LOCAL2,       byte(4),
        ZERO,         ZERO,
    })),
    method("E002", 0, code(.{ aml.SIGNAL, name("EV01"), aml.RESET, name("EV01"), RETURN, aml.WAIT, name("EV01"), ZERO })),
    method("W001", 0, code(.{ aml.SLEEP, byte(5) })),
    method("W002", 0, code(.{ aml.SLEEP, word(3000) })),
    method("W003", 0, code(.{ aml.STALL, word(300) })),
    method("W004", 0, code(.{ STORE, aml.TIMER, LOCAL0, aml.SLEEP, ONE, RETURN, aml.SUBTRACT, aml.TIMER, LOCAL0, ZERO })),
}));

fn mutexAt(ab: *AcpiBase, path: [*:0]const u8) !*object.Mutex {
    const node = nodeAt(ab, path) orelse return error.NotThere;
    const held = node.object orelse return error.Empty;
    return switch (held.value) {
        .mutex => |*mutex| mutex,
        else => error.NotAMutex,
    };
}

test "mutexes taken in order of level, serialized methods, events, and the waits on the machine's clock" {
    var test_machine: TestMachine = .{};
    defer test_machine.deinit();
    const ab = try loaded(&test_machine, waits);
    defer namespace.discard(ab);
    const mx01 = try mutexAt(ab, "MX01");
    const mx03 = try mutexAt(ab, "MX03");
    try expectInteger(ab, "M001", 0);
    try testing.expect(mx01.owner == null);
    var lines = test_machine.lines;
    try expectInteger(ab, "M002", ALL);
    try testing.expectEqual(lines + 1, test_machine.lines);
    try testing.expect(test_machine.said("level"));
    try testing.expect(mx01.owner == null and mx03.owner == null);
    try expectInteger(ab, "M003", 1);
    try testing.expect(test_machine.said("not held"));
    try testing.expectError(error.Mutex, evaluate(ab, "M005", &.{}));
    try testing.expect(mx03.owner == null);
    try expectInteger(ab, "M006", 1);
    lines = test_machine.lines;
    try expectInteger(ab, "M007", 1);
    try testing.expectEqual(lines, test_machine.lines);
    try expectInteger(ab, "M008", 1);
    try testing.expectEqual(lines + 1, test_machine.lines);
    try testing.expect(mx01.owner == null and mx03.owner == null);
    const result = try evaluate(ab, "M009", &.{});
    interpreter.release(ab, result);
    try testing.expect(mx03.owner == null and mx03.depth == 0);

    const slept = test_machine.slept;
    try expectInteger(ab, "E001", 4);
    try testing.expect(test_machine.slept - slept >= 10_000);
    try expectInteger(ab, "E002", ALL);

    var before = test_machine.slept;
    _ = try evaluate(ab, "W001", &.{});
    try testing.expectEqual(before + 5000, test_machine.slept);
    before = test_machine.slept;
    _ = try evaluate(ab, "W002", &.{});
    try testing.expectEqual(before + 2_000_000, test_machine.slept);
    try testing.expect(test_machine.said("two seconds"));
    _ = try evaluate(ab, "W003", &.{});
    try testing.expectEqual(@as(u64, 255), test_machine.stalled);
    try testing.expect(test_machine.said("255"));
    const elapsed = try evaluate(ab, "W004", &.{});
    try testing.expect(try integerOf(elapsed) >= 10_000);
}

// --- Notify --------------------------------------------------------------------------------

const notifications = aml.table("DSDT", 2, code(.{
    aml.pkg(aml.SCOPE, name("\\_SB") ++ aml.pkg(aml.DEVICE, name("DEV1"))),
    method("N001", 0, code(.{ aml.NOTIFY, name("\\_SB.DEV1"), byte(0x80) })),
    nameOf("I005", ONE),
    method("N002", 0, code(.{ aml.NOTIFY, name("I005"), ONE })),
    // Forty sent: as many as there is room for kept, the rest lost.
    method("N003", 0, code(.{
        STORE,                                                                                                                     ZERO, LOCAL0,
        whileDo(code(.{ aml.LLESS, LOCAL0, byte(40) }), code(.{ aml.NOTIFY, name("\\_SB.DEV1"), LOCAL0, aml.INCREMENT, LOCAL0 })),
    })),
}));

test "Notify keeps what it is about and its value for whatever takes them, and counts what it has no room for" {
    var test_machine: TestMachine = .{};
    defer test_machine.deinit();
    const ab = try loaded(&test_machine, notifications);
    defer namespace.discard(ab);
    _ = try evaluate(ab, "N001", &.{});
    const taken = notice.take(ab) orelse return error.NoNotice;
    try testing.expectEqual(nodeAt(ab, "\\_SB.DEV1").?, taken.node);
    try testing.expectEqual(@as(u32, 0x80), taken.value);
    namespace.unhold(ab, taken.node);
    try testing.expect(notice.take(ab) == null);
    try testing.expectError(error.Type, evaluate(ab, "N002", &.{}));
    _ = try evaluate(ab, "N003", &.{});
    try testing.expectEqual(@as(u32, base.MOST_NOTICES), ab.notices.count);
    try testing.expectEqual(@as(u32, 40 - base.MOST_NOTICES), ab.notices.lost);
    const first = notice.take(ab) orelse return error.NoNotice;
    try testing.expectEqual(@as(u32, 0), first.value);
    namespace.unhold(ab, first.node);
    // The rest are let go of with the namespace.
}

// --- Load and LoadTable --------------------------------------------------------------------

const extra = aml.table("SSDT", 2, nameOf("LDN0", byte(0x42)));
const other = aml.table("SSDT", 2, nameOf("LDN1", byte(0x43)));

const loading = aml.table("DSDT", 2, code(.{
    nameOf("TB00", buffer(byte(extra.len), extra)),
    nameOf("LDP0", ZERO),
    method("D001", 0, code(.{ aml.LOAD, name("TB00"), LOCAL0, RETURN, LOCAL0 })),
    method("D002", 0, code(.{ RETURN, aml.LOAD_TABLE, text("SSDT"), text("POWER"), text("TESTTABL"), text("\\_SB"), text("\\LDP0"), byte(5) })),
    method("D003", 0, code(.{ RETURN, aml.LOAD_TABLE, text("SSDT"), text("OTHER"), text(""), text(""), text(""), ZERO })),
    method("D004", 0, code(.{ aml.UNLOAD, LOCAL0, RETURN, ONE })),
}));

test "Load takes a table from a buffer, LoadTable one of the firmware's, each answering whether it loaded" {
    var test_machine: TestMachine = .{ .tables = &.{other} };
    defer test_machine.deinit();
    const ab = try loaded(&test_machine, loading);
    defer namespace.discard(ab);
    try expectInteger(ab, "D001", ALL);
    try testing.expectEqual(@as(u64, 0x42), try integerAt(ab, "\\LDN0"));
    try expectInteger(ab, "D002", ALL);
    try testing.expectEqual(@as(u64, 0x43), try integerAt(ab, "\\_SB.LDN1"));
    try testing.expectEqual(@as(u64, 5), try integerAt(ab, "\\LDP0"));
    try expectInteger(ab, "D003", 0);
    try testing.expectEqual(@as(u16, 3), ab.tables);
    try expectInteger(ab, "D004", 1);
    try testing.expect(test_machine.said("Unload"));
}

// --- what the interpreter answers itself, Debug, Fatal ----------------------------------------

const answers = aml.table("DSDT", 2, code(.{
    method("O001", 0, code(.{ RETURN, name("\\_OSI"), text("Windows 2022") })),
    method("O002", 0, code(.{ RETURN, name("\\_OSI"), text("Linux") })),
    method("O003", 0, code(.{ RETURN, name("_OSI"), text("Windows 2009") })),
    method("O004", 0, code(.{ RETURN, name("\\_OS") })),
    method("O005", 0, code(.{ RETURN, name("\\_REV") })),
    method("O006", 0, code(.{ RETURN, name("\\_OSI"), text("Extended Address Space Descriptor") })),
    method("G001", 0, code(.{ STORE, text("hello"), aml.DEBUG })),
    method("G002", 0, code(.{ aml.FATAL, 0x01, 0x02, 0x00, 0x00, 0x00, byte(3), RETURN, byte(5) })),
}));

test "\\_OSI answers for the versions of Windows, \\_OS and \\_REV are there, Debug and Fatal are said" {
    var test_machine: TestMachine = .{};
    defer test_machine.deinit();
    const ab = try loaded(&test_machine, answers);
    defer namespace.discard(ab);
    try expectInteger(ab, "O001", ALL);
    try expectInteger(ab, "O002", 0);
    try expectInteger(ab, "O003", ALL);
    try expectString(ab, "O004", "Microsoft Windows NT");
    try expectInteger(ab, "O005", 2);
    try expectInteger(ab, "O006", ALL);
    const lines = test_machine.lines;
    _ = try evaluate(ab, "G001", &.{});
    try testing.expectEqual(lines + 1, test_machine.lines);
    try testing.expect(test_machine.said("Debug"));
    try expectInteger(ab, "G002", 5);
    try testing.expect(test_machine.said("Fatal"));
}
