// SPDX-License-Identifier: MIT
//! Resolve: the addresses a name has, or the name an address has. Built
//! against the SDK only.
//!
//!   Resolve NAME/A,INET4=-4/S,INET6=-6/S
//!
//! A name is looked up as GetAddrInfo looks it up - the hosts file, the
//! cache, the name servers, for AAAA and A records - and every address it
//! has is printed, IPv6 and IPv4, in the order a connection would try
//! them; INET4 or INET6 asks for one family only. An IPv4 address, as
//! dotted text, is looked up the other way.

const sdk = @import("sdk");
const dos = sdk.dos;
const bsd = sdk.bsdsocket;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Resolve";
const VERSION_STRING = "\x00$VER: Resolve 1.1 (27.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "NAME/A,INET4=-4/S,INET6=-6/S";

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_ADDRESS = "%s has address %s\n";
const MSG_ADDRESS6 = "%s has IPv6 address %s\n";
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

fn lookupReason(code: i32) [*:0]const u8 {
    return switch (code) {
        bsd.EAI_AGAIN => "no answer from the name servers",
        bsd.EAI_FAIL => "no name server to ask",
        else => "no such name",
    };
}

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
    const family: i32 = if (argv[1] != 0 and argv[2] == 0) bsd.AF_INET else if (argv[2] != 0 and argv[1] == 0) bsd.AF_INET6 else bsd.AF_UNSPEC;
    const hints: bsd.addrinfo = .{ .ai_family = family, .ai_socktype = bsd.SOCK_STREAM, .ai_flags = bsd.AI_CANONNAME };
    var list: ?*bsd.addrinfo = null;
    const code = sb.GetAddrInfo(name, null, &hints, &list);
    if (code != 0) {
        _ = Printf(dl, MSG_FAILED, .{ name, lookupReason(code) });
        return dos.RETURN_WARN;
    }
    defer sb.FreeAddrInfo(list.?);
    const canonical: [*:0]const u8 = list.?.ai_canonname orelse name;
    var entry = list;
    while (entry) |each| : (entry = each.ai_next) {
        if (each.ai_family == bsd.AF_INET6) {
            const six: *const bsd.sockaddr_in6 = @ptrCast(@alignCast(each.ai_addr.?));
            var text: [bsd.INET6_ADDRSTRLEN]u8 = undefined;
            _ = Printf(dl, MSG_ADDRESS6, .{ canonical, sb.Inet_NtoP(bsd.AF_INET6, &six.sin6_addr, &text, text.len) orelse "?" });
        } else {
            const four: *const bsd.sockaddr_in = @ptrCast(@alignCast(each.ai_addr.?));
            _ = Printf(dl, MSG_ADDRESS, .{ canonical, sb.Inet_NtoA(four.sin_addr.s_addr) });
        }
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
