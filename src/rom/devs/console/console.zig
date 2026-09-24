// SPDX-License-Identifier: MPL-2.0
//! console.device: a terminal in a window.
//!
//! A unit is a window's console: `CMD_WRITE` is a stream of characters and
//! control sequences drawn into it (`term.zig` keeps the cells, `render.zig`
//! draws them), `CMD_READ` the keys typed into that window, through
//! keymap.library. `CONU_CHARMAP` keeps the text, so it puts it back itself
//! when the window is uncovered or sized; `CONU_STANDARD` keeps none and
//! leaves that to the program.
//!
//! **A handler and a task**, as the older console has. The handler is on
//! input.device's chain: it may not draw and it does not - it turns keys
//! into bytes for the active window's unit, takes the window events
//! intuition writes down the chain, and signals the task. The task does
//! what a write does not: the cursor when a window is activated, the text
//! again when a window is uncovered, the grid again when it is sized.
//!
//! A unit's cells and its cursor are guarded by the unit's own semaphore,
//! since a write comes on its caller's task and a repaint on the console's.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const con = sdk.console;
const km = sdk.keymap;
const ie = sdk.devices.inputevent;
const input = sdk.devices.input;
const wn = intuition.windows;
const sc = intuition.screens;
const layers = sdk.layers;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const LayersBase = sdk.interface.layers.LayersBase;
const KeymapBase = sdk.interface.keymap.KeymapBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const term = @import("term.zig");
const render = @import("render.zig");

pub const DEVICE_NAME = con.CONSOLENAME;
const DEVICE_VERSION = 0;
const DEVICE_REVISION = 1;
const BUILD_DATE = "20.9.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// Above the programs it serves, with input.device and the keyboard.
const task_pri = 20;
const stack_size = 8192;
/// Below intuition's 50: it activates a window before a key is looked at.
const handler_pri = 45;
/// How many characters wait for a read.
const ring_size = 512;
/// The most of a selection that is copied into the snip.
const max_snip = 4096;
/// utility.library, for CallHookPkt.
const UTILITY_VERSION = 1;
/// How many pointer events wait for the console's task.
const pointer_ring: u32 = 16;
/// The `io_Length` that says the data runs to a NUL instead of for a
/// stated number of bytes.
const nul_terminated: u64 = ~@as(u64, 0);

pub const interface = sdk.interface.console;
pub const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("console.device: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

/// What has happened to a unit's window that the task must answer.
const TOKEN_REFRESH: u32 = 1 << 0;
const TOKEN_RESIZE: u32 = 1 << 1;
const TOKEN_ACTIVE: u32 = 1 << 2;
const TOKEN_INACTIVE: u32 = 1 << 3;
/// A key asked for the selection: it goes into the snip.
const TOKEN_COPY: u32 = 1 << 4;

/// One console: the public part a program may read, then everything else.
/// Not `extern`: it holds the terminal, which is this tree's own struct.
const Unit = struct {
    /// `io_Unit` points here, and reads wait on its port's list.
    pub_unit: con.ConUnit,
    /// On the device's list of units.
    node: exec.Node = .{},
    base: *ConsoleBase,
    window: *wn.Window,
    layer: ?*sdk.layers.Layer = null,
    rp: *graphics.RastPort,
    /// The terminal and the memory its cells are in.
    grid: term.Term,
    cells: [*]term.Cell,
    cell_count: usize,
    /// The other screen's cells, taken when a program first asks for it.
    alt_cells: ?[*]term.Cell = null,
    /// Where a selection began and where the pointer is now, as cell
    /// numbers; the handler records them and the task acts on them.
    sel_anchor: u32 = 0,
    sel_now: u32 = 0,
    selecting: u8 = 0,
    /// Its window is the active one, as the events say.
    focus: u8 = 0,
    /// Where a character sits in its cell.
    baseline: i32 = 0,
    /// The unit's own keymap, as CD_SETKEYMAP leaves it.
    key_map: km.KeyMap,
    /// What the window's program has typed, waiting to be read.
    ring: [ring_size]u8 = @splat(0),
    head: u32 = 0,
    tail: u32 = 0,
    /// What the task has to answer, from the handler.
    tokens: u32 = 0,
    /// The window is the active one, so the cursor shows.
    active: u8 = 0,
    /// CMD_STOP was given and CMD_START has not been: reads still queue,
    /// and nothing is served out of the ring until they start again.
    stopped: u8 = 0,
    /// This unit is counted in `ConsoleBase.reporting`.
    counted: u8 = 0,
    open_count: u32 = 0,
    pad: u8 = 0,
    /// Held while the cells or the cursor are touched.
    lock: exec.SignalSemaphore = .{ .link = .{ .type = .signalsem } },
};

pub const ConsoleBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    graphics_base: *GraphicsBase,
    intuition_base: *IntuitionBase,
    layers_base: *LayersBase,
    keymap_base: *KeymapBase,
    utility_base: *UtilityBase,
    /// The units, and the semaphore that guards the list.
    units: exec.List = .{},
    list_lock: exec.SignalSemaphore = .{ .link = .{ .type = .signalsem } },
    /// The handler on input.device's chain, and what opened it.
    handler: exec.Interrupt = .{},
    input_io: exec.IOStdReq = .{},
    input_port: ?*exec.MsgPort = null,
    input_open: u8 = 0,
    started: u8 = 0,
    start_signal: i8 = -1,
    pad: u8 = 0,
    starter: ?*exec.Task = null,
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    /// The task's signal, which the handler raises.
    mask: u32 = 0,
    /// What was last selected, NUL terminated, from AllocVec. What a paste
    /// gives, and what GetConSnip copies.
    snip: ?[*:0]u8 = null,
    snip_len: u32 = 0,
    /// Who wants telling when a selection is finished, and the semaphore
    /// that guards the list - held across the call-out, so a hook cannot
    /// be removed while it is running.
    snip_hooks: exec.MinList = .{},
    hook_lock: exec.SignalSemaphore = .{ .link = .{ .type = .signalsem } },
    /// Where the pointer was, as the handler saw it, for the task to read.
    pointer: [pointer_ring]Pointed = @splat(.{}),
    ptr_head: u32 = 0,
    ptr_tail: u32 = 0,
    /// The button is down, so a move is part of a selection.
    tracking: u8 = 0,
    /// How many consoles have asked to be told about the pointer. The
    /// handler may not walk the unit list or take the list lock, so the
    /// count is kept for it, and a write that turns reporting on or off
    /// is what moves it.
    reporting: u32 = 0,
};

fn consoleBase(dev: *exec.Device) *ConsoleBase {
    return @alignCast(@fieldParentPtr("dev", dev));
}

fn stdReq(io: *exec.IORequest) *exec.IOStdReq {
    return @ptrCast(@alignCast(io));
}

fn unitOf(io: *exec.IORequest) ?*Unit {
    const u = io.unit orelse return null;
    return @alignCast(@fieldParentPtr("pub_unit", @as(*con.ConUnit, @ptrCast(@alignCast(u)))));
}

