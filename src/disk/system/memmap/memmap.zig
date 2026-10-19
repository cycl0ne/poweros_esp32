// SPDX-License-Identifier: MIT
//! MemMap: where the memory is and who holds it, in a window. Built
//! against the SDK only.
//!
//!   MemMap INTERVAL/K/N
//!
//! INTERVAL is how often it looks again, in seconds (1).
//!
//! Every region on exec's memory list is a band of pixels: its lowest
//! address at the band's top left, on to the right and down, each pixel a
//! stretch of its bytes in the colour of whoever holds them - the system,
//! a task, a task that has ended (what it left behind), or nobody: free. A
//! private block (MEMF_PRIVATE) is a darker shade of its owner's colour.
//! Under the bands a legend says what the colours are: the system, the
//! tasks that hold the most, the ended ones together, the rest, free.
//!
//! On a machine whose RAM is one kind (the board's SYSTAG_UnifiedMemory)
//! the regions are pieces of that one RAM, so they share one band: in the
//! order of their addresses, each given pixels for its size, every pixel
//! the same number of bytes, and a short dark tick where one region ends
//! and the next begins. Amounts are in KB, MB or GB, as suits them.
//!
//! A look is the two steps of `sdk.exec.memowners`: the regions walked with
//! exec's memory list locked - a spinlock, under which this only writes
//! bytes into memory it took before, one a pixel, its owner's index - and
//! then the owners named after the tasks there are. The bands are drawn
//! after, from those bytes through a table of colours (`WriteLUTPixelArray`),
//! into a canvas as big as the window lets it be.
//!
//! Its own memory is private, so it shows itself in the darker shade.
//!
//! The close gadget or Ctrl-C end it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const motion = sdk.motion;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const MotionBase = sdk.interface.motion.MotionBase;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const Pen = graphics.Pen;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const sc = intuition.screens;
const classusr = intuition.classusr;
const cv = sdk.gadgets.canvas;
const figures = @import("figures.zig");
const amount = figures.amount;

pub const COMMAND_NAME = "MemMap";
const VERSION = "1.1";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (18.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
/// What the screen's bar says while its window is active.
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "INTERVAL/K/N";
const arg_interval = 0;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOMEMORY = "%s: no memory for the window\n";
const MSG_NOSCREEN = "%s: no screen to open on\n";
const MSG_NOWINDOW = "%s: no window\n";

/// The regions drawn, a band each; any more are counted, not drawn.
const max_regions = 6;
/// The regions drawn in the one band of a machine whose RAM is one kind.
const max_joined = 32;
/// The owners told apart. Each takes two pixel values - its colour and
/// the darker private one - below the three kept for the ticks between
/// regions, for the rest and for free.
const max_owners = 120;
const cell_mark: u8 = 0xFD;
const cell_rest: u8 = 0xFE;
const cell_free: u8 = 0xFF;
comptime {
    if (max_owners * 2 > cell_mark) @compileError("MemMap: more owners than pixel values");
}

/// The picture's size to start with, which is what it asks the layout for.
const start_width = 560;
const start_height = 380;
const margin = 6;
/// The legend's rows, each with two entries, and the status line above.
const legend_rows = 7;

/// The tasks that hold the most get a colour each, in this order; the
/// others share grey. As many as the legend has room for beside the
/// system, the ended tasks, free, private and the others.
const task_colours = [_]Pen{ 0xFF2E9E4F, 0xFFE08A1E, 0xFF8E44AD, 0xFF16A0B0, 0xFFC0A020, 0xFFD45087, 0xFF6B8E23, 0xFF3B5BDB, 0xFF8D6E63 };
const colour_free: Pen = 0xFFE4E4E4;
const colour_system: Pen = 0xFF5470A0;
const colour_ended: Pen = 0xFFD03030;
const colour_others: Pen = 0xFF9A9A9A;
const colour_mark: Pen = 0xFF202020;

fn pair(t: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = t, .data = data };
}

