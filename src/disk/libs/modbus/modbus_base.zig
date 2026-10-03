// SPDX-License-Identifier: MIT
//! modbus.library's base: exec's Library header, what it was loaded
//! from, and utility.library, for the tags. There is one base, shared by
//! every opener: a client's bus or connection is its ModbusContext, a
//! server is its ModbusServer.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

pub const ModbusBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    utility_base: *UtilityBase,
};

pub fn modbusBase(lib: *exec.Library) *ModbusBase {
    return @fieldParentPtr("lib", lib);
}
