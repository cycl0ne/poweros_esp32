// SPDX-License-Identifier: MIT
//! The cover large, in a window of its own, opened by a press on the
//! cover. The picture is a picture datatype object made from where the
//! cover came from - the bytes the tags hold, or the file beside the song
//! (cover.zig) - in a layout that keeps it in its shape (`CHILDA_Aspect`),
//! scaled to the room it is given (`PDTA_Scale`) and in the middle of it.
//! The window opens as large as the picture is, as much of that as the
//! screen has room for, and is sized like any other; its close gadget or
//! Esc close it.
//!
//! It shows the cover it was opened with: the next song leaves it as it
//! is, and a press on that song's cover shows the new one instead, where
//! the window was and as large as it was. A press on the cover it shows
//! brings it to the front.
//!
//! The picture lays itself out on a process of its own and says when it
//! has (`IDCMPUPDATE`); it is drawn again then.

const sdk = @import("sdk");
const utility = sdk.utility;
const intuition = sdk.intuition;
const wn = intuition.windows;
const wc = intuition.windowclass;
const lg = intuition.layoutgclass;
const icc = intuition.icclass;
const classusr = intuition.classusr;
const datatypes = sdk.datatypes;
const pic = datatypes.pictureclass;
const cover = @import("cover.zig");
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;

/// Where a window was and how large.
const Place = struct { left: i32, top: i32, width: i32, height: i32 };

/// What the window shows a song's cover with.
pub const Libraries = struct {
    ib: *IntuitionBase,
    dt: *DataTypesBase,
    screen: *intuition.Screen,
};

pub const Big = struct {
    /// The window object, and the window and the picture while it is open.
    object: ?*Object = null,
    window: ?*intuition.Window = null,
    picture: ?*Object = null,
    /// Which song's cover it shows, as the caller counts them.
    song: usize = 0,
    title: [96:0]u8 = @splat(0),
    /// Where the last one was and how large, for the next.
    place: ?Place = null,

    /// The window's signal, 0 while it is closed.
    pub fn signal(big: *const Big, ib: *IntuitionBase) u32 {
        const object = big.object orelse return 0;
        var mask: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_SigMask, object, &mask);
        return @truncate(mask);
    }

    /// The cover of `song` - `source`, `title` its window's title - shown:
    /// the window brought to the front when it shows it already, opened
    /// in place of the one there otherwise. False when it cannot be shown.
    pub fn show(big: *Big, libs: Libraries, song: usize, source: cover.Source, title: [*:0]const u8) bool {
        const ib = libs.ib;
        const dt = libs.dt;
        if (big.window) |window| {
            if (big.song == song) {
                ib.WindowToFront(window);
                ib.ActivateWindow(window);
                return true;
            }
        }
        big.close(ib);

        const picture = cover.objectOf(dt, source, &[_]TagItem{
            .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
            .{ .tag = pic.PDTA_Scale, .data = 1 },
            .{},
        }) orelse return false;
        var header: usize = 0;
        _ = dt.GetDTAttrsA(picture, &[_]TagItem{ .{ .tag = pic.PDTA_BitMapHeader, .data = @intFromPtr(&header) }, .{} });
        const shape: ?*const pic.BitMapHeader = @ptrFromInt(header);
        const wide: u16 = if (shape) |known| @max(known.width, 1) else 1;
        const high: u16 = if (shape) |known| @max(known.height, 1) else 1;
        // From here on the picture is the layout's, which disposes of
        // what is in it.
        const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(picture) },
            .{ .tag = lg.CHILDA_Aspect, .data = lg.aspect(wide, high) },
            .{ .tag = lg.CHILDA_Align, .data = lg.CALIGN_HCENTRE | lg.CALIGN_VCENTRE },
            .{},
        }) orelse {
            dt.DisposeDTObject(picture);
            return false;
        };

        var length: usize = 0;
        while (title[length] != 0 and length < big.title.len) : (length += 1) big.title[length] = title[length];
        big.title[length] = 0;
        const at = big.place;
        const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            .{ .tag = wn.WA_Title, .data = @intFromPtr(&big.title) },
            .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(libs.screen) },
            .{ .tag = if (at != null) wn.WA_Left else utility.TAG_IGNORE, .data = if (at) |p| @bitCast(@as(isize, p.left)) else 0 },
            .{ .tag = if (at != null) wn.WA_Top else utility.TAG_IGNORE, .data = if (at) |p| @bitCast(@as(isize, p.top)) else 0 },
            .{ .tag = if (at != null) wn.WA_Width else utility.TAG_IGNORE, .data = if (at) |p| @intCast(p.width) else 0 },
            .{ .tag = if (at != null) wn.WA_Height else utility.TAG_IGNORE, .data = if (at) |p| @intCast(p.height) else 0 },
            // A picture larger than the screen opens as large as it has
            // room for.
            .{ .tag = wn.WA_AutoAdjust, .data = 1 },
            .{ .tag = wn.WA_CloseGadget, .data = 1 },
            .{ .tag = wn.WA_DragBar, .data = 1 },
            .{ .tag = wn.WA_DepthGadget, .data = 1 },
            .{ .tag = wn.WA_SizeGadget, .data = 1 },
            .{ .tag = wn.WA_Activate, .data = 1 },
            .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE },
            .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
            .{},
        }) orelse {
            ib.DisposeObject(layout); // and the picture in it
            return false;
        };
        var open = wc.WmOpen{};
        const opened = ib.SendMessage(object, @ptrCast(&open));
        if (opened == 0) {
            ib.DisposeObject(object); // and the layout and the picture
            return false;
        }
        big.object = object;
        big.window = @ptrFromInt(opened);
        big.picture = picture;
        big.song = song;
        return true;
    }

    /// Everything the window says: false when it is to close.
    pub fn messages(big: *Big, libs: Libraries) bool {
        const object = big.object orelse return true;
        var code: u32 = 0;
        var handle = wc.WmHandleInput{ .code = &code };
        var laid_out = false;
        while (true) {
            const word = libs.ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return false,
                wc.WMHI_VANILLAKEY => if (word & wc.WMHI_KEYMASK == 27) return false,
                // The picture laid out on its own process: what is on the
                // screen was drawn from the layout before.
                wc.WMHI_IDCMPUPDATE => laid_out = true,
                else => {},
            }
        }
        if (laid_out) big.redraw(libs.dt);
        return true;
    }

    fn redraw(big: *const Big, dt: *DataTypesBase) void {
        const picture = big.picture orelse return;
        const window = big.window orelse return;
        dt.RefreshDTObjectA(picture, window, null, null);
    }

    /// The window closed, if it is open; where it was kept for the next.
    pub fn close(big: *Big, ib: *IntuitionBase) void {
        const object = big.object orelse return;
        if (big.window) |window| big.place = .{
            .left = windowAttr(ib, window, wn.WA_Left),
            .top = windowAttr(ib, window, wn.WA_Top),
            .width = windowAttr(ib, window, wn.WA_Width),
            .height = windowAttr(ib, window, wn.WA_Height),
        };
        ib.DisposeObject(object); // the window, the layout and the picture
        big.object = null;
        big.window = null;
        big.picture = null;
    }
};

/// One of the window's numbers.
fn windowAttr(ib: *IntuitionBase, window: *intuition.Window, attr: utility.Tag) i32 {
    var value: usize = 0;
    ib.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = attr, .data = @intFromPtr(&value) }, .{} });
    return @truncate(@as(isize, @bitCast(value)));
}