/// A colour two thirds as bright: what a private block of its owner's is
/// drawn in.
fn darker(colour: Pen) Pen {
    const red = (colour >> 16 & 0xFF) * 2 / 3;
    const green = (colour >> 8 & 0xFF) * 2 / 3;
    const blue = (colour & 0xFF) * 2 / 3;
    return 0xFF00_0000 | red << 16 | green << 8 | blue;
}

/// A band as the last look laid it out: one region's, or on a machine
/// whose RAM is one kind all of them.
const Band = struct {
    name: [40:0]u8 = @splat(0),
    size: usize = 0,
    /// Its first pixel's place in `Map.cells`, and its rows; a row is
    /// `Map.band_width` pixels.
    first: usize = 0,
    top: i32 = 0,
    rows: i32 = 0,
};

/// The pixels of `Map.cells` one region is drawn into: its band's, or its
/// share of the one band.
const Part = struct {
    first: usize = 0,
    pixels: usize = 0,
};

/// What the program keeps: too much for its stack, so it is in a block of
/// its own.
const Map = struct {
    sys: *ExecBase,
    gb: *GraphicsBase,
    ib: *IntuitionBase,
    canvas: *Object,
    window: *intuition.Window = undefined,
    draw_info: *intuition.DrawInfo,
    rp: *graphics.RastPort = undefined,
    width: i32 = start_width,
    height: i32 = start_height,
    interval: u32,
    /// Whether the board says its RAM is one kind: one band for all of it.
    unified: bool = false,
    /// The pixels of the bands, one byte each: an owner's index twice, one
    /// more when private, or `cell_mark`, `cell_rest` or `cell_free`.
    /// Allocated outside the walk, which may not allocate.
    cells: ?[*]u8 = null,
    cells_size: usize = 0,
    tally: exec.memowners.Tally(max_owners) = .{},
    bands: [max_regions]Band = @splat(.{}),
    band_count: usize = 0,
    parts: [max_joined]Part = @splat(.{}),
    band_width: usize = 0,
    regions_left_out: u32 = 0,
    /// Pixel value to colour.
    table: [256]Pen = @splat(colour_free),
    line_height: i32 = 12,
    baseline: i32 = 9,

    /// The picture made as big as the canvas's box, the RastPort it has
    /// then, the screen's font on it, and the pixels to match.
    fn fit(map: *Map) bool {
        _ = map.ib.SetGadgetAttrsTagList(map.canvas, map.window, &[_]TagItem{
            pair(cv.CANVAS_Width, 0),
            pair(cv.CANVAS_Height, 0),
            .{},
        });
        return map.takePicture();
    }

    fn takePicture(map: *Map) bool {
        var value: usize = 0;
        _ = map.ib.GetAttr(cv.CANVAS_RastPort, map.canvas, &value);
        map.rp = @ptrFromInt(value);
        _ = map.ib.GetAttr(cv.CANVAS_Width, map.canvas, &value);
        map.width = @intCast(value);
        _ = map.ib.GetAttr(cv.CANVAS_Height, map.canvas, &value);
        map.height = @intCast(value);
        if (map.draw_info.font) |font| graphics.SetFont(map.gb, map.rp, font);
        map.line_height = @max(map.rpAttr(graphics.RPTAG_FontHeight), 8) + 4;
        map.baseline = 2 + map.rpAttr(graphics.RPTAG_FontBaseline);
        const wanted: usize = @intCast(@max(map.width, 1) * @max(map.height, 1));
        if (wanted == map.cells_size) return true;
        if (map.cells) |old| map.sys.FreeVec(old);
        map.cells = @ptrCast(map.sys.AllocVec(wanted, exec.MEMF_PRIVATE));
        map.cells_size = if (map.cells != null) wanted else 0;
        return map.cells != null;
    }

    fn rpAttr(map: *Map, attr: sdk.utility.Tag) i32 {
        var value: u32 = 0;
        map.gb.GetRPAttrs(map.rp, &[_]TagItem{ pair(attr, @intFromPtr(&value)), .{} });
        return @intCast(value);
    }

    /// The bands laid out for the regions drawn: a band each - or one for
    /// all of them on a machine whose RAM is one kind - each a line for its
    /// name and as many rows as share the height left above the legend; and
    /// each region's pixels in them.
    fn place(map: *Map, regions: []const *const exec.MemHeader) void {
        const bands: usize = if (map.unified) @min(regions.len, 1) else regions.len;
        map.band_count = bands;
        const shown: i32 = @intCast(bands);
        map.band_width = @intCast(@max(map.width - 2 * margin, 1));
        const legend_height = (legend_rows + 1) * map.line_height + margin;
        const room = map.height - 2 * margin - legend_height - shown * map.line_height;
        const rows = @max(@divTrunc(room, @max(shown, 1)), 2);
        var top: i32 = margin;
        var first: usize = 0;
        for (map.bands[0..bands]) |*band| {
            band.top = top + map.line_height;
            band.rows = rows;
            band.first = first;
            first += map.band_width * @as(usize, @intCast(rows));
            top = band.top + rows;
        }
        if (!map.unified) {
            for (regions, map.bands[0..bands], map.parts[0..bands]) |region, *band, *part| {
                band.size = sizeOf(region);
                copyName(&band.name, region.node.name);
                part.* = .{ .first = band.first, .pixels = map.band_width * @as(usize, @intCast(band.rows)) };
            }
            return;
        }
        if (bands == 0) return;
        // One band: each region's pixels in proportion to its bytes, so a
        // pixel is the same number of bytes all along.
        const band = &map.bands[0];
        copyName(&band.name, "Memory");
        band.size = 0;
        for (regions) |region| band.size += sizeOf(region);
        const pixels = map.band_width * @as(usize, @intCast(band.rows));
        var before: usize = 0;
        for (regions, map.parts[0..regions.len]) |region, *part| {
            const piece = figures.share(before, sizeOf(region), band.size, pixels);
            before += sizeOf(region);
            part.* = .{ .first = band.first + piece.first, .pixels = piece.pixels };
        }
    }

    /// One look: the regions walked and their pixels painted under the
    /// memory list's lock, which allows nothing but writing into memory
    /// already taken, then the owners named.
    fn look(map: *Map) void {
        const sys = map.sys;
        map.tally = .{};
        map.band_count = 0;
        const list = sys.LockExecList(exec.EXECLIST_MEMORY).?;
        // The regions, as many as are kept apart: in the list's order, or
        // by address where they are pieces of one RAM.
        var order: [max_joined]*const exec.MemHeader = undefined;
        var kept: usize = 0;
        var count: usize = 0;
        var counting = list.iterator();
        while (counting.next()) |node| : (count += 1) {
            if (kept == order.len) continue;
            order[kept] = @fieldParentPtr("node", node);
            kept += 1;
        }
        if (map.unified) byAddress(order[0..kept]);
        const shown: usize = if (map.cells == null) 0 else if (map.unified) kept else @min(kept, max_regions);
        map.place(order[0..shown]);
        for (order[0..kept], 0..) |region, index| map.walkRegion(region, if (index < shown) &map.parts[index] else null);
        // Those past what `order` holds: counted, not drawn.
        var index: usize = 0;
        var rest = list.iterator();
        while (rest.next()) |node| : (index += 1) {
            if (index >= kept) map.walkRegion(@fieldParentPtr("node", node), null);
        }
        // A tick where one region of the one band ends and the next begins:
        // the first pixel of the next, and the ones above and below it.
        if (map.unified and shown > 1) {
            for (map.parts[1..shown]) |part| map.mark(part.first);
        }
        sys.UnlockExecList(exec.EXECLIST_MEMORY);
        map.regions_left_out = @intCast(count - shown);
        map.tally.name(sys);
        map.colour();
    }

    /// One region's blocks counted, and painted into `part` when it is
    /// drawn.
    fn walkRegion(map: *Map, region: *const exec.MemHeader, part: ?*const Part) void {
        map.tally.regions += 1;
        const drawn = part orelse &Part{};
        const into: []u8 = if (drawn.pixels != 0 and drawn.first + drawn.pixels <= map.cells_size) map.cells.?[drawn.first..][0..drawn.pixels] else &.{};
        @memset(into, cell_free);
        const size = sizeOf(region);
        var walk = exec.RegionWalk.init(region);
        while (walk.next()) |stretch| {
            const slot = map.tally.add(stretch);
            if (into.len == 0) continue;
            const value: u8 = if (stretch.free) cell_free else if (slot) |index| @intCast(index * 2 + @intFromBool(stretch.private)) else cell_rest;
            paint(into, @intFromPtr(region.lower), size, stretch, value);
        }
        if (map.tally.damaged == null) map.tally.damaged = walk.damaged;
    }

    /// The tick at pixel `at` of the one band.
    fn mark(map: *Map, at: usize) void {
        const cells = map.cells orelse return;
        const band = &map.bands[0];
        const end = band.first + map.band_width * @as(usize, @intCast(band.rows));
        if (at >= end or end > map.cells_size) return;
        cells[at] = cell_mark;
        if (at >= band.first + map.band_width) cells[at - map.band_width] = cell_mark;
        if (at + map.band_width < end) cells[at + map.band_width] = cell_mark;
    }

    /// The table from pixel values to colours: the system's, the ended
    /// tasks', and the living tasks' by how much they hold.
    fn colour(map: *Map) void {
        const tally = &map.tally;
        for (tally.owners[0..tally.used], 0..) |*owner, index| {
            const base: Pen = if (owner.system()) colour_system else if (!owner.living) colour_ended else taskColour(tally, owner);
            map.table[index * 2] = base;
            map.table[index * 2 + 1] = darker(base);
        }
        map.table[cell_mark] = colour_mark;
        map.table[cell_rest] = colour_others;
        map.table[cell_free] = colour_free;
    }

    /// Everything drawn into the picture, and the canvas asked to show it.
    fn draw(map: *Map) void {
        const gb = map.gb;
        const rp = map.rp;
        const paper = map.draw_info.pens[sc.BACKGROUNDPEN];
        const ink = map.draw_info.pens[sc.TEXTPEN];
        setPen(gb, rp, paper);
        gb.RectFill(rp, &.{ .max_x = map.width, .max_y = map.height });
        var text: [96:0]u8 = @splat(0);
        for (map.bands[0..map.band_count]) |*band| {
            const per_pixel = band.size / @max(map.band_width * @as(usize, @intCast(band.rows)), 1);
            var size_text: [24:0]u8 = @splat(0);
            var pixel_text: [24:0]u8 = @splat(0);
            _ = amount(&size_text, band.size);
            _ = amount(&pixel_text, @max(per_pixel, 1));
            const stream = exec.fmtStream(.{ @as([*:0]const u8, &band.name), @as([*:0]const u8, &size_text), @as([*:0]const u8, &pixel_text) });
            comptime exec.checkFormat("%s - %s, a pixel %s", @TypeOf(.{ @as([*:0]const u8, ""), @as([*:0]const u8, ""), @as([*:0]const u8, "") }));
            _ = map.sys.RawDoFmt("%s - %s, a pixel %s", &stream, null, &text);
            write(map, margin, band.top - map.line_height, ink, &text);
            const cells = map.cells orelse continue;
            gb.WriteLUTPixelArray(rp, cells + band.first, @intCast(map.band_width), &map.table, 0, 0, &.{
                .min_x = margin,
                .min_y = band.top,
                .max_x = margin + @as(i32, @intCast(map.band_width)),
                .max_y = band.top + band.rows,
            });
        }
        map.drawLegend(ink);
        map.ib.QueueGadgetRefresh(map.canvas);
    }

    /// The status line and the colours named, two to a row, under the
    /// bands.
    fn drawLegend(map: *Map, ink: Pen) void {
        const tally = &map.tally;
        var y = map.height - margin - (legend_rows + 1) * map.line_height;
        var text: [96:0]u8 = @splat(0);
        if (tally.damaged) |at| {
            const stream = exec.fmtStream(.{at});
            comptime exec.checkFormat("A region is damaged at 0x%08zx: the rest of it is not shown", @TypeOf(.{@as(usize, 0)}));
            _ = map.sys.RawDoFmt("A region is damaged at 0x%08zx: the rest of it is not shown", &stream, null, &text);
        } else if (map.regions_left_out != 0) {
            const stream = exec.fmtStream(.{ tally.regions, tally.blocks, map.regions_left_out, map.interval });
            comptime exec.checkFormat("%u regions, %u blocks (%u regions not shown) - every %u s", @TypeOf(.{ @as(u32, 0), @as(u32, 0), @as(u32, 0), @as(u32, 0) }));
            _ = map.sys.RawDoFmt("%u regions, %u blocks (%u regions not shown) - every %u s", &stream, null, &text);
        } else {
            const stream = exec.fmtStream(.{ tally.regions, tally.blocks, map.interval });
            comptime exec.checkFormat("%u regions, %u blocks - every %u s", @TypeOf(.{ @as(u32, 0), @as(u32, 0), @as(u32, 0) }));
            _ = map.sys.RawDoFmt("%u regions, %u blocks - every %u s", &stream, null, &text);
        }
        write(map, margin, y, ink, &text);
        y += map.line_height;

        // The entries: the system, the ended tasks together, free, private,
        // then the living tasks with colours of their own, then the rest.
        var entries: usize = 0;
        var system_bytes: usize = 0;
        var ended_bytes: usize = 0;
        var ended: u32 = 0;
        for (tally.owners[0..tally.used]) |*owner| {
            if (owner.system()) {
                system_bytes += owner.bytes;
            } else if (!owner.living) {
                ended_bytes += owner.bytes;
                ended += 1;
            }
        }
        map.legendEntry(&entries, y, colour_system, colour_system, "system", system_bytes);
        var ended_name: [32:0]u8 = @splat(0);
        const ended_stream = exec.fmtStream(.{ended});
        comptime exec.checkFormat("%u ended tasks", @TypeOf(.{@as(u32, 0)}));
        _ = map.sys.RawDoFmt("%u ended tasks", &ended_stream, null, &ended_name);
        map.legendEntry(&entries, y, colour_ended, colour_ended, &ended_name, ended_bytes);
        map.legendEntry(&entries, y, colour_free, colour_free, "free", tally.free_bytes);
        map.legendEntry(&entries, y, task_colours[0], darker(task_colours[0]), "darker: private", null);
        var rank: usize = 0;
        var others: usize = tally.rest.bytes;
        while (rank < task_colours.len) : (rank += 1) {
            const owner = rankedTask(tally, rank) orelse break;
            map.legendEntry(&entries, y, task_colours[rank], task_colours[rank], &owner.name, owner.bytes);
        }
        while (rankedTask(tally, rank)) |owner| : (rank += 1) others += owner.bytes;
        if (others != 0) map.legendEntry(&entries, y, colour_others, colour_others, "other tasks", others);
    }

    /// One entry of the legend: a swatch - two-toned when `shade` differs -
    /// and its words, with the amount when there is a count.
    fn legendEntry(map: *Map, index: *usize, top: i32, colour_value: Pen, shade: Pen, label: [*:0]const u8, bytes: ?usize) void {
        if (index.* >= 2 * legend_rows) return;
        const column: i32 = @intCast(index.* % 2);
        const row: i32 = @intCast(index.* / 2);
        index.* += 1;
        const x = margin + column * @divTrunc(map.width - 2 * margin, 2);
        const y = top + row * map.line_height;
        const swatch = map.line_height - 4;
        setPen(map.gb, map.rp, colour_value);
        map.gb.RectFill(map.rp, &.{ .min_x = x, .min_y = y + 2, .max_x = x + swatch, .max_y = y + 2 + swatch });
        setPen(map.gb, map.rp, shade);
        map.gb.RectFill(map.rp, &.{ .min_x = x + @divTrunc(swatch, 2), .min_y = y + 2, .max_x = x + swatch, .max_y = y + 2 + swatch });
        var text: [64:0]u8 = @splat(0);
        if (bytes) |count| {
            var count_text: [24:0]u8 = @splat(0);
            _ = amount(&count_text, count);
            const stream = exec.fmtStream(.{ label, @as([*:0]const u8, &count_text) });
            comptime exec.checkFormat("%s  %s", @TypeOf(.{ @as([*:0]const u8, ""), @as([*:0]const u8, "") }));
            _ = map.sys.RawDoFmt("%s  %s", &stream, null, &text);
        } else {
            const stream = exec.fmtStream(.{label});
            comptime exec.checkFormat("%s", @TypeOf(.{@as([*:0]const u8, "")}));
            _ = map.sys.RawDoFmt("%s", &stream, null, &text);
        }
        write(map, x + swatch + 6, y, map.draw_info.pens[sc.TEXTPEN], &text);
    }
};

