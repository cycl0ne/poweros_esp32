// SPDX-License-Identifier: MIT
//! MMAL: the VideoCore firmware's media components on the Raspberry Pi's
//! BCM2711 - its H.264 and JPEG decoders ("ril.video_decode",
//! "ril.image_decode"), its ISP ("ril.isp") - reached through
//! vchiq.resource's "mmal" service. Each MMAL message is one VCHIQ
//! message: a header, then what its type carries.
//!
//! A component is made by name (COMPONENT_CREATE), its ports - control,
//! input, output - asked about and set (PORT_INFO_GET, PORT_INFO_SET,
//! PORT_PARAMETER_*), enabled (PORT_ACTION) and fed buffers
//! (BUFFER_FROM_HOST). Those come back (BUFFER_TO_HOST) when the
//! component is done with them: an input buffer once it read it, an
//! output buffer once it wrote it. The component says what changed in
//! events (EVENT_TO_HOST), the first picture's size among them.
//!
//! **The data**: without the firmware's own shared memory, a buffer's
//! bytes travel apart from its message, as a bulk transfer on the
//! service: after a BUFFER_FROM_HOST of an input buffer the ARM puts out
//! a bulk of its bytes (VCHIQBULK_TRANSMIT); after a BUFFER_TO_HOST of
//! an output buffer with data, a bulk with room for them, its length to
//! 4 (VCHIQBULK_RECEIVE). A buffer of up to 128 bytes may travel in its
//! message instead (`payload_in_message`). The firmware keeps its own
//! copy of every buffer a port has (`buffer_num` of `buffer_size`) in
//! the VideoCore's memory.
//!
//! Every request but BUFFER_FROM_HOST is answered, the answer carrying
//! the request's type and `context`: `Client.call` sends one and waits
//! for its answer, keeping the buffers and events that come meanwhile for
//! `Client.next`.
//!
//! The messages, their numbers and their layout are the Raspberry Pi's
//! MMAL as Linux's driver speaks it (drivers/staging/vc04_services/
//! vchiq-mmal, version 15; its numbers, the code here is written fresh).

const std = @import("std");
const exec = @import("../libs/exec/exec.zig");
const vchiq = @import("../resources/vchiq.zig");
const VchiqBase = @import("../interface/vchiq.zig").VchiqBase;

/// The service, and the protocol's versions the ARM speaks.
pub const SERVICE: u32 = 0x6D6D_616C; // vchiq.fourcc("mmal")
pub const VERSION: u32 = 15;
pub const VERSION_MIN: u32 = 10;

/// An MMAL four-character code: the first character in the low byte.
pub fn fourcc(name: *const [4]u8) u32 {
    return std.mem.readInt(u32, name, .little);
}

/// Every message's header's first word.
pub const MAGIC: u32 = 0x6C61_6D6D; // fourcc("mmal")

/// The most bytes one message holds.
pub const max_message = 512;

/// A time no one knows: a buffer's `pts` and `dts` when it has none.
pub const TIME_UNKNOWN: i64 = std.math.minInt(i64);

// --- message types ----------------------------------------------------------

pub const MSG_GET_VERSION: u32 = 3;
pub const MSG_COMPONENT_CREATE: u32 = 4;
pub const MSG_COMPONENT_DESTROY: u32 = 5;
pub const MSG_COMPONENT_ENABLE: u32 = 6;
pub const MSG_COMPONENT_DISABLE: u32 = 7;
pub const MSG_PORT_INFO_GET: u32 = 8;
pub const MSG_PORT_INFO_SET: u32 = 9;
pub const MSG_PORT_ACTION: u32 = 10;
pub const MSG_BUFFER_FROM_HOST: u32 = 11;
pub const MSG_BUFFER_TO_HOST: u32 = 12;
pub const MSG_PORT_PARAMETER_SET: u32 = 14;
pub const MSG_PORT_PARAMETER_GET: u32 = 15;
pub const MSG_EVENT_TO_HOST: u32 = 16;

