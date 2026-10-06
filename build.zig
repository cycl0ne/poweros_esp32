// SPDX-License-Identifier: MPL-2.0
const std = @import("std");
const poweros_sdk = @import("poweros_sdk");
const poweros_userland = @import("poweros_userland");

/// The flash chip every board has (16 MiB), and the flash disk on it:
/// flash.device's unit 0 starts at `-Ddisk-offset` and runs to the end of
/// the chip, with 4 KiB erase sectors and 256-byte pages
/// (src/rom/devs/flash/spiflash.zig). The build needs the numbers to make
/// a disk image and to put it in the right place, and hands the offset to
/// the kernel, whose boards give it to flash.device as SYSTAG_DiskOffset.
const flash_size = 16 * 1024 * 1024;
/// Where the disk starts unless `-Ddisk-offset` says otherwise, in KiB:
/// the kernel image starts at offset 0 and has this much room to grow in.
const default_disk_offset_kib = 2048;
/// The host port qemu-display forwards to the machine's Telnet port, 23.
const display_telnet_port: u16 = 2323;
/// An MMU page: the disk's start has to be one, since flash.device maps
/// the disk into the data window a page at a time.
const mmu_page = 64 * 1024;
const disk_sector = 4096;
const disk_page = 256;

/// Where a file that is not built here is put to have it on the disk
/// image: `disk/` in the root of the tree.
const disk_tree = "disk";

/// The boards there is a description for (src/boards/). One kernel image
/// is built per board. `qemu` is Espressif QEMU's machine, with its
/// virtual display, keyboard and mouse: the `qemu*` steps always run that
/// one, whichever board `-Dboard` names.
const Board = enum { waveshare_7b, es3c35p, qemu };

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
    // the classes that read a file's contents.
    "classes",
    "classes/gadgets",
    "classes/datatypes",
    "devs",
    // The network drivers, opened as networks/<name>.device, and the
    // interfaces C:net/AddNetInterface brings up.
    "devs/networks",
    "devs/NetInterfaces",
    // DEVS:DataTypes - one text descriptor per kind of file, which
    // C:AddDataTypes reads into datatypes.library's list.
    "devs/datatypes",
    // SYS:Programs - programs with windows, off the command path.
    "programs",
    // SYS:Tests - files to try the system on, a directory per subject.
    "tests",
    "tests/datatypes",
    // FONTS: - a contents file and a directory of sizes per family;
    // empty without scripts/fetch-fonts.sh.
    "fonts",
    // HANDLERS: - what a device is, for Mount to read, and the handlers
    // that are not in the ROM.
    "handlers",
    // ENVARC: lives here: the global variables that survive a reboot.
    // Sys/ holds the system's settings, Sys/net/ the network's, and
    // Sys/net/networks/ a Wi-Fi network's passphrase per file.
    "prefs",
    "prefs/env-archive",
    "prefs/env-archive/Sys",
    "prefs/env-archive/Sys/net",
    "prefs/env-archive/Sys/net/networks",
    "prefs/presets",
    "prefs/presets/styles",
};

