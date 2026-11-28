// SPDX-License-Identifier: MPL-2.0
//! The interpreter: bytecode run where it is, a term at a time - a
//! method's body when the method is called, a table's terms as the table
//! is loaded.
//!
//! **An evaluation** (`Run`) keeps three stacks in the interpreter's own
//! memory, never on the calling task's: the methods it is in (`Frame`:
//! where in the body it is, the scope, the locals and the arguments), the
//! terms it is working out (`Op`: an operator and the operands it has so
//! far) and the blocks it is inside (`Block`: an If's, an Else's or a
//! While's body, a Scope's or a Device's). A step either reads the next
//! operand of the term on top - a number, a name, or another term, which
//! goes on top until it has a value - or, once the term has them all,
//! does what the term says and hands its result to the term below, which
//! wanted it as an operand. A method call is a term whose operands are
//! the arguments; doing it puts the method on top, and its Return is the
//! call's result. However deep the firmware's bytecode goes, it costs the
//! evaluation memory, and the task's stack nothing.
//!
//! **What an operand is.** A TermArg (`term`) is a value: a constant, a
//! string, what a name holds - a field read where it is a field -, a
//! local's or an argument's object, a term's result; a name there that
//! holds a method is a call of it. A SuperName or a Target (`target`) is
//! where a result goes or what an operator asks about (`Place`): a name,
//! a local, an argument, the Debug object, nothing (a Zero), or what a
//! term answers - a reference, or an object stored into where it is; a
//! name there is never called. CondRefOf's (`cond`) may name what is not
//! there.
//!
//! **Loading** runs a table's terms the same way, at the root: each
//! definition makes its name to stay, and code outside any method runs
//! as it is met. What goes wrong while a table loads is said and leaves
//! out what it has to - the term, or the rest of the list it is in, where
//! nothing says where the next term starts - and the rest of the table
//! is loaded. While a method runs, an error ends the whole evaluation: it
//! is said in the log, with the method and where in it, and the caller
//! is told.
//!
//! **Names a method makes** while it runs are taken out of the namespace
//! again when it returns. A serialized method is run by one evaluation at
//! a time, holding its own mutex at its sync level.

const sdk = @import("sdk");
const exec = sdk.exec;
const machine = @import("../machine/_machine.zig");
const Stack = machine.Stack;
const AcpiBase = @import("../acpi_base.zig").AcpiBase;
const namespace = @import("../namespace/_namespace.zig");
const Node = namespace.Node;
const Path = namespace.Path;
const object = @import("../object/_object.zig");
const Object = object.Object;
const aml = @import("../aml/_aml.zig");
const Reader = aml.Reader;
const opcodes = @import("../aml/opcodes.zig");
const load = @import("../aml/load.zig");
const operators = @import("operators.zig");
const store = @import("store.zig");
const define = @import("define.zig");
const sync = @import("sync.zig");
const region = @import("../region/_region.zig");
const convert = @import("convert.zig");

/// Why an evaluation ended early.
pub const Error = error{
    /// A name the bytecode refers to is not there.
    NotFound,
    /// An operand of a kind the operator does not take.
    Type,
    /// An index or a length past what it is of.
    Range,
    /// No memory for an object, or for the interpreter's own stacks.
    NoMemory,
    /// An opcode the interpreter does not know.
    Unknown,
    /// Bytes that are no term: a package past its end, a name cut short.
    Broken,
    /// A limit reached: calls nested too deep, a loop that would not end.
    Limit,
    /// A name a method defines that is there already.
    Exists,
    /// A value read where nothing was ever stored.
    Uninitialized,
    /// A division by zero.
    DivideByZero,
    /// The firmware's own Fatal.
    Fatal,
    /// A mutex released by an evaluation that does not hold it, or taken
    /// below a level already held.
    Mutex,
    /// A field or a region the machine cannot reach.
    Access,
};

/// What a term worked out, or what an operand is.
pub const Item = union(enum) {
    /// Nothing: a method that returned nothing, a term with no result.
    none,
    /// An integer, which needs no object.
    integer: u64,
    /// An object, held.
    object: *Object,
    /// Where a result goes.
    place: Place,
    /// A name string as the bytecode wrote it.
    path: Path,
};

/// Where a result goes, or what an operator asks about.
pub const Place = union(enum) {
    /// Nowhere: a Zero where a target may be.
    none,
    /// The Debug object: what is stored there is said in the log.
    debug,
    /// A name.
    node: *Node,
    /// A local or an argument of the method running.
    local: u8,
    arg: u8,
    /// What a reference refers to (RefOf, Index), held.
    reference: *Object,
    /// An object a term answered, stored into where it is, held.
    object: *Object,
    /// A name CondRefOf asks about that is not there.
    missing,
};

