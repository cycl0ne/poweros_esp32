// SPDX-License-Identifier: MPL-2.0
//! A board that exists only for the host tests.
//!
//! It is written the way a real driver is written, because it is what
//! anyone writing one will read: nothing is kept in the module's own
//! image. The driver is its description, `spec`; the library allocates
//! the driver's `State` behind the node it makes for it, and every entry
//! point finds that state again through the node - an op has the board,
//! the board has its driver's node, and the node has the state. What
//! belongs to one board and not to the driver - the bands it shows - is
//! in the instance the library allocates beside each handle. Its modes
//! it adds to each board as it makes it (`AddBoardMode`), and the library
//! keeps them.
//!
//! A real driver's description is behind a ROM tag, and the library puts
//! it on its list. This one is put there by a test (`add`), which also
//! takes the display memory its boards are cut out of. Its devices are
//! none the library can find: a test adds one (`addDevice`), and the
//! driver, offered it, makes a board of it - or several, or declines, or
//! opens the device's bus first, as the test told it.
//!
//! Its engine really does fill and copy, so a test can compare
//! bytes and see both that the work happened and that the rectangle it was
//! given had already been cut down to the buffer. Everything it is asked
//! is recorded, so a test can also see what it was *not* asked.
//!
//! It keeps the bands it shows and the mode it was put in, as a display
//! does, and a test can make its next show fail: what a refusal leaves
//! can then be read on the board as well as in the library.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const err = rtg.errors;
const st = sdk.expansion.systemtags;
const RtgDriverBase = sdk.interface.rtgdriver.RtgDriverBase;

pub const DRIVER_NAME = "fake";

/// The chip a device of the test board's kind says it is, and the bus it
/// says it sits on: numbers no board's list has.
pub const chip: u32 = 0x7E57_0001;
pub const bus: u32 = 0x7E57_0002;

/// The most devices and boards one test has of this driver.
pub const max_devices = 4;
pub const max_boards = 8;

/// The display memory it reports. Small on purpose: the host tests run
/// exec on 80 KiB of test RAM and everything else has to fit beside it.
pub const region_bytes: usize = 16 * 1024;
/// How much of it a display that was already running is using, when the
/// board is made to come up that way.
pub const claimed_bytes: usize = 4096;
/// What the driver writes into its instance, so a test can see that the
/// library gave it its own memory and handed the same pointer back.
pub const instance_pattern: u32 = 0x5A5A_1234;

/// What the board was asked to do.
pub const Log = struct {
    created: u32 = 0,
    destroyed: u32 = 0,
    /// Devices offered, and devices taken away again (`detach`).
    offered: u32 = 0,
    detached: u32 = 0,
    /// Shows the board was asked for, and those of them that came with
    /// the mode to be set anew.
    set_mode: u32 = 0,
    shown: u32 = 0,
    refreshed: u32 = 0,
    display_calls: u32 = 0,
    brightness_calls: u32 = 0,
    control_calls: u32 = 0,
    fills: u32 = 0,
    copies: u32 = 0,
    /// Copies asked for together (`copy_rects`): how many calls, and how
    /// many rectangles the last had. Each rectangle counts in `copies`
    /// as well.
    copy_jobs: u32 = 0,
    last_copy_count: u32 = 0,
    mirrors: u32 = 0,
    /// The rectangle of the last fill, as the driver got it.
    last_rect: rtg.RtgRect = .{},
    last_copy: rtg.RtgCopy = .{},
    /// The last band's buffer and the flags, as the last show was handed
    /// them - refused or not.
    last_show_bitmap: ?*rtg.RtgBitMap = null,
    last_flags: u32 = 0,
    last_refresh_y: u32 = 0,
    last_refresh_rows: u32 = 0,
    last_control: u32 = 0,
    last_mirror_x: bool = false,
    last_mirror_y: bool = false,
    /// The mode and the timings the board was last put in, as the driver
    /// got them.
    last_mode: rtg.RtgMode = .{},
    last_timings: rtg.RtgTimings = .{},
    display_on: bool = false,
    brightness: u32 = 0,
    /// The pointer as the board has it: the image it was last given,
    /// where that image's top left is, and whether it is laid over the
    /// picture.
    pointer_sets: u32 = 0,
    pointer_moves: u32 = 0,
    pointer_image: ?*const rtg.RtgPointerImage = null,
    pointer_left: i32 = 0,
    pointer_top: i32 = 0,
    pointer_shown: bool = false,
    /// The overlay the same way: the image last given and its top left.
    overlay_sets: u32 = 0,
    overlay_moves: u32 = 0,
    overlay_image: ?*const rtg.RtgPointerImage = null,
    overlay_left: i32 = 0,
    overlay_top: i32 = 0,
    /// The bands of the last show, as the driver got them - refused or
    /// not.
    bands: [rtg.RTG_MAX_BANDS]rtg.RtgBand = undefined,
    band_count: u32 = 0,
    /// Pixels and colours laid over a buffer: how often, and the last
    /// rectangle, pixels, alpha or colour and scaled size as the driver
    /// got them.
    blends: u32 = 0,
    blend_rects: u32 = 0,
    scales: u32 = 0,
    last_pixels: rtg.RtgPixels = .{},
    last_alpha: u32 = 0,
    last_color: u32 = 0,
    last_scale_width: u32 = 0,
    last_scale_height: u32 = 0,
    /// The video layer: whether it is taken, how often it was opened,
    /// closed, shown a picture and moved, and the last picture, part and
    /// place as the driver got them.
    video_taken: bool = false,
    video_opens: u32 = 0,
    video_closes: u32 = 0,
    video_shows: u32 = 0,
    video_moves: u32 = 0,
    video_picture: ?*const rtg.RtgYuv = null,
    video_src: rtg.RtgRect = .{},
    video_place: rtg.RtgRect = .{},
    /// How often its connector was asked what is on it (`detect`), and how
    /// many timings it was asked whether it can make (`check_mode`).
    detects: u32 = 0,
    checks: u32 = 0,
    /// Frames the board was told to end (`endFrame`).
    frames_ended: u32 = 0,
    /// Waits for a blanking the driver was asked for itself (`waitVBlank`),
    /// and the count the last came with.
    vblank_waits: u32 = 0,
    last_wait_frames: u32 = 0,
};

