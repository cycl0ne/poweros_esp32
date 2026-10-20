// SPDX-License-Identifier: MIT
//! What C:test/Raster and C:test/Cube give the rasterizer core of the
//! system: exec's workers, rtg's RefreshRect for a buffer of the screen's,
//! exec's memory and the timer.

const sdk = @import("sdk");
const raster = @import("raster");
const exec = sdk.exec;
const rtg = sdk.rtg;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const TimerBase = timer.TimerBase;

/// A display's pixels by name, for saying what was found.
pub fn pixelsNamed(format: rtg.bitmaps.PixelFormat) [*:0]const u8 {
    return switch (format) {
        inline .rgba32, .bgra32, .rgb24, .bgr24, .rgb565, .argb1555, .indexed8, .gray8, .mono1 => |named| @tagName(named),
        _ => "of a format not known here",
    };
}

pub const System = struct {
    sys: *ExecBase,
    rb: *RtgBase,
    tb: *TimerBase,
    bitmap: *rtg.RtgBitMap,

    pub fn host(system: *System) raster.Host {
        return .{ .context = system, .share = &share, .hand_on = &handOn, .allocate = &allocate, .free = &free, .now = &clock };
    }

    /// The same on one core, handing on nothing: for plain memory.
    pub fn alone(system: *System) raster.Host {
        return .{ .context = system, .share = &raster.Host.oneAfterAnother, .hand_on = &handNowhere, .allocate = &allocate, .free = &free, .now = &clock };
    }

    fn handNowhere(_: ?*anyopaque, _: raster.Rect) void {}

    fn clock(context: ?*anyopaque) u64 {
        return now(of(context).tb);
    }

    fn of(context: ?*anyopaque) *System {
        return @ptrCast(@alignCast(context.?));
    }

    fn share(context: ?*anyopaque, work: raster.Work, data: ?*anyopaque, parts: u32) u32 {
        return of(context).sys.ShareWork(work, data, parts);
    }

    fn handOn(context: ?*anyopaque, area: raster.Rect) void {
        const system = of(context);
        const rect = rtg.RtgRect{ .x = @intCast(area.x), .y = @intCast(area.y), .width = @intCast(area.width), .height = @intCast(area.height) };
        _ = system.rb.RefreshRect(system.bitmap, &rect);
    }

    fn allocate(context: ?*anyopaque, bytes: usize) ?[*]u8 {
        return @ptrCast(of(context).sys.AllocVec(bytes, exec.MEMF_ANY));
    }

    fn free(context: ?*anyopaque, memory: [*]u8, bytes: usize) void {
        _ = bytes;
        of(context).sys.FreeVec(memory);
    }
};

/// Microseconds from the timer's start.
pub fn now(tb: *TimerBase) u64 {
    var ev: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&ev);
    return ev.toTicks() * 1_000_000 / rate;
}
