// SPDX-License-Identifier: MPL-2.0
//! The stub the firmware starts: `BOOTX64.EFI` on the boot partition.
//!
//! It is the only code in the system that talks to the firmware. What it
//! does, in order: asks for the memory map; asks the graphics protocol for
//! the framebuffer that is already lit; finds the root of the firmware's
//! tables among its configuration table; reads the kernel and the disk
//! image off the partition it was itself started from; fills in a
//! `Handover` (`handover.zig`); leaves the firmware; and calls the kernel
//! with that structure's address, as a device tree's address is passed on
//! the other two 64-bit chips.
//!
//! **Its own output goes to the serial line, by hand.** The firmware's
//! console is the firmware's, and it is gone after `exitBootServices`,
//! while the port is there before, during and after - so the stub's lines
//! and the kernel's first lines come out of the same place, which is what
//! makes a machine that stops between them readable. The port is written
//! with `out`/`in` on the 16550 the kernel will drive as its console
//! later.
//!
//! It uses the firmware's declarations from `std.os.uefi`, which is the
//! only place they are, and nothing else of std at run time: the numbers
//! in its lines are written by `putDec` and `putHex` here rather than by a
//! formatter.

const std = @import("std");
const uefi = std.os.uefi;
const handover = @import("handover.zig");
const Handover = handover.Handover;

/// The console, and where the kernel's will be: the first serial port of a
/// PC, which the firmware has already set up and left running.
const COM1: u16 = 0x3F8;

/// The 16550's registers, by their distance from the port. The kernel's
/// own names for these are in `sdk/hardware/x64uefi/uart.zig`; the stub
/// keeps its own two lines' worth so that it depends on nothing but the
/// firmware.
const THR: u16 = 0; // transmit holding
const LSR: u16 = 5; // line status
const LSR_THRE: u8 = 0x20; // the holding register is empty

/// The structure handed over, in the stub's own data: it is in the memory
/// the firmware gave the stub's image, which the kernel is told it owns -
/// so the kernel copies what it wants out of it before it hands that
/// memory out. A page of its own would do as well and cost a page.
var machine: Handover = .{};

// --- the serial line ---------------------------------------------------------------

