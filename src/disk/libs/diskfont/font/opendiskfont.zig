// SPDX-License-Identifier: MIT
//! OpenDiskFont: the nearest font to what is asked for, loaded or scaled
//! as needed.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const graphics = sdk.graphics;
const fontfile = sdk.diskfont.fontfile;
const TextFont = graphics.TextFont;
const TextAttr = graphics.TextAttr;
const _base = @import("../diskfont_base.zig");
const DiskfontBase = _base.DiskfontBase;
const _font = @import("_font.zig");
const Contents = _font.Contents;

/// The nearest font to what is asked for, loaded or scaled as needed.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenDiskFont(dfb: *DiskfontBase, text_attr: *const TextAttr) ?*TextFont
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `text_attr` - the font's name ("spleen.font", or a path to its
///   contents file), height - in rows, or in points with `FPF_POINTS` -
///   style and flags. A height of 0 is 1.
///
/// RESULT:
/// The font, open: close it with graphics' `CloseFont`. Null if there is
/// no font of the name, or none that will do - `FPF_DESIGNED` asked for
/// and no size drawn.
///
/// BEHAVIOR:
/// **A font in memory that matches perfectly is answered at once.**
/// Otherwise the family's contents file is read - `FONTS:<name>`, or the
/// name as given when it has a ':' - and:
///
/// - **A family with an outline** (a TrueType file) takes a size drawn
///   at exactly the height and style asked when it has one, and otherwise
///   has truetype.library render the outline at that height - at any
///   height, and with `FPF_DESIGNED` too, since it is drawn and not
///   scaled.
/// - **Without `FPF_DESIGNED`**, a source is looked for at the height
///   asked, then twice it, then half it (when even), in memory first and
///   then among the family's sizes, the style asked for or one with
///   underline, then bold, then italic let go, since the soft styles can
///   draw those. Failing all of that, the nearest size by `WeighTAMatch`.
///   A source of another height is scaled to the height asked
///   (`NewScaledDiskFont`), and the scaled font kept like a loaded one.
/// - **With `FPF_DESIGNED`**, the nearest size drawn, by `WeighTAMatch`,
///   whether in memory or on the disk: never a scaled one.
///
/// A size read from the disk must be a whole font file (checked and
/// sound); one that is not is passed over for the next best. Fonts are
/// loaded one at a time, whoever asks.
///
/// CONTEXT:
/// - Waits: yes: for the disk, and for another task loading.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Process, since it reads files.
///
/// OWNERSHIP:
/// The font is the library's; the caller holds it open until
/// `CloseFont`. Once nobody holds it, it stays loaded for the next caller
/// until memory runs short.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `graphics.library/OpenFont`, `graphics.library/WeighTAMatch`,
/// `AvailFonts`, `NewScaledDiskFont`
///
/// EXAMPLES:
/// ```zig
/// const want = sdk.graphics.TextAttr{ .name = "spleen.font", .y_size = 16 };
/// const font = dfb.OpenDiskFont(&want) orelse return error.NoFont;
/// defer gb.CloseFont(font);
/// ```
pub fn OpenDiskFont(dfb: *DiskfontBase, text_attr: *const TextAttr) ?*TextFont {
    const gb = dfb.graphics_base;
    const dl = dfb.dos_base;
    const sys = dfb.sys_base;

    var want = text_attr.*;
    // In rows from here on: every size found, loaded or scaled is rows.
    want.y_size = @intCast(gb.FontRows(text_attr));
    want.flags &= ~graphics.FPF_POINTS;
    want.name = dl.FilePart(text_attr.name);
    if (want.y_size == 0) want.y_size = 1;

    sys.ObtainSemaphore(&dfb.load_lock);
    defer sys.ReleaseSemaphore(&dfb.load_lock);

    var ram = gb.OpenFont(&want);
    var ram_weight = weightOf(dfb, &want, ram);
    if (ram_weight == graphics.MAXFONTMATCHWEIGHT) return ram;

    var path: [256:0]u8 = @splat(0);
    contentsPath(dfb, text_attr.name, &path);
    var contents = _font.readContents(dfb, &path);
    defer contents.free(dfb);

    // A family with an outline: a size drawn at exactly this height and
    // style as drawn, any other made from the outline at this height.
    if (outlineOf(&contents)) |outline| {
        const made = openExactOnDisk(dfb, &want, &contents) orelse
            _font.renderOutline(dfb, contents.dir, @ptrCast(&outline.path), want.name, want.y_size);
        if (made) |font| {
            if (ram) |held| gb.CloseFont(held);
            return font;
        }
    }

    if (want.flags & graphics.FPF_DESIGNED != 0) {
        return openWeighed(dfb, &want, &contents, ram, ram_weight);
    }

    if (ram) |font| gb.CloseFont(font);
    const source = scaleSource(dfb, &want, &contents) orelse blk: {
        var designed = want;
        designed.flags |= graphics.FPF_DESIGNED;
        ram = gb.OpenFont(&designed);
        ram_weight = weightOf(dfb, &designed, ram);
        break :blk openWeighed(dfb, &designed, &contents, ram, ram_weight);
    } orelse return null;
    if (source.image.height == want.y_size) return source;

    const scaled = _base.iface(dfb).NewScaledDiskFont(source, &want) orelse return source;
    gb.CloseFont(source);
    return _font.addAndOpen(dfb, _font.recordOf(scaled));
}

