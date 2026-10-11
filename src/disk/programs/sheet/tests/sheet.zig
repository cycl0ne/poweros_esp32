// SPDX-License-Identifier: MIT
//! Host tests of Sheet's workings: numbers read and written, formulas read
//! and worked out, references moved, the cells kept, undone and moved in
//! rows and columns, and CSV read and written. The window is not here.

const std = @import("std");
const host = @import("host_rom");
const kexec = host.exec;
const number = @import("../number.zig");
const formula = @import("../formula.zig");
const eval = @import("../eval.zig");
const cells = @import("../cells.zig");
const csv = @import("../csv.zig");

const testing = std.testing;

fn formatted(value: f64, digits: u32) []const u8 {
    const State = struct {
        var out: [32]u8 = undefined;
    };
    return number.format(value, digits, &State.out);
}

test "Sheet: numbers as typed" {
    try testing.expectEqual(@as(?f64, 12), number.parse("12"));
    try testing.expectEqual(@as(?f64, -1500), number.parse(" -1.5e3 "));
    try testing.expectEqual(@as(?f64, 0.15), number.parse("15%"));
    try testing.expectEqual(@as(?f64, 0.5), number.parse(".5"));
    try testing.expectEqual(@as(?f64, 1), number.parse("1."));
    try testing.expectEqual(@as(?f64, 0.1), number.parse("0.1"));
    // Past nineteen digits the rest only scale it.
    try testing.expectApproxEqRel(@as(f64, 123456789012345678901234.0), number.parse("123456789012345678901234").?, 1e-15);
    for ([_][]const u8{ "", " ", "abc", "1e", "-", ".", "1,5", "1.2.3", "1e999", "12a" }) |text| {
        try testing.expectEqual(@as(?f64, null), number.parse(text));
    }
}

test "Sheet: numbers written in so many digits" {
    try testing.expectEqualStrings("0", formatted(0, 10));
    try testing.expectEqualStrings("1234.5", formatted(1234.5, 10));
    try testing.expectEqualStrings("-42", formatted(-42, 10));
    try testing.expectEqualStrings("0.3", formatted(0.1 + 0.2, 15));
    try testing.expectEqualStrings("0.3333333333", formatted(1.0 / 3.0, 10));
    try testing.expectEqualStrings("1E+20", formatted(1e20, 10));
    try testing.expectEqualStrings("1.23456789E+11", formatted(123456789012, 10));
    try testing.expectEqualStrings("-0.00001234", formatted(-0.00001234, 10));
    try testing.expectEqualStrings("1.5E-07", formatted(1.5e-7, 10));
    try testing.expectEqualStrings("3", formatted(2.5, 1));
    try testing.expectEqualStrings("123457", formatted(123456.7, 6));
    try testing.expectEqualStrings("1.2346E+05", formatted(123456.7, 5));
    try testing.expectEqualStrings("1E+100", formatted(1e100, 10));
    try testing.expectEqualStrings("2.2250738585E-308", formatted(2.2250738585072014e-308, 11));
}

test "Sheet: the names of cells, and references read" {
    var letters: [2]u8 = undefined;
    try testing.expectEqualStrings("A", formula.columnName(0, &letters));
    try testing.expectEqualStrings("Z", formula.columnName(25, &letters));
    try testing.expectEqualStrings("AA", formula.columnName(26, &letters));
    try testing.expectEqualStrings("IV", formula.columnName(255, &letters));
    var name: [8]u8 = undefined;
    try testing.expectEqualStrings("A1", formula.cellName(0, 0, &name));
    try testing.expectEqualStrings("IV9999", formula.cellName(9998, 255, &name));

    const fixed = formula.readRef("$B$7+1").?;
    try testing.expectEqual(@as(usize, 4), fixed.len);
    try testing.expectEqual(@as(u32, 6), fixed.ref.row);
    try testing.expectEqual(@as(u32, 1), fixed.ref.col);
    try testing.expect(fixed.ref.row_fixed and fixed.ref.col_fixed);
    try testing.expectEqual(@as(u32, 255), formula.readRef("iv1").?.ref.col);
    for ([_][]const u8{ "A0", "A01", "IW1", "A10000", "ABC1", "A1B", "SUM(", "1A" }) |text| {
        try testing.expect(formula.readRef(text) == null);
    }
    var written: [10]u8 = undefined;
    try testing.expectEqualStrings("$B7", formula.writeRef(.{ .row = 6, .col = 1, .col_fixed = true }, &written));
}

