// SPDX-License-Identifier: MIT
//! Resolve: the addresses a name has, or the name an address has. Built
//! against the SDK only.
//!
//!   Resolve NAME/A
//!
//! A name is looked up as GetHostByName looks it up - the hosts file, the
//! cache, the name servers - and every address it has is printed; an
//! address, as dotted text, is looked up the other way.

const sdk = @import("sdk");
const dos = sdk.dos;
const bsd = sdk.bsdsocket;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Resolve";
const VERSION_STRING = "\x00$VER: Resolve 1.0 (26.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "NAME/A";

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_ADDRESS = "%s has address %s\n";
const MSG_NAME = "%s is %s\n";
const MSG_FAILED = "%s: %s\n";

fn reason(h_errno: i32) [*:0]const u8 {
    return switch (h_errno) {
        bsd.HOST_NOT_FOUND => "no such name",
        bsd.NO_DATA => "the name has no address",
        bsd.TRY_AGAIN => "no answer from the name servers",
        bsd.NO_RECOVERY => "no name server to ask",
        else => "not found",
    };
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const name: [*:0]const u8 = @ptrFromInt(argv[0]);

    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, bsd.SOCKETNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);

    const address = sb.Inet_Addr(name);
    if (address != bsd.INADDR_NONE) {
        const host = sb.GetHostByAddr(&address, 4, bsd.AF_INET) orelse return failed(dl, sb, name);
        _ = Printf(dl, MSG_NAME, .{ name, @as([*:0]const u8, host.h_name.?) });
        return dos.RETURN_OK;
    }
    const host = sb.GetHostByName(name) orelse return failed(dl, sb, name);
    const list = host.h_addr_list.?;
    var index: usize = 0;
    while (list[index]) |bytes| : (index += 1) {
        const value = @as(*align(1) const u32, @ptrCast(bytes)).*;
        _ = Printf(dl, MSG_ADDRESS, .{ @as([*:0]const u8, host.h_name.?), sb.Inet_NtoA(value) });
    }
    return dos.RETURN_OK;
}

fn failed(dl: *DosBase, sb: *SocketBase, name: [*:0]const u8) i32 {
    var h_errno: u32 = 0;
    const tags = [_]TagItem{ .{ .tag = bsd.SBTM_GETREF(bsd.SBTC_HERRNO), .data = @intFromPtr(&h_errno) }, .{} };
    _ = sb.SocketBaseTagList(&tags);
    _ = Printf(dl, MSG_FAILED, .{ name, reason(@bitCast(h_errno)) });
    return dos.RETURN_WARN;
}
