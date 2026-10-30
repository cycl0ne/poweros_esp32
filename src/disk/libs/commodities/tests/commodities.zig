// SPDX-License-Identifier: MIT
//! Host tests of commodities.library: the library made from its ROM tag
//! on the ROM's exec and keymap.library and spoken to through its jump
//! table, with the handler's rounds driven by the test.
//!
//! There is no input.device here, so the handler never goes onto a
//! chain: each test calls `_input.round` itself with the events
//! input.device would hand it, and reads what comes out.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const kbd = sdk.devices.keyboard;
const host = @import("host_rom");
const kexec = host.exec;
const commodities_init = @import("../commodities_init.zig");
const _base = @import("../commodities_base.zig");
const _input = @import("../input/_input.zig");

const testing = std.testing;
const CxBase = sdk.interface.commodities.CxBase;
const ExecBase = sdk.interface.exec.ExecBase;
const InputEvent = ie.InputEvent;

test {
    _ = @import("../commodities_lvo.zig");
}

/// exec, keymap.library and commodities.library opened.
const Rig = struct {
    keymap: *exec.Library = undefined,
    library: *exec.Library = undefined,
    cb: *CxBase = undefined,

    fn init(rig: *Rig) !void {
        try kexec.setUp();
        const keymap = kexec.InitResident(kexec.SysBase, &host.keymap.keymap_library_tag, null) orelse return error.NoKeymap;
        rig.keymap = @ptrCast(@alignCast(keymap));
        const lib = kexec.InitResident(kexec.SysBase, &commodities_init.commodities_library_tag, null) orelse return error.NoCommodities;
        rig.library = @ptrCast(@alignCast(lib));
        rig.cb = @ptrCast(rig.sys().OpenLibrary(cx.COMMODITIESNAME, cx.COMMODITIES_VERSION) orelse return error.NoBase);
    }

    fn sys(_: *Rig) *ExecBase {
        return kexec.SysBase.iface();
    }

    /// The library as it is inside.
    fn real(rig: *Rig) *_base.CxBase {
        return _base.fromInterface(rig.cb);
    }

    /// One round of the handler.
    fn round(rig: *Rig, events: ?*InputEvent) ?*InputEvent {
        return _input.round(rig.real(), events);
    }

    /// The library closed and expunged, keymap.library taken down, and
    /// nothing left behind.
    fn deinit(rig: *Rig) !void {
        rig.sys().CloseLibrary(rig.cb.lib());
        _ = rig.sys().RemLibrary(rig.library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, cx.COMMODITIESNAME) == null);
        kexec.Remove(kexec.SysBase, &rig.keymap.node);
        kexec.freeLibraryMemory(kexec.SysBase, rig.keymap);
        try kexec.expectNoLeaks();
        kexec.deinit();
    }
};

fn key(code: u32, qualifier: u32) InputEvent {
    return .{ .class = ie.IECLASS_RAWKEY, .code = code, .qualifier = qualifier };
}

/// `events` linked in their order.
fn chain(events: []InputEvent) ?*InputEvent {
    for (events, 0..) |*event, n| event.next = if (n + 1 < events.len) &events[n + 1] else null;
    return if (events.len == 0) null else &events[0];
}

/// The codes of a chain, in its order.
fn codes(buffer: []u32, events: ?*InputEvent) []u32 {
    var n: usize = 0;
    var event = events;
    while (event) |e| : (event = e.next) {
        buffer[n] = e.code;
        n += 1;
    }
    return buffer[0..n];
}

fn broker(rig: *Rig, name: [*:0]const u8, unique: u32, port: ?*exec.MsgPort, err: *i32) ?*cx.CxObj {
    return rig.cb.CxBroker(&.{ .name = name, .title = "Test", .descr = "A broker of the tests", .unique = unique, .port = port }, err);
}

