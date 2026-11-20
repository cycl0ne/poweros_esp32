// SPDX-License-Identifier: MIT
//! Host tests of json.library: the library made from its ROM tag on the
//! ROM's exec and opened, every call made through its jump table - text
//! read and refused where and why it should be, values looked up by name,
//! place and pointer, a document built and changed, written compact and
//! pretty and read back the same - and nothing left behind. The file
//! calls are tested on a RAM disk under the ROM's dos.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const json = sdk.json;
const host = @import("host_rom");
const kexec = host.exec;
const json_init = @import("../json_init.zig");

const testing = std.testing;
const JSONBase = sdk.interface.json.JSONBase;
const Value = json.Value;

test {
    _ = @import("../json_lvo.zig");
    _ = @import("../number/_number.zig");
    _ = @import("../utf8/_utf8.zig");
}

/// exec, with json.library made and opened.
const Rig = struct {
    library: *exec.Library = undefined,
    jb: *JSONBase = undefined,

    fn init(rig: *Rig) !void {
        try kexec.setUp();
        const made = kexec.InitResident(kexec.SysBase, &json_init.json_library_tag, null) orelse return error.NoLibrary;
        rig.library = @ptrCast(@alignCast(made));
        rig.jb = @ptrCast(kexec.SysBase.iface().OpenLibrary(json.JSONNAME, 1) orelse return error.NoBase);
    }

    /// The library closed and expunged, and nothing left behind.
    fn deinit(rig: *Rig) !void {
        const sys = kexec.SysBase.iface();
        sys.CloseLibrary(rig.jb.lib());
        _ = sys.RemLibrary(rig.library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, json.JSONNAME) == null);
        try kexec.expectNoLeaks();
        kexec.deinit();
    }

    fn parse(rig: *Rig, text: []const u8, flags: u32, report: ?*json.Error) ?*json.Document {
        return rig.jb.ParseJSON(text.ptr, text.len, flags, report);
    }
};

fn textOf(jb: *JSONBase, value: ?*const Value) []const u8 {
    var length: u32 = 0;
    const text = jb.GetJSONString(value, &length) orelse return "";
    return text[0..length];
}

test "json: a weather answer read, and its values found by name, place and pointer" {
    var rig = Rig{};
    try rig.init();
    const jb = rig.jb;
    const answer =
        \\{"latitude":52.52,"timezone":"Europe/Berlin","current":{"temperature_2m":3.6,"weather_code":3,"is_day":1},
        \\ "daily":{"time":["2026-11-20","2026-11-21"],"temperature_2m_max":[5.5,-0.8]},"ok":true,"none":null}
    ;
    var report = json.Error{};
    const document = rig.parse(answer, 0, &report) orelse return error.NotRead;
    try testing.expectEqual(json.JSONERR_OK, report.code);
    const root = document.root.?;
    try testing.expectEqual(json.JSON_OBJECT, root.kind);
    try testing.expectEqual(@as(u32, 6), jb.CountJSONValues(root));

    var number: f64 = 0;
    try testing.expect(jb.GetJSONNumber(jb.FindJSONPointer(root, "/current/temperature_2m"), &number));
    try testing.expectEqual(@as(f64, 3.6), number);
    var integer: i64 = 0;
    try testing.expect(jb.GetJSONInteger(jb.FindJSONPointer(root, "/current/weather_code"), &integer));
    try testing.expectEqual(@as(i64, 3), integer);
    try testing.expect(jb.GetJSONNumber(jb.FindJSONPointer(root, "/daily/temperature_2m_max/1"), &number));
    try testing.expectEqual(@as(f64, -0.8), number);
    try testing.expectEqualStrings("2026-11-21", textOf(jb, jb.GetJSONItem(jb.FindJSONPointer(root, "/daily/time"), 1)));
    try testing.expectEqualStrings("Europe/Berlin", textOf(jb, jb.FindJSONMember(root, "timezone")));
    var truth = false;
    try testing.expect(jb.GetJSONBool(jb.FindJSONMember(root, "ok"), &truth));
    try testing.expect(truth);
    try testing.expectEqual(json.JSON_NULL, jb.FindJSONMember(root, "none").?.kind);

    // Nothing where nothing is, and no call minds a null.
    try testing.expect(jb.FindJSONPointer(root, "/daily/time/2") == null);
    try testing.expect(jb.FindJSONPointer(root, "/daily/time/01") == null);
    try testing.expect(jb.FindJSONPointer(root, "/daily/time/-") == null);
    try testing.expect(jb.FindJSONPointer(root, "daily") == null);
    try testing.expect(jb.FindJSONPointer(root, "") == root);
    try testing.expect(jb.FindJSONMember(jb.FindJSONMember(root, "missing"), "deeper") == null);
    try testing.expect(!jb.GetJSONNumber(jb.FindJSONMember(root, "timezone"), &number));
    try testing.expect(jb.GetJSONItem(root, 0) == jb.FindJSONMember(root, "latitude"));
    try testing.expect(!jb.GetJSONInteger(jb.FindJSONMember(root, "latitude"), &integer));

    jb.DisposeJSONDocument(document);
    try rig.deinit();
}

