// SPDX-License-Identifier: MPL-2.0
//! A bus that exists only for the host tests: the transport driver whose
//! table names the bus a device of the test board's kind says it sits on
//! (`fakeboard.zig`).
//!
//! It is a description like any transport driver's, put on the library's
//! list by a test (`add`), and it makes a bus when the library asks it to
//! (`OpenTransport`). It sends nothing: every transfer is recorded in the
//! bus's own instance, which the library allocates beside the handle, and
//! answered with what a test said, so a test sees what crossed the bus
//! and what the library made of the answer.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const err = rtg.errors;
const RtgDriverBase = sdk.interface.rtgdriver.RtgDriverBase;
const board = @import("fakeboard.zig");

pub const DRIVER_NAME = "fakebus";

/// What the driver has that changes: the library allocates it behind the
/// driver's node, and `add` fills it in.
pub const State = struct {
    /// The driver's node, as the library made it.
    driver: *rtg.RtgDriver,
    /// Buses made and given back.
    created: u32 = 0,
    destroyed: u32 = 0,
    /// Refuse the next bus asked for with this, or RTGERR_OK to make it.
    create_answer: i32 = err.RTGERR_OK,
    /// The tags the last bus was made from: its device's.
    last_tags: ?[*]const TagItem = null,
};

/// What one bus keeps: what crossed it last.
pub const Instance = struct {
    sends: u32 = 0,
    colors: u32 = 0,
    reads: u32 = 0,
    last_cmd: i32 = 0,
    last_size: u32 = 0,
    /// What the next transfer answers.
    answer: i32 = err.RTGERR_OK,
};

pub fn stateOf(driver: *rtg.RtgDriver) *State {
    return @ptrCast(@alignCast(driver.state.?));
}

/// The bus's own record, for a test to read what crossed it.
///
/// INPUTS:
/// - `io` - a bus of this driver.
pub fn instanceOf(io: *rtg.RtgTransport) *Instance {
    return @ptrCast(@alignCast(io.instance.?));
}

fn createTransport(driver: *rtg.RtgDriver, io: *rtg.RtgTransport, tag_list: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(driver);
    if (state.create_answer != err.RTGERR_OK) return state.create_answer;
    state.created += 1;
    state.last_tags = tag_list;
    instanceOf(io).* = .{};
    io.ops = &ops;
    return err.RTGERR_OK;
}

fn destroy(io: *rtg.RtgTransport) callconv(.c) void {
    const driver: *rtg.RtgDriver = @ptrCast(@alignCast(io.driver.?));
    stateOf(driver).destroyed += 1;
}

fn txParam(io: *rtg.RtgTransport, cmd: i32, _: ?*const anyopaque, size: u32) callconv(.c) i32 {
    const instance = instanceOf(io);
    instance.sends += 1;
    instance.last_cmd = cmd;
    instance.last_size = size;
    return instance.answer;
}

fn txColor(io: *rtg.RtgTransport, cmd: i32, _: ?*const anyopaque, size: u32) callconv(.c) i32 {
    const instance = instanceOf(io);
    instance.colors += 1;
    instance.last_cmd = cmd;
    instance.last_size = size;
    return instance.answer;
}

fn rxParam(io: *rtg.RtgTransport, cmd: i32, buffer: ?*anyopaque, size: u32) callconv(.c) i32 {
    const instance = instanceOf(io);
    instance.reads += 1;
    instance.last_cmd = cmd;
    instance.last_size = size;
    // What a part would say of itself: the command, in every byte.
    if (buffer) |into| @memset(@as([*]u8, @ptrCast(into))[0..size], @truncate(@as(u32, @bitCast(cmd))));
    return instance.answer;
}

const ops = rtg.RtgTransportOps{
    .destroy = &destroy,
    .tx_param = &txParam,
    .tx_color = &txColor,
    .rx_param = &rxParam,
};

const driver_ops = rtg.RtgDriverOps{ .create_transport = &createTransport };

/// What it makes the bus of: a device on the test board's bus.
const matches = [_]rtg.RtgMatch{
    .{ .fields = rtg.drivers.RTGMATCH_BUS, .bus = board.bus },
    .{},
};

/// The driver's description, as a real transport driver's ROM tag holds
/// one.
pub const spec = rtg.RtgDriverSpec{
    .name = DRIVER_NAME,
    .id_string = "fake bus 1.0",
    .version = 1,
    .kind = rtg.drivers.RTGDT_TRANSPORT,
    .matches = &matches,
    .ops = &driver_ops,
    .state_size = @sizeOf(State),
    .instance_size = @sizeOf(Instance),
};

/// The driver put on rtg.library's list, for a test. Null without memory,
/// or when the library has a driver of this name already.
///
/// INPUTS:
/// - `library` - rtg.library's base, as `OpenLibrary` answers it.
pub fn add(library: *anyopaque) ?*State {
    const rb: *RtgDriverBase = @ptrCast(library);
    const driver = rb.AddRtgDriver(&spec, null) orelse return null;
    const state = stateOf(driver);
    state.* = .{ .driver = driver };
    return state;
}

/// The driver `add` put on the list taken off it again. False while a bus
/// of it is still open.
///
/// INPUTS:
/// - `state` - what `add` answered.
pub fn remove(state: *State) bool {
    return state.driver.rtg_base.RemRtgDriver(state.driver);
}
