// SPDX-License-Identifier: MIT
//! The font requester: the families in one list, the sizes of the family
//! picked in another, and a line of the font itself under them.
//!
//! What there is comes from diskfont's `AvailFonts` - the fonts in memory
//! and the ones in `FONTS:`, an outline among them, which is any size
//! asked for. A family is listed once however many sizes it has; the
//! sizes list is built from the entries of the family picked, and for an
//! outline from a set of the sizes a font is usually wanted at.
//!
//! The sample is a list of one line that cannot be picked, drawn by a
//! hook of the requester's: it opens the font that is picked, draws the
//! line in it in its pens and styles on a ground of the back pen, and
//! closes it again when the pick changes. That is what a font requester
//! is for - seeing the font before choosing it - and nothing else here
//! can show a font that is not the window's.
//!
//! The drawing mode is answered and not shown: it says how the program
//! will lay the text down later, and a sample drawn in it would invert
//! its own ground under Complement and look the same under both Text
//! modes.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const graphics = sdk.graphics;
const diskfont = sdk.diskfont;
const intuition = sdk.intuition;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const wn = intuition.windows;
const sc = intuition.screens;
const asl = sdk.asl;
const lv = sdk.gadgets.listview;
const cb = sdk.gadgets.checkbox;
const cy = sdk.gadgets.cycle;
const pa = sdk.gadgets.palette;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const AslBase = @import("../asl_base.zig").AslBase;
const _request = @import("../request/_request.zig");
const Requester = _request.Requester;
const entries = @import("../file/entries.zig");
const Entry = entries.Entry;

const ID_FAMILIES = 1;
const ID_SIZES = 2;
const ID_SAMPLE = 3;
const ID_BOLD = 4;
const ID_ITALIC = 5;
const ID_UNDERLINED = 6;
const ID_FRONT = 7;
const ID_BACK = 8;
const ID_MODE = 9;
const ID_OK = 10;
const ID_CANCEL = 11;

/// How tall the sample line is: room for a font of a good size without
/// the window growing to fit the largest there is.
const sample_height = 48;

/// The line the sample is drawn with.
const sample_text = "The quick brown fox jumps over the lazy dog";

/// The sizes an outline font is offered at. An outline is any height
/// asked for, so the list is the heights a font is usually wanted at
/// rather than the heights it has.
const outline_sizes = [_]u32{ 8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64 };

/// The colours the two pens are picked from unless the program gives
/// its own (`ASLFO_FrontPens`, `ASLFO_BackPens`). Black and white, the
/// greys between them, and a spread of hues light and dark: enough to
/// tell what a font will look like in, which is all the choice is for.
///
/// The screen's own pens are not what is offered, as they were on a
/// machine whose screens had a palette: here they are a few greys, a
/// blue and a black, and a row of four colours is no choice at all.
const default_pens = [_]graphics.Pen{
    // The greys keep clear of the grey a window is drawn in, so that a
    // box of one does not read as a hole in the row.
    0xFF000000, 0xFF444444, 0xFF888888, 0xFFFFFFFF,
    0xFFCC3333, 0xFFEE7733, 0xFFEECC33, 0xFF33AA33,
    0xFF33BBBB, 0xFF3366CC, 0xFF7755CC, 0xFFAA55CC,
    0xFF884422, 0xFFEE99AA, 0xFF226644, 0xFF223366,
};

/// Where black and white are in it, which is what the two pens start as.
const pen_black = 0;
const pen_white = 3;

/// The drawing modes the cycle gadget offers, in the order of `modes`:
/// the three a piece of text can be laid down in, which are one or the
/// other and never both. `DRMD_INVERSVID` and `DRMD_BLEND` are not among
/// them - they are bits that say something more about whichever of these
/// is picked, so offering them here would make a program choose between
/// blending and laying a ground down. A program that sets one with
/// `ASLFO_InitialDrawMode` keeps it, and the cycle changes only the rest.
const mode_labels = [_:null]?[*:0]const u8{ "Text", "Text and field", "Complement" };
const modes = [_]graphics.DrawMode{ graphics.DRMD_JAM1, graphics.DRMD_JAM2, graphics.DRMD_COMPLEMENT };

/// The bits the three above are: what the cycle changes, leaving the rest
/// of the drawing mode as the program set it.
const mode_mask: u32 = graphics.DRMD_JAM1 | graphics.DRMD_JAM2 | graphics.DRMD_COMPLEMENT;

