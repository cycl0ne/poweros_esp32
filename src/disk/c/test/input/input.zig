// SPDX-License-Identifier: MIT
//! Input: what goes down input.device's handler chain. Built against the
//! SDK only.
//!
//!   Input TIMER/S,KEY/K/N
//!
//! With nothing asked for it puts a handler on the chain and prints every
//! event that passes it - keys, fingers, the mouse, the pointer - until
//! Ctrl-C; TIMER
//! prints the ten-a-second ticks as well. KEY sends one rawkey down the
//! chain, pressed and let go, through IND_WRITEEVENT, and stops.
//!
//! The handler runs on input.device's task, where nothing may wait, so it
//! only copies each event into a ring and signals; the printing is done
//! here, on the program's own process. The handler is taken off with
//! IND_REMHANDLER before the program ends: once that request is back the
//! handler is not running and will never run again, so its code can go.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const input = sdk.devices.input;
const ie = sdk.devices.inputevent;
const touch = sdk.devices.touch;
const InputEvent = ie.InputEvent;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const KeymapBase = sdk.interface.keymap.KeymapBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Input";
const VERSION_STRING = "\x00$VER: Input 1.1 (22.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TIMER/S,KEY/K/N";
const arg_timer = 0;
const arg_key = 1;

/// Above where a windowing system sits, so it sees everything first.
const handler_pri = 60;
const ring_size = 64;

const MSG_NODEVICE = "No %s\n";
const MSG_WAITING = "Input events - Ctrl-C to stop\n";
const MSG_KEY = "key     %02x %-4s%s\n";
const MSG_KEY_TEXT = "key     %02x %-4s%s  \"%s\"\n";
const MSG_TOUCH = "finger  #%-2d %-4s %4d,%-4d%s\n";
const MSG_POINTER = "pointer %4d,%-4d %-14s%s\n";
const MSG_MOUSE = "mouse   %4d,%-4d %-14s%s\n";
const MSG_TIMER = "timer  %s\n";
const MSG_OTHER = "class %02x code %02x%s\n";
const MSG_LOST = "(%d events lost)\n";
const MSG_DONE = "%d events\n";
const MSG_SENT = "Sent rawkey %02x\n";

/// What the handler and the program share. The handler writes `head`, the
/// program `tail`.
const Ring = extern struct {
    sys: *ExecBase,
    task: *exec.Task,
    mask: u32,
    timer: u32,
    head: u32 = 0,
    tail: u32 = 0,
    lost: u32 = 0,
    events: [ring_size]InputEvent = undefined,
};

fn handler(events: ?*InputEvent, data: ?*anyopaque) callconv(.c) ?*InputEvent {
    const ring: *Ring = @ptrCast(@alignCast(data.?));
    const head: *volatile u32 = &ring.head;
    const tail: *volatile u32 = &ring.tail;
    var e = events;
    var any = false;
    while (e) |ev| : (e = ev.next) {
        if (ev.class == ie.IECLASS_TIMER and ring.timer == 0) continue;
        if (head.* -% tail.* >= ring_size) {
            ring.lost += 1;
            continue;
        }
        ring.events[head.* % ring_size] = ev.*;
        head.* +%= 1;
        any = true;
    }
    if (any) ring.sys.Signal(ring.task, ring.mask);
    return events;
}

const qualifier_names = [_]struct { bit: u32, name: [*:0]const u8 }{
    .{ .bit = ie.IEQUALIFIER_LSHIFT, .name = " lshift" },
    .{ .bit = ie.IEQUALIFIER_RSHIFT, .name = " rshift" },
    .{ .bit = ie.IEQUALIFIER_CAPSLOCK, .name = " caps" },
    .{ .bit = ie.IEQUALIFIER_CONTROL, .name = " ctrl" },
    .{ .bit = ie.IEQUALIFIER_LALT, .name = " lalt" },
    .{ .bit = ie.IEQUALIFIER_RALT, .name = " ralt" },
    .{ .bit = ie.IEQUALIFIER_LCOMMAND, .name = " lamiga" },
    .{ .bit = ie.IEQUALIFIER_RCOMMAND, .name = " ramiga" },
    .{ .bit = ie.IEQUALIFIER_NUMERICPAD, .name = " keypad" },
    .{ .bit = ie.IEQUALIFIER_REPEAT, .name = " repeat" },
    .{ .bit = ie.IEQUALIFIER_LEFTBUTTON, .name = " lbutton" },
    .{ .bit = ie.IEQUALIFIER_RBUTTON, .name = " rbutton" },
    .{ .bit = ie.IEQUALIFIER_MIDBUTTON, .name = " mbutton" },
};

fn qualifierText(q: u32, buf: *[128]u8) [*:0]const u8 {
    var n: usize = 0;
    for (qualifier_names) |qn| {
        if (q & qn.bit == 0) continue;
        var s = qn.name;
        while (s[0] != 0 and n < buf.len - 1) : (s += 1) {
            buf[n] = s[0];
            n += 1;
        }
    }
    buf[n] = 0;
    return @ptrCast(buf);
}

fn touchKind(kind: u32) [*:0]const u8 {
    return switch (kind) {
        touch.TOUCH_DOWN => "down",
        touch.TOUCH_MOVE => "move",
        touch.TOUCH_UP => "up",
        else => "?",
    };
}

