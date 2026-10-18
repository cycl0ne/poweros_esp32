// SPDX-License-Identifier: MIT
//! Where an icon goes that has no place of its own: the first cell of a
//! grid that no icon already on the ground overlaps - and, with Snap to
//! Grid, where an icon that was moved goes: the free cell of the same
//! grid nearest where it was let go.
//!
//! The desktop puts the disks down its right edge from the top, a column
//! at a time leftwards, as the original's disks run down the right of
//! the screen; a drawer fills rows from the top left. A cell is the room
//! an icon takes with its name under it, so two placed icons never touch.
//! The desktop's grid is counted from its right edge, a drawer's from its
//! left, so a cell an icon is snapped to is one an icon is placed in.

const graphics = @import("sdk").graphics;
const Rect = graphics.Rect;

/// How the grid is walked.
pub const Order = enum {
    /// Down a column, then the column to the left of it.
    columns_from_right,
    /// Along a row, then the row under it.
    rows_from_left,
};

/// A cell's size.
pub const Cell = struct { width: i32, height: i32 };

/// A place: a cell's top-left.
pub const Point = struct { x: i32, y: i32 };

fn overlaps(a: Rect, b: Rect) bool {
    return a.min_x < b.max_x and b.min_x < a.max_x and a.min_y < b.max_y and b.min_y < a.max_y;
}

/// The first cell of `area` in `order` that overlaps none of `taken`.
/// When every cell is taken, the first one: icons may lie on top of each
/// other, never off the ground.
pub fn firstFree(area: Rect, cell: Cell, taken: []const Rect, order: Order) Point {
    const across: i32 = @max(1, @divTrunc(area.max_x - area.min_x, cell.width));
    const down: i32 = @max(1, @divTrunc(area.max_y - area.min_y, cell.height));
    const cells = across * down;
    var n: i32 = 0;
    while (n < cells) : (n += 1) {
        const at = cellAt(area, cell, across, down, n, order);
        const box = Rect{ .min_x = at.x, .min_y = at.y, .max_x = at.x + cell.width, .max_y = at.y + cell.height };
        for (taken) |other| {
            if (overlaps(box, other)) break;
        } else return at;
    }
    return cellAt(area, cell, across, down, 0, order);
}

/// A cell found by `nextFree`: its place, and its number in the walk.
pub const Found = struct { at: Point, index: i32 };

/// The first cell from the `from`th in `order` that overlaps none of
/// `taken`, in a grid as tall as it needs to be: what a drawer fills with
/// the icons that have no place of their own, one after another, so each
/// walk starts where the last one stopped.
pub fn nextFree(area: Rect, cell: Cell, taken: []const Rect, from: i32) Found {
    const across: i32 = @max(1, @divTrunc(area.max_x - area.min_x, cell.width));
    var n = from;
    while (true) : (n += 1) {
        const at = Point{ .x = area.min_x + @rem(n, across) * cell.width, .y = area.min_y + @divTrunc(n, across) * cell.height };
        const box = Rect{ .min_x = at.x, .min_y = at.y, .max_x = at.x + cell.width, .max_y = at.y + cell.height };
        for (taken) |other| {
            if (overlaps(box, other)) break;
        } else return .{ .at = at, .index = n };
    }
}

/// The free cell of `area`'s grid nearest `near` - the top-left of the
/// cell an icon lies in as it was let go - for a grid laid out as `order`
/// walks it: columns from the area's left edge for `rows_from_left`, from
/// its right edge for `columns_from_right`, rows from its top. The cells
/// are tried a ring at a time round the one nearest `near`, and of a ring
/// the free one nearest `near` is taken. When every cell is taken, the
/// one nearest `near`: icons may lie on top of each other.
pub fn nearestFree(area: Rect, cell: Cell, taken: []const Rect, near: Point, order: Order) Point {
    const across: i32 = @max(1, @divTrunc(area.max_x - area.min_x, cell.width));
    const down: i32 = @max(1, @divTrunc(area.max_y - area.min_y, cell.height));
    const from_left = switch (order) {
        .rows_from_left => near.x - area.min_x,
        .columns_from_right => area.max_x - cell.width - near.x,
    };
    const column = @min(@max(nearestStep(from_left, cell.width), 0), across - 1);
    const row = @min(@max(nearestStep(near.y - area.min_y, cell.height), 0), down - 1);
    var ring: i32 = 0;
    while (ring < @max(across, down)) : (ring += 1) {
        var best: ?Point = null;
        var best_distance: i64 = 0;
        var dy = -ring;
        while (dy <= ring) : (dy += 1) {
            // Only the ring's own cells: a whole row at its top and its
            // bottom, the two ends of every row between.
            const edge_row = dy == -ring or dy == ring;
            var dx = -ring;
            while (dx <= ring) : (dx += if (edge_row or dx == ring) 1 else 2 * ring) {
                const c = column + dx;
                const r = row + dy;
                if (c < 0 or c >= across or r < 0 or r >= down) continue;
                const at = cellOf(area, cell, c, r, order);
                if (!free(at, cell, taken)) continue;
                const distance = square(at.x - near.x) + square(at.y - near.y);
                if (best == null or distance < best_distance) {
                    best = at;
                    best_distance = distance;
                }
            }
        }
        if (best) |at| return at;
    }
    return cellOf(area, cell, column, row, order);
}

/// The step of `size` nearest `offset`, rounded half up.
fn nearestStep(offset: i32, size: i32) i32 {
    return @divFloor(offset + @divTrunc(size, 2), size);
}

fn square(value: i32) i64 {
    const wide: i64 = value;
    return wide * wide;
}

/// Whether the cell at `at` overlaps none of `taken`.
fn free(at: Point, cell: Cell, taken: []const Rect) bool {
    const box = Rect{ .min_x = at.x, .min_y = at.y, .max_x = at.x + cell.width, .max_y = at.y + cell.height };
    for (taken) |other| {
        if (overlaps(box, other)) return false;
    }
    return true;
}

/// The cell in column `column` and row `row` of `order`'s grid.
fn cellOf(area: Rect, cell: Cell, column: i32, row: i32, order: Order) Point {
    return switch (order) {
        .rows_from_left => .{ .x = area.min_x + column * cell.width, .y = area.min_y + row * cell.height },
        .columns_from_right => .{ .x = area.max_x - (column + 1) * cell.width, .y = area.min_y + row * cell.height },
    };
}

fn cellAt(area: Rect, cell: Cell, across: i32, down: i32, n: i32, order: Order) Point {
    return switch (order) {
        .columns_from_right => .{
            .x = area.max_x - (@divTrunc(n, down) + 1) * cell.width,
            .y = area.min_y + @rem(n, down) * cell.height,
        },
        .rows_from_left => .{
            .x = area.min_x + @rem(n, across) * cell.width,
            .y = area.min_y + @divTrunc(n, across) * cell.height,
        },
    };
}
