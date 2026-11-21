// SPDX-License-Identifier: MIT
//! A glyph of colour layers read into the steps that draw it, from the
//! font's `COLR` table and the first palette of its `CPAL`: what
//! `GlyphPaints` hands out, and a tool on the host reads (`outlines.zig`).
//!
//! **A glyph of the table's first version** is a list of layers, each a
//! glyph's outline filled with one colour of the palette: a
//! `STEP_FILL_GLYPH` each.
//!
//! **One of its second version** is a graph of paints, gone through from
//! the glyph's own, depth first, the way the steps are drawn:
//!
//!   - its clip box, where the table's clip list has one, around all of
//!     it;
//!   - a paint of layers: each of the layers it names, in order;
//!   - a glyph: its outline as a clip around what it holds - or, holding
//!     a brush, through transforms or not, the outline filled with that
//!     brush (`STEP_FILL_GLYPH`, the transforms the brush's);
//!   - a colour glyph: that glyph's graph, inside its own clip box;
//!   - a transform, a translation, a scale, a rotation or a skew, each
//!     about a centre or not: a transform around what it holds;
//!   - a composite: a layer, the backdrop drawn on it, then the source
//!     on a layer of its own put down on it in the composite's mode;
//!   - a solid colour or a gradient: everything inside the clips filled
//!     with it (`STEP_FILL`).
//!
//! A paint of the variable kinds is read with the deltas the table's
//! store gives it at the outline's place on its axes - each through the
//! table's map of indices where it has one - added to its values, each
//! in that value's own units.
//!
//! **A gradient** is made what a program can draw. Its stops are sorted
//! by their offsets, those of one keeping their order, and spread over
//! 0 to 1: the gradient's ends moved to where the first and last stops
//! were. A linear gradient's three points become the two of a line
//! square to the third's: of no length, or with three points on one
//! line, it is its first stop's colour. A gradient whose stops are all
//! at one place pads that colour, or, when it does not pad, is nothing;
//! as is one of no stops. A colour is the palette's, its alpha times the
//! paint's; one the palette does not have, and the number 0xFFFF, is
//! the text's own (`STEPF_FOREGROUND`).
//!
//! A graph that goes round in a circle - a paint inside itself - one
//! deeper than `most_depth` or of more than `most_paints` paints, a
//! colour glyph the table lacks, and a paint or a layer past the table's
//! end, is no drawing of the glyph: no steps.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const vector = sdk.vector;
const _outline = @import("../outline/_outline.zig");
const _variation = @import("../outline/_variation.zig");
const Font = _outline.Font;
const Table = _outline.Table;
const Matrix = vector.Matrix;
const PaintStep = truetype.PaintStep;

/// How deep paints may be inside one another, and how many paints one
/// glyph is read through.
pub const most_depth = 64;
pub const most_paints = 16384;

/// A variable value's index into the deltas that says it has none.
const no_deltas: u32 = 0xFFFF_FFFF;

const Failure = error{Damaged};

