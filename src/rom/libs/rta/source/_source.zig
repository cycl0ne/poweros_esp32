// SPDX-License-Identifier: MPL-2.0
//! Making a source, and passing the calls on to the driver that made it.
//!
//! A source is made the way a sink is: the library reads the tags every
//! driver shares (`_sink.readRequest`), allocates the handle, the
//! driver's own data and the name, and the driver fills in the rest - its
//! operations, its modes and its ring. Past that the library keeps which
//! mode it runs in and whether it has been started, and dispatches the
//! rest; a slot the driver left null answers RTAERR_NOT_SUPPORTED.
//!
//! One task records from a source at a time - audio.device's - so the
//! calls of a running source take no lock of their own: the list's
//! semaphore holds the list still, not the sources on it.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;

const RtaBase = @import("../rta.zig").RtaBase;
const _sink = @import("../sink/_sink.zig");

/// What the library keeps for a source, beside the handle the caller
/// sees.
pub const Private = struct {
    source: rta.AudioSource = .{},
    /// The source's name, since the caller's string is the caller's.
    name_buf: [32]u8 = .{0} ** 32,
};

/// The library's own record around a source's handle.
///
/// INPUTS:
/// - `source` - the source.
pub fn privateOf(source: *rta.AudioSource) *Private {
    return @fieldParentPtr("source", source);
}

/// The mode a source starts in when none is asked for: the one its driver
/// marked the default, or its first. Null for a source with none.
///
/// INPUTS:
/// - `source` - the source, its modes filled in.
pub fn defaultMode(source: *rta.AudioSource) ?*rta.AudioMode {
    var first: ?*rta.AudioMode = null;
    var it = source.modes.iterator();
    while (it.next()) |node| {
        const mode: *rta.AudioMode = @fieldParentPtr("node", node);
        if (mode.flags & rta.sinks.AUDIOMF_DEFAULT != 0) return mode;
        if (first == null) first = mode;
    }
    return first;
}

/// Whether `mode` is one of the source's own.
///
/// INPUTS:
/// - `source` - the source.
/// - `mode` - the mode asked for.
pub fn hasMode(source: *rta.AudioSource, mode: *const rta.AudioMode) bool {
    var it = source.modes.iterator();
    while (it.next()) |node| {
        if (node == &mode.node) return true;
    }
    return false;
}

/// The number a new source is known by: as a sink's, from its driver's
/// name and its own, moved on by one past a number another source on the
/// list has already; never 0. Under the list's semaphore, held to add it.
///
/// INPUTS:
/// - `rb` - the library.
/// - `driver_name` - the name of the driver that made it.
/// - `name` - its own name.
pub fn idFor(rb: *RtaBase, driver_name: [*:0]const u8, name: [*:0]const u8) u32 {
    var hash = _sink.nameHash(driver_name, name);
    while (hash == 0 or taken(rb, hash)) hash +%= 1;
    return hash;
}

/// Whether a source on the list has that number.
fn taken(rb: *RtaBase, id: u32) bool {
    var it = rb.sources.iterator();
    while (it.next()) |node| {
        const source: *rta.AudioSource = @fieldParentPtr("node", node);
        if (source.id == id) return true;
    }
    return false;
}

/// Whether the source has been started and not stopped.
///
/// INPUTS:
/// - `source` - the source.
pub fn running(source: *const rta.AudioSource) bool {
    return source.flags & rta.sources.AUDIOSRCF_RUNNING != 0;
}
