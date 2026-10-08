"""
Applet: Traffic
Summary: Live ADS-B traffic radar
Description: A mini radar scope of the aircraft around you, with a card that
cycles through the nearest ones - callsign, type, altitude, distance and
groundspeed. Data from the free adsb.lol network (airplanes.live as backup).
Author: Will Longnecker
"""

load("encoding/json.star", "json")
load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")

# ---------------------------------------------------------------- config

# Default center: Enterprise, AL (home of KEDN). Override with lat/lon.
DEFAULT_LAT = 31.3152
DEFAULT_LON = -85.8552
DEFAULT_RANGE_NM = 25

FEEDS = [
    "https://api.adsb.lol/v2/point/%s/%s/%d",
    "https://api.airplanes.live/v2/point/%s/%s/%d",
]
TTL = 30

MAX_CARDS = 5  # nearest N aircraft get a card
FRAMES_PER_CARD = 30  # x 100ms = 3 s per aircraft
SWEEP_STEP = 12  # degrees per frame -> one sweep every 3 s

# Radar geometry (left 32x32 half of the display)
CX = 15
CY = 15
R_PX = 15

RING_OUTER = "#0d4a1a"
RING_INNER = "#08300f"
SWEEP = ["#22cc55", "#11662b", "#0a3a18"]
HOME = "#4a7a4a"
DIVIDER = "#1a2a1a"

# ---------------------------------------------------------------- main

def main(config):
    lat, lon = get_location(config)
    range_nm = int(config.str("range", str(DEFAULT_RANGE_NM)))
    show_ground = config.bool("show_ground", False)

    prefetched = config.get("aircraft")
    if config.bool("demo", False):
        raw = demo_aircraft(lat, lon)
    elif prefetched:
        # Data fetched by the GitHub workflow (retries, fallbacks, and no
        # coordinates in public logs). {"error": true} means every feed failed.
        body = json.decode(prefetched)
        raw = None if body.get("error") else (body.get("ac") or [])
    else:
        raw = fetch_aircraft(lat, lon, range_nm)

    if raw == None:
        return status_screen(range_nm, "NO DATA", "#ff5555")

    planes = build_planes(raw, lat, lon, range_nm, show_ground)
    if len(planes) == 0:
        return status_screen(range_nm, "NO TFC", "#66ccff")

    layout = config.str("layout", "radar")
    if layout == "card":
        return layout_card(planes)
    if layout == "list":
        return layout_list(planes, range_nm)
    if layout == "scope":
        return layout_scope(planes)
    if layout == "pointer":
        return layout_pointer(planes)
    return layout_radar(planes)

def animate(frames):
    return render.Root(
        delay = 100,
        show_full_animation = True,
        child = render.Animation(children = frames),
    )

# ---------------------------------------------------------------- layout: radar

def layout_radar(planes):
    cards = planes[:MAX_CARDS]
    background = radar_background()

    frames = []
    for i, sel in enumerate(cards):
        card = info_card(sel, i, len(planes))
        for f in range(FRAMES_PER_CARD):
            sweep = ((i * FRAMES_PER_CARD + f) * SWEEP_STEP) % 360
            frames.append(
                render.Stack(
                    children = [
                        background,
                        sweep_layer(sweep),
                        blips_layer(planes, sel, sweep, f),
                        card,
                    ],
                ),
            )
    return animate(frames)

# ---------------------------------------------------------------- data

def get_location(config):
    loc = config.get("location")
    if loc:
        j = json.decode(loc)
        return float(j["lat"]), float(j["lng"])
    return (
        float(config.str("lat", str(DEFAULT_LAT))),
        float(config.str("lon", str(DEFAULT_LON))),
    )

def fetch_aircraft(lat, lon, range_nm):
    for url in FEEDS:
        resp = http.get(
            url % (fmt_coord(lat), fmt_coord(lon), range_nm),
            ttl_seconds = TTL,
        )
        if resp.status_code == 200:
            body = resp.json()
            if body and "ac" in body:
                return body["ac"] or []
    return None

def fmt_coord(v):
    # 4 decimal places is ~10 m; keeps the cache key stable.
    return str(int(v * 10000) / 10000.0)