/// The kinds of operand a term's bytecode has, in order.
pub const Operand = enum(u8) {
    /// A TermArg: a value.
    term,
    /// A SuperName or a Target: a place.
    target,
    /// CondRefOf's SuperName: a place, or `missing`.
    cond,
    /// A NameString, as written.
    name,
    /// A number in the bytecode itself.
    byte,
    word,
    dword,
    /// A package length: the term ends at its end.
    pkg,
};

/// What a term at the reader is wanted as.
const Want = enum { statement, term, target, cond, element };

/// A method call's code: no opcode has it.
pub const CALL: u16 = 0xFFFF;

/// A term being worked out: its opcode, where it starts in its frame's
/// code, its operands and how many it has so far. A term that holds a
/// package keeps its end, and the reader's end outside it.
pub const Op = struct {
    code: u16,
    start: usize,
    operands: []const Operand,
    next: u8 = 0,
    items: [7]Item = [_]Item{.none} ** 7,
    end: usize = 0,
    outer_end: usize = 0,
    /// A call's method.
    node: ?*Node = null,
    /// A Package's elements so far, while it is filled.
    filling: bool = false,
    count: u32 = 0,
    /// A call whose method runs.
    calling: bool = false,
};

/// A body being run inside a method or a table: where it ends, the
/// reader's end outside it, and what to do there.
pub const Block = struct {
    kind: Kind,
    /// A While's: where the While starts, which runs again.
    start: usize = 0,
    end: usize,
    outer_end: usize,
    /// A Scope's or a Device's: the scope outside it, back at its end.
    scope: ?*Node = null,

    pub const Kind = enum { scope, taken, other, loop };
};

/// A method running, or a table's code: where it is, the scope names are
/// made and looked up in, its locals and arguments (each held), and where
/// its ops, blocks and the names it made start on the run's stacks.
pub const Frame = struct {
    reader: Reader,
    scope: *Node,
    method: ?*Node,
    locals: [8]?*Object = [_]?*Object{null} ** 8,
    args: [7]?*Object = [_]?*Object{null} ** 7,
    ops: u32,
    blocks: u32,
    temporaries: u32,
    /// Where the term it runs at its own level starts.
    statement_at: usize = 0,
    /// The While loop timed last, and when it has to have ended.
    loop_at: usize = NO_LOOP,
    loop_deadline: u64 = 0,
    /// A serialized method's own mutex, taken for it.
    serialized: bool = false,
};

const NO_LOOP = ~@as(usize, 0);

/// The deepest methods call one another.
pub const MOST_CALLS = 128;

/// The deepest terms are inside one another, in one evaluation.
pub const MOST_OPS = 4096;

/// How long a While may go on before the evaluation is ended: 30 seconds,
/// in the clock's units of 100 nanoseconds.
pub const MOST_LOOP = 30 * 10_000_000;

/// One evaluation.
pub const Run = struct {
    ab: *AcpiBase,
    frames: Stack(Frame) = .{},
    ops: Stack(Op) = .{},
    blocks: Stack(Block) = .{},
    temporaries: Stack(*Node) = .{},
    /// A table being loaded: names made stay, and what goes wrong leaves
    /// out a term instead of ending the run.
    load: ?*load.Load = null,
    /// What the outermost method returned.
    result: Item = .none,
    /// The mutexes it holds, last taken on top - a serialized method's
    /// among them -, and the level of the one on top.
    mutexes: Stack(*Object) = .{},
    sync_level: u8 = 0,
    /// Who holds what it takes: the evaluation it is nested in, where it
    /// is; null for itself.
    owner: ?*const anyopaque = null,
    /// A name the last error is about, for the log.
    detail: [namespace.PATH_ROOM]u8 = undefined,
    has_detail: bool = false,

    /// What the evaluation's stacks took, given back: for one made only
    /// to look at the namespace with, as `call` frees its own.
    pub fn deinit(run: *Run) void {
        run.frames.free(run.ab);
        run.ops.free(run.ab);
        run.blocks.free(run.ab);
        run.temporaries.free(run.ab);
        run.mutexes.free(run.ab);
    }
};

/// Who holds the mutexes `run` takes.
pub fn ownerOf(run: *const Run) *const anyopaque {
    return run.owner orelse @ptrCast(run);
}

// --- the items ----------------------------------------------------------------------

/// What `item` held let go of.
pub fn release(ab: *AcpiBase, item: Item) void {
    switch (item) {
        .object => |held| object.release(ab, held),
        .place => |place| switch (place) {
            .reference, .object => |held| object.release(ab, held),
            else => {},
        },
        else => {},
    }
}

/// `item` as an object, held: an integer made one.
pub fn objectOf(run: *Run, item: Item) Error!*Object {
    return switch (item) {
        .object => |held| held,
        .integer => |value| object.makeInteger(run.ab, value) orelse error.NoMemory,
        .none => object.make(run.ab, .{ .uninitialized = {} }) orelse error.NoMemory,
        else => error.Type,
    };
}

