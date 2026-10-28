// SPDX-License-Identifier: MIT
//! Host tests of datatypes.library's recognising: what each descriptor
//! says about a reading of a file, and which of them wins.
//!
//! The file is not read here - the reading is made by hand - because
//! what is under test is the matching, and a file would only put dos
//! between the test and the thing it is testing. The reading itself is
//! exercised in QEMU by `C:test/DataTypes`.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const iffparse = sdk.iffparse;
const host = @import("host_rom");
const kexec = host.exec;
const _base = @import("../datatypes_base.zig");
const _type = @import("../type/_type.zig");
const DataTypesBase = _base.DataTypesBase;

const testing = std.testing;
const ID = iffparse.MakeID;

test {
    _ = @import("../datatypes_lvo.zig");
}

/// exec and utility.library up, and a base with what the matching uses.
const Rig = struct {
    base: DataTypesBase = undefined,
    ub: *host.utility.UtilityBase = undefined,

    fn up(rig: *Rig) !void {
        rig.ub = try host.utility.setUp();
        rig.base = .{
            .lib = .{},
            .sys_base = kexec.SysBase.iface(),
            .dos_base = undefined,
            .utility_base = @ptrCast(rig.ub),
            .intuition_base = undefined,
            .graphics_base = undefined,
            .iffparse_base = undefined,
        };
    }

    fn down(rig: *Rig) !void {
        try host.utility.tearDown(rig.ub);
        try kexec.expectNoLeaks();
    }
};

/// A reading of a file, made by hand.
fn reading(name: []const u8, bytes: []const u8, form_type: u32, is_dir: bool) _type.Source {
    var source = _type.Source{ .kind = dtc.DTST_FILE, .form_type = form_type };
    @memcpy(source.fib.file_name[0..name.len], name);
    source.fib.dir_entry_type = if (is_dir) 2 else -3;
    @memcpy(source.buffer[0..bytes.len], bytes);
    source.buffer_length = @intCast(bytes.len);
    return source;
}

/// A descriptor, made by hand.
const Kind = struct {
    header: datatypes.DataTypeHeader,
    dt: datatypes.DataType,

    fn of(header: datatypes.DataTypeHeader) Kind {
        return .{ .header = header, .dt = .{ .header = undefined } };
    }

    fn ptr(kind: *Kind) *datatypes.DataType {
        kind.dt.header = &kind.header;
        return &kind.dt;
    }
};

test "datatypes: an IFF form is known by its type, and nothing else matches it" {
    var rig = Rig{};
    try rig.up();
    const db = &rig.base;

    var ilbm = Kind.of(.{
        .name = "ILBM",
        .base_name = "ilbm",
        .group_id = datatypes.GID_PICTURE,
        .id = ID("ILBM"),
        .flags = datatypes.DTF_IFF,
    });
    var ftxt = Kind.of(.{
        .name = "FTXT",
        .base_name = "ftxt",
        .group_id = datatypes.GID_TEXT,
        .id = ID("FTXT"),
        .flags = datatypes.DTF_IFF,
    });

    var picture = reading("a.iff", "FORM\x00\x00\x00\x10ILBM", ID("ILBM"), false);
    try testing.expect(_type.matches(db, ilbm.ptr(), &picture));
    try testing.expect(!_type.matches(db, ftxt.ptr(), &picture));

    // Not IFF at all: neither of them.
    var plain = reading("a.txt", "Hello", 0, false);
    try testing.expect(!_type.matches(db, ilbm.ptr(), &plain));
    try testing.expect(!_type.matches(db, ftxt.ptr(), &plain));
    try rig.down();
}

