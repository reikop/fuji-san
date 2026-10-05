# Builds assets/builtin_recipes.json from the "Fujifilm Film Simulation Recipes
# Database" spreadsheet maintained by Henri-Pierre Chavaz.
#
#   pip install openpyxl
#   python tool/build_builtin_recipes.py "<recipes.xlsx>" [--report]
#
# Settings in the sheet are free text written by many authors. A recipe is kept
# only when every field it mentions parses unambiguously into the app schema
# (lib/domain/recipe.dart); anything doubtful is skipped rather than guessed.
import collections
import json
import re
import sys
import unicodedata
import warnings

import openpyxl

SENSORS = ("X-Trans IV", "X-Trans V")
FILMS = {
    "provia": 1, "velvia": 2, "astia": 3, "pro neg. high": 4, "pro neg. std": 5,
    "monochrome": 6, "sepia": 10, "classic chrome": 11, "acros": 12, "eterna": 16,
    "classic negative": 17, "nostalgic negative": 19,
}
FILTERS = {"y": 1, "ye": 1, "yellow": 1, "r": 2, "red": 2, "g": 3, "green": 3}
EFFECT = {"off": 1, "weak": 2, "strong": 3}
NOISE = {-4: 32768, -3: 28672, -2: 16384, -1: 12288, 0: 8192, 1: 4096, 2: 0, 3: 24576, 4: 20480}
WB_MODES = [
    (r"auto white priority|white priority|awb-?w\b", 32800),
    (r"ambi[ea]nce priority|auto ambi[ea]nce|awb-?a\b", 32801),
    (r"fluorescent(?: light)?[ -]?\(?1|daylight fluorescent", 32769),
    (r"fluorescent(?: light)?[ -]?\(?2|warm.white fluorescent", 32770),
    (r"fluorescent(?: light)?[ -]?\(?3|cool.white fluorescent", 32771),
    (r"underwater", 8),
    (r"incandescent|tungsten", 6),
    (r"shade", 32774),
    (r"daylight|fine|sunny", 4),
    (r"auto|awb", 2),
]
NUM = r"(?<![\d.])([+-]? ?\d(?:[.,]\d+)?)"
IGNORED = r"^(exposure|exp\b|ev\b|push|iso(?!.*noise)|film simulation)"


class Skip(Exception):
    pass


def number(text, low, high, half=False):
    value = float(text.replace(" ", "").replace(",", "."))
    if value < low or value > high or (value * 2) % (1 if half else 2) != 0:
        raise Skip("range")
    return value


def clean(text):
    text = unicodedata.normalize("NFKC", text).lower()
    for a, b in (
        ("–", "-"), ("—", "-"), ("−", "-"), ("‑", "-"), ("colour", "color"), ("%", ""),
        ("’", "'"), ("flourescent", "fluorescent"), ("hightlight", "highlight"),
    ):
        text = text.replace(a, b)
    lines = [re.sub(r"\s+", " ", line).strip() for line in text.split("\n") if line.strip()]
    return [line for line in lines if not re.search(IGNORED, line)]


def find(lines, pattern, exclude=None):
    hits = [
        m for line in lines
        if not (exclude and re.search(exclude, line))
        for m in [re.search(pattern, line)] if m
    ]
    if len({m.groups() for m in hits}) > 1:
        raise Skip("conflict")
    return hits[0] if hits else None