test "ParseIX reads a class, qualifiers, upstroke and a key" {
    var rig: Rig = .{};
    try rig.init();
    const cb = rig.cb;
    var ix: cx.InputXpression = .{};

    try testing.expectEqual(@as(i32, 0), cb.ParseIX("rawkey lshift f1", &ix));
    try testing.expectEqual(ie.IECLASS_RAWKEY, ix.class);
    try testing.expectEqual(kbd.RAWKEY_F1, ix.code);
    try testing.expectEqual(ie.IEQUALIFIER_LSHIFT, ix.qualifier);
    try testing.expectEqual(cx.IX_NORMALQUALS, ix.qual_mask);

    // A character is its key on the default keymap, with what it takes.
    try testing.expectEqual(@as(i32, 0), cb.ParseIX("CTRL A", &ix));
    try testing.expectEqual(kbd.RAWKEY_A, ix.code);
    try testing.expect(ix.qualifier & ie.IEQUALIFIER_CONTROL != 0);
    try testing.expect(ix.qualifier & (ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT) != 0);

    // A synonym, a qualifier that may be held, and upstroke.
    try testing.expectEqual(@as(i32, 0), cb.ParseIX("-caps alt upstroke space", &ix));
    try testing.expectEqual(cx.IXSYM_ALT | cx.IXSYM_CAPS, ix.qual_same);
    try testing.expectEqual(cx.IXSYM_ALTMASK, ix.qualifier);
    try testing.expectEqual(@as(u32, 0), ix.qual_mask & cx.IXSYM_CAPSMASK);
    try testing.expectEqual(kbd.RAWKEY_SPACE | ie.IECODE_UP_PREFIX, ix.code);

    // A button, and no key at all: any code.
    try testing.expectEqual(@as(i32, 0), cb.ParseIX("rawmouse mouse_leftpress", &ix));
    try testing.expectEqual(ie.IECLASS_RAWMOUSE, ix.class);
    try testing.expectEqual(ie.IECODE_LBUTTON, ix.code);
    try testing.expectEqual(@as(i32, 0), cb.ParseIX("ctrl", &ix));
    try testing.expectEqual(@as(u32, 0), ix.code_mask);
    try testing.expectEqual(@as(i32, 0), cb.ParseIX("ctrl -upstroke", &ix));
    try testing.expectEqual(@as(u32, 0), ix.code_mask);
    try testing.expectEqual(@as(i32, 0), cb.ParseIX("ctrl upstroke", &ix));
    try testing.expectEqual(ie.IECODE_UP_PREFIX, ix.code_mask);

    // What makes no sense.
    try testing.expectEqual(@as(i32, -1), cb.ParseIX("ctrl nosuchkey", &ix));
    try testing.expectEqual(@as(i32, -1), cb.ParseIX("f1 f2", &ix));
    try testing.expectEqual(@as(i32, -1), cb.ParseIX("rawmouse f1", &ix));
    try testing.expectEqual(@as(i32, -2), cb.ParseIX(null, &ix));
    try testing.expectEqual(@as(i32, -2), cb.ParseIX(" , ", &ix));
    try testing.expect(!cb.MatchIX(&key(kbd.RAWKEY_F1, 0), &ix));

    try rig.deinit();
}

