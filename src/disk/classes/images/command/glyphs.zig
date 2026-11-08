// SPDX-License-Identifier: MIT
//! The command pictures, each drawn on a `shapes.Painter` in design units:
//! 0 to 100 across and down its square. Kept apart from the class so that
//! a test can draw them alone.

const sdk = @import("sdk");
const shapes = sdk.gadgets.shapes;
const command = sdk.images.command;
const Painter = shapes.Painter;
const Shape = shapes.Shape;
const Hue = shapes.Hue;
const Pen = sdk.graphics.Pen;
const graphics = sdk.graphics;

/// Draws `glyph`; one past the last, or none, draws nothing. Each picture
/// is drawn by a function of its own, never put in line here, so that
/// drawing one takes the stack that picture needs and not what every
/// picture together would: a program's stack holds it, from a menu's or
/// a button's drawing.
pub fn draw(p: *Painter, glyph: u32) void {
    switch (glyph) {
        command.CMD_NEW => drawNew(p),
        command.CMD_OPEN => drawOpen(p),
        command.CMD_SAVE => drawSave(p),
        command.CMD_PRINT => drawPrint(p),
        command.CMD_CUT => drawCut(p),
        command.CMD_COPY => drawCopy(p),
        command.CMD_PASTE => drawPaste(p),
        command.CMD_UNDO => drawUndo(p),
        command.CMD_REDO => drawRedo(p),
        command.CMD_FIND => drawFind(p),
        command.CMD_ZOOM_IN => drawZoomIn(p),
        command.CMD_ZOOM_OUT => drawZoomOut(p),
        command.CMD_BOLD => drawBold(p),
        command.CMD_ITALIC => drawItalic(p),
        command.CMD_UNDERLINE => drawUnderline(p),
        command.CMD_ALIGN_LEFT => drawAlignLeft(p),
        command.CMD_ALIGN_CENTRE => drawAlignCentre(p),
        command.CMD_ALIGN_RIGHT => drawAlignRight(p),
        command.CMD_WRAP => drawWrap(p),
        command.CMD_SUM => drawSum(p),
        command.CMD_SORT => drawSort(p),
        command.CMD_INSERT_ROW => drawInsertRow(p),
        command.CMD_DELETE_ROW => drawDeleteRow(p),
        command.CMD_INSERT_COLUMN => drawInsertColumn(p),
        command.CMD_DELETE_COLUMN => drawDeleteColumn(p),
        command.CMD_SETTINGS => drawSettings(p),
        command.CMD_NUMBER => drawNumber(p),
        command.CMD_PERCENT => drawPercent(p),
        command.CMD_CURRENCY => drawCurrency(p),
        command.CMD_DECIMALS_MORE => drawDecimalsMore(p),
        command.CMD_DECIMALS_LESS => drawDecimalsLess(p),
        command.CMD_FILL => drawFill(p),
        command.CMD_CLEAR => drawClear(p),
        command.CMD_LINE_NUMBERS => drawLineNumbers(p),
        command.CMD_HIGHLIGHT => drawHighlight(p),
        command.CMD_REPLACE => drawReplace(p),
        command.CMD_SELECT_ALL => drawSelectAll(p),
        command.CMD_PARENT => drawParent(p),
        command.CMD_NEW_DRAWER => drawNewDrawer(p),
        command.CMD_RENAME => drawRename(p),
        command.CMD_DELETE => drawDelete(p),
        command.CMD_INFORMATION => drawInformation(p),
        command.CMD_UPDATE => drawUpdate(p),
        command.CMD_VIEW_ICONS => drawViewIcons(p),
        command.CMD_VIEW_LIST => drawViewList(p),
        command.CMD_VIEW_DATE => drawViewDate(p),
        command.CMD_VIEW_SIZE => drawViewSize(p),
        command.CMD_ALL_FILES => drawAllFiles(p),
        command.CMD_CLEAN_UP => drawCleanUp(p),
        command.CMD_SNAP_GRID => drawSnapGrid(p),
        command.CMD_SNAPSHOT => drawSnapshot(p),
        command.CMD_BACK => drawBack(p),
        command.CMD_FORWARD => drawForward(p),
        command.CMD_SHELL => drawShell(p),
        command.CMD_LAUNCHER => drawLauncher(p),
        else => {},
    }
}

// --- the pictures, one function each ----------------------------------------------

noinline fn drawNew(p: *Painter) void {
    sheet(p, 18, 6, 78, 92, 18, null);
    badge(p, 74, 76, 20, .green, .plus);
}

noinline fn drawOpen(p: *Painter) void {
    // The folder's back, a sheet in it, and its front.
    p.solid(&.{p.poly(&.{ .{ 6, 20 }, .{ 34, 20 }, .{ 42, 28 }, .{ 90, 28 }, .{ 90, 84 }, .{ 6, 84 } })}, .yellow, .{ .shade = true, .no_gloss = true });
    p.solid(&.{p.rr(16, 34, 80, 76, 2)}, .paper, .{ .no_shadow = true, .no_gloss = true });
    p.solid(&.{p.poly(&.{ .{ 20, 46 }, .{ 98, 46 }, .{ 86, 88 }, .{ 4, 88 } })}, .yellow, .{});
}

