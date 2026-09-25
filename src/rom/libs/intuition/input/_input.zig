// SPDX-License-Identifier: MPL-2.0
//! Input: what intuition.library does with input.device's events.
//!
//! intuition.library is a handler on input.device's chain (priority 50),
//! put there the first time a screen opens - a machine that never opens a
//! screen never starts input.device. A handler runs on input.device's task
//! and must never wait, and what intuition does with an event - activating
//! a window, moving it, reordering it - takes the screen semaphore and
//! layer locks, which a program may be holding. So the handler only copies
//! the events it cares about into a ring in the base and signals
//! intuition's own task, and passes the list on unchanged. The task does
//! the work, one event at a time, under the screen semaphore:
//!
//!   - the pointer (IECLASS_NEWPOINTERPOS): a press activates the window
//!     under it and then acts on what part of the window it is on - a border
//!     gadget is shown pressed, and acts when let go over it (close sends
//!     IDCMP_CLOSEWINDOW, depth sends the window to the back if it is in
//!     front and to the front if it is not); the drag bar moves the window
//!     and the size gadget sizes it for as long as the button is held; the
//!     inside is IDCMP_MOUSEBUTTONS. A move with nothing held is
//!     IDCMP_MOUSEMOVE to the active window.
//!   - a key: IDCMP_RAWKEY to the active window, unless it is a
//!     right-Amiga shortcut of one of its menu items.
//!   - the menu button: the active window's menus (input/menus.zig), which
//!     take every event until they are gone.
//!   - the tick: IDCMP_INTUITICKS to the active window, one at a time.
//!
//! Every message a window gets carries where the pointer is in the window's
//! own coordinates, the qualifiers and the time of the event being handled.
//! `handle` is the work for one event, so the host tests drive it directly.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const layers = sdk.layers;
const ie = sdk.devices.inputevent;
const input = sdk.devices.input;
const timer = sdk.devices.timer;
const wn = sdk.intuition.windows;
const TagItem = utility.TagItem;
const InputEvent = ie.InputEvent;
const ExecBase = sdk.interface.exec.ExecBase;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _kscreen = @import("../screen/_screen.zig");
const Screen = _kscreen.Screen;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _gadget = @import("../gadget/_gadget.zig");
const menus = @import("menus.zig");
const verify = @import("verify.zig");
const _requester = @import("../requester/_requester.zig");
const rq = sdk.intuition.requesters;
const gadgetclass = @import("../classes/gadgetclass.zig");
const gc = sdk.intuition.gadgetclass;
const Object = sdk.intuition.Object;

/// Where on the chain: above anything that wants what intuition leaves.
const handler_pri = 50;
/// Above every program, with input.device, so the pointer is followed while
/// a program computes.
const task_pri = 20;
/// The borders are drawn from here, and sysiclass fills polygons.
const stack_size = 16384;
const ring_size = 64;

/// What the pointer is doing with the button held: `gadget` is a border
/// gadget pressed, `active` a gadget of the window's own being fed input,
/// `verify` the window being asked IDCMP_SIZEVERIFY before `part` - its
/// size gadget pressed or its zoom gadget used - goes ahead,
/// `screen_depth` the depth gadget in a screen's title bar pressed,
/// `sys_gadget` a gadget standing for the window's close, depth or zoom
/// gadget (`GA_SysGadget`) held.
const Mode = enum(u32) { none, inside, gadget, drag, size, active, verify, screen_depth, sys_gadget };

/// Where on a window a point is.
pub const Part = enum(u32) { none, inside, border, drag, close, depth, zoom, size };

/// intuition.library's input state, in its base.
pub const State = extern struct {
    /// 0 not tried, 1 running, 2 tried and there is no input.device.
    started: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    io: exec.IOStdReq = .{},
    handler: exec.Interrupt = .{},
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    /// The task's signal, which the handler raises.
    mask: u32 = 0,
    starter: ?*exec.Task = null,
    start_signal: i32 = -1,
    /// The handler writes `head`, the task `tail`.
    head: u32 = 0,
    tail: u32 = 0,
    events: [ring_size]InputEvent = undefined,

    /// The pointer on the display, and the event being handled: every
    /// message sent while it is handled carries its qualifiers and time.
    x: i32 = 0,
    y: i32 = 0,
    qualifier: u32 = 0,
    time: timer.TimeVal = .{},

    /// What a held button is doing, and to which window.
    mode: Mode = .none,
    part: Part = .none,
    window: ?*Window = null,
    /// The pointer when the button went down, and the window's box then.
    grab_x: i32 = 0,
    grab_y: i32 = 0,
    box_left: i32 = 0,
    box_top: i32 = 0,
    box_width: i32 = 0,
    box_height: i32 = 0,
    /// The pressed gadget is drawn pressed: the pointer is over it.
    over: u8 = 0,
    pad2: [3]u8 = .{ 0, 0, 0 },
    /// The window's own gadget that has the input, in `mode` active.
    active: ?*Object = null,
    /// The screen whose depth gadget is pressed, in `mode` screen_depth.
    screen: ?*Screen = null,
    /// Gadget help: where the pointer was at the last timer event, where
    /// help was last worked out, and what it said - the address and code
    /// last sent, which are sent again only when they change.
    help_last_x: i32 = 0,
    help_last_y: i32 = 0,
    help_x: i32 = -1,
    help_y: i32 = -1,
    help_target: ?*anyopaque = null,
    help_code: usize = 0,
};

fn stateOf(ib: *IntuitionBase) *State {
    return &ib.input;
}

// --- the handler and the task -------------------------------------------------------

