#!/bin/bash
# shellcheck disable=SC2016  # wait_for conditions are single-quoted and eval-ed later, on purpose
# Runs INSIDE the image (tests/test-image.sh). tests/ is mounted at /t and scripts/ at /s.
set -uo pipefail
export LC_ALL=C

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
wait_for() {
  local _
  for _ in $(seq 1 $(($2 * 5))); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}

for tool in steamcmd python3 pgrep pkill; do
  check "${tool} is installed" "0" "$(status command -v "${tool}")"
done
for lib in libatomic.so.1 libX11.so.6; do
  check "${lib} is installed" "0" "$(status bash -c "ldconfig -p | grep -q ${lib}")"
done
check "flux-scs is on the PATH" "0" "$(status command -v flux-scs)"
check "the base-map packages, both games" "4" "$(find /opt/flux/default_packages -name 'server_packages.*' | wc -l)"
check "the image's scripts are the repository's" "0" "$(status diff -r --exclude=__pycache__ --exclude=default_packages /s /opt/flux)"
check "the unit tests pass with the image's Python" "0" "$(status bash -c 'cd /tmp && rm -rf repo && mkdir repo && cp -r /s repo/scripts && cp -r /t repo/tests && cp -r /opt/flux/default_packages repo/ && cd repo && ./tests/test-flux.sh')"

# A stand-in server for either game: needs XDG_DATA_HOME, its config and packages, logs a session
# and a driver, and stops on SIGINT. With /tmp/standin-drop present it logs "Steam disconnected"
# and ends at once, as SCS's server does when Steam drops it.
cat >/usr/local/bin/steamcmd <<'STUB'
#!/bin/bash
dir=""
while [ $# -gt 0 ]; do [ "$1" = "+force_install_dir" ] && dir="$2"; shift; done
[ -n "${dir}" ] || exit 0
mkdir -p "${dir}/bin/linux_x64" "${dir}/linux64" "${dir}/steamapps"
for app in 1948160 2239530; do
  printf '"AppState"\n{\n\t"buildid"\t\t"100"\n}\n' >"${dir}/steamapps/appmanifest_${app}.acf"
done
for game in "eurotrucks2_server:Euro Truck Simulator 2" "amtrucks_server:American Truck Simulator"; do
  bin="${game%%:*}" folder="${game#*:}"
  # Python, not bash: the server is started in the background, where a shell ignores SIGINT and
  # cannot trap it; the real server sets its own handler, as Python does.
  cat >"${dir}/bin/linux_x64/${bin}" <<GAME
#!/bin/bash
exec -a ./${bin} python3 - "\$@" <<'PY'
import os, signal, sys, time
home = os.path.join(os.environ["XDG_DATA_HOME"], "${folder}")
log = os.path.join(home, "server.log.txt")
if not (os.path.exists(os.path.join(home, "server_config.sii")) and os.path.exists(os.path.join(home, "server_packages.sii"))):
    open(log, "a").write("no config\n"); sys.exit(1)
if '"dlc' in open(os.path.join(home, "server_packages.sii")).read():
    open(log, "a").write("00:00:00.258 : <ERROR> [MP] Error: Failed to load server packages info.\n00:00:05.258 : quit\n"); sys.exit(0)
if os.path.exists("/tmp/standin-drop"):
    os.remove("/tmp/standin-drop")
    open(log, "a").write("00:00:01.000 : [MP] Steam disconnected\n"); sys.exit(0)
def stop(*_):
    open(log, "a").write("stopped\n"); sys.exit(0)
signal.signal(signal.SIGINT, stop)
open(log, "a").write("00:00:01.000 : [MP] Session search id: 1234/101\n00:00:02.000 : [MP] Alice connected, client_id = 1 (a)\n")
while True:
    time.sleep(0.2)
PY
GAME
  chmod +x "${dir}/bin/linux_x64/${bin}"
done
STUB
chmod +x /usr/local/bin/steamcmd

state() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$1/flux/state.json" "$2" 2>/dev/null; }

# --- Euro Truck Simulator 2 ----------------------------------------------------------------------
data=/mnt/scs/data
ets2_home="${data}/Euro Truck Simulator 2"
export FLUX_RESTART_BACKOFF=1 FLUX_UPDATE_CHECK_MINUTES=0 SCS_LOBBY_NAME="Image Test"
/opt/flux/flux-entrypoint.sh >/tmp/entry.log 2>&1 &
entry=$!
check "the server comes up" "0" "$(status wait_for 'grep -q "\"running\"" ${data}/flux/state.json 2>/dev/null' 30)"
check "status reads the log" "Alice 1234/101" "$(flux-scs status | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["players"][0]["name"], d["searchId"])')"
check "the generation is in the state" "1" "$(state "${data}" generation)"
flux-scs set-settings '{"welcome": "Hello"}' >/dev/null
check "a saved setting is pending" "True" "$(flux-scs status | python3 -c 'import json,sys;print(json.load(sys.stdin)["pending"])')"
flux-scs restart >/dev/null
check "a panel restart is a new generation" "0" "$(status wait_for '[ "$(state ${data} generation)" = 2 ] && grep -q "\"running\"" ${data}/flux/state.json' 30)"
check "and applies the settings" "1" "$(grep -c 'welcome_message: "Hello"' "${ets2_home}/server_config.sii")"
check "the new run's log holds only the new run" "1" "$(grep -c 'Session search id' "${ets2_home}/server.log.txt")"
check "the previous run's log is kept aside" "0" "$(status wait_for 'ls ${data}/flux/logs/*-server.log' 5)"
check "not counted as a crash" "0" "$(grep -c 'restarts within' /tmp/entry.log)"
check "nothing pending after it" "False" "$(flux-scs status | python3 -c 'import json,sys;print(json.load(sys.stdin)["pending"])')"

# A restore, through the supervisor: the backup made before "Hello" was saved.
before="$(flux-scs backups | python3 -c 'import json,sys;print([b["name"] for b in json.load(sys.stdin)["backups"] if b["reason"]=="before a settings change"][0])')"
check "a restore restarts the server" "now" "$(flux-scs restore "${before}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["appliesOn"])')"
check "onto the backup's settings" "0" "$(status wait_for '[ "$(state ${data} generation)" = 3 ] && grep -q "\"running\"" ${data}/flux/state.json' 30)"
check "the welcome message is the one before" "0" "$(grep -c 'welcome_message: "Hello"' "${ets2_home}/server_config.sii")"
check "after a safety backup" "0" "$(status bash -c 'flux-scs backups | grep -q pre-restore')"