/// What the answers say: done, or why not.
pub const STATUS_SUCCESS: u32 = 0;
pub const STATUS_ENOMEM: u32 = 1;
pub const STATUS_ENOSPC: u32 = 2;
pub const STATUS_EINVAL: u32 = 3;
pub const STATUS_ENOSYS: u32 = 4;
pub const STATUS_ENOENT: u32 = 5;
pub const STATUS_ENXIO: u32 = 6;
pub const STATUS_EIO: u32 = 7;
pub const STATUS_ESPIPE: u32 = 8;
pub const STATUS_ECORRUPT: u32 = 9;
pub const STATUS_ENOTREADY: u32 = 10;
pub const STATUS_ECONFIG: u32 = 11;
pub const STATUS_EISCONN: u32 = 12;
pub const STATUS_ENOTCONN: u32 = 13;
pub const STATUS_EAGAIN: u32 = 14;
pub const STATUS_EFAULT: u32 = 15;

/// A port's type.
pub const PORT_CONTROL: u32 = 1;
pub const PORT_INPUT: u32 = 2;
pub const PORT_OUTPUT: u32 = 3;
pub const PORT_CLOCK: u32 = 4;

/// PORT_ACTION's actions.
pub const ACTION_ENABLE: u32 = 1;
pub const ACTION_DISABLE: u32 = 2;
pub const ACTION_FLUSH: u32 = 3;

/// A format's type.
pub const ES_TYPE_CONTROL: u32 = 1;
pub const ES_TYPE_AUDIO: u32 = 2;
pub const ES_TYPE_VIDEO: u32 = 3;

/// A format's flags: the stream comes a frame a buffer; a column
/// format's width is its columns' height.
pub const FORMAT_FLAG_FRAMED: u32 = 1;
pub const FORMAT_FLAG_COL_FMTS_WIDTH_IS_COL_STRIDE: u32 = 2;

/// Encodings.
pub const ENCODING_H264 = fourcc("H264");
pub const ENCODING_MJPEG = fourcc("MJPG");
pub const ENCODING_JPEG = fourcc("JPEG");
pub const ENCODING_I420 = fourcc("I420");
pub const ENCODING_I422 = fourcc("I422");
pub const ENCODING_NV12 = fourcc("NV12");
pub const ENCODING_YV12 = fourcc("YV12");
pub const ENCODING_RGB24 = fourcc("RGB3");
pub const ENCODING_BGR24 = fourcc("BGR3");
pub const ENCODING_RGBA = fourcc("RGBA");
pub const ENCODING_BGRA = fourcc("BGRA");
pub const ENCODING_OPAQUE = fourcc("OPQV");
/// NV12 in columns 128 bytes wide, the BCM2711's own: the brightness and
/// colour of each column one after the other ("SAND").
pub const ENCODING_YUVUV128 = fourcc("SAND");

/// Colour spaces.
pub const COLOR_SPACE_BT601 = fourcc("Y601");
pub const COLOR_SPACE_BT709 = fourcc("Y709");
pub const COLOR_SPACE_JPEG_JFIF = fourcc("YJFI");

/// Events, an event buffer's `cmd`.
pub const EVENT_ERROR = fourcc("ERRO");
pub const EVENT_EOS = fourcc("EEOS");
pub const EVENT_FORMAT_CHANGED = fourcc("EFCH");
pub const EVENT_PARAMETER_CHANGED = fourcc("EPCH");

/// Buffer flags.
pub const BUFFER_FLAG_EOS: u32 = 1 << 0;
pub const BUFFER_FLAG_FRAME_START: u32 = 1 << 1;
pub const BUFFER_FLAG_FRAME_END: u32 = 1 << 2;
pub const BUFFER_FLAG_FRAME: u32 = BUFFER_FLAG_FRAME_START | BUFFER_FLAG_FRAME_END;
pub const BUFFER_FLAG_KEYFRAME: u32 = 1 << 3;
pub const BUFFER_FLAG_DISCONTINUITY: u32 = 1 << 4;
pub const BUFFER_FLAG_CONFIG: u32 = 1 << 5;
pub const BUFFER_FLAG_CORRUPTED: u32 = 1 << 9;
/// The firmware could not take the buffer's payload (its bulk).
pub const BUFFER_FLAG_TRANSMISSION_FAILED: u32 = 1 << 10;

