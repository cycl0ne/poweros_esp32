// SPDX-License-Identifier: MIT
//! What the commodities in SYS:Commodities all do the same way, compiled
//! into each of them: where their settings come from, and the broker with
//! the loop that carries out a controller's commands.
//!
//! **Settings.** A commodity is started from its icon as often as from a
//! shell, and takes the same settings either way: `Settings.read` reads
//! the program's own icon's tool types when it was started from one - the
//! first file a program started from an icon is handed is itself - and its
//! command line against the ReadArgs template otherwise. Each setting is
//! then asked for by its tool type's name and its place in the template,
//! and one that is not given leaves the value it had:
//!
//!   var argv: [3]usize = @splat(0);
//!   var asked: Asked = .{};
//!   var settings = Settings.read(sys, dl, NAME, template, &argv) orelse return dos.RETURN_FAIL;
//!   defer settings.done();
//!   settings.standard(&asked);
//!   settings.number("SECONDS", arg_seconds, &seconds);
//!
//! **The broker.** `Commodity.open` makes the port a controller's commands
//! come to and the broker they reach it by, inactive and with nothing
//! under it yet; the program attaches its objects, activates it, and waits
//! on `signals()`. `next` hands out what is on the port, replied to, with
//! CXCMD_DISABLE and CXCMD_ENABLE already carried out - what is left is
//! the program's own business, `.end` being the order to go away.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const icon = sdk.icon;
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IconBase = sdk.interface.icon.IconBase;
const CxBase = sdk.interface.commodities.CxBase;

/// How long a hotkey description is kept.
pub const popkey_len = 128;

/// The three settings every commodity takes.
pub const Asked = struct {
    /// CX_PRIORITY: the broker's place among the others.
    priority: i32 = 0,
    /// CX_POPKEY: the hotkey that brings the window up, for a commodity
    /// that has one.
    popkey: [popkey_len:0]u8 = @splat(0),
    /// CX_POPUP: whether the window is up from the start.
    popup: bool = true,
};

/// Where a program's settings come from: its own icon, or its command
/// line.
pub const Settings = struct {
    sys: *ExecBase,
    dl: *DosBase,
    /// Both set when the program was started from an icon.
    icon_base: ?*IconBase = null,
    object: ?*icon.DiskObject = null,
    /// Set when it was started from a shell.
    rda: ?*dos.RDArgs = null,
    argv: []const usize = &.{},

    /// The settings of a program started from its icon, or its command
    /// line read against `template` into `argv`. Null when ReadArgs
    /// refused the command line, having said so under `name`.
    pub fn read(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8, template: [*:0]const u8, argv: []usize) ?Settings {
        if (fromIcon(sys, dl)) |settings| return settings;
        const rda = dl.ReadArgs(template, argv.ptr, null) orelse {
            _ = dl.PrintFault(dl.IoErr(), name);
            return null;
        };
        return .{ .sys = sys, .dl = dl, .rda = rda, .argv = argv };
    }

    /// The icon and the library it was read with, given back; the command
    /// line's arguments freed.
    pub fn done(settings: *Settings) void {
        if (settings.object) |object| settings.icon_base.?.FreeDiskObject(object);
        if (settings.icon_base) |base| settings.sys.CloseLibrary(base.lib());
        if (settings.rda) |rda| settings.dl.FreeArgs(rda);
        settings.* = .{ .sys = settings.sys, .dl = settings.dl };
    }

    /// Whether the program was started from an icon rather than a shell.
    pub fn started_from_icon(settings: *const Settings) bool {
        return settings.object != null;
    }

    /// A setting as text: the tool type called `tool`, or the argument at
    /// `index` of the template. Null when it is not given. From an icon
    /// the text is the icon's and lasts until `done`.
    pub fn text(settings: *const Settings, tool: [*:0]const u8, index: usize) ?[*:0]const u8 {
        if (settings.object) |object| return settings.icon_base.?.FindToolType(object.tool_types, tool);
        if (index >= settings.argv.len or settings.argv[index] == 0) return null;
        return @ptrFromInt(settings.argv[index]);
    }

    /// A number setting into `into`, left as it is when it is not given.
    /// The template's argument is a /K/N, which ReadArgs has read already.
    pub fn number(settings: *const Settings, tool: [*:0]const u8, index: usize, into: *i32) void {
        if (settings.object) |object| {
            const found = settings.icon_base.?.FindToolType(object.tool_types, tool) orelse return;
            var value: i32 = 0;
            if (settings.dl.StrToLong(found, &value) > 0) into.* = value;
            return;
        }
        if (index >= settings.argv.len or settings.argv[index] == 0) return;
        into.* = @as(*const i32, @ptrFromInt(settings.argv[index])).*;
    }

    /// A YES or NO setting into `into`, left as it is when it is not
    /// given: anything but NO is yes, as a tool type's value is read.
    pub fn yesNo(settings: *const Settings, tool: [*:0]const u8, index: usize, into: *bool) void {
        if (settings.object) |object| {
            const found = settings.icon_base.?.FindToolType(object.tool_types, tool) orelse return;
            into.* = !settings.icon_base.?.MatchToolValue(found, "NO");
            return;
        }
        const found = settings.text(tool, index) orelse return;
        into.* = !sameWord(found, "NO");
    }

    /// A text setting copied into `into`, cut to fit, left as it is when
    /// it is not given.
    pub fn copy(settings: *const Settings, tool: [*:0]const u8, index: usize, into: []u8) void {
        const found = settings.text(tool, index) orelse return;
        copyText(into, found);
    }

    /// CX_PRIORITY, CX_POPKEY and CX_POPUP, in that order in the
    /// template.
    pub fn standard(settings: *const Settings, asked: *Asked, first: usize) void {
        settings.number("CX_PRIORITY", first, &asked.priority);
        settings.copy("CX_POPKEY", first + 1, &asked.popkey);
        settings.yesNo("CX_POPUP", first + 2, &asked.popup);
    }
};

