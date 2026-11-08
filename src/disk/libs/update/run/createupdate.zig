// SPDX-License-Identifier: MIT
//! CreateUpdate: a run of the update made for one package, with what it
//! reads the package with opened.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const http = sdk.http;
const bsd = sdk.bsdsocket;
const utility = sdk.utility;
const prefs = sdk.prefs;
const update = sdk.update;
const UpdateBase = @import("../update_base.zig").UpdateBase;
const _run = @import("_run.zig");
const Run = _run.Run;
const _package = @import("../package/_package.zig");

/// Makes a run of the update for one package.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateUpdate(base: *UpdateBase, tags: ?[*]const TagItem) ?*Run
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `tags` - may be null:
///   - `UPD_Source` (`[*:0]const u8`): the package - a directory holding
///     `manifest`, `system/` and `boot/`, as a path, or an address with
///     `://` in it, read through LIBS:http.library. Left out, the SOURCE
///     `update.prefs` names (ENV:'s copy first, then ENVARC:'s), else the
///     source `ENVARC:Sys/install.prefs` kept.
///   - `UPD_Hook` (`*Hook`): where what the run says goes, an
///     `UpdateMessage` at a time, in place of the output.
///   - `UPD_Quiet` (bool): only failures on the output.
///
/// RESULT:
/// The run; or null where there was no memory for it (`IoErr`
/// ERROR_NO_FREE_STORE, nothing said), or where it could not start, the
/// reason said as a failure: `install.prefs` or `update.prefs` not a line
/// of settings, no package named and neither file naming one, a name
/// longer than a path can be, an address with LIBS:bsdsocket.library or
/// LIBS:http.library not there, no memory for the piece files are read in
/// or for the HTTP client.
///
/// BEHAVIOR:
/// Nothing of the package is read yet - DoUpdate reads it. The run is
/// made ready: what the install left read into it (the board this system
/// was built for, the partition its firmware reads), the package's name
/// copied into it, a 64 KiB piece to read and write files in, and for an
/// address bsdsocket.library and http.library opened with a client the
/// run's requests go through, which keeps its connection from one file
/// to the next.
///
/// CONTEXT:
/// - Waits: yes - for memory and for dos's packets.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Process: the run reads files on it and says what it says
///   on its output.
///
/// OWNERSHIP:
/// The run is the caller's, to let go with DeleteUpdate on the same task.
/// The tags are read during the call and the package's name is copied;
/// the hook is called until DeleteUpdate and stays the caller's.
///
/// NOTES:
/// A run belongs to the task that made it: dos's packets, the output and
/// the network libraries are that task's, and DoUpdate checks that task
/// for Ctrl-C. A program that runs the update on a process of its own
/// makes the run there.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DoUpdate`, `GetUpdateInfo`, `DeleteUpdate`, `ConfirmUpdate`,
/// `sdk.update`
///
/// EXAMPLES:
/// ```zig
/// const run = upd.CreateUpdate(&[_]utility.TagItem{
///     .{ .tag = update.UPD_Source, .data = @intFromPtr("http://10.0.2.2:8080/") },
///     .{},
/// }) orelse return dos.RETURN_FAIL;
/// defer upd.DeleteUpdate(run);
/// const code = upd.DoUpdate(run, &[_]utility.TagItem{
///     .{ .tag = update.UPD_Check, .data = 1 },
///     .{},
/// });
/// ```
pub fn CreateUpdate(base: *UpdateBase, tags: ?[*]const utility.TagItem) ?*Run {
    const run = _run.make(base, tags) orelse return null;
    run.object = run;
    if (!named(run, tags) or !ready(run)) {
        _run.free(run);
        return null;
    }
    return run;
}

/// The package's name copied into the run: the one `tags` give, else the
/// one `update.prefs` names, else where the install came from. False
/// where there is none or it is too long, or `update.prefs` is not a line
/// of settings, said.
fn named(run: *Run, tags: ?[*]const utility.TagItem) bool {
    const ub = run.ub;
    var wanted: prefs.update.Settings = .{};
    const given: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(update.UPD_Source, 0, tags));
    const from: [*:0]const u8 = given orelse found: {
        const text = prefs.loadWhole(run.sys, run.dl, prefs.update.ENV_FILE) orelse
            prefs.loadWhole(run.sys, run.dl, prefs.update.ENVARC_FILE);
        if (text) |file| {
            defer run.sys.FreeVec(@ptrCast(file.ptr));
            if (prefs.firstLine(file)) |line| {
                if (prefs.update.parse(ub, line, &wanted)) |wrong| {
                    _ = _run.fail(run, "%s: %s\n", .{ prefs.update.ENVARC_FILE, wrong });
                    return false;
                }
            }
        }
        if (prefs.update.sourceText(&wanted).len != 0) break :found @ptrCast(&wanted.source);
        const kept: [*:0]const u8 = @ptrCast(&run.settings.source);
        if (kept[0] != 0) break :found kept;
        _ = _run.fail(run, "no package named, and neither %s nor %s says where to look\n", .{
            prefs.update.ENVARC_FILE, prefs.install.ENVARC_FILE,
        });
        return false;
    };
    const length = ub.Strlen(from);
    if (length == 0 or length >= run.from_text.len) {
        _ = _run.fail(run, "%s is not the name of a package\n", .{from});
        return false;
    }
    _ = ub.Strlcpy(&run.from_text, run.from_text.len, from);
    run.from = @ptrCast(&run.from_text);
    run.kind = if (_package.isAddress(run.from[0..length])) .address else .path;
    return true;
}

/// What the run reads with, opened: the piece files are read and written
/// in, and for an address the network's libraries and an HTTP client.
/// False where something is not there, said; `_run.free` closes what was
/// opened.
fn ready(run: *Run) bool {
    const sys = run.sys;
    const memory = sys.AllocVec(_run.buffer_bytes, exec.MEMF_ANY) orelse {
        _ = _run.fail(run, "no memory\n", .{});
        return false;
    };
    const bytes: [*]u8 = @ptrCast(memory);
    run.buffer = bytes[0.._run.buffer_bytes];
    if (run.kind != .address) return true;

    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse {
        _ = _run.fail(run, "%s is an address and %s is not there\n", .{ run.from, bsd.SOCKETNAME });
        return false;
    };
    run.sb = @ptrCast(socket_lib);
    const http_lib = sys.OpenLibrary(http.HTTPNAME, 1) orelse {
        _ = _run.fail(run, "%s is an address and %s is not there\n", .{ run.from, http.HTTPNAME });
        return false;
    };
    run.hb = @ptrCast(http_lib);
    run.client = run.hb.?.CreateClient(run.sb.?, &[_]utility.TagItem{
        .{ .tag = http.HTTP_UserAgent, .data = @intFromPtr("PowerOS-Update/1.0") },
        .{},
    }) orelse {
        _ = _run.fail(run, "no memory for the HTTP client\n", .{});
        return false;
    };
    return true;
}
