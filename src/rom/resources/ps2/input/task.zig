// SPDX-License-Identifier: MPL-2.0
//! The task behind the keyboard controller: it takes the bytes the
//! servers kept, reads them as keys and as what the pointing device did,
//! and hands those to keyboard.device and mouse.device as a source of
//! each - the way a USB keyboard's and mouse's driver does, so nothing
//! above the two devices knows which kind of keyboard a key came from.
//!
//! **The servers** (`byteServer`, on the keyboard's line and on the
//! pointing device's) do what a server must and no more: while the
//! controller says a byte waits, the byte is read - which is what lets
//! the line drop - put in the ring with whose it is, and the task woken.
//! Both lines run the one function: the status says whose a byte is,
//! whichever line raised.
//!
//! **A task rather than the servers themselves**, because handing an
//! event to a device is a request the device answers, and an interrupt
//! cannot wait for an answer.

const sdk = @import("sdk");
const exec = sdk.exec;
const ie = sdk.devices.inputevent;
const kb = sdk.devices.keyboard;
const mouse = sdk.devices.mouse;
const vec = exec.vec;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("../ps2_base.zig");
const Ps2Base = _base.Ps2Base;
const port = @import("../port/_port.zig");
const scancode = @import("../key/scancode.zig");
const packet = @import("../pointer/packet.zig");

const stack_size = 8192;
/// Above the programs it feeds, as the devices it hands to are.
const task_pri = 10;
pub const task_name = "ps2.resource";

/// The lines the controller raises: the keyboard's and the pointing
/// device's, where every machine of this kind has them.
const key_line = 1;
const pointer_line = 12;

/// The most bytes one interrupt takes: more than the controller holds.
const bytes_most = 16;

/// The task started and waited for, then the servers put on their
/// lines. False when the task has no signal to be woken by.
pub fn start(pb: *Ps2Base) bool {
    const sys = pb.sys_base;
    const bit = sys.AllocSignal(-1);
    if (bit < 0) return false;
    defer sys.FreeSignal(bit);
    const stack = sys.AllocMem(stack_size, exec.MEMF_CLEAR) orelse return false;
    pb.stack = stack;
    pb.starter = sys.FindTask(null);
    pb.start_signal = @as(u32, 1) << @intCast(bit);
    pb.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = task_name },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    _ = sys.AddTask(&pb.task, &inputTask, null);
    _ = sys.Wait(pb.start_signal);
    if (pb.byte_signal == 0) return false;

    pb.key_server = .{ .node = .{ .type = .interrupt, .name = task_name }, .data = pb, .code = vec(byteServer) };
    sys.AddIntServer(key_line, &pb.key_server);
    if (pb.pointer) {
        pb.pointer_server = .{ .node = .{ .type = .interrupt, .name = task_name }, .data = pb, .code = vec(byteServer) };
        sys.AddIntServer(pointer_line, &pb.pointer_server);
    }
    return true;
}

fn byteServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const pb: *Ps2Base = @ptrCast(@alignCast(is_data.?));
    var took = false;
    var left: u32 = bytes_most;
    while (left > 0) : (left -= 1) {
        const status = port.status();
        if (status & port.STATUS_WAITING == 0) break;
        const byte: u16 = port.data();
        took = true;
        const head = @atomicLoad(u32, &pb.head, .acquire);
        const next = (head + 1) % _base.ring_size;
        if (next == @atomicLoad(u32, &pb.tail, .acquire)) {
            pb.lost +%= 1;
            continue;
        }
        pb.ring[head] = byte | (if (status & port.STATUS_POINTER != 0) _base.from_pointer else 0);
        @atomicStore(u32, &pb.head, next, .release);
    }
    if (!took) return 0;
    pb.sys_base.Signal(&pb.task, pb.byte_signal);
    return 1;
}

/// A source of keyboard.device or mouse.device: its request, and
/// whether it is open.
const Source = struct {
    io: exec.IOStdReq = .{},
    open: bool = false,

    fn take(source: *Source, sys: *ExecBase, reply: *exec.MsgPort, name: [*:0]const u8, flags: u32) void {
        source.io = .{};
        source.io.req.message.reply_port = reply;
        source.io.req.message.length = @sizeOf(exec.IOStdReq);
        source.open = sys.OpenDevice(name, 0, &source.io.req, flags) == 0;
    }

    fn hand(source: *Source, sys: *ExecBase, command: u16, events: []ie.InputEvent) void {
        if (!source.open or events.len == 0) return;
        source.io.req.command = command;
        source.io.data = events.ptr;
        source.io.length = @intCast(events.len * @sizeOf(ie.InputEvent));
        _ = sys.DoIO(&source.io.req);
    }
};

fn inputTask(sys: *ExecBase) callconv(.c) void {
    const pb: *Ps2Base = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const bit = sys.AllocSignal(-1);
    const reply = sys.CreateMsgPort();
    pb.byte_signal = if (bit < 0 or reply == null) 0 else @as(u32, 1) << @intCast(bit);
    if (pb.starter) |starter| {
        const told = pb.start_signal;
        pb.starter = null;
        sys.Signal(starter, told);
    }
    // A task with nothing to be woken by has nothing to wait for; its
    // stack stays with the resource, as a running task's would.
    if (pb.byte_signal == 0) return;

    var keys = Source{};
    var moves = Source{};
    keys.take(sys, reply.?, kb.KEYBOARDNAME, kb.KBDF_SOURCE);
    if (pb.pointer) moves.take(sys, reply.?, mouse.MOUSENAME, mouse.MOUSEF_SOURCE);
    var key_decoder = scancode.Decoder{};
    var move_decoder = packet.Decoder{ .wheel = pb.wheel };

    while (true) {
        _ = sys.Wait(pb.byte_signal);
        while (true) {
            const tail = @atomicLoad(u32, &pb.tail, .acquire);
            if (tail == @atomicLoad(u32, &pb.head, .acquire)) break;
            const entry = pb.ring[tail];
            @atomicStore(u32, &pb.tail, (tail + 1) % _base.ring_size, .release);
            const byte: u8 = @truncate(entry);
            if (entry & _base.from_pointer != 0) {
                var events: [packet.events_most]ie.InputEvent = undefined;
                const count = move_decoder.feed(byte, &events);
                moves.hand(sys, mouse.MOUSE_ADDEVENT, events[0..count]);
            } else if (key_decoder.feed(byte)) |key| {
                var event = [1]ie.InputEvent{.{
                    .class = ie.IECLASS_RAWKEY,
                    .code = @as(u32, key.rawkey) | (if (key.up) ie.IECODE_UP_PREFIX else 0),
                }};
                keys.hand(sys, kb.KBD_ADDEVENT, &event);
            }
        }
    }
}
