// SPDX-License-Identifier: MPL-2.0
//! The BCM2712's way to its first HDMI port (CHIP_BCM2712_HVS), as the
//! Compute Module 5's IO board and the Pi 5 have it: the hardware video
//! scaler (HVS), which reads the picture out of RAM through a display
//! list and composes its planes; pixel valve 0, which times the HVS's
//! first channel out as a mode; and the HDMI0 controller with its PHY,
//! whose PLL makes the pixel clock. The monitor's EDID comes over the
//! port's DDC, a Broadcom BSC I2C controller of its own (`ddc.zig`).
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
//! clocks before anything else - the HVS's own (DISP) among them, which
//! the firmware leaves stopped where no monitor was awake as it started,
//! and which `startDisp` then asks for rather than give the display up.
//!
//! **The display list** (`list.zig`) is in the HVS's own memory, 0x4000 into its
//! registers, from word 32 on (the bootloader's are the 32 before): the
//! picture as a plane, the overlay - a dragged icon - as a second plane
//! over it, the cursor as a third over both, and the end. A plane is nine
//! words at unity scale - its control word, its position, its alpha, its
//! size, the context the HVS keeps, the picture's address in two words
//! and its pitch, and a word past it - and each takes a piece of the
//! HVS's prefetch memory (UPM) of its own. The list stays where it is
//! once the display runs: showing another picture is its address
//! rewritten in place, as Linux's asynchronous flip does it, and an
//! image's place and size are its plane's words rewritten; a hidden
//! image is a plane of alpha 0. So a picture and the images change from
//! different tasks without a lock: they write different words.
//!
//! The picture is XRGB8888, 32 bits a pixel, which is the library's
//! bgra32, below 4 GiB and out of the caches; the cursor and the overlay
//! ARGB8888 with premultiplied alpha - clear where it is 0 - as the
//! board's image buffers have them. The HVS's IOMMU is left off: it reads
//! RAM at the ARM's addresses.
//!
//! **Mirrored** (`mirror`), each plane is read backwards: a row from its
//! right end with the position word's HFLIP, the rows from the bottom up
//! with the first pointer word's VFLIP, the plane's address then the
//! start of its last row (vc6_plane_mode_set). Which way the picture is
//! turned is kept in its plane's words alone, so the cursor and the
//! overlay are turned with it wherever they are written from: each is
//! laid where the turned picture has its place, read backwards too.
//!
//! **What the monitor is sent** is eight bits a colour, so the TMDS clock
//! is the pixel clock, up to 600 MHz (`sends`): 4K at 60 Hz. A monitor
//! whose EDID names HDMI's block gets HDMI (`Output`): the AVI infoframe
//! with the mode's CEA number, and the sound's packets while it plays;
//! any other DVI. The RGB is full range wherever the monitor takes it so:
//! as DVI, in a mode CEA does not number, or where the AVI infoframe may
//! say so (its QS); else it is squashed to 16-235 on the way out, as a
//! CEA mode's RGB is taken. Past 340 MHz the TMDS characters are
//! scrambled, the monitor told so through its SCDC - registers at
//! address 0x54 on the DDC - and looked at again now and then (`tend`),
//! since a monitor forgets it when it is switched off and on.
//!
//! **Dark** (`transmit`), the controller sends blank pixels without their
//! syncs, which a monitor takes for no signal and sleeps at. Everything
//! else runs on - the PHY, the valve with the frame interrupt, the HVS,
//! the sound's FIFO - and the monitor wakes in the mode as it was once
//! the syncs come back. (The PHY's lanes powered down, or held in reset,
//! go on sending the picture.)
//!
//! **The monitor's brightness** is its own, asked over the DDC with VESA's
//! DDC/CI (`ddc.feature`, `ddc.setFeature`): its MCCS control 0x10, which a
//! monitor that takes DDC/CI at all has. One that does not answers
//! nothing.
//!
//! **The sound** (`sound.zig`) goes into the controller's MAI FIFO,
//! which the sound's driver feeds IEC 958 subframes over a DMA channel;
//! the controller sends them as audio sample packets, with the audio
//! infoframe and the numbers the monitor rebuilds the sample clock from
//! (N and CTS), which depend on the mode's pixel clock. What a mode set
//! and the sound both write is kept together (`Shared`): a mode set
//! while sound plays sets those again.
//!
//! Pixel valve 0 raises its interrupt at the start of each frame's
//! vertical front porch, which is the board's frame interrupt
//! (`takeInterrupts`).

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const videocore = sdk.hardware.videocore;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const RtgDriverBase = sdk.interface.rtgdriver.RtgDriverBase;
const rtg = sdk.rtg;
const timing = @import("timing.zig");
const ddc = @import("ddc.zig");
const sound = @import("sound.zig");
const list = @import("list.zig");

/// Whether this is built for the AArch64 machines, whose BCM2712 waking
/// the display drives. The driver is built for every chip, which picks
/// its display at run time; elsewhere the display does not wake.
pub const on_bcm2712 = sdk.hardware.chip == .a64psci;

/// Where the port is, as the board's list names it: the video scaler's
/// registers, which are the part's own address, and the port's other
/// blocks - the mailbox its clocks are asked through, the scaler's IOMMU,
/// its pixel valve, the HDMI controller's blocks, the packet RAM and the
/// DDC's master - from the table the part points at. The driver reads
/// them from its part and keeps them beside its board.
pub const Port = struct {
    hvs: usize,
    blocks: sdk.hardware.bcm2712.HdmiPort,
};

