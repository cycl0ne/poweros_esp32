// SPDX-License-Identifier: MPL-2.0
//! The pointer, laid into the buffers the panel is really fed from.
//!
//! The picture never holds the pointer. The copy channel brings the
//! picture into the small buffers in internal memory a stretch at a
//! time (`panel.zig`), and a stretch the pointer crosses has the pointer
//! laid over it there, after the copy has put it in and before the panel
//! reads it: the buffer being filled is the one the panel reads next, a
//! stretch's time - about 460 microseconds - after the copy starts, and the
//! copy takes about half of that.
//!
//! What says the copy is done is the copy channel's own end-of-transfer
//! interrupt, which is enabled only for a copy of a stretch the pointer
//! crosses - a few of a frame's sixty - or one with another copy owed
//! behind it, and switched off again by the server rather than cleared.
//! So the status bit stays for `refill`, which reads it to know whether
//! the copy before has finished; and when `startCopy` finds a lay still
//! owed - the refill interrupt came first - it lays it itself, the copy
//! being over by then.
//!
//! The lay is a masked copy of at most `RTG_POINTER_MAX` rows of a stretch,
//! from internal memory into internal memory. It runs from IRAM, where no
//! flash read can stand it still, with runtime safety off like the rest of
//! the stream's code.
//!
//! The ops change what the interrupts read, so each change is made with
//! interrupts off; none of them waits.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const err = rtg.errors;
const dmares = sdk.resources.dma;
const panel_feed = @import("panel.zig");
const Panel = panel_feed.Panel;

/// Whether the pointer is to be laid into a copy of stretch `stretch`.
pub fn crosses(panel: *Panel, stretch: u32) bool {
    if (!panel.pointer_shown) return false;
    const image = panel.pointer orelse return false;
    const lines: i32 = @intCast(panel.config.bounce_lines);
    const first = @as(i32, @intCast(stretch)) * lines;
    return panel.pointer_top < first + lines and panel.pointer_top + @as(i32, @intCast(image.height)) > first;
}

/// The lay owed to the copy that has just ended, if any, and the copy's
/// interrupt off. From the copy's own interrupt, or from `startCopy` when
/// that came first.
pub fn painted(panel: *Panel) void {
    if (panel.paint_pending) lay(panel);
    panel.paint_pending = false;
    if (panel.dma) |db| db.EnableDMAInts(panel.copy_channel, dmares.DMA_IN, 0);
}

/// The copy channel's end-of-transfer interrupt: a stretch the pointer
/// crosses is in its buffer, and the channel is free for a copy owed
/// behind it.
pub fn copyServer(is_data: ?*anyopaque, _: u32) callconv(.c) i32 {
    const panel: *Panel = @ptrCast(@alignCast(is_data.?));
    const db = panel.dma orelse return 0;
    if (db.DMAIntStatus(panel.copy_channel, dmares.DMA_IN) & dmares.DMAINTF_IN_SUC_EOF == 0) return 0;
    painted(panel);
    panel_feed.refill(panel);
    return 1;
}

/// The pointer over the part of the last stretch copied that it crosses,
/// in the buffer that stretch was copied into.
noinline fn lay(panel: *Panel) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    const image = panel.pointer orelse return;
    const width: i32 = @intCast(panel.config.setup.width);
    const lines: i32 = @intCast(panel.config.bounce_lines);
    const first = @as(i32, @intCast(panel.copy_stretch)) * lines;
    const top = panel.pointer_top;
    const left = panel.pointer_left;
    const y0 = @max(top, first);
    const y1 = @min(top + @as(i32, @intCast(image.height)), first + lines);
    const x0 = @max(left, 0);
    const x1 = @min(left + @as(i32, @intCast(image.width)), width);
    if (y0 >= y1 or x0 >= x1) return;
    const buffer = panel.bounce.? + @as(usize, panel.copy_into) * panel.bounce_bytes;
    var y = y0;
    while (y < y1) : (y += 1) {
        const image_y: u32 = @intCast(y - top);
        const into: [*]u16 = @ptrCast(@alignCast(buffer + @as(usize, @intCast(y - first)) * @as(usize, @intCast(width)) * 2));
        const from: [*]const u16 = @ptrCast(@alignCast(image.pixels + image_y * image.pitch));
        const mask = image.mask + image_y * image.mask_pitch;
        var x = x0;
        while (x < x1) : (x += 1) {
            const image_x: u32 = @intCast(x - left);
            if (mask[image_x >> 3] & (@as(u8, 0x80) >> @intCast(image_x & 7)) != 0) into[@intCast(x)] = from[image_x];
        }
    }
}

// --- the ops ----------------------------------------------------------------

pub fn setPointer(panel: *Panel, image: ?*const rtg.RtgPointerImage) i32 {
    if (image) |one| {
        if (one.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    }
    panel.sys.Disable();
    panel.pointer = image;
    panel.sys.Enable();
    return err.RTGERR_OK;
}

pub fn movePointer(panel: *Panel, left: i32, top: i32) void {
    panel.sys.Disable();
    panel.pointer_left = left;
    panel.pointer_top = top;
    panel.sys.Enable();
}

pub fn showPointer(panel: *Panel, show: bool) i32 {
    panel.sys.Disable();
    panel.pointer_shown = show;
    panel.sys.Enable();
    return err.RTGERR_OK;
}
