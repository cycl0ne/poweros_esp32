// SPDX-License-Identifier: MPL-2.0
//! What the tags say a panel is.
//!
//! Everything this driver needs, read out of the tag list once at create
//! and kept in the board's own instance: the panel's timings, which the
//! library reads (`ReadTimingTags`), the peripheral's `Setup` made of
//! them, the three control lines wherever the board has them wired, and
//! how the picture is fed. A tag that is not there takes the default
//! beside it in `sdk/libs/rtg/tags.zig`; a tag that has to be there and is
//! not, or says what the peripheral cannot do, makes the create fail
//! rather than the panel come up wrong.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const tags = rtg.tags;
const RtgBase = sdk.interface.rtg.RtgBase;
const RtgDriverBase = sdk.interface.rtgdriver.RtgDriverBase;
const BoardPin = sdk.expansion.BoardPin;
const st = sdk.expansion.systemtags;
const lcd = @import("lcd.zig");

pub const Config = struct {
    /// The panel's timings, as its part's tags give them: the board's one
    /// mode.
    timings: rtg.RtgTimings = .{},
    setup: lcd.Setup = .{},
    /// The panel's own lines, wherever they are.
    reset_pin: BoardPin = .{},
    display_pin: BoardPin = .{},
    backlight_pin: BoardPin = .{},
    /// How long reset is held, and how long the panel is then given.
    reset_ms: u32 = 10,
    settle_ms: u32 = 20,
    /// How many lines one of the buffers the panel is really fed from
    /// holds. The height has to divide by it.
    bounce_lines: u32 = 10,
    /// How many pictures the board may have at once (`RTGA_Buffers`),
    /// each taken from system memory as it is asked for.
    buffers: u32 = 1,
    /// Where the stream sits on the bus.
    dma_priority: u32 = sdk.resources.dma.DMA_MAXPRI,
};

/// A line of the panel's part, from its PART_Pin* tag; absent: not wired.
fn pinFrom(rb: *RtgDriverBase, tag: u32, tag_list: ?[*]const TagItem) BoardPin {
    return BoardPin.of(rb.GetRtgTagData(tag, 0, tag_list));
}

/// The library as a program calls it, for a call that is not a driver's
/// own.
fn programs(rb: *RtgDriverBase) *RtgBase {
    return @ptrCast(rb);
}