// --- the window's geometry -------------------------------------------------------

fn windowAttr(cb: *ConsoleBase, w: *wn.Window, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    cb.intuition_base.GetWindowAttrs(w, &ask);
    return value;
}

/// An attribute of the screen the window is on.
fn screenAttr(cb: *ConsoleBase, w: *wn.Window, tag: sdk.utility.Tag) usize {
    const screen: *sc.Screen = @ptrFromInt(windowAttr(cb, w, wn.WA_Screen));
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    cb.intuition_base.GetScreenAttrs(screen, &ask);
    return value;
}

fn metric(cb: *ConsoleBase, rp: *graphics.RastPort, tag: sdk.utility.Tag) i32 {
    var value: u32 = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    cb.graphics_base.GetRPAttrs(rp, &ask);
    return @intCast(value);
}

/// Where the cells go on the window, and how many fit.
const Geometry = struct { origin_x: i32, origin_y: i32, cw: i32, ch: i32, baseline: i32, cols: u32, rows: u32, inner_w: i32, inner_h: i32 };

fn geometryOf(cb: *ConsoleBase, w: *wn.Window, rp: *graphics.RastPort) Geometry {
    const cw = @max(metric(cb, rp, graphics.RPTAG_FontWidth), 1);
    const ch = @max(metric(cb, rp, graphics.RPTAG_FontHeight), 1);
    const inner_w: i32 = @intCast(windowAttr(cb, w, wn.WA_InnerWidth));
    const inner_h: i32 = @intCast(windowAttr(cb, w, wn.WA_InnerHeight));
    return .{
        .origin_x = @intCast(windowAttr(cb, w, wn.WA_BorderLeft)),
        .origin_y = @intCast(windowAttr(cb, w, wn.WA_BorderTop)),
        .cw = cw,
        .ch = ch,
        .baseline = metric(cb, rp, graphics.RPTAG_FontBaseline),
        .cols = @intCast(@max(@divTrunc(inner_w, cw), 1)),
        .rows = @intCast(@max(@divTrunc(inner_h, ch), 1)),
        .inner_w = inner_w,
        .inner_h = inner_h,
    };
}

fn layoutOf(u: *Unit) render.Layout {
    const cb = u.base;
    const s: *intuition.Screen = @ptrFromInt(windowAttr(cb, u.window, wn.WA_Screen));
    const dri = cb.intuition_base.GetScreenDrawInfo(s);
    const pens: [*]const graphics.Pen = dri.pens;
    return .{
        .rp = u.rp,
        .origin_x = u.pub_unit.origin_x,
        .origin_y = u.pub_unit.origin_y,
        .cell_width = u.pub_unit.cell_width,
        .cell_height = u.pub_unit.cell_height,
        .baseline = u.baseline,
        .fg = pens[intuition.screens.TEXTPEN],
        .bg = pens[intuition.screens.BACKGROUNDPEN],
        .shine = pens[intuition.screens.SHINEPEN],
        .fill = pens[intuition.screens.FILLPEN],
    };
}

fn geometryInto(u: *Unit, g: Geometry) void {
    u.baseline = g.baseline;
    u.pub_unit.origin_x = g.origin_x;
    u.pub_unit.origin_y = g.origin_y;
    u.pub_unit.cell_width = g.cw;
    u.pub_unit.cell_height = g.ch;
    u.pub_unit.max_x = @intCast(g.cols - 1);
    u.pub_unit.max_y = @intCast(g.rows - 1);
}

// --- drawing, all of it under the unit's lock and its layer's ----------------------

fn lockDrawing(u: *Unit) void {
    const cb = u.base;
    cb.sys_base.ObtainSemaphore(&u.lock);
    if (u.layer) |l| cb.layers_base.LockLayer(l);
}

fn unlockDrawing(u: *Unit) void {
    const cb = u.base;
    if (u.layer) |l| cb.layers_base.UnlockLayer(l);
    cb.sys_base.ReleaseSemaphore(&u.lock);
}

/// How this unit's cursor should look as things stand: filled on the
/// active window, an outline on an inactive one that keeps its text, and
/// nothing at all where the program asked for no cursor or where the
/// console keeps no text - one that keeps none cannot put back what the
/// outline was drawn over.
fn cursorLook(u: *Unit) render.CursorLook {
    if (!u.grid.cursor().visible) return .off;
    if (u.active != 0) return .solid;
    if (u.pub_unit.unit_type == con.CONU_STANDARD) return .off;
    return .ghost;
}

/// The cursor as it is now, wherever it is now.
fn showCursor(u: *Unit) void {
    render.drawCursor(u.base.graphics_base, layoutOf(u), &u.grid, cursorLook(u));
}

/// The cursor off the cell it is on, before anything moves under it.
fn hideCursor(u: *Unit) void {
    render.drawCursor(u.base.graphics_base, layoutOf(u), &u.grid, .off);
}

/// The rows that changed, and the cursor back on top.
fn showChanges(u: *Unit) void {
    const l = layoutOf(u);
    render.drawDirty(u.base.graphics_base, l, &u.grid);
    showCursor(u);
    u.pub_unit.cp_x = @intCast(u.grid.cursor().x);
    u.pub_unit.cp_y = @intCast(u.grid.cursor().y);
}

/// Every cell, the strips beyond them, and the cursor - whose cell is
/// drawn only once, by `showCursor`.
fn showAll(u: *Unit) void {
    const l = layoutOf(u);
    render.drawAll(u.base.graphics_base, l, &u.grid);
    showEdges(u);
    showCursor(u);
}

// --- the ring of typed characters --------------------------------------------------

fn push(u: *Unit, bytes: []const u8) void {
    for (bytes) |c| {
        if (u.head -% u.tail >= ring_size) return;
        u.ring[u.head % ring_size] = c;
        u.head +%= 1;
    }
}

fn take(u: *Unit, into: []u8) usize {
    var n: usize = 0;
    while (n < into.len and u.tail != u.head) : (n += 1) {
        into[n] = u.ring[u.tail % ring_size];
        u.tail +%= 1;
    }
    return n;
}

/// Reads that were waiting, given what is in the ring now. Under Forbid.
fn serveReads(u: *Unit) void {
    if (u.stopped != 0) return;
    const sys = u.base.sys_base;
    const list = &u.pub_unit.msg_port.msg_list;
    while (u.tail != u.head) {
        const node = list.head orelse break;
        if (node.succ == null) break;
        const io: *exec.IORequest = @ptrCast(@alignCast(node));
        sys.Remove(node);
        io.flags &= ~exec.IOF_QUEUED;
        const std_io = stdReq(io);
        const room: usize = @intCast(std_io.length);
        const into: [*]u8 = @ptrCast(std_io.data.?);
        std_io.actual = take(u, into[0..room]);
        sys.ReplyIO(io);
    }
}

// --- the input handler, on input.device's task -------------------------------------

