// SPDX-License-Identifier: MPL-2.0
//! The ESP32-S3's LCD_CAM peripheral in RGB mode, which drives the board's
//! panel: a pixel clock, the two sync signals and a data enable on four
//! pads, sixteen bits of colour on sixteen more.
//!
//! In RGB mode the peripheral asks for pixels continuously and the DMA
//! feeds it: there is no frame to kick off and no interrupt to service.
//! Set the timings, point a looping DMA chain at a framebuffer, start it,
//! and the panel refreshes for as long as the board is on. Writing to the
//! framebuffer is all that changing the picture takes.
//!
//! The panel's own numbers - resolution, pixel clock, the six blanking
//! figures and which pad carries which bit - come in as a `Setup`. This
//! file is the peripheral and nothing else: it knows no board, so a
//! different panel is a different Setup and not a different driver.
//!
//! The DMA belongs to the caller: it needs dma.resource, and a resource
//! needs exec. This file is registers and nothing else, so the driver
//! allocates the channel and the chain and hands them over, the way
//! flash.device drives `spiflash.zig`.

const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const gpio = hardware.gpio;
const system = hardware.system;
const signals = hardware.signals;

const base = hardware.map.LCD_CAM;

// The registers, as offsets from the base.
const lcd_clock = 0x00;
const lcd_user = 0x14;
const lcd_misc = 0x18;
const lcd_ctrl = 0x1C;
const lcd_ctrl1 = 0x20;
const lcd_ctrl2 = 0x24;
const lc_dma_int_ena = 0x64;
const lc_dma_int_st = 0x6C;
const lc_dma_int_clr = 0x70;

/// The frame has ended and the vertical blanking has begun. The one moment
/// at which the pixel stream may be touched without the picture slipping.
pub const INT_VSYNC: u32 = 1 << 0;

// LCD_CLOCK
const clk_clkcnt_n_shift: u5 = 0;
const clk_equ_sysclk: u32 = 1 << 6;
const clk_ck_idle_edge: u32 = 1 << 7;
const clk_ck_out_edge: u32 = 1 << 8;
const clk_clkm_div_num_shift: u5 = 9;
const clk_clkm_div_b_shift: u5 = 17;
const clk_clkm_div_a_shift: u5 = 23;
const clk_sel_shift: u5 = 29;
const clk_en: u32 = 1 << 31;

// LCD_USER
const user_dout_cyclelen_shift: u5 = 0;
const user_always_out_en: u32 = 1 << 13;
const user_update: u32 = 1 << 20;
const user_2byte_en: u32 = 1 << 23;
const user_dout: u32 = 1 << 24;
const user_dummy: u32 = 1 << 25;
const user_cmd: u32 = 1 << 26;
const user_start: u32 = 1 << 27;
const user_reset: u32 = 1 << 28;

// LCD_MISC
const misc_vfk_cyclelen_shift: u5 = 6;
const misc_vbk_cyclelen_shift: u5 = 12;
const misc_next_frame_en: u32 = 1 << 25;
const misc_bk_en: u32 = 1 << 26;
const misc_afifo_reset: u32 = 1 << 27;
const misc_cd_idle_edge: u32 = 1 << 31;

// LCD_CTRL: the back porch, the active height and the total height.
const ctrl_hb_front_shift: u5 = 0; // 11 bits
const ctrl_va_height_shift: u5 = 11; // 10 bits
const ctrl_vt_height_shift: u5 = 21; // 10 bits
const ctrl_rgb_mode_en: u32 = 1 << 31;

// LCD_CTRL1
const ctrl1_vb_front_shift: u5 = 0; // 8 bits
const ctrl1_ha_width_shift: u5 = 8; // 12 bits
const ctrl1_ht_width_shift: u5 = 20; // 12 bits

// LCD_CTRL2
const ctrl2_vsync_width_shift: u5 = 0; // 7 bits
const ctrl2_vsync_idle_pol: u32 = 1 << 7;
const ctrl2_de_idle_pol: u32 = 1 << 8;
const ctrl2_hs_blank_en: u32 = 1 << 9;
const ctrl2_hsync_width_shift: u5 = 16; // 7 bits
const ctrl2_hsync_idle_pol: u32 = 1 << 23;
const ctrl2_hsync_position_shift: u5 = 24;

