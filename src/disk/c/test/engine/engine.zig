// SPDX-License-Identifier: MIT
//! Engine: the display board's engine - FillRect, CopyRect, BlendPixels,
//! BlendRect and ScalePixels - checked against what the CPU does, and
//! timed beside it. Built against the SDK only.
//!
//!   Engine ROUNDS/K/N,LOAD/K/N
//!
//! Two buffers the size of a screen are taken from the display board and
//! filled with a pattern of their coordinates. Each case is then done by
//! the board and checked: every pixel inside the rectangle has what it
//! should, every pixel outside it what it had. The cases are rectangles
//! that start and end anywhere in a cache line, a whole buffer, one too
//! small for the engine, copies between the two buffers and within one,
//! and a copy whose two rectangles overlap - which the board may refuse,
//! and the caller then does in software; and a copy out of plain memory,
//! described for the engine. Each case is timed over ROUNDS runs (5 if
//! not given), and the same work done by the CPU beside it.
//!
//! The blends and the scale are checked against graphics.library doing
//! the same in software, on plain memory painted alike: a picture with
//! coverage laid over the buffer, at full and at half strength, and in
//! the order the engine refuses (`rgba32`); a translucent colour; a
//! picture scaled smooth by ratios the engine reaches, and one it does
//! not. Every pixel outside the rectangle has to be
//! what it was. Inside, a blend may differ by one step of RGB565 where
//! the engine rounds its own way; a scale is mixed by the engine's own
//! sampling, so how far it lies from the CPU's is printed, and only a
//! large difference is a fault. The CPU's time is graphics.library's.
//! At the end, the frames the display starved of while all that ran.
//!
//! LOAD n instead does n fills of a whole buffer by the board, then n by
//! the CPU, and prints the display's starved frames before and after
//! each: whether the panel's stream holds up while the memory it streams
//! out of is that busy.

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

pub const COMMAND_NAME = "Engine";
const VERSION_STRING = "\x00$VER: Engine 1.1 (10.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "ROUNDS/K/N,LOAD/K/N";

/// The colour the fills use.
const fill_color: u16 = 0xF81F;

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

/// The pattern a buffer starts with.
fn patternAt(x: u32, y: u32, seed: u32) u16 {
    return @truncate(x *% 7 +% y *% 131 +% seed);
}

fn pixelAt(bm: *const rtg.RtgBitMap, x: u32, y: u32) *u16 {
    const row: [*]u16 = @ptrFromInt(@intFromPtr(bm.pixels.?) + @as(usize, y) * bm.pitch);
    return &row[x];
}

fn paint(bm: *rtg.RtgBitMap, seed: u32) void {
    var y: u32 = 0;
    while (y < bm.height) : (y += 1) {
        var x: u32 = 0;
        while (x < bm.width) : (x += 1) pixelAt(bm, x, y).* = patternAt(x, y, seed);
    }
}

fn inside(x: u32, y: u32, left: i32, top: i32, width: i32, height: i32) bool {
    const sx: i32 = @intCast(x);
    const sy: i32 = @intCast(y);
    return sx >= left and sx < left + width and sy >= top and sy < top + height;
}

fn checkFill(bm: *rtg.RtgBitMap, case: FillCase, seed: u32) u32 {
    var wrong: u32 = 0;
    var y: u32 = 0;
    while (y < bm.height) : (y += 1) {
        var x: u32 = 0;
        while (x < bm.width) : (x += 1) {
            const want = if (inside(x, y, case.x, case.y, case.width, case.height)) fill_color else patternAt(x, y, seed);
            if (pixelAt(bm, x, y).* != want) wrong += 1;
        }
    }
    return wrong;
}

fn checkCopy(dest: *rtg.RtgBitMap, case: CopyCase, src_seed: u32, dest_seed: u32) u32 {
    var wrong: u32 = 0;
    var y: u32 = 0;
    while (y < dest.height) : (y += 1) {
        var x: u32 = 0;
        while (x < dest.width) : (x += 1) {
            const want = if (inside(x, y, case.dx, case.dy, case.width, case.height))
                patternAt(@intCast(@as(i32, @intCast(x)) - case.dx + case.sx), @intCast(@as(i32, @intCast(y)) - case.dy + case.sy), src_seed)
            else
                patternAt(x, y, dest_seed);
            if (pixelAt(dest, x, y).* != want) wrong += 1;
        }
    }
    return wrong;
}

