// SPDX-License-Identifier: MPL-2.0
//! RawDoFmt, the raw serial port (RawIOInit, RawPutChar, RawMayGetChar)
//! and kprintf.
//!
//! RawDoFmt is the system's one formatter: everything that prints in this
//! tree is built on it, so a conversion means the same thing in a shell
//! command, a device's error and a kernel panic. Its rules:
//!
//!   %[-][0][width][.limit][l]{d,D,u,U,x,X,s,c}
//!
//! - Hex is uppercase without leading zeros; 0 prints as "0".
//! - With zero fill, a "-" goes before the zeros: %03d of -5 is "-05".
//! - .limit cuts the text; a NULL %s prints nothing, not even padding.
//! - An unknown conversion prints its own character, so %% prints "%".
//! - The output function gets a final NUL, and RawDoFmt returns the data
//!   stream past the values it used.
//!
//! The data stream is this chip's:
//! - %d %u %x %c take 32 bits, with l 64 bits. %s takes a pointer. The
//!   stream is packed and read with unaligned loads.
//! - A null output function stores the characters into put_ch_data as a
//!   buffer, which is how a string is formatted without writing a
//!   function for it.
//! - A format that ends in a lone "%" ends there rather than reading past
//!   the NUL.
//! - Left-justified text is padded with spaces even with the 0 flag,
//!   since zeros to the right of a number would change what it says.
//! - A null data stream gives 0 and null for every value rather than
//!   faulting, which keeps a bad format from taking the machine down.
//!
//! RawIOInit, RawPutChar and RawMayGetChar are the raw serial port: UART0,
//! polled, driven by exec itself (below; host tests put their stub into
//! `raw_io_hardware`). exec's init calls RawIOInit first of all, and until
//! then nothing goes out and nothing comes in - so a fault before that
//! point is silent.
//!
//! RawPutChar sends "\n" as "\r\n" and drops NULs, so a terminal need not
//! be in any particular mode and RawDoFmt's terminating NUL costs nothing.
//! `kprintf` is RawDoFmt to RawPutChar, for kernel code, which may run
//! before SysBase exists.
//!
//! The calls are a file each in this folder; this file is everything else.
//! The formatter itself (`format`) and one character out on the raw port
//! (`putChar`) take no base, because `kprintf` uses them: it is the
//! kernel's own output, runs before SysBase exists and after the machine
//! has broken, and has no table to call through (codex rule 1). The
//! jump-table calls hand their work to them.
//!
//! **The UART0 driver** is exec's own, just big enough. exec cannot import
//! serial.device's `uart.zig`, since the host tests' module ends at
//! src/rom/libs, and it needs a console long before a device exists
//! anyway. It sets UART0 up the same way serial.device would: bus clock,
//! reset with the core held, the 40 MHz crystal as its clock, 115200 8N1.
//! serial.device then finds UART0 already running from the crystal and
//! leaves it alone, so the two do not fight over the port.

const builtin = @import("builtin");
const sdk = @import("sdk");

const PutChProc = sdk.exec.PutChProc;

/// What RawIOInit, RawPutChar and RawMayGetChar drive.
pub const RawIOHardware = struct {
    /// Set the port up (rate, frame).
    init: *const fn () void,
    put: *const fn (c: u8) void,
    /// A received character, or null if none is waiting.
    get: *const fn () ?u8,
};

/// exec's UART0 driver; in the host tests, nothing (or a test's stub).
pub var raw_io_hardware: RawIOHardware = if (builtin.is_test) no_raw_io else chip_raw_io;

/// Set by RawIOInit: before it, the raw port is silent.
pub var raw_ready = false;

/// No hardware (host tests): output is dropped, and there is no input.
pub const no_raw_io: RawIOHardware = .{ .init = noInit, .put = noPut, .get = noGet };

/// exec's UART0 driver, below.
pub const chip_raw_io: RawIOHardware = .{ .init = uartInit, .put = uartPut, .get = uartGet };

fn noInit() void {}
fn noPut(_: u8) void {}
fn noGet() ?u8 {
    return null;
}

/// One character out on the raw port, "\n" as "\r\n". A NUL, or anything
/// before RawIOInit, goes nowhere.
///
/// INPUTS:
/// - `character` - the byte to send.
pub fn putChar(character: u8) void {
    if (!raw_ready or character == 0) return;
    if (character == '\n') raw_io_hardware.put('\r');
    raw_io_hardware.put(character);
}

