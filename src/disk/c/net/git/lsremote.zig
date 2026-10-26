// SPDX-License-Identifier: MIT
//! `Git ls-remote URL [HEADS] [TAGS] [SYMREF]`: a remote repository's
//! refs, a line each - the object's id, a tab, the ref's name. A tag
//! that names a tag object has a second line for the object it peels to,
//! the name followed by `^{}`. HEADS lists only the branches, TAGS only
//! the tags; SYMREF puts `ref: <target>` before the line of a symbolic
//! ref (HEAD).

const sdk = @import("sdk");
const dos = sdk.dos;
const _git = @import("_git.zig");
const transport = @import("transport.zig");
const Connection = @import("connect.zig").Connection;
const Git = @import("context.zig").Git;

pub const template = "URL/A,HEADS/S,TAGS/S,SYMREF/S";
const arg_url = 0;
const arg_heads = 1;
const arg_tags = 2;
const arg_symref = 3;
pub const arg_count = 4;

const Listing = struct {
    git: *Git,
    symref: bool,
};

pub fn run(git: *Git, argv: []const usize) i32 {
    const connection = Connection.open(git, @ptrFromInt(argv[arg_url]), "git-upload-pack") orelse return dos.RETURN_ERROR;
    defer connection.close();
    var prefixes: [2][]const u8 = undefined;
    var count: usize = 0;
    if (argv[arg_heads] != 0) {
        prefixes[count] = "refs/heads/";
        count += 1;
    }
    if (argv[arg_tags] != 0) {
        prefixes[count] = "refs/tags/";
        count += 1;
    }
    var listing: Listing = .{ .git = git, .symref = argv[arg_symref] != 0 };
    if (!connection.remote.listRefs(prefixes[0..count], show, &listing)) {
        connection.sayFailure();
        return dos.RETURN_ERROR;
    }
    return dos.RETURN_OK;
}

fn show(context: *anyopaque, ref: *const transport.Ref) bool {
    const listing: *Listing = @ptrCast(@alignCast(context));
    const git = listing.git;
    if (listing.symref) {
        if (ref.target) |target| {
            git.put("ref: ");
            git.put(target);
            git.put("\t");
            git.put(ref.name);
            git.put("\n");
        }
    }
    if (!ref.unborn) {
        line(git, &ref.id, ref.name, "");
        if (ref.peeled) |*peeled| line(git, peeled, ref.name, "^{}");
    }
    return !git.stopped();
}

fn line(git: *Git, id: *const _git.Id, name: []const u8, suffix: []const u8) void {
    var text: [41]u8 = undefined;
    _git.hexOf(id, text[0..40]);
    text[40] = '\t';
    git.put(&text);
    git.put(name);
    git.put(suffix);
    git.put("\n");
}
