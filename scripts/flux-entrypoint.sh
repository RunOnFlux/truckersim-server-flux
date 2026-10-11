#!/bin/bash
# PID 1, and the supervisor of the SCS convoy server: Euro Truck Simulator 2 or American Truck
# Simulator (SCS_GAME), the same server for both.
#
#   - every start: SteamCMD update (players must run the same game version as the server), a
#     restore if the panel asked for one, a backup of the settings and packages, then
#     server_config.sii and config_ds.cfg from the environment and the panel (fluxscs.py apply),
#     the base-map packages if none were uploaded, the previous run's log moved aside, then the
#     server
#   - SIGTERM/SIGINT from Docker: SIGINT to the server (its own way to stop: there is nothing to
#     save, a convoy server keeps no world); a SteamCMD download in progress is ended too
#   - a new game build on Steam: restart onto it once nobody is driving (an outdated server refuses
#     the new client), at most FLUX_UPDATE_WAIT_MINUTES later. A build that then fails to arrive
#     is not restarted for again for FLUX_UPDATE_RETRY_HOURS. SCS_RESTART_TIME = a daily restart
#   - the server ending on its own: a new generation in place. Steam dropping it ("Steam
#     disconnected", its weekly maintenance) is waited out with a growing backoff and never counts;
#     FLUX_RESTART_MAX_ATTEMPTS other unplanned ends inside FLUX_RESTART_WINDOW end the container
#     with 42

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-30}"
FLUX_UPDATE_CHECK_MINUTES="${FLUX_UPDATE_CHECK_MINUTES:-30}"
FLUX_UPDATE_WAIT_MINUTES="${FLUX_UPDATE_WAIT_MINUTES:-60}"
FLUX_UPDATE_RETRY_HOURS="${FLUX_UPDATE_RETRY_HOURS:-6}"
FLUX_RESTART_WAIT_MINUTES="${FLUX_RESTART_WAIT_MINUTES:-60}"

s="${FLUX_SERVER_DIR}"
d="${FLUX_DATA_DIR}"
scs() { python3 /opt/flux/fluxscs.py "$@"; }

rm -f "${FLUX_RESTART_MARKER}"
mkdir -p "${s}" "${d}" "${FLUX_STATE_DIR}" "${FLUX_GAME_LOG_DIR}"

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

# Whatever the last container left in state.json ("running") is not true of this one.
scs state starting "Starting"

game_pid=""
watch_pid=""
steam_pid=""
terminating=0
generation=0
restart_history=()
steam_backoff=0
log="${d}/${home}/server.log.txt"

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
  # A download in progress: ended, so the stop is not stuck behind it until Docker kills us.
  [ -n "${steam_pid}" ] && kill -TERM "${steam_pid}" 2>/dev/null
  stop_server
}
trap term_handler TERM INT

# SteamCMD in the BACKGROUND, waited for: bash runs a trap only between commands, so a foreground
# download would hold a stop until it finished.
run_steamcmd() {
  steamcmd "$@" >/tmp/steamcmd.log 2>&1 &
  steam_pid=$!
  wait "${steam_pid}"
  local rc=$?
  # A trap that fired while waiting returns early: wait again for the real end.
  while kill -0 "${steam_pid}" 2>/dev/null; do wait "${steam_pid}"; rc=$?; done
  steam_pid=""
  return "${rc}"
}

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
    if run_steamcmd +force_install_dir "${s}" +login anonymous +app_info_update 1 +app_update "${app}" +app_update "${app}" +quit \
      && [ -x "${s}/bin/linux_x64/${binary}" ]; then
      flux_log "server build $(flux_installed_build "${s}/steamapps/appmanifest_${app}.acf")"
      return 0
    fi
    [ "${terminating}" = "1" ] && return 1
    flux_log "WARN steamcmd failed (attempt ${attempt}/5): $(grep -vE '^\s*$' /tmp/steamcmd.log | tail -3 | tr '\n' ' ')"
    sleep 5
  done
  if [ -x "${s}/bin/linux_x64/${binary}" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed"
    return 0
  fi
  flux_log "ERROR could not install the server from Steam"
  return 1
}

# The build Steam has for the app now. SteamCMD's cached app info can be stale: it is dropped first.
public_build() {
  rm -f /root/.local/share/Steam/appcache/appinfo.vdf /root/Steam/appcache/appinfo.vdf "${HOME}/.steam/steam/appcache/appinfo.vdf" 2>/dev/null
  steamcmd +login anonymous +app_info_update 1 +app_info_print "${app}" +quit 2>/dev/null | flux_public_build public
}

player_count() {
  python3 /opt/flux/fluxscs.py status 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); n=d.get("reportedPlayers"); print(n if n is not None and n < len(d.get("players") or []) else len(d.get("players") or []))' 2>/dev/null
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
  # The log is this run's own (moved aside before the start): its first session line is this one.
  while IFS= read -r line; do
    if [[ "${line}" == *"Session search id"* ]]; then
      scs state running
      flux_log "the server is up (generation ${generation}): ${line##*: }"
      break
    fi
  done < <(tail -n +1 -F "${log}" 2>/dev/null)
  last_check="$(date -u +%s)"
  [ -n "${restart_at}" ] && next_restart="$(flux_next_daily "$(date -u +%s)" "${restart_at}")"
  while true; do
    sleep 60
    now="$(date -u +%s)"
    if [ "${FLUX_UPDATE_CHECK_MINUTES}" -gt 0 ] 2>/dev/null && [ $((now - last_check)) -ge $((FLUX_UPDATE_CHECK_MINUTES * 60)) ]; then
      last_check="${now}"
      build="$(flux_installed_build "${s}/steamapps/appmanifest_${app}.acf")"
      public="$(public_build)"
      if [ -n "${public}" ] && [ -n "${build}" ] && [ "${public}" != "${build}" ]; then
        if flux_update_failed_recently "${FLUX_UPDATE_FAILED}" "${public}" "${now}" "${FLUX_UPDATE_RETRY_HOURS}"; then
          continue
        fi
        flux_log "a new server build is on Steam (${build} -> ${public}): restarting onto it once nobody is driving"
        scs state running "A game update (build ${public}) is waiting for an empty server"
        wait_for_empty "${FLUX_UPDATE_WAIT_MINUTES}"
        printf '%s\n' "${public}" >"${FLUX_UPDATE_TARGET}"
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

