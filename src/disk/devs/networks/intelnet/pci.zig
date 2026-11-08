// SPDX-License-Identifier: MIT
//! The PCI side of intelnet.device: the controllers the machine has,
//! claimed, switched on and given an interrupt.
//!
//! **How they are found.** pci.library's chain is walked for Intel's
//! functions, and each is offered to the families (`family/_family.zig`)
//! by its device ID. Walking the vendor rather than the Ethernet class
//! is what says which controllers this device drives: another maker's
//! card of the same class is nothing to do with it, and an Intel
//! function of a generation that is not here is passed over rather than
//! claimed and failed.
//!
//! **The interrupt.** A vector of its own is asked for first, which puts
//! every cause in the extended registers and leaves the function's line
//! alone. Where the machine has no vectors to give, the function's
//! interrupt line is hooked and the causes are read from the first
//! register block instead - a line that may be shared, so the server
//! answers only when the controller has really raised something. A
//! function that gets neither is refused: a network card that cannot say
//! a frame arrived is of no use, and nothing here polls.

const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const _intelnet = @import("_intelnet.zig");
const IntelnetBase = _intelnet.IntelnetBase;
const Card = _intelnet.Card;
const Work = _intelnet.Work;
const mac = @import("mac.zig");
const link = @import("link.zig");
const family_file = @import("family/_family.zig");

/// Intel's PCI vendor ID.
const vendor_intel = 0x8086;

/// Every controller the device drives, claimed and reset, a card each.
/// `server` is the interrupt server every card's interrupt runs.
pub fn findAll(base: *IntelnetBase, server: exec.IntServerFn) void {
    const sys = base.sys_base;
    const pb = base.pci_base orelse return;
    var it = pb.FindPCIDevice(null, vendor_intel, pci.PCI_ANY);
    while (it) |function| : (it = pb.FindPCIDevice(function, vendor_intel, pci.PCI_ANY)) {
        const family = family_file.of(function.device_id) orelse continue;
        if (base.card_count == _intelnet.max_cards) break;
        const number = base.card_count;
        if (pb.ClaimPCIDevice(function, _intelnet.DEVICE_NAME)) |holder| {
            sdk.exec.kprintf(sys, "%s: the %s at %x is %s's\n", .{
                _intelnet.DEVICE_NAME, family.name, @as(u32, function.device_id), holder,
            });
            continue;
        }
        const card = make(base, function, family, number, server) orelse {
            pb.ReleasePCIDevice(function);
            continue;
        };
        base.cards[number] = card;
        base.card_count += 1;
    }
}

/// A card made from a function: its memory, its registers, its reset and
/// its interrupt. Null where any of that fails, and then nothing of the
/// function is kept.
fn make(
    base: *IntelnetBase,
    function: *pci.PCIDevice,
    family: *const family_file.Family,
    number: u32,
    server: exec.IntServerFn,
) ?*Card {
    const sys = base.sys_base;
    const pb = base.pci_base.?;
    const memory = sys.AllocMem(@sizeOf(Card), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return null;
    const card: *Card = @ptrCast(@alignCast(memory));
    card.* = .{
        .base = base,
        .sys = sys,
        .pb = pb,
        .function = function,
        .family = family,
        .number = number,
        .coherent = coherent(base, function),
        .unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } },
        // Set below, once the controller has been reset and has its
        // address back: `Unit.init` writes the whole of it.
        .net = undefined,
    };
    card.unit.msg_port.msg_list.init(.message);
    if (!place(card)) {
        sys.FreeMem(memory, @sizeOf(Card));
        return null;
    }
    if (!mac.reset(card.regs, card.family)) {
        sdk.exec.kprintf(sys, "%s: the %s does not come out of reset\n", .{ _intelnet.DEVICE_NAME, family.name });
        sys.FreeMem(memory, @sizeOf(Card));
        return null;
    }
    // The controller asks for a moment after a reset before its
    // registers are written again, and it reloads its address in it.
    base.pause(1000);
    const factory = mac.stationAddress(card.regs);
    card.net.init(sys, card, &factory);
    if (!work(card)) {
        sdk.exec.kprintf(sys, "%s: no memory for the %s's rings\n", .{ _intelnet.DEVICE_NAME, family.name });
        sys.FreeMem(memory, @sizeOf(Card));
        return null;
    }
    card.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = _intelnet.DEVICE_NAME },
        .data = card,
        .code = @ptrCast(server),
    };

    if (!hook(card)) {
        sdk.exec.kprintf(sys, "%s: the %s has no interrupt to raise\n", .{ _intelnet.DEVICE_NAME, family.name });
        // The block its rings were in goes; the card's own memory with
        // it. Nothing was started.
        sys.FreeMem(@ptrFromInt(card.work_memory), card.work_bytes);
        sys.FreeMem(memory, @sizeOf(Card));
        return null;
    }
    if (!link.start(card.regs)) {
        // A part whose medium is not copper has no PHY at that address.
        // Its own side of the link is up, and the status register says
        // what came of that, so the card is kept.
        sdk.exec.kprintf(sys, "%s: the %s has no PHY to negotiate with\n", .{ _intelnet.DEVICE_NAME, family.name });
    }
    return card;
}

/// Whether the controller sees the processors' caches: pci.library says
/// so from revision 1 on, and before that the answer is taken as no.
fn coherent(base: *IntelnetBase, function: *pci.PCIDevice) bool {
    const lib: *exec.Library = @ptrCast(@alignCast(base.pci_base.?));
    return lib.revision >= 1 and function.dma_coherent;
}

/// The function switched on and its registers found: its first base
/// address register is the register block, and it must be memory that
/// was placed.
fn place(card: *Card) bool {
    const pb = card.pb;
    const function = card.function;
    var command = pb.ReadPCIConfig(function, pci.PCI_COMMAND, 2);
    command |= pci.PCI_COMMAND_MEMORY | pci.PCI_COMMAND_MASTER;
    pb.WritePCIConfig(function, pci.PCI_COMMAND, 2, command);
    const bar = function.bars[0];
    if (bar.address == 0 or bar.flags & pci.PCIBAR_IO != 0) {
        sdk.exec.kprintf(card.sys, "%s: the %s's registers were not placed\n", .{
            _intelnet.DEVICE_NAME, card.family.name,
        });
        return false;
    }
    card.regs = @intCast(bar.address);
    return mac.present(card.regs);
}

/// The block the controller reads and writes, allocated where it can
/// reach it and aligned so that both rings start where they must.
fn work(card: *Card) bool {
    const bytes = @sizeOf(Work) + _intelnet.ring_align;
    const memory = card.sys.AllocMem(bytes, exec.MEMF_DMA | exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return false;
    const raw = @intFromPtr(memory);
    const at = (raw + _intelnet.ring_align - 1) & ~@as(usize, _intelnet.ring_align - 1);
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
        // A message-signalled interrupt that is not one of the extended
        // vectors still puts its causes in the first register block.
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
        _intelnet.DEVICE_NAME, card.number,          card.family.name,
        @as(u32, address[0]),  @as(u32, address[1]), @as(u32, address[2]),
        @as(u32, address[3]),  @as(u32, address[4]), @as(u32, address[5]),
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