/// Everything this driver has that changes: the library allocates it
/// behind the driver's node, and `add` fills it in.
pub const State = struct {
    /// The driver's node, as the library made it.
    driver: *rtg.RtgDriver,
    sys: *ExecBase,
    /// The display memory its boards are cut out of, and how much of it
    /// there is.
    region: [*]u8,
    region_bytes: usize = region_bytes,
    log: Log = .{},
    /// The devices `addDevice` added, to be taken away again.
    devices: [max_devices]?*rtg.RtgDevice = @splat(null),
    device_count: u32 = 0,
    /// The boards it made, in the order they were made: one that was
    /// deleted leaves its place empty.
    boards: [max_boards]?*rtg.RtgBoard = @splat(null),
    made: u32 = 0,

    // What a test makes the board do.

    /// Decline the next device offered with this, or RTGERR_OK to take
    /// it.
    create_answer: i32 = err.RTGERR_OK,
    /// How many boards it makes of the next device it takes: its outputs.
    outputs: u32 = 1,
    /// How many of its modes the next board made is given, from the first:
    /// all of them, unless a test says fewer - one is a panel's board.
    modes: u32 = mode_table.len,
    /// The one mode the next board made is given in their place
    /// (`makeDisplay`); null for the table's.
    display: ?ModeOf = null,
    /// Make the next board one with a connector: its ops fill in `detect`
    /// and `check_mode`, and its modes are what the monitor on it names.
    connector: bool = false,
    /// What is on the connector of every such board: whether a monitor
    /// is, the bytes of its EDID - null for one that does not read - and
    /// what `detect` answers.
    monitor_there: bool = true,
    monitor_edid: ?[]const u8 = null,
    detect_answer: i32 = err.RTGERR_OK,
    /// The fastest pixel clock a board with a connector makes, in Hz: a
    /// timing past it is refused.
    fastest_hz: u32 = 0xFFFF_FFFF,
    /// Open the device's bus before it makes a board, as the driver of a
    /// panel on a bus does, and decline when there is none.
    opens_bus: bool = false,
    /// Leave the engine's slots empty, as a board with no engine has them.
    without_engine: bool = false,
    /// Refuse to turn the picture, as a board whose pixels go out in the
    /// order they are written does.
    cannot_turn: bool = false,
    /// Come up with a display already running out of the front of the
    /// region, the way a driver that took over a running one does.
    claims_display: bool = false,
    /// Open the video layer over the picture whatever is asked, as a
    /// board that cannot lay its picture over a layer does.
    video_over_only: bool = false,
    /// What the driver's own wait for a blanking answers (`waitVBlank`).
    wait_answer: i32 = err.RTGERR_OK,
    /// Make the next show - of a buffer, of bands or of nothing - fail
    /// with this: the board goes on showing what it showed. It holds for
    /// `show_refusals` shows running, and the show after them works.
    /// RTGERR_OK lets it work.
    show_answer: i32 = err.RTGERR_OK,
    /// How many shows running `show_answer` refuses: one, unless a test
    /// says more. Back at one when they are spent.
    show_refusals: u32 = 1,
    /// How much display memory the next board made reports: all of it,
    /// unless a test says less - none is a board with no display memory.
    region_size: usize = region_bytes,
    /// Called with the board at the start of every op that changes what
    /// the board shows or the mode it is in, for a test that looks at
    /// what the library holds while the driver works.
    meanwhile: ?*const fn (board: *rtg.RtgBoard) void = null,
};

/// What belongs to one board: the library allocates it beside the handle.
pub const Instance = struct {
    pattern: u32 = 0,
    calls: u32 = 0,
    /// The bus the board's device sits on, when the driver opened it.
    bus: ?*rtg.RtgTransport = null,
    /// What the board shows: its bands from the top - one from line 0 for
    /// a buffer shown alone, none while nothing is shown. Kept once a show
    /// can no longer fail: a show that was refused left them as they
    /// were. And the number of the mode it was last put in.
    showing: [rtg.RTG_MAX_BANDS]rtg.RtgBand = undefined,
    showing_count: u32 = 0,
    mode_id: u32 = 0,
};

