// SPDX-License-Identifier: MPL-2.0
//! The BCM2712's way to its first HDMI port (CHIP_BCM2712_HVS), as the
//! Compute Module 5's IO board and the Pi 5 have it: the hardware video
//! scaler (HVS), which reads the picture out of RAM through a display
//! list and composes its planes; pixel valve 0, which times the HVS's
//! first channel out as a mode; and the HDMI0 controller with its PHY,
//! whose PLL makes the pixel clock. The monitor's EDID comes over the
//! port's DDC, a Broadcom BSC I2C controller of its own (`readEdid`).
//!
//! The steps and their values are Linux's (the vc4 driver of Raspberry
//! Pi's 6.12 tree: vc4_hvs.c, vc4_plane.c, vc4_crtc.c, vc4_hdmi.c and
//! vc4_hdmi_phy.c; i2c-brcmstb.c), for the BCM2712's D0 stepping: the
//! HVS's registers are where its "6D" ones are. Only the clocks are not
//! the ARM's to set: the HDMI state machine's (HSM) and the pixel
//! pipeline's (BVB) are the VideoCore firmware's, asked through its
//! mailbox (`sdk.hardware.videocore`), as Linux's clk-raspberrypi asks.
//! A register of the HDMI controller read or written while the HSM
//! clock is stopped - as the firmware leaves it with no monitor at boot -
//! never answers, and the core waits for it for good: so `wake` sets the
//! clocks before anything else.
//!
//! **The display list** is in the HVS's own memory, 0x4000 into its
//! registers, from word 32 on (the bootloader's are the 32 before): the
//! picture as a plane, the cursor as a second plane laid over it, and
//! the end. A plane is nine words at unity scale - its control word, its
//! position, its alpha, its size, the context the HVS keeps, the
//! picture's address in two words and its pitch, and a word past it -
//! and each takes a piece of the HVS's prefetch memory (UPM) of its own.
//! The list stays where it is once the display runs: showing another
//! picture is its address rewritten in place, as Linux's asynchronous
//! flip does it, and the cursor's place, image and size are its plane's
//! words rewritten; a hidden cursor is a plane of alpha 0. So a picture
//! and the cursor change from different tasks without a lock: they write
//! different words.
//!
//! The picture is XRGB8888, 32 bits a pixel, which is the library's
//! bgra32, below 4 GiB and out of the caches; the cursor ARGB8888 with
//! premultiplied alpha - clear where it is 0 - as the board's cursor
//! buffers have it. The HVS's IOMMU is left off: it reads RAM at the
//! ARM's addresses.
//!
//! The port is driven as DVI: no infoframes, full-range RGB, eight bits a
//! colour, so the TMDS clock is the pixel clock, and no scrambling - up
//! to 340 MHz, which is 4K at 30 Hz (`sends`). Pixel valve 0 raises its
//! interrupt at the start of each frame's vertical front porch, which is
//! the board's frame interrupt (`takeInterrupts`).

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const videocore = sdk.hardware.videocore;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const edid = @import("../edid.zig");

/// Whether this is built for the AArch64 machines, whose BCM2712 waking
/// the display drives. The driver is built for every chip, which picks
/// its display at run time; elsewhere the display does not wake.
const on_bcm2712 = sdk.hardware.chip == .a64psci;

/// The VideoCore's mailbox, and what the display asks its firmware: to
/// let go of the display it drives itself, and the clocks' rates - the
/// HSM's (the firmware's M2MC clock), the BVB's, and the HVS's (DISP),
/// which the firmware keeps running.
const MAILBOX: usize = 0x10_7C01_3880;
const TAG_NOTIFY_DISPLAY_DONE: u32 = 0x0003_0066;
const TAG_GET_CLOCK_RATE: u32 = 0x0003_0002;
const TAG_SET_CLOCK_RATE: u32 = 0x0003_8002;
const CLOCK_HSM: u32 = 13;
const CLOCK_BVB: u32 = 14;
const CLOCK_DISP: u32 = 16;
/// The HSM clock runs a hundredth faster than the TMDS clock, and never
/// below 120 MHz; the BVB at 75, 150 or 300 MHz by the TMDS clock.
const HSM_MIN_HZ: u64 = 120_000_000;

/// The HVS's IOMMU, switched off: control 0.
const IOMMU: usize = 0x10_0000_5200;

/// The HVS: its control, its arbiter's priorities, and per channel - 0
/// is pixel valve 0's - its control words, its display list's head, its
/// share of the composite output buffer (COB) and its status.
const HVS: usize = 0x10_7C58_0000;
const HVS_CONTROL = 0x20;
const CONTROL_HVS_EN: u32 = 1 << 31;
const CONTROL_PF_LINES_SHIFT = 18;
const CONTROL_MAX_REQS_SHIFT = 4;
const PRI_MAP0 = 0x38;
const PRI_MAP1 = 0x3C;
const DISP0 = 0x100;
const DISP_STRIDE = 0x40;
const DISP_CTRL0 = 0x00;
const DISP_CTRL1 = 0x04;
const DISP_LPTRS = 0x10;
const DISP_COB = 0x14;
const CTRL0_ENB: u32 = 1 << 31;
const CTRL0_RESET: u32 = 1 << 30;
const CTRL0_FWIDTH_SHIFT = 16;
const CTRL0_SIZE_MASK: u32 = 0x1FFF;
const CTRL1_INTLACE: u32 = 1 << 0;
/// The display lists' memory, and where this driver's list starts in it.
const DLIST = 0x4000;
const list_start: u32 = 32;

/// A plane's words (vc6_plane_mode_set), unity scale, linear RGBA8888.
const CTL0_END: u32 = 1 << 31;
const CTL0_VALID: u32 = 1 << 30;
const CTL0_NEXT_SHIFT = 24;
const CTL0_ALPHA_MASK_FIXED: u32 = 3 << 18;
const CTL0_UNITY: u32 = 1 << 15;
const CTL0_ORDER_ARGB: u32 = 2 << 13;
const PIXEL_FORMAT_RGBA8888: u32 = 7;
const CTL2_PREMULT: u32 = 1 << 29;
const CTL2_ALPHA_MIX: u32 = 1 << 28;
const CTL2_ALPHA_SHIFT = 4;
const ALPHA_OPAQUE: u32 = 0xFFF;
const CONTEXT: u32 = 0xC0C0_C0C0;
const PTR0_UPM_BASE_SHIFT = 16;
const PTR0_UPM_HANDLE_SHIFT = 10;
pub const plane_words = 9;
/// Where each word is in a plane.
const W_CTL0 = 0;
const W_POS0 = 1;
const W_CTL2 = 2;
const W_POS2 = 3;
const W_PTR0 = 5;
const W_PTR1 = 6;
const W_PTR2 = 7;
/// The picture's plane first, the cursor's over it, then the end.
const picture_plane = list_start;
const cursor_plane = list_start + plane_words;
const list_end = list_start + 2 * plane_words;

