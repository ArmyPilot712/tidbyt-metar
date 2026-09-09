"""
Applet: METAR
Summary: Live airfield weather
Description: Shows the current METAR observation for any ICAO airfield - flight
category, wind, visibility, ceiling, temperature/dewpoint and altimeter -
straight from the NOAA Aviation Weather Center.
Author: Will Longnecker
"""

load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

METAR_URL = "https://aviationweather.gov/api/data/metar"
DEFAULT_STATION = "KEDN"
TTL = 300  # NOAA updates hourly; 5 min is plenty fresh and polite.

# Flight-category colors, matching the usual sectional/ForeFlight convention.
CAT_COLORS = {
    "VFR": "#00cc22",
    "MVFR": "#1e6dff",
    "IFR": "#ff0000",
    "LIFR": "#ff00d0",
}

CEILING_LAYERS = ["BKN", "OVC", "OVX", "VV"]

def main(config):
    station = config.str("station", DEFAULT_STATION).strip().upper()
    use_f = config.bool("fahrenheit", False)
    show_raw = config.bool("show_raw", False)

    ob = fetch_metar(station)
    if ob == None:
        return message(station, "NO DATA")

    cat = ob.get("fltCat") or "UNK"
    color = CAT_COLORS.get(cat, "#888888")

    lines = [
        header(station, cat, color, ob),
        line(wind_str(ob), "#ffffff"),
        line(vis_str(ob) + "  " + sky_str(ob), "#ffaa33"),
    ]

    if show_raw:
        lines.append(
            render.Padding(
                pad = (1, 2, 1, 0),
                child = render.Marquee(
                    width = 62,
                    child = render.Text(
                        content = ob.get("rawOb", ""),
                        font = "tom-thumb",
                        color = "#8899aa",
                    ),
                ),
            ),
        )
    else:
        lines.append(line(temps_str(ob, use_f) + "  " + altimeter_str(ob), "#66ccff"))

    return render.Root(
        delay = 90,
        child = render.Column(
            expanded = True,
            main_align = "start",
            children = lines,
        ),
    )

# ---------------------------------------------------------------- data

def fetch_metar(station):
    resp = http.get(
        METAR_URL,
        params = {"ids": station, "format": "json"},
        ttl_seconds = TTL,
    )
    if resp.status_code != 200:
        return None

    body = resp.json()
    if type(body) != "list" or len(body) == 0:
        return None

    # Ask for one station, but never assume the API only returned one.
    for ob in body:
        if ob.get("icaoId", "").upper() == station:
            return ob
    return body[0]

# ---------------------------------------------------------------- format

def header(station, cat, color, ob):
    return render.Box(
        height = 7,
        color = color,
        child = render.Padding(
            pad = (1, 1, 1, 0),
            child = render.Row(
                expanded = True,
                main_align = "space_between",
                cross_align = "center",
                children = [
                    render.Text(
                        content = station,
                        font = "tom-thumb",
                        color = "#000000",
                    ),
                    render.Text(
                        content = cat + age_flag(ob),
                        font = "tom-thumb",
                        color = "#000000",
                    ),
                ],
            ),
        ),
    )

def age_flag(ob):
    """A trailing * means the observation is more than 90 minutes old."""
    obs_time = ob.get("obsTime")
    if obs_time == None:
        return ""
    age = time.now().unix - int(obs_time)
    if age > 90 * 60:
        return "*"
    return ""

def line(text, color):
    return render.Padding(
        pad = (1, 2, 1, 0),
        child = render.Text(content = text, font = "tom-thumb", color = color),
    )

def wind_str(ob):
    spd = ob.get("wspd")
    if spd == None:
        return "WIND ---"
    if spd == 0:
        return "CALM"

    dir = ob.get("wdir")
    if dir == None or type(dir) == "string":
        head = "VRB"
    else:
        head = pad3(int(dir))

    out = head + pad2(int(spd))
    gust = ob.get("wgst")
    if gust != None and gust > 0:
        out += "G" + pad2(int(gust))
    return out + "KT"

def vis_str(ob):
    vis = ob.get("visib")
    if vis == None:
        return "--SM"
    if type(vis) == "string":
        return vis + "SM"
    if vis == int(vis):
        return str(int(vis)) + "SM"
    return str(vis) + "SM"

def sky_str(ob):
    """Lowest broken/overcast layer is the ceiling; otherwise report the cover."""
    clouds = ob.get("clouds") or []

    ceiling = None
    cover = None
    for layer in clouds:
        base = layer.get("base")
        if layer.get("cover") in CEILING_LAYERS and base != None:
            if ceiling == None or base < ceiling:
                ceiling = base
                cover = layer.get("cover")

    if ceiling != None:
        return cover + pad3(int(ceiling) // 100)

    # No ceiling: show the lowest reported layer, or the summary cover.
    lowest = None
    lcover = None
    for layer in clouds:
        base = layer.get("base")
        if base != None and (lowest == None or base < lowest):
            lowest = base
            lcover = layer.get("cover")
    if lowest != None and lcover != None:
        return lcover + pad3(int(lowest) // 100)

    return ob.get("cover") or "CLR"

def temps_str(ob, use_f):
    t = ob.get("temp")
    d = ob.get("dewp")
    if t == None:
        return "--/--"
    if use_f:
        t = t * 9 / 5 + 32
        d = d * 9 / 5 + 32 if d != None else None
    ts = str(rnd(t))
    ds = str(rnd(d)) if d != None else "--"
    return ts + "/" + ds

def altimeter_str(ob):
    """The API reports hPa; pilots want inches of mercury."""
    hpa = ob.get("altim")
    if hpa == None:
        return "-----"
    inhg = hpa / 33.8639
    hundredths = rnd(inhg * 100)
    return str(hundredths // 100) + "." + pad2(hundredths % 100)

def message(station, text):
    return render.Root(
        child = render.Column(
            expanded = True,
            main_align = "center",
            cross_align = "center",
            children = [
                render.Text(content = station, font = "tom-thumb", color = "#888888"),
                render.Text(content = text, font = "tom-thumb", color = "#ff4444"),
            ],
        ),
    )

# ---------------------------------------------------------------- helpers

def rnd(x):
    """Starlark has no round(); nudge and truncate, handling negatives."""
    if x < 0:
        return -int(-x + 0.5)
    return int(x + 0.5)

def pad2(n):
    return ("0" + str(n)) if n < 10 else str(n)

def pad3(n):
    if n < 10:
        return "00" + str(n)
    if n < 100:
        return "0" + str(n)
    return str(n)

# ---------------------------------------------------------------- schema

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "station",
                name = "Airfield",
                desc = "Four-letter ICAO identifier (e.g. KOZR, KDHN, KIAD).",
                icon = "planeDeparture",
                default = DEFAULT_STATION,
            ),
            schema.Toggle(
                id = "fahrenheit",
                name = "Fahrenheit",
                desc = "Show temperature and dewpoint in F instead of C.",
                icon = "temperatureHalf",
                default = False,
            ),
            schema.Toggle(
                id = "show_raw",
                name = "Scroll raw METAR",
                desc = "Replace the bottom line with the scrolling raw observation.",
                icon = "scroll",
                default = False,
            ),
        ],
    )
