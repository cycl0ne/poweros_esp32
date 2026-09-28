// SPDX-License-Identifier: MIT
//! The panic handler of everything built with the SDK for the disk: a
//! failed safety check - an overflow, an index out of bounds, a null
//! unwrapped - becomes a dead-end alert that says which check failed and
//! where. `sdk/program.zig` installs it as the program's `panic`.
//!
//! A panic handler is handed no base, so it finds exec through
//! `AbsExecBase`, formats the check's values with `RawDoFmt` into a buffer
//! on the stack, and raises `AN_ProgramPanic` with `AlertAt` - both
//! through the jump table like any other call. The Guru then names the
//! file the check is in and the offset into it.

const alerts = @import("alerts.zig");
const exec = @import("exec.zig");
const fmt = @import("fmt.zig");

/// Zig's panic interface: one function per safety check, and `call` for
/// `@panic` and the checks that carry no values. Each is `noinline`, so
/// that `@returnAddress()` is the failed check's and the text buffer stays
/// out of the frames of the functions that check.
pub const panic = struct {
    pub noinline fn call(msg: []const u8, ret_addr: ?usize) noreturn {
        @branchHint(.cold);
        var text: [text_size]u8 = undefined;
        const length = @min(msg.len, text.len - 1);
        @memcpy(text[0..length], msg[0..length]);
        text[length] = 0;
        raise(&text, ret_addr orelse @returnAddress());
    }
    pub noinline fn sentinelMismatch(expected: anytype, found: @TypeOf(expected)) noreturn {
        @branchHint(.cold);
        _ = found;
        call("sentinel mismatch", @returnAddress());
    }
    pub noinline fn unwrapError(err: anyerror) noreturn {
        @branchHint(.cold);
        values("attempt to unwrap error: %.48s", struct { [*:0]const u8 }, @intFromPtr(@errorName(err).ptr), 0, @returnAddress());
    }
    pub noinline fn outOfBounds(index: usize, len: usize) noreturn {
        @branchHint(.cold);
        values("index out of bounds: index %u, len %u", struct { u32, u32 }, index, len, @returnAddress());
    }
    pub noinline fn startGreaterThanEnd(start: usize, end: usize) noreturn {
        @branchHint(.cold);
        values("start index %u is larger than end index %u", struct { u32, u32 }, start, end, @returnAddress());
    }
    pub noinline fn inactiveUnionField(active: anytype, accessed: @TypeOf(active)) noreturn {
        @branchHint(.cold);
        values("access of union field '%.24s' while field '%.24s' is active", struct { [*:0]const u8, [*:0]const u8 }, @intFromPtr(@tagName(accessed).ptr), @intFromPtr(@tagName(active).ptr), @returnAddress());
    }
    pub noinline fn sliceCastLenRemainder(src_len: usize) noreturn {
        @branchHint(.cold);
        values("slice length %u does not divide exactly into destination elements", struct { u32 }, src_len, 0, @returnAddress());
    }
    pub noinline fn reachedUnreachable() noreturn {
        @branchHint(.cold);
        call("reached unreachable code", @returnAddress());
    }
    pub noinline fn unwrapNull() noreturn {
        @branchHint(.cold);
        call("attempt to use null value", @returnAddress());
    }
    pub noinline fn castToNull() noreturn {
        @branchHint(.cold);
        call("cast causes pointer to be null", @returnAddress());
    }
    pub noinline fn incorrectAlignment() noreturn {
        @branchHint(.cold);
        call("incorrect alignment", @returnAddress());
    }
    pub noinline fn invalidErrorCode() noreturn {
        @branchHint(.cold);
        call("invalid error code", @returnAddress());
    }
    pub noinline fn integerOutOfBounds() noreturn {
        @branchHint(.cold);
        call("integer does not fit in destination type", @returnAddress());
    }
    pub noinline fn integerOverflow() noreturn {
        @branchHint(.cold);
        call("integer overflow", @returnAddress());
    }
    pub noinline fn shlOverflow() noreturn {
        @branchHint(.cold);
        call("left shift overflowed bits", @returnAddress());
    }
    pub noinline fn shrOverflow() noreturn {
        @branchHint(.cold);
        call("right shift overflowed bits", @returnAddress());
    }
    pub noinline fn divideByZero() noreturn {
        @branchHint(.cold);
        call("division by zero", @returnAddress());
    }
    pub noinline fn exactDivisionRemainder() noreturn {
        @branchHint(.cold);
        call("exact division produced remainder", @returnAddress());
    }
    pub noinline fn integerPartOutOfBounds() noreturn {
        @branchHint(.cold);
        call("integer part of floating point value out of bounds", @returnAddress());
    }
    pub noinline fn corruptSwitch() noreturn {
        @branchHint(.cold);
        call("switch on corrupt value", @returnAddress());
    }
    pub noinline fn shiftRhsTooBig() noreturn {
        @branchHint(.cold);
        call("shift amount is greater than the type size", @returnAddress());
    }
    pub noinline fn invalidEnumValue() noreturn {
        @branchHint(.cold);
        call("invalid enum value", @returnAddress());
    }
    pub noinline fn forLenMismatch() noreturn {
        @branchHint(.cold);
        call("for loop over objects with non-equal lengths", @returnAddress());
    }
    pub noinline fn copyLenMismatch() noreturn {
        @branchHint(.cold);
        call("source and destination arguments have non-equal lengths", @returnAddress());
    }
    pub noinline fn memcpyAlias() noreturn {
        @branchHint(.cold);
        call("@memcpy arguments alias", @returnAddress());
    }
    pub noinline fn noreturnReturned() noreturn {
        @branchHint(.cold);
        call("'noreturn' function returned", @returnAddress());
    }
};

/// The text buffer, on a stack that may be nearly spent: the longest
/// message with its values fits.
/// The text buffer, on a stack that may be nearly spent: the longest
/// message with its values fits.
const text_size = 112;

/// SysBase, from the one word that holds it for code without a base.
fn sysBase() *exec.ExecBase {
    const cell: *const volatile *exec.ExecBase = exec.AbsExecBase;
    return cell.*;
}

/// A check with up to two values, each a word or a string: `format`
/// checked at compile time against `Args`, the values' types, and the
/// values handed on as words.
inline fn values(comptime format_string: [:0]const u8, comptime Args: type, first: usize, second: usize, where: usize) noreturn {
    comptime fmt.checkFormat(format_string, Args);
    report(format_string, first, second, where);
}

/// The two words as RawDoFmt's stream - a word and a string pointer are
/// both 32 bits here - into the buffer, then the alert. One function for
/// every check, not one per format.
noinline fn report(format_string: [*:0]const u8, first: usize, second: usize, where: usize) noreturn {
    const stream = [2]u32{ @truncate(first), @truncate(second) };
    var text: [text_size]u8 = undefined;
    _ = sysBase().RawDoFmt(format_string, &stream, null, &text);
    raise(&text, where);
}

/// The dead-end alert, `AN_ProgramPanic` at `where` with the text. It does
/// not return.
noinline fn raise(text: *const [text_size]u8, where: usize) noreturn {
    sysBase().AlertAt(alerts.AT_DeadEnd | alerts.AN_ProgramPanic, where, @ptrCast(text));
    while (true) {} // a dead-end alert doesn't come back
}
