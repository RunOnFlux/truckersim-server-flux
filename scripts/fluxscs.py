#!/usr/bin/env python3
"""Every decision about the SCS convoy server's files (Euro Truck Simulator 2 / American Truck
Simulator), and the hub's commands.

    fluxscs.py apply                   server_config.sii and config_ds.cfg from the environment and the
                                       panel; the map packages if none were uploaded (before every start)
    fluxscs.py state <state> [msg]     record what the supervisor is doing (flux/state.json)
    fluxscs.py backup <reason>         a backup of the settings and packages (the supervisor's "start")
    fluxscs.py restore-apply <name>    put a backup back (the supervisor, with the server stopped)

    flux-scs status                    state, players (from the server log), session search id, version
    flux-scs settings                  the panel's settings, the env that overrides them, the limits
    flux-scs set-settings '<json>'     save settings (applied on the next start)
    flux-scs packages                  which map / DLC / mods the server's packages ask for
    flux-scs set-packages <sii> <dat>  install a server_packages pair exported from the game
    flux-scs reset-packages            back to the base map (no DLC, no mods)
    flux-scs backups                   the backups of the settings and packages, newest first
    flux-scs restore <name>            restart the server onto a backup (a safety backup is made first)
    flux-scs restart                   stop and start again

The game is SCS_GAME: ets2 (Euro Truck Simulator 2, app 1948160) or ats (American Truck
Simulator, app 2239530). The server has no console and no RCON: everything goes through its
files, which it reads at start, and its log.

Precedence: an environment variable that is SET to a non-empty value is applied on every start;
one that is unset OR EMPTY leaves the panel's value, then the default. (The marketplace writes
every declared parameter, blank ones too: an empty one is "the panel decides".) The moderators
are the one list that MERGES: the variable's and the panel's together.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

GAME = (os.environ.get("SCS_GAME") or "ets2").strip().lower()
GAMES = {
    "ets2": {"name": "Euro Truck Simulator 2", "home": "Euro Truck Simulator 2", "app": "1948160",
             "binary": "eurotrucks2_server", "game_app": "227300", "map": "/map/europe.mbd"},
    "ats": {"name": "American Truck Simulator", "home": "American Truck Simulator", "app": "2239530",
            "binary": "amtrucks_server", "game_app": "270880", "map": "/map/usa.mbd"},
}
G = GAMES.get(GAME, GAMES["ets2"])
OTHER = "ats" if GAME == "ets2" else "ets2"
SERVER_DIR = os.environ.get("FLUX_SERVER_DIR", "/mnt/scs/server")
DATA_DIR = os.environ.get("FLUX_DATA_DIR", "/mnt/scs/data")
STATE_DIR = os.environ.get("FLUX_STATE_DIR", os.path.join(DATA_DIR, "flux"))
STATE_FILE = os.path.join(STATE_DIR, "state.json")
SETTINGS_FILE = os.path.join(STATE_DIR, "settings.json")
BACKUP_DIR = os.environ.get("FLUX_BACKUP_DIR", os.path.join(STATE_DIR, "backups"))
BACKUP_INDEX = os.path.join(BACKUP_DIR, "index.json")
# The server's home: XDG_DATA_HOME is the data volume, the game's folder inside it.
HOME = os.path.join(DATA_DIR, G["home"])
CONFIG = os.path.join(HOME, "server_config.sii")
CONFIG_DS = os.path.join(HOME, "config_ds.cfg")
PACKAGES_SII = os.path.join(HOME, "server_packages.sii")
PACKAGES_DAT = os.path.join(HOME, "server_packages.dat")
BANLIST = os.path.join(HOME, "banlist.txt")
SERVER_LOG = os.path.join(HOME, "server.log.txt")
DEFAULT_PACKAGES = os.environ.get("FLUX_DEFAULT_PACKAGES", "/opt/flux/default_packages")
# The log parser's place in the current log, so a poll reads only what was written since the last
# one (the server appends to server.log.txt for as long as it runs).
LOG_STATE = os.environ.get("FLUX_LOG_STATE", "/tmp/flux-scs-logstate.json")
RESTART_MARKER = os.environ.get("FLUX_RESTART_MARKER", "/tmp/flux-restart-requested")
RESTORE_MARKER = os.environ.get("FLUX_RESTORE_MARKER", "/tmp/flux-restore-requested")

# The official cap. More is possible (config_ds.cfg g_max_convoy_size) but every PLAYER must set
# the same value in their own game, or they do not see the session.
OFFICIAL_MAX = 8
MAX_PLAYERS_CAP = 128

# Backups: tiny (settings and packages), so many are kept; the rules match every Flux game image.
BACKUP_KEEP = int(os.environ.get("FLUX_BACKUP_KEEP", "10") or 10)
BACKUP_MIN_AGE = int(os.environ.get("FLUX_BACKUP_MIN_AGE_MINUTES", "60") or 60) * 60
# What a backup holds, relative to the data volume. Nothing else is ever unpacked from one.
BACKUP_FILES = [
    os.path.join("flux", "settings.json"),
    os.path.join(G["home"], "server_packages.sii"),
    os.path.join(G["home"], "server_packages.dat"),
    os.path.join(G["home"], "banlist.txt"),
]
BACKUP_NAME_RE = re.compile(r"^\d{8}-\d{6}(-\d{1,3})?-(ets2|ats)\.tar\.gz$")

# The maps each game's packages may name. A mod map (ProMods and the like) has its own .mbd: what
# is checked is that it is not the OTHER game's.
MAP_OTHER_GAME = {
    "ets2": re.compile(r"(usa|canada|america|mexico|alaska)", re.I),
    "ats": re.compile(r"(europe|promods\.mbd$|russia|balkan|iberia|scandinavia)", re.I),
}
# setting: (server_config.sii key, kind, default, limit)
SETTINGS = {
    "lobbyName": ("lobby_name", "text", f"{G['name']} on Flux", 63),
    "description": ("description", "text", "", 63),
    "welcome": ("welcome_message", "text", "", 127),
    "password": ("password", "text", "", 63),
    "maxPlayers": ("max_players", "int", OFFICIAL_MAX, MAX_PLAYERS_CAP),
    "maxVehicles": ("max_vehicles_total", "int", 100, 1000),
    "maxAiPlayer": ("max_ai_vehicles_player", "int", 50, 500),
    "maxAiSpawn": ("max_ai_vehicles_player_spawn", "int", 50, 500),
    "token": ("server_logon_token", "text", "", 64),
    "playerDamage": ("player_damage", "bool", True, None),
    "traffic": ("traffic", "bool", True, None),
    "hideInCompany": ("hide_in_company", "bool", False, None),
    "hideColliding": ("hide_colliding", "bool", True, None),
    "forceSpeedLimiter": ("force_speed_limiter", "bool", False, None),
    "modsOptioning": ("mods_optioning", "bool", False, None),
    "timezones": ("timezones", "int", 0, 2),
    "serviceNoCollision": ("service_no_collision", "bool", False, None),
    "inMenuGhosting": ("in_menu_ghosting", "bool", False, None),
    "nameTags": ("name_tags", "bool", True, None),
    "moderators": ("moderator_list", "list", [], None),
    "allowLoad": (None, "bool", False, None),
}
ENV = {
    "SCS_LOBBY_NAME": "lobbyName", "SCS_DESCRIPTION": "description", "SCS_WELCOME": "welcome",
    "SCS_PASSWORD": "password", "SCS_MAX_PLAYERS": "maxPlayers", "SCS_TOKEN": "token",
    "SCS_MODERATORS": "moderators", "SCS_PLAYER_DAMAGE": "playerDamage", "SCS_TRAFFIC": "traffic",
    "SCS_FORCE_SPEED_LIMITER": "forceSpeedLimiter", "SCS_NAME_TAGS": "nameTags",
    "SCS_SERVICE_NO_COLLISION": "serviceNoCollision", "SCS_IN_MENU_GHOSTING": "inMenuGhosting",
    "SCS_TIMEZONES": "timezones", "SCS_MAX_AI": "maxAiPlayer",
}
SECRETS = ("password", "token")
# Characters a one-line .sii string cannot hold: C0 and C1 controls, the Unicode line and paragraph
# separators, and the quote and backslash the .sii syntax gives a meaning.
BAD_TEXT = re.compile('[\x00-\x1f\x7f-\x9f  "\\\\]')


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_text(path, text, encoding="utf-8"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".flux-")
    with os.fdopen(fd, "w", encoding=encoding) as f:
        f.write(text)
    os.replace(tmp, path)


def write_json(path, data, indent=2):
    write_text(path, json.dumps(data, indent=indent, ensure_ascii=False) + "\n")


def out(data):
    print(json.dumps(data, ensure_ascii=False))


def fail(message, code=1):
    out({"ok": False, "error": message})
    sys.exit(code)


def load_settings():
    data = read_json(SETTINGS_FILE, {})
    return data if isinstance(data, dict) else {}


def clean_text(value):
    """One line of text a .sii string can hold: the characters it cannot are dropped (each one a
    space), and runs of spaces closed up."""
    return re.sub(r" {2,}", " ", BAD_TEXT.sub(" ", str(value))).strip()


def coerce(name, value):
    _, kind, _, limit = SETTINGS[name]
    if kind == "bool":
        if isinstance(value, bool):
            return value
        v = str(value).strip().lower()
        if v in ("1", "true", "yes", "on"):
            return True
        if v in ("0", "false", "no", "off"):
            return False
        raise ValueError(f"{name} must be true or false")
    if kind == "int":
        if not re.fullmatch(r"\d{1,5}", str(value).strip()):
            raise ValueError(f"{name} must be a whole number")
        n = int(str(value).strip())
        low = 1 if name == "maxPlayers" else 0
        if not low <= n <= limit:
            raise ValueError(f"{name} must be {low} to {limit}")
        return n
    if kind == "list":
        items = value if isinstance(value, list) else re.split(r"[\s,;]+", str(value or ""))
        items = [str(i).strip() for i in items if str(i).strip()]
        bad = [i for i in items if not re.fullmatch(r"7656119\d{10}", i)]
        if bad:
            raise ValueError(f"not a SteamID64: {', '.join(bad)}")
        return list(dict.fromkeys(items))
    text = clean_text(value)
    if name == "token" and text and not re.fullmatch(r"[0-9A-Fa-f]{32}", text):
        raise ValueError("a Steam game server login token is 32 letters and digits")
    if name == "lobbyName" and not text:
        raise ValueError("the convoy needs a name: drivers find it by its name")
    return text[:limit]


def env_value(name):
    """The variable's value, or None when it is unset or EMPTY (the marketplace writes blank
    declared parameters: blank means "the panel decides")."""
    value = os.environ.get(name)
    if value is None or not str(value).strip():
        return None
    return value


def effective(settings=None):
    """(values, sources, warnings). sources: "env", "panel", "default", or "env+panel" for the
    moderators, which merge. warnings: env values that could not be used (and so were not)."""
    settings = load_settings() if settings is None else settings
    values, sources, warnings = {}, {}, []
    env_for = {v: k for k, v in ENV.items()}
    for name, (_, _, default, _) in SETTINGS.items():
        env = env_for.get(name)
        raw = env_value(env) if env else None
        from_env = None
        if raw is not None:
            try:
                from_env = coerce(name, raw)
            except ValueError as e:
                warnings.append(f"{env} is not used: {e}")
        if name == "moderators":
            panel = settings.get("moderators") or []
            merged = list(dict.fromkeys((from_env or []) + list(panel)))
            values[name] = merged
            sources[name] = "env+panel" if from_env and panel else "env" if from_env else "panel" if panel else "default"
            continue
        if from_env is not None:
            values[name], sources[name] = from_env, "env"
        elif name in settings:
            values[name], sources[name] = settings[name], "panel"
        else:
            values[name], sources[name] = default, "default"
    return values, sources, warnings


def sii_value(kind, value):
    if kind == "bool":
        return "true" if value else "false"
    if kind == "int":
        return str(int(value))
    return '"' + clean_text(value) + '"'


def render_config(values, port, query_port):
    lines = ["SiiNunit", "{", "server_config : _nameless.flux.0001 {"]
    for name, (key, kind, _, _) in SETTINGS.items():
        if key is None:
            continue
        value = values[name]
        if kind == "list":
            lines.append(f" {key}: {len(value)}")
            lines += [f" {key}[{i}]: {v}" for i, v in enumerate(value)]
            continue
        if name == "maxPlayers":
            continue
        lines.append(f" {key}: {sii_value(kind, value)}")
        if key == "max_ai_vehicles_player_spawn":
            lines += [" connection_virtual_port: 100", " query_virtual_port: 101",
                      f" connection_dedicated_port: {port}", f" query_dedicated_port: {query_port}"]
    lines.insert(3, f" max_players: {values['maxPlayers']}")
    lines += [" friends_only: false", " show_server: true", "}", "", "}"]
    return "\n".join(lines) + "\n"


def set_cfg(text, key, value):
    line = f'uset {key} "{value}"'
    if re.search(rf"^uset {re.escape(key)} .*$", text, re.M):
        return re.sub(rf"^uset {re.escape(key)} .*$", line, text, flags=re.M)
    return text.rstrip("\n") + "\n" + line + "\n"


def packages_fingerprint():
    """What the server will drive on at its next start: the uploaded pair, or (none uploaded) the
    base map the image installs then."""
    sii, dat = PACKAGES_SII, PACKAGES_DAT
    if not (os.path.exists(sii) and os.path.exists(dat)):
        sii = os.path.join(DEFAULT_PACKAGES, GAME, "server_packages.sii")
        dat = os.path.join(DEFAULT_PACKAGES, GAME, "server_packages.dat")
    h = hashlib.sha1()
    for path in (sii, dat):
        try:
            with open(path, "rb") as f:
                h.update(f.read())
        except OSError:
            h.update(b"-")
    return h.hexdigest()


def cmd_apply():
    notes = []
    values, sources, warnings = effective()
    notes += [f"WARN {w}" for w in warnings]
    port = int(os.environ.get("SCS_PORT", "27015"))
    query_port = int(os.environ.get("SCS_QUERY_PORT", str(port + 1)))
    os.makedirs(HOME, exist_ok=True)
    write_text(CONFIG, render_config(values, port, query_port))
    # The server clamps max_players to g_max_convoy_size (8 unless raised) and writes the clamped
    # value back: both are written, every start.
    try:
        cfg = open(CONFIG_DS, encoding="utf-8", errors="replace").read()
    except OSError:
        cfg = "# prism3d variable config data\n\n"
    cfg = set_cfg(cfg, "g_max_convoy_size", max(values["maxPlayers"], OFFICIAL_MAX))
    cfg = set_cfg(cfg, "g_convoy_allow_load", 1 if values["allowLoad"] else 0)
    write_text(CONFIG_DS, cfg)
    if not (os.path.exists(PACKAGES_SII) and os.path.exists(PACKAGES_DAT)):
        src = os.path.join(DEFAULT_PACKAGES, GAME)
        shutil.copy2(os.path.join(src, "server_packages.sii"), PACKAGES_SII)
        shutil.copy2(os.path.join(src, "server_packages.dat"), PACKAGES_DAT)
        notes.append("packages: none uploaded, so the base map (no DLC, no mods)")
    notes.append(f"{G['name']}: {values['lobbyName']!r}, {values['maxPlayers']} players, password {'set' if values['password'] else 'none'}, token {'set' if values['token'] else 'none (the session id changes on every start)'}, {len(values['moderators'])} moderator(s)")
    if values["maxPlayers"] > OFFICIAL_MAX:
        notes.append(f"more than {OFFICIAL_MAX} players: every player must set g_max_convoy_size {values['maxPlayers']} in their own config.cfg to see the session")
    state = read_json(STATE_FILE, {}) or {}
    state["applied"] = int(time.time()) + 1
    state["packagesApplied"] = packages_fingerprint()
    write_json(STATE_FILE, state, indent=None)
    for note in notes:
        print(f"# {note}")


# ------------------------------------------------------------------------------------------------
# State and status
# ------------------------------------------------------------------------------------------------

def cmd_state(state, message=None):
    data = read_json(STATE_FILE, {}) or {}
    if data.get("state") != state:
        data["since"] = int(time.time())
    data.update({"state": state, "message": message or None, "image": os.environ.get("FLUX_IMAGE_VERSION", "dev"), "game": GAME})
    generation = os.environ.get("FLUX_GENERATION")
    if generation and generation.isdigit():
        data["generation"] = int(generation)
    write_json(STATE_FILE, data, indent=None)


JOIN_RE = re.compile(r"\[MP\] (.+?) connected, client_id = (\d+)")
LEAVE_RE = re.compile(r"\[MP\] (.+?) disconnected, client_id = (\d+)")
SEARCH_RE = re.compile(r"Session search id: (\S+)")
VERSION_RE = re.compile(r"(\d+\.\d+\.\d+\.\d+s?)\b")
CHAT_RE = re.compile(r"^(\d{2}:\d{2}:\d{2}\.\d{3}) : \[MP\] \[Chat\] (.*)$")
# Every ~3 minutes the server logs its own headcount: the truth when a disconnect went unlogged.
STATE_RE = re.compile(r"\[MP\] State: \w+;\s*Time: \d+;\s*Players: (\d+)")


def parse_log(lines, start=None):
    """The roster, session search id, version and chat from log lines. `start` carries on from an
    earlier parse (the incremental poll)."""
    st = start or {"online": {}, "search": None, "version": None, "chat": [], "reported": None}
    online = dict(st.get("online") or {})
    search, version, chat, reported = st.get("search"), st.get("version"), list(st.get("chat") or []), st.get("reported")
    for line in lines:
        m = JOIN_RE.search(line)
        if m:
            online[m.group(2)] = {"name": m.group(1).strip(), "id": m.group(2)}
            continue
        m = LEAVE_RE.search(line)
        if m:
            online.pop(m.group(2), None)
            continue
        m = STATE_RE.search(line)
        if m:
            reported = int(m.group(1))
            # Nobody on, by the server's own count: whoever the log still lists left without a
            # disconnect line (a timeout, a crash of their game).
            if reported == 0:
                online = {}
            continue
        m = SEARCH_RE.search(line)
        if m:
            search = m.group(1)
        if version is None and "version" in line.lower():
            v = VERSION_RE.search(line)
            if v:
                version = v.group(1)
        m = CHAT_RE.match(line)
        if m:
            chat.append({"time": m.group(1), "text": m.group(2)})
    return {"online": online, "search": search, "version": version, "chat": chat[-50:], "reported": reported}


def read_log_incremental():
    """parse_log over the current server.log.txt, reading only what was written since the last call
    (a convoy server can run for weeks, and the panel polls every 15 seconds). The log is a new
    file on every start (the supervisor moves the old one away), so a changed inode, or a file
    shorter than where we were, starts over."""
    try:
        st = os.stat(SERVER_LOG)
    except OSError:
        return parse_log([])
    saved = read_json(LOG_STATE, {}) or {}
    if saved.get("ino") != st.st_ino or saved.get("offset", 0) > st.st_size:
        saved = {"ino": st.st_ino, "offset": 0, "parsed": None}
    with open(SERVER_LOG, "rb") as f:
        f.seek(saved["offset"])
        data = f.read()
    # Only whole lines: a line the server is still writing is read next time.
    end = data.rfind(b"\n") + 1
    lines = data[:end].decode("utf-8", "replace").splitlines()
    parsed = parse_log(lines, saved.get("parsed"))
    try:
        write_json(LOG_STATE, {"ino": st.st_ino, "offset": saved["offset"] + end, "parsed": parsed}, indent=None)
    except OSError:
        pass
    return parsed


def players_from(parsed):
    return list((parsed.get("online") or {}).values())


def cmd_status():
    state = read_json(STATE_FILE, {}) or {}
    values, _, _ = effective()
    running = state.get("state") == "running"
    parsed = read_log_incremental() if running else parse_log([])
    out({"state": state.get("state", "stopped"), "message": state.get("message"), "since": state.get("since"),
         "generation": state.get("generation"),
         "image": state.get("image"), "game": GAME, "gameName": G["name"], "version": parsed["version"],
         "players": players_from(parsed), "reportedPlayers": parsed["reported"],
         "max_players": values["maxPlayers"], "name": values["lobbyName"],
         "searchId": parsed["search"], "chat": parsed["chat"], "packages": packages_info(),
         "pending": pending(state)})


def pending(state):
    """True when the panel saved something the running server has not picked up: settings newer
    than the last apply, or packages (uploaded, reset) other than the ones that start used."""
    applied = state.get("applied") or 0
    try:
        if os.path.getmtime(SETTINGS_FILE) > applied:
            return True
    except OSError:
        pass
    if state.get("packagesApplied") is None:
        return False
    return packages_fingerprint() != state["packagesApplied"]


# ------------------------------------------------------------------------------------------------
# Packages
# ------------------------------------------------------------------------------------------------

def parse_packages(text):
    """server_packages.sii: the map, the DLC players must own (essential) or may have, the mods."""
    def lst(key):
        return re.findall(rf"^\s*{key}\[\d+\]:\s*\"?([^\"\n]*)\"?\s*$", text, re.M)
    m = re.search(r'map_name:\s*"([^"]*)"', text)
    t = re.search(r"time_stamp:\s*(\d+)", text)
    return {"map": m.group(1) if m else None, "essentialDlc": lst("dlc_essential_list"),
            "optionalDlc": lst("dlc_non_essential_list"), "mods": lst("mod_list"),
            "timeStamp": int(t.group(1)) if t else None}


def dat_time_stamp(path):
    """The time stamp a server_packages.dat carries: the little-endian 32-bit number at byte 2
    (checked on both base-map pairs: it equals the .sii's time_stamp)."""
    try:
        with open(path, "rb") as f:
            head = f.read(6)
    except OSError:
        return None
    return int.from_bytes(head[2:6], "little") if len(head) == 6 else None


def packages_info():
    try:
        text = open(PACKAGES_SII, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    info = parse_packages(text)
    # The base map is the pair the image ships, whatever it lists: the American Truck Simulator one
    # names two OPTIONAL DLC, so "no DLC and no mods" would call it an upload.
    try:
        shipped = open(os.path.join(DEFAULT_PACKAGES, GAME, "server_packages.sii"), encoding="utf-8", errors="replace").read()
    except OSError:
        shipped = None
    info["default"] = text == shipped or (info.get("mods") == [] and info.get("essentialDlc") == [] and info.get("optionalDlc") == [])
    return info


def cmd_packages():
    out({"packages": packages_info(), "game": GAME, "expectedMap": G["map"]})


def check_packages(text, dat):
    """Why this pair cannot be this server's, or None."""
    if "server_packages_info" not in text:
        return "this is not a server_packages.sii (export it in the game: console, export_server_packages)"
    info = parse_packages(text)
    other = GAMES[OTHER]["name"]
    if not info["map"] or not info["map"].startswith("/map/") or not info["map"].endswith(".mbd"):
        return f"unexpected map {info['map'] or '(none)'}"
    if MAP_OTHER_GAME[GAME].search(info["map"]):
        return f"these packages are for {other} ({info['map']}), this server is {G['name']}"
    # The game writes each DLC as an unsigned number (both base-map pairs); the server refuses
    # anything else ("Expecting unsigned value", measured) and does not start.
    raw_dlc = re.findall(r"^\s*dlc_(?:non_)?essential_list\[\d+\]:\s*(.+?)\s*$", text, re.M)
    if any(not re.fullmatch(r"\d{1,20}", v) for v in raw_dlc):
        return "this .sii was not written by the game (its DLC entries are not the numbers the game writes): export it again with export_server_packages"
    if not os.path.isfile(dat) or os.path.getsize(dat) < 16:
        return "the .dat file is missing or empty (export_server_packages writes both)"
    stamp = dat_time_stamp(dat)
    if info["timeStamp"] is not None and stamp is not None and stamp != info["timeStamp"]:
        return "the .sii and the .dat are from two different exports: upload the two files written together"
    return None


def cmd_set_packages(sii, dat):
    try:
        text = open(sii, encoding="utf-8", errors="replace").read()
    except OSError:
        fail("cannot read the .sii file", 2)
    problem = check_packages(text, dat)
    if problem:
        fail(problem, 2)
    backup("before new packages", force=True)
    # The .sii names the .dat it goes with; the server looks for it in its home.
    text = re.sub(r'roads_data_file_name:\s*"[^"]*"', 'roads_data_file_name: "/home/server_packages.dat"', text)
    os.makedirs(HOME, exist_ok=True)
    shutil.copy2(dat, PACKAGES_DAT + ".flux-new")
    write_text(PACKAGES_SII, text)
    os.replace(PACKAGES_DAT + ".flux-new", PACKAGES_DAT)
    out({"ok": True, "packages": packages_info(), "appliesOn": "restart"})


def cmd_reset_packages():
    backup("before the base map", force=True)
    for p in (PACKAGES_SII, PACKAGES_DAT):
        try:
            os.remove(p)
        except OSError:
            pass
    out({"ok": True, "appliesOn": "restart"})


# ------------------------------------------------------------------------------------------------
# Backups: the settings, the packages and the ban list (there is no world)
# ------------------------------------------------------------------------------------------------

def list_backups():
    """[(name, path, mtime, size)], newest first."""
    rows = []
    try:
        names = os.listdir(BACKUP_DIR)
    except OSError:
        return rows
    for name in names:
        if BACKUP_NAME_RE.match(name):
            path = os.path.join(BACKUP_DIR, name)
            try:
                st = os.stat(path)
            except OSError:
                continue
            rows.append((name, path, st.st_mtime, st.st_size))
    # Newest first; within one second, the -N suffix orders them.
    def order(r):
        m = re.match(r"^\d{8}-\d{6}(?:-(\d+))?-", r[0])
        return (r[2], int(m.group(1)) if m and m.group(1) else 1)
    rows.sort(key=order, reverse=True)
    return rows


def backups_to_prune(rows, now, keep=BACKUP_KEEP):
    """The backups to delete: all but the newest `keep`, except the newest one older than a day and
    the newest one older than a week, so a run of restarts never rotates every good backup away.
    rows: [(name, mtime)], newest first."""
    keep_names = {name for name, _ in rows[:keep]}
    for age in (86400, 7 * 86400):
        older = [name for name, mtime in rows if now - mtime >= age]
        if older:
            keep_names.add(older[0])
    return [name for name, _ in rows if name not in keep_names]


def backup(reason, force=False):
    """A backup now. Unless forced, skipped when the newest one is younger than
    FLUX_BACKUP_MIN_AGE_MINUTES (a start right after another start adds nothing)."""
    now = time.time()
    rows = list_backups()
    if not force and rows and now - rows[0][2] < BACKUP_MIN_AGE:
        return None
    present = [rel for rel in BACKUP_FILES if os.path.isfile(os.path.join(DATA_DIR, rel))]
    if not present:
        return ""
    os.makedirs(BACKUP_DIR, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime(now))
    name = f"{stamp}-{GAME}.tar.gz"
    # Two in the same second (a change right after another): each keeps its own state.
    for n in range(2, 1000):
        if not os.path.exists(os.path.join(BACKUP_DIR, name)):
            break
        name = f"{stamp}-{n}-{GAME}.tar.gz"
    path = os.path.join(BACKUP_DIR, name)
    part = path + ".part"
    with tarfile.open(part, "w:gz") as tar:
        for rel in present:
            tar.add(os.path.join(DATA_DIR, rel), arcname=rel)
    os.replace(part, path)
    index = read_json(BACKUP_INDEX, {}) or {}
    index[name] = reason
    for old in backups_to_prune([(n, m) for n, _, m, _ in list_backups()], now):
        try:
            os.remove(os.path.join(BACKUP_DIR, old))
        except OSError:
            pass
        index.pop(old, None)
    write_json(BACKUP_INDEX, index)
    return name


def cmd_backup(reason):
    name = backup(reason, force=reason != "start")
    if name:
        print(f"# backup ({reason}): {os.path.relpath(os.path.join(BACKUP_DIR, name), DATA_DIR)}")
    else:
        print(f"# backup ({reason}): {'nothing to back up yet' if name == '' else 'skipped, the newest is under an hour old'}")


def cmd_backups():
    index = read_json(BACKUP_INDEX, {}) or {}
    out({"backups": [{"name": n, "size": s, "modified": int(m), "reason": index.get(n)} for n, _, m, s in list_backups()],
         "path": os.path.relpath(BACKUP_DIR, DATA_DIR), "contains": BACKUP_FILES})


def cmd_restore(name):
    if not BACKUP_NAME_RE.match(name) or not os.path.isfile(os.path.join(BACKUP_DIR, name)):
        fail("no such backup", 2)
    if not name.endswith(f"-{GAME}.tar.gz"):
        fail(f"that backup is from the other game's server, not {G['name']}", 2)
    with open(RESTORE_MARKER, "w") as f:
        f.write(name + "\n")
    pids = subprocess.run(["pgrep", "-f", rf"^\./{G['binary']}"], capture_output=True, text=True).stdout.split()
    if pids:
        with open(RESTART_MARKER, "w") as f:
            f.write(f"requested: restore {name}\n")
        import signal
        for pid in pids:
            os.kill(int(pid), signal.SIGINT)
        out({"ok": True, "backup": name, "appliesOn": "now"})
    else:
        out({"ok": True, "backup": name, "appliesOn": "start"})


def cmd_restore_apply(name):
    """With the server stopped: a safety backup of what is there now, then the chosen backup's
    files put back. Only the files a backup holds are ever written."""
    path = os.path.join(BACKUP_DIR, name)
    if not BACKUP_NAME_RE.match(name) or not os.path.isfile(path):
        print(f"# WARN restore: no backup {name}")
        return
    safety = backup("pre-restore", force=True) or "(nothing to keep)"
    staging = tempfile.mkdtemp(dir=DATA_DIR, prefix=".flux-restore-")
    try:
        with tarfile.open(path, "r:gz") as tar:
            members = [m for m in tar.getmembers() if m.isfile() and m.name in BACKUP_FILES]
            for m in members:
                tar.extract(m, staging, filter="data") if hasattr(tarfile, "data_filter") else tar.extract(m, staging)
        restored = []
        for rel in BACKUP_FILES:
            src = os.path.join(staging, rel)
            dst = os.path.join(DATA_DIR, rel)
            if os.path.isfile(src):
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                os.replace(src, dst)
                restored.append(rel)
            else:
                # Not in the backup: it did not exist then (no panel settings yet, the base map, no
                # bans), so it does not now either.
                try:
                    os.remove(dst)
                except OSError:
                    pass
        print(f"# restored {name} ({', '.join(restored) or 'nothing'}); the state before it is {safety}")
    finally:
        shutil.rmtree(staging, ignore_errors=True)


# ------------------------------------------------------------------------------------------------
# Settings
# ------------------------------------------------------------------------------------------------

def cmd_settings():
    values, sources, warnings = effective()
    shown = {k: (("(set)" if v else "") if k in SECRETS else v) for k, v in values.items()}
    env_moderators = []
    raw = env_value("SCS_MODERATORS")
    if raw:
        try:
            env_moderators = coerce("moderators", raw)
        except ValueError:
            pass
    out({"values": shown, "sources": sources, "game": GAME, "officialMax": OFFICIAL_MAX,
         "maxPlayersCap": MAX_PLAYERS_CAP, "tokenApp": G["game_app"],
         "moderators": {"env": env_moderators, "panel": load_settings().get("moderators") or []},
         "envWarnings": warnings,
         "env": {k: v for k, v in ENV.items() if env_value(k) is not None}})


def cmd_set_settings(raw):
    try:
        incoming = json.loads(raw)
    except ValueError:
        fail("not JSON")
    if not isinstance(incoming, dict):
        fail("expected a JSON object")
    settings = load_settings()
    errors = []
    for name, value in incoming.items():
        if name not in SETTINGS:
            errors.append(f"unknown setting {name}")
            continue
        if value is None:
            settings.pop(name, None)
            continue
        try:
            settings[name] = coerce(name, value)
        except ValueError as e:
            errors.append(str(e))
    if errors:
        fail("; ".join(errors), 2)
    backup("before a settings change", force=True)
    write_json(SETTINGS_FILE, settings)
    out({"ok": True, "settings": {k: v for k, v in settings.items() if k not in SECRETS}, "appliesOn": "restart"})


def cmd_restart():
    pids = subprocess.run(["pgrep", "-f", rf"^\./{G['binary']}"], capture_output=True, text=True).stdout.split()
    if not pids:
        # No game process, but the supervisor may well be alive: a container restart then only
        # throws its work away (the first 1.3 GB download, the Steam back-off) or fails the same way
        # (refused packages). Exit 3 is kept for when nothing is there to pick the change up.
        state = read_json(STATE_FILE, {}) or {}
        if state.get("state") == "crashed" and "server packages" in str(state.get("message") or ""):
            # The supervisor is waiting for new packages; the marker ends the wait.
            with open(RESTART_MARKER, "w") as f:
                f.write("requested: from the panel\n")
            out({"ok": True, "appliesOn": "now"})
            return
        if state.get("state") in ("updating", "starting", "restarting"):
            # The next start writes the configs from what is saved: nothing to signal.
            out({"ok": True, "appliesOn": "start"})
            return
        fail("the server is not running", 3)
    with open(RESTART_MARKER, "w") as f:
        f.write("requested: from the panel\n")
    import signal
    for pid in pids:
        os.kill(int(pid), signal.SIGINT)
    out({"ok": True})


def main(argv):
    commands = {
        "apply": (cmd_apply, (0,)), "state": (cmd_state, (1, 2)), "status": (cmd_status, (0,)),
        "settings": (cmd_settings, (0,)), "set-settings": (cmd_set_settings, (1,)),
        "packages": (cmd_packages, (0,)), "set-packages": (cmd_set_packages, (2,)),
        "reset-packages": (cmd_reset_packages, (0,)), "restart": (cmd_restart, (0,)),
        "backup": (cmd_backup, (1,)), "backups": (cmd_backups, (0,)), "restore": (cmd_restore, (1,)),
        "restore-apply": (cmd_restore_apply, (1,)),
        "packages-fingerprint": (lambda: print(packages_fingerprint()), (0,)),
    }
    if not argv or argv[0] not in commands or len(argv) - 1 not in commands[argv[0]][1]:
        print(__doc__, file=sys.stderr)
        return 64
    commands[argv[0]][0](*argv[1:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