/// On input.device's task: the events intuition wants copied into the ring,
/// the task told, the list passed on as it came.
fn handler(events: ?*InputEvent, data: ?*anyopaque) callconv(.c) ?*InputEvent {
    const ib: *IntuitionBase = @ptrCast(@alignCast(data.?));
    const st = stateOf(ib);
    var any = false;
    var e = events;
    while (e) |ev| : (e = ev.next) {
        switch (ev.class) {
            ie.IECLASS_RAWKEY, ie.IECLASS_NEWPOINTERPOS, ie.IECLASS_TIMER => {},
            else => continue,
        }
        if (push(st, ev)) any = true;
    }
    if (any) ib.sys_base.Signal(&st.task, st.mask);
    return events;
}

/// One event into the ring: whether it went in.
///
/// **A full ring gives up the newest move, not the newest event.** The
/// next move says where the pointer is anyway, so one lost costs nothing;
/// a press, a release or a key lost costs a great deal - a release that
/// never arrives leaves whatever has the input holding it for good, and
/// every click after that goes to something nobody is pointing at. The
/// ring fills whenever the task is slower than the events arrive, which
/// is what dragging a window over a display this size is.
fn push(st: *State, ev: *const InputEvent) bool {
    const head: *volatile u32 = &st.head;
    const tail: *volatile u32 = &st.tail;
    if (head.* -% tail.* >= ring_size) {
        var back = head.*;
        while (back != tail.*) {
            back -%= 1;
            if (!isMove(&st.events[back % ring_size])) continue;
            st.events[back % ring_size] = ev.*;
            return true;
        }
        return false;
    }
    st.events[head.* % ring_size] = ev.*;
    head.* +%= 1;
    return true;
}

fn isMove(e: *const InputEvent) bool {
    return e.class == ie.IECLASS_NEWPOINTERPOS and e.code == ie.IECODE_NOBUTTON;
}

fn inputTask(sys: *ExecBase) callconv(.c) void {
    const st: *State = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const ib: *IntuitionBase = @alignCast(@fieldParentPtr("input", st));
    const signal = sys.AllocSignal(-1);
    if (signal >= 0) st.mask = @as(u32, 1) << @intCast(signal);
    if (st.starter) |starter| {
        st.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(st.start_signal));
    }
    if (signal < 0) return;
    // The menu session's replies signal this task too.
    var verify_mask: u32 = 0;
    const verify_signal = sys.AllocSignal(-1);
    if (verify_signal >= 0) {
        verify_mask = @as(u32, 1) << @intCast(verify_signal);
        ib.verify.port.sig_bit = @intCast(verify_signal);
        ib.verify.port.sig_task = &st.task;
        ib.verify.port.flags = exec.PA_SIGNAL;
    }
    const head: *volatile u32 = &st.head;
    const tail: *volatile u32 = &st.tail;
    while (true) {
        const got = sys.Wait(st.mask | verify_mask);
        if (got & verify_mask != 0) {
            _window.lock(ib);
            verify.poll(ib);
            _window.unlock(ib);
        }
        while (tail.* != head.*) {
            const e = st.events[tail.* % ring_size];
            tail.* +%= 1;
            // A move followed by another move is only the way there.
            if (isMove(&e) and tail.* != head.* and isMove(&st.events[tail.* % ring_size])) continue;
            handle(ib, &e);
        }
    }
}

/// input.device opened, the task started and the handler on the chain - the
/// first time a screen opens. Without input.device (the host tests, a ROM
/// without it) there is no input, and nothing else changes.
pub fn start(ib: *IntuitionBase) void {
    const st = stateOf(ib);
    if (st.started != 0) return;
    st.started = 2;
    const sys = ib.sys_base;
    // The port is this call's; the request outlives it, and what is kept
    // of it afterwards is the device and the unit that `windowEvent`
    // copies. Nothing does I/O with `st.io` itself again.
    const port = sys.CreateMsgPort() orelse return;
    defer sys.DeleteMsgPort(port);
    st.io = .{};
    st.io.req.message.reply_port = port;
    st.io.req.message.length = @sizeOf(exec.IOStdReq);
    if (sys.OpenDevice(input.INPUTNAME, 0, &st.io.req, 0) != 0) return;

    const stack = sys.AllocMem(stack_size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        sys.CloseDevice(&st.io.req);
        return;
    };
    const signal = sys.AllocSignal(-1);
    if (signal < 0) {
        sys.FreeMem(stack, stack_size);
        sys.CloseDevice(&st.io.req);
        return;
    }
    defer sys.FreeSignal(signal);
    st.stack = stack;
    st.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = "intuition input" },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    st.starter = sys.FindTask(null);
    st.start_signal = signal;
    _ = sys.AddTask(&st.task, &inputTask, null);
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    if (st.mask == 0) return;

    st.handler = .{
        .node = .{ .type = .interrupt, .pri = handler_pri, .name = "intuition.library" },
        .data = ib,
        .code = &handler,
    };
    st.io.req.command = input.IND_ADDHANDLER;
    st.io.data = &st.handler;
    _ = sys.DoIO(&st.io.req);
    st.started = 1;
}