test "json: strings with their escapes undone, a surrogate pair among them" {
    var rig = Rig{};
    try rig.init();
    const jb = rig.jb;
    const document = rig.parse(
        \\["a\"b\\c\/d\b\f\n\r\t", "\u00e4\u20AC\ud83d\ude00", "M\u00fcnchen", "\ud800x", "nul\u0000in", "Grüße"]
    , 0, null) orelse return error.NotRead;
    const root = document.root.?;
    try testing.expectEqualStrings("a\"b\\c/d\x08\x0C\n\r\t", textOf(jb, jb.GetJSONItem(root, 0)));
    try testing.expectEqualStrings("ä€😀", textOf(jb, jb.GetJSONItem(root, 1)));
    try testing.expectEqualStrings("München", textOf(jb, jb.GetJSONItem(root, 2)));
    try testing.expectEqualStrings("\u{FFFD}x", textOf(jb, jb.GetJSONItem(root, 3)));
    try testing.expectEqualStrings("nul\x00in", textOf(jb, jb.GetJSONItem(root, 4)));
    try testing.expectEqualStrings("Grüße", textOf(jb, jb.GetJSONItem(root, 5)));
    jb.DisposeJSONDocument(document);
    try rig.deinit();
}

test "json: text that is not JSON refused, saying why and where" {
    var rig = Rig{};
    try rig.init();
    const Case = struct { text: []const u8, code: i32, line: u32, column: u32 };
    const cases = [_]Case{
        .{ .text = "", .code = json.JSONERR_EMPTY, .line = 1, .column = 1 },
        .{ .text = "  \n ", .code = json.JSONERR_EMPTY, .line = 2, .column = 2 },
        .{ .text = "[1,2", .code = json.JSONERR_END, .line = 1, .column = 5 },
        .{ .text = "{\"a\":1,}", .code = json.JSONERR_UNEXPECTED, .line = 1, .column = 8 },
        .{ .text = "[1,]", .code = json.JSONERR_UNEXPECTED, .line = 1, .column = 4 },
        .{ .text = "{\n\"ä\": 01}", .code = json.JSONERR_NUMBER, .line = 2, .column = 7 },
        .{ .text = "[1.]", .code = json.JSONERR_NUMBER, .line = 1, .column = 4 },
        .{ .text = "[\"\\x\"]", .code = json.JSONERR_ESCAPE, .line = 1, .column = 3 },
        .{ .text = "[\"\\u12\"]", .code = json.JSONERR_ESCAPE, .line = 1, .column = 3 },
        .{ .text = "[\"a\tb\"]", .code = json.JSONERR_CONTROL, .line = 1, .column = 4 },
        .{ .text = "[\"\xC3\x28\"]", .code = json.JSONERR_UTF8, .line = 1, .column = 3 },
        .{ .text = "{} x", .code = json.JSONERR_TRAILING, .line = 1, .column = 4 },
        .{ .text = "tru", .code = json.JSONERR_END, .line = 1, .column = 4 },
        .{ .text = "nil", .code = json.JSONERR_UNEXPECTED, .line = 1, .column = 2 },
        .{ .text = "{\"a\" 1}", .code = json.JSONERR_UNEXPECTED, .line = 1, .column = 6 },
        .{ .text = "// no\n1", .code = json.JSONERR_UNEXPECTED, .line = 1, .column = 1 },
    };
    for (cases) |case| {
        var report = json.Error{};
        try testing.expect(rig.parse(case.text, 0, &report) == null);
        testing.expectEqual(case.code, report.code) catch |err| {
            std.debug.print("{s}\n", .{case.text});
            return err;
        };
        try testing.expectEqual(case.line, report.line);
        try testing.expectEqual(case.column, report.column);
    }
    try rig.deinit();
}

