// SPDX-License-Identifier: MIT
//! The JH7110's PCI Express root ports (CHIP_JH7110_PCIE): PLDA's
//! XpressRICH bridge, one lane each. Port 0 is the VisionFive 2's VL805,
//! the USB controller behind its four USB-A sockets; port 1 its M.2 slot.
//!
//! **Bringing a port up** is done as Linux does it (pcie-starfive.c,
//! pcie-plda-host.c, phy-jh7110-pcie.c), and as U-Boot's driver leaves
//! the bridge's registers after `pci enum`:
//!
//! 1. port 0's PHY, which the USB 3 controller may have instead, given
//!    to PCIe; the PHY's PLL tuned;
//! 2. in the STG block's syscon, the port made a root port and given its
//!    reference clock and CLKREQ;
//! 3. the STG bus's NoC clock and the port's three clocks on - AXI master,
//!    APB, transaction layer - and its six resets let go;
//! 4. PERST# held;
//! 5. the bridge's physical functions 1 to 3 switched off, the root port
//!    on, its class code a PCI-to-PCI bridge's, LTR message forwarding
//!    off (with nowhere to forward to it hangs the bridge), and its
//!    prefetchable window 64-bit;
//! 6. its address translation: configuration space and each memory
//!    window from the processor's side to where the board says it is on
//!    the bus (AXI slave 0's tables), and every address from the bus's
//!    side to the same address in memory - the RAM a function moves data
//!    to;
//! 7. its interrupts masked, what they had seen cleared;
//! 8. PERST# let go after 100 ms, 100 ms more before the first
//!    configuration request, and up to a second for the link - waited
//!    out for both ports at once (`_host.bringUp`).
//!
//! **What the walk does not see**: the root port's BAR0 and BAR1, which
//! are the bridge's window onto memory from the bus side, not memory the
//! port wants: they read 0 and are not written.
//!
//! **Interrupts.** The bridge gathers INTA to INTD - what it has had of
//! each from the link - in its own status register, and raises one
//! interrupt for all of them (PART_Irq, PLIC source 56 for port 0, 57 for
//! port 1). The library hooks it once the first function's server is
//! added: what it saw is cleared, and the servers of each line that was
//! raised run.
//!
//! **Message-signalled interrupts** end up there too. The bridge takes a
//! function's messages at an address of its own on the bus, which its
//! IMSI_ADDR register says, and keeps a bit for each of 32 vectors - the
//! message's data - in ISTATUS_MSI; that any is set is one more bit of
//! its status register. Each vector's bit is cleared before its servers
//! run, as an edge is: a message that comes while they run is seen again.
//!
//! The clocks and resets are `sdk.hardware.system`'s, the syscon offsets
//! the JH7110's as Linux and U-Boot have them (the VisionFive 2's device
//! tree); PERST# is on a GPIO the board names (PART_PinReset), driven by
//! the pin controller (`sdk.hardware.gpio`). What other drivers share -
//! the STG domain's reset word, the PHY's mode, the pin controller's
//! words - changes under Disable.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const boardpin = sdk.expansion.boardpin;
const BoardPin = sdk.expansion.BoardPin;
const system = sdk.hardware.system;
const gpio = sdk.hardware.gpio;
const _host = @import("_host.zig");
const Host = _host.Host;
const Address = _host.Address;
const Window = @import("../scan/place.zig").Window;

fn reg(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}

/// `bits` of the register at `address` set to `value`.
fn update(address: usize, bits: u32, value: u32) void {
    reg(address).* = (reg(address).* & ~bits) | (value & bits);
}

// --- the clock and reset generators -------------------------------------------------

/// Clock `n` of a port's three in the STG generator: AXI master, APB,
/// transaction layer.
fn stgClock(unit: u32, n: u32) u32 {
    return system.STGCLK_PCIE0_AXI_MST0 + 3 * unit + n;
}

/// Reset `n` of a port's six in the STG generator: AXI master, AXI slave
/// 0, AXI slave, bridge, core, APB.
fn stgReset(unit: u32, n: u32) u32 {
    return system.STGRST_PCIE0_AXI_MST0 + 6 * unit + n;
}

// --- the STG syscon -------------------------------------------------------------------

