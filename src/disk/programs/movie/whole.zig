// SPDX-License-Identifier: MIT
//! The film over the whole screen: a borderless window as large as the
//! screen, black, in front of every window - those that stay in front, a
//! dock, too, as the newest of them (`WA_StayInFront`) - which the
//! pictures are put down in instead of the window's while it is open,
//! with no pointer over it.
//!
//! The keys that work the film work here too - the space bar, left and
//! right, up and down; F, Esc, a press of a button, or another window made
//! active over it close it (`messages`).

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const keyboard = sdk.devices.keyboard;
const ie = sdk.devices.inputevent;
const wn = intuition.windows;
const sc = intuition.screens;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const TagItem = utility.TagItem;

/// What the window was told: to close, or a key for the film.
pub const Told = union(enum) { nothing, close, key: u32, raw_key: u32 };

pub const Whole = struct {
    window: *intuition.Window,
    rast_port: *graphics.RastPort,
    port: *sdk.exec.MsgPort,
    width: i32,
    height: i32,

    /// The window opened over the whole of `screen`, black and active:
    /// null when it would not open.
    pub fn open(ib: *IntuitionBase, gb: *GraphicsBase, screen: *intuition.Screen) ?Whole {
        var width: usize = 0;
        var height: usize = 0;
        ib.GetScreenAttrs(screen, &[_]TagItem{
            .{ .tag = sc.SA_Width, .data = @intFromPtr(&width) },
            .{ .tag = sc.SA_Height, .data = @intFromPtr(&height) },
            .{},
        });
        if (width < 16 or height < 16) return null;
        const window = ib.OpenWindowTagList(&[_]TagItem{
            .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
            .{ .tag = wn.WA_Left, .data = 0 },
            .{ .tag = wn.WA_Top, .data = 0 },
            .{ .tag = wn.WA_Width, .data = width },
            .{ .tag = wn.WA_Height, .data = height },
            .{ .tag = wn.WA_Borderless, .data = 1 },
            .{ .tag = wn.WA_Activate, .data = 1 },
            .{ .tag = wn.WA_StayInFront, .data = 1 },
            .{ .tag = wn.WA_HidePointer, .data = 1 },
            .{ .tag = wn.WA_RMBTrap, .data = 1 },
            .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_VANILLAKEY | wn.IDCMP_RAWKEY | wn.IDCMP_MOUSEBUTTONS | wn.IDCMP_INACTIVEWINDOW },
            .{},
        }) orelse return null;
        var rast_port: usize = 0;
        var port: usize = 0;
        ib.GetWindowAttrs(window, &[_]TagItem{
            .{ .tag = wn.WA_RastPort, .data = @intFromPtr(&rast_port) },
            .{ .tag = wn.WA_UserPort, .data = @intFromPtr(&port) },
            .{},
        });
        if (rast_port == 0 or port == 0) {
            ib.CloseWindow(window);
            return null;
        }
        const whole = Whole{
            .window = window,
            .rast_port = @ptrFromInt(rast_port),
            .port = @ptrFromInt(port),
            .width = @intCast(width),
            .height = @intCast(height),
        };
        gb.SetRPAttrs(whole.rast_port, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(0, 0, 0) }, .{} });
        gb.RectFill(whole.rast_port, &.{ .max_x = whole.width, .max_y = whole.height });
        return whole;
    }

    pub fn close(whole: *Whole, ib: *IntuitionBase) void {
        ib.CloseWindow(whole.window);
    }

    pub fn signal(whole: *const Whole) u32 {
        return whole.port.sigMask();
    }

    /// The next of its messages answered: what it told, `nothing` once
    /// there are none left. A key going down is the film's, unless it
    /// closes; its going up is passed over.
    pub fn next(whole: *Whole, ib: *IntuitionBase) Told {
        while (ib.GetIMsg(whole.window)) |message| {
            const class = message.class;
            const code: u32 = message.code;
            ib.ReplyIMsg(message);
            switch (class) {
                wn.IDCMP_INACTIVEWINDOW => return .close,
                wn.IDCMP_VANILLAKEY => return switch (code) {
                    'f', 'F', 27 => .close,
                    else => .{ .key = code },
                },
                wn.IDCMP_RAWKEY => if (code & ie.IECODE_UP_PREFIX == 0) {
                    if (code == keyboard.RAWKEY_ESC) return .close;
                    return .{ .raw_key = code };
                },
                wn.IDCMP_MOUSEBUTTONS => if (code == wn.SELECTDOWN or code == wn.MENUDOWN or code == wn.MIDDLEDOWN) return .close,
                else => {},
            }
        }
        return .nothing;
    }
};
