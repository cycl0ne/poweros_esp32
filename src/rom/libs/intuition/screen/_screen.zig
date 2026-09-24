// SPDX-License-Identifier: MPL-2.0
//! Screens: what the screen calls share - the structure behind the SDK's
//! opaque `Screen`, its title bar and its ground.
//!
//! A screen is a RastPort on a display, a LayerInfo over that RastPort for
//! the windows, and a title bar. The bar is a layer of its own - a smart
//! one at the back - so a window laid over it later clips it like any
//! other layer, and gets its pixels back when it moves away without the
//! bar having to be drawn again.
//!
//! Behind the bar is the **ground**: a simple-refresh layer the size of
//! the screen. It is what makes a part of the screen that a window leaves
//! show the background again: that part becomes the ground's damage, and a
//! layer's damage is backfilled - here in the background pen. The ground
//! keeps nothing and draws nothing else, so its damage is dropped after
//! every repair.
//!
//! One screen to a display: the display's buffer is the screen's, and the
//! surface a RastPort on it draws into is what tells two displays apart.
//! The list of screens and every public screen's lock count are guarded by
//! one semaphore in the base, which nests, so LockPubScreen can open the
//! default screen while it holds it.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const layers = sdk.layers;
const intuition = sdk.intuition;
const sc = intuition.screens;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// What a screen is, behind the opaque `sdk.intuition.Screen`.
pub const Screen = extern struct {
    /// On the base's list of screens.
    node: exec.MinNode = .{},
    /// Over the whole display, under no layer.
    rp: *graphics.RastPort,
    /// The display's surface: what makes this screen this display's.
    surface: usize,
    /// Its windows' layers, and the bar's.
    layer_info: *layers.LayerInfo,
    /// The title bar, or null without one.
    bar: ?*layers.Layer = null,
    /// The whole screen at the very back: what a window leaves is its
    /// damage, backfilled in the background pen by `ground_fill`.
    ground: ?*layers.Layer = null,
    ground_fill: utility.Hook = .{},
    base: *IntuitionBase,
    font: *graphics.TextFont,
    /// Whether the font is the screen's own to close.
    own_font: bool = false,
    /// What the bar says now: the active window's screen title while one
    /// of this screen's windows is active, and `default_title` otherwise.
    title: ?[*:0]const u8 = null,
    /// What the bar says with none of its windows active: `SA_Title`.
    default_title: ?[*:0]const u8 = null,
    width: i32,
    height: i32,
    depth: u32,
    /// The bar and its trim line; 0 without a bar.
    bar_height: i32 = 0,
    pens: [sc.NUMDRIPENS]Pen,
    draw_info: sc.DrawInfo,
    /// Nonzero for a public screen: its name is in `pub_name`.
    public: bool = false,
    pub_name: [sc.MAXPUBSCREENNAME + 1]u8 = @splat(0),
    /// How many LockPubScreens are outstanding. It cannot close until 0.
    visitors: u32 = 0,
    /// Its windows, oldest first. It cannot close while it has any.
    windows: exec.MinList = .{},
};

/// The default pens: a grey ground, black text and edges, white shine and
/// a blue fill - the look the default screen has always had.
pub const default_pens = blk: {
    var pens: [sc.NUMDRIPENS]Pen = undefined;
    const grey = graphics.penRGB(0xAA, 0xAA, 0xAA);
    const black = graphics.penRGB(0x00, 0x00, 0x00);
    const white = graphics.penRGB(0xFF, 0xFF, 0xFF);
    const blue = graphics.penRGB(0x66, 0x88, 0xBB);
    pens[sc.DETAILPEN] = grey;
    pens[sc.BLOCKPEN] = black;
    pens[sc.TEXTPEN] = black;
    pens[sc.SHINEPEN] = white;
    pens[sc.SHADOWPEN] = black;
    pens[sc.FILLPEN] = blue;
    pens[sc.FILLTEXTPEN] = black;
    pens[sc.BACKGROUNDPEN] = grey;
    pens[sc.HIGHLIGHTTEXTPEN] = white;
    pens[sc.BARDETAILPEN] = black;
    pens[sc.BARBLOCKPEN] = white;
    pens[sc.BARTRIMPEN] = black;
    break :blk pens;
};

/// Left of the title text, and above and below it inside the bar.
pub const bar_left = 5;
pub const bar_border = 1;

