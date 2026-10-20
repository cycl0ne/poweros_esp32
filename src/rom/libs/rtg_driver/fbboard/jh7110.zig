// SPDX-License-Identifier: MPL-2.0
//! The JH7110's way to its HDMI port (CHIP_JH7110_DC8200): the VOUT power
//! domain, its clocks and resets, Innosilicon's HDMI transmitter and its
//! PHY, and Verisilicon's DC8200 display controller, which reads the
//! picture out of RAM, 32 bits a pixel. The transmitter reads the
//! monitor's EDID over its own DDC (`readEdid`), so the board can tell
//! which modes the monitor takes before it picks one (`monitor.zig`).
//!
//! A mode is the pixel clock the transmitter's PLL makes for it
//! (`phy.zig`) and its timing, which goes to the transmitter and to the
//! controller. The controller takes its pixel clock from that PLL too, as
//! StarFive's Linux driver has it, so any clock the PLL makes is a clock
//! the display runs at - not only the VOUT source's PLL2 divided down.
//!
//! The steps are U-Boot's (StarFive's sf_vop.c and sf_hdmi.c), which
//! takes all of it down again before it starts the kernel, the power
//! domain included, and the transmitter's per-mode steps Linux's
//! (inno_hdmi.c). The controller's registers are written as U-Boot
//! writes them, a list of values with no names behind most of them; the
//! ones that matter here are named: the picture's size and timing, where
//! it is (FRAMEBUFFER_ADDRESS), how far apart its rows are, and what
//! starts the display.
//!
//! Nothing here is read before its domain is on: a register of a block
//! that is off does not answer, and the bus waits for it.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const edid = @import("../edid.zig");
const phy = @import("phy.zig");

/// The power management unit: a domain is switched by writing its bit to
/// the switch register and the "encourage" sequence after it.
const PMU: usize = 0x1703_0000;
const PMU_SW_TURN_ON = PMU + 0x0C;
const PMU_SW_ENCOURAGE = PMU + 0x44;
const PMU_CURR_POWER_MODE = PMU + 0x80;
const DOMAIN_VOUT: u32 = 1 << 4;
const ENCOURAGE = [_]u32{ 0xFF, 0x05, 0x50 };

/// The system clock and reset generator: a clock's register is its
/// number times four, bit 31 lets it through; a reset is held while its
/// bit is set in ASSERT and is out once it is set in STATUS.
const SYS_CRG: usize = 0x1302_0000;
const SYSCLK_VOUT_SRC = SYS_CRG + 58 * 4;
const SYSCLK_NOC_BUS_DISP_AXI = SYS_CRG + 60 * 4;
const SYSCLK_VOUT_TOP_AHB = SYS_CRG + 61 * 4;
const SYSCLK_VOUT_TOP_AXI = SYS_CRG + 62 * 4;
const SYSCLK_VOUT_TOP_HDMITX0_MCLK = SYS_CRG + 63 * 4;
const SYS_RESET_ASSERT0 = SYS_CRG + 0x2F8;
const SYS_RESET_ASSERT1 = SYS_CRG + 0x2FC;
const SYS_RESET_STATUS0 = SYS_CRG + 0x308;
const SYS_RESET_STATUS1 = SYS_CRG + 0x30C;
const SYSRST_NOC_BUS_DISP_AXI: u32 = 1 << 26;
const SYSRST_VOUT_TOP_SRC: u32 = 1 << (43 - 32);
const CLK_ENABLE: u32 = 1 << 31;