/// The name `path` from the frame's scope, by the search rules; the
/// error said with the name where it is not there.
pub fn findName(run: *Run, frame: *const Frame, path: Path) Error!*Node {
    return namespace.find(run.ab, frame.scope, path, .search) orelse notFound(run, frame.scope, path);
}

/// `path` is not there, from `scope`: the name kept for the log.
pub fn notFound(run: *Run, scope: *Node, path: Path) Error {
    _ = namespace.pathText(scope, path, &run.detail);
    run.has_detail = true;
    return error.NotFound;
}

// --- running ------------------------------------------------------------------------

/// `method` run with `args`, which stay the caller's: what it returned,
/// held by the caller - `.none` for nothing. An error ends it, said in
/// the log.
pub fn call(ab: *AcpiBase, method: *Node, args: []const Item) Error!Item {
    var run: Run = .{ .ab = ab };
    return callIn(&run, method, args);
}

/// `method` run with `args` as `call` runs it, from inside the evaluation
/// `outer` - for what the interpreter itself asks of the namespace while
/// it runs: the mutexes `outer` holds are its own.
pub fn callNested(outer: *Run, method: *Node, args: []const Item) Error!Item {
    var run: Run = .{ .ab = outer.ab, .owner = ownerOf(outer), .sync_level = outer.sync_level };
    return callIn(&run, method, args);
}

fn callIn(run: *Run, method: *Node, args: []const Item) Error!Item {
    defer run.deinit();
    const held = method.object orelse return error.Type;
    const body = switch (held.value) {
        .method => |body| body,
        else => return error.Type,
    };
    if (body.builtin != .none) return operators.builtin(run, args, body.builtin);
    try enter(run, method, body, args);
    loop(run) catch |err| {
        said(run, err);
        unwind(run, 0);
        return err;
    };
    sync.releaseAll(run);
    return run.result;
}

/// The code of a table being loaded, `reader` over it from its first
/// term, run at `scope`. What goes wrong is said, counted in `table` and
/// leaves out what it must; the rest is run.
pub fn runTable(ab: *AcpiBase, table: *load.Load, reader: Reader, scope: *Node) void {
    var run: Run = .{ .ab = ab, .load = table, .owner = table.owner };
    defer run.deinit();
    const frame = run.frames.push(ab) orelse {
        load.noMemory(table);
        return;
    };
    frame.* = .{ .reader = reader, .scope = scope, .method = null, .ops = 0, .blocks = 0, .temporaries = 0 };
    while (run.frames.count > 0) {
        loop(&run) catch |err| recover(&run, err);
    }
    sync.releaseAll(&run);
    release(ab, run.result);
}

/// Steps until the outermost frame has returned.
fn loop(run: *Run) Error!void {
    while (run.frames.count > 0) try step(run);
}

fn step(run: *Run) Error!void {
    const frame = run.frames.top().?;
    if (run.ops.count > frame.ops) {
        const op = run.ops.top().?;
        if (op.next < op.operands.len) return collect(run, frame, op);
        if (op.filling) return define.fill(run, frame, op);
        return execute(run, frame, op);
    }
    return statement(run, frame);
}

/// The frame between terms: a block ended, the body ended, or the next
/// term started.
fn statement(run: *Run, frame: *Frame) Error!void {
    if (run.blocks.count > frame.blocks) {
        const block = run.blocks.top().?;
        if (frame.reader.at >= block.end) return closeBlock(run, frame);
    }
    if (frame.reader.atEnd()) return returnFrom(run, .none);
    frame.statement_at = frame.reader.at;
    if (run.load) |table| {
        if (run.frames.count == 1 and !insideCode(run, frame) and isCode(frame.reader)) table.loaded.code += 1;
    }
    return startTerm(run, frame, .statement);
}

/// Whether the frame is inside code - an If, an Else, a While - rather
/// than only scopes.
fn insideCode(run: *const Run, frame: *const Frame) bool {
    var index = run.blocks.count;
    while (index > frame.blocks) {
        index -= 1;
        if (run.blocks.at(index).kind != .scope) return true;
    }
    return false;
}

/// Whether the term at `reader` is code rather than a definition.
fn isCode(reader: Reader) bool {
    if (reader.atName()) return true;
    const code = reader.peekOpcode() orelse return false;
    return !define.isDefinition(code);
}

