// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Thomas Dye
//! The transfer category, tests 115 to 119: a socket handed on -
//! Dup2Socket, ReleaseSocket and ObtainSocket in one program with the
//! data that waited on it, and ReleaseCopyOfSocket. Ports: offset 121.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _run = @import("run.zig");
const Run = _run.Run;
const Pair = _run.Pair;

pub fn tests(run: *Run) void {
    const sb = run.sb;

    // 115 to 117. Dup2Socket.
    for (0..3) |_| {
        run.tap.skip("no Dup2Socket");
        if (run.interrupted()) return;
    }

    // 118. Released and obtained again, with what waited on it.
    var pair = Pair.open(run, 121);
    if (pair.ready()) {
        var bytes: [100]u8 = undefined;
        _run.fillPattern(&bytes, 116);
        _ = sb.Send(pair.client, &bytes, bytes.len, 0);
        const id = sb.ReleaseSocket(pair.server, 42);
        if (id >= 0) {
            pair.server = -1;
            const obtained = sb.ObtainSocket(id, bsd.AF_INET, bsd.SOCK_STREAM, 0);
            if (obtained >= 0) {
                run.setReceiveTimeout(obtained, 2);
                @memset(&bytes, 0);
                const got = sb.Recv(obtained, &bytes, bytes.len, 0);
                run.tap.ok(got == 100 and _run.checkPattern(&bytes, 116) == 0, "ReleaseSocket()/ObtainSocket(): same-process roundtrip [AmiTCP]");
                run.tap.diag("  released_id=%d, obtained=%d, recv=%d", .{ id, obtained, got });
                run.close(obtained);
            } else {
                run.tap.ok(false, "ReleaseSocket()/ObtainSocket(): same-process roundtrip [AmiTCP]");
            }
        } else {
            run.tap.skip("ReleaseSocket not supported");
        }
    } else {
        run.tap.ok(false, "ReleaseSocket()/ObtainSocket(): same-process roundtrip [AmiTCP]");
    }
    pair.close(run);
    if (run.interrupted()) return;

    // 119. ReleaseCopyOfSocket.
    run.tap.skip("no ReleaseCopyOfSocket");
}