/// The pixels of `into` that the stretch covers, set to `value`: the
/// region's `size` bytes spread over all of them, and at least one pixel
/// for any block.
fn paint(into: []u8, lower: usize, size: usize, stretch: exec.Stretch, value: u8) void {
    if (into.len == 0 or size == 0) return;
    const from: u64 = stretch.start - lower;
    const to: u64 = from + stretch.bytes;
    const pixels: u64 = into.len;
    const first: usize = @intCast(@min(from * pixels / size, pixels - 1));
    const last: usize = @intCast(@min(@max((to * pixels + size - 1) / size, first + 1), pixels));
    @memset(into[first..last], value);
}

/// A region's bytes.
fn sizeOf(region: *const exec.MemHeader) usize {
    return @intFromPtr(region.upper) - @intFromPtr(region.lower);
}

/// The regions by their lowest address; few enough to sort by insertion,
/// under the memory list's lock.
fn byAddress(regions: []*const exec.MemHeader) void {
    var index: usize = 1;
    while (index < regions.len) : (index += 1) {
        const moving = regions[index];
        var to = index;
        while (to > 0 and @intFromPtr(regions[to - 1].lower) > @intFromPtr(moving.lower)) : (to -= 1) regions[to] = regions[to - 1];
        regions[to] = moving;
    }
}

