// SPDX-License-Identifier: MIT
//! Host tests of asl.library's parts that need no window: what the tags
//! say, how the lines of a list are kept in order, and which entries a
//! requester shows.
//!
//! The requester itself wants a screen, a window and the gadget classes
//! from the disk, so it is exercised in QEMU rather than here.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const asl = sdk.asl;
const utility = sdk.utility;
const host = @import("host_rom");
const kexec = host.exec;
const AslBase = @import("../asl_base.zig").AslBase;
const _request = @import("../request/_request.zig");
const Requester = _request.Requester;
const entries = @import("../file/entries.zig");
const Entry = entries.Entry;

const testing = std.testing;
const TagItem = utility.TagItem;

test {
    _ = @import("../asl_lvo.zig");
}

/// exec and utility.library up, and a base with just enough in it for
/// the parts under test: the tags are read through utility, and the
/// lines are made through exec.
const Rig = struct {
    base: AslBase,
    ub: *host.utility.UtilityBase = undefined,

    fn up(rig: *Rig) !void {
        const ub = try host.utility.setUp();
        rig.ub = ub;
        rig.base = .{
            .lib = .{},
            .sys_base = kexec.SysBase.iface(),
            .dos_base = undefined,
            .intuition_base = undefined,
            .graphics_base = undefined,
            .utility_base = @ptrCast(ub),
        };
        rig.base.requesters.init();
    }

    /// utility.library taken down, and nothing the test made left
    /// behind: an entry not freed is a leak the rig catches.
    fn down(rig: *Rig) !void {
        try host.utility.tearDown(rig.ub);
        try kexec.expectNoLeaks();
    }

    fn requester(rig: *Rig, kind: u32) Requester {
        return .{ .public = .{ .file = .{} }, .base = &rig.base, .kind = kind };
    }
};

test "a file requester's tags: where it opens, what it says, what it shows" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down() catch {};
    var r = rig.requester(asl.ASL_FileRequest);

    var window: u8 = 0;
    const tags = [_]TagItem{
        .{ .tag = asl.ASLFR_Window, .data = @intFromPtr(&window) },
        .{ .tag = asl.ASLFR_SleepWindow, .data = 1 },
        .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr("Open") },
        .{ .tag = asl.ASLFR_PositiveText, .data = @intFromPtr("Take") },
        .{ .tag = asl.ASLFR_InitialLeftEdge, .data = 30 },
        .{ .tag = asl.ASLFR_InitialTopEdge, .data = 40 },
        .{ .tag = asl.ASLFR_InitialDrawer, .data = @intFromPtr("SYS:c") },
        .{ .tag = asl.ASLFR_InitialFile, .data = @intFromPtr("List") },
        .{ .tag = asl.ASLFR_InitialPattern, .data = @intFromPtr("#?.info") },
        .{ .tag = asl.ASLFR_DoMultiSelect, .data = 1 },
        .{ .tag = asl.ASLFR_DoPatterns, .data = 1 },
        .{ .tag = asl.ASLFR_RejectIcons, .data = 1 },
        .{ .tag = asl.ASLFR_UserData, .data = 0x1234 },
        .{},
    };
    _request.takeTags(&r, &tags);

    try testing.expectEqual(@intFromPtr(&window), @intFromPtr(r.where.window));
    try testing.expectEqual(@as(u8, 1), r.where.sleep);
    try testing.expectEqualStrings("Open", std.mem.span(r.words.title.?));
    try testing.expectEqualStrings("Take", std.mem.span(r.words.positive.?));
    try testing.expect(r.words.negative == null);
    try testing.expectEqual(@as(i32, 30), r.box.left);
    try testing.expectEqual(@as(i32, 40), r.box.top);
    try testing.expect(r.flags1 & asl.FRF_DOMULTISELECT != 0);
    try testing.expect(r.flags1 & asl.FRF_DOPATTERNS != 0);
    try testing.expect(r.flags2 & asl.FRF2_REJECTICONS != 0);
    try testing.expectEqual(@as(usize, 0x1234), r.public.file.user_data);

    // The three fields are the requester's own buffers, and the public
    // structure points at them.
    try testing.expectEqualStrings("SYS:c", std.mem.span(@as([*:0]const u8, @ptrCast(&r.drawer))));
    try testing.expectEqualStrings("List", std.mem.span(@as([*:0]const u8, @ptrCast(&r.file))));
    try testing.expectEqualStrings("#?.info", std.mem.span(@as([*:0]const u8, @ptrCast(&r.pattern))));
    try testing.expectEqual(@intFromPtr(&r.drawer), @intFromPtr(r.public.file.drawer));
    try testing.expectEqual(@intFromPtr(&r.file), @intFromPtr(r.public.file.file));
    try testing.expectEqual(@intFromPtr(&r.pattern), @intFromPtr(r.public.file.pattern));

    // A flags word sets them all at once, and a bool tag after it still
    // has the last word.
    const again = [_]TagItem{
        .{ .tag = asl.ASLFR_Flags1, .data = asl.FRF_DOSAVEMODE },
        .{ .tag = asl.ASLFR_DoPatterns, .data = 1 },
        .{},
    };
    _request.takeTags(&r, &again);
    try testing.expect(r.flags1 & asl.FRF_DOSAVEMODE != 0);
    try testing.expect(r.flags1 & asl.FRF_DOMULTISELECT == 0);
    try testing.expect(r.flags1 & asl.FRF_DOPATTERNS != 0);
}

