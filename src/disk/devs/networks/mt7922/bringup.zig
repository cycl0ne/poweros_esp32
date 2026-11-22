// SPDX-License-Identifier: MIT
//! The card brought up to a radio that can scan: who holds the chip,
//! what it is, its Wi-Fi part reset, the DMA engine on its rings, the
//! firmware loaded, what the firmware says the card has, and the station
//! made (station.zig).
//!
//! **Who holds the chip.** The chip's power is either the firmware's or
//! the driver's. It is handed to the firmware and taken back once, so
//! that whatever state the machine's start left it in, the driver holds
//! it after; it is then asked for again from the chip's side before the
//! download. A chip whose firmware still runs in the driver's hold - the
//! machine restarted over it - is not handed over: it needs no hand-over,
//! and power handed to a firmware that is then reset may never come back,
//! short of taking the machine's power away. Nothing here hands it over
//! when it stops, for the same reason.
//!
//! **The order** is the chip's: the reset before the rings, the rings
//! before the first command, the firmware before anything the running
//! firmware answers. Every wait is a register read every millisecond up
//! to a limit; nothing here takes an interrupt.
//!
//! **A start that fails is tried again** from the Wi-Fi part's reset, up
//! to `attempts` times, the chip's state written to the log each time: a
//! chip a firmware ran on before - the machine's start, an earlier load
//! of this device - may not take the first. Each failed attempt costs a
//! few seconds the opener waits, which is what keeps the count low.
//! A processor that keeps the chip's power is not reached by the
//! machine's restart, nor by a reset of the PCI function: the card is
//! then refused, and the machine has to be switched off and on.
//!
//! **Left quiet**, the chip is as a reset leaves it: the driver still
//! holds it, the engine is stopped and the Wi-Fi part reset, so the next
//! start finds the boot ROM waiting for its patch.

const sdk = @import("sdk");
const _mt = @import("_mt7922.zig");
const regs_file = @import("regs.zig");
const dma = @import("dma.zig");
const mcu = @import("mcu.zig");
const firmware = @import("firmware.zig");
const station = @import("station.zig");
const Work = _mt.Work;
const say = _mt.say;

pub const Error = error{ NotOwned, NoChip, NoReset, DmaBusy, NoCapability } || firmware.Error || station.Error;

/// How often a hand-over of the chip's power is asked for before it is
/// given up.
const own_tries = 10;

pub fn bringUp(work: *Work) Error!void {
    const sys = work.sys;
    const regs = work.regs;
    const own = regs.rd(regs_file.CONN_ON_LPCTL);
    const state = regs.rd(regs_file.CONN_ON_MISC);
    const held = own & regs_file.LPCTL_OWN_SYNC == 0 and state & regs_file.MISC_FW_N9_RDY == regs_file.MISC_FW_N9_RDY;
    if (!held) handOver(work) catch |failure| {
        say(sys, "the chip does not hand over its power: switch the machine off and on", .{});
        report(work);
        return failure;
    };
    work.chip = regs.rdFar(regs_file.HW_CHIPID) & 0xffff;
    work.revision = regs.rdFar(regs_file.HW_REV) & 0xff;
    if (work.chip != _mt.CHIP_MT7922) {
        say(sys, "the chip says it is a %x, not an MT7922", .{work.chip});
        return error.NoChip;
    }
    regs.wr(regs_file.HOST_INT_ENA, 0);
    regs.wr(regs_file.PCIE_MAC_INT_ENABLE, 0xff);
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        if (start(work)) |_| return else |failure| {
            say(sys, "attempt %u: %s", .{ attempt, @as([*:0]const u8, @errorName(failure)) });
            report(work);
            if (attempt == attempts) return failure;
        }
    }
}

const attempts = 2;

/// One start from the Wi-Fi part's reset to a radio ready to scan.
fn start(work: *Work) Error!void {
    const regs = work.regs;
    try resetWifi(work);
    try rings(work);
    regs.wr(regs_file.SWDEF_MODE, 0);
    try driverOwn(work);
    regs.set(regs_file.PCIE_MAC_PM, regs_file.PCIE_L0S_DIS);
    try firmware.load(work);
    try capability(work);
    try station.setUp(work);
}

/// The chip's state in the log: who holds it, what its firmware says,
/// the engine, and where the command and event rings stand.
fn report(work: *Work) void {
    const regs = work.regs;
    say(work.sys, "  own %x, firmware state %x, host own %x, reset %x, engine %x, causes %x", .{
        regs.rd(regs_file.CONN_ON_LPCTL),          regs.rd(regs_file.CONN_ON_MISC),
        regs.rdFar(regs_file.TOP_LPCR_HOST_BAND0), regs.rdFar(regs_file.WFSYS_SW_RST),
        regs.rd(regs_file.GLO_CFG),                regs.rd(regs_file.HOST_INT_STA),
    });
    say(work.sys, "  commands %u/%u, firmware %u/%u, events %u/%u and %u/%u (cpu/dma)", .{
        regs.rd(work.tx_wm.at + regs_file.RING_CPU_IDX),   regs.rd(work.tx_wm.at + regs_file.RING_DMA_IDX),
        regs.rd(work.tx_fwdl.at + regs_file.RING_CPU_IDX), regs.rd(work.tx_fwdl.at + regs_file.RING_DMA_IDX),
        regs.rd(work.rx_wm.at + regs_file.RING_CPU_IDX),   regs.rd(work.rx_wm.at + regs_file.RING_DMA_IDX),
        regs.rd(work.rx_wm2.at + regs_file.RING_CPU_IDX),  regs.rd(work.rx_wm2.at + regs_file.RING_DMA_IDX),
    });
}

