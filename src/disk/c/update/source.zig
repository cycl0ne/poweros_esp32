// SPDX-License-Identifier: MIT
//! Where a package is read from. A path on a volume and an address over
//! HTTP answer the same two questions - a whole file into memory, which
//! is how the list is read, and a file written to the volume with its
//! sum and its length worked out as it goes - so the compare above does
//! not know which of the two it is walking.

const sdk = @import("sdk");
const dos = sdk.dos;
const http = sdk.http;
const utility = sdk.utility;
const shared = @import("_update.zig");
const Run = shared.Run;
const Name = shared.Name;

/// What says an argument is an address and not a path.
pub const address_mark = "://";

/// Whether `text` names an address.
pub fn isAddress(text: []const u8) bool {
    if (text.len < address_mark.len) return false;
    var at: usize = 0;
    while (at + address_mark.len <= text.len) : (at += 1) {
        if (text[at] == ':' and text[at + 1] == '/' and text[at + 2] == '/') return true;
        // A volume's name ends the search: "Work:http://x" is a path.
        if (text[at] == ':') return false;
    }
    return false;
}

/// The whole of the package's `rest` in memory, freed with FreeVec; null
/// and said when it cannot be had.
pub fn whole(run: *Run, rest: []const u8) ?[]u8 {
    const name = Name.of(run.from[0..shared.length(run.from)], rest);
    switch (run.kind) {
        .path => {
            const text = sdk.prefs.loadWhole(run.sys, run.dl, name.cstr()) orelse {
                _ = shared.failed(run, name.cstr(), run.dl.IoErr());
                return null;
            };
            return text;
        },
        .address => {
            var buffer: shared.Buffer = .{ .sys = run.sys };
            if (!get(run, name.cstr(), &buffer, null, null, null)) {
                buffer.free();
                return null;
            }
            // A list's last line must end, and one that arrived ended
            // is left exactly as it came: it is written back as the
            // machine's own list, byte for byte what the package holds.
            if (buffer.at == 0 or buffer.bytes[buffer.at - 1] != '\n') {
                if (!buffer.add("\n")) {
                    buffer.free();
                    _ = shared.fail(run, "no memory for %s\n", .{name.cstr()});
                    return null;
                }
            }
            return buffer.bytes[0..buffer.at];
        },
    }
}

/// The package's `rest` written to the file `to`, its CRC-32 in `sum`
/// and its length in `length`. Null when it is written; a return code
/// when it is not, said already.
pub fn fetch(run: *Run, rest: []const u8, to: [*:0]const u8, sum: *u32, length: *u64) ?i32 {
    const dl = run.dl;
    const name = Name.of(run.from[0..shared.length(run.from)], rest);
    const out = dl.Open(to, dos.MODE_NEWFILE) orelse return shared.failed(run, to, dl.IoErr());
    var crc = dos.flashfs.crcStart();
    var total: u64 = 0;
    var kept = false;
    defer if (!kept) {
        _ = dl.Close(out);
        _ = dl.DeleteFile(to);
    };

    switch (run.kind) {
        .path => {
            const in = dl.Open(name.cstr(), dos.MODE_OLDFILE) orelse return shared.failed(run, name.cstr(), dl.IoErr());
            defer _ = dl.Close(in);
            while (true) {
                const got = dl.Read(in, run.buffer.ptr, @intCast(run.buffer.len));
                if (got < 0) return shared.failed(run, name.cstr(), dl.IoErr());
                if (got == 0) break;
                const count: usize = @intCast(got);
                if (dl.Write(out, run.buffer.ptr, got) != got) return shared.failed(run, to, dl.IoErr());
                crc = dos.flashfs.crcAdd(crc, run.buffer[0..count]);
                total += count;
            }
        },
        .address => {
            if (!get(run, name.cstr(), null, out, &crc, &total)) return dos.RETURN_FAIL;
        },
    }
    if (!dl.Close(out)) {
        kept = true; // closed, and the file is the caller's to delete
        return shared.failed(run, to, dl.IoErr());
    }
    kept = true;
    sum.* = dos.flashfs.crcEnd(crc);
    length.* = total;
    return null;
}

/// `url` fetched: into `buffer` where one is given, else written to the
/// file `out` with `crc` carried on. False when it failed, said already.
fn get(run: *Run, url: [*:0]const u8, buffer: ?*shared.Buffer, out: ?*dos.FileHandle, crc: ?*u32, count: ?*u64) bool {
    const dl = run.dl;
    const hb = run.hb orelse {
        _ = shared.fail(run, "%s is an address and http.library is not open\n", .{url});
        return false;
    };
    const client = run.client orelse return false;
    var err: i32 = http.HTTPERR_OK;
    const request = hb.OpenRequest(client, "GET", url, &[_]utility.TagItem{
        .{ .tag = http.HTTP_Header, .data = @intFromPtr("Accept: */*") },
        .{ .tag = http.HTTP_Redirects, .data = redirects_most },
        .{ .tag = http.HTTP_UserAgent, .data = @intFromPtr(user_agent) },
        .{},
    }, &err) orelse {
        _ = shared.fail(run, "%s: %s\n", .{ url, why(err) });
        return false;
    };
    defer hb.CloseRequest(request);

    const status = hb.GetRequestAttr(request, http.HTTP_Status);
    if (status < 200 or status > 299) {
        const line: [*:0]const u8 = @ptrFromInt(hb.GetRequestAttr(request, http.HTTP_StatusLine));
        _ = shared.fail(run, "%s: %s\n", .{ url, line });
        return false;
    }

    var total: u64 = 0;
    while (true) {
        if (shared.stopped(run)) return false;
        const got = hb.ReadRequest(request, run.buffer.ptr, @intCast(run.buffer.len));
        if (got == 0) break;
        if (got < 0) {
            _ = shared.fail(run, "%s: %s\n", .{ url, why(got) });
            return false;
        }
        const piece: usize = @intCast(got);
        if (buffer) |into| {
            if (!into.add(run.buffer[0..piece])) {
                _ = shared.fail(run, "no memory for %s\n", .{url});
                return false;
            }
        }
        if (out) |file| {
            if (dl.Write(file, run.buffer.ptr, got) != got) {
                _ = shared.failed(run, url, dl.IoErr());
                return false;
            }
        }
        if (crc) |sum| sum.* = dos.flashfs.crcAdd(sum.*, run.buffer[0..piece]);
        total += piece;
    }
    if (count) |into| into.* = total;
    return true;
}

const redirects_most = 5;
const user_agent = "PowerOS-Update/1.0";

/// What an HTTP or TLS code means, as a line.
pub fn why(code: i32) [*:0]const u8 {
    return switch (code) {
        http.HTTPERR_URL => "no http:// or https:// URL",
        http.HTTPERR_HOST => "the host has no address",
        http.HTTPERR_TLS => "TLS failed - the clock must be set for a certificate to be checked",
        http.HTTPERR_PROTOCOL => "the answer is not HTTP",
        http.HTTPERR_CLOSED => "the server closed the connection without answering",
        http.HTTPERR_REDIRECT => "more redirects than are followed, or one to nowhere",
        http.HTTPERR_TRUNCATED => "the connection ended before the body did",
        http.HTTPERR_NOMEM => "no memory",
        http.HTTPERR_LIBRARY => "LIBS:tls.library is not there",
        http.HTTPERR_IO => "the connection failed",
        else => "the request failed",
    };
}
