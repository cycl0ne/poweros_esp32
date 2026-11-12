// SPDX-License-Identifier: MIT
//! Host tests of diskfont.library as a whole: the library made from its
//! ROM tag on the ROM's exec, utility, rtg, graphics and dos, with a RAM
//! disk mounted as FONTS: for the test to write font files onto, and
//! spoken to through its jump table.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const graphics = sdk.graphics;
const diskfont = sdk.diskfont;
const fontimage = graphics.fontimage;
const fontfile = diskfont.fontfile;
const host = @import("host_rom");
const kexec = host.exec;
const diskfont_init = @import("../diskfont_init.zig");
const _base = @import("../diskfont_base.zig");
const _outline = @import("../outline/_outline.zig");
const _font = @import("../font/_font.zig");

const testing = std.testing;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const DosBase = sdk.interface.dos.DosBase;

test {
    _ = @import("../diskfont_lvo.zig");
}

/// A family "test.font" at 8 and 16 rows: 'A' a bar, '?' the default.
fn familySpec(comptime rows: u16) fontimage.Spec {
    return .{
        .height = rows,
        .baseline = rows - 2,
        .x_size = rows / 2,
        .flags = graphics.FPF_DESIGNED,
        .default_char = '?',
        .glyphs = &.{
            .{ .code = '?', .advance = rows / 2, .width = 8, .rows = 1, .pixels = &.{0xFF} },
            .{ .code = 'A', .advance = rows / 2, .top = 1, .width = 8, .rows = 2, .pixels = &.{ 0xF0, 0x0F } },
        },
    };
}
const size8: [fontimage.imageSize(familySpec(8))]u8 align(4) = fontimage.build(familySpec(8));
const size16: [fontimage.imageSize(familySpec(16))]u8 align(4) = fontimage.build(familySpec(16));

/// A size of a fallback family: `letter` a bar, '?' the default, each
/// `advance` across, on a baseline a row above the test family's.
fn letterSpec(comptime rows: u16, comptime letter: u21, comptime advance: i16) fontimage.Spec {
    return .{
        .height = rows,
        .baseline = rows - 3,
        .x_size = @intCast(advance),
        .flags = graphics.FPF_DESIGNED,
        .default_char = '?',
        .glyphs = &.{
            .{ .code = '?', .advance = advance, .width = 8, .rows = 1, .pixels = &.{0xFF} },
            .{ .code = letter, .advance = advance, .top = 1, .width = 8, .rows = 2, .pixels = &.{ 0xF0, 0x0F } },
        },
    };
}
/// "more.font" at 8 and 16 rows draws B, "last.font" at 16 rows only C.
const more8: [fontimage.imageSize(letterSpec(8, 'B', 5))]u8 align(4) = fontimage.build(letterSpec(8, 'B', 5));
const more16: [fontimage.imageSize(letterSpec(16, 'B', 9))]u8 align(4) = fontimage.build(letterSpec(16, 'B', 9));
const last16: [fontimage.imageSize(letterSpec(16, 'C', 11))]u8 align(4) = fontimage.build(letterSpec(16, 'C', 11));

/// What `Rig.lend` hands exec: room for a font file past 4 MiB on the
/// disk, read whole, and for the disk growing the file as it is written.
var lent: [24 * 1024 * 1024]u8 align(16) = undefined;

/// The RAM disk behind FONTS: and ENV:, answering the test process's
/// packets.
const Disk = struct {
    var port: exec.MsgPort = undefined;
    var disk: host.ram.RamDisk = undefined;
    var dl: *DosBase = undefined;

    fn wait(proc: *dos.Process, sys: *sdk.interface.exec.ExecBase) callconv(.c) *exec.Message {
        const pkt = dos.DosPacket.fromMessage(sys.GetMsg(&port).?);
        const reply = disk.answer(pkt);
        dl.ReplyPkt(pkt, reply.res1, reply.res2);
        return sys.GetMsg(&proc.msg_port).?;
    }
};

/// exec, utility, rtg, graphics and dos; a process with FONTS: behind it;
/// diskfont.library opened.
const Rig = struct {
    db: *host.dos.DosBase,
    gb: *host.graphics.GraphicsBase,
    proc: dos.Process = .{},
    saved: ?*kexec.Task = null,
    dfb: *DiskfontBase = undefined,
    library: *exec.Library = undefined,
    /// The memory lent to exec, if a test asked for it.
    region: ?*exec.MemHeader = null,

    /// Memory for a test of a large file: the disk's copy of it and the
    /// one diskfont.library reads come out of this, being the region
    /// MEMF_ANY tries first. Given back, whole, by `deinit`.
    fn lend(rig: *Rig) !void {
        rig.region = rig.sysLib().AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent") orelse return error.NoRegion;
    }

    fn init(rig: *Rig) !void {
        rig.* = .{ .db = try host.dos.testSetUp(), .gb = undefined };
        _ = kexec.InitResident(kexec.SysBase, &host.rtg.rtg_library_tag, null) orelse return error.NoRtg;
        const made = kexec.InitResident(kexec.SysBase, &host.graphics.graphics_library_tag, null) orelse return error.NoGraphics;
        rig.gb = @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));

        rig.proc.task.node.name = "test process";
        host.dos_process.initMsgPort(&rig.proc);
        rig.saved = kexec.SysBase.cpu().this_task;
        kexec.SysBase.cpu().this_task = &rig.proc.task;

        const dos_lib = rig.dosLib();
        Disk.dl = dos_lib;
        Disk.port = .{ .flags = exec.PA_IGNORE };
        Disk.port.msg_list.init(.message);
        Disk.disk = try host.ram.RamDisk.init(rig.db.sys_base, dos_lib, rig.db.utility_base, &Disk.port);
        const node = dos_lib.MakeDosEntry("FONTS", dos.DLT_DEVICE).?;
        node.task = &Disk.port;
        try testing.expect(dos_lib.AddDosEntry(node));
        rig.proc.pkt_wait = &Disk.wait;

        const lib = kexec.InitResident(kexec.SysBase, &diskfont_init.diskfont_library_tag, null) orelse return error.NoDiskfont;
        rig.library = @ptrCast(@alignCast(lib));
        rig.dfb = @ptrCast(rig.sysLib().OpenLibrary(diskfont.DISKFONTNAME, 1) orelse return error.NoBase);
    }

    fn sysLib(_: *Rig) *sdk.interface.exec.ExecBase {
        return kexec.SysBase.iface();
    }

    fn dosLib(rig: *Rig) *DosBase {
        return host.dos.testBase(rig.db);
    }

    fn graphicsLib(rig: *Rig) *GraphicsBase {
        return @ptrCast(rig.gb);
    }

    /// The library closed and expunged, the disk and every library taken
    /// down, and nothing left behind.
    fn deinit(rig: *Rig) !void {
        rig.sysLib().CloseLibrary(rig.dfb.lib());
        _ = rig.sysLib().RemLibrary(rig.library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, diskfont.DISKFONTNAME) == null);
        Disk.disk.deinit();
        kexec.SysBase.cpu().this_task = rig.saved.?;

        const gb = rig.gb;
        const rb: *host.rtg.RtgBase = @ptrCast(@alignCast(gb.rtg_base));
        const ub: *exec.Library = @ptrCast(@alignCast(gb.utility_base));
        host.graphics.freeOwnedForTests(gb);
        kexec.CloseLibrary(kexec.SysBase, &rb.lib);
        kexec.CloseLibrary(kexec.SysBase, ub);
        kexec.Remove(kexec.SysBase, &gb.lib.node);
        kexec.freeLibraryMemory(kexec.SysBase, &gb.lib);
        kexec.CloseLibrary(kexec.SysBase, ub);
        kexec.Remove(kexec.SysBase, &rb.lib.node);
        kexec.freeLibraryMemory(kexec.SysBase, &rb.lib);
        try host.dos.testTearDown(rig.db);
        if (rig.region) |region| {
            try testing.expectEqual(@intFromPtr(region.upper) - @intFromPtr(region.lower), region.free);
            rig.sysLib().Remove(&region.node);
        }
        kexec.deinit();
    }

    /// A file on FONTS:.
    fn write(rig: *Rig, name: [*:0]const u8, bytes: []const u8) !void {
        const fh = rig.dosLib().Open(name, dos.MODE_NEWFILE) orelse return error.NoFile;
        try testing.expectEqual(@as(isize, @intCast(bytes.len)), rig.dosLib().Write(fh, bytes.ptr, @intCast(bytes.len)));
        try testing.expect(rig.dosLib().Close(fh));
    }

    /// A family of bitmap sizes on FONTS:: each image under its height,
    /// and the contents file made from the directory.
    fn writeSizes(rig: *Rig, comptime name: []const u8, comptime heights: []const u16, images: []const []const u8) !void {
        const made = rig.dosLib().CreateDir("FONTS:" ++ name) orelse return error.NoDir;
        rig.dosLib().UnLock(made);
        inline for (heights, 0..) |height, index| {
            try rig.write("FONTS:" ++ name ++ "/" ++ std.fmt.comptimePrint("{d}", .{height}), images[index]);
        }
        const fonts = rig.dosLib().Lock("FONTS:", dos.SHARED_LOCK).?;
        defer rig.dosLib().UnLock(fonts);
        const contents = rig.dfb.NewFontContents(fonts, name ++ ".font") orelse return error.NoContents;
        defer rig.dfb.DisposeFontContents(contents);
        const block: [*]align(4) u8 = @ptrCast(contents);
        try rig.write("FONTS:" ++ name ++ ".font", block[0..fontfile.contentsSize(contents.count)]);
    }

    /// The test family and the two fallback families on FONTS:, and ENV:
    /// on the same disk with its Sys drawer.
    fn writeFallbackFamilies(rig: *Rig) !void {
        try rig.writeFamily();
        try rig.writeSizes("more", &.{ 8, 16 }, &.{ &more8, &more16 });
        try rig.writeSizes("last", &.{16}, &.{&last16});
        const node = rig.dosLib().MakeDosEntry("ENV", dos.DLT_DEVICE).?;
        node.task = &Disk.port;
        try testing.expect(rig.dosLib().AddDosEntry(node));
        const made = rig.dosLib().CreateDir("ENV:Sys") orelse return error.NoDir;
        rig.dosLib().UnLock(made);
    }

    /// `line` as the whole of ENV:Sys/font.prefs.
    fn writePrefs(rig: *Rig, line: []const u8) !void {
        try rig.write(sdk.prefs.font.ENV_FILE, line);
    }

    /// The test family on FONTS:: its two sizes and its contents file.
    fn writeFamily(rig: *Rig) !void {
        const made = rig.dosLib().CreateDir("FONTS:test") orelse return error.NoDir;
        rig.dosLib().UnLock(made);
        try rig.write("FONTS:test/8", &size8);
        try rig.write("FONTS:test/16", &size16);
        var contents: [fontfile.contentsSize(2)]u8 align(4) = @splat(0);
        const header: *fontfile.ContentsHeader = @ptrCast(&contents);
        header.* = .{ .count = 2 };
        const entries: *[2]fontfile.FontContents = @ptrCast(@alignCast(contents[@sizeOf(fontfile.ContentsHeader)..]));
        entries[0] = fontfile.entryFor("test/8", @ptrCast(&size8));
        entries[1] = fontfile.entryFor("test/16", @ptrCast(&size16));
        fontfile.seal(&contents, contents.len);
        try rig.write("FONTS:test.font", &contents);
    }
};

