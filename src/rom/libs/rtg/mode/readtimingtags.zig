// SPDX-License-Identifier: MPL-2.0
//! ReadTimingTags: A part's timings, from its tags.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const tags = rtg.tags;
const TagItem = sdk.utility.TagItem;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Reads the generic timing tags of a list into a structure.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadTimingTags(rb: *RtgBase, tag_list: ?[*]const TagItem, timings: *rtg.RtgTimings) bool
/// ```
///
/// SINCE: 1.19. LVO -384.
///
/// INPUTS:
/// - `tag_list` - a device's tags.
/// - `timings` - where the timings go.
///
/// RESULT:
/// True, and `timings` filled in. False, and `timings` left as it was,
/// for a list without `RTGA_Width` or `RTGA_Height`, and for one that
/// names a pixel clock and lacks a sync pulse.
///
/// BEHAVIOR:
/// `RTGA_Width` and `RTGA_Height` are the picture; `RTGA_PixelClock` the
/// clock; `RTGA_HSyncPulse`, `RTGA_HBackPorch`, `RTGA_HFrontPorch` and
/// the three for the vertical the blanking; `RTGA_TimingFlags` the
/// `RTGTM_*` flags. A tag that is not there reads as 0. A list with no
/// clock is a display that has none - a controller behind a bus - and
/// needs no more than its size; one with a clock is a panel that is
/// streamed its picture, and a panel without a sync pulse is not one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself: it reads the list.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddBoardMode`, `GetRtgTagData`
///
/// EXAMPLES:
/// ```zig
/// var timings: rtg.RtgTimings = .{};
/// if (!rb.ReadTimingTags(tag_list, &timings)) return rtg.errors.RTGERR_BAD_TAGS;
/// ```
pub fn ReadTimingTags(rb: *RtgBase, tag_list: ?[*]const TagItem, timings: *rtg.RtgTimings) bool {
    const ub = rb.utility_base;
    const read: rtg.RtgTimings = .{
        .pixel_clock_hz = @truncate(ub.GetTagData(tags.RTGA_PixelClock, 0, tag_list)),
        .h_active = @truncate(ub.GetTagData(tags.RTGA_Width, 0, tag_list)),
        .h_front = @truncate(ub.GetTagData(tags.RTGA_HFrontPorch, 0, tag_list)),
        .h_sync = @truncate(ub.GetTagData(tags.RTGA_HSyncPulse, 0, tag_list)),
        .h_back = @truncate(ub.GetTagData(tags.RTGA_HBackPorch, 0, tag_list)),
        .v_active = @truncate(ub.GetTagData(tags.RTGA_Height, 0, tag_list)),
        .v_front = @truncate(ub.GetTagData(tags.RTGA_VFrontPorch, 0, tag_list)),
        .v_sync = @truncate(ub.GetTagData(tags.RTGA_VSyncPulse, 0, tag_list)),
        .v_back = @truncate(ub.GetTagData(tags.RTGA_VBackPorch, 0, tag_list)),
        .flags = @truncate(ub.GetTagData(tags.RTGA_TimingFlags, 0, tag_list)),
    };
    if (read.h_active == 0 or read.v_active == 0) return false;
    if (read.pixel_clock_hz != 0 and (read.h_sync == 0 or read.v_sync == 0)) return false;
    timings.* = read;
    return true;
}