/// A window event down input.device's chain, beside the IDCMP message the
/// window's program gets: what a console.device unit on that window hears,
/// without taking the program's own messages. Nothing happens before
/// input.device is open, and it is never called from inside a handler.
pub fn windowEvent(ib: *IntuitionBase, w: *Window, class: u32, code: u32) void {
    const st = stateOf(ib);
    if (st.started != 1) return;
    const sys = ib.sys_base;
    var e: InputEvent = .{
        .class = class,
        .code = code,
        .qualifier = st.qualifier,
        .address = @ptrCast(w),
    };
    // The port and the request are this call's own, on the stack. It is
    // called both from this library's task and from the task of whatever
    // program opened, sized or closed a window, and a reply signals the
    // task its port belongs to: one port made once would signal whichever
    // task happened to make it, and every other caller would wait for a
    // signal that went somewhere else. Two tasks would share the one
    // request as well.
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return; // no signal to wait on: the event is not written
    defer sys.FreeSignal(signal);
    var port: exec.MsgPort = .{
        .flags = exec.PA_SIGNAL,
        .sig_bit = @intCast(signal),
        .sig_task = sys.FindTask(null),
    };
    port.msg_list.init(.message);
    var io = st.io; // the device and unit the handler's request holds
    io.req.message.reply_port = &port;
    io.req.message.length = @sizeOf(exec.IOStdReq);
    io.req.command = input.IND_WRITEEVENT;
    io.data = &e;
    io.length = @sizeOf(InputEvent);
    _ = sys.DoIO(&io.req);
}

/// A window is closing: nothing held refers to it any more. Under the
/// screen semaphore.
pub fn forget(ib: *IntuitionBase, w: *Window) void {
    const st = stateOf(ib);
    menus.forget(ib, w);
    if (st.mode == .verify and st.window == w) verify.drop(ib);
    if (st.window == w) {
        if (st.mode == .active) abort(ib);
        st.window = null;
        st.mode = .none;
    }
}

/// A gadget is being taken out of its window: if it has the input, it is
/// told it has lost it. Under the screen semaphore.
pub fn forgetGadget(ib: *IntuitionBase, o: *Object) void {
    const st = stateOf(ib);
    if (st.mode == .active and st.active == o) {
        abort(ib);
        st.window = null;
        st.mode = .none;
    }
}

/// The active gadget told it is done, not by its own choice.
fn abort(ib: *IntuitionBase) void {
    const st = stateOf(ib);
    const o = st.active orelse return;
    // Let go of it first and whatever happens next, so that a window
    // already gone cannot leave a gadget pointer behind that the next
    // press would find.
    st.active = null;
    const w = st.window orelse return;
    var gi = _gadget.infoFor(ib, w, o);
    var msg = gc.GpGoInactive{ .gadget_info = &gi, .abort = 1 };
    _ = ib.iface().SendMessage(o, @ptrCast(&msg));
}

// --- where the pointer is -------------------------------------------------------------

/// The part of a window at (x, y) in the window's own coordinates.
pub fn partAt(w: *const Window, x: i32, y: i32) Part {
    if (x < 0 or y < 0 or x >= w.width or y >= w.height) return .none;
    if (w.flags & _window.WF_BORDERLESS != 0) return .inside;
    if (y < w.border_top) {
        if (w.flags & _window.WF_CLOSE != 0 and x < _window.close_width) return .close;
        if (w.flags & _window.WF_DEPTH != 0 and x >= w.width - _window.depth_width) return .depth;
        if (w.flags & _window.WF_HASZOOM != 0) {
            const right = w.width - @as(i32, if (w.flags & _window.WF_DEPTH != 0) _window.depth_width else 0);
            if (x >= right - _window.zoom_width and x < right) return .zoom;
        }
        return if (w.flags & _window.WF_DRAG != 0) .drag else .border;
    }
    if (w.flags & _window.WF_SIZE != 0 and x >= w.width - _window.size_width and y >= w.height - _window.size_height) return .size;
    if (x >= w.border_left and x < w.width - w.border_right and y < w.height - w.border_bottom) return .inside;
    return .border;
}

/// The screen the pointer is on: the one screen of the display.
fn screenAt(ib: *IntuitionBase) ?*Screen {
    const first = ib.screen_list.head orelse return null;
    if (first.succ == null) return null;
    return @ptrCast(@alignCast(first));
}

/// The window whose visible part is at (x, y) on its screen, or null for
/// the title bar, the ground or nothing.
fn windowAt(ib: *IntuitionBase, s: *Screen, x: i32, y: i32) ?*Window {
    const layer = ib.layers_base.WhichLayer(s.layer_info, x, y) orelse return null;
    var node = s.windows.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const w: *Window = @ptrCast(@alignCast(n));
        // Either of them: a GimmeZeroZero window is two layers, and a point
        // inside its border is in the inner one. A requester is the
        // window's too.
        if (w.layer == layer or w.inner_layer == layer or _requester.owns(w, layer)) return w;
    }
    return null;
}

// --- the work for one event ------------------------------------------------------------

/// One event, on intuition's task (or a host test).
pub fn handle(ib: *IntuitionBase, e: *const InputEvent) void {
    const st = stateOf(ib);
    _window.lock(ib);
    defer _window.unlock(ib);
    st.qualifier = e.qualifier;
    st.time = e.time;
    if (e.class == ie.IECLASS_NEWPOINTERPOS) {
        st.x = e.x;
        st.y = e.y;
    }
    // An alert up takes everything.
    if (ib.alert.active) return @import("../misc/_misc.zig").alertInput(ib, e);
    // A menu session takes everything while it lasts, and so does a
    // window being asked whether it may be sized.
    verify.poll(ib);
    if (menus.busy(ib)) {
        menus.handle(ib, e);
        return;
    }
    if (st.mode == .verify) return sizeVerifying(ib, e);
    // A gadget with the input gets everything until it is done; a tick
    // still reaches the window as well.
    if (st.mode == .active) {
        switch (e.class) {
            ie.IECLASS_NEWPOINTERPOS, ie.IECLASS_RAWKEY, ie.IECLASS_TIMER => {},
            else => return,
        }
        // A press somewhere else takes the gadget's hold away from it. A
        // gadget that ends only on a release - a line of text waits for
        // one over itself - would otherwise keep every event there is
        // after a press in another window, and nothing could take it back.
        if (e.class == ie.IECLASS_NEWPOINTERPOS and e.code == ie.IECODE_LBUTTON) {
            const here = if (screenAt(ib)) |s| windowAt(ib, s, st.x, st.y) else null;
            if (here != st.window) {
                abort(ib);
                st.window = null;
                st.mode = .none;
                handleFree(ib, e);
                return;
            }
        }
        followMouse(ib, e);
        const reuse = feed(ib, e);
        if (e.class == ie.IECLASS_TIMER) {
            if (ib.active_window) |w| _window.tick(ib, w);
        }
        if (!reuse) return;
    }
    handleFree(ib, e);
}

