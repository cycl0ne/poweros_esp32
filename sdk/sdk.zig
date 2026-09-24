// SPDX-License-Identifier: MIT
//! The SDK: what programs, libraries and devices build against. It is the
//! ABI and holds nothing of the kernel: the system's structures and
//! constants, laid out as the system is (`libs/`, `devices/`, `resources/`,
//! `hardware/`), and the libraries' jump tables (`interface/`). The kernel
//! builds against it too, so the implementation can't drift away from it.
//!
//!   const sdk = @import("sdk");
//!   const exec = sdk.exec; // types and constants
//!   const ExecBase = sdk.interface.exec.ExecBase; // SysBase and its functions
//!
//! `release.zig` is the one place the system's own name and release number
//! are written down.

pub const release = @import("release.zig");
pub const exec = @import("libs/exec/exec.zig");
pub const utility = @import("libs/utility/utility.zig");
pub const devices = @import("devices/devices.zig");
pub const dos = @import("libs/dos/dos.zig");
pub const resources = @import("resources/resources.zig");
pub const hardware = @import("hardware/hardware.zig");
pub const rtg = @import("libs/rtg/rtg.zig");
pub const expansion = @import("libs/expansion/expansion.zig");
pub const graphics = @import("libs/graphics/graphics.zig");
pub const layers = @import("libs/layers/layers.zig");
pub const intuition = @import("libs/intuition/intuition.zig");
pub const keymap = @import("libs/keymap/keymap.zig");
pub const console = @import("libs/console/console.zig");
pub const interface = @import("interface/interface.zig");

// --- alignment ------------------------------------------------------------
//
// Every structure of the SDK keeps to 4-byte alignment on the chip, 64-bit
// fields included (`align(4)`). The compiler moves the stack pointer by
// exactly the bytes of a call's stack arguments, so a call with an odd
// number of them - seven, nine or eleven in all - leaves everything it
// calls 4 bytes off an 8-byte boundary, and a structure that wanted 8 would
// sit where ReleaseSafe's `@alignCast` refuses it. The chip itself never
// needs more than 4: it has no 64-bit loads.

/// Records whose layout is the disk's and must not change: never cast from
/// a pointer onto the stack, only copied.
const fixed_layouts = [_]type{dos.flashfs.SegmentHeader};

comptime {
    if (@import("builtin").cpu.arch == .xtensa) {
        @setEvalBranchQuota(1_000_000);
        checkAlignment(@This(), 0);
    }
}

fn checkAlignment(comptime Namespace: type, comptime depth: u32) void {
    if (depth > 4) return;
    for (@typeInfo(Namespace).@"struct".decls) |d| {
        const value = @field(Namespace, d.name);
        if (@TypeOf(value) != type) continue;
        switch (@typeInfo(value)) {
            .@"struct" => |s| {
                if (s.layout == .@"extern" and @alignOf(value) > 4 and !isFixed(value)) {
                    @compileError(@typeName(value) ++ " is " ++ @import("std").fmt.comptimePrint("{d}", .{@alignOf(value)}) ++
                        "-byte aligned: give its 64-bit fields align(4) (see sdk/sdk.zig)");
                }
                checkAlignment(value, depth + 1);
            },
            else => {},
        }
    }
}

fn isFixed(comptime T: type) bool {
    for (fixed_layouts) |fixed| {
        if (T == fixed) return true;
    }
    return false;
}
