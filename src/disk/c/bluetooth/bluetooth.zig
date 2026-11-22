// SPDX-License-Identifier: MIT
//! Bluetooth: the system's Bluetooth controllers - listed, set, and made
//! to look for the devices around. Built against the SDK only.
//!
//!   Bluetooth [INFO/S] [SCAN/S] [TIME/K/N] [POWER/K] [NAME/K]
//!             [VISIBLE/K] [CONTROLLER/K/N]
//!
//!   Bluetooth          each controller on a line: its number, its
//!                      address, whether it is up - and then on or off,
//!                      visible, looking - and its device
//!   Bluetooth INFO     and what it is: the device and unit, the chip and
//!                      the firmware it was given, the versions of its
//!                      HCI and link manager and who made it, its
//!                      buffers, what it can do, its name and class
//!   POWER ON|OFF       the controller on, or off: off, it answers nobody
//!   NAME <name>        the name it shows others; NAME "" the machine's
//!   VISIBLE ON|OFF|<seconds>
//!                      found by others who look: until told otherwise,
//!                      not at all, or for that many seconds
//!   SCAN [TIME <s>]    the devices around, each on a line as it is
//!                      found - its address, how it was heard, its
//!                      signal, its name, what it is - and again when its
//!                      name comes; for about TIME seconds (10), then the
//!                      names not yet heard are asked for. CTRL-C stops.
//!                      With INFO, what each said of itself after.
//!   CONTROLLER <n>     the one controller these are for; without it,
//!                      every one
//!
//! POWER and NAME, and VISIBLE ON, are kept for the controller's next
//! start. The controllers are bluetooth.library's (ObtainBTControllers),
//! the devices its discovery's (StartBTDiscovery, ObtainBTDevices).

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const hcidev = sdk.devices.hci;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const BluetoothBase = sdk.interface.bluetooth.BluetoothBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Bluetooth";
const VERSION_STRING = "\x00$VER: Bluetooth 1.2 (22.11.2026)\r\n";

const template = "INFO/S,SCAN/S,TIME/K/N,POWER/K,NAME/K,VISIBLE/K,CONTROLLER/K/N";
const arg_info = 0;
const arg_scan = 1;
const arg_time = 2;
const arg_power = 3;
const arg_name = 4;
const arg_visible = 5;
const arg_controller = 6;
const arg_count = 7;

/// How many devices a scan follows: four controllers' worth.
const followed_most = 256;

const MSG_BREAK = "***Break\n";

/// How many characters of a device's name its line has room for: the 24
/// of `device`'s formats.
const name_column = 24;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const bt_lib = sys.OpenLibrary(bluetooth.BLUETOOTHNAME, 1) orelse {
        _ = Printf(dl, "no %s\n", .{@as([*:0]const u8, bluetooth.BLUETOOTHNAME)});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(bt_lib);
    const bt: *BluetoothBase = @ptrCast(bt_lib);

    const controller: u32 = if (argv[arg_controller] != 0) @bitCast(@as(*const i32, @ptrFromInt(argv[arg_controller])).*) else bluetooth.BT_ALL_CONTROLLERS;

    if (argv[arg_power] != 0 or argv[arg_name] != 0 or argv[arg_visible] != 0) {
        const done = set(dl, bt, controller, &argv);
        if (done != dos.RETURN_OK) return done;
    }
    if (argv[arg_scan] != 0) {
        const seconds: u32 = if (argv[arg_time] != 0) @bitCast(@as(*const i32, @ptrFromInt(argv[arg_time])).*) else 10;
        return scan(sys, dl, bt, controller, seconds, argv[arg_info] != 0);
    }
    return list(dl, bt, controller, argv[arg_info] != 0);
}

// --- the controllers ------------------------------------------------------------

