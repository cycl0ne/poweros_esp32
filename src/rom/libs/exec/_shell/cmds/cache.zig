// SPDX-License-Identifier: MPL-2.0
//! cache [e <addr> <len> [i|d|id] | dma <addr> <len> [read]]: exec's cache
//! functions; alone, CacheClearU.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "cache";
pub const usage = "cache [e <addr> <len> [i|d|id] | dma <addr> <len> [read]]";
pub const help =
    \\  cache                CacheClearU: DCache written back, ICache invalidated
    \\  cache e <addr> <len> [i|d|id]   CacheClearE on a range (default id)
    \\  cache dma <addr> <len> [read]   CachePreDMA, then CachePostDMA
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const sys = shell.base.iface();
    const word = args.next() orelse {
        sys.CacheClearU();
        shell.print("CacheClearU: DCache written back, ICache invalidated\n", .{});
        return;
    };
    const clear = _shell.same(word, "e");
    if (!clear and !_shell.same(word, "dma")) return error.Usage;
    const at = try args.number();
    var length = try args.number();
    if (at == 0) return error.Usage;
    const address: *anyopaque = @ptrFromInt(at);
    const option = args.next();
    if (clear) {
        var caches: u32 = 0;
        for (option orelse "id") |c| switch (c) {
            'i' => caches |= sdk.exec.CACRF_ClearI,
            'd' => caches |= sdk.exec.CACRF_ClearD,
            else => return error.Usage,
        };
        sys.CacheClearE(address, length, caches);
        shell.print("CacheClearE 0x%08x, %d bytes: done\n", .{ at, length });
    } else {
        var flags: u32 = 0;
        if (option) |how| {
            if (!_shell.same(how, "read")) return error.Usage;
            flags = sdk.exec.DMAF_ReadFromRAM;
        }
        const dma = sys.CachePreDMA(address, &length, flags);
        sys.CachePostDMA(address, &length, flags);
        shell.print("CachePreDMA: DMA at 0x%08x, %d bytes; CachePostDMA: done\n", .{ @intFromPtr(dma), length });
    }
}