pub fn nameLen(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (s[n] != 0) n += 1;
    return n;
}

fn sameName(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (a[i] == b[i]) : (i += 1) {
        if (a[i] == 0) return true;
    }
    return false;
}

/// The height of the ROM's font intuition starts with, for a screen given
/// none and for `IntuiTextLength` without a font: 16, the size that reads
/// at full height on a panel whose pixels are square.
pub const default_font_height = 16;

pub fn lock(ib: *IntuitionBase) void {
    ib.sys_base.ObtainSemaphore(&ib.screen_lock);
}

pub fn unlock(ib: *IntuitionBase) void {
    ib.sys_base.ReleaseSemaphore(&ib.screen_lock);
}

/// The public screen of that name, with the list held.
pub fn findPublic(ib: *IntuitionBase, name: [*:0]const u8) ?*Screen {
    var node = ib.screen_list.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const s: *Screen = @ptrCast(@alignCast(n));
        if (s.public and sameName(@ptrCast(&s.pub_name), name)) return s;
    }
    return null;
}

/// Whether some screen already has the display this surface belongs to.
pub fn displayTaken(ib: *IntuitionBase, surface: usize) bool {
    var node = ib.screen_list.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const s: *Screen = @ptrCast(@alignCast(n));
        if (s.surface == surface) return true;
    }
    return false;
}

pub fn setPen(ib: *IntuitionBase, rp: *graphics.RastPort, pen: Pen) void {
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = pen },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{},
    };
    ib.graphics_base.SetRPAttrs(rp, &tags);
}

/// The title bar: its fill, the title, and the trim line under it.
pub fn drawBar(ib: *IntuitionBase, s: *Screen) void {
    const bar = s.bar orelse return;
    const gb = ib.graphics_base;
    var where: usize = 0;
    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetRastPort, .data = @intFromPtr(&where) }, .{} };
    ib.layers_base.GetLayerAttrs(bar, &ask);
    if (where == 0) return;
    const rp: *graphics.RastPort = @ptrFromInt(where);
    // Held while it draws: a title changes while windows move about.
    ib.layers_base.LockLayer(bar);
    defer ib.layers_base.UnlockLayer(bar);

    setPen(ib, rp, s.pens[sc.BARBLOCKPEN]);
    gb.RectFill(rp, &.{ .max_x = s.width, .max_y = s.bar_height - 1 });
    setPen(ib, rp, s.pens[sc.BARTRIMPEN]);
    gb.DrawHLine(rp, 0, s.bar_height - 1, s.width);

    const title = s.title orelse return;
    graphics.SetFont(gb, rp, s.font);
    var baseline: u32 = 0;
    const metric = [_]TagItem{ .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) }, .{} };
    gb.GetRPAttrs(rp, &metric);
    setPen(ib, rp, s.pens[sc.BARDETAILPEN]);
    gb.Move(rp, bar_left, bar_border + @as(i32, @intCast(baseline)));
    gb.Text(rp, title, @intCast(nameLen(title)));
}

/// The ground's backfill: the area in the background pen, through the
/// ground's RastPort, handed back as it was.
pub fn fillGround(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const s: *Screen = @ptrCast(@alignCast(hook.data.?));
    const rp: *graphics.RastPort = @ptrCast(object orelse return 0);
    const msg: *layers.BackFillMsg = @ptrCast(@alignCast(message orelse return 0));
    const gb = s.base.graphics_base;
    var apen: u32 = 0;
    var mode: u32 = 0;
    const ask = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = @intFromPtr(&apen) },
        .{ .tag = graphics.RPTAG_DrMd, .data = @intFromPtr(&mode) },
        .{},
    };
    gb.GetRPAttrs(rp, &ask);
    setPen(s.base, rp, s.pens[sc.BACKGROUNDPEN]);
    gb.RectFill(rp, &msg.area);
    const put = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = apen },
        .{ .tag = graphics.RPTAG_DrMd, .data = mode },
        .{},
    };
    gb.SetRPAttrs(rp, &put);
    return 0;
}

/// Drop the ground's damage: it has already been backfilled, and there is
/// nothing else to draw there.
pub fn settleGround(ib: *IntuitionBase, s: *Screen) void {
    const ground = s.ground orelse return;
    if (ib.layers_base.BeginUpdate(ground)) ib.layers_base.EndUpdate(ground, true);
}