fn fontsLoaded(rig: *Rig) usize {
    const real: *_base.DiskfontBase = @ptrCast(@alignCast(rig.dfb));
    var n: usize = 0;
    var at = real.fonts.first();
    while (at) |node| : (at = node.next()) n += 1;
    return n;
}

test "OpenDiskFont: a size loaded, then found in memory; the nearest drawn; scaled sizes" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    try rig.writeFamily();
    const dfb = rig.dfb;
    const gb = rig.graphicsLib();

    // Exact: loaded from FONTS:test/8, a disk font.
    const eight = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 8 }) orelse return error.NoFont;
    try testing.expectEqual(@as(u16, 8), eight.image.height);
    try testing.expect(eight.flags & graphics.FPF_DISKFONT != 0);
    try testing.expectEqualStrings("test.font", std.mem.span(eight.node.name.?));
    try testing.expectEqual(@as(usize, 1), fontsLoaded(&rig));
    // Again: the one in memory, not a second load.
    const again = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 8 }).?;
    try testing.expectEqual(eight, again);
    try testing.expectEqual(@as(usize, 1), fontsLoaded(&rig));
    // graphics' own OpenFont finds it too, now it is on the list.
    const by_graphics = gb.OpenFont(&.{ .name = "test.font", .y_size = 8 }).?;
    try testing.expectEqual(eight, by_graphics);

    // 12, drawn only: the nearest size drawn, the shorter one.
    const drawn = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 12, .flags = graphics.FPF_DESIGNED }).?;
    try testing.expectEqual(eight, drawn);

    // 12, any: scaled from the nearest, and not drawn.
    const twelve = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 12 }).?;
    try testing.expectEqual(@as(u16, 12), twelve.image.height);
    try testing.expectEqual(@as(u8, 0), twelve.image.flags & graphics.FPF_DESIGNED);
    try testing.expectEqual(@as(u16, 6), twelve.image.x_size);
    try testing.expect(fontimage.check(@ptrCast(twelve.image), twelve.image.size));
    try testing.expect(fontimage.sound(@ptrCast(twelve.image), twelve.image.size));
    // 32, any: scaled from half its height, 16, loaded for it.
    const big = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 32 }).?;
    try testing.expectEqual(@as(u16, 32), big.image.height);
    const glyph = fontimage.glyphFor(big.image, 'A');
    try testing.expectEqual(@as(u16, 16), glyph.width);
    try testing.expectEqual(@as(u16, 4), glyph.rows);
    try testing.expectEqual(@as(i16, 2), glyph.top);

    // 8 points at 144 DPI is 16 rows: the size on the disk.
    rig.gb.screen_dpi = 144;
    const pointed = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 8, .flags = graphics.FPF_POINTS }).?;
    try testing.expectEqual(@as(u16, 16), pointed.image.height);
    try testing.expect(pointed.image.flags & graphics.FPF_DESIGNED != 0);
    gb.CloseFont(pointed);
    rig.gb.screen_dpi = 72;

    // A family there is not.
    try testing.expect(dfb.OpenDiskFont(&.{ .name = "none.font", .y_size = 8 }) == null);

    for ([_]*graphics.TextFont{ eight, again, by_graphics, drawn, twelve, big }) |font| gb.CloseFont(font);
}

test "AvailFonts: what it lacked, then everything, names and all" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    try rig.writeFamily();
    const dfb = rig.dfb;

    var small: [16]u8 align(4) = undefined;
    const lacking = dfb.AvailFonts(&small, small.len, diskfont.AFF_MEMORY | diskfont.AFF_DISK);
    try testing.expect(lacking > 0);
    const size = small.len + lacking;
    const buffer = try testing.allocator.alignedAlloc(u8, .@"8", size);
    defer testing.allocator.free(buffer);
    try testing.expectEqual(@as(u32, 0), dfb.AvailFonts(buffer.ptr, @intCast(size), diskfont.AFF_MEMORY | diskfont.AFF_DISK));
    const header: *const diskfont.AvailFontsHeader = @ptrCast(buffer.ptr);
    const entries = diskfont.availEntries(header);
    // The ROM's two pospaz in memory, and the family's two on the disk.
    try testing.expectEqual(@as(u32, 4), header.count);
    var on_disk: u32 = 0;
    for (entries) |entry| {
        if (entry.type == diskfont.AFF_DISK) {
            on_disk += 1;
            try testing.expectEqualStrings("test.font", std.mem.span(entry.attr.name));
        } else {
            try testing.expectEqual(diskfont.AFF_MEMORY, entry.type);
            try testing.expectEqualStrings(graphics.POSPAZNAME, std.mem.span(entry.attr.name));
        }
    }
    try testing.expectEqual(@as(u32, 2), on_disk);
}

test "NewFontContents: a family's sizes read from its directory, in order of height" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    try rig.writeFamily();
    // Something in the directory that is not a font is passed over.
    try rig.write("FONTS:test/readme", "not a font");
    const dfb = rig.dfb;
    const fonts = rig.dosLib().Lock("FONTS:", dos.SHARED_LOCK).?;
    defer rig.dosLib().UnLock(fonts);
    try testing.expect(dfb.NewFontContents(fonts, "test") == null);
    const made = dfb.NewFontContents(fonts, "test.font") orelse return error.NoContents;
    defer dfb.DisposeFontContents(made);
    const block: [*]align(4) u8 = @ptrCast(made);
    try testing.expect(fontfile.sound(block, fontfile.contentsSize(made.count)));
    const entries = fontfile.entriesOf(block);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("test/8", fontfile.pathOf(&entries[0]));
    try testing.expectEqualStrings("test/16", fontfile.pathOf(&entries[1]));
    try testing.expectEqual(@as(u16, 16), entries[1].y_size);
}

test "low memory: fonts nobody holds are freed, one held is kept" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    try rig.writeFamily();
    const dfb = rig.dfb;
    const gb = rig.graphicsLib();
    const eight = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 8 }).?;
    const sixteen = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 16 }).?;
    const scaled = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 24 }).?;
    try testing.expectEqual(@as(usize, 3), fontsLoaded(&rig));
    gb.CloseFont(sixteen);
    gb.CloseFont(scaled);

    // More than there is: the handlers are asked, diskfont's frees the
    // two nobody holds, and the allocation still fails.
    try testing.expect(rig.sysLib().AllocMem(1 << 30, exec.MEMF_ANY) == null);
    try testing.expectEqual(@as(usize, 1), fontsLoaded(&rig));
    try testing.expect(gb.OpenFont(&.{ .name = "test.font", .y_size = 16, .flags = graphics.FPF_DESIGNED }).? == eight);

    gb.CloseFont(eight);
    gb.CloseFont(eight);
}

test "an outline family: any height rendered, listed as scalable, found by NewFontContents" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const tt = @import("../../truetype/tests/truetype.zig");
    const truetype_init = @import("../../truetype/truetype_init.zig");
    const lib = kexec.InitResident(kexec.SysBase, &truetype_init.truetype_library_tag, null) orelse return error.NoTrueType;
    const truetype_lib: *exec.Library = @ptrCast(@alignCast(lib));
    defer _ = rig.sysLib().RemLibrary(truetype_lib);

    var out: tt.Out = .{};
    tt.buildFont(&out);
    const made = rig.dosLib().CreateDir("FONTS:tt") orelse return error.NoDir;
    rig.dosLib().UnLock(made);
    try rig.write("FONTS:tt/tt.ttf", out.bytes[0..out.len]);
    const fonts = rig.dosLib().Lock("FONTS:", dos.SHARED_LOCK).?;
    defer rig.dosLib().UnLock(fonts);
    const contents = rig.dfb.NewFontContents(fonts, "tt.font") orelse return error.NoContents;
    const block: [*]align(4) u8 = @ptrCast(contents);
    const entries = fontfile.entriesOf(block);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(u8, 1), entries[0].outline);
    try testing.expectEqual(graphics.FS_NORMAL, entries[0].style);
    try testing.expectEqualStrings("tt/tt.ttf", fontfile.pathOf(&entries[0]));
    try rig.write("FONTS:tt.font", block[0..fontfile.contentsSize(contents.count)]);
    rig.dfb.DisposeFontContents(contents);

    // Any height, drawn: 20 rows of coverage, the square 10 wide.
    const gb = rig.graphicsLib();
    const font = rig.dfb.OpenDiskFont(&.{ .name = "tt.font", .y_size = 20, .flags = graphics.FPF_DESIGNED }) orelse return error.NoFont;
    try testing.expectEqual(@as(u16, 20), font.image.height);
    try testing.expectEqual(fontimage.Kind.alpha4, font.image.kind);
    try testing.expectEqual(@as(u16, 10), fontimage.find(font.image, 'A').?.width);
    gb.CloseFont(font);

    // Listed once, as scalable, of no height.
    var buffer: [512]u8 align(8) = undefined;
    try testing.expectEqual(@as(u32, 0), rig.dfb.AvailFonts(&buffer, buffer.len, diskfont.AFF_DISK));
    const listed = diskfont.availEntries(@ptrCast(&buffer));
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expectEqual(diskfont.AFF_DISK | diskfont.AFF_SCALABLE, listed[0].type);
    try testing.expectEqual(@as(u16, 0), listed[0].attr.y_size);

    // At the end diskfont's expunge frees the rendered size nobody holds
    // and closes truetype.library, whose RemLibrary above then completes;
    // the leak check says whether all of it went.
}

