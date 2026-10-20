// SPDX-License-Identifier: MPL-2.0
//! CreateSourceTagList: A source from that driver, set up by the tags.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const RtaBase = @import("../rta.zig").RtaBase;
const err = rta.errors;
const registry = @import("../driver/_driver.zig");
const _sink = @import("../sink/_sink.zig");
const _source = @import("_source.zig");
const Private = _source.Private;

/// Makes a source from a driver.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateSourceTagList(rb: *RtaBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) ?*rta.AudioSource
/// ```
///
/// SINCE: 1.3. LVO -128.
///
/// INPUTS:
/// - `driver_name` - the driver to make it with.
/// - `tag_list` - the `RTAA_` options - the source's name, its priority,
///   the line its part is read over, data for the caller, and
///   `RTAA_ErrorPtr` for the reason if it fails - and the part's own
///   `PART_` tags, which the driver reads.
///
/// RESULT:
/// The source, or null. `RtaLastError` - and `RTAA_ErrorPtr`, if given -
/// then says why: `RTAERR_NO_DRIVER`, `RTAERR_NO_MEMORY`,
/// `RTAERR_BAD_MODE` for a driver that gave it no mode, or what the
/// driver answered.
///
/// BEHAVIOR:
/// As `CreateSinkTagList`, for a way in: the driver fills the handle in -
/// its operations, its modes and the ring it runs on - and nothing of the
/// part is touched until `StartSource`. Its `mode` is the one its driver
/// marked the default. It goes on the list of sources by `RTAA_Priority`,
/// so the first is the way in most wanted. Without `RTAA_Name` it is
/// named after the driver and a number. Its number (`AudioSource.id`) is
/// worked out from its driver's name and its own, the same from one boot
/// to the next, and no two sources share one.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the list, and if the driver
///   does.
/// - Interrupts: no.
/// - Locks: no spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The source is the caller's until `DeleteSource`. The driver and a line
/// it names are held meanwhile.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeleteSource`, `StartSource`, `NextSource`, `CreateSinkTagList`
///
/// EXAMPLES:
/// ```zig
/// const on_line = [_]TagItem{ .{ .tag = rta.tags.RTAA_Transport, .data = @intFromPtr(io) }, .{} };
/// const source = rb.CreateSourceTagList("es8311", &on_line) orelse return;
/// ```
pub fn CreateSourceTagList(rb: *RtaBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) ?*rta.AudioSource {
    const sys = rb.sys_base;
    const request = _sink.readRequest(rb, tag_list);

    const driver = registry.findDriverOfType(rb, driver_name, rta.sinks.RTADT_SOURCE) orelse {
        registry.fail(rb, err.RTAERR_NO_DRIVER, request.error_ptr);
        return null;
    };
    const create = driver.ops.?.create_source orelse {
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
    const source = &private.source;
    source.node.type = .unknown;
    source.node.pri = request.priority;
    source.rta_base = @ptrCast(rb);
    source.driver = driver;
    source.transport = request.transport;
    source.user_data = request.user_data;
    registry.setName(rb, &private.name_buf, driver_name, request.name, rb.serial);
    source.node.name = @ptrCast(&private.name_buf);
    sys.NewList(&source.modes);

    if (driver.instance_size != 0) {
        source.instance = sys.AllocVec(driver.instance_size, where) orelse {
            sys.FreeVec(memory);
            registry.fail(rb, err.RTAERR_NO_MEMORY, request.error_ptr);
            return null;
        };
        source.instance_size = driver.instance_size;
    }

    var code = create(driver, source, tag_list);
    if (code == err.RTAERR_OK) {
        // A source with no mode could never be started.
        if (_source.defaultMode(source)) |mode| {
            mode.flags |= rta.sinks.AUDIOMF_CURRENT;
            source.mode = mode;
        } else {
            if (source.ops) |ops| {
                if (ops.destroy) |destroy| destroy(source);
            }
            code = err.RTAERR_BAD_MODE;
        }
    }
    if (code != err.RTAERR_OK) {
        if (source.instance) |instance| sys.FreeVec(instance);
        sys.FreeVec(memory);
        registry.fail(rb, code, request.error_ptr);
        return null;
    }

    if (request.transport) |io| io.open_cnt += 1;
    driver.open_cnt += 1;

    sys.ObtainSemaphore(&rb.sink_lock);
    source.id = _source.idFor(rb, driver.node.name orelse driver_name, source.node.name.?);
    sys.Enqueue(&rb.sources, &source.node);
    rb.serial += 1;
    sys.ReleaseSemaphore(&rb.sink_lock);

    rb.last_error = err.RTAERR_OK;
    if (request.error_ptr) |p| p.* = err.RTAERR_OK;
    return source;
}