/// The term at the reader started, as `want` wants it: worked out at
/// once where it is a constant, a local, an argument or a name, and put
/// on top as an op otherwise.
fn startTerm(run: *Run, frame: *Frame, want: Want) Error!void {
    const reader = &frame.reader;
    const start = reader.at;
    if (reader.atName()) return nameTerm(run, frame, want, start);
    const code = reader.opcode() orelse return error.Broken;
    switch (code) {
        opcodes.LOCAL0_OP...opcodes.LOCAL0_OP + 7 => {
            const index: u8 = @intCast(code - opcodes.LOCAL0_OP);
            return give(run, frame, want, switch (want) {
                .target, .cond => .{ .place = .{ .local = index } },
                else => valueOf(frame.locals[index]),
            });
        },
        opcodes.ARG0_OP...opcodes.ARG6_OP => {
            const index: u8 = @intCast(code - opcodes.ARG0_OP);
            return give(run, frame, want, switch (want) {
                .target, .cond => .{ .place = .{ .arg = index } },
                else => valueOf(frame.args[index]),
            });
        },
        aml.ZERO_OP => return give(run, frame, want, switch (want) {
            .target, .cond => .{ .place = .none },
            else => .{ .integer = 0 },
        }),
        aml.ONE_OP, aml.ONES_OP, aml.BYTE_PREFIX, aml.WORD_PREFIX, aml.DWORD_PREFIX, aml.QWORD_PREFIX, aml.REVISION_OP => {
            reader.at = start;
            const value = reader.constant(run.ab.integer_bits) orelse return error.Broken;
            return give(run, frame, want, .{ .integer = value });
        },
        aml.STRING_PREFIX => {
            const text = reader.string() orelse return error.Broken;
            const made = object.makeString(run.ab, text) orelse return error.NoMemory;
            return give(run, frame, want, .{ .object = made });
        },
        opcodes.DEBUG_OP => return give(run, frame, want, .{ .place = .debug }),
        else => {},
    }
    if (run.ops.count - frame.ops >= MOST_OPS) return error.Limit;
    const operands = operandsOf(code) orelse {
        reader.at = start;
        return error.Unknown;
    };
    const op = run.ops.push(run.ab) orelse return error.NoMemory;
    op.* = .{ .code = code, .start = start, .operands = operands };
}

/// The next element of a package started: a name among them is kept as
/// the name.
pub fn startElement(run: *Run, frame: *Frame) Error!void {
    return startTerm(run, frame, .element);
}

/// What a local or an argument holds, as an operand: its object, held
/// once more; nothing where nothing was stored in it.
fn valueOf(slot: ?*Object) Item {
    const held = slot orelse return .none;
    return .{ .object = object.retain(held) };
}

/// A name met where `want` wants a term.
fn nameTerm(run: *Run, frame: *Frame, want: Want, start: usize) Error!void {
    const reader = &frame.reader;
    const path = reader.name() orelse return error.Broken;
    switch (want) {
        .target, .cond => {
            const node = namespace.find(run.ab, frame.scope, path, .search) orelse {
                if (want == .cond) return give(run, frame, want, .{ .place = .missing });
                return notFound(run, frame.scope, path);
            };
            return give(run, frame, want, .{ .place = .{ .node = node } });
        },
        .element => {
            // A package's element that names something: kept as the name,
            // looked up when it is read.
            const held = object.make(run.ab, .{ .name = .{
                .scope = frame.scope,
                .path = reader.code[start..].ptr,
                .length = @intCast(reader.at - start),
            } }) orelse return error.NoMemory;
            _ = namespace.hold(frame.scope);
            return give(run, frame, want, .{ .object = held });
        },
        .term, .statement => {
            const node = try findName(run, frame, path);
            if (node.object) |held| switch (held.value) {
                .method => |method| return startCall(run, frame, node, method, start),
                else => {},
            };
            const value = try store.readNode(run, node);
            return give(run, frame, want, value);
        },
    }
}

/// The operands of a call, as many as the method takes.
const call_operands = [_]Operand{.term} ** 7;

fn startCall(run: *Run, frame: *Frame, node: *Node, method: object.Method, start: usize) Error!void {
    if (run.ops.count - frame.ops >= MOST_OPS) return error.Limit;
    const op = run.ops.push(run.ab) orelse return error.NoMemory;
    op.* = .{ .code = CALL, .start = start, .operands = call_operands[0..method.args()], .node = node };
}

/// `item` handed to whatever wanted it: the op on top's next operand, or
/// let go of where the frame is between terms.
fn give(run: *Run, frame: *Frame, want: Want, item: Item) Error!void {
    if (want == .statement or run.ops.count == frame.ops) {
        release(run.ab, item);
        return;
    }
    return deliver(run, frame, item);
}

/// `item`, a term's result, handed to the op on top as its next operand,
/// made what that operand is; let go of where the frame is between terms.
fn deliver(run: *Run, frame: *Frame, item: Item) Error!void {
    if (run.ops.count == frame.ops) {
        release(run.ab, item);
        return;
    }
    const parent = run.ops.top().?;
    if (parent.filling) return define.element(run, parent, item);
    const operand = parent.operands[parent.next];
    parent.items[parent.next] = switch (operand) {
        .target, .cond => placeOf(run, item) catch |err| {
            release(run.ab, item);
            return err;
        },
        else => item,
    };
    parent.next += 1;
}

