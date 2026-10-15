#!/usr/bin/env bash
# ============================================================================
# TrueNAS *arr stack: datasets + docker compose builder
#
# Creates the "configs" and "media" datasets (split pools supported), builds a
# docker-compose.yml wired to them, and optionally launches the stack.
# Layout follows wiki.serversatho.me/en/Folder-Structure (TRaSH-style: media
# subfolders, not datasets, so hardlinks work).
#
# Run in the TrueNAS shell as root:
#   sudo su -c "wget https://raw.githubusercontent.com/serversathome/ServersatHome/refs/heads/main/truenas-file-structure.sh && chmod +x truenas-file-structure.sh && bash truenas-file-structure.sh"
# ============================================================================

set -uo pipefail

# ── Helpers ─────────────────────────────────────────────────────────────────
info() { echo ">>> $*"; }
warn() { echo "⚠️  $*"; }
die()  { echo "❌ $*" >&2; exit 1; }

# wait_for <description> <timeout-seconds> <command...>
# Polls until the command succeeds. Bounded, so a container that never comes up
# (bad VPN config, image pull failure) can't hang the script forever.
wait_for() {
    local what="$1" timeout="$2"; shift 2
    local waited=0
    echo "Waiting for $what (up to ${timeout}s)..."
    until "$@" >/dev/null 2>&1; do
        sleep 5; waited=$(( waited + 5 ))
        if [ "$waited" -ge "$timeout" ]; then
            warn "Timed out waiting for $what."
            return 1
        fi
    done
    return 0
}

# ── Pre-flight ──────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "Run this script as root (sudo su)."
command -v zfs >/dev/null 2>&1 || die "zfs not found. Is this a TrueNAS shell?"
command -v docker >/dev/null 2>&1 || die "docker not found. Enable the Apps service in the TrueNAS UI first."

# ── Pool selection ──────────────────────────────────────────────────────────
read -rp "Enter the pool name for configs: " CONFIG_POOL
read -rp "Enter the pool name for media (can be same as configs): " MEDIA_POOL

validate_pool() {
    local pool="$1"
    [[ "$pool" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] \
        || die "Pool name '$pool' must be lowercase with no spaces."
    zpool list -H -o name "$pool" >/dev/null 2>&1 \
        || die "Pool '$pool' does not exist. Available pools: $(zpool list -H -o name | tr '\n' ' ')"
}
validate_pool "$CONFIG_POOL"
validate_pool "$MEDIA_POOL"

# ── Host facts ──────────────────────────────────────────────────────────────
# LAN network for the qBittorrent VPN LAN bypass. Use the interface that
# carries the default route and its real prefix (not the first address
# `hostname -I` returns, which can be a Docker bridge, and not an assumed /24).
DEFAULT_IF=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
HOST_CIDR=$(ip -o -4 addr show dev "${DEFAULT_IF:-lo}" scope global 2>/dev/null | awk '{print $4; exit}')
HOST_IP="${HOST_CIDR%/*}"
if [ -n "$HOST_CIDR" ] && command -v python3 >/dev/null 2>&1; then
    CIDR_NETWORK=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$HOST_CIDR" 2>/dev/null)
fi
if [ -z "${CIDR_NETWORK:-}" ]; then
    HOST_IP=$(hostname -I | awk '{print $1}')
    CIDR_NETWORK="${HOST_IP%.*}.0/24"
    warn "Could not derive the LAN prefix; assuming $CIDR_NETWORK"
fi

# Timezone for the containers: whatever TrueNAS is set to.
TZ_VALUE=$(timedatectl show -p Timezone --value 2>/dev/null || true)
[ -n "$TZ_VALUE" ] || TZ_VALUE=$(cat /etc/timezone 2>/dev/null || true)
[ -n "$TZ_VALUE" ] || TZ_VALUE="America/New_York"

# Group that owns the Docker socket (999 on a standard TrueNAS install).
# Dozzle runs as 568:568 and must join it to see containers.
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo 999)

