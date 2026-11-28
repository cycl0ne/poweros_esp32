// SPDX-License-Identifier: MPL-2.0
//! Every opcode of the bytecode and the shape of what follows it: the
//! operands each term takes, in order (`shapeOf`), and a term stepped
//! over whole by that shape (`skip`).
//!
//! **Shapes.** An operand is a number of one to eight bytes, a string to
//! its NUL, a name string, another term (a TermArg), or where a result
//! goes (a SuperName, or nothing at all - a 0). A term that holds others
//! starts with its package length, and what it holds - a list of terms,
//! of bytes, of a package's elements, of a field's - runs to the
//! package's end.
//!
//! **A name in a term's place** is either a reference to an object or a
//! call of a method with its arguments behind it, and which one only the
//! namespace says: a name that is a method there takes as many terms as
//! the method has arguments; any other name, or one that is not there
//! yet, takes none - the rule every interpreter applies to bytecode read
//! before the methods it calls are defined.

const AcpiBase = @import("../acpi_base.zig").AcpiBase;
const namespace = @import("../namespace/_namespace.zig");
const Node = namespace.Node;
const aml = @import("_aml.zig");
const Reader = aml.Reader;
const EXT = aml.EXT;

/// An operand's shape.
pub const Arg = enum(u8) {
    byte,
    word,
    dword,
    qword,
    /// Characters to a NUL.
    string,
    /// A name string.
    name,
    /// A term: a TermArg.
    term,
    /// Where a result goes: a SuperName, or a 0 for nowhere.
    target,
    /// A package length; the term ends at its end.
    pkg,
    /// The rest of the package: terms, bytes, a package's elements, a
    /// field's elements.
    terms,
    bytes,
    elements,
    fields,
};

/// The shape of what follows an opcode, and whether the term defines a
/// name as it is loaded (`named`) - its name the first `name` operand,
/// but for the CreateField family, whose name is its last.
pub const Shape = struct {
    args: []const Arg,
    named: bool = false,
};

/// The opcodes, by their code: one byte, or `EXT | byte` behind 0x5B.
pub const ALIAS_OP: u16 = 0x06;
pub const NAME_OP: u16 = 0x08;
pub const SCOPE_OP: u16 = 0x10;
pub const BUFFER_OP: u16 = 0x11;
pub const PACKAGE_OP: u16 = 0x12;
pub const VAR_PACKAGE_OP: u16 = 0x13;
pub const METHOD_OP: u16 = 0x14;
pub const EXTERNAL_OP: u16 = 0x15;
pub const CREATE_DWORD_FIELD_OP: u16 = 0x8A;
pub const CREATE_WORD_FIELD_OP: u16 = 0x8B;
pub const CREATE_BYTE_FIELD_OP: u16 = 0x8C;
pub const CREATE_BIT_FIELD_OP: u16 = 0x8D;
pub const CREATE_QWORD_FIELD_OP: u16 = 0x8F;
pub const IF_OP: u16 = 0xA0;
pub const ELSE_OP: u16 = 0xA1;
pub const WHILE_OP: u16 = 0xA2;
pub const MUTEX_OP: u16 = EXT | 0x01;
pub const EVENT_OP: u16 = EXT | 0x02;
pub const CREATE_FIELD_OP: u16 = EXT | 0x13;
pub const DEBUG_OP: u16 = EXT | 0x31;
pub const OP_REGION_OP: u16 = EXT | 0x80;
pub const FIELD_OP: u16 = EXT | 0x81;
pub const DEVICE_OP: u16 = EXT | 0x82;
pub const PROCESSOR_OP: u16 = EXT | 0x83;
pub const POWER_RES_OP: u16 = EXT | 0x84;
pub const THERMAL_ZONE_OP: u16 = EXT | 0x85;
pub const INDEX_FIELD_OP: u16 = EXT | 0x86;
pub const BANK_FIELD_OP: u16 = EXT | 0x87;
pub const DATA_REGION_OP: u16 = EXT | 0x88;

/// The first and the last of the eight locals and the seven arguments.
pub const LOCAL0_OP: u16 = 0x60;
pub const ARG0_OP: u16 = 0x68;
pub const ARG6_OP: u16 = 0x6E;

const none = &[_]Arg{};
const one_term = &[_]Arg{.term};
const two_terms = &[_]Arg{ .term, .term };
const one_target = &[_]Arg{.target};
const term_target = &[_]Arg{ .term, .target };
const two_terms_target = &[_]Arg{ .term, .term, .target };

