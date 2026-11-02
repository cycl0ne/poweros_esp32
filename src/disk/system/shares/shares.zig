// SPDX-License-Identifier: MIT
//! Shares: the shares of other machines added to this one, in a window.
//! Built against the SDK only.
//!
//!   Shares SERVER/K,USER/K,DOMAIN/K
//!
//! SERVER is a server to look at as soon as the window opens, and USER
//! and DOMAIN who to log on to it as; without them the window opens on
//! what this machine already knows.
//!
//! **A server typed in and asked.** The field at the top takes a server
//! however it is written - `nas.lan`, `//nas.lan`, `\\nas.lan`,
//! `smb://nas.lan`, any of them with `:port` after the name and an IPv6
//! address in brackets, and a share after it is ignored, since the shares
//! are what is being asked for. Connect logs on - anonymously, with
//! nothing filled in - and asks the server what shares it has. A server
//! that will not have an anonymous logon, or that logs one on and then
//! will not answer the question, is asking for a user and a password: a
//! window opens for them and the question is put again. Log on opens that
//! window at any time, to come back as somebody else.
//!
//! **A share mounted.** Every share the server answered is in the list,
//! what kind it is beside it - the ones the server keeps for itself,
//! `IPC$` and a drive's `C$`, are marked as its own - and only one that
//! holds files can be mounted. Picking one fills in a device name made
//! from its own - in capitals, with anything a name may
//! not hold made an underscore, cut to the longest a device name may be -
//! which can be typed over. Mount writes the share's file in
//! `DEVS:Shares/`, the password's hash in `ENVARC:Sys/net/shares/` when
//! there is a password to keep, and then runs `C:net/MountShare`, which
//! mounts it: the share is on the device list at once and comes back at
//! every start, since the startup mounts every share there is a file for.
//! A mount that fails takes the files back off and says why.
//!
//! **What this machine knows** is the lower list: a line for every share
//! file, whether its device is mounted or not. Mount and Dismount put one
//! on the device list and take it off; Forget takes the share off this
//! machine altogether, its file and its kept password with it.
//!
//! The password is never kept as it was typed. It is hashed - MD4 over
//! its UTF-16, which is all a logon needs - and it is the hash that is
//! written down, as `C:net/MountShare` writes it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const smb = dos.smb;
const intuition = sdk.intuition;
const client = @import("smbclient");
const share_area = client.shares;
const sharefile = client.sharefile;
const browse = client.browse;
const words = @import("words.zig");
const known = @import("known.zig");
const server = @import("server.zig");
const Line = words.Line;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const graphics = sdk.graphics;
const TagItem = sdk.utility.TagItem;
const Object = intuition.Object;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const crypto = sdk.crypto;
const bsd = sdk.bsdsocket;
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

