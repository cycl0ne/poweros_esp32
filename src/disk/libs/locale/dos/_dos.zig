// SPDX-License-Identifier: MIT
//! The library in front of dos.library: from the first SetDefaultLocale
//! on, dos's DateToStr, StrToDate and Fault are the library's, and write
//! and read in the default locale's words, formats and language.
//!
//! The three are put in dos's jump table with SetFunction, and dos's own
//! kept in the base, under the lock, which a replacement takes to read
//! them. From then on the library holds itself open: a jump table may
//! point into it at any time, so it never goes.
//!
//! A replacement is handed dos's base, not the library's, so it finds the
//! library by exec's AbsExecBase word, opening it for the call (`enter`);
//! what it does is in `datetostr.zig`, `strtodate.zig` and `fault.zig`,
//! each a function of the library's base.
//!
//! The catalog dos's texts come from is the default locale's, opened by
//! SetDefaultLocale each time the default changes (`useCatalog`).

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const _locale = @import("../locale/_locale.zig");
const LocaleBase = _base.LocaleBase;
const DosLVO = sdk.interface.dos.LVO;

/// The catalog of dos's texts, by their codes.
pub const dos_catalog_name = "sys/dos.catalog";
/// The version of it dos's texts are: its descriptor's #version.
pub const dos_catalog_version = 1;

/// dos's three put in front of, once; the library holds itself open from
/// then on. The caller holds nothing.
pub fn install(lb: *LocaleBase) void {
    const sys = lb.sys_base;
    sys.ObtainSemaphore(&lb.lock);
    defer sys.ReleaseSemaphore(&lb.lock);
    if (lb.dos_fault != null) return;
    // The library's own open count: the jump tables point into it now.
    _ = sys.OpenLibrary(locale.LOCALENAME, 0);
    const dos_lib = lb.dos_base.lib();
    lb.dos_date_to_str = sys.SetFunction(dos_lib, DosLVO.DateToStr, exec.vec(@import("datetostr.zig").dosDateToStr));
    lb.dos_str_to_date = sys.SetFunction(dos_lib, DosLVO.StrToDate, exec.vec(@import("strtodate.zig").dosStrToDate));
    lb.dos_fault = sys.SetFunction(dos_lib, DosLVO.Fault, exec.vec(@import("fault.zig").dosFault));
}

/// dos's own three put back and the library's hold given up, for the host
/// tests, which take the library down; true when they were installed.
pub fn remove(lb: *LocaleBase) bool {
    const sys = lb.sys_base;
    sys.ObtainSemaphore(&lb.lock);
    const old_fault = lb.dos_fault orelse {
        sys.ReleaseSemaphore(&lb.lock);
        return false;
    };
    const dos_lib = lb.dos_base.lib();
    _ = sys.SetFunction(dos_lib, DosLVO.DateToStr, lb.dos_date_to_str.?);
    _ = sys.SetFunction(dos_lib, DosLVO.StrToDate, lb.dos_str_to_date.?);
    _ = sys.SetFunction(dos_lib, DosLVO.Fault, old_fault);
    lb.dos_date_to_str = null;
    lb.dos_str_to_date = null;
    lb.dos_fault = null;
    const catalog = lb.dos_catalog;
    lb.dos_catalog = null;
    sys.ReleaseSemaphore(&lb.lock);
    lb.iface().CloseCatalog(catalog);
    sys.CloseLibrary(&lb.lib);
    return true;
}

/// The catalog of dos's texts in `loc`'s languages made the one Fault
/// takes them from, and the one before given back. Reads files, so the
/// caller holds nothing.
pub fn useCatalog(lb: *LocaleBase, loc: *const locale.Locale) void {
    const library = lb.iface();
    const tags = [_]utility.TagItem{
        .{ .tag = locale.OC_BuiltInLanguage, .data = @intFromPtr(_locale.english) },
        .{ .tag = locale.OC_Version, .data = dos_catalog_version },
        .{},
    };
    const catalog = library.OpenCatalogA(loc, dos_catalog_name, &tags);
    const sys = lb.sys_base;
    sys.ObtainSemaphore(&lb.lock);
    const before = lb.dos_catalog;
    lb.dos_catalog = catalog;
    sys.ReleaseSemaphore(&lb.lock);
    library.CloseCatalog(before);
}

/// dos's own function behind `field`, of type `F`, read under the lock.
pub fn original(lb: *LocaleBase, comptime F: type, comptime field: []const u8) F {
    const sys = lb.sys_base;
    sys.ObtainSemaphoreShared(&lb.lock);
    defer sys.ReleaseSemaphore(&lb.lock);
    return @ptrCast(@alignCast(@field(lb, field).?));
}

/// The library, opened for a replacement's call: found by AbsExecBase,
/// since a replacement is handed dos's base. Never null once installed,
/// as the library holds itself open.
pub fn enter() ?*LocaleBase {
    const cell: *const volatile *exec.ExecBase = exec.AbsExecBase;
    const lib = cell.*.OpenLibrary(locale.LOCALENAME, 0) orelse return null;
    return _base.localeBase(lib);
}

/// The call's hold given back.
pub fn leave(lb: *LocaleBase) void {
    lb.sys_base.CloseLibrary(&lb.lib);
}
