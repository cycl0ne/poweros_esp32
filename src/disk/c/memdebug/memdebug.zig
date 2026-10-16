// SPDX-License-Identifier: MIT
//! MemDebug: memory debugging switched on or off, or checked now. Built
//! against the SDK only.
//!
//!   MemDebug ON/S,OFF/S,CHECK/S
//!
//! While it is on, every new block gets a wall behind it that FreeMem
//! checks, what is not cleared holds 0xABADCAFE, freed memory holds
//! 0xDEADBEEF and AllocMem checks it still does when it hands it out
//! again, and a task started with a stack of 4 KiB or more gets a wide
//! stack guard. FreeMem and AllocMem tell what they find on the system
//! log. Without an argument it prints whether the mode is on and what was
//! found since it was switched on; OFF prints the same as it switches off.
//!
//! CHECK looks at every wall and, while the mode is on, all free memory
//! now (exec's MemDebug), and names what is wrong: the address, and for a
//! wall the block's owner by number and, while that task is there, by
//! name (`sdk.exec.memowners`). Something wrong makes it end with WARN, so
//! a script can ask `If WARN`.
//!
//! A kernel built with -Dmemdebug=true has the mode on from its start, so
//! that the blocks the system made as it came up are walled too.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "MemDebug";
const VERSION_STRING = "\x00$VER: MemDebug 1.0 (16.10.2026)\r\n";

const template = "ON/S,OFF/S,CHECK/S";
const arg_on = 0;
const arg_off = 1;
const arg_check = 2;

const MSG_ONEONLY = "only one of ON, OFF or CHECK allowed\n";
/// How many things wrong CHECK names; the rest are counted.
const max_named = 16;
/// How many owners are told apart when CHECK names them.
const max_owners = 64;

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

    const given = @as(u32, @intFromBool(argv[arg_on] != 0)) + @intFromBool(argv[arg_off] != 0) + @intFromBool(argv[arg_check] != 0);
    if (given > 1) {
        _ = dl.PutStr(MSG_ONEONLY);
        return dos.RETURN_FAIL;
    }
    if (argv[arg_check] != 0) return check(sys, dl);
    if (argv[arg_on] != 0) {
        _ = sys.MemDebug(exec.MEMDEBUG_ON, null, null, 0);
        _ = dl.PutStr("Memory debugging on: new blocks walled, free memory filled\n");
        return dos.RETURN_OK;
    }
    var state: exec.MemDebugInfo = .{};
    const action = if (argv[arg_off] != 0) exec.MEMDEBUG_OFF else exec.MEMDEBUG_ASK;
    _ = sys.MemDebug(action, &state, null, 0);
    const on: [*:0]const u8 = if (state.on) "on" else "off";
    _ = Printf(dl, "Memory debugging %s: %u walls written over, %u writes to freed memory\n", .{ on, state.walls, state.freed_writes });
    return dos.RETURN_OK;
}

/// Every wall and all free memory looked at, and what is wrong printed
/// after, each wall's owner named by the tasks there are now: the check
/// and the naming each under exec's own lock, nothing printed meanwhile.
fn check(sys: *ExecBase, dl: *DosBase) i32 {
    var found: [max_named]exec.MemDamage = undefined;
    var state: exec.MemDebugInfo = .{};
    const count = sys.MemDebug(exec.MEMDEBUG_CHECK, &state, &found, max_named);
    const named = found[0..@min(count, max_named)];
    var tally: exec.memowners.Tally(max_owners) = .{};
    if (named.len != 0) {
        tally.take(sys);
        tally.name(sys);
    }
    for (named) |*damage| {
        const at: u32 = @truncate(damage.at);
        switch (damage.kind) {
            exec.MEMDAMAGE_FREED => _ = Printf(dl, "0x%08x  free memory written after its free\n", .{at}),
            exec.MEMDAMAGE_CHAIN => _ = Printf(dl, "0x%08x  a block header written over: the rest of its region not looked at\n", .{at}),
            else => if (damage.owner == exec.MEMOWNER_SYSTEM) {
                _ = Printf(dl, "0x%08x  a block of the system's written past its end\n", .{at});
            } else {
                const owner = tally.of(damage.owner);
                const task: [*:0]const u8 = if (owner != null and owner.?.living) @ptrCast(&owner.?.name) else "ended";
                _ = Printf(dl, "0x%08x  a block of task %u (%s) written past its end\n", .{ at, damage.owner, task });
            },
        }
    }
    if (count > max_named) _ = Printf(dl, "... and %u more\n", .{count - max_named});
    const free_too: [*:0]const u8 = if (state.on) " and all free memory" else "";
    const things: [*:0]const u8 = if (count == 1) "thing" else "things";
    _ = Printf(dl, "%u %s wrong in the walls%s\n", .{ count, things, free_too });
    return if (count != 0) dos.RETURN_WARN else dos.RETURN_OK;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
