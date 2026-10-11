// SPDX-License-Identifier: MIT
//! The sheet's cells: kept by place, worked out again after every change,
//! and every change kept so it can be undone.
//!
//! **Keeping.** Only cells that hold something take room: a table open by
//! address, its key the row and the column in one word, probed in a line
//! and closed up again when a cell goes, so no slot is ever a tombstone.
//! A cell keeps what was typed into it (its input) and what that is worth
//! (its value): a number or a text as typed, or what a formula worked out
//! to. Every allocation goes through exec.
//!
//! **Working out.** After a change every formula is worked out again, each
//! once. A formula that names one not yet worked out for this round puts
//! it on a stack of its own and is tried again once that one is done;
//! naming one that is waiting on it in turn is a circle (`#CIRC!`). The
//! stack is the sheet's, not the program's, so a column of a thousand
//! formulas each naming the one above costs memory, not a stack overflow.
//! A formula is worked out at most twice: the first try finds every cell
//! it names that is not done yet, since all its operands are worked out
//! whatever a condition says.
//!
//! **Undoing.** A change the user makes is a step: the texts of the cells
//! it changes, each with the text before and after, and the rows or
//! columns it moved. Undo plays a step's records backwards, redo forwards
//! again. Everything goes through `changeText` and `shiftLines`, so what
//! a step holds is what was done, in order.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const formula = @import("formula.zig");
const number = @import("number.zig");
const eval = @import("eval.zig");

const Value = eval.Value;
const max_rows = formula.max_rows;
const max_cols = formula.max_cols;

/// The longest text a cell keeps: what may be typed, and room for what
/// moving its references makes of it.
pub const max_text: usize = 1024;

/// The most steps that can be undone.
const max_steps = 100;

/// A copy of `text` of its own, with a 0 after it; null for no text, or
/// no memory (`failed` then says so).
fn copyText(sys: *ExecBase, text: []const u8, failed: *bool) ?[*]u8 {
    if (text.len == 0) return null;
    const memory: [*]u8 = @ptrCast(sys.AllocVec(text.len + 1, exec.MEMF_ANY) orelse {
        failed.* = true;
        return null;
    });
    @memcpy(memory[0..text.len], text);
    memory[text.len] = 0;
    return memory;
}

/// A cell's place as one word: the row above the column.
pub fn keyOf(row: u32, col: u32) u32 {
    return row << 8 | col;
}

pub fn rowOf(key: u32) u32 {
    return key >> 8;
}

pub fn colOf(key: u32) u32 {
    return key & 0xFF;
}

const free_key: u32 = 0xFFFF_FFFF;

/// A rectangle of cells, both corners in it.
pub const Area = struct {
    top: u32,
    left: u32,
    bottom: u32,
    right: u32,

    pub fn holds(area: Area, row: u32, col: u32) bool {
        return row >= area.top and row <= area.bottom and col >= area.left and col <= area.right;
    }

    pub fn cells(area: Area) u32 {
        return (area.bottom - area.top + 1) * (area.right - area.left + 1);
    }
};

/// What a cell's input is.
pub const Content = enum(u8) { number, text, formula };

pub const Cell = struct {
    key: u32 = free_key,
    /// What was typed, `input_len` bytes and a 0; the cell's own.
    input: [*]u8 = undefined,
    input_len: u16 = 0,
    content: Content = .text,
    value: Value = .{},
    /// A formula's text answer, which `value.text` points into; the cell's
    /// own.
    answer: ?[*]u8 = null,
    /// The round it was last worked out in, and the round it was last
    /// started in.
    done: u32 = 0,
    visiting: u32 = 0,
    /// Given a new key and not yet put where it probes to.
    unplaced: bool = false,

    pub fn text(cell: *const Cell) []const u8 {
        return cell.input[0..cell.input_len];
    }
};

/// One thing a step did.
const Record = union(enum) {
    /// A cell's text changed from `old` to `new` (null for empty).
    text: struct { key: u32, old: ?[*]u8, old_len: u16, new: ?[*]u8, new_len: u16 },
    /// Rows or columns put in (`insert`) or taken out at `at`.
    shift: struct { columns: bool, at: u32, count: u32, insert: bool },
};

