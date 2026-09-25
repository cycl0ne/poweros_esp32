// SPDX-License-Identifier: MIT
//! Classes: open a class library from the disk and make an object of its
//! class. Built against the SDK only.
//!
//!   Classes LIBRARY,ID/N
//!
//! With nothing named it opens `gadgets/hello.gadget`, which is in
//! `SYS:classes/gadgets/` and reached through `LIBS:`. The class is the
//! one named by the library's name after its last `/` or `:` - a class
//! library makes the class of its own name. What it prints: the library
//! and its open count, the class found on the public list, an object of
//! it made with `GA_ID` and the ID read back, and a second open of the same
//! name answering the same base without loading the file again. ID is the
//! object's `GA_ID` (7 unless given).

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const gc = intuition.gadgetclass;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;
const rdargs = dos.rdargs;

pub const COMMAND_NAME = "Classes";
const VERSION_STRING = "\x00$VER: Classes 1.0 (25.09.2026)\r\n";

const template = "LIBRARY,ID/N";
const arg_library = 0;
const arg_id = 1;

const DEFAULT_LIBRARY = "gadgets/hello.gadget";
const DEFAULT_ID = 7;

const MSG_NOLIBRARY = "%s: cannot open %s\n";
const MSG_OPENED = "%s %d.%d at 0x%08x, open count %d\n";
const MSG_NOCLASS = "No public class %s\n";
const MSG_CLASS = "Class %s: %d objects, %d subclasses\n";
const MSG_NOOBJECT = "%s made no object\n";
const MSG_OBJECT = "Object 0x%08x, GA_ID %d, class now has %d\n";
const MSG_AGAIN = "Opened again: %s, open count %d\n";
const MSG_SAME = "the same base";
const MSG_OTHER = "ANOTHER base";
const MSG_DONE = "Disposed, closed: class has %d objects\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    const intuition_lib = sys.OpenLibrary("intuition.library", 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, "intuition.library" });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(intuition_lib);
    const ib: *IntuitionBase = @ptrCast(intuition_lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const name = rdargs.string(argv[arg_library]) orelse DEFAULT_LIBRARY;
    const id: u32 = if (rdargs.number(argv[arg_id])) |n| @bitCast(n) else DEFAULT_ID;

    const lib = sys.OpenLibrary(name, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, name });
        return dos.RETURN_ERROR;
    };
    defer sys.CloseLibrary(lib);
    _ = Printf(dl, MSG_OPENED, .{ lib.name().ptr, lib.version, lib.revision, @intFromPtr(lib), lib.open_cnt });

    const class_name = tail(name);
    const cl = ib.FindClass(class_name) orelse {
        _ = Printf(dl, MSG_NOCLASS, .{class_name});
        return dos.RETURN_ERROR;
    };
    _ = Printf(dl, MSG_CLASS, .{ class_name, cl.object_count, cl.subclass_count });

    const object = ib.NewObjectTagList(null, class_name, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = id },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOOBJECT, .{class_name});
        return dos.RETURN_ERROR;
    };
    var read_back: usize = 0;
    _ = ib.GetAttr(gc.GA_ID, object, &read_back);
    _ = Printf(dl, MSG_OBJECT, .{ @intFromPtr(object), @as(u32, @truncate(read_back)), cl.object_count });

    if (sys.OpenLibrary(name, 0)) |again| {
        _ = Printf(dl, MSG_AGAIN, .{ if (again == lib) MSG_SAME else MSG_OTHER, again.open_cnt });
        sys.CloseLibrary(again);
    }

    ib.DisposeObject(object);
    _ = Printf(dl, MSG_DONE, .{cl.object_count});
    return dos.RETURN_OK;
}

/// The part of a name after its last `/` or `:`.
fn tail(name: [*:0]const u8) [*:0]const u8 {
    var after = name;
    var i: usize = 0;
    while (name[i] != 0) : (i += 1) {
        if (name[i] == '/' or name[i] == ':') after = name + i + 1;
    }
    return after;
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
