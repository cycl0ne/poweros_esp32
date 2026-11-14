// SPDX-License-Identifier: MPL-2.0
//! A board's kernel and the image of it the board is started from:
//! `addKernel` for every chip, and one image maker a chip - the ESP32-S3's
//! flash image, the ESP32-P4's two parts, the booti Image of the RISC-V 64
//! and AArch64 machines, the x86-64 machine's kernel and its UEFI stub.

const std = @import("std");
const build_boards = @import("boards.zig");
const build_disk = @import("disk.zig");

const Board = build_boards.Board;
const chipOf = build_boards.chipOf;
const flash_boards = build_boards.flash_boards;
const flashDisk = build_disk.flashDisk;

/// The kernel, its ESP image and the full 16 MB flash with the disk in it.
pub const Image = struct {
    kernel_elf: std.Build.LazyPath,
    image: std.Build.LazyPath,
    flash_image: std.Build.LazyPath,
    /// The ESP32-P4's second part, the code and constants run in place
    /// from flash; the S3's image is one piece.
    flash_part: ?std.Build.LazyPath = null,

    /// The kernel's pieces for `esptool write-flash`, each after the
    /// offset it goes to.
    pub fn addTo(image: Image, b: *std.Build, run: *std.Build.Step.Run) void {
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
pub fn addImage(b: *std.Build, esptool: []const u8, ressize: *std.Build.Step.Compile, kernel: *std.Build.Step.Compile, disk_bin: std.Build.LazyPath, disk_offset: u32) Image {
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
pub const p4_flash_part_offset = 0x40000;

/// The stub the x86-64 machine's firmware starts, as its own artifact: a
/// PE32+ image for `x86_64-uefi`, which is the firmware's own target and
/// nothing else in the tree is built for - it is the only code the firmware
/// itself runs. The kernel beside it is an ELF for the machine's own target
/// like every other board's.
pub fn addUefiStub(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const stub = b.createModule(.{
        .root_source_file = b.path("src/boot/uefi/stub.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .uefi, .abi = .msvc }),
        .optimize = optimize,
        .single_threaded = true,
        .unwind_tables = .none,
    });
    return b.addExecutable(.{ .name = "BOOTX64", .root_module = stub });
}

/// A RISC-V 64 kernel made into what is booted: the ELF, which QEMU loads
/// as it is, and a raw binary of it from its first address (0x80200000),
/// which U-Boot loads there. Nothing to flash.
pub fn addRv64Image(b: *std.Build, kernel: *std.Build.Step.Compile) Image {
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
pub fn addA64Image(b: *std.Build, kernel: *std.Build.Step.Compile) Image {
    const kernel_elf = kernel.getEmittedBin();
    const image = b.addObjCopy(kernel_elf, .{ .format = .bin }).getOutput();
    return .{ .kernel_elf = kernel_elf, .image = image, .flash_image = image };
}

/// An x86-64 kernel made into what is read off the boot partition: the
/// ELF, for a debugger, and a raw binary of it from its first address
/// (0x00200000), which starts with the header the stub reads to learn
/// where the image goes and how much room it needs there
/// (src/arch/x64uefi/start.S). Nothing to flash: the firmware reads it
/// from a file.
pub fn addX64Image(b: *std.Build, kernel: *std.Build.Step.Compile) Image {
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
pub fn addP4Image(b: *std.Build, esptool: []const u8, ramimage: *std.Build.Step.Compile, kernel: *std.Build.Step.Compile, disk_bin: std.Build.LazyPath, disk_offset: u32) Image {
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
pub fn addKernel(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sdk: *std.Build.Module, board: Board, disk_offset: u32, cores: u32, selftest: bool, memdebug: bool, logdebug: bool) *std.Build.Step.Compile {
    const chip = chipOf(board);
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path(switch (chip) {
            .esp32s3 => "src/main.zig",
            .esp32p4 => "src/main_esp32p4.zig",
            .rv64sbi => "src/main_rv64sbi.zig",
            .a64psci => "src/main_a64psci.zig",
            .x64uefi => "src/main_x64uefi.zig",
        }),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .unwind_tables = .none,
        // Every backtrace but the ESP32-S3's walks the frame-pointer chain.
        .omit_frame_pointer = if (chip == .esp32s3) null else false,
        // x86-64's ABI lets a leaf function keep 128 bytes below the stack
        // pointer, which is exactly where an interrupt pushes its frame:
        // see `x64_target_query` in the SDK's build.
        .red_zone = if (chip == .x64uefi) false else null,
        // RV64's kernel is at 0x80200000, which the default code model
        // (medlow, addresses within 2 GiB of 0) cannot reach. AArch64's
        // small model reaches 4 GiB around the code, PC-relatively.
        .code_model = switch (chip) {
            .rv64sbi => .medany,
            .a64psci, .x64uefi => .small,
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
    options.addOption(bool, "logdebug", logdebug);
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
        .x64uefi => kernel_mod.addAssemblyFile(b.path("src/arch/x64uefi/start.S")),
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
        .x64uefi => "src/arch/x64uefi/kernel.ld",
    }));
    kernel.entry = .{ .symbol_name = "_start" };
    // A section per function, so each function's literals (.literal.<fn>)
    // sit next to its code: l32r reaches only 256 KiB back, and the code in
    // flash is bigger than that (kernel.ld keeps the input order).
    kernel.link_function_sections = true;
    return kernel;
}

/// esptool: ESP-IDF's, the newest under ~/.espressif/tools/python/<version>/venv/bin,
/// which ESP-IDF keeps working with its own Python; else esptool from PATH.
pub fn findEsptool(b: *std.Build) []const u8 {
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

/// What `addFlashSteps` takes from the build so far.
pub const FlashStepsWith = struct {
    a64_disk_bin: std.Build.LazyPath,
    baud: []const u8,
    board: Board,
    built: Image,
    disk_offset: u32,
    disk_size: u32,
    esptool: []const u8,
    flash_disks: [flash_boards.len]std.Build.LazyPath,
    port: []const u8,
    rv64_disk_bin: std.Build.LazyPath,
    x64_disk_bin: std.Build.LazyPath,
};

/// The `flash`, `flash-disk` and `flash-all` steps.
pub fn addFlashSteps(b: *std.Build, with: FlashStepsWith) void {
    const a64_disk_bin = with.a64_disk_bin;
    const baud = with.baud;
    const board = with.board;
    const built = with.built;
    const disk_offset = with.disk_offset;
    const disk_size = with.disk_size;
    const esptool = with.esptool;
    const flash_disks = with.flash_disks;
    const port = with.port;
    const rv64_disk_bin = with.rv64_disk_bin;
    const x64_disk_bin = with.x64_disk_bin;

    // The board's chip and its disk: the S3's image at 0x0, the P4's two
    // parts at 0x2000 and p4_flash_part_offset; each chip's own programs
    // on its disk.
    const chip_name = @tagName(chipOf(board));
    const board_disk = switch (chipOf(board)) {
        .esp32s3, .esp32p4 => flashDisk(flash_disks, board).?,
        .rv64sbi => rv64_disk_bin,
        .a64psci => a64_disk_bin,
        .x64uefi => x64_disk_bin,
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
