// SPDX-License-Identifier: MPL-2.0
//! What the tags say a DSI panel is.
//!
//! Everything this driver needs, read out of the tag list once at create
//! and kept in the board's own instance: the picture's size and format,
//! the link (lanes, lane rate), the pixel clock and the timings, the
//! panel's bring-up, the D-PHY's supply, and the panel's reset and
//! backlight lines wherever the board has them. A tag that is not there
//! takes the default beside it in `sdk/libs/rtg/tags.zig`; a tag that has
//! to be there and is not makes the create fail rather than the panel come
//! up wrong.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const tags = rtg.tags;
const RtgBase = sdk.interface.rtg.RtgBase;
const BoardPin = sdk.expansion.BoardPin;
const st = sdk.expansion.systemtags;
const host = @import("host.zig");

pub const Config = struct {
    width: u32 = 0,
    height: u32 = 0,
    format: rtg.PixelFormat = .rgb565,
    bits_per_pixel: u32 = 16,
    lanes: u32 = 0,
    lane_mbps: u32 = 0,
    pixel_hz: u32 = 0,
    hsync: u32 = 0,
    hbp: u32 = 0,
    hfp: u32 = 0,
    vsync: u32 = 0,
    vbp: u32 = 0,
    vfp: u32 = 0,
    /// The panel's bring-up: steps as `dcsStep` writes them.
    init_sequence: ?[*]const u8 = null,
    init_length: u32 = 0,
    /// The LDO channel that feeds the D-PHY, 0 for none, and its voltage.
    phy_ldo: u32 = 0,
    phy_millivolts: u32 = 0,
    /// The panel's own lines, wherever they are.
    reset_pin: BoardPin = .{},
    backlight_pin: BoardPin = .{},
    /// How long reset is held, and how long the panel is then given.
    reset_ms: u32 = 10,
    settle_ms: u32 = 20,
    /// How many pictures the board may have at once (`RTGA_Buffers`),
    /// each taken from system memory as it is asked for.
    buffers: u32 = 1,
};

fn u32At(rb: *RtgBase, tag: u32, default: u32, tag_list: ?[*]const TagItem) u32 {
    return @truncate(rb.GetRtgTagData(tag, default, tag_list));
}

/// Read the tags. Null if one that has to be there is not, or the panel
/// asks for what this host cannot do.
pub fn read(rb: *RtgBase, tag_list: ?[*]const TagItem) ?Config {
    var config = Config{};
    config.width = u32At(rb, tags.RTGA_Width, 0, tag_list);
    config.height = u32At(rb, tags.RTGA_Height, 0, tag_list);
    config.format = @enumFromInt(u32At(rb, tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.rgb565), tag_list));
    config.bits_per_pixel = rtg.bitmaps.formatBits(config.format);
    config.lanes = u32At(rb, tags.RTGA_DSI_Lanes, 0, tag_list);
    config.lane_mbps = u32At(rb, tags.RTGA_DSI_LaneRate, 0, tag_list);
    config.pixel_hz = u32At(rb, tags.RTGA_DSI_PixelClock, 0, tag_list);
    config.hsync = u32At(rb, tags.RTGA_DSI_HSyncPulse, 0, tag_list);
    config.hbp = u32At(rb, tags.RTGA_DSI_HSyncBackPorch, 0, tag_list);
    config.hfp = u32At(rb, tags.RTGA_DSI_HSyncFrontPorch, 0, tag_list);
    config.vsync = u32At(rb, tags.RTGA_DSI_VSyncPulse, 0, tag_list);
    config.vbp = u32At(rb, tags.RTGA_DSI_VSyncBackPorch, 0, tag_list);
    config.vfp = u32At(rb, tags.RTGA_DSI_VSyncFrontPorch, 0, tag_list);
    const sequence = rb.GetRtgTagData(tags.RTGA_DSI_InitSequence, 0, tag_list);
    if (sequence != 0) config.init_sequence = @ptrFromInt(sequence);
    config.init_length = u32At(rb, tags.RTGA_DSI_InitLength, 0, tag_list);
    config.phy_ldo = u32At(rb, tags.RTGA_DSI_PhyLdo, 0, tag_list);
    config.phy_millivolts = u32At(rb, tags.RTGA_DSI_PhyMillivolts, 2500, tag_list);
    config.reset_pin = BoardPin.of(rb.GetRtgTagData(st.PART_PinReset, 0, tag_list));
    config.backlight_pin = BoardPin.of(rb.GetRtgTagData(st.PART_PinBacklight, 0, tag_list));
    config.reset_ms = u32At(rb, tags.RTGA_ResetMillis, 10, tag_list);
    config.settle_ms = u32At(rb, tags.RTGA_SettleMillis, 20, tag_list);
    config.buffers = @max(u32At(rb, tags.RTGA_Buffers, 1, tag_list), 1);

    if (config.width == 0 or config.height == 0) return null;
    if (config.lanes < 1 or config.lanes > 2) return null;
    if (config.lane_mbps < host.rate_min or config.lane_mbps > host.rate_max) return null;
    if (config.pixel_hz == 0 or config.hsync == 0 or config.vsync == 0) return null;
    if (config.init_sequence == null or config.init_length == 0) return null;
    // The bridge sends what memory holds; 16 bits a pixel is what it is
    // driven at here.
    if (config.format != .rgb565) return null;
    return config;
}
