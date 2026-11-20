// SPDX-License-Identifier: MIT
//! What the window shows, as plain numbers: a place, the weather there now,
//! the next 24 hours and the next days - and how each is read out of the
//! services' JSON answers with json.library.
//!
//! **A place** comes from one of two services. Nominatim (OpenStreetMap)
//! takes any address - a street and its number, a postcode, a town - and
//! answers a list of what it found, the first being the likeliest, with
//! its parts (`addressdetails`): the place is named from those, as short
//! as says where it is - the road and its number and the town; a place
//! of its own name (a square, a park, a postcode) and its town; or the
//! town and its region. Open-Meteo's own search, which finds towns by
//! name, stands in when Nominatim cannot be reached.
//!
//! **The weather** is Open-Meteo's forecast: `current`, `hourly` (24
//! hours from the one now) and `daily` (today and the three days after
//! it), each of `hourly` and `daily` a member per measure holding an
//! array, an item per hour or day. Times are the place's own
//! (`timezone=auto`), written `2026-11-20T09:30`.
//!
//! **The weather's kind** is its WMO code (`weather_code`), which `skyOf`
//! makes one of the pictures `sky.zig` draws (`view.zig`'s `wordsOf` the
//! words that say it).

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = sdk.interface.json.JSONBase;

pub const max_hours = 24;
pub const max_days = 4;
/// The longest name a place is given, its NUL aside.
pub const name_max = 95;

/// Where the weather is asked for.
pub const Place = struct {
    name: [name_max + 1:0]u8 = @splat(0),
    latitude: f64 = 0,
    longitude: f64 = 0,

    pub fn named(place: *const Place) bool {
        return place.name[0] != 0;
    }

    pub fn same(place: *const Place, other: *const Place) bool {
        return @abs(place.latitude - other.latitude) < 0.0001 and @abs(place.longitude - other.longitude) < 0.0001;
    }
};

/// A time of day at the place.
pub const Clock = struct {
    hour: u8 = 0,
    minute: u8 = 0,
};

/// The weather now.
pub const Now = struct {
    temperature: f32 = 0,
    feels_like: f32 = 0,
    humidity: u8 = 0,
    code: u8 = 0,
    wind_speed: f32 = 0,
    /// Where the wind comes from, in degrees: 0 north, 90 east.
    wind_from: f32 = 0,
    day: bool = true,
    precipitation: f32 = 0,
    /// When the service measured it, at the place.
    at: Clock = .{},
};

/// One hour to come.
pub const Hour = struct {
    hour: u8 = 0,
    temperature: f32 = 0,
    code: u8 = 0,
    day: bool = true,
    /// 0 to 100.
    rain_chance: u8 = 0,
};

/// One day: today first.
pub const Day = struct {
    year: u16 = 0,
    month: u8 = 1,
    day: u8 = 1,
    /// 0 for Sunday to 6 for Saturday.
    weekday: u8 = 0,
    code: u8 = 0,
    high: f32 = 0,
    low: f32 = 0,
    /// 0 to 100.
    rain_chance: u8 = 0,
    sunrise: Clock = .{},
    sunset: Clock = .{},
};

/// The whole of one answer.
pub const Forecast = struct {
    now: Now = .{},
    hours: [max_hours]Hour = @splat(.{}),
    hour_count: u32 = 0,
    days: [max_days]Day = @splat(.{}),
    day_count: u32 = 0,
    /// Whether the temperatures are Fahrenheit and the wind mph, as they
    /// were asked for.
    fahrenheit: bool = false,
};

// --- the pictures and the words of the weather ---------------------------------

/// The pictures `sky.zig` draws.
pub const Sky = enum {
    clear,
    few_clouds,
    cloudy,
    overcast,
    fog,
    drizzle,
    rain,
    heavy_rain,
    freezing,
    snow,
    showers,
    snow_showers,
    thunder,
};

/// The picture of a WMO code.
pub fn skyOf(code: u8) Sky {
    return switch (code) {
        0 => .clear,
        1 => .few_clouds,
        2 => .cloudy,
        3 => .overcast,
        45, 48 => .fog,
        51, 53, 55 => .drizzle,
        56, 57, 66, 67 => .freezing,
        61, 63 => .rain,
        65 => .heavy_rain,
        71, 73, 75, 77 => .snow,
        80, 81, 82 => .showers,
        85, 86 => .snow_showers,
        95, 96, 99 => .thunder,
        else => .cloudy,
    };
}

