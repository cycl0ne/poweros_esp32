// SPDX-License-Identifier: MIT
//! vchiq: vchiq.resource and the firmware's MMAL from the shell - what
//! the VideoCore's components say of themselves.
//!
//!   vchiq                          ril.video_decode, ril.image_decode
//!   vchiq ril.isp                  that component
//!
//! For each: its ports, each port's buffers and format, and the
//! encodings its input and output take. Built against the SDK only.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const mmal = sdk.hardware.mmal;
const vchiq = sdk.resources.vchiq;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const VchiqBase = sdk.interface.vchiq.VchiqBase;
const Printf = dos.stdio.Printf;

const NAME = "vchiq";
const VERSION_STRING = "\x00$VER: vchiq 1.0 (17.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "COMPONENT";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const vb: *VchiqBase = @ptrCast(sys.OpenResource(vchiq.VCHIQNAME) orelse {
        _ = Printf(dl, "no %s\n", .{vchiq.VCHIQNAME});
        return dos.RETURN_FAIL;
    });
    const memory = sys.AllocMem(@sizeOf(mmal.Client), exec.MEMF_CLEAR) orelse return dos.RETURN_FAIL;
    defer sys.FreeMem(memory, @sizeOf(mmal.Client));
    const c: *mmal.Client = @ptrCast(@alignCast(memory));
    const opened = c.open(vb);
    if (opened != vchiq.VCHIQERR_OK) {
        _ = Printf(dl, "the mmal service did not open: %u\n", .{opened});
        return dos.RETURN_ERROR;
    }
    defer c.close();
    _ = dl.PutStr("the mmal service is open\n");
    if (argv[0] != 0) {
        describe(dl, c, @ptrFromInt(argv[0]));
    } else {
        describe(dl, c, "ril.video_decode");
        describe(dl, c, "ril.image_decode");
    }
    if (c.dropped != 0) _ = Printf(dl, "%u buffers and events were dropped\n", .{c.dropped});
    return dos.RETURN_OK;
}

fn describe(dl: *DosBase, c: *mmal.Client, name: [*:0]const u8) void {
    var reply: mmal.ComponentCreateReply = undefined;
    const got = c.create(std.mem.span(name), 0, &reply);
    if (got != vchiq.VCHIQERR_OK) {
        _ = Printf(dl, "%s: no answer (%u)\n", .{ name, got });
        return;
    }
    if (reply.status != mmal.STATUS_SUCCESS) {
        _ = Printf(dl, "%s: not made, status %u\n", .{ name, reply.status });
        return;
    }
    _ = Printf(dl, "%s: component %08x, %u inputs, %u outputs, %u clocks\n", .{ name, reply.component_handle, reply.input_num, reply.output_num, reply.clock_num });
    port(dl, c, reply.component_handle, mmal.PORT_CONTROL, 0, "control");
    if (reply.input_num > 0) port(dl, c, reply.component_handle, mmal.PORT_INPUT, 0, "input 0");
    if (reply.output_num > 0) port(dl, c, reply.component_handle, mmal.PORT_OUTPUT, 0, "output 0");
    const destroyed = c.component(mmal.MSG_COMPONENT_DESTROY, reply.component_handle);
    if (destroyed != mmal.STATUS_SUCCESS) _ = Printf(dl, "  destroyed: status %u\n", .{destroyed});
}

fn port(dl: *DosBase, c: *mmal.Client, handle: u32, port_type: u32, index: u32, what: [*:0]const u8) void {
    var info: mmal.PortInfo = undefined;
    const status = c.portInfo(handle, port_type, index, &info);
    if (status != mmal.STATUS_SUCCESS) {
        _ = Printf(dl, "  %s: status %u\n", .{ what, status });
        return;
    }
    var code: [5]u8 = @splat(0);
    std.mem.writeInt(u32, code[0..4], info.format.encoding, .little);
    _ = Printf(dl, "  %s: port %08x, %s variant %08x, %ux%u (crop %dx%d), buffers %u..%u of %u..%u bytes, align %u, capabilities %x\n", .{
        what,                             info.port_handle,                  @as([*:0]const u8, @ptrCast(&code)), info.format.encoding_variant,
        info.es.width,                    info.es.height,                    info.es.crop.width,                  info.es.crop.height,
        info.port.buffer_num_min,         info.port.buffer_num_recommended,  info.port.buffer_size_min,           info.port.buffer_size_recommended,
        info.port.buffer_alignment_min,   info.port.capabilities,
    });
    if (port_type == mmal.PORT_CONTROL) return;
    var codes: [mmal.parameter_words * 4]u8 = undefined;
    var length: u32 = 0;
    const got = c.getParameter(handle, info.port_handle, mmal.PARAMETER_SUPPORTED_ENCODINGS, &codes, &length);
    if (got != mmal.STATUS_SUCCESS) {
        _ = Printf(dl, "    encodings: status %u\n", .{got});
        return;
    }
    _ = dl.PutStr("    encodings:");
    var at: usize = 0;
    while (at + 4 <= @min(length, codes.len)) : (at += 4) {
        var one: [5]u8 = @splat(0);
        @memcpy(one[0..4], codes[at .. at + 4]);
        _ = Printf(dl, " %s", .{@as([*:0]const u8, @ptrCast(&one))});
    }
    _ = dl.PutStr("\n");
}
