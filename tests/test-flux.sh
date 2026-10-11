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

data="${tmp}/data"
scs() {
  local vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  env -i PATH="${PATH}" FLUX_DATA_DIR="${data}" FLUX_DEFAULT_PACKAGES="${PWD}/default_packages" "${vars[@]}" python3 scripts/fluxscs.py "$@"
}
home="${data}/Euro Truck Simulator 2"
cfg() { sed -n "s/^ $1: //p" "${home}/server_config.sii"; }

scs SCS_LOBBY_NAME='My "Convoy"' SCS_MAX_PLAYERS=16 SCS_MODERATORS="76561197960287930,bad" SCS_TRAFFIC=false SCS_PORT=27100 apply >"${tmp}/notes"
check "the lobby name, without quotes" '"My  Convoy"' "$(cfg lobby_name)"
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
printf 'SiiNunit\n{\nserver_packages_info : _nameless.1 {\n version: 1\n dlc_essential_list: 1\n dlc_essential_list[0]: "dlc_iberia"\n dlc_non_essential_list: 0\n mod_list: 1\n mod_list[0]: "promods"\n map_name: "/map/europe.mbd"\n roads_data_file_name: "/home/x/server_packages.dat"\n time_stamp: 1\n}\n}\n' >"${tmp}/p.sii"
head -c 100 /dev/urandom >"${tmp}/p.dat"
check "packages from the game install" "0" "$(status scs set-packages "${tmp}/p.sii" "${tmp}/p.dat")"
check "what they ask for" "['dlc_iberia'] ['promods']" "$(scs packages | python3 -c 'import json,sys;p=json.load(sys.stdin)["packages"];print(p["essentialDlc"], p["mods"])')"
check "the .dat path is the server's home" '/home/server_packages.dat' "$(sed -n 's/.*roads_data_file_name: "\(.*\)"/\1/p' "${home}/server_packages.sii")"
sed 's#/map/europe.mbd#/map/usa.mbd#' "${tmp}/p.sii" >"${tmp}/usa.sii"
check "ATS packages on an ETS2 server are refused" "2" "$(status scs set-packages "${tmp}/usa.sii" "${tmp}/p.dat")"
check "not a packages file" "2" "$(status scs set-packages "${tmp}/p.dat" "${tmp}/p.dat")"
scs reset-packages >/dev/null
scs apply >/dev/null
check "reset brings the base map back" "True" "$(scs packages | python3 -c 'import json,sys;print(json.load(sys.stdin)["packages"]["default"])')"
scs SCS_GAME=ats apply >/dev/null
check "the ATS base map is the default too (it lists optional DLC)" "True" "$(scs SCS_GAME=ats packages | python3 -c 'import json,sys;print(json.load(sys.stdin)["packages"]["default"])')"

# The roster, from the server's log.
py() { PYTHONPATH=scripts python3 -c "import fluxscs as t; $1"; }
check "players come and go" "Bob" "$(py 'p,_,_,_=t.parse_log(["12:00:00.000 : [MP] Alice connected, client_id = 1 (x)", "12:00:01.000 : [MP] Bob connected, client_id = 2 (x)", "12:01:00.000 : [MP] Alice disconnected, client_id = 1 (x)"]); print(",".join(x["name"] for x in p))')"
check "the session search id" "9029/101" "$(py 'print(t.parse_log(["[MP] Session search id: 9029/101"])[1])')"
check "chat" "Bob: hi" "$(py 'print(t.parse_log(["12:00:00.000 : [MP] [Chat] Bob: hi"])[3][0]["text"])')"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