/// The VOUT domain's own clock and reset generator, laid out the same
/// way. The controller's pixel clock is the VOUT source (PLL2, 1188 MHz)
/// divided by 8 while the domain comes up, and the transmitter's PLL once
/// a mode is set: bit 24 of its gate picks that.
const VOUT_CRG: usize = 0x295C_0000;
const VOUTCLK_DC8200_PIX = VOUT_CRG + 1 * 4;
const VOUTCLK_DC8200_AXI = VOUT_CRG + 4 * 4;
const VOUTCLK_DC8200_CORE = VOUT_CRG + 5 * 4;
const VOUTCLK_DC8200_AHB = VOUT_CRG + 6 * 4;
const VOUTCLK_DC8200_PIX0 = VOUT_CRG + 7 * 4;
const VOUTCLK_DC8200_PIX1 = VOUT_CRG + 8 * 4;
const VOUTCLK_HDMI_TX_MCLK = VOUT_CRG + 15 * 4;
const VOUTCLK_HDMI_TX_BCLK = VOUT_CRG + 16 * 4;
const VOUTCLK_HDMI_TX_SYS = VOUT_CRG + 17 * 4;
const VOUT_RESET_ASSERT = VOUT_CRG + 0x48;
const VOUT_RESET_STATUS = VOUT_CRG + 0x4C;
const VOUTRST_DC8200: u32 = 1 << 0 | 1 << 1 | 1 << 2;
const VOUTRST_HDMI_TX: u32 = 1 << 9;
const PIXEL_DIVIDER: u32 = 8;
const PIX_FROM_HDMI: u32 = 1 << 24;

/// The pin controller: what drives a pad and its output enable are a
/// byte each, four pads to a word, at DOUT and DOEN; an input of the chip
/// is fed by the pad in its byte of GPI (the pad's number plus two); a
/// pad's own settings are a word each from PADCFG.
const SYS_IOMUX: usize = 0x1304_0000;
const IOMUX_DOEN = SYS_IOMUX + 0x00;
const IOMUX_DOUT = SYS_IOMUX + 0x40;
const IOMUX_GPI = SYS_IOMUX + 0x80;
const IOMUX_PADCFG = SYS_IOMUX + 0x120;
const PAD_INPUT_ENABLE: u32 = 1 << 0;
const PAD_PULL_UP: u32 = 1 << 3;

/// The transmitter's DDC lines on pads 0 (SCL) and 1 (SDA), as the
/// board's device tree has them: the transmitter's signal that drives
/// the pad, the one that enables it, and the input the pad feeds.
const DdcPin = struct { pad: u8, out: u8, enable: u8, input: u8 };
const ddc_pins = [_]DdcPin{
    .{ .pad = 0, .out = 11, .enable = 3, .input = 6 },
    .{ .pad = 1, .out = 12, .enable = 4, .input = 7 },
};