/// A blend or a scale: what the board did against what graphics.library
/// did on plain memory, both from the same pattern. `outside` counts the
/// pixels outside the rectangle that changed, `off` those inside more
/// than one RGB565 step from the CPU's in a channel, `worst` the largest
/// difference of a channel in eight-bit steps, `sum` all differences.
const Compared = struct { outside: u32 = 0, off: u32 = 0, worst: u32 = 0, sum: u64 = 0, count: u32 = 0 };

fn widen(pixel: u16) [3]u32 {
    const red: u32 = pixel >> 11 & 0x1F;
    const green: u32 = pixel >> 5 & 0x3F;
    const blue: u32 = pixel & 0x1F;
    return .{ red << 3 | red >> 2, green << 2 | green >> 4, blue << 3 | blue >> 2 };
}

/// The most RGB565 steps two pixels are apart in any one channel.
fn stepsApart(got: u16, want: u16) u32 {
    var most: u32 = 0;
    for ([3]u4{ 11, 5, 0 }, [3]u16{ 0x1F, 0x3F, 0x1F }) |shift, mask| {
        const one: i32 = got >> shift & mask;
        const two: i32 = want >> shift & mask;
        most = @max(most, @abs(one - two));
    }
    return most;
}

fn compare(board_bm: *rtg.RtgBitMap, cpu: *const rtg.Surface, area: rtg.RtgRect, seed: u32) Compared {
    var result = Compared{};
    var y: u32 = 0;
    while (y < board_bm.height) : (y += 1) {
        const cpu_row: [*]const u16 = @ptrFromInt(@intFromPtr(cpu.pixels.?) + @as(usize, y) * cpu.pitch);
        var x: u32 = 0;
        while (x < board_bm.width) : (x += 1) {
            const got = pixelAt(board_bm, x, y).*;
            if (!inside(x, y, area.x, area.y, area.width, area.height)) {
                if (got != patternAt(x, y, seed)) result.outside += 1;
                continue;
            }
            const want = cpu_row[x];
            const a = widen(got);
            const b = widen(want);
            for (a, b) |one, two| {
                const difference = if (one > two) one - two else two - one;
                result.worst = @max(result.worst, difference);
                result.sum += difference;
            }
            if (stepsApart(got, want) > 1) result.off += 1;
            result.count += 3;
        }
    }
    return result;
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

/// Plain memory painted as `paint` paints a buffer.
fn paintSurface(surface: *const rtg.Surface, seed: u32) void {
    var y: u32 = 0;
    while (y < surface.height) : (y += 1) {
        const row: [*]u16 = @ptrFromInt(@intFromPtr(surface.pixels.?) + @as(usize, y) * surface.pitch);
        var x: u32 = 0;
        while (x < surface.width) : (x += 1) row[x] = patternAt(x, y, seed);
    }
}

fn word(which: bool, yes: [*:0]const u8, no: [*:0]const u8) [*:0]const u8 {
    return if (which) yes else no;
}

/// What a case came to: done right, done wrong, or left to software.
fn verdict(answer: i32, wrong: u32) [*:0]const u8 {
    if (answer != err.RTGERR_OK) return "software's";
    return if (wrong == 0) "ok" else "WRONG";
}

fn starved(rb: *RtgBase, board: *rtg.RtgBoard) u32 {
    var counts: rtg.RtgBoardStats = .{};
    _ = rb.GetBoardStats(board, &counts, @sizeOf(rtg.RtgBoardStats));
    return counts.starved_frames;
}

/// LOAD: `rounds` whole-buffer fills by the board, then by the CPU, with
/// the display's starved frames before and after each run.
fn loadTest(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard, tb: *TimerBase, bm: *rtg.RtgBitMap, rounds: u32) i32 {
    const whole = rtg.RtgRect{ .x = 0, .y = 0, .width = @intCast(bm.width), .height = @intCast(bm.height) };
    var before = starved(rb, board);
    var start = now(tb);
    var round: u32 = 0;
    var refused: u32 = 0;
    while (round < rounds) : (round += 1) {
        if (rb.FillRect(bm, &whole, @truncate(round)) != err.RTGERR_OK) refused += 1;
    }
    var took = now(tb) - start;
    _ = Printf(dl, "board: %u fills of %ux%u in %lu us (%u refused), starved frames %u -> %u\n", .{
        rounds, bm.width, bm.height, took, refused, before, starved(rb, board),
    });
    before = starved(rb, board);
    start = now(tb);
    round = 0;
    while (round < rounds) : (round += 1) {
        var y: u32 = 0;
        while (y < bm.height) : (y += 1) {
            const row: [*]u16 = @ptrFromInt(@intFromPtr(pixelAt(bm, 0, y)));
            @memset(row[0..bm.width], @truncate(round));
        }
    }
    took = now(tb) - start;
    _ = Printf(dl, "CPU: %u fills of %ux%u in %lu us, starved frames %u -> %u\n", .{
        rounds, bm.width, bm.height, took, before, starved(rb, board),
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
    var argv: [2]usize = @splat(0);
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
    const board = rb.FindBoard(sdk.graphics.DISPLAY_BOARD) orelse {
        _ = Printf(dl, "No display board\n", .{});
        return dos.RETURN_FAIL;
    };
    var info: rtg.RtgBoardInfo = .{};
    _ = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    _ = Printf(dl, "Board: fill %s, copy %s\n", .{
        word(info.caps & rtg.boards.RTGBC_FILL_RECT != 0, "yes", "no"),
        word(info.caps & rtg.boards.RTGBC_COPY_RECT != 0, "yes", "no"),
    });

    var timer_req: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &timer_req.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&timer_req.node);
    const tb: *TimerBase = @ptrCast(timer_req.node.device.?);

    const width: u32 = @max(info.width, 480);
    const height: u32 = @max(info.height, 400);
    const first = rb.AllocBitMap(board, width, height, @intFromEnum(rtg.PixelFormat.rgb565), 0) orelse {
        _ = Printf(dl, "No memory for the buffers\n", .{});
        return dos.RETURN_FAIL;
    };
    defer rb.FreeBitMap(first);
    const second = rb.AllocBitMap(board, width, height, @intFromEnum(rtg.PixelFormat.rgb565), 0) orelse {
        _ = Printf(dl, "No memory for the buffers\n", .{});
        return dos.RETURN_FAIL;
    };
    defer rb.FreeBitMap(second);
    _ = Printf(dl, "Buffers: %u x %u, pitch %u, at 0x%08lx and 0x%08lx\n", .{
        width, height, first.pitch, @as(u64, @intFromPtr(first.pixels.?)), @as(u64, @intFromPtr(second.pixels.?)),
    });

    if (argv[1] != 0) {
        const load: u32 = @intCast(@max(1, @as(*const i32, @ptrFromInt(argv[1])).*));
        return loadTest(dl, rb, board, tb, second, load);
    }

    const starved_before = starved(rb, board);
    var failures: u32 = 0;
    for (fills) |case| {
        var engine_us: u64 = 0;
        var answer: i32 = err.RTGERR_OK;
        var round: u32 = 0;
        while (round < rounds) : (round += 1) {
            paint(first, 1);
            const start = now(tb);
            answer = rb.FillRect(first, &.{ .x = case.x, .y = case.y, .width = case.width, .height = case.height }, fill_color);
            engine_us += now(tb) - start;
        }
        var cpu_us: u64 = 0;
        round = 0;
        while (round < rounds) : (round += 1) {
            paint(second, 1);
            const start = now(tb);
            var y: i32 = case.y;
            while (y < case.y + case.height) : (y += 1) {
                const row: [*]u16 = @ptrFromInt(@intFromPtr(pixelAt(second, @intCast(case.x), @intCast(y))));
                @memset(row[0..@intCast(case.width)], fill_color);
            }
            cpu_us += now(tb) - start;
        }
        const wrong = if (answer == err.RTGERR_OK) checkFill(first, case, 1) else 0;
        if (wrong != 0) failures += 1;
        _ = Printf(dl, "fill %ux%u at %d,%d: board %s %lu us, CPU %lu us: %s\n", .{
            @as(u32, @intCast(case.width)),                            @as(u32, @intCast(case.height)),
            case.x,                                                    case.y,
            word(answer == err.RTGERR_OK, "did it in", "refused it,"), engine_us / rounds,
            cpu_us / rounds,                                           verdict(answer, wrong),
        });
        if (wrong != 0) _ = Printf(dl, "  %u pixels wrong\n", .{wrong});
    }

    for (copies) |case| {
        const src = first;
        const dest = if (case.same) first else second;
        const what = rtg.RtgCopy{ .src_x = case.sx, .src_y = case.sy, .width = case.width, .height = case.height, .dest_x = case.dx, .dest_y = case.dy };
        var engine_us: u64 = 0;
        var answer: i32 = err.RTGERR_OK;
        var round: u32 = 0;
        while (round < rounds) : (round += 1) {
            paint(first, 1);
            if (!case.same) paint(second, 2);
            const start = now(tb);
            answer = rb.CopyRect(src, dest, &what);
            engine_us += now(tb) - start;
        }
        const wrong = if (answer == err.RTGERR_OK) checkCopy(dest, case, 1, if (case.same) 1 else 2) else 0;
        if (wrong != 0) failures += 1;
        _ = Printf(dl, "copy %ux%u %d,%d -> %d,%d%s: board %s %lu us: %s\n", .{
            @as(u32, @intCast(case.width)),        @as(u32, @intCast(case.height)),
            case.sx,                               case.sy,
            case.dx,                               case.dy,
            word(case.same, " in one buffer", ""), word(answer == err.RTGERR_OK, "did it in", "refused it,"),
            engine_us / rounds,                    verdict(answer, wrong),
        });
        if (wrong != 0) _ = Printf(dl, "  %u pixels wrong\n", .{wrong});
    }

    failures += memoryCopy(dl, rb, sys, tb, first, rounds);
    failures += blendCases(dl, rb, sys, tb, first, rounds);
    _ = Printf(dl, "Starved frames meanwhile: %u\n", .{starved(rb, board) - starved_before});

    if (failures != 0) return dos.RETURN_ERROR;
    return dos.RETURN_OK;
}

/// A copy out of plain memory, described for the engine.
fn memoryCopy(dl: *DosBase, rb: *RtgBase, sys: *ExecBase, tb: *TimerBase, dest: *rtg.RtgBitMap, rounds: u32) u32 {
    const bytes = dest.pitch * dest.height;
    const memory = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return 0;
    defer sys.FreeVec(memory);
    var plain = rtg.RtgBitMap{ .pixels = @ptrCast(memory), .width = dest.width, .height = dest.height, .pitch = dest.pitch, .format = .rgb565 };
    paint(&plain, 2);
    const case = CopyCase{ .sx = 5, .sy = 3, .width = 400, .height = 300, .dx = 17, .dy = 11, .same = false };
    const what = rtg.RtgCopy{ .src_x = case.sx, .src_y = case.sy, .width = case.width, .height = case.height, .dest_x = case.dx, .dest_y = case.dy };
    var engine_us: u64 = 0;
    var answer: i32 = err.RTGERR_OK;
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        paint(dest, 1);
        const start = now(tb);
        answer = rb.CopyRect(&plain, dest, &what);
        engine_us += now(tb) - start;
    }
    const wrong = if (answer == err.RTGERR_OK) checkCopy(dest, case, 2, 1) else 0;
    _ = Printf(dl, "copy 400x300 from memory at 0x%08lx: board %s %lu us: %s\n", .{
        @as(u64, @intFromPtr(memory)), word(answer == err.RTGERR_OK, "did it in", "refused it,"), engine_us / rounds, verdict(answer, wrong),
    });
    if (wrong != 0) _ = Printf(dl, "  %u pixels wrong\n", .{wrong});
    return @intFromBool(wrong != 0);
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

/// Each blend and scale by the board on `first`, and by graphics.library
/// in software on plain memory painted alike.
fn blendCases(dl: *DosBase, rb: *RtgBase, sys: *ExecBase, tb: *TimerBase, first: *rtg.RtgBitMap, rounds: u32) u32 {
    const graphics_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, 0) orelse return 0;
    defer sys.CloseLibrary(graphics_lib);
    const gb: *GraphicsBase = @ptrCast(graphics_lib);
    const bytes = first.pitch * first.height;
    const memory = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return 0;
    defer sys.FreeVec(memory);
    const plain = rtg.Surface{ .pixels = @ptrCast(memory), .width = first.width, .height = first.height, .pitch = first.pitch, .size_bytes = bytes, .format = .rgb565 };
    const picture_memory = sys.AllocVec(picture_width * picture_height * 4, exec.MEMF_ANY) orelse return 0;
    defer sys.FreeVec(picture_memory);
    const picture: [*]u32 = @ptrCast(@alignCast(picture_memory));
    paintPicture(picture, picture_width, picture_height);

    const cpu_tags = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&plain) }, .{} };
    const cpu_rp = gb.CreateRastPortTagList(&cpu_tags) orelse return 0;
    defer gb.FreeRastPort(cpu_rp);

    var failures: u32 = 0;
    for (blends) |case| {
        const pixels = rtg.RtgPixels{ .pixels = @ptrCast(picture), .pitch = picture_width * 4, .format = case.format };
        var engine_us: u64 = 0;
        var answer: i32 = err.RTGERR_OK;
        var round: u32 = 0;
        while (round < rounds) : (round += 1) {
            paint(first, 1);
            const start = now(tb);
            answer = switch (case.kind) {
                .pixels => rb.BlendPixels(first, &case.area, &pixels, case.alpha),
                .rect => rb.BlendRect(first, &case.area, case.color),
                .scale => rb.ScalePixels(first, &case.area, &pixels, case.from_width, case.from_height),
            };
            engine_us += now(tb) - start;
        }
        var cpu_us: u64 = 0;
        round = 0;
        while (round < rounds) : (round += 1) {
            paintSurface(&plain, 1);
            const start = now(tb);
            cpuDoes(gb, cpu_rp, case, picture);
            cpu_us += now(tb) - start;
        }
        const result = if (answer == err.RTGERR_OK) compare(first, &plain, case.area, 1) else Compared{};
        // A scale is the engine's own sampling: far off only when broken.
        const mean = if (result.count == 0) 0 else result.sum / result.count;
        const wrong = result.outside != 0 or (if (case.kind == .scale) mean > 12 else result.off != 0);
        if (wrong) failures += 1;
        const name: [*:0]const u8 = switch (case.kind) {
            .pixels => if (case.format == .rgba32) "blend rgba32" else "blend bgra32",
            .rect => "blend colour",
            .scale => "scale",
        };
        _ = Printf(dl, "%s %ux%u at %d,%d: board %s %lu us, CPU %lu us: %s\n", .{
            name,                                                                        @as(u32, @intCast(case.area.width)),
            @as(u32, @intCast(case.area.height)),                                        case.area.x,
            case.area.y,                                                                 word(answer == err.RTGERR_OK, "did it in", "refused it,"),
            engine_us / rounds,                                                          cpu_us / rounds,
            if (answer != err.RTGERR_OK) "software's" else if (wrong) "WRONG" else "ok",
        });
        if (answer == err.RTGERR_OK) _ = Printf(dl, "  outside changed %u, off by more than a step %u, worst %u, mean %lu/100\n", .{
            result.outside, result.off, result.worst, if (result.count == 0) 0 else result.sum * 100 / result.count,
        });
    }
    return failures;
}

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
