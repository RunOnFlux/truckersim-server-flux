#!/usr/bin/env python3
"""Every decision about the SCS convoy server's files (Euro Truck Simulator 2 / American Truck
Simulator), and the hub's commands.

    fluxscs.py apply                   server_config.sii and config_ds.cfg from the environment and the
                                       panel; the map packages if none were uploaded (before every start)
    fluxscs.py state <state> [msg]     record what the supervisor is doing (flux/state.json)

    flux-scs status                    state, players (from the server log), session search id, version
    flux-scs settings                  the panel's settings, the env that overrides them, the limits
    flux-scs set-settings '<json>'     save settings (applied on the next start)
    flux-scs packages                  which map / DLC / mods the server's packages ask for
    flux-scs set-packages <sii> <dat>  install a server_packages pair exported from the game
    flux-scs reset-packages            back to the base map (no DLC, no mods)
    flux-scs restart                   stop and start again

The game is SCS_GAME: ets2 (Euro Truck Simulator 2, app 1948160) or ats (American Truck
Simulator, app 2239530). The server has no console and no RCON: everything goes through its
files, which it reads at start, and its log.

Precedence: an environment variable that is SET is applied on every start; one that is not set
leaves the panel's value, then the default.
"""

import json
import os
import re
import shutil
import subprocess
import sys
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
SERVER_DIR = os.environ.get("FLUX_SERVER_DIR", "/mnt/scs/server")
DATA_DIR = os.environ.get("FLUX_DATA_DIR", "/mnt/scs/data")
STATE_DIR = os.environ.get("FLUX_STATE_DIR", os.path.join(DATA_DIR, "flux"))
STATE_FILE = os.path.join(STATE_DIR, "state.json")
SETTINGS_FILE = os.path.join(STATE_DIR, "settings.json")
# The server's home: XDG_DATA_HOME is the data volume, the game's folder inside it.
HOME = os.path.join(DATA_DIR, G["home"])
CONFIG = os.path.join(HOME, "server_config.sii")
CONFIG_DS = os.path.join(HOME, "config_ds.cfg")
PACKAGES_SII = os.path.join(HOME, "server_packages.sii")
PACKAGES_DAT = os.path.join(HOME, "server_packages.dat")
SERVER_LOG = os.path.join(HOME, "server.log.txt")
DEFAULT_PACKAGES = os.environ.get("FLUX_DEFAULT_PACKAGES", "/opt/flux/default_packages")

# The official cap. More is possible (config_ds.cfg g_max_convoy_size) but every PLAYER must set
# the same value in their own game, or they do not see the session.
OFFICIAL_MAX = 8
MAX_PLAYERS_CAP = 128

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
    text = re.sub(r'[\x00-\x1f\x7f"\\]', " ", str(value)).strip()
    if name == "token" and text and not re.fullmatch(r"[0-9A-Fa-f]{32}", text):
        raise ValueError("a Steam game server login token is 32 letters and digits")
    return text[:limit]


def effective(settings=None):
    settings = load_settings() if settings is None else settings
    values, sources = {}, {}
    env_for = {v: k for k, v in ENV.items()}
    for name, (_, _, default, _) in SETTINGS.items():
        env = env_for.get(name)
        if env and env in os.environ:
            try:
                values[name], sources[name] = coerce(name, os.environ[env]), "env"
                continue
            except ValueError:
                pass
        if name in settings:
            values[name], sources[name] = settings[name], "panel"
        else:
            values[name], sources[name] = default, "default"
    return values, sources


def sii_value(kind, value):
    if kind == "bool":
        return "true" if value else "false"
    if kind == "int":
        return str(int(value))
    return '"' + str(value) + '"'


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


def cmd_apply():
    notes = []
    values, sources = effective()
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
    write_json(STATE_FILE, data, indent=None)


JOIN_RE = re.compile(r"\[MP\] (.+?) connected, client_id = (\d+)")
LEAVE_RE = re.compile(r"\[MP\] (.+?) disconnected, client_id = (\d+)")
SEARCH_RE = re.compile(r"Session search id: (\S+)")
VERSION_RE = re.compile(r"(\d+\.\d+\.\d+\.\d+s?)\b")
CHAT_RE = re.compile(r"^(\d{2}:\d{2}:\d{2}\.\d{3}) : \[MP\] \[Chat\] (.*)$")


def read_log():
    try:
        with open(SERVER_LOG, encoding="utf-8", errors="replace") as f:
            return f.read().splitlines()
    except OSError:
        return []