test "an outline family of cubic curves: found by NewFontContents, a size rendered" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const builder = @import("../../truetype/tests/builder.zig");
    const cff = @import("../../truetype/tests/cff.zig");
    const truetype_init = @import("../../truetype/truetype_init.zig");
    const lib = kexec.InitResident(kexec.SysBase, &truetype_init.truetype_library_tag, null) orelse return error.NoTrueType;
    const truetype_lib: *exec.Library = @ptrCast(@alignCast(lib));
    defer _ = rig.sysLib().RemLibrary(truetype_lib);

    // 'A' is a square 500 units wide and 700 tall, a program of lines.
    var file: builder.File = .{};
    const nothing = builder.program("endchar");
    const square = builder.program("0 0 rmoveto 500 hlineto 700 vlineto -500 hlineto endchar");
    cff.build(&file, .{ .glyphs = &.{ nothing, square } }, false);
    const made = rig.dosLib().CreateDir("FONTS:cubic") orelse return error.NoDir;
    rig.dosLib().UnLock(made);
    try rig.write("FONTS:cubic/cubic.otf", file.bytes[0..file.len]);
    const fonts = rig.dosLib().Lock("FONTS:", dos.SHARED_LOCK).?;
    defer rig.dosLib().UnLock(fonts);
    const contents = rig.dfb.NewFontContents(fonts, "cubic.font") orelse return error.NoContents;
    const block: [*]align(4) u8 = @ptrCast(contents);
    const entries = fontfile.entriesOf(block);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(u8, 1), entries[0].outline);
    try testing.expectEqualStrings("cubic/cubic.otf", fontfile.pathOf(&entries[0]));
    try rig.write("FONTS:cubic.font", block[0..fontfile.contentsSize(contents.count)]);
    rig.dfb.DisposeFontContents(contents);

    // 20 rows of coverage, the square 10 wide, as the same square of a
    // font of quadratic curves is.
    const gb = rig.graphicsLib();
    const font = rig.dfb.OpenDiskFont(&.{ .name = "cubic.font", .y_size = 20, .flags = graphics.FPF_DESIGNED }) orelse return error.NoFont;
    try testing.expectEqual(@as(u16, 20), font.image.height);
    try testing.expectEqual(fontimage.Kind.alpha4, font.image.kind);
    try testing.expectEqual(@as(u16, 10), fontimage.find(font.image, 'A').?.width);
    gb.CloseFont(font);
}

test "revision 12: a family whose outline is a font of colour pictures in a file past 4 MiB: found by NewFontContents, a size rendered in colour" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    try rig.lend();
    const builder = @import("../../truetype/tests/builder.zig");
    const pictured = @import("../../truetype/tests/strike.zig");
    const truetype_init = @import("../../truetype/truetype_init.zig");
    const compression_init = @import("../../compression/compression_init.zig");
    const lib = kexec.InitResident(kexec.SysBase, &truetype_init.truetype_library_tag, null) orelse return error.NoTrueType;
    const truetype_lib: *exec.Library = @ptrCast(@alignCast(lib));
    defer _ = rig.sysLib().RemLibrary(truetype_lib);
    const packer = kexec.InitResident(kexec.SysBase, &compression_init.compression_library_tag, null) orelse return error.NoCompression;
    const compression_lib: *exec.Library = @ptrCast(@alignCast(packer));
    defer _ = rig.sysLib().RemLibrary(compression_lib);

    // 'A' is a picture of two pixels by two on the baseline, in a strike
    // of 20 pixels an em; the file goes on past its tables, as one of
    // thousands of pictures does past 4 MiB.
    var file: builder.File = .{};
    pictured.colourFont(&file);
    const long = try testing.allocator.alloc(u8, 4 * 1024 * 1024 + 1);
    defer testing.allocator.free(long);
    @memset(long, 0);
    @memcpy(long[0..file.len], file.bytes[0..file.len]);
    const made = rig.dosLib().CreateDir("FONTS:emoji") orelse return error.NoDir;
    rig.dosLib().UnLock(made);
    try rig.write("FONTS:emoji/emoji.ttf", long);
    const fonts = rig.dosLib().Lock("FONTS:", dos.SHARED_LOCK).?;
    defer rig.dosLib().UnLock(fonts);
    const contents = rig.dfb.NewFontContents(fonts, "emoji.font") orelse return error.NoContents;
    const block: [*]align(4) u8 = @ptrCast(contents);
    const entries = fontfile.entriesOf(block);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(u8, 1), entries[0].outline);
    try testing.expectEqualStrings("emoji/emoji.ttf", fontfile.pathOf(&entries[0]));
    try rig.write("FONTS:emoji.font", block[0..fontfile.contentsSize(contents.count)]);
    rig.dfb.DisposeFontContents(contents);

    // 20 rows of colour: the picture at its strike's own size, pixel for
    // pixel.
    const gb = rig.graphicsLib();
    const font = rig.dfb.OpenDiskFont(&.{ .name = "emoji.font", .y_size = 20, .flags = graphics.FPF_DESIGNED }) orelse return error.NoFont;
    try testing.expectEqual(@as(u16, 20), font.image.height);
    try testing.expectEqual(fontimage.Kind.rgba32, font.image.kind);
    try testing.expectEqual(@as(u16, 2), fontimage.find(font.image, 'A').?.width);
    gb.CloseFont(font);
}

/// An outline family `name` whose font file says it is drawn in
/// `style_bits` (1 bold, 2 italic), its contents file made by
/// NewFontContents.
fn writeOutlineFamily(rig: *Rig, comptime name: []const u8, style_bits: u8) !void {
    return writeOutlineFamilyAt(rig, name, style_bits, 'A');
}

/// The same family with its three glyphs at `first` and the two
/// characters after it.
fn writeOutlineFamilyAt(rig: *Rig, comptime name: []const u8, style_bits: u8, first: u16) !void {
    const tt = @import("../../truetype/tests/truetype.zig");
    var out: tt.Out = .{};
    tt.buildFaceAt(&out, style_bits, first);
    return writeOutlineFile(rig, name, out.bytes[0..out.len]);
}

/// A family of one TrueType file, `bytes`, and its contents file.
fn writeOutlineFile(rig: *Rig, comptime name: []const u8, bytes: []const u8) !void {
    const made = rig.dosLib().CreateDir("FONTS:" ++ name) orelse return error.NoDir;
    rig.dosLib().UnLock(made);
    try rig.write("FONTS:" ++ name ++ "/" ++ name ++ ".ttf", bytes);
    const fonts = rig.dosLib().Lock("FONTS:", dos.SHARED_LOCK).?;
    defer rig.dosLib().UnLock(fonts);
    const contents = rig.dfb.NewFontContents(fonts, name ++ ".font") orelse return error.NoContents;
    defer rig.dfb.DisposeFontContents(contents);
    const block: [*]align(4) u8 = @ptrCast(contents);
    try rig.write("FONTS:" ++ name ++ ".font", block[0..fontfile.contentsSize(contents.count)]);
}

test "faces: bold asked of a family is its bold face, drawn bold; a face it lacks is left to the soft styles" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const truetype_init = @import("../../truetype/truetype_init.zig");
    const lib = kexec.InitResident(kexec.SysBase, &truetype_init.truetype_library_tag, null) orelse return error.NoTrueType;
    const truetype_lib: *exec.Library = @ptrCast(@alignCast(lib));
    defer _ = rig.sysLib().RemLibrary(truetype_lib);
    try writeOutlineFamily(&rig, "tt", 0);
    try writeOutlineFamily(&rig, "tt-bold", 1);

    // The bold face's entry says what its file says.
    const fonts = rig.dosLib().Lock("FONTS:", dos.SHARED_LOCK).?;
    const listed = rig.dfb.NewFontContents(fonts, "tt-bold.font") orelse return error.NoContents;
    rig.dosLib().UnLock(fonts);
    try testing.expectEqual(graphics.FSF_BOLD, fontfile.entriesOf(@ptrCast(listed))[0].style);
    rig.dfb.DisposeFontContents(listed);

    const gb = rig.graphicsLib();
    // Bold: the bold face, drawn bold, so graphics adds no bold of its own.
    const bold = rig.dfb.OpenDiskFont(&.{ .name = "tt.font", .y_size = 20, .style = graphics.FSF_BOLD }) orelse return error.NoFont;
    defer gb.CloseFont(bold);
    try testing.expectEqualStrings("tt-bold.font", std.mem.span(bold.node.name.?));
    try testing.expectEqual(graphics.FSF_BOLD, bold.image.style);
    // Bold italic: no face for both, so the bold one, for the soft
    // styles to lean.
    const both = rig.dfb.OpenDiskFont(&.{ .name = "tt.font", .y_size = 20, .style = graphics.FSF_BOLD | graphics.FSF_ITALIC }) orelse return error.NoFont;
    defer gb.CloseFont(both);
    try testing.expectEqual(bold, both);
    // Italic: no italic face, the family itself, plain.
    const italic = rig.dfb.OpenDiskFont(&.{ .name = "tt.font", .y_size = 20, .style = graphics.FSF_ITALIC }) orelse return error.NoFont;
    defer gb.CloseFont(italic);
    try testing.expectEqualStrings("tt.font", std.mem.span(italic.node.name.?));
    try testing.expectEqual(graphics.FS_NORMAL, italic.image.style);

    // The face asked by its own name, plain, is the size in memory: the
    // outline is not rendered twice.
    const loaded = fontsLoaded(&rig);
    const again = rig.dfb.OpenDiskFont(&.{ .name = "tt-bold.font", .y_size = 20 }) orelse return error.NoFont;
    defer gb.CloseFont(again);
    try testing.expectEqual(bold, again);
    try testing.expectEqual(loaded, fontsLoaded(&rig));
}

test "NewScaledDiskFont: the caller's, freed with FreeVec" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const gb = rig.graphicsLib();
    const pospaz = gb.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = 8 }).?;
    defer gb.CloseFont(pospaz);
    const double = rig.dfb.NewScaledDiskFont(pospaz, &.{ .name = "", .y_size = 16 }) orelse return error.NoFont;
    try testing.expectEqual(@as(u16, 16), double.image.height);
    try testing.expectEqual(@as(u16, 16), double.image.x_size);
    try testing.expect(fontimage.check(@ptrCast(double.image), double.image.size));
    // Every pixel of 'A' doubled: twice the width and twice the rows.
    const from = fontimage.glyphFor(pospaz.image, 'A');
    const to = fontimage.glyphFor(double.image, 'A');
    try testing.expectEqual(2 * from.width, to.width);
    try testing.expectEqual(2 * from.rows, to.rows);
    try testing.expect(rig.dfb.NewScaledDiskFont(pospaz, &.{ .name = "", .y_size = 0 }) == null);
    rig.sysLib().FreeVec(double);
}

