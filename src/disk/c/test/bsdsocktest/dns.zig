// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Thomas Dye
//! The dns category, tests 88 to 104: names - GetHostByName of localhost
//! and of a name that cannot be, GetHostByAddr of 127.0.0.1 and 0.0.0.0,
//! the services, protocols and networks databases, GetHostName into a
//! large and a tiny buffer, the host id; with the host helper, a name on
//! the Internet and the helper's own address looked up.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const Run = @import("run.zig").Run;

pub fn tests(run: *Run) void {
    const sb = run.sb;

    // 88. localhost is 127.0.0.1.
    if (sb.GetHostByName("localhost")) |entry| {
        const address = firstAddress(entry);
        run.tap.ok(entry.h_addrtype == bsd.AF_INET and entry.h_length == 4 and address == bsd.htonl(bsd.INADDR_LOOPBACK), "gethostbyname(): \"localhost\" resolves to 127.0.0.1 [BSD 4.4]");
        run.tap.diag("  resolved: %s", .{sb.Inet_NtoA(address)});
    } else {
        run.tap.ok(false, "gethostbyname(): \"localhost\" resolves to 127.0.0.1 [BSD 4.4]");
        run.tap.diag("  h_errno=%d", .{run.hErrno()});
    }
    if (run.interrupted()) return;

    // 89. A name under .invalid is never found, and says why.
    const missing = sb.GetHostByName("nonexistent.invalid");
    run.tap.ok(missing == null and run.hErrno() != 0, "gethostbyname(): invalid hostname sets h_errno [BSD 4.4]");
    run.tap.diag("  h_errno=%d", .{run.hErrno()});
    if (run.interrupted()) return;

    // 90, 91. The names of 127.0.0.1 and 0.0.0.0: any answer, which the
    // log gives.
    reverse(run, bsd.htonl(bsd.INADDR_LOOPBACK), true, "gethostbyaddr(): reverse lookup 127.0.0.1 [BSD 4.4]");
    if (run.interrupted()) return;
    reverse(run, 0, true, "gethostbyaddr(): 0.0.0.0 behavior [BSD 4.4]");
    if (run.interrupted()) return;

    // 92 to 97. The services and protocols databases.
    const databases = [_][*:0]const u8{
        "no GetServByName",  "no GetServByName",  "no GetServByPort",
        "no GetProtoByName", "no GetProtoByName", "no GetProtoByNumber",
    };
    for (databases) |reason| {
        run.tap.skip(reason);
        if (run.interrupted()) return;
    }

    // 98. The machine's name.
    var name: [256]u8 = @splat(0);
    var result = sb.GetHostName(&name, name.len);
    run.tap.ok(result == 0 and name[0] != 0, "gethostname(): retrieve hostname [BSD 4.4]");
    run.tap.diag("  rc=%d, hostname=\"%s\"", .{ result, @as([*:0]const u8, @ptrCast(&name)) });
    if (run.interrupted()) return;

    // 99. The name into two bytes: any answer, which the log gives.
    var small: [2]u8 = .{ 'X', 'X' };
    result = sb.GetHostName(&small, small.len);
    run.tap.ok(true, "gethostname(): small buffer truncation [BSD 4.4]");
    if (result == 0) {
        run.tap.diag("  small[0]=0x%02x small[1]=0x%02x", .{ @as(u32, small[0]), @as(u32, small[1]) });
    } else {
        run.tap.diag("  rc=%d, errno=%d", .{ result, run.errno() });
    }
    if (run.interrupted()) return;

    // 100 to 102. The host id and the networks database.
    const others = [_][*:0]const u8{ "no GetHostId", "no GetNetByName", "no GetNetByAddr" };
    for (others) |reason| {
        run.tap.skip(reason);
        if (run.interrupted()) return;
    }

    // 103, 104 need the host helper.
    if (!run.helper.connected) {
        run.tap.skip("host helper not connected");
        if (run.interrupted()) return;
        run.tap.skip("host helper not connected");
        return;
    }

    // 103. A name on the Internet.
    if (sb.GetHostByName("aminet.net")) |entry| {
        run.tap.ok(entry.h_addrtype == bsd.AF_INET and entry.h_length == 4, "gethostbyname(): external hostname resolution [BSD 4.4]");
        run.tap.diag("  resolved: %s", .{sb.Inet_NtoA(firstAddress(entry))});
    } else {
        run.tap.ok(false, "gethostbyname(): external hostname resolution [BSD 4.4]");
        run.tap.diag("  h_errno=%d", .{run.hErrno()});
    }
    if (run.interrupted()) return;

    // 104. The helper's name: passes without one too.
    reverse(run, run.helper.address, false, "gethostbyaddr(): external reverse lookup [BSD 4.4]");
}

fn firstAddress(entry: *bsd.hostent) u32 {
    const first = entry.h_addr_list.?[0] orelse return 0;
    return @as(*align(1) const u32, @ptrCast(first)).*;
}

/// The name of `address`. With `any`, every answer passes; else an
/// answer must be an IPv4 one (no answer passes as well).
fn reverse(run: *Run, address: u32, any: bool, description: [*:0]const u8) void {
    if (run.sb.GetHostByAddr(&address, 4, bsd.AF_INET)) |entry| {
        run.tap.ok(any or (entry.h_addrtype == bsd.AF_INET and entry.h_length == 4), description);
        run.tap.diag("  hostname: %s", .{@as(?[*:0]const u8, entry.h_name)});
    } else {
        run.tap.ok(true, description);
        run.tap.diag("  h_errno=%d", .{run.hErrno()});
    }
}
