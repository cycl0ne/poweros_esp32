// SPDX-License-Identifier: MPL-2.0
const std = @import("std");
const poweros_sdk = @import("poweros_sdk");
const poweros_userland = @import("poweros_userland");

/// The flash chip every board has (16 MiB), and the flash disk on it:
/// flash.device's unit 0 starts at `-Ddisk-offset` and runs to the end of
/// the chip, with 4 KiB erase sectors and 256-byte pages
/// (src/rom/devs/flash/esp32s3/spiflash.zig). The build needs the numbers to make
/// a disk image and to put it in the right place, and hands the offset to
/// the kernel, whose boards give it to flash.device as SYSTAG_DiskOffset.
const flash_size = 16 * 1024 * 1024;
/// Where the disk starts unless `-Ddisk-offset` says otherwise, in KiB:
/// the kernel image starts at offset 0 and has this much room to grow in.
const default_disk_offset_kib = 2048;
/// The host ports qemu-display forwards to the machine's Telnet port, 23,
/// and its SSH port, 22.
const display_telnet_port: u16 = 2323;
const display_ssh_port: u16 = 2222;
/// An MMU page: the disk's start has to be one, since flash.device maps
/// the disk into the data window a page at a time.
const mmu_page = 64 * 1024;
const disk_sector = 4096;
const disk_page = 256;
/// The flash disk's table area before DH0 unless `-Drdb-size` says
/// otherwise, in KiB: the RigidDiskBlock, the PartitionBlocks, and room
/// for the file systems kept in the table (tools/mkfs's `rdb-sectors`).
const default_rdb_size_kib = 64;
/// The disks of QEMU's virt machines, NVMe SSDs with a GPT and posfs on
/// them: the system disk, DH0:, made afresh by every build and started
/// from as it is - what a run writes to it goes with the run - and the
/// work disk, DH1:, made blank once and kept from then on with what is
/// saved to it.
const virt_system_bytes = 256 * 1024 * 1024;
const virt_work_bytes = 1024 * 1024 * 1024;
/// Where the work disks are kept, from the root of the tree: outside
/// zig-out/, which cleaning the build clears.
const virt_work_dir = "work";

/// Where a file that is not built here is put to have it on the disk
/// image: `disk/` in the root of the tree.
const disk_tree = "disk";

/// Where games built elsewhere are put to have them on the virt
/// machines' system disks with -Dgames: `games/` in the root of the tree,
/// which is the disks' `Games` drawer.
const games_tree = "games";
const games_drawer = "Games";
const games_drawer_icon: DiskIcon = .{ .path = games_drawer ++ ".info", .picture = "applications-games", .fields = &.{"KIND=DRAWER"} };

/// The boards there is a description for (src/boards/). One kernel image
/// is built per board. `qemu` is Espressif QEMU's machine, with its
/// virtual display, keyboard and mouse: the `qemu*` steps always run that
/// one, whichever board `-Dboard` names. `qemu_virt` is upstream QEMU's
/// RISC-V 64 `virt` machine under OpenSBI, which the `virt` step runs;
/// `visionfive2` is StarFive's JH7110 board, booted from U-Boot.
/// `qemu_virt_a64` is upstream QEMU's AArch64 `virt` machine with
/// Cortex-A76 cores and a GICv2, which the `virt64` steps run;
/// `rpi_cm5` is the Raspberry Pi Compute Module 5, booted from its eMMC.
const Board = enum { waveshare_7b, es3c35p, qemu, esp32p4_emu, olimex_p4pc, crowpanel_p4, qemu_virt, visionfive2, qemu_virt_a64, rpi_cm5 };

/// The chip a board is built on, which picks the kernel's target, its
/// root, start code and linker script, and how its image is made.
const Chip = poweros_sdk.Chip;

fn chipOf(board: Board) Chip {
    return switch (board) {
        .waveshare_7b, .es3c35p, .qemu => .esp32s3,
        .esp32p4_emu, .olimex_p4pc, .crowpanel_p4 => .esp32p4,
        .qemu_virt, .visionfive2 => .rv64sbi,
        .qemu_virt_a64, .rpi_cm5 => .a64psci,
    };
}

/// The ROM modules' strings in other languages: what dos.library's faults
/// say once locale.library stands in front of Fault.
const rom_catalogs = [_]poweros_userland.Catalog{
    .{ .disk = "locale/Catalogs/deutsch/sys/dos.catalog", .descriptor = "src/rom/libs/dos/text/dos.cd", .translation = "src/rom/libs/dos/text/catalogs/deutsch.ct", .name = "sys/dos.catalog" },
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
    // SYS:Programs - programs with windows, off the command path, and
    // in Docs what each of them is.
    "programs",
    "programs/Docs",
    // SYS:WBStartup - the programs the desktop starts as it comes up,
    // empty until some are put there.
    "WBStartup",
    // SYS:System - the system's own tools: Shell, which the desktop's
    // own icons start, HDToolBox, CPULoad, NetLoad and MemMap; in Docs
    // what each of the others is.
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
};

