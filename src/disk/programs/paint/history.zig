// SPDX-License-Identifier: MIT
//! What Paint can undo and redo: the changes made to the layers' pixels
//! and to the stack of layers, kept one after another in a single block
//! of memory given at the start.
//!
//! A record is a header, what it keeps, and its own length again at its
//! end, so the records can be walked back from the last. Those before
//! `done` are changes that can be undone, the newest last; those from
//! `done` to `end` were undone and can be redone. A new change drops
//! whatever could be redone. When the block is full the oldest records
//! go, the rest moved down to its start; a change larger than the whole
//! block cannot be undone and empties it.
//!
//! **Pixels.** A record of a change to a layer's pixels names the layer by
//! its id and keeps the area it touched with that area's pixels from the
//! other side of the change. Undoing it swaps its pixels with the
//! layer's: the layer gets them back from before the change and the
//! record keeps the ones from after it, which redoing swaps back. The
//! program keeps a second copy of the layer being painted as it was after
//! the last change (`kept`): the pixels a stroke replaced come from there
//! (`record`); a change to another layer is kept from the layer itself
//! before it is made (`remember`).
//!
//! **Layers.** A record of a layer put in or taken out keeps the layer -
//! its pixels' memory, name and settings - while the layer is out of the
//! stack: a layer taken out is held by its record, and so is one put in
//! once that is undone. The memory goes back to the program
//! (`release`) when the record that holds it is dropped: a layer deleted
//! is gone for good when its deletion can no longer be undone. A record
//! of a layer moved keeps where from and where to.
//!
//! **Steps of more than one record.** A record made `joined` is undone
//! and redone with the one before it - merging a layer down is the lower
//! layer's pixels and the upper layer taken out. The oldest records are
//! dropped a whole step at a time, and a joined record whose step would
//! lose its first part to make room is not kept at all.
//!
//! Undoing or redoing makes the layer it touched the one painted - for a
//! step of several records, the layer painted before the step when it is
//! undone, and after it when it is done again - and tells the program
//! what to show again (`Change`).

const picture_zig = @import("picture.zig");
const Picture = picture_zig.Picture;
const Pixel = picture_zig.Pixel;
const Area = picture_zig.Area;
const layers_zig = @import("layers.zig");
const Layer = layers_zig.Layer;
const Stack = layers_zig.Stack;

const Kind = enum(u32) { pixels, layer_in, layer_out, moved };

const Header = extern struct {
    kind: Kind,
    /// The layer's id: the one whose pixels it keeps, or the one put in
    /// or taken out.
    id: u32,
    min_x: i32 = 0,
    min_y: i32 = 0,
    max_x: i32 = 0,
    max_y: i32 = 0,
    /// Pixels: how many it keeps.
    count: u32 = 0,
    /// A layer put in or taken out: where; moved: where from.
    place: u32 = 0,
    /// Moved: where to.
    to: u32 = 0,
    /// Undone and redone with the record before it.
    joined: u32 = 0,
    /// The record holds the layer, out of the stack.
    holding: u32 = 0,

    fn area(header: Header) Area {
        return .{ .min_x = header.min_x, .min_y = header.min_y, .max_x = header.max_x, .max_y = header.max_y };
    }

    /// The bytes what it keeps takes.
    fn keptBytes(header: Header) usize {
        return switch (header.kind) {
            .pixels => @as(usize, header.count) * @sizeOf(Pixel),
            .layer_in, .layer_out => layer_bytes,
            .moved => 0,
        };
    }
};

const header_bytes = @sizeOf(Header);
const footer_bytes = @sizeOf(u32);
const layer_bytes = (@sizeOf(Layer) + 3) & ~@as(usize, 3);

/// What an undo or a redo changed: the area of the picture to show again,
/// and whether the stack of layers is another.
pub const Change = struct {
    area: Area = Area.none,
    layers: bool = false,
    /// A record of the step has chosen the layer painted.
    placed: bool = false,
};