/// An event with no gadget holding the input.
fn handleFree(ib: *IntuitionBase, e: *const InputEvent) void {
    switch (e.class) {
        ie.IECLASS_NEWPOINTERPOS => {
            if (e.code == ie.IECODE_LBUTTON) {
                press(ib, e);
            } else if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
                release(ib);
            } else if (e.code == ie.IECODE_NOBUTTON) {
                moved(ib);
            } else {
                otherButton(ib, e.code);
            }
        },
        ie.IECLASS_RAWKEY => if (ib.active_window) |w| key(ib, w, e),
        ie.IECLASS_TIMER => if (ib.active_window) |w| {
            _window.tick(ib, w);
            helpTick(ib, w);
        },
        else => {},
    }
}

/// One event to the gadget that has the input; true when it is done with
/// it and the event is to be handled as though it had never been active.
fn feed(ib: *IntuitionBase, e: *const InputEvent) bool {
    const st = stateOf(ib);
    const o = st.active orelse return false;
    const w = st.window orelse return false;
    const b = _gadget.box(ib, w, o);
    var gi = _gadget.infoFor(ib, w, o);
    const at = _gadget.toDomainFor(ib, w, o, st.x - w.left, st.y - w.top);
    var termination: i32 = 0;
    var msg = gc.GpInput{
        .method_id = gc.GM_HANDLEINPUT,
        .gadget_info = &gi,
        .event = e,
        .termination = &termination,
        .mouse = .{ .x = at.x - b.left, .y = at.y - b.top },
    };
    const result = ib.iface().SendMessage(o, @ptrCast(&msg));
    if (result == gc.GMR_MEACTIVE) return false;
    finish(ib, w, o, result, termination);

    // Tab out of it: the keyboard goes to the next gadget of the window
    // that takes it, without the pointer being anywhere near.
    const tab = result & (gc.GMR_NEXTACTIVE | gc.GMR_PREVACTIVE);
    if (tab != 0) {
        if (_gadget.tabFrom(ib, w, o, tab & gc.GMR_PREVACTIVE != 0)) |o2| {
            activateGadget(ib, w, o2);
        }
        return false;
    }
    return result & gc.GMR_REUSE != 0;
}

/// A gadget given the input with no press behind it - Tab arriving at it,
/// or a program asking. The event a press would have carried is null,
/// which is how a class tells the two apart.
fn activateGadget(ib: *IntuitionBase, w: *Window, o: *Object) void {
    const st = stateOf(ib);
    var gi = _gadget.infoFor(ib, w, o);
    var termination: i32 = 0;
    var msg = gc.GpInput{
        .method_id = gc.GM_GOACTIVE,
        .gadget_info = &gi,
        .event = null,
        .termination = &termination,
        .mouse = .{ .x = 0, .y = 0 },
    };
    const result = ib.iface().SendMessage(o, @ptrCast(&msg));
    if (result == gc.GMR_MEACTIVE) {
        st.mode = .active;
        st.active = o;
        st.window = w;
        return;
    }
    finish(ib, w, o, result, termination);
}

/// ActivateGadget's work: the gadget given the input if nothing is in the
/// way - its window active, nothing held, no menu session, the gadget on
/// that window and enabled, in `requester` and that the one in front - and
/// true when it took it.
pub fn activateFor(ib: *IntuitionBase, w: *Window, o: *Object, requester: ?*sdk.intuition.Requester) bool {
    const st = stateOf(ib);
    if (ib.active_window != w or st.mode != .none or menus.busy(ib)) return false;
    const g = gadgetclass.gadgetOf(ib, o);
    if (g.window != w or g.flags & gadgetclass.GFLG_DISABLED != 0) return false;
    if (g.requester != requester or g.requester != w.first_request) return false;
    activateGadget(ib, w, o);
    return st.mode == .active and st.active == o;
}

/// A gadget done: told so, and the program told what it did.
fn finish(ib: *IntuitionBase, w: *Window, o: *Object, result: usize, termination: i32) void {
    const st = stateOf(ib);
    st.active = null;
    st.mode = .none;
    st.window = null;
    var gi = _gadget.infoFor(ib, w, o);
    var msg = gc.GpGoInactive{ .gadget_info = &gi, .abort = 0 };
    _ = ib.iface().SendMessage(o, @ptrCast(&msg));
    const g = gadgetclass.gadgetOf(ib, o);
    if (result & gc.GMR_VERIFY != 0 and g.activation & gadgetclass.GACT_RELVERIFY != 0) {
        _ = _window.sendWith(ib, w, wn.IDCMP_GADGETUP, @bitCast(termination), o);
    }
    // An end gadget used the way that counts takes its requester down.
    if (result & gc.GMR_VERIFY != 0 and g.activation & gadgetclass.GACT_ENDGADGET != 0) {
        if (g.requester) |req| ib.iface().EndRequest(req, @ptrCast(w));
    }
}

