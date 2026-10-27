// SPDX-License-Identifier: MIT
//! An icon's picture at a size: shrunk once, and shared.
//!
//! **The size** is the picture's own when it fits in the size asked for
//! each way, and otherwise the largest that fits with its shape kept, at
//! least a pixel each way. **Shrinking** makes each pixel the average of
//! the pixels it covers, red, green and blue weighted by their coverage,
//! so a soft edge stays soft.
//!
//! **A shrunk copy** is one block - the `Shrunk`, whose first field is the
//! `IconImage` handed out, then its pixels - and counts its users as a
//! picture does, under the same spinlock. A copy of a picture this library
//! made hangs on that picture, holds it, and is found there again by the
//! next caller that asks for the same size: many files share one default
//! picture, and so share its copy. A copy of an image of a program's own
//! belongs to no picture and is shared with nobody.

const sdk = @import("sdk");
const exec = sdk.exec;
const icon = sdk.icon;
const IconBase = @import("../icon_base.zig").IconBase;
const _picture = @import("_picture.zig");
const Picture = _picture.Picture;

/// What a copy is checked by when it is handed back: not a picture's.
const MAGIC: u32 = 0x49434F53;

/// A width and a height.
pub const Size = struct { width: u32, height: u32 };

pub const Shrunk = extern struct {
    /// What ObtainIconImage hands out; the pixels follow this struct.
    image: icon.IconImage,
    magic: u32 = MAGIC,
    /// How many hold it.
    users: u32 = 1,
    /// The picture it was shrunk from, held while the copy is; null for an
    /// image of a program's own.
    source: ?*Picture = null,
    /// The next copy of the same picture.
    next: ?*Shrunk = null,
};

/// The copy behind an image; null for an image that is not one.
pub fn ofImage(image: *const icon.IconImage) ?*Shrunk {
    const shrunk: *Shrunk = @constCast(@fieldParentPtr("image", image));
    return if (shrunk.magic == MAGIC) shrunk else null;
}

/// The size a picture `width` by `height` is shown at: itself when it
/// fits in `most` each way, else made smaller with its shape kept, at
/// least a pixel each way.
pub fn fitted(width: u32, height: u32, most: u32) Size {
    if (width <= most and height <= most) return .{ .width = width, .height = height };
    if (width >= height) {
        return .{ .width = most, .height = @max(1, @as(u32, @intCast(@as(u64, height) * most / width))) };
    }
    return .{ .width = @max(1, @as(u32, @intCast(@as(u64, width) * most / height))), .height = most };
}

/// `from`, `width` by `height` pixels of rgba32, shrunk to `to.width` by
/// `to.height` into `into`: each pixel the average of the pixels it
/// covers, red, green and blue weighted by their coverage.
pub fn shrink(from: []const u8, width: u32, height: u32, into: []u8, to: Size) void {
    var y: u32 = 0;
    while (y < to.height) : (y += 1) {
        const top = y * height / to.height;
        const bottom = @max(top + 1, (y + 1) * height / to.height);
        var x: u32 = 0;
        while (x < to.width) : (x += 1) {
            const left = x * width / to.width;
            const right = @max(left + 1, (x + 1) * width / to.width);
            var red: u64 = 0;
            var green: u64 = 0;
            var blue: u64 = 0;
            var cover: u64 = 0;
            var count: u64 = 0;
            var sy = top;
            while (sy < bottom) : (sy += 1) {
                var sx = left;
                while (sx < right) : (sx += 1) {
                    const at = (@as(usize, sy) * width + sx) * 4;
                    const alpha: u64 = from[at + 3];
                    red += from[at] * alpha;
                    green += from[at + 1] * alpha;
                    blue += from[at + 2] * alpha;
                    cover += alpha;
                    count += 1;
                }
            }
            const out = (@as(usize, y) * to.width + x) * 4;
            into[out + 3] = @intCast(cover / count);
            if (cover == 0) {
                into[out] = 0;
                into[out + 1] = 0;
                into[out + 2] = 0;
            } else {
                into[out] = @intCast(red / cover);
                into[out + 1] = @intCast(green / cover);
                into[out + 2] = @intCast(blue / cover);
            }
        }
    }
}