/// The HDMI transmitter: register n is at n times four.
const HDMI: usize = 0x2959_0000;
const HDMI_STATUS = 0xC8;
const STATUS_HOTPLUG: u32 = 1 << 7;
/// Its DDC master, which reads the monitor's EDID 128 bytes at a time
/// into a FIFO: the bus clock's divider, where the read starts, and the
/// FIFO. Writing the segment starts the read; EDID_READY in STATUS1 says
/// it is done.
const DDC_BUS_FREQ_L = 0x4B;
const DDC_BUS_FREQ_H = 0x4C;
const EDID_SEGMENT_POINTER = 0x4D;
const EDID_WORD_ADDR = 0x4E;
const EDID_FIFO_OFFSET = 0x4F;
const EDID_FIFO_ADDR = 0x50;
const INTERRUPT_MASK1 = 0xC0;
const INTERRUPT_STATUS1 = 0xC1;
const EDID_READY: u32 = 1 << 2;
/// The DDC's clock, 100 kHz: its 51.2 MHz register clock over four, over
/// that - as StarFive's Linux driver sets it.
const DDC_DIVIDER: u32 = 51_200_000 / 4 / 100_000;
/// Its power and reset: the PHY powered down while a mode is set, up
/// again after.
const SYS_CTRL = 0x00;
const PHY_POWER_DOWN: u32 = 0x63;
const PHY_POWER_ON: u32 = 0x61;
/// The mode's timing as the transmitter takes it, given rather than
/// measured from the controller's sync: the totals, the blanking, where
/// the sync starts counted back from the end and how long it is, and the
/// sync's polarity.
const VIDEO_TIMING_CTL = 0x08;
const TIMING_EXTERNAL: u32 = 1 << 0;
const TIMING_HSYNC_HIGH: u32 = 1 << 2;
const TIMING_VSYNC_HIGH: u32 = 1 << 3;
const VIDEO_EXT_HTOTAL = 0x09;
const VIDEO_EXT_HBLANK = 0x0B;
const VIDEO_EXT_HDELAY = 0x0D;
const VIDEO_EXT_HDURATION = 0x0F;
const VIDEO_EXT_VTOTAL = 0x11;
const VIDEO_EXT_VBLANK = 0x13;
const VIDEO_EXT_VDELAY = 0x14;
const VIDEO_EXT_VDURATION = 0x15;
/// The packet buffers it sends with each frame: buffer 6 is the AVI
/// infoframe, its header, checksum and data bytes from PACKET_ADDR on.
const PACKET_BUF_INDEX = 0x9F;
const PACKET_AVI: u32 = 0x06;
const PACKET_ADDR = 0xA0;
const PACKET_BYTES = 17;
const PHY_SYNC = 0xCE;
/// The PHY's PLLs (`phy.zig`): the pre-PLL's power (bit 0 off) and its
/// settings from 0x1A1, its fraction from 0x1D1; the post-PLL's power
/// and settings; each one's lock bit.
const PLL_PRE = 0x1A0;
const PLL_PRE_SETTINGS = 0x1A1;
const PLL_PRE_FRACTION = 0x1D1;
const PLL_PRE_LOCKED = 0x1A9;
const PLL_POST = 0x1AA;
const PLL_POST_SETTINGS = 0x1AB;
const PLL_POST_LOCKED = 0x1AF;
const PLL_OFF: u32 = 1 << 0;
/// The post-PLL off, with its post divider on and the TMDS clock in.
const PLL_POST_OFF: u32 = 0x0F;

/// The display controller.
const DC: usize = 0x2940_0000;
/// Its interrupts: reading ACKNOWLEDGE says which came since it was last
/// read, and clears them; ENABLE says which may come, and `start` lets
/// them, as U-Boot does.
const INTERRUPT_ACKNOWLEDGE = 0x0010;
const INTERRUPT_ENABLE = 0x0014;
const FRAMEBUFFER_ADDRESS = 0x1400;
const FRAMEBUFFER_STRIDE = 0x1408;
const PANEL_START = 0x1CCC;
/// The picture's size, the primary plane's and its bottom right corner's
/// (width, and height from bit 15), and the panel's timing: each way the
/// total and the picture (from bit 16), and the sync's start and end (from
/// bit 15), on (bit 30), low (bit 31).
const FRAMEBUFFER_SIZE = 0x1810;
const FRAMEBUFFER_BOTTOM_RIGHT = 0x24E0;
const DISPLAY_H = 0x1430;
const DISPLAY_H_SYNC = 0x1438;
const DISPLAY_V = 0x1440;
const DISPLAY_V_SYNC = 0x1448;
const SYNC_ON: u32 = 1 << 30;
const SYNC_LOW: u32 = 1 << 31;
/// The primary plane's extra configuration, with its shadow bit, and the
/// panel's, whose bit 0 holds the shadow registers while it is set: what
/// is written meanwhile is taken together once both are let go.
const FRAMEBUFFER_CONFIG_EX = 0x1CC0;
const FRAMEBUFFER_SHADOW: u32 = 1 << 12;
const PANEL_CONFIG_EX = 0x2518;
const PANEL_HOLD: u32 = 1 << 0;
/// The cursor plane: an ARGB8888 image 32 or 64 pixels square, laid over
/// the picture by the controller with its hot spot at LOCATION. Format 0
/// is no cursor; VALID stays set either way, as U-Boot and Linux leave it.
const CURSOR_CONFIG = 0x1468;
const CURSOR_ADDRESS = 0x146C;
const CURSOR_LOCATION = 0x1470;
const CURSOR_ARGB8888: u32 = 2;
const CURSOR_VALID: u32 = 1 << 2;
const CURSOR_UPDATE: u32 = 1 << 3;
const CURSOR_SIZE_64: u32 = 1 << 5;

