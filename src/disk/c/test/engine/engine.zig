// SPDX-License-Identifier: MIT
//! Engine: the display board's engine - FillRect, CopyRect, BlendPixels,
//! BlendRect and ScalePixels - checked against what the CPU does, and
//! timed beside it, in each pixel format it may be given. Built against
//! the SDK only.
//!
//!   Engine ROUNDS/K/N,LOAD/K/N,DRAG/K/N
//!
//! The cases run first in the format the display runs in, then in RGB565
//! and BGRA32 where that is neither: the formats boards' engines draw in.
//! In each, two buffers the size of a screen are taken from the display
//! board and filled with a pattern of their coordinates. Each case is
//! then done by the board and checked: every pixel inside the rectangle
//! has what it should, every pixel outside it what it had. The cases are
//! rectangles that start and end anywhere in a cache line, a whole
//! buffer, one too small for the engine, copies between the two buffers
//! and within one, and a copy whose two rectangles overlap - which the
//! board may refuse, and the caller then does in software; and a copy out
//! of plain memory, described for the engine. Each case is timed over
//! ROUNDS runs (5 if not given), and the same work done by the CPU beside
//! it.
//!
//! Every case's line starts with who did it: `engine` when the board did,
//! `SOFTWARE` when it would be left to software - the board has no engine
//! for it, or refused it (too small, an overlap, a format it does not
//! draw in). A refusal is checked too: the buffer has to be as it was, as
//! the software that does the job then expects. Each format ends with how
//! many cases the engine took. A board that says it has an engine but took
//! none of the cases in the display's format ends the run with a warning.
//!
//! The blends and the scale are checked against graphics.library doing
//! the same in software, on plain memory of the same format painted
//! alike: a picture with coverage laid over the buffer, at full and at
//! half strength, and in the order the engine refuses (`rgba32`); a
//! translucent colour; a picture scaled smooth by ratios the engine
//! reaches, and one it does not. Every pixel outside the rectangle has to
//! be what it was. Inside, a blend may differ by one step of the format -
//! 1/31 of a channel of five bits, 1/255 of one of eight - where the
//! engine rounds its own way; a scale is mixed by the engine's own
//! sampling, so how far it lies from the CPU's is printed, and only a
//! large difference is a fault. The CPU's time is graphics.library's.
//! At the end, the frames the display starved of while all that ran.
//!
//! LOAD n instead does n fills of a whole buffer by the board, then n by
//! the CPU, in the display's format, and prints the display's starved
//! frames before and after each: whether the panel's stream holds up
//! while the memory it streams out of is that busy.
//!
//! DRAG n instead lays an overlay of 128 x 128 - a round icon - over the
//! picture, following the pointer as a dragged icon does, and moves the
//! pointer n steps across the display and back, as fast as it goes. It
//! prints the time a step takes and the starved frames before and after:
//! whether the stream holds up while the board puts the picture back
//! and lays the images at every step. The pointer goes back where it was.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const rtg = sdk.rtg;
const err = rtg.errors;
const timer = sdk.devices.timer;
const graphics = sdk.graphics;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const TimerBase = timer.TimerBase;
const Printf = dos.stdio.Printf;
const B = rtg.boards;

pub const COMMAND_NAME = "Engine";
const VERSION_STRING = "\x00$VER: Engine 1.3 (19.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "ROUNDS/K/N,LOAD/K/N,DRAG/K/N";

/// A fill: where.
const FillCase = struct { x: i32, y: i32, width: i32, height: i32 };
/// A copy: from where, how much, to where, and whether within one buffer.
const CopyCase = struct { sx: i32, sy: i32, width: i32, height: i32, dx: i32, dy: i32, same: bool };

/// What the cases are cut from: a buffer of at least 480 x 400.
const fills = [_]FillCase{
    .{ .x = 13, .y = 7, .width = 400, .height = 300 },
    .{ .x = 32, .y = 0, .width = 256, .height = 200 },
    .{ .x = 31, .y = 5, .width = 97, .height = 50 },
    .{ .x = 3, .y = 3, .width = 20, .height = 20 },
};
const copies = [_]CopyCase{
    .{ .sx = 5, .sy = 3, .width = 400, .height = 300, .dx = 17, .dy = 11, .same = false },
    .{ .sx = 0, .sy = 0, .width = 256, .height = 150, .dx = 64, .dy = 200, .same = true },
    .{ .sx = 10, .sy = 10, .width = 300, .height = 200, .dx = 40, .dy = 30, .same = true },
};

/// The formats the test draws in, and those the cases also run in where
/// the display runs in neither.
const drawn = [_]rtg.PixelFormat{ .rgb565, .argb1555, .rgba32, .bgra32 };
const also = [_]rtg.PixelFormat{ .rgb565, .bgra32 };

