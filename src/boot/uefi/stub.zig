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
//! **What it says goes where the machine's own output goes.** While the
//! firmware is there that is the firmware's console, which is the screen
//! on a machine that has one and the serial line on a machine set up that
//! way - and on a machine with no serial port at all, those lines are the
//! only sign that the firmware started this loader rather than something
//! else, or nothing. What the console was shown stays on the screen while
//! the kernel comes up, until something draws over it.
//!
//! **After `exitBootServices` it is the serial port, by hand.** The
//! firmware's console goes with the firmware, while the port is there
//! before, during and after - and it is the port the kernel's first lines
//! come out of, so a machine that stops between them is readable. It is
//! written with `out`/`in` on the 16550 the kernel will drive as its
//! console later, and it is where the stub's lines go when the firmware
//! offers no console of its own.
//!
//! Both at once would say everything twice on a machine whose firmware
//! console is that same serial line, which is what a firmware does when
//! it has no screen to write to.
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

/// The firmware's console while the firmware is there: where a machine
/// with no serial port shows the stub's lines. Taken when the stub
/// starts and forgotten the moment the firmware is left, since calling it
/// after that would be calling code that is gone.
var console: ?*uefi.protocol.SimpleTextOutput = null;

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

/// `text` on the firmware's console, in the sixteen-bit characters it
/// takes. A chunk at a time out of one buffer: the stub allocates nothing,
/// and the firmware wants both characters at the end of a line.
fn putConsole(one: *uefi.protocol.SimpleTextOutput, text: []const u8) void {
    var wide: [80]u16 = undefined;
    var filled: usize = 0;
    for (text) |byte| {
        if (filled + 3 > wide.len) {
            wide[filled] = 0;
            _ = one.outputString(wide[0..filled :0].ptr) catch {};
            filled = 0;
        }
        if (byte == '\n') {
            wide[filled] = '\r';
            filled += 1;
        }
        wide[filled] = byte;
        filled += 1;
    }
    if (filled != 0) {
        wide[filled] = 0;
        _ = one.outputString(wide[0..filled :0].ptr) catch {};
    }
}

