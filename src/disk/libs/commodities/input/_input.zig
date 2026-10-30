// SPDX-License-Identifier: MIT
//! The handler: the library on input.device's chain, and every event
//! through the network.
//!
//! The handler is on the chain, at priority 53, while there is a broker:
//! `updateHandler` puts it there when the first broker is made and takes
//! it off when the last goes, each time looking at the list itself, so
//! two programs doing either at once leave it as the list says.
//!
//! **A round.** input.device calls the handler with a list of events,
//! and the handler:
//!
//! 1. frees the messages of its last round - their events were the list
//!    it gave back, which every handler after it has read by now - and
//!    the messages programs have replied to;
//! 2. copies each new event into a message, after any it held back;
//! 3. tries for the network's lock. When a program has it, the handler
//!    gives back nothing and keeps the messages for the next round - the
//!    tick comes ten times a second - so nothing waits and nothing goes
//!    out of order;
//! 4. takes the messages programs added (AddIEvents), then its own, and
//!    sends each to the first broker;
//! 5. walks: the message at the head goes to its next object, which acts
//!    on it, until no message is left. A message whose list is done goes
//!    on after the object on top of its stack; one with an empty stack
//!    has come out of the network, and goes onto `returned`;
//! 6. links the events of `returned` and gives them back: that is what
//!    the windowing system sees.
//!
//! The objects' actions are below `walk`. A custom object's function is
//! called with the lock held, on input.device's task: it may route,
//! divert and dispose of messages, and add events, but not make or
//! delete objects.

const sdk = @import("sdk");
const exec = sdk.exec;
const cx = sdk.commodities;
const input = sdk.devices.input;
const ie = sdk.devices.inputevent;
const InputEvent = ie.InputEvent;
const _base = @import("../commodities_base.zig");
const _message = @import("../message/_message.zig");
const CxBase = _base.CxBase;
const Object = _base.Object;
const Message = _base.Message;

/// Before the windowing system (50) and the console (45): a hotkey is the
/// commodity's before any window sees it.
const handler_pri = 53;

/// The handler on input.device's chain when there is a broker, off it
/// when there is none.
pub fn updateHandler(base: *CxBase) void {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.handler_lock);
    defer sys.ReleaseSemaphore(&base.handler_lock);
    sys.ObtainSemaphore(&base.lock);
    const wanted = !base.brokers.isEmpty();
    sys.ReleaseSemaphore(&base.lock);
    if (wanted == (base.handler_on != 0)) return;
    // The request's reply comes to a port of this call's task.
    const port = sys.CreateMsgPort() orelse return;
    defer sys.DeleteMsgPort(port);
    const io = &base.input_io;
    if (wanted) {
        io.* = .{};
        io.req.message.reply_port = port;
        io.req.message.length = @sizeOf(exec.IOStdReq);
        if (sys.OpenDevice(input.INPUTNAME, 0, &io.req, 0) != 0) return;
        base.handler = .{
            .node = .{ .type = .interrupt, .pri = handler_pri, .name = base.lib.node.name },
            .data = base,
            .code = &handler,
        };
        io.req.command = input.IND_ADDHANDLER;
        io.data = &base.handler;
        _ = sys.DoIO(&io.req);
        base.handler_on = 1;
    } else {
        io.req.message.reply_port = port;
        io.req.command = input.IND_REMHANDLER;
        io.data = &base.handler;
        _ = sys.DoIO(&io.req);
        sys.CloseDevice(&io.req);
        base.handler_on = 0;
        // The handler is not running and never will again: what it kept
        // is freed here.
        drain(base);
    }
}

/// Every message the handler keeps between rounds, and the replied ones,
/// freed. Only while the handler is off the chain.
pub fn drain(base: *CxBase) void {
    const sys = base.sys_base;
    _message.freeList(base, &base.returned);
    _message.freeList(base, &base.held);
    sys.AcquireLock(&base.queue_lock);
    var queued: exec.List = .{};
    queued.init(.message);
    moveAll(base, &base.queue, &queued);
    sys.ReleaseLock(&base.queue_lock);
    _message.freeList(base, &queued);
    _message.freeReplied(base);
}

fn handler(events: ?*InputEvent, data: ?*anyopaque) callconv(.c) ?*InputEvent {
    return round(@ptrCast(@alignCast(data.?)), events);
}

/// Every node of `from` onto the end of `to`. Pure list work: done under
/// the queue's spinlock as well.
fn moveAll(base: *CxBase, from: *exec.List, to: *exec.List) void {
    const sys = base.sys_base;
    while (sys.RemHead(from)) |node| sys.AddTail(to, node);
}

