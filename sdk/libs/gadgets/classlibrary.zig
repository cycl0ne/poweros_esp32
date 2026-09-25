// SPDX-License-Identifier: MIT
//! A class library: a library on the disk whose whole business is one
//! BOOPSI class of its own name. `ClassLibrary` makes everything but the
//! class's dispatcher:
//!
//! - The base: exec's library, the segments it was loaded from,
//!   intuition.library, graphics.library, utility.library and the class.
//! - The init opens the three, and the libraries the class says it needs
//!   (`opens`: another class library whose class it makes objects of),
//!   makes the class from its superclass by name
//!   (`MakeClass`), sets the dispatcher, keeps the base in the class's
//!   `user_data` - where `baseOf` finds it - and puts the class on the
//!   public list.
//! - The expunge refuses while the library is open or the class has
//!   objects or subclasses. Otherwise it frees the class, closes what it
//!   opened,
//!   takes the library off exec's list, frees its memory and hands back
//!   the segments.
//! - The jump table: the standard four, then the library's own calls when
//!   it has any (`functions`).
//! - The ROM tag, in `.resident`, the `$VER:` string, in `.version`, and a
//!   program entry that says the file is not a command.
//!
//! A class file is then its instance data, its dispatcher and one line:
//!
//!   const Library = sdk.gadgets.ClassLibrary(.{
//!       .name = "checkbox.gadget",
//!       .version = 1,
//!       .date = "25.09.2026",
//!       .super = sdk.intuition.classusr.BUTTONGCLASS,
//!       .Instance = Data,
//!       .dispatch = dispatch,
//!   });
//!   comptime {
//!       _ = Library;
//!   }

const std = @import("std");
const exec = @import("../exec/exec.zig");
const utility = @import("../utility/utility.zig");
const classes = @import("../intuition/classes.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const IntuitionBase = @import("../../interface/intuition.zig").IntuitionBase;
const GraphicsBase = @import("../../interface/graphics.zig").GraphicsBase;
const UtilityBase = @import("../../interface/utility.zig").UtilityBase;
const Class = classes.Class;

/// What a class library is.
pub const Spec = struct {
    /// The library's name, which is also the class's: `checkbox.gadget`.
    name: [:0]const u8,
    version: u16,
    revision: u16 = 0,
    /// `dd.mm.yyyy`.
    date: []const u8,
    /// The superclass, by name.
    super: [*:0]const u8,
    /// The class's part of an object.
    Instance: type,
    dispatch: utility.hooks.HookFn,
    /// Libraries the class needs open for as long as it is there, by
    /// name: at most `max_opens`.
    opens: []const [*:0]const u8 = &.{},
    /// The library's own calls, after the standard four, in the order of
    /// its `.fd`: each an `lvo<Name>` taking the `Base` first.
    functions: []const *const anyopaque = &.{},
};

/// How many libraries a class library may open for its class.
pub const max_opens = 4;

/// A class library's base: what its dispatcher reaches through `baseOf`.
pub const Base = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    intuition_base: *IntuitionBase,
    graphics_base: *GraphicsBase,
    utility_base: *UtilityBase,
    /// What LoadSeg made, handed to the init and back at the expunge.
    seg_list: ?*anyopaque = null,
    class: *Class,
    /// The libraries of `Spec.opens`, in that order.
    opened: [max_opens]?*exec.Library = @splat(null),
};

/// The base of the library a class is in, from the class a dispatcher is
/// handed.
pub fn baseOf(cl: *const Class) *Base {
    return @ptrFromInt(cl.user_data);
}