// --- the answers read -------------------------------------------------------------

/// Open-Meteo's forecast read out of its answer; false when it is not one.
pub fn readForecast(jb: *JSONBase, root: ?*const json.Value, into: *Forecast) bool {
    const current = jb.FindJSONMember(root, "current") orelse return false;
    var now = Now{};
    now.temperature = number(jb, current, "temperature_2m") orelse return false;
    now.feels_like = number(jb, current, "apparent_temperature") orelse now.temperature;
    now.humidity = percent(jb, jb.FindJSONMember(current, "relative_humidity_2m"));
    now.code = codeOf(jb, jb.FindJSONMember(current, "weather_code"));
    now.wind_speed = number(jb, current, "wind_speed_10m") orelse 0;
    now.wind_from = number(jb, current, "wind_direction_10m") orelse 0;
    now.day = (number(jb, current, "is_day") orelse 1) != 0;
    now.precipitation = number(jb, current, "precipitation") orelse 0;
    if (jb.GetJSONString(jb.FindJSONMember(current, "time"), null)) |time| now.at = clockOf(time);
    into.now = now;

    const hourly = jb.FindJSONMember(root, "hourly");
    const hour_times = jb.FindJSONMember(hourly, "time");
    into.hour_count = @min(jb.CountJSONValues(hour_times), max_hours);
    for (into.hours[0..into.hour_count], 0..) |*hour, at| {
        const index: u32 = @intCast(at);
        hour.* = .{};
        if (jb.GetJSONString(jb.GetJSONItem(hour_times, index), null)) |time| hour.hour = clockOf(time).hour;
        hour.temperature = itemNumber(jb, hourly, "temperature_2m", index) orelse now.temperature;
        hour.code = codeOf(jb, jb.GetJSONItem(jb.FindJSONMember(hourly, "weather_code"), index));
        hour.day = (itemNumber(jb, hourly, "is_day", index) orelse 1) != 0;
        hour.rain_chance = percent(jb, jb.GetJSONItem(jb.FindJSONMember(hourly, "precipitation_probability"), index));
    }

    const daily = jb.FindJSONMember(root, "daily");
    const day_times = jb.FindJSONMember(daily, "time");
    into.day_count = @min(jb.CountJSONValues(day_times), max_days);
    for (into.days[0..into.day_count], 0..) |*day, at| {
        const index: u32 = @intCast(at);
        day.* = .{};
        if (jb.GetJSONString(jb.GetJSONItem(day_times, index), null)) |date| dateOf(date, day);
        day.code = codeOf(jb, jb.GetJSONItem(jb.FindJSONMember(daily, "weather_code"), index));
        day.high = itemNumber(jb, daily, "temperature_2m_max", index) orelse 0;
        day.low = itemNumber(jb, daily, "temperature_2m_min", index) orelse 0;
        day.rain_chance = percent(jb, jb.GetJSONItem(jb.FindJSONMember(daily, "precipitation_probability_max"), index));
        if (jb.GetJSONString(jb.GetJSONItem(jb.FindJSONMember(daily, "sunrise"), index), null)) |time| day.sunrise = clockOf(time);
        if (jb.GetJSONString(jb.GetJSONItem(jb.FindJSONMember(daily, "sunset"), index), null)) |time| day.sunset = clockOf(time);
    }
    return true;
}

