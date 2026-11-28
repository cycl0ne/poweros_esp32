// SPDX-License-Identifier: MPL-2.0
//! Mutexes, events and waiting: what the bytecode's Acquire, Release,
//! Signal, Wait, Reset, Sleep and Stall do, and the mutex a serialized
//! method is run under.
//!
//! **Mutexes** are held by an evaluation (`Run`; a nested one, as a
//! field's PCI address is worked out, is the same evaluation), as many
//! times over as it took one. Each has a sync level, 0 to 15. Acquire of
//! one below the level the evaluation holds is said in the log and
//! answered as a time run out; taking one another evaluation holds waits,
//! for as long as the term says, the namespace given up meanwhile. While
//! it holds mutexes the evaluation's level is that of the last it took
//! and still holds. Release of one it does not hold, or of one whose
//! level is not the level it holds, is said and does nothing. A
//! serialized method holds its own mutex while it runs - at the level
//! the method declares, and taken only below that level - once however
//! often it calls itself. An evaluation that ends gives back every mutex
//! it still holds.
//!
//! **Events** count how often they were signalled: Wait takes one
//! signal, or waits for one for as long as the term says, and Reset
//! forgets them.
//!
//! A wait for a mutex or an event looks again every millisecond. Sleep
//! is at most two seconds, Stall at most 255 microseconds, each said in
//! the log where it asked for more.

const sdk = @import("sdk");
const exec = sdk.exec;
const machine = @import("../machine/_machine.zig");
const namespace = @import("../namespace/_namespace.zig");
const Node = namespace.Node;
const object = @import("../object/_object.zig");
const Object = object.Object;
const interpreter = @import("_interpreter.zig");
const Run = interpreter.Run;
const Error = interpreter.Error;

/// What Acquire's and Wait's time limit is for none: it waits for good.
pub const FOREVER: u64 = 0xFFFF;

/// The clock's units in a millisecond.
const MILLISECOND = 10_000;

/// The deepest a mutex may be taken over by the evaluation holding it.
const MOST_DEPTH = 0xFFFF;

/// `mutex` taken by the run, waiting at most `timeout_ms` - FOREVER for
/// good - where another holds it: false where it was taken, true where
/// the time ran out. Taken again by the run that holds it, it counts.
pub fn take(run: *Run, mutex: *object.Mutex, timeout_ms: u64) Error!bool {
    const me = interpreter.ownerOf(run);
    if (mutex.owner == me) {
        if (mutex.depth == MOST_DEPTH) return true;
        mutex.depth += 1;
        return false;
    }
    if (mutex.owner != null) {
        const start = run.ab.machine.time(run.ab);
        while (mutex.owner != null) {
            if (timeout_ms != FOREVER and run.ab.machine.time(run.ab) - start >= timeout_ms * MILLISECOND) return true;
            run.ab.machine.sleep(run.ab, 1);
        }
    }
    mutex.owner = me;
    mutex.depth = 1;
    return false;
}

/// `mutex` given back once by the run; let go of where that was the last
/// time it took it. One it does not hold is left alone.
pub fn give(run: *Run, mutex: *object.Mutex) void {
    if (mutex.owner != interpreter.ownerOf(run) or mutex.depth == 0) return;
    mutex.depth -= 1;
    if (mutex.depth == 0) mutex.owner = null;
}

/// The mutex `held` is: a mutex's own, or a serialized method's.
fn lockOf(held: *Object) ?*object.Mutex {
    return switch (held.value) {
        .mutex => |*mutex| mutex,
        .method => |*method| {
            method.serial.sync_level = method.syncLevel();
            return &method.serial;
        },
        else => null,
    };
}

/// The level of the mutex the run took last and still holds; 0 for none.
fn levelNow(run: *const Run) u8 {
    const top = run.mutexes.top() orelse return 0;
    const mutex = lockOf(top.*) orelse return 0;
    return mutex.sync_level;
}

/// `held`, a mutex the run just took the first time, kept on its list.
fn keep(run: *Run, held: *Object, mutex: *object.Mutex) Error!void {
    const kept = run.mutexes.push(run.ab) orelse {
        give(run, mutex);
        return error.NoMemory;
    };
    kept.* = object.retain(held);
    run.sync_level = mutex.sync_level;
}

/// Acquire: `held`, a mutex, taken - false - or not: the time ran out, or
/// its level is below the run's - true.
pub fn acquire(run: *Run, held: *Object, timeout_ms: u64) Error!bool {
    const mutex = switch (held.value) {
        .mutex => |*mutex| mutex,
        else => return error.Type,
    };
    if (mutex.owner != interpreter.ownerOf(run) and mutex.sync_level < run.sync_level) {
        machine.log(run.ab, exec.LOG_WARNING, "a mutex of level %u taken while one of level %u is held: not taken\n", .{
            @as(u32, mutex.sync_level), @as(u32, run.sync_level),
        });
        return true;
    }
    if (try take(run, mutex, @min(timeout_ms, FOREVER))) return true;
    if (mutex.depth == 1) try keep(run, held, mutex);
    return false;
}

