// SPDX-License-Identifier: MIT
//! ssh.device: a TCP connection that speaks SSH (RFC 4251-4254) as a
//! stream of bytes - the encryption, the login and the session channel
//! taken off it - either end of it: the server's, which a console needs
//! to run on the network, and the client's, for a shell elsewhere. It is
//! in DEVS:; C:net/ShellServer SSH puts con-handler on the server's end,
//! and C:net/SSH is the client.
//!
//! **A unit is a connection.** Its number is the id a socket was left
//! under with bsdsocket.library's ReleaseSocket(fd, UNIQUE_ID) - one the
//! server accepted, or one the client connected. The first OpenDevice
//! takes the socket with ObtainSocket; later ones - the console's - share
//! the unit, and the last CloseDevice closes the connection. The first
//! command decides which end the unit is: SSHCMD_ACCEPT the server's,
//! SSHCMD_CONNECT the client's. Requests are IOStdReqs (an IOExtSer,
//! which a console opens with, is one too); the device's own commands are
//! numbered clear of serial.device's, which a console may ask.
//!
//! **The server's end:**
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
//!   SDCMD_TERMSIZE io_Actual, io_Offset: the client's terminal's columns
//!                  and rows, as it said them and as its window changed;
//!                  IOERR_NOCMD when it asked for no terminal.
//!   CMD_FLUSH      every read waiting is answered with IOERR_ABORTED.
//!
//! **The client's end**, its commands one after another, each answered
//! once its step is over. Whenever the connection has gone first, the
//! answer is IOERR_ENDOFSTREAM, with io_Actual the reason (SSH_DISCONNECT_*:
//! the server's, or ours).
//!
//!   SSHCMD_CONNECT io_Data: an SshConnect. The version lines and the key
//!                  exchange; answered once the keys are in use, with the
//!                  server's host key in it - the server has shown it
//!                  holds that key, and whether the key is the right one
//!                  is the caller's to decide before it logs in.
//!   SSHCMD_LOGIN   io_Data: an SshLogin, the user and the ways to log in:
//!                  an Ed25519 key, a password, or both - or neither,
//!                  which asks the server what it takes. The key is tried
//!                  first. 0 once logged in; SSHERR_LOGIN when every way
//!                  given was refused, with the ways the server still
//!                  takes in its `methods` - and SSHCMD_LOGIN may come
//!                  again with others. Either way, with the banner the
//!                  server sent meanwhile, if it sent one.
//!   SSHCMD_SESSION io_Data: an SshSession, a command or a shell, and a
//!                  terminal. 0 once it runs, io_Actual 1 when it has the
//!                  terminal; SSHERR_SESSION when the server refused it.
//!   CMD_READ       what the session printed, its errors among it, as
//!                  soon as there is a byte; IOERR_ENDOFSTREAM once the
//!                  server has sent its end.
//!   CMD_WRITE      io_Length bytes to the session, as for the server.
//!   SSHCMD_EOF     the end of the session's input, told once the writes
//!                  before it have gone.
//!   SSHCMD_WINDOW  io_Length, io_Offset: the terminal's new columns and
//!                  rows.
//!   SSHCMD_STATUS  answered once the session is over: io_Actual its exit
//!                  status; IOERR_ENDOFSTREAM and 255 when it told none.
//!
//! A command out of its order is answered with SSHERR_ORDER.
//!
//! **What it speaks**, either end: key exchange mlkem768x25519-sha256 -
//! ML-KEM-768 with X25519, safe from a quantum computer - or
//! curve25519-sha256 (RFC 8731), with OpenSSH's strict key exchange; host
//! key ssh-ed25519 (RFC 8709); aes256-gcm@openssh.com and
//! aes128-gcm@openssh.com (RFC 5647); no compression. Logins by password
//! and by ssh-ed25519 key. One session channel per connection, with a
//! shell or one command; no forwarding, no sftp. The peer may renew the
//! keys at any time.

const exec = @import("../libs/exec/exec.zig");

pub const SSHNAME = "ssh.device";

