// SPDX-License-Identifier: MIT
//! Bluetooth: the system's Bluetooth controllers set, and the devices
//! around found, paired and linked, in a window. Built against the SDK
//! only.
//!
//!   Bluetooth CONTROLLER/K/N
//!
//! CONTROLLER is the controller to start on, by its number; without it,
//! the first there is.
//!
//! **The controllers** are bluetooth.library's: the board's own, which
//! opening the library brings up, and those their drivers offer - a USB
//! one once it is plugged in. With more than one, the chooser at the top
//! picks the one the window works on.
//!
//! **The line under it** says where the controller is: being set up,
//! failed and why, off, or on - and whether devices that search find this
//! one, until when where it is for a time. A message - what a search
//! found, why a change did not work - stands there for a few seconds; a
//! pairing, and a link or a bond being made or ended, say there that
//! they are under way until they are over.
//!
//! **On** turns the controller on and off; **Name** is the name other
//! devices see, set when the field is left - emptied, the machine's;
//! **Visible to others** has devices that search find this one, until it
//! is cleared. The library keeps all three for the controller's next
//! start.
//!
//! **The devices** are the controller's bonds, its links, and what its
//! last search found, one line each (devices.zig): its name, what it is,
//! the signal it was heard with, its state - paired, connected,
//! encrypted, the drivers that drive it - and its address, a device
//! linked drawn bold. **Search** looks for the devices around for ten
//! seconds, the list growing as they are found.
//!
//! **Pair** pairs with the device picked, **Connect** and **Disconnect**
//! make and end a link to it, and **Forget...** ends its bond once a
//! requester has asked; a double click pairs with a device without a
//! bond, and connects to one with a bond and no link. The calls that wait
//! for a device are made by a process of the window's own (worker.zig),
//! one at a time.
//!
//! **The pairings.** While it is open the window is the pairings' agent
//! (AddBTAgent) - of its own and of those a device begins. What a pairing
//! needs - whether a device shows the number shown, the number it shows,
//! the PIN it takes, a number to be typed on it, whether a device with
//! nothing to compare may pair - is asked in a window of its own
//! (pairing.zig), which goes once it is answered, or once its pairing is
//! over.
//!
//! The window follows the library: whatever changes - a controller, a
//! device found, a link, a bond - the library signals, and the window
//! reads it all again, twice a second at the most.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const graphics = sdk.graphics;
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const locale = sdk.locale;
const timer = sdk.devices.timer;
const strings = @import("strings");
const devices = @import("devices.zig");
const Device = devices.Device;
const pairing_text = @import("pairing.zig");
const worker_file = @import("worker.zig");
const Worker = worker_file.Worker;
const Job = worker_file.Job;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const BluetoothBase = sdk.interface.bluetooth.BluetoothBase;
const TagItem = sdk.utility.TagItem;
const Object = intuition.Object;
const rdargs = dos.rdargs;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const lb = sdk.gadgets.listbrowser;
const st = sdk.gadgets.string;
const tx = sdk.gadgets.text;
const cb_class = sdk.gadgets.checkbox;
const ch = sdk.gadgets.chooser;
const Text = locale.Strings(strings);
const Id = strings.Id;

pub const COMMAND_NAME = "Bluetooth";
const VERSION = "1.1";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (23.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "CONTROLLER/K/N";
const arg_controller = 0;
const arg_count = 1;

/// The gadgets.
const ID_CONTROLLER = 1;
const ID_ON = 2;
const ID_NAME = 3;
const ID_VISIBLE = 4;
const ID_DEVICES = 5;
const ID_SEARCH = 6;
const ID_PAIR = 7;
const ID_CONNECT = 8;
const ID_DISCONNECT = 9;
const ID_FORGET = 10;
/// The pairing window's.
const ID_ASK_YES = 11;
const ID_ASK_NO = 12;
const ID_ASK_FIELD = 13;

/// The buttons under the list, in the order `shown_buttons` keeps them.
const button_pair = 0;
const button_connect = 1;
const button_disconnect = 2;
const button_forget = 3;
const button_search = 4;
const button_count = 5;

/// The keys that end a field's typing with what was typed, Return and
/// Enter, as its GADGETUP's code.
const raw_return: u32 = 0x44;
const raw_enter: u32 = 0x43;

fn entered(code: u32) bool {
    return code == raw_return or code == raw_enter;
}

/// The tick: the list made again at most once a tick, a message held for
/// `message_ticks`, a time to be visible counted down every
/// `countdown_ticks`.
const tick_us: u64 = 500_000;
const message_ticks: u32 = 10;
const countdown_ticks: u32 = 2;
/// How long a search looks.
const search_seconds: u32 = 10;
/// How long the line says a pairing is under way where its end never
/// comes: past the library's minute for a pairing and its twenty seconds
/// to hear an LE device.
const pairing_ticks: u32 = 200;

/// As many controllers as the chooser offers.
const controllers_most = 4;
/// The longest name a controller shows, its NUL aside.
const name_most = 248;

/// The room the status line keeps, whatever it says: a longer line is cut
/// at the window's edge.
const status_room = "x" ** 80;
/// How many rows the list shows without being made taller, how many
/// characters wide it is at the least, how many the name field is.
const rows_shown = 12;
const list_columns: usize = 120;
const name_columns: usize = 28;
/// How wide the pairing window's question is, in characters, and how much
/// room its text has in bytes.
const ask_columns: usize = 44;
const ask_text_most = 480;

/// The list's columns: name, kind, signal, state, address.
const column_count = 5;
const column_weights = [column_count]u16{ 22, 18, 19, 30, 30 };
const column_titles = [column_count]Id{ .MSG_COLUMN_NAME, .MSG_COLUMN_KIND, .MSG_COLUMN_SIGNAL, .MSG_COLUMN_STATE, .MSG_COLUMN_ADDRESS };

/// What each kind (BTDK_*) is called; none for BTDK_NONE.
const kind_names = [_]?Id{
    null,                  .MSG_KIND_COMPUTER,     .MSG_KIND_LAPTOP,       .MSG_KIND_HANDHELD,
    .MSG_KIND_PHONE,       .MSG_KIND_ACCESS_POINT, .MSG_KIND_HEADSET,      .MSG_KIND_HANDS_FREE,
    .MSG_KIND_MICROPHONE,  .MSG_KIND_LOUDSPEAKER,  .MSG_KIND_HEADPHONES,   .MSG_KIND_PORTABLE_AUDIO,
    .MSG_KIND_CAR_AUDIO,   .MSG_KIND_HIFI,         .MSG_KIND_DISPLAY,      .MSG_KIND_GAME_CONSOLE,
    .MSG_KIND_AUDIO_VIDEO, .MSG_KIND_KEYBOARD,     .MSG_KIND_MOUSE,        .MSG_KIND_KEYBOARD_MOUSE,
    .MSG_KIND_JOYSTICK,    .MSG_KIND_GAMEPAD,      .MSG_KIND_REMOTE,       .MSG_KIND_TABLET,
    .MSG_KIND_PERIPHERAL,  .MSG_KIND_IMAGING,      .MSG_KIND_WEARABLE,     .MSG_KIND_TOY,
    .MSG_KIND_HEALTH,      .MSG_KIND_EARBUDS,      .MSG_KIND_WATCH,        .MSG_KIND_CLOCK,
    .MSG_KIND_TAG,         .MSG_KIND_KEYRING,      .MSG_KIND_MEDIA_PLAYER, .MSG_KIND_THERMOMETER,
    .MSG_KIND_HEART_RATE,  .MSG_KIND_SENSOR,       .MSG_KIND_LIGHT,        .MSG_KIND_AUDIO_SOURCE,
    .MSG_KIND_HEARING_AID,
};

comptime {
    if (kind_names.len != bluetooth.BTDK_LAST + 1) @compileError("a kind without a name");
}

fn pair(tag: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = tag, .data = data };
}

/// A signal in a word, by how a link fares on it.
fn signalWord(dbm: i32) Id {
    if (dbm >= -55) return .MSG_SIGNAL_EXCELLENT;
    if (dbm >= -70) return .MSG_SIGNAL_GOOD;
    if (dbm >= -85) return .MSG_SIGNAL_FAIR;
    return .MSG_SIGNAL_WEAK;
}

