#!/bin/bash
# PID 1, and the supervisor of the SCS convoy server: Euro Truck Simulator 2 or American Truck
# Simulator (SCS_GAME), the same server for both.
#
#   - every start: SteamCMD update (players must run the same game version as the server), then
#     server_config.sii and config_ds.cfg from the environment and the panel (fluxscs.py apply),
#     the base-map packages if none were uploaded, then the server
#   - SIGTERM/SIGINT from Docker: SIGINT to the server (its own way to stop: there is nothing to
#     save, a convoy server keeps no world)
#   - a new game build on Steam: restart onto it once nobody is driving (an outdated server refuses
#     the new client), at most FLUX_UPDATE_WAIT_MINUTES later; SCS_RESTART_TIME = a daily restart
#   - the server ending on its own ("Steam disconnected" ends it): a new generation in place;
#     FLUX_RESTART_MAX_ATTEMPTS unplanned ones inside FLUX_RESTART_WINDOW end the container with 42

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-30}"
FLUX_UPDATE_CHECK_MINUTES="${FLUX_UPDATE_CHECK_MINUTES:-30}"
FLUX_UPDATE_WAIT_MINUTES="${FLUX_UPDATE_WAIT_MINUTES:-60}"
FLUX_RESTART_WAIT_MINUTES="${FLUX_RESTART_WAIT_MINUTES:-60}"

s="${FLUX_SERVER_DIR}"
d="${FLUX_DATA_DIR}"
scs() { python3 /opt/flux/fluxscs.py "$@"; }

rm -f "${FLUX_RESTART_MARKER}"
mkdir -p "${s}" "${d}" "${FLUX_STATE_DIR}"

if ! game="$(flux_scs_game "${SCS_GAME:-ets2}")"; then
  flux_log "ERROR SCS_GAME='${SCS_GAME}' is neither ets2 nor ats; refusing to start"
  exit 42
fi
read -r app binary home <<<"${game}"
export SCS_GAME="${SCS_GAME:-ets2}"
if ! port="$(flux_valid_port "${SCS_PORT:-}" 27015)" || ! query_port="$(flux_valid_port "${SCS_QUERY_PORT:-}" $((port + 1)))"; then
  flux_log "ERROR SCS_PORT / SCS_QUERY_PORT are not ports; refusing to start"
  exit 42
fi
export SCS_PORT="${port}" SCS_QUERY_PORT="${query_port}"
if ! restart_at="$(flux_restart_time "${SCS_RESTART_TIME:-}")"; then
  flux_log "WARN SCS_RESTART_TIME='${SCS_RESTART_TIME}' is not HH:MM; no daily restart"
  restart_at=""
fi
flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}): ${home} (app ${app}), ports ${port} and ${query_port}, daily restart ${restart_at:-off}"

game_pid=""
watch_pid=""
terminating=0
generation=0
restart_history=()

stop_server() {
  local pid
  pid="$(flux_game_pid "${binary}")"
  pid="${pid:-${game_pid}}"
  [ -n "${pid}" ] && kill -INT "${pid}" 2>/dev/null
}

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested: stopping the server, no restart will follow"
  stop_server
}
trap term_handler TERM INT

update_server() {
  local attempt
  if flux_truthy "${SKIP_UPDATE:-}" && [ -x "${s}/bin/linux_x64/${binary}" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  scs state updating "Downloading the server from Steam"
  flux_log "updating the server from Steam (app ${app})"
  for attempt in 1 2 3 4 5; do
    # app_update twice after app_info_update: the American Truck Simulator server answered
    # "Missing configuration" to a single one (measured), the second succeeds.
    if steamcmd +force_install_dir "${s}" +login anonymous +app_info_update 1 +app_update "${app}" +app_update "${app}" +quit >/tmp/steamcmd.log 2>&1 \
      && [ -x "${s}/bin/linux_x64/${binary}" ]; then
      flux_log "server build $(flux_installed_build "${s}/steamapps/appmanifest_${app}.acf")"
      return 0
    fi
    [ "${terminating}" = "1" ] && return 1
    flux_log "WARN steamcmd failed (attempt ${attempt}/5): $(grep -E 'ERROR|Error' /tmp/steamcmd.log | tail -1)"
    sleep 5
  done
  if [ -x "${s}/bin/linux_x64/${binary}" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed"
    return 0
  fi
  flux_log "ERROR could not install the server from Steam"
  return 1
}

player_count() {
  python3 /opt/flux/fluxscs.py status 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("players") or []))' 2>/dev/null
}

wait_for_empty() {
  local until=$(($(date -u +%s) + $1 * 60))
  while [ "$(date -u +%s)" -lt "${until}" ]; do
    [ "$(player_count)" = "0" ] && return 0
    sleep 60
  done
  return 0
}

