// SPDX-License-Identifier: MIT
//! A keyboard.device or a mouse.device for host tests: it keeps the
//! events its sources hand it (KBD_ADDEVENT, MOUSE_ADDEVENT), the first
//! `max_events`, counts its opens and closes, and answers nothing else.

const sdk = @import("sdk");
const exec = sdk.exec;
const ie = sdk.devices.inputevent;
const ExecBase = sdk.interface.exec.ExecBase;

pub const max_events = 32;

/// A stand-in device of the name `name`, keeping the events of `command`.
pub fn Source(comptime name: [:0]const u8, comptime command: u16) type {
    return struct {
        pub const Device = extern struct {
            dev: exec.Device,
            sys: *ExecBase,
            events: [max_events]ie.InputEvent = @splat(.{}),
            count: u32 = 0,
            opens: u32 = 0,
            closes: u32 = 0,
        };

        pub fn of(made: *anyopaque) *Device {
            const dev: *exec.Device = @ptrCast(@alignCast(made));
            return @fieldParentPtr("dev", dev);
        }

        /// The events kept so far, and none from here on.
        pub fn taken(stand_in: *Device) []const ie.InputEvent {
            const kept = stand_in.events[0..@min(stand_in.count, max_events)];
            stand_in.count = 0;
            return kept;
        }

        fn init(dev: *exec.Device, _: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Device {
            const stand_in: *Device = @fieldParentPtr("dev", dev);
            const header = dev.*;
            stand_in.* = .{ .dev = header, .sys = sys };
            return dev;
        }

        fn open(dev: *exec.Device, _: *exec.IORequest, _: u32, _: u32) callconv(.c) i32 {
            const stand_in: *Device = @fieldParentPtr("dev", dev);
            dev.open_cnt += 1;
            stand_in.opens += 1;
            return 0;
        }

        fn close(dev: *exec.Device, _: *exec.IORequest) callconv(.c) ?*anyopaque {
            const stand_in: *Device = @fieldParentPtr("dev", dev);
            dev.open_cnt -= 1;
            stand_in.closes += 1;
            return null;
        }

        fn expunge(dev: *exec.Device) callconv(.c) ?*anyopaque {
            const stand_in: *Device = @fieldParentPtr("dev", dev);
            const sys = stand_in.sys;
            sys.DetachLibrary(dev);
            const start: *anyopaque = @ptrFromInt(@intFromPtr(dev) - dev.neg_size);
            sys.FreeMem(start, @as(usize, dev.neg_size) + dev.pos_size);
            return null;
        }

        fn beginIO(dev: *exec.Device, request: *exec.IORequest) callconv(.c) void {
            const stand_in: *Device = @fieldParentPtr("dev", dev);
            const io: *exec.IOStdReq = @ptrCast(@alignCast(request));
            if (request.command == command) {
                const events: [*]const ie.InputEvent = @ptrCast(@alignCast(io.data.?));
                const count = io.length / @sizeOf(ie.InputEvent);
                for (events[0..count]) |event| {
                    if (stand_in.count < max_events) stand_in.events[stand_in.count] = event;
                    stand_in.count += 1;
                }
                request.err = 0;
            } else {
                request.err = exec.IOERR_NOCMD;
            }
            if (request.flags & exec.IOF_QUICK == 0) stand_in.sys.ReplyMsg(&request.message);
        }

        fn abortIO(_: *exec.Device, _: *exec.IORequest) callconv(.c) i32 {
            return 0;
        }

        const vectors = [_]*const anyopaque{
            exec.vec(open),
            exec.vec(close),
            exec.vec(expunge),
            exec.vec(exec.libExtFunc),
            exec.vec(beginIO),
            exec.vec(abortIO),
        };

        const init_table = exec.InitTable{
            .data_size = @sizeOf(Device),
            .vectors = &vectors,
            .vector_count = vectors.len,
            .init = &init,
        };

        pub const tag: exec.Resident = .{
            .match_tag = &tag,
            .flags = exec.RTF_AUTOINIT,
            .version = 1,
            .type = .device,
            .pri = 0,
            .name = name,
            .id_string = name ++ " (stand-in) 1.0",
            .init = &init_table,
        };
    };
}
