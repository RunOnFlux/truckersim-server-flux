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

# A stand-in server: needs XDG_DATA_HOME, its config and packages, logs a session and a player,
# and stops on SIGINT.
cat >/usr/local/bin/steamcmd <<'STUB'
#!/bin/bash
dir=""
while [ $# -gt 0 ]; do [ "$1" = "+force_install_dir" ] && dir="$2"; shift; done
[ -n "${dir}" ] || exit 0
mkdir -p "${dir}/bin/linux_x64" "${dir}/linux64" "${dir}/steamapps"
printf '"AppState"\n{\n\t"buildid"\t\t"100"\n}\n' >"${dir}/steamapps/appmanifest_1948160.acf"
# Python, not bash: the server is started in the background, where a shell ignores SIGINT and
# cannot trap it; the real server sets its own handler, as Python does.
cat >"${dir}/bin/linux_x64/eurotrucks2_server" <<'GAME'
#!/bin/bash
exec -a ./eurotrucks2_server python3 - "$@" <<'PY'
import os, signal, sys, time
home = os.path.join(os.environ["XDG_DATA_HOME"], "Euro Truck Simulator 2")
log = os.path.join(home, "server.log.txt")
if not (os.path.exists(os.path.join(home, "server_config.sii")) and os.path.exists(os.path.join(home, "server_packages.sii"))):
    open(log, "w").write("no config\n"); sys.exit(1)
def stop(*_):
    open(log, "a").write("stopped\n"); sys.exit(0)
signal.signal(signal.SIGINT, stop)
open(log, "w").write("00:00:01.000 : [MP] Session search id: 1234/101\n00:00:02.000 : [MP] Alice connected, client_id = 1 (a)\n")
while True:
    time.sleep(0.2)
PY
GAME
chmod +x "${dir}/bin/linux_x64/eurotrucks2_server"
STUB
chmod +x /usr/local/bin/steamcmd

data=/mnt/scs/data
export FLUX_RESTART_BACKOFF=1 FLUX_UPDATE_CHECK_MINUTES=0 SCS_LOBBY_NAME="Image Test"
/opt/flux/flux-entrypoint.sh >/tmp/entry.log 2>&1 &
entry=$!
check "the server comes up" "0" "$(status wait_for 'grep -q "\"running\"" ${data}/flux/state.json 2>/dev/null' 30)"
check "status reads the log" "Alice 1234/101" "$(flux-scs status | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["players"][0]["name"], d["searchId"])')"
flux-scs set-settings '{"welcome": "Hello"}' >/dev/null
flux-scs restart >/dev/null
check "a panel restart applies the settings" "0" "$(status wait_for 'grep -q "welcome_message: \"Hello\"" "${data}/Euro Truck Simulator 2/server_config.sii" && grep -q "\"running\"" ${data}/flux/state.json' 30)"
check "not counted as a crash" "0" "$(grep -c 'restarts within' /tmp/entry.log)"
kill -TERM "${entry}"
check "a stop ends the supervisor" "0" "$(status wait_for '! kill -0 ${entry} 2>/dev/null' 20)"
check "with SIGINT to the server" "1" "$(grep -c stopped "${data}/Euro Truck Simulator 2/server.log.txt")"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ] || { echo '--- entrypoint log'; cat /tmp/entry.log; exit 1; }
