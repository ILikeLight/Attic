#!/usr/bin/env python3
"""Builds Attic/Resources/GameDB.sqlite from the libretro-database.

The libretro-database (https://github.com/libretro/libretro-database, CC BY-SA 4.0) holds the
No-Intro and Redump lists in clrmamepro form, with checksums and game codes, and separate lists
with release years. Attic only needs a small part of it: for each game the system, the checksum
or game code to find it by, the No-Intro or Redump name (which is also the name of its libretro
thumbnail), the title, the year and the region. GameDB.sqlite is an adaptation of the
libretro-database and falls under CC BY-SA 4.0 as well.

Only the metadat and dat folders are needed:
    git clone --filter=blob:none --sparse https://github.com/libretro/libretro-database
    git -C libretro-database sparse-checkout set metadat dat

Usage: python3 Database/build_database.py <libretro-database> [out.sqlite]
"""
import difflib
import os
import re
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "..", "Attic", "Resources", "GameDB.sqlite")


class System:
    def __init__(self, attic, lists, crc=False, serial=None, years=(), titles=None):
        self.attic = attic            # Attic's GameSystem
        self.lists = lists            # No-Intro or Redump lists, under metadat/
        self.crc = crc                # cartridges: found by checksum
        self.serial = serial          # how a game code from the list becomes Attic's (see serial_keys)
        self.years = years            # (list, key) pairs with release years: key "crc" or "serial"
        self.titles = titles          # a list with nicer titles and years by game code (GameTDB's, for GameCube and Wii)


SYSTEMS = [
    System("gb", ["no-intro/Nintendo - Game Boy.dat", "no-intro/Nintendo - Game Boy Color.dat"], crc=True,
           years=[("releaseyear/Nintendo - Game Boy.dat", "crc"), ("releaseyear/Nintendo - Game Boy Color.dat", "crc")]),
    System("gba", ["no-intro/Nintendo - Game Boy Advance.dat"], crc=True, serial="plain",
           years=[("releaseyear/Nintendo - Game Boy Advance.dat", "crc")]),
    # The Famicom Disk System is played by Nestopia, so it is the NES in Attic.
    System("nes", ["no-intro/Nintendo - Nintendo Entertainment System.dat", "no-intro/Nintendo - Family Computer Disk System.dat"],
           crc=True, years=[("releaseyear/Nintendo - Nintendo Entertainment System.dat", "crc"),
                            ("releaseyear/Nintendo - Family Computer Disk System.dat", "crc")]),
    System("snes", ["no-intro/Nintendo - Super Nintendo Entertainment System.dat"], crc=True,
           years=[("releaseyear/Nintendo - Super Nintendo Entertainment System.dat", "crc")]),
    System("n64", ["no-intro/Nintendo - Nintendo 64.dat"], crc=True, serial="plain",
           years=[("releaseyear/Nintendo - Nintendo 64.dat", "crc")]),
    System("ds", ["no-intro/Nintendo - Nintendo DS.dat"], crc=True, serial="plain",
           years=[("releaseyear/Nintendo - Nintendo DS.dat", "crc")]),
    System("n3ds", ["no-intro/Nintendo - Nintendo 3DS.dat", "no-intro/Nintendo - New Nintendo 3DS.dat"], serial="last"),
    System("md", ["no-intro/Sega - Mega Drive - Genesis.dat"], crc=True,
           years=[("releaseyear/Sega - Mega Drive - Genesis.dat", "crc")]),
    # Discs are found by game code: the lists have the checksum of a whole disc or track, which
    # says nothing about a .chd, .rvz or .cso.
    System("gc", ["redump/Nintendo - GameCube.dat"], serial="nintendo-disc", titles="../dat/Nintendo - GameCube.dat"),
    System("wii", ["redump/Nintendo - Wii.dat"], serial="nintendo-disc", titles="../dat/Nintendo - Wii.dat"),
    System("ps1", ["redump/Sony - PlayStation.dat"], serial="plain",
           years=[("developer/Sony - PlayStation.dat", "serial")]),
    System("psp", ["no-intro/Sony - PlayStation Portable.dat", "redump/Sony - PlayStation Portable.dat"], serial="plain",
           years=[("releaseyear/Sony - PlayStation Portable.dat", "serial")]),
    System("dc", ["redump/Sega - Dreamcast.dat"], serial="dreamcast"),
]