/// The unit of the window that is active, if one of them is.
/// The console of the window that is active. The handler keeps `focus`
/// itself, from the events that say a window became active, rather than
/// asking intuition: it runs on input.device's task, and a call that waits
/// there for a lock intuition holds stops every handler on the chain.
fn activeUnit(cb: *ConsoleBase) ?*Unit {
    var node = cb.units.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const u: *Unit = @fieldParentPtr("node", n);
        if (u.focus != 0) return u;
    }
    return null;
}

fn unitOfWindow(cb: *ConsoleBase, window: ?*anyopaque) ?*Unit {
    var node = cb.units.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const u: *Unit = @fieldParentPtr("node", n);
        if (@as(*anyopaque, @ptrCast(u.window)) == window) return u;
    }
    return null;
}

/// A key's characters, with the cursor keys in their application form when
/// the terminal asked for it.
fn keyBytes(cb: *ConsoleBase, u: *Unit, e: *const ie.InputEvent, buf: []u8) usize {
    const n = cb.keymap_base.MapRawKey(e, buf.ptr, @intCast(buf.len), &u.key_map);
    if (n <= 0) return 0;
    const len: usize = @intCast(n);
    if (u.grid.app_cursor and len == 3 and buf[0] == 0x1B and buf[1] == '[') {
        switch (buf[2]) {
            'A', 'B', 'C', 'D' => buf[1] = 'O',
            else => {},
        }
    }
    // In new-line mode the Return key is a new line and not only a carriage
    // return, so a program that echoes what it reads goes down a row.
    if (u.grid.lnm and len == 1 and buf[0] == '\r' and buf.len > 1) {
        buf[1] = '\n';
        return 2;
    }
    return len;
}

/// What is selected in `u`, kept as the snip. Under the unit's lock.
fn copySelection(cb: *ConsoleBase, u: *Unit) void {
    // One more than the most that is taken, so that a selection which
    // fills the buffer exactly still has room for the NUL a hook is
    // handed.
    var text: [max_snip + 1]u8 = undefined;
    const n = u.grid.selectionText(text[0..max_snip]);
    if (n == 0) return;
    text[n] = 0;
    setSnip(cb, text[0..n]);
    tellSnipHooks(cb, u, text[0..n :0]);
}

/// Whoever asked to be told that a selection is finished. On the console's
/// own task, so a hook may do rather more than a handler may - but it may
/// not wait, since every other console is waiting on this task behind it.
/// The lock is held across the calls, so a hook cannot be taken off the
/// list while it is running.
fn tellSnipHooks(cb: *ConsoleBase, u: *Unit, text: [:0]const u8) void {
    const sys = cb.sys_base;
    sys.ObtainSemaphore(&cb.hook_lock);
    defer sys.ReleaseSemaphore(&cb.hook_lock);
    var message = con.SnipHookMsg{
        .type = 0,
        .snip_len = @intCast(text.len),
        .snip_data = text.ptr,
    };
    var node: ?*exec.MinNode = cb.snip_hooks.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const hook: *sdk.utility.Hook = @ptrCast(@alignCast(n));
        _ = cb.utility_base.CallHookPkt(hook, &u.pub_unit, &message);
    }
}

/// The snip, from bytes: a copy of its own, NUL terminated.
fn setSnip(cb: *ConsoleBase, bytes: []const u8) void {
    const sys = cb.sys_base;
    const fresh: ?[*:0]u8 = if (bytes.len == 0) null else blk: {
        const memory = sys.AllocVec(bytes.len + 1, exec.MEMF_ANY) orelse return;
        const to: [*]u8 = @ptrCast(memory);
        for (bytes, 0..) |c, i| to[i] = c;
        to[bytes.len] = 0;
        break :blk @ptrCast(to);
    };
    sys.Forbid();
    const old = cb.snip;
    cb.snip = fresh;
    cb.snip_len = @intCast(bytes.len);
    sys.Permit();
    if (old) |o| sys.FreeVec(o);
}

/// The snip into the unit's ring, as though it had been typed.
fn paste(cb: *ConsoleBase, u: *Unit) void {
    const sys = cb.sys_base;
    sys.Forbid();
    defer sys.Permit();
    const snip = cb.snip orelse return;
    var i: u32 = 0;
    while (i < cb.snip_len) : (i += 1) push(u, &[1]u8{snip[i]});
    serveReads(u);
}

/// Which cell of `u` the pointer is over, and whether it is over it at all.
fn cellAt(cb: *ConsoleBase, u: *Unit, x: i32, y: i32) ?u32 {
    const left: i32 = @intCast(windowAttr(cb, u.window, wn.WA_Left));
    const top: i32 = @intCast(windowAttr(cb, u.window, wn.WA_Top));
    const in_x = x - left - u.pub_unit.origin_x;
    const in_y = y - top - u.pub_unit.origin_y;
    if (in_x < 0 or in_y < 0) return null;
    const col: u32 = @intCast(@divTrunc(in_x, u.pub_unit.cell_width));
    const row: u32 = @intCast(@divTrunc(in_y, u.pub_unit.cell_height));
    if (col >= u.grid.cols or row >= u.grid.rows) return null;
    return row * u.grid.cols + col;
}

/// The unit whose window the pointer is over, if the pointer is over one
/// that selects. Windows overlap, so the layer the point belongs to
/// decides, not the first rectangle it falls in.
fn unitUnder(cb: *ConsoleBase, x: i32, y: i32, want: *const fn (*Unit) bool) ?*Unit {
    var node = cb.units.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const u: *Unit = @fieldParentPtr("node", n);
        if (!want(u)) continue;
        if (cellAt(cb, u, x, y) == null) continue;
        const layer = u.layer orelse return u;
        const info: *layers.LayerInfo = @ptrFromInt(screenAttr(cb, u.window, sc.SA_LayerInfo));
        if (cb.layers_base.WhichLayer(info, x, y) != layer) continue;
        return u;
    }
    return null;
}

/// The pointer, as the handler saw it: where it was and what its button
/// was doing. The handler may call nothing that takes a lock - it runs on
/// input.device's task, and the chain is what carries every event to
/// everyone - so it only writes these down and the console's own task
/// works out which console the point is in.
const Pointed = extern struct {
    x: i32 = 0,
    y: i32 = 0,
    code: u32 = 0,
    /// What was held down with it: the shift that overrides mouse
    /// reporting, and the bits a report carries.
    qualifier: u32 = 0,
};

/// A console the pointer may select text in.
fn selects(u: *Unit) bool {
    return u.pub_unit.unit_type == con.CONU_SNIPMAP;
}

/// A console whose program asked to be told where the pointer is.
fn reports(u: *Unit) bool {
    return u.grid.mouse != .off;
}

/// Keep `ConsoleBase.reporting` in step with this unit's terminal. The
/// handler reads that count instead of walking the units, so it is moved
/// wherever the terminal's mouse mode can have changed: after a write,
/// and when the unit goes.
fn countReporting(u: *Unit) void {
    const sys = u.base.sys_base;
    const want: u8 = if (reports(u)) 1 else 0;
    if (want == u.counted) return;
    sys.Disable();
    if (want != 0) u.base.reporting += 1 else u.base.reporting -= 1;
    u.counted = want;
    sys.Enable();
}

