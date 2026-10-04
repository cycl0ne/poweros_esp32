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

/// The RAM disk behind FONTS:, answering the test process's packets.
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
        kexec.deinit();
    }

    /// A file on FONTS:.
    fn write(rig: *Rig, name: [*:0]const u8, bytes: []const u8) !void {
        const fh = rig.dosLib().Open(name, dos.MODE_NEWFILE) orelse return error.NoFile;
        try testing.expectEqual(@as(isize, @intCast(bytes.len)), rig.dosLib().Write(fh, bytes.ptr, @intCast(bytes.len)));
        try testing.expect(rig.dosLib().Close(fh));
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
