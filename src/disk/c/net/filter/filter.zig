// SPDX-License-Identifier: MIT
//! Filter: the packet filter's rules loaded, shown, and taken out again
//! (filter.library). Built against the SDK only.
//!
//!   Filter LOAD/S,FROM/K,SHOW/S,FLOWS/S,OFF/S,QUIET/S
//!
//! LOAD reads the rules from FROM - `ENVARC:Sys/net/filter` unless given -
//! and puts them in force in place of any before; a line it does not
//! understand loads nothing, and is said with its line, its column and
//! the word. SHOW lists the rules and the defaults in force with how many
//! packets each decided. FLOWS lists the exchanges this machine began
//! whose answers pass without a rule. OFF takes the rules out: every
//! packet passes again. With none of them: SHOW. QUIET says nothing when
//! all is well.
//!
//! `S:Network-Startup` runs `Filter LOAD QUIET` before it brings up an
//! interface, when `ENVARC:Sys/net/filter` is there. The rule language is
//! in the network guide (sdk/docs/guides/network.md).

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const filter = sdk.filter;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const FilterBase = sdk.interface.filter.FilterBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Filter";
const VERSION_STRING = "\x00$VER: Filter 1.0 (08.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "LOAD/S,FROM/K,SHOW/S,FLOWS/S,OFF/S,QUIET/S";
const arg_load = 0;
const arg_from = 1;
const arg_show = 2;
const arg_flows = 3;
const arg_off = 4;
const arg_quiet = 5;

/// The most of a rules file read.
const file_max = 64 * 1024;
/// The most rules and exchanges listed.
const listed_max = 128;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOFILE = "%s: can't read %s\n";
const MSG_TOOBIG = "%s: %s is larger than %lu bytes\n";
const MSG_BAD = "%s: %s, line %lu, column %lu: '%s' not understood\n";
const MSG_TWICE = "%s: %s, line %lu, column %lu: '%s' is said twice\n";
const MSG_NOMEM = "%s: no memory for the rules\n";
const MSG_NOSTACK = "%s: bsdsocket.library takes no filter\n";
const MSG_LOADED = "%s: %lu rules and defaults from %s in force\n";
const MSG_OFF = "%s: no rules in force; every packet passes\n";
const MSG_NONE = "No rules in force.\n";
const MSG_HEAD = " Line      Hits  Rule\n";
const MSG_RULE = "%5lu %9lu  %s\n";
const MSG_NOFLOWS = "No exchanges.\n";
const MSG_FLOW = "%-5s %s port %lu -> %s port %lu, quiet %lu.%lu s\n";
const MSG_ECHO = "%-5s %s -> %s, identifier %lu, quiet %lu.%lu s\n";
const MSG_MORE = "... and %lu more\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [6]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const quiet = argv[arg_quiet] != 0;

    const filter_lib = sys.OpenLibrary(filter.FILTERNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, filter.FILTERNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(filter_lib);
    const fb: *FilterBase = @ptrCast(filter_lib);

    var result: i32 = dos.RETURN_OK;
    if (argv[arg_off] != 0) {
        fb.ClearFilterRules();
        if (!quiet) _ = Printf(dl, MSG_OFF, .{COMMAND_NAME});
    }
    if (argv[arg_load] != 0) {
        const from = dos.rdargs.string(argv[arg_from]) orelse filter.FILTER_FILE;
        result = load(sys, dl, fb, from, quiet);
    }
    const nothing_asked = argv[arg_load] == 0 and argv[arg_off] == 0 and argv[arg_flows] == 0;
    if (argv[arg_show] != 0 or nothing_asked) show(sys, dl, fb);
    if (argv[arg_flows] != 0) flows(sys, dl, fb);
    return result;
}

