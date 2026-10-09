// SPDX-License-Identifier: MIT
//! An icon on the desktop or in a drawer: its picture with its name under
//! it, where it lies, and what it stands for - a disk, or a file with its
//! size, date and protection, which a drawer viewed as text shows instead
//! of the picture.
//!
//! **Where it lies** is the picture's top-left in its ground, as the icon
//! file keeps it; a drawer scrolled shows its ground from an origin, which
//! every call that draws or hits is given. The name is centred under the
//! picture, cut to what fits in a cell, and on the desktop drawn with a
//! shadow in the other of black and white, so it reads on any ground. An
//! icon placed by the desktop sits in its cell with its picture's foot on
//! the cell's line, so the names of a row line up whatever their
//! pictures' heights.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const icon = sdk.icon;
const rtg = sdk.rtg;
const graphics = sdk.graphics;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IconBase = sdk.interface.icon.IconBase;
const Rect = graphics.Rect;
const Pen = graphics.Pen;
const TagItem = utility.TagItem;
pub const picture = @import("picture.zig");
pub const place = @import("place.zig");

/// The longest name kept for an icon.
pub const label_max = dos.name_max;

/// How everything on one ground is drawn: the font of the names, how
/// large a picture may be, the cell an icon is placed in, and the names'
/// pens.
pub const Look = struct {
    font: ?*graphics.TextFont = null,
    font_height: i32 = 8,
    baseline: i32 = 6,
    icon_size: u32 = 48,
    cell: place.Cell = .{ .width = 80, .height = 64 },
    text: Pen = 0xFFFF_FFFF,
    /// The name's shadow; null for none.
    shadow: ?Pen = 0xFF00_0000,
    /// A selected icon's plate and name: the screen's fill pens.
    fill: Pen = 0xFF66_88BB,
    fill_text: Pen = 0xFF00_0000,

    /// The most a name may be wide: its cell, less a little room each side.
    pub fn labelRoom(look: *const Look) i32 {
        return look.cell.width - 4;
    }
};

/// The room between a picture and its name.
const label_gap = 2;

/// A ground's origin: where its (0, 0) is drawn, so a scrolled drawer's
/// icons are drawn and hit where they show.
pub const Origin = struct { x: i32 = 0, y: i32 = 0 };

/// What a file is, as its drawer was read.
pub const Entry = struct {
    /// `ST_`: a drawer (above 0) or a file.
    kind: i32 = dos.ST_FILE,
    size: u64 = 0,
    date: dos.DateStamp = .{},
    protection: u32 = 0,

    pub fn isDrawer(entry: *const Entry) bool {
        return entry.kind > 0;
    }
};