/// How many times a wait reads its register before it gives up.
const patience: u32 = 1_000_000;

/// Why the display did not come up: its domain stayed off, the
/// transmitter's PLL makes no such clock, or it did not lock.
pub const Failure = enum { none, power, clock, pll };

fn hdmi(index: usize) *volatile u32 {
    return reg(HDMI + index * 4);
}

fn dc(offset: usize) *volatile u32 {
    return reg(DC + offset);
}

fn on(clock: usize) void {
    reg(clock).* |= CLK_ENABLE;
}

/// Resets `bits` of ASSERT let go, and waited for in STATUS.
fn release(assert: usize, status: usize, bits: u32) void {
    reg(assert).* &= ~bits;
    var tries: u32 = 0;
    while (reg(status).* & bits != bits and tries < patience) : (tries += 1) {}
}

/// Whether `index` came to have bit 0 set.
fn locked(index: usize) bool {
    var tries: u32 = 0;
    while (tries < patience) : (tries += 1) {
        if (hdmi(index).* & 1 != 0) return true;
    }
    return false;
}

/// The VOUT domain switched on, if it is off.
fn powerOn() bool {
    if (reg(PMU_CURR_POWER_MODE).* & DOMAIN_VOUT != 0) return true;
    reg(PMU_SW_TURN_ON).* = DOMAIN_VOUT;
    for (ENCOURAGE) |value| reg(PMU_SW_ENCOURAGE).* = value;
    var tries: u32 = 0;
    while (tries < patience) : (tries += 1) {
        if (reg(PMU_CURR_POWER_MODE).* & DOMAIN_VOUT != 0) return true;
    }
    return false;
}

/// Whether a monitor is on the port: the transmitter's hot-plug line.
/// Only once `wake` has the transmitter out of reset.
pub fn monitor() bool {
    return hdmi(HDMI_STATUS).* & STATUS_HOTPLUG != 0;
}

/// The byte of `cell`'s word that is number `index` of four, set to
/// `value`.
fn setByte(cell: usize, index: u32, value: u32) void {
    const word = reg(cell + index / 4 * 4);
    const shift: u5 = @intCast(index % 4 * 8);
    word.* = word.* & ~(@as(u32, 0xFF) << shift) | value << shift;
}

/// The transmitter's DDC on its pads, pulled up as the device tree has
/// them, whatever the firmware left there.
fn takeDdcPins() void {
    for (ddc_pins) |pin| {
        setByte(IOMUX_DOUT, pin.pad, pin.out);
        setByte(IOMUX_DOEN, pin.pad, pin.enable);
        setByte(IOMUX_GPI, pin.input, @as(u32, pin.pad) + 2);
        reg(IOMUX_PADCFG + @as(usize, pin.pad) * 4).* |= PAD_INPUT_ENABLE | PAD_PULL_UP;
    }
}

