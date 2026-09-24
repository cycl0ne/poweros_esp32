// SPDX-License-Identifier: MPL-2.0
//! The console handler: CON:, RAW: and AUX:, a terminal a program talks to
//! through dos. A ROM module ("con-handler", a ResidentHandler) built
//! against the SDK only; dos.library's init adds the three nodes that name
//! it, and GetDeviceProc starts it when one of them is first opened. The
//! line editing is editor.zig's, the window the name asks for window.zig's.
//!
//! **What the terminal is** is the node's startup (ACTION_STARTUP's
//! dp_Arg2):
//!
//! - 0 (CON:) and 1 (RAW:, which starts in raw mode): a window of this
//!   console's own, with a console.device unit on it. The name that opened
//!   it says where the window goes and what it may do (window.zig), so
//!   **one Open is one window**: the handler claims no node and dos starts
//!   another process for the next name asked of CON:. The process closes
//!   its window and ends when its last handle closes, and the window's
//!   close gadget is the end of the input, as Ctrl-\ is. A name may hand
//!   over a window the caller opened (`WINDOW`) instead, which the console
//!   takes over and closes, and whose events it leaves alone.
//! - A FileSysStartupMsg (AUX:): a console on an exec device, opened with
//!   the name, unit and flags in it. A startup that names no device is the
//!   machine's own console port, as the board's SYSTAG_Console says - the
//!   USB port on a board whose UART0 is the kernel's own output and
//!   nothing else; UART0 on the emulator, which QEMU puts on its
//!   terminal. There is one such port and
//!   everything shares it, so this handler claims its node and serves
//!   every Open of it from the one process.
//!
//! Both are the same two commands on an exec device, CMD_READ of a byte
//! and CMD_WRITE of a string, which is why the handler above them is one
//! piece of code.
//!
//! Packets:
//! - FINDINPUT, FINDOUTPUT, FINDUPDATE: an interactive handle. With AUTO
//!   the terminal itself waits for the first READ, WRITE, WAIT_CHAR or
//!   DISK_INFO. END: the handle's pending READs end (0), and the last one
//!   closes the terminal.
//! - READ: waits for a line (cooked) or a byte (raw); one line at most per
//!   READ, the rest stays. 0 after Ctrl-\. WRITE: out at once, unless
//!   Ctrl-S is holding the console, and then it waits unanswered - so a
//!   program writing to a console somebody has stopped stops with it, and
//!   the next character typed lets them both go.
//! - FORCE, STACK, QUEUE: text (dp_Arg2, dp_Arg3 long) for the console to
//!   read as though it had been typed into it - in front of whatever is
//!   waiting, or behind it. It goes in a character at a time whenever
//!   nothing else is happening, so it is echoed and edited exactly as
//!   typing is. The answer is how much was taken, or -1 if none of it
//!   fits. DROP throws away what has not gone in yet.
//! - WAIT_CHAR (microseconds): at once DOSTRUE (res2: whole lines ready)
//!   or, after the time, DOSFALSE; timer.device, UNIT_MICROHZ.
//! - SCREEN_MODE: 1 raw, 0 cooked. CHANGE_SIGNAL (dp_Arg2 a port): whose
//!   task gets the break signals from now on.
//! - DISK_INFO: an InfoData with ID_CON or ID_RAWCON and the open count.
//! - IS_FILESYSTEM: DOSFALSE; anything else ERROR_ACTION_NOT_KNOWN.
//!
//! Ctrl-C to Ctrl-F signal the CHANGE_SIGNAL task, else the last reader's,
//! and the last writer's if another.
//!
//! CHANGE_SIGNAL hands the old port back in dp_Arg3, since dp_Res2 is 32
//! bits here. Each pending WAIT_CHAR has its own timer request. FORCE and
//! STACK do the same thing: telling them apart would take a second way of
//! handing text out, one that puts a line straight into a reader's buffer
//! without showing it, and there is none. There is no GET_VARS, which
//! would answer with the address of the handler's own private state; the
//! history is the editor's, with no SET_HIST/GET_HIST packets; and there
//! is no paste list, since text copied with the pointer goes in through
//! console.device's snip. A clipboard shared between programs is a module
//! of its own, not this one (docs/console.md). READs wait without blocking
//! the handler; SEEK and unknown packets are ERROR_ACTION_NOT_KNOWN.
//!
//! **The banner** (`src/rom/release.zig`) goes out before a console's first
//! write. Each console has its own, so it stands above the first thing
//! written to it - which for a shell is its first prompt.

const std = @import("std");
const sdk = @import("sdk");
const release = @import("../../release.zig");
const dos = sdk.dos;
const exec = sdk.exec;
const serial = sdk.devices.serial;
const usbserial = sdk.devices.usbserial;
const timer = sdk.devices.timer;
const filehandler = dos.filehandler;
const con = sdk.console;
const intuition = sdk.intuition;
const wn = intuition.windows;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const DosPacket = dos.DosPacket;
const Process = dos.Process;
const MsgPort = exec.MsgPort;
pub const editor = @import("editor.zig");
const Editor = editor.Editor;
pub const window = @import("window.zig");

pub const HANDLER_NAME = "con-handler";
const HANDLER_VERSION = 1;
const HANDLER_REVISION = 0;
const BUILD_DATE = "16.9.2026";
const HANDLER_VERSION_STRING =
    "\x00$VER: " ++ HANDLER_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ HANDLER_VERSION, HANDLER_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// READs and WAIT_CHARs that can wait at once.
const max_reads = 16;
/// WRITEs that can wait at once while the output is held. A writer waits
/// for its answer, so this is one per program writing here.
const max_held = 8;
pub const max_waits = 4;

/// The banner as it reaches the terminal: the editor turns each "\n" of it
/// into CR LF.
const banner_on_screen = blk: {
    var out: []const u8 = "";
    for (release.BANNER) |ch| out = out ++ (if (ch == '\n') "\r\n" else &[_]u8{ch});
    break :blk out;
};

fn asArg(p: anytype) isize {
    return @bitCast(@intFromPtr(p));
}

