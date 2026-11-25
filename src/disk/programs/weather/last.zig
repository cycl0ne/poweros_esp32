// SPDX-License-Identifier: MIT
//! The last answer, kept in `ENV:Weather.last` and `ENVARC:Weather.last`
//! with the place it is for and when it came, so that the window opens on
//! that place's weather - the whole picture at once - while it is asked
//! for again. It is written with json.library each time an answer comes:
//!
//!   {
//!     "kept": 1543917900,
//!     "place": { "name": "Bern, Switzerland", "latitude": 46.94809, "longitude": 7.44744 },
//!     "forecast": {
//!       "now": { "temperature": 4.3, ..., "at": { "hour": 10, "minute": 45 } },
//!       "hours": [ { "hour": 10, "temperature": 4.1, ... }, ... ],
//!       "hour_count": 24,
//!       "days": [ { "year": 2026, "month": 11, ... }, ... ],
//!       "day_count": 4,
//!       "fahrenheit": false
//!     }
//!   }
//!
//! `kept` is when it came, in seconds by the machine's clock. The
//! forecast's members are `forecast.zig`'s fields by their names, each
//! written and read by what it is (`put`, `take`), so the two cannot
//! drift apart; a file that lacks one, or holds one of another kind, is
//! not read.
//!
//! An answer is shown again only for the place the window opens on, in
//! the units it asks for, and for a day after it came: its hours are the
//! 24 from when it was measured, and after a day none of them is still to
//! come. One that came later than now - the clock was set back since - is
//! not shown either.

const sdk = @import("sdk");
const dos = sdk.dos;
const json = sdk.json;
const JSONBase = sdk.interface.json.JSONBase;
const DosBase = sdk.interface.dos.DosBase;
const forecast = @import("forecast.zig");
const places = @import("places.zig");
const Forecast = forecast.Forecast;
const Place = forecast.Place;

pub const ENV_FILE = "ENV:Weather.last";
pub const ENVARC_FILE = "ENVARC:Weather.last";

/// How long after it came an answer is shown again, in seconds.
pub const shown_for: i64 = 24 * 60 * 60;

const ticks_per_second = 50;

/// `seen`, the weather at `place`, kept in ENV: and ENVARC: as having come
/// now; false when either could not be written.
pub fn save(jb: *JSONBase, dl: *DosBase, place: *const Place, seen: *const Forecast) bool {
    const document = jb.CreateJSONDocument() orelse return false;
    defer jb.DisposeJSONDocument(document);
    const root = valueOf(jb, document, now(dl), place, seen) orelse return false;
    _ = jb.SetJSONRoot(document, root);
    var written = true;
    for ([_][*:0]const u8{ ENV_FILE, ENVARC_FILE }) |name| {
        if (!jb.WriteJSONFile(root, name, 0)) written = false;
    }
    return written;
}

/// The answer kept in ENV: into `into`, when it is the weather at `place`
/// in the units `fahrenheit` says and came less than a day ago; false,
/// and `into` as it was, otherwise.
pub fn load(jb: *JSONBase, dl: *DosBase, place: *const Place, fahrenheit: bool, into: *Forecast) bool {
    const document = jb.ReadJSONFile(ENV_FILE, 0, null) orelse return false;
    defer jb.DisposeJSONDocument(document);
    return read(jb, document.root, now(dl), place, fahrenheit, into);
}

/// The file's whole value: `seen` at `place`, come at `kept`.
pub fn valueOf(jb: *JSONBase, document: *json.Document, kept: i64, place: *const Place, seen: *const Forecast) ?*json.Value {
    const root = jb.CreateJSONValue(document, json.JSON_OBJECT) orelse return null;
    if (!jb.SetJSONMember(root, "kept", jb.CreateJSONInteger(document, kept) orelse return null)) return null;
    if (!jb.SetJSONMember(root, "place", places.valueOf(jb, document, place) orelse return null)) return null;
    if (!jb.SetJSONMember(root, "forecast", put(jb, document, seen) orelse return null)) return null;
    return root;
}

/// The forecast `root` holds into `into`, when it is the weather at
/// `place` in the units `fahrenheit` says and came less than a day before
/// `at`; false, and `into` as it was, otherwise.
pub fn read(jb: *JSONBase, root: ?*const json.Value, at: i64, place: *const Place, fahrenheit: bool, into: *Forecast) bool {
    var kept: i64 = 0;
    if (!jb.GetJSONInteger(jb.FindJSONMember(root, "kept"), &kept)) return false;
    if (at < kept or at - kept > shown_for) return false;
    var where = Place{};
    if (!places.placeOf(jb, jb.FindJSONMember(root, "place"), &where) or !where.same(place)) return false;
    var found = Forecast{};
    if (!take(jb, jb.FindJSONMember(root, "forecast"), &found)) return false;
    if (found.fahrenheit != fahrenheit) return false;
    if (found.hour_count > forecast.max_hours or found.day_count > forecast.max_days) return false;
    into.* = found;
    return true;
}

/// The machine's clock, in seconds.
fn now(dl: *DosBase) i64 {
    var stamp: dos.DateStamp = .{};
    _ = dl.DateStamp(&stamp);
    return @as(i64, stamp.days) * 86400 + @as(i64, stamp.minute) * 60 + @divTrunc(stamp.tick, ticks_per_second);
}

/// `value` made JSON: a structure an object of its fields by their names,
/// an array an array, a number a number, a truth a truth.
fn put(jb: *JSONBase, document: *json.Document, value: anytype) ?*json.Value {
    const T = @TypeOf(value.*);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            const object = jb.CreateJSONValue(document, json.JSON_OBJECT) orelse return null;
            inline for (info.fields) |field| {
                const member = put(jb, document, &@field(value, field.name)) orelse return null;
                if (!jb.SetJSONMember(object, field.name, member)) return null;
            }
            return object;
        },
        .array => {
            const array = jb.CreateJSONValue(document, json.JSON_ARRAY) orelse return null;
            for (value) |*item| {
                if (!jb.InsertJSONItem(array, put(jb, document, item) orelse return null, json.JSON_END)) return null;
            }
            return array;
        },
        .bool => return jb.CreateJSONBool(document, value.*),
        .float => return jb.CreateJSONNumber(document, value.*),
        .int => return jb.CreateJSONInteger(document, value.*),
        else => @compileError("Weather does not keep a " ++ @typeName(T)),
    }
}

/// `into` read from `from`, as `put` writes it; false when a member is not
/// there or not what its field is.
fn take(jb: *JSONBase, from: ?*const json.Value, into: anytype) bool {
    const T = @TypeOf(into.*);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (!take(jb, jb.FindJSONMember(from, field.name), &@field(into, field.name))) return false;
            }
            return true;
        },
        .array => {
            if (jb.CountJSONValues(from) != into.len) return false;
            for (into, 0..) |*item, at| {
                if (!take(jb, jb.GetJSONItem(from, @intCast(at)), item)) return false;
            }
            return true;
        },
        .bool => return jb.GetJSONBool(from, into),
        .float => {
            var number: f64 = 0;
            if (!jb.GetJSONNumber(from, &number)) return false;
            into.* = @floatCast(number);
            return true;
        },
        .int => |info| {
            if (info.signedness != .unsigned) @compileError("Weather keeps no signed whole numbers");
            const most: i64 = (1 << info.bits) - 1;
            var integer: i64 = 0;
            if (!jb.GetJSONInteger(from, &integer) or integer < 0 or integer > most) return false;
            into.* = @intCast(integer);
            return true;
        },
        else => @compileError("Weather does not keep a " ++ @typeName(T)),
    }
}