noinline fn drawSave(p: *Painter) void {
    // The disk, its shutter and its label.
    p.solid(&.{p.poly(&.{ .{ 8, 8 }, .{ 78, 8 }, .{ 92, 22 }, .{ 92, 92 }, .{ 8, 92 } })}, .blue, .{});
    p.solid(&.{p.rr(26, 8, 70, 36, 2)}, .metal, .{ .no_shadow = true, .no_gloss = true });
    if (p.detail) p.fill(p.rr(54, 13, 62, 31, 1), .{ .colour = shapes.tones(.blue).dark });
    p.solid(&.{p.rr(20, 50, 80, 92, 3)}, .paper, .{ .no_shadow = true, .no_gloss = true });
    if (p.detail) {
        p.stroke(28, 72, 62, 3.5, shapes.tones(.blue).base);
        p.stroke(28, 60, 74, 3.5, shapes.tones(.blue).base);
    }
}

noinline fn drawPrint(p: *Painter) void {
    p.solid(&.{p.rr(26, 6, 74, 40, 2)}, .paper, .{ .no_gloss = true });
    p.solid(&.{p.rr(6, 32, 94, 74, 9)}, .metal, .{});
    p.solid(&.{p.rr(18, 56, 82, 66, 3)}, .iron, .{ .no_shadow = true, .no_gloss = true });
    p.solid(&.{p.rr(24, 62, 76, 94, 2)}, .paper, .{ .no_gloss = true });
    if (p.detail) {
        p.stroke(32, 68, 72, 3.5, shapes.tones(.blue).base);
        p.stroke(32, 58, 82, 3.5, shapes.tones(.blue).base);
        // The lamp that says it is on.
        p.solid(&.{p.disc(82, 44, 5)}, .green, .{ .no_shadow = true, .no_gloss = true });
    }
}

noinline fn drawCut(p: *Painter) void {
    p.solid(&.{ p.poly(&shapes.taper(58, 68, 27, 5, 11, 2)), p.poly(&shapes.taper(42, 68, 73, 5, 11, 2)) }, .metal, .{});
    p.solid(&.{ p.ring(30, 78, 19, 7, 0, 360), p.ring(70, 78, 19, 7, 0, 360) }, .red, .{});
    if (p.detail) p.solid(&.{p.disc(50, 50, 4.5)}, .iron, .{ .no_shadow = true, .no_gloss = true });
}

noinline fn drawCopy(p: *Painter) void {
    sheet(p, 6, 4, 60, 70, 14, .blue);
    sheet(p, 36, 28, 92, 96, 16, .blue);
}

noinline fn drawPaste(p: *Painter) void {
    // The board, its clip and the clip's slot, and a sheet on it.
    p.solid(&.{p.rr(8, 12, 74, 94, 7)}, .brown, .{});
    p.solid(&.{p.rr(24, 4, 58, 20, 4)}, .metal, .{ .no_shadow = true });
    if (p.detail) p.fill(p.rr(35, 7.5, 47, 11.5, 2), .{ .colour = shapes.tones(.iron).dark });
    sheet(p, 40, 34, 94, 98, 14, .blue);
}

noinline fn drawUndo(p: *Painter) void {
    undo(p);
}

noinline fn drawRedo(p: *Painter) void {
    p.mirror = true;
    defer p.mirror = false;
    undo(p);
}

noinline fn drawFind(p: *Painter) void {
    lens(p, null);
}

noinline fn drawZoomIn(p: *Painter) void {
    lens(p, .plus);
}

noinline fn drawZoomOut(p: *Painter) void {
    lens(p, .minus);
}

/// The stem, three bars 13 thick and two bowls whose bands are as
/// thick, each meeting the middle bar exactly: the upper bowl with
/// its lower band, the wider lower one with its upper band.
noinline fn drawBold(p: *Painter) void {
    p.ink(&.{
        p.rr(22, 10, 38, 90, 0),
        p.rr(22, 10, 50, 23, 0),
        p.ring(50, 31.5, 21.5, 8.5, -90, 90),
        p.rr(22, 40, 51, 53, 0),
        p.ring(51, 65, 25, 12, -90, 90),
        p.rr(22, 77, 51, 90, 0),
    });
}

/// One outline, every part of it leaning the same way: a quarter
/// across for every unit down.
noinline fn drawItalic(p: *Painter) void {
    p.ink(&.{p.poly(&.{
        .{ 40, 10 },    .{ 80, 10 },    .{ 77.25, 21 }, .{ 64.25, 21 },
        .{ 49.75, 79 }, .{ 62.75, 79 }, .{ 60, 90 },    .{ 20, 90 },
        .{ 22.75, 79 }, .{ 35.75, 79 }, .{ 50.25, 21 }, .{ 37.25, 21 },
    })});
}

