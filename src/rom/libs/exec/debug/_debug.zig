// SPDX-License-Identifier: MPL-2.0
//! The ROM debugger: the machine stopped, read and told what to do over
//! the raw ports.
//!
//! `s3>` is a task. It needs the scheduler, a console device and memory,
//! so it is gone exactly when it is wanted most - after a Guru, a hang,
//! or a crash in something it stands on. This is the other half: it runs
//! with interrupts masked, on no task, through no device, allocating
//! nothing, and leaves the machine as it found it when told to go on.
//!
//! **It talks on both raw ports at once.** Both boards say their console
//! is the chip's own USB port, and a 7B may also have a cable on UART0;
//! which one is plugged in is not something a stopped machine can ask.
//! So every character goes to both and a character is taken from
//! whichever has one. Nothing else is running to fight over either port.
//!
//! **It runs on the stack it was entered on.** Switching stacks under
//! compiled code needs the register windows spilled, which is exec's
//! `NewStackRun` - a call that allocates and waits, neither of which is
//! available here. What it does instead is look at the stack pointer
//! before it starts: a debugger that crashes on a blown stack is worse
//! than one that says the stack is blown.
//!
//! **Nothing here calls through a jump table.** The code that reports a
//! broken machine must not depend on anything that may be what broke, so
//! this file calls exec's own functions directly, as the Guru does
//! (codex rule 1's exception for the kernel's own output).

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const exec = @import("../exec.zig");
const _rawio = @import("../rawio/_rawio.zig");

/// What the chip's part of the debugger is, as `RawIOHardware` is what
/// the raw port's part is. The kernel fills it in at boot; without it
/// the debugger says so and goes straight back, which is what the host
/// tests get.
///
/// exec may not reach into `src/arch/`: its host tests compile this file
/// and there is no Xtensa there. Everything that needs an instruction or
/// knows the chip's map is behind these.
pub const DebugHardware = struct {
    /// Mask interrupts and answer what to put back.
    stop: *const fn () u32,
    /// Put back what `stop` answered.
    go: *const fn (saved: u32) void,
    halt: *const fn () noreturn,
    reboot: *const fn () void,
    /// The registers of a trap frame, written a character at a time
    /// through `put`, so the debugger decides where they go.
    showFrame: *const fn (frame: *const anyopaque, put: sdk.exec.PutChProc, data: ?*anyopaque) void,
    /// Where the stopped code was: its pc, its stack pointer and the
    /// return address it would have gone to.
    frameAt: *const fn (frame: *const anyopaque, pc: *usize, sp: *usize, ret: *usize) void,
    /// The code an address is in, and how far into it; null when it is
    /// in none that is known.
    whereIs: *const fn (address: usize, offset: *usize) ?[*:0]const u8,
    /// Whether an address can be read without faulting again.
    readable: *const fn (address: usize) bool,
};

/// Set by the kernel. Null until then, and in the host tests.
pub var debug_hardware: ?*const DebugHardware = null;

/// What the debugger was entered for, which decides what `g` does.
pub const Reason = enum {
    /// `Debug()` from working code: `g` goes back to it.
    asked,
    /// An alert that can be returned from.
    recoverable,
    /// A dead-end Guru: there is nothing to go back to, so `g` halts.
    dead_end,
};

/// How long a typed line may be.
const line_length = 96;

/// How many frames a backtrace shows before it gives up.
const max_frames = 24;

/// How much memory `d` shows when no length is given.
const default_dump = 64;

/// The state of one visit. It is static rather than on the stack because
/// the stack is the thing least to be trusted here.
var reason: Reason = .asked;
var frame: ?*const anyopaque = null;
var line: [line_length]u8 = undefined;
var going = false;

// --- the two ports ----------------------------------------------------------
//
// In the host tests neither exists: naming them there would compile the
// chip's UART setup, which is Xtensa instructions, into a program for
// this machine.