/// A press on a gadget of the window's own: it goes active if it will.
fn pressGadget(ib: *IntuitionBase, w: *Window, o: *Object, e: *const InputEvent) void {
    const st = stateOf(ib);
    const b = _gadget.box(ib, w, o);
    var gi = _gadget.infoFor(ib, w, o);
    const at = _gadget.toDomainFor(ib, w, o, st.x - w.left, st.y - w.top);
    var termination: i32 = 0;
    var msg = gc.GpInput{
        .method_id = gc.GM_GOACTIVE,
        .gadget_info = &gi,
        .event = e,
        .termination = &termination,
        .mouse = .{ .x = at.x - b.left, .y = at.y - b.top },
    };
    if (gadgetclass.gadgetOf(ib, o).activation & gadgetclass.GACT_IMMEDIATE != 0) {
        _ = _window.sendWith(ib, w, wn.IDCMP_GADGETDOWN, 0, o);
    }
    const result = ib.iface().SendMessage(o, @ptrCast(&msg));
    if (result == gc.GMR_MEACTIVE) {
        st.mode = .active;
        st.active = o;
        st.window = w;
        return;
    }
    finish(ib, w, o, result, termination);
}

/// A key to the active window: IDCMP_VANILLAKEY when it listens for that
/// and the key makes one character through the default keymap, the
/// character in `code`; IDCMP_RAWKEY otherwise.
fn key(ib: *IntuitionBase, w: *Window, e: *const InputEvent) void {
    // A requester up takes the keys from the window - its shortcuts too -
    // unless it is a noisy one, which passes them on.
    if (w.first_request) |req| {
        if (req.flags & rq.NOISYREQ == 0) return;
    } else if (menus.shortcut(ib, w, e)) return;
    if (w.idcmp & wn.IDCMP_VANILLAKEY != 0) {
        if (ib.keymap_base) |kb| {
            var text: [8]u8 = undefined;
            if (kb.MapRawKey(e, &text, text.len, null) == 1) {
                _window.send(ib, w, wn.IDCMP_VANILLAKEY, text[0]);
                return;
            }
        }
    }
    _window.send(ib, w, wn.IDCMP_RAWKEY, e.code);
}

fn press(ib: *IntuitionBase, e: *const InputEvent) void {
    const st = stateOf(ib);
    const s = screenAt(ib) orelse return;
    // The screen's depth gadget, where no window covers it: pressed until
    // the button goes up.
    if (_kscreen.onDepthGadget(ib, s, st.x, st.y)) {
        st.mode = .screen_depth;
        st.screen = s;
        st.over = 1;
        _kscreen.drawDepth(ib, s, true);
        return;
    }
    const w = windowAt(ib, s, st.x, st.y) orelse return;
    if (ib.active_window != w) ib.iface().ActivateWindow(@ptrCast(w));
    const part = partAt(w, st.x - w.left, st.y - w.top);
    // A requester up in it: its gadgets, and the window's drag bar, depth,
    // zoom and size gadgets, are all a press may reach.
    if (w.first_request) |req| switch (part) {
        .drag, .depth, .zoom, .size => {},
        else => return pressRequester(ib, w, req, part, e),
    };
    // The window's own gadgets are asked first, the drag bar's row
    // included - a gadget put in the top border is meant to be pressed
    // there, and dragging the window is what is left when none is. The
    // close, depth and size gadgets keep their corners: they are not on
    // this list, so nothing here can be asked in their place.
    if (w.first_request == null and (part == .inside or part == .border or part == .drag)) {
        switch (_gadget.hit(ib, w, st.x - w.left, st.y - w.top)) {
            .gadget => |o| {
                if (sysPartOf(ib, o)) |stands_for| return pressSysGadget(ib, w, o, stands_for);
                pressGadget(ib, w, o, e);
                return;
            },
            // A disabled gadget is still the thing that was pressed: the
            // press stops here rather than dragging the window about.
            .disabled => return,
            .none => {},
        }
    }
    st.window = w;
    st.part = part;
    st.grab_x = st.x;
    st.grab_y = st.y;
    st.box_left = w.left;
    st.box_top = w.top;
    st.box_width = w.width;
    st.box_height = w.height;
    switch (part) {
        .close, .depth, .zoom => {
            st.mode = .gadget;
            st.over = 1;
            _window.drawGadget(ib, w, gadgetOf(part), true);
        },
        .size => {
            st.over = 1;
            _window.drawGadget(ib, w, .size, true);
            // A window that asked is asked first; its reply lets the
            // sizing begin.
            if (w.idcmp & wn.IDCMP_SIZEVERIFY != 0) {
                st.mode = .verify;
                return verify.start(ib, w, wn.IDCMP_SIZEVERIFY, 0, .size);
            }
            st.mode = .size;
        },
        .drag => st.mode = .drag,
        .inside => {
            st.mode = .inside;
            _window.send(ib, w, wn.IDCMP_MOUSEBUTTONS, wn.SELECTDOWN);
        },
        .border, .none => st.mode = .none,
    }
}

