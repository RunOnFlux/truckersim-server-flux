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
- gives the hub a JSON status read off the server's log: players, chat, session search ID

There is no world to save: a convoy server keeps none. There is no console and no RCON either.

## Volumes

| Path | Flux mount | What |
|---|---|---|
| `/mnt/scs/data` | `g:` (synced) | the server's home (`XDG_DATA_HOME`): `<game>/server_config.sii`, `config_ds.cfg`, `server_packages.sii/.dat`, `server.log.txt`, `banlist.txt`; and `flux/` |
| `/mnt/scs/server` | `ml:server` (local) | the server, ~1.3 GB |

## Ports

`SCS_PORT` (27015) and `SCS_QUERY_PORT` (the next one): SCS documents TCP and UDP on both.
Without a public port players still find the server by its session search ID.

## Environment

| Variable | server_config.sii | |
|---|---|---|
| `SCS_GAME` | | `ets2` (default) or `ats` |
| `SCS_LOBBY_NAME`, `SCS_DESCRIPTION`, `SCS_WELCOME` | `lobby_name`, `description`, `welcome_message` | 63/63/127 characters |
| `SCS_PASSWORD` | `password` | |
| `SCS_MAX_PLAYERS` | `max_players` + `g_max_convoy_size` | 1-128; above 8, players must set `g_max_convoy_size` too |
| `SCS_TOKEN` | `server_logon_token` | a Steam game server token for the GAME's app (227300 / 270880): a session ID that stays the same across restarts |
| `SCS_MODERATORS` | `moderator_list` | SteamID64s |
| `SCS_TRAFFIC`, `SCS_PLAYER_DAMAGE`, `SCS_FORCE_SPEED_LIMITER`, `SCS_NAME_TAGS`, `SCS_SERVICE_NO_COLLISION`, `SCS_IN_MENU_GHOSTING`, `SCS_TIMEZONES`, `SCS_MAX_AI` | the same keys | |
| `SCS_RESTART_TIME` | | `HH:MM`, a daily restart once nobody is driving |

The panel has the rest (`hide_in_company`, `hide_colliding`, `mods_optioning`, vehicle limits,
cargo in convoys).

## For the hub

| Command | |
|---|---|
| `flux-scs status` | `state`, `players` (`name`, `id`), `chat`, `searchId`, `version`, `packages` (map, DLC, mods), `pending` |
| `flux-scs settings` / `set-settings '<json>'` | |
| `flux-scs packages` / `set-packages <sii> <dat>` / `reset-packages` | the map packages: install a pair exported from the game (checked: right game, both files) |
| `flux-scs restart` | |

## Measured (ETS2 1.61.1.1, ATS 1.61.2.0)

- ~1.3 GB install; up 3 s after start; ~275 MB RAM and ~5% of a core idle; `docker stop` 1.9 s.
- The ATS download answers "Missing configuration" to a first `app_update`; the second works.
- The server rewrites `server_config.sii` at start (and clamps `max_players` to
  `g_max_convoy_size`): both files are written from the settings on every start.
- `[MP]` lines go to `server.log.txt`, not to stdout.

## Versions

- **1.0.1** (2026-10-11): `packages.default` is true for the shipped base-map pair of either game
  (American Truck Simulator's lists two optional DLC, and read as an upload).
- **1.0.0** (2026-10-11): first release.
