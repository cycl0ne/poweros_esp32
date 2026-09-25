// SPDX-License-Identifier: MIT
//! Online: a network interface's device put back on its link. Built
//! against the SDK only.
//!
//!   Online NAME/M,ALL/S,QUIET/S
//!
//! Each NAME is an interface, eth0 or ETH0 alike; ALL is every one but
//! lo0. The interface is up again with the address it had, and an
//! address from DHCP has its lease renewed.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Online";
const VERSION_STRING = "\x00$VER: Online 1.0 (25.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "NAME/M,ALL/S,QUIET/S";
const arg_name = 0;
const arg_all = 1;
const arg_quiet = 2;

/// The state this command puts an interface in, and what it says then.
const state = bsd.IFSTATE_UP;
const MSG_DONE = "%s is on line\n";

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_FAILED = "%s: %s: %s\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const quiet = argv[arg_quiet] != 0;

    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        if (!quiet) _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, bsd.SOCKETNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);

    var result: i32 = dos.RETURN_OK;
    if (argv[arg_all] != 0) {
        const list = sb.ObtainInterfaceList() orelse return dos.RETURN_FAIL;
        defer sb.ReleaseInterfaceList(list);
        var it = list.iterator();
        while (it.next()) |node| {
            const name = node.name.?;
            if (name[0] == 'l' and name[1] == 'o' and name[2] == '0' and name[3] == 0) continue;
            result = @max(result, change(dl, sb, name, quiet));
        }
    } else if (argv[arg_name] != 0) {
        const names: [*]const ?[*:0]const u8 = @ptrFromInt(argv[arg_name]);
        var index: usize = 0;
        while (names[index]) |name| : (index += 1) result = @max(result, change(dl, sb, name, quiet));
    } else {
        _ = dl.PrintFault(dos.ERROR_REQUIRED_ARG_MISSING, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    return result;
}

fn change(dl: *DosBase, sb: *SocketBase, name: [*:0]const u8, quiet: bool) i32 {
    var lower: [bsd.IFNAMSIZ:0]u8 = @splat(0);
    var at: usize = 0;
    while (name[at] != 0 and at + 1 < lower.len) : (at += 1) {
        const char = name[at];
        lower[at] = if (char >= 'A' and char <= 'Z') char + 32 else char;
    }
    const interface: [*:0]const u8 = @ptrCast(&lower);
    const tags = [_]TagItem{ .{ .tag = bsd.IFA_State, .data = state }, .{} };
    if (sb.ConfigureInterfaceTagList(interface, &tags) < 0) {
        const why: [*:0]const u8 = switch (sb.Errno()) {
            bsd.ENXIO => "no such interface",
            bsd.EINVAL => "not on a device",
            else => "the device refused",
        };
        if (!quiet) _ = Printf(dl, MSG_FAILED, .{ COMMAND_NAME, interface, why });
        return dos.RETURN_WARN;
    }
    if (!quiet) _ = Printf(dl, MSG_DONE, .{interface});
    return dos.RETURN_OK;
}