/// A press on a window with a requester up, not on a border gadget that
/// still works: to a gadget of the requester in front when it is on one,
/// and otherwise to the window only when that requester is a noisy one.
fn pressRequester(ib: *IntuitionBase, w: *Window, req: *sdk.intuition.Requester, part: Part, e: *const InputEvent) void {
    const st = stateOf(ib);
    const layer = ib.layers_base.WhichLayer(w.screen.layer_info, st.x, st.y);
    if (req.layer != null and layer == req.layer) {
        switch (_gadget.hitList(ib, w, req.gadgets, st.x - w.left, st.y - w.top)) {
            .gadget => |o| return pressGadget(ib, w, o, e),
            .disabled => return,
            .none => {},
        }
    }
    if (req.flags & rq.NOISYREQ == 0 or part == .none) return;
    st.window = w;
    st.part = part;
    st.mode = .inside;
    _window.send(ib, w, wn.IDCMP_MOUSEBUTTONS, wn.SELECTDOWN);
}

fn gadgetOf(part: Part) _window.Gadget {
    return switch (part) {
        .close => .close,
        .depth => .depth,
        .zoom => .zoom,
        else => .size,
    };
}

fn moved(ib: *IntuitionBase) void {
    const st = stateOf(ib);
    switch (st.mode) {
        .drag => if (st.window) |w| ib.iface().ChangeWindowBox(
            @ptrCast(w),
            st.box_left + st.x - st.grab_x,
            st.box_top + st.y - st.grab_y,
            w.width,
            w.height,
        ),
        .size => if (st.window) |w| ib.iface().ChangeWindowBox(
            @ptrCast(w),
            w.left,
            w.top,
            st.box_width + st.x - st.grab_x,
            st.box_height + st.y - st.grab_y,
        ),
        .screen_depth => if (st.screen) |s| {
            const over: u8 = @intFromBool(_kscreen.onDepthGadget(ib, s, st.x, st.y));
            if (over != st.over) {
                st.over = over;
                _kscreen.drawDepth(ib, s, over != 0);
            }
        },
        .gadget => if (st.window) |w| {
            // Pressed while the pointer is over it, as it would be let go.
            const over: u8 = @intFromBool(partAt(w, st.x - w.left, st.y - w.top) == st.part);
            if (over != st.over) {
                st.over = over;
                _window.drawGadget(ib, w, gadgetOf(st.part), over != 0);
            }
        },
        // A move with nothing held goes only to a window that asked to hear
        // the pointer over it. Without that a window listening for the class
        // at all would be told about every move anywhere on the screen.
        else => if (ib.active_window) |w| {
            if (w.flags & _window.WF_REPORTMOUSE != 0) _window.send(ib, w, wn.IDCMP_MOUSEMOVE, 0);
        },
    }
}

/// The menu and middle buttons: told to the active window, wherever the
/// pointer is. The menu button pressed is the window's with WA_RMBTrap, and
/// otherwise the menus' - unless the select button is already doing
/// something - and let go is always told.
fn otherButton(ib: *IntuitionBase, code: u32) void {
    const w = ib.active_window orelse return;
    // A requester up takes the menu button from the window, and from its
    // menus, unless it is a noisy one.
    if (w.first_request) |req| {
        if (req.flags & rq.NOISYREQ == 0 and (code & ~ie.IECODE_UP_PREFIX) == ie.IECODE_RBUTTON) return;
        if (code == ie.IECODE_RBUTTON) {
            _ = _window.sendWith(ib, w, wn.IDCMP_MOUSEBUTTONS, code, null);
            return;
        }
    }
    if (code == ie.IECODE_RBUTTON and w.flags & _window.WF_RMBTRAP == 0) {
        if (stateOf(ib).mode == .none) menus.menuButton(ib);
        return;
    }
    const told = switch (code) {
        ie.IECODE_RBUTTON => true,
        ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX,
        ie.IECODE_MBUTTON,
        ie.IECODE_MBUTTON | ie.IECODE_UP_PREFIX,
        => true,
        else => false,
    };
    if (told) _ = _window.sendWith(ib, w, wn.IDCMP_MOUSEBUTTONS, code, null);
}

/// An event while a window is asked IDCMP_SIZEVERIFY: a tick counts down
/// the time it has, letting go of the size gadget gives the sizing up, and
/// nothing else happens until the answer.
fn sizeVerifying(ib: *IntuitionBase, e: *const InputEvent) void {
    switch (e.class) {
        ie.IECLASS_TIMER => {
            if (ib.active_window) |w| _window.tick(ib, w);
            verify.tick(ib);
        },
        ie.IECLASS_NEWPOINTERPOS => {
            if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX and stateOf(ib).part == .size) verify.abort(ib, .abort);
        },
        else => {},
    }
}

/// IDCMP_SIZEVERIFY answered, or given up on. Yes: the sizing begins, with
/// the button still held, or the zoom is done. Given up: the size gadget
/// comes back up, and the window hears IDCMP_NEWSIZE, which says the
/// sizing it was warned of is over.
pub fn sizeVerified(ib: *IntuitionBase, purpose: verify.Purpose, answer: verify.Answer) void {
    const st = stateOf(ib);
    const w = st.window orelse {
        st.mode = .none;
        return;
    };
    if (answer != .abort) {
        if (purpose == .size) {
            st.mode = .size;
            return;
        }
        st.mode = .none;
        st.window = null;
        const width = w.width;
        const height = w.height;
        ib.iface().ZipWindow(@ptrCast(w));
        if (w.width == width and w.height == height) _window.send(ib, w, wn.IDCMP_NEWSIZE, 0);
        return;
    }
    st.mode = .none;
    st.window = null;
    if (purpose == .size) _window.drawGadget(ib, w, .size, false);
    _window.send(ib, w, wn.IDCMP_NEWSIZE, 0);
}

