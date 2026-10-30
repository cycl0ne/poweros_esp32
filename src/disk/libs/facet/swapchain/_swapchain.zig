// SPDX-License-Identifier: MIT
//! A swapchain: the images a surface shows, and where each of them is.
//!
//! An image is `free` - the program may have it next - `acquired` by the
//! program, `presenting` - handed to the queue to be shown once what it
//! waits for is done - or `shown`, the one the display reads. When the
//! queue's task has shown an image (the surface's `show`, which returns
//! when the display has taken it up), the one shown before comes free,
//! and `freed` wakes whoever waits in AcquireNextImage. A swapchain of
//! one image hands out the image shown: it is drawn while it is seen. On
//! a surface that copies what it shows - a window - none is ever shown:
//! an image is free again once copied. A surface lost - its window closed
//! while the swapchain was in use - shows nothing more: what was presented
//! comes free unshown, and the program is told the surface is lost.
//!
//! Everything here changes under `lock`; the queue's task and the program
//! both take it.

const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const ExecBase = sdk.interface.exec.ExecBase;
const Device = @import("../device/_device.zig").Device;
const _image = @import("../image/_image.zig");
const Image = _image.Image;
const _surface = @import("../surface/_surface.zig");
const Surface = _surface.Surface;
const Picture = _surface.Picture;

/// The most images a swapchain has, and the most swapchains a present
/// shows an image of.
pub const max_images = 4;
pub const max_presents = 8;

pub const State = enum { free, acquired, presenting, shown };

pub const Swapchain = struct {
    device: *Device,
    surface: *Surface,
    width: u32,
    height: u32,
    format: facet.Format,
    count: u32,
    /// Handed on to a newer swapchain: no more images handed out.
    retired: bool = false,
    lock: exec.SignalSemaphore = .{},
    /// Signalled when an image comes free.
    freed: exec.Waitable = .{},
    /// Images handed to the queue and not yet shown.
    presenting: u32 = 0,
    images: [max_images]Image = undefined,
    pictures: [max_images]Picture = @splat(.{}),
    states: [max_images]State = @splat(.free),
};

/// The images made over the pictures, which the surface has made.
pub fn lay(swapchain: *Swapchain, sys: *ExecBase, usage: u32) void {
    sys.InitSemaphore(&swapchain.lock);
    for (0..swapchain.count) |k| {
        const picture = &swapchain.pictures[k];
        swapchain.images[k] = .{
            .device = swapchain.device,
            .format = swapchain.format,
            .width = swapchain.width,
            .height = swapchain.height,
            .levels = 1,
            .usage = usage,
            .kind = .rows,
            .pitch = picture.pitch,
            .bytes = @as(u64, picture.pitch) * swapchain.height,
            .data = picture.pixels,
            .presentable = true,
            .display = picture.display,
        };
        swapchain.states[k] = if (picture.shown and !swapchain.surface.ops.copies) .shown else .free;
    }
}

/// Whether the surface still has the swapchain's shape.
pub const Fit = enum {
    current,
    /// Sized, or its pixels another format: a new swapchain is wanted.
    changed,
    /// What it was over has gone: nothing more is shown on it.
    lost,
};

pub fn fit(swapchain: *const Swapchain) Fit {
    const now = swapchain.surface.ops.shape(swapchain.surface) orelse return .lost;
    if (now.width != swapchain.width or now.height != swapchain.height or now.format != swapchain.format) return .changed;
    return .current;
}

/// What AcquireNextImage comes to: an image, or why not.
pub const Acquired = union(enum) {
    image: u32,
    /// None free, and none coming free: the program holds them all, or
    /// nothing it presented is still to be shown.
    none,
    /// None free in the time given.
    timeout,
    out_of_date,
    lost,
};

