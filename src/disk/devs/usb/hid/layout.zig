// SPDX-License-Identifier: MIT
//! A mouse's report descriptor read into where its report keeps the
//! buttons, the move and the wheel: so a mouse is read by what it says
//! it sends, whatever the width of its fields - with no hardware and no
//! system, so the host tests hold it.
//!
//! The descriptor is a run of items (HID 1.11, 6.2.2). Global items set
//! the usage page, the logical minimum, a field's size and count and the
//! report ID, and stay until changed; Push and Pop save and restore them.
//! Local items name the usages of the next main item and are forgotten
//! after it; a usage of fewer than four bytes takes the page in force at
//! that main item. An Input item lays `count` fields of `size` bits into
//! the report, after the ones before it with the same report ID - and a
//! report with an ID has the ID as its first byte. Output and Feature
//! items lie in reports of their own and move nothing here.
//!
//! Inside the first application collection whose usage is the mouse
//! (Generic Desktop, Mouse), the relative X, Y and wheel and the first
//! three buttons are noted where they lie, all from the report that
//! carries the first of them. A descriptor with no such mouse, an
//! absolute X or Y, or one wider than 32 bits gives no layout; the
//! mouse is then put in its boot protocol, whose report `boot_mouse`
//! describes.

/// One field of a report.
pub const Field = struct {
    /// Where it starts, in bits from the report's first byte (the report
    /// ID, for a report that has one).
    offset: u16 = 0,
    /// Its width in bits; 0 when the report has no such field.
    size: u8 = 0,
    /// Whether it counts below zero: its logical minimum is.
    signed: bool = false,

    /// Its value in `report`; 0 when it has none or lies past the end.
    pub fn value(field: Field, report: []const u8) i32 {
        if (field.size == 0) return 0;
        const end = @as(usize, field.offset) + field.size;
        if (end > report.len * 8) return 0;
        const first = field.offset / 8;
        const last = (end - 1) / 8;
        var bits: u64 = 0;
        var at = last + 1;
        while (at > first) {
            at -= 1;
            bits = (bits << 8) | report[at];
        }
        const width: u6 = @intCast(field.size);
        const mask: u64 = (@as(u64, 1) << width) - 1;
        const raw = (bits >> @intCast(field.offset % 8)) & mask;
        if (field.signed and raw >> (width - 1) != 0) return @truncate(@as(i64, @bitCast(raw | ~mask)));
        return @truncate(@as(i64, @intCast(raw)));
    }
};

/// Where a mouse's report keeps what it says.
pub const MouseLayout = struct {
    /// The report's ID, its first byte; 0 for a mouse whose reports have
    /// none.
    report_id: u8 = 0,
    /// The left, right and middle buttons.
    buttons: [3]Field = @splat(.{}),
    x: Field = .{},
    y: Field = .{},
    wheel: Field = .{},

    /// Whether `report` is this layout's: its ID matches.
    pub fn owns(layout: *const MouseLayout, report: []const u8) bool {
        if (layout.report_id == 0) return true;
        return report.len > 0 and report[0] == layout.report_id;
    }
};

/// The boot protocol's mouse report: the buttons in the first byte, then
/// x and y as signed bytes, and the wheel in a fourth byte where there is
/// one.
pub const boot_mouse = MouseLayout{
    .buttons = .{ .{ .offset = 0, .size = 1 }, .{ .offset = 1, .size = 1 }, .{ .offset = 2, .size = 1 } },
    .x = .{ .offset = 8, .size = 8, .signed = true },
    .y = .{ .offset = 16, .size = 8, .signed = true },
    .wheel = .{ .offset = 24, .size = 8, .signed = true },
};

const PAGE_GENERIC_DESKTOP: u32 = 0x01;
const PAGE_BUTTON: u32 = 0x09;
const USAGE_MOUSE: u32 = (PAGE_GENERIC_DESKTOP << 16) | 0x02;
const USAGE_X: u32 = (PAGE_GENERIC_DESKTOP << 16) | 0x30;
const USAGE_Y: u32 = (PAGE_GENERIC_DESKTOP << 16) | 0x31;
const USAGE_WHEEL: u32 = (PAGE_GENERIC_DESKTOP << 16) | 0x38;

