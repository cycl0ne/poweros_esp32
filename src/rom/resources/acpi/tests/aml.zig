// SPDX-License-Identifier: MPL-2.0
//! Bytecode put together at compile time, for the host tests of the
//! interpreter: `code` joins its parts in the order the bytecode has
//! them - an operator before its operands - each a byte (an opcode by
//! its name here, a local, an argument) or a run of bytes (a name, a
//! constant, a string, a term with a package, as the functions below
//! write them). A method's body reads as its source does:
//!
//! ```
//! code(.{ RETURN, ADD, byte(3), LOCAL0, ZERO })   // Return (Add (3, Local0))
//! ```

/// The parts joined.
pub fn code(comptime parts: anytype) []const u8 {
    return comptime joined(parts);
}

fn joined(comptime parts: anytype) []const u8 {
    @setEvalBranchQuota(1_000_000);
    var bytes: []const u8 = &.{};
    inline for (parts) |part| bytes = bytes ++ bytesOf(part);
    const done = bytes[0..bytes.len].*;
    return &done;
}

fn bytesOf(comptime part: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(part))) {
        .comptime_int, .int => &[_]u8{part},
        .array => &part,
        else => part,
    };
}

/// A constant, the way its prefix says.
pub fn byte(comptime value: u8) []const u8 {
    return &[_]u8{ 0x0A, value };
}

pub fn word(comptime value: u16) []const u8 {
    return &[_]u8{ 0x0B, @truncate(value), @truncate(value >> 8) };
}

pub fn dword(comptime value: u32) []const u8 {
    return &[_]u8{ 0x0C, @truncate(value), @truncate(value >> 8), @truncate(value >> 16), @truncate(value >> 24) };
}

pub fn qword(comptime value: u64) []const u8 {
    return comptime qwordBytes(value);
}

fn qwordBytes(comptime value: u64) []const u8 {
    var bytes: [9]u8 = undefined;
    bytes[0] = 0x0E;
    for (0..8) |index| bytes[1 + index] = @truncate(value >> (index * 8));
    const done = bytes;
    return &done;
}

/// A table: its header - `signature`, `revision`, the maker "POWER ",
/// the table's name "TESTTABL" - and `terms` after it, its checksum
/// holding.
pub fn table(comptime signature: *const [4]u8, comptime revision: u8, comptime terms: []const u8) []const u8 {
    return comptime tableBytes(signature, revision, terms);
}

fn tableBytes(comptime signature: *const [4]u8, comptime revision: u8, comptime terms: []const u8) []const u8 {
    @setEvalBranchQuota(1_000_000);
    const length = 36 + terms.len;
    var bytes: [length]u8 = @splat(0);
    for (signature, 0..) |char, index| bytes[index] = char;
    for (0..4) |index| bytes[4 + index] = @truncate(length >> (index * 8));
    bytes[8] = revision;
    for ("POWER ", 0..) |char, index| bytes[10 + index] = char;
    for ("TESTTABL", 0..) |char, index| bytes[16 + index] = char;
    bytes[24] = 1;
    for ("TEST", 0..) |char, index| bytes[28 + index] = char;
    for (terms, 0..) |char, index| bytes[36 + index] = char;
    var sum: u8 = 0;
    for (bytes) |char| sum +%= char;
    bytes[9] = 0 -% sum;
    const done = bytes;
    return &done;
}

/// A string constant: its characters and the NUL.
pub fn text(comptime chars: []const u8) []const u8 {
    return "\x0D" ++ chars ++ "\x00";
}

/// A name string from a path as the source writes it: "\\_SB.PCI0",
/// "^FOO", "INT0", each name filled out with `_`.
pub fn name(comptime path: []const u8) []const u8 {
    return comptime nameBytes(path);
}

fn nameBytes(comptime path: []const u8) []const u8 {
    {
        var bytes: []const u8 = &.{};
        var rest = path;
        while (rest.len > 0 and (rest[0] == '\\' or rest[0] == '^')) {
            bytes = bytes ++ rest[0..1];
            rest = rest[1..];
        }
        if (rest.len == 0) return bytes ++ "\x00";
        var segments: []const []const u8 = &.{};
        var start = 0;
        for (rest, 0..) |char, index| {
            if (char != '.') continue;
            segments = segments ++ [_][]const u8{rest[start..index]};
            start = index + 1;
        }
        segments = segments ++ [_][]const u8{rest[start..]};
        if (segments.len == 2) bytes = bytes ++ "\x2E";
        if (segments.len > 2) bytes = bytes ++ [_]u8{ 0x2F, segments.len };
        for (segments) |segment| {
            var filled: [4]u8 = "____".*;
            for (segment, 0..) |char, index| filled[index] = char;
            bytes = bytes ++ filled;
        }
        const done = bytes[0..bytes.len].*;
        return &done;
    }
}

