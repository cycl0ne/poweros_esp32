// SPDX-License-Identifier: MPL-2.0
//! What goes on a disk image besides the programs: the drawers every
//! image has, the icons, the `disk/` tree, -Dextra and `games/`, the ROM
//! modules a flash board loads from its disk - and `DiskImages`, the runs
//! of mkfs that make every board's image from one recipe.

const std = @import("std");
const poweros_sdk = @import("poweros_sdk");
const poweros_userland = @import("poweros_userland");
const build_boards = @import("boards.zig");
const build_fetched = @import("fetched.zig");
const build_release = @import("release.zig");

const Board = build_boards.Board;
const Chip = build_boards.Chip;
const Sets = build_boards.Sets;
const boardSets = build_boards.boardSets;
const chipOf = build_boards.chipOf;
const disk_page = build_boards.disk_page;
const disk_sector = build_boards.disk_sector;
const flash_boards = build_boards.flash_boards;
const iconSize = build_boards.iconSize;
const ram_chips = build_boards.ram_chips;
const ram_disk_size = build_boards.ram_disk_size;
const virt_system_bytes = build_boards.virt_system_bytes;
const FontPlace = build_fetched.FontPlace;
const aic8800Dir = build_fetched.aic8800Dir;
const aic8800_files = build_fetched.aic8800_files;
const amdgpuDir = build_fetched.amdgpuDir;
const certsFile = build_fetched.certsFile;
const cjk_file = build_fetched.cjk_file;
const cyw43455Dir = build_fetched.cyw43455Dir;
const cyw43455_files = build_fetched.cyw43455_files;
const devanagari_dir = build_fetched.devanagari_dir;
const disk_fonts = build_fetched.disk_fonts;
const emojiDir = build_fetched.emojiDir;
const emoji_file = build_fetched.emoji_file;
const emoji_languages = build_fetched.emoji_languages;
const fontsDir = build_fetched.fontsDir;
const hasFontFile = build_fetched.hasFontFile;
const hasFontSources = build_fetched.hasFontSources;
const iconsDir = build_fetched.iconsDir;
const liberation_dir = build_fetched.liberation_dir;
const pciIdsFile = build_fetched.pciIdsFile;
const vpuDir = build_fetched.vpuDir;
const chipNames = build_release.chipNames;

/// Where a file that is not built here is put to have it on the disk
/// image: `disk/` in the root of the tree.
const disk_tree = "disk";

/// Where games built elsewhere are put to have them on the virt
/// machines' system disks with -Dgames: `games/` in the root of the tree,
/// which is the disks' `Games` drawer.
const games_tree = "games";
const games_drawer = "Games";
const games_drawer_icon: DiskIcon = .{ .path = games_drawer ++ ".info", .picture = "applications-games", .fields = &.{"KIND=DRAWER"} };

/// A ROM module that the boards with a flash load from their disk
/// instead: the file under src/rom/ it is built from, the name of its
/// load file, and its place on the disk. Its file is both - a ROM tag
/// where a kernel's list names it, a load file with that tag in it
/// here - and dos or ramlib finds it on the disk when something first
/// asks for it. The 64-bit machines' kernels keep these in their ROM.
const RomOnDisk = struct { root: []const u8, name: []const u8, disk: []const u8 };

/// What a flash board's ROM leaves to its disk: the pipe between two
/// commands, which `|` in a shell opens, and the clock of things that
/// move, which the first gadget that animates opens.
const rom_on_disk = [_]RomOnDisk{
    .{ .root = "src/rom/handler/pipe/pipe.zig", .name = "pipe-handler", .disk = "devs/handlers/pipe-handler" },
    .{ .root = "src/rom/libs/motion/motion.zig", .name = "motion.library", .disk = "libs/motion.library" },
};

/// The ROM modules' strings in other languages: what dos.library's faults
/// say once locale.library stands in front of Fault.
const rom_catalogs = [_]poweros_userland.Catalog{
    .{ .disk = "locale/Catalogs/deutsch/sys/dos.catalog", .descriptor = "src/rom/libs/dos/text/dos.cd", .translation = "src/rom/libs/dos/text/catalogs/deutsch.ct", .name = "sys/dos.catalog" },
    .{ .disk = "locale/Catalogs/hindi/sys/dos.catalog", .descriptor = "src/rom/libs/dos/text/dos.cd", .translation = "src/rom/libs/dos/text/catalogs/hindi.ct", .name = "sys/dos.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/nihongo/sys/dos.catalog", .descriptor = "src/rom/libs/dos/text/dos.cd", .translation = "src/rom/libs/dos/text/catalogs/nihongo.ct", .name = "sys/dos.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/hangugeo/sys/dos.catalog", .descriptor = "src/rom/libs/dos/text/dos.cd", .translation = "src/rom/libs/dos/text/catalogs/hangugeo.ct", .name = "sys/dos.catalog", .wide = true },
    .{ .disk = "locale/Catalogs/zhongwen/sys/dos.catalog", .descriptor = "src/rom/libs/dos/text/dos.cd", .translation = "src/rom/libs/dos/text/catalogs/zhongwen.ct", .name = "sys/dos.catalog", .wide = true },
};

/// The directories every disk image has, parents before what is in them.
const image_dirs = [_][]const u8{
    "c",
    // C:test - the programs that exercise a device or a library. The
    // startup-sequence puts it on the path, so they are still called by
    // name.
    "c/test",
    // C:net - the network's tools, on the path as well.
    "c/net",
    "s",
    "libs",
    // LIBS:facet - the drivers of GPUs facet.library draws with, beside the
    // cores.
    "libs/facet",
    // LIBS:codecs - the decoders of pictures videocodec.library chooses
    // among, a library each.
    "libs/codecs",
    // The classes, opened through LIBS: (the startup-sequence adds this
    // directory to it): gadgets/ for the gadget classes, datatypes/ for
    // the classes that read a file's contents, docklets/ for the dock's
    // docklets, which it lists from there, images/ for the pictures drawn
    // to any size.
    "classes",
    "classes/gadgets",
    "classes/datatypes",
    "classes/docklets",
    "classes/images",
    "devs",
    // The network drivers, opened as networks/<name>.device, and the
    // interfaces C:net/AddNetInterface brings up.
    "devs/networks",
    "devs/NetInterfaces",
    // The USB class drivers, opened as usb/<name>.device, whose ROM tags
    // usb.library reads to know what each drives.
    "devs/usb",
    // DEVS:DataTypes - one text descriptor per kind of file, which
    // C:AddDataTypes reads into datatypes.library's list.
    "devs/datatypes",
    // HANDLERS: - the handlers that are not in the ROM, loaded the first
    // time a device they serve is used. What a device is, for Mount to
    // read, is DEVS:MountList.
    "devs/handlers",
    // DEVS:Keymaps - the keymaps that are not in the ROM, a file each,
    // which keymap.library loads when one is asked for by name.
    "devs/keymaps",
    // SYS:Programs - programs with windows, off the command path, and
    // in Docs what each of them is.
    "programs",
    "programs/Docs",
    // SYS:WBStartup - the programs the desktop starts as it comes up,
    // empty until some are put there.
    "WBStartup",
    // SYS:System - the system's own tools: Shell, which the desktop's
    // own icons start, HDToolBox, CPULoad, NetLoad, MemMap and Clock; in
    // Docs what each of the others is.
    "System",
    "System/Docs",
    // SYS:Commodities - the programs that work on the input before the
    // windows see it, Exchange first, which lists and controls them; in
    // Docs what each is.
    "Commodities",
    "Commodities/Docs",
    // The volume's trash: a file put in it is renamed there, and Empty
    // Trash deletes what it holds.
    "Trashcan",
    // SYS:Tests - files to try the system on, a directory per subject.
    "tests",
    "tests/datatypes",
    // FONTS: - a contents file and a directory of sizes per family;
    // empty without scripts/fetch-fonts.sh.
    "fonts",
    // ENVARC: lives here: the global variables that survive a reboot.
    // Sys/ holds the system's settings, Sys/net/ the network's,
    // Sys/net/networks/ a Wi-Fi network's passphrase per file, and
    // Player/ the stations the Player keeps.
    "prefs",
    "prefs/env-archive",
    "prefs/env-archive/Sys",
    "prefs/env-archive/Sys/net",
    "prefs/env-archive/Sys/net/networks",
    "prefs/env-archive/Player",
    "prefs/presets",
    "prefs/presets/styles",
    // LOCALE: - the countries' formats, the languages' words and order,
    // and the programs' strings in each language, a catalog per program
    // at the program's own place (sys/ for the system's own modules).
    "locale",
    "locale/Countries",
    "locale/Languages",
    "locale/Catalogs",
    "locale/Catalogs/deutsch",
    "locale/Catalogs/deutsch/sys",
    "locale/Catalogs/deutsch/c",
    "locale/Catalogs/deutsch/c/test",
    "locale/Catalogs/deutsch/programs",
    "locale/Catalogs/deutsch/System",
    "locale/Catalogs/deutsch/Commodities",
    "locale/Catalogs/hindi",
    "locale/Catalogs/hindi/sys",
    "locale/Catalogs/hindi/c",
    "locale/Catalogs/hindi/c/test",
    "locale/Catalogs/hindi/programs",
    "locale/Catalogs/hindi/System",
    "locale/Catalogs/nihongo",
    "locale/Catalogs/nihongo/sys",
    "locale/Catalogs/nihongo/c",
    "locale/Catalogs/nihongo/c/test",
    "locale/Catalogs/nihongo/programs",
    "locale/Catalogs/nihongo/System",
    "locale/Catalogs/hangugeo",
    "locale/Catalogs/hangugeo/sys",
    "locale/Catalogs/hangugeo/c",
    "locale/Catalogs/hangugeo/c/test",
    "locale/Catalogs/hangugeo/programs",
    "locale/Catalogs/hangugeo/System",
    "locale/Catalogs/zhongwen",
    "locale/Catalogs/zhongwen/sys",
    "locale/Catalogs/zhongwen/c",
    "locale/Catalogs/zhongwen/c/test",
    "locale/Catalogs/zhongwen/programs",
    "locale/Catalogs/zhongwen/System",
};