/// Why a controller failed, or a call did not work: BTERR_*, or the
/// status the controller answered.
fn why(result: i32) Id {
    return switch (result) {
        bluetooth.BTERR_NOMEM => .MSG_WHY_NOMEM,
        bluetooth.BTERR_OPENFAIL => .MSG_WHY_OPENFAIL,
        bluetooth.BTERR_TIMEOUT => .MSG_WHY_TIMEOUT,
        bluetooth.BTERR_DETACHED => .MSG_WHY_DETACHED,
        bluetooth.BTERR_PROTOCOL => .MSG_WHY_PROTOCOL,
        bluetooth.BTERR_NOCONTROLLER => .MSG_WHY_NOCONTROLLER,
        bluetooth.BTERR_NOTUP => .MSG_WHY_NOTUP,
        bluetooth.BTERR_OFF => .MSG_WHY_OFF,
        bluetooth.BTERR_UNSUPPORTED => .MSG_WHY_UNSUPPORTED,
        bluetooth.BTERR_BUSY => .MSG_WHY_BUSY,
        hci.HCI_ERR_UNKNOWN_COMMAND => .MSG_WHY_UNKNOWN_COMMAND,
        hci.HCI_ERR_HARDWARE_FAILURE => .MSG_WHY_HARDWARE,
        else => .MSG_WHY_REFUSED,
    };
}

/// Why a pairing, a link or the end of a bond did not work: the reasons
/// that are a device's, else the controller's (`why`).
fn whyDevice(result: i32) Id {
    return switch (result) {
        bluetooth.BTERR_NOMEM => .MSG_WHY_NO_ROOM,
        bluetooth.BTERR_TIMEOUT => .MSG_WHY_NO_ANSWER,
        bluetooth.BTERR_BONDED => .MSG_WHY_BONDED,
        bluetooth.BTERR_NOTBONDED => .MSG_WHY_NOT_BONDED,
        bluetooth.BTERR_NOTCONNECTED => .MSG_WHY_NOT_LINKED,
        bluetooth.BTERR_REFUSED => .MSG_WHY_ANSWER_REFUSED,
        hci.HCI_ERR_PAGE_TIMEOUT, hci.HCI_ERR_FAILED_TO_ESTABLISH, hci.HCI_ERR_LMP_RESPONSE_TIMEOUT => .MSG_WHY_NO_ANSWER,
        hci.HCI_ERR_CONNECTION_TIMEOUT => .MSG_WHY_LOST,
        hci.HCI_ERR_REMOTE_USER_TERMINATED, hci.HCI_ERR_REMOTE_LOW_RESOURCES, hci.HCI_ERR_REMOTE_POWER_OFF => .MSG_WHY_DEVICE_ENDED,
        hci.HCI_ERR_LOCAL_HOST_TERMINATED => .MSG_WHY_ENDED_HERE,
        hci.HCI_ERR_REJECTED_LIMITED_RESOURCES, hci.HCI_ERR_REJECTED_SECURITY, hci.HCI_ERR_REJECTED_ADDRESS => .MSG_WHY_DEVICE_REFUSED,
        hci.HCI_ERR_AUTHENTICATION_FAILURE => .MSG_WHY_NUMBERS,
        hci.HCI_ERR_PIN_OR_KEY_MISSING => .MSG_WHY_KEY_MISSING,
        hci.HCI_ERR_PAIRING_NOT_ALLOWED => .MSG_WHY_NOT_PAIRING,
        hci.HCI_ERR_REPEATED_ATTEMPTS => .MSG_WHY_REPEATED,
        hci.HCI_ERR_INSUFFICIENT_SECURITY => .MSG_WHY_SHORT_KEY,
        else => why(result),
    };
}

/// An address as it is written, the most significant byte first.
fn addressText(address: *const [6]u8, into: *[18]u8) [*:0]const u8 {
    const hex = "0123456789ABCDEF";
    for (0..6) |index| {
        const octet = address[5 - index];
        into[index * 3] = hex[octet >> 4];
        into[index * 3 + 1] = hex[octet & 0xF];
        into[index * 3 + 2] = if (index == 5) 0 else ':';
    }
    return @ptrCast(into);
}

fn spanOf(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}

fn same(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |mine, theirs| {
        if (mine != theirs) return false;
    }
    return true;
}

/// Whether two addresses are one: of one kind, with the same bytes.
fn sameAddress(one: *const bluetooth.BTAddress, other: *const bluetooth.BTAddress) bool {
    return one.kind == other.kind and same(&one.bytes, &other.bytes);
}

/// What a device is called on the line and in the requesters: its name,
/// or its address while it has none.
const Who = [worker_file.who_most + 1]u8;

fn whoOf(name: [*:0]const u8, address: *const bluetooth.BTAddress) Who {
    var who: Who = @splat(0);
    var address_text: [18]u8 = undefined;
    const shown = if (name[0] != 0) spanOf(name) else spanOf(addressText(&address.bytes, &address_text));
    const length = @min(shown.len, who.len - 1);
    @memcpy(who[0..length], shown[0..length]);
    return who;
}

/// A tag that is there only where `present`: TAG_IGNORE otherwise, so
/// that a gadget a window does not have is left out of its layout.
fn when(present: bool, tag: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = if (present) tag else sdk.utility.TAG_IGNORE, .data = data };
}

/// A line of text a gadget points at: written over where it is, never
/// moved, so that the gadget may keep it.
const line_most = 200;
const Line = struct {
    bytes: [line_most + 1]u8 = @splat(0),
    length: usize = 0,

    fn clear(line: *Line) void {
        line.length = 0;
        line.bytes[0] = 0;
    }

    fn ptr(line: *const Line) [*:0]const u8 {
        return @ptrCast(&line.bytes);
    }

    fn slice(line: *const Line) []const u8 {
        return line.bytes[0..line.length];
    }

    fn put(line: *Line, text: []const u8) void {
        const length = @min(text.len, line_most - line.length);
        @memcpy(line.bytes[line.length..][0..length], text[0..length]);
        line.length += length;
        line.bytes[line.length] = 0;
    }

    /// The string `id` with `args`, in place of what the line held.
    fn say(line: *Line, words: *const Text, comptime id: Id, args: anytype) void {
        line.length = words.format(&line.bytes, id, args).len;
    }
};

/// A controller as the window last read it.
const Controller = struct {
    id: u32 = 0,
    state: u32 = bluetooth.BTCS_OPENING,
    failure: i32 = 0,
    flags: u32 = 0,
    visible_left: u32 = 0,
    name: [name_most + 1]u8 = @splat(0),
    label: Line = .{},

    fn up(controller: *const Controller) bool {
        return controller.state == bluetooth.BTCS_UP;
    }

    fn powered(controller: *const Controller) bool {
        return controller.up() and controller.flags & bluetooth.BTCF_POWERED != 0;
    }

    fn searching(controller: *const Controller) bool {
        return controller.powered() and controller.flags & bluetooth.BTCF_DISCOVERING != 0;
    }

    /// Whether it is visible for a time, which the line counts down.
    fn countingDown(controller: *const Controller) bool {
        return controller.powered() and controller.flags & bluetooth.BTCF_VISIBLE != 0 and
            controller.visible_left != bluetooth.BT_VISIBLE_ALWAYS;
    }
};

/// A number to be typed on a device, as its pairing gave it.
const Shown = struct {
    address: bluetooth.BTAddress,
    number: u32,
    who: Who,
};