/// 4 rows, 32-bit colour: 'r' is red whole, then green covering half.
const rgba_spec = fontimage.Spec{
    .height = 4,
    .baseline = 3,
    .x_size = 3,
    .kind = .rgba32,
    .default_char = 'r',
    .glyphs = &.{.{ .code = 'r', .advance = 3, .top = 1, .width = 2, .rows = 1, .pixels = &.{
        0xFF, 0, 0,    0xFF,
        0,    0, 0xFF, 0x80,
    } }},
};
const rgba_image: [fontimage.imageSize(rgba_spec)]u8 align(4) = fontimage.build(rgba_spec);

test "NewScaledDiskFont: a font of 32-bit colour keeps every pixel's four bytes; a size no image holds is refused" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const gb = rig.graphicsLib();
    var colour = graphics.TextFont{ .node = .{ .name = "rgba.font" }, .image = @ptrCast(&rgba_image) };

    const double = rig.dfb.NewScaledDiskFont(&colour, &.{ .name = "", .y_size = 8 }) orelse return error.NoFont;
    try testing.expectEqual(fontimage.Kind.rgba32, double.image.kind);
    try testing.expectEqual(@as(u16, 8), double.image.height);
    try testing.expectEqual(@as(u32, 0), double.image.palette_count);
    try testing.expectEqual(fontimage.NO_PEN, double.image.pen_index);
    try testing.expect(fontimage.check(@ptrCast(double.image), double.image.size));
    try testing.expect(fontimage.sound(@ptrCast(double.image), double.image.size));
    // Every pixel doubled each way, its colour and its coverage whole.
    const glyph = fontimage.glyphFor(double.image, 'r');
    try testing.expectEqual(@as(u16, 4), glyph.width);
    try testing.expectEqual(@as(u16, 2), glyph.rows);
    try testing.expectEqual(@as(i16, 2), glyph.top);
    try testing.expectEqual(@as(i16, 6), glyph.advance);
    try testing.expectEqual(@as(u16, 16), glyph.pitch);
    const row = [_]u8{
        0xFF, 0, 0,    0xFF, 0xFF, 0, 0,    0xFF,
        0,    0, 0xFF, 0x80, 0,    0, 0xFF, 0x80,
    };
    const px = fontimage.pixelsOf(double.image, glyph);
    try testing.expectEqualSlices(u8, &row, px[0..16]);
    try testing.expectEqualSlices(u8, &row, px[16..32]);
    rig.sysLib().FreeVec(double);

    // Three rows from four: the nearest pixel, never a mix of two.
    const small = rig.dfb.NewScaledDiskFont(&colour, &.{ .name = "", .y_size = 3 }) orelse return error.NoFont;
    try testing.expect(fontimage.check(@ptrCast(small.image), small.image.size));
    const small_glyph = fontimage.glyphFor(small.image, 'r');
    const small_px = fontimage.pixelsOf(small.image, small_glyph);
    for (0..small_glyph.rows) |y| for (0..small_glyph.width) |x| {
        const pixel = small_px[y * small_glyph.pitch + x * 4 ..][0..4];
        const red = std.mem.eql(u8, pixel, &.{ 0xFF, 0, 0, 0xFF });
        const blue = std.mem.eql(u8, pixel, &.{ 0, 0, 0xFF, 0x80 });
        try testing.expect(red or blue);
    };
    rig.sysLib().FreeVec(small);

    // A row of more than 65535 bytes, and a box wider than 32767
    // pixels: no font image holds either, and none is made.
    try testing.expect(rig.dfb.NewScaledDiskFont(&colour, &.{ .name = "", .y_size = 40000 }) == null);
    const pospaz = gb.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = 8 }).?;
    defer gb.CloseFont(pospaz);
    try testing.expect(rig.dfb.NewScaledDiskFont(pospaz, &.{ .name = "", .y_size = 65535 }) == null);
}

fn outlinesLoaded(rig: *Rig) usize {
    const real: *_base.DiskfontBase = @ptrCast(@alignCast(rig.dfb));
    var n: usize = 0;
    var at = real.outlines.first();
    while (at) |node| : (at = node.next()) n += 1;
    return n;
}

test "revision 4: an outline opened by its family, the face for the styles, shared, kept until memory runs short" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    try testing.expect(rig.dfb.lib().revision >= 4);
    const truetype_init = @import("../../truetype/truetype_init.zig");
    const lib = kexec.InitResident(kexec.SysBase, &truetype_init.truetype_library_tag, null) orelse return error.NoTrueType;
    const truetype_lib: *exec.Library = @ptrCast(@alignCast(lib));
    defer _ = rig.sysLib().RemLibrary(truetype_lib);
    try writeOutlineFamily(&rig, "tt", 0);
    try writeOutlineFamily(&rig, "tt-italic", 2);
    try rig.writeFamily();
    const dfb = rig.dfb;
    const tb: *sdk.interface.truetype.TrueTypeBase = @ptrCast(rig.sysLib().OpenLibrary(sdk.truetype.TRUETYPENAME, 1).?);
    defer rig.sysLib().CloseLibrary(tb.lib());

    // The family's own, plain; read by truetype.library's calls.
    const plain = dfb.OpenOutlineFont("tt.font", graphics.FS_NORMAL) orelse return error.NoOutline;
    try testing.expectEqual(graphics.FS_NORMAL, plain.style);
    try testing.expectEqual(@as(u32, 1), tb.GlyphIndex(plain.outline, 'A'));
    // Italic: its face. Bold italic: no face draws both, so the italic one.
    const italic = dfb.OpenOutlineFont("FONTS:tt.font", graphics.FSF_ITALIC) orelse return error.NoOutline;
    try testing.expectEqual(graphics.FSF_ITALIC, italic.style);
    const both = dfb.OpenOutlineFont("tt.font", graphics.FSF_BOLD | graphics.FSF_ITALIC) orelse return error.NoOutline;
    try testing.expectEqual(italic, both);
    // Bold: no face, the family's own - the same one, shared.
    const bold = dfb.OpenOutlineFont("TT.font", graphics.FSF_BOLD) orelse return error.NoOutline;
    try testing.expectEqual(plain, bold);
    try testing.expectEqual(@as(usize, 2), outlinesLoaded(&rig));

    // A family of bitmaps only, and none at all.
    try testing.expect(dfb.OpenOutlineFont("test.font", graphics.FS_NORMAL) == null);
    try testing.expect(dfb.OpenOutlineFont("none.font", graphics.FS_NORMAL) == null);

    // Closed, they stay; short of memory, those nobody holds go.
    dfb.CloseOutlineFont(both);
    dfb.CloseOutlineFont(italic);
    dfb.CloseOutlineFont(bold);
    dfb.CloseOutlineFont(null);
    try testing.expectEqual(@as(usize, 2), outlinesLoaded(&rig));
    try testing.expect(rig.sysLib().AllocMem(1 << 30, exec.MEMF_ANY) == null);
    try testing.expectEqual(@as(usize, 1), outlinesLoaded(&rig));
    try testing.expectEqual(@as(u32, 3), tb.GlyphIndex(plain.outline, 'C'));
    dfb.CloseOutlineFont(plain);
    // The expunge at the end frees the last.
}

/// An axis as `FontAxes` gives it.
fn axisAt(comptime tag: *const [4]u8, minimum: f32, default: f32, maximum: f32) sdk.truetype.Axis {
    return .{ .tag = sdk.truetype.tableTag(tag), .minimum = minimum, .default = default, .maximum = maximum, .value = default, .name = 0, .hidden = false };
}

/// Where an entry is on the axis `tag`; null if it does not name it.
fn entryAt(entry: *const fontfile.FontContents, comptime tag: *const [4]u8) ?f32 {
    for (entry.axes[0..entry.axis_count]) |axis| {
        if (axis.tag == sdk.truetype.tableTag(tag)) return axis.value;
    }
    return null;
}

