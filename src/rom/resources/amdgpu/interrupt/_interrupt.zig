// SPDX-License-Identifier: MPL-2.0
//! The device's interrupts: the ring its interrupt block writes an entry
//! into for each one, and the message on PCI that says one was written.
//!
//! Every block of the device raises its interrupts through the one
//! interrupt block. For each it writes a 32-byte entry - which client
//! raised it, which of that client's sources, and what the source adds -
//! into a ring in memory, moves its write pointer on and sends the
//! function's message. The resource's server for that message (`serve`)
//! reads the entries from where it stopped up to the write pointer, hands
//! each to the servers added for its client and source (AddGPUIntServer),
//! and tells the block how far it has read - which is also what lets it
//! send its next message: until the read pointer is written, none comes.
//!
//! **Where the ring is.** In the device's own memory (AllocGPUMemory),
//! named by the device's address of it, which the block reaches as the
//! device's other blocks reach that memory: through the memory hub's
//! first context, which maps the device's memory onto itself. The CPU
//! reads it uncached, so what the block wrote is read as it is. Each
//! entry's first word is cleared once it is read, so that one the block
//! has moved its pointer past but whose words are still on their way is
//! known, and waited for. The write pointer is written back just past the
//! ring, as the block wants an address for it; it is read from the
//! block's register, which is what it is.
//!
//! **What else is written.** One ring, without a doorbell - the read
//! pointer goes into the block's own register - its overflow switched on
//! and cleared, and the two guards against a client that floods it that
//! the block has. Nothing is moved to a second ring. The block's two
//! register maps known are 6.0's and 6.1's, which differ in where the
//! pointers are.
//!
//! The ring is started when the first server is added (`start`), so a
//! machine whose drivers ask for no interrupt never has it written.

const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const amdgpu = sdk.resources.amdgpu;
const reg = sdk.hardware.mmio.reg;
const _base = @import("../amdgpu_base.zig");
const AMDGPUBase = _base.AMDGPUBase;

/// One server added: the client and source it is for, and the server.
pub const Server = extern struct {
    client: u32 = 0,
    source: u32 = 0,
    server: ?*exec.Interrupt = null,
};

/// The most servers added at once.
pub const servers_max = 16;

/// The ring: 2048 entries of 32 bytes, and where the write pointer is
/// written back, just past it.
const ring_bytes: u32 = 64 * 1024;
const entry_bytes: u32 = 32;
const written_back_room: u32 = 256;
/// The ring's size as the block takes it: the power of two its words are.
const ring_size_code: u32 = 14;
comptime {
    if (@as(u32, 4) << ring_size_code != ring_bytes) @compileError("the ring's size code does not match its bytes");
}

/// Where a register map's registers are, counted in words from the
/// block's first segment.
const Map = struct {
    rb_cntl: u32,
    rb_base: u32,
    rb_base_hi: u32,
    rb_rptr: u32,
    rb_wptr: u32,
    wptr_addr_hi: u32,
    wptr_addr_lo: u32,
    doorbell_rptr: u32,
    storm_clients: u32,
    flood: u32,
    msi_storm: u32,
    /// Whether an overflow noted before the ring was switched on is
    /// cleared as it is: 6.0 keeps one through a write of the pointer.
    clear_on_start: bool,
};

/// The kernel's osssys_6_0_0_offset.h and osssys_6_1_0_offset.h.
const map_6_0 = Map{
    .rb_cntl = 0x80,
    .rb_base = 0x81,
    .rb_base_hi = 0x82,
    .rb_rptr = 0x83,
    .rb_wptr = 0x84,
    .wptr_addr_hi = 0x85,
    .wptr_addr_lo = 0x86,
    .doorbell_rptr = 0x87,
    .storm_clients = 0xda,
    .flood = 0xd5,
    .msi_storm = 0xf1,
    .clear_on_start = true,
};
const map_6_1 = Map{
    .rb_cntl = 0x80,
    .rb_rptr = 0x81,
    .rb_wptr = 0x82,
    .rb_base = 0x83,
    .rb_base_hi = 0x84,
    .wptr_addr_hi = 0x85,
    .wptr_addr_lo = 0x86,
    .doorbell_rptr = 0x87,
    .storm_clients = 0xaa,
    .flood = 0xd5,
    .msi_storm = 0xf1,
    .clear_on_start = false,
};

