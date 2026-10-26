// SPDX-License-Identifier: MIT
//! Git: repositories in git's own format, worked with the way git works
//! with them - one command, its first word the verb, the rest read by
//! that verb's own template. Built against the SDK only.
//!
//!   Git VERB ...
//!
//! | Verb | What it does |
//! |------|--------------|
//! | `ls-remote URL [HEADS] [TAGS] [SYMREF]` | a remote repository's refs |
//! | `clone URL [DIR] [DEPTH=n] [BRANCH=name] [QUIET]` | a remote repository copied, its branch checked out |
//! | `fetch [REMOTE] [DEPTH=n] [QUIET]` | what a remote has that is not here, fetched |
//! | `pull [REMOTE] [QUIET]` | the branch brought forward to the one it follows |
//! | `checkout NAME` | the work tree moved to another branch or commit |
//! | `init [DIRECTORY]` | an empty repository made |
//! | `add PATHS/M [ALL]` | files put in the index for the next commit |
//! | `rm PATHS/M [CACHED] [RECURSIVE] [FORCE]` | files taken out of the index and the work tree |
//! | `commit MESSAGE=M/K [ALL]` | what the index holds made a commit |
//! | `push [REMOTE] [REFS/M] [FORCE] [TAGS] [SETUPSTREAM] [QUIET]` | branches and tags set on a remote, what it lacks sent |
//! | `remote [add NAME URL] [remove NAME] [VERBOSE]` | the remotes, listed, added or taken out |
//! | `status [SHORT]` | what has changed, staged or not, and what is untracked |
//! | `log [REVISION] [COUNT=n] [ONELINE]` | the history, newest first |
//! | `diff [CACHED]` | the paths that changed |
//! | `branch [REMOTES] [ALL]` | the branches |
//! | `cat-file OBJECT [TYPE] [SIZE]` | an object of the repository, shown |
//!
//! `Git ?` lists the verbs; `Git <verb> ?` shows the verb's template and
//! reads its arguments from the console.
//!
//! A remote is `https://host/path` or `http://...`, spoken to over smart
//! HTTP (LIBS:http.library): in git's protocol version 2 where the server
//! speaks it, version 0 where it does not. A server that asks for
//! credentials gets the user and token the URL holds
//! (`https://user:token@host/path`), else the first matching line of
//! ENVARC:Sys/net/git-credentials (git's credential store: a URL with
//! them in it, a line each), else what is typed on the console - which is
//! then offered to that file. Over HTTPS the server's certificate is
//! checked against the system's trusted roots; the clock must be set
//! (TimeSync).
//!
//! A remote is also `ssh://[user@]host[:port]/path` or `user@host:path`,
//! reached through DEVS:ssh.device as C:net/SSH reaches a host: the host
//! key checked against ENVARC:Sys/net/known_hosts (a new host is asked
//! about), the login with the key ENVARC:Sys/net/id_ed25519 (`SSH
//! KEYGEN` makes it), else a password typed on the console.
//!
//! A remote named in `.git/config` - `origin` for a clone, any that
//! `Git remote add` makes - stands for its URL; without one, `fetch`,
//! `pull` and `push` take the current branch's remote, else `origin`.
//!
//! The repository's objects must be named by SHA-1.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const crypto = sdk.crypto;
const compression = sdk.compression;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const context = @import("context.zig");
const lsremote = @import("lsremote.zig");
const catfile = @import("catfile.zig");
const clone = @import("clone.zig");
const checkout = @import("checkout.zig");
const fetch = @import("fetch.zig");
const pull = @import("pull.zig");
const init = @import("init.zig");
const add = @import("add.zig");
const rm = @import("rm.zig");
const commit = @import("commit.zig");
const push = @import("push.zig");
const remote = @import("remote.zig");
const status = @import("status.zig");
const log = @import("log.zig");
const diff = @import("diff.zig");
const branch = @import("branch.zig");
const Git = context.Git;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = context.COMMAND_NAME;
const VERSION_STRING = "\x00$VER: Git 1.1 (26.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "VERB,ARGS/F";
const arg_verb = 0;
const args_most = 16;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOVERB = "%s: there is no verb %s - Git ? lists them\n";
const MSG_USAGE = "Usage: Git VERB ...  (Git VERB ? shows the verb's template)\n";

const Verb = struct {
    name: []const u8,
    template: [*:0]const u8,
    arg_count: usize,
    run: *const fn (git: *Git, argv: []const usize) i32,
    what: []const u8,
};