/// The handler's logic over `Io`, which writes to the terminal, replies,
/// signals, opens and closes the devices and runs WAIT_CHAR's timers
/// (DeviceIo on the board, TestIo in the tests).
pub fn Handler(comptime Io: type) type {
    return struct {
        const Self = @This();

        io: *Io,
        ed: Editor,
        /// The node's mode (RAW: raw), for each first open.
        raw_default: bool,
        /// AUTO: the terminal is not opened when a handle is, but when
        /// something is first read from it or written to it, so a console
        /// nothing ever says anything on never appears.
        auto_open: bool = false,
        /// The terminal itself is open (its window is up, its port is
        /// open), which with AUTO happens later than the first handle.
        terminal_open: bool = false,
        /// The banner has gone out; it goes before the node's first write.
        banner_done: bool = false,
        opens: u32 = 0,
        reads: [max_reads]*DosPacket = undefined,
        read_count: usize = 0,
        /// WRITEs waiting to go out, in the order they came. While the
        /// output is held they are not answered, so a program writing to a
        /// console somebody has stopped stops with it.
        held: [max_held]*DosPacket = undefined,
        held_count: usize = 0,
        waits: [max_waits]?*DosPacket = @splat(null),
        /// The last reader's and writer's reply ports, and CHANGE_SIGNAL's.
        reader: ?*MsgPort = null,
        writer: ?*MsgPort = null,
        signal_port: ?*MsgPort = null,

        pub fn init(io: *Io, raw: bool) Self {
            return .{ .io = io, .ed = .{ .sink = .{ .ctx = io, .write = &Io.sinkWrite }, .raw = raw }, .raw_default = raw };
        }

        pub fn packet(h: *Self, pkt: *DosPacket) void {
            switch (pkt.getAction()) {
                .findinput, .findoutput, .findupdate => h.open(pkt),
                .end => h.end(pkt),
                .read => {
                    h.reader = pkt.port;
                    if (!h.terminal(pkt)) return;
                    if (pkt.args.io.length <= 0 or pkt.args.io.buffer == null) return h.io.reply(pkt, 0, 0);
                    if (h.read_count == max_reads) return h.io.reply(pkt, -1, dos.ERROR_NO_FREE_STORE);
                    h.reads[h.read_count] = pkt;
                    h.read_count += 1;
                    h.serve();
                },
                .write => {
                    h.writer = pkt.port;
                    if (!h.terminal(pkt)) return;
                    h.hold(pkt);
                    h.writeHeld();
                },
                .force, .stack, .queue => {
                    // dp_Arg2 the text and dp_Arg3 how much of it, which
                    // is what a READ's arguments already name. Nothing is
                    // taken unless all of it fits: the answer is a number,
                    // and half a line would be worse than none.
                    const a = pkt.args.io;
                    const text = a.buffer orelse return h.io.reply(pkt, -1, 0);
                    if (a.length <= 0) return h.io.reply(pkt, -1, 0);
                    const at: Editor.Push = if (pkt.getAction() == .queue) .last else .first;
                    if (!h.ed.pushIn(text[0..@intCast(a.length)], at)) return h.io.reply(pkt, -1, 0);
                    h.io.reply(pkt, a.length, 0);
                },
                .drop => {
                    h.ed.dropPushed();
                    h.io.reply(pkt, dos.DOSTRUE, 0);
                },
                .wait_char => {
                    if (!h.terminal(pkt)) return;
                    h.waitChar(pkt);
                },
                .screen_mode => {
                    h.ed.setRaw(pkt.args.screen_mode.mode != 0);
                    h.io.reply(pkt, dos.DOSTRUE, 0);
                    h.serve();
                },
                .change_signal => {
                    const old = h.signal_port orelse h.reader;
                    const port: ?*MsgPort = @ptrFromInt(@as(usize, @bitCast(pkt.args.raw[1])));
                    if (port) |p| h.signal_port = p;
                    pkt.args.raw[2] = asArg(old);
                    h.io.reply(pkt, dos.DOSTRUE, 0);
                },
                .disk_info => {
                    if (!h.terminal(pkt)) return;
                    const info: *dos.InfoData = @ptrFromInt(@as(usize, @bitCast(pkt.args.raw[0])));
                    info.* = .{ .disk_type = if (h.ed.raw) dos.ID_RAWCON else dos.ID_CON, .in_use = @intCast(h.opens) };
                    h.io.reply(pkt, dos.DOSTRUE, 0);
                },
                .is_filesystem => h.io.reply(pkt, dos.DOSFALSE, 0),
                else => h.io.reply(pkt, dos.DOSFALSE, dos.ERROR_ACTION_NOT_KNOWN),
            }
        }

        /// The terminal, opened if it is not open yet. A packet that finds
        /// it cannot be opened is answered here and false comes back.
        fn terminal(h: *Self, pkt: *DosPacket) bool {
            if (h.terminal_open) return true;
            if (!h.io.open()) {
                h.io.reply(pkt, dos.DOSFALSE, dos.ERROR_DEVICE_NOT_MOUNTED);
                return false;
            }
            h.terminal_open = true;
            h.ed.reset(h.raw_default);
            return true;
        }

        /// A WRITE onto the end of the queue. With no room the oldest goes
        /// out first: holding the output must never cost a program what it
        /// wrote.
        fn hold(h: *Self, pkt: *DosPacket) void {
            if (h.held_count == max_held) h.writeOut(h.takeHeld());
            h.held[h.held_count] = pkt;
            h.held_count += 1;
        }

        /// The first waiting WRITE, off the queue.
        fn takeHeld(h: *Self) *DosPacket {
            const pkt = h.held[0];
            h.removeHeld(0);
            return pkt;
        }

        /// What is waiting, as far as the hold allows. Nothing held: the
        /// one just queued goes out here, which is the ordinary case.
        fn writeHeld(h: *Self) void {
            while (h.held_count > 0 and !h.ed.hold) h.writeOut(h.takeHeld());
        }

        /// A WRITE onto the terminal, and its answer.
        fn writeOut(h: *Self, pkt: *DosPacket) void {
            const a = pkt.args.io;
            // A READ is waiting, so whatever is on the line now is a
            // prompt somebody is meant to answer: the editor puts it back
            // under this write.
            h.ed.waiting = h.read_count > 0;
            if (!h.banner_done) {
                h.banner_done = true;
                h.ed.write(release.BANNER);
            }
            if (a.length > 0) {
                h.ed.write(a.buffer.?[0..@intCast(a.length)]);
                h.ed.flush();
            }
            h.io.reply(pkt, @max(a.length, 0), 0);
        }

        fn open(h: *Self, pkt: *DosPacket) void {
            const fh = pkt.args.find.fh orelse return h.io.reply(pkt, dos.DOSFALSE, dos.ERROR_INVALID_LOCK);
            if (!h.auto_open and !h.terminal(pkt)) return;
            fh.interactive = true;
            fh.key = fh;
            h.opens += 1;
            h.io.reply(pkt, dos.DOSTRUE, 0);
        }

        fn end(h: *Self, pkt: *DosPacket) void {
            const fh = pkt.args.file.fh;
            var i: usize = 0;
            while (i < h.read_count) {
                const r = h.reads[i];
                if (r.args.io.fh != fh and h.opens > 1) {
                    i += 1;
                    continue;
                }
                h.removeRead(i);
                h.io.reply(r, 0, 0);
            }
            // What the closing handle wrote goes out although the output
            // is held: a packet nobody will ever answer would leave its
            // writer waiting for good.
            var pending: usize = 0;
            while (pending < h.held_count) {
                const waiting = h.held[pending];
                if (waiting.args.io.fh != fh and h.opens > 1) {
                    pending += 1;
                    continue;
                }
                h.removeHeld(pending);
                h.writeOut(waiting);
            }
            if (h.opens > 0) h.opens -= 1;
            if (h.opens == 0) {
                for (&h.waits, 0..) |*w, slot| {
                    const waiting = w.* orelse continue;
                    h.io.stopTimer(slot);
                    w.* = null;
                    h.io.reply(waiting, dos.DOSFALSE, 0);
                }
                h.ed.dropPushed();
                if (h.terminal_open) h.io.close();
                h.terminal_open = false;
                h.reader = null;
                h.writer = null;
                h.signal_port = null;
            }
            h.io.reply(pkt, dos.DOSTRUE, 0);
        }

        fn removeRead(h: *Self, i: usize) void {
            std.mem.copyForwards(*DosPacket, h.reads[i .. h.read_count - 1], h.reads[i + 1 .. h.read_count]);
            h.read_count -= 1;
        }

        fn removeHeld(h: *Self, i: usize) void {
            std.mem.copyForwards(*DosPacket, h.held[i .. h.held_count - 1], h.held[i + 1 .. h.held_count]);
            h.held_count -= 1;
        }

        fn waitChar(h: *Self, pkt: *DosPacket) void {
            if (h.ed.readable()) return h.io.reply(pkt, dos.DOSTRUE, @intCast(h.ed.lineCount()));
            const timeout = pkt.args.wait.timeout;
            if (timeout <= 0) return h.io.reply(pkt, dos.DOSFALSE, 0);
            for (&h.waits, 0..) |*w, slot| {
                if (w.* != null) continue;
                if (!h.io.startTimer(slot, @intCast(timeout))) break;
                w.* = pkt;
                return;
            }
            h.io.reply(pkt, dos.DOSFALSE, dos.ERROR_NO_FREE_STORE);
        }

        /// WAIT_CHAR's time is up.
        pub fn timerDone(h: *Self, slot: usize) void {
            const pkt = h.waits[slot] orelse return;
            h.waits[slot] = null;
            h.io.reply(pkt, dos.DOSFALSE, 0);
        }

        /// A byte from the terminal.
        pub fn input(h: *Self, c: u8) void {
            h.ed.key(c);
            h.ed.flush();
            const bits = h.ed.breaks;
            h.ed.breaks = 0;
            if (bits != 0) {
                const target = h.signal_port orelse h.reader;
                if (target) |p| h.io.signal(p, bits);
                if (h.writer) |w| {
                    if (w != target) h.io.signal(w, bits);
                }
            }
            h.serve();
            // The key may have been the one that lets held output go.
            h.writeHeld();
        }

        /// One character of the text handed to this console, typed in as
        /// though it had come from the terminal: echoed, edited and read
        /// like anything else typed. Whether one went in.
        pub fn pushOne(h: *Self) bool {
            if (!h.terminal_open) return false;
            const c = h.ed.nextPushed() orelse return false;
            h.input(c);
            return true;
        }

        /// READs and WAIT_CHARs answered as far as the input goes.
        fn serve(h: *Self) void {
            while (h.read_count > 0 and h.ed.readable()) {
                const pkt = h.reads[0];
                h.removeRead(0);
                const a = pkt.args.io;
                const n = h.ed.read(a.buffer.?[0..@intCast(a.length)]);
                h.io.reply(pkt, @intCast(n), 0);
            }
            if (!h.ed.readable()) return;
            for (&h.waits, 0..) |*w, slot| {
                const pkt = w.* orelse continue;
                h.io.stopTimer(slot);
                w.* = null;
                h.io.reply(pkt, dos.DOSTRUE, @intCast(h.ed.lineCount()));
            }
        }
    };
}