/// A term's result where a place is wanted: a reference refers to one,
/// another object is stored into where it is.
fn placeOf(run: *Run, item: Item) Error!Item {
    _ = run;
    return switch (item) {
        .place => item,
        .object => |held| switch (held.value) {
            .reference => .{ .place = .{ .reference = held } },
            else => .{ .place = .{ .object = held } },
        },
        .none => .{ .place = .none },
        else => error.Type,
    };
}

/// An operand of the op on top read.
fn collect(run: *Run, frame: *Frame, op: *Op) Error!void {
    const reader = &frame.reader;
    const index = op.next;
    switch (op.operands[index]) {
        .byte => op.items[index] = .{ .integer = reader.number(1) orelse return error.Broken },
        .word => op.items[index] = .{ .integer = reader.number(2) orelse return error.Broken },
        .dword => op.items[index] = .{ .integer = reader.number(4) orelse return error.Broken },
        .name => op.items[index] = .{ .path = reader.name() orelse return error.Broken },
        .pkg => {
            op.outer_end = reader.end;
            op.end = reader.pkgEnd() orelse return error.Broken;
            reader.end = op.end;
        },
        .term => return startTerm(run, frame, .term),
        .target => return startTerm(run, frame, .target),
        .cond => return startTerm(run, frame, .cond),
    }
    op.next += 1;
}

/// The op on top, with all its operands, done.
fn execute(run: *Run, frame: *Frame, op: *Op) Error!void {
    switch (op.code) {
        CALL => return callOp(run, frame, op),
        opcodes.IF_OP => return ifOp(run, frame, op),
        opcodes.ELSE_OP => {
            // An Else that follows no If: its body is not run.
            frame.reader.at = op.end;
            return finish(run, frame, .none);
        },
        opcodes.WHILE_OP => return whileOp(run, frame, op),
        BREAK_OP, CONTINUE_OP => return leaveLoop(run, frame, op.code == CONTINUE_OP),
        RETURN_OP => {
            const result = try returned(run, op.items[0]);
            popOp(run, frame);
            return returnFrom(run, result);
        },
        NOOP_OP, BREAKPOINT_OP => return finish(run, frame, .none),
        else => {},
    }
    if (define.isDefinition(op.code) or op.code == opcodes.BUFFER_OP or op.code == opcodes.PACKAGE_OP or op.code == opcodes.VAR_PACKAGE_OP)
        return define.execute(run, frame, op);
    const result = try operators.execute(run, frame, op);
    return finish(run, frame, result);
}

/// What Return hands back: the value, a copy of it where another holds
/// it too - a name's, a local's, an argument's -, so that what the caller
/// does to it changes nothing of the method's.
fn returned(run: *Run, item: Item) Error!Item {
    const held = switch (item) {
        .object => |held| held,
        .place => |place| switch (place) {
            .debug => return error.Type,
            else => return .none,
        },
        else => return item,
    };
    if (held.references == 1) return .{ .object = object.retain(held) };
    return .{ .object = try convert.copy(run, held) };
}

const RETURN_OP: u16 = 0xA4;
const BREAK_OP: u16 = 0xA5;
const CONTINUE_OP: u16 = 0x9F;
const NOOP_OP: u16 = 0xA3;
const BREAKPOINT_OP: u16 = 0xCC;

/// The op on top let go of: its operands, and the package it was in left
/// - the reader at its end, the end outside it back.
fn popOp(run: *Run, frame: *Frame) void {
    const op = run.ops.top().?;
    for (op.items) |item| release(run.ab, item);
    if (op.end != 0) {
        frame.reader.at = op.end;
        frame.reader.end = op.outer_end;
    }
    run.ops.pop();
}

/// The op on top done with `result`, which goes to the op below it.
pub fn finish(run: *Run, frame: *Frame, result: Item) Error!void {
    popOp(run, frame);
    return deliver(run, frame, result);
}

/// The op on top, which holds a package, done by running its contents
/// as a block of `kind`: the op let go of, the reader left inside.
pub fn enterBlock(run: *Run, frame: *Frame, kind: Block.Kind, scope: ?*Node) Error!void {
    const op = run.ops.top().?;
    const block: Block = .{ .kind = kind, .start = op.start, .end = op.end, .outer_end = op.outer_end, .scope = if (scope != null) frame.scope else null };
    for (op.items) |item| release(run.ab, item);
    run.ops.pop();
    const pushed = run.blocks.push(run.ab) orelse return error.NoMemory;
    pushed.* = block;
    if (scope) |inside| frame.scope = inside;
}

fn ifOp(run: *Run, frame: *Frame, op: *Op) Error!void {
    const taken = try operators.truth(run, op.items[1]);
    if (taken) return enterBlock(run, frame, .taken, null);
    popOp(run, frame);
    return elseAfter(run, frame, true);
}

