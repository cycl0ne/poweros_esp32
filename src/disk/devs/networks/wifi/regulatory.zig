// SPDX-License-Identifier: MIT
//! What the radio may send where: the country codes the radio's library
//! knows (`regdomain_table`) and, for each kind of rule set, its channels,
//! widest bandwidth and highest power (`regulatory_data`). The library
//! looks a country up here when it is set, and uses the rule set for the
//! channels it scans and the power it sends at; the table ends with a
//! `##` row it stops at. The radio is 2.4 GHz only, so every rule set is
//! about channels 1 to 14. Data, and nothing the device itself reads.

/// One run of channels and its limits (`wifi_reg_rule_t`): the bandwidth
/// in bits 0-2 (1: 20 MHz, 2: 40 MHz), the highest EIRP in dBm in bits
/// 3-8, bit 9 set for a channel that needs radar detection.
pub const Rule = extern struct {
    start_channel: u8,
    end_channel: u8,
    limits: u16,
};

/// A rule set (`wifi_regulatory_t`): up to two runs of channels.
pub const Regulatory = extern struct {
    rule_count: u8,
    rules: [2]Rule,
};

/// A country and the rule set it follows (`wifi_regdomain_t`).
pub const Domain = extern struct {
    code: [2]u8,
    rule_set: u8,
};

fn rule(start: u8, end: u8, bandwidth: u16, eirp: u16, dfs: u16) Rule {
    return .{ .start_channel = start, .end_channel = end, .limits = bandwidth | eirp << 3 | dfs << 9 };
}

const none: Rule = .{ .start_channel = 0, .end_channel = 0, .limits = 0 };

/// The rule sets, in the order the country table numbers them.
const RuleSet = enum(u8) {
    default,
    ce,
    acma,
    anatel,
    ised,
    srrc,
    ofca,
    wpc,
    mic,
    kcc,
    ifetel,
    rcm,
    ncc,
    fcc,
    gt,
    ke,
    kp,
    my,
    pk,
    tg,
    end,
};

pub export const regulatory_data = [_]Regulatory{
    .{ .rule_count = 1, .rules = .{ rule(1, 11, 2, 20, 0), none } }, // default
    .{ .rule_count = 1, .rules = .{ rule(1, 13, 2, 20, 0), none } }, // ce
    .{ .rule_count = 1, .rules = .{ rule(1, 13, 2, 36, 0), none } }, // acma
    .{ .rule_count = 1, .rules = .{ rule(1, 13, 2, 30, 0), none } }, // anatel
    .{ .rule_count = 1, .rules = .{ rule(1, 13, 2, 36, 0), none } }, // ised
    .{ .rule_count = 1, .rules = .{ rule(1, 13, 2, 20, 0), none } }, // srrc
    .{ .rule_count = 1, .rules = .{ rule(1, 13, 2, 36, 0), none } }, // ofca
    .{ .rule_count = 1, .rules = .{ rule(1, 13, 2, 30, 0), none } }, // wpc
    .{ .rule_count = 2, .rules = .{ rule(1, 13, 2, 20, 0), rule(14, 14, 1, 20, 0) } }, // mic
    .{ .rule_count = 1, .rules = .{ rule(1, 13, 2, 23, 0), none } }, // kcc
    .{ .rule_count = 1, .rules = .{ rule(1, 13, 2, 20, 0), none } }, // ifetel
    .{ .rule_count = 1, .rules = .{ rule(1, 13, 2, 36, 0), none } }, // rcm
    .{ .rule_count = 1, .rules = .{ rule(1, 13, 2, 30, 0), none } }, // ncc
    .{ .rule_count = 1, .rules = .{ rule(1, 11, 2, 30, 0), none } }, // fcc
    .{ .rule_count = 1, .rules = .{ rule(1, 13, 2, 26, 0), none } }, // gt
    .{ .rule_count = 1, .rules = .{ rule(1, 13, 2, 33, 0), none } }, // ke
    .{ .rule_count = 1, .rules = .{ rule(1, 13, 1, 20, 0), none } }, // kp
    .{ .rule_count = 1, .rules = .{ rule(1, 14, 2, 26, 0), none } }, // my
    .{ .rule_count = 1, .rules = .{ rule(1, 14, 2, 30, 0), none } }, // pk
    .{ .rule_count = 1, .rules = .{ rule(1, 13, 2, 20, 1), none } }, // tg
};

