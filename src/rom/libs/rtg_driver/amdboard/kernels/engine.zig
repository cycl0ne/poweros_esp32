// SPDX-License-Identifier: MPL-2.0
//! The board's kernels for the graphics block's compute engine, built by
//! the build's own compiler (`poweros_sdk.addGPUCode`) into the code
//! object the board embeds, loads and runs (`../kernels.zig`): pixels
//! laid over a rectangle, a colour laid over one, a picture scaled into
//! one, a shape and a tile in two colours - each pixel as
//! graphics.library makes it (`jobs.zig`, `pixels.zig`).
//!
//! Each takes its job as its one argument, the structure the board fills
//! in, and is dispatched over the job's rectangle in groups of 64
//! threads: a row of groups for each row of the rectangle, as many as the
//! spans of 64 pixels of the buffer's memory a row of it can reach into,
//! `(width + 126) / 64`. A thread is handed column `group x * 64 + thread` of
//! row `group y`, and its job lays the groups on the buffer's memory and
//! finds its pixel (`jobs.zig`); a thread with none does nothing. The
//! three that lay what they land on go through their job's marks
//! (`jobs.layOnce`), so that a wave lays its pixels once however often
//! the job runs.

const jobs = @import("jobs.zig");

inline fn column() u32 {
    return @workGroupId(0) *% jobs.group +% @workItemId(0);
}

inline fn row() u32 {
    return @workGroupId(1);
}

export fn blend_pixels(job: jobs.BlendPixels) callconv(.kernel) void {
    jobs.layOnce(.global, jobs.blendPixels, job, column(), row());
}

export fn blend_rect(job: jobs.BlendRect) callconv(.kernel) void {
    jobs.layOnce(.global, jobs.blendRect, job, column(), row());
}

export fn scale_pixels(job: jobs.ScalePixels) callconv(.kernel) void {
    jobs.layOnce(.global, jobs.scalePixels, job, column(), row());
}

export fn blit_template(job: jobs.BlitTemplate) callconv(.kernel) void {
    jobs.blitTemplate(.global, job, column(), row());
}

export fn blit_pattern(job: jobs.BlitPattern) callconv(.kernel) void {
    jobs.blitPattern(.global, job, column(), row());
}