const STG_SYSCON: usize = 0x1024_0000;
/// Each port's block of the syscon's registers.
const syscon_block = [2]usize{ 0x48, 0x1F8 };
/// Which physical function the bridge's registers answer for, from the
/// AXI side: reads, and writes, which share their register with the
/// reference clock's source and CLKREQ.
const SYSCON_AR = 0x78;
const AR_FUNC_MASK: u32 = 0x007F_FF00;
const AR_FUNC_SHIFT = 17;
const SYSCON_AW = 0x7C;
const AW_FUNC_MASK: u32 = 0x0000_7FFF;
const AW_FUNC_SHIFT = 9;
const AW_CKREF_SRC_MASK: u32 = 3 << 18;
const AW_CKREF_SRC: u32 = 2 << 18;
const AW_CLKREQ: u32 = 1 << 22;
/// The port is a root port, not an endpoint.
const SYSCON_RP_NEP = 0xE8;
const K_RP_NEP: u32 = 1 << 8;
/// The link's state: the data link layer is up.
const SYSCON_LNKSTA = 0x170;
const DATA_LINK_ACTIVE: u32 = 1 << 5;
/// Port 0's PHY, shared with the USB 3 controller: which of the two it
/// serves, and USB 3's bus width and PHY enable, in the STG syscon; in
/// the system syscon, the USB controller's reset kept apart from the
/// PHY's while PCIe has it.
const STG_PHY0_MODE = STG_SYSCON + 0x148;
const PHY_MODE_MASK: u32 = 3 << 20;
const STG_PHY0_USB = STG_SYSCON + 0x1F4;
const USB3_BUS_WIDTH_MASK: u32 = 3 << 2;
const USB3_PHY_ENABLE: u32 = 1 << 4;
const SYS_SYSCON: usize = 0x1303_0000;
const SYS_PHY_CONNECT = SYS_SYSCON + 0x18;
const USB_PDRSTN_SPLIT: u32 = 1 << 17;

// --- the PHY ---------------------------------------------------------------------------

const phy_base = [2]usize{ 0x1021_0000, 0x1022_0000 };
/// The PLL's KVCO gain, fine-tuned.
const PHY_KVCO_LEVEL = 0x28;
const PHY_KVCO_TUNE_SIGNAL = 0x80;
const KVCO_FINE_TUNE_LEVEL: u32 = 0x91;
const KVCO_FINE_TUNE_SIGNALS: u32 = 0x0C;

// --- the bridge ------------------------------------------------------------------------

const GEN_SETTINGS = 0x80;
const RP_ENABLE: u32 = 1 << 0;
/// Its class code (above the revision), as the root port's header has it.
const PCIE_PCI_IDS_DW1 = 0x9C;
const PCI_MISC = 0xB4;
const FUNCTION_DIS: u32 = 1 << 15;
const PCIE_WINROM = 0xFC;
const PREF_MEM_WIN_64: u32 = 1 << 3;
const IMASK_LOCAL = 0x180;
const ISTATUS_LOCAL = 0x184;
const INTX_SHIFT = 24;
const INTX_MASK: u32 = 0xF << INTX_SHIFT;
/// ISTATUS_LOCAL and IMASK_LOCAL: a message-signalled interrupt came.
const MSI_EVENT: u32 = 1 << 28;
/// Where on the bus the bridge takes the messages, and the vectors it
/// has had.
const IMSI_ADDR = 0x190;
const ISTATUS_MSI = 0x194;
const msi_vectors = 32;
const PMSG_SUPPORT_RX = 0x3F0;
const PMSG_LTR_SUPPORT: u32 = 1 << 2;

/// The bus side's window onto memory, and the size the whole of it is
/// given: 2^(0x25 + 1) bytes, everything.
const ATR0_PCIE_WIN0_SRCADDR_PARAM = 0x600;
const ATR0_PCIE_WIN0_SRC_ADDR = 0x604;
const PCIE_WIN0_SIZE: u32 = 0x25 << 1;

