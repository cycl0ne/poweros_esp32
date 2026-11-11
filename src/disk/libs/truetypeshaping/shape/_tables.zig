// SPDX-License-Identifier: MIT
//! A layout table's bytes, and the two lists every lookup is built on.
//!
//! `Table` is a stretch of a font's bytes, big-endian, read by place. A
//! read past its end answers 0, and a part of it (`part`) that starts
//! past its end or at 0 - which is how a table says "none" - is empty, so
//! everything read of that is 0 as well. A count a table gives is cut to
//! what the table has room for (`count`) before anything is looked up by
//! it. So a damaged table makes a lookup that does nothing, never a read
//! outside the font.
//!
//! A coverage table is the list of glyphs a lookup holds for, and the
//! place of each in it (`coverage`); a class definition sorts glyphs into
//! numbered classes (`classOf`), class 0 being every glyph it does not
//! name.

/// A stretch of a font's bytes.
pub const Table = struct {
    bytes: []const u8,

    pub const none: Table = .{ .bytes = &.{} };

    /// The 16-bit number at `at`; 0 past the end.
    pub fn word(table: Table, at: u32) u32 {
        if (at >= table.bytes.len or table.bytes.len - at < 2) return 0;
        return (@as(u32, table.bytes[at]) << 8) | table.bytes[at + 1];
    }

    /// The same, signed.
    pub fn signed(table: Table, at: u32) i32 {
        const value: u16 = @intCast(table.word(at));
        return @as(i16, @bitCast(value));
    }

    /// The 32-bit number at `at`; 0 past the end.
    pub fn long(table: Table, at: u32) u32 {
        if (at >= table.bytes.len or table.bytes.len - at < 4) return 0;
        return (table.word(at) << 16) | table.word(at + 2);
    }

    /// The table from `at` on. Empty when `at` is 0 or past the end.
    pub fn part(table: Table, at: u32) Table {
        if (at == 0 or at >= table.bytes.len) return none;
        return .{ .bytes = table.bytes[at..] };
    }

    /// The part a 16-bit offset stored at `at` points to.
    pub fn partAt(table: Table, at: u32) Table {
        return table.part(table.word(at));
    }

    /// The part a 32-bit offset stored at `at` points to.
    pub fn partAtLong(table: Table, at: u32) Table {
        return table.part(table.long(at));
    }

    /// The number of records stored at `at`, cut to how many records of
    /// `size` bytes the table holds from `first` on.
    pub fn count(table: Table, at: u32, first: u32, size: u32) u32 {
        const said = table.word(at);
        if (first >= table.bytes.len) return 0;
        const room: u32 = @intCast((table.bytes.len - first) / size);
        return if (said < room) said else room;
    }

    pub fn empty(table: Table) bool {
        return table.bytes.len == 0;
    }
};

/// The place of `glyph` in a coverage table; null when it is not in it.
pub fn coverage(table: Table, glyph: u32) ?u32 {
    switch (table.word(0)) {
        1 => {
            // The glyphs themselves, in rising order.
            var low: u32 = 0;
            var high: u32 = table.count(2, 4, 2);
            while (low < high) {
                const middle = low + (high - low) / 2;
                const listed = table.word(4 + middle * 2);
                if (listed == glyph) return middle;
                if (listed < glyph) low = middle + 1 else high = middle;
            }
            return null;
        },
        2 => {
            // Ranges of glyphs: first, last, the first's place.
            var low: u32 = 0;
            var high: u32 = table.count(2, 4, 6);
            while (low < high) {
                const middle = low + (high - low) / 2;
                const range = 4 + middle * 6;
                if (glyph < table.word(range)) {
                    high = middle;
                } else if (glyph > table.word(range + 2)) {
                    low = middle + 1;
                } else {
                    return table.word(range + 4) + (glyph - table.word(range));
                }
            }
            return null;
        },
        else => return null,
    }
}

/// The class a class definition sorts `glyph` into; 0 when it names none.
pub fn classOf(table: Table, glyph: u32) u32 {
    switch (table.word(0)) {
        1 => {
            // A class for each glyph from a first one on.
            const first = table.word(2);
            if (glyph < first) return 0;
            const place = glyph - first;
            if (place >= table.count(4, 6, 2)) return 0;
            return table.word(6 + place * 2);
        },
        2 => {
            // Ranges of glyphs: first, last, their class.
            var low: u32 = 0;
            var high: u32 = table.count(2, 4, 6);
            while (low < high) {
                const middle = low + (high - low) / 2;
                const range = 4 + middle * 6;
                if (glyph < table.word(range)) {
                    high = middle;
                } else if (glyph > table.word(range + 2)) {
                    low = middle + 1;
                } else {
                    return table.word(range + 4);
                }
            }
            return 0;
        },
        else => return 0,
    }
}