/// The tables a glyph is read from.
const Colr = struct {
    font: *const Font,
    table: Table,
    cpal: ?Table,
    /// The second version's lists, where it has them.
    base_list: ?Table = null,
    layer_list: ?Table = null,
    clip_list: ?Table = null,
    index_map: ?Table = null,
    store: ?Table = null,

    fn byte(colr: *const Colr, at: u32) u8 {
        return _outline.byteIn(colr.font, colr.table, at);
    }
    fn word(colr: *const Colr, at: u32) u16 {
        return _outline.wordIn(colr.font, colr.table, at);
    }
    fn signed(colr: *const Colr, at: u32) i16 {
        return _outline.signedIn(colr.font, colr.table, at);
    }
    fn triple(colr: *const Colr, at: u32) u32 {
        return _outline.tripleIn(colr.font, colr.table, at);
    }
    fn long(colr: *const Colr, at: u32) u32 {
        return _outline.longIn(colr.font, colr.table, at);
    }

    /// What of the table an offset of 32 bits at `at` names; null for an
    /// offset of 0 or one past the table's end.
    fn partAt(colr: *const Colr, at: u32) ?Table {
        const offset = colr.long(at);
        if (offset == 0 or offset >= colr.table.len) return null;
        return .{ .at = colr.table.at + offset, .len = colr.table.len - offset };
    }

    /// The deltas `count` values from `base` on have at the outline's
    /// place, each in its value's own units; all 0 at the default, and
    /// for a table without a store.
    fn deltas(colr: *const Colr, base: u32, comptime count: u32) [count]f32 {
        var found: [count]f32 = @splat(0);
        if (base == no_deltas or !colr.font.vary.varied) return found;
        const store = colr.store orelse return found;
        const reach = @min(count, no_deltas - base);
        var nth: u32 = 0;
        while (nth < reach) : (nth += 1) {
            const index = base + nth;
            const implicit: _variation.Item = .{ .outer = index >> 16, .inner = index & 0xFFFF };
            const item = if (colr.index_map) |map| _variation.itemOf(colr.font, map, index) orelse implicit else implicit;
            found[nth] = @floatCast(_variation.storeDelta(colr.font, store, item.outer, item.inner));
        }
        return found;
    }

    /// A value of 2.14 bits at `at`, with a delta in its units.
    fn fraction(colr: *const Colr, at: u32, delta: f32) f32 {
        return (@as(f32, @floatFromInt(colr.signed(at))) + delta) / 16384;
    }
    /// A value in the font's units at `at`, with a delta.
    fn units(colr: *const Colr, at: u32, delta: f32) f32 {
        return @as(f32, @floatFromInt(colr.signed(at))) + delta;
    }
    /// The same, of no sign.
    fn length(colr: *const Colr, at: u32, delta: f32) f32 {
        return @as(f32, @floatFromInt(colr.word(at))) + delta;
    }
    /// A value of 16.16 bits at `at`, with a delta in its units.
    fn fixed(colr: *const Colr, at: u32, delta: f32) f32 {
        return (@as(f32, @floatFromInt(@as(i32, @bitCast(colr.long(at))))) + delta) / 65536;
    }

    /// A stop's colour: the first palette's `index`, its alpha times
    /// `alpha`; the text's for 0xFFFF and for one the palette lacks.
    fn colourOf(colr: *const Colr, index: u16, alpha: f32, step: *PaintStep) void {
        step.flags = truetype.STEPF_FOREGROUND;
        step.red = 0;
        step.green = 0;
        step.blue = 0;
        step.alpha = alpha;
        const cpal = colr.cpal orelse return;
        if (index == 0xFFFF) return;
        const font = colr.font;
        const entries: u32 = _outline.wordIn(font, cpal, 2);
        const records: u32 = _outline.wordIn(font, cpal, 6);
        if (_outline.wordIn(font, cpal, 4) == 0 or index >= entries) return;
        const record = @as(u32, _outline.wordIn(font, cpal, 12)) + index;
        if (record >= records) return;
        const at = _outline.longIn(font, cpal, 8) +| record *| 4;
        if (at >= cpal.len or cpal.len - at < 4) return;
        // Blue, green, red, alpha.
        step.flags = 0;
        step.blue = @as(f32, @floatFromInt(_outline.byteIn(font, cpal, at))) / 255;
        step.green = @as(f32, @floatFromInt(_outline.byteIn(font, cpal, at + 1))) / 255;
        step.red = @as(f32, @floatFromInt(_outline.byteIn(font, cpal, at + 2))) / 255;
        step.alpha = @as(f32, @floatFromInt(_outline.byteIn(font, cpal, at + 3))) / 255 * alpha;
    }
};

/// The steps written as far as there is room, and counted all the way.
const Writer = struct {
    steps: ?[*]PaintStep,
    room: u32,
    count: u32 = 0,

    fn put(writer: *Writer, step: PaintStep) void {
        if (writer.steps) |steps| {
            if (writer.count < writer.room) steps[writer.count] = step;
        }
        writer.count +|= 1;
    }
};

/// The steps that draw `glyph` into `steps`, as many as `room` holds:
/// how many there are, 0 for a glyph the font does not draw in colour
/// and one whose drawing cannot be read.
pub fn stepsOf(font: *const Font, glyph: u32, steps: ?[*]PaintStep, room: u32) u32 {
    const table = _outline.findTable(font, "COLR") orelse return 0;
    if (table.len < 14 or glyph > 0xFFFF) return 0;
    var colr: Colr = .{ .font = font, .table = table, .cpal = _outline.findTable(font, "CPAL") };
    if (colr.word(0) >= 1 and table.len >= 34) {
        colr.base_list = colr.partAt(14);
        colr.layer_list = colr.partAt(18);
        colr.clip_list = colr.partAt(22);
        colr.index_map = colr.partAt(26);
        colr.store = colr.partAt(30);
    }
    var writer: Writer = .{ .steps = steps, .room = room };
    if (colr.base_list) |list| {
        if (paintOfBase(&colr, list, glyph)) |paint| {
            var walk: Walk = .{ .colr = &colr, .out = &writer };
            walk.root(glyph, paint) catch return 0;
            return writer.count;
        }
    }
    layers(&colr, glyph, &writer) catch return 0;
    return writer.count;
}

