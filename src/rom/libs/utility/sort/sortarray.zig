// SPDX-License-Identifier: MPL-2.0
//! SortArray: an array's elements put in order in place, compared by a
//! hook. A heap sort: the elements are made a heap whose top goes last,
//! the top swapped to the end and the rest sifted into a heap again,
//! until one element is left.

const std = @import("std");
const sdk = @import("sdk");

const UtilityBase = @import("../utility.zig").UtilityBase;
const Hook = sdk.utility.Hook;

/// Puts the elements of an array in order, in place, as a hook compares
/// them.
///
/// SYNOPSIS:
/// ```zig
/// fn SortArray(ub: *UtilityBase, array: ?*anyopaque, count: usize, size: usize, hook: *Hook) void
/// ```
///
/// SINCE: 1.6. LVO -300.
///
/// INPUTS:
/// - `array` - the first element.
/// - `count` - how many elements there are.
/// - `size` - the bytes of one element, from its start to the next's.
/// - `hook` - what compares two elements: called with one as the object
///   and another as the message, it answers - read as an `isize` - below
///   0 when the object goes before the message, 0 or above when not.
///
/// RESULT:
/// None; the elements are in order.
///
/// BEHAVIOR:
/// A heap sort: the elements are made a heap with the one that goes last
/// on top, the top swapped to the end and the rest made a heap again,
/// until one is left. That takes about 2 n log2 n comparisons at most,
/// whatever order the elements come in, and no memory. Elements are
/// swapped a word at a time when `array` and `size` are a word's
/// multiple, a byte at a time else. A `count` below 2 or a `size` of 0
/// calls the hook not at all.
///
/// CONTEXT:
/// - Waits: only when the hook does.
/// - Interrupts: safe when the hook is.
/// - Locks: none taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The array and the hook are the caller's; the
/// elements the hook is handed are in the array, moved between calls.
///
/// NOTES:
/// The sort is not stable: elements that compare alike end up in no
/// order of their own. An answer of Stricmp or CompareMem may be handed
/// back as it is. The hook's `data` carries what the comparison needs
/// besides the two elements - a table they index, a library to call.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CallHookPkt`, `CompareMem`, `Stricmp`
///
/// EXAMPLES:
/// ```zig
/// fn byName(hook: *utility.Hook, first: ?*anyopaque, second: ?*anyopaque) callconv(.c) usize {
///     const ub: *UtilityBase = @ptrCast(@alignCast(hook.data.?));
///     const a: *const Entry = @ptrCast(@alignCast(first.?));
///     const b: *const Entry = @ptrCast(@alignCast(second.?));
///     return @bitCast(@as(isize, ub.Stricmp(a.name, b.name)));
/// }
///
/// var by_name: utility.Hook = .{ .entry = byName, .data = ub };
/// ub.SortArray(entries.ptr, entries.len, @sizeOf(Entry), &by_name);
/// ```
pub fn SortArray(ub: *UtilityBase, array: ?*anyopaque, count: usize, size: usize, hook: *Hook) void {
    if (count < 2 or size == 0) return;
    const start: [*]u8 = @ptrCast(array orelse return);
    const word = @sizeOf(usize);
    const sorting: Sorting = .{
        .utility = ub.iface(),
        .start = start,
        .size = size,
        .hook = hook,
        .by_words = size % word == 0 and @intFromPtr(start) % word == 0,
    };
    var first = count / 2;
    while (first > 0) {
        first -= 1;
        sorting.siftDown(first, count);
    }
    var end = count;
    while (end > 1) {
        end -= 1;
        sorting.swap(0, end);
        sorting.siftDown(0, end);
    }
}