/// The HVS's prefetch memory, in units of 256 bytes, two lines a plane:
/// the picture's from 0 - room for a row of 4K - and the cursor's after.
const UPM_UNIT = 256;
const upm_picture: u32 = 0;
const upm_cursor: u32 = 128;

/// Pixel valve 0: its control, its vertical control, the mode's timing,
/// its interrupts, the pixel mux and the pipe's start.
const PV: usize = 0x10_7C41_0000;
const PV_CONTROL = 0x00;
const PV_V_CONTROL = 0x04;
const PV_VSYNCD_EVEN = 0x08;
const PV_HORZA = 0x0C;
const PV_HORZB = 0x10;
const PV_VERTA = 0x14;
const PV_VERTB = 0x18;
const PV_INTEN = 0x24;
const PV_INTSTAT = 0x28;
const PV_MUX_CFG = 0x34;
const PV_PIPE_INIT_CTRL = 0x94;
const PV_CONTROL_EN: u32 = 1 << 0;
const PV_CONTROL_FIFO_CLR: u32 = 1 << 1;
const PV_CONTROL_WAIT_HSTART: u32 = 1 << 12;
const PV_CONTROL_TRIGGER_UNDERFLOW: u32 = 1 << 13;
const PV_CONTROL_CLR_AT_START: u32 = 1 << 14;
const PV_CONTROL_FIFO_LEVEL_SHIFT = 15;
const PV_CONTROL_FIFO_LEVEL_HIGH_SHIFT = 25;
const PV_VCONTROL_VIDEN: u32 = 1 << 0;
const PV_VCONTROL_CONTINUOUS: u32 = 1 << 1;
const PV_VCONTROL_ODD_TIMING: u32 = 1 << 29;
const PV_INT_VFP_START: u32 = 1 << 7;
const PV_MUX_NO_SWAP: u32 = 8 << 2;
const PV_PIPE_INIT: u32 = 1 << 8 | 1 << 4 | 1 << 0;
/// The FIFO's level: its 64 bytes less the six pixels of the fetch's
/// latency, three bytes each.
const pv_fifo_level: u32 = 64 - 3 * 6;

/// The HDMI0 controller's blocks.
const HDMI: usize = 0x10_7C70_1400;
const HDMI_DVP: usize = 0x10_7C70_1000;
const HDMI_PHY: usize = 0x10_7C70_1D00;
const HDMI_RM: usize = 0x10_7C70_2000;
const HDMI_CSC: usize = 0x10_7C70_0100;
const HDMI_HD: usize = 0x10_7C72_0000;
/// The DVP's clock gates, one bit for each port's 108 MHz, set to stop it.
const DVP_MISC_CONFIG: usize = 0x10_7C70_0008;
const DVP_HDMI0_GATE: u32 = 1 << 3;

const FIFO_CTL = 0x07C;
const RAM_PACKET_CONFIG = 0x0C4;
const SCHEDULER_CONTROL = 0x0E8;
const H_HORZA = 0x0EC;
const H_HORZB = 0x0F0;
const H_VERTA0 = 0x0F4;
const H_VERTB0 = 0x0F8;
const H_VERTA1 = 0x100;
const H_VERTB1 = 0x104;
const MISC_CONTROL = 0x114;
const DEEP_COLOR_CONFIG_1 = 0x18C;
const GCP_CONFIG = 0x194;
const GCP_WORD_1 = 0x198;
const HOTPLUG = 0x1C8;
const HOTPLUG_CONNECTED: u32 = 1 << 0;
const FIFO_MASTER_SLAVE_N: u32 = 1 << 0;
const FIFO_RECENTER: u32 = 1 << 6;
const FIFO_RECENTER_DONE: u32 = 1 << 14;
const FIFO_VALID_WRITE: u32 = 0xEFFF;
const RAM_PACKET_ENABLE: u32 = 1 << 16;
const SCHEDULER_MODE_HDMI: u32 = 1 << 0;
const SCHEDULER_HDMI_ACTIVE: u32 = 1 << 1;
const SCHEDULER_IGNORE_VSYNC_PREDICTS: u32 = 1 << 5;
const SCHEDULER_MANUAL_FORMAT: u32 = 1 << 15;
const HORZA_VPOS: u32 = 1 << 15;
const HORZA_HPOS: u32 = 1 << 14;
const GCP_ENABLE: u32 = 1 << 31;
const GCP_CLEAR_AVMUTE: u32 = 1 << 4;

const DVP_CLOCK_STOP = 0x0BC;
const DVP_VEC_INTERFACE_CFG = 0x0F0;
const DVP_VEC_INTERFACE_XBAR = 0x0F4;
const CLOCK_STOP_PIXEL: u32 = 1 << 1;
/// The colour lanes' order for RGB out of the CSC.
const XBAR_RGB: u32 = 0x35_4021;

const CSC_CTL = 0x00;
const CSC_12_11 = 0x04;
const CSC_14_13 = 0x08;
const CSC_22_21 = 0x0C;
const CSC_24_23 = 0x10;
const CSC_32_31 = 0x14;
const CSC_34_33 = 0x18;
const CSC_CHANNEL_CTL = 0x2C;
const CSC_ENABLE_CUSTOM: u32 = 1 << 2 | 3;
/// 1.0 in the CSC's 2.13 fixed point.
const CSC_ONE: u32 = 0x2000;

const HD_DVP_CTL = 0x00;
const HD_VID_CTL = 0x44;
const VID_ENABLE: u32 = 1 << 31;
const VID_UNDERFLOW_ENABLE: u32 = 1 << 30;
const VID_FRAME_COUNTER_RESET: u32 = 1 << 29;
const VID_VSYNC_LOW: u32 = 1 << 28;
const VID_HSYNC_LOW: u32 = 1 << 27;
const VID_CLRRGB: u32 = 1 << 23;
const VID_BLANKPIX: u32 = 1 << 18;
const VID_BLANK_INSERT_EN: u32 = 1 << 16;

