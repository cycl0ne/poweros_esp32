// SPDX-License-Identifier: MIT
//! GetFilterRules: the rules and defaults in force, with their counts.

const sdk = @import("sdk");
const filter = sdk.filter;
const _base = @import("../filter_base.zig");
const FilterBase = _base.FilterBase;

/// Hands back the rules and the defaults in force, in the order of their
/// lines, each with how many packets it decided.
///
/// SYNOPSIS:
/// ```zig
/// fn GetFilterRules(base: *FilterBase, into: ?[*]FilterRuleInfo, count: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `into` - room for `count` FilterRuleInfo; may be null when `count`
///   is 0.
///
/// RESULT:
/// How many rules and defaults there are, even when `into` held fewer; 0
/// with no rules in force.
///
/// BEHAVIOR:
/// As many as fit are written, in the order of their lines: `kind` says a
/// rule from a default, `action` what it does, `text` is the line as
/// written, without its comment.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `into` is the caller's.
///
/// NOTES:
/// Counts start at 0 with each load.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LoadFilterRules`, `GetFilterFlows`
///
/// EXAMPLES:
/// ```zig
/// var rules: [32]filter.FilterRuleInfo = undefined;
/// const total = fb.GetFilterRules(&rules, rules.len);
/// for (rules[0..@min(total, rules.len)]) |rule| _ = rule.hits;
/// ```
pub fn GetFilterRules(base: *FilterBase, into: ?[*]filter.FilterRuleInfo, count: u32) u32 {
    const sys = base.sys_base;
    const room: []filter.FilterRuleInfo = if (into) |many| many[0..count] else &.{};
    sys.AcquireLock(&base.lock);
    defer sys.ReleaseLock(&base.lock);
    const set = base.rules orelse return 0;
    const rules = set.rules();
    const defaults = set.defaults();
    // The two lists merged by line: each is in the file's order already.
    var rule_at: usize = 0;
    var default_at: usize = 0;
    var written: usize = 0;
    while (rule_at < rules.len or default_at < defaults.len) : (written += 1) {
        const take_rule = default_at == defaults.len or (rule_at < rules.len and rules[rule_at].line < defaults[default_at].line);
        if (written >= room.len) {
            if (take_rule) rule_at += 1 else default_at += 1;
            continue;
        }
        if (take_rule) {
            const rule = &rules[rule_at];
            room[written] = .{ .kind = filter.FILTERINFO_RULE, .action = @intFromEnum(rule.action), .line = rule.line, .hits = rule.hits, .text = rule.text };
            rule_at += 1;
        } else {
            const each = &defaults[default_at];
            room[written] = .{ .kind = filter.FILTERINFO_DEFAULT, .action = @intFromEnum(each.action), .line = each.line, .hits = each.hits, .text = each.text };
            default_at += 1;
        }
    }
    return @intCast(rules.len + defaults.len);
}