test "a variable font's styles: by the names of its instances, else by what its axes mean; what they cannot give is left out" {
    const bold = graphics.FSF_BOLD;
    const italic = graphics.FSF_ITALIC;

    // An instance's name is a style whatever its case and spacing.
    try testing.expectEqual(@as(?graphics.FontStyle, graphics.FS_NORMAL), fontfile.styleOfName("Regular"));
    try testing.expectEqual(@as(?graphics.FontStyle, bold), fontfile.styleOfName("BOLD"));
    try testing.expectEqual(@as(?graphics.FontStyle, italic), fontfile.styleOfName("italic"));
    try testing.expectEqual(@as(?graphics.FontStyle, bold | italic), fontfile.styleOfName("Bold Italic"));
    try testing.expectEqual(@as(?graphics.FontStyle, bold | italic), fontfile.styleOfName("BoldItalic"));
    for ([_][]const u8{ "", "Light", "Bol", "Bolder", "Semibold Italic", "Italic Bold" }) |other| {
        try testing.expectEqual(@as(?graphics.FontStyle, null), fontfile.styleOfName(other));
    }

    const none: [4]?fontfile.Place = @splat(null);
    var made: [4]fontfile.FontContents = undefined;

    // A weight axis whose default is the lightest: regular is 400, bold
    // 700, and there is no italic.
    {
        const axes = [_]sdk.truetype.Axis{axisAt("wght", 200, 200, 900)};
        try testing.expectEqual(@as(u32, 2), fontfile.variableEntries("v/v.ttf", graphics.FS_NORMAL, &axes, &none, &made));
        try testing.expectEqual(graphics.FS_NORMAL, made[0].style);
        try testing.expectEqual(@as(?f32, 400), entryAt(&made[0], "wght"));
        try testing.expectEqual(bold, made[1].style);
        try testing.expectEqual(@as(?f32, 700), entryAt(&made[1], "wght"));
        for (made[0..2]) |*entry| {
            try testing.expectEqualStrings("v/v.ttf", fontfile.pathOf(entry));
            try testing.expectEqual(@as(u8, 1), entry.outline);
            try testing.expectEqual(@as(u16, 0), entry.y_size);
        }
    }
    // Regular at the default names no axis; bold held to the range; a
    // slant leans to its far end, and bold italic is both.
    {
        const axes = [_]sdk.truetype.Axis{ axisAt("wght", 300, 400, 600), axisAt("slnt", -10, 0, 0) };
        try testing.expectEqual(@as(u32, 4), fontfile.variableEntries("v/v.ttf", graphics.FS_NORMAL, &axes, &none, &made));
        try testing.expectEqual(@as(u8, 0), made[0].axis_count);
        try testing.expectEqual(bold, made[1].style);
        try testing.expectEqual(@as(?f32, 600), entryAt(&made[1], "wght"));
        try testing.expectEqual(italic, made[2].style);
        try testing.expectEqual(@as(?f32, null), entryAt(&made[2], "wght"));
        try testing.expectEqual(@as(?f32, -10), entryAt(&made[2], "slnt"));
        try testing.expectEqual(bold | italic, made[3].style);
        try testing.expectEqual(@as(?f32, 600), entryAt(&made[3], "wght"));
        try testing.expectEqual(@as(?f32, -10), entryAt(&made[3], "slnt"));
    }
    // `ital` is taken before `slnt`.
    {
        const axes = [_]sdk.truetype.Axis{ axisAt("slnt", -10, 0, 0), axisAt("ital", 0, 0, 1) };
        try testing.expectEqual(@as(u32, 2), fontfile.variableEntries("v/v.ttf", graphics.FS_NORMAL, &axes, &none, &made));
        try testing.expectEqual(italic, made[1].style);
        try testing.expectEqual(@as(?f32, 1), entryAt(&made[1], "ital"));
        try testing.expectEqual(@as(?f32, null), entryAt(&made[1], "slnt"));
    }
    // Axes that are neither weight nor lean, and a weight that goes no
    // bolder than regular: the one entry, the rest for the soft styles.
    {
        const axes = [_]sdk.truetype.Axis{ axisAt("wdth", 50, 100, 200), axisAt("wght", 100, 400, 400) };
        try testing.expectEqual(@as(u32, 1), fontfile.variableEntries("v/v.ttf", graphics.FS_NORMAL, &axes, &none, &made));
        try testing.expectEqual(@as(u8, 0), made[0].axis_count);
    }
    // A file that says it is italic: its own style and that with bold.
    {
        const axes = [_]sdk.truetype.Axis{axisAt("wght", 200, 200, 900)};
        try testing.expectEqual(@as(u32, 2), fontfile.variableEntries("v/v.ttf", italic, &axes, &none, &made));
        try testing.expectEqual(italic, made[0].style);
        try testing.expectEqual(@as(?f32, 400), entryAt(&made[0], "wght"));
        try testing.expectEqual(bold | italic, made[1].style);
        try testing.expectEqual(@as(?f32, 700), entryAt(&made[1], "wght"));
    }
    // A file that says it is bold stays where it is, and has no bolder.
    {
        const axes = [_]sdk.truetype.Axis{axisAt("wght", 200, 700, 900)};
        try testing.expectEqual(@as(u32, 1), fontfile.variableEntries("v/v.ttf", bold, &axes, &none, &made));
        try testing.expectEqual(bold, made[0].style);
        try testing.expectEqual(@as(u8, 0), made[0].axis_count);
    }
    // A named place is taken before the axes' meaning, and bold italic
    // builds on the regular one where the file names none of its own.
    {
        const axes = [_]sdk.truetype.Axis{ axisAt("wght", 100, 100, 900), axisAt("slnt", -12, 0, 0) };
        var named = none;
        named[0] = fontfile.placeOf(&axes, &.{ .{ .tag = sdk.truetype.tableTag("wght"), .value = 350 }, .{ .tag = sdk.truetype.tableTag("slnt"), .value = 0 } });
        named[bold] = fontfile.placeOf(&axes, &.{.{ .tag = sdk.truetype.tableTag("wght"), .value = 2000 }});
        try testing.expectEqual(@as(u32, 4), fontfile.variableEntries("v/v.ttf", graphics.FS_NORMAL, &axes, &named, &made));
        try testing.expectEqual(@as(?f32, 350), entryAt(&made[0], "wght"));
        try testing.expectEqual(@as(u8, 1), made[0].axis_count);
        try testing.expectEqual(@as(?f32, 900), entryAt(&made[1], "wght"));
        try testing.expectEqual(@as(?f32, 350), entryAt(&made[2], "wght"));
        try testing.expectEqual(@as(?f32, -12), entryAt(&made[2], "slnt"));
        try testing.expectEqual(@as(?f32, 900), entryAt(&made[3], "wght"));
        try testing.expectEqual(@as(?f32, -12), entryAt(&made[3], "slnt"));
    }
    // An instance away from the default on more axes than an entry
    // holds is no place; one more axis than that at its default is.
    {
        const letters = [_]*const [4]u8{ "AAAA", "BBBB", "CCCC", "DDDD", "EEEE", "FFFF", "GGGG", "HHHH", "IIII" };
        var axes: [letters.len]sdk.truetype.Axis = undefined;
        var values: [letters.len]sdk.truetype.AxisValue = undefined;
        inline for (letters, 0..) |tag, index| {
            axes[index] = axisAt(tag, 0, 0, 10);
            values[index] = .{ .tag = sdk.truetype.tableTag(tag), .value = 5 };
        }
        try testing.expectEqual(@as(?fontfile.Place, null), fontfile.placeOf(&axes, &values));
        values[letters.len - 1].value = 0;
        const place = fontfile.placeOf(&axes, &values).?;
        try testing.expectEqual(@as(u8, fontfile.MAXFONTAXES), place.count);
    }
}

test "revision 13: a variable font is listed a style, each a place of the one file, opened and drawn by the style asked" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    try testing.expect(rig.dfb.lib().revision >= 13);
    const builder = @import("../../truetype/tests/builder.zig");
    const variation = @import("../../truetype/tests/variation.zig");
    const truetype_init = @import("../../truetype/truetype_init.zig");
    const lib = kexec.InitResident(kexec.SysBase, &truetype_init.truetype_library_tag, null) orelse return error.NoTrueType;
    const truetype_lib: *exec.Library = @ptrCast(@alignCast(lib));
    defer _ = rig.sysLib().RemLibrary(truetype_lib);
    const dfb = rig.dfb;
    const gb = rig.graphicsLib();
    const tb: *sdk.interface.truetype.TrueTypeBase = @ptrCast(rig.sysLib().OpenLibrary(sdk.truetype.TRUETYPENAME, 1).?);
    defer rig.sysLib().CloseLibrary(tb.lib());

    // Weight from its lightest, which is the default, and a slant. The
    // file names a regular and two bolds; nothing italic.
    const english = 0x0409;
    var file: builder.File = .{};
    variation.namedFont(&file, &.{
        .{ .tag = "wght", .least = 100, .middle = 100, .most = 900, .name = 256 },
        .{ .tag = "slnt", .least = -12, .middle = 0, .most = 0, .name = 257 },
    }, &.{
        .{ .name = 258, .values = &.{ 300, 0 } },
        .{ .name = 259, .values = &.{ 400, 0 } },
        .{ .name = 260, .values = &.{ 900, 0 } },
        .{ .name = 261, .values = &.{ 800, 0 } },
    }, &.{
        .{ .platform = 3, .encoding = 1, .language = english, .id = 258, .stored = builder.utf16("Light") },
        .{ .platform = 3, .encoding = 1, .language = english, .id = 259, .stored = builder.utf16("Regular") },
        .{ .platform = 3, .encoding = 1, .language = english, .id = 260, .stored = builder.utf16("Bold") },
        .{ .platform = 3, .encoding = 1, .language = english, .id = 261, .stored = builder.utf16("bold") },
    });
    try writeOutlineFile(&rig, "vary", file.written());

    // Four entries of the one file: the styles the file names at their
    // instances - the first of a name - and the italic ones by the
    // slant's far end.
    const weight = std.mem.readInt(u32, "wght", .big);
    const slant = std.mem.readInt(u32, "slnt", .big);
    const fonts = rig.dosLib().Lock("FONTS:", dos.SHARED_LOCK).?;
    const listed = dfb.NewFontContents(fonts, "vary.font") orelse return error.NoContents;
    rig.dosLib().UnLock(fonts);
    {
        defer dfb.DisposeFontContents(listed);
        const entries = fontfile.entriesOf(@ptrCast(listed));
        try testing.expectEqual(@as(usize, 4), entries.len);
        const weights = [4]f32{ 400, 900, 400, 900 };
        for (entries, 0..) |*entry, style| {
            try testing.expectEqualStrings("vary/vary.ttf", std.mem.sliceTo(&entry.path, 0));
            try testing.expectEqual(@as(u8, 1), entry.outline);
            try testing.expectEqual(@as(u16, 0), entry.y_size);
            try testing.expectEqual(@as(graphics.FontStyle, @intCast(style)), entry.style);
            const italic = style & graphics.FSF_ITALIC != 0;
            try testing.expectEqual(@as(u8, if (italic) 2 else 1), entry.axis_count);
            try testing.expectEqual(weight, entry.axes[0].tag);
            try testing.expectEqual(weights[style], entry.axes[0].value);
            if (italic) {
                try testing.expectEqual(slant, entry.axes[1].tag);
                try testing.expectEqual(@as(f32, -12), entry.axes[1].value);
            }
        }
    }

    // A size: the bold one is drawn from the bold place - its 'A' is
    // wider, as the glyph grows with the weight - and says it is bold,
    // so graphics does not thicken it again. Each holds its outline.
    // (24 rows: the rig's memory is short of two taller ones.)
    const regular = dfb.OpenDiskFont(&.{ .name = "vary.font", .y_size = 24, .flags = graphics.FPF_DESIGNED }) orelse return error.NoFont;
    const heavy = dfb.OpenDiskFont(&.{ .name = "vary.font", .y_size = 24, .style = graphics.FSF_BOLD, .flags = graphics.FPF_DESIGNED }) orelse return error.NoFont;
    try testing.expect(regular != heavy);
    try testing.expectEqual(graphics.FS_NORMAL, regular.image.style & fontfile.listed_styles);
    try testing.expectEqual(graphics.FSF_BOLD, heavy.image.style & fontfile.listed_styles);
    try testing.expect(fontimage.sound(@ptrCast(heavy.image), heavy.image.size));
    try testing.expect(fontimage.find(heavy.image, 'A').?.width > fontimage.find(regular.image, 'A').?.width);
    try testing.expect(try lengthIn(&rig, heavy, "A") > try lengthIn(&rig, regular, "A"));
    try testing.expectEqual(@as(usize, 2), outlinesLoaded(&rig));

    // Each style asked is an outline of its own, at its place - the one
    // its size holds - and asked again it is the same one.
    var axes: [2]sdk.truetype.Axis = undefined;
    const plain = dfb.OpenOutlineFont("vary.font", graphics.FS_NORMAL) orelse return error.NoOutline;
    try testing.expectEqual(graphics.FS_NORMAL, plain.style);
    try testing.expectEqual(@as(u32, 2), tb.FontAxes(plain.outline, &axes, 2));
    try testing.expectEqual(@as(f32, 400), axes[0].value);
    try testing.expectEqual(@as(f32, 0), axes[1].value);
    const bold = dfb.OpenOutlineFont("vary.font", graphics.FSF_BOLD) orelse return error.NoOutline;
    try testing.expect(bold != plain);
    try testing.expectEqual(graphics.FSF_BOLD, bold.style);
    try testing.expectEqual(@as(u32, 2), tb.FontAxes(bold.outline, &axes, 2));
    try testing.expectEqual(@as(f32, 900), axes[0].value);
    const both = dfb.OpenOutlineFont("FONTS:vary.font", graphics.FSF_BOLD | graphics.FSF_ITALIC | graphics.FSF_UNDERLINED) orelse return error.NoOutline;
    try testing.expectEqual(graphics.FSF_BOLD | graphics.FSF_ITALIC, both.style);
    try testing.expectEqual(@as(u32, 2), tb.FontAxes(both.outline, &axes, 2));
    try testing.expectEqual(@as(f32, 900), axes[0].value);
    try testing.expectEqual(@as(f32, -12), axes[1].value);
    try testing.expectEqual(bold, dfb.OpenOutlineFont("VARY.font", graphics.FSF_BOLD).?);
    dfb.CloseOutlineFont(bold);
    try testing.expectEqual(@as(usize, 3), outlinesLoaded(&rig));
    gb.CloseFont(heavy);
    gb.CloseFont(regular);

    // Short of memory, what nobody holds goes; the file's bytes stay
    // for the outline still open, and go with it.
    dfb.CloseOutlineFont(both);
    dfb.CloseOutlineFont(bold);
    try testing.expect(rig.sysLib().AllocMem(1 << 30, exec.MEMF_ANY) == null);
    try testing.expectEqual(@as(usize, 1), outlinesLoaded(&rig));
    try testing.expectEqual(@as(u32, 1), tb.GlyphIndex(plain.outline, 'A'));
    try testing.expectEqual(@as(u32, 2), tb.FontAxes(plain.outline, &axes, 2));
    try testing.expectEqual(@as(f32, 400), axes[0].value);
    dfb.CloseOutlineFont(plain);
}