/// kprintf for kernel code: `format_string` with `args` (checked at compile
/// time, as sdk.exec.kprintf's) through the formatter to the raw port.
///
/// INPUTS:
/// - `format_string` - a RawDoFmt format.
/// - `args` - a tuple of the values.
pub fn kprintf(comptime format_string: [:0]const u8, args: anytype) void {
    comptime sdk.exec.checkFormat(format_string, @TypeOf(args));
    const stream = sdk.exec.fmtStream(args);
    // Direct, not through the table: kprintf is the kernel's own output
    // and runs before SysBase exists and after the machine has broken,
    // where there is no table to call through (codex rule 1).
    _ = format(format_string, &stream, &rawPut, null);
}

/// `kprintf`'s output function: the character to the raw port.
fn rawPut(character: u8, _: ?*anyopaque) callconv(.c) void {
    putChar(character); // direct, for the same reason as kprintf
}

/// The characters of a NUL-terminated string, without it.
///
/// INPUTS:
/// - `text` - the string.
fn span(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}

// --- the formatter ----------------------------------------------------------

/// Where the characters go: the output function, or with none, the buffer
/// put_ch_data points to.
const Output = struct {
    proc: ?PutChProc,
    data: ?*anyopaque,

    fn put(out: *Output, character: u8) void {
        if (out.proc) |proc| return proc(character, out.data);
        const buffer: [*]u8 = @ptrCast(out.data orelse return);
        buffer[0] = character;
        out.data = buffer + 1;
    }

    fn repeat(out: *Output, character: u8, count: usize) void {
        for (0..count) |_| out.put(character);
    }
};

/// The next value of type T from the data stream (0 without one).
fn next(comptime T: type, data: *?[*]const u8) T {
    const at = data.* orelse return 0;
    data.* = at + @sizeOf(T);
    return @as(*align(1) const T, @ptrCast(at)).*;
}

/// A decimal number in the format: width or limit.
///
/// INPUTS:
/// - `cursor` - where the digits start; moved past them.
fn number(cursor: *[*:0]const u8) usize {
    var value: usize = 0;
    while (cursor.*[0] >= '0' and cursor.*[0] <= '9') : (cursor.* += 1) {
        value = value *% 10 +% (cursor.*[0] - '0');
    }
    return value;
}

/// `value` in `radix` at the end of `buffer`, uppercase, with a "-" in
/// front when `negative`.
fn digits(buffer: []u8, value: u64, radix: u8, negative: bool) []const u8 {
    var index = buffer.len;
    var rest = value;
    while (true) {
        index -= 1;
        buffer[index] = "0123456789ABCDEF"[@intCast(rest % radix)];
        rest /= radix;
        if (rest == 0) break;
    }
    if (negative) {
        index -= 1;
        buffer[index] = '-';
    }
    return buffer[index..];
}

/// RawDoFmt's work, with no base: `kprintf` formats with it before there
/// is an ExecBase. Formats `format_string` with the values in `data_stream`
/// and hands the characters to `put_ch_proc` (with `put_ch_data`), then a
/// NUL.
///
/// INPUTS:
/// - `format_string` - the format; the rules are in the file header.
/// - `data_stream` - the values, packed; null gives 0 and null for each.
/// - `put_ch_proc` - where the characters go; null stores them into
///   `put_ch_data` as a buffer.
/// - `put_ch_data` - handed to `put_ch_proc`, or the buffer.
///
/// RESULT:
/// The data stream past the values it used.
pub fn format(format_string: [*:0]const u8, data_stream: ?*const anyopaque, put_ch_proc: ?PutChProc, put_ch_data: ?*anyopaque) ?*const anyopaque {
    var out: Output = .{ .proc = put_ch_proc, .data = put_ch_data };
    var data: ?[*]const u8 = @ptrCast(data_stream);
    var cursor = format_string;
    while (cursor[0] != 0) {
        const character = cursor[0];
        cursor += 1;
        if (character != '%') {
            out.put(character);
            continue;
        }
        var left = false;
        if (cursor[0] == '-') {
            left = true;
            cursor += 1;
        }
        const zero = cursor[0] == '0';
        const width = number(&cursor);
        var limit: usize = 0;
        if (cursor[0] == '.') {
            cursor += 1;
            limit = number(&cursor);
        }
        const long = cursor[0] == 'l';
        if (long) cursor += 1;
        const conversion = cursor[0];
        if (conversion == 0) break;
        cursor += 1;

        var buffer: [24]u8 = undefined; // a 64-bit number: 20 digits and a sign
        var text: []const u8 = switch (conversion) {
            'd', 'D' => signed: {
                const value: i64 = if (long) next(i64, &data) else next(i32, &data);
                break :signed digits(&buffer, @abs(value), 10, value < 0);
            },
            'u', 'U' => digits(&buffer, if (long) next(u64, &data) else next(u32, &data), 10, false),
            'x', 'X' => digits(&buffer, if (long) next(u64, &data) else next(u32, &data), 16, false),
            'c' => char: {
                buffer[0] = @truncate(if (long) next(u64, &data) else next(u32, &data));
                break :char buffer[0..1];
            },
            's' => span(@as(?[*:0]const u8, @ptrFromInt(next(usize, &data))) orelse continue),
            else => {
                out.put(conversion);
                continue;
            },
        };
        if (limit != 0 and limit < text.len) text = text[0..limit];
        const pad = width -| text.len;
        if (left) {
            for (text) |character_out| out.put(character_out);
            out.repeat(' ', pad);
            continue;
        }
        if (zero and text.len != 0 and text[0] == '-') {
            out.put('-');
            text = text[1..];
        }
        out.repeat(if (zero) '0' else ' ', pad);
        for (text) |character_out| out.put(character_out);
    }
    out.put(0);
    return data;
}