def build_planes(raw, lat, lon, range_nm, show_ground):
    out = []
    for ac in raw:
        if ac.get("lat") == None or ac.get("lon") == None:
            continue

        alt = ac.get("alt_baro")
        on_ground = alt == "ground"
        if on_ground and not show_ground:
            continue
        if type(alt) != "int" and type(alt) != "float":
            alt = None

        dist, brg = dist_brg(lat, lon, ac["lat"], ac["lon"])
        if dist > range_nm:
            continue

        out.append({
            "call": ident(ac),
            "type": (ac.get("t") or ac.get("r") or "----").strip().upper(),
            "mil": is_military(ac),
            "alt": alt,
            "ground": on_ground,
            "vs": ac.get("baro_rate") or ac.get("geom_rate") or 0,
            "gs": ac.get("gs"),
            "track": ac.get("track"),
            "dist": dist,
            "brg": brg,
            "x": CX + dist / range_nm * R_PX * math.sin(math.radians(brg)),
            "y": CY - dist / range_nm * R_PX * math.cos(math.radians(brg)),
        })

    return sorted(out, key = lambda p: p["dist"])

# Type-line colors
CIV_COLOR = "#aabbcc"
MIL_COLOR = "#ff6a5c"

# Backup check for when the feed's military flag is missing: common military
# ICAO type designators (lots of these fly around Rucker / Eglin / Moody).
MIL_TYPES = [
    "H60",
    "UH60",
    "HH60",
    "MH60",
    "S70",  # Black Hawk / Seahawk family
    "H47",
    "CH47",
    "MH47",  # Chinook
    "H64",
    "AH64",  # Apache
    "UH72",
    "H72",  # Lakota
    "TH73",
    "TH57",
    "H1",
    "UH1",
    "AH1",
    "V22",
    "C17",
    "C5",
    "C5M",
    "C130",
    "C30J",
    "C2",
    "C27J",
    "C12",
    "C26",
    "C40",
    "C32",
    "C37",
    "K35R",
    "KC10",
    "K46",
    "KC46",
    "E3",
    "E3CF",
    "E6",
    "P8",
    "RC135",
    "R135",
    "F15",
    "F16",
    "F18",
    "F18S",
    "F22",
    "F35",
    "A10",
    "B1",
    "B2",
    "B52",
    "T6",
    "TEX2",
    "T38",
    "T45",
    "T1",
    "U2",
    "MQ9",
    "Q9",
]

def is_military(ac):
    # adsb.lol / airplanes.live set bit 0 of dbFlags for known military airframes.
    flags = ac.get("dbFlags")
    if type(flags) == "int" and flags % 2 == 1:
        return True
    return (ac.get("t") or "").strip().upper() in MIL_TYPES

def type_color(p):
    return MIL_COLOR if p["mil"] else CIV_COLOR

def ident(ac):
    for k in ["flight", "r", "hex"]:
        v = (ac.get(k) or "").strip().upper()
        if v:
            return v
    return "UNKNOWN"

def dist_brg(lat1, lon1, lat2, lon2):
    p1 = math.radians(lat1)
    p2 = math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    dp = p2 - p1

    a = math.pow(math.sin(dp / 2), 2) + math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2)
    dist = 2 * 3440.065 * math.atan2(math.sqrt(a), math.sqrt(1 - a))  # nm

    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    brg = (math.degrees(math.atan2(y, x)) + 360) % 360
    return dist, brg

# ---------------------------------------------------------------- radar

def px(x, y, color):
    return render.Padding(
        pad = (int(x), int(y), 0, 0),
        child = render.Box(width = 1, height = 1, color = color),
    )

def ring_points(radius):
    seen = {}
    pts = []
    for d in range(0, 360, 2):
        x = int(math.round(CX + radius * math.sin(math.radians(d))))
        y = int(math.round(CY - radius * math.cos(math.radians(d))))
        key = "%d,%d" % (x, y)
        if key not in seen:
            seen[key] = True
            pts.append((x, y))
    return pts