/// The program's own icon, when it was started from one: the first file it
/// was handed is itself. Null when it was started from a shell, or when
/// the icon cannot be read - the command line says instead.
fn fromIcon(sys: *ExecBase, dl: *DosBase) ?Settings {
    var count: u32 = 0;
    const files = dl.GetArgList(&count) orelse return null;
    if (count == 0) return null;
    const program = files[0];
    const name = program.name orelse return null;
    const library = sys.OpenLibrary(icon.ICONNAME, 1) orelse return null;
    const ib: *IconBase = @ptrCast(library);
    const old = dl.CurrentDir(program.lock);
    defer _ = dl.CurrentDir(old);
    const object = ib.GetDiskObject(name) orelse {
        sys.CloseLibrary(library);
        // Started from an icon all the same: there is no command line to
        // read, and the program takes its settings as they come.
        return .{ .sys = sys, .dl = dl };
    };
    return .{ .sys = sys, .dl = dl, .icon_base = ib, .object = object };
}

// --- the broker ----------------------------------------------------------------------

/// What a commodity has to act on.
pub const Event = union(enum) {
    /// An event a sender or a custom object sent, with its id and a copy
    /// of the event itself.
    input: struct { id: i32, event: ie.InputEvent },
    /// CXCMD_DISABLE, done: the broker no longer watches the input
    /// stream. A commodity that leaves something changed while it does -
    /// a pointer hidden, a screen blanked - puts it back here.
    disabled,
    /// CXCMD_ENABLE, done: it watches again.
    enabled,
    /// CXCMD_APPEAR, or CXCMD_UNIQUE - another of this commodity was
    /// started: both ask for the window.
    show,
    /// CXCMD_DISAPPEAR.
    hide,
    /// CXCMD_LIST_CHG: the commodities changed. Only the controller's.
    list_changed,
    /// CXCMD_KILL: go away.
    end,
};