const port_uart: _rawio.RawIOHardware = if (builtin.is_test) _rawio.no_raw_io else _rawio.chip_raw_io;
const port_usb: _rawio.RawIOHardware = if (builtin.is_test) _rawio.no_raw_io else _rawio.usb_jtag_raw_io;

fn put(character: u8) void {
    if (character == '\n') put('\r');
    port_uart.put(character);
    port_usb.put(character);
}

fn puts(text: []const u8) void {
    for (text) |character| put(character);
}

/// A character from whichever port has one; it waits for one.
fn get() u8 {
    while (true) {
        if (port_uart.get()) |character| return character;
        if (port_usb.get()) |character| return character;
    }
}

/// A character if one is waiting, without stopping for it.
fn poll() ?u8 {
    if (port_uart.get()) |character| return character;
    return port_usb.get();
}

/// exec's formatter onto both ports, so the debugger prints the way the
/// rest of the kernel does.
fn printf(comptime format: [:0]const u8, args: anytype) void {
    const stream = sdk.exec.fmtStream(args);
    _ = exec.format(format, &stream, &putHook, null);
}

fn putHook(character: u8, _: ?*anyopaque) callconv(.c) void {
    if (character != 0) put(character);
}

/// A line typed, echoed as it comes, with backspace. What was typed.
fn readLine() []const u8 {
    var length: usize = 0;
    while (true) {
        const character = get();
        switch (character) {
            '\r', '\n' => {
                put('\n');
                return line[0..length];
            },
            8, 127 => if (length > 0) {
                length -= 1;
                puts("\x08 \x08");
            },
            else => if (character >= ' ' and character < 127 and length + 1 < line.len) {
                line[length] = character;
                length += 1;
                put(character);
            },
        }
    }
}

// --- reading what was typed -------------------------------------------------

/// The words of a line, in order.
const Words = struct {
    rest: []const u8,

    fn next(self: *Words) ?[]const u8 {
        var at: usize = 0;
        while (at < self.rest.len and self.rest[at] == ' ') at += 1;
        if (at >= self.rest.len) return null;
        const start = at;
        while (at < self.rest.len and self.rest[at] != ' ') at += 1;
        const word = self.rest[start..at];
        self.rest = self.rest[at..];
        return word;
    }
};

/// A number, hex unless it is written `#1234`. Null when it is not one.
fn number(word: []const u8) ?usize {
    if (word.len == 0) return null;
    var text = word;
    var base: usize = 16;
    if (text[0] == '#') {
        base = 10;
        text = text[1..];
    } else if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        text = text[2..];
    }
    if (text.len == 0) return null;
    var value: usize = 0;
    for (text) |character| {
        const digit: usize = switch (character) {
            '0'...'9' => character - '0',
            'a'...'f' => character - 'a' + 10,
            'A'...'F' => character - 'A' + 10,
            else => return null,
        };
        if (digit >= base) return null;
        value = value * base + digit;
    }
    return value;
}

// --- what it can look at ----------------------------------------------------

/// Whether an address can be read without causing a second fault. The
/// memory lists would say it more exactly and are not asked: they are
/// among the things that may be what broke.
fn readable(address: usize) bool {
    const chip = debug_hardware orelse return false;
    return chip.readable(address);
}

fn word32(address: usize) ?u32 {
    if (address & 3 != 0 or !readable(address)) return null;
    return @as(*const volatile u32, @ptrFromInt(address)).*;
}

/// Where an address is, printed after it: `(the ROM)` or the file and
/// the offset into it.
fn named(address: usize) void {
    const chip = debug_hardware orelse return;
    var offset: usize = 0;
    const name = chip.whereIs(address, &offset) orelse return;
    if (offset == 0) {
        printf(" (%s)", .{name});
    } else {
        printf(" (%.32s +0x%x)", .{ name, @as(u32, @truncate(offset)) });
    }
}

/// Whether an address is in code that can be named, which is how a
/// backtrace knows it is still walking frames and not rubbish.
fn inCode(address: usize) bool {
    const chip = debug_hardware orelse return false;
    var offset: usize = 0;
    return chip.whereIs(address, &offset) != null;
}