/// A collection of the TrueType files `fonts` in `into`, each whole
/// after the header, its tables' places counted from the collection's
/// start. How long it is.
fn collectionOf(into: []u8, fonts: []const []const u8) usize {
    @memset(into, 0);
    @memcpy(into[0..4], "ttcf");
    std.mem.writeInt(u32, into[4..8], 0x0001_0000, .big);
    std.mem.writeInt(u32, into[8..12], @intCast(fonts.len), .big);
    var len: usize = 12 + fonts.len * 4;
    for (fonts, 0..) |font, index| {
        std.mem.writeInt(u32, into[12 + index * 4 ..][0..4], @intCast(len), .big);
        @memcpy(into[len..][0..font.len], font);
        const tables = std.mem.readInt(u16, font[4..6], .big);
        for (0..tables) |table| {
            const place = into[len + 12 + table * 16 + 8 ..][0..4];
            std.mem.writeInt(u32, place, std.mem.readInt(u32, place, .big) + @as(u32, @intCast(len)), .big);
        }
        len += (font.len + 3) & ~@as(usize, 3);
    }
    return len;
}

test "revision 14: a contents entry names a font of a collection, and the collection's families read the one file" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    try testing.expect(rig.dfb.lib().revision >= 14);
    const tt = @import("../../truetype/tests/truetype.zig");
    const truetype_init = @import("../../truetype/truetype_init.zig");
    const lib = kexec.InitResident(kexec.SysBase, &truetype_init.truetype_library_tag, null) orelse return error.NoTrueType;
    const truetype_lib: *exec.Library = @ptrCast(@alignCast(lib));
    defer _ = rig.sysLib().RemLibrary(truetype_lib);
    const dfb = rig.dfb;
    const gb = rig.graphicsLib();

    // Two fonts in one file: the first has 'A' to 'C', the second, which
    // says it is bold, 'a' to 'c'.
    var first: tt.Out = .{};
    tt.buildFaceAt(&first, 0, 'A');
    var second: tt.Out = .{};
    tt.buildFaceAt(&second, 1, 'a');
    var file: [8192]u8 = undefined;
    const len = collectionOf(&file, &.{ first.bytes[0..first.len], second.bytes[0..second.len] });
    try testing.expectEqual(@as(u32, 2), sdk.truetype.fontCount(file[0..len]));
    try testing.expectEqual(graphics.FS_NORMAL, sdk.truetype.styleOfFont(file[0..len], 0));
    try testing.expectEqual(graphics.FSF_BOLD, sdk.truetype.styleOfFont(file[0..len], 1));
    try testing.expectEqual(graphics.FS_NORMAL, sdk.truetype.styleOfFont(file[0..len], 2));

    // The family whose directory holds the file is its first font.
    const made = rig.dosLib().CreateDir("FONTS:first") orelse return error.NoDir;
    rig.dosLib().UnLock(made);
    try rig.write("FONTS:first/all.ttc", file[0..len]);
    const fonts = rig.dosLib().Lock("FONTS:", dos.SHARED_LOCK).?;
    const listed = dfb.NewFontContents(fonts, "first.font") orelse return error.NoContents;
    rig.dosLib().UnLock(fonts);
    {
        defer dfb.DisposeFontContents(listed);
        const entries = fontfile.entriesOf(@ptrCast(listed));
        try testing.expectEqual(@as(usize, 1), entries.len);
        try testing.expectEqualStrings("first/all.ttc", std.mem.sliceTo(&entries[0].path, 0));
        try testing.expectEqual(@as(u8, 1), entries[0].outline);
        try testing.expectEqual(@as(u8, 0), entries[0].face);
        try testing.expectEqual(graphics.FS_NORMAL, entries[0].style);
        const block: [*]const u8 = @ptrCast(listed);
        try rig.write("FONTS:first.font", block[0..fontfile.contentsSize(1)]);
    }

    // The second font is a family with a contents file and no directory:
    // its entry names the file where it is, and which font of it.
    var contents: [fontfile.contentsSize(1)]u8 align(4) = @splat(0);
    const header: *fontfile.ContentsHeader = @ptrCast(&contents);
    header.* = .{ .count = 1 };
    const entry: *fontfile.FontContents = @ptrCast(@alignCast(contents[@sizeOf(fontfile.ContentsHeader)..]));
    entry.* = fontfile.outlineEntry("first/all.ttc", graphics.FSF_BOLD, .{}, 1);
    fontfile.seal(&contents, contents.len);
    try testing.expect(fontfile.sound(&contents, contents.len));
    try rig.write("FONTS:second.font", &contents);

    // Each family draws its own font's characters and not the other's.
    const upper = dfb.OpenDiskFont(&.{ .name = "first.font", .y_size = 20, .flags = graphics.FPF_DESIGNED }) orelse return error.NoFont;
    const lower = dfb.OpenDiskFont(&.{ .name = "second.font", .y_size = 20, .flags = graphics.FPF_DESIGNED }) orelse return error.NoFont;
    try testing.expectEqual(graphics.FS_NORMAL, upper.image.style & graphics.FSF_BOLD);
    try testing.expectEqual(graphics.FSF_BOLD, lower.image.style & graphics.FSF_BOLD);
    const ink = try inkIn(&rig, upper, "A");
    try testing.expect(ink != 0);
    try testing.expectEqual(ink, try inkIn(&rig, lower, "a"));
    try testing.expectEqual(ink, try inkIn(&rig, upper, "Aa"));
    try testing.expectEqual(ink, try inkIn(&rig, lower, "aA"));

    // Two outlines, one copy of the file.
    try testing.expectEqual(@as(usize, 2), outlinesLoaded(&rig));
    const real: *_base.DiskfontBase = @ptrCast(@alignCast(dfb));
    const one: *const _outline.OutlineRecord = @fieldParentPtr("link", real.outlines.first().?);
    const other: *const _outline.OutlineRecord = @fieldParentPtr("link", real.outlines.first().?.next().?);
    try testing.expect(one.file != null);
    try testing.expectEqual(one.file, other.file);
    try testing.expect(one.entry.face != other.entry.face);

    // The first to go leaves the file to the other, which still draws.
    gb.CloseFont(upper);
    try testing.expect(rig.sysLib().AllocMem(1 << 30, exec.MEMF_ANY) == null);
    try testing.expectEqual(ink, try inkIn(&rig, lower, "a"));
    gb.CloseFont(lower);
    // The expunge at the end frees the rest; the leak check says whether
    // the file went once.
}

/// How far `text` moves the cursor in `font`.
fn lengthIn(rig: *Rig, font: *graphics.TextFont, text: []const u8) !i32 {
    var pixels: [16 * 16 * 2]u8 = @splat(0);
    var surface = sdk.rtg.Surface{
        .pixels = &pixels,
        .width = 16,
        .height = 16,
        .pitch = 32,
        .size_bytes = pixels.len,
        .format = .rgb565,
    };
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) },
        .{},
    };
    const rp = rig.graphicsLib().CreateRastPortTagList(&tags) orelse return error.NoRastPort;
    defer rig.graphicsLib().FreeRastPort(rp);
    return rig.graphicsLib().TextLength(rp, text.ptr, @intCast(text.len));
}

fn nameOf(font: *const graphics.TextFont) []const u8 {
    return std.mem.span(font.node.name.?);
}

