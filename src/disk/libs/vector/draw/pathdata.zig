// SPDX-License-Identifier: MIT
//! SVG path data onto a path: `M 10 10 h 20 a 5 5 0 0 1 5 5 z` and the
//! rest of SVG's grammar - every command in both its forms, absolute and
//! relative to the current point; a command's numbers given again for
//! another of it, a move's taken as lines; numbers run together where a
//! sign or a second point parts them (`10-5.5.5`), and the arc's flags as
//! single digits. Since 1.1.
//!
//! **An error stops it there**: the commands before it are kept and the
//! one it is in is not, as SVG draws path data that goes wrong. The data
//! is a path of its own: it starts with a move, and a first relative move
//! is taken from (0, 0).

const sdk = @import("sdk");
const vector = sdk.vector;
const P = vector.Point;
const Path = @import("path.zig").Path;
const shapes = @import("shapes.zig");

/// The data added; `VECTOR_OK`, `VECTORERR_SYNTAX` at the first error,
/// or `VECTORERR_NOMEM` when a segment did not fit.
pub fn add(path: *Path, text: []const u8) i32 {
    const failed_before = path.failed;
    var parser = Parser{ .text = text };
    const result = parser.run(path);
    if (result == vector.VECTOR_OK and path.failed and !failed_before) return vector.VECTORERR_NOMEM;
    return result;
}