/// The domain on, the controller's and the transmitter's clocks running
/// and their resets let go, and the transmitter's DDC ready to read the
/// monitor's EDID (`readEdid`): what `start` needs first, and what tells
/// which modes the monitor takes before one is picked. Done again it
/// changes nothing. `waiter.wait(micros)` waits that long.
pub fn wake(waiter: anytype) Failure {
    if (reg(PMU_CURR_POWER_MODE).* & DOMAIN_VOUT == 0) {
        if (!powerOn()) return .power;
        waiter.wait(50_000);
    }

    // The bus to the domain and the domain's own clocks, as U-Boot's
    // vout_probe_resources_jh7110 has them.
    on(SYSCLK_NOC_BUS_DISP_AXI);
    release(SYS_RESET_ASSERT0, SYS_RESET_STATUS0, SYSRST_NOC_BUS_DISP_AXI);
    on(SYSCLK_VOUT_SRC);
    on(SYSCLK_VOUT_TOP_AXI);
    on(SYSCLK_VOUT_TOP_AHB);
    release(SYS_RESET_ASSERT1, SYS_RESET_STATUS1, SYSRST_VOUT_TOP_SRC);
    // The pixel clock from the divider, not the transmitter's PLL.
    reg(VOUTCLK_DC8200_PIX).* = PIXEL_DIVIDER;
    reg(VOUTCLK_DC8200_PIX0).* = CLK_ENABLE;
    reg(VOUTCLK_DC8200_PIX1).* = CLK_ENABLE;
    on(VOUTCLK_DC8200_AXI);
    on(VOUTCLK_DC8200_CORE);
    on(VOUTCLK_DC8200_AHB);
    release(VOUT_RESET_ASSERT, VOUT_RESET_STATUS, VOUTRST_DC8200);

    // The transmitter: its clocks, out of reset (inno_hdmi_probe).
    on(SYSCLK_VOUT_TOP_HDMITX0_MCLK);
    on(VOUTCLK_HDMI_TX_SYS);
    on(VOUTCLK_HDMI_TX_MCLK);
    on(VOUTCLK_HDMI_TX_BCLK);
    release(VOUT_RESET_ASSERT, VOUT_RESET_STATUS, VOUTRST_HDMI_TX);

    // Its DDC (inno_hdmi_i2c_init): the pads, the bus clock, the EDID's
    // interrupt off and cleared.
    takeDdcPins();
    hdmi(DDC_BUS_FREQ_L).* = DDC_DIVIDER & 0xFF;
    hdmi(DDC_BUS_FREQ_H).* = DDC_DIVIDER >> 8;
    hdmi(INTERRUPT_MASK1).* = 0;
    hdmi(INTERRUPT_STATUS1).* = EDID_READY;
    return .none;
}

/// Block `number` of the monitor's EDID into `block`: block n is word
/// address (n % 2) * 128 of segment n / 2. False when the monitor did
/// not answer within 100 ms. Only once `wake` has the transmitter up.
pub fn readEdid(number: u8, block: *[128]u8, waiter: anytype) bool {
    // inno_hdmi_i2c_xfer: the interrupt let through to its status bit and
    // cleared, the read set up and started, the FIFO read out.
    hdmi(INTERRUPT_MASK1).* = EDID_READY;
    hdmi(INTERRUPT_STATUS1).* = EDID_READY;
    defer hdmi(INTERRUPT_MASK1).* = 0;
    hdmi(EDID_FIFO_OFFSET).* = 0;
    hdmi(EDID_WORD_ADDR).* = @as(u32, number % 2) * 128;
    hdmi(EDID_SEGMENT_POINTER).* = number / 2;
    var waited: u32 = 0;
    while (hdmi(INTERRUPT_STATUS1).* & EDID_READY == 0) : (waited += 1) {
        if (waited == 100) return false;
        waiter.wait(1000);
    }
    hdmi(INTERRUPT_STATUS1).* = EDID_READY;
    for (block) |*byte| byte.* = @truncate(hdmi(EDID_FIFO_ADDR).*);
    return true;
}

/// A 16-bit value into two of the transmitter's registers, low first.
fn hdmi16(index: usize, value: u32) void {
    hdmi(index).* = value & 0xFF;
    hdmi(index + 1).* = (value >> 8) & 0xFF;
}

/// The PHY's PLLs set for `pll` (inno_hdmi_config_pll): both off while
/// they are set, then on. Their lock is waited for after.
fn setPll(pll: *const phy.Pll) void {
    const set = phy.image(pll);
    const post = phy.post(pll.pixel_khz);
    hdmi(PLL_PRE).* = PLL_OFF;
    hdmi(PLL_POST).* = PLL_POST_OFF;
    for (set.regs, 0..) |value, i| hdmi(PLL_PRE_SETTINGS + i).* = value;
    if (pll.frac != 0) {
        for (set.frac, 0..) |value, i| hdmi(PLL_PRE_FRACTION + i).* = value;
    }
    for (post[0..3], 0..) |value, i| hdmi(PLL_POST_SETTINGS + i).* = value;
    hdmi(PLL_POST).* = post[3];
    hdmi(PLL_PRE).* = 0;
}

