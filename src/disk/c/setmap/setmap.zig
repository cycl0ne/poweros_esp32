// SPDX-License-Identifier: MIT
//! SetMap: which keymap the machine uses. Built against the SDK only.
//!
//!   SetMap KEYMAP
//!
//! With a name - "deutsch", "usa" - makes that keymap.library's default,
//! which every key made into a character from then on goes through. With
//! none, says which it is.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const km = sdk.keymap;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const KeymapBase = sdk.interface.keymap.KeymapBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "SetMap";
const VERSION_STRING = "\x00$VER: SetMap 1.0 (20.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "KEYMAP";
const arg_keymap = 0;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOTFOUND = "Keymap %s not found - there are deutsch and usa\n";
const MSG_CURRENT = "Keymap %s\n";

/// The ROM's keymaps, to name the default.
const names = [_][*:0]const u8{ "deutsch", "usa" };

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

    const lib = sys.OpenLibrary(km.KEYMAPNAME, km.KEYMAP_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{km.KEYMAPNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(lib);
    const kb: *KeymapBase = @ptrCast(lib);

    if (argv[arg_keymap] == 0) {
        const now = kb.AskKeyMapDefault();
        for (names) |name| {
            if (kb.FindKeyMap(name) == now) {
                _ = Printf(dl, MSG_CURRENT, .{name});
                return dos.RETURN_OK;
            }
        }
        _ = Printf(dl, MSG_CURRENT, .{@as([*:0]const u8, "(not one of the ROM's)")});
        return dos.RETURN_OK;
    }
    const name: [*:0]const u8 = @ptrFromInt(argv[arg_keymap]);
    const map = kb.FindKeyMap(name) orelse {
        _ = Printf(dl, MSG_NOTFOUND, .{name});
        return dos.RETURN_ERROR;
    };
    kb.SetKeyMapDefault(map);
    return dos.RETURN_OK;
}