/// The PHY (vc6_hdmi_phy_init): its PLL from the 54 MHz crystal, its
/// VCO 8 to 12 GHz, ten bits a TMDS character.
const PHY_RESET_CTL = 0x000;
const PHY_POWERUP_CTL = 0x004;
const PHY_CTL_0 = 0x008;
const PHY_CTL_1 = 0x00C;
const PHY_CTL_2 = 0x010;
const PHY_CTL_CK = 0x014;
const PHY_PLL_REFCLK = 0x01C;
const PHY_PLL_POST_KDIV = 0x028;
const PHY_PLL_VCOCLK_DIV = 0x02C;
const PHY_PLL_CFG = 0x044;
const PHY_TMDS_CLK_WORD_SEL = 0x054;
const PHY_PLL_MISC_0 = 0x060;
const PHY_PLL_RESET_CTL = 0x190;
const PHY_PLL_POWERUP_CTL = 0x194;
const PHY_POWERUP_ALL: u32 = 0x1CF;
const PHY_PLL_RESETB: u32 = 1 << 0;
const PHY_KDIV_BYPASS: u32 = 1 << 4;
const PHY_KDIV_RUN: u32 = 2 << 2 | 1;
const PHY_REFCLK_CMOS_54: u32 = 1 << 13 | 54;
const PHY_VCODIV_EN: u32 = 1 << 10;
const RM_OFFSET = 0x018;
const RM_OFFSET_ONLY: u32 = 1 << 31;
const CRYSTAL_HZ: u64 = 54_000_000;
const VCO_MIN_HZ: u64 = 8_000_000_000;
const VCO_MAX_HZ: u64 = 12_000_000_000;
/// The PLL's other settings, as Linux writes them, MISC_0 to MISC_8.
const pll_misc = [_]u32{ 0x810C_6000, 0x00B8_C451, 0x4640_2E31, 0x00B8_C005, 0x4241_0261, 0xCC02_1001, 0xC830_1C80, 0xB080_4444, 0xF80F_8000 };

/// The port's DDC: a BSC I2C controller - the target's address, eight
/// words of data each way, the count, its control, the transfer's enable
/// and status, and more control.
const DDC: usize = 0x10_7D50_8200;
const BSC_CHIP_ADDRESS = 0x00;
const BSC_DATA_IN = 0x04;
const BSC_CNT = 0x24;
const BSC_CTL = 0x28;
const BSC_IIC_ENABLE = 0x2C;
const BSC_DATA_OUT = 0x30;
const BSC_CTLHI = 0x50;
/// 97.5 kHz: the 390 kHz clock, divided; the data words four bytes each.
const BSC_CTL_97K: u32 = 1 << 4 | 1 << 7;
const BSC_CTL_INT_EN: u32 = 1 << 6;
const BSC_CTL_READ: u32 = 1;
const BSC_CTLHI_WORDS: u32 = 1 << 6;
const BSC_ENABLE: u32 = 1 << 0;
const BSC_DONE: u32 = 1 << 1;
const BSC_NOACK: u32 = 1 << 2;
/// What a piece of a transfer is to end and start with.
const COND_NOSTOP: u32 = 1 << 4;
const COND_NOSTART: u32 = 1 << 5;
const COND_RESTART: u32 = 1 << 6;
const bsc_chunk = 32;
const EDID_ADDRESS: u32 = 0x50;

/// How many times a wait reads its register before it gives up.
const patience: u32 = 1_000_000;

/// Why the display did not come up: the firmware did not set its clocks,
/// or the port sends no such pixel clock.
pub const Failure = enum { none, firmware, clock };

/// What went wrong, said on the raw port.
pub fn why(failure: Failure) [*:0]const u8 {
    return switch (failure) {
        .none => "the display came up",
        .firmware => "the VideoCore firmware did not set the HDMI clocks",
        .clock => "the HDMI port sends no such pixel clock",
    };
}

fn at(base: usize, offset: usize) *volatile u32 {
    return reg(base + offset);
}

fn hvsDisp(offset: usize) *volatile u32 {
    return reg(HVS + DISP0 + offset);
}

fn word(index: u32) *volatile u32 {
    return reg(HVS + DLIST + @as(usize, index) * 4);
}

// --- the firmware ------------------------------------------------------------

/// The firmware asked `tag` with `value`: whether it answered. The
/// message's buffer is RAM it reaches, taken for the call.
fn ask(sys: *ExecBase, tag: u32, value: []u32) bool {
    const memory = sys.AllocMem(videocore.buffer_bytes * 2, exec.MEMF_DMA | exec.MEMF_CLEAR) orelse return false;
    defer sys.FreeMem(memory, videocore.buffer_bytes * 2);
    const buffer = videocore.bufferIn(memory) orelse return false;
    return videocore.call(sys, MAILBOX, buffer, tag, value);
}

/// Clock `clock` set to `hz`: whether the firmware took it.
fn setClock(sys: *ExecBase, clock: u32, hz: u64) bool {
    var value = [3]u32{ clock, @intCast(hz), 0 };
    return ask(sys, TAG_SET_CLOCK_RATE, &value) and value[1] != 0;
}

/// Clock `clock`'s rate; 0 while it is stopped, null when the firmware
/// does not say.
fn clockRate(sys: *ExecBase, clock: u32) ?u32 {
    var value = [2]u32{ clock, 0 };
    if (!ask(sys, TAG_GET_CLOCK_RATE, &value)) return null;
    return value[1];
}

/// Clock `clock` running at `hz` at least: set to it when it is slower.
fn atLeast(sys: *ExecBase, clock: u32, hz: u64) bool {
    const now = clockRate(sys, clock) orelse return false;
    return now >= hz or setClock(sys, clock, hz);
}

/// The HSM's rate for a TMDS clock of `tmds_hz`.
pub fn hsmHz(tmds_hz: u64) u64 {
    return @max(HSM_MIN_HZ, tmds_hz / 100 * 101);
}

/// The BVB's rate for a TMDS clock of `tmds_hz`.
pub fn bvbHz(tmds_hz: u64) u64 {
    if (tmds_hz > 297_000_000) return 300_000_000;
    if (tmds_hz > 148_500_000) return 150_000_000;
    return 75_000_000;
}