/// The first place of Nominatim's answer, an array of what it found; false
/// for none.
pub fn readNominatim(jb: *JSONBase, root: ?*const json.Value, into: *Place) bool {
    const found = jb.GetJSONItem(root, 0) orelse return false;
    into.latitude = numberText(jb, jb.FindJSONMember(found, "lat")) orelse return false;
    into.longitude = numberText(jb, jb.FindJSONMember(found, "lon")) orelse return false;
    var name = Name{ .into = &into.name };
    name.into.* = @splat(0);
    const address = jb.FindJSONMember(found, "address");
    const town = firstOf(jb, address, &.{ "city", "town", "village", "hamlet", "municipality", "suburb", "county" });
    const own = firstOf(jb, found, &.{"name"});
    if (jb.GetJSONString(jb.FindJSONMember(address, "road"), null)) |road| {
        // An address: the street, its number, the town.
        name.add(road);
        if (jb.GetJSONString(jb.FindJSONMember(address, "house_number"), null)) |number_text| {
            name.add(" ");
            name.add(number_text);
        }
        if (town) |text| {
            name.add(", ");
            name.add(text);
        }
    } else if (own != null and (town == null or !sameText(own.?, town.?))) {
        // A place of its own name - a square, a park, a postcode - and
        // the town it is in.
        name.add(own.?);
        if (town orelse firstOf(jb, address, &.{ "state", "country" })) |where| {
            name.add(", ");
            name.add(where);
        }
    } else if (town) |text| {
        // A town, and its region.
        name.add(text);
        if (firstOf(jb, address, &.{ "state", "country" })) |region| {
            if (!sameText(region, text)) {
                name.add(", ");
                name.add(region);
            }
        }
    } else if (own) |text| {
        name.add(text);
    }
    if (into.name[0] == 0) {
        if (jb.GetJSONString(jb.FindJSONMember(found, "display_name"), null)) |whole| name.add(whole);
    }
    return true;
}

/// The first place of Open-Meteo's search, `results`; false for none.
pub fn readOpenMeteoPlace(jb: *JSONBase, root: ?*const json.Value, into: *Place) bool {
    const found = jb.GetJSONItem(jb.FindJSONMember(root, "results"), 0) orelse return false;
    var latitude: f64 = 0;
    var longitude: f64 = 0;
    if (!jb.GetJSONNumber(jb.FindJSONMember(found, "latitude"), &latitude)) return false;
    if (!jb.GetJSONNumber(jb.FindJSONMember(found, "longitude"), &longitude)) return false;
    into.latitude = latitude;
    into.longitude = longitude;
    var name = Name{ .into = &into.name };
    name.into.* = @splat(0);
    if (jb.GetJSONString(jb.FindJSONMember(found, "name"), null)) |own| name.add(own);
    if (firstOf(jb, found, &.{ "admin1", "country" })) |region| {
        name.add(", ");
        name.add(region);
    }
    return true;
}

/// A name put together in pieces, cut where it is full - never inside a
/// UTF-8 character.
const Name = struct {
    into: *[name_max + 1:0]u8,
    length: usize = 0,

    fn add(name: *Name, piece: [*:0]const u8) void {
        var at: usize = 0;
        while (piece[at] != 0) : (at += 1) {
            if (name.length == name_max) break;
            name.into[name.length] = piece[at];
            name.length += 1;
        }
        // A character cut in two - the next byte one of its own - is
        // taken back whole: its continuation bytes, then its lead.
        if (piece[at] & 0xC0 == 0x80) {
            while (name.length > 0 and name.into[name.length - 1] & 0xC0 == 0x80) name.length -= 1;
            if (name.length > 0) name.length -= 1;
        }
        name.into[name.length] = 0;
    }
};

fn sameText(one: [*:0]const u8, other: [*:0]const u8) bool {
    var at: usize = 0;
    while (one[at] == other[at]) : (at += 1) {
        if (one[at] == 0) return true;
    }
    return false;
}

/// The ISO 639-1 code of a locale's language, by the name locale.library
/// gives it (`deutsch`): what the services are asked to name places in.
pub fn languageCode(language: [*:0]const u8) ?[]const u8 {
    const codes = [_][2][]const u8{
        .{ "bulgarski", "bg" }, .{ "cestina", "cs" },  .{ "dansk", "da" },      .{ "deutsch", "de" },
        .{ "eesti", "et" },     .{ "ellinika", "el" }, .{ "english", "en" },    .{ "espanol", "es" },
        .{ "francais", "fr" },  .{ "gaeilge", "ga" },  .{ "hangugeo", "ko" },   .{ "hindi", "hi" },
        .{ "hrvatski", "hr" },  .{ "islenska", "is" }, .{ "italiano", "it" },   .{ "latviesu", "lv" },
        .{ "lietuviu", "lt" },  .{ "magyar", "hu" },   .{ "malti", "mt" },      .{ "nederlands", "nl" },
        .{ "nihongo", "ja" },   .{ "norsk", "nb" },    .{ "polski", "pl" },     .{ "portugues", "pt" },
        .{ "romana", "ro" },    .{ "russkij", "ru" },  .{ "slovencina", "sk" }, .{ "slovenscina", "sl" },
        .{ "suomi", "fi" },     .{ "svenska", "sv" },  .{ "turkce", "tr" },     .{ "ukrainska", "uk" },
        .{ "zhongwen", "zh" },
    };
    for (codes) |pair| {
        var at: usize = 0;
        while (at < pair[0].len and language[at] == pair[0][at]) at += 1;
        if (at == pair[0].len and language[at] == 0) return pair[1];
    }
    return null;
}

