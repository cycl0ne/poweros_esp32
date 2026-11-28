// SPDX-License-Identifier: MPL-2.0
//! What the interpreter's host tests share: a table loaded on the test
//! machine, a method of it called by its path, and what it returned
//! checked - an integer, a string, a buffer - with the method named
//! where it is not what was expected.

const std = @import("std");
const testing = std.testing;
const AcpiBase = @import("../acpi_base.zig").AcpiBase;
const namespace = @import("../namespace/_namespace.zig");
const Node = namespace.Node;
const object = @import("../object/_object.zig");
const load = @import("../aml/load.zig");
const interpreter = @import("../interpreter/_interpreter.zig");
const Item = interpreter.Item;
const TestMachine = @import("machine.zig").TestMachine;

/// Every bit of a 64-bit integer set: true.
pub const ALL: u64 = 0xFFFF_FFFF_FFFF_FFFF;

/// The namespace made on `test_machine` and `table` loaded into it,
/// which has to load without a fault.
pub fn loaded(test_machine: *TestMachine, table: []const u8) !*AcpiBase {
    const ab = test_machine.base();
    if (!namespace.make(ab)) return error.NoMemory;
    const result = load.loadTable(ab, .{ .code = table, .index = 1 });
    if (result.failed + result.unknown + result.broken + result.missing + result.again != 0) {
        namespace.discard(ab);
        return error.LoadFailed;
    }
    return ab;
}

pub fn nodeAt(ab: *AcpiBase, path: [*:0]const u8) ?*Node {
    var spelled: namespace.TextPath = undefined;
    if (!namespace.parseText(path, &spelled)) return null;
    return namespace.find(ab, ab.root.?, spelled.path, .exact);
}

/// The method at `path` called with `args`: what it returned, the
/// caller's.
pub fn evaluate(ab: *AcpiBase, path: [*:0]const u8, args: []const Item) !Item {
    const node = nodeAt(ab, path) orelse return error.NotThere;
    return interpreter.call(ab, node, args);
}

pub fn integerOf(item: Item) !u64 {
    return switch (item) {
        .integer => |value| value,
        .object => |held| switch (held.value) {
            .integer => |value| value,
            else => error.NotAnInteger,
        },
        else => error.NotAnInteger,
    };
}

pub fn bytesOf(item: Item, kind: object.Kind) ![]const u8 {
    const held = switch (item) {
        .object => |held| held,
        else => return error.NoBytes,
    };
    if (held.kind() != kind) return error.WrongKind;
    return switch (held.value) {
        .string, .buffer => |bytes| bytes.slice(),
        else => error.NoBytes,
    };
}

pub fn expectInteger(ab: *AcpiBase, path: [*:0]const u8, expected: u64) !void {
    return expectIntegerWith(ab, path, &.{}, expected);
}

pub fn expectIntegerWith(ab: *AcpiBase, path: [*:0]const u8, args: []const Item, expected: u64) !void {
    const result = try evaluate(ab, path, args);
    defer interpreter.release(ab, result);
    testing.expectEqual(expected, try integerOf(result)) catch |err| {
        std.debug.print("{s} returned the wrong integer\n", .{path});
        return err;
    };
}

pub fn expectString(ab: *AcpiBase, path: [*:0]const u8, expected: []const u8) !void {
    const result = try evaluate(ab, path, &.{});
    defer interpreter.release(ab, result);
    testing.expectEqualSlices(u8, expected, try bytesOf(result, .string)) catch |err| {
        std.debug.print("{s} returned the wrong string\n", .{path});
        return err;
    };
}

pub fn expectBuffer(ab: *AcpiBase, path: [*:0]const u8, expected: []const u8) !void {
    const result = try evaluate(ab, path, &.{});
    defer interpreter.release(ab, result);
    testing.expectEqualSlices(u8, expected, try bytesOf(result, .buffer)) catch |err| {
        std.debug.print("{s} returned the wrong buffer\n", .{path});
        return err;
    };
}

/// What the name at `path` holds, an integer.
pub fn integerAt(ab: *AcpiBase, path: [*:0]const u8) !u64 {
    const node = nodeAt(ab, path) orelse return error.NotThere;
    const held = node.object orelse return error.Empty;
    return switch (held.value) {
        .integer => |value| value,
        else => error.NotAnInteger,
    };
}
