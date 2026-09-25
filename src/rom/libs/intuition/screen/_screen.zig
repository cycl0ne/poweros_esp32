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
//! **Buffers.** A screen draws in a buffer of its display's memory, the
//! display's size. The first screen of a display takes the buffer the
//! display was brought up showing - its *home* - and every further one is
//! given a buffer of its own. The base's list of screens is in depth order,
//! front first, and a display shows the buffer of its frontmost screen:
//! bringing a screen forward is showing its buffer, which the driver does
//! at a frame's start, so nothing is copied and nothing tears. When a
//! display's last screen closes, its home is shown again, black.
//!
//! The list of screens and every public screen's lock count are guarded by
//! one semaphore in the base, which nests, so LockPubScreen can open the
//! default screen while it holds it.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const graphics = sdk.graphics;
const layers = sdk.layers;
const intuition = sdk.intuition;
const sc = intuition.screens;
const ic = intuition.imageclass;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// What a screen is, behind the opaque `sdk.intuition.Screen`.
pub const Screen = extern struct {
    /// On the base's list of screens.
    node: exec.MinNode = .{},
    /// Over the whole screen, under no layer.
    rp: *graphics.RastPort,
    /// The buffer it draws in, as a surface.
    surface: usize,
    /// Its display, the buffer it draws in, and the display's home buffer.
    /// `own_bitmap` when the buffer was allocated for it, rather than being
    /// the home it took over.
    board: *rtg.RtgBoard,
    bitmap: *rtg.RtgBitMap,
    home: *rtg.RtgBitMap,
    own_bitmap: bool = false,
    /// What it shows while it is in front: `bitmap`, or a buffer of its
    /// own that `ChangeScreenBuffer` made the one shown.
    shown: *rtg.RtgBitMap,
    /// Whether its bar is in front of its backdrop windows (`ShowTitle`).
    show_title: bool = true,
    /// The depth gadget at the bar's right end, how wide it is, and whether
    /// it is drawn pressed. None without a bar.
    depth_image: ?*intuition.Object = null,
    depth_width: i32 = 0,
    depth_pressed: bool = false,
    /// `SA_Type`: `CUSTOMSCREEN` or `PUBLICSCREEN`.
    screen_type: u32 = sc.CUSTOMSCREEN,
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
    /// Nonzero for a public screen: its name is in `pub_name`, and
    /// `pub_node` is on the base's list of public screens.
    public: bool = false,
    pub_name: [sc.MAXPUBSCREENNAME + 1]u8 = @splat(0),
    /// Its entry on that list: whether it is private, and how many locks
    /// and visitor windows are outstanding - it cannot close until none.
    pub_node: sc.PubScreenNode,
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

/// The public screen of that name, private or not, with the list held.
/// Names are told apart without regard to case.
pub fn findPublic(ib: *IntuitionBase, name: [*:0]const u8) ?*Screen {
    var node = ib.pub_screens.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const psn: *sc.PubScreenNode = @ptrCast(@alignCast(n));
        if (ib.utility_base.Stricmp(psn.node.name.?, name) == 0) return @ptrCast(@alignCast(psn.screen));
    }
    return null;
}

/// The same, only when it is open to visitors.
pub fn findVisitable(ib: *IntuitionBase, name: [*:0]const u8) ?*Screen {
    const s = findPublic(ib, name) orelse return null;
    return if (s.pub_node.flags & sc.PSNF_PRIVATE != 0) null else s;
}

/// One visitor more, with the list held.
pub fn visit(s: *Screen) void {
    s.pub_node.visitor_count += 1;
}

/// One visitor fewer, with the list held. The last to go tells the owner,
/// if it asked to be told, so it can try to close the screen again.
pub fn leave(ib: *IntuitionBase, s: *Screen) void {
    const psn = &s.pub_node;
    if (psn.visitor_count == 0) return;
    psn.visitor_count -= 1;
    if (psn.visitor_count != 0) return;
    const task = psn.sig_task orelse return;
    ib.sys_base.Signal(task, @as(u32, 1) << @as(u5, @truncate(psn.sig_bit)));
}

