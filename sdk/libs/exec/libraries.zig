// SPDX-License-Identifier: MIT
//! Libraries (exec/libraries.h). A library is one block of memory: the jump
//! table (one function pointer per vector) in front of the library base,
//! the `Library` header and the library's own data behind it.
//!
//!              ┌─────────────────────┐  base - neg_size
//!              │ user vector n       │
//!              │ ...                 │
//!              │ user vector 0       │  LIB_USERDEF
//!              │ ExtFunc (reserved)  │  LIB_EXTFUNC
//!              │ Expunge             │  LIB_EXPUNGE
//!              │ Close               │  LIB_CLOSE
//!              │ Open                │  LIB_OPEN = base - slot_size
//!   base ────► ├─────────────────────┤
//!              │ Library             │
//!              │ library data        │
//!              └─────────────────────┘  base + pos_size
//!
//! Functions get the library base as their first argument.

const std = @import("std");
const Node = @import("nodes.zig").Node;
const ExecBase = @import("../../interface/exec.zig").ExecBase;

/// Bytes per jump-table entry: one function pointer (6 bytes of JMP on 68k).
pub const slot_size = @sizeOf(*const anyopaque);

/// Library vector offset (LVO) of vector `index`, counted from the base.
pub fn lvo(index: usize) isize {
    return -@as(isize, @intCast((index + 1) * slot_size));
}

pub const LIB_OPEN = lvo(0);
pub const LIB_CLOSE = lvo(1);
pub const LIB_EXPUNGE = lvo(2);
pub const LIB_EXTFUNC = lvo(3);
/// First library-specific vector.
pub const LIB_USERDEF = lvo(4);
/// Open, Close, Expunge and ExtFunc come first in every library.
pub const standard_vectors = 4;

/// lib_Flags
pub const LIBF_SUMMING: u8 = 1 << 0;
pub const LIBF_CHANGED: u8 = 1 << 1;
pub const LIBF_SUMUSED: u8 = 1 << 2;
pub const LIBF_DELEXP: u8 = 1 << 3;

/// struct Library.
pub const Library = extern struct {
    /// lib_Node: ln_Type is NT_LIBRARY, ln_Name the library's name.
    node: Node = .{ .type = .library },
    flags: u8 = 0,
    pad: u8 = 0,
    /// Bytes of jump table in front of the base.
    neg_size: u16 = 0,
    /// Bytes from the base: this header and the library's data.
    pos_size: u16 = 0,
    version: u16 = 0,
    revision: u16 = 0,
    id_string: ?[*:0]const u8 = null,
    /// Checksum of the jump table, see SumLibrary.
    sum: u32 = 0,
    open_cnt: u16 = 0,

    pub fn name(lib: *const Library) [:0]const u8 {
        return std.mem.span(lib.node.name orelse return "");
    }

    /// The function in the jump table at `offset` (an LVO), as type `F`.
    pub fn vector(lib: *Library, comptime F: type, offset: isize) F {
        return @ptrCast(@alignCast(lib.slot(offset).*));
    }

    /// The jump-table entry at `offset` (an LVO).
    ///
    /// It checks nothing, and that is measured rather than assumed. Every
    /// call through a jump table comes here, the check was a load of
    /// `neg_size`, a compare and a branch at each of those sites, and
    /// taking it out is **20744 bytes of this ROM's code, 3.6% of it** -
    /// while most calls still go direct. Under the codex's rule that every
    /// call goes through the table, it would be more again.
    ///
    /// What it bought was little. At every generated call site the offset
    /// is a constant the compiler knows, and `call` below checks those at
    /// compile time for nothing. The one place an offset comes from a
    /// caller at run time is `SetFunction`, which checks it itself and can
    /// afford to - it runs twice at boot, not twice a scanline.
    pub fn slot(lib: *Library, offset: isize) **const anyopaque {
        return @ptrFromInt(@intFromPtr(lib) - @as(usize, @intCast(-offset)));
    }
};

