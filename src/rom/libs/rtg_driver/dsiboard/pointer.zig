// SPDX-License-Identifier: MPL-2.0
//! The pointer and the overlay - a dragged icon - over the picture the
//! DSI board streams.
//!
//! The screens never hold them. The stream reads the board's copy of what
//! is shown (`link.zig`) - over HDMI always, on a panel from the first
//! time a pointer or an overlay is to be seen - and the images are laid
//! into that copy. A move puts the picture back where the image was, from
//! the shown buffers, and lays it at its new place, so it costs the
//! image's size and not the picture's. The overlay is laid first, the
//! pointer over it; a change to either puts both back and lays both
//! again, as one may cover the other.
//!
//! **Rows going into the copy** - bands shown, rows refreshed - go around
//! the rectangle the images cover (`keepOut`), so they are never out of
//! the copy: while a screen is pulled down every line changes at every
//! step, and the pointer would otherwise be missing from most frames.
//! What lies under them is then filled from the shown buffers and they
//! are laid again (`mend`).
//!
//! The images and where they are change under `lock`, a semaphore, and
//! every write into the copy that touches them - a change, and the rows
//! shown or refreshed from the rectangle kept out to the mend - is made
//! holding it, so the rectangle kept out is where the images still are.

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

const Rect = link_file.Rect;

/// The part of an image at (left, top) that is on the copy; null when
/// none of it is.
fn clipOf(link: *const Link, image: *const rtg.RtgPointerImage, left: i32, top: i32) ?Rect {
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
    restoreRect(link, clipOf(link, image, left, top) orelse return);
}

fn restoreRect(link: *const Link, area: Rect) void {
    var y = area.y0;
    while (y < area.y1) : (y += 1) {
        const row = link_file.sourceRow(link, y) orelse continue;
        link_file.put(link, y, area.x0, row + area.x0, area.x1 - area.x0);
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

/// The rectangle the images cover - the overlay's, and the pointer's
/// while it is shown - for rows going into the copy to go around; null
/// when nothing is laid. The lock is held, and stays held until `mend`.
pub fn keepOut(pointer: *const Pointer, link: *const Link) ?Rect {
    var area: ?Rect = null;
    if (pointer.overlay) |image| area = join(area, clipOf(link, image, pointer.overlay_left, pointer.overlay_top));
    if (pointer.shown) {
        if (pointer.image) |image| area = join(area, clipOf(link, image, pointer.left, pointer.top));
    }
    return area;
}

fn join(one: ?Rect, other: ?Rect) ?Rect {
    const a = one orelse return other;
    const b = other orelse return a;
    return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
}

/// After rows went into the copy around `kept`: the picture under it
/// filled from the shown buffers - what they show there may have changed
/// - and the images laid again. The lock is held.
pub fn mend(pointer: *const Pointer, link: *const Link, kept: ?Rect) void {
    if (link.pixels == 0) return;
    if (kept) |area| restoreRect(link, area);
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
