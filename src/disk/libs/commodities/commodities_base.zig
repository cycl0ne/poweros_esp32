// SPDX-License-Identifier: MIT
//! commodities.library's base, and the shapes behind the public ones.
//!
//! A program holds a `CxObj` and a `CxMsg` only as handles; behind them
//! are `Object` and `Message`. An object is a node on its parent's list -
//! a broker on the base's list of brokers - with a list of its own for
//! what is attached to it, and what its kind needs in `data`. A message
//! is an exec message carrying one input event, the object it goes to
//! next and a stack of the objects to come back to when a list it was
//! diverted into is done.
//!
//! **The locks.** The network - the brokers, every object's list, flags
//! and data - is under `lock`, a semaphore: each call that changes the
//! network takes it for that change and waits for nothing else while it
//! has it. The handler runs on input.device's task, where nothing may
//! wait, and only tries for it (AttemptSemaphore); while a program has
//! it, the handler keeps the events in `held` and passes them through at
//! its next round, in order. `queue`, where AddIEvents puts its messages
//! for the handler, is under `queue_lock`, a spinlock, because a program
//! adds to it while the handler takes from it. `held`, `routing` and
//! `returned` are the handler's own. Putting the handler on input.device's
//! chain and taking it off is under `handler_lock`, so two programs making
//! the first broker, or deleting the last, at once do it once.

const sdk = @import("sdk");
const exec = sdk.exec;
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const InputEvent = ie.InputEvent;
const ExecBase = sdk.interface.exec.ExecBase;
const KeymapBase = sdk.interface.keymap.KeymapBase;

pub const CxBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    /// keymap.library, open while the library is: ParseIX and
    /// InvertKeyMap ask it which key makes a character.
    keymap_base: ?*KeymapBase = null,
    /// The brokers, highest priority first.
    brokers: exec.List = .{},
    /// The network's lock.
    lock: exec.SignalSemaphore = .{},
    /// Putting the handler on input.device's chain and taking it off.
    handler_lock: exec.SignalSemaphore = .{},
    /// input.device, open while the handler is on its chain.
    input_io: exec.IOStdReq = .{},
    /// The handler, priority 53: before the windowing system (50) and
    /// the console (45).
    handler: exec.Interrupt = .{},
    /// 1 while the handler is on the chain.
    handler_on: u32 = 0,
    /// Messages AddIEvents made, for the handler's next round.
    queue: exec.List = .{},
    queue_lock: exec.Lock = .{},
    /// Events the handler could not take through the network yet, oldest
    /// first.
    held: exec.List = .{},
    /// The messages going through the network in this round.
    routing: exec.List = .{},
    /// The messages whose events the handler gave back in its last
    /// round: input.device's other handlers read them until it calls
    /// again, which frees them.
    returned: exec.List = .{},
    /// Where every message the library sends a program comes back:
    /// replied messages wait here to be freed.
    reply_port: exec.MsgPort = .{ .flags = exec.PA_IGNORE },

    /// This library as a caller sees it, to call its own functions
    /// through the jump table.
    pub fn iface(base: *CxBase) *sdk.interface.commodities.CxBase {
        return @ptrCast(base);
    }
};

/// The base from exec's Library header.
pub fn cxBase(lib: *exec.Library) *CxBase {
    return @fieldParentPtr("lib", lib);
}

/// The base from the interface's handle.
pub fn fromInterface(lib: *sdk.interface.commodities.CxBase) *CxBase {
    return @ptrCast(@alignCast(lib));
}

// --- objects -------------------------------------------------------------------

/// On a list.
pub const COF_INLIST: u32 = 1;
/// Acting on what reaches it; cx.COF_ACTIVE.
pub const COF_ENABLE: u32 = cx.COF_ACTIVE;

/// What a broker keeps: copies of its NewBroker's strings, who made it,
/// where its commands go.
pub const Broker = extern struct {
    name: [cx.CBD_NAMELEN]u8 = @splat(0),
    title: [cx.CBD_TITLELEN]u8 = @splat(0),
    descr: [cx.CBD_DESCRLEN]u8 = @splat(0),
    task: ?*exec.Task = null,
    port: ?*exec.MsgPort = null,
};

/// What each kind of object keeps.
pub const Data = extern union {
    filter: cx.InputXpression,
    send: extern struct { port: ?*exec.MsgPort, id: i32 },
    signal: extern struct { task: ?*exec.Task, signal: u32 },
    /// The program's events; null swallows.
    translate: ?*const InputEvent,
    broker: Broker,
    debug: i32,
    custom: extern struct { action: ?cx.CustomFn, id: i32 },
};

pub const Object = extern struct {
    /// On its parent's list. A broker's `name` is its own copy.
    node: exec.Node = .{},
    /// CX_.
    kind: u32 = cx.CX_INVALID,
    /// COF_INLIST, COF_ENABLE, cx.COF_SHOW_HIDE.
    flags: u32 = 0,
    /// COERR_ bits.
    err: u32 = 0,
    /// What is attached to it.
    list: exec.List = .{},
    data: Data = .{ .debug = 0 },
};

pub fn objectOf(co: *cx.CxObj) *Object {
    return @ptrCast(@alignCast(co));
}

pub fn handleOf(object: *Object) *cx.CxObj {
    return @ptrCast(object);
}

// --- messages ------------------------------------------------------------------

/// How deep a message may be diverted with a way back: deeper than any
/// network a program builds, and a message stays under 400 bytes on a
/// 64-bit machine.
pub const STACK_SLOTS = 32;
/// A message that has been through this many objects is in a loop: it
/// leaves the network.
pub const TOO_MANY_ECHOES = 1024;

pub const Message = extern struct {
    msg: exec.Message = .{},
    /// The next object: a node on some object's list, or the tail of one,
    /// which sends it back up the stack.
    destination: ?*exec.Node = null,
    /// The sender's or custom object's id, or the command.
    id: i32 = 0,
    /// CXM_.
    kind: u32 = 0,
    /// How many objects it has been through.
    echo: u32 = 0,
    /// How much of `stack` is in use.
    stack_index: u32 = 0,
    /// The objects whose successors come next, as lists are finished.
    stack: [STACK_SLOTS]?*Object = @splat(null),
    /// The event, for CXM_IEVENT.
    event: InputEvent = .{},
};

pub fn messageOf(cxm: *cx.CxMsg) *Message {
    return @ptrCast(@alignCast(cxm));
}

pub fn constMessageOf(cxm: *const cx.CxMsg) *const Message {
    return @ptrCast(@alignCast(cxm));
}

pub fn cxMsgOf(message: *Message) *cx.CxMsg {
    return @ptrCast(message);
}
