// SPDX-License-Identifier: MIT
//! Where: where a task stands - the instruction it is at and the calls it
//! came through, each named by the code it is in - asked while it runs
//! on, without stopping it. Built against the SDK only.
//!
//!   Where TASK/A,TIMES/K/N
//!
//! TASK is a task's number, as `Tasks` shows it, or its name. One look:
//!
//!   Task 12 "Paint", running on core 2
//!     at     0x000000004a3c1234  SYS:Programs/Paint +0x3f234
//!     link   0x000000004a3c1100  SYS:Programs/Paint +0x3f100
//!     stack  0x000000004a5ffa10  1520 of 65536 bytes in use
//!     called from
//!        1   0x0000000040081234  ROM
//!        2   0x000000004a3c0200  SYS:Programs/Paint +0x3e200
//!
//! `at` is the instruction it runs, or for a task that waits the one it
//! goes on from, which is in exec's Wait. `link` is the return address
//! its CPU holds in a register, shown when it is not the first call
//! already: a function that has made no frame yet returns there. `called from` are the return addresses up its frames,
//! the innermost first. An address in the ROM says ROM - the kernel's
//! ELF of the same build names its line, `llvm-symbolizer
//! --obj=zig-out/bin/kernel <address>` - and one in a file loaded from
//! disk says the file and how far into its code, which the file's ELF
//! names the same way, with that offset (`FindLoadedCode`). One in no
//! code says `?`.
//!
//! TIMES looks that many times, a tick of 20 ms apart, prints the first
//! look whole and after it the places the task was at, each with how
//! often: a task that loops shows its loop, one that waits the same place
//! each time. A task that ends meanwhile is said, and the looks so far
//! are shown.
//!
//! The task is not stopped: one running on another core is read there at
//! that core's next exception (`GetTaskSpot`), and runs on. A core that
//! holds its interrupts off does not answer - its task runs inside
//! Disable, or spins for a lock with its interrupts masked - and that is
//! what Where says, with RETURN_WARN; with TIMES such looks count as
//! elsewhere. On the
//! ESP32-S3 the frames are in the CPU's register windows until the task
//! switches, and `called from` stays empty.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Where";
const VERSION_STRING = "\x00$VER: Where 1.0 (21.11.2026)\r\n";

const template = "TASK/A,TIMES/K/N";
const arg_task = 0;
const arg_times = 1;
const arg_count = 2;

/// An address as wide as the machine's.
const address_format = if (@sizeOf(usize) == 8) "0x%016zx" else "0x%08zx";
/// How many places TIMES tells apart; the rest are counted together.
const max_places = 24;
const max_times = 10_000;

const Place = struct { pc: usize, rom: bool, count: u32 };

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const wanted = rdargs.string(argv[arg_task]).?;
    const times: u32 = @intCast(@min(@max(rdargs.number(argv[arg_times]) orelse 1, 1), max_times));

    var task = findTask(sys, dl, wanted) orelse {
        _ = Printf(dl, "No task %s\n", .{wanted});
        return dos.RETURN_WARN;
    };
    if (task == sys.FindTask(null).?) {
        _ = Printf(dl, "%s: a task cannot look at itself\n", .{COMMAND_NAME});
        return dos.RETURN_WARN;
    }
    const id = task.id;
    var name: [40]u8 = undefined;
    copyName(&name, task.node.name);

    var spot: exec.TaskSpot = .{};
    if (!sys.GetTaskSpot(task, &spot)) {
        _ = Printf(dl, "Task %u has ended\n", .{id});
        return dos.RETURN_WARN;
    }
    const size = task.sp_upper -% task.sp_lower;
    const upper = task.sp_upper;
    if (spot.pc == 0 and spot.core != exec.ANY_CORE) {
        _ = Printf(dl, "Task %u \"%s\", running on core %u with its interrupts held off: not read\n", .{ id, @as([*:0]const u8, @ptrCast(&name)), spot.core });
        return dos.RETURN_WARN;
    }
    if (spot.core != exec.ANY_CORE) {
        _ = Printf(dl, "Task %u \"%s\", running on core %u\n", .{ id, @as([*:0]const u8, @ptrCast(&name)), spot.core });
    } else {
        _ = Printf(dl, "Task %u \"%s\", %s\n", .{ id, @as([*:0]const u8, @ptrCast(&name)), stateName(task.state) });
    }
    showSpot(dl, &spot, size, upper);
    if (times == 1) return dos.RETURN_OK;

    // The looks after the first: the task found again by its number each
    // time, so one that ended is not read from memory it gave back.
    var places: [max_places]Place = undefined;
    var place_count: usize = 0;
    var others: u32 = 0;
    var looks: u32 = 0;
    var ended = false;
    while (looks < times) {
        if (looks != 0) {
            if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) break;
            dl.Delay(1);
            task = sys.FindTaskById(id) orelse {
                ended = true;
                break;
            };
            if (!sys.GetTaskSpot(task, &spot)) {
                ended = true;
                break;
            }
        }
        looks += 1;
        if (spot.pc == 0) {
            others += 1;
            continue;
        }
        const rom = spot.in_rom & 1 != 0;
        for (places[0..place_count]) |*place| {
            if (place.pc == spot.pc) {
                place.count += 1;
                break;
            }
        } else if (place_count < max_places) {
            places[place_count] = .{ .pc = spot.pc, .rom = rom, .count = 1 };
            place_count += 1;
        } else {
            others += 1;
        }
    }
    if (ended) _ = Printf(dl, "Task %u has ended\n", .{id});
    _ = Printf(dl, "%u looks, at\n", .{looks});
    sortPlaces(places[0..place_count]);
    for (places[0..place_count]) |place| {
        _ = Printf(dl, "  %5u   ", .{place.count});
        showAddress(dl, place.pc, place.rom);
    }
    if (others != 0) _ = Printf(dl, "  %5u   elsewhere\n", .{others});
    return dos.RETURN_OK;
}