pub fn build(b: *std.Build) void {
    // ReleaseSmall currently trips over a compiler_rt symbol bug in the
    // Espressif Zig build, and Debug does not fit into IRAM, so default to
    // ReleaseSafe (ReleaseFast works as well).
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseSafe)") orelse .ReleaseSafe;
    const esptool = b.option([]const u8, "esptool", "esptool executable") orelse "esptool";
    const qemu = b.option([]const u8, "qemu", "Espressif qemu-system-xtensa executable") orelse findQemu(b);
    const port = b.option([]const u8, "port", "Serial port used by `zig build flash`") orelse "/dev/ttyACM0";
    const baud = b.option([]const u8, "baud", "Baud rate used by `zig build flash`") orelse "921600";
    const board = b.option(Board, "board", "The board the kernel is built for (default: waveshare_7b)") orelse .waveshare_7b;
    const disk_offset_kib = b.option(u32, "disk-offset", "Where the flash disk starts, in KiB: a multiple of 64 (default: 2048)") orelse default_disk_offset_kib;
    const cores = b.option(u32, "cores", "How many cores the kernel runs on, 1 or 2 (default: what the board's SYSTAG_Cores says)") orelse 0;
    if (cores > 2) std.debug.panic("-Dcores={d}: this chip has two cores", .{cores});
    const net = b.option([]const u8, "net", "The qemu steps' network: none, or a -nic backend such as tap,ifname=tap0,script=no,downscript=no (default: QEMU's user network)");
    const net_dump = b.option([]const u8, "net-dump", "Write every frame of the qemu steps' network to this pcap file");
    const wifi = wifiDir(b, b.option([]const u8, "wifi", "The radio's vendor libraries for wifi.device (default: toolchain/espressif-wifi, which scripts/fetch-wifi.sh fills)"));
    const telnet = b.option(u16, "telnet", "Forward this host port to the machine's port 23 (C:net/ShellServer) on the qemu steps' user network; qemu-display forwards 2323 unless given, and 0 forwards none");
    const network = qemuNetwork(b, net, net_dump, telnet);
    const rs485 = b.option([]const u8, "rs485", "Give the qemu steps' RS-485 port (UART1, rs485.device) to this QEMU serial backend, such as tcp::5020,server,nowait or a pty");
    // The display is the one a person sits at: `telnet localhost 2323`
    // reaches a ShellServer in it without asking for the port.
    const display_network = qemuNetwork(b, net, net_dump, telnet orelse display_telnet_port);
    const disk_offset = disk_offset_kib * 1024;
    if (disk_offset % mmu_page != 0 or disk_offset == 0 or disk_offset >= flash_size) {
        std.debug.panic("-Ddisk-offset={d}: the disk has to start on a 64 KiB page inside the {d} KiB of flash", .{ disk_offset_kib, flash_size / 1024 });
    }
    const disk_size = flash_size - disk_offset;

    const target = b.resolveTargetQuery(poweros_sdk.target_query);

    // The SDK (sdk/, a package of its own): the system's types and the
    // libraries' jump tables, and how a program is built. The kernel builds
    // against it like any program does.
    const sdk_dep = b.dependency("poweros_sdk", .{});
    const sdk = sdk_dep.module("sdk");
    const kernel = addKernel(b, target, optimize, sdk, board, disk_offset, cores);

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
        const load_file = b.fmt("{s}.seg", .{program.name});
        b.getInstallStep().dependOn(&b.addInstallBinFile(disk_dep.namedLazyPath(program.disk), load_file).step);
    }
    if (wifi != null) {
        const wifi_device = poweros_userland.wifi_device;
        b.getInstallStep().dependOn(&b.addInstallBinFile(disk_dep.namedLazyPath(wifi_device.disk), "wifi.device.seg").step);
    }

    // The disk image: the same file system code the handler runs
    // (src/rom/handler/flashfs as a module of its own), driven on the host over a
    // block of memory. Its numbers must be the ones flash.device reports:
    // the disk area of src/layout.zig, 4 KiB sectors, 256-byte pages.
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

    // What goes on the image besides the build's own outputs: the
    // `disk/` tree, then -Dextra. `made` is the directories the image
    // already has, so that none is asked for twice - which mkfs refuses.
    var made: std.ArrayList([]const u8) = .empty;
    made.appendSlice(b.allocator, &image_dirs) catch @panic("OOM");
    const tree = diskTree(b, &made);
    const extras = extraFiles(b, &made);

    const make_disk = b.addRunArtifact(mkfs);
    const disk_bin = make_disk.addOutputFileArg("disk.bin");
    make_disk.addArgs(&.{
        "System",
        "DH0",
        b.fmt("{d}", .{disk_size / disk_sector}),
        b.fmt("{d}", .{disk_sector}),
        b.fmt("{d}", .{disk_page}),
    });
    make_disk.addArgs(&image_dirs);
    // The directories those files need, made before anything goes in
    // them: mkfs takes its paths in the order they are given.
    make_disk.addArgs(tree.dirs);
    for (extras) |extra| make_disk.addArgs(extra.dirs);
    for (poweros_userland.programs) |program| {
        make_disk.addPrefixedFileArg(b.fmt("{s}=", .{program.disk}), disk_dep.namedLazyPath(program.disk));
    }
    for (poweros_userland.files) |file| {
        make_disk.addPrefixedFileArg(b.fmt("{s}=", .{file.disk}), disk_dep.namedLazyPath(file.disk));
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
            make_disk.addArg(b.fmt("fonts/{s}", .{family.name}));
            make_disk.addPrefixedFileArg(b.fmt("fonts/{s}.font=", .{family.name}), out.path(b, b.fmt("{s}.font", .{family.name})));
            for (family.sizes) |rows| {
                const size = b.fmt("{s}/{d}", .{ family.name, rows });
                make_disk.addPrefixedFileArg(b.fmt("fonts/{s}=", .{size}), out.path(b, size));
            }
            for (family.outlines) |file| {
                const at = b.fmt("{s}/{s}", .{ family.name, file });
                make_disk.addPrefixedFileArg(b.fmt("fonts/{s}=", .{at}), out.path(b, at));
            }
        }
        make_disk.addPrefixedFileArg("fonts/spleen.licence=", .{ .cwd_relative = b.pathJoin(&.{ dir, "spleen-2.2.0/LICENSE" }) });
        make_disk.addPrefixedFileArg("fonts/go.licence=", .{ .cwd_relative = b.pathJoin(&.{ dir, "go/README" }) });
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
        make_disk.addArg("certificates");
        make_disk.addPrefixedFileArg("certificates/roots=", store);
    }
    // The `disk/` tree, and then -Dextra last, so that either may
    // replace a file the tree above put there.
    for (tree.files) |file| {
        make_disk.addPrefixedFileArg(b.fmt("{s}=", .{file.path}), b.path(file.host));
    }
    for (extras) |extra| {
        make_disk.addPrefixedFileArg(b.fmt("{s}=", .{extra.path}), .{ .cwd_relative = extra.host });
    }
    b.getInstallStep().dependOn(&b.addInstallBinFile(disk_bin, "disk.bin").step);

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
    const built = addImage(b, esptool, ressize, kernel, disk_bin, disk_offset);
    const image = built.image;
    b.getInstallStep().dependOn(&b.addInstallBinFile(built.kernel_elf, "kernel").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(image, "kernel.bin").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(built.flash_image, "flash.bin").step);

    // The emulator is a board of its own: the `qemu*` steps run its image,
    // with the same disk.
    const emulated = if (board == .qemu) built else addImage(b, esptool, ressize, addKernel(b, target, optimize, sdk, .qemu, disk_offset, cores), disk_bin, disk_offset);
    const flash_image = emulated.flash_image;

    const run_qemu = qemuRun(b, qemu, flash_image, network, qemuConsole(b, &.{"-nographic"}, rs485));
    b.step("qemu", "Boot the kernel in Espressif QEMU (quit with Ctrl-A X)").dependOn(&run_qemu.step);

    const run_display = qemuRun(b, qemu, flash_image, display_network, qemuConsole(b, &.{ "-display", "sdl,show-cursor=off" }, rs485));
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
    const run_disk = qemuRunPath(b, qemu, .{ .cwd_relative = disk_image }, false, network, qemuConsole(b, &.{"-nographic"}, rs485));
    run_disk.step.dependOn(&keep.step);
    b.step("qemu-disk", "Boot in QEMU on a flash image that keeps what is written to the disk").dependOn(&run_disk.step);
    // Target-independent code, tested on the host.
    const test_step = b.step("test", "Run the unit tests on the host");
    for ([_][]const u8{ "src/tests.zig", "src/rom/devs/timer/timeval.zig" }) |path| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = b.graph.host,
        });
        test_mod.addImport("sdk", sdk);
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
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = disk_test_mod })).step);
    // wifi.device's own code compiles for the chip even where the vendor
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
    // Every program and module on the disk compiles: the disk image is
    // made from all of them.
    test_step.dependOn(&make_disk.step);
    // Every board's kernel compiles, not only the one being flashed.
    for (std.enums.values(Board)) |other| {
        if (other != board) test_step.dependOn(&addKernel(b, target, optimize, sdk, other, disk_offset, cores).step);
    }

    // The SDK's interfaces (sdk/interface) come from its .fd files
    // (sdk/fd): the SDK package's `fd` step writes them, and its `test`
    // step - part of this one - fails if one isn't up to date.
    const fd_step = b.step("fd", "Generate the SDK's interfaces (sdk/interface) from sdk/fd");
    fd_step.dependOn(&sdk_dep.builder.top_level_steps.get("fd").?.step);
    test_step.dependOn(&sdk_dep.builder.top_level_steps.get("test").?.step);

    const flash = b.addSystemCommand(&.{ esptool, "--chip", "esp32s3", "--port", port, "--baud", baud, "write-flash", "0x0" });
    flash.addFileArg(image);
    flash.stdio = .inherit;
    flash.has_side_effects = true;
    b.step("flash", "Write the kernel to flash offset 0x0 (replaces the bootloader)").dependOn(&flash.step);

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
        esptool,        "--chip",                       "esp32s3",                    "--port", port, "--baud", baud,
        "erase-region", b.fmt("0x{x}", .{disk_offset}), b.fmt("0x{x}", .{disk_size}),
    });
    erase_disk.stdio = .inherit;
    erase_disk.has_side_effects = true;

    const flash_disk = b.addSystemCommand(&.{ esptool, "--chip", "esp32s3", "--port", port, "--baud", baud, "write-flash", b.fmt("0x{x}", .{disk_offset}) });
    flash_disk.addFileArg(disk_bin);
    flash_disk.stdio = .inherit;
    flash_disk.has_side_effects = true;
    flash_disk.step.dependOn(&erase_disk.step);
    b.step("flash-disk", "Write a fresh disk image to the flash disk (erases what is on it)").dependOn(&flash_disk.step);

    // Both at once: the disk area erased as flash-disk does, then the
    // kernel and the disk image in one write-flash - one connection to the
    // chip for the two, and a ROM and a disk from the same build, which is
    // the pairing a stale disk breaks.
    const flash_all = b.addSystemCommand(&.{ esptool, "--chip", "esp32s3", "--port", port, "--baud", baud, "write-flash", "0x0" });
    flash_all.addFileArg(image);
    flash_all.addArg(b.fmt("0x{x}", .{disk_offset}));
    flash_all.addFileArg(disk_bin);
    flash_all.stdio = .inherit;
    flash_all.has_side_effects = true;
    flash_all.step.dependOn(&erase_disk.step);
    b.step("flash-all", "Write the kernel and a fresh disk image (erases the disk)").dependOn(&flash_all.step);
}