def radar_background():
    kids = [render.Box(width = 64, height = 32, color = "#000000")]
    for (x, y) in ring_points(R_PX):
        kids.append(px(x, y, RING_OUTER))
    for (x, y) in ring_points(R_PX / 2):
        kids.append(px(x, y, RING_INNER))

    # North tick
    kids.append(px(CX, 0, "#2a7a3a"))
    kids.append(px(CX, 1, "#2a7a3a"))

    kids.append(px(CX, CY, HOME))

    # Divider between scope and card
    kids.append(
        render.Padding(
            pad = (32, 1, 0, 0),
            child = render.Box(width = 1, height = 30, color = DIVIDER),
        ),
    )
    return render.Stack(children = kids)

def sweep_layer(angle):
    kids = []
    for i, c in enumerate(SWEEP):
        a = math.radians(angle - i * 6)
        for r in range(2, R_PX):
            x = int(math.round(CX + r * math.sin(a)))
            y = int(math.round(CY - r * math.cos(a)))
            kids.append(px(x, y, c))
    return render.Stack(children = kids)

def blips_layer(planes, sel, sweep, f):
    kids = []

    for p in planes:
        if p == sel:
            continue
        color = alt_color(p)

        # Afterglow: brightest right after the sweep passes, fades over a turn.
        since = (sweep - p["brg"] + 360) % 360
        bright = 1.0 - 0.5 * (since / 360.0)

        if p["track"] != None:
            tx = p["x"] - 1.5 * math.sin(math.radians(p["track"]))
            ty = p["y"] + 1.5 * math.cos(math.radians(p["track"]))
            kids.append(px(math.round(tx), math.round(ty), dim(color, bright * 0.35)))
        kids.append(px(math.round(p["x"]), math.round(p["y"]), dim(color, bright)))

    # Selected aircraft: solid white with a blinking target box.
    x = int(math.round(sel["x"]))
    y = int(math.round(sel["y"]))
    if (f // 5) % 2 == 0:
        for (dx, dy) in [(-2, -2), (-1, -2), (1, -2), (2, -2), (-2, -1), (2, -1), (-2, 1), (2, 1), (-2, 2), (-1, 2), (1, 2), (2, 2)]:
            if 0 <= x + dx and x + dx < 32 and 0 <= y + dy and y + dy < 32:
                kids.append(px(x + dx, y + dy, "#ffdd33"))
    kids.append(px(x, y, "#ffffff"))

    return render.Stack(children = kids)

# ---------------------------------------------------------------- card

def info_card(p, idx, total):
    color = alt_color(p)
    return render.Padding(
        pad = (34, 0, 0, 0),
        child = render.Column(
            children = [
                txt(p["call"][:8], "#ffdd33"),
                render.Row(
                    children = [
                        txt(p["type"][:4], type_color(p)),
                        render.Box(width = 2, height = 6),
                        txt("%d/%d" % (idx + 1, total), "#445566"),
                    ],
                ),
                txt(alt_str(p), color),
                render.Row(
                    children = [
                        txt(dist_str(p["dist"]), "#66ccff"),
                        txt("nm", "#336688"),
                        render.Box(width = 2, height = 6),
                        txt(compass(p["brg"]), "#66ccff"),
                    ],
                ),
                txt(spd_str(p), "#ffffff"),
            ],
        ),
    )

def txt(s, color):
    return render.Text(content = s, font = "tom-thumb", color = color)

def alt_str(p):
    if p["ground"]:
        return "GND"
    if p["alt"] == None:
        return "ALT ?"
    a = int(p["alt"])
    vs = p["vs"] or 0
    trend = "^" if vs > 300 else ("v" if vs < -300 else "")
    if a >= 18000:
        fl = str(int((a + 50) / 100))
        return "FL" + ("0" * (3 - len(fl))) + fl + trend
    return commas(int((a + 50) / 100) * 100) + trend

def commas(n):
    s = str(n)
    if len(s) <= 3:
        return s
    return s[:-3] + "," + s[-3:]

def dist_str(d):
    if d < 10:
        return str(int(d * 10) / 10.0)
    return str(int(d))

def spd_str(p):
    if p["gs"] == None:
        return "--kt"
    return "%dkt" % int(p["gs"])

def compass(brg):
    pts = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    return pts[int((brg + 22.5) / 45) % 8]

# ---------------------------------------------------------------- colors

# Altitude bands, roughly following the FlightAware / tar1090 look.
def alt_color(p):
    if p["ground"]:
        return "#888888"
    a = p["alt"]
    if a == None:
        return "#bbbbbb"
    if a < 2000:
        return "#ff8833"
    if a < 6000:
        return "#ffdd33"
    if a < 12000:
        return "#66ff66"
    if a < 25000:
        return "#33ccff"
    return "#cc77ff"

def dim(hexcolor, factor):
    h = hexcolor.lstrip("#")
    out = "#"
    for i in [0, 2, 4]:
        v = int(int(h[i:i + 2], 16) * factor)
        v = max(0, min(255, v))
        out += HEX[v // 16] + HEX[v % 16]
    return out

HEX = "0123456789abcdef"

# ---------------------------------------------------------------- misc

def status_screen(range_nm, msg, color):
    background = radar_background()
    frames = []
    for f in range(30):
        frames.append(
            render.Stack(
                children = [
                    background,
                    sweep_layer((f * SWEEP_STEP) % 360),
                    render.Padding(
                        pad = (34, 7, 0, 0),
                        child = render.Column(
                            children = [
                                txt(msg, color),
                                txt("%dnm" % range_nm, "#445566"),
                            ],
                        ),
                    ),
                ],
            ),
        )
    return render.Root(delay = 100, child = render.Animation(children = frames))

def demo_aircraft(lat, lon):
    # Fake traffic around the default center for testing renders offline.
    def at(dlat, dlon):
        return lat + dlat, lon + dlon

    rows = [
        ("N12876", "C172", 2500, 0, 98, 140, 0.05, -0.06),
        ("FLAG21", "H60", 1200, 0, 120, 90, -0.12, 0.10),
        ("DAL1789", "B739", 31000, 0, 455, 45, 0.25, 0.20),
        ("REACH42", "C17", 14500, 1800, 310, 300, -0.20, -0.25),
        ("N714NL", "C150", 3200, -400, 85, 200, 0.02, -0.12),
        ("AAL2311", "A321", 9800, -1500, 280, 250, 0.30, -0.10),
        ("EAGLE6", "H47", 800, 0, 110, 10, -0.05, 0.22),
    ]
    out = []
    for (call, t, alt, vs, gs, trk, dla, dlo) in rows:
        la, lo = at(dla, dlo)
        out.append({
            "flight": call,
            "t": t,
            "alt_baro": alt,
            "baro_rate": vs,
            "gs": gs,
            "track": trk,
            "lat": la,
            "lon": lo,
            "dbFlags": 1 if call in ["FLAG21", "REACH42", "EAGLE6"] else 0,
        })
    return out

# ---------------------------------------------------------------- schema

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Location(
                id = "location",
                name = "Location",
                desc = "Center of the radar scope.",
                icon = "locationDot",
            ),
            schema.Dropdown(
                id = "range",
                name = "Range",
                desc = "Radius of the scope in nautical miles.",
                icon = "circleDot",
                default = str(DEFAULT_RANGE_NM),
                options = [
                    schema.Option(display = "%d nm" % r, value = str(r))
                    for r in [5, 10, 15, 25, 40, 60]
                ],
            ),
            schema.Dropdown(
                id = "layout",
                name = "Layout",
                desc = "How traffic is drawn.",
                icon = "tableCells",
                default = "radar",
                options = [
                    schema.Option(display = "Radar + card", value = "radar"),
                    schema.Option(display = "Big card", value = "card"),
                    schema.Option(display = "List", value = "list"),
                    schema.Option(display = "ATC scope", value = "scope"),
                    schema.Option(display = "Pointer", value = "pointer"),
                ],
            ),
            schema.Toggle(
                id = "show_ground",
                name = "Show ground traffic",
                desc = "Include aircraft reporting on the ground.",
                icon = "planeArrival",
                default = False,
            ),
        ],
    )

