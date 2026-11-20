# Weather

Weather shows the weather at any place: what it is now, the next 24 hours
and the three days after today, drawn over a sky in the weather's own
colours.

## Starting it

Double-click its icon in SYS:Programs, or type in a shell:

```
Weather [PLACE <words>]
```

- `PLACE` is a place to look up as the window opens: an address, a town,
  a postcode. Without it the window opens on the place shown last.

It needs the network: an interface that is up, with a name server.

## Finding a place

Type an address, a street and its number, a postcode or a town into the
field at the top and press Return, or Search. The place is looked up with
OpenStreetMap's Nominatim, which knows addresses down to the house; when
Nominatim cannot be reached - it is asked over HTTPS, which needs the
clock set - Open-Meteo's own search stands in, which knows towns by name.
The window names the place found as briefly as says where it is: the
street and the town, or the town and its region.

- **Keep** puts the place shown among the places kept.
- **Kept** lists them: a pick puts that place in the field and shows its
  weather.
- **Remove** takes the place the list shows off it.

The places kept, the place shown last and the units are written to
`ENV:Weather.json` and `ENVARC:Weather.json`, so they are there the next
time.

## What the window shows

- **At the top** the place, the day and the time there; on the right when
  the weather was measured, or what is being asked for, and whose the
  data are.
- **The weather now**: its picture, the temperature, the words for it,
  how warm it feels and today's high and low; beside them humidity, the
  wind (its speed and where it comes from, with an arrow the way it
  blows), precipitation, sunrise and sunset.
- **The next 24 hours**: the temperature as a curve, its value and a
  picture every third hour, and the chance of rain as blue bars under the
  curve.
- **The next three days**, a pane each: the day, its picture and words,
  its high and low, its chance of rain, and a bar of its range against
  the three days', coloured from blue in the cold to red in the heat.

By night the sun in the pictures is the moon, and a clear sky has stars.
The picture is drawn to fit the window, whatever its size. While the
window is sized, the last picture is stretched to it, and it is drawn
anew when the size gadget is let go.

The weather is asked for again every quarter of an hour while the window
is open.

## The menus

- **Project**: Refresh (asks for the weather again now), About, Quit.
- **Settings**: Celsius or Fahrenheit. Fahrenheit gives the wind in mph,
  Celsius in km/h. Until one is picked, the locale's measuring system
  decides: Fahrenheit for the American one.

## Where the data come from

The weather is Open-Meteo's (open-meteo.com), under CC BY 4.0. Places are
found with Nominatim, from OpenStreetMap's data, © OpenStreetMap
contributors, under the ODbL. Both are free to use for a program like
this one; the window names them.

## What it needs

- `LIBS:json.library`, which reads the answers and writes the settings.
- `LIBS:http.library`, `LIBS:bsdsocket.library`; `LIBS:tls.library` for
  Nominatim.
- `LIBS:vector.library`, which draws the picture, and `LIBS:motion.library`
  for the quarter hour.
