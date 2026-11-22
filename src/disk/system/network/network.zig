// SPDX-License-Identifier: MIT
//! Network: an interface's addresses, set in a window - DHCP or a fixed
//! address, the name servers, IPv6 - written to its file in
//! DEVS:NetInterfaces/ and, once asked, put to use at once. Built against
//! the SDK only.
//!
//!   Network INTERFACE/K
//!
//! INTERFACE is the interface to start on, by its file's name (`ETH0`) or
//! the interface's (`eth0`); without it, the first file there is.
//!
//! **The interfaces** are the files in DEVS:NetInterfaces/, each one an
//! interface the boot brings up - its name the file's in lower case. The
//! line under the chooser says whether it is up now and with which
//! address, asked again every two seconds.
//!
//! **The settings** are the file's (settings.zig): Configure as DHCP or a
//! fixed address with its net mask and gateway, the name servers and the
//! domain, and IPv6 - automatic, a fixed address, or off. A field that
//! does not apply is dimmed and keeps what the file says. The net mask
//! takes a prefix length too (`24`, `/24`), and is written as an address.
//!
//! **Save** sees that every address is one, writes the file - only what
//! the window changed; comments and every other keyword stay - and, when
//! the interface is up, asks whether to start it again with them now,
//! which ends every connection it carries: C:net/RemNetInterface takes it
//! down, C:net/AddNetInterface brings it up from the file, and what either
//! says when it fails is shown. **Revert** reads the file again.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const graphics = sdk.graphics;
const bsd = sdk.bsdsocket;
const timer = sdk.devices.timer;
const netinterface = @import("netinterface");
const settings_file = @import("settings.zig");
const Settings = settings_file.Settings;
const untilNul = settings_file.untilNul;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
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
const st = sdk.gadgets.string;
const tx = sdk.gadgets.text;
const ch = sdk.gadgets.chooser;

pub const COMMAND_NAME = "Network";
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

const ID_INTERFACE = 1;
const ID_CONFIGURE = 2;
const ID_ADDRESS = 3;
const ID_NETMASK = 4;
const ID_GATEWAY = 5;
const ID_SERVERS = 6;
const ID_DOMAIN = 7;
const ID_IPV6 = 8;
const ID_ADDRESS6 = 9;
const ID_PREFIX6 = 10;
const ID_GATEWAY6 = 11;
const ID_SAVE = 12;
const ID_REVERT = 13;

/// The most interface files looked at.
const max_interfaces = 8;

/// The status line made again every tick; a message stays this many
/// ticks before it says where the interface stands again.
const tick_us: u64 = 2_000_000;
const message_ticks: u32 = 3;

/// The room the status line keeps, whatever it says, and how many
/// characters wide the name servers' field is at the least.
const status_room = "x" ** 80;
const servers_columns: usize = 48;

const configure_labels = [_:null]?[*:0]const u8{ "DHCP", "Fixed address" };
const ipv6_labels = [_:null]?[*:0]const u8{ "Automatic", "Fixed address", "Off" };

fn pair(tag: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = tag, .data = data };
}

/// A line put together piece by piece, which a gadget keeps pointing at.
const Line = struct {
    text: [160:0]u8 = @splat(0),
    length: usize = 0,

    fn clear(line: *Line) void {
        @memset(&line.text, 0);
        line.length = 0;
    }

    fn ptr(line: *const Line) [*:0]const u8 {
        return @ptrCast(&line.text);
    }

    fn slice(line: *const Line) []const u8 {
        return line.text[0..line.length];
    }

    fn put(line: *Line, bytes: []const u8) void {
        for (bytes) |char| putChar(char, line);
    }

    fn add(line: *Line, sys: *ExecBase, comptime format: [:0]const u8, args: anytype) void {
        comptime exec.checkFormat(format, @TypeOf(args));
        const stream = exec.fmtStream(args);
        _ = sys.RawDoFmt(format, &stream, &putChar, line);
    }

    fn say(line: *Line, sys: *ExecBase, comptime format: [:0]const u8, args: anytype) void {
        line.clear();
        line.add(sys, format, args);
    }

    fn putChar(char: u8, data: ?*anyopaque) callconv(.c) void {
        const line: *Line = @ptrCast(@alignCast(data.?));
        if (char == 0 or line.length >= line.text.len) return;
        line.text[line.length] = char;
        line.length += 1;
    }
};