/// Whether the board says its RAM is one kind (SYSTAG_UnifiedMemory). No
/// when expansion.library is not there to ask.
fn unifiedMemory(sys: *ExecBase) bool {
    const expansion = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return false;
    defer sys.CloseLibrary(expansion);
    const utility = sys.OpenLibrary(sdk.utility.UTILITYNAME, 0) orelse return false;
    defer sys.CloseLibrary(utility);
    const eb: *ExpansionBase = @ptrCast(expansion);
    const ub: *UtilityBase = @ptrCast(utility);
    return ub.GetTagData(sdk.expansion.systemtags.SYSTAG_UnifiedMemory, 0, eb.SystemTags()) != 0;
}

/// The living task of rank `rank` - 0 holds the most - or null.
fn rankedTask(tally: anytype, rank: usize) ?*const exec.memowners.Owner {
    var found: ?*const exec.memowners.Owner = null;
    var bigger: usize = 0;
    // The owner with exactly `rank` living tasks holding more, the first
    // found among equals.
    for (tally.owners[0..tally.used]) |*owner| {
        if (owner.system() or !owner.living) continue;
        bigger = 0;
        for (tally.owners[0..tally.used], 0..) |*other, index| {
            if (other.system() or !other.living or other == owner) continue;
            if (other.bytes > owner.bytes or (other.bytes == owner.bytes and index < indexOf(tally, owner))) bigger += 1;
        }
        if (bigger == rank) found = owner;
    }
    return found;
}

