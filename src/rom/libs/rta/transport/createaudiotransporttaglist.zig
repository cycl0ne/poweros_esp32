// SPDX-License-Identifier: MPL-2.0
//! CreateAudioTransportTagList: A line from that driver, set up by the
//! tags.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const RtaBase = @import("../rta.zig").RtaBase;
const err = rta.errors;
const tags = rta.tags;
const registry = @import("../driver/_driver.zig");
const Private = @import("_transport.zig").Private;

/// Makes a line from a driver, for a sink to play through.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateAudioTransportTagList(rb: *RtaBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) ?*rta.AudioTransport
/// ```
///
/// SINCE: 1.0. LVO -84.
///
/// INPUTS:
/// - `driver_name` - the driver to make it with ("i2s").
/// - `tag_list` - the `RTAA_` options - its name, data for the caller,
///   `RTAA_ErrorPtr` for the reason if it fails - and the part's `PART_`
///   tags, whose pads the line drives.
///
/// RESULT:
/// The line, or null. `RtaLastError` - and `RTAA_ErrorPtr`, if given -
/// then says why: `RTAERR_NO_DRIVER`, `RTAERR_NO_MEMORY`, or what the
/// driver answered - `RTAERR_BAD_TAGS` for a part whose lines are not
/// pads of the chip.
///
/// BEHAVIOR:
/// A part fed over I2S is two drivers: one for the line and one for the
/// part, whose sink names the line with `RTAA_Transport` when it is made.
/// Nothing is touched until the sink starts it.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the sink list, and if the
///   driver does.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `DeleteAudioTransport`. The driver is held
/// meanwhile.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeleteAudioTransport`, `CreateSinkTagList`, `StartAudioTransport`
///
/// EXAMPLES:
/// ```zig
/// const io = rb.CreateAudioTransportTagList("i2s", part.tags) orelse return;
/// ```
pub fn CreateAudioTransportTagList(rb: *RtaBase, driver_name: [*:0]const u8, tag_list: ?[*]const TagItem) ?*rta.AudioTransport {
    const sys = rb.sys_base;
    const ub = rb.utility_base;
    const error_ptr: ?*i32 = @ptrFromInt(ub.GetTagData(tags.RTAA_ErrorPtr, 0, tag_list));

    const driver = registry.findDriverOfType(rb, driver_name, rta.sinks.RTADT_TRANSPORT) orelse {
        registry.fail(rb, err.RTAERR_NO_DRIVER, error_ptr);
        return null;
    };
    const create = driver.ops.?.create_transport orelse {
        registry.fail(rb, err.RTAERR_NO_DRIVER, error_ptr);
        return null;
    };

    const where = registry.memoryFor(driver);
    const memory = sys.AllocVec(@sizeOf(Private), where) orelse {
        registry.fail(rb, err.RTAERR_NO_MEMORY, error_ptr);
        return null;
    };
    const private: *Private = @ptrCast(@alignCast(memory));
    private.* = .{};
    const io = &private.io;
    io.node.type = .unknown;
    io.rta_base = @ptrCast(rb);
    io.driver = driver;
    io.user_data = @ptrFromInt(ub.GetTagData(tags.RTAA_UserData, 0, tag_list));
    registry.setName(rb, &private.name_buf, driver_name, @ptrFromInt(ub.GetTagData(tags.RTAA_Name, 0, tag_list)), rb.serial);
    io.node.name = @ptrCast(&private.name_buf);

    if (driver.instance_size != 0) {
        io.instance = sys.AllocVec(driver.instance_size, where) orelse {
            sys.FreeVec(memory);
            registry.fail(rb, err.RTAERR_NO_MEMORY, error_ptr);
            return null;
        };
        io.instance_size = driver.instance_size;
    }

    const code = create(driver, io, tag_list);
    if (code != err.RTAERR_OK) {
        if (io.instance) |instance| sys.FreeVec(instance);
        sys.FreeVec(memory);
        registry.fail(rb, code, error_ptr);
        return null;
    }

    driver.open_cnt += 1;
    sys.ObtainSemaphore(&rb.sink_lock);
    sys.AddTail(&rb.transports, &io.node);
    rb.serial += 1;
    sys.ReleaseSemaphore(&rb.sink_lock);

    rb.last_error = err.RTAERR_OK;
    if (error_ptr) |p| p.* = err.RTAERR_OK;
    return io;
}