/// `image` at most `most` pixels each way, held: the image itself when it
/// fits, else a copy - the picture's own of that size when there is one.
/// Null without the memory.
pub fn obtain(base: *IconBase, image: *const icon.IconImage, most: u32) ?*const icon.IconImage {
    const sys = base.sys_base;
    const size = fitted(image.width, image.height, @max(most, 1));
    const source = _picture.ofImage(image);
    if (size.width == image.width and size.height == image.height) {
        if (source) |picture| {
            _picture.hold(base, picture);
        } else if (ofImage(image)) |copy| {
            sys.AcquireLock(&base.users_lock);
            copy.users += 1;
            sys.ReleaseLock(&base.users_lock);
        }
        return image;
    }
    const picture = source orelse {
        const made = make(base, image, size) orelse return null;
        return &made.image;
    };
    sys.AcquireLock(&base.users_lock);
    if (keptOf(picture, size)) |kept| {
        kept.users += 1;
        sys.ReleaseLock(&base.users_lock);
        return &kept.image;
    }
    sys.ReleaseLock(&base.users_lock);

    // Shrunk without the lock; another caller may have made the same copy
    // meanwhile, and then that one is taken and this one let go.
    const made = make(base, image, size) orelse return null;
    sys.AcquireLock(&base.users_lock);
    if (keptOf(picture, size)) |kept| {
        kept.users += 1;
        sys.ReleaseLock(&base.users_lock);
        sys.FreeVec(made);
        return &kept.image;
    }
    made.source = picture;
    made.next = picture.shrunk;
    picture.shrunk = made;
    picture.users += 1;
    sys.ReleaseLock(&base.users_lock);
    return &made.image;
}

/// An image from `obtain` given back: a picture let go of, a copy freed
/// with its last user - and the picture it hung on let go of then. An
/// image of a program's own that fitted is not held, and nothing is done.
pub fn release(base: *IconBase, image: *const icon.IconImage) void {
    if (_picture.ofImage(image)) |picture| return _picture.release(base, picture);
    const copy = ofImage(image) orelse return;
    const sys = base.sys_base;
    sys.AcquireLock(&base.users_lock);
    copy.users -= 1;
    const last = copy.users == 0;
    if (last) {
        if (copy.source) |picture| unhang(picture, copy);
    }
    sys.ReleaseLock(&base.users_lock);
    if (!last) return;
    const source = copy.source;
    sys.FreeVec(copy);
    if (source) |picture| _picture.release(base, picture);
}

/// The copy of `picture` at `size`, if it has one. Under `users_lock`.
fn keptOf(picture: *Picture, size: Size) ?*Shrunk {
    var at = picture.shrunk;
    while (at) |copy| : (at = copy.next) {
        if (copy.image.width == size.width and copy.image.height == size.height) return copy;
    }
    return null;
}

/// `copy` taken off its picture's list. Under `users_lock`.
fn unhang(picture: *Picture, copy: *Shrunk) void {
    var link = &picture.shrunk;
    while (link.*) |at| : (link = &at.next) {
        if (at == copy) {
            link.* = copy.next;
            return;
        }
    }
}

/// A copy of `image` shrunk to `size`, with one user and on no list.
fn make(base: *IconBase, image: *const icon.IconImage, size: Size) ?*Shrunk {
    const pixel_bytes = @as(usize, size.width) * size.height * 4;
    const memory = base.sys_base.AllocVec(@sizeOf(Shrunk) + pixel_bytes, exec.MEMF_ANY) orelse return null;
    const pixels: [*]u8 = @as([*]u8, @ptrCast(memory)) + @sizeOf(Shrunk);
    const copy: *Shrunk = @ptrCast(@alignCast(memory));
    copy.* = .{ .image = .{ .width = size.width, .height = size.height, .pixels = pixels } };
    const from = image.pixels[0 .. @as(usize, image.width) * image.height * 4];
    shrink(from, image.width, image.height, pixels[0..pixel_bytes], size);
    return copy;
}
