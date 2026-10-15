// SPDX-License-Identifier: MPL-2.0
//! memdebug [on|off|check]: memory debugging. While it is on, every new
//! block gets a wall behind it that FreeMem checks, what is not cleared
//! holds 0xABADCAFE, freed memory holds 0xDEADBEEF and AllocMem checks it
//! still does when it hands it out again, and a task started with a stack
//! of 4 KiB or more gets a wide stack guard. `check` looks at every wall
//! and all free memory now, and names what is wrong.
//!
//! A wall written over is told by FreeMem with an alert and a line on the
//! log naming the block, the owner and how far it was written; free memory
//! written after its free, by AllocMem with a line on the log. The counts
//! of both are kept until the mode is switched on again.

const sdk = @import("sdk");
const _memory = @import("../../memory/_memory.zig");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "memdebug";
pub const usage = "memdebug [on|off|check]";
pub const help =
    \\  memdebug [on|off|check]  memory debugging: walls behind new blocks, patterns in new and
    \\                       freed memory, wide stack guards; check looks at all of it now
    \\
;

/// How many things wrong `check` names; the rest are counted.
const max_named = 16;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const base = shell.base;
    const word = args.next() orelse {
        report(shell);
        return;
    };
    if (_shell.same(word, "on")) {
        _memory.debugOn(base);
        shell.print("memdebug: on - new blocks walled, free memory filled\n", .{});
    } else if (_shell.same(word, "off")) {
        base.mem_debug.on = false;
        report(shell);
    } else if (_shell.same(word, "check")) {
        check(shell);
    } else return error.Usage;
}

/// The state and what was found since it was switched on.
fn report(shell: *Shell) void {
    const debug = &shell.base.mem_debug;
    const state: [*:0]const u8 = if (debug.on) "on" else "off";
    shell.print("memdebug %s: %u walls written over, %u writes to freed memory\n", .{ state, debug.walls, debug.freed_writes });
}

/// Every wall and all free memory looked at, under the memory lock, and
/// what is wrong printed after.
fn check(shell: *Shell) void {
    var found: [max_named]_memory.Damage = undefined;
    const count = _memory.debugCheck(shell.base, &found);
    for (found[0..@min(count, max_named)]) |*damage| {
        if (damage.freed) {
            shell.print("0x%08x  free memory written after its free\n", .{@as(u32, @truncate(damage.at))});
        } else {
            shell.print("0x%08x  a block of owner %u written past its end\n", .{ @as(u32, @truncate(damage.at)), damage.owner });
        }
    }
    if (count > max_named) shell.print("... and %u more\n", .{count - max_named});
    const free_too: [*:0]const u8 = if (shell.base.mem_debug.on) " and all free memory" else "";
    shell.print("memdebug check: %u things wrong in the walls%s\n", .{ count, free_too });
}
