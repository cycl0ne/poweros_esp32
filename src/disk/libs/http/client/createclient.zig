// SPDX-License-Identifier: MIT
//! CreateClient: a client for a program's requests.

const sdk = @import("sdk");
const exec = sdk.exec;
const http = sdk.http;
const utility = sdk.utility;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const HttpBase = @import("../http_base.zig").HttpBase;
const http_init = @import("../http_init.zig");
const _client = @import("_client.zig");
const Client = _client.Client;

/// Makes a client, through which a program makes its requests and which
/// keeps their connections for the next.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateClient(base: *HttpBase, socket_base: *SocketBase, tags: ?[*]const utility.TagItem) ?*http.Client
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `socket_base`: the program's own bsdsocket.library base, which the
///   client's connections are made in.
/// - `tags`:
///   - HTTP_Verify (bool, true): the servers' certificates are checked.
///   - HTTP_UserAgent (`[*:0]const u8`): what the requests send as their
///     User-Agent; `PowerOS-http.library/1.0` unless given.
///   - HTTP_Timeout (u32, 0): the seconds a connection may stay quiet
///     before a request fails; 0 waits for as long as it takes.
///
/// RESULT:
/// The client; null when there is no memory for it.
///
/// BEHAVIOR:
/// Allocates the client and keeps the settings. No connection is made
/// until the first request.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do; its requests need the task that opened
///   `socket_base`.
///
/// OWNERSHIP:
/// The client is the caller's until DeleteClient. `socket_base` stays
/// the caller's, and open until the client is deleted. The User-Agent is
/// copied.
///
/// NOTES:
/// A User-Agent is cut at its 95th character, and before anything that
/// would end a header line.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeleteClient`, `OpenRequest`
///
/// EXAMPLES:
/// ```zig
/// const client = hb.CreateClient(sb, &[_]utility.TagItem{
///     .{ .tag = http.HTTP_Timeout, .data = 30 },
///     .{},
/// }) orelse return;
/// defer hb.DeleteClient(client);
/// ```
pub fn CreateClient(base: *HttpBase, socket_base: *SocketBase, tags: ?[*]const utility.TagItem) ?*http.Client {
    const sys = base.sys_base;
    const ub = base.utility_base;
    const memory = sys.AllocVec(@sizeOf(Client), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const client: *Client = @ptrCast(@alignCast(memory));
    client.* = .{
        .base = base,
        .socket_base = socket_base,
        .verify = ub.GetTagData(http.HTTP_Verify, 1, tags) != 0,
        .timeout = @intCast(ub.GetTagData(http.HTTP_Timeout, 0, tags)),
    };
    const given = ub.GetTagData(http.HTTP_UserAgent, 0, tags);
    const agent: [*:0]const u8 = if (given != 0) @ptrFromInt(given) else http_init.USER_AGENT;
    var count: usize = 0;
    while (count < _client.agent_most and agent[count] >= ' ' and agent[count] != 0x7F) : (count += 1) {
        client.agent[count] = agent[count];
    }
    client.agent_length = @intCast(count);
    return _client.handleOf(client);
}