const ITEM_MAIN = 0;
const ITEM_GLOBAL = 1;
const ITEM_LOCAL = 2;
const MAIN_INPUT = 8;
const MAIN_COLLECTION = 10;
const MAIN_END_COLLECTION = 12;
const GLOBAL_USAGE_PAGE = 0;
const GLOBAL_LOGICAL_MIN = 1;
const GLOBAL_REPORT_SIZE = 7;
const GLOBAL_REPORT_ID = 8;
const GLOBAL_REPORT_COUNT = 9;
const GLOBAL_PUSH = 10;
const GLOBAL_POP = 11;
const LOCAL_USAGE = 0;
const LOCAL_USAGE_MIN = 1;
const LOCAL_USAGE_MAX = 2;
const COLLECTION_APPLICATION = 1;
const INPUT_CONSTANT: u32 = 1 << 0;
const INPUT_VARIABLE: u32 = 1 << 1;
const INPUT_RELATIVE: u32 = 1 << 2;
const LONG_ITEM: u8 = 0xFE;

/// The global items in force.
const Globals = struct {
    page: u32 = 0,
    logical_min: i32 = 0,
    size: u32 = 0,
    count: u32 = 0,
    report_id: u8 = 0,
};

/// The local items since the last main item.
const Locals = struct {
    /// A usage as given: four bytes carry their page, fewer take the
    /// page in force at the main item.
    usages: [16]u32 = undefined,
    whole: [16]bool = undefined,
    count: usize = 0,
    min: u32 = 0,
    max: u32 = 0,
    min_whole: bool = false,
    ranged: bool = false,

    /// The usage of the main item's field `index`: the list's, its last
    /// one repeated; or the range's, its last one repeated.
    fn usageAt(locals: *const Locals, page: u32, index: u32) u32 {
        if (locals.count > 0) {
            const at = @min(index, locals.count - 1);
            return if (locals.whole[at]) locals.usages[at] else (page << 16) | locals.usages[at];
        }
        if (!locals.ranged) return 0;
        const usage = if (locals.min + index <= locals.max) locals.min + index else locals.max;
        return if (locals.min_whole) usage else (page << 16) | usage;
    }
};

/// The bits laid so far into each report: a report ID and how far.
const Offsets = struct {
    ids: [16]u8 = undefined,
    bits: [16]u32 = undefined,
    count: usize = 0,

    /// The report's bits so far, made for a report not seen yet: after
    /// its ID byte, if it has one. Null when there are more reports than
    /// this keeps.
    fn of(offsets: *Offsets, report_id: u8) ?*u32 {
        for (offsets.ids[0..offsets.count], 0..) |id, i| {
            if (id == report_id) return &offsets.bits[i];
        }
        if (offsets.count == offsets.ids.len) return null;
        offsets.ids[offsets.count] = report_id;
        offsets.bits[offsets.count] = if (report_id != 0) 8 else 0;
        offsets.count += 1;
        return &offsets.bits[offsets.count - 1];
    }
};