# ================================================================ alt layouts

def line_px(x0, y0, x1, y1, color, skip_start = 0):
    """Bresenham line as a list of 1px widgets."""
    x0, y0, x1, y1 = int(x0), int(y0), int(x1), int(y1)
    dx = abs(x1 - x0)
    dy = -abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx + dy
    out = []
    n = 0
    for _ in range(200):
        if n >= skip_start and 0 <= x0 and x0 < 64 and 0 <= y0 and y0 < 32:
            out.append(px(x0, y0, color))
        n += 1
        if x0 == x1 and y0 == y1:
            break
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x0 += sx
        if e2 <= dx:
            err += dx
            y0 += sy
    return out

def arrow_px(cx, cy, deg, length, color, head = 3):
    """Arrow from (cx, cy) pointing at compass bearing deg."""
    a = math.radians(deg)
    tx = math.round(cx + length * math.sin(a))
    ty = math.round(cy - length * math.cos(a))
    kids = line_px(cx, cy, tx, ty, color)
    for side in [-150, 150]:
        b = math.radians(deg + side)
        kids += line_px(tx, ty, math.round(tx + head * math.sin(b)), math.round(ty - head * math.cos(b)), color)
    return kids

def progress_dots(n, idx, y):
    kids = []
    x0 = 32 - (n * 4 - 1) // 2
    for i in range(n):
        kids.append(
            render.Padding(
                pad = (x0 + i * 4, y, 0, 0),
                child = render.Box(width = 3, height = 1, color = "#ffdd33" if i == idx else "#333333"),
            ),
        )
    return kids

