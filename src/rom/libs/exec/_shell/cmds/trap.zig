// SPDX-License-Identifier: MPL-2.0
//! trap [skip|off]: trap code on the shell's task that steps over the
//! instruction that faulted, or none, and how many it has skipped.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const trap = @import("../../../../../arch/esp32s3/trap.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

/// Trap code: step over the faulting instruction (2 bytes for Xtensa's
/// narrow instructions, op0 8-13, otherwise 3).
fn skipTrap(info: *sdk.exec.TrapInfo, data: ?*anyopaque) callconv(.c) i32 {
    const shell: *Shell = @ptrCast(@alignCast(data.?));
    shell.skipped_traps += 1;
    // Instruction memory only takes aligned 32-bit loads.
    const word = @as(*const volatile u32, @ptrFromInt(info.pc & ~@as(usize, 3))).*;
    const op0: u4 = @truncate(word >> @intCast((info.pc & 3) * 8));
    const length: usize = if (op0 >= 8 and op0 <= 13) 2 else 3;
    shell.print("[trap] %s at 0x%08x skipped (%d-byte instruction)\n", .{ trap.causeName(info.number), info.pc, length });
    info.pc += length;
    return 1;
}

pub const name = "trap";
pub const usage = "trap [skip|off]";
pub const help =
    \\  trap [skip|off]      trap code that steps over faulting instructions
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const sys = shell.base.iface();
    if (args.next()) |word| {
        if (_shell.same(word, "skip")) {
            _ = sys.SetTrapCode(&skipTrap, shell);
        } else if (_shell.same(word, "off")) {
            _ = sys.SetTrapCode(null, null);
        } else return error.Usage;
    }
    const mode: [*:0]const u8 = if (sys.FindTask(null).?.trap_code == null) "none (Guru Meditation)" else "skip";
    shell.print("trap code: %s, %d exception(s) skipped\n", .{ mode, shell.skipped_traps });
}