// --- the UART0 driver --------------------------------------------------------

const baud = 115_200;
const xtal_hz = sdk.hardware.XTAL_HZ;

// UART0's registers.
const uart = sdk.hardware.uart;
const uart0 = uart.base(0);

/// UART0's bus clock and reset, and the UARTs' FIFO memory. The helpers
/// are inline and mask interrupts at the CPU, not through exec - this
/// runs before exec is up, and after it has stopped.
const system = sdk.hardware.system;
const reg = sdk.hardware.mmio.reg;

/// Sets UART0 up. Whatever the boot ROM was still sending is let out
/// first, so its output and the kernel's do not run together.
fn uartInit() void {
    while (reg(uart0 + uart.STATUS).* & uart.STATUS_TXFIFO_CNT != 0) {}
    while (reg(uart0 + uart.FSM_STATUS).* & uart.FSM_ST_UTX_OUT != 0) {}
    system.clockOn(.uart_mem);
    system.clockOn(.uart0);
    system.releaseReset(.uart0);
    reg(uart0 + uart.CLK_CONF).* |= uart.CLK_RST_CORE;
    system.holdInReset(.uart0);
    system.releaseReset(.uart0);
    reg(uart0 + uart.CLK_CONF).* &= ~uart.CLK_RST_CORE;
    const clk = reg(uart0 + uart.CLK_CONF).* & ~(uart.CLK_SCLK_SEL | uart.CLK_SCLK_DIV_NUM);
    reg(uart0 + uart.CLK_CONF).* = clk | uart.CLK_SCLK_SEL_XTAL | uart.CLK_SCLK_EN | uart.CLK_TX_SCLK_EN | uart.CLK_RX_SCLK_EN;
    const div16: u32 = (xtal_hz << 4) / baud; // in 1/16 steps
    reg(uart0 + uart.CLKDIV).* = (div16 & 0xF) << uart.CLKDIV_FRAG_SHIFT | div16 >> 4;
    reg(uart0 + uart.CONF0).* = (reg(uart0 + uart.CONF0).* & ~uart.CONF0_FRAME) | uart.CONF0_8N1;
}

/// RawPutChar's byte out. Waits while the TX FIFO is full.
fn uartPut(character: u8) void {
    while ((reg(uart0 + uart.STATUS).* & uart.STATUS_TXFIFO_CNT) >> uart.STATUS_TXFIFO_CNT_SHIFT >= uart.FIFO_LEN - 2) {}
    reg(uart0 + uart.FIFO).* = character;
}

