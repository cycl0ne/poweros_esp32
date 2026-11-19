// SPDX-License-Identifier: MIT
//! What Paint can undo and redo: for each change, the area it touched and
//! that area's pixels from the other side of the change, kept one after
//! another in a single block of memory given at the start.
//!
//! A record is a header (the area and its pixel count), the pixels row
//! by row, and its own length again at its end, so the records can be
//! walked back from the last. Those before `done` are changes that can be
//! undone, the newest last; those from `done` to `end` were undone and
//! can be redone. Undoing a record swaps its pixels with the picture's:
//! the picture gets them back from before the change and the record keeps
//! the ones from after it, which redoing swaps back. A new change drops
//! whatever could be redone. When the block is full the oldest records
//! go, the rest moved down to its start; a change larger than the whole
//! block cannot be undone and empties it.
//!
//! The program keeps a second copy of the picture as it was after the
//! last change (`kept`): the pixels a change replaced come from there, and
//! every change, undo and redo copies its area into it afterwards.

const picture_zig = @import("picture.zig");
const Picture = picture_zig.Picture;
const Pixel = picture_zig.Pixel;
const Area = picture_zig.Area;

const Header = extern struct {
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,
    count: u32,

    fn area(header: Header) Area {
        return .{ .min_x = header.min_x, .min_y = header.min_y, .max_x = header.max_x, .max_y = header.max_y };
    }
};

const header_bytes = @sizeOf(Header);
const footer_bytes = @sizeOf(u32);

pub const History = struct {
    memory: [*]align(4) u8,
    size: usize,
    done: usize = 0,
    end: usize = 0,

    /// The bytes a record of `area` takes.
    pub fn recordBytes(area: Area) usize {
        return header_bytes + @as(usize, area.width()) * area.height() * @sizeOf(Pixel) + footer_bytes;
    }

    pub fn canUndo(history: *const History) bool {
        return history.done > 0;
    }

    pub fn canRedo(history: *const History) bool {
        return history.end > history.done;
    }

    /// Nothing to undo or redo: a new picture.
    pub fn clear(history: *History) void {
        history.done = 0;
        history.end = 0;
    }

    /// A change of `area` has been made to `picture`; `kept` still holds
    /// the area as it was before. That is recorded, and `kept` brought up
    /// to the picture. False when the change was too large to keep: there
    /// is nothing to undo then.
    pub fn record(history: *History, picture: *const Picture, kept: *Picture, changed: Area) bool {
        const area = changed.clip(picture.width, picture.height);
        if (area.isEmpty()) return true;
        defer kept.copyArea(picture, area);
        history.end = history.done;
        const bytes = recordBytes(area);
        if (bytes > history.size) {
            history.clear();
            return false;
        }
        while (history.done + bytes > history.size) history.dropOldest();

        const at = history.done;
        const header = Header{ .min_x = area.min_x, .min_y = area.min_y, .max_x = area.max_x, .max_y = area.max_y, .count = area.width() * area.height() };
        history.headerAt(at).* = header;
        const pixels = history.pixelsAt(at, header.count);
        var filled: usize = 0;
        var y: u32 = @intCast(area.min_y);
        while (y < area.max_y) : (y += 1) {
            const from = kept.row(y)[@intCast(area.min_x)..@intCast(area.max_x)];
            @memcpy(pixels[filled .. filled + from.len], from);
            filled += from.len;
        }
        history.footerAt(at + bytes).* = @intCast(bytes);
        history.done += bytes;
        history.end = history.done;
        return true;
    }

    /// The last change undone; the area it touched, null with none left.
    pub fn undo(history: *History, picture: *Picture, kept: *Picture) ?Area {
        if (!history.canUndo()) return null;
        const bytes = history.footerAt(history.done).*;
        history.done -= bytes;
        return history.swap(history.done, picture, kept);
    }

    /// The last change undone made again; the area, null with none.
    pub fn redo(history: *History, picture: *Picture, kept: *Picture) ?Area {
        if (!history.canRedo()) return null;
        const at = history.done;
        history.done += recordBytes(history.headerAt(at).area());
        return history.swap(at, picture, kept);
    }

    /// The record at `at` and the picture's pixels traded.
    fn swap(history: *History, at: usize, picture: *Picture, kept: *Picture) Area {
        const header = history.headerAt(at).*;
        const area = header.area();
        const pixels = history.pixelsAt(at, header.count);
        var taken: usize = 0;
        var y: u32 = @intCast(area.min_y);
        while (y < area.max_y) : (y += 1) {
            const there = picture.row(y)[@intCast(area.min_x)..@intCast(area.max_x)];
            for (there, pixels[taken .. taken + there.len]) |*in_picture, *in_record| {
                const was = in_picture.*;
                in_picture.* = in_record.*;
                in_record.* = was;
            }
            taken += there.len;
        }
        kept.copyArea(picture, area);
        return area;
    }

    /// The oldest record gone, the others moved down to the start.
    fn dropOldest(history: *History) void {
        const bytes = recordBytes(history.headerAt(0).area());
        var at: usize = 0;
        const words: [*]u32 = @ptrCast(history.memory);
        const from = bytes / 4;
        while (at < (history.end - bytes) / 4) : (at += 1) words[at] = words[at + from];
        history.done -= bytes;
        history.end -= bytes;
    }

    fn headerAt(history: *History, at: usize) *align(4) Header {
        return @ptrCast(@alignCast(history.memory + at));
    }

    fn pixelsAt(history: *History, at: usize, count: u32) []Pixel {
        const first: [*]Pixel = @ptrCast(@alignCast(history.memory + at + header_bytes));
        return first[0..count];
    }

    /// The length a record ending at `end` has written there.
    fn footerAt(history: *History, end: usize) *align(4) u32 {
        return @ptrCast(@alignCast(history.memory + end - footer_bytes));
    }
};