// --- On the board ---

/// One port of a console: its read request, always out for one byte while
/// the console is open, and a copy of it for writing. A window's console
/// and a serial port answer the same two commands - CMD_READ of a byte,
/// CMD_WRITE of a string - so the handler drives either one through this.
const Unit = struct {
    device: [*:0]const u8,
    unit: u32,
    read: serial.IOExtSer = .{},
    write: serial.IOExtSer = .{},
    byte: u8 = 0,
    open: bool = false,
};

/// Handler's Io on the real machine: either a console.device unit in a
/// window this handler opened, or a serial port, with timer.device for
/// WAIT_CHAR. Every request replies to `port`.
const DeviceIo = struct {
    sys: *ExecBase,
    dl: *DosBase,
    port: *MsgPort,
    /// What this console is on: null a window of its own, else the exec
    /// device the node's startup names - and a startup naming no device is
    /// the machine's own console port.
    startup: ?*const dos.FileSysStartupMsg = null,
    /// What the name that opened this console asked of its window.
    spec: window.Spec = .{},
    units: [2]Unit = .{
        .{ .device = serial.SERIALNAME, .unit = serial.UNIT_UART0 },
        .{ .device = usbserial.USBSERIALNAME, .unit = 0 },
    },
    intuition_base: ?*IntuitionBase = null,
    win: ?*wn.Window = null,
    /// The window's own port, where its close gadget is heard.
    user_port: ?*MsgPort = null,
    /// The last handle has closed: this console has done its work.
    finished: bool = false,
    /// A window told to WAIT has had the key that lets it go.
    key_seen: bool = false,
    timer_open: bool = false,
    timers: [max_waits]timer.TimeRequest = @splat(.{}),
    timer_busy: [max_waits]bool = @splat(false),

    /// This console is a window of its own, so it belongs to the one Open
    /// that asked for it and the process ends with it.
    fn inWindow(io: *const DeviceIo) bool {
        return io.startup == null;
    }

    /// The window stands although the last handle has closed, because the
    /// name said WAIT: what is written on it stays until a key is pressed.
    fn waitPending(io: *const DeviceIo) bool {
        return io.inWindow() and io.spec.wait and !io.key_seen and io.units[0].open;
    }

    fn sinkWrite(ctx: *anyopaque, bytes: []const u8) void {
        const io: *DeviceIo = @ptrCast(@alignCast(ctx));
        for (&io.units) |*u| {
            if (!u.open) continue;
            u.write.io_ser.req.command = exec.CMD_WRITE;
            u.write.io_ser.data = @constCast(bytes.ptr);
            u.write.io_ser.length = @intCast(bytes.len);
            _ = io.sys.DoIO(&u.write.io_ser.req);
        }
    }

    fn reply(io: *DeviceIo, pkt: *DosPacket, res1: isize, res2: i32) void {
        io.dl.ReplyPkt(pkt, res1, res2);
    }

    fn signal(io: *DeviceIo, port: *MsgPort, bits: u32) void {
        if (port.sig_task) |task| io.sys.Signal(@ptrCast(@alignCast(task)), bits);
    }

    /// Whether the machine's console is UART0 rather than the USB port:
    /// the board's SYSTAG_Console, UART0 when it names none.
    fn consoleOnUart(io: *DeviceIo) bool {
        const st = sdk.expansion.systemtags;
        const utility_lib = io.sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return true;
        defer io.sys.CloseLibrary(utility_lib);
        const expansion_lib = io.sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return true;
        defer io.sys.CloseLibrary(expansion_lib);
        const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
        const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
        return ub.GetTagData(st.SYSTAG_Console, st.CONSOLE_UART0, eb.SystemTags()) == st.CONSOLE_UART0;
    }

    fn open(io: *DeviceIo) bool {
        return if (io.inWindow()) io.openWindow() else io.openPort();
    }

    /// A window of this console's own with a console.device unit on it.
    /// CONU_SNIPMAP: the console keeps the text, so it puts the window
    /// back itself when it is uncovered or sized, and what is on it can be
    /// picked up with the pointer.
    fn openWindow(io: *DeviceIo) bool {
        const lib = io.sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse return false;
        const ib: *IntuitionBase = @ptrCast(lib);
        io.intuition_base = ib;
        // The name may have handed this console a window, in which case it
        // opens none of its own.
        const mine = io.spec.window == 0;
        const w = (if (mine)
            window.open(ib, &io.spec, wn.IDCMP_CLOSEWINDOW)
        else
            window.adopt(ib, &io.spec)) orelse {
            io.closeWindow();
            return false;
        };
        io.win = w;
        // A window this console was handed belongs to whoever opened it as
        // far as its messages go: taking them off its port would take them
        // from the program waiting for them. So a console in somebody
        // else's window has no close gadget of its own to hear.
        io.user_port = if (mine) @ptrFromInt(window.windowAttr(ib, w, wn.WA_UserPort)) else null;
        const u = &io.units[0];
        io.units[1].open = false;
        u.device = con.CONSOLENAME;
        u.unit = @bitCast(con.CONU_SNIPMAP);
        u.read = .{ .io_ser = .{
            .req = .{ .message = .{ .reply_port = io.port, .length = @sizeOf(serial.IOExtSer) } },
            .data = @ptrCast(w),
        } };
        u.open = io.sys.OpenDevice(u.device, u.unit, &u.read.io_ser.req, 0) == 0;
        if (!u.open) {
            io.closeWindow();
            return false;
        }
        u.write = u.read;
        io.readNext(u);
        return true;
    }

    /// The console on an exec device: the one the startup names, or, when
    /// it names none, the machine's own console port, as the board's
    /// system tag list says: the USB port on a board whose UART0 is the
    /// kernel's own output and nothing else, UART0 where that is what
    /// the terminal shows.
    fn openPort(io: *DeviceIo) bool {
        const named: ?[*:0]const u8 = if (io.startup) |s| s.device else null;
        if (named) |name| {
            const u = &io.units[0];
            io.units[1].open = false;
            u.device = name;
            u.unit = if (io.startup) |s| s.unit else 0;
            return io.openUnit(u, if (io.startup) |s| s.flags else 0);
        }
        var any = false;
        const uart = io.consoleOnUart();
        for (&io.units, 0..) |*u, i| {
            // Unit 0 of the table is UART0, unit 1 the USB port.
            if ((i == 0) != uart) {
                u.open = false;
                continue;
            }
            if (io.openUnit(u, 0)) any = true;
        }
        return any;
    }

    fn openUnit(io: *DeviceIo, u: *Unit, flags: u32) bool {
        u.read = .{
            .io_ser = .{ .req = .{ .message = .{ .reply_port = io.port, .length = @sizeOf(serial.IOExtSer) } } },
            .ser_flags = serial.SERF_SHARED,
        };
        u.open = io.sys.OpenDevice(u.device, u.unit, &u.read.io_ser.req, flags) == 0;
        u.write = u.read;
        if (!u.open) return false;
        io.setLine(u);
        io.readNext(u);
        return true;
    }

    /// The line's speed and shape, when the startup's environment asks for
    /// them (de_Baud and de_Control, which C:Mount writes from a
    /// mountlist's `Baud` and `Control = "8N1/NONE"`). What it does not ask
    /// for is left as the port had it, so a console on the machine's own
    /// port is not re-timed by being opened, and a port that refuses the
    /// parameters altogether keeps the line it had.
    fn setLine(io: *DeviceIo, u: *Unit) void {
        const startup = io.startup orelse return;
        const env = startup.environ orelse return;
        if (env.baud == 0 and env.control == 0) return;
        var set = u.read;
        set.io_ser.req.command = serial.SDCMD_SETPARAMS;
        if (env.baud != 0) set.baud = env.baud;
        const bits = filehandler.controlDataBits(env.control);
        if (bits != 0) {
            set.read_len = bits;
            set.write_len = bits;
        }
        const stop = filehandler.controlStopBits(env.control);
        if (stop != 0) set.stop_bits = stop;
        switch (filehandler.controlParity(env.control)) {
            'E' => set.ser_flags |= serial.SERF_PARTY_ON,
            'O' => set.ser_flags |= serial.SERF_PARTY_ON | serial.SERF_PARTY_ODD,
            'N' => set.ser_flags &= ~(serial.SERF_PARTY_ON | serial.SERF_PARTY_ODD),
            else => {},
        }
        // How the two ends hold each other back: none, the hardware's two
        // lines, or the xON and xOFF characters in the stream.
        switch (filehandler.controlHandshake(env.control)) {
            'N' => {
                set.ser_flags |= serial.SERF_XDISABLED;
                set.ser_flags &= ~serial.SERF_7WIRE;
            },
            'R' => {
                set.ser_flags |= serial.SERF_XDISABLED | serial.SERF_7WIRE;
            },
            'X' => {
                set.ser_flags &= ~(serial.SERF_XDISABLED | serial.SERF_7WIRE);
            },
            else => {},
        }
        // A port that will not have them keeps the line it had - a
        // console that opens on the terminal as it stands is better than
        // no console. What it took is kept, so that everything written and
        // read after this goes out the same way.
        if (io.sys.DoIO(&set.io_ser.req) != 0) return;
        u.read.baud = set.baud;
        u.read.read_len = set.read_len;
        u.read.write_len = set.write_len;
        u.read.stop_bits = set.stop_bits;
        u.read.ser_flags = set.ser_flags;
        u.write = u.read;
    }

    fn readNext(io: *DeviceIo, u: *Unit) void {
        u.read.io_ser.req.command = exec.CMD_READ;
        u.read.io_ser.data = &u.byte;
        u.read.io_ser.length = 1;
        io.sys.SendIO(&u.read.io_ser.req);
    }

    fn close(io: *DeviceIo) void {
        io.finished = true;
        // WAIT: the window stays up, and with it the console's read, until
        // a key comes.
        if (io.waitPending()) return;
        for (&io.units) |*u| {
            if (!u.open) continue;
            _ = io.sys.AbortIO(&u.read.io_ser.req);
            _ = io.sys.WaitIO(&u.read.io_ser.req);
            io.sys.CloseDevice(&u.read.io_ser.req);
            u.open = false;
        }
        io.closeWindow();
    }

    /// The window and intuition.library, if this console has them.
    fn closeWindow(io: *DeviceIo) void {
        const ib = io.intuition_base orelse return;
        if (io.win) |w| ib.CloseWindow(w);
        io.win = null;
        io.user_port = null;
        io.sys.CloseLibrary(ib.lib());
        io.intuition_base = null;
    }

    /// What the window has to say: its close gadget, which ends the input
    /// as Ctrl-\ does. Whether anything came.
    fn windowClosed(io: *DeviceIo) bool {
        const port = io.user_port orelse return false;
        var closed = false;
        while (io.sys.GetMsg(port)) |msg| {
            const im: *wn.IntuiMessage = @ptrCast(@alignCast(msg));
            if (im.class & wn.IDCMP_CLOSEWINDOW != 0) closed = true;
            io.sys.ReplyMsg(msg);
        }
        return closed;
    }

    fn startTimer(io: *DeviceIo, slot: usize, micros: u64) bool {
        if (!io.timer_open) {
            io.timers[0] = .{ .node = .{ .message = .{ .reply_port = io.port, .length = @sizeOf(timer.TimeRequest) } } };
            if (io.sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &io.timers[0].node, 0) != 0) return false;
            for (io.timers[1..]) |*t| t.* = io.timers[0];
            io.timer_open = true;
        }
        const t = &io.timers[slot];
        t.node.command = timer.TR_ADDREQUEST;
        t.time = .{ .secs = @intCast(micros / 1_000_000), .micro = @intCast(micros % 1_000_000) };
        io.sys.SendIO(&t.node);
        io.timer_busy[slot] = true;
        return true;
    }

    fn stopTimer(io: *DeviceIo, slot: usize) void {
        if (!io.timer_busy[slot]) return;
        _ = io.sys.AbortIO(&io.timers[slot].node);
        _ = io.sys.WaitIO(&io.timers[slot].node);
        io.timer_busy[slot] = false;
    }
};

