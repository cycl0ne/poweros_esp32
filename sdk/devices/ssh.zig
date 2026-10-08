// SPDX-License-Identifier: MIT
//! ssh.device: a TCP connection that speaks SSH (RFC 4251-4254) as a
//! stream of bytes - the encryption, the login and the session channel
//! taken off it - what a console needs to run on the network. It is in
//! DEVS:, and C:net/ShellServer SSH puts con-handler on it.
//!
//! **A unit is a connection.** Its number is the id a socket was left
//! under with bsdsocket.library's ReleaseSocket(fd, UNIQUE_ID). The first
//! OpenDevice takes the socket with ObtainSocket; later ones - the
//! console's - share the unit, and the last CloseDevice closes the
//! connection. Requests are IOStdReqs (an IOExtSer, which a console opens
//! with, is one too).
//!
//!   SSHCMD_ACCEPT  io_Data: an SshAccept, the host key and who may log
//!                  in. The protocol starts: the version, the key
//!                  exchange, the login, the session channel. Answered
//!                  once the client asks for a shell or a command, with
//!                  what it asked for in the SshAccept; IOERR_ENDOFSTREAM
//!                  when it went before that, or did not log in within
//!                  two minutes.
//!   CMD_READ       what the client typed, as soon as there is a byte,
//!                  io_Length at the most; a break or an interrupt as
//!                  Ctrl-C. When the client has sent its end:
//!                  IOERR_ENDOFSTREAM, now and from then on.
//!   CMD_WRITE      io_Length bytes to the client; answered when the
//!                  channel has taken them all. IOERR_ENDOFSTREAM when the
//!                  connection has gone.
//!   SSHCMD_EXIT    io_Length: the exit status. The status is told, the
//!                  channel ended and closed; the client goes.
//!   CMD_FLUSH      every read waiting is answered with IOERR_ABORTED.
//!
//! **What it speaks**: key exchange curve25519-sha256 (RFC 8731), with
//! OpenSSH's strict key exchange; host key ssh-ed25519 (RFC 8709);
//! aes256-gcm@openssh.com and aes128-gcm@openssh.com (RFC 5647); no
//! compression. Logins by password and by ssh-ed25519 key. One session
//! channel per connection, with a shell or one command; no forwarding,
//! no sftp. The client may renew the keys at any time.

const exec = @import("../libs/exec/exec.zig");

pub const SSHNAME = "ssh.device";

/// The device's own commands.
pub const SSHCMD_ACCEPT: u16 = exec.CMD_NONSTD + 0;
pub const SSHCMD_EXIT: u16 = exec.CMD_NONSTD + 1;

/// SshAccept's `kind`: an interactive shell, or one command.
pub const SSHSESSION_SHELL: u32 = 1;
pub const SSHSESSION_EXEC: u32 = 2;

/// The most public keys and the longest password an SshAccept takes.
pub const SSH_KEYS_MAX = 16;
pub const SSH_PASSWORD_MAX = 64;

/// What SSHCMD_ACCEPT is given, and what it hands back.
pub const SshAccept = extern struct {
    /// The host key, Ed25519: its seed (the private half) and its
    /// public half (sdk/devices/ssh/keys.zig).
    host_seed: [32]u8 = @splat(0),
    host_public: [32]u8 = @splat(0),
    /// The password, `password_length` bytes, or none at 0; and the
    /// Ed25519 public keys that may log in.
    password: [SSH_PASSWORD_MAX]u8 = @splat(0),
    password_length: u32 = 0,
    keys: [SSH_KEYS_MAX][32]u8 = @splat(@splat(0)),
    key_count: u32 = 0,
    /// Back: SSHSESSION_*, the user the client logged in as, the command
    /// for SSHSESSION_EXEC, and its terminal - its type and size - when it
    /// asked for one (`columns` 0 when not).
    kind: u32 = 0,
    columns: u32 = 0,
    rows: u32 = 0,
    user: [64]u8 = @splat(0),
    terminal: [32]u8 = @splat(0),
    command: [512]u8 = @splat(0),
};

/// The host key's file, the authorized keys and the public key's line
/// (sdk/devices/ssh/keys.zig).
pub const keys = @import("ssh/keys.zig");
