// SPDX-License-Identifier: MPL-2.0
//! The kernel's shell, `s3>`: the task code the boot task becomes once the
//! residents have run, talking to the user on serial.device's unit 0
//! (UART0) or usbserial.device (USB-Serial-JTAG), whichever the board names
//! as its console, with CMD_READ and CMD_WRITE.
//!
//! What it holds is what a kernel needs to look at itself, and what has to
//! work before there is a disk to load a command from: the lists exec and
//! dos keep, the hardware (timer, watchdog, caches, DMA, the panel, the
//! flash disk and its RigidDiskBlock), and the ways to make the machine
//! fail on purpose. Anything a program can do it does not do: `newshell`
//! starts the real shell, and the commands in C: take it from there.
//!
//! This file is the loop: the console, the line being typed, the command
//! list and what several commands share. Each command is a file of its
//! own in `cmds/`, which says its name, its usage and its lines of `help`
//! beside `run`, which gets the shell's state and the rest of the line.
//!
//! The state is one `Shell` block, allocated in internal memory when the
//! shell starts - interrupt code reads parts of it - and handed to every
//! command. The interrupts and the trap code a command installs find it
//! through their data pointer. Every call to exec goes through its jump
//! table; exec's lists are read straight from its base.

const sdk = @import("sdk");
const exec = @import("../exec.zig");
const serial = sdk.devices.serial;
const usbserial = sdk.devices.usbserial;
const timer = sdk.devices.timer;
const st = sdk.expansion.systemtags;
const ExecBase = exec.ExecBase;
const Interrupt = sdk.exec.Interrupt;
const Node = sdk.exec.Node;
const MsgPort = sdk.exec.MsgPort;
const IOStdReq = sdk.exec.IOStdReq;

/// A command line's words, split in place: each word is ended with a NUL,
/// so it can go to RawDoFmt's %s as it is.
pub const Args = struct {
    rest: [:0]u8,

    /// The next word, or null at the end of the line.
    pub fn next(args: *Args) ?[:0]const u8 {
        var start: usize = 0;
        while (start < args.rest.len and (args.rest[start] == ' ' or args.rest[start] == 0)) start += 1;
        if (start == args.rest.len) return null;
        var end = start;
        while (end < args.rest.len and args.rest[end] != ' ' and args.rest[end] != 0) end += 1;
        args.rest[end] = 0; // the line's own NUL for the last word
        const word = args.rest[start..end :0];
        args.rest = args.rest[@min(end + 1, args.rest.len)..];
        return word;
    }

    /// The next word without taking it.
    pub fn peek(args: *Args) ?[:0]const u8 {
        var copy = args.*;
        return copy.next();
    }

    /// The next word as a number: decimal, or hexadecimal after `0x`.
    pub fn number(args: *Args) !u32 {
        const word = args.next() orelse return error.Usage;
        return parseNumber(word) orelse error.Usage;
    }

    /// The next word as a number if there is one, else `default`.
    pub fn numberOr(args: *Args, default: u32) !u32 {
        return if (args.peek() != null) args.number() else default;
    }

    /// The next word as a signed decimal number.
    pub fn signed(args: *Args) !i32 {
        const word = args.next() orelse return error.Usage;
        if (word.len > 1 and word[0] == '-') {
            const magnitude = parseNumber(word[1..]) orelse return error.Usage;
            if (magnitude > 0x8000_0000) return error.Usage;
            return @intCast(-@as(i64, magnitude));
        }
        const value = parseNumber(word) orelse return error.Usage;
        if (value > 0x7FFF_FFFF) return error.Usage;
        return @intCast(value);
    }
};

/// `text` as a number: decimal, or hexadecimal after `0x`. Null for
/// anything else, or one that does not fit 32 bits.
pub fn parseNumber(text: []const u8) ?u32 {
    var digits = text;
    var radix: u64 = 10;
    if (digits.len > 2 and digits[0] == '0' and (digits[1] == 'x' or digits[1] == 'X')) {
        radix = 16;
        digits = digits[2..];
    }
    if (digits.len == 0) return null;
    var value: u64 = 0;
    for (digits) |c| {
        const digit: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        if (digit >= radix) return null;
        value = value * radix + digit;
        if (value > 0xFFFF_FFFF) return null;
    }
    return @intCast(value);
}

/// Whether two words are the same.
pub fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// A value of enum `E` by its name, "?" for one the enum does not name.
pub fn enumName(comptime E: type, value: E) [*:0]const u8 {
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (@intFromEnum(value) == field.value) return field.name;
    }
    return "?";
}

