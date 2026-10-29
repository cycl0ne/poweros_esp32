// SPDX-License-Identifier: MIT
//! CloseCatalog: a catalog given back.

const sdk = @import("sdk");
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const LocaleBase = _base.LocaleBase;

/// Gives a catalog back.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseCatalog(lb: *LocaleBase, catalog: ?*locale.Catalog) void
/// ```
///
/// SINCE: 1.0. LVO -112.
///
/// INPUTS:
/// - `catalog` - a catalog from OpenCatalogA; null does nothing, so the
///   answer of an OpenCatalogA that found none may be handed over as it
///   is.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The catalog is held once by each OpenCatalogA that answered it. One no
/// one holds stays loaded, for the next program that asks, until the
/// library is asked to give memory back.
///
/// CONTEXT:
/// - Waits: for the library's lock, for a moment.
/// - Interrupts: no.
/// - Locks: takes the library's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's hold ends: the catalog's strings may be gone once this
/// returns.
///
/// NOTES:
/// A string from GetCatalogStr is the catalog's: copy what is needed
/// after the catalog is closed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenCatalogA`, `GetCatalogStr`
///
/// EXAMPLES:
/// ```zig
/// const catalog = lb.OpenCatalogA(null, "c/test/locale.catalog", null);
/// defer lb.CloseCatalog(catalog);
/// ```
pub fn CloseCatalog(lb: *LocaleBase, catalog: ?*locale.Catalog) void {
    const ext = _base.catalogOf(catalog orelse return);
    const sys = lb.sys_base;
    sys.ObtainSemaphore(&lb.lock);
    if (ext.usage != 0) ext.usage -= 1;
    sys.ReleaseSemaphore(&lb.lock);
}