fn list(dl: *DosBase, bt: *BluetoothBase, controller: u32, with_info: bool) i32 {
    const controllers = bt.ObtainBTControllers() orelse {
        _ = dl.PutStr("no memory\n");
        return dos.RETURN_FAIL;
    };
    defer bt.ReleaseBTControllers(controllers);
    var any = false;
    var it = controllers.iterator();
    while (it.next()) |node| {
        const found: *bluetooth.BTController = @fieldParentPtr("node", node);
        if (controller != bluetooth.BT_ALL_CONTROLLERS and found.id != controller) continue;
        if (with_info and any) _ = dl.PutStr("\n");
        any = true;
        line(dl, found);
        if (with_info) info(dl, found);
    }
    if (!any) {
        _ = dl.PutStr(if (controller == bluetooth.BT_ALL_CONTROLLERS) "no Bluetooth controller\n" else "no such controller\n");
        return if (controller == bluetooth.BT_ALL_CONTROLLERS) dos.RETURN_OK else dos.RETURN_WARN;
    }
    return dos.RETURN_OK;
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

/// Its number, address - dashes until the controller has said it - state,
/// what it does, and device.
fn line(dl: *DosBase, controller: *const bluetooth.BTController) void {
    const address = &controller.address.bytes;
    var text: [18]u8 = undefined;
    if (address[0] | address[1] | address[2] | address[3] | address[4] | address[5] == 0) {
        _ = Printf(dl, "%u: --:--:--:--:--:--  %s", .{ controller.id, stateName(controller.state) });
    } else {
        _ = Printf(dl, "%u: %s  %s", .{ controller.id, addressText(address, &text), stateName(controller.state) });
    }
    if (controller.state == bluetooth.BTCS_FAILED) _ = Printf(dl, " (%s)", .{failureName(controller.failure)});
    if (controller.state == bluetooth.BTCS_UP) {
        const flags = controller.flags;
        _ = dl.PutStr(if (flags & bluetooth.BTCF_POWERED != 0) ", on" else ", off");
        if (flags & bluetooth.BTCF_VISIBLE != 0) {
            if (controller.visible_left == bluetooth.BT_VISIBLE_ALWAYS) {
                _ = dl.PutStr(", visible");
            } else {
                _ = Printf(dl, ", visible for %u s", .{controller.visible_left});
            }
        }
        if (flags & bluetooth.BTCF_DISCOVERING != 0) _ = dl.PutStr(", looking");
    }
    _ = Printf(dl, "  %s unit %u\n", .{ controller.node.name orelse @as([*:0]const u8, "?"), controller.unit });
}

fn stateName(state: u32) [*:0]const u8 {
    return switch (state) {
        bluetooth.BTCS_OPENING => "opening",
        bluetooth.BTCS_STARTING => "starting",
        bluetooth.BTCS_UP => "up",
        bluetooth.BTCS_FAILED => "failed",
        else => "?",
    };
}

fn failureName(failure: i32) [*:0]const u8 {
    return switch (failure) {
        bluetooth.BTERR_NOMEM => "no memory",
        bluetooth.BTERR_OPENFAIL => "its device did not open",
        bluetooth.BTERR_TIMEOUT => "a command was not answered",
        bluetooth.BTERR_DETACHED => "it has gone",
        bluetooth.BTERR_PROTOCOL => "its device failed",
        hci.HCI_ERR_UNKNOWN_COMMAND => "it does not take a command it needs",
        hci.HCI_ERR_HARDWARE_FAILURE => "a hardware failure",
        else => "it refused a command",
    };
}

/// What a call's failure means, for the one controller or every one.
fn callFailure(result: i32, controller: u32) [*:0]const u8 {
    return switch (result) {
        bluetooth.BTERR_NOMEM => "no memory",
        bluetooth.BTERR_NOCONTROLLER => if (controller == bluetooth.BT_ALL_CONTROLLERS) "no Bluetooth controller" else "no such controller",
        bluetooth.BTERR_NOTUP => "the controller is not up",
        bluetooth.BTERR_OFF => "the controller is off (POWER ON)",
        bluetooth.BTERR_UNSUPPORTED => "the controller cannot do that",
        else => "it failed",
    };
}

/// What a version number is called.
fn versionName(version: u8) [*:0]const u8 {
    const names = [_][*:0]const u8{ "1.0b", "1.1", "1.2", "2.0", "2.1", "3.0", "4.0", "4.1", "4.2", "5.0", "5.1", "5.2", "5.3", "5.4", "6.0" };
    return if (version < names.len) names[version] else "later than 6.0";
}

/// A few of the makers' company identifiers: the controllers' chips, and
/// the devices' makers most often heard.
fn makerName(company: u16) ?[*:0]const u8 {
    return switch (company) {
        2 => "Intel",
        6 => "Microsoft",
        10 => "Qualcomm (CSR)",
        15 => "Broadcom",
        29 => "Qualcomm",
        70 => "MediaTek",
        76 => "Apple",
        93 => "Realtek",
        117 => "Samsung",
        158 => "Bose",
        224 => "Google",
        301 => "Sony",
        305 => "Cypress",
        else => null,
    };
}

fn has(bits: []const u8, n: u32) bool {
    return bits[n / 8] & (@as(u8, 1) << @intCast(n % 8)) != 0;
}

/// The device and unit, chip, firmware, versions, buffers, features.
fn info(dl: *DosBase, controller: *const bluetooth.BTController) void {
    if (controller.chip) |chip| _ = Printf(dl, "  chip        %s\n", .{chip});
    if (controller.firmware) |firmware| _ = Printf(dl, "  firmware    %s\n", .{firmware});
    switch (controller.bus) {
        hcidev.HCIBUS_USB => _ = Printf(dl, "  bus         USB\n", .{}),
        hcidev.HCIBUS_UART => if (controller.baud != 0) {
            _ = Printf(dl, "  bus         UART, %u bit/s\n", .{controller.baud});
        } else {
            _ = Printf(dl, "  bus         UART\n", .{});
        },
        else => _ = Printf(dl, "  bus         ?\n", .{}),
    }
    if (controller.state != bluetooth.BTCS_UP and controller.hci_version == 0 and controller.manufacturer == 0) return;
    _ = Printf(dl, "  HCI         %s, revision %u\n", .{ versionName(controller.hci_version), @as(u32, controller.hci_revision) });
    _ = Printf(dl, "  LMP         %s, subversion %u\n", .{ versionName(controller.lmp_version), @as(u32, controller.lmp_subversion) });
    if (makerName(controller.manufacturer)) |maker| {
        _ = Printf(dl, "  made by     %s (%u)\n", .{ maker, @as(u32, controller.manufacturer) });
    } else {
        _ = Printf(dl, "  made by     company %u\n", .{@as(u32, controller.manufacturer)});
    }
    const page0 = &controller.features[0];
    const page1 = &controller.features[1];
    const page2 = &controller.features[2];
    const bredr = !has(page0, hci.LMP_BREDR_NOT_SUPPORTED);
    const le = has(page0, hci.LMP_LE);
    _ = Printf(dl, "  radio       %s\n", .{@as([*:0]const u8, if (bredr and le) "BR/EDR and LE" else if (le) "LE" else "BR/EDR")});
    if (bredr) _ = Printf(dl, "  ACL         %u packets of %u bytes; SCO %u of %u\n", .{
        @as(u32, controller.acl_packets),
        @as(u32, controller.acl_mtu),
        @as(u32, controller.sco_packets),
        @as(u32, controller.sco_mtu),
    });
    if (le) _ = Printf(dl, "  LE ACL      %u packets of %u bytes\n", .{ @as(u32, controller.le_packets), @as(u32, controller.le_mtu) });
    _ = dl.PutStr("  features   ");
    const features = [_]struct { bits: []const u8, n: u32, label: [*:0]const u8 }{
        .{ .bits = page0, .n = hci.LMP_EDR_ACL_2M, .label = "EDR 2 Mbit/s" },
        .{ .bits = page0, .n = hci.LMP_EDR_ACL_3M, .label = "EDR 3 Mbit/s" },
        .{ .bits = page0, .n = hci.LMP_ESCO, .label = "eSCO" },
        .{ .bits = page0, .n = hci.LMP_SIMPLE_PAIRING, .label = "Secure Simple Pairing" },
        .{ .bits = page1, .n = hci.LMP_HOST_SIMPLE_PAIRING, .label = "(on)" },
        .{ .bits = page2, .n = hci.LMP_SECURE_CONNECTIONS, .label = "Secure Connections" },
        .{ .bits = page0, .n = hci.LMP_EXTENDED_INQUIRY, .label = "extended inquiry" },
        .{ .bits = page0, .n = hci.LMP_SNIFF_SUBRATING, .label = "sniff subrating" },
        .{ .bits = &controller.le_features, .n = hci.LE_FEATURE_ENCRYPTION, .label = "LE encryption" },
        .{ .bits = &controller.le_features, .n = hci.LE_FEATURE_DATA_LENGTH, .label = "LE data length" },
        .{ .bits = &controller.le_features, .n = hci.LE_FEATURE_PRIVACY, .label = "LE privacy" },
        .{ .bits = &controller.le_features, .n = hci.LE_FEATURE_2M_PHY, .label = "LE 2M PHY" },
        .{ .bits = &controller.le_features, .n = hci.LE_FEATURE_CODED_PHY, .label = "LE Coded PHY" },
        .{ .bits = &controller.le_features, .n = hci.LE_FEATURE_EXTENDED_ADVERTISING, .label = "extended advertising" },
    };
    var shown: u32 = 0;
    for (features) |feature| {
        if (!has(feature.bits, feature.n)) continue;
        if (shown % 4 == 0 and shown != 0) _ = dl.PutStr("\n             ");
        _ = Printf(dl, " %s", .{feature.label});
        shown += 1;
    }
    if (shown == 0) _ = dl.PutStr(" none of note");
    _ = dl.PutStr("\n");
    if (controller.name[0] != 0) _ = Printf(dl, "  name        %s\n", .{controller.name});
    _ = Printf(dl, "  class       %06lx\n", .{@as(u64, controller.class_of_device)});
}

// --- the settings ---------------------------------------------------------------

/// Whether a word is `word`, in any case.
fn same(text: [*:0]const u8, word: []const u8) bool {
    for (word, 0..) |wanted, index| {
        const char = text[index];
        if (char == 0) return false;
        const lowered = if (char >= 'A' and char <= 'Z') char + 32 else char;
        const wanted_lowered = if (wanted >= 'A' and wanted <= 'Z') wanted + 32 else wanted;
        if (lowered != wanted_lowered) return false;
    }
    return text[word.len] == 0;
}

/// POWER, NAME, VISIBLE given to the controller, then the controllers
/// listed as they are now.
fn set(dl: *DosBase, bt: *BluetoothBase, controller: u32, argv: *const [arg_count]usize) i32 {
    var tags: [4]utility.TagItem = @splat(.{});
    var count: usize = 0;
    if (argv[arg_power] != 0) {
        const word: [*:0]const u8 = @ptrFromInt(argv[arg_power]);
        const on = if (same(word, "ON")) true else if (same(word, "OFF")) false else {
            _ = dl.PutStr("POWER is ON or OFF\n");
            return dos.RETURN_ERROR;
        };
        tags[count] = .{ .tag = bluetooth.BTCA_Powered, .data = @intFromBool(on) };
        count += 1;
    }
    if (argv[arg_name] != 0) {
        tags[count] = .{ .tag = bluetooth.BTCA_Name, .data = argv[arg_name] };
        count += 1;
    }
    if (argv[arg_visible] != 0) {
        const word: [*:0]const u8 = @ptrFromInt(argv[arg_visible]);
        var seconds: u32 = 0;
        if (same(word, "ON")) {
            seconds = bluetooth.BT_VISIBLE_ALWAYS;
        } else if (!same(word, "OFF")) {
            var value: i32 = 0;
            if (dl.StrToLong(word, &value) <= 0 or value <= 0) {
                _ = dl.PutStr("VISIBLE is ON, OFF or a number of seconds\n");
                return dos.RETURN_ERROR;
            }
            seconds = @intCast(value);
        }
        tags[count] = .{ .tag = bluetooth.BTCA_Visible, .data = seconds };
        count += 1;
    }
    const result = bt.SetBTControllerAttrs(controller, &tags);
    if (result != 0) {
        _ = Printf(dl, "%s: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), callFailure(result, controller) });
        return dos.RETURN_ERROR;
    }
    return dos.RETURN_OK;
}

// --- the scan ---------------------------------------------------------------------

/// What a device's line showed of its name.
const Shown = enum(u8) { none, short, whole };

fn shownOf(found: *const bluetooth.BTDevice) Shown {
    const name = found.node.name orelse return .none;
    if (name[0] == 0) return .none;
    return if (found.flags & bluetooth.BTDF_SHORT_NAME != 0) .short else .whole;
}

/// A device the scan has shown, and how much of its name.
const Followed = struct {
    address: [6]u8 = @splat(0),
    kind: u8 = 0,
    shown: Shown = .none,
};

const Follow = struct {
    devices: [followed_most]Followed = @splat(.{}),
    count: usize = 0,

    fn find(follow: *Follow, found: *const bluetooth.BTDevice) ?*Followed {
        for (follow.devices[0..follow.count]) |*followed| {
            if (followed.kind != found.address.kind) continue;
            var same_bytes = true;
            for (followed.address, found.address.bytes) |mine, theirs| {
                if (mine != theirs) same_bytes = false;
            }
            if (same_bytes) return followed;
        }
        return null;
    }
};

/// The controller - or every one - made to look; each device shown as it
/// is found, and again when its name comes, until no controller looks or
/// CTRL-C.
fn scan(sys: *ExecBase, dl: *DosBase, bt: *BluetoothBase, controller: u32, seconds: u32, with_info: bool) i32 {
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(signal);
    const mask = @as(u32, 1) << @intCast(signal);
    const notify = bt.AddBTNotify(sys.FindTask(null).?, mask) orelse return dos.RETURN_FAIL;
    defer bt.RemBTNotify(notify);
    const memory = sys.AllocVec(@sizeOf(Follow), exec.MEMF_CLEAR) orelse {
        _ = dl.PutStr("no memory\n");
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const follow: *Follow = @ptrCast(@alignCast(memory));
    follow.* = .{};

    const started = bt.StartBTDiscovery(controller, seconds);
    if (started != 0) {
        _ = Printf(dl, "%s: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), callFailure(started, controller) });
        return dos.RETURN_ERROR;
    }
    // The library's bounds: 2 to 60 seconds, about 10 for 0.
    const shown_seconds: u32 = if (seconds == 0) 10 else @min(@max(seconds, 2), 60);
    _ = Printf(dl, "Looking for about %u s, then for the names; CTRL-C stops\n", .{shown_seconds});
    var broken = false;
    while (true) {
        const got = sys.Wait(mask | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) {
            bt.StopBTDiscovery(controller);
            broken = true;
        }
        showNew(dl, bt, controller, follow);
        if (broken or !looking(bt, controller)) break;
    }
    if (broken) _ = dl.PutStr(MSG_BREAK);
    _ = Printf(dl, "%u found\n", .{@as(u32, @intCast(follow.count))});
    if (with_info) details(dl, bt, controller);
    return if (broken) dos.RETURN_WARN else dos.RETURN_OK;
}

/// Whether any of the controllers still looks.
fn looking(bt: *BluetoothBase, controller: u32) bool {
    const controllers = bt.ObtainBTControllers() orelse return false;
    defer bt.ReleaseBTControllers(controllers);
    var it = controllers.iterator();
    while (it.next()) |node| {
        const found: *bluetooth.BTController = @fieldParentPtr("node", node);
        if (controller != bluetooth.BT_ALL_CONTROLLERS and found.id != controller) continue;
        if (found.flags & bluetooth.BTCF_DISCOVERING != 0) return true;
    }
    return false;
}

/// The devices not shown yet, and those whose name - or whole name - has
/// come since.
fn showNew(dl: *DosBase, bt: *BluetoothBase, controller: u32, follow: *Follow) void {
    const devices = bt.ObtainBTDevices(controller) orelse return;
    defer bt.ReleaseBTDevices(devices);
    var it = devices.iterator();
    while (it.next()) |node| {
        const found: *bluetooth.BTDevice = @fieldParentPtr("node", node);
        const shown = shownOf(found);
        if (follow.find(found)) |followed| {
            if (@intFromEnum(shown) <= @intFromEnum(followed.shown)) continue;
            followed.shown = shown;
        } else {
            if (follow.count == follow.devices.len) continue;
            follow.devices[follow.count] = .{ .address = found.address.bytes, .kind = found.address.kind, .shown = shown };
            follow.count += 1;
        }
        device(dl, found);
    }
}

/// One device on a line: address, how it was heard, signal, name, what it
/// is.
fn device(dl: *DosBase, found: *const bluetooth.BTDevice) void {
    var text: [18]u8 = undefined;
    const how: [*:0]const u8 = if (found.flags & bluetooth.BTDF_BREDR != 0)
        (if (found.flags & bluetooth.BTDF_LE != 0) "BR/EDR+LE" else "BR/EDR")
    else if (found.address.kind == bluetooth.BTADDR_LE_RANDOM) "LE random" else "LE";
    const name: [*:0]const u8 = if (found.node.name) |kept| (if (kept[0] != 0) kept else unnamed(found)) else unnamed(found);
    _ = Printf(dl, "  %s  %-9s", .{ addressText(&found.address.bytes, &text), how });
    if (found.rssi == bluetooth.BT_RSSI_NONE) {
        _ = dl.PutStr("    --    ");
    } else {
        _ = Printf(dl, "  %4ld dBm", .{@as(i64, found.rssi)});
    }
    const what = whatItIs(found);
    if (what[0] == 0) {
        _ = Printf(dl, "  %.24s\n", .{name});
    } else {
        _ = Printf(dl, "  %-24.24s  %s\n", .{ name, what });
    }
}

fn unnamed(found: *const bluetooth.BTDevice) [*:0]const u8 {
    return if (found.flags & bluetooth.BTDF_NO_NAME != 0) "(no name)" else "-";
}

/// What a device is: its class of device's major and minor class, or LE's
/// appearance; empty where it said neither.
fn whatItIs(found: *const bluetooth.BTDevice) [*:0]const u8 {
    if (found.class_of_device != 0) {
        const major = (found.class_of_device >> 8) & 0x1F;
        const minor = (found.class_of_device >> 2) & 0x3F;
        return switch (major) {
            hci.COD_MAJOR_COMPUTER => switch (minor) {
                hci.COD_COMPUTER_LAPTOP => "laptop",
                hci.COD_COMPUTER_HANDHELD => "handheld",
                else => "computer",
            },
            hci.COD_MAJOR_PHONE => "phone",
            hci.COD_MAJOR_NETWORK => "network access point",
            hci.COD_MAJOR_AUDIO_VIDEO => switch (minor) {
                1 => "headset",
                2 => "hands-free",
                4 => "microphone",
                5 => "loudspeaker",
                6 => "headphones",
                7 => "portable audio",
                8 => "car audio",
                10 => "hi-fi",
                14, 15 => "display",
                18 => "game console",
                else => "audio/video",
            },
            hci.COD_MAJOR_PERIPHERAL => switch (minor >> 4) {
                1 => "keyboard",
                2 => "mouse",
                3 => "keyboard and mouse",
                else => switch (minor & 0xF) {
                    1 => "joystick",
                    2 => "gamepad",
                    3 => "remote control",
                    5 => "tablet",
                    else => "peripheral",
                },
            },
            hci.COD_MAJOR_IMAGING => "printer or camera",
            hci.COD_MAJOR_WEARABLE => "wearable",
            hci.COD_MAJOR_TOY => "toy",
            hci.COD_MAJOR_HEALTH => "health device",
            else => "",
        };
    }
    return switch (found.appearance) {
        0 => "",
        0x03C1 => "keyboard",
        0x03C2 => "mouse",
        0x03C3 => "joystick",
        0x03C4 => "gamepad",
        0x03C5 => "tablet",
        0x0941 => "earbuds",
        0x0942 => "headset",
        0x0943 => "headphones",
        else => switch (found.appearance >> 6) {
            1 => "phone",
            2 => "computer",
            3 => "watch",
            4 => "clock",
            5 => "display",
            6 => "remote control",
            8 => "tag",
            9 => "keyring",
            10 => "media player",
            12 => "thermometer",
            13 => "heart rate sensor",
            15 => "input device",
            21 => "sensor",
            22, 31 => "light",
            33 => "speaker",
            34 => "audio source",
            37 => "headphones",
            41 => "hearing aid",
            42 => "game controller",
            else => "",
        },
    };
}

/// What each device found said of itself.
fn details(dl: *DosBase, bt: *BluetoothBase, controller: u32) void {
    const devices = bt.ObtainBTDevices(controller) orelse return;
    defer bt.ReleaseBTDevices(devices);
    var it = devices.iterator();
    while (it.next()) |node| {
        const found: *bluetooth.BTDevice = @fieldParentPtr("node", node);
        _ = dl.PutStr("\n");
        device(dl, found);
        if (found.node.name) |name| {
            if (characters(name) > name_column) {
                _ = Printf(dl, "      name %s%s\n", .{ name, @as([*:0]const u8, if (found.flags & bluetooth.BTDF_SHORT_NAME != 0) " (shortened)" else "") });
            } else if (found.flags & bluetooth.BTDF_SHORT_NAME != 0) {
                _ = dl.PutStr("      its name shortened\n");
            }
        }
        _ = Printf(dl, "      controller %u, heard %u ms ago", .{ found.controller, found.age });
        if (found.class_of_device != 0) _ = Printf(dl, ", class %06lx", .{@as(u64, found.class_of_device)});
        if (found.appearance != 0) _ = Printf(dl, ", appearance %04lx", .{@as(u64, found.appearance)});
        if (found.tx_power != bluetooth.BT_TX_POWER_NONE) _ = Printf(dl, ", sends at %ld dBm", .{@as(i64, found.tx_power)});
        if (found.flags & bluetooth.BTDF_CONNECTABLE != 0) _ = dl.PutStr(", connectable");
        _ = dl.PutStr("\n");
        if (found.company != bluetooth.BT_COMPANY_NONE) {
            if (makerName(found.company)) |maker| {
                _ = Printf(dl, "      made by %s\n", .{maker});
            } else {
                _ = Printf(dl, "      made by company %u\n", .{@as(u32, found.company)});
            }
        }
        for (found.uuid16[0..found.uuid16_count]) |uuid| {
            if (serviceName(uuid)) |service| {
                _ = Printf(dl, "      service %04lx  %s\n", .{ @as(u64, uuid), service });
            } else {
                _ = Printf(dl, "      service %04lx\n", .{@as(u64, uuid)});
            }
        }
        for (found.uuid128[0..found.uuid128_count]) |*uuid| {
            var uuid_text: [37]u8 = undefined;
            _ = Printf(dl, "      service %s\n", .{uuidText(uuid, &uuid_text)});
        }
    }
}

/// How many characters a UTF-8 text has: its bytes but the ones that go
/// on a character.
fn characters(text: [*:0]const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (text[index] != 0) : (index += 1) {
        if (text[index] & 0xC0 != 0x80) count += 1;
    }
    return count;
}

/// A 128-bit UUID as it is written, from its bytes as they are sent: the
/// least significant first.
fn uuidText(uuid: *const [16]u8, into: *[37]u8) [*:0]const u8 {
    const hex = "0123456789ABCDEF";
    var at: usize = 0;
    var index: usize = 16;
    while (index > 0) {
        index -= 1;
        into[at] = hex[uuid[index] >> 4];
        into[at + 1] = hex[uuid[index] & 0xF];
        at += 2;
        if (index == 12 or index == 10 or index == 8 or index == 6) {
            into[at] = '-';
            at += 1;
        }
    }
    into[at] = 0;
    return @ptrCast(into);
}

/// What the services most often offered are, by their 16-bit UUID.
fn serviceName(uuid: u16) ?[*:0]const u8 {
    return switch (uuid) {
        0x1101 => "serial port",
        0x1105 => "object push",
        0x1106 => "file transfer",
        0x1108 => "headset",
        0x110A => "audio source",
        0x110B => "audio sink",
        0x110C => "remote control target",
        0x110E => "remote control",
        0x1112 => "headset audio gateway",
        0x1115 => "network user",
        0x1116 => "network access point",
        0x111E => "hands-free",
        0x111F => "hands-free audio gateway",
        0x1124 => "keyboard, mouse or game controller",
        0x112F => "phone book",
        0x1132 => "messages",
        0x1200 => "device identification",
        0x180A => "device information",
        0x180D => "heart rate",
        0x180F => "battery",
        0x1812 => "keyboard, mouse or game controller over LE",
        else => null,
    };
}

export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