# ── Layout ──────────────────────────────────────────────────────────────────
# One config dataset per app. Seerr is the exception: its container always runs
# as UID 1000 (the node user) and ignores `user:`, so its dataset is owned by
# 1000 — see wiki.serversatho.me/en/seerr.
CONFIG_DATASETS=("prowlarr" "radarr" "sonarr" "seerr" "profilarr" "bazarr" "jellyfin" "qbittorrent" "qui" "dozzle")
MEDIA_SUBDIRECTORIES=("movies" "tv" "downloads" "downloads/torrent")
DOCKER_COMPOSE_PATH="/mnt/$CONFIG_POOL/docker"
DOCKER_COMPOSE_FILE="$DOCKER_COMPOSE_PATH/docker-compose.yml"
QBITTORRENT_WIREGUARD_DIR="/mnt/$CONFIG_POOL/configs/qbittorrent/wireguard"

# set_perms <path> [owner]   (default root:apps, 770)
set_perms() {
    local path="$1" owner="${2:-root:apps}"
    chown "$owner" "$path"
    chmod 770 "$path"
}

# create_dataset <pool> <dataset> [owner]
# Prefers the TrueNAS middleware (midclt) so the UI knows about the dataset;
# falls back to plain `zfs create` where midclt isn't available.
create_dataset() {
    local pool_name="$1" dataset_name="$2" owner="${3:-root:apps}"
    local dataset_path="$pool_name/$dataset_name"
    local mountpoint="/mnt/$dataset_path"

    if ! zfs list "$dataset_path" >/dev/null 2>&1; then
        echo "Creating dataset: $dataset_path"
        if command -v midclt >/dev/null 2>&1; then
            midclt call pool.dataset.create "{\"name\": \"$dataset_path\"}" >/dev/null \
                || zfs create "$dataset_path" \
                || die "Failed to create dataset $dataset_path"
        else
            zfs create "$dataset_path" || die "Failed to create dataset $dataset_path"
        fi
    fi

    if ! mountpoint -q "$mountpoint"; then
        echo "Mounting dataset: $dataset_path"
        zfs mount "$dataset_path" || true
    fi

    if [ -d "$mountpoint" ]; then
        set_perms "$mountpoint" "$owner"
    else
        die "$mountpoint does not exist after mounting. Check dataset status."
    fi
}

# create_directory <path> [owner]
create_directory() {
    local dir_path="$1" owner="${2:-root:apps}"
    if [ ! -d "$dir_path" ]; then
        echo "Creating directory: $dir_path"
        mkdir -p "$dir_path" || die "Failed to create $dir_path"
    else
        echo "Directory already exists: $dir_path, updating permissions..."
    fi
    set_perms "$dir_path" "$owner"
}

# ── Datasets ────────────────────────────────────────────────────────────────
create_dataset "$CONFIG_POOL" "configs"
for dataset in "${CONFIG_DATASETS[@]}"; do
    if [ "$dataset" = "seerr" ]; then
        create_dataset "$CONFIG_POOL" "configs/$dataset" "1000:1000"
    else
        create_dataset "$CONFIG_POOL" "configs/$dataset"
    fi
done

create_dataset "$MEDIA_POOL" "media"
for subdir in "${MEDIA_SUBDIRECTORIES[@]}"; do
    create_directory "/mnt/$MEDIA_POOL/media/$subdir"
done

create_directory "$DOCKER_COMPOSE_PATH"

# ── docker-compose.yml ──────────────────────────────────────────────────────
# Regenerated every run (it has to reflect the pools you just chose), but an
# existing file is backed up first so hand edits are never lost.
if [ -f "$DOCKER_COMPOSE_FILE" ]; then
    backup="$DOCKER_COMPOSE_FILE.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$DOCKER_COMPOSE_FILE" "$backup"
    warn "Existing compose file backed up to $backup"
fi

