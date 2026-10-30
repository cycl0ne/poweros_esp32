// SPDX-License-Identifier: MPL-2.0
//! The cores' clock on the Compute Module 5 (`boards.cpu_clock`): the
//! VideoCore's firmware sets it, and the cores' supply with it, when it is
//! asked through its mailbox - as Linux's cpufreq asks it. Unasked, it
//! leaves them at 1 GHz. It takes them no faster than config.txt's
//! arm_freq allows - 2.4 GHz unless that says less - and slows them by
//! itself while the chip is too hot or its supply sags.

const sdk = @import("sdk");
const exec = sdk.exec;
const videocore = sdk.hardware.videocore;
const ExecBase = sdk.interface.exec.ExecBase;
const system = @import("system.zig");

const TAG_GET_MAX_CLOCK_RATE: u32 = 0x0003_0004;
const TAG_SET_CLOCK_RATE: u32 = 0x0003_8002;
/// The firmware's number for the cores' clock.
const CLOCK_ARM: u32 = 3;
/// What holds the cores back, as the firmware says it (GET_THROTTLED):
/// the supply below 4.63 V, the clock capped, the cores throttled, the
/// chip at its soft temperature limit - each now; the same 16 bits up
/// since it started.
const TAG_GET_THROTTLED: u32 = 0x0003_0046;
const UNDER_VOLTAGE: u32 = 1 << 0;
const CAPPED: u32 = 1 << 1;
const THROTTLED: u32 = 1 << 2;
const SOFT_TEMP_LIMIT: u32 = 1 << 3;

fn reason(flags: u32) [*:0]const u8 {
    if (flags & UNDER_VOLTAGE != 0) return "its supply is too low (under-voltage)";
    if (flags & SOFT_TEMP_LIMIT != 0) return "the chip is too hot";
    return "it throttles the cores";
}

/// The cores at `mhz`, or as fast as the firmware lets them where that
/// is slower: the clock it set, in MHz; 0 when it did not answer, and the
/// clock is as it was. Where it holds them slower than that for now - a
/// supply that sags, a chip too hot - the log says why. The messages go
/// in MEMF_DMA, the RAM the firmware reads.
pub fn setCpuClock(sys: *ExecBase, mhz: u32) u32 {
    const bytes = 2 * videocore.buffer_bytes;
    const memory = sys.AllocMem(bytes, exec.MEMF_DMA) orelse return 0;
    defer sys.FreeMem(memory, bytes);
    const buffer = videocore.bufferIn(memory) orelse return 0;
    var most = [_]u32{ CLOCK_ARM, 0 };
    if (!videocore.call(sys, system.mailbox, buffer, TAG_GET_MAX_CLOCK_RATE, &most)) return 0;
    var rate = [_]u32{ CLOCK_ARM, @min(mhz * 1_000_000, most[1]), 0 };
    if (!videocore.call(sys, system.mailbox, buffer, TAG_SET_CLOCK_RATE, &rate)) return 0;
    var held = [_]u32{0};
    if (videocore.call(sys, system.mailbox, buffer, TAG_GET_THROTTLED, &held) and held[0] & (CAPPED | THROTTLED) != 0) {
        exec.kprintf(sys, "cpu clock held back by the firmware: %s\n", .{reason(held[0])});
    }
    return rate[1] / 1_000_000;
}
