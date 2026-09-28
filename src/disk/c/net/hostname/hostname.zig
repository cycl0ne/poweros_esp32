// SPDX-License-Identifier: MIT
//! HostName: the machine's name on the network, shown or set. Built
//! against the SDK only.
//!
//!   HostName NAME,SAVE/S
//!
//! Without NAME it prints the name bsdsocket.library has - the one in
//! ENVARC:Sys/net/hostname, or "poweros" without one. With NAME it sets it
//! for the running system: 1 to 63 letters, digits and hyphens, not
//! beginning or ending with a hyphen. DHCP requests from then on carry it.
//! SAVE writes the name to ENVARC:Sys/net/hostname as well, so that it
//! holds from the next boot.

const sdk = @import("sdk");
const dos = sdk.dos;
const bsd = sdk.bsdsocket;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const Printf = dos.stdio.Printf;
const rdargs = dos.rdargs;

pub const COMMAND_NAME = "HostName";
const VERSION_STRING = "\x00$VER: HostName 1.0 (28.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "NAME,SAVE/S";
const arg_name = 0;
const arg_save = 1;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NAME = "%s\n";
const MSG_BADNAME = "%s: a host name is 1 to 63 letters, digits and hyphens\n";
const MSG_NOSAVE = "%s: can't write %s\n";

/// What the file holds above the name.
const file_head =
    "# ENVARC:Sys/net/hostname - the machine's name on the network, which\n" ++
    "# DHCP servers are told and may show and register: 1 to 63 letters,\n" ++
    "# digits and hyphens. The first line that is not a comment is read.\n" ++
    "# C:net/HostName NAME SAVE writes this file.\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, bsd.SOCKETNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(socket_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);

    if (rdargs.string(argv[arg_name])) |name| {
        if (sb.SetHostName(name) != 0) {
            _ = Printf(dl, MSG_BADNAME, .{name});
            return dos.RETURN_ERROR;
        }
    }
    var name: [64]u8 = @splat(0);
    if (sb.GetHostName(&name, name.len) != 0) return dos.RETURN_FAIL;
    const shown: [*:0]const u8 = @ptrCast(&name);
    if (argv[arg_save] == 0) {
        if (argv[arg_name] == 0) _ = Printf(dl, MSG_NAME, .{shown});
        return dos.RETURN_OK;
    }

    const file = dl.Open(bsd.HOSTNAME_FILE, dos.MODE_NEWFILE) orelse {
        _ = Printf(dl, MSG_NOSAVE, .{ COMMAND_NAME, bsd.HOSTNAME_FILE });
        return dos.RETURN_ERROR;
    };
    defer _ = dl.Close(file);
    var length: usize = 0;
    while (name[length] != 0) length += 1;
    name[length] = '\n';
    if (dl.Write(file, file_head, file_head.len) != file_head.len or
        dl.Write(file, &name, @intCast(length + 1)) != length + 1)
    {
        _ = Printf(dl, MSG_NOSAVE, .{ COMMAND_NAME, bsd.HOSTNAME_FILE });
        return dos.RETURN_ERROR;
    }
    return dos.RETURN_OK;
}