/// Shift takes the pointer back from a program that asked to be told
/// about it, so that text can still be selected in such a window - the
/// rule every terminal with mouse reporting has, and without it a program
/// that turns reporting on has the pointer for as long as it runs.
fn shifted(p: Pointed) bool {
    return p.qualifier & (ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT) != 0;
}

/// Which button an event is about, and whether it was let go.
fn buttonOf(code: u32) ?struct { term.MouseButton, bool } {
    const up = code & ie.IECODE_UP_PREFIX != 0;
    return switch (code & ~ie.IECODE_UP_PREFIX) {
        ie.IECODE_LBUTTON => .{ .left, up },
        ie.IECODE_MBUTTON => .{ .middle, up },
        ie.IECODE_RBUTTON => .{ .right, up },
        else => null,
    };
}

/// The pointer, to the program of the console it is over. Nothing is
/// drawn and no selection is touched: the program is being told, and what
/// it does about it is its own business.
fn reportPointer(cb: *ConsoleBase, p: Pointed) bool {
    const u = unitUnder(cb, p.x, p.y, reports) orelse return false;
    const cell = cellAt(cb, u, p.x, p.y) orelse return false;
    const button, const up = buttonOf(p.code) orelse .{ term.MouseButton.left, false };
    const moving = buttonOf(p.code) == null;
    if (!u.grid.wantsMouse(moving, cb.tracking != 0)) return false;
    lockDrawing(u);
    u.grid.reportMouse(
        button,
        cell % u.grid.cols,
        cell / u.grid.cols,
        moving,
        up,
        shifted(p),
        p.qualifier & ie.IEQUALIFIER_CONTROL != 0,
        p.qualifier & (ie.IEQUALIFIER_LALT | ie.IEQUALIFIER_RALT) != 0,
    );
    var reply: [32]u8 = undefined;
    const n = u.grid.takeReply(&reply);
    unlockDrawing(u);
    if (n == 0) return true;
    const sys = cb.sys_base;
    sys.Forbid();
    push(u, reply[0..n]);
    serveReads(u);
    sys.Permit();
    return true;
}

/// A press starts a selection, a move with the button down carries it on,
/// and letting go copies it. On the console's task, so it may ask
/// intuition and layers where the point is.
fn pointed(cb: *ConsoleBase, p: Pointed) void {
    // A console whose program asked about the pointer is told, and keeps
    // the pointer, unless shift is down - which is how text is still
    // selected in such a window.
    if (!shifted(p) and reportPointer(cb, p)) return;
    if (p.code == ie.IECODE_LBUTTON) {
        const u = unitUnder(cb, p.x, p.y, selects) orelse return;
        lockDrawing(u);
        defer unlockDrawing(u);
        const cell = cellAt(cb, u, p.x, p.y) orelse return;
        // Below the last line of output is nothing to select, and a press
        // there starts nothing.
        if (cell / u.grid.cols > u.grid.textEnd() / u.grid.cols) return;
        u.sel_anchor = cell;
        u.sel_now = u.sel_anchor;
        u.selecting = 1;
        u.grid.select(u.sel_anchor, u.sel_anchor + 1);
        showChanges(u);
        return;
    }
    // A move or a release goes to whichever console is selecting.
    var node = cb.units.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const u: *Unit = @fieldParentPtr("node", n);
        if (u.selecting == 0) continue;
        lockDrawing(u);
        defer unlockDrawing(u);
        // Dragged below the last line of output, the end stays where the
        // output ends.
        if (cellAt(cb, u, p.x, p.y)) |cell| {
            const end = u.grid.textEnd();
            u.sel_now = if (cell / u.grid.cols > end / u.grid.cols) end else cell;
        }
        if (p.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
            u.selecting = 0;
            copySelection(cb, u);
        }
        u.grid.select(@min(u.sel_anchor, u.sel_now), @max(u.sel_anchor, u.sel_now) + 1);
        showChanges(u);
        return;
    }
}

/// What the handler saw, to the task: the ring is small, since a move the
/// task is too slow to read is one the next move says again.
fn pushPointer(cb: *ConsoleBase, e: *const ie.InputEvent) void {
    const p = Pointed{ .x = e.x, .y = e.y, .code = e.code, .qualifier = e.qualifier };
    const next = (cb.ptr_head + 1) % pointer_ring;
    if (next == cb.ptr_tail) {
        // Full. A move may be superseded but it may not be lost: dropping
        // the new one leaves the stale one to be acted on, and a selection
        // then sits where the pointer no longer is until it moves again.
        // So the newest entry gives way to this one.
        cb.pointer[(cb.ptr_head + pointer_ring - 1) % pointer_ring] = p;
        return;
    }
    cb.pointer[cb.ptr_head] = p;
    cb.ptr_head = next;
}

fn takePointer(cb: *ConsoleBase) ?Pointed {
    const sys = cb.sys_base;
    sys.Disable();
    defer sys.Enable();
    if (cb.ptr_head == cb.ptr_tail) return null;
    const p = cb.pointer[cb.ptr_tail];
    cb.ptr_tail = (cb.ptr_tail + 1) % pointer_ring;
    return p;
}

/// Shift+Insert, which pastes: `CSI 2 ; 2 ~`.
fn isShiftInsert(bytes: []const u8) bool {
    const want = "\x1b[2;2~";
    if (bytes.len != want.len) return false;
    for (bytes, want) |a, b| {
        if (a != b) return false;
    }
    return true;
}

/// CDInputHandler's work: the events, to the consoles they belong to.
fn handleEvents(cb: *ConsoleBase, events: ?*ie.InputEvent) void {
    const sys = cb.sys_base;
    var signal = false;
    var at = events;
    while (at) |e| : (at = e.next) {
        switch (e.class) {
            ie.IECLASS_RAWKEY => {
                const u = activeUnit(cb) orelse continue;
                var buf: [16]u8 = undefined;
                const n = keyBytes(cb, u, e, &buf);
                // Shift+Insert, and right-Amiga with C or V: the selection
                // copied, or the snip typed in.
                if (isShiftInsert(buf[0..n])) {
                    paste(cb, u);
                    continue;
                }
                if (e.qualifier & ie.IEQUALIFIER_RCOMMAND != 0 and n == 1) {
                    switch (buf[0]) {
                        'v', 'V' => {
                            paste(cb, u);
                            continue;
                        },
                        'c', 'C' => {
                            u.tokens |= TOKEN_COPY;
                            sys.Signal(&cb.task, cb.mask);
                            continue;
                        },
                        else => {},
                    }
                }
                if (n == 0) continue;
                sys.Forbid();
                push(u, buf[0..n]);
                serveReads(u);
                sys.Permit();
            },
            // Where the pointer is and what its button does, written down
            // for the task: this runs on input.device's, which may not wait
            // for a lock intuition holds.
            ie.IECLASS_NEWPOINTERPOS => {
                if (e.code & ~ie.IECODE_UP_PREFIX == ie.IECODE_LBUTTON and e.code & ie.IECODE_UP_PREFIX == 0) cb.tracking = 1;
                // While a selection is being dragged, and whenever any
                // console's program has asked to be told about the
                // pointer. `cb.reporting` is a count the task keeps, so
                // the handler needs no list walk and no lock: it runs on
                // input.device's task and may do neither.
                if (cb.tracking != 0 or cb.reporting != 0) {
                    pushPointer(cb, e);
                    signal = true;
                }
                if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) cb.tracking = 0;
            },
            ie.IECLASS_EVENT => {
                const u = unitOfWindow(cb, e.address) orelse continue;
                u.tokens |= switch (e.code) {
                    ie.IECODE_NEWSIZE => TOKEN_RESIZE,
                    ie.IECODE_REFRESHWINDOW => TOKEN_REFRESH,
                    else => continue,
                };
                signal = true;
            },
            ie.IECLASS_ACTIVEWINDOW, ie.IECLASS_INACTIVEWINDOW => {
                const u = unitOfWindow(cb, e.address) orelse continue;
                u.focus = if (e.class == ie.IECLASS_ACTIVEWINDOW) 1 else 0;
                u.tokens |= if (e.class == ie.IECLASS_ACTIVEWINDOW) TOKEN_ACTIVE else TOKEN_INACTIVE;
                signal = true;
            },
            else => {},
        }
    }
    if (signal) sys.Signal(&cb.task, cb.mask);
}

