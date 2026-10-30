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
//! DDC/CI (`feature`, `setFeature`): its MCCS control 0x10, which a
//! monitor that takes DDC/CI at all has. One that does not answers
//! nothing.
//!
//! **The sound** (`audioStart`) goes into the controller's MAI FIFO,
//! which a DMA channel feeds IEC 958 subframes (rta-hdmi's
//! `rta_driver/hdmi/bcm2712.zig`); the controller sends them as audio
//! sample packets, with the audio infoframe and the numbers the monitor
//! rebuilds the sample clock from (N and CTS), which depend on the
//! mode's pixel clock. The display and its sound share what both write
//! (`Shared`): a mode set while sound plays sets those again.
//!
//! Pixel valve 0 raises its interrupt at the start of each frame's
//! vertical front porch, which is the board's frame interrupt
//! (`takeInterrupts`).

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
/// The picture's plane first, the overlay's over it, the cursor's over
/// both, then the end.
const picture_plane = list_start;
const overlay_plane = list_start + plane_words;
const cursor_plane = list_start + 2 * plane_words;
const list_end = list_start + 3 * plane_words;
/// A plane read backwards: each row (in its position word), and the rows
/// (in its first pointer word).
const POS0_HFLIP: u32 = 1 << 15;
const PTR0_VFLIP: u32 = 1 << 31;

/// The HVS's prefetch memory, in units of 256 bytes, two lines a plane:
/// the picture's from 0 - room for a row of 4K - then the cursor's and
/// the overlay's, each as a handle of its own.
const UPM_UNIT = 256;
const upm_picture: u32 = 0;
const upm_cursor: u32 = 128;
const upm_overlay: u32 = 136;

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
const MAI_CHANNEL_MAP = 0x0A4;
const MAI_CONFIG = 0x0A8;
const AUDIO_PACKET_CONFIG = 0x0C0;
const RAM_PACKET_CONFIG = 0x0C4;
const RAM_PACKET_STATUS = 0x0CC;
const CRP_CFG = 0x0D0;
const CTS_0 = 0x0D4;
const CTS_1 = 0x0D8;
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
const HD_MAI_CTL = 0x10;
const HD_MAI_THR = 0x14;
const HD_MAI_FMT = 0x18;
const HD_MAI_DATA = 0x1C;
const HD_MAI_SMP = 0x20;
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

/// The MAI, the sound's way in: its control, its FIFO's thresholds for
/// the DMA's request and for panic, the stream's format, the FIFO's
/// data word and its sample clock - 108 MHz times M over N.
const MAI_RESET: u32 = 1 << 0;
const MAI_ERRORF: u32 = 1 << 1;
const MAI_ERRORE: u32 = 1 << 2;
const MAI_ENABLE: u32 = 1 << 3;
const MAI_CHNUM_SHIFT = 4;
const MAI_FLUSH: u32 = 1 << 9;
const MAI_WHOLSMP: u32 = 1 << 12;
const MAI_CHALIGN: u32 = 1 << 13;
const MAI_DLATE: u32 = 1 << 15;
const MAI_THRESHOLDS: u32 = 0x10 << 23 | 0x10 << 15 | 0x1C << 7 | 0x1C;
const MAI_FORMAT_PCM: u32 = 2;
const MAI_CONFIG_REVERSED: u32 = 1 << 27 | 1 << 26;
const AUDIO_ZERO_FLAT: u32 = 1 << 29;
const AUDIO_ZERO_INACTIVE: u32 = 1 << 24;
/// The B frame's preamble, as the subframes carry it (alsa-lib's 8).
const AUDIO_B_FRAME: u32 = 8 << 10;
const CRP_EXTERNAL_CTS: u32 = 1 << 24;
/// The DVP's 108 MHz, which the MAI's sample clock is divided from.
const AUDIO_CLOCK_HZ: u64 = 108_000_000;

/// HDMI0's MAI FIFO as the DMA engine reaches it, and the request line
/// it asks for data on: the 40-bit engine's DREQ 12 on the D0 stepping
/// (bcm2712d0-rpi-5-b.dts). The CM5's device tree has the C stepping's
/// 10, which the firmware's D0 overlay changes, and which no request
/// ever comes on here.
pub const mai_data: usize = HDMI_HD + HD_MAI_DATA;
pub const audio_dreq: u32 = 12;

/// The packet RAM: a packet's nine words for each infoframe type, its
/// header in the first and its four subpackets of seven bytes in the
/// eight after, each four bytes then three.
const HDMI_PACKET: usize = 0x10_7C70_3800;
const PACKET_STRIDE = 0x24;
pub const INFOFRAME_VENDOR: u8 = 0x81;
pub const INFOFRAME_AVI: u8 = 0x82;
pub const INFOFRAME_AUDIO: u8 = 0x84;

/// The monitor's SCDC, on the DDC: the TMDS configuration - the bit
/// clock at a fortieth of the TMDS clock, the scrambling - and the
/// scrambler's status.
const SCDC_ADDRESS: u32 = 0x54;
const SCDC_TMDS_CONFIG: u8 = 0x20;
const SCDC_SCRAMBLER_STATUS: u8 = 0x21;
const SCDC_SCRAMBLING: u8 = 1 << 0;
const SCDC_RATIO_40: u8 = 1 << 1;

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

/// The monitor's own controls over the DDC (VESA's DDC/CI): its address,
/// the host's in a message, the opcodes - a control asked for, its
/// answer, a control set - and the address each checksum starts from,
/// the monitor's when it is written to and the host's when it answers.
/// The monitor wants 40 ms to answer and 50 ms after a control is set.
const DDCCI_ADDRESS: u32 = 0x37;
const DDCCI_HOST: u8 = 0x51;
const DDCCI_GET: u8 = 0x01;
const DDCCI_REPLY: u8 = 0x02;
const DDCCI_SET: u8 = 0x03;
const DDCCI_WRITTEN_SUM: u8 = 0x6E;
const DDCCI_ANSWER_SUM: u8 = 0x50;
const ddcci_answer_us = 40_000;
const ddcci_set_us = 50_000;
/// MCCS's control for the brightness: the luminance.
pub const VCP_BRIGHTNESS: u8 = 0x10;

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

// --- what the display and its sound share ------------------------------------