pub const COMMAND_NAME = "Shares";
const VERSION = "1.0";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (02.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "SERVER/K,USER/K,DOMAIN/K";
const arg_server = 0;
const arg_user = 1;
const arg_domain = 2;
const arg_count = 3;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_OLDCRYPTO = "%s: needs crypto.library %u.%u, which hashes with MD4\n";
const MSG_NOMEMORY = "%s: no memory\n";
const MSG_NOWINDOW = "%s: no window\n";

/// crypto.library's first revision with MD4, which the NT hash is.
const CRYPTO_VERSION = 1;
const CRYPTO_REVISION = 4;

/// The command MountShare is run as, and where its two streams go.
const mount_command = "C:net/MountShare ";
const out_file = "T:Shares.out";
const err_file = "T:Shares.err";
const redirection = " QUIET <NIL: >" ++ out_file ++ " *>" ++ err_file;

/// The gadgets.
const ID_SERVER = 1;
const ID_CONNECT = 2;
const ID_LOGON = 3;
const ID_FOUND = 4;
const ID_NAME = 5;
const ID_READONLY = 6;
const ID_ENCRYPT = 7;
const ID_MOUNT = 8;
const ID_MINE = 9;
const ID_REMOUNT = 10;
const ID_DISMOUNT = 11;
const ID_FORGET = 12;
const ID_USER = 20;
const ID_PASSWORD = 21;
const ID_DOMAIN = 22;
const ID_KEEP = 23;
const ID_OK = 24;
const ID_CANCEL = 25;

/// No share picked.
const none_picked: usize = ~@as(usize, 0);

/// A field says which key ended it, as the raw key it was: Return and the
/// keypad's Enter do what the button beside the field does, where Tab and
/// a press elsewhere only leave the field.
const raw_return: u32 = 0x44;
const raw_enter: u32 = 0x43;

fn entered(code: u32) bool {
    return code == raw_return or code == raw_enter;
}

/// How many rows each list shows without being made taller.
const found_rows_shown = 6;
const mine_rows_shown = 4;

/// The longest comment shown of a share.
const comment_max: usize = 64;

/// How many characters wide the fields of the logon window are, in the
/// screen's font: a name, a password and a domain are typed into them.
const logon_columns: usize = 28;

const found_columns = [_]lb.Column{
    .{ .title = "Share", .weight = 3 },
    .{ .title = "Kind", .weight = 2 },
    .{ .title = "Comment", .weight = 4 },
    .{ .title = "Mounted as", .weight = 2 },
    .{},
};

const mine_columns = [_]lb.Column{
    .{ .title = "Device", .weight = 2 },
    .{ .title = "Share", .weight = 4 },
    .{ .title = "User", .weight = 2 },
    .{ .title = "State", .weight = 2 },
    .{},
};

fn pair(tag: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = tag, .data = data };
}

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    cb: *CryptoBase,

    /// The window and its layout's root.
    object: ?*Object = null,
    window: ?*intuition.Window = null,

    /// The server being looked at, and who logs on to it.
    link: server.Link,
    account: server.Account = .{},

    /// What the status line says, the server field's text, and the name
    /// field's while it is being filled in from a share.
    status: Line = .{},
    shown_server: [server.shown_max:0]u8 = @splat(0),
    suggested: [known.device_max + 1:0]u8 = @splat(0),

    /// The server's shares.
    found: ?*Object = null,
    found_rows: exec.List = .{},
    picked: usize = none_picked,

    name_field: ?*Object = null,
    readonly_box: ?*Object = null,
    encrypt_box: ?*Object = null,
    mount_button: ?*Object = null,
    server_field: ?*Object = null,
    connect_button: ?*Object = null,
    logon_button: ?*Object = null,
    status_gadget: ?*Object = null,

    /// What this machine knows.
    mine: ?*Object = null,
    mine_rows: exec.List = .{},
    known_list: known.List = .{},
    picked_known: usize = none_picked,
    remount_button: ?*Object = null,
    dismount_button: ?*Object = null,
    forget_button: ?*Object = null,

    /// The window that asks who to log on as.
    logon_object: ?*Object = null,
    logon_window: ?*intuition.Window = null,
    user_field: ?*Object = null,
    password_field: ?*Object = null,
    domain_field: ?*Object = null,
    keep_box: ?*Object = null,
    logon_title: Line = .{},

    // --- the gadgets' texts -------------------------------------------------------

    /// A line on the status line until the next one.
    fn say(app: *App, comptime format: [:0]const u8, args: anytype) void {
        app.status.say(app.sys, format, args);
        app.set(app.status_gadget, &.{ pair(tx.TEXT_Text, @intFromPtr(app.status.ptr())), .{} });
    }

    fn set(app: *App, object: ?*Object, tags: []const TagItem) void {
        _ = app.ib.SetGadgetAttrsTagList(object orelse return, app.window, tags.ptr);
    }

    fn setIn(app: *App, window: ?*intuition.Window, object: ?*Object, tags: []const TagItem) void {
        _ = app.ib.SetGadgetAttrsTagList(object orelse return, window, tags.ptr);
    }

    fn enable(app: *App, object: ?*Object, on: bool) void {
        app.set(object, &.{ pair(gc.GA_Disabled, @intFromBool(!on)), .{} });
    }

    /// What a string gadget holds now.
    fn textOf(app: *App, object: ?*Object) []const u8 {
        var at: usize = 0;
        _ = app.ib.GetAttr(gc.STRINGA_TextVal, object orelse return &.{}, &at);
        if (at == 0) return &.{};
        return words.spanOf(@ptrFromInt(at));
    }

    fn checked(app: *App, object: ?*Object) bool {
        var value: usize = 0;
        _ = app.ib.GetAttr(cb_class.CHECKBOX_Checked, object orelse return false, &value);
        return value != 0;
    }

    /// The row a list has selected, and what it stands for.
    fn selectedOf(app: *App, object: ?*Object) ?*lb.Row {
        var at: usize = 0;
        _ = app.ib.GetAttr(lb.LISTBROWSER_SelectedRow, object orelse return null, &at);
        if (at == 0) return null;
        return @ptrFromInt(at);
    }

    // --- the server's shares ------------------------------------------------------

    /// The upper list made anew from what the last look found.
    fn showFound(app: *App) void {
        app.set(app.found, &.{ pair(lb.LISTBROWSER_Rows, lb.LISTBROWSER_DETACH), .{} });
        lb.freeRows(app.sys, &app.found_rows);
        var selected: u32 = lb.LISTBROWSER_NONE;
        for (app.link.shares[0..app.link.count], 0..) |*share, index| {
            var name: [client.names.name_max:0]u8 = @splat(0);
            const shown = client.names.toDos(share.name, @ptrCast(&name));
            name[shown.len] = 0;
            var comment: [comment_max + 1:0]u8 = @splat(0);
            _ = latin1Of(share.comment, &comment);
            var mounted: [known.device_max + 2:0]u8 = @splat(0);
            if (app.mountedAs(shown)) |device| {
                const length = @min(device.len, known.device_max);
                @memcpy(mounted[0..length], device[0..length]);
                mounted[length] = ':';
            }
            const texts = [_][*:0]const u8{ @ptrCast(&name), server.kindName(share), @ptrCast(&comment), @ptrCast(&mounted) };
            const row = lb.allocRow(app.sys, &texts, 0) orelse break;
            row.user_data = index;
            app.sys.AddTail(&app.found_rows, &row.node);
            if (app.picked == index) selected = @intCast(countOf(&app.found_rows) - 1);
        }
        app.set(app.found, &.{
            pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.found_rows)),
            pair(lb.LISTBROWSER_Selected, selected),
            .{},
        });
        app.showPicked();
    }

    /// Which device a share of the server being looked at is mounted as,
    /// if any: the share files are matched on the server and the share's
    /// name together.
    fn mountedAs(app: *App, share: []const u8) ?[]const u8 {
        for (app.known_list.items[0..app.known_list.count]) |*item| {
            if (item.wrong) continue;
            const place = client.place.placeOf(item.share()) orelse continue;
            if (!known.sameName(place.server, app.link.serverName())) continue;
            if (!known.sameName(place.share, share)) continue;
            return item.name();
        }
        return null;
    }

    /// The fields under the upper list follow the share picked in it: the
    /// name it suggests, and whether it can be mounted at all.
    fn showPicked(app: *App) void {
        const share = app.pickedShare();
        const mountable = share != null and share.?.isDisk() and client.names.fits(share.?.name);
        if (share) |picked| {
            var shown: [client.names.name_max:0]u8 = @splat(0);
            const name = client.names.toDos(picked.name, @ptrCast(&shown));
            _ = known.deviceNameOf(name, &app.suggested);
            // A name already taken is left as it is: typing over it is
            // the one way to mount the same share twice.
            if (known.standingOf(app.dl, words.untilNul(&app.suggested)) != .none) {
                app.say("%s: is taken already - another name mounts the share beside it", .{@as([*:0]const u8, @ptrCast(&app.suggested))});
            }
            app.set(app.name_field, &.{ pair(gc.STRINGA_TextVal, @intFromPtr(@as([*:0]const u8, @ptrCast(&app.suggested)))), .{} });
        }
        app.enable(app.name_field, mountable);
        app.enable(app.readonly_box, mountable);
        app.enable(app.encrypt_box, mountable);
        app.enable(app.mount_button, mountable);
        if (share != null and !mountable) {
            if (!share.?.isDisk()) {
                app.say("that one holds no files: only a disk share can be mounted", .{});
            } else {
                app.say("that share's name cannot be written in a share file", .{});
            }
        }
    }

    fn pickedShare(app: *App) ?*share_area.Share {
        if (app.picked >= app.link.count) return null;
        return &app.link.shares[app.picked];
    }

    // --- what this machine knows --------------------------------------------------

    /// The lower list made anew from the share files and the device list.
    fn showMine(app: *App) void {
        app.known_list.read(app.dl);
        app.set(app.mine, &.{ pair(lb.LISTBROWSER_Rows, lb.LISTBROWSER_DETACH), .{} });
        lb.freeRows(app.sys, &app.mine_rows);
        var selected: u32 = lb.LISTBROWSER_NONE;
        for (app.known_list.items[0..app.known_list.count], 0..) |*item, index| {
            var device: [known.device_max + 2:0]u8 = @splat(0);
            const name = item.name();
            @memcpy(device[0..name.len], name);
            device[name.len] = ':';
            var where: Line = .{};
            var user: Line = .{};
            var state: Line = .{};
            if (item.wrong) {
                where.put("its file says nothing this understands");
            } else {
                where.put(item.share());
                if (item.file.port != 0) where.add(app.sys, " port %u", .{@as(u32, item.file.port)});
                user.put(item.user());
                if (user.length == 0) user.put("-");
                if (item.password) user.put(", password kept");
            }
            state.put(if (item.mounted) "mounted" else "not mounted");
            if (!item.wrong and item.file.readonly) state.put(", read only");
            if (!item.wrong and item.file.encrypt) state.put(", encrypted");
            const texts = [_][*:0]const u8{ @ptrCast(&device), where.ptr(), user.ptr(), state.ptr() };
            const row = lb.allocRow(app.sys, &texts, 0) orelse break;
            row.user_data = index;
            app.sys.AddTail(&app.mine_rows, &row.node);
            if (app.picked_known == index) selected = @intCast(index);
        }
        app.set(app.mine, &.{
            pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.mine_rows)),
            pair(lb.LISTBROWSER_Selected, selected),
            .{},
        });
        app.showPickedKnown();
    }

    fn pickedKnown(app: *App) ?*known.Known {
        if (app.picked_known >= app.known_list.count) return null;
        return &app.known_list.items[app.picked_known];
    }

    fn showPickedKnown(app: *App) void {
        const item = app.pickedKnown();
        app.enable(app.remount_button, item != null and !item.?.mounted and !item.?.wrong);
        app.enable(app.dismount_button, item != null and item.?.mounted);
        app.enable(app.forget_button, item != null);
    }

    // --- the things the buttons do ------------------------------------------------

    /// Connect: the server read out of the field, logged on to and asked.
    /// A server that wants a user says so, and the window for one opens.
    fn connect(app: *App) void {
        const typed = app.textOf(app.server_field);
        if (typed.len == 0) {
            app.say("type a server to look at: a name, an address, or %s", .{"//nas.lan"});
            return;
        }
        if (!app.link.setServer(typed)) {
            app.say("that is not a server's name", .{});
            return;
        }
        app.picked = none_picked;
        app.look();
        if (app.link.wants_user) {
            app.openLogon();
            return;
        }
        app.showFound();
    }

    /// The look itself, with the pointer busy while it goes: the window
    /// hears nothing until the server has answered or given up.
    fn look(app: *App) void {
        app.say("asking %s...", .{@as([*:0]const u8, @ptrCast(&app.link.server))});
        app.busy(true);
        app.link.look(&app.account);
        app.busy(false);
        server.say(&app.link, &app.status);
        app.set(app.status_gadget, &.{ pair(tx.TEXT_Text, @intFromPtr(app.status.ptr())), .{} });
    }

    fn busy(app: *App, on: bool) void {
        const tags = [_]TagItem{ pair(wn.WA_BusyPointer, @intFromBool(on)), .{} };
        if (app.window) |w| app.ib.SetWindowPointerA(w, &tags);
        if (app.logon_window) |w| app.ib.SetWindowPointerA(w, &tags);
    }

    /// Mount: the share picked written down and mounted under the name in
    /// the field. A mount that does not come off takes the files away
    /// again, so nothing is left that the next start would try.
    fn mount(app: *App) void {
        const share = app.pickedShare() orelse return;
        var shown: [client.names.name_max:0]u8 = @splat(0);
        const share_name = client.names.toDos(share.name, @ptrCast(&shown));
        const device = app.textOf(app.name_field);
        if (!known.nameAllowed(device)) {
            app.say("a device's name has letters, digits, %s in it, and nothing else", .{"- _ ."});
            return;
        }
        var name: [known.device_max + 1:0]u8 = @splat(0);
        _ = words.copyInto(&name, device);
        switch (known.standingOf(app.dl, device)) {
            .share => {
                app.say("%s: is a share mounted already", .{@as([*:0]const u8, @ptrCast(&name))});
                return;
            },
            .other => {
                app.say("%s: is a device of another kind", .{@as([*:0]const u8, @ptrCast(&name))});
                return;
            },
            .none => {},
        }

        // Where the share is, as a share file says it.
        var place: Line = .{};
        place.put("//");
        place.put(app.link.serverName());
        place.put("/");
        place.put(share_name);
        if (!sharefile.savable(place.slice()) or !sharefile.savable(app.account.userName())) {
            app.say("a quote in the share's name or the user's cannot be written down", .{});
            return;
        }

        var path: known.Path = undefined;
        const share_path = known.pathOf(&path, sharefile.directory, words.untilNul(&name));
        const written = sharefile.writeTo(app.dl, share_path, words.untilNul(&name), &.{
            .share = place.slice(),
            .user = given(app.account.userName()),
            .domain = given(app.account.domainName()),
            .port = if (app.link.port == 0) null else app.link.port,
            .readonly = app.checked(app.readonly_box),
            .encrypt = app.checked(app.encrypt_box),
        });
        if (!written) {
            app.sayFault("%s: could not be written", .{share_path});
            return;
        }
        // The hash, so that a start after this one logs on by itself.
        var kept_password = false;
        if (app.account.has_hash and app.account.keep) {
            var hash_path: known.Path = undefined;
            const password_path = known.pathOf(&hash_path, sharefile.password_directory, words.untilNul(&name));
            if (sharefile.writePassword(app.dl, password_path, &app.account.nt_hash)) {
                kept_password = true;
            } else {
                app.sayFault("%s: could not be written", .{password_path});
                known.unwrite(app.dl, words.untilNul(&name), false);
                return;
            }
        }
        if (!app.runMountShare(words.untilNul(&name), false)) {
            known.unwrite(app.dl, words.untilNul(&name), kept_password);
            app.showMine();
            return;
        }
        app.say("%s: is //%s/%s", .{ @as([*:0]const u8, @ptrCast(&name)), @as([*:0]const u8, @ptrCast(&app.link.server)), @as([*:0]const u8, @ptrCast(&shown)) });
        app.showMine();
        app.showFound();
    }

    /// Mount or Dismount in the lower list.
    fn remount(app: *App, off: bool) void {
        const item = app.pickedKnown() orelse return;
        var name: [known.device_max + 1:0]u8 = @splat(0);
        _ = words.copyInto(&name, item.name());
        if (app.runMountShare(words.untilNul(&name), off)) {
            if (off) {
                app.say("%s: is off the device list", .{@as([*:0]const u8, @ptrCast(&name))});
            } else {
                app.say("%s: is mounted", .{@as([*:0]const u8, @ptrCast(&name))});
            }
        }
        app.showMine();
        app.showFound();
    }

    /// Forget: the share off this machine, dismounted first if it is on
    /// the device list. Asked for first, since a kept password goes with
    /// it.
    fn forget(app: *App) void {
        const item = app.pickedKnown() orelse return;
        var name: [known.device_max + 1:0]u8 = @splat(0);
        _ = words.copyInto(&name, item.name());
        const mounted = item.mounted;
        const asked = requesters.EasyRequest(app.ib, app.window, .{
            .title = COMMAND_NAME,
            .text_format = "Forget %s:?\nIts share file goes, and the password kept for it.",
            .gadget_format = "Forget|Cancel",
        }, null, .{@as([*:0]const u8, @ptrCast(&name))});
        if (asked != 1) return;
        if (mounted and !app.runMountShare(words.untilNul(&name), true)) {
            app.showMine();
            return;
        }
        known.forget(app.dl, words.untilNul(&name));
        app.picked_known = none_picked;
        app.say("%s: is forgotten", .{@as([*:0]const u8, @ptrCast(&name))});
        app.showMine();
        app.showFound();
    }

    /// `C:net/MountShare <device> [DISMOUNT]` run, its two streams read
    /// into the status line: true when it came to nothing to say.
    fn runMountShare(app: *App, device: []const u8, off: bool) bool {
        var command: [160:0]u8 = @splat(0);
        var line: usize = 0;
        for ([_][]const u8{ mount_command, device, if (off) " DISMOUNT" else "", redirection }) |part| {
            for (part) |char| {
                if (line + 1 >= command.len) break;
                command[line] = char;
                line += 1;
            }
        }
        command[line] = 0;
        app.busy(true);
        const code = app.dl.SystemTagList(@ptrCast(&command), &[_]TagItem{
            pair(dos.NP_StackSize, dos.CLI_DEFAULT_STACK),
            .{},
        });
        app.busy(false);
        // What it said, whichever stream it said it on. A command that
        // says nothing and ends well did what it was asked.
        if (app.saidBy(out_file) or app.saidBy(err_file)) return code == dos.RETURN_OK;
        if (code == dos.RETURN_OK) return true;
        app.say("MountShare could not be run", .{});
        return false;
    }

    /// The first line with something in it of a file MountShare wrote,
    /// onto the status line: whether there was one. The file is deleted
    /// either way, so the next run does not read this one's.
    fn saidBy(app: *App, path: [*:0]const u8) bool {
        var said = false;
        if (app.dl.Open(path, dos.MODE_OLDFILE)) |handle| {
            var text: [words.line_max + 1]u8 = undefined;
            const got = app.dl.Read(handle, &text, text.len - 1);
            _ = app.dl.Close(handle);
            if (got > 0) {
                const bytes = text[0..@intCast(got)];
                var at: usize = 0;
                while (at < bytes.len and (bytes[at] == '\n' or bytes[at] == '\r')) at += 1;
                var end = at;
                while (end < bytes.len and bytes[end] != '\n' and bytes[end] != '\r') end += 1;
                if (end > at) {
                    app.status.clear();
                    app.status.put(bytes[at..end]);
                    app.set(app.status_gadget, &.{ pair(tx.TEXT_Text, @intFromPtr(app.status.ptr())), .{} });
                    said = true;
                }
            }
        }
        _ = app.dl.DeleteFile(path);
        return said;
    }

    /// A file that could not be written, said with the reason dos gives.
    fn sayFault(app: *App, comptime format: [:0]const u8, args: anytype) void {
        const reason = app.dl.IoErr();
        app.status.say(app.sys, format, args);
        var fault: [120:0]u8 = @splat(0);
        if (app.dl.Fault(reason, null, &fault, fault.len - 1) > 0 and fault[0] != 0) {
            app.status.put(": ");
            app.status.put(words.untilNul(&fault));
        }
        app.set(app.status_gadget, &.{ pair(tx.TEXT_Text, @intFromPtr(app.status.ptr())), .{} });
    }

    // --- who logs on --------------------------------------------------------------

    /// The window that asks who to log on as, made and opened: it stands
    /// beside the main one, which goes on answering.
    fn openLogon(app: *App) void {
        if (app.logon_object != null) {
            app.setIn(app.logon_window, app.user_field, &.{ pair(gc.GA_Disabled, 0), .{} });
            return;
        }
        const ib = app.ib;
        app.user_field = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_USER),
            pair(gc.GA_RelVerify, 1),
            pair(gc.GA_TabCycle, 1),
            pair(gc.STRINGA_MaxChars, smb.SMB_USER_MAX),
            pair(gc.STRINGA_TextVal, @intFromPtr(@as([*:0]const u8, @ptrCast(&app.account.user)))),
            .{},
        });
        app.password_field = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_PASSWORD),
            pair(gc.GA_RelVerify, 1),
            pair(gc.GA_TabCycle, 1),
            pair(gc.STRINGA_MaxChars, sharefile.password_max),
            pair(gc.STRINGA_Secret, 1),
            .{},
        });
        app.domain_field = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_DOMAIN),
            pair(gc.GA_RelVerify, 1),
            pair(gc.GA_TabCycle, 1),
            pair(gc.STRINGA_MaxChars, 64),
            pair(gc.STRINGA_TextVal, @intFromPtr(@as([*:0]const u8, @ptrCast(&app.account.domain)))),
            .{},
        });
        app.keep_box = ib.NewObjectTagList(null, cb_class.CHECKBOX_CLASS, &[_]TagItem{
            pair(gc.GA_ID, ID_KEEP),
            pair(cb_class.CHECKBOX_Checked, @intFromBool(app.account.keep)),
            .{},
        });
        // The fields are given room for a name and a password of the
        // length people actually use, which neither a label nor an empty
        // field would ask for on its own.
        const field_width = fontWidth(app) * logon_columns + 12;
        const fields = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
            pair(lg.LAYOUTA_Spacing, 4),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(app.user_field orelse return)),
            pair(lg.CHILDA_Label, @intFromPtr("_User")),
            pair(lg.CHILDA_MinWidth, field_width),
            pair(lg.CHILDA_WeightHeight, 0),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(app.password_field orelse return)),
            pair(lg.CHILDA_Label, @intFromPtr("_Password")),
            pair(lg.CHILDA_MinWidth, field_width),
            pair(lg.CHILDA_WeightHeight, 0),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(app.domain_field orelse return)),
            pair(lg.CHILDA_Label, @intFromPtr("_Domain")),
            pair(lg.CHILDA_MinWidth, field_width),
            pair(lg.CHILDA_WeightHeight, 0),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(app.keep_box orelse return)),
            pair(lg.CHILDA_Label, @intFromPtr("_Keep the password")),
            pair(lg.CHILDA_WeightHeight, 0),
            pair(lg.LAYOUTA_AddChild, @intFromPtr(buttonRow(ib, "Log on", ID_OK, "Cancel", ID_CANCEL) orelse return)),
            pair(lg.CHILDA_WeightHeight, 0),
            .{},
        }) orelse return;
        app.logon_title.say(app.sys, "Log on to %s", .{@as([*:0]const u8, @ptrCast(&app.link.server))});
        app.logon_object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            pair(wn.WA_Title, @intFromPtr(app.logon_title.ptr())),
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
        if (ib.SendMessage(app.logon_object.?, @ptrCast(&open)) == 0) {
            ib.DisposeObject(app.logon_object);
            app.logon_object = null;
            app.say("no window to ask in", .{});
            return;
        }
        var at: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_Window, app.logon_object.?, &at);
        app.logon_window = @ptrFromInt(at);
    }

    fn closeLogon(app: *App) void {
        const object = app.logon_object orelse return;
        app.ib.DisposeObject(object);
        app.logon_object = null;
        app.logon_window = null;
        app.user_field = null;
        app.password_field = null;
        app.domain_field = null;
        app.keep_box = null;
    }

    /// Log on: what was typed taken as the account, the password hashed
    /// and forgotten, and the server asked again.
    fn logon(app: *App) void {
        _ = words.copyInto(&app.account.user, app.textOf(app.user_field));
        _ = words.copyInto(&app.account.domain, app.textOf(app.domain_field));
        _ = words.copyInto(&app.account.password, app.textOf(app.password_field));
        app.account.keep = app.checked(app.keep_box);
        const typed = words.untilNul(&app.account.password);
        app.account.has_hash = typed.len > 0;
        if (app.account.has_hash) app.account.nt_hash = app.account.takePassword(app.cb);
        app.account.forgetPassword();
        app.setIn(app.logon_window, app.password_field, &.{ pair(gc.STRINGA_TextVal, @intFromPtr("")), .{} });
        app.closeLogon();
        app.picked = none_picked;
        app.look();
        app.showFound();
    }
};