pub fn stateOf(driver: *rtg.RtgDriver) *State {
    return @ptrCast(@alignCast(driver.state.?));
}

fn stateOfBoard(board: *rtg.RtgBoard) *State {
    return stateOf(board.driver.?);
}

/// The board's own record, for a test to read what it shows.
///
/// INPUTS:
/// - `board` - a board of this driver.
pub fn instanceOf(board: *rtg.RtgBoard) *Instance {
    return @ptrCast(@alignCast(board.instance.?));
}

/// What it takes: a device of its own chip, which no board's list has.
const matches = [_]rtg.RtgMatch{
    .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = chip },
    .{},
};

/// The driver's description, as a real driver's ROM tag holds one.
pub const spec = rtg.RtgDriverSpec{
    .name = DRIVER_NAME,
    .id_string = "fake board 1.0",
    .version = 1,
    .kind = rtg.drivers.RTGDT_BOARD,
    .matches = &matches,
    .ops = &driver_ops,
    .state_size = @sizeOf(State),
};

/// A device of the test board's kind, as tags say it. Its bus is the
/// test bus's (`fakebus.zig`).
const device_tag_list = [_]sdk.utility.FixedTagItem{
    .value(st.PART_Chip, chip),
    .pointer(st.PART_ChipName, "fake display"),
    .value(st.PART_Bus, bus),
    .done,
};

/// The tags of a device of the test board's kind: what `AddRtgDevice` is
/// handed, and what a test's own list ends in with a TAG_MORE.
pub fn deviceTags() [*]const TagItem {
    return @ptrCast(&device_tag_list);
}

/// The driver put on rtg.library's list, for a test: its description
/// handed to AddRtgDriver, the display memory its boards are cut out of
/// taken, and its state filled in. Null without memory, or when the
/// library has a driver of this name already.
///
/// INPUTS:
/// - `sys` - exec.
/// - `library` - rtg.library's base, as `OpenLibrary` answers it.
pub fn add(sys: *ExecBase, library: *anyopaque) ?*State {
    return addSized(sys, library, region_bytes);
}