/// `opcode` - a byte or an extended opcode's two - its package length,
/// and `body`: an If, a While, a Method, a Buffer, a Package.
pub fn pkg(comptime opcode: anytype, comptime body: []const u8) []const u8 {
    return comptime bytesOf(opcode) ++ lengthOf(body.len) ++ body;
}

/// A package length for `content` bytes: it counts itself.
fn lengthOf(comptime content: usize) []const u8 {
    return comptime lengthBytes(content);
}

fn lengthBytes(comptime content: usize) []const u8 {
    if (content + 1 <= 0x3F) return &[_]u8{content + 1};
    for (1..4) |follow| {
        const total = content + 1 + follow;
        if (total < 1 << (4 + 8 * follow)) {
            var bytes: []const u8 = &[_]u8{@as(u8, follow << 6 | (total & 0x0F))};
            for (0..follow) |index| bytes = bytes ++ [_]u8{@truncate(total >> (4 + 8 * index))};
            const done = bytes[0..bytes.len].*;
            return &done;
        }
    }
    @compileError("a package too long");
}

/// `Method (path, args, flags) { body }`, `flags` the byte after the
/// name - the argument count in its low three bits, 0x08 serialized,
/// the sync level above.
pub fn method(comptime path: []const u8, comptime flags: u8, comptime body: []const u8) []const u8 {
    return pkg(METHOD, name(path) ++ [_]u8{flags} ++ body);
}

/// `If (predicate) { body }`.
pub fn ifThen(comptime predicate: []const u8, comptime body: []const u8) []const u8 {
    return pkg(IF, predicate ++ body);
}

/// `Else { body }`.
pub fn orElse(comptime body: []const u8) []const u8 {
    return pkg(ELSE, body);
}

/// `While (predicate) { body }`.
pub fn whileDo(comptime predicate: []const u8, comptime body: []const u8) []const u8 {
    return pkg(WHILE, predicate ++ body);
}

/// `Buffer (size) { bytes }`, `size` already a constant.
pub fn buffer(comptime size: []const u8, comptime bytes: []const u8) []const u8 {
    return pkg(BUFFER, size ++ bytes);
}

/// `Package (count) { elements }`.
pub fn package(comptime count: u8, comptime elements: []const u8) []const u8 {
    return pkg(PACKAGE, [_]u8{count} ++ elements);
}

/// `Name (path, value)`, `value` a part as `code` takes one.
pub fn nameOf(comptime path: []const u8, comptime value: anytype) []const u8 {
    return comptime [_]u8{NAME} ++ name(path) ++ bytesOf(value);
}

/// `OperationRegion (path, space, offset, length)`, the offset and the
/// length already terms.
pub fn region(comptime path: []const u8, comptime space: u8, comptime offset: anytype, comptime length: anytype) []const u8 {
    return comptime REGION ++ name(path) ++ [_]u8{space} ++ bytesOf(offset) ++ bytesOf(length);
}

/// `Field (region, flags) { units }`: `flags` the access type in its low
/// four bits, 0x10 the lock, 0x20 WriteAsOnes, 0x40 WriteAsZeros; the
/// units what `unit` and `skip` write.
pub fn field(comptime region_path: []const u8, comptime flags: u8, comptime units: []const u8) []const u8 {
    return pkg(FIELD, name(region_path) ++ [_]u8{flags} ++ units);
}

/// `IndexField (index, data, flags) { units }`.
pub fn indexField(comptime index_path: []const u8, comptime data_path: []const u8, comptime flags: u8, comptime units: []const u8) []const u8 {
    return pkg(INDEX_FIELD, name(index_path) ++ name(data_path) ++ [_]u8{flags} ++ units);
}

/// `BankField (region, bank, value, flags) { units }`, the value already
/// a term.
pub fn bankField(comptime region_path: []const u8, comptime bank_path: []const u8, comptime value: anytype, comptime flags: u8, comptime units: []const u8) []const u8 {
    return pkg(BANK_FIELD, name(region_path) ++ name(bank_path) ++ bytesOf(value) ++ [_]u8{flags} ++ units);
}

/// A named unit of a field list, `bits` wide.
pub fn unit(comptime unit_name: []const u8, comptime bits: u32) []const u8 {
    return comptime unitBytes(unit_name, bits);
}

fn unitBytes(comptime unit_name: []const u8, comptime bits: u32) []const u8 {
    var filled: [4]u8 = "____".*;
    for (unit_name, 0..) |char, index| filled[index] = char;
    const done = filled ++ bitsOf(bits)[0..bitsOf(bits).len].*;
    return &done;
}

/// Bits of a field list left out: what `Offset` writes as well.
pub fn skip(comptime bits: u32) []const u8 {
    return comptime [_]u8{0x00} ++ bitsOf(bits);
}

/// A width in bits, in a package length's encoding that counts nothing
/// but its value.
fn bitsOf(comptime value: u32) []const u8 {
    return comptime bitsBytes(value);
}