/// A pairing under way.
const Pairing = struct {
    address: bluetooth.BTAddress,
    who: Who,
};

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    bt: *BluetoothBase,
    words: *const Text,

    /// The window and its layout's root.
    object: ?*Object = null,
    window: ?*intuition.Window = null,

    /// The controllers, the one the window works on - by its number, the
    /// one asked for until it is there - and the chooser's labels.
    controllers: [controllers_most]Controller = @splat(.{}),
    controller_count: usize = 0,
    current: usize = 0,
    wanted: ?u32 = null,
    labels: [controllers_most + 1:null]?[*:0]const u8 = @splat(null),

    /// The devices, the list's rows, and the device picked, by its
    /// address, so that the list made again keeps it picked.
    table: devices.Table = .{},
    rows: exec.List = .{},
    picked: ?bluetooth.BTAddress = null,
    /// The columns, their titles in the catalog's language.
    columns: [column_count + 1]lb.Column = @splat(.{}),
    /// A row's texts while it is made, copied into the row.
    cells: [column_count]Line = @splat(.{}),

    /// What the status line says and what it shows; how many more ticks a
    /// message stays.
    status: Line = .{},
    shown_status: Line = .{},
    held: u32 = 0,
    /// What the gadgets show of the controller: its name in the field,
    /// whether the boxes are set, whether they may be used.
    shown_name: [name_most + 1]u8 = @splat(0),
    shown_on: bool = false,
    shown_visible: bool = false,
    shown_visible_usable: bool = true,
    shown_usable: bool = true,
    /// Whether each button under the list may be pressed, as it shows.
    shown_buttons: [button_count]bool = @splat(false),
    /// Whether the controller was searching when last read, so that the
    /// search's end is said.
    was_searching: bool = false,

    /// The library's signal: something changed. Read again at once, or -
    /// read once this tick already - at the next.
    notify: ?*bluetooth.BTNotify = null,
    notify_bit: i8 = -1,
    read_this_tick: bool = false,
    dirty: bool = false,

    /// The worker that makes the calls that wait for a device, started at
    /// the first; the call asked of it, until its end is taken.
    worker: ?*Worker = null,
    job: ?Job = null,

    /// The agent: what the pairings ask comes to its port.
    agent_port: ?*exec.MsgPort = null,
    agent: ?*bluetooth.BTAgent = null,
    /// The pairings' questions, each the library's message: the first is
    /// asked in the pairing window, the rest after it; each is replied
    /// once it is answered, or once its pairing is over.
    questions: exec.List = .{},
    /// The number a device is to have typed on it, until its pairing is
    /// over or the window that shows it is closed.
    number_shown: ?Shown = null,
    /// The pairing the line says is under way, until its end - or, where
    /// that never comes, `pairing_left` ticks.
    pairing: ?Pairing = null,
    pairing_left: u32 = 0,

    /// The pairing window, its texts - the question, the device's name
    /// in it, the number - and its field.
    ask_object: ?*Object = null,
    ask_window: ?*intuition.Window = null,
    ask_text: [ask_text_most + 1]u8 = @splat(0),
    ask_name: pairing_text.Name = @splat(0),
    ask_number: pairing_text.Number = @splat(0),
    ask_field: ?*Object = null,

    /// The tick.
    timer_req: timer.TimeRequest = .{},
    timer_port: ?*exec.MsgPort = null,
    timer_open: bool = false,
    timer_out: bool = false,
    ticks: u32 = 0,

    chooser: ?*Object = null,
    status_gadget: ?*Object = null,
    on_box: ?*Object = null,
    name_field: ?*Object = null,
    visible_box: ?*Object = null,
    list: ?*Object = null,
    pair_button: ?*Object = null,
    connect_button: ?*Object = null,
    disconnect_button: ?*Object = null,
    forget_button: ?*Object = null,
    search_button: ?*Object = null,

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

    fn checked(app: *App, object: ?*Object) bool {
        var value: usize = 0;
        _ = app.ib.GetAttr(cb_class.CHECKBOX_Checked, object orelse return false, &value);
        return value != 0;
    }

    /// What a string gadget holds now.
    fn textOf(app: *App, object: ?*Object) [*:0]const u8 {
        var at: usize = 0;
        _ = app.ib.GetAttr(gc.STRINGA_TextVal, object orelse return "", &at);
        if (at == 0) return "";
        return @ptrFromInt(at);
    }

    /// A message on the status line, which stays there `message_ticks`
    /// before the line says where the controller is again.
    fn say(app: *App, comptime id: Id, args: anytype) void {
        app.status.say(app.words, id, args);
        app.held = message_ticks;
        app.showStatus();
    }

    /// The status line drawn, only when it says something else than it
    /// did.
    fn showStatus(app: *App) void {
        if (same(app.status.slice(), app.shown_status.slice())) return;
        app.shown_status = app.status;
        app.set(app.status_gadget, &.{ pair(tx.TEXT_Text, @intFromPtr(app.shown_status.ptr())), .{} });
    }

    fn controller(app: *App) ?*Controller {
        if (app.current >= app.controller_count) return null;
        return &app.controllers[app.current];
    }

    // --- reading the library -----------------------------------------------------

    /// Everything read again and shown: the controllers, the line, the
    /// gadgets and the list.
    fn refresh(app: *App) void {
        app.read_this_tick = true;
        app.dirty = false;
        app.readControllers();
        app.readDevices();
        const now = if (app.controller()) |picked| picked.searching() else false;
        if (app.was_searching and !now) switch (app.foundCount()) {
            0 => app.say(.MSG_FOUND_NONE, .{}),
            1 => app.say(.MSG_FOUND_ONE, .{}),
            else => |count| app.say(.MSG_FOUND, .{@as(u32, @intCast(count))}),
        };
        app.was_searching = now;
        app.showLine();
        app.showSettings();
        app.showList();
        app.showButtons();
    }

    /// The library's signal: read at once, or at the next tick where it
    /// was read this one already.
    fn changed(app: *App) void {
        if (app.read_this_tick) {
            app.dirty = true;
            return;
        }
        app.refresh();
    }

    /// The controllers read; the one the window works on kept, or the
    /// first where it has gone; the chooser's labels made again where they
    /// changed.
    fn readControllers(app: *App) void {
        const list = app.bt.ObtainBTControllers() orelse return;
        defer app.bt.ReleaseBTControllers(list);
        var count: usize = 0;
        var relabel = false;
        var it = list.iterator();
        while (it.next()) |node| {
            if (count == controllers_most) break;
            const found: *bluetooth.BTController = @fieldParentPtr("node", node);
            const kept = &app.controllers[count];
            const before = kept.label;
            kept.id = found.id;
            kept.state = found.state;
            kept.failure = found.failure;
            kept.flags = found.flags;
            kept.visible_left = found.visible_left;
            const name = spanOf(found.name);
            const length = @min(name.len, name_most);
            @memcpy(kept.name[0..length], name[0..length]);
            kept.name[length] = 0;
            var address_text: [18]u8 = undefined;
            const address = &found.address.bytes;
            const unknown = address[0] | address[1] | address[2] | address[3] | address[4] | address[5] == 0;
            kept.label.say(app.words, .MSG_CONTROLLER_LABEL, .{
                found.id,
                if (unknown) @as([*:0]const u8, "--:--:--:--:--:--") else addressText(address, &address_text),
                found.node.name orelse @as([*:0]const u8, "?"),
                found.unit,
            });
            if (!same(before.slice(), kept.label.slice())) relabel = true;
            count += 1;
        }
        if (count != app.controller_count) relabel = true;
        app.controller_count = count;
        app.current = 0;
        if (app.wanted) |wanted| {
            for (app.controllers[0..count], 0..) |*one, index| {
                if (one.id == wanted) app.current = index;
            }
        }
        if (count != 0 and app.wanted == null) app.wanted = app.controllers[0].id;
        if (!relabel) return;
        for (app.controllers[0..count], 0..) |*one, index| app.labels[index] = one.label.ptr();
        if (count == 0) app.labels[0] = app.words.get(.MSG_NO_CONTROLLER_LABEL);
        app.labels[@max(count, 1)] = null;
        app.set(app.chooser, &.{
            pair(ch.CHOOSER_Labels, @intFromPtr(&app.labels)),
            pair(ch.CHOOSER_Active, app.current),
            pair(gc.GA_Disabled, @intFromBool(count < 2)),
            .{},
        });
    }

    /// The devices of the controller read: its bonds, its links, what it
    /// found.
    fn readDevices(app: *App) void {
        app.table.clear();
        const picked = app.controller() orelse return;
        const bt = app.bt;
        if (bt.ObtainBTBonds(picked.id)) |list| {
            defer bt.ReleaseBTBonds(list);
            var it = list.iterator();
            while (it.next()) |node| app.table.addBond(@fieldParentPtr("node", node));
        }
        if (bt.ObtainBTConnections(picked.id)) |list| {
            defer bt.ReleaseBTConnections(list);
            var it = list.iterator();
            while (it.next()) |node| app.table.addLink(@fieldParentPtr("node", node));
        }
        if (bt.ObtainBTDevices(picked.id)) |list| {
            defer bt.ReleaseBTDevices(list);
            var it = list.iterator();
            while (it.next()) |node| app.table.addFound(@fieldParentPtr("node", node));
        }
    }

    fn foundCount(app: *App) usize {
        var count: usize = 0;
        for (app.table.slice()) |*device| {
            if (device.found) count += 1;
        }
        return count;
    }

    // --- the controller ----------------------------------------------------------

    /// The status line made from the controller, unless a message stands
    /// there.
    fn showLine(app: *App) void {
        if (app.held != 0) return;
        const words = app.words;
        const line = &app.status;
        // What is under way, until it is over.
        if (app.job) |job| {
            const who: [*:0]const u8 = @ptrCast(&job.who);
            switch (job.kind) {
                .connect => line.say(words, .MSG_CONNECTING, .{who}),
                .disconnect => line.say(words, .MSG_DISCONNECTING, .{who}),
                .forget => line.say(words, .MSG_FORGETTING, .{who}),
            }
            return app.showStatus();
        }
        if (app.pairing) |pairing| {
            line.say(words, .MSG_PAIRING, .{@as([*:0]const u8, @ptrCast(&pairing.who))});
            return app.showStatus();
        }
        const picked = app.controller() orelse {
            line.say(words, .MSG_NO_CONTROLLER, .{});
            return app.showStatus();
        };
        switch (picked.state) {
            bluetooth.BTCS_UP => {},
            bluetooth.BTCS_FAILED => {
                line.say(words, .MSG_FAILED, .{words.get(why(picked.failure))});
                return app.showStatus();
            },
            else => {
                line.say(words, .MSG_STARTING, .{});
                return app.showStatus();
            },
        }
        if (!picked.powered()) {
            line.say(words, .MSG_OFF, .{});
        } else if (picked.searching()) {
            line.say(words, .MSG_SEARCHING, .{});
        } else if (picked.flags & bluetooth.BTCF_VISIBLE == 0) {
            line.say(words, .MSG_HIDDEN, .{});
        } else if (picked.visible_left == bluetooth.BT_VISIBLE_ALWAYS) {
            line.say(words, .MSG_SHOWN, .{});
        } else {
            line.say(words, .MSG_SHOWN_FOR, .{picked.visible_left});
        }
        app.showStatus();
    }

    /// The boxes and the name field set from the controller, each only
    /// where it shows something else.
    fn showSettings(app: *App) void {
        const picked = app.controller();
        const up = picked != null and picked.?.up();
        const powered = picked != null and picked.?.powered();
        const on = powered;
        const visible = powered and picked.?.flags & bluetooth.BTCF_VISIBLE != 0;
        if (up != app.shown_usable) {
            app.enable(app.on_box, up);
            app.enable(app.name_field, up);
            app.shown_usable = up;
        }
        if (on != app.shown_on) {
            app.set(app.on_box, &.{ pair(cb_class.CHECKBOX_Checked, @intFromBool(on)), .{} });
            app.shown_on = on;
        }
        if (visible != app.shown_visible or powered != app.shown_visible_usable) {
            app.set(app.visible_box, &.{
                pair(cb_class.CHECKBOX_Checked, @intFromBool(visible)),
                pair(gc.GA_Disabled, @intFromBool(!powered)),
                .{},
            });
            app.shown_visible = visible;
            app.shown_visible_usable = powered;
        }
        const name: []const u8 = if (picked) |one| spanOf(@ptrCast(&one.name)) else "";
        if (!same(name, spanOf(@ptrCast(&app.shown_name)))) {
            @memcpy(app.shown_name[0..name.len], name);
            app.shown_name[name.len] = 0;
            app.set(app.name_field, &.{ pair(gc.STRINGA_TextVal, @intFromPtr(&app.shown_name)), .{} });
        }
    }

    /// Pair, Connect, Disconnect, Forget and Search made usable where they
    /// may be pressed, each only where that changed.
    fn showButtons(app: *App) void {
        const picked = app.controller();
        const powered = picked != null and picked.?.powered();
        const device = app.pickedDevice();
        const idle = app.job == null;
        const not_pairing = app.pairing == null;
        const bonded = device != null and device.?.bonded;
        const linked = device != null and device.?.linked;
        var usable: [button_count]bool = undefined;
        usable[button_pair] = powered and device != null and !bonded and idle and not_pairing;
        usable[button_connect] = powered and device != null and !linked and idle;
        usable[button_disconnect] = linked and idle;
        usable[button_forget] = bonded and idle and not_pairing;
        usable[button_search] = powered and !picked.?.searching();
        const buttons = [button_count]?*Object{ app.pair_button, app.connect_button, app.disconnect_button, app.forget_button, app.search_button };
        for (usable, buttons, &app.shown_buttons) |wanted, object, *shown| {
            if (wanted == shown.*) continue;
            app.enable(object, wanted);
            shown.* = wanted;
        }
    }

    /// The controller `index` of the chooser picked.
    fn pickController(app: *App, index: usize) void {
        if (index >= app.controller_count or index == app.current) return;
        app.wanted = app.controllers[index].id;
        app.picked = null;
        app.held = 0;
        app.refresh();
    }

    /// The controller set by `tags`; said where it did not work.
    fn setAttrs(app: *App, tags: []const TagItem) void {
        const picked = app.controller() orelse return;
        const result = app.bt.SetBTControllerAttrs(picked.id, tags.ptr);
        if (result != 0) app.say(.MSG_NOT_SET, .{app.words.get(why(result))});
        app.refresh();
    }

    // Each of these keeps what its gadget shows now - the box clicked, the
    // name typed - so that the refresh after sets the gadget back where
    // the controller did not take it.

    fn setOn(app: *App) void {
        const wanted = app.checked(app.on_box);
        app.shown_on = wanted;
        app.setAttrs(&.{ pair(bluetooth.BTCA_Powered, @intFromBool(wanted)), .{} });
    }

    fn setVisible(app: *App) void {
        const wanted = app.checked(app.visible_box);
        app.shown_visible = wanted;
        app.setAttrs(&.{ pair(bluetooth.BTCA_Visible, if (wanted) bluetooth.BT_VISIBLE_ALWAYS else 0), .{} });
    }

    /// The name typed, where it is another; emptied, the machine's.
    fn setName(app: *App) void {
        const picked = app.controller() orelse return;
        const typed = spanOf(app.textOf(app.name_field));
        if (same(typed, spanOf(@ptrCast(&picked.name)))) return;
        const length = @min(typed.len, name_most);
        @memcpy(app.shown_name[0..length], typed[0..length]);
        app.shown_name[length] = 0;
        app.setAttrs(&.{ pair(bluetooth.BTCA_Name, @intFromPtr(&app.shown_name)), .{} });
    }

    /// Search: the controller made to look for the devices around.
    fn search(app: *App) void {
        const picked = app.controller() orelse return;
        const result = app.bt.StartBTDiscovery(picked.id, search_seconds);
        if (result != 0) {
            app.say(.MSG_NOT_SEARCHING, .{app.words.get(why(result))});
            return;
        }
        app.held = 0;
        app.refresh();
    }

    // --- the list ------------------------------------------------------------------

    /// A device's texts made in `cells`: its name, what it is, its signal,
    /// its state and its address.
    fn cellsOf(app: *App, device: *const Device) void {
        const words = app.words;
        const cells = &app.cells;
        for (cells) |*cell| cell.clear();

        if (device.name[0] != 0) {
            cells[0].put(spanOf(@ptrCast(&device.name)));
        } else {
            cells[0].put(spanOf(words.get(.MSG_NO_NAME)));
        }

        const kind = app.bt.BTDeviceKind(device.class_of_device, device.appearance);
        if (kind < kind_names.len) {
            if (kind_names[kind]) |id| cells[1].put(spanOf(words.get(id)));
        }

        if (device.rssi != bluetooth.BT_RSSI_NONE) {
            const dbm: i32 = device.rssi;
            cells[2].say(words, .MSG_SIGNAL, .{ dbm, words.get(signalWord(dbm)) });
        }

        const state = &cells[3];
        if (device.bonded) state.put(spanOf(words.get(.MSG_STATE_PAIRED)));
        if (device.linked) {
            if (state.length != 0) state.put(", ");
            const pairing = device.link_flags & bluetooth.BTLF_PAIRING != 0;
            state.put(spanOf(words.get(if (pairing) .MSG_STATE_PAIRING else .MSG_STATE_CONNECTED)));
            if (device.link_flags & bluetooth.BTLF_ENCRYPTED != 0) {
                state.put(", ");
                state.put(spanOf(words.get(.MSG_STATE_ENCRYPTED)));
            }
        }
        if (device.drivers[0] != 0) {
            if (state.length != 0) state.put(", ");
            state.put(spanOf(@ptrCast(&device.drivers)));
        }

        var address_text: [18]u8 = undefined;
        const address = addressText(&device.address.bytes, &address_text);
        switch (device.address.kind) {
            bluetooth.BTADDR_LE_PUBLIC => cells[4].say(words, .MSG_ADDRESS_LE, .{address}),
            bluetooth.BTADDR_LE_RANDOM => cells[4].say(words, .MSG_ADDRESS_RANDOM, .{address}),
            else => cells[4].put(spanOf(address)),
        }
    }

    /// The list made anew from the devices, the one picked kept; given to
    /// the gadget only where a row differs from what it shows.
    fn showList(app: *App) void {
        const sys = app.sys;
        var fresh: exec.List = .{};
        fresh.init(.unknown);
        var selected: u32 = lb.LISTBROWSER_NONE;
        var place: u32 = 0;
        for (app.table.slice(), 0..) |*device, index| {
            app.cellsOf(device);
            var texts: [column_count][*:0]const u8 = undefined;
            for (&texts, &app.cells) |*one, *cell| one.* = cell.ptr();
            const row = lb.allocRow(sys, &texts, 0) orelse break;
            row.user_data = index;
            if (device.linked) row.flags |= lb.ROW_MARKED;
            sys.AddTail(&fresh, &row.node);
            if (app.picked) |picked| {
                if (devices.sameDevice(&picked, &device.address)) selected = place;
            }
            place += 1;
        }
        if (sameRows(&fresh, &app.rows)) {
            lb.freeRows(sys, &fresh);
            return;
        }
        // Taken away without a window, so that the gadget is drawn once,
        // as the list is given back, and not empty in between.
        app.setIn(null, app.list, &.{ pair(lb.LISTBROWSER_Rows, lb.LISTBROWSER_DETACH), .{} });
        lb.freeRows(sys, &app.rows);
        while (sys.RemHead(&fresh)) |node| sys.AddTail(&app.rows, node);
        app.set(app.list, &.{
            pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.rows)),
            pair(lb.LISTBROWSER_Selected, selected),
            .{},
        });
    }

    /// The row picked taken as the device picked.
    fn pickRow(app: *App) void {
        var at: usize = 0;
        _ = app.ib.GetAttr(lb.LISTBROWSER_SelectedRow, app.list orelse return, &at);
        if (at != 0) {
            const row: *lb.Row = @ptrFromInt(at);
            if (row.user_data < app.table.count) app.picked = app.table.devices[row.user_data].address;
        }
        app.showButtons();
    }

    /// The device picked, as the table has it now; null where there is
    /// none, or it has gone.
    fn pickedDevice(app: *App) ?*Device {
        const picked = app.picked orelse return null;
        return app.table.find(&picked);
    }

    // --- the devices ---------------------------------------------------------------

    /// Pair: a pairing begun with the device picked, what it asks answered
    /// in the pairing window, its end said on the line.
    fn pairPicked(app: *App) void {
        const picked = app.controller() orelse return;
        const device = app.pickedDevice() orelse return;
        const who = whoOf(@ptrCast(&device.name), &device.address);
        const address = device.address;
        const result = app.bt.PairBTDevice(picked.id, &address, app.agent);
        if (result != 0) {
            app.say(.MSG_NOT_PAIRED, .{ @as([*:0]const u8, @ptrCast(&who)), app.words.get(whyDevice(result)) });
            return;
        }
        app.underWay(&address, &who);
    }

    /// A call that waits for the device picked made by the worker -
    /// started at the first - the line saying it is under way.
    fn askWorker(app: *App, kind: worker_file.Kind) void {
        const picked = app.controller() orelse return;
        const device = app.pickedDevice() orelse return;
        if (app.job != null) return;
        const job = Job{
            .kind = kind,
            .controller = picked.id,
            .address = device.address,
            .who = whoOf(@ptrCast(&device.name), &device.address),
        };
        if (app.worker == null) app.worker = Worker.start(app.sys, app.dl, app.bt);
        const worker = app.worker orelse return app.sayOutcome(&job, bluetooth.BTERR_NOMEM);
        worker.ask(&job);
        app.job = job;
        app.held = 0;
        app.showLine();
        app.showButtons();
    }

    /// Forget...: the device picked's bond ended, once a requester has
    /// asked.
    fn forgetPicked(app: *App) void {
        const device = app.pickedDevice() orelse return;
        const who = whoOf(@ptrCast(&device.name), &device.address);
        const easy = intuition.EasyStruct{
            .title = app.words.get(.MSG_WINDOW_TITLE),
            .text_format = app.words.get(.MSG_FORGET_ASK),
            .gadget_format = app.words.get(.MSG_FORGET_BUTTONS),
        };
        const args = .{@as([*:0]const u8, @ptrCast(&who))};
        comptime exec.checkFormat(strings.builtin(.MSG_FORGET_ASK), @TypeOf(args));
        const stream = exec.fmtStream(args);
        if (app.ib.EasyRequestArgs(app.window, &easy, null, &stream) != 1) return;
        app.askWorker(.forget);
    }

    /// A device's row double-clicked: paired with where it has no bond,
    /// connected to where it has one and no link.
    fn defaultAction(app: *App) void {
        const device = app.pickedDevice() orelse return;
        if (!device.bonded) {
            if (app.shown_buttons[button_pair]) app.pairPicked();
        } else if (!device.linked) {
            if (app.shown_buttons[button_connect]) app.askWorker(.connect);
        }
    }

    /// The worker's signal: the end of its call said, everything read
    /// again. A function of its own, as `agentMessages` is.
    noinline fn workerDone(app: *App) void {
        const worker = app.worker orelse return;
        var job: Job = .{};
        var result: i32 = 0;
        if (!worker.take(&job, &result)) return;
        app.job = null;
        app.sayOutcome(&job, result);
        app.refresh();
    }

    fn sayOutcome(app: *App, job: *const Job, result: i32) void {
        const who: [*:0]const u8 = @ptrCast(&job.who);
        const reason = app.words.get(whyDevice(result));
        switch (job.kind) {
            .connect => if (result == 0) app.say(.MSG_CONNECTED, .{who}) else app.say(.MSG_NOT_CONNECTED, .{ who, reason }),
            // A link the controller did not say had ended in time is taken
            // to be down all the same.
            .disconnect => if (result == 0 or result == bluetooth.BTERR_TIMEOUT)
                app.say(.MSG_DISCONNECTED, .{who})
            else
                app.say(.MSG_NOT_DISCONNECTED, .{ who, reason }),
            .forget => if (result == 0) app.say(.MSG_FORGOTTEN, .{who}) else app.say(.MSG_NOT_FORGOTTEN, .{ who, reason }),
        }
    }

    fn stopWorker(app: *App) void {
        const worker = app.worker orelse return;
        worker.free();
        app.worker = null;
    }

    // --- the pairings ------------------------------------------------------------

    /// The pairing with the device at `address` said under way.
    fn underWay(app: *App, address: *const bluetooth.BTAddress, who: *const Who) void {
        app.pairing = .{ .address = address.*, .who = who.* };
        app.pairing_left = pairing_ticks;
        app.held = 0;
        app.showLine();
        app.showButtons();
    }

    fn firstQuestion(app: *App) ?*bluetooth.BTAgentMessage {
        const node = app.questions.first() orelse return null;
        const message: *exec.Message = @fieldParentPtr("node", node);
        return @fieldParentPtr("message", message);
    }

    /// What came to the agent's port: a question kept for the pairing
    /// window, a number to be typed shown in it, a pairing's end said. A
    /// function of its own, so that its copies of names are stack only
    /// while it runs.
    noinline fn agentMessages(app: *App) void {
        const sys = app.sys;
        const port = app.agent_port orelse return;
        while (sys.GetMsg(port)) |message| {
            const asked: *bluetooth.BTAgentMessage = @fieldParentPtr("message", message);
            const who = whoOf(@ptrCast(&asked.name), &asked.address);
            switch (asked.kind) {
                bluetooth.BTAK_CONFIRM, bluetooth.BTAK_PASSKEY, bluetooth.BTAK_PIN => {
                    const first = app.questions.isEmpty();
                    sys.AddTail(&app.questions, &message.node);
                    app.underWay(&asked.address, &who);
                    if (first) app.openAsk();
                },
                bluetooth.BTAK_SHOW => {
                    app.number_shown = .{ .address = asked.address, .number = asked.number, .who = who };
                    app.underWay(&asked.address, &who);
                    sys.ReplyMsg(message);
                    if (app.questions.isEmpty()) app.openAsk();
                },
                bluetooth.BTAK_DONE => {
                    const address = asked.address;
                    const result = asked.result;
                    sys.ReplyMsg(message);
                    app.pairingOver(&address, result, &who);
                },
                else => sys.ReplyMsg(message),
            }
        }
    }

    /// A pairing's end: its questions answered no and its number no longer
    /// shown - the pairing window going on to what is asked next - and the
    /// end said.
    fn pairingOver(app: *App, address: *const bluetooth.BTAddress, result: i32, who: *const Who) void {
        const sys = app.sys;
        const head = app.questions.first();
        var ask_changed = false;
        var it = app.questions.iterator();
        while (it.next()) |node| {
            const message: *exec.Message = @fieldParentPtr("node", node);
            const asked: *bluetooth.BTAgentMessage = @fieldParentPtr("message", message);
            if (!sameAddress(&asked.address, address)) continue;
            if (head) |first| {
                if (node == first) ask_changed = true;
            }
            sys.Remove(node);
            asked.accept = 0;
            sys.ReplyMsg(message);
        }
        if (app.number_shown) |shown| {
            if (sameAddress(&shown.address, address)) {
                app.number_shown = null;
                if (head == null) ask_changed = true;
            }
        }
        if (ask_changed) app.openAsk();
        if (app.pairing) |pairing| {
            if (sameAddress(&pairing.address, address)) app.pairing = null;
        }
        const name: [*:0]const u8 = @ptrCast(who);
        if (result == 0) {
            app.say(.MSG_PAIRED, .{name});
        } else {
            app.say(.MSG_NOT_PAIRED, .{ name, app.words.get(whyDevice(result)) });
        }
        app.showButtons();
    }

    /// The pairing window's Yes or Pair, or Return in its field: the
    /// question agreed to, with the passkey or the PIN typed where it asks
    /// for one - nothing done while the field holds none.
    fn answerYes(app: *App) void {
        const asked = app.firstQuestion() orelse return;
        switch (asked.kind) {
            bluetooth.BTAK_PASSKEY => asked.passkey = pairing_text.passkeyOf(spanOf(app.textOf(app.ask_field))) orelse return,
            bluetooth.BTAK_PIN => {
                const typed = spanOf(app.textOf(app.ask_field));
                if (typed.len == 0 or typed.len > bluetooth.BT_PIN_MOST) return;
                @memcpy(asked.pin[0..typed.len], typed);
                asked.pin_length = @intCast(typed.len);
            },
            else => {},
        }
        asked.accept = 1;
        app.answered(asked);
    }

    /// The pairing window's No or Cancel, or its close gadget: the question
    /// refused - or the number to be typed no longer shown.
    fn answerNo(app: *App) void {
        const asked = app.firstQuestion() orelse {
            app.number_shown = null;
            return app.openAsk();
        };
        asked.accept = 0;
        app.answered(asked);
    }

    /// A question answered: replied, and the pairing window gone on to
    /// what is asked next.
    fn answered(app: *App, asked: *bluetooth.BTAgentMessage) void {
        app.sys.Remove(&asked.message.node);
        app.sys.ReplyMsg(&asked.message);
        app.openAsk();
    }

    /// The pairing window opened for what is asked first - a question, or
    /// else a number to be typed on a device - in place of the one open;
    /// none where nothing is asked. Its tag lists are stack only while it
    /// is made.
    noinline fn openAsk(app: *App) void {
        app.closeAsk();
        const ib = app.ib;
        const words = app.words;
        var kind: u32 = bluetooth.BTAK_SHOW;
        var number: u32 = bluetooth.BT_NO_NUMBER;
        var who: Who = undefined;
        if (app.firstQuestion()) |asked| {
            kind = asked.kind;
            number = asked.number;
            who = whoOf(@ptrCast(&asked.name), &asked.address);
        } else if (app.number_shown) |shown| {
            number = shown.number;
            who = shown.who;
        } else return;

        const name = pairing_text.nameMarkup(spanOf(@ptrCast(&who)), &app.ask_name);
        const text = &app.ask_text;
        const compare = kind == bluetooth.BTAK_CONFIRM and number != bluetooth.BT_NO_NUMBER;
        switch (kind) {
            bluetooth.BTAK_CONFIRM => _ = if (compare)
                words.format(text, .MSG_ASK_COMPARE, .{name})
            else
                words.format(text, .MSG_ASK_CONSENT, .{name}),
            bluetooth.BTAK_PASSKEY => _ = words.format(text, .MSG_ASK_PASSKEY, .{name}),
            bluetooth.BTAK_PIN => _ = words.format(text, .MSG_ASK_PIN, .{name}),
            else => _ = words.format(text, .MSG_ASK_SHOW, .{name}),
        }

        const question = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
            pair(tx.TEXT_Markup, 1),
            pair(tx.TEXT_Wrap, 1),
            pair(gc.GA_Width, fontWidth(app) * ask_columns),
            pair(tx.TEXT_Text, @intFromPtr(text)),
            .{},
        });
        const shows_number = number != bluetooth.BT_NO_NUMBER;
        const number_line: ?*Object = if (shows_number) ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
            pair(tx.TEXT_Markup, 1),
            pair(tx.TEXT_Justification, tx.TEXT_JUSTIFY_CENTER),
            pair(tx.TEXT_Text, @intFromPtr(pairing_text.numberMarkup(number, 2 * @as(u32, @intCast(fontHeight(app))), &app.ask_number))),
            .{},
        }) else null;
        // The passkey a number field - digits alone - emptied of the 0 it
        // is made with; the PIN any text.
        app.ask_field = switch (kind) {
            bluetooth.BTAK_PASSKEY => ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
                pair(gc.GA_ID, ID_ASK_FIELD),
                pair(gc.GA_RelVerify, 1),
                pair(gc.STRINGA_MaxChars, pairing_text.passkey_digits + 1),
                pair(gc.STRINGA_LongVal, 0),
                .{},
            }),
            bluetooth.BTAK_PIN => ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
                pair(gc.GA_ID, ID_ASK_FIELD),
                pair(gc.GA_RelVerify, 1),
                pair(gc.STRINGA_MaxChars, bluetooth.BT_PIN_MOST + 1),
                .{},
            }),
            else => null,
        };
        if (kind == bluetooth.BTAK_PASSKEY) app.setIn(null, app.ask_field, &.{ pair(gc.STRINGA_TextVal, @intFromPtr("")), .{} });
        const typing = kind == bluetooth.BTAK_PASSKEY or kind == bluetooth.BTAK_PIN;
        // A number to be typed on the device asks nothing here: the window
        // only shows it, until the pairing is over or it is closed.
        const answers = kind != bluetooth.BTAK_SHOW;
        const yes = if (answers) button(ib, words.get(if (compare) .MSG_YES else .MSG_PAIR), ID_ASK_YES, true) else null;
        const no = if (answers) button(ib, words.get(if (compare) .MSG_NO else .MSG_CANCEL), ID_ASK_NO, true) else null;
        const buttons: ?*Object = if (yes != null and no != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
            pair(lg.LAYOUTA_Spacing, 8),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(yes)),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(no)),
            .{},
        }) else null;
        const complete = question != null and (number_line != null) == shows_number and
            (app.ask_field != null) == typing and (buttons != null) == answers;
        const fields: ?*Object = if (complete) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
            pair(lg.LAYOUTA_Margin, 8),
            pair(lg.LAYOUTA_Spacing, 8),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(question)),
            pair(lg.CHILDA_WeightHeight, 0),
            when(shows_number, lg.LAYOUTA_AddChild, @intFromPtr(number_line)),
            when(shows_number, lg.CHILDA_WeightHeight, 0),
            when(typing, lg.LAYOUTA_AddChild, @intFromPtr(app.ask_field)),
            when(typing, lg.CHILDA_WeightHeight, 0),
            when(answers, lg.LAYOUTA_AddChild, @intFromPtr(buttons)),
            when(answers, lg.CHILDA_WeightHeight, 0),
            .{},
        }) else null;
        const layout = fields orelse {
            // What was made goes again: the buttons with their row where
            // it was made, on their own where it was not.
            ib.DisposeObject(question);
            ib.DisposeObject(number_line);
            ib.DisposeObject(app.ask_field);
            if (buttons != null) {
                ib.DisposeObject(buttons);
            } else {
                ib.DisposeObject(yes);
                ib.DisposeObject(no);
            }
            app.ask_field = null;
            return;
        };
        app.ask_object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            pair(wn.WA_Title, @intFromPtr(words.get(.MSG_PAIRING_TITLE))),
            pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
            pair(wn.WA_CloseGadget, 1),
            pair(wn.WA_DragBar, 1),
            pair(wn.WA_DepthGadget, 1),
            pair(wn.WA_Activate, 1),
            pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
            .{},
        }) orelse {
            ib.DisposeObject(layout);
            app.ask_field = null;
            return;
        };
        var open = wc.WmOpen{};
        if (ib.SendMessage(app.ask_object.?, @ptrCast(&open)) == 0) {
            ib.DisposeObject(app.ask_object);
            app.ask_object = null;
            app.ask_field = null;
            return;
        }
        var at: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_Window, app.ask_object.?, &at);
        app.ask_window = @ptrFromInt(at);
        if (app.ask_field) |field| {
            if (app.ask_window) |window| _ = ib.ActivateGadget(field, window, null);
        }
    }

    /// The pairing window closed, a PIN typed into it emptied first.
    fn closeAsk(app: *App) void {
        const object = app.ask_object orelse return;
        if (app.ask_field != null) app.setIn(app.ask_window, app.ask_field, &.{ pair(gc.STRINGA_TextVal, @intFromPtr("")), .{} });
        app.ib.DisposeObject(object);
        app.ask_object = null;
        app.ask_window = null;
        app.ask_field = null;
    }

    /// The agent given back: the questions it holds and what is still on
    /// its port answered no, the port gone.
    fn removeAgent(app: *App) void {
        const sys = app.sys;
        if (app.agent) |agent| app.bt.RemBTAgent(agent);
        app.agent = null;
        while (sys.RemHead(&app.questions)) |node| {
            const message: *exec.Message = @fieldParentPtr("node", node);
            const asked: *bluetooth.BTAgentMessage = @fieldParentPtr("message", message);
            asked.accept = 0;
            sys.ReplyMsg(message);
        }
        const port = app.agent_port orelse return;
        while (sys.GetMsg(port)) |message| sys.ReplyMsg(message);
        sys.DeleteMsgPort(port);
        app.agent_port = null;
    }

    // --- the tick -----------------------------------------------------------------

    fn timerMask(app: *const App) u32 {
        const port = app.timer_port orelse return 0;
        return port.sigMask();
    }

    fn notifyMask(app: *const App) u32 {
        if (app.notify == null) return 0;
        return @as(u32, 1) << @intCast(app.notify_bit);
    }

    fn agentMask(app: *const App) u32 {
        const port = app.agent_port orelse return 0;
        return port.sigMask();
    }

    fn workerMask(app: *const App) u32 {
        const worker = app.worker orelse return 0;
        return worker.signal();
    }

    fn startTimer(app: *App) void {
        if (!app.timer_open or app.timer_out) return;
        app.timer_req.node.command = timer.TR_ADDREQUEST;
        app.timer_req.time = timer.TimeVal.fromMicros(tick_us);
        app.sys.SendIO(&app.timer_req.node);
        app.timer_out = true;
    }

    /// A tick, once its signal came: what the library signalled since the
    /// last read, a message's time, a time to be visible counted down.
    fn ticked(app: *App) void {
        if (!app.timer_out or app.sys.CheckIO(&app.timer_req.node) == null) return;
        _ = app.sys.WaitIO(&app.timer_req.node);
        app.timer_out = false;
        app.startTimer();
        app.ticks += 1;
        app.read_this_tick = false;
        if (app.held > 0) {
            app.held -= 1;
            if (app.held == 0) app.showLine();
        }
        if (app.pairing != null) {
            app.pairing_left -|= 1;
            if (app.pairing_left == 0) {
                app.pairing = null;
                app.showLine();
                app.showButtons();
            }
        }
        if (app.dirty) return app.refresh();
        const picked = app.controller() orelse return;
        if (picked.countingDown() and app.ticks % countdown_ticks == 0) {
            app.readControllers();
            app.showLine();
            app.showSettings();
        }
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

/// Whether two lists of rows show the same: as many rows, each with the
/// same texts and marks.
fn sameRows(one: *exec.List, other: *exec.List) bool {
    var mine = one.iterator();
    var theirs = other.iterator();
    while (true) {
        const a = mine.next();
        const b = theirs.next();
        if (a == null or b == null) return a == null and b == null;
        const row_a: *lb.Row = @fieldParentPtr("node", a.?);
        const row_b: *lb.Row = @fieldParentPtr("node", b.?);
        if (row_a.flags != row_b.flags or row_a.user_data != row_b.user_data) return false;
        for (0..column_count) |column| {
            if (!same(spanOf(row_a.cells[column].?), spanOf(row_b.cells[column].?))) return false;
        }
    }
}

fn button(ib: *IntuitionBase, label: [*:0]const u8, id: usize, usable: bool) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_Text, @intFromPtr(label)),
        pair(gc.GA_ID, id),
        pair(gc.GA_RelVerify, 1),
        pair(gc.GA_Disabled, @intFromBool(!usable)),
        .{},
    });
}

