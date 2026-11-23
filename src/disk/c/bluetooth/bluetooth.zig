// SPDX-License-Identifier: MIT
//! Bluetooth: the system's Bluetooth controllers - listed, set, made to
//! look for the devices around, linked to them and paired with them.
//! Built against the SDK only.
//!
//!   Bluetooth [INFO/S] [SCAN/S] [TIME/K/N] [POWER/K] [NAME/K]
//!             [VISIBLE/K] [CONNECT/K] [DISCONNECT/K] [LIST/S] [LE/S]
//!             [RANDOM/S] [CONTROLLER/K/N] [PAIR/K] [PIN/K] [UNPAIR/K]
//!             [BONDS/S] [AGENT/S] [SERVICES/K]
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
//!   CONNECT <device>   a link made to the device - its address, or the
//!                      name a scan heard - and shown once it is up: over
//!                      LE for a device a scan heard over LE, or with LE
//!                      (its public address) or RANDOM (its random one)
//!   DISCONNECT <device>
//!                      the link to the device ended
//!   LIST               the links, each on a line: the device's address,
//!                      the kind of link, which side is its central, how
//!                      long it has been up, the device's name; with INFO,
//!                      who made it, whether it is encrypted and
//!                      authenticated, to a device with a bond, its
//!                      handle and its class, LE's parameters
//!   PAIR <device>      a bond made with the device - its address, or the
//!                      name a scan heard, over LE where CONNECT would
//!                      link over LE - what the pairing needs asked here:
//!                      whether the device shows the same number (y or
//!                      n), the number it shows, its PIN; or a number to
//!                      type on the device. CTRL-C stops.
//!   PIN <pin>          the PIN given to a device that asks for one
//!   UNPAIR <device>    the bond ended - by its address, or the device's
//!                      name - and a link to the device
//!   BONDS              the bonds, each on a line: the device's address,
//!                      the kind of link it is for, how its pairing was
//!                      confirmed, the device's name; with INFO, its
//!                      controller, class and key - an LE key's size, and
//!                      whether the device gave its identity
//!   AGENT              the pairings the devices begin answered here, as
//!                      PAIR's are, until CTRL-C
//!   SERVICES <device>  the services the device offers, asked of it over
//!                      BR/EDR - its address, or the name a scan heard -
//!                      each on a line: what it is, the PSM or RFCOMM
//!                      channel it is reached on, its name; with INFO, its
//!                      profile and the profile's version, and its
//!                      record's handle
//!   CONTROLLER <n>     the one controller these are for; without it,
//!                      every one - for CONNECT, the one with a link to
//!                      the device, else the one that found it, else the
//!                      first that is on
//!
//! POWER and NAME, and VISIBLE ON, are kept for the controller's next
//! start, as the bonds are. The controllers are bluetooth.library's
//! (ObtainBTControllers), the devices its discovery's (StartBTDiscovery,
//! ObtainBTDevices), the links and bonds its too (ConnectBTDevice,
//! DisconnectBTDevice, ObtainBTConnections, PairBTDevice, UnpairBTDevice,
//! ObtainBTBonds), PAIR and AGENT its agents (AddBTAgent), and the
//! services its SDP client's (ObtainBTServices).

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
const VERSION_STRING = "\x00$VER: Bluetooth 1.7 (23.11.2026)\r\n";

const template = "INFO/S,SCAN/S,TIME/K/N,POWER/K,NAME/K,VISIBLE/K,CONNECT/K,DISCONNECT/K,LIST/S,LE/S,RANDOM/S,CONTROLLER/K/N," ++
    "PAIR/K,PIN/K,UNPAIR/K,BONDS/S,AGENT/S,SERVICES/K";
const arg_info = 0;
const arg_scan = 1;
const arg_time = 2;
const arg_power = 3;
const arg_name = 4;
const arg_visible = 5;
const arg_connect = 6;
const arg_disconnect = 7;
const arg_list = 8;
const arg_le = 9;
const arg_random = 10;
const arg_controller = 11;
const arg_pair = 12;
const arg_pin = 13;
const arg_unpair = 14;
const arg_bonds = 15;
const arg_agent = 16;
const arg_services = 17;
const arg_count = 18;

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
    if (argv[arg_connect] != 0) return connect(dl, bt, controller, @ptrFromInt(argv[arg_connect]), &argv);
    if (argv[arg_disconnect] != 0) return disconnect(dl, bt, controller, @ptrFromInt(argv[arg_disconnect]), &argv);
    if (argv[arg_list] != 0) return links(dl, bt, controller, argv[arg_info] != 0);
    const pin: ?[*:0]const u8 = if (argv[arg_pin] != 0) @ptrFromInt(argv[arg_pin]) else null;
    if (argv[arg_pair] != 0) return pairWith(sys, dl, bt, controller, @ptrFromInt(argv[arg_pair]), pin, &argv);
    if (argv[arg_unpair] != 0) return unpair(dl, bt, controller, @ptrFromInt(argv[arg_unpair]));
    if (argv[arg_bonds] != 0) return showBonds(dl, bt, controller, argv[arg_info] != 0);
    if (argv[arg_agent] != 0) return agent(sys, dl, bt, pin);
    if (argv[arg_services] != 0) return services(dl, bt, controller, @ptrFromInt(argv[arg_services]), &argv);
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