/// Where in the table the paint of `glyph` in the second version's list
/// of base glyphs is; null for a glyph it does not have.
fn paintOfBase(colr: *const Colr, list: Table, glyph: u32) ?u32 {
    const font = colr.font;
    const count = _outline.longIn(font, list, 0);
    if (count > (list.len -| 4) / 6) return null;
    var low: u32 = 0;
    var high: u32 = count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const record = 4 + middle * 6;
        const found: u32 = _outline.wordIn(font, list, record);
        if (found == glyph) {
            const offset = _outline.longIn(font, list, record + 2);
            const at = list.at - colr.table.at + offset;
            if (offset == 0 or at >= colr.table.len) return null;
            return at;
        }
        if (found < glyph) low = middle + 1 else high = middle;
    }
    return null;
}

/// A glyph of the first version: each of its layers filled with its
/// colour. Nothing for a glyph the table does not have.
fn layers(colr: *const Colr, glyph: u32, writer: *Writer) Failure!void {
    const count: u32 = colr.word(2);
    const records = colr.long(4);
    const layer_records = colr.long(8);
    const layer_count: u32 = colr.word(12);
    if (records == 0 or records >= colr.table.len or (colr.table.len - records) / 6 < count) return;
    var low: u32 = 0;
    var high: u32 = count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const record = records + middle * 6;
        const found: u32 = colr.word(record);
        if (found == glyph) {
            const first: u32 = colr.word(record + 2);
            const many: u32 = colr.word(record + 4);
            if (first + many > layer_count) return Failure.Damaged;
            if (layer_records >= colr.table.len or (colr.table.len - layer_records) / 4 < first + many) return Failure.Damaged;
            var nth: u32 = 0;
            while (nth < many) : (nth += 1) {
                const layer = layer_records + (first + nth) * 4;
                var step: PaintStep = .{ .kind = truetype.STEP_FILL_GLYPH, .glyph = colr.word(layer) };
                colr.colourOf(colr.word(layer + 2), 1, &step);
                writer.put(step);
            }
            return;
        }
        if (found < glyph) low = middle + 1 else high = middle;
    }
}

/// A paint read, its deltas added: what is drawn of it.
const Resolved = union(enum) {
    layers: struct { first: u32, count: u32 },
    solid: struct { index: u16, alpha: f32 },
    linear: struct { points: [6]f32, line: Line },
    radial: struct { x0: f32, y0: f32, r0: f32, x1: f32, y1: f32, r1: f32, line: Line },
    sweep: struct { x: f32, y: f32, start: f32, end: f32, line: Line },
    glyph: struct { glyph: u32, paint: u32 },
    colour_glyph: u32,
    transform: struct { matrix: Matrix, paint: u32 },
    composite: struct { source: u32, mode: u32, backdrop: u32 },
};

/// A gradient's colours: where in the table, and whether its stops are
/// varied.
const Line = struct { at: u32, varied: bool };

/// One stop, read and varied.
const Stop = struct { offset: f32, index: u16, alpha: f32 };