/// The drivers' swing and pre-emphasis for the faster modes, as StarFive's
/// Linux driver tunes them by CEA's number (its improve_eye_diagram); any
/// other mode keeps the chip's own.
fn tuneDrivers(vic: u8) void {
    switch (vic) {
        93, 94, 95 => {
            hdmi(0x100).* = 0x00;
            hdmi(0x1BB).* = 0x40;
            hdmi(0x1BC).* = 0x40;
            hdmi(0x1BD).* = 0x40;
            hdmi(0x1BF).* = 0x02;
            hdmi(0x1C0).* = 0x22;
        },
        16, 31 => {
            hdmi(0x1BF).* = 0x02;
            hdmi(0x1C0).* = 0x22;
        },
        1, 3, 4 => {
            hdmi(0x1BF).* = 0x00;
            hdmi(0x1C0).* = 0x00;
        },
        else => {},
    }
}

/// The mode's timing given to the transmitter (inno_hdmi_config_video_timing).
fn videoTiming(mode: *const edid.Timing) void {
    const htotal = mode.htotal();
    const vtotal = mode.vtotal();
    hdmi16(VIDEO_EXT_HTOTAL, htotal);
    hdmi16(VIDEO_EXT_HBLANK, htotal - mode.width);
    hdmi16(VIDEO_EXT_HDELAY, mode.h_sync + mode.h_back);
    hdmi16(VIDEO_EXT_HDURATION, mode.h_sync);
    hdmi16(VIDEO_EXT_VTOTAL, vtotal);
    hdmi(VIDEO_EXT_VBLANK).* = (vtotal - mode.height) & 0xFF;
    hdmi(VIDEO_EXT_VDELAY).* = (mode.v_sync + mode.v_back) & 0xFF;
    hdmi(VIDEO_EXT_VDURATION).* = mode.v_sync & 0xFF;
    var control = TIMING_EXTERNAL;
    if (mode.hsync_high) control |= TIMING_HSYNC_HIGH;
    if (mode.vsync_high) control |= TIMING_VSYNC_HIGH;
    hdmi(VIDEO_TIMING_CTL).* = control;
}

/// The AVI infoframe the transmitter sends with each frame, as the P4's
/// HDMI bridge sends it: RGB, its active format the picture, underscanned;
/// the picture's aspect; IT content in full-range RGB - a computer's
/// picture, which a television may then show without cropping its edges
/// or treating it as video - and CEA's number for the mode, 0 for one
/// that has none. U-Boot's left the version and the checksum 0, so a
/// monitor threw it away.
fn infoframe(mode: *const edid.Timing) void {
    // The aspect a numbered mode is named with (720x480 and 720x576 are
    // each 4:3 under one number, 16:9 under another), else the picture's.
    const aspect: u8 = switch (mode.vic) {
        1, 2, 17 => 1,
        3, 18 => 2,
        else => if (mode.width * 3 == mode.height * 4) 1 else if (mode.width * 9 == mode.height * 16) 2 else 0,
    };
    var frame: [PACKET_BYTES]u8 = @splat(0);
    frame[0] = 0x82; // AVI, version 2, 13 bytes
    frame[1] = 0x02;
    frame[2] = 0x0D;
    frame[4] = 0x10 | 0x02;
    frame[5] = aspect << 4 | 0x08;
    frame[6] = 0x80 | 2 << 2;
    frame[7] = mode.vic;
    var sum: u8 = 0;
    for (frame) |byte| sum +%= byte;
    frame[3] = 0 -% sum;
    hdmi(PACKET_BUF_INDEX).* = PACKET_AVI;
    for (frame, 0..) |byte, i| hdmi(PACKET_ADDR + i).* = byte;
}