test "json: comments and a last comma read as nothing when asked for" {
    var rig = Rig{};
    try rig.init();
    const jb = rig.jb;
    const text = "\xEF\xBB\xBF// places kept\n{ /* the list */ \"places\": [1, 2,], \"shown\": 0, }\n";
    try testing.expect(rig.parse(text, 0, null) == null);
    const document = rig.parse(text, json.JSONF_COMMENTS, null) orelse return error.NotRead;
    try testing.expectEqual(@as(u32, 2), jb.CountJSONValues(jb.FindJSONMember(document.root, "places")));
    try testing.expectEqual(@as(u32, 2), jb.CountJSONValues(document.root));
    jb.DisposeJSONDocument(document);
    var report = json.Error{};
    try testing.expect(rig.parse("[1] /* open", json.JSONF_COMMENTS, &report) == null);
    try testing.expectEqual(json.JSONERR_END, report.code);
    try rig.deinit();
}

test "json: a name twice finds the last, and setting it leaves one" {
    var rig = Rig{};
    try rig.init();
    const jb = rig.jb;
    const document = rig.parse("{\"a\":1,\"b\":2,\"a\":3}", 0, null) orelse return error.NotRead;
    const root = document.root.?;
    var integer: i64 = 0;
    try testing.expect(jb.GetJSONInteger(jb.FindJSONMember(root, "a"), &integer));
    try testing.expectEqual(@as(i64, 3), integer);
    const four = jb.CreateJSONInteger(document, 4) orelse return error.NoMemory;
    try testing.expect(jb.SetJSONMember(root, "a", four));
    try testing.expectEqual(@as(u32, 2), jb.CountJSONValues(root));
    var text: [64]u8 = undefined;
    const length = jb.FormatJSON(root, &text, text.len, 0);
    try testing.expectEqualStrings("{\"b\":2,\"a\":4}", text[0..length]);
    jb.DisposeJSONDocument(document);
    try rig.deinit();
}