/// The device's own commands, past serial.device's.
pub const SSHCMD_ACCEPT: u16 = exec.CMD_NONSTD + 16;
pub const SSHCMD_EXIT: u16 = exec.CMD_NONSTD + 17;
pub const SSHCMD_CONNECT: u16 = exec.CMD_NONSTD + 18;
pub const SSHCMD_LOGIN: u16 = exec.CMD_NONSTD + 19;
pub const SSHCMD_SESSION: u16 = exec.CMD_NONSTD + 20;
pub const SSHCMD_EOF: u16 = exec.CMD_NONSTD + 21;
pub const SSHCMD_WINDOW: u16 = exec.CMD_NONSTD + 22;
pub const SSHCMD_STATUS: u16 = exec.CMD_NONSTD + 23;

/// The device's own errors (io_Error).
pub const SSHERR_LOGIN: i8 = 1;
pub const SSHERR_SESSION: i8 = 2;
pub const SSHERR_ORDER: i8 = 3;

/// Why a connection ended (RFC 4253, 11.1): an IOERR_ENDOFSTREAM's
/// io_Actual on the client's end.
pub const SSH_DISCONNECT_PROTOCOL_ERROR: u32 = 2;
pub const SSH_DISCONNECT_KEY_EXCHANGE_FAILED: u32 = 3;
pub const SSH_DISCONNECT_MAC_ERROR: u32 = 5;
pub const SSH_DISCONNECT_SERVICE_NOT_AVAILABLE: u32 = 7;
pub const SSH_DISCONNECT_PROTOCOL_VERSION_NOT_SUPPORTED: u32 = 8;
pub const SSH_DISCONNECT_HOST_KEY_NOT_VERIFIABLE: u32 = 9;
pub const SSH_DISCONNECT_CONNECTION_LOST: u32 = 10;
pub const SSH_DISCONNECT_BY_APPLICATION: u32 = 11;
pub const SSH_DISCONNECT_NO_MORE_AUTH_METHODS_AVAILABLE: u32 = 14;

/// SshConnect's `kex`: the key exchange the keys came from.
pub const SSHKEX_MLKEM768X25519: u32 = 1;
pub const SSHKEX_CURVE25519: u32 = 2;

/// SshAccept's `kind`: an interactive shell, or one command.
pub const SSHSESSION_SHELL: u32 = 1;
pub const SSHSESSION_EXEC: u32 = 2;

/// The most public keys and the longest password an SshAccept takes.
pub const SSH_KEYS_MAX = 16;
pub const SSH_PASSWORD_MAX = 64;
/// The most of a server's banner an SshLogin brings back.
pub const SSH_BANNER_MAX = 2048;

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

/// What SSHCMD_CONNECT hands back.
pub const SshConnect = extern struct {
    /// The server's host key, Ed25519, and SSHKEX_*.
    host_public: [32]u8 = @splat(0),
    kex: u32 = 0,
};

/// What SSHCMD_LOGIN is given, and on a refusal hands back.
pub const SshLogin = extern struct {
    /// The user, NUL-terminated.
    user: [64]u8 = @splat(0),
    /// The Ed25519 key to log in with, when `key_given` is 1: its seed
    /// and its public half, as the key file holds them.
    key_seed: [32]u8 = @splat(0),
    key_public: [32]u8 = @splat(0),
    key_given: u32 = 0,
    /// The password, `password_length` bytes, or none at 0.
    password: [SSH_PASSWORD_MAX]u8 = @splat(0),
    password_length: u32 = 0,
    /// Back with SSHERR_LOGIN: the ways the server still takes, a
    /// name-list ("publickey,password"), NUL-terminated.
    methods: [128]u8 = @splat(0),
    /// Back: the banner the server sent since the last SSHCMD_LOGIN -
    /// text for the user, UTF-8, NUL-terminated, as the server sent it,
    /// so control characters and all: the caller shows it without them.
    /// Empty when none came.
    banner: [SSH_BANNER_MAX]u8 = @splat(0),
};

/// What SSHCMD_SESSION is given.
pub const SshSession = extern struct {
    /// The command, NUL-terminated; empty for a shell.
    command: [512]u8 = @splat(0),
    /// The terminal's type ("xterm-256color"), NUL-terminated, and its
    /// size; an empty type for no terminal.
    terminal: [32]u8 = @splat(0),
    columns: u32 = 0,
    rows: u32 = 0,
};

/// The host key's file, the authorized keys and the public key's line
/// (sdk/devices/ssh/keys.zig).
pub const keys = @import("ssh/keys.zig");