const Step = struct { records: exec.Array(Record) = .{} };

/// The cells of an area kept apart from the sheet, to be put back
/// elsewhere: each with its place from the area's top left corner.
pub const Block = struct {
    rows: u32 = 0,
    cols: u32 = 0,
    /// Where the area was, which a formula's references move from.
    row: u32 = 0,
    col: u32 = 0,
    entries: exec.Array(Entry) = .{},

    pub const Entry = struct { row: u32, col: u32, text: [*]u8, len: u16 };

    pub fn deinit(block: *Block, sys: *ExecBase) void {
        for (block.entries.slice()) |entry| sys.FreeVec(entry.text);
        block.entries.deinit(sys);
        block.* = .{};
    }
};

pub const Sheet = struct {
    sys: *ExecBase,
    slots: [*]Cell = undefined,
    capacity: u32 = 0,
    count: u32 = 0,
    /// The round of working out; 0 is never one, so a new cell is never
    /// taken for done.
    generation: u32 = 0,
    scratch: *eval.Scratch = undefined,
    /// The cells waiting to be worked out, as slot numbers.
    pending: exec.Array(u32) = .{},
    /// A formula named a cell that could not be put on `pending`.
    starved: bool = false,
    steps: exec.Array(Step) = .{},
    /// How many of `steps` are done; those after it can be redone.
    position: u32 = 0,
    /// The step being made, between `begin` and `end`.
    open: ?Step = null,
    /// Changed since it was last read or saved.
    changed: bool = false,
    /// Room for a text as its references are moved.
    moved: [max_text]u8 = undefined,

    /// A sheet with nothing in it; null with no memory.
    pub fn create(sys: *ExecBase) ?*Sheet {
        const sheet: *Sheet = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(Sheet), exec.MEMF_ANY) orelse return null));
        sheet.* = .{ .sys = sys };
        const scratch: *eval.Scratch = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(eval.Scratch), exec.MEMF_ANY) orelse {
            sys.FreeVec(sheet);
            return null;
        }));
        scratch.* = .{};
        sheet.scratch = scratch;
        if (!sheet.makeTable(64)) {
            sys.FreeVec(scratch);
            sys.FreeVec(sheet);
            return null;
        }
        return sheet;
    }

    pub fn destroy(sheet: *Sheet) void {
        const sys = sheet.sys;
        sheet.clearAll();
        sys.FreeVec(sheet.slots);
        sheet.pending.deinit(sys);
        sheet.steps.deinit(sys);
        sys.FreeVec(sheet.scratch);
        sys.FreeVec(sheet);
    }

    // --- the table ------------------------------------------------------------

    fn makeTable(sheet: *Sheet, capacity: u32) bool {
        const slots: [*]Cell = @ptrCast(@alignCast(sheet.sys.AllocVec(capacity * @sizeOf(Cell), exec.MEMF_ANY) orelse return false));
        for (slots[0..capacity]) |*slot| slot.* = .{};
        sheet.slots = slots;
        sheet.capacity = capacity;
        return true;
    }

    fn home(sheet: *const Sheet, key: u32) u32 {
        return (key *% 2654435761) & (sheet.capacity - 1);
    }

    fn slotOf(sheet: *const Sheet, key: u32) ?u32 {
        var index = sheet.home(key);
        while (true) : (index = (index + 1) & (sheet.capacity - 1)) {
            const at = sheet.slots[index].key;
            if (at == key) return index;
            if (at == free_key) return null;
        }
    }

    pub fn find(sheet: *const Sheet, row: u32, col: u32) ?*Cell {
        const index = sheet.slotOf(keyOf(row, col)) orelse return null;
        return &sheet.slots[index];
    }

    /// A cell moved into a table, whose key is not in it yet.
    fn place(sheet: *Sheet, cell: Cell) *Cell {
        var index = sheet.home(cell.key);
        while (sheet.slots[index].key != free_key) index = (index + 1) & (sheet.capacity - 1);
        sheet.slots[index] = cell;
        return &sheet.slots[index];
    }

    /// The table made twice as big, its cells moved over. Pointers into it
    /// go with the old one.
    fn grow(sheet: *Sheet) bool {
        const old = sheet.slots;
        const old_capacity = sheet.capacity;
        if (!sheet.makeTable(old_capacity * 2)) return false;
        for (old[0..old_capacity]) |cell| {
            if (cell.key != free_key) _ = sheet.place(cell);
        }
        sheet.sys.FreeVec(old);
        return true;
    }

    /// The slot for `key`: the one it has, or a new empty one.
    fn slotFor(sheet: *Sheet, key: u32) ?*Cell {
        if (sheet.slotOf(key)) |index| return &sheet.slots[index];
        if ((sheet.count + 1) * 10 > sheet.capacity * 7 and !sheet.grow()) return null;
        sheet.count += 1;
        return sheet.place(.{ .key = key });
    }

    fn release(sheet: *Sheet, cell: *Cell) void {
        sheet.sys.FreeVec(cell.input);
        if (cell.answer) |answer| sheet.sys.FreeVec(answer);
        cell.answer = null;
    }

    /// The cell at `key` taken out, and the cells probed past it closed up
    /// behind it.
    fn remove(sheet: *Sheet, key: u32) void {
        var hole = sheet.slotOf(key) orelse return;
        sheet.release(&sheet.slots[hole]);
        sheet.count -= 1;
        const mask = sheet.capacity - 1;
        var probe = hole;
        while (true) {
            probe = (probe + 1) & mask;
            const moving = sheet.slots[probe].key;
            if (moving == free_key) break;
            // Stays when its home lies cyclically between the hole and it.
            const want = sheet.home(moving);
            const stays = if (hole <= probe) (hole < want and want <= probe) else (hole < want or want <= probe);
            if (stays) continue;
            sheet.slots[hole] = sheet.slots[probe];
            hole = probe;
        }
        sheet.slots[hole] = .{};
    }

    /// Every cell gone; the history too.
    pub fn clearAll(sheet: *Sheet) void {
        for (sheet.slots[0..sheet.capacity]) |*cell| {
            if (cell.key == free_key) continue;
            sheet.release(cell);
            cell.* = .{};
        }
        sheet.count = 0;
        sheet.dropSteps(0);
        if (sheet.open) |*step| sheet.freeStep(step);
        sheet.open = null;
        sheet.changed = false;
    }

    /// The cells as they are, for walking: free slots have `free_key`.
    pub fn slotsInUse(sheet: *const Sheet) []Cell {
        return sheet.slots[0..sheet.capacity];
    }

    pub fn isFree(cell: *const Cell) bool {
        return cell.key == free_key;
    }

    /// How far the cells reach: one past the last row and the last column
    /// with anything in them.
    pub fn extent(sheet: *const Sheet) struct { rows: u32, cols: u32 } {
        var rows: u32 = 0;
        var cols: u32 = 0;
        for (sheet.slots[0..sheet.capacity]) |cell| {
            if (cell.key == free_key) continue;
            rows = @max(rows, rowOf(cell.key) + 1);
            cols = @max(cols, colOf(cell.key) + 1);
        }
        return .{ .rows = rows, .cols = cols };
    }

    // --- a cell's text --------------------------------------------------------

    /// What `text` is as a cell's input: a formula, a number, or a text.
    fn contentOf(text: []const u8) Content {
        if (text[0] == '=') return .formula;
        if (number.parse(text) != null) return .number;
        return .text;
    }

    /// The cell at `key` given `text`, an empty text taking it out. False
    /// with no memory, the cell as it was.
    fn setText(sheet: *Sheet, key: u32, text: []const u8) bool {
        if (text.len == 0) {
            sheet.remove(key);
            return true;
        }
        var failed = false;
        const copy = copyText(sheet.sys, text[0..@min(text.len, max_text)], &failed) orelse return false;
        const cell = sheet.slotFor(key) orelse {
            sheet.sys.FreeVec(copy);
            return false;
        };
        if (cell.input_len != 0) sheet.release(cell);
        const length: u16 = @intCast(@min(text.len, max_text));
        cell.* = .{ .key = key, .input = copy, .input_len = length };
        cell.content = contentOf(copy[0..length]);
        cell.value = switch (cell.content) {
            .number => Value.ofNumber(number.parse(copy[0..length]).?),
            // A leading apostrophe keeps a text that would read as a
            // number or a formula a text, and is not shown.
            .text => Value.ofText(if (copy[0] == '\'') copy[1..length] else copy[0..length]),
            .formula => .{},
        };
        return true;
    }

    /// The text the cell at `row`, `col` was given, "" for none.
    pub fn textAt(sheet: *const Sheet, row: u32, col: u32) []const u8 {
        const cell = sheet.find(row, col) orelse return "";
        return cell.text();
    }

    // --- working out ------------------------------------------------------------

    /// The context `eval.evaluate` asks: the value of the cell at `row`,
    /// `col`.
    pub fn cellValue(sheet: *Sheet, row: u32, col: u32) Value {
        const cell = sheet.find(row, col) orelse return .{};
        return sheet.valueOf(cell);
    }

    /// The context `eval.evaluate` asks: each cell of a range that holds
    /// something, by whichever is fewer - the range's places or the cells.
    pub fn eachInRange(sheet: *Sheet, row: u32, col: u32, row2: u32, col2: u32, gather: anytype) void {
        const area = Area{ .top = row, .left = col, .bottom = row2, .right = col2 };
        if (area.cells() <= sheet.count) {
            var at_row = row;
            while (at_row <= row2) : (at_row += 1) {
                var at_col = col;
                while (at_col <= col2) : (at_col += 1) {
                    const cell = sheet.find(at_row, at_col) orelse continue;
                    gather.visit(sheet.valueOf(cell));
                }
            }
            return;
        }
        for (sheet.slots[0..sheet.capacity]) |*cell| {
            if (cell.key == free_key or !area.holds(rowOf(cell.key), colOf(cell.key))) continue;
            gather.visit(sheet.valueOf(cell));
        }
    }

    /// A cell's value for this round. One not worked out yet is put on
    /// the stack, and the formula asking is tried again after it.
    fn valueOf(sheet: *Sheet, cell: *Cell) Value {
        if (cell.content != .formula or cell.done == sheet.generation) {
            var value = cell.value;
            value.from_cell = true;
            return value;
        }
        if (cell.visiting == sheet.generation) return Value.ofError(.circular);
        const index: u32 = @intCast((@intFromPtr(cell) - @intFromPtr(sheet.slots)) / @sizeOf(Cell));
        if (!sheet.pending.append(sheet.sys, index)) sheet.starved = true;
        return Value.ofNumber(0);
    }

    /// A formula's answer kept in its cell, a text one in memory of the
    /// cell's own.
    fn keep(sheet: *Sheet, cell: *Cell, answer: Value) void {
        if (cell.answer) |old| sheet.sys.FreeVec(old);
        cell.answer = null;
        var value = answer;
        value.from_cell = false;
        if (value.kind == .text and value.text.len > 0) {
            var failed = false;
            if (copyText(sheet.sys, value.text, &failed)) |copy| {
                cell.answer = copy;
                value.text = copy[0..value.text.len];
            } else value = Value.ofError(.value);
        }
        cell.value = value;
    }

    /// Every formula worked out again.
    pub fn recalculate(sheet: *Sheet) void {
        sheet.generation +%= 1;
        if (sheet.generation == 0) sheet.generation = 1;
        const round = sheet.generation;
        var index: u32 = 0;
        while (index < sheet.capacity) : (index += 1) {
            const cell = &sheet.slots[index];
            if (cell.key == free_key or cell.content != .formula or cell.done == round) continue;
            sheet.pending.len = 0;
            if (!sheet.pending.append(sheet.sys, index)) {
                sheet.keep(cell, Value.ofError(.value));
                cell.done = round;
                continue;
            }
            while (sheet.pending.len > 0) {
                const top = sheet.pending.items[sheet.pending.len - 1];
                const working = &sheet.slots[top];
                if (working.done == round) {
                    sheet.pending.len -= 1;
                    continue;
                }
                working.visiting = round;
                const before = sheet.pending.len;
                sheet.starved = false;
                var answer = eval.evaluate(sheet, sheet.scratch, working.text());
                if (sheet.pending.len > before) continue;
                if (sheet.starved) answer = Value.ofError(.value);
                sheet.keep(working, answer);
                working.done = round;
                sheet.pending.len -= 1;
            }
        }
    }

    // --- steps ------------------------------------------------------------------

    fn freeRecord(sheet: *Sheet, record: Record) void {
        switch (record) {
            .text => |change| {
                if (change.old) |old| sheet.sys.FreeVec(old);
                if (change.new) |new| sheet.sys.FreeVec(new);
            },
            .shift => {},
        }
    }

    fn freeStep(sheet: *Sheet, step: *Step) void {
        for (step.records.slice()) |record| sheet.freeRecord(record);
        step.records.deinit(sheet.sys);
    }

    /// The steps from `from` on forgotten.
    fn dropSteps(sheet: *Sheet, from: u32) void {
        while (sheet.steps.len > from) {
            sheet.steps.len -= 1;
            sheet.freeStep(&sheet.steps.items[sheet.steps.len]);
        }
        if (sheet.position > from) sheet.position = from;
    }

    /// A step begun: what follows until `end` is undone as one.
    pub fn begin(sheet: *Sheet) void {
        if (sheet.open == null) sheet.open = .{};
    }

    /// The step ended and kept, unless it did nothing; then everything is
    /// worked out again. False when the step could not be kept - it is
    /// done, and cannot be undone.
    pub fn end(sheet: *Sheet) bool {
        var step = sheet.open orelse return true;
        sheet.open = null;
        sheet.recalculate();
        if (step.records.len == 0) {
            step.records.deinit(sheet.sys);
            return true;
        }
        sheet.changed = true;
        sheet.dropSteps(sheet.position);
        if (sheet.steps.len == max_steps) {
            sheet.freeStep(&sheet.steps.items[0]);
            const kept = sheet.steps.slice();
            for (kept[1..], 0..) |moving, at| kept[at] = moving;
            sheet.steps.len -= 1;
            sheet.position -= 1;
        }
        if (!sheet.steps.append(sheet.sys, step)) {
            // Nothing before it can be undone over it either.
            sheet.freeStep(&step);
            sheet.dropSteps(0);
            return false;
        }
        sheet.position += 1;
        return true;
    }

    pub fn canUndo(sheet: *const Sheet) bool {
        return sheet.position > 0;
    }

    pub fn canRedo(sheet: *const Sheet) bool {
        return sheet.position < sheet.steps.len;
    }

    fn play(sheet: *Sheet, record: Record, forwards: bool) void {
        switch (record) {
            .text => |change| {
                const ptr = if (forwards) change.new else change.old;
                const length = if (forwards) change.new_len else change.old_len;
                const text: []const u8 = if (ptr) |bytes| bytes[0..length] else "";
                // Undoing frees nothing: where memory is short the cell may
                // stay as it is, and the step is still the one to redo.
                _ = sheet.setText(change.key, text);
            },
            .shift => |shift| sheet.moveLines(shift.columns, shift.at, shift.count, if (forwards) shift.insert else !shift.insert),
        }
    }

    /// The last step done undone.
    pub fn undo(sheet: *Sheet) bool {
        if (!sheet.canUndo()) return false;
        sheet.position -= 1;
        const records = sheet.steps.items[sheet.position].records.slice();
        var at = records.len;
        while (at > 0) {
            at -= 1;
            sheet.play(records[at], false);
        }
        sheet.changed = true;
        sheet.recalculate();
        return true;
    }

    /// The last step undone done again.
    pub fn redo(sheet: *Sheet) bool {
        if (!sheet.canRedo()) return false;
        for (sheet.steps.items[sheet.position].records.slice()) |record| sheet.play(record, true);
        sheet.position += 1;
        sheet.changed = true;
        sheet.recalculate();
        return true;
    }

    /// The cell at `row`, `col` given `text` ("" empties it), as part of
    /// the open step. False with no memory, the cell as it was.
    pub fn changeText(sheet: *Sheet, row: u32, col: u32, text: []const u8) bool {
        const key = keyOf(row, col);
        const old = sheet.textAt(row, col);
        const new = text[0..@min(text.len, max_text)];
        if (sameText(old, new)) return true;
        if (sheet.open) |*step| {
            var failed = false;
            const old_copy = copyText(sheet.sys, old, &failed);
            const new_copy = copyText(sheet.sys, new, &failed);
            const record = Record{ .text = .{ .key = key, .old = old_copy, .old_len = @intCast(old.len), .new = new_copy, .new_len = @intCast(new.len) } };
            if (failed or !step.records.append(sheet.sys, record)) {
                sheet.freeRecord(record);
                return false;
            }
            if (!sheet.setText(key, new)) {
                step.records.len -= 1;
                sheet.freeRecord(record);
                return false;
            }
            return true;
        }
        return sheet.setText(key, new);
    }

    /// Rows (or columns) moved, the cells' places only: `count` of them
    /// opened at `at` (`insert`), or closed there, the cells in them gone
    /// already. Done in the table as it is, so it needs no memory and
    /// cannot fail: every cell is given its new key, then each is put where
    /// its key now probes to, swapping with one not yet put.
    fn moveLines(sheet: *Sheet, columns: bool, at: u32, count: u32, insert: bool) void {
        const mask = sheet.capacity - 1;
        for (sheet.slots[0..sheet.capacity]) |*cell| {
            if (cell.key == free_key) continue;
            cell.key = movedKey(cell.key, columns, at, count, insert) orelse {
                sheet.release(cell);
                cell.* = .{};
                sheet.count -= 1;
                continue;
            };
            cell.unplaced = true;
        }
        var index: u32 = 0;
        while (index < sheet.capacity) : (index += 1) {
            if (sheet.slots[index].key == free_key or !sheet.slots[index].unplaced) continue;
            var carry = sheet.slots[index];
            sheet.slots[index] = .{};
            while (true) {
                carry.unplaced = false;
                // Past the cells already put: a cell put never moves again,
                // so the run in front of it stays whole.
                var probe = sheet.home(carry.key);
                while (sheet.slots[probe].key != free_key and !sheet.slots[probe].unplaced) probe = (probe + 1) & mask;
                const there = sheet.slots[probe];
                sheet.slots[probe] = carry;
                if (there.key == free_key) break;
                carry = there;
            }
        }
    }

    /// Rows or columns put in or taken out as one step of their own, with
    /// every formula's references moved to follow: `count` from `at`.
    /// False when it could not be done: inserting would push something off
    /// the end of the sheet (`no_room`), or there was no memory.
    pub fn shiftLines(sheet: *Sheet, columns: bool, at: u32, count: u32, insert: bool) ShiftResult {
        const limit = (if (columns) max_cols else max_rows) - count;
        if (insert) {
            for (sheet.slots[0..sheet.capacity]) |cell| {
                if (cell.key == free_key) continue;
                const index = if (columns) colOf(cell.key) else rowOf(cell.key);
                if (index >= limit) return .no_room;
            }
        }
        var keys: exec.Array(u32) = .{};
        defer keys.deinit(sheet.sys);
        for (sheet.slots[0..sheet.capacity]) |cell| {
            if (cell.key != free_key and !keys.append(sheet.sys, cell.key)) return .no_memory;
        }
        const move: formula.Move = if (insert)
            .{ .insert = .{ .columns = columns, .at = at, .count = count } }
        else
            .{ .delete = .{ .columns = columns, .at = at, .count = count } };
        sheet.begin();
        var ok = true;
        for (keys.slice()) |key| {
            const index = if (columns) colOf(key) else rowOf(key);
            const gone = !insert and index >= at and index < at + count;
            const row = rowOf(key);
            const col = colOf(key);
            if (gone) {
                ok = sheet.changeText(row, col, "") and ok;
                continue;
            }
            const cell = sheet.find(row, col) orelse continue;
            if (cell.content != .formula) continue;
            const moved = formula.rewrite(cell.text(), move, &sheet.moved) orelse continue;
            ok = sheet.changeText(row, col, moved) and ok;
        }
        if (ok) {
            if (sheet.open) |*step| {
                if (step.records.append(sheet.sys, .{ .shift = .{ .columns = columns, .at = at, .count = count, .insert = insert } })) {
                    sheet.moveLines(columns, at, count, insert);
                } else ok = false;
            }
        }
        const kept = sheet.end();
        return if (ok and kept) .done else .no_memory;
    }

    // --- filling, copying and putting back ------------------------------------

    /// What `text` becomes copied from `from_row`, `from_col` to `row`,
    /// `col`: a formula's references moved along, anything else as it is.
    /// Null when it would not fit.
    pub fn copiedText(sheet: *Sheet, text: []const u8, from_row: u32, from_col: u32, row: u32, col: u32) ?[]const u8 {
        if (text.len == 0 or text[0] != '=') return text;
        const move = formula.Move{ .offset = .{
            .rows = @as(i32, @intCast(row)) - @as(i32, @intCast(from_row)),
            .cols = @as(i32, @intCast(col)) - @as(i32, @intCast(from_col)),
        } };
        return formula.rewrite(text, move, &sheet.moved);
    }

    /// The area's first row copied into the rows below it (`down`), or its
    /// first column into the columns right of it, as one step. False with
    /// no memory.
    pub fn fill(sheet: *Sheet, area: Area, down: bool) bool {
        sheet.begin();
        var ok = true;
        var row = area.top;
        while (row <= area.bottom) : (row += 1) {
            var col = area.left;
            while (col <= area.right) : (col += 1) {
                const from_row = if (down) area.top else row;
                const from_col = if (down) col else area.left;
                if (row == from_row and col == from_col) continue;
                // The source's text is its own memory, which the change to
                // another cell leaves alone.
                const text = sheet.copiedText(sheet.textAt(from_row, from_col), from_row, from_col, row, col) orelse continue;
                ok = sheet.changeText(row, col, text) and ok;
            }
        }
        return sheet.end() and ok;
    }

    /// Every cell of the area emptied, as one step.
    pub fn clear(sheet: *Sheet, area: Area) bool {
        sheet.begin();
        var ok = true;
        var keys: exec.Array(u32) = .{};
        defer keys.deinit(sheet.sys);
        for (sheet.slots[0..sheet.capacity]) |cell| {
            if (cell.key == free_key or !area.holds(rowOf(cell.key), colOf(cell.key))) continue;
            if (!keys.append(sheet.sys, cell.key)) ok = false;
        }
        for (keys.slice()) |key| ok = sheet.changeText(rowOf(key), colOf(key), "") and ok;
        return sheet.end() and ok;
    }

    /// The cells of an area copied into `block`. False with no memory.
    pub fn copyBlock(sheet: *Sheet, area: Area, block: *Block) bool {
        block.deinit(sheet.sys);
        block.rows = area.bottom - area.top + 1;
        block.cols = area.right - area.left + 1;
        block.row = area.top;
        block.col = area.left;
        for (sheet.slots[0..sheet.capacity]) |cell| {
            if (cell.key == free_key) continue;
            const row = rowOf(cell.key);
            const col = colOf(cell.key);
            if (!area.holds(row, col)) continue;
            var failed = false;
            const copy = copyText(sheet.sys, cell.text(), &failed) orelse return false;
            const entry = Block.Entry{ .row = row - area.top, .col = col - area.left, .text = copy, .len = cell.input_len };
            if (!block.entries.append(sheet.sys, entry)) {
                sheet.sys.FreeVec(copy);
                return false;
            }
        }
        return true;
    }

    /// `block` put back with its top left corner at `row`, `col`, its
    /// formulas' references moved along, the area it covers emptied first:
    /// one step. What would fall off the sheet is left out. False with no
    /// memory.
    pub fn pasteBlock(sheet: *Sheet, block: *const Block, row: u32, col: u32) bool {
        const bottom = @min(row + block.rows - 1, max_rows - 1);
        const right = @min(col + block.cols - 1, max_cols - 1);
        sheet.begin();
        var ok = true;
        // Emptied first, as part of this one step.
        var keys: exec.Array(u32) = .{};
        defer keys.deinit(sheet.sys);
        const area = Area{ .top = row, .left = col, .bottom = bottom, .right = right };
        for (sheet.slots[0..sheet.capacity]) |cell| {
            if (cell.key == free_key or !area.holds(rowOf(cell.key), colOf(cell.key))) continue;
            if (!keys.append(sheet.sys, cell.key)) ok = false;
        }
        for (keys.slice()) |key| ok = sheet.changeText(rowOf(key), colOf(key), "") and ok;
        for (block.entries.slice()) |entry| {
            const to_row = row + entry.row;
            const to_col = col + entry.col;
            if (to_row > bottom or to_col > right) continue;
            const text = sheet.copiedText(entry.text[0..entry.len], block.row + entry.row, block.col + entry.col, to_row, to_col) orelse continue;
            ok = sheet.changeText(to_row, to_col, text) and ok;
        }
        return sheet.end() and ok;
    }

    /// Text in rows and columns - lines of fields split by tabs - put in
    /// from `row`, `col` on, each field as typed: one step.
    pub fn pasteText(sheet: *Sheet, text: []const u8, row: u32, col: u32) bool {
        sheet.begin();
        var ok = true;
        var at_row = row;
        var at_col = col;
        var start: usize = 0;
        var at: usize = 0;
        while (at <= text.len) : (at += 1) {
            const char: u8 = if (at < text.len) text[at] else '\n';
            if (char != '\t' and char != '\n') continue;
            var field = text[start..at];
            if (field.len > 0 and field[field.len - 1] == '\r') field = field[0 .. field.len - 1];
            // A last line with nothing on it is the end of the one before.
            const last = at == text.len;
            if (!(last and field.len == 0 and at_col == col)) {
                if (at_row < max_rows and at_col < max_cols) ok = sheet.changeText(at_row, at_col, field) and ok;
            }
            start = at + 1;
            if (char == '\t') {
                at_col += 1;
            } else {
                at_row += 1;
                at_col = col;
            }
        }
        return sheet.end() and ok;
    }
};

