// SPDX-License-Identifier: MIT
//! Host tests of Weather's reading of the services' answers: json.library
//! made from its ROM tag on the ROM's exec, and the answers of Open-Meteo's
//! forecast, Nominatim and Open-Meteo's search read into places and
//! forecasts as the window gets them - and nothing left behind.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const json = sdk.json;
const host = @import("host_rom");
const kexec = host.exec;
const json_init = @import("../../../libs/json/json_init.zig");
const forecast = @import("../forecast.zig");

const testing = std.testing;
const JSONBase = sdk.interface.json.JSONBase;

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

    fn deinit(rig: *Rig) !void {
        const sys = kexec.SysBase.iface();
        sys.CloseLibrary(rig.jb.lib());
        _ = sys.RemLibrary(rig.library);
        try kexec.expectNoLeaks();
        kexec.deinit();
    }

    fn parse(rig: *Rig, text: []const u8) !*json.Document {
        return rig.jb.ParseJSON(text.ptr, text.len, 0, null) orelse error.NotJson;
    }
};

fn nameOf(place: *const forecast.Place) []const u8 {
    return std.mem.sliceTo(&place.name, 0);
}

/// Open-Meteo's answer, as it comes, cut to three hours.
const forecast_answer =
    \\{"latitude":52.52,"longitude":13.419998,"generationtime_ms":0.2,"utc_offset_seconds":3600,
    \\"timezone":"Europe/Berlin","timezone_abbreviation":"GMT+1","elevation":38.0,
    \\"current_units":{"time":"iso8601","interval":"seconds","temperature_2m":"°C"},
    \\"current":{"time":"2026-11-20T10:45","interval":900,"temperature_2m":4.3,"apparent_temperature":1.6,
    \\"relative_humidity_2m":73,"weather_code":2,"wind_speed_10m":3.2,"wind_direction_10m":315,"is_day":1,"precipitation":0.10},
    \\"hourly":{"time":["2026-11-20T10:00","2026-11-20T11:00","2026-11-20T12:00"],
    \\"temperature_2m":[4.1,4.6,5.0],"weather_code":[3,2,61],"precipitation_probability":[0,15,40],"is_day":[1,1,1]},
    \\"daily":{"time":["2026-11-20","2026-11-21","2026-11-22","2026-11-23"],"weather_code":[2,3,80,85],
    \\"temperature_2m_max":[5.2,6.0,5.1,3.0],"temperature_2m_min":[1.9,0.8,2.9,-0.4],
    \\"precipitation_probability_max":[18,18,30,14],
    \\"sunrise":["2026-11-20T07:36","2026-11-21T07:38","2026-11-22T07:39","2026-11-23T07:41"],
    \\"sunset":["2026-11-20T16:06","2026-11-21T16:05","2026-11-22T16:04","2026-11-23T16:03"]}}
;

test "a forecast read" {
    var rig = Rig{};
    try rig.init();
    {
        const document = try rig.parse(forecast_answer);
        defer rig.jb.DisposeJSONDocument(document);
        var read = forecast.Forecast{};
        try testing.expect(forecast.readForecast(rig.jb, document.root, &read));
        try testing.expectApproxEqAbs(@as(f32, 4.3), read.now.temperature, 0.001);
        try testing.expectApproxEqAbs(@as(f32, 1.6), read.now.feels_like, 0.001);
        try testing.expectEqual(@as(u8, 73), read.now.humidity);
        try testing.expectEqual(@as(u8, 2), read.now.code);
        try testing.expectEqual(@as(f32, 315), read.now.wind_from);
        try testing.expect(read.now.day);
        try testing.expectEqual(forecast.Clock{ .hour = 10, .minute = 45 }, read.now.at);
        try testing.expectEqual(@as(u32, 3), read.hour_count);
        try testing.expectEqual(@as(u8, 12), read.hours[2].hour);
        try testing.expectEqual(@as(u8, 61), read.hours[2].code);
        try testing.expectEqual(@as(u8, 40), read.hours[2].rain_chance);
        try testing.expectEqual(@as(u32, 4), read.day_count);
        const sunday = read.days[2];
        try testing.expectEqual(@as(u16, 2026), sunday.year);
        try testing.expectEqual(@as(u8, 11), sunday.month);
        try testing.expectEqual(@as(u8, 22), sunday.day);
        try testing.expectEqual(@as(u8, 0), sunday.weekday);
        try testing.expectEqual(@as(u8, 80), sunday.code);
        try testing.expectEqual(@as(u8, 30), sunday.rain_chance);
        try testing.expectApproxEqAbs(@as(f32, -0.4), read.days[3].low, 0.001);
        try testing.expectEqual(forecast.Clock{ .hour = 7, .minute = 36 }, read.days[0].sunrise);
        try testing.expectEqual(forecast.Clock{ .hour = 16, .minute = 6 }, read.days[0].sunset);
    }
    {
        // Not a forecast: an error the service answers with.
        const document = try rig.parse("{\"error\":true,\"reason\":\"Latitude must be in range of -90 to 90\"}");
        defer rig.jb.DisposeJSONDocument(document);
        var read = forecast.Forecast{};
        try testing.expect(!forecast.readForecast(rig.jb, document.root, &read));
    }
    try rig.deinit();
}

