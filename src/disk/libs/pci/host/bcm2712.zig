// SPDX-License-Identifier: MIT
//! The BCM2712's PCI Express root ports (CHIP_BCM2712_PCIE): Broadcom's
//! STB bridge, as the Raspberry Pi 5 and the Compute Module 5 have it.
//! Port 1 is the CM5 IO board's M.2 slot, one lane at up to 5 GT/s; port
//! 2 is the RP1's, which the kernel keeps (src/boards/rpi_cm5/rp1.zig)
//! and which no board names here.
//!
//! **Bringing a port up** is done as Linux does it (pcie-brcmstb.c, its
//! bcm2712 configuration), from a port the bootloader has not touched:
//!
//! 1. PERST# held (PCIE_CTRL's PERSTB), then the bridge reset and let go
//!    again - the SoC's reset controller's reset 42 + n for port n;
//! 2. the SerDes powered (HARD_DEBUG's SERDES_IDDQ cleared);
//! 3. the bridge's side towards memory (MISC_CTRL): reads and writes of
//!    memory let through, an unanswered configuration read reading all
//!    ones, bursts of up to 512 bytes, memory controller 0 64 GiB;
//! 4. RAM where it is on the bus: the inbound window RC_BAR1, the 16 GiB
//!    from 0 onto RAM from 0 - the most a CM5 has - so a driver gives a
//!    function the processor's addresses, as on every board here. (Linux
//!    puts RAM at 0x10_0000_0000 on the bus instead.);
//! 5. the root port's class code a PCI-to-PCI bridge's, little-endian
//!    through the inbound window;
//! 6. the outbound windows: window 0 the board's memory window, window 1
//!    its prefetchable one, each from the processor's address to the
//!    bus's, in MiB;
//! 7. what Linux's post-setup does for the BCM2712: the PHY's PLL set up
//!    for the 54 MHz crystal as its reference (over MDIO), the L1
//!    sub-states' clock, reads that fail answered with all ones instead
//!    of an abort, longer timeouts, the QoS fixes of the D0 stepping and
//!    the FIFO's QoS map (the device tree's brcm,fifo-qos-map);
//! 8. CLKREQ# not listened to while the link trains; PERST# let go after
//!    100 ms (`release`), and the link waited for (`linkUp`), both ports'
//!    waits at once (`_host.bringUp`). Once it is up the reference clock
//!    is driven all the time and L1 sub-states are not offered (Linux's
//!    "safe" CLKREQ# mode): nothing here puts a link to sleep.
//!
//! **Configuration space** is not ECAM: the root port's own is at the
//! start of the bridge's registers; a function's is reached by writing
//! its bus, device and function to the index register (EXT_CFG_INDEX) and
//! then going through the 4 KiB data window (EXT_CFG_DATA). The two are
//! one register pair for every caller, so an access is made under
//! Disable. Behind a link that is down nothing is asked - the bridge
//! would abort - and a function that is not there reads all ones.
//!
//! **What the walk does not see**: the root port's BAR0 and BAR1, as on
//! the JH7110.
//!
//! **Interrupts.** INTA to INTD of the functions behind a port are four
//! GIC interrupts of their own, PART_Irq and the three after it, level
//! triggered: a function's line is the one it ends up on at the root
//! port. Message-signalled interrupts are not taken yet: the library
//! offers a function no vectors, and its driver uses its line.

const sdk = @import("sdk");
const exec = sdk.exec;
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

/// Whether this is built for the BCM2712's chip, whose counter the
/// short waits here read. The library is built for every chip; elsewhere
/// no port is started, and none of that is built.
const on_bcm2712 = sdk.hardware.chip == .a64psci;

// --- the SoC's reset controller --------------------------------------------------------

/// brcm,brcmstb-reset: banks of 32 resets, each a set, a clear and a
/// status register. Port n's bridge is reset 42 + n.
const RESET_CONTROLLER: usize = 0x10_0150_4318;
const RESET_BANK = 0x18;
const SW_INIT_SET: usize = 0x00;
const SW_INIT_CLEAR: usize = 0x04;
const first_bridge_reset = 42;

// --- the bridge ------------------------------------------------------------------------