/// An icon the build writes onto the image: where it goes, the picture
/// scripts/fetch-icons.sh drew for it, its fields as tools/mkicon takes
/// them, and - for an icon only some disks have - the pointer size of the
/// chips whose disks have it.
const DiskIcon = struct { path: []const u8, picture: []const u8, fields: []const []const u8 = &.{}, pointer_bytes: ?u32 = null };

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
    // The dock: on the ESP32s in SYS:Programs, started by hand; on the
    // 64-bit machines in SYS:WBStartup, started with the desktop, which
    // does not wait for it to end.
    .{ .path = "programs/Dock.info", .picture = "preferences-desktop", .fields = &.{ "KIND=TOOL", icon_stack }, .pointer_bytes = 4 },
    .{ .path = "WBStartup/Dock.info", .picture = "preferences-desktop", .fields = &.{ "KIND=TOOL", icon_stack, "TYPE=DONOTWAIT" }, .pointer_bytes = 8 },
    // What each program is, in SYS:Programs/Docs: read in MultiView.
    .{ .path = "programs/Docs.info", .picture = "folder", .fields = &.{"KIND=DRAWER"} },
    .{ .path = "programs/Docs/Battery.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "programs/Docs/Dock.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "programs/Docs/FontView.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "programs/Docs/MultiView.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
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
    .{ .path = "System/Docs.info", .picture = "folder", .fields = &.{"KIND=DRAWER"} },
    .{ .path = "System/Docs/CPULoad.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "System/Docs/NetLoad.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "System/Docs/HDToolBox.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    .{ .path = "System/Docs/MemMap.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
    // The commodities, each icon with the tool types it reads, and what
    // each is in SYS:Commodities/Docs.
    .{ .path = "Commodities/Exchange.info", .picture = "preferences-desktop-keyboard-shortcuts", .fields = &.{ "KIND=TOOL", icon_stack, "TYPE=CX_PRIORITY=0", "TYPE=CX_POPKEY=ctrl alt home", "TYPE=CX_POPUP=YES" } },
    .{ .path = "Commodities/Docs.info", .picture = "folder", .fields = &.{"KIND=DRAWER"} },
    .{ .path = "Commodities/Docs/Exchange.md.info", .picture = "x-office-document", .fields = &.{ "KIND=PROJECT", "TOOL=SYS:Programs/MultiView", icon_stack } },
};

/// The size the desktop shows icons at on a board's screen - an eighth of
/// its height, at most 48 (the screens are in src/boards/<board>/
/// system.zig) - so the disk's pictures are drawn at it, not shrunk on
/// the board.
fn iconSize(board: Board) u32 {
    return switch (board) {
        // 1024x600
        .waveshare_7b, .qemu => 48,
        // 480x320
        .es3c35p => 40,
        // No screen yet.
        .esp32p4_emu, .olimex_p4pc, .crowpanel_p4, .qemu_virt, .visionfive2, .qemu_virt_a64, .rpi_cm5 => 48,
    };
}

pub fn build(b: *std.Build) void {
    // ReleaseSmall currently trips over a compiler_rt symbol bug in the
    // Espressif Zig build, and Debug does not fit into IRAM, so default to
    // ReleaseSafe (ReleaseFast works as well).
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseSafe)") orelse .ReleaseSafe;
    const esptool = b.option([]const u8, "esptool", "esptool executable (default: ESP-IDF's, else esptool from PATH)") orelse findEsptool(b);
    const qemu = b.option([]const u8, "qemu", "Espressif qemu-system-xtensa executable") orelse findQemu(b);
    const port = b.option([]const u8, "port", "Serial port used by `zig build flash`") orelse "/dev/ttyACM0";
    const baud = b.option([]const u8, "baud", "Baud rate used by `zig build flash`") orelse "921600";
    const board = b.option(Board, "board", "The board the kernel is built for (default: waveshare_7b)") orelse .waveshare_7b;
    const dh0_size_kib = b.option(u32, "dh0-size", "DH0:'s size in KiB, a multiple of 4; the rest of the flash disk is left for partitions made later with C:RDB ADD (default: all of it)") orelse 0;
    const disk_offset_kib = b.option(u32, "disk-offset", "Where the flash disk starts, in KiB: a multiple of 64 (default: 2048)") orelse default_disk_offset_kib;
    const rdb_size_kib = b.option(u32, "rdb-size", "The flash disk's partition table area before DH0:, in KiB, a multiple of 4 and 64 at least: room for more partitions and for file systems kept in the table (default: 64)") orelse default_rdb_size_kib;
    const cores = b.option(u32, "cores", "How many cores the kernel runs on, 1 or 2 - up to 4 on a RISC-V 64 or AArch64 board (default: what the board's SYSTAG_Cores says)") orelse 0;
    const selftest = b.option(bool, "selftest", "ESP32-P4: the boot task checks the chip and runs test tasks instead of the shell (default: false)") orelse false;
    const memdebug = b.option(bool, "memdebug", "Memory debugging on from exec's start: walls behind blocks, patterns in new and freed memory, wide stack guards (default: false; s3> memdebug and C:MemDebug switch it at run time)") orelse false;
    const posfs_soak = b.option(u32, "posfs-soak", "`zig build test`: run posfs's power-cut test on this many more seeds, each on flash, a card and a stick (default: 0)") orelse 0;
    const most_cores: u32 = switch (chipOf(board)) {
        .rv64sbi, .a64psci => 4,
        .esp32s3, .esp32p4 => 2,
    };
    if (cores > most_cores) std.debug.panic("-Dcores={d}: this chip has {d} cores", .{ cores, most_cores });
    const net = b.option([]const u8, "net", "The network of the qemu steps and the virt display steps: none, or a QEMU network backend such as tap,ifname=tap0,script=no,downscript=no (default: QEMU's user network)");
    const net_dump = b.option([]const u8, "net-dump", "Write every frame of the qemu and virt display steps' network to this pcap file");
    const wifi = wifiDir(b, b.option([]const u8, "wifi", "The radio's vendor libraries for esp32s3wifi.device (default: toolchain/espressif-wifi, which scripts/fetch-wifi.sh fills)"));
    const telnet = b.option(u16, "telnet", "Forward this host port to the machine's port 23 (C:net/ShellServer) on the qemu and virt display steps' user network; qemu-display forwards 2323 unless given, and 0 forwards none");
    const ssh_port = b.option(u16, "ssh", "Forward this host port to the machine's port 22 (C:net/ShellServer SSH) on the qemu and virt display steps' user network; qemu-display forwards 2222 unless given, and 0 forwards none");
    const network = qemuNetwork(b, net, net_dump, telnet, ssh_port);
    const virt_network = virtNetwork(b, net, net_dump, telnet, ssh_port);
    const rs485 = b.option([]const u8, "rs485", "Give the qemu steps' RS-485 port (UART1, rs485.device) to this QEMU serial backend, such as tcp::5020,server,nowait or a pty");
    const slip_line = b.option([]const u8, "slip", "Give the qemu steps' UART1 (serial.device unit 1, a SLIP line) to this QEMU serial backend, such as tcp::5021,server,nowait; not with -Drs485");
    if (rs485 != null and slip_line != null) std.debug.panic("-Drs485 and -Dslip: both are UART1", .{});
    // UART1's backend: the RS-485 port's or a SLIP line's.
    const uart1 = rs485 orelse slip_line;
    const usb_devices = b.option([]const u8, "usb", "Plug these QEMU USB devices into the qemu steps' USB port, comma-separated (usb-hub,usb-kbd,usb-mouse); an item with '=' is a property of the device before it (usb-kbd,port=1,id=kbd)");
    const virt_speaker = virtSpeaker(b, b.option([]const u8, "audio", "The virt and virt64 steps' USB speaker on this QEMU audio backend - an -audiodev's driver and options: pa, pipewire, alsa, sdl, none, wav,path=out.wav (default: QEMU's own choice among the backends it has)"));
    const virt_ui = b.option([]const u8, "virt-ui", "QEMU's -display for the virt and virt64 display steps (default: gtk,show-cursor=off,zoom-to-fit=off - GTK's window at the picture's size, 1:1; default,show-cursor=off takes SDL, or VNC, where there is no GTK)") orelse "gtk,show-cursor=off,zoom-to-fit=off";
    const usb_disk = b.option([]const u8, "usb-disk", "Plug a USB stick into the qemu steps' USB port whose blocks are this raw image file (-snapshot runs keep it unchanged)");
    const usb = qemuUsb(b, usb_devices, usb_disk);
    // The display is the one a person sits at: `telnet localhost 2323`
    // and `ssh -p 2222 localhost` reach a ShellServer in it without asking
    // for the port.
    const display_network = qemuNetwork(b, net, net_dump, telnet orelse display_telnet_port, ssh_port orelse display_ssh_port);
    const disk_offset = disk_offset_kib * 1024;
    if (disk_offset % mmu_page != 0 or disk_offset == 0 or disk_offset >= flash_size) {
        std.debug.panic("-Ddisk-offset={d}: the disk has to start on a 64 KiB page inside the {d} KiB of flash", .{ disk_offset_kib, flash_size / 1024 });
    }
    const disk_size = flash_size - disk_offset;
    // The table's area, in whole sectors, every block a RigidDiskBlock may
    // be in at least.
    const disk_rdb_blocks: u32 = rdb_size_kib * 1024 / disk_sector;
    if (rdb_size_kib * 1024 % disk_sector != 0 or disk_rdb_blocks < 16 or disk_rdb_blocks + 2 > disk_size / disk_sector) {
        std.debug.panic("-Drdb-size={d}: the table's area has to be whole {d} KiB sectors, 64 KiB at least, within the {d} KiB of the disk", .{ rdb_size_kib, disk_sector / 1024, disk_size / 1024 });
    }
    // DH0: after the RDB's blocks: all of the disk past them, or what
    // -Ddh0-size asks for.
    const dh0_sectors: u32 = dh0_size_kib * 1024 / disk_sector;
    if (dh0_size_kib * 1024 % disk_sector != 0 or (dh0_size_kib != 0 and dh0_sectors + disk_rdb_blocks > disk_size / disk_sector)) {
        std.debug.panic("-Ddh0-size={d}: DH0: has to be whole {d} KiB sectors within the {d} KiB the disk has past its RDB", .{ dh0_size_kib, disk_sector / 1024, disk_size / 1024 - disk_rdb_blocks * disk_sector / 1024 });
    }

    const target = b.resolveTargetQuery(poweros_sdk.target_query);
    const p4_target = b.resolveTargetQuery(poweros_sdk.p4_target_query);
    const rv64_target = b.resolveTargetQuery(poweros_sdk.rv64_target_query);
    const a64_target = b.resolveTargetQuery(poweros_sdk.a64_target_query);
    const kernel_target = switch (chipOf(board)) {
        .esp32s3 => target,
        .esp32p4 => p4_target,
        .rv64sbi => rv64_target,
        .a64psci => a64_target,
    };

    // The SDK (sdk/, a package of its own): the system's types and the
    // libraries' jump tables, and how a program is built. The kernel builds
    // against it like any program does.
    const sdk_dep = b.dependency("poweros_sdk", .{});
    const sdk = sdk_dep.module("sdk");
    const kernel = addKernel(b, kernel_target, optimize, sdk, board, disk_offset, cores, selftest, memdebug);

    // What goes on the disk (src/disk, a package of its own): the
    // commands, the test programs, the modules loaded from LIBS:, DEVS:
    // and HANDLERS:, and the scripts, each built against the SDK and
    // handed over under its place on the disk. Their load files are
    // installed beside the kernel as well, to compare with `List C:`.
    const disk_dep = if (wifi) |dir|
        b.dependency("poweros_userland", .{ .optimize = optimize, .wifi = dir })
    else
        b.dependency("poweros_userland", .{ .optimize = optimize });
    for (poweros_userland.programs) |program| {
        if (!poweros_userland.builtFor(program, .esp32s3)) continue;
        const load_file = b.fmt("{s}.seg", .{program.name});
        b.getInstallStep().dependOn(&b.addInstallBinFile(disk_dep.namedLazyPath(program.disk), load_file).step);
    }
    if (wifi != null) {
        const wifi_device = poweros_userland.wifi_device;
        b.getInstallStep().dependOn(&b.addInstallBinFile(disk_dep.namedLazyPath(wifi_device.disk), "esp32s3wifi.device.seg").step);
    }

    // The disk image: the same file system code the handler runs
    // (src/rom/handler/flashfs as a module of its own), driven on the host
    // over a block of memory. Its numbers must be the ones flash.device
    // reports: the disk area of src/layout.zig, 4 KiB sectors, 256-byte
    // pages.
    const fs_mod = b.createModule(.{
        .root_source_file = b.path("src/rom/handler/flashfs/disk.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    fs_mod.addImport("sdk", sdk);
    const mkfs = b.addExecutable(.{
        .name = "mkfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkfs/mkfs.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    mkfs.root_module.addImport("sdk", sdk);
    mkfs.root_module.addImport("fs", fs_mod);
    // tools/posfsck, the handler's check of a posfs volume run on an
    // image: `zig build posfsck -- [--data] <image>`, or without the
    // arguments installed as zig-out/bin/posfsck. The check is the
    // handler's own code (src/disk/devs/handlers/posfs as a module of its
    // own).
    const posfs_mod = b.createModule(.{
        .root_source_file = b.path("src/disk/devs/handlers/posfs/fs.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    posfs_mod.addImport("sdk", sdk);
    // mkfs writes posfs with the same code, on a disk with a GPT.
    mkfs.root_module.addImport("posfs", posfs_mod);
    const posfsck = b.addExecutable(.{
        .name = "posfsck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/posfsck/posfsck.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    posfsck.root_module.addImport("sdk", sdk);
    posfsck.root_module.addImport("posfs", posfs_mod);
    const posfsck_step = b.step("posfsck", "Check the posfs volumes of an image (zig build posfsck -- [--data] <image>)");
    if (b.args) |given| {
        const run_posfsck = b.addRunArtifact(posfsck);
        run_posfsck.addArgs(given);
        posfsck_step.dependOn(&run_posfsck.step);
    } else posfsck_step.dependOn(&b.addInstallArtifact(posfsck, .{}).step);

    // audio.device's mixer on the host: `audio-golden` writes the golden
    // mix's reference file again (src/rom/devs/audio/golden.zig, whose
    // test holds the mixer to it), and `audio-bench` says how fast the
    // mixer is - on stderr, which a test may not write to.
    const golden_mod = b.createModule(.{
        .root_source_file = b.path("src/rom/devs/audio/golden.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const audiogolden = b.addExecutable(.{
        .name = "audiogolden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/audio/audiogolden.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    audiogolden.root_module.addImport("golden", golden_mod);
    const write_golden = b.addRunArtifact(audiogolden);
    write_golden.addArg(b.pathFromRoot("src/rom/devs/audio/golden.pcm"));
    write_golden.has_side_effects = true;
    b.step("audio-golden", "Write audio.device's golden mix again (src/rom/devs/audio/golden.pcm)").dependOn(&write_golden.step);
    const audiobench = b.addExecutable(.{
        .name = "audiobench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/audio/audiobench.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    audiobench.root_module.addImport("golden", golden_mod);
    const run_bench = b.addRunArtifact(audiobench);
    run_bench.has_side_effects = true;
    b.step("audio-bench", "Time audio.device's mixer on the host for 1, 4, 8 and 16 voices").dependOn(&run_bench.step);

    // graphics.library's software drawing on the host, as the tests stand
    // it up: `gfx-bench` says what each kind of call costs, to compare one
    // change of the drawing loops with the one before. A test binary,
    // since exec stands on the host only in one, run as a program so that
    // it may print.
    const gfxbench_mod = b.createModule(.{
        .root_source_file = b.path("src/gfxbench.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    gfxbench_mod.addImport("sdk", sdk);
    const gfxbench = b.addTest(.{ .name = "gfxbench", .root_module = gfxbench_mod, .filters = &.{"gfx-bench"} });
    const run_gfxbench = std.Build.Step.Run.create(b, "run gfxbench");
    run_gfxbench.addArtifactArg(gfxbench);
    run_gfxbench.has_side_effects = true;
    b.step("gfx-bench", "Time graphics.library's software drawing on the host, in RGB565 and BGRA32").dependOn(&run_gfxbench.step);

    // tools/mkicon, which makes the disk's icons from pictures.
    const mkicon = b.addExecutable(.{
        .name = "mkicon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkicon/mkicon.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    mkicon.root_module.addImport("sdk", sdk);

    // What goes on the image besides the build's own outputs: the
    // `disk/` tree, then -Dextra. `made` is the directories the image
    // already has, so that none is asked for twice - which mkfs refuses.
    var made: std.ArrayList([]const u8) = .empty;
    made.appendSlice(b.allocator, &image_dirs) catch @panic("OOM");
    const tree = diskTree(b, &made);
    const extras = extraFiles(b, &made);
    const games = gamesTree(b, &made);

    // Four images from one recipe: the ESP32-S3's, the ESP32-P4's, the
    // RISC-V 64 machines' and the AArch64 machines', which differ only in
    // their programs' load files.
    const make_disk = b.addRunArtifact(mkfs);
    const disk_bin = make_disk.addOutputFileArg("disk.bin");
    const make_p4_disk = b.addRunArtifact(mkfs);
    const p4_disk_bin = make_p4_disk.addOutputFileArg("disk-esp32p4.bin");
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
    const disks: DiskImages = .{ .runs = .{ make_disk, make_p4_disk, make_rv64_disk, make_a64_disk } };
    const p4_disk_dep = b.dependency("poweros_userland", .{ .optimize = optimize, .chip = Chip.esp32p4 });
    const rv64_disk_dep = b.dependency("poweros_userland", .{ .optimize = optimize, .chip = Chip.rv64sbi });
    const a64_disk_dep = b.dependency("poweros_userland", .{ .optimize = optimize, .chip = Chip.a64psci });
    disks.addArgs(&.{
        "System",
        "DH0",
        b.fmt("{d}", .{disk_size / disk_sector}),
        b.fmt("{d}", .{dh0_sectors}),
        b.fmt("{d}", .{disk_sector}),
        b.fmt("{d}", .{disk_page}),
        b.fmt("{d}", .{disk_rdb_blocks}),
    });
    disks.addArgs(&image_dirs);
    // The directories those files need, made before anything goes in
    // them: mkfs takes its paths in the order they are given.
    disks.addArgs(tree.dirs);
    for (extras) |extra| disks.addArgs(extra.dirs);
    for (poweros_userland.programs) |program| {
        if (poweros_userland.builtFor(program, .esp32s3)) {
            make_disk.addPrefixedFileArg(b.fmt("{s}=", .{program.disk}), disk_dep.namedLazyPath(program.disk));
        }
        if (poweros_userland.builtFor(program, .esp32p4)) {
            make_p4_disk.addPrefixedFileArg(b.fmt("{s}=", .{program.disk}), p4_disk_dep.namedLazyPath(program.disk));
        }
        if (poweros_userland.builtFor(program, .rv64sbi)) {
            make_rv64_disk.addPrefixedFileArg(b.fmt("{s}=", .{program.disk}), rv64_disk_dep.namedLazyPath(program.disk));
        }
        if (poweros_userland.builtFor(program, .a64psci)) {
            make_a64_disk.addPrefixedFileArg(b.fmt("{s}=", .{program.disk}), a64_disk_dep.namedLazyPath(program.disk));
        }
    }
    for (poweros_userland.files) |file| {
        disks.addPrefixedFileArg(b.fmt("{s}=", .{file.disk}), disk_dep.namedLazyPath(file.disk));
    }
    // The programs' catalogs, and the ROM modules' own.
    for (poweros_userland.catalogs) |catalog| {
        disks.addPrefixedFileArg(b.fmt("{s}=", .{catalog.disk}), disk_dep.namedLazyPath(catalog.disk));
    }
    for (rom_catalogs) |catalog| {
        const catalog_file = poweros_sdk.addCatalog(b, sdk_dep, b.path(catalog.descriptor), b.path(catalog.translation), catalog.name);
        disks.addPrefixedFileArg(b.fmt("{s}=", .{catalog.disk}), catalog_file);
    }
    // The chips' own versions after the shared ones, which they replace
    // on their images.
    for (poweros_userland.mac_files ++ poweros_userland.p4_files) |file| {
        make_p4_disk.addPrefixedFileArg(b.fmt("{s}=", .{file.disk}), p4_disk_dep.namedLazyPath(file.source));
    }
    for (poweros_userland.mac_files) |file| {
        make_rv64_disk.addPrefixedFileArg(b.fmt("{s}=", .{file.disk}), rv64_disk_dep.namedLazyPath(file.source));
    }
    for (poweros_userland.a64_files) |file| {
        make_a64_disk.addPrefixedFileArg(b.fmt("{s}=", .{file.disk}), a64_disk_dep.namedLazyPath(file.source));
    }
    if (wifi != null) {
        const wifi_device = poweros_userland.wifi_device;
        make_disk.addPrefixedFileArg(b.fmt("{s}=", .{wifi_device.disk}), disk_dep.namedLazyPath(wifi_device.disk));
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
        for (disk_fonts) |family| {
            const run = b.addRunArtifact(fontconv);
            const out = run.addOutputDirectoryArg(family.name);
            run.addArg(family.name);
            run.addArgs(family.options);
            for (family.sources) |source| run.addFileArg(.{ .cwd_relative = b.pathJoin(&.{ dir, source }) });
            disks.addArg(b.fmt("fonts/{s}", .{family.name}));
            disks.addPrefixedFileArg(b.fmt("fonts/{s}.font=", .{family.name}), out.path(b, b.fmt("{s}.font", .{family.name})));
            for (family.sizes) |rows| {
                const size = b.fmt("{s}/{d}", .{ family.name, rows });
                disks.addPrefixedFileArg(b.fmt("fonts/{s}=", .{size}), out.path(b, size));
            }
            for (family.outlines) |file| {
                const at = b.fmt("{s}/{s}", .{ family.name, file });
                disks.addPrefixedFileArg(b.fmt("fonts/{s}=", .{at}), out.path(b, at));
            }
        }
        disks.addPrefixedFileArg("fonts/spleen.licence=", .{ .cwd_relative = b.pathJoin(&.{ dir, "spleen-2.2.0/LICENSE" }) });
        disks.addPrefixedFileArg("fonts/go.licence=", .{ .cwd_relative = b.pathJoin(&.{ dir, "go/README" }) });
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
        disks.addArg("certificates");
        disks.addPrefixedFileArg("certificates/roots=", store);
    }
    // DEVS:usb/firmware/aic8800/ - what an AIC8800 Wi-Fi stick's boot ROM
    // is given, as scripts/fetch-aic8800.sh fetched it. On the ESP32-P4's
    // disk alone: the stick needs a high-speed port. Not in DEVS:usb/
    // itself, where every file is looked at as a driver.
    if (aic8800Dir(b)) |dir| {
        make_p4_disk.addArgs(&.{ "devs/usb/firmware", "devs/usb/firmware/aic8800" });
        for (aic8800_files) |name| {
            make_p4_disk.addPrefixedFileArg(b.fmt("devs/usb/firmware/aic8800/{s}=", .{name}), .{ .cwd_relative = b.pathJoin(&.{ dir, name }) });
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
            if (!sized and one.pointer_bytes == null) {
                disks.addPrefixedFileArg(prefix, makeIcon(b, mkicon, picture, one, ""));
                continue;
            }
            // An icon that asks for a command's stack: made once for each
            // size of pointer, and each disk given its chip's - each disk
            // that has it.
            var by_width: [2]?std.Build.LazyPath = @splat(null);
            for (disks.runs, DiskImages.pointer_bytes) |run, bytes| {
                if (one.pointer_bytes) |only| if (only != bytes) continue;
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
                } else if (extra.virt and virt) {
                    run.addPrefixedFileArg(b.fmt("--gpt-file={s}=", .{extra.path}), host);
                }
            } else run.addPrefixedFileArg(b.fmt("{s}=", .{extra.path}), host);
        }
    }
    // -Dgames: `games/` on the virt machines' system disks alone, its
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
                run.addPrefixedFileArg(b.fmt("--gpt-file={s}=", .{game.path}), b.path(host));
            } else run.addArg(b.fmt("--gpt-file={s}", .{game.path}));
        }
        if (games_icon) |icon| run.addPrefixedFileArg(b.fmt("--gpt-file={s}=", .{games_drawer_icon.path}), icon);
    }
    b.getInstallStep().dependOn(&b.addInstallBinFile(disk_bin, "disk.bin").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(p4_disk_bin, "disk-esp32p4.bin").step);

    // The RISC-V 64 and AArch64 boards' flash disk is loaded into RAM
    // beside the kernel - by U-Boot's booti, or by QEMU's -initrd given
    // by hand - and is all the disk there is, so it is made as large as
    // the disk, the rest erased (tools/padimage). QEMU's virt machines
    // start from an NVMe SSD instead (`VirtDisks`).
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
    pad_rv64_disk.addArg(b.fmt("{d}", .{disk_size}));
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
    pad_a64_disk.addArg(b.fmt("{d}", .{disk_size}));
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

    // After linking: every ROM tag's module size into the kernel's
    // resident_sizes table (the shell's `residents` shows them).
    const ressize = b.addExecutable(.{
        .name = "ressize",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/ressize.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    // The ESP32-P4's ROM-loaded part of the kernel image, cut from the
    // whole one.
    const ramimage = b.addExecutable(.{
        .name = "ramimage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/ramimage.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const built = switch (chipOf(board)) {
        .esp32s3 => addImage(b, esptool, ressize, kernel, disk_bin, disk_offset),
        .esp32p4 => addP4Image(b, esptool, ramimage, kernel, p4_disk_bin, disk_offset),
        .rv64sbi => addRv64Image(b, kernel),
        .a64psci => addA64Image(b, kernel),
    };
    const image = built.image;
    b.getInstallStep().dependOn(&b.addInstallBinFile(built.kernel_elf, "kernel").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(image, "kernel.bin").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(built.flash_image, "flash.bin").step);
    // Only the board's own: the emulator's image is made beside it on
    // every build, and the two parts must not share the name.
    if (built.flash_part) |part| b.getInstallStep().dependOn(&b.addInstallBinFile(part, "kernel-flash.bin").step);

    // The emulator is a board of its own: the `qemu*` steps run its image,
    // with the same disk.
    const emulated = if (board == .qemu) built else addImage(b, esptool, ressize, addKernel(b, target, optimize, sdk, .qemu, disk_offset, cores, false, memdebug), disk_bin, disk_offset);
    const flash_image = emulated.flash_image;

    const run_qemu = qemuRun(b, qemu, flash_image, network, usb, qemuConsole(b, &.{"-nographic"}, uart1));
    b.step("qemu", "Boot the kernel in Espressif QEMU (quit with Ctrl-A X)").dependOn(&run_qemu.step);

    const run_display = qemuRun(b, qemu, flash_image, display_network, usb, qemuConsole(b, &.{ "-display", "sdl,show-cursor=off" }, uart1));
    b.step("qemu-display", "Boot in QEMU with its virtual display in an SDL window").dependOn(&run_display.step);

    // The same, but on a flash image that keeps what the kernel writes:
    // `qemu` runs with -snapshot and flash.bin is built afresh every time,
    // so neither survives a run. This one puts the current kernel at offset
    // 0 of a copy that stays, exactly as `zig build flash` does to the
    // board, and leaves the disk area (-Ddisk-offset on) alone.
    const disk_image = "zig-out/bin/qemu-flash.bin";
    const keep_disk = b.fmt(
        \\if [ ! -f "$0" ]; then
        \\  head -c 16777216 /dev/zero | tr '\000' '\377' > "$0"
        \\  dd if="$2" of="$0" bs={d} seek={d} conv=notrunc status=none
        \\fi
        \\dd if="$1" of="$0" conv=notrunc status=none
    , .{ disk_sector, disk_offset / disk_sector });
    const keep = b.addSystemCommand(&.{ "sh", "-c", keep_disk, disk_image });
    keep.addFileArg(emulated.image);
    keep.addFileArg(disk_bin);
    keep.has_side_effects = true;
    const run_disk = qemuRunPath(b, qemu, .{ .cwd_relative = disk_image }, false, network, usb, qemuConsole(b, &.{"-nographic"}, uart1));
    run_disk.step.dependOn(&keep.step);
    b.step("qemu-disk", "Boot in QEMU on a flash image that keeps what is written to the disk").dependOn(&run_disk.step);

    // The ESP32-P4 in esp-emulator (scripts/fetch-esp-emu.sh), a board of
    // its own: the `emu` step runs its image on the boards' v1.x ROM.
    const p4_emulated = if (board == .esp32p4_emu) built else addP4Image(b, esptool, ramimage, addKernel(b, p4_target, optimize, sdk, .esp32p4_emu, disk_offset, cores, selftest, memdebug), p4_disk_bin, disk_offset);
    const run_emu = b.addSystemCommand(&.{
        b.pathFromRoot("toolchain/esp-emu/esp-emu"), "--chip",                                                 "esp32p4",
        "--rom",                                     b.pathFromRoot("toolchain/esp-emu/esp32p4_rev0_rom.elf"), "--psram-size",
        "32M",                                       "--net",                                                  "user",
        "--firmware",
    });
    run_emu.addFileArg(p4_emulated.flash_image);
    run_emu.stdio = .inherit;
    run_emu.has_side_effects = true;
    b.step("emu", "Boot the ESP32-P4 kernel in esp-emulator (quit with Ctrl-C)").dependOn(&run_emu.step);

    // The virt machines' work disk, blank: copied to work/ for each
    // machine the first time it runs (`keepWorkDisk`).
    const make_work_disk = b.addRunArtifact(mkfs);
    make_work_disk.addArg("--blank");
    const blank_work_disk = make_work_disk.addPrefixedOutputFileArg("--gpt=", "work.bin");
    make_work_disk.addArgs(&.{ b.fmt("--gpt-bytes={d}", .{virt_work_bytes}), "Work", "DH1" });

    // QEMU's RISC-V 64 virt machine, a board of its own: the `virt` step
    // boots its kernel under the OpenSBI QEMU brings (-bios default),
    // which enters it in supervisor mode at 0x80200000, and it starts
    // from its system disk, an NVMe SSD (`virtDisks`). A USB speaker
    // (`virtSpeaker`) is on its xHCI controller, as on every virt step.
    const virt_kernel = if (board == .qemu_virt) kernel else addKernel(b, rv64_target, optimize, sdk, .qemu_virt, disk_offset, cores, selftest, memdebug);
    const virt_disks: VirtDisks = .{ .system = rv64_system_disk, .work = keepWorkDisk(b, blank_work_disk, "virt.bin") };
    const run_virt = b.addSystemCommand(&.{
        "qemu-system-riscv64", "-M", "virt",       "-m",    "512M",
        "-smp",                "4",  "-nographic", "-bios", "default",
    });
    run_virt.addArgs(&.{ "-device", "qemu-xhci" });
    run_virt.addArgs(virt_speaker);
    virt_disks.addTo(run_virt);
    run_virt.addArg("-kernel");
    run_virt.addArtifactArg(virt_kernel);
    run_virt.stdio = .inherit;
    run_virt.has_side_effects = true;
    b.step("virt", "Boot the RISC-V 64 kernel in QEMU's virt machine (quit with Ctrl-A X)").dependOn(&run_virt.step);

    // The same with what the board has around it: the virtio GPU, 1920x1080
    // as the VisionFive 2's HDMI, and USB with a keyboard, a tablet, whose
    // pointer stays where the host's is, and an Ethernet adapter on the
    // user network (`virtNetwork`). The window is QEMU's own
    // choice - GTK or SDL, VNC on :5900 where it has neither - and the
    // GPU's cursor is the host's pointer over it; the console stays on the
    // terminal. `virt-ramfb` has the ramfb instead, the machine's pointer
    // composed into the picture and the host's hidden over it.
    for ([_][3][]const u8{
        .{ "virtio-gpu-device,xres=1920,yres=1080", "virt-display", "virtio GPU" },
        .{ "ramfb", "virt-ramfb", "ramfb" },
    }) |display| {
        const run_virt_display = b.addSystemCommand(&.{
            "qemu-system-riscv64", "-M",        "virt",      "-m",      "512M",
            "-smp",                "4",         "-bios",     "default", "-display",
            virt_ui,               "-serial",   "mon:stdio", "-device", display[0],
            "-device",             "qemu-xhci", "-device",   "usb-kbd", "-device",
            "usb-tablet",
        });
        run_virt_display.addArgs(virt_network);
        run_virt_display.addArgs(virt_speaker);
        virt_disks.addTo(run_virt_display);
        run_virt_display.addArg("-kernel");
        run_virt_display.addArtifactArg(virt_kernel);
        run_virt_display.stdio = .inherit;
        run_virt_display.has_side_effects = true;
        b.step(display[1], b.fmt("Boot QEMU's virt machine with its display ({s}), keyboard, tablet and network", .{display[2]})).dependOn(&run_virt_display.step);
    }

    // QEMU's AArch64 virt machine, a board of its own: the `virt64` step
    // boots its kernel as QEMU boots an arm64 Linux Image - at EL1, the
    // device tree in x0, PSCI by HVC - with Cortex-A76 cores and a GICv2
    // as the Pi's BCM2712 has them, everything below 4 GiB, and the same
    // two NVMe SSDs, its own system disk and work disk.
    const virt64_kernel = if (board == .qemu_virt_a64) built else addA64Image(b, addKernel(b, a64_target, optimize, sdk, .qemu_virt_a64, disk_offset, cores, selftest, memdebug));
    const virt64_machine = [_][]const u8{
        "qemu-system-aarch64", "-M",         "virt,gic-version=2,highmem=off",
        "-cpu",                "cortex-a76", "-m",
        "512M",                "-smp",       "4",
    };
    const virt64_disks: VirtDisks = .{ .system = a64_system_disk, .work = keepWorkDisk(b, blank_work_disk, "virt64.bin") };
    const run_virt64 = b.addSystemCommand(&virt64_machine);
    run_virt64.addArgs(&.{ "-nographic", "-device", "qemu-xhci" });
    run_virt64.addArgs(virt_speaker);
    virt64_disks.addTo(run_virt64);
    run_virt64.addArg("-kernel");
    run_virt64.addFileArg(virt64_kernel.image);
    run_virt64.stdio = .inherit;
    run_virt64.has_side_effects = true;
    b.step("virt64", "Boot the AArch64 kernel in QEMU's virt machine (quit with Ctrl-A X)").dependOn(&run_virt64.step);

    // The same with what the board has around it, as `virt-display`: the
    // virtio GPU - or the ramfb, `virt64-ramfb` - USB with a keyboard, a
    // tablet and an Ethernet adapter, the console on the terminal.
    for ([_][3][]const u8{
        .{ "virtio-gpu-device,xres=1920,yres=1080", "virt64-display", "virtio GPU" },
        .{ "ramfb", "virt64-ramfb", "ramfb" },
    }) |display| {
        const run_virt64_display = b.addSystemCommand(&virt64_machine);
        run_virt64_display.addArgs(&.{
            "-display", virt_ui,    "-serial", "mon:stdio",
            "-device",  display[0], "-device", "qemu-xhci",
            "-device",  "usb-kbd",  "-device", "usb-tablet",
        });
        run_virt64_display.addArgs(virt_network);
        run_virt64_display.addArgs(virt_speaker);
        virt64_disks.addTo(run_virt64_display);
        run_virt64_display.addArg("-kernel");
        run_virt64_display.addFileArg(virt64_kernel.image);
        run_virt64_display.stdio = .inherit;
        run_virt64_display.has_side_effects = true;
        b.step(display[1], b.fmt("Boot QEMU's AArch64 virt machine with its display ({s}), keyboard, tablet and network", .{display[2]})).dependOn(&run_virt64_display.step);
    }

    // The machine with EL2 and EL3 (virtualization=on): the firmware is
    // QEMU's PSCI at EL3, reached by SMC, and every core comes in at EL2,
    // as on the CM5 - so the kernel's way down to EL1 runs.
    const run_virt64_el2 = b.addSystemCommand(&.{
        "qemu-system-aarch64", "-M",         "virt,gic-version=2,highmem=off,virtualization=on",
        "-cpu",                "cortex-a76", "-m",
        "512M",                "-smp",       "4",
        "-nographic",          "-device",    "qemu-xhci",
    });
    run_virt64_el2.addArgs(virt_speaker);
    virt64_disks.addTo(run_virt64_el2);
    run_virt64_el2.addArg("-kernel");
    run_virt64_el2.addFileArg(virt64_kernel.image);
    run_virt64_el2.stdio = .inherit;
    run_virt64_el2.has_side_effects = true;
    b.step("virt64-el2", "Boot the AArch64 kernel in QEMU's virt machine entered at EL2, PSCI by SMC").dependOn(&run_virt64_el2.step);
    // Target-independent code, tested on the host.
    const test_step = b.step("test", "Run the unit tests on the host");
    const test_options = b.addOptions();
    test_options.addOption(u32, "posfs_soak", posfs_soak);
    for ([_][]const u8{ "src/tests.zig", "src/rom/devs/timer/timeval.zig" }) |path| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = b.graph.host,
        });
        test_mod.addImport("sdk", sdk);
        test_mod.addOptions("test_options", test_options);
        const unit_tests = b.addTest(.{ .root_module = test_mod });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
    // The disk's own tests, some of which bring up the ROM's exec and
    // utility.library: those they reach through `host_rom`.
    const host_rom = b.createModule(.{ .root_source_file = b.path("src/host_rom.zig"), .target = b.graph.host });
    host_rom.addImport("sdk", sdk);
    const disk_test_mod = b.createModule(.{
        .root_source_file = disk_dep.path("tests.zig"),
        .target = b.graph.host,
    });
    disk_test_mod.addImport("sdk", sdk);
    disk_test_mod.addImport("host_rom", host_rom);
    // The rasterizer core: its own tests, and the module its test programs
    // import, for the scenes they draw (c/test/raster/reference.zig). A
    // file belongs to one module, so the core is tested on its own.
    const raster_mod = b.createModule(.{ .root_source_file = disk_dep.path("libs/facet/raster/raster.zig"), .target = b.graph.host });
    raster_mod.addImport("sdk", sdk);
    disk_test_mod.addImport("raster", raster_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = raster_mod })).step);
    // The baseline JPEG decoder, jpeg.datatype's and videocodec.library's,
    // tested on its own as well.
    const jpegdecode_mod = b.createModule(.{ .root_source_file = disk_dep.path("classes/datatypes/jpeg/decode.zig"), .target = b.graph.host });
    disk_test_mod.addImport("jpegdecode", jpegdecode_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = jpegdecode_mod })).step);
    disk_test_mod.addOptions("test_options", test_options);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = disk_test_mod })).step);
    test_step.dependOn(&posfsck.step);
    // esp32s3wifi.device's own code compiles for the chip even where the vendor
    // libraries it links are missing: as an object, which needs no link.
    const wifi_check = b.addObject(.{
        .name = "wifi_check",
        .root_module = b.createModule(.{
            .root_source_file = disk_dep.path(poweros_userland.wifi_device.source),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .unwind_tables = .none,
        }),
    });
    wifi_check.root_module.addImport("sdk", sdk);
    test_step.dependOn(&wifi_check.step);
    // fontconv's own tests: its readers and the images it writes.
    const fontconv_tests = b.createModule(.{
        .root_source_file = b.path("tools/fontconv/fontconv.zig"),
        .target = b.graph.host,
    });
    fontconv_tests.addImport("sdk", sdk);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = fontconv_tests })).step);
    // Board facts are src/boards/'s and nothing a module imports: a
    // module asks expansion.library for its part (tools/boardcheck.zig).
    const boardcheck = b.addExecutable(.{
        .name = "boardcheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/boardcheck.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const check_boards = b.addRunArtifact(boardcheck);
    check_boards.addArg(b.pathFromRoot("src"));
    check_boards.has_side_effects = true;
    test_step.dependOn(&check_boards.step);
    // Every file in the kernel shell's cmds/ is in its command list: the
    // table and `help` are made from that list (tools/shellcheck.zig).
    const shellcheck = b.addExecutable(.{
        .name = "shellcheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/shellcheck.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const check_shell = b.addRunArtifact(shellcheck);
    check_shell.addArg(b.pathFromRoot("src/rom/libs/exec/_shell"));
    check_shell.has_side_effects = true;
    test_step.dependOn(&check_shell.step);
    // The SDK's autodocs (sdk/docs/autodocs) come from the doc comments of
    // every call in sdk/fd: `autodoc` writes them, and `test` fails if one
    // isn't up to date (tools/autodoc.zig).
    const autodoc = b.addExecutable(.{
        .name = "autodoc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/autodoc.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const autodoc_args = [_][]const u8{ b.pathFromRoot("sdk/fd"), b.pathFromRoot("src"), b.pathFromRoot("sdk/docs/autodocs") };
    const write_autodocs = b.addRunArtifact(autodoc);
    write_autodocs.addArgs(&autodoc_args);
    write_autodocs.has_side_effects = true;
    b.step("autodoc", "Generate the SDK's autodocs (sdk/docs/autodocs) from the source").dependOn(&write_autodocs.step);
    const check_autodocs = b.addRunArtifact(autodoc);
    check_autodocs.addArg("--check");
    check_autodocs.addArgs(&autodoc_args);
    check_autodocs.has_side_effects = true;
    test_step.dependOn(&check_autodocs.step);
    // The charts of which module opens which (sdk/docs/modules.md) come
    // from the source: `modchart` writes them, and `test` fails if one
    // isn't up to date (tools/modchart.zig). The ROM's modules it finds by
    // their place; the disk's are the disk package's list, handed over as a
    // file of `<name>=<root file>` lines.
    const modchart = b.addExecutable(.{
        .name = "modchart",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/modchart.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    var disk_modules: std.ArrayList(u8) = .empty;
    for (poweros_userland.programs ++ [_]poweros_userland.Program{poweros_userland.wifi_device}) |program| {
        if (!isModule(program.disk)) continue;
        const root = b.pathFromRoot(b.fmt("src/disk/{s}", .{program.source}));
        disk_modules.appendSlice(b.allocator, b.fmt("{s}={s}\n", .{ program.name, root })) catch @panic("OOM");
    }
    const disk_module_list = b.addWriteFiles().add("disk-modules", disk_modules.items);
    const modchart_args = [_][]const u8{ b.pathFromRoot("sdk/docs/modules.md"), b.pathFromRoot("src"), b.pathFromRoot("sdk") };
    const write_modchart = b.addRunArtifact(modchart);
    write_modchart.addArgs(&modchart_args);
    write_modchart.addFileArg(disk_module_list);
    write_modchart.has_side_effects = true;
    b.step("modchart", "Generate the module charts (sdk/docs/modules.md) from the source").dependOn(&write_modchart.step);
    const check_modchart = b.addRunArtifact(modchart);
    check_modchart.addArg("--check");
    check_modchart.addArgs(&modchart_args);
    check_modchart.addFileArg(disk_module_list);
    check_modchart.has_side_effects = true;
    test_step.dependOn(&check_modchart.step);
    // tools/mkicon runs once on a default icon's picture with every
    // field, reads back what it wrote, and fails if any of it does not
    // read.
    const try_mkicon = b.addRunArtifact(mkicon);
    try_mkicon.addFileArg(b.path("src/disk/libs/icon/images/drawer.png"));
    _ = try_mkicon.addOutputFileArg("Work.info");
    try_mkicon.addArgs(&.{ "KIND=DRAWER", "AT=20,10", "TOOL=SYS:Programs/MultiView", "TYPE=FILETYPE=text|ascii", "TYPE=DONOTWAIT", "STACK=16384", "WINDOW=40,30,400,200", "SCROLL=0,8", "VIEW=NAME", "SHOW=ALL" });
    test_step.dependOn(&try_mkicon.step);
    // Every program and module on the disk compiles: the disk image is
    // made from all of them. And for the ESP32-P4 too, into load files.
    test_step.dependOn(&make_disk.step);
    test_step.dependOn(&make_p4_disk.step);
    test_step.dependOn(&make_a64_disk.step);
    // Every board's kernel compiles, not only the one being flashed.
    for (std.enums.values(Board)) |other| {
        const other_target = switch (chipOf(other)) {
            .esp32s3 => target,
            .esp32p4 => p4_target,
            .rv64sbi => rv64_target,
            .a64psci => a64_target,
        };
        if (other != board) test_step.dependOn(&addKernel(b, other_target, optimize, sdk, other, disk_offset, cores, false, false).step);
    }

    // The SDK's interfaces (sdk/interface) come from its .fd files
    // (sdk/fd): the SDK package's `fd` step writes them, and its `test`
    // step - part of this one - fails if one isn't up to date.
    const fd_step = b.step("fd", "Generate the SDK's interfaces (sdk/interface) from sdk/fd");
    fd_step.dependOn(&sdk_dep.builder.top_level_steps.get("fd").?.step);
    test_step.dependOn(&sdk_dep.builder.top_level_steps.get("test").?.step);

    // The board's chip and its disk: the S3's image at 0x0, the P4's two
    // parts at 0x2000 and p4_flash_part_offset; each chip's own programs
    // on its disk.
    const chip_name = @tagName(chipOf(board));
    const board_disk = switch (chipOf(board)) {
        .esp32s3 => disk_bin,
        .esp32p4 => p4_disk_bin,
        .rv64sbi => rv64_disk_bin,
        .a64psci => a64_disk_bin,
    };
    const flash = b.addSystemCommand(&.{ esptool, "--chip", chip_name, "--port", port, "--baud", baud, "write-flash" });
    built.addTo(b, flash);
    flash.stdio = .inherit;
    flash.has_side_effects = true;
    b.step("flash", "Write the kernel to the board's flash (replaces the bootloader)").dependOn(&flash.step);

    // The disk, on its own: `zig build flash` doesn't touch it, so this is
    // what puts a file system there the first time (or wipes it).
    //
    // The whole disk area is erased first, and that is not belt and braces.
    // The image holds only the sectors the file system touched - a few
    // hundred KiB of fifteen MiB - and the file system is a **log**: what
    // replay believes is whatever carries the highest sequence number.
    // Writing the image over the front of a disk that has been used leaves
    // the older, further-along segments in place, and those outrank it. The
    // machine then boots a mixture: a file that was replaced still reads as
    // it was, and a program from one build runs against a ROM from another,
    // which fails in ways that look like anything but a stale disk.
    const erase_disk = b.addSystemCommand(&.{
        esptool,        "--chip",                       chip_name,                    "--port", port, "--baud", baud,
        "erase-region", b.fmt("0x{x}", .{disk_offset}), b.fmt("0x{x}", .{disk_size}),
    });
    erase_disk.stdio = .inherit;
    erase_disk.has_side_effects = true;

    const flash_disk = b.addSystemCommand(&.{ esptool, "--chip", chip_name, "--port", port, "--baud", baud, "write-flash", b.fmt("0x{x}", .{disk_offset}) });
    flash_disk.addFileArg(board_disk);
    flash_disk.stdio = .inherit;
    flash_disk.has_side_effects = true;
    flash_disk.step.dependOn(&erase_disk.step);
    b.step("flash-disk", "Write a fresh disk image to the flash disk (erases what is on it)").dependOn(&flash_disk.step);

    // Both at once: the disk area erased as flash-disk does, then the
    // kernel and the disk image in one write-flash - one connection to the
    // chip for the two, and a ROM and a disk from the same build, which is
    // the pairing a stale disk breaks.
    const flash_all = b.addSystemCommand(&.{ esptool, "--chip", chip_name, "--port", port, "--baud", baud, "write-flash" });
    built.addTo(b, flash_all);
    flash_all.addArg(b.fmt("0x{x}", .{disk_offset}));
    flash_all.addFileArg(board_disk);
    flash_all.stdio = .inherit;
    flash_all.has_side_effects = true;
    flash_all.step.dependOn(&erase_disk.step);
    b.step("flash-all", "Write the kernel and a fresh disk image (erases the disk)").dependOn(&flash_all.step);
}

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
    /// `virt:`: on the virt machines' system disks as well, and on
    /// nothing else of their chips.
    virt: bool = false,
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
/// images it is for and a colon: chips by `Chip`'s names, and `virt` for
/// the virt machines' system disks alone (`system-rv64.bin`,
/// `system-a64.bin`, mkfs's `--gpt-file`).
/// `-Dextra=rv64sbi:c/tool=<file>` puts a program on the RISC-V 64 disks
/// only; `-Dextra=virt:Music/song.mp3=<file>` a song on the SSDs QEMU
/// starts from, which have room where the boards' flash disks have none.
///
/// The directories a path needs are made for it, and the ones the image
/// already has are left alone. They are made on every image, whichever
/// the file is for: an empty drawer costs a block, and one path then
/// never needs a drawer on one image that another file made on another.
fn extraFiles(b: *std.Build, made: *std.ArrayList([]const u8)) []const Extra {
    const given = b.option(
        []const []const u8,
        "extra",
        "A file from outside this tree on the disk image: [<chip>|virt,...:]<path on the disk>=<file on the host>, given once per file",
    ) orelse return &.{};

    var extras: std.ArrayList(Extra) = .empty;
    for (given) |entry| {
        const split = std.mem.indexOfScalar(u8, entry, '=') orelse
            std.debug.panic("-Dextra={s}: no '=' between the path on the disk and the file on the host", .{entry});
        // The chips it is for, before a colon in what comes before the '='.
        var only: ?std.EnumSet(Chip) = null;
        var virt = false;
        var start: usize = 0;
        if (std.mem.indexOfScalar(u8, entry[0..split], ':')) |colon| {
            var chips = std.EnumSet(Chip).initEmpty();
            var names = std.mem.splitScalar(u8, entry[0..colon], ',');
            while (names.next()) |name| {
                if (std.mem.eql(u8, name, "virt")) {
                    virt = true;
                    continue;
                }
                const chip = std.meta.stringToEnum(Chip, name) orelse
                    std.debug.panic("-Dextra={s}: no image '{s}' - virt, or a chip: {s}", .{ entry, name, chipNames(b) });
                chips.insert(chip);
            }
            only = chips;
            start = colon + 1;
        }
        const path = std.mem.trim(u8, entry[start..split], "/");
        const host = entry[split + 1 ..];
        if (path.len == 0 or host.len == 0)
            std.debug.panic("-Dextra={s}: it is [<chip>|virt,...:]<path on the disk>=<file on the host>", .{entry});

        extras.append(b.allocator, .{
            .path = path,
            .host = host,
            .only = only,
            .virt = virt,
            .dirs = dirsFor(b, made, path, false),
        }) catch @panic("OOM");
    }
    return extras.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// `Chip`'s names, for a message.
fn chipNames(b: *std.Build) []const u8 {
    var names: std.ArrayList(u8) = .empty;
    for (std.enums.values(Chip), 0..) |chip, i| {
        if (i != 0) names.appendSlice(b.allocator, ", ") catch @panic("OOM");
        names.appendSlice(b.allocator, @tagName(chip)) catch @panic("OOM");
    }
    return names.items;
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
};

/// FONTS: as the disk has it. Spleen at every size a panel wants; the
/// same at 16 rows smoothed from its 32-row drawing, whose coverage shows
/// how an alpha font looks on a panel; at 16 with a shadow, a colour font
/// drawn partly in the pen; and the Go faces as outlines, at any size.
const disk_fonts = [_]DiskFont{
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
};

/// Where scripts/fetch-fonts.sh put the fonts' sources, if it has.
fn fontsDir(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const path = b.pathFromRoot("toolchain/fonts");
    var dir = std.Io.Dir.cwd().openDir(io, b.pathJoin(&.{ path, "go" }), .{}) catch {
        std.log.info("no font sources (scripts/fetch-fonts.sh): the disk has no FONTS:", .{});
        return null;
    };
    dir.close(io);
    return path;
}

/// Where scripts/fetch-icons.sh put the pictures drawn at `size`, if it
/// has.
fn iconsDir(b: *std.Build, size: u32) ?[]const u8 {
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
const aic8800_files = [_][]const u8{
    "fmacfw.bin",         "fw_adid.bin",            "fw_adid_u03.bin", "fw_patch.bin", "fw_patch_u03.bin",
    "fw_patch_table.bin", "fw_patch_table_u03.bin",
};

const cyw43455_files = [_][]const u8{ "cyfmac43455-sdio.bin", "cyfmac43455-sdio.clm_blob", "brcmfmac43455-sdio.txt" };

/// Where scripts/fetch-cyw43455.sh put the CYW43455's firmware, or null
/// without it.
fn cyw43455Dir(b: *std.Build) ?[]const u8 {
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
fn aic8800Dir(b: *std.Build) ?[]const u8 {
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
fn vpuDir(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const path = b.pathFromRoot("toolchain/wave511");
    std.Io.Dir.cwd().access(io, b.pathJoin(&.{ path, "wave511_dec_fw.bin" }), .{}) catch {
        std.log.info("no WAVE511 firmware (scripts/fetch-vpu.sh): the RISC-V 64 disk has no DEVS:firmware/", .{});
        return null;
    };
    return path;
}

/// The list scripts/fetch-pciids.sh fetched, or null without it.
fn pciIdsFile(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const path = b.pathFromRoot("toolchain/pciids/pci.ids");
    std.Io.Dir.cwd().access(io, path, .{}) catch {
        std.log.info("no PCI ID list (scripts/fetch-pciids.sh): the RISC-V and AArch64 disks have no DEVS:pci.ids", .{});
        return null;
    };
    return path;
}

/// The PEM bundle scripts/fetch-certs.sh fetched, or null without it.
fn certsFile(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const path = b.pathFromRoot("toolchain/certs/cacert-2026-09-25.pem");
    std.Io.Dir.cwd().access(io, path, .{}) catch {
        std.log.info("no root certificates (scripts/fetch-certs.sh): the disk has no SYS:Certificates/Roots", .{});
        return null;
    };
    return path;
}

fn wifiDir(b: *std.Build, given: ?[]const u8) ?[]const u8 {
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

fn diskTree(b: *std.Build, made: *std.ArrayList([]const u8)) Tree {
    const io = b.graph.io;
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
const Tree = struct {
    dirs: []const []const u8 = &.{},
    files: []const Extra = &.{},
};

/// `games/` in the root of the tree, with -Dgames: what is in it goes in
/// the `Games` drawer of the virt machines' system disks
/// (`system-rv64.bin`, `system-a64.bin`) - games and their data, too
/// large for the boards' flash disks, on the SSDs that have room for
/// them. A program is built once per chip, so `<name>.<chip>.seg` goes
/// on that chip's disk alone, as `<name>`:
/// `games/Millennium/Millennium.a64psci.seg` is
/// `SYS:Games/Millennium/Millennium` on the AArch64 machine's. Another
/// `.seg` loses the suffix on both, and any other file keeps its name.
/// The drawers are made on those disks alone (mkfs's `--gpt-file` with
/// no file), outermost first, and `Games` gets its icon there
/// (`games_drawer_icon`): the volume's window shows only what has one.
///
/// A name beginning with a dot is left behind, and so is the `README.md`
/// in the root of `games/`.
fn gamesTree(b: *std.Build, made: *std.ArrayList([]const u8)) []const Game {
    const wanted = b.option(bool, "games", "Put what games/ holds in the Games drawer of the virt machines' system disks: <name>.<chip>.seg on that chip's as <name>") orelse false;
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

/// The kernel, its ESP image and the full 16 MB flash with the disk in it.
const Image = struct {
    kernel_elf: std.Build.LazyPath,
    image: std.Build.LazyPath,
    flash_image: std.Build.LazyPath,
    /// The ESP32-P4's second part, the code and constants run in place
    /// from flash; the S3's image is one piece.
    flash_part: ?std.Build.LazyPath = null,

    /// The kernel's pieces for `esptool write-flash`, each after the
    /// offset it goes to.
    fn addTo(image: Image, b: *std.Build, run: *std.Build.Step.Run) void {
        if (image.flash_part) |part| {
            run.addArg("0x2000");
            run.addFileArg(image.image);
            run.addArg(b.fmt("0x{x}", .{p4_flash_part_offset}));
            run.addFileArg(part);
        } else {
            run.addArg("0x0");
            run.addFileArg(image.image);
        }
    }
};

/// `kernel` made into what is flashed and what QEMU boots.
fn addImage(b: *std.Build, esptool: []const u8, ressize: *std.Build.Step.Compile, kernel: *std.Build.Step.Compile, disk_bin: std.Build.LazyPath, disk_offset: u32) Image {
    const measure = b.addRunArtifact(ressize);
    measure.addArtifactArg(kernel);
    const kernel_elf = measure.addOutputFileArg("kernel");

    // ESP image for the ROM bootloader, at flash offset 0x0 - no
    // second-stage bootloader. --ram-only-header shows the ROM only the RAM
    // segments (vectors, boot code, data), which it loads; the code segment
    // (.flash.text) follows them, 64 KiB-aligned, and the boot code maps it
    // through the MMU (src/arch/esp32s3/flashmap.zig). No SHA-256 digest:
    // esptool's covers the whole file, the ROM hashes only the part the
    // header shows it, so the check could only fail.
    const elf2image = b.addSystemCommand(&.{
        esptool,        "--chip", "esp32s3",           "elf2image",
        "--flash-mode", "dio",    "--flash-freq",      "80m",
        "--flash-size", "16MB",   "--ram-only-header", "--dont-append-digest",
        "-o",
    });
    const unchecked = elf2image.addOutputFileArg("kernel.bin");
    elf2image.addFileArg(kernel_elf);

    // The image has to end below the disk, or writing one overwrites the
    // other. Everything that flashes or merges it takes it from here.
    const fits = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            \\size=$(wc -c < "$0")
            \\if [ "$size" -gt {d} ]; then
            \\  echo "kernel.bin is $size bytes, more than the {d} KiB below the disk: raise -Ddisk-offset" >&2
            \\  exit 1
            \\fi
            \\cp "$0" "$1"
        , .{ disk_offset, disk_offset / 1024 }),
    });
    fits.addFileArg(unchecked);
    const image = fits.addOutputFileArg("kernel.bin");

    // Full 16 MB flash dump for QEMU, like the board's N16R8 module.
    const merge = b.addSystemCommand(&.{ esptool, "--chip", "esp32s3", "merge-bin", "--pad-to-size", "16MB", "-o" });
    const flash_image = merge.addOutputFileArg("flash.bin");
    merge.addArg("0x0");
    merge.addFileArg(image);
    merge.addArg(b.fmt("0x{x}", .{disk_offset}));
    merge.addFileArg(disk_bin);
    return .{ .kernel_elf = kernel_elf, .image = image, .flash_image = flash_image };
}

/// Where the ESP32-P4's kernel keeps its flash part in flash: the offset
/// src/arch/esp32p4/kernel.ld links it for (`_flash_part_offset`).
const p4_flash_part_offset = 0x40000;

/// Disk images made from one recipe: what is given goes into each.
const DiskImages = struct {
    runs: [4]*std.Build.Step.Run,

    /// How long a pointer is on each run's chip, in the order of `runs`:
    /// the ESP32-S3's and the ESP32-P4's, then RISC-V 64's and AArch64's.
    const pointer_bytes = [4]u32{ 4, 4, 8, 8 };
    /// Each run's chip, and whether it writes a virt machine's system
    /// disk as well (`--gpt`), in the same order.
    const chips = [4]Chip{ .esp32s3, .esp32p4, .rv64sbi, .a64psci };
    const virt_disks = [4]bool{ false, false, true, true };

    fn addArg(images: DiskImages, arg: []const u8) void {
        for (images.runs) |run| run.addArg(arg);
    }

    fn addArgs(images: DiskImages, args: []const []const u8) void {
        for (images.runs) |run| run.addArgs(args);
    }

    fn addPrefixedFileArg(images: DiskImages, prefix: []const u8, path: std.Build.LazyPath) void {
        for (images.runs) |run| run.addPrefixedFileArg(prefix, path);
    }
};

/// The two NVMe SSDs of a virt machine: the system disk the build made,
/// whose writes QEMU keeps in a copy that ends with the run
/// (`snapshot=on`), and the work disk, which keeps them. QEMU passes the
/// work disk's flushes on to nobody (`cache=unsafe`): each would be a
/// sync of the image file on the host, milliseconds apiece, while what
/// was written is in the host's own cache already and stays there when
/// QEMU quits or is killed - only a crash of the host can lose it.
const VirtDisks = struct {
    system: std.Build.LazyPath,
    /// The work disk's path, and the step that puts it there.
    work: WorkDisk,

    fn addTo(disks: VirtDisks, run: *std.Build.Step.Run) void {
        const b = run.step.owner;
        run.addArg("-drive");
        run.addPrefixedFileArg("if=none,id=system,format=raw,snapshot=on,file=", disks.system);
        run.addArgs(&.{
            "-device", "nvme,serial=system,drive=system",
            "-drive",  b.fmt("if=none,id=work,format=raw,cache=unsafe,file={s}", .{disks.work.path}),
            "-device", "nvme,serial=work,drive=work",
        });
        run.step.dependOn(disks.work.step);
    }
};

const WorkDisk = struct { path: []const u8, step: *std.Build.Step };

/// A machine's work disk, `name` in `virt_work_dir`: the blank one copied
/// there when there is none yet, which leaves one that is alone. A copy
/// keeps the blank's holes, so the disk takes on the host what has been
/// written to it.
fn keepWorkDisk(b: *std.Build, blank: std.Build.LazyPath, name: []const u8) WorkDisk {
    const path = b.pathFromRoot(b.pathJoin(&.{ virt_work_dir, name }));
    const keep = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\[ -f "$0" ] || { mkdir -p "$(dirname "$0")" && cp "$1" "$0"; }
        ,
        path,
    });
    keep.addFileArg(blank);
    keep.has_side_effects = true;
    return .{ .path = path, .step = &keep.step };
}

/// A RISC-V 64 kernel made into what is booted: the ELF, which QEMU loads
/// as it is, and a raw binary of it from its first address (0x80200000),
/// which U-Boot loads there. Nothing to flash.
fn addRv64Image(b: *std.Build, kernel: *std.Build.Step.Compile) Image {
    const kernel_elf = kernel.getEmittedBin();
    const image = b.addObjCopy(kernel_elf, .{ .format = .bin }).getOutput();
    return .{ .kernel_elf = kernel_elf, .image = image, .flash_image = image };
}

/// An AArch64 kernel made into what is booted: the ELF, for a debugger,
/// and a raw binary of it from its first address (0x40200000), which
/// starts with an arm64 Image header (start.S): QEMU's -kernel loads it
/// as it loads Linux - at the start of RAM plus the header's text_offset,
/// the device tree in x0, the initrd in /chosen - which it does for an
/// Image and not for an ELF. Nothing to flash.
fn addA64Image(b: *std.Build, kernel: *std.Build.Step.Compile) Image {
    const kernel_elf = kernel.getEmittedBin();
    const image = b.addObjCopy(kernel_elf, .{ .format = .bin }).getOutput();
    return .{ .kernel_elf = kernel_elf, .image = image, .flash_image = image };
}

/// The ESP32-P4's kernel made into what is flashed and what esp-emulator
/// boots, in two parts: the RAM part, an ESP image the ROM loads and runs,
/// at flash offset 0x2000, where the P4's ROM looks for its second-stage
/// bootloader; and the flash part - the code and constants - at the
/// offset it is linked for, which the RAM part maps in place
/// (src/arch/esp32p4/flashmap.zig). Both, and the disk at `disk_offset`,
/// in a 16 MB flash dump for the emulator.
fn addP4Image(b: *std.Build, esptool: []const u8, ramimage: *std.Build.Step.Compile, kernel: *std.Build.Step.Compile, disk_bin: std.Build.LazyPath, disk_offset: u32) Image {
    const kernel_elf = kernel.getEmittedBin();
    // --ram-only-header puts the RAM segments first and has the header
    // count only those; the image is cut after their checksum.
    const elf2image = b.addSystemCommand(&.{
        esptool,        "--chip", "esp32p4",           "elf2image",
        "--flash-mode", "dio",    "--flash-freq",      "80m",
        "--flash-size", "16MB",   "--ram-only-header", "--dont-append-digest",
        "-o",
    });
    const whole = elf2image.addOutputFileArg("kernel-whole.bin");
    elf2image.addFileArg(kernel_elf);
    const cut = b.addRunArtifact(ramimage);
    cut.addFileArg(whole);
    const image = cut.addOutputFileArg("kernel.bin");
    const unchecked_part = b.addObjCopy(kernel_elf, .{ .format = .bin, .only_section = ".flash" });
    // The RAM part has to end below the flash part, and the flash part
    // below the disk, or writing one overwrites the next. Everything that
    // flashes or merges them takes them from here.
    const fits = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            \\ram=$(wc -c < "$0")
            \\part=$(wc -c < "$1")
            \\if [ "$ram" -gt {d} ]; then
            \\  echo "kernel.bin is $ram bytes, more than the {d} KiB below the flash part" >&2
            \\  exit 1
            \\fi
            \\if [ "$part" -gt {d} ]; then
            \\  echo "kernel-flash.bin is $part bytes, more than the {d} KiB between 0x{x} and the disk: raise -Ddisk-offset" >&2
            \\  exit 1
            \\fi
            \\cp "$1" "$2"
        , .{ p4_flash_part_offset - 0x2000, (p4_flash_part_offset - 0x2000) / 1024, disk_offset - p4_flash_part_offset, (disk_offset - p4_flash_part_offset) / 1024, p4_flash_part_offset }),
    });
    fits.addFileArg(image);
    fits.addFileArg(unchecked_part.getOutput());
    const flash_part = fits.addOutputFileArg("kernel-flash.bin");
    const merge = b.addSystemCommand(&.{ esptool, "--chip", "esp32p4", "merge-bin", "--pad-to-size", "16MB", "-o" });
    const flash_image = merge.addOutputFileArg("flash.bin");
    merge.addArg("0x2000");
    merge.addFileArg(image);
    merge.addArg(b.fmt("0x{x}", .{p4_flash_part_offset}));
    merge.addFileArg(flash_part);
    merge.addArg(b.fmt("0x{x}", .{disk_offset}));
    merge.addFileArg(disk_bin);
    return .{ .kernel_elf = kernel_elf, .image = image, .flash_image = flash_image, .flash_part = flash_part };
}

/// The kernel for `board`: src/main.zig with the board's description
/// chosen (src/boards/boards.zig reads `build_options.board`). `cores` 0
/// leaves the number of cores to the board; `selftest` makes an ESP32-P4's
/// boot task the chip's checks rather than the shell; `memdebug` has exec
/// switch memory debugging on as it starts.
fn addKernel(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sdk: *std.Build.Module, board: Board, disk_offset: u32, cores: u32, selftest: bool, memdebug: bool) *std.Build.Step.Compile {
    const chip = chipOf(board);
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path(switch (chip) {
            .esp32s3 => "src/main.zig",
            .esp32p4 => "src/main_esp32p4.zig",
            .rv64sbi => "src/main_rv64sbi.zig",
            .a64psci => "src/main_a64psci.zig",
        }),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .unwind_tables = .none,
        // RISC-V's and AArch64's backtraces walk the frame-pointer chain.
        .omit_frame_pointer = if (chip == .esp32s3) null else false,
        // RV64's kernel is at 0x80200000, which the default code model
        // (medlow, addresses within 2 GiB of 0) cannot reach. AArch64's
        // small model reaches 4 GiB around the code, PC-relatively.
        .code_model = switch (chip) {
            .rv64sbi => .medany,
            .a64psci => .small,
            .esp32s3, .esp32p4 => .default,
        },
    });
    kernel_mod.addImport("sdk", sdk);
    const options = b.addOptions();
    options.addOption(Board, "board", board);
    options.addOption(u32, "disk_offset", disk_offset);
    options.addOption(u32, "cores", cores);
    options.addOption(bool, "selftest", selftest);
    options.addOption(bool, "memdebug", memdebug);
    kernel_mod.addOptions("build_options", options);
    switch (chip) {
        .esp32s3 => {
            kernel_mod.addAssemblyFile(b.path("src/arch/esp32s3/start.S"));
            kernel_mod.addAssemblyFile(b.path("src/arch/esp32s3/cache.S"));
            kernel_mod.addAssemblyFile(b.path("src/arch/esp32s3/stack.S"));
        },
        .esp32p4 => kernel_mod.addAssemblyFile(b.path("src/arch/esp32p4/start.S")),
        .rv64sbi => kernel_mod.addAssemblyFile(b.path("src/arch/rv64sbi/start.S")),
        .a64psci => kernel_mod.addAssemblyFile(b.path("src/arch/a64psci/start.S")),
    }

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_mod,
    });
    kernel.setLinkerScript(b.path(switch (chip) {
        .esp32s3 => "kernel.ld",
        .esp32p4 => "src/arch/esp32p4/kernel.ld",
        .rv64sbi => "src/arch/rv64sbi/kernel.ld",
        .a64psci => "src/arch/a64psci/kernel.ld",
    }));
    kernel.entry = .{ .symbol_name = "_start" };
    // A section per function, so each function's literals (.literal.<fn>)
    // sit next to its code: l32r reaches only 256 KiB back, and the code in
    // flash is bigger than that (kernel.ld keeps the input order).
    kernel.link_function_sections = true;
    return kernel;
}

/// A QEMU run on a throw-away copy of the image: -snapshot keeps the
/// kernel's writes out of it.
fn qemuRun(b: *std.Build, qemu: []const u8, flash_image: std.Build.LazyPath, network: []const []const u8, usb: []const []const u8, extra: []const []const u8) *std.Build.Step.Run {
    return qemuRunPath(b, qemu, flash_image, true, network, usb, extra);
}

/// What is plugged into the emulator's USB port, as QEMU's arguments: a
/// `-device` per item of `devices` - an item with `=` in it is a property
/// of the device before it, so `usb-kbd,port=1,usb-mouse` is two devices
/// - and a USB stick over the raw image `disk`. The port is the DWC2's one
/// root port: QEMU puts a hub on it by itself when a device other than a
/// hub is plugged in without `port=1`, and the devices then sit behind
/// that hub. A `usb-serial` (an FTDI FT232) without a `chardev=` gets a
/// pty of its own, whose name QEMU prints as it starts; a `usb-net` (a
/// CDC Ethernet adapter) without a `netdev=` a user network of its own,
/// 10.0.3.0/24 for the first (DHCP hands out 10.0.3.15), 10.0.4.0/24 for
/// the next - beside the machine's own Ethernet on 10.0.2.0/24. A device plugged
/// in or out while the machine runs goes through the monitor (Ctrl-A C):
/// `device_add usb-kbd,id=kbd`, `device_del kbd` - the stick is
/// `usbstick`.
fn qemuUsb(b: *std.Build, devices: ?[]const u8, disk: ?[]const u8) []const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    if (devices) |list| {
        var specs: std.ArrayList([]const u8) = .empty;
        var items = std.mem.tokenizeScalar(u8, list, ',');
        while (items.next()) |item| {
            if (std.mem.indexOfScalar(u8, item, '=') == null) {
                specs.append(b.allocator, item) catch @panic("OOM");
                continue;
            }
            if (specs.items.len == 0) std.debug.panic("-Dusb={s}: {s} is a property of no device", .{ list, item });
            const last = &specs.items[specs.items.len - 1];
            last.* = b.fmt("{s},{s}", .{ last.*, item });
        }
        var nets: u32 = 0;
        for (specs.items, 0..) |spec, index| {
            const serial = std.mem.eql(u8, spec, "usb-serial") or std.mem.startsWith(u8, spec, "usb-serial,");
            if (serial and std.mem.indexOf(u8, spec, "chardev=") == null) {
                const id = b.fmt("usbserial{d}", .{index});
                args.appendSlice(b.allocator, &.{ "-chardev", b.fmt("pty,id={s}", .{id}), "-device", b.fmt("{s},chardev={s}", .{ spec, id }) }) catch @panic("OOM");
                continue;
            }
            const network = std.mem.eql(u8, spec, "usb-net") or std.mem.startsWith(u8, spec, "usb-net,");
            if (network and std.mem.indexOf(u8, spec, "netdev=") == null) {
                const id = b.fmt("usbnet{d}", .{index});
                nets += 1;
                args.appendSlice(b.allocator, &.{ "-netdev", b.fmt("user,id={s},net=10.0.{d}.0/24", .{ id, 2 + nets }), "-device", b.fmt("{s},netdev={s}", .{ spec, id }) }) catch @panic("OOM");
            } else {
                args.appendSlice(b.allocator, &.{ "-device", spec }) catch @panic("OOM");
            }
        }
    }
    if (disk) |file| {
        args.appendSlice(b.allocator, &.{
            "-drive",  b.fmt("if=none,id=usbdisk,format=raw,file={s}", .{file}),
            "-device", "usb-storage,drive=usbdisk,id=usbstick",
        }) catch @panic("OOM");
    }
    return args.items;
}

/// The emulator's network, as QEMU's arguments: the machine's Ethernet MAC
/// on QEMU's user network - NAT to the host's, with a gateway and DHCP
/// server at 10.0.2.2 and DNS at 10.0.2.3 - named here rather than left
/// to QEMU's default, which a USB adapter's network of its own (`qemuUsb`)
/// would take away. `net` names another
/// backend for the MAC (a tap device puts the machine on the real
/// network) or `none`; `dump` writes every frame to a pcap file, which
/// needs the backend to have a name, so it makes the user network explicit.
/// `telnet` forwards that host port to the machine's port 23, where
/// C:net/ShellServer listens, and `ssh_port` one to port 22, where
/// ShellServer SSH does; 0 is none. Only qemu-display has them unless
/// asked (2323, 2222): a fixed host port keeps a second QEMU from
/// starting, and the display is the run a person sits at.
fn qemuNetwork(b: *std.Build, net: ?[]const u8, dump: ?[]const u8, telnet: ?u16, ssh_port: ?u16) []const []const u8 {
    if (net) |backend| {
        if (std.mem.eql(u8, backend, "none")) return b.dupeStrings(&.{ "-nic", "none" });
    }
    const nic = b.fmt("{s},id=net0,model=open_eth{s}", .{ net orelse "user", if (net == null) hostForwards(b, telnet, ssh_port) else "" });
    const file = dump orelse return b.dupeStrings(&.{ "-nic", nic });
    return b.dupeStrings(&.{ "-nic", nic, "-object", b.fmt("filter-dump,id=dump0,netdev=net0,file={s}", .{file}) });
}

/// The virt machines' network, as QEMU's arguments: a USB Ethernet adapter
/// (`usb-net`, a CDC-ECM function usb/ecm.device drives) on the machine's
/// xHCI controller, on QEMU's user network as `qemuNetwork` has it -
/// 10.0.2.15 by DHCP, the gateway 10.0.2.2, DNS at 10.0.2.3. It is the
/// only network the machines have a driver for. `net`, `dump`, `telnet`
/// and `ssh_port` are `qemuNetwork`'s; nothing is forwarded unless asked,
/// so a virt machine starts beside a qemu-display, which holds 2323 and
/// 2222.
fn virtNetwork(b: *std.Build, net: ?[]const u8, dump: ?[]const u8, telnet: ?u16, ssh_port: ?u16) []const []const u8 {
    if (net) |backend| {
        if (std.mem.eql(u8, backend, "none")) return b.dupeStrings(&.{ "-nic", "none" });
    }
    const netdev = b.fmt("{s},id=net0{s}", .{ net orelse "user", if (net == null) hostForwards(b, telnet, ssh_port) else "" });
    const adapter = [_][]const u8{ "-netdev", netdev, "-device", "usb-net,netdev=net0" };
    const file = dump orelse return b.dupeStrings(&adapter);
    return b.dupeStrings(&(adapter ++ [_][]const u8{ "-object", b.fmt("filter-dump,id=dump0,netdev=net0,file={s}", .{file}) }));
}

/// The virt machines' USB speaker, as QEMU's arguments: QEMU's
/// `usb-audio`, which usb/uac.device plays through as one of the
/// machine's outputs, `speaker` in the monitor - `device_del speaker`
/// pulls it out while it plays, `device_add usb-audio,id=speaker` puts it
/// back. `backend` is an `-audiodev`'s driver and its options - `pa`,
/// `pipewire`, `wav,path=out.wav` for a file; with none named QEMU takes
/// the first of the audio backends it has, and plays into nothing when it
/// has none but `none`.
fn virtSpeaker(b: *std.Build, backend: ?[]const u8) []const []const u8 {
    const named = backend orelse return b.dupeStrings(&.{ "-device", "usb-audio,id=speaker" });
    return b.dupeStrings(&.{ "-audiodev", b.fmt("{s},id=sound", .{named}), "-device", "usb-audio,id=speaker,audiodev=sound" });
}

/// The user network's port forwards, as a backend's options: `telnet` to
/// the machine's port 23, `ssh_port` to its port 22; null or 0 is none.
fn hostForwards(b: *std.Build, telnet: ?u16, ssh_port: ?u16) []const u8 {
    const telnet_forwarded: ?u16 = if (telnet) |port| (if (port == 0) null else port) else null;
    const ssh_forwarded: ?u16 = if (ssh_port) |port| (if (port == 0) null else port) else null;
    const telnet_forward = if (telnet_forwarded) |port| b.fmt(",hostfwd=tcp::{d}-:23", .{port}) else "";
    const ssh_forward = if (ssh_forwarded) |port| b.fmt(",hostfwd=tcp::{d}-:22", .{port}) else "";
    return b.fmt("{s}{s}", .{ telnet_forward, ssh_forward });
}

/// The display arguments, then the serial ports: UART0, the console, on
/// the terminal QEMU runs in, and UART1 - the RS-485 port, or a SLIP
/// line - on `uart1`'s backend when one is given. `-nographic` alone puts
/// UART0 on the terminal; naming a second port means naming the first as
/// well.
fn qemuConsole(b: *std.Build, display: []const []const u8, uart1: ?[]const u8) []const []const u8 {
    const graphic = !(display.len == 1 and std.mem.eql(u8, display[0], "-nographic"));
    if (uart1 == null and !graphic) return display;
    var args: std.ArrayList([]const u8) = .empty;
    args.appendSlice(b.allocator, display) catch @panic("OOM");
    args.appendSlice(b.allocator, &.{ "-serial", "mon:stdio" }) catch @panic("OOM");
    if (uart1) |backend| args.appendSlice(b.allocator, &.{ "-serial", backend }) catch @panic("OOM");
    return args.items;
}

/// `snapshot` false lets the kernel write the image, so a disk on it keeps
/// what is written from one boot to the next.
///
/// Both cores run on one host thread (`-accel tcg,thread=single`). With a
/// thread each, the Espressif QEMU damages its own heap about a second
/// into a boot, while the desktop loads its code - a double free in its
/// flash requests, or a crash in its translated code - in up to half of
/// all boots; on one thread none.
fn qemuRunPath(b: *std.Build, qemu: []const u8, flash_image: std.Build.LazyPath, snapshot: bool, network: []const []const u8, usb: []const []const u8, extra: []const []const u8) *std.Build.Step.Run {
    // Like the board's N16R8 module: 8 MB octal PSRAM (-m is the PSRAM size).
    const run = b.addSystemCommand(&.{
        qemu,                                            "-machine", "esp32s3",
        "-m",                                            "8M",       "-global",
        "driver=ssi_psram,property=is_octal,value=true", "-accel",   "tcg,thread=single",
    });
    if (snapshot) run.addArg("-snapshot");
    run.addArgs(network);
    run.addArgs(usb);
    run.addArgs(extra);
    run.addArg("-drive");
    run.addPrefixedFileArg("if=mtd,format=raw,file=", flash_image);
    run.stdio = .inherit;
    run.has_side_effects = true;
    return run;
}

/// Whether a thing on the disk is a module - a library, device, handler or
/// class - rather than a program.
fn isModule(disk: []const u8) bool {
    for ([_][]const u8{ "libs/", "devs/", "classes/" }) |place| {
        if (std.mem.startsWith(u8, disk, place)) return true;
    }
    return false;
}

/// esptool: ESP-IDF's, the newest under ~/.espressif/tools/python/<version>/venv/bin,
/// which ESP-IDF keeps working with its own Python; else esptool from PATH.
fn findEsptool(b: *std.Build) []const u8 {
    const name = "esptool";
    const io = b.graph.io;
    const home = b.graph.environ_map.get("HOME") orelse return name;
    const pythons = b.pathJoin(&.{ home, ".espressif", "tools", "python" });
    var dir = std.Io.Dir.openDirAbsolute(io, pythons, .{ .iterate = true }) catch return name;
    defer dir.close(io);
    var newest: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (newest == null or std.mem.order(u8, entry.name, newest.?) == .gt) newest = b.dupe(entry.name);
    }
    const version = newest orelse return name;
    const found = b.pathJoin(&.{ pythons, version, "venv", "bin", name });
    if (std.Io.Dir.cwd().access(io, found, .{})) |_| return found else |_| return name;
}

/// The 240 MHz build from scripts/build-qemu.sh if present, else
/// qemu-system-xtensa from PATH, else the newest one installed by ESP-IDF's
/// tools under ~/.espressif/tools/qemu-xtensa/<version>/qemu/bin.
fn findQemu(b: *std.Build) []const u8 {
    const name = "qemu-system-xtensa";
    const io = b.graph.io;

    const local = b.pathFromRoot("toolchain/qemu/bin/" ++ name);
    if (std.Io.Dir.cwd().access(io, local, .{})) |_| return local else |_| {}

    if (b.findProgram(&.{name}, &.{})) |path| return path else |_| {}

    const home = b.graph.environ_map.get("HOME") orelse return name;
    const tools = b.pathJoin(&.{ home, ".espressif", "tools", "qemu-xtensa" });
    var dir = std.Io.Dir.openDirAbsolute(io, tools, .{ .iterate = true }) catch return name;
    defer dir.close(io);

    var newest: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (newest == null or std.mem.order(u8, entry.name, newest.?) == .gt) newest = b.dupe(entry.name);
    }
    const version = newest orelse return name;
    return b.pathJoin(&.{ tools, version, "qemu", "bin", name });
}
