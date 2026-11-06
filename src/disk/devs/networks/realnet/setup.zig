// SPDX-License-Identifier: MIT
//! Bringing the controller up, for realnet.device. Two sequences, both
//! of them writes to the registers in `mac.zig`:
//!
//! - `chip`, once, when the device claims the function: the part taken
//!   away from whatever was driving it before the machine started, its
//!   PHY given its power, the patch area of its on-chip processor
//!   cleared, and the link told to report its uncorrectable errors.
//! - `bringUp`, every time the unit is told to run: the settings the
//!   part wants before it receives and sends - its buffers, its
//!   thresholds, its power saving, its descriptor fetching - and then
//!   the gate in front of the receive path opened.
//!
//! The order matters as much as the values: most of these registers
//! take a write only while the configuration lock is open, and the part
//! wants its receive path gated shut until everything else is set.
//!
//! **No microcode is loaded.** The part has an on-chip processor whose
//! patch area a driver may fill with a block the maker supplies; this
//! device clears that area and loads nothing, so the part runs the code
//! it came up with. Everything here is register settings.

const mac = @import("mac.zig");
const Part = mac.Part;

/// What the part is set up for once, before it is ever started. False
/// where it does not come out of its reset.
pub fn chip(at: usize, part: *const Part) bool {
    if (!mac.exitOob(at)) return false;
    mac.phyPowerOn(at);
    hardware(at, part);
    mac.disableCauses(at);
    clearTimers(at);
    return mac.reset(at);
}

/// The settings that outlive a reset: the part's power saving, its
/// on-chip processor's patch area, and the link's error reporting.
fn hardware(at: usize, part: *const Part) void {
    mac.unlock(at);
    mac.clear8(at, mac.cfg5, mac.cfg5_pme_sts);
    mac.clear8(at, mac.cfg2, mac.cfg2_clkreq_en);
    mac.lock(at);
    mac.clear8(at, 0xf1, 0x80);

    // The part's own power saving, which would take the link down under
    // it while nothing is being sent.
    mac.macOcpClear(at, 0xd40a, 0x0010);

    // The patch area of the on-chip processor cleared, and the entry
    // that would run it. Nothing is written in its place.
    mac.macOcpWrite(at, 0xfc38, 0);
    var address: u16 = 0xfc28;
    while (address < 0xfc38) : (address += 2) mac.macOcpWrite(at, address, 0);
    mac.wait(at, 3000);
    mac.macOcpWrite(at, 0xfc26, 0);

    if (part.first) phyPowerSave(at);

    // The link's uncorrectable errors reported, so that a fault on it is
    // one the machine can see rather than a frame that never arrives.
    mac.csiWrite(at, 0x108, mac.csiRead(at, 0x108) | 0x0010_0000);
}

/// The PHY's own power saving turned off, which the first of these
/// parts needs its patching window open for.
fn phyPowerSave(at: usize) void {
    if (mac.phyOcpRead(at, 0xc416) == 0x0500) return;
    patchWindow(at, true);
    mac.phyOcpWrite(at, 0xc416, 0);
    mac.phyOcpWrite(at, 0xc416, 0x0500);
    patchWindow(at, false);
}

/// The window in which the PHY's registers may be patched, opened or
/// closed, and waited for: the PHY answers in a register of its own.
fn patchWindow(at: usize, open: bool) void {
    if (open) mac.phyOcpSet(at, 0xb820, 0x0010) else mac.phyOcpClear(at, 0xb820, 0x0010);
    var left: u32 = 1000;
    while (left > 0) : (left -= 1) {
        const ready = mac.phyOcpRead(at, 0xb800) & 0x0040 != 0;
        if (ready == open) return;
        mac.wait(at, 100);
    }
}

/// Every timer that would raise an interrupt of its own, stopped: each
/// frame raises its own cause here, and nothing is held back for a
/// timer to release.
fn clearTimers(at: usize) void {
    mac.write32(at, mac.timerint0, 0);
    mac.write32(at, mac.timerint1, 0);
    mac.write32(at, mac.timerint2, 0);
    mac.write32(at, mac.timerint3, 0);
    mac.write32(at, mac.timercnt, 0);
}