def parse(base, settings):
    lines = clean(settings)
    lines = [re.sub(r"n/a \(x-trans iii\) or off \(x-t3/x-t30\)", "off", line) for line in lines]
    text = " ".join(lines)
    if re.search(r"patrons only|custom|\bor\b|double exposure|multiple exposure", text):
        raise Skip("unsupported")
    base = re.sub(r"\s+", " ", base.strip().lower())
    if base not in FILMS:
        raise Skip("film")
    film = FILMS[base]
    if "bleach bypass" in text:
        if film != 16:
            raise Skip("film")
        film = 18
    if "reala" in text:
        raise Skip("film")
    if film in (6, 12):
        m = re.search(
            r"(?:acros|monochrome|mono)\W{0,3}(?:with |\+ ?)?(yellow|ye|red|green|y|r|g)\b(?: filter)?",
            text,
        )
        if m:
            film += FILTERS[m.group(1)]
        elif "filter" in text:
            raise Skip("filter")
    mono = film in (6, 7, 8, 9, 10, 12, 13, 14, 15)
    v = {0xD192: film}

    m = re.search(r"(?:d-?range|dynamic range|dr) ?priority:? ?(off|weak|strong|auto)", text)
    v[0xD191] = {"off": 0, "weak": 1, "strong": 2, "auto": 32768}[m.group(1)] if m else 0
    m = find(lines, r"(?:dynamic range|^d-?range|^dr)[: -]*(?:dr)?[ -]?(auto|100|200|400)\b", r"priority: ?(?!off)")
    if m:
        if len(set(re.findall(r"auto|100|200|400", m.string))) > 1:
            raise Skip("dynamic range")
        v[0xD190] = 65535 if m.group(1) == "auto" else int(m.group(1))
    elif v[0xD191] == 0:
        raise Skip("dynamic range")
    else:
        v[0xD190] = 100

    v[0xD193] = v[0xD194] = 0
    if mono:
        for key, name in ((0xD193, "wc"), (0xD194, "mg")):
            m = re.search(rf"\b{name}:? ?([+-]? ?\d+)", text) or re.search(rf"([+-]? ?\d+) ?{name}\b", text)
            if m:
                v[key] = int(number(m.group(1), -18, 18) * 10)
        if not (v[0xD193] or v[0xD194]) and re.search(r"(toning|monochromatic color)[: ]*(?![ :0]|off|n/a|none)", text):
            raise Skip("toning")

    m = find(lines, r"^grain(?: effect)?(?: roughness)?[: -]*(.+)$", r"grain size")
    if not m:
        raise Skip("grain")
    grain = m.group(1)
    # The size is sometimes on its own line, or wrapped onto the next one.
    size = find(lines, r"^(?:grain size[: -]*)?(small|large)$")
    if re.search(r"\boff\b", grain):
        v[0xD195] = 1
    else:
        strength = re.findall(r"weak|strong", grain)
        sizes = re.findall(r"small|large", grain) or ([size.group(1)] if size else ["small"])
        if len(strength) != 1 or len(sizes) != 1:
            raise Skip("grain")
        v[0xD195] = {"weak": 2, "strong": 3}[strength[0]] + (2 if sizes[0] == "large" else 0)

    m = find(lines, r"^(?:color chrome|chrome color|chrome)(?: effect)?(?: fx)?[: -]*(off|weak|strong)\b", r"blue")
    v[0xD196] = EFFECT[m.group(1)] if m else 1
    if not m and any("chrome" in line and "blue" not in line for line in lines):
        raise Skip("color chrome")
    m = find(lines, r"^(?:color chrome|chrome)?[ -]*(?:effect|fx)?[ -]*blue(?: effect)?[: -]*(off|weak|strong)\b")
    v[0xD197] = EFFECT[m.group(1)] if m else 1
    if not m and re.search(r"(fx|chrome|effect) blue", text):
        raise Skip("color chrome blue")
    m = re.search(r"smooth skin(?: effect)?[: -]*(off|weak|strong)", text)
    v[0xD198] = EFFECT[m.group(1)] if m else 1

    wb = [
        line for line in lines
        if re.match(r"(white balance|wb|awb|auto white balance)\b|k?\d{4,5}k?$", line)
    ]
    if not wb:
        raise Skip("white balance")
    joined = " ".join(wb)
    if re.search(r"\bor\b|between", joined):
        raise Skip("white balance")
    kelvin = set(re.findall(r"(?<!\d)(\d{4,5})(?!\d)", joined))
    modes = {code for pattern, code in WB_MODES if re.search(pattern, joined)}
    if 32800 in modes or 32801 in modes:
        modes.discard(2)
    if 32769 in modes or 32770 in modes or 32771 in modes:
        modes.discard(4)
    if len(kelvin) == 1 and modes <= {2}:
        v[0xD199] = 32775
        v[0xD19C] = int(kelvin.pop())
        if not 2500 <= v[0xD19C] <= 10000 or v[0xD19C] % 10:
            raise Skip("kelvin")
    elif len(modes) == 1 and not kelvin:
        v[0xD199] = modes.pop()
        v[0xD19C] = 5600
    else:
        raise Skip("white balance")
    shifts = set()
    for pattern in (
        NUM + r" ?(?:red|r)\b[ ,;&/]*(?:and )?" + NUM + r" ?(?:blue|b)\b",
        r"(?<![a-z])(?:red|r)[: =]*" + NUM + r"[ ,;&/]*(?:and )?(?<![a-z])(?:blue|b)[: =]*" + NUM,
    ):
        for m in re.finditer(pattern, text):
            shifts.add((m.group(1), m.group(2)))
    shifts = {(int(number(r, -9, 9)), int(number(b, -9, 9))) for r, b in shifts}
    if len(shifts) > 1:
        raise Skip("wb shift")
    if not shifts and re.search(r"shift|\bred\b|\bblue\b(?<!fx blue)(?<!effect blue)(?<!chrome blue)", joined):
        raise Skip("wb shift")
    v[0xD19A], v[0xD19B] = shifts.pop() if shifts else (0, 0)

    curve = [line for line in lines if "curve" in line or line.startswith("tone")]

    def tone(key, pattern, low, high, required, half=False, exclude=None, short=None):
        m = find(lines, pattern, exclude) or (short and find(curve, short))
        if m:
            v[key] = int(number(m.group(1), low, high, half) * 10)
        elif required:
            raise Skip(hex(key))
        else:
            v[key] = 0

    toned = v[0xD191] == 0
    tone(0xD19D, r"(?:highlights?|h-?tone)(?: tone)?[: ]*" + NUM, -2, 4, toned, True, short=r"\bh ?[:=]? ?" + NUM)
    tone(0xD19E, r"(?:shadows?|s-?tone)(?: tone)?[: ]*" + NUM, -2, 4, toned, True, short=r"\bs ?[:=]? ?" + NUM)
    tone(0xD19F, r"^(?:color|saturation)[: ]*" + NUM, -4, 4, not mono, exclude=r"chrome")
    tone(0xD1A0, r"^sharp\w*[: ]*" + NUM, -4, 4, True)
    tone(0xD1A2, r"^clarity[: ]*" + NUM, -5, 5, False)
    m = find(lines, r"(?:noise reduction(?:/high iso nr)?|noise red\.?|high iso nr|iso-nr|^nr|^noise)[: ]*" + NUM)
    if not m and re.search(r"noise|\bnr\b", text):
        raise Skip("noise reduction")
    v[0xD1A1] = NOISE[int(number(m.group(1), -4, 4))] if m else NOISE[0]
    return v


