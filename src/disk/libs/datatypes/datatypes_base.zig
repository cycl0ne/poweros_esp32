// SPDX-License-Identifier: MIT
//! datatypes.library's base, and the list every part of it reads.
//!
//! The list of data types is not the library's: `C:AddDataTypes` builds
//! it and publishes it as the named object `DataTypesList`, and the
//! library takes a pointer to it when it is first opened. That is what
//! lets the descriptors be read again - a new format added, a
//! descriptor changed - without the library being unloaded, and what
//! makes opening the library fail cleanly on a system where
//! AddDataTypes has not run.
//!
//! datatypesclass is made here too, at the first open, because every
//! object of every format is one.

const sdk = @import("sdk");
const exec = sdk.exec;
const datatypes = sdk.datatypes;
const intuition = sdk.intuition;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IFFParseBase = sdk.interface.iffparse.IFFParseBase;

pub const DataTypesBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    dos_base: *DosBase,
    utility_base: *UtilityBase,
    intuition_base: *IntuitionBase,
    graphics_base: *GraphicsBase,
    iffparse_base: *IFFParseBase,
    /// What `C:AddDataTypes` published; null when it has not run.
    list: ?*datatypes.DataTypesList = null,
    /// datatypesclass, which every format's class is made from.
    class: ?*intuition.classes.Class = null,
};

/// The base from exec's Library header.
pub fn dtBase(lib: *exec.Library) *DataTypesBase {
    return @fieldParentPtr("lib", lib);
}

/// How much of a file is read to recognise it by.
pub const sniff_bytes = 512;