test "Sheet: what is wrong with a formula" {
    var ops: [64]formula.Op = undefined;
    const cases = [_]struct { text: []const u8, problem: formula.Problem }{
        .{ .text = "=1+", .problem = .syntax },
        .{ .text = "=", .problem = .syntax },
        .{ .text = "=FOO(1)", .problem = .unknown_name },
        .{ .text = "=FOO", .problem = .unknown_name },
        .{ .text = "=SUM()", .problem = .arguments },
        .{ .text = "=MOD(1)", .problem = .arguments },
        .{ .text = "=(1", .problem = .parentheses },
        .{ .text = "=1)", .problem = .parentheses },
        .{ .text = "=1,2", .problem = .parentheses },
        .{ .text = "=\"open", .problem = .syntax },
        .{ .text = "=A1:", .problem = .syntax },
        .{ .text = "=SUM(A1:B2)*-2%", .problem = .none },
        .{ .text = "=PI()", .problem = .none },
    };
    for (cases) |case| {
        try testing.expectEqual(case.problem, formula.compile(case.text, &ops).problem);
    }
    try testing.expectEqual(formula.Problem.too_long, formula.compile("=1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1", &ops).problem);
}

test "Sheet: references moved as a formula is copied, rows put in and taken out" {
    var out: [128]u8 = undefined;
    const Move = formula.Move;
    try testing.expectEqualStrings("=B2+$B$2+$C2+D$1", formula.rewrite("=A1+$B$2+$C1+C$1", Move{ .offset = .{ .rows = 1, .cols = 1 } }, &out).?);
    try testing.expectEqualStrings("=#REF!*2", formula.rewrite("=A1*2", Move{ .offset = .{ .rows = -1, .cols = 0 } }, &out).?);
    // Text in quotes is never a reference.
    try testing.expectEqualStrings("=\"A1\"&B1", formula.rewrite("=\"A1\"&A1", Move{ .offset = .{ .rows = 0, .cols = 1 } }, &out).?);
    // Inserting moves fixed and loose references alike.
    try testing.expectEqualStrings("=SUM(A1:A6)+$A$7", formula.rewrite("=SUM(A1:A5)+$A$6", Move{ .insert = .{ .columns = false, .at = 2, .count = 1 } }, &out).?);
    // Deleting: what was deleted is #REF!, a range shrinks, the rest moves.
    try testing.expectEqualStrings("=#REF!+A2+SUM(A1:A3)", formula.rewrite("=A2+A3+SUM(A1:A4)", Move{ .delete = .{ .columns = false, .at = 1, .count = 1 } }, &out).?);
    try testing.expectEqualStrings("=SUM(#REF!)", formula.rewrite("=SUM(B1:C9)", Move{ .delete = .{ .columns = true, .at = 1, .count = 2 } }, &out).?);
    try testing.expectEqualStrings("=SUM(A1:B9)", formula.rewrite("=SUM(A1:D9)", Move{ .delete = .{ .columns = true, .at = 1, .count = 2 } }, &out).?);
    // Not a formula: as it is.
    try testing.expectEqualStrings("A1", formula.rewrite("A1", Move{ .offset = .{ .rows = 1, .cols = 1 } }, &out).?);
}