test "datatypes: a mask matches the bytes the file starts with, wildcards and all" {
    var rig = Rig{};
    try rig.up();
    const db = &rig.base;

    const bytes = [_]u8{ 'B', 'M', 0, 0 };
    const any = [_]u8{ 0, 0, 1, 1 };
    var bmp = Kind.of(.{
        .name = "BMP",
        .base_name = "bmp",
        .group_id = datatypes.GID_PICTURE,
        .id = ID("BMP "),
        .flags = datatypes.DTF_BINARY,
        .mask = &bytes,
        .mask_any = &any,
        .mask_len = 4,
    });

    var windows = reading("a.bmp", "BM\x36\x04", 0, false);
    try testing.expect(_type.matches(db, bmp.ptr(), &windows));
    var other = reading("a.bmp", "MB\x36\x04", 0, false);
    try testing.expect(!_type.matches(db, bmp.ptr(), &other));
    // Shorter than the mask: nothing to compare, so no.
    var tiny = reading("a.bmp", "B", 0, false);
    try testing.expect(!_type.matches(db, bmp.ptr(), &tiny));
    try rig.down();
}

test "datatypes: a pattern matches the name, and a directory only a directory" {
    var rig = Rig{};
    try rig.up();
    const db = &rig.base;
    const ub = rig.ub.iface();

    var tokens: [64]u8 = @splat(0);
    try testing.expect(ub.ParsePatternNoCase("#?.md", &tokens, tokens.len) >= 0);
    var markdown = Kind.of(.{
        .name = "Markdown",
        .base_name = "markdown",
        .group_id = datatypes.GID_TEXT,
        .id = ID("MD  "),
        .flags = datatypes.DTF_ASCII,
        .pattern = @ptrCast(&tokens),
    });

    var readme = reading("README.MD", "# Title", 0, false);
    try testing.expect(_type.matches(db, markdown.ptr(), &readme));
    var other = reading("README", "# Title", 0, false);
    try testing.expect(!_type.matches(db, markdown.ptr(), &other));

    // A directory matches only a descriptor that says it is for one.
    var drawer = Kind.of(.{
        .name = "Directory",
        .base_name = "directory",
        .group_id = datatypes.GID_SYSTEM,
        .id = ID("DIR "),
        .flags = datatypes.DTF_BINARY | datatypes.DTF_DIRECTORY,
    });
    var dir = reading("Tests", "", 0, true);
    try testing.expect(_type.matches(db, drawer.ptr(), &dir));
    try testing.expect(!_type.matches(db, markdown.ptr(), &dir));
    var file = reading("Tests", "x", 0, false);
    try testing.expect(!_type.matches(db, drawer.ptr(), &file));
    try rig.down();
}

test "datatypes: what is left over is text if it reads as text, and bytes if not" {
    var rig = Rig{};
    try rig.up();
    const db = &rig.base;

    var ascii = Kind.of(.{
        .name = "ASCII",
        .base_name = "ascii",
        .group_id = datatypes.GID_TEXT,
        .id = ID("TEXT"),
        .flags = datatypes.DTF_ASCII,
    });
    var binary = Kind.of(.{
        .name = "Binary",
        .base_name = "binary",
        .group_id = datatypes.GID_SYSTEM,
        .id = ID("BINA"),
        .flags = datatypes.DTF_BINARY,
    });

    var script = reading("s", "Echo \"hello\"\nQuit\n", 0, false);
    try testing.expect(_type.matches(db, ascii.ptr(), &script));
    try testing.expect(_type.matches(db, binary.ptr(), &script));

    var program = reading("List", "\x00\x00\x03\xF3\x00\x00", 0, false);
    try testing.expect(!_type.matches(db, ascii.ptr(), &program));
    try testing.expect(_type.matches(db, binary.ptr(), &program));
    try rig.down();
}