fn put(text: []const u8) void {
    if (console) |one| {
        putConsole(one, text);
        return;
    }
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

/// The first mebibyte, which is the only place a core can be started
/// from: the message that starts one names a page by a number of one
/// byte.
const low_memory: u64 = 0x10_0000;

/// A page of free memory down there kept for starting the other cores,
/// out of a range the firmware called free. The first page of the address
/// space is passed over: the kernel leaves it unmapped on purpose, so that
/// a null pointer faults where it is used. The first one found is kept -
/// one page is all it takes, and which of them it is makes no difference.
fn takeLowPage(start: u64, end: u64) void {
    if (machine.low_page != 0) return;
    const first = if (start < 0x1000) 0x1000 else (start + 0xFFF) & ~@as(u64, 0xFFF);
    const last = @min(end, low_memory);
    if (first + 0x1000 > last) return;
    machine.low_page = first;
}

/// The key the firmware gave with the map last read: `exitBootServices`
/// takes it and refuses a key the map has moved past, which is how the
/// firmware makes sure nobody leaves it holding a map that has changed.
var map_key: uefi.tables.MemoryMapKey = undefined;

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
    map_key = map.info.key;

    var walk = map.iterator();
    while (walk.next()) |entry| {
        const start = entry.physical_start;
        const end = start + entry.number_of_pages * 4096;
        if (isFree(entry.type)) {
            // Nothing below the first mebibyte goes on the list: the
            // machine's oldest corners are in there, and a page of it is
            // worth less than the trouble of telling which. One page is
            // worth it - the one another core starts on - and that is
            // taken here, where the firmware's map says which of it is
            // free, and given to nobody else.
            if (start < low_memory) takeLowPage(start, end);
            const from = if (start < low_memory) low_memory else start;
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

/// The identifier of the partition the stub was started from, as its
/// disk's table has it: the firmware names the device it read an image
/// from as a path of nodes, and the node for a partition of a disk
/// carries the partition's signature - with a table of the newer kind,
/// the sixteen bytes that name it there. Left as zeroes where the path
/// has no such node, as on a medium without that table.
///
/// The path is read as bytes: a node is its kind, its sub-kind and its
/// length, and the one looked for is a medium's (4) hard drive (1), whose
/// signature is at 24 with what kind of signature it is at 41 - 2 for a
/// table's identifier. A node of kind 0x7F ends the path.
fn takeBootPartition(boot: *uefi.tables.BootServices) void {
    const image = (boot.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch return) orelse return;
    const device = image.device_handle orelse return;
    const path = (boot.handleProtocol(uefi.protocol.DevicePath, device) catch return) orelse return;
    var node: [*]const u8 = @ptrCast(path);
    var nodes: u32 = 0;
    while (nodes < 64) : (nodes += 1) {
        const kind = node[0];
        const sub_kind = node[1];
        const length = @as(usize, node[2]) | @as(usize, node[3]) << 8;
        if (kind == 0x7F or length < 4) return;
        if (kind == 4 and sub_kind == 1 and length >= 42 and node[41] == 2) {
            @memcpy(&machine.boot_partition, node[24..40]);
            return;
        }
        node += length;
    }
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

/// Where the kernel is to be called. Only the image says, and it says in
/// the header `readKernel` reads.
var entry_at: u64 = 0;

/// `kernel.bin` read into the pages it names for itself, and the range it
/// is in.
///
/// The image begins with a `KernelHeader` (`handover.zig`): where it has
/// to be, how much memory it takes there - its zeroed data and its boot
/// stack included - and how far into it the entry is. It cannot be moved,
/// so those pages are asked for by address rather than wherever the
/// firmware pleases, and a firmware that will not give them says so here
/// instead of leaving a kernel in the wrong place. They are asked for as
/// loader code, which is the kind of memory a firmware does not keep code
/// from running in.
///
/// The page below the image goes with them: it is where the kernel keeps
/// the one pointer a program finds the system by, and the kernel keeps
/// that same page out of its heap (`src/arch/x64uefi/ram.zig`).
fn readKernel(boot: *uefi.tables.BootServices, volume: *uefi.protocol.File) !handover.Range {
    var file = try volume.open(kernel_name, .read, .{});
    defer file.close() catch {};

    const info = try file.getInfo(.file, &info_buffer);
    const size = info.file_size;

    var head: handover.KernelHeader = .{};
    const head_bytes = @as([*]u8, @ptrCast(&head))[0..@sizeOf(handover.KernelHeader)];
    if (size < head_bytes.len) return error.Empty;
    if (try file.read(head_bytes) != head_bytes.len) return error.Short;
    if (head.magic != handover.KERNEL_MAGIC) return error.NotAKernel;
    if (head.load < page or head.load % page != 0) return error.LoadAddress;
    if (head.memory < size or head.entry >= size) return error.ImageSize;

    const from = head.load - page;
    const pages = (head.memory + page + (page - 1)) / page;
    _ = try boot.allocatePages(.{ .address = @ptrFromInt(from) }, .loader_code, @intCast(pages));

    try file.setPosition(0);
    const bytes: []u8 = @as([*]u8, @ptrFromInt(head.load))[0..@intCast(size)];
    var done: usize = 0;
    while (done < bytes.len) {
        const read = try file.read(bytes[done..]);
        if (read == 0) return error.Short;
        done += read;
    }
    entry_at = head.load + head.entry;
    return .{ .start = from, .end = head.load + head.memory };
}

/// A page of memory, which is what the firmware hands out in.
const page = 4096;

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
    if (machine.low_page != 0) {
        put("stub: a page for the other cores at ");
        putHex(machine.low_page);
        put("\n");
    } else line("no free page below the first mebibyte: the machine runs on one core");
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

// --- leaving the firmware ----------------------------------------------------------

/// The firmware let go of the machine and the kernel called, which does
/// not return.
///
/// `exitBootServices` refuses a memory-map key the map has moved past,
/// which is the firmware saying the map the stub gathered is out of date.
/// Nothing between reading it and here asks the firmware for anything, so
/// that should not happen; it is asked again once rather than giving up,
/// since everything the firmware allocated while it was up becomes the
/// kernel's the moment it leaves anyway.
///
/// After it the firmware's console and its handlers are gone, so the
/// interrupts stay masked until the kernel's own are up, and anything the
/// stub still has to say goes out of the serial port by hand.
fn handOver(boot: *uefi.tables.BootServices) uefi.Status {
    boot.exitBootServices(uefi.handle, map_key) catch {
        const info = boot.getMemoryMapInfo() catch {
            line("the firmware will not say where its memory map is");
            return .load_error;
        };
        map_key = info.key;
        boot.exitBootServices(uefi.handle, map_key) catch {
            line("the firmware will not let go of the machine");
            return .load_error;
        };
    };
    // The firmware is gone, and its console with it: what is left to say
    // goes out of the port, which is there whatever the firmware used.
    console = null;
    asm volatile ("cli");
    // The kernel is built for the ordinary 64-bit calling convention, not
    // the firmware's: the handover's address goes in RDI.
    const Entry = *const fn (machine: u64) callconv(.{ .x86_64_sysv = .{} }) noreturn;
    const enter: Entry = @ptrFromInt(entry_at);
    enter(@intFromPtr(&machine));
}

// --- the firmware's entry ----------------------------------------------------------

pub fn main() uefi.Status {
    const system_table = uefi.system_table;
    // The console first of all, so that everything below is said on a
    // machine whose only output is its screen.
    console = system_table.con_out;
    const boot = system_table.boot_services orelse {
        line("the firmware offers no boot services");
        return .load_error;
    };
    // A line before anything is asked of the firmware: it is what says
    // that the loader the firmware started is this one.
    line("started by the firmware");

    machine.system_table = @intFromPtr(system_table);
    machine.console_port = COM1;
    machine.console_rate = 115200;

    takeTables(system_table);
    takeFramebuffer(boot);

    if (ownVolume(boot)) |volume| {
        if (readKernel(boot, volume)) |where| {
            machine.kernel = where;
        } else |err| {
            put("stub: kernel.bin cannot be read where it has to be: ");
            put(@errorName(err));
            put("\n");
        }
        machine.disk = readFile(boot, volume, disk_name) catch .{ .start = 0, .end = 0 };
        // With no disk image beside it, the system is on the disk the
        // stub came from: the kernel is told which partition that was.
        if (machine.disk.end == 0) takeBootPartition(boot);
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
    if (machine.kernel.end == 0) {
        line("no kernel to start: the machine stops here");
        return .load_error;
    }
    put("stub: leaving the firmware, entering the kernel at ");
    putHex(entry_at);
    put("\n");
    return handOver(boot);
}