noinline fn drawUnderline(p: *Painter) void {
    p.ink(&.{ p.rr(22, 8, 36, 54, 0), p.rr(64, 8, 78, 54, 0), p.ring(50, 54, 28, 14, 180, 360) });
    p.solid(&.{p.rr(16, 84, 84, 96, 2)}, .red, .{ .no_shadow = true, .no_gloss = true });
}

noinline fn drawAlignLeft(p: *Painter) void {
    alignment(p, .left);
}

noinline fn drawAlignCentre(p: *Painter) void {
    alignment(p, .centre);
}

noinline fn drawAlignRight(p: *Painter) void {
    alignment(p, .right);
}

noinline fn drawWrap(p: *Painter) void {
    p.ink(&.{ p.rr(10, 12, 90, 22, 3), p.rr(10, 67, 38, 77, 3) });
    p.solid(&.{ p.rr(10, 37, 66, 47, 0), p.ring(66, 57, 20, 10, -90, 90), p.poly(&.{ .{ 66, 58 }, .{ 66, 86 }, .{ 44, 72 } }) }, .orange, .{});
}

noinline fn drawSum(p: *Painter) void {
    p.solid(&.{p.poly(&.{
        .{ 16, 8 },  .{ 84, 8 },  .{ 86, 30 }, .{ 76, 30 }, .{ 72, 20 }, .{ 40, 20 }, .{ 62, 50 }, .{ 40, 80 },
        .{ 72, 80 }, .{ 76, 70 }, .{ 86, 70 }, .{ 84, 92 }, .{ 16, 92 }, .{ 16, 86 }, .{ 46, 50 }, .{ 16, 14 },
    })}, .green, .{});
}

noinline fn drawSort(p: *Painter) void {
    p.ink(&.{ p.rr(52, 12, 72, 24, 2), p.rr(52, 40, 82, 52, 2), p.rr(52, 68, 92, 80, 2) });
    p.solid(&.{ p.poly(&shapes.bar(27, 8, 27, 60, 13)), p.poly(&.{ .{ 9, 56 }, .{ 45, 56 }, .{ 27, 90 } }) }, .violet, .{});
}

noinline fn drawInsertRow(p: *Painter) void {
    table(p, .green, .plus, .row);
}

noinline fn drawDeleteRow(p: *Painter) void {
    table(p, .red, .cross, .row);
}

noinline fn drawInsertColumn(p: *Painter) void {
    table(p, .green, .plus, .column);
}

noinline fn drawDeleteColumn(p: *Painter) void {
    table(p, .red, .cross, .column);
}

noinline fn drawSettings(p: *Painter) void {
    var cog: [teeth.len + 1]Shape = undefined;
    for (teeth, 0..) |tooth, i| cog[i] = p.poly(&tooth);
    cog[teeth.len] = p.ring(50, 50, 36, 15, 0, 360);
    p.solid(&cog, .metal, .{ .flat = true });
    p.solid(&.{p.ring(50, 50, 22, 15, 0, 360)}, .teal, .{ .no_shadow = true });
}

/// Two strokes leaning as an italic does and two across them.
noinline fn drawNumber(p: *Painter) void {
    p.solid(&.{
        p.poly(&shapes.bar(44, 8, 32, 92, 12)),
        p.poly(&shapes.bar(72, 8, 60, 92, 12)),
        p.rr(14, 28, 90, 40, 0),
        p.rr(10, 60, 86, 72, 0),
    }, .blue, .{});
}

noinline fn drawPercent(p: *Painter) void {
    p.solid(&.{
        p.poly(&shapes.bar(80, 8, 20, 92, 12)),
        p.ring(27, 27, 18, 8, 0, 360),
        p.ring(73, 73, 18, 8, 0, 360),
    }, .orange, .{});
}

noinline fn drawCurrency(p: *Painter) void {
    // The note, its middle lighter, and a coin with its rim.
    p.solid(&.{p.rr(4, 18, 80, 66, 5)}, .green, .{});
    if (p.detail) {
        p.fill(p.disc(42, 42, 13), .{ .colour = shapes.tones(.green).light });
        p.fill(p.ring(42, 42, 13, 9, 0, 360), .{ .colour = shapes.tones(.green).dark });
    }
    p.solid(&.{p.disc(70, 70, 25)}, .yellow, .{});
    if (p.detail) p.fill(p.ring(70, 70, 18, 14, 0, 360), .{ .colour = shapes.tones(.yellow).dark });
}

noinline fn drawDecimalsMore(p: *Painter) void {
    decimals(p, .green, .plus);
}

noinline fn drawDecimalsLess(p: *Painter) void {
    decimals(p, .red, .minus);
}

noinline fn drawFill(p: *Painter) void {
    p.solid(&.{p.rr(8, 6, 52, 33, 3)}, .blue, .{ .no_gloss = true });
    p.solid(&.{ p.rr(8, 37, 52, 64, 3), p.rr(8, 68, 52, 95, 3) }, .paper, .{ .no_gloss = true });
    p.solid(&.{ p.poly(&shapes.bar(76, 8, 76, 62, 14)), p.poly(&.{ .{ 58, 58 }, .{ 94, 58 }, .{ 76, 94 } }) }, .orange, .{});
}