/// What the display (rtg-fb) and its sound (rta-hdmi) share, found by
/// its name: a public semaphore held while either writes what both do -
/// the packet RAM's switches, the clock regeneration - with the mode's
/// pixel clock, whether it goes out as HDMI, and the sound playing (no
/// channels while none does). The first to ask makes it and it stays
/// for good: the display, as it starts.
pub const Shared = struct {
    lock: exec.SignalSemaphore = .{},
    pixel_khz: u32 = 0,
    hdmi: bool = false,
    audio_rate: u32 = 0,
    audio_channels: u32 = 0,
};

pub const shared_name = "bcm2712.hdmi0";

/// The shared state, made when nobody has yet; null without memory for
/// it.
pub fn sharedOf(sys: *ExecBase) ?*Shared {
    if (sys.FindSemaphore(shared_name)) |found| return @fieldParentPtr("lock", found);
    const memory = sys.AllocMem(@sizeOf(Shared), exec.MEMF_SYSTEM | exec.MEMF_CLEAR) orelse return null;
    const made: *Shared = @ptrCast(@alignCast(memory));
    made.* = .{};
    made.lock.link.name = shared_name;
    sys.AddSemaphore(&made.lock);
    return made;
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

/// SCDC register `offset` of the monitor's, read: the offset written,
/// then a byte read. Null when the monitor did not answer.
fn scdcRead(offset: u8, waiter: anytype) ?u8 {
    at(DDC, BSC_CHIP_ADDRESS).* = SCDC_ADDRESS << 1;
    if (!send(COND_RESTART | COND_NOSTOP, &.{offset}, waiter)) return null;
    at(DDC, BSC_CHIP_ADDRESS).* = SCDC_ADDRESS << 1 | 1;
    var value = [1]u8{0};
    if (!receive(readCondition(true, true), &value, waiter)) return null;
    return value[0];
}

/// SCDC register `offset` written with `value`.
fn scdcWrite(offset: u8, value: u8, waiter: anytype) bool {
    at(DDC, BSC_CHIP_ADDRESS).* = SCDC_ADDRESS << 1;
    return send(0, &.{ offset, value }, waiter);
}

/// The monitor told to take scrambled TMDS at a bit clock of a fortieth,
/// or the TMDS as it was (drm_scdc_set_high_tmds_clock_ratio, then
/// drm_scdc_set_scrambling): its TMDS configuration's two bits.
fn scdcScrambling(on: bool, waiter: anytype) bool {
    const config = scdcRead(SCDC_TMDS_CONFIG, waiter) orelse return false;
    const both = SCDC_RATIO_40 | SCDC_SCRAMBLING;
    return scdcWrite(SCDC_TMDS_CONFIG, if (on) config | both else config & ~both, waiter);
}

// --- the monitor's own controls (DDC/CI) -------------------------------------

/// A control's value as the monitor answers it, and its largest.
pub const Feature = struct { value: u16, most: u16 };

/// What a message's checksum makes of `from` and its bytes: each XORed
/// in.
fn checksum(from: u8, bytes: []const u8) u8 {
    var sum = from;
    for (bytes) |byte| sum ^= byte;
    return sum;
}

/// The message that asks for control `code`: from the host, two bytes
/// long, the opcode and the control, and the checksum.
pub fn askFor(code: u8) [5]u8 {
    var message = [5]u8{ DDCCI_HOST, 0x80 | 2, DDCCI_GET, code, 0 };
    message[4] = checksum(DDCCI_WRITTEN_SUM, message[0..4]);
    return message;
}

/// The message that sets control `code` to `value`, high byte first.
pub fn setTo(code: u8, value: u16) [7]u8 {
    var message = [7]u8{ DDCCI_HOST, 0x80 | 4, DDCCI_SET, code, @truncate(value >> 8), @truncate(value), 0 };
    message[6] = checksum(DDCCI_WRITTEN_SUM, message[0..6]);
    return message;
}

/// The monitor's answer about control `code`: from the monitor, eight
/// bytes long, a reply that it has the control, its largest value and
/// its value, and a checksum that adds up. Null for anything else - a
/// monitor that has not got the control, or was not ready.
pub fn answerOf(answer: *const [11]u8, code: u8) ?Feature {
    if (answer[0] != DDCCI_WRITTEN_SUM or answer[1] != 0x80 | 8) return null;
    if (answer[2] != DDCCI_REPLY or answer[3] != 0 or answer[4] != code) return null;
    if (checksum(DDCCI_ANSWER_SUM, answer[0..10]) != answer[10]) return null;
    const most = @as(u16, answer[6]) << 8 | answer[7];
    if (most == 0) return null;
    return .{ .value = @as(u16, answer[8]) << 8 | answer[9], .most = most };
}

/// The monitor's control `code`, asked for over the DDC: null when it
/// does not answer. Takes some 50 ms.
pub fn feature(code: u8, waiter: anytype) ?Feature {
    if (!on_bcm2712) return null;
    at(DDC, BSC_CHIP_ADDRESS).* = DDCCI_ADDRESS << 1;
    if (!send(0, &askFor(code), waiter)) return null;
    waiter.wait(ddcci_answer_us);
    at(DDC, BSC_CHIP_ADDRESS).* = DDCCI_ADDRESS << 1 | 1;
    var answer: [11]u8 = undefined;
    if (!receive(readCondition(true, true), &answer, waiter)) return null;
    return answerOf(&answer, code);
}

/// The monitor's control `code` set to `value`, and the time it wants
/// before it is spoken to again waited out: false when it did not take
/// the message.
pub fn setFeature(code: u8, value: u16, waiter: anytype) bool {
    if (!on_bcm2712) return false;
    at(DDC, BSC_CHIP_ADDRESS).* = DDCCI_ADDRESS << 1;
    const taken = send(0, &setTo(code, value), waiter);
    waiter.wait(ddcci_set_us);
    return taken;
}

// --- the PHY -----------------------------------------------------------------

/// The port's fastest TMDS clock, in kHz, scrambled past 340 MHz
/// (Linux's max_pixel_clock for the BCM2712's HDMI0).
const max_khz: u32 = 600_000;

/// Whether the port can send a mode of that pixel clock - to a monitor
/// that takes it (`edid.Sink.mostKhz`).
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
/// picture's), and seen or not; each row read from its right end, the
/// rows from the bottom up - `address` then the last row's.
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
    hflip: bool = false,
    vflip: bool = false,
};

