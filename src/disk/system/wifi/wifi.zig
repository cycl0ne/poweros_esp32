// SPDX-License-Identifier: MIT
//! WiFi: the networks a radio hears, joined and left in a window. Built
//! against the SDK only.
//!
//!   WiFi INTERFACE/K
//!
//! INTERFACE is the radio to start on, by its interface (`wlan0`) or its
//! file in DEVS:NetInterfaces/ (`WLAN0`); without it, the first one there
//! is.
//!
//! **The radios** are the devices that answer the wireless requests
//! (radio.zig): those an interface is up on, and those that say they speak
//! them with none up - not up yet, which scan all the same. With more than
//! one, the chooser at the top picks the one the window works on.
//!
//! **The line under it** says where the station is: the network it is on,
//! the channel and band, the signal, and the interface's address - asked
//! again every few seconds - or that it is on none, or the join under way.
//!
//! **The networks in range** are what the last scan heard, one line per
//! network name - its strongest access point's signal, channel and way in,
//! and every band any of them is on - strongest first. Scan asks again;
//! the window scans as it opens and when another radio is picked. The
//! network the station is on is marked; the last column also says which
//! ones have a passphrase kept and which one the radio joins at start.
//!
//! **Join**, or a double-click on a line, joins the network picked: an
//! open one at once, a protected one with the passphrase kept for it, or
//! else with one asked for in a window of its own - where Keep the
//! passphrase keeps it for the next time, written once the station is on
//! the network with it. A radio not up is brought up first: its file in
//! DEVS:NetInterfaces/ started by C:net/AddNetInterface, and where it has
//! none, one written for it that asks DHCP for the address - WLAN0, or the
//! first such name free - which the boot then brings up at every start.
//! A join that has not come off after twenty seconds
//! is given up, and the network left, so the radio does not go on trying
//! a passphrase that is wrong. **Leave** leaves the network the station is
//! on. **Forget** deletes a network's kept passphrase, once it has asked,
//! and stops it being joined at start.
//!
//! **Join at start** is the `Network` of the radio's interface file in
//! DEVS:NetInterfaces/, which the boot joins as it brings the interface
//! up: the box follows the network picked, and setting or clearing it
//! writes the file at once (the `netinterface` module).
//!
//! **Settings...** starts SYS:System/Network on the radio's interface: its
//! addresses, DHCP or fixed, and its name servers.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const graphics = sdk.graphics;
const bsd = sdk.bsdsocket;
const wireless = sdk.devices.wireless;
const timer = sdk.devices.timer;
const radio_file = @import("radio.zig");
const netinterface = @import("netinterface");
const passphrase_file = @import("passphrase.zig");
const text = @import("text.zig");
const Line = text.Line;
const Radio = radio_file.Radio;
const Network = radio_file.Network;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const TagItem = sdk.utility.TagItem;
const Object = intuition.Object;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const requesters = intuition.requesters;
const lb = sdk.gadgets.listbrowser;
const st = sdk.gadgets.string;
const tx = sdk.gadgets.text;
const cb_class = sdk.gadgets.checkbox;
const ch = sdk.gadgets.chooser;

pub const COMMAND_NAME = "WiFi";
const VERSION = "1.1";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (22.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "INTERFACE/K";
const arg_interface = 0;
const arg_count = 1;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOMEMORY = "%s: no memory\n";
const MSG_NOWINDOW = "%s: no window\n";

/// The gadgets.
const ID_RADIO = 1;
const ID_NETWORKS = 2;
const ID_JOIN = 3;
const ID_LEAVE = 4;
const ID_FORGET = 5;
const ID_SCAN = 6;
const ID_START = 7;
const ID_SETTINGS = 8;
const ID_PASSPHRASE = 10;
const ID_KEEP = 11;
const ID_ASK_JOIN = 12;
const ID_ASK_CANCEL = 13;

/// A field says which key ended it, as the raw key it was: Return and the
/// keypad's Enter join, where Tab and a press elsewhere only leave it.
const raw_return: u32 = 0x44;
const raw_enter: u32 = 0x43;

fn entered(code: u32) bool {
    return code == raw_return or code == raw_enter;
}

/// The timer's tick; a join is looked at every tick, the line under the
/// chooser made again every `status_ticks`.
const tick_us: u64 = 1_000_000;
const status_ticks: u32 = 3;
/// How many ticks a message stays before the line says where the station
/// is again.
const message_ticks: u32 = 5;
/// How many ticks a join is given before it is given up.
const join_ticks_max: u32 = 20;

/// The room the status line keeps, whatever it says: a line longer than
/// that - a long network name's - is cut at the window's edge.
const status_room = "x" ** 88;

/// How many rows the list shows without being made taller, how many
/// characters wide it is at the least - a line of the widest texts its
/// columns have - and how many the passphrase field is.
const rows_shown = 10;
const list_columns: usize = 100;
const passphrase_columns: usize = 32;

const columns = [_]lb.Column{
    .{ .title = "Network", .weight = 20 },
    .{ .title = "Signal", .weight = 18, .flags = lb.COLUMN_NOSORT },
    .{ .title = "Band", .weight = 14, .flags = lb.COLUMN_NOSORT },
    .{ .title = "Security", .weight = 11 },
    .{ .title = "State", .weight = 21, .flags = lb.COLUMN_NOSORT },
    .{},
};

fn pair(tag: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = tag, .data = data };
}

/// A signal in a word, by how a station fares on it.
fn signalWord(dbm: i32) [*:0]const u8 {
    if (dbm >= -55) return "excellent";
    if (dbm >= -67) return "good";
    if (dbm >= -75) return "fair";
    return "weak";
}

fn bandsName(bands: u8) [*:0]const u8 {
    const both = radio_file.BAND_2G | radio_file.BAND_5G;
    if (bands & both == both) return "2.4 and 5 GHz";
    if (bands & radio_file.BAND_5G != 0) return "5 GHz";
    return "2.4 GHz";
}

