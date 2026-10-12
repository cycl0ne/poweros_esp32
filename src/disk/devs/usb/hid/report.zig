// SPDX-License-Identifier: MIT
//! A report into events: what a keyboard's or a mouse's report means,
//! with no hardware and no system, so the host tests hold it.
//!
//! **A keyboard's report** is read where its layout says the keys lie
//! (layout.zig: the keyboard's own descriptor, or the boot protocol's
//! report - the modifier byte, a reserved byte, six slots): each bit set
//! in a run of key bits, and each slot's usage, is a key held down. The
//! keys' usages become the set of rawkeys held down, which is compared
//! with the last report's set: a rawkey in the new set only went down,
//! one in the old only went up. Comparing rawkeys rather than usages lets
//! two keys that are one rawkey - the left and right Control - hold it
//! down together. A report of "too many keys" (a slot of usage 0x01), or
//! of another ID, changes nothing.
//!
//! **A mouse's report** is read where its layout says the buttons, the
//! move and the wheel lie (layout.zig: the mouse's own descriptor, or the
//! boot protocol's report): a move by that much, each button that
//! changed, and the wheel's notches. A report of another ID is not the
//! mouse's and means nothing here.

const sdk = @import("sdk");
const ie = sdk.devices.inputevent;
const InputEvent = ie.InputEvent;
const layout_file = @import("layout.zig");
const MouseLayout = layout_file.MouseLayout;
const KeyboardLayout = layout_file.KeyboardLayout;
const Field = layout_file.Field;

/// No rawkey for this usage.
const none: u8 = 0xFF;

/// The keyboard page's usages (HID usage tables, page 7) as rawkeys: a
/// key's place, which a keymap gives its meaning.
pub const from_usage: [256]u8 = blk: {
    var t: [256]u8 = @splat(none);
    // a to z.
    const letters = [26]u8{ 0x20, 0x35, 0x33, 0x22, 0x12, 0x23, 0x24, 0x25, 0x17, 0x26, 0x27, 0x28, 0x37, 0x36, 0x18, 0x19, 0x10, 0x13, 0x21, 0x14, 0x16, 0x34, 0x11, 0x32, 0x15, 0x31 };
    for (letters, 0..) |rawkey, i| t[0x04 + i] = rawkey;
    // 1 to 9 and 0.
    for (0..10) |i| t[0x1E + i] = @intCast(0x01 + i);
    const pairs = [_][2]u8{
        .{ 0x28, 0x44 }, .{ 0x29, 0x45 }, .{ 0x2A, 0x41 }, .{ 0x2B, 0x42 }, .{ 0x2C, 0x40 },
        .{ 0x2D, 0x0B }, .{ 0x2E, 0x0C }, .{ 0x2F, 0x1A }, .{ 0x30, 0x1B }, .{ 0x31, 0x0D },
        // The key left of Return on an international keyboard, and the
        // one right of the left Shift.
        .{ 0x32, 0x2B }, .{ 0x64, 0x30 }, .{ 0x33, 0x29 }, .{ 0x34, 0x2A }, .{ 0x35, 0x00 },
        .{ 0x36, 0x38 }, .{ 0x37, 0x39 }, .{ 0x38, 0x3A }, .{ 0x39, 0x62 },
        // F1 to F10, F11, F12.
        .{ 0x3A, 0x50 },
        .{ 0x3B, 0x51 }, .{ 0x3C, 0x52 }, .{ 0x3D, 0x53 }, .{ 0x3E, 0x54 }, .{ 0x3F, 0x55 },
        .{ 0x40, 0x56 }, .{ 0x41, 0x57 }, .{ 0x42, 0x58 }, .{ 0x43, 0x59 }, .{ 0x44, 0x4B },
        .{ 0x45, 0x6F },
        // Insert, Home, Page Up, Delete, End, Page Down, the cursor keys.
        .{ 0x49, 0x47 }, .{ 0x4A, 0x70 }, .{ 0x4B, 0x48 }, .{ 0x4C, 0x46 },
        .{ 0x4D, 0x71 }, .{ 0x4E, 0x49 }, .{ 0x4F, 0x4E }, .{ 0x50, 0x4F }, .{ 0x51, 0x4D },
        .{ 0x52, 0x4C },
        // The keypad: / * - + Enter 1-9 0 .
        .{ 0x54, 0x5C }, .{ 0x55, 0x5D }, .{ 0x56, 0x4A }, .{ 0x57, 0x5E },
        .{ 0x58, 0x43 }, .{ 0x59, 0x1D }, .{ 0x5A, 0x1E }, .{ 0x5B, 0x1F }, .{ 0x5C, 0x2D },
        .{ 0x5D, 0x2E }, .{ 0x5E, 0x2F }, .{ 0x5F, 0x3D }, .{ 0x60, 0x3E }, .{ 0x61, 0x3F },
        .{ 0x62, 0x0F }, .{ 0x63, 0x3C },
        // Help.
        .{ 0x75, 0x5F },
    };
    for (pairs) |p| t[p[0]] = p[1];
    break :blk t;
};

