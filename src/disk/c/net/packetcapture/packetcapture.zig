// SPDX-License-Identifier: MIT
//! PacketCapture: the frames an interface sends and takes, into a pcap
//! file Wireshark and tcpdump read. Built against the SDK only.
//!
//!   PacketCapture INTERFACE/A,TO/K/A,COUNT/K/N,TIME/K/N,SNAPLEN/K/N,QUIET/S,FILTERED/S
//!
//! INTERFACE is eth0, ETH0 or lo0. Frames are written to TO until COUNT
//! of them, TIME seconds, or Ctrl-C; SNAPLEN cuts each at that many bytes
//! (all of it unless given). At the end, unless QUIET: how many frames,
//! and how many the capture had no room for.
//!
//! With FILTERED, only the packets that came in and a packet hook - a
//! firewall - dropped or refused: each the IP packet behind a four-byte
//! address family, which is how to see which rule bites.
//!
//! The frames come from a capture socket (PF_PACKET) held to the
//! interface. The file is pcap with microsecond stamps, in the chip's byte
//! order, which every reader turns; its link is Ethernet, or for lo0 a
//! four-byte address family before each packet. The stamps are the
//! system clock's, which keeps local time: a reader shows it as UTC.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const timer = sdk.devices.timer;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const TimerBase = sdk.interface.timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "PacketCapture";
const VERSION_STRING = "\x00$VER: PacketCapture 1.2 (08.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "INTERFACE/A,TO/K/A,COUNT/K/N,TIME/K/N,SNAPLEN/K/N,QUIET/S,FILTERED/S";
const arg_interface = 0;
const arg_to = 1;
const arg_count = 2;
const arg_time = 3;
const arg_snaplen = 4;
const arg_quiet = 5;
const arg_filtered = 6;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOINTERFACE = "%s: no interface %s\n";
const MSG_FAILED = "%s: %s failed: %s (errno %d)\n";
const MSG_CAPTURING = "Capturing on %s into %s; Ctrl-C stops\n";
const MSG_DONE = "%lu frames, %lu bytes; %lu had no room\n";

/// The largest frame, its capture header, and some.
const buffer_bytes = 2048;
const snaplen_most: u32 = 65535;
/// 1 January 1970 to 1 January 1978, where the system clock counts from.
const unix_to_system: u32 = 252_460_800;

/// The file's header: magic, version 2.4, zone, accuracy, the longest
/// frame kept, the link.
const FileHeader = extern struct {
    magic: u32 = 0xA1B2_C3D4,
    major: u16 = 2,
    minor: u16 = 4,
    zone: i32 = 0,
    accuracy: u32 = 0,
    snaplen: u32,
    link: u32,
};

