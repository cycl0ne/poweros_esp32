// SPDX-License-Identifier: MPL-2.0
//! acpi.resource's base: what the interpreter runs in, the namespace it
//! built from the firmware's tables, and what loading them found.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const Machine = @import("machine/_machine.zig").Machine;
const Node = @import("namespace/_namespace.zig").Node;

/// What loading the tables found, table by table and summed: the names
/// made; terms at a table's own level, outside any method, which run as
/// they are met, and those of them that ended with an error; names a
/// table defines that one before it already has, of which the first is
/// kept; scopes a table opens, and names a definition refers to, that no
/// table has made, whose terms are left out; opcodes the interpreter does
/// not know, after which the rest of their term list is left out; and
/// terms that end past their package or their table.
pub const Loaded = extern struct {
    names: u32 = 0,
    code: u32 = 0,
    failed: u32 = 0,
    again: u32 = 0,
    missing: u32 = 0,
    unknown: u32 = 0,
    broken: u32 = 0,

    pub fn add(sum: *Loaded, more: Loaded) void {
        sum.names += more.names;
        sum.code += more.code;
        sum.failed += more.failed;
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
    /// Never signalled: what Sleep waits for, for as long as it asks.
    never: exec.Waitable = .{},
    /// The firmware's root table, where the tables a DataTableRegion and
    /// LoadTable name are looked for; 0 where there is none.
    firmware: usize = 0,
    /// Where PCI's configuration space is mapped, the first segment's:
    /// what the board's bridge part names; 0 where there is none.
    pci_config: usize = 0,
    /// The address spaces whose regions have been told they can be
    /// reached (their `_REG` run), a bit for each space.
    connected: [4]u64 = .{ 0, 0, 0, 0 },
    /// The notifications the bytecode sent and nobody has taken yet.
    notices: Notices = .{},
    /// The tables Load copied in, which the namespace's methods run from.
    copies: ?*anyopaque = null,
};

/// The notifications the bytecode's Notify sent, oldest first: each the
/// device it is about, held, and the value. One sent while it is full is
/// counted as lost.
pub const Notices = extern struct {
    nodes: [MOST_NOTICES]?*Node = [_]?*Node{null} ** MOST_NOTICES,
    values: [MOST_NOTICES]u32 = [_]u32{0} ** MOST_NOTICES,
    first: u32 = 0,
    count: u32 = 0,
    lost: u32 = 0,
};

pub const MOST_NOTICES = 32;
