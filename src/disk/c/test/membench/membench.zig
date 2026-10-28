// SPDX-License-Identifier: MIT
//! MemBench: how fast exec's AllocVec and FreeVec are, and how that holds
//! up when the memory is cut up. Built against the SDK only.
//!
//!   MemBench TEST/K,STREAM/K/N,ROUNDS/K/N
//!
//!   MemBench                   every test
//!   MemBench TEST stream       the streams only
//!   MemBench STREAM 64         ... of 64 MiB each
//!
//! Each test is timed as a whole and given as the time per call:
//!
//! - **small**: ROUNDS (100000) pairs, a block of 16 to 256 bytes taken
//!   and given back at once.
//! - **held**: 10000 blocks of 16 to 1024 bytes taken, then given back in
//!   a random order.
//! - **mixed**: ROUNDS rounds over 1000 blocks of 16 bytes to 64 KiB: one,
//!   chosen at random, given back and taken again at another size.
//! - **large**: 1000 pairs of 1 MiB, and 100 of 64 MiB.
//! - **stream**: what the RAM: disk did with a file up to ram-handler 1.4:
//!   STREAM MiB (200) in blocks of 1 KiB - 1032 bytes each, with their
//!   link - kept, then all given back.
//!   First alone. Then beside a neighbour that takes a block of 4 KiB
//!   every 38th of the stream's and gives them back 64 at a time, as posfs
//!   did with its buffers while PacketCapture wrote. Then once more, that
//!   stream kept, with no neighbour. A neighbour's block given back between
//!   the stream's is filled by three of them and a remainder that fits
//!   none, and every later block is looked for past all of those.
//!
//! The sizes are each power of two as likely as the next. A stream is cut
//! to a quarter of the largest free block. What MemBench measures is time
//! only: how many chunks each call walked needs counters in exec. Ctrl-C
//! stops it, and what it took is given back.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const TimerBase = sdk.interface.timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "MemBench";
const VERSION_STRING = "\x00$VER: MemBench 1.0 (28.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TEST/K,STREAM/K/N,ROUNDS/K/N";
const arg_test = 0;
const arg_stream = 1;
const arg_rounds = 2;

const Test = enum { small, held, mixed, large, stream };

const default_stream_mib: u32 = 200;
const default_rounds: u32 = 100_000;
const held_blocks = 10_000;
const mixed_blocks = 1000;
/// A block of ram-handler 1.4: its link and 1 KiB of the file.
const stream_block = 1032;
const stream_data = 1024;
/// The neighbour beside a stream: a block of 4 KiB every
/// `neighbour_every` of the stream's, given back `neighbour_batch` at a
/// time.
const neighbour_block = 4096;
const neighbour_every = 38;
const neighbour_batch = 64;

const Run = struct {
    sys: *ExecBase,
    dl: *DosBase,
    timer_base: *TimerBase,
    random: u64 = 0x2545_F491_4F6C_DD1D,
    broken: bool = false,

    fn take(run: *Run, bytes: usize) ?*anyopaque {
        return run.sys.AllocVec(bytes, exec.MEMF_ANY);
    }

    fn give(run: *Run, memory: ?*anyopaque) void {
        run.sys.FreeVec(memory);
    }

    /// Ctrl-C, looked at every 1024th time it is asked.
    fn stopped(run: *Run, count: usize) bool {
        if (run.broken) return true;
        if (count % 1024 != 0 or run.dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) return false;
        _ = run.dl.PutStr("***Break\n");
        run.broken = true;
        return true;
    }

    fn next(run: *Run) u64 {
        run.random ^= run.random << 13;
        run.random ^= run.random >> 7;
        run.random ^= run.random << 17;
        return run.random;
    }

    /// From `least` to `most` (powers of two), each power as likely.
    fn size(run: *Run, comptime least: u32, comptime most: u32) u32 {
        const low = std.math.log2_int(u32, least);
        const high = std.math.log2_int(u32, most);
        const power: u5 = @intCast(low + run.next() % (high - low));
        const base = @as(u32, 1) << power;
        return base + @as(u32, @intCast(run.next() % base));
    }

    /// The E-clock in nanoseconds.
    fn now(run: *Run) u64 {
        var value: timer.EClockVal = .{};
        const rate = run.timer_base.ReadEClock(&value);
        const count = value.toTicks();
        return count / rate * 1_000_000_000 + count % rate * 1_000_000_000 / rate;
    }

    /// `what`: `calls` calls in `nanos`.
    fn report(run: *Run, what: [*:0]const u8, calls: u64, nanos: u64) void {
        const each = nanos * 10 / @max(calls, 1);
        _ = Printf(run.dl, "  %-44s %8lu calls %6lu.%03lu ms %6lu.%lu ns each\n", .{ what, calls, nanos / 1_000_000, nanos / 1000 % 1000, each / 10, each % 10 });
    }
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    var only: ?Test = null;
    if (argv[arg_test] != 0) {
        const name = std.mem.span(@as([*:0]const u8, @ptrFromInt(argv[arg_test])));
        only = for (std.enums.values(Test)) |candidate| {
            if (std.ascii.eqlIgnoreCase(name, @tagName(candidate))) break candidate;
        } else {
            _ = Printf(dl, "%s: no test %s: small, held, mixed, large or stream\n", .{ COMMAND_NAME, name.ptr });
            return dos.RETURN_ERROR;
        };
    }
    const rounds = @max(number(argv[arg_rounds], default_rounds), 1);
    const largest = sys.AvailMem(exec.MEMF_ANY | exec.MEMF_LARGEST);
    const stream_bytes = @min(@as(usize, number(argv[arg_stream], default_stream_mib)) << 20, largest / 4);

    var clock: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&clock.node);
    var run = Run{ .sys = sys, .dl = dl, .timer_base = @ptrCast(@alignCast(clock.node.device.?)) };

    _ = Printf(dl, "%zu KiB free, the largest block %zu KiB\n", .{ sys.AvailMem(exec.MEMF_ANY) >> 10, largest >> 10 });
    for (std.enums.values(Test)) |which| {
        if (only != null and only.? != which) continue;
        const result = switch (which) {
            .small => small(&run, rounds),
            .held => held(&run),
            .mixed => mixed(&run, rounds),
            .large => large(&run),
            .stream => streams(&run, stream_bytes / stream_data),
        };
        if (result != dos.RETURN_OK) return result;
        if (run.broken) return dos.RETURN_WARN;
    }
    return dos.RETURN_OK;
}

