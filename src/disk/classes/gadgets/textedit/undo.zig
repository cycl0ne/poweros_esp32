// SPDX-License-Identifier: MIT
//! Undo and redo for a textedit.gadget: every change to the text kept as
//! what it took out and what it put in, where, and where the cursor and
//! the selection were before it.
//!
//! A change is a replacement: at `at`, `removed` gave way to `inserted`.
//! Undo puts `removed` back in place of `inserted`, redo the other way
//! round. A change made after an undo forgets what could have been redone.
//!
//! **Typing is one step.** A change made by typing joins the one before
//! when that was typing too and they touch: a character put in right
//! after the last, Backspace just before what the last took out, Del just
//! after. Anything else - a cursor key, a press, a paste - starts a step
//! of its own (`seal`).
//!
//! The history keeps `max_steps` changes and `max_bytes` of their text;
//! past either, the oldest go. A change too big to keep at all leaves an
//! empty history rather than one that would undo into the wrong text.
//!
//! The steps are an allocation of their own, made at the first change:
//! a History is a few words, so it is made in place on any task's stack.

const std = @import("std");
const Memory = @import("text.zig").Memory;

pub const max_steps = 512;
pub const max_bytes = 1024 * 1024;

/// One change, its two texts in one allocation: `removed` first.
pub const Step = struct {
    at: u32,
    bytes: ?[*]u8 = null,
    cap: u32 = 0,
    removed_len: u32 = 0,
    inserted_len: u32 = 0,
    cursor: u32,
    anchor: u32,
    /// Made by typing, and still open to the next keystroke.
    typing: bool = false,

    pub fn removed(step: *const Step) []const u8 {
        const bytes = step.bytes orelse return &.{};
        return bytes[0..step.removed_len];
    }

    pub fn inserted(step: *const Step) []const u8 {
        const bytes = step.bytes orelse return &.{};
        return bytes[step.removed_len..][0..step.inserted_len];
    }

    fn size(step: *const Step) u32 {
        return step.removed_len + step.inserted_len;
    }
};