/// Release: `held`, a mutex the run holds, given back once (see the
/// file's header).
pub fn release(run: *Run, held: *Object) Error!void {
    const mutex = switch (held.value) {
        .mutex => |*mutex| mutex,
        else => return error.Type,
    };
    if (mutex.owner != interpreter.ownerOf(run)) {
        machine.log(run.ab, exec.LOG_WARNING, "a mutex released that is not held: left alone\n", .{});
        return;
    }
    if (mutex.depth == 1 and mutex.sync_level != levelNow(run)) {
        machine.log(run.ab, exec.LOG_WARNING, "a mutex of level %u released while one of level %u was taken after it: left alone\n", .{
            @as(u32, mutex.sync_level), @as(u32, levelNow(run)),
        });
        return;
    }
    give(run, mutex);
    if (mutex.depth != 0) return;
    forget(run, held);
}

/// `held` taken off the list of mutexes the run holds, and the run's
/// level that of the last one left.
fn forget(run: *Run, held: *Object) void {
    var index: u32 = run.mutexes.count;
    while (index > 0) {
        index -= 1;
        if (run.mutexes.at(index).* != held) continue;
        var after = index;
        while (after + 1 < run.mutexes.count) : (after += 1) run.mutexes.at(after).* = run.mutexes.at(after + 1).*;
        run.mutexes.pop();
        object.release(run.ab, held);
        break;
    }
    run.sync_level = levelNow(run);
}

/// Every mutex the run still holds given back, the last taken first.
pub fn releaseAll(run: *Run) void {
    const me = interpreter.ownerOf(run);
    while (run.mutexes.top()) |top| {
        const held = top.*;
        run.mutexes.pop();
        if (lockOf(held)) |mutex| {
            if (mutex.owner == me) {
                mutex.owner = null;
                mutex.depth = 0;
            }
        }
        object.release(run.ab, held);
    }
    run.sync_level = 0;
}

/// A serialized method, `node`, about to run: its mutex taken - waiting
/// for good where another evaluation runs it - and true; false where the
/// run holds it already, as a method calling itself does. Called at a
/// level above its own, it is an error.
pub fn enterSerialized(run: *Run, node: *Node) Error!bool {
    const held = node.object orelse return error.Type;
    const mutex = lockOf(held) orelse return error.Type;
    if (mutex.owner == interpreter.ownerOf(run)) return false;
    if (run.sync_level > mutex.sync_level) return error.Mutex;
    _ = try take(run, mutex, FOREVER);
    try keep(run, held, mutex);
    return true;
}

/// A serialized method that took its mutex returned, or was left by an
/// error: the mutex given back.
pub fn leaveSerialized(run: *Run, node: *Node) void {
    const held = node.object orelse return;
    const mutex = lockOf(held) orelse return;
    if (mutex.owner != interpreter.ownerOf(run)) return;
    mutex.owner = null;
    mutex.depth = 0;
    forget(run, held);
}

/// Signal: one more signal for `held`, an event.
pub fn signal(held: *Object) Error!void {
    switch (held.value) {
        .event => |*event| event.pending +|= 1,
        else => return error.Type,
    }
}

/// Reset: `held`'s signals forgotten.
pub fn reset(held: *Object) Error!void {
    switch (held.value) {
        .event => |*event| event.pending = 0,
        else => return error.Type,
    }
}

/// Wait: one of `held`'s signals taken - false - waiting at most
/// `timeout_ms` for one - true where the time ran out first.
pub fn wait(run: *Run, held: *Object, timeout_ms: u64) Error!bool {
    const event = switch (held.value) {
        .event => |*event| event,
        else => return error.Type,
    };
    const limit: u64 = @min(timeout_ms, FOREVER);
    const start = run.ab.machine.time(run.ab);
    while (event.pending == 0) {
        if (limit != FOREVER and run.ab.machine.time(run.ab) - start >= limit * MILLISECOND) return true;
        run.ab.machine.sleep(run.ab, 1);
    }
    event.pending -= 1;
    return false;
}

/// The longest Sleep, in milliseconds, and the longest Stall, in
/// microseconds.
pub const MOST_SLEEP = 2000;
pub const MOST_STALL = 255;

/// Sleep: `milliseconds` waited for, the namespace given up meanwhile.
pub fn sleep(run: *Run, milliseconds: u64) void {
    if (milliseconds > MOST_SLEEP) {
        machine.log(run.ab, exec.LOG_DEBUG, "Sleep (%lu) is longer than a sleep may be: two seconds slept\n", .{milliseconds});
    }
    run.ab.machine.sleep(run.ab, @intCast(@min(milliseconds, MOST_SLEEP)));
}

/// Stall: `microseconds` waited for on the processor.
pub fn stall(run: *Run, microseconds: u64) void {
    if (microseconds > MOST_STALL) {
        machine.log(run.ab, exec.LOG_DEBUG, "Stall (%lu) is longer than a stall may be: 255 microseconds stalled\n", .{microseconds});
    }
    run.ab.machine.stall(run.ab, @intCast(@min(microseconds, MOST_STALL)));
}
