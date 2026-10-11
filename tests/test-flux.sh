#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh and fluxscs.py. No Docker, no Steam, no game.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

check "ets2" "1948160 eurotrucks2_server Euro Truck Simulator 2" "$(flux_scs_game ets2)"
check "ats" "2239530 amtrucks_server American Truck Simulator" "$(flux_scs_game ATS)"
check "the default is ets2" "1948160" "$(flux_scs_game '' | cut -d' ' -f1)"
check "another game is refused" "1" "$(status flux_scs_game farming)"
check "a port" "27015" "$(flux_valid_port '' 27015)"
check "a daily restart" "06:00" "$(flux_restart_time 6:00)"
check "Steam dropping the server does not count as a crash" "1" "$(status flux_restart_counts 'steam: Steam dropped the server (exit 0)')"
check "a crash counts" "0" "$(status flux_restart_counts 'the server ended on its own (exit 139)')"
check "Steam disconnected is recognised" "0" "$(printf '12:00:00.000 : [MP] Steam disconnected\n' | status flux_steam_dropped)"
check "a packages refusal is recognised" "0" "$(printf '00:00:00.258 : <ERROR> [MP] Error: Failed to load server packages info.\n' | status flux_packages_refused)"
check "an ordinary end is not" "1" "$(printf '12:00:00.000 : [MP] Server was terminated\n' | status flux_steam_dropped)"
check "the Steam backoff starts at 30 s" "30" "$(flux_steam_backoff 0)"
check "and doubles" "120" "$(flux_steam_backoff 60)"
check "up to 10 min" "600" "$(flux_steam_backoff 500)"
printf '25900000 1000\n' >"${tmp}/failed"
check "a failed update target is skipped for a while" "0" "$(status flux_update_failed_recently "${tmp}/failed" 25900000 2000 6)"
check "but not forever" "1" "$(status flux_update_failed_recently "${tmp}/failed" 25900000 $((1000 + 7 * 3600)) 6)"
check "and a newer build is not skipped" "1" "$(status flux_update_failed_recently "${tmp}/failed" 26000000 2000 6)"

data="${tmp}/data"
scs() {
  local vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  env -i PATH="${PATH}" FLUX_DATA_DIR="${data}" FLUX_DEFAULT_PACKAGES="${PWD}/default_packages" FLUX_LOG_STATE="${tmp}/logstate.json" FLUX_RESTART_MARKER="${tmp}/restart" FLUX_RESTORE_MARKER="${tmp}/restore" "${vars[@]}" python3 scripts/fluxscs.py "$@"
}
home="${data}/Euro Truck Simulator 2"
cfg() { sed -n "s/^ $1: //p" "${home}/server_config.sii"; }

scs SCS_LOBBY_NAME='My "Convoy"' SCS_MAX_PLAYERS=16 SCS_MODERATORS="76561197960287930,bad" SCS_TRAFFIC=false SCS_PORT=27100 apply >"${tmp}/notes"
check "the lobby name, without quotes" '"My Convoy"' "$(cfg lobby_name)"
check "players" "16" "$(cfg max_players)"
check "the convoy size follows" 'uset g_max_convoy_size "16"' "$(grep g_max_convoy_size "${home}/config_ds.cfg")"
check "and players are told" "1" "$(grep -c 'g_max_convoy_size 16 in their own' "${tmp}/notes")"
check "a bad moderator list falls back to none" "0" "$(cfg moderator_list)"
check "traffic off" "false" "$(cfg traffic)"
check "the ports" "27100 27101" "$(cfg connection_dedicated_port) $(cfg query_dedicated_port)"
check "the virtual ports" "100 101" "$(cfg connection_virtual_port) $(cfg query_virtual_port)"
check "the base map packages" "0" "$(status test -s "${home}/server_packages.dat")"
scs SCS_MODERATORS="76561197960287930 76561197960287931" apply >/dev/null
check "moderators, counted and listed" "2 76561197960287931" "$(cfg moderator_list) $(cfg 'moderator_list\[1\]')"
scs SCS_MAX_PLAYERS=4 apply >/dev/null
check "fewer than 8 keeps the convoy size at 8" 'uset g_max_convoy_size "8"' "$(grep g_max_convoy_size "${home}/config_ds.cfg")"
check "players above the cap fall back" "8" "$(scs SCS_MAX_PLAYERS=999 apply >/dev/null; cfg max_players)"

