// SPDX-License-Identifier: MIT
//! volume.docklet: how loud the machine plays (audio.device), as a
//! speaker with its sound waves.
//!
//! The speaker is in the text pen, with three waves before it: as many in
//! the fill pen as the volume reaches - one up to a third, two up to two
//! thirds, all three above - the rest in the track's. At 0 there is a
//! cross where the waves would be, and on a machine without sound the
//! speaker is struck through. It looks every second, so a volume set by
//! Volume or in a shell (`Audio VOLUME 50`) shows at once. What it says:
//! "Volume 60%, Speaker" - the output played through - or "No sound". A
//! click on it runs SYS:Programs/Volume.

const sdk = @import("sdk");
const audio = sdk.devices.audio;
const audiocontrol = sdk.devices.audiocontrol;
const docklets = sdk.docklets;

pub const Data = struct {
    /// The device, opened for its triggers; null without sound.
    control: ?audiocontrol.Control = null,
    percent: u32 = 0,
    /// The output played through, as the device names it.
    output: [32:0]u8 = @splat(0),
    read: bool = false,
    text: [64]u8 = @splat(0),
};

const Class = docklets.DockletClass(Data, .{
    .name = docklets.VOLUME_CLASS,
    .version = 1,
    .date = "27.10.2026",
    .title = "Volume",
    .command = "SYS:Programs/Volume",
    .begin = begin,
    .end = end,
    .look = look,
    .text = text,
    .draw = draw,
});
pub const Library = Class.Library;
comptime {
    _ = Library;
}

fn begin(base: *sdk.gadgets.Base, own: *Data) bool {
    own.control = audiocontrol.Control.open(base.sys_base);
    return true;
}

fn end(base: *sdk.gadgets.Base, own: *Data) void {
    _ = base;
    if (own.control) |*control| control.close();
    own.control = null;
}

fn look(base: *sdk.gadgets.Base, own: *Data) bool {
    const control = if (own.control) |*open| open else {
        if (own.read) return false;
        own.read = true;
        docklets.say(&own.text, "No sound");
        return true;
    };
    var info: audio.AudioInfo = .{};
    const percent = if (control.query(&info)) audiocontrol.percentOf(info.master) else 0;
    var output: [32:0]u8 = @splat(0);
    if (info.output) |name| {
        var n: usize = 0;
        while (n < output.len and name[n] != 0) : (n += 1) output[n] = name[n];
    }
    if (own.read and percent == own.percent and sameName(&output, &own.output)) return false;
    own.read = true;
    own.percent = percent;
    own.output = output;
    if (output[0] != 0) {
        _ = docklets.format(base.sys_base, &own.text, "Volume %u%%, %s", .{ percent, @as([*:0]const u8, &own.output) });
    } else {
        _ = docklets.format(base.sys_base, &own.text, "Volume %u%%", .{percent});
    }
    return true;
}

fn sameName(a: *const [32:0]u8, b: *const [32:0]u8) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn text(own: *Data) [*:0]const u8 {
    return @ptrCast(&own.text);
}

fn draw(own: *Data, f: *const docklets.Frame) void {
    const p = f.pens;
    const middle = f.part(1, 2);
    // The speaker: a box and the cone before it.
    const back = f.part(12, 100);
    const neck = f.part(28, 100);
    const mouth = f.part(46, 100);
    f.box(back, f.part(38, 100), neck + 1, f.part(62, 100), p.text);
    f.polygon(&.{ .{ neck, f.part(38, 100) }, .{ mouth, f.part(20, 100) }, .{ mouth, f.part(80, 100) }, .{ neck, f.part(62, 100) } }, p.text);
    const line = @max(1, f.part(1, 16));
    if (own.control == null) {
        f.line(back - 1, f.part(80, 100), f.part(88, 100), f.part(20, 100), p.text);
        return;
    }
    const waves: u32 = if (own.percent == 0) 0 else if (own.percent <= 33) 1 else if (own.percent <= 66) 2 else 3;
    if (waves == 0) {
        // A cross where the waves would be.
        const cx = f.part(72, 100);
        const half = f.part(12, 100);
        f.line(cx - half, middle - half, cx + half, middle + half, p.text);
        f.line(cx - half, middle + half, cx + half, middle - half, p.text);
        return;
    }
    for (0..3) |k| {
        const radius = f.part(16 + 13 * @as(i32, @intCast(k)), 100);
        f.arc(mouth - f.part(4, 100), middle, radius, radius - line, -45, 45, if (k < waves) p.fill else p.track);
    }
}