test "MatchIX widens synonyms and ignores what may be held" {
    var rig: Rig = .{};
    try rig.init();
    const cb = rig.cb;
    var ix: cx.InputXpression = .{};

    try testing.expectEqual(@as(i32, 0), cb.ParseIX("shift f1", &ix));
    try testing.expect(cb.MatchIX(&key(kbd.RAWKEY_F1, ie.IEQUALIFIER_RSHIFT), &ix));
    try testing.expect(cb.MatchIX(&key(kbd.RAWKEY_F1, ie.IEQUALIFIER_LSHIFT), &ix));
    try testing.expect(!cb.MatchIX(&key(kbd.RAWKEY_F1, 0), &ix));
    try testing.expect(!cb.MatchIX(&key(kbd.RAWKEY_F1 | ie.IECODE_UP_PREFIX, ie.IEQUALIFIER_LSHIFT), &ix));
    try testing.expect(!cb.MatchIX(&key(kbd.RAWKEY_F1, ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_CONTROL), &ix));
    // The pointer's motion bit is outside the normal qualifiers.
    try testing.expect(cb.MatchIX(&key(kbd.RAWKEY_F1, ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RELATIVEMOUSE), &ix));
    // Caps Lock is a qualifier like the others, unless it may be held.
    try testing.expect(!cb.MatchIX(&key(kbd.RAWKEY_F1, ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_CAPSLOCK), &ix));
    try testing.expectEqual(@as(i32, 0), cb.ParseIX("-capslock shift f1", &ix));
    try testing.expect(cb.MatchIX(&key(kbd.RAWKEY_F1, ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_CAPSLOCK), &ix));

    // Upstroke comes before the key.
    try testing.expectEqual(@as(i32, -1), cb.ParseIX("f1 -upstroke", &ix));
    try testing.expectEqual(@as(i32, 0), cb.ParseIX("-upstroke f1", &ix));
    try testing.expect(cb.MatchIX(&key(kbd.RAWKEY_F1 | ie.IECODE_UP_PREFIX, 0), &ix));
    try testing.expect(cb.MatchIX(&key(kbd.RAWKEY_F1, 0), &ix));

    // A button's own qualifier does not count; another's does.
    try testing.expectEqual(@as(i32, 0), cb.ParseIX("rawmouse mouse_rightpress", &ix));
    const right: InputEvent = .{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_RBUTTON, .qualifier = ie.IEQUALIFIER_RBUTTON };
    try testing.expect(cb.MatchIX(&right, &ix));
    try testing.expect(!cb.MatchIX(&.{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_RBUTTON, .qualifier = ie.IEQUALIFIER_RBUTTON | ie.IEQUALIFIER_LEFTBUTTON }, &ix));
    try testing.expectEqual(@as(i32, 0), cb.ParseIX("rawmouse lbutton mouse_rightpress", &ix));
    try testing.expect(!cb.MatchIX(&right, &ix));
    try testing.expect(cb.MatchIX(&.{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_RBUTTON, .qualifier = ie.IEQUALIFIER_RBUTTON | ie.IEQUALIFIER_LEFTBUTTON }, &ix));

    // A null class matches every event.
    const everything: cx.InputXpression = .{ .class = ie.IECLASS_NULL };
    try testing.expect(cb.MatchIX(&.{ .class = ie.IECLASS_TIMER }, &everything));

    try rig.deinit();
}

test "InvertKeyMap and InvertString turn characters into keys" {
    var rig: Rig = .{};
    try rig.init();
    const cb = rig.cb;
    const sys = rig.sys();

    var event: InputEvent = .{};
    try testing.expect(cb.InvertKeyMap('a', &event, null));
    try testing.expectEqual(ie.IECLASS_RAWKEY, event.class);
    try testing.expectEqual(kbd.RAWKEY_A, event.code);
    try testing.expectEqual(@as(u32, 0), event.qualifier);
    // On "deutsch" é is the dead acute and then e: the dead key comes as
    // the key before.
    try testing.expect(cb.InvertKeyMap(0xE9, &event, null));
    try testing.expectEqual(@as(u32, 0x12), event.code);
    const before: u32 = @bitCast(event.x);
    try testing.expect(before & ie.IE_PREVKEY_VALID != 0);
    try testing.expectEqual(@as(u32, 0x0C), (before >> 8) & 0xFF);
    try testing.expect(!cb.InvertKeyMap(0x100, &event, null));

    const typed = cx.InvertString(sys, cb, "ab\\n<f1>", null) orelse return error.NoEvents;
    var buffer: [8]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ kbd.RAWKEY_A, 0x35, kbd.RAWKEY_RETURN, kbd.RAWKEY_F1 }, codes(&buffer, typed));
    cx.FreeIEvents(sys, typed);
    try testing.expect(cx.InvertString(sys, cb, "<nosuchkey>", null) == null);
    try testing.expect(cx.InvertString(sys, cb, "a\\q", null) == null);
    try testing.expect(cx.InvertString(sys, cb, "", null) == null);

    try rig.deinit();
}