/// The display brought up in `mode` - its pixel clock one the
/// transmitter's PLL makes (`phy.sends`) - showing the picture at
/// `address`, 32 bits a pixel, rows `pitch` bytes apart, below 4 GiB and
/// out of the caches. With the display up, it changes to `mode`.
/// `waiter.wait(micros)` waits that long.
pub fn start(mode: *const edid.Timing, address: usize, pitch: u32, waiter: anytype) Failure {
    const pll = phy.find(mode.pixel_khz) orelse return .clock;
    const woken = wake(waiter);
    if (woken != .none) return woken;

    // The panel stopped, and the controller on the divider's clock while
    // the PLL changes.
    dc(PANEL_START).* = 0;
    reg(VOUTCLK_DC8200_PIX0).* = CLK_ENABLE;

    // The transmitter's PHY (inno_hdmi_setup): the PLLs set for the clock
    // and locked, the LDO and the serializer on, the drivers tuned;
    // powered down while the mode's timing and infoframe are set, up again
    // with its drivers on.
    hdmi(0x1B0).* |= 0x4;
    hdmi(0x1CC).* = 0xF;
    setPll(pll);
    if (!locked(PLL_PRE_LOCKED) or !locked(PLL_POST_LOCKED)) return .pll;
    hdmi(0x1B4).* = 0x7;
    hdmi(0x1BE).* = 0x71;
    tuneDrivers(mode.vic);
    hdmi(SYS_CTRL).* = PHY_POWER_DOWN;
    videoTiming(mode);
    infoframe(mode);
    hdmi(0xC9).* = 0x10;
    hdmi(SYS_CTRL).* = PHY_POWER_ON;
    hdmi(0x1B2).* = 0x8F;
    waiter.wait(50_000);
    hdmi(PHY_SYNC).* = 0x00;
    hdmi(PHY_SYNC).* = 0x01;

    // The controller's pixel clock from the PLL: the mode's own.
    reg(VOUTCLK_DC8200_PIX0).* = CLK_ENABLE | PIX_FROM_HDMI;

    // The controller: the mode from the picture at `address`, to the
    // transmitter (sf_display_init).
    const size = mode.width | mode.height << 15;
    const hsync_start = mode.width + mode.h_front;
    const vsync_start = mode.height + mode.v_front;
    dc(INTERRUPT_ENABLE).* = 0xC000_1FFF;
    dc(0x1CC0).* = 0x0000_2000;
    dc(0x1800).* = 0x0000_0000;
    dc(0x24D8).* = 0x0000_0000;
    dc(FRAMEBUFFER_BOTTOM_RIGHT).* = size;
    dc(FRAMEBUFFER_SIZE).* = size;
    dc(FRAMEBUFFER_ADDRESS).* = @truncate(address);
    dc(FRAMEBUFFER_STRIDE).* = pitch;
    dc(0x1CE8).* = 0x0000_0F61;
    dc(0x2510).* = 0x0000_2042;
    dc(0x2508).* = 0x808A_3156;
    dc(0x2500).* = 0x8008_E1B2;
    dc(0x1518).* = 0x1800_0000;
    dc(0x1CC0).* = 0x0000_3000;
    dc(0x1540).* = 0x0006_0000;
    dc(0x2540).* = 0x0000_0001;
    dc(0x1540).* = 0x8006_0000;
    dc(0x1544).* = 0x0006_0000;
    dc(0x2544).* = 0x0000_0002;
    dc(0x1544).* = 0x8006_0000;
    dc(0x1548).* = 0x0006_0000;
    dc(0x2548).* = 0x0000_000C;
    dc(0x1548).* = 0x8006_0000;
    dc(0x154C).* = 0x0006_0000;
    dc(0x254C).* = 0x0000_000D;
    dc(0x154C).* = 0x8006_0000;
    dc(0x2518).* = 0x0000_0001;
    dc(0x1A28).* = 0x0000_0000;
    dc(DISPLAY_H).* = mode.htotal() << 16 | mode.width;
    dc(DISPLAY_H_SYNC).* = hsync_start | (hsync_start + mode.h_sync) << 15 | SYNC_ON | (if (mode.hsync_high) 0 else SYNC_LOW);
    dc(DISPLAY_V).* = mode.vtotal() << 16 | mode.height;
    dc(DISPLAY_V_SYNC).* = vsync_start | (vsync_start + mode.v_sync) << 15 | SYNC_ON | (if (mode.vsync_high) 0 else SYNC_LOW);
    dc(0x14B0).* = 0x0000_0000;
    dc(0x1CD0).* = 0x0000_00D2;
    dc(0x14B8).* = 0x0000_0005;
    dc(0x14D0).* = 0x0000_0052;
    dc(0x1528).* = 0xDEAD_BEEF;
    dc(0x1418).* = 0x0000_1111;
    dc(0x1410).* = 0x0000_0000;
    dc(0x2518).* = 0x0000_0000;
    dc(0x1468).* = 0x0020_0024;
    dc(0x1484).* = 0x0000_0000;
    dc(0x1468).* = 0x0020_0024;
    dc(0x24E8).* = 0x0000_0C24;
    dc(0x24FC).* = 0x0000_0000;
    dc(0x24E8).* = 0x0000_0C24;
    dc(PANEL_START).* = 0x0000_0001;
    return .none;
}