/// As `add`, with `bytes` of display memory for its boards in place of
/// `region_bytes`: for a test whose own memory is small and whose
/// pictures are.
///
/// INPUTS:
/// - `sys` - exec.
/// - `library` - rtg.library's base, as `OpenLibrary` answers it.
/// - `bytes` - how much display memory the driver takes.
pub fn addSized(sys: *ExecBase, library: *anyopaque, bytes: usize) ?*State {
    const rb: *RtgDriverBase = @ptrCast(library);
    const region = sys.AllocMem(bytes, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const driver = rb.AddRtgDriver(&spec, null) orelse {
        sys.FreeMem(region, bytes);
        return null;
    };
    const state = stateOf(driver);
    state.* = .{ .driver = driver, .sys = sys, .region = @ptrCast(region), .region_bytes = bytes, .region_size = bytes };
    return state;
}

/// A device put on the library's list and offered - one of the test
/// board's kind, which this driver takes unless a test has told it to
/// decline. Null without memory, and with `max_devices` of them there.
///
/// INPUTS:
/// - `state` - what `add` answered.
/// - `tag_list` - what the device is; null for `deviceTags()`. A test's
///   own list says more and ends in a TAG_MORE to those, or names another
///   chip. It is read until the driver is removed.
pub fn addDevice(state: *State, tag_list: ?[*]const TagItem) ?*rtg.RtgDevice {
    if (state.device_count == max_devices) return null;
    const device = state.driver.rtg_base.AddRtgDevice(tag_list orelse deviceTags()) orelse return null;
    state.devices[state.device_count] = device;
    state.device_count += 1;
    return device;
}

/// A device of the test board's kind added, and the first board the
/// driver made of it: what a test of a module above rtg.library draws
/// on. Null without memory, and when the driver declined.
///
/// INPUTS:
/// - `state` - what `add` answered.
pub fn makeBoard(state: *State) ?*rtg.RtgBoard {
    return makeBoardFrom(state, null);
}

/// A device of the test board's kind added, and the board made of it
/// with one mode, of that size in that format: the display a test of a
/// module above rtg.library opens its screens on, which is in that mode
/// once a buffer of the size is shown on it. Null as `makeBoard`.
///
/// INPUTS:
/// - `state` - what `add` answered.
/// - `width`, `height` - the display's size.
/// - `format` - the pixel format it shows.
pub fn makeDisplay(state: *State, width: u32, height: u32, format: rtg.PixelFormat) ?*rtg.RtgBoard {
    state.display = .{ .timings = .{ .h_active = width, .v_active = height }, .format = format, .flags = rtg.modes.RTGMF_DEFAULT };
    defer state.display = null;
    return makeBoard(state);
}

/// As `makeBoard`, from a device of the test's own tags.
///
/// INPUTS:
/// - `state` - what `add` answered.
/// - `tag_list` - what the device is, as `addDevice` takes it.
pub fn makeBoardFrom(state: *State, tag_list: ?[*]const TagItem) ?*rtg.RtgBoard {
    const before = state.made;
    _ = addDevice(state, tag_list) orelse return null;
    if (state.made == before) return null;
    return state.boards[before];
}

/// The driver `add` put on the list taken off it again, with all it has:
/// its boards deleted, its devices taken away, and its display memory
/// given back. False, and the driver still on the list, while a board
/// cannot go - an event server or a video layer is still on it.
///
/// INPUTS:
/// - `state` - what `add` answered.
pub fn remove(state: *State) bool {
    const sys = state.sys;
    const rb = state.driver.rtg_base;
    const region = state.region;
    const bytes = state.region_bytes;
    // A driver being removed deletes its boards; `destroyBoard` clears
    // the place of each that went.
    for (state.boards[0..state.made]) |made| rb.DeleteBoard(made);
    for (state.devices[0..state.device_count]) |device| rb.RemRtgDevice(device);
    state.device_count = 0;
    // The state goes with the node.
    if (!rb.RemRtgDriver(state.driver)) return false;
    sys.FreeMem(@ptrCast(region), bytes);
    return true;
}

/// A frame of `board` ends, as a real board's frame interrupt says it:
/// the blanking is signalled to whoever waits for one. The board sends no
/// frames of its own, so a test says when one ends.
///
/// INPUTS:
/// - `board` - the board whose frame ends.
pub fn endFrame(board: *rtg.RtgBoard) void {
    stateOfBoard(board).log.frames_ended += 1;
    const rb: *RtgDriverBase = @ptrCast(board.rtg_base.?);
    _ = rb.SignalRtgEvent(board, rtg.events.RTGEV_VBLANK);
}

/// A mode a board of this driver has: its timings, its format, and
/// whether the board comes up in it.
const ModeOf = struct { timings: rtg.RtgTimings, format: rtg.PixelFormat, flags: u32 = 0 };

/// The modes every board of it is given, in this order - so the first is
/// number 1: 320x200 and 640x480 at 60 frames a second exactly, and a
/// picture of two colours on a display with no clock.
pub const mode_table = [_]ModeOf{
    .{
        .timings = .{ .pixel_clock_hz = 6_000_000, .h_active = 320, .h_front = 16, .h_sync = 32, .h_back = 32, .v_active = 200, .v_front = 10, .v_sync = 10, .v_back = 30 },
        .format = .rgb565,
        .flags = rtg.modes.RTGMF_DEFAULT,
    },
    .{
        .timings = .{ .pixel_clock_hz = 25_200_000, .h_active = 640, .h_front = 16, .h_sync = 96, .h_back = 48, .v_active = 480, .v_front = 10, .v_sync = 2, .v_back = 33 },
        .format = .rgb565,
    },
    .{
        .timings = .{ .h_active = 64, .v_active = 64 },
        .format = .mono1,
    },
};

// --- the ops ----------------------------------------------------------------

fn destroyBoard(board: *rtg.RtgBoard) callconv(.c) void {
    const state = stateOfBoard(board);
    instanceOf(board).calls += 1;
    state.log.destroyed += 1;
    // The bus it opened goes with the board.
    if (instanceOf(board).bus) |io| state.driver.rtg_base.CloseTransport(io);
    forget(state, board);
}

/// A board that is going leaves its place among the ones made.
fn forget(state: *State, board: *rtg.RtgBoard) void {
    for (state.boards[0..state.made]) |*made| {
        if (made.* == board) made.* = null;
    }
}

/// The device is taken from the driver.
fn detach(driver: *rtg.RtgDriver, _: *rtg.RtgDevice) callconv(.c) void {
    stateOf(driver).log.detached += 1;
}

/// The answer a test set for the next show, taken: RTGERR_OK when none
/// was set, and RTGERR_OK again once it has refused as many shows as
/// the test asked for.
///
/// INPUTS:
/// - `state` - the driver's block, whose `show_answer` is read, and put
///   back to RTGERR_OK with the last of its `show_refusals`.
fn showAnswer(state: *State) i32 {
    const answer = state.show_answer;
    if (answer == err.RTGERR_OK) return answer;
    state.show_refusals -|= 1;
    if (state.show_refusals == 0) {
        state.show_answer = err.RTGERR_OK;
        state.show_refusals = 1;
    }
    return answer;
}

/// The board's one op for what is on the glass, as a display keeps the
/// contract: what it was handed is logged, refused or not; in the mode it
/// is in, a show that is refused leaves what it showed; with the mode set
/// anew, one that is refused leaves it showing nothing; and what it shows
/// changes once nothing of the show can fail any more.
fn showOp(board: *rtg.RtgBoard, what: *const rtg.RtgShow) callconv(.c) i32 {
    const instance = instanceOf(board);
    instance.calls += 1;
    const state = stateOfBoard(board);
    if (state.meanwhile) |look| look(board);
    const log = &state.log;
    const anew = what.flags & rtg.boards.RTGSHOW_MODE_CHANGED != 0;
    log.shown += 1;
    log.last_flags = what.flags;
    log.band_count = what.count;
    if (what.bands) |bands| @memcpy(log.bands[0..what.count], bands[0..what.count]);
    log.last_show_bitmap = if (what.count != 0) log.bands[what.count - 1].bitmap else null;
    if (anew) {
        log.set_mode += 1;
        log.last_mode = what.mode.*;
        log.last_timings = what.timings.*;
    }
    const answer = showAnswer(state);
    if (answer != err.RTGERR_OK) {
        if (anew) instance.showing_count = 0;
        return answer;
    }
    if (anew) instance.mode_id = what.mode.id;
    @memcpy(instance.showing[0..what.count], log.bands[0..what.count]);
    instance.showing_count = what.count;
    return err.RTGERR_OK;
}

fn refresh(board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, y: u32, rows: u32) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    _ = bitmap;
    const log = &stateOfBoard(board).log;
    log.refreshed += 1;
    log.last_refresh_y = y;
    log.last_refresh_rows = rows;
    return err.RTGERR_OK;
}