/// The frontmost screen of a display, or null when it has none.
pub fn frontOn(ib: *IntuitionBase, board: *rtg.RtgBoard) ?*Screen {
    var node = ib.screen_list.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const s: *Screen = @ptrCast(@alignCast(n));
        if (s.board == board) return s;
    }
    return null;
}

/// The display's home buffer: the one it was showing when intuition first
/// put a screen on it, which every screen of the display remembers.
pub fn homeOf(ib: *IntuitionBase, board: *rtg.RtgBoard, showing: *rtg.RtgBitMap) *rtg.RtgBitMap {
    var node = ib.screen_list.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const s: *Screen = @ptrCast(@alignCast(n));
        if (s.board == board) return s.home;
    }
    return showing;
}

/// Whether a screen draws in this buffer.
pub fn inUse(ib: *IntuitionBase, bitmap: *rtg.RtgBitMap) bool {
    var node = ib.screen_list.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const s: *Screen = @ptrCast(@alignCast(n));
        if (s.bitmap == bitmap) return true;
    }
    return false;
}

/// The display shows its frontmost screen, or its home when it has none.
/// Showing a buffer waits for the frame it starts on, so this is called
/// with the list held but never under Forbid.
pub fn showFront(ib: *IntuitionBase, board: *rtg.RtgBoard, home: *rtg.RtgBitMap) void {
    const rb = ib.rtg_base orelse return;
    const wanted = if (frontOn(ib, board)) |s| s.shown else home;
    if (board.showing == wanted) return;
    _ = rb.ShowBitMap(board, wanted, 0, 0);
}

/// A screen to the front of the list, or to the back, and its display
/// showing whichever is now its front.
pub fn restack(ib: *IntuitionBase, s: *Screen, to_front: bool) void {
    const sys = ib.sys_base;
    sys.Remove(@ptrCast(&s.node));
    if (to_front) sys.AddHead(@ptrCast(&ib.screen_list), @ptrCast(&s.node)) else sys.AddTail(@ptrCast(&ib.screen_list), @ptrCast(&s.node));
    showFront(ib, s.board, s.home);
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

    defer drawDepthOn(ib, s, rp);
    const title = s.title orelse return;
    graphics.SetFont(gb, rp, s.font);
    var baseline: u32 = 0;
    const metric = [_]TagItem{ .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) }, .{} };
    gb.GetRPAttrs(rp, &metric);
    setPen(ib, rp, s.pens[sc.BARDETAILPEN]);
    gb.Move(rp, bar_left, bar_border + @as(i32, @intCast(baseline)));
    gb.Text(rp, title, @intCast(nameLen(title)));
}

/// The bar's depth gadget, pressed or not. Drawn after the title, so a
/// title that runs that far is covered by it.
fn drawDepthOn(ib: *IntuitionBase, s: *Screen, rp: *graphics.RastPort) void {
    const image = s.depth_image orelse return;
    const state: u32 = if (s.depth_pressed) ic.IDS_SELECTED else ic.IDS_NORMAL;
    ib.iface().DrawImageState(rp, image, s.width - s.depth_width, 0, state, &s.draw_info);
}

/// The depth gadget drawn again, pressed or let go.
pub fn drawDepth(ib: *IntuitionBase, s: *Screen, pressed: bool) void {
    const bar = s.bar orelse return;
    s.depth_pressed = pressed;
    var where: usize = 0;
    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetRastPort, .data = @intFromPtr(&where) }, .{} };
    ib.layers_base.GetLayerAttrs(bar, &ask);
    if (where == 0) return;
    ib.layers_base.LockLayer(bar);
    defer ib.layers_base.UnlockLayer(bar);
    drawDepthOn(ib, s, @ptrFromInt(where));
}

/// Whether (x, y) is on the bar's depth gadget where it shows - no window
/// in front of it there.
pub fn onDepthGadget(ib: *IntuitionBase, s: *Screen, x: i32, y: i32) bool {
    const bar = s.bar orelse return false;
    if (s.depth_image == null) return false;
    if (x < s.width - s.depth_width or x >= s.width or y < 0 or y >= s.bar_height - 1) return false;
    return ib.layers_base.WhichLayer(s.layer_info, x, y) == bar;
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