/// RawMayGetChar's byte, if one is waiting.
fn uartGet() ?u8 {
    if (reg(uart0 + uart.STATUS).* & uart.STATUS_RXFIFO_CNT == 0) return null;
    return @truncate(reg(uart0 + uart.FIFO).*);
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;
const native_endian = @import("builtin").cpu.arch.endian();

/// The formatter into a buffer, for the test below: the characters, and
/// how many NULs came.
const FmtSink = struct {
    var buffer: [128]u8 = undefined;
    var len: usize = 0;
    var nuls: u32 = 0;

    fn put(c: u8, _: ?*anyopaque) callconv(.c) void {
        if (c == 0) {
            nuls += 1;
            return;
        }
        buffer[len] = c;
        len += 1;
    }

    fn run(format_string: [*:0]const u8, args: anytype) []const u8 {
        len = 0;
        nuls = 0;
        const stream = sdk.exec.fmtStream(args);
        _ = format(format_string, &stream, &put, null);
        return buffer[0..len];
    }
};

test "format: conversions, width and fill, odd formats, the stream, a buffer, unaligned values" {
    const f = FmtSink.run;
    // Conversions take 32 bits, with l 64.
    {
        try testing.expectEqualStrings("-42 42 2A x", f("%d %u %x %c", .{ @as(i32, -42), @as(u32, 42), @as(u32, 42), @as(u8, 'x') }));
        try testing.expectEqualStrings("-42 42 2A", f("%D %U %X", .{ @as(i32, -42), @as(u32, 42), @as(u32, 42) }));
        try testing.expectEqualStrings("-2147483648 4294967295 DEADBEEF", f("%d %u %x", .{ @as(i32, std.math.minInt(i32)), @as(u32, std.math.maxInt(u32)), @as(u32, 0xDEADBEEF) }));
        try testing.expectEqualStrings("-5000000000 18446744073709551615 100000000", f("%ld %lu %lx", .{ @as(i64, -5_000_000_000), @as(u64, std.math.maxInt(u64)), @as(u64, 0x1_0000_0000) }));
        try testing.expectEqualStrings("0 0", f("%x %d", .{ @as(u32, 0), @as(i32, 0) }));
        try testing.expectEqualStrings("name: exec", f("name: %s", .{"exec"}));
        try testing.expectEqual(@as(u32, 1), FmtSink.nuls); // the final NUL
    }
    // Width, zero fill, left justification, limit.
    {
        try testing.expectEqualStrings("[   42]", f("[%5d]", .{@as(u32, 42)}));
        try testing.expectEqualStrings("[42   ]", f("[%-5d]", .{@as(u32, 42)}));
        try testing.expectEqualStrings("[00042]", f("[%05d]", .{@as(u32, 42)}));
        try testing.expectEqualStrings("[-05]", f("[%03d]", .{@as(i32, -5)})); // the sign before the zeros
        try testing.expectEqualStrings("[5    ]", f("[%-05d]", .{@as(u32, 5)}));
        try testing.expectEqualStrings("[ab]", f("[%.2s]", .{"abcd"}));
        try testing.expectEqualStrings("[    ab]", f("[%6.2s]", .{"abcd"}));
        try testing.expectEqualStrings("[12]", f("[%1d]", .{@as(u32, 12)})); // too narrow: the whole number
        try testing.expectEqualStrings("[]", f("[%5s]", .{null})); // NULL: no padding either
    }
    // %%, unknown conversions, a % at the end.
    {
        try testing.expectEqualStrings("100%", f("100%%", .{}));
        try testing.expectEqualStrings("q 7", f("%q %d", .{@as(u32, 7)}));
        try testing.expectEqualStrings("a", f("a%", .{}));
        try testing.expectEqualStrings("a", f("a%-5l", .{}));
        try testing.expectEqual(@as(u32, 1), FmtSink.nuls);
    }
    // Returns the stream past the values it used.
    {
        const stream = sdk.exec.fmtStream(.{ @as(u32, 1), @as(u32, 2) });
        const rest = format("%d", &stream, &FmtSink.put, null);
        try testing.expectEqual(@as(?*const anyopaque, @ptrCast(&stream[4])), rest);
        // No stream: every value is 0 (and a %s NULL).
        FmtSink.len = 0;
        try testing.expectEqual(@as(?*const anyopaque, null), format("%d%s", null, &FmtSink.put, null));
        try testing.expectEqualStrings("0", FmtSink.buffer[0..FmtSink.len]);
    }
    // Without an output function it fills put_ch_data.
    {
        const stream = sdk.exec.fmtStream(.{ @as(i32, -3), "ok" });
        var out: [16]u8 = @splat(0xAA);
        _ = format("n=%d %s", &stream, null, &out);
        try testing.expectEqualStrings("n=-3 ok", std.mem.sliceTo(&out, 0));
        try testing.expectEqual(@as(u8, 0xAA), out[8]); // the NUL at 7, nothing after
    }
    // A 64-bit value right after a 32-bit one (unaligned).
    {
        const stream = sdk.exec.fmtStream(.{ @as(u32, 7), @as(u64, 0x1122334455667788) });
        var hand: [12]u8 = undefined;
        std.mem.writeInt(u32, hand[0..4], 7, native_endian);
        std.mem.writeInt(u64, hand[4..12], 0x1122334455667788, native_endian);
        try testing.expectEqualSlices(u8, &hand, &stream);
        FmtSink.len = 0;
        _ = format("%d %lx", &stream, &FmtSink.put, null);
        try testing.expectEqualStrings("7 1122334455667788", FmtSink.buffer[0..FmtSink.len]);
    }
}
