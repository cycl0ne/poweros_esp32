// SPDX-License-Identifier: MIT
//! One Player: the Player that runs keeps the public port `Player`, and a
//! second start hands what it was given over to it and ends. Its files go
//! by their full names - a name typed in a shell is the shell's drawer's,
//! which the Player running does not share; a station's address as it is
//! - with ADD, and VOLUME and
//! LOOK when they were given. A start that finds no Player is the Player,
//! and makes its list of the same full names, which is how Player.list
//! keeps them.
//!
//! The port takes a program's question too - what is playing, and how
//! far (`sdk.player.State`, the dock's player.docklet asks it) - told
//! from a `Handed` by its length.
//!
//! The second start sends a `Handed` with `SafePutToPort` - the find and
//! the send under one hold of exec's port lock, so a Player ending at
//! that moment answers it as it takes its port down - and waits for the
//! answer: the names are its memory until then. `names` makes the full
//! names, `handOver` sends them.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const visual = @import("visual.zig");
const playlist = @import("playlist.zig");

/// The public port of the Player running, which a program asks what it
/// plays at too (`sdk.player`).
pub const PORT_NAME = sdk.player.PORT_NAME;

/// What a second start hands the Player running. The sender's until it
/// is replied.
pub const Handed = extern struct {
    message: exec.Message = .{},
    /// The files' full names, `count` of them; none brings the window to
    /// the front.
    names: ?[*]const [*:0]const u8 = null,
    count: u32 = 0,
    /// Nonzero for ADD: the files added, and the first not played.
    add: u32 = 0,
    /// VOLUME, or -1 when it was not given.
    volume: i32 = -1,
    /// LOOK as a `visual.Mode` plus one, or 0 when it was not given.
    look: u32 = 0,

    /// The picture asked for, if one was.
    pub fn lookAsked(handed: *const Handed) ?visual.Mode {
        if (handed.look == 0 or handed.look > visual.mode_count) return null;
        return @enumFromInt(handed.look - 1);
    }

    /// The names handed, as a slice.
    pub fn nameList(handed: *const Handed) []const [*:0]const u8 {
        const list = handed.names orelse return &.{};
        return list[0..handed.count];
    }
};

/// A name as long as a full name can be.
pub const Name = [dos.path_max + 1:0]u8;

/// The full names of the files given, in one block: the pointers, then
/// the names they point at.
pub const Names = struct {
    memory: ?*anyopaque = null,
    list: ?[*]const [*:0]const u8 = null,
    count: u32 = 0,

    pub fn free(made: *Names, sys: *ExecBase) void {
        if (made.memory) |block| sys.FreeVec(block);
        made.* = .{};
    }

    pub fn slice(made: *const Names) []const [*:0]const u8 {
        const list = made.list orelse return &.{};
        return list[0..made.count];
    }
};

/// `files` - a NULL-ended list, as ReadArgs gives FILES/M - by their full
/// names: a name that locks by the name of what it locks, one that does
/// not by the current drawer's name with it added; a station's address as
/// it is. Null when there is no memory for them; none given are none made.
pub fn names(sys: *ExecBase, dl: *DosBase, files: ?[*]const ?[*:0]const u8) ?Names {
    var count: usize = 0;
    if (files) |list| {
        while (list[count] != null) count += 1;
    }
    if (count == 0) return .{};
    const pointers_size = count * @sizeOf([*:0]const u8);
    const memory = sys.AllocVec(pointers_size + count * @sizeOf(Name), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const block: [*]u8 = @ptrCast(memory);
    const pointers: [*][*:0]const u8 = @ptrCast(@alignCast(block));
    const spelled: [*]Name = @ptrCast(block + pointers_size);
    for (0..count) |at| {
        fullName(dl, files.?[at].?, &spelled[at]);
        pointers[at] = &spelled[at];
    }
    return .{ .memory = memory, .list = pointers, .count = @intCast(count) };
}

/// `name` by its full name, into `into`.
fn fullName(dl: *DosBase, name: [*:0]const u8, into: *Name) void {
    if (playlist.isUrl(name)) return copyName(name, into);
    if (dl.Lock(name, dos.ACCESS_READ)) |lock| {
        defer dl.UnLock(lock);
        if (dl.NameFromLock(lock, into, into.len)) return;
    }
    // Not there, or no name for it: as it would be looked for from here.
    if (!dl.GetCurrentDirName(into, into.len)) into[0] = 0;
    if (dl.AddPart(into, name, into.len)) return;
    copyName(name, into);
}

fn copyName(name: [*:0]const u8, into: *Name) void {
    var length: usize = 0;
    while (name[length] != 0 and length < dos.path_max) : (length += 1) into[length] = name[length];
    into[length] = 0;
}

/// What a start found.
pub const Outcome = enum {
    /// No Player runs: this start is the Player.
    alone,
    /// The Player running has taken what was given.
    handed,
    /// No memory to hand it over with.
    no_memory,
};

/// The files - `names` made of them - and the words given handed to the
/// Player running, which has dealt with them when this returns
/// `.handed`.
pub fn handOver(sys: *ExecBase, given: *const Names, add: bool, volume: ?i32, look: ?visual.Mode) Outcome {
    const reply = sys.CreateMsgPort() orelse return .no_memory;
    defer sys.DeleteMsgPort(reply);
    var handed = Handed{
        .message = .{ .reply_port = reply, .length = @sizeOf(Handed) },
        .names = given.list,
        .count = given.count,
        .add = @intFromBool(add),
        .volume = volume orelse -1,
        .look = if (look) |mode| @as(u32, @intFromEnum(mode)) + 1 else 0,
    };
    if (!sys.SafePutToPort(&handed.message, PORT_NAME)) return .alone;
    _ = sys.WaitPort(reply);
    _ = sys.GetMsg(reply);
    return .handed;
}
