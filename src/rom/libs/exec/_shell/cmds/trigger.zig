// SPDX-License-Identifier: MPL-2.0
//! trigger [0-3]: raises "from CPU" interrupt source 79 + n, and counts
//! what exec dispatched for it and what ran after.
//!
//! The first time it runs it installs a server on source 79 and a handler
//! on source 80, which acknowledge the request; the server then Causes the
//! shell's software interrupt, the usual pattern of acknowledging in the
//! interrupt and doing the rest in a softint. Not at boot: two of twelve
//! CPU lines are too many to hold for a debugging command.

const sdk = @import("sdk");
const exec = @import("../../exec.zig");
const _shell = @import("../shell.zig");
const uptime = @import("../../../../../arch/esp32s3/timer.zig");
const reg = sdk.hardware.mmio.reg;
const intbits = sdk.hardware.intbits;
const Shell = _shell.Shell;
const Args = _shell.Args;

/// SYSTEM_CPU_INTR_FROM_CPU_n_REG: bit 0 raises source
/// INTB_FROM_CPU_INTR0 + n until it is cleared again (the sources are
/// level-triggered).
const from_cpu_reg = sdk.hardware.map.SYSTEM + 0x30;

fn acknowledge(int_number: u32) void {
    reg(from_cpu_reg + 4 * @as(usize, int_number - intbits.INTB_FROM_CPU_INTR0)).* = 0;
}

fn ackServer(data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    const shell: *Shell = @ptrCast(@alignCast(data.?));
    acknowledge(int_number);
    shell.base.iface().Cause(&shell.softint);
    return 1; // handled: end of chain
}

fn ackHandler(_: ?*anyopaque, int_number: u32) callconv(.c) void {
    acknowledge(int_number);
}

fn install(shell: *Shell) void {
    if (shell.trigger_installed) return;
    shell.trigger_installed = true;
    shell.trigger_server = .{
        .node = .{ .type = .interrupt, .name = "from-cpu server" },
        .data = shell,
        .code = sdk.exec.vec(ackServer),
    };
    shell.trigger_handler = .{
        .node = .{ .type = .interrupt, .name = "from-cpu handler" },
        .code = sdk.exec.vec(ackHandler),
    };
    const sys = shell.base.iface();
    sys.AddIntServer(intbits.INTB_FROM_CPU_INTR0, &shell.trigger_server);
    _ = sys.SetIntVector(intbits.INTB_FROM_CPU_INTR0 + 1, &shell.trigger_handler);
}

pub const name = "trigger";
pub const usage = "trigger [0-3]";
pub const help =
    \\  trigger [0-3]        raise "from CPU" interrupt source 79 + n
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const n = try args.numberOr(0);
    if (n > 3) return error.Usage;
    install(shell);
    const source = intbits.INTB_FROM_CPU_INTR0 + n;
    const vector = &shell.base.int_vects[source];
    if (!exec.inUse(vector)) {
        shell.print("nothing installed on source %d\n", .{source});
        return;
    }
    const count: *volatile u32 = &vector.count;
    const softints: *volatile u32 = &shell.softint_runs;
    const before = count.*;
    const soft_before = softints.*;
    reg(from_cpu_reg + 4 * @as(usize, n)).* = 1;
    const deadline = uptime.uptimeUs() + 1000;
    while (count.* == before and uptime.uptimeUs() < deadline) {}
    shell.print("source %d: %d interrupt(s) dispatched, %d software interrupt(s) run\n", .{ source, count.* - before, softints.* - soft_before });
}