const verbs = [_]Verb{
    .{ .name = "ls-remote", .template = lsremote.template, .arg_count = lsremote.arg_count, .run = lsremote.run, .what = "a remote repository's refs" },
    .{ .name = "clone", .template = clone.template, .arg_count = clone.arg_count, .run = clone.run, .what = "a remote repository copied, its branch checked out" },
    .{ .name = "fetch", .template = fetch.template, .arg_count = fetch.arg_count, .run = fetch.run, .what = "what a remote has that is not here, fetched" },
    .{ .name = "pull", .template = pull.template, .arg_count = pull.arg_count, .run = pull.run, .what = "the branch brought forward to the one it follows" },
    .{ .name = "checkout", .template = checkout.template, .arg_count = checkout.arg_count, .run = checkout.run, .what = "the work tree moved to another branch or commit" },
    .{ .name = "init", .template = init.template, .arg_count = init.arg_count, .run = init.run, .what = "an empty repository made" },
    .{ .name = "add", .template = add.template, .arg_count = add.arg_count, .run = add.run, .what = "files put in the index for the next commit" },
    .{ .name = "rm", .template = rm.template, .arg_count = rm.arg_count, .run = rm.run, .what = "files taken out of the index and the work tree" },
    .{ .name = "commit", .template = commit.template, .arg_count = commit.arg_count, .run = commit.run, .what = "what the index holds made a commit" },
    .{ .name = "push", .template = push.template, .arg_count = push.arg_count, .run = push.run, .what = "branches and tags set on a remote, what it lacks sent" },
    .{ .name = "remote", .template = remote.template, .arg_count = remote.arg_count, .run = remote.run, .what = "the remotes, listed, added or taken out" },
    .{ .name = "status", .template = status.template, .arg_count = status.arg_count, .run = status.run, .what = "what has changed, staged or not, and what is untracked" },
    .{ .name = "log", .template = log.template, .arg_count = log.arg_count, .run = log.run, .what = "the history, newest first" },
    .{ .name = "diff", .template = diff.template, .arg_count = diff.arg_count, .run = diff.run, .what = "the paths that changed" },
    .{ .name = "branch", .template = branch.template, .arg_count = branch.arg_count, .run = branch.run, .what = "the branches" },
    .{ .name = "cat-file", .template = catfile.template, .arg_count = catfile.arg_count, .run = catfile.run, .what = "an object of the repository, shown" },
};

comptime {
    for (verbs) |verb| {
        if (verb.arg_count > args_most) @compileError("a verb has more arguments than there are slots");
    }
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    // The line read once, so a verb's '?' reads the console, not it again.
    var first: [2]usize = @splat(0);
    var first_rda: dos.RDArgs = .{ .flags = dos.RDAF_NOPROMPT };
    const line_args = dl.ReadArgs(template, &first, &first_rda) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(line_args);
    if (first[arg_verb] == 0) {
        usage(dl);
        return dos.RETURN_WARN;
    }
    const verb_text: [*:0]const u8 = @ptrFromInt(first[arg_verb]);
    if (verb_text[0] == '?' and verb_text[1] == 0) {
        usage(dl);
        return dos.RETURN_OK;
    }
    const verb = for (&verbs) |*each| {
        if (sameWord(each.name, verb_text)) break each;
    } else {
        _ = Printf(dl, MSG_NOVERB, .{ @as([*:0]const u8, COMMAND_NAME), verb_text });
        return dos.RETURN_ERROR;
    };

    // The rest of the line as typed - quotes and all - for the verb's
    // template.
    const rest = afterFirstItem(args[0..len]);
    const memory = sys.AllocVec(rest.len + 2, exec.MEMF_ANY) orelse {
        _ = Printf(dl, "%s: no memory\n", .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const text: [*]u8 = @ptrCast(memory);
    @memcpy(text[0..rest.len], rest);
    text[rest.len] = '\n';
    var argv: [args_most]usize = @splat(0);
    var verb_rda: dos.RDArgs = .{ .source = .{ .buffer = text, .length = @intCast(rest.len + 1) } };
    const verb_args = dl.ReadArgs(verb.template, &argv, &verb_rda) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(verb_args);

    const crypto_lib = sys.OpenLibrary(crypto.CRYPTONAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ @as([*:0]const u8, COMMAND_NAME), @as([*:0]const u8, crypto.CRYPTONAME) });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(crypto_lib);
    const compression_lib = sys.OpenLibrary(compression.COMPRESSIONNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ @as([*:0]const u8, COMMAND_NAME), @as([*:0]const u8, compression.COMPRESSIONNAME) });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(compression_lib);

    var git: Git = .{
        .sys = sys,
        .dl = dl,
        .cb = @ptrCast(crypto_lib),
        .zb = @ptrCast(compression_lib),
        .output = dl.Output(),
    };
    defer git.close();
    return verb.run(&git, argv[0..verb.arg_count]);
}

fn usage(dl: *DosBase) void {
    _ = Printf(dl, MSG_USAGE, .{});
    for (verbs) |verb| {
        _ = dl.WriteChars("  ", 2);
        _ = dl.WriteChars(verb.name.ptr, @intCast(verb.name.len));
        var pad = verb.name.len;
        while (pad < 12) : (pad += 1) _ = dl.WriteChars(" ", 1);
        _ = dl.WriteChars(verb.what.ptr, @intCast(verb.what.len));
        _ = dl.WriteChars("\n", 1);
    }
}

/// Whether the typed verb is `name`, its case not counted.
fn sameWord(name: []const u8, typed: [*:0]const u8) bool {
    for (name, 0..) |char, at| {
        const given = typed[at];
        const lowered = if (given >= 'A' and given <= 'Z') given + 32 else given;
        if (lowered != char) return false;
    }
    return typed[name.len] == 0;
}

/// What follows the line's first item - a word, or a quoted one - its
/// line end left off.
fn afterFirstItem(line: []const u8) []const u8 {
    var at: usize = 0;
    while (at < line.len and (line[at] == ' ' or line[at] == '\t')) at += 1;
    if (at < line.len and line[at] == '"') {
        at += 1;
        while (at < line.len and line[at] != '"' and line[at] != '\n') : (at += 1) {
            if (line[at] == '*' and at + 1 < line.len) at += 1;
        }
        if (at < line.len and line[at] == '"') at += 1;
    } else {
        while (at < line.len and line[at] != ' ' and line[at] != '\t' and line[at] != '\n' and line[at] != '=') at += 1;
    }
    var end = line.len;
    while (end > at and (line[end - 1] == '\n' or line[end - 1] == '\r')) end -= 1;
    return line[at..end];
}