const Sorting = struct {
    utility: *sdk.interface.utility.UtilityBase,
    start: [*]u8,
    size: usize,
    hook: *Hook,
    by_words: bool,

    fn at(sorting: *const Sorting, index: usize) [*]u8 {
        return sorting.start + index * sorting.size;
    }

    /// Whether element `a` goes before element `b`.
    fn before(sorting: *const Sorting, a: usize, b: usize) bool {
        const answer: isize = @bitCast(sorting.utility.CallHookPkt(sorting.hook, sorting.at(a), sorting.at(b)));
        return answer < 0;
    }

    fn swap(sorting: *const Sorting, a: usize, b: usize) void {
        if (sorting.by_words) {
            const first: [*]usize = @ptrCast(@alignCast(sorting.at(a)));
            const second: [*]usize = @ptrCast(@alignCast(sorting.at(b)));
            for (0..sorting.size / @sizeOf(usize)) |index| {
                const held = first[index];
                first[index] = second[index];
                second[index] = held;
            }
            return;
        }
        const first = sorting.at(a);
        const second = sorting.at(b);
        for (0..sorting.size) |index| {
            const held = first[index];
            first[index] = second[index];
            second[index] = held;
        }
    }

    /// The element at `root` moved down the heap below `end` until
    /// neither of its children goes after it.
    fn siftDown(sorting: *const Sorting, root: usize, end: usize) void {
        var parent = root;
        while (true) {
            var child = parent * 2 + 1;
            if (child >= end) return;
            if (child + 1 < end and sorting.before(child, child + 1)) child += 1;
            if (!sorting.before(parent, child)) return;
            sorting.swap(parent, child);
            parent = child;
        }
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

/// Counts its calls in the u32 its `data` points at.
fn byValue(hook: *Hook, first: ?*anyopaque, second: ?*anyopaque) callconv(.c) usize {
    const calls: *u32 = @ptrCast(@alignCast(hook.data.?));
    calls.* += 1;
    const a: *const u32 = @ptrCast(@alignCast(first.?));
    const b: *const u32 = @ptrCast(@alignCast(second.?));
    const answer: isize = if (a.* < b.*) -1 else if (a.* > b.*) 1 else 0;
    return @bitCast(answer);
}

test "SortArray: numbers in any order come out in order, through the jump table" {
    const ub = try library.setUp();
    defer kexec.deinit();
    var calls: u32 = 0;
    var hook: Hook = .{ .entry = byValue, .data = &calls };
    var numbers: [500]u32 = undefined;
    var seed: u32 = 7;
    for (&numbers) |*number| {
        seed = seed *% 1103515245 +% 12345;
        number.* = (seed >> 16) % 300; // with repeats
    }
    ub.iface().SortArray(&numbers, numbers.len, @sizeOf(u32), &hook);
    for (numbers[1..], 0..) |number, index| try testing.expect(numbers[index] <= number);
    // 2 n log2 n is the most a heap sort takes.
    try testing.expect(calls <= 2 * 500 * 9);

    // In order already, the other way round, all alike.
    var rising: [64]u32 = undefined;
    for (&rising, 0..) |*number, index| number.* = @intCast(index);
    var falling: [64]u32 = undefined;
    for (&falling, 0..) |*number, index| number.* = @intCast(63 - index);
    var alike: [64]u32 = @splat(5);
    for ([_]*[64]u32{ &rising, &falling, &alike }) |list| {
        SortArray(ub, list, list.len, @sizeOf(u32), &hook);
        for (list[1..], 0..) |number, index| try testing.expect(list[index] <= number);
    }
    for (rising, 0..) |number, index| try testing.expectEqual(@as(u32, @intCast(index)), number);
    for (falling, 0..) |number, index| try testing.expectEqual(@as(u32, @intCast(index)), number);

    // Nothing to sort: the hook is not called.
    calls = 0;
    SortArray(ub, &numbers, 1, @sizeOf(u32), &hook);
    SortArray(ub, &numbers, 0, @sizeOf(u32), &hook);
    SortArray(ub, null, 10, @sizeOf(u32), &hook);
    SortArray(ub, &numbers, 10, 0, &hook);
    try testing.expectEqual(@as(u32, 0), calls);
}

/// Three bytes, a name's letter first: swapped a byte at a time.
const Odd = extern struct { letter: u8, low: u8, high: u8 };

fn byLetter(_: *Hook, first: ?*anyopaque, second: ?*anyopaque) callconv(.c) usize {
    const a: *const Odd = @ptrCast(first.?);
    const b: *const Odd = @ptrCast(second.?);
    return @bitCast(@as(isize, @as(i16, a.letter) - b.letter));
}

test "SortArray: elements of an odd size, each whole after the sort" {
    const ub = try library.setUp();
    defer kexec.deinit();
    var hook: Hook = .{ .entry = byLetter };
    const word = "heapsortxyz";
    var elements: [word.len]Odd = undefined;
    for (&elements, word, 0..) |*element, letter, index| element.* = .{ .letter = letter, .low = @intCast(index), .high = letter +% 1 };
    SortArray(ub, &elements, elements.len, @sizeOf(Odd), &hook);
    for (elements[1..], 0..) |element, index| try testing.expect(elements[index].letter <= element.letter);
    for (elements) |element| {
        try testing.expectEqual(word[element.low], element.letter);
        try testing.expectEqual(element.letter +% 1, element.high);
    }
}
