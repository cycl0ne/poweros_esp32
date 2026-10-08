// SPDX-License-Identifier: MIT
//! LoadFilterRules: rules as text, parsed and put in force.

const sdk = @import("sdk");
const exec = sdk.exec;
const filter = sdk.filter;
const _base = @import("../filter_base.zig");
const FilterBase = _base.FilterBase;
const _rules = @import("_rules.zig");
const RuleSet = _rules.RuleSet;
const parse = @import("parse.zig");
const _hook = @import("../hook/_hook.zig");

/// Parses `text` as rules and puts them in force in place of the old
/// ones.
///
/// SYNOPSIS:
/// ```zig
/// fn LoadFilterRules(base: *FilterBase, text: [*]const u8, length: u32, err: ?*FilterError) u32
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `text` - the rules, `length` bytes, a line each, as `sdk.filter`
///   describes them; lines end with LF (a CR before it is a space).
/// - `err` - where a failure is said, or null.
///
/// RESULT:
/// `FILTERERR_OK`; or `FILTERERR_SYNTAX` (a word not understood, or one
/// that does not fit the rest of its rule), `FILTERERR_TWICE` (a match
/// given twice in a rule, or a second default for one interface),
/// `FILTERERR_NOMEM`, `FILTERERR_NOSTACK` (bsdsocket.library could not be
/// opened, or took no hook) - with the line, the column and the word in
/// `err` for the first two.
///
/// BEHAVIOR:
/// The whole text is parsed first: a failure leaves the rules in force as
/// they were. Then, the first time, the library's two hooks go into
/// bsdsocket.library's chains (AddPacketHook, PH_Keep); and the new rules
/// take the old ones' place at once, between one packet and the next.
/// Their counts start at 0. Empty text is a rule set with no rules: what
/// the noted exchanges and the stack's connections do not pass, passes
/// anyway.
///
/// CONTEXT:
/// - Waits: yes - for memory, and for bsdsocket.library's lock.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do: bsdsocket.library is opened on it for the
///   length of the call.
///
/// OWNERSHIP:
/// `text` is read during the call only; the rules are the library's.
///
/// NOTES:
/// While rules are in force the library stays in memory: bsdsocket.library
/// calls it for every packet. ClearFilterRules lets it go.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ClearFilterRules`, `GetFilterRules`, `sdk.filter`
///
/// EXAMPLES:
/// ```zig
/// const rules = "default in on wlan0 block\npass in on wlan0 proto tcp from 192.168.1.0/24 to port 23\n";
/// var err: filter.FilterError = .{};
/// if (fb.LoadFilterRules(rules, rules.len, &err) != filter.FILTERERR_OK) {
///     // err.line, err.column, err.word
/// }
/// ```
pub fn LoadFilterRules(base: *FilterBase, text: [*]const u8, length: u32, err: ?*filter.FilterError) u32 {
    const sys = base.sys_base;
    var own_err: filter.FilterError = .{};
    const into = err orelse &own_err;
    into.* = .{};
    const source = text[0..length];
    const room = parse.lines(source);
    const memory = sys.AllocVec(RuleSet.bytesFor(room, room), exec.MEMF_ANY) orelse {
        into.code = filter.FILTERERR_NOMEM;
        return filter.FILTERERR_NOMEM;
    };
    const bytes: [*]align(8) u8 = @ptrCast(@alignCast(memory));
    const set = RuleSet.make(bytes[0..RuleSet.bytesFor(room, room)], room, room);
    const code = parse.parse(source, set, into);
    if (code != filter.FILTERERR_OK) {
        sys.FreeVec(memory);
        return code;
    }
    if (!_hook.hookIn(base)) {
        sys.FreeVec(memory);
        into.code = filter.FILTERERR_NOSTACK;
        return filter.FILTERERR_NOSTACK;
    }
    sys.AcquireLock(&base.lock);
    const old = base.rules;
    base.rules = set;
    sys.ReleaseLock(&base.lock);
    if (old) |gone| sys.FreeVec(gone);
    return filter.FILTERERR_OK;
}