/// The GPIO matrix signals. The sixteen data lines are consecutive.
const sig_data0: u32 = signals.LCD_DATA_OUT0;
const sig_de: u32 = signals.LCD_H_ENABLE;
const sig_hsync: u32 = signals.LCD_H_SYNC;
const sig_vsync: u32 = signals.LCD_V_SYNC;
const sig_pclk: u32 = signals.LCD_PCLK;

/// The clock the pixel clock is divided down from: LCD_CLK_SEL 2 is the
/// 240 MHz PLL, which divides exactly to this panel's 30 MHz.
const clk_sel_pll240: u32 = 2;
const pll240_hz: u32 = 240_000_000;

/// dma.resource's peripheral number for this one, which the caller
/// connects its channel to.
pub const dma_peripheral: u32 = 5;

/// A panel, in the terms this peripheral needs it. Whoever drives the
/// peripheral fills one in; where those numbers come from - a board's own
/// wiring, a tag list, a panel's data sheet - is not this file's business.
pub const Setup = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    /// Bits a pixel on the bus. 16 is what this file drives.
    bits_per_pixel: u32 = 16,
    pixel_clock_hz: u32 = 0,
    /// In pixel clocks.
    hsync_pulse: u32 = 0,
    hsync_back_porch: u32 = 0,
    hsync_front_porch: u32 = 0,
    /// In lines.
    vsync_pulse: u32 = 0,
    vsync_back_porch: u32 = 0,
    vsync_front_porch: u32 = 0,
    /// Where the active area starts in the line, counted from the start of
    /// the sync pulse. 0: worked out from the pulse the peripheral can
    /// actually emit (see `emittedPulse`).
    active_start: u32 = 0,
    /// The data is taken on the falling edge of the pixel clock.
    pclk_active_low: bool = false,
    /// The sync lines rest low rather than high.
    hsync_idle_low: bool = false,
    vsync_idle_low: bool = false,
    /// The pads: the colour bits least significant first, then the four
    /// timing signals.
    data_pins: [24]u8 = .{0} ** 24,
    data_width: u32 = 16,
    pclk_pin: u8 = 0,
    hsync_pin: u8 = 0,
    vsync_pin: u8 = 0,
    de_pin: u8 = 0,
};

/// The sync pulse the peripheral can actually emit. Its width field is
/// seven bits and wraps rather than saturating, so a pulse longer than 128
/// comes out short - and a back porch measured from the width that was
/// asked for puts every line that much late, which shows as the picture
/// sliding sideways with one end wrapped round to the other. Measure the
/// porch from what is emitted and the line total stays true.
pub fn emittedPulse(want: u32) u32 {
    if (want == 0) return 0;
    return ((want - 1) & 0x7F) + 1;
}

fn r(offset: usize) *volatile u32 {
    return reg(base + offset);
}

/// The dividers for a pixel clock: the peripheral clock is the source over
/// `group`, and the pixel clock is that over `prescale`.
const Divide = struct { group: u32, prescale: u32 };

fn divideFor(want_hz: u32) Divide {
    // The group divider may not be 1, so start at 2 and take the first
    // pair whose product lands on the wanted clock.
    var group: u32 = 2;
    while (group <= 16) : (group += 1) {
        const lcd_clk = pll240_hz / group;
        if (lcd_clk % want_hz != 0) continue;
        const prescale = lcd_clk / want_hz;
        if (prescale >= 1 and prescale <= 64) return .{ .group = group, .prescale = prescale };
    }
    // Nothing exact: the nearest that is not faster than asked for, since
    // a panel tolerates a slow clock better than one past its rating.
    const prescale = (pll240_hz / 2 + want_hz - 1) / want_hz;
    return .{ .group = 2, .prescale = @min(64, @max(1, prescale)) };
}