const State = struct {
    io: DeviceIo,
    handler: Handler(DeviceIo),
};

/// The handler process: STARTUP (dp_Arg1 the name opened, dp_Arg2 what the
/// node says this console is), then packets, characters and timers.
///
/// A console in a window serves the one Open that started it and ends when
/// that Open closes, which is how the name can say where the window goes
/// and how two Opens are two windows; a console on a serial port claims
/// its node and stays, since there is one such port and everything shares
/// it.
pub fn conHandler(sb: *ExecBase) callconv(.c) void {
    const lib = sb.OpenLibrary(dos.DOSNAME, 0) orelse return;
    const dl: *DosBase = @ptrCast(lib);
    const startup = dl.WaitPkt() orelse return;
    if (startup.getAction() != .startup) {
        dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_ACTION_NOT_KNOWN);
        return;
    }
    const me: *Process = @fieldParentPtr("task", sb.FindTask(null).?);
    // dp_Arg2: 0 a window, 1 a window in raw mode, anything else the
    // startup of a console on an exec device, which is always cooked.
    const what = startup.args.raw[1];
    const on_device: ?*const dos.FileSysStartupMsg = if (what == 0 or what == 1) null else @ptrFromInt(@as(usize, @bitCast(what)));
    const raw = what == 1;
    const name: ?[*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(startup.args.raw[0])));
    const port = sb.CreateMsgPort() orelse return dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_NO_FREE_STORE);
    const block = sb.AllocVec(@sizeOf(State), exec.MEMF_CLEAR) orelse {
        sb.DeleteMsgPort(port);
        return dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_NO_FREE_STORE);
    };
    const st: *State = @ptrCast(@alignCast(block));
    st.io = .{ .sys = sb, .dl = dl, .port = port, .startup = on_device };
    if (on_device == null) st.io.spec = window.parse(name orelse "CON:");
    st.handler = Handler(DeviceIo).init(&st.io, raw);
    st.handler.auto_open = st.io.inWindow() and st.io.spec.auto;
    // A console on a port is the node's from now on, so every later Open
    // of that name comes here; a window's console claims nothing, and dos
    // starts another process for the next name asked of it.
    const node: ?*dos.DosList = @ptrFromInt(@as(usize, @bitCast(startup.args.raw[2])));
    if (!st.io.inWindow()) {
        if (node) |n| n.task = &me.msg_port;
    }
    dl.ReplyPkt(startup, dos.DOSTRUE, 0);

    const h = &st.handler;
    while (true) {
        // What is done is taken first; Wait follows a round without any.
        var any = false;
        while (sb.GetMsg(&me.msg_port)) |msg| {
            any = true;
            h.packet(DosPacket.fromMessage(msg));
        }
        if (st.io.windowClosed()) {
            any = true;
            h.input(editor.END_OF_INPUT);
        }
        for (&st.io.units) |*u| {
            if (!u.open or sb.CheckIO(&u.read.io_ser.req) == null) continue;
            any = true;
            const got = sb.WaitIO(&u.read.io_ser.req) == 0 and u.read.io_ser.actual == 1;
            const c = u.byte;
            st.io.readNext(u);
            if (got) h.input(c);
        }
        for (0..max_waits) |slot| {
            if (!st.io.timer_busy[slot] or sb.CheckIO(&st.io.timers[slot].node) == null) continue;
            any = true;
            _ = sb.WaitIO(&st.io.timers[slot].node);
            st.io.timer_busy[slot] = false;
            h.timerDone(slot);
        }
        // Nothing else happened this round, so a character of the text
        // handed to this console goes in. One per round, and only when the
        // port is quiet, so it arrives at the speed of typing and never
        // holds up a program that is talking to the console.
        if (!any and h.pushOne()) any = true;
        // A window kept standing by WAIT goes when the input ends: Ctrl-\
        // typed into it, or its close gadget, which says the same thing.
        // Until then it stands there with what was written on it.
        if (st.io.waitPending() and h.ed.eof) {
            st.io.key_seen = true;
            st.io.close();
        }
        // A window's console is one Open's: when that Open has closed, and
        // nothing is keeping the window up, this process is done. A console
        // on a port is the node's, and the node keeps its port, so that one
        // stays however often it is opened and closed - it must, or the
        // next name asked of it would reach a process that is gone.
        if (st.io.inWindow() and st.io.finished and !st.io.waitPending() and h.held_count == 0) break;
        if (!any) {
            const window_bits = if (st.io.user_port) |p| p.sigMask() else 0;
            _ = sb.Wait(me.msg_port.sigMask() | port.sigMask() | window_bits);
        }
    }
    if (st.io.timer_open) {
        for (0..max_waits) |slot| st.io.stopTimer(slot);
        sb.CloseDevice(&st.io.timers[0].node);
    }
    sb.FreeVec(block);
    sb.DeleteMsgPort(port);
    sb.CloseLibrary(lib);
}