fn display(board: *rtg.RtgBoard, on: bool) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.display_calls += 1;
    log.display_on = on;
    return err.RTGERR_OK;
}

fn setBrightness(board: *rtg.RtgBoard, percent: u32) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.brightness_calls += 1;
    log.brightness = percent;
    return err.RTGERR_OK;
}

fn brightness(board: *rtg.RtgBoard) callconv(.c) u32 {
    return stateOfBoard(board).log.brightness;
}

fn stats(board: *rtg.RtgBoard, out: *rtg.RtgBoardStats) callconv(.c) void {
    _ = board;
    out.* = .{ .frames = 42, .starved_frames = 1, .worst_gap_us = 7 };
}

fn control(board: *rtg.RtgBoard, what: u32, value: isize) callconv(.c) isize {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.control_calls += 1;
    log.last_control = what;
    return value + 1;
}

fn mirror(board: *rtg.RtgBoard, mirror_x: bool, mirror_y: bool) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.mirrors += 1;
    log.last_mirror_x = mirror_x;
    log.last_mirror_y = mirror_y;
    return err.RTGERR_OK;
}

fn setPointer(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.pointer_sets += 1;
    log.pointer_image = image;
    return err.RTGERR_OK;
}

fn movePointer(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    const log = &stateOfBoard(board).log;
    log.pointer_moves += 1;
    log.pointer_left = left;
    log.pointer_top = top;
}

fn showPointer(board: *rtg.RtgBoard, show: bool) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    stateOfBoard(board).log.pointer_shown = show;
    return err.RTGERR_OK;
}

fn setOverlay(board: *rtg.RtgBoard, image: ?*const rtg.RtgPointerImage) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.overlay_sets += 1;
    log.overlay_image = image;
    return err.RTGERR_OK;
}

fn moveOverlay(board: *rtg.RtgBoard, left: i32, top: i32) callconv(.c) void {
    const log = &stateOfBoard(board).log;
    log.overlay_moves += 1;
    log.overlay_left = left;
    log.overlay_top = top;
}

/// The one video layer: a key colour, the DC8200's limits, under the
/// picture unless the test says it cannot be. Its converter is a real
/// one's - the television matrices at eight bits, either range, and no
/// high dynamic range - so a picture it could not make colours out of
/// takes no layer.
fn videoOpen(board: *rtg.RtgBoard, layer: *rtg.RtgVideoLayer) callconv(.c) i32 {
    const state = stateOfBoard(board);
    if (layer.matrix != rtg.RTGYUV_BT601 and layer.matrix != rtg.RTGYUV_BT709) return err.RTGERR_NOT_SUPPORTED;
    if (layer.transfer != rtg.RTGYUV_SDR or layer.primaries != rtg.RTGYUV_BT709) return err.RTGERR_NOT_SUPPORTED;
    if (layer.depth != 8) return err.RTGERR_NOT_SUPPORTED;
    if (state.log.video_taken) return err.RTGERR_IN_USE;
    state.log.video_taken = true;
    state.log.video_opens += 1;
    state.log.video_place = .{};
    if (state.video_over_only) layer.flags &= ~rtg.RTGVLF_UNDER;
    layer.key = 0x0008_0008;
    layer.max_width = 4096;
    layer.max_height = 4096;
    layer.max_up = 3;
    layer.max_down = 10;
    return err.RTGERR_OK;
}

fn videoClose(board: *rtg.RtgBoard, _: *rtg.RtgVideoLayer) callconv(.c) void {
    const log = &stateOfBoard(board).log;
    log.video_taken = false;
    log.video_closes += 1;
    log.video_picture = null;
}

/// Whether `src` scales into `place` within the layer's limits, each way.
fn videoFits(layer: *const rtg.RtgVideoLayer, src: rtg.RtgRect, place: rtg.RtgRect) bool {
    if (place.width <= 0 or place.height <= 0) return true;
    const up: i64 = layer.max_up;
    const down: i64 = layer.max_down;
    return place.width <= up * src.width and src.width <= down * place.width and
        place.height <= up * src.height and src.height <= down * place.height;
}