fn out8(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

fn in8(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

/// One byte out of the port, once it can take it. Polled: there is nothing
/// else running.
fn putByte(byte: u8) void {
    while (in8(COM1 + LSR) & LSR_THRE == 0) {}
    out8(COM1 + THR, byte);
}

fn put(text: []const u8) void {
    for (text) |byte| {
        if (byte == '\n') putByte('\r');
        putByte(byte);
    }
}

fn putDec(value: u64) void {
    var digits: [20]u8 = undefined;
    var index: usize = digits.len;
    var rest = value;
    while (true) {
        index -= 1;
        digits[index] = '0' + @as(u8, @intCast(rest % 10));
        rest /= 10;
        if (rest == 0) break;
    }
    put(digits[index..]);
}

fn putHex(value: u64) void {
    put("0x");
    var shift: u6 = 60;
    var leading = true;
    while (true) {
        const nibble: u8 = @intCast((value >> shift) & 0xF);
        if (nibble != 0 or !leading or shift == 0) {
            leading = false;
            put(&[_]u8{if (nibble < 10) '0' + nibble else 'a' + nibble - 10});
        }
        if (shift == 0) break;
        shift -= 4;
    }
}

/// A line of the stub's own: what it found, or what it could not.
fn line(text: []const u8) void {
    put("stub: ");
    put(text);
    put("\n");
}

// --- the memory map ----------------------------------------------------------------

/// Whether memory of this kind is the kernel's to hand out once the
/// firmware has gone. The firmware's own boot code and data are: it is not
/// running any more. Its runtime services, its tables and everything it
/// did not describe are not.
fn isFree(kind: uefi.tables.MemoryType) bool {
    return switch (kind) {
        .conventional_memory, .boot_services_code, .boot_services_data, .loader_code, .loader_data => true,
        else => false,
    };
}

/// Whether memory of this kind must be left alone rather than merely not
/// handed out: the firmware's runtime half, which is still there and still
/// called.
fn isReserved(kind: uefi.tables.MemoryType) bool {
    return switch (kind) {
        .runtime_services_code, .runtime_services_data, .acpi_reclaim_memory, .acpi_memory_nvs, .pal_code => true,
        else => false,
    };
}

/// A range added to one of the two lists, joined to the one before it where
/// they touch - the firmware's map is in address order and cut finely, so
/// joining keeps a machine with many pieces inside the lists' bounds.
fn add(ranges: []handover.Range, count: *u32, dropped: *u32, start: u64, end: u64) void {
    if (end <= start) return;
    if (count.* > 0) {
        const last = &ranges[count.* - 1];
        if (last.end == start) {
            last.end = end;
            return;
        }
    }
    if (count.* >= ranges.len) {
        dropped.* += 1;
        return;
    }
    ranges[count.*] = .{ .start = start, .end = end };
    count.* += 1;
}

/// The firmware's memory map into the handover's two lists. The map is read
/// into memory the firmware gives, which the kernel is free to use
/// afterwards.
fn takeMemory(boot: *uefi.tables.BootServices) !void {
    // How many descriptors it takes, then room for a few more than that:
    // asking for the pool changes the map. `info.len` is a count of
    // descriptors, not a size, and the room asked for is a whole number of
    // them - the call divides what it is given.
    const info = try boot.getMemoryMapInfo();
    const room = (info.len + 8) * info.descriptor_size;
    const buffer = try boot.allocatePool(.loader_data, room);
    const map = try boot.getMemoryMap(@alignCast(buffer));

    var walk = map.iterator();
    while (walk.next()) |entry| {
        const start = entry.physical_start;
        const end = start + entry.number_of_pages * 4096;
        if (isFree(entry.type)) {
            // Nothing below the first mebibyte: the machine's oldest
            // corners are in there, and a page of it is worth less than
            // the trouble of telling which.
            const from = if (start < 0x10_0000) 0x10_0000 else start;
            add(&machine.memory, &machine.memory_count, &machine.memory_dropped, from, end);
        } else if (isReserved(entry.type)) {
            add(&machine.reserved, &machine.reserved_count, &machine.reserved_dropped, start, end);
        }
    }
}

// --- the firmware's other answers --------------------------------------------------

/// The framebuffer the firmware has already lit, if it lit one.
fn takeFramebuffer(boot: *uefi.tables.BootServices) void {
    const protocol = boot.locateProtocol(uefi.protocol.GraphicsOutput, null) catch return orelse return;
    const mode = protocol.mode;
    const info = mode.info;
    machine.framebuffer = .{
        .base = mode.frame_buffer_base,
        .size = mode.frame_buffer_size,
        .width = info.horizontal_resolution,
        .height = info.vertical_resolution,
        .stride = info.pixels_per_scan_line,
        .format = switch (info.pixel_format) {
            .blue_green_red_reserved_8_bit_per_color => .bgrx32,
            .red_green_blue_reserved_8_bit_per_color => .rgbx32,
            else => .unknown,
        },
    };
}

/// The root of the firmware's tables, from its configuration table: the
/// 2.0 pointer where there is one, else the 1.0 one.
fn takeTables(system_table: *uefi.tables.SystemTable) void {
    const entries = system_table.configuration_table[0..system_table.number_of_table_entries];
    var older: u64 = 0;
    for (entries) |entry| {
        if (entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid)) {
            machine.tables = @intFromPtr(entry.vendor_table);
            return;
        }
        if (entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_10_table_guid)) {
            older = @intFromPtr(entry.vendor_table);
        }
    }
    machine.tables = older;
}

// --- the files on the boot partition -----------------------------------------------

/// The volume the stub was started from, opened. Everything the machine
/// needs is beside the stub, so nothing has to be searched for.
fn ownVolume(boot: *uefi.tables.BootServices) !*uefi.protocol.File {
    const image = try boot.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) orelse return error.NoLoadedImage;
    const device = image.device_handle orelse return error.NoDevice;
    const file_system = try boot.handleProtocol(uefi.protocol.SimpleFileSystem, device) orelse return error.NoFileSystem;
    return try file_system.openVolume();
}