/// A going through of one glyph's graph.
const Walk = struct {
    colr: *const Colr,
    out: *Writer,
    paints_left: u32 = most_paints,
    /// The paints of layers and of colour glyphs being drawn, from the
    /// outermost: one met again inside itself is a circle.
    active: [most_depth]u32 = undefined,
    active_count: u32 = 0,

    fn put(walk: *Walk, step: PaintStep) void {
        walk.out.put(step);
    }

    /// The glyph's paint at `paint`, inside its clip box.
    fn root(walk: *Walk, glyph: u32, paint: u32) Failure!void {
        try walk.enter(paint);
        const boxed = walk.clipBox(glyph);
        try walk.draw(try walk.resolve(paint), 0);
        if (boxed) walk.put(.{ .kind = truetype.STEP_POP_CLIP });
        walk.leave();
    }

    fn enter(walk: *Walk, id: u32) Failure!void {
        for (walk.active[0..walk.active_count]) |held| {
            if (held == id) return Failure.Damaged;
        }
        if (walk.active_count == most_depth) return Failure.Damaged;
        walk.active[walk.active_count] = id;
        walk.active_count += 1;
    }

    fn leave(walk: *Walk) void {
        walk.active_count -= 1;
    }

    /// The clip box the clip list has for `glyph` pushed; false for none.
    fn clipBox(walk: *Walk, glyph: u32) bool {
        const colr = walk.colr;
        const list = colr.clip_list orelse return false;
        const font = colr.font;
        if (_outline.byteIn(font, list, 0) != 1) return false;
        const count = _outline.longIn(font, list, 1);
        if (count > (list.len -| 5) / 7) return false;
        var low: u32 = 0;
        var high: u32 = count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const record = 5 + middle * 7;
            const start: u32 = _outline.wordIn(font, list, record);
            const end: u32 = _outline.wordIn(font, list, record + 2);
            if (glyph < start) {
                high = middle;
            } else if (glyph > end) {
                low = middle + 1;
            } else {
                const offset = _outline.tripleIn(font, list, record + 4);
                if (offset == 0 or offset >= list.len) return false;
                const box = list.at - colr.table.at + offset;
                const format = colr.byte(box);
                if (format != 1 and format != 2) return false;
                const delta = if (format == 2) colr.deltas(colr.long(box + 9), 4) else [4]f32{ 0, 0, 0, 0 };
                walk.put(.{
                    .kind = truetype.STEP_PUSH_CLIP_BOX,
                    .x0 = colr.units(box + 1, delta[0]),
                    .y0 = colr.units(box + 3, delta[1]),
                    .x1 = colr.units(box + 5, delta[2]),
                    .y1 = colr.units(box + 7, delta[3]),
                });
                return true;
            }
        }
        return false;
    }

    /// The paint an offset of 24 bits at `at` names, from the paint at
    /// `paint`.
    fn child(walk: *Walk, paint: u32, at: u32) Failure!u32 {
        const offset = walk.colr.triple(at);
        if (offset == 0) return Failure.Damaged;
        const found = paint +| offset;
        if (found >= walk.colr.table.len) return Failure.Damaged;
        return found;
    }

    /// The paint at `paint` read, of `most_paints` in all.
    fn resolve(walk: *Walk, paint: u32) Failure!Resolved {
        if (walk.paints_left == 0) return Failure.Damaged;
        walk.paints_left -= 1;
        const colr = walk.colr;
        const format = colr.byte(paint);
        const at = paint + 1;
        return switch (format) {
            1 => .{ .layers = .{ .count = colr.byte(at), .first = colr.long(at + 1) } },
            2, 3 => solid: {
                const delta = if (format == 3) colr.deltas(colr.long(at + 4), 1) else [1]f32{0};
                break :solid .{ .solid = .{ .index = colr.word(at), .alpha = colr.fraction(at + 2, delta[0]) } };
            },
            4, 5 => linear: {
                const delta = if (format == 5) colr.deltas(colr.long(at + 15), 6) else @as([6]f32, @splat(0));
                var points: [6]f32 = undefined;
                for (&points, 0..) |*point, nth| point.* = colr.units(at + 3 + @as(u32, @intCast(nth)) * 2, delta[nth]);
                break :linear .{ .linear = .{ .points = points, .line = .{ .at = try walk.child(paint, at), .varied = format == 5 } } };
            },
            6, 7 => radial: {
                const delta = if (format == 7) colr.deltas(colr.long(at + 15), 6) else @as([6]f32, @splat(0));
                break :radial .{ .radial = .{
                    .x0 = colr.units(at + 3, delta[0]),
                    .y0 = colr.units(at + 5, delta[1]),
                    .r0 = colr.length(at + 7, delta[2]),
                    .x1 = colr.units(at + 9, delta[3]),
                    .y1 = colr.units(at + 11, delta[4]),
                    .r1 = colr.length(at + 13, delta[5]),
                    .line = .{ .at = try walk.child(paint, at), .varied = format == 7 },
                } };
            },
            8, 9 => sweep: {
                const delta = if (format == 9) colr.deltas(colr.long(at + 11), 4) else @as([4]f32, @splat(0));
                break :sweep .{ .sweep = .{
                    .x = colr.units(at + 3, delta[0]),
                    .y = colr.units(at + 5, delta[1]),
                    .start = colr.fraction(at + 7, delta[2]),
                    .end = colr.fraction(at + 9, delta[3]),
                    .line = .{ .at = try walk.child(paint, at), .varied = format == 9 },
                } };
            },
            10 => .{ .glyph = .{ .paint = try walk.child(paint, at), .glyph = colr.word(at + 3) } },
            11 => .{ .colour_glyph = colr.word(at) },
            12, 13 => affine: {
                const inner = try walk.child(paint, at);
                const affine = try walk.child(paint, at + 3);
                const delta = if (format == 13) colr.deltas(colr.long(affine + 24), 6) else @as([6]f32, @splat(0));
                break :affine .{ .transform = .{ .paint = inner, .matrix = .{
                    .a = colr.fixed(affine, delta[0]),
                    .b = colr.fixed(affine + 4, delta[1]),
                    .c = colr.fixed(affine + 8, delta[2]),
                    .d = colr.fixed(affine + 12, delta[3]),
                    .e = colr.fixed(affine + 16, delta[4]),
                    .f = colr.fixed(affine + 20, delta[5]),
                } } };
            },
            14, 15 => translate: {
                const delta = if (format == 15) colr.deltas(colr.long(at + 7), 2) else [2]f32{ 0, 0 };
                break :translate .{ .transform = .{ .paint = try walk.child(paint, at), .matrix = Matrix.translate(colr.units(at + 3, delta[0]), colr.units(at + 5, delta[1])) } };
            },
            16...23 => scale: {
                // Two scales or one, about the origin or a centre.
                const uniform = format >= 20;
                const centred = format == 18 or format == 19 or format == 22 or format == 23;
                const varied = format % 2 == 1;
                const values: u32 = (if (uniform) @as(u32, 1) else 2) + (if (centred) @as(u32, 2) else 0);
                const delta = if (varied) colr.deltas(colr.long(at + 3 + values * 2), 4) else @as([4]f32, @splat(0));
                const x = colr.fraction(at + 3, delta[0]);
                const y = if (uniform) x else colr.fraction(at + 5, delta[1]);
                const centre_at = at + 3 + (if (uniform) @as(u32, 2) else 4);
                const first_centre: usize = if (uniform) 1 else 2;
                var matrix = Matrix.scale(x, y);
                if (centred) {
                    const cx = colr.units(centre_at, delta[first_centre]);
                    const cy = colr.units(centre_at + 2, delta[first_centre + 1]);
                    matrix.e = cx - x * cx;
                    matrix.f = cy - y * cy;
                }
                break :scale .{ .transform = .{ .paint = try walk.child(paint, at), .matrix = matrix } };
            },
            24...27 => rotate: {
                const centred = format >= 26;
                const varied = format % 2 == 1;
                const delta = if (varied) colr.deltas(colr.long(at + 3 + (if (centred) @as(u32, 6) else 2)), 3) else @as([3]f32, @splat(0));
                const turn = colr.fraction(at + 3, delta[0]) * 180 * (pi / 180);
                const sin = @sin(turn);
                const cos = @cos(turn);
                var matrix: Matrix = .{ .a = cos, .b = sin, .c = -sin, .d = cos };
                if (centred) {
                    const cx = colr.units(at + 5, delta[1]);
                    const cy = colr.units(at + 7, delta[2]);
                    matrix.e = sin * cy + (1 - cos) * cx;
                    matrix.f = -sin * cx + (1 - cos) * cy;
                }
                break :rotate .{ .transform = .{ .paint = try walk.child(paint, at), .matrix = matrix } };
            },
            28...31 => skew: {
                const centred = format >= 30;
                const varied = format % 2 == 1;
                const delta = if (varied) colr.deltas(colr.long(at + 3 + (if (centred) @as(u32, 8) else 4)), 4) else @as([4]f32, @splat(0));
                const tan_x = tangent(colr.fraction(at + 3, delta[0]) * 180 * (pi / 180));
                const tan_y = tangent(colr.fraction(at + 5, delta[1]) * 180 * (pi / 180));
                var matrix: Matrix = .{ .c = -tan_x, .b = tan_y };
                if (centred) {
                    const cx = colr.units(at + 7, delta[2]);
                    const cy = colr.units(at + 9, delta[3]);
                    matrix.e = tan_x * cy;
                    matrix.f = -tan_y * cx;
                }
                break :skew .{ .transform = .{ .paint = try walk.child(paint, at), .matrix = matrix } };
            },
            32 => .{ .composite = .{
                .source = try walk.child(paint, at),
                .mode = colr.byte(at + 3),
                .backdrop = try walk.child(paint, at + 4),
            } },
            else => Failure.Damaged,
        };
    }

    /// A paint read drawn, `depth` inside the glyph's own.
    fn draw(walk: *Walk, paint: Resolved, depth: u32) Failure!void {
        if (depth >= most_depth) return Failure.Damaged;
        const colr = walk.colr;
        switch (paint) {
            .layers => |range| {
                const list = colr.layer_list orelse return Failure.Damaged;
                const font = colr.font;
                const count = _outline.longIn(font, list, 0);
                var nth: u32 = 0;
                while (nth < range.count) : (nth += 1) {
                    const index = range.first +| nth;
                    if (index >= count or 4 + @as(u64, index) * 4 + 4 > list.len) return Failure.Damaged;
                    const offset = _outline.longIn(font, list, 4 + index * 4);
                    const layer = list.at - colr.table.at +| offset;
                    if (offset == 0 or layer >= colr.table.len) return Failure.Damaged;
                    try walk.enter(layer);
                    try walk.draw(try walk.resolve(layer), depth + 1);
                    walk.leave();
                }
            },
            .solid, .linear, .radial, .sweep => {
                var step: PaintStep = .{ .kind = truetype.STEP_FILL };
                if (walk.brushOf(paint, &step)) |stops| {
                    walk.put(step);
                    walk.putStops(stops);
                }
            },
            .glyph => |glyph| {
                var next = try walk.resolve(glyph.paint);
                var between: ?Matrix = null;
                while (next == .transform) {
                    const transform = next.transform;
                    between = if (between) |before| before.then(transform.matrix) else transform.matrix;
                    next = try walk.resolve(transform.paint);
                }
                switch (next) {
                    .solid, .linear, .radial, .sweep => {
                        var step: PaintStep = .{ .kind = truetype.STEP_FILL_GLYPH, .glyph = glyph.glyph, .matrix = between orelse .{} };
                        if (walk.brushOf(next, &step)) |stops| {
                            walk.put(step);
                            walk.putStops(stops);
                        }
                        return;
                    },
                    else => {},
                }
                walk.put(.{ .kind = truetype.STEP_PUSH_CLIP_GLYPH, .glyph = glyph.glyph });
                if (between) |matrix| walk.put(.{ .kind = truetype.STEP_PUSH_TRANSFORM, .matrix = matrix });
                try walk.draw(next, depth + 1);
                if (between != null) walk.put(.{ .kind = truetype.STEP_POP_TRANSFORM });
                walk.put(.{ .kind = truetype.STEP_POP_CLIP });
            },
            .colour_glyph => |glyph| {
                const list = colr.base_list orelse return Failure.Damaged;
                const base = paintOfBase(colr, list, glyph) orelse return Failure.Damaged;
                try walk.enter(base);
                const boxed = walk.clipBox(glyph);
                try walk.draw(try walk.resolve(base), depth + 1);
                if (boxed) walk.put(.{ .kind = truetype.STEP_POP_CLIP });
                walk.leave();
            },
            .transform => |transform| {
                walk.put(.{ .kind = truetype.STEP_PUSH_TRANSFORM, .matrix = transform.matrix });
                try walk.draw(try walk.resolve(transform.paint), depth + 1);
                walk.put(.{ .kind = truetype.STEP_POP_TRANSFORM });
            },
            .composite => |composite| {
                walk.put(.{ .kind = truetype.STEP_PUSH_LAYER, .mode = truetype.COMPOSE_SOURCE_OVER });
                try walk.draw(try walk.resolve(composite.backdrop), depth + 1);
                walk.put(.{ .kind = truetype.STEP_PUSH_LAYER, .mode = if (composite.mode <= truetype.COMPOSE_LUMINOSITY) composite.mode else truetype.COMPOSE_SOURCE_OVER });
                try walk.draw(try walk.resolve(composite.source), depth + 1);
                walk.put(.{ .kind = truetype.STEP_POP_LAYER });
                walk.put(.{ .kind = truetype.STEP_POP_LAYER });
            },
        }
    }

    /// The stops a brush's step is followed by, as `brushOf` sets them.
    const Stops = struct {
        line: ?Line = null,
        /// What each offset is moved by and spread over.
        start: f32 = 0,
        spread: f32 = 1,
        /// A stop more, at 1, of the last stop's colour.
        padded: bool = false,
    };

    /// How a gradient's stops from `first` to `last` are spread over 0
    /// to 1: all at one place, the last again at 1 - or, for a gradient
    /// that does not pad, null.
    fn spreadOf(walk: *Walk, first: f32, last: f32, line: Line) ?Stops {
        var stops: Stops = .{ .line = line, .start = first };
        const range = last - first;
        if (range != 0) {
            stops.spread = range;
        } else {
            if (walk.colr.byte(line.at) != truetype.EXTEND_PAD) return null;
            stops.padded = true;
        }
        return stops;
    }

    /// The brush of a solid colour or a gradient put in `step`, its stops
    /// to follow; null for one that draws nothing.
    fn brushOf(walk: *Walk, paint: Resolved, step: *PaintStep) ?Stops {
        const colr = walk.colr;
        switch (paint) {
            .solid => |solid| {
                step.brush = truetype.BRUSH_SOLID;
                colr.colourOf(solid.index, solid.alpha, step);
                return .{};
            },
            .linear => |linear| {
                const ends = walk.endsOf(linear.line) orelse return null;
                const points = linear.points;
                const p1x = points[2] - points[0];
                const p1y = points[3] - points[1];
                const p2x = points[4] - points[0];
                const p2y = points[5] - points[1];
                if ((p1x == 0 and p1y == 0) or (p2x == 0 and p2y == 0) or p1x * p2y - p1y * p2x == 0) {
                    // Its first stop's colour.
                    step.brush = truetype.BRUSH_SOLID;
                    colr.colourOf(ends.first.index, ends.first.alpha, step);
                    return .{};
                }
                // The line from p0 square to p0's way to p2, as far as p1
                // reaches along it.
                const square_x = p2y;
                const square_y = -p2x;
                const square = @sqrt(square_x * square_x + square_y * square_y);
                const along = (p1x * square_x + p1y * square_y) / (square * square);
                var x0 = points[0];
                var y0 = points[1];
                var x3 = x0 + square_x * along;
                var y3 = y0 + square_y * along;
                const stops = walk.spreadOf(ends.first.offset, ends.last.offset, linear.line) orelse return null;
                if (stops.spread != 1 or ends.first.offset != 0) {
                    const dx = x3 - x0;
                    const dy = y3 - y0;
                    x3 = x0 + dx * ends.last.offset;
                    y3 = y0 + dy * ends.last.offset;
                    x0 += dx * ends.first.offset;
                    y0 += dy * ends.first.offset;
                }
                step.brush = truetype.BRUSH_LINEAR;
                step.x0 = x0;
                step.y0 = y0;
                step.x1 = x3;
                step.y1 = y3;
                walk.lineHead(linear.line, step, stops);
                return stops;
            },
            .radial => |radial| {
                const ends = walk.endsOf(radial.line) orelse return null;
                var x0 = radial.x0;
                var y0 = radial.y0;
                var r0 = radial.r0;
                var x1 = radial.x1;
                var y1 = radial.y1;
                var r1 = radial.r1;
                const stops = walk.spreadOf(ends.first.offset, ends.last.offset, radial.line) orelse return null;
                if (stops.spread != 1 or ends.first.offset != 0) {
                    const dx = x1 - x0;
                    const dy = y1 - y0;
                    const dr = r1 - r0;
                    x1 = x0 + dx * ends.last.offset;
                    y1 = y0 + dy * ends.last.offset;
                    r1 = r0 + dr * ends.last.offset;
                    x0 += dx * ends.first.offset;
                    y0 += dy * ends.first.offset;
                    r0 += dr * ends.first.offset;
                }
                step.brush = truetype.BRUSH_RADIAL;
                step.x0 = x0;
                step.y0 = y0;
                step.r0 = r0;
                step.x1 = x1;
                step.y1 = y1;
                step.r1 = r1;
                walk.lineHead(radial.line, step, stops);
                return stops;
            },
            .sweep => |sweep| {
                const ends = walk.endsOf(sweep.line) orelse return null;
                // A half turn more than the table says, so that its
                // angles of 0 to 2 are of the whole turn.
                const start = sweep.start * 180 + 180;
                const end = sweep.end * 180 + 180;
                const sector = end - start;
                const stops = walk.spreadOf(ends.first.offset, ends.last.offset, sweep.line) orelse return null;
                const from = start + sector * ends.first.offset;
                const to = start + sector * ends.last.offset;
                if (from == to and colr.byte(sweep.line.at) != truetype.EXTEND_PAD) return null;
                step.brush = truetype.BRUSH_SWEEP;
                step.x0 = sweep.x;
                step.y0 = sweep.y;
                step.start_angle = from;
                step.end_angle = to;
                walk.lineHead(sweep.line, step, stops);
                return stops;
            },
            else => return null,
        }
    }

    /// A gradient's extend and the count of its stops put in its step.
    fn lineHead(walk: *Walk, line: Line, step: *PaintStep, stops: Stops) void {
        const extend: u32 = walk.colr.byte(line.at);
        step.extend = if (extend <= truetype.EXTEND_REFLECT) extend else truetype.EXTEND_PAD;
        step.stop_count = @as(u32, walk.colr.word(line.at + 1)) + @intFromBool(stops.padded);
    }

    /// A colour line's first and last stops in the order of their
    /// offsets: the lowest, the first of those alike; the highest, the
    /// last. Null for a line of no stops.
    fn endsOf(walk: *Walk, line: Line) ?struct { first: Stop, last: Stop } {
        const count: u32 = walk.colr.word(line.at + 1);
        if (count == 0) return null;
        var first = walk.stopAt(line, 0);
        var last = first;
        var nth: u32 = 1;
        while (nth < count) : (nth += 1) {
            const stop = walk.stopAt(line, nth);
            if (stop.offset < first.offset) first = stop;
            if (stop.offset >= last.offset) last = stop;
        }
        return .{ .first = first, .last = last };
    }

    /// Stop `nth` of a colour line, varied.
    fn stopAt(walk: *Walk, line: Line, nth: u32) Stop {
        const colr = walk.colr;
        const size: u32 = if (line.varied) 10 else 6;
        const at = line.at + 3 + nth * size;
        const delta = if (line.varied) colr.deltas(colr.long(at + 6), 2) else [2]f32{ 0, 0 };
        return .{ .offset = colr.fraction(at, delta[0]), .index = colr.word(at + 2), .alpha = colr.fraction(at + 4, delta[1]) };
    }

    /// The stops of a gradient whose `ends` they are written after its
    /// step: sorted, spread over 0 to 1, the last again at 1 where they
    /// are all at one place - a colour line that does not pad is then
    /// nothing.
    fn putStops(walk: *Walk, stops: Stops) void {
        const line = stops.line orelse return;
        const count: u32 = walk.colr.word(line.at + 1);
        // Sorted by picking, again and again, the lowest after the last
        // one taken: of two alike, the earlier.
        var taken_offset: f32 = 0;
        var taken: u32 = 0;
        var taken_any = false;
        var last: Stop = undefined;
        var sorted: u32 = 0;
        while (sorted < count) : (sorted += 1) {
            var best: ?Stop = null;
            var best_nth: u32 = 0;
            var nth: u32 = 0;
            while (nth < count) : (nth += 1) {
                const stop = walk.stopAt(line, nth);
                const after = !taken_any or stop.offset > taken_offset or (stop.offset == taken_offset and nth > taken);
                if (!after) continue;
                if (best) |so_far| {
                    if (stop.offset >= so_far.offset) continue;
                }
                best = stop;
                best_nth = nth;
            }
            const stop = best orelse break;
            taken_offset = stop.offset;
            taken = best_nth;
            taken_any = true;
            last = stop;
            walk.putStop(stop, stops);
        }
        if (stops.padded) {
            var again = last;
            again.offset += 1;
            walk.putStop(again, stops);
        }
    }

    fn putStop(walk: *Walk, stop: Stop, stops: Stops) void {
        var step: PaintStep = .{ .kind = truetype.STEP_STOP, .offset = (stop.offset - stops.start) / stops.spread };
        walk.colr.colourOf(stop.index, stop.alpha, &step);
        walk.put(step);
    }
};

const pi: f32 = 3.14159265358979;

fn tangent(angle: f32) f32 {
    return @sin(angle) / @cos(angle);
}