/// An empty text is no text at all: a share file leaves the keyword out.
fn given(text: []const u8) ?[]const u8 {
    return if (text.len == 0) null else text;
}

/// A server's text as Latin-1, what it holds that Latin-1 does not made a
/// question mark: a comment, which is read and not used for anything.
fn latin1Of(utf16: []const u8, into: []u8) []const u8 {
    const count = @min(utf16.len / 2, into.len - 1);
    for (0..count) |index| {
        const unit = client.names.unitAt(utf16, index);
        into[index] = if (unit >= 0x20 and unit <= 0xFF) @intCast(unit) else '?';
    }
    into[count] = 0;
    return into[0..count];
}

fn countOf(list: *exec.List) usize {
    var count: usize = 0;
    var node = list.first();
    while (node) |it| : (node = it.next()) count += 1;
    return count;
}

fn button(ib: *IntuitionBase, text: [*:0]const u8, id: usize) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_Text, @intFromPtr(text)),
        pair(gc.GA_ID, id),
        pair(gc.GA_RelVerify, 1),
        .{},
    });
}

/// Two buttons side by side, each no wider than it needs.
fn buttonRow(ib: *IntuitionBase, left: [*:0]const u8, left_id: usize, right: [*:0]const u8, right_id: usize) ?*Object {
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 8),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(button(ib, left, left_id) orelse return null)),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(button(ib, right, right_id) orelse return null)),
        .{},
    });
}