fn same(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |a, b| if (a != b) return false;
    return true;
}

fn spanOf(string: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (string[length] != 0) length += 1;
    return string[0..length];
}

fn put(into: []u8, text: []const u8) void {
    const count = @min(text.len, into.len - 1);
    @memcpy(into[0..count], text[0..count]);
    into[count] = 0;
}

/// One interface file: its name as it is on the disk, the interface's,
/// and what the chooser says for it.
const Interface = struct {
    file: [32:0]u8 = @splat(0),
    name: [32:0]u8 = @splat(0),
    label: Line = .{},
};

/// The interface file and the two buffers it is changed in, and what
/// starting the interface again takes: kept apart from the stack, which on
/// a 32-bit machine has no room for them.
const Files = struct {
    bytes: [netinterface.file_max]u8,
    first: [netinterface.file_max]u8,
    second: [netinterface.file_max]u8,
    work: netinterface.Work,
};

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    sb: *SocketBase,
    files: *Files,

    object: ?*Object = null,
    window: ?*intuition.Window = null,

    interfaces: [max_interfaces]Interface = @splat(.{}),
    interface_count: usize = 0,
    current: usize = 0,
    labels: [max_interfaces + 1:null]?[*:0]const u8 = @splat(null),

    /// Whether the file could be read.
    loaded: bool = false,
    /// What the window shows, and what it asks for.
    settings: Settings = .{},
    configure: usize = 0,
    ipv6: usize = 0,
    /// What the window says, read and checked for Save (`gather`).
    gathered: Settings = .{},
    /// A line put together and used at once: a net mask written out, a
    /// name server's text to check.
    scratch: Line = .{},

    status: Line = .{},
    shown_status: Line = .{},
    held: u32 = 0,

    chooser: ?*Object = null,
    status_gadget: ?*Object = null,
    configure_chooser: ?*Object = null,
    address_field: ?*Object = null,
    netmask_field: ?*Object = null,
    gateway_field: ?*Object = null,
    servers_field: ?*Object = null,
    domain_field: ?*Object = null,
    ipv6_chooser: ?*Object = null,
    address6_field: ?*Object = null,
    prefix6_field: ?*Object = null,
    gateway6_field: ?*Object = null,
    save_button: ?*Object = null,
    revert_button: ?*Object = null,

    timer_req: timer.TimeRequest = .{},
    timer_port: ?*exec.MsgPort = null,
    timer_open: bool = false,
    timer_out: bool = false,

    // --- the gadgets ----------------------------------------------------------

    fn set(app: *App, object: ?*Object, tags: []const TagItem) void {
        _ = app.ib.SetGadgetAttrsTagList(object orelse return, app.window, tags.ptr);
    }

    fn enable(app: *App, object: ?*Object, on: bool) void {
        app.set(object, &.{ pair(gc.GA_Disabled, @intFromBool(!on)), .{} });
    }

    fn setText(app: *App, object: ?*Object, text: [*:0]const u8) void {
        app.set(object, &.{ pair(gc.STRINGA_TextVal, @intFromPtr(text)), .{} });
    }

    /// What a string gadget holds now, into `into`.
    fn readText(app: *App, object: ?*Object, into: []u8) void {
        var at: usize = 0;
        _ = app.ib.GetAttr(gc.STRINGA_TextVal, object orelse return put(into, ""), &at);
        if (at == 0) return put(into, "");
        put(into, trimmed(spanOf(@ptrFromInt(at))));
    }

    /// A message on the status line, which stays `message_ticks` before
    /// the line says where the interface stands again.
    fn say(app: *App, comptime format: [:0]const u8, args: anytype) void {
        app.status.say(app.sys, format, args);
        app.held = message_ticks;
        app.showStatus();
    }

    fn showStatus(app: *App) void {
        if (same(app.status.slice(), app.shown_status.slice())) return;
        app.shown_status = app.status;
        app.set(app.status_gadget, &.{ pair(tx.TEXT_Text, @intFromPtr(app.shown_status.ptr())), .{} });
    }

    fn interface(app: *App) ?*Interface {
        if (app.current >= app.interface_count) return null;
        return &app.interfaces[app.current];
    }

    // --- the interfaces -------------------------------------------------------

    /// The files in DEVS:NetInterfaces/, in the order of their names, each
    /// read for the device it names.
    fn findInterfaces(app: *App) void {
        const dl = app.dl;
        const lock = dl.Lock("DEVS:NetInterfaces", dos.ACCESS_READ) orelse return;
        defer dl.UnLock(lock);
        const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_FIB, null) orelse return));
        defer dl.FreeDosObject(dos.DOS_FIB, fib);
        if (!dl.Examine(lock, fib)) return;
        while (dl.ExNext(lock, fib) and app.interface_count < max_interfaces) {
            if (dos.isDirectory(fib.dir_entry_type)) continue;
            const found = untilNul(&fib.file_name);
            if (found.len == 0 or found.len > 31) continue;
            const dot = for (found) |char| {
                if (char == '.') break true;
            } else false;
            if (dot) continue;
            var one: Interface = .{};
            put(&one.file, found);
            for (found, 0..) |char, at| one.name[at] = netinterface.lower(char);
            // In the order of their names, so that the chooser is the same
            // at every start.
            var place = app.interface_count;
            while (place > 0 and before(found, untilNul(&app.interfaces[place - 1].file))) : (place -= 1) {
                app.interfaces[place] = app.interfaces[place - 1];
            }
            app.interfaces[place] = one;
            app.interface_count += 1;
        }
        for (app.interfaces[0..app.interface_count], 0..) |*one, index| {
            one.label.put(untilNul(&one.file));
            var path: netinterface.Path = undefined;
            if (netinterface.readFile(dl, netinterface.pathOf(untilNul(&one.name), &path), &app.files.bytes)) |bytes| {
                const device = netinterface.valueOf(bytes, "Device") orelse "";
                const unit = netinterface.valueOf(bytes, "Unit") orelse "";
                if (device.len != 0) {
                    one.label.put(" - ");
                    one.label.put(device);
                    one.label.put(" unit ");
                    one.label.put(if (unit.len != 0) unit else "0");
                }
            }
            app.labels[index] = one.label.ptr();
        }
    }

    /// The interface `index` read from its file into the window.
    fn load(app: *App, index: usize) void {
        app.current = index;
        app.loaded = false;
        app.settings = .{};
        const picked = app.interface() orelse return app.showSettings();
        var path: netinterface.Path = undefined;
        const at = netinterface.pathOf(untilNul(&picked.name), &path);
        const bytes = netinterface.readFile(app.dl, at, &app.files.bytes) orelse {
            app.showSettings();
            app.say("%s cannot be read, or is too long to change here", .{at});
            return;
        };
        app.loaded = true;
        settings_file.read(bytes, &app.settings);
        app.showSettings();
        app.held = 0;
        app.refresh();
    }

    /// The settings into the gadgets.
    fn showSettings(app: *App) void {
        const settings = &app.settings;
        app.configure = if (settings.dhcp) 0 else 1;
        app.ipv6 = @intFromEnum(settings.ipv6);
        app.set(app.configure_chooser, &.{ pair(ch.CHOOSER_Active, app.configure), .{} });
        app.set(app.ipv6_chooser, &.{ pair(ch.CHOOSER_Active, app.ipv6), .{} });
        app.setText(app.address_field, @ptrCast(&settings.address));
        app.setText(app.netmask_field, @ptrCast(&settings.netmask));
        app.setText(app.gateway_field, @ptrCast(&settings.gateway));
        app.setText(app.servers_field, @ptrCast(&settings.nameservers));
        app.setText(app.domain_field, @ptrCast(&settings.domain));
        app.setText(app.address6_field, @ptrCast(&settings.address6));
        app.setText(app.prefix6_field, @ptrCast(&settings.prefix6));
        app.setText(app.gateway6_field, @ptrCast(&settings.gateway6));
        app.showEnabled();
    }

    /// The fields that apply: the IPv4 address for a fixed one, the IPv6
    /// one likewise, nothing without a file.
    fn showEnabled(app: *App) void {
        const loaded = app.loaded;
        const fixed4 = loaded and app.configure == 1;
        const fixed6 = loaded and app.ipv6 == @intFromEnum(settings_file.Ipv6.fixed);
        app.enable(app.configure_chooser, loaded);
        app.enable(app.address_field, fixed4);
        app.enable(app.netmask_field, fixed4);
        app.enable(app.gateway_field, fixed4);
        app.enable(app.servers_field, loaded);
        app.enable(app.domain_field, loaded);
        app.enable(app.ipv6_chooser, loaded);
        app.enable(app.address6_field, fixed6);
        app.enable(app.prefix6_field, fixed6);
        app.enable(app.gateway6_field, fixed6);
        app.enable(app.save_button, loaded);
        app.enable(app.revert_button, loaded);
    }

    /// Where the interface stands now, on the status line - unless a
    /// message is still on it.
    fn refresh(app: *App) void {
        if (app.held != 0) return;
        const picked = app.interface() orelse {
            app.status.say(app.sys, "There is no file in DEVS:NetInterfaces/", .{});
            return app.showStatus();
        };
        const name: [*:0]const u8 = @ptrCast(&picked.name);
        var address: u32 = 0;
        var netmask: u32 = 0;
        var state: u32 = 0;
        const tags = [_]TagItem{
            pair(bsd.IFQ_Address, @intFromPtr(&address)),
            pair(bsd.IFQ_NetMask, @intFromPtr(&netmask)),
            pair(bsd.IFQ_State, @intFromPtr(&state)),
            .{},
        };
        const line = &app.status;
        line.clear();
        if (app.sb.QueryInterfaceTagList(name, &tags) != 0 or state & bsd.IFSTATE_UP == 0) {
            line.add(app.sys, "%s is not up", .{name});
        } else if (address == 0) {
            line.add(app.sys, "%s is up, without an IPv4 address yet", .{name});
            if (state & bsd.IFSTATE_DHCP != 0) line.put(" - DHCP has not answered");
        } else {
            const octets: [4]u8 = @bitCast(address);
            line.add(app.sys, "%s is up: %u.%u.%u.%u/%u", .{
                name,
                @as(u32, octets[0]),
                @as(u32, octets[1]),
                @as(u32, octets[2]),
                @as(u32, octets[3]),
                @as(u32, @popCount(netmask)),
            });
            if (state & bsd.IFSTATE_LINKLOCAL != 0) {
                line.put(", its own - DHCP has not answered");
            } else if (state & bsd.IFSTATE_DHCP != 0) {
                line.put(", from DHCP");
            } else {
                line.put(", fixed");
            }
        }
        app.showStatus();
    }

    fn up(app: *App) bool {
        const picked = app.interface() orelse return false;
        var state: u32 = 0;
        const tags = [_]TagItem{ pair(bsd.IFQ_State, @intFromPtr(&state)), .{} };
        return app.sb.QueryInterfaceTagList(@ptrCast(&picked.name), &tags) == 0 and state & bsd.IFSTATE_UP != 0;
    }

    // --- saving ---------------------------------------------------------------

    /// What the window says, read into `gathered`: false, said, when an
    /// address is none.
    fn gather(app: *App) bool {
        const settings = &app.gathered;
        settings.* = app.settings;
        settings.dhcp = app.configure == 0;
        settings.ipv6 = @enumFromInt(app.ipv6);
        app.readText(app.address_field, &settings.address);
        app.readText(app.netmask_field, &settings.netmask);
        app.readText(app.gateway_field, &settings.gateway);
        app.readText(app.servers_field, &settings.nameservers);
        app.readText(app.domain_field, &settings.domain);
        app.readText(app.address6_field, &settings.address6);
        app.readText(app.prefix6_field, &settings.prefix6);
        app.readText(app.gateway6_field, &settings.gateway6);
        if (!settings.dhcp) {
            if (settings.address[0] == 0) return app.refuse("A fixed address needs its address");
            if (!app.isAddress(bsd.AF_INET, &settings.address)) return app.refuse("The address is no IPv4 address");
            if (!app.netmaskOf(&settings.netmask)) return app.refuse("The net mask is no mask: 255.255.255.0, or 24");
            if (settings.gateway[0] != 0 and !app.isAddress(bsd.AF_INET, &settings.gateway)) return app.refuse("The gateway is no IPv4 address");
        }
        var words: [2 * settings_file.servers_max + 1][]const u8 = undefined;
        const count = settings_file.serversOf(untilNul(&settings.nameservers), &words);
        var four: u32 = 0;
        var six: u32 = 0;
        for (words[0..@min(count, words.len)]) |word| {
            if (word.len > settings_file.server_max) return app.refuse("A name server is no address");
            const text = &app.scratch;
            text.clear();
            text.put(word);
            if (app.isAddress(bsd.AF_INET, text.ptr())) {
                four += 1;
            } else if (app.isAddress(bsd.AF_INET6, text.ptr())) {
                six += 1;
            } else return app.refuse("A name server is no address");
        }
        if (four > settings_file.servers_max or six > settings_file.servers_max) return app.refuse("Four name servers of each kind at the most");
        if (settings.domain[0] != 0 and !netinterface.writable(untilNul(&settings.domain))) return app.refuse("The domain cannot hold a quote");
        if (settings.ipv6 == .fixed) {
            if (settings.address6[0] == 0) return app.refuse("A fixed IPv6 address needs its address");
            if (!app.isAddress(bsd.AF_INET6, &settings.address6)) return app.refuse("The IPv6 address is no address");
            if (settings.prefix6[0] != 0) {
                const length = numberOf(untilNul(&settings.prefix6)) orelse 0;
                if (length < 1 or length > 128) return app.refuse("The prefix length is 1 to 128");
            }
            if (settings.gateway6[0] != 0 and !app.isAddress(bsd.AF_INET6, &settings.gateway6)) return app.refuse("The IPv6 gateway is no address");
        }
        return true;
    }

    fn refuse(app: *App, comptime text: [:0]const u8) bool {
        app.say(text, .{});
        return false;
    }

    fn isAddress(app: *App, family: i32, text: [*:0]const u8) bool {
        var address: [16]u8 = undefined;
        return app.sb.Inet_PtoN(family, text, &address) == 1;
    }

    /// A net mask as an address: an empty one stays empty, a prefix length
    /// is made the address it means; false for one that is neither.
    fn netmaskOf(app: *App, mask: *settings_file.Field) bool {
        const text = untilNul(mask);
        if (text.len == 0) return true;
        const digits = if (text[0] == '/') text[1..] else text;
        if (numberOf(digits)) |length| {
            if (length > 32) return false;
            const bits: u32 = if (length == 0) 0 else ~@as(u32, 0) << @intCast(32 - length);
            const line = &app.scratch;
            line.say(app.sys, "%u.%u.%u.%u", .{ bits >> 24, (bits >> 16) & 0xFF, (bits >> 8) & 0xFF, bits & 0xFF });
            put(mask, line.slice());
            return true;
        }
        var address: [4]u8 = undefined;
        if (app.sb.Inet_PtoN(bsd.AF_INET, @ptrCast(mask), &address) != 1) return false;
        // The ones first, then only noughts.
        const value = @as(u32, address[0]) << 24 | @as(u32, address[1]) << 16 | @as(u32, address[2]) << 8 | address[3];
        return value == 0 or @clz(~value) + @ctz(value) == 32;
    }

    /// Save: the settings checked, written to the file, and - once asked -
    /// put to use.
    fn save(app: *App) void {
        if (!app.loaded or !app.gather()) return;
        const settings = &app.gathered;
        const picked = app.interface() orelse return;
        var path: netinterface.Path = undefined;
        const at = netinterface.pathOf(untilNul(&picked.name), &path);
        // The file again as it is now: something else may have changed it
        // since it was read.
        const bytes = netinterface.readFile(app.dl, at, &app.files.bytes) orelse {
            app.say("%s cannot be read, or is too long to change here", .{at});
            return;
        };
        const written = settings_file.write(bytes, settings, &app.files.first, &app.files.second) orelse {
            app.say("%s would grow too long to change here", .{at});
            return;
        };
        if (!netinterface.writeFile(app.dl, at, written)) {
            app.say("%s cannot be written", .{at});
            return;
        }
        app.settings = settings.*;
        app.showSettings();
        const name: [*:0]const u8 = @ptrCast(&picked.name);
        if (!app.up()) {
            app.say("Saved - %s takes them as it is brought up", .{name});
            return;
        }
        const asked = requesters.EasyRequest(app.ib, app.window, .{
            .title = COMMAND_NAME,
            .text_format = "The settings are saved.\nStart %s again with them now?\nEvery connection it carries ends -\na session over it as well.",
            .gadget_format = "Start again|Later",
        }, null, .{name});
        if (asked != 1) {
            app.say("Saved - %s takes them when it is next brought up", .{name});
            return;
        }
        app.restart(picked);
    }

    /// The interface taken down and brought up again from its file.
    fn restart(app: *App, picked: *Interface) void {
        const window = app.window orelse return;
        app.ib.SetWindowPointerA(window, &[_]TagItem{ pair(wn.WA_BusyPointer, 1), .{} });
        defer app.ib.SetWindowPointerA(window, &[_]TagItem{.{}});
        const work = &app.files.work;
        netinterface.remInterface(app.dl, untilNul(&picked.name), work);
        const started = netinterface.addInterface(app.dl, untilNul(&picked.file), COMMAND_NAME, work);
        if (started.code != dos.RETURN_OK) {
            if (started.said.len != 0) {
                app.status.clear();
                app.status.put(started.said);
            } else {
                app.status.say(app.sys, "C:net/AddNetInterface failed: %ld", .{@as(i64, started.code)});
            }
            app.held = message_ticks;
            app.showStatus();
            return;
        }
        app.say("%s started again with the saved settings", .{@as([*:0]const u8, @ptrCast(&picked.name))});
    }

    // --- the tick ---------------------------------------------------------------

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

    fn ticked(app: *App) void {
        if (!app.timer_out or app.sys.CheckIO(&app.timer_req.node) == null) return;
        _ = app.sys.WaitIO(&app.timer_req.node);
        app.timer_out = false;
        app.startTimer();
        if (app.held > 0) app.held -= 1;
        app.refresh();
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

/// Whether `one` comes before `other`, letter by letter, case aside.
fn before(one: []const u8, other: []const u8) bool {
    for (one[0..@min(one.len, other.len)], other[0..@min(one.len, other.len)]) |a, b| {
        const left = netinterface.lower(a);
        const right = netinterface.lower(b);
        if (left != right) return left < right;
    }
    return one.len < other.len;
}

fn trimmed(text: []const u8) []const u8 {
    var start: usize = 0;
    var end = text.len;
    while (start < end and (text[start] == ' ' or text[start] == '\t' or text[start] == '\r')) start += 1;
    while (end > start and (text[end - 1] == ' ' or text[end - 1] == '\t' or text[end - 1] == '\r')) end -= 1;
    return text[start..end];
}

/// A number of decimal digits, at most three; null for anything else.
fn numberOf(text: []const u8) ?u32 {
    if (text.len == 0 or text.len > 3) return null;
    var value: u32 = 0;
    for (text) |char| {
        if (char < '0' or char > '9') return null;
        value = value * 10 + (char - '0');
    }
    return value;
}

fn button(ib: *IntuitionBase, label: [*:0]const u8, id: usize) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_Text, @intFromPtr(label)),
        pair(gc.GA_ID, id),
        pair(gc.GA_RelVerify, 1),
        .{},
    });
}