// --- the commands -----------------------------------------------------------

fn showRegisters() void {
    const chip = debug_hardware orelse return;
    const f = frame orelse {
        printf("no trap frame: entered from a call, not from an exception\n", .{});
        return;
    };
    chip.showFrame(f, &putHook, null);
}

fn dump(words: *Words) void {
    const address = number(words.next() orelse "") orelse {
        printf("d <address> [length]\n", .{});
        return;
    };
    const length = number(words.next() orelse "") orelse default_dump;
    var at = address & ~@as(usize, 3);
    const end = at + length;
    while (at < end) {
        printf("%08x ", .{@as(u32, @truncate(at))});
        var column: usize = 0;
        while (column < 4 and at < end) : (column += 1) {
            if (word32(at)) |value| {
                printf(" %08x", .{value});
            } else {
                puts("  ------");
            }
            at += 4;
        }
        put('\n');
    }
}

fn poke(words: *Words) void {
    const address = number(words.next() orelse "") orelse {
        printf("m <address> <value>\n", .{});
        return;
    };
    const value = number(words.next() orelse "") orelse {
        printf("m <address> <value>\n", .{});
        return;
    };
    if (address & 3 != 0 or !readable(address)) {
        printf("%08x cannot be written\n", .{@as(u32, @truncate(address))});
        return;
    }
    @as(*volatile u32, @ptrFromInt(address)).* = @truncate(value);
    printf("%08x = %08x\n", .{ @as(u32, @truncate(address)), @as(u32, @truncate(value)) });
}

/// The register windows pushed out to the stacks they belong to, by
/// calling deep enough that the window file overflows and the hardware
/// writes the older ones out. There is no instruction that spills them
/// without the window registers being driven by hand.
///
/// Only done when the debugger was entered from working code. A spill
/// writes to a stack, and on a dead-end Guru that stack may be the thing
/// that broke; a backtrace that stops early is better than a debugger
/// that faults.
/// Written to and read back through a volatile pointer, so the calls
/// below are not thrown away as having no effect - which is exactly
/// what they look like.
var spill_sink: u32 = 0;

noinline fn spillWindows(depth: u32) u32 {
    if (depth == 0) return @as(*volatile u32, &spill_sink).*;
    const deeper = spillWindows(depth - 1);
    @as(*volatile u32, &spill_sink).* = deeper +% depth;
    return deeper +% depth;
}

/// The call chain, from the stopped code outwards.
///
/// A windowed call leaves the caller's return address and stack pointer
/// in the four words below the callee's stack pointer, so the chain is
/// read from memory - as long as the window that held them has been
/// spilled. The registers still in the window file are not in memory at
/// all, so a chain may stop early; it says so rather than inventing the
/// rest. Nothing is spilled on purpose here: forcing a spill writes to a
/// stack that may be what broke.
fn backtrace() void {
    const chip = debug_hardware orelse return;
    if (reason == .asked) @as(*volatile u32, &spill_sink).* = spillWindows(18);
    var pc: usize = 0;
    var sp: usize = 0;
    if (frame) |f| {
        var ret: usize = 0;
        chip.frameAt(f, &pc, &sp, &ret);
        printFrame(0, pc);
        // The caller of the stopped function is in a0, not in memory.
        pc = returnTo(ret, pc);
    } else {
        // No trap frame: entered from a call. The four words below this
        // function's own stack pointer hold the return address and
        // stack of whoever called it, which is where the chain starts.
        // `@returnAddress` is not used: under the windowed ABI it is
        // empty as often as not.
        sp = @frameAddress();
        const here = @intFromPtr(&backtrace);
        pc = returnTo(word32(sp -% 16) orelse 0, here);
        sp = word32(sp -% 12) orelse sp;
    }
    var depth: u32 = 1;
    while (depth < max_frames) : (depth += 1) {
        if (pc == 0 or !inCode(pc)) break;
        printFrame(depth, pc);
        // The four words below this frame's stack pointer hold the
        // frame before it.
        const next_pc = word32(sp -% 16) orelse break;
        const next_sp = word32(sp -% 12) orelse break;
        if (next_pc == 0 or next_sp <= sp or !readable(next_sp)) break;
        pc = returnTo(next_pc, pc);
        sp = next_sp;
    }
    if (depth >= max_frames) printf("  ... and further\n", .{});
}