pub const Icon = struct {
    node: exec.Node = .{},
    /// Its icon, and its picture as shown; neither in a drawer viewed as
    /// text.
    object: ?*icon.DiskObject = null,
    picture: ?picture.Shown = null,
    entry: Entry = .{},
    /// The name, and how many of its bytes are shown and how wide they are.
    label: [label_max + 1]u8 = @splat(0),
    label_len: u16 = 0,
    shown_len: u16 = 0,
    label_width: i32 = 0,
    /// The picture's top-left in its window.
    x: i32 = 0,
    y: i32 = 0,
    /// Whether it lies where its file says, rather than where it was put;
    /// and whether it was moved since, a place Snapshot would keep.
    placed_by_file: bool = false,
    moved: bool = false,
    selected: bool = false,
    /// What it stands for, to know it again: a volume's node.
    key: ?*anyopaque = null,
    /// A file left out on the desktop: its full name, the icon's own
    /// allocation; null for anything else.
    path: ?[*:0]u8 = null,
    /// A program's icon (AddAppIcon): the library's record of it, whose
    /// `object` this icon shows and does not own; null for anything else.
    app: ?*anyopaque = null,

    pub fn width(ic: *const Icon) i32 {
        const shown = ic.picture orelse return 0;
        return @intCast(shown.size.width);
    }

    pub fn height(ic: *const Icon) i32 {
        const shown = ic.picture orelse return 0;
        return @intCast(shown.size.height);
    }

    pub fn name(ic: *const Icon) []const u8 {
        return ic.label[0..ic.label_len];
    }

    /// Where its name is drawn: the left of the text and the top of its
    /// line.
    fn labelAt(ic: *const Icon) struct { x: i32, y: i32 } {
        return .{ .x = ic.x + @divTrunc(ic.width() - ic.label_width, 2), .y = ic.y + ic.height() + label_gap };
    }

    /// The whole of it on its ground: the picture and the name under it.
    pub fn box(ic: *const Icon, look: *const Look) Rect {
        const at = ic.labelAt();
        return .{
            .min_x = @min(ic.x, at.x),
            .min_y = ic.y,
            .max_x = @max(ic.x + ic.width(), at.x + ic.label_width),
            .max_y = at.y + look.font_height,
        };
    }

    /// Its box where it shows, from `origin`.
    pub fn shownBox(ic: *const Icon, look: *const Look, origin: Origin) Rect {
        const b = ic.box(look);
        return .{ .min_x = b.min_x - origin.x, .min_y = b.min_y - origin.y, .max_x = b.max_x - origin.x, .max_y = b.max_y - origin.y };
    }

    /// Put in the cell whose top-left is `cell_x`, `cell_y`: the picture
    /// centred across it, its foot on the line every picture of the row
    /// stands on.
    pub fn putInCell(ic: *Icon, look: *const Look, cell_x: i32, cell_y: i32) void {
        ic.x = cell_x + @divTrunc(look.cell.width - ic.width(), 2);
        ic.y = cell_y + @as(i32, @intCast(look.icon_size)) - ic.height();
    }

    /// The name measured in the look's font through `rp`, and cut to what
    /// fits in a cell.
    pub fn measure(ic: *Icon, gb: *GraphicsBase, rp: *graphics.RastPort, look: *const Look) void {
        if (look.font) |font| gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) }, .{} });
        var extent: graphics.TextExtent = undefined;
        const fits = gb.TextFit(rp, &ic.label, ic.label_len, &extent, null, 1, look.labelRoom(), look.font_height + 8);
        ic.shown_len = @intCast(fits);
        ic.label_width = gb.TextLength(rp, &ic.label, fits);
    }

    /// Drawn through `rp` from `origin`: the picture over what is there,
    /// the name with its shadow. Selected, a plate of the fill pen half
    /// shows through behind the picture, and the name is on the fill pen.
    pub fn draw(ic: *const Icon, gb: *GraphicsBase, rp: *graphics.RastPort, look: *const Look, origin: Origin) void {
        const x = ic.x - origin.x;
        const y = ic.y - origin.y;
        if (ic.selected and ic.picture != null) {
            const plate = Rect{ .min_x = x - 3, .min_y = y - 3, .max_x = x + ic.width() + 3, .max_y = y + ic.height() + 3 };
            gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = (look.fill & 0x00FF_FFFF) | 0x8000_0000 }, .{} });
            gb.FillRoundRect(rp, &plate, 6);
        }
        if (ic.picture) |shown| {
            const area = Rect{ .min_x = x, .min_y = y, .max_x = x + ic.width(), .max_y = y + ic.height() };
            gb.BlendPixelArray(rp, shown.pixels, shown.size.width * 4, @intFromEnum(rtg.PixelFormat.rgba32), 0, 0, &area);
        }
        if (ic.shown_len == 0) return;
        const at = ic.labelAt();
        var tags = [_]TagItem{
            .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
            .{ .tag = graphics.RPTAG_APen, .data = look.text },
            .{ .tag = if (look.font != null) graphics.RPTAG_Font else utility.TAG_IGNORE, .data = @intFromPtr(look.font) },
            .{},
        };
        if (ic.selected) {
            const under = Rect{ .min_x = at.x - origin.x - 2, .min_y = at.y - origin.y, .max_x = at.x - origin.x + ic.label_width + 2, .max_y = at.y - origin.y + look.font_height };
            gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = look.fill }, .{} });
            gb.RectFill(rp, &under);
            tags[1].data = look.fill_text;
        } else if (look.shadow) |shadow| {
            tags[1].data = shadow;
            gb.SetRPAttrs(rp, &tags);
            gb.Move(rp, at.x - origin.x + 1, at.y - origin.y + look.baseline + 1);
            gb.Text(rp, &ic.label, ic.shown_len);
            tags[1].data = look.text;
        }
        gb.SetRPAttrs(rp, &tags);
        gb.Move(rp, at.x - origin.x, at.y - origin.y + look.baseline);
        gb.Text(rp, &ic.label, ic.shown_len);
    }

    /// Whether the point (`x`, `y`) where its ground shows, from `origin`,
    /// is on it.
    pub fn hit(ic: *const Icon, look: *const Look, origin: Origin, x: i32, y: i32) bool {
        const b = ic.shownBox(look, origin);
        return x >= b.min_x and x < b.max_x and y >= b.min_y and y < b.max_y;
    }
};

/// An icon made for `object`, named `label`, its picture at the look's
/// size - or with no object, an entry of a drawer viewed as text; null
/// without memory. The icon owns the object from here on.
pub fn make(sys: *ExecBase, pictures: *picture.Pictures, object: ?*icon.DiskObject, label: []const u8, look: *const Look) ?*Icon {
    const memory = sys.AllocVec(@sizeOf(Icon), exec.MEMF_CLEAR) orelse return null;
    var shown: ?picture.Shown = null;
    if (object) |given| if (given.image) |image| {
        shown = pictures.obtain(sys, image, look.icon_size) orelse {
            sys.FreeVec(memory);
            return null;
        };
    };
    const ic: *Icon = @ptrCast(@alignCast(memory));
    ic.* = .{ .object = object, .picture = shown };
    const length = @min(label.len, label_max);
    @memcpy(ic.label[0..length], label[0..length]);
    ic.label_len = @intCast(length);
    ic.shown_len = ic.label_len;
    return ic;
}

/// An icon freed: its picture given back, its object to icon.library -
/// but a program's icon's, which is its record's.
pub fn free(sys: *ExecBase, ib: *IconBase, pictures: *picture.Pictures, ic: *Icon) void {
    if (ic.picture) |shown| pictures.release(sys, shown);
    if (ic.app == null) if (ic.object) |object| ib.FreeDiskObject(object);
    if (ic.path) |held| sys.FreeVec(held);
    sys.FreeVec(ic);
}