def at(x, y, child):
    return render.Padding(pad = (int(x), int(y), 0, 0), child = child)

def hundreds(p):
    """ATC-style altitude in hundreds of feet: 025, 310."""
    if p["ground"]:
        return "GND"
    if p["alt"] == None:
        return "XXX"
    h = str(int((p["alt"] + 50) / 100))
    return ("0" * (3 - len(h))) + h

def trend(p):
    vs = p["vs"] or 0
    return "^" if vs > 300 else ("v" if vs < -300 else "")

# ---------------------------------------------------------------- layout: card

def layout_card(planes):
    cards = planes[:MAX_CARDS]
    frames = []
    for i, p in enumerate(cards):
        color = alt_color(p)
        top = render.Box(
            width = 64,
            height = 8,
            child = render.Padding(
                pad = (1, 0, 1, 0),
                child = render.Row(
                    expanded = True,
                    main_align = "space_between",
                    cross_align = "end",
                    children = [
                        render.Text(p["call"][:9], font = "tb-8", color = "#ffdd33"),
                        txt(p["type"][:4], type_color(p)),
                    ],
                ),
            ),
        )
        alt = render.Text(alt_str(p), font = "6x13", color = color)
        bottom = render.Box(
            width = 64,
            height = 6,
            child = render.Padding(
                pad = (1, 0, 1, 0),
                child = render.Row(
                    expanded = True,
                    main_align = "space_between",
                    children = [
                        render.Row(children = [
                            txt(dist_str(p["dist"]), "#66ccff"),
                            txt("nm ", "#336688"),
                            txt(compass(p["brg"]), "#66ccff"),
                        ]),
                        txt(spd_str(p), "#ffffff"),
                    ],
                ),
            ),
        )

        # Small heading arrow showing which way it's flying.
        hdg = []
        if p["track"] != None:
            hdg = arrow_px(56, 15, p["track"], 6, color, 3)

        frame = render.Stack(children = [
            render.Box(width = 64, height = 32, color = "#000000"),
            at(0, 0, top),
            at(1, 9, alt),
            render.Stack(children = hdg),
            at(0, 24, bottom),
            render.Stack(children = progress_dots(len(cards), i, 31)),
        ])
        frames += [frame] * FRAMES_PER_CARD
    return animate(frames)

# ---------------------------------------------------------------- layout: list

ROWS_PER_PAGE = 4