/// A node's name, "?" for one without.
pub fn nodeName(node: *const Node) [*:0]const u8 {
    return node.name orelse "?";
}

/// The commands, in the order `help` lists them. Each is a file in
/// `cmds/` that says what it is called, the usage it prints when its
/// words are wrong, and its lines of `help`, beside its `run`; the table
/// the loop looks a command up in and the whole of `help`'s text are made
/// from this list at compile time. `zig build test` fails when a file in
/// `cmds/` is missing from it (tools/shellcheck.zig).
const commands = .{
    @import("cmds/help.zig"),
    @import("cmds/info.zig"),
    @import("cmds/uptime.zig"),
    @import("cmds/memlist.zig"),
    @import("cmds/memtrace.zig"),
    @import("cmds/peek.zig"),
    @import("cmds/poke.zig"),
    @import("cmds/sleep.zig"),
    @import("cmds/libs.zig"),
    @import("cmds/devs.zig"),
    @import("cmds/constop.zig"),
    @import("cmds/ser.zig"),
    @import("cmds/residents.zig"),
    @import("cmds/resources.zig"),
    @import("cmds/tdelay.zig"),
    @import("cmds/tabort.zig"),
    @import("cmds/systime.zig"),
    @import("cmds/eclock.zig"),
    @import("cmds/date.zig"),
    @import("cmds/ints.zig"),
    @import("cmds/trigger.zig"),
    @import("cmds/cause.zig"),
    @import("cmds/alert.zig"),
    @import("cmds/trap.zig"),
    @import("cmds/tasks.zig"),
    @import("cmds/ports.zig"),
    @import("cmds/sems.zig"),
    @import("cmds/doslist.zig"),
    @import("cmds/segments.zig"),
    @import("cmds/clis.zig"),
    @import("cmds/newshell.zig"),
    @import("cmds/disk.zig"),
    @import("cmds/sd.zig"),
    @import("cmds/format.zig"),
    @import("cmds/rdb.zig"),
    @import("cmds/screen.zig"),
    @import("cmds/syscall.zig"),
    @import("cmds/fault.zig"),
    @import("cmds/panic.zig"),
    @import("cmds/wdt.zig"),
    @import("cmds/cache.zig"),
    @import("cmds/dma.zig"),
    @import("cmds/reboot.zig"),
};

/// A command, as the loop finds it by name.
const Command = struct {
    name: []const u8,
    usage: [:0]const u8,
    run: *const fn (*Shell, *Args) anyerror!void,
};

const table = made: {
    var entries: [commands.len]Command = undefined;
    for (commands, &entries) |command, *entry| {
        entry.* = .{ .name = command.name, .usage = command.usage, .run = command.run };
    }
    break :made entries;
};

/// Every command's lines of help, one after the other.
pub const help_text: [:0]const u8 = made: {
    var text: [:0]const u8 = "";
    for (commands) |command| text = text ++ command.help;
    break :made text;
};

/// The console: serial.device's unit 0 (UART0) or usbserial.device
/// (USB-Serial-JTAG), opened shared. Per unit a read request, always out
/// for one byte, and a write request (a copy of the opened one). All reply
/// to `con_port`.
pub const ConsoleUnit = struct {
    device: [*:0]const u8,
    unit: u32,
    read: serial.IOExtSer = .{},
    write: serial.IOExtSer = .{},
    input: u8 = 0,
    open: bool = false,
};

/// Everything the shell keeps, in one block: what it types into, its
/// console, and what the commands leave behind them - requests kept open,
/// the interrupts `trigger` and `cause` install, the traps `trap skip`
/// counts.
pub const Shell = struct {
    /// exec, as the task code got it.
    base: *ExecBase,

    /// The line being typed, and room for its NUL.
    line: [129]u8 = undefined,
    len: usize = 0,
    last_was_cr: bool = false,

    con_port: *MsgPort = undefined,
    con_units: [2]ConsoleUnit = .{
        .{ .device = serial.SERIALNAME, .unit = serial.UNIT_UART0 },
        .{ .device = usbserial.USBSERIALNAME, .unit = 0 },
    },
    /// What `print` has collected and not yet written.
    out: [256]u8 = undefined,
    out_len: usize = 0,

    /// flash.device's unit 0, opened at the first `disk` or `rdb` and kept:
    /// the device is the file system's too, so opening it shared costs
    /// nothing.
    disk_port: ?*MsgPort = null,
    disk_req: IOStdReq = .{},
    /// sd.device's unit 0, the same way.
    sd_port: ?*MsgPort = null,
    sd_req: IOStdReq = .{},

    /// The software interrupt `trigger`'s server defers its work to, and
    /// `cause` causes; how often it has run.
    softint: Interrupt = .{},
    softint_runs: u32 = 0,
    /// `trigger`'s server and handler, installed the first time it runs.
    trigger_server: Interrupt = .{},
    trigger_handler: Interrupt = .{},
    trigger_installed: bool = false,

    /// Exceptions `trap skip` has stepped over.
    skipped_traps: u32 = 0,

    /// The shell's output, formatted by exec's RawDoFmt (the format is
    /// checked against the values at compile time), to the console.
    pub fn print(shell: *Shell, comptime format: [:0]const u8, args: anytype) void {
        comptime sdk.exec.checkFormat(format, @TypeOf(args));
        const stream = sdk.exec.fmtStream(args);
        _ = shell.base.iface().RawDoFmt(format, &stream, &putConsole, shell);
    }
};