noinline fn drawClear(p: *Painter) void {
    // Leaning a quarter turn's half, its sleeve at the lower end.
    p.ink(&.{p.rr(44, 88, 96, 94, 2)});
    p.solid(&.{p.poly(&.{ .{ 33, 39 }, .{ 58, 14 }, .{ 84, 40 }, .{ 59, 65 } })}, .red, .{});
    p.solid(&.{p.poly(&.{ .{ 8, 64 }, .{ 33, 39 }, .{ 59, 65 }, .{ 34, 90 } })}, .paper, .{});
}

noinline fn drawLineNumbers(p: *Painter) void {
    // The margin, a mark in it for each line's number, the lines.
    p.solid(&.{p.rr(6, 6, 32, 94, 4)}, .blue, .{ .no_gloss = true });
    const white = shapes.Paint{ .colour = shapes.white };
    for ([_]f32{ 14, 34, 54, 74 }) |y| p.fill(p.rr(13, y, 25, y + 10, 2), white);
    p.ink(&.{ p.rr(40, 14, 94, 24, 3), p.rr(40, 34, 80, 44, 3), p.rr(40, 54, 90, 64, 3), p.rr(40, 74, 66, 84, 3) });
}

noinline fn drawHighlight(p: *Painter) void {
    // A word or two of each line in a colour of its kind, the rest
    // in the ink.
    const plain = shapes.Solid{ .no_shadow = true, .no_gloss = true };
    p.ink(&.{ p.rr(44, 10, 92, 22, 3), p.rr(20, 54, 40, 66, 3) });
    p.solid(&.{p.rr(8, 10, 38, 22, 3)}, .violet, plain);
    p.solid(&.{p.rr(20, 32, 52, 44, 3)}, .blue, plain);
    p.solid(&.{p.rr(58, 32, 84, 44, 3)}, .orange, plain);
    p.solid(&.{p.rr(46, 54, 92, 66, 3)}, .green, plain);
    p.solid(&.{p.rr(8, 76, 72, 88, 3)}, .teal, plain);
}

noinline fn drawReplace(p: *Painter) void {
    // What was there, the arrow from it turning down, and what
    // takes its place; on each a line of white text.
    p.solid(&.{p.rr(6, 8, 46, 38, 4)}, .red, .{});
    p.solid(&.{ p.rr(44, 18, 62, 28, 0), p.ring(62, 39, 21, 11, 0, 90), p.poly(&.{ .{ 66, 39 }, .{ 90, 39 }, .{ 78, 58 } }) }, .orange, .{});
    p.solid(&.{p.rr(52, 60, 94, 92, 4)}, .green, .{});
    if (p.detail) {
        p.stroke(14, 38, 21, 4, shapes.white);
        p.stroke(60, 86, 74, 4, shapes.white);
    }
}

noinline fn drawSelectAll(p: *Painter) void {
    // What is selected, and round it the frame: four corners and a
    // dash between each two.
    p.fill(p.rr(20, 20, 80, 80, 2), .{ .colour = shapes.tones(.blue).light });
    p.ink(&.{ p.rr(26, 28, 74, 36, 2), p.rr(26, 46, 66, 54, 2), p.rr(26, 64, 56, 72, 2) });
    p.solid(&.{
        p.poly(&.{ .{ 6, 6 }, .{ 24, 6 }, .{ 24, 13 }, .{ 13, 13 }, .{ 13, 24 }, .{ 6, 24 } }),
        p.poly(&.{ .{ 76, 6 }, .{ 94, 6 }, .{ 94, 24 }, .{ 87, 24 }, .{ 87, 13 }, .{ 76, 13 } }),
        p.poly(&.{ .{ 6, 76 }, .{ 13, 76 }, .{ 13, 87 }, .{ 24, 87 }, .{ 24, 94 }, .{ 6, 94 } }),
        p.poly(&.{ .{ 87, 76 }, .{ 94, 76 }, .{ 94, 94 }, .{ 76, 94 }, .{ 76, 87 }, .{ 87, 87 } }),
        p.rr(41, 6, 59, 13, 0),
        p.rr(41, 87, 59, 94, 0),
        p.rr(6, 41, 13, 59, 0),
        p.rr(87, 41, 94, 59, 0),
    }, .blue, .{ .flat = true, .no_shadow = true });
}

noinline fn drawParent(p: *Painter) void {
    folder(p, 6, 30, 94, 94);
    p.solid(&.{ p.poly(&.{ .{ 50, 4 }, .{ 80, 36 }, .{ 20, 36 } }), p.rr(40, 32, 60, 76, 2) }, .blue, .{});
}

noinline fn drawNewDrawer(p: *Painter) void {
    folder(p, 4, 14, 86, 82);
    badge(p, 74, 76, 20, .green, .plus);
}

