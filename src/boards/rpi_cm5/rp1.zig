// SPDX-License-Identifier: MPL-2.0
//! The RP1's interrupts, on the GIC. The RP1 - the CM5's I/O chip, behind
//! the BCM2712's PCI Express port 2 - raises each of its 61 interrupt
//! sources (its UARTs, USB, Ethernet, GPIO banks...) as an MSI-X message:
//! source n as vector n, written to the MIP, the BCM2712's MSI-X
//! Interrupt Peripheral, which raises the GIC's shared interrupt 128 + n
//! on it - interrupt ID 160 + n, taken on its edge. Source n is exec
//! interrupt 160 + n, then (`irq`): a driver adds its server there, as on
//! any of the GIC's, and the GIC's code calls in here (`bridge`) as it
//! switches one on or off, and once its servers have run.
//!
//! **What the bootloader leaves** (`enable_rp1_uart=1`, `pciex4_reset=0`:
//! the RP1 not reset before the kernel starts): the link up, the RP1's
//! BARs placed - BAR1, its peripherals, at 0x1C_0000_0000 through the
//! port's one outbound window, BAR0 with the MSI-X table above it - and
//! its memory decoding and bus mastering on. Not left: the root port's
//! bus numbers, an inbound window to the MIP, MSI-X.
//!
//! **Set up once** (`init`), as Linux's drivers do it (pcie-brcmstb.c,
//! irq-bcm2712-mip.c, rp1.c):
//! 1. the root port's secondary and subordinate bus 1, which the RP1's
//!    configuration space is reached on - through the port's index and
//!    data registers, not ECAM;
//! 2. an inbound window, the port's BAR3: the 4 KiB at 0xFF_FFFF_F000 on
//!    the bus onto the MIP, so that what the RP1 writes there reaches it;
//! 3. the MIP: every vector the processors', none the VPU's, each taken
//!    on its edge;
//! 4. each entry of the RP1's MSI-X table: that address, its own number
//!    as the data; then MSI-X on, INTx off. Each source stays off in the
//!    RP1 until `enable`.
//!
//! **A source** is switched on and off in its MSIX_CFG register in the
//! RP1, as at the GIC. A level-triggered one - all of them but the USB
//! controllers' interrupters, which are edges - sends one message and
//! then waits for an acknowledge (IACK) before it sends another, however
//! long it stays raised: `end` gives it once the source's servers have
//! run, so one still raised then - something came while they ran - sends
//! again. MSIX_CFG has set and clear aliases (at +0x800 and +0xC00):
//! nothing is read and written back, whichever core switches a source.

const hardware = @import("sdk").hardware;
const pci = @import("sdk").pci;
const reg = hardware.mmio.reg;
const boards = @import("../boards.zig");

/// Port 2, the RP1's root port: its own configuration space at the start
/// of its registers, the RP1's through the index and data registers.
const PCIE: usize = 0x10_0012_0000;
const PCIE_MISC_RC_BAR3_CONFIG_LO = 0x403C;
const PCIE_MISC_RC_BAR3_CONFIG_HI = 0x4040;
const PCIE_MISC_UBUS_BAR3_CONFIG_REMAP_LO = 0x40BC;
const PCIE_MISC_UBUS_BAR3_CONFIG_REMAP_HI = 0x40C0;
const PCIE_EXT_CFG_DATA = 0x8000;
const PCIE_EXT_CFG_INDEX = 0x9000;
/// RC_BARn_CONFIG_LO's size for 4 KiB, and a remap's switch.
const IBAR_SIZE_4K: u32 = 0x1C;
const UBUS_REMAP_ACCESS_EN: u32 = 1 << 0;

/// MIP0, whose 64 vectors are the GIC's shared interrupts 128 to 191, and
/// where on the bus it takes messages: its first register, which raises
/// the vector written to it.
const MIP: usize = 0x10_0013_0000;
const MIP_INT_CFGL_HOST = 0x20;
const MIP_INT_CFGH_HOST = 0x30;
const MIP_INT_MASKL_HOST = 0x40;
const MIP_INT_MASKH_HOST = 0x50;
const MIP_INT_MASKL_VPU = 0x60;
const MIP_INT_MASKH_VPU = 0x70;
const mip_on_bus: u64 = 0xFF_FFFF_F000;