cat > "$DOCKER_COMPOSE_FILE" <<EOF
services:
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped
    ports:
      - 9696:9696
    environment:
      - PUID=568
      - PGID=568
      - TZ=$TZ_VALUE
    volumes:
      - /mnt/$CONFIG_POOL/configs/prowlarr:/config

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    ports:
      - 7878:7878
    environment:
      - PUID=568
      - PGID=568
      - TZ=$TZ_VALUE
    volumes:
      - /mnt/$CONFIG_POOL/configs/radarr:/config
      - /mnt/$MEDIA_POOL/media:/media

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    ports:
      - 8989:8989
    environment:
      - PUID=568
      - PGID=568
      - TZ=$TZ_VALUE
    volumes:
      - /mnt/$CONFIG_POOL/configs/sonarr:/config
      - /mnt/$MEDIA_POOL/media:/media

  seerr:
    # Runs as UID 1000 internally and ignores "user:"; its config dataset is
    # owned by 1000 for that reason.
    image: ghcr.io/seerr-team/seerr:latest
    init: true
    container_name: seerr
    environment:
      - LOG_LEVEL=info
      - TZ=$TZ_VALUE
      - PORT=5055
    ports:
      - 5055:5055
    healthcheck:
      test: wget --no-verbose --tries=1 --spider http://localhost:5055/api/v1/status || exit 1
      start_period: 20s
      timeout: 3s
      interval: 15s
      retries: 3
    restart: unless-stopped
    volumes:
      - /mnt/$CONFIG_POOL/configs/seerr:/app/config

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    environment:
      - LOG_LEVEL=info
      - LOG_HTML=false
      - CAPTCHA_SOLVER=none
      - TZ=$TZ_VALUE
    ports:
      - 8191:8191
    restart: unless-stopped

  profilarr:
    image: ghcr.io/dictionarry-hub/profilarr:latest
    container_name: profilarr
    restart: unless-stopped
    ports:
      - "6868:6868"
    volumes:
      - /mnt/$CONFIG_POOL/configs/profilarr:/config
    environment:
      - PUID=568
      - PGID=568
      - UMASK=022
      - TZ=$TZ_VALUE

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    restart: unless-stopped
    ports:
      - 6767:6767
    environment:
      - PUID=568
      - PGID=568
      - TZ=$TZ_VALUE
    volumes:
      - /mnt/$CONFIG_POOL/configs/bazarr:/config
      - /mnt/$MEDIA_POOL/media:/media

  jellyfin:
    container_name: jellyfin
    image: lscr.io/linuxserver/jellyfin:latest
    environment:
      - PUID=568
      - PGID=568
      - TZ=$TZ_VALUE
    ports:
      - '8096:8096'
    restart: unless-stopped
    volumes:
      - /mnt/$CONFIG_POOL/configs/jellyfin:/config
      - /mnt/$MEDIA_POOL/media:/media

  qbittorrent:
    container_name: qbittorrent
    # Version pinned on purpose; bump deliberately, not via :latest.
    image: ghcr.io/hotio/qbittorrent:release-5.1.2
    restart: unless-stopped
    ports:
      - 8080:8080
    environment:
      - PUID=568
      - PGID=568
      - UMASK=002
      - TZ=$TZ_VALUE
      - WEBUI_PORTS=8080/tcp,8080/udp
      - VPN_ENABLED=true
      - VPN_CONF=wg0
      - VPN_PROVIDER=generic
      - VPN_LAN_NETWORK=$CIDR_NETWORK,10.8.0.0/24
      - VPN_LAN_LEAK_ENABLED=false
      - VPN_EXPOSE_PORTS_ON_LAN=
      - VPN_AUTO_PORT_FORWARD=true
      - VPN_PORT_REDIRECTS=
      - VPN_FIREWALL_TYPE=auto
      - VPN_HEALTHCHECK_ENABLED=false
      - VPN_NAMESERVERS=wg
      - PRIVOXY_ENABLED=false
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=1
    volumes:
      - /mnt/$CONFIG_POOL/configs/qbittorrent:/config
      - /mnt/$MEDIA_POOL/media:/media

  qui:
    image: ghcr.io/autobrr/qui:latest
    container_name: qui
    user: "568:568"
    restart: unless-stopped
    ports:
      - "7476:7476"
    volumes:
      - /mnt/$CONFIG_POOL/configs/qui:/config
      - /mnt/$MEDIA_POOL/media:/media

  dozzle:
    # Dozzle 11+: runs as 568, needs the Docker socket's group and a /data
    # volume for users/settings. /proc is optional (host uptime/load card).
    image: amir20/dozzle:latest
    container_name: dozzle
    user: "568:568"
    group_add:
      - "$DOCKER_GID"
    environment:
      - TZ=$TZ_VALUE
    restart: unless-stopped
    ports:
      - '8888:8080'
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /mnt/$CONFIG_POOL/configs/dozzle:/data
      - /proc:/host/proc:ro

  watchtower:
    container_name: watchtower
    environment:
      - TZ=$TZ_VALUE
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_NOTIFICATIONS_HOSTNAME=TrueNAS
      - WATCHTOWER_INCLUDE_STOPPED=true
      # Skip TrueNAS catalog apps (ix-<app>-...). This Watchtower fork matches
      # names as anchored regexes, so "ix*" would match nothing useful.
      - WATCHTOWER_DISABLE_CONTAINERS=ix-.*
      - WATCHTOWER_NO_STARTUP_MESSAGE=true
      - WATCHTOWER_SCHEDULE=0 0 3 * * *
    image: nickfedor/watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
