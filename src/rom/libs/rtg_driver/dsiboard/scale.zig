// SPDX-License-Identifier: MPL-2.0
//! The DSI board's engine scaling a picture over an RGB565 buffer:
//! ScalePixels on the PPA's scaler, then its blend unit.
//!
//! The scaler's factors are a whole number and sixteenths each way, so
//! it takes a job only when both sizes are reached exactly: the
//! rectangle's width times 16 a whole multiple of the part's width, and
//! the same for the heights - a half, a double, three quarters. Its
//! macro-blocks land wherever they fall, so it does not write the buffer:
//! it scales into a block of ARGB8888 of the driver's own, allocated for
//! the job with its rows a whole number of cache lines, and that block is
//! then laid over the rectangle as BlendPixels lays a picture
//! (`blend.zig`) - so coverage survives the scaling. The block's lines
//! are written back before the scaler runs and dropped after, so what the
//! CPU then reads of it is what the scaler wrote.
//!
//! Anything else - a ratio between the steps, a format the scaler has no
//! mode for, a picture the 2D-DMA cannot read, no memory for the block,
//! a job too small to be worth it - is answered RTGERR_NOT_SUPPORTED.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const err = rtg.errors;
const ExecBase = sdk.interface.exec.ExecBase;
const dma2d = @import("dma2d.zig");
const ppa = @import("ppa.zig");
const engine_file = @import("engine.zig");
const blend = @import("blend.zig");
const Engine = engine_file.Engine;

/// The largest factor: 255 and fifteen sixteenths.
const largest_sixteenths = 256 * 16 - 1;

/// ScalePixels: the rectangle lies inside the buffer. `watched` as for
/// `engine.fill`.
pub fn scalePixels(engine: *Engine, sys: *ExecBase, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, width: u32, height: u32, watched: bool) i32 {
    if (!engine.ready or !engine_file.lined(dest)) return err.RTGERR_NOT_SUPPORTED;
    const out_width: u32 = @intCast(area.width);
    const out_height: u32 = @intCast(area.height);
    if (out_width * 16 % width != 0 or out_height * 16 % height != 0) return err.RTGERR_NOT_SUPPORTED;
    const x16 = out_width * 16 / width;
    const y16 = out_height * 16 / height;
    if (x16 == 0 or y16 == 0 or x16 > largest_sixteenths or y16 > largest_sixteenths) return err.RTGERR_NOT_SUPPORTED;
    if (out_width * out_height < engine.smallest_blend) return err.RTGERR_NOT_SUPPORTED;
    if (out_width > dma2d.field_max or out_height > dma2d.field_max) return err.RTGERR_NOT_SUPPORTED;
    const picture = blend.pictureOf(pixels, width, height, 255) orelse return err.RTGERR_NOT_SUPPORTED;

    // The block, its rows whole cache lines.
    const line = engine_file.line_bytes;
    const pitch = (out_width * 4 + line - 1) / line * line;
    const block_bytes = pitch * out_height;
    const memory = sys.AllocMem(block_bytes + line, exec.MEMF_ANY) orelse return err.RTGERR_NOT_SUPPORTED;
    defer sys.FreeMem(memory, block_bytes + line);
    const block = (@intFromPtr(memory) + line - 1) & ~@as(usize, line - 1);
    if (!engine_file.reachable(block, @as(u64, block) + block_bytes)) return err.RTGERR_NOT_SUPPORTED;

    sys.ObtainSemaphore(&engine.lock);
    defer sys.ReleaseSemaphore(&engine.lock);
    const source_end = picture.first_row + @as(usize, height - 1) * picture.pitch + @as(usize, picture.column + width) * picture.source.bytes;
    engine_file.writeBackSpan(sys, picture.first_row + @as(usize, picture.column) * picture.source.bytes, source_end);
    engine_file.writeBackSpan(sys, block, block + block_bytes);

    const parts = engine_file.descriptors(engine);
    ppa.resetScaler();
    if (!dma2d.connectOut(0, dma2d.peri_ppa_srm)) return engine_file.failed(engine);
    dma2d.portBlock(0, ppa.port_block, ppa.port_block);
    if (!dma2d.connectIn(dma2d.peri_ppa_srm, false)) return engine_file.failed(engine);
    dma2d.describe(parts.send, picture.first_row, picture.width, height, picture.column, 0, width, height, picture.source.pbyte);
    // The scaler says where each of its blocks goes; the descriptor only
    // names the picture they go into.
    dma2d.describe(parts.receive, block, pitch / 4, out_height, 0, 0, 2, 2, 0);
    const signal = engine_file.prepare(engine, sys, watched);
    dma2d.runOut(0, parts.send_at);
    dma2d.runIn(parts.receive_at);
    ppa.scale(picture.source.cm, picture.source.swap, x16, y16, height, out_width);
    const done = engine_file.wait(engine, sys, signal);
    var bytes: u32 = block_bytes;
    sys.CachePostDMA(@ptrFromInt(block), &bytes, 0);
    if (!done) return engine_file.failed(engine);

    const scaled = blend.Picture{
        .first_row = block,
        .pitch = pitch,
        .width = pitch / 4,
        .column = 0,
        .source = blend.sourceOf(.bgra32).?,
        .alpha = 255,
    };
    const laid = blend.lay(engine, sys, dest, area, scaled, watched);
    if (laid == err.RTGERR_OK) engine.scales +%= 1;
    return laid;
}
