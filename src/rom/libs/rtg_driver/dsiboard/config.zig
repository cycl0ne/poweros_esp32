// SPDX-License-Identifier: MPL-2.0
//! What the tags say a DSI panel is.
//!
//! Everything this driver needs, read out of the tag list once at create
//! and kept in the board's own instance: the picture's size and format,
//! the link (lanes, lane rate), the pixel clock and the timings - which
//! the library reads (`ReadTimingTags`) - the panel's bring-up, the
//! D-PHY's supply, and the panel's reset and backlight lines wherever the
//! board has them. A part that is an HDMI
//! bridge (CHIP_LT8912B) has no bring-up of its own: it says where on
//! I2C the bridge is instead. A tag that is not there
//! takes the default beside it in `sdk/libs/rtg/tags.zig`; a tag that has
//! to be there and is not makes the create fail rather than the panel come
//! up wrong.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const tags = rtg.tags;
const RtgBase = sdk.interface.rtg.RtgBase;
const RtgDriverBase = sdk.interface.rtgdriver.RtgDriverBase;
const BoardPin = sdk.expansion.BoardPin;
const st = sdk.expansion.systemtags;
const host = @import("host.zig");

pub const Config = struct {
    /// What is on the link: a panel's controller, or the HDMI bridge
    /// (CHIP_LT8912B).
    chip: u32 = st.CHIP_ANY,
    /// The bridge's I2C unit and main address.
    i2c_unit: u32 = 0,
    i2c_address: u32 = 0,
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
    /// The sync pulses' polarity, as the mode's standard has them.
    hsync_high: bool = false,
    vsync_high: bool = false,
    /// The panel's bring-up: steps as the boards' lists write them.
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

fn u32At(rb: *RtgDriverBase, tag: u32, default: u32, tag_list: ?[*]const TagItem) u32 {
    return @truncate(rb.GetRtgTagData(tag, default, tag_list));
}

/// The library as a program calls it, for a call that is not a driver's
/// own.
fn programs(rb: *RtgDriverBase) *RtgBase {
    return @ptrCast(rb);
}

/// Read the tags. Null if one that has to be there is not, or the panel
/// asks for what this host cannot do.
pub fn read(rb: *RtgDriverBase, tag_list: ?[*]const TagItem) ?Config {
    var config = Config{};
    config.chip = u32At(rb, st.PART_Chip, st.CHIP_ANY, tag_list);
    config.i2c_unit = u32At(rb, st.PART_BusUnit, 0, tag_list);
    config.i2c_address = u32At(rb, st.PART_Address, 0, tag_list);
    // The picture and its timings: a size, a clock and both sync pulses,
    // or it is nothing this host streams to.
    var timings: rtg.RtgTimings = .{};
    if (!rb.ReadTimingTags(tag_list, &timings)) return null;
    if (timings.pixel_clock_hz == 0) return null;
    config.width = timings.h_active;
    config.height = timings.v_active;
    config.pixel_hz = timings.pixel_clock_hz;
    config.hsync = timings.h_sync;
    config.hbp = timings.h_back;
    config.hfp = timings.h_front;
    config.vsync = timings.v_sync;
    config.vbp = timings.v_back;
    config.vfp = timings.v_front;
    config.hsync_high = timings.flags & rtg.modes.RTGTM_HSYNC_HIGH != 0;
    config.vsync_high = timings.flags & rtg.modes.RTGTM_VSYNC_HIGH != 0;
    // The screens are RGB565, whatever the link carries. The number is
    // looked at before it is taken for a format: one no format has is
    // refused, not a trap.
    const format = u32At(rb, tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.rgb565), tag_list);
    if (format != @intFromEnum(rtg.PixelFormat.rgb565)) return null;
    config.format = .rgb565;
    config.bits_per_pixel = programs(rb).RtgFormatBits(format);
    config.lanes = u32At(rb, tags.RTGA_DSI_Lanes, 0, tag_list);
    config.lane_mbps = u32At(rb, tags.RTGA_DSI_LaneRate, 0, tag_list);
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

    // What the host's and the bridge's fields hold: a picture of twelve
    // bits each way, a line and a frame of sixteen. One too small to be a
    // burst of the stream is none either.
    if (config.width < 8 or config.height < 8) return null;
    if (config.width > 0xFFF or config.height > 0xFFF) return null;
    const line = @as(u64, config.hsync) + config.hbp + config.width + config.hfp;
    const lines = @as(u64, config.vsync) + config.vbp + config.height + config.vfp;
    if (line > 0xFFFF or lines > 0xFFFF) return null;
    if (config.lanes < 1 or config.lanes > 2) return null;
    // A rate the PHY takes, and one its PLL makes or comes near.
    if (host.pllFor(config.lane_mbps) == null) return null;
    const hdmi = config.chip == st.CHIP_LT8912B;
    // The lanes carry the picture: all of them together at least the bits
    // the pixel clock asks for - RGB888 over a bridge to a monitor.
    const carried: u64 = @as(u64, config.lanes) * config.lane_mbps * 1_000_000;
    const wanted: u64 = @as(u64, config.pixel_hz) * (if (hdmi) 24 else config.bits_per_pixel);
    if (carried < wanted) return null;
    if (hdmi) {
        if (config.i2c_address == 0) return null;
    } else {
        if (config.init_sequence == null or config.init_length == 0) return null;
        // A panel is streamed its screens as they lie in memory, a row
        // whole cache lines: a width that is not gives rows the stream
        // cannot follow.
        if ((config.width * (config.bits_per_pixel / 8)) % sdk.hardware.DCACHE_LINE_SIZE != 0) return null;
    }
    return config;
}
