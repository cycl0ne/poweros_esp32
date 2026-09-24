// SPDX-License-Identifier: MPL-2.0
//! utility.library as a library: its base, and the Expunge vector that
//! keeps it in memory.

const sdk = @import("sdk");
const exec = sdk.exec;

const ExecBase = sdk.interface.exec.ExecBase;
const NamedObject = sdk.utility.NamedObject;

/// struct UtilityBase: `ub_LibNode`, `ub_Language` and `ub_Reserved` are
/// public; the rest is the library's own.
pub const UtilityBase = extern struct {
    lib: exec.Library,
    /// ub_Language: the system's language. Nothing sets it yet.
    language: u8,
    /// ub_Reserved: padding the public part keeps.
    reserved: u8,
    /// ub_SysBase: exec, called through the SDK's interface.
    sys_base: *ExecBase,
    /// ub_MasterSpace: the root name space, a named object with a name
    /// space.
    master_space: *NamedObject,
    /// ub_Sequence: GetUniqueID's last ID.
    sequence: u32,
    /// `*` is a wildcard for the patterns parsed from now on (SetWildStar).
    wild_star: bool,

    /// This library as a caller sees it, to call its own functions through the
    /// jump table.
    ///
    /// INPUTS:
    /// - `ub` - the library's base.
    pub fn iface(ub: *UtilityBase) *sdk.interface.utility.UtilityBase {
        return @ptrCast(ub);
    }
};

/// Expunge vector: refuses, always. The library is part of the ROM, and
/// other modules hold its base from their init on.
///
/// INPUTS:
/// - `_` - the library, unused.
///
/// RESULT:
/// Null: there is no segment to give back.
pub fn expunge(_: *exec.Library) callconv(.c) ?*anyopaque {
    return null;
}
