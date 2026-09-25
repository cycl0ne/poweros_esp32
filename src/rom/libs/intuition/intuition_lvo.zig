// SPDX-License-Identifier: MPL-2.0
//! intuition.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures at compile time, the slots and the
//! forwarding in the tests at the end.
//!
//! Each wrapper is the slot a caller reaches through the table. It hands
//! the work to the call - a file of its own in the folder for its area -
//! with the library's base first, casting a window or a screen from the
//! SDK's opaque type to the structure the library keeps behind it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const Class = intuition.Class;
const Object = intuition.Object;
const Msg = intuition.Msg;
const TagItem = utility.TagItem;
const vec = exec.vec;
const intuition_base = @import("intuition_base.zig");
const IntuitionBase = intuition_base.IntuitionBase;

const MakeClass = @import("boopsi/makeclass.zig").MakeClass;
const FreeClass = @import("boopsi/freeclass.zig").FreeClass;
const AddClass = @import("boopsi/addclass.zig").AddClass;
const RemoveClass = @import("boopsi/removeclass.zig").RemoveClass;
const FindClass = @import("boopsi/findclass.zig").FindClass;
const LockClassList = @import("boopsi/lockclasslist.zig").LockClassList;
const UnlockClassList = @import("boopsi/unlockclasslist.zig").UnlockClassList;
const NewObjectTagList = @import("boopsi/newobjecttaglist.zig").NewObjectTagList;
const DisposeObject = @import("boopsi/disposeobject.zig").DisposeObject;
const SetAttrsTagList = @import("boopsi/setattrstaglist.zig").SetAttrsTagList;
const GetAttr = @import("boopsi/getattr.zig").GetAttr;
const NextObject = @import("boopsi/nextobject.zig").NextObject;
const SendMessage = @import("boopsi/sendmessage.zig").SendMessage;
const SendSuperMessage = @import("boopsi/sendsupermessage.zig").SendSuperMessage;
const CoerceMessage = @import("boopsi/coercemessage.zig").CoerceMessage;
const DrawImage = @import("image/drawimage.zig").DrawImage;
const DrawImageState = @import("image/drawimagestate.zig").DrawImageState;
const EraseImage = @import("image/eraseimage.zig").EraseImage;
const PointInImage = @import("image/pointinimage.zig").PointInImage;
const OpenScreenTagList = @import("screen/openscreentaglist.zig").OpenScreenTagList;
const CloseScreen = @import("screen/closescreen.zig").CloseScreen;
const GetScreenAttrs = @import("screen/getscreenattrs.zig").GetScreenAttrs;
const ScreenToFront = @import("screen/screentofront.zig").ScreenToFront;
const ScreenToBack = @import("screen/screentoback.zig").ScreenToBack;
const GetScreenDrawInfo = @import("screen/getscreendrawinfo.zig").GetScreenDrawInfo;
const FreeScreenDrawInfo = @import("screen/freescreendrawinfo.zig").FreeScreenDrawInfo;
const LockPubScreen = @import("screen/lockpubscreen.zig").LockPubScreen;
const UnlockPubScreen = @import("screen/unlockpubscreen.zig").UnlockPubScreen;
const OpenWindowTagList = @import("window/openwindowtaglist.zig").OpenWindowTagList;
const CloseWindow = @import("window/closewindow.zig").CloseWindow;
const GetWindowAttrs = @import("window/getwindowattrs.zig").GetWindowAttrs;
const MoveWindow = @import("window/movewindow.zig").MoveWindow;
const SizeWindow = @import("window/sizewindow.zig").SizeWindow;
const ChangeWindowBox = @import("window/changewindowbox.zig").ChangeWindowBox;
const WindowToFront = @import("window/windowtofront.zig").WindowToFront;
const WindowToBack = @import("window/windowtoback.zig").WindowToBack;
const ActivateWindow = @import("window/activatewindow.zig").ActivateWindow;
const ModifyIDCMP = @import("window/modifyidcmp.zig").ModifyIDCMP;
const BeginRefresh = @import("window/beginrefresh.zig").BeginRefresh;
const EndRefresh = @import("window/endrefresh.zig").EndRefresh;
const RefreshWindowFrame = @import("window/refreshwindowframe.zig").RefreshWindowFrame;
const AddGList = @import("gadget/addglist.zig").AddGList;
const RemoveGList = @import("gadget/removeglist.zig").RemoveGList;
const RefreshGList = @import("gadget/refreshglist.zig").RefreshGList;
const SetGadgetAttrsTagList = @import("gadget/setgadgetattrstaglist.zig").SetGadgetAttrsTagList;
const ObtainGIRPort = @import("gadget/obtaingirport.zig").ObtainGIRPort;
const ReleaseGIRPort = @import("gadget/releasegirport.zig").ReleaseGIRPort;
const PrintIText = @import("render/printitext.zig").PrintIText;
const DrawBorder = @import("render/drawborder.zig").DrawBorder;
const IntuiTextLength = @import("render/intuitextlength.zig").IntuiTextLength;
const LockIBase = @import("ibase/lockibase.zig").LockIBase;
const UnlockIBase = @import("ibase/unlockibase.zig").UnlockIBase;
const ZipWindow = @import("window/zipwindow.zig").ZipWindow;
const SetWindowTitles = @import("window/setwindowtitles.zig").SetWindowTitles;
const WindowLimits = @import("window/windowlimits.zig").WindowLimits;
const OnGadget = @import("gadget/ongadget.zig").OnGadget;
const OffGadget = @import("gadget/offgadget.zig").OffGadget;
const EasyRequestArgs = @import("request/easyrequestargs.zig").EasyRequestArgs;
const BuildEasyRequestArgs = @import("request/buildeasyrequestargs.zig").BuildEasyRequestArgs;
const SysReqHandler = @import("request/sysreqhandler.zig").SysReqHandler;
const FreeSysRequest = @import("request/freesysrequest.zig").FreeSysRequest;
const SetMenuStrip = @import("menu/setmenustrip.zig").SetMenuStrip;
const ClearMenuStrip = @import("menu/clearmenustrip.zig").ClearMenuStrip;
const ResetMenuStrip = @import("menu/resetmenustrip.zig").ResetMenuStrip;
const ItemAddress = @import("menu/itemaddress.zig").ItemAddress;
const OnMenu = @import("menu/onmenu.zig").OnMenu;
const OffMenu = @import("menu/offmenu.zig").OffMenu;
const LendMenus = @import("menu/lendmenus.zig").LendMenus;
const ActivateGadget = @import("gadget/activategadget.zig").ActivateGadget;
const DoGadgetMethodA = @import("gadget/dogadgetmethoda.zig").DoGadgetMethodA;
const InitRequester = @import("requester/initrequester.zig").InitRequester;
const Request = @import("requester/request.zig").Request;
const EndRequest = @import("requester/endrequest.zig").EndRequest;
const SetDMRequest = @import("requester/setdmrequest.zig").SetDMRequest;
const ClearDMRequest = @import("requester/cleardmrequest.zig").ClearDMRequest;
const AutoRequestTagList = @import("request/autorequesttaglist.zig").AutoRequestTagList;
const BuildSysRequestTagList = @import("request/buildsysrequesttaglist.zig").BuildSysRequestTagList;
const DoubleClick = @import("input/doubleclick.zig").DoubleClick;
const GetIMsg = @import("window/getimsg.zig").GetIMsg;
const ReplyIMsg = @import("window/replyimsg.zig").ReplyIMsg;
const WaitIMsg = @import("window/waitimsg.zig").WaitIMsg;
const MoveWindowInFrontOf = @import("window/movewindowinfrontof.zig").MoveWindowInFrontOf;
const ScrollWindowRaster = @import("window/scrollwindowraster.zig").ScrollWindowRaster;
const SetMouseQueue = @import("window/setmousequeue.zig").SetMouseQueue;
const ReportMouse = @import("window/reportmouse.zig").ReportMouse;
const LockPubScreenList = @import("screen/lockpubscreenlist.zig").LockPubScreenList;
const UnlockPubScreenList = @import("screen/unlockpubscreenlist.zig").UnlockPubScreenList;
const NextPubScreen = @import("screen/nextpubscreen.zig").NextPubScreen;
const SetDefaultPubScreen = @import("screen/setdefaultpubscreen.zig").SetDefaultPubScreen;
const GetDefaultPubScreen = @import("screen/getdefaultpubscreen.zig").GetDefaultPubScreen;
const SetPubScreenModes = @import("screen/setpubscreenmodes.zig").SetPubScreenModes;
const PubScreenStatus = @import("screen/pubscreenstatus.zig").PubScreenStatus;
const ScreenDepth = @import("screen/screendepth.zig").ScreenDepth;
const ShowTitle = @import("screen/showtitle.zig").ShowTitle;
const AllocScreenBuffer = @import("screen/allocscreenbuffer.zig").AllocScreenBuffer;
const ChangeScreenBuffer = @import("screen/changescreenbuffer.zig").ChangeScreenBuffer;
const FreeScreenBuffer = @import("screen/freescreenbuffer.zig").FreeScreenBuffer;
const DisplayBeep = @import("misc/displaybeep.zig").DisplayBeep;
const CurrentTime = @import("misc/currenttime.zig").CurrentTime;
const DisplayAlert = @import("misc/displayalert.zig").DisplayAlert;
const TimedDisplayAlert = @import("misc/timeddisplayalert.zig").TimedDisplayAlert;
const HelpControl = @import("gadget/helpcontrol.zig").HelpControl;
const SetEditHook = @import("gadget/setedithook.zig").SetEditHook;
const GadgetMouse = @import("gadget/gadgetmouse.zig").GadgetMouse;