/// What the whole run works with.
const Test = struct {
    sys: *ExecBase,
    dl: *DosBase,
    rb: *RtgBase,
    gb: *GraphicsBase,
    tb: *TimerBase,
    board: *rtg.RtgBoard,
    caps: u32,
    rounds: u32,
    width: u32,
    height: u32,
};

/// What the cases in one format came to: done by the engine, refused,
/// with no engine for them, and wrong.
const Tally = struct { cases: u32 = 0, engine: u32 = 0, refused: u32 = 0, no_engine: u32 = 0, wrong: u32 = 0 };

/// A blend or a scale: what the board did against what graphics.library
/// did on plain memory, both from the same pattern. `outside` counts the
/// pixels outside the rectangle that changed, `off` those inside more
/// than one of the format's steps from the CPU's in a channel, `worst`
/// the largest difference of a channel in eight-bit steps, `sum` all
/// differences.
const Compared = struct { outside: u32 = 0, off: u32 = 0, worst: u32 = 0, sum: u64 = 0, count: u32 = 0 };

/// A channel of a pixel: where it starts, and how many bits it has.
const Channel = struct { shift: u5, bits: u5 };

/// Everything that depends on the pixel format: the type a pixel is, its
/// channels, the bits that make it opaque, the colour the fills use, and
/// the cases drawn and checked in it.
fn Format(comptime format: rtg.PixelFormat) type {
    return struct {
        const Pixel = switch (format) {
            .rgb565, .argb1555 => u16,
            .rgba32, .bgra32 => u32,
            else => @compileError("a format the test does not draw in"),
        };
        const channels: []const Channel = switch (format) {
            .rgb565 => &.{ .{ .shift = 11, .bits = 5 }, .{ .shift = 5, .bits = 6 }, .{ .shift = 0, .bits = 5 } },
            .argb1555 => &.{ .{ .shift = 15, .bits = 1 }, .{ .shift = 10, .bits = 5 }, .{ .shift = 5, .bits = 5 }, .{ .shift = 0, .bits = 5 } },
            else => &.{ .{ .shift = 24, .bits = 8 }, .{ .shift = 16, .bits = 8 }, .{ .shift = 8, .bits = 8 }, .{ .shift = 0, .bits = 8 } },
        };
        const opaque_bits: Pixel = switch (format) {
            .argb1555 => 0x8000,
            .rgba32, .bgra32 => 0xFF00_0000,
            else => 0,
        };
        /// Magenta, opaque, in either order of the channels.
        const fill_color: Pixel = switch (format) {
            .rgb565 => 0xF81F,
            .argb1555 => 0xFC1F,
            else => 0xFFFF_00FF,
        };

        fn at(surface: *const rtg.Surface, x: u32, y: u32) *Pixel {
            const row: [*]Pixel = @ptrCast(@alignCast(surface.pixels.? + @as(usize, y) * surface.pitch));
            return &row[x];
        }

        /// The pattern a buffer starts with: every channel different
        /// from its neighbours', opaque.
        fn patternAt(x: u32, y: u32, seed: u32) Pixel {
            const h = (x *% 0x9E37_79B1) ^ (y *% 0x85EB_CA77) ^ (seed *% 0xC2B2_AE3D);
            return @as(Pixel, @truncate(h ^ h >> 15)) | opaque_bits;
        }

        fn paint(surface: *const rtg.Surface, seed: u32) void {
            var y: u32 = 0;
            while (y < surface.height) : (y += 1) {
                var x: u32 = 0;
                while (x < surface.width) : (x += 1) at(surface, x, y).* = patternAt(x, y, seed);
            }
        }

        /// `count` pixels of row `y` from `x` on, as the CPU fills them.
        fn fillRow(surface: *const rtg.Surface, x: u32, y: u32, count: u32, color: Pixel) void {
            const row: [*]Pixel = @ptrCast(at(surface, x, y));
            @memset(row[0..count], color);
        }

        /// The pixels that are not the pattern any more.
        fn changed(surface: *const rtg.Surface, seed: u32) u32 {
            var wrong: u32 = 0;
            var y: u32 = 0;
            while (y < surface.height) : (y += 1) {
                var x: u32 = 0;
                while (x < surface.width) : (x += 1) {
                    if (at(surface, x, y).* != patternAt(x, y, seed)) wrong += 1;
                }
            }
            return wrong;
        }

        fn checkFill(surface: *const rtg.Surface, case: FillCase, seed: u32) u32 {
            var wrong: u32 = 0;
            var y: u32 = 0;
            while (y < surface.height) : (y += 1) {
                var x: u32 = 0;
                while (x < surface.width) : (x += 1) {
                    const want = if (inside(x, y, case.x, case.y, case.width, case.height)) fill_color else patternAt(x, y, seed);
                    if (at(surface, x, y).* != want) wrong += 1;
                }
            }
            return wrong;
        }

        fn checkCopy(dest: *const rtg.Surface, case: CopyCase, src_seed: u32, dest_seed: u32) u32 {
            var wrong: u32 = 0;
            var y: u32 = 0;
            while (y < dest.height) : (y += 1) {
                var x: u32 = 0;
                while (x < dest.width) : (x += 1) {
                    const want = if (inside(x, y, case.dx, case.dy, case.width, case.height))
                        patternAt(@intCast(@as(i32, @intCast(x)) - case.dx + case.sx), @intCast(@as(i32, @intCast(y)) - case.dy + case.sy), src_seed)
                    else
                        patternAt(x, y, dest_seed);
                    if (at(dest, x, y).* != want) wrong += 1;
                }
            }
            return wrong;
        }

        /// A channel of a pixel, at its own width.
        fn channelOf(pixel: Pixel, comptime channel: Channel) u32 {
            return @as(u32, pixel) >> channel.shift & ((@as(u32, 1) << channel.bits) - 1);
        }

        /// A channel of a pixel, widened to eight bits.
        fn widen(pixel: Pixel, comptime channel: Channel) u32 {
            const value = channelOf(pixel, channel);
            return switch (channel.bits) {
                8 => value,
                1 => value * 255,
                else => value << (8 - channel.bits) | value >> (2 * channel.bits - 8),
            };
        }

        /// The most of its own steps any one channel of two pixels is
        /// apart.
        fn stepsApart(got: Pixel, want: Pixel) u32 {
            var most: u32 = 0;
            inline for (channels) |channel| {
                const one: i32 = @intCast(channelOf(got, channel));
                const two: i32 = @intCast(channelOf(want, channel));
                most = @max(most, @abs(one - two));
            }
            return most;
        }

        fn compare(board_surface: *const rtg.Surface, cpu: *const rtg.Surface, area: rtg.RtgRect, seed: u32) Compared {
            var result = Compared{};
            var y: u32 = 0;
            while (y < board_surface.height) : (y += 1) {
                var x: u32 = 0;
                while (x < board_surface.width) : (x += 1) {
                    const got = at(board_surface, x, y).*;
                    if (!inside(x, y, area.x, area.y, area.width, area.height)) {
                        if (got != patternAt(x, y, seed)) result.outside += 1;
                        continue;
                    }
                    const want = at(cpu, x, y).*;
                    inline for (channels) |channel| {
                        const one = widen(got, channel);
                        const two = widen(want, channel);
                        const difference = if (one > two) one - two else two - one;
                        result.worst = @max(result.worst, difference);
                        result.sum += difference;
                        result.count += 1;
                    }
                    if (stepsApart(got, want) > 1) result.off += 1;
                }
            }
            return result;
        }

        /// Every case in this format, on two buffers of it from the
        /// board. Null when the board has no memory for them.
        fn run(t: *Test, display: bool) ?Tally {
            const first = t.rb.AllocBitMap(t.board, t.width, t.height, @intFromEnum(format), 0) orelse return null;
            defer t.rb.FreeBitMap(first);
            const second = t.rb.AllocBitMap(t.board, t.width, t.height, @intFromEnum(format), 0) orelse return null;
            defer t.rb.FreeBitMap(second);
            _ = Printf(t.dl, "In %s%s: buffers %u x %u, pitch %u, at 0x%08lx and 0x%08lx\n", .{
                nameOf(format),                         word(display, ", the display's format", ""),
                t.width,                                t.height,
                first.pitch,                            @as(u64, @intFromPtr(first.pixels.?)),
                @as(u64, @intFromPtr(second.pixels.?)),
            });
            var tally = Tally{};
            fillCases(t, &tally, first, second);
            copyCases(t, &tally, first, second);
            memoryCopy(t, &tally, first);
            blendCases(t, &tally, first);
            _ = Printf(t.dl, "  %s: the engine did %u of %u cases; %u refused, %u with no engine for them, %u wrong\n", .{
                nameOf(format), tally.engine, tally.cases, tally.refused, tally.no_engine, tally.wrong,
            });
            return tally;
        }

        fn fillCases(t: *Test, tally: *Tally, first: *rtg.RtgBitMap, second: *rtg.RtgBitMap) void {
            for (fills) |case| {
                const area = rtg.RtgRect{ .x = case.x, .y = case.y, .width = case.width, .height = case.height };
                var engine_us: u64 = 0;
                var answer: i32 = err.RTGERR_OK;
                var round: u32 = 0;
                while (round < t.rounds) : (round += 1) {
                    paint(surfaceOf(first), 1);
                    const start = now(t.tb);
                    answer = t.rb.FillRect(first, &area, fill_color);
                    engine_us += now(t.tb) - start;
                }
                var cpu_us: u64 = 0;
                round = 0;
                while (round < t.rounds) : (round += 1) {
                    paint(surfaceOf(second), 1);
                    const start = now(t.tb);
                    var y: i32 = case.y;
                    while (y < case.y + case.height) : (y += 1) fillRow(surfaceOf(second), @intCast(case.x), @intCast(y), @intCast(case.width), fill_color);
                    cpu_us += now(t.tb) - start;
                }
                const wrong = if (answer == err.RTGERR_OK) checkFill(surfaceOf(first), case, 1) else changed(surfaceOf(first), 1);
                begin(t, answer);
                _ = Printf(t.dl, "fill %ux%u at %d,%d", .{ @as(u32, @intCast(case.width)), @as(u32, @intCast(case.height)), case.x, case.y });
                finish(t, tally, answer, B.RTGBC_FILL_RECT, engine_us / t.rounds, cpu_us / t.rounds, wrong);
            }
        }

        fn copyCases(t: *Test, tally: *Tally, first: *rtg.RtgBitMap, second: *rtg.RtgBitMap) void {
            for (copies) |case| {
                const src = first;
                const dest = if (case.same) first else second;
                const dest_seed: u32 = if (case.same) 1 else 2;
                const what = rtg.RtgCopy{ .src_x = case.sx, .src_y = case.sy, .width = case.width, .height = case.height, .dest_x = case.dx, .dest_y = case.dy };
                var engine_us: u64 = 0;
                var answer: i32 = err.RTGERR_OK;
                var round: u32 = 0;
                while (round < t.rounds) : (round += 1) {
                    paint(surfaceOf(first), 1);
                    if (!case.same) paint(surfaceOf(second), 2);
                    const start = now(t.tb);
                    answer = t.rb.CopyRect(src, dest, &what);
                    engine_us += now(t.tb) - start;
                }
                const wrong = if (answer == err.RTGERR_OK) checkCopy(surfaceOf(dest), case, 1, dest_seed) else changed(surfaceOf(dest), dest_seed);
                begin(t, answer);
                _ = Printf(t.dl, "copy %ux%u %d,%d -> %d,%d%s", .{
                    @as(u32, @intCast(case.width)),        @as(u32, @intCast(case.height)),
                    case.sx,                               case.sy,
                    case.dx,                               case.dy,
                    word(case.same, " in one buffer", ""),
                });
                finish(t, tally, answer, B.RTGBC_COPY_RECT, engine_us / t.rounds, null, wrong);
            }
        }

        /// A copy out of plain memory, described for the engine.
        fn memoryCopy(t: *Test, tally: *Tally, dest: *rtg.RtgBitMap) void {
            const bytes = dest.pitch * dest.height;
            const memory = t.sys.AllocVec(bytes, exec.MEMF_ANY) orelse return;
            defer t.sys.FreeVec(memory);
            var plain = rtg.RtgBitMap{ .pixels = @ptrCast(memory), .width = dest.width, .height = dest.height, .pitch = dest.pitch, .format = format };
            paint(surfaceOf(&plain), 2);
            const case = CopyCase{ .sx = 5, .sy = 3, .width = 400, .height = 300, .dx = 17, .dy = 11, .same = false };
            const what = rtg.RtgCopy{ .src_x = case.sx, .src_y = case.sy, .width = case.width, .height = case.height, .dest_x = case.dx, .dest_y = case.dy };
            var engine_us: u64 = 0;
            var answer: i32 = err.RTGERR_OK;
            var round: u32 = 0;
            while (round < t.rounds) : (round += 1) {
                paint(surfaceOf(dest), 1);
                const start = now(t.tb);
                answer = t.rb.CopyRect(&plain, dest, &what);
                engine_us += now(t.tb) - start;
            }
            const wrong = if (answer == err.RTGERR_OK) checkCopy(surfaceOf(dest), case, 2, 1) else changed(surfaceOf(dest), 1);
            begin(t, answer);
            _ = Printf(t.dl, "copy 400x300 from memory at 0x%08lx", .{@as(u64, @intFromPtr(memory))});
            finish(t, tally, answer, B.RTGBC_COPY_RECT, engine_us / t.rounds, null, wrong);
        }

        /// Each blend and scale by the board on `first`, and by
        /// graphics.library in software on plain memory painted alike.
        fn blendCases(t: *Test, tally: *Tally, first: *rtg.RtgBitMap) void {
            const bytes = first.pitch * first.height;
            const memory = t.sys.AllocVec(bytes, exec.MEMF_ANY) orelse return;
            defer t.sys.FreeVec(memory);
            const plain = rtg.Surface{ .pixels = @ptrCast(memory), .width = first.width, .height = first.height, .pitch = first.pitch, .size_bytes = bytes, .format = format };
            const picture_memory = t.sys.AllocVec(picture_width * picture_height * 4, exec.MEMF_ANY) orelse return;
            defer t.sys.FreeVec(picture_memory);
            const picture: [*]u32 = @ptrCast(@alignCast(picture_memory));
            paintPicture(picture, picture_width, picture_height);

            const cpu_tags = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&plain) }, .{} };
            const cpu_rp = t.gb.CreateRastPortTagList(&cpu_tags) orelse return;
            defer t.gb.FreeRastPort(cpu_rp);

            for (blends) |case| {
                const pixels = rtg.RtgPixels{ .pixels = @ptrCast(picture), .pitch = picture_width * 4, .format = case.format };
                var engine_us: u64 = 0;
                var answer: i32 = err.RTGERR_OK;
                var round: u32 = 0;
                while (round < t.rounds) : (round += 1) {
                    paint(surfaceOf(first), 1);
                    const start = now(t.tb);
                    answer = switch (case.kind) {
                        .pixels => t.rb.BlendPixels(first, &case.area, &pixels, case.alpha),
                        .rect => t.rb.BlendRect(first, &case.area, case.color),
                        .scale => t.rb.ScalePixels(first, &case.area, &pixels, case.from_width, case.from_height),
                    };
                    engine_us += now(t.tb) - start;
                }
                var cpu_us: u64 = 0;
                round = 0;
                while (round < t.rounds) : (round += 1) {
                    paint(&plain, 1);
                    const start = now(t.tb);
                    cpuDoes(t.gb, cpu_rp, case, picture);
                    cpu_us += now(t.tb) - start;
                }
                var result = Compared{};
                var wrong: u32 = 0;
                if (answer == err.RTGERR_OK) {
                    result = compare(surfaceOf(first), &plain, case.area, 1);
                    // A scale is the engine's own sampling: far off only
                    // when broken.
                    const mean = if (result.count == 0) 0 else result.sum / result.count;
                    const off = if (case.kind == .scale) (if (mean > 12) @max(result.off, 1) else 0) else result.off;
                    wrong = result.outside + off;
                } else {
                    wrong = changed(surfaceOf(first), 1);
                }
                const name: [*:0]const u8 = switch (case.kind) {
                    .pixels => if (case.format == .rgba32) "blend rgba32" else "blend bgra32",
                    .rect => "blend colour",
                    .scale => "scale",
                };
                const cap = switch (case.kind) {
                    .pixels => B.RTGBC_BLEND_PIXELS,
                    .rect => B.RTGBC_BLEND_RECT,
                    .scale => B.RTGBC_SCALE_PIXELS,
                };
                begin(t, answer);
                _ = Printf(t.dl, "%s %ux%u at %d,%d", .{ name, @as(u32, @intCast(case.area.width)), @as(u32, @intCast(case.area.height)), case.area.x, case.area.y });
                finish(t, tally, answer, cap, engine_us / t.rounds, cpu_us / t.rounds, wrong);
                if (answer == err.RTGERR_OK) _ = Printf(t.dl, "      outside changed %u, off by more than a step %u, worst %u, mean %lu/100\n", .{
                    result.outside, result.off, result.worst, if (result.count == 0) 0 else result.sum * 100 / result.count,
                });
            }
        }

        /// LOAD: `rounds` whole-buffer fills by the board, then by the
        /// CPU, with the display's starved frames before and after each
        /// run.
        fn loadTest(t: *Test, rounds: u32) i32 {
            const bm = t.rb.AllocBitMap(t.board, t.width, t.height, @intFromEnum(format), 0) orelse {
                _ = Printf(t.dl, "No memory for the buffer\n", .{});
                return dos.RETURN_FAIL;
            };
            defer t.rb.FreeBitMap(bm);
            const whole = rtg.RtgRect{ .x = 0, .y = 0, .width = @intCast(bm.width), .height = @intCast(bm.height) };
            var before = starved(t.rb, t.board);
            var start = now(t.tb);
            var round: u32 = 0;
            var refused: u32 = 0;
            while (round < rounds) : (round += 1) {
                if (t.rb.FillRect(bm, &whole, @as(Pixel, @truncate(round)) | opaque_bits) != err.RTGERR_OK) refused += 1;
            }
            var took = now(t.tb) - start;
            _ = Printf(t.dl, "board: %u fills of %ux%u in %s in %lu us (%u refused), starved frames %u -> %u\n", .{
                rounds, bm.width, bm.height, nameOf(format), took, refused, before, starved(t.rb, t.board),
            });
            before = starved(t.rb, t.board);
            start = now(t.tb);
            round = 0;
            while (round < rounds) : (round += 1) {
                var y: u32 = 0;
                while (y < bm.height) : (y += 1) fillRow(surfaceOf(bm), 0, y, bm.width, @as(Pixel, @truncate(round)) | opaque_bits);
            }
            took = now(t.tb) - start;
            _ = Printf(t.dl, "CPU: %u fills of %ux%u in %s in %lu us, starved frames %u -> %u\n", .{
                rounds, bm.width, bm.height, nameOf(format), took, before, starved(t.rb, t.board),
            });
            return dos.RETURN_OK;
        }
    };
}

