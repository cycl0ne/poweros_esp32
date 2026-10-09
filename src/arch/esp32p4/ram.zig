// SPDX-License-Identifier: MPL-2.0
//! The chip's free RAM, handed to exec as memory regions: L2MEM's two free
//! parts on a chip before v3.0 - below the ROM's reserved area, after the
//! kernel, and above it, below the L2 cache - and the PSRAM.
//!
//! L2MEM is internal memory and every DMA engine reaches it. It has the
//! lower priority, so MEMF_ANY takes PSRAM first and L2MEM stays free for
//! what only it can do.

const exec = @import("../../rom/libs/exec/exec.zig");
const hardware = @import("sdk").hardware;
const layout = @import("layout.zig");
const psram = @import("psram.zig");

/// The ROM's reserved area ends here; the high part starts.
const high_start = 0x4FF4_0000;
/// The top of L2MEM, where the L2 cache ends.
const l2mem_end = hardware.map.DRAM_END;
/// CACHE_L2_CACHE_CACHESIZE_CONF: one bit for the L2 cache's size, bit n
/// for 256 << n bytes.
const l2_cache_size_conf = hardware.map.CACHE + 0x278;

const internal = exec.MEMF_INTERNAL | exec.MEMF_DMA;
const internal_pri = -10;
/// PSRAM behind the caches: the bulk of the memory.
const external = exec.MEMF_EXTERNAL;
const external_pri = 0;

pub const max_regions = 3;

/// The L2 cache's size, as the ROM set it: 128, 256 or 512 KiB on these
/// chips. Anything else read there is taken as the largest, so that no
/// memory the cache may hold is ever handed out.
pub fn l2CacheSize() usize {
    const conf = l2CacheSizeConf();
    const largest = l2mem_end - high_start;
    if (@popCount(conf) != 1) return largest;
    const size = @as(u64, 256) << @intCast(@ctz(conf));
    return if (size >= 128 * 1024 and size <= largest) @intCast(size) else largest;
}

/// CACHE_L2_CACHE_CACHESIZE_CONF as it reads.
pub fn l2CacheSizeConf() u32 {
    return hardware.mmio.reg(l2_cache_size_conf).*;
}

/// Regions for the bootstrap. The first one also holds SysBase.
pub fn regions(buf: *[max_regions]exec.MemRegion) []const exec.MemRegion {
    var count: usize = 0;
    buf[count] = .{
        .name = "internal memory",
        .base = @ptrFromInt(layout.heapStart()),
        .size = layout.heapEnd() - layout.heapStart(),
        .attributes = internal,
        .pri = internal_pri,
    };
    count += 1;
    const high_end = l2mem_end -| l2CacheSize();
    if (high_end > high_start) {
        buf[count] = .{
            .name = "internal memory (high)",
            .base = @ptrFromInt(high_start),
            .size = high_end - high_start,
            .attributes = internal,
            .pri = internal_pri,
        };
        count += 1;
    }
    if (psram.size != 0) {
        buf[count] = .{
            .name = "external memory",
            .base = @ptrFromInt(psram.base),
            .size = psram.size,
            .attributes = external,
            .pri = external_pri,
        };
        count += 1;
    }
    return buf[0..count];
}
