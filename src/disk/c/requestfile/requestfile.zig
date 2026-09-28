// SPDX-License-Identifier: MIT
//! RequestFile: the shell asks which file, and is told the name.
//! Built against the SDK only.
//!
//!   RequestFile DRAWER,FILE/K,PATTERN/K,TITLE/K,POSITIVE/K,NEGATIVE/K,
//!               ACCEPTPATTERN/K,REJECTPATTERN/K,SAVEMODE/S,MULTISELECT/S,
//!               DRAWERSONLY/S,NOICONS/S,PUBSCREEN/K
//!
//! It puts up asl.library's file requester and writes the whole name -
//! the drawer and the file joined - to its output in quotes, so that a
//! script can take it as one argument however many spaces are in it.
//! With `MULTISELECT` every name picked is written, in quotes, on the one
//! line with a space between them.
//!
//! A requester given up writes nothing and ends with a warning, which is
//! what lets a script tell "nothing picked" from a name.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const asl = sdk.asl;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const AslBase = sdk.interface.asl.AslBase;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "RequestFile";
const VERSION_STRING = "\x00$VER: RequestFile 1.0 (28.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DRAWER,FILE/K,PATTERN/K,TITLE/K,POSITIVE/K,NEGATIVE/K," ++
    "ACCEPTPATTERN/K,REJECTPATTERN/K,SAVEMODE/S,MULTISELECT/S," ++
    "DRAWERSONLY/S,NOICONS/S,PUBSCREEN/K";
const arg_drawer = 0;
const arg_file = 1;
const arg_pattern = 2;
const arg_title = 3;
const arg_positive = 4;
const arg_negative = 5;
const arg_accept = 6;
const arg_reject = 7;
const arg_savemode = 8;
const arg_multiselect = 9;
const arg_drawersonly = 10;
const arg_noicons = 11;
const arg_pubscreen = 12;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOREQUEST = "No requester\n";

/// The drawer and a name joined, written in quotes.
fn writeName(dl: *DosBase, drawer: [*:0]const u8, name: [*:0]const u8, first: bool) void {
    var path: [dos.path_max + 1]u8 = @splat(0);
    var i: usize = 0;
    while (drawer[i] != 0 and i + 1 < path.len) : (i += 1) path[i] = drawer[i];
    path[i] = 0;
    _ = dl.AddPart(@ptrCast(&path), name, path.len);
    _ = dl.PutStr(if (first) "\"" else " \"");
    _ = dl.PutStr(@ptrCast(&path));
    _ = dl.PutStr("\"");
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [13]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const asl_lib = sys.OpenLibrary(asl.ASLNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{asl.ASLNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(asl_lib);
    const ab: *AslBase = @ptrCast(asl_lib);

    const ignore = sdk.utility.TAG_IGNORE;
    const pattern = dos.rdargs.string(argv[arg_pattern]);
    const screen = dos.rdargs.string(argv[arg_pubscreen]);
    const handle = ab.AllocAslRequest(asl.ASL_FileRequest, &[_]TagItem{
        .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr(dos.rdargs.string(argv[arg_title]) orelse "Select a file") },
        .{ .tag = if (argv[arg_positive] != 0) asl.ASLFR_PositiveText else ignore, .data = argv[arg_positive] },
        .{ .tag = if (argv[arg_negative] != 0) asl.ASLFR_NegativeText else ignore, .data = argv[arg_negative] },
        .{ .tag = if (screen != null) asl.ASLFR_PubScreenName else ignore, .data = argv[arg_pubscreen] },
        .{ .tag = asl.ASLFR_InitialDrawer, .data = @intFromPtr(dos.rdargs.string(argv[arg_drawer]) orelse "") },
        .{ .tag = if (argv[arg_file] != 0) asl.ASLFR_InitialFile else ignore, .data = argv[arg_file] },
        .{ .tag = if (pattern != null) asl.ASLFR_DoPatterns else ignore, .data = 1 },
        .{ .tag = if (pattern != null) asl.ASLFR_InitialPattern else ignore, .data = argv[arg_pattern] },
        .{ .tag = if (argv[arg_accept] != 0) asl.ASLFR_AcceptPattern else ignore, .data = argv[arg_accept] },
        .{ .tag = if (argv[arg_reject] != 0) asl.ASLFR_RejectPattern else ignore, .data = argv[arg_reject] },
        .{ .tag = asl.ASLFR_DoSaveMode, .data = @intFromBool(argv[arg_savemode] != 0) },
        .{ .tag = asl.ASLFR_DoMultiSelect, .data = @intFromBool(argv[arg_multiselect] != 0) },
        .{ .tag = asl.ASLFR_DrawersOnly, .data = @intFromBool(argv[arg_drawersonly] != 0) },
        .{ .tag = asl.ASLFR_RejectIcons, .data = @intFromBool(argv[arg_noicons] != 0) },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOREQUEST, .{});
        return dos.RETURN_FAIL;
    };
    defer ab.FreeAslRequest(handle);
    const req: *asl.FileRequester = @ptrCast(@alignCast(handle));

    if (!ab.AslRequest(handle, null)) return dos.RETURN_WARN;

    const drawer: [*:0]const u8 = req.drawer orelse "";
    if (req.num_args > 0) {
        const list = req.arg_list.?;
        for (list[0..@intCast(req.num_args)], 0..) |arg, i| {
            writeName(dl, drawer, arg.name orelse "", i == 0);
        }
    } else {
        writeName(dl, drawer, req.file orelse "", true);
    }
    _ = dl.PutStr("\n");
    return dos.RETURN_OK;
}
