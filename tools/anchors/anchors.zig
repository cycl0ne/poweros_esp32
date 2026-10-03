// SPDX-License-Identifier: MPL-2.0
//! anchors: Mozilla's root certificates, as one PEM file, into the trust
//! store the disk carries (`SYS:Certificates/Roots`).
//!
//! usage: anchors <in.pem> <out>
//!
//! Each certificate is read with the library's own code (`x509`, from
//! `src/disk/libs/tls/x509`), and what a chain is checked against - its
//! subject and its key - is written in the store's form
//! (`x509/anchors.zig`). A root whose key is of a kind no signature is
//! checked with (P-521: one root in the 2026-09-25 bundle) is left out
//! quietly - nothing could be checked with it anyway. A root that cannot
//! be read at all fails the build: that is the reader's fault, and a new
//! bundle that shows one up must be seen.

const std = @import("std");
const x509 = @import("x509");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: anchors <in.pem> <out>\n", .{});
        std.process.exit(2);
    }
    const text = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .unlimited);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, x509.anchors.magic);
    var blocks = x509.pem.Blocks.of(text);
    var buffer: [16384]u8 = undefined;
    var left_out: usize = 0;
    while (blocks.next(&buffer)) |encoded| {
        const cert = x509.certificate.parse(encoded) orelse {
            std.debug.print("anchors: a root that cannot be read ({d} bytes)\n", .{encoded.len});
            left_out += 1;
            continue;
        };
        const anchor = x509.anchors.fromCertificate(&cert) orelse continue;
        const at = out.items.len;
        try out.resize(arena, at + x509.anchors.encodedLength(&anchor));
        _ = x509.anchors.encode(&anchor, out.items[at..]);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out.items });
    if (left_out != 0) std.process.exit(1);
}