/// Parameters, by group: common, camera, video.
pub const PARAMETER_SUPPORTED_ENCODINGS: u32 = 0x0001;
pub const PARAMETER_ZERO_COPY: u32 = 0x0004;
pub const PARAMETER_BUFFER_REQUIREMENTS: u32 = 0x0005;
pub const PARAMETER_NO_IMAGE_PADDING: u32 = 0x000E;
pub const PARAMETER_VIDEO_INTERLACE_TYPE: u32 = 0x2002E;
pub const PARAMETER_VIDEO_VALIDATE_TIMESTAMPS: u32 = 0x20037;
pub const PARAMETER_VIDEO_STOP_ON_PAR_COLOUR_CHANGE: u32 = 0x20038;
pub const PARAMETER_VIDEO_MAX_NUM_CALLBACKS: u32 = 0x20031;
pub const PARAMETER_EXTRA_BUFFERS: u32 = 0x20013;

/// The bytes a buffer's bulk moves for `length` bytes of payload: a
/// whole number of words, both ways. The firmware's end of the bulk is
/// that long; one of the exact length only, sent with a buffer, comes
/// back with BUFFER_FLAG_TRANSMISSION_FAILED, the payload not read. The
/// buffer's own length stays exact, and the bytes past it are not used.
pub fn bulkBytes(length: u32) u32 {
    return (length + 3) & ~@as(u32, 3);
}

/// The most a parameter's value holds.
pub const parameter_words = 96;
/// The most short data a buffer's message carries.
pub const short_data = 128;
/// The most an event carries.
pub const event_bytes = 256;

// --- layouts ----------------------------------------------------------------

pub const Header = extern struct {
    magic: u32 = MAGIC,
    type: u32 = 0,
    control_service: u32 = 0,
    context: u32 = 0,
    status: u32 = 0,
    padding: u32 = 0,
};

pub const Rect = extern struct { x: i32 = 0, y: i32 = 0, width: i32 = 0, height: i32 = 0 };
pub const Fraction = extern struct { num: i32 = 0, den: i32 = 0 };

/// A video format: for a raw one `width` is the rows' stride in pixels
/// and `height` the rows a plane has; `crop` is the picture in them.
pub const VideoFormat = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    crop: Rect = .{},
    frame_rate: Fraction = .{},
    par: Fraction = .{},
    color_space: u32 = 0,
};

pub const EsFormat = extern struct {
    type: u32 = 0,
    encoding: u32 = 0,
    encoding_variant: u32 = 0,
    es: u32 = 0,
    bitrate: u32 = 0,
    flags: u32 = 0,
    extradata_size: u32 = 0,
    extradata: u32 = 0,
};

/// A port, as the firmware has it: of what is set only `buffer_num`,
/// `buffer_size` and `userdata` count.
pub const Port = extern struct {
    priv: u32 = 0,
    name: u32 = 0,
    type: u32 = 0,
    index: u16 = 0,
    index_all: u16 = 0,
    is_enabled: u32 = 0,
    format: u32 = 0,
    buffer_num_min: u32 = 0,
    buffer_size_min: u32 = 0,
    buffer_alignment_min: u32 = 0,
    buffer_num_recommended: u32 = 0,
    buffer_size_recommended: u32 = 0,
    buffer_num: u32 = 0,
    buffer_size: u32 = 0,
    component: u32 = 0,
    userdata: u32 = 0,
    capabilities: u32 = 0,
};

pub const ComponentCreate = extern struct {
    h: Header = .{ .type = MSG_COMPONENT_CREATE },
    client_component: u32 = 0,
    name: [128]u8 = @splat(0),
    pid: u32 = 0,
};