/// The window's whole layout, or null when something could not be made.
fn buildLayout(app: *App) ?*Object {
    const ib = app.ib;
    app.server_field = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_SERVER),
        pair(gc.GA_RelVerify, 1),
        pair(gc.GA_TabCycle, 1),
        pair(gc.STRINGA_MaxChars, server.shown_max),
        pair(gc.STRINGA_TextVal, @intFromPtr(@as([*:0]const u8, @ptrCast(&app.shown_server)))),
        .{},
    });
    app.connect_button = button(ib, "Connect", ID_CONNECT);
    app.logon_button = button(ib, "Log on...", ID_LOGON);
    app.status_gadget = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Text, @intFromPtr(app.status.ptr())),
        pair(gc.GA_Width, 540),
        .{},
    });
    app.found = ib.NewObjectTagList(null, lb.LISTBROWSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_FOUND),
        pair(gc.GA_RelVerify, 1),
        pair(lb.LISTBROWSER_Columns, @intFromPtr(&found_columns)),
        pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.found_rows)),
        .{},
    });
    app.name_field = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_NAME),
        pair(gc.GA_RelVerify, 1),
        pair(gc.GA_TabCycle, 1),
        pair(gc.STRINGA_MaxChars, known.device_max),
        pair(gc.GA_Width, 140),
        .{},
    });
    app.readonly_box = ib.NewObjectTagList(null, cb_class.CHECKBOX_CLASS, &[_]TagItem{ pair(gc.GA_ID, ID_READONLY), .{} });
    app.encrypt_box = ib.NewObjectTagList(null, cb_class.CHECKBOX_CLASS, &[_]TagItem{ pair(gc.GA_ID, ID_ENCRYPT), .{} });
    app.mount_button = button(ib, "Mount", ID_MOUNT);
    app.mine = ib.NewObjectTagList(null, lb.LISTBROWSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_MINE),
        pair(gc.GA_RelVerify, 1),
        pair(lb.LISTBROWSER_Columns, @intFromPtr(&mine_columns)),
        pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.mine_rows)),
        .{},
    });
    app.remount_button = button(ib, "Mount", ID_REMOUNT);
    app.dismount_button = button(ib, "Dismount", ID_DISMOUNT);
    app.forget_button = button(ib, "Forget", ID_FORGET);

    const row_height = fontHeight(app);
    const top = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.server_field orelse return null)),
        pair(lg.CHILDA_Label, @intFromPtr("_Server")),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.connect_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.logon_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        .{},
    }) orelse return null;
    const picked_row = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.name_field orelse return null)),
        pair(lg.CHILDA_Label, @intFromPtr("Mount _as")),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.readonly_box orelse return null)),
        pair(lg.CHILDA_Label, @intFromPtr("_Read only")),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.encrypt_box orelse return null)),
        pair(lg.CHILDA_Label, @intFromPtr("_Encrypted")),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.mount_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        .{},
    }) orelse return null;
    const mine_row = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.remount_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.dismount_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.forget_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        .{},
    }) orelse return null;
    const found_group = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_FrameTitle, @intFromPtr("Shares on the server")),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 4),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.found orelse return null)),
        pair(lg.CHILDA_MinHeight, found_rows_shown * row_height + 24),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(picked_row)),
        pair(lg.CHILDA_WeightHeight, 0),
        .{},
    }) orelse return null;
    const mine_group = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_FrameTitle, @intFromPtr("Shares on this machine")),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 4),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.mine orelse return null)),
        pair(lg.CHILDA_MinHeight, mine_rows_shown * row_height + 24),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(mine_row)),
        pair(lg.CHILDA_WeightHeight, 0),
        .{},
    }) orelse return null;
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(top)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.status_gadget orelse return null)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(found_group)),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(mine_group)),
        .{},
    });
}