test "the kinds share the tags that mean the same thing, and no others" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down() catch {};

    // ASL_TB+10 is a file requester's pattern and a font requester's
    // name: which structure is being made decides what it means.
    var file = rig.requester(asl.ASL_FileRequest);
    var font = rig.requester(asl.ASL_FontRequest);
    const tags = [_]TagItem{
        .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr("Both") },
        .{ .tag = asl.ASLFR_UserData, .data = 7 },
        .{ .tag = asl.ASLFR_InitialPattern, .data = @intFromPtr("#?.txt") },
        .{},
    };
    _request.takeTags(&file, &tags);
    _request.takeTags(&font, &tags);

    // The words and where it opens are the same for both.
    try testing.expectEqualStrings("Both", std.mem.span(file.words.title.?));
    try testing.expectEqualStrings("Both", std.mem.span(font.words.title.?));
    // The user data goes into whichever structure it is.
    try testing.expectEqual(@as(usize, 7), file.public.file.user_data);
    try testing.expectEqual(@as(usize, 7), font.public.font.user_data);
    // The pattern is the file requester's alone.
    try testing.expectEqualStrings("#?.txt", std.mem.span(@as([*:0]const u8, @ptrCast(&file.pattern))));
    try testing.expectEqual(@as(u8, 0), font.pattern[0]);
}

fn namesOf(list: *exec.List, into: [][]const u8) usize {
    var n: usize = 0;
    var node = list.first();
    while (node) |it| : (node = it.next()) {
        const entry: *Entry = @fieldParentPtr("node", it);
        into[n] = std.mem.span(entry.name());
        n += 1;
        if (n == into.len) break;
    }
    return n;
}

test "the lines of a list: drawers first, then by name without regard to case" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down() catch {};
    const sys = rig.base.sys_base;
    const ub = rig.base.utility_base;
    var list: exec.List = .{};
    list.init(.unknown);

    try testing.expect(entries.add(sys, ub, &list, "zebra.txt", dos.ST_FILE, 12));
    try testing.expect(entries.add(sys, ub, &list, "Apple", dos.ST_USERDIR, 0));
    try testing.expect(entries.add(sys, ub, &list, "alpha.txt", dos.ST_FILE, 4096));
    try testing.expect(entries.add(sys, ub, &list, "beta", dos.ST_USERDIR, 0));
    try testing.expect(entries.add(sys, ub, &list, "Beta.txt", dos.ST_FILE, 0));

    var names: [8][]const u8 = undefined;
    const count = namesOf(&list, &names);
    try testing.expectEqual(@as(usize, 5), count);
    try testing.expectEqualStrings("Apple", names[0]);
    try testing.expectEqualStrings("beta", names[1]);
    try testing.expectEqualStrings("alpha.txt", names[2]);
    try testing.expectEqualStrings("Beta.txt", names[3]);
    try testing.expectEqualStrings("zebra.txt", names[4]);

    // The right-hand column: a size for a file, the word for a drawer.
    const first: *Entry = @fieldParentPtr("node", list.first().?);
    try testing.expectEqualStrings("Drawer", std.mem.span(first.right()));
    try testing.expect(first.isDir());
    var node = list.first();
    while (node) |it| : (node = it.next()) {
        const entry: *Entry = @fieldParentPtr("node", it);
        if (std.mem.eql(u8, std.mem.span(entry.name()), "alpha.txt")) {
            try testing.expectEqualStrings("4096", std.mem.span(entry.right()));
            try testing.expect(!entry.isDir());
        }
    }

    entries.empty(sys, &list);
    try testing.expect(list.isEmpty());
}
