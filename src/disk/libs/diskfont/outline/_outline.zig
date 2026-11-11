// SPDX-License-Identifier: MIT
//! The outlines diskfont.library has opened (since 1.4): a face's
//! TrueType file read whole and opened by truetype.library, shared by
//! everyone who asks for it.
//!
//! **A record is one allocation**, the `OutlineFont` the caller is given
//! first, then its link on the library's list, how many hold it, the
//! file, and the contents file it was found by, which is how it is found
//! again. One nobody holds stays, for the next to ask, until memory runs
//! short: the low-memory handler frees it after the fonts nobody holds.
//!
//! **A size rendered from an outline holds it** (since 1.9), for as long
//! as the size is in memory: the glyphs its image lacks are made from
//! the outline as they are drawn (`font/_font.zig`).

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const diskfont = sdk.diskfont;
const _base = @import("../diskfont_base.zig");
const DiskfontBase = _base.DiskfontBase;
const _font = @import("../font/_font.zig");
const opendiskfont = @import("../font/opendiskfont.zig");

pub const OutlineRecord = extern struct {
    font: diskfont.OutlineFont,
    link: exec.Node = .{},
    /// How many have it open.
    holders: u32 = 0,
    /// The TrueType file; the outline reads it in place.
    file: ?*anyopaque = null,
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
            if (openFamily(dfb, &face_name)) |font| return font;
        }
    }
    return openFamily(dfb, name);
}

/// One family's outline: held already, or its file read and opened.
fn openFamily(dfb: *DiskfontBase, name: [*:0]const u8) ?*diskfont.OutlineFont {
    var path: [256:0]u8 = @splat(0);
    opendiskfont.contentsPath(dfb, name, &path);
    if (find(dfb, &path)) |record| {
        record.holders += 1;
        return &record.font;
    }
    var contents = _font.readContents(dfb, &path);
    defer contents.free(dfb);
    return openIn(dfb, &path, &contents);
}

/// The outline of the family whose contents file, at `path`, is
/// `contents`: held already, or its file read and opened. The caller
/// holds the load lock, and gives the outline back with `close`.
///
/// INPUTS:
/// - `dfb` - the library.
/// - `path` - the contents file, as `contentsPath` makes it.
/// - `contents` - what it holds.
///
/// RESULT:
/// The outline, held once more; null if the family has none, or its
/// file cannot be read or opened.
pub fn openIn(dfb: *DiskfontBase, path: *const [256:0]u8, contents: *const _font.Contents) ?*diskfont.OutlineFont {
    const sys = dfb.sys_base;
    if (find(dfb, path)) |record| {
        record.holders += 1;
        return &record.font;
    }
    const entry = opendiskfont.outlineOf(contents) orelse return null;
    const tb = _font.trueType(dfb) orelse return null;
    // The system's, not the task's that opened it first: it is shared.
    const flags = exec.MEMF_ANY | exec.MEMF_SYSTEM;
    const data = _font.readWhole(dfb, contents.dir, @ptrCast(&entry.path), flags) orelse return null;
    const outline = tb.OpenOutline(data.ptr, @intCast(data.len), null) orelse {
        sys.FreeVec(data.ptr);
        return null;
    };
    const memory = sys.AllocVec(@sizeOf(OutlineRecord), flags) orelse {
        tb.CloseOutline(outline);
        sys.FreeVec(data.ptr);
        return null;
    };
    const record: *OutlineRecord = @ptrCast(@alignCast(memory));
    record.* = .{
        .font = .{ .outline = outline, .style = entry.style & opendiskfont.face_styles },
        .holders = 1,
        .file = data.ptr,
        .key = path.*,
    };
    sys.AddTail(&dfb.outlines, &record.link);
    return &record.font;
}

/// The record opened from the contents file at `path`, if there is one.
fn find(dfb: *DiskfontBase, path: *const [256:0]u8) ?*OutlineRecord {
    var at = dfb.outlines.first();
    while (at) |node| : (at = node.next()) {
        const record: *OutlineRecord = @fieldParentPtr("link", node);
        if (samePath(&record.key, path)) return record;
    }
    return null;
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
        sys.FreeVec(record.file);
        sys.FreeVec(record);
        return true;
    }
    return false;
}
