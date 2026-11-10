// SPDX-License-Identifier: MIT
//! A page on the web read whole into memory, for MultiView to show as it
//! shows a file.
//!
//! bsdsocket.library and http.library are opened when the first page is
//! fetched, and not before: a MultiView that only ever shows files never
//! touches the network. The client made then keeps its connections, so
//! the next page from the same server comes over the one already open,
//! without a second TLS handshake. A redirect is followed, five at the
//! most, and the address the page came from in the end is the one its
//! links are read against.
//!
//! `https:` is checked as http.library checks it: the server's
//! certificate against the system's trusted roots, which needs the clock
//! set.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const bsd = sdk.bsdsocket;
const http = sdk.http;
const links = @import("links.zig");
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const HttpBase = sdk.interface.http.HttpBase;

/// The most a page may be; one larger is not shown.
const page_most: usize = 16 << 20;
/// What a page's memory starts at when its length is not known.
const first_room: usize = 64 << 10;
const redirects_most = 5;

/// The network, as far as it has been needed.
pub const Web = struct {
    sys: *ExecBase,
    /// What the program calls itself to a server.
    agent: [*:0]const u8 = "PowerOS",
    socket_lib: ?*exec.Library = null,
    http_lib: ?*exec.Library = null,
    client: ?*http.Client = null,
    /// What went wrong with the last page that could not be fetched, in
    /// words.
    why: [256]u8 = @splat(0),

    /// The libraries opened and the client made, if they are not yet.
    fn ready(web: *Web) bool {
        if (web.client != null) return true;
        const sys = web.sys;
        if (web.socket_lib == null) web.socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1);
        if (web.http_lib == null) web.http_lib = sys.OpenLibrary(http.HTTPNAME, 1);
        const socket_lib = web.socket_lib orelse return web.say(bsd.SOCKETNAME ++ " is not there");
        const http_lib = web.http_lib orelse return web.say(http.HTTPNAME ++ " is not there");
        const hb: *HttpBase = @ptrCast(http_lib);
        web.client = hb.CreateClient(@ptrCast(socket_lib), &[_]utility.TagItem{
            .{ .tag = http.HTTP_UserAgent, .data = @intFromPtr(web.agent) },
            .{},
        }) orelse return web.say("there is no memory for the network");
        return true;
    }

    fn say(web: *Web, words: []const u8) bool {
        const length = @min(words.len, web.why.len - 1);
        @memcpy(web.why[0..length], words[0..length]);
        web.why[length] = 0;
        return false;
    }

    /// The client and the connections it kept closed, and the libraries
    /// with them.
    pub fn close(web: *Web) void {
        const sys = web.sys;
        if (web.client) |client| {
            const hb: *HttpBase = @ptrCast(web.http_lib.?);
            hb.DeleteClient(client);
            web.client = null;
        }
        if (web.http_lib) |lib| sys.CloseLibrary(lib);
        if (web.socket_lib) |lib| sys.CloseLibrary(lib);
        web.http_lib = null;
        web.socket_lib = null;
    }

    /// The page at `where`, read whole into memory from `AllocVec`, the
    /// caller's to free; `where` then names where it came from, after
    /// the redirects. Null, with why in `why`, when it could not be had:
    /// no network, a server that answered with no page, Ctrl-C.
    pub fn fetch(web: *Web, dl: *DosBase, where: *links.Location) ?[]u8 {
        if (!web.ready()) return null;
        const hb: *HttpBase = @ptrCast(web.http_lib.?);
        const client = web.client.?;
        var err: i32 = http.HTTPERR_OK;
        const request = hb.OpenRequest(client, "GET", where.name(), &[_]utility.TagItem{
            .{ .tag = http.HTTP_Header, .data = @intFromPtr("Accept: text/html, */*") },
            .{ .tag = http.HTTP_Redirects, .data = redirects_most },
            .{},
        }, &err) orelse return web.failed(hb, err);
        defer hb.CloseRequest(request);

        const status = hb.GetRequestAttr(request, http.HTTP_Status);
        if (status < 200 or status > 299) {
            const line: [*:0]const u8 = @ptrFromInt(hb.GetRequestAttr(request, http.HTTP_StatusLine));
            var length: usize = 0;
            while (line[length] != 0) length += 1;
            _ = web.say(line[0..length]);
            return null;
        }
        // Where it came from in the end, which its links are read
        // against.
        const answered: ?[*:0]const u8 = @ptrFromInt(hb.GetRequestAttr(request, http.HTTP_URL));
        if (answered) |address| {
            var length: usize = 0;
            while (address[length] != 0) length += 1;
            _ = where.take(address[0..length]);
        }

        const told = hb.GetRequestAttr(request, http.HTTP_ContentLength);
        var room: usize = if (told != http.HTTP_LENGTH_UNKNOWN and told < page_most) told + 1 else first_room;
        var page: [*]u8 = @ptrCast(web.sys.AllocVec(room, exec.MEMF_ANY) orelse {
            _ = web.say("there is no memory for the page");
            return null;
        });
        var have: usize = 0;
        while (true) {
            if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
                web.sys.FreeVec(page);
                _ = web.say("stopped");
                return null;
            }
            if (have == room) {
                if (room >= page_most) {
                    web.sys.FreeVec(page);
                    _ = web.say("the page is larger than this program shows");
                    return null;
                }
                const bigger = @min(room * 2, page_most);
                const grown: [*]u8 = @ptrCast(web.sys.AllocVec(bigger, exec.MEMF_ANY) orelse {
                    web.sys.FreeVec(page);
                    _ = web.say("there is no memory for the page");
                    return null;
                });
                @memcpy(grown[0..have], page[0..have]);
                web.sys.FreeVec(page);
                page = grown;
                room = bigger;
            }
            const got = hb.ReadRequest(request, page + have, @intCast(@min(room - have, 0x7FFF_FFFF)));
            if (got == 0) break;
            if (got < 0) {
                web.sys.FreeVec(page);
                return web.failed(hb, got);
            }
            have += @intCast(got);
        }
        if (have == 0) {
            web.sys.FreeVec(page);
            _ = web.say("the page is empty");
            return null;
        }
        return page[0..have];
    }

    /// A request that failed, said in http.library's words.
    fn failed(web: *Web, hb: *HttpBase, code: i32) ?[]u8 {
        _ = hb.Fault(web.client, code, null, &web.why, web.why.len);
        return null;
    }
};