EOF

echo "Docker Compose file created at $DOCKER_COMPOSE_FILE"
echo "Datasets and directories are in place."

# ── qBittorrent default save path ───────────────────────────────────────────
# Keys in qBittorrent.conf contain a literal backslash (Session\DefaultSavePath).
# Use fixed-string grep and single-quoted sed patterns so the backslash
# survives; in double quotes "\\D" reaches sed/grep as "\D", which they treat as
# a plain "D" and nothing ever matches.
set_qbittorrent_save_path() {
    local conf="$1" save_path="$2"
    if grep -qF '[BitTorrent]' "$conf"; then
        if grep -qF 'Session\DefaultSavePath=' "$conf"; then
            echo "Updating Session\\DefaultSavePath in $conf"
            sed -i '/^\[BitTorrent\]/,/^\[/ s|^Session\\DefaultSavePath=.*|Session\\DefaultSavePath='"$save_path"'|' "$conf"
        else
            echo "Adding Session\\DefaultSavePath under [BitTorrent] in $conf"
            sed -i '/^\[BitTorrent\]/a Session\\DefaultSavePath='"$save_path" "$conf"
        fi
    else
        echo "Adding [BitTorrent] section and Session\\DefaultSavePath to $conf"
        printf '\n[BitTorrent]\nSession\\DefaultSavePath=%s\n' "$save_path" >> "$conf"
    fi
    grep -qF "Session\\DefaultSavePath=$save_path" "$conf"
}

