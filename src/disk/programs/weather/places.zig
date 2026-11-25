// SPDX-License-Identifier: MIT
//! The places kept, the one shown and the units, in `ENV:Weather.json`
//! and `ENVARC:Weather.json`, read and written with json.library:
//!
//!   {
//!     "units": "celsius",
//!     "shown": { "name": "Bern, Switzerland", "latitude": 46.94809, "longitude": 7.44744 },
//!     "places": [
//!       { "name": "Bern, Switzerland", "latitude": 46.94809, "longitude": 7.44744 }
//!     ]
//!   }
//!
//! `units` is `celsius` or `fahrenheit`; without the file, the locale's
//! measuring system says (American: Fahrenheit). The file is written
//! whenever a place is kept or removed, another shown or the units
//! changed; ENV: is read at the start, ENVARC: being where it survives a
//! restart.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = sdk.interface.json.JSONBase;
const forecast = @import("forecast.zig");
const Place = forecast.Place;

pub const ENV_FILE = "ENV:Weather.json";
pub const ENVARC_FILE = "ENVARC:Weather.json";

/// How many places are kept at the most.
pub const max_places = 16;

pub const Settings = struct {
    places: [max_places]Place = @splat(.{}),
    count: u32 = 0,
    /// The place last shown; unnamed for none.
    shown: Place = .{},
    fahrenheit: bool = false,

    /// Where `place` is among those kept, if it is.
    pub fn indexOf(settings: *const Settings, place: *const Place) ?u32 {
        for (settings.places[0..settings.count], 0..) |*kept, at| {
            if (kept.same(place)) return @intCast(at);
        }
        return null;
    }

    /// `place` kept, at the end; false when the list is full. One already
    /// kept is kept once.
    pub fn keep(settings: *Settings, place: *const Place) bool {
        if (settings.indexOf(place) != null) return true;
        if (settings.count == max_places) return false;
        settings.places[settings.count] = place.*;
        settings.count += 1;
        return true;
    }

    pub fn remove(settings: *Settings, index: u32) void {
        if (index >= settings.count) return;
        var at = index;
        while (at + 1 < settings.count) : (at += 1) settings.places[at] = settings.places[at + 1];
        settings.count -= 1;
        settings.places[settings.count] = .{};
    }
};

/// The settings read from ENV:, as far as the file holds them; false
/// when there is no file to read.
pub fn load(jb: *JSONBase, into: *Settings) bool {
    const document = jb.ReadJSONFile(ENV_FILE, 0, null) orelse return false;
    defer jb.DisposeJSONDocument(document);
    const root = document.root;
    if (jb.GetJSONString(jb.FindJSONMember(root, "units"), null)) |units| into.fahrenheit = units[0] == 'f';
    _ = placeOf(jb, jb.FindJSONMember(root, "shown"), &into.shown);
    const list = jb.FindJSONMember(root, "places");
    var at: u32 = 0;
    while (jb.GetJSONItem(list, at)) |item| : (at += 1) {
        var place = Place{};
        if (placeOf(jb, item, &place)) _ = into.keep(&place);
    }
    return true;
}

/// The settings written to ENV: and ENVARC:; false when either could not
/// be.
pub fn save(jb: *JSONBase, settings: *const Settings) bool {
    const document = jb.CreateJSONDocument() orelse return false;
    defer jb.DisposeJSONDocument(document);
    const root = jb.CreateJSONValue(document, json.JSON_OBJECT) orelse return false;
    _ = jb.SetJSONRoot(document, root);
    const units: []const u8 = if (settings.fahrenheit) "fahrenheit" else "celsius";
    if (!jb.SetJSONMember(root, "units", jb.CreateJSONString(document, units.ptr, @intCast(units.len)) orelse return false)) return false;
    if (settings.shown.named()) {
        if (!jb.SetJSONMember(root, "shown", valueOf(jb, document, &settings.shown) orelse return false)) return false;
    }
    const list = jb.CreateJSONValue(document, json.JSON_ARRAY) orelse return false;
    if (!jb.SetJSONMember(root, "places", list)) return false;
    for (settings.places[0..settings.count]) |*place| {
        if (!jb.InsertJSONItem(list, valueOf(jb, document, place) orelse return false, json.JSON_END)) return false;
    }
    var written = true;
    for ([_][*:0]const u8{ ENV_FILE, ENVARC_FILE }) |name| {
        if (!jb.WriteJSONFile(root, name, json.JSONF_PRETTY)) written = false;
    }
    return written;
}

/// A place read from its object; false when it lacks a name or a
/// position on the globe.
pub fn placeOf(jb: *JSONBase, value: ?*const json.Value, into: *Place) bool {
    var length: u32 = 0;
    const name = jb.GetJSONString(jb.FindJSONMember(value, "name"), &length) orelse return false;
    var latitude: f64 = 0;
    var longitude: f64 = 0;
    if (!jb.GetJSONNumber(jb.FindJSONMember(value, "latitude"), &latitude)) return false;
    if (!jb.GetJSONNumber(jb.FindJSONMember(value, "longitude"), &longitude)) return false;
    if (latitude < -90 or latitude > 90 or longitude < -180 or longitude > 180) return false;
    into.* = .{ .latitude = latitude, .longitude = longitude };
    // Cut where it is full, never inside a UTF-8 character.
    var kept: usize = @min(length, forecast.name_max);
    if (kept < length) {
        while (kept > 0 and name[kept] & 0xC0 == 0x80) kept -= 1;
    }
    @memcpy(into.name[0..kept], name[0..kept]);
    into.name[kept] = 0;
    return kept > 0;
}

/// A place made an object of its name and position.
pub fn valueOf(jb: *JSONBase, document: *json.Document, place: *const Place) ?*json.Value {
    const object = jb.CreateJSONValue(document, json.JSON_OBJECT) orelse return null;
    var length: u32 = 0;
    while (place.name[length] != 0) length += 1;
    if (!jb.SetJSONMember(object, "name", jb.CreateJSONString(document, &place.name, length) orelse return null)) return null;
    if (!jb.SetJSONMember(object, "latitude", jb.CreateJSONNumber(document, place.latitude) orelse return null)) return null;
    if (!jb.SetJSONMember(object, "longitude", jb.CreateJSONNumber(document, place.longitude) orelse return null)) return null;
    return object;
}