/// Whether `passphrase` is one a WPA network takes: 8 to 63 characters,
/// or the key itself in 64 hex digits.
fn passphraseFits(passphrase: []const u8) bool {
    if (passphrase.len >= 8 and passphrase.len <= 63) return true;
    if (passphrase.len != 64) return false;
    for (passphrase) |char| {
        const hex = (char >= '0' and char <= '9') or (char >= 'a' and char <= 'f') or (char >= 'A' and char <= 'F');
        if (!hex) return false;
    }
    return true;
}

/// The radio's interface file and the buffer it is changed in, and what
/// starting its interface takes: kept apart from the stack, which on a
/// 32-bit machine has no room for them.
const Files = struct {
    bytes: [netinterface.file_max]u8,
    changed: [netinterface.file_max]u8,
    work: netinterface.Work,
};

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    sb: *SocketBase,
    files: *Files,

    /// The window and its layout's root.
    object: ?*Object = null,
    window: ?*intuition.Window = null,

    /// The radios, the one the window works on, and the labels the
    /// chooser shows for them.
    radios: [radio_file.max_radios]Radio = @splat(.{}),
    radio_count: usize = 0,
    current: usize = 0,
    radio_labels: [radio_file.max_radios + 1:null]?[*:0]const u8 = @splat(null),
    link: radio_file.Link,

    /// What the last scan heard, the list's rows, and the network picked,
    /// by its name, so that a new scan keeps it picked.
    networks: [radio_file.max_networks]Network = undefined,
    network_count: usize = 0,
    rows: exec.List = .{},
    picked: [radio_file.ssid_max:0]u8 = @splat(0),

    /// The network the station is on, as it was last asked.
    joined: radio_file.Joined = .{},
    on: bool = false,
    /// The join under way: the network, how many ticks it has had, and
    /// the passphrase typed for it with whether to keep it.
    joining: [radio_file.ssid_max:0]u8 = @splat(0),
    join_ticks: u32 = 0,
    typed: [wireless.PASSPHRASE_MAX + 1]u8 = @splat(0),
    keep_typed: bool = false,
    /// A passphrase on its way: the kept one read for a join, or the one
    /// typed with its line's end, written to be kept. Wiped after each.
    passphrase: [wireless.PASSPHRASE_MAX + 2]u8 = @splat(0),

    /// The radio's interface file - whether there is one - and the
    /// network it joins at start.
    start_file: bool = false,
    start_network: [radio_file.ssid_max:0]u8 = @splat(0),

    /// What the status line says, and what the window's title says.
    status: Line = .{},
    shown_status: Line = .{},
    /// A row's signal and state as the list is made, copied into the row;
    /// the command Settings... starts.
    row_signal: Line = .{},
    row_state: Line = .{},
    command: Line = .{},
    ticks: u32 = 0,
    /// How many more ticks the message on the line stays.
    held: u32 = 0,

    chooser: ?*Object = null,
    status_gadget: ?*Object = null,
    list: ?*Object = null,
    join_button: ?*Object = null,
    leave_button: ?*Object = null,
    forget_button: ?*Object = null,
    scan_button: ?*Object = null,
    start_box: ?*Object = null,
    settings_button: ?*Object = null,

    /// The window that asks for a passphrase, and the network it asks for.
    ask_object: ?*Object = null,
    ask_window: ?*intuition.Window = null,
    ask_title: Line = .{},
    ask_ssid: [radio_file.ssid_max:0]u8 = @splat(0),
    passphrase_field: ?*Object = null,
    keep_box: ?*Object = null,

    /// The tick.
    timer_req: timer.TimeRequest = .{},
    timer_port: ?*exec.MsgPort = null,
    timer_open: bool = false,
    timer_out: bool = false,

    // --- the gadgets ----------------------------------------------------------

    fn set(app: *App, object: ?*Object, tags: []const TagItem) void {
        _ = app.ib.SetGadgetAttrsTagList(object orelse return, app.window, tags.ptr);
    }

    fn setIn(app: *App, window: ?*intuition.Window, object: ?*Object, tags: []const TagItem) void {
        _ = app.ib.SetGadgetAttrsTagList(object orelse return, window, tags.ptr);
    }

    fn enable(app: *App, object: ?*Object, on: bool) void {
        app.set(object, &.{ pair(gc.GA_Disabled, @intFromBool(!on)), .{} });
    }

    /// A message on the status line, `format` with `args`, which stays
    /// there `message_ticks` before the line says where the station is
    /// again.
    fn say(app: *App, comptime format: [:0]const u8, args: anytype) void {
        app.status.say(app.sys, format, args);
        app.held = message_ticks;
        app.showStatus();
    }

    /// The status line drawn, only when it says something else than it
    /// did.
    fn showStatus(app: *App) void {
        if (text.same(app.status.slice(), app.shown_status.slice())) return;
        app.shown_status = app.status;
        app.set(app.status_gadget, &.{ pair(tx.TEXT_Text, @intFromPtr(app.shown_status.ptr())), .{} });
    }

    /// What a string gadget holds now.
    fn textOf(app: *App, object: ?*Object) []const u8 {
        var at: usize = 0;
        _ = app.ib.GetAttr(gc.STRINGA_TextVal, object orelse return &.{}, &at);
        if (at == 0) return &.{};
        return text.spanOf(@ptrFromInt(at));
    }

    fn checked(app: *App, object: ?*Object) bool {
        var value: usize = 0;
        _ = app.ib.GetAttr(cb_class.CHECKBOX_Checked, object orelse return false, &value);
        return value != 0;
    }

    fn radio(app: *App) ?*Radio {
        if (app.current >= app.radio_count) return null;
        return &app.radios[app.current];
    }

    // --- the radio ----------------------------------------------------------------

    /// The radio `index` opened in place of the one before, its interface
    /// file read, where it is said and its networks scanned for.
    fn pickRadio(app: *App, index: usize) void {
        app.link.close();
        app.on = false;
        app.joining[0] = 0;
        text.wipe(&app.typed);
        app.network_count = 0;
        app.picked[0] = 0;
        app.current = index;
        const picked_radio = app.radio() orelse return;
        if (!app.link.open(picked_radio)) {
            app.say("%s: the device does not open", .{@as([*:0]const u8, @ptrCast(&picked_radio.device))});
            app.showList();
            return;
        }
        app.readStart();
        app.refresh();
        app.showList();
        app.scan();
    }

    /// The radio's interface file read for the network it joins at start.
    fn readStart(app: *App) void {
        app.start_file = false;
        app.start_network[0] = 0;
        const picked_radio = app.radio() orelse return;
        if (picked_radio.file[0] == 0) return;
        var path: netinterface.Path = undefined;
        const file = netinterface.readFile(app.dl, netinterface.pathOf(text.untilNul(&picked_radio.file), &path), &app.files.bytes) orelse return;
        app.start_file = true;
        if (netinterface.valueOf(file, "Network")) |name| _ = text.copyInto(&app.start_network, name);
    }

    fn scan(app: *App) void {
        if (app.link.scanning) return;
        if (!app.link.startScan()) {
            app.say("The radio cannot be asked to scan", .{});
            return;
        }
        if (app.joining[0] == 0) app.say("Scanning...", .{});
        app.enable(app.scan_button, false);
    }

    /// A scan's answer taken, once its signal came.
    fn scanned(app: *App) void {
        var failed: i8 = 0;
        const count = app.link.scanDone(&app.networks, &failed) orelse return;
        app.network_count = count;
        app.enable(app.scan_button, true);
        app.showList();
        if (app.joining[0] != 0) return;
        if (failed != 0) {
            app.say("The scan failed: error %d", .{@as(i32, failed)});
        } else if (app.on) {
            app.held = 0;
            app.refreshLine();
        } else {
            app.say("%u networks in range - pick one and Join", .{@as(u32, @intCast(count))});
        }
    }

    /// Where the station is, asked of the radio and the interface again:
    /// the status line, and the list when the network it is on changed.
    fn refresh(app: *App) void {
        var now: radio_file.Joined = .{};
        const on = app.link.joined(&now);
        if (on) {
            if (app.link.signal()) |dbm| now.signal = dbm;
        }
        const changed = on != app.on or !text.same(now.name(), app.joined.name());
        app.on = on;
        app.joined = now;
        if (changed) app.showList();
        if (app.joining[0] == 0 and app.held == 0) app.refreshLine();
    }

    /// The status line made from what was last asked.
    fn refreshLine(app: *App) void {
        const picked_radio = app.radio() orelse return;
        const interface: [*:0]const u8 = @ptrCast(&picked_radio.interface);
        if (!app.on) {
            if (picked_radio.up) {
                app.status.say(app.sys, "%s is on no network - pick one and Join", .{interface});
            } else {
                app.status.say(app.sys, "The radio is not up - Join brings it up with the network picked", .{});
            }
            app.showStatus();
            return;
        }
        const joined = &app.joined;
        const line = &app.status;
        line.say(app.sys, "On \"%s\" - channel %u (%s), %d dBm, %s - ", .{
            @as([*:0]const u8, @ptrCast(&joined.ssid)),
            joined.channel,
            bandsName(radio_file.bandOf(joined.channel)),
            joined.signal,
            signalWord(joined.signal),
        });
        var address: u32 = 0;
        var state: u32 = 0;
        const tags = [_]TagItem{
            pair(bsd.IFQ_Address, @intFromPtr(&address)),
            pair(bsd.IFQ_State, @intFromPtr(&state)),
            .{},
        };
        if (!picked_radio.up) {
            line.put("no address: its interface is not up - Join brings it up");
        } else if (app.sb.QueryInterfaceTagList(interface, &tags) != 0 or address == 0) {
            line.put("no address yet");
        } else {
            const octets: [4]u8 = @bitCast(address);
            line.add(app.sys, "address %u.%u.%u.%u", .{ @as(u32, octets[0]), @as(u32, octets[1]), @as(u32, octets[2]), @as(u32, octets[3]) });
            if (state & bsd.IFSTATE_LINKLOCAL != 0) line.put(" (no DHCP answer yet)");
        }
        app.showStatus();
    }

    // --- the list -----------------------------------------------------------------

    /// The list made anew from the networks heard, the one picked kept.
    fn showList(app: *App) void {
        // Taken away without a window, so that the gadget is drawn once,
        // as the list is given back, and not empty in between.
        app.setIn(null, app.list, &.{ pair(lb.LISTBROWSER_Rows, lb.LISTBROWSER_DETACH), .{} });
        lb.freeRows(app.sys, &app.rows);
        var selected: u32 = lb.LISTBROWSER_NONE;
        var place: u32 = 0;
        for (app.networks[0..app.network_count], 0..) |*network, index| {
            const signal_text = &app.row_signal;
            signal_text.say(app.sys, "%d dBm, %s", .{ network.signal, signalWord(network.signal) });
            const state = &app.row_state;
            state.clear();
            const is_on = app.on and text.same(network.name(), app.joined.name());
            if (is_on) state.put("on it");
            if (app.joining[0] != 0 and text.same(network.name(), text.untilNul(&app.joining))) state.put("joining");
            if (app.known(network.name())) {
                if (state.length != 0) state.put(", ");
                state.put("known");
            }
            if (text.same(network.name(), text.untilNul(&app.start_network))) {
                if (state.length != 0) state.put(", ");
                state.put("at start");
            }
            const texts = [_][*:0]const u8{
                @ptrCast(&network.ssid),
                signal_text.ptr(),
                bandsName(network.bands),
                radio_file.authName(network.auth),
                state.ptr(),
            };
            const row = lb.allocRow(app.sys, &texts, 0) orelse break;
            row.user_data = index;
            if (is_on) row.flags |= lb.ROW_MARKED;
            app.sys.AddTail(&app.rows, &row.node);
            if (text.same(network.name(), text.untilNul(&app.picked))) selected = place;
            place += 1;
        }
        app.set(app.list, &.{
            pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.rows)),
            pair(lb.LISTBROWSER_Selected, selected),
            .{},
        });
        app.showButtons();
    }

    /// The buttons follow the network picked: Join one the station is not
    /// on, Leave while it is on one or joining, Forget one that is known
    /// or joined at start; the box says whether the one picked is joined
    /// at start, and can be set where there is an interface file.
    fn showButtons(app: *App) void {
        const network = app.pickedNetwork();
        const has_radio = app.link.opened;
        const is_on = network != null and app.on and text.same(network.?.name(), app.joined.name());
        const is_up = if (app.radio()) |picked_radio| picked_radio.up else false;
        app.enable(app.join_button, has_radio and network != null and (!is_on or !is_up));
        app.enable(app.leave_button, has_radio and (app.on or app.joining[0] != 0));
        const at_start = network != null and text.same(network.?.name(), text.untilNul(&app.start_network));
        app.enable(app.forget_button, network != null and (app.known(network.?.name()) or at_start));
        app.set(app.start_box, &.{
            pair(gc.GA_Disabled, @intFromBool(!(app.start_file and network != null and netinterface.writable(network.?.name())))),
            pair(cb_class.CHECKBOX_Checked, @intFromBool(at_start)),
            .{},
        });
        app.enable(app.scan_button, has_radio and !app.link.scanning);
        const picked_radio = app.radio();
        app.enable(app.settings_button, picked_radio != null and picked_radio.?.file[0] != 0);
    }

    fn pickedNetwork(app: *App) ?*Network {
        const name = text.untilNul(&app.picked);
        if (name.len == 0) return null;
        for (app.networks[0..app.network_count]) |*network| {
            if (text.same(network.name(), name)) return network;
        }
        return null;
    }

    /// The row picked taken as the network picked.
    fn pickRow(app: *App) void {
        var at: usize = 0;
        _ = app.ib.GetAttr(lb.LISTBROWSER_SelectedRow, app.list orelse return, &at);
        if (at == 0) return;
        const row: *lb.Row = @ptrFromInt(at);
        if (row.user_data >= app.network_count) return;
        _ = text.copyInto(&app.picked, app.networks[row.user_data].name());
        app.showButtons();
    }

    /// Whether a passphrase is kept for `name`.
    fn known(app: *App, name: []const u8) bool {
        var path: passphrase_file.Path = undefined;
        const at = passphrase_file.pathOf(name, &path) orelse return false;
        const lock = app.dl.Lock(at, dos.SHARED_LOCK) orelse return false;
        app.dl.UnLock(lock);
        return true;
    }

    // --- joining ------------------------------------------------------------------

    /// Join: the network picked joined - an open one at once, a protected
    /// one with its kept passphrase, or with one asked for.
    fn joinPicked(app: *App) void {
        const network = app.pickedNetwork() orelse return;
        if (network.auth == wireless.S2AUTH_ENTERPRISE) {
            app.say("\"%s\" asks for an account, which WiFi does not join with", .{@as([*:0]const u8, @ptrCast(&network.ssid))});
            return;
        }
        if (network.open()) return app.startJoin(network.name(), null);
        const kept = app.passphrase[0 .. wireless.PASSPHRASE_MAX + 1];
        defer text.wipe(&app.passphrase);
        if (wireless.knownPassphrase(app.dl, @ptrCast(&network.ssid), kept)) |passphrase| {
            return app.startJoin(network.name(), passphrase);
        }
        app.openAsk(network.name());
    }

    /// The join of `name` asked of the radio - brought up first, when it is
    /// not - and then watched. A radio just brought up from a file that
    /// names the network is joined to it by C:net/AddNetInterface with the
    /// passphrase kept, and one still on it from a file that names none
    /// stays on it: neither is asked again, which would leave the network
    /// and join it anew.
    fn startJoin(app: *App, name: []const u8, passphrase: ?[*:0]const u8) void {
        const brought = if (app.radio()) |picked_radio| !picked_radio.up else false;
        if (!app.bringUp()) {
            text.wipe(&app.typed);
            return;
        }
        var ssid: [radio_file.ssid_max:0]u8 = @splat(0);
        _ = text.copyInto(&ssid, name);
        const typed = passphrase != null and passphrase.? == @as([*:0]const u8, @ptrCast(&app.typed));
        const joined_by_file = brought and !typed and text.same(name, text.untilNul(&app.start_network));
        const still_on = brought and app.start_network[0] == 0 and app.on and text.same(name, app.joined.name());
        if (!joined_by_file and !still_on) {
            const refused = app.link.join(@ptrCast(&ssid), passphrase);
            if (refused != 0) {
                app.say("The radio refused to join \"%s\": error %d", .{ @as([*:0]const u8, @ptrCast(&ssid)), @as(i32, refused) });
                text.wipe(&app.typed);
                return;
            }
        }
        app.joining = ssid;
        app.join_ticks = 0;
        app.say("Joining \"%s\"...", .{@as([*:0]const u8, @ptrCast(&ssid))});
        app.showList();
    }

    /// The radio's interface brought up, when it is not: its file started
    /// by C:net/AddNetInterface - written first where it has none, under
    /// the first of WLAN0 to WLAN9 free, asking DHCP for the address. False,
    /// said, when it could not be.
    fn bringUp(app: *App) bool {
        const picked_radio = app.radio() orelse return false;
        if (picked_radio.up) return true;
        const window = app.window orelse return false;
        app.ib.SetWindowPointerA(window, &[_]TagItem{ pair(wn.WA_BusyPointer, 1), .{} });
        defer app.ib.SetWindowPointerA(window, &[_]TagItem{.{}});
        if (picked_radio.file[0] == 0) {
            var name: netinterface.Name = undefined;
            if (!netinterface.freeName(app.dl, "WLAN", &name)) {
                app.say("No interface file can be written: WLAN0 to WLAN9 are all taken", .{});
                return false;
            }
            var path: netinterface.Path = undefined;
            const at = netinterface.pathOf(text.untilNul(&name), &path);
            const bytes = netinterface.newFile(text.untilNul(&name), text.untilNul(&picked_radio.device), picked_radio.unit, &app.files.changed) orelse {
                app.say("%s cannot be made for %s", .{ at, @as([*:0]const u8, @ptrCast(&picked_radio.device)) });
                return false;
            };
            if (!netinterface.writeFile(app.dl, at, bytes)) {
                app.say("%s cannot be written", .{at});
                return false;
            }
            picked_radio.file = name;
        }
        const started = netinterface.addInterface(app.dl, text.untilNul(&picked_radio.file), COMMAND_NAME, &app.files.work);
        if (started.code != dos.RETURN_OK) {
            if (started.said.len != 0) {
                app.status.clear();
                app.status.put(started.said);
            } else {
                app.status.say(app.sys, "C:net/AddNetInterface failed: %ld", .{@as(i64, started.code)});
            }
            app.held = message_ticks;
            app.showStatus();
            return false;
        }
        picked_radio.up = true;
        @memset(&picked_radio.interface, 0);
        for (text.untilNul(&picked_radio.file), 0..) |char, at| {
            if (at + 1 < picked_radio.interface.len) picked_radio.interface[at] = netinterface.lower(char);
        }
        picked_radio.labelUp(app.sys);
        app.set(app.chooser, &.{
            pair(ch.CHOOSER_Labels, @intFromPtr(&app.radio_labels)),
            pair(ch.CHOOSER_Active, app.current),
            .{},
        });
        app.readStart();
        app.showButtons();
        return true;
    }

    /// A tick of the join under way: done once the station is on the
    /// network - the passphrase typed kept then, when that was asked -
    /// and given up, the network left, when it has taken too long.
    fn watchJoin(app: *App) void {
        const name: [*:0]const u8 = @ptrCast(&app.joining);
        var now: radio_file.Joined = .{};
        if (app.link.joined(&now) and text.same(now.name(), text.untilNul(&app.joining))) {
            if (app.link.signal()) |dbm| now.signal = dbm;
            app.joined = now;
            app.on = true;
            // The line says where the station is now, unless keeping the
            // passphrase failed, which is said instead.
            app.held = 0;
            const typed = text.untilNul(&app.typed);
            if (typed.len != 0 and app.keep_typed) app.keepPassphrase(text.untilNul(&app.joining), typed);
            text.wipe(&app.typed);
            app.joining[0] = 0;
            if (app.held == 0) app.refreshLine();
            app.showList();
            return;
        }
        app.join_ticks += 1;
        if (app.join_ticks < join_ticks_max) return;
        _ = app.link.leave();
        const had_passphrase = app.typed[0] != 0 or !app.pickedOpen();
        text.wipe(&app.typed);
        if (had_passphrase) {
            app.say("\"%s\" not joined in %u seconds: given up - is the passphrase right?", .{ name, join_ticks_max });
        } else {
            app.say("\"%s\" not joined in %u seconds: given up", .{ name, join_ticks_max });
        }
        app.joining[0] = 0;
        app.on = false;
        app.showList();
    }

    fn pickedOpen(app: *App) bool {
        for (app.networks[0..app.network_count]) |*network| {
            if (text.same(network.name(), text.untilNul(&app.joining))) return network.open();
        }
        return false;
    }

    /// `passphrase` kept as the one for `name`.
    fn keepPassphrase(app: *App, name: []const u8, passphrase: []const u8) void {
        var path: passphrase_file.Path = undefined;
        const at = passphrase_file.pathOf(name, &path) orelse {
            app.say("Joined - the passphrase is not kept: a name with : or / names no file", .{});
            return;
        };
        const line = &app.passphrase;
        defer text.wipe(line);
        @memcpy(line[0..passphrase.len], passphrase);
        line[passphrase.len] = '\n';
        if (!netinterface.writeFile(app.dl, at, line[0 .. passphrase.len + 1])) {
            app.say("Joined - the passphrase could not be written to %s", .{at});
        }
    }

    /// Leave: the network the station is on left, or the join under way
    /// given up.
    fn leave(app: *App) void {
        const refused = app.link.leave();
        if (refused != 0) {
            app.say("The radio refused to leave: error %d", .{@as(i32, refused)});
            return;
        }
        const was = if (app.joining[0] != 0) app.joining else app.joined.ssid;
        app.joining[0] = 0;
        text.wipe(&app.typed);
        app.on = false;
        app.say("Left \"%s\"", .{@as([*:0]const u8, @ptrCast(&was))});
        app.showList();
    }

    /// Forget: the network picked's kept passphrase deleted, and it no
    /// longer joined at start, once that is asked.
    fn forget(app: *App) void {
        const network = app.pickedNetwork() orelse return;
        var name: [radio_file.ssid_max:0]u8 = network.ssid;
        const at_start = text.same(text.untilNul(&name), text.untilNul(&app.start_network));
        const asked = if (at_start)
            requesters.EasyRequest(app.ib, app.window, .{
                .title = COMMAND_NAME,
                .text_format = "Forget \"%s\"?\nIts kept passphrase is deleted, and the radio\nno longer joins it at start.",
                .gadget_format = "Forget|Cancel",
            }, null, .{@as([*:0]const u8, @ptrCast(&name))})
        else
            requesters.EasyRequest(app.ib, app.window, .{
                .title = COMMAND_NAME,
                .text_format = "Forget \"%s\"?\nIts kept passphrase is deleted.",
                .gadget_format = "Forget|Cancel",
            }, null, .{@as([*:0]const u8, @ptrCast(&name))});
        if (asked != 1) return;
        var path: passphrase_file.Path = undefined;
        if (passphrase_file.pathOf(text.untilNul(&name), &path)) |at| _ = app.dl.DeleteFile(at);
        if (at_start and !app.writeStart(null)) return;
        app.say("\"%s\" is forgotten", .{@as([*:0]const u8, @ptrCast(&name))});
        app.showList();
    }

    /// The box: the network picked set as the one joined at start, or no
    /// longer.
    fn toggleStart(app: *App) void {
        const network = app.pickedNetwork() orelse return app.showButtons();
        const wanted = app.checked(app.start_box);
        const is_start = text.same(network.name(), text.untilNul(&app.start_network));
        if (wanted == is_start) return;
        if (!app.writeStart(if (wanted) network.name() else null)) return app.showButtons();
        if (!wanted) {
            app.say("The radio joins no network at start", .{});
        } else if (!network.open() and !app.known(network.name())) {
            app.say("\"%s\" is joined at start once its passphrase is kept", .{@as([*:0]const u8, @ptrCast(&network.ssid))});
        } else {
            app.say("\"%s\" is joined at start", .{@as([*:0]const u8, @ptrCast(&network.ssid))});
        }
        app.showList();
    }

    /// The interface file written with `network` as its Network, or none:
    /// false, said, when it cannot be.
    fn writeStart(app: *App, network: ?[]const u8) bool {
        const picked_radio = app.radio() orelse return false;
        var path: netinterface.Path = undefined;
        const at = netinterface.pathOf(text.untilNul(&picked_radio.file), &path);
        const file = netinterface.readFile(app.dl, at, &app.files.bytes) orelse {
            app.say("%s cannot be read, or is too long to change here", .{at});
            return false;
        };
        const value = [_]netinterface.Value{.{ .text = network orelse "", .quoted = true }};
        const written = netinterface.withValues(file, "Network", if (network != null) &value else &.{}, &app.files.changed) orelse {
            app.say("%s would grow too long to change here", .{at});
            return false;
        };
        if (!netinterface.writeFile(app.dl, at, written)) {
            app.say("%s cannot be written", .{at});
            return false;
        }
        app.start_network[0] = 0;
        if (network) |name| _ = text.copyInto(&app.start_network, name);
        return true;
    }

    /// Settings...: SYS:System/Network started on the radio's interface,
    /// beside this window.
    fn openSettings(app: *App) void {
        const picked_radio = app.radio() orelse return;
        const dl = app.dl;
        const command = &app.command;
        command.say(app.sys, "SYS:System/Network INTERFACE=%s", .{@as([*:0]const u8, @ptrCast(&picked_radio.file))});
        const input = dl.Open("NIL:", dos.MODE_OLDFILE) orelse return app.say("SYS:System/Network could not be started", .{});
        const output = dl.Open("NIL:", dos.MODE_NEWFILE) orelse {
            _ = dl.Close(input);
            return app.say("SYS:System/Network could not be started", .{});
        };
        // Started on its own: the shell closes both streams at its end.
        const tags = [_]TagItem{
            pair(dos.SYS_Asynch, 1),
            pair(dos.SYS_Input, @intFromPtr(input)),
            pair(dos.SYS_Output, @intFromPtr(output)),
            pair(dos.NP_StackSize, dos.CLI_DEFAULT_STACK),
            .{},
        };
        if (dl.SystemTagList(command.ptr(), &tags) < 0) {
            _ = dl.Close(input);
            _ = dl.Close(output);
            app.say("SYS:System/Network could not be started", .{});
        }
    }

    // --- the window that asks for a passphrase ------------------------------------

    /// The window that asks for the passphrase of `name`, opened - in
    /// place of one still open. Its tag lists are stack only while it is
    /// made, not in every caller's frame.
    noinline fn openAsk(app: *App, name: []const u8) void {
        _ = text.copyInto(&app.ask_ssid, name);
        if (app.ask_object != null) {
            app.closeAsk();
        }
        const ib = app.ib;
        app.passphrase_field = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_PASSPHRASE),
            pair(gc.GA_RelVerify, 1),
            pair(gc.GA_TabCycle, 1),
            pair(gc.STRINGA_MaxChars, wireless.PASSPHRASE_MAX),
            pair(gc.STRINGA_Secret, 1),
            .{},
        });
        app.keep_box = ib.NewObjectTagList(null, cb_class.CHECKBOX_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_KEEP),
            pair(cb_class.CHECKBOX_Checked, @intFromBool(passphrase_file.keepable(name))),
            pair(gc.GA_Disabled, @intFromBool(!passphrase_file.keepable(name))),
            .{},
        });
        const buttons = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
            pair(lg.LAYOUTA_Spacing, 8),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(button(ib, "Join", ID_ASK_JOIN) orelse return)),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(button(ib, "Cancel", ID_ASK_CANCEL) orelse return)),
            .{},
        }) orelse return;
        const fields = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
            pair(lg.LAYOUTA_Margin, 6),
            pair(lg.LAYOUTA_Spacing, 4),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(app.passphrase_field orelse return)),
            pair(lg.CHILDA_Label, @intFromPtr("_Passphrase")),
            pair(lg.CHILDA_MinWidth, fontWidth(app) * passphrase_columns + 12),
            pair(lg.CHILDA_WeightHeight, 0),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(app.keep_box orelse return)),
            pair(lg.CHILDA_Label, @intFromPtr("_Keep the passphrase")),
            pair(lg.CHILDA_WeightHeight, 0),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(buttons)),
            pair(lg.CHILDA_WeightHeight, 0),
            .{},
        }) orelse return;
        app.ask_title.say(app.sys, "Join \"%s\"", .{@as([*:0]const u8, @ptrCast(&app.ask_ssid))});
        app.ask_object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            pair(wn.WA_Title, @intFromPtr(app.ask_title.ptr())),
            pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
            pair(wn.WA_CloseGadget, 1),
            pair(wn.WA_DragBar, 1),
            pair(wn.WA_DepthGadget, 1),
            pair(wn.WA_Activate, 1),
            pair(wc.WINDOWA_Layout, @intFromPtr(fields)),
            .{},
        }) orelse {
            ib.DisposeObject(fields);
            return;
        };
        var open = wc.WmOpen{};
        if (ib.SendMessage(app.ask_object.?, @ptrCast(&open)) == 0) {
            ib.DisposeObject(app.ask_object);
            app.forgetAskParts();
            app.say("No window to ask for the passphrase in", .{});
            return;
        }
        var at: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_Window, app.ask_object.?, &at);
        app.ask_window = @ptrFromInt(at);
        if (app.ask_window) |window| _ = ib.ActivateGadget(app.passphrase_field.?, window, null);
        app.say("The passphrase of \"%s\"...", .{@as([*:0]const u8, @ptrCast(&app.ask_ssid))});
    }

    fn forgetAskParts(app: *App) void {
        app.ask_object = null;
        app.ask_window = null;
        app.passphrase_field = null;
        app.keep_box = null;
    }

    fn closeAsk(app: *App) void {
        const object = app.ask_object orelse return;
        // The field's text goes before the window does.
        app.setIn(app.ask_window, app.passphrase_field, &.{ pair(gc.STRINGA_TextVal, @intFromPtr("")), .{} });
        app.ib.DisposeObject(object);
        app.forgetAskParts();
    }

    /// The window's Join: the passphrase taken - one a WPA network takes -
    /// the window closed, and the network joined with it.
    fn askJoin(app: *App) void {
        const typed = app.textOf(app.passphrase_field);
        if (!passphraseFits(typed)) {
            app.say("A passphrase is 8 to 63 characters, or 64 hex digits", .{});
            return;
        }
        text.wipe(&app.typed);
        _ = text.copyInto(&app.typed, typed);
        app.keep_typed = app.checked(app.keep_box);
        app.closeAsk();
        app.startJoin(text.untilNul(&app.ask_ssid), @ptrCast(&app.typed));
    }

    // --- the tick -----------------------------------------------------------------

    fn timerMask(app: *const App) u32 {
        const port = app.timer_port orelse return 0;
        return port.sigMask();
    }

    fn startTimer(app: *App) void {
        if (!app.timer_open or app.timer_out) return;
        app.timer_req.node.command = timer.TR_ADDREQUEST;
        app.timer_req.time = timer.TimeVal.fromMicros(tick_us);
        app.sys.SendIO(&app.timer_req.node);
        app.timer_out = true;
    }

    /// A tick, once its signal came: the join under way looked at, or
    /// every few ticks where the station is.
    fn ticked(app: *App) void {
        if (!app.timer_out or app.sys.CheckIO(&app.timer_req.node) == null) return;
        _ = app.sys.WaitIO(&app.timer_req.node);
        app.timer_out = false;
        app.startTimer();
        if (!app.link.opened) return;
        if (app.held > 0) app.held -= 1;
        if (app.joining[0] != 0) return app.watchJoin();
        app.ticks += 1;
        if (app.ticks % status_ticks == 0) app.refresh();
    }

    fn stopTimer(app: *App) void {
        if (app.timer_out) {
            _ = app.sys.AbortIO(&app.timer_req.node);
            _ = app.sys.WaitIO(&app.timer_req.node);
            app.timer_out = false;
        }
        if (app.timer_open) app.sys.CloseDevice(&app.timer_req.node);
        app.timer_open = false;
        if (app.timer_port) |port| app.sys.DeleteMsgPort(port);
        app.timer_port = null;
    }
};

