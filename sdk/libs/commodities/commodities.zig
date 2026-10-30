// SPDX-License-Identifier: MIT
//! commodities.library: programs that watch the input stream and act on
//! it, on the disk in LIBS:.
//!
//! Every event input.device makes passes a network of objects before the
//! windowing system sees it. The network is a list of brokers, one for
//! each program that takes part, highest priority first; under each
//! broker hangs the program's own tree of objects:
//!
//! - a **filter** passes on, down its own list, the events that meet its
//!   condition - a key with its qualifiers, a class of event - written as
//!   a description ("ctrl alt h", `ParseIX`) or as an `InputXpression`;
//! - a **sender** sends the program a copy of each event that reaches it,
//!   with the sender's id, to a port of the program's;
//! - a **signal** object signals a task;
//! - a **translator** puts its own events in place of the one that
//!   reached it - none at all to swallow it;
//! - a **custom** object calls a function of the program's;
//! - a **debug** object prints what reaches it on the serial console.
//!
//! An event goes down a list from its first object; an object it is
//! diverted into (a broker, a filter that matched) sends it through its
//! own list first, and then on to the object after it. What comes out of
//! the last broker is what the windows get.
//!
//! **A hotkey.** A filter for the key, a sender under it, and a
//! translator with no events after the sender, so the key goes to the
//! program and no further (`HotKey`):
//!
//!   const broker = cb.CxBroker(&.{ .name = "Clock", .title = "Clock",
//!       .descr = "Shows the time", .unique = cx.NBU_UNIQUE | cx.NBU_NOTIFY,
//!       .port = port }, null) orelse return;
//!   defer cb.DeleteCxObjAll(broker);
//!   cb.AttachCxObj(broker, cx.HotKey(cb, "ctrl alt c", port, 1));
//!   if (cb.CxObjError(broker) != 0) return;
//!   _ = cb.ActivateCxObj(broker, true);
//!
//! The program then waits on `port`. A CXM_IEVENT message is the hotkey
//! (its `CxMsgID` the sender's id), a CXM_COMMAND one an order from the
//! controller - CXCMD_DISABLE, CXCMD_ENABLE, CXCMD_KILL, ... Every message
//! is replied to. Before the program ends it deletes its broker with
//! everything under it, and replies to whatever is still on its port.
//!
//! A custom object's function runs on input.device's task, inside the
//! network: like an input handler it may not wait. It may look at and
//! change the message's event, divert, route or dispose of the message,
//! add events (AddIEvents: they go through the network in the same
//! round) and signal - nothing that creates or deletes objects.

const exec = @import("../exec/exec.zig");
const ie = @import("../../devices/inputevent.zig");
const kbd = @import("../../devices/keyboard.zig");
const keymap = @import("../keymap/keymap.zig");
const InputEvent = ie.InputEvent;
const ExecBase = @import("../../interface/exec.zig").ExecBase;

pub const COMMODITIESNAME = "commodities.library";
/// The version that has everything here.
pub const COMMODITIES_VERSION = 1;

/// The base, for the functions.
pub const CxBase = @import("../../interface/commodities.zig").CxBase;

/// An object of the network. Only the library makes and reads one.
pub const CxObj = opaque {};

/// A message of the network: an exec message, which a sender puts on the
/// program's port and the program replies to.
pub const CxMsg = opaque {
    /// The exec message it is, for ReplyMsg.
    pub fn message(cxm: *CxMsg) *exec.Message {
        return @ptrCast(@alignCast(cxm));
    }

    /// The message GetMsg answered, as a commodity message.
    pub fn from(msg: *exec.Message) *CxMsg {
        return @ptrCast(msg);
    }
};

/// A custom object's function: the library's base, the message that
/// reached the object, and the object.
pub const CustomFn = *const fn (cx: *CxBase, cxm: *CxMsg, co: *CxObj) callconv(.c) void;

// --- objects -------------------------------------------------------------------

