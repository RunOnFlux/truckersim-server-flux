#!/bin/bash
# Shared helpers for the SCS convoy server image (Euro Truck Simulator 2 / American Truck Simulator).
#
# SOURCING THIS FILE MUST STAY SIDE-EFFECT FREE: tests/test-flux.sh sources it directly and
# calls the functions with made-up inputs. Everything that decides something takes its inputs
# as arguments, so the decision can be tested without a server, Steam or Docker.

# ---------------------------------------------------------------------------------------------
# Paths. Two volumes: the install (SteamCMD's, disposable, local to the node) and the data (the
# server's home, XDG_DATA_HOME, and ours). The data is the only thing that has to survive.
# ---------------------------------------------------------------------------------------------
FLUX_SERVER_DIR="${FLUX_SERVER_DIR:-/mnt/scs/server}"
FLUX_DATA_DIR="${FLUX_DATA_DIR:-/mnt/scs/data}"
FLUX_STATE_DIR="${FLUX_STATE_DIR:-${FLUX_DATA_DIR}/flux}"
FLUX_LOG="${FLUX_LOG:-${FLUX_STATE_DIR}/flux.log}"
FLUX_LOG_MAX_LINES="${FLUX_LOG_MAX_LINES:-2000}"
FLUX_BACKUP_DIR="${FLUX_BACKUP_DIR:-${FLUX_STATE_DIR}/backups}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-/tmp/flux-restart-requested}"
FLUX_RESTORE_MARKER="${FLUX_RESTORE_MARKER:-/tmp/flux-restore-requested}"
# The game update a planned restart was for, and the one that failed to arrive (the watcher skips a
# failed target for FLUX_UPDATE_RETRY_HOURS instead of restarting for it over and over).
FLUX_UPDATE_TARGET="${FLUX_UPDATE_TARGET:-${FLUX_STATE_DIR}/update-target}"
FLUX_UPDATE_FAILED="${FLUX_UPDATE_FAILED:-${FLUX_STATE_DIR}/update-failed}"
FLUX_GAME_LOG_DIR="${FLUX_GAME_LOG_DIR:-${FLUX_STATE_DIR}/logs}"
FLUX_GAME_LOG_KEEP="${FLUX_GAME_LOG_KEEP:-5}"

# $1 = SCS_GAME. Prints "<steam app> <binary> <home folder>", or returns 1 for an unknown game.
flux_scs_game() {
  case "${1,,}" in
    "" | ets2) printf '1948160 eurotrucks2_server Euro Truck Simulator 2' ;;
    ats) printf '2239530 amtrucks_server American Truck Simulator' ;;
    *) return 1 ;;
  esac
}

flux_log() {
  local line
  line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [flux] $*"
  printf '%s\n' "${line}"
  if [ -n "${FLUX_LOG}" ] && mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null; then
    printf '%s\n' "${line}" >>"${FLUX_LOG}" 2>/dev/null || return 0
    flux_trim_file "${FLUX_LOG}" "${FLUX_LOG_MAX_LINES}"
  fi
}

# Keeps the last $2 lines of $1. Checked cheaply first: most calls change nothing.
flux_trim_file() {
  local file="$1" max="$2" lines
  lines="$(wc -l <"${file}" 2>/dev/null || echo 0)"
  if [ "${lines}" -gt $((max + max / 10)) ]; then
    tail -n "${max}" "${file}" >"${file}.tmp" 2>/dev/null && mv "${file}.tmp" "${file}"
  fi
}

flux_truthy() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# $1 = a port as given, $2 = the default. Prints it, or returns 1 for a value that is not one.
flux_valid_port() {
  local value="${1:-$2}"
  [[ "${value}" =~ ^[0-9]{1,5}$ ]] || return 1
  value=$((10#${value}))
  [ "${value}" -ge 1024 ] && [ "${value}" -le 65535 ] || return 1
  printf '%s' "${value}"
}

# ---------------------------------------------------------------------------------------------
# The supervisor's restart budget: a server that keeps dying is not fixed by restarting it in
# the same container forever.
# ---------------------------------------------------------------------------------------------

# $1 = now (epoch seconds), $2 = window in seconds, $3.. = the times of earlier restarts.
# Prints the restarts that are still inside the window, space separated.
flux_restarts_in_window() {
  local now="$1" window="$2" t kept=()
  shift 2
  for t in "$@"; do
    [ "${t}" -gt $((now - window)) ] && kept+=("${t}")
  done
  printf '%s' "${kept[*]}"
}

# $1 = why the last generation ended. A restart the supervisor planned (a game update, the
# daily restart, one the panel asked for) is the plan working, not a crash; neither is Steam
# dropping the server (its weekly maintenance), which is waited out with a growing backoff.
flux_restart_counts() {
  case "$1" in
    planned* | requested* | steam:*) return 1 ;;
    *) return 0 ;;
  esac
}

