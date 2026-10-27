// SPDX-License-Identifier: MIT
//! A line of settings, read a pair at a time by NextSetting - the form the
//! settings files in ENV:Sys are written in:
//!
//!     ICONSIZE=48 PICTURE="SYS:Prefs/Sea Side.png" VIEW NAME
//!
//! Blanks (spaces, tabs, carriage returns and line feeds) part the pairs.
//! A pair is `KEY=value`, or `KEY value` with spaces or tabs between. The
//! key ends at a blank or an '='. A value in double quotes runs to the
//! next quote, blanks and '=' in it - there are no escapes - and a value
//! not in quotes to the next blank. `KEY=` before a blank, or a key alone
//! at the end, has an empty value.

/// What NextSetting reads from and what it read. The caller sets `text`
/// and `length` and leaves `at` 0; each call moves `at` past the pair it
/// read and points `key` and `value` at it in the text.
pub const SettingScan = extern struct {
    /// The line; it need not end with a NUL, and may hold several lines.
    text: [*]const u8,
    length: usize,
    /// Where the next pair is looked for.
    at: usize = 0,
    /// The pair read last, in `text`: the value without its quotes.
    key: ?[*]const u8 = null,
    key_length: usize = 0,
    value: ?[*]const u8 = null,
    value_length: usize = 0,

    /// The key read last.
    pub fn keyText(scan: *const SettingScan) []const u8 {
        const key = scan.key orelse return &.{};
        return key[0..scan.key_length];
    }

    /// The value read last.
    pub fn valueText(scan: *const SettingScan) []const u8 {
        const value = scan.value orelse return &.{};
        return value[0..scan.value_length];
    }
};