/// An image for the program, waiting up to `timeout` microseconds
/// (exec.WAIT_FOREVER: as long as it takes) for one to come free.
pub fn acquire(swapchain: *Swapchain, sys: *ExecBase, timeout: u64) Acquired {
    const freed = [1]*exec.Waitable{&swapchain.freed};
    var waited = false;
    while (true) {
        sys.ObtainSemaphore(&swapchain.lock);
        const unfit: ?Acquired = if (swapchain.retired) .out_of_date else switch (fit(swapchain)) {
            .current => null,
            .changed => .out_of_date,
            .lost => .lost,
        };
        if (unfit) |answer| {
            sys.ReleaseSemaphore(&swapchain.lock);
            return answer;
        }
        if (free(swapchain)) |index| {
            swapchain.states[index] = .acquired;
            sys.ReleaseSemaphore(&swapchain.lock);
            return .{ .image = index };
        }
        const coming = swapchain.presenting != 0;
        sys.ResetWaitable(&swapchain.freed);
        sys.ReleaseSemaphore(&swapchain.lock);
        if (!coming) return .none;
        // A time given is waited out once: a lap after it that finds
        // nothing free gives up.
        if (timeout == 0 or (waited and timeout != exec.WAIT_FOREVER)) return .timeout;
        if (sys.WaitForAny(&freed, 1, timeout) == exec.WAIT_TIMEOUT) return .timeout;
        waited = true;
    }
}

/// The first image free; with one image, the one shown.
fn free(swapchain: *const Swapchain) ?u32 {
    for (swapchain.states[0..swapchain.count], 0..) |state, k| {
        if (state == .free or (swapchain.count == 1 and state == .shown)) return @intCast(k);
    }
    return null;
}

/// Image `index`, acquired, handed to the queue to be shown: false for
/// one the program does not hold.
pub fn hand(swapchain: *Swapchain, sys: *ExecBase, index: u32) bool {
    sys.ObtainSemaphore(&swapchain.lock);
    defer sys.ReleaseSemaphore(&swapchain.lock);
    if (index >= swapchain.count or swapchain.states[index] != .acquired) return false;
    swapchain.states[index] = .presenting;
    swapchain.presenting += 1;
    return true;
}

/// Image `index`, handed to the queue, the program's again: a present
/// that could not be put on the queue.
pub fn unhand(swapchain: *Swapchain, sys: *ExecBase, index: u32) void {
    sys.ObtainSemaphore(&swapchain.lock);
    defer sys.ReleaseSemaphore(&swapchain.lock);
    swapchain.states[index] = .acquired;
    swapchain.presenting -= 1;
}

/// Handed on to a newer swapchain: whoever waits for an image is told.
pub fn retire(swapchain: *Swapchain, sys: *ExecBase) void {
    sys.ObtainSemaphore(&swapchain.lock);
    defer sys.ReleaseSemaphore(&swapchain.lock);
    swapchain.retired = true;
    sys.SignalWaitable(&swapchain.freed);
}

/// Image `index` given back to the swapchain unshown: a present that
/// could not go on.
pub fn giveBack(swapchain: *Swapchain, sys: *ExecBase, index: u32) void {
    sys.ObtainSemaphore(&swapchain.lock);
    defer sys.ReleaseSemaphore(&swapchain.lock);
    if (index < swapchain.count and swapchain.states[index] == .acquired) swapchain.states[index] = .free;
    sys.SignalWaitable(&swapchain.freed);
}

/// On the queue's task: image `index` shown, and the one shown before
/// it free - or, copied out or not shown at all on a surface lost, free
/// itself.
pub fn show(swapchain: *Swapchain, sys: *ExecBase, index: u32) void {
    const surface = swapchain.surface;
    const shown = surface.ops.show(surface, &swapchain.pictures[index]);
    sys.ObtainSemaphore(&swapchain.lock);
    defer sys.ReleaseSemaphore(&swapchain.lock);
    if (shown) for (swapchain.states[0..swapchain.count], 0..) |*state, k| {
        if (k != index and state.* == .shown) state.* = .free;
    };
    swapchain.states[index] = if (shown and !surface.ops.copies) .shown else .free;
    swapchain.presenting -= 1;
    sys.SignalWaitable(&swapchain.freed);
}

/// On the queue's task: image `index`, handed to the queue, free again
/// without being shown: what it holds may not be finished.
pub fn unshown(swapchain: *Swapchain, sys: *ExecBase, index: u32) void {
    sys.ObtainSemaphore(&swapchain.lock);
    defer sys.ReleaseSemaphore(&swapchain.lock);
    swapchain.states[index] = .free;
    swapchain.presenting -= 1;
    sys.SignalWaitable(&swapchain.freed);
}

/// The image the display shows, if one of the swapchain's.
pub fn shownImage(swapchain: *const Swapchain) ?u32 {
    for (swapchain.states[0..swapchain.count], 0..) |state, k| {
        if (state == .shown) return @intCast(k);
    }
    return null;
}
