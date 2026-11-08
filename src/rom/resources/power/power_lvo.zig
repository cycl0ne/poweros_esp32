// SPDX-License-Identifier: MPL-2.0
//! power.resource's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const power = sdk.resources.power;
const vec = exec.vec;
const PowerBase = @import("power_base.zig").PowerBase;
const PowerAbilities = @import("machine/powerabilities.zig").PowerAbilities;
const PowerOff = @import("machine/poweroff.zig").PowerOff;
const AddPowerNotify = @import("notify/addpowernotify.zig").AddPowerNotify;
const RemPowerNotify = @import("notify/rempowernotify.zig").RemPowerNotify;

/// power.resource's interface, as the SDK generates it from
/// sdk/fd/power_lib.fd.
const interface = sdk.interface.power;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("power.resource: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "power.resource", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("machine/powerabilities.zig"),
    @embedFile("machine/poweroff.zig"),
    @embedFile("notify/addpowernotify.zig"),
    @embedFile("notify/rempowernotify.zig"),
};

fn lvoPowerAbilities(pb: *PowerBase) callconv(.c) u32 {
    return PowerAbilities(pb);
}
fn lvoPowerOff(pb: *PowerBase) callconv(.c) void {
    PowerOff(pb);
}
fn lvoAddPowerNotify(pb: *PowerBase, task: *exec.Task, signals: u32) callconv(.c) ?*power.PowerNotify {
    return AddPowerNotify(pb, task, signals);
}
fn lvoRemPowerNotify(pb: *PowerBase, notify: ?*power.PowerNotify) callconv(.c) void {
    RemPowerNotify(pb, notify);
}

/// The jump table, in slot order: a resource has no standard vectors, so
/// its first function is in the first slot.
pub const vectors = [_]*const anyopaque{
    vec(lvoPowerAbilities),
    vec(lvoPowerOff),
    vec(lvoAddPowerNotify),
    vec(lvoRemPowerNotify),
};