// --- small, held, mixed, large ------------------------------------------------------------

fn small(run: *Run, rounds: u32) i32 {
    _ = run.dl.PutStr("small: a block taken and given back at once\n");
    var count: u32 = 0;
    const started = run.now();
    while (count < rounds and !run.stopped(count)) : (count += 1) {
        const block = run.take(run.size(16, 256)) orelse return noMemory(run, 256);
        run.give(block);
    }
    run.report("pairs of 16 to 256 bytes", @as(u64, count) * 2, run.now() - started);
    return dos.RETURN_OK;
}

fn held(run: *Run) i32 {
    _ = run.dl.PutStr("held: blocks taken, then given back in a random order\n");
    const table = takeTable(run, held_blocks) orelse return noMemory(run, held_blocks * @sizeOf(?*anyopaque));
    defer giveTable(run, table);
    var count: usize = 0;
    var started = run.now();
    while (count < table.len and !run.stopped(count)) : (count += 1) {
        table[count] = run.take(run.size(16, 1024)) orelse break;
    }
    run.report("taken, 16 to 1024 bytes", count, run.now() - started);
    // Shuffled before the clock runs again.
    var index = count;
    while (index > 1) {
        index -= 1;
        const other: usize = @intCast(run.next() % (index + 1));
        std.mem.swap(?*anyopaque, &table[index], &table[other]);
    }
    started = run.now();
    for (table[0..count]) |block| run.give(block);
    run.report("given back", count, run.now() - started);
    if (count < table.len and !run.broken) return noMemory(run, 1024);
    return dos.RETURN_OK;
}

fn mixed(run: *Run, rounds: u32) i32 {
    _ = run.dl.PutStr("mixed: one block of many given back and taken again\n");
    const table = takeTable(run, mixed_blocks) orelse return noMemory(run, mixed_blocks * @sizeOf(?*anyopaque));
    defer giveTable(run, table);
    defer for (table) |block| run.give(block);
    for (table) |*slot| slot.* = run.take(run.size(16, 64 * 1024));
    var count: u32 = 0;
    const started = run.now();
    while (count < rounds and !run.stopped(count)) : (count += 1) {
        const slot = &table[@intCast(run.next() % table.len)];
        run.give(slot.*);
        slot.* = run.take(run.size(16, 64 * 1024));
    }
    const nanos = run.now() - started;
    run.report("rounds over 1000 blocks of 16 B to 64 KiB", @as(u64, count) * 2, nanos);
    return dos.RETURN_OK;
}

fn large(run: *Run) i32 {
    _ = run.dl.PutStr("large: a large block taken and given back at once\n");
    const kinds = [_]struct { bytes: usize, pairs: u32, what: [*:0]const u8 }{
        .{ .bytes = 1 << 20, .pairs = 1000, .what = "pairs of 1 MiB" },
        .{ .bytes = 64 << 20, .pairs = 100, .what = "pairs of 64 MiB" },
    };
    for (kinds) |kind| {
        var count: u32 = 0;
        const started = run.now();
        while (count < kind.pairs and !run.stopped(count)) : (count += 1) {
            const block = run.take(kind.bytes) orelse break;
            run.give(block);
        }
        const nanos = run.now() - started;
        if (count == 0) {
            _ = Printf(run.dl, "  %-44s no block of that size\n", .{kind.what});
            continue;
        }
        run.report(kind.what, @as(u64, count) * 2, nanos);
    }
    return dos.RETURN_OK;
}