/// The modifier byte's bits as rawkeys: left Control, Shift, Alt, GUI,
/// then the right ones. Both Controls are the one Control; the GUI keys
/// are the Amiga keys.
pub const modifier_keys = [8]u8{ 0x63, 0x60, 0x64, 0x66, 0x63, 0x61, 0x65, 0x67 };

/// Caps Lock's rawkey.
pub const RAWKEY_CAPSLOCK: u8 = 0x62;

/// The rawkeys a keyboard holds down: a bit each.
pub const KeySet = struct {
    bits: [4]u32 = @splat(0),

    pub fn add(set: *KeySet, rawkey: u8) void {
        set.bits[rawkey >> 5] |= @as(u32, 1) << @intCast(rawkey & 31);
    }

    pub fn has(set: *const KeySet, rawkey: u8) bool {
        return set.bits[rawkey >> 5] & (@as(u32, 1) << @intCast(rawkey & 31)) != 0;
    }
};

/// The keyboard page's usage a slot holds when more keys are down than
/// the report has room for.
const usage_rollover: u32 = 0x01;

/// What a keyboard report read by `layout` holds down; null for a report
/// of "too many keys", which says nothing about which, and for one that
/// is not the layout's.
pub fn keysOf(layout: *const KeyboardLayout, report: []const u8) ?KeySet {
    if (!layout.owns(report)) return null;
    var set: KeySet = .{};
    for (layout.bits[0..layout.bits_count]) |run| {
        var index: u16 = 0;
        while (index < run.count) : (index += 1) {
            const bit = Field{ .offset = run.offset + index, .size = 1 };
            if (bit.value(report) != 0) addUsage(&set, @as(u32, run.first_usage) + index);
        }
    }
    const slots = layout.slots;
    var index: u32 = 0;
    while (slots.size != 0 and index < slots.count) : (index += 1) {
        const slot = Field{ .offset = @intCast(slots.offset + index * slots.size), .size = slots.size, .signed = slots.logical_min < 0 };
        const value = slot.value(report);
        if (value < slots.logical_min) continue;
        const usage = @as(u32, slots.first_usage) + @as(u32, @intCast(value - slots.logical_min));
        if (usage == usage_rollover) return null;
        addUsage(&set, usage);
    }
    return set;
}

/// A key held down, by its keyboard page usage: a modifier's rawkey, or
/// the one `from_usage` gives.
fn addUsage(set: *KeySet, usage: u32) void {
    if (usage >= 0xE0 and usage <= 0xE7) return set.add(modifier_keys[usage - 0xE0]);
    if (usage >= from_usage.len) return;
    const rawkey = from_usage[usage];
    if (rawkey != none) set.add(rawkey);
}

