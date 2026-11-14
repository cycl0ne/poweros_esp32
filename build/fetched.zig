// SPDX-License-Identifier: MPL-2.0
//! What the scripts in scripts/ fetched into toolchain/, and how it goes
//! on a disk: the fonts and their families, the emoji lists, the icons'
//! pictures, the firmware files, the certificates, the radio's vendor
//! libraries. Each is looked for, and left off with a line when it is
//! not there.

const std = @import("std");

/// `disk/` in the root of the tree: everything in it goes on the image
/// at the same place, directories and all. It is where a program built
/// somewhere else is dropped to have it on the disk - a file put in
/// `disk/c/` is on `C:` and runs by name - without the build having to
/// know anything about where it came from.
///
/// **A `.seg` suffix is taken off**, because that is the extension a
/// load file is built with and not the name a command is called by: the
/// tree's own programs go on the image as `c/list`, and `disk/c/dm.seg`
/// goes on as `c/dm` beside them.
///
/// An empty directory is made too, so a place for something can be kept
/// before there is anything to put in it. A name beginning with a dot is
/// left behind, so the tree can hold a `.gitkeep` without the disk
/// gaining one, and so is the `README.md` in the root of `disk/` that
/// says what the directory is for.
/// Where the radio's vendor libraries are, as an absolute path: the
/// directory -Dwifi names, or toolchain/espressif-wifi if
/// scripts/fetch-wifi.sh has filled it. Null without them: the build then
/// has everything but esp32s3wifi.device, and says so once.
/// A font family on the disk: what fontconv makes it from, how, and the
/// heights that come out.
const DiskFont = struct {
    name: []const u8,
    options: []const []const u8 = &.{},
    /// From toolchain/fonts.
    sources: []const []const u8,
    sizes: []const u32 = &.{},
    /// TrueType files among the sources, copied beside the sizes.
    outlines: []const []const u8 = &.{},
    /// On the 64-bit disks only: the ESP32s' flash has not the room.
    wide: bool = false,
    /// Which of the fetched fonts it is made from.
    set: FontSet = .base,
    /// The family whose directory holds this one's font file, for a
    /// font of a collection after the first: the family is a contents
    /// file alone, which names the file there.
    in: ?[]const u8 = null,
    /// In the 64-bit disks' trees and manifests - so in the release
    /// packages - and on the system disks, not in the disk image a
    /// machine starts from out of RAM, which has not the room (mkfs's
    /// `--system-file`).
    system: bool = false,
};

/// Where a font family's files go: a disk's ordinary list, or - under
/// `--system-file=` - its tree, manifest and system disk without the
/// image in RAM.
pub const FontPlace = struct {
    runs: []const *std.Build.Step.Run,
    prefix: []const u8,

    pub fn drawer(place: FontPlace, path: []const u8) void {
        for (place.runs) |run| run.addArg(run.step.owner.fmt("{s}{s}", .{ place.prefix, path }));
    }

    pub fn file(place: FontPlace, path: []const u8, from: std.Build.LazyPath) void {
        for (place.runs) |run| run.addPrefixedFileArg(run.step.owner.fmt("{s}{s}=", .{ place.prefix, path }), from);
    }
};

/// What scripts/fetch-fonts.sh fetches, as far as a tree may have one
/// part and not another: `base` is what every fetch brought, the others
/// came later and a tree fetched before them lacks them.
const FontSet = enum { base, liberation, devanagari, cjk, emoji };

/// Noto Sans CJK Regular as scripts/fetch-fonts.sh names it, in
/// `devanagari_dir`: one file of ten fonts.
pub const cjk_file = "NotoSansCJK-Regular.ttc";

/// The family of the collection's font `face`, which draws the
/// characters Japanese, Chinese and Korean share in one region's forms.
/// The first has the file in its directory; the others name it there.
fn cjkFamily(comptime name: []const u8, comptime face: []const u8) DiskFont {
    const first = "cjk-jp";
    const source: []const []const u8 = &.{devanagari_dir ++ "/" ++ cjk_file};
    if (comptime std.mem.eql(u8, name, first)) return .{ .name = name, .sources = source, .outlines = &.{cjk_file}, .wide = true, .set = .cjk, .system = true };
    return .{ .name = name, .options = &.{ "--face", face, "--in", first }, .sources = source, .wide = true, .set = .cjk, .in = first, .system = true };
}