// --- the streams --------------------------------------------------------------------------

/// The blocks of a stream, and its neighbour's that are out.
const Stream = struct {
    blocks: []?*anyopaque,
    count: usize = 0,
    neighbour: [neighbour_batch]?*anyopaque = @splat(null),
    neighbour_count: usize = 0,

    /// What the neighbour holds given back.
    fn flush(stream: *Stream, run: *Run) void {
        for (stream.neighbour[0..stream.neighbour_count]) |block| run.give(block);
        stream.neighbour_count = 0;
    }

    fn free(stream: *Stream, run: *Run) void {
        for (stream.blocks[0..stream.count]) |block| run.give(block);
        stream.count = 0;
    }
};

fn streams(run: *Run, blocks: usize) i32 {
    _ = Printf(run.dl, "stream: a file of %zu MiB in %zu blocks of %u bytes, kept\n", .{ blocks * stream_data >> 20, blocks, @as(u32, stream_block) });
    if (blocks == 0) return dos.RETURN_OK;
    const first_table = takeTable(run, blocks) orelse return noMemory(run, blocks * @sizeOf(?*anyopaque));
    defer giveTable(run, first_table);
    const second_table = takeTable(run, blocks) orelse return noMemory(run, blocks * @sizeOf(?*anyopaque));
    defer giveTable(run, second_table);
    var first: Stream = .{ .blocks = first_table };
    defer first.free(run);
    var second: Stream = .{ .blocks = second_table };
    defer second.free(run);

    if (!takeStream(run, &first, false, "alone")) return noMemory(run, stream_block);
    if (run.broken) return dos.RETURN_OK;
    giveStream(run, &first, "given back");
    if (!takeStream(run, &first, true, "beside the neighbour")) return noMemory(run, stream_block);
    if (run.broken) return dos.RETURN_OK;
    if (!takeStream(run, &second, false, "again, that stream kept")) return noMemory(run, stream_block);
    if (run.broken) return dos.RETURN_OK;
    giveStream(run, &second, "the second given back");
    giveStream(run, &first, "the first given back");
    return dos.RETURN_OK;
}

/// `into`'s blocks taken, with the neighbour's beside them if
/// `neighbour`: the whole run, and its first and last eighths. False when
/// the memory ran out.
fn takeStream(run: *Run, into: *Stream, neighbour: bool, what: [*:0]const u8) bool {
    const total = into.blocks.len;
    const eighth = @max(total / 8, 1);
    const started = run.now();
    var first_eighth: u64 = 0;
    var last_started = started;
    var ok = true;
    while (into.count < total and !run.stopped(into.count)) {
        if (neighbour and into.count % neighbour_every == 0) {
            into.neighbour[into.neighbour_count] = run.take(neighbour_block) orelse {
                ok = false;
                break;
            };
            into.neighbour_count += 1;
            if (into.neighbour_count == neighbour_batch) into.flush(run);
        }
        into.blocks[into.count] = run.take(stream_block) orelse {
            ok = false;
            break;
        };
        into.count += 1;
        if (into.count == eighth) first_eighth = run.now() - started;
        if (into.count == total - eighth) last_started = run.now();
    }
    const ended = run.now();
    into.flush(run);
    if (!ok or run.broken) return ok;
    run.report(what, into.count, ended - started);
    run.report("  its first eighth", eighth, first_eighth);
    run.report("  its last eighth", eighth, ended - last_started);
    return true;
}

fn giveStream(run: *Run, from: *Stream, what: [*:0]const u8) void {
    const count = from.count;
    const started = run.now();
    from.free(run);
    run.report(what, count, run.now() - started);
}

// --- the rest -----------------------------------------------------------------------------

/// A table of `count` blocks, empty.
fn takeTable(run: *Run, count: usize) ?[]?*anyopaque {
    const memory = run.sys.AllocVec(count * @sizeOf(?*anyopaque), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const table: [*]?*anyopaque = @ptrCast(@alignCast(memory));
    return table[0..count];
}

fn giveTable(run: *Run, table: []?*anyopaque) void {
    run.give(@ptrCast(table.ptr));
}

fn number(arg: usize, default: u32) u32 {
    if (arg == 0) return default;
    return @bitCast(@as(*const i32, @ptrFromInt(arg)).*);
}

fn noMemory(run: *Run, bytes: usize) i32 {
    _ = Printf(run.dl, "%s: no memory for a block of %zu bytes\n", .{ COMMAND_NAME, bytes });
    return dos.RETURN_FAIL;
}
