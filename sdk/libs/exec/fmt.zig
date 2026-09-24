// SPDX-License-Identifier: MIT
//! RawDoFmt's side of the SDK: the output function's type, a way to build
//! its data stream from Zig values, a compile-time check of a format
//! against its values, and debug.lib's kprintf.
//!
//! The data stream holds the values in the order of the format's `%`s,
//! packed: `%d %u %x %c` take 32 bits, with `l` 64 bits, and `%s` takes a
//! pointer to a NUL-terminated string. fmtStream packs a tuple that way;
//! checkFormat makes sure a format and a tuple fit together.
//!
//!   sdk.exec.kprintf(sys, "%s: %ld bytes\n", .{ name, @as(u64, size) });

const std = @import("std");
const native = @import("builtin").cpu.arch.endian();
const ExecBase = @import("../../interface/exec.zig").ExecBase;

/// RawDoFmt's output function: gets each character, then a final NUL, and
/// the put_ch_data RawDoFmt was given.
pub const PutChProc = *const fn (c: u8, put_ch_data: ?*anyopaque) callconv(.c) void;

/// What a value is in the data stream.
const Kind = enum {
    /// 4 bytes: %d %u %x %c.
    word,
    /// 8 bytes: %ld %lu %lx %lc.
    long,
    /// A NUL-terminated string (or null): %s.
    string,
    /// Any other pointer: no conversion takes it.
    pointer,
};

fn isString(comptime T: type) bool {
    const info = @typeInfo(T).pointer;
    const Elem = switch (info.size) {
        .one => switch (@typeInfo(info.child)) {
            .array => |array| array.child,
            else => return false,
        },
        else => info.child,
    };
    return Elem == u8 and std.meta.sentinel(T) == @as(u8, 0);
}

fn kindOf(comptime T: type) Kind {
    return switch (@typeInfo(T)) {
        .int => |info| if (info.bits > 64)
            @compileError("RawDoFmt: " ++ @typeName(T) ++ " is wider than 64 bits")
        else if (info.bits > 32) .long else .word,
        .comptime_int => .word,
        .null => .string,
        .pointer => if (isString(T)) .string else .pointer,
        .optional => |info| switch (@typeInfo(info.child)) {
            .pointer => if (isString(info.child)) .string else .pointer,
            else => @compileError("RawDoFmt: no stream form for " ++ @typeName(T)),
        },
        else => @compileError("RawDoFmt: no stream form for " ++ @typeName(T)),
    };
}

/// A compile error unless `format` and `Args` (a tuple type) fit together
/// as RawDoFmt reads them: one value per conversion, a 32-bit or smaller
/// integer for %d %u %x %c, a wider one for %ld %lu %lx %lc, and a
/// NUL-terminated string (or null) for %s.
pub fn checkFormat(comptime format: []const u8, comptime Args: type) void {
    comptime {
        @setEvalBranchQuota(1000 + 10 * format.len);
        const fields = @typeInfo(Args).@"struct".fields;
        var used: usize = 0;
        var i: usize = 0;
        while (i < format.len) {
            const c = format[i];
            i += 1;
            if (c != '%') continue;
            if (i < format.len and format[i] == '-') i += 1;
            while (i < format.len and std.ascii.isDigit(format[i])) i += 1;
            if (i < format.len and format[i] == '.') {
                i += 1;
                while (i < format.len and std.ascii.isDigit(format[i])) i += 1;
            }
            const long = i < format.len and format[i] == 'l';
            if (long) i += 1;
            if (i >= format.len) break;
            const conversion = format[i];
            i += 1;
            const want: Kind = switch (conversion) {
                'd', 'D', 'u', 'U', 'x', 'X', 'c' => if (long) .long else .word,
                's' => .string,
                else => continue, // %% and unknown conversions take no value
            };
            if (used == fields.len) @compileError("format \"" ++ format ++ "\": more conversions than values");
            const T = fields[used].type;
            if (kindOf(T) != want) @compileError(std.fmt.comptimePrint(
                "format \"{s}\": value {d} ({s}) doesn't fit %{s}{c}",
                .{ format, used + 1, @typeName(T), if (long) "l" else "", conversion },
            ));
            used += 1;
        }
        if (used != fields.len) @compileError("format \"" ++ format ++ "\": more values than conversions");
    }
}

/// The data stream for `args`, a tuple: integers of up to 32 bits as 4
/// bytes (sign- or zero-extended), 64-bit ones as 8, pointers (strings for
/// `%s`) as a usize, and null as a null pointer, packed in order.
pub fn fmtStream(args: anytype) [streamSize(@TypeOf(args))]u8 {
    var out: [streamSize(@TypeOf(args))]u8 = undefined;
    var at: usize = 0;
    inline for (args) |arg| {
        const T = @TypeOf(arg);
        switch (comptime kindOf(T)) {
            .word => {
                const V = if (T == comptime_int) (if (arg < 0) i32 else u32) else if (@typeInfo(T).int.signedness == .signed) i32 else u32;
                std.mem.writeInt(V, out[at..][0..4], arg, native);
                at += 4;
            },
            .long => {
                const V = if (@typeInfo(T).int.signedness == .signed) i64 else u64;
                std.mem.writeInt(V, out[at..][0..8], arg, native);
                at += 8;
            },
            .string, .pointer => {
                std.mem.writeInt(usize, out[at..][0..@sizeOf(usize)], addressOf(arg), native);
                at += @sizeOf(usize);
            },
        }
    }
    return out;
}

fn addressOf(arg: anytype) usize {
    return switch (@typeInfo(@TypeOf(arg))) {
        .pointer => |info| if (info.size == .slice) @intFromPtr(arg.ptr) else @intFromPtr(arg),
        .optional => if (arg) |p| addressOf(p) else 0,
        else => 0,
    };
}

fn streamSize(comptime Args: type) usize {
    var size: usize = 0;
    for (@typeInfo(Args).@"struct".fields) |field| {
        size += switch (kindOf(field.type)) {
            .word => 4,
            .long => 8,
            .string, .pointer => @sizeOf(usize),
        };
    }
    return size;
}

/// debug.lib's kprintf: `format` with `args` (a tuple, checked against the
/// format at compile time) through RawDoFmt to RawPutChar, the raw serial
/// output. For debugging; it works in interrupts and with task switching
/// off.
pub fn kprintf(sys: *ExecBase, comptime format: [:0]const u8, args: anytype) void {
    comptime checkFormat(format, @TypeOf(args));
    const stream = fmtStream(args);
    _ = sys.RawDoFmt(format, &stream, &rawPut, sys);
}

fn rawPut(c: u8, put_ch_data: ?*anyopaque) callconv(.c) void {
    if (c == 0) return; // the final NUL
    const sys: *ExecBase = @ptrCast(put_ch_data.?);
    sys.RawPutChar(c);
}