fn videoShow(board: *rtg.RtgBoard, layer: *rtg.RtgVideoLayer, picture: ?*const rtg.RtgYuv, src: ?*const rtg.RtgRect) callconv(.c) i32 {
    const log = &stateOfBoard(board).log;
    log.video_shows += 1;
    if (src) |part| {
        if (!videoFits(layer, part.*, log.video_place)) return err.RTGERR_BAD_ARG;
        log.video_src = part.*;
    }
    log.video_picture = picture;
    return err.RTGERR_OK;
}

fn videoMove(board: *rtg.RtgBoard, layer: *rtg.RtgVideoLayer, place: *const rtg.RtgRect) callconv(.c) i32 {
    const log = &stateOfBoard(board).log;
    log.video_moves += 1;
    log.video_place = place.*;
    if (log.video_picture != null and !videoFits(layer, log.video_src, place.*)) return err.RTGERR_BAD_ARG;
    return err.RTGERR_OK;
}

/// A driver's own wait for a blanking: counted, and answered at once
/// with what the test set (`State.wait_answer`). In none of the tables
/// below - a board of this driver is waited for by the library - so a
/// test that wants a board whose driver waits itself puts it in that
/// board's table.
///
/// INPUTS:
/// - `board` - the board asked.
/// - `frames` - the count as WaitVBlank was given it, 0 included.
pub fn waitVBlank(board: *rtg.RtgBoard, frames: u32) callconv(.c) i32 {
    const state = stateOfBoard(board);
    state.log.vblank_waits += 1;
    state.log.last_wait_frames = frames;
    return state.wait_answer;
}

/// rgb565 only: what a board's engine would do, done by hand so the tests
/// can compare bytes.
fn rows16(bitmap: *rtg.RtgBitMap, y: u32) []u16 {
    const start = bitmap.rowPtr(y);
    return @as([*]u16, @ptrCast(@alignCast(start)))[0..bitmap.width];
}