/// What a pointer or mouse event's code says happened.
fn buttonText(code: u32) [*:0]const u8 {
    return switch (code) {
        ie.IECODE_LBUTTON => "press",
        ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX => "let go",
        ie.IECODE_RBUTTON => "right press",
        ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX => "right let go",
        ie.IECODE_MBUTTON => "middle press",
        ie.IECODE_MBUTTON | ie.IECODE_UP_PREFIX => "middle let go",
        else => "moved",
    };
}

fn show(dl: *DosBase, kb: ?*KeymapBase, e: *const InputEvent) void {
    var qbuf: [128]u8 = undefined;
    const q = qualifierText(e.qualifier, &qbuf);
    switch (e.class) {
        ie.IECLASS_RAWKEY => {
            const up = e.code & ie.IECODE_UP_PREFIX != 0;
            const dir: [*:0]const u8 = if (up) "up" else "down";
            // What it makes through the default keymap, CSI shown as such.
            var text: [16:0]u8 = @splat(0);
            const n = if (kb) |k| k.MapRawKey(e, &text, 15, null) else 0;
            if (n > 0) {
                var shown: [48:0]u8 = @splat(0);
                var at: usize = 0;
                for (text[0..@intCast(n)]) |c| {
                    const word: []const u8 = switch (c) {
                        0x9B => "CSI",
                        0x1B => "ESC",
                        '\r' => "\\r",
                        '\n' => "\\n",
                        '\t' => "\\t",
                        else => &[1]u8{c},
                    };
                    const printable = c >= 0x20 or word.len > 1;
                    const put = if (printable) word else "?";
                    for (put) |ch| {
                        if (at < shown.len) shown[at] = ch;
                        at += 1;
                    }
                }
                _ = Printf(dl, MSG_KEY_TEXT, .{ e.code & ie.IECODE_KEY_CODE_MASK, dir, q, @as([*:0]const u8, &shown) });
            } else {
                _ = Printf(dl, MSG_KEY, .{ e.code & ie.IECODE_KEY_CODE_MASK, dir, q });
            }
        },
        ie.IECLASS_TOUCH => _ = Printf(dl, MSG_TOUCH, .{ e.code, touchKind(e.subclass), e.x, e.y, q }),
        ie.IECLASS_NEWPOINTERPOS => _ = Printf(dl, MSG_POINTER, .{ e.x, e.y, buttonText(e.code), q }),
        ie.IECLASS_RAWMOUSE => _ = Printf(dl, MSG_MOUSE, .{ e.x, e.y, buttonText(e.code), q }),
        ie.IECLASS_TIMER => _ = Printf(dl, MSG_TIMER, .{q}),
        else => _ = Printf(dl, MSG_OTHER, .{ e.class, e.code, q }),
    }
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    var io: exec.IOStdReq = .{};
    io.req.message.reply_port = port;
    io.req.message.length = @sizeOf(exec.IOStdReq);
    if (sys.OpenDevice(input.INPUTNAME, 0, &io.req, 0) != 0) {
        _ = Printf(dl, MSG_NODEVICE, .{input.INPUTNAME});
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&io.req);

    if (argv[arg_key] != 0) {
        const code: u32 = @intCast(@as(*const i32, @ptrFromInt(argv[arg_key])).* & 0x7F);
        var e: InputEvent = undefined;
        for ([_]u32{ 0, ie.IECODE_UP_PREFIX }) |up| {
            e = .{ .class = ie.IECLASS_RAWKEY, .code = code | up };
            io.req.command = input.IND_WRITEEVENT;
            io.data = &e;
            io.length = @sizeOf(InputEvent);
            _ = sys.DoIO(&io.req);
        }
        _ = Printf(dl, MSG_SENT, .{code});
        return dos.RETURN_OK;
    }

    const signal = sys.AllocSignal(-1);
    if (signal < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(signal);
    var ring: Ring = .{
        .sys = sys,
        .task = sys.FindTask(null).?,
        .mask = @as(u32, 1) << @intCast(signal),
        .timer = @intFromBool(argv[arg_timer] != 0),
    };
    var int: exec.Interrupt = .{
        .node = .{ .type = .interrupt, .pri = handler_pri, .name = COMMAND_NAME },
        .data = &ring,
        .code = &handler,
    };
    io.req.command = input.IND_ADDHANDLER;
    io.data = &int;
    _ = sys.DoIO(&io.req);

    // A Ctrl-C from before this command started is not a request to stop it.
    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);
    _ = Printf(dl, MSG_WAITING, .{});
    const head: *volatile u32 = &ring.head;
    const tail: *volatile u32 = &ring.tail;
    const keymap_lib = sys.OpenLibrary(sdk.keymap.KEYMAPNAME, sdk.keymap.KEYMAP_VERSION);
    defer if (keymap_lib) |l| sys.CloseLibrary(l);
    const kb: ?*KeymapBase = @ptrCast(keymap_lib);
    var total: u32 = 0;
    var lost: u32 = 0;
    while (true) {
        const got = sys.Wait(ring.mask | exec.SIGBREAKF_CTRL_C);
        while (tail.* != head.*) {
            show(dl, kb, &ring.events[tail.* % ring_size]);
            tail.* +%= 1;
            total += 1;
        }
        const now_lost = @as(*volatile u32, &ring.lost).*;
        if (now_lost != lost) {
            _ = Printf(dl, MSG_LOST, .{now_lost - lost});
            lost = now_lost;
        }
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
    }

    io.req.command = input.IND_REMHANDLER;
    io.data = &int;
    _ = sys.DoIO(&io.req);
    _ = Printf(dl, MSG_DONE, .{total});
    return dos.RETURN_OK;
}
