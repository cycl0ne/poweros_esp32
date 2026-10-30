// SPDX-License-Identifier: MIT
//! ParseIX: a description into an input expression.

const sdk = @import("sdk");
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const _base = @import("../commodities_base.zig");
const _filter = @import("_filter.zig");
const CxBase = _base.CxBase;

/// Reads a description - "ctrl alt f1", "rawmouse lbutton
/// mouse_rightpress" - into an input expression.
///
/// SYNOPSIS:
/// ```zig
/// fn ParseIX(base: *CxBase, description: ?[*:0]const u8, ix: *cx.InputXpression) i32
/// ```
///
/// SINCE: 1.0. LVO -84.
///
/// INPUTS:
/// - `description` - the words, or null.
/// - `ix` - where the expression goes.
///
/// RESULT:
/// 0 when every word made sense; -1 when words were left that did not
/// (the expression is what came before them); -2 for a description that
/// is null or empty, whose expression matches nothing.
///
/// BEHAVIOR:
/// The words come in this order, each part optional:
///
///   [class] {[-]qualifier} [[-]upstroke] [key or button]
///
/// The class is one of ACTIVEWINDOW, DISKINSERTED, DISKREMOVED, EVENT,
/// INACTIVEWINDOW, NEWPOINTERPOS, NEWPREFS, RAWKEY, RAWMOUSE, TIMER,
/// TOUCH or USB; RAWKEY when none is given. Each qualifier named must be
/// held: LSHIFT, RSHIFT, CAPSLOCK, CONTROL (CTRL), LALT, RALT, LCOMMAND,
/// RCOMMAND, NUMERICPAD, REPEAT, LEFTBUTTON, MIDBUTTON, RBUTTON,
/// RELATIVEMOUSE, with LEFT_SHIFT, NUMPAD and the like for the same;
/// SHIFT, CAPS and ALT are either of a pair (CAPS: either shift or Caps
/// Lock). Every qualifier not named must not be held, but for
/// RELATIVEMOUSE; one named with `-` in front may be held or not.
/// UPSTROKE matches the key going up, -UPSTROKE either way. The key is a
/// name - F1 to F12, ESC, TAB, RETURN, ENTER, SPACE, BACKSPACE, DEL,
/// HELP, INSERT, HOME, END, PAGE_UP, PAGE_DOWN, UP, DOWN, LEFT, RIGHT,
/// COMMA, BREAK - or one character, the key that types it through the
/// default keymap (with the qualifiers that takes, so "ctrl A" is ctrl
/// and shift); with a keypad qualifier, the keypad's key of the
/// character. For RAWMOUSE the button: MOUSE_LEFTPRESS,
/// MOUSE_MIDDLEPRESS, MOUSE_RIGHTPRESS, MOUSE_WHEEL; the button's own
/// qualifier, held on its press and not on its release, does not count.
/// Case does not matter; spaces, tabs, commas and new lines separate
/// words. A description that names no key or button takes any code:
/// "ctrl" is any key with Control held, down or up, "rawmouse -lbutton
/// -mbutton -rbutton" every mouse event with no key held, "touch
/// -lbutton" every finger; "ctrl upstroke" is any key going up, the only
/// part of the code that counts then.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// With Caps Lock on, a description that does not name it does not
/// match: "-caps ctrl alt h" matches either way.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetFilter`, `MatchIX`, `InvertKeyMap`
///
/// EXAMPLES:
/// ```zig
/// var ix: cx.InputXpression = .{};
/// if (cb.ParseIX("-caps ctrl alt f1", &ix) != 0) return error.BadHotkey;
/// ```
pub fn ParseIX(base: *CxBase, description: ?[*:0]const u8, ix: *cx.InputXpression) i32 {
    ix.* = .{};
    const text = description orelse {
        ix.code = 0xFFFF_FFFF;
        return -2;
    };
    var words = _filter.Words{ .text = text };
    var word = words.next() orelse {
        ix.code = 0xFFFF_FFFF;
        return -2;
    };

    if (_filter.lookup(&_filter.classes, word)) |class| {
        ix.class = class;
        word = words.next() orelse return anyCode(ix, false);
    }

    // Qualifiers, each perhaps with "-" in front.
    while (true) {
        const any = word.len > 1 and word[0] == '-';
        const name = if (any) word[1..] else word;
        if (_filter.lookup(&_filter.qualifiers, name)) |bit| {
            if (any) ix.qual_mask &= ~bit else ix.qualifier |= bit;
        } else if (synonym(name)) |s| {
            ix.qual_same |= s.id;
            if (any) ix.qual_mask &= ~s.mask else ix.qualifier |= s.mask;
        } else break;
        word = words.next() orelse return anyCode(ix, false);
    }

    const any_way = word.len > 1 and word[0] == '-';
    if (_filter.same(if (any_way) word[1..] else word, _filter.upstroke)) {
        if (any_way) ix.code_mask &= ~ie.IECODE_UP_PREFIX else ix.code |= ie.IECODE_UP_PREFIX;
        word = words.next() orelse return anyCode(ix, true);
    }

    switch (ix.class) {
        ie.IECLASS_RAWMOUSE => {
            const button = _filter.lookup(&_filter.buttons, word) orelse return -1;
            ix.code |= button;
            ix.qual_mask &= ~buttonQualifier(button);
        },
        ie.IECLASS_RAWKEY => {
            if (_filter.lookup(&_filter.keys, word)) |key| {
                ix.code |= key;
            } else if (word.len == 1 and ix.qualifier & ie.IEQUALIFIER_NUMERICPAD != 0) {
                ix.code |= _filter.lookup(&_filter.keypad, word) orelse return -1;
            } else if (word.len == 1) {
                var event: ie.InputEvent = .{};
                if (!base.iface().InvertKeyMap(word[0], &event, null)) return -1;
                ix.code |= event.code;
                ix.qualifier |= event.qualifier;
            } else return -1;
        },
        else => return -1,
    }
    return if (words.next() == null) 0 else -1;
}

/// The end of a description that named no key: any code, but for the up
/// bit when UPSTROKE or -UPSTROKE said what it is. 0, for ParseIX.
fn anyCode(ix: *cx.InputXpression, upstroke: bool) i32 {
    ix.code_mask = if (upstroke) ix.code_mask & ie.IECODE_UP_PREFIX else 0;
    return 0;
}

/// The qualifier a button's press carries.
fn buttonQualifier(button: u32) u32 {
    return switch (button) {
        ie.IECODE_LBUTTON => ie.IEQUALIFIER_LEFTBUTTON,
        ie.IECODE_MBUTTON => ie.IEQUALIFIER_MIDBUTTON,
        ie.IECODE_RBUTTON => ie.IEQUALIFIER_RBUTTON,
        else => 0,
    };
}

fn synonym(name: []const u8) ?_filter.Synonym {
    for (_filter.synonyms) |s| {
        if (_filter.same(s.word, name)) return s;
    }
    return null;
}