test "json: a document built, written compact and pretty, and read back the same" {
    var rig = Rig{};
    try rig.init();
    const jb = rig.jb;
    const document = jb.CreateJSONDocument() orelse return error.NoMemory;
    const root = jb.CreateJSONValue(document, json.JSON_OBJECT) orelse return error.NoMemory;
    try testing.expect(jb.SetJSONRoot(document, root));
    const places = jb.CreateJSONValue(document, json.JSON_ARRAY) orelse return error.NoMemory;
    try testing.expect(jb.SetJSONMember(root, "places", places));
    for ([_][]const u8{ "Berlin", "München \"Altstadt\"" }, [_]f64{ 52.52, 48.13743 }) |name, latitude| {
        const place = jb.CreateJSONValue(document, json.JSON_OBJECT) orelse return error.NoMemory;
        try testing.expect(jb.SetJSONMember(place, "name", jb.CreateJSONString(document, name.ptr, @intCast(name.len)).?));
        try testing.expect(jb.SetJSONMember(place, "latitude", jb.CreateJSONNumber(document, latitude).?));
        try testing.expect(jb.InsertJSONItem(places, place, json.JSON_END));
    }
    try testing.expect(jb.SetJSONMember(root, "fahrenheit", jb.CreateJSONBool(document, false).?));
    try testing.expect(jb.SetJSONMember(root, "big", jb.CreateJSONInteger(document, 9007199254740993).?));
    try testing.expect(jb.SetJSONMember(root, "empty", jb.CreateJSONValue(document, json.JSON_ARRAY).?));
    try testing.expect(jb.SetJSONMember(root, "nothing", jb.CreateJSONValue(document, json.JSON_NULL).?));
    try testing.expect(jb.SetJSONMember(root, "far", jb.CreateJSONNumber(document, std.math.inf(f64)).?));

    var text: [512]u8 = undefined;
    const compact = "{\"places\":[{\"name\":\"Berlin\",\"latitude\":52.52},{\"name\":\"München \\\"Altstadt\\\"\",\"latitude\":48.13743}],\"fahrenheit\":false,\"big\":9007199254740993,\"empty\":[],\"nothing\":null,\"far\":null}";
    const length = jb.FormatJSON(root, &text, text.len, 0);
    try testing.expectEqualStrings(compact, text[0..length]);
    // Measured without a buffer, and cut where a small one ends.
    try testing.expectEqual(length, jb.FormatJSON(root, null, 0, 0));
    var small: [8]u8 = undefined;
    try testing.expectEqual(length, jb.FormatJSON(root, &small, small.len, 0));
    try testing.expectEqualStrings("{\"place", std.mem.sliceTo(&small, 0));

    const pretty =
        \\{
        \\  "places": [
        \\    {
        \\      "name": "Berlin",
        \\      "latitude": 52.52
        \\    },
        \\    {
        \\      "name": "M\u00fcnchen \"Altstadt\"",
        \\      "latitude": 48.13743
        \\    }
        \\  ],
        \\  "fahrenheit": false,
        \\  "big": 9007199254740993,
        \\  "empty": [],
        \\  "nothing": null,
        \\  "far": null
        \\}
    ;
    const pretty_length = jb.FormatJSON(root, &text, text.len, json.JSONF_PRETTY | json.JSONF_ASCII);
    try testing.expectEqualStrings(pretty, text[0..pretty_length]);

    // Read back, and written again: the same text.
    const again = rig.parse(text[0..pretty_length], 0, null) orelse return error.NotRead;
    var second: [512]u8 = undefined;
    const second_length = jb.FormatJSON(again.root, &second, second.len, 0);
    try testing.expectEqualStrings(compact, second[0..second_length]);
    var integer: i64 = 0;
    try testing.expect(jb.GetJSONInteger(jb.FindJSONMember(again.root, "big"), &integer));
    try testing.expectEqual(@as(i64, 9007199254740993), integer);
    jb.DisposeJSONDocument(again);
    jb.DisposeJSONDocument(document);
    try rig.deinit();
}

