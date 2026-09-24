// SPDX-License-Identifier: MIT
//! Where a part's line is. A line is not always on a pad of the chip: it
//! may be a pin of the IO expander, reached over I2C, or something the
//! part does for itself (a controller's command). So a line is a kind and
//! a number, and kind NONE says the part has no such line - which a bare
//! pad number cannot, since pad 0 is a real pad.
//!
//! In a tag list a line is the `ti_Data` of its tag, the four bytes of a
//! `BoardPin` read as one word: `data` and `of` convert.

/// No line.
pub const BPIN_NONE: u8 = 0;
/// `number` is a pad of the chip.
pub const BPIN_GPIO: u8 = 1;
/// `number` is a pin of expander.resource.
pub const BPIN_EXPANDER: u8 = 2;
/// The part's own, whatever that means to its driver.
pub const BPIN_DRIVER: u8 = 3;

pub const BoardPin = extern struct {
    kind: u8 = BPIN_NONE,
    number: u8 = 0,
    /// The line is asserted low.
    active_low: u8 = 0,
    pad: u8 = 0,

    /// The line as a tag's `ti_Data`.
    pub fn data(pin: BoardPin) usize {
        return @as(u32, @bitCast(pin));
    }

    /// The line a tag's `ti_Data` names.
    pub fn of(value: usize) BoardPin {
        return @bitCast(@as(u32, @truncate(value)));
    }

    /// Whether there is a line at all.
    pub fn wired(pin: BoardPin) bool {
        return pin.kind != BPIN_NONE;
    }
};

/// A pad of the chip, as a tag's `ti_Data`.
pub fn gpio(pad: u8) usize {
    return (BoardPin{ .kind = BPIN_GPIO, .number = pad }).data();
}

/// A pin of the IO expander, as a tag's `ti_Data`.
pub fn expander(pin: u8) usize {
    return (BoardPin{ .kind = BPIN_EXPANDER, .number = pin }).data();
}

/// A line the part's driver works itself, as a tag's `ti_Data`.
pub fn driver(number: u8) usize {
    return (BoardPin{ .kind = BPIN_DRIVER, .number = number }).data();
}

/// The same, asserted low.
pub fn gpioLow(pad: u8) usize {
    return (BoardPin{ .kind = BPIN_GPIO, .number = pad, .active_low = 1 }).data();
}

pub fn expanderLow(pin: u8) usize {
    return (BoardPin{ .kind = BPIN_EXPANDER, .number = pin, .active_low = 1 }).data();
}