fn fillRect(board: *rtg.RtgBoard, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.fills += 1;
    log.last_rect = area.*;
    if (dest.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    var y: u32 = @intCast(area.y);
    const end: u32 = @intCast(area.y + area.height);
    while (y < end) : (y += 1) {
        const row = rows16(dest, y);
        var x: u32 = @intCast(area.x);
        const right: u32 = @intCast(area.x + area.width);
        while (x < right) : (x += 1) row[x] = @truncate(color);
    }
    return err.RTGERR_OK;
}

fn copyRects(board: *rtg.RtgBoard, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copies: [*]const rtg.RtgCopy, count: u32) callconv(.c) i32 {
    const log = &stateOfBoard(board).log;
    log.copy_jobs += 1;
    log.last_copy_count = count;
    for (copies[0..count]) |*one| {
        const result = copyRect(board, src, dest, one);
        if (result != err.RTGERR_OK) return result;
    }
    return err.RTGERR_OK;
}

fn copyRect(board: *rtg.RtgBoard, src: *rtg.RtgBitMap, dest: *rtg.RtgBitMap, copy: *const rtg.RtgCopy) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.copies += 1;
    log.last_copy = copy.*;
    if (src.format != .rgb565 or dest.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    const height: u32 = @intCast(copy.height);
    const width: u32 = @intCast(copy.width);
    // Rows the way round that lets a buffer be copied onto itself.
    const downwards = copy.dest_y <= copy.src_y;
    var step: u32 = 0;
    while (step < height) : (step += 1) {
        const line = if (downwards) step else height - 1 - step;
        const from = rows16(src, @as(u32, @intCast(copy.src_y)) + line);
        const to = rows16(dest, @as(u32, @intCast(copy.dest_y)) + line);
        const src_x: u32 = @intCast(copy.src_x);
        const dest_x: u32 = @intCast(copy.dest_x);
        if (copy.dest_x <= copy.src_x) {
            var x: u32 = 0;
            while (x < width) : (x += 1) to[dest_x + x] = from[src_x + x];
        } else {
            var x: u32 = width;
            while (x > 0) {
                x -= 1;
                to[dest_x + x] = from[src_x + x];
            }
        }
    }
    return err.RTGERR_OK;
}

/// `over` mixed into the RGB565 pixel `under` by `coverage`, rounded as
/// graphics.library's own blend rounds.
fn mix(under: u16, over: u32, coverage: u32) u16 {
    if (coverage == 0) return under;
    const red: u32 = (under >> 11) & 0x1F;
    const green: u32 = (under >> 5) & 0x3F;
    const blue: u32 = under & 0x1F;
    const was = [3]u32{ red << 3 | red >> 2, green << 2 | green >> 4, blue << 3 | blue >> 2 };
    const new = [3]u32{ over >> 16 & 0xFF, over >> 8 & 0xFF, over & 0xFF };
    var mixed: [3]u32 = undefined;
    for (&mixed, was, new) |*channel, before, after| {
        channel.* = (after * coverage + before * (255 - coverage) + 127) / 255;
    }
    return @intCast((mixed[0] >> 3) << 11 | (mixed[1] >> 2) << 5 | mixed[2] >> 3);
}

fn blendPixels(board: *rtg.RtgBoard, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, alpha: u32) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.blends += 1;
    log.last_rect = area.*;
    log.last_pixels = pixels.*;
    log.last_alpha = alpha;
    if (dest.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    const whole = pixels.flags & rtg.RTGPIXF_OPAQUE != 0;
    // A picture in the buffer's own format - a window's buffer - is taken
    // only as one that covers fully.
    if (whole and pixels.format == .rgb565) {
        var line: u32 = 0;
        while (line < area.height) : (line += 1) {
            const to = rows16(dest, @as(u32, @intCast(area.y)) + line);
            const from: [*]const u16 = @ptrCast(@alignCast(pixels.pixels.? + @as(usize, @intCast(pixels.y + @as(i32, @intCast(line)))) * pixels.pitch));
            var column: u32 = 0;
            while (column < area.width) : (column += 1) {
                const pen = from[@as(usize, @intCast(pixels.x)) + column];
                const red: u32 = (pen >> 11) & 0x1F;
                const green: u32 = (pen >> 5) & 0x3F;
                const blue: u32 = pen & 0x1F;
                const over = (red << 3 | red >> 2) << 16 | (green << 2 | green >> 4) << 8 | (blue << 3 | blue >> 2);
                const x = @as(u32, @intCast(area.x)) + column;
                to[x] = mix(to[x], over, alpha);
            }
        }
        return err.RTGERR_OK;
    }
    if (pixels.format != .bgra32 and pixels.format != .rgba32) return err.RTGERR_BAD_FORMAT;
    var row: u32 = 0;
    while (row < area.height) : (row += 1) {
        const to = rows16(dest, @as(u32, @intCast(area.y)) + row);
        const from: [*]const u32 = @ptrCast(@alignCast(pixels.pixels.? + @as(usize, @intCast(pixels.y + @as(i32, @intCast(row)))) * pixels.pitch));
        var column: u32 = 0;
        while (column < area.width) : (column += 1) {
            var pen = from[@as(usize, @intCast(pixels.x)) + column];
            if (pixels.format == .rgba32) pen = (pen & 0xFF00_FF00) | (pen >> 16 & 0xFF) | (pen & 0xFF) << 16;
            const coverage = if (whole) alpha else ((pen >> 24) * alpha + 127) / 255;
            const x = @as(u32, @intCast(area.x)) + column;
            to[x] = mix(to[x], pen, coverage);
        }
    }
    return err.RTGERR_OK;
}

fn blendRect(board: *rtg.RtgBoard, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, color: u32) callconv(.c) i32 {
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.blend_rects += 1;
    log.last_rect = area.*;
    log.last_color = color;
    if (dest.format != .rgb565) return err.RTGERR_BAD_FORMAT;
    var y: u32 = @intCast(area.y);
    while (y < area.y + area.height) : (y += 1) {
        const row = rows16(dest, y);
        var x: u32 = @intCast(area.x);
        while (x < area.x + area.width) : (x += 1) row[x] = mix(row[x], color, color >> 24);
    }
    return err.RTGERR_OK;
}

/// Logged and refused: the caller scales in software, so a test of the
/// layer above sees the same pixels with and without a board.
fn scalePixels(board: *rtg.RtgBoard, dest: *rtg.RtgBitMap, area: *const rtg.RtgRect, pixels: *const rtg.RtgPixels, width: u32, height: u32) callconv(.c) i32 {
    _ = dest;
    instanceOf(board).calls += 1;
    const log = &stateOfBoard(board).log;
    log.scales += 1;
    log.last_rect = area.*;
    log.last_pixels = pixels.*;
    log.last_scale_width = width;
    log.last_scale_height = height;
    return err.RTGERR_NOT_SUPPORTED;
}

/// Everything a board can be asked.
const full_ops = rtg.RtgBoardOps{
    .destroy = &destroyBoard,
    .show = &showOp,
    .refresh = &refresh,
    .display = &display,
    .set_brightness = &setBrightness,
    .brightness = &brightness,
    .stats = &stats,
    .control = &control,
    .fill_rect = &fillRect,
    .copy_rect = &copyRect,
    .copy_rects = &copyRects,
    .mirror = &mirror,
    .set_pointer = &setPointer,
    .move_pointer = &movePointer,
    .show_pointer = &showPointer,
    .set_overlay = &setOverlay,
    .move_overlay = &moveOverlay,
    .blend_pixels = &blendPixels,
    .blend_rect = &blendRect,
    .scale_pixels = &scalePixels,
    .video_open = &videoOpen,
    .video_close = &videoClose,
    .video_show = &videoShow,
    .video_move = &videoMove,
};

/// What is on the connector, as the test set it: whether a monitor is
/// there, and as much of its EDID as there is room for.
fn detect(board: *rtg.RtgBoard, asked: *rtg.RtgDetect) callconv(.c) i32 {
    const state = stateOfBoard(board);
    state.log.detects += 1;
    if (state.detect_answer != err.RTGERR_OK) return state.detect_answer;
    asked.present = @intFromBool(state.monitor_there);
    if (!state.monitor_there) return err.RTGERR_OK;
    const bytes = state.monitor_edid orelse return err.RTGERR_OK;
    const length: u32 = @intCast(@min(bytes.len, asked.edid_max));
    @memcpy(asked.edid[0..length], bytes[0..length]);
    asked.edid_size = length;
    return err.RTGERR_OK;
}

/// A timing is one the board makes up to the clock the test set.
fn checkMode(board: *rtg.RtgBoard, timings: *const rtg.RtgTimings) callconv(.c) i32 {
    const state = stateOfBoard(board);
    state.log.checks += 1;
    return if (timings.pixel_clock_hz <= state.fastest_hz) err.RTGERR_OK else err.RTGERR_BAD_MODE;
}

/// A board with a connector: everything, and what is on it.
const connector_ops = ops: {
    var more = full_ops;
    more.detect = &detect;
    more.check_mode = &checkMode;
    break :ops more;
};

/// A board with no engine: it can be shown and refreshed and no more.
const plain_ops = rtg.RtgBoardOps{
    .destroy = &destroyBoard,
    .show = &showOp,
    .refresh = &refresh,
};

/// A board whose pixels go out in the order they are written, so it cannot
/// be turned.
const fixed_ops = rtg.RtgBoardOps{
    .destroy = &destroyBoard,
    .show = &showOp,
    .refresh = &refresh,
    .stats = &stats,
};

/// A device of its chip is offered: a board made for each of its
/// outputs, as the test said - or the device declined, with nothing
/// kept.
fn attach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, _: ?[*]const TagItem) callconv(.c) i32 {
    const state = stateOf(driver);
    const rb = driver.rtg_base;
    state.log.offered += 1;
    if (state.create_answer != err.RTGERR_OK) return state.create_answer;
    if (state.made + state.outputs > max_boards) return err.RTGERR_NO_MEMORY;

    // A panel on a bus: the bus first.
    var io: ?*rtg.RtgTransport = null;
    if (state.opens_bus) io = rb.OpenTransport(driver, device) orelse return err.RTGERR_NO_DISPLAY;

    const first = state.made;
    var unit: u32 = 0;
    while (unit < state.outputs) : (unit += 1) {
        const board = makeOutput(driver, device, unit) orelse {
            // What was made of this device goes, and the bus with it.
            for (state.boards[first..state.made]) |*made| {
                rb.DeleteBoard(made.*);
                made.* = null;
            }
            state.made = first;
            rb.CloseTransport(io);
            return err.RTGERR_NO_MEMORY;
        };
        state.boards[state.made] = board;
        state.made += 1;
        state.log.created += 1;
    }
    // The first board has the bus, and gives it back as it goes.
    if (io) |opened| instanceOf(state.boards[first].?).bus = opened;
    return err.RTGERR_OK;
}