fn printFrame(depth: u32, pc: usize) void {
    printf("  %2d  0x%08x", .{ depth, @as(u32, @truncate(pc)) });
    named(pc);
    put('\n');
}

/// A return address as a place in the code: the window's call size taken
/// off the top, the code region put back, and three bytes taken off so
/// that it lands in the call rather than after it.
fn returnTo(value: usize, near: usize) usize {
    if (value == 0) return 0;
    const address = (value & 0x3FFF_FFFF) | (near & 0xC000_0000);
    return if (address >= 3) address - 3 else address;
}

fn help() void {
    puts(
        \\  r            the registers and the trap frame
        \\  bt           the call chain
        \\  d addr [len] memory, in words
        \\  m addr value one word written
        \\  g            go on
        \\  reset        restart the machine
        \\  q            the same as g
        \\
    );
}

fn same(word: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, word, name);
}

// --- the prompt -------------------------------------------------------------

/// Whether the stack looks like one. A debugger that crashes on a blown
/// stack tells nobody anything.
fn stackLooksSound() bool {
    const sp = @frameAddress();
    return sp & 15 == 0 and readable(sp) and readable(sp + 256);
}

/// The debugger entered. It returns when told to go on; on a dead-end
/// alert it never returns.
pub fn enter(why: Reason, trap_frame: ?*const anyopaque) void {
    const chip = debug_hardware orelse {
        printf("\n*** no debugger on this machine\n", .{});
        return;
    };
    reason = why;
    frame = trap_frame;
    going = false;

    // Nothing else runs while the debugger has the machine, and the
    // level the caller was at is put back when it goes on.
    const saved = chip.stop();
    defer chip.go(saved);

    if (!stackLooksSound()) {
        printf("\n*** the stack is not sound (sp 0x%08x): halted\n", .{@as(u32, @truncate(@frameAddress()))});
        chip.halt();
    }

    printf("\nROM debugger. ? for the commands.\n", .{});
    if (exec.initialized) {
        const task = exec.SysBase.this_task;
        printf("stopped in task \"%s\"\n", .{task.name()});
    }

    while (!going) {
        puts("dbg> ");
        var words = Words{ .rest = readLine() };
        const word = words.next() orelse continue;
        if (same(word, "?") or same(word, "h") or same(word, "help")) {
            help();
        } else if (same(word, "r")) {
            showRegisters();
        } else if (same(word, "bt")) {
            backtrace();
        } else if (same(word, "d")) {
            dump(&words);
        } else if (same(word, "m")) {
            poke(&words);
        } else if (same(word, "g") or same(word, "q")) {
            if (reason == .dead_end) {
                printf("nothing to go back to: halted\n", .{});
                chip.halt();
            }
            going = true;
        } else if (same(word, "reset")) {
            chip.reboot();
        } else {
            printf("%.16s? ? for the commands.\n", .{word.ptr});
        }
    }
}

/// A dead-end alert offers the debugger for a few seconds and halts if
/// nobody answers, so an unattended board behaves as it always has.
/// Whether it was taken up.
pub fn offer() bool {
    puts("*** enter the debugger? (y) ");
    var spins: u32 = 0;
    while (spins < offer_spins) : (spins += 1) {
        if (poll()) |character| {
            if (character == 'y' or character == 'Y') {
                put('\n');
                return true;
            }
            if (character == '\r' or character == '\n' or character == 'n' or character == 'N') break;
        }
    }
    puts("\n");
    return false;
}

/// About five seconds of asking, counted in spins because the timer is
/// one of the things that may have stopped.
const offer_spins: u32 = 60_000_000;