fn release(ib: *IntuitionBase) void {
    const st = stateOf(ib);
    const mode = st.mode;
    st.mode = .none;
    if (mode == .screen_depth) return releaseScreenDepth(ib);
    const w = st.window orelse return;
    st.window = null;
    if (mode == .sys_gadget) return releaseSysGadget(ib, w);
    switch (mode) {
        .gadget => {
            if (st.over != 0) _window.drawGadget(ib, w, gadgetOf(st.part), false);
            if (partAt(w, st.x - w.left, st.y - w.top) != st.part) return;
            switch (st.part) {
                .close => _window.send(ib, w, wn.IDCMP_CLOSEWINDOW, 0),
                .depth => depthToggle(ib, w),
                .zoom => {
                    if (w.idcmp & wn.IDCMP_SIZEVERIFY == 0) return ib.iface().ZipWindow(@ptrCast(w));
                    st.mode = .verify;
                    st.window = w;
                    verify.start(ib, w, wn.IDCMP_SIZEVERIFY, 0, .zoom);
                },
                else => {},
            }
        },
        .size => {
            _window.drawGadget(ib, w, .size, false);
            // A window that was asked hears that the sizing is over, even
            // when its size came out the same.
            if (w.idcmp & wn.IDCMP_SIZEVERIFY != 0 and w.width == st.box_width and w.height == st.box_height) {
                _window.send(ib, w, wn.IDCMP_NEWSIZE, 0);
            }
        },
        .inside => _window.send(ib, w, wn.IDCMP_MOUSEBUTTONS, wn.SELECTUP),
        else => {},
    }
}

/// A window to the back when it is in front of every other, else to the
/// front: what its depth gadget does.
fn depthToggle(ib: *IntuitionBase, w: *Window) void {
    var in_front: usize = 0;
    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetInFront, .data = @intFromPtr(&in_front) }, .{} };
    ib.layers_base.GetLayerAttrs(w.layer, &ask);
    if (in_front == 0) ib.iface().WindowToBack(@ptrCast(w)) else ib.iface().WindowToFront(@ptrCast(w));
}

/// Which of the window's own gadgets a gadget stands for (`GA_SysGadget`,
/// `GA_SysGType`), if it stands for one.
fn sysPartOf(ib: *IntuitionBase, o: *Object) ?Part {
    const g = gadgetclass.gadgetOf(ib, o);
    if (g.flags & gadgetclass.GFLG_SYSGADGET == 0) return null;
    return switch (g.sys_type) {
        gc.GTYP_WDRAGGING => .drag,
        gc.GTYP_SIZING => .size,
        gc.GTYP_CLOSE => .close,
        gc.GTYP_WDEPTH => .depth,
        gc.GTYP_WZOOM => .zoom,
        else => null,
    };
}

/// A press on a gadget standing for one of the window's own: a drag or a
/// sizing as from the window's own, or the gadget held, selected, until it
/// is let go.
fn pressSysGadget(ib: *IntuitionBase, w: *Window, o: *Object, part: Part) void {
    const st = stateOf(ib);
    st.window = w;
    st.part = part;
    st.grab_x = st.x;
    st.grab_y = st.y;
    st.box_left = w.left;
    st.box_top = w.top;
    st.box_width = w.width;
    st.box_height = w.height;
    switch (part) {
        .drag => st.mode = .drag,
        .size => st.mode = .size,
        else => {
            st.mode = .sys_gadget;
            st.active = o;
            selectGadget(ib, w, o, true);
        },
    }
}

fn selectGadget(ib: *IntuitionBase, w: *Window, o: *Object, on: bool) void {
    const g = gadgetclass.gadgetOf(ib, o);
    if (on) g.flags |= gadgetclass.GFLG_SELECTED else g.flags &= ~gadgetclass.GFLG_SELECTED;
    _gadget.render(ib, w, o, gc.GREDRAW_UPDATE);
}

/// Such a gadget let go: over it still, it does what it stands for.
fn releaseSysGadget(ib: *IntuitionBase, w: *Window) void {
    const st = stateOf(ib);
    const o = st.active orelse return;
    st.active = null;
    selectGadget(ib, w, o, false);
    switch (_gadget.hit(ib, w, st.x - w.left, st.y - w.top)) {
        .gadget => |hit| if (hit != o) return,
        else => return,
    }
    switch (st.part) {
        .close => _window.send(ib, w, wn.IDCMP_CLOSEWINDOW, 0),
        .depth => depthToggle(ib, w),
        .zoom => ib.iface().ZipWindow(@ptrCast(w)),
        else => {},
    }
}

/// A move while a gadget of `GA_FollowMouse` has the input: its window is
/// told, when it listens for the pointer's moves.
fn followMouse(ib: *IntuitionBase, e: *const InputEvent) void {
    if (e.class != ie.IECLASS_NEWPOINTERPOS or e.code != ie.IECODE_NOBUTTON) return;
    const st = stateOf(ib);
    const o = st.active orelse return;
    const w = st.window orelse return;
    if (gadgetclass.gadgetOf(ib, o).activation & gadgetclass.GACT_FOLLOWMOUSE == 0) return;
    _window.send(ib, w, wn.IDCMP_MOUSEMOVE, 0);
}