test "brokers: unique names, notice to the first, commands by name, the list" {
    var rig: Rig = .{};
    try rig.init();
    const cb = rig.cb;
    const sys = rig.sys();
    const port = sys.CreateMsgPort() orelse return error.NoPort;

    var err: i32 = -1;
    try testing.expect(rig.cb.CxBroker(&.{ .version = 7, .name = "x", .title = "", .descr = "" }, &err) == null);
    try testing.expectEqual(cx.CBERR_VERSION, err);

    const first = broker(&rig, "Hotkeys", cx.NBU_UNIQUE | cx.NBU_NOTIFY, port, &err) orelse return error.NoBroker;
    try testing.expectEqual(cx.CBERR_OK, err);
    try testing.expectEqual(cx.CX_BROKER, cb.CxObjType(first));
    try testing.expect(broker(&rig, "Hotkeys", cx.NBU_UNIQUE | cx.NBU_NOTIFY, null, &err) == null);
    try testing.expectEqual(cx.CBERR_DUP, err);
    // The first was told someone else tried.
    const notice = cx.CxMsg.from(sys.GetMsg(port) orelse return error.NoNotice);
    try testing.expectEqual(cx.CXM_COMMAND, cb.CxMsgType(notice));
    try testing.expectEqual(cx.CXCMD_UNIQUE, cb.CxMsgID(notice));
    try testing.expect(cb.CxMsgData(notice) == null);
    sys.ReplyMsg(notice.message());

    const second = broker(&rig, "Blanker", cx.NBU_DUPLICATE, null, &err) orelse return error.NoBroker;
    try testing.expectEqual(cx.CMDE_OK, cb.BrokerCommand("Hotkeys", cx.CXCMD_DISABLE));
    const command = cx.CxMsg.from(sys.GetMsg(port) orelse return error.NoCommand);
    try testing.expectEqual(cx.CXCMD_DISABLE, cb.CxMsgID(command));
    sys.ReplyMsg(command.message());
    try testing.expectEqual(cx.CMDE_NOPORT, cb.BrokerCommand("Blanker", cx.CXCMD_ENABLE));
    try testing.expectEqual(cx.CMDE_NOBROKER, cb.BrokerCommand("Nobody", cx.CXCMD_ENABLE));

    try testing.expect(!cb.ActivateCxObj(first, true));
    try testing.expect(cb.ActivateCxObj(first, true));
    var list: exec.List = .{};
    list.init(.unknown);
    try testing.expectEqual(@as(i32, 2), cb.CopyBrokerList(&list));
    const copy: *cx.BrokerCopy = @ptrCast(@alignCast(list.first().?));
    try testing.expectEqualStrings("Hotkeys", std.mem.sliceTo(&copy.name_buffer, 0));
    try testing.expectEqualStrings("A broker of the tests", std.mem.sliceTo(&copy.descr, 0));
    try testing.expectEqual(cx.COF_ACTIVE, copy.flags);
    try testing.expectEqual(port, copy.port.?);
    try testing.expectEqual(@as(?*exec.Node, &copy.node), sys.FindName(&list, "Hotkeys"));
    try testing.expect(sys.FindName(&list, "Blanker") != null);
    cb.FreeBrokerList(&list);
    try testing.expect(list.isEmpty());

    // A broker on the list keeps the library.
    cb.DeleteCxObjAll(first);
    try testing.expectEqual(cx.CMDE_NOBROKER, cb.BrokerCommand("Hotkeys", cx.CXCMD_KILL));
    cb.DeleteCxObjAll(second);
    sys.DeleteMsgPort(port);
    try rig.deinit();
}

test "objects: errors, priorities, what attaching to nothing does" {
    var rig: Rig = .{};
    try rig.init();
    const cb = rig.cb;

    try testing.expect(cb.CreateCxObj(cx.CX_INVALID, 0, 0) == null);
    try testing.expect(cb.CreateCxObj(cx.CX_CUSTOM + 1, 0, 0) == null);
    try testing.expect(cb.CreateCxObj(cx.CX_BROKER, 0, 0) == null);
    try testing.expectEqual(cx.CX_INVALID, cb.CxObjType(null));
    try testing.expectEqual(cx.COERR_ISNULL, cb.CxObjError(null));

    const bad = cx.CxFilter(cb, "ctrl nosuchkey") orelse return error.NoFilter;
    try testing.expectEqual(cx.COERR_BADFILTER, cb.CxObjError(bad));
    cb.SetFilter(bad, "ctrl f2");
    try testing.expectEqual(@as(u32, 0), cb.CxObjError(bad));
    cb.SetTranslate(bad, null);
    try testing.expectEqual(cx.COERR_BADTYPE, cb.CxObjError(bad));
    cb.ClearCxObjError(bad);
    cb.AttachCxObj(bad, null);
    try testing.expectEqual(cx.COERR_NULLATTACH, cb.CxObjError(bad));

    const low = cx.CxDebug(cb, 1) orelse return error.NoObject;
    const high = cx.CxDebug(cb, 2) orelse return error.NoObject;
    try testing.expectEqual(@as(i32, 0), cb.SetCxObjPri(high, 300));
    try testing.expectEqual(@as(i32, 127), cb.SetCxObjPri(high, 10));
    cb.EnqueueCxObj(bad, low);
    cb.EnqueueCxObj(bad, high);
    const object = _base.objectOf(bad);
    try testing.expectEqual(&_base.objectOf(high).node, object.list.first().?);
    cb.RemoveCxObj(high);
    cb.InsertCxObj(bad, high, null);
    try testing.expectEqual(&_base.objectOf(high).node, object.list.first().?);
    cb.RemoveCxObj(high);
    cb.InsertCxObj(bad, high, low);
    try testing.expectEqual(&_base.objectOf(low).node, object.list.first().?);

    // Attaching to nothing gives the object back.
    cb.AttachCxObj(null, cx.CxDebug(cb, 3));
    cb.DeleteCxObjAll(bad);

    try rig.deinit();
}