fn firstOf(jb: *JSONBase, object: ?*const json.Value, names: []const [*:0]const u8) ?[*:0]const u8 {
    for (names) |name| {
        if (jb.GetJSONString(jb.FindJSONMember(object, name), null)) |text| {
            if (text[0] != 0) return text;
        }
    }
    return null;
}

fn number(jb: *JSONBase, object: *const json.Value, name: [*:0]const u8) ?f32 {
    var value: f64 = 0;
    if (!jb.GetJSONNumber(jb.FindJSONMember(object, name), &value)) return null;
    return @floatCast(value);
}

fn itemNumber(jb: *JSONBase, object: ?*const json.Value, name: [*:0]const u8, index: u32) ?f32 {
    var value: f64 = 0;
    if (!jb.GetJSONNumber(jb.GetJSONItem(jb.FindJSONMember(object, name), index), &value)) return null;
    return @floatCast(value);
}

fn codeOf(jb: *JSONBase, value: ?*const json.Value) u8 {
    var whole: i64 = 0;
    if (!jb.GetJSONInteger(value, &whole) or whole < 0 or whole > 99) return 255;
    return @intCast(whole);
}

fn percent(jb: *JSONBase, value: ?*const json.Value) u8 {
    var amount: f64 = 0;
    if (!jb.GetJSONNumber(value, &amount)) return 0;
    return @intFromFloat(@min(@max(amount, 0), 100));
}

/// A number Nominatim writes as a string, `"48.1374990"`, read as JSON
/// reads one.
fn numberText(jb: *JSONBase, value: ?*const json.Value) ?f64 {
    var length: u32 = 0;
    const text = jb.GetJSONString(value, &length) orelse return null;
    const document = jb.ParseJSON(text, length, 0, null) orelse return null;
    defer jb.DisposeJSONDocument(document);
    var read: f64 = 0;
    return if (jb.GetJSONNumber(document.root, &read)) read else null;
}

/// The hour and minute of `2026-11-20T09:30`.
fn clockOf(text: [*:0]const u8) Clock {
    var at: usize = 0;
    while (text[at] != 0 and text[at] != 'T') at += 1;
    if (text[at] != 'T') return .{};
    return .{ .hour = twoDigits(text + at + 1), .minute = twoDigits(text + at + 4) };
}

/// The date of `2026-11-20`, and its weekday.
fn dateOf(text: [*:0]const u8, into: *Day) void {
    var year: u32 = 0;
    var at: usize = 0;
    while (at < 4 and text[at] >= '0' and text[at] <= '9') : (at += 1) year = year * 10 + (text[at] - '0');
    if (at != 4 or text[4] != '-') return;
    into.year = @intCast(year);
    into.month = twoDigits(text + 5);
    into.day = twoDigits(text + 8);
    into.weekday = weekdayOf(into.year, into.month, into.day);
}

fn twoDigits(text: [*:0]const u8) u8 {
    if (text[0] < '0' or text[0] > '9' or text[1] < '0' or text[1] > '9') return 0;
    return (text[0] - '0') * 10 + (text[1] - '0');
}

/// 0 for Sunday to 6 for Saturday, by the days since 1 March of year 0
/// in the Gregorian calendar.
pub fn weekdayOf(year: u16, month: u8, day: u8) u8 {
    const shifted_year: i32 = @as(i32, year) - @as(i32, if (month <= 2) 1 else 0);
    const shifted_month: i32 = if (month <= 2) @as(i32, month) + 9 else @as(i32, month) - 3;
    const days = 365 * shifted_year + @divFloor(shifted_year, 4) - @divFloor(shifted_year, 100) + @divFloor(shifted_year, 400) + @divFloor(153 * shifted_month + 2, 5) + @as(i32, day) - 1;
    // 1 March of year 0 was a Wednesday.
    return @intCast(@mod(days + 3, 7));
}
