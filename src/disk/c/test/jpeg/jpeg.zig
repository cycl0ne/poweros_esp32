// SPDX-License-Identifier: MIT
//! Jpeg: a JPEG file decoded by the machine's codec and by software, the
//! two timed and compared. Built against the SDK only.
//!
//!   Jpeg FILE/A,ROUNDS/K/N
//!
//! The file is read into memory and shown to jpeg.resource, which says
//! what it is and whether its codec takes it; a codec that does decodes
//! it ROUNDS times (3 if not given), and the time of one decode is
//! printed. Then jpeg.datatype makes the picture twice, once kept to its
//! software decoder and once allowed the codec (JDTA_Decoder), each timed
//! over the same rounds and asked which decoder did read it. The two
//! pictures are compared pixel by pixel: the largest difference in any
//! channel, the mean, and how many pixels lie further apart than
//! `far_apart` - the two decoders round their arithmetic and bring the
//! colour's halved samples to full size each its own way, so they are
//! close, not equal.
//!
//! On a machine without a codec the resource is missing and only the
//! software picture is made.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const pic = datatypes.pictureclass;
const jpegclass = datatypes.jpegclass;
const jpeg = sdk.resources.jpeg;
const timer = sdk.devices.timer;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const TimerBase = timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Jpeg";
const VERSION_STRING = "\x00$VER: Jpeg 1.0 (10.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE/A,ROUNDS/K/N";
const arg_file = 0;
const arg_rounds = 1;

/// A difference in a channel larger than this is counted as far apart.
const far_apart = 24;

fn now(tb: *TimerBase) u64 {
    var ev: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&ev);
    return ev.toTicks() * 1_000_000 / rate;
}

fn samplingName(sampling: u32) [*:0]const u8 {
    return switch (sampling) {
        jpeg.JPEGSAMP_GREY => "grey",
        jpeg.JPEGSAMP_444 => "4:4:4",
        jpeg.JPEGSAMP_422 => "4:2:2",
        jpeg.JPEGSAMP_420 => "4:2:0",
        else => "?",
    };
}

fn answerName(answer: u32) [*:0]const u8 {
    return switch (answer) {
        jpeg.JPEGERR_OK => "ok",
        jpeg.JPEGERR_NOT_JPEG => "not a JPEG",
        jpeg.JPEGERR_CORRUPT => "corrupt",
        jpeg.JPEGERR_UNSUPPORTED => "not one the codec takes",
        jpeg.JPEGERR_NO_MEMORY => "no memory",
        jpeg.JPEGERR_FAILED => "the codec failed on it",
        jpeg.JPEGERR_NO_ENGINE => "no codec",
        else => "?",
    };
}

/// The codec on its own: what the file is, and one decode's time.
fn codecAlone(dl: *DosBase, jb: *jpeg.JpegBase, tb: *TimerBase, file: []const u8, rounds: u32) void {
    const length: u32 = @intCast(file.len);
    var info: jpeg.JPEGInfo = .{};
    const examined = jb.ExamineJPEG(file.ptr, length, &info);
    if (examined != jpeg.JPEGERR_OK) {
        _ = Printf(dl, "Codec: %s\n", .{answerName(examined)});
        return;
    }
    _ = Printf(dl, "File: %u x %u, %u components, %s, decoded %u bytes a row, %u in all\n", .{
        info.width, info.height, info.components, samplingName(info.sampling), info.pitch, info.bytes,
    });
    var best: u64 = ~@as(u64, 0);
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        var picture: jpeg.JPEGPicture = .{};
        const start = now(tb);
        const answer = jb.DecodeJPEG(file.ptr, length, &picture);
        const took = now(tb) - start;
        jb.FreeJPEGPicture(&picture);
        if (answer != jpeg.JPEGERR_OK) {
            _ = Printf(dl, "Codec: %s\n", .{answerName(answer)});
            return;
        }
        best = @min(best, took);
    }
    _ = Printf(dl, "Codec alone: %ld us a decode\n", .{best});
}

/// A picture made by jpeg.datatype with the decoder `want` allows.
const Made = struct {
    object: *sdk.intuition.classusr.Object,
    decoder: u32,
    width: u32,
    height: u32,
    pixels: [*]const u32,
    pitch: u32,
    best: u64,
};

fn make(dt: *DataTypesBase, tb: *TimerBase, name: [*:0]const u8, want: u32, rounds: u32) ?Made {
    const tags = [_]TagItem{
        .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_PICTURE },
        .{ .tag = jpegclass.JDTA_Decoder, .data = want },
        .{},
    };
    var best: u64 = ~@as(u64, 0);
    var round: u32 = 1;
    while (round < rounds) : (round += 1) {
        const start = now(tb);
        const object = dt.NewDTObjectA(name, &tags) orelse return null;
        best = @min(best, now(tb) - start);
        dt.DisposeDTObject(object);
    }
    const start = now(tb);
    const object = dt.NewDTObjectA(name, &tags) orelse return null;
    best = @min(best, now(tb) - start);
    var decoder: usize = 0;
    var header: usize = 0;
    var pixels: usize = 0;
    var pitch: usize = 0;
    _ = dt.GetDTAttrsA(object, &[_]TagItem{
        .{ .tag = jpegclass.JDTA_Decoder, .data = @intFromPtr(&decoder) },
        .{ .tag = pic.PDTA_BitMapHeader, .data = @intFromPtr(&header) },
        .{ .tag = pic.PDTA_Pixels, .data = @intFromPtr(&pixels) },
        .{ .tag = pic.PDTA_BytesPerRow, .data = @intFromPtr(&pitch) },
        .{},
    });
    if (header == 0 or pixels == 0) {
        dt.DisposeDTObject(object);
        return null;
    }
    const shape: *const pic.BitMapHeader = @ptrFromInt(header);
    return .{
        .object = object,
        .decoder = @intCast(decoder),
        .width = shape.width,
        .height = shape.height,
        .pixels = @ptrFromInt(pixels),
        .pitch = @intCast(pitch),
        .best = best,
    };
}

