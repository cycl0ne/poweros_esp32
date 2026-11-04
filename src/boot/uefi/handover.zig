// SPDX-License-Identifier: MPL-2.0
//! What the stub hands the kernel: the machine as the firmware described
//! it, in one structure at a known address.
//!
//! On the machines whose firmware passes a device tree the kernel reads
//! that tree itself, once, before exec owns the memory it sits in
//! (`src/arch/a64psci/fdt.zig`). This machine's firmware has no such blob
//! to pass: the facts are spread over its memory map, its graphics
//! protocol and its tables, and they can only be had while the firmware is
//! still up. So the stub gathers them, writes them here, and leaves - and
//! the kernel reads this where the others read a tree. The fields are the
//! same facts in the same order, so `takeBoard()` keeps the shape it has
//! on both other 64-bit chips.
//!
//! Everything here is physical. The stub leaves the firmware's identity
//! map in place and the kernel runs on it until it makes its own
//! (`src/arch/x64uefi/mmu.zig`), so an address in this structure is good
//! in both.
//!
//! It is written where the kernel can find it with no agreement about
//! addresses: the stub passes its address in the first argument of the
//! call into the kernel, as a device tree's address is passed on the other
//! two chips.

/// The bytes `POSX64` and the version, as one word: what the kernel checks
/// before it believes anything else here. A stub and a kernel from
/// different builds is the one mistake this structure can catch for itself.
pub const MAGIC: u64 = @bitCast(@as([8]u8, "POSX64\x00\x02".*));

/// The same for the other direction: what the stub reads out of the kernel
/// image before it asks the firmware for anything.
pub const KERNEL_MAGIC: u64 = @bitCast(@as([8]u8, "POSKRN\x00\x01".*));

/// The first bytes of `kernel.bin`, which `src/arch/x64uefi/start.S` lays
/// down at the image's start.
///
/// **It is the kernel that says where it goes, not the stub.** The image is
/// not relocatable: its code holds addresses at fixed distances and it
/// reads its own pieces by the symbols its linker script set, so it has to
/// run where it was linked. Rather than write that address down a second
/// time in the stub, the kernel carries it here together with how much
/// memory it needs from there - its code and data, its .bss and its boot
/// stack - and the stub asks the firmware for exactly those pages, by
/// address, and reads the image straight into them. A firmware that will
/// not give them says so, and the stub says so on the console, which is a
/// great deal better than a kernel read into the wrong place.
pub const KernelHeader = extern struct {
    magic: u64 = KERNEL_MAGIC,
    /// Where the image must be.
    load: u64 = 0,
    /// How many bytes it takes from there.
    memory: u64 = 0,
    /// How far into the image its entry is.
    entry: u64 = 0,
};

/// The version of this structure. The kernel refuses what it does not
/// know: a stub is on the boot partition beside the kernel and the two are
/// written together, so a mismatch is a half-written update, and saying so
/// on the console beats running on fields that have moved.
pub const VERSION: u32 = 2;

/// A range of memory, start inclusive and end exclusive, as the other two
/// 64-bit chips' tree readers give them.
pub const Range = extern struct {
    start: u64,
    end: u64,
};

/// How many ranges of each kind the structure carries. A PC's memory map is
/// cut into far more pieces than a device tree's - the firmware's own code
/// and data, its runtime services, its tables, the holes below 1 MiB - so
/// these are larger than the eight a tree is read into. The stub says how
/// many it dropped (`memory_dropped`, `reserved_dropped`) rather than
/// silently losing them, and a machine that drops any is a machine these
/// numbers are too small for.
pub const max_memory = 32;
pub const max_reserved = 32;

/// What the pixels of the framebuffer the firmware has already lit look
/// like. The order is the one the graphics protocol names; a format the
/// stub does not know is `unknown`, and the display driver then leaves the
/// panel alone.
pub const PixelFormat = enum(u32) {
    unknown = 0,
    /// Blue, green, red, one byte each, and a byte that is not used.
    bgrx32 = 1,
    /// Red, green, blue, one byte each, and a byte that is not used.
    rgbx32 = 2,
};