/// The VideoCore's mailbox, and what the display asks its firmware: to
/// let go of the display it drives itself, and the clocks' rates - the
/// HSM's (the firmware's M2MC clock), the BVB's, and the HVS's (DISP),
/// which the firmware keeps running.
const TAG_NOTIFY_DISPLAY_DONE: u32 = 0x0003_0066;
const TAG_GET_CLOCK_RATE: u32 = 0x0003_0002;
const TAG_GET_MAX_CLOCK_RATE: u32 = 0x0003_0004;
const TAG_SET_CLOCK_RATE: u32 = 0x0003_8002;
const CLOCK_HSM: u32 = 13;
const CLOCK_BVB: u32 = 14;
const CLOCK_DISP: u32 = 16;
/// The HSM clock runs a hundredth faster than the TMDS clock, and never
/// below 120 MHz; the BVB at 75, 150 or 300 MHz by the TMDS clock.
const HSM_MIN_HZ: u64 = 120_000_000;

/// The HVS's IOMMU, switched off: control 0.
/// The HVS: its control, its arbiter's priorities, and per channel - 0
/// is pixel valve 0's - its control words, its display list's head, its
/// share of the composite output buffer (COB) and its status.
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
pub const CTL0_END: u32 = 1 << 31;

/// Where each word is in a plane.
const W_CTL0 = 0;

/// The picture's plane first, the overlay's over it, the cursor's over
/// both, then the end.
pub const picture_plane = list_start;
pub const overlay_plane = list_start + list.plane_words;
pub const cursor_plane = list_start + 2 * list.plane_words;
const list_end = list_start + 3 * list.plane_words;

const upm_picture: u32 = 0;
pub const upm_cursor: u32 = 128;
pub const upm_overlay: u32 = 136;

/// Pixel valve 0: its control, its vertical control, the mode's timing,
/// its interrupts, the pixel mux and the pipe's start.
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

/// The DVP's clock gates, one bit for each port's 108 MHz, set to stop it.
const DVP_HDMI0_GATE: u32 = 1 << 3;

const FIFO_CTL = 0x07C;

const RAM_PACKET_CONFIG = 0x0C4;
const RAM_PACKET_STATUS = 0x0CC;

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
const SCRAMBLER_CTL = 0x1E4;
const SCRAMBLER_ENABLE: u32 = 1 << 0;
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
/// 1.0 in the CSC's 2.13 fixed point; 0.8594 of it, which with an offset
/// of 16 (in 9.6) squashes 0-255 to 16-235.
const CSC_ONE: u32 = 0x2000;
const CSC_LIMITED: u32 = 0x1B80;
const CSC_LIMITED_OFFSET: u32 = 0x0400;

const HD_DVP_CTL = 0x00;

const HD_MAI_DATA = 0x1C;
const HD_VID_CTL = 0x44;
const VID_ENABLE: u32 = 1 << 31;
const VID_UNDERFLOW_ENABLE: u32 = 1 << 30;
const VID_FRAME_COUNTER_RESET: u32 = 1 << 29;
const VID_VSYNC_LOW: u32 = 1 << 28;
const VID_HSYNC_LOW: u32 = 1 << 27;
const VID_CLRSYNC: u32 = 1 << 24;
const VID_CLRRGB: u32 = 1 << 23;
const VID_BLANKPIX: u32 = 1 << 18;
const VID_BLANK_INSERT_EN: u32 = 1 << 16;

/// HDMI0's MAI FIFO as the DMA engine reaches it, and the request line
/// it asks for data on: the 40-bit engine's DREQ 12 on the D0 stepping
/// (bcm2712d0-rpi-5-b.dts). The CM5's device tree has the C stepping's
/// 10, which the firmware's D0 overlay changes, and which no request
/// ever comes on here.
/// The packet RAM: a packet's nine words for each infoframe type, its
/// header in the first and its four subpackets of seven bytes in the
/// eight after, each four bytes then three.
const PACKET_STRIDE = 0x24;
pub const INFOFRAME_VENDOR: u8 = 0x81;
pub const INFOFRAME_AVI: u8 = 0x82;

const SCDC_SCRAMBLER_STATUS: u8 = 0x21;
pub const SCDC_SCRAMBLING: u8 = 1 << 0;

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
pub const BSC_CTL = 0x28;
pub const BSC_IIC_ENABLE = 0x2C;
pub const BSC_CTLHI = 0x50;
/// 97.5 kHz: the 390 kHz clock, divided; the data words four bytes each.
pub const BSC_CTL_97K: u32 = 1 << 4 | 1 << 7;

pub const BSC_CTLHI_WORDS: u32 = 1 << 6;

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

pub fn at(base: usize, offset: usize) *volatile u32 {
    return reg(base + offset);
}

fn hvsDisp(port: *const Port, offset: usize) *volatile u32 {
    return reg(port.hvs + DISP0 + offset);
}

pub fn word(port: *const Port, index: u32) *volatile u32 {
    return reg(port.hvs + DLIST + @as(usize, index) * 4);
}

// --- what a mode set and the sound both write --------------------------------

/// What the port keeps for a mode set and the sound, which write the
/// same things - the packet RAM's switches, the clock regeneration: a
/// semaphore held while either writes them, the mode's pixel clock,
/// whether it goes out as HDMI, and the sound playing (no channels while
/// none does). The driver keeps it beside its board, and names
/// rtg.library in it, whose calls build the AVI infoframe and work out
/// the clock regeneration.
pub const Shared = struct {
    lock: exec.SignalSemaphore = .{},
    rtg_base: ?*RtgDriverBase = null,
    pixel_khz: u32 = 0,
    hdmi: bool = false,
    audio_rate: u32 = 0,
    audio_channels: u32 = 0,
};

// --- the firmware ------------------------------------------------------------

/// The firmware asked `tag` with `value`: whether it answered. The
/// message's buffer is RAM it reaches, taken for the call.
fn ask(port: *const Port, sys: *ExecBase, tag: u32, value: []u32) bool {
    const memory = sys.AllocMem(videocore.buffer_bytes * 2, exec.MEMF_DMA | exec.MEMF_CLEAR) orelse return false;
    defer sys.FreeMem(memory, videocore.buffer_bytes * 2);
    const buffer = videocore.bufferIn(memory) orelse return false;
    return videocore.call(sys, port.blocks.mailbox, buffer, tag, value);
}

