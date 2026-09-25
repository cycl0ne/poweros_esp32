// SPDX-License-Identifier: MIT
//! telnet.device: a TCP connection as a stream of bytes, with the Telnet
//! protocol (RFC 854) taken off it - what a console needs to run on the
//! network. It is in DEVS:, and C:net/ShellServer puts con-handler on it.
//!
//! **A unit is a connection.** Its number is the id a socket was left
//! under with bsdsocket.library's ReleaseSocket(fd, UNIQUE_ID): OpenDevice
//! takes the socket with ObtainSocket, so the unit can be opened once, and
//! CloseDevice closes the connection. Requests are IOStdReqs (an
//! IOExtSer, which a console opens with, is one too).
//!
//!   CMD_READ    what came, as soon as there is a byte, io_Length at the
//!               most: the Telnet commands taken out, IAC IAC as 255,
//!               CR LF and CR NUL as CR, an interrupt (IAC IP) or break
//!               (IAC BRK) as Ctrl-C. When the peer has closed the
//!               connection: IOERR_ENDOFSTREAM, now and from then on.
//!   CMD_WRITE   io_Length bytes out, 255 sent as IAC IAC; answered when
//!               the stack has taken them. IOERR_ENDOFSTREAM when the
//!               connection has gone.
//!   CMD_FLUSH   every read waiting is answered with IOERR_ABORTED.
//!
//! Anything else is IOERR_NOCMD. On opening, the unit offers to echo and
//! to go without go-ahead (WILL ECHO, WILL SUPPRESS-GO-AHEAD, DO
//! SUPPRESS-GO-AHEAD), so a client sends each key as it is typed and
//! shows only what comes back; every other option is refused.

pub const TELNETNAME = "telnet.device";
