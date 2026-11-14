// SPDX-License-Identifier: MPL-2.0
//! What is handed over: a release package for a machine that installs
//! itself, an archive for each kind of board, and a tool's report printed
//! after the step that made it.

const std = @import("std");
const build_boards = @import("boards.zig");
const build_disk = @import("disk.zig");
const build_kernel = @import("kernel.zig");

const Board = build_boards.Board;
const Chip = build_boards.Chip;
const boardConsole = build_boards.boardConsole;
const chipOf = build_boards.chipOf;
const flash_boards = build_boards.flash_boards;
const release_boards = build_boards.release_boards;
const BoardDisks = build_disk.BoardDisks;
const BootFile = build_disk.BootFile;
const Tree = build_disk.Tree;
const bootFiles = build_disk.bootFiles;
const uefi_loader_path = build_disk.uefi_loader_path;
const Image = build_kernel.Image;
const addA64Image = build_kernel.addA64Image;
const addImage = build_kernel.addImage;
const addKernel = build_kernel.addKernel;
const addP4Image = build_kernel.addP4Image;
const addRv64Image = build_kernel.addRv64Image;
const addUefiStub = build_kernel.addUefiStub;
const addX64Image = build_kernel.addX64Image;
const p4_flash_part_offset = build_kernel.p4_flash_part_offset;

/// Where everything a release is made of is written: `release/` in the
/// root of the tree, beside zig-out and out of the repository, so that
/// what is uploaded is in one place and nothing else is in it. It is the
/// install prefix's neighbour, which is how a build step reaches it.
pub const release_dir: std.Build.InstallDir = .{ .custom = "../release" };

/// A package to hand out must not carry the `disk/` tree unasked: those
/// are the builder's own files, and the network settings among them hold
/// a passphrase. Nothing is refused when that tree is empty, or when
/// `-Ddisk-tree` has said what to do with it either way.
/// A tool's report, read back out of the file the build captured it in
/// and written to the terminal.
///
/// A run whose output file the build caches has its standard output sent
/// nowhere, and what it writes to the error stream is printed under a
/// banner that says a command failed. So a tool that has something to say
/// to whoever asked for its output says it on the standard output, the
/// run captures it, and this step prints it once the output is in place.
const Report = struct {
    step: std.Build.Step,
    text: std.Build.LazyPath,
    /// Printed after the tool's own report: what the kernel on the medium
    /// will say about itself, which is the one thing the medium cannot be
    /// looked at for.
    tail: []const u8,

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        const one: *Report = @fieldParentPtr("step", step);
        const b = step.owner;
        const at = one.text.getPath3(b, step);
        const said = try at.root_dir.handle.readFileAlloc(b.graph.io, at.sub_path, options.gpa, .limited(64 * 1024));
        defer options.gpa.free(said);
        std.debug.print("{s}{s}", .{ said, one.tail });
    }
};

/// The step that prints `text`, and `tail` after it, once `after` has run.
pub fn addReport(b: *std.Build, text: std.Build.LazyPath, tail: []const u8, after: *std.Build.Step) *Report {
    const one = b.allocator.create(Report) catch @panic("OOM");
    one.* = .{
        .step = .init(.{
            .id = .custom,
            .name = "report",
            .owner = b,
            .makeFn = Report.make,
        }),
        .text = text,
        .tail = tail,
    };
    text.addStepDependencies(&one.step);
    one.step.dependOn(after);
    return one;
}

fn refusePrivateTree(b: *std.Build, step: *std.Build.Step, said: ?bool, tree: Tree, what: []const u8) void {
    if (said != null or tree.files.len == 0) return;
    step.dependOn(&b.addFail(b.fmt(
        "{s}: {d} files from the disk/ tree are on this image, and that tree is yours - the network settings in it hold a passphrase. Build with -Ddisk-tree=false for a package to hand out, or -Ddisk-tree=true to pack it as it is.",
        .{ what, tree.files.len },
    )).step);
}

/// What building another board's kernel takes, so that a release can
/// build every board's in one go: each chip's target and its disk image,
/// in `Chip`'s order, and what an image is made with.
const BoardBuild = struct {
    targets: [5]std.Build.ResolvedTarget,
    disks: BoardDisks,
    optimize: std.builtin.OptimizeMode,
    sdk: *std.Build.Module,
    esptool: []const u8,
    ressize: *std.Build.Step.Compile,
    ramimage: *std.Build.Step.Compile,
    disk_offset: u32,
    cores: u32,
    memdebug: bool,
    logdebug: bool,
};