/// Read the tags. Null if one that has to be there is not.
pub fn read(rb: *RtgDriverBase, tag_list: ?[*]const TagItem) ?Config {
    var config = Config{};
    const get = struct {
        fn u32At(base: *RtgDriverBase, tag: u32, default: u32, list: ?[*]const TagItem) u32 {
            return @truncate(base.GetRtgTagData(tag, default, list));
        }
    };

    // The panel's timings: a size, a clock and both sync pulses, or it is
    // not a panel this peripheral streams to.
    const timings = &config.timings;
    if (!rb.ReadTimingTags(tag_list, timings)) return null;
    if (timings.pixel_clock_hz == 0) return null;
    // 16 bits a pixel in RGB565 is what this peripheral is driven at here.
    // The number is looked at before it is taken for a format: one no
    // format has is refused, not a trap.
    const format = get.u32At(rb, tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.rgb565), tag_list);
    if (format != @intFromEnum(rtg.PixelFormat.rgb565)) return null;

    const setup = &config.setup;
    setup.width = timings.h_active;
    setup.height = timings.v_active;
    setup.bits_per_pixel = programs(rb).RtgFormatBits(format);
    setup.pixel_clock_hz = timings.pixel_clock_hz;
    setup.hsync_pulse = timings.h_sync;
    setup.hsync_back_porch = timings.h_back;
    setup.hsync_front_porch = timings.h_front;
    setup.vsync_pulse = timings.v_sync;
    setup.vsync_back_porch = timings.v_back;
    setup.vsync_front_porch = timings.v_front;
    setup.active_start = get.u32At(rb, tags.RTGA_RGB_ActiveStart, 0, tag_list);

    // A sync pulse that is high is a line that rests low.
    setup.pclk_active_low = timings.flags & rtg.modes.RTGTM_PCLK_FALLING != 0;
    setup.pclk_idle_high = timings.flags & rtg.modes.RTGTM_PCLK_IDLE_HIGH != 0;
    setup.hsync_idle_low = timings.flags & rtg.modes.RTGTM_HSYNC_HIGH != 0;
    setup.vsync_idle_low = timings.flags & rtg.modes.RTGTM_VSYNC_HIGH != 0;
    setup.de_idle_high = timings.flags & rtg.modes.RTGTM_DE_LOW != 0;

    // What the peripheral's fields hold: a picture and a line of twelve
    // bits, a frame of ten, a back porch counted from the sync's start of
    // eight. A figure past them would be cut to them without a word.
    if (!lcd.fits(setup)) return null;
    // A row of a buffer is whole cache lines, which the copy reads the
    // picture in: a width that is not gives rows the stream cannot follow.
    if ((setup.width * (setup.bits_per_pixel / 8)) % sdk.hardware.DCACHE_LINE_SIZE != 0) return null;

    setup.data_width = get.u32At(rb, tags.RTGA_RGB_DataWidth, 16, tag_list);
    const pins_at = rb.GetRtgTagData(tags.RTGA_RGB_DataPins, 0, tag_list);
    if (pins_at == 0 or setup.data_width == 0 or setup.data_width > setup.data_pins.len) return null;
    const pins: [*]const u8 = @ptrFromInt(pins_at);
    // Copied, not kept: the caller's array is the caller's.
    @memcpy(setup.data_pins[0..setup.data_width], pins[0..setup.data_width]);

    // The four timing signals' pads, each needed: one left out is not
    // pad 0. The pixel clock's is the part's clock line, a pad of the
    // chip's own.
    const clock = pinFrom(rb, st.PART_PinClock, tag_list);
    if (clock.kind != sdk.expansion.boardpin.BPIN_GPIO or clock.number > 0xFF) return null;
    setup.pclk_pin = @truncate(clock.number);
    const no_pad: u32 = 0xFFFF_FFFF;
    const signal_pads = [_]struct { tag: u32, into: *u8 }{
        .{ .tag = tags.RTGA_RGB_HSyncPin, .into = &setup.hsync_pin },
        .{ .tag = tags.RTGA_RGB_VSyncPin, .into = &setup.vsync_pin },
        .{ .tag = tags.RTGA_RGB_DePin, .into = &setup.de_pin },
    };
    for (signal_pads) |signal| {
        const pad = get.u32At(rb, signal.tag, no_pad, tag_list);
        if (pad > 0xFF) return null;
        signal.into.* = @truncate(pad);
    }
    setup.drive_strength = @intCast(@min(get.u32At(rb, tags.RTGA_RGB_DriveStrength, 3, tag_list), 3));

    config.reset_pin = pinFrom(rb, st.PART_PinReset, tag_list);
    config.display_pin = pinFrom(rb, st.PART_PinEnable, tag_list);
    config.backlight_pin = pinFrom(rb, st.PART_PinBacklight, tag_list);
    config.reset_ms = get.u32At(rb, tags.RTGA_ResetMillis, 10, tag_list);
    config.settle_ms = get.u32At(rb, tags.RTGA_SettleMillis, 20, tag_list);
    config.bounce_lines = get.u32At(rb, tags.RTGA_RGB_BounceLines, 10, tag_list);
    config.buffers = @max(get.u32At(rb, tags.RTGA_Buffers, 1, tag_list), 1);
    config.dma_priority = get.u32At(rb, tags.RTGA_RGB_DmaPriority, sdk.resources.dma.DMA_MAXPRI, tag_list);

    return config;
}