# Steam dropping the server: waited out, never counted.
touch /tmp/standin-drop
flux-scs restart >/dev/null
check "Steam dropping the server is recognised" "0" "$(status wait_for 'grep -q "steam: Steam dropped the server" /tmp/entry.log' 20)"
check "and not counted as a crash" "0" "$(grep -c 'restarts within' /tmp/entry.log)"

kill -TERM "${entry}"
check "a stop ends the supervisor" "0" "$(status wait_for '! kill -0 ${entry} 2>/dev/null' 40)"
check "and says stopped" "stopped" "$(state "${data}" state)"

# Packages the server cannot load (a hand-written .sii left on the volume): no crash loop, a
# message, and back as soon as the packages change.
sed -i 's#dlc_essential_list: 0#dlc_essential_list: 1\n dlc_essential_list[0]: "dlc_iberia"#' "${ets2_home}/server_packages.sii"
/opt/flux/flux-entrypoint.sh >/tmp/entry.log 2>&1 &
entry=$!
check "refused packages: the state says so" "0" "$(status wait_for '[ "$(state ${data} state)" = crashed ] && grep -q "server packages could not be loaded" ${data}/flux/state.json' 30)"
sleep 3
check "and it does not restart over and over" "1" "$(grep -c 'starting the server (generation' /tmp/entry.log)"
check "a panel restart while it waits is taken, not \"not running\"" "now" "$(flux-scs restart | python3 -c 'import json,sys;print(json.load(sys.stdin)["appliesOn"])')"
check "and the supervisor tries again" "0" "$(status wait_for '[ "$(grep -c "starting the server (generation" /tmp/entry.log)" -ge 2 ]' 30)"
check "then waits again on the same packages" "0" "$(status wait_for '[ "$(state ${data} state)" = crashed ]' 40)"
flux-scs reset-packages >/dev/null
check "back on the base map once the packages change" "0" "$(status wait_for 'grep -q "\"running\"" ${data}/flux/state.json' 30)"
kill -TERM "${entry}"
wait_for '! kill -0 ${entry} 2>/dev/null' 20

# --- American Truck Simulator --------------------------------------------------------------------
ats_data=/tmp/ats-data
SCS_GAME=ats FLUX_DATA_DIR="${ats_data}" FLUX_STATE_DIR="${ats_data}/flux" FLUX_SERVER_DIR=/tmp/ats-server FLUX_LOG="${ats_data}/flux/flux.log" \
  FLUX_GAME_LOG_DIR="${ats_data}/flux/logs" FLUX_UPDATE_TARGET="${ats_data}/flux/update-target" FLUX_UPDATE_FAILED="${ats_data}/flux/update-failed" \
  /opt/flux/flux-entrypoint.sh >/tmp/entry-ats.log 2>&1 &
entry=$!
check "ATS: the server comes up" "0" "$(status wait_for 'grep -q "\"running\"" ${ats_data}/flux/state.json 2>/dev/null' 30)"
check "ATS: in its own folder" "1" "$(grep -c '^ lobby_name: "Image Test"' "${ats_data}/American Truck Simulator/server_config.sii")"
check "ATS: on the USA base map, reported as the default" "/map/usa.mbd True" "$(SCS_GAME=ats FLUX_DATA_DIR=${ats_data} FLUX_STATE_DIR=${ats_data}/flux flux-scs status | python3 -c 'import json,sys;p=json.load(sys.stdin)["packages"];print(p["map"], p["default"])')"
check "ATS: the status says the game" "ats" "$(SCS_GAME=ats FLUX_DATA_DIR=${ats_data} FLUX_STATE_DIR=${ats_data}/flux flux-scs status | python3 -c 'import json,sys;print(json.load(sys.stdin)["game"])')"
kill -TERM "${entry}"
check "ATS: a stop ends the supervisor" "0" "$(status wait_for '! kill -0 ${entry} 2>/dev/null' 20)"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ] || { echo '--- entrypoint log'; cat /tmp/entry.log; echo '--- ats'; cat /tmp/entry-ats.log 2>/dev/null; exit 1; }