/// `board`'s kernel, and the image of it that board is started from.
fn addBoardImage(b: *std.Build, with: BoardBuild, board: Board) Image {
    const chip = chipOf(board);
    const slot = @intFromEnum(chip);
    const kernel = addKernel(b, with.targets[slot], with.optimize, with.sdk, board, with.disk_offset, with.cores, false, with.memdebug, with.logdebug);
    return switch (chip) {
        .esp32s3 => addImage(b, with.esptool, with.ressize, kernel, with.disks.of(board), with.disk_offset),
        .esp32p4 => addP4Image(b, with.esptool, with.ramimage, kernel, with.disks.of(board), with.disk_offset),
        .rv64sbi => addRv64Image(b, kernel),
        .a64psci => addA64Image(b, kernel),
        .x64uefi => addX64Image(b, kernel),
    };
}

/// The name a machine's disk image is read under, which is what its
/// firmware looks for beside the kernel.
pub fn ramDiskName(chip: Chip) []const u8 {
    return switch (chip) {
        .rv64sbi => "disk-rv64.bin",
        .a64psci => "disk-a64.bin",
        .x64uefi => "disk-x64.bin",
        .esp32s3 => "disk.bin",
        .esp32p4 => "disk-esp32p4.bin",
    };
}

/// What a release package holds besides the kernel: the volume's files as
/// a tree, the disk image the firmware loads beside the kernel, and
/// whatever `-Dboot=` adds.
const PackageParts = struct {
    tree: std.Build.LazyPath,
    ram_disk: std.Build.LazyPath,
    boot_files: []const BootFile,
    /// The loader a machine whose firmware is UEFI starts, where there
    /// is one. It belongs in the package's `boot/` as much as in the
    /// image's `SYS:Storage/Boot`: a machine installed or brought up to
    /// date from a package writes the boot partition from this drawer,
    /// and one written without the loader is one the firmware finds
    /// nothing in.
    boot_loader: ?std.Build.LazyPath = null,
};

/// A release package for `board` - `system/` the volume, `boot/` what the
/// firmware loads, a manifest over both - gathered, checked against that
/// manifest, and installed into the release directory. `step` is what the
/// two depend on; the answer is the gathered directory, which `serve`
/// hands out.
fn addPackage(
    b: *std.Build,
    step: *std.Build.Step,
    mkpackage: *std.Build.Step.Compile,
    board: Board,
    kernel_image: std.Build.LazyPath,
    parts: PackageParts,
) std.Build.LazyPath {
    const chip = chipOf(board);
    const name = b.fmt("package-{s}", .{@tagName(board)});
    const gather = b.addRunArtifact(mkpackage);
    const gathered = gather.addPrefixedOutputDirectoryArg("--into=", name);
    gather.addArg(b.fmt("--chip={s}", .{@tagName(chip)}));
    // The board as well as the chip: two boards share a chip and every
    // path in the package, and their kernels differ in what the board has
    // and where it is.
    gather.addArg(b.fmt("--board={s}", .{@tagName(board)}));
    gather.addPrefixedDirectoryArg("--system=", parts.tree);
    gather.addPrefixedFileArg("boot/kernel.bin=", kernel_image);
    gather.addPrefixedFileArg(b.fmt("boot/{s}=", .{ramDiskName(chip)}), parts.ram_disk);
    if (parts.boot_loader) |loader| gather.addPrefixedFileArg("boot/" ++ uefi_loader_path ++ "=", loader);
    // What the firmware of this board reads beside them.
    if (board == .rpi_cm5) gather.addPrefixedFileArg("boot/config.txt=", b.path("src/boards/rpi_cm5/config.txt"));
    for (parts.boot_files) |file| {
        gather.addPrefixedFileArg(b.fmt("boot/{s}=", .{file.name}), .{ .cwd_relative = file.host });
    }
    // The package held against the manifest it was just given, so that a
    // package which is installed from is one that was checked.
    const check = b.addRunArtifact(mkpackage);
    check.addArg("--check");
    check.addDirectoryArg(gathered);
    step.dependOn(&check.step);
    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = gathered,
        .install_dir = release_dir,
        .install_subdir = name,
    }).step);
    return gathered;
}

/// The disks a QEMU machine's archive holds, and the cores its script
/// starts the machine with.
const QemuParts = struct {
    system_disk: std.Build.LazyPath,
    work_disk: std.Build.LazyPath,
    cores: u32,
};