fn handler(events: ?*ie.InputEvent, data: ?*anyopaque) callconv(.c) ?*ie.InputEvent {
    const cb: *ConsoleBase = @ptrCast(@alignCast(data.?));
    handleEvents(cb, events);
    return events;
}

// --- the task: everything that draws and is not a write ----------------------------

/// The strips beyond the cells, for the window's size now.
fn showEdges(u: *Unit) void {
    render.drawEdges(u.base.graphics_base, layoutOf(u), &u.grid, @intCast(windowAttr(u.base, u.window, wn.WA_InnerWidth)), @intCast(windowAttr(u.base, u.window, wn.WA_InnerHeight)));
}

/// The window was sized: a grid of the new size, with what fits kept.
/// False where it holds as many columns and rows as before, and every
/// cell is where it was.
fn resized(u: *Unit) bool {
    const cb = u.base;
    const sys = cb.sys_base;
    const g = geometryOf(cb, u.window, u.rp);
    // The window changed by fewer pixels than a character: the text is
    // where it was and there is nothing to lay out again.
    if (g.cols == u.grid.cols and g.rows == u.grid.rows) {
        geometryInto(u, g);
        return false;
    }
    // Always into memory of its own, even when the new grid holds as many
    // cells as the old: laying the text out again reads the old grid while
    // it writes the new one, so the two cannot be the same.
    const want = @as(usize, g.cols) * g.rows;
    const memory = sys.AllocMem(want * @sizeOf(term.Cell), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
    const fresh: [*]term.Cell = @ptrCast(@alignCast(memory));
    const on_alt = u.alt_cells != null and u.grid.alternate;
    u.grid.resize(fresh[0..want], g.cols, g.rows);

    // The screen that is not in use has no grid laying it out, so it is
    // given room of the new size and starts empty.
    if (u.alt_cells) |alt| {
        sys.FreeMem(alt, u.cell_count * @sizeOf(term.Cell));
        u.alt_cells = null;
        if (sys.AllocMem(want * @sizeOf(term.Cell), exec.MEMF_ANY | exec.MEMF_CLEAR)) |spare| {
            u.alt_cells = @ptrCast(@alignCast(spare));
        }
    }
    sys.FreeMem(u.cells, u.cell_count * @sizeOf(term.Cell));
    if (on_alt) {
        // The live grid is the other screen, so that is what the new
        // memory holds; the program's own screen is the spare.
        u.cells = u.alt_cells orelse fresh;
        u.alt_cells = fresh;
    } else {
        u.cells = fresh;
    }
    u.cell_count = want;
    geometryInto(u, g);
    return true;
}

fn serveTokens(cb: *ConsoleBase, u: *Unit) void {
    const sys = cb.sys_base;
    sys.Forbid();
    const tokens = u.tokens;
    u.tokens = 0;
    sys.Permit();
    if (tokens == 0) return;

    lockDrawing(u);
    defer unlockDrawing(u);
    if (tokens & TOKEN_ACTIVE != 0) u.active = 1;
    if (tokens & TOKEN_INACTIVE != 0) {
        // The cursor comes off the cell before the window stops being the
        // active one, and goes back in its inactive look below.
        hideCursor(u);
        u.active = 0;
    }
    if (tokens & TOKEN_COPY != 0) copySelection(cb, u);
    if (tokens & TOKEN_RESIZE != 0 and u.pub_unit.flags & con.CONFLAG_NODRAW_ON_NEWSIZE == 0) {
        // Sized by less than a character, the cells stay inside the
        // window and only the strips beyond them changed; unless the
        // window was uncovered as well, they are all that is drawn.
        if (resized(u) or tokens & TOKEN_REFRESH != 0) showAll(u) else showEdges(u);
        return;
    }
    if (tokens & TOKEN_REFRESH != 0) {
        // A console that keeps its text puts it back; one that does not
        // leaves that to the window's program.
        if (u.pub_unit.unit_type != con.CONU_STANDARD) showAll(u) else showCursor(u);
        return;
    }
    if (tokens & (TOKEN_ACTIVE | TOKEN_INACTIVE) != 0) showCursor(u);
}

fn consoleTask(sys: *ExecBase) callconv(.c) void {
    const cb: *ConsoleBase = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const signal = sys.AllocSignal(-1);
    if (signal >= 0) cb.mask = @as(u32, 1) << @intCast(signal);
    if (cb.starter) |starter| {
        cb.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(cb.start_signal));
    }
    if (signal < 0) return;
    while (true) {
        _ = sys.Wait(cb.mask);
        sys.ObtainSemaphoreShared(&cb.list_lock);
        while (takePointer(cb)) |p| pointed(cb, p);
        var node = cb.units.head;
        while (node) |n| : (node = n.succ) {
            if (n.succ == null) break;
            serveTokens(cb, @fieldParentPtr("node", n));
        }
        sys.ReleaseSemaphore(&cb.list_lock);
    }
}

