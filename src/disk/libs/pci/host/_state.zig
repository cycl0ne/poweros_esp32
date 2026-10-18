// SPDX-License-Identifier: MIT
//! What a reset clears of a function's configuration - what the library
//! and its driver set up in it - kept, and put back.
//!
//! ResetPCIDevice keeps it before the reset it gives a function. The
//! walk keeps it too, once the function is set up (`Entry.kept`): a
//! function that was reset behind the library's back since - its link
//! went down and came back, as a function whose power dipped takes it
//! down - has it put back when a driver claims it.

const sdk = @import("sdk");
const pci = sdk.pci;
const _host = @import("_host.zig");
const Entry = _host.Entry;
const _vectors = @import("../interrupt/_vectors.zig");

/// The header's first 16 words, and the PCI Express capability's device
/// and link control and their second ones.
pub const Saved = struct {
    header: [16]u32 = @splat(0),
    express: [4]u32 = @splat(0),
};

const express_controls = [4]u32{ pci.PCI_EXP_DEVCTL, pci.PCI_EXP_LNKCTL, pci.PCI_EXP_DEVCTL2, pci.PCI_EXP_LNKCTL2 };

pub fn save(entry: *Entry) Saved {
    var saved = Saved{};
    for (&saved.header, 0..) |*word, i| word.* = read(entry, @intCast(i * 4), 4);
    const exp = entry.cap_express;
    if (exp != 0) {
        for (&saved.express, express_controls) |*word, offset| word.* = read(entry, exp + offset, 2);
    }
    return saved;
}

/// What `save` kept written back: PCI Express control first, the BARs,
/// the ROM, the cache line and the interrupt line, the command last but
/// for the vectors - an MSI-X table is reached through a BAR once its
/// memory is decoded. A function with a PCI_HEADER_NORMAL header.
pub fn restore(entry: *Entry, saved: *const Saved) void {
    const exp = entry.cap_express;
    if (exp != 0) {
        const version = read(entry, exp + pci.PCI_EXP_FLAGS, 2) & 0xF;
        const kept: usize = if (version >= 2) 4 else 2;
        for (saved.express[0..kept], express_controls[0..kept]) |word, offset| write(entry, exp + offset, 2, word);
    }
    var i: u32 = pci.PCI_BASE_ADDRESS_0 / 4;
    while (i < pci.PCI_BASE_ADDRESS_0 / 4 + 6) : (i += 1) write(entry, i * 4, 4, saved.header[i]);
    write(entry, pci.PCI_ROM_ADDRESS, 4, saved.header[pci.PCI_ROM_ADDRESS / 4]);
    write(entry, pci.PCI_CACHE_LINE_SIZE, 1, saved.header[pci.PCI_CACHE_LINE_SIZE / 4]);
    write(entry, pci.PCI_LATENCY_TIMER, 1, saved.header[pci.PCI_CACHE_LINE_SIZE / 4] >> 8);
    write(entry, pci.PCI_INTERRUPT_LINE, 1, saved.header[pci.PCI_INTERRUPT_LINE / 4]);
    write(entry, pci.PCI_COMMAND, 2, saved.header[pci.PCI_COMMAND / 4]);
    _vectors.restore(entry);
}

/// Whether the function lost what `saved` has of it - a BAR, or what
/// its command decodes - as a reset leaves it. False for one that does
/// not answer: there is nothing to put back yet.
pub fn lost(entry: *Entry, saved: *const Saved) bool {
    const vendor = read(entry, pci.PCI_VENDOR_ID, 2);
    if (vendor == 0xFFFF or vendor == 0x0001) return false;
    var i: u32 = pci.PCI_BASE_ADDRESS_0 / 4;
    while (i < pci.PCI_BASE_ADDRESS_0 / 4 + 6) : (i += 1) {
        if (read(entry, i * 4, 4) != saved.header[i]) return true;
    }
    const decoding: u32 = pci.PCI_COMMAND_IO | pci.PCI_COMMAND_MEMORY;
    return read(entry, pci.PCI_COMMAND, 2) & decoding != saved.header[pci.PCI_COMMAND / 4] & decoding;
}

fn read(entry: *Entry, offset: u32, size: u32) u32 {
    return _host.read(entry.host, _host.addressOf(&entry.device), offset, size);
}

fn write(entry: *Entry, offset: u32, size: u32, value: u32) void {
    _host.write(entry.host, _host.addressOf(&entry.device), offset, size, value);
}
