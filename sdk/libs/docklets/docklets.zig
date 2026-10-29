// SPDX-License-Identifier: MIT
//! Docklets: small pictures of the machine's state - the time, the
//! battery, the volume, how busy the cores are, the network, what the
//! Player plays - that the dock shows among its entries, and keeps up to
//! date.
//!
//! Each is a class library of its own in `SYS:classes/docklets/`, reached
//! through `LIBS:` as `docklets/<name>.docklet`, its class called by the
//! file's name. The class is an image class (imageclass): it takes no
//! input - a click on it is the dock's, which runs the docklet's command
//! - and it draws itself fitted to the square it is given
//! (`IM_DRAWFRAME`), over whatever is there, in the screen's pens (the
//! message's `DrawInfo`). So it is sharp at every size, the one the dock
//! magnifies it to too. `IM_DRAW` draws it in the image's own box.
//!
//! A docklet looks at the machine when it is made and whenever it is set
//! `DOCKLET_Look`; that set answers non-zero when what it shows changed,
//! and the dock then draws it again. How often it wants to be asked is
//! `DOCKLET_Every`. The rest is read with `GetAttr`:
//!
//!   const lib = sys.OpenLibrary(docklets.CLOCK_LIBRARY, 0) orelse return;
//!   defer sys.CloseLibrary(lib);
//!   const clock = ib.NewObjectTagList(null, docklets.CLOCK_CLASS, null) orelse return;
//!   defer ib.DisposeObject(clock);
//!   // Every DOCKLET_Every milliseconds:
//!   const look = [_]TagItem{ .{ .tag = docklets.DOCKLET_Look, .data = 1 }, .{} };
//!   if (ib.SetAttrsTagList(clock, &look) != 0) {
//!       var draw = ic.ImpDraw{ .method_id = ic.IM_DRAWFRAME, .rast_port = rp, .offset = .{ .x = 10, .y = 4 }, .draw_info = dri, .dimensions = .{ .width = 48, .height = 48 } };
//!       _ = ib.SendMessage(clock, @ptrCast(&draw));
//!   }
//!
//! `DockletClass` makes such a class library from a few functions:
//! looking, saying what it shows, and drawing it on a `Frame`.