/// A sheet on the host's exec, its cells given in one step.
const Fixture = struct {
    sheet: *cells.Sheet,

    fn init() !Fixture {
        try kexec.setUp();
        const sheet = cells.Sheet.create(kexec.SysBase.iface()) orelse return error.OutOfMemory;
        return .{ .sheet = sheet };
    }

    fn deinit(fixture: *Fixture) !void {
        fixture.sheet.destroy();
        try kexec.expectNoLeaks();
        kexec.deinit();
    }

    fn put(fixture: *Fixture, name: []const u8, typed: []const u8) !void {
        const place = formula.readRef(name).?.ref;
        fixture.sheet.begin();
        try testing.expect(fixture.sheet.changeText(place.row, place.col, typed));
        try testing.expect(fixture.sheet.end());
    }

    fn value(fixture: *Fixture, name: []const u8) eval.Value {
        const place = formula.readRef(name).?.ref;
        const cell = fixture.sheet.find(place.row, place.col) orelse return .{};
        return cell.value;
    }

    fn text(fixture: *Fixture, name: []const u8) []const u8 {
        const place = formula.readRef(name).?.ref;
        return fixture.sheet.textAt(place.row, place.col);
    }

    fn expectNumber(fixture: *Fixture, name: []const u8, expected: f64) !void {
        const got = fixture.value(name);
        try testing.expectEqual(eval.Kind.number, got.kind);
        try testing.expectApproxEqAbs(expected, got.number, 1e-9);
    }

    fn expectError(fixture: *Fixture, name: []const u8, expected: eval.Error) !void {
        const got = fixture.value(name);
        try testing.expectEqual(eval.Kind.err, got.kind);
        try testing.expectEqual(expected, got.err);
    }

    fn expectText(fixture: *Fixture, name: []const u8, expected: []const u8) !void {
        const got = fixture.value(name);
        try testing.expectEqual(eval.Kind.text, got.kind);
        try testing.expectEqualStrings(expected, got.text);
    }
};

test "Sheet: formulas worked out" {
    var fixture = try Fixture.init();
    try fixture.put("A1", "2");
    try fixture.put("A2", "3");
    try fixture.put("A3", "=A1+A2*2");
    try fixture.expectNumber("A3", 8);
    // Negation binds before a power, and powers go left to right.
    try fixture.put("B1", "=-2^2");
    try fixture.expectNumber("B1", 4);
    try fixture.put("B2", "=2^3^2");
    try fixture.expectNumber("B2", 64);
    try fixture.put("B3", "=SUM(A1:A3)");
    try fixture.expectNumber("B3", 13);
    try fixture.put("B4", "=AVERAGE(A1:A2)");
    try fixture.expectNumber("B4", 2.5);
    try fixture.put("B5", "=MAX(A1:A3)-MIN(A1:A3)");
    try fixture.expectNumber("B5", 6);
    try fixture.put("B6", "=COUNT(A1:B5)");
    try fixture.expectNumber("B6", 8);
    try fixture.put("B7", "=1/0");
    try fixture.expectError("B7", .div0);
    try fixture.put("B8", "=\"a\"+1");
    try fixture.expectError("B8", .value);
    try fixture.put("B9", "=\"3\"+1");
    try fixture.expectNumber("B9", 4);
    try fixture.put("C1", "=A1&\" units\"");
    try fixture.expectText("C1", "2 units");
    try fixture.put("C2", "=IF(A1>1,\"big\",\"small\")");
    try fixture.expectText("C2", "big");
    try fixture.put("C3", "=LEN(\"say \"\"hi\"\"\")");
    try fixture.expectNumber("C3", 8);
    try fixture.put("C4", "=ROUND(2.345,2)");
    try fixture.expectNumber("C4", 2.35);
    try fixture.put("C5", "=MOD(-3,2)+10%");
    try fixture.expectNumber("C5", 1.1);
    try fixture.put("C6", "=UPPER(C1)");
    try fixture.expectText("C6", "2 UNITS");
    try fixture.put("C7", "=SQRT(-1)");
    try fixture.expectError("C7", .num);
    try fixture.put("C8", "=A1=2");
    try testing.expectEqual(eval.Kind.boolean, fixture.value("C8").kind);
    // An error anywhere in a sum is the sum's.
    try fixture.put("C9", "=SUM(B7,1)");
    try fixture.expectError("C9", .div0);
    // A text in a range is passed over; written into the formula it counts.
    try fixture.put("D1", "words");
    try fixture.put("D2", "=SUM(D1,A1)");
    try fixture.expectNumber("D2", 2);
    try fixture.put("D3", "=Z99");
    try fixture.expectNumber("D3", 0);
    try fixture.put("D4", "=#REF!+1");
    try fixture.expectError("D4", .ref);
    try fixture.put("D5", "=NOPE(1)");
    try fixture.expectError("D5", .name);

    // A change reaches every formula that depends on it.
    try fixture.put("A1", "10");
    try fixture.expectNumber("A3", 16);
    try fixture.expectNumber("B3", 29);
    try fixture.expectText("C1", "10 units");
    try fixture.deinit();
}