/// An archive somebody downloads, unpacks and runs: the kernel, the two
/// disks, `tools/qemupackage/run.sh` as it is, and the `machine.conf`
/// that script reads. The disks are mostly holes - 256 MB with a tenth of
/// it written, a blank 1 GB work disk - so the archive keeps them as
/// holes (`tar -S`) and they are holes again where it is unpacked.
fn addQemuPackage(b: *std.Build, step: *std.Build.Step, board: Board, kernel_image: std.Build.LazyPath, parts: QemuParts) void {
    const rv64 = chipOf(board) == .rv64sbi;
    const name = b.fmt("poweros-{s}", .{@tagName(board)});
    const bundle = b.addWriteFiles();
    _ = bundle.addCopyFile(kernel_image, b.fmt("{s}/kernel.bin", .{name}));
    _ = bundle.addCopyFile(parts.system_disk, b.fmt("{s}/system.bin", .{name}));
    _ = bundle.addCopyFile(parts.work_disk, b.fmt("{s}/work.bin", .{name}));
    _ = bundle.addCopyFile(b.path("tools/qemupackage/run.sh"), b.fmt("{s}/run.sh", .{name}));
    _ = bundle.addCopyFile(b.path("tools/qemupackage/bundle.md"), b.fmt("{s}/README.md", .{name}));
    _ = bundle.add(b.fmt("{s}/machine.conf", .{name}), b.fmt(
        \\# What ./run.sh starts, and the files it starts it on. The
        \\# machine's own arguments are QEMU's, as the project's README
        \\# gives them for this board.
        \\BOARD={s}
        \\QEMU={s}
        \\QEMU_PACKAGE="{s}"
        \\MACHINE="{s}"
        \\CPU="{s}"
        \\MEMORY={s}
        \\CORES={d}
        \\SIZE=1280x720
        \\KERNEL=kernel.bin
        \\SYSTEM=system.bin
        \\WORK=work.bin
        \\
    , .{
        @tagName(board),
        if (rv64) "qemu-system-riscv64" else "qemu-system-aarch64",
        if (rv64) "QEMU for RISC-V 64 (qemu-system-riscv64)" else "QEMU for AArch64 (qemu-system-aarch64)",
        if (rv64) "-M virt -bios default" else "-M virt,gic-version=2,highmem=off",
        if (rv64) "" else "-cpu cortex-a76",
        "512M",
        // What the board's system tag list says
        // (src/boards/<board>/system.zig: SYSTAG_Cores is 4 on both virt
        // machines), unless -Dcores said otherwise.
        if (parts.cores == 0) 4 else parts.cores,
    }));
    addArchive(b, step, bundle, name);
}

/// Where an ESP32 board's flash disk is, and the image of it.
const EspParts = struct {
    disk: std.Build.LazyPath,
    disk_offset: u32,
    disk_size: u32,
};

/// An archive somebody downloads, unpacks and writes to a board: the
/// kernel's parts, the flash disk, `tools/espackage/flash.sh` as it is,
/// and the `machine.conf` that script reads - the chip, where each piece
/// goes in the flash, and which port the board's console is.
fn addEspPackage(b: *std.Build, step: *std.Build.Step, board: Board, image: Image, parts: EspParts) void {
    const chip = chipOf(board);
    const name = b.fmt("poweros-{s}", .{@tagName(board)});
    const disk_name = ramDiskName(chip);
    const bundle = b.addWriteFiles();
    _ = bundle.addCopyFile(image.image, b.fmt("{s}/kernel.bin", .{name}));
    if (image.flash_part) |part| _ = bundle.addCopyFile(part, b.fmt("{s}/kernel-flash.bin", .{name}));
    _ = bundle.addCopyFile(parts.disk, b.fmt("{s}/{s}", .{ name, disk_name }));
    _ = bundle.addCopyFile(b.path("tools/espackage/flash.sh"), b.fmt("{s}/flash.sh", .{name}));
    _ = bundle.addCopyFile(b.path("tools/espackage/bundle.md"), b.fmt("{s}/README.md", .{name}));
    // The kernel is one piece on the ESP32-S3, written at 0; on the
    // ESP32-P4 it is two, the part the ROM loads into memory and the part
    // that runs in place from flash.
    const kernel_parts = if (image.flash_part == null)
        "0x0=kernel.bin"
    else
        b.fmt("0x2000=kernel.bin 0x{x}=kernel-flash.bin", .{p4_flash_part_offset});
    _ = bundle.add(b.fmt("{s}/machine.conf", .{name}), b.fmt(
        \\# What ./flash.sh writes, and where each piece goes in the flash.
        \\# The offsets are this build's own (-Ddisk-offset).
        \\BOARD={s}
        \\CHIP={s}
        \\KERNEL="{s}"
        \\DISK="0x{x}={s}"
        \\DISK_SIZE=0x{x}
        \\PORT={s}
        \\BAUD=921600
        \\CONSOLE="{s}"
        \\
    , .{
        @tagName(board),
        @tagName(chip),
        kernel_parts,
        parts.disk_offset,
        disk_name,
        parts.disk_size,
        "/dev/ttyACM0",
        boardConsole(board),
    }));
    addArchive(b, step, bundle, name);
}

