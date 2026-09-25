// SPDX-License-Identifier: MPL-2.0
//! What the tags say a panel is.
//!
//! Everything this driver needs, read out of the tag list once at create
//! and kept in the board's own instance: the peripheral's `Setup`, the
//! three control lines wherever the board has them wired, and how the
//! picture is fed. A tag that is not there takes the default beside it in
//! `sdk/libs/rtg/tags.zig`; a tag that has to be there and is not makes the
//! create fail rather than the panel come up wrong.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const tags = rtg.tags;
const RtgBase = sdk.interface.rtg.RtgBase;
const BoardPin = sdk.expansion.BoardPin;
const st = sdk.expansion.systemtags;
const lcd = @import("lcd.zig");

pub const Config = struct {
    setup: lcd.Setup = .{},
    /// The panel's own lines, wherever they are.
    reset_pin: BoardPin = .{},
    display_pin: BoardPin = .{},
    backlight_pin: BoardPin = .{},
    /// How long reset is held, and how long the panel is then given.
    reset_ms: u32 = 10,
    settle_ms: u32 = 20,
    /// How many lines one of the two buffers the panel is really fed from
    /// holds. The height has to divide by it.
    bounce_lines: u32 = 10,
    /// How many pictures the display memory holds (`RTGA_Buffers`): as
    /// many as there is room for, down to one.
    buffers: u32 = 1,
    /// Where the stream sits on the bus.
    dma_priority: u32 = sdk.resources.dma.DMA_MAXPRI,
};

/// A line of the panel's part, from its PART_Pin* tag; absent: not wired.
fn pinFrom(rb: *RtgBase, tag: u32, tag_list: ?[*]const TagItem) BoardPin {
    return BoardPin.of(rb.GetRtgTagData(tag, 0, tag_list));
}

/// Read the tags. Null if one that has to be there is not.
pub fn read(rb: *RtgBase, tag_list: ?[*]const TagItem) ?Config {
    var config = Config{};
    const get = struct {
        fn u32At(base: *RtgBase, tag: u32, default: u32, list: ?[*]const TagItem) u32 {
            return @truncate(base.GetRtgTagData(tag, default, list));
        }
    };

    const setup = &config.setup;
    setup.width = get.u32At(rb, tags.RTGA_Width, 0, tag_list);
    setup.height = get.u32At(rb, tags.RTGA_Height, 0, tag_list);
    const format: rtg.PixelFormat = @enumFromInt(get.u32At(rb, tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.rgb565), tag_list));
    setup.bits_per_pixel = rtg.bitmaps.formatBits(format);
    setup.pixel_clock_hz = get.u32At(rb, tags.RTGA_RGB_PixelClock, 0, tag_list);
    setup.hsync_pulse = get.u32At(rb, tags.RTGA_RGB_HSyncPulse, 0, tag_list);
    setup.hsync_back_porch = get.u32At(rb, tags.RTGA_RGB_HSyncBackPorch, 0, tag_list);
    setup.hsync_front_porch = get.u32At(rb, tags.RTGA_RGB_HSyncFrontPorch, 0, tag_list);
    setup.vsync_pulse = get.u32At(rb, tags.RTGA_RGB_VSyncPulse, 0, tag_list);
    setup.vsync_back_porch = get.u32At(rb, tags.RTGA_RGB_VSyncBackPorch, 0, tag_list);
    setup.vsync_front_porch = get.u32At(rb, tags.RTGA_RGB_VSyncFrontPorch, 0, tag_list);
    setup.active_start = get.u32At(rb, tags.RTGA_RGB_ActiveStart, 0, tag_list);

    const flags = get.u32At(rb, tags.RTGA_RGB_Flags, 0, tag_list);
    setup.pclk_active_low = flags & tags.RTGRGBF_PCLK_ACTIVE_LOW != 0;
    setup.hsync_idle_low = flags & tags.RTGRGBF_HSYNC_IDLE_LOW != 0;
    setup.vsync_idle_low = flags & tags.RTGRGBF_VSYNC_IDLE_LOW != 0;

    setup.data_width = get.u32At(rb, tags.RTGA_RGB_DataWidth, 16, tag_list);
    const pins_at = rb.GetRtgTagData(tags.RTGA_RGB_DataPins, 0, tag_list);
    if (pins_at == 0 or setup.data_width == 0 or setup.data_width > setup.data_pins.len) return null;
    const pins: [*]const u8 = @ptrFromInt(pins_at);
    // Copied, not kept: the caller's array is the caller's.
    var i: u32 = 0;
    while (i < setup.data_width) : (i += 1) setup.data_pins[i] = pins[i];

    setup.pclk_pin = @truncate(get.u32At(rb, tags.RTGA_RGB_PclkPin, 0, tag_list));
    setup.hsync_pin = @truncate(get.u32At(rb, tags.RTGA_RGB_HSyncPin, 0, tag_list));
    setup.vsync_pin = @truncate(get.u32At(rb, tags.RTGA_RGB_VSyncPin, 0, tag_list));
    setup.de_pin = @truncate(get.u32At(rb, tags.RTGA_RGB_DePin, 0, tag_list));

    config.reset_pin = pinFrom(rb, st.PART_PinReset, tag_list);
    config.display_pin = pinFrom(rb, st.PART_PinEnable, tag_list);
    config.backlight_pin = pinFrom(rb, st.PART_PinBacklight, tag_list);
    config.reset_ms = get.u32At(rb, tags.RTGA_ResetMillis, 10, tag_list);
    config.settle_ms = get.u32At(rb, tags.RTGA_SettleMillis, 20, tag_list);
    config.bounce_lines = get.u32At(rb, tags.RTGA_RGB_BounceLines, 10, tag_list);
    config.buffers = @max(get.u32At(rb, tags.RTGA_Buffers, 1, tag_list), 1);
    config.dma_priority = get.u32At(rb, tags.RTGA_RGB_DmaPriority, sdk.resources.dma.DMA_MAXPRI, tag_list);

    // A panel with no size, no clock or no blanking is not a panel.
    if (setup.width == 0 or setup.height == 0) return null;
    if (setup.pixel_clock_hz == 0) return null;
    if (setup.hsync_pulse == 0 or setup.vsync_pulse == 0) return null;
    // 16 bits a pixel is what this peripheral is driven at here.
    if (setup.bits_per_pixel != 16) return null;
    return config;
}
