// SPDX-License-Identifier: MPL-2.0
//! info: what machine this is, from platform.resource - the same answers
//! `C:Platform` prints, so there is one source of truth and not two - with
//! the board's name from expansion.library. The stack pointer is the
//! shell's own and belongs to nobody else, so it is read here.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const cpu = @import("../../../../../arch/esp32s3/cpu.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const platform = sdk.resources.platform;
const st = sdk.expansion.systemtags;

pub const name = "info";
pub const usage = "info";
pub const help =
    \\  info                 CPU, clocks and memory layout
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    const sys = shell.base.iface();
    const resource = sys.OpenResource(platform.PLATFORMNAME) orelse {
        shell.print("no %s\n", .{platform.PLATFORMNAME});
        return;
    };
    const pr: *sdk.interface.platform.PlatformBase = @ptrCast(@alignCast(resource));
    var p: platform.PlatformInfo = .{};
    _ = pr.GetPlatformInfo(&p, @sizeOf(@TypeOf(p)));

    const board: [*:0]const u8 = @ptrFromInt(_shell.boardFact(shell, st.SYSTAG_Name, @intFromPtr("(no name)")));
    shell.print("board    %s\n", .{board});
    shell.print("chip     %s, %s, PRID 0x%04x\n", .{ p.chip.?, p.core.?, p.prid & 0xFFFF });
    shell.print("clock    %d MHz CPU (configured %d, measured %d), %d Hz tick on CCOMPARE0 (irq %d)\n", .{
        pr.CpuClock() / 1_000_000,
        p.cpu_hz / 1_000_000,
        p.measured_cpu_hz / 1_000_000,
        p.tick_hz,
        p.tick_irq,
    });
    shell.print("vecbase  0x%08x\n", .{p.vecbase});
    shell.print("iram     0x%08x-0x%08x  %d bytes code\n", .{ p.iram_lower, p.iram_upper, p.iram_upper - p.iram_lower });
    shell.print("dram     0x%08x-0x%08x  %d bytes data+bss\n", .{ p.dram_lower, p.dram_upper, p.dram_upper - p.dram_lower });
    shell.print("flash    0x%08x-0x%08x  %d KiB code\n", .{ p.flash_text_lower, p.flash_text_upper, (p.flash_text_upper - p.flash_text_lower) / 1024 });
    shell.print("ram      internal %d KiB free, external %d KiB free (see avail)\n", .{ sys.AvailMem(sdk.exec.MEMF_INTERNAL) / 1024, sys.AvailMem(sdk.exec.MEMF_EXTERNAL) / 1024 });
    if (p.psram_size != 0) {
        shell.print("psram    0x%08x-0x%08x  %d MiB octal, vendor 0x%02x\n", .{ p.psram_base, p.psram_base + p.psram_size, p.psram_size >> 20, p.psram_vendor });
    }
    shell.print("stack    0x%08x-0x%08x  sp 0x%08x\n", .{ p.stack_lower, p.stack_upper, cpu.stackPointer() });
    shell.print("built    %s\n", .{p.built.?});
}