test "fallback fonts: the families font.prefs names, attached at the font's height in the list's order" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    try rig.writeFallbackFamilies();
    try rig.writePrefs("DEFAULT=test.font/16 FALLBACK=more.font,last.font\n");
    const dfb = rig.dfb;
    const gb = rig.graphicsLib();

    // 16 rows: each family has that size, and the one before it in the
    // list falls back to it.
    const sixteen = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 16 }) orelse return error.NoFont;
    const more = sixteen.fallback orelse return error.NoFallback;
    try testing.expectEqualStrings("more.font", nameOf(more));
    try testing.expectEqual(@as(u16, 16), more.image.height);
    const last = more.fallback orelse return error.NoFallback;
    try testing.expectEqualStrings("last.font", nameOf(last));
    try testing.expectEqual(@as(u16, 16), last.image.height);
    try testing.expect(last.fallback == null);
    try testing.expectEqual(@as(usize, 3), fontsLoaded(&rig));
    // Nobody has the fallbacks open: the font that names them keeps them.
    try testing.expectEqual(@as(u32, 1), sixteen.open_count);
    try testing.expectEqual(@as(u32, 0), more.open_count);
    try testing.expectEqual(@as(u32, 0), last.open_count);
    // A is the font's own, B more's, C last's, and D nobody's: the
    // font's own default.
    try testing.expectEqual(@as(i32, 8 + 9 + 11 + 8), try lengthIn(&rig, sixteen, "ABCD"));

    // A family of the list opened by its name is the font already made,
    // and falls back to the families after it only.
    const by_name = dfb.OpenDiskFont(&.{ .name = "more.font", .y_size = 16 }).?;
    try testing.expectEqual(@as(*const graphics.TextFont, by_name), more);
    try testing.expectEqual(@as(i32, 9 + 9 + 11), try lengthIn(&rig, by_name, "ABC"));
    gb.CloseFont(by_name);

    // 8 rows: the last family has no such size and is scaled to it, so
    // every font of the chain is as tall as the line.
    const eight = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 8 }).?;
    const more_eight = eight.fallback orelse return error.NoFallback;
    try testing.expectEqualStrings("more.font", nameOf(more_eight));
    try testing.expectEqual(@as(u16, 8), more_eight.image.height);
    const last_eight = more_eight.fallback orelse return error.NoFallback;
    try testing.expectEqualStrings("last.font", nameOf(last_eight));
    try testing.expectEqual(@as(u16, 8), last_eight.image.height);
    try testing.expectEqual(@as(u8, 0), last_eight.image.flags & graphics.FPF_DESIGNED);
    try testing.expect(last_eight.fallback == null);
    try testing.expectEqual(@as(usize, 6), fontsLoaded(&rig));
    const scaled_c: i32 = fontimage.find(last_eight.image, 'C').?.advance;
    try testing.expectEqual(@as(i32, 4 + 5) + scaled_c, try lengthIn(&rig, eight, "ABC"));

    // Memory short: the 8 rows nobody holds go, the font first and then
    // what it fell back to; the fallbacks of the font still open stay,
    // open counts of 0 and all.
    gb.CloseFont(eight);
    try testing.expect(rig.sysLib().AllocMem(1 << 30, exec.MEMF_ANY) == null);
    try testing.expectEqual(@as(usize, 3), fontsLoaded(&rig));
    try testing.expectEqual(more, sixteen.fallback.?);
    try testing.expectEqual(last, more.fallback.?);
    try testing.expectEqual(@as(i32, 8 + 9 + 11), try lengthIn(&rig, sixteen, "ABC"));
    // Closed, the whole chain is free to go.
    gb.CloseFont(sixteen);
    try testing.expect(rig.sysLib().AllocMem(1 << 30, exec.MEMF_ANY) == null);
    try testing.expectEqual(@as(usize, 0), fontsLoaded(&rig));
}

test "fallback fonts: the list read at each opening; a font in memory keeps its chain; what cannot be kept is passed over" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    try rig.writeFallbackFamilies();
    const dfb = rig.dfb;
    const gb = rig.graphicsLib();
    const sys = rig.sysLib();

    // No font.prefs: no font falls back.
    const eight = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 8 }).?;
    try testing.expect(eight.fallback == null);
    // A line without the key: the same.
    try rig.writePrefs("DEFAULT=test.font/8\n");
    const twelve = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 12 }).?;
    try testing.expect(twelve.fallback == null);

    // The list written: a font made from now on has it, a family there
    // is not passed over, and the two in memory stay as they were made.
    try rig.writePrefs("FIXED=test.font/8 FALLBACK=none.font,more.font,last.font\n");
    const sixteen = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 16 }).?;
    const more = sixteen.fallback orelse return error.NoFallback;
    try testing.expectEqualStrings("more.font", nameOf(more));
    try testing.expectEqualStrings("last.font", nameOf(more.fallback.?));
    try testing.expectEqual(eight, dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 8 }).?);
    gb.CloseFont(eight);
    try testing.expect(eight.fallback == null);
    try testing.expect(twelve.fallback == null);
    for ([_]*graphics.TextFont{ eight, twelve, sixteen }) |font| gb.CloseFont(font);
    try testing.expect(sys.AllocMem(1 << 30, exec.MEMF_ANY) == null);
    try testing.expectEqual(@as(usize, 0), fontsLoaded(&rig));

    // A font a program added under a listed family's name is not the
    // library's to keep: passed over, and the family after it attached.
    var theirs = graphics.TextFont{ .node = .{ .name = "more.font" }, .image = @ptrCast(&more8) };
    try testing.expect(gb.AddFont(&theirs));
    try rig.writePrefs("FALLBACK=more.font,last.font\n");
    const beside = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 8 }).?;
    const after = beside.fallback orelse return error.NoFallback;
    try testing.expectEqualStrings("last.font", nameOf(after));
    try testing.expectEqual(@as(u16, 8), after.image.height);
    try testing.expect(after.fallback == null);
    try testing.expectEqual(@as(u32, 0), theirs.open_count);
    gb.CloseFont(beside);
    try testing.expect(gb.RemFont(&theirs));
    try testing.expect(sys.AllocMem(1 << 30, exec.MEMF_ANY) == null);
    try testing.expectEqual(@as(usize, 0), fontsLoaded(&rig));

    // The test family in the list: each family is given those after it,
    // so no font comes back to itself.
    try rig.writePrefs("FALLBACK=last.font,test.font,more.font\n");
    const first = dfb.OpenDiskFont(&.{ .name = "last.font", .y_size = 16 }).?;
    const second = first.fallback orelse return error.NoFallback;
    try testing.expectEqualStrings("test.font", nameOf(second));
    const third = second.fallback orelse return error.NoFallback;
    try testing.expectEqualStrings("more.font", nameOf(third));
    try testing.expect(third.fallback == null);
    try testing.expectEqual(@as(i32, 8 + 9 + 11), try lengthIn(&rig, first, "ABC"));
    gb.CloseFont(first);
    try testing.expect(sys.AllocMem(1 << 30, exec.MEMF_ANY) == null);
    try testing.expectEqual(@as(usize, 0), fontsLoaded(&rig));

    // A font of the ROM's at the height is attached as it is, and the
    // chain ends with it; at another height it is scaled like any other,
    // and goes on to the family after it.
    try rig.writePrefs("FALLBACK=more.font," ++ graphics.POSPAZNAME ++ ",last.font\n");
    const with_rom = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 16 }).?;
    const before_rom = with_rom.fallback orelse return error.NoFallback;
    try testing.expectEqualStrings("more.font", nameOf(before_rom));
    const rom = before_rom.fallback orelse return error.NoFallback;
    try testing.expectEqualStrings(graphics.POSPAZNAME, nameOf(rom));
    try testing.expect(rom.flags & graphics.FPF_ROMFONT != 0);
    try testing.expect(rom.fallback == null);
    // a is the ROM font's, and C, which only the family after it has,
    // is the test font's default.
    const rom_a: i32 = fontimage.find(rom.image, 'a').?.advance;
    try testing.expectEqual(@as(i32, 8 + 9) + rom_a + 8, try lengthIn(&rig, with_rom, "ABaC"));
    const scaled = dfb.OpenDiskFont(&.{ .name = "test.font", .y_size = 12 }).?;
    const scaled_rom = scaled.fallback.?.fallback orelse return error.NoFallback;
    try testing.expectEqualStrings(graphics.POSPAZNAME, nameOf(scaled_rom));
    try testing.expectEqual(@as(u16, 12), scaled_rom.image.height);
    try testing.expectEqual(@as(u8, 0), scaled_rom.flags & graphics.FPF_ROMFONT);
    try testing.expectEqualStrings("last.font", nameOf(scaled_rom.fallback.?));
    gb.CloseFont(with_rom);
    gb.CloseFont(scaled);
}

/// How many pixels `text` lights, drawn in `font` near the left edge of
/// a surface 48 by 32.
fn inkIn(rig: *Rig, font: *graphics.TextFont, text: []const u8) !u32 {
    var pixels: [48 * 32 * 2]u8 = @splat(0);
    var surface = sdk.rtg.Surface{
        .pixels = &pixels,
        .width = 48,
        .height = 32,
        .pitch = 96,
        .size_bytes = pixels.len,
        .format = .rgb565,
    };
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) },
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) },
        .{},
    };
    const gb = rig.graphicsLib();
    const rp = gb.CreateRastPortTagList(&tags) orelse return error.NoRastPort;
    defer gb.FreeRastPort(rp);
    gb.Move(rp, 2, font.image.baseline);
    gb.Text(rp, text.ptr, @intCast(text.len));
    var lit: u32 = 0;
    var at: usize = 0;
    while (at < pixels.len) : (at += 2) {
        if (pixels[at] != 0 or pixels[at + 1] != 0) lit += 1;
    }
    return lit;
}