// The ring's control word.
const rb_enable: u32 = 1 << 0;
const rb_size_shift = 1;
const rb_size_mask: u32 = 0x1f << rb_size_shift;
const wptr_writeback: u32 = 1 << 8;
const overflow_enable: u32 = 1 << 16;
const enable_intr: u32 = 1 << 17;
const mc_snoop: u32 = 1 << 20;
const rptr_rearm: u32 = 1 << 21;
const mc_ro: u32 = 1 << 22;
const mc_vmid_mask: u32 = 0xf << 24;
const mc_space_shift = 28;
const mc_space_mask: u32 = 0x7 << mc_space_shift;
/// The ring named by an address of the device's own - through the memory
/// hub's context - rather than a bus address.
const mc_space_device: u32 = 4;
const overflow_clear: u32 = 1 << 31;
/// The write pointer: overflowed, and where the next entry goes.
const wptr_overflow: u32 = 1 << 0;
const pointer_mask: u32 = 0x3fffc;
/// A client that floods the ring, and the delay between messages while
/// one does: the memory hub's faults, as the kernel's driver sets it.
const storm_client_memory_faults: u32 = 1 << 18;
const flood_enable: u32 = 1 << 3;
const msi_storm_delay_mask: u32 = 0xfff;
const msi_storm_delay: u32 = 3;

/// How many times an entry whose first word is still clear is looked at
/// again before it is taken as it is.
const late_looks = 1000;

/// The register map of `block`, null for one whose ring is not known.
fn mapOf(block: amdgpu.GPUBlock) ?*const Map {
    if (block.count == 0 or block.major != 6) return null;
    return switch (block.minor) {
        0 => &map_6_0,
        1 => &map_6_1,
        else => null,
    };
}

/// The interrupt block taken, where its ring is one whose registers are
/// known; said once when not.
pub fn take(ab: *AMDGPUBase, block: amdgpu.GPUBlock) void {
    if (mapOf(block) == null) {
        exec.kprintf(ab.sys_base, "amdgpu.resource: the interrupt block %d.%d.%d is not one whose ring is known\n", .{
            @as(u32, block.major), @as(u32, block.minor), @as(u32, block.revision),
        });
        return;
    }
    ab.interrupts = block;
    ab.interrupts_known = true;
}

fn at(ab: *const AMDGPUBase, offset: u32) *volatile u32 {
    return reg(@as(usize, @intCast(ab.info.registers)) + @as(usize, ab.interrupts.addresses[0] + offset) * 4);
}

fn fence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

fn interface(ab: *AMDGPUBase) *sdk.interface.amdgpu.AMDGPUBase {
    return @ptrCast(&ab.lib);
}