/// A frame's record header: when, how much is in the file, how long it
/// was.
const RecordHeader = extern struct {
    secs: u32,
    micro: u32,
    kept: u32,
    length: u32,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [7]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const to: [*:0]const u8 = @ptrFromInt(argv[arg_to]);
    const count = number(argv[arg_count], 0);
    const seconds = number(argv[arg_time], 0);
    const snaplen = @min(number(argv[arg_snaplen], snaplen_most), snaplen_most);
    const quiet = argv[arg_quiet] != 0;
    const filtered = argv[arg_filtered] != 0;

    // The interface's name as the stack has it: in lower case.
    const given: [*:0]const u8 = @ptrFromInt(argv[arg_interface]);
    var name: [bsd.IFNAMSIZ:0]u8 = @splat(0);
    var at: usize = 0;
    while (given[at] != 0 and at + 1 < name.len) : (at += 1) {
        const char = given[at];
        name[at] = if (char >= 'A' and char <= 'Z') char + 32 else char;
    }

    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, bsd.SOCKETNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);

    var state: u32 = 0;
    const query = [_]TagItem{ .{ .tag = bsd.IFQ_State, .data = @intFromPtr(&state) }, .{} };
    if (sb.QueryInterfaceTagList(&name, &query) != 0) {
        _ = Printf(dl, MSG_NOINTERFACE, .{ COMMAND_NAME, @as([*:0]const u8, &name) });
        return dos.RETURN_ERROR;
    }
    const link: u32 = if (filtered or state & bsd.IFSTATE_LOOPBACK != 0) bsd.CAPTURE_LINK_NULL else bsd.CAPTURE_LINK_ETHERNET;

    const capture = sb.Socket(bsd.PF_PACKET, bsd.SOCK_RAW, 0);
    if (capture < 0) return failed(dl, sb, "Socket");
    defer _ = sb.CloseSocket(capture);
    if (sb.SetSockOpt(capture, bsd.SOL_SOCKET, bsd.SO_BINDTODEVICE, &name, bsd.IFNAMSIZ) < 0) return failed(dl, sb, "SetSockOpt");

    var clock: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&clock.node);
    const timer_base: *TimerBase = @ptrCast(@alignCast(clock.node.device.?));

    const memory = sys.AllocVec(buffer_bytes, exec.MEMF_ANY) orelse return dos.RETURN_FAIL;
    defer sys.FreeVec(memory);
    const buffer = @as([*]u8, @ptrCast(memory))[0..buffer_bytes];

    const file = dl.Open(to, dos.MODE_NEWFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), to);
        return dos.RETURN_ERROR;
    };
    defer _ = dl.Close(file);
    const header: FileHeader = .{ .snaplen = snaplen, .link = link };
    if (!write(dl, file, bytesOf(&header))) return writeFailed(dl);
    if (!quiet) _ = Printf(dl, MSG_CAPTURING, .{ @as([*:0]const u8, &name), to });

    const deadline: ?u64 = if (seconds != 0) eclock(timer_base) + @as(u64, seconds) * 1_000_000 else null;
    var frames: u64 = 0;
    var bytes: u64 = 0;
    var dropped: u64 = 0;
    const capture_bytes = @sizeOf(bsd.CaptureHeader);
    while (count == 0 or frames < count) {
        var patience: timer.TimeVal = .{};
        var patience_pointer: ?*timer.TimeVal = null;
        if (deadline) |until| {
            const now = eclock(timer_base);
            if (now >= until) break;
            patience = timer.TimeVal.fromMicros(until - now);
            patience_pointer = &patience;
        }
        var read: bsd.fd_set = .{};
        read.set(capture);
        const ready = sb.WaitSelect(capture + 1, &read, null, null, patience_pointer, null);
        if (ready < 0) {
            if (sb.Errno() == bsd.EINTR) break;
            return failed(dl, sb, "WaitSelect");
        }
        if (ready == 0) continue;
        const got = sb.Recv(capture, buffer.ptr, buffer_bytes, 0);
        if (got < 0) {
            if (sb.Errno() == bsd.EINTR) break;
            return failed(dl, sb, "Recv");
        }
        if (got < capture_bytes) continue;
        const seen: *align(1) const bsd.CaptureHeader = @ptrCast(buffer.ptr);
        // A packet a hook stopped comes as a second copy: kept with
        // FILTERED, and only then.
        if ((seen.flags & bsd.CAPTURE_FILTERED != 0) != filtered) continue;
        const frame = buffer[capture_bytes..@intCast(got)];
        const kept: u32 = @min(@as(u32, @intCast(frame.len)), snaplen);
        const record: RecordHeader = .{
            .secs = seen.secs +% unix_to_system,
            .micro = seen.micro,
            .kept = kept,
            .length = seen.length,
        };
        if (!write(dl, file, bytesOf(&record)) or !write(dl, file, frame[0..kept])) return writeFailed(dl);
        frames += 1;
        bytes += seen.length;
        dropped += seen.dropped;
    }
    if (!quiet) _ = Printf(dl, MSG_DONE, .{ frames, bytes, dropped });
    return dos.RETURN_OK;
}

fn number(arg: usize, default: u32) u32 {
    if (arg == 0) return default;
    const value: *const i32 = @ptrFromInt(arg);
    return if (value.* < 0) default else @intCast(value.*);
}

fn bytesOf(value: anytype) []const u8 {
    const size = @sizeOf(@TypeOf(value.*));
    return @as(*const [size]u8, @ptrCast(value));
}

fn write(dl: *DosBase, file: *dos.FileHandle, data: []const u8) bool {
    return dl.Write(file, data.ptr, @intCast(data.len)) == data.len;
}

fn writeFailed(dl: *DosBase) i32 {
    _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
    return dos.RETURN_ERROR;
}

fn failed(dl: *DosBase, sb: *SocketBase, what: [*:0]const u8) i32 {
    _ = Printf(dl, MSG_FAILED, .{ COMMAND_NAME, what, bsd.errnoText(sb, sb.Errno()), sb.Errno() });
    return dos.RETURN_ERROR;
}

/// The E-clock in microseconds.
fn eclock(timer_base: *TimerBase) u64 {
    var value: timer.EClockVal = .{};
    const rate = timer_base.ReadEClock(&value);
    const count = @as(u64, value.hi) << 32 | value.lo;
    return count / rate * 1_000_000 + count % rate * 1_000_000 / rate;
}
