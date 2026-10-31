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
pub const rta = @import("libs/rta/rta.zig");
pub const expansion = @import("libs/expansion/expansion.zig");
pub const graphics = @import("libs/graphics/graphics.zig");
pub const layers = @import("libs/layers/layers.zig");
pub const intuition = @import("libs/intuition/intuition.zig");
pub const keymap = @import("libs/keymap/keymap.zig");
pub const console = @import("libs/console/console.zig");
pub const gadgets = @import("libs/gadgets/gadgets.zig");
/// The dock's docklets: what every one answers, and the class library
/// that makes one.
pub const docklets = @import("libs/docklets/docklets.zig");
/// The image classes on the disk: pictures drawn to any size, the
/// command images a tool bar has and a player's controls.
pub const images = @import("libs/images/images.zig");
pub const bsdsocket = @import("libs/bsdsocket/bsdsocket.zig");
pub const crypto = @import("libs/crypto/crypto.zig");
pub const compression = @import("libs/compression/compression.zig");
pub const http = @import("libs/http/http.zig");
/// LZ4's block format (sdk/libs/lz4).
pub const lz4 = @import("libs/lz4/lz4.zig");
pub const diskfont = @import("libs/diskfont/diskfont.zig");
/// The system's settings as files (ENV:Sys, ENVARC:Sys).
pub const prefs = @import("libs/prefs/prefs.zig");
pub const truetype = @import("libs/truetype/truetype.zig");
pub const asl = @import("libs/asl/asl.zig");
pub const iffparse = @import("libs/iffparse/iffparse.zig");
/// Programs that watch the input stream and act on it, through
/// commodities.library.
pub const commodities = @import("libs/commodities/commodities.zig");
pub const datatypes = @import("libs/datatypes/datatypes.zig");
pub const motion = @import("libs/motion/motion.zig");
/// A disk's RigidDiskBlock and partitions, through rdb.library.
pub const rdb = @import("libs/rdb/rdb.zig");
/// TLS sessions over sockets, through tls.library.
pub const tls = @import("libs/tls/tls.zig");
/// Modbus over RTU and TCP, client and server, through modbus.library.
pub const modbus = @import("libs/modbus/modbus.zig");
/// Sound decoded from WAV and MP3 into 16-bit samples, through
/// audiocodec.library.
pub const audiocodec = @import("libs/audiocodec/audiocodec.zig");
/// Container files - MP4 - their tracks and packets, through
/// media.library.
pub const media = @import("libs/media/media.zig");
/// Films - their pictures as frames, their sound as samples - through
/// videocodec.library.
pub const videocodec = @import("libs/videocodec/videocodec.zig");
/// A codec module's structures: a decoder of pictures in LIBS:codecs/,
/// which videocodec.library chooses for a film.
pub const vcodec = @import("libs/videocodec/vcodec.zig");
/// What the Player that runs plays, asked at its public port.
pub const player = @import("libs/player/player.zig");
/// A packet filter on the stack's packet hooks, through filter.library.
pub const filter = @import("libs/filter/filter.zig");
/// A Wi-Fi station's WPA2-Personal keys and handshakes, through
/// wpa.library.
pub const wpa = @import("libs/wpa/wpa.zig");
/// Icons: the picture a file is shown with and its fields, through
/// icon.library.
pub const icon = @import("libs/icon/icon.zig");
/// anvil.library: the desktop.
pub const anvil = @import("libs/anvil/anvil.zig");
/// usb.library: the USB buses, their devices, pipes to their endpoints.
pub const usb = @import("libs/usb/usb.zig");
/// The machine's PCI functions, through pci.library.
pub const pci = @import("libs/pci/pci.zig");
/// Three-dimensional drawing on the machine's cores, through facet.library.
pub const facet = @import("libs/facet/facet.zig");
/// Countries, languages and a program's strings in them, through
/// locale.library.
pub const locale = @import("libs/locale/locale.zig");
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

// --- 64-bit fields in constants -------------------------------------------
//
// A constant the compiler builds from fields - a default value, what
// `x.* = .{}` copies - lays a structure out by the fields' own alignment:
// a 64-bit number's is 8, whatever its field says. A structure whose 64-bit
// fields all sit on 8-byte places, and whose size is a multiple of 8, comes
// out 8-aligned there, though Zig aligns it to 4 and places it by 4. Inside
// another structure at an offset that is not a multiple of 8, the constant
// puts it 4 bytes further on than the code reads it, and every field after
// it comes out of the default one word off: a -1 that belongs to one field
// lands on the next. A structure with a 64-bit field off its 8-byte place,
// or with a size its fields do not divide, is built byte by byte instead,
// and comes out where the code reads it - and so does anything inside it.
//
// So every structure the SDK declares, and every one the program or module
// being built declares in public - `@import("root")`, the kernel's
// `rom_modules` among it - is walked through all its fields, and one that
// holds such a structure at such an offset is refused.

comptime {
    const builtin = @import("builtin");
    const arch = builtin.cpu.arch;
    const machine = arch == .aarch64 and builtin.os.tag == .freestanding;
    if (arch == .xtensa or arch == .riscv32 or arch == .riscv64 or machine) {
        @setEvalBranchQuota(20_000_000);
        checkConstants(@This(), 0);
        checkConstants(@import("root"), 0);
    }
}

