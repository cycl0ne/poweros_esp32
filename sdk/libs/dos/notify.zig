// SPDX-License-Identifier: MIT
//! Notification: a program told when a file or a directory changes
//! (StartNotify, EndNotify), and what a handler needs to answer for it.
//!
//! **A program** fills in a NotifyRequest - the name, and how it wants to
//! hear: a NotifyMessage on a port, or a signal - and hands it to
//! StartNotify; the request is the program's and stays where it is until
//! EndNotify. dos turns the name into the handler's own path - an
//! assign's directory written out (`ENV:Sys/x` becomes
//! `Ram Disk:ENV/Sys/x`) - in `full_name`, and sends the request to the
//! handler with ACTION_ADD_NOTIFY.
//!
//! **What a watcher is told of.** A file: a handle that wrote to it closed
//! (not each write, so a file half written is never reported), created,
//! deleted, renamed away or onto, its protection, comment, date or owner
//! changed. A directory: an entry in it created, deleted, renamed, or
//! closed after writing. A name that is not there yet is watched until it
//! appears; a watch follows the object it found until the object is
//! deleted or renamed.
//!
//! **The handler's side** is `Watchers`: one per volume. The handler tells
//! it which of its objects a request's path names, and calls it as objects
//! change; it sends the messages, takes them back as the programs reply
//! (on a port of its own, which the handler waits on beside its packets),
//! and keeps NRF_WAIT_REPLY's promise. An object is a key of the
//! handler's choosing - its node.