/// The task and the handler, on the first open that has a window.
fn start(cb: *ConsoleBase) bool {
    const sys = cb.sys_base;
    if (cb.started != 0) return cb.started == 1;
    cb.started = 2;
    const stack = sys.AllocMem(stack_size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
    cb.stack = stack;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return false;
    defer sys.FreeSignal(signal);
    cb.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    cb.starter = sys.FindTask(null);
    cb.start_signal = signal;
    _ = sys.AddTask(&cb.task, &consoleTask, null);
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    if (cb.mask == 0) return false;

    cb.input_port = sys.CreateMsgPort() orelse return false;
    cb.input_io = .{};
    cb.input_io.req.message.reply_port = cb.input_port;
    cb.input_io.req.message.length = @sizeOf(exec.IOStdReq);
    if (sys.OpenDevice(input.INPUTNAME, 0, &cb.input_io.req, 0) != 0) return false;
    cb.input_open = 1;
    cb.handler = .{
        .node = .{ .type = .interrupt, .pri = handler_pri, .name = DEVICE_NAME },
        .data = cb,
        .code = &handler,
    };
    cb.input_io.req.command = input.IND_ADDHANDLER;
    cb.input_io.data = &cb.handler;
    _ = sys.DoIO(&cb.input_io.req);
    cb.started = 1;
    return true;
}

// --- the commands ------------------------------------------------------------------

/// The other screen, and the size a program asked for: what the terminal
/// cannot do itself, done after the write that asked for it.
fn answerRequests(u: *Unit) void {
    const cb = u.base;
    switch (u.grid.alt_request) {
        .none => {},
        .enter => {
            u.grid.alt_request = .none;
            const alt = u.alt_cells orelse blk: {
                // Not cleared here: entering writes an empty cell over
                // every one of them, and a screen's worth of memory is
                // not worth clearing twice.
                const memory = cb.sys_base.AllocMem(u.cell_count * @sizeOf(term.Cell), exec.MEMF_ANY) orelse break :blk null;
                u.alt_cells = @ptrCast(@alignCast(memory));
                break :blk u.alt_cells;
            } orelse return;
            u.grid.enterAlternate(alt[0..u.cell_count]);
            showAll(u);
        },
        .leave => {
            u.grid.alt_request = .none;
            u.grid.leaveAlternate(u.cells[0..u.cell_count]);
            showAll(u);
            // The other screen's cells go back with it. What was written
            // there is gone the moment it is left - that is what the
            // other screen is for - so keeping the memory would keep
            // nothing, and a window whose console was once asked for a
            // second screen would hold one for as long as it is open.
            // Asking again is one allocation, against a repaint of the
            // whole window that is paid either way.
            if (u.alt_cells) |alt| {
                cb.sys_base.FreeMem(alt, u.cell_count * @sizeOf(term.Cell));
                u.alt_cells = null;
            }
        },
    }
    if (u.grid.want_cols != 0 or u.grid.want_rows != 0) {
        // A window of that many characters, border included. The size
        // comes back as a window event, and the grid is made then.
        const cols: i32 = @intCast(if (u.grid.want_cols != 0) u.grid.want_cols else u.grid.cols);
        const rows: i32 = @intCast(if (u.grid.want_rows != 0) u.grid.want_rows else u.grid.rows);
        u.grid.want_cols = 0;
        u.grid.want_rows = 0;
        const borders_w: i32 = @intCast(windowAttr(cb, u.window, wn.WA_Width) - windowAttr(cb, u.window, wn.WA_InnerWidth));
        const borders_h: i32 = @intCast(windowAttr(cb, u.window, wn.WA_Height) - windowAttr(cb, u.window, wn.WA_InnerHeight));
        const want_w = cols * u.pub_unit.cell_width + borders_w;
        const want_h = rows * u.pub_unit.cell_height + borders_h;
        const now_w: i32 = @intCast(windowAttr(cb, u.window, wn.WA_Width));
        const now_h: i32 = @intCast(windowAttr(cb, u.window, wn.WA_Height));
        if (want_w != now_w or want_h != now_h) {
            // Not under the layer's lock: sizing a window takes it.
            if (u.layer) |layer| cb.layers_base.UnlockLayer(layer);
            cb.intuition_base.SizeWindow(u.window, want_w - now_w, want_h - now_h);
            if (u.layer) |layer| cb.layers_base.LockLayer(layer);
        }
    }
}

fn write(u: *Unit, bytes: []const u8) void {
    lockDrawing(u);
    defer unlockDrawing(u);
    const cb = u.base;
    // The cursor comes off before the text moves under it.
    hideCursor(u);
    // The screen itself may change hands in the middle of a write - a
    // program asks for the other screen and writes on it at once - and the
    // cells are this unit's to hand over, so the write stops there.
    var rest = bytes;
    while (rest.len != 0) {
        const took = u.grid.writeSome(rest);
        rest = rest[took..];
        answerRequests(u);
    }
    showChanges(u);

    // What the terminal answered - a cursor report, its size - is read
    // like anything typed.
    var reply: [32]u8 = undefined;
    const n = u.grid.takeReply(&reply);
    if (n > 0) {
        cb.sys_base.Forbid();
        push(u, reply[0..n]);
        serveReads(u);
        cb.sys_base.Permit();
    }
    // A write is the only thing that turns mouse reporting on or off.
    countReporting(u);
}

fn read(u: *Unit, io: *exec.IORequest) bool {
    const std_io = stdReq(io);
    if (std_io.data == null) {
        io.err = exec.IOERR_BADADDRESS;
        return true;
    }
    const sys = u.base.sys_base;
    sys.Forbid();
    defer sys.Permit();
    // A stopped unit queues whatever it is given, however much is waiting
    // in the ring: that is what stopping it is for.
    if (u.stopped == 0 and u.tail != u.head) {
        const into: [*]u8 = @ptrCast(std_io.data.?);
        std_io.actual = take(u, into[0..@intCast(std_io.length)]);
        return true;
    }
    io.flags &= ~exec.IOF_QUICK;
    io.flags |= exec.IOF_QUEUED;
    // A queued request is a message again, as PutMsg would make it:
    // WaitIO looks at the node's type, and the reply left there by
    // its last use would let a caller past before this one has run.
    io.message.node.type = .message;
    sys.AddTail(&u.pub_unit.msg_port.msg_list, &io.message.node);
    return false;
}

fn flush(u: *Unit) void {
    const sys = u.base.sys_base;
    sys.Forbid();
    defer sys.Permit();
    const list = &u.pub_unit.msg_port.msg_list;
    while (list.head) |node| {
        if (node.succ == null) break;
        const io: *exec.IORequest = @ptrCast(@alignCast(node));
        sys.Remove(node);
        io.flags &= ~exec.IOF_QUEUED;
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
    }
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const cb = consoleBase(dev);
    const sys = cb.sys_base;
    const std_io = stdReq(io);
    io.err = 0;
    std_io.actual = 0;
    const unit = unitOf(io);
    switch (io.command) {
        exec.CMD_WRITE => if (unit) |u| {
            if (std_io.data) |data| {
                const bytes: [*]const u8 = @ptrCast(data);
                // A length of -1 means the data runs to a NUL rather than
                // for a stated number of bytes.
                var len: usize = undefined;
                if (std_io.length == nul_terminated) {
                    len = 0;
                    while (bytes[len] != 0) len += 1;
                } else len = @intCast(std_io.length);
                write(u, bytes[0..len]);
                std_io.actual = len;
                // What is left to write, and where it would go on from:
                // a caller that loops on a partial write reads both back.
                std_io.length = 0;
                std_io.data = @ptrFromInt(@intFromPtr(data) + len);
            } else io.err = exec.IOERR_BADADDRESS;
        } else {
            io.err = exec.IOERR_OPENFAIL;
        },
        exec.CMD_READ => if (unit) |u| {
            if (!read(u, io)) return;
        } else {
            io.err = exec.IOERR_OPENFAIL;
        },
        exec.CMD_CLEAR => if (unit) |u| {
            sys.Forbid();
            u.tail = u.head;
            sys.Permit();
        },
        // Both halves: the I/O reset every device here does - the waiting
        // reads given back and the typed-in input dropped - and the
        // terminal put back as it was when the console opened.
        exec.CMD_RESET => if (unit) |u| {
            flush(u);
            sys.Forbid();
            u.tail = u.head;
            u.stopped = 0;
            sys.Permit();
            lockDrawing(u);
            u.grid.reset();
            showAll(u);
            unlockDrawing(u);
        },
        exec.CMD_STOP => if (unit) |u| {
            u.stopped = 1;
        },
        exec.CMD_START => if (unit) |u| {
            sys.Forbid();
            u.stopped = 0;
            // Whatever queued while it was stopped is owed an answer now.
            serveReads(u);
            sys.Permit();
        },
        exec.CMD_FLUSH => if (unit) |u| flush(u),
        con.CD_ASKKEYMAP, con.CD_ASKDEFAULTKEYMAP => {
            if (std_io.data == null or std_io.length < @sizeOf(km.KeyMap)) {
                io.err = exec.IOERR_BADLENGTH;
            } else {
                const into: *km.KeyMap = @ptrCast(@alignCast(std_io.data.?));
                into.* = if (unit != null and io.command == con.CD_ASKKEYMAP) unit.?.key_map else cb.keymap_base.AskKeyMapDefault().*;
                std_io.actual = @sizeOf(km.KeyMap);
            }
        },
        con.CD_SETKEYMAP => {
            if (std_io.data == null or std_io.length < @sizeOf(km.KeyMap)) {
                io.err = exec.IOERR_BADLENGTH;
            } else if (unit) |u| {
                u.key_map = @as(*const km.KeyMap, @ptrCast(@alignCast(std_io.data.?))).*;
            }
        },
        con.CD_SETDEFAULTKEYMAP => {
            if (std_io.data == null) {
                io.err = exec.IOERR_BADADDRESS;
            } else {
                // Not copied: the caller's keymap must stay.
                cb.keymap_base.SetKeyMapDefault(@ptrCast(@alignCast(std_io.data.?)));
            }
        },
        else => io.err = exec.IOERR_NOCMD,
    }
    sys.ReplyIO(io);
}

fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const cb = consoleBase(dev);
    const sys = cb.sys_base;
    sys.Forbid();
    defer sys.Permit();
    if (io.flags & exec.IOF_QUEUED == 0) return -1;
    sys.Remove(&io.message.node);
    io.flags &= ~exec.IOF_QUEUED;
    io.err = exec.IOERR_ABORTED;
    sys.ReplyIO(io);
    return 0;
}