check "the panel takes settings" "0" "$(status scs set-settings '{"password": "pw", "welcome": "Hi", "forceSpeedLimiter": true, "allowLoad": true}')"
scs apply >/dev/null
check "password and welcome" '"pw" "Hi"' "$(cfg password) $(cfg welcome_message)"
check "speed limiter" "true" "$(cfg force_speed_limiter)"
check "cargo in convoys" 'uset g_convoy_allow_load "1"' "$(grep g_convoy_allow_load "${home}/config_ds.cfg")"
check "settings hide the password" "(set)" "$(scs settings | python3 -c 'import json,sys;print(json.load(sys.stdin)["values"]["password"])')"
check "a bad token is refused" "2" "$(status scs set-settings '{"token": "nope"}')"
check "a good token" "0" "$(status scs set-settings '{"token": "0123456789ABCDEF0123456789ABCDEF"}')"
check "timezones out of range" "2" "$(status scs set-settings '{"timezones": 5}')"
check "an unknown setting" "2" "$(status scs set-settings '{"pvp": true}')"

# Packages.
printf 'SiiNunit\n{\nserver_packages_info : _nameless.1 {\n version: 1\n dlc_essential_list: 1\n dlc_essential_list[0]: 2050001\n dlc_non_essential_list: 0\n mod_list: 1\n mod_list[0]: "promods"\n map_name: "/map/europe.mbd"\n roads_data_file_name: "/home/x/server_packages.dat"\n time_stamp: 1\n}\n}\n' >"${tmp}/p.sii"
python3 -c 'import struct,sys; open(sys.argv[1],"wb").write(b"\x01\x00"+struct.pack("<I",1)+b"\x00"*40)' "${tmp}/p.dat"
check "packages from the game install" "0" "$(status scs set-packages "${tmp}/p.sii" "${tmp}/p.dat")"
check "what they ask for" "['2050001'] ['promods']" "$(scs packages | python3 -c 'import json,sys;p=json.load(sys.stdin)["packages"];print(p["essentialDlc"], p["mods"])')"
check "the .dat path is the server's home" '/home/server_packages.dat' "$(sed -n 's/.*roads_data_file_name: "\(.*\)"/\1/p' "${home}/server_packages.sii")"
sed 's#/map/europe.mbd#/map/usa.mbd#' "${tmp}/p.sii" >"${tmp}/usa.sii"
check "ATS packages on an ETS2 server are refused" "2" "$(status scs set-packages "${tmp}/usa.sii" "${tmp}/p.dat")"
check "not a packages file" "2" "$(status scs set-packages "${tmp}/p.dat" "${tmp}/p.dat")"
scs reset-packages >/dev/null
scs apply >/dev/null
check "reset brings the base map back" "True" "$(scs packages | python3 -c 'import json,sys;print(json.load(sys.stdin)["packages"]["default"])')"
scs SCS_GAME=ats apply >/dev/null
check "the ATS base map is the default too (it lists optional DLC)" "True" "$(scs SCS_GAME=ats packages | python3 -c 'import json,sys;print(json.load(sys.stdin)["packages"]["default"])')"

# Empty env values are "the panel decides" (the marketplace writes blank declared parameters).
scs set-settings '{"description": "From the panel", "welcome": "Welcome!"}' >/dev/null
scs SCS_DESCRIPTION= SCS_WELCOME="  " apply >/dev/null
check "an empty env description leaves the panel's" '"From the panel"' "$(cfg description)"
check "an empty env welcome leaves the panel's" '"Welcome!"' "$(cfg welcome_message)"
check "and the panel's are not locked" "panel panel" "$(scs SCS_DESCRIPTION= SCS_WELCOME= settings | python3 -c 'import json,sys;d=json.load(sys.stdin)["sources"];print(d["description"], d["welcome"])')"
scs SCS_LOBBY_NAME= apply >/dev/null
check "an empty env name is the default, never an empty name" '"Euro Truck Simulator 2 on Flux"' "$(cfg lobby_name)"

