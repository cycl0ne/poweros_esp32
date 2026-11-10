// SPDX-License-Identifier: MIT
//! The SMB 2/3 client, as the `smbclient` module: everything a program
//! needs to reach a share on a server, and the files that say where the
//! shares are. Compiled into each program that imports it - the handler
//! that serves a share, the tool that mounts one, the tool that lists
//! what a server has - so that the protocol is written once.
//!
//! **The protocol**, from the bottom up:
//!
//! | File | What it holds |
//! |------|---------------|
//! | `wire.zig` | the message header and the readers and writers its fields are made of |
//! | `connection.zig` | the TCP connection and SMB's framing over it |
//! | `signing.zig` | the signatures of each dialect, and the hash of a negotiation |
//! | `crypt.zig` | the session's keys and the transform header a sealed message carries |
//! | `session.zig` | a session and every request made in it, compounds, credits and the requests sent ahead |
//! | `negotiate.zig` | NEGOTIATE: the dialect, the ciphers and what the server can do |
//! | `ntlm.zig`, `spnego.zig` | NTLMv2 and the token it is carried in |
//! | `logon.zig` | SESSION_SETUP and TREE_CONNECT |
//! | `commands.zig` | CREATE, READ, WRITE, QUERY_DIRECTORY, QUERY_INFO, SET_INFO, IOCTL, ECHO, CLOSE |
//! | `names.zig` | names between UTF-8 and the UTF-16 the protocol speaks |
//! | `rpc.zig` | DCE/RPC over a named pipe, and the NDR its arguments are in |
//! | `shares.zig` | the shares a server has, asked of `srvsvc` |
//! | `browse.zig` | a session brought up from nothing: connect, negotiate, log on, and the share or the shares |
//!
//! **The files** that say where a share is: `place.zig` reads
//! `//server/share`, and `sharefile.zig` the keywords of
//! `DEVS:Shares/<NAME>` and the password kept beside it.

pub const wire = @import("wire.zig");
pub const connection = @import("connection.zig");
pub const signing = @import("signing.zig");
pub const crypt = @import("crypt.zig");
pub const session = @import("session.zig");
pub const negotiate = @import("negotiate.zig");
pub const ntlm = @import("ntlm.zig");
pub const spnego = @import("spnego.zig");
pub const logon = @import("logon.zig");
pub const commands = @import("commands.zig");
pub const names = @import("names.zig");
pub const rpc = @import("rpc.zig");
pub const shares = @import("shares.zig");
pub const browse = @import("browse.zig");
pub const place = @import("place.zig");
pub const sharefile = @import("sharefile.zig");

/// The session and its connection, the two the rest is built on.
pub const Session = session.Session;
pub const Connection = connection.Connection;

/// The stack a session's work wants, where it does not run on a process
/// of its own with room set aside for it: a logon derives its keys and a
/// share list carries the buffers the question and the answer are read
/// in, which together go deeper than the stack a command is run on. A
/// program that logs on from a shell command or a window's input loop
/// allocates this much through exec's `NewStackRun` and does the work
/// there.
pub const stack_bytes: u32 = 48 * 1024;

// The files' own tests, for the module's test run; those that need
// crypto.library are in tests/.
test {
    _ = commands;
    _ = names;
    _ = place;
    _ = rpc;
    _ = sharefile;
    _ = shares;
    _ = spnego;
    _ = wire;
}
