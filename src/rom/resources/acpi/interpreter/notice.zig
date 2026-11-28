// SPDX-License-Identifier: MPL-2.0
//! The notifications the bytecode sends with Notify: kept in the base,
//! oldest first, for whatever takes the system's notifications - each the
//! device, processor or thermal zone it is about, held, and its value.
//! One sent while as many wait as the base has room for is counted as
//! lost, and said in the log.

const sdk = @import("sdk");
const exec = sdk.exec;
const base = @import("../acpi_base.zig");
const AcpiBase = base.AcpiBase;
const machine = @import("../machine/_machine.zig");
const namespace = @import("../namespace/_namespace.zig");
const Node = namespace.Node;
const interpreter = @import("_interpreter.zig");
const Run = interpreter.Run;
const Place = interpreter.Place;
const Error = interpreter.Error;

/// A notification taken: what it is about, held by the taker, and its
/// value.
pub const Notice = struct {
    node: *Node,
    value: u32,
};

/// Notify: `value` about what `place` names, kept.
pub fn queue(run: *Run, place: Place, value: u64) Error!void {
    const node: *Node = switch (place) {
        .node => |node| namespace.target(node),
        .reference => |held| switch (held.value.reference) {
            .node => |node| namespace.target(node),
            else => return error.Type,
        },
        else => return error.Type,
    };
    switch (node.kind()) {
        .device, .processor, .thermal_zone => {},
        else => return error.Type,
    }
    const ab = run.ab;
    var text: [namespace.PATH_ROOM]u8 = undefined;
    _ = namespace.pathOf(node, &text);
    const notices = &ab.notices;
    if (notices.count == base.MOST_NOTICES) {
        notices.lost += 1;
        machine.log(ab, exec.LOG_WARNING, "Notify (%s, 0x%lx) lost: too many wait\n", .{ @as([*:0]const u8, @ptrCast(&text)), value });
        return;
    }
    machine.log(ab, exec.LOG_DEBUG, "Notify (%s, 0x%lx)\n", .{ @as([*:0]const u8, @ptrCast(&text)), value });
    const at = (notices.first + notices.count) % base.MOST_NOTICES;
    notices.nodes[at] = namespace.hold(node);
    notices.values[at] = @truncate(value);
    notices.count += 1;
}

/// The oldest notification, taken; null where none waits.
pub fn take(ab: *AcpiBase) ?Notice {
    const notices = &ab.notices;
    if (notices.count == 0) return null;
    const at = notices.first;
    const taken: Notice = .{ .node = notices.nodes[at].?, .value = notices.values[at] };
    notices.nodes[at] = null;
    notices.first = (at + 1) % base.MOST_NOTICES;
    notices.count -= 1;
    return taken;
}

/// Every notification waiting let go of.
pub fn forget(ab: *AcpiBase) void {
    while (take(ab)) |taken| namespace.unhold(ab, taken.node);
}