/// One `-Dextra` file: where it goes on the disk image, which file on
/// the host it is, and the directories that have to be made for it.
const Extra = struct {
    /// Its path in the volume's root, e.g. "c/dm" or "dm/GRAPHICS.DAT".
    path: []const u8,
    /// The file on the host, as the option gave it.
    host: []const u8,
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
/// The directories a path needs are made for it, and the ones the image
/// already has are left alone.
fn extraFiles(b: *std.Build, made: *std.ArrayList([]const u8)) []const Extra {
    const given = b.option(
        []const []const u8,
        "extra",
        "A file from outside this tree on the disk image: <path on the disk>=<file on the host>, given once per file",
    ) orelse return &.{};

    var extras: std.ArrayList(Extra) = .empty;
    for (given) |entry| {
        const split = std.mem.indexOfScalar(u8, entry, '=') orelse
            std.debug.panic("-Dextra={s}: no '=' between the path on the disk and the file on the host", .{entry});
        const path = std.mem.trim(u8, entry[0..split], "/");
        const host = entry[split + 1 ..];
        if (path.len == 0 or host.len == 0)
            std.debug.panic("-Dextra={s}: it is <path on the disk>=<file on the host>", .{entry});

        extras.append(b.allocator, .{
            .path = path,
            .host = host,
            .dirs = dirsFor(b, made, path, false),
        }) catch @panic("OOM");
    }
    return extras.toOwnedSlice(b.allocator) catch @panic("OOM");
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
/// has everything but wifi.device, and says so once.
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
        std.log.info("no radio libraries (scripts/fetch-wifi.sh): the disk has no wifi.device", .{});
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
    const merge = b.addSystemCommand(&.{ esptool, "--chip", "esp32s3", "merge-bin", "--fill-flash-size", "16MB", "-o" });
    const flash_image = merge.addOutputFileArg("flash.bin");
    merge.addArg("0x0");
    merge.addFileArg(image);
    merge.addArg(b.fmt("0x{x}", .{disk_offset}));
    merge.addFileArg(disk_bin);
    return .{ .kernel_elf = kernel_elf, .image = image, .flash_image = flash_image };
}

/// The kernel for `board`: src/main.zig with the board's description
/// chosen (src/boards/boards.zig reads `build_options.board`). `cores` 0
/// leaves the number of cores to the board.
fn addKernel(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sdk: *std.Build.Module, board: Board, disk_offset: u32, cores: u32) *std.Build.Step.Compile {
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .unwind_tables = .none,
    });
    kernel_mod.addImport("sdk", sdk);
    const options = b.addOptions();
    options.addOption(Board, "board", board);
    options.addOption(u32, "disk_offset", disk_offset);
    options.addOption(u32, "cores", cores);
    kernel_mod.addOptions("build_options", options);
    kernel_mod.addAssemblyFile(b.path("src/arch/esp32s3/start.S"));
    kernel_mod.addAssemblyFile(b.path("src/arch/esp32s3/cache.S"));
    kernel_mod.addAssemblyFile(b.path("src/arch/esp32s3/stack.S"));

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_mod,
    });
    kernel.setLinkerScript(b.path("kernel.ld"));
    kernel.entry = .{ .symbol_name = "_start" };
    // A section per function, so each function's literals (.literal.<fn>)
    // sit next to its code: l32r reaches only 256 KiB back, and the code in
    // flash is bigger than that (kernel.ld keeps the input order).
    kernel.link_function_sections = true;
    return kernel;
}