/// A board's buffer as a surface: an RtgBitMap is one by pointer.
fn surfaceOf(bm: *rtg.RtgBitMap) *const rtg.Surface {
    return @ptrCast(bm);
}

fn inside(x: u32, y: u32, left: i32, top: i32, width: i32, height: i32) bool {
    const sx: i32 = @intCast(x);
    const sy: i32 = @intCast(y);
    return sx >= left and sx < left + width and sy >= top and sy < top + height;
}

fn nameOf(format: rtg.PixelFormat) [*:0]const u8 {
    return switch (format) {
        .rgba32 => "rgba32",
        .bgra32 => "bgra32",
        .rgb24 => "rgb24",
        .bgr24 => "bgr24",
        .rgb565 => "rgb565",
        .argb1555 => "argb1555",
        .indexed8 => "indexed8",
        .gray8 => "gray8",
        .mono1 => "mono1",
        _ => "an unknown format",
    };
}

/// The start of a case's line: who did it.
fn begin(t: *Test, answer: i32) void {
    _ = Printf(t.dl, "  %s  ", .{word(answer == err.RTGERR_OK, "engine  ", "SOFTWARE")});
}

/// The rest of a case's line: why software would do it, if it would; the
/// times; and what came of it - right, wrong, or for a refusal the buffer
/// untouched. `cap` is the board's bit for the call.
fn finish(t: *Test, tally: *Tally, answer: i32, cap: u32, engine_us: u64, cpu_us: ?u64, wrong: u32) void {
    tally.cases += 1;
    if (answer == err.RTGERR_OK) {
        tally.engine += 1;
        _ = Printf(t.dl, ": %lu us", .{engine_us});
    } else if (t.caps & cap == 0) {
        tally.no_engine += 1;
        _ = Printf(t.dl, ": no engine for it", .{});
    } else {
        tally.refused += 1;
        _ = Printf(t.dl, ": refused (%d)", .{answer});
    }
    if (cpu_us) |us| _ = Printf(t.dl, ", CPU %lu us", .{us});
    const outcome: [*:0]const u8 = if (wrong != 0) "WRONG" else if (answer == err.RTGERR_OK) "ok" else "untouched";
    _ = Printf(t.dl, ": %s\n", .{outcome});
    if (wrong == 0) return;
    tally.wrong += 1;
    _ = Printf(t.dl, "      %u pixels wrong\n", .{wrong});
}