pub fn ClassLibrary(comptime spec: Spec) type {
    if (spec.opens.len > max_opens) @compileError("a class library opens at most max_opens libraries");
    return struct {
        pub const version_string = "\x00$VER: " ++ spec.name ++ " " ++
            std.fmt.comptimePrint("{d}.{d}", .{ spec.version, spec.revision }) ++
            " (" ++ spec.date ++ ")\r\n";

        fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Library {
            const base: *Base = @fieldParentPtr("lib", lib);
            lib.revision = spec.revision;
            base.sys_base = sys;
            base.seg_list = seg_list;
            const intuition_lib = sys.OpenLibrary("intuition.library", 0) orelse return null;
            const graphics_lib = sys.OpenLibrary("graphics.library", 0) orelse {
                sys.CloseLibrary(intuition_lib);
                return null;
            };
            const utility_lib = sys.OpenLibrary(utility.UTILITYNAME, 0) orelse {
                sys.CloseLibrary(graphics_lib);
                sys.CloseLibrary(intuition_lib);
                return null;
            };
            base.intuition_base = @ptrCast(intuition_lib);
            base.graphics_base = @ptrCast(graphics_lib);
            base.utility_base = @ptrCast(utility_lib);
            base.opened = @splat(null);
            for (spec.opens, 0..) |name, i| {
                base.opened[i] = sys.OpenLibrary(name, 0) orelse {
                    closeAll(base);
                    return null;
                };
            }
            const ib = base.intuition_base;
            base.class = ib.MakeClass(spec.name, spec.super, null, @sizeOf(spec.Instance)) orelse {
                closeAll(base);
                return null;
            };
            base.class.dispatcher.entry = spec.dispatch;
            base.class.user_data = @intFromPtr(base);
            ib.AddClass(base.class);
            return lib;
        }

        fn closeAll(base: *Base) void {
            const sys = base.sys_base;
            for (base.opened) |lib| sys.CloseLibrary(lib);
            sys.CloseLibrary(base.utility_base.lib());
            sys.CloseLibrary(base.graphics_base.lib());
            sys.CloseLibrary(base.intuition_base.lib());
        }

        fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
            const base: *Base = @fieldParentPtr("lib", lib);
            const cl = base.class;
            if (lib.open_cnt != 0 or cl.object_count != 0 or cl.subclass_count != 0) {
                lib.flags |= exec.libraries.LIBF_DELEXP;
                return null;
            }
            const ib = base.intuition_base;
            if (!ib.FreeClass(cl)) {
                // An object made between the look and the free: it stays.
                ib.AddClass(cl);
                lib.flags |= exec.libraries.LIBF_DELEXP;
                return null;
            }
            closeAll(base);
            const sys = base.sys_base;
            const seg_list = base.seg_list;
            sys.Remove(&lib.node);
            const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
            sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
            return seg_list;
        }

        const vectors = [_]*const anyopaque{
            exec.libraries.vec(exec.libraries.libOpen),
            exec.libraries.vec(exec.libraries.libClose),
            exec.libraries.vec(expunge),
            exec.libraries.vec(exec.libraries.libExtFunc),
        } ++ spec.functions[0..spec.functions.len].*;

        const init_table = exec.InitTable{
            .data_size = @sizeOf(Base),
            .vectors = &vectors,
            .vector_count = vectors.len,
            .init = &init,
        };

        /// Made when it is first opened, so no boot phase. A host test
        /// makes it with `InitResident`.
        pub const resident_tag: exec.Resident = .{
            .match_tag = &resident_tag,
            .flags = exec.RTF_AUTOINIT,
            .version = spec.version,
            .type = .library,
            .pri = 0,
            .name = spec.name,
            .id_string = version_string[1..], // past the NUL: a C string
            .init = &init_table,
        };

        const version_tag: [version_string.len:0]u8 = version_string.*;

        /// A class library is not a command.
        fn programEntry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
            _ = args;
            _ = len;
            exec.kprintf(sys, "%s is a class library, not a command\n", .{spec.name.ptr});
            return 20; // RETURN_FAIL, without opening dos.library to say it
        }

        // Nothing in the file refers to these three: the tag is found by
        // looking for it, the version string by `Version`, the entry by
        // the loader. program.ld keeps `.resident` and `.version`. A host
        // test holds several class libraries in one program, where the
        // names would clash, and needs none of them.
        comptime {
            if (!@import("builtin").is_test) {
                @export(&resident_tag, .{ .name = "class_library_tag", .section = ".resident" });
                @export(&version_tag, .{ .name = "version_tag", .section = ".version" });
                @export(&programEntry, .{ .name = "_program_entry" });
            }
        }
    };
}