/// The Else after an If, where there is one: run where `run_it`, stepped
/// over otherwise.
fn elseAfter(run: *Run, frame: *Frame, run_it: bool) Error!void {
    const reader = &frame.reader;
    if (reader.peekOpcode() != opcodes.ELSE_OP) return;
    const start = reader.at;
    _ = reader.opcode();
    const outer_end = reader.end;
    const end = reader.pkgEnd() orelse {
        reader.at = start;
        return error.Broken;
    };
    if (!run_it) {
        reader.at = end;
        return;
    }
    reader.end = end;
    const pushed = run.blocks.push(run.ab) orelse return error.NoMemory;
    pushed.* = .{ .kind = .other, .end = end, .outer_end = outer_end };
}

fn whileOp(run: *Run, frame: *Frame, op: *Op) Error!void {
    const going = try operators.truth(run, op.items[1]);
    if (!going) {
        if (frame.loop_at == op.start) frame.loop_at = NO_LOOP;
        popOp(run, frame);
        return;
    }
    const now = run.ab.machine.time(run.ab);
    if (frame.loop_at != op.start) {
        frame.loop_at = op.start;
        frame.loop_deadline = now + MOST_LOOP;
    } else if (now > frame.loop_deadline) {
        return error.Limit;
    }
    return enterBlock(run, frame, .loop, null);
}

/// The innermost While left (Break), or run again (Continue).
fn leaveLoop(run: *Run, frame: *Frame, again: bool) Error!void {
    popOp(run, frame);
    while (run.blocks.count > frame.blocks) {
        const block = run.blocks.top().?.*;
        run.blocks.pop();
        if (block.scope) |outside| frame.scope = outside;
        if (block.kind != .loop) continue;
        frame.reader.end = block.outer_end;
        frame.reader.at = if (again) block.start else block.end;
        if (!again) frame.loop_at = NO_LOOP;
        return;
    }
    // Break and Continue outside any While do nothing.
}

/// The block on top, whose end the reader has reached, left.
fn closeBlock(run: *Run, frame: *Frame) Error!void {
    const block = run.blocks.top().?.*;
    run.blocks.pop();
    frame.reader.at = block.end;
    frame.reader.end = block.outer_end;
    switch (block.kind) {
        .scope => frame.scope = block.scope.?,
        .taken => return elseAfter(run, frame, false),
        .other => {},
        .loop => frame.reader.at = block.start,
    }
}

// --- methods ------------------------------------------------------------------------

fn callOp(run: *Run, frame: *Frame, op: *Op) Error!void {
    _ = frame;
    const node = op.node.?;
    const held = node.object orelse return error.Type;
    const method = switch (held.value) {
        .method => |method| method,
        else => return error.Type,
    };
    if (method.builtin != .none) {
        const result = try operators.builtin(run, op.items[0..method.args()], method.builtin);
        return finish(run, run.frames.top().?, result);
    }
    if (run.frames.count >= MOST_CALLS) return error.Limit;
    op.calling = true;
    return enter(run, node, method, op.items[0..method.args()]);
}

/// `method` (the node `node`) entered with `args`, which stay the
/// caller's: a frame on top, holding its arguments.
fn enter(run: *Run, node: *Node, method: object.Method, args: []const Item) Error!void {
    var frame: Frame = .{
        .reader = Reader.of((method.code orelse return error.Type)[0..method.length], 0),
        .scope = node,
        .method = node,
        .ops = run.ops.count,
        .blocks = run.blocks.count,
        .temporaries = run.temporaries.count,
    };
    if (method.flags & object.METHOD_SERIALIZED != 0) frame.serialized = try sync.enterSerialized(run, node);
    for (args, 0..) |arg, index| {
        frame.args[index] = argumentOf(run, arg) catch |err| {
            for (frame.args[0..index]) |done| object.release(run.ab, done);
            if (frame.serialized) sync.leaveSerialized(run, node);
            return err;
        };
    }
    const pushed = run.frames.push(run.ab) orelse {
        for (frame.args) |held| object.release(run.ab, held);
        if (frame.serialized) sync.leaveSerialized(run, node);
        return error.NoMemory;
    };
    pushed.* = frame;
}

/// An argument as a method holds it: an integer the method's own; a
/// string, a buffer, a package the caller's, held once more - what the
/// method does to its contents the caller sees, and a store to the
/// argument replaces it.
fn argumentOf(run: *Run, arg: Item) Error!?*Object {
    return switch (arg) {
        .none => null,
        .integer => |value| object.makeInteger(run.ab, value) orelse error.NoMemory,
        .object => |held| switch (held.value) {
            .integer => |value| object.makeInteger(run.ab, value) orelse error.NoMemory,
            else => object.retain(held),
        },
        else => error.Type,
    };
}

