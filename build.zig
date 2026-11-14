// SPDX-License-Identifier: MPL-2.0
//! The system's build: the options, the board's kernel, and the calls
//! into build/, where the rest is by what it is about - the boards and
//! their numbers (boards.zig), the host's tools (tools.zig), the disk
//! images (disk.zig) and what was fetched for them (fetched.zig), the
//! kernels and their images and the flash steps (kernel.zig), the
//! emulators' steps (qemu.zig), packages and archives (release.zig), the
//! tests and checks (tests.zig), the `help` step (help.zig). Each phase there is a function that takes
//! what the build has so far in a structure and hands on what it made.

const std = @import("std");
const poweros_sdk = @import("poweros_sdk");
const poweros_userland = @import("poweros_userland");

// The build in files, by what each is about (build/).
const build_boards = @import("build/boards.zig");
const build_disk = @import("build/disk.zig");
const build_fetched = @import("build/fetched.zig");
const build_kernel = @import("build/kernel.zig");
const build_qemu = @import("build/qemu.zig");
const build_release = @import("build/release.zig");
const build_tools = @import("build/tools.zig");
const build_tests = @import("build/tests.zig");
const build_help = @import("build/help.zig");

// The names `build` uses from them.
const Board = build_boards.Board;
const Sets = build_boards.Sets;
const boardSets = build_boards.boardSets;
const chipOf = build_boards.chipOf;
const default_disk_offset_kib = build_boards.default_disk_offset_kib;
const default_rdb_size_kib = build_boards.default_rdb_size_kib;
const disk_sector = build_boards.disk_sector;
const flash_size = build_boards.flash_size;
const mmu_page = build_boards.mmu_page;
const addDiskImages = build_disk.addDiskImages;
const flashDisk = build_disk.flashDisk;
const wifiDir = build_fetched.wifiDir;
const addA64Image = build_kernel.addA64Image;
const addFlashSteps = build_kernel.addFlashSteps;
const addImage = build_kernel.addImage;
const addKernel = build_kernel.addKernel;
const addP4Image = build_kernel.addP4Image;
const addRv64Image = build_kernel.addRv64Image;
const addX64Image = build_kernel.addX64Image;
const findEsptool = build_kernel.findEsptool;
const addRunSteps = build_qemu.addRunSteps;
const display_ssh_port = build_qemu.display_ssh_port;
const display_telnet_port = build_qemu.display_telnet_port;
const findQemu = build_qemu.findQemu;
const q35Network = build_qemu.q35Network;
const q35Speaker = build_qemu.q35Speaker;
const qemuNetwork = build_qemu.qemuNetwork;
const qemuUsb = build_qemu.qemuUsb;
const virtMonitor = build_qemu.virtMonitor;
const virtNetwork = build_qemu.virtNetwork;
const virtSpeaker = build_qemu.virtSpeaker;
const addPackageSteps = build_release.addPackageSteps;
const addReleaseSteps = build_release.addReleaseSteps;
const addHostTools = build_tools.addHostTools;
const addCheckSteps = build_tests.addCheckSteps;

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
    const cores = b.option(u32, "cores", "How many cores the kernel runs on, 1 or 2 - up to 4 on a RISC-V 64 or AArch64 machine, and as many as an x86-64 machine has (default: what the board's SYSTAG_Cores says, which on a PC is every core it has)") orelse 0;
    const selftest = b.option(bool, "selftest", "ESP32-P4: the boot task checks the chip and runs test tasks instead of the shell (default: false)") orelse false;
    // Whether the `disk/` tree goes on the images. It is the builder's own
    // files, and a package to hand out is built without them
    // (`qemu-package` refuses rather than pack them unasked), so this is
    // null when nothing was said about it.
    const disk_tree_option = b.option(bool, "disk-tree", "Put the disk/ tree on the disk images (default: yes, when there is one)");
    const sets_option = b.option([]const u8, "sets", "The sets of programs and files on -Dboard='s disk, separated by commas, or all: base, gui, net, wifi, media, storage, usb, 3d, modbus, commodities, dev, tests (default: what src/boards/<board>/disk.zig names)");
    const board_sets: Sets = if (sets_option) |text|
        poweros_userland.parseSets(text) orelse std.debug.panic("-Dsets={s} names a set there is none of", .{text})
    else
        boardSets(board);
    const memdebug = b.option(bool, "memdebug", "Memory debugging on from exec's start: walls behind blocks, patterns in new and freed memory, wide stack guards (default: false; s3> memdebug and C:MemDebug switch it at run time)") orelse false;
    const logdebug = b.option(bool, "logdebug", "The log keeps the debug lines from exec's start, among them every module's name as it is started: what a boot that stops before there is a shell says for itself (default: false; C:Log LEVEL switches it at run time)") orelse false;
    const posfs_soak = b.option(u32, "posfs-soak", "`zig build test`: run posfs's power-cut test on this many more seeds, each on flash, a card and a stick (default: 0)") orelse 0;
    const most_cores: u32 = switch (chipOf(board)) {
        // The machine's own tables say how many cores it has, so there is
        // no figure here to hold -Dcores against.
        .x64uefi => 0,
        .rv64sbi, .a64psci => 4,
        .esp32s3, .esp32p4 => 2,
    };
    if (most_cores != 0 and cores > most_cores) std.debug.panic("-Dcores={d}: this chip has {d} cores", .{ cores, most_cores });
    const net = b.option([]const u8, "net", "The network of the qemu, virt, virt64 and q35 steps: none, or a QEMU network backend such as tap,ifname=tap0,script=no,downscript=no (default: QEMU's user network)");
    const net_dump = b.option([]const u8, "net-dump", "Write every frame of the qemu, virt, virt64 and q35 steps' network to this pcap file");
    const wifi = wifiDir(b, b.option([]const u8, "wifi", "The radio's vendor libraries for esp32s3wifi.device (default: toolchain/espressif-wifi, which scripts/fetch-wifi.sh fills)"));
    const telnet = b.option(u16, "telnet", "Forward this host port to the machine's port 23 (C:net/ShellServer) on the qemu, virt, virt64 and q35 display steps' user network; qemu-display forwards 2323 unless given, and 0 forwards none");
    const ssh_port = b.option(u16, "ssh", "Forward this host port to the machine's port 22 (C:net/ShellServer SSH) on the qemu, virt, virt64 and q35 display steps' user network; qemu-display forwards 2222 unless given, and 0 forwards none");
    const network = qemuNetwork(b, net, net_dump, telnet, ssh_port);
    const virt_network = virtNetwork(b, net, net_dump, telnet, ssh_port);
    const q35_network = q35Network(b, net, net_dump, telnet, ssh_port);
    const rs485 = b.option([]const u8, "rs485", "Give the qemu steps' RS-485 port (UART1, rs485.device) to this QEMU serial backend, such as tcp::5020,server,nowait or a pty");
    const slip_line = b.option([]const u8, "slip", "Give the qemu steps' UART1 (serial.device unit 1, a SLIP line) to this QEMU serial backend, such as tcp::5021,server,nowait; not with -Drs485");
    if (rs485 != null and slip_line != null) std.debug.panic("-Drs485 and -Dslip: both are UART1", .{});
    // UART1's backend: the RS-485 port's or a SLIP line's.
    const uart1 = rs485 orelse slip_line;
    const usb_devices = b.option([]const u8, "usb", "Plug these QEMU USB devices into the qemu steps' USB port, comma-separated (usb-hub,usb-kbd,usb-mouse); an item with '=' is a property of the device before it (usb-kbd,port=1,id=kbd)");
    const audio_backend = b.option([]const u8, "audio", "The sound of the virt, virt64 and q35 steps on this QEMU audio backend - an -audiodev's driver and options: pa, pipewire, alsa, sdl, none, wav,path=out.wav (default: QEMU's own choice among the backends it has)");
    const virt_speaker = virtSpeaker(b, audio_backend);
    const q35_speaker = q35Speaker(b, audio_backend);
    const virt_ui = b.option([]const u8, "virt-ui", "QEMU's -display for the virt, virt64 and q35 display steps (default: gtk,show-cursor=off,zoom-to-fit=off - GTK's window at the picture's size, 1:1; default,show-cursor=off takes SDL, or VNC, where there is no GTK)") orelse "gtk,show-cursor=off,zoom-to-fit=off";
    const virt_monitor = virtMonitor(b, b.option([]const u8, "virt-qmp", "Open a QMP monitor on this Unix socket in the virt, virt64 and q35 display steps, which scripts/qemu-shot.py takes the running machine's picture through (such as /tmp/poweros.qmp)"));
    const usb_disk = b.option([]const u8, "usb-disk", "Plug a USB stick into the qemu steps' USB port whose blocks are this raw image file (-snapshot runs keep it unchanged)");
    const ovmf_code = b.option([]const u8, "ovmf-code", "The x64 UEFI firmware the q35 steps start (default: /usr/share/edk2/x64/OVMF_CODE.4m.fd)") orelse "/usr/share/edk2/x64/OVMF_CODE.4m.fd";
    const ovmf_vars = b.option([]const u8, "ovmf-vars", "The firmware's variable store the q35 steps start from, copied into work/ on its first run (default: /usr/share/edk2/x64/OVMF_VARS.4m.fd)") orelse "/usr/share/edk2/x64/OVMF_VARS.4m.fd";
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
    const x64_target = b.resolveTargetQuery(poweros_sdk.x64_target_query);
    const kernel_target = switch (chipOf(board)) {
        .esp32s3 => target,
        .esp32p4 => p4_target,
        .rv64sbi => rv64_target,
        .a64psci => a64_target,
        .x64uefi => x64_target,
    };

    // The SDK (sdk/, a package of its own): the system's types and the
    // libraries' jump tables, and how a program is built. The kernel builds
    // against it like any program does.
    const sdk_dep = b.dependency("poweros_sdk", .{});
    const sdk = sdk_dep.module("sdk");
    const kernel = addKernel(b, kernel_target, optimize, sdk, board, disk_offset, cores, selftest, memdebug, logdebug);

    // What goes on the disk (src/disk, a package of its own): the
    // commands, the test programs, the modules loaded from LIBS:, DEVS:
    // and HANDLERS:, and the scripts, each built against the SDK and
    // handed over under its place on the disk. A flash board's load
    // files are installed beside its kernel as well, to compare with
    // `List C:`: the ESP32-S3's here, the ESP32-P4's where its package
    // is made, below.
    const disk_dep = if (wifi) |dir|
        b.dependency("poweros_userland", .{ .optimize = optimize, .wifi = dir })
    else
        b.dependency("poweros_userland", .{ .optimize = optimize });
    if (chipOf(board) == .esp32s3) {
        for (poweros_userland.programs) |program| {
            if (!poweros_userland.builtFor(program, .esp32s3)) continue;
            const load_file = b.fmt("{s}.seg", .{program.name});
            b.getInstallStep().dependOn(&b.addInstallBinFile(disk_dep.namedLazyPath(program.disk), load_file).step);
        }
        if (wifi != null) {
            const wifi_device = poweros_userland.wifi_device;
            b.getInstallStep().dependOn(&b.addInstallBinFile(disk_dep.namedLazyPath(wifi_device.disk), "esp32s3wifi.device.seg").step);
        }
    }

    const host_tools = addHostTools(b, .{
        .disk_dep = disk_dep,
        .sdk = sdk,
    });
    const mkfs = host_tools.mkfs;
    const mkicon = host_tools.mkicon;
    const mkstick = host_tools.mkstick;
    const posfsck = host_tools.posfsck;
    const svgcompare = host_tools.svgcompare;

    const disk_images = addDiskImages(b, .{
        .board = board,
        .board_sets = board_sets,
        .dh0_sectors = dh0_sectors,
        .disk_dep = disk_dep,
        .disk_rdb_blocks = disk_rdb_blocks,
        .disk_size = disk_size,
        .disk_tree_option = disk_tree_option,
        .mkfs = mkfs,
        .mkicon = mkicon,
        .optimize = optimize,
        .sdk = sdk,
        .sdk_dep = sdk_dep,
        .wifi = wifi,
    });
    const a64_disk_bin = disk_images.a64_disk_bin;
    const a64_system_disk = disk_images.a64_system_disk;
    const a64_tree = disk_images.a64_tree;
    const disks = disk_images.disks;
    const flash_disks = disk_images.flash_disks;
    const make_a64_disk = disk_images.make_a64_disk;
    const make_rv64_disk = disk_images.make_rv64_disk;
    const make_x64_disk = disk_images.make_x64_disk;
    const rv64_disk_bin = disk_images.rv64_disk_bin;
    const rv64_system_disk = disk_images.rv64_system_disk;
    const rv64_tree = disk_images.rv64_tree;
    const tree = disk_images.tree;
    const x64_disk_bin = disk_images.x64_disk_bin;
    const x64_medium_bin = disk_images.x64_medium_bin;
    const x64_system_disk = disk_images.x64_system_disk;
    const x64_tree = disk_images.x64_tree;

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
        .esp32s3 => addImage(b, esptool, ressize, kernel, flashDisk(flash_disks, board).?, disk_offset),
        .esp32p4 => addP4Image(b, esptool, ramimage, kernel, flashDisk(flash_disks, board).?, disk_offset),
        .rv64sbi => addRv64Image(b, kernel),
        .a64psci => addA64Image(b, kernel),
        .x64uefi => addX64Image(b, kernel),
    };
    const image = built.image;
    b.getInstallStep().dependOn(&b.addInstallBinFile(built.kernel_elf, "kernel").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(image, "kernel.bin").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(built.flash_image, "flash.bin").step);
    // Only the board's own: the emulator's image is made beside it on
    // every build, and the two parts must not share the name.
    if (built.flash_part) |part| b.getInstallStep().dependOn(&b.addInstallBinFile(part, "kernel-flash.bin").step);

    const packaging = addPackageSteps(b, .{
        .a64_disk_bin = a64_disk_bin,
        .a64_tree = a64_tree,
        .board = board,
        .image = image,
        .make_a64_disk = make_a64_disk,
        .make_rv64_disk = make_rv64_disk,
        .make_x64_disk = make_x64_disk,
        .optimize = optimize,
        .rv64_disk_bin = rv64_disk_bin,
        .rv64_tree = rv64_tree,
        .sdk = sdk,
        .x64_disk_bin = x64_disk_bin,
        .x64_tree = x64_tree,
    });
    const boot_files = packaging.boot_files;
    const mkpackage = packaging.mkpackage;
    const serve = packaging.serve;
    const uefi_stub = packaging.uefi_stub;

    const run_steps = addRunSteps(b, .{
        .a64_system_disk = a64_system_disk,
        .a64_target = a64_target,
        .board = board,
        .built = built,
        .cores = cores,
        .disk_offset = disk_offset,
        .display_network = display_network,
        .esptool = esptool,
        .flash_disks = flash_disks,
        .kernel = kernel,
        .logdebug = logdebug,
        .memdebug = memdebug,
        .mkfs = mkfs,
        .mkstick = mkstick,
        .network = network,
        .optimize = optimize,
        .ovmf_code = ovmf_code,
        .ovmf_vars = ovmf_vars,
        .p4_target = p4_target,
        .q35_network = q35_network,
        .q35_speaker = q35_speaker,
        .qemu = qemu,
        .ramimage = ramimage,
        .ressize = ressize,
        .rv64_system_disk = rv64_system_disk,
        .rv64_target = rv64_target,
        .sdk = sdk,
        .selftest = selftest,
        .target = target,
        .uart1 = uart1,
        .uefi_stub = uefi_stub,
        .usb = usb,
        .virt_monitor = virt_monitor,
        .virt_network = virt_network,
        .virt_speaker = virt_speaker,
        .virt_ui = virt_ui,
        .x64_medium_bin = x64_medium_bin,
        .x64_system_disk = x64_system_disk,
        .x64_target = x64_target,
    });
    const blank_work_disk = run_steps.blank_work_disk;

    addReleaseSteps(b, .{
        .a64_disk_bin = a64_disk_bin,
        .a64_system_disk = a64_system_disk,
        .a64_target = a64_target,
        .a64_tree = a64_tree,
        .blank_work_disk = blank_work_disk,
        .board = board,
        .boot_files = boot_files,
        .built = built,
        .cores = cores,
        .disk_offset = disk_offset,
        .disk_size = disk_size,
        .disk_tree_option = disk_tree_option,
        .esptool = esptool,
        .flash_disks = flash_disks,
        .logdebug = logdebug,
        .memdebug = memdebug,
        .mkpackage = mkpackage,
        .optimize = optimize,
        .p4_target = p4_target,
        .ramimage = ramimage,
        .ressize = ressize,
        .rv64_disk_bin = rv64_disk_bin,
        .rv64_system_disk = rv64_system_disk,
        .rv64_target = rv64_target,
        .rv64_tree = rv64_tree,
        .sdk = sdk,
        .target = target,
        .tree = tree,
        .uefi_stub = uefi_stub,
        .x64_disk_bin = x64_disk_bin,
        .x64_target = x64_target,
        .x64_tree = x64_tree,
    });

    addCheckSteps(b, .{
        .a64_target = a64_target,
        .board = board,
        .built = built,
        .cores = cores,
        .disk_dep = disk_dep,
        .disk_offset = disk_offset,
        .disks = disks,
        .mkicon = mkicon,
        .mkpackage = mkpackage,
        .optimize = optimize,
        .p4_target = p4_target,
        .posfs_soak = posfs_soak,
        .posfsck = posfsck,
        .rv64_target = rv64_target,
        .sdk = sdk,
        .sdk_dep = sdk_dep,
        .serve = serve,
        .svgcompare = svgcompare,
        .target = target,
        .wifi = wifi,
        .x64_target = x64_target,
    });

    addFlashSteps(b, .{
        .a64_disk_bin = a64_disk_bin,
        .baud = baud,
        .board = board,
        .built = built,
        .disk_offset = disk_offset,
        .disk_size = disk_size,
        .esptool = esptool,
        .flash_disks = flash_disks,
        .port = port,
        .rv64_disk_bin = rv64_disk_bin,
        .x64_disk_bin = x64_disk_bin,
    });

    // Last, so that it lists every step and option above.
    build_help.addHelpStep(b);
}