fn checkbox(ib: *IntuitionBase, id: usize) ?*Object {
    return ib.NewObjectTagList(null, cb_class.CHECKBOX_CLASS, &[_]TagItem{
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
    const words = app.words;
    app.chooser = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_CONTROLLER),
        pair(gc.GA_RelVerify, 1),
        pair(ch.CHOOSER_Labels, @intFromPtr(&app.labels)),
        pair(ch.CHOOSER_Active, app.current),
        pair(gc.GA_Disabled, @intFromBool(app.controller_count < 2)),
        .{},
    });
    app.status_gadget = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_RoomFor, @intFromPtr(status_room)),
        pair(tx.TEXT_Clipped, 1),
        pair(tx.TEXT_Text, @intFromPtr(app.shown_status.ptr())),
        .{},
    });
    app.on_box = checkbox(ib, ID_ON);
    app.visible_box = checkbox(ib, ID_VISIBLE);
    app.name_field = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_NAME),
        pair(gc.GA_RelVerify, 1),
        pair(gc.GA_TabCycle, 1),
        pair(gc.STRINGA_MaxChars, name_most),
        pair(gc.STRINGA_TextVal, @intFromPtr(&app.shown_name)),
        .{},
    });
    app.list = ib.NewObjectTagList(null, lb.LISTBROWSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_DEVICES),
        pair(gc.GA_RelVerify, 1),
        pair(lb.LISTBROWSER_Columns, @intFromPtr(&app.columns)),
        pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.rows)),
        .{},
    });
    // Dimmed until the window has read what they may do.
    app.pair_button = button(ib, words.get(.MSG_PAIR), ID_PAIR, false);
    app.connect_button = button(ib, words.get(.MSG_CONNECT), ID_CONNECT, false);
    app.disconnect_button = button(ib, words.get(.MSG_DISCONNECT), ID_DISCONNECT, false);
    app.forget_button = button(ib, words.get(.MSG_FORGET), ID_FORGET, false);
    app.search_button = button(ib, words.get(.MSG_SEARCH), ID_SEARCH, false);

    const row_height = fontHeight(app);
    const settings = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 12),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.on_box orelse return null)),
        pair(lg.CHILDA_Label, @intFromPtr(words.get(.MSG_ON))),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.name_field orelse return null)),
        pair(lg.CHILDA_Label, @intFromPtr(words.get(.MSG_NAME))),
        pair(lg.CHILDA_MinWidth, fontWidth(app) * name_columns + 12),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.visible_box orelse return null)),
        pair(lg.CHILDA_Label, @intFromPtr(words.get(.MSG_VISIBLE))),
        pair(lg.CHILDA_WeightWidth, 0),
        .{},
    }) orelse return null;
    const actions = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.pair_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.connect_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.disconnect_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.forget_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.search_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        .{},
    }) orelse return null;
    const devices_group = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_FrameTitle, @intFromPtr(words.get(.MSG_DEVICES))),
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
        pair(lg.CHILDA_Label, @intFromPtr(words.get(.MSG_CONTROLLER))),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.status_gadget orelse return null)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(settings)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(devices_group)),
        .{},
    });
}

