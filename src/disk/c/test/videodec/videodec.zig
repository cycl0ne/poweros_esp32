// SPDX-License-Identifier: MIT
//! VideoDec: an elementary video stream decoded by the chip's decoder,
//! timed and checked. Built against the SDK only.
//!
//!   VideoDec FILE/A,H265/S,FRAME/K/N,TO/K
//!
//! The file - H.264, or H.265 with H265 or a name ending in .h265, .265
//! or .hevc, in Annex B form as `ffmpeg -c:v copy -bsf:v
//! h264_mp4toannexb out.h264` writes it - is read into memory and cut into
//! pictures at their access units; each is fed to videodec.resource with
//! a time of 40 ms a picture, and the frames are taken as they come. The
//! stream's size, profile and frame rate are printed, then how many
//! frames came out and how fast, and whether they came in order: their
//! numbers one after another, their times rising.
//!
//! FRAME (and TO) writes that frame - counted from 0 in the order they
//! are shown - into TO as it is shown, as raw NV12: its rows of
//! brightness, then its rows of colour, each as wide as the picture. On
//! the PC, `ffmpeg -i FILE -vf "select=eq(n\,FRAME)" -frames:v 1
//! -pix_fmt nv12 -f rawvideo ref.nv12` makes the same frame to compare
//! byte for byte.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const datatypes = sdk.datatypes;
const videodec = sdk.resources.videodec;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const VideoDecBase = videodec.VideoDecBase;
const TimerBase = timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "VideoDec";
const VERSION_STRING = "\x00$VER: VideoDec 1.0 (29.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE/A,H265/S,FRAME/K/N,TO/K";
const arg_file = 0;
const arg_h265 = 1;
const arg_frame = 2;
const arg_to = 3;

/// The time each picture is fed with: 25 a second.
const picture_us: u64 = 40_000;

fn now(tb: *TimerBase) u64 {
    var ev: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&ev);
    return ev.toTicks() * 1_000_000 / rate;
}

/// An elementary stream cut into access units: each from the start code
/// of its first unit to the start code of the next access unit's.
const Splitter = struct {
    bytes: []const u8,
    h265: bool,
    /// The next unit's start code.
    at: usize,

    fn init(bytes: []const u8, h265: bool) Splitter {
        return .{ .bytes = bytes, .h265 = h265, .at = startCode(bytes, 0) };
    }

    /// Where the start code at or after `from` begins - its leading zero
    /// of four, or of three - or the end.
    fn startCode(bytes: []const u8, from: usize) usize {
        var k = from;
        while (k + 3 <= bytes.len) : (k += 1) {
            if (bytes[k] == 0 and bytes[k + 1] == 0 and bytes[k + 2] == 1) {
                return if (k > from and bytes[k - 1] == 0) k - 1 else k;
            }
        }
        return bytes.len;
    }

    /// The unit's first bytes past its start code.
    fn payload(bytes: []const u8, code: usize) usize {
        var k = code;
        while (k < bytes.len and bytes[k] == 0) : (k += 1) {}
        return k + 1;
    }

    const Kind = struct { vcl: bool, first: bool, opens: bool };

    /// What a unit is: a slice (vcl), the first of its picture, or one
    /// that opens an access unit when it comes after a slice.
    fn kind(s: *const Splitter, p: usize) Kind {
        const b = s.bytes;
        if (p + 3 > b.len) return .{ .vcl = false, .first = false, .opens = false };
        if (s.h265) {
            const t = (b[p] >> 1) & 0x3F;
            return .{
                .vcl = t < 32,
                .first = t < 32 and b[p + 2] & 0x80 != 0,
                .opens = (t >= 32 and t <= 35) or t == 39 or (t >= 41 and t <= 44) or (t >= 48 and t <= 55),
            };
        }
        const t = b[p] & 0x1F;
        return .{
            .vcl = t >= 1 and t <= 5,
            .first = t >= 1 and t <= 5 and b[p + 1] & 0x80 != 0,
            .opens = (t >= 6 and t <= 9) or (t >= 14 and t <= 18),
        };
    }

    fn next(s: *Splitter) ?[]const u8 {
        const b = s.bytes;
        if (s.at >= b.len) return null;
        const start = s.at;
        var seen_vcl = false;
        var code = s.at;
        while (code < b.len) {
            const k = s.kind(payload(b, code));
            if (seen_vcl and ((k.vcl and k.first) or k.opens)) break;
            if (k.vcl) seen_vcl = true;
            code = startCode(b, payload(b, code));
        }
        s.at = code;
        return b[start..code];
    }
};