/// The pads the panel is on, routed out through the GPIO matrix: as many
/// colour bits as it has, then the four timing signals.
pub fn pins(setup: *const Setup) void {
    var i: u32 = 0;
    while (i < setup.data_width and i < setup.data_pins.len) : (i += 1) {
        route(setup.data_pins[i], sig_data0 + i);
    }
    route(setup.pclk_pin, sig_pclk);
    route(setup.hsync_pin, sig_hsync);
    route(setup.vsync_pin, sig_vsync);
    route(setup.de_pin, sig_de);
}

/// One pad, driven by the peripheral. Push-pull, hardest drive: these
/// switch at 30 MHz into a ribbon cable.
fn route(pin: u8, signal: u32) void {
    gpio.toMatrix(pin);
    gpio.driveStrength(pin, 3);
    gpio.outputEnable(pin, true);
    gpio.connectOut(pin, signal, false);
}

/// The peripheral, set up for the board's panel but not yet running. The
/// DMA has to be pointed at a framebuffer and started before `start`.
pub fn setUp(setup: *const Setup) void {
    const p = setup;

    // What the panel amounts to in the peripheral's own terms, kept for
    // the calls that work in them afterwards.
    line_total = p.hsync_pulse + p.hsync_back_porch + p.width + p.hsync_front_porch;
    active_start = if (p.active_start != 0)
        p.active_start
    else
        p.hsync_back_porch + emittedPulse(p.hsync_pulse);

    enable();

    // Stop whatever it was doing, and empty the pixel FIFO.
    r(lcd_user).* = 0;
    r(lcd_user).* |= user_reset; // self clearing
    r(lcd_misc).* |= misc_afifo_reset; // self clearing

    const d = divideFor(p.pixel_clock_hz);
    var clock: u32 = clk_en |
        (clk_sel_pll240 << clk_sel_shift) |
        (d.group << clk_clkm_div_num_shift) |
        (1 << clk_clkm_div_a_shift); // a fraction of 0/1: none
    if (d.prescale == 1) {
        clock |= clk_equ_sysclk;
    } else {
        clock |= (d.prescale - 1) << clk_clkcnt_n_shift;
    }
    // Which edge of the pixel clock the data is taken on. The panel's.
    if (p.pclk_active_low) clock |= clk_ck_out_edge;
    r(lcd_clock).* = clock;

    // RGB mode, two bytes a pixel, the data phase only, and output that
    // never stops: the DMA decides how much there is, not a length here.
    r(lcd_user).* = user_always_out_en | user_2byte_en | user_dout;
    r(lcd_ctrl).* = ctrl_rgb_mode_en;

    // One blank cycle each side of the frame, which an RGB panel always
    // has, and the frame repeated for as long as the DMA feeds it.
    r(lcd_misc).* = misc_bk_en | misc_next_frame_en |
        (0 << misc_vfk_cyclelen_shift) | (0 << misc_vbk_cyclelen_shift);

    timing(setup);
}

/// The panel's blanking, in the peripheral's terms: it counts a back porch
/// from the start of the sync pulse, and totals rather than front porches.
fn timing(setup: *const Setup) void {
    const p = setup;

    // Where the active area starts, less one.
    const hb_front = active_start - 1;
    const ht_width = p.hsync_pulse + p.hsync_back_porch + p.width + p.hsync_front_porch - 1;
    const vb_front = p.vsync_back_porch + p.vsync_pulse - 1;
    const vt_height = p.vsync_pulse + p.vsync_back_porch + p.height + p.vsync_front_porch - 1;

    r(lcd_ctrl).* = ctrl_rgb_mode_en |
        ((hb_front & 0x7FF) << ctrl_hb_front_shift) |
        (((p.height - 1) & 0x3FF) << ctrl_va_height_shift) |
        ((vt_height & 0x3FF) << ctrl_vt_height_shift);

    r(lcd_ctrl1).* =
        ((vb_front & 0xFF) << ctrl1_vb_front_shift) |
        (((p.width - 1) & 0xFFF) << ctrl1_ha_width_shift) |
        ((ht_width & 0xFFF) << ctrl1_ht_width_shift);

    // The sync pulse widths are seven bits each. A pulse that does not fit
    // comes out wrapped, which is what `active_start` is measured from
    // rather than from the width that was asked for.
    // Which way round the sync lines rest is the panel's: leave the
    // polarity bits at zero for a panel that rests them high and every
    // pulse is inverted, so it measures each line and each frame from the
    // wrong edge and the picture sits sideways.
    var ctrl2: u32 =
        (((p.vsync_pulse - 1) & 0x7F) << ctrl2_vsync_width_shift) |
        (((p.hsync_pulse - 1) & 0x7F) << ctrl2_hsync_width_shift) |
        ctrl2_hs_blank_en | // HSYNC goes on through the porches
        (0 << ctrl2_hsync_position_shift); // at the start of the line
    if (!p.hsync_idle_low) ctrl2 |= ctrl2_hsync_idle_pol;
    if (!p.vsync_idle_low) ctrl2 |= ctrl2_vsync_idle_pol;
    r(lcd_ctrl2).* = ctrl2;
}

