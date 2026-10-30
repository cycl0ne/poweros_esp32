// SPDX-License-Identifier: MIT
//! Commodities: a hotkey commodity, the commodities running, and commands
//! to one of them. Built against the SDK only.
//!
//!   Commodities LIST/S,BROKER/K,COMMAND/K,HOTKEY/K,TYPE/K,PRI/K/N
//!
//! With nothing asked for it is a commodity of its own, "CxTest": a broker
//! with a hotkey under it (HOTKEY, "ctrl alt c" when none is given) that
//! prints each press and keeps it from the windows, until Ctrl-C or a
//! KILL command. With TYPE each press types that string as well
//! (InvertString's form: `\n` a Return, `<f1>` a key by its description).
//! PRI is the broker's place among the others. A second CxTest is refused,
//! and the first one told so.
//!
//! LIST prints the commodities running: name, whether it is active, its
//! title and description. BROKER with COMMAND sends the one of that exact
//! name a command: DISABLE, ENABLE, APPEAR, DISAPPEAR, KILL or UNIQUE.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const CxBase = sdk.interface.commodities.CxBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Commodities";
const VERSION_STRING = "\x00$VER: Commodities 1.0 (30.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "LIST/S,BROKER/K,COMMAND/K,HOTKEY/K,TYPE/K,PRI/K/N";
const arg_list = 0;
const arg_broker = 1;
const arg_command = 2;
const arg_hotkey = 3;
const arg_type = 4;
const arg_pri = 5;

const broker_name = "CxTest";
const default_hotkey = "ctrl alt c";
/// The sender's id: what a hotkey message carries.
const hotkey_id = 1;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NONE = "No commodities\n";
const MSG_BROKER = "%-23s %-8s %s - %s\n";
const MSG_BADCOMMAND = "COMMAND is DISABLE, ENABLE, APPEAR, DISAPPEAR, KILL or UNIQUE\n";
const MSG_NEEDBROKER = "COMMAND needs BROKER\n";
const MSG_SENT = "%s sent to %s\n";
const MSG_NOBROKER = "No commodity called %s\n";
const MSG_NOPORT = "%s takes no commands\n";
const MSG_NOMEMORY = "No memory\n";
const MSG_DUPLICATE = "%s runs already\n";
const MSG_NOTMADE = "No broker (error %d)\n";
const MSG_BADHOTKEY = "Not a hotkey: %s\n";
const MSG_BADTYPE = "Cannot type: %s\n";
const MSG_RUNNING = "%s: hotkey %s - Ctrl-C to stop\n";
const MSG_HOTKEY = "hotkey %d: code %02x qualifier %04x\n";
const MSG_COMMAND = "command %s\n";
const MSG_UNIQUE = "another %s was started\n";
const MSG_DONE = "%d hotkeys\n";

const commands = [_]struct { name: [*:0]const u8, id: i32 }{
    .{ .name = "DISABLE", .id = cx.CXCMD_DISABLE },
    .{ .name = "ENABLE", .id = cx.CXCMD_ENABLE },
    .{ .name = "APPEAR", .id = cx.CXCMD_APPEAR },
    .{ .name = "DISAPPEAR", .id = cx.CXCMD_DISAPPEAR },
    .{ .name = "KILL", .id = cx.CXCMD_KILL },
    .{ .name = "UNIQUE", .id = cx.CXCMD_UNIQUE },
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [6]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const cx_lib = sys.OpenLibrary(cx.COMMODITIESNAME, cx.COMMODITIES_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{@as([*:0]const u8, cx.COMMODITIESNAME)});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(cx_lib);
    const cb: *CxBase = @ptrCast(cx_lib);

    if (argv[arg_list] != 0) return list(dl, cb);
    if (argv[arg_command] != 0) {
        const name: [*:0]const u8 = @ptrFromInt(argv[arg_command]);
        const broker: [*:0]const u8 = if (argv[arg_broker] != 0) @ptrFromInt(argv[arg_broker]) else {
            _ = Printf(dl, MSG_NEEDBROKER, .{});
            return dos.RETURN_ERROR;
        };
        return command(dl, cb, broker, name);
    }
    const hotkey: [*:0]const u8 = if (argv[arg_hotkey] != 0) @ptrFromInt(argv[arg_hotkey]) else default_hotkey;
    const typed: ?[*:0]const u8 = if (argv[arg_type] != 0) @ptrFromInt(argv[arg_type]) else null;
    const pri: i32 = if (argv[arg_pri] != 0) @as(*const i32, @ptrFromInt(argv[arg_pri])).* else 0;
    return run(sys, dl, cb, hotkey, typed, pri);
}

/// Every commodity running, one line each.
fn list(dl: *DosBase, cb: *CxBase) i32 {
    var brokers: exec.List = .{};
    brokers.init(.unknown);
    const count = cb.CopyBrokerList(&brokers);
    defer cb.FreeBrokerList(&brokers);
    if (count == 0) _ = Printf(dl, MSG_NONE, .{});
    var it = brokers.iterator();
    while (it.next()) |node| {
        const copy: *cx.BrokerCopy = @ptrCast(@alignCast(node));
        const state: [*:0]const u8 = if (copy.flags & cx.COF_ACTIVE != 0) "active" else "inactive";
        _ = Printf(dl, MSG_BROKER, .{
            @as([*:0]const u8, @ptrCast(&copy.name_buffer)), state,
            @as([*:0]const u8, @ptrCast(&copy.title)),       @as([*:0]const u8, @ptrCast(&copy.descr)),
        });
    }
    return dos.RETURN_OK;
}