/// The task `text` names: its number, or else its name.
fn findTask(sys: *ExecBase, dl: *DosBase, text: [*:0]const u8) ?*exec.Task {
    var number: i32 = 0;
    const used = dl.StrToLong(text, &number);
    if (used > 0 and text[@intCast(used)] == 0 and number >= 0) return sys.FindTaskById(@intCast(number));
    return sys.FindTask(text);
}

fn copyName(into: []u8, name: ?[*:0]const u8) void {
    const from = name orelse "";
    var i: usize = 0;
    while (i < into.len - 1 and from[i] != 0) : (i += 1) into[i] = from[i];
    into[i] = 0;
}

fn stateName(state: exec.TaskState) [*:0]const u8 {
    return switch (state) {
        .ready => "ready to run",
        .wait => "waiting",
        .except => "held by a failure",
        else => "switched out",
    };
}

fn showSpot(dl: *DosBase, spot: *const exec.TaskSpot, size: usize, upper: usize) void {
    _ = dl.PutStr("  at     ");
    showAddress(dl, spot.pc, spot.in_rom & 1 != 0);
    // A function that has made its frame has saved the link there: then
    // it is the first call, and shown once.
    if (spot.link != 0 and (spot.depth == 0 or spot.calls[0] != spot.link)) {
        _ = dl.PutStr("  link   ");
        showAddress(dl, spot.link, spot.in_rom & 2 != 0);
    }
    _ = Printf(dl, "  stack  " ++ address_format, .{spot.sp});
    if (spot.sp <= upper and upper - spot.sp <= size) {
        _ = Printf(dl, "  %zu of %zu bytes in use\n", .{ upper - spot.sp, size });
    } else {
        _ = Printf(dl, "  outside its stack of %zu bytes\n", .{size});
    }
    if (spot.depth == 0) return;
    _ = dl.PutStr("  called from\n");
    for (spot.calls[0..spot.depth], 0..) |address, i| {
        _ = Printf(dl, "    %2u   ", .{@as(u32, @intCast(i + 1))});
        showAddress(dl, address, spot.in_rom & (@as(u32, 4) << @intCast(i)) != 0);
    }
}

/// An address and the code it is in, and the line's end.
fn showAddress(dl: *DosBase, address: usize, rom: bool) void {
    _ = Printf(dl, address_format ++ "  ", .{address});
    if (rom) {
        _ = dl.PutStr("ROM\n");
        return;
    }
    var file: [96]u8 = undefined;
    var offset: usize = 0;
    if (dl.FindLoadedCode(address, &file, file.len, &offset)) {
        _ = Printf(dl, "%s +0x%zx\n", .{ @as([*:0]const u8, @ptrCast(&file)), offset });
    } else {
        _ = dl.PutStr("?\n");
    }
}

/// The places most looked at first.
fn sortPlaces(places: []Place) void {
    var i: usize = 1;
    while (i < places.len) : (i += 1) {
        const one = places[i];
        var at = i;
        while (at > 0 and places[at - 1].count < one.count) : (at -= 1) places[at] = places[at - 1];
        places[at] = one;
    }
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