def layout_list(planes, range_nm):
    shown = planes[:ROWS_PER_PAGE * 3]
    pages = [shown[i:i + ROWS_PER_PAGE] for i in range(0, len(shown), ROWS_PER_PAGE)]
    header = render.Stack(children = [
        render.Box(width = 64, height = 6, color = "#0d3018"),
        at(1, 0, txt("TFC %d" % len(planes), "#66ff88")),
        at(64 - 4 * len("%dNM" % range_nm), 0, txt("%dNM" % range_nm, "#3a8a4a")),
    ])

    frames = []
    for pi, page in enumerate(pages):
        kids = [render.Box(width = 64, height = 32, color = "#000000"), header]
        for r, p in enumerate(page):
            y = 6 + r * 6
            d = dist_str(p["dist"])
            kids.append(at(0, y, txt(p["call"][:7], "#ffdd33")))
            kids.append(at(30, y, txt(hundreds(p) + trend(p), alt_color(p))))
            kids.append(at(64 - 4 * len(d), y, txt(d, "#66ccff")))
        if len(pages) > 1:
            kids += progress_dots(len(pages), pi, 31)
        frame = render.Stack(children = kids)
        frames += [frame] * (FRAMES_PER_CARD + 10)
    return animate(frames)

# ---------------------------------------------------------------- layout: scope

def layout_scope(planes):
    """STARS-style: wide scope, data block with leader line on one target."""
    cx = 31
    cy = 15
    bg = [render.Box(width = 64, height = 32, color = "#000000")]
    for r, c in [(15, RING_OUTER), (7.5, RING_INNER)]:
        for (x, y) in ring_points(r):
            bg.append(px(x + (cx - CX), y + (cy - CY), c))
    bg.append(px(cx, cy, HOME))
    background = render.Stack(children = bg)

    cards = planes[:MAX_CARDS]
    frames = []
    for sel in cards:
        kids = [background]
        for p in planes:
            x = math.round(p["x"] + (cx - CX))
            y = math.round(p["y"] + (cy - CY))
            kids.append(px(x, y, "#ffffff" if p == sel else dim(alt_color(p), 0.8)))

        sx = int(math.round(sel["x"] + (cx - CX)))
        sy = int(math.round(sel["y"] + (cy - CY)))
        block_w = 4 * max(len(sel["call"][:7]), 6)
        right = sx + 4 + block_w <= 64
        bx = sx + 4 if right else sx - 3 - block_w
        by = max(0, min(20, sy - 8))
        lx = sx + 3 if right else sx - 3
        ly = sy - 3
        leader = line_px(sx, sy, lx, ly, "#2ad4ff", 1)

        spd = "--" if sel["gs"] == None else str(int(sel["gs"] / 10))
        block = render.Box(
            width = block_w,
            height = 12,
            child = render.Column(children = [
                txt(sel["call"][:7], "#2ad4ff"),
                txt(hundreds(sel) + trend(sel) + " " + spd, "#2ad4ff"),
            ]),
        )
        kids += leader
        kids.append(at(max(0, bx), by, block))
        frame = render.Stack(children = kids)
        frames += [frame] * FRAMES_PER_CARD
    return animate(frames)

# ---------------------------------------------------------------- layout: pointer

def layout_pointer(planes):
    """Big compass arrow pointing at each of the nearest aircraft."""
    bg = [render.Box(width = 64, height = 32, color = "#000000")]
    for (x, y) in ring_points(R_PX):
        bg.append(px(x, y, "#222a33"))
    bg.append(at(CX - 1, 1, render.Text("N", font = "CG-pixel-3x5-mono", color = "#556677")))
    bg.append(render.Padding(pad = (32, 1, 0, 0), child = render.Box(width = 1, height = 30, color = "#1a2230")))
    background = render.Stack(children = bg)

    cards = planes[:MAX_CARDS]
    frames = []
    for i, p in enumerate(cards):
        color = alt_color(p)
        card = info_card(p, i, len(planes))
        for f in range(FRAMES_PER_CARD):
            # Arrow "grows" in over the first few frames of each target.
            length = min(12, 4 + f)
            frames.append(render.Stack(children = [
                background,
                render.Stack(children = arrow_px(CX, CY, p["brg"], length, color, 4)),
                px(CX, CY, "#ffffff"),
                card,
            ]))
    return animate(frames)