/// The clocks the controller needs for a TMDS clock of `tmds_hz`.
fn clocksFor(sys: *ExecBase, tmds_hz: u64) bool {
    return setClock(sys, CLOCK_HSM, hsmHz(tmds_hz)) and setClock(sys, CLOCK_BVB, bvbHz(tmds_hz));
}

// --- waking ------------------------------------------------------------------

/// The firmware's own display let go of, the HVS's clock seen to run,
/// the HDMI controller's running - at least as fast as the slowest
/// mode's, until `start` sets a mode's - and its 108 MHz gate open, and
/// the DDC ready to read the monitor's EDID (`readEdid`): what tells
/// which modes the monitor takes before one is picked, and what `monitor`
/// needs. Nothing of the display's is read before its clocks are known
/// to run. Done again it changes nothing. `sys` is exec's;
/// `waiter.wait(micros)` waits that long.
pub fn wake(sys: *ExecBase, waiter: anytype) Failure {
    _ = waiter;
    if (!on_bcm2712) return .firmware;
    // Firmware that does not know the tag has no display of its own to
    // let go of.
    var none = [0]u32{};
    _ = ask(sys, TAG_NOTIFY_DISPLAY_DONE, &none);
    if ((clockRate(sys, CLOCK_DISP) orelse 0) == 0) return .firmware;
    if (!atLeast(sys, CLOCK_HSM, hsmHz(0)) or !atLeast(sys, CLOCK_BVB, bvbHz(0))) return .firmware;
    at(DVP_MISC_CONFIG, 0).* &= ~DVP_HDMI0_GATE;
    // The DDC (brcmstb_i2c_set_bsc_reg_defaults): four bytes a data word,
    // 97.5 kHz, nothing under way.
    at(DDC, BSC_CTLHI).* = BSC_CTLHI_WORDS;
    at(DDC, BSC_CTL).* = BSC_CTL_97K;
    at(DDC, BSC_IIC_ENABLE).* = 0;
    return .none;
}

/// Whether the HVS's first channel runs this driver's list.
fn running() bool {
    return hvsDisp(DISP_CTRL0).* & CTRL0_ENB != 0 and hvsDisp(DISP_LPTRS).* & 0xFFF == list_start;
}

/// Whether a monitor is on the port: the controller's hot-plug line.
/// Only once `wake` has its clocks running.
pub fn monitor() bool {
    if (!on_bcm2712) return false;
    return at(HDMI, HOTPLUG).* & HOTPLUG_CONNECTED != 0;
}

// --- the DDC -----------------------------------------------------------------

/// What each piece of a read of `length` bytes is to end and start with,
/// as Linux's brcmstb_i2c_xfer has a read after its write: the first
/// starts again after the write and keeps the bus, the ones after go on
/// without a start, the last ends with a stop.
pub fn readCondition(first: bool, last: bool) u32 {
    if (first and last) return 0;
    if (first) return COND_NOSTOP;
    if (last) return COND_NOSTART;
    return COND_NOSTART | COND_NOSTOP;
}

/// One piece of a transfer of `length` bytes started - written from
/// the data words, or read into them - ending and starting as
/// `condition` says. False when the target did not answer, or the
/// controller did not finish in 100 ms (brcmstb_send_i2c_cmd).
fn run(condition: u32, read: bool, length: usize, waiter: anytype) bool {
    const control = BSC_CTL_97K | (if (read) BSC_CTL_READ else 0);
    at(DDC, BSC_CTLHI).* = BSC_CTLHI_WORDS;
    at(DDC, BSC_CNT).* = @intCast(length & 0x3F);
    at(DDC, BSC_CTL).* = control | BSC_CTL_INT_EN;
    at(DDC, BSC_IIC_ENABLE).* = condition | BSC_ENABLE;
    var waited: u32 = 0;
    while (at(DDC, BSC_IIC_ENABLE).* & BSC_DONE == 0 and waited < 100) : (waited += 1) waiter.wait(1000);
    const status = at(DDC, BSC_IIC_ENABLE).*;
    at(DDC, BSC_CTL).* = control;
    at(DDC, BSC_CNT).* = 0;
    at(DDC, BSC_IIC_ENABLE).* = 0;
    return status & BSC_DONE != 0 and status & BSC_NOACK == 0;
}

/// Up to 32 bytes written, four to a data word, the first in its low
/// byte.
fn send(condition: u32, bytes: []const u8, waiter: anytype) bool {
    var i: usize = 0;
    while (i * 4 < bytes.len) : (i += 1) {
        var data: u32 = 0;
        for (0..4) |byte| {
            if (i * 4 + byte < bytes.len) data |= @as(u32, bytes[i * 4 + byte]) << @intCast(byte * 8);
        }
        at(DDC, BSC_DATA_IN + i * 4).* = data;
    }
    return run(condition, false, bytes.len, waiter);
}

/// Up to 32 bytes read into `into`.
fn receive(condition: u32, into: []u8, waiter: anytype) bool {
    if (!run(condition, true, into.len, waiter)) return false;
    var i: usize = 0;
    while (i * 4 < into.len) : (i += 1) {
        const data = at(DDC, BSC_DATA_OUT + i * 4).*;
        for (0..4) |byte| {
            if (i * 4 + byte < into.len) into[i * 4 + byte] = @truncate(data >> @intCast(byte * 8));
        }
    }
    return true;
}

/// Block `number` of the monitor's EDID into `block` - 0 or 1, the two
/// halves of its first segment: the offset written to the EDID's address,
/// then the block read in pieces of 32 bytes. False when the monitor did
/// not answer. Only once `wake` has the DDC ready.
pub fn readEdid(number: u8, block: *[128]u8, waiter: anytype) bool {
    if (!on_bcm2712 or number > 1) return false;
    at(DDC, BSC_CHIP_ADDRESS).* = EDID_ADDRESS << 1;
    const offset = [1]u8{number * 128};
    if (!send(COND_RESTART | COND_NOSTOP, &offset, waiter)) return false;
    at(DDC, BSC_CHIP_ADDRESS).* = EDID_ADDRESS << 1 | 1;
    var done: usize = 0;
    while (done < block.len) : (done += bsc_chunk) {
        const condition = readCondition(done == 0, done + bsc_chunk >= block.len);
        if (!receive(condition, block[done .. done + bsc_chunk], waiter)) return false;
    }
    return true;
}

// --- the PHY -----------------------------------------------------------------