fn bitsBytes(comptime value: u32) []const u8 {
    if (value <= 0x3F) return &[_]u8{value};
    for (1..4) |follow| {
        if (value < 1 << (4 + 8 * follow)) {
            var bytes: []const u8 = &[_]u8{@as(u8, follow << 6 | (value & 0x0F))};
            for (0..follow) |index| bytes = bytes ++ [_]u8{@truncate(value >> (4 + 8 * index))};
            const done = bytes[0..bytes.len].*;
            return &done;
        }
    }
    @compileError("a field too wide");
}

/// An extended opcode's two bytes.
pub fn ext(comptime value: u8) []const u8 {
    return &[_]u8{ 0x5B, value };
}

// The opcodes, by their names in the source.
pub const ZERO = 0x00;
pub const ONE = 0x01;
pub const ALIAS = 0x06;
pub const NAME = 0x08;
pub const SCOPE = 0x10;
pub const BUFFER = 0x11;
pub const PACKAGE = 0x12;
pub const VAR_PACKAGE = 0x13;
pub const METHOD = 0x14;
pub const LOCAL0 = 0x60;
pub const LOCAL1 = 0x61;
pub const LOCAL2 = 0x62;
pub const LOCAL3 = 0x63;
pub const LOCAL4 = 0x64;
pub const LOCAL5 = 0x65;
pub const LOCAL6 = 0x66;
pub const LOCAL7 = 0x67;
pub const ARG0 = 0x68;
pub const ARG1 = 0x69;
pub const ARG2 = 0x6A;
pub const ARG3 = 0x6B;
pub const STORE = 0x70;
pub const REF_OF = 0x71;
pub const ADD = 0x72;
pub const CONCATENATE = 0x73;
pub const SUBTRACT = 0x74;
pub const INCREMENT = 0x75;
pub const DECREMENT = 0x76;
pub const MULTIPLY = 0x77;
pub const DIVIDE = 0x78;
pub const SHIFT_LEFT = 0x79;
pub const SHIFT_RIGHT = 0x7A;
pub const AND = 0x7B;
pub const NAND = 0x7C;
pub const OR = 0x7D;
pub const NOR = 0x7E;
pub const XOR = 0x7F;
pub const NOT = 0x80;
pub const FIND_SET_LEFT_BIT = 0x81;
pub const FIND_SET_RIGHT_BIT = 0x82;
pub const DEREF_OF = 0x83;
pub const CONCATENATE_RES_TEMPLATE = 0x84;
pub const MOD = 0x85;
pub const NOTIFY = 0x86;
pub const SIZE_OF = 0x87;
pub const INDEX = 0x88;
pub const MATCH = 0x89;
pub const CREATE_DWORD_FIELD = 0x8A;
pub const CREATE_WORD_FIELD = 0x8B;
pub const CREATE_BYTE_FIELD = 0x8C;
pub const CREATE_BIT_FIELD = 0x8D;
pub const OBJECT_TYPE = 0x8E;
pub const CREATE_QWORD_FIELD = 0x8F;
pub const LAND = 0x90;
pub const LOR = 0x91;
pub const LNOT = 0x92;
pub const LEQUAL = 0x93;
pub const LGREATER = 0x94;
pub const LLESS = 0x95;
pub const TO_BUFFER = 0x96;
pub const TO_DECIMAL_STRING = 0x97;
pub const TO_HEX_STRING = 0x98;
pub const TO_INTEGER = 0x99;
pub const TO_STRING = 0x9C;
pub const COPY_OBJECT = 0x9D;
pub const MID = 0x9E;
pub const CONTINUE = 0x9F;
pub const IF = 0xA0;
pub const ELSE = 0xA1;
pub const WHILE = 0xA2;
pub const NOOP = 0xA3;
pub const RETURN = 0xA4;
pub const BREAK = 0xA5;
pub const ONES = 0xFF;

pub const MUTEX = ext(0x01);
pub const EVENT = ext(0x02);
pub const COND_REF_OF = ext(0x12);
pub const CREATE_FIELD = ext(0x13);
pub const LOAD_TABLE = ext(0x1F);
pub const LOAD = ext(0x20);
pub const STALL = ext(0x21);
pub const SLEEP = ext(0x22);
pub const ACQUIRE = ext(0x23);
pub const SIGNAL = ext(0x24);
pub const WAIT = ext(0x25);
pub const RESET = ext(0x26);
pub const RELEASE = ext(0x27);
pub const FROM_BCD = ext(0x28);
pub const TO_BCD = ext(0x29);
pub const UNLOAD = ext(0x2A);
pub const REVISION = ext(0x30);
pub const DEBUG = ext(0x31);
pub const FATAL = ext(0x32);
pub const TIMER = ext(0x33);
pub const REGION = ext(0x80);
pub const FIELD = ext(0x81);
pub const DEVICE = ext(0x82);
pub const THERMAL_ZONE = ext(0x85);
pub const INDEX_FIELD = ext(0x86);
pub const BANK_FIELD = ext(0x87);
pub const DATA_REGION = ext(0x88);