def parse_log(lines):
    online, search, version, chat = {}, None, None, []
    for line in lines:
        m = JOIN_RE.search(line)
        if m:
            online[m.group(2)] = {"name": m.group(1).strip(), "id": m.group(2)}
            continue
        m = LEAVE_RE.search(line)
        if m:
            online.pop(m.group(2), None)
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
    return list(online.values()), search, version, chat[-50:]


def cmd_status():
    state = read_json(STATE_FILE, {}) or {}
    values, _ = effective()
    players, search, version, chat = parse_log(read_log()) if state.get("state") == "running" else ([], None, None, [])
    out({"state": state.get("state", "stopped"), "message": state.get("message"), "since": state.get("since"),
         "image": state.get("image"), "game": GAME, "gameName": G["name"], "version": version,
         "players": players, "max_players": values["maxPlayers"], "name": values["lobbyName"],
         "searchId": search, "chat": chat, "packages": packages_info(),
         "pending": pending(state)})


def pending(state):
    try:
        return os.path.getmtime(SETTINGS_FILE) > (state.get("applied") or 0) or \
            os.path.getmtime(PACKAGES_SII) > (state.get("applied") or 0)
    except OSError:
        return False


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


def packages_info():
    try:
        text = open(PACKAGES_SII, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    info = parse_packages(text)
    info["default"] = info.get("mods") == [] and info.get("essentialDlc") == [] and info.get("optionalDlc") == []
    return info


def cmd_packages():
    out({"packages": packages_info(), "game": GAME, "expectedMap": G["map"]})


def cmd_set_packages(sii, dat):
    try:
        text = open(sii, encoding="utf-8", errors="replace").read()
    except OSError:
        fail("cannot read the .sii file", 2)
    if "server_packages_info" not in text:
        fail("this is not a server_packages.sii (export it in the game: console, export_server_packages)", 2)
    info = parse_packages(text)
    if info["map"] and info["map"] != G["map"] and not info["map"].startswith("/map/"):
        fail(f"unexpected map {info['map']}", 2)
    if info["map"] and G["map"] not in info["map"] and GAME == "ets2" and "usa" in info["map"]:
        fail("these packages are for American Truck Simulator, this server is Euro Truck Simulator 2", 2)
    if info["map"] and GAME == "ats" and "europe" in info["map"]:
        fail("these packages are for Euro Truck Simulator 2, this server is American Truck Simulator", 2)
    if not os.path.isfile(dat) or os.path.getsize(dat) < 16:
        fail("the .dat file is missing or empty (export_server_packages writes both)", 2)
    # The .sii names the .dat it goes with; the server looks for it in its home.
    text = re.sub(r'roads_data_file_name:\s*"[^"]*"', 'roads_data_file_name: "/home/server_packages.dat"', text)
    os.makedirs(HOME, exist_ok=True)
    shutil.copy2(dat, PACKAGES_DAT + ".flux-new")
    write_text(PACKAGES_SII, text)
    os.replace(PACKAGES_DAT + ".flux-new", PACKAGES_DAT)
    out({"ok": True, "packages": packages_info(), "appliesOn": "restart"})


def cmd_reset_packages():
    for p in (PACKAGES_SII, PACKAGES_DAT):
        try:
            os.remove(p)
        except OSError:
            pass
    out({"ok": True, "appliesOn": "restart"})


# ------------------------------------------------------------------------------------------------
# Settings
# ------------------------------------------------------------------------------------------------

def cmd_settings():
    values, sources = effective()
    shown = {k: (("(set)" if v else "") if k in SECRETS else v) for k, v in values.items()}
    out({"values": shown, "sources": sources, "game": GAME, "officialMax": OFFICIAL_MAX,
         "maxPlayersCap": MAX_PLAYERS_CAP, "tokenApp": G["game_app"],
         "env": {k: v for k, v in ENV.items() if k in os.environ}})


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
    write_json(SETTINGS_FILE, settings)
    out({"ok": True, "settings": {k: v for k, v in settings.items() if k not in SECRETS}, "appliesOn": "restart"})


def cmd_restart():
    pids = subprocess.run(["pgrep", "-f", rf"^\./{G['binary']}"], capture_output=True, text=True).stdout.split()
    if not pids:
        fail("the server is not running", 3)
    with open(os.environ.get("FLUX_RESTART_MARKER", "/tmp/flux-restart-requested"), "w") as f:
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
    }
    if not argv or argv[0] not in commands or len(argv) - 1 not in commands[argv[0]][1]:
        print(__doc__, file=sys.stderr)
        return 64
    commands[argv[0]][0](*argv[1:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