/// A font requester while it is up.
const Session = struct {
    r: *Requester,
    sys: *ExecBase,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    ub: *UtilityBase,
    df: *DiskfontBase,
    object: *Object = undefined,
    window: *intuition.Window = undefined,
    families_gadget: *Object = undefined,
    sizes_gadget: *Object = undefined,
    sample_gadget: *Object = undefined,
    /// The colours each palette offers.
    front_pens: [*]const graphics.Pen = undefined,
    front_count: u32 = 0,
    back_pens: [*]const graphics.Pen = undefined,
    back_count: u32 = 0,
    /// The lists: the families, the sizes of the one picked, and the one
    /// line of the sample.
    families: exec.List = .{},
    sizes: exec.List = .{},
    sample: exec.List = .{},
    sample_node: exec.Node = .{},
    /// What AvailFonts found, kept for as long as the requester is up:
    /// the entries point into it.
    found: ?[*]u8 = null,
    found_count: u32 = 0,
    /// The font the sample is drawn in, opened when the pick changes.
    shown_font: ?*graphics.TextFont = null,
    /// The hook that draws the sample.
    draw_hook: utility.Hook = .{},
    answered: bool = false,
};

fn textLen(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (s[n] != 0) n += 1;
    return n;
}

/// The family a font's name is: its name without the `.font` at the end.
fn familyOf(name: [*:0]const u8, into: []u8) []const u8 {
    var len = textLen(name);
    const tail = ".font";
    if (len > tail.len) {
        var same = true;
        for (tail, 0..) |c, i| {
            const here = name[len - tail.len + i];
            if (here != c and here != c - 0x20) same = false;
        }
        if (same) len -= tail.len;
    }
    const room = @min(len, into.len - 1);
    @memcpy(into[0..room], name[0..room]);
    into[room] = 0;
    return into[0..room];
}

// --- what there is ----------------------------------------------------------

/// Whether a font AvailFonts found is one this requester lists: the
/// heights it was given, and fixed width only where that was asked for.
/// An outline is any height, so no height rules it out.
fn wanted(s: *Session, entry: *const diskfont.AvailFonts) bool {
    const r = s.r;
    const outline = entry.type & diskfont.AFF_SCALABLE != 0;
    if (!outline) {
        const height = entry.attr.y_size;
        if (r.min_height != 0 and height < r.min_height) return false;
        if (r.max_height != 0 and height > r.max_height) return false;
    }
    if (r.flags1 & asl.FOF_FIXEDWIDTHONLY != 0) {
        // A font says it is fixed width by not saying it is proportional.
        if (entry.attr.flags & graphics.FPF_PROPORTIONAL != 0) return false;
    }
    return true;
}

fn availEntries(s: *Session) []const diskfont.AvailFonts {
    const block = s.found orelse return &.{};
    const header: *const diskfont.AvailFontsHeader = @ptrCast(@alignCast(block));
    return diskfont.availEntries(header);
}