/// What a board's boot archive holds besides the kernel: the disk image
/// its loader puts in RAM beside it, and what `-Dboot=` added.
const BootParts = struct {
    ram_disk: std.Build.LazyPath,
    /// A loader the firmware starts instead of the kernel, where the
    /// machine has one, and where on the partition it goes. A board
    /// whose firmware loads the kernel itself passes none.
    loader: ?std.Build.LazyPath = null,
    loader_path: []const u8 = "",
    boot_files: []const BootFile,
};

/// An archive somebody downloads, unpacks and copies onto the partition
/// a board's firmware reads: the kernel, the disk image the system runs
/// from, `config.txt` where the board has one, and a `write.sh` that
/// copies them there. A board whose disk is in RAM needs nothing else to
/// start, and installs itself onto a card or an SSD from inside.
fn addBootPackage(b: *std.Build, step: *std.Build.Step, board: Board, kernel_image: std.Build.LazyPath, parts: BootParts) void {
    const chip = chipOf(board);
    const name = b.fmt("poweros-{s}", .{@tagName(board)});
    const disk_name = ramDiskName(chip);
    const bundle = b.addWriteFiles();
    _ = bundle.addCopyFile(kernel_image, b.fmt("{s}/kernel.bin", .{name}));
    _ = bundle.addCopyFile(parts.ram_disk, b.fmt("{s}/{s}", .{ name, disk_name }));
    _ = bundle.addCopyFile(b.path("tools/bootpackage/write.sh"), b.fmt("{s}/write.sh", .{name}));
    _ = bundle.addCopyFile(b.path("tools/bootpackage/bundle.md"), b.fmt("{s}/README.md", .{name}));
    // What the firmware reads, in the order write.sh copies them - the
    // loader first on a machine that has one, since it is what the
    // firmware starts.
    var files = b.fmt("kernel.bin {s}", .{disk_name});
    if (parts.loader) |loader| {
        _ = bundle.addCopyFile(loader, b.fmt("{s}/{s}", .{ name, parts.loader_path }));
        files = b.fmt("{s} {s}", .{ parts.loader_path, files });
    }
    if (board == .rpi_cm5) {
        _ = bundle.addCopyFile(b.path("src/boards/rpi_cm5/config.txt"), b.fmt("{s}/config.txt", .{name}));
        files = b.fmt("{s} config.txt", .{files});
    }
    for (parts.boot_files) |file| {
        _ = bundle.addCopyFile(.{ .cwd_relative = file.host }, b.fmt("{s}/{s}", .{ name, file.name }));
        files = b.fmt("{s} {s}", .{ files, file.name });
    }
    _ = bundle.add(b.fmt("{s}/machine.conf", .{name}), b.fmt(
        \\# What ./write.sh copies onto the partition this board's firmware
        \\# reads, and what the board's console is.
        \\BOARD={s}
        \\CHIP={s}
        \\FILES="{s}"
        \\CONSOLE="{s}"
        \\
    , .{ @tagName(board), @tagName(chip), files, boardConsole(board) }));
    addArchive(b, step, bundle, name);
}

/// What an archive takes, whichever board it is for: each chip's disk
/// image in `Chip`'s order, the two virt machines' system disks and the
/// blank work disk they share, what `-Dboot=` added, where an ESP32
/// board's flash disk is, and the cores a machine is started with.
const ArchiveParts = struct {
    disks: BoardDisks,
    rv64_system: std.Build.LazyPath,
    a64_system: std.Build.LazyPath,
    work_disk: std.Build.LazyPath,
    /// The x86-64 machine's loader, which its firmware starts instead of
    /// the kernel; no other board has one.
    uefi_stub: std.Build.LazyPath,
    boot_files: []const BootFile,
    disk_offset: u32,
    disk_size: u32,
    cores: u32,
};

