// SPDX-License-Identifier: MIT
//! What a requester is while the library holds it: the structure the
//! program reads, the text it was answered with, and everything the tags
//! said about it.
//!
//! The public structure comes first in the allocation, so the pointer
//! `AllocAslRequest` hands out is the pointer to the whole and
//! `requesterOf` gets back from one to the other.
//!
//! The text fields are the requester's own buffers rather than the
//! program's: the program is told where they are and they hold until the
//! next request on that requester or until it is freed, which is what
//! lets a requester open again where it was left.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const asl = sdk.asl;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const AslBase = @import("../asl_base.zig").AslBase;
const TagItem = utility.TagItem;

/// The three public structures at one address: which one it is is the
/// requester's kind.
pub const Public = extern union {
    file: asl.FileRequester,
    font: asl.FontRequester,
    mode: asl.ScreenModeRequester,
};

/// Where a requester opens: on a window's screen, on a screen, or on the
/// public screen of that name.
pub const Where = extern struct {
    window: ?*intuition.Window = null,
    screen: ?*intuition.Screen = null,
    pub_screen: ?[*:0]const u8 = null,
    /// `ASLFR_SleepWindow`: the parent takes no input while it is up.
    sleep: u8 = 0,
    pad: [3]u8 = @splat(0),
};

/// The words on it, each null for the one the library chooses.
pub const Words = extern struct {
    title: ?[*:0]const u8 = null,
    positive: ?[*:0]const u8 = null,
    negative: ?[*:0]const u8 = null,
    text_attr: ?*const graphics.TextAttr = null,
};

/// Where it opens and how big, -1 for "wherever the screen puts it".
pub const Box = extern struct {
    left: i32 = -1,
    top: i32 = -1,
    width: i32 = 0,
    height: i32 = 0,
};

/// A requester the library made.
pub const Requester = extern struct {
    /// First, so that the program's pointer is this one.
    public: Public,
    node: exec.MinNode = .{},
    base: *AslBase,
    kind: u32 = 0,
    where: Where = .{},
    words: Words = .{},
    box: Box = .{},
    /// `ASLFR_Flags1` and `ASLFR_Flags2`, or the bools that set their
    /// bits one at a time.
    flags1: u32 = 0,
    flags2: u32 = 0,
    /// The hooks: one asked about every entry, one handed the messages
    /// the requester does not want itself.
    filter_func: ?*utility.Hook = null,
    intui_func: ?*utility.Hook = null,
    /// The patterns an entry must and must not match, as given.
    accept_pattern: ?[*:0]const u8 = null,
    reject_pattern: ?[*:0]const u8 = null,
    /// The file requester's three fields. They are what `public.file`
    /// points at.
    file: [dos.name_max + 1]u8 = @splat(0),
    drawer: [dos.path_max + 1]u8 = @splat(0),
    pattern: [dos.name_max + 1]u8 = @splat(0),
    /// A font requester's own: the family it starts on, how tall, and
    /// the limits on what it lists. The family is a buffer of the
    /// requester's, as the file requester's fields are.
    family: [dos.name_max + 1]u8 = @splat(0),
    size: u32 = 0,
    min_height: u32 = 0,
    max_height: u32 = 0,
    /// The colours the two pens are picked from, with how many each
    /// holds; null for the spread the requester offers of its own.
    front_pens: ?[*]const graphics.Pen = null,
    front_pen_count: u32 = 0,
    back_pens: ?[*]const graphics.Pen = null,
    back_pen_count: u32 = 0,
    /// A multi-select answer: the block holding the `WBArg`s and the
    /// names after them, and the one lock on the drawer they all name.
    /// Every pair carries that same lock, since every name picked is in
    /// the one drawer; it is the library's and is let go here.
    args: ?*anyopaque = null,
    arg_lock: ?*dos.FileLock = null,
};

/// The answer a request left behind, given back: a requester asked again
/// drops what the answer before it held, and so does `FreeAslRequest`.
pub fn dropArgs(r: *Requester) void {
    if (r.kind != asl.ASL_FileRequest) return;
    const sys = r.base.sys_base;
    if (r.args) |block| sys.FreeVec(block);
    r.args = null;
    if (r.arg_lock) |lock| r.base.dos_base.UnLock(lock);
    r.arg_lock = null;
    r.public.file.arg_list = null;
    r.public.file.num_args = 0;
}