/// The root port's PCI Express capability, and in it the link status.
const BRCM_PCIE_CAP_REGS = 0x00AC;
const PCIE_RC_CFG_VENDOR_SPECIFIC_REG1 = 0x0188;
const ENDIAN_MODE_BAR2_MASK: u32 = 0xC;
const PCIE_RC_CFG_PRIV1_ID_VAL3 = 0x043C;
const CLASS_CODE_MASK: u32 = 0xFF_FFFF;
const PCIE_RC_CFG_PRIV1_ROOT_CAP = 0x04F8;
const ROOT_CAP_L1SS_MODE_MASK: u32 = 0xF8;
const ROOT_CAP_L1SS_MODE_NONE: u32 = 2 << 3;
const PCIE_RC_DL_MDIO_ADDR = 0x1100;
const PCIE_RC_DL_MDIO_WR_DATA = 0x1104;
const PCIE_RC_PL_PHY_CTL_15 = 0x184C;
const PM_CLK_PERIOD_MASK: u32 = 0xFF;
/// 18.52 ns, a 54 MHz clock's period, rounded down.
const PM_CLK_PERIOD_54MHZ: u32 = 0x12;

const PCIE_MISC_MISC_CTRL = 0x4008;
const MISC_CTRL_RCB_64B_MODE: u32 = 1 << 7;
const MISC_CTRL_RCB_MPS_MODE: u32 = 1 << 10;
const MISC_CTRL_SCB_ACCESS_EN: u32 = 1 << 12;
const MISC_CTRL_CFG_READ_UR_MODE: u32 = 1 << 13;
const MISC_CTRL_MAX_BURST_SIZE_MASK: u32 = 3 << 20;
const MISC_CTRL_MAX_BURST_512: u32 = 2 << 20;
const MISC_CTRL_SCB0_SIZE_MASK: u32 = 0x1F << 27;
/// Memory controller 0's size, log2 of it less 15: 64 GiB, as the
/// bootloader leaves port 2.
const MISC_CTRL_SCB0_SIZE_64G: u32 = (36 - 15) << 27;

/// The outbound windows: where on the bus window n starts, and where
/// the processor has it, in MiB - the low 12 bits of base and limit in
/// one register, the bits above in two more.
const PCIE_MISC_CPU_2_PCIE_MEM_WIN0_LO = 0x400C;
const PCIE_MISC_CPU_2_PCIE_MEM_WIN0_HI = 0x4010;
const PCIE_MISC_CPU_2_PCIE_MEM_WIN0_BASE_LIMIT = 0x4070;
const PCIE_MISC_CPU_2_PCIE_MEM_WIN0_BASE_HI = 0x4080;
const PCIE_MISC_CPU_2_PCIE_MEM_WIN0_LIMIT_HI = 0x4084;

/// The inbound window onto RAM, and its remap, as on port 2.
const PCIE_MISC_RC_BAR1_CONFIG_LO = 0x402C;
const PCIE_MISC_UBUS_BAR1_CONFIG_REMAP_LO = 0x40AC;
const IBAR_SIZE_16G: u32 = 34 - 15;
const UBUS_REMAP_ACCESS_EN: u32 = 1 << 0;

const PCIE_MISC_RC_CONFIG_RETRY_TIMEOUT = 0x405C;
const PCIE_MISC_PCIE_CTRL = 0x4064;
const PCIE_CTRL_PERSTB: u32 = 1 << 2;
const PCIE_MISC_PCIE_STATUS = 0x4068;
const STATUS_PHYLINKUP: u32 = 1 << 4;
const STATUS_DL_ACTIVE: u32 = 1 << 5;
const PCIE_MISC_CTRL_1 = 0x40A0;
const CTRL_1_EN_VDM_QOS_CONTROL: u32 = 1 << 5;
const PCIE_MISC_UBUS_CTRL = 0x40A4;
const UBUS_PCIE_REPLY_ERR_DIS: u32 = 1 << 13;
const UBUS_PCIE_REPLY_DECERR_DIS: u32 = 1 << 19;
const PCIE_MISC_UBUS_TIMEOUT = 0x40A8;
/// The traffic classes' QoS maps, eight of them downwards from here.
const PCIE_MISC_TC_QUEUE_TO_QOS_MAP0 = 0x4160;
const PCIE_MISC_AXI_INTF_CTRL = 0x416C;
const AXI_REQFIFO_EN_QOS_PROPAGATION: u32 = 1 << 7;
const AXI_DIS_QOS_GATING_IN_MASTER: u32 = 1 << 11;
const AXI_EN_QOS_UPDATE_TIMING_FIX: u32 = 1 << 12;
const AXI_EN_RCLK_QOS_ARRAY_FIX: u32 = 1 << 13;
const AXI_MASTER_MAX_OUTSTANDING_REQUESTS_MASK: u32 = 0x3F;
const PCIE_MISC_AXI_READ_ERROR_DATA = 0x4170;