test "a round: a hotkey taken out, a copy sent, the rest through" {
    var rig: Rig = .{};
    try rig.init();
    const cb = rig.cb;
    const sys = rig.sys();
    const port = sys.CreateMsgPort() orelse return error.NoPort;

    var err: i32 = 0;
    const top = broker(&rig, "Hotkeys", cx.NBU_UNIQUE, port, &err) orelse return error.NoBroker;
    cb.AttachCxObj(top, cx.HotKey(cb, "ctrl f1", port, 7));
    try testing.expectEqual(@as(u32, 0), cb.CxObjError(top));

    var buffer: [8]u32 = undefined;
    // An inactive broker lets everything by.
    var events = [_]InputEvent{ key(kbd.RAWKEY_F1, ie.IEQUALIFIER_CONTROL), key(kbd.RAWKEY_A, 0) };
    try testing.expectEqualSlices(u32, &.{ kbd.RAWKEY_F1, kbd.RAWKEY_A }, codes(&buffer, rig.round(chain(&events))));
    try testing.expect(sys.GetMsg(port) == null);

    _ = cb.ActivateCxObj(top, true);
    var more = [_]InputEvent{ key(kbd.RAWKEY_F1, ie.IEQUALIFIER_CONTROL), key(kbd.RAWKEY_A, 0), key(kbd.RAWKEY_F1, 0) };
    try testing.expectEqualSlices(u32, &.{ kbd.RAWKEY_A, kbd.RAWKEY_F1 }, codes(&buffer, rig.round(chain(&more))));
    const hit = cx.CxMsg.from(sys.GetMsg(port) orelse return error.NoHotkey);
    try testing.expect(sys.GetMsg(port) == null);
    try testing.expectEqual(cx.CXM_IEVENT, cb.CxMsgType(hit));
    try testing.expectEqual(@as(i32, 7), cb.CxMsgID(hit));
    try testing.expectEqual(kbd.RAWKEY_F1, cb.CxMsgData(hit).?.code);
    sys.ReplyMsg(hit.message());

    // The replied message is freed by the next round.
    try testing.expect(rig.round(null) == null);
    try testing.expect(rig.real().reply_port.msg_list.isEmpty());

    cb.DeleteCxObjAll(top);
    sys.DeleteMsgPort(port);
    try rig.deinit();
}

test "a translator's events come out in their order, at the event's time" {
    var rig: Rig = .{};
    try rig.init();
    const cb = rig.cb;
    var err: i32 = 0;
    const top = broker(&rig, "Typer", cx.NBU_UNIQUE, null, &err) orelse return error.NoBroker;
    var typed = [_]InputEvent{ key(kbd.RAWKEY_A, 0), key(0x35, 0), key(kbd.RAWKEY_RETURN, 0) };
    const filter = cx.CxFilter(cb, "f2") orelse return error.NoFilter;
    cb.AttachCxObj(filter, cx.CxTranslate(cb, chain(&typed)));
    cb.AttachCxObj(top, filter);
    _ = cb.ActivateCxObj(top, true);

    var events = [_]InputEvent{ key(kbd.RAWKEY_F1, 0), key(0x51, 0), key(kbd.RAWKEY_TAB, 0) };
    events[1].time = .{ .secs = 12, .micro = 34 };
    var buffer: [8]u32 = undefined;
    const out = rig.round(chain(&events));
    try testing.expectEqualSlices(u32, &.{ kbd.RAWKEY_F1, kbd.RAWKEY_A, 0x35, kbd.RAWKEY_RETURN, kbd.RAWKEY_TAB }, codes(&buffer, out));
    try testing.expectEqual(@as(u32, 12), out.?.next.?.time.secs);
    try testing.expectEqual(@as(u32, 34), out.?.next.?.next.?.time.micro);

    cb.DeleteCxObjAll(top);
    try rig.deinit();
}