/// Why a link was not made or ended.
fn linkFailure(dl: *DosBase, result: i32, controller: u32) void {
    const reason: ?[*:0]const u8 = switch (result) {
        bluetooth.BTERR_TIMEOUT => "the device did not answer in time",
        bluetooth.BTERR_BUSY => "the controller is making another such link, or ending this one",
        bluetooth.BTERR_NOTCONNECTED => "no link to that device",
        bluetooth.BTERR_UNSUPPORTED => "the controller cannot make that kind of link",
        hci.HCI_ERR_PAGE_TIMEOUT => "the device did not answer",
        hci.HCI_ERR_CONNECTION_TIMEOUT => "the link was lost",
        hci.HCI_ERR_FAILED_TO_ESTABLISH => "the device did not answer on the new link",
        hci.HCI_ERR_LOCAL_HOST_TERMINATED => "taken back",
        hci.HCI_ERR_REJECTED_LIMITED_RESOURCES, hci.HCI_ERR_REJECTED_SECURITY, hci.HCI_ERR_REJECTED_ADDRESS => "the device refused",
        hci.HCI_ERR_CONNECTION_EXISTS => "there is a link to that device already",
        hci.HCI_ERR_PIN_OR_KEY_MISSING => "the device has no key for this machine (UNPAIR, and PAIR again)",
        hci.HCI_ERR_AUTHENTICATION_FAILURE => "the device did not take this machine's key",
        hci.HCI_ERR_INSUFFICIENT_SECURITY => "the link's encryption key is too short",
        hci.HCI_ERR_LMP_RESPONSE_TIMEOUT => "the device stopped answering",
        hci.HCI_ERR_REPEATED_ATTEMPTS => "the device wants a pause before the next try",
        else => if (result > 0) null else callFailure(result, controller),
    };
    if (reason) |text| {
        _ = Printf(dl, "%s: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), text });
    } else {
        _ = Printf(dl, "%s: the controller answered %02lx\n", .{ @as([*:0]const u8, COMMAND_NAME), @as(u64, @intCast(result)) });
    }
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

// --- the links --------------------------------------------------------------------

fn hexDigit(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

/// An address written "AA:BB:CC:DD:EE:FF", the most significant byte
/// first, into the order it is sent in; null for anything else.
fn parseAddress(text: [*:0]const u8) ?[6]u8 {
    var bytes: [6]u8 = undefined;
    var at: usize = 0;
    for (0..6) |index| {
        const high = hexDigit(text[at]) orelse return null;
        const low = hexDigit(text[at + 1]) orelse return null;
        bytes[5 - index] = high << 4 | low;
        at += 2;
        if (index == 5) break;
        if (text[at] != ':' and text[at] != '-') return null;
        at += 1;
    }
    if (text[at] != 0) return null;
    return bytes;
}

/// Whether two names are the same, in any case.
fn sameName(one: [*:0]const u8, other: [*:0]const u8) bool {
    var index: usize = 0;
    while (true) : (index += 1) {
        const mine = one[index];
        const theirs = other[index];
        const lowered = if (mine >= 'A' and mine <= 'Z') mine + 32 else mine;
        const theirs_lowered = if (theirs >= 'A' and theirs <= 'Z') theirs + 32 else theirs;
        if (lowered != theirs_lowered) return false;
        if (mine == 0) return true;
    }
}

fn sameBytes(one: *const [6]u8, other: *const [6]u8) bool {
    for (one, other) |mine, theirs| {
        if (mine != theirs) return false;
    }
    return true;
}

/// The device CONNECT or PAIR names: its address - of the kind LE or
/// RANDOM says, else of the kind a scan heard it as, else BR/EDR's - or a
/// name a scan heard; null for neither.
fn deviceNamed(bt: *BluetoothBase, controller: u32, text: [*:0]const u8, argv: *const [arg_count]usize) ?bluetooth.BTAddress {
    const bytes = parseAddress(text);
    if (bytes != null and (argv[arg_le] != 0 or argv[arg_random] != 0)) {
        return .{ .bytes = bytes.?, .kind = if (argv[arg_random] != 0) bluetooth.BTADDR_LE_RANDOM else bluetooth.BTADDR_LE_PUBLIC };
    }
    const devices = bt.ObtainBTDevices(controller) orelse return null;
    defer bt.ReleaseBTDevices(devices);
    var it = devices.iterator();
    while (it.next()) |node| {
        const found: *bluetooth.BTDevice = @fieldParentPtr("node", node);
        if (bytes) |wanted| {
            if (sameBytes(&found.address.bytes, &wanted)) return found.address;
        } else if (found.node.name) |name| {
            if (sameName(name, text)) return found.address;
        }
    }
    if (bytes) |wanted| return .{ .bytes = wanted };
    return null;
}

/// The link DISCONNECT names: by the device's address - of the kind LE or
/// RANDOM says, where one does - or its name; null for none.
fn linkNamed(bt: *BluetoothBase, controller: u32, text: [*:0]const u8, argv: *const [arg_count]usize) ?bluetooth.BTAddress {
    const bytes = parseAddress(text);
    const list_of_links = bt.ObtainBTConnections(controller) orelse return null;
    defer bt.ReleaseBTConnections(list_of_links);
    var it = list_of_links.iterator();
    while (it.next()) |node| {
        const link: *bluetooth.BTConnection = @fieldParentPtr("node", node);
        if (bytes) |wanted| {
            if (!sameBytes(&link.address.bytes, &wanted)) continue;
            if (argv[arg_random] != 0 and link.address.kind != bluetooth.BTADDR_LE_RANDOM) continue;
            if (argv[arg_le] != 0 and link.address.kind != bluetooth.BTADDR_LE_PUBLIC) continue;
            return link.address;
        } else if (link.node.name) |name| {
            if (sameName(name, text)) return link.address;
        }
    }
    return null;
}

/// CONNECT: the link made, and shown once it is up.
fn connect(dl: *DosBase, bt: *BluetoothBase, controller: u32, text: [*:0]const u8, argv: *const [arg_count]usize) i32 {
    const address = deviceNamed(bt, controller, text, argv) orelse {
        _ = Printf(dl, "%s: no device %s (an address, or a name a SCAN heard)\n", .{ @as([*:0]const u8, COMMAND_NAME), text });
        return dos.RETURN_ERROR;
    };
    var shown: [18]u8 = undefined;
    _ = Printf(dl, "Connecting to %s over %s\n", .{ addressText(&address.bytes, &shown), @as([*:0]const u8, if (address.kind == bluetooth.BTADDR_BREDR) "BR/EDR" else "LE") });
    const result = bt.ConnectBTDevice(controller, &address);
    if (result != 0) {
        // A device with a bond: the link may be up, not made secure.
        if (hasLink(bt, controller, &address)) _ = Printf(dl, "Linked to %s, not made secure\n", .{addressText(&address.bytes, &shown)});
        linkFailure(dl, result, controller);
        return dos.RETURN_ERROR;
    }
    return showLinks(dl, bt, controller, &address, false);
}

/// Whether the controller - or any, with BT_ALL_CONTROLLERS - has a link
/// to `address`.
fn hasLink(bt: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress) bool {
    const list_of_links = bt.ObtainBTConnections(controller) orelse return false;
    defer bt.ReleaseBTConnections(list_of_links);
    var it = list_of_links.iterator();
    while (it.next()) |node| {
        const link: *const bluetooth.BTConnection = @fieldParentPtr("node", node);
        if (sameBytes(&link.address.bytes, &address.bytes)) return true;
    }
    return false;
}

/// DISCONNECT: the link ended.
fn disconnect(dl: *DosBase, bt: *BluetoothBase, controller: u32, text: [*:0]const u8, argv: *const [arg_count]usize) i32 {
    const address = linkNamed(bt, controller, text, argv) orelse {
        _ = Printf(dl, "%s: no link to %s\n", .{ @as([*:0]const u8, COMMAND_NAME), text });
        return dos.RETURN_WARN;
    };
    const result = bt.DisconnectBTDevice(controller, &address);
    if (result != 0) {
        linkFailure(dl, result, controller);
        return dos.RETURN_ERROR;
    }
    var shown: [18]u8 = undefined;
    _ = Printf(dl, "Disconnected from %s\n", .{addressText(&address.bytes, &shown)});
    return dos.RETURN_OK;
}

/// LIST: every link of the controller - or of every one.
fn links(dl: *DosBase, bt: *BluetoothBase, controller: u32, with_info: bool) i32 {
    return showLinks(dl, bt, controller, null, with_info);
}

/// The links, or the one to `only`.
fn showLinks(dl: *DosBase, bt: *BluetoothBase, controller: u32, only: ?*const bluetooth.BTAddress, with_info: bool) i32 {
    const list_of_links = bt.ObtainBTConnections(controller) orelse {
        _ = dl.PutStr("no memory\n");
        return dos.RETURN_FAIL;
    };
    defer bt.ReleaseBTConnections(list_of_links);
    var any = false;
    var it = list_of_links.iterator();
    while (it.next()) |node| {
        const link: *bluetooth.BTConnection = @fieldParentPtr("node", node);
        if (only) |wanted| {
            if (link.address.kind != wanted.kind or !sameBytes(&link.address.bytes, &wanted.bytes)) continue;
        }
        any = true;
        linkLine(dl, link);
        if (with_info) linkInfo(dl, link);
    }
    if (!any and only == null) _ = dl.PutStr("no link\n");
    return dos.RETURN_OK;
}

/// One link on a line: the device's address, the kind of link, which side
/// is its central, how long it has been up, the device's name.
fn linkLine(dl: *DosBase, link: *const bluetooth.BTConnection) void {
    var text: [18]u8 = undefined;
    const kind: [*:0]const u8 = if (link.flags & bluetooth.BTLF_LE == 0) "BR/EDR" else if (link.address.kind == bluetooth.BTADDR_LE_RANDOM) "LE random" else "LE";
    const role: [*:0]const u8 = if (link.flags & bluetooth.BTLF_CENTRAL != 0) "central" else "peripheral";
    _ = Printf(dl, "  %s  %-9s  %-10s  %6u s", .{ addressText(&link.address.bytes, &text), kind, role, link.age / 1000 });
    const name: [*:0]const u8 = link.node.name orelse "";
    if (name[0] != 0) _ = Printf(dl, "  %s", .{name});
    _ = dl.PutStr("\n");
}

/// Who made the link, whether it is encrypted, its controller and
/// handle, the device's class, LE's parameters.
fn linkInfo(dl: *DosBase, link: *const bluetooth.BTConnection) void {
    const made: [*:0]const u8 = if (link.flags & bluetooth.BTLF_INCOMING != 0) "the device" else "this machine";
    const encrypted: [*:0]const u8 = if (link.flags & bluetooth.BTLF_ENCRYPTED != 0) ", encrypted" else ", not encrypted";
    const authenticated: [*:0]const u8 = if (link.flags & bluetooth.BTLF_AUTHENTICATED != 0) ", authenticated" else "";
    const bonded: [*:0]const u8 = if (link.flags & bluetooth.BTLF_PAIRING != 0) ", being paired" else if (link.flags & bluetooth.BTLF_BONDED != 0) ", bonded" else "";
    _ = Printf(dl, "      made by %s%s%s%s; controller %u, handle %u", .{ made, encrypted, authenticated, bonded, link.controller, @as(u32, link.handle) });
    if (link.class_of_device != 0) _ = Printf(dl, ", class %06lx", .{@as(u64, link.class_of_device)});
    _ = dl.PutStr("\n");
    if (link.flags & bluetooth.BTLF_LE != 0) {
        // In units of 1.25 ms, and of 10 ms.
        const hundredths = @as(u32, link.interval) * 125;
        _ = Printf(dl, "      every %u.%02u ms, latency %u, lost after %u ms unheard\n", .{
            hundredths / 100,
            hundredths % 100,
            @as(u32, link.latency),
            @as(u32, link.supervision) * 10,
        });
    }
}

// --- pairing ----------------------------------------------------------------------

/// Why a pairing did not begin, or did not make a bond.
fn pairFailure(dl: *DosBase, result: i32, controller: u32) void {
    const reason: ?[*:0]const u8 = switch (result) {
        bluetooth.BTERR_BONDED => "this machine has a bond with that device already (UNPAIR first)",
        bluetooth.BTERR_BUSY => "the device is being paired, or its link ended",
        bluetooth.BTERR_UNSUPPORTED => "the controller cannot pair over that kind of link",
        bluetooth.BTERR_REFUSED => "refused, or not answered in time",
        bluetooth.BTERR_TIMEOUT => "the device was not heard, or the pairing took too long",
        bluetooth.BTERR_NOMEM => "no room: the controller has its 32 bonds, or no memory",
        bluetooth.BTERR_DETACHED => "the controller has gone",
        hci.HCI_ERR_AUTHENTICATION_FAILURE => "the device refused, or the numbers did not match",
        hci.HCI_ERR_PIN_OR_KEY_MISSING => "no PIN, or the device has no key for this machine (UNPAIR, and PAIR again)",
        hci.HCI_ERR_PAIRING_NOT_ALLOWED => "the device does not pair now",
        hci.HCI_ERR_REPEATED_ATTEMPTS => "the device wants a pause before the next try",
        hci.HCI_ERR_INSUFFICIENT_SECURITY => "the link's encryption key is too short",
        hci.HCI_ERR_LMP_RESPONSE_TIMEOUT => "the device stopped answering",
        else => null,
    };
    if (reason) |text| {
        _ = Printf(dl, "%s: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), text });
    } else linkFailure(dl, result, controller);
}

/// PAIR: the pairing begun, and what it asks answered here until it is
/// over.
fn pairWith(sys: *ExecBase, dl: *DosBase, bt: *BluetoothBase, controller: u32, text: [*:0]const u8, pin: ?[*:0]const u8, argv: *const [arg_count]usize) i32 {
    // Of the kind CONNECT takes it as.
    const address = deviceNamed(bt, controller, text, argv) orelse {
        _ = Printf(dl, "%s: no device %s (an address, or a name a SCAN heard)\n", .{ @as([*:0]const u8, COMMAND_NAME), text });
        return dos.RETURN_ERROR;
    };
    var answering = Answering.open(sys, bt) orelse {
        _ = dl.PutStr("no memory\n");
        return dos.RETURN_FAIL;
    };
    defer answering.close();
    var shown: [18]u8 = undefined;
    _ = Printf(dl, "Pairing with %s over %s; CTRL-C stops\n", .{ addressText(&address.bytes, &shown), @as([*:0]const u8, if (address.kind == bluetooth.BTADDR_BREDR) "BR/EDR" else "LE") });
    const result = bt.PairBTDevice(controller, &address, answering.agent);
    if (result != 0) {
        pairFailure(dl, result, controller);
        return dos.RETURN_ERROR;
    }
    return answering.serve(dl, pin, &address, controller);
}

/// AGENT: the devices' pairings answered here until CTRL-C.
fn agent(sys: *ExecBase, dl: *DosBase, bt: *BluetoothBase, pin: ?[*:0]const u8) i32 {
    var answering = Answering.open(sys, bt) orelse {
        _ = dl.PutStr("no memory\n");
        return dos.RETURN_FAIL;
    };
    defer answering.close();
    _ = dl.PutStr("Answering the pairings devices begin; CTRL-C stops\n");
    return answering.serve(dl, pin, null, bluetooth.BT_ALL_CONTROLLERS);
}

/// An agent of this command's: its port, and the library's handle.
const Answering = struct {
    sys: *ExecBase,
    bt: *BluetoothBase,
    port: *exec.MsgPort,
    agent: *bluetooth.BTAgent,

    fn open(sys: *ExecBase, bt: *BluetoothBase) ?Answering {
        const port = sys.CreateMsgPort() orelse return null;
        // It shows a number, answers yes or no, and types one.
        const handle = bt.AddBTAgent(port, bluetooth.BTIO_KEYBOARDDISPLAY) orelse {
            sys.DeleteMsgPort(port);
            return null;
        };
        return .{ .sys = sys, .bt = bt, .port = port, .agent = handle };
    }

    /// The agent given back, what is still on its port replied, the port
    /// gone.
    fn close(answering: *Answering) void {
        answering.bt.RemBTAgent(answering.agent);
        while (answering.sys.GetMsg(answering.port)) |message| answering.sys.ReplyMsg(message);
        answering.sys.DeleteMsgPort(answering.port);
    }

    /// What comes to the port answered, until the pairing with `until` is
    /// over - or, without one, until CTRL-C.
    fn serve(answering: *Answering, dl: *DosBase, pin: ?[*:0]const u8, until: ?*const bluetooth.BTAddress, controller: u32) i32 {
        const sys = answering.sys;
        const mask = @as(u32, 1) << @intCast(answering.port.sig_bit);
        while (true) {
            const got = sys.Wait(mask | exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0) {
                _ = dl.PutStr(MSG_BREAK);
                return dos.RETURN_WARN;
            }
            while (sys.GetMsg(answering.port)) |message| {
                const asked: *bluetooth.BTAgentMessage = @fieldParentPtr("message", message);
                const kind = asked.kind;
                const result = asked.result;
                const address = asked.address;
                answer(dl, asked, pin, controller);
                sys.ReplyMsg(message);
                if (kind != bluetooth.BTAK_DONE) continue;
                const wanted = until orelse continue;
                if (!sameBytes(&address.bytes, &wanted.bytes)) continue;
                return if (result == 0) dos.RETURN_OK else dos.RETURN_ERROR;
            }
        }
    }
};

/// The device a message is about: its name, or its address.
fn deviceText(asked: *const bluetooth.BTAgentMessage, into: *[18]u8) [*:0]const u8 {
    if (asked.name[0] != 0) return @ptrCast(&asked.name);
    return addressText(&asked.address.bytes, into);
}

/// A question answered on the console, or what the agent is told shown.
fn answer(dl: *DosBase, asked: *bluetooth.BTAgentMessage, pin: ?[*:0]const u8, controller: u32) void {
    var shown: [18]u8 = undefined;
    const who = deviceText(asked, &shown);
    switch (asked.kind) {
        bluetooth.BTAK_CONFIRM => {
            if (asked.number != bluetooth.BT_NO_NUMBER) {
                _ = Printf(dl, "Does %s show %06u? (y/n) ", .{ who, asked.number });
            } else {
                _ = Printf(dl, "May %s pair with this machine? (y/n) ", .{who});
            }
            asked.accept = @intFromBool(yes(dl));
        },
        bluetooth.BTAK_PASSKEY => {
            _ = Printf(dl, "The passkey %s shows: ", .{who});
            const typed = numberTyped(dl);
            asked.accept = @intFromBool(typed != null);
            asked.passkey = typed orelse 0;
        },
        bluetooth.BTAK_SHOW => _ = Printf(dl, "Type %06u on %s\n", .{ asked.number, who }),
        bluetooth.BTAK_PIN => {
            var length: usize = 0;
            if (pin) |given| {
                while (length < bluetooth.BT_PIN_MOST and given[length] != 0) : (length += 1) asked.pin[length] = given[length];
            } else {
                _ = Printf(dl, "The PIN for %s: ", .{who});
                length = lineTyped(dl, &asked.pin);
            }
            asked.pin_length = @intCast(length);
            asked.accept = @intFromBool(length != 0);
        },
        bluetooth.BTAK_DONE => if (asked.result == 0) {
            _ = Printf(dl, "Paired with %s\n", .{who});
        } else {
            _ = Printf(dl, "Not paired with %s\n", .{who});
            pairFailure(dl, asked.result, controller);
        },
        else => {},
    }
}

/// A line typed on the console into `into`, without its end: its
/// length, 0 for none.
fn lineTyped(dl: *DosBase, into: []u8) usize {
    _ = dl.Flush(dl.Output());
    var typed: [64]u8 = @splat(0);
    _ = dl.FGets(dl.Input(), &typed, typed.len) orelse return 0;
    var length: usize = 0;
    while (length < typed.len and length < into.len and typed[length] != 0 and typed[length] != '\n' and typed[length] != '\r') : (length += 1) into[length] = typed[length];
    return length;
}

/// Whether the answer typed is yes.
fn yes(dl: *DosBase) bool {
    var typed: [8]u8 = @splat(0);
    const length = lineTyped(dl, &typed);
    return length != 0 and (typed[0] == 'y' or typed[0] == 'Y');
}

/// A number of up to six digits typed; null for anything else.
fn numberTyped(dl: *DosBase) ?u32 {
    var typed: [16]u8 = @splat(0);
    const length = lineTyped(dl, &typed);
    if (length == 0 or length > 6) return null;
    var value: u32 = 0;
    for (typed[0..length]) |char| {
        if (char < '0' or char > '9') return null;
        value = value * 10 + (char - '0');
    }
    return value;
}

/// The bond UNPAIR names: by the device's address, or its name; null for
/// none.
fn bondNamed(bt: *BluetoothBase, controller: u32, text: [*:0]const u8) ?bluetooth.BTAddress {
    const bytes = parseAddress(text);
    const list_of_bonds = bt.ObtainBTBonds(controller) orelse return null;
    defer bt.ReleaseBTBonds(list_of_bonds);
    var it = list_of_bonds.iterator();
    while (it.next()) |node| {
        const bond: *bluetooth.BTBond = @fieldParentPtr("node", node);
        if (bytes) |wanted| {
            if (sameBytes(&bond.address.bytes, &wanted)) return bond.address;
        } else if (bond.node.name) |name| {
            if (sameName(name, text)) return bond.address;
        }
    }
    return null;
}

/// UNPAIR: the bond ended.
fn unpair(dl: *DosBase, bt: *BluetoothBase, controller: u32, text: [*:0]const u8) i32 {
    const address = bondNamed(bt, controller, text) orelse {
        _ = Printf(dl, "%s: no bond with %s\n", .{ @as([*:0]const u8, COMMAND_NAME), text });
        return dos.RETURN_WARN;
    };
    const result = bt.UnpairBTDevice(controller, &address);
    if (result != 0) {
        _ = Printf(dl, "%s: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), callFailure(result, controller) });
        return dos.RETURN_ERROR;
    }
    var shown: [18]u8 = undefined;
    _ = Printf(dl, "Unpaired %s\n", .{addressText(&address.bytes, &shown)});
    return dos.RETURN_OK;
}

/// BONDS: every bond of the controller - or of every one.
fn showBonds(dl: *DosBase, bt: *BluetoothBase, controller: u32, with_info: bool) i32 {
    const list_of_bonds = bt.ObtainBTBonds(controller) orelse {
        _ = dl.PutStr("no memory\n");
        return dos.RETURN_FAIL;
    };
    defer bt.ReleaseBTBonds(list_of_bonds);
    var any = false;
    var it = list_of_bonds.iterator();
    while (it.next()) |node| {
        const bond: *bluetooth.BTBond = @fieldParentPtr("node", node);
        any = true;
        var text: [18]u8 = undefined;
        const le = bond.address.kind != bluetooth.BTADDR_BREDR;
        const kind: [*:0]const u8 = if (!le) "BR/EDR" else if (bond.address.kind == bluetooth.BTADDR_LE_RANDOM) "LE random" else "LE";
        const how: [*:0]const u8 = if (bond.flags & bluetooth.BTBF_LEGACY != 0) "PIN" else if (bond.flags & bluetooth.BTBF_AUTHENTICATED != 0) "confirmed" else "unconfirmed";
        _ = Printf(dl, "  %s  %-9s  %-11s", .{ addressText(&bond.address.bytes, &text), kind, how });
        const name: [*:0]const u8 = bond.node.name orelse "";
        if (name[0] != 0) _ = Printf(dl, "  %s", .{name});
        _ = dl.PutStr("\n");
        if (with_info) {
            _ = Printf(dl, "      controller %u", .{bond.controller});
            // A link this machine made is not told the device's class.
            if (bond.class_of_device != 0) _ = Printf(dl, ", class %06lx", .{@as(u64, bond.class_of_device)});
            const secure: [*:0]const u8 = if (bond.flags & bluetooth.BTBF_SECURE != 0) ", Secure Connections" else "";
            if (le) {
                const identity: [*:0]const u8 = if (bond.flags & bluetooth.BTBF_IDENTITY != 0) ", its identity kept" else "";
                _ = Printf(dl, ", a key of %u bytes%s%s\n", .{ bond.key_size, secure, identity });
            } else {
                _ = Printf(dl, ", key type %u%s\n", .{ bond.key_type, secure });
            }
        }
    }
    if (!any) _ = dl.PutStr("no bond\n");
    return dos.RETURN_OK;
}

// --- the services -----------------------------------------------------------------

/// The device SERVICES names, over BR/EDR: its address, or the name a
/// scan heard - one heard over LE alone as it was heard; null for
/// neither.
fn brEdrDevice(bt: *BluetoothBase, controller: u32, text: [*:0]const u8, argv: *const [arg_count]usize) ?bluetooth.BTAddress {
    if (parseAddress(text)) |bytes| {
        if (argv[arg_le] == 0 and argv[arg_random] == 0) return .{ .bytes = bytes };
    }
    const devices = bt.ObtainBTDevices(controller) orelse return null;
    defer bt.ReleaseBTDevices(devices);
    var it = devices.iterator();
    while (it.next()) |node| {
        const found: *bluetooth.BTDevice = @fieldParentPtr("node", node);
        const name = found.node.name orelse continue;
        if (!sameName(name, text)) continue;
        if (found.flags & bluetooth.BTDF_BREDR != 0) return .{ .bytes = found.address.bytes };
        return found.address;
    }
    return deviceNamed(bt, controller, text, argv);
}

/// SERVICES: what the device offers, a service on a line.
fn services(dl: *DosBase, bt: *BluetoothBase, controller: u32, text: [*:0]const u8, argv: *const [arg_count]usize) i32 {
    const address = brEdrDevice(bt, controller, text, argv) orelse {
        _ = Printf(dl, "%s: no device %s (an address, or a name a SCAN heard)\n", .{ @as([*:0]const u8, COMMAND_NAME), text });
        return dos.RETURN_ERROR;
    };
    if (address.kind != bluetooth.BTADDR_BREDR) {
        _ = Printf(dl, "%s: that device was heard over LE alone, whose services are not asked for yet\n", .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_ERROR;
    }
    var shown: [18]u8 = undefined;
    _ = Printf(dl, "Asking %s for its services\n", .{addressText(&address.bytes, &shown)});
    var found: ?*exec.List = null;
    const result = bt.ObtainBTServices(controller, &address, &found);
    if (result != 0) {
        const reason: ?[*:0]const u8 = switch (result) {
            bluetooth.BTERR_BUSY => "the controller is asking another device",
            bluetooth.BTERR_PROTOCOL => "the device's answer was an error, or made no sense",
            bluetooth.BTERR_NOMEM => "no memory, or more services than 32 KiB hold",
            bluetooth.BTERR_UNSUPPORTED => "the device does not say what it offers",
            bluetooth.BTERR_REFUSED => "the device refused the question",
            else => null,
        };
        if (reason) |why| {
            _ = Printf(dl, "%s: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), why });
        } else linkFailure(dl, result, controller);
        return dos.RETURN_ERROR;
    }
    defer bt.ReleaseBTServices(found);
    const with_info = argv[arg_info] != 0;
    var any = false;
    var it = found.?.iterator();
    while (it.next()) |node| {
        const service: *bluetooth.BTService = @fieldParentPtr("node", node);
        any = true;
        serviceLine(dl, service);
        if (with_info) serviceInfo(dl, service);
    }
    if (!any) _ = dl.PutStr("no service\n");
    return dos.RETURN_OK;
}

/// One service on a line: what it is - its name, else its UUID, as
/// `SCAN INFO` writes one - where it is reached, its own name.
fn serviceLine(dl: *DosBase, service: *const bluetooth.BTService) void {
    if (serviceName(service.class16)) |what| {
        _ = Printf(dl, "  %-28s", .{what});
    } else if (service.class16 != 0) {
        _ = Printf(dl, "  service %04lx%-16s", .{ @as(u64, service.class16), @as([*:0]const u8, "") });
    } else {
        var uuid_text: [37]u8 = undefined;
        var sent_order: [16]u8 = undefined;
        for (service.class.bytes, 0..) |byte, index| sent_order[15 - index] = byte;
        _ = Printf(dl, "  %-28s", .{uuidText(&sent_order, &uuid_text)});
    }
    if (service.rfcomm_channel != 0) {
        _ = Printf(dl, "  RFCOMM %-4u", .{@as(u32, service.rfcomm_channel)});
    } else if (service.psm != 0) {
        _ = Printf(dl, "  PSM %-7u", .{@as(u32, service.psm)});
    } else {
        _ = dl.PutStr("             ");
    }
    const name: [*:0]const u8 = service.node.name orelse "";
    if (name[0] != 0) _ = Printf(dl, "  %s", .{name});
    _ = dl.PutStr("\n");
}

/// With INFO: its profile and the profile's version, and its record.
fn serviceInfo(dl: *DosBase, service: *const bluetooth.BTService) void {
    const major: u32 = service.profile_version >> 8;
    const minor: u32 = service.profile_version & 0xFF;
    if (serviceName(service.profile16)) |profile| {
        _ = Printf(dl, "      %s %u.%u,", .{ profile, major, minor });
    } else if (service.profile16 != 0) {
        _ = Printf(dl, "      profile %04lx %u.%u,", .{ @as(u64, service.profile16), major, minor });
    } else {
        _ = dl.PutStr("      no profile,");
    }
    _ = Printf(dl, " record %08lx, %u bytes\n", .{ @as(u64, service.handle), service.record_length });
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

/// What the services most often offered are, by their 16-bit UUID - the
/// classes and profiles an SDP server lists, and LE's services.
fn serviceName(uuid: u16) ?[*:0]const u8 {
    return switch (uuid) {
        0x1000 => "service discovery",
        0x1101 => "serial port",
        0x1103 => "dial-up networking",
        0x1104 => "synchronization",
        0x1105 => "object push",
        0x1106 => "file transfer",
        0x1108 => "headset",
        0x110A => "audio source",
        0x110B => "audio sink",
        0x110C => "remote control target",
        0x110D => "advanced audio",
        0x110E => "remote control",
        0x110F => "remote control controller",
        0x1112 => "headset audio gateway",
        0x1115 => "network user",
        0x1116 => "network access point",
        0x1117 => "group network",
        0x111E => "hands-free",
        0x111F => "hands-free audio gateway",
        0x1124 => "keyboard, mouse or game controller",
        0x112D => "SIM access",
        0x112E => "phone book client",
        0x112F => "phone book",
        0x1130 => "phone book access",
        0x1131 => "headset",
        0x1132 => "messages",
        0x1133 => "message notifications",
        0x1134 => "message access",
        0x1200 => "device identification",
        0x1203 => "generic audio",
        0x1800 => "generic access",
        0x1801 => "generic attribute",
        0x180A => "device information",
        0x180D => "heart rate",
        0x180F => "battery",
        0x1812 => "keyboard, mouse or game controller over LE",
        else => null,
    };
}

export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