/// What came out, and whether in order.
const Tally = struct {
    frames: u32 = 0,
    out_of_order: u32 = 0,
    last_time: u64 = 0,
    wanted: ?u32 = null,
    to: ?[*:0]const u8 = null,
    written: bool = false,
};

fn take(dl: *DosBase, vb: *VideoDecBase, decoder: *videodec.VideoDecoder, frame: *videodec.VideoDecFrame, t: *Tally) void {
    if (frame.number != t.frames or (t.frames > 0 and frame.time <= t.last_time)) {
        if (t.out_of_order < 4) {
            _ = Printf(dl, "frame %u: number %u, time %lu after %lu\n", .{ t.frames, frame.number, frame.time, t.last_time });
        }
        t.out_of_order += 1;
    }
    if (t.wanted) |n| {
        if (n == t.frames) {
            if (t.to) |name| t.written = writeFrame(dl, name, frame);
        }
    }
    t.last_time = frame.time;
    t.frames += 1;
    vb.ReleaseVideoFrame(decoder, frame);
}

/// The frame as it is shown, as raw NV12, into the file `name`.
fn writeFrame(dl: *DosBase, name: [*:0]const u8, frame: *const videodec.VideoDecFrame) bool {
    const file = dl.Open(name, dos.MODE_NEWFILE) orelse {
        _ = Printf(dl, "%s: cannot be written\n", .{name});
        return false;
    };
    defer _ = dl.Close(file);
    const width: isize = frame.width;
    var row: u32 = 0;
    while (row < frame.height) : (row += 1) {
        if (dl.Write(file, frame.y.? + row * frame.pitch, width) != width) return false;
    }
    row = 0;
    while (row < (frame.height + 1) / 2) : (row += 1) {
        if (dl.Write(file, frame.cbcr.? + row * frame.pitch, width) != width) return false;
    }
    return true;
}

fn errorName(code: u32) [*:0]const u8 {
    return switch (code) {
        videodec.VDERR_OK => "ok",
        videodec.VDERR_NEED_DATA => "needs data",
        videodec.VDERR_END => "ended",
        videodec.VDERR_FULL => "full",
        videodec.VDERR_CORRUPT => "corrupt, or the chip stopped",
        videodec.VDERR_NO_ENGINE => "no decoder (or no DEVS:firmware/wave511_dec_fw.bin)",
        videodec.VDERR_UNSUPPORTED => "not supported",
        videodec.VDERR_NO_MEMORY => "no memory",
        videodec.VDERR_BUSY => "every decoder in use",
        else => "?",
    };
}

fn endsWith(name: [*:0]const u8, tail: []const u8) bool {
    var n: usize = 0;
    while (name[n] != 0) : (n += 1) {}
    if (n < tail.len) return false;
    for (tail, name[n - tail.len .. n]) |want, got| {
        const lower = if (got >= 'A' and got <= 'Z') got + 32 else got;
        if (lower != want) return false;
    }
    return true;
}