/// AXI slave 0's translation tables: from the processor's side to the
/// bus. An entry's first word holds its source address's upper bits,
/// its size (2^(n + 1) bytes) and its enable; then the source's upper
/// half, the translated address, and what the translation is for.
const ATR_AXI4_SLV0 = 0x800;
const ATR_ENTRY = 0x20;
const ATR_SRCADDR_PARAM = 0x00;
const ATR_SRC_ADDR = 0x04;
const ATR_TRSL_ADDR_LSB = 0x08;
const ATR_TRSL_ADDR_UDW = 0x0C;
const ATR_TRSL_PARAM = 0x10;
const ATR_IMPL_ENABLE: u32 = 1 << 0;
const ATR_SIZE_SHIFT = 1;
const ATR_ENTRIES = 8;
/// What an entry translates to: configuration requests, or memory reads
/// and writes.
const TRSL_CONFIG: u32 = 1;
const TRSL_MEMORY: u32 = 0;

/// The configuration space's window: 256 buses.
const config_bytes: u64 = 1 << 28;

/// Whether this is built for the JH7110, whose clocks and pads bringing a
/// port up drives (`sdk.hardware.system`, `gpio`). The library is built
/// for every chip; elsewhere no port is started, and none of that is
/// built.
const on_jh7110 = sdk.hardware.chip == .rv64sbi;

/// The port up as far as PERST#, which is held (`_host.start`). False
/// for a port the chip does not have, or a part that does not say where
/// its registers are.
pub fn start(host: *Host) bool {
    return if (on_jh7110) bringUp(host) else false;
}

fn bringUp(host: *Host) bool {
    if (host.unit >= syscon_block.len or host.registers == 0 or host.config == 0) return false;
    const unit = host.unit;
    const syscon = STG_SYSCON + syscon_block[unit];
    const bridge = host.registers;
    const sys = host.sys;

    if (unit == 0) {
        sys.Disable();
        pcieMode();
        sys.Enable();
    }
    reg(phy_base[unit] + PHY_KVCO_LEVEL).* = KVCO_FINE_TUNE_LEVEL;
    reg(phy_base[unit] + PHY_KVCO_TUNE_SIGNAL).* = KVCO_FINE_TUNE_SIGNALS;

    update(syscon + SYSCON_RP_NEP, K_RP_NEP, K_RP_NEP);
    update(syscon + SYSCON_AW, AW_CKREF_SRC_MASK, AW_CKREF_SRC);
    update(syscon + SYSCON_AW, AW_CLKREQ, AW_CLKREQ);

    sys.Disable();
    system.clockOn(.sys, system.SYSCLK_NOC_BUS_STG_AXI);
    for (0..3) |n| system.clockOn(.stg, stgClock(unit, @intCast(n)));
    for (0..6) |n| system.releaseReset(.stg, stgReset(unit, @intCast(n)));
    sys.Enable();
    for (0..6) |n| _ = system.waitOutOfReset(.stg, stgReset(unit, @intCast(n)));

    holdPerst(host, true);

    // Functions 1 to 3 switched off, each through the AXI side's view of
    // it; then the view back on function 0.
    var function: u32 = 1;
    while (function < 4) : (function += 1) {
        update(syscon + SYSCON_AR, AR_FUNC_MASK, function << AR_FUNC_SHIFT);
        update(syscon + SYSCON_AW, AW_FUNC_MASK, function << AW_FUNC_SHIFT);
        reg(bridge + PCI_MISC).* |= FUNCTION_DIS;
    }
    update(syscon + SYSCON_AR, AR_FUNC_MASK, 0);
    update(syscon + SYSCON_AW, AW_FUNC_MASK, 0);

    reg(bridge + GEN_SETTINGS).* |= RP_ENABLE;
    update(bridge + PCIE_PCI_IDS_DW1, 0xFFFF_FF00, 0x0604 << 16);
    reg(bridge + PMSG_SUPPORT_RX).* &= ~PMSG_LTR_SUPPORT;
    reg(bridge + PCIE_WINROM).* |= PREF_MEM_WIN_64;

    var entry: u32 = 0;
    translate(bridge, entry, host.config, 0, config_bytes, TRSL_CONFIG);
    entry += 1;
    for ([_]Window{ host.windows.mem, host.windows.pref }) |window| {
        if (window.size == 0) continue;
        translate(bridge, entry, window.cpu, window.base, window.size, TRSL_MEMORY);
        entry += 1;
    }
    while (entry < ATR_ENTRIES) : (entry += 1) reg(bridge + ATR_AXI4_SLV0 + entry * ATR_ENTRY + ATR_SRCADDR_PARAM).* = 0;
    reg(bridge + ATR0_PCIE_WIN0_SRCADDR_PARAM).* |= PCIE_WIN0_SIZE;
    reg(bridge + ATR0_PCIE_WIN0_SRC_ADDR).* = 0;

    // The root port's own BARs cleared, through its configuration space.
    reg(host.config + 0x10).* = 0;
    reg(host.config + 0x14).* = 0;

    reg(bridge + IMASK_LOCAL).* = 0;
    reg(bridge + ISTATUS_LOCAL).* = 0xFFFF_FFFF;
    reg(bridge + ISTATUS_MSI).* = 0xFFFF_FFFF;
    host.msi_address = reg(bridge + IMSI_ADDR).*;
    host.msi_count = msi_vectors;
    return true;
}