const HARD_DEBUG = 0x4304;
const HARD_DEBUG_CLKREQ_DEBUG_ENABLE: u32 = 1 << 1;
const HARD_DEBUG_REFCLK_OVRD_ENABLE: u32 = 1 << 16;
const HARD_DEBUG_REFCLK_OVRD_OUT: u32 = 1 << 20;
const HARD_DEBUG_L1SS_ENABLE: u32 = 1 << 21;
const HARD_DEBUG_SERDES_IDDQ: u32 = 1 << 27;
const HARD_DEBUG_CLKREQ_MASK = HARD_DEBUG_CLKREQ_DEBUG_ENABLE | HARD_DEBUG_REFCLK_OVRD_ENABLE |
    HARD_DEBUG_REFCLK_OVRD_OUT | HARD_DEBUG_L1SS_ENABLE;

const EXT_CFG_DATA = 0x8000;
const EXT_CFG_INDEX = 0x9000;

/// The PHY's registers over MDIO: a write's packet, and the PLL's
/// settings for a 54 MHz reference, block 0x1600 on.
const MDIO_DATA_DONE: u32 = 1 << 31;
const MDIO_SET_ADDR = 0x1F;
const pll_block: u16 = 0x1600;
const pll_registers = [_]u8{ 0x16, 0x17, 0x18, 0x19, 0x1B, 0x1C, 0x1E };
const pll_values = [_]u16{ 0x50B9, 0xBDA1, 0x0094, 0x97B4, 0x5030, 0x5030, 0x0007 };

/// The device tree's brcm,fifo-qos-map for port 1: QoS 3 at each quartile
/// of the FIFO's level, the same for every traffic class.
const fifo_qos_map: u32 = 0x3333;

/// The port up as far as PERST#, which is held (`_host.start`). False
/// for a port the chip does not have, port 2 - the RP1's, the kernel's -
/// or a part that does not say where its registers are.
pub fn start(host: *Host) bool {
    return if (on_bcm2712) bringUp(host) else false;
}

fn bringUp(host: *Host) bool {
    if (host.unit > 1 or host.registers == 0) return false;
    const r = host.registers;

    // Nothing of the bridge's is touched while it is held: on a CM5 the
    // processor stopped for good at a read of PCIE_CTRL then.
    update(r + PCIE_MISC_PCIE_CTRL, PCIE_CTRL_PERSTB, 0);
    holdBridge(host.unit, true);
    wait(200);
    holdBridge(host.unit, false);
    update(r + HARD_DEBUG, HARD_DEBUG_SERDES_IDDQ, 0);
    wait(200);

    update(r + PCIE_MISC_MISC_CTRL, MISC_CTRL_RCB_64B_MODE | MISC_CTRL_RCB_MPS_MODE | MISC_CTRL_SCB_ACCESS_EN |
        MISC_CTRL_CFG_READ_UR_MODE | MISC_CTRL_MAX_BURST_SIZE_MASK | MISC_CTRL_SCB0_SIZE_MASK, MISC_CTRL_RCB_64B_MODE |
        MISC_CTRL_RCB_MPS_MODE | MISC_CTRL_SCB_ACCESS_EN | MISC_CTRL_CFG_READ_UR_MODE | MISC_CTRL_MAX_BURST_512 |
        MISC_CTRL_SCB0_SIZE_64G);
    reg(r + PCIE_MISC_UBUS_BAR1_CONFIG_REMAP_LO + 4).* = 0;
    reg(r + PCIE_MISC_UBUS_BAR1_CONFIG_REMAP_LO).* = UBUS_REMAP_ACCESS_EN;
    reg(r + PCIE_MISC_RC_BAR1_CONFIG_LO + 4).* = 0;
    reg(r + PCIE_MISC_RC_BAR1_CONFIG_LO).* = IBAR_SIZE_16G;

    update(r + PCIE_RC_CFG_PRIV1_ID_VAL3, CLASS_CODE_MASK, 0x06_0400);
    update(r + PCIE_RC_CFG_VENDOR_SPECIFIC_REG1, ENDIAN_MODE_BAR2_MASK, 0);
    var window: u32 = 0;
    for ([_]Window{ host.windows.mem, host.windows.pref }) |w| {
        if (w.size == 0) continue;
        outbound(r, window, w);
        window += 1;
    }

    if (!postSetup(r)) return false;
    update(r + HARD_DEBUG, HARD_DEBUG_CLKREQ_MASK, 0);
    return true;
}

