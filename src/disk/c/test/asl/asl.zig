// SPDX-License-Identifier: MIT
//! Asl: the file requester, asked for a name and told what it answered.
//! Built against the SDK only.
//!
//!   Asl DIR MULTI/S SAVE/S DRAWERS/S PATTERN/K
//!
//! It opens asl.library, makes a file requester starting in `DIR` -
//! `SYS:` unless another is named - and puts it up. What it was answered
//! with is printed: the drawer and the name, or with `MULTI` every name
//! picked. `SAVE` asks for a name to save under, `DRAWERS` for a drawer
//! rather than a file, and `PATTERN` gives the requester a Pattern field
//! starting on that pattern.
//!
//! The requester is answered with its buttons, with a second press on a
//! line, or from the keyboard: the letter underlined in each label works
//! its gadget.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const asl = sdk.asl;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const AslBase = sdk.interface.asl.AslBase;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Asl";
const VERSION_STRING = "\x00$VER: Asl 1.0 (28.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DIR,MULTI/S,SAVE/S,DRAWERS/S,PATTERN/K";
const arg_dir = 0;
const arg_multi = 1;
const arg_save = 2;
const arg_drawers = 3;
const arg_pattern = 4;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOREQUEST = "No requester\n";
const MSG_GAVEUP = "Nothing picked\n";
const MSG_ANSWER = "Drawer \"%s\", file \"%s\"\n";
const MSG_ONE = "  %s\n";
const MSG_COUNT = "%lu names picked:\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [5]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const dir = dos.rdargs.string(argv[arg_dir]) orelse "SYS:";
    const pattern = dos.rdargs.string(argv[arg_pattern]);

    const asl_lib = sys.OpenLibrary(asl.ASLNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{asl.ASLNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(asl_lib);
    const ab: *AslBase = @ptrCast(asl_lib);

    const ignore = sdk.utility.TAG_IGNORE;
    const handle = ab.AllocAslRequest(asl.ASL_FileRequest, &[_]TagItem{
        .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr(@as([*:0]const u8, if (argv[arg_save] != 0) "Save as" else "Pick a file")) },
        .{ .tag = asl.ASLFR_InitialDrawer, .data = @intFromPtr(dir) },
        .{ .tag = asl.ASLFR_DoMultiSelect, .data = @intFromBool(argv[arg_multi] != 0) },
        .{ .tag = asl.ASLFR_DoSaveMode, .data = @intFromBool(argv[arg_save] != 0) },
        .{ .tag = asl.ASLFR_DrawersOnly, .data = @intFromBool(argv[arg_drawers] != 0) },
        .{ .tag = if (pattern != null) asl.ASLFR_DoPatterns else ignore, .data = 1 },
        .{ .tag = if (pattern != null) asl.ASLFR_InitialPattern else ignore, .data = @intFromPtr(pattern) },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOREQUEST, .{});
        return dos.RETURN_FAIL;
    };
    defer ab.FreeAslRequest(handle);
    const req: *asl.FileRequester = @ptrCast(@alignCast(handle));

    if (!ab.AslRequest(handle, null)) {
        _ = Printf(dl, MSG_GAVEUP, .{});
        return dos.RETURN_WARN;
    }
    _ = Printf(dl, MSG_ANSWER, .{ req.drawer orelse "", req.file orelse "" });
    if (req.num_args > 0) if (req.arg_list) |list| {
        _ = Printf(dl, MSG_COUNT, .{@as(u64, @intCast(req.num_args))});
        for (list[0..@intCast(req.num_args)]) |arg| {
            _ = Printf(dl, MSG_ONE, .{arg.name orelse ""});
        }
    };
    return dos.RETURN_OK;
}
