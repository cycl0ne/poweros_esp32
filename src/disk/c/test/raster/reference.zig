// SPDX-License-Identifier: MIT
//! The scenes C:test/Raster and C:test/Cube draw, drawn on the host, small,
//! and compared with the pictures of them kept in reference/: what the
//! rasterizer's tests on the board look like, held still. Each is drawn
//! twice, into 32 bits a pixel and into 565 - NAME-565, dithered as it is
//! written back - and each has a picture of its own. A picture may differ
//! from its reference by 2 in a channel anywhere - in 565 by a step - and
//! by more in a few pixels: a texel picked on the other side of a border
//! by a float's last bit, on a host that rounds differently.
//!
//! When one differs by more, what was drawn is written to
//! .zig-cache/raster/NAME.ppm, to be looked at, and copied over
//! reference/NAME.ppm when the change was meant. The pictures are PPMs,
//! 160 x 120, 565 widened to 8 bits a channel as a display shows it.

const std = @import("std");
const raster = @import("raster");
const scenes = @import("scenes.zig");
const testing = std.testing;

const width = 160;
const height = 120;
const aspect: f32 = @as(f32, width) / height;
const whole = raster.Viewport{ .x = 0, .y = 0, .width = width, .height = height };

/// The pixels in a picture that may differ by more than 2 in a channel,
/// or by more than a step in 565.
const most_apart = width * height / 1000;

/// The formats each scene is drawn in, and what its picture's name ends in.
const formats = [_]struct { format: raster.Format, suffix: []const u8 }{
    .{ .format = .bgra32, .suffix = "" },
    .{ .format = .rgb565, .suffix = "-565" },
};

fn allocate(_: ?*anyopaque, bytes: usize) ?[*]u8 {
    const memory = testing.allocator.alloc(u8, bytes) catch return null;
    return memory.ptr;
}

fn free(_: ?*anyopaque, memory: [*]u8, bytes: usize) void {
    testing.allocator.free(memory[0..bytes]);
}

fn handNowhere(_: ?*anyopaque, _: raster.Rect) void {}

const host = raster.Host{
    .share = &raster.Host.oneAfterAnother,
    .hand_on = &handNowhere,
    .allocate = &allocate,
    .free = &free,
};

/// A picture in a format and the target over it.
const Picture = struct {
    format: raster.Format,
    memory: [width * height]u32 align(64) = undefined,
    target: raster.Target = undefined,

    fn begin(picture: *Picture, attachments: raster.Attachments) !void {
        const surface = raster.Surface{ .pixels = @ptrCast(&picture.memory), .pitch = width * picture.format.bytes(), .width = width, .height = height, .format = picture.format };
        picture.target = try raster.Target.init(host, surface, .{ .width = width, .height = height }, attachments);
        picture.target.begin();
    }

    fn finish(picture: *Picture) void {
        _ = picture.target.finish();
        picture.target.deinit();
    }

    /// Pixel `at` as 0xRRGGBB: 565 widened as a display widens it, each
    /// channel's top bits repeated below.
    fn color(picture: *const Picture, at: usize) u32 {
        return switch (picture.format) {
            .bgra32 => picture.memory[at] & 0xFF_FFFF,
            .rgba32 => raster.Format.rgba32.pack(picture.memory[at]) & 0xFF_FFFF,
            .rgb565 => wide: {
                const pixel: u32 = @as([*]const u16, @ptrCast(&picture.memory))[at];
                const red = pixel >> 11;
                const green = pixel >> 5 & 0x3F;
                const blue = pixel & 0x1F;
                break :wide (red << 3 | red >> 2) << 16 | (green << 2 | green >> 4) << 8 | (blue << 3 | blue >> 2);
            },
        };
    }

    /// The bits of each channel the format keeps: what a channel of 8 is
    /// shifted right by to be compared.
    fn dropped(picture: *const Picture) [3]u3 {
        return switch (picture.format) {
            .bgra32, .rgba32 => .{ 0, 0, 0 },
            .rgb565 => .{ 3, 2, 3 },
        };
    }

    /// The picture against reference/`name`.ppm.
    fn expectLike(picture: *const Picture, comptime name: []const u8) !void {
        const kept = @embedFile("reference/" ++ name ++ ".ppm");
        const header = std.fmt.comptimePrint("P6\n{d} {d}\n255\n", .{ width, height });
        // In steps of the format: 2 of 8 bits, one of 565.
        const slack: u32 = if (picture.format == .rgb565) 1 else 2;
        const shifts = picture.dropped();
        var apart: u32 = 0;
        var worst: u32 = 0;
        if (kept.len != header.len + width * height * 3 or !std.mem.eql(u8, kept[0..header.len], header)) {
            apart = width * height;
        } else for (0..width * height) |at| {
            const pixel = picture.color(at);
            var most: u32 = 0;
            for (0..3, shifts) |channel, shift| {
                const got: i32 = @intCast((pixel >> @intCast(16 - channel * 8) & 0xFF) >> shift);
                const want: i32 = kept[header.len + at * 3 + channel] >> shift;
                most = @max(most, @abs(got - want));
            }
            worst = @max(worst, most);
            if (most > slack) apart += 1;
        }
        if (apart <= most_apart) return;
        std.debug.print("{s}: {d} pixels apart from the reference (worst by {d}); drawn: .zig-cache/raster/{s}.ppm\n", .{ name, apart, worst, name });
        picture.write(name) catch |err| std.debug.print("{s} not written: {s}\n", .{ name, @errorName(err) });
        return error.TestExpectedEqual;
    }

    fn write(picture: *const Picture, comptime name: []const u8) !void {
        const header = std.fmt.comptimePrint("P6\n{d} {d}\n255\n", .{ width, height });
        var bytes: [header.len + width * height * 3]u8 = undefined;
        @memcpy(bytes[0..header.len], header);
        for (0..width * height) |at| {
            const pixel = picture.color(at);
            for (0..3) |channel| bytes[header.len + at * 3 + channel] = @truncate(pixel >> @intCast(16 - channel * 8));
        }
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(testing.io, ".zig-cache/raster");
        try cwd.writeFile(testing.io, .{ .sub_path = ".zig-cache/raster/" ++ name ++ ".ppm", .data = &bytes });
    }
};