/// The port's fastest TMDS clock without scrambling, in kHz.
const max_khz: u32 = 340_000;

/// Whether the port can send a mode of that pixel clock.
pub fn sends(pixel_khz: u32) bool {
    return pixel_khz != 0 and pixel_khz <= max_khz;
}

/// The VCO's divider for a TMDS clock of `tmds_hz`: halfway between the
/// least that brings ten times the clock up to 8 GHz and the most that
/// keeps it under 12 (vc6_phy_get_vco_freq).
pub fn vcoDivider(tmds_hz: u64) u32 {
    var div: u64 = 0;
    while (tmds_hz * div * 10 < VCO_MIN_HZ) div += 1;
    const least = div;
    while (tmds_hz * (div + 1) * 10 < VCO_MAX_HZ) div += 1;
    return @intCast(least + (div - least) / 2);
}

/// The rate manager's offset for the VCO at `vco_hz`: twice it over the
/// crystal, in 9.22 fixed point (phy_get_rm_offset).
pub fn rmOffset(vco_hz: u64) u32 {
    return @intCast(((vco_hz * 2) << 22) / CRYSTAL_HZ >> 2);
}

/// A lane's drive (CTL_0 to CTL_2, and CTL_CK for the clock lane) at a
/// TMDS clock of `tmds_hz`, as vc6_hdmi_phy_settings has it: three bands
/// of currents, termination and slew, to 222, 297 and 597 MHz.
pub fn laneDrive(tmds_hz: u64, clock_lane: bool) u32 {
    if (tmds_hz <= 222_000_000) return 0x8082_8700;
    if (tmds_hz <= 297_000_000) return if (clock_lane) 0xC087_0800 else 0xC087_0000;
    return if (clock_lane) 0x849F_8F00 else 0x848F_8700;
}

/// The PHY reset, its PLL set for `tmds_hz` and locked, its lanes driven
/// and powered up (vc6_hdmi_phy_init).
fn phyStart(tmds_hz: u64) void {
    const div = vcoDivider(tmds_hz);
    const vco = tmds_hz * div * 10;
    at(HDMI_PHY, PHY_RESET_CTL).* = 0;
    at(HDMI_PHY, PHY_POWERUP_CTL).* = 0;
    at(HDMI_PHY, PHY_PLL_POST_KDIV).* = PHY_KDIV_BYPASS;
    for (pll_misc, 0..) |value, i| at(HDMI_PHY, PHY_PLL_MISC_0 + i * 4).* = value;
    at(HDMI_PHY, PHY_PLL_REFCLK).* = PHY_REFCLK_CMOS_54;
    at(HDMI_PHY, PHY_RESET_CTL).* = 0x7F;
    at(HDMI_RM, RM_OFFSET).* = RM_OFFSET_ONLY | rmOffset(vco);
    at(HDMI_PHY, PHY_PLL_VCOCLK_DIV).* = PHY_VCODIV_EN | div;
    at(HDMI_PHY, PHY_PLL_CFG).* = 0;
    at(HDMI_PHY, PHY_PLL_POST_KDIV).* = PHY_KDIV_RUN;
    at(HDMI_PHY, PHY_CTL_0).* = laneDrive(tmds_hz, false);
    at(HDMI_PHY, PHY_CTL_1).* = laneDrive(tmds_hz, false);
    at(HDMI_PHY, PHY_CTL_2).* = laneDrive(tmds_hz, false);
    at(HDMI_PHY, PHY_CTL_CK).* = laneDrive(tmds_hz, true);
    at(HDMI_PHY, PHY_TMDS_CLK_WORD_SEL).* = if (tmds_hz >= 340_000_000) 3 else 0;
    at(HDMI_PHY, PHY_POWERUP_CTL).* = PHY_POWERUP_ALL;
    at(HDMI_PHY, PHY_PLL_POWERUP_CTL).* = 1;
    at(HDMI_PHY, PHY_PLL_RESET_CTL).* &= ~PHY_PLL_RESETB;
    at(HDMI_PHY, PHY_PLL_RESET_CTL).* |= PHY_PLL_RESETB;
}

// --- the display list --------------------------------------------------------

/// A plane of its picture at `address`, `width` by `height` pixels at
/// (x, y), rows `pitch` bytes apart, in the UPM from `upm` as handle
/// `handle`: with alpha its pixels' own (the cursor's), or opaque (the
/// picture's), and seen or not.
pub const Plane = struct {
    address: usize,
    pitch: u32,
    x: u32 = 0,
    y: u32 = 0,
    width: u32,
    height: u32,
    upm: u32,
    handle: u32,
    alpha: bool = false,
    seen: bool = true,
};

/// The plane's nine words (vc6_plane_mode_set, vc6_plane_allocate_upm).
pub fn planeOf(plane: Plane) [plane_words]u32 {
    const mask = if (plane.alpha) 0 else CTL0_ALPHA_MASK_FIXED;
    const ctl2 = if (plane.seen) CTL2_PREMULT | ALPHA_OPAQUE << CTL2_ALPHA_SHIFT else CTL2_PREMULT | CTL2_ALPHA_MIX;
    return .{
        CTL0_VALID | plane_words << CTL0_NEXT_SHIFT | mask | CTL0_UNITY | CTL0_ORDER_ARGB | PIXEL_FORMAT_RGBA8888,
        (plane.y & 0x1FFF) << 16 | (plane.x & 0x1FFF),
        ctl2,
        (plane.height - 1) << 16 | (plane.width - 1),
        CONTEXT,
        plane.upm << PTR0_UPM_BASE_SHIFT | plane.handle << PTR0_UPM_HANDLE_SHIFT | upper(plane.address),
        @truncate(plane.address),
        plane.pitch,
        CTL0_END,
    };
}

/// An address's bits above the low 32, as a plane's first pointer word
/// carries them: eight, as far as the HVS reaches.
fn upper(address: usize) u32 {
    return @as(u32, @truncate(@as(u64, address) >> 32)) & 0xFF;
}

/// The units of UPM a plane of rows `pitch` bytes apart takes: two lines
/// of 32-byte words, with one to spare (vc6_upm_size).
pub fn upmUnits(pitch: u32) u32 {
    const line = (pitch + 62) / 32 * 32;
    return (line * 2 + UPM_UNIT - 1) / UPM_UNIT;
}

