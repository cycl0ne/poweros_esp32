// SPDX-License-Identifier: MIT
//! A name asked for: a small window over the desktop with what it is for,
//! a field holding the name as it is, and OK and Cancel - what Rename and
//! New Drawer ask with. The field is active as it opens, so the name can
//! be typed at once; Return in it is OK. The desktop waits for the answer.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const intuition = sdk.intuition;
const wn = intuition.windows;
const wc = intuition.windowclass;
const lg = intuition.layoutgclass;
const gc = intuition.gadgetclass;
const classusr = intuition.classusr;
const st = sdk.gadgets.string;
const tx = sdk.gadgets.text;
const TagItem = utility.TagItem;
const Object = intuition.Object;
const Desktop = @import("_desktop.zig").Desktop;

const ID_FIELD = 1;
const ID_OK = 2;
const ID_CANCEL = 3;

fn pair(tag: utility.Tag, data: usize) TagItem {
    return .{ .tag = tag, .data = data };
}

/// A name asked for under `title`, `prompt` above a field holding
/// `start`; the answer in `into`, NUL after it - its length, or null when
/// it was cancelled, left empty, or the gadgets cannot be had.
pub fn name(d: *Desktop, title: [*:0]const u8, prompt: [*:0]const u8, start: []const u8, into: *[dos.name_max + 1]u8) ?usize {
    const ib = d.ib;
    const string_lib = d.sys.OpenLibrary(st.STRING_LIBRARY, 0) orelse return null;
    defer d.sys.CloseLibrary(string_lib);
    const text_lib = d.sys.OpenLibrary(tx.TEXT_LIBRARY, 0) orelse return null;
    defer d.sys.CloseLibrary(text_lib);

    var shown: [dos.name_max + 1:0]u8 = @splat(0);
    @memcpy(shown[0..@min(start.len, dos.name_max)], start[0..@min(start.len, dos.name_max)]);
    const label = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(prompt)), .{} });
    const field = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_FIELD),
        pair(gc.GA_RelVerify, 1),
        pair(gc.STRINGA_MaxChars, dos.name_max),
        pair(gc.STRINGA_TextVal, @intFromPtr(&shown)),
        // The cursor after the name, to be typed on or rubbed out.
        pair(gc.STRINGA_BufferPos, @min(start.len, dos.name_max)),
        .{},
    });
    const buttons = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{ pair(gc.GA_Text, @intFromPtr("_OK")), pair(gc.GA_ID, ID_OK), pair(gc.GA_RelVerify, 1), .{} }))),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{ pair(gc.GA_Text, @intFromPtr("_Cancel")), pair(gc.GA_ID, ID_CANCEL), pair(gc.GA_RelVerify, 1), .{} }))),
        .{},
    });
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(label)),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(field)),
        pair(lg.CHILDA_MinWidth, 280),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(buttons)),
        pair(lg.CHILDA_WeightHeight, 0),
        .{},
    }) orelse return null;
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr(title)),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wn.WA_Position, wn.WPOS_CENTERSCREEN),
        pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        return null;
    };
    defer ib.DisposeObject(object);
    var opening = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&opening)) == 0) return null;
    var window_ptr: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_ptr);
    const window: *intuition.Window = @ptrFromInt(window_ptr);
    if (field) |given| _ = ib.ActivateGadget(given, window, null);

    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    const accepted = loop: while (true) {
        _ = ib.WaitIMsg(window, 0);
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => break :loop false,
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_OK, ID_FIELD => break :loop true,
                    ID_CANCEL => break :loop false,
                    else => {},
                },
                else => {},
            }
        }
    };
    if (!accepted) return null;
    var typed: usize = 0;
    _ = ib.GetAttr(gc.STRINGA_TextVal, field.?, &typed);
    if (typed == 0) return null;
    const text: [*:0]const u8 = @ptrFromInt(typed);
    var length: usize = 0;
    while (text[length] != 0 and length < dos.name_max) : (length += 1) into[length] = text[length];
    into[length] = 0;
    if (length == 0) return null;
    return length;
}