# Regions as Attic shows them.
REGIONS = {
    "USA": "USA", "Canada": "USA", "Europe": "EUR", "UK": "EUR", "Germany": "EUR", "France": "EUR",
    "Italy": "EUR", "Spain": "EUR", "Netherlands": "EUR", "Sweden": "EUR", "Denmark": "EUR",
    "Finland": "EUR", "Norway": "EUR", "Scandinavia": "EUR", "Greece": "EUR", "Ireland": "EUR",
    "Portugal": "EUR", "Poland": "EUR", "Russia": "EUR", "Belgium": "EUR", "Austria": "EUR", "Switzerland": "EUR",
    "Japan": "JPN", "Korea": "KOR", "China": "CHN", "Hong Kong": "CHN", "Taiwan": "TWN", "Asia": "Azië",
    "Australia": "AUS", "New Zealand": "AUS", "Brazil": "BRA", "World": "Wereld", "USA, Europe": "USA/EUR",
    "Japan, USA": "JPN/USA", "Japan, Europe": "JPN/EUR", "USA, Australia": "USA", "Europe, Australia": "EUR",
    "USA, Korea": "USA/KOR", "USA, Brazil": "USA", "Japan, Korea": "JPN/KOR", "Brazil, Korea": "BRA/KOR",
    "Asia, Australia": "Azië", "USA, Canada": "USA", "Japan, USA, Europe": "Wereld", "USA, Japan": "JPN/USA",
}


# MARK: clrmamepro lists

TOKEN = re.compile(r'"((?:[^"\\]|\\.)*)"|([()])|([^\s()"]+)')


def parse_dat(path):
    """The games of a clrmamepro list: a dict per game, with a list of dicts under "rom"."""
    with open(path, encoding="utf-8", errors="replace") as file:
        tokens = [(quoted, paren, word) for quoted, paren, word in TOKEN.findall(file.read())]
    games = []
    position = 0

    def block():
        nonlocal position
        fields = {}
        while position < len(tokens):
            quoted, paren, word = tokens[position]
            position += 1
            if paren == ")":
                return fields
            key = word or quoted
            if position < len(tokens) and tokens[position][1] == "(":
                position += 1
                fields.setdefault(key, []).append(block())
            elif position < len(tokens):
                value_quoted, _, value_word = tokens[position]
                position += 1
                fields.setdefault(key, value_quoted if value_quoted or not value_word else value_word)
        return fields

    while position < len(tokens):
        quoted, paren, word = tokens[position]
        position += 1
        if word in ("game", "machine") and position < len(tokens) and tokens[position][1] == "(":
            position += 1
            games.append(block())
        elif paren == "(":
            block()
    return games


# MARK: Keys and names

def serial_values(game):
    """Every game code a list gives for a game; some list several, separated by commas."""
    raw = [game.get("serial", "")] + [rom.get("serial", "") for rom in game.get("rom", [])]
    values = []
    for text in raw:
        for part in str(text).split(","):
            part = part.strip()
            if part and part not in values:
                values.append(part)
    return values


def plain_key(serial):
    """Game codes without separators, as Attic compares them: SCUS-94900 → SCUS94900."""
    return re.sub(r"[^0-9A-Z]", "", serial.upper())


def serial_keys(game, style):
    keys = []
    for serial in serial_values(game):
        if style == "plain":
            key = plain_key(serial)
        elif style == "last":
            # 3DS: CTR-P-BTVJ → BTVJ, the code in the game's header.
            key = plain_key(serial.split("-")[-1])
        elif style == "dreamcast":
            # The boot header holds ten characters: MK-51000-53 is MK-5100053 there. Sega's own American
            # discs are listed by number only (51000), their header says MK-51000.
            key = plain_key(serial)
            for extra in [plain_key(serial[:10])] + (["MK" + key] if key.isdigit() else []):
                if extra and extra not in keys:
                    keys.append(extra)
        elif style == "nintendo-disc":
            # GameCube and Wii: DL-DOL-GW7E-USA or RVL-RJ2J-JPN → GW7E, the first four letters of the
            # disc's ID (GW7E69); Attic looks them up by those four.
            match = re.search(r"(?:DOL|RVL)-([A-Z0-9]{4})", serial.upper())
            key = match.group(1) if match else plain_key(serial)[:4]
        else:
            key = None
        if key and key not in keys:
            keys.append(key)
    return keys