/// The requester a program's pointer names.
pub fn requesterOf(handle: *anyopaque) *Requester {
    return @ptrCast(@alignCast(handle));
}

/// A NUL-terminated string copied into a buffer, cut to fit. Nothing for
/// null, which empties the buffer.
pub fn copyInto(into: []u8, text: ?[*:0]const u8) void {
    const from = text orelse {
        into[0] = 0;
        return;
    };
    var i: usize = 0;
    while (from[i] != 0 and i + 1 < into.len) : (i += 1) into[i] = from[i];
    into[i] = 0;
}

/// A bit of `flags` set or cleared as a bool tag says.
fn setFlag(flags: *u32, bit: u32, on: bool) void {
    if (on) flags.* |= bit else flags.* &= ~bit;
}

/// What `ASLFR_UserData` is set to, in whichever structure this is.
fn setUserData(r: *Requester, value: usize) void {
    switch (r.kind) {
        asl.ASL_FontRequest => r.public.font.user_data = value,
        asl.ASL_ScreenModeRequest => r.public.mode.user_data = value,
        else => r.public.file.user_data = value,
    }
}

/// The tags every kind of requester answers to, which are the same
/// numbers for all three. True when `item` was one of them.
fn takeCommonTag(r: *Requester, item: *const TagItem) bool {
    const v = item.data;
    const n: i32 = @bitCast(@as(u32, @truncate(v)));
    switch (item.tag) {
        asl.ASLFR_Window => r.where.window = @ptrFromInt(v),
        asl.ASLFR_Screen => r.where.screen = @ptrFromInt(v),
        asl.ASLFR_PubScreenName => r.where.pub_screen = @ptrFromInt(v),
        asl.ASLFR_SleepWindow => r.where.sleep = @intFromBool(v != 0),
        asl.ASLFR_IntuiMsgFunc => {
            r.intui_func = @ptrFromInt(v);
            setFlag(&r.flags1, asl.FRF_INTUIFUNC, v != 0);
        },
        asl.ASLFR_UserData => setUserData(r, v),
        asl.ASLFR_TextAttr => r.words.text_attr = @ptrFromInt(v),
        asl.ASLFR_TitleText => r.words.title = @ptrFromInt(v),
        asl.ASLFR_PositiveText => r.words.positive = @ptrFromInt(v),
        asl.ASLFR_NegativeText => r.words.negative = @ptrFromInt(v),
        asl.ASLFR_InitialLeftEdge => r.box.left = n,
        asl.ASLFR_InitialTopEdge => r.box.top = n,
        asl.ASLFR_InitialWidth => r.box.width = n,
        asl.ASLFR_InitialHeight => r.box.height = n,
        asl.ASLFR_FilterFunc => {
            r.filter_func = @ptrFromInt(v);
            setFlag(&r.flags1, asl.FRF_FILTERFUNC, v != 0);
        },
        else => return false,
    }
    return true;
}

/// The tags only a file requester answers to. Their numbers are shared
/// with the other two kinds' own tags, so which structure is being made
/// decides what a number means and each kind reads its own.
fn takeFileTag(r: *Requester, item: *const TagItem) void {
    const v = item.data;
    switch (item.tag) {
        asl.ASLFR_Flags1 => r.flags1 = @truncate(v),
        asl.ASLFR_Flags2 => r.flags2 = @truncate(v),
        asl.ASLFR_DoSaveMode => setFlag(&r.flags1, asl.FRF_DOSAVEMODE, v != 0),
        asl.ASLFR_DoMultiSelect => setFlag(&r.flags1, asl.FRF_DOMULTISELECT, v != 0),
        asl.ASLFR_DoPatterns => setFlag(&r.flags1, asl.FRF_DOPATTERNS, v != 0),
        asl.ASLFR_DrawersOnly => setFlag(&r.flags2, asl.FRF2_DRAWERSONLY, v != 0),
        asl.ASLFR_RejectIcons => setFlag(&r.flags2, asl.FRF2_REJECTICONS, v != 0),
        asl.ASLFR_FilterDrawers => setFlag(&r.flags2, asl.FRF2_FILTERDRAWERS, v != 0),
        asl.ASLFR_AcceptPattern => r.accept_pattern = @ptrFromInt(v),
        asl.ASLFR_RejectPattern => r.reject_pattern = @ptrFromInt(v),
        // The three fields are the requester's own buffers: what a tag
        // gives is copied into them.
        asl.ASLFR_InitialFile => copyInto(&r.file, @ptrFromInt(v)),
        asl.ASLFR_InitialDrawer => copyInto(&r.drawer, @ptrFromInt(v)),
        asl.ASLFR_InitialPattern => copyInto(&r.pattern, @ptrFromInt(v)),
        else => {},
    }
}