/// The method on top returned `result`: its frame let go of, and the
/// result handed to the call that ran it - or kept as the run's where it
/// was the outermost.
fn returnFrom(run: *Run, result: Item) Error!void {
    const frame = run.frames.top().?;
    leaveFrame(run, frame);
    run.frames.pop();
    const caller = run.frames.top() orelse {
        run.result = result;
        return;
    };
    const op = run.ops.top().?;
    op.calling = false;
    return finish(run, caller, result);
}

/// What the frame on top holds let go of: its ops and blocks, its locals
/// and arguments, the names it made and its serialized method's mutex.
fn leaveFrame(run: *Run, frame: *Frame) void {
    while (run.ops.count > frame.ops) {
        const op = run.ops.top().?;
        for (op.items) |item| release(run.ab, item);
        run.ops.pop();
    }
    run.blocks.count = frame.blocks;
    for (frame.locals) |held| object.release(run.ab, held);
    for (frame.args) |held| object.release(run.ab, held);
    frame.locals = [_]?*Object{null} ** 8;
    frame.args = [_]?*Object{null} ** 7;
    while (run.temporaries.count > frame.temporaries) {
        const node = run.temporaries.top().?.*;
        run.temporaries.pop();
        region.regionGone(run, node);
        namespace.remove(run.ab, node);
    }
    if (frame.serialized) sync.leaveSerialized(run, frame.method.?);
    frame.serialized = false;
}

/// Every frame above `bottom` left, the mutexes the run holds given back.
fn unwind(run: *Run, bottom: u32) void {
    while (run.frames.count > bottom) {
        leaveFrame(run, run.frames.top().?);
        run.frames.pop();
    }
    if (bottom == 0) sync.releaseAll(run);
}

// --- what goes wrong ------------------------------------------------------------------

/// An error said in the log: the method, where in it and why.
fn said(run: *Run, err: Error) void {
    const frame = run.frames.top() orelse return;
    var where: [namespace.PATH_ROOM]u8 = undefined;
    if (frame.method) |method| {
        _ = namespace.pathOf(method, &where);
    } else {
        const text = "the table's own code";
        @memcpy(where[0..text.len], text);
        where[text.len] = 0;
    }
    const at: u32 = @intCast(if (run.ops.count > frame.ops) run.ops.top().?.start else frame.reader.at);
    const detail: [*:0]const u8 = if (run.has_detail) @ptrCast(&run.detail) else "";
    machine.log(run.ab, exec.LOG_ERROR, "%s at 0x%x: %s%s%s\n", .{
        @as([*:0]const u8, @ptrCast(&where)), at, reason(err), @as([*:0]const u8, if (run.has_detail) " " else ""), detail,
    });
    run.has_detail = false;
}

/// What an error is, as the log says it.
pub fn reason(err: Error) [*:0]const u8 {
    return switch (err) {
        error.NotFound => "not there:",
        error.Type => "an operand of the wrong kind",
        error.Range => "an index past the end",
        error.NoMemory => "no memory",
        error.Unknown => "an opcode not known",
        error.Broken => "bytes that are no term",
        error.Limit => "a limit reached",
        error.Exists => "defined again:",
        error.Uninitialized => "a value read where none was stored",
        error.DivideByZero => "a division by zero",
        error.Fatal => "the firmware's Fatal",
        error.Mutex => "a mutex out of order",
        error.Access => "a field or a region that cannot be reached",
    };
}

/// An error while a table loads: what it is about said and counted, the
/// methods it was in left, and the term it was in - or, where nothing
/// says where that ends, the rest of its list - left out.
fn recover(run: *Run, err: Error) void {
    const table = run.load.?;
    // The method a term outside any method called, where it went wrong
    // in one: the call ends, said as any method's error is.
    if (run.frames.count > 1) {
        said(run, err);
        unwind(run, 1);
    }
    sync.releaseAll(run);
    const frame = run.frames.at(0);
    const start = frame.statement_at;
    while (run.ops.count > 0) {
        const op = run.ops.top().?;
        for (op.items) |item| release(run.ab, item);
        if (op.end != 0) frame.reader.end = op.outer_end;
        run.ops.pop();
    }
    const scope = frame.scope;
    var fault: opcodes.Fault = .{};
    const left: load.Left = left: {
        // The term's own end, where the bytes say it.
        frame.reader.at = start;
        var probe = frame.reader;
        if (opcodes.skip(run.ab, &probe, scope, &fault)) {
            frame.reader.at = probe.at;
            break :left .term;
        }
        // The rest of the list: to the end of the block it is in, or of
        // the table.
        frame.reader.at = frame.reader.end;
        break :left .rest;
    };
    load.failed(table, err, start, scope, left, run.has_detail, &run.detail);
    run.has_detail = false;
}

// --- the operands of each term ------------------------------------------------------