fn writePlane(first: u32, plane: Plane) void {
    for (planeOf(plane), 0..) |value, i| word(first + @as(u32, @intCast(i))).* = value;
}

/// The cursor's plane - an image `side` pixels square at `address` with
/// its top left at (left, top) - cut to a picture `width` by `height`:
/// the part of the image on it, which the hot spot being on the picture
/// makes at least a pixel.
pub fn cursorPlaneOf(address: usize, side: u32, left: i32, top: i32, width: u32, height: u32, seen: bool) Plane {
    const s: i32 = @intCast(side);
    const from_x: u32 = @intCast(@max(0, -left));
    const from_y: u32 = @intCast(@max(0, -top));
    const x: u32 = @intCast(@max(0, left));
    const y: u32 = @intCast(@max(0, top));
    const right: u32 = @intCast(@min(@as(i32, @intCast(width)), left + s));
    const bottom: u32 = @intCast(@min(@as(i32, @intCast(height)), top + s));
    return .{
        .address = address + @as(usize, from_y) * side * 4 + @as(usize, from_x) * 4,
        .pitch = side * 4,
        .x = x,
        .y = y,
        .width = @max(right -| x, 1),
        .height = @max(bottom -| y, 1),
        .upm = upm_cursor,
        .handle = 1,
        .alpha = true,
        .seen = seen,
    };
}

// --- starting ----------------------------------------------------------------

/// The display taken down, if it runs: pixel valve 0 stopped at the end
/// of a frame, the controller's picture blanked, the valve's FIFO cleared
/// and the HVS's channel reset (vc4_crtc_disable).
fn stop(waiter: anytype) void {
    if (at(PV, PV_V_CONTROL).* & PV_VCONTROL_VIDEN != 0) {
        at(PV, PV_V_CONTROL).* &= ~PV_VCONTROL_VIDEN;
        waiter.wait(20_000);
    }
    at(HDMI, RAM_PACKET_CONFIG).* = 0;
    at(HDMI_HD, HD_VID_CTL).* |= VID_CLRRGB | VID_BLANKPIX;
    at(PV, PV_INTEN).* = 0;
    at(PV, PV_CONTROL).* &= ~PV_CONTROL_EN;
    at(PV, PV_CONTROL).* |= PV_CONTROL_FIFO_CLR;
    if (hvsDisp(DISP_CTRL0).* & CTRL0_ENB != 0) {
        hvsDisp(DISP_CTRL0).* |= CTRL0_RESET;
        hvsDisp(DISP_CTRL0).* &= ~CTRL0_ENB;
    }
}

/// The HVS on, its IOMMU off, and the composite output buffer shared
/// between its three channels, four lines of 3840 for each of the first
/// two (vc6_hvs_hw_init, vc4_hvs_cob_init).
fn hvsStart() void {
    at(IOMMU, 0).* = 0;
    at(HVS, HVS_CONTROL).* = CONTROL_HVS_EN | 8 << CONTROL_PF_LINES_SHIFT | 15 << CONTROL_MAX_REQS_SHIFT;
    at(HVS, PRI_MAP0).* = 0xFFFF_FFFF;
    at(HVS, PRI_MAP1).* = 0xFFFF_FFFF;
    var top: u32 = 3840;
    reg(HVS + DISP0 + 2 * DISP_STRIDE + DISP_COB).* = top << 16;
    var base = top + 16;
    top += 3840 * 4;
    reg(HVS + DISP0 + DISP_STRIDE + DISP_COB).* = top << 16 | base;
    base = top + 16;
    top += 3840 * 4;
    hvsDisp(DISP_COB).* = top << 16 | base;
}

/// The controller's timing for `mode` (vc5_hdmi_set_timings), eight bits
/// a colour, no pixel doubling.
fn hdmiTiming(mode: *const edid.Timing) void {
    var horza = mode.width | mode.h_front << 16;
    if (mode.vsync_high) horza |= HORZA_VPOS;
    if (mode.hsync_high) horza |= HORZA_HPOS;
    at(HDMI, H_HORZA).* = horza;
    at(HDMI, H_HORZB).* = mode.h_back << 16 | mode.h_sync;
    const verta = (mode.v_sync & 0x1F) << 24 | (mode.v_front & 0x7F) << 16 | mode.height;
    at(HDMI, H_VERTA0).* = verta;
    at(HDMI, H_VERTA1).* = verta;
    at(HDMI, H_VERTB0).* = mode.v_back & 0x1FF;
    at(HDMI, H_VERTB1).* = (mode.htotal() >> 1) << 16 | (mode.v_back & 0x1FF);
    at(HDMI, DEEP_COLOR_CONFIG_1).* = at(HDMI, DEEP_COLOR_CONFIG_1).* & ~@as(u32, 0x70F) | 2 << 8;
    at(HDMI, GCP_WORD_1).* = at(HDMI, GCP_WORD_1).* & ~@as(u32, 0xFFFF) | GCP_CLEAR_AVMUTE;
    at(HDMI, GCP_CONFIG).* |= GCP_ENABLE;
    at(HDMI, MISC_CONTROL).* &= ~@as(u32, 0xF);
    at(HDMI_DVP, DVP_CLOCK_STOP).* = 0;
}

/// Pixel valve 0's timing for `mode` (vc4_crtc_config_pv): progressive,
/// a pixel a clock, 24 bits from the HDMI controller's clock.
fn pvTiming(mode: *const edid.Timing) void {
    at(PV, PV_CONTROL).* &= ~PV_CONTROL_EN;
    at(PV, PV_CONTROL).* |= PV_CONTROL_FIFO_CLR;
    at(PV, PV_HORZA).* = mode.h_back << 16 | mode.h_sync;
    at(PV, PV_HORZB).* = mode.h_front << 16 | mode.width;
    at(PV, PV_V_CONTROL).* = PV_VCONTROL_CONTINUOUS | PV_VCONTROL_ODD_TIMING;
    at(PV, PV_VSYNCD_EVEN).* = 0;
    at(PV, PV_VERTA).* = mode.v_back << 16 | mode.v_sync;
    at(PV, PV_VERTB).* = mode.v_front << 16 | mode.height;
    at(PV, PV_MUX_CFG).* = PV_MUX_NO_SWAP;
    at(PV, PV_PIPE_INIT_CTRL).* = PV_PIPE_INIT;
    at(PV, PV_CONTROL).* = PV_CONTROL_FIFO_CLR |
        (pv_fifo_level & 0x3F) << PV_CONTROL_FIFO_LEVEL_SHIFT |
        (pv_fifo_level >> 6) << PV_CONTROL_FIFO_LEVEL_HIGH_SHIFT |
        PV_CONTROL_CLR_AT_START | PV_CONTROL_TRIGGER_UNDERFLOW | PV_CONTROL_WAIT_HSTART;
}

