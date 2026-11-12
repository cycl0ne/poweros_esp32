// SPDX-License-Identifier: MIT
//! The order a list of names is shown in: the default locale's, where
//! locale.library is there, and Unicode's folding without it.
//!
//! A program that sorts names for a reader - a directory's, a list's
//! rows, a sheet's column - opens an `Order` for the sort and asks it
//! which of two texts comes first. With locale.library that is the
//! language's order of letters, case and accents deciding only between
//! texts that are otherwise the same (`SC_COLLATE2`): `Äpfel` beside
//! `Apfel` in German, `å` after `z` in Swedish. Without the library, or
//! without a default locale, it is the order of the folded code points,
//! which is what the ROM's own lists use.
//!
//! The locale is the default one at the moment the `Order` is opened, so
//! a program that runs on opens one for each sort and follows a change of
//! the settings with the next.

const exec = @import("../exec/exec.zig");
const locale = @import("locale.zig");
const unicode = @import("../utility/unicode.zig");
const utf8 = @import("../utility/utf8.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const LocaleBase = @import("../../interface/locale.zig").LocaleBase;

/// The most bytes of a text given by its length that are compared in the
/// locale's order: a name of a file system fits.
pub const room = 256;

pub const Order = struct {
    lb: ?*LocaleBase = null,
    loc: ?*locale.Locale = null,

    /// The default locale's order, or folding's when there is no
    /// locale.library to open or no default locale.
    pub fn open(sys: *ExecBase) Order {
        const library = sys.OpenLibrary(locale.LOCALENAME, 0) orelse return .{};
        const lb: *LocaleBase = @ptrCast(@alignCast(library));
        const loc = lb.OpenLocale(null) orelse {
            sys.CloseLibrary(library);
            return .{};
        };
        return .{ .lb = lb, .loc = loc };
    }

    /// The locale and the library given back; the order is folding's
    /// from then on.
    pub fn close(order: *Order, sys: *ExecBase) void {
        const lb = order.lb orelse return;
        lb.CloseLocale(order.loc);
        sys.CloseLibrary(lb.lib());
        order.* = .{};
    }

    /// Below 0 when `a` comes before `b`, above when after, 0 when they
    /// are the same text.
    pub fn compareZ(order: *const Order, a: [*:0]const u8, b: [*:0]const u8) i32 {
        const lb = order.lb orelse return unicode.compareFolded(span(a), span(b));
        return lb.StrnCmp(order.loc.?, a, b, -1, locale.SC_COLLATE2);
    }

    /// The same for two texts given by their lengths. Texts of `room`
    /// bytes or more are compared by what of each fits, cut after a
    /// whole character, and by folding when that is the same.
    pub fn compare(order: *const Order, a: []const u8, b: []const u8) i32 {
        if (order.lb == null) return unicode.compareFolded(a, b);
        var one: [room]u8 = undefined;
        var two: [room]u8 = undefined;
        const whole_one = ended(&one, a);
        const whole_two = ended(&two, b);
        const whole = whole_one and whole_two;
        const found = order.compareZ(@ptrCast(&one), @ptrCast(&two));
        if (found != 0 or whole) return found;
        return unicode.compareFolded(a, b);
    }
};

/// `text` in `into` with a NUL after it: true when all of it fitted.
fn ended(into: *[room]u8, text: []const u8) bool {
    const most: usize = room - 1;
    const length: usize = if (text.len > most) utf8.cut(text, most) else text.len;
    @memcpy(into[0..length], text[0..length]);
    into[length] = 0;
    return length == text.len;
}

fn span(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}