/// One output's board, filled in as a real driver fills one in before its
/// attach answers. Null without memory.
fn makeOutput(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, unit: u32) ?*rtg.RtgBoard {
    const state = stateOf(driver);
    const board = driver.rtg_base.CreateBoard(driver, device, &.{
        .label = if (unit == 0) "Fake 0" else "Fake 1",
        .ops = if (state.connector)
            &connector_ops
        else if (state.cannot_turn)
            &fixed_ops
        else if (state.without_engine)
            &plain_ops
        else
            &full_ops,
        .instance_size = @sizeOf(Instance),
        .flags = rtg.boards.RTGBF_STREAMING,
        // Every board of it is cut out of the one display memory: a test
        // takes buffers on one of them.
        .region = .{
            .base = state.region,
            // No more than there is, whatever a test asked for.
            .size = @min(state.region_size, state.region_bytes),
            .alignment = 64,
            .flags = rtg.boards.RTGRF_DISPLAYABLE | rtg.boards.RTGRF_CPU_CACHED,
        },
        .unit = unit,
        // A monitor's modes in the format the tests draw in.
        .format = .rgb565,
        // Bands on the board that has everything; one whole buffer on the
        // two that have less.
        .caps = if (state.connector or !(state.cannot_turn or state.without_engine)) rtg.boards.RTGBC_BANDS else 0,
    }) orelse return null;
    const instance = instanceOf(board);
    instance.* = .{ .pattern = instance_pattern };

    // Its modes: the library keeps them, and numbers them as they come.
    const given: []const ModeOf = if (state.display) |*one| one[0..1] else mode_table[0..@min(state.modes, mode_table.len)];
    for (given) |*one| {
        if (driver.rtg_base.AddBoardMode(board, &one.timings, @intFromEnum(one.format), one.flags) == 0) {
            driver.rtg_base.DeleteBoard(board);
            return null;
        }
    }
    board.info.buffers = 2;

    if (state.claims_display) {
        const rb = board.rtg_base.?;
        var described = rtg.RtgBitMap{
            .pixels = state.region,
            .width = 64,
            .height = 32,
            .pitch = 128,
            .size_bytes = claimed_bytes,
            .format = .rgb565,
            .flags = rtg.bitmaps.RTGBMF_DISPLAYABLE,
        };
        board.showing = rb.AttachBitMap(board, &described);
        if (board.showing) |running| {
            instance.showing[0] = .{ .bitmap = running };
            instance.showing_count = 1;
        }
    }
    return board;
}

const driver_ops = rtg.RtgDriverOps{ .attach = &attach, .detach = &detach };
