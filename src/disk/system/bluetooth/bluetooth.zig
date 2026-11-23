// SPDX-License-Identifier: MIT
//! Bluetooth: the system's Bluetooth controllers set, and the devices
//! around found, in a window. Built against the SDK only.
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
//! found, why a change did not work - stands there for a few seconds.
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
const VERSION = "1.0";
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

/// The tick: the list made again at most once a tick, a message held for
/// `message_ticks`, a time to be visible counted down every
/// `countdown_ticks`.
const tick_us: u64 = 500_000;
const message_ticks: u32 = 10;
const countdown_ticks: u32 = 2;
/// How long a search looks.
const search_seconds: u32 = 10;

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
    shown_usable: bool = true,
    /// Whether the controller was searching when last read, so that the
    /// search's end is said.
    was_searching: bool = false,

    /// The library's signal: something changed. Read again at once, or -
    /// read once this tick already - at the next.
    notify: ?*bluetooth.BTNotify = null,
    notify_bit: i8 = -1,
    read_this_tick: bool = false,
    dirty: bool = false,

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
        if (app.was_searching and !now) app.say(.MSG_FOUND, .{@as(u32, @intCast(app.foundCount()))});
        app.was_searching = now;
        app.showLine();
        app.showSettings();
        app.showList();
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

    /// The boxes, the name field and Search set from the controller, each
    /// only where it shows something else.
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
        app.set(app.visible_box, &.{
            pair(cb_class.CHECKBOX_Checked, @intFromBool(visible)),
            pair(gc.GA_Disabled, @intFromBool(!powered)),
            .{},
        });
        app.shown_visible = visible;
        const name: []const u8 = if (picked) |one| spanOf(@ptrCast(&one.name)) else "";
        if (!same(name, spanOf(@ptrCast(&app.shown_name)))) {
            @memcpy(app.shown_name[0..name.len], name);
            app.shown_name[name.len] = 0;
            app.set(app.name_field, &.{ pair(gc.STRINGA_TextVal, @intFromPtr(&app.shown_name)), .{} });
        }
        app.enable(app.search_button, powered and !picked.?.searching());
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

    fn setOn(app: *App) void {
        app.setAttrs(&.{ pair(bluetooth.BTCA_Powered, @intFromBool(app.checked(app.on_box))), .{} });
    }

    fn setVisible(app: *App) void {
        const visible = app.checked(app.visible_box);
        app.setAttrs(&.{ pair(bluetooth.BTCA_Visible, if (visible) bluetooth.BT_VISIBLE_ALWAYS else 0), .{} });
    }

    /// The name typed, where it is another; emptied, the machine's.
    fn setName(app: *App) void {
        const picked = app.controller() orelse return;
        const typed = app.textOf(app.name_field);
        if (same(spanOf(typed), spanOf(@ptrCast(&picked.name)))) return;
        app.setAttrs(&.{ pair(bluetooth.BTCA_Name, @intFromPtr(typed)), .{} });
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
        if (at == 0) return;
        const row: *lb.Row = @ptrFromInt(at);
        if (row.user_data >= app.table.count) return;
        app.picked = app.table.devices[row.user_data].address;
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

fn button(ib: *IntuitionBase, label: [*:0]const u8, id: usize) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_Text, @intFromPtr(label)),
        pair(gc.GA_ID, id),
        pair(gc.GA_RelVerify, 1),
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
    app.search_button = button(ib, words.get(.MSG_SEARCH), ID_SEARCH);

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
    defer ib.DisposeObject(app.object);
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
        const got = sys.Wait(@as(u32, @intCast(mask)) | app.notifyMask() | app.timerMask() | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_OK;
        if (got & app.notifyMask() != 0) app.changed();
        if (got & app.timerMask() != 0) app.ticked();

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
                    ID_DEVICES => app.pickRow(),
                    ID_SEARCH => app.search(),
                    else => {},
                },
                else => {},
            }
        }
    }
}