noinline fn drawRename(p: *Painter) void {
    // The field, the name in it, and the cursor standing out of
    // it at both ends. The name is dark on the paper, not the ink,
    // which is light on a dark screen.
    p.solid(&.{p.rr(4, 28, 92, 72, 6)}, .paper, .{ .no_gloss = true });
    p.fill(p.rr(14, 42, 58, 58, 3), .{ .colour = shapes.tones(.iron).base });
    p.solid(&.{ p.rr(67, 14, 75, 86, 0), p.rr(59, 14, 83, 21, 0), p.rr(59, 79, 83, 86, 0) }, .blue, .{ .flat = true, .no_shadow = true });
}

noinline fn drawDelete(p: *Painter) void {
    // The bin narrowing downward, its ribs, the lid and its handle.
    p.solid(&.{p.poly(&.{ .{ 18, 30 }, .{ 82, 30 }, .{ 75, 95 }, .{ 25, 95 } })}, .metal, .{});
    if (p.detail) {
        const rib = shapes.Paint{ .colour = shapes.tones(.metal).dark };
        p.fill(p.poly(&shapes.bar(35, 42, 38, 84, 5)), rib);
        p.fill(p.poly(&shapes.bar(50, 42, 50, 84, 5)), rib);
        p.fill(p.poly(&shapes.bar(65, 42, 62, 84, 5)), rib);
    }
    p.solid(&.{p.rr(37, 5, 63, 21, 5)}, .iron, .{ .no_gloss = true });
    p.solid(&.{p.rr(10, 15, 90, 29, 4)}, .metal, .{});
}

noinline fn drawInformation(p: *Painter) void {
    p.solid(&.{p.disc(50, 50, 45)}, .blue, .{});
    const white = shapes.Paint{ .colour = shapes.white };
    p.fill(p.disc(50, 26, 8), white);
    p.fill(p.rr(43, 40, 57, 78, 0), white);
    if (p.detail) {
        p.fill(p.rr(36, 40, 57, 47, 0), white);
        p.fill(p.rr(36, 71, 64, 78, 0), white);
    }
}

noinline fn drawUpdate(p: *Painter) void {
    p.solid(&.{
        p.ring(50, 50, 40, 26, 30, 150),
        p.poly(&update_heads[0]),
        p.ring(50, 50, 40, 26, 210, 330),
        p.poly(&update_heads[1]),
    }, .green, .{});
}

noinline fn drawViewIcons(p: *Painter) void {
    // Each a tile and its name under it, drawers and files.
    for ([_][2]f32{ .{ 6, 6 }, .{ 56, 6 }, .{ 6, 56 }, .{ 56, 56 } }, 0..) |at, i| {
        p.solid(&.{p.rr(at[0] + 5, at[1], at[0] + 33, at[1] + 28, 4)}, if (i == 0 or i == 3) .yellow else .blue, .{});
        p.ink(&.{p.rr(at[0], at[1] + 32, at[0] + 38, at[1] + 38, 2)});
    }
}

noinline fn drawViewList(p: *Painter) void {
    for ([_]f32{ 10, 40, 70 }, [_]f32{ 94, 76, 86 }, 0..) |y, end, i| {
        p.solid(&.{p.rr(6, y, 26, y + 20, 3)}, if (i == 0) .yellow else .blue, .{ .no_gloss = true });
        p.ink(&.{p.rr(34, y + 6, end, y + 14, 3)});
    }
}

noinline fn drawViewDate(p: *Painter) void {
    // The page, its top, the two rings, and the days as a grid.
    p.solid(&.{p.rr(8, 14, 92, 94, 6)}, .paper, .{ .no_gloss = true });
    p.solid(&.{p.rr(8, 14, 92, 38, 6)}, .red, .{ .no_shadow = true, .no_gloss = true });
    p.solid(&.{ p.rr(26, 4, 36, 26, 4), p.rr(64, 4, 74, 26, 4) }, .iron, .{ .no_shadow = true, .no_gloss = true });
    if (p.detail) {
        const day = shapes.Paint{ .colour = shapes.tones(.iron).light };
        for ([_]f32{ 48, 63, 78 }) |y| {
            for ([_]f32{ 18, 34, 50, 66 }) |x| p.fill(p.rr(x, y, x + 10, y + 9, 1), day);
        }
    }
}

noinline fn drawViewSize(p: *Painter) void {
    p.solid(&.{
        p.rr(6, 62, 30, 92, 3),
        p.rr(38, 38, 62, 92, 3),
        p.rr(70, 10, 94, 92, 3),
    }, .blue, .{});
}

noinline fn drawAllFiles(p: *Painter) void {
    // A plain sheet, and the eye: its white, the iris, the pupil
    // and a glint.
    sheet(p, 8, 4, 64, 74, 14, null);
    p.solid(&.{p.poly(&eye)}, .paper, .{ .no_gloss = true });
    p.solid(&.{p.disc(62, 68, 14)}, .blue, .{ .no_shadow = true, .no_gloss = true });
    p.fill(p.disc(62, 68, 6), .{ .colour = shapes.tones(.iron).dark });
    if (p.detail) p.fill(p.disc(57, 63, 3), .{ .colour = shapes.white });
}