/// Noto Color Emoji as scripts/fetch-fonts.sh names it, in
/// `devanagari_dir`.
pub const emoji_file = "NotoColorEmoji.ttf";

/// Where scripts/fetch-fonts.sh puts Noto Sans Devanagari, in
/// toolchain/fonts.
pub const devanagari_dir = "noto";

/// Where scripts/fetch-fonts.sh puts the Liberation fonts, in
/// toolchain/fonts.
pub const liberation_dir = "liberation-fonts-ttf-2.1.5";

/// A Liberation family and its faces: `name`, `name`-bold, -italic and
/// -bolditalic, from Liberation`file`-Regular.ttf and the rest.
fn liberationFamily(comptime name: []const u8, comptime file: []const u8) [4]DiskFont {
    var faces: [4]DiskFont = undefined;
    for (.{ "", "-bold", "-italic", "-bolditalic" }, .{ "Regular", "Bold", "Italic", "BoldItalic" }, 0..) |suffix, style, i| {
        const ttf = "Liberation" ++ file ++ "-" ++ style ++ ".ttf";
        faces[i] = .{ .name = name ++ suffix, .sources = &.{liberation_dir ++ "/" ++ ttf}, .outlines = &.{ttf}, .wide = true, .set = .liberation };
    }
    return faces;
}

/// FONTS: as the disk has it. Spleen at every size a panel wants; the
/// same at 16 rows smoothed from its 32-row drawing, whose coverage shows
/// how an alpha font looks on a panel; at 16 with a shadow, a colour font
/// drawn partly in the pen; the Go faces as outlines, at any size; and on
/// the 64-bit disks the Liberation fonts as outlines - sans, serif and
/// mono, each with its bold, italic and bold italic faces - which SVG's
/// text is drawn in, Noto Sans Devanagari, regular and bold, which
/// `font.prefs` names as the font a text falls back to for the script,
/// and - in the trees and on the system disks alone, the file being
/// 19.5 MB and the disk image in RAM 32 - Noto Sans CJK - Japanese, Chinese and
/// Korean - as five families of the one file, a region's forms each:
/// Japan's, Korea's, China's, Taiwan's and Hong Kong's - and Noto Color
/// Emoji, 10.7 MB of glyphs in their own colours, which `font.prefs`
/// names last among the fonts a text falls back to.
pub const disk_fonts = liberationFamily("sans", "Sans") ++ liberationFamily("serif", "Serif") ++ liberationFamily("mono", "Mono") ++ [_]DiskFont{
    .{
        .name = "spleen",
        .sources = &.{ "spleen-2.2.0/spleen-5x8.bdf", "spleen-2.2.0/spleen-6x12.bdf", "spleen-2.2.0/spleen-8x16.bdf", "spleen-2.2.0/spleen-12x24.bdf", "spleen-2.2.0/spleen-16x32.bdf" },
        .sizes = &.{ 8, 12, 16, 24, 32 },
    },
    .{ .name = "spleen-smooth", .options = &.{ "--alpha", "2" }, .sources = &.{"spleen-2.2.0/spleen-16x32.bdf"}, .sizes = &.{16} },
    .{ .name = "spleen-shadow", .options = &.{"--shadow"}, .sources = &.{"spleen-2.2.0/spleen-8x16.bdf"}, .sizes = &.{17} },
    .{ .name = "go", .sources = &.{"go/Go-Regular.ttf"}, .outlines = &.{"Go-Regular.ttf"} },
    .{ .name = "go-bold", .sources = &.{"go/Go-Bold.ttf"}, .outlines = &.{"Go-Bold.ttf"} },
    .{ .name = "go-italic", .sources = &.{"go/Go-Italic.ttf"}, .outlines = &.{"Go-Italic.ttf"} },
    .{ .name = "go-mono", .sources = &.{"go/Go-Mono.ttf"}, .outlines = &.{"Go-Mono.ttf"} },
    .{ .name = "go-mono-bold", .sources = &.{"go/Go-Mono-Bold.ttf"}, .outlines = &.{"Go-Mono-Bold.ttf"} },
    .{ .name = "devanagari", .sources = &.{devanagari_dir ++ "/NotoSansDevanagari-Regular.ttf"}, .outlines = &.{"NotoSansDevanagari-Regular.ttf"}, .wide = true, .set = .devanagari },
    .{ .name = "devanagari-bold", .sources = &.{devanagari_dir ++ "/NotoSansDevanagari-Bold.ttf"}, .outlines = &.{"NotoSansDevanagari-Bold.ttf"}, .wide = true, .set = .devanagari },
    cjkFamily("cjk-jp", "0"),
    cjkFamily("cjk-kr", "1"),
    cjkFamily("cjk-sc", "2"),
    cjkFamily("cjk-tc", "3"),
    cjkFamily("cjk-hk", "4"),
    .{ .name = "emoji", .sources = &.{devanagari_dir ++ "/" ++ emoji_file}, .outlines = &.{emoji_file}, .wide = true, .set = .emoji, .system = true },
};