/// How wide a character of the screen's font is, which the fields of the
/// window that asks for a logon are measured in: a name and a password
/// are typed into them, so they are given room for one.
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

/// How tall a row of the screen's font is, which the lists' least heights
/// are measured in.
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

    var libraries: [8]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_][*:0]const u8{
        intuition.INTUITIONNAME, graphics.GRAPHICSNAME,     bsd.SOCKETNAME,
        crypto.CRYPTONAME,       lb.LISTBROWSER_LIBRARY,    st.STRING_LIBRARY,
        tx.TEXT_LIBRARY,         cb_class.CHECKBOX_LIBRARY,
    };
    for (wanted, 0..) |name, index| {
        libraries[index] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, name });
            return dos.RETURN_FAIL;
        };
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);
    const gb: *GraphicsBase = @ptrCast(libraries[1].?);
    const sb: *SocketBase = @ptrCast(libraries[2].?);
    const crypto_lib = libraries[3].?;
    if (crypto_lib.version == CRYPTO_VERSION and crypto_lib.revision < CRYPTO_REVISION) {
        _ = Printf(dl, MSG_OLDCRYPTO, .{ COMMAND_NAME, @as(u32, CRYPTO_VERSION), @as(u32, CRYPTO_REVISION) });
        return dos.RETURN_FAIL;
    }

    // The app, then the session's buffers and the one a listing is
    // gathered in. A look at a server writes requests of a few hundred
    // bytes and reads an answer no larger than the gathering buffer, so
    // the buffers are far smaller than a mounted share's handler keeps.
    const send_room: usize = 8 * 1024;
    const receive_room: usize = server.gather_size + 8 * 1024;
    const memory = sys.AllocVec(@sizeOf(App) + send_room + receive_room + server.gather_size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const bytes: [*]u8 = @ptrCast(memory);
    const app: *App = @ptrCast(@alignCast(memory));
    app.* = .{
        .sys = sys,
        .dl = dl,
        .ib = ib,
        .gb = gb,
        .cb = @ptrCast(crypto_lib),
        .link = .{
            .sys = sys,
            .sb = sb,
            .cb = @ptrCast(crypto_lib),
            .session = browse.sessionOn(sb, @ptrCast(crypto_lib), .{
                .send = bytes[@sizeOf(App)..][0..send_room],
                .receive = bytes[@sizeOf(App) + send_room ..][0..receive_room],
            }),
            .gather = bytes[@sizeOf(App) + send_room + receive_room ..][0..server.gather_size],
        },
    };
    app.found_rows.init(.unknown);
    app.mine_rows.init(.unknown);
    defer lb.freeRows(sys, &app.found_rows);
    defer lb.freeRows(sys, &app.mine_rows);

    if (rdargs.string(argv[arg_user])) |user| _ = words.copyInto(&app.account.user, words.spanOf(user));
    if (rdargs.string(argv[arg_domain])) |domain| _ = words.copyInto(&app.account.domain, words.spanOf(domain));
    const asked_server = rdargs.string(argv[arg_server]);
    if (asked_server) |name| {
        // The field holds the port too, since Connect reads the server
        // back out of it.
        if (app.link.setServer(words.spanOf(name))) _ = app.link.shownIn(&app.shown_server);
    }
    app.status.put("type a server and press Connect to see what shares it has");

    const layout = buildLayout(app) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    app.object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr("Shares")),
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
    defer app.closeLogon();

    app.showMine();
    app.showPicked();
    if (asked_server != null) app.connect();

    var code_word: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code_word };
    while (true) {
        var mask: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_SigMask, app.object.?, &mask);
        var logon_mask: usize = 0;
        if (app.logon_object) |object| _ = ib.GetAttr(wc.WINDOWA_SigMask, object, &logon_mask);
        const got = sys.Wait(@as(u32, @intCast(mask | logon_mask)) | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_OK;

        // The window that asks who to log on as, while it is up.
        if (app.logon_object) |object| {
            while (true) {
                const word = ib.SendMessage(object, @ptrCast(&handle));
                if (word == wc.WMHI_LASTMSG) break;
                switch (word & wc.WMHI_CLASSMASK) {
                    wc.WMHI_CLOSEWINDOW => {
                        app.closeLogon();
                        break;
                    },
                    wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                        ID_OK => {
                            app.logon();
                            break;
                        },
                        ID_PASSWORD => if (entered(code_word)) {
                            app.logon();
                            break;
                        },
                        ID_CANCEL => {
                            app.closeLogon();
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
                    ID_CONNECT => app.connect(),
                    ID_SERVER => if (entered(code_word)) app.connect(),
                    ID_LOGON => app.openLogon(),
                    ID_FOUND => {
                        if (app.selectedOf(app.found)) |row| app.picked = row.user_data;
                        app.showPicked();
                    },
                    ID_MOUNT => app.mount(),
                    ID_NAME => if (entered(code_word)) app.mount(),
                    ID_MINE => {
                        if (app.selectedOf(app.mine)) |row| app.picked_known = row.user_data;
                        app.showPickedKnown();
                    },
                    ID_REMOUNT => app.remount(false),
                    ID_DISMOUNT => app.remount(true),
                    ID_FORGET => app.forget(),
                    else => {},
                },
                else => {},
            }
        }
    }
}