fn button(ib: *IntuitionBase, label: [*:0]const u8, id: usize) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_Text, @intFromPtr(label)),
        pair(gc.GA_ID, id),
        pair(gc.GA_RelVerify, 1),
        .{},
    });
}

/// The window's whole layout, or null when something could not be made.
/// A function of its own: its tag lists are a kilobyte of stack, given
/// back once the window is made rather than held through the loop.
noinline fn buildLayout(app: *App) ?*Object {
    const ib = app.ib;
    app.chooser = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_RADIO),
        pair(gc.GA_RelVerify, 1),
        pair(ch.CHOOSER_Labels, @intFromPtr(&app.radio_labels)),
        pair(ch.CHOOSER_Active, app.current),
        pair(gc.GA_Disabled, @intFromBool(app.radio_count < 2)),
        .{},
    });
    app.status_gadget = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_RoomFor, @intFromPtr(status_room)),
        pair(tx.TEXT_Clipped, 1),
        pair(tx.TEXT_Text, @intFromPtr(app.shown_status.ptr())),
        .{},
    });
    app.list = ib.NewObjectTagList(null, lb.LISTBROWSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_NETWORKS),
        pair(gc.GA_RelVerify, 1),
        pair(lb.LISTBROWSER_Columns, @intFromPtr(&columns)),
        pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.rows)),
        .{},
    });
    app.join_button = button(ib, "_Join", ID_JOIN);
    app.leave_button = button(ib, "_Leave", ID_LEAVE);
    app.forget_button = button(ib, "_Forget...", ID_FORGET);
    app.scan_button = button(ib, "_Scan", ID_SCAN);
    app.settings_button = button(ib, "Settings...", ID_SETTINGS);
    app.start_box = ib.NewObjectTagList(null, cb_class.CHECKBOX_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_START),
        pair(gc.GA_RelVerify, 1),
        .{},
    });

    const row_height = fontHeight(app);
    const actions = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.join_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.leave_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.forget_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.start_box orelse return null)),
        pair(lg.CHILDA_Label, @intFromPtr("Join at s_tart")),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.scan_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.settings_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        .{},
    }) orelse return null;
    const networks_group = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_FrameTitle, @intFromPtr("Networks in range")),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 4),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.list orelse return null)),
        pair(lg.CHILDA_MinHeight, rows_shown * row_height + 24),
        pair(lg.CHILDA_MinWidth, list_columns * fontWidth(app) + 24),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(actions)),
        pair(lg.CHILDA_WeightHeight, 0),
        .{},
    }) orelse return null;
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.chooser orelse return null)),
        pair(lg.CHILDA_Label, @intFromPtr("_Radio")),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.status_gadget orelse return null)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(networks_group)),
        .{},
    });
}