/// RawDoFmt's output function: collects the text, "\n" as "\r\n" (the
/// serial ports are raw), and writes it at the final NUL.
fn putConsole(c: u8, data: ?*anyopaque) callconv(.c) void {
    const shell: *Shell = @ptrCast(@alignCast(data.?));
    if (c == 0) {
        writeConsole(shell, shell.out[0..shell.out_len]);
        shell.out_len = 0;
        return;
    }
    if (c == '\n') bufferConsole(shell, '\r');
    bufferConsole(shell, c);
}

/// A character into the output; written when it is full.
fn bufferConsole(shell: *Shell, c: u8) void {
    if (shell.out_len == shell.out.len) {
        writeConsole(shell, shell.out[0..shell.out_len]);
        shell.out_len = 0;
    }
    shell.out[shell.out_len] = c;
    shell.out_len += 1;
}

/// CMD_WRITE on the console's units.
fn writeConsole(shell: *Shell, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const sys = shell.base.iface();
    for (&shell.con_units) |*u| {
        if (!u.open) continue;
        u.write.io_ser.req.command = sdk.exec.CMD_WRITE;
        u.write.io_ser.data = @constCast(bytes.ptr);
        u.write.io_ser.length = @intCast(bytes.len);
        _ = sys.DoIO(&u.write.io_ser.req);
    }
}

/// Open the console's unit, shared, with its read request, and copy that
/// for writing, as a program copies an opened request. The board says which
/// unit: the USB port on a board whose UART0 is the kernel's own output
/// and nothing else, UART0 where that is what the terminal shows.
fn openConsole(shell: *Shell) bool {
    const sys = shell.base.iface();
    shell.con_port = sys.CreateMsgPort() orelse return false;
    const uart = boardFact(shell, st.SYSTAG_Console, st.CONSOLE_UART0) == st.CONSOLE_UART0;
    var any = false;
    for (&shell.con_units, 0..) |*u, i| {
        // Entry 0 is UART0, entry 1 the USB port.
        if ((i == 0) != uart) continue;
        u.read = .{
            .io_ser = .{ .req = .{ .message = .{ .reply_port = shell.con_port, .length = @sizeOf(serial.IOExtSer) } } },
            .ser_flags = serial.SERF_SHARED,
        };
        u.open = sys.OpenDevice(u.device, u.unit, &u.read.io_ser.req, 0) == 0;
        u.write = u.read;
        any = any or u.open;
    }
    if (!any) sys.DeleteMsgPort(shell.con_port);
    return any;
}

/// Send a CMD_READ for the unit's next byte.
fn readConsole(shell: *Shell, u: *ConsoleUnit) void {
    u.read.io_ser.req.command = sdk.exec.CMD_READ;
    u.read.io_ser.data = &u.input;
    u.read.io_ser.length = 1;
    shell.base.iface().SendIO(&u.read.io_ser.req);
}

/// Take the console's read on `device`'s `unit` back, so that a command
/// gets the unit's input and SDCMD_SETPARAMS doesn't find it busy. The
/// console unit if its read was out: `resumeConsole` sends it again.
pub fn pauseConsole(shell: *Shell, device: [*:0]const u8, unit: u32) ?*ConsoleUnit {
    const sys = shell.base.iface();
    for (&shell.con_units) |*u| {
        if (!u.open or u.unit != unit or u.device != device) continue;
        if (sys.CheckIO(&u.read.io_ser.req) != null) return null;
        _ = sys.AbortIO(&u.read.io_ser.req);
        _ = sys.WaitIO(&u.read.io_ser.req);
        return u;
    }
    return null;
}