pub const ComponentCreateReply = extern struct {
    h: Header,
    status: u32,
    component_handle: u32,
    input_num: u32,
    output_num: u32,
    clock_num: u32,
};

/// COMPONENT_DESTROY, _ENABLE and _DISABLE.
pub const ComponentRequest = extern struct {
    h: Header,
    component_handle: u32,
};

/// The answer that is a status alone.
pub const StatusReply = extern struct {
    h: Header,
    status: u32,
};

pub const PortInfoGet = extern struct {
    h: Header = .{ .type = MSG_PORT_INFO_GET },
    component_handle: u32,
    port_type: u32,
    index: u32,
};

/// A port as PORT_INFO_GET tells it, and PORT_INFO_SET answers.
pub const PortInfo = extern struct {
    h: Header,
    status: u32,
    component_handle: u32,
    port_type: u32,
    port_index: u32,
    found: i32,
    port_handle: u32,
    port: Port,
    format: EsFormat,
    es: VideoFormat,
    extradata: [128]u8,
};

pub const PortInfoSet = extern struct {
    h: Header = .{ .type = MSG_PORT_INFO_SET },
    component_handle: u32,
    port_type: u32,
    port_index: u32,
    port: Port,
    format: EsFormat,
    es: VideoFormat,
    extradata: [128]u8 = @splat(0),
};

pub const PortAction = extern struct {
    h: Header = .{ .type = MSG_PORT_ACTION },
    component_handle: u32,
    port_handle: u32,
    action: u32,
    port: Port,
};

pub const ParameterSet = extern struct {
    h: Header = .{ .type = MSG_PORT_PARAMETER_SET },
    component_handle: u32,
    port_handle: u32,
    id: u32,
    size: u32,
    value: [parameter_words]u32 = @splat(0),
};

pub const ParameterGet = extern struct {
    h: Header = .{ .type = MSG_PORT_PARAMETER_GET },
    component_handle: u32,
    port_handle: u32,
    id: u32,
    size: u32,
};

pub const ParameterGetReply = extern struct {
    h: Header,
    status: u32,
    id: u32,
    size: u32,
    value: [parameter_words]u32,
};

/// The ARM's part of a buffer's message, which the firmware sends back
/// with it: the component's and port's handles, and the ARM's number for
/// the buffer.
pub const DriverBuffer = extern struct {
    magic: u32 = MAGIC,
    component_handle: u32 = 0,
    port_handle: u32 = 0,
    client_context: u32 = 0,
};

pub const BufferHeader = extern struct {
    next: u32 = 0,
    priv: u32 = 0,
    /// 0 for data; an event's code (EVENT_*) otherwise.
    cmd: u32 = 0,
    /// The ARM's name for the memory - the firmware keeps its own copy.
    data: u32 = 0,
    alloc_size: u32 = 0,
    length: u32 = 0,
    offset: u32 = 0,
    flags: u32 = 0,
    /// On 4-byte boundaries, as the SDK keeps 64-bit fields; they fall
    /// on 8-byte ones in every message all the same.
    pts: i64 align(4) = TIME_UNKNOWN,
    dts: i64 align(4) = TIME_UNKNOWN,
    type: u32 = 0,
    user_data: u32 = 0,
};

/// A buffer's message both ways: BUFFER_FROM_HOST, BUFFER_TO_HOST.
pub const BufferMessage = extern struct {
    h: Header = .{ .type = MSG_BUFFER_FROM_HOST },
    drvbuf: DriverBuffer = .{},
    drvbuf_ref: DriverBuffer = .{},
    buffer: BufferHeader = .{},
    /// A video buffer's planes: how many, where each starts and its
    /// pitch.
    planes: u32 = 0,
    plane_offset: [4]u32 = @splat(0),
    plane_pitch: [4]u32 = @splat(0),
    video_flags: u32 = 0,
    is_zero_copy: i32 = 0,
    has_reference: i32 = 0,
    payload_in_message: u32 = 0,
    short_data: [short_data]u8 = @splat(0),
    /// What the firmware's layout pads it to, its 64-bit fields being on
    /// 8-byte boundaries there: 296 bytes in all.
    tail: u32 = 0,
};