/// What follows `code`, operand by operand, as the interpreter reads it;
/// null for a code it does not know. A term's contents past its operands
/// - a body, a buffer's bytes, a package's elements, a field's list - are
/// its handler's.
pub fn operandsOf(code: u16) ?[]const Operand {
    return switch (code) {
        opcodes.ALIAS_OP => &.{ .name, .name },
        opcodes.NAME_OP => &.{ .name, .term },
        opcodes.SCOPE_OP => &.{ .pkg, .name },
        opcodes.BUFFER_OP => &.{ .pkg, .term },
        opcodes.PACKAGE_OP => &.{ .pkg, .byte },
        opcodes.VAR_PACKAGE_OP => &.{ .pkg, .term },
        opcodes.METHOD_OP => &.{ .pkg, .name, .byte },
        opcodes.EXTERNAL_OP => &.{ .name, .byte, .byte },
        0x70 => &.{ .term, .target }, // Store
        0x71 => &.{.target}, // RefOf
        0x72, 0x73, 0x74, 0x77, 0x79...0x7F, 0x84, 0x85 => &.{ .term, .term, .target }, // Add, Concatenate, Subtract, Multiply, ShiftLeft to Xor, ConcatenateResTemplate, Mod
        0x75, 0x76 => &.{.target}, // Increment, Decrement
        0x78 => &.{ .term, .term, .target, .target }, // Divide
        0x80, 0x81, 0x82 => &.{ .term, .target }, // Not, FindSetLeftBit, FindSetRightBit
        0x83 => &.{.term}, // DerefOf
        0x86 => &.{ .target, .term }, // Notify
        0x87 => &.{.target}, // SizeOf
        0x88 => &.{ .term, .term, .target }, // Index
        0x89 => &.{ .term, .byte, .term, .byte, .term, .term }, // Match
        opcodes.CREATE_DWORD_FIELD_OP,
        opcodes.CREATE_WORD_FIELD_OP,
        opcodes.CREATE_BYTE_FIELD_OP,
        opcodes.CREATE_BIT_FIELD_OP,
        opcodes.CREATE_QWORD_FIELD_OP,
        => &.{ .term, .term, .name },
        0x8E => &.{.target}, // ObjectType
        0x90, 0x91, 0x93, 0x94, 0x95 => &.{ .term, .term }, // LAnd, LOr, LEqual, LGreater, LLess
        0x92 => &.{.term}, // LNot
        0x96, 0x97, 0x98, 0x99 => &.{ .term, .target }, // ToBuffer, ToDecimalString, ToHexString, ToInteger
        0x9C => &.{ .term, .term, .target }, // ToString
        0x9D => &.{ .term, .target }, // CopyObject
        0x9E => &.{ .term, .term, .term, .target }, // Mid
        CONTINUE_OP, NOOP_OP, BREAK_OP, BREAKPOINT_OP => &.{},
        opcodes.IF_OP, opcodes.WHILE_OP => &.{ .pkg, .term },
        opcodes.ELSE_OP => &.{.pkg},
        RETURN_OP => &.{.term},
        opcodes.MUTEX_OP => &.{ .name, .byte },
        opcodes.EVENT_OP => &.{.name},
        aml.EXT | 0x12 => &.{ .cond, .target }, // CondRefOf
        opcodes.CREATE_FIELD_OP => &.{ .term, .term, .term, .name },
        aml.EXT | 0x1F => &.{ .term, .term, .term, .term, .term, .term }, // LoadTable
        aml.EXT | 0x20 => &.{ .name, .target }, // Load
        aml.EXT | 0x21, aml.EXT | 0x22 => &.{.term}, // Stall, Sleep
        aml.EXT | 0x23 => &.{ .target, .word }, // Acquire
        aml.EXT | 0x24, aml.EXT | 0x26, aml.EXT | 0x27 => &.{.target}, // Signal, Reset, Release
        aml.EXT | 0x25 => &.{ .target, .term }, // Wait
        aml.EXT | 0x28, aml.EXT | 0x29 => &.{ .term, .target }, // FromBCD, ToBCD
        aml.EXT | 0x2A => &.{.target}, // Unload
        aml.EXT | 0x33 => &.{}, // Timer
        aml.EXT | 0x32 => &.{ .byte, .dword, .term }, // Fatal
        opcodes.OP_REGION_OP => &.{ .name, .byte, .term, .term },
        opcodes.FIELD_OP => &.{ .pkg, .name },
        opcodes.DEVICE_OP, opcodes.THERMAL_ZONE_OP => &.{ .pkg, .name },
        opcodes.PROCESSOR_OP => &.{ .pkg, .name, .byte, .dword, .byte },
        opcodes.POWER_RES_OP => &.{ .pkg, .name, .byte, .word },
        opcodes.INDEX_FIELD_OP => &.{ .pkg, .name, .name },
        opcodes.BANK_FIELD_OP => &.{ .pkg, .name, .name, .term },
        opcodes.DATA_REGION_OP => &.{ .name, .term, .term, .term },
        else => null,
    };
}
