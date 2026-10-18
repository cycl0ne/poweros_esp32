// SPDX-License-Identifier: MIT
//! What AllocPCIVectors and the calls after it share: a function's MSI
//! or MSI-X set up with a run of the host bridge's vectors, each vector
//! masked and let through, and all of it written again after a reset.
//!
//! **MSI-X** is taken where the function has it and its table is in a
//! BAR that was placed: every entry gets the bridge's address and its
//! own vector as its data, and stays masked until a server is on it.
//! **MSI** otherwise: a power-of-two run of vectors, aligned to its size
//! - the function puts the vector's number in the data's low bits - and
//! each vector masked where the function can mask them one by one. A
//! function signalling messages raises no INTx: its INTx is switched off
//! while it has vectors.

const sdk = @import("sdk");
const pci = sdk.pci;
const _host = @import("../host/_host.zig");
const Entry = _host.Entry;

const four_gib: u64 = 1 << 32;

/// Up to `count` vectors for the function: how many it got. Under the
/// claim lock.
pub fn allocate(entry: *Entry, count: u32) u32 {
    const device = &entry.device;
    if (device.vectors != 0) return device.vectors;
    if (count == 0 or entry.host.msi_count == 0) return 0;
    if (entry.cap_msix != 0 and allocateMsix(entry, count)) return device.vectors;
    if (entry.cap_msi != 0 and allocateMsi(entry, count)) return device.vectors;
    return 0;
}

fn allocateMsix(entry: *Entry, count: u32) bool {
    const device = &entry.device;
    const table = msixTable(entry) orelse return false;
    var n: u32 = @min(count, device.msix_vectors, entry.host.msi_count);
    const first = while (n > 0) : (n -= 1) {
        if (_host.takeVectors(entry.host, n, 1)) |first| break first;
    } else return false;
    entry.vector_base = first;
    entry.msix_table = table;
    device.vectors = @intCast(n);
    device.vector_kind = pci.PCI_VECTORS_MSIX;
    programMsix(entry);
    return true;
}

fn allocateMsi(entry: *Entry, count: u32) bool {
    const device = &entry.device;
    const host = entry.host;
    const flags = read(entry, entry.cap_msi + pci.PCI_MSI_FLAGS, 2);
    if (flags & pci.PCI_MSI_FLAGS_64BIT == 0 and host.msi_address >= four_gib) return false;
    var n = powerAtMost(@min(count, device.msi_vectors, host.msi_count));
    const first = while (n > 0) : (n /= 2) {
        if (_host.takeVectors(host, n, n)) |first| break first;
    } else return false;
    entry.vector_base = first;
    device.vectors = @intCast(n);
    device.vector_kind = pci.PCI_VECTORS_MSI;
    programMsi(entry);
    return true;
}

/// Where the processor reaches the function's MSI-X table; null where it
/// cannot: its BAR not placed, or not decoded.
fn msixTable(entry: *Entry) ?usize {
    const device = &entry.device;
    const where = read(entry, entry.cap_msix + pci.PCI_MSIX_TABLE, 4);
    const bir = where & pci.PCI_MSIX_TABLE_BIR;
    if (bir >= 6) return null;
    const bar = device.bars[bir];
    const offset: u64 = where & pci.PCI_MSIX_TABLE_OFFSET;
    if (bar.address == 0 or bar.flags & pci.PCIBAR_IO != 0) return null;
    if (offset + @as(u64, device.msix_vectors) * pci.PCI_MSIX_ENTRY_SIZE > bar.size) return null;
    if (read(entry, pci.PCI_COMMAND, 2) & pci.PCI_COMMAND_MEMORY == 0) return null;
    return @intCast(bar.address + offset);
}

/// The function's MSI-X written from what it was given: on, every entry
/// masked while its table is written, then each let through that has a
/// server.
fn programMsix(entry: *Entry) void {
    const device = &entry.device;
    const host = entry.host;
    const cap = entry.cap_msix;
    const flags = read(entry, cap + pci.PCI_MSIX_FLAGS, 2);
    write(entry, cap + pci.PCI_MSIX_FLAGS, 2, flags | pci.PCI_MSIX_FLAGS_MASKALL | pci.PCI_MSIX_FLAGS_ENABLE);
    var i: u32 = 0;
    while (i < device.msix_vectors) : (i += 1) {
        const slot = msixEntry(entry, i);
        if (i < device.vectors) {
            slot[0] = @truncate(host.msi_address);
            slot[1] = @truncate(host.msi_address >> 32);
            slot[2] = entry.vector_base + i;
        }
        slot[3] = slot[3] | pci.PCI_MSIX_ENTRY_CTRL_MASKBIT;
    }
    intx(entry, false);
    write(entry, cap + pci.PCI_MSIX_FLAGS, 2, (flags | pci.PCI_MSIX_FLAGS_ENABLE) & ~@as(u32, pci.PCI_MSIX_FLAGS_MASKALL));
    i = 0;
    while (i < device.vectors) : (i += 1) mask(entry, i, !hasServer(entry, i));
}