const exec = @import("../exec/exec.zig");
const utility = @import("../utility/utility.zig");
const graphics = @import("../graphics/graphics.zig");
const classes = @import("../intuition/classes.zig");
const classusr = @import("../intuition/classusr.zig");
const ic = @import("../intuition/imageclass.zig");
const gadgets = @import("../gadgets/gadgets.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const TagItem = utility.TagItem;
const Class = classes.Class;
const Object = classes.Object;

/// Where the docklets are: the dock lists them from there.
pub const DOCKLETS_DRAWER = "SYS:classes/docklets";
/// What a docklet's file name ends in; its library is opened as this
/// prefix and the file's name.
pub const DOCKLET_SUFFIX = ".docklet";
pub const DOCKLET_PREFIX = "docklets/";

/// The docklets on the disk: what a program opens, and the class it then
/// asks for.
pub const CLOCK_LIBRARY = "docklets/clock.docklet";
pub const CLOCK_CLASS = "clock.docklet";
pub const BATTERY_LIBRARY = "docklets/battery.docklet";
pub const BATTERY_CLASS = "battery.docklet";
pub const VOLUME_LIBRARY = "docklets/volume.docklet";
pub const VOLUME_CLASS = "volume.docklet";
pub const CPU_LIBRARY = "docklets/cpu.docklet";
pub const CPU_CLASS = "cpu.docklet";
pub const NETWORK_LIBRARY = "docklets/network.docklet";
pub const NETWORK_CLASS = "network.docklet";
pub const PLAYER_LIBRARY = "docklets/player.docklet";
pub const PLAYER_CLASS = "player.docklet";

/// Where the docklets' tags begin: clear of intuition's classes and of
/// the gadget classes' (`gadgets.GADGETS_Dummy`).
pub const DOCKLET_Dummy = utility.TAG_USER + 0x0500_0000;
/// `[*:0]const u8`, read: the docklet's name, "Clock". The docklet's.
pub const DOCKLET_Title = DOCKLET_Dummy + 0x01;
/// `[*:0]const u8`, read: what it shows now, in a few words - "14:05,
/// Tuesday 27-Oct-2026", "Battery 80%, charging". The docklet's, and
/// changed by the next look.
pub const DOCKLET_Text = DOCKLET_Dummy + 0x02;
/// `?[*:0]const u8`, read: the command a click on it runs - the program
/// that shows more, "SYS:System/CPULoad" - or null for none. The
/// docklet's.
pub const DOCKLET_Command = DOCKLET_Dummy + 0x03;
/// Read: how often it wants to look, in milliseconds.
pub const DOCKLET_Every = DOCKLET_Dummy + 0x04;
/// Set, its data passed over: look at the machine now. The set answers
/// non-zero when what it shows changed.
pub const DOCKLET_Look = DOCKLET_Dummy + 0x05;

/// The pens a docklet draws in, and the square it draws in: the drawn
/// pictures' own, in `gadgets.shapes`.
pub const Pens = gadgets.shapes.Pens;
pub const Frame = gadgets.shapes.Frame;

/// What a docklet is, for `DockletClass`.
pub fn Spec(comptime Instance: type) type {
    return struct {
        /// The library's name, which is also the class's: `clock.docklet`.
        name: [:0]const u8,
        version: u16,
        revision: u16 = 0,
        /// `dd.mm.yyyy`.
        date: []const u8,
        /// Its name, as the dock lists it (`DOCKLET_Title`).
        title: [*:0]const u8,
        /// What a click on it runs (`DOCKLET_Command`).
        command: ?[*:0]const u8 = null,
        /// How often it looks, in milliseconds (`DOCKLET_Every`).
        every: u32 = 1000,
        /// Libraries the class needs open while it is there.
        opens: []const [*:0]const u8 = &.{},
        /// What an object needs opened or found, when it is made; false
        /// and it is not made. `end` undoes it.
        begin: ?*const fn (base: *gadgets.Base, own: *Instance) bool = null,
        end: ?*const fn (base: *gadgets.Base, own: *Instance) void = null,
        /// The machine looked at: whether what it shows changed.
        look: *const fn (base: *gadgets.Base, own: *Instance) bool,
        /// What it shows, in words (`DOCKLET_Text`).
        text: *const fn (own: *Instance) [*:0]const u8,
        /// It drawn on `frame`.
        draw: *const fn (own: *Instance, frame: *const Frame) void,
    };
}

/// A docklet's class library: `Library.resident_tag` is its ROM tag. The
/// class answers what every docklet does - its title, text, command and
/// how often it looks, a look when set, drawing fitted or in its own box
/// - from `spec`, and the rest is imageclass's.
pub fn DockletClass(comptime Instance: type, comptime spec: Spec(Instance)) type {
    return struct {
        pub const Library = gadgets.ClassLibrary(.{
            .name = spec.name,
            .version = spec.version,
            .revision = spec.revision,
            .date = spec.date,
            .super = classusr.IMAGECLASS,
            .Instance = Instance,
            .dispatch = dispatch,
            .opens = spec.opens,
        });

        /// The class's dispatcher.
        pub fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
            const cl: *Class = @ptrCast(hook);
            const base = gadgets.baseOf(cl);
            const ib = base.intuition_base;
            const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
            const o: ?*Object = @ptrCast(object);
            switch (msg.method_id) {
                classusr.OM_NEW => {
                    const made = ib.SendSuperMessage(cl, o, msg);
                    if (made == 0) return 0;
                    const obj: *Object = @ptrFromInt(made);
                    const own = classes.instData(Instance, cl, obj);
                    own.* = .{};
                    if (spec.begin) |begin| if (!begin(base, own)) {
                        // Not begun: nothing for `end` to undo.
                        var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                        _ = ib.SendSuperMessage(cl, obj, &gone);
                        return 0;
                    };
                    _ = spec.look(base, own);
                    return made;
                },
                classusr.OM_DISPOSE => {
                    if (spec.end) |end| end(base, classes.instData(Instance, cl, o orelse return 0));
                    return ib.SendSuperMessage(cl, o, msg);
                },
                classusr.OM_GET => {
                    const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
                    const own = classes.instData(Instance, cl, o.?);
                    get.storage.* = switch (get.attr_id) {
                        DOCKLET_Title => @intFromPtr(spec.title),
                        DOCKLET_Text => @intFromPtr(spec.text(own)),
                        DOCKLET_Command => if (spec.command) |command| @intFromPtr(command) else 0,
                        DOCKLET_Every => spec.every,
                        else => return ib.SendSuperMessage(cl, o, msg),
                    };
                    return 1;
                },
                classusr.OM_SET, classusr.OM_UPDATE => {
                    const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
                    var changed = ib.SendSuperMessage(cl, o, msg);
                    if (base.utility_base.FindTagItem(DOCKLET_Look, set.attr_list) != null) {
                        if (spec.look(base, classes.instData(Instance, cl, o.?))) changed = 1;
                    }
                    return changed;
                },
                ic.IM_DRAW, ic.IM_DRAWFRAME => {
                    const draw: *ic.ImpDraw = @ptrCast(@alignCast(msg));
                    const image = classes.instData(ic.Image, cl.super.?, o.?);
                    const framed = msg.method_id == ic.IM_DRAWFRAME;
                    const width = if (framed) draw.dimensions.width else image.width;
                    const height = if (framed) draw.dimensions.height else image.height;
                    const size = @min(width, height);
                    if (size < 4) return 1;
                    const gb = base.graphics_base;
                    const rp = draw.rast_port;
                    const saved = gadgets.support.Saved.of(gb, rp);
                    defer saved.restore(gb, rp);
                    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 1 }, .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} });
                    defer gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 0 }, .{} });
                    // Centred in a box that is not square.
                    const frame = Frame{
                        .gb = gb,
                        .rp = rp,
                        .x = draw.offset.x + image.left + @divTrunc(width - size, 2),
                        .y = draw.offset.y + image.top + @divTrunc(height - size, 2),
                        .size = size,
                        .pens = Pens.of(draw.draw_info),
                    };
                    spec.draw(classes.instData(Instance, cl, o.?), &frame);
                    return 1;
                },
                else => return ib.SendSuperMessage(cl, o, msg),
            }
        }
    };
}

/// `args` written into `into` through a RawDoFmt `format`, checked
/// against it when compiled, cut to fit and NUL-terminated: a docklet's
/// words.
pub fn format(sys: *ExecBase, into: []u8, comptime fmt: [:0]const u8, args: anytype) [*:0]const u8 {
    comptime exec.checkFormat(fmt, @TypeOf(args));
    const stream = exec.fmtStream(args);
    return gadgets.support.formatInto(sys, fmt, &stream, into);
}

/// `words` copied into `into`, cut to fit and NUL-terminated.
pub fn say(into: []u8, words: []const u8) void {
    const n = @min(words.len, into.len - 1);
    @memcpy(into[0..n], words[0..n]);
    into[n] = 0;
}