export const con_handler_tag: exec.ResidentHandler linksection(".resident") = .{
    .resident = .{
        .match_tag = &con_handler_tag.resident,
        .version = HANDLER_VERSION,
        .type = .handler,
        .pri = -121,
        .name = HANDLER_NAME,
        .id_string = HANDLER_VERSION_STRING[1..], // past the NUL: a C string
    },
    .handler = &conHandler,
};

// --- For the tests ----------------------------------------------------------

/// Handler's Io without devices: the terminal's bytes collected, replies
/// put into the packets and counted, signals, opens and timers noted.
pub const TestIo = struct {
    out: [4096]u8 = undefined,
    out_len: usize = 0,
    replies: usize = 0,
    last: ?*DosPacket = null,
    signalled: u32 = 0,
    signal_port: ?*MsgPort = null,
    opened: u32 = 0,
    closed: u32 = 0,
    timers: [max_waits]bool = @splat(false),

    pub fn sinkWrite(ctx: *anyopaque, bytes: []const u8) void {
        const io: *TestIo = @ptrCast(@alignCast(ctx));
        const n = @min(bytes.len, io.out.len - io.out_len);
        @memcpy(io.out[io.out_len..][0..n], bytes[0..n]);
        io.out_len += n;
    }
    pub fn reply(io: *TestIo, pkt: *DosPacket, res1: isize, res2: i32) void {
        pkt.res1 = res1;
        pkt.res2 = res2;
        io.replies += 1;
        io.last = pkt;
    }
    pub fn signal(io: *TestIo, port: *MsgPort, bits: u32) void {
        io.signal_port = port;
        io.signalled |= bits;
    }
    pub fn open(io: *TestIo) bool {
        io.opened += 1;
        return true;
    }
    pub fn close(io: *TestIo) void {
        io.closed += 1;
    }
    pub fn startTimer(io: *TestIo, slot: usize, micros: u64) bool {
        _ = micros;
        io.timers[slot] = true;
        return true;
    }
    pub fn stopTimer(io: *TestIo, slot: usize) void {
        io.timers[slot] = false;
    }
    pub fn text(io: *const TestIo) []const u8 {
        return io.out[0..io.out_len];
    }
    pub fn clear(io: *TestIo) void {
        io.out_len = 0;
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

fn newEditor(io: *TestIo) Editor {
    return .{ .sink = .{ .ctx = io, .write = &TestIo.sinkWrite } };
}

fn keys(ed: *Editor, text: []const u8) void {
    for (text) |c| ed.key(c);
    ed.flush();
}

/// The next line a READ gets.
fn nextLine(ed: *Editor, buffer: []u8) []const u8 {
    return buffer[0..ed.read(buffer)];
}

test "the ROM tag: a handler's, which InitCode and InitResident leave alone" {
    const tag = &con_handler_tag;
    try testing.expectEqual(&tag.resident, tag.resident.match_tag);
    try testing.expectEqual(exec.NodeType.handler, tag.resident.type);
    try testing.expectEqual(@as(u8, 0), tag.resident.flags);
    try testing.expect(tag.resident.init == null);
    try testing.expectEqualStrings(HANDLER_NAME, std.mem.span(tag.resident.name));
}

test "typing, cursor keys and Enter: the echo and the line" {
    var io: TestIo = .{};
    var ed = newEditor(&io);
    keys(&ed, "ab\x1b[DX\r");
    try testing.expectEqualStrings("ab\x1b[1DXb\x1b[1D\x1b[1C\r\n", io.text());
    var buffer: [16]u8 = undefined;
    try testing.expect(ed.readable());
    try testing.expectEqualStrings("aXb\n", nextLine(&ed, &buffer));
    try testing.expect(!ed.readable());

    keys(&ed, "a\r\nb\n"); // CR LF counts once
    try testing.expectEqual(@as(usize, 2), ed.lines);
    try testing.expectEqualStrings("a\n", nextLine(&ed, &buffer));
    try testing.expectEqualStrings("b\n", nextLine(&ed, &buffer));
    keys(&ed, "hello\r");
    try testing.expectEqualStrings("hel", nextLine(&ed, buffer[0..3])); // the rest stays
    try testing.expectEqualStrings("lo\n", nextLine(&ed, &buffer));
}

test "editing keys: ^W ^A ^K ^Y, Delete, ^Z BS, ^U, ^X, Home/End, 0x9B" {
    var io: TestIo = .{};
    var ed = newEditor(&io);
    var buffer: [64]u8 = undefined;
    keys(&ed, "hello world\x17"); // ^W: "hello "
    keys(&ed, "\x01\x0b"); // ^A ^K: all into the kill buffer
    keys(&ed, "\x19x"); // ^Y, then x: "hello x"
    keys(&ed, "\x01\x1b[3~"); // start, Delete: "ello x"
    keys(&ed, "\x1a\x7f\r"); // ^Z, Backspace (0x7F): "ello "
    try testing.expectEqualStrings("ello \n", nextLine(&ed, &buffer));
    keys(&ed, "abc\x1b[D\x15\r"); // ^U: to the start
    try testing.expectEqualStrings("c\n", nextLine(&ed, &buffer));
    keys(&ed, "abc\x18def\r"); // ^X
    try testing.expectEqualStrings("def\n", nextLine(&ed, &buffer));
    keys(&ed, "bc\x1b[HA\x1b[FD\r"); // Home, End
    try testing.expectEqualStrings("AbcD\n", nextLine(&ed, &buffer));
    keys(&ed, "xy\x9bDz\x9b1~0\r"); // the 0x9B CSI: left; Home as 1~
    try testing.expectEqualStrings("0xzy\n", nextLine(&ed, &buffer));
    keys(&ed, "\x07\x09ok\r"); // other control characters are dropped
    try testing.expectEqualStrings("ok\n", nextLine(&ed, &buffer));
}

test "history: up and down, no duplicates, ^R search by prefix" {
    var io: TestIo = .{};
    var ed = newEditor(&io);
    var buffer: [64]u8 = undefined;
    keys(&ed, "one\rtwo\rtwo\r");
    for (0..3) |_| _ = nextLine(&ed, &buffer);
    keys(&ed, "\x1b[A\x1b[A\x1b[A\r"); // two, one, then nothing older
    try testing.expectEqualStrings("one\n", nextLine(&ed, &buffer));
    keys(&ed, "\x1b[A\x1b[A\x1b[B\r"); // one (the recalled line is the newest now), two, down: one
    try testing.expectEqualStrings("one\n", nextLine(&ed, &buffer));
    keys(&ed, "\x1b[A\x1b[Bx\r"); // down past the newest: empty
    try testing.expectEqualStrings("x\n", nextLine(&ed, &buffer));
    keys(&ed, "O\x12\r"); // ^R: "o", any case
    try testing.expectEqualStrings("one\n", nextLine(&ed, &buffer));
    keys(&ed, "t\x12\x12\r"); // "two", then no older "t...": stays
    try testing.expectEqualStrings("two\n", nextLine(&ed, &buffer));

    var small: editor.History = .{};
    var long: [700]u8 = @splat('a');
    for (0..4) |i| {
        long[0] = @intCast('0' + i);
        small.add(&long);
    }
    try testing.expectEqual(@as(u8, '3'), small.entry(0).?[0]); // the oldest dropped
    try testing.expect(small.entry(1) != null and small.entry(2) == null); // two 701-byte lines fit
}

test "Ctrl-\\ ends the input; breaks; raw mode" {
    var io: TestIo = .{};
    var ed = newEditor(&io);
    var buffer: [64]u8 = undefined;
    keys(&ed, "abc\x1c");
    try testing.expect(ed.readable());
    try testing.expectEqualStrings("abc", nextLine(&ed, &buffer)); // without a LF
    try testing.expect(ed.readable());
    try testing.expectEqual(@as(usize, 0), ed.read(&buffer)); // the end
    try testing.expect(!ed.readable());

    keys(&ed, "a\x03b\x06\r"); // Ctrl-C and Ctrl-F: signals, not input
    try testing.expectEqual(exec.SIGBREAKF_CTRL_C | exec.SIGBREAKF_CTRL_F, ed.breaks);
    try testing.expectEqualStrings("ab\n", nextLine(&ed, &buffer));

    ed.breaks = 0;
    keys(&ed, "pa");
    io.clear();
    ed.setRaw(true); // what was typed goes to the reader
    keys(&ed, "q\n\x03\x1b");
    try testing.expectEqualStrings("", io.text()); // no echo
    try testing.expectEqual(exec.SIGBREAKF_CTRL_C, ed.breaks);
    try testing.expectEqualStrings("paq\n\x03\x1b", nextLine(&ed, &buffer)); // past the LF
}

test "output: LF as CR LF; the prompt and a typed line set aside and redrawn" {
    var io: TestIo = .{};
    var ed = newEditor(&io);
    ed.write("x\ny");
    ed.flush();
    try testing.expectEqualStrings("x\r\ny", io.text());
    io.clear();
    keys(&ed, "ab\x1b[D");
    io.clear();
    ed.write("hi\n");
    ed.flush();
    // The line on the screen was "yab": the "y" left over from the write
    // above is the prompt, and it comes back with the typed line.
    try testing.expectEqualStrings("\r\x1b[Khi\r\nyab\x1b[1D", io.text());
    io.clear();
    ed.write("no newline");
    ed.flush();
    try testing.expectEqualStrings("\r\x1b[Kno newline\r\nyab\x1b[1D", io.text());
    ed.setRaw(true);
    io.clear();
    ed.write("r\n");
    ed.flush();
    try testing.expectEqualStrings("r\n", io.text()); // raw: as it is
}

test "output: a prompt nobody has typed into comes back when a READ waits" {
    var io: TestIo = .{};
    var ed = newEditor(&io);
    ed.write("1.System:> ");
    ed.flush();
    io.clear();

    // Nothing waiting: the write just goes out, as any output does.
    ed.write("background\n");
    ed.flush();
    try testing.expectEqualStrings("background\r\n", io.text());

    // A READ is waiting, so the prompt is what the cursor sits on and it
    // has to come back under whatever is written - otherwise the console
    // looks stuck with no prompt in sight.
    io.clear();
    ed.prompt_len = 0;
    ed.write("1.System:> ");
    ed.flush();
    io.clear();
    ed.waiting = true;
    ed.write("[CLI 2] output\n");
    ed.flush();
    try testing.expectEqualStrings("\r\x1b[K[CLI 2] output\r\n1.System:> ", io.text());
}

test "the handler: opens, pending READs, partial lines, END" {
    var io: TestIo = .{};
    var h = Handler(TestIo).init(&io, false);
    var fh: dos.FileHandle = .{};
    var other: dos.FileHandle = .{};
    var reader_port: MsgPort = .{};

    var find = DosPacket.init(.findinput, .{ .find = .{ .fh = &fh, .lock = null, .name = "CON:" } });
    h.packet(&find);
    try testing.expectEqual(dos.DOSTRUE, find.res1);
    try testing.expect(fh.interactive);
    var find2 = DosPacket.init(.findoutput, .{ .find = .{ .fh = &other, .lock = null, .name = "*" } });
    h.packet(&find2);
    try testing.expectEqual(@as(u32, 1), io.opened); // the devices once
    try testing.expectEqual(@as(u32, 2), h.opens);

    var buffer: [3]u8 = undefined;
    var read = DosPacket.init(.read, .{ .io = .{ .fh = &fh, .buffer = &buffer, .length = 3 } });
    read.port = &reader_port;
    const before = io.replies;
    h.packet(&read);
    try testing.expectEqual(before, io.replies); // waits for a line
    for ("hello\r") |c| h.input(c);
    try testing.expectEqual(@as(isize, 3), read.res1);
    try testing.expectEqualStrings("hel", &buffer);
    h.packet(&read);
    try testing.expectEqual(@as(isize, 3), read.res1); // the rest at once
    try testing.expectEqualStrings("lo\n", &buffer);

    // The banner goes out before the node's first write, and only then.
    var write = DosPacket.init(.write, .{ .io = .{ .fh = &other, .buffer = @constCast("ok\n"), .length = 3 } });
    io.clear();
    h.packet(&write);
    try testing.expectEqual(@as(isize, 3), write.res1);
    try testing.expectEqualStrings(banner_on_screen ++ "ok\r\n", io.text());
    io.clear();
    h.packet(&write);
    try testing.expectEqualStrings("ok\r\n", io.text());

    read.res1 = 99;
    h.packet(&read); // waits
    var end = DosPacket.init(.end, .{ .file = .{ .fh = &fh } });
    h.packet(&end);
    try testing.expectEqual(@as(isize, 0), read.res1); // its READ ended
    try testing.expectEqual(@as(u32, 0), io.closed);
    var end2 = DosPacket.init(.end, .{ .file = .{ .fh = &other } });
    h.packet(&end2);
    try testing.expectEqual(@as(u32, 1), io.closed); // the last: devices closed
}

test "the handler: WAIT_CHAR, SCREEN_MODE, breaks, CHANGE_SIGNAL, DISK_INFO, the rest" {
    var io: TestIo = .{};
    var h = Handler(TestIo).init(&io, true); // RAW:
    var fh: dos.FileHandle = .{};
    var find = DosPacket.init(.findinput, .{ .find = .{ .fh = &fh, .lock = null, .name = "RAW:" } });
    h.packet(&find);
    try testing.expect(h.ed.raw);

    var wait = DosPacket.init(.wait_char, .{ .wait = .{ .timeout = 0 } });
    h.packet(&wait);
    try testing.expectEqual(dos.DOSFALSE, wait.res1);
    wait = DosPacket.init(.wait_char, .{ .wait = .{ .timeout = 1000 } });
    wait.res1 = 99;
    h.packet(&wait);
    try testing.expect(io.timers[0] and wait.res1 == 99); // waits
    h.input('x');
    try testing.expectEqual(dos.DOSTRUE, wait.res1);
    try testing.expect(!io.timers[0]); // its timer stopped
    var buffer: [8]u8 = undefined;
    var read = DosPacket.init(.read, .{ .io = .{ .fh = &fh, .buffer = &buffer, .length = 8 } });
    var reader_port: MsgPort = .{};
    read.port = &reader_port;
    h.packet(&read);
    try testing.expectEqual(@as(isize, 1), read.res1); // raw: a byte is enough
    wait.res1 = 99;
    h.packet(&wait);
    h.timerDone(0);
    try testing.expectEqual(dos.DOSFALSE, wait.res1); // the time is up

    h.input(3); // Ctrl-C to the last reader
    try testing.expectEqual(exec.SIGBREAKF_CTRL_C, io.signalled);
    try testing.expectEqual(@as(?*MsgPort, &reader_port), io.signal_port);
    var other_port: MsgPort = .{};
    var change = DosPacket.init(.change_signal, .{ .raw = .{ 0, asArg(&other_port), 0, 0, 0, 0, 0 } });
    h.packet(&change);
    try testing.expectEqual(asArg(&reader_port), change.args.raw[2]); // the old one
    h.input(4);
    try testing.expectEqual(@as(?*MsgPort, &other_port), io.signal_port);

    var mode = DosPacket.init(.screen_mode, .{ .screen_mode = .{ .mode = 0 } });
    h.packet(&mode);
    try testing.expect(!h.ed.raw);
    var info: dos.InfoData = .{};
    var disk = DosPacket.init(.disk_info, .{ .raw = .{ asArg(&info), 0, 0, 0, 0, 0, 0 } });
    h.packet(&disk);
    try testing.expectEqual(dos.ID_CON, info.disk_type);
    try testing.expectEqual(@as(i32, 1), info.in_use);
    var seek = DosPacket.init(.seek, .{ .raw = @splat(0) });
    h.packet(&seek);
    try testing.expectEqual(dos.ERROR_ACTION_NOT_KNOWN, seek.res2);
    var fs = DosPacket.init(.is_filesystem, .{ .raw = @splat(0) });
    h.packet(&fs);
    try testing.expectEqual(Answer{ .res1 = dos.DOSFALSE, .res2 = 0 }, Answer{ .res1 = fs.res1, .res2 = fs.res2 });
}

const Answer = struct { res1: isize, res2: i32 };

test {
    _ = window;
}

test "Ctrl-S holds what is written; the next character lets it go" {
    var io: TestIo = .{};
    var h = Handler(TestIo).init(&io, false);
    var fh: dos.FileHandle = .{};
    var find = DosPacket.init(.findinput, .{ .find = .{ .fh = &fh, .lock = null, .name = "CON:" } });
    h.packet(&find);
    var first = DosPacket.init(.write, .{ .io = .{ .fh = &fh, .buffer = @constCast("x\n"), .length = 2 } });
    h.packet(&first); // the banner, out of the way
    io.clear();

    h.input(0x13); // Ctrl-S
    try testing.expect(h.ed.hold);
    try testing.expectEqual(@as(usize, 0), io.text().len); // and not echoed
    var one = DosPacket.init(.write, .{ .io = .{ .fh = &fh, .buffer = @constCast("one\n"), .length = 4 } });
    var two = DosPacket.init(.write, .{ .io = .{ .fh = &fh, .buffer = @constCast("two\n"), .length = 4 } });
    one.res1 = 99;
    two.res1 = 99;
    h.packet(&one);
    h.packet(&two);
    try testing.expectEqual(@as(usize, 2), h.held_count);
    try testing.expectEqual(@as(usize, 0), io.text().len); // nothing on the terminal
    try testing.expectEqual(@as(isize, 99), one.res1); // and nobody answered

    h.input('a'); // any character at all
    try testing.expect(!h.ed.hold);
    try testing.expectEqual(@as(usize, 0), h.held_count);
    try testing.expectEqual(@as(isize, 4), one.res1);
    try testing.expectEqual(@as(isize, 4), two.res1);
    const text = io.text();
    try testing.expect(std.mem.indexOf(u8, text, "one").? < std.mem.indexOf(u8, text, "two").?);

    // Ctrl-Q is a character like another: it lets the output go and is not
    // typed into the line.
    h.input(0x13);
    try testing.expect(h.ed.hold);
    h.input(0x11);
    try testing.expect(!h.ed.hold);
    h.input('\r');
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("a\n", nextLine(&h.ed, &buffer)); // only the 'a'

    // Raw mode has no hold: Ctrl-S is a byte the reader gets.
    h.ed.setRaw(true);
    h.input(0x13);
    try testing.expect(!h.ed.hold);
    try testing.expectEqualStrings("\x13", nextLine(&h.ed, &buffer));
}

test "the hold: a full queue lets the oldest out, and END answers what waits" {
    var io: TestIo = .{};
    var h = Handler(TestIo).init(&io, false);
    var fh: dos.FileHandle = .{};
    var find = DosPacket.init(.findinput, .{ .find = .{ .fh = &fh, .lock = null, .name = "CON:" } });
    h.packet(&find);
    h.banner_done = true;
    h.input(0x13);

    var packets: [max_held + 1]DosPacket = undefined;
    for (&packets, 0..) |*pkt, i| {
        _ = i;
        pkt.* = DosPacket.init(.write, .{ .io = .{ .fh = &fh, .buffer = @constCast("ab"), .length = 2 } });
        pkt.res1 = 99;
        h.packet(pkt);
    }
    // The queue is full, so the one that waited longest went out.
    try testing.expectEqual(@as(usize, max_held), h.held_count);
    try testing.expectEqual(@as(isize, 2), packets[0].res1);
    try testing.expectEqual(@as(isize, 99), packets[1].res1);

    // The handle closes while the output is still held: what it wrote goes
    // out anyway, or its writers would wait for ever.
    var end = DosPacket.init(.end, .{ .file = .{ .fh = &fh } });
    h.packet(&end);
    try testing.expectEqual(@as(usize, 0), h.held_count);
    try testing.expectEqual(@as(isize, 2), packets[max_held].res1);
    try testing.expectEqual(@as(u32, 1), io.closed);
}

test "text handed to a console is typed into it: QUEUE, STACK, FORCE, DROP" {
    var io: TestIo = .{};
    var h = Handler(TestIo).init(&io, false);
    var fh: dos.FileHandle = .{};
    var find = DosPacket.init(.findinput, .{ .find = .{ .fh = &fh, .lock = null, .name = "CON:" } });
    h.packet(&find);
    io.clear();
    var buffer: [32]u8 = undefined;

    var q = DosPacket.init(.queue, .{ .io = .{ .fh = null, .buffer = @constCast("second\n"), .length = 7 } });
    h.packet(&q);
    try testing.expectEqual(@as(isize, 7), q.res1);
    var st = DosPacket.init(.stack, .{ .io = .{ .fh = null, .buffer = @constCast("first\n"), .length = 6 } });
    h.packet(&st);
    try testing.expect(h.ed.pushedIn());
    try testing.expect(!h.ed.readable()); // nothing is typed yet

    while (h.pushOne()) {}
    try testing.expectEqualStrings("first\n", nextLine(&h.ed, &buffer));
    try testing.expectEqualStrings("second\n", nextLine(&h.ed, &buffer));
    // It went in as typing does, so it is on the terminal as well.
    try testing.expect(std.mem.indexOf(u8, io.text(), "first") != null);

    // DROP throws away what has not been typed yet.
    var f = DosPacket.init(.force, .{ .io = .{ .fh = null, .buffer = @constCast("gone\n"), .length = 5 } });
    h.packet(&f);
    try testing.expectEqual(@as(isize, 5), f.res1);
    var drop = DosPacket.init(.drop, .{ .raw = @splat(0) });
    h.packet(&drop);
    try testing.expectEqual(dos.DOSTRUE, drop.res1);
    try testing.expect(!h.pushOne());
    try testing.expect(!h.ed.readable());

    // Nothing to push, and more than there is room for: nothing is taken.
    var empty = DosPacket.init(.queue, .{ .io = .{ .fh = null, .buffer = @constCast("x"), .length = 0 } });
    h.packet(&empty);
    try testing.expectEqual(@as(isize, -1), empty.res1);
    var huge = DosPacket.init(.queue, .{ .io = .{ .fh = null, .buffer = @constCast("x"), .length = 4096 } });
    h.packet(&huge);
    try testing.expectEqual(@as(isize, -1), huge.res1);
    try testing.expect(!h.ed.pushedIn());
}

test "pushed text: it waits behind a full line, a break ends it, WAIT_CHAR counts it" {
    var io: TestIo = .{};
    var h = Handler(TestIo).init(&io, false);
    var fh: dos.FileHandle = .{};
    var find = DosPacket.init(.findinput, .{ .find = .{ .fh = &fh, .lock = null, .name = "CON:" } });
    h.packet(&find);
    io.clear();

    // A line somebody is halfway through typing is not disturbed: the text
    // goes in at the cursor, as if it were typed there.
    for ("xy") |c| h.input(c);
    h.input(0x01); // ^A: to the start
    var one = DosPacket.init(.stack, .{ .io = .{ .fh = null, .buffer = @constCast("Z"), .length = 1 } });
    h.packet(&one);
    while (h.pushOne()) {}
    h.input('\r');
    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings("Zxy\n", nextLine(&h.ed, &buffer));

    // WAIT_CHAR counts text that is about to be typed as a line of its own.
    var pending = DosPacket.init(.queue, .{ .io = .{ .fh = null, .buffer = @constCast("a\n"), .length = 2 } });
    h.packet(&pending);
    for ("typed\r") |c| h.input(c);
    var wait = DosPacket.init(.wait_char, .{ .wait = .{ .timeout = 0 } });
    h.packet(&wait);
    try testing.expectEqual(dos.DOSTRUE, wait.res1);
    try testing.expectEqual(@as(i32, 2), wait.res2); // the typed line, and the one waiting
    try testing.expectEqualStrings("typed\n", nextLine(&h.ed, &buffer));

    // A break ends it, and takes what it had already typed with it.
    var more = DosPacket.init(.force, .{ .io = .{ .fh = null, .buffer = @constCast("no\n"), .length = 3 } });
    h.packet(&more);
    _ = h.pushOne();
    h.input(3); // Ctrl-C
    try testing.expect(!h.ed.pushedIn());
    try testing.expectEqual(@as(usize, 0), h.ed.len);

    // A line with no end to it fills up and the rest waits, rather than
    // being thrown away.
    var long: [400]u8 = @splat('u');
    var big = DosPacket.init(.queue, .{ .io = .{ .fh = null, .buffer = &long, .length = 400 } });
    h.packet(&big);
    try testing.expectEqual(@as(isize, 400), big.res1);
    while (h.pushOne()) {}
    try testing.expect(h.ed.pushedIn()); // it waits for room
    h.input(0x18); // ^X clears the line
    try testing.expect(h.pushOne()); // and it carries on
}
