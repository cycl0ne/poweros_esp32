// SPDX-License-Identifier: MIT
//! The outlines diskfont.library has opened (since 1.4): a face's
//! font file read whole and opened by truetype.library, shared by
//! everyone who asks for it.
//!
//! **A record is one allocation**, the `OutlineFont` the caller is given
//! first, then its link on the library's list, how many hold it, the
//! file, and what it was found by, which is how it is found again: the
//! contents file and the entry of it - a file and a place on the file's
//! axes. One nobody holds stays, for the next to ask, until memory runs
//! short: the low-memory handler frees it after the fonts nobody holds.
//!
//! **A variable font is a record a place** (since 1.13). The entries of
//! one file at several places - regular, bold - are opened each as an
//! outline of its own, and all of them read the one copy of the file:
//! the bytes are freed with the last record that has them.
//!
//! **A size rendered from an outline holds it** (since 1.9), for as long
//! as the size is in memory: the glyphs its image lacks are made from
//! the outline as they are drawn (`font/_font.zig`).

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const diskfont = sdk.diskfont;
const fontfile = sdk.diskfont.fontfile;
const truetype = sdk.truetype;
const utility = sdk.utility;
const _base = @import("../diskfont_base.zig");
const DiskfontBase = _base.DiskfontBase;
const _font = @import("../font/_font.zig");
const opendiskfont = @import("../font/opendiskfont.zig");

pub const OutlineRecord = extern struct {
    font: diskfont.OutlineFont,
    link: exec.Node = .{},
    /// How many have it open.
    holders: u32 = 0,
    /// The font file; the outline reads it in place. The records of
    /// one file at several places have the same.
    file: ?*anyopaque = null,
    file_size: u32 = 0,
    /// The styles this record was the answer for, when its family was
    /// asked by name: bit n for the bold and italic bits n. It saves
    /// reading the contents file to find the entry again.
    asked: u32 = 0,
    /// The entry it was opened from: the file and the place.
    entry: fontfile.FontContents = .{},
    /// The family's contents file it came from: "FONTS:sans-bold.font".
    key: [256:0]u8 = @splat(0),
};

/// The family `name`'s outline, the one of its faces drawn in the most
/// of `style`'s bold and italic first, opened for the caller. The caller
/// holds the load lock.
pub fn open(dfb: *DiskfontBase, name: [*:0]const u8, style: graphics.FontStyle) ?*diskfont.OutlineFont {
    if (style & opendiskfont.face_styles != 0) {
        for (opendiskfont.faces) |face| {
            if (style & face.style != face.style) continue;
            var face_name: [256:0]u8 = @splat(0);
            if (!opendiskfont.faceName(name, face.suffix, &face_name)) continue;
            if (openFamily(dfb, &face_name, style)) |font| return font;
        }
    }
    return openFamily(dfb, name, style);
}

/// One family's outline nearest `style`: held already, or its file read
/// and opened.
fn openFamily(dfb: *DiskfontBase, name: [*:0]const u8, style: graphics.FontStyle) ?*diskfont.OutlineFont {
    var path: [256:0]u8 = @splat(0);
    opendiskfont.contentsPath(dfb, name, &path);
    const asked = @as(u32, 1) << @intCast(style & opendiskfont.face_styles);
    if (findAsked(dfb, &path, asked)) |record| {
        record.holders += 1;
        return &record.font;
    }
    var contents = _font.readContents(dfb, &path);
    defer contents.free(dfb);
    const entry = opendiskfont.outlineOf(&contents, style) orelse return null;
    const font = openEntry(dfb, &path, &contents, entry) orelse return null;
    const record: *OutlineRecord = @fieldParentPtr("font", font);
    record.asked |= asked;
    return font;
}