pub const History = struct {
    memory: [*]align(4) u8,
    size: usize,
    done: usize = 0,
    end: usize = 0,
    /// Gives a layer's memory back to the program, when the record that
    /// held it goes.
    release: *const fn (context: *anyopaque, memory: *anyopaque) void,
    context: *anyopaque,

    /// The bytes a record of a change to `area`'s pixels takes.
    pub fn recordBytes(area: Area) usize {
        return header_bytes + @as(usize, area.width()) * area.height() * @sizeOf(Pixel) + footer_bytes;
    }

    fn bytesOf(header: Header) usize {
        return header_bytes + header.keptBytes() + footer_bytes;
    }

    pub fn canUndo(history: *const History) bool {
        return history.done > 0;
    }

    pub fn canRedo(history: *const History) bool {
        return history.end > history.done;
    }

    /// Nothing to undo or redo: a new picture, or the program ending. The
    /// layers records held are given back.
    pub fn clear(history: *History) void {
        var at: usize = 0;
        while (at < history.end) {
            const header = history.headerAt(at);
            history.letGo(header, at);
            at += bytesOf(header.*);
        }
        history.done = 0;
        history.end = 0;
    }

    /// The pixels of `area` in the layer `id`, as `before` holds them,
    /// kept: the change to them is about to be made, or `before` still
    /// holds them as they were. False when it was too large to keep.
    pub fn remember(history: *History, id: u32, before: *const Picture, changed: Area, joined: bool) bool {
        const area = changed.clip(before.width, before.height);
        if (area.isEmpty()) return true;
        const header = Header{
            .kind = .pixels,
            .id = id,
            .min_x = area.min_x,
            .min_y = area.min_y,
            .max_x = area.max_x,
            .max_y = area.max_y,
            .count = area.width() * area.height(),
        };
        const at = history.begin(header, joined) orelse return false;
        const pixels = history.pixelsAt(at, header.count);
        var filled: usize = 0;
        var y: u32 = @intCast(area.min_y);
        while (y < area.max_y) : (y += 1) {
            const from = before.row(y)[@intCast(area.min_x)..@intCast(area.max_x)];
            @memcpy(pixels[filled .. filled + from.len], from);
            filled += from.len;
        }
        return true;
    }

    /// A change of `area` has been made to `picture`, the layer `id`;
    /// `kept` still holds the area as it was before. That is recorded,
    /// and `kept` brought up to the picture. False when the change was
    /// too large to keep: there is nothing to undo then.
    pub fn record(history: *History, id: u32, picture: *const Picture, kept: *Picture, changed: Area) bool {
        defer kept.copyArea(picture, changed);
        return history.remember(id, kept, changed, false);
    }

    /// The layer at `place` has been put in.
    pub fn layerIn(history: *History, stack: *const Stack, place: u32, joined: bool) bool {
        return history.begin(.{ .kind = .layer_in, .id = stack.layers[place].id, .place = place }, joined) != null;
    }

    /// `layer` has been taken out from `place`, and is the record's to
    /// hold. False when it could not be kept: the layer is still the
    /// caller's then, to give back.
    pub fn layerOut(history: *History, layer: Layer, place: u32, joined: bool) bool {
        const at = history.begin(.{ .kind = .layer_out, .id = layer.id, .place = place, .holding = 1 }, joined) orelse return false;
        history.putLayer(at, layer);
        return true;
    }

    /// The layer at `from` has been moved to `to`.
    pub fn moved(history: *History, from: u32, to: u32, joined: bool) bool {
        return history.begin(.{ .kind = .moved, .id = 0, .place = from, .to = to }, joined) != null;
    }

    /// The last step undone, and what that changed; null with none left.
    pub fn undo(history: *History, stack: *Stack) ?Change {
        if (!history.canUndo()) return null;
        var change = Change{};
        while (history.done > 0) {
            const bytes = history.footerAt(history.done).*;
            history.done -= bytes;
            history.apply(history.done, stack, false, &change);
            if (history.headerAt(history.done).joined == 0) break;
        }
        return change;
    }

    /// The last step undone made again, and what that changed; null
    /// with none.
    pub fn redo(history: *History, stack: *Stack) ?Change {
        if (!history.canRedo()) return null;
        var change = Change{};
        while (true) {
            const at = history.done;
            history.done += bytesOf(history.headerAt(at).*);
            history.apply(at, stack, true, &change);
            if (history.done >= history.end or history.headerAt(history.done).joined == 0) break;
        }
        return change;
    }

    /// The record at `at` undone, or done again (`again`). Undone, the
    /// first record of a step undone - its last - chooses the layer
    /// painted; done again, the last.
    fn apply(history: *History, at: usize, stack: *Stack, again: bool, change: *Change) void {
        const header = history.headerAt(at);
        const choose = again or !change.placed;
        change.placed = true;
        switch (header.kind) {
            .pixels => {
                const place = stack.placeOf(header.id) orelse return;
                history.swap(at, &stack.layers[place].picture);
                if (choose) stack.current = place;
                change.area = change.area.add(header.area());
            },
            .layer_in, .layer_out => {
                // Undoing a layer put in, or doing again one taken out,
                // takes it out; the other two put it back.
                const out = (header.kind == .layer_in) != again;
                if (out) {
                    const place = stack.placeOf(header.id) orelse header.place;
                    history.putLayer(at, stack.remove(place));
                    header.holding = 1;
                } else {
                    stack.insert(header.place, history.layerAt(at));
                    if (choose) stack.current = header.place;
                    header.holding = 0;
                }
                change.layers = true;
            },
            .moved => {
                const from = if (again) header.place else header.to;
                const to = if (again) header.to else header.place;
                stack.move(from, to);
                if (choose) stack.current = to;
                change.layers = true;
            },
        }
        if (change.layers and stack.count > 0) change.area = stack.layers[0].picture.whole();
    }

    /// A record of `header` begun after what can be undone, room made for
    /// it: where it is, with only what it keeps left to fill in. Null when
    /// it does not fit, or a joined one would lose what it joins to make
    /// room; the history is empty then.
    fn begin(history: *History, given: Header, joined: bool) ?usize {
        history.dropRedo();
        const bytes = bytesOf(given);
        if (bytes > history.size) {
            history.clear();
            return null;
        }
        while (history.done + bytes > history.size) {
            history.dropOldest();
            if (joined and history.done == 0) {
                history.clear();
                return null;
            }
        }
        var header = given;
        header.joined = @intFromBool(joined and history.done > 0);
        const at = history.done;
        history.headerAt(at).* = header;
        history.footerAt(at + bytes).* = @intCast(bytes);
        history.done += bytes;
        history.end = history.done;
        return at;
    }

    /// What could be redone dropped.
    fn dropRedo(history: *History) void {
        var at = history.done;
        while (at < history.end) {
            const header = history.headerAt(at);
            history.letGo(header, at);
            at += bytesOf(header.*);
        }
        history.end = history.done;
    }

    /// The oldest step gone - its first record and those joined to it -
    /// the others moved down to the start.
    fn dropOldest(history: *History) void {
        var bytes: usize = 0;
        while (bytes < history.done) {
            const header = history.headerAt(bytes);
            if (bytes > 0 and header.joined == 0) break;
            history.letGo(header, bytes);
            bytes += bytesOf(header.*);
        }
        const words: [*]u32 = @ptrCast(history.memory);
        const from = bytes / 4;
        var at: usize = 0;
        while (at < (history.end - bytes) / 4) : (at += 1) words[at] = words[at + from];
        history.done -= bytes;
        history.end -= bytes;
        if (history.done > 0) history.headerAt(0).joined = 0;
    }

    /// A record going: the layer it holds given back.
    fn letGo(history: *History, header: *align(4) Header, at: usize) void {
        if (header.holding == 0) return;
        header.holding = 0;
        history.release(history.context, history.layerAt(at).memory);
    }

    /// The record at `at` and the picture's pixels traded.
    fn swap(history: *History, at: usize, picture: *Picture) void {
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
    }

    fn headerAt(history: *History, at: usize) *align(4) Header {
        return @ptrCast(@alignCast(history.memory + at));
    }

    fn pixelsAt(history: *History, at: usize, count: u32) []Pixel {
        const first: [*]Pixel = @ptrCast(@alignCast(history.memory + at + header_bytes));
        return first[0..count];
    }

    /// The layer a record keeps, copied out: the block is aligned for
    /// pixels, not for a layer's pointers.
    fn layerAt(history: *History, at: usize) Layer {
        var layer: Layer = undefined;
        const into: *[@sizeOf(Layer)]u8 = @ptrCast(&layer);
        @memcpy(into, (history.memory + at + header_bytes)[0..@sizeOf(Layer)]);
        return layer;
    }

    fn putLayer(history: *History, at: usize, layer: Layer) void {
        const from: *const [@sizeOf(Layer)]u8 = @ptrCast(&layer);
        @memcpy((history.memory + at + header_bytes)[0..@sizeOf(Layer)], from);
    }

    /// The length a record ending at `end` has written there.
    fn footerAt(history: *History, end: usize) *align(4) u32 {
        return @ptrCast(@alignCast(history.memory + end - footer_bytes));
    }
};