/// PERST# let go (`_host.release`).
pub fn release(host: *Host) void {
    if (on_jh7110) holdPerst(host, false);
}

/// Whether the port's data link layer is up (`_host.linkUp`).
pub fn linkUp(host: *const Host) bool {
    const syscon = STG_SYSCON + syscon_block[host.unit];
    return reg(syscon + SYSCON_LNKSTA).* & DATA_LINK_ACTIVE != 0;
}

/// AXI slave 0's entry `index`: `bytes` from `axi` on the processor's
/// side to `bus` on the bus's, for `param` (TRSL_*).
fn translate(bridge: usize, index: u32, axi: u64, bus: u64, bytes: u64, param: u32) void {
    const entry = bridge + ATR_AXI4_SLV0 + index * ATR_ENTRY;
    const size_field: u32 = @as(u32, std.math.log2_int_ceil(u64, bytes)) - 1;
    reg(entry + ATR_TRSL_PARAM).* = param;
    reg(entry + ATR_SRCADDR_PARAM).* = (@as(u32, @truncate(axi)) & 0xFFFF_F000) | (size_field << ATR_SIZE_SHIFT) | ATR_IMPL_ENABLE;
    reg(entry + ATR_SRC_ADDR).* = @truncate(axi >> 32);
    reg(entry + ATR_TRSL_ADDR_LSB).* = @truncate(bus);
    reg(entry + ATR_TRSL_ADDR_UDW).* = @truncate(bus >> 32);
}

/// Port 0's PHY given to PCIe, as Linux's PHY driver sets it
/// (phy_pcie_mode_set). Under Disable.
fn pcieMode() void {
    system.update(STG_PHY0_MODE, 0, PHY_MODE_MASK);
    system.update(STG_PHY0_USB, 0, USB3_BUS_WIDTH_MASK | USB3_PHY_ENABLE);
    system.update(SYS_PHY_CONNECT, USB_PDRSTN_SPLIT, 0);
}

/// PERST# held, or let go: the pad driven by the pin controller.
fn holdPerst(host: *const Host, held: bool) void {
    const line = BoardPin.of(host.perst);
    if (line.kind != boardpin.BPIN_GPIO or line.number > gpio.max_pin) return;
    const high = if (line.active_low != 0) !held else held;
    host.sys.Disable();
    gpio.setLevel(line.number, high);
    gpio.outputEnable(line.number, true);
    host.sys.Enable();
}

/// The root port's BAR0 and BAR1.
pub fn hidden(at: Address, offset: u32) bool {
    return at.bus == 0 and at.device == 0 and at.function == 0 and offset >= 0x10 and offset < 0x18;
}

/// The bridge's interrupt hooked, if it is not yet. Under Disable.
fn hook(host: *Host) void {
    if (host.gathering) return;
    host.gathering = true;
    host.gather = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = "pci.library" },
        .data = host,
        .code = @ptrCast(&gather),
    };
    host.sys.AddIntServer(host.irq, &host.gather);
}

/// The bridge's interrupt let go once nothing is on it: no line's
/// server, no vector's. Under Disable.
fn unhookIfIdle(host: *Host) void {
    for (&host.lines) |*line| {
        if (!line.isEmpty()) return;
    }
    if (!vectorsIdle(host)) return;
    if (host.gathering) {
        host.sys.RemIntServer(host.irq, &host.gather);
        host.gathering = false;
    }
}