pub const EventToHost = extern struct {
    h: Header,
    client_component: u32,
    port_type: u32,
    port_num: u32,
    cmd: u32,
    length: u32,
    data: [event_bytes]u8,
    delayed_buffer: u32,
};

/// What an EVENT_FORMAT_CHANGED carries: the buffers the port wants now,
/// and its new format.
pub const FormatChanged = extern struct {
    buffer_size_min: u32,
    buffer_num_min: u32,
    buffer_size_recommended: u32,
    buffer_num_recommended: u32,
    es_ptr: u32,
    format: EsFormat,
    es: VideoFormat,
    extradata: [128]u8,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 24);
    std.debug.assert(@sizeOf(VideoFormat) == 44);
    std.debug.assert(@sizeOf(EsFormat) == 32);
    std.debug.assert(@sizeOf(Port) == 64);
    std.debug.assert(@sizeOf(ComponentCreate) == 24 + 136);
    std.debug.assert(@sizeOf(ComponentCreateReply) == 24 + 20);
    std.debug.assert(@sizeOf(PortInfo) == 24 + 292);
    std.debug.assert(@sizeOf(PortInfoSet) == 24 + 280);
    std.debug.assert(@sizeOf(PortAction) == 24 + 76);
    std.debug.assert(@sizeOf(ParameterSet) == 24 + 400);
    std.debug.assert(@sizeOf(ParameterGetReply) == 24 + 396);
    std.debug.assert(@sizeOf(BufferHeader) == 56);
    std.debug.assert(@offsetOf(BufferMessage, "buffer") == 24 + 32);
    std.debug.assert(@offsetOf(BufferMessage, "planes") == 24 + 88);
    std.debug.assert(@offsetOf(BufferMessage, "payload_in_message") == 24 + 136);
    std.debug.assert(@sizeOf(BufferMessage) == 296);
    std.debug.assert(@sizeOf(EventToHost) == 24 + 280);
    std.debug.assert(@sizeOf(FormatChanged) == 224);
}

// --- the client -------------------------------------------------------------

/// A message as it came, aligned for every layout here.
pub const Message = extern struct {
    bytes: [max_message]u8 align(4) = undefined,
    length: u32 = 0,

    pub fn header(m: *const Message) *const Header {
        return @ptrCast(&m.bytes);
    }

    /// The message as `T`: what it did not carry reads as 0. Null for
    /// one shorter than a header.
    pub fn as(m: *const Message, comptime T: type) ?*const T {
        if (m.length < @sizeOf(Header)) return null;
        return @ptrCast(&m.bytes);
    }
};

/// How long an answer is waited for.
pub const answer_us: u64 = 3_000_000;

/// How many buffers and events are kept while an answer is waited for.
const kept_max = 32;

