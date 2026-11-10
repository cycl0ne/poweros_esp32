// SPDX-License-Identifier: MIT
//! DTTime: how long a datatype takes to make a picture, and to draw each
//! frame of an animation. Built against the SDK only.
//!
//!   DTTime FILE/M/A,ROUNDS/K/N,WIDTH/K/N,HEIGHT/K/N
//!
//! Each file is made into a datatype object ROUNDS times (3 if not given),
//! whatever kind it is, and the fastest and the mean are printed with the
//! picture's size and what the object keeps: the memory free before the
//! last one was made, less the memory free after. Making it is reading
//! the file and, for a picture drawn rather than decoded - an SVG file -
//! drawing it, so a file on a share or a slow disk is timed with its
//! reading: copy it to RAM: to time only the class.
//!
//! WIDTH and HEIGHT are the size wanted (`PDTA_WantedWidth`,
//! `PDTA_WantedHeight`): a class that draws its picture draws it to fit
//! inside them, the others pass them by. A picture's pens are hashed as
//! `tools/svgcompare --hash` hashes its drawing (FNV-1a, 64 bits, over
//! the pens as little-endian words), so what the machine made can be held
//! against what the host drew to the bit.
//!
//! An animation then has every frame drawn ROUNDS times over, by its
//! class, into pens of this program's: `ADTM_LOADFRAME` sent on this
//! process, as animation.datatype's loader sends it. The object is
//! never laid out or played, so no loader is running beside it. Printed
//! are the mean frame, the fastest and the slowest, and how many frames
//! a second the mean would allow. The pens are cleared before each frame,
//! as the loader clears them, outside the time.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const pic = datatypes.pictureclass;
const adt = datatypes.animationclass;
const timer = sdk.devices.timer;
const graphics = sdk.graphics;
const TagItem = sdk.utility.TagItem;
const Object = intuition.classusr.Object;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const TimerBase = timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "DTTime";
const VERSION_STRING = "\x00$VER: DTTime 1.1 (10.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE/M/A,ROUNDS/K/N,WIDTH/K/N,HEIGHT/K/N";
const arg_file = 0;
const arg_rounds = 1;
const arg_width = 2;
const arg_height = 3;

const MSG_NOLIBRARY = "%s: no %s\n";
const MSG_NOTMADE = "%s: not made - ";
const MSG_MADE = "%s: %s %lu x %lu, made in %lu us (mean %lu), keeps %lu KB\n";
const MSG_HASH = "  pens %08lx%08lx\n";
const MSG_FRAMES = "  %lu frames x %lu: %lu us a frame (fastest %lu, slowest %lu), %lu.%lu a second\n";

/// Microseconds of timer.device's E-clock.
fn now(tb: *TimerBase) u64 {
    var ev: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&ev);
    return ev.toTicks() * 1_000_000 / rate;
}

/// FNV-1a, 64 bits, over the pens as little-endian words.
fn pensHash(pixels: usize, bytes_per_row: usize, width: u32, height: u32) u64 {
    var h: u64 = 0xcbf29ce484222325;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row: [*]const graphics.Pen = @ptrFromInt(pixels + y * bytes_per_row);
        for (row[0..width]) |pen| {
            var shift: u5 = 0;
            while (true) : (shift += 8) {
                h ^= @as(u8, @truncate(pen >> shift));
                h *%= 0x100000001b3;
                if (shift == 24) break;
            }
        }
    }
    return h;
}

fn attribute(dt: *DataTypesBase, object: *Object, tag: u32) usize {
    var value: usize = 0;
    _ = dt.GetDTAttrsA(object, &[_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} });
    return value;
}

/// Every frame drawn `rounds` times over into pens of the animation's
/// size, timed one by one.
fn frames(sys: *ExecBase, dl: *DosBase, ib: *IntuitionBase, tb: *TimerBase, object: *Object, width: u32, height: u32, count: u32, rounds: u32) void {
    const bytes_per_row = width * @sizeOf(graphics.Pen);
    const memory = sys.AllocVec(height * bytes_per_row, exec.MEMF_ANY) orelse {
        _ = Printf(dl, "  no memory for a frame's pens\n", .{});
        return;
    };
    defer sys.FreeVec(memory);
    const pens: [*]graphics.Pen = @ptrCast(@alignCast(memory));
    var total: u64 = 0;
    var fastest: u64 = ~@as(u64, 0);
    var slowest: u64 = 0;
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        var frame: u32 = 0;
        while (frame < count) : (frame += 1) {
            @memset(pens[0 .. width * height], 0);
            var msg = adt.AdtFrame{ .frame = frame, .pens = pens, .bytes_per_row = bytes_per_row };
            const start = now(tb);
            _ = ib.SendMessage(object, @ptrCast(&msg));
            const took = now(tb) - start;
            total += took;
            fastest = @min(fastest, took);
            slowest = @max(slowest, took);
        }
    }
    const mean = total / (@as(u64, count) * rounds);
    // Frames a second, to a tenth.
    const tenths = if (mean == 0) 0 else 10_000_000 / mean;
    _ = Printf(dl, MSG_FRAMES, .{ @as(u64, count), @as(u64, rounds), mean, fastest, slowest, tenths / 10, tenths % 10 });
}