test "datatypes: bytes in memory are known by what they start with, and by a name when they have one" {
    var rig = Rig{};
    try rig.up();
    const db = &rig.base;
    const ub = rig.ub.iface();

    var tokens: [64]u8 = @splat(0);
    try testing.expect(ub.ParsePatternNoCase("#?.(jpg|jpeg)", &tokens, tokens.len) >= 0);
    const start = [_]u8{ 0xFF, 0xD8, 0xFF };
    const any = [_]u8{ 0, 0, 0 };
    var jpeg = Kind.of(.{
        .name = "JPEG",
        .base_name = "jpeg",
        .group_id = datatypes.GID_PICTURE,
        .id = ID("JPEG"),
        .flags = datatypes.DTF_BINARY,
        .mask = &start,
        .mask_any = &any,
        .mask_len = 3,
        .pattern = @ptrCast(&tokens),
    });
    const picture = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 'J', 'F', 'I', 'F' };

    // No name: the bytes decide.
    var unnamed: _type.Source = undefined;
    try testing.expect(_type.open(db, &unnamed, dtc.DTST_MEMORY, @constCast(&picture), &[_]utility.TagItem{
        .{ .tag = dtc.DTA_SourceSize, .data = picture.len },
        .{},
    }));
    try testing.expectEqual(@as(u64, picture.len), unnamed.fib.size);
    try testing.expect(_type.matches(db, jpeg.ptr(), &unnamed));

    // A name is matched as a file's.
    var named: _type.Source = undefined;
    try testing.expect(_type.open(db, &named, dtc.DTST_MEMORY, @constCast(&picture), &[_]utility.TagItem{
        .{ .tag = dtc.DTA_SourceSize, .data = picture.len },
        .{ .tag = dtc.DTA_Name, .data = @intFromPtr("cover.jpg") },
        .{},
    }));
    try testing.expect(_type.matches(db, jpeg.ptr(), &named));
    var misnamed: _type.Source = undefined;
    try testing.expect(_type.open(db, &misnamed, dtc.DTST_MEMORY, @constCast(&picture), &[_]utility.TagItem{
        .{ .tag = dtc.DTA_SourceSize, .data = picture.len },
        .{ .tag = dtc.DTA_Name, .data = @intFromPtr("cover.png") },
        .{},
    }));
    try testing.expect(!_type.matches(db, jpeg.ptr(), &misnamed));

    // Other bytes are not a JPEG, and bytes without their size are not
    // a source at all.
    var other: _type.Source = undefined;
    try testing.expect(_type.open(db, &other, dtc.DTST_MEMORY, @constCast("GIF89a"), &[_]utility.TagItem{
        .{ .tag = dtc.DTA_SourceSize, .data = 6 },
        .{},
    }));
    try testing.expect(!_type.matches(db, jpeg.ptr(), &other));
    var sizeless: _type.Source = undefined;
    try testing.expect(!_type.open(db, &sizeless, dtc.DTST_MEMORY, @constCast(&picture), null));
    try rig.down();
}

test "datatypes: an IFF form in memory is known by its type" {
    var rig = Rig{};
    try rig.up();
    const db = &rig.base;

    var ilbm = Kind.of(.{
        .name = "ILBM",
        .base_name = "ilbm",
        .group_id = datatypes.GID_PICTURE,
        .id = ID("ILBM"),
        .flags = datatypes.DTF_IFF,
    });
    const form = "FORM\x00\x00\x00\x10ILBMBMHD";
    var source: _type.Source = undefined;
    try testing.expect(_type.open(db, &source, dtc.DTST_MEMORY, @constCast(form), &[_]utility.TagItem{
        .{ .tag = dtc.DTA_SourceSize, .data = form.len },
        .{},
    }));
    try testing.expectEqual(ID("ILBM"), source.form_type);
    try testing.expect(_type.matches(db, ilbm.ptr(), &source));
    try testing.expectEqual(@as(u32, 0), _type.formTypeOfBytes("FORM\x00\x00"));
    try testing.expectEqual(@as(u32, 0), _type.formTypeOfBytes("JUNK\x00\x00\x00\x10ILBM"));
    try rig.down();
}

test "datatypes: the class library's name from a base name" {
    var name: [64]u8 = @splat(0);
    try testing.expect(_type.className("ilbm", &name));
    try testing.expectEqualStrings("datatypes/ilbm.datatype", std.mem.span(@as([*:0]const u8, @ptrCast(&name))));
    // Too long to fit is refused rather than cut.
    var long: [56]u8 = @splat('x');
    long[55] = 0;
    try testing.expect(!_type.className(@ptrCast(&long), &name));
}