# stdin = the end of the server's log. True when it ended because Steam dropped it ("Steam
# disconnected" is a known end of SCS's server).
flux_steam_dropped() {
  grep -qiE 'steam (is )?disconnected|disconnected from steam|logged ?off from steam|SteamAPI.*(fail|lost)'
}

# stdin = the end of the server's log. True when it stopped because it could not load its server
# packages ("Failed to load server packages info", measured with a hand-written .sii).
flux_packages_refused() {
  grep -qiE 'Failed to load server packages|Server packages file not found|generated for different map|time stamp does not match|wrong version'
}

# $1 = the previous backoff in seconds (0 for none). Prints the next: 30 s, doubling, at most 600.
flux_steam_backoff() {
  local prev="${1:-0}"
  [[ "${prev}" =~ ^[0-9]+$ ]] || prev=0
  if [ "${prev}" -lt 30 ]; then printf '30'; elif [ $((prev * 2)) -gt 600 ]; then printf '600'; else printf '%s' $((prev * 2)); fi
}

# $1 = the update-failed file, $2 = the build on Steam now, $3 = now, $4 = hours to wait. True when
# that same build failed to arrive less than $4 hours ago: no restart for it yet.
flux_update_failed_recently() {
  local target at
  [ -f "$1" ] || return 1
  read -r target at <"$1" || return 1
  [ "${target}" = "$2" ] || return 1
  [[ "${at}" =~ ^[0-9]+$ ]] || return 1
  [ $(($3 - at)) -lt $(($4 * 3600)) ]
}

# ---------------------------------------------------------------------------------------------
# The daily restart. There is no console to warn players through, so it waits for an empty server first.
# ---------------------------------------------------------------------------------------------

# $1 = SCS_RESTART_TIME as given. Prints HH:MM (in TZ), or "" when off. Returns 1 for a value that
# is not a time.
flux_restart_time() {
  local value="${1-}" h m
  case "${value,,}" in
    "" | off | none | false | 0) printf ''; return 0 ;;
  esac
  [[ "${value}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  h=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]}))
  [ "${h}" -le 23 ] && [ "${m}" -le 59 ] || return 1
  printf '%02d:%02d' "${h}" "${m}"
}

# $1 = now (epoch seconds), $2 = HH:MM in the container's time zone (TZ; UTC when unset). Prints
# the epoch of the next time it is $2: today when that is still ahead, tomorrow otherwise. Through
# `date`, so a daylight-saving change is the zone's, not an hour off.
flux_next_daily() {
  local now="$1" at
  at="$(date -d "$(date -d "@${now}" +%F) $2" +%s 2>/dev/null)" || return 1
  if [ "${at}" -le "${now}" ]; then
    at="$(date -d "$(date -d "@$((now + 86400))" +%F) $2" +%s 2>/dev/null)" || return 1
  fi
  printf '%s' "${at}"
}

# ---------------------------------------------------------------------------------------------
# Rotation of the game logs and the backups.
# ---------------------------------------------------------------------------------------------

# $1 = number to keep, then the files NEWEST FIRST. Prints the ones to delete.
flux_files_to_prune() {
  local keep="$1" i=0 f
  shift
  for f in "$@"; do
    i=$((i + 1))
    [ "${i}" -gt "${keep}" ] && printf '%s\n' "${f}"
  done
  return 0
}

# $1 = directory, $2 = glob, $3 = number to keep.
flux_prune() {
  local f files=()
  # shellcheck disable=SC2012,SC2086  # $2 is a glob on purpose; names are ours, no spaces
  mapfile -t files < <(ls -t "$1"/$2 2>/dev/null)
  while IFS= read -r f; do
    [ -n "${f}" ] && rm -f "${f}"
  done < <(flux_files_to_prune "$3" "${files[@]}")
}

# ---------------------------------------------------------------------------------------------
# Steam builds: an outdated server refuses players on the new client, so a new build means a
# restart (onto it). SteamCMD's own "up to date" check is not trusted: the installed buildid
# (appmanifest) is compared with the public branch's (app_info).
# ---------------------------------------------------------------------------------------------

# $1 = an appmanifest_<app>.acf. Prints its buildid.
flux_installed_build() {
  [ -f "$1" ] || return 0
  awk -F'"' '$2 == "buildid" { print $4; exit }' "$1"
}

# stdin = steamcmd +app_info_print output. Prints the public branch's buildid.
# $1 = the branch (default public).
flux_public_build() {
  awk -v want="\"${1:-public}\"" '
    /"branches"/ { inb = 1 }
    inb && $1 == want { inp = 1 }
    inp && /"buildid"/ { gsub(/"/, "", $2); print $2; exit }
  '
}

# $1 = the binary's name.
flux_game_pid() {
  pgrep -f "^\./$1" 2>/dev/null | head -1
}