/// The framebuffer as the firmware set it up. `base` 0 means the firmware
/// gave none, which is what a machine started with no display does.
pub const Framebuffer = extern struct {
    base: u64 = 0,
    /// Its whole size in bytes, as the firmware reports it.
    size: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// Pixels from the start of one row to the start of the next, which is
    /// not always the width.
    stride: u32 = 0,
    format: PixelFormat = .unknown,
};

/// The machine, as the firmware described it and the stub found it.
pub const Handover = extern struct {
    magic: u64 = MAGIC,
    version: u32 = VERSION,
    /// `@sizeOf(Handover)`, so a kernel that knows a later version can see
    /// at once that it was handed an earlier one.
    size: u32 = @sizeOf(Handover),

    /// The memory the kernel may hand out: the firmware's free memory, and
    /// the memory its own boot code and data were in, which is the
    /// kernel's once the firmware is gone.
    memory: [max_memory]Range = @splat(.{ .start = 0, .end = 0 }),
    memory_count: u32 = 0,
    /// Ranges there was no room for, which is a fault in `max_memory`
    /// rather than in the machine.
    memory_dropped: u32 = 0,

    /// The memory the kernel must leave alone: the firmware's runtime
    /// services, its tables, and everything it did not describe as free.
    /// The kernel's own image and the disk image are **not** in here -
    /// they have fields of their own, because the kernel wants their
    /// bounds for more than keeping off them.
    reserved: [max_reserved]Range = @splat(.{ .start = 0, .end = 0 }),
    reserved_count: u32 = 0,
    reserved_dropped: u32 = 0,

    /// Where the stub put the kernel, and how much of it there is - the
    /// whole of it, its zeroed data at the end included.
    kernel: Range = .{ .start = 0, .end = 0 },
    /// Where the stub put the disk image, which `flash.device` serves from
    /// RAM. An empty range means there was none, and the machine then runs
    /// diskless, as it does on the other boards without one.
    disk: Range = .{ .start = 0, .end = 0 },

    /// The root of the firmware's tables, from its configuration table:
    /// the 2.0 pointer where there is one, else the 1.0 one. 0 where the
    /// firmware published neither, which no machine with this firmware
    /// should do.
    tables: u64 = 0,
    /// The firmware's system table, kept for what only the firmware can do
    /// after it has gone: its runtime services reset the machine and hold
    /// its clock.
    system_table: u64 = 0,

    framebuffer: Framebuffer = .{},

    /// The I/O port of the serial line the kernel is to use as its
    /// console, and the rate the firmware left it at. The stub does not
    /// find these out - the board's description says what this machine
    /// class has, and these are what the firmware was using, so that the
    /// kernel's first line comes out of the same port the stub's did.
    console_port: u16 = 0,
    console_rate: u32 = 0,

    /// How many cores the firmware says there are, which the stub takes
    /// from the tables so that the kernel's memory for per-core state is
    /// right before it reads the tables itself. 0 where it could not tell,
    /// and the kernel then counts them its own way.
    cores: u32 = 0,

    /// A page below the first mebibyte that the firmware called free, and
    /// that nothing else is given: where another core starts. A core of
    /// this architecture is started by a message naming a page by its
    /// number, and that number is a byte - so the page has to be down
    /// there, and the kernel copies the few instructions that bring a core
    /// into the state the rest of the kernel runs in onto it
    /// (`src/arch/x64uefi/start.S`). It is the stub's to find because it
    /// is the only one that sees the firmware's map, which the memory list
    /// above leaves the whole first mebibyte out of. 0 where the firmware
    /// called none of it free, and then the machine runs on one core.
    low_page: u64 = 0,

    /// The memory the kernel may hand out, as a slice.
    pub fn memoryRanges(machine: *const Handover) []const Range {
        return machine.memory[0..@min(machine.memory_count, max_memory)];
    }

    /// The memory it must leave alone, as a slice.
    pub fn reservedRanges(machine: *const Handover) []const Range {
        return machine.reserved[0..@min(machine.reserved_count, max_reserved)];
    }
};
