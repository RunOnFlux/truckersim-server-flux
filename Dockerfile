# Euro Truck Simulator 2 / American Truck Simulator convoy server image for Flux (SCS_GAME).
#
# Written from scratch. SCS's dedicated server (Steam apps 1948160 / 2239530, free, anonymous),
# installed and updated with SteamCMD on every start, under a supervisor that writes
# server_config.sii and config_ds.cfg from the environment and the hub's panel, ships the base-map
# packages until the owner uploads their own (map DLC and mods come from the game's
# export_server_packages), restarts onto game updates when nobody is driving, and gives the hub a
# JSON status read off the server's log. See README.md.
# The base. CI builds it pinned to the digest it resolved and records that digest in the
# org.opencontainers.image.base.digest label, which the scheduled check compares against
# (.github/ci/needs-rebuild.sh).
ARG BASE_IMAGE=steamcmd/steamcmd:ubuntu-24
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUX_IMAGE_VERSION=dev

# libatomic1 + libx11-6: what the server binary needs that the base lacks (ldd, 1.61).
RUN apt-get update -y && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends ca-certificates curl procps tzdata python3 libatomic1 libx11-6 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/fluxscs.py /opt/flux/
# The base-map packages (no DLC, no mods) for both games, from LsHallo/ets2-dedicated-convoy-server
# (Apache-2.0): the server will not start without a packages pair, and only the game can export one.
COPY default_packages /opt/flux/default_packages
RUN chmod 0755 /opt/flux/*.sh /opt/flux/fluxscs.py && ln -s /opt/flux/fluxscs.py /usr/local/bin/flux-scs

RUN steamcmd +quit >/dev/null 2>&1; test -d /root/.local/share/Steam

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION}

VOLUME ["/mnt/scs/server", "/mnt/scs/data"]

# SCS documents both TCP and UDP on the connection and query ports.
EXPOSE 27015/udp 27015/tcp 27016/udp 27016/tcp

HEALTHCHECK --interval=60s --timeout=10s --start-period=15m --retries=3 \
    CMD pgrep -f "^\./(eurotrucks2|amtrucks)_server" >/dev/null || exit 1

ENTRYPOINT []
CMD ["/opt/flux/flux-entrypoint.sh"]