/// The events from `old` to `new`, into `out`: key-ups first, then
/// key-downs, each a RAWKEY event. How many.
pub fn keyEvents(old: KeySet, new: KeySet, out: []InputEvent) usize {
    var count: usize = 0;
    var rawkey: u32 = 0;
    while (rawkey < 128) : (rawkey += 1) {
        const key: u8 = @intCast(rawkey);
        if (old.has(key) and !new.has(key) and count < out.len) {
            out[count] = .{ .class = ie.IECLASS_RAWKEY, .code = rawkey | ie.IECODE_UP_PREFIX };
            count += 1;
        }
    }
    rawkey = 0;
    while (rawkey < 128) : (rawkey += 1) {
        const key: u8 = @intCast(rawkey);
        if (!old.has(key) and new.has(key) and count < out.len) {
            out[count] = .{ .class = ie.IECLASS_RAWKEY, .code = rawkey };
            count += 1;
        }
    }
    return count;
}

/// The buttons a mouse report holds down: bit 0 the left, 1 the right,
/// 2 the middle.
pub fn buttonsOf(layout: *const MouseLayout, report: []const u8) u8 {
    var buttons: u8 = 0;
    for (layout.buttons, 0..) |field, bit| {
        if (field.value(report) != 0) buttons |= @as(u8, 1) << @intCast(bit);
    }
    return buttons;
}

/// The events of a mouse report read by `layout`, after one whose
/// buttons were `old_buttons`, into `out`: a relative move, each changed
/// button, the wheel. How many; none for a report that is not the
/// layout's.
pub fn mouseEvents(layout: *const MouseLayout, old_buttons: u8, report: []const u8, out: []InputEvent) usize {
    if (!layout.owns(report) or report.len < 3 or out.len < 5) return 0;
    var count: usize = 0;
    const dx = layout.x.value(report);
    const dy = layout.y.value(report);
    if (dx != 0 or dy != 0) {
        out[count] = .{
            .class = ie.IECLASS_RAWMOUSE,
            .code = ie.IECODE_NOBUTTON,
            .qualifier = ie.IEQUALIFIER_RELATIVEMOUSE,
            .x = dx,
            .y = dy,
        };
        count += 1;
    }
    const buttons = buttonsOf(layout, report);
    const codes = [3]u32{ ie.IECODE_LBUTTON, ie.IECODE_RBUTTON, ie.IECODE_MBUTTON };
    for (codes, 0..) |code, bit| {
        const mask = @as(u8, 1) << @intCast(bit);
        if ((old_buttons ^ buttons) & mask == 0) continue;
        out[count] = .{
            .class = ie.IECLASS_RAWMOUSE,
            .code = if (buttons & mask != 0) code else code | ie.IECODE_UP_PREFIX,
            .qualifier = ie.IEQUALIFIER_RELATIVEMOUSE,
        };
        count += 1;
    }
    const wheel = layout.wheel.value(report);
    if (wheel != 0) {
        // HID's wheel counts up as positive; an event's counts down.
        out[count] = .{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_WHEEL, .y = -wheel };
        count += 1;
    }
    return count;
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

const boot_keys = &layout_file.boot_keyboard;

test "a key pressed and let go is a down and an up" {
    var out: [8]InputEvent = undefined;
    const empty = keysOf(boot_keys, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }).?;
    const a_down = keysOf(boot_keys, &.{ 0, 0, 0x04, 0, 0, 0, 0, 0 }).?;
    try testing.expectEqual(@as(usize, 1), keyEvents(empty, a_down, &out));
    try testing.expectEqual(@as(u32, 0x20), out[0].code);
    try testing.expectEqual(@as(usize, 1), keyEvents(a_down, empty, &out));
    try testing.expectEqual(@as(u32, 0x20 | ie.IECODE_UP_PREFIX), out[0].code);
}

test "both Controls are one key: it goes up when the last one does" {
    var out: [8]InputEvent = undefined;
    const both = keysOf(boot_keys, &.{ 0x11, 0, 0, 0, 0, 0, 0, 0 }).?;
    const right = keysOf(boot_keys, &.{ 0x10, 0, 0, 0, 0, 0, 0, 0 }).?;
    const none_held = keysOf(boot_keys, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }).?;
    try testing.expectEqual(@as(usize, 0), keyEvents(both, right, &out));
    try testing.expectEqual(@as(usize, 1), keyEvents(right, none_held, &out));
    try testing.expectEqual(@as(u32, 0x63 | ie.IECODE_UP_PREFIX), out[0].code);
}

