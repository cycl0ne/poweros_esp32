// SPDX-License-Identifier: MIT
//! JSON read onto a tape: every value one node, in the order the text
//! has them, a container followed by everything in it.
//!
//! The text is read twice: once to count the nodes, so the caller can
//! allocate exactly that many, and once to fill them. A node of an
//! array or object knows how many members it has and where the node
//! after all of them is, so a member is found by skipping from one to
//! the next, never by reading the text again. An object's members are
//! pairs: a string node for the name, then the value.
//!
//! A string node points into the text, with its escapes as written:
//! names are compared as they stand, which is what a file of known
//! names needs. A number is kept as an f32.

/// What a node holds.
pub const Kind = enum(u8) { null_value, false_value, true_value, number, string, array, object };

/// One value.
pub const Node = extern struct {
    kind: Kind,
    pad: [3]u8 = @splat(0),
    /// A number's value.
    number: f32 = 0,
    /// Where a string's bytes start in the text.
    at: u32 = 0,
    /// A string's length in bytes; an array's items, an object's pairs.
    length: u32 = 0,
    /// The node after this one and all it holds.
    next: u32 = 0,
};

/// The deepest nesting read.
pub const max_depth = 64;

/// The text and its nodes; node 0 is the outermost value.
pub const Tape = struct {
    text: []const u8,
    nodes: []const Node,

    pub fn kind(tape: Tape, index: u32) Kind {
        return tape.nodes[index].kind;
    }

    /// The value named `name` in the object at `index`, or null.
    pub fn get(tape: Tape, index: ?u32, name: []const u8) ?u32 {
        const object = index orelse return null;
        if (tape.nodes[object].kind != .object) return null;
        var at = object + 1;
        var left = tape.nodes[object].length;
        while (left > 0) : (left -= 1) {
            const key = tape.nodes[at];
            if (equal(tape.text[key.at..][0..key.length], name)) return at + 1;
            at = tape.nodes[at + 1].next;
        }
        return null;
    }

    /// Item `n` of the array at `index`, or null.
    pub fn item(tape: Tape, index: ?u32, n: u32) ?u32 {
        const array = index orelse return null;
        if (tape.nodes[array].kind != .array or n >= tape.nodes[array].length) return null;
        var at = array + 1;
        var left = n;
        while (left > 0) : (left -= 1) at = tape.nodes[at].next;
        return at;
    }

    /// An array's items in order.
    pub fn items(tape: Tape, index: ?u32) Items {
        const array = index orelse return .{ .tape = tape, .at = 0, .left = 0 };
        if (tape.nodes[array].kind != .array) return .{ .tape = tape, .at = 0, .left = 0 };
        return .{ .tape = tape, .at = array + 1, .left = tape.nodes[array].length };
    }

    /// How many items or pairs a container has; 0 for anything else.
    pub fn count(tape: Tape, index: ?u32) u32 {
        const at = index orelse return 0;
        const node = tape.nodes[at];
        return if (node.kind == .array or node.kind == .object) node.length else 0;
    }

    /// A number, or the first item of an array of them.
    pub fn number(tape: Tape, index: ?u32) ?f32 {
        const at = index orelse return null;
        return switch (tape.nodes[at].kind) {
            .number => tape.nodes[at].number,
            .true_value => 1,
            .false_value => 0,
            .array => if (tape.nodes[at].length > 0 and tape.nodes[at + 1].kind == .number) tape.nodes[at + 1].number else null,
            else => null,
        };
    }

    /// A string's bytes, escapes as written.
    pub fn string(tape: Tape, index: ?u32) ?[]const u8 {
        const at = index orelse return null;
        const node = tape.nodes[at];
        if (node.kind != .string) return null;
        return tape.text[node.at..][0..node.length];
    }

    /// Whether the value is true, or a number other than 0.
    pub fn flag(tape: Tape, index: ?u32) bool {
        const value = tape.number(index) orelse return false;
        return value != 0;
    }
};

/// Walks an array.
pub const Items = struct {
    tape: Tape,
    at: u32,
    left: u32,

    pub fn next(walk: *Items) ?u32 {
        if (walk.left == 0) return null;
        const here = walk.at;
        walk.at = walk.tape.nodes[here].next;
        walk.left -= 1;
        return here;
    }
};

fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// The text read onto `nodes`, or only counted when `nodes` is null:
/// how many nodes it takes, or null when it is not JSON.
pub fn parse(text: []const u8, nodes: ?[]Node) ?u32 {
    var reader = Reader{ .text = text, .nodes = nodes };
    reader.value(0) orelse return null;
    reader.space();
    if (reader.at != text.len) return null;
    return reader.used;
}

const Reader = struct {
    text: []const u8,
    nodes: ?[]Node,
    at: usize = 0,
    used: u32 = 0,

    fn space(reader: *Reader) void {
        while (reader.at < reader.text.len) : (reader.at += 1) {
            switch (reader.text[reader.at]) {
                ' ', '\t', '\r', '\n' => {},
                else => return,
            }
        }
    }

    fn peek(reader: *Reader) ?u8 {
        reader.space();
        return if (reader.at < reader.text.len) reader.text[reader.at] else null;
    }

    /// A new node, its index.
    fn add(reader: *Reader, node: Node) u32 {
        const index = reader.used;
        if (reader.nodes) |nodes| nodes[index] = node;
        reader.used += 1;
        return index;
    }

    fn close(reader: *Reader, index: u32, length: u32) void {
        if (reader.nodes) |nodes| {
            nodes[index].length = length;
            nodes[index].next = reader.used;
        }
    }

    fn value(reader: *Reader, depth: u32) ?void {
        if (depth > max_depth) return null;
        const c = reader.peek() orelse return null;
        switch (c) {
            '{' => {
                reader.at += 1;
                const index = reader.add(.{ .kind = .object });
                var pairs: u32 = 0;
                if (reader.peek() == '}') {
                    reader.at += 1;
                } else while (true) {
                    if (reader.peek() != '"') return null;
                    reader.str() orelse return null;
                    if (reader.peek() != ':') return null;
                    reader.at += 1;
                    reader.value(depth + 1) orelse return null;
                    pairs += 1;
                    const after = reader.peek() orelse return null;
                    reader.at += 1;
                    if (after == '}') break;
                    if (after != ',') return null;
                }
                reader.close(index, pairs);
            },
            '[' => {
                reader.at += 1;
                const index = reader.add(.{ .kind = .array });
                var length: u32 = 0;
                if (reader.peek() == ']') {
                    reader.at += 1;
                } else while (true) {
                    reader.value(depth + 1) orelse return null;
                    length += 1;
                    const after = reader.peek() orelse return null;
                    reader.at += 1;
                    if (after == ']') break;
                    if (after != ',') return null;
                }
                reader.close(index, length);
            },
            '"' => reader.str() orelse return null,
            't' => {
                reader.word("true") orelse return null;
                reader.close(reader.add(.{ .kind = .true_value }), 0);
            },
            'f' => {
                reader.word("false") orelse return null;
                reader.close(reader.add(.{ .kind = .false_value }), 0);
            },
            'n' => {
                reader.word("null") orelse return null;
                reader.close(reader.add(.{ .kind = .null_value }), 0);
            },
            else => reader.num() orelse return null,
        }
    }

    fn word(reader: *Reader, expected: []const u8) ?void {
        if (reader.text.len - reader.at < expected.len) return null;
        if (!equal(reader.text[reader.at..][0..expected.len], expected)) return null;
        reader.at += expected.len;
    }

    fn str(reader: *Reader) ?void {
        reader.at += 1;
        const start = reader.at;
        while (reader.at < reader.text.len) : (reader.at += 1) {
            switch (reader.text[reader.at]) {
                '\\' => reader.at += 1,
                '"' => {
                    const index = reader.add(.{ .kind = .string, .at = @intCast(start) });
                    reader.close(index, @intCast(reader.at - start));
                    reader.at += 1;
                    return;
                },
                else => {},
            }
        }
        return null;
    }

    fn digit(reader: *Reader) ?u8 {
        if (reader.at >= reader.text.len) return null;
        const c = reader.text[reader.at];
        return if (c >= '0' and c <= '9') c - '0' else null;
    }

    fn num(reader: *Reader) ?void {
        var negative = false;
        if (reader.at < reader.text.len and reader.text[reader.at] == '-') {
            negative = true;
            reader.at += 1;
        }
        var mantissa: u64 = 0;
        var scale: i32 = 0;
        var digits: u32 = 0;
        while (reader.digit()) |d| : (reader.at += 1) {
            digits += 1;
            if (mantissa < 1_000_000_000_000_000) mantissa = mantissa * 10 + d else scale += 1;
        }
        if (digits == 0) return null;
        if (reader.at < reader.text.len and reader.text[reader.at] == '.') {
            reader.at += 1;
            var fraction: u32 = 0;
            while (reader.digit()) |d| : (reader.at += 1) {
                fraction += 1;
                if (mantissa < 1_000_000_000_000_000) {
                    mantissa = mantissa * 10 + d;
                    scale -= 1;
                }
            }
            if (fraction == 0) return null;
        }
        if (reader.at < reader.text.len and (reader.text[reader.at] == 'e' or reader.text[reader.at] == 'E')) {
            reader.at += 1;
            var exponent_negative = false;
            if (reader.at < reader.text.len and (reader.text[reader.at] == '+' or reader.text[reader.at] == '-')) {
                exponent_negative = reader.text[reader.at] == '-';
                reader.at += 1;
            }
            var exponent: i32 = 0;
            var exponent_digits: u32 = 0;
            while (reader.digit()) |d| : (reader.at += 1) {
                exponent_digits += 1;
                if (exponent < 1000) exponent = exponent * 10 + d;
            }
            if (exponent_digits == 0) return null;
            scale += if (exponent_negative) -exponent else exponent;
        }
        var result: f32 = @floatFromInt(mantissa);
        while (scale > 0) : (scale -= 1) result *= 10;
        while (scale < 0) : (scale += 1) {
            result /= 10;
            if (result == 0) break;
        }
        reader.close(reader.add(.{ .kind = .number, .number = if (negative) -result else result }), 0);
    }
};