pub const OpenFn = *const fn (lib: *Library, version: u32) callconv(.c) ?*Library;
/// Returns the seglist to unload when the library was expunged, else null.
pub const CloseFn = *const fn (lib: *Library) callconv(.c) ?*anyopaque;
pub const ExpungeFn = *const fn (lib: *Library) callconv(.c) ?*anyopaque;
pub const ExtFuncFn = *const fn (lib: *Library) callconv(.c) ?*anyopaque;
/// The init routine MakeLibrary, CreateLibrary and InitResident call on the
/// new base, with SysBase. Return the base, or null to
/// give up (the memory is then freed).
pub const InitFn = *const fn (lib: *Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*Library;

/// A function as a jump-table entry.
pub fn vec(comptime f: anytype) *const anyopaque {
    return @ptrCast(&f);
}

/// Call the function at `offset` (an LVO) in the jump table of the library
/// at `base`, as type `F`, with the base as its first argument. The SDK's
/// interfaces (sdk/interface) make their calls with it.
pub inline fn call(base: anytype, comptime offset: isize, comptime F: type, args: anytype) @typeInfo(@typeInfo(F).pointer.child).@"fn".return_type.? {
    // The offset is a constant here, so what a check at run time could
    // have found is found by the compiler instead, and costs nothing at
    // all: an LVO is negative and a whole number of slots back from the
    // base. What it cannot check - that the library is new enough to have
    // this slot - is what OpenLibrary's version is for.
    comptime {
        if (offset >= 0) @compileError("an LVO is negative: the jump table is in front of the base");
        if (@mod(-offset, @as(isize, slot_size)) != 0)
            @compileError("an LVO is a whole number of slots back from the base");
    }
    const lib: *Library = @ptrCast(@alignCast(base));
    return @call(.auto, lib.vector(F, offset), .{base} ++ args);
}

/// Check at compile time that every slot's work is done by a function
/// named after it, so that the name in the `.fd` finds the code.
///
/// INPUTS:
/// - `source` - the implementation file's own text, as `@embedFile` gives
///   it. It is read at compile time and none of it is in the binary.
/// - `LVO` - the generated LVO struct, whose declarations are the slots.
/// - `who` - the library's name, for the message.
/// - `inline_slots` - the slots whose `lvo` wrapper *is* the whole
///   implementation, with nothing else to call. Naming them here is a
///   decision rather than an oversight, which is the point: the rule
///   exists so that grepping a `.fd` name reaches the code, and a wrapper
///   that holds the code satisfies it. A wrapper that calls something else
///   under a different name does not.
///
/// The function may be named after the slot exactly - `PrintIText`, the
/// call in a file of its own with its contract - or with its first letter
/// lowered - `printIText`, a module's helper behind a documented wrapper.
///
/// It looks at the text after each `fn lvo<Name>(`, so it is a reading of
/// the source rather than of the syntax tree: good enough to catch a
/// function that was named for how it reads in its own file - `new`,
/// `contains`, `addDriver` - which is how this goes wrong every time.
pub fn checkSlotNames(
    comptime source: []const u8,
    comptime LVO: type,
    comptime who: []const u8,
    comptime inline_slots: []const []const u8,
) void {
    // Each slot searches the whole file twice, so the budget grows with
    // both. Generous rather than tight: it is paid once, at compile time.
    @setEvalBranchQuota(@typeInfo(LVO).@"struct".decls.len * source.len / 4 + 100_000);
    for (@typeInfo(LVO).@"struct".decls) |d| {
        var is_inline = false;
        for (inline_slots) |name| {
            if (std.mem.eql(u8, name, d.name)) is_inline = true;
        }
        if (is_inline) continue;

        // At the start of a line, so that the same text inside a doc
        // comment - every SYNOPSIS block holds one - is passed over.
        const wrapper = "\nfn lvo" ++ d.name ++ "(";
        const at = std.mem.indexOf(u8, source, wrapper) orelse
            @compileError(who ++ ": no lvo" ++ d.name ++ " at the start of a line " ++
                "in the source given");
        // Far enough to clear the signature and a body of a few lines.
        // The wrapper's own name is passed over: it holds the slot's.
        const end = @min(at + 800, source.len);
        const body = source[at + wrapper.len .. end];
        const want = [_]u8{d.name[0] | 0x20} ++ d.name[1..] ++ "(";
        const exact = d.name ++ "(";
        if (std.mem.indexOf(u8, body, want) == null and std.mem.indexOf(u8, body, exact) == null) {
            @compileError(who ++ ": lvo" ++ d.name ++ " does not reach a function called " ++
                exact ++ " or " ++ want ++ " - the function behind a slot is named after it, so that the " ++
                "name in the .fd finds the code (docs/codex.md). If the wrapper is the " ++
                "whole implementation, say so in its checkSlotNames list.");
        }
    }
}

/// Check at compile time that each slot's documented LVO is the one the
/// generated interface actually gives it.
///
/// INPUTS:
/// - `source` - the implementation file's own text, as `@embedFile` gives
///   it. It is read at compile time and none of it is in the binary.
/// - `LVO` - the generated LVO struct, whose declarations are the slots.
/// - `who` - the library's name, for the message.
///
/// A doc comment says `SINCE: <version>. LVO -N.`, and that number is
/// written by hand while the real one comes from the `.fd`. The two drift
/// silently: a wrong LVO in a contract is read by whoever is writing
/// against the library, and nothing else ever compares them.
///
/// The documented number is the **machine's**, where a slot is four bytes.
/// A host test builds for the host, where a pointer is eight, so the two
/// are compared as slot indices rather than byte offsets - the index is
/// what the `.fd` fixes and it is the same everywhere.
///
/// A slot whose wrapper documents no LVO at all is passed over, so this
/// checks what is written rather than demanding that anything be.
pub fn checkDocumentedLvos(
    comptime source: []const u8,
    comptime LVO: type,
    comptime who: []const u8,
) void {
    checkDocumentedLvosAt(source, LVO, who, "fn lvo");
}

/// `checkDocumentedLvos` for contracts written above a declaration other
/// than the `lvo` wrapper: `declaration` is what precedes the slot's name
/// at the start of a line - `"pub fn "` for a contract on the
/// implementation named after its slot.
pub fn checkDocumentedLvosAt(
    comptime source: []const u8,
    comptime LVO: type,
    comptime who: []const u8,
    comptime declaration: []const u8,
) void {
    @setEvalBranchQuota(20 * source.len + 100_000);
    // One pass over the lines, keeping where the current run of `///`
    // lines began. A declaration at the start of a line - so the same text
    // in a SYNOPSIS block is passed over, as in checkSlotNames - is checked
    // against the doc run right above it.
    var doc_start: ?usize = null;
    var line_start: usize = 0;
    while (line_start < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
        const line = source[line_start..line_end];
        if (std.mem.startsWith(u8, line, "///")) {
            if (doc_start == null) doc_start = line_start;
        } else {
            if (doc_start) |start| {
                if (std.mem.startsWith(u8, line, declaration)) {
                    if (std.mem.indexOfScalar(u8, line, '(')) |open| {
                        const name = line[declaration.len..open];
                        if (@hasDecl(LVO, name)) {
                            checkDocumentedLvo(source[start..line_start], @field(LVO, name), who, name);
                        }
                    }
                }
            }
            doc_start = null;
        }
        line_start = line_end + 1;
    }
}

/// One slot's doc block against its LVO from the .fd.
fn checkDocumentedLvo(comptime doc: []const u8, comptime offset: isize, comptime who: []const u8, comptime name: []const u8) void {
    const marker = "LVO -";
    const found = std.mem.indexOf(u8, doc, marker) orelse return;
    var n: isize = 0;
    var i = found + marker.len;
    while (i < doc.len and doc[i] >= '0' and doc[i] <= '9') : (i += 1) {
        n = n * 10 + (doc[i] - '0');
    }
    // Slot indices, not byte offsets: a documented LVO counts the
    // machine's four-byte slots, and a host build's are eight.
    const machine_slot_size = 4;
    if (@mod(n, machine_slot_size) != 0) {
        @compileError(who ++ ": " ++ name ++ " documents LVO -" ++
            std.fmt.comptimePrint("{d}", .{n}) ++
            ", which is not a whole number of slots.");
    }
    const documented_index = @divExact(n, machine_slot_size) - 1;
    const actual_index = @divExact(-offset, @as(isize, slot_size)) - 1;
    if (documented_index != actual_index) {
        @compileError(who ++ ": " ++ name ++ " documents LVO -" ++
            std.fmt.comptimePrint("{d}", .{n}) ++ " (slot " ++
            std.fmt.comptimePrint("{d}", .{documented_index}) ++ "), but it is slot " ++
            std.fmt.comptimePrint("{d}", .{actual_index}) ++ ", which on the machine is LVO -" ++
            std.fmt.comptimePrint("{d}", .{(actual_index + 1) * machine_slot_size}) ++
            " - the .fd is the source of truth (docs/codex.md).");
    }
}

/// Check that every `lvo<Name>` wrapper only hands over: its body is one
/// call to the function named after its slot, with the base first and
/// the wrapper's own parameters after it, in order (docs/codex.md, rule
/// 4). A parameter or the result may be cast between the SDK's opaque
/// type and the library's own. Two parameters of the same type swapped
/// still compile; this is what catches them.
///
/// INPUTS:
/// - `source` - the `_lvo` file's own text, as `@embedFile` gives it.
///   Only the part before its `// --- tests` line is read, so the tests'
///   own helpers are not taken for wrappers.
/// - `LVO` - the generated LVO struct: every slot must have been checked.
/// - `skip` - the slots whose wrapper may add what only it has, such as
///   exec's `Alert`, which takes its caller's return address.
///
/// RESULT:
/// `error.WrapperForwarding` for the first wrapper that does not hand
/// over as it should, after printing which, and `error.WrapperCount` when
/// the file does not hold a wrapper for every slot.
///
/// NOTES:
/// It reads the text, not the syntax tree, and is called from a host test
/// only: nothing of it is in the ROM.
pub fn checkForwarding(source: []const u8, comptime LVO: type, skip: []const []const u8) error{ WrapperForwarding, WrapperCount }!void {
    var checked: usize = 0;
    const tests_at = std.mem.indexOf(u8, source, "\n// --- tests") orelse source.len;
    var rest: []const u8 = source[0..tests_at];
    wrappers: while (std.mem.indexOf(u8, rest, "\nfn lvo")) |at| {
        rest = rest[at + "\nfn ".len ..];
        const open = std.mem.indexOfScalar(u8, rest, '(') orelse return error.WrapperForwarding;
        const slot = rest["lvo".len..open];
        for (skip) |name| {
            if (std.mem.eql(u8, name, slot)) {
                checked += 1;
                continue :wrappers;
            }
        }
        const close = std.mem.indexOf(u8, rest, ") callconv(.c)") orelse return error.WrapperForwarding;
        const body_start = (std.mem.indexOf(u8, rest, "{\n") orelse return error.WrapperForwarding) + 2;
        const body_end = body_start + (std.mem.indexOf(u8, rest[body_start..], "\n}") orelse return error.WrapperForwarding);
        var body = std.mem.trim(u8, rest[body_start..body_end], " \n");
        if (std.mem.startsWith(u8, body, "return ")) body = body["return ".len..];
        // A call that answers in the library's own type has its result cast
        // back to the SDK's, which only changes how the pointer is typed.
        while (std.mem.startsWith(u8, body, "@ptrCast(") or std.mem.startsWith(u8, body, "@alignCast(")) {
            body = body[std.mem.indexOfScalar(u8, body, '(').? + 1 .. std.mem.lastIndexOfScalar(u8, body, ')').?];
        }

        // The call it hands the work to: its name, or a path ending in it.
        const call_open = std.mem.indexOfScalar(u8, body, '(') orelse return forwardingFailed(slot, "calls nothing");
        const callee = body[0..call_open];
        const name_start = if (std.mem.lastIndexOfScalar(u8, callee, '.')) |dot| dot + 1 else 0;
        if (!std.mem.eql(u8, slot, callee[name_start..])) return forwardingFailed(slot, "calls a function of another name");

        var names: [16][]const u8 = undefined;
        const count = parameterNames(rest[open + 1 .. close], &names);

        // The identifiers of the arguments that are parameters, in order:
        // the base first, then the wrapper's own.
        const args = body[call_open + 1 .. std.mem.lastIndexOfScalar(u8, body, ')') orelse return error.WrapperForwarding];
        var seen: usize = 0;
        var word_start: ?usize = null;
        for (args, 0..) |c, index| {
            const word_char = std.ascii.isAlphanumeric(c) or c == '_';
            if (word_char and word_start == null) word_start = index;
            if ((!word_char or index == args.len - 1) and word_start != null) {
                const end = if (word_char) index + 1 else index;
                const word = args[word_start.?..end];
                word_start = null;
                for (names[0..count]) |name| {
                    if (std.mem.eql(u8, name, word)) {
                        if (!std.mem.eql(u8, names[seen], word)) return forwardingFailed(slot, "passes its parameters out of order");
                        seen += 1;
                        break;
                    }
                }
            }
        }
        if (seen != count) return forwardingFailed(slot, "does not pass on every parameter");
        checked += 1;
    }
    if (checked != @typeInfo(LVO).@"struct".decls.len) return error.WrapperCount;
}

/// Reports a wrapper `checkForwarding` refuses.
///
/// INPUTS:
/// - `slot` - the wrapper's slot name.
/// - `what` - what is wrong with it.
fn forwardingFailed(slot: []const u8, what: []const u8) error{WrapperForwarding} {
    std.debug.print("lvo{s} {s} (docs/codex.md, rule 4)\n", .{ slot, what });
    return error.WrapperForwarding;
}

/// A wrapper's parameter names, in order, from its parameter list: split
/// at the commas outside brackets.
///
/// INPUTS:
/// - `params` - the text between the wrapper's parentheses.
/// - `names` - where the names go.
///
/// RESULT:
/// How many there are.
fn parameterNames(params: []const u8, names: *[16][]const u8) usize {
    var count: usize = 0;
    var depth: usize = 0;
    var start: usize = 0;
    for (params, 0..) |c, index| {
        switch (c) {
            '(', '[' => depth += 1,
            ')', ']' => depth -= 1,
            ',' => if (depth == 0) {
                names[count] = nameOf(params[start..index]);
                count += 1;
                start = index + 1;
            },
            else => {},
        }
    }
    names[count] = nameOf(params[start..]);
    return count + 1;
}

/// The name of one parameter, from its `name: Type` text.
///
/// INPUTS:
/// - `param` - one parameter's text.
fn nameOf(param: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, param, " \n");
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse trimmed.len;
    return std.mem.trim(u8, trimmed[0..colon], " ");
}