/// The pixel clock - the TMDS clock, with eight bits a colour - the
/// transmitter's PLL is set to, in kHz, read back from it; 0 while the
/// transmitter is not up, or set to none of `phy.zig`'s. What the HDMI
/// port's sound gives the monitor its rate by.
pub fn pixelClockKhz() u32 {
    if (reg(PMU_CURR_POWER_MODE).* & DOMAIN_VOUT == 0) return 0;
    if (reg(VOUT_RESET_STATUS).* & VOUTRST_HDMI_TX == 0) return 0;
    var regs: [6]u8 = undefined;
    for (&regs, 0..) |*value, i| value.* = @truncate(hdmi(PLL_PRE_SETTINGS + i).*);
    var frac: [3]u8 = undefined;
    for (&frac, 0..) |*value, i| value.* = @truncate(hdmi(PLL_PRE_FRACTION + i).*);
    return phy.clockOf(regs, frac);
}

/// Whether the port can send a mode of that pixel clock.
pub const sends = phy.sends;

/// The shadow registers held, for writes that are to be taken together
/// (`let go`), as Linux's driver writes a plane.
fn hold() void {
    dc(PANEL_CONFIG_EX).* |= PANEL_HOLD;
    dc(FRAMEBUFFER_CONFIG_EX).* &= ~FRAMEBUFFER_SHADOW;
}

fn letGo() void {
    dc(FRAMEBUFFER_CONFIG_EX).* |= FRAMEBUFFER_SHADOW;
    dc(PANEL_CONFIG_EX).* &= ~PANEL_HOLD;
}

/// What the controller raised since this was last asked, cleared: 0 when
/// the interrupt was not its.
pub fn takeInterrupts() u32 {
    return dc(INTERRUPT_ACKNOWLEDGE).*;
}

/// The picture at `address` shown from now on.
pub fn show(address: usize) void {
    hold();
    dc(FRAMEBUFFER_ADDRESS).* = @truncate(address);
    letGo();
}

/// The largest cursor image, each way.
pub const cursor_side = 64;

/// The cursor plane, all of it at once as Linux's driver writes it: the
/// image at `address` (`cursor_side` square, or half that when `small`),
/// its hot spot at (x, y) on the picture, shown or not. A new place alone
/// is not taken: the controller fetches it with the configuration, whose
/// UPDATE is written after it.
pub fn cursor(address: usize, small: bool, hot_x: u32, hot_y: u32, x: u32, y: u32, shown: bool) void {
    hold();
    dc(CURSOR_ADDRESS).* = @truncate(address);
    dc(CURSOR_LOCATION).* = (x & 0x3FFF) | (y & 0x3FFF) << 16;
    const config = (hot_x & 0xFF) << 16 | (hot_y & 0xFF) << 8 | (if (small) 0 else CURSOR_SIZE_64) | CURSOR_UPDATE | CURSOR_VALID;
    dc(CURSOR_CONFIG).* = if (shown) config | CURSOR_ARGB8888 else config;
    letGo();
}
