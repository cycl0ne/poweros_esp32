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
//! of both are kept until the mode is switched on again. Each word is a
//! MemDebug call.

const sdk = @import("sdk");
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
    const sys = shell.base.iface();
    var state: sdk.exec.MemDebugInfo = .{};
    const word = args.next() orelse {
        _ = sys.MemDebug(sdk.exec.MEMDEBUG_ASK, &state, null, 0);
        report(shell, &state);
        return;
    };
    if (_shell.same(word, "on")) {
        _ = sys.MemDebug(sdk.exec.MEMDEBUG_ON, null, null, 0);
        shell.print("memdebug: on - new blocks walled, free memory filled\n", .{});
    } else if (_shell.same(word, "off")) {
        _ = sys.MemDebug(sdk.exec.MEMDEBUG_OFF, &state, null, 0);
        report(shell, &state);
    } else if (_shell.same(word, "check")) {
        check(shell);
    } else return error.Usage;
}

/// The state and what was found since it was switched on.
fn report(shell: *Shell, state: *const sdk.exec.MemDebugInfo) void {
    const on: [*:0]const u8 = if (state.on) "on" else "off";
    shell.print("memdebug %s: %u walls written over, %u writes to freed memory\n", .{ on, state.walls, state.freed_writes });
}

/// Every wall and all free memory looked at, under the memory lock, and
/// what is wrong printed after.
fn check(shell: *Shell) void {
    var found: [max_named]sdk.exec.MemDamage = undefined;
    var state: sdk.exec.MemDebugInfo = .{};
    const count = shell.base.iface().MemDebug(sdk.exec.MEMDEBUG_CHECK, &state, &found, max_named);
    for (found[0..@min(count, max_named)]) |*damage| {
        const at: u32 = @truncate(damage.at);
        switch (damage.kind) {
            sdk.exec.MEMDAMAGE_FREED => shell.print("0x%08x  free memory written after its free\n", .{at}),
            sdk.exec.MEMDAMAGE_CHAIN => shell.print("0x%08x  a block header written over: the rest of its region not looked at\n", .{at}),
            else => shell.print("0x%08x  a block of owner %u written past its end\n", .{ at, damage.owner }),
        }
    }
    if (count > max_named) shell.print("... and %u more\n", .{count - max_named});
    const free_too: [*:0]const u8 = if (state.on) " and all free memory" else "";
    const things: [*:0]const u8 = if (count == 1) "thing" else "things";
    shell.print("memdebug check: %u %s wrong in the walls%s\n", .{ count, things, free_too });
}