/// How wide a character of the screen's font is, which the passphrase
/// field is measured in.
fn fontWidth(app: *App) usize {
    const screen = app.ib.LockPubScreen(null) orelse return 8;
    defer app.ib.UnlockPubScreen(null, screen);
    const info = app.ib.GetScreenDrawInfo(screen);
    defer app.ib.FreeScreenDrawInfo(screen, info);
    const font = info.font orelse return 8;
    var extent = graphics.FontExtent{};
    app.gb.FontExtent(font, &extent);
    return @max(@as(usize, @intCast(@max(extent.width, 6))), 6);
}

/// How tall a row of the screen's font is, which the list's least height
/// is measured in.
fn fontHeight(app: *App) usize {
    const screen = app.ib.LockPubScreen(null) orelse return 16;
    defer app.ib.UnlockPubScreen(null, screen);
    const info = app.ib.GetScreenDrawInfo(screen);
    defer app.ib.FreeScreenDrawInfo(screen, info);
    const font = info.font orelse return 16;
    var extent = graphics.FontExtent{};
    app.gb.FontExtent(font, &extent);
    return @max(@as(usize, @intCast(@max(extent.height, 8))), 8);
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    var libraries: [10]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_][*:0]const u8{
        intuition.INTUITIONNAME,     graphics.GRAPHICSNAME,     bsd.SOCKETNAME,
        sdk.interface.utility.NAME,  lb.LISTBROWSER_LIBRARY,    st.STRING_LIBRARY,
        tx.TEXT_LIBRARY,             cb_class.CHECKBOX_LIBRARY, ch.CHOOSER_LIBRARY,
        sdk.expansion.EXPANSIONNAME,
    };
    for (wanted, 0..) |name, index| {
        libraries[index] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, name });
            return dos.RETURN_FAIL;
        };
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);
    const sb: *SocketBase = @ptrCast(libraries[2].?);
    const utility: *UtilityBase = @ptrCast(libraries[3].?);
    const eb: *ExpansionBase = @ptrCast(libraries[9].?);

    const files_memory = sys.AllocVec(@sizeOf(Files), exec.MEMF_ANY) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(files_memory);
    const memory = sys.AllocVec(@sizeOf(App), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const app: *App = @ptrCast(@alignCast(memory));
    app.* = .{
        .sys = sys,
        .dl = dl,
        .ib = ib,
        .gb = @ptrCast(libraries[1].?),
        .sb = sb,
        .files = @ptrCast(@alignCast(files_memory)),
        .link = .{ .sys = sys, .utility = utility },
    };
    app.rows.init(.unknown);
    defer lb.freeRows(sys, &app.rows);
    defer app.link.close();
    defer text.wipe(&app.typed);

    app.radio_count = radio_file.find(sys, dl, sb, eb, &app.files.bytes, &app.radios);
    for (app.radios[0..app.radio_count], 0..) |*one, index| {
        app.radio_labels[index] = one.label.ptr();
        if (rdargs.string(argv[arg_interface])) |asked| {
            const name = text.spanOf(asked);
            if (text.sameWord(text.untilNul(&one.interface), name) or text.sameWord(text.untilNul(&one.file), name)) app.current = index;
        }
    }
    if (app.radio_count == 0) {
        app.radio_labels[0] = "no radio";
        app.status.put("No radio: no device here answers the wireless requests");
    }
    app.shown_status = app.status;

    app.timer_port = sys.CreateMsgPort();
    if (app.timer_port) |port| {
        app.timer_req.node.message.reply_port = port;
        app.timer_req.node.message.length = @sizeOf(timer.TimeRequest);
        app.timer_open = sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &app.timer_req.node, 0) == 0;
    }
    defer app.stopTimer();

    const layout = buildLayout(app) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    app.object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr("Wi-Fi")),
        pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_SizeGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(app.object);
    var open = wc.WmOpen{};
    if (ib.SendMessage(app.object.?, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }
    var at: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, app.object.?, &at);
    app.window = @ptrFromInt(at);
    defer app.closeAsk();

    app.showButtons();
    if (app.radio_count != 0) app.pickRadio(app.current);
    app.startTimer();

    var code_word: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code_word };
    while (true) {
        var mask: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_SigMask, app.object.?, &mask);
        var ask_mask: usize = 0;
        if (app.ask_object) |object| _ = ib.GetAttr(wc.WINDOWA_SigMask, object, &ask_mask);
        const got = sys.Wait(@as(u32, @intCast(mask | ask_mask)) | app.link.scanMask() | app.timerMask() | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_OK;
        if (got & app.link.scanMask() != 0) app.scanned();
        if (got & app.timerMask() != 0) app.ticked();

        // The window that asks for a passphrase, while it is up.
        if (app.ask_object) |object| {
            while (true) {
                const word = ib.SendMessage(object, @ptrCast(&handle));
                if (word == wc.WMHI_LASTMSG) break;
                switch (word & wc.WMHI_CLASSMASK) {
                    wc.WMHI_CLOSEWINDOW => {
                        app.closeAsk();
                        app.held = 0;
                        app.refreshLine();
                        break;
                    },
                    wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                        ID_ASK_JOIN => {
                            app.askJoin();
                            if (app.ask_object != object) break;
                        },
                        ID_PASSPHRASE => if (entered(code_word)) {
                            app.askJoin();
                            if (app.ask_object != object) break;
                        },
                        ID_ASK_CANCEL => {
                            app.closeAsk();
                            app.held = 0;
                            app.refreshLine();
                            break;
                        },
                        else => {},
                    },
                    else => {},
                }
            }
        }

        while (true) {
            const word = ib.SendMessage(app.object.?, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_RADIO => if (code_word < app.radio_count and code_word != app.current) app.pickRadio(code_word),
                    ID_NETWORKS => {
                        app.pickRow();
                        if (code_word & lb.LISTBROWSER_DOUBLE != 0) app.joinPicked();
                    },
                    ID_JOIN => app.joinPicked(),
                    ID_LEAVE => app.leave(),
                    ID_FORGET => app.forget(),
                    ID_SCAN => app.scan(),
                    ID_START => app.toggleStart(),
                    ID_SETTINGS => app.openSettings(),
                    else => {},
                },
                else => {},
            }
        }
    }
}