def year_of(text):
    match = re.search(r"(19[7-9]\d|20[0-4]\d)", str(text or ""))
    return int(match.group(1)) if match else None


ARTICLES = "The|A|An|Die|Der|Das|Le|La|Les|L'|El|Los|Las|Il|Lo|De|Het"


def title_from_name(name):
    """'Legend of Zelda, The - The Minish Cap (Europe)' → 'The Legend of Zelda: The Minish Cap'."""
    title = re.sub(r"\s*[\(\[][^\)\]]*[\)\]]", "", name).strip()
    title = re.sub(rf"^([^,\-:]+), ({ARTICLES})(?=\s|$)", r"\2 \1", title)
    title = re.sub(r"\bPokemon\b", "Pokémon", title)
    return title.replace(" - ", ": ")


def region_of(game):
    """From the name, which lists every region ("USA, Europe"); the region field has only the first."""
    match = re.search(r"\(([^)]+)\)", game.get("name", ""))
    for region in [match.group(1) if match else None, game.get("region")]:
        if region in REGIONS:
            return REGIONS[region]
    return None


# Where a game code says a game was sold: the last letter of a Nintendo code, the third of Sony's.
NINTENDO_REGION = {"E": "USA", "P": "Europe", "J": "Japan", "K": "Korea", "D": "Germany", "F": "France",
                   "S": "Spain", "I": "Italy", "H": "Netherlands", "U": "Australia", "X": "Europe", "Y": "Europe",
                   "C": "China", "W": "Taiwan"}
SONY_REGION = {"U": "USA", "E": "Europe", "P": "Japan", "J": "Japan", "M": "Japan", "A": "Asia", "K": "Korea", "C": "China"}


def preference(system, serial, name):
    """Lower is better, for several games under one game code: the one from the region the code is
    for, and a finished game before a demo or prototype."""
    expected = None
    if serial and system in ("gba", "ds", "n64", "gc", "wii", "n3ds") and len(serial) >= 4:
        expected = NINTENDO_REGION.get(serial[3])
    elif serial and system in ("ps1", "psp") and len(serial) >= 3:
        expected = SONY_REGION.get(serial[2])
    regions = re.search(r"\(([^)]+)\)", name)
    score = 0 if not expected or (regions and expected in regions.group(1)) else 1
    if re.search(r"\((Beta|Proto|Demo|Kiosk|Sample|Preview|Trial)[^)]*\)", name):
        score += 2
    return score


# MARK: Building

def years_for(root, system):
    by_crc, by_serial = {}, {}
    for list_path, key in system.years:
        path = os.path.normpath(os.path.join(root, "metadat", list_path))
        if not os.path.exists(path):
            print(f"  (no {list_path})")
            continue
        for game in parse_dat(path):
            year = year_of(game.get("releaseyear"))
            if not year:
                continue
            if key == "crc":
                for rom in game.get("rom", []):
                    if rom.get("crc"):
                        by_crc.setdefault(int(rom["crc"], 16), year)
            else:
                for serial in serial_keys(game, system.serial or "plain"):
                    by_serial.setdefault(serial, year)
    return by_crc, by_serial


def strip_tags(name):
    return re.sub(r"\s*[\(\[][^\)\]]*[\)\]]", "", name).strip()


def comparable(text):
    return re.sub(r"[^0-9a-z]", "", text.lower())


def titles_for(root, system):
    """GameTDB's titles and years for GameCube and Wii discs ("007: Agent Under Fire"), by the first
    four letters of the game code. That list also has mods and homebrew that reuse a game's code."""
    titles = {}
    if not system.titles:
        return titles
    for game in parse_dat(os.path.normpath(os.path.join(root, "metadat", system.titles))):
        for key in serial_keys(game, system.serial):
            titles.setdefault(key, []).append((strip_tags(game.get("name", "")), year_of(game.get("releaseyear"))))
    return titles