/// The ring started: its memory taken and cleared, the device's message
/// hooked, and the block told where the ring is and to write it. False,
/// said on the raw port, where any of it cannot be had; nothing is left
/// taken then. Under the interrupt lock.
pub fn start(ab: *AMDGPUBase) bool {
    const sys = ab.sys_base;
    const map = mapOf(ab.interrupts) orelse return false;
    const device = ab.device orelse return false;
    const pb = ab.pci orelse return false;
    var ring: amdgpu.GPUMemory = .{};
    if (!interface(ab).AllocGPUMemory(ring_bytes + written_back_room, 256, &ring)) {
        exec.kprintf(sys, "amdgpu.resource: no room in the device's memory for the interrupt ring\n", .{});
        return false;
    }
    const words: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(ring.cpu)));
    for (0..(ring_bytes + written_back_room) / 4) |index| words[index] = 0;
    fence();
    ab.ih_ring = ring;
    ab.ih_read = 0;

    ab.ih_vector = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = "amdgpu.resource" },
        .data = ab,
        .code = &serve,
    };
    if (pb.AllocPCIVectors(device, 1) != 1 or !pb.AddPCIVectorServer(device, 0, &ab.ih_vector)) {
        pb.FreePCIVectors(device);
        interface(ab).FreeGPUMemory(&ab.ih_ring);
        exec.kprintf(sys, "amdgpu.resource: the device has no message vector for its interrupts\n", .{});
        return false;
    }
    const command = pb.ReadPCIConfig(device, pci.PCI_COMMAND, 2);
    pb.WritePCIConfig(device, pci.PCI_COMMAND, 2, command | pci.PCI_COMMAND_MASTER);

    // Off, and both pointers at the start.
    var control = at(ab, map.rb_cntl).*;
    control &= ~(rb_enable | enable_intr);
    at(ab, map.rb_cntl).* = control;
    at(ab, map.rb_rptr).* = 0;
    at(ab, map.rb_wptr).* = 0;

    // Where the ring is, and how it is written.
    at(ab, map.rb_base).* = @truncate(ring.device >> 8);
    at(ab, map.rb_base_hi).* = @truncate(ring.device >> 40 & 0xff);
    control &= ~(rb_size_mask | mc_space_mask | mc_vmid_mask | mc_ro);
    control |= mc_space_device << mc_space_shift | overflow_clear | overflow_enable |
        ring_size_code << rb_size_shift | wptr_writeback | mc_snoop | rptr_rearm;
    at(ab, map.rb_cntl).* = control;
    const written_back = ring.device + ring_bytes;
    at(ab, map.wptr_addr_lo).* = @truncate(written_back);
    at(ab, map.wptr_addr_hi).* = @truncate(written_back >> 32 & 0xffff);
    at(ab, map.rb_wptr).* = 0;
    at(ab, map.rb_rptr).* = 0;
    at(ab, map.doorbell_rptr).* = 0;

    // The guards against a flooding client, as the kernel's driver sets
    // them.
    at(ab, map.storm_clients).* = at(ab, map.storm_clients).* | storm_client_memory_faults;
    at(ab, map.flood).* = at(ab, map.flood).* | flood_enable;
    at(ab, map.msi_storm).* = at(ab, map.msi_storm).* & ~msi_storm_delay_mask | msi_storm_delay;

    // On. 6.0 clears an overflow only with the ring on, so it is cleared
    // after; its interrupt comes last.
    ab.ih_running = true;
    if (map.clear_on_start) {
        control = control & ~overflow_clear | rb_enable;
        at(ab, map.rb_cntl).* = control;
        at(ab, map.rb_cntl).* = control | overflow_clear;
        control = control & ~overflow_clear | enable_intr;
        at(ab, map.rb_cntl).* = control;
    } else {
        control = control & ~overflow_clear | rb_enable | enable_intr;
        at(ab, map.rb_cntl).* = control;
    }
    exec.kprintf(sys, "amdgpu.resource: the interrupt ring at 0x%lx, %d entries, control %x, by %s\n", .{
        ring.device,
        ring_bytes / entry_bytes,
        at(ab, map.rb_cntl).*,
        if (device.vector_kind == pci.PCI_VECTORS_MSIX) @as([*:0]const u8, "a vector of its own") else "a message",
    });
    return true;
}

/// The device's message: every entry the ring holds handed on, and the
/// block told how far it was read - each time, since it sends no further
/// message until it is told.
fn serve(data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const ab: *AMDGPUBase = @ptrCast(@alignCast(data.?));
    if (!ab.ih_running) return 0;
    const map = mapOf(ab.interrupts) orelse return 0;
    const ring: usize = @intCast(ab.ih_ring.cpu);
    var rounds: u32 = 0;
    while (rounds < 4) : (rounds += 1) {
        var written = at(ab, map.rb_wptr).*;
        if (written & wptr_overflow != 0) {
            // The entries from just past the write pointer on are the
            // oldest not written over.
            written &= ~wptr_overflow;
            ab.ih_read = (written & pointer_mask) + entry_bytes & (ring_bytes - 1);
            ab.ih_overflows +%= 1;
            const control = at(ab, map.rb_cntl).*;
            at(ab, map.rb_cntl).* = control | overflow_clear;
            at(ab, map.rb_cntl).* = control & ~overflow_clear;
        }
        const end = written & pointer_mask & (ring_bytes - 1);
        if (end == ab.ih_read) break;
        while (ab.ih_read != end) {
            const entry: [*]volatile u32 = @ptrFromInt(ring + ab.ih_read);
            var first = entry[0];
            var looks: u32 = 0;
            while (first == 0 and looks < late_looks) : (looks += 1) first = entry[0];
            entry[0] = 0;
            hand(ab, first & 0xff, first >> 8 & 0xff);
            ab.ih_read = ab.ih_read + entry_bytes & (ring_bytes - 1);
            ab.ih_entries +%= 1;
        }
    }
    at(ab, map.rb_rptr).* = ab.ih_read;
    return 1;
}

/// One entry handed to every server added for its client and source.
fn hand(ab: *AMDGPUBase, client: u32, source: u32) void {
    for (&ab.servers) |*slot| {
        const server = slot.server orelse continue;
        if (slot.client != client or slot.source != source) continue;
        const code: exec.IntServerFn = @ptrCast(@alignCast(server.code orelse continue));
        _ = code(server.data, source);
    }
}