fn field(ib: *IntuitionBase, id: usize, max_chars: usize) ?*Object {
    return ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        pair(gc.GA_ID, id),
        pair(gc.GA_RelVerify, 1),
        pair(gc.GA_TabCycle, 1),
        pair(gc.STRINGA_MaxChars, max_chars),
        .{},
    });
}

fn chooser(ib: *IntuitionBase, id: usize, labels: [*:null]const ?[*:0]const u8) ?*Object {
    return ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, id),
        pair(gc.GA_RelVerify, 1),
        pair(ch.CHOOSER_Labels, @intFromPtr(labels)),
        .{},
    });
}

/// A framed group of labelled children, one under the other.
fn group(ib: *IntuitionBase, title: [*:0]const u8, children: []const struct { ?*Object, [*:0]const u8 }) ?*Object {
    var tags: [4 + 3 * 8 + 1]TagItem = undefined;
    var count: usize = 0;
    for ([_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_FrameTitle, @intFromPtr(title)),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 4),
    }) |tag| {
        tags[count] = tag;
        count += 1;
    }
    for (children) |child| {
        tags[count] = pair(lg.LAYOUTA_AddChild, @intFromPtr(child[0] orelse return null));
        tags[count + 1] = pair(lg.CHILDA_Label, @intFromPtr(child[1]));
        tags[count + 2] = pair(lg.CHILDA_WeightHeight, 0);
        count += 3;
    }
    tags[count] = .{};
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &tags);
}

