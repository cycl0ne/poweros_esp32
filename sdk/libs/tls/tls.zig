// SPDX-License-Identifier: MIT
//! tls.library's structures and constants: the session a program reads
//! and writes through, the tags it is opened with, the attributes it
//! answers, and the error codes. The calls are in `sdk.interface.tls`.
//!
//! A session is TLS 1.3 - or TLS 1.2 with a server that speaks nothing
//! newer - over a stream socket the program connected, in
//! the program's own bsdsocket.library base: OpenSession does the
//! handshake and checks the server's certificates against the system's
//! trusted roots (`SYS:Certificates/Roots`) and the program's own
//! (`ENVARC:Sys/net/certificates/`, PEM files); ReadSession and
//! WriteSession then carry plain bytes; CloseSession says goodbye and
//! frees the session. The socket stays the program's throughout, to
//! WaitSelect on and to close.

const utility = @import("../utility/utility.zig");

/// The library's name, for OpenLibrary.
pub const TLSNAME = "tls.library";

/// A session: what OpenSession makes. Only tls.library knows what is in
/// it.
pub const Session = opaque {};

// --- tags ---------------------------------------------------------------------

pub const TLS_Dummy = utility.TAG_USER + 0x60400;
/// `[*:0]const u8`: the server's name - sent to it (SNI) and checked
/// against its certificate. Required.
pub const TLS_Host = TLS_Dummy + 0x01;
/// Bool: the server's certificates are checked (true). False leaves
/// only its CertificateVerify and Finished checked - for a test, never
/// for anything that matters.
pub const TLS_Verify = TLS_Dummy + 0x02;
/// `[*:0]const u8`: an application protocol to ask for by ALPN
/// (`http/1.1`), or none. GetSessionAttr: the one the server chose, or
/// an empty string.
pub const TLS_Protocol = TLS_Dummy + 0x03;
/// `*u32`: where OpenSession puts the certificate check's TLSV_*, also
/// when it fails - there is no session to ask then.
pub const TLS_GetVerdict = TLS_Dummy + 0x04;
/// `*u32`: where OpenSession puts the alert the server refused with, or
/// 0.
pub const TLS_GetAlert = TLS_Dummy + 0x05;
/// GetSessionAttr only: the protocol's version, 0x0304 for TLS 1.3 or
/// 0x0303 for TLS 1.2.
pub const TLS_Version = TLS_Dummy + 0x10;
/// GetSessionAttr only: the cipher suite's number (0x1301, 0x1302; TLS
/// 1.2's 0xC02B, 0xC02F, 0xC02C, 0xC030).
pub const TLS_Suite = TLS_Dummy + 0x11;
/// GetSessionAttr only: what the certificate check said, a TLSV_*.
pub const TLS_Verdict = TLS_Dummy + 0x12;
/// GetSessionAttr only: the alert the server ended the session with, or
/// 0.
pub const TLS_Alert = TLS_Dummy + 0x13;
/// GetSessionAttr only: the last TLSERR_* of the session.
pub const TLS_Error = TLS_Dummy + 0x14;

// --- errors -------------------------------------------------------------------

/// What OpenSession puts where `err` points, and what ReadSession and
/// WriteSession answer below zero.
pub const TLSERR_OK: i32 = 0;
/// No memory for the session.
pub const TLSERR_NOMEM: i32 = -1;
/// The socket failed, or the server closed it in the middle of a
/// handshake or a record; bsdsocket's Errno says more.
pub const TLSERR_IO: i32 = -2;
/// The clock is not set, so no certificate's dates can be checked:
/// TimeSync first, or TLS_Verify off.
pub const TLSERR_CLOCK: i32 = -3;
/// The server's certificates were not trusted: TLS_Verdict says why.
pub const TLSERR_CERTIFICATE: i32 = -4;
/// The handshake failed: no version, cipher suite or key share in
/// common, a signature or a Finished message that did not check, a
/// record that did not decrypt, a message out of its place.
pub const TLSERR_HANDSHAKE: i32 = -5;
/// The server ended the session with an alert: TLS_Alert says which.
pub const TLSERR_ALERT: i32 = -6;
/// No TLS_Host given.
pub const TLSERR_HOST: i32 = -7;
/// crypto.library could not be opened.
pub const TLSERR_CRYPTO: i32 = -8;

// --- the certificate check ----------------------------------------------------

/// TLS_Verdict: what the check of the server's certificates said.
pub const TLSV_TRUSTED: u32 = 0;
/// A certificate that could not be read.
pub const TLSV_MALFORMED: u32 = 1;
/// No path to a trusted root.
pub const TLSV_UNKNOWN_ISSUER: u32 = 2;
/// An issuer whose key did not check a signature.
pub const TLSV_BAD_SIGNATURE: u32 = 3;
/// An algorithm or a key of a kind there is no check for.
pub const TLSV_UNSUPPORTED: u32 = 4;
pub const TLSV_EXPIRED: u32 = 5;
pub const TLSV_NOT_YET_VALID: u32 = 6;
/// An issuer that is not a CA, or may not sign certificates.
pub const TLSV_NOT_CA: u32 = 7;
pub const TLSV_PATH_LENGTH: u32 = 8;
/// A CA with name constraints, which are not checked.
pub const TLSV_NAME_CONSTRAINTS: u32 = 9;
/// The server's certificate is not for serving TLS.
pub const TLSV_WRONG_USAGE: u32 = 10;
/// The server's certificate does not name the host.
pub const TLSV_WRONG_NAME: u32 = 11;
pub const TLSV_TOO_LONG: u32 = 12;