/// Whether scripts/fetch-fonts.sh has fetched `sub` into the fonts' `dir`.
pub fn hasFontSources(b: *std.Build, dir: []const u8, sub: []const u8) bool {
    const io = b.graph.io;
    var found = std.Io.Dir.cwd().openDir(io, b.pathJoin(&.{ dir, sub }), .{}) catch return false;
    found.close(io);
    return true;
}

/// Whether scripts/fetch-fonts.sh has fetched the file `name` into the
/// fonts' `dir`.
pub fn hasFontFile(b: *std.Build, dir: []const u8, name: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, b.pathJoin(&.{ dir, name }), .{}) catch return false;
    return true;
}

/// Where scripts/fetch-fonts.sh put the fonts' sources, if it has.
pub fn fontsDir(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const path = b.pathFromRoot("toolchain/fonts");
    var dir = std.Io.Dir.cwd().openDir(io, b.pathJoin(&.{ path, "go" }), .{}) catch {
        std.log.info("no font sources (scripts/fetch-fonts.sh): the disk has no FONTS:", .{});
        return null;
    };
    dir.close(io);
    return path;
}

/// Where scripts/fetch-unicode.sh put the files of the Unicode Character
/// Database, if it has: those of the version the tables in the tree
/// are made from.
pub fn unicodeDir(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const path = b.pathFromRoot("toolchain/unicode/16.0.0");
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return null;
    dir.close(io);
    return path;
}

/// Where scripts/fetch-emoji.sh put the emoji list and the annotation
/// files, if it has.
pub fn emojiDir(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const path = b.pathFromRoot("toolchain/emoji/16.0");
    std.Io.Dir.cwd().access(io, b.pathJoin(&.{ path, "emoji-test.txt" }), .{}) catch {
        std.log.info("no emoji list and names (scripts/fetch-emoji.sh): the 64-bit packages and system disks have no LOCALE:Emoji", .{});
        return null;
    };
    return path;
}

/// A language the disk has, as the locale names it, and the annotation
/// files its emoji names are made from: its own last, after the one it
/// takes what it leaves out from.
const EmojiLanguage = struct {
    name: []const u8,
    codes: []const []const u8,
};

pub const emoji_languages = [_]EmojiLanguage{
    .{ .name = "dansk", .codes = &.{"da"} },
    .{ .name = "deutsch", .codes = &.{"de"} },
    .{ .name = "english", .codes = &.{"en"} },
    .{ .name = "espanol", .codes = &.{"es"} },
    .{ .name = "francais", .codes = &.{"fr"} },
    .{ .name = "hangugeo", .codes = &.{"ko"} },
    .{ .name = "hindi", .codes = &.{"hi"} },
    .{ .name = "italiano", .codes = &.{"it"} },
    .{ .name = "nederlands", .codes = &.{"nl"} },
    .{ .name = "nihongo", .codes = &.{"ja"} },
    .{ .name = "norsk", .codes = &.{"no"} },
    .{ .name = "portugues", .codes = &.{ "pt", "pt_PT" } },
    .{ .name = "svenska", .codes = &.{"sv"} },
    .{ .name = "zhongwen", .codes = &.{"zh"} },
    .{ .name = "zhongwen-fanti", .codes = &.{"zh_Hant"} },
};