/// Where `descriptor` - a report descriptor - says its mouse's report
/// keeps the buttons, the move and the wheel; null when it describes no
/// relative mouse this can read.
pub fn mouseLayout(descriptor: []const u8) ?MouseLayout {
    var globals: Globals = .{};
    var saved: [4]Globals = undefined;
    var saved_count: usize = 0;
    var locals: Locals = .{};
    var offsets: Offsets = .{};
    var layout: MouseLayout = .{};
    var have_id = false;
    var collections: u32 = 0;
    // The collection depth the mouse's collection opened at; 0 outside.
    var mouse_depth: u32 = 0;
    var at: usize = 0;
    while (at < descriptor.len) {
        const prefix = descriptor[at];
        if (prefix == LONG_ITEM) {
            if (at + 1 >= descriptor.len) break;
            at += 3 + @as(usize, descriptor[at + 1]);
            continue;
        }
        const data_size: usize = switch (prefix & 3) {
            0 => 0,
            1 => 1,
            2 => 2,
            else => 4,
        };
        if (at + 1 + data_size > descriptor.len) break;
        const bytes = descriptor[at + 1 ..][0..data_size];
        at += 1 + data_size;
        const data = unsignedOf(bytes);
        const tag = prefix >> 4;
        switch ((prefix >> 2) & 3) {
            ITEM_MAIN => {
                switch (tag) {
                    MAIN_INPUT => {
                        const offset = offsets.of(globals.report_id) orelse return null;
                        if (mouse_depth != 0 and data & (INPUT_CONSTANT | INPUT_VARIABLE) == INPUT_VARIABLE) {
                            var index: u32 = 0;
                            while (index < globals.count) : (index += 1) {
                                const usage = locals.usageAt(globals.page, index);
                                const where = offset.* + index * globals.size;
                                if (!note(&layout, &have_id, globals, usage, where, data & INPUT_RELATIVE != 0)) return null;
                            }
                        }
                        offset.* += globals.size * globals.count;
                    },
                    MAIN_COLLECTION => {
                        collections += 1;
                        if (mouse_depth == 0 and data == COLLECTION_APPLICATION and locals.usageAt(globals.page, 0) == USAGE_MOUSE) mouse_depth = collections;
                    },
                    MAIN_END_COLLECTION => {
                        if (mouse_depth != 0 and mouse_depth == collections) return finished(layout);
                        collections -|= 1;
                    },
                    else => {},
                }
                locals = .{};
            },
            ITEM_GLOBAL => switch (tag) {
                GLOBAL_USAGE_PAGE => globals.page = data,
                GLOBAL_LOGICAL_MIN => globals.logical_min = signedOf(bytes),
                GLOBAL_REPORT_SIZE => globals.size = data,
                GLOBAL_REPORT_ID => globals.report_id = @truncate(data),
                GLOBAL_REPORT_COUNT => globals.count = data,
                GLOBAL_PUSH => {
                    if (saved_count == saved.len) return null;
                    saved[saved_count] = globals;
                    saved_count += 1;
                },
                GLOBAL_POP => {
                    if (saved_count == 0) return null;
                    saved_count -= 1;
                    globals = saved[saved_count];
                },
                else => {},
            },
            ITEM_LOCAL => switch (tag) {
                LOCAL_USAGE => if (locals.count < locals.usages.len) {
                    locals.usages[locals.count] = data;
                    locals.whole[locals.count] = data_size == 4;
                    locals.count += 1;
                },
                LOCAL_USAGE_MIN => {
                    locals.min = data;
                    locals.min_whole = data_size == 4;
                    locals.ranged = true;
                },
                LOCAL_USAGE_MAX => locals.max = if (data_size == 4) data & 0xFFFF else data,
                else => {},
            },
            else => {},
        }
    }
    return if (mouse_depth != 0) finished(layout) else null;
}

/// A variable field of the mouse's collection noted if it is one of
/// those read; false for one that makes the mouse unreadable.
fn note(layout: *MouseLayout, have_id: *bool, globals: Globals, usage: u32, offset: u32, relative: bool) bool {
    const field = Field{ .offset = @truncate(offset), .size = @truncate(globals.size), .signed = globals.logical_min < 0 };
    const slot: *Field = switch (usage) {
        USAGE_X => &layout.x,
        USAGE_Y => &layout.y,
        USAGE_WHEEL => &layout.wheel,
        (PAGE_BUTTON << 16) | 1, (PAGE_BUTTON << 16) | 2, (PAGE_BUTTON << 16) | 3 => &layout.buttons[(usage & 0xFFFF) - 1],
        else => return true,
    };
    if (have_id.*) {
        if (globals.report_id != layout.report_id) return true;
    } else {
        layout.report_id = globals.report_id;
        have_id.* = true;
    }
    if (usage == USAGE_X or usage == USAGE_Y) {
        if (!relative or globals.size == 0 or globals.size > 32) return false;
    } else if (globals.size == 0 or globals.size > 32 or (usage == USAGE_WHEEL and !relative)) return true;
    if (offset > 0xFFFF) return false;
    slot.* = field;
    return true;
}

fn finished(layout: MouseLayout) ?MouseLayout {
    if (layout.x.size == 0 or layout.y.size == 0) return null;
    return layout;
}

