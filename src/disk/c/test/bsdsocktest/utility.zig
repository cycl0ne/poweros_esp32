// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Thomas Dye
//! The utility category, tests 105 to 114: addresses as text and back -
//! Inet_NtoA of 127.0.0.1, 255.255.255.255 and 0.0.0.0, Inet_Addr of an
//! address, of text that is none, and of the broadcast address; the
//! class A network and host parts and the address made of them again.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const Run = @import("run.zig").Run;

pub fn tests(run: *Run) void {
    const sb = run.sb;

    // 105 to 107. Addresses as text.
    const texts = [_]struct { address: u32, text: []const u8, description: [*:0]const u8 }{
        .{ .address = 0x7f000001, .text = "127.0.0.1", .description = "Inet_NtoA(): 127.0.0.1 formatting [AmiTCP]" },
        .{ .address = 0xffffffff, .text = "255.255.255.255", .description = "Inet_NtoA(): 255.255.255.255 formatting [AmiTCP]" },
        .{ .address = 0, .text = "0.0.0.0", .description = "Inet_NtoA(): 0.0.0.0 formatting [AmiTCP]" },
    };
    for (texts) |case| {
        const text = sb.Inet_NtoA(bsd.htonl(case.address));
        run.tap.ok(same(text, case.text), case.description);
        run.tap.diag("  returned: \"%s\"", .{text});
        if (run.interrupted()) return;
    }

    // 108. Text as an address.
    run.tap.ok(sb.Inet_Addr("127.0.0.1") == bsd.htonl(0x7f000001), "inet_addr(): parse \"127.0.0.1\" [BSD 4.4]");
    if (run.interrupted()) return;

    // 109. Text that is no address.
    run.tap.ok(sb.Inet_Addr("not.an.ip") == bsd.INADDR_NONE, "inet_addr(): invalid string returns INADDR_NONE [BSD 4.4]");
    if (run.interrupted()) return;

    // 110. The broadcast address, which reads the same as INADDR_NONE.
    run.tap.ok(sb.Inet_Addr("255.255.255.255") == 0xffffffff, "inet_addr(): \"255.255.255.255\" [BSD 4.4]");
    run.tap.diag("  note: INADDR_NONE ambiguity with broadcast address", .{});
    if (run.interrupted()) return;

    // 111 to 114. An address's parts and inet_network.
    const reasons = [_][*:0]const u8{ "no Inet_LnaOf", "no Inet_NetOf", "no Inet_MakeAddr", "no inet_network" };
    for (reasons) |reason| {
        run.tap.skip(reason);
        if (run.interrupted()) return;
    }
}

fn same(text: [*:0]const u8, want: []const u8) bool {
    for (want, 0..) |character, at| {
        if (text[at] != character) return false;
    }
    return text[want.len] == 0;
}