/// RGB through the controller's CSC unchanged (vc5_hdmi_csc_setup).
fn hdmiColours() void {
    at(HDMI_DVP, DVP_VEC_INTERFACE_CFG).* = 0;
    at(HDMI_DVP, DVP_VEC_INTERFACE_XBAR).* = XBAR_RGB;
    at(HDMI_CSC, CSC_12_11).* = CSC_ONE;
    at(HDMI_CSC, CSC_14_13).* = 0;
    at(HDMI_CSC, CSC_22_21).* = CSC_ONE << 16;
    at(HDMI_CSC, CSC_24_23).* = 0;
    at(HDMI_CSC, CSC_32_31).* = 0;
    at(HDMI_CSC, CSC_34_33).* = CSC_ONE;
    at(HDMI_CSC, CSC_CHANNEL_CTL).* = 0;
    at(HDMI_CSC, CSC_CTL).* = CSC_ENABLE_CUSTOM;
}

/// Until `bits` of `register` are `set` or not, `tries` milliseconds at
/// most.
fn waitBits(register: *volatile u32, bits: u32, set: bool, tries: u32, waiter: anytype) void {
    var waited: u32 = 0;
    while ((register.* & bits != 0) != set and waited < tries) : (waited += 1) waiter.wait(1000);
}

/// The display brought up in `mode` - its pixel clock one the port sends
/// (`sends`) - showing the picture at `address`, 32 bits a pixel, rows
/// `pitch` bytes apart, below 4 GiB and out of the caches; the cursor
/// hidden. With the display up, it changes to `mode`. The order is
/// vc4_crtc_atomic_enable's. `waiter.wait(micros)` waits that long.
pub fn start(sys: *ExecBase, mode: *const edid.Timing, address: usize, pitch: u32, waiter: anytype) Failure {
    if (!on_bcm2712) return .firmware;
    if (!sends(mode.pixel_khz)) return .clock;
    const woken = wake(sys, waiter);
    if (woken != .none) return woken;
    const tmds_hz = @as(u64, mode.pixel_khz) * 1000;
    stop(waiter);
    if (!clocksFor(sys, tmds_hz)) return .firmware;

    // The controller reset (vc5_hdmi_reset), the HVS's channel 0 on with
    // the list: the picture, and the cursor hidden over it.
    at(HDMI_HD, HD_DVP_CTL).* = 0;
    at(HDMI_DVP, DVP_CLOCK_STOP).* |= CLOCK_STOP_PIXEL;
    hvsStart();
    writePlane(picture_plane, .{ .address = address, .pitch = pitch, .width = mode.width, .height = mode.height, .upm = upm_picture, .handle = 0 });
    writePlane(cursor_plane, .{ .address = address, .pitch = 4, .width = 1, .height = 1, .upm = upm_cursor, .handle = 1, .alpha = true, .seen = false });
    word(list_end).* = CTL0_END;
    hvsDisp(DISP_LPTRS).* = list_start;
    hvsDisp(DISP_CTRL0).* = CTRL0_RESET;
    hvsDisp(DISP_CTRL1).* &= ~CTRL1_INTLACE;
    hvsDisp(DISP_CTRL0).* = CTRL0_ENB | (mode.width - 1) << CTRL0_FWIDTH_SHIFT | (mode.height - 1);

    // The controller's PHY and timing, the valve's, the colours, then the
    // video let through (pre_crtc_configure, config_pv, pre_crtc_enable,
    // post_crtc_enable), as DVI.
    phyStart(tmds_hz);
    at(HDMI, SCHEDULER_CONTROL).* |= SCHEDULER_MANUAL_FORMAT | SCHEDULER_IGNORE_VSYNC_PREDICTS;
    hdmiTiming(mode);
    pvTiming(mode);
    at(PV, PV_CONTROL).* |= PV_CONTROL_EN;
    hdmiColours();
    at(HDMI, FIFO_CTL).* = FIFO_MASTER_SLAVE_N;
    at(PV, PV_V_CONTROL).* |= PV_VCONTROL_VIDEN;
    var video = at(HDMI_HD, HD_VID_CTL).* & ~(VID_VSYNC_LOW | VID_HSYNC_LOW);
    video |= VID_ENABLE | VID_CLRRGB | VID_UNDERFLOW_ENABLE | VID_FRAME_COUNTER_RESET | VID_BLANK_INSERT_EN;
    if (!mode.vsync_high) video |= VID_VSYNC_LOW;
    if (!mode.hsync_high) video |= VID_HSYNC_LOW;
    at(HDMI_HD, HD_VID_CTL).* = video;
    at(HDMI_HD, HD_VID_CTL).* &= ~VID_BLANKPIX;
    at(HDMI, RAM_PACKET_CONFIG).* &= ~RAM_PACKET_ENABLE;
    at(HDMI, SCHEDULER_CONTROL).* &= ~SCHEDULER_MODE_HDMI;
    waitBits(at(HDMI, SCHEDULER_CONTROL), SCHEDULER_HDMI_ACTIVE, false, 1000, waiter);
    recenter(waiter);

    // The frame interrupt: the start of each vertical front porch.
    at(PV, PV_INTSTAT).* = PV_INT_VFP_START;
    at(PV, PV_INTEN).* = PV_INT_VFP_START;
    return .none;
}

/// The controller's FIFO centred between the valve and the PHY, twice a
/// millisecond apart (vc4_hdmi_recenter_fifo).
fn recenter(waiter: anytype) void {
    const fifo = at(HDMI, FIFO_CTL);
    const drift = fifo.* & FIFO_VALID_WRITE;
    for (0..2) |i| {
        if (i != 0) waiter.wait(1000);
        fifo.* = drift & ~FIFO_RECENTER;
        fifo.* = drift | FIFO_RECENTER;
    }
    var tries: u32 = 0;
    while (fifo.* & FIFO_RECENTER_DONE == 0 and tries < patience) tries += 1;
}