/// The outline of one entry of the family whose contents file, at
/// `path`, is `contents`: held already, or its file read - or taken from
/// a record of the same file at another place - and opened at the
/// entry's place. The caller holds the load lock, and gives the outline
/// back with `close`.
///
/// INPUTS:
/// - `dfb` - the library.
/// - `path` - the contents file, as `contentsPath` makes it.
/// - `contents` - what it holds.
/// - `entry` - one of its outline entries.
///
/// RESULT:
/// The outline, held once more; null if its file cannot be read or
/// opened.
pub fn openEntry(dfb: *DiskfontBase, path: *const [256:0]u8, contents: *const _font.Contents, entry: *const fontfile.FontContents) ?*diskfont.OutlineFont {
    const sys = dfb.sys_base;
    var shared: ?*OutlineRecord = null;
    var at = dfb.outlines.first();
    while (at) |node| : (at = node.next()) {
        const record: *OutlineRecord = @fieldParentPtr("link", node);
        if (!samePath(&record.key, path) or !sameFile(&record.entry, entry)) continue;
        if (samePlace(&record.entry, entry)) {
            record.holders += 1;
            return &record.font;
        }
        shared = record;
    }
    const tb = _font.trueType(dfb) orelse return null;
    // The system's, not the task's that opened it first: it is shared.
    const flags = exec.MEMF_ANY | exec.MEMF_SYSTEM;
    var data: []u8 = undefined;
    if (shared) |record| {
        const bytes: [*]u8 = @ptrCast(record.file.?);
        data = bytes[0..record.file_size];
    } else {
        data = _font.readWhole(dfb, contents.dir, @ptrCast(&entry.path), flags) orelse return null;
    }
    // The values are read at the opening and not kept.
    const tags = [_]utility.TagItem{
        .{ .tag = truetype.TTA_Axes, .data = @intFromPtr(&entry.axes) },
        .{ .tag = truetype.TTA_AxisCount, .data = entry.axis_count },
        .{ .tag = utility.TAG_DONE, .data = 0 },
    };
    const outline = tb.OpenOutline(data.ptr, @intCast(data.len), &tags) orelse {
        if (shared == null) sys.FreeVec(data.ptr);
        return null;
    };
    const memory = sys.AllocVec(@sizeOf(OutlineRecord), flags) orelse {
        tb.CloseOutline(outline);
        if (shared == null) sys.FreeVec(data.ptr);
        return null;
    };
    const record: *OutlineRecord = @ptrCast(@alignCast(memory));
    record.* = .{
        .font = .{ .outline = outline, .style = entry.style & opendiskfont.face_styles },
        .holders = 1,
        .file = data.ptr,
        .file_size = @intCast(data.len),
        .entry = entry.*,
        .key = path.*,
    };
    sys.AddTail(&dfb.outlines, &record.link);
    return &record.font;
}

/// The record that was the answer when the family whose contents file
/// is at `path` was asked for the styles of the bit `asked`, if there is
/// one.
fn findAsked(dfb: *DiskfontBase, path: *const [256:0]u8, asked: u32) ?*OutlineRecord {
    var at = dfb.outlines.first();
    while (at) |node| : (at = node.next()) {
        const record: *OutlineRecord = @fieldParentPtr("link", node);
        if (record.asked & asked != 0 and samePath(&record.key, path)) return record;
    }
    return null;
}

/// Whether two entries of one contents file name the same file.
fn sameFile(a: *const fontfile.FontContents, b: *const fontfile.FontContents) bool {
    for (a.path, b.path) |x, y| {
        if (lower(x) != lower(y)) return false;
        if (x == 0) return true;
    }
    return true;
}

/// Whether two entries are at the same place on their file's axes: the
/// same axes named, in the same order, with the same values.
fn samePlace(a: *const fontfile.FontContents, b: *const fontfile.FontContents) bool {
    if (a.axis_count != b.axis_count) return false;
    for (a.axes[0..a.axis_count], b.axes[0..b.axis_count]) |x, y| {
        if (x.tag != y.tag) return false;
        if (@as(u32, @bitCast(x.value)) != @as(u32, @bitCast(y.value))) return false;
    }
    return true;
}

/// The same path, letters of either case alike, as the disk has them.
fn samePath(a: *const [256:0]u8, b: *const [256:0]u8) bool {
    for (a, b) |x, y| {
        if (lower(x) != lower(y)) return false;
        if (x == 0) return true;
    }
    return true;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Whether a record on the list reads the file at `file`.
fn fileHeld(dfb: *DiskfontBase, file: ?*anyopaque) bool {
    var at = dfb.outlines.first();
    while (at) |node| : (at = node.next()) {
        const record: *OutlineRecord = @fieldParentPtr("link", node);
        if (record.file == file) return true;
    }
    return false;
}

/// One holder fewer. The caller holds the load lock.
pub fn close(font: *diskfont.OutlineFont) void {
    const record: *OutlineRecord = @fieldParentPtr("font", font);
    if (record.holders > 0) record.holders -= 1;
}

/// One outline nobody holds, closed and freed. The caller holds the load
/// lock.
///
/// RESULT:
/// Whether there was one.
pub fn freeOne(dfb: *DiskfontBase) bool {
    const sys = dfb.sys_base;
    var at = dfb.outlines.first();
    while (at) |node| : (at = node.next()) {
        const record: *OutlineRecord = @fieldParentPtr("link", node);
        if (record.holders != 0) continue;
        sys.Remove(&record.link);
        // Opened only once truetype.library was.
        dfb.truetype_base.?.CloseOutline(record.font.outline);
        // The file's bytes go with the last record that reads them.
        if (!fileHeld(dfb, record.file)) sys.FreeVec(record.file);
        sys.FreeVec(record);
        return true;
    }
    return false;
}