fn vectorsIdle(host: *Host) bool {
    for (&host.vectors) |*list| {
        if (!list.isEmpty()) return false;
    }
    return true;
}

/// `server` on line `pin` (1 to 4); the bridge's interrupt hooked with
/// the first, and the line let through.
pub fn addServer(host: *Host, pin: u8, server: *exec.Interrupt) void {
    const sys = host.sys;
    sys.Disable();
    defer sys.Enable();
    sys.Enqueue(&host.lines[pin - 1], &server.node);
    hook(host);
    reg(host.registers + IMASK_LOCAL).* |= lineBit(pin);
}

/// `server` off line `pin`; the line masked once it has none, the
/// bridge's interrupt let go once nothing has.
pub fn remServer(host: *Host, pin: u8, server: *exec.Interrupt) void {
    const sys = host.sys;
    sys.Disable();
    defer sys.Enable();
    sys.Remove(&server.node);
    if (host.lines[pin - 1].isEmpty()) reg(host.registers + IMASK_LOCAL).* &= ~lineBit(pin);
    unhookIfIdle(host);
}

/// `server` on vector `vector`; the bridge's interrupt hooked with the
/// first, and the messages let through.
pub fn addVectorServer(host: *Host, vector: u8, server: *exec.Interrupt) void {
    const sys = host.sys;
    sys.Disable();
    defer sys.Enable();
    sys.Enqueue(&host.vectors[vector], &server.node);
    hook(host);
    reg(host.registers + IMASK_LOCAL).* |= MSI_EVENT;
}

/// `server` off the vector it is on; the messages masked once no vector
/// has a server, the bridge's interrupt let go once nothing has.
pub fn remVectorServer(host: *Host, server: *exec.Interrupt) void {
    const sys = host.sys;
    sys.Disable();
    defer sys.Enable();
    sys.Remove(&server.node);
    if (vectorsIdle(host)) reg(host.registers + IMASK_LOCAL).* &= ~MSI_EVENT;
    unhookIfIdle(host);
}

/// Every server off vectors `first` to `first + count - 1`.
pub fn clearVectors(host: *Host, first: u8, count: u16) void {
    const sys = host.sys;
    sys.Disable();
    defer sys.Enable();
    var v: u32 = first;
    while (v < @as(u32, first) + count) : (v += 1) host.vectors[v].init(.interrupt);
    if (vectorsIdle(host)) reg(host.registers + IMASK_LOCAL).* &= ~MSI_EVENT;
    unhookIfIdle(host);
}

fn lineBit(pin: u8) u32 {
    return @as(u32, 1) << @intCast(INTX_SHIFT + pin - 1);
}

/// The bridge's interrupt: what it saw cleared first - a line raised
/// again while its servers run is seen again - then the servers of every
/// line it saw, each line's until one answers; and of every vector that
/// came, each vector's bit cleared before its servers run.
fn gather(data: ?*anyopaque, number: u32) callconv(.c) i32 {
    const host: *Host = @ptrCast(@alignCast(data.?));
    const bridge = host.registers;
    const seen = reg(bridge + ISTATUS_LOCAL).* & reg(bridge + IMASK_LOCAL).* & (INTX_MASK | MSI_EVENT);
    if (seen == 0) return 0;
    reg(bridge + ISTATUS_LOCAL).* = seen;
    if (seen & MSI_EVENT != 0) {
        const came = reg(bridge + ISTATUS_MSI).*;
        for (&host.vectors, 0..) |*list, v| {
            const bit = @as(u32, 1) << @intCast(v);
            if (came & bit == 0) continue;
            reg(bridge + ISTATUS_MSI).* = bit;
            run(list, number);
        }
    }
    for (&host.lines, 0..) |*line, n| {
        if (seen & lineBit(@intCast(n + 1)) != 0) run(line, number);
    }
    return 1;
}

/// A chain's servers, until one answers.
fn run(list: *exec.List, number: u32) void {
    var it = list.iterator();
    while (it.next()) |node| {
        const server: *exec.Interrupt = @fieldParentPtr("node", node);
        const code: exec.IntServerFn = @ptrCast(@alignCast(server.code orelse continue));
        if (code(server.data, number) != 0) break;
    }
}