/// What an object is (CxObjType); CX_INVALID is no object at all.
pub const CX_INVALID: u32 = 0;
/// Passes on, down its list, the events that meet its condition.
pub const CX_FILTER: u32 = 1;
/// Sends the program a copy of each event, with an id.
pub const CX_SEND: u32 = 2;
/// Signals a task for each event.
pub const CX_SIGNAL: u32 = 3;
/// Puts its own events in place of each one.
pub const CX_TRANSLATE: u32 = 4;
/// A program's place in the network, at the top of its tree.
pub const CX_BROKER: u32 = 5;
/// Prints each message on the serial console.
pub const CX_DEBUG: u32 = 6;
/// Calls a function of the program's for each message.
pub const CX_CUSTOM: u32 = 7;

/// Errors an object records (CxObjError), as bits.
/// CxObjError(null): the object was never made.
pub const COERR_ISNULL: u32 = 1;
/// A null object was attached to its list.
pub const COERR_NULLATTACH: u32 = 2;
/// Its last condition made no sense: the filter matches nothing.
pub const COERR_BADFILTER: u32 = 4;
/// A call for another kind of object was made on it.
pub const COERR_BADTYPE: u32 = 8;

// --- messages ------------------------------------------------------------------

/// A message's kind (CxMsgType): an event, which goes through the network
/// and comes to a program from a sender or a custom object.
pub const CXM_IEVENT: u32 = 1;
/// An order from the controller to a broker's program, on the port in
/// its NewBroker; never through the network.
pub const CXM_COMMAND: u32 = 2;

/// A CXM_COMMAND message's id. Please stop acting on input; the broker
/// is to be made inactive.
pub const CXCMD_DISABLE: i32 = 1;
/// Please act on input again; the broker is to be made active.
pub const CXCMD_ENABLE: i32 = 2;
/// Open your window, if you have one.
pub const CXCMD_APPEAR: i32 = 3;
/// Close your window.
pub const CXCMD_DISAPPEAR: i32 = 4;
/// Go away for good.
pub const CXCMD_KILL: i32 = 5;
/// Someone tried to make a broker with your name (NBU_NOTIFY): showing
/// your window is the usual answer.
pub const CXCMD_UNIQUE: i32 = 6;
/// The list of brokers changed: for the controller.
pub const CXCMD_LIST_CHG: i32 = 7;

// --- brokers -------------------------------------------------------------------

pub const NewBroker = extern struct {
    /// NB_VERSION.
    version: u32 = NB_VERSION,
    /// How the broker is found (BrokerCommand) and listed: up to
    /// CBD_NAMELEN - 1 characters are kept.
    name: [*:0]const u8,
    /// What the controller shows of it: up to CBD_TITLELEN - 1 and
    /// CBD_DESCRLEN - 1 characters are kept.
    title: [*:0]const u8,
    descr: [*:0]const u8,
    /// What happens when a broker of the name is there already: NBU_.
    unique: u32 = NBU_DUPLICATE,
    /// COF_SHOW_HIDE when the program has a window to show and hide.
    flags: u32 = 0,
    /// Its place among the brokers, higher first, -128 to 127.
    pri: i32 = 0,
    /// Where CXM_COMMAND messages go; null for a program that takes none,
    /// which gets Ctrl-E for CXCMD_KILL instead.
    port: ?*exec.MsgPort = null,
};

/// NewBroker's version.
pub const NB_VERSION: u32 = 1;

/// How much of a broker's name, title and description is kept, the end
/// of string included.
pub const CBD_NAMELEN = 24;
pub const CBD_TITLELEN = 40;
pub const CBD_DESCRLEN = 40;

/// NewBroker.unique: another broker of the name is made all the same.
pub const NBU_DUPLICATE: u32 = 0;
/// No second broker of the name is made (CBERR_DUP).
pub const NBU_UNIQUE: u32 = 1;
/// The broker of the name is sent CXCMD_UNIQUE.
pub const NBU_NOTIFY: u32 = 2;

/// NewBroker.flags, and BrokerCopy.flags: the program has a window the
/// controller can show and hide (CXCMD_APPEAR, CXCMD_DISAPPEAR).
pub const COF_SHOW_HIDE: u32 = 4;
/// BrokerCopy.flags: the broker is active.
pub const COF_ACTIVE: u32 = 2;

/// CxBroker's error.
pub const CBERR_OK: i32 = 0;
/// No memory.
pub const CBERR_SYSERR: i32 = 1;
/// NBU_UNIQUE, and a broker of the name is there.
pub const CBERR_DUP: i32 = 2;
/// NewBroker.version is not one the library knows.
pub const CBERR_VERSION: i32 = 3;