/// One round: `events` through the network, and what comes out.
pub fn round(base: *CxBase, events: ?*InputEvent) ?*InputEvent {
    const sys = base.sys_base;
    _message.freeList(base, &base.returned);
    _message.freeReplied(base);

    var event = events;
    while (event) |e| : (event = e.next) {
        // Without memory the rest of the list is lost, as it would be
        // with any handler that cannot keep it.
        const message = _message.create(base, cx.CXM_IEVENT, e) orelse break;
        sys.AddTail(&base.held, &message.msg.node);
    }
    if (!sys.AttemptSemaphore(&base.lock)) return null;
    defer sys.ReleaseSemaphore(&base.lock);

    sys.AcquireLock(&base.queue_lock);
    moveAll(base, &base.queue, &base.routing);
    sys.ReleaseLock(&base.queue_lock);
    moveAll(base, &base.held, &base.routing);
    var it = base.routing.iterator();
    while (it.next()) |node| _message.routeToFirstBroker(base, @ptrCast(@alignCast(node)));

    walk(base);

    var first: ?*InputEvent = null;
    var last: ?*InputEvent = null;
    var out = base.returned.iterator();
    while (out.next()) |node| {
        const message: *Message = @ptrCast(@alignCast(node));
        message.event.next = null;
        if (last) |l| l.next = &message.event else first = &message.event;
        last = &message.event;
    }
    return first;
}

/// Every message on `routing` through the network, until none is left.
/// Under the network's lock.
fn walk(base: *CxBase) void {
    const sys = base.sys_base;
    const library = base.iface();
    while (base.routing.first()) |node| {
        const message: *Message = @ptrCast(@alignCast(node));
        var target = message.destination;
        if (message.echo > _base.TOO_MANY_ECHOES) target = null;
        // The end of a list: on after the object on top of the stack.
        while (target) |t| {
            if (t.succ != null) break;
            if (message.stack_index == 0) {
                target = null;
                break;
            }
            message.stack_index -= 1;
            const back = message.stack[message.stack_index] orelse {
                target = null;
                break;
            };
            target = back.node.succ;
        }
        const object: *Object = @ptrCast(@alignCast(target orelse {
            sys.Remove(&message.msg.node);
            sys.AddTail(&base.returned, &message.msg.node);
            continue;
        }));
        message.destination = object.node.succ;
        if (object.flags & _base.COF_ENABLE == 0) continue;
        message.echo += 1;
        const cxm = _base.cxMsgOf(message);
        const co = _base.handleOf(object);
        switch (object.kind) {
            cx.CX_FILTER => {
                if (object.err & cx.COERR_BADFILTER == 0 and library.MatchIX(&message.event, &object.data.filter)) {
                    library.DivertCxMsg(cxm, co, co);
                }
            },
            cx.CX_BROKER => library.DivertCxMsg(cxm, co, co),
            cx.CX_SEND => send(base, message, object),
            cx.CX_SIGNAL => if (object.data.signal.task) |task| {
                sys.Signal(task, @as(u32, 1) << @intCast(object.data.signal.signal));
            },
            cx.CX_TRANSLATE => translate(base, message, object),
            cx.CX_DEBUG => exec.kprintf(sys, "commodities debug %d: class %u code %x qualifier %x\n", .{
                object.data.debug, message.event.class, message.event.code, message.event.qualifier,
            }),
            cx.CX_CUSTOM => {
                message.id = object.data.custom.id;
                if (object.data.custom.action) |action| action(library, cxm, co);
            },
            else => {},
        }
    }
}

/// A copy of the message's event to the sender's port, with its id. The
/// message itself goes on.
fn send(base: *CxBase, message: *Message, object: *Object) void {
    const port = object.data.send.port orelse return;
    const copy = _message.create(base, cx.CXM_IEVENT, &message.event) orelse return;
    copy.id = object.data.send.id;
    base.sys_base.PutMsg(port, &copy.msg);
}

/// The message replaced by one for each of the translator's events, in
/// their order, each going on from where it would have.
fn translate(base: *CxBase, message: *Message, object: *Object) void {
    const sys = base.sys_base;
    var pred: *exec.Node = &message.msg.node;
    var event = object.data.translate;
    while (event) |e| : (event = e.next) {
        const clone = _message.create(base, cx.CXM_IEVENT, e) orelse break;
        clone.event.time = message.event.time;
        clone.destination = message.destination;
        clone.id = message.id;
        clone.stack = message.stack;
        clone.stack_index = message.stack_index;
        clone.echo = message.echo;
        sys.Insert(&base.routing, &clone.msg.node, pred);
        pred = &clone.msg.node;
    }
    base.iface().DisposeCxMsg(_base.cxMsgOf(message));
}

/// Whether the calling task is inside the walk: a custom object's
/// function, on input.device's task, with the network's lock held.
pub fn inWalk(base: *CxBase) bool {
    return base.lock.owner == base.sys_base.FindTask(null);
}