def gametdb_match(candidates, name):
    """The GameTDB entry that is this disc, not a mod with its code: the one named most alike."""
    wanted = comparable(title_from_name(name))
    best, best_ratio = None, 0.0
    for title, year in candidates:
        ratio = difflib.SequenceMatcher(None, wanted, comparable(title)).ratio()
        if ratio > best_ratio:
            best, best_ratio = (title, year), ratio
    return best if best_ratio >= 0.6 else None


def rows_for(root, system):
    years_by_crc, years_by_serial = years_for(root, system)
    titles = titles_for(root, system)
    rows = []
    for list_path in system.lists:
        for game in parse_dat(os.path.join(root, "metadat", list_path)):
            name = game.get("name")
            if not name:
                continue
            serials = serial_keys(game, system.serial) if system.serial else []
            crcs = []
            if system.crc:
                crcs = [int(rom["crc"], 16) for rom in game.get("rom", []) if rom.get("crc")]
            tdb = next((match for key in serials if key in titles
                        for match in [gametdb_match(titles[key], name)] if match), None)
            year = next((years_by_crc[crc] for crc in crcs if crc in years_by_crc), None) \
                or next((years_by_serial[key] for key in serials if key in years_by_serial), None) \
                or (tdb[1] if tdb else None) or year_of(game.get("releaseyear"))
            title = tdb[0] if tdb else title_from_name(name)
            region = region_of(game)
            # One row per checksum and game code, so either finds the game; without either, by its name.
            for crc in crcs or [None]:
                for serial in serials or [None]:
                    rows.append((system.attic, crc, serial, name, title, year, region))
    # A version without a year gets the year of another version of the same game.
    years = {}
    for row in rows:
        if row[5]:
            years[row[4]] = min(years.get(row[4], row[5]), row[5])
    return [row if row[5] else row[:5] + (years.get(row[4]),) + row[6:] for row in rows]


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    root = os.path.abspath(sys.argv[1])
    out = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_OUT)

    rows = []
    for system in SYSTEMS:
        rows += rows_for(root, system)
    rows = list(dict.fromkeys(rows))
    # Rows with the same checksum or game code go in best first: Attic takes the first one it finds.
    rows.sort(key=lambda row: (row[0], row[2] or "", row[1] or -1, preference(row[0], row[2], row[3]), row[3]))

    if os.path.exists(out):
        os.remove(out)
    db = sqlite3.connect(out)
    db.executescript("""
        PRAGMA page_size = 4096;
        CREATE TABLE games (
            system TEXT NOT NULL,   -- Attic's GameSystem
            crc INTEGER,            -- CRC32 as No-Intro counts it: no copier header, N64 in big-endian order
            serial TEXT,            -- game code without separators: A2DE, GW7E, BTVJ, SCUS94900, ULUS10336, MK51000
            name TEXT NOT NULL,     -- No-Intro or Redump name, also the libretro thumbnail name
            title TEXT NOT NULL,
            year INTEGER,
            region TEXT
        );
    """)
    db.executemany("INSERT INTO games VALUES (?, ?, ?, ?, ?, ?, ?)", rows)
    db.executescript("""
        CREATE INDEX games_crc ON games (crc) WHERE crc IS NOT NULL;
        CREATE INDEX games_serial ON games (serial) WHERE serial IS NOT NULL;
        CREATE INDEX games_name ON games (system, name);
    """)
    db.commit()
    db.execute("VACUUM")
    db.close()
    games, years, counts = set(), 0, {}
    for row in rows:
        if (row[0], row[3]) not in games:
            games.add((row[0], row[3]))
            counts[row[0]] = counts.get(row[0], 0) + 1
            years += row[5] is not None
    print(f"{out}: {len(games)} games ({years} with a year), {len(rows)} rows, {os.path.getsize(out) // 1024} KB")
    print("  " + ", ".join(f"{system} {count}" for system, count in sorted(counts.items())))


if __name__ == "__main__":
    main()