pub fn resumeConsole(shell: *Shell, paused: ?*ConsoleUnit) void {
    if (paused) |u| readConsole(shell, u);
}

/// The shell's task code (an exec.TaskFn). Without its console, or the
/// memory for its state, it ends.
pub fn run(sys: *sdk.exec.ExecBase) callconv(.c) void {
    const block = sys.AllocMem(@sizeOf(Shell), sdk.exec.MEMF_INTERNAL | sdk.exec.MEMF_CLEAR) orelse {
        sdk.exec.kprintf(sys, "shell: no memory\n", .{});
        return;
    };
    const shell: *Shell = @ptrCast(@alignCast(block));
    shell.* = .{ .base = @ptrCast(@alignCast(sys)) };
    shell.softint = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = "shell softint" },
        .data = shell,
        .code = sdk.exec.vec(countSoftInt),
    };
    if (!openConsole(shell)) {
        sdk.exec.kprintf(sys, "shell: can't open %s or %s\n", .{ serial.SERIALNAME, usbserial.USBSERIALNAME });
        sys.FreeMem(block, @sizeOf(Shell));
        return;
    }
    shell.print("Type 'help' for a list of commands.\n", .{});
    prompt(shell);
    for (&shell.con_units) |*u| {
        if (u.open) readConsole(shell, u);
    }
    while (true) {
        // What is done is taken first, and Wait only follows a round that
        // found nothing: a command's own WaitIO may have taken the port
        // signal of a reply that is waiting here.
        var any = false;
        for (&shell.con_units) |*u| {
            if (!u.open or sys.CheckIO(&u.read.io_ser.req) == null) continue;
            any = true;
            if (sys.WaitIO(&u.read.io_ser.req) == 0 and u.read.io_ser.actual == 1) input(shell, u.input);
            readConsole(shell, u);
        }
        if (any) continue;
        _ = sys.Wait(shell.con_port.sigMask());
    }
}

fn prompt(shell: *Shell) void {
    shell.print("s3> ", .{});
}

/// One character typed: kept, taken back, or the line run.
fn input(shell: *Shell, c: u8) void {
    defer shell.last_was_cr = c == '\r';
    switch (c) {
        '\r', '\n' => {
            if (c == '\n' and shell.last_was_cr) return;
            shell.print("\n", .{});
            shell.line[shell.len] = 0;
            execute(shell, shell.line[0..shell.len :0]);
            shell.len = 0;
            prompt(shell);
        },
        0x08, 0x7f => if (shell.len > 0) {
            shell.len -= 1;
            shell.print("\x08 \x08", .{});
        },
        0x03 => {
            shell.print("^C\n", .{});
            shell.len = 0;
            prompt(shell);
        },
        else => if (c >= 0x20 and c < 0x7f and shell.len < shell.line.len - 1) {
            shell.line[shell.len] = c;
            shell.len += 1;
            shell.print("%c", .{c});
        },
    }
}

/// The line's first word is the command, the rest its words.
fn execute(shell: *Shell, text: [:0]u8) void {
    var args: Args = .{ .rest = text };
    const name = args.next() orelse return;
    for (table) |command| {
        if (!same(command.name, name)) continue;
        command.run(shell, &args) catch |err| switch (err) {
            error.Usage => shell.print("usage: %s\n", .{command.usage}),
            else => shell.print("error: %s\n", .{@errorName(err)}),
        };
        return;
    }
    shell.print("unknown command '%s', try 'help'\n", .{name});
}

/// The software interrupt: counts its runs.
fn countSoftInt(data: ?*anyopaque) callconv(.c) void {
    const shell: *Shell = @ptrCast(@alignCast(data.?));
    shell.softint_runs +%= 1;
}

// --- the board ------------------------------------------------------------

/// A fact from the board's system tag list, through expansion.library;
/// `default` if the library or the fact is not there.
pub fn boardFact(shell: *Shell, tag: u32, default: usize) usize {
    return fact(shell, null, tag, default);
}

/// A fact of the board's first part of `kind`; `default` if there is no
/// such part or it does not say.
pub fn partFact(shell: *Shell, kind: u32, tag: u32, default: usize) usize {
    return fact(shell, kind, tag, default);
}

fn fact(shell: *Shell, kind: ?u32, tag: u32, default: usize) usize {
    const sys = shell.base.iface();
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return default;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return default;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const list = if (kind) |k|
        (eb.FindBoardPart(null, k, st.CHIP_ANY) orelse return default).tags
    else
        eb.SystemTags();
    return ub.GetTagData(tag, default, list);
}

