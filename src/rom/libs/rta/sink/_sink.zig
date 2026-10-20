// SPDX-License-Identifier: MPL-2.0
//! Making a sink, and passing the calls on to the driver that made it.
//!
//! The library reads the tags every driver shares, allocates the handle,
//! the driver's own data and the name, and then lets the driver fill the
//! rest in: its operations, its modes and its ring. Past that it keeps
//! what has to be the same for every sink - which mode it is in, whether
//! it has been started - and dispatches the rest. Where the driver left a
//! slot null, the answer is RTAERR_NOT_SUPPORTED: the library does not do
//! the work instead.
//!
//! One task plays through a sink at a time - audio.device's - so the
//! calls of a running sink take no lock of their own: the list's
//! semaphore holds the list still, not the sinks on it.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const TagItem = sdk.utility.TagItem;
const tags = rta.tags;

const RtaBase = @import("../rta.zig").RtaBase;

/// What the library keeps for a sink, beside the handle the caller sees.
pub const Private = struct {
    sink: rta.AudioSink = .{},
    /// The sink's name, since the caller's string is the caller's.
    name_buf: [32]u8 = .{0} ** 32,
};

/// The library's own record around a sink's handle.
///
/// INPUTS:
/// - `sink` - the sink.
pub fn privateOf(sink: *rta.AudioSink) *Private {
    return @fieldParentPtr("sink", sink);
}

/// What the tags say, before the driver sees them.
pub const Request = struct {
    name: ?[*:0]const u8 = null,
    user_data: ?*anyopaque = null,
    transport: ?*rta.AudioTransport = null,
    priority: i8 = 0,
    error_ptr: ?*i32 = null,
};

/// What the caller's tags ask of a new sink, read once.
///
/// INPUTS:
/// - `rb` - the library. Its tag calls read the list.
/// - `tag_list` - the caller's tags.
pub fn readRequest(rb: *RtaBase, tag_list: ?[*]const TagItem) Request {
    const ub = rb.utility_base;
    const priority: isize = @bitCast(ub.GetTagData(tags.RTAA_Priority, 0, tag_list));
    return .{
        .name = @ptrFromInt(ub.GetTagData(tags.RTAA_Name, 0, tag_list)),
        .user_data = @ptrFromInt(ub.GetTagData(tags.RTAA_UserData, 0, tag_list)),
        .transport = @ptrFromInt(ub.GetTagData(tags.RTAA_Transport, 0, tag_list)),
        .priority = @intCast(@max(-128, @min(127, priority))),
        .error_ptr = @ptrFromInt(ub.GetTagData(tags.RTAA_ErrorPtr, 0, tag_list)),
    };
}

/// The mode a new sink starts in: the one its driver marked the default,
/// or its first. Null for a sink with none.
///
/// INPUTS:
/// - `sink` - the sink, its modes filled in.
pub fn defaultMode(sink: *rta.AudioSink) ?*rta.AudioMode {
    var first: ?*rta.AudioMode = null;
    var it = sink.modes.iterator();
    while (it.next()) |node| {
        const mode: *rta.AudioMode = @fieldParentPtr("node", node);
        if (mode.flags & rta.sinks.AUDIOMF_DEFAULT != 0) return mode;
        if (first == null) first = mode;
    }
    return first;
}

/// The number a new sink is known by: FNV-1a over its driver's name, a
/// slash and its own name, so the same output has the same number from
/// one boot to the next whatever else the machine has; never 0. One that
/// another sink on the list has already moves on by one. Under the sink
/// list's semaphore, held to add the sink.
///
/// INPUTS:
/// - `rb` - the library.
/// - `driver_name` - the name of the driver that made it.
/// - `name` - its own name.
pub fn idFor(rb: *RtaBase, driver_name: [*:0]const u8, name: [*:0]const u8) u32 {
    var hash = nameHash(driver_name, name);
    while (hash == 0 or taken(rb, hash)) hash +%= 1;
    return hash;
}

/// FNV-1a over a driver's name, a slash and a handle's name: what a sink's
/// number, and a source's, starts from.
///
/// INPUTS:
/// - `driver_name` - the name of the driver that made it.
/// - `name` - its own name.
pub fn nameHash(driver_name: [*:0]const u8, name: [*:0]const u8) u32 {
    var hash: u32 = 0x811C_9DC5;
    for ([_][*:0]const u8{ driver_name, "/", name }) |part| {
        var at: usize = 0;
        while (part[at] != 0) : (at += 1) {
            hash ^= part[at];
            hash *%= 0x0100_0193;
        }
    }
    return hash;
}

/// Whether a sink on the list has that number.
fn taken(rb: *RtaBase, id: u32) bool {
    var it = rb.sinks.iterator();
    while (it.next()) |node| {
        const sink: *rta.AudioSink = @fieldParentPtr("node", node);
        if (sink.id == id) return true;
    }
    return false;
}

/// Whether the sink has been started and not stopped.
///
/// INPUTS:
/// - `sink` - the sink.
pub fn running(sink: *const rta.AudioSink) bool {
    return sink.flags & rta.sinks.AUDIOSF_RUNNING != 0;
}