noinline fn drawCleanUp(p: *Painter) void {
    // The handle, the band round the bristles' top, the bristles.
    p.solid(&.{p.poly(&shapes.bar(84, 6, 50, 52, 10))}, .brown, .{});
    p.solid(&.{p.poly(&.{ .{ 30, 52 }, .{ 62, 52 }, .{ 92, 94 }, .{ 8, 94 } })}, .yellow, .{});
    p.solid(&.{p.rr(28, 46, 64, 56, 3)}, .red, .{ .no_shadow = true, .no_gloss = true });
    if (p.detail) {
        const straw = shapes.Paint{ .colour = shapes.tones(.yellow).dark };
        p.fill(p.poly(&shapes.bar(38, 60, 28, 92, 3)), straw);
        p.fill(p.poly(&shapes.bar(50, 60, 50, 92, 3)), straw);
        p.fill(p.poly(&shapes.bar(62, 60, 72, 92, 3)), straw);
    }
}

noinline fn drawSnapGrid(p: *Painter) void {
    // The grid behind, then the magnet: its bow, its arms, and
    // the bare ends that hold.
    var dots: [9]Shape = undefined;
    for (0..9) |i| {
        const x = 14 + @as(f32, @floatFromInt(i % 3)) * 36;
        const y = 14 + @as(f32, @floatFromInt(i / 3)) * 36;
        dots[i] = p.rr(x - 4, y - 4, x + 4, y + 4, 4);
    }
    p.ink(&dots);
    p.solid(&.{ p.ring(50, 54, 32, 14, 180, 360), p.rr(18, 20, 36, 54, 0), p.rr(64, 20, 82, 54, 0) }, .red, .{});
    p.solid(&.{ p.rr(18, 8, 36, 22, 0), p.rr(64, 8, 82, 22, 0) }, .metal, .{ .no_shadow = true });
}

noinline fn drawSnapshot(p: *Painter) void {
    // The top with the button, the body, the lens and its glass,
    // and the lamp.
    p.solid(&.{ p.rr(30, 16, 62, 34, 4), p.rr(70, 20, 84, 30, 2) }, .iron, .{ .no_gloss = true });
    p.solid(&.{p.rr(6, 28, 94, 86, 8)}, .iron, .{});
    p.solid(&.{p.ring(50, 57, 22, 14, 0, 360)}, .metal, .{ .no_shadow = true });
    p.fill(p.disc(50, 57, 14), .{ .colour = shapes.tones(.blue).base });
    if (p.detail) {
        p.fill(p.disc(45, 52, 4), .{ .colour = 0xCCFF_FFFF });
        p.solid(&.{p.rr(14, 36, 24, 44, 2)}, .yellow, .{ .no_shadow = true, .no_gloss = true });
    }
}

noinline fn drawBack(p: *Painter) void {
    back(p);
}

noinline fn drawForward(p: *Painter) void {
    p.mirror = true;
    defer p.mirror = false;
    back(p);
}

noinline fn drawShell(p: *Painter) void {
    // The console's window, its prompt and the cursor after it,
    // light on the dark whatever the screen's pens are.
    p.solid(&.{p.rr(4, 10, 96, 90, 7)}, .iron, .{});
    const prompt = shapes.Paint{ .colour = shapes.tones(.green).light };
    p.fill(p.poly(&.{ .{ 16, 30 }, .{ 28, 30 }, .{ 46, 50 }, .{ 28, 70 }, .{ 16, 70 }, .{ 34, 50 } }), prompt);
    p.fill(p.rr(52, 62, 76, 70, 1), prompt);
}

/// The box's top and left edge, and the arrow out of its corner,
/// its head filling the opposite one.
noinline fn drawLauncher(p: *Painter) void {
    p.ink(&.{
        p.rr(8, 8, 62, 21, 0),
        p.rr(8, 8, 21, 62, 0),
        p.poly(&shapes.bar(34, 34, 74, 74, 13)),
        p.poly(&.{ .{ 92, 46 }, .{ 92, 92 }, .{ 46, 92 } }),
    });
}

/// A closed folder from (`x0`, `y0`) to (`x1`, `y1`): its back, shaded as
/// an open one's is, with the tab at its top left, and its front over it.
fn folder(p: *Painter, x0: f32, y0: f32, x1: f32, y1: f32) void {
    const tab = (x1 - x0) * 0.34;
    const step = (y1 - y0) * 0.12;
    p.solid(&.{p.poly(&.{ .{ x0, y0 }, .{ x0 + tab, y0 }, .{ x0 + tab + step, y0 + step }, .{ x1, y0 + step }, .{ x1, y1 }, .{ x0, y1 } })}, .yellow, .{ .shade = true, .no_gloss = true });
    p.solid(&.{p.rr(x0, y0 + step * 2, x1, y1, 3)}, .yellow, .{});
}