/// A broker, the port its commands come to, and the loop that carries
/// them out.
pub const Commodity = struct {
    sys: *ExecBase,
    cb: *CxBase,
    port: *exec.MsgPort,
    broker: *cx.CxObj,

    pub const Error = error{
        /// No memory for the port or the broker.
        NoMemory,
        /// A commodity of the name runs already (NBU_UNIQUE), and has
        /// been told so.
        Duplicate,
    };

    /// A port and a broker on it, as `nb` says - its `port` is this one -
    /// inactive and with nothing under it yet.
    pub fn open(sys: *ExecBase, cb: *CxBase, nb: cx.NewBroker) Error!Commodity {
        const port = sys.CreateMsgPort() orelse return Error.NoMemory;
        var with_port = nb;
        with_port.port = port;
        var err: i32 = cx.CBERR_OK;
        const broker = cb.CxBroker(&with_port, &err) orelse {
            sys.DeleteMsgPort(port);
            return if (err == cx.CBERR_DUP) Error.Duplicate else Error.NoMemory;
        };
        return .{ .sys = sys, .cb = cb, .port = port, .broker = broker };
    }

    /// The broker with everything under it, then the port with whatever
    /// is still on it answered - in that order, so that nothing arrives
    /// after the port has gone.
    pub fn close(c: *const Commodity) void {
        c.cb.DeleteCxObjAll(c.broker);
        while (c.sys.GetMsg(c.port)) |msg| c.sys.ReplyMsg(msg);
        c.sys.DeleteMsgPort(c.port);
    }

    /// The objects the program built, put under the broker: whether they
    /// were all made.
    pub fn attach(c: *const Commodity, object: ?*cx.CxObj) bool {
        c.cb.AttachCxObj(c.broker, object);
        return c.cb.CxObjError(c.broker) == 0;
    }

    /// The commodity watching the input stream, or not.
    pub fn activate(c: *const Commodity, on: bool) void {
        _ = c.cb.ActivateCxObj(c.broker, on);
    }

    /// What to wait for: the port, and the breaks that stop the program.
    /// A Ctrl-C from before it started is cleared.
    pub fn signals(c: *const Commodity) u32 {
        _ = c.sys.SetSignal(0, breaks);
        return c.port.sigMask() | breaks;
    }

    /// Whether what `Wait` answered says to stop: Ctrl-C, or the Ctrl-E a
    /// KILL reaches a commodity with no port by.
    pub fn stopped(got: u32) bool {
        return got & breaks != 0;
    }

    /// The next thing on the port the program has to act on, answered and
    /// replied to, or null for nothing left. CXCMD_DISABLE and
    /// CXCMD_ENABLE are carried out here and handed on, for a commodity
    /// that has something of its own to put back.
    pub fn next(c: *const Commodity) ?Event {
        while (c.sys.GetMsg(c.port)) |msg| {
            const cxm = cx.CxMsg.from(msg);
            const kind = c.cb.CxMsgType(cxm);
            const id = c.cb.CxMsgID(cxm);
            var event: ie.InputEvent = .{};
            if (c.cb.CxMsgData(cxm)) |data| event = data.*;
            c.sys.ReplyMsg(msg);
            if (kind == cx.CXM_IEVENT) return .{ .input = .{ .id = id, .event = event } };
            switch (id) {
                cx.CXCMD_DISABLE => {
                    c.activate(false);
                    return .disabled;
                },
                cx.CXCMD_ENABLE => {
                    c.activate(true);
                    return .enabled;
                },
                cx.CXCMD_APPEAR, cx.CXCMD_UNIQUE => return .show,
                cx.CXCMD_DISAPPEAR => return .hide,
                cx.CXCMD_LIST_CHG => return .list_changed,
                cx.CXCMD_KILL => return .end,
                else => {},
            }
        }
        return null;
    }

    const breaks = exec.SIGBREAKF_CTRL_C | exec.SIGBREAKF_CTRL_E;
};

// --- text ----------------------------------------------------------------------------

/// `text` into `into`, cut to fit, with its end of string.
pub fn copyText(into: []u8, text: [*:0]const u8) void {
    var at: usize = 0;
    while (text[at] != 0 and at + 1 < into.len) : (at += 1) into[at] = text[at];
    into[at] = 0;
}

/// Whether two words are the same, ignoring the case of ASCII letters.
pub fn sameWord(left: [*:0]const u8, right: [*:0]const u8) bool {
    var at: usize = 0;
    while (true) : (at += 1) {
        const a = if (left[at] >= 'a' and left[at] <= 'z') left[at] - 32 else left[at];
        const b = if (right[at] >= 'a' and right[at] <= 'z') right[at] - 32 else right[at];
        if (a != b) return false;
        if (a == 0) return true;
    }
}