pub export const regdomain_table = [_]Domain{
    .{ .code = "01".*, .rule_set = @intFromEnum(RuleSet.default) },
    .{ .code = "EU".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "AD".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "AE".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "AF".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "AI".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "AL".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "AM".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "AN".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "AR".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "AS".*, .rule_set = @intFromEnum(RuleSet.fcc) },
    .{ .code = "AT".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "AU".*, .rule_set = @intFromEnum(RuleSet.rcm) },
    .{ .code = "AW".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "AZ".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "BA".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "BB".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "BD".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "BE".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "BF".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "BG".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "BH".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "BL".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "BM".*, .rule_set = @intFromEnum(RuleSet.fcc) },
    .{ .code = "BN".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "BO".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "BR".*, .rule_set = @intFromEnum(RuleSet.ncc) },
    .{ .code = "BS".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "BT".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "BW".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "BY".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "BZ".*, .rule_set = @intFromEnum(RuleSet.ncc) },
    .{ .code = "CA".*, .rule_set = @intFromEnum(RuleSet.rcm) },
    .{ .code = "CF".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "CH".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "CI".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "CL".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "CN".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "CO".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "CR".*, .rule_set = @intFromEnum(RuleSet.rcm) },
    .{ .code = "CU".*, .rule_set = @intFromEnum(RuleSet.kcc) },
    .{ .code = "CX".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "CY".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "CZ".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "DE".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "DK".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "DM".*, .rule_set = @intFromEnum(RuleSet.fcc) },
    .{ .code = "DO".*, .rule_set = @intFromEnum(RuleSet.fcc) },
    .{ .code = "DZ".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "EC".*, .rule_set = @intFromEnum(RuleSet.ncc) },
    .{ .code = "EE".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "EG".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "ES".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "ET".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "FI".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "FM".*, .rule_set = @intFromEnum(RuleSet.fcc) },
    .{ .code = "FO".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "FR".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "GB".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "GD".*, .rule_set = @intFromEnum(RuleSet.fcc) },
    .{ .code = "GE".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "GF".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "GH".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "GI".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "GL".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "GP".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "GR".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "GT".*, .rule_set = @intFromEnum(RuleSet.gt) },
    .{ .code = "GU".*, .rule_set = @intFromEnum(RuleSet.fcc) },
    .{ .code = "GY".*, .rule_set = @intFromEnum(RuleSet.ncc) },
    .{ .code = "HK".*, .rule_set = @intFromEnum(RuleSet.rcm) },
    .{ .code = "HN".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "HR".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "HT".*, .rule_set = @intFromEnum(RuleSet.fcc) },
    .{ .code = "HU".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "ID".*, .rule_set = @intFromEnum(RuleSet.gt) },
    .{ .code = "IE".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "IL".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "IM".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "IN".*, .rule_set = @intFromEnum(RuleSet.ncc) },
    .{ .code = "IR".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "IS".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "IT".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "JM".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "JO".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "JP".*, .rule_set = @intFromEnum(RuleSet.mic) },
    .{ .code = "KE".*, .rule_set = @intFromEnum(RuleSet.ke) },
    .{ .code = "KH".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "KN".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "KP".*, .rule_set = @intFromEnum(RuleSet.kp) },
    .{ .code = "KR".*, .rule_set = @intFromEnum(RuleSet.kcc) },
    .{ .code = "KW".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "KY".*, .rule_set = @intFromEnum(RuleSet.ncc) },
    .{ .code = "KZ".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "LB".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "LC".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "LI".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "LK".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "LS".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "LT".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "LU".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "LV".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "MA".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "MC".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "MD".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "ME".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "MF".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "MH".*, .rule_set = @intFromEnum(RuleSet.fcc) },
    .{ .code = "MK".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "MN".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "MO".*, .rule_set = @intFromEnum(RuleSet.kcc) },
    .{ .code = "MP".*, .rule_set = @intFromEnum(RuleSet.fcc) },
    .{ .code = "MQ".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "MR".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "MT".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "MU".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "MV".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "MW".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "MX".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "MY".*, .rule_set = @intFromEnum(RuleSet.my) },
    .{ .code = "NA".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "NG".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "NI".*, .rule_set = @intFromEnum(RuleSet.fcc) },
    .{ .code = "NL".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "NO".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "NP".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "NZ".*, .rule_set = @intFromEnum(RuleSet.rcm) },
    .{ .code = "OM".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "PA".*, .rule_set = @intFromEnum(RuleSet.rcm) },
    .{ .code = "PE".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "PF".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "PG".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "PH".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "PK".*, .rule_set = @intFromEnum(RuleSet.pk) },
    .{ .code = "PL".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "PM".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "PR".*, .rule_set = @intFromEnum(RuleSet.fcc) },
    .{ .code = "PT".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "PW".*, .rule_set = @intFromEnum(RuleSet.fcc) },
    .{ .code = "PY".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "QA".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "RE".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "RO".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "RS".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "RU".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "RW".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "SA".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "SE".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "SG".*, .rule_set = @intFromEnum(RuleSet.kcc) },
    .{ .code = "SI".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "SK".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "SM".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "SN".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "SR".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "SV".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "SX".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "SY".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "TC".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "TD".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "TG".*, .rule_set = @intFromEnum(RuleSet.tg) },
    .{ .code = "TH".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "TN".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "TR".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "TT".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "TW".*, .rule_set = @intFromEnum(RuleSet.ncc) },
    .{ .code = "TZ".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "UA".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "UG".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "US".*, .rule_set = @intFromEnum(RuleSet.fcc) },
    .{ .code = "UY".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "UZ".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "VA".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "VC".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "VE".*, .rule_set = @intFromEnum(RuleSet.ncc) },
    .{ .code = "VI".*, .rule_set = @intFromEnum(RuleSet.fcc) },
    .{ .code = "VN".*, .rule_set = @intFromEnum(RuleSet.kcc) },
    .{ .code = "VU".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "WF".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "WS".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "YE".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "YT".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "ZA".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "ZW".*, .rule_set = @intFromEnum(RuleSet.ifetel) },
    .{ .code = "##".*, .rule_set = @intFromEnum(RuleSet.end) },
};