fn time(sys: *ExecBase, dl: *DosBase, ib: *IntuitionBase, dt: *DataTypesBase, tb: *TimerBase, name: [*:0]const u8, rounds: u32, tags: [*]const TagItem) void {
    var best: u64 = ~@as(u64, 0);
    var total: u64 = 0;
    var kept: usize = 0;
    var object: ?*Object = null;
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        if (object) |previous| dt.DisposeDTObject(previous);
        const before = sys.AvailMem(exec.MEMF_ANY);
        const start = now(tb);
        object = dt.NewDTObjectA(name, tags) orelse {
            _ = Printf(dl, MSG_NOTMADE, .{name});
            _ = dl.PrintFault(dl.IoErr(), null);
            return;
        };
        const took = now(tb) - start;
        kept = before -| sys.AvailMem(exec.MEMF_ANY);
        best = @min(best, took);
        total += took;
    }
    const made = object.?;
    defer dt.DisposeDTObject(made);
    const count: u32 = @truncate(attribute(dt, made, adt.ADTA_Frames));
    var width: u32 = 0;
    var height: u32 = 0;
    if (count != 0) {
        width = @truncate(attribute(dt, made, adt.ADTA_Width));
        height = @truncate(attribute(dt, made, adt.ADTA_Height));
    } else {
        const header = attribute(dt, made, pic.PDTA_BitMapHeader);
        if (header != 0) {
            const shape: *const pic.BitMapHeader = @ptrFromInt(header);
            width = shape.width;
            height = shape.height;
        }
    }
    _ = Printf(dl, MSG_MADE, .{
        name,                  if (count != 0) "animation" else "picture",
        @as(u64, width),       @as(u64, height),
        best,                  total / rounds,
        @as(u64, kept / 1024),
    });
    const pixels = attribute(dt, made, pic.PDTA_Pixels);
    if (count == 0 and pixels != 0) {
        const hash = pensHash(pixels, attribute(dt, made, pic.PDTA_BytesPerRow), width, height);
        _ = Printf(dl, MSG_HASH, .{ hash >> 32, hash & 0xFFFF_FFFF });
    }
    if (count != 0 and width != 0 and height != 0) frames(sys, dl, ib, tb, made, width, height, count, rounds);
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const rounds: u32 = if (argv[arg_rounds] != 0) @intCast(@max(1, @as(*const i32, @ptrFromInt(argv[arg_rounds])).*)) else 3;

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, intuition.INTUITIONNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);
    const dt_lib = sys.OpenLibrary(datatypes.DATATYPESNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, datatypes.DATATYPESNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(dt_lib);
    const dt: *DataTypesBase = @ptrCast(dt_lib);

    var timer_req: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &timer_req.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&timer_req.node);
    const tb: *TimerBase = @ptrCast(timer_req.node.device.?);

    const wanted = struct {
        fn of(arg: usize) usize {
            return if (arg != 0) @intCast(@max(0, @as(*const i32, @ptrFromInt(arg)).*)) else 0;
        }
    }.of;
    const tags = [_]TagItem{
        .{ .tag = pic.PDTA_WantedWidth, .data = wanted(argv[arg_width]) },
        .{ .tag = pic.PDTA_WantedHeight, .data = wanted(argv[arg_height]) },
        .{},
    };
    const names: [*]const usize = @ptrFromInt(argv[arg_file]);
    var i: usize = 0;
    while (names[i] != 0) : (i += 1) {
        if (sys.SetSignal(0, exec.SIGBREAKF_CTRL_C) & exec.SIGBREAKF_CTRL_C != 0) break;
        time(sys, dl, ib, dt, tb, @ptrFromInt(names[i]), rounds, &tags);
    }
    return dos.RETURN_OK;
}
