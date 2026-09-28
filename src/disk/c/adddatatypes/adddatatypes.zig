// SPDX-License-Identifier: MIT
//! AddDataTypes: the descriptors of DEVS:DataTypes read into the list
//! datatypes.library works from. Built against the SDK only.
//!
//!   AddDataTypes [FILES/M] [REFRESH/S] [REMOVE/S] [LIST/S] [QUIET/S]
//!
//! With no arguments it reads every file in `DEVS:DataTypes`. With
//! `FILES` it reads the ones named, wherever they are, which is how a
//! new format is added without a reboot. `REFRESH` forgets what was
//! read before and reads the directory again; `REMOVE` takes the named
//! types off the list; `LIST` prints what is on it.
//!
//! The list itself is published as the named object `DataTypesList`, so
//! that this command owns the memory and datatypes.library only reads
//! it. That is why the startup-sequence runs this before anything opens
//! the library: without the list there is nothing to recognise a file
//! by, and the library refuses to open.
//!
//! A descriptor is a text file read with `ReadArgs`:
//!
//!   NAME=ILBM BASE=ilbm GROUP=pict ID=ILBM TYPE=IFF PRI=0
//!   PATTERN=#?.(iff|ilbm|lbm)
//!
//! `MASK` is the bytes the file starts with: `?` stands for any byte
//! and `\xNN` for one written as a number. `DIR` says the descriptor is
//! for a directory. `RECOGNISE` says the class knows how to tell and is
//! to be asked. `CASE` matches the pattern
//! with regard to case. `PRI` decides the order they are tried in,
//! highest first, so the descriptors that catch whatever is left - plain
//! text, plain bytes - are given a low one.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const datatypes = sdk.datatypes;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const Printf = dos.stdio.Printf;
const TagItem = utility.TagItem;
const descriptor = @import("descriptor.zig");
const readDescriptor = descriptor.readDescriptor;
const idText = descriptor.idText;
const textLen = descriptor.textLen;

pub const COMMAND_NAME = "AddDataTypes";
const VERSION_STRING = "\x00$VER: AddDataTypes 1.0 (29.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILES/M,REFRESH/S,REMOVE/S,LIST/S,QUIET/S";
const arg_files = 0;
const arg_refresh = 1;
const arg_remove = 2;
const arg_list = 3;
const arg_quiet = 4;

const MSG_NOLIST = "No memory for the data type list\n";
const MSG_NOREAD = "Cannot read %s\n";
const MSG_BAD = "%s: not a data type descriptor\n";
const MSG_ADDED = "%s added\n";
const MSG_REMOVED = "%s removed\n";
const MSG_INUSE = "%s is in use\n";
const MSG_NOTFOUND = "%s: no such data type\n";
const MSG_LINE = "%-16s %-5s %-5s %4ld  %s\n";
const MSG_HEAD = "Name             Group ID     Pri  Class\n";
const MSG_COUNT = "%ld data types\n";

/// How big a descriptor file may be.
const max_descriptor = 1024;

/// The list, found or made and published.
fn listOf(sys: *ExecBase, ub: *UtilityBase) ?*datatypes.DataTypesList {
    if (ub.FindNamedObject(null, datatypes.DATATYPESLIST_NAME, null)) |found| {
        const list: ?*datatypes.DataTypesList = @ptrCast(@alignCast(found.object));
        ub.ReleaseNamedObject(found);
        return list;
    }
    const tags = [_]TagItem{
        .{ .tag = utility.ANO_UserSpace, .data = @sizeOf(datatypes.DataTypesList) },
        .{},
    };
    const made = ub.AllocNamedObjectA(datatypes.DATATYPESLIST_NAME, &tags) orelse return null;
    const list: *datatypes.DataTypesList = @ptrCast(@alignCast(made.object.?));
    list.* = .{};
    sys.InitSemaphore(&list.lock);
    list.all.init(.unknown);
    if (!ub.AddNamedObject(null, made)) {
        ub.FreeNamedObject(made);
        return null;
    }
    return list;
}

