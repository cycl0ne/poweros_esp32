// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Thomas Dye
//! The socket category, tests 1 to 23: a socket's life - Socket, Bind,
//! Listen, Connect, Accept, Shutdown, CloseSocket, GetSockName and
//! GetPeerName. Ports: offsets 0 to 19.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const _run = @import("run.zig");
const Run = _run.Run;

pub fn tests(run: *Run) void {
    const sb = run.sb;
    var address: bsd.sockaddr_in = .{};
    var length: u32 = 0;

    // 1. A stream socket.
    var descriptor = sb.Socket(bsd.AF_INET, bsd.SOCK_STREAM, 0);
    run.tap.ok(descriptor >= 0, "socket(): create SOCK_STREAM (TCP) [BSD 4.4]");
    run.close(descriptor);
    if (run.interrupted()) return;

    // 2. A datagram socket.
    descriptor = sb.Socket(bsd.AF_INET, bsd.SOCK_DGRAM, 0);
    run.tap.ok(descriptor >= 0, "socket(): create SOCK_DGRAM (UDP) [BSD 4.4]");
    run.close(descriptor);
    if (run.interrupted()) return;

    // 3. A raw ICMP socket.
    descriptor = sb.Socket(bsd.AF_INET, bsd.SOCK_RAW, bsd.IPPROTO_ICMP);
    if (descriptor >= 0) {
        run.tap.ok(true, "socket(): create SOCK_RAW (ICMP) [BSD 4.4]");
        run.close(descriptor);
    } else if (run.errno() == bsd.EACCES) {
        run.tap.skip("raw sockets require privileges");
    } else {
        run.tap.ok(false, "socket(): create SOCK_RAW (ICMP) [BSD 4.4]");
    }
    if (run.interrupted()) return;

    // 4. A domain there is none of.
    descriptor = sb.Socket(-1, bsd.SOCK_STREAM, 0);
    run.tap.ok(descriptor == -1 and run.errno() != 0, "socket(): reject invalid domain (errno) [BSD 4.4]");
    run.close(descriptor);
    if (run.interrupted()) return;

    // 5. A type there is none of.
    descriptor = sb.Socket(bsd.AF_INET, 999, 0);
    run.tap.ok(descriptor == -1 and run.errno() != 0, "socket(): reject invalid type (errno) [BSD 4.4]");
    run.close(descriptor);
    if (run.interrupted()) return;

    // 6. Port 0 picks one.
    descriptor = run.tcpSocket();
    if (descriptor >= 0) {
        address = .{ .sin_addr = .{ .s_addr = bsd.htonl(bsd.INADDR_ANY) } };
        const result = sb.Bind(descriptor, address.anyConst(), @sizeOf(bsd.sockaddr_in));
        length = @sizeOf(bsd.sockaddr_in);
        _ = sb.GetSockName(descriptor, address.any(), &length);
        run.tap.ok(result == 0 and bsd.ntohs(address.sin_port) > 0, "bind(): INADDR_ANY port 0 auto-assigns ephemeral port [BSD 4.4]");
        run.tap.diag("  assigned port: %u", .{@as(u32, bsd.ntohs(address.sin_port))});
    } else {
        run.tap.ok(false, "bind(): INADDR_ANY port 0 auto-assigns ephemeral port [BSD 4.4]");
    }
    run.close(descriptor);
    if (run.interrupted()) return;

    // 7. A port of the caller's.
    var port = run.port(0);
    descriptor = run.tcpSocket();
    if (descriptor >= 0) {
        run.setFlag(descriptor, bsd.SO_REUSEADDR, 1);
        address = _run.loopback(port);
        const result = sb.Bind(descriptor, address.anyConst(), @sizeOf(bsd.sockaddr_in));
        length = @sizeOf(bsd.sockaddr_in);
        _ = sb.GetSockName(descriptor, address.any(), &length);
        run.tap.ok(result == 0 and bsd.ntohs(address.sin_port) == port, "bind(): specific port assignment [BSD 4.4]");
    } else {
        run.tap.ok(false, "bind(): specific port assignment [BSD 4.4]");
    }
    run.close(descriptor);
    if (run.interrupted()) return;

    // 8. The same address twice.
    port = run.port(1);
    descriptor = run.tcpSocket();
    const second = run.tcpSocket();
    if (descriptor >= 0 and second >= 0) {
        address = _run.loopback(port);
        _ = sb.Bind(descriptor, address.anyConst(), @sizeOf(bsd.sockaddr_in));
        _ = sb.Listen(descriptor, 5);
        const result = sb.Bind(second, address.anyConst(), @sizeOf(bsd.sockaddr_in));
        run.tap.ok(result < 0 and run.errno() == bsd.EADDRINUSE, "bind(): EADDRINUSE on double-bind [BSD 4.4]");
    } else {
        run.tap.ok(false, "bind(): EADDRINUSE on double-bind [BSD 4.4]");
    }
    run.close(descriptor);
    run.close(second);
    if (run.interrupted()) return;

    // 9. Listen on a bound socket.
    port = run.port(2);
    descriptor = run.tcpSocket();
    if (descriptor >= 0) {
        run.setFlag(descriptor, bsd.SO_REUSEADDR, 1);
        address = _run.loopback(port);
        _ = sb.Bind(descriptor, address.anyConst(), @sizeOf(bsd.sockaddr_in));
        run.tap.ok(sb.Listen(descriptor, 5) == 0, "listen(): on bound socket [BSD 4.4]");
    } else {
        run.tap.ok(false, "listen(): on bound socket [BSD 4.4]");
    }
    run.close(descriptor);
    if (run.interrupted()) return;

    // 10. Listen on an unbound one: either answer is right; the log says
    // which.
    descriptor = run.tcpSocket();
    if (descriptor >= 0) {
        const result = sb.Listen(descriptor, 5);
        run.tap.ok(true, "listen(): on unbound socket (auto-bind behavior) [BSD 4.4]");
        if (result == 0) run.tap.diag("  behavior: auto-bind", .{}) else run.tap.diag("  behavior: rejected (expected on some stacks)", .{});
    } else {
        run.tap.ok(false, "listen(): on unbound socket (auto-bind behavior) [BSD 4.4]");
    }
    run.close(descriptor);
    if (run.interrupted()) return;

    // 11. Connect to a loopback listener.
    port = run.port(3);
    var listener = run.loopbackListener(port);
    var client = run.loopbackClient(port);
    var server = run.acceptOne(listener);
    run.tap.ok(listener >= 0 and client >= 0 and server >= 0, "connect(): TCP to loopback listener [BSD 4.4]");
    run.close(server);
    run.close(client);
    run.close(listener);
    if (run.interrupted()) return;

    // 12. Connect to a port nobody listens on.
    port = run.port(4);
    descriptor = run.tcpSocket();
    if (descriptor >= 0) {
        address = _run.loopback(port);
        const result = sb.Connect(descriptor, address.anyConst(), @sizeOf(bsd.sockaddr_in));
        run.tap.ok(result < 0 and run.errno() == bsd.ECONNREFUSED, "connect(): ECONNREFUSED to closed port [BSD 4.4]");
    } else {
        run.tap.ok(false, "connect(): ECONNREFUSED to closed port [BSD 4.4]");
    }
    run.close(descriptor);
    if (run.interrupted()) return;

    // 13. Accept answers a new descriptor.
    port = run.port(5);
    listener = run.loopbackListener(port);
    client = run.loopbackClient(port);
    server = run.acceptOne(listener);
    run.tap.ok(server >= 0 and server != listener, "accept(): returns new descriptor [BSD 4.4]");
    run.close(server);
    run.close(client);
    run.close(listener);
    if (run.interrupted()) return;

    // 14. Accept fills in the peer.
    port = run.port(6);
    listener = run.loopbackListener(port);
    client = run.loopbackClient(port);
    if (listener >= 0 and client >= 0) {
        address = .{ .sin_family = 0 };
        length = @sizeOf(bsd.sockaddr_in);
        server = sb.Accept(listener, address.any(), &length);
        run.tap.ok(server >= 0 and address.sin_family == bsd.AF_INET and
            address.sin_addr.s_addr == bsd.htonl(bsd.INADDR_LOOPBACK) and address.sin_port != 0, "accept(): fills peer address struct [BSD 4.4]");
        run.close(server);
    } else {
        run.tap.ok(false, "accept(): fills peer address struct [BSD 4.4]");
    }
    run.close(client);
    run.close(listener);
    if (run.interrupted()) return;

    // 15. A listener that never waits, with nothing to accept.
    port = run.port(7);
    listener = run.loopbackListener(port);
    if (listener >= 0) {
        _ = run.setNonblocking(listener);
        server = run.acceptOne(listener);
        run.tap.ok(server < 0 and run.errno() == bsd.EWOULDBLOCK, "accept(): EWOULDBLOCK when non-blocking, no pending [BSD 4.4]");
        run.close(server);
    } else {
        run.tap.ok(false, "accept(): EWOULDBLOCK when non-blocking, no pending [BSD 4.4]");
    }
    run.close(listener);
    if (run.interrupted()) return;

    // 16. Shutdown for receiving.
    port = run.port(8);
    listener = run.loopbackListener(port);
    client = run.loopbackClient(port);
    server = run.acceptOne(listener);
    if (client >= 0 and server >= 0) {
        run.tap.ok(sb.Shutdown(client, bsd.SHUT_RD) == 0, "shutdown(SHUT_RD): disable receives [BSD 4.4]");
    } else {
        run.tap.ok(false, "shutdown(SHUT_RD): disable receives [BSD 4.4]");
    }
    run.close(server);
    run.close(client);
    run.close(listener);
    if (run.interrupted()) return;

    // 17. Shutdown for sending: the peer reads the end.
    port = run.port(9);
    listener = run.loopbackListener(port);
    client = run.loopbackClient(port);
    server = run.acceptOne(listener);
    if (client >= 0 and server >= 0) {
        run.setReceiveTimeout(server, 2);
        if (sb.Shutdown(client, bsd.SHUT_WR) == 0) {
            var bytes: [16]u8 = undefined;
            run.tap.ok(sb.Recv(server, &bytes, bytes.len, 0) == 0, "shutdown(SHUT_WR): peer sees EOF [BSD 4.4]");
        } else {
            run.tap.ok(false, "shutdown(SHUT_WR): peer sees EOF [BSD 4.4]");
        }
    } else {
        run.tap.ok(false, "shutdown(SHUT_WR): peer sees EOF [BSD 4.4]");
    }
    run.close(server);
    run.close(client);
    run.close(listener);
    if (run.interrupted()) return;

    // 18. Shutdown both ways.
    port = run.port(10);
    listener = run.loopbackListener(port);
    client = run.loopbackClient(port);
    server = run.acceptOne(listener);
    if (client >= 0 and server >= 0) {
        run.tap.ok(sb.Shutdown(client, bsd.SHUT_RDWR) == 0, "shutdown(SHUT_RDWR): full close [BSD 4.4]");
    } else {
        run.tap.ok(false, "shutdown(SHUT_RDWR): full close [BSD 4.4]");
    }
    run.close(server);
    run.close(client);
    run.close(listener);
    if (run.interrupted()) return;

    // 19. CloseSocket of a socket.
    descriptor = run.tcpSocket();
    run.tap.ok(descriptor >= 0 and sb.CloseSocket(descriptor) == 0, "CloseSocket(): valid descriptor [AmiTCP]");
    if (run.interrupted()) return;

    // 20. CloseSocket of no socket.
    run.tap.ok(sb.CloseSocket(-1) != 0, "CloseSocket(): invalid descriptor returns error [AmiTCP]");
    if (run.interrupted()) return;

    // 21. GetSockName after Bind.
    port = run.port(11);
    descriptor = run.tcpSocket();
    if (descriptor >= 0) {
        run.setFlag(descriptor, bsd.SO_REUSEADDR, 1);
        address = _run.loopback(port);
        _ = sb.Bind(descriptor, address.anyConst(), @sizeOf(bsd.sockaddr_in));
        address = .{ .sin_family = 0 };
        length = @sizeOf(bsd.sockaddr_in);
        _ = sb.GetSockName(descriptor, address.any(), &length);
        run.tap.ok(address.sin_family == bsd.AF_INET and address.sin_port == bsd.htons(port) and
            address.sin_addr.s_addr == bsd.htonl(bsd.INADDR_LOOPBACK), "getsockname(): returns bound address [BSD 4.4]");
    } else {
        run.tap.ok(false, "getsockname(): returns bound address [BSD 4.4]");
    }
    run.close(descriptor);
    if (run.interrupted()) return;

    // 22. GetPeerName once connected.
    port = run.port(12);
    listener = run.loopbackListener(port);
    client = run.loopbackClient(port);
    server = run.acceptOne(listener);
    if (client >= 0) {
        address = .{ .sin_family = 0 };
        length = @sizeOf(bsd.sockaddr_in);
        const result = sb.GetPeerName(client, address.any(), &length);
        run.tap.ok(result == 0 and address.sin_family == bsd.AF_INET and
            address.sin_addr.s_addr == bsd.htonl(bsd.INADDR_LOOPBACK), "getpeername(): returns peer address after connect [BSD 4.4]");
    } else {
        run.tap.ok(false, "getpeername(): returns peer address after connect [BSD 4.4]");
    }
    run.close(server);
    run.close(client);
    run.close(listener);
    if (run.interrupted()) return;

    // 23. GetPeerName with no peer.
    descriptor = run.tcpSocket();
    if (descriptor >= 0) {
        length = @sizeOf(bsd.sockaddr_in);
        const result = sb.GetPeerName(descriptor, address.any(), &length);
        run.tap.ok(result < 0 and run.errno() == bsd.ENOTCONN, "getpeername(): ENOTCONN on unconnected socket [BSD 4.4]");
    } else {
        run.tap.ok(false, "getpeername(): ENOTCONN on unconnected socket [BSD 4.4]");
    }
    run.close(descriptor);
}