const Parser = struct {
    text: []const u8,
    at: usize = 0,
    /// The current point, and where the contour it is on began.
    current: P = .{},
    start: P = .{},
    /// The last curve's second control point, for an `S` or `T` after one
    /// of its kind to mirror; null after anything else.
    cubic_control: ?P = null,
    quad_control: ?P = null,
    /// A move has come.
    begun: bool = false,

    fn run(parser: *Parser, path: *Path) i32 {
        var command: u8 = 0;
        parser.space();
        while (parser.at < parser.text.len) {
            const c = parser.text[parser.at];
            if (isCommand(c)) {
                command = c;
                parser.at += 1;
            } else if (command == 0 or command == 'Z' or command == 'z') {
                // Numbers before any command, or after a close.
                return vector.VECTORERR_SYNTAX;
            } else if (command == 'M') {
                command = 'L';
            } else if (command == 'm') {
                command = 'l';
            }
            if (!parser.one(path, command)) return vector.VECTORERR_SYNTAX;
            parser.space();
        }
        return vector.VECTOR_OK;
    }

    /// One command with its numbers, added only once they are all read.
    fn one(parser: *Parser, path: *Path, command: u8) bool {
        const relative = command >= 'a';
        const base = if (relative) parser.current else P{};
        const upper = command & ~@as(u8, 0x20);
        // The data must start with a move.
        if (!parser.begun and upper != 'M') return false;
        switch (upper) {
            'M' => {
                const p = parser.point(base) orelse return false;
                path.moveTo(p);
                parser.current = p;
                parser.start = p;
                parser.begun = true;
                parser.forget();
            },
            'L' => {
                const p = parser.point(base) orelse return false;
                path.lineTo(p);
                parser.current = p;
                parser.forget();
            },
            'H' => {
                const x = parser.number() orelse return false;
                const p = P{ .x = x + base.x, .y = parser.current.y };
                path.lineTo(p);
                parser.current = p;
                parser.forget();
            },
            'V' => {
                const y = parser.number() orelse return false;
                const p = P{ .x = parser.current.x, .y = y + base.y };
                path.lineTo(p);
                parser.current = p;
                parser.forget();
            },
            'C' => {
                const c1 = parser.point(base) orelse return false;
                const c2 = parser.point(base) orelse return false;
                const p = parser.point(base) orelse return false;
                path.cubicTo(c1, c2, p);
                parser.current = p;
                parser.forget();
                parser.cubic_control = c2;
            },
            'S' => {
                const c2 = parser.point(base) orelse return false;
                const p = parser.point(base) orelse return false;
                const c1 = mirrored(parser.cubic_control, parser.current);
                path.cubicTo(c1, c2, p);
                parser.current = p;
                parser.forget();
                parser.cubic_control = c2;
            },
            'Q' => {
                const q = parser.point(base) orelse return false;
                const p = parser.point(base) orelse return false;
                path.quadTo(q, p);
                parser.current = p;
                parser.forget();
                parser.quad_control = q;
            },
            'T' => {
                const p = parser.point(base) orelse return false;
                const q = mirrored(parser.quad_control, parser.current);
                path.quadTo(q, p);
                parser.current = p;
                parser.forget();
                parser.quad_control = q;
            },
            'A' => {
                const rx = parser.number() orelse return false;
                const ry = parser.number() orelse return false;
                const angle = parser.number() orelse return false;
                const large = parser.flag() orelse return false;
                const sweep = parser.flag() orelse return false;
                const p = parser.point(base) orelse return false;
                shapes.arcTo(path, rx, ry, angle, large, sweep, p);
                parser.current = p;
                parser.forget();
            },
            'Z' => {
                path.close();
                parser.current = parser.start;
                parser.forget();
            },
            else => return false,
        }
        return true;
    }

    fn forget(parser: *Parser) void {
        parser.cubic_control = null;
        parser.quad_control = null;
    }

    fn point(parser: *Parser, base: P) ?P {
        const x = parser.number() orelse return null;
        const y = parser.number() orelse return null;
        return .{ .x = x + base.x, .y = y + base.y };
    }

    /// Spaces, and a comma between them.
    fn separator(parser: *Parser) void {
        parser.space();
        if (parser.at < parser.text.len and parser.text[parser.at] == ',') {
            parser.at += 1;
            parser.space();
        }
    }

    fn space(parser: *Parser) void {
        while (parser.at < parser.text.len) : (parser.at += 1) {
            switch (parser.text[parser.at]) {
                ' ', '\t', '\n', '\r', 0x0C => {},
                else => return,
            }
        }
    }

    /// An arc's flag: one digit, 0 or 1, needing nothing after it.
    fn flag(parser: *Parser) ?bool {
        parser.separator();
        if (parser.at >= parser.text.len) return null;
        const c = parser.text[parser.at];
        if (c != '0' and c != '1') return null;
        parser.at += 1;
        return c == '1';
    }

    /// A number: a sign, digits with a point among them or before them,
    /// and an exponent.
    fn number(parser: *Parser) ?f32 {
        parser.separator();
        const text = parser.text;
        var i = parser.at;
        var negative = false;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) {
            negative = text[i] == '-';
            i += 1;
        }
        var mantissa: u64 = 0;
        var exponent: i32 = 0;
        var digits: u32 = 0;
        while (i < text.len and isDigit(text[i])) : (i += 1) {
            digits += 1;
            if (mantissa < 1_000_000_000_000_000) {
                mantissa = mantissa * 10 + (text[i] - '0');
            } else exponent += 1;
        }
        if (i < text.len and text[i] == '.') {
            i += 1;
            while (i < text.len and isDigit(text[i])) : (i += 1) {
                digits += 1;
                if (mantissa < 1_000_000_000_000_000) {
                    mantissa = mantissa * 10 + (text[i] - '0');
                    exponent -= 1;
                }
            }
        }
        if (digits == 0) return null;
        // An exponent, unless the `e` is the start of something else.
        if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
            var j = i + 1;
            var exp_negative = false;
            if (j < text.len and (text[j] == '+' or text[j] == '-')) {
                exp_negative = text[j] == '-';
                j += 1;
            }
            if (j < text.len and isDigit(text[j])) {
                var e: i32 = 0;
                while (j < text.len and isDigit(text[j])) : (j += 1) {
                    if (e < 1000) e = e * 10 + (text[j] - '0');
                }
                exponent += if (exp_negative) -e else e;
                i = j;
            }
        }
        parser.at = i;
        var value: f64 = @floatFromInt(mantissa);
        var e = exponent;
        while (e > 0) : (e -= 1) value *= 10;
        while (e < 0) : (e += 1) value /= 10;
        if (value > 3.0e38) value = 3.0e38;
        const result: f32 = @floatCast(value);
        return if (negative) -result else result;
    }
};

