// SPDX-License-Identifier: MIT
//! A certificate's dates: UTCTime and GeneralizedTime as X.509 writes
//! them (RFC 5280, 4.1.2.5) - always UTC, always to the second, `Z` at
//! the end - into seconds since 1970.
//!
//! UTCTime's two-digit year is 1950 to 2049; from 2050 on certificates
//! write GeneralizedTime's four digits.

const der = @import("der.zig");

/// A Time value's seconds since 1970; null for one not in X.509's form.
pub fn read(element: der.Element) ?i64 {
    const text = element.contents;
    var year: i64 = 0;
    var at: usize = 0;
    switch (element.tag) {
        der.UTC_TIME => {
            if (text.len != 13) return null;
            const short = digits(text[0..2]) orelse return null;
            year = if (short < 50) 2000 + short else 1900 + short;
            at = 2;
        },
        der.GENERALIZED_TIME => {
            if (text.len != 15) return null;
            year = digits(text[0..4]) orelse return null;
            at = 4;
        },
        else => return null,
    }
    if (text[text.len - 1] != 'Z') return null;
    const month = digits(text[at..][0..2]) orelse return null;
    const day = digits(text[at + 2 ..][0..2]) orelse return null;
    const hour = digits(text[at + 4 ..][0..2]) orelse return null;
    const minute = digits(text[at + 6 ..][0..2]) orelse return null;
    const second = digits(text[at + 8 ..][0..2]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59) return null;
    return daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second;
}

fn digits(text: []const u8) ?i64 {
    var value: i64 = 0;
    for (text) |char| {
        if (char < '0' or char > '9') return null;
        value = value * 10 + (char - '0');
    }
    return value;
}

/// Days from 1970-01-01 to a date of the proleptic Gregorian calendar
/// (Howard Hinnant's days_from_civil).
pub fn daysFromCivil(year_in: i64, month: i64, day: i64) i64 {
    const year = if (month <= 2) year_in - 1 else year_in;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted_month = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}