# The moderators MERGE: the variable's and the panel's.
scs set-settings '{"moderators": ["76561197960287932"]}' >/dev/null
scs SCS_MODERATORS="76561197960287930" apply >/dev/null
check "moderators from env and panel, together" "2 76561197960287930 76561197960287932" "$(cfg moderator_list) $(cfg 'moderator_list\[0\]') $(cfg 'moderator_list\[1\]')"
check "the settings say which is which" "['76561197960287930'] ['76561197960287932'] env+panel" "$(scs SCS_MODERATORS=76561197960287930 settings | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["moderators"]["env"], d["moderators"]["panel"], d["sources"]["moderators"])')"

# Text a .sii string cannot hold.
check "C1 controls and line separators are dropped" '"A B C"' "$(scs SCS_LOBBY_NAME="$(printf 'A\xc2\x85B\xe2\x80\xa8C')" apply >/dev/null; cfg lobby_name)"
check "an empty name is refused by the panel" "2" "$(status scs set-settings '{"lobbyName": "   "}')"
check "an invalid env token is said, and not used" "1" "$(scs SCS_TOKEN=nope apply | grep -c 'WARN SCS_TOKEN is not used')"

# pending: what the running server has not picked up.
pend() { scs status | python3 -c 'import json,sys;print(json.load(sys.stdin)["pending"])'; }
scs apply >/dev/null
check "nothing pending right after a start" "False" "$(pend)"
rm -f "${data}/flux/settings.json"
scs apply >/dev/null
printf 'SiiNunit\n{\nserver_packages_info : _nameless.1 {\n version: 1\n dlc_essential_list: 1\n dlc_essential_list[0]: 2050001\n dlc_non_essential_list: 0\n mod_list: 1\n mod_list[0]: "promods"\n map_name: "/map/europe.mbd"\n roads_data_file_name: "/home/x/server_packages.dat"\n time_stamp: 1670000000\n}\n}\n' >"${tmp}/p.sii"
python3 -c 'import struct,sys; open(sys.argv[1],"wb").write(b"\x01\x00"+struct.pack("<I",1670000000)+b"\x00"*40)' "${tmp}/p.dat"
check "packages from the game install" "0" "$(status scs set-packages "${tmp}/p.sii" "${tmp}/p.dat")"
check "an upload is pending even with no settings.json" "True" "$(pend)"
scs apply >/dev/null
check "and applied by a start" "False" "$(pend)"
scs reset-packages >/dev/null
check "a reset is pending too" "True" "$(pend)"
scs apply >/dev/null
check "until the next start" "False" "$(pend)"

# Package pairs: written together, for this game.
python3 -c 'import struct,sys; open(sys.argv[1],"wb").write(b"\x01\x00"+struct.pack("<I",1234)+b"\x00"*40)' "${tmp}/other.dat"
check "a .sii and a .dat from two exports are refused" "2" "$(status scs set-packages "${tmp}/p.sii" "${tmp}/other.dat")"
check "and say why" "1" "$(scs set-packages "${tmp}/p.sii" "${tmp}/other.dat" | grep -c 'two different exports')"
sed 's#/map/europe.mbd#/map/promods_canada.mbd#' "${tmp}/p.sii" >"${tmp}/canada.sii"
check "an ATS mod map on an ETS2 server is refused" "2" "$(status scs set-packages "${tmp}/canada.sii" "${tmp}/p.dat")"
sed 's#essential_list\[0\]: 2050001#essential_list[0]: "dlc_iberia"#' "${tmp}/p.sii" >"${tmp}/quoted.sii"
check "a .sii the game did not write (quoted DLC) is refused: the server would not start" "2" "$(status scs set-packages "${tmp}/quoted.sii" "${tmp}/p.dat")"
check "the base-map pairs pass their own check" "None None" "$(PYTHONPATH=scripts python3 -c '
import fluxscs as t
for g in ("ets2","ats"):
    t.GAME=g; t.OTHER="ats" if g=="ets2" else "ets2"; t.G=t.GAMES[g]
    print(t.check_packages(open(f"default_packages/{g}/server_packages.sii").read(), f"default_packages/{g}/server_packages.dat"), end=" ")