/// The arrow pointing back, to the left: its head and its shaft.
fn back(p: *Painter) void {
    p.solid(&.{ p.poly(&.{ .{ 6, 50 }, .{ 46, 12 }, .{ 46, 88 } }), p.rr(40, 36, 94, 64, 3) }, .blue, .{});
}

/// The heads of Update's two arrows, each at the end of its band,
/// pointing on round clockwise.
const update_heads = [2][3][2]f32{ head(50, 50, 40, 26, 30, -36, 9), head(50, 50, 40, 26, 210, -36, 9) };

/// An arrow's head at the end of a ring's band round (`cx`, `cy`), from
/// `inner` out to `outer`: its base across the band at `angle` degrees,
/// `spread` past it on both sides, its point on the band's middle `ahead`
/// degrees on - anticlockwise, or clockwise when negative.
fn head(cx: f32, cy: f32, outer: f32, inner: f32, angle: f32, ahead: f32, spread: f32) [3][2]f32 {
    const radians = 3.14159265 / 180.0;
    const base = angle * radians;
    const point = (angle + ahead) * radians;
    const middle = (outer + inner) / 2;
    return .{
        .{ cx + (inner - spread) * @cos(base), cy - (inner - spread) * @sin(base) },
        .{ cx + (outer + spread) * @cos(base), cy - (outer + spread) * @sin(base) },
        .{ cx + middle * @cos(point), cy - middle * @sin(point) },
    };
}

/// All Files' eye round (62, 68): two bows meeting in points at its
/// corners, 34 to each side and 20 up and down.
const eye = blk: {
    const cx = 62.0;
    const cy = 68.0;
    const half = 34.0;
    const rise = 20.0;
    var out: [14][2]f32 = undefined;
    out[0] = .{ cx - half, cy };
    out[7] = .{ cx + half, cy };
    for (0..6) |i| {
        const t = (@as(f32, @floatFromInt(i)) + 1) / 7 * 2 - 1;
        const y = rise * (1 - t * t);
        out[1 + i] = .{ cx + t * half, cy - y };
        out[13 - i] = .{ cx + t * half, cy + y };
    }
    break :blk out;
};

/// The arrow turning back: most of a ring and its head.
fn undo(p: *Painter) void {
    p.solid(&.{ p.ring(54, 58, 35, 17, -40, 180), p.poly(&.{ .{ 6, 55 }, .{ 50, 55 }, .{ 28, 88 } }) }, .blue, .{});
}

/// `.0` in the ink - a point and a nought of two half rings and the
/// sides between - and a badge in `hue`.
fn decimals(p: *Painter, hue: Hue, mark: Mark) void {
    p.ink(&.{
        p.rr(6, 50, 18, 62, 3),
        p.ring(40, 20, 16, 8, 0, 180),
        p.ring(40, 46, 16, 8, 180, 360),
        p.rr(24, 20, 32, 46, 0),
        p.rr(48, 20, 56, 46, 0),
    });
    badge(p, 74, 76, 21, hue, mark);
}

/// The cog's eight teeth, bars from the rim outward between the eighths.
const teeth = blk: {
    var out: [8][4][2]f32 = undefined;
    for (&out, 0..) |*tooth, i| {
        const a: f32 = (@as(f32, @floatFromInt(i)) * 45 + 22.5) * (3.14159265 / 180.0);
        tooth.* = shapes.bar(50 + 28 * @cos(a), 50 - 28 * @sin(a), 50 + 45 * @cos(a), 50 - 45 * @sin(a), 16);
    }
    break :blk out;
};

/// A sheet of paper from (`x0`, `y0`) to (`x1`, `y1`), its top right
/// corner folded over by `fold`, with four lines of text on it - in
/// `lines`' hue, or a quiet grey.
fn sheet(p: *Painter, x0: f32, y0: f32, x1: f32, y1: f32, fold: f32, lines: ?Hue) void {
    p.solid(&.{p.poly(&.{ .{ x0, y0 }, .{ x1 - fold, y0 }, .{ x1, y0 + fold }, .{ x1, y1 }, .{ x0, y1 } })}, .paper, .{ .no_gloss = true });
    p.solid(&.{p.poly(&.{ .{ x1 - fold, y0 }, .{ x1 - fold, y0 + fold }, .{ x1, y0 + fold } })}, .metal, .{ .no_shadow = true, .no_gloss = true });
    if (!p.detail) return;
    const colour: Pen = if (lines) |hue| shapes.tones(hue).base else 0xFFC4_CBD5;
    const left = x0 + 9;
    const right = x1 - 9;
    const step = (y1 - y0 - fold - 10) / 4;
    for (0..4) |i| {
        const y = y0 + fold + 6 + @as(f32, @floatFromInt(i)) * step;
        p.stroke(left, if (i == 3) left + (right - left) * 0.6 else right, y, 3.5, colour);
    }
}