/// Clock `clock` set to `hz`: whether the firmware took it.
fn setClock(port: *const Port, sys: *ExecBase, clock: u32, hz: u64) bool {
    var value = [3]u32{ clock, @intCast(hz), 0 };
    return ask(port, sys, TAG_SET_CLOCK_RATE, &value) and value[1] != 0;
}

/// Clock `clock`'s rate; 0 while it is stopped, null when the firmware
/// does not say.
fn clockRate(port: *const Port, sys: *ExecBase, clock: u32) ?u32 {
    var value = [2]u32{ clock, 0 };
    if (!ask(port, sys, TAG_GET_CLOCK_RATE, &value)) return null;
    return value[1];
}

/// Clock `clock` running at `hz` at least: set to it when it is slower.
fn atLeast(port: *const Port, sys: *ExecBase, clock: u32, hz: u64) bool {
    const now = clockRate(port, sys, clock) orelse return false;
    return now >= hz or setClock(port, sys, clock, hz);
}

/// The fastest the firmware gives for clock `clock`; null when it does
/// not say.
fn maxClockRate(port: *const Port, sys: *ExecBase, clock: u32) ?u32 {
    var value = [2]u32{ clock, 0 };
    if (!ask(port, sys, TAG_GET_MAX_CLOCK_RATE, &value)) return null;
    return value[1];
}