/// What Linux's brcm_pcie_post_setup_bcm2712 does (step 7 at the top).
fn postSetup(r: usize) bool {
    if (!mdioWrite(r, MDIO_SET_ADDR, pll_block)) return false;
    for (pll_registers, pll_values) |at, value| {
        if (!mdioWrite(r, at, value)) return false;
    }
    wait(200);
    update(r + PCIE_RC_PL_PHY_CTL_15, PM_CLK_PERIOD_MASK, PM_CLK_PERIOD_54MHZ);
    reg(r + PCIE_MISC_UBUS_CTRL).* |= UBUS_PCIE_REPLY_ERR_DIS | UBUS_PCIE_REPLY_DECERR_DIS;
    reg(r + PCIE_MISC_AXI_READ_ERROR_DATA).* = 0xFFFF_FFFF;
    // 250 ms and about 240 ms, in clocks of 750 MHz.
    reg(r + PCIE_MISC_UBUS_TIMEOUT).* = 0x0B2D_0000;
    reg(r + PCIE_MISC_RC_CONFIG_RETRY_TIMEOUT).* = 0x0ABA_0000;
    const axi = r + PCIE_MISC_AXI_INTF_CTRL;
    reg(axi).* = (reg(axi).* & ~AXI_REQFIFO_EN_QOS_PROPAGATION) | AXI_EN_RCLK_QOS_ARRAY_FIX |
        AXI_EN_QOS_UPDATE_TIMING_FIX | AXI_DIS_QOS_GATING_IN_MASTER;
    // A chip whose timing fix does not stick throttles what it has in
    // flight to memory instead.
    if (reg(axi).* & AXI_EN_QOS_UPDATE_TIMING_FIX == 0) update(axi, AXI_MASTER_MAX_OUTSTANDING_REQUESTS_MASK, 15);
    reg(r + PCIE_MISC_CTRL_1).* &= ~CTRL_1_EN_VDM_QOS_CONTROL;
    var class: usize = 0;
    while (class < 8) : (class += 1) reg(r + PCIE_MISC_TC_QUEUE_TO_QOS_MAP0 - 4 * class).* = fifo_qos_map;
    return true;
}

/// PERST# let go (`_host.release`).
pub fn release(host: *Host) void {
    if (on_bcm2712) update(host.registers + PCIE_MISC_PCIE_CTRL, PCIE_CTRL_PERSTB, PCIE_CTRL_PERSTB);
}

/// Whether the link is up, its PHY and its data link layer
/// (`_host.linkUp`). Once it is, the reference clock is driven for good
/// and L1 sub-states are not offered.
pub fn linkUp(host: *const Host) bool {
    const r = host.registers;
    const both = STATUS_PHYLINKUP | STATUS_DL_ACTIVE;
    if (reg(r + PCIE_MISC_PCIE_STATUS).* & both != both) return false;
    update(r + HARD_DEBUG, HARD_DEBUG_CLKREQ_MASK, HARD_DEBUG_REFCLK_OVRD_OUT | HARD_DEBUG_REFCLK_OVRD_ENABLE);
    update(r + PCIE_RC_CFG_PRIV1_ROOT_CAP, ROOT_CAP_L1SS_MODE_MASK, ROOT_CAP_L1SS_MODE_NONE);
    return true;
}

/// Port `unit`'s bridge held in reset, or let go.
fn holdBridge(unit: u32, held: bool) void {
    const reset = first_bridge_reset + unit;
    const bank = RESET_CONTROLLER + (reset / 32) * RESET_BANK;
    reg(bank + if (held) SW_INIT_SET else SW_INIT_CLEAR).* = @as(u32, 1) << @intCast(reset % 32);
}