/// The archive a board is handed over in. What that is differs with the
/// machine: QEMU's two are started by a script, an ESP32 board is written
/// by one, and a board whose firmware loads a kernel from a partition has
/// those files copied onto it. The two emulators have none - neither is a
/// machine anybody has by downloading an archive.
fn addBoardArchive(b: *std.Build, step: *std.Build.Step, board: Board, image: Image, parts: ArchiveParts) void {
    const disk = parts.disks.of(board);
    switch (board) {
        .qemu, .esp32p4_emu => step.dependOn(&b.addFail(b.fmt(
            "archive: {s} is an emulator, not a machine anybody has by downloading an archive - Espressif's QEMU is built here (scripts/build-qemu.sh) and esp-emulator fetched (scripts/fetch-esp-emu.sh). Every other board has one.",
            .{@tagName(board)},
        )).step),
        .waveshare_7b, .es3c35p, .olimex_p4pc, .crowpanel_p4 => addEspPackage(b, step, board, image, .{
            .disk = disk,
            .disk_offset = parts.disk_offset,
            .disk_size = parts.disk_size,
        }),
        .qemu_virt, .qemu_virt_a64 => addQemuPackage(b, step, board, image.image, .{
            .system_disk = if (chipOf(board) == .rv64sbi) parts.rv64_system else parts.a64_system,
            .work_disk = parts.work_disk,
            .cores = parts.cores,
        }),
        // The x86-64 machine is started by its firmware off a boot
        // partition, as a PC is: the files it reads are copied there.
        .qemu_q35 => addBootPackage(b, step, board, image.image, .{
            .ram_disk = disk,
            .loader = parts.uefi_stub,
            .loader_path = "EFI/BOOT/BOOTX64.EFI",
            .boot_files = parts.boot_files,
        }),
        .visionfive2, .rpi_cm5 => addBootPackage(b, step, board, image.image, .{
            .ram_disk = disk,
            .boot_files = parts.boot_files,
        }),
    }
}

/// `bundle`'s directory `name` packed into `release/<name>.tar.gz`, and
/// left beside it as a directory too, so it can be tried before it is
/// handed out. Holes are kept as holes (`-S`).
fn addArchive(b: *std.Build, step: *std.Build.Step, bundle: *std.Build.Step.WriteFile, name: []const u8) void {
    const archive = b.addSystemCommand(&.{ "tar", "-czSf" });
    const packed_file = archive.addOutputFileArg(b.fmt("{s}.tar.gz", .{name}));
    archive.addArg("-C");
    archive.addDirectoryArg(bundle.getDirectory());
    archive.addArg(name);
    step.dependOn(&b.addInstallFileWithDir(packed_file, release_dir, b.fmt("{s}.tar.gz", .{name})).step);
    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = bundle.getDirectory().path(b, name),
        .install_dir = release_dir,
        .install_subdir = name,
    }).step);
}

/// `Chip`'s names, for a message.
pub fn chipNames(b: *std.Build) []const u8 {
    var names: std.ArrayList(u8) = .empty;
    for (std.enums.values(Chip), 0..) |chip, i| {
        if (i != 0) names.appendSlice(b.allocator, ", ") catch @panic("OOM");
        names.appendSlice(b.allocator, @tagName(chip)) catch @panic("OOM");
    }
    return names.items;
}

/// What `addPackageSteps` takes from the build so far.
pub const PackageStepsWith = struct {
    a64_disk_bin: std.Build.LazyPath,
    a64_tree: std.Build.LazyPath,
    board: Board,
    image: std.Build.LazyPath,
    make_a64_disk: *std.Build.Step.Run,
    make_rv64_disk: *std.Build.Step.Run,
    make_x64_disk: *std.Build.Step.Run,
    optimize: std.builtin.OptimizeMode,
    rv64_disk_bin: std.Build.LazyPath,
    rv64_tree: std.Build.LazyPath,
    sdk: *std.Build.Module,
    x64_disk_bin: std.Build.LazyPath,
    x64_tree: std.Build.LazyPath,
};

/// What `addPackageSteps` hands on to the rest of the build.
pub const MadePackageSteps = struct {
    boot_files: []const BootFile,
    mkpackage: *std.Build.Step.Compile,
    serve: *std.Build.Step.Compile,
    uefi_stub: *std.Build.Step.Compile,
};