# After the update: a planned update whose build did not arrive is remembered as failed.
check_update_target() {
  local target installed
  [ -f "${FLUX_UPDATE_TARGET}" ] || return 0
  target="$(cat "${FLUX_UPDATE_TARGET}" 2>/dev/null)"
  rm -f "${FLUX_UPDATE_TARGET}"
  installed="$(flux_installed_build "${s}/steamapps/appmanifest_${app}.acf")"
  if [ -n "${target}" ] && [ "${installed}" != "${target}" ]; then
    printf '%s %s\n' "${target}" "$(date -u +%s)" >"${FLUX_UPDATE_FAILED}"
    flux_log "WARN the update to build ${target} did not arrive (still ${installed:-none}): not restarting for it again for ${FLUX_UPDATE_RETRY_HOURS} h"
  else
    rm -f "${FLUX_UPDATE_FAILED}"
  fi
}

# The previous run's log, moved aside: the new run's log holds only this run, so neither the
# readiness check nor the roster can read the last session's lines.
rotate_log() {
  if [ -s "${log}" ]; then
    mv -f "${log}" "${FLUX_GAME_LOG_DIR}/$(date -u +%Y%m%d-%H%M%S)-server.log"
  fi
  rm -f "${log}" /tmp/flux-scs-logstate.json
  flux_prune "${FLUX_GAME_LOG_DIR}" '*-server.log' "${FLUX_GAME_LOG_KEEP}"
}

start_generation() {
  local line restore
  generation=$((generation + 1))
  export FLUX_GENERATION="${generation}"
  rm -f "${FLUX_RESTART_MARKER}"
  update_server || return 1
  [ "${terminating}" = "1" ] && return 2
  check_update_target
  if [ -f "${FLUX_RESTORE_MARKER}" ]; then
    restore="$(head -1 "${FLUX_RESTORE_MARKER}")"
    rm -f "${FLUX_RESTORE_MARKER}"
    while IFS= read -r line; do flux_log "restore: ${line#\# }"; done < <(scs restore-apply "${restore}" 2>&1)
  fi
  while IFS= read -r line; do flux_log "${line#\# }"; done < <(scs backup start 2>&1)
  while IFS= read -r line; do
    flux_log "config: ${line#\# }"
  done < <(scs apply 2>&1)
  # Steam's client library where the server looks for it.
  mkdir -p "${HOME}/.steam/sdk64"
  cp -f "${s}/linux64/steamclient.so" "${HOME}/.steam/sdk64/" 2>/dev/null
  [ "${terminating}" = "1" ] && return 2
  rotate_log

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
  started_at="$(date -u +%s)"
  watcher &
  watch_pid=$!
  return 0
}

sweep_generation() {
  [ -n "${watch_pid}" ] && kill "${watch_pid}" 2>/dev/null
  watch_pid=""
  pkill -f "tail -n \+1 -F ${log}" 2>/dev/null
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

# Until the packages change, or the panel asks for a restart (or a restore), or a stop.
wait_for_packages_change() {
  local before
  before="$(scs packages-fingerprint 2>/dev/null)"
  while [ "${terminating}" = "0" ]; do
    sleep 5 &
    wait $!
    [ -f "${FLUX_RESTART_MARKER}" ] || [ -f "${FLUX_RESTORE_MARKER}" ] && return 0
    [ "$(scs packages-fingerprint 2>/dev/null)" != "${before}" ] && return 0
  done
}

started_at=0
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
  backoff="${FLUX_RESTART_BACKOFF}"
  if [ -z "${reason}" ] && tail -n 40 "${log}" 2>/dev/null | flux_packages_refused; then
    # Restarting would fail the same way: say why, and wait for other packages (an upload, a
    # reset to the base map, a restore) or a restart asked for from the panel.
    flux_log "ERROR the server could not load its server packages: waiting for new ones (upload, base map or restore)"
    scs state crashed "The server packages could not be loaded: upload a new export_server_packages pair or go back to the base map"
    wait_for_packages_change
    [ "${terminating}" = "1" ] && { scs state stopped; exit 0; }
    reason="requested: new server packages"
  fi
  if [ -z "${reason}" ] && tail -n 40 "${log}" 2>/dev/null | flux_steam_dropped; then
    # A run that held for 10 minutes starts the backoff over.
    [ $(($(date -u +%s) - started_at)) -ge 600 ] && steam_backoff=0
    steam_backoff="$(flux_steam_backoff "${steam_backoff}")"
    backoff="${steam_backoff}"
    reason="steam: Steam dropped the server (exit ${rc}); trying again"
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
  flux_log "${reason}: restarting the server in place in ${backoff}s"
  sleep "${backoff}" &
  wait $!
done
