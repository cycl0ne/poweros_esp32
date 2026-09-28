// SPDX-License-Identifier: MIT
//! DataTypes: what kind of file something is. Built against the SDK
//! only.
//!
//!   DataTypes FILE/M
//!
//! Each name is locked and handed to datatypes.library's
//! `ObtainDataTypeA`, which tries the descriptors `C:AddDataTypes` read
//! and answers the first that matches. What it prints is the kind's
//! name, its group, its four characters and the class that would be
//! loaded to open it.
//!
//! It is what a file requester does to decide whether to show a file,
//! and it costs one reading of the file's first bytes however many
//! kinds there are.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "DataTypes";
const VERSION_STRING = "\x00$VER: DataTypes 1.0 (29.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE/M/A";
const arg_file = 0;

const MSG_NOLIBRARY = "No %s - has C:AddDataTypes run?\n";
const MSG_NOLOCK = "%s: cannot be found\n";
const MSG_UNKNOWN = "%s: %s\n";
const MSG_KIND = "%-28s %s (%s.%s), class %s.datatype\n";

fn idText(id: u32, into: *[5]u8) [*:0]const u8 {
    into[0] = @truncate(id >> 24);
    into[1] = @truncate(id >> 16);
    into[2] = @truncate(id >> 8);
    into[3] = @truncate(id);
    into[4] = 0;
    return @ptrCast(into);
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const lib = sys.OpenLibrary(datatypes.DATATYPESNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{datatypes.DATATYPESNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(lib);
    const dt: *DataTypesBase = @ptrCast(lib);

    var group_text: [5]u8 = undefined;
    var id_text: [5]u8 = undefined;
    const names: [*]const usize = @ptrFromInt(argv[arg_file]);
    var i: usize = 0;
    while (names[i] != 0) : (i += 1) {
        const name: [*:0]const u8 = @ptrFromInt(names[i]);
        const lock = dl.Lock(name, dos.SHARED_LOCK) orelse {
            _ = Printf(dl, MSG_NOLOCK, .{name});
            continue;
        };
        defer dl.UnLock(lock);
        const kind = dt.ObtainDataTypeA(dtc.DTST_FILE, lock, null) orelse {
            _ = Printf(dl, MSG_UNKNOWN, .{ name, dt.GetDTString(@intCast(dl.IoErr())) });
            continue;
        };
        defer dt.ReleaseDataType(kind);
        _ = Printf(dl, MSG_KIND, .{
            name,
            dt.GetDTString(kind.header.group_id),
            idText(kind.header.group_id, &group_text),
            idText(kind.header.id, &id_text),
            kind.header.base_name,
        });
    }
    return dos.RETURN_OK;
}