test "json: values moved, inserted at a place, taken out, copied, and never into themselves" {
    var rig = Rig{};
    try rig.init();
    const jb = rig.jb;
    const document = rig.parse("{\"list\":[1,2,3],\"inner\":{\"deep\":[true]}}", 0, null) orelse return error.NotRead;
    const root = document.root.?;
    const list = jb.FindJSONMember(root, "list").?;
    const inner = jb.FindJSONMember(root, "inner").?;
    var text: [128]u8 = undefined;

    // The last item to the front, then one in the middle.
    try testing.expect(jb.InsertJSONItem(list, jb.GetJSONItem(list, 2).?, 0));
    try testing.expect(jb.InsertJSONItem(list, jb.CreateJSONInteger(document, 9).?, 2));
    try testing.expectEqualStrings("[3,1,9,2]", text[0..jb.FormatJSON(list, &text, text.len, 0)]);

    // Nothing goes inside itself, nor into what is not its kind, nor
    // into another document.
    try testing.expect(!jb.SetJSONMember(inner, "loop", root));
    try testing.expect(!jb.SetJSONMember(inner, "self", inner));
    try testing.expect(!jb.InsertJSONItem(inner, list, 0));
    const other = jb.CreateJSONDocument() orelse return error.NoMemory;
    try testing.expect(!jb.InsertJSONItem(list, jb.CreateJSONValue(other, json.JSON_NULL).?, 0));
    try testing.expect(!jb.SetJSONRoot(other, list));

    // A copy into another document, the original changed after.
    const copy = jb.CopyJSONValue(other, root) orelse return error.NoMemory;
    try testing.expect(jb.SetJSONRoot(other, copy));
    jb.RemoveJSONValue(jb.FindJSONMember(root, "inner").?);
    try testing.expectEqualStrings("{\"list\":[3,1,9,2]}", text[0..jb.FormatJSON(root, &text, text.len, 0)]);
    try testing.expectEqualStrings("{\"list\":[3,1,9,2],\"inner\":{\"deep\":[true]}}", text[0..jb.FormatJSON(other.root, &text, text.len, 0)]);

    // A member moved from one object into another loses its old name.
    try testing.expect(jb.SetJSONMember(copy, "moved", jb.FindJSONMember(copy, "list").?));
    try testing.expectEqualStrings("{\"inner\":{\"deep\":[true]},\"moved\":[3,1,9,2]}", text[0..jb.FormatJSON(copy, &text, text.len, 0)]);

    // The root taken off, and a document with none written as null.
    jb.RemoveJSONValue(copy);
    try testing.expect(other.root == null);
    try testing.expectEqualStrings("null", text[0..jb.FormatJSON(other.root, &text, text.len, 0)]);
    jb.DisposeJSONDocument(other);
    jb.DisposeJSONDocument(document);
    try rig.deinit();
}

/// Memory lent to exec for the deepest nesting: two thousand arrays are
/// more than the host tests' 80 KiB hold.
var lent: [512 * 1024]u8 align(16) = undefined;

test "json: nesting deeper than any stack would take is read and written" {
    var rig = Rig{};
    try rig.init();
    const jb = rig.jb;
    const sys = kexec.SysBase.iface();
    const region = sys.AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent").?;
    const depth = 2000;
    var text: [2 * depth]u8 = undefined;
    @memset(text[0..depth], '[');
    @memset(text[depth..], ']');
    const document = rig.parse(&text, 0, null) orelse return error.NotRead;
    var back: [2 * depth + 1]u8 = undefined;
    const length = jb.FormatJSON(document.root, &back, back.len, 0);
    try testing.expectEqualStrings(&text, back[0..length]);
    jb.DisposeJSONDocument(document);
    try testing.expectEqual(@intFromPtr(region.upper) - @intFromPtr(region.lower), region.free);
    sys.Remove(&region.node);
    try rig.deinit();
}

// --- the files ----------------------------------------------------------------

const DosBase = sdk.interface.dos.DosBase;

/// The RAM disk behind WORK:, answering the test process's packets.
const Disk = struct {
    var port: exec.MsgPort = undefined;
    var disk: host.ram.RamDisk = undefined;
    var dl: *DosBase = undefined;

    fn wait(proc: *dos.Process, sys: *sdk.interface.exec.ExecBase) callconv(.c) *exec.Message {
        const pkt = dos.DosPacket.fromMessage(sys.GetMsg(&port).?);
        const reply = disk.answer(pkt);
        dl.ReplyPkt(pkt, reply.res1, reply.res2);
        return sys.GetMsg(&proc.msg_port).?;
    }
};