def camera_name(name):
    ascii_name = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    ascii_name = re.sub(r"[^A-Za-z0-9 _.,+()\-]", " ", ascii_name)
    return re.sub(r"\s+", " ", ascii_name).strip()[:25].strip()


def main():
    warnings.simplefilter("ignore")
    sheet = openpyxl.load_workbook(sys.argv[1], data_only=True)["Recipes"]
    recipes, reasons, seen = [], collections.Counter(), set()
    for row in sheet.iter_rows(min_row=2, values_only=True):
        creator, name, _, _, camera, sensor, base, settings, _, url = row[:10]
        if not name or not str(sensor or "").startswith(SENSORS):
            continue
        try:
            if not settings or not base or not str(url or "").startswith("http"):
                raise Skip("incomplete")
            values = parse(str(base), str(settings))
            name = re.sub(r"\s+", " ", str(name)).strip()
            short = camera_name(name)
            if not short or len(name) > 120 or name.lower() == "unnamed":
                raise Skip("name")
            key = (name.lower(), json.dumps(values, sort_keys=True))
            if key in seen:
                raise Skip("duplicate")
            seen.add(key)
            recipes.append({
                "name": name,
                "cameraName": short,
                "creator": re.sub(r"\s+", " ", str(creator or "")).strip(),
                "camera": str(camera or "").strip(),
                "sensor": str(sensor).strip(),
                "url": str(url).strip(),
                "values": {format(k, "x"): value for k, value in values.items()},
            })
        except Skip as skip:
            reasons[str(skip)] += 1
            if "--report" in sys.argv:
                print("SKIP", skip, "|", name, "|", repr(str(settings))[:300])
    recipes.sort(key=lambda r: r["name"].lower())
    with open("assets/builtin_recipes.json", "w", encoding="utf-8", newline="\n") as out:
        json.dump(
            {
                "format": "fuji-san-builtin",
                "version": 1,
                "source": "Fujifilm Film Simulation Recipes Database, Henri-Pierre Chavaz",
                "recipes": recipes,
            },
            out,
            ensure_ascii=False,
            separators=(",", ":"),
        )
    print(len(recipes), "recipes written;", dict(reasons), file=sys.stderr)


main()
