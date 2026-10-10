// SPDX-License-Identifier: MIT
//! Engine: the display board's engine - FillRect and CopyRect - checked
//! pixel for pixel against what the CPU does, and timed beside it. Built
//! against the SDK only.
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
//! and the caller then does in software. Each case is timed over ROUNDS
//! runs (5 if not given), and the same work done by the CPU beside it.
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
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const TimerBase = timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Engine";
const VERSION_STRING = "\x00$VER: Engine 1.0 (10.10.2026)\r\n";
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

    if (failures != 0) return dos.RETURN_ERROR;
    return dos.RETURN_OK;
}
