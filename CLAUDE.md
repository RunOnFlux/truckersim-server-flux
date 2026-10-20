# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Docker image repo**: SCS's convoy dedicated server for Euro Truck Simulator 2 and American
Truck Simulator (`SCS_GAME`), `runonflux/truckersim-server-flux`. steamcmd/steamcmd:ubuntu-24 and a
supervisor in bash. Same family as `~/work/corekeeper-server-flux`.

## Commands

```bash
./tests/test-flux.sh
docker build -t truckersim-server-flux:local .
./tests/test-image.sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh .github/ci/*.sh
```

## Things that will bite you

- **No packages, no server.** `server_packages.sii/.dat` must exist; the base-map pair ships in
  `default_packages/` (Apache-2.0, LsHallo/ets2-dedicated-convoy-server).
- **max_players above 8 needs `g_max_convoy_size` in config_ds.cfg**, or the server clamps it and
  writes 8 back; and every PLAYER needs the same value in their game.
- **Stop with SIGINT.** The stand-in server in the image test is Python: a background bash cannot
  trap SIGINT.
- **The ATS server needs two `app_update`s** after `app_info_update` ("Missing configuration").
- **The log, not stdout**, has the `[MP]` lines the roster is read from.
- **Each run gets its own server.log.txt** (rotate_log before the exec): never read the previous
  run's lines for readiness or the roster. The parser keeps its place in /tmp.
- **Real exports write DLC as unsigned numbers**: a quoted value stops the server. Never name DLC.
- **Logon tokens are for the GAME's app** (227300 ETS2, 270880 ATS), not the server's.
- **The game's rotated logs are local too** (`${FLUX_GAME_LOG_DIR}` = `${FLUX_SERVER_DIR}/flux-logs/game`, newest 5 via `flux_prune`). `flux_game_logs_migrate` moves an old `data/flux/logs` there once and removes it.
- **flux.log is local** (`${FLUX_SERVER_DIR}/flux-logs/flux.log`, 5 MB + one `.1`, on the `ml:` mount), never the synced data volume. `flux_log_migrate` moves an older `flux/flux.log` there once. `entrypoint` creates the dir explicitly. The start-up banner is `flux_banner "<game>"` (container start and every generation); keep its text.