/// Everything AvailFonts finds, into a block of the requester's. False
/// without memory: a requester with nothing to list is no requester.
fn readFonts(s: *Session) bool {
    const flags = diskfont.AFF_MEMORY | diskfont.AFF_DISK;
    var size: u32 = 4096;
    while (size <= 256 * 1024) : (size *= 2) {
        const block = s.sys.AllocVec(size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
        const more = s.df.AvailFonts(@ptrCast(block), size, flags);
        if (more == 0) {
            s.found = @ptrCast(block);
            return true;
        }
        s.sys.FreeVec(block);
    }
    return false;
}

/// The families, each once however many sizes it has.
fn fillFamilies(s: *Session) void {
    var name: [dos.name_max + 1]u8 = @splat(0);
    for (availEntries(s)) |*entry| {
        if (!wanted(s, entry)) continue;
        const family = familyOf(entry.attr.name, &name);
        if (family.len == 0) continue;
        var already = false;
        var node = s.families.first();
        while (node) |it| : (node = it.next()) {
            const line: *Entry = @fieldParentPtr("node", it);
            if (sameName(s.ub, line.name(), @ptrCast(&name))) {
                already = true;
                break;
            }
        }
        if (already) continue;
        _ = entries.addText(s.sys, s.ub, &s.families, @ptrCast(&name), "", dos.ST_FILE, 0);
    }
}

/// Two names, compared without regard to case.
fn sameName(ub: *UtilityBase, one: [*:0]const u8, other: [*:0]const u8) bool {
    var i: usize = 0;
    while (one[i] != 0 and other[i] != 0) : (i += 1) {
        if (ub.ToUpper(one[i]) != ub.ToUpper(other[i])) return false;
    }
    return one[i] == other[i];
}

/// The sizes of the family picked. An outline is offered at the sizes a
/// font is usually wanted at, since it is made at any of them.
fn fillSizes(s: *Session) void {
    entries.empty(s.sys, &s.sizes);
    const family: [*:0]const u8 = @ptrCast(&s.r.family);
    if (family[0] == 0) return;
    var name: [dos.name_max + 1]u8 = @splat(0);
    var digits: [8]u8 = @splat(0);
    var outline = false;
    for (availEntries(s)) |*entry| {
        if (!wanted(s, entry)) continue;
        const its = familyOf(entry.attr.name, &name);
        if (its.len == 0 or !sameName(s.ub, @ptrCast(&name), family)) continue;
        if (entry.type & diskfont.AFF_SCALABLE != 0) {
            outline = true;
            continue;
        }
        const height: u32 = entry.attr.y_size;
        if (haveSize(s, height)) continue;
        _ = entries.addText(s.sys, s.ub, &s.sizes, sizeText(height, &digits), "", 0, height);
    }
    if (!outline) return;
    for (outline_sizes) |height| {
        if (s.r.min_height != 0 and height < s.r.min_height) continue;
        if (s.r.max_height != 0 and height > s.r.max_height) continue;
        if (haveSize(s, height)) continue;
        _ = entries.addText(s.sys, s.ub, &s.sizes, sizeText(height, &digits), "", 0, height);
    }
}

/// Whether the sizes list already holds that height.
fn haveSize(s: *Session, height: u32) bool {
    var node = s.sizes.first();
    while (node) |it| : (node = it.next()) {
        const line: *Entry = @fieldParentPtr("node", it);
        if (line.size == height) return true;
    }
    return false;
}

fn sizeText(height: u32, into: *[8]u8) [*:0]const u8 {
    var digits: [8]u8 = undefined;
    var left = height;
    var count: usize = 0;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0 or count == digits.len) break;
    }
    var i: usize = 0;
    while (i < count) : (i += 1) into[i] = digits[count - 1 - i];
    into[i] = 0;
    return @ptrCast(into);
}

// --- the sample -------------------------------------------------------------

/// The font that is picked, opened; the one shown before it closed. A
/// font that will not open leaves the sample in the window's own, which
/// says as plainly as anything that the pick cannot be had.
fn openShown(s: *Session) void {
    if (s.shown_font) |font| {
        s.gb.CloseFont(font);
        s.shown_font = null;
    }
    const r = s.r;
    if (r.family[0] == 0 or r.size == 0) return;
    var name: [dos.name_max + 8]u8 = @splat(0);
    const len = @min(textLen(@ptrCast(&r.family)), name.len - 6);
    @memcpy(name[0..len], r.family[0..len]);
    @memcpy(name[len..][0..5], ".font");
    name[len + 5] = 0;
    const attr = graphics.TextAttr{
        .name = @ptrCast(&name),
        .y_size = @truncate(r.size),
        .style = r.public.font.attr.style,
        .flags = r.public.font.attr.flags,
    };
    s.shown_font = s.df.OpenDiskFont(&attr);
}

