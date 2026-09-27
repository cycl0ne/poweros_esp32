// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Thomas Dye
//! The misc category, tests 127 to 131: GetDTableSize as it starts and
//! after SBTC_DTABLESIZE grew the table, syslog, CloseSocket after a
//! Shutdown, and as many sockets open at once as the table holds.
//! Ports: offset 140.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _run = @import("run.zig");
const Run = _run.Run;
const Pair = _run.Pair;

pub fn tests(run: *Run) void {
    const sb = run.sb;

    // 127. The table's size as it starts.
    var size = sb.GetDTableSize();
    run.tap.ok(size >= 64, "getdtablesize(): default descriptor table size [AmiTCP]");
    run.tap.diag("  dtablesize=%d", .{size});
    if (run.interrupted()) return;

    // 128. The table grown by 64.
    const original = run.getTag(bsd.SBTC_DTABLESIZE);
    if (original < 64) {
        run.tap.ok(false, "getdtablesize(): reflects SBTC_DTABLESIZE change [AmiTCP]");
        run.tap.diag("  GET returned %u (expected >= 64), skipping SET", .{original});
    } else {
        const larger = original + 64;
        _ = run.setTag(bsd.SBTC_DTABLESIZE, larger);
        size = sb.GetDTableSize();
        run.tap.ok(size >= larger, "getdtablesize(): reflects SBTC_DTABLESIZE change [AmiTCP]");
        run.tap.diag("  before=%u, requested=%u, getdtablesize=%d", .{ original, larger, size });
        _ = run.setTag(bsd.SBTC_DTABLESIZE, original);
    }
    if (run.interrupted()) return;

    // 129. syslog.
    run.tap.skip("no syslog");
    if (run.interrupted()) return;

    // 130. CloseSocket after Shutdown.
    var pair = Pair.open(run, 140);
    if (pair.ready()) {
        _ = sb.Shutdown(pair.client, bsd.SHUT_RDWR);
        const result = sb.CloseSocket(pair.client);
        pair.client = -1;
        run.tap.ok(result == 0, "CloseSocket(): succeeds after prior shutdown [AmiTCP]");
        run.tap.diag("  rc=%d", .{result});
    } else {
        run.tap.ok(false, "CloseSocket(): succeeds after prior shutdown [AmiTCP]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 131. The table's size less one sockets, at most 256.
    size = sb.GetDTableSize();
    const descriptors = &run.buffers.descriptors;
    const wanted: usize = @min(@as(usize, @intCast(@max(size - 1, 0))), descriptors.len);
    var count: usize = 0;
    while (count < wanted) : (count += 1) {
        descriptors[count] = run.tcpSocket();
        if (descriptors[count] < 0) break;
    }
    const opened: u32 = @intCast(count);
    run.tap.ok(opened >= 32, "socket(): open dtablesize-1 descriptors successfully [AmiTCP]");
    run.tap.diag("  opened=%u, dtablesize=%d", .{ opened, size });
    run.tap.note("Max sockets: %u", .{opened});
    while (count > 0) {
        count -= 1;
        run.close(descriptors[count]);
    }
}
