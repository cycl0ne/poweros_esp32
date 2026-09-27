// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Thomas Dye
//! The errno category, tests 120 to 126: the error number - Errno after a
//! call that failed and after one that did not, SetErrnoPtr with a
//! variable of 1, 2 and 4 bytes, SBTC_ERRNOLONGPTR, and a connect that
//! an error left over from before must not make fail. Ports: offset 0.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _run = @import("run.zig");
const Run = _run.Run;

pub fn tests(run: *Run) void {
    const sb = run.sb;

    // 120. Errno after a call that failed.
    var descriptor = sb.Socket(-1, -1, -1);
    var number = sb.Errno();
    run.tap.ok(descriptor < 0 and number != 0, "Errno(): correct value after failed operation [AmiTCP]");
    run.tap.diag("  Errno()=%d", .{number});
    run.close(descriptor);
    if (run.interrupted()) return;

    // 121. Errno after one that did not: either answer, which the log
    // gives.
    _ = sb.CloseSocket(-1);
    descriptor = sb.Socket(bsd.AF_INET, bsd.SOCK_STREAM, 0);
    if (descriptor >= 0) {
        number = sb.Errno();
        run.tap.ok(true, "Errno(): behavior after successful operation [AmiTCP]");
        if (number == 0) run.tap.diag("  behavior: errno cleared on success", .{}) else run.tap.diag("  behavior: errno=%d after successful socket()", .{number});
        run.close(descriptor);
    } else {
        run.tap.ok(false, "Errno(): behavior after successful operation [AmiTCP]");
    }
    if (run.interrupted()) return;

    // 122 to 124. A variable of 1, 2 and 4 bytes.
    var byte: i8 = 0;
    sb.SetErrnoPtr(&byte, 1);
    _ = sb.CloseSocket(-1);
    sb.SetErrnoPtr(null, 0);
    run.tap.ok(byte != 0, "SetErrnoPtr(): 1-byte variable [AmiTCP]");
    run.tap.diag("  byte errno: %d", .{@as(i32, byte)});
    if (run.interrupted()) return;

    var word: i16 = 0;
    sb.SetErrnoPtr(&word, 2);
    _ = sb.CloseSocket(-1);
    sb.SetErrnoPtr(null, 0);
    run.tap.ok(word != 0, "SetErrnoPtr(): 2-byte variable [AmiTCP]");
    run.tap.diag("  word errno: %d", .{@as(i32, word)});
    if (run.interrupted()) return;

    var long: i32 = 0;
    sb.SetErrnoPtr(&long, 4);
    _ = sb.CloseSocket(-1);
    sb.SetErrnoPtr(null, 0);
    run.tap.ok(long != 0, "SetErrnoPtr(): 4-byte variable [AmiTCP]");
    run.tap.diag("  long errno: %d", .{long});
    if (run.interrupted()) return;

    // 125. SBTC_ERRNOLONGPTR.
    run.tap.skip("no SBTC_ERRNOLONGPTR");
    if (run.interrupted()) return;

    // 126. An error left over from before does not stop a connect.
    const description = "connect(): not affected by stale errno [POSIX]";
    const listener = run.loopbackListener(run.port(0));
    if (listener < 0) {
        run.tap.ok(false, description);
        run.tap.diag("  could not create listener", .{});
        return;
    }
    defer run.close(listener);
    const client = run.tcpSocket();
    if (client < 0) {
        run.tap.ok(false, description);
        run.tap.diag("  could not create client socket", .{});
        return;
    }
    defer run.close(client);
    _ = sb.CloseSocket(-1);
    const stale = sb.Errno();
    const address = _run.loopback(run.port(0));
    const result = sb.Connect(client, address.anyConst(), @sizeOf(bsd.sockaddr_in));
    run.tap.ok(result == 0, description);
    run.tap.diag("  stale_errno=%d, connect_rc=%d, post_errno=%d", .{ stale, result, sb.Errno() });
    if (result == 0) run.close(sb.Accept(listener, null, null));
}