/// The sample line, drawn in the font that is picked, in its pens and its
/// drawing mode. The gadget draws nothing more of the line.
fn drawSample(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    const msg: *const lv.LVDrawMsg = @ptrCast(@alignCast(message.?));
    if (msg.method_id != lv.LV_DRAW) return lv.LVCB_UNKNOWN;
    const s: *Session = @ptrCast(@alignCast(hook.data.?));
    const gb = s.gb;
    const rp = msg.rast_port.?;
    const r = s.r;
    const styled = sdk.gadgets.support.pensFor(s.ib, msg.draw_info.?, null, intuition.style.PART_MAIN, null);
    const pens: [*]const graphics.Pen = &styled;
    const front = if (r.flags1 & asl.FOF_DOFRONTPEN != 0) r.public.font.front_pen else pens[sc.TEXTPEN];
    const back = if (r.flags1 & asl.FOF_DOBACKPEN != 0) r.public.font.back_pen else pens[sc.BACKGROUNDPEN];

    const ground = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = back },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(rp, &ground);
    gb.RectFill(rp, &msg.bounds);

    if (s.shown_font) |font| {
        graphics.SetFont(gb, rp, font);
        // A font drawn in the style asked for is the best answer; for the
        // rest, graphics draws the style over it. SetSoftStyle keeps only
        // what the font has not got already.
        _ = gb.SetSoftStyle(rp, r.public.font.attr.style, ~@as(u32, 0));
    }
    var baseline: u32 = 0;
    var height: u32 = 0;
    const ask_metrics = [_]TagItem{
        .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
        .{},
    };
    gb.GetRPAttrs(rp, &ask_metrics);
    // The styles are what the font was opened with, so nothing here has
    // to add them. The drawing mode is not put on: the sample shows the
    // font, the pens and the styles, and the mode is an answer for the
    // program to draw with rather than something to do to the sample -
    // laid on here, Complement would invert the ground the requester
    // just painted and the two Text modes would look alike, since the
    // ground under them is already the back pen.
    const ink = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = front },
        .{ .tag = graphics.RPTAG_BPen, .data = back },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(rp, &ink);
    const top = msg.bounds.min_y + @divTrunc(msg.bounds.max_y - msg.bounds.min_y - @as(i32, @intCast(height)), 2) + @as(i32, @intCast(baseline));
    var len: u32 = @intCast(sample_text.len);
    const room = msg.bounds.max_x - msg.bounds.min_x - 4;
    if (gb.TextLength(rp, sample_text, len) > room) {
        var extent: graphics.TextExtent = .{};
        len = gb.TextFit(rp, sample_text, len, &extent, null, 1, @max(room, 0), 0);
    }
    gb.Move(rp, msg.bounds.min_x + 2, top);
    gb.Text(rp, sample_text, len);
    return lv.LVCB_OK;
}

/// The sample drawn again, because the pick or the way it is drawn has
/// changed.
fn showSample(s: *Session) void {
    openShown(s);
    const tags = [_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&s.sample) }, .{} };
    _ = s.ib.SetGadgetAttrsTagList(s.sample_gadget, s.window, &tags);
}

// --- the window -------------------------------------------------------------

fn makeButton(s: *Session, text: [*:0]const u8, id: usize) ?*Object {
    return s.ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr(text) },
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
}

fn makeCheck(s: *Session, id: usize, on: bool) ?*Object {
    return s.ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = cb.CHECKBOX_Checked, .data = @intFromBool(on) },
        .{},
    });
}

fn makePalette(s: *Session, id: usize, table: [*]const graphics.Pen, count: u32, pen: u32) ?*Object {
    var which: u32 = 0;
    for (table[0..count], 0..) |value, i| {
        if (value == pen) which = @intCast(i);
    }
    return s.ib.NewObjectTagList(null, pa.PALETTE_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = pa.PALETTE_ColorTable, .data = @intFromPtr(table) },
        .{ .tag = pa.PALETTE_NumColors, .data = count },
        .{ .tag = pa.PALETTE_Color, .data = which },
        .{},
    });
}