// --- timer.device ---------------------------------------------------------

/// A timer.device request on `unit`, made with CreateIORequest for its own
/// reply port; `closeTimer` closes the device and frees both.
fn timerRequest(shell: *Shell, unit: u32) ?*timer.TimeRequest {
    const sys = shell.base.iface();
    const port = sys.CreateMsgPort() orelse return null;
    const io = sys.CreateIORequest(port, @sizeOf(timer.TimeRequest)) orelse {
        sys.DeleteMsgPort(port);
        return null;
    };
    if (sys.OpenDevice(timer.TIMERNAME, unit, io, 0) != 0) {
        sys.DeleteIORequest(io);
        sys.DeleteMsgPort(port);
        return null;
    }
    return @fieldParentPtr("node", io);
}

/// `timerRequest` for a command, which says when it fails.
pub fn openTimer(shell: *Shell, unit: u32) !*timer.TimeRequest {
    return timerRequest(shell, unit) orelse {
        shell.print("can't open %s unit %d\n", .{ timer.TIMERNAME, unit });
        return error.NoTimer;
    };
}

pub fn closeTimer(shell: *Shell, req: *timer.TimeRequest) void {
    const sys = shell.base.iface();
    const port = req.node.message.reply_port;
    sys.CloseDevice(&req.node);
    sys.DeleteIORequest(&req.node);
    sys.DeleteMsgPort(port);
}

/// Sleep `ms` milliseconds on timer.device; not at all if it will not
/// open.
pub fn sleepMs(shell: *Shell, ms: u32) void {
    const req = timerRequest(shell, timer.UNIT_MICROHZ) orelse return;
    defer closeTimer(shell, req);
    req.node.command = timer.TR_ADDREQUEST;
    req.time = timer.TimeVal.fromMicros(@as(u64, ms) * 1000);
    _ = shell.base.iface().DoIO(&req.node);
}

// --- dos.library ----------------------------------------------------------

/// dos.library through its jump table, or null (with a message). The
/// caller closes it.
pub fn openDos(shell: *Shell) ?*sdk.interface.dos.DosBase {
    const lib = shell.base.iface().OpenLibrary(sdk.dos.DOSNAME, 0) orelse {
        shell.print("can't open %s\n", .{sdk.dos.DOSNAME});
        return null;
    };
    return @ptrCast(lib);
}

// --- block devices --------------------------------------------------------

/// A block device's unit 0 on a request the shell keeps: opened the first
/// time, with its own reply port, and the same request every time after.
/// Opening it shared costs nothing - the device is the file system's too.
pub fn openBlockDevice(shell: *Shell, port: *?*MsgPort, request: *IOStdReq, name: [*:0]const u8) !*IOStdReq {
    if (request.req.device != null) return request;
    const sys = shell.base.iface();
    const reply = port.* orelse made: {
        const made = sys.CreateMsgPort() orelse return error.OutOfMemory;
        port.* = made;
        break :made made;
    };
    request.* = .{ .req = .{ .message = .{ .reply_port = reply, .length = @sizeOf(IOStdReq) } } };
    const err = sys.OpenDevice(name, 0, &request.req, 0);
    if (err != 0) {
        shell.print("OpenDevice %s unit 0: error %d\n", .{ name, err });
        return error.NotFound;
    }
    return request;
}

/// flash.device's unit 0, for `disk` and `rdb`.
pub fn openDisk(shell: *Shell) !*IOStdReq {
    return openBlockDevice(shell, &shell.disk_port, &shell.disk_req, sdk.devices.trackdisk.FLASHNAME);
}

/// One command to a block device; answers io_Error.
pub fn blockIO(shell: *Shell, io: *IOStdReq, command: u16, offset: u64, length: u64, data: ?*anyopaque) i8 {
    io.req.command = command;
    io.offset = offset;
    io.length = length;
    io.data = data;
    io.actual = 0;
    _ = shell.base.iface().DoIO(&io.req);
    return io.req.err;
}

/// Bytes as hexadecimal, sixteen to a line, each line starting with where
/// it is: `first` plus its offset into `bytes`.
pub fn dump(shell: *Shell, bytes: []const u8, first: u32) void {
    for (bytes, 0..) |b, i| {
        const at: u32 = @intCast(i);
        if (at % 16 == 0) shell.print("%s0x%08x:", .{ if (at == 0) "" else "\n", first + at });
        shell.print(" %02x", .{b});
    }
    shell.print("\n", .{});
}
