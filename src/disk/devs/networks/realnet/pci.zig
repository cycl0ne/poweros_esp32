// SPDX-License-Identifier: MIT
//! The PCI side of realnet.device: the controllers the machine has,
//! claimed, switched on and given an interrupt.
//!
//! **How they are found.** pci.library's chain is walked for Realtek's
//! functions, and each is offered to `mac.partOf` by the revision in its
//! send configuration register - the one register that says which
//! controller this is. Walking the vendor rather than the Ethernet class
//! is what says which controllers this device drives: another maker's
//! card of the same class is nothing to do with it, and a Realtek
//! function of a generation that is not here is passed over rather than
//! claimed and failed.
//!
//! **Where the registers are.** These parts put their register block in
//! their third base address register, as a 64-bit memory one; older
//! placements - a 32-bit memory block, or the port space - are taken
//! where the firmware left one of those instead.
//!
//! **The link's power saving.** The states the link may drop into while
//! nothing is being sent are switched off in the function's PCI Express
//! capability: a link that has to be woken costs a frame its latency,
//! and the part's own documents ask for them to be off.
//!
//! **The interrupt.** A vector of its own is asked for first. Where the
//! machine has no vectors to give, the function's interrupt line is
//! hooked - a line that may be shared, so the server answers only when
//! the controller has really raised something. A function that gets
//! neither is refused: a network card that cannot say a frame arrived is
//! of no use, and nothing here polls.

const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const _realnet = @import("_realnet.zig");
const RealnetBase = _realnet.RealnetBase;
const Card = _realnet.Card;
const Work = _realnet.Work;
const mac = @import("mac.zig");
const setup = @import("setup.zig");
const link = @import("link.zig");

/// Realtek's PCI vendor ID.
const vendor_realtek = 0x10EC;

/// PCI's class and subclass for an Ethernet controller. The maker's
/// other parts in a machine - a card reader, a sound part - are passed
/// over by it before anything of theirs is read.
const class_ethernet: u32 = 0x02_00_00;

/// The PCI Express capability, and its link control register, where the
/// states the link may drop into are turned off.
const cap_express = 0x10;
const express_link_control = 0x10;
const link_aspm: u32 = 0x0003;
const link_clock_pm: u32 = 0x0100;

/// Every controller the device drives, claimed and set up, a card each.
/// `server` is the interrupt server every card's interrupt runs.
pub fn findAll(base: *RealnetBase, server: exec.IntServerFn) void {
    const sys = base.sys_base;
    const pb = base.pci_base orelse return;
    var it = pb.FindPCIDevice(null, vendor_realtek, pci.PCI_ANY);
    while (it) |function| : (it = pb.FindPCIDevice(function, vendor_realtek, pci.PCI_ANY)) {
        if (function.class_code & pci.PCI_CLASS_SUB_MASK != class_ethernet) continue;
        if (base.card_count == _realnet.max_cards) break;
        const number = base.card_count;
        if (pb.ClaimPCIDevice(function, _realnet.DEVICE_NAME)) |holder| {
            sdk.exec.kprintf(sys, "%s: the controller at %x is %s's\n", .{
                _realnet.DEVICE_NAME, @as(u32, function.device_id), holder,
            });
            continue;
        }
        const card = make(base, function, number, server) orelse {
            pb.ReleasePCIDevice(function);
            continue;
        };
        base.cards[number] = card;
        base.card_count += 1;
    }
}

/// A card made from a function: its registers, its set-up, its memory
/// and its interrupt. Null where any of that fails, and then nothing of
/// the function is kept.
fn make(base: *RealnetBase, function: *pci.PCIDevice, number: u32, server: exec.IntServerFn) ?*Card {
    const sys = base.sys_base;
    const pb = base.pci_base.?;
    const regs = place(base, function) orelse return null;
    const part = mac.partOf(regs) orelse {
        sdk.exec.kprintf(sys, "%s: the controller at %x is a revision %lx this device does not drive\n", .{
            _realnet.DEVICE_NAME, @as(u32, function.device_id), @as(i64, mac.revision(regs)),
        });
        return null;
    };
    const memory = sys.AllocMem(@sizeOf(Card), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return null;
    const card: *Card = @ptrCast(@alignCast(memory));
    card.* = .{
        .base = base,
        .sys = sys,
        .pb = pb,
        .function = function,
        .regs = regs,
        .part = part,
        .number = number,
        .coherent = coherent(base, function),
        .unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } },
        // Set below, once the controller has its address back:
        // `Unit.init` writes the whole of it.
        .net = undefined,
    };
    card.unit.msg_port.msg_list.init(.message);
    quietLink(card);
    if (!setup.chip(regs, part)) {
        sdk.exec.kprintf(sys, "%s: the %s does not come out of reset\n", .{ _realnet.DEVICE_NAME, part.name });
        sys.FreeMem(memory, @sizeOf(Card));
        return null;
    }
    // The PHY told to offer what it has and to negotiate. Once is
    // enough: it keeps the link by itself, and the unit above hears
    // every change on the controller's own cause.
    link.negotiate(regs);
    // The part reloads its address out of its own storage after a reset,
    // and wants a moment to do it in.
    base.pause(1000);
    const factory = mac.stationAddress(regs);
    card.net.init(sys, card, &factory);
    if (!work(card)) {
        sdk.exec.kprintf(sys, "%s: no memory for the %s's rings\n", .{ _realnet.DEVICE_NAME, part.name });
        sys.FreeMem(memory, @sizeOf(Card));
        return null;
    }
    card.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = _realnet.DEVICE_NAME },
        .data = card,
        .code = @ptrCast(server),
    };
    if (!hook(card)) {
        sdk.exec.kprintf(sys, "%s: the %s has no interrupt to raise\n", .{ _realnet.DEVICE_NAME, part.name });
        sys.FreeMem(@ptrFromInt(card.work_memory), card.work_bytes);
        sys.FreeMem(memory, @sizeOf(Card));
        return null;
    }
    return card;
}