/// The HVS's own clock started where it is stopped, at the fastest rate
/// the firmware gives for it: the compositor reads and writes memory on
/// it, and no mode depends on which rate it is. The firmware stops it
/// where it found no monitor awake as it started - which a machine that
/// starts from its own medium does in the second after the power comes
/// on, long before a monitor that was asleep answers - and the display
/// is then asked for rather than given up on.
fn startDisp(port: *const Port, sys: *ExecBase) bool {
    const most = maxClockRate(port, sys, CLOCK_DISP) orelse return false;
    if (most == 0) return false;
    return setClock(port, sys, CLOCK_DISP, most) and (clockRate(port, sys, CLOCK_DISP) orelse 0) != 0;
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
fn clocksFor(port: *const Port, sys: *ExecBase, tmds_hz: u64) bool {
    return setClock(port, sys, CLOCK_HSM, hsmHz(tmds_hz)) and setClock(port, sys, CLOCK_BVB, bvbHz(tmds_hz));
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
pub fn wake(port: *const Port, sys: *ExecBase, waiter: anytype) Failure {
    _ = waiter;
    if (!on_bcm2712) return .firmware;
    // Firmware that does not know the tag has no display of its own to
    // let go of.
    var none = [0]u32{};
    _ = ask(port, sys, TAG_NOTIFY_DISPLAY_DONE, &none);
    if ((clockRate(port, sys, CLOCK_DISP) orelse 0) == 0 and !startDisp(port, sys)) return .firmware;
    if (!atLeast(port, sys, CLOCK_HSM, hsmHz(0)) or !atLeast(port, sys, CLOCK_BVB, bvbHz(0))) return .firmware;
    at(port.blocks.dvp_gates, 0).* &= ~DVP_HDMI0_GATE;
    // The DDC (brcmstb_i2c_set_bsc_reg_defaults): four bytes a data word,
    // 97.5 kHz, nothing under way.
    at(port.blocks.ddc, BSC_CTLHI).* = BSC_CTLHI_WORDS;
    at(port.blocks.ddc, BSC_CTL).* = BSC_CTL_97K;
    at(port.blocks.ddc, BSC_IIC_ENABLE).* = 0;
    return .none;
}

/// Whether the HVS's first channel runs this driver's list.
pub fn running(port: *const Port) bool {
    return hvsDisp(port, DISP_CTRL0).* & CTRL0_ENB != 0 and hvsDisp(port, DISP_LPTRS).* & 0xFFF == list_start;
}

/// Whether a monitor is on the port: the controller's hot-plug line.
/// Only once `wake` has its clocks running.
pub fn monitor(port: *const Port) bool {
    if (!on_bcm2712) return false;
    return at(port.blocks.hdmi, HOTPLUG).* & HOTPLUG_CONNECTED != 0;
}

// --- the PHY -----------------------------------------------------------------

/// The port's fastest TMDS clock, in kHz, scrambled past 340 MHz
/// (Linux's max_pixel_clock for the BCM2712's HDMI0).
const max_khz: u32 = 600_000;

/// Whether the port can send a mode of that pixel clock - to a monitor
/// that takes it, which the library sees to.
pub fn sends(pixel_khz: u32) bool {
    return pixel_khz != 0 and pixel_khz <= max_khz;
}

/// The widest picture the HVS's composite output buffer is laid out for
/// (`hvsStart`).
const widest: u32 = 3840;

/// Whether the port can make `mode`: its pixel clock one it sends
/// (`sends`), progressive, a picture the HVS's buffer is laid out for,
/// and its vertical figures ones the controller's registers hold - the
/// sync in five bits, the front porch in seven, the back porch in nine.
pub fn makes(mode: *const rtg.RtgTimings) bool {
    if (!sends(timing.khz(mode))) return false;
    if (mode.flags & rtg.modes.RTGTM_INTERLACED != 0) return false;
    if (mode.h_active == 0 or mode.v_active == 0) return false;
    if (mode.h_active > widest or mode.v_active > 0xFFFF) return false;
    if (mode.h_front > 0xFFFF or mode.h_sync > 0xFFFF or mode.h_back > 0xFFFF) return false;
    return mode.v_sync <= 0x1F and mode.v_front <= 0x7F and mode.v_back <= 0x1FF;
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
fn phyStart(port: *const Port, tmds_hz: u64) void {
    const div = vcoDivider(tmds_hz);
    const vco = tmds_hz * div * 10;
    at(port.blocks.phy, PHY_RESET_CTL).* = 0;
    at(port.blocks.phy, PHY_POWERUP_CTL).* = 0;
    at(port.blocks.phy, PHY_PLL_POST_KDIV).* = PHY_KDIV_BYPASS;
    for (pll_misc, 0..) |value, i| at(port.blocks.phy, PHY_PLL_MISC_0 + i * 4).* = value;
    at(port.blocks.phy, PHY_PLL_REFCLK).* = PHY_REFCLK_CMOS_54;
    at(port.blocks.phy, PHY_RESET_CTL).* = 0x7F;
    at(port.blocks.rate_manager, RM_OFFSET).* = RM_OFFSET_ONLY | rmOffset(vco);
    at(port.blocks.phy, PHY_PLL_VCOCLK_DIV).* = PHY_VCODIV_EN | div;
    at(port.blocks.phy, PHY_PLL_CFG).* = 0;
    at(port.blocks.phy, PHY_PLL_POST_KDIV).* = PHY_KDIV_RUN;
    at(port.blocks.phy, PHY_CTL_0).* = laneDrive(tmds_hz, false);
    at(port.blocks.phy, PHY_CTL_1).* = laneDrive(tmds_hz, false);
    at(port.blocks.phy, PHY_CTL_2).* = laneDrive(tmds_hz, false);
    at(port.blocks.phy, PHY_CTL_CK).* = laneDrive(tmds_hz, true);
    at(port.blocks.phy, PHY_TMDS_CLK_WORD_SEL).* = if (tmds_hz >= 340_000_000) 3 else 0;
    at(port.blocks.phy, PHY_POWERUP_CTL).* = PHY_POWERUP_ALL;
    at(port.blocks.phy, PHY_PLL_POWERUP_CTL).* = 1;
    at(port.blocks.phy, PHY_PLL_RESET_CTL).* &= ~PHY_PLL_RESETB;
    at(port.blocks.phy, PHY_PLL_RESET_CTL).* |= PHY_PLL_RESETB;
}

// --- what the monitor is sent ------------------------------------------------

/// How a mode goes to a monitor: as HDMI or DVI; its RGB squashed to
/// 16-235 or not; the range said in the AVI infoframe or left to the
/// monitor's default; the TMDS scrambled.
pub const Output = struct {
    hdmi: bool,
    limited: bool,
    range_said: bool,
    scrambled: bool,
};

/// The fastest TMDS clock that goes unscrambled, HDMI 1.4's, in kHz.
const hdmi14_khz: u32 = 340_000;

/// What the monitor says of itself that decides how a mode goes to it
/// (`rtg.RtgMonitorInfo.flags`): whether it takes HDMI's packets, whether
/// its RGB range may be chosen, and whether it is an HDMI 2.0 monitor.
pub const Sink = struct {
    hdmi: bool = false,
    quant_selectable: bool = false,
    forum: bool = false,

    /// What `GetBoardMonitor` answered, as the port reads it.
    pub fn of(said: *const rtg.RtgMonitorInfo) Sink {
        return .{
            .hdmi = said.flags & rtg.modes.RTGMON_HDMI != 0,
            .quant_selectable = said.flags & rtg.modes.RTGMON_RANGE_SELECTABLE != 0,
            .forum = said.flags & rtg.modes.RTGMON_HDMI2 != 0,
        };
    }
};

/// How `mode` goes to the monitor `sink` says it is. A CEA mode but the
/// first is taken as limited range unless the AVI infoframe says
/// otherwise, which it may where the monitor lets it (QS).
pub fn outputFor(sink: Sink, mode: *const rtg.RtgTimings) Output {
    const cea_limited = sink.hdmi and mode.vic > 1;
    return .{
        .hdmi = sink.hdmi,
        .limited = cea_limited and !sink.quant_selectable,
        .range_said = sink.hdmi and sink.quant_selectable,
        .scrambled = timing.khz(mode) > hdmi14_khz,
    };
}

/// An infoframe as the packet RAM takes it: its type, version and length,
/// its checksum - which brings the sum of all its bytes to 0 - and its
/// bytes, up to 27, the rest 0.
pub const Infoframe = [31]u8;

pub fn infoframe(kind: u8, version: u8, body: []const u8) Infoframe {
    var frame: Infoframe = @splat(0);
    frame[0] = kind;
    frame[1] = version;
    frame[2] = @intCast(body.len);
    @memcpy(frame[4..][0..body.len], body);
    var sum: u8 = 0;
    for (frame) |byte| sum +%= byte;
    frame[3] = 0 -% sum;
    return frame;
}

/// HDMI 1.4's numbers for the 4K modes it sends in its vendor infoframe
/// rather than the AVI infoframe - to a monitor that is not HDMI 2.0 -
/// by their CEA numbers; 0 for any other mode.
pub fn hdmiVic(vic: u8) u8 {
    return switch (vic) {
        95 => 1,
        94 => 2,
        93 => 3,
        98 => 4,
        else => 0,
    };
}

/// The CEA number the AVI infoframe carries for `mode`: none for a mode
/// HDMI 1.4's vendor infoframe carries instead.
fn aviVic(sink: Sink, mode: *const rtg.RtgTimings) u8 {
    if (!sink.forum and hdmiVic(mode.vic) != 0) return 0;
    return mode.vic;
}

/// What the AVI infoframe for `mode` says beyond its picture, as
/// `BuildAviInfoFrame` takes it: the range when it is said, and no number
/// for a mode the vendor infoframe carries instead.
pub fn aviFlags(sink: Sink, mode: *const rtg.RtgTimings, output: Output) u32 {
    var flags: u32 = 0;
    if (output.range_said) flags |= if (output.limited) rtg.RTGAVI_RANGE_LIMITED else rtg.RTGAVI_RANGE_FULL;
    if (aviVic(sink, mode) == 0) flags |= rtg.RTGAVI_NO_VIC;
    return flags;
}

/// The AVI infoframe for `mode`, as rtg.library builds it: RGB, the
/// picture's aspect, the active part the whole picture, the range when it
/// is said, the mode's number. All zeroes without the library.
fn aviFrame(shared: *const Shared, sink: Sink, mode: *const rtg.RtgTimings, output: Output) Infoframe {
    var frame: Infoframe = @splat(0);
    if (shared.rtg_base) |rb| _ = rb.BuildAviInfoFrame(mode, aviFlags(sink, mode, output), &frame);
    return frame;
}

/// HDMI's vendor infoframe naming HDMI 1.4's 4K mode `hdmi_vic`.
pub fn vendorFrame(hdmi_vic: u8) Infoframe {
    return infoframe(INFOFRAME_VENDOR, 1, &.{ 0x03, 0x0C, 0x00, 0x20, hdmi_vic });
}

/// The packet `frame` into the packet RAM and sent with every frame from
/// now on (vc4_hdmi_write_infoframe): its sending stopped and waited out,
/// its nine words written, then sent again. The packet RAM must be on.
pub fn writePacket(port: *const Port, frame: *const Infoframe, waiter: anytype) void {
    const id: u5 = @intCast(frame[0] - 0x80);
    const bit = @as(u32, 1) << id;
    stopPacket(port, frame[0], waiter);
    const first = port.blocks.packets + @as(usize, id) * PACKET_STRIDE;
    var i: usize = 0;
    while (i < 28) : (i += 7) {
        const pair = first + i / 7 * 8;
        reg(pair).* = @as(u32, frame[i]) | @as(u32, frame[i + 1]) << 8 | @as(u32, frame[i + 2]) << 16;
        reg(pair + 4).* = @as(u32, frame[i + 3]) | @as(u32, frame[i + 4]) << 8 | @as(u32, frame[i + 5]) << 16 | @as(u32, frame[i + 6]) << 24;
    }
    reg(first + 32).* = 0;
    at(port.blocks.hdmi, RAM_PACKET_CONFIG).* |= bit;
    waitBits(at(port.blocks.hdmi, RAM_PACKET_STATUS), bit, true, 100, waiter);
}

/// The packet of type `kind` no longer sent, waited out.
pub fn stopPacket(port: *const Port, kind: u8, waiter: anytype) void {
    const bit = @as(u32, 1) << @as(u5, @intCast(kind - 0x80));
    at(port.blocks.hdmi, RAM_PACKET_CONFIG).* &= ~bit;
    waitBits(at(port.blocks.hdmi, RAM_PACKET_STATUS), bit, false, 100, waiter);
}

// --- starting ----------------------------------------------------------------

/// The display taken down, if it runs: pixel valve 0 stopped at the end
/// of a frame, the controller's packets and picture blanked, the
/// scrambling off at both ends, the valve's FIFO cleared and the HVS's
/// channel reset (vc4_crtc_disable).
fn stop(port: *const Port, waiter: anytype) void {
    if (at(port.blocks.pixel_valve, PV_V_CONTROL).* & PV_VCONTROL_VIDEN != 0) {
        at(port.blocks.pixel_valve, PV_V_CONTROL).* &= ~PV_VCONTROL_VIDEN;
        waiter.wait(20_000);
    }
    at(port.blocks.hdmi, RAM_PACKET_CONFIG).* = 0;
    if (at(port.blocks.hdmi, SCRAMBLER_CTL).* & SCRAMBLER_ENABLE != 0) {
        at(port.blocks.hdmi, SCRAMBLER_CTL).* &= ~SCRAMBLER_ENABLE;
        _ = ddc.scdcScrambling(port, false, waiter);
    }
    at(port.blocks.hd, HD_VID_CTL).* |= VID_CLRRGB | VID_BLANKPIX;
    at(port.blocks.pixel_valve, PV_INTEN).* = 0;
    at(port.blocks.pixel_valve, PV_CONTROL).* &= ~PV_CONTROL_EN;
    at(port.blocks.pixel_valve, PV_CONTROL).* |= PV_CONTROL_FIFO_CLR;
    if (hvsDisp(port, DISP_CTRL0).* & CTRL0_ENB != 0) {
        hvsDisp(port, DISP_CTRL0).* |= CTRL0_RESET;
        hvsDisp(port, DISP_CTRL0).* &= ~CTRL0_ENB;
    }
}

/// The HVS on, its IOMMU off, and the composite output buffer shared
/// between its three channels, four lines of 3840 for each of the first
/// two (vc6_hvs_hw_init, vc4_hvs_cob_init).
fn hvsStart(port: *const Port) void {
    at(port.blocks.iommu, 0).* = 0;
    at(port.hvs, HVS_CONTROL).* = CONTROL_HVS_EN | 8 << CONTROL_PF_LINES_SHIFT | 15 << CONTROL_MAX_REQS_SHIFT;
    at(port.hvs, PRI_MAP0).* = 0xFFFF_FFFF;
    at(port.hvs, PRI_MAP1).* = 0xFFFF_FFFF;
    var top: u32 = widest;
    reg(port.hvs + DISP0 + 2 * DISP_STRIDE + DISP_COB).* = top << 16;
    var base = top + 16;
    top += widest * 4;
    reg(port.hvs + DISP0 + DISP_STRIDE + DISP_COB).* = top << 16 | base;
    base = top + 16;
    top += widest * 4;
    hvsDisp(port, DISP_COB).* = top << 16 | base;
}

/// The controller's timing for `mode` (vc5_hdmi_set_timings), eight bits
/// a colour, no pixel doubling.
fn hdmiTiming(port: *const Port, mode: *const rtg.RtgTimings) void {
    var horza = mode.h_active | mode.h_front << 16;
    if (timing.vsyncHigh(mode)) horza |= HORZA_VPOS;
    if (timing.hsyncHigh(mode)) horza |= HORZA_HPOS;
    at(port.blocks.hdmi, H_HORZA).* = horza;
    at(port.blocks.hdmi, H_HORZB).* = mode.h_back << 16 | mode.h_sync;
    const verta = (mode.v_sync & 0x1F) << 24 | (mode.v_front & 0x7F) << 16 | mode.v_active;
    at(port.blocks.hdmi, H_VERTA0).* = verta;
    at(port.blocks.hdmi, H_VERTA1).* = verta;
    at(port.blocks.hdmi, H_VERTB0).* = mode.v_back & 0x1FF;
    at(port.blocks.hdmi, H_VERTB1).* = (timing.htotal(mode) >> 1) << 16 | (mode.v_back & 0x1FF);
    at(port.blocks.hdmi, DEEP_COLOR_CONFIG_1).* = at(port.blocks.hdmi, DEEP_COLOR_CONFIG_1).* & ~@as(u32, 0x70F) | 2 << 8;
    at(port.blocks.hdmi, GCP_WORD_1).* = at(port.blocks.hdmi, GCP_WORD_1).* & ~@as(u32, 0xFFFF) | GCP_CLEAR_AVMUTE;
    at(port.blocks.hdmi, GCP_CONFIG).* |= GCP_ENABLE;
    at(port.blocks.hdmi, MISC_CONTROL).* &= ~@as(u32, 0xF);
    at(port.blocks.dvp, DVP_CLOCK_STOP).* = 0;
}

/// Pixel valve 0's timing for `mode` (vc4_crtc_config_pv): progressive,
/// a pixel a clock, 24 bits from the HDMI controller's clock.
fn pvTiming(port: *const Port, mode: *const rtg.RtgTimings) void {
    at(port.blocks.pixel_valve, PV_CONTROL).* &= ~PV_CONTROL_EN;
    at(port.blocks.pixel_valve, PV_CONTROL).* |= PV_CONTROL_FIFO_CLR;
    at(port.blocks.pixel_valve, PV_HORZA).* = mode.h_back << 16 | mode.h_sync;
    at(port.blocks.pixel_valve, PV_HORZB).* = mode.h_front << 16 | mode.h_active;
    at(port.blocks.pixel_valve, PV_V_CONTROL).* = PV_VCONTROL_CONTINUOUS | PV_VCONTROL_ODD_TIMING;
    at(port.blocks.pixel_valve, PV_VSYNCD_EVEN).* = 0;
    at(port.blocks.pixel_valve, PV_VERTA).* = mode.v_back << 16 | mode.v_sync;
    at(port.blocks.pixel_valve, PV_VERTB).* = mode.v_front << 16 | mode.v_active;
    at(port.blocks.pixel_valve, PV_MUX_CFG).* = PV_MUX_NO_SWAP;
    at(port.blocks.pixel_valve, PV_PIPE_INIT_CTRL).* = PV_PIPE_INIT;
    at(port.blocks.pixel_valve, PV_CONTROL).* = PV_CONTROL_FIFO_CLR |
        (pv_fifo_level & 0x3F) << PV_CONTROL_FIFO_LEVEL_SHIFT |
        (pv_fifo_level >> 6) << PV_CONTROL_FIFO_LEVEL_HIGH_SHIFT |
        PV_CONTROL_CLR_AT_START | PV_CONTROL_TRIGGER_UNDERFLOW | PV_CONTROL_WAIT_HSTART;
}

/// RGB through the controller's CSC, unchanged or squashed to 16-235
/// (vc5_hdmi_csc_setup, vc5_hdmi_csc_full_rgb_to_rgb).
fn hdmiColours(port: *const Port, limited: bool) void {
    const scale = if (limited) CSC_LIMITED else CSC_ONE;
    const offset = if (limited) CSC_LIMITED_OFFSET else 0;
    at(port.blocks.dvp, DVP_VEC_INTERFACE_CFG).* = 0;
    at(port.blocks.dvp, DVP_VEC_INTERFACE_XBAR).* = XBAR_RGB;
    at(port.blocks.csc, CSC_12_11).* = scale;
    at(port.blocks.csc, CSC_14_13).* = offset << 16;
    at(port.blocks.csc, CSC_22_21).* = scale << 16;
    at(port.blocks.csc, CSC_24_23).* = offset << 16;
    at(port.blocks.csc, CSC_32_31).* = 0;
    at(port.blocks.csc, CSC_34_33).* = offset << 16 | scale;
    at(port.blocks.csc, CSC_CHANNEL_CTL).* = 0;
    at(port.blocks.csc, CSC_CTL).* = CSC_ENABLE_CUSTOM;
}

/// Until `bits` of `register` are `set` or not, `tries` milliseconds at
/// most.
fn waitBits(register: *volatile u32, bits: u32, set: bool, tries: u32, waiter: anytype) void {
    var waited: u32 = 0;
    while ((register.* & bits != 0) != set and waited < tries) : (waited += 1) waiter.wait(1000);
}

/// The display brought up in `mode` - its pixel clock one the port sends
/// (`sends`) and the monitor `sink` takes - showing the picture at
/// `address`, 32 bits a pixel, rows `pitch` bytes apart, below 4 GiB and
/// out of the caches, unturned; the cursor and the overlay hidden, and
/// the monitor sent the picture. With the display up, it changes
/// to `mode`; sound that plays goes on in it. The order is
/// vc4_crtc_atomic_enable's. `waiter.wait(micros)` waits that long.
pub fn start(port: *const Port, sys: *ExecBase, shared: *Shared, mode: *const rtg.RtgTimings, sink: Sink, address: usize, pitch: u32, waiter: anytype) Failure {
    if (!on_bcm2712) return .firmware;
    if (!sends(timing.khz(mode))) return .clock;
    const woken = wake(port, sys, waiter);
    if (woken != .none) return woken;
    sys.ObtainSemaphore(&shared.lock);
    defer sys.ReleaseSemaphore(&shared.lock);
    const output = outputFor(sink, mode);
    const tmds_hz = @as(u64, timing.khz(mode)) * 1000;
    stop(port, waiter);
    if (!clocksFor(port, sys, tmds_hz)) return .firmware;

    // The controller reset (vc5_hdmi_reset), the HVS's channel 0 on with
    // the list: the picture, and the overlay and the cursor hidden over
    // it.
    at(port.blocks.hd, HD_DVP_CTL).* = 0;
    at(port.blocks.dvp, DVP_CLOCK_STOP).* |= CLOCK_STOP_PIXEL;
    hvsStart(port);
    list.writePlane(port, picture_plane, .{ .address = address, .pitch = pitch, .width = mode.h_active, .height = mode.v_active, .upm = upm_picture, .handle = 0 });
    list.writePlane(port, overlay_plane, .{ .address = address, .pitch = 4, .width = 1, .height = 1, .upm = upm_overlay, .handle = 2, .alpha = true, .seen = false });
    list.writePlane(port, cursor_plane, .{ .address = address, .pitch = 4, .width = 1, .height = 1, .upm = upm_cursor, .handle = 1, .alpha = true, .seen = false });
    word(port, list_end).* = CTL0_END;
    hvsDisp(port, DISP_LPTRS).* = list_start;
    hvsDisp(port, DISP_CTRL0).* = CTRL0_RESET;
    hvsDisp(port, DISP_CTRL1).* &= ~CTRL1_INTLACE;
    hvsDisp(port, DISP_CTRL0).* = CTRL0_ENB | (mode.h_active - 1) << CTRL0_FWIDTH_SHIFT | (mode.v_active - 1);

    // The controller's PHY and timing, the valve's, the colours, then the
    // video let through (pre_crtc_configure, config_pv, pre_crtc_enable,
    // post_crtc_enable), as HDMI with its infoframes or as DVI.
    phyStart(port, tmds_hz);
    at(port.blocks.hdmi, SCHEDULER_CONTROL).* |= SCHEDULER_MANUAL_FORMAT | SCHEDULER_IGNORE_VSYNC_PREDICTS;
    hdmiTiming(port, mode);
    pvTiming(port, mode);
    at(port.blocks.pixel_valve, PV_CONTROL).* |= PV_CONTROL_EN;
    hdmiColours(port, output.limited);
    at(port.blocks.hdmi, FIFO_CTL).* = FIFO_MASTER_SLAVE_N;
    at(port.blocks.pixel_valve, PV_V_CONTROL).* |= PV_VCONTROL_VIDEN;
    var video = at(port.blocks.hd, HD_VID_CTL).* & ~(VID_VSYNC_LOW | VID_HSYNC_LOW);
    video |= VID_ENABLE | VID_CLRRGB | VID_UNDERFLOW_ENABLE | VID_FRAME_COUNTER_RESET | VID_BLANK_INSERT_EN;
    if (!timing.vsyncHigh(mode)) video |= VID_VSYNC_LOW;
    if (!timing.hsyncHigh(mode)) video |= VID_HSYNC_LOW;
    at(port.blocks.hd, HD_VID_CTL).* = video;
    at(port.blocks.hd, HD_VID_CTL).* &= ~VID_BLANKPIX;
    if (output.hdmi) {
        at(port.blocks.hdmi, SCHEDULER_CONTROL).* |= SCHEDULER_MODE_HDMI;
        waitBits(at(port.blocks.hdmi, SCHEDULER_CONTROL), SCHEDULER_HDMI_ACTIVE, true, 1000, waiter);
        at(port.blocks.hdmi, RAM_PACKET_CONFIG).* = RAM_PACKET_ENABLE;
        writePacket(port, &aviFrame(shared, sink, mode, output), waiter);
        if (!sink.forum and hdmiVic(mode.vic) != 0) writePacket(port, &vendorFrame(hdmiVic(mode.vic)), waiter);
    } else {
        at(port.blocks.hdmi, RAM_PACKET_CONFIG).* &= ~RAM_PACKET_ENABLE;
        at(port.blocks.hdmi, SCHEDULER_CONTROL).* &= ~SCHEDULER_MODE_HDMI;
        waitBits(at(port.blocks.hdmi, SCHEDULER_CONTROL), SCHEDULER_HDMI_ACTIVE, false, 1000, waiter);
    }
    recenter(port, waiter);
    // Past 340 MHz, the monitor told before the scrambler starts
    // (vc4_hdmi_enable_scrambling).
    if (output.scrambled) {
        _ = ddc.scdcScrambling(port, true, waiter);
        at(port.blocks.hdmi, SCRAMBLER_CTL).* |= SCRAMBLER_ENABLE;
    }

    // The sound that plays, sent in the new mode: its clock regeneration
    // from the new pixel clock, its infoframe again.
    shared.pixel_khz = timing.khz(mode);
    shared.hdmi = output.hdmi;
    if (output.hdmi and shared.audio_channels != 0) {
        sound.regenerate(port, shared);
        writePacket(port, &sound.audioFrame(shared.audio_channels), waiter);
    }

    // The frame interrupt: the start of each vertical front porch.
    at(port.blocks.pixel_valve, PV_INTSTAT).* = PV_INT_VFP_START;
    at(port.blocks.pixel_valve, PV_INTEN).* = PV_INT_VFP_START;
    return .none;
}

/// What a running display needs now and then, about once a second: the
/// monitor's scrambling turned on again when it has lost it, as it does
/// when it is switched off and on (vc4_hdmi_scrambling_wq).
pub fn tend(port: *const Port, waiter: anytype) void {
    if (!on_bcm2712 or !running(port) or !transmitting(port)) return;
    if (at(port.blocks.hdmi, SCRAMBLER_CTL).* & SCRAMBLER_ENABLE == 0) return;
    const status = ddc.scdcRead(port, SCDC_SCRAMBLER_STATUS, waiter) orelse return;
    if (status & SCDC_SCRAMBLING == 0) _ = ddc.scdcScrambling(port, true, waiter);
}

/// The controller's FIFO centred between the valve and the PHY, twice a
/// millisecond apart (vc4_hdmi_recenter_fifo).
fn recenter(port: *const Port, waiter: anytype) void {
    const fifo = at(port.blocks.hdmi, FIFO_CTL);
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
pub fn takeInterrupts(port: *const Port) u32 {
    const raised = at(port.blocks.pixel_valve, PV_INTSTAT).* & at(port.blocks.pixel_valve, PV_INTEN).*;
    if (raised != 0) at(port.blocks.pixel_valve, PV_INTSTAT).* = raised;
    return raised;
}

/// The monitor sent the picture, or blank pixels without syncs - no
/// signal, to a monitor. CLRSYNC reads back as 0 and holds only while it
/// is written, so the picture is back as soon as a write leaves it out.
pub fn transmit(port: *const Port, on: bool) void {
    if (!running(port)) return;
    const video = at(port.blocks.hd, HD_VID_CTL);
    video.* = if (on) video.* & ~(VID_CLRSYNC | VID_BLANKPIX) else video.* | VID_CLRSYNC | VID_BLANKPIX;
}

/// Whether the monitor is sent the picture.
fn transmitting(port: *const Port) bool {
    return at(port.blocks.hd, HD_VID_CTL).* & VID_BLANKPIX == 0;
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
    try testing.expectEqual(@as(u32, 0x848F_8700), laneDrive(594_000_000, false));
    try testing.expect(sends(148_500) and sends(297_000) and sends(594_000) and !sends(600_001) and !sends(0));
    try testing.expectEqual(@as(u64, 120_000_000), hsmHz(74_250_000));
    try testing.expectEqual(@as(u64, 149_985_000), hsmHz(148_500_000));
    try testing.expectEqual(@as(u64, 75_000_000), bvbHz(148_500_000));
    try testing.expectEqual(@as(u64, 150_000_000), bvbHz(297_000_000));
}

test "what a monitor is sent: HDMI with its range said, limited without QS, DVI full" {
    const portable: Sink = .{ .hdmi = true, .quant_selectable = true };
    const full_hd: rtg.RtgTimings = .{ .pixel_clock_hz = 148_500_000, .h_active = 1920, .v_active = 1080, .vic = 16 };
    const output = outputFor(portable, &full_hd);
    try testing.expect(output.hdmi and !output.limited and output.range_said and !output.scrambled);
    // The AVI infoframe says the range, full.
    try testing.expectEqual(rtg.RTGAVI_RANGE_FULL, aviFlags(portable, &full_hd, output));

    // A monitor without QS takes a CEA mode's RGB limited, and is not
    // told; 640x480 (VIC 1) stays full.
    const plain: Sink = .{ .hdmi = true };
    const squashed = outputFor(plain, &full_hd);
    try testing.expect(squashed.limited and !squashed.range_said);
    try testing.expectEqual(@as(u32, 0), aviFlags(plain, &full_hd, squashed));
    const vga: rtg.RtgTimings = .{ .pixel_clock_hz = 25_175_000, .h_active = 640, .v_active = 480, .vic = 1 };
    try testing.expect(!outputFor(plain, &vga).limited);

    // DVI: no infoframes, full range.
    const dvi: Sink = .{};
    const as_dvi = outputFor(dvi, &full_hd);
    try testing.expect(!as_dvi.hdmi and !as_dvi.limited and !as_dvi.range_said);

    // 4K60 is scrambled.
    const uhd60: rtg.RtgTimings = .{ .pixel_clock_hz = 594_000_000, .h_active = 3840, .v_active = 2160, .vic = 97 };
    try testing.expect(outputFor(portable, &uhd60).scrambled);
}

test "HDMI 1.4's 4K modes go in the vendor infoframe, HDMI 2.0's in the AVI's" {
    const uhd30: rtg.RtgTimings = .{ .pixel_clock_hz = 297_000_000, .h_active = 3840, .v_active = 2160, .vic = 95 };
    try testing.expectEqual(@as(u8, 95), uhd30.vic);
    try testing.expectEqual(@as(u8, 1), hdmiVic(uhd30.vic));
    const older: Sink = .{ .hdmi = true };
    try testing.expect(aviFlags(older, &uhd30, outputFor(older, &uhd30)) & rtg.RTGAVI_NO_VIC != 0);
    var newer = older;
    newer.forum = true;
    try testing.expectEqual(@as(u32, 0), aviFlags(newer, &uhd30, outputFor(newer, &uhd30)) & rtg.RTGAVI_NO_VIC);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x01, 0x05, 0x49, 0x03, 0x0C, 0x00, 0x20, 0x01, 0 }, vendorFrame(1)[0..10]);
}

test "what the port makes: its clock, a picture its buffer holds, the controller's vertical fields" {
    var mode: rtg.RtgTimings = .{ .pixel_clock_hz = 148_500_000, .h_active = 1920, .h_front = 88, .h_sync = 44, .h_back = 148, .v_active = 1080, .v_front = 4, .v_sync = 5, .v_back = 36 };
    try testing.expect(makes(&mode));
    mode.pixel_clock_hz = 601_000_000;
    try testing.expect(!makes(&mode));
    mode.pixel_clock_hz = 148_500_000;
    mode.h_active = 4096;
    try testing.expect(!makes(&mode));
    mode.h_active = 0;
    try testing.expect(!makes(&mode));
    mode.h_active = 1920;
    mode.v_sync = 32;
    try testing.expect(!makes(&mode));
    mode.v_sync = 5;
    mode.v_back = 512;
    try testing.expect(!makes(&mode));
    mode.v_back = 36;
    mode.flags = rtg.modes.RTGTM_INTERLACED;
    try testing.expect(!makes(&mode));
}
