// SPDX-License-Identifier: MIT
//! `Git cat-file OBJECT [TYPE] [SIZE]`: an object of the repository the
//! current directory is in, shown - a commit or tag as its text, a tree
//! a line an entry (the mode, the type, the id, a tab, the name), a blob
//! as its bytes. TYPE prints only its type, SIZE only its size. OBJECT
//! is an id, the start of one, or a ref.

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const object = @import("object.zig");
const revision = @import("revision.zig");
const Repository = @import("repo.zig").Repository;
const Git = @import("context.zig").Git;

pub const template = "OBJECT/A,TYPE=T/S,SIZE=S/S";
const arg_object = 0;
const arg_type = 1;
const arg_size = 2;
pub const arg_count = 3;

pub fn run(git: *Git, argv: []const usize) i32 {
    const repo = Repository.find(git) orelse return dos.RETURN_ERROR;
    defer repo.close();
    const name: [*:0]const u8 = @ptrFromInt(argv[arg_object]);
    const id = revision.lookUp(repo, name) orelse return dos.RETURN_ERROR;
    var found = repo.objects.read(&id) orelse {
        git.say("%s names an object the repository does not have\n", .{name});
        return dos.RETURN_ERROR;
    };
    defer found.free(git.sys);
    if (argv[arg_type] != 0) {
        git.put(found.kind.name());
        git.put("\n");
        return dos.RETURN_OK;
    }
    if (argv[arg_size] != 0) {
        var digits: [24]u8 = undefined;
        var out: _git.Out = .{ .into = &digits };
        out.decimal(found.data.len);
        out.byte('\n');
        git.put(out.written());
        return dos.RETURN_OK;
    }
    if (found.kind != .tree) {
        git.put(found.data);
        return dos.RETURN_OK;
    }
    var entries: object.TreeEntries = .{ .body = found.data };
    while (entries.next()) |entry| {
        var line: [64]u8 = undefined;
        var out: _git.Out = .{ .into = &line };
        var mode: [6]u8 = undefined;
        var rest = entry.mode;
        var at: usize = mode.len;
        while (at > 0) {
            at -= 1;
            mode[at] = '0' + @as(u8, @intCast(rest & 7));
            rest >>= 3;
        }
        out.put(&mode);
        out.put(if (entry.mode == object.mode_tree) " tree " else if (entry.mode == object.mode_gitlink) " commit " else " blob ");
        out.hex(&entry.id);
        out.byte('\t');
        git.put(out.written());
        git.put(entry.name);
        git.put("\n");
    }
    if (entries.bad) {
        git.say("the tree is broken\n", .{});
        return dos.RETURN_ERROR;
    }
    return dos.RETURN_OK;
}