/// Where scripts/fetch-icons.sh put the pictures drawn at `size`, if it
/// has.
pub fn iconsDir(b: *std.Build, size: u32) ?[]const u8 {
    const io = b.graph.io;
    const path = b.pathFromRoot(b.fmt("toolchain/icons/{d}", .{size}));
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch {
        std.log.info("no icon pictures (scripts/fetch-icons.sh): the disk has no icons of its own", .{});
        return null;
    };
    dir.close(io);
    return path;
}

/// The files scripts/fetch-aic8800.sh fetches.
pub const aic8800_files = [_][]const u8{
    "fmacfw.bin",         "fw_adid.bin",            "fw_adid_u03.bin", "fw_patch.bin", "fw_patch_u03.bin",
    "fw_patch_table.bin", "fw_patch_table_u03.bin",
};

pub const cyw43455_files = [_][]const u8{ "cyfmac43455-sdio.bin", "cyfmac43455-sdio.clm_blob", "brcmfmac43455-sdio.txt" };

/// Where scripts/fetch-cyw43455.sh put the CYW43455's firmware, or null
/// without it.
pub fn cyw43455Dir(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const path = b.pathFromRoot("toolchain/cyw43455");
    std.Io.Dir.cwd().access(io, b.pathJoin(&.{ path, "cyfmac43455-sdio.bin" }), .{}) catch {
        std.log.info("no CYW43455 firmware (scripts/fetch-cyw43455.sh): the disk has no DEVS:networks/firmware/cyw43455/", .{});
        return null;
    };
    return path;
}

/// Where scripts/fetch-aic8800.sh put the AIC8800's firmware, or null
/// without it.
pub fn aic8800Dir(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const path = b.pathFromRoot("toolchain/aic8800");
    std.Io.Dir.cwd().access(io, b.pathJoin(&.{ path, "fmacfw.bin" }), .{}) catch {
        std.log.info("no AIC8800 firmware (scripts/fetch-aic8800.sh): the disk has no DEVS:usb/firmware/aic8800/", .{});
        return null;
    };
    return path;
}

/// Where scripts/fetch-vpu.sh put the WAVE511's firmware, or null
/// without it.
pub fn vpuDir(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const path = b.pathFromRoot("toolchain/wave511");
    std.Io.Dir.cwd().access(io, b.pathJoin(&.{ path, "wave511_dec_fw.bin" }), .{}) catch {
        std.log.info("no WAVE511 firmware (scripts/fetch-vpu.sh): the RISC-V 64 disk has no DEVS:firmware/", .{});
        return null;
    };
    return path;
}

/// Where scripts/fetch-amdgpu.sh put an AMD graphics device's firmware,
/// or null without it.
pub fn amdgpuDir(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const path = b.pathFromRoot("toolchain/amdgpu");
    std.Io.Dir.cwd().access(io, b.pathJoin(&.{ path, "vcn_4_0_2.bin" }), .{}) catch {
        std.log.info("no AMD graphics firmware (scripts/fetch-amdgpu.sh): the x86-64 disk has no DEVS:firmware/amdgpu/", .{});
        return null;
    };
    return path;
}

/// The list scripts/fetch-pciids.sh fetched, or null without it.
pub fn pciIdsFile(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const path = b.pathFromRoot("toolchain/pciids/pci.ids");
    std.Io.Dir.cwd().access(io, path, .{}) catch {
        std.log.info("no PCI ID list (scripts/fetch-pciids.sh): the RISC-V and AArch64 disks have no DEVS:pci.ids", .{});
        return null;
    };
    return path;
}

/// The PEM bundle scripts/fetch-certs.sh fetched, or null without it.
pub fn certsFile(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const path = b.pathFromRoot("toolchain/certs/cacert-2026-09-25.pem");
    std.Io.Dir.cwd().access(io, path, .{}) catch {
        std.log.info("no root certificates (scripts/fetch-certs.sh): the disk has no SYS:Certificates/Roots", .{});
        return null;
    };
    return path;
}

pub fn wifiDir(b: *std.Build, given: ?[]const u8) ?[]const u8 {
    const io = b.graph.io;
    const path = given orelse b.pathFromRoot("toolchain/espressif-wifi");
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch {
        if (given != null) std.debug.panic("-Dwifi={s}: no such directory", .{path});
        std.log.info("no radio libraries (scripts/fetch-wifi.sh): the disk has no esp32s3wifi.device", .{});
        return null;
    };
    dir.close(io);
    return path;
}