/// The chip's power handed to the firmware, then taken back.
fn handOver(work: *Work) Error!void {
    const regs = work.regs;
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        if (tries == own_tries) return error.NotOwned;
        regs.wr(regs_file.CONN_ON_LPCTL, regs_file.LPCTL_SET_OWN);
        if (work.poll(regs_file.CONN_ON_LPCTL, regs_file.LPCTL_OWN_SYNC, regs_file.LPCTL_OWN_SYNC, 50)) break;
    }
    tries = 0;
    while (true) : (tries += 1) {
        if (tries == own_tries) return error.NotOwned;
        regs.wr(regs_file.CONN_ON_LPCTL, regs_file.LPCTL_CLR_OWN);
        if (work.poll(regs_file.CONN_ON_LPCTL, regs_file.LPCTL_OWN_SYNC, 0, 50)) break;
    }
}

/// The driver's hold asked for from the chip's side, until the firmware
/// lets go.
fn driverOwn(work: *Work) Error!void {
    work.regs.wrFar(regs_file.TOP_LPCR_HOST_BAND0, regs_file.LPCR_DRV_OWN);
    if (!work.pollFar(regs_file.TOP_LPCR_HOST_BAND0, regs_file.LPCR_FW_OWN, 0, 500)) {
        say(work.sys, "the firmware does not let go of the chip", .{});
        return error.NotOwned;
    }
}

/// The Wi-Fi part held in reset, let go, and waited for.
fn resetWifi(work: *Work) Error!void {
    const regs = work.regs;
    regs.rmwFar(regs_file.WFSYS_SW_RST, regs_file.WFSYS_RST_B, 0);
    work.pause(50_000);
    regs.rmwFar(regs_file.WFSYS_SW_RST, 0, regs_file.WFSYS_RST_B);
    if (!work.pollFar(regs_file.WFSYS_SW_RST, regs_file.WFSYS_INIT_DONE, regs_file.WFSYS_INIT_DONE, 500)) {
        say(work.sys, "the Wi-Fi part does not come out of reset", .{});
        return error.NoReset;
    }
}

/// The engine stopped, every ring told to it - the receiving ones given
/// their buffers - and started, its interrupts on.
fn rings(work: *Work) Error!void {
    const regs = work.regs;
    if (!dma.stop(work)) {
        say(work.sys, "the DMA engine does not stop", .{});
        return error.DmaBusy;
    }
    for ([_]*dma.Ring{ &work.tx_data, &work.tx_wm, &work.tx_fwdl, &work.rx_wm, &work.rx_wm2, &work.rx_data }) |ring| ring.reset(regs);
    regs.wr(regs_file.TX_RING0_EXT_CTRL, 0x4);
    for ([_]*dma.Ring{ &work.rx_wm, &work.rx_wm2, &work.rx_data }) |ring| ring.arm(regs);
    dma.start(regs);
    work.int_enabled = regs_file.INT_WANTED;
    regs.wr(regs_file.HOST_INT_ENA, work.int_enabled);
    regs.set(regs_file.MCU2HOST_SW_INT_ENA, regs_file.MCU_CMD_WAKE_RX_PCIE);
}

/// What the firmware says the card has: its address, its bands, its
/// streams.
fn capability(work: *Work) Error!void {
    const answer = (mcu.send(work, mcu.ce(mcu.CE_GET_NIC_CAPAB), &.{}, true) catch return error.NoCapability).?;
    const payload = answer.payload();
    if (payload.len < 4) return error.NoCapability;
    const count = mcu.get16(payload, 0);
    var at: usize = 4;
    for (0..count) |_| {
        if (at + 8 > payload.len) break;
        const kind = mcu.get32(payload, at);
        const length = mcu.get32(payload, at + 4);
        at += 8;
        if (at + length > payload.len) break;
        const data = payload[at .. at + length];
        at += length;
        switch (kind) {
            nic_cap_mac_addr => if (data.len >= 6) {
                work.station = data[0..6].*;
            },
            nic_cap_phy => if (data.len >= 12) {
                work.has_5g = data[10] & 0x2 != 0;
                work.streams = data[4];
            },
            nic_cap_6g => if (data.len >= 1) {
                work.has_6g = data[0] != 0;
            },
            else => {},
        }
    }
    for (work.station) |byte| {
        if (byte != 0) return;
    }
    return error.NoCapability;
}

const nic_cap_mac_addr = 0x07;
const nic_cap_phy = 0x08;
const nic_cap_6g = 0x18;

/// The chip left quiet: no interrupts, the engine stopped, the Wi-Fi part
/// reset.
pub fn quiet(work: *Work) void {
    const regs = work.regs;
    regs.wr(regs_file.HOST_INT_ENA, 0);
    regs.wr(regs_file.PCIE_MAC_INT_ENABLE, 0);
    _ = regs.rd(regs_file.PCIE_MAC_INT_ENABLE);
    work.int_enabled = 0;
    _ = dma.stop(work);
    resetWifi(work) catch {};
}