/// Where the active area starts in the line, counted from the start of the
/// sync pulse. The panel and the peripheral have to agree about this to the
/// pixel: too small and the picture slides left with its left edge wrapping
/// round to the right, too large and it slides right.
///
/// It starts as the figure the panel's own numbers give and may be moved
/// afterwards, which is what a picture that sits sideways is measured and
/// corrected with. The field is eleven bits and the line is shorter than
/// that, so a shift either way can be taken round the line rather than run
/// off the end of it.
pub var active_start: u32 = 0;

/// How long a line is, in pixel clocks: the whole of it, blanking and all.
/// A shift of the active area is modulo this. Set by `setUp`, so it is 0
/// until the peripheral has been given a panel.
pub var line_total: u32 = 0;

pub fn lineTotal() u32 {
    return line_total;
}

/// Move the active area to `start` pixels after the start of the sync
/// pulse, taken modulo the line. The peripheral latches a timing change
/// where `update` is set, so this belongs in the vertical blanking with the
/// pixel stream's realignment: written into a running frame, the timing
/// generator and the DMA part company for good.
pub fn setActiveStart(pixels: u32) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    if (line_total == 0) return;
    active_start = pixels % line_total;
    const c = r(lcd_ctrl).*;
    r(lcd_ctrl).* = (c & ~@as(u32, 0x7FF << ctrl_hb_front_shift)) |
        (((active_start - 1) & 0x7FF) << ctrl_hb_front_shift);
    r(lcd_user).* |= user_update;
}

pub fn backPorch() u32 {
    return ((r(lcd_ctrl).* >> ctrl_hb_front_shift) & 0x7FF) + 1;
}

pub fn intEnable(mask: u32) void {
    r(lc_dma_int_ena).* = mask;
}

pub fn intStatus() u32 {
    return r(lc_dma_int_st).*;
}

pub fn intClear(mask: u32) void {
    r(lc_dma_int_clr).* = mask;
}

/// Empty the pixel FIFO. The first pixel the panel takes after a start is
/// whatever is at the head of this, so it has to be empty at the moment
/// the DMA begins - anything left in it shifts the whole picture sideways
/// by however many pixels it held.
pub fn fifoReset() linksection(".iram.text") void {
    @setRuntimeSafety(false);
    r(lcd_misc).* |= misc_afifo_reset; // self clearing
}

/// Let it run. The DMA must already be feeding it.
pub fn start() linksection(".iram.text") void {
    @setRuntimeSafety(false);
    const u = r(lcd_user);
    u.* |= user_update; // take the timings written above
    u.* |= user_start;
}

pub fn stop() linksection(".iram.text") void {
    @setRuntimeSafety(false);
    const u = r(lcd_user);
    u.* &= ~user_start;
    u.* |= user_update;
}

/// The bus clock on and the peripheral out of reset. It comes up held in
/// reset, and a register read while it is answers zero whatever the
/// hardware is, so this has to happen before anything is written or read.
pub fn enable() void {
    system.enable(.lcd_cam);
}
