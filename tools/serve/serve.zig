// SPDX-License-Identifier: MPL-2.0
//! serve: hands out a release package over HTTP, so a machine installs
//! itself or brings itself up to date with nothing but a network.
//!
//! usage: serve [--port=<n>] [--host=<address>] <dir>
//!
//! GET and HEAD, and nothing else: there is no way to write anything
//! through it, no listing of a directory, and no path outside the one
//! directory it was given. What it will answer is exactly what a manifest
//! may name (`sdk.install.manifest.pathOk`) - relative, no `..`, no
//! device name, no control or pattern character - so the server, the tool
//! that writes a package and the commands that read one all take the same
//! view of what a path in a package is. `/` answers with a line saying
//! where to start, which is `GET /manifest`.
//!
//! On QEMU's user network the host is 10.0.2.2, so a machine in QEMU
//! reaches `http://10.0.2.2:<port>/` with no hardware in the way.
//!
//! One connection at a time, kept open while the client wants it: a
//! package is a few hundred files, and one machine installs from it.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const net = Io.net;
const http = std.http;
const sdk = @import("sdk");
const install = sdk.install;
const manifest = install.manifest;

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("serve: " ++ format ++ "\n", args);
    std.process.exit(1);
}

/// Said once, as the server comes up, and then a line per request.
fn say(comptime format: []const u8, args: anytype) void {
    std.debug.print("serve: " ++ format ++ "\n", args);
}

/// The request's head, which holds the target, is read into this much.
const head_bytes = 16 * 1024;

/// What is written out at once.
const body_bytes = 64 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var port: u16 = 8080;
    var host: []const u8 = "0.0.0.0";
    var root_path: ?[]const u8 = null;
    for (args, 0..) |arg, index| {
        if (index == 0) continue;
        if (mem.startsWith(u8, arg, "--port=")) {
            const text = arg["--port=".len..];
            port = std.fmt.parseInt(u16, text, 10) catch fatal("{s}: no port", .{text});
        } else if (mem.startsWith(u8, arg, "--host=")) {
            host = arg["--host=".len..];
        } else if (mem.startsWith(u8, arg, "--")) {
            fatal("{s}: no such option", .{arg});
        } else if (root_path == null) {
            root_path = arg;
        } else fatal("usage: serve [--port=<n>] [--host=<address>] <dir>", .{});
    }
    const dir_path = root_path orelse fatal("usage: serve [--port=<n>] [--host=<address>] <dir>", .{});

    const cwd = Io.Dir.cwd();
    var root = cwd.openDir(io, dir_path, .{}) catch |err|
        fatal("{s}: {s}", .{ dir_path, @errorName(err) });
    defer root.close(io);
    // A directory with no manifest is not a package, and saying so now is
    // better than a machine finding out after it has fetched half of one.
    root.access(io, install.package_manifest, .{}) catch |err|
        fatal("{s}/{s}: {s}", .{ dir_path, install.package_manifest, @errorName(err) });

    const address = net.IpAddress.parse(host, port) catch fatal("{s}: no address", .{host});
    var server = address.listen(io, .{ .reuse_address = true }) catch |err|
        fatal("{s}:{d}: {s}", .{ host, port, @errorName(err) });
    defer server.deinit(io);
    say("{s} on http://{s}:{d}/ - in QEMU's user network http://10.0.2.2:{d}/ (quit with Ctrl-C)", .{ dir_path, host, port, port });

    var head: [head_bytes]u8 = undefined;
    var body: [body_bytes]u8 = undefined;
    while (true) {
        const stream = server.accept(io) catch |err| {
            say("a connection came to nothing: {s}", .{@errorName(err)});
            continue;
        };
        defer stream.close(io);
        var reader = stream.reader(io, &head);
        var writer = stream.writer(io, &body);
        var connection: http.Server = .init(&reader.interface, &writer.interface);
        while (connection.reader.state == .ready) {
            var request = connection.receiveHead() catch break;
            answer(io, root, &request, gpa) catch break;
        }
    }
}

/// One request answered: the file it names, or why not.
fn answer(io: Io, root: Io.Dir, request: *http.Server.Request, gpa: mem.Allocator) !void {
    const target = request.head.target;
    const method = request.head.method;
    if (method != .GET and method != .HEAD) {
        say("{s} {s} 405", .{ @tagName(method), target });
        // And the connection ends with the answer: a method that sends a
        // body has sent one, and nothing here is going to read it.
        return request.respond("this serves files and nothing else\n", .{
            .status = .method_not_allowed,
            .keep_alive = false,
        });
    }

    // The target as a path in the package: what is before any query,
    // without its leading slash, with %xx read back.
    var decoded: [manifest.max_path + 1]u8 = undefined;
    const asked = if (mem.indexOfScalar(u8, target, '?')) |at| target[0..at] else target;
    if (asked.len == 0 or asked[0] != '/' or asked.len - 1 > manifest.max_path) {
        say("{s} {s} 404", .{ @tagName(method), target });
        return request.respond("no such file\n", .{ .status = .not_found });
    }
    @memcpy(decoded[0 .. asked.len - 1], asked[1..]);
    const path = std.Uri.percentDecodeInPlace(decoded[0 .. asked.len - 1]);

    // Nothing but a package's own paths, which is what a manifest may
    // name: that one rule is the whole of what this server will open.
    if (path.len == 0) {
        say("{s} {s} 200 (where to start)", .{ @tagName(method), target });
        return request.respond(
            "A release package. GET /manifest for the list, then the paths in it.\n",
            .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }} },
        );
    }
    if (!manifest.pathOk(path)) {
        say("{s} {s} 403", .{ @tagName(method), target });
        return request.respond("no path in a package\n", .{ .status = .forbidden });
    }

    const content = root.readFileAlloc(io, path, gpa, .unlimited) catch |err| {
        say("{s} {s} 404 ({s})", .{ @tagName(method), target, @errorName(err) });
        return request.respond("no such file\n", .{ .status = .not_found });
    };
    defer gpa.free(content);
    say("{s} {s} 200 {d}", .{ @tagName(method), target, content.len });
    return request.respond(content, .{
        .extra_headers = &.{.{ .name = "content-type", .value = contentType(path) }},
    });
}

/// What a file in a package is, for a client that asks. A manifest and
/// the firmware's own settings are read by people as well as machines;
/// everything else is a program, a picture or an image of a disk.
fn contentType(path: []const u8) []const u8 {
    const plain = "text/plain; charset=utf-8";
    if (mem.eql(u8, path, install.package_manifest)) return plain;
    for ([_][]const u8{ ".txt", ".md", ".cd" }) |suffix| {
        if (mem.endsWith(u8, path, suffix)) return plain;
    }
    return "application/octet-stream";
}