/// The command called `name` to the commodity called `broker`.
fn command(dl: *DosBase, cb: *CxBase, broker: [*:0]const u8, name: [*:0]const u8) i32 {
    const id = for (commands) |c| {
        if (same(c.name, name)) break c.id;
    } else {
        _ = Printf(dl, MSG_BADCOMMAND, .{});
        return dos.RETURN_ERROR;
    };
    switch (cb.BrokerCommand(broker, id)) {
        cx.CMDE_OK => _ = Printf(dl, MSG_SENT, .{ name, broker }),
        cx.CMDE_NOBROKER => {
            _ = Printf(dl, MSG_NOBROKER, .{broker});
            return dos.RETURN_WARN;
        },
        cx.CMDE_NOPORT => {
            _ = Printf(dl, MSG_NOPORT, .{broker});
            return dos.RETURN_WARN;
        },
        else => {
            _ = Printf(dl, MSG_NOMEMORY, .{});
            return dos.RETURN_FAIL;
        },
    }
    return dos.RETURN_OK;
}

/// CxTest: a broker with the hotkey under it, until Ctrl-C or KILL.
fn run(sys: *ExecBase, dl: *DosBase, cb: *CxBase, hotkey: [*:0]const u8, typed: ?[*:0]const u8, pri: i32) i32 {
    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    var err: i32 = cx.CBERR_OK;
    const broker = cb.CxBroker(&.{
        .name = broker_name,
        .title = "Commodities test",
        .descr = "Prints a hotkey, types a string",
        .unique = cx.NBU_UNIQUE | cx.NBU_NOTIFY,
        .pri = pri,
        .port = port,
    }, &err) orelse {
        if (err == cx.CBERR_DUP) {
            _ = Printf(dl, MSG_DUPLICATE, .{@as([*:0]const u8, broker_name)});
            return dos.RETURN_WARN;
        }
        _ = Printf(dl, MSG_NOTMADE, .{err});
        return dos.RETURN_FAIL;
    };
    // Whatever happens below, the broker goes with everything under it,
    // and what is still on the port is answered.
    defer {
        cb.DeleteCxObjAll(broker);
        while (sys.GetMsg(port)) |msg| sys.ReplyMsg(msg);
    }

    cb.AttachCxObj(broker, cx.HotKey(cb, hotkey, port, hotkey_id));
    if (cb.CxObjError(broker) & cx.COERR_NULLATTACH != 0) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    var check: cx.InputXpression = .{};
    if (cb.ParseIX(hotkey, &check) != 0) {
        _ = Printf(dl, MSG_BADHOTKEY, .{hotkey});
        return dos.RETURN_ERROR;
    }
    const events = if (typed) |text| cx.InvertString(sys, cb, text, null) orelse {
        _ = Printf(dl, MSG_BADTYPE, .{text});
        return dos.RETURN_ERROR;
    } else null;
    defer cx.FreeIEvents(sys, events);

    _ = cb.ActivateCxObj(broker, true);
    // A Ctrl-C from before this command started is not a request to stop it.
    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);
    _ = Printf(dl, MSG_RUNNING, .{ @as([*:0]const u8, broker_name), hotkey });
    var hits: i32 = 0;
    var running = true;
    while (running) {
        const got = sys.Wait(port.sigMask() | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) running = false;
        while (sys.GetMsg(port)) |msg| {
            const cxm = cx.CxMsg.from(msg);
            const kind = cb.CxMsgType(cxm);
            const id = cb.CxMsgID(cxm);
            var event: ie.InputEvent = .{};
            if (cb.CxMsgData(cxm)) |data| event = data.*;
            sys.ReplyMsg(msg);
            if (kind == cx.CXM_IEVENT) {
                hits += 1;
                _ = Printf(dl, MSG_HOTKEY, .{ id, event.code, event.qualifier });
                if (events) |first| cb.AddIEvents(first);
                continue;
            }
            switch (id) {
                cx.CXCMD_DISABLE => _ = cb.ActivateCxObj(broker, false),
                cx.CXCMD_ENABLE => _ = cb.ActivateCxObj(broker, true),
                cx.CXCMD_KILL => running = false,
                cx.CXCMD_UNIQUE => {
                    _ = Printf(dl, MSG_UNIQUE, .{@as([*:0]const u8, broker_name)});
                    continue;
                },
                else => {},
            }
            for (commands) |c| {
                if (c.id == id) _ = Printf(dl, MSG_COMMAND, .{c.name});
            }
        }
    }
    _ = Printf(dl, MSG_DONE, .{hits});
    return dos.RETURN_OK;
}

/// Whether two words are the same, ignoring the case of ASCII letters.
fn same(left: [*:0]const u8, right: [*:0]const u8) bool {
    var at: usize = 0;
    while (true) : (at += 1) {
        if (upper(left[at]) != upper(right[at])) return false;
        if (left[at] == 0) return true;
    }
}

fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}