/// Its functions, as the SDK has them (sdk/fd/intuition_lib.fd).
const interface = sdk.interface.intuition;

/// Each function's offset in the jump table.
const LVO = interface.LVO;

// Every function in LVO is an lvo* function here, with the SDK's
// signature, in its slot.
comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("intuition.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(50_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "intuition.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`: every
/// call of the table.
const contract_files = [_][]const u8{
    @embedFile("boopsi/makeclass.zig"),
    @embedFile("boopsi/freeclass.zig"),
    @embedFile("boopsi/addclass.zig"),
    @embedFile("boopsi/removeclass.zig"),
    @embedFile("boopsi/findclass.zig"),
    @embedFile("boopsi/lockclasslist.zig"),
    @embedFile("boopsi/unlockclasslist.zig"),
    @embedFile("boopsi/newobjecttaglist.zig"),
    @embedFile("boopsi/disposeobject.zig"),
    @embedFile("boopsi/setattrstaglist.zig"),
    @embedFile("boopsi/getattr.zig"),
    @embedFile("boopsi/nextobject.zig"),
    @embedFile("boopsi/sendmessage.zig"),
    @embedFile("boopsi/sendsupermessage.zig"),
    @embedFile("boopsi/coercemessage.zig"),
    @embedFile("image/drawimage.zig"),
    @embedFile("image/drawimagestate.zig"),
    @embedFile("image/eraseimage.zig"),
    @embedFile("image/pointinimage.zig"),
    @embedFile("screen/openscreentaglist.zig"),
    @embedFile("screen/closescreen.zig"),
    @embedFile("screen/getscreenattrs.zig"),
    @embedFile("screen/screentofront.zig"),
    @embedFile("screen/screentoback.zig"),
    @embedFile("screen/getscreendrawinfo.zig"),
    @embedFile("screen/freescreendrawinfo.zig"),
    @embedFile("screen/lockpubscreen.zig"),
    @embedFile("screen/unlockpubscreen.zig"),
    @embedFile("window/openwindowtaglist.zig"),
    @embedFile("window/closewindow.zig"),
    @embedFile("window/getwindowattrs.zig"),
    @embedFile("window/movewindow.zig"),
    @embedFile("window/sizewindow.zig"),
    @embedFile("window/changewindowbox.zig"),
    @embedFile("window/windowtofront.zig"),
    @embedFile("window/windowtoback.zig"),
    @embedFile("window/activatewindow.zig"),
    @embedFile("window/modifyidcmp.zig"),
    @embedFile("window/beginrefresh.zig"),
    @embedFile("window/endrefresh.zig"),
    @embedFile("window/refreshwindowframe.zig"),
    @embedFile("gadget/addglist.zig"),
    @embedFile("gadget/removeglist.zig"),
    @embedFile("gadget/refreshglist.zig"),
    @embedFile("gadget/setgadgetattrstaglist.zig"),
    @embedFile("gadget/obtaingirport.zig"),
    @embedFile("gadget/releasegirport.zig"),
    @embedFile("render/printitext.zig"),
    @embedFile("render/drawborder.zig"),
    @embedFile("render/intuitextlength.zig"),
    @embedFile("ibase/lockibase.zig"),
    @embedFile("ibase/unlockibase.zig"),
    @embedFile("window/zipwindow.zig"),
    @embedFile("window/setwindowtitles.zig"),
    @embedFile("window/windowlimits.zig"),
    @embedFile("gadget/ongadget.zig"),
    @embedFile("gadget/offgadget.zig"),
    @embedFile("request/easyrequestargs.zig"),
    @embedFile("request/buildeasyrequestargs.zig"),
    @embedFile("request/sysreqhandler.zig"),
    @embedFile("request/freesysrequest.zig"),
    @embedFile("menu/setmenustrip.zig"),
    @embedFile("menu/clearmenustrip.zig"),
    @embedFile("menu/resetmenustrip.zig"),
    @embedFile("menu/itemaddress.zig"),
    @embedFile("menu/onmenu.zig"),
    @embedFile("menu/offmenu.zig"),
    @embedFile("menu/lendmenus.zig"),
    @embedFile("gadget/activategadget.zig"),
    @embedFile("gadget/dogadgetmethoda.zig"),
    @embedFile("requester/initrequester.zig"),
    @embedFile("requester/request.zig"),
    @embedFile("requester/endrequest.zig"),
    @embedFile("requester/setdmrequest.zig"),
    @embedFile("requester/cleardmrequest.zig"),
    @embedFile("request/autorequesttaglist.zig"),
    @embedFile("request/buildsysrequesttaglist.zig"),
    @embedFile("input/doubleclick.zig"),
};

fn lvoMakeClass(ib: *IntuitionBase, class_id: ?[*:0]const u8, super_id: ?[*:0]const u8, super_class: ?*Class, inst_size: u32) callconv(.c) ?*Class {
    return MakeClass(ib, class_id, super_id, super_class, inst_size);
}
fn lvoFreeClass(ib: *IntuitionBase, cl: ?*Class) callconv(.c) bool {
    return FreeClass(ib, cl);
}
fn lvoAddClass(ib: *IntuitionBase, cl: *Class) callconv(.c) void {
    AddClass(ib, cl);
}
fn lvoRemoveClass(ib: *IntuitionBase, cl: *Class) callconv(.c) void {
    RemoveClass(ib, cl);
}
fn lvoFindClass(ib: *IntuitionBase, class_id: [*:0]const u8) callconv(.c) ?*Class {
    return FindClass(ib, class_id);
}
fn lvoLockClassList(ib: *IntuitionBase) callconv(.c) *exec.MinList {
    return LockClassList(ib);
}
fn lvoUnlockClassList(ib: *IntuitionBase) callconv(.c) void {
    UnlockClassList(ib);
}
fn lvoNewObjectTagList(ib: *IntuitionBase, cl: ?*Class, class_id: ?[*:0]const u8, tags: ?[*]const TagItem) callconv(.c) ?*Object {
    return NewObjectTagList(ib, cl, class_id, tags);
}
fn lvoDisposeObject(ib: *IntuitionBase, object: ?*Object) callconv(.c) void {
    DisposeObject(ib, object);
}
fn lvoSetAttrsTagList(ib: *IntuitionBase, object: ?*Object, tags: ?[*]const TagItem) callconv(.c) u32 {
    return SetAttrsTagList(ib, object, tags);
}
fn lvoGetAttr(ib: *IntuitionBase, attr_id: utility.Tag, object: ?*Object, storage: *usize) callconv(.c) u32 {
    return GetAttr(ib, attr_id, object, storage);
}
fn lvoNextObject(ib: *IntuitionBase, state: *?*exec.MinNode) callconv(.c) ?*Object {
    return NextObject(ib, state);
}
fn lvoSendMessage(ib: *IntuitionBase, object: ?*Object, msg: *Msg) callconv(.c) usize {
    return SendMessage(ib, object, msg);
}
fn lvoSendSuperMessage(ib: *IntuitionBase, cl: *Class, object: ?*Object, msg: *Msg) callconv(.c) usize {
    return SendSuperMessage(ib, cl, object, msg);
}
fn lvoCoerceMessage(ib: *IntuitionBase, cl: *Class, object: ?*Object, msg: *Msg) callconv(.c) usize {
    return CoerceMessage(ib, cl, object, msg);
}
fn lvoDrawImage(ib: *IntuitionBase, rp: *graphics.RastPort, image: ?*Object, left: i32, top: i32) callconv(.c) void {
    DrawImage(ib, rp, image, left, top);
}
fn lvoDrawImageState(ib: *IntuitionBase, rp: *graphics.RastPort, image: ?*Object, left: i32, top: i32, state: u32, draw_info: ?*intuition.imageclass.DrawInfo) callconv(.c) void {
    DrawImageState(ib, rp, image, left, top, state, draw_info);
}
fn lvoEraseImage(ib: *IntuitionBase, rp: *graphics.RastPort, image: ?*Object, left: i32, top: i32) callconv(.c) void {
    EraseImage(ib, rp, image, left, top);
}
fn lvoPointInImage(ib: *IntuitionBase, x: i32, y: i32, image: ?*Object) callconv(.c) bool {
    return PointInImage(ib, x, y, image);
}
fn lvoOpenScreenTagList(ib: *IntuitionBase, tags: ?[*]const TagItem) callconv(.c) ?*intuition.Screen {
    return @ptrCast(OpenScreenTagList(ib, tags));
}
fn lvoCloseScreen(ib: *IntuitionBase, screen: ?*intuition.Screen) callconv(.c) bool {
    return CloseScreen(ib, @ptrCast(@alignCast(screen)));
}
fn lvoGetScreenAttrs(ib: *IntuitionBase, screen: *intuition.Screen, tags: ?[*]const TagItem) callconv(.c) void {
    GetScreenAttrs(ib, @ptrCast(@alignCast(screen)), tags);
}
fn lvoScreenToFront(ib: *IntuitionBase, screen: *intuition.Screen) callconv(.c) void {
    ScreenToFront(ib, @ptrCast(@alignCast(screen)));
}
fn lvoScreenToBack(ib: *IntuitionBase, screen: *intuition.Screen) callconv(.c) void {
    ScreenToBack(ib, @ptrCast(@alignCast(screen)));
}
fn lvoGetScreenDrawInfo(ib: *IntuitionBase, screen: *intuition.Screen) callconv(.c) *intuition.DrawInfo {
    return GetScreenDrawInfo(ib, @ptrCast(@alignCast(screen)));
}
fn lvoFreeScreenDrawInfo(ib: *IntuitionBase, screen: *intuition.Screen, draw_info: ?*intuition.DrawInfo) callconv(.c) void {
    FreeScreenDrawInfo(ib, @ptrCast(@alignCast(screen)), draw_info);
}
fn lvoLockPubScreen(ib: *IntuitionBase, name: ?[*:0]const u8) callconv(.c) ?*intuition.Screen {
    return @ptrCast(LockPubScreen(ib, name));
}
fn lvoUnlockPubScreen(ib: *IntuitionBase, name: ?[*:0]const u8, screen: ?*intuition.Screen) callconv(.c) void {
    UnlockPubScreen(ib, name, @ptrCast(@alignCast(screen)));
}
fn lvoOpenWindowTagList(ib: *IntuitionBase, tags: ?[*]const TagItem) callconv(.c) ?*intuition.Window {
    return @ptrCast(OpenWindowTagList(ib, tags));
}
fn lvoCloseWindow(ib: *IntuitionBase, window: ?*intuition.Window) callconv(.c) void {
    CloseWindow(ib, @ptrCast(@alignCast(window)));
}
fn lvoGetWindowAttrs(ib: *IntuitionBase, window: *intuition.Window, tags: ?[*]const TagItem) callconv(.c) void {
    GetWindowAttrs(ib, @ptrCast(@alignCast(window)), tags);
}
fn lvoMoveWindow(ib: *IntuitionBase, window: *intuition.Window, dx: i32, dy: i32) callconv(.c) void {
    MoveWindow(ib, @ptrCast(@alignCast(window)), dx, dy);
}
fn lvoSizeWindow(ib: *IntuitionBase, window: *intuition.Window, dw: i32, dh: i32) callconv(.c) void {
    SizeWindow(ib, @ptrCast(@alignCast(window)), dw, dh);
}
fn lvoChangeWindowBox(ib: *IntuitionBase, window: *intuition.Window, left: i32, top: i32, width: i32, height: i32) callconv(.c) void {
    ChangeWindowBox(ib, @ptrCast(@alignCast(window)), left, top, width, height);
}
fn lvoWindowToFront(ib: *IntuitionBase, window: *intuition.Window) callconv(.c) void {
    WindowToFront(ib, @ptrCast(@alignCast(window)));
}
fn lvoWindowToBack(ib: *IntuitionBase, window: *intuition.Window) callconv(.c) void {
    WindowToBack(ib, @ptrCast(@alignCast(window)));
}
fn lvoActivateWindow(ib: *IntuitionBase, window: *intuition.Window) callconv(.c) void {
    ActivateWindow(ib, @ptrCast(@alignCast(window)));
}
fn lvoModifyIDCMP(ib: *IntuitionBase, window: *intuition.Window, flags: u32) callconv(.c) bool {
    return ModifyIDCMP(ib, @ptrCast(@alignCast(window)), flags);
}
fn lvoBeginRefresh(ib: *IntuitionBase, window: *intuition.Window) callconv(.c) void {
    BeginRefresh(ib, @ptrCast(@alignCast(window)));
}
fn lvoEndRefresh(ib: *IntuitionBase, window: *intuition.Window, complete: bool) callconv(.c) void {
    EndRefresh(ib, @ptrCast(@alignCast(window)), complete);
}
fn lvoRefreshWindowFrame(ib: *IntuitionBase, window: *intuition.Window) callconv(.c) void {
    RefreshWindowFrame(ib, @ptrCast(@alignCast(window)));
}
fn lvoAddGList(ib: *IntuitionBase, window: *intuition.Window, gadget: *Object, position: i32, count: i32) callconv(.c) u32 {
    return AddGList(ib, @ptrCast(@alignCast(window)), gadget, position, count);
}
fn lvoRemoveGList(ib: *IntuitionBase, window: *intuition.Window, gadget: *Object, count: i32) callconv(.c) i32 {
    return RemoveGList(ib, @ptrCast(@alignCast(window)), gadget, count);
}
fn lvoRefreshGList(ib: *IntuitionBase, gadget: *Object, window: *intuition.Window, count: i32) callconv(.c) void {
    RefreshGList(ib, gadget, @ptrCast(@alignCast(window)), count);
}
fn lvoSetGadgetAttrsTagList(ib: *IntuitionBase, gadget: *Object, window: ?*intuition.Window, tags: ?[*]const TagItem) callconv(.c) usize {
    return SetGadgetAttrsTagList(ib, gadget, @ptrCast(@alignCast(window)), tags);
}
fn lvoObtainGIRPort(ib: *IntuitionBase, gadget_info: ?*intuition.GadgetInfo) callconv(.c) ?*graphics.RastPort {
    return ObtainGIRPort(ib, gadget_info);
}
fn lvoReleaseGIRPort(ib: *IntuitionBase, rp: ?*graphics.RastPort) callconv(.c) void {
    ReleaseGIRPort(ib, rp);
}
fn lvoPrintIText(ib: *IntuitionBase, rp: *graphics.RastPort, itext: ?*const intuition.IntuiText, left: i32, top: i32) callconv(.c) void {
    PrintIText(ib, rp, itext, left, top);
}
fn lvoDrawBorder(ib: *IntuitionBase, rp: *graphics.RastPort, border: ?*const intuition.Border, left: i32, top: i32) callconv(.c) void {
    DrawBorder(ib, rp, border, left, top);
}
fn lvoIntuiTextLength(ib: *IntuitionBase, itext: *const intuition.IntuiText) callconv(.c) i32 {
    return IntuiTextLength(ib, itext);
}
fn lvoLockIBase(ib: *IntuitionBase, lock_number: u32) callconv(.c) u32 {
    return LockIBase(ib, lock_number);
}
fn lvoUnlockIBase(ib: *IntuitionBase, lock_number: u32) callconv(.c) void {
    UnlockIBase(ib, lock_number);
}
fn lvoZipWindow(ib: *IntuitionBase, window: *intuition.Window) callconv(.c) void {
    ZipWindow(ib, @ptrCast(@alignCast(window)));
}
fn lvoSetWindowTitles(ib: *IntuitionBase, window: *intuition.Window, window_title: ?[*:0]const u8, screen_title: ?[*:0]const u8) callconv(.c) void {
    SetWindowTitles(ib, @ptrCast(@alignCast(window)), window_title, screen_title);
}
fn lvoWindowLimits(ib: *IntuitionBase, window: *intuition.Window, min_width: i32, min_height: i32, max_width: i32, max_height: i32) callconv(.c) bool {
    return WindowLimits(ib, @ptrCast(@alignCast(window)), min_width, min_height, max_width, max_height);
}
fn lvoOnGadget(ib: *IntuitionBase, gadget: *Object, window: *intuition.Window, requester: ?*intuition.Requester) callconv(.c) void {
    OnGadget(ib, gadget, @ptrCast(@alignCast(window)), requester);
}
fn lvoOffGadget(ib: *IntuitionBase, gadget: *Object, window: *intuition.Window, requester: ?*intuition.Requester) callconv(.c) void {
    OffGadget(ib, gadget, @ptrCast(@alignCast(window)), requester);
}
fn lvoEasyRequestArgs(ib: *IntuitionBase, window: ?*intuition.Window, easy_struct: *const intuition.EasyStruct, idcmp_ptr: ?*u32, args: ?*const anyopaque) callconv(.c) i32 {
    return EasyRequestArgs(ib, @ptrCast(@alignCast(window)), easy_struct, idcmp_ptr, args);
}
fn lvoBuildEasyRequestArgs(ib: *IntuitionBase, window: ?*intuition.Window, easy_struct: *const intuition.EasyStruct, idcmp: u32, args: ?*const anyopaque) callconv(.c) ?*intuition.Window {
    return @ptrCast(BuildEasyRequestArgs(ib, @ptrCast(@alignCast(window)), easy_struct, idcmp, args));
}
fn lvoSysReqHandler(ib: *IntuitionBase, window: ?*intuition.Window, idcmp_ptr: ?*u32, wait_input: bool) callconv(.c) i32 {
    return SysReqHandler(ib, @ptrCast(@alignCast(window)), idcmp_ptr, wait_input);
}
fn lvoFreeSysRequest(ib: *IntuitionBase, window: ?*intuition.Window) callconv(.c) void {
    FreeSysRequest(ib, @ptrCast(@alignCast(window)));
}
fn lvoSetMenuStrip(ib: *IntuitionBase, window: *intuition.Window, menu_strip: *intuition.Menu) callconv(.c) bool {
    return SetMenuStrip(ib, @ptrCast(@alignCast(window)), menu_strip);
}
fn lvoClearMenuStrip(ib: *IntuitionBase, window: *intuition.Window) callconv(.c) void {
    ClearMenuStrip(ib, @ptrCast(@alignCast(window)));
}
fn lvoResetMenuStrip(ib: *IntuitionBase, window: *intuition.Window, menu_strip: *intuition.Menu) callconv(.c) bool {
    return ResetMenuStrip(ib, @ptrCast(@alignCast(window)), menu_strip);
}
fn lvoItemAddress(ib: *IntuitionBase, menu_strip: ?*intuition.Menu, menu_number: u32) callconv(.c) ?*intuition.MenuItem {
    return ItemAddress(ib, menu_strip, menu_number);
}
fn lvoOnMenu(ib: *IntuitionBase, window: *intuition.Window, menu_number: u32) callconv(.c) void {
    OnMenu(ib, @ptrCast(@alignCast(window)), menu_number);
}
fn lvoOffMenu(ib: *IntuitionBase, window: *intuition.Window, menu_number: u32) callconv(.c) void {
    OffMenu(ib, @ptrCast(@alignCast(window)), menu_number);
}
fn lvoLendMenus(ib: *IntuitionBase, from_window: *intuition.Window, to_window: ?*intuition.Window) callconv(.c) void {
    LendMenus(ib, @ptrCast(@alignCast(from_window)), @ptrCast(@alignCast(to_window)));
}
fn lvoActivateGadget(ib: *IntuitionBase, gadget: *Object, window: *intuition.Window, requester: ?*intuition.Requester) callconv(.c) bool {
    return ActivateGadget(ib, gadget, @ptrCast(@alignCast(window)), requester);
}
fn lvoDoGadgetMethodA(ib: *IntuitionBase, gadget: *Object, window: ?*intuition.Window, requester: ?*intuition.Requester, message: *Msg) callconv(.c) usize {
    return DoGadgetMethodA(ib, gadget, @ptrCast(@alignCast(window)), requester, message);
}
fn lvoInitRequester(ib: *IntuitionBase, requester: *intuition.Requester) callconv(.c) void {
    InitRequester(ib, requester);
}
fn lvoRequest(ib: *IntuitionBase, requester: *intuition.Requester, window: *intuition.Window) callconv(.c) bool {
    return Request(ib, requester, @ptrCast(@alignCast(window)));
}
fn lvoEndRequest(ib: *IntuitionBase, requester: *intuition.Requester, window: *intuition.Window) callconv(.c) void {
    EndRequest(ib, requester, @ptrCast(@alignCast(window)));
}
fn lvoSetDMRequest(ib: *IntuitionBase, window: *intuition.Window, requester: *intuition.Requester) callconv(.c) bool {
    return SetDMRequest(ib, @ptrCast(@alignCast(window)), requester);
}
fn lvoClearDMRequest(ib: *IntuitionBase, window: *intuition.Window) callconv(.c) bool {
    return ClearDMRequest(ib, @ptrCast(@alignCast(window)));
}
fn lvoAutoRequestTagList(ib: *IntuitionBase, window: ?*intuition.Window, tags: ?[*]const TagItem) callconv(.c) bool {
    return AutoRequestTagList(ib, @ptrCast(@alignCast(window)), tags);
}
fn lvoBuildSysRequestTagList(ib: *IntuitionBase, window: ?*intuition.Window, tags: ?[*]const TagItem) callconv(.c) ?*intuition.Window {
    return @ptrCast(BuildSysRequestTagList(ib, @ptrCast(@alignCast(window)), tags));
}
fn lvoDoubleClick(ib: *IntuitionBase, start_seconds: u32, start_micros: u32, current_seconds: u32, current_micros: u32) callconv(.c) bool {
    return DoubleClick(ib, start_seconds, start_micros, current_seconds, current_micros);
}
fn lvoGetIMsg(ib: *IntuitionBase, window: *intuition.Window) callconv(.c) ?*intuition.IntuiMessage {
    return GetIMsg(ib, @ptrCast(@alignCast(window)));
}
fn lvoReplyIMsg(ib: *IntuitionBase, msg: *intuition.IntuiMessage) callconv(.c) void {
    ReplyIMsg(ib, msg);
}
fn lvoWaitIMsg(ib: *IntuitionBase, window: *intuition.Window, others: u32) callconv(.c) u32 {
    return WaitIMsg(ib, @ptrCast(@alignCast(window)), others);
}
fn lvoMoveWindowInFrontOf(ib: *IntuitionBase, window: *intuition.Window, behind: *intuition.Window) callconv(.c) void {
    MoveWindowInFrontOf(ib, @ptrCast(@alignCast(window)), @ptrCast(@alignCast(behind)));
}
fn lvoScrollWindowRaster(ib: *IntuitionBase, window: *intuition.Window, dx: i32, dy: i32, area: *const graphics.Rect) callconv(.c) bool {
    return ScrollWindowRaster(ib, @ptrCast(@alignCast(window)), dx, dy, area);
}
fn lvoSetMouseQueue(ib: *IntuitionBase, window: *intuition.Window, length: u32) callconv(.c) u32 {
    return SetMouseQueue(ib, @ptrCast(@alignCast(window)), length);
}
fn lvoReportMouse(ib: *IntuitionBase, window: *intuition.Window, on: bool) callconv(.c) void {
    ReportMouse(ib, @ptrCast(@alignCast(window)), on);
}
fn lvoLockPubScreenList(ib: *IntuitionBase) callconv(.c) *exec.List {
    return LockPubScreenList(ib);
}
fn lvoUnlockPubScreenList(ib: *IntuitionBase) callconv(.c) void {
    UnlockPubScreenList(ib);
}
fn lvoNextPubScreen(ib: *IntuitionBase, screen: ?*intuition.Screen, name_buffer: *[32]u8) callconv(.c) ?[*:0]u8 {
    return NextPubScreen(ib, @ptrCast(@alignCast(screen)), name_buffer);
}
fn lvoSetDefaultPubScreen(ib: *IntuitionBase, name: ?[*:0]const u8) callconv(.c) void {
    SetDefaultPubScreen(ib, name);
}
fn lvoGetDefaultPubScreen(ib: *IntuitionBase, name_buffer: ?*[32]u8) callconv(.c) ?*intuition.Screen {
    return @ptrCast(GetDefaultPubScreen(ib, name_buffer));
}
fn lvoSetPubScreenModes(ib: *IntuitionBase, modes: u32) callconv(.c) u32 {
    return SetPubScreenModes(ib, modes);
}
fn lvoPubScreenStatus(ib: *IntuitionBase, screen: *intuition.Screen, flags: u32) callconv(.c) u32 {
    return PubScreenStatus(ib, @ptrCast(@alignCast(screen)), flags);
}
fn lvoScreenDepth(ib: *IntuitionBase, screen: *intuition.Screen, flags: u32) callconv(.c) void {
    ScreenDepth(ib, @ptrCast(@alignCast(screen)), flags);
}
fn lvoShowTitle(ib: *IntuitionBase, screen: *intuition.Screen, show: bool) callconv(.c) void {
    ShowTitle(ib, @ptrCast(@alignCast(screen)), show);
}
fn lvoAllocScreenBuffer(ib: *IntuitionBase, screen: *intuition.Screen, flags: u32) callconv(.c) ?*intuition.screens.ScreenBuffer {
    return AllocScreenBuffer(ib, @ptrCast(@alignCast(screen)), flags);
}
fn lvoChangeScreenBuffer(ib: *IntuitionBase, screen: *intuition.Screen, buffer: *intuition.screens.ScreenBuffer) callconv(.c) bool {
    return ChangeScreenBuffer(ib, @ptrCast(@alignCast(screen)), buffer);
}
fn lvoFreeScreenBuffer(ib: *IntuitionBase, screen: *intuition.Screen, buffer: ?*intuition.screens.ScreenBuffer) callconv(.c) void {
    FreeScreenBuffer(ib, @ptrCast(@alignCast(screen)), buffer);
}
fn lvoDisplayBeep(ib: *IntuitionBase, screen: ?*intuition.Screen) callconv(.c) void {
    DisplayBeep(ib, @ptrCast(@alignCast(screen)));
}
fn lvoCurrentTime(ib: *IntuitionBase, seconds: *u32, micros: *u32) callconv(.c) void {
    CurrentTime(ib, seconds, micros);
}
fn lvoDisplayAlert(ib: *IntuitionBase, alert_number: u32, text: [*:0]const u8, height: u32) callconv(.c) bool {
    return DisplayAlert(ib, alert_number, text, height);
}
fn lvoTimedDisplayAlert(ib: *IntuitionBase, alert_number: u32, text: [*:0]const u8, height: u32, frames: u32) callconv(.c) bool {
    return TimedDisplayAlert(ib, alert_number, text, height, frames);
}
fn lvoHelpControl(ib: *IntuitionBase, window: *intuition.Window, flags: u32) callconv(.c) void {
    HelpControl(ib, @ptrCast(@alignCast(window)), flags);
}
fn lvoSetEditHook(ib: *IntuitionBase, hook: ?*utility.Hook) callconv(.c) *utility.Hook {
    return SetEditHook(ib, hook);
}
fn lvoGadgetMouse(ib: *IntuitionBase, gadget: *intuition.Object, info: *intuition.GadgetInfo, point: *graphics.Point) callconv(.c) void {
    GadgetMouse(ib, gadget, info, point);
}

pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(intuition_base.expunge),
    vec(exec.libExtFunc),
    vec(lvoMakeClass),
    vec(lvoFreeClass),
    vec(lvoAddClass),
    vec(lvoRemoveClass),
    vec(lvoFindClass),
    vec(lvoLockClassList),
    vec(lvoUnlockClassList),
    vec(lvoNewObjectTagList),
    vec(lvoDisposeObject),
    vec(lvoSetAttrsTagList),
    vec(lvoGetAttr),
    vec(lvoNextObject),
    vec(lvoSendMessage),
    vec(lvoSendSuperMessage),
    vec(lvoCoerceMessage),
    vec(lvoDrawImage),
    vec(lvoDrawImageState),
    vec(lvoEraseImage),
    vec(lvoPointInImage),
    vec(lvoOpenScreenTagList),
    vec(lvoCloseScreen),
    vec(lvoGetScreenAttrs),
    vec(lvoScreenToFront),
    vec(lvoScreenToBack),
    vec(lvoGetScreenDrawInfo),
    vec(lvoFreeScreenDrawInfo),
    vec(lvoLockPubScreen),
    vec(lvoUnlockPubScreen),
    vec(lvoOpenWindowTagList),
    vec(lvoCloseWindow),
    vec(lvoGetWindowAttrs),
    vec(lvoMoveWindow),
    vec(lvoSizeWindow),
    vec(lvoChangeWindowBox),
    vec(lvoWindowToFront),
    vec(lvoWindowToBack),
    vec(lvoActivateWindow),
    vec(lvoModifyIDCMP),
    vec(lvoBeginRefresh),
    vec(lvoEndRefresh),
    vec(lvoRefreshWindowFrame),
    vec(lvoAddGList),
    vec(lvoRemoveGList),
    vec(lvoRefreshGList),
    vec(lvoSetGadgetAttrsTagList),
    vec(lvoObtainGIRPort),
    vec(lvoReleaseGIRPort),
    vec(lvoPrintIText),
    vec(lvoDrawBorder),
    vec(lvoIntuiTextLength),
    vec(lvoLockIBase),
    vec(lvoUnlockIBase),
    vec(lvoZipWindow),
    vec(lvoSetWindowTitles),
    vec(lvoWindowLimits),
    vec(lvoOnGadget),
    vec(lvoOffGadget),
    vec(lvoEasyRequestArgs),
    vec(lvoBuildEasyRequestArgs),
    vec(lvoSysReqHandler),
    vec(lvoFreeSysRequest),
    vec(lvoSetMenuStrip),
    vec(lvoClearMenuStrip),
    vec(lvoResetMenuStrip),
    vec(lvoItemAddress),
    vec(lvoOnMenu),
    vec(lvoOffMenu),
    vec(lvoLendMenus),
    vec(lvoActivateGadget),
    vec(lvoDoGadgetMethodA),
    vec(lvoInitRequester),
    vec(lvoRequest),
    vec(lvoEndRequest),
    vec(lvoSetDMRequest),
    vec(lvoClearDMRequest),
    vec(lvoAutoRequestTagList),
    vec(lvoBuildSysRequestTagList),
    vec(lvoDoubleClick),
    vec(lvoGetIMsg),
    vec(lvoReplyIMsg),
    vec(lvoWaitIMsg),
    vec(lvoMoveWindowInFrontOf),
    vec(lvoScrollWindowRaster),
    vec(lvoSetMouseQueue),
    vec(lvoReportMouse),
    vec(lvoLockPubScreenList),
    vec(lvoUnlockPubScreenList),
    vec(lvoNextPubScreen),
    vec(lvoSetDefaultPubScreen),
    vec(lvoGetDefaultPubScreen),
    vec(lvoSetPubScreenModes),
    vec(lvoPubScreenStatus),
    vec(lvoScreenDepth),
    vec(lvoShowTitle),
    vec(lvoAllocScreenBuffer),
    vec(lvoChangeScreenBuffer),
    vec(lvoFreeScreenBuffer),
    vec(lvoDisplayBeep),
    vec(lvoCurrentTime),
    vec(lvoDisplayAlert),
    vec(lvoTimedDisplayAlert),
    vec(lvoHelpControl),
    vec(lvoSetEditHook),
    vec(lvoGadgetMouse),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: the standard four, then this library's own" {
    try testing.expectEqual(@as(usize, 4 + @typeInfo(LVO).@"struct".decls.len), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("intuition_lvo.zig"), LVO, &.{});
}