test "Sheet: a circle of formulas, and a long chain of them" {
    var fixture = try Fixture.init();
    try fixture.put("A1", "=A2+1");
    try fixture.put("A2", "=A1+1");
    try fixture.expectError("A1", .circular);
    try fixture.expectError("A2", .circular);
    try fixture.put("B1", "=B1");
    try fixture.expectError("B1", .circular);

    // Each worked out after the one it names, with no recursion. Put in
    // outside any step, so no history is kept of them.
    try testing.expect(fixture.sheet.changeText(0, 2, "1"));
    var row: u32 = 2;
    while (row <= 150) : (row += 1) {
        var typed: [16]u8 = undefined;
        const formula_text = try std.fmt.bufPrint(&typed, "=C{d}+1", .{row - 1});
        try testing.expect(fixture.sheet.changeText(row - 1, 2, formula_text));
    }
    fixture.sheet.recalculate();
    try fixture.expectNumber("C150", 150);
    try fixture.put("C1", "-99");
    try fixture.expectNumber("C150", 50);
    try fixture.deinit();
}

test "Sheet: steps undone and done again" {
    var fixture = try Fixture.init();
    try fixture.put("A1", "1");
    try fixture.put("A2", "=A1*10");
    try fixture.put("A1", "5");
    try fixture.expectNumber("A2", 50);
    try testing.expect(fixture.sheet.undo());
    try fixture.expectNumber("A2", 10);
    try testing.expect(fixture.sheet.undo());
    try testing.expect(fixture.sheet.find(1, 0) == null);
    try testing.expect(fixture.sheet.redo());
    try fixture.expectNumber("A2", 10);
    try testing.expect(fixture.sheet.redo());
    try fixture.expectNumber("A2", 50);
    try testing.expect(!fixture.sheet.redo());
    // A new step forgets what could be redone.
    try testing.expect(fixture.sheet.undo());
    try fixture.put("B1", "x");
    try testing.expect(!fixture.sheet.canRedo());

    // Clearing an area is one step.
    try testing.expect(fixture.sheet.clear(.{ .top = 0, .left = 0, .bottom = 9, .right = 9 }));
    try testing.expect(fixture.sheet.count == 0);
    try testing.expect(fixture.sheet.undo());
    try testing.expectEqualStrings("x", fixture.text("B1"));
    try fixture.expectNumber("A2", 10);
    try fixture.deinit();
}

test "Sheet: rows and columns put in and taken out, and undone" {
    var fixture = try Fixture.init();
    try fixture.put("A1", "1");
    try fixture.put("A2", "2");
    try fixture.put("A3", "3");
    try fixture.put("A4", "4");
    try fixture.put("B1", "=SUM(A1:A4)");
    try fixture.put("C1", "=A3*2");

    try testing.expectEqual(cells.ShiftResult.done, fixture.sheet.shiftLines(false, 0, 1, true));
    try testing.expect(fixture.sheet.find(0, 0) == null);
    try testing.expectEqualStrings("=SUM(A2:A5)", fixture.text("B2"));
    try testing.expectEqualStrings("=A4*2", fixture.text("C2"));
    try fixture.expectNumber("B2", 10);
    try fixture.expectNumber("C2", 6);

    // Row 3, now holding the 2, taken out: the sum shrinks, the 3 moves up.
    try testing.expectEqual(cells.ShiftResult.done, fixture.sheet.shiftLines(false, 2, 1, false));
    try testing.expectEqualStrings("=SUM(A2:A4)", fixture.text("B2"));
    try fixture.expectNumber("B2", 8);
    try testing.expectEqualStrings("=A3*2", fixture.text("C2"));
    try fixture.expectNumber("C2", 6);

    // The row a formula names taken out: #REF!.
    try testing.expectEqual(cells.ShiftResult.done, fixture.sheet.shiftLines(false, 2, 1, false));
    try testing.expectEqualStrings("=#REF!*2", fixture.text("C2"));
    try fixture.expectError("C2", .ref);
    try fixture.expectNumber("B2", 5);

    // Undone, all the way back.
    try testing.expect(fixture.sheet.undo());
    try testing.expect(fixture.sheet.undo());
    try testing.expect(fixture.sheet.undo());
    try testing.expectEqualStrings("=SUM(A1:A4)", fixture.text("B1"));
    try testing.expectEqualStrings("=A3*2", fixture.text("C1"));
    try testing.expectEqualStrings("1", fixture.text("A1"));
    try testing.expectEqualStrings("4", fixture.text("A4"));
    try fixture.expectNumber("B1", 10);
    // And done again.
    try testing.expect(fixture.sheet.redo());
    try testing.expectEqualStrings("=SUM(A2:A5)", fixture.text("B2"));

    // Columns the same way: C taken out, what named it is #REF!, and
    // what was right of it moves left.
    try fixture.put("E1", "=C2+1");
    try testing.expectEqual(cells.ShiftResult.done, fixture.sheet.shiftLines(true, 2, 1, false));
    try testing.expectEqualStrings("=#REF!+1", fixture.text("D1"));
    try testing.expect(fixture.sheet.find(1, 2) == null);

    // Nothing is pushed off the end of the sheet.
    try fixture.put("A9999", "last");
    try testing.expectEqual(cells.ShiftResult.no_room, fixture.sheet.shiftLines(false, 0, 1, true));
    try fixture.deinit();
}