const testing = @import("std").testing;

fn tapeOf(text: []const u8, nodes: []Node) !Tape {
    const counted = parse(text, null) orelse return error.NotJson;
    try testing.expect(counted <= nodes.len);
    try testing.expectEqual(counted, parse(text, nodes[0..counted]).?);
    return .{ .text = text, .nodes = nodes[0..counted] };
}

test "objects, arrays and numbers" {
    var nodes: [64]Node = undefined;
    const tape = try tapeOf(
        \\ { "w": 512, "h": 2.5e2, "nm": "a \"b\"", "layers": [ {"ty": 4}, [1, -0.25, 3E-1], true, null ], "e": {} }
    , &nodes);
    try testing.expectEqual(@as(f32, 512), tape.number(tape.get(0, "w")).?);
    try testing.expectEqual(@as(f32, 250), tape.number(tape.get(0, "h")).?);
    try testing.expectEqualStrings("a \\\"b\\\"", tape.string(tape.get(0, "nm")).?);
    const layers = tape.get(0, "layers");
    try testing.expectEqual(@as(u32, 4), tape.count(layers));
    try testing.expectEqual(@as(f32, 4), tape.number(tape.get(tape.item(layers, 0), "ty")).?);
    const numbers = tape.item(layers, 1);
    try testing.expectApproxEqAbs(@as(f32, -0.25), tape.number(tape.item(numbers, 1)).?, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.3), tape.number(tape.item(numbers, 2)).?, 1e-6);
    try testing.expect(tape.flag(tape.item(layers, 2)));
    try testing.expectEqual(Kind.null_value, tape.kind(tape.item(layers, 3).?));
    try testing.expectEqual(@as(u32, 0), tape.count(tape.get(0, "e")));
    try testing.expectEqual(@as(?u32, null), tape.get(0, "missing"));
    var walk = tape.items(layers);
    var seen: u32 = 0;
    while (walk.next()) |_| seen += 1;
    try testing.expectEqual(@as(u32, 4), seen);
}

test "what is not JSON" {
    try testing.expectEqual(@as(?u32, null), parse("{\"a\":}", null));
    try testing.expectEqual(@as(?u32, null), parse("[1,2", null));
    try testing.expectEqual(@as(?u32, null), parse("{\"a\":1} x", null));
    try testing.expectEqual(@as(?u32, null), parse("-", null));
    try testing.expectEqual(@as(?u32, null), parse("1.", null));
}