test "revision 9: a size made from an outline renders a character past its image when it is first drawn, and holds the outline" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    try testing.expect(rig.dfb.lib().revision >= 9);
    const truetype_init = @import("../../truetype/truetype_init.zig");
    const lib = kexec.InitResident(kexec.SysBase, &truetype_init.truetype_library_tag, null) orelse return error.NoTrueType;
    const truetype_lib: *exec.Library = @ptrCast(@alignCast(lib));
    defer _ = rig.sysLib().RemLibrary(truetype_lib);
    // Arrows are no part of what a size is rendered with: U+2190 the
    // square, U+2191 the curved one, U+2192 the square moved right.
    try writeOutlineFamilyAt(&rig, "arrows", 0, 0x2190);
    try writeOutlineFamily(&rig, "tt", 0);
    const dfb = rig.dfb;
    const gb = rig.graphicsLib();
    const left = "\xE2\x86\x90";
    const down = "\xE2\x86\x93";

    const font = dfb.OpenDiskFont(&.{ .name = "arrows.font", .y_size = 20, .flags = graphics.FPF_DESIGNED }) orelse return error.NoFont;
    try testing.expectEqual(@as(u16, 20), font.image.height);
    try testing.expect(fontimage.find(font.image, 0x2190) == null);
    try testing.expect(font.render != null);
    // Its outline has a `kern` table, but there is no library to shape
    // by it: a glyph for each character.
    try testing.expect(font.shape == null);
    try testing.expectEqual(@as(usize, 1), outlinesLoaded(&rig));

    // Measured and drawn all the same: the square, 10 by 14, 12 on. A
    // character the outline lacks is the font's missing glyph, which has
    // no ink.
    try testing.expectEqual(@as(i32, 12), try lengthIn(&rig, font, left));
    try testing.expectEqual(@as(u32, 140), try inkIn(&rig, font, left));
    try testing.expectEqual(@as(i32, 24), try lengthIn(&rig, font, left ++ "\xE2\x86\x92"));
    try testing.expectEqual(@as(u32, 0), try inkIn(&rig, font, down));

    // The hook as graphics asks it for a glyph by its number: one the
    // outline has, one it does not, and one for which there is no room.
    const hook = font.render.?;
    var bytes: [256]u8 = undefined;
    var request = graphics.GlyphRequest{ .which = 3, .flags = graphics.GLYPHREQ_NUMBER, .pixels = &bytes, .room = bytes.len };
    try testing.expectEqual(graphics.GLYPH_OK, hook.entry.?(hook, font, &request));
    try testing.expectEqual(fontimage.Kind.alpha4, request.kind);
    try testing.expectEqual(@as(i16, 12), request.glyph.advance);
    try testing.expectEqual(@as(u16, 10), request.glyph.width);
    try testing.expectEqual(@as(u32, 5 * 14), request.size);
    request = .{ .which = 4, .flags = graphics.GLYPHREQ_NUMBER, .pixels = &bytes, .room = bytes.len };
    try testing.expectEqual(graphics.GLYPH_NONE, hook.entry.?(hook, font, &request));
    request = .{ .which = 1, .flags = graphics.GLYPHREQ_NUMBER, .pixels = &bytes, .room = 8 };
    try testing.expectEqual(graphics.GLYPH_ROOM, hook.entry.?(hook, font, &request));
    try testing.expectEqual(@as(u32, 5 * 14), request.size);
    request = .{ .which = 0x2193, .pixels = &bytes, .room = bytes.len };
    try testing.expectEqual(graphics.GLYPH_NONE, hook.entry.?(hook, font, &request));

    // A second size renders from the same outline; short of memory with
    // both open, the sizes stay, the outline with them, and the glyph
    // made is still the font's.
    const small = dfb.OpenDiskFont(&.{ .name = "arrows.font", .y_size = 10, .flags = graphics.FPF_DESIGNED }) orelse return error.NoFont;
    try testing.expectEqual(@as(usize, 1), outlinesLoaded(&rig));
    try testing.expectEqual(@as(i32, 6), try lengthIn(&rig, small, left));
    try testing.expect(rig.sysLib().AllocMem(1 << 30, exec.MEMF_ANY) == null);
    try testing.expectEqual(@as(usize, 2), fontsLoaded(&rig));
    try testing.expectEqual(@as(usize, 1), outlinesLoaded(&rig));
    try testing.expectEqual(@as(u32, 140), try inkIn(&rig, font, left));

    // One size closed: it goes, the outline stays for the other. Both
    // closed: the sizes go, and then the outline nobody holds.
    gb.CloseFont(small);
    try testing.expect(rig.sysLib().AllocMem(1 << 30, exec.MEMF_ANY) == null);
    try testing.expectEqual(@as(usize, 1), fontsLoaded(&rig));
    try testing.expectEqual(@as(usize, 1), outlinesLoaded(&rig));
    try testing.expectEqual(@as(u32, 140), try inkIn(&rig, font, left));
    gb.CloseFont(font);
    try testing.expect(rig.sysLib().AllocMem(1 << 30, exec.MEMF_ANY) == null);
    try testing.expectEqual(@as(usize, 0), fontsLoaded(&rig));
    try testing.expectEqual(@as(usize, 0), outlinesLoaded(&rig));

    // A fallback's hook is asked after the font's own: 'A' is the
    // font's, the arrow no glyph of its outline, and the fallback
    // renders it.
    try rig.writeFallbackFamilies();
    try rig.writePrefs("FALLBACK=arrows.font\n");
    const letters = dfb.OpenDiskFont(&.{ .name = "tt.font", .y_size = 20, .flags = graphics.FPF_DESIGNED }) orelse return error.NoFont;
    try testing.expectEqualStrings("arrows.font", nameOf(letters.fallback orelse return error.NoFallback));
    try testing.expectEqual(@as(usize, 2), outlinesLoaded(&rig));
    try testing.expectEqual(@as(i32, 24), try lengthIn(&rig, letters, "A" ++ left));
    try testing.expectEqual(@as(u32, 280), try inkIn(&rig, letters, "A" ++ left));
    try testing.expectEqual(@as(u32, 140), try inkIn(&rig, letters, "A" ++ down));
    gb.CloseFont(letters);
    // The expunge at the end frees the sizes, what they made and the
    // outlines; the leak check says whether all of it went.
}

test "revision 10: a size made from an outline with layout tables shapes its text; one without draws a glyph for each character" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    try testing.expect(rig.dfb.lib().revision >= 10);
    const truetype_init = @import("../../truetype/truetype_init.zig");
    const lib = kexec.InitResident(kexec.SysBase, &truetype_init.truetype_library_tag, null) orelse return error.NoTrueType;
    const truetype_lib: *exec.Library = @ptrCast(@alignCast(lib));
    defer _ = rig.sysLib().RemLibrary(truetype_lib);
    const shaping_init = @import("../../truetypeshaping/truetypeshaping_init.zig");
    const made = kexec.InitResident(kexec.SysBase, &shaping_init.truetypeshaping_library_tag, null) orelse return error.NoShaping;
    const shaping_lib: *exec.Library = @ptrCast(@alignCast(made));
    defer _ = rig.sysLib().RemLibrary(shaping_lib);
    const dfb = rig.dfb;
    const gb = rig.graphicsLib();

    // 1000 units are the size's rows. Every advance is 600; 'A' before
    // 'B' is 50 closer, 'B' before 'C' 20 further.
    try writeOutlineFamily(&rig, "tt", 0);
    const font = dfb.OpenDiskFont(&.{ .name = "tt.font", .y_size = 20, .flags = graphics.FPF_DESIGNED }) orelse return error.NoFont;
    try testing.expect(font.shape != null);
    // At 20 rows 600 units are 12 pixels, 550 are 11, and 620 still 12.
    try testing.expectEqual(@as(i32, 24), try lengthIn(&rig, font, "BA"));
    try testing.expectEqual(@as(i32, 23), try lengthIn(&rig, font, "AB"));
    try testing.expectEqual(@as(i32, 46), try lengthIn(&rig, font, "ABAB"));
    try testing.expectEqual(@as(i32, 24), try lengthIn(&rig, font, "BC"));
    // A character the outline lacks is the font's missing glyph, and the
    // letter before it shaped by itself.
    try testing.expectEqual(@as(i32, 12) + font.image.x_size, try lengthIn(&rig, font, "AZ"));

    // The places in the text are the kerned ones.
    var pixels: [16 * 16 * 2]u8 = @splat(0);
    var surface = sdk.rtg.Surface{ .pixels = &pixels, .width = 16, .height = 16, .pitch = 32, .size_bytes = pixels.len, .format = .rgb565 };
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) },
        .{},
    };
    const rp = gb.CreateRastPortTagList(&tags) orelse return error.NoRastPort;
    try testing.expectEqual(@as(i32, 11), gb.TextOffsetToX(rp, "ABA", 3, 1));
    try testing.expectEqual(@as(i32, 23), gb.TextOffsetToX(rp, "ABA", 3, 2));
    try testing.expectEqual(@as(u32, 1), gb.TextXToOffset(rp, "ABA", 3, 14));
    try testing.expectEqual(@as(u32, 2), gb.TextXToOffset(rp, "ABA", 3, 18));
    gb.FreeRastPort(rp);

    // The hook as graphics asks it: a glyph the shaping left as its
    // character's is named by the character, the one of a character the
    // outline lacks by number 0.
    const hook = font.shape.?;
    var glyphs: [8]graphics.PlacedGlyph = undefined;
    var request = graphics.ShapeRequest{ .text = "ABZ", .length = 3, .glyphs = &glyphs, .room = glyphs.len };
    try testing.expectEqual(graphics.SHAPE_OK, hook.entry.?(hook, font, &request));
    try testing.expectEqual(@as(u32, 3), request.count);
    try testing.expectEqual(graphics.PlacedGlyph{ .which = 'A', .cluster = 0, .advance = 11 }, glyphs[0]);
    try testing.expectEqual(graphics.PlacedGlyph{ .which = 'B', .cluster = 1, .advance = 12 }, glyphs[1]);
    try testing.expectEqual(graphics.PlacedGlyph{ .which = 0, .flags = graphics.GLYPHREQ_NUMBER, .cluster = 2, .advance = 12 }, glyphs[2]);
    request = .{ .text = "ABZ", .length = 3, .glyphs = &glyphs, .room = 1 };
    try testing.expectEqual(graphics.SHAPE_ROOM, hook.entry.?(hook, font, &request));
    try testing.expectEqual(@as(u32, 3), request.count);

    // Twice the rows: 550 units are 22 pixels, 620 are 25, and a glyph
    // the shaping left alone moves the point as far as its image says.
    const tall = dfb.OpenDiskFont(&.{ .name = "tt.font", .y_size = 40, .flags = graphics.FPF_DESIGNED }) orelse return error.NoFont;
    try testing.expectEqual(@as(i32, 46), try lengthIn(&rig, tall, "AB"));
    try testing.expectEqual(@as(i32, 49), try lengthIn(&rig, tall, "BC"));
    try testing.expectEqual(@as(i32, fontimage.find(tall.image, 'C').?.advance), try lengthIn(&rig, tall, "C"));
    gb.CloseFont(tall);
    gb.CloseFont(font);

    // An outline with no table to shape by: no hook, a glyph for each
    // character.
    const builder = @import("../../truetype/tests/builder.zig");
    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    cmap.run('A', &.{ 1, 2, 3 });
    var file: builder.File = .{};
    _ = builder.font(&file, .{ .cmap = cmap.written(), .glyphs = 4 });
    try writeOutlineFile(&rig, "plain", file.written());
    const plain = dfb.OpenDiskFont(&.{ .name = "plain.font", .y_size = 20, .flags = graphics.FPF_DESIGNED }) orelse return error.NoFont;
    try testing.expect(plain.render != null);
    try testing.expect(plain.shape == null);
    try testing.expectEqual(@as(i32, 24), try lengthIn(&rig, plain, "AB"));
    gb.CloseFont(plain);
    // The expunge at the end closes both libraries, whose RemLibrary
    // above then completes; the leak check says whether all of it went.
}