request_restart() {
  printf '%s\n' "$1" >"${FLUX_RESTART_MARKER}"
  flux_log "$1: restarting the server"
  stop_server
}

# shellcheck disable=SC2329  # run in the background below
watcher() {
  local line last_check now next_restart="" build public
  while IFS= read -r line; do
    if [[ "${line}" == *"Session search id"* ]]; then
      scs state running
      flux_log "the server is up (generation ${generation}): ${line##*: }"
      break
    fi
  done < <(tail -n +1 -F "${d}/${home}/server.log.txt" 2>/dev/null)
  last_check="$(date -u +%s)"
  [ -n "${restart_at}" ] && next_restart="$(flux_next_daily "$(date -u +%s)" "${restart_at}")"
  while true; do
    sleep 60
    now="$(date -u +%s)"
    if [ "${FLUX_UPDATE_CHECK_MINUTES}" -gt 0 ] 2>/dev/null && [ $((now - last_check)) -ge $((FLUX_UPDATE_CHECK_MINUTES * 60)) ]; then
      last_check="${now}"
      build="$(flux_installed_build "${s}/steamapps/appmanifest_${app}.acf")"
      public="$(steamcmd +login anonymous +app_info_update 1 +app_info_print "${app}" +quit 2>/dev/null | flux_public_build public)"
      if [ -n "${public}" ] && [ -n "${build}" ] && [ "${public}" != "${build}" ]; then
        flux_log "a new server build is on Steam (${build} -> ${public}): restarting onto it once nobody is driving"
        scs state running "A game update (build ${public}) is waiting for an empty server"
        wait_for_empty "${FLUX_UPDATE_WAIT_MINUTES}"
        request_restart "planned: game update ${build} -> ${public}"
        exit 0
      fi
    fi
    if [ -n "${next_restart}" ] && [ "${now}" -ge "${next_restart}" ]; then
      wait_for_empty "${FLUX_RESTART_WAIT_MINUTES}"
      request_restart "planned: the daily restart (${restart_at})"
      exit 0
    fi
  done
}

start_generation() {
  local line
  generation=$((generation + 1))
  rm -f "${FLUX_RESTART_MARKER}"
  update_server || return 1
  [ "${terminating}" = "1" ] && return 2
  while IFS= read -r line; do
    flux_log "config: ${line#\# }"
  done < <(scs apply 2>&1)
  # Steam's client library where the server looks for it.
  mkdir -p "${HOME}/.steam/sdk64"
  cp -f "${s}/linux64/steamclient.so" "${HOME}/.steam/sdk64/" 2>/dev/null
  [ "${terminating}" = "1" ] && return 2

  scs state starting "Loading the map"
  flux_log "starting the server (generation ${generation})"
  (
    cd "${s}/bin/linux_x64" || exit 1
    # XDG_DATA_HOME: the server's home ("<game>/" with server_config.sii, the packages, the log)
    # is on the data volume. -nosingle: SCS's flag for running more than one server per machine.
    export XDG_DATA_HOME="${d}" LD_LIBRARY_PATH="${s}/linux64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    exec "./${binary}" -nosingle
  ) &
  game_pid=$!
  watcher &
  watch_pid=$!
  return 0
}

sweep_generation() {
  [ -n "${watch_pid}" ] && kill "${watch_pid}" 2>/dev/null
  watch_pid=""
  pkill -f "tail -n \+1 -F ${d}/${home}/server.log.txt" 2>/dev/null
  pkill -KILL -f "^\./${binary}" 2>/dev/null
  game_pid=""
}

wait_for_generation() {
  local asked_at=0 now
  while kill -0 "${game_pid}" 2>/dev/null; do
    sleep 1 &
    wait $!
    if [ "${terminating}" = "1" ] || [ -f "${FLUX_RESTART_MARKER}" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      if [ $((now - asked_at)) -ge "${FLUX_STOP_GRACE}" ]; then
        kill -KILL "${game_pid}" 2>/dev/null
        break
      fi
    else
      asked_at=0
    fi
  done
  wait "${game_pid}" 2>/dev/null
}

while true; do
  if [ "${terminating}" = "1" ]; then
    scs state stopped
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "2" ]; then
    scs state stopped
    exit 0
  elif [ "${started}" != "0" ]; then
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    scs state crashed "The server could not be installed or started"
    exit 42
  fi
  wait_for_generation
  rc=$?
  reason=""
  [ -f "${FLUX_RESTART_MARKER}" ] && reason="$(cat "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  sweep_generation
  rm -f "${FLUX_RESTART_MARKER}"
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (server exited ${rc})"
    scs state stopped
    exit 0
  fi
  [ -z "${reason}" ] && reason="the server ended on its own (exit ${rc})"
  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s; ending the container (42)"
      scs state crashed "The server keeps stopping: ${reason}"
      exit 42
    fi
  fi
  scs state restarting "${reason}"
  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