/// A file read into pages of its own, and the range it is in. The pages are
/// asked for as loader data, which the kernel is told it owns - the kernel
/// keeps what it wants where it is and hands the rest out.
fn readFile(boot: *uefi.tables.BootServices, volume: *uefi.protocol.File, name: [*:0]const u16) !handover.Range {
    var file = try volume.open(name, .read, .{});
    defer file.close() catch {};

    const info = try file.getInfo(.file, &info_buffer);
    const size = info.file_size;
    if (size == 0) return error.Empty;

    const pages = (size + 4095) / 4096;
    const memory = try boot.allocatePages(.any, .loader_data, @intCast(pages));
    const bytes: []u8 = @as([*]u8, @ptrCast(memory.ptr))[0..@intCast(size)];

    var done: usize = 0;
    while (done < bytes.len) {
        const read = try file.read(bytes[done..]);
        if (read == 0) return error.Short;
        done += read;
    }
    const start = @intFromPtr(bytes.ptr);
    return .{ .start = start, .end = start + size };
}

/// Room for a file's information, which the protocol writes into the
/// caller's memory. One file is read at a time.
var info_buffer: [512]u8 align(8) = undefined;

/// `kernel.bin`, as UTF-16, which is how the firmware names files.
const kernel_name = std.unicode.utf8ToUtf16LeStringLiteral("kernel.bin");
/// `disk-x64.bin` beside it: the disk image the machine runs on until it
/// has a disk of its own.
const disk_name = std.unicode.utf8ToUtf16LeStringLiteral("disk-x64.bin");

// --- what it says for itself -------------------------------------------------------

fn report() void {
    put("\n");
    line("PowerOS x86-64 stub");
    put("stub: tables ");
    putHex(machine.tables);
    put(", system table ");
    putHex(machine.system_table);
    put("\n");
    if (machine.framebuffer.base != 0) {
        put("stub: screen ");
        putDec(machine.framebuffer.width);
        put("x");
        putDec(machine.framebuffer.height);
        put(", stride ");
        putDec(machine.framebuffer.stride);
        put(", at ");
        putHex(machine.framebuffer.base);
        put("\n");
    } else line("no screen the firmware lit");
    var free: u64 = 0;
    for (machine.memory[0..machine.memory_count]) |range| free += range.end - range.start;
    put("stub: memory ");
    putDec(machine.memory_count);
    put(" ranges, ");
    putDec(free / (1024 * 1024));
    put(" MiB; reserved ");
    putDec(machine.reserved_count);
    put(" ranges\n");
    if (machine.memory_dropped != 0 or machine.reserved_dropped != 0) {
        put("stub: ");
        putDec(machine.memory_dropped + machine.reserved_dropped);
        put(" ranges dropped: the handover's lists are too small for this machine\n");
    }
    for (machine.memory[0..machine.memory_count]) |range| {
        put("stub:   memory ");
        putHex(range.start);
        put("-");
        putHex(range.end);
        put("\n");
    }
    if (machine.kernel.end != 0) {
        put("stub: kernel at ");
        putHex(machine.kernel.start);
        put(", ");
        putDec(machine.kernel.end - machine.kernel.start);
        put(" bytes\n");
    } else line("no kernel.bin on the boot partition");
    if (machine.disk.end != 0) {
        put("stub: disk image at ");
        putHex(machine.disk.start);
        put(", ");
        putDec((machine.disk.end - machine.disk.start) / 1024);
        put(" KiB\n");
    } else line("no disk image: the machine would run diskless");
}

// --- the firmware's entry ----------------------------------------------------------

pub fn main() uefi.Status {
    const system_table = uefi.system_table;
    const boot = system_table.boot_services orelse {
        line("the firmware offers no boot services");
        return .load_error;
    };

    machine.system_table = @intFromPtr(system_table);
    machine.console_port = COM1;
    machine.console_rate = 115200;

    takeTables(system_table);
    takeFramebuffer(boot);

    if (ownVolume(boot)) |volume| {
        machine.kernel = readFile(boot, volume, kernel_name) catch .{ .start = 0, .end = 0 };
        machine.disk = readFile(boot, volume, disk_name) catch .{ .start = 0, .end = 0 };
    } else |_| {
        line("the partition the stub was started from cannot be read");
    }

    // Last, because asking for anything else changes the map.
    takeMemory(boot) catch |err| {
        put("stub: the firmware's memory map cannot be read: ");
        put(@errorName(err));
        put("\n");
        return .load_error;
    };

    report();
    line("nothing to hand over to yet: the kernel comes next");
    return .success;
}