fn indexOf(tally: anytype, owner: *const exec.memowners.Owner) usize {
    return (@intFromPtr(owner) - @intFromPtr(&tally.owners[0])) / @sizeOf(exec.memowners.Owner);
}

/// A living task's colour: its rank's, or grey past the colours there are.
fn taskColour(tally: anytype, owner: *const exec.memowners.Owner) Pen {
    var rank: usize = 0;
    while (rank < task_colours.len) : (rank += 1) {
        if (rankedTask(tally, rank) == owner) return task_colours[rank];
    }
    return colour_others;
}

fn setPen(gb: *GraphicsBase, rp: *graphics.RastPort, pen: Pen) void {
    gb.SetRPAttrs(rp, &[_]TagItem{ pair(graphics.RPTAG_APen, pen), .{} });
}

/// Words at `x`, the line whose top is `y`.
fn write(map: *Map, x: i32, y: i32, ink: Pen, text: [*:0]const u8) void {
    var length: u32 = 0;
    while (text[length] != 0) length += 1;
    if (length == 0) return;
    setPen(map.gb, map.rp, ink);
    map.gb.Move(map.rp, x, y + map.baseline);
    map.gb.Text(map.rp, text, length);
}

fn copyName(into: []u8, from: ?[*:0]const u8) void {
    const text = from orelse "?";
    var length: usize = 0;
    while (length + 1 < into.len and text[length] != 0) : (length += 1) into[length] = text[length];
    into[length] = 0;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const interval: u32 = @intCast(@min(@max(rdargs.number(argv[arg_interval]) orelse 1, 1), 3600));

    var libraries: [4]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_][*:0]const u8{ intuition.INTUITIONNAME, graphics.GRAPHICSNAME, motion.MOTIONNAME, cv.CANVAS_LIBRARY };
    for (wanted, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, name });
            return dos.RETURN_FAIL;
        };
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);
    const gb: *GraphicsBase = @ptrCast(libraries[1].?);
    const motion_base: *MotionBase = @ptrCast(libraries[2].?);

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);
    const draw_info = ib.GetScreenDrawInfo(screen);
    defer ib.FreeScreenDrawInfo(screen, draw_info);

    const canvas = ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
        pair(cv.CANVAS_Width, start_width),
        pair(cv.CANVAS_Height, start_height),
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Margin, 2),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(canvas)),
        .{},
    }) orelse {
        ib.DisposeObject(canvas);
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr("Memory Map")),
        pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
        pair(wn.WA_PubScreen, @intFromPtr(screen)),
        pair(wn.WA_AutoAdjust, 1),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_SizeGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wn.WA_IDCMP, wn.IDCMP_NEWSIZE),
        pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(object);

    // Its state is its own alone: private, as the pixels are.
    const map: *Map = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(Map), exec.MEMF_PRIVATE) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }));
    defer sys.FreeVec(map);
    map.* = .{ .sys = sys, .gb = gb, .ib = ib, .canvas = canvas, .draw_info = draw_info, .interval = interval, .unified = unifiedMemory(sys) };
    defer if (map.cells) |cells| sys.FreeVec(cells);

    var open = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }
    var window_pointer: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_pointer);
    map.window = @ptrFromInt(window_pointer);
    if (!map.fit()) {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }
    map.look();
    map.draw();

    // The clock: a look every interval.
    const bit = sys.AllocSignal(-1);
    if (bit < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(bit);
    const tick = motion_base.CreateTimerTagList(&[_]TagItem{
        pair(motion.TIMER_Period, interval * 1000),
        pair(motion.TIMER_Repeat, motion.TIMER_FOREVER),
        pair(motion.TIMER_Signal, @intCast(bit)),
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer motion_base.DeleteTimer(tick);
    motion_base.StartTimer(tick);
    const tick_mask = @as(u32, 1) << @intCast(bit);

    var code_word: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code_word };
    while (true) {
        const got = ib.WaitIMsg(map.window, tick_mask | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_OK;
        var again = got & tick_mask != 0;
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_NEWSIZE => {
                    if (!map.fit()) return dos.RETURN_FAIL;
                    again = true;
                },
                else => {},
            }
        }
        if (again) {
            map.look();
            map.draw();
        }
    }
}