/// The `package` and `serve` steps: the release package of -Dboard=,
/// and the server that hands it out.
pub fn addPackageSteps(b: *std.Build, with: PackageStepsWith) MadePackageSteps {
    const a64_disk_bin = with.a64_disk_bin;
    const a64_tree = with.a64_tree;
    const board = with.board;
    const image = with.image;
    const make_a64_disk = with.make_a64_disk;
    const make_rv64_disk = with.make_rv64_disk;
    const make_x64_disk = with.make_x64_disk;
    const optimize = with.optimize;
    const rv64_disk_bin = with.rv64_disk_bin;
    const rv64_tree = with.rv64_tree;
    const sdk = with.sdk;
    const x64_disk_bin = with.x64_disk_bin;
    const x64_tree = with.x64_tree;

    // `package` - everything a machine installs from, and is later
    // brought up to date against, in one directory: the volume's files
    // under system/, what the board's firmware loads under boot/, and a
    // manifest over both (tools/mkpackage, sdk.install). It is for the
    // machines whose disk is in RAM; an ESP32 board's disk is the flash
    // its kernel is written with, which `flash-disk` writes.
    const boot_files = bootFiles(b);
    const mkpackage = b.addExecutable(.{
        .name = "mkpackage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkpackage/mkpackage.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    mkpackage.root_module.addImport("sdk", sdk);
    // tools/serve hands that package out over HTTP, read-only, so a
    // machine installs itself or brings itself up to date with nothing but
    // a network - and in QEMU's user network the host is 10.0.2.2, so
    // either chip proves it without hardware.
    const serve = b.addExecutable(.{
        .name = "serve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/serve/serve.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    serve.root_module.addImport("sdk", sdk);
    const serve_port = b.option(u16, "serve-port", "The port `serve` hands a release package out on (default: 8080)") orelse 8080;
    // The x86-64 machine's loader: a PE32+ of its own that the firmware
    // starts, and which then reads the kernel (src/boot/uefi/stub.zig).
    // It is made here because everything that writes a boot partition
    // has to carry it - the package below, the image further down and
    // the stick - and it is one of that board's build products
    // (`zig-out/bin/BOOTX64.EFI`), because it is a file that has to be
    // on the partition the firmware reads, as much as the kernel is.
    const uefi_stub = addUefiStub(b, optimize);
    const package_step = b.step("package", "Gather a release package for -Dboard= into release/package-<board>/");
    const serve_step = b.step("serve", "Gather the release package and hand it out over HTTP (quit with Ctrl-C)");
    switch (chipOf(board)) {
        .esp32s3, .esp32p4 => {
            const no_package = b.addFail(
                "package: this board's disk is the flash its kernel is written with - `flash-disk` writes it, and `esp-package` packs it to be written elsewhere. A package is for a machine whose disk is in RAM: -Dboard=visionfive2, rpi_cm5, qemu_virt, qemu_virt_a64 or qemu_q35.",
            );
            package_step.dependOn(&no_package.step);
            serve_step.dependOn(&no_package.step);
        },
        .rv64sbi, .a64psci, .x64uefi => {
            const gathered = addPackage(b, package_step, mkpackage, board, image, .{
                .tree = switch (chipOf(board)) {
                    .rv64sbi => rv64_tree,
                    .a64psci => a64_tree,
                    else => x64_tree,
                },
                .ram_disk = switch (chipOf(board)) {
                    .rv64sbi => rv64_disk_bin,
                    .a64psci => a64_disk_bin,
                    else => x64_disk_bin,
                },
                .boot_files = boot_files,
                .boot_loader = if (chipOf(board) == .x64uefi) uefi_stub.getEmittedBin() else null,
            });
            // `serve` hands out the package it has just gathered, so one
            // command is the whole of the host's side.
            const run_serve = b.addRunArtifact(serve);
            run_serve.addArg(b.fmt("--port={d}", .{serve_port}));
            run_serve.addDirectoryArg(gathered);
            run_serve.stdio = .inherit;
            run_serve.has_side_effects = true;
            serve_step.dependOn(&run_serve.step);
            serve_step.dependOn(package_step);
        },
    }

    // The loader beside the kernel in this board's build products.
    if (board == .qemu_q35) {
        b.getInstallStep().dependOn(&b.addInstallBinFile(uefi_stub.getEmittedBin(), "BOOTX64.EFI").step);
    }

    // SYS:Storage/Boot on the image of the machine this build is for: the
    // files its firmware loads, so it installs itself from what it is
    // running - no network, no second machine - and SYS:Storage/manifest
    // over them, a package's boot half written by the same tool, which
    // says which chip and board they are for. The image of the other
    // 64-bit chip keeps the drawers and nothing in them: a kernel is the
    // board's, and a build is for one board.
    switch (chipOf(board)) {
        .esp32s3, .esp32p4 => {},
        .rv64sbi, .a64psci, .x64uefi => {
            const run = switch (chipOf(board)) {
                .rv64sbi => make_rv64_disk,
                .a64psci => make_a64_disk,
                else => make_x64_disk,
            };
            const list = b.addRunArtifact(mkpackage);
            const boot_list = list.addPrefixedOutputDirectoryArg("--into=", b.fmt("boot-{s}", .{@tagName(board)}));
            list.addArg(b.fmt("--chip={s}", .{@tagName(chipOf(board))}));
            list.addArg(b.fmt("--board={s}", .{@tagName(board)}));
            // Every file goes into both: the drawer the machine reads it
            // from, and the list that says what it is.
            list.addPrefixedFileArg("boot/kernel.bin=", image);
            run.addPrefixedFileArg("Storage/Boot/kernel.bin=", image);
            // The loader beside it on a machine whose firmware starts one:
            // without it in both, a machine that installs itself - or one
            // installed from a package - would write a boot partition its
            // firmware finds nothing in.
            if (chipOf(board) == .x64uefi) {
                const loader = uefi_stub.getEmittedBin();
                list.addPrefixedFileArg("boot/" ++ uefi_loader_path ++ "=", loader);
                run.addPrefixedFileArg("Storage/Boot/" ++ uefi_loader_path ++ "=", loader);
            }
            if (board == .rpi_cm5) {
                const config = b.path("src/boards/rpi_cm5/config.txt");
                list.addPrefixedFileArg("boot/config.txt=", config);
                run.addPrefixedFileArg("Storage/Boot/config.txt=", config);
            }
            for (boot_files) |file| {
                const host: std.Build.LazyPath = .{ .cwd_relative = file.host };
                list.addPrefixedFileArg(b.fmt("boot/{s}=", .{file.name}), host);
                run.addPrefixedFileArg(b.fmt("Storage/Boot/{s}=", .{file.name}), host);
            }
            run.addPrefixedFileArg("Storage/manifest=", boot_list.path(b, "manifest"));
        },
    }
    return .{
        .boot_files = boot_files,
        .mkpackage = mkpackage,
        .serve = serve,
        .uefi_stub = uefi_stub,
    };
}

/// What `addReleaseSteps` takes from the build so far.
pub const ReleaseStepsWith = struct {
    a64_disk_bin: std.Build.LazyPath,
    a64_system_disk: std.Build.LazyPath,
    a64_target: std.Build.ResolvedTarget,
    a64_tree: std.Build.LazyPath,
    blank_work_disk: std.Build.LazyPath,
    board: Board,
    boot_files: []const BootFile,
    built: Image,
    cores: u32,
    disk_offset: u32,
    disk_size: u32,
    disk_tree_option: ?bool,
    esptool: []const u8,
    flash_disks: [flash_boards.len]std.Build.LazyPath,
    logdebug: bool,
    memdebug: bool,
    mkpackage: *std.Build.Step.Compile,
    optimize: std.builtin.OptimizeMode,
    p4_target: std.Build.ResolvedTarget,
    ramimage: *std.Build.Step.Compile,
    ressize: *std.Build.Step.Compile,
    rv64_disk_bin: std.Build.LazyPath,
    rv64_system_disk: std.Build.LazyPath,
    rv64_target: std.Build.ResolvedTarget,
    rv64_tree: std.Build.LazyPath,
    sdk: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    tree: Tree,
    uefi_stub: *std.Build.Step.Compile,
    x64_disk_bin: std.Build.LazyPath,
    x64_target: std.Build.ResolvedTarget,
    x64_tree: std.Build.LazyPath,
};

/// The `archive`, `release` and `sums` steps.
pub fn addReleaseSteps(b: *std.Build, with: ReleaseStepsWith) void {
    const a64_disk_bin = with.a64_disk_bin;
    const a64_system_disk = with.a64_system_disk;
    const a64_target = with.a64_target;
    const a64_tree = with.a64_tree;
    const blank_work_disk = with.blank_work_disk;
    const board = with.board;
    const boot_files = with.boot_files;
    const built = with.built;
    const cores = with.cores;
    const disk_offset = with.disk_offset;
    const disk_size = with.disk_size;
    const disk_tree_option = with.disk_tree_option;
    const esptool = with.esptool;
    const flash_disks = with.flash_disks;
    const logdebug = with.logdebug;
    const memdebug = with.memdebug;
    const mkpackage = with.mkpackage;
    const optimize = with.optimize;
    const p4_target = with.p4_target;
    const ramimage = with.ramimage;
    const ressize = with.ressize;
    const rv64_disk_bin = with.rv64_disk_bin;
    const rv64_system_disk = with.rv64_system_disk;
    const rv64_target = with.rv64_target;
    const rv64_tree = with.rv64_tree;
    const sdk = with.sdk;
    const target = with.target;
    const tree = with.tree;
    const uefi_stub = with.uefi_stub;
    const x64_disk_bin = with.x64_disk_bin;
    const x64_target = with.x64_target;
    const x64_tree = with.x64_tree;

    // `archive` - what a board is handed over in, for the board this
    // build is for: QEMU's machines get the kernel, the two disks and a
    // `run.sh` that starts them (`tools/qemupackage`); an ESP32 board the
    // kernel, the flash disk and a `flash.sh` that writes them
    // (`tools/espackage`); a 64-bit board the files its firmware loads
    // and a `write.sh` that copies them (`tools/bootpackage`).
    const archive_parts: ArchiveParts = .{
        .disks = .{ .flash = flash_disks, .ram = .{ rv64_disk_bin, a64_disk_bin, x64_disk_bin } },
        .rv64_system = rv64_system_disk,
        .a64_system = a64_system_disk,
        .work_disk = blank_work_disk,
        .uefi_stub = uefi_stub.getEmittedBin(),
        .boot_files = boot_files,
        .disk_offset = disk_offset,
        .disk_size = disk_size,
        .cores = cores,
    };
    const archive_step = b.step("archive", "Pack what -Dboard= is handed over in: release/poweros-<board>.tar.gz");
    refusePrivateTree(b, archive_step, disk_tree_option, tree, "archive");
    addBoardArchive(b, archive_step, board, built, archive_parts);

    // `release` - every board's artifact in one build, into release/: the
    // package of each machine whose disk is in RAM, the archive of each
    // QEMU machine, and the archive of each board. The two emulators are
    // left out (`release_boards`).
    const release_step = b.step("release", "Build every board's release artifact into release/");
    refusePrivateTree(b, release_step, disk_tree_option, tree, "release");
    const board_build: BoardBuild = .{
        .targets = .{ target, p4_target, rv64_target, a64_target, x64_target },
        .disks = .{ .flash = flash_disks, .ram = .{ rv64_disk_bin, a64_disk_bin, x64_disk_bin } },
        .optimize = optimize,
        .sdk = sdk,
        .esptool = esptool,
        .ressize = ressize,
        .ramimage = ramimage,
        .disk_offset = disk_offset,
        .cores = cores,
        .memdebug = memdebug,
        .logdebug = logdebug,
    };
    for (release_boards) |one| {
        // The board this build is for is already built; the rest are
        // built for the release alone.
        const one_image = if (one == board) built else addBoardImage(b, board_build, one);
        addBoardArchive(b, release_step, one, one_image, archive_parts);
        // And a release package for every machine that installs itself
        // onto a medium: an ESP32 board's disk is the flash its kernel is
        // written with, so it has none.
        switch (chipOf(one)) {
            .esp32s3, .esp32p4 => {},
            .rv64sbi, .a64psci, .x64uefi => {
                _ = addPackage(b, release_step, mkpackage, one, one_image.image, .{
                    .tree = switch (chipOf(one)) {
                        .rv64sbi => rv64_tree,
                        .a64psci => a64_tree,
                        else => x64_tree,
                    },
                    .ram_disk = switch (chipOf(one)) {
                        .rv64sbi => rv64_disk_bin,
                        .a64psci => a64_disk_bin,
                        else => x64_disk_bin,
                    },
                    .boot_files = boot_files,
                    .boot_loader = if (chipOf(one) == .x64uefi) uefi_stub.getEmittedBin() else null,
                });
            },
        }
    }

    // `sums` - the SHA-256 of every archive in release/, written as
    // `sha256sum -c` reads it (tools/sums.zig), so that somebody who
    // downloaded one can hold it against what was built.
    //
    // It is a step of its own and not part of `release` on purpose: it
    // sums what is in the directory, and a whole set of archives is not
    // one build's. The files a firmware loads are put in a disk image's
    // `SYS:Storage/Boot` only for the machine the build is for - a kernel
    // is the board's - so each 64-bit board's archive and package come
    // from a build of their own, kept in that directory as they are made.
    // `sums` is what is run over the finished directory, and it never
    // builds or replaces anything in it.
    const sums = b.addExecutable(.{
        .name = "sums",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sums.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_sums = b.addRunArtifact(sums);
    run_sums.addArg(b.pathFromRoot("release"));
    run_sums.has_side_effects = true;
    const sums_step = b.step("sums", "Write release/SHA256SUMS over the archives that are there");
    sums_step.dependOn(&run_sums.step);
}