/// The window's whole layout, or null when something could not be made.
/// A function of its own: its tag lists are a kilobyte of stack, given
/// back once the window is made rather than held through the loop.
noinline fn buildLayout(app: *App) ?*Object {
    const ib = app.ib;
    app.chooser = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_INTERFACE),
        pair(gc.GA_RelVerify, 1),
        pair(ch.CHOOSER_Labels, @intFromPtr(&app.labels)),
        pair(ch.CHOOSER_Active, app.current),
        pair(gc.GA_Disabled, @intFromBool(app.interface_count < 2)),
        .{},
    });
    app.status_gadget = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_RoomFor, @intFromPtr(status_room)),
        pair(tx.TEXT_Clipped, 1),
        pair(tx.TEXT_Text, @intFromPtr(app.shown_status.ptr())),
        .{},
    });
    app.configure_chooser = chooser(ib, ID_CONFIGURE, &configure_labels);
    app.address_field = field(ib, ID_ADDRESS, 15);
    app.netmask_field = field(ib, ID_NETMASK, 15);
    app.gateway_field = field(ib, ID_GATEWAY, 15);
    app.servers_field = field(ib, ID_SERVERS, @sizeOf(settings_file.Servers) - 1);
    app.domain_field = field(ib, ID_DOMAIN, @sizeOf(settings_file.Field) - 1);
    app.ipv6_chooser = chooser(ib, ID_IPV6, &ipv6_labels);
    app.address6_field = field(ib, ID_ADDRESS6, settings_file.server_max);
    app.prefix6_field = field(ib, ID_PREFIX6, 3);
    app.gateway6_field = field(ib, ID_GATEWAY6, settings_file.server_max);
    app.save_button = button(ib, "_Save", ID_SAVE);
    app.revert_button = button(ib, "_Revert", ID_REVERT);

    const ipv4 = group(ib, "IPv4", &.{
        .{ app.configure_chooser, "Configure" },
        .{ app.address_field, "Address" },
        .{ app.netmask_field, "Net mask" },
        .{ app.gateway_field, "Gateway" },
    }) orelse return null;
    const names = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_FrameTitle, @intFromPtr("Names")),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 4),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.servers_field orelse return null)),
        pair(lg.CHILDA_Label, @intFromPtr("Name servers")),
        pair(lg.CHILDA_MinWidth, servers_columns * fontWidth(app) + 12),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.domain_field orelse return null)),
        pair(lg.CHILDA_Label, @intFromPtr("Domain")),
        pair(lg.CHILDA_WeightHeight, 0),
        .{},
    }) orelse return null;
    const ipv6 = group(ib, "IPv6", &.{
        .{ app.ipv6_chooser, "IPv6" },
        .{ app.address6_field, "Address" },
        .{ app.prefix6_field, "Prefix length" },
        .{ app.gateway6_field, "Gateway" },
    }) orelse return null;
    const buttons = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 8),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.save_button orelse return null)),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.revert_button orelse return null)),
        .{},
    }) orelse return null;
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.chooser orelse return null)),
        pair(lg.CHILDA_Label, @intFromPtr("_Interface")),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.status_gadget orelse return null)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(ipv4)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(names)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(ipv6)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(buttons)),
        pair(lg.CHILDA_WeightHeight, 0),
        .{},
    });
}