/// Whether a library's function of type `Have` implements the interface's
/// function type `Want` (Fn.Name in sdk/interface): the same parameters
/// apart from the base, the same result, the same calling convention. A
/// library checks its jump table with it at compile time. The base is the
/// module's own (isOwnBase), as the SDK's Fn has it: never exec's bare
/// Library or Device.
pub fn sameSignature(comptime Have: type, comptime Want: type) bool {
    const have = @typeInfo(@typeInfo(Have).pointer.child).@"fn";
    const want = @typeInfo(@typeInfo(Want).pointer.child).@"fn";
    if (have.params.len != want.params.len or have.return_type.? != want.return_type.?) return false;
    if (!std.meta.eql(have.calling_convention, want.calling_convention)) return false;
    if (!isOwnBase(have.params[0].type.?)) return false;
    for (have.params[1..], want.params[1..]) |p, q| {
        if (p.type.? != q.type.?) return false;
    }
    return true;
}

/// A function's first parameter: a pointer to the module's own base, a
/// struct that starts with its Library (or Device) header, such as
/// UtilityBase, TimerBase or DmaBase. Not the bare header itself.
fn isOwnBase(comptime P: type) bool {
    const info = @typeInfo(P);
    if (info != .pointer) return false;
    const Base = info.pointer.child;
    const Device = @import("devices.zig").Device;
    if (Base == Library or Base == Device) return false;
    const s = switch (@typeInfo(Base)) {
        .@"struct" => |s| s,
        else => return false,
    };
    return s.fields.len > 0 and (s.fields[0].type == Library or s.fields[0].type == Device);
}