/// The window object and everything in it. False with nothing made.
fn build(s: *Session, screen: *intuition.Screen) bool {
    const r = s.r;
    const ib = s.ib;
    s.draw_hook = .{ .entry = &drawSample, .data = @ptrCast(s) };

    const families = ib.NewObjectTagList(null, lv.LISTVIEW_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_FAMILIES },
        .{ .tag = lv.LISTVIEW_ShowSelected, .data = 1 },
        .{},
    });
    const sizes = ib.NewObjectTagList(null, lv.LISTVIEW_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_SIZES },
        .{ .tag = lv.LISTVIEW_ShowSelected, .data = 1 },
        .{ .tag = gc.GA_Width, .data = 60 },
        .{},
    });
    const sample = ib.NewObjectTagList(null, lv.LISTVIEW_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_SAMPLE },
        .{ .tag = lv.LISTVIEW_ReadOnly, .data = 1 },
        .{ .tag = lv.LISTVIEW_CallBack, .data = @intFromPtr(&s.draw_hook) },
        .{ .tag = lv.LISTVIEW_ItemHeight, .data = sample_height },
        .{ .tag = lv.LISTVIEW_ScrollWidth, .data = 0 },
        // One line tall and no more: a list made without a size asks for
        // room for six of its lines, and one of these is forty-eight
        // pixels.
        .{ .tag = gc.GA_Width, .data = 200 },
        .{ .tag = gc.GA_Height, .data = sample_height + 6 },
        .{},
    });
    const lists = if (families != null and sizes != null)
        ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(families) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(sizes) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 25 },
            .{},
        })
    else
        null;

    const ignore = utility.TAG_IGNORE;
    const style = r.flags1 & asl.FOF_DOSTYLE != 0;
    const bold = if (style) makeCheck(s, ID_BOLD, r.public.font.attr.style & graphics.FSF_BOLD != 0) else null;
    const italic = if (style) makeCheck(s, ID_ITALIC, r.public.font.attr.style & graphics.FSF_ITALIC != 0) else null;
    const under = if (style) makeCheck(s, ID_UNDERLINED, r.public.font.attr.style & graphics.FSF_UNDERLINED != 0) else null;
    const styles = if (style) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(bold) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Bold") },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(italic) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Italic") },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(under) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Underlined") },
        .{},
    }) else null;

    const front = if (r.flags1 & asl.FOF_DOFRONTPEN != 0) makePalette(s, ID_FRONT, s.front_pens, s.front_count, r.public.font.front_pen) else null;
    const back = if (r.flags1 & asl.FOF_DOBACKPEN != 0) makePalette(s, ID_BACK, s.back_pens, s.back_count, r.public.font.back_pen) else null;
    var which_mode: u32 = 0;
    for (modes, 0..) |mode, i| {
        if (mode == r.public.font.draw_mode & mode_mask) which_mode = @intCast(i);
    }
    const mode = if (r.flags1 & asl.FOF_DODRAWMODE != 0) ib.NewObjectTagList(null, cy.CYCLE_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_MODE },
        .{ .tag = cy.CYCLE_Labels, .data = @intFromPtr(&mode_labels) },
        .{ .tag = cy.CYCLE_Active, .data = which_mode },
        .{},
    }) else null;

    const ok = makeButton(s, r.words.positive orelse "_Ok", ID_OK);
    const cancel = makeButton(s, r.words.negative orelse "_Cancel", ID_CANCEL);
    const buttons = if (ok != null and cancel != null)
        ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(ok) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(cancel) },
            .{},
        })
    else
        null;

    const whole = lists != null and sample != null and buttons != null and
        (!style or styles != null) and
        (r.flags1 & asl.FOF_DOFRONTPEN == 0 or front != null) and
        (r.flags1 & asl.FOF_DOBACKPEN == 0 or back != null) and
        (r.flags1 & asl.FOF_DODRAWMODE == 0 or mode != null);
    const layout = if (whole) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 6 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(lists) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(sample) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = if (styles != null) lg.LAYOUTA_AddChild else ignore, .data = @intFromPtr(styles) },
        .{ .tag = if (styles != null) lg.CHILDA_WeightHeight else ignore, .data = 0 },
        .{ .tag = if (front != null) lg.LAYOUTA_AddChild else ignore, .data = @intFromPtr(front) },
        .{ .tag = if (front != null) lg.CHILDA_Label else ignore, .data = @intFromPtr("_Front") },
        .{ .tag = if (front != null) lg.CHILDA_WeightHeight else ignore, .data = 0 },
        .{ .tag = if (back != null) lg.LAYOUTA_AddChild else ignore, .data = @intFromPtr(back) },
        .{ .tag = if (back != null) lg.CHILDA_Label else ignore, .data = @intFromPtr("Bac_k") },
        .{ .tag = if (back != null) lg.CHILDA_WeightHeight else ignore, .data = 0 },
        .{ .tag = if (mode != null) lg.LAYOUTA_AddChild else ignore, .data = @intFromPtr(mode) },
        .{ .tag = if (mode != null) lg.CHILDA_Label else ignore, .data = @intFromPtr("_Mode") },
        .{ .tag = if (mode != null) lg.CHILDA_WeightHeight else ignore, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(buttons) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{},
    }) else null;
    const made = layout orelse {
        // A child a group took is that group's to dispose of; one that
        // never reached a group is disposed of here, and disposing both
        // would free it twice.
        if (lists) |group| ib.DisposeObject(group) else {
            for ([_]?*Object{ families, sizes }) |part| ib.DisposeObject(part);
        }
        if (styles) |group| ib.DisposeObject(group) else {
            for ([_]?*Object{ bold, italic, under }) |part| ib.DisposeObject(part);
        }
        if (buttons) |group| ib.DisposeObject(group) else {
            for ([_]?*Object{ ok, cancel }) |part| ib.DisposeObject(part);
        }
        for ([_]?*Object{ sample, front, back, mode }) |part| ib.DisposeObject(part);
        return false;
    };

    var nominal = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(made, @ptrCast(&nominal));
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr(r.words.title orelse "Pick a font") },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        // The height the layout asks for and no more: the slack a window
        // opens with is shared out among its children, and what would
        // grow here is the sample and the lists, which are the size they
        // want to be.
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(@max(if (r.box.width > 0) r.box.width else nominal.domain.width + 80, 1)) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(@max(if (r.box.height > 0) r.box.height else nominal.domain.height, 1)) },
        .{ .tag = if (r.box.left >= 0) wn.WA_Left else ignore, .data = @intCast(@max(r.box.left, 0)) },
        .{ .tag = if (r.box.top >= 0) wn.WA_Top else ignore, .data = @intCast(@max(r.box.top, 0)) },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(made) },
        .{},
    }) orelse {
        ib.DisposeObject(made);
        return false;
    };
    s.object = object;
    s.families_gadget = families.?;
    s.sizes_gadget = sizes.?;
    s.sample_gadget = sample.?;
    return true;
}

