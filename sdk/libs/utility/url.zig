// SPDX-License-Identifier: MIT
//! A URL taken apart in place, and the `%XX` escapes of its parts: what
//! ParseUrl answers, and what it and EncodeUrl are told.
//!
//! ParseUrl copies nothing and decodes nothing: each part is where it
//! lies in the text, its offset and its length (`UrlPart.of` hands the
//! slice out), so a part is still escaped as the URL writes it. A user
//! and a password go through DecodeUrl before they are used; a path is
//! sent on as it is.

/// A part of a URL: where it starts in the text, and its bytes - 0 when
/// the URL has none.
pub const UrlPart = extern struct {
    offset: u32 = 0,
    length: u32 = 0,

    /// The part's bytes in `text`, the text ParseUrl was given.
    pub fn of(part: UrlPart, text: []const u8) []const u8 {
        return text[part.offset..][0..part.length];
    }
};

/// A URL's parts, as ParseUrl finds them in
/// `scheme://[user[:password]@]host[:port][/path][?query][#fragment]`,
/// or in `[user@]host:path` with URLF_SCP.
pub const UrlParts = extern struct {
    /// Without its `://`; none in the scp form.
    scheme: UrlPart = .{},
    /// Up to the first `:` before the last `@` of the authority; the
    /// password is the rest of it. URLF_USER and URLF_PASSWORD say they
    /// were given, as either may be empty.
    user: UrlPart = .{},
    password: UrlPart = .{},
    /// A name or an address; an IPv6 address without its brackets, and
    /// URLF_BRACKETS set.
    host: UrlPart = .{},
    /// From the `/` or the `?` after the authority to a `#` or the end,
    /// the query with it; the fragment is no part. In the scp form, all
    /// after the colon. Its offset is where the authority ends, even when
    /// the path is empty.
    path: UrlPart = .{},
    /// 1 to 65535; 0 when the URL names none.
    port: u32 = 0,
    /// URLF_USER, URLF_PASSWORD, URLF_BRACKETS, URLF_SCP.
    flags: u32 = 0,
};

/// ParseUrl: `[user@]host:path`, with no scheme, is taken too - a colon
/// with no `/` before it, and not followed by `//`. In UrlParts.flags:
/// that form was read.
pub const URLF_SCP: u32 = 1 << 0;
/// In UrlParts.flags: the URL gives a user (`user@`), a password
/// (`user:password@`).
pub const URLF_USER: u32 = 1 << 1;
pub const URLF_PASSWORD: u32 = 1 << 2;
/// In UrlParts.flags: the host is in brackets, an IPv6 address.
pub const URLF_BRACKETS: u32 = 1 << 3;

/// EncodeUrl: a `/` kept as it is - a whole path, its segments encoded.
pub const URLF_SLASH: u32 = 1 << 4;
/// EncodeUrl: the text is Latin-1, each character past ASCII encoded as
/// its two bytes of UTF-8.
pub const URLF_LATIN1: u32 = 1 << 5;

/// What DecodeUrl answers for a `%` that is not followed by two hex
/// digits.
pub const URL_BROKEN: usize = ~@as(usize, 0);
