// SPDX-License-Identifier: MIT
//! A surface: where a swapchain's pictures are shown, and what shows them.
//!
//! What a surface is over - a screen (`screen.zig`) or a window
//! (`window.zig`) - is behind its `Ops`: its size and format, the buffers
//! a swapchain's images are made over, and how one is shown. The
//! swapchain (swapchain/) keeps which image is where; the ops only do
//! what is asked. The host tests give a surface ops of their own.

const sdk = @import("sdk");
const facet = sdk.facet;
const PixelFormat = sdk.rtg.bitmaps.PixelFormat;
const Instance = @import("../instance/_instance.zig").Instance;
const _image = @import("../image/_image.zig");
const Swapchain = @import("../swapchain/_swapchain.zig").Swapchain;

pub const Surface = struct {
    instance: *Instance,
    ops: *const Ops,
    /// What the ops keep: `screen.zig`'s Screen, `window.zig`'s Window.
    context: ?*anyopaque = null,
    /// The swapchain made on it last and not handed on, or null; and how
    /// many of its swapchains are not yet destroyed, handed on or not.
    swapchain: ?*Swapchain = null,
    swapchains: u32 = 0,
    /// What a swapchain's pictures in the machine's memory are allocated
    /// with: what the device it is made for can reach.
    picture_memory: u32 = sdk.exec.MEMF_ANY,
};

/// A surface's size and the format of its pixels now.
pub const Shape = struct {
    width: u32,
    height: u32,
    /// `undefined` for pixels facet.library cannot draw.
    format: facet.Format,
};

/// A buffer a swapchain's image is made over.
pub const Picture = struct {
    pixels: [*]u8 = undefined,
    pitch: u32 = 0,
    /// The ops' own: the screen's ScreenBuffer, the window's picture.
    handle: ?*anyopaque = null,
    /// Where what is drawn into it is handed on to.
    display: ?_image.Display = null,
    /// What the display shows as the swapchain is made.
    shown: bool = false,
};

pub const Ops = struct {
    /// What `show` does with a buffer: copies it out, so that it is free
    /// again as soon as it is shown and the display never reads it, or
    /// hands it to the display, which reads it until another is shown.
    copies: bool = false,
    /// Null once what the surface is over has gone - its window closed:
    /// the surface is lost, and stays so.
    shape: *const fn (surface: *Surface) ?Shape,
    /// The most buffers a swapchain could be given.
    most: *const fn (surface: *Surface) u32,
    /// `pictures.len` buffers of the surface's shape made: false, and
    /// none, when there is no room for them all.
    make: *const fn (surface: *Surface, pictures: []Picture) bool,
    /// The buffers given back, `shown` the one the display shows now.
    unmake: *const fn (surface: *Surface, pictures: []Picture, shown: ?u32) void,
    /// The buffer shown, from the display's next frame on: returns when
    /// the display has taken it up, and no sooner than a frame from now
    /// where it is not taken up at all - the screen behind another, or
    /// the buffer shown already. False, and nothing shown, on a surface
    /// lost.
    show: *const fn (surface: *Surface, picture: *Picture) bool,
    /// What the surface kept given back, as it goes.
    close: *const fn (surface: *Surface) void,
};

/// A format facet.library draws in: the two 32-bit orders a display has,
/// and 565.
pub fn drawable(format: facet.Format) bool {
    return format == .b8g8r8a8_unorm or format == .r8g8b8a8_unorm or format == .r5g6b5_unorm_pack16;
}

/// A display's pixels as a format: `undefined` for those facet.library
/// cannot draw.
pub fn formatOf(pixels: PixelFormat) facet.Format {
    return switch (pixels) {
        .bgra32 => .b8g8r8a8_unorm,
        .rgba32 => .r8g8b8a8_unorm,
        .rgb565 => .r5g6b5_unorm_pack16,
        else => .undefined,
    };
}

/// What a swapchain's images can be used for: drawn into.
pub const usage = facet.IMAGE_USAGE_COLOR_ATTACHMENT;
