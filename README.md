# truckersim-server-flux

The SCS convoy dedicated server for [Flux](https://runonflux.io), as
`runonflux/truckersim-server-flux`: **Euro Truck Simulator 2** or **American Truck Simulator**
(`SCS_GAME=ets2|ats`, the same server for both). SCS's server (Steam apps 1948160 / 2239530, free,
anonymous), installed and updated with SteamCMD on every start, under a supervisor that:

- writes `server_config.sii` and `config_ds.cfg` from the environment and the hub's panel
- ships the **base-map packages** (no DLC, no mods) until the owner uploads their own: the server
  does not start without a `server_packages.sii`/`.dat` pair, and only the game can export one
  (console: `export_server_packages`), with the map DLC and mods that profile has
- raises the player cap past SCS's 8 when asked (`g_max_convoy_size`), and says what that costs:
  every player must set the same value in their own game to see the session
- restarts onto a new game build once nobody is driving (players must run the server's version)
- gives the hub a JSON status read off the server's log (each run's own: the previous run's log is
  moved aside at every start, and only what is new is read on each poll): players, chat, session
  search ID
- keeps backups of the settings, packages and ban list (before every change and at a start, the
  newest 10 plus the newest older than a day and a week) and restores one on request, after a
  safety backup
- waits out Steam dropping the server (a growing backoff, never counted as a crash), and stops
  rather than crash-loops on server packages it cannot load (the panel says so)

There is no world to save: a convoy server keeps none. There is no console and no RCON either.

## Volumes

| Path | Flux mount | What |
|---|---|---|
| `/mnt/scs/data` | `g:` (synced) | the server's home (`XDG_DATA_HOME`): `<game>/server_config.sii`, `config_ds.cfg`, `server_packages.sii/.dat`, `server.log.txt`, `banlist.txt`; and `flux/` (state, backups) |
| `/mnt/scs/server` | `ml:server` (local) | the server, ~1.3 GB, and our `flux-logs/flux.log` (5 MB, one `.1`) |

## Ports

`SCS_PORT` (27015) and `SCS_QUERY_PORT` (the next one): SCS documents TCP and UDP on both.
Without a public port players still find the server by its session search ID.

## Environment

A variable that is SET to a non-empty value is applied on every start; one that is unset or EMPTY
leaves the panel's value, then the default (the marketplace writes blank declared parameters).
`SCS_MODERATORS` MERGES with the panel's list instead: both are moderators.

| Variable | server_config.sii | |
|---|---|---|
| `SCS_GAME` | | `ets2` (default) or `ats` |
| `SCS_LOBBY_NAME`, `SCS_DESCRIPTION`, `SCS_WELCOME` | `lobby_name`, `description`, `welcome_message` | 63/63/127 characters |
| `SCS_PASSWORD` | `password` | |
| `SCS_MAX_PLAYERS` | `max_players` + `g_max_convoy_size` | 1-128 (default 8, SCS's limit); above 8, players must set `g_max_convoy_size` too. The marketplace plans do not set it: raising the convoy is the owner's choice, in the panel |
| `SCS_TOKEN` | `server_logon_token` | a Steam game server token for the GAME's app (227300 / 270880): a session ID that stays the same across restarts |
| `SCS_MODERATORS` | `moderator_list` | SteamID64s |
| `SCS_TRAFFIC`, `SCS_PLAYER_DAMAGE`, `SCS_FORCE_SPEED_LIMITER`, `SCS_NAME_TAGS`, `SCS_SERVICE_NO_COLLISION`, `SCS_IN_MENU_GHOSTING`, `SCS_TIMEZONES`, `SCS_MAX_AI` | the same keys | |
| `SCS_RESTART_TIME` | | `HH:MM`, a daily restart once nobody is driving |

The panel has the rest (`hide_in_company`, `hide_colliding`, `mods_optioning`, vehicle limits,
cargo in convoys).

## For the hub

| Command | |
|---|---|
| `flux-scs status` | `state`, `since`, `generation` (one per server start: what a restart waits for), `players` (`name`, `id`), `reportedPlayers` (the server's own count), `chat`, `searchId`, `version`, `packages` (map, DLC, mods), `pending` (settings or packages the running server has not picked up) |
| `flux-scs settings` / `set-settings '<json>'` | |
| `flux-scs packages` / `set-packages <sii> <dat>` / `reset-packages` | the map packages: install a pair exported from the game (checked: a map that is not the other game's, DLC written as the game writes them, and the .dat's time stamp equal to the .sii's, so both come from the same export) |
| `flux-scs backups` / `restore <name>` | the backups (name, size, date, why); a restore restarts the server onto one, after a safety backup ("pre-restore") |
| `flux-scs restart` | `appliesOn`: `now` (the server is signalled, or the wait for new packages ends) or `start` (no game process while the supervisor downloads or backs off: the next start writes the saved settings). Exit 3 only when nothing is there to pick it up |

## Measured (ETS2 1.61.1.1, ATS 1.61.2.0)

- ~1.3 GB install; up 3 s after start; ~275 MB RAM and ~5% of a core idle; `docker stop` 1.9 s.
- The ATS download answers "Missing configuration" to a first `app_update`; the second works.
- The server rewrites `server_config.sii` at start (and clamps `max_players` to
  `g_max_convoy_size`): both files are written from the settings on every start.
- `[MP]` lines go to `server.log.txt`, not to stdout. `[MP] State: ...; Players: N` every ~3 minutes is
  the server's own headcount: 0 clears a driver whose disconnect was never logged.
- A `.dat`'s bytes 2-5 (little-endian) are its export's time stamp, equal to the `.sii`'s
  `time_stamp` (both base-map pairs).
- Packages the server cannot load (a hand-written `.sii` with quoted DLC: "Expecting unsigned
  value") end it 5 s after the start with "Failed to load server packages info".

## Versions

- **1.0.4** (2026-10-20): flux.log moved off the synced data volume to `flux-logs/flux.log` on the local install volume (5 MB, one `.1` rotated copy; an old one on the data volume is appended there once and deleted); the FluxCloud start-up banner at container start and on every server generation; the scheduled build runs on Mondays and publishes only for an urgent security update or commits the published image does not have. (Banner names the running game.)
- **1.0.3** (2026-10-17): `restart` with no game process no longer answers "not running" while the
  supervisor is alive (downloading, backing off, waiting for packages), so the panel never restarts
  the container over a first download or onto the same refused packages.
- **1.0.2** (2026-10-11): each run's own log (moved aside at every start; read incrementally); a
  restart is a new `generation`; `pending` with no settings file and after a reset; empty env values
  are unset; moderators merge; C1 controls and line separators dropped from text; an empty name
  refused; an unusable env value warned about; package pairs checked (map, DLC format, time stamp);
  backups and `restore`; refused packages wait instead of crash-looping; Steam dropping the server
  backed off and not counted; a failed update not restarted for again for 6 h; SteamCMD in the
  background (a stop does not wait for a download); the app cache dropped before an update check;
  the image test runs American Truck Simulator too.
- **1.0.1** (2026-10-11): `packages.default` is true for the shipped base-map pair of either game
  (American Truck Simulator's lists two optional DLC, and read as an upload).
- **1.0.0** (2026-10-11): first release.
