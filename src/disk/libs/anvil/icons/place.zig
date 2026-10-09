// SPDX-License-Identifier: MIT
//! Where an icon goes that has no place of its own: the first cell of a
//! grid that no icon already on the ground overlaps.
//!
//! The desktop puts the disks down its right edge from the top, a column
//! at a time leftwards, as the original's disks run down the right of
//! the screen; a drawer fills rows from the top left. A cell is the room
//! an icon takes with its name under it, so two placed icons never touch.

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