/// The shape of what follows `code`; null for a code that is no opcode.
pub fn shapeOf(code: u16) ?Shape {
    return switch (code) {
        0x00, 0x01, 0xFF => .{ .args = none }, // Zero, One, Ones
        ALIAS_OP => .{ .args = &.{ .name, .name }, .named = true },
        NAME_OP => .{ .args = &.{ .name, .term }, .named = true },
        0x0A => .{ .args = &.{.byte} },
        0x0B => .{ .args = &.{.word} },
        0x0C => .{ .args = &.{.dword} },
        0x0D => .{ .args = &.{.string} },
        0x0E => .{ .args = &.{.qword} },
        SCOPE_OP => .{ .args = &.{ .pkg, .name, .terms } },
        BUFFER_OP => .{ .args = &.{ .pkg, .term, .bytes } },
        PACKAGE_OP => .{ .args = &.{ .pkg, .byte, .elements } },
        VAR_PACKAGE_OP => .{ .args = &.{ .pkg, .term, .elements } },
        METHOD_OP => .{ .args = &.{ .pkg, .name, .byte, .terms }, .named = true },
        EXTERNAL_OP => .{ .args = &.{ .name, .byte, .byte } },
        LOCAL0_OP...ARG6_OP => .{ .args = none },
        0x70 => .{ .args = term_target }, // Store
        0x71 => .{ .args = one_target }, // RefOf
        0x72, 0x73, 0x74 => .{ .args = two_terms_target }, // Add, Concatenate, Subtract
        0x75, 0x76 => .{ .args = one_target }, // Increment, Decrement
        0x77 => .{ .args = two_terms_target }, // Multiply
        0x78 => .{ .args = &.{ .term, .term, .target, .target } }, // Divide
        0x79...0x7F => .{ .args = two_terms_target }, // ShiftLeft to Xor
        0x80, 0x81, 0x82 => .{ .args = term_target }, // Not, FindSetLeftBit, FindSetRightBit
        0x83 => .{ .args = one_term }, // DerefOf
        0x84, 0x85 => .{ .args = two_terms_target }, // ConcatenateResTemplate, Mod
        0x86 => .{ .args = &.{ .target, .term } }, // Notify
        0x87 => .{ .args = one_target }, // SizeOf
        0x88 => .{ .args = two_terms_target }, // Index
        0x89 => .{ .args = &.{ .term, .byte, .term, .byte, .term, .term } }, // Match
        CREATE_DWORD_FIELD_OP,
        CREATE_WORD_FIELD_OP,
        CREATE_BYTE_FIELD_OP,
        CREATE_BIT_FIELD_OP,
        CREATE_QWORD_FIELD_OP,
        => .{ .args = &.{ .term, .term, .name }, .named = true },
        0x8E => .{ .args = one_target }, // ObjectType
        0x90, 0x91 => .{ .args = two_terms }, // LAnd, LOr
        0x92 => .{ .args = one_term }, // LNot
        0x93, 0x94, 0x95 => .{ .args = two_terms }, // LEqual, LGreater, LLess
        0x96, 0x97, 0x98, 0x99 => .{ .args = term_target }, // ToBuffer, ToDecimalString, ToHexString, ToInteger
        0x9C => .{ .args = two_terms_target }, // ToString
        0x9D => .{ .args = term_target }, // CopyObject
        0x9E => .{ .args = &.{ .term, .term, .term, .target } }, // Mid
        0x9F, 0xA3, 0xA5, 0xCC => .{ .args = none }, // Continue, Noop, Break, BreakPoint
        IF_OP, WHILE_OP => .{ .args = &.{ .pkg, .term, .terms } },
        ELSE_OP => .{ .args = &.{ .pkg, .terms } },
        0xA4 => .{ .args = one_term }, // Return
        MUTEX_OP => .{ .args = &.{ .name, .byte }, .named = true },
        EVENT_OP => .{ .args = &.{.name}, .named = true },
        EXT | 0x12 => .{ .args = &.{ .target, .target } }, // CondRefOf
        CREATE_FIELD_OP => .{ .args = &.{ .term, .term, .term, .name }, .named = true },
        EXT | 0x1F => .{ .args = &.{ .term, .term, .term, .term, .term, .term } }, // LoadTable
        EXT | 0x20 => .{ .args = &.{ .name, .target } }, // Load
        EXT | 0x21, EXT | 0x22 => .{ .args = one_term }, // Stall, Sleep
        EXT | 0x23 => .{ .args = &.{ .target, .word } }, // Acquire
        EXT | 0x24, EXT | 0x26, EXT | 0x27 => .{ .args = one_target }, // Signal, Reset, Release
        EXT | 0x25 => .{ .args = &.{ .target, .term } }, // Wait
        EXT | 0x28, EXT | 0x29 => .{ .args = term_target }, // FromBCD, ToBCD
        EXT | 0x2A => .{ .args = one_target }, // Unload
        EXT | 0x30, DEBUG_OP, EXT | 0x33 => .{ .args = none }, // Revision, Debug, Timer
        EXT | 0x32 => .{ .args = &.{ .byte, .dword, .term } }, // Fatal
        OP_REGION_OP => .{ .args = &.{ .name, .byte, .term, .term }, .named = true },
        FIELD_OP => .{ .args = &.{ .pkg, .name, .byte, .fields }, .named = true },
        DEVICE_OP, THERMAL_ZONE_OP => .{ .args = &.{ .pkg, .name, .terms }, .named = true },
        PROCESSOR_OP => .{ .args = &.{ .pkg, .name, .byte, .dword, .byte, .terms }, .named = true },
        POWER_RES_OP => .{ .args = &.{ .pkg, .name, .byte, .word, .terms }, .named = true },
        INDEX_FIELD_OP => .{ .args = &.{ .pkg, .name, .name, .byte, .fields }, .named = true },
        BANK_FIELD_OP => .{ .args = &.{ .pkg, .name, .name, .term, .byte, .fields }, .named = true },
        DATA_REGION_OP => .{ .args = &.{ .name, .term, .term, .term }, .named = true },
        else => null,
    };
}