pub const History = struct {
    memory: Memory,
    /// `max_steps` of them, from the first change on; null before.
    steps: ?[*]Step = null,
    /// Steps kept, and how many of them are done: the ones past `done`
    /// are what redo puts back.
    count: u32 = 0,
    done: u32 = 0,
    bytes: u32 = 0,

    pub fn init(memory: Memory) History {
        return .{ .memory = memory };
    }

    pub fn deinit(history: *History) void {
        history.forgetFrom(0);
        if (history.steps) |steps| history.memory.free(history.memory.context, @ptrCast(steps));
        history.steps = null;
    }

    /// Every step from `index` on freed.
    fn forgetFrom(history: *History, index: u32) void {
        var at = index;
        while (at < history.count) : (at += 1) {
            const step = &history.steps.?[at];
            history.bytes -= step.size();
            if (step.bytes) |bytes| history.memory.free(history.memory.context, bytes);
        }
        history.count = @min(history.count, index);
        history.done = @min(history.done, index);
    }

    /// The oldest step freed and the rest moved down.
    fn dropOldest(history: *History) void {
        const steps = history.steps.?;
        const step = &steps[0];
        history.bytes -= step.size();
        if (step.bytes) |bytes| history.memory.free(history.memory.context, bytes);
        var at: u32 = 1;
        while (at < history.count) : (at += 1) steps[at - 1] = steps[at];
        history.count -= 1;
        history.done -|= 1;
    }

    /// The next keystroke starts a step of its own.
    pub fn seal(history: *History) void {
        if (history.done > 0) history.steps.?[history.done - 1].typing = false;
    }

    pub fn canUndo(history: *const History) bool {
        return history.done > 0;
    }

    pub fn canRedo(history: *const History) bool {
        return history.done < history.count;
    }

    /// The step undo would take back, which the caller applies and then
    /// confirms with `undone`.
    pub fn toUndo(history: *const History) ?*const Step {
        if (history.done == 0) return null;
        return &history.steps.?[history.done - 1];
    }

    pub fn undone(history: *History) void {
        history.done -= 1;
    }

    pub fn toRedo(history: *const History) ?*const Step {
        if (history.done == history.count) return null;
        return &history.steps.?[history.done];
    }

    pub fn redone(history: *History) void {
        history.done += 1;
    }

    /// A change kept: at `at`, `removed` gave way to `inserted`; `cursor`
    /// and `anchor` as they were before it. With `typing`, it joins the
    /// last step when that was typing and they touch.
    pub fn record(history: *History, at: u32, removed: []const u8, inserted: []const u8, cursor: u32, anchor: u32, typing: bool) void {
        if (history.steps == null) {
            const memory = history.memory.alloc(history.memory.context, max_steps * @sizeOf(Step)) orelse return;
            history.steps = @ptrCast(@alignCast(memory));
        }
        history.forgetFrom(history.done);
        if (typing and history.join(at, removed, inserted)) return;
        history.seal();
        const total: u32 = @intCast(removed.len + inserted.len);
        if (total > max_bytes) {
            // Too big to keep: what is kept could not be undone past it.
            history.forgetFrom(0);
            return;
        }
        while (history.count == max_steps or (history.count > 0 and history.bytes + total > max_bytes)) history.dropOldest();
        var step = Step{ .at = at, .cursor = cursor, .anchor = anchor, .typing = typing };
        if (total != 0) {
            const least: u32 = if (typing) 32 else 0;
            const cap = @max(total, least);
            const bytes = history.memory.alloc(history.memory.context, cap) orelse {
                history.forgetFrom(0);
                return;
            };
            @memcpy(bytes[0..removed.len], removed);
            @memcpy(bytes[removed.len..][0..inserted.len], inserted);
            step.bytes = bytes;
            step.cap = cap;
        }
        step.removed_len = @intCast(removed.len);
        step.inserted_len = @intCast(inserted.len);
        history.steps.?[history.count] = step;
        history.count += 1;
        history.done = history.count;
        history.bytes += total;
    }

    /// The change added to the last step when both are typing and touch.
    fn join(history: *History, at: u32, removed: []const u8, inserted: []const u8) bool {
        if (history.done == 0) return false;
        const last = &history.steps.?[history.done - 1];
        if (!last.typing) return false;
        // A character put in right after the last ones.
        if (removed.len == 0 and inserted.len != 0 and last.removed_len == 0 and at == last.at + last.inserted_len) {
            if (!history.grow(last, @intCast(inserted.len))) return false;
            @memcpy(last.bytes.?[last.size()..][0..inserted.len], inserted);
            last.inserted_len += @intCast(inserted.len);
            history.bytes += @intCast(inserted.len);
            return true;
        }
        if (inserted.len == 0 and removed.len != 0 and last.inserted_len == 0) {
            const count: u32 = @intCast(removed.len);
            // Backspace: just before what the last took out.
            if (at + count == last.at) {
                if (!history.grow(last, count)) return false;
                const bytes = last.bytes.?;
                @memmove(bytes[count..][0..last.removed_len], bytes[0..last.removed_len]);
                @memcpy(bytes[0..count], removed);
                last.removed_len += count;
                last.at = at;
                history.bytes += count;
                return true;
            }
            // Del: at the same place again.
            if (at == last.at) {
                if (!history.grow(last, count)) return false;
                @memcpy(last.bytes.?[last.removed_len..][0..count], removed);
                last.removed_len += count;
                history.bytes += count;
                return true;
            }
        }
        return false;
    }

    /// Room in a step for `extra` more bytes, doubling.
    fn grow(history: *History, step: *Step, extra: u32) bool {
        const need = step.size() + extra;
        if (history.bytes + extra > max_bytes) return false;
        if (need <= step.cap) return true;
        var cap = @max(step.cap, 32);
        while (cap < need) cap *= 2;
        const fresh = history.memory.alloc(history.memory.context, cap) orelse return false;
        if (step.bytes) |old| {
            @memcpy(fresh[0..step.size()], old[0..step.size()]);
            history.memory.free(history.memory.context, old);
        }
        step.bytes = fresh;
        step.cap = cap;
        return true;
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

const test_memory = Memory{ .alloc = testAlloc, .free = testFree };

fn testAlloc(_: ?*anyopaque, size: u32) ?[*]u8 {
    const block = testing.allocator.alignedAlloc(u8, .@"8", size + 8) catch return null;
    std.mem.writeInt(u64, block[0..8], size, .little);
    return block.ptr + 8;
}

fn testFree(_: ?*anyopaque, memory: [*]u8) void {
    const start = memory - 8;
    const size = std.mem.readInt(u64, start[0..8], .little);
    testing.allocator.free(@as([*]align(8) u8, @alignCast(start))[0 .. size + 8]);
}

test "typing joins into one step; a sealed step does not" {
    var history = History.init(test_memory);
    defer history.deinit();
    history.record(0, "", "h", 0, 0, true);
    history.record(1, "", "i", 1, 1, true);
    history.record(2, "", "!", 2, 2, true);
    try testing.expectEqual(@as(u32, 1), history.count);
    try testing.expectEqualStrings("hi!", history.toUndo().?.inserted());
    history.seal();
    history.record(3, "", "x", 3, 3, true);
    try testing.expectEqual(@as(u32, 2), history.count);
    // A character somewhere else is a step of its own too.
    history.record(0, "", "y", 0, 0, true);
    try testing.expectEqual(@as(u32, 3), history.count);
}

test "Backspace and Del runs join, each the right way round" {
    var history = History.init(test_memory);
    defer history.deinit();
    // "abcde", Backspace three times from the end.
    history.record(4, "e", "", 5, 5, true);
    history.record(3, "d", "", 4, 4, true);
    history.record(2, "c", "", 3, 3, true);
    try testing.expectEqual(@as(u32, 1), history.count);
    try testing.expectEqualStrings("cde", history.toUndo().?.removed());
    try testing.expectEqual(@as(u32, 2), history.toUndo().?.at);
    history.seal();
    // Del twice at 0 of "ab".
    history.record(0, "a", "", 0, 0, true);
    history.record(0, "b", "", 0, 0, true);
    try testing.expectEqual(@as(u32, 2), history.count);
    try testing.expectEqualStrings("ab", history.toUndo().?.removed());
}

test "undo and redo walk the steps; a new change forgets the redo" {
    var history = History.init(test_memory);
    defer history.deinit();
    history.record(0, "", "one", 0, 0, false);
    history.record(3, "", "two", 3, 3, false);
    try testing.expectEqualStrings("two", history.toUndo().?.inserted());
    history.undone();
    try testing.expect(history.canRedo());
    try testing.expectEqualStrings("two", history.toRedo().?.inserted());
    history.record(3, "", "six", 3, 3, false);
    try testing.expect(!history.canRedo());
    try testing.expectEqual(@as(u32, 2), history.count);
    history.undone();
    history.undone();
    try testing.expect(!history.canUndo());
}

test "the oldest steps go past the limit" {
    var history = History.init(test_memory);
    defer history.deinit();
    var at: u32 = 0;
    while (at < max_steps + 10) : (at += 1) history.record(at, "", "x", at, at, false);
    try testing.expectEqual(@as(u32, max_steps), history.count);
    try testing.expectEqual(@as(u32, 10), history.steps.?[0].at);
}