/// `Namespace`'s fields, then its public declarations: the types among
/// them, and the lists of types (`rom_modules`), down to a few levels.
fn checkConstants(comptime Namespace: type, comptime depth: u32) void {
    if (depth > 5 or outsideTree(Namespace)) return;
    checkFields(Namespace);
    const decls = switch (@typeInfo(Namespace)) {
        .@"struct" => |s| s.decls,
        .@"union" => |u| u.decls,
        .@"enum" => |e| e.decls,
        .@"opaque" => |o| o.decls,
        else => return,
    };
    for (decls) |d| {
        const Decl = @TypeOf(@field(Namespace, d.name));
        if (Decl == type) {
            checkConstants(@field(Namespace, d.name), depth + 1);
        } else if (isListOfTypes(Decl)) {
            checkList(@field(Namespace, d.name), depth + 1);
        }
    }
}

fn checkList(comptime list: anytype, comptime depth: u32) void {
    for (@typeInfo(@TypeOf(list)).@"struct".fields) |field| {
        const item = @field(list, field.name);
        if (@TypeOf(item) == type) {
            checkConstants(item, depth);
        } else if (isListOfTypes(@TypeOf(item))) {
            checkList(item, depth);
        }
    }
}

fn isListOfTypes(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.is_tuple,
        else => false,
    };
}

/// The language's own library and the compiler's are not ours to check,
/// and the chip's registers are addresses, with members only one chip has.
fn outsideTree(comptime T: type) bool {
    const name = @typeName(T);
    for ([_][]const u8{ "std.", "builtin.", "hardware." }) |prefix| {
        if (name.len >= prefix.len and @import("std").mem.eql(u8, name[0..prefix.len], prefix)) return true;
    }
    return false;
}

/// A structure, and everything it holds, refused if it places a structure
/// that a constant aligns to 8 at an offset that is not a multiple of 8.
fn checkFields(comptime T: type) void {
    if (comptimeOnly(T)) return;
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (s.layout == .@"packed") return;
            const exact = builtByteWise(T);
            for (s.fields) |field| {
                if (field.is_comptime) continue;
                checkFields(field.type);
                if (exact or !isAggregate(field.type)) continue;
                const offset = @offsetOf(T, field.name);
                if (constantAlign(field.type) == 8 and offset % 8 != 0) {
                    @compileError(@typeName(T) ++ "." ++ field.name ++ " is at offset " ++
                        @import("std").fmt.comptimePrint("{d}", .{offset}) ++ ", and " ++
                        @typeName(field.type) ++ " has its 64-bit fields on 8-byte places, " ++
                        "so a default value puts it 4 bytes further on: give it an 8-byte place (see sdk/sdk.zig)");
                }
            }
        },
        .@"union" => |u| for (u.fields) |field| checkFields(field.type),
        .array => |a| checkFields(a.child),
        .optional => |o| checkFields(o.child),
        else => {},
    }
}

/// A type that exists only while compiling - a list of types, a class's
/// description - and has no layout. Pointers are not followed: one to a
/// structure is a word whatever the structure holds.
fn comptimeOnly(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .type, .comptime_int, .comptime_float, .enum_literal, .null, .undefined, .@"fn", .noreturn => true,
        .@"struct" => |s| for (s.fields) |field| {
            if (!field.is_comptime and comptimeOnly(field.type)) break true;
        } else false,
        .@"union" => |u| for (u.fields) |field| {
            if (comptimeOnly(field.type)) break true;
        } else false,
        .array => |a| comptimeOnly(a.child),
        .optional => |o| comptimeOnly(o.child),
        .pointer => |p| switch (@typeInfo(p.child)) {
            .type, .comptime_int, .comptime_float, .enum_literal => true,
            else => false,
        },
        else => false,
    };
}

/// A structure or a union, or a row or an optional of them: what a
/// constant places by its own alignment rather than its fields' sizes.
fn isAggregate(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.layout != .@"packed",
        .@"union" => true,
        .array => |a| isAggregate(a.child),
        .optional => |o| isAggregate(o.child),
        else => false,
    };
}

/// The alignment a constant gives a type: a number's natural one,
/// whatever its field says; a structure's, the largest of its fields' - or
/// 1 when it is built byte by byte.
fn constantAlign(comptime T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .int, .float => naturalAlign(@sizeOf(T)),
        .@"enum" => |e| constantAlign(e.tag_type),
        .array => |a| constantAlign(a.child),
        .@"struct" => |s| switch (s.layout) {
            .@"packed" => constantAlign(s.backing_integer.?),
            else => if (builtByteWise(T)) 1 else most: {
                var most = 1;
                for (s.fields) |field| {
                    if (!field.is_comptime) most = @max(most, constantAlign(field.type));
                }
                break :most most;
            },
        },
        .@"union" => |u| most: {
            var most = 1;
            for (u.fields) |field| most = @max(most, constantAlign(field.type));
            break :most most;
        },
        .optional => |o| if (@sizeOf(T) == @sizeOf(o.child)) @alignOf(T) else constantAlign(o.child),
        else => @alignOf(T),
    };
}

/// Whether a constant of the structure is built byte by byte: a field the
/// compiler sees off its alignment - a number at an offset that is not a
/// multiple of its size, as a 64-bit field `align(4)` on a 4-byte place -
/// or a size its fields' alignment does not divide. A structure among the
/// fields counts with Zig's own alignment of it, which is where the 8 a
/// constant gives it goes unseen.
fn builtByteWise(comptime T: type) bool {
    var most = 1;
    for (@typeInfo(T).@"struct".fields) |field| {
        if (field.is_comptime) continue;
        const seen = seenAlign(field.type);
        most = @max(most, seen);
        if (@offsetOf(T, field.name) % seen != 0) return true;
    }
    return @sizeOf(T) % most != 0;
}

fn seenAlign(comptime T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union" => @alignOf(T),
        .array => |a| seenAlign(a.child),
        else => constantAlign(T),
    };
}

fn naturalAlign(comptime size: comptime_int) comptime_int {
    return if (size >= 8) 8 else if (size >= 4) 4 else if (size >= 2) 2 else 1;
}
