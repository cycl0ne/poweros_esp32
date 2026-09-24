// SPDX-License-Identifier: MPL-2.0
//! The board's free RAM, handed to exec as memory regions: the chip's own
//! SRAM and the PSRAM beside it.

const exec = @import("../../rom/libs/exec/exec.zig");
const layout = @import("layout.zig");
const psram = @import("psram.zig");

/// The ROM's boot stack (_stack_sentry.._stack in the ROM ELF). Free once
/// _start runs on our stack. The ROM's .data/.bss follow from 0x3FCED710
/// and must stay untouched: the ROM functions we call still use them.
const rom_stack_start = 0x3FCE_9710;
const rom_stack_end = 0x3FCE_B710;

/// Internal SRAM, all of it inside the window a DMA engine addresses. It has
/// the lower priority, so MEMF_ANY takes PSRAM first and this stays free for
/// what only it can do: descriptor chains, and anything the caches are
/// suspended over.
const internal = exec.MEMF_INTERNAL | exec.MEMF_DMA;
const internal_pri = -10;
/// PSRAM behind the data cache: the bulk of the memory.
const external = exec.MEMF_EXTERNAL;
const external_pri = 0;

pub const max_regions = 4;

/// Regions for the bootstrap. The first one also holds SysBase.
pub fn regions(buf: *[max_regions]exec.MemRegion) []const exec.MemRegion {
    var n: usize = 0;
    buf[n] = .{
        .name = "internal memory",
        .base = @ptrFromInt(layout.heapStart()),
        .size = layout.heapEnd() - layout.heapStart(),
        .attributes = internal,
        .pri = internal_pri,
    };
    n += 1;
    buf[n] = .{
        .name = "internal memory (rom stack)",
        .base = @ptrFromInt(rom_stack_start),
        .size = rom_stack_end - rom_stack_start,
        .attributes = internal,
        .pri = internal_pri,
    };
    n += 1;
    if (psram.spare_sram.len != 0) {
        buf[n] = .{
            .name = "internal memory (cache spare)",
            .base = psram.spare_sram.ptr,
            .size = psram.spare_sram.len,
            .attributes = internal,
            .pri = internal_pri,
        };
        n += 1;
    }
    if (psram.size != 0) {
        buf[n] = .{
            .name = "external memory",
            .base = @ptrFromInt(psram.base),
            .size = psram.size,
            .attributes = external,
            .pri = external_pri,
        };
        n += 1;
    }
    return buf[0..n];
}