/// exec, utility and dos, a process with WORK: behind it, and
/// json.library made and opened.
const FileRig = struct {
    db: *host.dos.DosBase,
    proc: dos.Process = .{},
    saved: ?*kexec.Task = null,
    library: *exec.Library = undefined,
    jb: *JSONBase = undefined,

    fn init(rig: *FileRig) !void {
        rig.* = .{ .db = try host.dos.testSetUp() };
        rig.proc.task.node.name = "test process";
        host.dos_process.initMsgPort(&rig.proc);
        rig.saved = kexec.SysBase.cpu().this_task;
        kexec.SysBase.cpu().this_task = &rig.proc.task;
        const dl = host.dos.testBase(rig.db);
        Disk.dl = dl;
        Disk.port = .{ .flags = exec.PA_IGNORE };
        Disk.port.msg_list.init(.message);
        Disk.disk = try host.ram.RamDisk.init(rig.db.sys_base, dl, rig.db.utility_base, &Disk.port);
        const node = dl.MakeDosEntry("WORK", dos.DLT_DEVICE).?;
        node.task = &Disk.port;
        try testing.expect(dl.AddDosEntry(node));
        rig.proc.pkt_wait = &Disk.wait;
        const made = kexec.InitResident(kexec.SysBase, &json_init.json_library_tag, null) orelse return error.NoLibrary;
        rig.library = @ptrCast(@alignCast(made));
        rig.jb = @ptrCast(kexec.SysBase.iface().OpenLibrary(json.JSONNAME, 1) orelse return error.NoBase);
    }

    fn deinit(rig: *FileRig) !void {
        const sys = kexec.SysBase.iface();
        sys.CloseLibrary(rig.jb.lib());
        _ = sys.RemLibrary(rig.library);
        Disk.disk.deinit();
        kexec.SysBase.cpu().this_task = rig.saved.?;
        try host.dos.testTearDown(rig.db);
        kexec.deinit();
    }
};

test "json: a value written into a file and read back from it" {
    var rig: FileRig = undefined;
    try rig.init();
    const jb = rig.jb;
    const dl = host.dos.testBase(rig.db);
    const kept = "{\"places\":[{\"name\":\"Berlin\",\"latitude\":52.52}],\"shown\":0}";
    const document = jb.ParseJSON(kept, kept.len, 0, null) orelse return error.NotRead;
    try testing.expect(jb.WriteJSONFile(document.root, "WORK:Weather.json", json.JSONF_PRETTY));
    jb.DisposeJSONDocument(document);

    var report = json.Error{};
    const back = jb.ReadJSONFile("WORK:Weather.json", 0, &report) orelse return error.NotRead;
    try testing.expectEqual(json.JSONERR_OK, report.code);
    try testing.expectEqualStrings("Berlin", std.mem.span(jb.GetJSONString(jb.FindJSONPointer(back.root, "/places/0/name"), null).?));
    jb.DisposeJSONDocument(back);

    // The file as text: pretty, and a line end after it.
    var text: [128]u8 = undefined;
    const fh = dl.Open("WORK:Weather.json", dos.MODE_OLDFILE) orelse return error.NoFile;
    const got = dl.Read(fh, &text, text.len);
    _ = dl.Close(fh);
    try testing.expectEqualStrings("{\n  \"places\": [\n    {\n      \"name\": \"Berlin\",\n      \"latitude\": 52.52\n    }\n  ],\n  \"shown\": 0\n}\n", text[0..@intCast(got)]);

    // A file that is not there.
    try testing.expect(jb.ReadJSONFile("WORK:Missing.json", 0, &report) == null);
    try testing.expectEqual(json.JSONERR_FILE, report.code);
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, report.dos_error);
    try rig.deinit();
}
