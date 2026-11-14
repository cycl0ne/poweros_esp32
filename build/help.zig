// SPDX-License-Identifier: MPL-2.0
//! The `help` step: every step and every option this build has, with what
//! each is for, and nothing of what `zig build` has for every project.
//!
//! It is made last, from the build's own lists: a step or an option added
//! anywhere is in it without being written down a second time.

const std = @import("std");

/// The width the text is broken at.
const width = 100;
/// How far a description is from the left edge.
const indent = 6;

/// The step, and the text it prints.
const Help = struct {
    step: std.Build.Step,
    text: []const u8,

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const help: *Help = @fieldParentPtr("step", step);
        std.debug.print("{s}", .{help.text});
    }
};

/// `words` broken into lines of `width`, each `indent` in.
fn wrapped(b: *std.Build, text: *std.ArrayList(u8), words: []const u8) void {
    var column: usize = 0;
    var each = std.mem.tokenizeAny(u8, words, " \n");
    while (each.next()) |word| {
        if (column != 0 and column + 1 + word.len > width) {
            text.append(b.allocator, '\n') catch @panic("OOM");
            column = 0;
        }
        if (column == 0) {
            text.appendNTimes(b.allocator, ' ', indent) catch @panic("OOM");
            column = indent;
        } else {
            text.append(b.allocator, ' ') catch @panic("OOM");
            column += 1;
        }
        text.appendSlice(b.allocator, word) catch @panic("OOM");
        column += word.len;
    }
    if (column != 0) text.append(b.allocator, '\n') catch @panic("OOM");
}

/// What an option takes, as it is written after `-D<name>=`.
fn valueOf(b: *std.Build, option: anytype) []const u8 {
    if (option.enum_options) |names| return std.mem.join(b.allocator, "|", names) catch @panic("OOM");
    return switch (option.type_id) {
        .bool => "true|false",
        .int => "<number>",
        .float => "<number>",
        .string, .lazy_path => "<text>",
        .list, .lazy_path_list => "<text>, given once for each",
        else => "<value>",
    };
}

/// The `help` step. Called once every other step and option is there.
pub fn addHelpStep(b: *std.Build) void {
    const help = b.allocator.create(Help) catch @panic("OOM");
    const top = b.step("help", "Show this build's steps and options");

    var text: std.ArrayList(u8) = .empty;
    text.appendSlice(b.allocator,
        \\./zig build [step ...] [-D<option>=<value> ...]
        \\
        \\Steps (none named: the kernel and the disk of -Dboard=, into zig-out/bin):
        \\
    ) catch @panic("OOM");
    for (b.top_level_steps.values()) |one| {
        const name = one.step.name;
        if (std.mem.eql(u8, name, "install") or std.mem.eql(u8, name, "uninstall")) continue;
        text.appendSlice(b.allocator, b.fmt("\n  {s}\n", .{name})) catch @panic("OOM");
        wrapped(b, &text, one.description);
    }
    text.appendSlice(b.allocator, "\nOptions:\n") catch @panic("OOM");
    for (b.available_options_list.items) |option| {
        const value = valueOf(b, option);
        // A long row of names goes under the option, a short one beside it.
        const beside = value.len + option.name.len <= 60;
        text.appendSlice(b.allocator, b.fmt("\n  -D{s}={s}\n", .{ option.name, if (beside) value else "<name>" })) catch @panic("OOM");
        wrapped(b, &text, option.description);
        if (!beside) wrapped(b, &text, b.fmt("One of: {s}.", .{std.mem.join(b.allocator, ", ", option.enum_options.?) catch @panic("OOM")}));
    }

    help.* = .{
        .step = .init(.{ .id = .custom, .name = "help", .owner = b, .makeFn = Help.make }),
        .text = text.items,
    };
    top.dependOn(&help.step);
}