/// The pattern's texture in `format`, its memory the caller's to free.
fn patternTexture(format: raster.TextureFormat) !struct { texture: raster.Texture, memory: []u8 } {
    const memory = try testing.allocator.alignedAlloc(u8, .@"8", scenes.textureBytes(format));
    return .{ .texture = scenes.patternTexture(format, memory.ptr), .memory = memory };
}

const Backdrop = raster.Pipeline(.{ .color = .smooth, .cull = .none, .depth = .less });
const Box = raster.Pipeline(.{ .color = .texture, .front = .clockwise, .depth = .less });

/// `draw`'s scene in each format, against its picture; and in 565 exactly
/// what was drawn in 32 bits, dithered: the tiles are drawn the same in
/// both, and only written back differently.
fn expectScene(comptime name: []const u8, comptime draw: fn (picture: *Picture) anyerror!void) !void {
    var pictures: [formats.len]Picture = undefined;
    inline for (formats, &pictures) |kind, *picture| {
        picture.* = .{ .format = kind.format };
        try draw(picture);
        try picture.expectLike(name ++ kind.suffix);
    }
    var dithered: [width * height]u16 = undefined;
    const packing = raster.Packing.of(.rgb565);
    for (0..height) |y| {
        packing.store(@ptrCast(dithered[y * width ..].ptr), pictures[0].memory[y * width ..].ptr, width, 0, @intCast(y));
    }
    try testing.expectEqualSlices(u16, &dithered, @as([*]const u16, @ptrCast(&pictures[1].memory))[0 .. width * height]);
}

test "the cube, turned, textured over its backdrop" {
    try expectScene("cube", drawCube);
}

fn drawCube(picture: *Picture) !void {
    const made = try patternTexture(.rgba8888);
    defer testing.allocator.free(made.memory);
    try picture.begin(.{ .depth = .{ .used = true } });
    try raster.draw(&picture.target, &Backdrop{ .viewport = whole }, &scenes.backdrop(Backdrop.Vertex), &scenes.quad_indices);
    const box = Box{ .viewport = whole, .transform = scenes.cubeTransform(0.6, 4.5, aspect), .texture = &made.texture };
    try raster.draw(&picture.target, &box, &scenes.cube(Box.Vertex), &scenes.cube_indices);
    picture.finish();
}

test "the corridor, nearest in 565, every level of the texture" {
    try expectScene("corridor", drawCorridor);
}

fn drawCorridor(picture: *Picture) !void {
    const made = try patternTexture(.rgb565);
    defer testing.allocator.free(made.memory);
    const Corridor = raster.Pipeline(.{ .color = .texture, .sampling = .{ .format = .rgb565, .filter = .nearest }, .cull = .none });
    try picture.begin(.{});
    const pipeline = Corridor{ .viewport = whole, .transform = scenes.corridorTransform(aspect), .texture = &made.texture };
    try raster.draw(&picture.target, &pipeline, &scenes.corridor(Corridor.Vertex), &scenes.corridor_indices);
    picture.finish();
}

test "smooth colours laid over the corridor by their alpha" {
    try expectScene("glass", drawGlass);
}

fn drawGlass(picture: *Picture) !void {
    const made = try patternTexture(.rgba8888);
    defer testing.allocator.free(made.memory);
    const Corridor = raster.Pipeline(.{ .color = .texture, .cull = .none });
    const Glass = raster.Pipeline(.{ .color = .smooth, .cull = .none, .blend = .alpha });
    try picture.begin(.{});
    const corridor = Corridor{ .viewport = whole, .transform = scenes.corridorTransform(aspect), .texture = &made.texture };
    try raster.draw(&picture.target, &corridor, &scenes.corridor(Corridor.Vertex), &scenes.corridor_indices);
    const glass = [_]Glass.Vertex{
        .{ .position = .{ -0.9, -0.9, 0.5 }, .color = 0xC0FF_2020 },
        .{ .position = .{ 0.6, -0.7, 0.5 }, .color = 0x4020_FF20 },
        .{ .position = .{ -0.5, 0.8, 0.5 }, .color = 0x8020_20FF },
        .{ .position = .{ 0.9, 0.9, 0.5 }, .color = 0xFFFF_FFFF },
        .{ .position = .{ -0.7, 0.6, 0.5 }, .color = 0x0000_0000 },
        .{ .position = .{ 0.7, -0.8, 0.5 }, .color = 0x80FF_C000 },
    };
    try raster.draw(&picture.target, &Glass{ .viewport = whole }, &glass, &[_]u16{ 0, 1, 2, 3, 4, 5 });
    picture.finish();
}