/// Whether the controller sees the processors' caches: pci.library says
/// so from revision 1 on, and before that the answer is taken as no.
fn coherent(base: *RealnetBase, function: *pci.PCIDevice) bool {
    const lib: *exec.Library = @ptrCast(@alignCast(base.pci_base.?));
    return lib.revision >= 1 and function.dma_coherent;
}

/// The function switched on and its registers found: the third base
/// address register where the firmware placed one there, else the
/// second, else nothing - the register block has to be memory, since
/// everything this device does to the part is a memory access.
fn place(base: *RealnetBase, function: *pci.PCIDevice) ?usize {
    const pb = base.pci_base.?;
    var command = pb.ReadPCIConfig(function, pci.PCI_COMMAND, 2);
    command |= pci.PCI_COMMAND_MEMORY | pci.PCI_COMMAND_MASTER;
    pb.WritePCIConfig(function, pci.PCI_COMMAND, 2, command);
    for ([_]usize{ 2, 1 }) |which| {
        const bar = function.bars[which];
        if (bar.address == 0 or bar.flags & pci.PCIBAR_IO != 0) continue;
        const at: usize = @intCast(bar.address);
        if (!mac.present(at)) continue;
        return at;
    }
    sdk.exec.kprintf(base.sys_base, "%s: the controller at %x has no register block in memory\n", .{
        _realnet.DEVICE_NAME, @as(u32, function.device_id),
    });
    return null;
}

/// The states the link may drop into while nothing is being sent,
/// turned off. A function without the capability is one whose link has
/// none of them.
fn quietLink(card: *Card) void {
    const pb = card.pb;
    const at = pb.FindPCICapability(card.function, cap_express, 0);
    if (at == 0) return;
    const control = pb.ReadPCIConfig(card.function, at + express_link_control, 2);
    pb.WritePCIConfig(card.function, at + express_link_control, 2, control & ~(link_aspm | link_clock_pm));
}

/// The block the controller reads and writes, allocated where it can
/// reach it and aligned so that both rings start where they must.
fn work(card: *Card) bool {
    const bytes = @sizeOf(Work) + _realnet.ring_align;
    const memory = card.sys.AllocMem(bytes, exec.MEMF_DMA | exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return false;
    const raw = @intFromPtr(memory);
    const at = (raw + _realnet.ring_align - 1) & ~@as(usize, _realnet.ring_align - 1);
    card.work_memory = raw;
    card.work_bytes = bytes;
    card.work = @ptrFromInt(at);
    return true;
}

/// The card's interrupt hooked: a vector of its own, a message on vector
/// 0, or its interrupt line. False where it gets none of them.
fn hook(card: *Card) bool {
    const pb = card.pb;
    const function = card.function;
    if (pb.AllocPCIVectors(function, 1) == 1 and pb.AddPCIVectorServer(function, 0, &card.int)) {
        card.signalling = if (function.vector_kind == pci.PCI_VECTORS_MSIX) .vector else .message;
        return true;
    }
    pb.FreePCIVectors(function);
    if (pb.AddPCIIntServer(function, &card.int)) {
        const command = pb.ReadPCIConfig(function, pci.PCI_COMMAND, 2);
        pb.WritePCIConfig(function, pci.PCI_COMMAND, 2, command & ~@as(u32, pci.PCI_COMMAND_INTX_DISABLE));
        card.signalling = .line;
        return true;
    }
    card.signalling = .none;
    return false;
}

/// The line the device prints for a card it has taken: what it is,
/// which address it came with, and how it raises its interrupt. What the
/// link is doing is said by the card itself, whenever that changes.
pub fn describe(card: *Card) void {
    const address = card.net.station;
    sdk.exec.kprintf(card.sys, "%s: unit %u: %s, %x:%x:%x:%x:%x:%x, %s\n", .{
        _realnet.DEVICE_NAME, card.number,          card.part.name,
        @as(u32, address[0]), @as(u32, address[1]), @as(u32, address[2]),
        @as(u32, address[3]), @as(u32, address[4]), @as(u32, address[5]),
        signalling(card),
    });
}

/// How the card's interrupt reaches the task.
fn signalling(card: *Card) [*:0]const u8 {
    return switch (card.signalling) {
        .vector => "a vector of its own",
        .message => "a message on vector 0",
        .line => "its interrupt line",
        .none => "nothing",
    };
}
