// SPDX-License-Identifier: MIT
//! Bluetooth: the system's Bluetooth controllers. Built against the SDK
//! only.
//!
//!   Bluetooth [INFO/S]
//!
//!   Bluetooth          each controller on a line: its number, its
//!                      address, whether it is up, and its device
//!   Bluetooth INFO     and what it is: the device and unit, the chip and
//!                      the firmware it was given, the versions of its
//!                      HCI and link manager and who made it, its
//!                      buffers, what it can do, its name and class
//!
//! The controllers are bluetooth.library's: those it was given by their
//! devices and brought up (ObtainBTControllers).

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const hcidev = sdk.devices.hci;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const BluetoothBase = sdk.interface.bluetooth.BluetoothBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Bluetooth";
const VERSION_STRING = "\x00$VER: Bluetooth 1.0 (22.11.2026)\r\n";

const template = "INFO/S";
const arg_info = 0;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [1]usize = @splat(0);
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

    const list = bt.ObtainBTControllers() orelse {
        _ = dl.PutStr("no memory\n");
        return dos.RETURN_FAIL;
    };
    defer bt.ReleaseBTControllers(list);
    var any = false;
    var it = list.iterator();
    while (it.next()) |node| {
        const controller: *bluetooth.BTController = @fieldParentPtr("node", node);
        if (argv[arg_info] != 0 and any) _ = dl.PutStr("\n");
        any = true;
        line(dl, controller);
        if (argv[arg_info] != 0) info(dl, controller);
    }
    if (!any) _ = dl.PutStr("no Bluetooth controller\n");
    return dos.RETURN_OK;
}

/// Its number, address, state and device.
fn line(dl: *DosBase, controller: *const bluetooth.BTController) void {
    const address = controller.address.bytes;
    _ = Printf(dl, "%u: %02X:%02X:%02X:%02X:%02X:%02X  %s", .{
        controller.id,
        @as(u32, address[5]),
        @as(u32, address[4]),
        @as(u32, address[3]),
        @as(u32, address[2]),
        @as(u32, address[1]),
        @as(u32, address[0]),
        stateName(controller.state),
    });
    if (controller.state == bluetooth.BTCS_FAILED) _ = Printf(dl, " (%s)", .{failureName(controller.failure)});
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

/// What a version number is called.
fn versionName(version: u8) [*:0]const u8 {
    const names = [_][*:0]const u8{ "1.0b", "1.1", "1.2", "2.0", "2.1", "3.0", "4.0", "4.1", "4.2", "5.0", "5.1", "5.2", "5.3", "5.4", "6.0" };
    return if (version < names.len) names[version] else "later than 6.0";
}

/// A few of the makers' company identifiers.
fn makerName(company: u16) ?[*:0]const u8 {
    return switch (company) {
        2 => "Intel",
        10 => "Qualcomm (CSR)",
        15 => "Broadcom",
        29 => "Qualcomm",
        70 => "MediaTek",
        93 => "Realtek",
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
    _ = Printf(dl, "  bus         %s\n", .{@as([*:0]const u8, switch (controller.bus) {
        hcidev.HCIBUS_USB => "USB",
        hcidev.HCIBUS_UART => "UART",
        else => "?",
    })});
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

export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
