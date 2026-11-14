// SPDX-License-Identifier: MPL-2.0
//! The boards and chips the build knows, and the numbers they share: which
//! chip a board is built on, which boards have their disk in their flash,
//! the sets a board's disk holds, the sizes of the flash, its sectors and
//! the disks in RAM.

const std = @import("std");
const poweros_sdk = @import("poweros_sdk");
const poweros_userland = @import("poweros_userland");

/// The flash chip every board has (16 MiB), and the flash disk on it:
/// flash.device's unit 0 starts at `-Ddisk-offset` and runs to the end of
/// the chip, with 4 KiB erase sectors and 256-byte pages
/// (src/rom/devs/flash/esp32s3/spiflash.zig). The build needs the numbers to make
/// a disk image and to put it in the right place, and hands the offset to
/// the kernel, whose boards give it to flash.device as SYSTAG_DiskOffset.
pub const flash_size = 16 * 1024 * 1024;
/// Where the disk starts unless `-Ddisk-offset` says otherwise, in KiB:
/// the kernel image starts at offset 0 and has this much room to grow in.
pub const default_disk_offset_kib = 2048;
/// An MMU page: the disk's start has to be one, since flash.device maps
/// the disk into the data window a page at a time.
pub const mmu_page = 64 * 1024;
pub const disk_sector = 4096;
pub const disk_page = 256;
/// The flash disk's table area before DH0 unless `-Drdb-size` says
/// otherwise, in KiB: the RigidDiskBlock, the PartitionBlocks, and room
/// for the file systems kept in the table (tools/mkfs's `rdb-sectors`).
pub const default_rdb_size_kib = 64;
/// The disks of QEMU's virt machines, NVMe SSDs with a GPT and posfs on
/// them: the system disk, DH0:, made afresh by every build and started
/// from as it is - what a run writes to it goes with the run - and the
/// work disk, DH1:, made blank once and kept from then on with what is
/// saved to it.
pub const virt_system_bytes = 256 * 1024 * 1024;
/// The RISC-V 64 and AArch64 machines' disk image, which their loader
/// puts in RAM beside the kernel: not flash, so larger than the ESP32s'
/// flash disk - room for what only those machines run, such as the video
/// codecs in software.
pub const ram_disk_size = 32 * 1024 * 1024;
pub const virt_work_bytes = 1024 * 1024 * 1024;
/// Where the work disks are kept, from the root of the tree: outside
/// zig-out/, which cleaning the build clears.
pub const virt_work_dir = "work";

/// The boards there is a description for (src/boards/). One kernel image
/// is built per board. `qemu` is Espressif QEMU's machine, with its
/// virtual display, keyboard and mouse: the `qemu*` steps always run that
/// one, whichever board `-Dboard` names. `qemu_virt` is upstream QEMU's
/// RISC-V 64 `virt` machine under OpenSBI, which the `virt` step runs;
/// `visionfive2` is StarFive's JH7110 board, booted from U-Boot.
/// `qemu_virt_a64` is upstream QEMU's AArch64 `virt` machine with
/// Cortex-A76 cores and a GICv2, which the `virt64` steps run;
/// `rpi_cm5` is the Raspberry Pi Compute Module 5, booted from its eMMC.
/// `qemu_q35` is upstream QEMU's x86-64 q35 machine started by UEFI
/// firmware, which the `q35` step runs.
pub const Board = enum { waveshare_7b, es3c35p, qemu, esp32p4_emu, olimex_p4pc, crowpanel_p4, qemu_virt, visionfive2, qemu_virt_a64, rpi_cm5, qemu_q35 };

/// The chip a board is built on, which picks the kernel's target, its
/// root, start code and linker script, and how its image is made.
pub const Chip = poweros_sdk.Chip;

/// The sets a disk holds (`src/disk/build.zig`).
pub const Sets = poweros_userland.Sets;

/// The boards whose disk is their flash. Each has a disk image of its
/// own, with the sets that board names: a flash has room for what the
/// board is meant to do.
pub const flash_boards = [_]Board{ .waveshare_7b, .es3c35p, .qemu, .olimex_p4pc, .crowpanel_p4, .esp32p4_emu };