/// The RP1, function 0 of bus 1.
const RP1_VENDOR: u32 = 0x1DE4;
const RP1_DEVICE: u32 = 0x0001;
const rp1_function: u32 = 1 << 20;

/// BAR1, the RP1's peripherals, where the bootloader puts it; its PCIe
/// block, with an MSIX_CFG register per source, and their aliases.
pub const peripherals: usize = 0x1C_0000_0000;
const PCIE_APBS: usize = peripherals + 0x10_8000;
const MSIX_CFG = 0x008;
const MSIX_CFG_SET = 0x800;
const MSIX_CFG_CLR = 0xC00;
const MSIX_CFG_ENABLE: u32 = 1 << 0;
const MSIX_CFG_IACK: u32 = 1 << 2;
const MSIX_CFG_IACK_EN: u32 = 1 << 3;

/// Its interrupt sources (Linux's dt-bindings/mfd/rp1.h), those the board
/// names, and the sources taken on their edge: the USB controllers'
/// interrupters, 31 to 34 and 36 to 39.
pub const sources = 61;
pub const INT_ETH = 6;
pub const INT_UART0 = 25;
pub const INT_USBHOST0_0 = 31;
pub const INT_USBHOST1_0 = 36;
const edge_sources: u64 = (0xF << 31) | (0xF << 36);

/// The exec interrupt - the GIC's interrupt ID - source `source` comes
/// on.
pub fn irq(source: u32) u32 {
    return first_irq + source;
}
const first_irq: u32 = 160;

/// What the GIC's code calls (`boards.interrupt_bridge`).
pub const bridge: boards.InterruptBridge = .{
    .first = first_irq,
    .count = sources,
    .init = init,
    .enable = enable,
    .disable = disable,
    .end = end,
};

/// The routing set up, as the top of the file says. Nothing is done
/// unless the RP1 answers as itself, with its MSI-X table where its BARs
/// say.
fn init() void {
    const bus = reg(PCIE + pci.PCI_PRIMARY_BUS);
    bus.* = (bus.* & 0xFF00_0000) | 1 << 16 | 1 << 8;
    const id = config(pci.PCI_VENDOR_ID).*;
    if (id != RP1_DEVICE << 16 | RP1_VENDOR) return;
    const cap = msixCapability() orelse return;
    const table = msixTable(cap) orelse return;

    reg(PCIE + PCIE_MISC_UBUS_BAR3_CONFIG_REMAP_HI).* = @truncate(MIP >> 32);
    reg(PCIE + PCIE_MISC_UBUS_BAR3_CONFIG_REMAP_LO).* = @as(u32, @truncate(MIP)) | UBUS_REMAP_ACCESS_EN;
    reg(PCIE + PCIE_MISC_RC_BAR3_CONFIG_HI).* = @truncate(mip_on_bus >> 32);
    reg(PCIE + PCIE_MISC_RC_BAR3_CONFIG_LO).* = @as(u32, @truncate(mip_on_bus)) | IBAR_SIZE_4K;

    reg(MIP + MIP_INT_MASKL_VPU).* = 0xFFFF_FFFF;
    reg(MIP + MIP_INT_MASKH_VPU).* = 0xFFFF_FFFF;
    reg(MIP + MIP_INT_CFGL_HOST).* = 0xFFFF_FFFF;
    reg(MIP + MIP_INT_CFGH_HOST).* = 0xFFFF_FFFF;
    reg(MIP + MIP_INT_MASKL_HOST).* = 0;
    reg(MIP + MIP_INT_MASKH_HOST).* = 0;

    var source: u32 = 0;
    while (source < sources) : (source += 1) {
        msixCfg(MSIX_CFG_CLR, source).* = MSIX_CFG_ENABLE | MSIX_CFG_IACK_EN;
        const entry = table + source * pci.PCI_MSIX_ENTRY_SIZE;
        reg(entry + 0).* = @truncate(mip_on_bus);
        reg(entry + 4).* = @truncate(mip_on_bus >> 32);
        reg(entry + 8).* = source;
        reg(entry + 12).* = 0;
    }
    const flags = config(cap);
    flags.* = (flags.* | @as(u32, pci.PCI_MSIX_FLAGS_ENABLE) << 16) & ~(@as(u32, pci.PCI_MSIX_FLAGS_MASKALL) << 16);
    // The status register beside it written with nothing to clear.
    const command = config(pci.PCI_COMMAND);
    command.* = (command.* & 0xFFFF) | pci.PCI_COMMAND_MASTER | pci.PCI_COMMAND_INTX_DISABLE;
}