/// The tags only a font requester answers to. Their numbers are the
/// file requester's own tags' numbers, so the kind decides.
fn takeFontTag(r: *Requester, item: *const TagItem) void {
    const v = item.data;
    switch (item.tag) {
        asl.ASLFO_Flags => r.flags1 = @truncate(v),
        asl.ASLFO_DoFrontPen => setFlag(&r.flags1, asl.FOF_DOFRONTPEN, v != 0),
        asl.ASLFO_DoBackPen => setFlag(&r.flags1, asl.FOF_DOBACKPEN, v != 0),
        asl.ASLFO_DoStyle => setFlag(&r.flags1, asl.FOF_DOSTYLE, v != 0),
        asl.ASLFO_DoDrawMode => setFlag(&r.flags1, asl.FOF_DODRAWMODE, v != 0),
        asl.ASLFO_FixedWidthOnly => setFlag(&r.flags1, asl.FOF_FIXEDWIDTHONLY, v != 0),
        asl.ASLFO_MinHeight => r.min_height = @truncate(v),
        asl.ASLFO_MaxHeight => r.max_height = @truncate(v),
        asl.ASLFO_InitialName => copyInto(&r.family, @ptrFromInt(v)),
        asl.ASLFO_InitialSize => r.size = @truncate(v),
        asl.ASLFO_InitialStyle => r.public.font.attr.style = @truncate(v),
        asl.ASLFO_InitialFlags => r.public.font.attr.flags = @truncate(v),
        asl.ASLFO_InitialFrontPen => r.public.font.front_pen = @truncate(v),
        asl.ASLFO_InitialBackPen => r.public.font.back_pen = @truncate(v),
        asl.ASLFO_InitialDrawMode => r.public.font.draw_mode = @truncate(v),
        asl.ASLFO_FrontPens => r.front_pens = @ptrFromInt(v),
        asl.ASLFO_BackPens => r.back_pens = @ptrFromInt(v),
        asl.ASLFO_MaxFrontPen => r.front_pen_count = @truncate(v),
        asl.ASLFO_MaxBackPen => r.back_pen_count = @truncate(v),
        else => {},
    }
}

/// What the tags say, read by both `AllocAslRequest` and `AslRequest`.
pub fn takeTags(r: *Requester, tags: ?[*]const TagItem) void {
    const ub = r.base.utility_base;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        if (takeCommonTag(r, item)) continue;
        switch (r.kind) {
            asl.ASL_FileRequest => takeFileTag(r, item),
            asl.ASL_FontRequest => takeFontTag(r, item),
            // The screen mode requester reads its own in its item
            // (`todo/asl` 7).
            else => {},
        }
    }
    switch (r.kind) {
        asl.ASL_FileRequest => {
            r.public.file.file = @ptrCast(&r.file);
            r.public.file.drawer = @ptrCast(&r.drawer);
            r.public.file.pattern = @ptrCast(&r.pattern);
        },
        asl.ASL_FontRequest => {
            // The name is the requester's buffer, as the file
            // requester's fields are: what the program reads holds until
            // the next request on it.
            r.public.font.attr.name = @ptrCast(&r.family);
            r.public.font.attr.y_size = @truncate(r.size);
        },
        else => {},
    }
}