/// Outbound window `index`: `window.size` bytes from `window.cpu` on the
/// processor's side to `window.base` on the bus.
fn outbound(r: usize, index: u32, window: Window) void {
    const base_mb = window.cpu >> 20;
    const limit_mb = (window.cpu + window.size - 1) >> 20;
    reg(r + PCIE_MISC_CPU_2_PCIE_MEM_WIN0_LO + 8 * index).* = @truncate(window.base);
    reg(r + PCIE_MISC_CPU_2_PCIE_MEM_WIN0_HI + 8 * index).* = @truncate(window.base >> 32);
    reg(r + PCIE_MISC_CPU_2_PCIE_MEM_WIN0_BASE_LIMIT + 4 * index).* =
        @as(u32, @truncate(limit_mb & 0xFFF)) << 20 | @as(u32, @truncate(base_mb & 0xFFF)) << 4;
    update(r + PCIE_MISC_CPU_2_PCIE_MEM_WIN0_BASE_HI + 8 * index, 0xFF, @truncate(base_mb >> 12));
    update(r + PCIE_MISC_CPU_2_PCIE_MEM_WIN0_LIMIT_HI + 8 * index, 0xFF, @truncate(limit_mb >> 12));
}

/// One of the PHY's registers written over MDIO, port 0: false if the PHY
/// did not take it within 100 µs.
fn mdioWrite(r: usize, at: u8, value: u16) bool {
    reg(r + PCIE_RC_DL_MDIO_ADDR).* = at;
    _ = reg(r + PCIE_RC_DL_MDIO_ADDR).*;
    reg(r + PCIE_RC_DL_MDIO_WR_DATA).* = MDIO_DATA_DONE | value;
    var waited: u32 = 0;
    while (reg(r + PCIE_RC_DL_MDIO_WR_DATA).* & MDIO_DATA_DONE != 0) : (waited += 10) {
        if (waited >= 100) return false;
        wait(10);
    }
    return true;
}

/// `us` microseconds, on the system counter: the waits while a port is
/// set up are too short for timer.device. Only `bringUp`'s, so only built
/// for the BCM2712.
fn wait(us: u64) void {
    const cpu = sdk.hardware.cpu;
    const ticks = cpu.counterFrequency() * us / 1_000_000;
    const from = cpu.time();
    while (cpu.time() -% from < ticks) {}
}

// --- configuration space ---------------------------------------------------------------

/// `size` bytes of a function's configuration space at `offset`; all
/// ones for one there is none of.
pub fn read(host: *Host, at: Address, offset: u32, size: u32) u32 {
    const sys = host.sys;
    sys.Disable();
    defer sys.Enable();
    const address = configAddress(host, at, offset) orelse return @as(u32, 0xFFFF_FFFF) >> @intCast(32 - 8 * size);
    return switch (size) {
        1 => @as(*volatile u8, @ptrFromInt(address)).*,
        2 => @as(*volatile u16, @ptrFromInt(address)).*,
        else => @as(*volatile u32, @ptrFromInt(address)).*,
    };
}

/// `size` bytes of `value` into a function's configuration space at
/// `offset`.
pub fn write(host: *Host, at: Address, offset: u32, size: u32, value: u32) void {
    const sys = host.sys;
    sys.Disable();
    defer sys.Enable();
    const address = configAddress(host, at, offset) orelse return;
    switch (size) {
        1 => @as(*volatile u8, @ptrFromInt(address)).* = @truncate(value),
        2 => @as(*volatile u16, @ptrFromInt(address)).* = @truncate(value),
        else => @as(*volatile u32, @ptrFromInt(address)).* = value,
    }
}

/// Where `offset` of a function's configuration space is: the root
/// port's in the bridge's registers, nothing else on its bus; a
/// function behind it through the data window, once the index names it.
/// Under Disable.
fn configAddress(host: *Host, at: Address, offset: u32) ?usize {
    const r = host.registers;
    if (at.bus == 0) return if (at.device == 0 and at.function == 0) r + (offset & 0xFFF) else null;
    reg(r + EXT_CFG_INDEX).* = @as(u32, at.bus) << 20 | @as(u32, at.device) << 15 | @as(u32, at.function) << 12;
    return r + EXT_CFG_DATA + (offset & 0xFFF);
}

/// The root port's BAR0 and BAR1.
pub fn hidden(at: Address, offset: u32) bool {
    return at.bus == 0 and at.device == 0 and at.function == 0 and offset >= 0x10 and offset < 0x18;
}