const Mark = enum { plus, minus, cross };

/// A round badge in `hue` with a white mark on it.
fn badge(p: *Painter, cx: f32, cy: f32, r: f32, hue: Hue, mark: Mark) void {
    p.solid(&.{p.disc(cx, cy, r)}, hue, .{});
    const w = r * 0.34;
    const l = r * 0.62;
    const white = shapes.Paint{ .colour = shapes.white };
    switch (mark) {
        .plus, .minus => {
            p.fill(p.rr(cx - l, cy - w / 2, cx + l, cy + w / 2, 0), white);
            if (mark == .plus) p.fill(p.rr(cx - w / 2, cy - l, cx + w / 2, cy + l, 0), white);
        },
        .cross => {
            const e = l * 0.75;
            p.fill(p.poly(&shapes.bar(cx - e, cy - e, cx + e, cy + e, w)), white);
            p.fill(p.poly(&shapes.bar(cx - e, cy + e, cx + e, cy - e, w)), white);
        },
    }
}

/// The magnifying glass: its handle, its rim, the glass shading from
/// light to blue, and a glint on it - or, for a zoom, a plus or a minus.
fn lens(p: *Painter, mark: ?Mark) void {
    p.solid(&.{p.poly(&shapes.bar(62, 62, 91, 91, 15))}, .iron, .{});
    p.solid(&.{p.ring(40, 40, 32, 22, 0, 360)}, .metal, .{});
    const blue = shapes.tones(.blue);
    const glass: shapes.Paint = if (p.detail) .{ .fill = .{
        .kind = graphics.FILL_RADIAL,
        .from_x = graphics.FILL_ONE * 32 / 100,
        .from_y = graphics.FILL_ONE * 28 / 100,
        .to_x = graphics.FILL_ONE,
        .to_y = graphics.FILL_ONE,
        .count = 3,
        .stops = .{
            .{ .at = 0, .pen = 0xFFF4_FBFF },
            .{ .at = graphics.FILL_ONE * 6 / 10, .pen = blue.light },
            .{ .at = graphics.FILL_ONE, .pen = shapes.withAlpha(blue.base, 0xE6) },
            .{},
        },
    } } else .{ .colour = blue.light };
    p.fill(p.disc(40, 40, 22), glass);
    if (mark) |m| {
        const ink = shapes.Paint{ .colour = blue.dark };
        p.fill(p.rr(27, 37, 53, 43, 0), ink);
        if (m == .plus) p.fill(p.rr(37, 27, 43, 53, 0), ink);
    } else if (p.detail) {
        p.fill(p.disc(32, 31, 6), .{ .colour = 0xCCFF_FFFF });
    }
}

const Lines = enum { row, column };

/// A small table, its heading blue, a row or a column picked out in
/// `hue`, and a badge in the same hue.
fn table(p: *Painter, hue: Hue, mark: Mark, picked: Lines) void {
    p.solid(&.{p.rr(6, 14, 80, 86, 4)}, .paper, .{ .no_gloss = true });
    p.solid(&.{p.rr(6, 14, 80, 32, 3)}, .blue, .{ .no_shadow = true, .no_gloss = true });
    // Inside the rim, in pixels.
    const d = p.rim;
    const left = p.u(6) + d;
    const right = p.u(80) - d;
    const bottom = p.u(86) - d;
    const light = shapes.Paint{ .colour = shapes.tones(hue).light };
    switch (picked) {
        .row => p.fill(box(left, p.u(50), right, p.u(68)), light),
        .column => p.fill(box(p.u(31) + d, p.u(32), p.u(56), bottom), light),
    }
    if (p.detail) {
        const grid = shapes.Paint{ .colour = 0xFFB0_B8C4 };
        for ([_]f32{ 31, 56 }) |x| p.fill(box(p.u(x), p.u(32), p.u(x) + d, bottom), grid);
        for ([_]f32{ 50, 68 }) |y| p.fill(box(left, p.u(y), right, p.u(y) + d), grid);
    }
    badge(p, 78, 78, 21, hue, mark);
}

/// A box in pixels, not design units.
fn box(x0: i32, y0: i32, x1: i32, y1: i32) Shape {
    return .{ .box = .{ .x0 = @floatFromInt(x0), .y0 = @floatFromInt(y0), .x1 = @floatFromInt(x1), .y1 = @floatFromInt(y1), .radius = 0 } };
}

const Flush = enum { left, centre, right };

/// Four lines of text in the ink, of two lengths, flush to a side or
/// centred.
fn alignment(p: *Painter, flush: Flush) void {
    for ([_]f32{ 76, 52, 76, 44 }, 0..) |w, i| {
        const y = 14 + @as(f32, @floatFromInt(i)) * 20;
        const x0: f32 = switch (flush) {
            .left => 12,
            .centre => 50 - w / 2,
            .right => 88 - w,
        };
        p.ink(&.{p.rr(x0, y, x0 + w, y + 10, 2)});
    }
}