/// The rules file read and put in force: said how it went.
fn load(sys: *ExecBase, dl: *DosBase, fb: *FilterBase, from: [*:0]const u8, quiet: bool) i32 {
    const file = dl.Open(from, dos.MODE_OLDFILE) orelse {
        _ = Printf(dl, MSG_NOFILE, .{ COMMAND_NAME, from });
        return dos.RETURN_ERROR;
    };
    defer _ = dl.Close(file);
    _ = dl.Seek(file, 0, dos.OFFSET_END);
    const size = dl.Seek(file, 0, dos.OFFSET_BEGINNING);
    if (size < 0) {
        _ = Printf(dl, MSG_NOFILE, .{ COMMAND_NAME, from });
        return dos.RETURN_ERROR;
    }
    if (size > file_max) {
        _ = Printf(dl, MSG_TOOBIG, .{ COMMAND_NAME, from, @as(u64, file_max) });
        return dos.RETURN_ERROR;
    }
    const length: u32 = @intCast(size);
    const memory = sys.AllocVec(@max(length, 1), exec.MEMF_ANY) orelse {
        _ = Printf(dl, MSG_NOMEM, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const text: [*]u8 = @ptrCast(memory);
    if (dl.Read(file, text, @intCast(length)) != length) {
        _ = Printf(dl, MSG_NOFILE, .{ COMMAND_NAME, from });
        return dos.RETURN_ERROR;
    }
    var err: filter.FilterError = .{};
    const word: [*:0]const u8 = @ptrCast(&err.word);
    switch (fb.LoadFilterRules(text, length, &err)) {
        filter.FILTERERR_OK => {},
        filter.FILTERERR_SYNTAX => {
            _ = Printf(dl, MSG_BAD, .{ COMMAND_NAME, from, @as(u64, err.line), @as(u64, err.column), word });
            return dos.RETURN_ERROR;
        },
        filter.FILTERERR_TWICE => {
            _ = Printf(dl, MSG_TWICE, .{ COMMAND_NAME, from, @as(u64, err.line), @as(u64, err.column), word });
            return dos.RETURN_ERROR;
        },
        filter.FILTERERR_NOMEM => {
            _ = Printf(dl, MSG_NOMEM, .{COMMAND_NAME});
            return dos.RETURN_FAIL;
        },
        else => {
            _ = Printf(dl, MSG_NOSTACK, .{COMMAND_NAME});
            return dos.RETURN_FAIL;
        },
    }
    if (!quiet) _ = Printf(dl, MSG_LOADED, .{ COMMAND_NAME, @as(u64, fb.GetFilterRules(null, 0)), from });
    return dos.RETURN_OK;
}

/// The rules and defaults in force, with their counts.
fn show(sys: *ExecBase, dl: *DosBase, fb: *FilterBase) void {
    const memory = sys.AllocVec(listed_max * @sizeOf(filter.FilterRuleInfo), exec.MEMF_ANY) orelse return;
    defer sys.FreeVec(memory);
    const rules: [*]filter.FilterRuleInfo = @ptrCast(@alignCast(memory));
    const total = fb.GetFilterRules(rules, listed_max);
    if (total == 0) {
        _ = Printf(dl, MSG_NONE, .{});
        return;
    }
    _ = Printf(dl, MSG_HEAD, .{});
    for (rules[0..@min(total, listed_max)]) |*rule| {
        _ = Printf(dl, MSG_RULE, .{ @as(u64, rule.line), @as(u64, rule.hits), @as([*:0]const u8, @ptrCast(&rule.text)) });
    }
    if (total > listed_max) _ = Printf(dl, MSG_MORE, .{@as(u64, total - listed_max)});
}

/// The exchanges whose answers pass without a rule.
fn flows(sys: *ExecBase, dl: *DosBase, fb: *FilterBase) void {
    const memory = sys.AllocVec(listed_max * @sizeOf(filter.FilterFlowInfo), exec.MEMF_ANY) orelse return;
    defer sys.FreeVec(memory);
    const list: [*]filter.FilterFlowInfo = @ptrCast(@alignCast(memory));
    const total = fb.GetFilterFlows(list, listed_max);
    if (total == 0) {
        _ = Printf(dl, MSG_NOFLOWS, .{});
        return;
    }
    // The addresses as text: bsdsocket.library's to write.
    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return;
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);
    for (list[0..@min(total, listed_max)]) |*flow| {
        var local: [bsd.INET6_ADDRSTRLEN]u8 = @splat(0);
        var remote: [bsd.INET6_ADDRSTRLEN]u8 = @splat(0);
        addressText(sb, &flow.local, &local);
        addressText(sb, &flow.remote, &remote);
        const seconds = @as(u64, flow.idle_ms / 1000);
        const tenths = @as(u64, flow.idle_ms % 1000 / 100);
        const local_text: [*:0]const u8 = @ptrCast(&local);
        const remote_text: [*:0]const u8 = @ptrCast(&remote);
        if (flow.protocol == @as(u8, @intCast(bsd.IPPROTO_UDP))) {
            _ = Printf(dl, MSG_FLOW, .{ "UDP", local_text, @as(u64, flow.local_port), remote_text, @as(u64, flow.remote_port), seconds, tenths });
        } else {
            const name: [*:0]const u8 = if (flow.protocol == @as(u8, @intCast(bsd.IPPROTO_ICMP))) "ICMP" else "ICMP6";
            _ = Printf(dl, MSG_ECHO, .{ name, local_text, remote_text, @as(u64, flow.local_port), seconds, tenths });
        }
    }
    if (total > listed_max) _ = Printf(dl, MSG_MORE, .{@as(u64, total - listed_max)});
}

/// An address as text: an IPv4-mapped one as IPv4.
fn addressText(sb: *SocketBase, address: *const bsd.in6_addr, into: *[bsd.INET6_ADDRSTRLEN]u8) void {
    const bytes = &address.s6_addr;
    const mapped = for (bytes[0..10]) |byte| {
        if (byte != 0) break false;
    } else bytes[10] == 0xFF and bytes[11] == 0xFF;
    if (mapped) {
        _ = sb.Inet_NtoP(bsd.AF_INET, bytes[12..16], into, into.len);
    } else {
        _ = sb.Inet_NtoP(bsd.AF_INET6, address, into, into.len);
    }
}