/// The plane's nine words (vc6_plane_mode_set, vc6_plane_allocate_upm).
pub fn planeOf(plane: Plane) [plane_words]u32 {
    const mask = if (plane.alpha) 0 else CTL0_ALPHA_MASK_FIXED;
    const ctl2 = if (plane.seen) CTL2_PREMULT | ALPHA_OPAQUE << CTL2_ALPHA_SHIFT else CTL2_PREMULT | CTL2_ALPHA_MIX;
    return .{
        CTL0_VALID | plane_words << CTL0_NEXT_SHIFT | mask | CTL0_UNITY | CTL0_ORDER_ARGB | PIXEL_FORMAT_RGBA8888,
        (plane.y & 0x1FFF) << 16 | (if (plane.hflip) POS0_HFLIP else 0) | (plane.x & 0x1FFF),
        ctl2,
        (plane.height - 1) << 16 | (plane.width - 1),
        CONTEXT,
        (if (plane.vflip) PTR0_VFLIP else 0) | plane.upm << PTR0_UPM_BASE_SHIFT | plane.handle << PTR0_UPM_HANDLE_SHIFT | upper(plane.address),
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

/// How the picture is turned: mirrored left to right, top to bottom.
pub const Turn = struct { x: bool = false, y: bool = false };

/// An image laid over the picture - the cursor, the overlay: `width` by
/// `height` pixels of ARGB at `address`, rows `pitch` bytes apart, with
/// its piece of the UPM.
pub const Image = struct {
    address: usize,
    pitch: u32,
    width: u32,
    height: u32,
    upm: u32,
    handle: u32,
};

/// The plane of `image`, its top left at (left, top) on a picture
/// `width` by `height` that is turned `turn`: where the turned picture
/// has it, cut to the glass, and read backwards where the picture is.
/// An image wholly off the glass is a hidden pixel.
pub fn imagePlaneOf(image: Image, left: i32, top: i32, width: u32, height: u32, turn: Turn, seen: bool) Plane {
    const w: i32 = @intCast(image.width);
    const h: i32 = @intCast(image.height);
    const glass_w: i32 = @intCast(width);
    const glass_h: i32 = @intCast(height);
    // Its rectangle on the glass, and the part of that on it.
    const box_x = if (turn.x) glass_w - left - w else left;
    const box_y = if (turn.y) glass_h - top - h else top;
    const x = @max(0, box_x);
    const y = @max(0, box_y);
    const right = @min(glass_w, box_x + w);
    const bottom = @min(glass_h, box_y + h);
    var plane: Plane = .{
        .address = image.address,
        .pitch = image.pitch,
        .width = 1,
        .height = 1,
        .upm = image.upm,
        .handle = image.handle,
        .alpha = true,
        .seen = false,
        .hflip = turn.x,
        .vflip = turn.y,
    };
    if (x >= right or y >= bottom) return plane;
    // Columns and rows of the rectangle cut off at the glass's left and
    // top, which are the image's last ones where it is turned that way.
    const cut_x = x - box_x;
    const cut_y = y - box_y;
    const shown_w = right - x;
    const shown_h = bottom - y;
    const column = if (turn.x) w - cut_x - shown_w else cut_x;
    const row = if (turn.y) h - 1 - cut_y else cut_y;
    plane.address = image.address + @as(usize, @intCast(row)) * image.pitch + @as(usize, @intCast(column)) * 4;
    plane.x = @intCast(x);
    plane.y = @intCast(y);
    plane.width = @intCast(shown_w);
    plane.height = @intCast(shown_h);
    plane.seen = seen;
    return plane;
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

/// How `mode` goes to the monitor `sink` says it is. A CEA mode but the
/// first is taken as limited range unless the AVI infoframe says
/// otherwise, which it may where the monitor lets it (QS).
pub fn outputFor(sink: edid.Sink, mode: *const edid.Timing) Output {
    const cea_limited = sink.hdmi and mode.vic > 1;
    return .{
        .hdmi = sink.hdmi,
        .limited = cea_limited and !sink.quant_selectable,
        .range_said = sink.hdmi and sink.quant_selectable,
        .scrambled = mode.pixel_khz > edid.hdmi14_khz,
    };
}

/// An infoframe as the packet RAM takes it: its type, version and length,
/// its checksum - which brings the sum of all its bytes to 0 - and its
/// bytes, up to 27, the rest 0.
pub const Infoframe = [31]u8;

fn infoframe(kind: u8, version: u8, body: []const u8) Infoframe {
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
fn aviVic(sink: edid.Sink, mode: *const edid.Timing) u8 {
    if (!sink.forum and hdmiVic(mode.vic) != 0) return 0;
    return mode.vic;
}

/// The AVI infoframe for `mode` (hdmi_avi_infoframe_pack, as
/// drm_hdmi_avi_infoframe_from_display_mode fills it): RGB, the picture's
/// aspect - 4:3 for CEA's 640x480, 720x480 and 720x576 at their first
/// numbers, 16:9 for its others - the active part the whole picture, the
/// range when it is said, the mode's number.
pub fn aviFrame(sink: edid.Sink, mode: *const edid.Timing, output: Output) Infoframe {
    const aspect: u8 = switch (mode.vic) {
        0 => 0,
        1, 2, 17 => 1,
        else => 2,
    };
    const range: u8 = if (!output.range_said) 0 else if (output.limited) 1 else 2;
    return infoframe(INFOFRAME_AVI, 2, &.{
        // Active format information present, RGB.
        0x10,
        aspect << 4 | 8,
        range << 2,
        aviVic(sink, mode),
        0, 0, 0, 0, 0, 0, 0, 0, 0,
    });
}

/// HDMI's vendor infoframe naming HDMI 1.4's 4K mode `hdmi_vic`.
pub fn vendorFrame(hdmi_vic: u8) Infoframe {
    return infoframe(INFOFRAME_VENDOR, 1, &.{ 0x03, 0x0C, 0x00, 0x20, hdmi_vic });
}

/// The audio infoframe for `channels` of LPCM: the rest as the stream's
/// own header says, the speakers front left and right.
pub fn audioFrame(channels: u32) Infoframe {
    return infoframe(INFOFRAME_AUDIO, 1, &.{ @intCast(channels - 1), 0, 0, 0, 0, 0, 0, 0, 0, 0 });
}

/// The packet `frame` into the packet RAM and sent with every frame from
/// now on (vc4_hdmi_write_infoframe): its sending stopped and waited out,
/// its nine words written, then sent again. The packet RAM must be on.
fn writePacket(frame: *const Infoframe, waiter: anytype) void {
    const id: u5 = @intCast(frame[0] - 0x80);
    const bit = @as(u32, 1) << id;
    stopPacket(frame[0], waiter);
    const first = HDMI_PACKET + @as(usize, id) * PACKET_STRIDE;
    var i: usize = 0;
    while (i < 28) : (i += 7) {
        const pair = first + i / 7 * 8;
        reg(pair).* = @as(u32, frame[i]) | @as(u32, frame[i + 1]) << 8 | @as(u32, frame[i + 2]) << 16;
        reg(pair + 4).* = @as(u32, frame[i + 3]) | @as(u32, frame[i + 4]) << 8 | @as(u32, frame[i + 5]) << 16 | @as(u32, frame[i + 6]) << 24;
    }
    reg(first + 32).* = 0;
    at(HDMI, RAM_PACKET_CONFIG).* |= bit;
    waitBits(at(HDMI, RAM_PACKET_STATUS), bit, true, 100, waiter);
}

/// The packet of type `kind` no longer sent, waited out.
fn stopPacket(kind: u8, waiter: anytype) void {
    const bit = @as(u32, 1) << @as(u5, @intCast(kind - 0x80));
    at(HDMI, RAM_PACKET_CONFIG).* &= ~bit;
    waitBits(at(HDMI, RAM_PACKET_STATUS), bit, false, 100, waiter);
}

// --- starting ----------------------------------------------------------------

/// The display taken down, if it runs: pixel valve 0 stopped at the end
/// of a frame, the controller's packets and picture blanked, the
/// scrambling off at both ends, the valve's FIFO cleared and the HVS's
/// channel reset (vc4_crtc_disable).
fn stop(waiter: anytype) void {
    if (at(PV, PV_V_CONTROL).* & PV_VCONTROL_VIDEN != 0) {
        at(PV, PV_V_CONTROL).* &= ~PV_VCONTROL_VIDEN;
        waiter.wait(20_000);
    }
    at(HDMI, RAM_PACKET_CONFIG).* = 0;
    if (at(HDMI, SCRAMBLER_CTL).* & SCRAMBLER_ENABLE != 0) {
        at(HDMI, SCRAMBLER_CTL).* &= ~SCRAMBLER_ENABLE;
        _ = scdcScrambling(false, waiter);
    }
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

/// RGB through the controller's CSC, unchanged or squashed to 16-235
/// (vc5_hdmi_csc_setup, vc5_hdmi_csc_full_rgb_to_rgb).
fn hdmiColours(limited: bool) void {
    const scale = if (limited) CSC_LIMITED else CSC_ONE;
    const offset = if (limited) CSC_LIMITED_OFFSET else 0;
    at(HDMI_DVP, DVP_VEC_INTERFACE_CFG).* = 0;
    at(HDMI_DVP, DVP_VEC_INTERFACE_XBAR).* = XBAR_RGB;
    at(HDMI_CSC, CSC_12_11).* = scale;
    at(HDMI_CSC, CSC_14_13).* = offset << 16;
    at(HDMI_CSC, CSC_22_21).* = scale << 16;
    at(HDMI_CSC, CSC_24_23).* = offset << 16;
    at(HDMI_CSC, CSC_32_31).* = 0;
    at(HDMI_CSC, CSC_34_33).* = offset << 16 | scale;
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
/// (`sends`) and the monitor `sink` takes - showing the picture at
/// `address`, 32 bits a pixel, rows `pitch` bytes apart, below 4 GiB and
/// out of the caches, unturned; the cursor and the overlay hidden, and
/// the monitor sent the picture. With the display up, it changes
/// to `mode`; sound that plays goes on in it. The order is
/// vc4_crtc_atomic_enable's. `waiter.wait(micros)` waits that long.
pub fn start(sys: *ExecBase, mode: *const edid.Timing, sink: edid.Sink, address: usize, pitch: u32, waiter: anytype) Failure {
    if (!on_bcm2712) return .firmware;
    if (!sends(mode.pixel_khz)) return .clock;
    const woken = wake(sys, waiter);
    if (woken != .none) return woken;
    const shared = sharedOf(sys);
    if (shared) |held| sys.ObtainSemaphore(&held.lock);
    defer if (shared) |held| sys.ReleaseSemaphore(&held.lock);
    const output = outputFor(sink, mode);
    const tmds_hz = @as(u64, mode.pixel_khz) * 1000;
    stop(waiter);
    if (!clocksFor(sys, tmds_hz)) return .firmware;

    // The controller reset (vc5_hdmi_reset), the HVS's channel 0 on with
    // the list: the picture, and the overlay and the cursor hidden over
    // it.
    at(HDMI_HD, HD_DVP_CTL).* = 0;
    at(HDMI_DVP, DVP_CLOCK_STOP).* |= CLOCK_STOP_PIXEL;
    hvsStart();
    writePlane(picture_plane, .{ .address = address, .pitch = pitch, .width = mode.width, .height = mode.height, .upm = upm_picture, .handle = 0 });
    writePlane(overlay_plane, .{ .address = address, .pitch = 4, .width = 1, .height = 1, .upm = upm_overlay, .handle = 2, .alpha = true, .seen = false });
    writePlane(cursor_plane, .{ .address = address, .pitch = 4, .width = 1, .height = 1, .upm = upm_cursor, .handle = 1, .alpha = true, .seen = false });
    word(list_end).* = CTL0_END;
    hvsDisp(DISP_LPTRS).* = list_start;
    hvsDisp(DISP_CTRL0).* = CTRL0_RESET;
    hvsDisp(DISP_CTRL1).* &= ~CTRL1_INTLACE;
    hvsDisp(DISP_CTRL0).* = CTRL0_ENB | (mode.width - 1) << CTRL0_FWIDTH_SHIFT | (mode.height - 1);

    // The controller's PHY and timing, the valve's, the colours, then the
    // video let through (pre_crtc_configure, config_pv, pre_crtc_enable,
    // post_crtc_enable), as HDMI with its infoframes or as DVI.
    phyStart(tmds_hz);
    at(HDMI, SCHEDULER_CONTROL).* |= SCHEDULER_MANUAL_FORMAT | SCHEDULER_IGNORE_VSYNC_PREDICTS;
    hdmiTiming(mode);
    pvTiming(mode);
    at(PV, PV_CONTROL).* |= PV_CONTROL_EN;
    hdmiColours(output.limited);
    at(HDMI, FIFO_CTL).* = FIFO_MASTER_SLAVE_N;
    at(PV, PV_V_CONTROL).* |= PV_VCONTROL_VIDEN;
    var video = at(HDMI_HD, HD_VID_CTL).* & ~(VID_VSYNC_LOW | VID_HSYNC_LOW);
    video |= VID_ENABLE | VID_CLRRGB | VID_UNDERFLOW_ENABLE | VID_FRAME_COUNTER_RESET | VID_BLANK_INSERT_EN;
    if (!mode.vsync_high) video |= VID_VSYNC_LOW;
    if (!mode.hsync_high) video |= VID_HSYNC_LOW;
    at(HDMI_HD, HD_VID_CTL).* = video;
    at(HDMI_HD, HD_VID_CTL).* &= ~VID_BLANKPIX;
    if (output.hdmi) {
        at(HDMI, SCHEDULER_CONTROL).* |= SCHEDULER_MODE_HDMI;
        waitBits(at(HDMI, SCHEDULER_CONTROL), SCHEDULER_HDMI_ACTIVE, true, 1000, waiter);
        at(HDMI, RAM_PACKET_CONFIG).* = RAM_PACKET_ENABLE;
        writePacket(&aviFrame(sink, mode, output), waiter);
        if (!sink.forum and hdmiVic(mode.vic) != 0) writePacket(&vendorFrame(hdmiVic(mode.vic)), waiter);
    } else {
        at(HDMI, RAM_PACKET_CONFIG).* &= ~RAM_PACKET_ENABLE;
        at(HDMI, SCHEDULER_CONTROL).* &= ~SCHEDULER_MODE_HDMI;
        waitBits(at(HDMI, SCHEDULER_CONTROL), SCHEDULER_HDMI_ACTIVE, false, 1000, waiter);
    }
    recenter(waiter);
    // Past 340 MHz, the monitor told before the scrambler starts
    // (vc4_hdmi_enable_scrambling).
    if (output.scrambled) {
        _ = scdcScrambling(true, waiter);
        at(HDMI, SCRAMBLER_CTL).* |= SCRAMBLER_ENABLE;
    }

    // The sound that plays, sent in the new mode: its clock regeneration
    // from the new pixel clock, its infoframe again.
    if (shared) |held| {
        held.pixel_khz = mode.pixel_khz;
        held.hdmi = output.hdmi;
        if (output.hdmi and held.audio_channels != 0) {
            regenerate(held);
            writePacket(&audioFrame(held.audio_channels), waiter);
        }
    }

    // The frame interrupt: the start of each vertical front porch.
    at(PV, PV_INTSTAT).* = PV_INT_VFP_START;
    at(PV, PV_INTEN).* = PV_INT_VFP_START;
    return .none;
}

/// What a running display needs now and then, about once a second: the
/// monitor's scrambling turned on again when it has lost it, as it does
/// when it is switched off and on (vc4_hdmi_scrambling_wq).
pub fn tend(waiter: anytype) void {
    if (!on_bcm2712 or !running() or !transmitting()) return;
    if (at(HDMI, SCRAMBLER_CTL).* & SCRAMBLER_ENABLE == 0) return;
    const status = scdcRead(SCDC_SCRAMBLER_STATUS, waiter) orelse return;
    if (status & SCDC_SCRAMBLING == 0) _ = scdcScrambling(true, waiter);
}

// --- the sound ---------------------------------------------------------------

/// The MAI's code for a sample rate; 0, not said, for any other.
pub fn rateCode(rate: u32) u32 {
    return switch (rate) {
        32_000 => 7,
        44_100 => 8,
        48_000 => 9,
        88_200 => 11,
        96_000 => 12,
        176_400 => 14,
        192_000 => 15,
        else => 0,
    };
}

/// The MAI's sample clock for `rate`: 108 MHz divided by N over M, the
/// nearest fraction with M to 256 (vc4_hdmi_audio_set_mai_clock), as its
/// register holds them - N above, M less one in the low byte.
pub fn maiSample(rate: u32) u32 {
    var best_n: u64 = 0;
    var best_m: u64 = 1;
    var best_error: u64 = ~@as(u64, 0);
    var m: u64 = 1;
    while (m <= 256) : (m += 1) {
        const n = (AUDIO_CLOCK_HZ * m + rate / 2) / rate;
        if (n == 0 or n > 0xFF_FFFF) continue;
        const exact = AUDIO_CLOCK_HZ * m;
        const off = if (n * rate > exact) n * rate - exact else exact - n * rate;
        // |n/m - clock/rate|, compared without dividing.
        if (best_error == ~@as(u64, 0) or off * best_m < best_error * m) {
            best_n = n;
            best_m = m;
            best_error = off;
        }
        if (off == 0) break;
    }
    return @intCast(best_n << 8 | (best_m - 1));
}

/// N and CTS, which the monitor rebuilds the sample clock from - 128
/// times the rate is the TMDS clock times N over CTS - for `rate` at a
/// pixel clock of `pixel_khz` (vc4_hdmi_set_n_cts).
pub fn clockRegen(rate: u32, pixel_khz: u32) struct { n: u32, cts: u32 } {
    const n = 128 * rate / 1000;
    const cts = @as(u64, pixel_khz) * 1000 * n / (128 * @as(u64, rate));
    return .{ .n = n, .cts = @intCast(cts) };
}

fn regenerate(shared: *const Shared) void {
    const regen = clockRegen(shared.audio_rate, shared.pixel_khz);
    at(HDMI, CRP_CFG).* = CRP_EXTERNAL_CTS | regen.n;
    at(HDMI, CTS_0).* = regen.cts;
    at(HDMI, CTS_1).* = regen.cts;
}

/// Whether sound can go out: the display up as HDMI.
pub fn audible(sys: *ExecBase) bool {
    if (!on_bcm2712 or !running()) return false;
    const shared = sharedOf(sys) orelse return false;
    return shared.hdmi;
}

/// The sound started: `channels` channels of IEC 958 subframes at `rate`
/// into the MAI FIFO, sent as audio sample packets with their infoframe
/// (vc4_hdmi_audio_startup, then vc4_hdmi_audio_prepare). The DMA
/// channel that feeds the FIFO starts after. False, and nothing started,
/// when the display is not up as HDMI.
pub fn audioStart(sys: *ExecBase, rate: u32, channels: u32, waiter: anytype) bool {
    if (!on_bcm2712 or channels == 0 or channels > 8) return false;
    const shared = sharedOf(sys) orelse return false;
    sys.ObtainSemaphore(&shared.lock);
    defer sys.ReleaseSemaphore(&shared.lock);
    if (!running() or !shared.hdmi) return false;
    at(HDMI_HD, HD_MAI_CTL).* = MAI_RESET | MAI_FLUSH | MAI_DLATE | MAI_ERRORE | MAI_ERRORF;
    at(HDMI_HD, HD_MAI_SMP).* = maiSample(rate);
    at(HDMI_HD, HD_MAI_CTL).* = channels << MAI_CHNUM_SHIFT | MAI_WHOLSMP | MAI_CHALIGN | MAI_ENABLE;
    at(HDMI_HD, HD_MAI_FMT).* = rateCode(rate) << 8 | MAI_FORMAT_PCM << 16;
    at(HDMI_HD, HD_MAI_THR).* = MAI_THRESHOLDS;
    const mask = (@as(u32, 1) << @intCast(channels)) - 1;
    at(HDMI, MAI_CONFIG).* = MAI_CONFIG_REVERSED | mask;
    at(HDMI, MAI_CHANNEL_MAP).* = channelMap(mask);
    at(HDMI, AUDIO_PACKET_CONFIG).* = AUDIO_ZERO_FLAT | AUDIO_ZERO_INACTIVE | AUDIO_B_FRAME | mask;
    shared.audio_rate = rate;
    shared.audio_channels = channels;
    regenerate(shared);
    writePacket(&audioFrame(channels), waiter);
    return true;
}

/// The sound stopped, once its DMA channel has: the MAI and its FIFO
/// reset, the audio infoframe no longer sent (vc4_hdmi_audio_shutdown,
/// vc4_hdmi_audio_reset).
pub fn audioStop(sys: *ExecBase, waiter: anytype) void {
    if (!on_bcm2712) return;
    const shared = sharedOf(sys) orelse return;
    sys.ObtainSemaphore(&shared.lock);
    defer sys.ReleaseSemaphore(&shared.lock);
    shared.audio_rate = 0;
    shared.audio_channels = 0;
    if (!running()) return;
    at(HDMI_HD, HD_MAI_CTL).* = MAI_DLATE | MAI_ERRORE | MAI_ERRORF;
    if (shared.hdmi) stopPacket(INFOFRAME_AUDIO, waiter);
    at(HDMI_HD, HD_MAI_CTL).* = MAI_RESET;
    at(HDMI_HD, HD_MAI_CTL).* = MAI_ERRORF;
    at(HDMI_HD, HD_MAI_CTL).* = MAI_FLUSH;
}

/// Each channel of `mask` taken from the MAI's channel of its own number
/// (vc5_hdmi_channel_map): four bits a channel.
pub fn channelMap(mask: u32) u32 {
    var map: u32 = 0;
    for (0..8) |i| {
        if (mask & (@as(u32, 1) << @intCast(i)) != 0) map |= @as(u32, @intCast(i)) << @intCast(4 * i);
    }
    return map;
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

/// The picture's plane's size and pitch, and how it is turned, as its
/// words have them.
fn pictureWidth() u32 {
    return (word(picture_plane + W_POS2).* & 0x1FFF) + 1;
}

fn pictureHeight() u32 {
    return (word(picture_plane + W_POS2).* >> 16 & 0x1FFF) + 1;
}

fn turnOf() Turn {
    return .{
        .x = word(picture_plane + W_POS0).* & POS0_HFLIP != 0,
        .y = word(picture_plane + W_PTR0).* & PTR0_VFLIP != 0,
    };
}

/// Where the picture's plane starts reading a picture at `address`: its
/// last row where it reads from the bottom up.
fn readFrom(address: usize, turn: Turn) usize {
    if (!turn.y) return address;
    return address + @as(usize, pictureHeight() - 1) * word(picture_plane + W_PTR2).*;
}

fn pointPicture(address: usize, turn: Turn) void {
    const from = readFrom(address, turn);
    const flags = word(picture_plane + W_PTR0).* & ~(PTR0_VFLIP | 0xFF);
    word(picture_plane + W_PTR0).* = flags | (if (turn.y) PTR0_VFLIP else 0) | upper(from);
    word(picture_plane + W_PTR1).* = @truncate(from);
}

/// The picture at `address` shown from now on: the picture's plane's
/// address rewritten. The HVS takes it up as it next fetches.
pub fn show(address: usize) void {
    if (!running()) return;
    pointPicture(address, turnOf());
}

/// The picture mirrored as `turn` says from the next frame on, the one
/// at `address` - the one shown - read backwards. The cursor and the
/// overlay are turned with it when they are next written.
pub fn mirror(address: usize, turn: Turn) void {
    if (!running()) return;
    const position = word(picture_plane + W_POS0).* & ~POS0_HFLIP;
    word(picture_plane + W_POS0).* = position | (if (turn.x) POS0_HFLIP else 0);
    pointPicture(address, turn);
}

/// The monitor sent the picture, or blank pixels without syncs - no
/// signal, to a monitor. CLRSYNC reads back as 0 and holds only while it
/// is written, so the picture is back as soon as a write leaves it out.
pub fn transmit(on: bool) void {
    if (!running()) return;
    const video = at(HDMI_HD, HD_VID_CTL);
    video.* = if (on) video.* & ~(VID_CLRSYNC | VID_BLANKPIX) else video.* | VID_CLRSYNC | VID_BLANKPIX;
}

/// Whether the monitor is sent the picture.
fn transmitting() bool {
    return at(HDMI_HD, HD_VID_CTL).* & VID_BLANKPIX == 0;
}

/// An image's plane rewritten - its words but the first, the address
/// last, so that the HVS does not fetch a new image at an old size.
fn writeImage(first: u32, plane: Plane) void {
    const words = planeOf(plane);
    for ([_]usize{ W_CTL2, W_POS0, W_POS2, W_PTR2, W_PTR0, W_PTR1 }) |i| word(first + @as(u32, @intCast(i))).* = words[i];
}

/// The largest cursor image, each way.
pub const cursor_side = 64;

/// The cursor's plane: the image at `address` (`cursor_side` square, or
/// half that when `small`), its hot spot at (x, y) on the picture, shown
/// or not, turned as the picture is.
pub fn cursor(address: usize, small: bool, hot_x: u32, hot_y: u32, x: u32, y: u32, shown: bool) void {
    if (!running()) return;
    const side: u32 = if (small) cursor_side / 2 else cursor_side;
    const image = Image{ .address = address, .pitch = side * 4, .width = side, .height = side, .upm = upm_cursor, .handle = 1 };
    const left = @as(i32, @intCast(x)) - @as(i32, @intCast(hot_x));
    const top = @as(i32, @intCast(y)) - @as(i32, @intCast(hot_y));
    writeImage(cursor_plane, imagePlaneOf(image, left, top, pictureWidth(), pictureHeight(), turnOf(), shown));
}

/// The largest overlay, each way: rtg's.
pub const overlay_side = 160;

/// The overlay's plane: `width` by `height` pixels of the image at
/// `address`, rows `overlay_side` pixels apart, its top left at (left,
/// top) on the picture, shown or not, turned as the picture is.
pub fn overlay(address: usize, width: u32, height: u32, left: i32, top: i32, shown: bool) void {
    if (!running()) return;
    const image = Image{
        .address = address,
        .pitch = overlay_side * 4,
        .width = @max(width, 1),
        .height = @max(height, 1),
        .upm = upm_overlay,
        .handle = 2,
    };
    writeImage(overlay_plane, imagePlaneOf(image, left, top, pictureWidth(), pictureHeight(), turnOf(), shown and width != 0 and height != 0));
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
    const big = Image{ .address = 0x1000, .pitch = 256, .width = 64, .height = 64, .upm = upm_cursor, .handle = 1 };
    const small = Image{ .address = 0x1000, .pitch = 128, .width = 32, .height = 32, .upm = upm_cursor, .handle = 1 };
    const corner = imagePlaneOf(big, -4, -4, 1920, 1080, .{}, true);
    try testing.expectEqual(@as(usize, 0x1000 + 4 * 256 + 4 * 4), corner.address);
    try testing.expectEqual(@as(u32, 0), corner.x);
    try testing.expectEqual(@as(u32, 60), corner.width);
    try testing.expectEqual(@as(u32, 60), corner.height);
    try testing.expectEqual(@as(u32, 256), corner.pitch);
    const cursor_words = planeOf(corner);
    try testing.expectEqual(@as(u32, 0), cursor_words[0] & 3 << 18);
    try testing.expectEqual(@as(u32, 128 << 16 | 1 << 10), cursor_words[5]);
    // At the bottom right, only the hot spot's pixel on it.
    const edge = imagePlaneOf(small, 1919, 1079, 1920, 1080, .{}, true);
    try testing.expectEqual(@as(u32, 1), edge.width);
    try testing.expectEqual(@as(u32, 1), edge.height);
    try testing.expectEqual(@as(u32, 1919), edge.x);
    // Hidden: alpha 0, mixed.
    try testing.expectEqual(@as(u32, 0x3000_0000), planeOf(imagePlaneOf(big, 10, 10, 1920, 1080, .{}, false))[2]);
    // Wholly off the picture: a hidden pixel.
    const gone = imagePlaneOf(big, -64, 10, 1920, 1080, .{}, true);
    try testing.expect(!gone.seen and gone.width == 1 and gone.height == 1);
    // A row of 1920 takes 61 units of UPM, of 4K 121, the cursor's 3:
    // both fit before the cursor's at 128.
    try testing.expectEqual(@as(u32, 61), upmUnits(7680));
    try testing.expectEqual(@as(u32, 121), upmUnits(15360));
    try testing.expectEqual(@as(u32, 3), upmUnits(256));
}

test "the BCM2712's display list turned: the picture and an image read backwards" {
    const flipped = planeOf(.{ .address = 0x3000_0000 + 1079 * 7680, .pitch = 7680, .width = 1920, .height = 1080, .upm = 0, .handle = 0, .hflip = true, .vflip = true });
    try testing.expectEqual(@as(u32, 1 << 15), flipped[1]);
    try testing.expectEqual(@as(u32, 1 << 31), flipped[5]);
    try testing.expectEqual(@as(u32, 0x3000_0000 + 1079 * 7680), flipped[6]);

    // Mirrored left to right, a 64-pixel cursor at (100, 50) is at
    // 1920 - 164 on the glass, read from its own first column backwards.
    const big = Image{ .address = 0x1000, .pitch = 256, .width = 64, .height = 64, .upm = upm_cursor, .handle = 1 };
    const across = imagePlaneOf(big, 100, 50, 1920, 1080, .{ .x = true }, true);
    try testing.expectEqual(@as(u32, 1920 - 164), across.x);
    try testing.expectEqual(@as(u32, 50), across.y);
    try testing.expectEqual(@as(usize, 0x1000), across.address);
    try testing.expect(across.hflip and !across.vflip and across.width == 64);
    // At the picture's left edge, 4 columns off: on the glass it is 4
    // columns off the right, which are the image's first 4 - so it is
    // read from column 4, 60 wide.
    const left_edge = imagePlaneOf(big, -4, 50, 1920, 1080, .{ .x = true }, true);
    try testing.expectEqual(@as(u32, 1920 - 60), left_edge.x);
    try testing.expectEqual(@as(u32, 60), left_edge.width);
    try testing.expectEqual(@as(usize, 0x1000 + 4 * 4), left_edge.address);
    // At the picture's right edge, 4 columns off: on the glass 4 off the
    // left, the image's last 4 - read from column 0.
    const right_edge = imagePlaneOf(big, 1920 - 60, 50, 1920, 1080, .{ .x = true }, true);
    try testing.expectEqual(@as(u32, 0), right_edge.x);
    try testing.expectEqual(@as(u32, 60), right_edge.width);
    try testing.expectEqual(@as(usize, 0x1000), right_edge.address);
    // Upside down, 4 rows off the picture's top: on the glass 4 off the
    // bottom, the image's first 4; read from row 63 upwards, 60 rows.
    const top_edge = imagePlaneOf(big, 100, -4, 1920, 1080, .{ .y = true }, true);
    try testing.expectEqual(@as(u32, 1080 - 60), top_edge.y);
    try testing.expectEqual(@as(u32, 60), top_edge.height);
    try testing.expectEqual(@as(usize, 0x1000 + 63 * 256), top_edge.address);
    try testing.expect(top_edge.vflip);
    // 4 rows off the picture's bottom: on the glass 4 off the top, the
    // image's last 4; read from row 59 upwards.
    const bottom_edge = imagePlaneOf(big, 100, 1080 - 60, 1920, 1080, .{ .y = true }, true);
    try testing.expectEqual(@as(u32, 0), bottom_edge.y);
    try testing.expectEqual(@as(u32, 60), bottom_edge.height);
    try testing.expectEqual(@as(usize, 0x1000 + 59 * 256), bottom_edge.address);
}

test "the monitor's controls: DDC/CI's messages and answers" {
    // The brightness asked for, and set to 50: the checksum starts from
    // the monitor's address, 0x6E.
    try testing.expectEqualSlices(u8, &.{ 0x51, 0x82, 0x01, 0x10, 0xAC }, &askFor(VCP_BRIGHTNESS));
    try testing.expectEqualSlices(u8, &.{ 0x51, 0x84, 0x03, 0x10, 0x00, 0x32, 0x9A }, &setTo(VCP_BRIGHTNESS, 50));
    // The answer: 50 of 100, its checksum from the host's 0x50.
    var answer = [11]u8{ 0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2 };
    const got = answerOf(&answer, VCP_BRIGHTNESS).?;
    try testing.expectEqual(@as(u16, 50), got.value);
    try testing.expectEqual(@as(u16, 100), got.most);
    // A checksum that does not add up, a control the monitor has not got.
    answer[10] ^= 1;
    try testing.expect(answerOf(&answer, VCP_BRIGHTNESS) == null);
    answer[10] ^= 1;
    answer[3] = 1;
    answer[10] ^= 1;
    try testing.expect(answerOf(&answer, VCP_BRIGHTNESS) == null);
    // Not ready: the null message.
    const nothing = [11]u8{ 0x6E, 0x80, 0xBE, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expect(answerOf(&nothing, VCP_BRIGHTNESS) == null);
}

test "the BCM2712's DDC: how the pieces of a read end and start" {
    try testing.expectEqual(COND_NOSTOP, readCondition(true, false));
    try testing.expectEqual(COND_NOSTART | COND_NOSTOP, readCondition(false, false));
    try testing.expectEqual(COND_NOSTART, readCondition(false, true));
}

test "what a monitor is sent: HDMI with its range said, limited without QS, DVI full" {
    const portable: edid.Sink = .{ .hdmi = true, .audio = true, .quant_selectable = true, .max_tmds_khz = 300_000 };
    const full_hd = edid.knownMode(1920, 1080, 60).?;
    const output = outputFor(portable, &full_hd);
    try testing.expect(output.hdmi and !output.limited and output.range_said and !output.scrambled);
    // RGB, 16:9 with the active part the picture, full range, VIC 16.
    try testing.expectEqualSlices(u8, &.{ 0x82, 0x02, 0x0D, 0x1F, 0x10, 0x28, 0x08, 16, 0 }, aviFrame(portable, &full_hd, output)[0..9]);

    // A monitor without QS takes a CEA mode's RGB limited, and is not
    // told; 640x480 (VIC 1) stays full.
    const plain: edid.Sink = .{ .hdmi = true, .audio = false, .quant_selectable = false, .max_tmds_khz = 0 };
    const squashed = outputFor(plain, &full_hd);
    try testing.expect(squashed.limited and !squashed.range_said);
    try testing.expectEqual(@as(u8, 0), aviFrame(plain, &full_hd, squashed)[6]);
    const vga = edid.knownMode(640, 480, 60).?;
    try testing.expect(!outputFor(plain, &vga).limited);
    try testing.expectEqual(@as(u8, 1 << 4 | 8), aviFrame(plain, &vga, outputFor(plain, &vga))[5]);

    // DVI: no infoframes, full range.
    const dvi: edid.Sink = .{ .hdmi = false, .audio = false, .quant_selectable = false, .max_tmds_khz = 0 };
    const as_dvi = outputFor(dvi, &full_hd);
    try testing.expect(!as_dvi.hdmi and !as_dvi.limited and !as_dvi.range_said);

    // 4K60 is scrambled.
    const uhd60 = edid.knownMode(3840, 2160, 60).?;
    try testing.expect(outputFor(portable, &uhd60).scrambled);
}

test "HDMI 1.4's 4K modes go in the vendor infoframe, HDMI 2.0's in the AVI's" {
    const uhd30 = edid.knownMode(3840, 2160, 30).?;
    try testing.expectEqual(@as(u8, 95), uhd30.vic);
    try testing.expectEqual(@as(u8, 1), hdmiVic(uhd30.vic));
    const older: edid.Sink = .{ .hdmi = true, .audio = true, .quant_selectable = false, .max_tmds_khz = 300_000 };
    try testing.expectEqual(@as(u8, 0), aviFrame(older, &uhd30, outputFor(older, &uhd30))[7]);
    var newer = older;
    newer.forum = true;
    try testing.expectEqual(@as(u8, 95), aviFrame(newer, &uhd30, outputFor(newer, &uhd30))[7]);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x01, 0x05, 0x49, 0x03, 0x0C, 0x00, 0x20, 0x01, 0 }, vendorFrame(1)[0..10]);
}

test "the sound's numbers: the audio infoframe, the MAI's clock, N and CTS" {
    try testing.expectEqualSlices(u8, &.{ 0x84, 0x01, 0x0A, 0x70, 0x01, 0 }, audioFrame(2)[0..6]);
    // 108 MHz over 48 kHz is 2250 exactly; over 44.1 kHz 120000/49.
    try testing.expectEqual(@as(u32, 2250 << 8), maiSample(48_000));
    try testing.expectEqual(@as(u32, 120_000 << 8 | 48), maiSample(44_100));
    try testing.expectEqual(@as(u32, 3375 << 8), maiSample(32_000));
    try testing.expectEqual(@as(u32, 9), rateCode(48_000));
    try testing.expectEqual(@as(u32, 0), rateCode(22_050));
    // HDMI's table: 6144 and 148500 at 1080p60, 594000 at 4K60.
    const full_hd = clockRegen(48_000, 148_500);
    try testing.expectEqual(@as(u32, 6144), full_hd.n);
    try testing.expectEqual(@as(u32, 148_500), full_hd.cts);
    try testing.expectEqual(@as(u32, 594_000), clockRegen(48_000, 594_000).cts);
    try testing.expectEqual(@as(u32, 0x10), channelMap(0x3));
    try testing.expectEqual(@as(u32, 0x7654_3210), channelMap(0xFF));
}