/// How wide a character of the screen's font is, which the name servers'
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

    var libraries: [6]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_][*:0]const u8{
        intuition.INTUITIONNAME, graphics.GRAPHICSNAME, bsd.SOCKETNAME,
        st.STRING_LIBRARY,       tx.TEXT_LIBRARY,       ch.CHOOSER_LIBRARY,
    };
    for (wanted, 0..) |name, index| {
        libraries[index] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, name });
            return dos.RETURN_FAIL;
        };
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);

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
        .sb = @ptrCast(libraries[2].?),
        .files = @ptrCast(@alignCast(files_memory)),
    };

    app.findInterfaces();
    if (rdargs.string(argv[arg_interface])) |asked| {
        for (app.interfaces[0..app.interface_count], 0..) |*one, index| {
            if (netinterface.sameWord(untilNul(&one.file), spanOf(asked))) app.current = index;
        }
    }
    if (app.interface_count == 0) app.labels[0] = "no interface";

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
        pair(wn.WA_Title, @intFromPtr("Network")),
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

    app.load(app.current);
    app.startTimer();

    var code_word: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code_word };
    while (true) {
        var mask: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_SigMask, app.object.?, &mask);
        const got = sys.Wait(@as(u32, @intCast(mask)) | app.timerMask() | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_OK;
        if (got & app.timerMask() != 0) app.ticked();
        while (true) {
            const word = ib.SendMessage(app.object.?, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_INTERFACE => if (code_word < app.interface_count and code_word != app.current) app.load(code_word),
                    ID_CONFIGURE => {
                        app.configure = code_word;
                        app.showEnabled();
                    },
                    ID_IPV6 => {
                        app.ipv6 = code_word;
                        app.showEnabled();
                    },
                    ID_SAVE => app.save(),
                    ID_REVERT => {
                        app.load(app.current);
                        app.say("The file is read again", .{});
                    },
                    else => {},
                },
                else => {},
            }
        }
    }
}