pub const ShiftResult = enum { done, no_room, no_memory };

/// A key moved by rows or columns put in or taken out; null for a cell in
/// what was taken out.
fn movedKey(key: u32, columns: bool, at: u32, count: u32, insert: bool) ?u32 {
    var row = rowOf(key);
    var col = colOf(key);
    const index = if (columns) &col else &row;
    if (index.* >= at) {
        if (insert) {
            index.* += count;
        } else if (index.* < at + count) {
            return null;
        } else index.* -= count;
    }
    if (row >= max_rows or col >= max_cols) return null;
    return keyOf(row, col);
}

/// Whether two texts are the same, byte for byte.
pub fn sameText(text: []const u8, other: []const u8) bool {
    if (text.len != other.len) return false;
    for (text, other) |char, other_char| {
        if (char != other_char) return false;
    }
    return true;
}

/// How a value is shown: a number in at most `digits` significant
/// digits, a text as it is, TRUE or FALSE, an error's name. Written into
/// `out` when it has to be made; the text.
pub fn shownText(value: Value, digits: u32, out: *[32]u8) []const u8 {
    return switch (value.kind) {
        .number => number.format(value.number, digits, out),
        .text => value.text,
        .boolean => if (value.number != 0) "TRUE" else "FALSE",
        .err => eval.errorText(value.err),
        .empty, .range => "",
    };
}
