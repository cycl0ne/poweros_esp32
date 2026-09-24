// SPDX-License-Identifier: MPL-2.0
//! residents: the ROM tags exec found, by priority, with each module's
//! size as the build measured it (tools/ressize.zig) and the functions in
//! its jump table.

const sdk = @import("sdk");
const exec = @import("../../exec.zig");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const layout = @import("../../../../../arch/esp32s3/layout.zig");

pub const name = "residents";
pub const usage = "residents";
pub const help =
    \\  residents            the resident modules (ROM tags), by priority
    \\
;

pub fn run(shell: *Shell, _: *Args) anyerror!void {
    shell.print("romtag      name                 ver type       pri    code   data   size  vec  flags\n", .{});
    const table = shell.base.res_modules orelse return;
    var i: usize = 0;
    var total: layout.ResidentSize = .{ .tag = 0, .code = 0, .data = 0 };
    var total_vectors: u32 = 0;
    while (table[i]) |tag| : (i += 1) {
        var flag_buf: [48]u8 = undefined;
        var vec_buf: [8]u8 = undefined;
        // Measured by the build: code, and data with the tag.
        const size = layout.residentSize(@intFromPtr(tag)) orelse layout.ResidentSize{ .tag = 0, .code = 0, .data = 0 };
        total.code += size.code;
        total.data += size.data;
        const vectors = residentVectors(shell, tag);
        total_vectors += vectors orelse 0;
        const vec_text: [*:0]const u8 = if (vectors) |n| decimal(shell, &vec_buf, n) else "-";
        shell.print("0x%08x  %-20s %3d %-10s %4d  %6d %6d %6d  %3s  %s\n", .{
            @intFromPtr(tag), tag.name,  tag.version,           _shell.enumName(sdk.exec.NodeType, tag.type), tag.pri,
            size.code,        size.data, size.code + size.data, vec_text,                                     residentFlags(tag.flags, &flag_buf),
        });
    }
    shell.print("%-50s  %6d %6d %6d  %3d\n", .{ "total", total.code, total.data, total.code + total.data, total_vectors });
}

/// rt_Flags as words.
fn residentFlags(flags: u8, buf: []u8) [:0]const u8 {
    const names = [_]struct { u8, []const u8 }{
        .{ sdk.exec.RTF_COLDSTART, "coldstart" },
        .{ sdk.exec.RTF_SINGLETASK, "singletask" },
        .{ sdk.exec.RTF_AFTERDOS, "afterdos" },
        .{ sdk.exec.RTF_AUTOINIT, "autoinit" },
    };
    var n: usize = 0;
    for (names) |entry| {
        if (flags & entry[0] == 0 or n + entry[1].len + 2 > buf.len) continue;
        @memcpy(buf[n..][0..entry[1].len], entry[1]);
        n += entry[1].len;
        buf[n] = ' ';
        n += 1;
    }
    buf[n] = 0;
    return buf[0..n :0];
}

/// How many functions a resident's jump table has: an auto-init tag's
/// InitTable says; for one with its own init, the library or device it
/// made (its neg_size). Null if it makes none.
fn residentVectors(shell: *Shell, tag: *const sdk.exec.Resident) ?u32 {
    if (tag.flags & sdk.exec.RTF_AUTOINIT != 0) {
        const init_table: *const sdk.exec.InitTable = @ptrCast(@alignCast(tag.init orelse return null));
        return init_table.vector_count;
    }
    const list: *sdk.exec.List = switch (tag.type) {
        .library => &shell.base.lib_list,
        .device => &shell.base.device_list,
        else => return null,
    };
    const sys = shell.base.iface();
    sys.Forbid();
    defer sys.Permit();
    const node = sys.FindName(list, tag.name) orelse return null;
    const lib: *sdk.exec.Library = @fieldParentPtr("node", node);
    return lib.neg_size / sdk.exec.slot_size;
}

/// `n` as decimal text in `buffer`, with exec's RawDoFmt.
fn decimal(shell: *Shell, buffer: []u8, n: u32) [*:0]const u8 {
    const stream = sdk.exec.fmtStream(.{n});
    _ = shell.base.iface().RawDoFmt("%d", &stream, null, buffer.ptr);
    return @ptrCast(buffer.ptr);
}