// sameSignature holds a function to the module's own base: one that takes
// the bare Library header is refused, whatever else matches. Checked here,
// at compile time, since everything that builds against the SDK compiles
// it.
comptime {
    const OwnBase = extern struct { lib: Library, count: u32 };
    const Want = *const fn (*OwnBase, u32) callconv(.c) void;
    if (!sameSignature(*const fn (*OwnBase, u32) callconv(.c) void, Want))
        @compileError("sameSignature refuses a function on the module's own base");
    if (sameSignature(*const fn (*Library, u32) callconv(.c) void, Want))
        @compileError("sameSignature takes a function on the bare Library");
}

/// Standard Open: count the opener, cancel a pending expunge.
pub fn libOpen(lib: *Library, version: u32) callconv(.c) ?*Library {
    _ = version;
    lib.open_cnt += 1;
    lib.flags &= ~LIBF_DELEXP;
    return lib;
}

/// Standard Close: the last close carries out a delayed expunge.
pub fn libClose(lib: *Library) callconv(.c) ?*anyopaque {
    lib.open_cnt -= 1;
    if (lib.open_cnt == 0 and lib.flags & LIBF_DELEXP != 0) {
        return lib.vector(ExpungeFn, LIB_EXPUNGE)(lib);
    }
    return null;
}

/// The reserved ExtFunc vector.
pub fn libExtFunc(lib: *Library) callconv(.c) ?*anyopaque {
    _ = lib;
    return null;
}

/// Everything CreateLibrary needs.
pub const LibraryInit = struct {
    name: [:0]const u8,
    version: u16 = 0,
    revision: u16 = 0,
    id_string: ?[:0]const u8 = null,
    /// Position on the library list (ln_Pri).
    pri: i8 = 0,
    /// Size of the base: Library plus the library's own data.
    data_size: usize = @sizeOf(Library),
    /// The whole jump table: Open, Close, Expunge, ExtFunc, then the
    /// library's own functions. Every library brings its own; `libOpen`,
    /// `libClose` and `libExtFunc` are there for the three that need
    /// nothing special.
    vectors: []const *const anyopaque,
    /// Runs on the finished base before it goes on the list.
    init: ?InitFn = null,
    seg_list: ?*anyopaque = null,
};