/// A QEMU run on a throw-away copy of the image: -snapshot keeps the
/// kernel's writes out of it.
fn qemuRun(b: *std.Build, qemu: []const u8, flash_image: std.Build.LazyPath, network: []const []const u8, extra: []const []const u8) *std.Build.Step.Run {
    return qemuRunPath(b, qemu, flash_image, true, network, extra);
}

/// The emulator's network, as QEMU's arguments. Without them QEMU gives
/// the machine's Ethernet MAC its user network: NAT to the host's, with a
/// gateway and DHCP server at 10.0.2.2 and DNS at 10.0.2.3. `net` names another
/// backend for the MAC (a tap device puts the machine on the real
/// network) or `none`; `dump` writes every frame to a pcap file, which
/// needs the backend to have a name, so it makes the user network explicit.
/// `telnet` forwards that host port to the machine's port 23, where
/// C:net/ShellServer listens; 0 is none. Only qemu-display has one unless
/// asked (2323): a fixed host port keeps a second QEMU from starting, and
/// the display is the run a person sits at.
fn qemuNetwork(b: *std.Build, net: ?[]const u8, dump: ?[]const u8, telnet: ?u16) []const []const u8 {
    if (net) |backend| {
        if (std.mem.eql(u8, backend, "none")) return b.dupeStrings(&.{ "-nic", "none" });
    }
    const forwarded: ?u16 = if (telnet) |port| (if (port == 0) null else port) else null;
    if (net == null and dump == null and forwarded == null) return &.{};
    const forward = if (forwarded) |port| b.fmt(",hostfwd=tcp::{d}-:23", .{port}) else "";
    const nic = b.fmt("{s},id=net0,model=open_eth{s}", .{ net orelse "user", if (net == null) forward else "" });
    const file = dump orelse return b.dupeStrings(&.{ "-nic", nic });
    return b.dupeStrings(&.{ "-nic", nic, "-object", b.fmt("filter-dump,id=dump0,netdev=net0,file={s}", .{file}) });
}