/// Gadget help at a timer event: when the active window has it on and the
/// pointer has come to rest somewhere new, what is under the pointer is
/// told to the window it belongs to - or, over no window of the active
/// one's help group, a null to the active window. Only a change is sent.
fn helpTick(ib: *IntuitionBase, active: *Window) void {
    const st = stateOf(ib);
    const x = st.x;
    const y = st.y;
    defer {
        st.help_last_x = x;
        st.help_last_y = y;
    }
    if (active.more_flags & _window.WMF_GADGETHELP == 0) return;
    const resting = @abs(x - st.help_last_x) <= 6 and @abs(y - st.help_last_y) <= 3;
    if (!resting or (x == st.help_x and y == st.help_y)) return;
    st.help_x = x;
    st.help_y = y;

    var told = active;
    var target: ?*anyopaque = null;
    var code: usize = gc.GMR_HELPHIT;
    if (screenAt(ib)) |s| {
        if (windowAt(ib, s, x, y)) |w| {
            if (w.help_group == active.help_group) {
                told = w;
                target = w;
                if (helpHit(ib, w, x, y)) |hit| {
                    target = hit.gadget;
                    code = hit.code;
                }
            }
        }
    }
    if (target == st.help_target and code == st.help_code) return;
    st.help_target = target;
    st.help_code = code;
    // All ones, or the gadget's own code in the low sixteen bits.
    const message_code: u32 = if (code == gc.GMR_HELPHIT) 0xFFFF_FFFF else @truncate(code & 0xFFFF);
    _ = _window.sendWith(ib, told, wn.IDCMP_GADGETHELP, message_code, target);
}

/// The help-aware gadget under (x, y) in a window - its requester's when
/// the point is on one - and what it answered GM_HELPTEST; null when none
/// has anything to say there.
fn helpHit(ib: *IntuitionBase, w: *Window, x: i32, y: i32) ?struct { gadget: *Object, code: usize } {
    var first = w.gadgets;
    const layer = ib.layers_base.WhichLayer(w.screen.layer_info, x, y);
    var req = w.first_request;
    while (req) |r| : (req = r.older) {
        if (r.layer != null and r.layer == layer) {
            first = r.gadgets;
            break;
        }
    }
    var next = first;
    while (next) |o| : (next = gadgetclass.gadgetOf(ib, o).next) {
        const g = gadgetclass.gadgetOf(ib, o);
        if (g.flags & gadgetclass.GFLG_GADGETHELP == 0) continue;
        var gi = _gadget.infoFor(ib, w, o);
        // Its own bounding box when it has one: the label beside it too.
        const b = if (g.flags & gadgetclass.GFLG_BOUNDS != 0)
            _gadget.Box{ .left = g.bounds.left, .top = g.bounds.top, .width = g.bounds.width, .height = g.bounds.height }
        else
            _gadget.boxIn(g, gi.domain_width, gi.domain_height);
        const at_x = x - w.left - gi.domain_left;
        const at_y = y - w.top - gi.domain_top;
        if (at_x < b.left or at_y < b.top or at_x >= b.left + b.width or at_y >= b.top + b.height) continue;
        var msg = gc.GpHitTest{ .method_id = gc.GM_HELPTEST, .gadget_info = &gi, .mouse = .{ .x = at_x - b.left, .y = at_y - b.top } };
        const answer = ib.iface().SendMessage(o, @ptrCast(&msg));
        if (answer != gc.GMR_NOHELPHIT) return .{ .gadget = o, .code = answer };
    }
    return null;
}

/// The screen's depth gadget let go: over it, the screen goes to the back
/// when it is in front of its display or Shift is held, and to the front
/// otherwise.
fn releaseScreenDepth(ib: *IntuitionBase) void {
    const st = stateOf(ib);
    const s = st.screen orelse return;
    st.screen = null;
    if (st.over != 0) _kscreen.drawDepth(ib, s, false);
    if (!_kscreen.onDepthGadget(ib, s, st.x, st.y)) return;
    const shifted = st.qualifier & (ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT) != 0;
    const in_front = _kscreen.frontOn(ib, s.board) == s;
    const flags = if (in_front or shifted) sdk.intuition.screens.SDEPTH_TOBACK else sdk.intuition.screens.SDEPTH_TOFRONT;
    ib.iface().ScreenDepth(@ptrCast(s), flags);
}

const testing = @import("std").testing;

test "a full input ring gives up a move, never a button" {
    var st = State{};
    const move: InputEvent = .{ .class = ie.IECLASS_NEWPOINTERPOS, .code = ie.IECODE_NOBUTTON, .x = 1, .y = 1 };
    var i: u32 = 0;
    while (i < ring_size) : (i += 1) {
        const one: InputEvent = .{ .class = ie.IECLASS_NEWPOINTERPOS, .code = ie.IECODE_NOBUTTON, .x = @intCast(i), .y = 0 };
        try testing.expect(push(&st, &one));
    }
    try testing.expectEqual(@as(u32, ring_size), st.head -% st.tail);

    // Full: another move is taken in place of the newest, so the pointer's
    // position stays current and the ring does not grow.
    try testing.expect(push(&st, &move));
    try testing.expectEqual(@as(u32, ring_size), st.head -% st.tail);
    try testing.expectEqual(@as(i32, 1), st.events[(st.head -% 1) % ring_size].x);

    // A release takes a move's place rather than being dropped: losing one
    // leaves whatever has the input holding it for good.
    const up: InputEvent = .{ .class = ie.IECLASS_NEWPOINTERPOS, .code = ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, .x = 9, .y = 9 };
    try testing.expect(push(&st, &up));
    var found = false;
    i = 0;
    while (i < ring_size) : (i += 1) {
        const e = st.events[(st.tail +% i) % ring_size];
        if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) found = true;
    }
    try testing.expect(found);

    // A ring of nothing but buttons has nothing to give up, so the newest
    // is refused rather than a press being lost.
    var full = State{};
    i = 0;
    while (i < ring_size) : (i += 1) {
        const typed: InputEvent = .{ .class = ie.IECLASS_RAWKEY, .code = @intCast(i) };
        try testing.expect(push(&full, &typed));
    }
    try testing.expect(!push(&full, &up));
}