test "places named from Nominatim's answers" {
    var rig = Rig{};
    try rig.init();
    const answers = [_]struct { text: []const u8, name: []const u8, latitude: f64 }{
        // A street and its number.
        .{
            .text =
            \\[{"place_id":1,"lat":"52.5163","lon":"13.3777","category":"building","type":"yes","name":"",
            \\"display_name":"7, Pariser Platz, Mitte, Berlin, 10117, Deutschland",
            \\"address":{"house_number":"7","road":"Pariser Platz","suburb":"Mitte","city":"Berlin","postcode":"10117","country":"Deutschland"}}]
            ,
            .name = "Pariser Platz 7, Berlin",
            .latitude = 52.5163,
        },
        // A square of its own name.
        .{
            .text =
            \\[{"lat":"52.5219814","lon":"13.4136358","category":"place","type":"square","name":"Alexanderplatz",
            \\"address":{"square":"Alexanderplatz","suburb":"Mitte","city":"Berlin","country":"Deutschland"}}]
            ,
            .name = "Alexanderplatz, Berlin",
            .latitude = 52.5219814,
        },
        // A town, and its region.
        .{
            .text =
            \\[{"lat":"46.9482713","lon":"7.4514512","name":"Bern",
            \\"address":{"city":"Bern","county":"Verwaltungskreis Bern-Mittelland","state":"Bern","country":"Schweiz"}}]
            ,
            .name = "Bern",
            .latitude = 46.9482713,
        },
    };
    for (answers) |answer| {
        const document = try rig.parse(answer.text);
        defer rig.jb.DisposeJSONDocument(document);
        var place = forecast.Place{};
        try testing.expect(forecast.readNominatim(rig.jb, document.root, &place));
        try testing.expectEqualStrings(answer.name, nameOf(&place));
        try testing.expectEqual(answer.latitude, place.latitude);
    }
    {
        // Nothing found.
        const document = try rig.parse("[]");
        defer rig.jb.DisposeJSONDocument(document);
        var place = forecast.Place{};
        try testing.expect(!forecast.readNominatim(rig.jb, document.root, &place));
    }
    try rig.deinit();
}

test "a place from Open-Meteo's search" {
    var rig = Rig{};
    try rig.init();
    {
        const document = try rig.parse(
            \\{"results":[{"id":2950159,"name":"Berlin","latitude":52.52437,"longitude":13.41053,
            \\"country_code":"DE","admin1":"Land Berlin","country":"Deutschland"}],"generationtime_ms":0.6}
        );
        defer rig.jb.DisposeJSONDocument(document);
        var place = forecast.Place{};
        try testing.expect(forecast.readOpenMeteoPlace(rig.jb, document.root, &place));
        try testing.expectEqualStrings("Berlin, Land Berlin", nameOf(&place));
        try testing.expectEqual(@as(f64, 13.41053), place.longitude);
    }
    {
        const document = try rig.parse("{\"generationtime_ms\":0.4}");
        defer rig.jb.DisposeJSONDocument(document);
        var place = forecast.Place{};
        try testing.expect(!forecast.readOpenMeteoPlace(rig.jb, document.root, &place));
    }
    try rig.deinit();
}

test "a long name cut whole characters" {
    var rig = Rig{};
    try rig.init();
    // 94 bytes of `a`, then a two-byte character that does not fit.
    {
        const text = "[{\"lat\":\"1\",\"lon\":\"2\",\"name\":\"" ++ "a" ** 94 ++ "\u{E4}b\"}]";
        const document = try rig.parse(text);
        defer rig.jb.DisposeJSONDocument(document);
        var place = forecast.Place{};
        try testing.expect(forecast.readNominatim(rig.jb, document.root, &place));
        try testing.expectEqual(@as(usize, 94), nameOf(&place).len);
    }
    try rig.deinit();
}

test "weekdays and language codes" {
    try testing.expectEqual(@as(u8, 5), forecast.weekdayOf(2026, 11, 20));
    try testing.expectEqual(@as(u8, 0), forecast.weekdayOf(2026, 11, 22));
    try testing.expectEqual(@as(u8, 4), forecast.weekdayOf(2024, 2, 29));
    try testing.expectEqual(@as(u8, 6), forecast.weekdayOf(2000, 1, 1));
    try testing.expectEqualStrings("de", forecast.languageCode("deutsch").?);
    try testing.expectEqualStrings("zh", forecast.languageCode("zhongwen").?);
    try testing.expect(forecast.languageCode("deutschx") == null);
    try testing.expect(forecast.languageCode("deu") == null);
}