/// A picture with coverage: colours from its coordinates, the coverage
/// running across and down so every level turns up.
fn paintPicture(picture: [*]u32, width: u32, height: u32) void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const alpha = (x * 3 + y * 5) & 0xFF;
            picture[y * width + x] = alpha << 24 | (x * 5 & 0xFF) << 16 | (y * 3 & 0xFF) << 8 | ((x + y) & 0xFF);
        }
    }
}

fn word(which: bool, yes: [*:0]const u8, no: [*:0]const u8) [*:0]const u8 {
    return if (which) yes else no;
}

fn starved(rb: *RtgBase, board: *rtg.RtgBoard) u32 {
    var counts: rtg.RtgBoardStats = .{};
    _ = rb.GetBoardStats(board, &counts, @sizeOf(rtg.RtgBoardStats));
    return counts.starved_frames;
}

/// The overlay DRAG moves: a disc in a square, opaque inside, colours
/// from its coordinates.
const drag_size: u32 = 128;

/// DRAG: an overlay following the pointer, the pointer moved `steps`
/// times along the diagonal and back.
fn dragTest(dl: *DosBase, rb: *RtgBase, sys: *ExecBase, board: *rtg.RtgBoard, tb: *TimerBase, info: *const rtg.RtgBoardInfo, steps: u32) i32 {
    const pitch = drag_size * 2;
    const memory = sys.AllocVec(pitch * drag_size, exec.MEMF_ANY) orelse {
        _ = Printf(dl, "No memory for the overlay\n", .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const pixels: [*]u16 = @ptrCast(@alignCast(memory));
    const middle: i32 = @intCast(drag_size / 2);
    var y: u32 = 0;
    while (y < drag_size) : (y += 1) {
        var x: u32 = 0;
        while (x < drag_size) : (x += 1) {
            const across = @as(i32, @intCast(x)) - middle;
            const down = @as(i32, @intCast(y)) - middle;
            const opaque_bit: u16 = if (across * across + down * down < middle * middle) 0x8000 else 0;
            pixels[y * drag_size + x] = opaque_bit | @as(u16, @truncate(x >> 2 << 10 | y >> 2 << 5 | (x + y) >> 3));
        }
    }
    const image = rtg.Surface{ .pixels = @ptrCast(memory), .width = drag_size, .height = drag_size, .pitch = pitch, .size_bytes = pitch * drag_size, .format = .argb1555 };
    const home_x = board.pointer_x;
    const home_y = board.pointer_y;
    const answer = rb.SetBoardOverlay(board, &image, drag_size / 2, drag_size / 2);
    if (answer != err.RTGERR_OK) {
        _ = Printf(dl, "The board takes no overlay (%d)\n", .{answer});
        return dos.RETURN_ERROR;
    }
    const span: i32 = @intCast(@min(info.width, info.height));
    const before = starved(rb, board);
    const start = now(tb);
    var step: u32 = 0;
    while (step < steps) : (step += 1) {
        // Four pixels a step, along the diagonal and back again.
        const lap: i32 = @intCast(step * 4 % @as(u32, @intCast(span * 2)));
        const along = if (lap < span) lap else span * 2 - lap;
        rb.MoveBoardPointer(board, along, along);
    }
    const took = now(tb) - start;
    const after = starved(rb, board);
    _ = rb.SetBoardOverlay(board, null, 0, 0);
    rb.MoveBoardPointer(board, home_x, home_y);
    _ = Printf(dl, "drag: %u steps of a %ux%u overlay in %lu us, %lu us a step, starved frames %u -> %u\n", .{
        steps, drag_size, drag_size, took, took / steps, before, after,
    });
    return dos.RETURN_OK;
}

fn now(tb: *TimerBase) u64 {
    var ev: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&ev);
    return ev.toTicks() * 1_000_000 / rate;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const rounds: u32 = if (argv[0] != 0) @intCast(@max(1, @as(*const i32, @ptrFromInt(argv[0])).*)) else 5;

    const rtg_lib = sys.OpenLibrary(rtg.RTGNAME, 1) orelse {
        _ = Printf(dl, "No %s\n", .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(rtg_lib);
    const rb: *RtgBase = @ptrCast(rtg_lib);
    const graphics_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, 0) orelse {
        _ = Printf(dl, "No %s\n", .{graphics.GRAPHICSNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(graphics_lib);
    const board = rb.FindBoard(sdk.graphics.DISPLAY_BOARD) orelse {
        _ = Printf(dl, "No display board\n", .{});
        return dos.RETURN_FAIL;
    };
    var info: rtg.RtgBoardInfo = .{};
    _ = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    _ = Printf(dl, "Board: %ux%u in %s; fill %s, copy %s, blend pixels %s, blend colour %s, scale %s\n", .{
        info.width,
        info.height,
        nameOf(info.format),
        word(info.caps & B.RTGBC_FILL_RECT != 0, "yes", "no"),
        word(info.caps & B.RTGBC_COPY_RECT != 0, "yes", "no"),
        word(info.caps & B.RTGBC_BLEND_PIXELS != 0, "yes", "no"),
        word(info.caps & B.RTGBC_BLEND_RECT != 0, "yes", "no"),
        word(info.caps & B.RTGBC_SCALE_PIXELS != 0, "yes", "no"),
    });

    var timer_req: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &timer_req.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&timer_req.node);
    const tb: *TimerBase = @ptrCast(timer_req.node.device.?);

    if (argv[2] != 0) {
        const steps: u32 = @intCast(@max(1, @as(*const i32, @ptrFromInt(argv[2])).*));
        return dragTest(dl, rb, sys, board, tb, &info, steps);
    }

    var t = Test{
        .sys = sys,
        .dl = dl,
        .rb = rb,
        .gb = @ptrCast(graphics_lib),
        .tb = tb,
        .board = board,
        .caps = info.caps,
        .rounds = rounds,
        .width = @max(info.width, 480),
        .height = @max(info.height, 400),
    };

    if (argv[1] != 0) {
        const load: u32 = @intCast(@max(1, @as(*const i32, @ptrFromInt(argv[1])).*));
        inline for (drawn) |format| {
            if (info.format == format) return Format(format).loadTest(&t, load);
        }
        _ = Printf(dl, "The display runs in %s, which LOAD does not fill\n", .{nameOf(info.format)});
        return dos.RETURN_FAIL;
    }

    const starved_before = starved(rb, board);
    var failures: u32 = 0;
    // What the engine did in the display's format; null when the test
    // does not draw in it.
    var display_engine: ?u32 = null;
    inline for (drawn) |format| {
        if (info.format == format) {
            const tally = Format(format).run(&t, true) orelse {
                _ = Printf(dl, "No memory for the buffers\n", .{});
                return dos.RETURN_FAIL;
            };
            failures += tally.wrong;
            display_engine = tally.engine;
        }
    }
    if (display_engine == null) _ = Printf(dl, "The display runs in %s, which the test does not draw in\n", .{nameOf(info.format)});
    for (also) |wanted| {
        if (wanted == info.format) continue;
        inline for (drawn) |format| {
            if (wanted == format) {
                if (Format(format).run(&t, false)) |tally| {
                    failures += tally.wrong;
                } else {
                    _ = Printf(dl, "In %s: no memory on the board for the buffers, left out\n", .{nameOf(format)});
                }
            }
        }
    }
    _ = Printf(dl, "Starved frames meanwhile: %u\n", .{starved(rb, board) - starved_before});

    if (failures != 0) return dos.RETURN_ERROR;
    const claimed = info.caps & (B.RTGBC_FILL_RECT | B.RTGBC_COPY_RECT | B.RTGBC_BLEND_PIXELS | B.RTGBC_BLEND_RECT | B.RTGBC_SCALE_PIXELS);
    if (display_engine) |did| {
        if (claimed != 0 and did == 0) {
            _ = Printf(dl, "The board says it has an engine, but did none of the cases in %s, the display's format\n", .{nameOf(info.format)});
            return dos.RETURN_WARN;
        }
    }
    return dos.RETURN_OK;
}

const BlendKind = enum { pixels, rect, scale };
const BlendCase = struct {
    kind: BlendKind,
    area: rtg.RtgRect,
    format: rtg.PixelFormat = .bgra32,
    alpha: u32 = 255,
    color: u32 = 0,
    /// For a scale: the part of the picture taken.
    from_width: u32 = 0,
    from_height: u32 = 0,
};

const picture_width = 400;
const picture_height = 300;

const blends = [_]BlendCase{
    .{ .kind = .pixels, .area = .{ .x = 13, .y = 7, .width = 400, .height = 300 } },
    .{ .kind = .pixels, .area = .{ .x = 13, .y = 7, .width = 400, .height = 300 }, .format = .rgba32 },
    .{ .kind = .pixels, .area = .{ .x = 64, .y = 20, .width = 160, .height = 100 }, .alpha = 128 },
    .{ .kind = .pixels, .area = .{ .x = 3, .y = 3, .width = 60, .height = 40 } },
    .{ .kind = .rect, .area = .{ .x = 13, .y = 7, .width = 400, .height = 300 }, .color = 0x80FF_8000 },
    .{ .kind = .rect, .area = .{ .x = 31, .y = 5, .width = 97, .height = 50 }, .color = 0x4000_40FF },
    .{ .kind = .scale, .area = .{ .x = 16, .y = 8, .width = 400, .height = 300 }, .from_width = 200, .from_height = 150 },
    .{ .kind = .scale, .area = .{ .x = 16, .y = 8, .width = 200, .height = 150 }, .from_width = 400, .from_height = 300 },
    .{ .kind = .scale, .area = .{ .x = 16, .y = 8, .width = 300, .height = 225 }, .from_width = 400, .from_height = 300 },
    .{ .kind = .scale, .area = .{ .x = 16, .y = 8, .width = 333, .height = 250 }, .from_width = 400, .from_height = 300 },
};

/// What graphics.library does in software for `case`.
fn cpuDoes(gb: *GraphicsBase, rp: *graphics.RastPort, case: BlendCase, picture: [*]u32) void {
    const area = graphics.Rect{ .min_x = case.area.x, .min_y = case.area.y, .max_x = case.area.x + case.area.width, .max_y = case.area.y + case.area.height };
    switch (case.kind) {
        .pixels => {
            if (case.alpha == 255) {
                gb.BlendPixelArray(rp, @ptrCast(picture), picture_width * 4, @intFromEnum(case.format), 0, 0, &area);
                return;
            }
            // The constant alpha, multiplied in as the engine does it.
            var y: u32 = 0;
            while (y < @as(u32, @intCast(case.area.height))) : (y += 1) {
                var x: u32 = 0;
                while (x < @as(u32, @intCast(case.area.width))) : (x += 1) {
                    const pen = picture[y * picture_width + x];
                    const coverage = (pen >> 24) * case.alpha >> 8;
                    const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = coverage << 24 | (pen & 0xFF_FFFF) }, .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_BLEND }, .{} };
                    gb.SetRPAttrs(rp, &tags);
                    const at_x = case.area.x + @as(i32, @intCast(x));
                    const at_y = case.area.y + @as(i32, @intCast(y));
                    gb.RectFill(rp, &.{ .min_x = at_x, .min_y = at_y, .max_x = at_x + 1, .max_y = at_y + 1 });
                }
            }
            const plain_tags = [_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} };
            gb.SetRPAttrs(rp, &plain_tags);
        },
        .rect => {
            const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = case.color }, .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_BLEND }, .{} };
            gb.SetRPAttrs(rp, &tags);
            gb.RectFill(rp, &area);
            const plain_tags = [_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} };
            gb.SetRPAttrs(rp, &plain_tags);
        },
        .scale => {
            const smooth = [_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 1 }, .{} };
            gb.SetRPAttrs(rp, &smooth);
            const from = graphics.Rect{ .min_x = 0, .min_y = 0, .max_x = @intCast(case.from_width), .max_y = @intCast(case.from_height) };
            gb.ScalePixelArray(rp, @ptrCast(picture), picture_width * 4, @intFromEnum(case.format), &from, &area);
            const sharp = [_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 0 }, .{} };
            gb.SetRPAttrs(rp, &sharp);
        },
    }
}