/// How wide a character of the screen's font is, which the list and the
/// name field are measured in.
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
    var words = Text.open(sys);
    defer words.close();

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    var libraries: [8]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_]struct { name: [*:0]const u8, version: u32 }{
        .{ .name = intuition.INTUITIONNAME, .version = 0 },   .{ .name = graphics.GRAPHICSNAME, .version = 0 },
        .{ .name = bluetooth.BLUETOOTHNAME, .version = 1 },   .{ .name = lb.LISTBROWSER_LIBRARY, .version = 0 },
        .{ .name = st.STRING_LIBRARY, .version = 0 },         .{ .name = tx.TEXT_LIBRARY, .version = 0 },
        .{ .name = cb_class.CHECKBOX_LIBRARY, .version = 0 }, .{ .name = ch.CHOOSER_LIBRARY, .version = 0 },
    };
    for (wanted, 0..) |library, index| {
        libraries[index] = sys.OpenLibrary(library.name, library.version) orelse {
            _ = words.printf(dl, .MSG_NO_LIBRARY, .{ @as([*:0]const u8, COMMAND_NAME), library.name });
            return dos.RETURN_FAIL;
        };
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);

    const memory = sys.AllocVec(@sizeOf(App), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = words.printf(dl, .MSG_NO_MEMORY, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const app: *App = @ptrCast(@alignCast(memory));
    app.* = .{
        .sys = sys,
        .dl = dl,
        .ib = ib,
        .gb = @ptrCast(libraries[1].?),
        .bt = @ptrCast(libraries[2].?),
        .words = &words,
    };
    app.rows.init(.unknown);
    defer lb.freeRows(sys, &app.rows);
    for (column_titles, column_weights, 0..) |title, weight, index| {
        app.columns[index] = .{ .title = words.get(title), .weight = weight };
    }
    if (rdargs.number(argv[arg_controller])) |asked| app.wanted = @bitCast(asked);

    // Told whenever something changes.
    app.notify_bit = sys.AllocSignal(-1);
    if (app.notify_bit >= 0) {
        app.notify = app.bt.AddBTNotify(sys.FindTask(null).?, @as(u32, 1) << @intCast(app.notify_bit));
    }
    defer {
        app.bt.RemBTNotify(app.notify);
        if (app.notify_bit >= 0) sys.FreeSignal(app.notify_bit);
    }

    // The worker ends after the window - waiting for the call it is in -
    // and the agent before it: their defers run in the other order.
    defer app.stopWorker();
    app.questions.init(.message);
    app.agent_port = sys.CreateMsgPort();
    if (app.agent_port) |port| app.agent = app.bt.AddBTAgent(port, bluetooth.BTIO_KEYBOARDDISPLAY);
    defer app.removeAgent();

    app.timer_port = sys.CreateMsgPort();
    if (app.timer_port) |port| {
        app.timer_req.node.message.reply_port = port;
        app.timer_req.node.message.length = @sizeOf(timer.TimeRequest);
        app.timer_open = sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &app.timer_req.node, 0) == 0;
    }
    defer app.stopTimer();

    app.readControllers();
    if (app.controller_count == 0) app.labels[0] = words.get(.MSG_NO_CONTROLLER_LABEL);
    const layout = buildLayout(app) orelse {
        _ = words.printf(dl, .MSG_NO_MEMORY, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    };
    app.object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr(words.get(.MSG_WINDOW_TITLE))),
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
        _ = words.printf(dl, .MSG_NO_MEMORY, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    };
    defer {
        app.closeAsk();
        ib.DisposeObject(app.object);
    }
    var open = wc.WmOpen{};
    if (ib.SendMessage(app.object.?, @ptrCast(&open)) == 0) {
        _ = words.printf(dl, .MSG_NO_WINDOW, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    }
    var at: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, app.object.?, &at);
    app.window = @ptrFromInt(at);

    app.refresh();
    app.startTimer();

    var code_word: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code_word };
    while (true) {
        var mask: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_SigMask, app.object.?, &mask);
        var ask_mask: usize = 0;
        if (app.ask_object) |object| _ = ib.GetAttr(wc.WINDOWA_SigMask, object, &ask_mask);
        const others = app.notifyMask() | app.timerMask() | app.agentMask() | app.workerMask();
        const got = sys.Wait(@as(u32, @intCast(mask | ask_mask)) | others | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_OK;
        if (got & app.agentMask() != 0) app.agentMessages();
        if (got & app.workerMask() != 0) app.workerDone();
        if (got & app.notifyMask() != 0) app.changed();
        if (got & app.timerMask() != 0) app.ticked();

        // The pairing window, while it is up.
        if (app.ask_object) |object| {
            while (true) {
                const word = ib.SendMessage(object, @ptrCast(&handle));
                if (word == wc.WMHI_LASTMSG) break;
                switch (word & wc.WMHI_CLASSMASK) {
                    wc.WMHI_CLOSEWINDOW => app.answerNo(),
                    wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                        ID_ASK_YES => app.answerYes(),
                        ID_ASK_FIELD => if (entered(code_word)) app.answerYes(),
                        ID_ASK_NO => app.answerNo(),
                        else => {},
                    },
                    else => {},
                }
                // Answered, it has gone - or been made again for the next.
                if (app.ask_object != object) break;
            }
        }

        while (true) {
            const word = ib.SendMessage(app.object.?, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_CONTROLLER => app.pickController(code_word),
                    ID_ON => app.setOn(),
                    ID_NAME => app.setName(),
                    ID_VISIBLE => app.setVisible(),
                    ID_DEVICES => {
                        app.pickRow();
                        if (code_word & lb.LISTBROWSER_DOUBLE != 0) app.defaultAction();
                    },
                    ID_PAIR => app.pairPicked(),
                    ID_CONNECT => app.askWorker(.connect),
                    ID_DISCONNECT => app.askWorker(.disconnect),
                    ID_FORGET => app.forgetPicked(),
                    ID_SEARCH => app.search(),
                    else => {},
                },
                else => {},
            }
        }
    }
}