// --- the functions -----------------------------------------------------------------

fn lvoCDInputHandler(cb: *ConsoleBase, events: ?*ie.InputEvent) callconv(.c) ?*ie.InputEvent {
    handleEvents(cb, events);
    return events;
}

fn lvoGetConSnip(cb: *ConsoleBase) callconv(.c) ?[*:0]u8 {
    const sys = cb.sys_base;
    sys.Forbid();
    defer sys.Permit();
    const snip = cb.snip orelse return null;
    const memory = sys.AllocVec(cb.snip_len + 1, exec.MEMF_ANY) orelse return null;
    const to: [*]u8 = @ptrCast(memory);
    var i: u32 = 0;
    while (i < cb.snip_len) : (i += 1) to[i] = snip[i];
    to[cb.snip_len] = 0;
    return @ptrCast(to);
}

fn lvoSetConSnip(cb: *ConsoleBase, snip: ?[*:0]const u8) callconv(.c) bool {
    const text = snip orelse {
        setSnip(cb, "");
        return true;
    };
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    setSnip(cb, text[0..n]);
    return cb.snip != null;
}

fn lvoAddSnipHook(cb: *ConsoleBase, hook: *sdk.utility.Hook) callconv(.c) void {
    const sys = cb.sys_base;
    sys.ObtainSemaphore(&cb.hook_lock);
    defer sys.ReleaseSemaphore(&cb.hook_lock);
    sys.AddTail(@ptrCast(&cb.snip_hooks), @ptrCast(&hook.node));
}

fn lvoRemSnipHook(cb: *ConsoleBase, hook: *sdk.utility.Hook) callconv(.c) void {
    const sys = cb.sys_base;
    // The same lock the call-out holds, so this waits for a hook that is
    // running and the caller may free it the moment this returns.
    sys.ObtainSemaphore(&cb.hook_lock);
    defer sys.ReleaseSemaphore(&cb.hook_lock);
    sys.Remove(@ptrCast(&hook.node));
}

fn lvoRawKeyConvert(cb: *ConsoleBase, events: ?*const ie.InputEvent, buffer: [*]u8, length: i32, key_map: ?*const km.KeyMap) callconv(.c) i32 {
    var total: i32 = 0;
    var at = events;
    while (at) |e| : (at = e.next) {
        const room = length - total;
        if (room <= 0) return -1;
        const n = cb.keymap_base.MapRawKey(e, buffer + @as(usize, @intCast(total)), room, key_map);
        if (n < 0) return -1;
        total += n;
    }
    return total;
}

// --- open and close ----------------------------------------------------------------