/// An icon the build writes onto the image: where it goes, the picture
/// scripts/fetch-icons.sh drew for it, its fields as tools/mkicon takes
/// them, and - for an icon only some disks have - the pointer size of the
/// chips whose disks have it, or the chips themselves where the two
/// chips of a pointer size differ (`src/disk/build.zig`'s lists say which
/// disk a program is on; an icon without its program is an icon that
/// starts nothing).
const DiskIcon = struct {
    path: []const u8,
    picture: []const u8,
    fields: []const []const u8 = &.{},
    pointer_bytes: ?u32 = null,
    chips: ?[]const Chip = null,
};

/// The stack every icon that starts a program asks for: what a command
/// gets in a shell (`CLI_DEFAULT_STACK`), so a program has the same stack
/// started from its icon as typed. That depends on the chip's pointers,
/// so this field stands for it in the list, and each disk gets the icon
/// with its own (`iconStack`).
const icon_stack = "STACK=CLI_DEFAULT_STACK";

/// `CLI_DEFAULT_STACK` on a chip whose pointers are `pointer_bytes` long:
/// 4 KiB for each byte, as sdk/libs/dos/dosextens.zig has it.
fn iconStack(b: *std.Build, pointer_bytes: u32) []const u8 {
    return b.fmt("STACK={d}", .{4096 * pointer_bytes});
}

/// The icon `one` made by tools/mkicon from `picture`, with `stack` for
/// the field `icon_stack`.
fn makeIcon(b: *std.Build, mkicon: *std.Build.Step.Compile, picture: []const u8, one: DiskIcon, stack: []const u8) std.Build.LazyPath {
    const run = b.addRunArtifact(mkicon);
    run.addFileArg(.{ .cwd_relative = picture });
    const made = run.addOutputFileArg(std.fs.path.basename(one.path));
    for (one.fields) |field| run.addArg(if (std.mem.eql(u8, field, icon_stack)) stack else field);
    return made;
}

