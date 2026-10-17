// SPDX-License-Identifier: MPL-2.0
//! trap [skip|off]: trap code on the shell's task that steps over the
//! instruction that faulted, or none, and how many it has skipped.

const builtin = @import("builtin");
const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const trap = @import("../../../../../arch/arch.zig").trap;
const Shell = _shell.Shell;
const Args = _shell.Args;

/// Trap code: step over the faulting instruction - on Xtensa 2 bytes for
/// the narrow instructions (op0 8-13), otherwise 3; on RISC-V 4 bytes
/// when the low two bits are 11, otherwise 2 (the C extension's). Written
/// to the raw port: this runs in the exception, which may not wait for
/// the console.
fn skipTrap(info: *sdk.exec.TrapInfo, data: ?*anyopaque) callconv(.c) i32 {
    const shell: *Shell = @ptrCast(@alignCast(data.?));
    shell.skipped_traps += 1;
    // Instruction memory only takes aligned 32-bit loads.
    const word = @as(*const volatile u32, @ptrFromInt(info.pc & ~@as(usize, 3))).*;
    const low: u8 = @truncate(word >> @intCast((info.pc & 3) * 8));
    const length: usize = if (comptime builtin.cpu.arch.isRISCV())
        (if (low & 3 == 3) 4 else 2)
    else if (low & 0xF >= 8 and low & 0xF <= 13) 2 else 3;
    sdk.exec.kprintf(shell.base.iface(), "[trap] %s at 0x%08zx skipped (%zd-byte instruction)\n", .{ trap.causeName(info.number), info.pc, length });
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