/// The chips whose disk is in RAM, or on a medium as large as one likes:
/// one image each, for every board on that chip.
pub const ram_chips = [_]Chip{ .rv64sbi, .a64psci, .x64uefi };

/// The sets `board`'s disk holds, as its `disk.zig` names them.
pub fn boardSets(board: Board) Sets {
    const text: []const u8 = switch (board) {
        .waveshare_7b => @import("../src/boards/waveshare_7b/disk.zig").sets,
        .es3c35p => @import("../src/boards/es3c35p/disk.zig").sets,
        .qemu => @import("../src/boards/qemu/disk.zig").sets,
        .esp32p4_emu => @import("../src/boards/esp32p4_emu/disk.zig").sets,
        .olimex_p4pc => @import("../src/boards/olimex_p4pc/disk.zig").sets,
        .crowpanel_p4 => @import("../src/boards/crowpanel_p4/disk.zig").sets,
        .qemu_virt => @import("../src/boards/qemu_virt/disk.zig").sets,
        .visionfive2 => @import("../src/boards/visionfive2/disk.zig").sets,
        .qemu_virt_a64 => @import("../src/boards/qemu_virt_a64/disk.zig").sets,
        .rpi_cm5 => @import("../src/boards/rpi_cm5/disk.zig").sets,
        .qemu_q35 => @import("../src/boards/qemu_q35/disk.zig").sets,
    };
    return poweros_userland.parseSets(text) orelse std.debug.panic("src/boards/{s}/disk.zig names a set there is none of: {s}", .{ @tagName(board), text });
}

pub fn chipOf(board: Board) Chip {
    return switch (board) {
        .waveshare_7b, .es3c35p, .qemu => .esp32s3,
        .esp32p4_emu, .olimex_p4pc, .crowpanel_p4 => .esp32p4,
        .qemu_virt, .visionfive2 => .rv64sbi,
        .qemu_virt_a64, .rpi_cm5 => .a64psci,
        .qemu_q35 => .x64uefi,
    };
}

/// The size the desktop shows icons at on a board's screen - an eighth of
/// its height, at most 48 (the screens are in src/boards/<board>/
/// system.zig) - so the disk's pictures are drawn at it, not shrunk on
/// the board.
pub fn iconSize(board: Board) u32 {
    return switch (board) {
        // 1024x600
        .waveshare_7b, .qemu => 48,
        // 480x320
        .es3c35p => 40,
        // No screen yet.
        .esp32p4_emu, .olimex_p4pc, .crowpanel_p4, .qemu_virt, .visionfive2, .qemu_virt_a64, .rpi_cm5, .qemu_q35 => 48,
    };
}

/// The boards a release is made for: every board somebody can have. The
/// two emulators are not among them - Espressif's QEMU for the ESP32-S3
/// (`qemu`) and esp-emulator for the ESP32-P4 (`esp32p4_emu`) - since
/// neither is a machine anybody has by downloading an archive.
pub const release_boards = [_]Board{
    .waveshare_7b, .es3c35p,   .olimex_p4pc, .crowpanel_p4,
    .visionfive2,  .qemu_virt, .rpi_cm5,     .qemu_virt_a64,
    .qemu_q35,
};

/// What a board's console is, for the script to say once it has written
/// the flash (`src/boards/<board>/system.zig` has the lines themselves).
pub fn boardConsole(board: Board) []const u8 {
    return switch (board) {
        .waveshare_7b, .es3c35p, .qemu => "the chip's own USB port, the board's USB socket, at 115200 8N1",
        .olimex_p4pc, .esp32p4_emu => "the chip's USB Serial/JTAG port at 115200 8N1",
        .crowpanel_p4 => "UART0 through the board's CH340K at 115200 8N1",
        .visionfive2 => "the debug UART on pins 8 and 10 of the 40-pin header at 115200 8N1, through a 3.3 V serial adapter",
        .rpi_cm5 => "the RP1's UART0 on pins 8 and 10 of the 40-pin header at 115200 8N1",
        .qemu_virt, .qemu_virt_a64, .qemu_q35 => "the terminal QEMU is started in",
    };
}