test "a report of too many keys changes nothing" {
    try testing.expect(keysOf(boot_keys, &.{ 0, 0, 1, 1, 1, 1, 1, 1 }) == null);
}

test "a keyboard that reports every key as a bit" {
    // Report 1: the modifiers, then a bit for each usage from 0 to 119.
    const bits = KeyboardLayout{
        .report_id = 1,
        .bits = .{ .{ .offset = 8, .count = 8, .first_usage = 0xE0 }, .{ .offset = 16, .count = 120, .first_usage = 0 }, .{}, .{} },
        .bits_count = 2,
    };
    // Backspace (usage 0x2A: the sixth byte of bits, bit 2) and left Shift.
    const held = keysOf(&bits, &.{ 0x01, 0x02, 0, 0, 0, 0, 0, 0x04, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).?;
    try testing.expect(held.has(0x41));
    try testing.expect(held.has(0x60));
    try testing.expect(!held.has(0x20));
    // Read as a boot report, that same byte is a slot holding A.
    try testing.expect(keysOf(boot_keys, &.{ 0x01, 0x02, 0, 0, 0, 0, 0, 0x04 }).?.has(0x20));
    // Another report - the consumer keys, say - is not the keyboard's.
    try testing.expect(keysOf(&bits, &.{ 0x03, 0xE9, 0x00 }) == null);
}

/// A keyboard that reports every key as a bit, as one sends it on its
/// second interface: the modifiers, then a bit for each usage from 0 to
/// 0x8F, no report ID; three LEDs.
const bits_keyboard = [_]u8{
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x95, 0x08, 0x75, 0x01,
    0x15, 0x00, 0x25, 0x01, 0x19, 0xE0, 0x29, 0xE7, 0x81, 0x02, 0x05, 0x07,
    0x95, 0x90, 0x75, 0x01, 0x15, 0x00, 0x25, 0x01, 0x19, 0x00, 0x29, 0x8F,
    0x81, 0x02, 0x05, 0x08, 0x95, 0x03, 0x75, 0x01, 0x19, 0x01, 0x29, 0x03,
    0x91, 0x02, 0x95, 0x05, 0x75, 0x01, 0x91, 0x01, 0xC0,
};

test "a keyboard of bits read by its own descriptor" {
    const layout = layout_file.keyboardLayout(&bits_keyboard).?;
    try testing.expectEqual(@as(u8, 0), layout.report_id);
    try testing.expect(layout.leds);
    var report: [19]u8 = @splat(0);
    // Backspace: usage 0x2A, the bit 0x2A after the modifier byte.
    report[1 + 0x2A / 8] = 1 << (0x2A % 8);
    const held = keysOf(&layout, &report).?;
    try testing.expect(held.has(0x41));
    try testing.expect(!held.has(0x20));
    // F12 (usage 0x45) with right Alt.
    report = @splat(0);
    report[0] = 0x40;
    report[1 + 0x45 / 8] = 1 << (0x45 % 8);
    const second = keysOf(&layout, &report).?;
    try testing.expect(second.has(0x6F));
    try testing.expect(second.has(0x65));
}

test "a mouse's move, a button and the wheel" {
    var out: [5]InputEvent = undefined;
    const boot = &layout_file.boot_mouse;
    const count = mouseEvents(boot, 0, &.{ 0x01, 5, @bitCast(@as(i8, -3)), 1 }, &out);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqual(@as(i32, 5), out[0].x);
    try testing.expectEqual(@as(i32, -3), out[0].y);
    try testing.expectEqual(ie.IECODE_LBUTTON, out[1].code);
    try testing.expectEqual(@as(i32, -1), out[2].y);
    try testing.expectEqual(@as(usize, 1), mouseEvents(boot, 0x01, &.{ 0x00, 0, 0 }, &out));
    try testing.expectEqual(ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, out[0].code);
}

test {
    _ = layout_file;
}
