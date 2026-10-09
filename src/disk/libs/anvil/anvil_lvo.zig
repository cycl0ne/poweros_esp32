// SPDX-License-Identifier: MIT
//! anvil.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const intuition = sdk.intuition;
const icon = sdk.icon;
const anvil = sdk.anvil;
const utility = sdk.utility;
const vec = exec.vec;
const AnvilBase = @import("anvil_base.zig").AnvilBase;
const anvil_init = @import("anvil_init.zig");

const StartAnvil = @import("start/startanvil.zig").StartAnvil;
const Information = @import("info/information.zig").Information;
const AddAppWindow = @import("app/addappwindow.zig").AddAppWindow;
const RemoveAppWindow = @import("app/removeappwindow.zig").RemoveAppWindow;
const AddAppIcon = @import("app/addappicon.zig").AddAppIcon;
const RemoveAppIcon = @import("app/removeappicon.zig").RemoveAppIcon;
const AddAppMenuItem = @import("app/addappmenuitem.zig").AddAppMenuItem;
const RemoveAppMenuItem = @import("app/removeappmenuitem.zig").RemoveAppMenuItem;

/// anvil.library's interface, as the SDK generates it from
/// sdk/fd/anvil_lib.fd.
const interface = sdk.interface.anvil;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("anvil.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "anvil.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("start/startanvil.zig"),
    @embedFile("info/information.zig"),
    @embedFile("app/addappwindow.zig"),
    @embedFile("app/removeappwindow.zig"),
    @embedFile("app/addappicon.zig"),
    @embedFile("app/removeappicon.zig"),
    @embedFile("app/addappmenuitem.zig"),
    @embedFile("app/removeappmenuitem.zig"),
};

fn lvoStartAnvil(base: *AnvilBase, tags: ?[*]const utility.TagItem) callconv(.c) bool {
    return StartAnvil(base, tags);
}

fn lvoInformation(base: *AnvilBase, lock: ?*dos.FileLock, name: [*:0]const u8, screen: ?*intuition.Screen) callconv(.c) bool {
    return Information(base, lock, name, screen);
}

fn lvoAddAppWindow(base: *AnvilBase, id: u32, user_data: usize, window: *intuition.Window, port: *exec.MsgPort, tags: ?[*]const utility.TagItem) callconv(.c) ?*anvil.AppWindow {
    return AddAppWindow(base, id, user_data, window, port, tags);
}

fn lvoRemoveAppWindow(base: *AnvilBase, app: ?*anvil.AppWindow) callconv(.c) bool {
    return RemoveAppWindow(base, app);
}

fn lvoAddAppIcon(base: *AnvilBase, id: u32, user_data: usize, text: [*:0]const u8, port: *exec.MsgPort, object: *const icon.DiskObject, tags: ?[*]const utility.TagItem) callconv(.c) ?*anvil.AppIcon {
    return AddAppIcon(base, id, user_data, text, port, object, tags);
}

fn lvoRemoveAppIcon(base: *AnvilBase, app: ?*anvil.AppIcon) callconv(.c) bool {
    return RemoveAppIcon(base, app);
}

fn lvoAddAppMenuItem(base: *AnvilBase, id: u32, user_data: usize, text: [*:0]const u8, port: *exec.MsgPort, tags: ?[*]const utility.TagItem) callconv(.c) ?*anvil.AppMenuItem {
    return AddAppMenuItem(base, id, user_data, text, port, tags);
}

fn lvoRemoveAppMenuItem(base: *AnvilBase, app: ?*anvil.AppMenuItem) callconv(.c) bool {
    return RemoveAppMenuItem(base, app);
}

/// The standard four, then the library's own in .fd order.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(anvil_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoStartAnvil),
    vec(lvoInformation),
    vec(lvoAddAppWindow),
    vec(lvoRemoveAppWindow),
    vec(lvoAddAppIcon),
    vec(lvoRemoveAppIcon),
    vec(lvoAddAppMenuItem),
    vec(lvoRemoveAppMenuItem),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: the standard four, then this library's own" {
    try testing.expectEqual(@as(usize, 4 + @typeInfo(LVO).@"struct".decls.len), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("anvil_lvo.zig"), LVO, &.{});
}
