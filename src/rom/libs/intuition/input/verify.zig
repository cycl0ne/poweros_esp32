// SPDX-License-Identifier: MPL-2.0
//! Verifies: a window asked before something is done to it, and its reply
//! waited for without anything waiting.
//!
//! A window that listens for the class is sent the message - IDCMP_MENUVERIFY
//! before menus are shown over it, IDCMP_REQVERIFY before its double-click
//! requester goes up, IDCMP_SIZEVERIFY before the user sizes it - and the
//! reply comes back to a port of intuition's own, which signals the input
//! task. The input task keeps taking events meanwhile, and whoever started
//! the verify decides what they mean; when the reply is there, or thirty
//! ticks have passed, or the caller gives up, the answer goes back to it by
//! what the verify was for. One verify is out at a time: they start from
//! the input task only, and only when nothing else has the input.
//!
//! A window that does not listen is as good as one that said yes, at once.
//! A MENUVERIFY `MENUHOT` replied with `code` set to anything else is a no;
//! every other verify cannot be refused. A reply that comes after its
//! verify was given up on is freed when it arrives.

const sdk = @import("sdk");
const exec = sdk.exec;
const intuition = sdk.intuition;
const mn = intuition.menus;
const wn = intuition.windows;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const menus = @import("menus.zig");
const _input = @import("_input.zig");

/// How many ticks - a tenth of a second each - a window has to answer.
const verify_ticks = 30;

/// What a verify is for, which says who hears its answer: the menu
/// session - the active window's menus, a shortcut of its, another
/// window's go-ahead, the double-click requester - or the input task's
/// sizing and zooming of a window.
pub const Purpose = enum(u32) { menus, key, others, dmr, size, zoom };

/// How a verify came out: yes, no, or given up on.
pub const Answer = enum { ok, cancel, abort };

/// The verify out, in the base.
pub const State = extern struct {
    purpose: Purpose = .menus,
    /// The window asked, and the message it was sent; null with none out.
    window: ?*Window = null,
    message: ?*wn.IntuiMessage = null,
    class: u32 = 0,
    code: u32 = 0,
    /// Ticks left before silence counts as an answer.
    timeout: i32 = 0,
    /// Where replies come back: it signals the input task once that runs.
    port: exec.MsgPort = .{ .flags = exec.PA_IGNORE },
};

fn stateOf(ib: *IntuitionBase) *State {
    return &ib.verify;
}

/// The port made ready, when the base is. The input task makes it signal
/// itself when it starts.
pub fn init(ib: *IntuitionBase) void {
    ib.verify = .{};
    ib.verify.port.msg_list.init(.message);
}

/// The window a verify is out to, or null.
pub fn windowOf(ib: *IntuitionBase) ?*Window {
    return stateOf(ib).window;
}

/// What the verify out - or the last one - is for.
pub fn purposeOf(ib: *IntuitionBase) Purpose {
    return stateOf(ib).purpose;
}

/// Ask `w` with `class` and `code`, for `purpose`; the answer comes back
/// by the purpose, at once when the window does not listen or cannot be
/// sent the message.
pub fn start(ib: *IntuitionBase, w: *Window, class: u32, code: u32, purpose: Purpose) void {
    const st = stateOf(ib);
    st.purpose = purpose;
    if (w.idcmp & class == 0 or w.user_port == null) return done(ib, .ok);
    const message = _window.post(ib, w, class, code, null, ib.input.qualifier, &st.port) orelse
        return done(ib, .abort);
    st.window = w;
    st.message = message;
    st.class = class;
    st.code = code;
    st.timeout = verify_ticks;
}

/// The replies that have come back: the one waited for answered, any other
/// freed.
pub fn poll(ib: *IntuitionBase) void {
    const st = stateOf(ib);
    while (ib.sys_base.GetMsg(&st.port)) |m| {
        const im: *wn.IntuiMessage = @ptrCast(@alignCast(m));
        const awaited = st.message == im;
        const code = im.code;
        _window.freeMessage(ib, m);
        if (!awaited) continue;
        st.message = null;
        st.window = null;
        const refused = st.class == wn.IDCMP_MENUVERIFY and st.code == mn.MENUHOT and code != mn.MENUHOT;
        done(ib, if (refused) .cancel else .ok);
    }
}

/// One tick of the time a window has: silence past it is no from a window
/// asked for itself, and yes from one only warned (`MENUWAITING`).
pub fn tick(ib: *IntuitionBase) void {
    const st = stateOf(ib);
    if (st.window == null) return;
    st.timeout -= 1;
    if (st.timeout >= 0) return;
    abort(ib, if (st.class == wn.IDCMP_MENUVERIFY and st.code == mn.MENUWAITING) .ok else .abort);
}

/// Give up waiting: `answer` as though it had come.
pub fn abort(ib: *IntuitionBase, answer: Answer) void {
    drop(ib);
    done(ib, answer);
}

/// Give up waiting with no answer to anyone: the window is gone.
pub fn drop(ib: *IntuitionBase) void {
    const st = stateOf(ib);
    // A reply that comes later is freed by `poll` as one not waited for.
    st.message = null;
    st.window = null;
}

fn done(ib: *IntuitionBase, answer: Answer) void {
    const purpose = stateOf(ib).purpose;
    switch (purpose) {
        .menus, .key, .others, .dmr => menus.verified(ib, purpose, answer),
        .size, .zoom => _input.sizeVerified(ib, purpose, answer),
    }
}