/// How well an open font matches, 0 for none.
fn weightOf(dfb: *DiskfontBase, want: *const TextAttr, font: ?*TextFont) i32 {
    const found = font orelse return 0;
    const attr = _font.attrOf(found);
    return dfb.graphics_base.WeighTAMatch(want, &attr, null);
}

/// "FONTS:<name>", or the name itself when it names a place.
fn contentsPath(dfb: *DiskfontBase, name: [*:0]const u8, path: *[256:0]u8) void {
    var i: usize = 0;
    var placed = false;
    while (name[i] != 0) : (i += 1) {
        if (name[i] == ':') placed = true;
    }
    if (placed) {
        copy(path, name);
        return;
    }
    copy(path, sdk.diskfont.FONTSNAME);
    _ = dfb.dos_base.AddPart(path, name, path.len);
}

fn copy(to: *[256:0]u8, from: [*:0]const u8) void {
    var i: usize = 0;
    while (from[i] != 0 and i < to.len) : (i += 1) to[i] = from[i];
    to[i] = 0;
}

/// The styles that must agree for a font to stand in exactly: the ones
/// the font is drawn with.
const drawn_styles = graphics.FSF_UNDERLINED | graphics.FSF_BOLD | graphics.FSF_ITALIC;

/// A font at exactly `want`'s height and drawn styles: in memory, then
/// among the family's sizes. `scale_ok` lets a scaled font in memory
/// count.
fn openExact(dfb: *DiskfontBase, want: *const TextAttr, contents: *Contents, scale_ok: bool) ?*TextFont {
    const gb = dfb.graphics_base;
    var ask = want.*;
    if (!scale_ok) ask.flags |= graphics.FPF_DESIGNED;
    if (gb.OpenFont(&ask)) |font| {
        if (font.image.height == want.y_size and font.image.style & drawn_styles == want.style & drawn_styles) return font;
        gb.CloseFont(font);
    }
    for (contents.entries()) |*entry| {
        if (entry.y_size != want.y_size) continue;
        if (entry.style & drawn_styles != want.style & drawn_styles) continue;
        if (loadEntry(dfb, contents, entry, want.name)) |font| return font;
    }
    return null;
}

/// The family's outline entry, if it has one.
fn outlineOf(contents: *const Contents) ?*const fontfile.FontContents {
    for (contents.entries()) |*entry| {
        if (entry.outline != 0) return entry;
    }
    return null;
}

/// A size on the disk at exactly `want`'s height and drawn styles.
fn openExactOnDisk(dfb: *DiskfontBase, want: *const TextAttr, contents: *Contents) ?*TextFont {
    for (contents.entries()) |*entry| {
        if (entry.outline != 0 or entry.y_size != want.y_size) continue;
        if (entry.style & drawn_styles != want.style & drawn_styles) continue;
        if (loadEntry(dfb, contents, entry, want.name)) |font| return font;
    }
    return null;
}

/// A source to scale from: the height asked, twice it, half it, each
/// with the styles asked and then fewer.
fn scaleSource(dfb: *DiskfontBase, want: *const TextAttr, contents: *Contents) ?*TextFont {
    var ask = want.*;
    while (true) {
        ask.y_size = want.y_size;
        if (openExact(dfb, &ask, contents, true)) |font| return font;
        ask.y_size = want.y_size *| 2;
        if (openExact(dfb, &ask, contents, false)) |font| return font;
        if (want.y_size % 2 == 0) {
            ask.y_size = want.y_size / 2;
            if (openExact(dfb, &ask, contents, false)) |font| return font;
        }
        // A style the soft styles can draw is let go, one at a time.
        if (ask.style & graphics.FSF_UNDERLINED != 0) {
            ask.style &= ~graphics.FSF_UNDERLINED;
        } else if (ask.style & graphics.FSF_BOLD != 0) {
            ask.style &= ~graphics.FSF_BOLD;
        } else if (ask.style & graphics.FSF_ITALIC != 0) {
            ask.style &= ~graphics.FSF_ITALIC;
        } else {
            return null;
        }
    }
}

/// The heaviest of `ram` and the family's sizes against `want`; a size
/// heavier than the font in memory is loaded, and one that will not load
/// passed over for the next.
fn openWeighed(dfb: *DiskfontBase, want: *const TextAttr, contents: *Contents, ram: ?*TextFont, ram_weight: i32) ?*TextFont {
    const gb = dfb.graphics_base;
    const entries = contents.entries();
    var failed: [64]bool = @splat(false);
    while (true) {
        var best: ?usize = null;
        var best_weight = ram_weight;
        for (entries, 0..) |*entry, i| {
            if (i < failed.len and failed[i]) continue;
            const attr = TextAttr{
                .name = want.name,
                .y_size = entry.y_size,
                .style = entry.style,
                .flags = entry.flags | graphics.FPF_DISKFONT,
            };
            const weight = gb.WeighTAMatch(want, &attr, null);
            if (weight > best_weight) {
                best = i;
                best_weight = weight;
            }
        }
        const i = best orelse return ram;
        if (loadEntry(dfb, contents, &entries[i], want.name)) |font| {
            if (ram) |held| gb.CloseFont(held);
            return font;
        }
        if (i >= failed.len) return ram;
        failed[i] = true;
    }
}

/// An entry of the contents file, loaded.
fn loadEntry(dfb: *DiskfontBase, contents: *Contents, entry: *const fontfile.FontContents, name: [*:0]const u8) ?*TextFont {
    return _font.loadSize(dfb, contents.dir, @ptrCast(&entry.path), name);
}