fn unsignedOf(bytes: []const u8) u32 {
    var value: u32 = 0;
    var at = bytes.len;
    while (at > 0) {
        at -= 1;
        value = (value << 8) | bytes[at];
    }
    return value;
}

fn signedOf(bytes: []const u8) i32 {
    const value = unsignedOf(bytes);
    return switch (bytes.len) {
        1 => @as(i8, @bitCast(@as(u8, @truncate(value)))),
        2 => @as(i16, @bitCast(@as(u16, @truncate(value)))),
        else => @bitCast(value),
    };
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

/// The boot mouse's descriptor as the HID specification gives it.
const boot_descriptor = [_]u8{
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00, 0x05, 0x09,
    0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01,
    0x81, 0x02, 0x95, 0x01, 0x75, 0x05, 0x81, 0x01, 0x05, 0x01, 0x09, 0x30,
    0x09, 0x31, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x02, 0x81, 0x06,
    0xC0, 0xC0,
};

/// A wide mouse: report 1, five buttons, a 16-bit X and Y, a wheel and a
/// horizontal one (consumer page, AC Pan); then a keyboard's collection.
const wide_descriptor = [_]u8{
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x01, 0x09, 0x01, 0xA1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x95, 0x05,
    0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x03, 0x81, 0x01, 0x05, 0x01,
    0x16, 0x01, 0x80, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x02, 0x09, 0x30,
    0x09, 0x31, 0x81, 0x06, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01,
    0x09, 0x38, 0x81, 0x06, 0x05, 0x0C, 0x0A, 0x38, 0x02, 0x95, 0x01, 0x81,
    0x06, 0xC0, 0xC0, 0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x02, 0x05,
    0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95,
    0x08, 0x81, 0x02, 0xC0,
};

test "the boot mouse's own descriptor is the boot layout" {
    const layout = mouseLayout(&boot_descriptor).?;
    try testing.expectEqual(@as(u8, 0), layout.report_id);
    try testing.expectEqual(boot_mouse.buttons, layout.buttons);
    try testing.expectEqual(boot_mouse.x, layout.x);
    try testing.expectEqual(boot_mouse.y, layout.y);
    try testing.expectEqual(@as(u8, 0), layout.wheel.size);
}

test "a wide mouse: its report ID, 16-bit move and wheel" {
    const layout = mouseLayout(&wide_descriptor).?;
    try testing.expectEqual(@as(u8, 1), layout.report_id);
    try testing.expectEqual(Field{ .offset = 8, .size = 1 }, layout.buttons[0]);
    try testing.expectEqual(Field{ .offset = 10, .size = 1 }, layout.buttons[2]);
    try testing.expectEqual(Field{ .offset = 16, .size = 16, .signed = true }, layout.x);
    try testing.expectEqual(Field{ .offset = 32, .size = 16, .signed = true }, layout.y);
    try testing.expectEqual(Field{ .offset = 48, .size = 8, .signed = true }, layout.wheel);
    // Left a long way, down by one, the left button, a notch toward the user.
    const report = [_]u8{ 0x01, 0x01, 0x18, 0xFC, 0x01, 0x00, 0xFF, 0x00 };
    try testing.expect(layout.owns(&report));
    try testing.expectEqual(@as(i32, -1000), layout.x.value(&report));
    try testing.expectEqual(@as(i32, 1), layout.y.value(&report));
    try testing.expectEqual(@as(i32, -1), layout.wheel.value(&report));
    try testing.expectEqual(@as(i32, 1), layout.buttons[0].value(&report));
    try testing.expect(!layout.owns(&.{ 0x02, 0x00 }));
}

test "a field past a short report's end reads 0" {
    try testing.expectEqual(@as(i32, 0), boot_mouse.wheel.value(&.{ 0, 1, 2 }));
    try testing.expectEqual(@as(i32, -3), boot_mouse.y.value(&.{ 0, 1, 0xFD }));
}

test "no mouse, or an absolute one, gives no layout" {
    try testing.expect(mouseLayout(wide_descriptor[75..]) == null);
    var absolute = boot_descriptor;
    absolute[47] = 0x02;
    try testing.expect(mouseLayout(&absolute) == null);
    try testing.expect(mouseLayout(&.{}) == null);
}