/// One task's "mmal" service, and the messages that came while it waited
/// for an answer.
pub const Client = struct {
    vb: *VchiqBase,
    service: *vchiq.VchiqService,
    context: u32 = 1,
    kept: [kept_max]Message = undefined,
    kept_first: u32 = 0,
    kept_count: u32 = 0,
    /// Buffers and events that came with no room to keep them.
    dropped: u32 = 0,

    /// The service opened: VCHIQERR_OK, or why not.
    pub fn open(c: *Client, vb: *VchiqBase) u32 {
        var err: u32 = vchiq.VCHIQERR_OK;
        const service = vb.OpenService(SERVICE, VERSION, VERSION_MIN, &err) orelse return err;
        c.* = .{ .vb = vb, .service = service };
        return vchiq.VCHIQERR_OK;
    }

    pub fn close(c: *Client) void {
        c.vb.CloseService(c.service);
    }

    /// A message that is not answered: a buffer.
    pub fn send(c: *Client, request: anytype) u32 {
        const bytes = std.mem.asBytes(request);
        return c.vb.SendMessage(c.service, bytes.ptr, @intCast(bytes.len));
    }

    /// `request` sent - its first `length` bytes - and its answer waited
    /// for, into `answer`: VCHIQERR_OK, or VCHIQERR_TIMEOUT, or why it
    /// could not go. Buffers and events that come meanwhile are kept for
    /// `next`; an answer to an earlier request that ran out of time is
    /// dropped.
    pub fn callLength(c: *Client, request: anytype, length: usize, answer: *Message) u32 {
        const h: *Header = &request.h;
        h.magic = MAGIC;
        h.context = c.context;
        c.context +%= 1;
        if (c.context == 0) c.context = 1;
        const bytes = std.mem.asBytes(request);
        const sent = c.vb.SendMessage(c.service, bytes.ptr, @intCast(length));
        if (sent != vchiq.VCHIQERR_OK) return sent;
        while (true) {
            const got = c.receive(answer, answer_us);
            if (got != vchiq.VCHIQERR_OK) return got;
            const a = answer.header();
            if (a.type == h.type and a.context == h.context) return vchiq.VCHIQERR_OK;
            if (a.type == MSG_BUFFER_TO_HOST or a.type == MSG_EVENT_TO_HOST) c.keep(answer);
        }
    }

    pub fn call(c: *Client, request: anytype, answer: *Message) u32 {
        return c.callLength(request, @sizeOf(@TypeOf(request.*)), answer);
    }

    /// The next buffer or event: VCHIQERR_OK, VCHIQERR_TIMEOUT or
    /// VCHIQERR_CLOSED.
    pub fn next(c: *Client, into: *Message, timeout_us: u64) u32 {
        if (c.kept_count != 0) {
            into.* = c.kept[c.kept_first];
            c.kept_first = (c.kept_first + 1) % kept_max;
            c.kept_count -= 1;
            return vchiq.VCHIQERR_OK;
        }
        return c.receive(into, timeout_us);
    }

    fn receive(c: *Client, into: *Message, timeout_us: u64) u32 {
        var length: u32 = 0;
        const got = c.vb.ReceiveMessage(c.service, &into.bytes, max_message, &length, timeout_us);
        into.length = @min(length, max_message);
        @memset(into.bytes[into.length..], 0);
        return got;
    }

    fn keep(c: *Client, m: *const Message) void {
        if (c.kept_count == kept_max) {
            c.dropped += 1;
            return;
        }
        c.kept[(c.kept_first + c.kept_count) % kept_max] = m.*;
        c.kept_count += 1;
    }

    // --- components ---------------------------------------------------------

    /// A component made: its answer (status, handle, ports) in `reply`.
    pub fn create(c: *Client, name: []const u8, client_component: u32, reply: *ComponentCreateReply) u32 {
        var request: ComponentCreate = .{ .client_component = client_component };
        @memcpy(request.name[0..@min(name.len, 127)], name[0..@min(name.len, 127)]);
        var answer: Message = .{};
        const got = c.call(&request, &answer);
        if (got != vchiq.VCHIQERR_OK) return got;
        reply.* = (answer.as(ComponentCreateReply) orelse return vchiq.VCHIQERR_SIZE).*;
        return vchiq.VCHIQERR_OK;
    }

    /// COMPONENT_DESTROY, _ENABLE or _DISABLE: the firmware's status, or
    /// STATUS_EIO when it did not answer.
    pub fn component(c: *Client, kind: u32, handle: u32) u32 {
        var request: ComponentRequest = .{ .h = .{ .type = kind }, .component_handle = handle };
        return c.statusOf(&request);
    }

    /// A port as the firmware has it: its status.
    pub fn portInfo(c: *Client, handle: u32, port_type: u32, index: u32, info: *PortInfo) u32 {
        var request: PortInfoGet = .{ .component_handle = handle, .port_type = port_type, .index = index };
        var answer: Message = .{};
        if (c.call(&request, &answer) != vchiq.VCHIQERR_OK) return STATUS_EIO;
        info.* = (answer.as(PortInfo) orelse return STATUS_EIO).*;
        return info.status;
    }

    /// A port set as `info` says - its buffers and format: the
    /// firmware's status. `info` is read again from the firmware after.
    pub fn setPort(c: *Client, info: *PortInfo) u32 {
        var request: PortInfoSet = .{
            .component_handle = info.component_handle,
            .port_type = info.port_type,
            .port_index = info.port_index,
            .port = info.port,
            .format = info.format,
            .es = info.es,
        };
        request.format.es = 0;
        request.format.extradata = 0;
        const extra = @min(info.format.extradata_size, request.extradata.len);
        @memcpy(request.extradata[0..extra], info.extradata[0..extra]);
        const status = c.statusOf(&request);
        if (status != STATUS_SUCCESS) return status;
        return c.portInfo(info.component_handle, info.port_type, info.port_index, info);
    }

    /// A port enabled or disabled (ACTION_*): the firmware's status.
    pub fn portAction(c: *Client, info: *const PortInfo, action: u32) u32 {
        var request: PortAction = .{
            .component_handle = info.component_handle,
            .port_handle = info.port_handle,
            .action = action,
            .port = info.port,
        };
        return c.statusOf(&request);
    }

    /// A parameter set on a port: the firmware's status.
    pub fn setParameter(c: *Client, handle: u32, port_handle: u32, id: u32, value: []const u8) u32 {
        var request: ParameterSet = .{ .component_handle = handle, .port_handle = port_handle, .id = id, .size = @intCast(8 + value.len) };
        const words = std.mem.sliceAsBytes(request.value[0..]);
        @memcpy(words[0..value.len], value);
        var answer: Message = .{};
        if (c.callLength(&request, 40 + value.len, &answer) != vchiq.VCHIQERR_OK) return STATUS_EIO;
        return (answer.as(StatusReply) orelse return STATUS_EIO).status;
    }

    pub fn setParameter32(c: *Client, handle: u32, port_handle: u32, id: u32, value: u32) u32 {
        return c.setParameter(handle, port_handle, id, std.mem.asBytes(&value));
    }

    /// A parameter of a port into `into`: the firmware's status, and its
    /// length in `length` (which may be more than `into` holds, with
    /// STATUS_ENOSPC).
    pub fn getParameter(c: *Client, handle: u32, port_handle: u32, id: u32, into: []u8, length: *u32) u32 {
        const room: u32 = @intCast(@min(into.len, parameter_words * 4));
        var request: ParameterGet = .{ .component_handle = handle, .port_handle = port_handle, .id = id, .size = 8 + room };
        var answer: Message = .{};
        length.* = 0;
        if (c.call(&request, &answer) != vchiq.VCHIQERR_OK) return STATUS_EIO;
        const reply = answer.as(ParameterGetReply) orelse return STATUS_EIO;
        const size = reply.size -| 8;
        length.* = size;
        const n = @min(size, room);
        @memcpy(into[0..n], std.mem.sliceAsBytes(reply.value[0..])[0..n]);
        return reply.status;
    }

    fn statusOf(c: *Client, request: anytype) u32 {
        var answer: Message = .{};
        if (c.call(request, &answer) != vchiq.VCHIQERR_OK) return STATUS_EIO;
        return (answer.as(StatusReply) orelse return STATUS_EIO).status;
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "four-character codes: MMAL's low byte first" {
    try testing.expectEqual(@as(u32, 0x3436_3248), ENCODING_H264);
    try testing.expectEqual(@as(u32, 0x4745_504A), ENCODING_JPEG);
    try testing.expectEqual(@as(u32, 0x3032_3449), ENCODING_I420);
    try testing.expectEqual(@as(u32, 0x4843_4645), EVENT_FORMAT_CHANGED);
    try testing.expectEqual(MAGIC, fourcc("mmal"));
}
