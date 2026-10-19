// SPDX-License-Identifier: MPL-2.0
//! CreateSinkTagList: A sink from that driver, set up by the tags.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const RtaBase = @import("../rta.zig").RtaBase;
const err = rta.errors;
const registry = @import("../driver/_driver.zig");
const _sink = @import("_sink.zig");
const Private = _sink.Private;

/// Makes a sink from a driver.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateSinkTagList(rb: *RtaBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) ?*rta.AudioSink
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `driver_name` - the driver to make it with.
/// - `tag_list` - the `RTAA_` options - the sink's name, its priority, the
///   line its part is fed over, data for the caller, and `RTAA_ErrorPtr`
///   for the reason if it fails - and the part's own `PART_` tags, which
///   the driver reads.
///
/// RESULT:
/// The sink, or null. `RtaLastError` - and `RTAA_ErrorPtr`, if given -
/// then says why: `RTAERR_NO_DRIVER`, `RTAERR_NO_MEMORY`,
/// `RTAERR_BAD_MODE` for a driver that gave it no mode, or what the
/// driver answered.
///
/// BEHAVIOR:
/// The sink's handle and the driver's instance come from memory the
/// driver can read from its interrupts when it asks for that. The driver
/// fills the handle in: its operations, its modes and the ring it runs
/// on. The sink comes up in the mode its driver marked the default and is
/// not started; nothing of the part is touched until `StartSink`. It goes
/// on the list by `RTAA_Priority`, so the first on the list is the output
/// most wanted. Without `RTAA_Name` it is named after the driver and a
/// number: null0.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the sink list, and if the
///   driver does.
/// - Interrupts: no.
/// - Locks: no spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The sink is the caller's until `DeleteSink`. The driver and a line it
/// names are held meanwhile.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeleteSink`, `StartSink`, `NextSink`
///
/// EXAMPLES:
/// ```zig
/// const named = [_]TagItem{ .{ .tag = rta.tags.RTAA_Priority, .data = @bitCast(@as(isize, -100)) }, .{} };
/// const sink = rb.CreateSinkTagList("null", &named) orelse return null;
/// ```
pub fn CreateSinkTagList(rb: *RtaBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) ?*rta.AudioSink {
    const sys = rb.sys_base;
    const request = _sink.readRequest(rb, tag_list);

    const driver = registry.findDriverOfType(rb, driver_name, rta.sinks.RTADT_SINK) orelse {
        registry.fail(rb, err.RTAERR_NO_DRIVER, request.error_ptr);
        return null;
    };
    const create = driver.ops.?.create_sink orelse {
        registry.fail(rb, err.RTAERR_NO_DRIVER, request.error_ptr);
        return null;
    };

    const where = registry.memoryFor(driver);
    const memory = sys.AllocVec(@sizeOf(Private), where) orelse {
        registry.fail(rb, err.RTAERR_NO_MEMORY, request.error_ptr);
        return null;
    };
    const private: *Private = @ptrCast(@alignCast(memory));
    private.* = .{};
    const sink = &private.sink;
    sink.node.type = .unknown;
    sink.node.pri = request.priority;
    sink.rta_base = @ptrCast(rb);
    sink.driver = driver;
    sink.transport = request.transport;
    sink.user_data = request.user_data;
    registry.setName(rb, &private.name_buf, driver_name, request.name, rb.serial);
    sink.node.name = @ptrCast(&private.name_buf);
    sys.NewList(&sink.modes);

    if (driver.instance_size != 0) {
        sink.instance = sys.AllocVec(driver.instance_size, where) orelse {
            sys.FreeVec(memory);
            registry.fail(rb, err.RTAERR_NO_MEMORY, request.error_ptr);
            return null;
        };
        sink.instance_size = driver.instance_size;
    }

    var code = create(driver, sink, tag_list);
    if (code == err.RTAERR_OK) {
        // A sink with no mode could never be started.
        if (_sink.defaultMode(sink)) |mode| {
            mode.flags |= rta.sinks.AUDIOMF_CURRENT;
            sink.mode = mode;
        } else {
            if (sink.ops) |ops| {
                if (ops.destroy) |destroy| destroy(sink);
            }
            code = err.RTAERR_BAD_MODE;
        }
    }
    if (code != err.RTAERR_OK) {
        if (sink.instance) |instance| sys.FreeVec(instance);
        sys.FreeVec(memory);
        registry.fail(rb, code, request.error_ptr);
        return null;
    }

    if (request.transport) |io| io.open_cnt += 1;
    driver.open_cnt += 1;

    sys.ObtainSemaphore(&rb.sink_lock);
    sys.Enqueue(&rb.sinks, &sink.node);
    rb.serial += 1;
    sys.ReleaseSemaphore(&rb.sink_lock);

    rb.last_error = err.RTAERR_OK;
    if (request.error_ptr) |p| p.* = err.RTAERR_OK;
    return sink;
}