fn makeUnit(cb: *ConsoleBase, window: *wn.Window, unit_type: i32, flags: u32) ?*Unit {
    const sys = cb.sys_base;
    const rp: *graphics.RastPort = @ptrFromInt(windowAttr(cb, window, wn.WA_RastPort));
    const g = geometryOf(cb, window, rp);
    const count = @as(usize, g.cols) * g.rows;
    const memory = sys.AllocMem(@sizeOf(Unit), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const cells = sys.AllocMem(count * @sizeOf(term.Cell), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        sys.FreeMem(memory, @sizeOf(Unit));
        return null;
    };
    const u: *Unit = @ptrCast(@alignCast(memory));
    const grid: [*]term.Cell = @ptrCast(@alignCast(cells));
    u.* = .{
        .pub_unit = .{ .unit_type = unit_type, .flags = flags, .window = @ptrCast(window) },
        .base = cb,
        .window = window,
        .layer = @ptrFromInt(windowAttr(cb, window, wn.WA_Layer)),
        .rp = rp,
        .grid = term.Term.init(grid[0..count], g.cols, g.rows),
        .cells = grid,
        .cell_count = count,
        .key_map = cb.keymap_base.AskKeyMapDefault().*,
        .node = .{ .type = .unknown, .name = DEVICE_NAME },
    };
    u.pub_unit.msg_port = .{ .flags = exec.PA_IGNORE };
    u.pub_unit.msg_port.msg_list.init(.message);
    sys.InitSemaphore(&u.lock);
    geometryInto(u, g);
    u.active = @intFromBool(windowAttr(cb, window, wn.WA_Active) != 0);
    // A window opened active was activated before there was a console to
    // hear the event, so the first answer comes from the window itself.
    u.focus = u.active;

    sys.ObtainSemaphore(&cb.list_lock);
    sys.AddTail(&cb.units, &u.node);
    sys.ReleaseSemaphore(&cb.list_lock);

    lockDrawing(u);
    showAll(u);
    unlockDrawing(u);
    return u;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    const cb = consoleBase(dev);
    if (io.message.length < @sizeOf(exec.IOStdReq)) return exec.IOERR_OPENFAIL;
    const wanted: i32 = @bitCast(unit_number);
    if (wanted == con.CONU_LIBRARY) {
        // No console: the request is filled in far enough to call the
        // device's own functions.
        dev.open_cnt += 1;
        dev.flags &= ~exec.LIBF_DELEXP;
        io.unit = null;
        return 0;
    }
    if (wanted != con.CONU_STANDARD and wanted != con.CONU_CHARMAP and wanted != con.CONU_SNIPMAP) return exec.IOERR_OPENFAIL;
    const std_io = stdReq(io);
    const window: *wn.Window = @ptrCast(@alignCast(std_io.data orelse return exec.IOERR_OPENFAIL));
    if (!start(cb)) return exec.IOERR_OPENFAIL;
    const u = makeUnit(cb, window, wanted, flags) orelse return exec.IOERR_OPENFAIL;
    u.open_count += 1;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    io.unit = @ptrCast(&u.pub_unit);
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const cb = consoleBase(dev);
    const sys = cb.sys_base;
    dev.open_cnt -= 1;
    const u = unitOf(io) orelse return null;
    u.open_count -= 1;
    if (u.open_count != 0) return null;
    _ = abortIO(dev, io);
    flush(u);
    // Whatever this console asked about the pointer goes with it.
    u.grid.mouse = .off;
    countReporting(u);
    sys.ObtainSemaphore(&cb.list_lock);
    sys.Remove(&u.node);
    sys.ReleaseSemaphore(&cb.list_lock);
    sys.FreeMem(u.cells, u.cell_count * @sizeOf(term.Cell));
    if (u.alt_cells) |alt| sys.FreeMem(alt, u.cell_count * @sizeOf(term.Cell));
    sys.FreeMem(u, @sizeOf(Unit));
    io.unit = null;
    return null;
}

/// The device stays: its task and its handler are the machine's once up.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    _ = seg_list;
    dev.revision = DEVICE_REVISION;
    const cb = consoleBase(dev);
    cb.sys_base = sys_base;
    const gfx = sys_base.OpenLibrary(graphics.GRAPHICSNAME, graphics.GRAPHICS_VERSION) orelse return null;
    const int = sys_base.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        sys_base.CloseLibrary(gfx);
        return null;
    };
    const lay = sys_base.OpenLibrary(sdk.layers.LAYERSNAME, sdk.layers.LAYERS_VERSION) orelse {
        sys_base.CloseLibrary(int);
        sys_base.CloseLibrary(gfx);
        return null;
    };
    const key = sys_base.OpenLibrary(km.KEYMAPNAME, km.KEYMAP_VERSION) orelse {
        sys_base.CloseLibrary(lay);
        sys_base.CloseLibrary(int);
        sys_base.CloseLibrary(gfx);
        return null;
    };
    // For CallHookPkt, which is how a snip hook is called.
    const util = sys_base.OpenLibrary(sdk.interface.utility.NAME, UTILITY_VERSION) orelse {
        sys_base.CloseLibrary(key);
        sys_base.CloseLibrary(lay);
        sys_base.CloseLibrary(int);
        sys_base.CloseLibrary(gfx);
        return null;
    };
    cb.graphics_base = @ptrCast(gfx);
    cb.intuition_base = @ptrCast(int);
    cb.layers_base = @ptrCast(lay);
    cb.keymap_base = @ptrCast(key);
    cb.utility_base = @ptrCast(util);
    cb.snip_hooks.init();
    cb.units.init(.unknown);
    sys_base.InitSemaphore(&cb.list_lock);
    sys_base.InitSemaphore(&cb.hook_lock);
    return dev;
}

const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
    vec(lvoCDInputHandler),
    vec(lvoRawKeyConvert),
    vec(lvoGetConSnip),
    vec(lvoSetConSnip),
    vec(lvoAddSnipHook),
    vec(lvoRemSnipHook),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(ConsoleBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// Cold start under intuition (18), which it opens, and keymap (40).
export const console_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &console_device_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = DEVICE_VERSION,
    .pri = 17,
    .type = .device,
    .name = DEVICE_NAME,
    .id_string = DEVICE_VERSION_STRING[1..],
    .init = &init_table,
};

// --- tests --------------------------------------------------------------------------

const testing = std.testing;

/// Just enough of a base for the pointer ring, which touches nothing else.
fn ringOnly() ConsoleBase {
    var cb: ConsoleBase = undefined;
    cb.pointer = @splat(.{});
    cb.ptr_head = 0;
    cb.ptr_tail = 0;
    return cb;
}

fn pointerEvent(x: i32) ie.InputEvent {
    return .{ .class = ie.IECLASS_NEWPOINTERPOS, .code = ie.IECODE_NOBUTTON, .x = x, .y = 0 };
}

test "a full pointer ring loses the newest move, never the newest event" {
    var cb = ringOnly();

    // It holds one fewer than its length: head meeting tail is empty.
    var i: i32 = 0;
    while (i < pointer_ring - 1) : (i += 1) {
        const e = pointerEvent(i);
        pushPointer(&cb, &e);
    }
    try testing.expectEqual(pointer_ring - 1, cb.ptr_head);

    // One more than it can hold. The oldest entries must stay - they are
    // what the task has not read yet - and the newest gives way, so what
    // is on the ring still ends at where the pointer really is.
    const over = pointerEvent(999);
    pushPointer(&cb, &over);
    try testing.expectEqual(pointer_ring - 1, cb.ptr_head);
    try testing.expectEqual(@as(i32, 0), cb.pointer[0].x);
    try testing.expectEqual(@as(i32, 999), cb.pointer[pointer_ring - 2].x);

    // And again: it is always the last one that gives way.
    const over2 = pointerEvent(1000);
    pushPointer(&cb, &over2);
    try testing.expectEqual(@as(i32, 1000), cb.pointer[pointer_ring - 2].x);
    try testing.expectEqual(@as(i32, 0), cb.pointer[0].x);
}

test "a pointer event carries its qualifier, which is what shift is read from" {
    var cb = ringOnly();
    var e = pointerEvent(4);
    e.code = ie.IECODE_LBUTTON;
    e.qualifier = ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_CONTROL;
    pushPointer(&cb, &e);
    try testing.expect(shifted(cb.pointer[0]));
    try testing.expectEqual(ie.IECODE_LBUTTON, cb.pointer[0].code);

    // And which button it was, with a release told from a press.
    const b, const up = buttonOf(ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX).?;
    try testing.expectEqual(term.MouseButton.right, b);
    try testing.expect(up);
    try testing.expect(buttonOf(ie.IECODE_NOBUTTON) == null);
}