/// Source `irq - first_irq` on, as its kind is; acknowledged once too, so
/// one that sent before and waits is heard again.
fn enable(source_irq: u32) void {
    const source = source_irq - first_irq;
    if (isLevel(source)) {
        msixCfg(MSIX_CFG_SET, source).* = MSIX_CFG_IACK_EN | MSIX_CFG_ENABLE;
        msixCfg(MSIX_CFG_SET, source).* = MSIX_CFG_IACK;
    } else {
        msixCfg(MSIX_CFG_CLR, source).* = MSIX_CFG_IACK_EN;
        msixCfg(MSIX_CFG_SET, source).* = MSIX_CFG_ENABLE;
    }
}

fn disable(source_irq: u32) void {
    msixCfg(MSIX_CFG_CLR, source_irq - first_irq).* = MSIX_CFG_ENABLE;
}

/// Its servers have run: a level-triggered source acknowledged.
fn end(source_irq: u32) void {
    const source = source_irq - first_irq;
    if (isLevel(source)) msixCfg(MSIX_CFG_SET, source).* = MSIX_CFG_IACK;
}

fn isLevel(source: u32) bool {
    return edge_sources & (@as(u64, 1) << @intCast(source)) == 0;
}

/// Source `source`'s MSIX_CFG register, through the alias at `alias`.
fn msixCfg(alias: usize, source: u32) *volatile u32 {
    return reg(PCIE_APBS + alias + MSIX_CFG + 4 * @as(usize, source));
}

/// The RP1's configuration space at `offset`, a word at a time. Only
/// `init` asks it, on the boot core before anything else does.
fn config(offset: u32) *volatile u32 {
    reg(PCIE + PCIE_EXT_CFG_INDEX).* = rp1_function;
    return reg(PCIE + PCIE_EXT_CFG_DATA + offset);
}

/// Where the RP1's MSI-X capability is, if it has one.
fn msixCapability() ?u32 {
    var at = config(pci.PCI_CAPABILITY_LIST).* & 0xFC;
    var steps: u32 = 0;
    while (at != 0 and steps < 48) : (steps += 1) {
        const header = config(at).*;
        if (header & 0xFF == pci.PCI_CAP_ID_MSIX) return at;
        at = (header >> 8) & 0xFC;
    }
    return null;
}

/// Where the processor reaches the MSI-X table: in the BAR the capability
/// names, as far above BAR1 on the bus as above `peripherals` here - the
/// outbound window maps them alike. Null for a 64-bit or I/O BAR, or one
/// below BAR1.
fn msixTable(cap: u32) ?usize {
    const where = config(cap + pci.PCI_MSIX_TABLE).*;
    const bir = where & pci.PCI_MSIX_TABLE_BIR;
    if (bir >= 6) return null;
    const bar = config(pci.PCI_BASE_ADDRESS_0 + 4 * bir).*;
    const bar1 = config(pci.PCI_BASE_ADDRESS_0 + 4).*;
    if (bar & 0x7 != 0 or bar1 & 0x7 != 0) return null;
    const base = bar & 0xFFFF_FFF0;
    const base1 = bar1 & 0xFFFF_FFF0;
    if (base < base1) return null;
    return peripherals + (base - base1) + (where & pci.PCI_MSIX_TABLE_OFFSET);
}