test "Sheet: filling, copying and pasting" {
    var fixture = try Fixture.init();
    try fixture.put("B1", "10");
    try fixture.put("B2", "20");
    try fixture.put("B3", "30");
    try fixture.put("A1", "=B1+$B$1");
    try testing.expect(fixture.sheet.fill(.{ .top = 0, .left = 0, .bottom = 2, .right = 0 }, true));
    try testing.expectEqualStrings("=B2+$B$1", fixture.text("A2"));
    try testing.expectEqualStrings("=B3+$B$1", fixture.text("A3"));
    try fixture.expectNumber("A3", 40);

    var block: cells.Block = .{};
    try testing.expect(fixture.sheet.copyBlock(.{ .top = 0, .left = 0, .bottom = 1, .right = 1 }, &block));
    try testing.expectEqual(@as(u32, 2), block.rows);
    try testing.expect(fixture.sheet.pasteBlock(&block, 4, 2));
    try testing.expectEqualStrings("=D5+$B$1", fixture.text("C5"));
    try testing.expectEqualStrings("10", fixture.text("D5"));
    try fixture.expectNumber("C5", 20);

    try testing.expect(fixture.sheet.pasteText("1\t2\r\n3\t\t5\n", 10, 0));
    try testing.expectEqualStrings("2", fixture.text("B11"));
    try testing.expectEqualStrings("5", fixture.text("C12"));
    try testing.expect(fixture.sheet.find(11, 1) == null);
    try testing.expect(fixture.sheet.find(12, 0) == null);
    block.deinit(fixture.sheet.sys);
    try fixture.deinit();
}

test "Sheet: CSV read and written" {
    var fixture = try Fixture.init();
    var file = "name,value\r\n\"Smith, J.\",12\n\"say \"\"hi\"\"\",=B2*2\n".*;
    const read = csv.read(fixture.sheet, &file);
    try testing.expectEqual(@as(u8, ','), read.form.separator);
    try testing.expectEqualStrings("Smith, J.", fixture.text("A2"));
    try testing.expectEqualStrings("say \"hi\"", fixture.text("A3"));
    try fixture.expectNumber("B3", 24);
    try testing.expect(!fixture.sheet.changed);
    const written = csv.write(fixture.sheet, read.form).?;
    try testing.expectEqualStrings("name,value\n\"Smith, J.\",12\n\"say \"\"hi\"\"\",=B2*2\n", written);
    fixture.sheet.sys.FreeVec(@constCast(written.ptr));

    // Semicolons and decimal commas, read so and written back so.
    var german = "\xEF\xBB\xBFPreis;1,5\nM\xC3\xBCller;=B1*2\n".*;
    const second = csv.read(fixture.sheet, &german);
    try testing.expectEqual(@as(u8, ';'), second.form.separator);
    try testing.expect(second.form.decimal_comma);
    try fixture.expectNumber("B1", 1.5);
    try fixture.expectNumber("B2", 3);
    try testing.expectEqualStrings("M\xFCller", fixture.text("A2"));
    const back = csv.write(fixture.sheet, second.form).?;
    try testing.expectEqualStrings("Preis;1,5\nM\xFCller;=B1*2\n", back);
    fixture.sheet.sys.FreeVec(@constCast(back.ptr));
    try fixture.deinit();
}