/// The part set up to receive and send, with its rings already written:
/// everything that has to be in place before the receive path's gate is
/// opened. It does not start the part - the caller does that, once the
/// filter is written.
pub fn bringUp(at: usize, part: *const Part) void {
    mac.unlock(at);
    mac.clear8(at, 0xf1, 0x80);
    mac.clear8(at, mac.cfg2, mac.cfg2_clkreq_en);
    mac.clear8(at, mac.cfg5, mac.cfg5_pme_sts);
    mac.clear8(at, mac.cfg3, mac.cfg3_rdy_to_l23);

    // Every moderation timer at zero: a frame is not held back.
    var slot: usize = 0;
    while (slot < 64) : (slot += 1) mac.write32(at, mac.intmiti + slot * 4, 0);

    mac.write32(at, mac.rxcfg, part.receiving);
    mac.write32(at, mac.txcfg, mac.txcfg_config);

    // How long the link's own buffer may hold a packet before it is
    // handed on, and the part's hardware optimisation.
    mac.csiWrite(at, 0x70c, (mac.csiRead(at, 0x70c) & ~@as(u32, 0xff00_0000)) | 0x2700_0000);
    mac.write16(at, 0x0382, 0x221b);

    // One ring for everything that comes in: no spreading over queues,
    // and the queue count field left at one queue.
    mac.write8(at, mac.rss_ctrl, 0);
    mac.clear16(at, mac.rxqueue_ctrl, 0x001c);

    // The part would drop the link to a slower speed by itself while
    // nothing is being sent.
    mac.clear8(at, mac.cfg1, mac.cfg1_speed_down);

    mac.macOcpWrite(at, 0xc140, 0xffff);
    mac.macOcpWrite(at, 0xc142, 0xffff);
    mac.macOcpSet(at, 0xeb58, 0x0001);

    mac.macOcpModify(at, 0xe614, 0x0700, part.fifo);
    mac.macOcpModify(at, 0xe63e, 0x0c00, 0);
    mac.macOcpClear(at, 0xe63e, 0x0030);
    if (part.first) mac.macOcpSet(at, 0xe63e, 0x0020);

    mac.macOcpClear(at, 0xc0b4, 0x0001);
    mac.macOcpSet(at, 0xc0b4, 0x0001);
    mac.macOcpSet(at, 0xc0b4, 0x000c);

    mac.macOcpModify(at, 0xeb6a, 0x00ff, 0x0033);
    mac.macOcpModify(at, 0xeb50, 0x03e0, 0x0040);
    mac.macOcpModify(at, 0xe056, 0x00f0, 0x0030);

    // How many descriptors the part fetches at a time.
    mac.write8(at, mac.tdfnr, 0x10);
    mac.set8(at, mac.dllpr, mac.dllpr_tx_10m_ps_en);

    mac.macOcpClear(at, 0xe040, 0x1000);
    mac.macOcpModify(at, 0xea1c, 0x0003, 0x0001);
    mac.macOcpModify(at, 0xe0c0, 0x4f0f, 0x4403);
    mac.macOcpSet(at, 0xe052, 0x0068);
    mac.macOcpClear(at, 0xe052, 0x0080);
    mac.macOcpModify(at, 0xd430, 0x0fff, 0x047f);

    mac.set8(at, mac.dllpr, mac.dllpr_pfm_en | mac.dllpr_tx_10m_ps_en);
    if (part.first) mac.set8(at, mac.mcucmd, 0x01);

    // The energy-efficient idling the part would do between frames,
    // which costs the first frame after an idle its latency.
    mac.macOcpClear(at, 0xe080, 0x0002);
    mac.macOcpClear(at, 0xea1c, 0x0004);

    // The table the part matches frames against, emptied.
    mac.macOcpSet(at, 0xeb54, 0x0001);
    mac.wait(at, 1);
    mac.macOcpClear(at, 0xeb54, 0x0001);

    mac.clear32(at, 0x1880, 0x0030);
    mac.macOcpWrite(at, 0xe098, 0xc302);

    // What the part checks for itself on the way in. What it found is in
    // the descriptor, and a frame that came through with every checksum
    // right is answered as checked.
    mac.set16(at, mac.cpluscmd, mac.cpluscmd_rxcsum);

    // The part is still settling from the writes above; it says so in a
    // register of its own.
    var left: u32 = 10;
    while (left > 0) : (left -= 1) {
        if (mac.macOcpRead(at, 0xe00e) & 0x2000 == 0) break;
        mac.wait(at, 1000);
    }

    // The gate in front of the receive path opened, which is the last
    // thing: from here the part would take frames in.
    mac.clear8(at, mac.ppsw, mac.ppsw_rxdv_gate);
    mac.wait(at, 2000);
}

/// The configuration lock closed again, which the two writes that want
/// it open are done under.
pub fn settled(at: usize) void {
    mac.clear8(at, mac.cfg2, mac.cfg2_clkreq_en);
    mac.clear8(at, mac.cfg5, mac.cfg5_pme_sts);
    mac.lock(at);
}
