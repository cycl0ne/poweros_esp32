// SPDX-License-Identifier: MPL-2.0
//! acpi.resource's base: what the interpreter runs in, the namespace it
//! built from the firmware's tables, and what loading them found.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const Machine = @import("machine/_machine.zig").Machine;
const Node = @import("namespace/_namespace.zig").Node;

/// What loading the tables found, table by table and summed: the names
/// made; terms at a table's own level, outside any method, which are
/// counted and not yet run; names a table defines that one before it
/// already has, of which the first is kept; scopes a table opens that no
/// table has made, whose contents are left out; opcodes the interpreter
/// does not know, after which the rest of their term list is left out;
/// and terms that end past their package or their table.
pub const Loaded = extern struct {
    names: u32 = 0,
    code: u32 = 0,
    again: u32 = 0,
    missing: u32 = 0,
    unknown: u32 = 0,
    broken: u32 = 0,

    pub fn add(sum: *Loaded, more: Loaded) void {
        sum.names += more.names;
        sum.code += more.code;
        sum.again += more.again;
        sum.missing += more.missing;
        sum.unknown += more.unknown;
        sum.broken += more.broken;
    }
};

pub const AcpiBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What the interpreter asks for memory and for the log.
    machine: *const Machine,
    /// The resource's memory, many small blocks the namespace is made of.
    pool: ?*anyopaque = null,
    /// The namespace's root, `\`: null until it is made.
    root: ?*Node = null,
    /// How wide an integer is: 64 bits, or 32 under a DSDT of a revision
    /// below 2.
    integer_bits: u8 = 64,
    /// How many tables have been loaded, and what loading them found.
    tables: u16 = 0,
    loaded: Loaded = .{},
    /// Held by whoever reads the namespace.
    lock: exec.SignalSemaphore = .{},
};