# ── Launch ──────────────────────────────────────────────────────────────────
read -rp "Would you like to launch the Docker containers now? (yes/no): " LAUNCH_CONTAINERS
if [[ ! "$LAUNCH_CONTAINERS" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo "Docker containers were not launched. You can start them manually by running:"
    echo "cd $DOCKER_COMPOSE_PATH && docker compose up -d"
    exit 0
fi

docker info >/dev/null 2>&1 \
    || die "Cannot talk to the Docker daemon. Enable the Apps service in the TrueNAS UI, then re-run."

# WireGuard config for qBittorrent (hotio expects /config/wireguard/wg0.conf).
create_directory "$QBITTORRENT_WIREGUARD_DIR"
echo "Please paste your WireGuard VPN configuration below by using SHIFT+INS to paste (press ENTER then Ctrl+D when done):"
WG_CONFIG=$(cat)
if [ -z "${WG_CONFIG//[[:space:]]/}" ]; then
    warn "No WireGuard configuration entered. qBittorrent will not start until $QBITTORRENT_WIREGUARD_DIR/wg0.conf exists."
else
    printf '%s\n' "$WG_CONFIG" > "$QBITTORRENT_WIREGUARD_DIR/wg0.conf"
    chown root:apps "$QBITTORRENT_WIREGUARD_DIR/wg0.conf"
    chmod 660 "$QBITTORRENT_WIREGUARD_DIR/wg0.conf"
    echo "WireGuard configuration saved to $QBITTORRENT_WIREGUARD_DIR/wg0.conf"
fi

cd "$DOCKER_COMPOSE_PATH" || die "Cannot cd to $DOCKER_COMPOSE_PATH"
echo "Launching Docker containers from $DOCKER_COMPOSE_PATH..."
docker compose up -d || die "Failed to launch Docker containers. Check the logs for errors."
echo "Docker containers launched successfully!"

# qBittorrent: set the default save path once it has written its config.
QBITTORRENT_CONF_FILE="/mnt/$CONFIG_POOL/configs/qbittorrent/config/qBittorrent.conf"
if wait_for "qBittorrent to generate its configuration file" 180 test -f "$QBITTORRENT_CONF_FILE"; then
    if set_qbittorrent_save_path "$QBITTORRENT_CONF_FILE" "/media/downloads"; then
        echo "qBittorrent default save path set to /media/downloads"
        echo "Restarting qBittorrent container to apply the new configuration..."
        docker restart qbittorrent >/dev/null && echo "qBittorrent restarted."
    else
        warn "Could not set the qBittorrent default save path; set it in the WebUI (Options > Downloads)."
    fi
else
    warn "qBittorrent has not written $QBITTORRENT_CONF_FILE. Usually the VPN config is wrong:"
    warn "  docker logs qbittorrent"
fi

# Radarr / Sonarr: add root folders via their APIs.
RADARR_CONFIG_FILE="/mnt/$CONFIG_POOL/configs/radarr/config.xml"
SONARR_CONFIG_FILE="/mnt/$CONFIG_POOL/configs/sonarr/config.xml"

extract_api_key() {
    [ -f "$1" ] && grep -oP '(?<=<ApiKey>)[^<]+' "$1"
}

# add_root_folder <app> <port> <api-key> <path>
add_root_folder() {
    local app="$1" port="$2" key="$3" path="$4"
    if ! wait_for "$app to be ready" 180 curl -fs -H "X-Api-Key: $key" "http://localhost:$port/api/v3/system/status" -o /dev/null; then
        warn "$app is not responding; add the root folder $path manually."
        return 1
    fi
    echo "Adding root folder $path to $app..."
    if curl -fs -X POST "http://localhost:$port/api/v3/rootfolder" \
        -H "X-Api-Key: $key" -H "Content-Type: application/json" \
        -d "{\"path\": \"$path\"}" -o /dev/null; then
        echo "$app root folder added."
    else
        warn "$app rejected the root folder (it may already exist). Check $app > Settings > Media Management."
    fi
}

echo "Extracting API keys from Radarr and Sonarr..."
wait_for "Radarr and Sonarr to generate config files" 180 \
    bash -c "[ -f '$RADARR_CONFIG_FILE' ] && [ -f '$SONARR_CONFIG_FILE' ]" || true

RADARR_API_KEY=$(extract_api_key "$RADARR_CONFIG_FILE")
SONARR_API_KEY=$(extract_api_key "$SONARR_CONFIG_FILE")
if [ -n "$RADARR_API_KEY" ]; then echo "Radarr API key extracted"; else warn "Radarr API key not found in $RADARR_CONFIG_FILE"; fi
if [ -n "$SONARR_API_KEY" ]; then echo "Sonarr API key extracted"; else warn "Sonarr API key not found in $SONARR_CONFIG_FILE"; fi

[ -n "$RADARR_API_KEY" ] && add_root_folder Radarr 7878 "$RADARR_API_KEY" /media/movies
[ -n "$SONARR_API_KEY" ] && add_root_folder Sonarr 8989 "$SONARR_API_KEY" /media/tv
if [ -z "$RADARR_API_KEY" ] || [ -z "$SONARR_API_KEY" ]; then
    warn "Root folders for any app without an API key were skipped. You can add them manually later."
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Running containers and their URLs:"
docker ps --format "{{.Names}}" | while read -r container_name; do
    ports=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{ (index $conf 0).HostPort }} {{end}}{{end}}' "$container_name")
    if [ -n "$ports" ]; then
        for port in $ports; do
            echo "$container_name | http://$HOST_IP:$port"
        done
    else
        echo "$container_name | No exposed port found"
    fi
done

# qBittorrent prints a temporary WebUI password on first start.
if docker ps --format "{{.Names}}" | grep -qx qbittorrent; then
    echo "Fetching qBittorrent password from logs..."
    sleep 10
    qbittorrent_password=$(docker logs qbittorrent 2>&1 | grep -oP 'A temporary password is provided for this session: \K\S+' | tail -1)
    if [ -n "$qbittorrent_password" ]; then
        echo "qBittorrent WebUI password: $qbittorrent_password"
    else
        echo "qBittorrent WebUI password not found in logs yet. Run: docker logs qbittorrent | grep 'temporary password'"
    fi
else
    warn "qBittorrent container is not running (check the VPN config): docker logs qbittorrent"
fi
echo "Script completed."