/// The display arguments, then the serial ports: UART0, the console, on
/// the terminal QEMU runs in, and UART1, the RS-485 port, on `rs485`'s
/// backend when one is given. `-nographic` alone puts UART0 on the
/// terminal; naming a second port means naming the first as well.
fn qemuConsole(b: *std.Build, display: []const []const u8, rs485: ?[]const u8) []const []const u8 {
    const graphic = !(display.len == 1 and std.mem.eql(u8, display[0], "-nographic"));
    if (rs485 == null and !graphic) return display;
    var args: std.ArrayList([]const u8) = .empty;
    args.appendSlice(b.allocator, display) catch @panic("OOM");
    args.appendSlice(b.allocator, &.{ "-serial", "mon:stdio" }) catch @panic("OOM");
    if (rs485) |backend| args.appendSlice(b.allocator, &.{ "-serial", backend }) catch @panic("OOM");
    return args.items;
}

/// `snapshot` false lets the kernel write the image, so a disk on it keeps
/// what is written from one boot to the next.
fn qemuRunPath(b: *std.Build, qemu: []const u8, flash_image: std.Build.LazyPath, snapshot: bool, network: []const []const u8, extra: []const []const u8) *std.Build.Step.Run {
    // Like the board's N16R8 module: 8 MB octal PSRAM (-m is the PSRAM size).
    const run = b.addSystemCommand(&.{
        qemu,                                            "-machine", "esp32s3",
        "-m",                                            "8M",       "-global",
        "driver=ssi_psram,property=is_octal,value=true",
    });
    if (snapshot) run.addArg("-snapshot");
    run.addArgs(network);
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
    for ([_][]const u8{ "libs/", "devs/", "handlers/", "classes/" }) |place| {
        if (std.mem.startsWith(u8, disk, place)) return true;
    }
    return false;
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