// --- the loop ---------------------------------------------------------------

fn entryAt(list: *exec.List, line: u32) ?*Entry {
    const node = lv.nodeAt(list, line) orelse return null;
    return @fieldParentPtr("node", node);
}

/// The sizes list built for the family picked, and the size kept if the
/// new family has it - a font asked for at 12 stays at 12 when another
/// family has a 12.
fn pickFamily(s: *Session, line: u32) void {
    const entry = entryAt(&s.families, line) orelse return;
    _request.copyInto(&s.r.family, entry.name());
    const detach = [_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = lv.LISTVIEW_DETACH }, .{} };
    _ = s.ib.SetGadgetAttrsTagList(s.sizes_gadget, s.window, &detach);
    fillSizes(s);
    var which: u32 = lv.LISTVIEW_NONE;
    var at: u32 = 0;
    var node = s.sizes.first();
    while (node) |it| : (node = it.next()) {
        const size: *Entry = @fieldParentPtr("node", it);
        if (size.size == s.r.size) which = at;
        at += 1;
    }
    if (which == lv.LISTVIEW_NONE and s.sizes.first() != null) {
        const first: *Entry = @fieldParentPtr("node", s.sizes.first().?);
        s.r.size = @truncate(first.size);
        which = 0;
    }
    const attach = [_]TagItem{
        .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&s.sizes) },
        .{ .tag = lv.LISTVIEW_Selected, .data = which },
        .{ .tag = if (which != lv.LISTVIEW_NONE) lv.LISTVIEW_MakeVisible else utility.TAG_IGNORE, .data = which },
        .{},
    };
    _ = s.ib.SetGadgetAttrsTagList(s.sizes_gadget, s.window, &attach);
    showSample(s);
}

fn pickSize(s: *Session, line: u32) void {
    const entry = entryAt(&s.sizes, line) orelse return;
    s.r.size = @truncate(entry.size);
    showSample(s);
}

fn setStyle(s: *Session, bit: graphics.FontStyle, on: bool) void {
    if (on) s.r.public.font.attr.style |= bit else s.r.public.font.attr.style &= ~bit;
    showSample(s);
}

