// SPDX-License-Identifier: MPL-2.0
//! The AXI interconnect between the DSI board's DMAs and the PSRAM they
//! share: the panel's stream put first, and the engine's 2D-DMA held to a
//! rate that leaves the stream enough.
//!
//! A panel's stream cannot wait: a line the bridge does not have in time
//! is an underrun, and after one the panel may stay dark. The engine can:
//! unchecked, a whole-screen fill writes about 140 MB/s with the PSRAM at
//! 80 MHz. Measured there: beside the 480x640 panel's 29 MB/s that starves
//! nothing (162 MB/s in all), beside the 1024x600 panel's 64 MB/s it
//! starves a frame for every two such fills (204 MB/s). At 200 MHz the
//! engine writes 220 MB/s beside that same 64 MB/s stream and starves
//! nothing. So a stream above `held_above` - 40 MB/s at 80 MHz, as much
//! more as the PSRAM is faster - holds the engine to the rate below, about
//! 78 MB/s, where it starves none and still fills twice as fast as the CPU
//! at 80 MHz; the next rate up is the same as none.
//!
//! The interconnect's arbitration is a priority and a read QoS per master
//! (all 0 after reset: the masters take turns). Its regulators are set
//! through a command interface: the value into DATA, then the command -
//! which master, reads or writes, which regulator - with its enable bit,
//! which clears when the regulator has taken it. A regulator's rates are
//! fractions of a transaction a cycle, the highest bit of a field being a
//! half.
//!
//! It keeps no state: every call is register writes at `map.AXI_ICM` and
//! `map.AXI_ICM_QOS`.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const map = sdk.hardware.map;
const systimer = sdk.hardware.systimer;

const mst_arb_priority = map.AXI_ICM + 0x1C;
const mst_arqos = map.AXI_ICM + 0x28;
const qos_cmd = map.AXI_ICM_QOS + 0x08;
const qos_data = map.AXI_ICM_QOS + 0x0C;

/// The DW-GDMA's memory master (its master 1, the interconnect's "GDMA
/// mst2"), in bits 16 to 19 of the priority and the QoS words.
const gdma_memory_shift = 16;
const field_mask: u32 = 0xF;

/// The regulator's masters: the 2D-DMA.
const master_dma2d: u32 = 10;
/// QOS_CMD: the command (0 the burstiness regulator, 1 the rates), reads
/// or writes, the master, a write command, go.
const cmd_burstiness: u32 = 0;
const cmd_rates: u32 = 1;
const cmd_writes: u32 = 1 << 7;
const cmd_master_shift = 8;
const cmd_write: u32 = 1 << 30;
const cmd_go: u32 = 1 << 31;

/// The 2D-DMA's regulator: bursts of up to 16 transactions, the regulator
/// on (or off); a peak of 1/128 of a transaction a cycle and an average of
/// 1/256.
const burstiness: u32 = (16 - 1) << 16;
const regulator_on: u32 = 1;
const rates: u32 = (0x8000_0000 >> 6) + (0x8000 >> 7);

/// A stream above this many bytes a second holds the engine back, with
/// the PSRAM at 80 MHz; a faster PSRAM raises it in proportion.
const held_above_at_80: u64 = 40_000_000;

/// What a stream may take before it holds the engine back, with the PSRAM
/// at `psram_mhz`.
pub fn heldAbove(psram_mhz: u32) u64 {
    return held_above_at_80 * @max(psram_mhz, 80) / 80;
}

/// The panel's stream first; the 2D-DMA held back when the stream takes
/// `stream_bytes` a second beyond what the PSRAM at `psram_mhz` leaves
/// room for, else free to run.
pub fn share(stream_bytes: u64, psram_mhz: u32) void {
    const mask = field_mask << gdma_memory_shift;
    reg(mst_arb_priority).* = (reg(mst_arb_priority).* & ~mask) | mask;
    reg(mst_arqos).* = (reg(mst_arqos).* & ~mask) | mask;
    const held = stream_bytes > heldAbove(psram_mhz);
    for ([_]u32{ 0, cmd_writes }) |direction| {
        command(burstiness | (if (held) regulator_on else 0), cmd_burstiness | direction);
        if (held) command(rates, cmd_rates | direction);
    }
}

/// One regulator command for the 2D-DMA, waited for.
fn command(value: u32, what: u32) void {
    waitIdle();
    reg(qos_data).* = value;
    reg(qos_cmd).* = cmd_go | cmd_write | master_dma2d << cmd_master_shift | what;
    waitIdle();
}

fn waitIdle() void {
    const since = systimer.uptimeUs();
    while (reg(qos_cmd).* & cmd_go != 0) {
        if (systimer.uptimeUs() - since > 1000) return;
    }
}
