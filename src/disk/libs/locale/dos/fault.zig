// SPDX-License-Identifier: MIT
//! dos's Fault, in the default locale's language: the text of a code from
//! the catalog of dos's texts, `sys/dos.catalog`, when it has one; dos's
//! own Fault for the rest - a code the catalog lacks, code 0, no catalog.
//!
//! The text is put together as dos puts it: "header: text", or the text
//! alone for a null header, cut to the buffer with its NUL; the length
//! written is the answer. The catalog is read under the library's lock,
//! which a change of the default locale takes to swap it.

const sdk = @import("sdk");
const _base = @import("../locale_base.zig");
const _dos = @import("_dos.zig");
const LocaleBase = _base.LocaleBase;
const DosBase = sdk.interface.dos.DosBase;
const DosFn = sdk.interface.dos.Fn;

/// What stands in dos's jump table: the library found, the call made.
pub fn dosFault(db: *DosBase, code: i32, header: ?[*:0]const u8, buffer: [*]u8, len: i32) callconv(.c) i32 {
    const lb = _dos.enter() orelse return 0;
    defer _dos.leave(lb);
    if (fault(lb, code, header, buffer, len)) |written| return written;
    const own = _dos.original(lb, DosFn.Fault, "dos_fault");
    return own(db, code, header, buffer, len);
}

/// Fault from the catalog of dos's texts; null when it has no text for
/// `code`, and for code 0 or no buffer.
pub fn fault(lb: *LocaleBase, code: i32, header: ?[*:0]const u8, buffer: [*]u8, len: i32) ?i32 {
    if (code == 0 or len <= 0) return null;
    const sys = lb.sys_base;
    sys.ObtainSemaphoreShared(&lb.lock);
    defer sys.ReleaseSemaphore(&lb.lock);
    const catalog = lb.dos_catalog orelse return null;
    const missing: [*:0]const u8 = "";
    const text = lb.iface().GetCatalogStr(catalog, code, missing);
    if (text == missing) return null;

    const room: usize = @as(usize, @intCast(len)) - 1;
    var at: usize = 0;
    const parts = [_]?[*:0]const u8{ header, if (header != null) ": " else null, text };
    for (parts) |part| {
        const string = part orelse continue;
        var from: usize = 0;
        while (string[from] != 0 and at < room) : (from += 1) {
            buffer[at] = string[from];
            at += 1;
        }
    }
    buffer[at] = 0;
    return @intCast(at);
}