/// One word from the window acted on. False when the requester is done.
fn act(s: *Session, word: usize, code: u32) bool {
    switch (word & wc.WMHI_CLASSMASK) {
        wc.WMHI_CLOSEWINDOW => return false,
        wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
            ID_FAMILIES => pickFamily(s, code & ~lv.LISTVIEW_DOUBLE),
            ID_SIZES => {
                pickSize(s, code & ~lv.LISTVIEW_DOUBLE);
                // A second press on a size is the answer.
                if (code & lv.LISTVIEW_DOUBLE != 0 and s.r.family[0] != 0) {
                    s.answered = true;
                    return false;
                }
            },
            ID_BOLD => setStyle(s, graphics.FSF_BOLD, code != 0),
            ID_ITALIC => setStyle(s, graphics.FSF_ITALIC, code != 0),
            ID_UNDERLINED => setStyle(s, graphics.FSF_UNDERLINED, code != 0),
            ID_FRONT => {
                if (code < s.front_count) s.r.public.font.front_pen = s.front_pens[code];
                showSample(s);
            },
            ID_BACK => {
                if (code < s.back_count) s.r.public.font.back_pen = s.back_pens[code];
                showSample(s);
            },
            ID_MODE => {
                if (code < modes.len) {
                    const kept = s.r.public.font.draw_mode & ~mode_mask;
                    s.r.public.font.draw_mode = @truncate(kept | modes[code]);
                }
                showSample(s);
            },
            ID_OK => {
                if (s.r.family[0] != 0) {
                    s.answered = true;
                    return false;
                }
            },
            ID_CANCEL => return false,
            else => {},
        },
        wc.WMHI_VANILLAKEY => switch (word & wc.WMHI_KEYMASK) {
            0x0D => {
                if (s.r.family[0] != 0) {
                    s.answered = true;
                    return false;
                }
            },
            0x1B => return false,
            else => {},
        },
        else => {},
    }
    return true;
}

// --- the whole thing --------------------------------------------------------