/// The function's MSI written from what it was given: the address, its
/// first vector as the data, as many vectors as it was given, each
/// masked that has no server, and on.
fn programMsi(entry: *Entry) void {
    const device = &entry.device;
    const host = entry.host;
    const cap = entry.cap_msi;
    var flags = read(entry, cap + pci.PCI_MSI_FLAGS, 2);
    const wide = flags & pci.PCI_MSI_FLAGS_64BIT != 0;
    write(entry, cap + pci.PCI_MSI_FLAGS, 2, flags & ~@as(u32, pci.PCI_MSI_FLAGS_ENABLE));
    write(entry, cap + pci.PCI_MSI_ADDRESS_LO, 4, @as(u32, @truncate(host.msi_address)) & 0xFFFF_FFFC);
    if (wide) write(entry, cap + pci.PCI_MSI_ADDRESS_HI, 4, @truncate(host.msi_address >> 32));
    write(entry, cap + (if (wide) pci.PCI_MSI_DATA_64 else pci.PCI_MSI_DATA_32), 2, entry.vector_base);
    var i: u32 = 0;
    while (i < device.vectors) : (i += 1) mask(entry, i, !hasServer(entry, i));
    const given: u32 = @ctz(@as(u32, device.vectors));
    flags &= ~@as(u32, pci.PCI_MSI_FLAGS_QSIZE);
    flags |= (given << 4) | pci.PCI_MSI_FLAGS_ENABLE;
    intx(entry, false);
    write(entry, cap + pci.PCI_MSI_FLAGS, 2, flags);
}

/// Vector `vector` of the function's masked, or let through. A function
/// whose MSI cannot mask one vector alone sends it either way.
pub fn mask(entry: *Entry, vector: u32, masked: bool) void {
    switch (entry.device.vector_kind) {
        pci.PCI_VECTORS_MSIX => {
            const slot = msixEntry(entry, vector);
            const control = slot[3];
            slot[3] = if (masked) control | pci.PCI_MSIX_ENTRY_CTRL_MASKBIT else control & ~pci.PCI_MSIX_ENTRY_CTRL_MASKBIT;
            // Read back: the write has reached the function.
            _ = slot[3];
        },
        pci.PCI_VECTORS_MSI => {
            const cap = entry.cap_msi;
            const flags = read(entry, cap + pci.PCI_MSI_FLAGS, 2);
            if (flags & pci.PCI_MSI_FLAGS_MASKBIT == 0) return;
            const offset = cap + (if (flags & pci.PCI_MSI_FLAGS_64BIT != 0) pci.PCI_MSI_MASK_64 else pci.PCI_MSI_MASK_32);
            const bits = read(entry, offset, 4);
            const bit = @as(u32, 1) << @intCast(vector);
            write(entry, offset, 4, if (masked) bits | bit else bits & ~bit);
        },
        else => {},
    }
}

/// The function's vectors given back: its MSI or MSI-X off, every server
/// still on one taken off, its INTx on again. Under the claim lock.
pub fn free(entry: *Entry) void {
    const device = &entry.device;
    if (device.vectors == 0) return;
    switch (device.vector_kind) {
        pci.PCI_VECTORS_MSIX => {
            const cap = entry.cap_msix;
            const flags = read(entry, cap + pci.PCI_MSIX_FLAGS, 2);
            write(entry, cap + pci.PCI_MSIX_FLAGS, 2, (flags | pci.PCI_MSIX_FLAGS_MASKALL) & ~@as(u32, pci.PCI_MSIX_FLAGS_ENABLE));
        },
        pci.PCI_VECTORS_MSI => {
            const cap = entry.cap_msi;
            const flags = read(entry, cap + pci.PCI_MSI_FLAGS, 2);
            write(entry, cap + pci.PCI_MSI_FLAGS, 2, flags & ~@as(u32, pci.PCI_MSI_FLAGS_ENABLE | pci.PCI_MSI_FLAGS_QSIZE));
        },
        else => {},
    }
    intx(entry, true);
    _host.clearVectors(entry.host, entry.vector_base, device.vectors);
    _host.giveVectors(entry.host, entry.vector_base, device.vectors);
    device.vectors = 0;
    device.vector_kind = pci.PCI_VECTORS_NONE;
    entry.vector_base = 0;
    entry.msix_table = 0;
}

/// What the function was given written again, as after a reset, which
/// lost it.
pub fn restore(entry: *Entry) void {
    switch (entry.device.vector_kind) {
        pci.PCI_VECTORS_MSIX => programMsix(entry),
        pci.PCI_VECTORS_MSI => programMsi(entry),
        else => {},
    }
}

/// Whether the function's vector `vector` has a server.
pub fn hasServer(entry: *const Entry, vector: u32) bool {
    return !entry.host.vectors[entry.vector_base + vector].isEmpty();
}

/// The four words of the function's MSI-X table entry `index`.
fn msixEntry(entry: *const Entry, index: u32) *volatile [4]u32 {
    return @ptrFromInt(entry.msix_table + index * pci.PCI_MSIX_ENTRY_SIZE);
}

/// The function's INTx on, or off.
fn intx(entry: *Entry, on: bool) void {
    const command = read(entry, pci.PCI_COMMAND, 2);
    const off: u32 = pci.PCI_COMMAND_INTX_DISABLE;
    write(entry, pci.PCI_COMMAND, 2, if (on) command & ~off else command | off);
}

fn read(entry: *Entry, offset: u32, size: u32) u32 {
    return _host.read(entry.host, _host.addressOf(&entry.device), offset, size);
}

fn write(entry: *Entry, offset: u32, size: u32, value: u32) void {
    _host.write(entry.host, _host.addressOf(&entry.device), offset, size, value);
}

/// The power of two at or below `value`; 0 for 0.
fn powerAtMost(value: u32) u32 {
    if (value == 0) return 0;
    return @as(u32, 1) << @intCast(31 - @clz(value));
}
