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
//! pointer over it. The pointer moving puts back its own rectangle and
//! lays the overlay again inside it; the overlay moving puts back its
//! rectangle and lays both. While an icon is dragged both move at every
//! step, and the overlay, up to 160 pixels each way, is then put back
//! and laid once and not twice. Any other change puts both back and lays
//! both.
//!
//! What a change wrote goes out of the data cache before the lock is let
//! go (`link.writeOut`), a rectangle covering all of it.
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

fn restoreRect(link: *const Link, area: Rect) void {
    var y = area.y0;
    while (y < area.y1) : (y += 1) {
        const row = link_file.sourceRow(link, y) orelse continue;
        link_file.put(link, y, area.x0, row + area.x0, area.x1 - area.x0);
    }
}

/// One image laid into the copy: its pixels where its mask has them, a
/// run at a time, cut to the copy and to `within` when given.
fn layImage(link: *const Link, given: ?*const rtg.RtgPointerImage, left: i32, top: i32, within: ?Rect) void {
    const image = given orelse return;
    if (image.format != .rgb565) return;
    const whole = clipOf(link, image, left, top) orelse return;
    const clip = if (within) |area| meet(whole, area) orelse return else whole;
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

/// Where each image is on the copy: the overlay's rectangle, and the
/// pointer's while it is shown; null for one not there.
fn overlayArea(pointer: *const Pointer, link: *const Link) ?Rect {
    const image = pointer.overlay orelse return null;
    return clipOf(link, image, pointer.overlay_left, pointer.overlay_top);
}

fn pointerArea(pointer: *const Pointer, link: *const Link) ?Rect {
    if (!pointer.shown) return null;
    const image = pointer.image orelse return null;
    return clipOf(link, image, pointer.left, pointer.top);
}

/// Both images into the copy: the overlay, then the pointer over it when
/// it is shown. The lock is held.
fn lay(pointer: *const Pointer, link: *const Link) void {
    layImage(link, pointer.overlay, pointer.overlay_left, pointer.overlay_top, null);
    if (pointer.shown) layImage(link, pointer.image, pointer.left, pointer.top, null);
}

/// The rectangle the images cover - the overlay's, and the pointer's
/// while it is shown - for rows going into the copy to go around; null
/// when nothing is laid. The lock is held, and stays held until `mend`.
pub fn keepOut(pointer: *const Pointer, link: *const Link) ?Rect {
    return join(overlayArea(pointer, link), pointerArea(pointer, link));
}

/// The rectangle covering both.
fn join(one: ?Rect, other: ?Rect) ?Rect {
    const a = one orelse return other;
    const b = other orelse return a;
    return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
}

/// The part both cover; null for none.
fn meet(a: Rect, b: Rect) ?Rect {
    const area: Rect = .{ .x0 = @max(a.x0, b.x0), .y0 = @max(a.y0, b.y0), .x1 = @min(a.x1, b.x1), .y1 = @min(a.y1, b.y1) };
    if (area.x0 >= area.x1 or area.y0 >= area.y1) return null;
    return area;
}

/// What was written under `area` out of the data cache.
fn writeOutUnder(link: *const Link, sys: *ExecBase, area: ?Rect) void {
    link_file.writeOut(link, sys, area orelse return);
}

/// After rows went into the copy around `kept`: the picture under it
/// filled from the shown buffers - what they show there may have changed
/// - and the images laid again. The lock is held.
pub fn mend(pointer: *const Pointer, link: *const Link, sys: *ExecBase, kept: ?Rect) void {
    if (link.pixels == 0) return;
    const area = kept orelse return;
    restoreRect(link, area);
    lay(pointer, link);
    link_file.writeOut(link, sys, area);
}

/// What changes: which image, and its place or whether it is seen.
pub const Change = union(enum) {
    image: ?*const rtg.RtgPointerImage,
    place: [2]i32,
    shown: bool,
    overlay: ?*const rtg.RtgPointerImage,
    overlay_place: [2]i32,
};

/// A change made in the copy: a move puts back the moved image's
/// rectangle and lays again what lies in it; any other puts both back and
/// lays both. With no copy yet the change is only kept.
pub fn change(pointer: *Pointer, link: *const Link, sys: *ExecBase, what: Change) void {
    sys.ObtainSemaphore(&pointer.lock);
    defer sys.ReleaseSemaphore(&pointer.lock);
    if (link.pixels == 0) return keep(pointer, what);
    switch (what) {
        .place => {
            // The overlay laid again where the pointer was, the pointer
            // over it at its new place.
            const was = pointerArea(pointer, link);
            if (was) |area| {
                restoreRect(link, area);
                layImage(link, pointer.overlay, pointer.overlay_left, pointer.overlay_top, area);
            }
            keep(pointer, what);
            if (pointer.shown) layImage(link, pointer.image, pointer.left, pointer.top, null);
            writeOutUnder(link, sys, join(was, pointerArea(pointer, link)));
        },
        .overlay_place => {
            // The pointer goes with the rectangle put back, or lies under
            // the overlay's new place: laid again over it.
            const was = overlayArea(pointer, link);
            if (was) |area| restoreRect(link, area);
            keep(pointer, what);
            lay(pointer, link);
            writeOutUnder(link, sys, join(was, keepOut(pointer, link)));
        },
        else => {
            // The pointer's rectangle even while it is not shown: the
            // change may be the one that hides it.
            const image_was = if (pointer.image) |image| clipOf(link, image, pointer.left, pointer.top) else null;
            const was = join(overlayArea(pointer, link), image_was);
            if (overlayArea(pointer, link)) |area| restoreRect(link, area);
            if (image_was) |area| restoreRect(link, area);
            keep(pointer, what);
            lay(pointer, link);
            writeOutUnder(link, sys, join(was, keepOut(pointer, link)));
        },
    }
}

/// The change kept: the image, the place, or whether it is seen.
fn keep(pointer: *Pointer, what: Change) void {
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
}