/// What pixel valve 0 raised since this was last asked, cleared: 0 when
/// the interrupt was not its.
pub fn takeInterrupts() u32 {
    const raised = at(PV, PV_INTSTAT).* & at(PV, PV_INTEN).*;
    if (raised != 0) at(PV, PV_INTSTAT).* = raised;
    return raised;
}

/// The picture at `address` shown from now on: the picture's plane's
/// address rewritten. The HVS takes it up as it next fetches.
pub fn show(address: usize) void {
    if (!running()) return;
    word(picture_plane + W_PTR0).* = (word(picture_plane + W_PTR0).* & ~@as(u32, 0xFF)) | upper(address);
    word(picture_plane + W_PTR1).* = @truncate(address);
}

/// The largest cursor image, each way.
pub const cursor_side = 64;

/// The cursor's plane: the image at `address` (`cursor_side` square, or
/// half that when `small`), its hot spot at (x, y) on the picture, shown
/// or not - its words rewritten, the address last, so that the HVS does
/// not fetch a new image at an old size.
pub fn cursor(address: usize, small: bool, hot_x: u32, hot_y: u32, x: u32, y: u32, shown: bool) void {
    if (!running()) return;
    const control = hvsDisp(DISP_CTRL0).*;
    const width = (control >> CTRL0_FWIDTH_SHIFT & CTRL0_SIZE_MASK) + 1;
    const height = (control & CTRL0_SIZE_MASK) + 1;
    const side: u32 = if (small) cursor_side / 2 else cursor_side;
    const left = @as(i32, @intCast(x)) - @as(i32, @intCast(hot_x));
    const top = @as(i32, @intCast(y)) - @as(i32, @intCast(hot_y));
    const words = planeOf(cursorPlaneOf(address, side, left, top, width, height, shown));
    for ([_]usize{ W_CTL2, W_POS0, W_POS2, W_PTR2, W_PTR0, W_PTR1 }) |i| word(cursor_plane + @as(u32, @intCast(i))).* = words[i];
}

const std = @import("std");
const testing = std.testing;

test "the BCM2712's HDMI PHY: the VCO's divider, the rate manager and the lanes' drive" {
    // 1080p60: ten times 148.5 MHz is 1.485 GHz; 6 brings it over 8 GHz,
    // 8 keeps it under 12, and 7 is between.
    try testing.expectEqual(@as(u32, 7), vcoDivider(148_500_000));
    // 720p60, 74.25 MHz: 11 to 16, so 13.
    try testing.expectEqual(@as(u32, 13), vcoDivider(74_250_000));
    // 4K30, 297 MHz: 3 to 4.
    try testing.expectEqual(@as(u32, 3), vcoDivider(297_000_000));
    // 10.395 GHz over 54 MHz, twice, in 9.22: 384.999... * 2^20.
    try testing.expectEqual(@as(u32, @intCast((10_395_000_000 * 2 << 22) / 54_000_000 >> 2)), rmOffset(10_395_000_000));
    try testing.expectEqual(@as(u32, 0x8082_8700), laneDrive(148_500_000, false));
    try testing.expectEqual(@as(u32, 0x8082_8700), laneDrive(222_000_000, true));
    try testing.expectEqual(@as(u32, 0xC087_0800), laneDrive(297_000_000, true));
    try testing.expectEqual(@as(u32, 0x848F_8700), laneDrive(340_000_000, false));
    try testing.expect(sends(148_500) and sends(297_000) and !sends(594_000) and !sends(0));
    try testing.expectEqual(@as(u64, 120_000_000), hsmHz(74_250_000));
    try testing.expectEqual(@as(u64, 149_985_000), hsmHz(148_500_000));
    try testing.expectEqual(@as(u64, 75_000_000), bvbHz(148_500_000));
    try testing.expectEqual(@as(u64, 150_000_000), bvbHz(297_000_000));
}

test "the BCM2712's display list: a picture's plane, and the cursor's cut to the picture" {
    const words = planeOf(.{ .address = 0x3000_0000, .pitch = 7680, .width = 1920, .height = 1080, .upm = 0, .handle = 0 });
    try testing.expectEqualSlices(u32, &.{
        0x4900_0000 | 3 << 18 | 1 << 15 | 2 << 13 | 7,
        0,
        0x2000_FFF0,
        1079 << 16 | 1919,
        0xC0C0_C0C0,
        0,
        0x3000_0000,
        7680,
        0x8000_0000,
    }, &words);
    // The cursor at the top left, its hot spot 4 pixels in: 4 columns and
    // rows of it are off the picture.
    const corner = cursorPlaneOf(0x1000, 64, -4, -4, 1920, 1080, true);
    try testing.expectEqual(@as(usize, 0x1000 + 4 * 256 + 4 * 4), corner.address);
    try testing.expectEqual(@as(u32, 0), corner.x);
    try testing.expectEqual(@as(u32, 60), corner.width);
    try testing.expectEqual(@as(u32, 60), corner.height);
    try testing.expectEqual(@as(u32, 256), corner.pitch);
    const cursor_words = planeOf(corner);
    try testing.expectEqual(@as(u32, 0), cursor_words[0] & 3 << 18);
    try testing.expectEqual(@as(u32, 128 << 16 | 1 << 10), cursor_words[5]);
    // At the bottom right, only the hot spot's pixel on it.
    const edge = cursorPlaneOf(0x1000, 32, 1919, 1079, 1920, 1080, true);
    try testing.expectEqual(@as(u32, 1), edge.width);
    try testing.expectEqual(@as(u32, 1), edge.height);
    try testing.expectEqual(@as(u32, 1919), edge.x);
    // Hidden: alpha 0, mixed.
    try testing.expectEqual(@as(u32, 0x3000_0000), planeOf(cursorPlaneOf(0x1000, 64, 10, 10, 1920, 1080, false))[2]);
    // A row of 1920 takes 61 units of UPM, of 4K 121, the cursor's 3:
    // both fit before the cursor's at 128.
    try testing.expectEqual(@as(u32, 61), upmUnits(7680));
    try testing.expectEqual(@as(u32, 121), upmUnits(15360));
    try testing.expectEqual(@as(u32, 3), upmUnits(256));
}

test "the BCM2712's DDC: how the pieces of a read end and start" {
    try testing.expectEqual(COND_NOSTOP, readCondition(true, false));
    try testing.expectEqual(COND_NOSTART | COND_NOSTOP, readCondition(false, false));
    try testing.expectEqual(COND_NOSTART, readCondition(false, true));
}
