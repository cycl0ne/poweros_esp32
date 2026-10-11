// SPDX-License-Identifier: MPL-2.0
//! The pointer and the overlay - a dragged icon - over the picture the
//! DSI board streams.
//!
//! The screens never hold them. The stream reads the board's copy of what
//! is shown (`link.zig`) - over HDMI always, on a panel from the first
//! time a pointer or an overlay is to be seen - and the images are laid
//! into that copy after whatever puts rows there: bands shown, rows
//! refreshed. A move puts the picture back where the image was, from the
//! shown buffers, and lays it at its new place, so it costs the image's
//! size and not the picture's. The overlay is laid first, the pointer
//! over it; a change to either puts both back and lays both again, as
//! one may cover the other.
//!
//! The images and where they are change under `lock`, a semaphore, and
//! every write of them into the copy is made holding it, so a lay always
//! uses the place an image is at now. Rows a refresh converted over the
//! pointer get it back from that refresh's own lay, whichever task moved
//! it in between; until then, for no longer than the conversion, those
//! rows show the picture without it.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const ExecBase = sdk.interface.exec.ExecBase;
const link_file = @import("link.zig");
const Link = link_file.Link;

/// The images over the picture and where they are; the board's, beside
/// its copy.
pub const Pointer = struct {
    lock: exec.SignalSemaphore = .{},
    /// The pointer as rtg.library made it, its top left, and whether it
    /// is to be seen.
    image: ?*const rtg.RtgPointerImage = null,
    left: i32 = 0,
    top: i32 = 0,
    shown: bool = false,
    /// The overlay, seen while there is one.
    overlay: ?*const rtg.RtgPointerImage = null,
    overlay_left: i32 = 0,
    overlay_top: i32 = 0,

    /// Whether anything is to be laid over the picture.
    pub fn wanted(pointer: *const Pointer) bool {
        return (pointer.shown and pointer.image != null) or pointer.overlay != null;
    }
};

/// The part of an image at (left, top) that is on the copy, as columns
/// and lines; null when none of it is.
const Clip = struct { x0: u32, y0: u32, x1: u32, y1: u32 };

fn clipOf(link: *const Link, image: *const rtg.RtgPointerImage, left: i32, top: i32) ?Clip {
    const x0 = @max(left, 0);
    const y0 = @max(top, 0);
    const x1 = @min(left + @as(i32, @intCast(image.width)), @as(i32, @intCast(link.width)));
    const y1 = @min(top + @as(i32, @intCast(image.height)), @as(i32, @intCast(link.height)));
    if (x0 >= x1 or y0 >= y1) return null;
    return .{ .x0 = @intCast(x0), .y0 = @intCast(y0), .x1 = @intCast(x1), .y1 = @intCast(y1) };
}

/// The picture back where an image is: its rectangle from the shown
/// buffers.
fn restoreImage(link: *const Link, given: ?*const rtg.RtgPointerImage, left: i32, top: i32) void {
    const image = given orelse return;
    const clip = clipOf(link, image, left, top) orelse return;
    var y = clip.y0;
    while (y < clip.y1) : (y += 1) {
        const row = link_file.sourceRow(link, y) orelse continue;
        link_file.put(link, y, clip.x0, row + clip.x0, clip.x1 - clip.x0);
    }
}

/// One image laid into the copy: its pixels where its mask has them, a
/// run at a time, cut to the copy.
fn layImage(link: *const Link, given: ?*const rtg.RtgPointerImage, left: i32, top: i32) void {
    const image = given orelse return;
    if (image.format != .rgb565) return;
    const clip = clipOf(link, image, left, top) orelse return;
    var y = clip.y0;
    while (y < clip.y1) : (y += 1) {
        const image_y: u32 = @intCast(@as(i32, @intCast(y)) - top);
        const from: [*]const u16 = @ptrCast(@alignCast(image.pixels + image_y * image.pitch));
        var x = clip.x0;
        while (x < clip.x1) {
            const image_x: u32 = @intCast(@as(i32, @intCast(x)) - left);
            if (!image.opaqueAt(image_x, image_y)) {
                x += 1;
                continue;
            }
            var run: u32 = 1;
            while (x + run < clip.x1 and image.opaqueAt(image_x + run, image_y)) run += 1;
            link_file.put(link, y, x, from + image_x, run);
            x += run;
        }
    }
}

/// Both images back out of the copy. The lock is held.
fn restore(pointer: *const Pointer, link: *const Link) void {
    restoreImage(link, pointer.overlay, pointer.overlay_left, pointer.overlay_top);
    restoreImage(link, pointer.image, pointer.left, pointer.top);
}

/// Both images into the copy: the overlay, then the pointer over it when
/// it is shown. The lock is held.
fn lay(pointer: *const Pointer, link: *const Link) void {
    layImage(link, pointer.overlay, pointer.overlay_left, pointer.overlay_top);
    if (pointer.shown) layImage(link, pointer.image, pointer.left, pointer.top);
}

/// The images laid again, where they are now: after rows went into the
/// copy. Nothing while there is no copy.
pub fn relay(pointer: *Pointer, link: *const Link, sys: *ExecBase) void {
    if (link.pixels == 0) return;
    sys.ObtainSemaphore(&pointer.lock);
    defer sys.ReleaseSemaphore(&pointer.lock);
    lay(pointer, link);
}

/// What changes: which image, and its place or whether it is seen.
pub const Change = union(enum) {
    image: ?*const rtg.RtgPointerImage,
    place: [2]i32,
    shown: bool,
    overlay: ?*const rtg.RtgPointerImage,
    overlay_place: [2]i32,
};

/// A change made: both images put back out of the copy, the change made,
/// both laid again. With no copy yet the change is only kept.
pub fn change(pointer: *Pointer, link: *const Link, sys: *ExecBase, what: Change) void {
    sys.ObtainSemaphore(&pointer.lock);
    defer sys.ReleaseSemaphore(&pointer.lock);
    const copied = link.pixels != 0;
    if (copied) restore(pointer, link);
    switch (what) {
        .image => |image| pointer.image = image,
        .place => |place| {
            pointer.left = place[0];
            pointer.top = place[1];
        },
        .shown => |shown| pointer.shown = shown,
        .overlay => |image| pointer.overlay = image,
        .overlay_place => |place| {
            pointer.overlay_left = place[0];
            pointer.overlay_top = place[1];
        },
    }
    if (copied) lay(pointer, link);
}