fn mirrored(control: ?P, about: P) P {
    const c = control orelse return about;
    return .{ .x = 2 * about.x - c.x, .y = 2 * about.y - c.y };
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isCommand(c: u8) bool {
    return switch (c) {
        'M', 'm', 'L', 'l', 'H', 'h', 'V', 'v', 'C', 'c', 'S', 's', 'Q', 'q', 'T', 't', 'A', 'a', 'Z', 'z' => true,
        else => false,
    };
}

// --- tests ---------------------------------------------------------------------

const testing = @import("std").testing;
const test_memory = @import("memory.zig").test_memory;
const path_ = @import("path.zig");
const Verb = path_.Verb;
const bounds = @import("bounds.zig").bounds;

fn expectVerbs(path: *const Path, want: []const Verb) !void {
    var walk = path.walk();
    for (want) |verb| try testing.expectEqual(verb, walk.next().?.verb);
    try testing.expect(walk.next() == null);
}

test "every command, absolute and relative, a move's numbers again as lines" {
    const path = Path.create(test_memory).?;
    defer path.destroy();
    try testing.expectEqual(vector.VECTOR_OK, add(path, "M10 10 20 10 h10 v10 H10 V 15 z m 5,5 l 1 1 c 1 0 2 1 2 2 s 1 2 2 2 q 1 0 1 1 t 1 1 Q 0 0 1 1 T 2 2 a 1 1 0 0 1 2 0 Z"));
    // The arc is a half circle: two curves.
    const want = [_]Verb{ .move, .line, .line, .line, .line, .line, .close, .move, .line, .cubic, .cubic, .quad, .quad, .quad, .quad, .cubic, .cubic, .close };
    try expectVerbs(path, &want);
    // After the first close the relative move is from where it began.
    var walk = path.walk();
    var seen: u32 = 0;
    while (walk.next()) |segment| : (seen += 1) {
        if (seen == 7) try testing.expectEqual(P{ .x = 15, .y = 15 }, segment.points[0]);
        if (seen == 2) try testing.expectEqual(P{ .x = 30, .y = 10 }, segment.points[0]);
    }
}

test "numbers run together, exponents, and an arc's flags without spaces" {
    const path = Path.create(test_memory).?;
    defer path.destroy();
    try testing.expectEqual(vector.VECTOR_OK, add(path, "M0,0L10-5.5.5,0l1e1-2E-1"));
    var walk = path.walk();
    _ = walk.next();
    try testing.expectEqual(P{ .x = 10, .y = -5.5 }, walk.next().?.points[0]);
    try testing.expectEqual(P{ .x = 0.5, .y = 0 }, walk.next().?.points[0]);
    // An `l` taking 10 and -0.2: neither a point nor its exponent is a
    // command.
    const last = walk.next().?.points[0];
    try testing.expectApproxEqAbs(@as(f32, 10.5), last.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -0.2), last.y, 1e-5);
    path.clear();
    try testing.expectEqual(vector.VECTOR_OK, add(path, "M0 0a10 10 0 1110 0"));
    try testing.expect(bounds(path, .{}).?.height > 18);
}

test "an error keeps what came before it, and data must start with a move" {
    const path = Path.create(test_memory).?;
    defer path.destroy();
    try testing.expectEqual(vector.VECTORERR_SYNTAX, add(path, "M 10 10 L 20 20 L 30"));
    try expectVerbs(path, &.{ .move, .line });
    path.clear();
    try testing.expectEqual(vector.VECTORERR_SYNTAX, add(path, "L 10 10"));
    try testing.expectEqual(@as(usize, 0), path.verbs.len);
    path.clear();
    try testing.expectEqual(vector.VECTORERR_SYNTAX, add(path, "M 1 1 z 5 5"));
    try expectVerbs(path, &.{ .move, .close });
    path.clear();
    try testing.expectEqual(vector.VECTORERR_SYNTAX, add(path, "M 1 1 A 5 5 0 2 0 9 9"));
    try testing.expectEqual(vector.VECTORERR_SYNTAX, add(path, "M 1 1 X"));
    try testing.expectEqual(vector.VECTOR_OK, add(path, "  "));
}

test "a smooth curve mirrors the last one's control point, and only after one of its kind" {
    const path = Path.create(test_memory).?;
    defer path.destroy();
    try testing.expectEqual(vector.VECTOR_OK, add(path, "M0 0 C 0 10 10 10 10 0 S 20 -10 20 0 L 30 0 S 40 10 40 0"));
    var walk = path.walk();
    _ = walk.next();
    _ = walk.next();
    try testing.expectEqual(P{ .x = 10, .y = -10 }, walk.next().?.points[0]);
    _ = walk.next();
    // After a line: the first control point is the current point.
    try testing.expectEqual(P{ .x = 30, .y = 0 }, walk.next().?.points[0]);
}