/// BrokerCommand's answer: sent.
pub const CMDE_OK: i32 = 0;
/// There is no broker of the name.
pub const CMDE_NOBROKER: i32 = -1;
/// The broker has no port (a CXCMD_KILL went as Ctrl-E all the same).
pub const CMDE_NOPORT: i32 = -2;
/// No memory for the message.
pub const CMDE_NOMEM: i32 = -3;

/// A broker as CopyBrokerList copies it: a node on the caller's list,
/// the caller's to read and FreeBrokerList's to free.
pub const BrokerCopy = extern struct {
    /// `name` points at `name_buffer`.
    node: exec.Node = .{},
    name_buffer: [CBD_NAMELEN]u8 = @splat(0),
    title: [CBD_TITLELEN]u8 = @splat(0),
    descr: [CBD_DESCRLEN]u8 = @splat(0),
    /// The task that made it.
    task: ?*exec.Task = null,
    /// Its NewBroker's port.
    port: ?*exec.MsgPort = null,
    /// COF_ACTIVE and COF_SHOW_HIDE.
    flags: u32 = 0,
};

// --- input expressions ---------------------------------------------------------

/// What a filter matches: an event of `class`, whose code has `code`'s
/// bits where `code_mask` has them, and whose qualifiers have
/// `qualifier`'s where `qual_mask` has them - each side widened first by
/// the synonyms in `qual_same`. A class of IECLASS_NULL matches every
/// event; ParseIX writes one.
pub const InputXpression = extern struct {
    /// IX_VERSION.
    version: u32 = IX_VERSION,
    class: u32 = ie.IECLASS_RAWKEY,
    code: u32 = 0,
    code_mask: u32 = 0xFFFF_FFFF,
    qualifier: u32 = 0,
    qual_mask: u32 = IX_NORMALQUALS,
    /// IXSYM_ bits.
    qual_same: u32 = 0,
};
pub const IX = InputXpression;

/// InputXpression's version.
pub const IX_VERSION: u32 = 1;

/// InputXpression.qual_same: either shift is both.
pub const IXSYM_SHIFT: u32 = 1;
/// Either shift or Caps Lock is all three.
pub const IXSYM_CAPS: u32 = 2;
/// Either alt is both.
pub const IXSYM_ALT: u32 = 4;

pub const IXSYM_SHIFTMASK: u32 = ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT;
pub const IXSYM_CAPSMASK: u32 = IXSYM_SHIFTMASK | ie.IEQUALIFIER_CAPSLOCK;
pub const IXSYM_ALTMASK: u32 = ie.IEQUALIFIER_LALT | ie.IEQUALIFIER_RALT;

/// The qualifiers a description compares unless it says otherwise: all
/// but IEQUALIFIER_RELATIVEMOUSE, which says how a mouse reports and not
/// what was held.
pub const IX_NORMALQUALS: u32 = 0x7FFF;

/// Whether `ix` matches everything.
pub fn isNullIX(ix: *const InputXpression) bool {
    return ix.class == ie.IECLASS_NULL;
}

// --- objects made --------------------------------------------------------------

/// A filter for `description` (ParseIX), null for one that matches
/// nothing until SetFilter.
pub fn CxFilter(cx: *CxBase, description: ?[*:0]const u8) ?*CxObj {
    return cx.CreateCxObj(CX_FILTER, @intFromPtr(description), 0);
}

/// A sender: a copy of each event to `port`, with `id`.
pub fn CxSender(cx: *CxBase, port: *exec.MsgPort, id: i32) ?*CxObj {
    return cx.CreateCxObj(CX_SEND, @intFromPtr(port), @as(u32, @bitCast(id)));
}

/// `task` signalled with `signal` (its number) for each event.
pub fn CxSignal(cx: *CxBase, task: *exec.Task, signal: u5) ?*CxObj {
    return cx.CreateCxObj(CX_SIGNAL, @intFromPtr(task), signal);
}