fn run(dl: *DosBase, vb: *VideoDecBase, tb: *TimerBase, file: []const u8, h265: bool, t: *Tally) i32 {
    var err: u32 = 0;
    const codec = if (h265) videodec.VDCODEC_H265 else videodec.VDCODEC_H264;
    const opened = now(tb);
    const decoder = vb.OpenVideoDecoder(codec, null, &err) orelse {
        _ = Printf(dl, "OpenVideoDecoder: %s\n", .{errorName(err)});
        return dos.RETURN_FAIL;
    };
    defer vb.CloseVideoDecoder(decoder);
    _ = Printf(dl, "opened in %lu us\n", .{now(tb) - opened});

    var splitter = Splitter.init(file, h265);
    var pictures: u32 = 0;
    var frame: videodec.VideoDecFrame = .{};
    var told = false;
    var started: u64 = 0;
    var failure: u32 = videodec.VDERR_OK;
    feeding: while (splitter.next()) |picture| {
        while (true) {
            const fed = vb.FeedVideoDecoder(decoder, picture.ptr, @intCast(picture.len), pictures * picture_us, 0);
            if (fed == videodec.VDERR_OK) break;
            if (fed != videodec.VDERR_FULL) {
                failure = fed;
                break :feeding;
            }
            const got = vb.DecodeVideoFrame(decoder, &frame);
            if (got == videodec.VDERR_OK) {
                take(dl, vb, decoder, &frame, t);
            } else {
                failure = got;
                break :feeding;
            }
        }
        pictures += 1;
        if (!told) {
            var info: videodec.VideoDecInfo = .{};
            const asked = vb.GetVideoDecoderInfo(decoder, &info);
            if (asked == videodec.VDERR_OK) {
                told = true;
                _ = Printf(dl, "%u x %u (coded %u x %u from %u,%u), %u bit, profile %u, %u/%u frames a second, %u frames\n", .{
                    info.width,     info.height,  info.coded_width, info.coded_height, info.left,   info.top,
                    info.bit_depth, info.profile, info.rate_num,    info.rate_den,     info.frames,
                });
                started = now(tb);
            } else if (asked != videodec.VDERR_NEED_DATA) {
                failure = asked;
                break :feeding;
            }
        }
        while (true) {
            const got = vb.DecodeVideoFrame(decoder, &frame);
            if (got == videodec.VDERR_OK) {
                take(dl, vb, decoder, &frame, t);
            } else if (got == videodec.VDERR_NEED_DATA) {
                break;
            } else {
                failure = got;
                break :feeding;
            }
        }
    }
    if (failure == videodec.VDERR_OK) {
        _ = vb.FeedVideoDecoder(decoder, null, 0, 0, videodec.VDFEED_END);
        while (true) {
            const got = vb.DecodeVideoFrame(decoder, &frame);
            if (got == videodec.VDERR_OK) {
                take(dl, vb, decoder, &frame, t);
            } else {
                if (got != videodec.VDERR_END) failure = got;
                break;
            }
        }
    }
    const took = now(tb) - started;
    _ = Printf(dl, "%u pictures fed, %u frames out in %lu ms", .{ pictures, t.frames, took / 1000 });
    if (took > 0 and t.frames > 0) {
        const per_100s = @as(u64, t.frames) * 100_000_000 / took;
        _ = Printf(dl, ": %lu.%02lu frames a second", .{ per_100s / 100, per_100s % 100 });
    }
    _ = Printf(dl, "\n", .{});
    if (t.out_of_order > 0) _ = Printf(dl, "%u frames out of order\n", .{t.out_of_order});
    if (t.to) |name| {
        if (t.written) _ = Printf(dl, "frame %u written to %s\n", .{ t.wanted.?, name }) else _ = Printf(dl, "frame %u not written\n", .{t.wanted.?});
    }
    if (failure != videodec.VDERR_OK) {
        _ = Printf(dl, "stopped: %s\n", .{errorName(failure)});
        return dos.RETURN_ERROR;
    }
    return if (t.out_of_order == 0) dos.RETURN_OK else dos.RETURN_WARN;
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
    const name: [*:0]const u8 = @ptrFromInt(argv[arg_file]);
    const h265 = argv[arg_h265] != 0 or endsWith(name, ".h265") or endsWith(name, ".265") or endsWith(name, ".hevc");
    var tally: Tally = .{};
    if (argv[arg_frame] != 0) tally.wanted = @intCast(@max(0, @as(*const i32, @ptrFromInt(argv[arg_frame])).*));
    if (argv[arg_to] != 0) tally.to = @ptrFromInt(argv[arg_to]);

    const found = sys.OpenResource(videodec.VIDEODECNAME) orelse {
        _ = Printf(dl, "No %s on this machine\n", .{videodec.VIDEODECNAME});
        return dos.RETURN_WARN;
    };
    const vb: *VideoDecBase = @ptrCast(found);
    if (vb.VideoDecCodecs() & (if (h265) videodec.VDCODEC_H265 else videodec.VDCODEC_H264) == 0) {
        _ = Printf(dl, "The decoder does not take %s\n", .{if (h265) "H.265" else "H.264"});
        return dos.RETURN_WARN;
    }

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
    _ = Printf(dl, "%s: %lu bytes of %s\n", .{ name, file.len, if (h265) "H.265" else "H.264" });
    return run(dl, vb, tb, file, h265, &tally);
}