/// What the custom objects of the tests saw.
const Custom = struct {
    var calls: u32 = 0;

    /// F2 adds an F3 after it; everything else passes.
    fn addAfterF2(cb: *CxBase, cxm: *cx.CxMsg, _: *cx.CxObj) callconv(.c) void {
        calls += 1;
        const event = cb.CxMsgData(cxm) orelse return;
        if (event.code != 0x51) return;
        var extra = key(0x52, 0);
        cb.AddIEvents(&extra);
    }

    /// Sends the message back to itself, for ever.
    fn loop(cb: *CxBase, cxm: *cx.CxMsg, co: *cx.CxObj) callconv(.c) void {
        calls += 1;
        cb.RouteCxMsg(cxm, co);
    }
};

test "custom objects: events added in the walk, a loop cut off" {
    var rig: Rig = .{};
    try rig.init();
    const cb = rig.cb;
    var err: i32 = 0;
    const top = broker(&rig, "Custom", cx.NBU_UNIQUE, null, &err) orelse return error.NoBroker;
    const adder = cx.CxCustom(cb, &Custom.addAfterF2, 5) orelse return error.NoObject;
    cb.AttachCxObj(top, adder);
    _ = cb.ActivateCxObj(top, true);

    Custom.calls = 0;
    var buffer: [8]u32 = undefined;
    var events = [_]InputEvent{ key(0x51, 0), key(kbd.RAWKEY_A, 0) };
    try testing.expectEqualSlices(u32, &.{ 0x51, kbd.RAWKEY_A, 0x52 }, codes(&buffer, rig.round(chain(&events))));
    try testing.expectEqual(@as(u32, 3), Custom.calls);

    cb.DeleteCxObj(adder);
    cb.AttachCxObj(top, cx.CxCustom(cb, &Custom.loop, 0));
    Custom.calls = 0;
    var one = [_]InputEvent{key(kbd.RAWKEY_A, 0)};
    try testing.expectEqualSlices(u32, &.{kbd.RAWKEY_A}, codes(&buffer, rig.round(chain(&one))));
    try testing.expectEqual(@as(u32, _base.TOO_MANY_ECHOES), Custom.calls);

    cb.DeleteCxObjAll(top);
    try rig.deinit();
}

test "AddIEvents from a program, and events held while the network is busy" {
    var rig: Rig = .{};
    try rig.init();
    const cb = rig.cb;
    const sys = rig.sys();
    var err: i32 = 0;
    const top = broker(&rig, "Busy", cx.NBU_UNIQUE, null, &err) orelse return error.NoBroker;
    _ = cb.ActivateCxObj(top, true);

    var buffer: [8]u32 = undefined;
    var added = [_]InputEvent{ key(0x53, 0), key(0x54, 0) };
    cb.AddIEvents(chain(&added));
    var events = [_]InputEvent{key(kbd.RAWKEY_A, 0)};
    try testing.expectEqualSlices(u32, &.{ 0x53, 0x54, kbd.RAWKEY_A }, codes(&buffer, rig.round(chain(&events))));

    // A program has the network: the handler, on a task of its own,
    // gives back nothing and keeps the events for its next round.
    var input_task: exec.Task = .{};
    const own = kexec.SysBase.cpu().this_task;
    sys.ObtainSemaphore(&rig.real().lock);
    kexec.SysBase.cpu().this_task = &input_task;
    var first = [_]InputEvent{key(0x50, 0)};
    const nothing = rig.round(chain(&first));
    var second = [_]InputEvent{key(0x51, 0)};
    const still = rig.round(chain(&second));
    kexec.SysBase.cpu().this_task = own;
    sys.ReleaseSemaphore(&rig.real().lock);
    try testing.expect(nothing == null);
    try testing.expect(still == null);
    var third = [_]InputEvent{key(0x52, 0)};
    try testing.expectEqualSlices(u32, &.{ 0x50, 0x51, 0x52 }, codes(&buffer, rig.round(chain(&third))));

    cb.DeleteCxObjAll(top);
    try rig.deinit();
}