' | sed 's/ $//')"

# Backups and restore.
count() { scs backups | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["backups"]))'; }
before="$(count)"
scs backup start >/dev/null
check "a start right after a change is not backed up again" "${before}" "$(count)"
check "keep the newest, plus the newest older than a day and than a week" "['e', 'g', 'h', 'i']" "$(PYTHONPATH=scripts python3 -c '
import fluxscs as t
now=10*86400
rows=[("a",now-1),("b",now-2),("c",now-3),("d",now-90000),("e",now-100000),("f",now-8*86400),("g",now-9*86400),("h",now-9*86400-1),("i",now-9*86400-2)]
print(t.backups_to_prune(rows, now, keep=3))')"
scs set-settings '{"welcome": "Before"}' >/dev/null
scs set-settings '{"welcome": "After"}' >/dev/null
first="$(scs backups | python3 -c 'import json,sys;print(json.load(sys.stdin)["backups"][0]["name"])')"
check "a restore needs a real backup" "2" "$(status scs restore ../../etc/passwd.tar.gz)"
check "a restore with no server running applies at the start" "start" "$(scs restore "${first}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["appliesOn"])')"
check "and leaves its marker" "${first}" "$(cat "${tmp}/restore")"
scs restore-apply "${first}" >/dev/null
check "restore-apply puts the settings back" "Before" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["welcome"])' "${data}/flux/settings.json")"
check "after a safety backup" "1" "$(scs backups | python3 -c 'import json,sys;print(sum(1 for b in json.load(sys.stdin)["backups"] if b["reason"]=="pre-restore"))')"

# The roster, from the server's log, read incrementally.
py() { PYTHONPATH=scripts python3 -c "import fluxscs as t; $1"; }
check "players come and go" "Bob" "$(py 'p=t.parse_log(["12:00:00.000 : [MP] Alice connected, client_id = 1 (x)", "12:00:01.000 : [MP] Bob connected, client_id = 2 (x)", "12:01:00.000 : [MP] Alice disconnected, client_id = 1 (x)"]); print(",".join(x["name"] for x in p["online"].values()))')"
check "the session search id" "9029/101" "$(py 'print(t.parse_log(["[MP] Session search id: 9029/101"])["search"])')"
check "chat" "Bob: hi" "$(py 'print(t.parse_log(["12:00:00.000 : [MP] [Chat] Bob: hi"])["chat"][0]["text"])')"
check "the server's own count of 0 clears drivers whose disconnect was never logged" "0 0" "$(py 'p=t.parse_log(["[MP] Bob connected, client_id = 2 (x)", "12:03:00.000 : [MP] State: running;  Time: 180;  Players: 0"]); print(len(p["online"]), p["reported"])')"
log="${home}/server.log.txt"
printf '00:00:01.000 : [MP] Session search id: 1/101\n00:00:02.000 : [MP] Alice connected, client_id = 1 (a)\n' >"${log}"
printf '{"state": "running"}' >"${data}/flux/state.json"
roster() { scs status | python3 -c 'import json,sys;print(",".join(p["name"] for p in json.load(sys.stdin)["players"]))'; }
check "the roster from the log" "Alice" "$(roster)"
printf '00:00:03.000 : [MP] Bob connected, client_id = 2 (b)\n00:00:04.000 : [MP] Al' >>"${log}"
check "later lines are read on the next poll; a half-written line waits" "Alice,Bob" "$(roster)"
printf 'ice disconnected, client_id = 1 (a)\n' >>"${log}"
check "and is read once whole" "Bob" "$(roster)"
mv "${log}" "${log}.old" && printf '00:00:01.000 : [MP] Session search id: 2/101\n' >"${log}"
check "a new run's log starts over" "" "$(roster)"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