const disk_icons = [_]DiskIcon{
    // The defaults, in ENVARC:Sys and from there in ENV:Sys: a file
    // without an icon gets the one of its kind, its group or a script's.
    .{ .path = "prefs/env-archive/Sys/def_disk.info", .picture = "drive-harddisk", .fields = &.{"KIND=DISK"} },
    .{ .path = "prefs/env-archive/Sys/def_drawer.info", .picture = "folder", .fields = &.{"KIND=DRAWER"} },
    .{ .path = "prefs/env-archive/Sys/def_tool.info", .picture = "application-x-executable", .fields = &.{ "KIND=TOOL", icon_stack } },
    .{ .path = "prefs/env-archive/Sys/def_project.info", .picture = "text-x-generic", .fields = &.{ "KIND=PROJECT", icon_stack } },
    .{ .path = "prefs/env-archive/Sys/def_trashcan.info", .picture = "user-trash", .fields = &.{"KIND=TRASHCAN"} },
    // A script runs through IconX.
    .{ .path = "prefs/env-archive/Sys/def_script.info", .picture = "text-x-script", .fields = &.{ "KIND=PROJECT", "TOOL=C:IconX", icon_stack } },
    .{ .path = "prefs/env-archive/Sys/def_picture.info", .picture = "image-x-generic", .fields = &.{ "KIND=PROJECT", icon_stack } },
    .{ .path = "prefs/env-archive/Sys/def_text.info", .picture = "text-x-generic", .fields = &.{ "KIND=PROJECT", icon_stack } },
    .{ .path = "prefs/env-archive/Sys/def_document.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", icon_stack } },
    .{ .path = "prefs/env-archive/Sys/def_sound.info", .picture = "audio-x-generic", .fields = &.{ "KIND=PROJECT", icon_stack } },
    .{ .path = "prefs/env-archive/Sys/def_instrument.info", .picture = "audio-card", .fields = &.{ "KIND=PROJECT", icon_stack } },
    .{ .path = "prefs/env-archive/Sys/def_music.info", .picture = "multimedia-player", .fields = &.{ "KIND=PROJECT", icon_stack } },
    .{ .path = "prefs/env-archive/Sys/def_animation.info", .picture = "video-x-generic", .fields = &.{ "KIND=PROJECT", icon_stack } },
    .{ .path = "prefs/env-archive/Sys/def_movie.info", .picture = "video-x-generic", .fields = &.{ "KIND=PROJECT", icon_stack } },
    .{ .path = "prefs/env-archive/Sys/def_model.info", .picture = "package-x-generic", .fields = &.{ "KIND=PROJECT", icon_stack } },
    // The volume itself: its window shows the drawers with icons, the
    // system's own (C:, S:, LIBS:, DEVS:, ...) left to the shell.
    .{ .path = "Disk.info", .picture = "drive-harddisk", .fields = &.{ "KIND=DISK", "SHOW=ICONS" } },
    .{ .path = "Trashcan.info", .picture = "user-trash", .fields = &.{"KIND=TRASHCAN"} },
    .{ .path = "programs.info", .picture = "applications-other", .fields = &.{"KIND=DRAWER"} },
    .{ .path = "prefs.info", .picture = "preferences-desktop", .fields = &.{"KIND=DRAWER"} },
    .{ .path = "System.info", .picture = "applications-system", .fields = &.{"KIND=DRAWER"} },
    .{ .path = "Commodities.info", .picture = "input-keyboard", .fields = &.{"KIND=DRAWER"} },
    .{ .path = "WBStartup.info", .picture = "folder", .fields = &.{"KIND=DRAWER"} },
    .{ .path = "tests.info", .picture = "folder", .fields = &.{"KIND=DRAWER"} },
    .{ .path = "pictures.info", .picture = "folder", .fields = &.{"KIND=DRAWER"} },
    .{ .path = "fonts.info", .picture = "folder", .fields = &.{"KIND=DRAWER"} },
    // The programs.
    .{ .path = "programs/Notepad.info", .picture = "accessories-text-editor", .fields = &.{ "KIND=TOOL", icon_stack } },
    .{ .path = "programs/MultiView.info", .picture = "system-search", .fields = &.{ "KIND=TOOL", icon_stack } },
    .{ .path = "programs/FontView.info", .picture = "preferences-desktop-font", .fields = &.{ "KIND=TOOL", icon_stack } },
    .{ .path = "programs/Prefs.info", .picture = "preferences-system", .fields = &.{ "KIND=TOOL", icon_stack } },
    .{ .path = "programs/Battery.info", .picture = "battery", .fields = &.{ "KIND=TOOL", icon_stack } },
    .{ .path = "programs/Sheet.info", .picture = "x-office-spreadsheet", .fields = &.{ "KIND=TOOL", icon_stack } },
    .{ .path = "programs/Terminal.info", .picture = "utilities-terminal", .fields = &.{ "KIND=TOOL", icon_stack } },
    .{ .path = "programs/Player.info", .picture = "multimedia-player", .fields = &.{ "KIND=TOOL", icon_stack } },
    .{ .path = "programs/Volume.info", .picture = "audio-card", .fields = &.{ "KIND=TOOL", icon_stack } },
    .{ .path = "programs/Movie.info", .picture = "video-x-generic", .fields = &.{ "KIND=TOOL", icon_stack } },
    // The two that draw in three dimensions are on every disk but the
    // ESP32-S3's, which has no facet.library.
    .{ .path = "programs/Boing.info", .picture = "applications-games", .fields = &.{ "KIND=TOOL", icon_stack }, .chips = &.{ .esp32p4, .rv64sbi, .a64psci } },
    .{ .path = "programs/Cobra.info", .picture = "applications-games", .fields = &.{ "KIND=TOOL", icon_stack }, .chips = &.{ .esp32p4, .rv64sbi, .a64psci } },
    // The dock: on the ESP32s in SYS:Programs, started by hand; on the
    // 64-bit machines in SYS:WBStartup, started with the desktop, which
    // does not wait for it to end.
    .{ .path = "programs/Dock.info", .picture = "preferences-desktop", .fields = &.{ "KIND=TOOL", icon_stack }, .pointer_bytes = 4 },
    .{ .path = "WBStartup/Dock.info", .picture = "preferences-desktop", .fields = &.{ "KIND=TOOL", icon_stack, "TYPE=DONOTWAIT" }, .pointer_bytes = 8 },
    // What each program is, in SYS:Programs/Docs: read in MultiView.
    .{ .path = "programs/Docs.info", .picture = "folder", .fields = &.{"KIND=DRAWER"} },
    .{ .path = "programs/Docs/Battery.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "programs/Docs/Boing.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack }, .chips = &.{ .esp32p4, .rv64sbi, .a64psci } },
    .{ .path = "programs/Docs/Cobra.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack }, .chips = &.{ .esp32p4, .rv64sbi, .a64psci } },
    .{ .path = "programs/Docs/Dock.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "programs/Docs/FontView.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "programs/Docs/MultiView.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "programs/Docs/Movie.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "programs/Docs/Notepad.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "programs/Docs/Player.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "programs/Docs/Prefs.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "programs/Docs/Sheet.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "programs/Docs/Terminal.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "programs/Docs/Volume.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    // The system's tools, and what each is in SYS:System/Docs.
    .{ .path = "System/Shell.info", .picture = "utilities-terminal", .fields = &.{ "KIND=TOOL", icon_stack } },
    .{ .path = "System/HDToolBox.info", .picture = "drive-harddisk", .fields = &.{ "KIND=TOOL", icon_stack } },
    .{ .path = "System/CPULoad.info", .picture = "utilities-system-monitor", .fields = &.{ "KIND=TOOL", icon_stack } },
    .{ .path = "System/NetLoad.info", .picture = "utilities-system-monitor", .fields = &.{ "KIND=TOOL", icon_stack } },
    .{ .path = "System/MemMap.info", .picture = "computer", .fields = &.{ "KIND=TOOL", icon_stack } },
    .{ .path = "System/Clock.info", .picture = "appointment-new", .fields = &.{ "KIND=TOOL", icon_stack, "TYPE=MODE=ANALOG", "TYPE=SECONDS=YES", "TYPE=DATE=YES" } },
    .{ .path = "System/Shares.info", .picture = "folder-remote", .fields = &.{ "KIND=TOOL", icon_stack } },
    .{ .path = "System/Update.info", .picture = "system-software-update", .fields = &.{ "KIND=TOOL", icon_stack }, .chips = &.{ .rv64sbi, .a64psci, .x64uefi } },
    .{ .path = "System/Docs.info", .picture = "folder", .fields = &.{"KIND=DRAWER"} },
    .{ .path = "System/Docs/CPULoad.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "System/Docs/NetLoad.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "System/Docs/HDToolBox.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "System/Docs/MemMap.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "System/Docs/Clock.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "System/Docs/Shares.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "System/Docs/Update.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack }, .chips = &.{ .rv64sbi, .a64psci, .x64uefi } },
    // The commodities, each icon with the tool types it reads, and what
    // each is in SYS:Commodities/Docs. The pictures are the ones the
    // fetch drew, so the ones that work on the same thing share a
    // picture - the name under it says which is which.
    .{ .path = "Commodities/Exchange.info", .picture = "preferences-desktop-keyboard-shortcuts", .fields = &.{ "KIND=TOOL", icon_stack, "TYPE=CX_PRIORITY=0", "TYPE=CX_POPKEY=ctrl alt home", "TYPE=CX_POPUP=YES" } },
    .{ .path = "Commodities/Blanker.info", .picture = "preferences-desktop", .fields = &.{ "KIND=TOOL", icon_stack, "TYPE=SECONDS=60", "TYPE=CYCLECOLORS=YES", "TYPE=ANIMATION=YES", "TYPE=CX_PRIORITY=0", "TYPE=CX_POPKEY=ctrl alt b", "TYPE=CX_POPUP=YES" } },
    .{ .path = "Commodities/Emoji.info", .picture = "input-keyboard", .fields = &.{ "KIND=TOOL", icon_stack, "TYPE=CX_PRIORITY=0", "TYPE=CX_POPKEY=ctrl alt e", "TYPE=CX_POPUP=YES" } },
    .{ .path = "Commodities/FKey.info", .picture = "preferences-desktop-keyboard-shortcuts", .fields = &.{ "KIND=TOOL", icon_stack, "TYPE=CX_PRIORITY=0", "TYPE=CX_POPKEY=ctrl alt k", "TYPE=CX_POPUP=YES" } },
    .{ .path = "Commodities/AutoPoint.info", .picture = "preferences-system", .fields = &.{ "KIND=TOOL", icon_stack, "TYPE=CX_PRIORITY=0" } },
    .{ .path = "Commodities/ClickToFront.info", .picture = "preferences-system", .fields = &.{ "KIND=TOOL", icon_stack, "TYPE=CX_PRIORITY=0" } },
    .{ .path = "Commodities/MouseBlanker.info", .picture = "input-keyboard", .fields = &.{ "KIND=TOOL", icon_stack, "TYPE=CX_PRIORITY=0" } },
    .{ .path = "Commodities/NoCapsLock.info", .picture = "input-keyboard", .fields = &.{ "KIND=TOOL", icon_stack, "TYPE=CX_PRIORITY=0" } },
    .{ .path = "Commodities/NumericPad.info", .picture = "input-keyboard", .fields = &.{ "KIND=TOOL", icon_stack, "TYPE=CX_PRIORITY=0" } },
    .{ .path = "Commodities/Docs.info", .picture = "folder", .fields = &.{"KIND=DRAWER"} },
    .{ .path = "Commodities/Docs/Exchange.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "Commodities/Docs/AutoPoint.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "Commodities/Docs/Blanker.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "Commodities/Docs/ClickToFront.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "Commodities/Docs/Emoji.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "Commodities/Docs/FKey.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "Commodities/Docs/MouseBlanker.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "Commodities/Docs/NoCapsLock.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "Commodities/Docs/NumericPad.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
};

/// The directories only the machines whose disk is in RAM have:
/// SYS:Storage is what belongs to the machine rather than to the running
/// system, and Storage/Boot in it the files the firmware loads, which
/// `C:Install` writes to a boot partition - so such a machine installs
/// itself with no network and no second machine. An ESP32 board's disk is
/// the flash its kernel is written with and has no use for either.
const ram_disk_dirs = [_][]const u8{ "Storage", "Storage/Boot" };

/// The drawers under `Storage/Boot` a machine's firmware wants its files
/// in. A UEFI firmware reads one name and no other: `EFI/BOOT/BOOTX64.EFI`
/// on the partition it starts from, so the loader is kept under those two
/// drawers here as well - that way `C:Install` copies the whole of
/// `Storage/Boot` and the result is a partition that machine starts from.
const uefi_boot_dirs = [_][]const u8{ "Storage/Boot/EFI", "Storage/Boot/EFI/BOOT" };
/// Where that firmware looks for the loader, under `Storage/Boot` and in
/// a package's `boot/`.
pub const uefi_loader_path = "EFI/BOOT/BOOTX64.EFI";

/// Whether the directory `dir` is made on `chip`'s image: the catalogs
/// of `wide_languages` are on the 64-bit machines' disks only, with the
/// fonts they are written in. Whether a board's sets have it is asked
/// apart (`poweros_userland.onDisk`).
fn dirFor(dir: []const u8, chip: Chip) bool {
    const catalogs = "locale/Catalogs/";
    if (std.mem.startsWith(u8, dir, catalogs)) {
        const language = std.mem.sliceTo(dir[catalogs.len..], '/');
        for (wide_languages) |wide| {
            if (std.mem.eql(u8, language, wide)) return chip != .esp32s3 and chip != .esp32p4;
        }
    }
    return true;
}

/// The languages whose script needs a font the ESP32s' flash has no room
/// for.
const wide_languages = [_][]const u8{ "hindi", "nihongo", "hangugeo", "zhongwen" };

/// One `-Dextra` file: where it goes on the disk image, which file on
/// the host it is, the chips whose images take it, and the directories
/// that have to be made for it.
const Extra = struct {
    /// Its path in the volume's root, e.g. "c/dm" or "dm/GRAPHICS.DAT".
    path: []const u8,
    /// The file on the host, as the option gave it.
    host: []const u8,
    /// The chips whose disk images it goes on; null for every image.
    only: ?std.EnumSet(Chip) = null,
    /// `system:`: a file of the 64-bit machines' system that their disk
    /// image in RAM has no room for - in their trees, manifests and
    /// packages and on the system disks (mkfs's `--system-file`).
    system: bool = false,
    /// The directories above `path` that the image does not have yet,
    /// outermost first. Only the first file that needs one names it.
    dirs: []const []const u8,
};

/// `-Dextra=<path on the disk>=<file on the host>`: a file from outside
/// this tree onto the disk image, given once per file. It is what puts a
/// program built in another repository on `C:` along with the data it
/// reads - `-Dextra=c/dm=../dmzig/zig-out/poweros/dm.seg
/// -Dextra=dm/GRAPHICS.DAT=../dmzig/assets/GRAPHICS.DAT` - without this
/// tree knowing anything about it.
///
/// A file goes on every chip's image unless the entry starts with the
/// images it is for and a colon: chips by `Chip`'s names, and `system`
/// for the 64-bit machines' systems without their disk image in RAM
/// (mkfs's `--system-file`): the trees and manifests a release package
/// is made of, and the system disks.
/// `-Dextra=rv64sbi:c/tool=<file>` puts a program on the RISC-V 64 disks
/// only; `-Dextra=system:Music/song.mp3=<file>` a song on every 64-bit
/// machine's disk, which has room where the image in RAM and the
/// boards' flash disks have none.
///
/// The directories a path needs are made for it, and the ones the image
/// already has are left alone. They are made on every image, whichever
/// the file is for: an empty drawer costs a block, and one path then
/// never needs a drawer on one image that another file made on another.
fn extraFiles(b: *std.Build, made: *std.ArrayList([]const u8)) []const Extra {
    const given = b.option(
        []const []const u8,
        "extra",
        "A file from outside this tree on the disk image: [<chip>|system,...:]<path on the disk>=<file on the host>, given once per file",
    ) orelse return &.{};

    var extras: std.ArrayList(Extra) = .empty;
    for (given) |entry| {
        const split = std.mem.indexOfScalar(u8, entry, '=') orelse
            std.debug.panic("-Dextra={s}: no '=' between the path on the disk and the file on the host", .{entry});
        // The chips it is for, before a colon in what comes before the '='.
        var only: ?std.EnumSet(Chip) = null;
        var system = false;
        var start: usize = 0;
        if (std.mem.indexOfScalar(u8, entry[0..split], ':')) |colon| {
            var chips = std.EnumSet(Chip).initEmpty();
            var names = std.mem.splitScalar(u8, entry[0..colon], ',');
            while (names.next()) |name| {
                if (std.mem.eql(u8, name, "system")) {
                    system = true;
                    continue;
                }
                const chip = std.meta.stringToEnum(Chip, name) orelse
                    std.debug.panic("-Dextra={s}: no image '{s}' - system, or a chip: {s}", .{ entry, name, chipNames(b) });
                chips.insert(chip);
            }
            only = chips;
            start = colon + 1;
        }
        const path = std.mem.trim(u8, entry[start..split], "/");
        const host = entry[split + 1 ..];
        if (path.len == 0 or host.len == 0)
            std.debug.panic("-Dextra={s}: it is [<chip>|system,...:]<path on the disk>=<file on the host>", .{entry});

        extras.append(b.allocator, .{
            .path = path,
            .host = host,
            .only = only,
            .system = system,
            .dirs = dirsFor(b, made, path, false),
        }) catch @panic("OOM");
    }
    return extras.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// A file `-Dboot=` puts in a package's `boot/`: the name it is read
/// under, and the file on the host.
pub const BootFile = struct { name: []const u8, host: []const u8 };

/// `-Dboot=[<name>=]<file on the host>`: a file from outside this tree in
/// a release package's `boot/`, given once per file. It is for what a
/// board's firmware reads that this tree does not hold - the Compute
/// Module 5's device tree is Raspberry Pi's
/// (`-Dboot=/boot/firmware/bcm2712-rpi-cm5-cm5io.dtb`) - and the file
/// goes into the package's manifest with the rest, so a machine fetches
/// and checks it like any other. Without a name it keeps the host file's.
pub fn bootFiles(b: *std.Build) []const BootFile {
    const given = b.option(
        []const []const u8,
        "boot",
        "A file from outside this tree in a release package's boot/: [<name>=]<file on the host>, given once per file",
    ) orelse return &.{};

    var files: std.ArrayList(BootFile) = .empty;
    for (given) |entry| {
        const split = std.mem.indexOfScalar(u8, entry, '=');
        const host = if (split) |at| entry[at + 1 ..] else entry;
        const name = if (split) |at| entry[0..at] else std.fs.path.basename(host);
        if (name.len == 0 or host.len == 0)
            std.debug.panic("-Dboot={s}: it is [<name>=]<file on the host>", .{entry});
        files.append(b.allocator, .{ .name = name, .host = host }) catch @panic("OOM");
    }
    return files.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// The directories `path` needs that nothing has made yet, outermost
/// first, added to `made` as they are named. With `include_self` the
/// path is a directory and counts as one of them; without it the path is
/// a file and only what is above it does.
fn dirsFor(b: *std.Build, made: *std.ArrayList([]const u8), path: []const u8, include_self: bool) []const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, at, '/')) |slash| : (at = slash + 1) {
        need(b, made, &dirs, path[0..slash]);
    }
    if (include_self) need(b, made, &dirs, path);
    return dirs.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn need(b: *std.Build, made: *std.ArrayList([]const u8), dirs: *std.ArrayList([]const u8), dir: []const u8) void {
    for (made.items) |done| {
        if (std.mem.eql(u8, done, dir)) return;
    }
    made.append(b.allocator, dir) catch @panic("OOM");
    dirs.append(b.allocator, dir) catch @panic("OOM");
}

fn diskTree(b: *std.Build, made: *std.ArrayList([]const u8), include: bool) Tree {
    const io = b.graph.io;
    if (!include) return .{};
    var root = b.build_root.handle.openDir(io, disk_tree, .{ .iterate = true }) catch return .{};
    defer root.close(io);

    var dirs: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList(Extra) = .empty;
    var walker = root.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch @panic("disk/: cannot be read")) |entry| {
        // The walker hands a directory over before what is in it, so
        // taking them in the order they arrive puts parents first.
        // A name beginning with a dot is the host's business, not the
        // disk's: .gitkeep, .gitignore and whatever a file manager
        // leaves behind stay here. So does the README that says what
        // this directory is for.
        if (entry.basename.len != 0 and entry.basename[0] == '.') continue;
        if (std.mem.eql(u8, entry.path, "README.md")) continue;
        const path = b.dupe(entry.path);
        switch (entry.kind) {
            .directory => dirs.appendSlice(b.allocator, dirsFor(b, made, path, true)) catch @panic("OOM"),
            .file => {
                dirs.appendSlice(b.allocator, dirsFor(b, made, path, false)) catch @panic("OOM");
                files.append(b.allocator, .{
                    .path = withoutSeg(path),
                    .host = b.fmt("{s}/{s}", .{ disk_tree, path }),
                    .dirs = &.{},
                }) catch @panic("OOM");
            },
            else => {},
        }
    }
    return .{
        .dirs = dirs.toOwnedSlice(b.allocator) catch @panic("OOM"),
        .files = files.toOwnedSlice(b.allocator) catch @panic("OOM"),
    };
}

/// What `disk/` puts on the image: the directories to make, outermost
/// first, and the files to put in them.
pub const Tree = struct {
    dirs: []const []const u8 = &.{},
    files: []const Extra = &.{},
};

/// `games/` in the root of the tree, with -Dgames: what is in it goes in
/// the `Games` drawer of the 64-bit machines' systems - their trees,
/// manifests and release packages, and the system disks
/// (`system-rv64.bin`, `system-a64.bin`, `system-x64.bin`) - games and
/// their data, too large for the disk image in RAM and the boards'
/// flash disks, on the disks that have room for them. A program is built once per chip, so `<name>.<chip>.seg` goes
/// on that chip's disk alone, as `<name>`:
/// `games/Millennium/Millennium.a64psci.seg` is
/// `SYS:Games/Millennium/Millennium` on the AArch64 machine's. Another
/// `.seg` loses the suffix on all of them, and any other file keeps its
/// name.
/// The drawers are made there alone (mkfs's `--system-file` with
/// no file), outermost first, and `Games` gets its icon there
/// (`games_drawer_icon`): the volume's window shows only what has one.
///
/// A name beginning with a dot is left behind, and so is the `README.md`
/// in the root of `games/`.
fn gamesTree(b: *std.Build, made: *std.ArrayList([]const u8)) []const Game {
    const wanted = b.option(bool, "games", "Put what games/ holds in the Games drawer of the 64-bit machines' packages and system disks: <name>.<chip>.seg on that chip's as <name>") orelse false;
    if (!wanted) return &.{};
    const io = b.graph.io;
    var root = b.build_root.handle.openDir(io, games_tree, .{ .iterate = true }) catch
        std.debug.panic("-Dgames: there is no {s}/ in the tree's root", .{games_tree});
    defer root.close(io);

    var games: std.ArrayList(Game) = .empty;
    drawers(b, made, &games, games_drawer, true);
    var walker = root.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch @panic("games/: cannot be read")) |entry| {
        if (entry.basename.len != 0 and entry.basename[0] == '.') continue;
        if (std.mem.eql(u8, entry.path, "README.md")) continue;
        const path = b.fmt("{s}/{s}", .{ games_drawer, entry.path });
        switch (entry.kind) {
            .directory => drawers(b, made, &games, path, true),
            .file => {
                drawers(b, made, &games, path, false);
                var game: Game = .{ .path = withoutSeg(path), .host = b.fmt("{s}/{s}", .{ games_tree, entry.path }) };
                if (game.path.len != path.len) {
                    if (std.mem.lastIndexOfScalar(u8, game.path, '.')) |dot| {
                        if (std.meta.stringToEnum(Chip, game.path[dot + 1 ..])) |chip| {
                            game.chip = chip;
                            game.path = game.path[0..dot];
                        }
                    }
                }
                games.append(b.allocator, game) catch @panic("OOM");
            },
            else => {},
        }
    }
    return games.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// The drawers `path` needs that are not made yet, as entries of
/// `games`.
fn drawers(b: *std.Build, made: *std.ArrayList([]const u8), games: *std.ArrayList(Game), path: []const u8, include_self: bool) void {
    for (dirsFor(b, made, path, include_self)) |dir| {
        games.append(b.allocator, .{ .path = dir }) catch @panic("OOM");
    }
}

/// A drawer or a file of `games/`, in the order mkfs makes them.
const Game = struct {
    /// Its path on the disk.
    path: []const u8,
    /// The file, from the tree's root; null for a drawer.
    host: ?[]const u8 = null,
    /// The chip whose disk alone it goes on; null for both.
    chip: ?Chip = null,
};

fn withoutSeg(path: []const u8) []const u8 {
    const suffix = ".seg";
    if (path.len > suffix.len and std.mem.endsWith(u8, path, suffix)) {
        return path[0 .. path.len - suffix.len];
    }
    return path;
}

/// The name a flash board's disk image is installed under, by its chip.
fn flashDiskName(chip: Chip) []const u8 {
    return switch (chip) {
        .esp32s3 => "disk.bin",
        .esp32p4 => "disk-esp32p4.bin",
        .rv64sbi, .a64psci, .x64uefi => unreachable,
    };
}

/// `board`'s flash disk among `images`, in `flash_boards`' order; null
/// for a board whose disk is not its flash.
pub fn flashDisk(images: [flash_boards.len]std.Build.LazyPath, board: Board) ?std.Build.LazyPath {
    const at = std.mem.indexOfScalar(Board, &flash_boards, board) orelse return null;
    return images[at];
}

/// Every disk image there is, for the code that hands a board its own:
/// the flash boards' in `flash_boards`' order, the others in
/// `ram_chips`'.
pub const BoardDisks = struct {
    flash: [flash_boards.len]std.Build.LazyPath,
    ram: [ram_chips.len]std.Build.LazyPath,

    pub fn of(disks: BoardDisks, board: Board) std.Build.LazyPath {
        if (flashDisk(disks.flash, board)) |image| return image;
        return disks.ram[std.mem.indexOfScalar(Chip, &ram_chips, chipOf(board)).?];
    }
};

/// Disk images made from one recipe. What is given goes into each that
/// has a place for it: a file is on a disk when its set and the sets of
/// the drawers it lies in are among that disk's
/// (`poweros_userland.onDisk`).
pub const DiskImages = struct {
    runs: [count]*std.Build.Step.Run,
    /// What each run's disk holds, in the order of `runs`.
    sets: [count]Sets,

    /// The flash boards' images, then the 64-bit chips'.
    pub const count = flash_boards.len + ram_chips.len;

    /// Each run's chip, in the order of `runs`.
    pub const chips: [count]Chip = blk: {
        var list: [count]Chip = undefined;
        for (flash_boards, 0..) |board, i| list[i] = chipOf(board);
        for (ram_chips, flash_boards.len..) |chip, i| list[i] = chip;
        break :blk list;
    };
    /// How long a pointer is on each run's chip.
    pub const pointer_bytes: [count]u32 = blk: {
        var list: [count]u32 = undefined;
        for (chips, 0..) |chip, i| list[i] = switch (chip) {
            .esp32s3, .esp32p4 => 4,
            .rv64sbi, .a64psci, .x64uefi => 8,
        };
        break :blk list;
    };
    /// Whether each run writes a virt machine's system disk as well
    /// (`--gpt`).
    pub const virt_disks: [count]bool = @as([flash_boards.len]bool, @splat(false)) ++ @as([ram_chips.len]bool, @splat(true));

    /// Where `board`'s disk is in `runs`.
    pub fn indexOf(board: Board) usize {
        if (std.mem.indexOfScalar(Board, &flash_boards, board)) |at| return at;
        return flash_boards.len + std.mem.indexOfScalar(Chip, &ram_chips, chipOf(board)).?;
    }

    /// The run that makes `board`'s disk.
    pub fn runOf(images: *const DiskImages, board: Board) *std.Build.Step.Run {
        return images.runs[indexOf(board)];
    }

    pub fn addArg(images: DiskImages, arg: []const u8) void {
        for (images.runs) |run| run.addArg(arg);
    }

    pub fn addArgs(images: DiskImages, args: []const []const u8) void {
        for (images.runs) |run| run.addArgs(args);
    }

    pub fn addPrefixedFileArg(images: DiskImages, prefix: []const u8, path: std.Build.LazyPath) void {
        for (images.runs) |run| run.addPrefixedFileArg(prefix, path);
    }

    /// The directory `dir` on every disk whose sets have it.
    pub fn addDir(images: DiskImages, dir: []const u8) void {
        for (images.runs, images.sets) |run, sets| {
            if (poweros_userland.onDisk(sets, dir)) run.addArg(dir);
        }
    }

    /// The file `from` at `path` on every disk whose sets have it.
    pub fn addFile(images: DiskImages, path: []const u8, from: std.Build.LazyPath) void {
        for (images.runs, images.sets) |run, sets| {
            if (poweros_userland.onDisk(sets, path)) run.addPrefixedFileArg(run.step.owner.fmt("{s}=", .{path}), from);
        }
    }

    /// The directory `dir` on `chip`'s disks whose sets have it.
    pub fn addChipDir(images: DiskImages, chip: Chip, dir: []const u8) void {
        for (images.runs, chips, images.sets) |run, of, sets| {
            if (of == chip and poweros_userland.onDisk(sets, dir)) run.addArg(dir);
        }
    }

    /// The file `from` at `path` on `chip`'s disks whose sets have it.
    pub fn addChipFile(images: DiskImages, chip: Chip, path: []const u8, from: std.Build.LazyPath) void {
        for (images.runs, chips, images.sets) |run, of, sets| {
            if (of == chip and poweros_userland.onDisk(sets, path)) run.addPrefixedFileArg(run.step.owner.fmt("{s}=", .{path}), from);
        }
    }

    /// The runs of every disk, or of the 64-bit machines' only.
    pub fn some(images: *const DiskImages, wide_only: bool) Some {
        const from: usize = if (wide_only) flash_boards.len else 0;
        return .{ .runs = images.runs[from..], .sets = images.sets[from..] };
    }

    pub const Some = struct {
        runs: []const *std.Build.Step.Run,
        sets: []const Sets,

        pub fn addArg(images: Some, arg: []const u8) void {
            for (images.runs) |run| run.addArg(arg);
        }

        pub fn addPrefixedFileArg(images: Some, prefix: []const u8, path: std.Build.LazyPath) void {
            for (images.runs) |run| run.addPrefixedFileArg(prefix, path);
        }

        /// The file `from` at `path` on each of these disks that holds
        /// `set`.
        pub fn addFileIn(images: Some, set: poweros_userland.Set, path: []const u8, from: std.Build.LazyPath) void {
            for (images.runs, images.sets) |run, sets| {
                if (sets.contains(set)) run.addPrefixedFileArg(run.step.owner.fmt("{s}=", .{path}), from);
            }
        }
    };
};

/// Whether a thing on the disk is a module - a library, device, handler or
/// class - rather than a program.
pub fn isModule(disk: []const u8) bool {
    for ([_][]const u8{ "libs/", "devs/", "classes/" }) |place| {
        if (std.mem.startsWith(u8, disk, place)) return true;
    }
    return false;
}

/// What `addDiskImages` takes from the build so far.
pub const DiskImagesWith = struct {
    board: Board,
    board_sets: Sets,
    dh0_sectors: u32,
    disk_dep: *std.Build.Dependency,
    disk_rdb_blocks: u32,
    disk_size: u32,
    disk_tree_option: ?bool,
    mkfs: *std.Build.Step.Compile,
    mkicon: *std.Build.Step.Compile,
    optimize: std.builtin.OptimizeMode,
    sdk: *std.Build.Module,
    sdk_dep: *std.Build.Dependency,
    wifi: ?[]const u8,
};

/// What `addDiskImages` hands on to the rest of the build.
pub const MadeDiskImages = struct {
    a64_disk_bin: std.Build.LazyPath,
    a64_system_disk: std.Build.LazyPath,
    a64_tree: std.Build.LazyPath,
    disks: DiskImages,
    flash_disks: [flash_boards.len]std.Build.LazyPath,
    make_a64_disk: *std.Build.Step.Run,
    make_rv64_disk: *std.Build.Step.Run,
    make_x64_disk: *std.Build.Step.Run,
    rv64_disk_bin: std.Build.LazyPath,
    rv64_system_disk: std.Build.LazyPath,
    rv64_tree: std.Build.LazyPath,
    tree: Tree,
    x64_disk_bin: std.Build.LazyPath,
    x64_medium_bin: std.Build.LazyPath,
    x64_system_disk: std.Build.LazyPath,
    x64_tree: std.Build.LazyPath,
};

/// Every disk image: one for each board whose disk is its flash, one for
/// each 64-bit chip, each filled with what its sets hold - the programs,
/// the files, the catalogs, the fonts, the icons, the `disk/` tree and
/// -Dextra - and the board's own installed.
pub fn addDiskImages(b: *std.Build, with: DiskImagesWith) MadeDiskImages {
    const board = with.board;
    const board_sets = with.board_sets;
    const dh0_sectors = with.dh0_sectors;
    const disk_dep = with.disk_dep;
    const disk_rdb_blocks = with.disk_rdb_blocks;
    const disk_size = with.disk_size;
    const disk_tree_option = with.disk_tree_option;
    const mkfs = with.mkfs;
    const mkicon = with.mkicon;
    const optimize = with.optimize;
    const sdk = with.sdk;
    const sdk_dep = with.sdk_dep;
    const wifi = with.wifi;

    // What goes on the image besides the build's own outputs: the
    // `disk/` tree, then -Dextra. `made` is the directories the image
    // already has, so that none is asked for twice - which mkfs refuses.
    var made: std.ArrayList([]const u8) = .empty;
    made.appendSlice(b.allocator, &image_dirs) catch @panic("OOM");
    made.appendSlice(b.allocator, &ram_disk_dirs) catch @panic("OOM");
    const tree = diskTree(b, &made, disk_tree_option orelse true);
    const extras = extraFiles(b, &made);
    const games = gamesTree(b, &made);

    // The images, from one recipe: one for each board whose disk is its
    // flash, with the sets that board names, and one for the RISC-V 64
    // machines, the AArch64 machines and the x86-64 machines each. They
    // differ in their programs' load files and in what the sets leave
    // off. -Dsets is for the board this build is for.
    var flash_runs: [flash_boards.len]*std.Build.Step.Run = undefined;
    var flash_disks: [flash_boards.len]std.Build.LazyPath = undefined;
    var disk_sets: [DiskImages.count]Sets = undefined;
    for (flash_boards, 0..) |one, i| {
        flash_runs[i] = b.addRunArtifact(mkfs);
        flash_disks[i] = flash_runs[i].addOutputFileArg(flashDiskName(chipOf(one)));
        disk_sets[i] = if (one == board) board_sets else boardSets(one);
    }
    for (ram_chips, flash_boards.len..) |chip, i| {
        disk_sets[i] = if (chipOf(board) == chip) board_sets else Sets.initFull();
    }
    const make_rv64_disk = b.addRunArtifact(mkfs);
    // The RISC-V 64 disk's files as a tree as well, and the list of them,
    // for a card that is SYS: to be brought up to date from
    // (zig-out/disk-rv64/, zig-out/bin/disk-rv64.manifest).
    const rv64_tree = make_rv64_disk.addPrefixedOutputDirectoryArg("--tree=", "disk-rv64");
    const rv64_manifest = make_rv64_disk.addPrefixedOutputFileArg("--manifest=", "disk-rv64.manifest");
    const rv64_disk_made = make_rv64_disk.addOutputFileArg("disk-rv64-made.bin");
    // And as the virt machine's system disk, a GPT disk with posfs.
    const rv64_system_disk = make_rv64_disk.addPrefixedOutputFileArg("--gpt=", "system-rv64.bin");
    make_rv64_disk.addArg(b.fmt("--gpt-bytes={d}", .{virt_system_bytes}));
    const make_a64_disk = b.addRunArtifact(mkfs);
    // The AArch64 disk's files as a tree and a list as well, as the
    // RISC-V 64 disk's (zig-out/disk-a64/, zig-out/bin/disk-a64.manifest).
    const a64_tree = make_a64_disk.addPrefixedOutputDirectoryArg("--tree=", "disk-a64");
    const a64_manifest = make_a64_disk.addPrefixedOutputFileArg("--manifest=", "disk-a64.manifest");
    const a64_disk_made = make_a64_disk.addOutputFileArg("disk-a64-made.bin");
    const a64_system_disk = make_a64_disk.addPrefixedOutputFileArg("--gpt=", "system-a64.bin");
    make_a64_disk.addArg(b.fmt("--gpt-bytes={d}", .{virt_system_bytes}));
    const make_x64_disk = b.addRunArtifact(mkfs);
    // The x86-64 disk's files as a tree and a list as well, as the other
    // 64-bit disks' (zig-out/disk-x64/, zig-out/bin/disk-x64.manifest).
    const x64_tree = make_x64_disk.addPrefixedOutputDirectoryArg("--tree=", "disk-x64");
    const x64_manifest = make_x64_disk.addPrefixedOutputFileArg("--manifest=", "disk-x64.manifest");
    const x64_disk_made = make_x64_disk.addOutputFileArg("disk-x64-made.bin");
    // And as the stick's, which a machine started from it boots whatever
    // its own disks hold (mkfs `--medium`).
    const x64_medium_made = make_x64_disk.addPrefixedOutputFileArg("--medium=", "disk-x64-medium-made.bin");
    const x64_system_disk = make_x64_disk.addPrefixedOutputFileArg("--gpt=", "system-x64.bin");
    make_x64_disk.addArg(b.fmt("--gpt-bytes={d}", .{virt_system_bytes}));
    const disks: DiskImages = .{ .runs = flash_runs ++ .{ make_rv64_disk, make_a64_disk, make_x64_disk }, .sets = disk_sets };
    const p4_disk_dep = b.dependency("poweros_userland", .{ .optimize = optimize, .chip = Chip.esp32p4 });
    if (chipOf(board) == .esp32p4) {
        for (poweros_userland.programs) |program| {
            if (!poweros_userland.builtFor(program, .esp32p4)) continue;
            const load_file = b.fmt("{s}.seg", .{program.name});
            b.getInstallStep().dependOn(&b.addInstallBinFile(p4_disk_dep.namedLazyPath(program.disk), load_file).step);
        }
    }
    const rv64_disk_dep = b.dependency("poweros_userland", .{ .optimize = optimize, .chip = Chip.rv64sbi });
    const a64_disk_dep = b.dependency("poweros_userland", .{ .optimize = optimize, .chip = Chip.a64psci });
    const x64_disk_dep = b.dependency("poweros_userland", .{ .optimize = optimize, .chip = Chip.x64uefi });
    // The ESP32s' disk is the flash past the kernel, the 64-bit machines'
    // a RAM disk of its own size.
    for (disks.runs, DiskImages.chips) |run, chip| {
        const size: u32 = switch (chip) {
            .esp32s3, .esp32p4 => disk_size,
            .rv64sbi, .a64psci, .x64uefi => ram_disk_size,
        };
        run.addArgs(&.{
            "System",
            "DH0",
            b.fmt("{d}", .{size / disk_sector}),
            b.fmt("{d}", .{dh0_sectors}),
            b.fmt("{d}", .{disk_sector}),
            b.fmt("{d}", .{disk_page}),
            b.fmt("{d}", .{disk_rdb_blocks}),
        });
    }
    for (disks.runs, DiskImages.chips, disks.sets) |run, chip, sets| {
        for (image_dirs) |dir| {
            if (dirFor(dir, chip) and poweros_userland.onDisk(sets, dir)) run.addArg(dir);
        }
        switch (chip) {
            .esp32s3, .esp32p4 => {},
            .rv64sbi, .a64psci => run.addArgs(&ram_disk_dirs),
            .x64uefi => {
                run.addArgs(&ram_disk_dirs);
                run.addArgs(&uefi_boot_dirs);
            },
        }
    }
    // The `disk/` tree and -Dextra are the developer's own and go on
    // every disk, whatever its sets: a drawer of the build's that a
    // board's sets left off is made after all where one of those files
    // lies in it.
    var own_paths: std.ArrayList([]const u8) = .empty;
    own_paths.appendSlice(b.allocator, tree.dirs) catch @panic("OOM");
    for (tree.files) |file| own_paths.append(b.allocator, file.path) catch @panic("OOM");
    for (extras) |extra| {
        own_paths.appendSlice(b.allocator, extra.dirs) catch @panic("OOM");
        own_paths.append(b.allocator, extra.path) catch @panic("OOM");
    }
    for (disks.runs, DiskImages.chips, disks.sets) |run, chip, sets| {
        for (image_dirs) |dir| {
            if (!dirFor(dir, chip) or poweros_userland.onDisk(sets, dir)) continue;
            for (own_paths.items) |path| {
                if (path.len <= dir.len or path[dir.len] != '/' or !std.mem.startsWith(u8, path, dir)) continue;
                run.addArg(dir);
                break;
            }
        }
    }
    // The directories those files need, made before anything goes in
    // them: mkfs takes its paths in the order they are given.
    disks.addArgs(tree.dirs);
    for (extras) |extra| disks.addArgs(extra.dirs);
    const chip_deps = [_]*std.Build.Dependency{ disk_dep, p4_disk_dep, rv64_disk_dep, a64_disk_dep, x64_disk_dep };
    for (poweros_userland.programs) |program| {
        for (disks.runs, DiskImages.chips, disks.sets) |run, chip, sets| {
            if (!poweros_userland.builtFor(program, chip) or !poweros_userland.onDisk(sets, program.disk)) continue;
            run.addPrefixedFileArg(b.fmt("{s}=", .{program.disk}), chip_deps[@intFromEnum(chip)].namedLazyPath(program.disk));
        }
    }
    // The ROM modules the flash boards load from their disk, built for
    // each of their chips and installed beside the board's own load
    // files.
    for (rom_on_disk) |module| {
        for ([_]Chip{ .esp32s3, .esp32p4 }) |chip| {
            const seg = poweros_sdk.addProgram(b, sdk_dep, .{
                .name = module.name,
                .root = b.path(module.root),
                .optimize = optimize,
                .chip = chip,
            });
            disks.addChipFile(chip, module.disk, seg);
            if (chipOf(board) == chip) b.getInstallStep().dependOn(&b.addInstallBinFile(seg, b.fmt("{s}.seg", .{module.name})).step);
        }
    }
    for (poweros_userland.files) |file| {
        const prefix = b.fmt("{s}=", .{file.disk});
        const path = disk_dep.namedLazyPath(file.disk);
        for (disks.runs, DiskImages.chips, disks.sets) |run, chip, sets| {
            if (poweros_userland.fileFor(file, chip) and poweros_userland.onDisk(sets, file.disk)) run.addPrefixedFileArg(prefix, path);
        }
    }
    // The programs' catalogs, and the ROM modules' own.
    for (poweros_userland.catalogs) |catalog| {
        disks.some(catalog.wide).addFileIn(poweros_userland.setOfCatalog(catalog), catalog.disk, disk_dep.namedLazyPath(catalog.disk));
    }
    for (rom_catalogs) |catalog| {
        const catalog_file = poweros_sdk.addCatalog(b, sdk_dep, b.path(catalog.descriptor), b.path(catalog.translation), catalog.name);
        disks.some(catalog.wide).addPrefixedFileArg(b.fmt("{s}=", .{catalog.disk}), catalog_file);
    }
    // The chips' own versions after the shared ones, which they replace
    // on their images.
    for (poweros_userland.mac_files ++ poweros_userland.p4_files) |file| {
        disks.addChipFile(.esp32p4, file.disk, p4_disk_dep.namedLazyPath(file.source));
    }
    for (poweros_userland.mac_files) |file| {
        disks.addChipFile(.rv64sbi, file.disk, rv64_disk_dep.namedLazyPath(file.source));
    }
    for (poweros_userland.a64_files) |file| {
        disks.addChipFile(.a64psci, file.disk, a64_disk_dep.namedLazyPath(file.source));
    }
    for (poweros_userland.x64_files) |file| {
        disks.addChipFile(.x64uefi, file.disk, x64_disk_dep.namedLazyPath(file.source));
    }
    if (wifi != null) {
        const wifi_device = poweros_userland.wifi_device;
        disks.addChipFile(.esp32s3, wifi_device.disk, disk_dep.namedLazyPath(wifi_device.disk));
    }
    // FONTS: - the fonts scripts/fetch-fonts.sh fetched, converted by
    // tools/fontconv into the system's own files, when they are there.
    if (fontsDir(b)) |dir| {
        const fontconv = b.addExecutable(.{
            .name = "fontconv",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/fontconv/fontconv.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
            }),
        });
        fontconv.root_module.addImport("sdk", sdk);
        // truetype.library's reading of a font file: a variable font's
        // axes and named instances, for the styles it is listed in.
        const fontconv_truetype = b.createModule(.{ .root_source_file = disk_dep.path("libs/truetype/outlines.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
        fontconv_truetype.addImport("sdk", sdk);
        fontconv.root_module.addImport("truetype", fontconv_truetype);
        const liberation = hasFontSources(b, dir, liberation_dir);
        if (!liberation) std.log.info("no Liberation fonts (scripts/fetch-fonts.sh): the 64-bit disks have no FONTS:sans, serif or mono", .{});
        const devanagari = hasFontFile(b, dir, devanagari_dir ++ "/NotoSansDevanagari-Regular.ttf") and hasFontFile(b, dir, devanagari_dir ++ "/NotoSansDevanagari-Bold.ttf");
        if (!devanagari) std.log.info("no Noto Sans Devanagari, Regular and Bold (scripts/fetch-fonts.sh): the 64-bit disks have no FONTS:devanagari", .{});
        const cjk = hasFontFile(b, dir, devanagari_dir ++ "/" ++ cjk_file) and hasFontFile(b, dir, devanagari_dir ++ "/NotoSansCJK.licence");
        if (!cjk) std.log.info("no Noto Sans CJK Regular and its licence (scripts/fetch-fonts.sh): the 64-bit packages and system disks have no FONTS:cjk-jp, -kr, -sc, -tc and -hk", .{});
        const emoji = hasFontFile(b, dir, devanagari_dir ++ "/" ++ emoji_file) and hasFontFile(b, dir, devanagari_dir ++ "/NotoColorEmoji.licence");
        if (!emoji) std.log.info("no Noto Color Emoji and its licence (scripts/fetch-fonts.sh): the 64-bit packages and system disks have no FONTS:emoji", .{});
        for (disk_fonts) |family| {
            switch (family.set) {
                .base => {},
                .liberation => if (!liberation) continue,
                .devanagari => if (!devanagari) continue,
                .cjk => if (!cjk) continue,
                .emoji => if (!emoji) continue,
            }
            // The 64-bit disks take every family; the ESP32s' the ones
            // that are not `wide`. A `system` family is in the 64-bit
            // disks' trees and on the system disks, not in the image a
            // machine starts from out of RAM.
            const onto: FontPlace = .{ .runs = disks.some(family.wide or family.system).runs, .prefix = if (family.system) "--system-file=" else "" };
            const run = b.addRunArtifact(fontconv);
            const out = run.addOutputDirectoryArg(family.name);
            run.addArg(family.name);
            run.addArgs(family.options);
            for (family.sources) |source| run.addFileArg(.{ .cwd_relative = b.pathJoin(&.{ dir, source }) });
            if (family.in == null) onto.drawer(b.fmt("fonts/{s}", .{family.name}));
            onto.file(b.fmt("fonts/{s}.font", .{family.name}), out.path(b, b.fmt("{s}.font", .{family.name})));
            for (family.sizes) |rows| {
                const size = b.fmt("{s}/{d}", .{ family.name, rows });
                onto.file(b.fmt("fonts/{s}", .{size}), out.path(b, size));
            }
            for (family.outlines) |file| {
                const at = b.fmt("{s}/{s}", .{ family.name, file });
                onto.file(b.fmt("fonts/{s}", .{at}), out.path(b, at));
            }
        }
        disks.addPrefixedFileArg("fonts/spleen.licence=", .{ .cwd_relative = b.pathJoin(&.{ dir, "spleen-2.2.0/LICENSE" }) });
        disks.addPrefixedFileArg("fonts/go.licence=", .{ .cwd_relative = b.pathJoin(&.{ dir, "go/README" }) });
        if (liberation) disks.some(true).addPrefixedFileArg("fonts/liberation.licence=", .{ .cwd_relative = b.pathJoin(&.{ dir, liberation_dir ++ "/LICENSE" }) });
        if (devanagari) disks.some(true).addPrefixedFileArg("fonts/devanagari.licence=", .{ .cwd_relative = b.pathJoin(&.{ dir, devanagari_dir ++ "/NotoSansDevanagari.licence" }) });
        if (cjk) disks.some(true).addPrefixedFileArg("--system-file=fonts/cjk.licence=", .{ .cwd_relative = b.pathJoin(&.{ dir, devanagari_dir ++ "/NotoSansCJK.licence" }) });
        if (emoji) disks.some(true).addPrefixedFileArg("--system-file=fonts/emoji.licence=", .{ .cwd_relative = b.pathJoin(&.{ dir, devanagari_dir ++ "/NotoColorEmoji.licence" }) });
    }
    // SYS:Certificates/Roots - Mozilla's roots, which
    // scripts/fetch-certs.sh fetched, as the trust store tools/anchors
    // makes of them with the TLS library's own certificate code.
    if (certsFile(b)) |bundle| {
        const x509 = b.createModule(.{
            .root_source_file = b.path("src/disk/libs/tls/x509/x509.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        });
        const anchors = b.addExecutable(.{
            .name = "anchors",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/anchors/anchors.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
            }),
        });
        anchors.root_module.addImport("x509", x509);
        const run = b.addRunArtifact(anchors);
        run.addFileArg(.{ .cwd_relative = bundle });
        const store = run.addOutputFileArg("roots");
        disks.addDir("certificates");
        disks.addFile("certificates/roots", store);
    }
    // LOCALE:Emoji/ - the emoji in their groups and order, and their
    // names in the disk's languages, which tools/emojigen makes of what
    // scripts/fetch-emoji.sh fetched - and the licence of that beside
    // them. Where FONTS:emoji is: in the 64-bit disks' trees and on
    // the system disks, not in the image in RAM.
    if (emojiDir(b)) |dir| {
        const emojigen = b.addExecutable(.{
            .name = "emojigen",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/emojigen/emojigen.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
            }),
        });
        emojigen.root_module.addImport("sdk", sdk);
        const run = b.addRunArtifact(emojigen);
        run.addFileArg(.{ .cwd_relative = b.pathJoin(&.{ dir, "emoji-test.txt" }) });
        const out = run.addOutputDirectoryArg("emoji");
        const onto: FontPlace = .{ .runs = disks.some(true).runs, .prefix = "--system-file=" };
        onto.drawer("locale/Emoji");
        onto.file("locale/Emoji/emoji.list", out.path(b, "emoji.list"));
        for (emoji_languages) |language| {
            run.addArg(b.fmt("--language={s}", .{language.name}));
            for (language.codes) |code| {
                for ([_][]const u8{ "annotations", "annotationsDerived" }) |kind| {
                    run.addFileArg(.{ .cwd_relative = b.pathJoin(&.{ dir, kind, b.fmt("{s}.xml", .{code}) }) });
                }
            }
            const file = b.fmt("{s}.names", .{language.name});
            onto.file(b.fmt("locale/Emoji/{s}", .{file}), out.path(b, file));
        }
        onto.file("locale/Emoji/unicode.licence", .{ .cwd_relative = b.pathJoin(&.{ dir, "LICENSE" }) });
    }
    // DEVS:usb/firmware/aic8800/ - what an AIC8800 Wi-Fi stick's boot ROM
    // is given, as scripts/fetch-aic8800.sh fetched it. On the ESP32-P4's
    // disk alone: the stick needs a high-speed port. Not in DEVS:usb/
    // itself, where every file is looked at as a driver.
    if (aic8800Dir(b)) |dir| {
        disks.addChipDir(.esp32p4, "devs/usb/firmware");
        disks.addChipDir(.esp32p4, "devs/usb/firmware/aic8800");
        for (aic8800_files) |name| {
            disks.addChipFile(.esp32p4, b.fmt("devs/usb/firmware/aic8800/{s}", .{name}), .{ .cwd_relative = b.pathJoin(&.{ dir, name }) });
        }
    }
    // DEVS:firmware/wave511_dec_fw.bin - what the JH7110's video decoder
    // runs, which videodec.resource loads, as scripts/fetch-vpu.sh fetched
    // it - and Chips&Media's licence for it beside it. On the RISC-V 64
    // disk alone.
    if (vpuDir(b)) |dir| {
        make_rv64_disk.addArg("devs/firmware");
        make_rv64_disk.addPrefixedFileArg("devs/firmware/wave511_dec_fw.bin=", .{ .cwd_relative = b.pathJoin(&.{ dir, "wave511_dec_fw.bin" }) });
        make_rv64_disk.addPrefixedFileArg("devs/firmware/wave511.licence=", .{ .cwd_relative = b.pathJoin(&.{ dir, "LICENSE.txt" }) });
    }
    // DEVS:firmware/amdgpu/ - what an AMD graphics device's video decoder
    // runs and the table of contents its security processor is given
    // first, which amdgpu.resource loads, as scripts/fetch-amdgpu.sh
    // fetched them - and AMD's licence for them beside them. On the x86-64
    // disk alone.
    if (amdgpuDir(b)) |dir| {
        make_x64_disk.addArgs(&.{ "devs/firmware", "devs/firmware/amdgpu" });
        for ([_][]const u8{ "vcn_4_0_2.bin", "psp_13_0_4_toc.bin" }) |name| {
            make_x64_disk.addPrefixedFileArg(b.fmt("devs/firmware/amdgpu/{s}=", .{name}), .{ .cwd_relative = b.pathJoin(&.{ dir, name }) });
        }
        make_x64_disk.addPrefixedFileArg("devs/firmware/amdgpu.licence=", .{ .cwd_relative = b.pathJoin(&.{ dir, "LICENSE.amdgpu" }) });
    }
    // DEVS:networks/firmware/cyw43455/ - what the Raspberry Pi CM5's radio
    // runs, as scripts/fetch-cyw43455.sh fetched it. On the AArch64 disk
    // alone, whose networks/cyw43455.device loads it.
    if (cyw43455Dir(b)) |dir| {
        make_a64_disk.addArgs(&.{ "devs/networks/firmware", "devs/networks/firmware/cyw43455" });
        for (cyw43455_files) |name| {
            make_a64_disk.addPrefixedFileArg(b.fmt("devs/networks/firmware/cyw43455/{s}=", .{name}), .{ .cwd_relative = b.pathJoin(&.{ dir, name }) });
        }
    }
    // DEVS:pci.ids - the PCI ID Repository's list, which C:PCIInfo names
    // vendors and devices from, as scripts/fetch-pciids.sh fetched it. On
    // the disks with PCI, the RISC-V 64 and the AArch64 one.
    if (pciIdsFile(b)) |list| {
        make_rv64_disk.addPrefixedFileArg("devs/pci.ids=", .{ .cwd_relative = list });
        make_a64_disk.addPrefixedFileArg("devs/pci.ids=", .{ .cwd_relative = list });
        make_x64_disk.addPrefixedFileArg("devs/pci.ids=", .{ .cwd_relative = list });
    }
    // The icons, from the pictures scripts/fetch-icons.sh drew at the
    // board's size, when they are there. An icon whose picture is
    // missing - one the script gained since it last ran here - is left
    // out until it runs again.
    const icons = iconsDir(b, iconSize(board));
    if (icons) |dir| {
        for (disk_icons) |one| {
            const picture = b.pathJoin(&.{ dir, b.fmt("{s}.png", .{one.picture}) });
            std.Io.Dir.cwd().access(b.graph.io, picture, .{}) catch {
                std.log.info("no picture {s} (scripts/fetch-icons.sh): the disk has no {s}", .{ one.picture, one.path });
                continue;
            };
            const prefix = b.fmt("{s}=", .{one.path});
            const sized = for (one.fields) |field| {
                if (std.mem.eql(u8, field, icon_stack)) break true;
            } else false;
            if (!sized and one.pointer_bytes == null and one.chips == null) {
                disks.addFile(one.path, makeIcon(b, mkicon, picture, one, ""));
                continue;
            }
            // An icon that asks for a command's stack: made once for each
            // size of pointer, and each disk given its chip's - each disk
            // that has it.
            var by_width: [2]?std.Build.LazyPath = @splat(null);
            for (disks.runs, DiskImages.pointer_bytes, DiskImages.chips, disks.sets) |run, bytes, chip, sets| {
                if (!poweros_userland.onDisk(sets, one.path)) continue;
                if (one.pointer_bytes) |only| if (only != bytes) continue;
                if (one.chips) |only| if (std.mem.indexOfScalar(Chip, only, chip) == null) continue;
                const slot = &by_width[bytes / 8];
                if (slot.* == null) slot.* = makeIcon(b, mkicon, picture, one, iconStack(b, bytes));
                run.addPrefixedFileArg(prefix, slot.*.?);
            }
        }
    }
    // The `disk/` tree, and then -Dextra last, so that either may
    // replace a file the tree above put there.
    for (tree.files) |file| {
        disks.addPrefixedFileArg(b.fmt("{s}=", .{file.path}), b.path(file.host));
    }
    // QEMU's virt machines prefer the USB speaker their steps plug in
    // (`virtSpeaker`): their system disks' audio.prefs says so, and the
    // boards' disks keep the one above, which prefers none.
    for (disks.runs, DiskImages.virt_disks) |run, virt| {
        if (virt) run.addPrefixedFileArg("--gpt-file=prefs/env-archive/Sys/audio.prefs=", b.path("src/disk/prefs/virt/Sys/audio.prefs"));
    }
    for (extras) |extra| {
        const host: std.Build.LazyPath = .{ .cwd_relative = extra.host };
        for (disks.runs, DiskImages.chips, DiskImages.virt_disks) |run, chip, virt| {
            if (extra.only) |only| {
                if (only.contains(chip)) {
                    run.addPrefixedFileArg(b.fmt("{s}=", .{extra.path}), host);
                } else if (extra.system and virt) {
                    run.addPrefixedFileArg(b.fmt("--system-file={s}=", .{extra.path}), host);
                }
            } else run.addPrefixedFileArg(b.fmt("{s}=", .{extra.path}), host);
        }
    }
    // -Dgames: `games/` in the 64-bit disks' trees and on their system
    // disks, not in the image in RAM (mkfs's `--system-file`), its
    // drawers too, a program on its own chip's; and the drawer's icon,
    // since the volume's window shows only what has one.
    const games_icon: ?std.Build.LazyPath = if (games.len == 0) null else if (icons) |dir| icon: {
        const picture = b.pathJoin(&.{ dir, b.fmt("{s}.png", .{games_drawer_icon.picture}) });
        std.Io.Dir.cwd().access(b.graph.io, picture, .{}) catch {
            std.log.info("no picture {s} (scripts/fetch-icons.sh): the disk has no {s}", .{ games_drawer_icon.picture, games_drawer_icon.path });
            break :icon null;
        };
        break :icon makeIcon(b, mkicon, picture, games_drawer_icon, "");
    } else null;
    for (disks.runs, DiskImages.chips, DiskImages.virt_disks) |run, chip, virt| {
        if (!virt) continue;
        for (games) |game| {
            if (game.chip) |only| {
                if (only != chip) continue;
            }
            if (game.host) |host| {
                run.addPrefixedFileArg(b.fmt("--system-file={s}=", .{game.path}), b.path(host));
            } else run.addArg(b.fmt("--system-file={s}", .{game.path}));
        }
        if (games_icon) |icon| run.addPrefixedFileArg(b.fmt("--system-file={s}=", .{games_drawer_icon.path}), icon);
    }
    // A build installs its board's disk, and makes no other.
    if (flashDisk(flash_disks, board)) |image| b.getInstallStep().dependOn(&b.addInstallBinFile(image, flashDiskName(chipOf(board))).step);

    // The RISC-V 64 and AArch64 boards' flash disk is loaded into RAM
    // beside the kernel - by U-Boot's booti, or by QEMU's -initrd given
    // by hand - and is all the disk there is, so it is made as large as
    // the disk (`ram_disk_size`), the rest erased (tools/padimage).
    // QEMU's virt machines start from an NVMe SSD instead (`VirtDisks`).
    const padimage = b.addExecutable(.{
        .name = "padimage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/padimage.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const pad_rv64_disk = b.addRunArtifact(padimage);
    pad_rv64_disk.addFileArg(rv64_disk_made);
    const rv64_disk_bin = pad_rv64_disk.addOutputFileArg("disk-rv64.bin");
    pad_rv64_disk.addArg(b.fmt("{d}", .{ram_disk_size}));
    // The virt machine's system disk too, for QEMU run by hand.
    if (board == .qemu_virt) b.getInstallStep().dependOn(&b.addInstallBinFile(rv64_system_disk, "system-rv64.bin").step);
    if (chipOf(board) == .rv64sbi) {
        b.getInstallStep().dependOn(&b.addInstallBinFile(rv64_disk_bin, "disk-rv64.bin").step);
        b.getInstallStep().dependOn(&b.addInstallBinFile(rv64_manifest, "disk-rv64.manifest").step);
        b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = rv64_tree,
            .install_dir = .prefix,
            .install_subdir = "disk-rv64",
        }).step);
    }
    const pad_a64_disk = b.addRunArtifact(padimage);
    pad_a64_disk.addFileArg(a64_disk_made);
    const a64_disk_bin = pad_a64_disk.addOutputFileArg("disk-a64.bin");
    pad_a64_disk.addArg(b.fmt("{d}", .{ram_disk_size}));
    if (board == .qemu_virt_a64) b.getInstallStep().dependOn(&b.addInstallBinFile(a64_system_disk, "system-a64.bin").step);
    if (chipOf(board) == .a64psci) {
        b.getInstallStep().dependOn(&b.addInstallBinFile(a64_disk_bin, "disk-a64.bin").step);
        b.getInstallStep().dependOn(&b.addInstallBinFile(a64_manifest, "disk-a64.manifest").step);
        b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = a64_tree,
            .install_dir = .prefix,
            .install_subdir = "disk-a64",
        }).step);
    }
    const pad_x64_disk = b.addRunArtifact(padimage);
    pad_x64_disk.addFileArg(x64_disk_made);
    const x64_disk_bin = pad_x64_disk.addOutputFileArg("disk-x64.bin");
    pad_x64_disk.addArg(b.fmt("{d}", .{ram_disk_size}));
    const pad_x64_medium = b.addRunArtifact(padimage);
    pad_x64_medium.addFileArg(x64_medium_made);
    const x64_medium_bin = pad_x64_medium.addOutputFileArg("disk-x64.bin");
    pad_x64_medium.addArg(b.fmt("{d}", .{ram_disk_size}));
    if (board == .qemu_q35) b.getInstallStep().dependOn(&b.addInstallBinFile(x64_system_disk, "system-x64.bin").step);
    if (chipOf(board) == .x64uefi) {
        b.getInstallStep().dependOn(&b.addInstallBinFile(x64_disk_bin, "disk-x64.bin").step);
        b.getInstallStep().dependOn(&b.addInstallBinFile(x64_manifest, "disk-x64.manifest").step);
        b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = x64_tree,
            .install_dir = .prefix,
            .install_subdir = "disk-x64",
        }).step);
    }
    return .{
        .a64_disk_bin = a64_disk_bin,
        .a64_system_disk = a64_system_disk,
        .a64_tree = a64_tree,
        .disks = disks,
        .flash_disks = flash_disks,
        .make_a64_disk = make_a64_disk,
        .make_rv64_disk = make_rv64_disk,
        .make_x64_disk = make_x64_disk,
        .rv64_disk_bin = rv64_disk_bin,
        .rv64_system_disk = rv64_system_disk,
        .rv64_tree = rv64_tree,
        .tree = tree,
        .x64_disk_bin = x64_disk_bin,
        .x64_medium_bin = x64_medium_bin,
        .x64_system_disk = x64_system_disk,
        .x64_tree = x64_tree,
    };
}
