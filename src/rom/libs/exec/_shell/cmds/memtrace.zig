// SPDX-License-Identifier: MPL-2.0
//! memtrace [on|count|off|min <bytes>]: what the system hands out and
//! takes back, counted around whatever is being measured. `on` prints a
//! line per event on this line as well as counting; `count` only counts,
//! which changes the timing of what is being watched far less; `off` stops
//! and says what is outstanding. `min` keeps the small blocks out of the
//! printing without taking them out of the count.

const exec = @import("../../exec.zig");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "memtrace";
pub const usage = "memtrace [on|count|off|min <bytes>]";
pub const help =
    \\  memtrace [on|count|off|min <bytes>]  count what is allocated and freed around a measurement;
    \\                       on prints each event too, off says what is outstanding
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const trace = exec.trace;
    const word = args.next() orelse {
        report(shell, trace);
        return;
    };
    if (_shell.same(word, "on") or _shell.same(word, "count")) {
        trace.start(word[0] == 'o');
        const printing: [*:0]const u8 = if (trace.loud) " and printing" else "";
        shell.print("memtrace: counting%s, from nothing\n", .{printing});
    } else if (_shell.same(word, "off")) {
        trace.on = false;
        trace.loud = false;
        report(shell, trace);
    } else if (_shell.same(word, "min")) {
        trace.min_size = try args.number();
        shell.print("memtrace: printing blocks of %d bytes and up\n", .{trace.min_size});
    } else return error.Usage;
}

/// What the count has come to.
fn report(shell: *Shell, trace: *const exec.Trace) void {
    const left = trace.outstanding();
    const state: [*:0]const u8 = if (trace.on) "on" else "off";
    shell.print("memtrace %s: %d allocations %ld bytes, %d frees %ld bytes\n", .{
        state,
        trace.allocs,
        trace.alloc_bytes,
        trace.frees,
        trace.free_bytes,
    });
    if (left >= 0) {
        shell.print("             %ld bytes outstanding\n", .{@as(u64, @intCast(left))});
    } else {
        shell.print("             %ld bytes more freed than taken\n", .{@as(u64, @intCast(-left))});
    }
}