/// Why a term could not be stepped over: an opcode the interpreter does
/// not know, or a term that ends past its package or its table, or nests
/// deeper than MOST_NESTING. Where, and the opcode met there; `none`
/// while nothing has gone wrong.
pub const Fault = struct {
    why: Why = .none,
    at: usize = 0,
    code: u16 = 0,

    pub const Why = enum { none, unknown, broken };
};

/// The deepest terms are stepped over inside one another.
pub const MOST_NESTING = 64;

/// The term at `reader` stepped over whole, read in `scope` - which says
/// whether a name in a term's place calls a method. False, with `fault`
/// filled in and the reader left at the fault, where it cannot be.
pub fn skip(ab: *const AcpiBase, reader: *Reader, scope: *Node, fault: *Fault) bool {
    return skipTerm(ab, reader, scope, fault, 0);
}

fn skipTerm(ab: *const AcpiBase, reader: *Reader, scope: *Node, fault: *Fault, depth: u32) bool {
    const start = reader.at;
    if (depth == MOST_NESTING) return failed(fault, .broken, start, 0);
    if (reader.atName()) {
        const path = reader.name() orelse return failed(fault, .broken, start, 0);
        const called = namespace.find(ab, scope, path, .search) orelse return true;
        const held = called.object orelse return true;
        const args = switch (held.value) {
            .method => |method| method.args(),
            else => return true,
        };
        var index: u8 = 0;
        while (index < args) : (index += 1) {
            if (!skipTerm(ab, reader, scope, fault, depth + 1)) return false;
        }
        return true;
    }
    const code = reader.opcode() orelse return failed(fault, .broken, start, 0);
    const shape = shapeOf(code) orelse {
        reader.at = start;
        return failed(fault, .unknown, start, code);
    };
    // What a package holds is read within it: its end is the reader's
    // while its operands are read, and the one before afterwards.
    const outer_end = reader.end;
    defer reader.end = outer_end;
    var end: ?usize = null;
    for (shape.args) |arg| {
        switch (arg) {
            .byte => _ = reader.number(1) orelse return failed(fault, .broken, start, code),
            .word => _ = reader.number(2) orelse return failed(fault, .broken, start, code),
            .dword => _ = reader.number(4) orelse return failed(fault, .broken, start, code),
            .qword => _ = reader.number(8) orelse return failed(fault, .broken, start, code),
            .string => _ = reader.string() orelse return failed(fault, .broken, start, code),
            .name => _ = reader.name() orelse return failed(fault, .broken, start, code),
            .term => if (!skipTerm(ab, reader, scope, fault, depth + 1)) return false,
            .target => if (!skipTarget(ab, reader, scope, fault, depth + 1)) return false,
            .pkg => {
                const package_end = reader.pkgEnd() orelse return failed(fault, .broken, start, code);
                end = package_end;
                reader.end = package_end;
            },
            .terms, .bytes, .elements, .fields => reader.at = end orelse return failed(fault, .broken, start, code),
        }
    }
    if (end) |package_end| reader.at = package_end;
    return true;
}

/// A target stepped over: a name there is where a result goes, or the
/// object an operator asks about, and never a method called; anything
/// else is a term.
fn skipTarget(ab: *const AcpiBase, reader: *Reader, scope: *Node, fault: *Fault, depth: u32) bool {
    if (!reader.atName()) return skipTerm(ab, reader, scope, fault, depth);
    const start = reader.at;
    _ = reader.name() orelse return failed(fault, .broken, start, 0);
    return true;
}

fn failed(fault: *Fault, why: Fault.Why, at: usize, code: u16) bool {
    fault.* = .{ .why = why, .at = at, .code = code };
    return false;
}