fn decoderName(decoder: u32) [*:0]const u8 {
    return if (decoder == jpegclass.JDEC_CODEC) "the codec" else "software";
}

/// The two pictures side by side: the largest difference in a channel,
/// the mean in hundredths, the pixels further apart than `far_apart`.
fn compare(dl: *DosBase, soft: *const Made, codec: *const Made) void {
    if (soft.width != codec.width or soft.height != codec.height) {
        _ = Printf(dl, "Sizes differ: %u x %u and %u x %u\n", .{ soft.width, soft.height, codec.width, codec.height });
        return;
    }
    var worst: u32 = 0;
    var sum: u64 = 0;
    var far: u32 = 0;
    var y: u32 = 0;
    while (y < soft.height) : (y += 1) {
        const a: [*]const u32 = @ptrFromInt(@intFromPtr(soft.pixels) + @as(usize, y) * soft.pitch);
        const b: [*]const u32 = @ptrFromInt(@intFromPtr(codec.pixels) + @as(usize, y) * codec.pitch);
        var x: u32 = 0;
        while (x < soft.width) : (x += 1) {
            var apart = false;
            var shift: u5 = 0;
            while (shift < 24) : (shift += 8) {
                const one: i32 = @intCast(a[x] >> shift & 0xFF);
                const two: i32 = @intCast(b[x] >> shift & 0xFF);
                const difference: u32 = @abs(one - two);
                worst = @max(worst, difference);
                sum += difference;
                if (difference > far_apart) apart = true;
            }
            if (apart) far += 1;
        }
    }
    const channels: u64 = @as(u64, soft.width) * soft.height * 3;
    _ = Printf(dl, "Compared: worst %u, mean %ld/100, %u of %u pixels more than %u apart\n", .{
        worst, sum * 100 / channels, far, soft.width * soft.height, @as(u32, far_apart),
    });
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
    const name: [*:0]const u8 = @ptrFromInt(argv[arg_file]);
    const rounds: u32 = if (argv[arg_rounds] != 0) @intCast(@max(1, @as(*const i32, @ptrFromInt(argv[arg_rounds])).*)) else 3;

    var timer_req: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &timer_req.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&timer_req.node);
    const tb: *TimerBase = @ptrCast(timer_req.node.device.?);

    const lock = dl.Lock(name, dos.SHARED_LOCK) orelse {
        _ = Printf(dl, "%s: cannot be found\n", .{name});
        return dos.RETURN_ERROR;
    };
    const file = switch (datatypes.subclass.readWhole(sys, dl, lock)) {
        .got => |bytes| bytes,
        else => {
            dl.UnLock(lock);
            _ = Printf(dl, "%s: cannot be read\n", .{name});
            return dos.RETURN_ERROR;
        },
    };
    dl.UnLock(lock);
    defer sys.FreeVec(file.ptr);

    const codec_there = sys.OpenResource(jpeg.JPEGNAME) != null;
    if (sys.OpenResource(jpeg.JPEGNAME)) |found| {
        codecAlone(dl, @ptrCast(found), tb, file, rounds);
    } else {
        _ = Printf(dl, "No %s: software only\n", .{jpeg.JPEGNAME});
    }

    const dt_lib = sys.OpenLibrary(datatypes.DATATYPESNAME, 0) orelse {
        _ = Printf(dl, "No %s - has C:AddDataTypes run?\n", .{datatypes.DATATYPESNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(dt_lib);
    const dt: *DataTypesBase = @ptrCast(dt_lib);

    const soft = make(dt, tb, name, jpegclass.JDEC_SOFTWARE, rounds) orelse {
        _ = Printf(dl, "jpeg.datatype could not read it in software\n", .{});
        return dos.RETURN_ERROR;
    };
    defer dt.DisposeDTObject(soft.object);
    _ = Printf(dl, "Datatype, software: %u x %u in %ld us, read by %s\n", .{ soft.width, soft.height, soft.best, decoderName(soft.decoder) });
    if (!codec_there) return dos.RETURN_OK;

    const codec = make(dt, tb, name, jpegclass.JDEC_CODEC, rounds) orelse {
        _ = Printf(dl, "Datatype, codec: refused\n", .{});
        return dos.RETURN_WARN;
    };
    defer dt.DisposeDTObject(codec.object);
    _ = Printf(dl, "Datatype, codec: %u x %u in %ld us, read by %s\n", .{ codec.width, codec.height, codec.best, decoderName(codec.decoder) });
    compare(dl, &soft, &codec);
    return dos.RETURN_OK;
}