const exec = @import("../exec/exec.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;

/// How a watcher wants to hear: a NotifyMessage to `port`; a signal to
/// `task`; with a message, no second one until the first is replied - a
/// change meanwhile is told when it is; told once at the start when the
/// object is there.
pub const NRF_SEND_MESSAGE: u32 = 1 << 0;
pub const NRF_SEND_SIGNAL: u32 = 1 << 1;
pub const NRF_WAIT_REPLY: u32 = 1 << 3;
pub const NRF_NOTIFY_INITIAL: u32 = 1 << 4;

/// A NotifyMessage's `class` and `code`.
pub const NOTIFY_CLASS: u32 = 0x4000_0000;
pub const NOTIFY_CODE: u16 = 0x1234;

/// struct NotifyRequest: what a program watches and how it hears of it.
/// The program's, from StartNotify to EndNotify; `full_name`, `msg_count`
/// and `handler` are dos's and the handler's.
pub const NotifyRequest = extern struct {
    /// nr_Name: the file or directory, as the program names it.
    name: ?[*:0]const u8 = null,
    /// nr_FullName: the handler's own path to it, which dos makes and
    /// frees.
    full_name: ?[*:0]u8 = null,
    /// nr_UserData: the program's.
    user_data: usize = 0,
    /// nr_Flags: NRF_*.
    flags: u32 = 0,
    /// NRF_SEND_MESSAGE: the port the messages go to.
    port: ?*exec.MsgPort = null,
    /// NRF_SEND_SIGNAL: the task, and the number of the signal.
    task: ?*exec.Task = null,
    signal_number: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// nr_MsgCount: messages sent and not replied yet.
    msg_count: u32 = 0,
    /// nr_Handler: the handler that has the request.
    handler: ?*exec.MsgPort = null,
};

/// struct NotifyMessage: what a watcher gets on its port. Reply it with
/// ReplyMsg once read.
pub const NotifyMessage = extern struct {
    message: exec.Message = .{},
    class: u32 = NOTIFY_CLASS,
    code: u16 = NOTIFY_CODE,
    pad: u16 = 0,
    /// The request it is about.
    request: ?*NotifyRequest = null,
};

// --- the handler's side -------------------------------------------------------------

/// A request a handler holds: what it watches - its object, or none while
/// its name is not there - and the messages it has out.
const Watch = struct {
    node: exec.Node = .{},
    request: *NotifyRequest,
    key: ?*anyopaque,
    /// Messages sent and not back.
    out: u32 = 0,
    /// A change came while NRF_WAIT_REPLY held a message back: told once
    /// the last one is replied.
    late: bool = false,
};

/// A message out, and the watch it is for - none once the watch has gone,
/// when the message is only waited for to be freed.
const Sent = struct {
    node: exec.Node = .{},
    watch: ?*Watch,
    message: NotifyMessage = .{},
};

/// A volume's watchers.
pub const Watchers = struct {
    sys: *ExecBase,
    /// Where the programs' replies come back to.
    reply_port: ?*exec.MsgPort = null,
    watches: exec.List = .{},
    sent: exec.List = .{},

    /// Ready to take requests: false without a port for the replies.
    pub fn init(w: *Watchers, sys: *ExecBase) bool {
        w.* = .{ .sys = sys };
        w.watches.init(.unknown);
        w.sent.init(.unknown);
        w.reply_port = sys.CreateMsgPort() orelse return false;
        return true;
    }

    /// Every watch dropped and the port deleted - for a handler that ends;
    /// a message not replied yet is left to its program.
    pub fn deinit(w: *Watchers) void {
        const sys = w.sys;
        w.collect();
        while (w.watches.first()) |node| {
            sys.Remove(node);
            sys.FreeVec(node);
        }
        while (w.sent.first()) |node| sys.Remove(node);
        if (w.reply_port) |port| sys.DeleteMsgPort(port);
        w.reply_port = null;
    }

    /// The signal of the port the replies come to, for the handler's Wait.
    pub fn signals(w: *Watchers) u32 {
        const port = w.reply_port orelse return 0;
        return port.sigMask();
    }

    /// The path a request names on the volume: its full name past the
    /// device or volume part, a leading `/` dropped.
    pub fn pathOf(request: *const NotifyRequest) []const u8 {
        const full = request.full_name orelse return &.{};
        var length: usize = 0;
        while (full[length] != 0) length += 1;
        var start: usize = 0;
        for (full[0..length], 0..) |char, index| {
            if (char == ':') start = index + 1;
        }
        while (start < length and full[start] == '/') start += 1;
        return full[start..length];
    }

    /// ACTION_ADD_NOTIFY: `request` watched on `key`, the object its path
    /// names, or on nothing yet; told at once with NRF_NOTIFY_INITIAL when
    /// the object is there. False without memory.
    pub fn add(w: *Watchers, request: *NotifyRequest, key: ?*anyopaque) bool {
        const sys = w.sys;
        const memory = sys.AllocVec(@sizeOf(Watch), exec.MEMF_CLEAR) orelse return false;
        const watch: *Watch = @ptrCast(@alignCast(memory));
        watch.* = .{ .request = request, .key = key };
        request.msg_count = 0;
        sys.AddTail(&w.watches, &watch.node);
        if (key != null and request.flags & NRF_NOTIFY_INITIAL != 0) w.tell(watch);
        return true;
    }

    /// ACTION_REMOVE_NOTIFY: the request's watch dropped. Its messages
    /// still on the program's port are taken back; one the program has
    /// taken is freed when it is replied. False for a request it has not.
    pub fn remove(w: *Watchers, request: *NotifyRequest) bool {
        const sys = w.sys;
        const watch = w.find(request) orelse return false;
        var it = w.sent.iterator();
        while (it.next()) |node| {
            const sent: *Sent = @fieldParentPtr("node", node);
            if (sent.watch != watch) continue;
            sent.watch = null;
            const port = request.port orelse continue;
            if (sys.RemoveMsg(port, &sent.message.message)) {
                sys.Remove(&sent.node);
                sys.FreeVec(sent);
            }
        }
        request.msg_count = 0;
        sys.Remove(&watch.node);
        sys.FreeVec(watch);
        return true;
    }

    fn find(w: *Watchers, request: *NotifyRequest) ?*Watch {
        var it = w.watches.iterator();
        while (it.next()) |node| {
            const watch: *Watch = @fieldParentPtr("node", node);
            if (watch.request == request) return watch;
        }
        return null;
    }

    /// `key` changed: every watch on it told.
    pub fn changed(w: *Watchers, key: *anyopaque) void {
        var it = w.watches.iterator();
        while (it.next()) |node| {
            const watch: *Watch = @fieldParentPtr("node", node);
            if (watch.key == key) w.tell(watch);
        }
    }

    /// `key` has gone - deleted, or renamed away: its watches wait for
    /// their names again.
    pub fn orphan(w: *Watchers, key: *anyopaque) void {
        var it = w.watches.iterator();
        while (it.next()) |node| {
            const watch: *Watch = @fieldParentPtr("node", node);
            if (watch.key == key) watch.key = null;
        }
    }

    /// Every object gone at once - a volume formatted: every watch waits
    /// for its name again.
    pub fn orphanAll(w: *Watchers) void {
        var it = w.watches.iterator();
        while (it.next()) |node| {
            const watch: *Watch = @fieldParentPtr("node", node);
            watch.key = null;
        }
    }

    /// `key` has come to be at `path` - made, or renamed there: the watches
    /// waiting for that name take it, and with `tell` are told.
    pub fn adopt(w: *Watchers, key: *anyopaque, path: []const u8, tell_them: bool) void {
        var it = w.watches.iterator();
        while (it.next()) |node| {
            const watch: *Watch = @fieldParentPtr("node", node);
            if (watch.key != null or !samePath(pathOf(watch.request), path)) continue;
            watch.key = key;
            if (tell_them) w.tell(watch);
        }
    }

    /// The replies come back: each message freed, and a change held back
    /// by NRF_WAIT_REPLY told once a watch has none out.
    pub fn collect(w: *Watchers) void {
        const sys = w.sys;
        const port = w.reply_port orelse return;
        while (sys.GetMsg(port)) |message| {
            const notify: *NotifyMessage = @fieldParentPtr("message", message);
            const sent: *Sent = @fieldParentPtr("message", notify);
            sys.Remove(&sent.node);
            const watch = sent.watch;
            sys.FreeVec(sent);
            const back = watch orelse continue;
            back.out -|= 1;
            back.request.msg_count -|= 1;
            if (back.out == 0 and back.late) {
                back.late = false;
                w.tell(back);
            }
        }
    }

    /// One watcher told, as it asked.
    fn tell(w: *Watchers, watch: *Watch) void {
        const sys = w.sys;
        const request = watch.request;
        if (request.flags & NRF_SEND_SIGNAL != 0) {
            if (request.task) |task| sys.Signal(task, @as(u32, 1) << @intCast(request.signal_number & 31));
        }
        if (request.flags & NRF_SEND_MESSAGE == 0) return;
        const port = request.port orelse return;
        if (request.flags & NRF_WAIT_REPLY != 0 and watch.out > 0) {
            watch.late = true;
            return;
        }
        const memory = sys.AllocVec(@sizeOf(Sent), exec.MEMF_CLEAR) orelse return;
        const sent: *Sent = @ptrCast(@alignCast(memory));
        sent.* = .{ .watch = watch, .message = .{
            .message = .{ .reply_port = w.reply_port, .length = @sizeOf(NotifyMessage) },
            .request = request,
        } };
        sys.AddTail(&w.sent, &sent.node);
        watch.out += 1;
        request.msg_count += 1;
        sys.PutMsg(port, &sent.message.message);
    }
};

/// A handler's node's path from the root, `a/b/c`, in `into`: any node
/// with a `parent` (null at the root) and a NUL-padded `name`. Empty when
/// it does not fit.
pub fn nodePath(node: anytype, into: []u8) []const u8 {
    var end = into.len;
    var at: ?@TypeOf(node) = node;
    while (at) |it| : (at = it.parent) {
        if (it.parent == null) break;
        var length: usize = 0;
        while (length < it.name.len and it.name[length] != 0) length += 1;
        const separator: usize = if (end == into.len) 0 else 1;
        if (length + separator > end) return &.{};
        if (separator != 0) {
            end -= 1;
            into[end] = '/';
        }
        end -= length;
        @memcpy(into[end..][0..length], it.name[0..length]);
    }
    return into[end..];
}

/// Whether two paths are the same, case aside and a trailing `/` aside.
fn samePath(a: []const u8, b: []const u8) bool {
    const left = trimmed(a);
    const right = trimmed(b);
    if (left.len != right.len) return false;
    for (left, right) |x, y| {
        if (lower(x) != lower(y)) return false;
    }
    return true;
}

fn trimmed(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

/// Lower case for the names a file system compares: ASCII and Latin-1.
fn lower(char: u8) u8 {
    return switch (char) {
        'A'...'Z', 0xC0...0xD6, 0xD8...0xDE => char + 32,
        else => char,
    };
}