/// A descriptor put on the list, highest priority first, and whatever
/// was there under the same name taken off.
fn addOne(sys: *ExecBase, list: *datatypes.DataTypesList, dt: *datatypes.DataType) bool {
    sys.ObtainSemaphore(&list.lock);
    defer sys.ReleaseSemaphore(&list.lock);
    var it = list.all.iterator();
    while (it.next()) |node| {
        const other: *datatypes.DataType = @fieldParentPtr("node", node);
        if (!sameName(other.node.name.?, dt.node.name.?)) continue;
        if (other.uses != 0) return false;
        sys.Remove(node);
        list.count -= 1;
        sys.FreeVec(other);
        break;
    }
    sys.Enqueue(&list.all, &dt.node);
    list.count += 1;
    return true;
}

fn sameName(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (a[i] != 0 and b[i] != 0) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return a[i] == b[i];
}

/// One descriptor file read and added.
fn addFile(sys: *ExecBase, dl: *DosBase, ub: *UtilityBase, list: *datatypes.DataTypesList, name: [*:0]const u8, quiet: bool) void {
    const file = dl.Open(name, dos.MODE_OLDFILE) orelse {
        if (!quiet) _ = Printf(dl, MSG_NOREAD, .{name});
        return;
    };
    defer _ = dl.Close(file);
    const memory = sys.AllocVec(max_descriptor, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return;
    defer sys.FreeVec(memory);
    const text: [*]u8 = @ptrCast(memory);
    const got = dl.Read(file, text, max_descriptor - 2);
    if (got <= 0) {
        if (!quiet) _ = Printf(dl, MSG_NOREAD, .{name});
        return;
    }
    // ReadArgs wants a line to end.
    var length: usize = @intCast(got);
    if (text[length - 1] != '\n') {
        text[length] = '\n';
        length += 1;
    }
    const dt = readDescriptor(sys, dl, ub, text[0..length]) orelse {
        if (!quiet) _ = Printf(dl, MSG_BAD, .{name});
        return;
    };
    if (!addOne(sys, list, dt)) {
        sys.FreeVec(dt);
        if (!quiet) _ = Printf(dl, MSG_INUSE, .{dt.header.name});
        return;
    }
    if (!quiet) _ = Printf(dl, MSG_ADDED, .{dt.header.name});
}

/// Every file of DEVS:DataTypes read.
fn addAll(sys: *ExecBase, dl: *DosBase, ub: *UtilityBase, list: *datatypes.DataTypesList, quiet: bool) void {
    const lock = dl.Lock(datatypes.DATATYPES_DIR, dos.SHARED_LOCK) orelse {
        if (!quiet) _ = Printf(dl, MSG_NOREAD, .{datatypes.DATATYPES_DIR});
        return;
    };
    defer dl.UnLock(lock);
    const fib_memory = sys.AllocVec(@sizeOf(dos.FileInfoBlock), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return;
    defer sys.FreeVec(fib_memory);
    const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(fib_memory));
    if (!dl.Examine(lock, fib)) return;
    var path: [256]u8 = @splat(0);
    while (dl.ExNext(lock, fib)) {
        if (fib.dir_entry_type > 0) continue;
        const dir = datatypes.DATATYPES_DIR;
        @memcpy(path[0..dir.len], dir);
        path[dir.len] = '/';
        const name_len = textLen(@ptrCast(&fib.file_name));
        if (dir.len + 1 + name_len + 1 > path.len) continue;
        @memcpy(path[dir.len + 1 ..][0..name_len], fib.file_name[0..name_len]);
        path[dir.len + 1 + name_len] = 0;
        addFile(sys, dl, ub, list, @ptrCast(&path), quiet);
    }
}

/// The named types taken off the list.
fn removeThem(sys: *ExecBase, dl: *DosBase, list: *datatypes.DataTypesList, names: [*]const usize, quiet: bool) void {
    var i: usize = 0;
    while (names[i] != 0) : (i += 1) {
        const wanted: [*:0]const u8 = @ptrFromInt(names[i]);
        sys.ObtainSemaphore(&list.lock);
        var found = false;
        var it = list.all.iterator();
        while (it.next()) |node| {
            const dt: *datatypes.DataType = @fieldParentPtr("node", node);
            if (!sameName(dt.node.name.?, wanted)) continue;
            found = true;
            if (dt.uses != 0) {
                sys.ReleaseSemaphore(&list.lock);
                if (!quiet) _ = Printf(dl, MSG_INUSE, .{wanted});
                break;
            }
            sys.Remove(node);
            list.count -= 1;
            sys.FreeVec(dt);
            sys.ReleaseSemaphore(&list.lock);
            if (!quiet) _ = Printf(dl, MSG_REMOVED, .{wanted});
            break;
        } else {
            sys.ReleaseSemaphore(&list.lock);
        }
        if (!found and !quiet) _ = Printf(dl, MSG_NOTFOUND, .{wanted});
    }
}

/// What is on the list.
fn printList(sys: *ExecBase, dl: *DosBase, list: *datatypes.DataTypesList) void {
    sys.ObtainSemaphoreShared(&list.lock);
    defer sys.ReleaseSemaphore(&list.lock);
    _ = Printf(dl, MSG_HEAD, .{});
    var group_text: [5]u8 = undefined;
    var id_text: [5]u8 = undefined;
    var it = list.all.iterator();
    while (it.next()) |node| {
        const dt: *datatypes.DataType = @fieldParentPtr("node", node);
        _ = Printf(dl, MSG_LINE, .{
            dt.header.name,
            idText(dt.header.group_id, &group_text),
            idText(dt.header.id, &id_text),
            @as(i64, dt.header.priority),
            dt.header.base_name,
        });
    }
    _ = Printf(dl, MSG_COUNT, .{@as(i64, list.count)});
}

/// Everything on the list thrown away, so the directory can be read
/// afresh. What is in use stays.
fn forgetAll(sys: *ExecBase, list: *datatypes.DataTypesList) void {
    sys.ObtainSemaphore(&list.lock);
    defer sys.ReleaseSemaphore(&list.lock);
    var at = list.all.head;
    while (at) |node| {
        const next = node.succ orelse break;
        const dt: *datatypes.DataType = @fieldParentPtr("node", node);
        at = next;
        if (dt.uses != 0) continue;
        sys.Remove(node);
        list.count -= 1;
        sys.FreeVec(dt);
    }
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    const util_lib = sys.OpenLibrary(utility.UTILITYNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(util_lib);
    const ub: *UtilityBase = @ptrCast(util_lib);

    var argv: [5]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const quiet = argv[arg_quiet] != 0;

    const list = listOf(sys, ub) orelse {
        if (!quiet) _ = Printf(dl, MSG_NOLIST, .{});
        return dos.RETURN_FAIL;
    };

    if (argv[arg_list] != 0) {
        printList(sys, dl, list);
        return dos.RETURN_OK;
    }
    if (argv[arg_remove] != 0) {
        if (argv[arg_files] == 0) return dos.RETURN_WARN;
        removeThem(sys, dl, list, @ptrFromInt(argv[arg_files]), quiet);
        return dos.RETURN_OK;
    }
    if (argv[arg_refresh] != 0) forgetAll(sys, list);
    if (argv[arg_files] != 0) {
        const names: [*]const usize = @ptrFromInt(argv[arg_files]);
        var i: usize = 0;
        while (names[i] != 0) : (i += 1) addFile(sys, dl, ub, list, @ptrFromInt(names[i]), quiet);
    } else {
        addAll(sys, dl, ub, list, quiet);
    }
    return dos.RETURN_OK;
}