/// A translator that puts `events` in place of each event - null to
/// swallow them. The list stays the caller's (SetTranslate).
pub fn CxTranslate(cx: *CxBase, events: ?*const InputEvent) ?*CxObj {
    return cx.CreateCxObj(CX_TRANSLATE, @intFromPtr(events), 0);
}

/// A debug object, printing `id` with each message.
pub fn CxDebug(cx: *CxBase, id: i32) ?*CxObj {
    return cx.CreateCxObj(CX_DEBUG, @as(u32, @bitCast(id)), 0);
}

/// A custom object: `action` called for each message, with `id` as the
/// message's id.
pub fn CxCustom(cx: *CxBase, action: CustomFn, id: i32) ?*CxObj {
    return cx.CreateCxObj(CX_CUSTOM, @intFromPtr(action), @as(u32, @bitCast(id)));
}

/// A hotkey: a filter for `description` with a sender to `port` (`id`)
/// under it, and a translator with no events after the sender, so the
/// key goes to the program and no further. Null without memory; a bad
/// description is the filter's error, which the broker it is attached to
/// does not show - check `CxObjError` of the result.
pub fn HotKey(cx: *CxBase, description: [*:0]const u8, port: *exec.MsgPort, id: i32) ?*CxObj {
    const filter = CxFilter(cx, description) orelse return null;
    cx.AttachCxObj(filter, CxSender(cx, port, id));
    cx.AttachCxObj(filter, CxTranslate(cx, null));
    if (cx.CxObjError(filter) & COERR_NULLATTACH != 0) {
        cx.DeleteCxObjAll(filter);
        return null;
    }
    return filter;
}

/// The key events that type `string` through `key_map` (null: the
/// default), in the string's order, from the caller's memory: each
/// character by its key, `\n` and `\r` Return, `\t` Tab, `\\` a
/// backslash, and `<description>` the event a ParseIX description names
/// ("<alt f>"). Null for an empty string, when a character has no key or
/// a description makes no sense, and for no memory. FreeIEvents gives the
/// list back.
pub fn InvertString(sys: *ExecBase, cx: *CxBase, string: [*:0]const u8, key_map: ?*const keymap.KeyMap) ?*InputEvent {
    var first: ?*InputEvent = null;
    var last: ?*InputEvent = null;
    var at: usize = 0;
    while (string[at] != 0) {
        var event: InputEvent = .{};
        var made = true;
        switch (string[at]) {
            '\\' => {
                at += 1;
                switch (string[at]) {
                    'n', 'r' => event = .{ .class = ie.IECLASS_RAWKEY, .code = kbd.RAWKEY_RETURN },
                    't' => event = .{ .class = ie.IECLASS_RAWKEY, .code = kbd.RAWKEY_TAB },
                    '\\' => made = cx.InvertKeyMap('\\', &event, key_map),
                    else => {
                        FreeIEvents(sys, first);
                        return null;
                    },
                }
                at += 1;
            },
            '<' => {
                var description: [128:0]u8 = @splat(0);
                var n: usize = 0;
                at += 1;
                while (string[at] != 0 and string[at] != '>') : (at += 1) {
                    if (n < description.len) description[n] = string[at];
                    n += 1;
                }
                if (string[at] != '>' or n >= description.len) made = false else at += 1;
                var ix: InputXpression = .{};
                if (made and cx.ParseIX(&description, &ix) == 0) {
                    event = .{ .class = ix.class, .code = ix.code, .qualifier = ix.qualifier };
                } else made = false;
            },
            else => |c| {
                made = cx.InvertKeyMap(c, &event, key_map);
                at += 1;
            },
        }
        const block = if (made) sys.AllocMem(@sizeOf(InputEvent), exec.MEMF_ANY | exec.MEMF_CLEAR) else null;
        const copy: *InputEvent = @ptrCast(@alignCast(block orelse {
            FreeIEvents(sys, first);
            return null;
        }));
        copy.* = event;
        copy.next = null;
        if (last) |l| l.next = copy else first = copy;
        last = copy;
    }
    return first;
}

/// The events InvertString made, given back. Null does nothing.
pub fn FreeIEvents(sys: *ExecBase, events: ?*InputEvent) void {
    var event = events;
    while (event) |e| {
        event = e.next;
        sys.FreeMem(e, @sizeOf(InputEvent));
    }
}