/// A font requester put up and answered.
pub fn ask(ab: *AslBase, r: *Requester) bool {
    const df = @import("../asl_base.zig").diskfontOf(ab) orelse return false;
    const block = ab.sys_base.AllocVec(@sizeOf(Session), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
    defer ab.sys_base.FreeVec(block);
    const s: *Session = @ptrCast(@alignCast(block));
    s.* = .{
        .r = r,
        .sys = ab.sys_base,
        .ib = ab.intuition_base,
        .gb = ab.graphics_base,
        .ub = ab.utility_base,
        .df = df,
    };
    s.families.init(.unknown);
    s.sizes.init(.unknown);
    s.sample.init(.unknown);
    s.sample_node = .{ .name = sample_text };
    s.sys.AddTail(&s.sample, &s.sample_node);
    defer {
        if (s.shown_font) |font| s.gb.CloseFont(font);
        entries.empty(s.sys, &s.families);
        entries.empty(s.sys, &s.sizes);
        if (s.found) |found| s.sys.FreeVec(@ptrCast(found));
    }
    if (!readFonts(s)) return false;

    const named: ?[*:0]const u8 = if (r.where.window != null or r.where.screen != null) null else r.where.pub_screen;
    const parent_screen: ?*intuition.Screen = if (r.where.window) |w| blk: {
        var at: usize = 0;
        const ask_screen = [_]TagItem{ .{ .tag = wn.WA_Screen, .data = @intFromPtr(&at) }, .{} };
        s.ib.GetWindowAttrs(w, &ask_screen);
        break :blk if (at != 0) @ptrFromInt(at) else null;
    } else null;
    const given: ?*intuition.Screen = parent_screen orelse r.where.screen;
    const screen: *intuition.Screen = given orelse
        (s.ib.LockPubScreen(named) orelse s.ib.LockPubScreen(null) orelse return false);
    defer if (given == null) s.ib.UnlockPubScreen(null, screen);

    // The colours the two palettes offer: the program's, or the spread
    // this library keeps for the purpose.
    s.front_pens = if (r.front_pens != null and r.front_pen_count != 0) r.front_pens.? else &default_pens;
    s.front_count = if (r.front_pens != null and r.front_pen_count != 0) r.front_pen_count else default_pens.len;
    s.back_pens = if (r.back_pens != null and r.back_pen_count != 0) r.back_pens.? else &default_pens;
    s.back_count = if (r.back_pens != null and r.back_pen_count != 0) r.back_pen_count else default_pens.len;
    // Text in black on white unless the program said otherwise, which is
    // a pair out of whichever table is offered rather than a colour that
    // cannot be picked again once it is left.
    if (r.public.font.front_pen == 0) r.public.font.front_pen = s.front_pens[@min(pen_black, s.front_count - 1)];
    if (r.public.font.back_pen == 0) r.public.font.back_pen = s.back_pens[@min(pen_white, s.back_count - 1)];

    if (!build(s, screen)) return false;
    defer s.ib.DisposeObject(s.object);

    var open = wc.WmOpen{};
    if (s.ib.SendMessage(s.object, @ptrCast(&open)) == 0) return false;
    var window_at: usize = 0;
    _ = s.ib.GetAttr(wc.WINDOWA_Window, s.object, &window_at);
    s.window = @ptrFromInt(window_at);

    const parent = if (r.where.sleep != 0) r.where.window else null;
    if (parent) |w| {
        const busy = [_]TagItem{ .{ .tag = wn.WA_BusyPointer, .data = 1 }, .{} };
        s.ib.SetWindowPointerA(w, &busy);
    }
    defer if (parent) |w| {
        const awake = [_]TagItem{ .{ .tag = wn.WA_BusyPointer, .data = 0 }, .{} };
        s.ib.SetWindowPointerA(w, &awake);
    };

    // The families, and the family the requester starts on if it has one.
    fillFamilies(s);
    var which: u32 = lv.LISTVIEW_NONE;
    var at: u32 = 0;
    var node = s.families.first();
    while (node) |it| : (node = it.next()) {
        const entry: *Entry = @fieldParentPtr("node", it);
        if (r.family[0] != 0 and sameName(s.ub, entry.name(), @ptrCast(&r.family))) which = at;
        at += 1;
    }
    const attach = [_]TagItem{
        .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&s.families) },
        .{ .tag = if (which != lv.LISTVIEW_NONE) lv.LISTVIEW_Selected else utility.TAG_IGNORE, .data = which },
        .{ .tag = if (which != lv.LISTVIEW_NONE) lv.LISTVIEW_MakeVisible else utility.TAG_IGNORE, .data = which },
        .{},
    };
    _ = s.ib.SetGadgetAttrsTagList(s.families_gadget, s.window, &attach);
    if (which != lv.LISTVIEW_NONE) pickFamily(s, which) else showSample(s);

    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    loop: while (true) {
        while (true) {
            const word = s.ib.SendMessage(s.object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            if (!act(s, word, code)) break :loop;
        }
        const got = s.ib.WaitIMsg(s.window, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
    }

    // Where it was left, and what it was answered with. The name is the
    // family with `.font` after it, which is what OpenDiskFont wants.
    var box: [4]usize = @splat(0);
    const ask_box = [_]TagItem{
        .{ .tag = wn.WA_Left, .data = @intFromPtr(&box[0]) },
        .{ .tag = wn.WA_Top, .data = @intFromPtr(&box[1]) },
        .{ .tag = wn.WA_Width, .data = @intFromPtr(&box[2]) },
        .{ .tag = wn.WA_Height, .data = @intFromPtr(&box[3]) },
        .{},
    };
    s.ib.GetWindowAttrs(s.window, &ask_box);
    r.box.left = @bitCast(@as(u32, @truncate(box[0])));
    r.box.top = @bitCast(@as(u32, @truncate(box[1])));
    r.box.width = @bitCast(@as(u32, @truncate(box[2])));
    r.box.height = @bitCast(@as(u32, @truncate(box[3])));
    r.public.font.left_edge = r.box.left;
    r.public.font.top_edge = r.box.top;
    r.public.font.width = r.box.width;
    r.public.font.height = r.box.height;
    if (s.answered) {
        var name: [dos.name_max + 1]u8 = @splat(0);
        const len = @min(textLen(@ptrCast(&r.family)), name.len - 6);
        @memcpy(name[0..len], r.family[0..len]);
        @memcpy(name[len..][0..5], ".font");
        name[len + 5] = 0;
        _request.copyInto(&r.family, @ptrCast(&name));
        r.public.font.attr.name = @ptrCast(&r.family);
        r.public.font.attr.y_size = @truncate(r.size);
    }
    const detach = [_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = lv.LISTVIEW_DETACH }, .{} };
    _ = s.ib.SetGadgetAttrsTagList(s.families_gadget, s.window, &detach);
    _ = s.ib.SetGadgetAttrsTagList(s.sizes_gadget, s.window, &detach);
    _ = s.ib.SetGadgetAttrsTagList(s.sample_gadget, s.window, &detach);
    return s.answered;
}
