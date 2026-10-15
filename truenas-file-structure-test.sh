#!/usr/bin/env bash
# ============================================================================
# TrueNAS *arr stack: datasets + docker compose + FULL AUTO-CONFIGURATION
#                                                        (TEST SCRIPT)
#
# Experimental superset of truenas-file-structure.sh. It does everything the
# main script does, then configures every container through its API in the
# order from wiki.serversatho.me/en/InstallInstructions:
#
#   qBittorrent -> Radarr -> Sonarr -> FlareSolverr -> Prowlarr -> Profilarr
#   -> Jellyfin -> Seerr -> Bazarr -> Qui
#
# Every step is idempotent (safe to re-run) and isolated: a step that cannot be
# completed prints what to finish in the UI and the rest still runs.
#
# Logins created by this script (change them afterwards!):
#   user: admin   password: changeme   email: admin@admin.com
#
# Run in the TrueNAS shell as root:
#   sudo su -c "wget https://raw.githubusercontent.com/serversathome/ServersatHome/refs/heads/main/truenas-file-structure-test.sh && chmod +x truenas-file-structure-test.sh && bash truenas-file-structure-test.sh"
# ============================================================================

# ok()/warn()/todo() always succeed, so "cmd && ok ... || todo ..." is a safe
# one-line if/else throughout this file.
# shellcheck disable=SC2015
set -uo pipefail

# ── Defaults for every login this script creates ────────────────────────────
ADMIN_USER="admin"
ADMIN_PASS="changeme"
ADMIN_EMAIL="admin@admin.com"

# ── Helpers ─────────────────────────────────────────────────────────────────
info() { echo ">>> $*"; }
ok()   { echo "    ✔ $*"; }
warn() { echo "⚠️  $*"; }
die()  { echo "❌ $*" >&2; exit 1; }

# wait_for <description> <timeout-seconds> <command...>
wait_for() {
    local what="$1" timeout="$2"; shift 2
    local waited=0
    # Progress goes to stderr: callers like `KEY=$(arr_key radarr)` capture
    # stdout, and a chatty wait_for would otherwise end up inside the value.
    echo "Waiting for $what (up to ${timeout}s)..." >&2
    until "$@" >/dev/null 2>&1; do
        sleep 5; waited=$(( waited + 5 ))
        if [ "$waited" -ge "$timeout" ]; then
            warn "Timed out waiting for $what." >&2
            return 1
        fi
    done
    return 0
}

# http <method> <url> [body] [extra curl args...]
# Prints the response body. The HTTP status goes to a temp file (not a
# variable) so it survives `x=$(http ...)` command substitutions; read it with
# http_code / http_ok. Never aborts the script.
# The body travels through a file (--data-binary @file), never as an argument:
# the *arr schema bodies run to tens of KB and must reach curl byte for byte.
# curl's stderr is kept so a transport failure shows up as "no response:
# curl: (7) ..." instead of a blank status in the messages below.
HTTP_STATUS_FILE=$(mktemp)
HTTP_BODY_FILE=$(mktemp)
HTTP_ERR_FILE=$(mktemp)
http() {
    local method="$1" url="$2" body="${3-}"
    shift $(( $# < 3 ? $# : 3 ))
    local out
    : > "$HTTP_ERR_FILE"
    if [ -n "$body" ]; then
        printf '%s' "$body" > "$HTTP_BODY_FILE"
        out=$(curl -sS -m 120 -X "$method" "$url" --data-binary "@$HTTP_BODY_FILE" "$@" -w $'\n%{http_code}' 2>"$HTTP_ERR_FILE")
    else
        out=$(curl -sS -m 120 -X "$method" "$url" "$@" -w $'\n%{http_code}' 2>"$HTTP_ERR_FILE")
    fi
    printf '%s' "${out##*$'\n'}" > "$HTTP_STATUS_FILE"
    printf '%s' "${out%$'\n'*}"
}
# http_code prints the status; with no usable status it prints the curl error
# so the messages read "HTTP no response: curl: (28) Connection timed out".
http_code() {
    local code err
    code=$(cat "$HTTP_STATUS_FILE" 2>/dev/null)
    if [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then printf '%s' "$code"; return; fi
    err=$(tr -d '\r' < "$HTTP_ERR_FILE" 2>/dev/null | grep -v '^$' | head -1 | cut -c1-160)
    printf 'no response: %s' "${err:-curl produced no output (status [${code}])}"
}
http_ok()   { [[ "$(cat "$HTTP_STATUS_FILE" 2>/dev/null)" =~ ^2[0-9][0-9]$ ]]; }

# jpy '<python expression over d>'  — evaluate against JSON on stdin.
# Scalars print raw; dicts/lists print as JSON. Empty/invalid input -> "".
jpy() {
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
try:
    r = eval(sys.argv[1])
except Exception:
    sys.exit(0)
if r is None:
    sys.exit(0)
print(r if not isinstance(r, (dict, list)) else json.dumps(r))' "$1"
}

# jbuild '<python expression>' — build JSON from a python literal that may use
# os.environ (safe way to embed passwords and keys without quoting trouble).
jbuild() {
    python3 -c 'import json, os, sys; print(json.dumps(eval(sys.argv[1])))' "$1"
}

# Shared state filled in as containers are configured.
RADARR_API_KEY=""; SONARR_API_KEY=""; PROWLARR_API_KEY=""; BAZARR_API_KEY=""
JELLYFIN_TOKEN=""
declare -a TODO_LIST=()
todo() { TODO_LIST+=("$*"); warn "$*"; }

# ── Pre-flight ──────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "Run this script as root (sudo su)."
command -v zfs >/dev/null 2>&1 || die "zfs not found. Is this a TrueNAS shell?"
command -v docker >/dev/null 2>&1 || die "docker not found. Enable the Apps service in the TrueNAS UI first."
command -v python3 >/dev/null 2>&1 || die "python3 not found (it ships with TrueNAS)."
command -v curl >/dev/null 2>&1 || die "curl not found."

# ── Pool selection ──────────────────────────────────────────────────────────
# Offer the pools that exist instead of asking the user to type a name. The
# boot pool is never a valid target, so it is left out of the menu.
mapfile -t POOLS < <(zpool list -H -o name | grep -vE '^(boot-pool|freenas-boot)$')
[ "${#POOLS[@]}" -gt 0 ] || die "No data pools found. Create a pool in the TrueNAS UI first."

# choose_pool <prompt> [default]  -> sets CHOSEN_POOL
choose_pool() {
    local prompt="$1" default="${2:-}" i choice
    echo ""
    echo "$prompt"
    for i in "${!POOLS[@]}"; do
        printf '  %d) %-20s %s\n' "$(( i + 1 ))" "${POOLS[$i]}" \
            "$(zpool list -H -o size,free "${POOLS[$i]}" | awk '{print "size "$1", free "$2}')"
    done
    while true; do
        if [ -n "$default" ]; then
            read -rp "Select a pool [1-${#POOLS[@]}] (Enter for $default): " choice
            [ -z "$choice" ] && { CHOSEN_POOL="$default"; return; }
        else
            read -rp "Select a pool [1-${#POOLS[@]}]: " choice
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#POOLS[@]}" ]; then
            CHOSEN_POOL="${POOLS[$(( choice - 1 ))]}"
            return
        fi
        echo "Please enter a number between 1 and ${#POOLS[@]}."
    done
}

if [ "${#POOLS[@]}" -eq 1 ]; then
    CONFIG_POOL="${POOLS[0]}"
    MEDIA_POOL="${POOLS[0]}"
    echo "Only one data pool found; using '$CONFIG_POOL' for both configs and media."
else
    choose_pool "Which pool should hold the app configs (SSD pool if you have one)?"
    CONFIG_POOL="$CHOSEN_POOL"
    choose_pool "Which pool should hold the media library (can be the same pool)?" "$CONFIG_POOL"
    MEDIA_POOL="$CHOSEN_POOL"
fi

# Dataset names need to be lowercase with no spaces for the rest of the stack.
for pool in "$CONFIG_POOL" "$MEDIA_POOL"; do
    [[ "$pool" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] \
        || die "Pool name '$pool' must be lowercase with no spaces. Rename the pool or create a compliant one."
done
echo "Configs pool: $CONFIG_POOL    Media pool: $MEDIA_POOL"

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
MEDIA_SUBDIRECTORIES=("movies" "tv" "downloads" "downloads/torrent" "downloads/crossseed")
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
      - DOZZLE_NO_ANALYTICS=true
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

# ── Launch ──────────────────────────────────────────────────────────────────
read -rp "Would you like to launch AND auto-configure the Docker containers now? (yes/no): " LAUNCH_CONTAINERS
if [[ ! "$LAUNCH_CONTAINERS" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo "Docker containers were not launched. You can start them manually by running:"
    echo "cd $DOCKER_COMPOSE_PATH && docker compose up -d"
    exit 0
fi

docker info >/dev/null 2>&1 \
    || die "Cannot talk to the Docker daemon. Enable the Apps service in the TrueNAS UI, then re-run."

# WireGuard config for qBittorrent (hotio expects /config/wireguard/wg0.conf).
create_directory "$QBITTORRENT_WIREGUARD_DIR"
if [ -s "$QBITTORRENT_WIREGUARD_DIR/wg0.conf" ]; then
    echo "WireGuard config already present at $QBITTORRENT_WIREGUARD_DIR/wg0.conf (leaving it alone)."
else
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
fi

cd "$DOCKER_COMPOSE_PATH" || die "Cannot cd to $DOCKER_COMPOSE_PATH"
echo "Launching Docker containers from $DOCKER_COMPOSE_PATH..."
docker compose up -d || die "Failed to launch Docker containers. Check the logs for errors."
echo "Docker containers launched successfully!"

# ============================================================================
#                           AUTO-CONFIGURATION PHASE
#
# Containers talk to each other by compose service name (radarr, sonarr,
# qbittorrent, ...). This script talks to them from the TrueNAS shell through
# the published ports on localhost.
# ============================================================================
export ADMIN_USER ADMIN_PASS ADMIN_EMAIL CONFIG_POOL MEDIA_POOL

QB_URL="http://localhost:8080"
RADARR_URL="http://localhost:7878";   RADARR_INT="http://radarr:7878"
SONARR_URL="http://localhost:8989";   SONARR_INT="http://sonarr:8989"
PROWLARR_URL="http://localhost:9696"; PROWLARR_INT="http://prowlarr:9696"
FLARE_URL="http://localhost:8191";    FLARE_INT="http://flaresolverr:8191/"
PROFILARR_URL="http://localhost:6868"
JELLYFIN_URL="http://localhost:8096"
SEERR_URL="http://localhost:5055"
BAZARR_URL="http://localhost:6767"
QUI_URL="http://localhost:7476"
QB_INT="http://qbittorrent:8080"

COOKIE_DIR=$(mktemp -d)
trap 'rm -rf "$COOKIE_DIR" "$HTTP_STATUS_FILE" "$HTTP_BODY_FILE" "$HTTP_ERR_FILE"' EXIT

# ── Shared *arr helpers (Radarr / Sonarr / Prowlarr share one API shape) ────
# arr_api <base-url> <api-key> <method> <path> [json-body]
arr_api() {
    local base="$1" key="$2" method="$3" path="$4" body="${5-}"
    http "$method" "$base$path" "$body" -H "X-Api-Key: $key" -H 'Content-Type: application/json'
}

# arr_key <app> -> prints the API key from the app's config.xml (waits for it)
arr_key() {
    local app="$1" cfg="/mnt/$CONFIG_POOL/configs/$1/config.xml"
    wait_for "$app to write config.xml" 180 bash -c "grep -q '<ApiKey>' '$cfg'" || return 1
    grep -oP '(?<=<ApiKey>)[^<]+' "$cfg" | head -1 | tr -d '[:space:]'
}

# arr_enable_forms_auth <app> <base-url> <api-key> <api-version>
# GET the host config, set Forms login (required for all addresses) and switch
# off "Send Anonymous Usage Data", PUT back. The *arr apps need the FULL
# object on PUT; a partial body 500s.
arr_enable_forms_auth() {
    local app="$1" base="$2" key="$3" ver="$4" cfg body
    cfg=$(arr_api "$base" "$key" GET "/api/$ver/config/host")
    http_ok || { todo "$app: could not read host config; enable Forms login in Settings > General."; return 1; }
    body=$(printf '%s' "$cfg" | python3 -c '
import json, os, sys
d = json.load(sys.stdin)
d.update(authenticationMethod="forms", authenticationRequired="enabled",
         username=os.environ["ADMIN_USER"], password=os.environ["ADMIN_PASS"],
         passwordConfirmation=os.environ["ADMIN_PASS"], analyticsEnabled=False)
print(json.dumps(d))')
    arr_api "$base" "$key" PUT "/api/$ver/config/host/1" "$body" >/dev/null
    if http_ok; then ok "$app: Forms login enabled ($ADMIN_USER / $ADMIN_PASS); anonymous usage data off"; else
        todo "$app: Forms login not applied (HTTP $(http_code)); set it in Settings > General."; fi
}

# arr_add_root_folder <app> <base-url> <api-key> <path>
arr_add_root_folder() {
    local app="$1" base="$2" key="$3" path="$4" existing
    existing=$(arr_api "$base" "$key" GET /api/v3/rootfolder | jpy "[r['path'] for r in d]")
    if [[ "$existing" == *"\"$path\""* ]]; then ok "$app: root folder $path already present"; return 0; fi
    arr_api "$base" "$key" POST /api/v3/rootfolder "{\"path\": \"$path\"}" >/dev/null
    if http_ok; then ok "$app: root folder $path added"; else
        todo "$app: could not add root folder $path (HTTP $(http_code)); add it in Settings > Media Management."; fi
}

# arr_errors — turn an *arr 400 body ([{propertyName, errorMessage}, ...])
# into one line for the messages; anything else is shown as-is, trimmed.
arr_errors() {
    printf '%s' "$1" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
    if isinstance(d, list) and d and isinstance(d[0], dict) and "errorMessage" in d[0]:
        print("; ".join("%s: %s" % (e.get("propertyName", ""), e.get("errorMessage", "")) for e in d)); sys.exit(0)
except Exception:
    pass
print(raw.strip()[:240])'
}

# qb_diagnose <app> — when <app> cannot talk to qBittorrent, show why: a reach
# probe and ONE login probe from inside the <app> container (qBittorrent bans
# an IP after 5 failed logins, so the login probe runs once per script run),
# plus the WebUI lines from qBittorrent's own log.
QB_LOGIN_PROBED=""
qb_diagnose() {
    local app="$1" out log
    if docker exec "$app" curl --version >/dev/null 2>&1; then
        out=$(docker exec "$app" curl -sS -m 10 -o /dev/null -w '%{http_code}' "$QB_INT/api/v2/app/webapiVersion" 2>&1 | tail -c 160)
        echo "    probe: GET $QB_INT/api/v2/app/webapiVersion from inside '$app' -> $out  (403 = reachable, login needed; 000 = unreachable)"
        if [ -z "$QB_LOGIN_PROBED" ]; then
            QB_LOGIN_PROBED=1
            out=$(docker exec "$app" curl -sS -m 10 -w ' [HTTP %{http_code}]' --data-urlencode "username=$ADMIN_USER" --data-urlencode "password=$ADMIN_PASS" "$QB_INT/api/v2/auth/login" 2>&1 | tail -c 160)
            echo "    probe: login as $ADMIN_USER from inside '$app' -> $out  (Ok. = good; Fails. = wrong password; 403 = IP banned for 1h)"
        fi
    else
        echo "    probe: no curl inside '$app'; cannot test the path to qBittorrent from there"
    fi
    log=$(find "/mnt/$CONFIG_POOL/configs/qbittorrent" -name 'qbittorrent.log' 2>/dev/null | head -1)
    if [ -n "$log" ]; then
        echo "    qBittorrent log, last WebUI lines:"
        grep -iE 'webui|webapi|banned|host header' "$log" | tail -5 | sed 's/^/      /'
    fi
}

# arr_add_qbittorrent <app> <base-url> <api-key> <category-field> <category>
# Builds the client from the app's own schema so field names stay correct.
# The *arr runs its connection test on save as well (forceSave only waives
# warnings), so a client whose test fails cannot be stored: the container
# name is tried first, then the TrueNAS LAN address through the published
# port as a fallback, and the real error is printed either way.
arr_add_qbittorrent() {
    local app="$1" base="$2" key="$3" cat_field="$4" category="$5" have schema body res host
    have=$(arr_api "$base" "$key" GET /api/v3/downloadclient | jpy "next((c for c in d if c['implementation']=='QBittorrent'), None)")
    if [ -n "$have" ]; then
        # Present from an earlier run: make sure "Remove Completed" is off.
        if [ "$(printf '%s' "$have" | jpy "d.get('removeCompletedDownloads')")" = "True" ]; then
            res=$(arr_api "$base" "$key" PUT "/api/v3/downloadclient/$(printf '%s' "$have" | jpy "d['id']")?forceSave=true" "$(printf '%s' "$have" | jpy "dict(d, removeCompletedDownloads=False)")")
            if http_ok; then ok "$app: qBittorrent download client already present; 'Remove Completed' switched off"; else
                warn "$app: could not switch 'Remove Completed' off (HTTP $(http_code)): $(arr_errors "$res")"; fi
        else
            ok "$app: qBittorrent download client already present"
        fi
        return 0
    fi
    schema=$(arr_api "$base" "$key" GET /api/v3/downloadclient/schema)
    for host in qbittorrent "$HOST_IP"; do
        body=$(printf '%s' "$schema" | QB_HOST="$host" CAT_FIELD="$cat_field" CATEGORY="$category" python3 -c '
import json, os, sys
t = next(x for x in json.load(sys.stdin) if x.get("implementation") == "QBittorrent")
vals = {"host": os.environ["QB_HOST"], "port": 8080, "useSsl": False, "urlBase": "",
        "username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PASS"],
        os.environ["CAT_FIELD"]: os.environ["CATEGORY"]}
for f in t["fields"]:
    if f["name"] in vals:
        f["value"] = vals[f["name"]]
# "Remove Completed" stays off: finished torrents keep seeding in qBittorrent
# (the Qui automations decide when they go); failed ones are still removed.
t.update(name="qBittorrent", enable=True, protocol="torrent", priority=1,
         removeCompletedDownloads=False, removeFailedDownloads=True, tags=[])
t.pop("id", None)
print(json.dumps(t))') || { todo "$app: qBittorrent not found in the download client schema."; return 1; }
        res=$(arr_api "$base" "$key" POST /api/v3/downloadclient/test "$body")
        http_ok && break
        warn "$app: qBittorrent connection test via '$host' failed (HTTP $(http_code)): $(arr_errors "$res")"
        [ "$host" = qbittorrent ] && qb_diagnose "$app"
        body=""
    done
    if [ -z "$body" ]; then
        todo "$app: qBittorrent download client not added: the connection test fails via the container name and via $HOST_IP (see the probes above). Add it in Settings > Download Clients once qBittorrent is reachable."
        return 1
    fi
    res=$(arr_api "$base" "$key" POST '/api/v3/downloadclient?forceSave=true' "$body")
    if http_ok; then
        ok "$app: qBittorrent download client added (host '$host', category '$category')"
        [ "$host" = qbittorrent ] || warn "$app: the container name 'qbittorrent' did not work from $app; the client uses the host address $host instead."
    else
        todo "$app: could not add the qBittorrent download client (HTTP $(http_code)): $(arr_errors "$res")"
    fi
}

# ── 1. qBittorrent ──────────────────────────────────────────────────────────
# The setup calls go to the WebUI from INSIDE the container (hotio's image
# ships curl), which works even while the VPN firewall is still settling; the
# published port is the fallback.
#
# Two traps, both hit on real runs:
#  * A login from loopback proves NOTHING about the password: with "bypass
#    authentication for clients on localhost" qBittorrent answers "Ok." to any
#    password. The login is therefore verified from the host through the
#    published port on every run (there the source is the Docker bridge and
#    the check is real) and set whenever that check fails.
#  * 5 failed logins ban the client IP for an hour (in memory). After the
#    password is (re)set the container is restarted once so Radarr, Sonarr
#    and Qui, which may have been banned by then, start clean.
QB_MODE="host"
# The cookie file must exist on the same filesystem curl runs on; /tmp is
# present both on the host and inside the container.
QB_COOKIE="/tmp/truenas-setup-qb.cookie"
qb_curl() {
    if [ "$QB_MODE" = "exec" ]; then docker exec qbittorrent curl -sS -m 30 "$@"
    else curl -sS -m 30 "$@"; fi
}
qb_up()    { [ "$(qb_curl -o /dev/null -w '%{http_code}' "$QB_URL/" 2>/dev/null)" = "200" ]; }
qb_login() { [ "$(qb_curl -c "$QB_COOKIE" --data-urlencode "username=$1" --data-urlencode "password=$2" "$QB_URL/api/v2/auth/login" 2>/dev/null)" = "Ok." ]; }
qb_post()  { qb_curl -b "$QB_COOKIE" "$@"; }   # qb_post <form args...> <url>
qb_code()  { qb_post -o /dev/null -w '%{http_code}' "$@" 2>/dev/null; }   # HTTP status of a logged-in call
# qb_login_from_host <user> <pass> -> "Ok." | "Fails." | "<error> [HTTP code]"
# A real credential check: the request enters through the published port.
qb_login_from_host() {
    curl -sS -m 15 -w ' [HTTP %{http_code}]' --data-urlencode "username=$1" --data-urlencode "password=$2" "$QB_URL/api/v2/auth/login" 2>&1 | tail -c 120
}
qb_pref() { printf '%s' "$1" | jpy "d.get('$2')"; }

configure_qbittorrent() {
    info "[1/10] qBittorrent"
    if docker exec qbittorrent curl --version >/dev/null 2>&1; then QB_MODE="exec"; fi
    # QB_URL is used both from inside the container and from the host; inside
    # the container localhost:8080 is the WebUI itself, so the same URL works.
    wait_for "qBittorrent WebUI (needs the VPN tunnel up)" 300 qb_up \
        || { todo "qBittorrent never came up. Check the VPN config: docker logs qbittorrent"; return 1; }

    # 1. A session for the setup calls (loopback; may be a bypass session).
    local tmp_pw
    if ! qb_login "$ADMIN_USER" "$ADMIN_PASS"; then
        tmp_pw=$(docker logs qbittorrent 2>&1 | grep -oP 'temporary password is provided for this session: \K\S+' | tail -1)
        [ -n "$tmp_pw" ] || { todo "qBittorrent: no temporary password in the logs and $ADMIN_USER/$ADMIN_PASS did not work; set the WebUI password manually."; return 1; }
        qb_login "admin" "$tmp_pw" || { todo "qBittorrent: login with the temporary password failed; set the WebUI password manually."; return 1; }
    fi
    local prefs
    prefs=$(qb_post "$QB_URL/api/v2/app/preferences" 2>/dev/null)
    echo "    qBittorrent WebUI settings: bypass_local_auth=$(qb_pref "$prefs" bypass_local_auth) host_header_validation=$(qb_pref "$prefs" web_ui_host_header_validation_enabled) csrf=$(qb_pref "$prefs" web_ui_csrf_protection_enabled) max_auth_fail=$(qb_pref "$prefs" web_ui_max_auth_fail_count) ban=$(qb_pref "$prefs" web_ui_ban_duration)s"

    # 2. Is the login already right? One attempt from the host (counts toward
    #    the host's 5-strike limit, so only one).
    local verify code
    verify=$(qb_login_from_host "$ADMIN_USER" "$ADMIN_PASS")
    if [[ "$verify" == Ok.* ]]; then
        ok "qBittorrent: WebUI login $ADMIN_USER / $ADMIN_PASS verified from outside the container"
    else
        echo "    qBittorrent: login from the host answered '$verify'; setting the WebUI login now."
        code=$(qb_code --data-urlencode "json=$(jbuild '{"web_ui_username": os.environ["ADMIN_USER"], "web_ui_password": os.environ["ADMIN_PASS"]}')" "$QB_URL/api/v2/app/setPreferences")
        [ "$code" = "200" ] || { todo "qBittorrent: setPreferences for the WebUI login returned HTTP $code; set $ADMIN_USER / $ADMIN_PASS in Tools > Options > WebUI."; return 1; }
        # 3. Restart: flushes the new login to disk and clears the in-memory
        #    IP bans earlier failed logins (Radarr, Sonarr, Qui, you) have
        #    collected. The VPN tunnel comes back on its own.
        sleep 5
        echo "    qBittorrent: restarting the container to clear login bans..."
        docker restart qbittorrent >/dev/null 2>&1
        wait_for "qBittorrent WebUI after the restart" 300 qb_up \
            || { todo "qBittorrent did not come back after the restart: docker logs qbittorrent"; return 1; }
        verify=$(qb_login_from_host "$ADMIN_USER" "$ADMIN_PASS")
        case "$verify" in
            Ok.*)    ok "qBittorrent: WebUI login set to $ADMIN_USER / $ADMIN_PASS (verified from outside the container)" ;;
            Fails.*) todo "qBittorrent: the WebUI still rejects $ADMIN_USER / $ADMIN_PASS from outside the container; set it in Tools > Options > WebUI. Radarr, Sonarr and Qui cannot log in until then."; return 1 ;;
            *)       todo "qBittorrent: port 8080 not reachable from the TrueNAS host ($verify); check VPN_LAN_NETWORK and: docker logs qbittorrent"; return 1 ;;
        esac
        qb_login "$ADMIN_USER" "$ADMIN_PASS" || { todo "qBittorrent: could not log back in after the restart; check the WebUI."; return 1; }
    fi

    # Save paths per wiki.serversatho.me/en/Folder-Structure: completed downloads
    # in /media/downloads (one subfolder per category via Automatic Torrent
    # Management), incomplete ones and .torrent files in /media/downloads/torrent.
    code=$(qb_code --data-urlencode 'json={"save_path":"/media/downloads","temp_path_enabled":true,"temp_path":"/media/downloads/torrent","export_dir":"/media/downloads/torrent","auto_tmm_enabled":true,"torrent_content_layout":"Original"}' \
        "$QB_URL/api/v2/app/setPreferences")
    if [ "$code" = "200" ]; then ok "qBittorrent: save paths set (/media/downloads, incomplete in /media/downloads/torrent)"; else
        todo "qBittorrent: could not set the save paths (HTTP $code); set them in Tools > Options > Downloads."; fi

    # Connection / BitTorrent / Advanced per wiki.serversatho.me/en/qBittorrent:
    # no connection limits (-1 = box unchecked), no torrent queueing, more
    # parallel checking, and all torrent traffic bound to the VPN interface
    # on every IPv4 address.
    code=$(qb_code --data-urlencode 'json={"max_connec":-1,"max_connec_per_torrent":-1,"max_uploads":-1,"max_uploads_per_torrent":-1,"queueing_enabled":false,"max_active_checking_torrents":3,"current_network_interface":"wg0","current_interface_address":"0.0.0.0"}' \
        "$QB_URL/api/v2/app/setPreferences")
    if [ "$code" = "200" ]; then ok "qBittorrent: connection limits off, queueing off, 3 checking torrents, interface wg0 / all IPv4"; else
        todo "qBittorrent: could not apply the connection/advanced settings (HTTP $code); set them in Tools > Options."; fi

    local cat
    for cat in radarr sonarr; do
        code=$(qb_code --data-urlencode "category=$cat" --data-urlencode "savePath=/media/downloads/$cat" "$QB_URL/api/v2/torrents/createCategory")
        case "$code" in
            200) ok "qBittorrent: category '$cat' -> /media/downloads/$cat" ;;
            409) ok "qBittorrent: category '$cat' already exists" ;;
            *)   warn "qBittorrent: could not create category '$cat' (HTTP $code)" ;;
        esac
    done
    [ "$QB_MODE" = "exec" ] && docker exec qbittorrent rm -f "$QB_COOKIE" >/dev/null 2>&1
    rm -f "$QB_COOKIE"
}

# ── 2/3. Radarr and Sonarr ──────────────────────────────────────────────────
configure_radarr() {
    info "[2/10] Radarr"
    RADARR_API_KEY=$(arr_key radarr) || { todo "Radarr: config.xml never appeared; skipping."; return 1; }
    wait_for "Radarr API" 180 bash -c "curl -fs -H 'X-Api-Key: $RADARR_API_KEY' $RADARR_URL/api/v3/system/status -o /dev/null" \
        || { todo "Radarr API not responding; skipping."; return 1; }
    arr_enable_forms_auth Radarr "$RADARR_URL" "$RADARR_API_KEY" v3
    arr_add_root_folder   Radarr "$RADARR_URL" "$RADARR_API_KEY" /media/movies
    arr_add_qbittorrent   Radarr "$RADARR_URL" "$RADARR_API_KEY" movieCategory radarr
}

configure_sonarr() {
    info "[3/10] Sonarr"
    SONARR_API_KEY=$(arr_key sonarr) || { todo "Sonarr: config.xml never appeared; skipping."; return 1; }
    wait_for "Sonarr API" 180 bash -c "curl -fs -H 'X-Api-Key: $SONARR_API_KEY' $SONARR_URL/api/v3/system/status -o /dev/null" \
        || { todo "Sonarr API not responding; skipping."; return 1; }
    arr_enable_forms_auth Sonarr "$SONARR_URL" "$SONARR_API_KEY" v3
    arr_add_root_folder   Sonarr "$SONARR_URL" "$SONARR_API_KEY" /media/tv
    arr_add_qbittorrent   Sonarr "$SONARR_URL" "$SONARR_API_KEY" tvCategory sonarr
}

# ── 4. FlareSolverr ─────────────────────────────────────────────────────────
configure_flaresolverr() {
    info "[4/10] FlareSolverr"
    if wait_for "FlareSolverr" 120 bash -c "curl -fs $FLARE_URL/ -o /dev/null"; then ok "FlareSolverr is up (nothing to configure)"
    else todo "FlareSolverr did not respond on :8191; Prowlarr's proxy test may fail."; fi
}

# ── 5. Prowlarr ─────────────────────────────────────────────────────────────
prowlarr_tag_id() {  # prowlarr_tag_id <label> -> id (creates it if missing)
    local id
    id=$(arr_api "$PROWLARR_URL" "$PROWLARR_API_KEY" GET /api/v1/tag | jpy "next((t['id'] for t in d if t['label']=='$1'), None)")
    [ -n "$id" ] && { echo "$id"; return 0; }
    arr_api "$PROWLARR_URL" "$PROWLARR_API_KEY" POST /api/v1/tag "{\"label\": \"$1\"}" | jpy "d['id']"
}

prowlarr_add_app() {  # prowlarr_add_app <Radarr|Sonarr> <internal-url> <api-key>
    local impl="$1" url="$2" key="$3" have body
    have=$(arr_api "$PROWLARR_URL" "$PROWLARR_API_KEY" GET /api/v1/applications | jpy "[a['implementation'] for a in d]")
    if [[ "$have" == *"\"$impl\""* ]]; then ok "Prowlarr: $impl app already present"; return 0; fi
    body=$(arr_api "$PROWLARR_URL" "$PROWLARR_API_KEY" GET /api/v1/applications/schema \
        | IMPL="$impl" APP_URL="$url" APP_KEY="$key" PROWLARR_INT="$PROWLARR_INT" python3 -c '
import json, os, sys
t = next(x for x in json.load(sys.stdin) if x.get("implementation") == os.environ["IMPL"])
vals = {"prowlarrUrl": os.environ["PROWLARR_INT"], "baseUrl": os.environ["APP_URL"], "apiKey": os.environ["APP_KEY"]}
for f in t["fields"]:
    if f["name"] in vals:
        f["value"] = vals[f["name"]]
t.update(name=os.environ["IMPL"], syncLevel="fullSync", tags=[])
t.pop("id", None)
print(json.dumps(t))') || { todo "Prowlarr: $impl not in the applications schema."; return 1; }
    arr_api "$PROWLARR_URL" "$PROWLARR_API_KEY" POST /api/v1/applications/test "$body" >/dev/null
    http_ok || warn "Prowlarr: $impl connection test failed (HTTP $(http_code)); saving anyway."
    arr_api "$PROWLARR_URL" "$PROWLARR_API_KEY" POST '/api/v1/applications?forceSave=true' "$body" >/dev/null
    if http_ok; then ok "Prowlarr: $impl app added (full sync)"; else todo "Prowlarr: could not add $impl (HTTP $(http_code))."; fi
}

configure_prowlarr() {
    info "[5/10] Prowlarr"
    PROWLARR_API_KEY=$(arr_key prowlarr) || { todo "Prowlarr: config.xml never appeared; skipping."; return 1; }
    wait_for "Prowlarr API" 180 bash -c "curl -fs -H 'X-Api-Key: $PROWLARR_API_KEY' $PROWLARR_URL/api/v1/system/status -o /dev/null" \
        || { todo "Prowlarr API not responding; skipping."; return 1; }
    arr_enable_forms_auth Prowlarr "$PROWLARR_URL" "$PROWLARR_API_KEY" v1

    # FlareSolverr as an indexer proxy, applied to indexers tagged "flaresolverr".
    local have tag_id body
    have=$(arr_api "$PROWLARR_URL" "$PROWLARR_API_KEY" GET /api/v1/indexerproxy | jpy "[p['implementation'] for p in d]")
    if [[ "$have" == *'"FlareSolverr"'* ]]; then ok "Prowlarr: FlareSolverr proxy already present"; else
        tag_id=$(prowlarr_tag_id flaresolverr)
        body=$(arr_api "$PROWLARR_URL" "$PROWLARR_API_KEY" GET /api/v1/indexerproxy/schema \
            | TAG_ID="${tag_id:-0}" FLARE_INT="$FLARE_INT" python3 -c '
import json, os, sys
t = next(x for x in json.load(sys.stdin) if x.get("implementation") == "FlareSolverr")
for f in t["fields"]:
    if f["name"] == "host": f["value"] = os.environ["FLARE_INT"]
    if f["name"] == "requestTimeout": f["value"] = 60
t.update(name="FlareSolverr", tags=[int(os.environ["TAG_ID"])] if int(os.environ["TAG_ID"]) else [])
t.pop("id", None)
print(json.dumps(t))')
        arr_api "$PROWLARR_URL" "$PROWLARR_API_KEY" POST '/api/v1/indexerproxy?forceSave=true' "$body" >/dev/null
        if http_ok; then ok "Prowlarr: FlareSolverr proxy added (tag 'flaresolverr')"; else todo "Prowlarr: could not add the FlareSolverr proxy (HTTP $(http_code))."; fi
    fi

    [ -n "$RADARR_API_KEY" ] && prowlarr_add_app Radarr "$RADARR_INT" "$RADARR_API_KEY"
    [ -n "$SONARR_API_KEY" ] && prowlarr_add_app Sonarr "$SONARR_INT" "$SONARR_API_KEY"
    echo "    Prowlarr has no indexers yet: add your trackers in Indexers > Add Indexer (tag Cloudflare-protected ones 'flaresolverr')."
}

# ── 6. Profilarr ────────────────────────────────────────────────────────────
# Profilarr v2 is a SvelteKit app: account creation and Arr linking are form
# actions (urlencoded POSTs that answer 303 on success), protected by a session
# cookie and SvelteKit's Origin check. The default Dictionarry database is
# linked automatically on first boot.
PROFILARR_COOKIE="$COOKIE_DIR/profilarr.cookie"
profilarr_form() {  # profilarr_form <path> <form args...> -> prints HTTP code; body kept for diagnostics
    local path="$1"; shift
    curl -sS -m 60 -o "$COOKIE_DIR/profilarr.body" -w '%{http_code}' -b "$PROFILARR_COOKIE" -c "$PROFILARR_COOKIE" \
        -H "Origin: $PROFILARR_URL" -H 'Accept: text/html' "$@" "$PROFILARR_URL$path"
}
profilarr_body_hint() {  # first bit of the last response, tags stripped, for error messages
    sed 's/<[^>]*>/ /g' "$COOKIE_DIR/profilarr.body" 2>/dev/null | tr -s '[:space:]' ' ' | cut -c1-240
}
profilarr_needs_setup() {  # true while Profilarr still redirects to its first-run page
    [[ "$(curl -sS -m 30 -o /dev/null -w '%{redirect_url}' "$PROFILARR_URL/")" == *"/auth/setup"* ]]
}
profilarr_logged_in() {  # the session cookie is accepted by the API
    [ "$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -b "$PROFILARR_COOKIE" "$PROFILARR_URL/api/v1/arr")" = "200" ]
}

configure_profilarr() {
    info "[6/10] Profilarr"
    wait_for "Profilarr" 180 bash -c "curl -fs $PROFILARR_URL/api/v1/health -o /dev/null" \
        || { todo "Profilarr did not come up; skipping."; return 1; }
    local code
    if profilarr_needs_setup; then
        code=$(profilarr_form /auth/setup --data-urlencode "username=$ADMIN_USER" --data-urlencode "password=$ADMIN_PASS" --data-urlencode "confirmPassword=$ADMIN_PASS")
        # Judge by state, not only by status: a 303 is the documented success,
        # but the account may exist even if the form answered differently.
        if profilarr_needs_setup; then
            todo "Profilarr: account setup returned HTTP $code ($(profilarr_body_hint)); finish it at $PROFILARR_URL."
            return 1
        fi
        ok "Profilarr: account created ($ADMIN_USER / $ADMIN_PASS) [HTTP $code]"
    fi
    if ! profilarr_logged_in; then
        code=$(profilarr_form /auth/login --data-urlencode "username=$ADMIN_USER" --data-urlencode "password=$ADMIN_PASS")
        profilarr_logged_in && ok "Profilarr: logged in" \
            || { todo "Profilarr: login returned HTTP $code ($(profilarr_body_hint)); link Radarr/Sonarr in the UI."; return 1; }
    fi
    local app url key linked
    for app in radarr sonarr; do
        if [ "$app" = radarr ]; then url="$RADARR_INT"; key="$RADARR_API_KEY"; else url="$SONARR_INT"; key="$SONARR_API_KEY"; fi
        [ -n "$key" ] || { todo "Profilarr: no $app API key; link it in the UI."; continue; }
        linked=$(http GET "$PROFILARR_URL/api/v1/arr" "" -b "$PROFILARR_COOKIE" | jpy "[a['name'] for a in d]")
        if [[ "$linked" == *"\"${app^}\""* ]]; then ok "Profilarr: ${app^} already linked"; continue; fi
        code=$(profilarr_form /arr/new --data-urlencode "name=${app^}" --data-urlencode "type=$app" --data-urlencode "url=$url" --data-urlencode "api_key=$key")
        linked=$(http GET "$PROFILARR_URL/api/v1/arr" "" -b "$PROFILARR_COOKIE" | jpy "[a['name'] for a in d]")
        if [[ "$linked" == *"\"${app^}\""* ]]; then ok "Profilarr: ${app^} linked ($url) [HTTP $code]"
        else todo "Profilarr: linking ${app^} returned HTTP $code ($(profilarr_body_hint)); add it under Arrs."; fi
    done
    profilarr_sync_all
}

# profilarr_action <instance-id> <action> <form args...> -> prints JSON result; status via http_code
# SvelteKit form action, called the way the UI's JS does (x-sveltekit-action)
# so the answer is JSON ({"type":"success"|"failure"|...}) instead of HTML.
# Form actions insist on a form-encoded body ("Form actions expect
# form-encoded data", HTTP 415 otherwise), so even a no-argument action such
# as syncQualityProfiles sends an empty urlencoded body.
profilarr_post() {  # profilarr_post <path?/action> <form args...>
    local path="$1"; shift
    [ $# -gt 0 ] || set -- --data-raw ''
    http POST "$PROFILARR_URL$path" "" -b "$PROFILARR_COOKIE" -c "$PROFILARR_COOKIE" \
        -H "Origin: $PROFILARR_URL" -H 'x-sveltekit-action: true' \
        -H 'Content-Type: application/x-www-form-urlencoded' "$@"
}
profilarr_action() {
    local id="$1" action="$2"; shift 2
    profilarr_post "/arr/$id/sync?/$action" "$@"
}
# profilarr_automation <instance-name> <what> <path?/action> <form args...>
# Saves one of the per-Arr automations (drift detection, renames, cleanup)
# and reports the outcome; the JSON answer carries "type":"success"|"failure".
profilarr_automation() {
    local name="$1" what="$2" path="$3" res; shift 3
    res=$(profilarr_post "$path" "$@")
    if http_ok && [[ "$res" == *'"type":"success"'* ]]; then ok "Profilarr: $name $what enabled"
    else warn "Profilarr: could not enable $what for $name (HTTP $(http_code)): $(printf '%s' "$res" | head -c 160)"; fi
}

# profilarr_sync_wait <instance-name> <section>  (section: qualityProfiles|delayProfiles|mediaManagement)
profilarr_sync_wait() {
    local name="$1" section="$2" waited=0 st
    while :; do
        st=$(http GET "$PROFILARR_URL/api/v1/status" "" -b "$PROFILARR_COOKIE" | NAME="$name" SECTION="$section" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
for a in d.get("arrs", []):
    if str(a.get("name")) == os.environ["NAME"] or str(a.get("id")) == os.environ["NAME"]:
        print((a.get("sync") or {}).get(os.environ["SECTION"], {}).get("status", "unknown")); break
else:
    print("unknown")' 2>/dev/null)
        case "$st" in
            idle)    return 0 ;;
            failed)  return 1 ;;
            unknown) return 2 ;;
        esac
        sleep 5; waited=$(( waited + 5 ))
        [ "$waited" -ge 600 ] && return 3
    done
}

# Sync everything from the auto-linked Dictionarry database to one Arr:
# all quality profiles (their custom formats come along), the first delay
# profile, and the first naming / quality-definition / media-settings configs.
profilarr_instance_id() {  # profilarr_instance_id <Radarr|Sonarr> -> id ("" if not linked)
    http GET "$PROFILARR_URL/api/v1/arr" "" -b "$PROFILARR_COOKIE" | jpy "next((a['id'] for a in d if a['name']=='$1'), None)"
}

profilarr_sync_instance() {  # profilarr_sync_instance <Radarr|Sonarr>
    local name="$1" id lists res
    id=$(profilarr_instance_id "$name")
    [ -n "$id" ] || { todo "Profilarr: $name is not linked; sync it in the UI."; return 1; }

    # The profile/config names live only in the sync page's load data
    # (SvelteKit __data.json, devalue-encoded). Decode it generically.
    lists=$(http GET "$PROFILARR_URL/arr/$id/sync/__data.json" "" -b "$PROFILARR_COOKIE" | NAME="$name" python3 -c '
import json, os, sys
raw = json.load(sys.stdin)
SPECIAL = {-1: None, -2: None, -3: float("nan"), -4: float("inf"), -5: float("-inf"), -6: -0.0}
def hydrate(values, i, memo):
    if i in SPECIAL: return SPECIAL[i]
    if i in memo: return memo[i]
    v = values[i]
    if isinstance(v, list):
        if v and isinstance(v[0], str) and v[0] in ("Date","Set","Map","RegExp","Object","BigInt","null","Symbol") and len(v) >= 1:
            out = [hydrate(values, j, memo) for j in v[1:]] if v[0] in ("Set","Map","Object") else v[1:]
        else:
            out = [hydrate(values, j, memo) for j in v]
    elif isinstance(v, dict):
        out = {k: hydrate(values, j, memo) for k, j in v.items()}
    else:
        out = v
    memo[i] = out
    return out
found = None
for node in raw.get("nodes") or []:
    if not node or node.get("type") != "data": continue
    data = hydrate(node["data"], 0, {})
    if isinstance(data, dict) and isinstance(data.get("databases"), list):
        found = data["databases"]
if not found: sys.exit(1)
db = found[0]
names = lambda key: [x["name"] for x in (db.get(key) or []) if isinstance(x, dict) and x.get("name")]
# The database ships one delay/naming/etc. config per app ("Radarr", "Sonarr").
# Prefer the one named after this instance; fall back to the first listed.
app = os.environ["NAME"].lower()
def pick(key):
    xs = names(key)
    return next((n for n in xs if app in n.lower()), xs[0] if xs else "")
print(json.dumps({"dbId": db["id"], "db": db.get("name"), "qp": names("qualityProfiles"), "dp": pick("delayProfiles"),
                  "naming": pick("namingConfigs"), "qdef": pick("qualityDefinitionsConfigs"), "media": pick("mediaSettingsConfigs")}))' 2>/dev/null)
    [ -n "$lists" ] || { todo "Profilarr: could not read the Dictionarry profile list for $name; pick profiles under Arrs > $name > Sync."; return 1; }
    local db_id qp_sel dp_name naming qdef media
    db_id=$(printf '%s' "$lists" | jpy "d['dbId']")
    qp_sel=$(printf '%s' "$lists" | jpy "[{'databaseId': d['dbId'], 'profileName': n} for n in d['qp']]")
    dp_name=$(printf '%s' "$lists" | jpy "d['dp']")
    naming=$(printf '%s' "$lists" | jpy "d['naming']")
    qdef=$(printf '%s' "$lists" | jpy "d['qdef']")
    media=$(printf '%s' "$lists" | jpy "d['media']")
    echo "    Profilarr/$name: $(printf '%s' "$lists" | jpy "len(d['qp'])") quality profiles from '$(printf '%s' "$lists" | jpy "d['db']")', delay '$dp_name', naming '$naming', quality defs '$qdef', media settings '$media'"

    # Save selections (scheduled daily at 04:00 so later database updates flow through).
    profilarr_action "$id" saveQualityProfiles --data-urlencode "selections=$qp_sel" --data-urlencode 'priorities=[]' \
        --data-urlencode 'trigger=schedule' --data-urlencode 'cron=0 4 * * *' >/dev/null
    http_ok || { todo "Profilarr: saving quality profiles for $name failed (HTTP $(http_code))."; return 1; }
    if [ -n "$dp_name" ]; then
        profilarr_action "$id" saveDelayProfiles --data-urlencode "databaseId=$db_id" --data-urlencode "profileName=$dp_name" \
            --data-urlencode 'trigger=schedule' --data-urlencode 'cron=0 4 * * *' >/dev/null
        http_ok || warn "Profilarr: saving the delay profile for $name failed (HTTP $(http_code))"
    fi
    profilarr_action "$id" saveMediaManagement \
        --data-urlencode "namingDatabaseId=${naming:+$db_id}" --data-urlencode "namingConfigName=$naming" \
        --data-urlencode "qualityDefinitionsDatabaseId=${qdef:+$db_id}" --data-urlencode "qualityDefinitionsConfigName=$qdef" \
        --data-urlencode "mediaSettingsDatabaseId=${media:+$db_id}" --data-urlencode "mediaSettingsConfigName=$media" \
        --data-urlencode 'trigger=schedule' --data-urlencode 'cron=0 4 * * *' >/dev/null
    http_ok || warn "Profilarr: saving media management for $name failed (HTTP $(http_code))"

    # Run each sync now and wait; quality profiles must finish before Seerr
    # picks a profile later.
    local section sec
    for section in syncQualityProfiles syncDelayProfiles syncMediaManagement; do
        res=$(profilarr_action "$id" "$section")
        if ! http_ok; then warn "Profilarr: $section for $name returned HTTP $(http_code): $(printf '%s' "$res" | head -c 200)"; continue; fi
        # The status API spells the sections qualityProfiles / delayProfiles /
        # mediaManagement (lower-case first letter), and reports
        # idle | pending | in_progress | failed.
        sec="${section#sync}"; sec="${sec,}"
        case $(profilarr_sync_wait "$name" "$sec" ; echo $?) in
            0) ok "Profilarr: $name $sec synced" ;;
            1) todo "Profilarr: $name $sec sync FAILED; check Arrs > $name in the UI." ;;
            2) warn "Profilarr: $name $sec queued (status not readable; check the UI)" ;;
            *) warn "Profilarr: $name $sec still running after 10 min; carrying on" ;;
        esac
    done
}

# Per-Arr automations (wiki sections 4.3 and 4.5), all switched on: drift
# detection daily after the 04:00 sync, renames (files and folders) daily
# after that, cleanup weekly. Each page's `save` upserts, so re-runs are safe.
profilarr_enable_automations() {  # profilarr_enable_automations <Radarr|Sonarr>
    local name="$1" id
    id=$(profilarr_instance_id "$name")
    [ -n "$id" ] || return 1
    profilarr_automation "$name" "drift detection" "/arr/$id/drift?/save" \
        --data-urlencode 'enabled=true' --data-urlencode 'cron=0 5 * * *'
    profilarr_automation "$name" "renames" "/arr/$id/rename?/save" \
        --data-urlencode 'enabled=true' --data-urlencode 'renameFolders=true' --data-urlencode 'ignoreTag=' \
        --data-urlencode 'cron=0 6 * * *' --data-urlencode 'summaryNotifications=false'
    profilarr_automation "$name" "cleanup" "/arr/$id/settings?/updateCleanup" \
        --data-urlencode 'enabled=1' --data-urlencode 'cron=0 0 * * 0'
    # First cleanup pass right away (queued as a job; Profilarr runs it).
    local res
    res=$(profilarr_post "/arr/$id/settings?/runCleanupNow")
    if http_ok && [[ "$res" == *'"type":"success"'* ]]; then ok "Profilarr: $name cleanup run queued"
    else warn "Profilarr: could not queue a cleanup run for $name (HTTP $(http_code)): $(printf '%s' "$res" | head -c 160)"; fi
}

profilarr_sync_all() {
    local app
    for app in Radarr Sonarr; do
        profilarr_sync_instance "$app"
        profilarr_enable_automations "$app"
    done
}

# ── 7. Jellyfin ─────────────────────────────────────────────────────────────
JF_AUTH='MediaBrowser Client="truenas-setup", Device="truenas", DeviceId="truenas-setup-script", Version="1.0.0"'
jf_api() {  # jf_api <method> <path> [json] [extra curl args]
    local method="$1" path="$2" body="${3-}"; shift $(( $# < 3 ? $# : 3 ))
    local auth="$JF_AUTH"; [ -n "$JELLYFIN_TOKEN" ] && auth="$JF_AUTH, Token=\"$JELLYFIN_TOKEN\""
    http "$method" "$JELLYFIN_URL$path" "$body" -H "Authorization: $auth" -H 'Content-Type: application/json' "$@"
}

jf_add_library() {  # jf_add_library <name> <collectionType> <path>
    local name="$1" ctype="$2" path="$3" have
    have=$(jf_api GET /Library/VirtualFolders | jpy "[v['Name'] for v in d]")
    if [[ "$have" == *"\"$name\""* ]]; then ok "Jellyfin: library '$name' already present"; return 0; fi
    jf_api POST "/Library/VirtualFolders?name=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$name")&collectionType=$ctype&refreshLibrary=true" \
        "{\"LibraryOptions\": {\"PathInfos\": [{\"Path\": \"$path\"}]}}" >/dev/null
    if http_ok; then ok "Jellyfin: library '$name' -> $path"; else todo "Jellyfin: could not add library '$name' (HTTP $(http_code))."; fi
}

configure_jellyfin() {
    info "[7/10] Jellyfin"
    wait_for "Jellyfin" 180 bash -c "curl -fs $JELLYFIN_URL/System/Info/Public -o /dev/null" \
        || { todo "Jellyfin did not come up; skipping."; return 1; }
    local done_flag
    done_flag=$(http GET "$JELLYFIN_URL/System/Info/Public" | jpy "d.get('StartupWizardCompleted')")
    if [ "$done_flag" != "True" ]; then
        # The wizard endpoints need no auth until /Startup/Complete is called.
        jf_api POST /Startup/Configuration '{"ServerName":"Jellyfin","UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null
        jf_api GET  /Startup/User >/dev/null
        jf_api POST /Startup/User "$(jbuild '{"Name": os.environ["ADMIN_USER"], "Password": os.environ["ADMIN_PASS"]}')" >/dev/null
        http_ok || todo "Jellyfin: could not set the admin user (HTTP $(http_code))."
        jf_api POST /Startup/RemoteAccess '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null
        jf_api POST /Startup/Complete >/dev/null
        http_ok && ok "Jellyfin: setup wizard completed (admin $ADMIN_USER / $ADMIN_PASS)" \
                || todo "Jellyfin: wizard completion returned HTTP $(http_code); finish it at $JELLYFIN_URL."
    else
        ok "Jellyfin: setup wizard already completed"
    fi
    JELLYFIN_TOKEN=$(jf_api POST /Users/AuthenticateByName "$(jbuild '{"Username": os.environ["ADMIN_USER"], "Pw": os.environ["ADMIN_PASS"]}')" | jpy "d['AccessToken']")
    [ -n "$JELLYFIN_TOKEN" ] || { todo "Jellyfin: could not log in as $ADMIN_USER; add the Movies and TV libraries in the UI."; return 1; }
    jf_add_library "Movies"   movies  /media/movies
    jf_add_library "TV Shows" tvshows /media/tv
}

# ── 8. Seerr ────────────────────────────────────────────────────────────────
SEERR_COOKIE="$COOKIE_DIR/seerr.cookie"
seerr_api() {  # seerr_api <method> <path> [json]
    http "$1" "$SEERR_URL$2" "${3-}" -b "$SEERR_COOKIE" -c "$SEERR_COOKIE" -H 'Content-Type: application/json'
}

# seerr_add_arr <radarr|sonarr> <internal-host> <port> <api-key> <root>
# Quality profile: "1080p Balanced" from Profilarr/Dictionarry, else any other
# synced 1080p profile, else the stock HD-1080p. An entry that already exists
# but still sits on a stock profile (Seerr configured before the Profilarr
# sync had landed) is updated in place.
SEERR_STOCK_PROFILES="{'Any', 'SD', 'HD-720p', 'HD-1080p', 'Ultra-HD', 'HD - 720p/1080p'}"
seerr_add_arr() {
    local app="$1" host="$2" port="$3" key="$4" root="$5" existing cur_profile test body id
    existing=$(seerr_api GET "/api/v1/settings/$app" | jpy "next((s for s in d if s['hostname']=='$host'), None)")
    if [ -n "$existing" ]; then
        cur_profile=$(printf '%s' "$existing" | jpy "d.get('activeProfileName')")
        if [ "$(printf '%s' "$existing" | jpy "d.get('activeProfileName') in $SEERR_STOCK_PROFILES")" != "True" ]; then
            ok "Seerr: ${app^} already configured (profile '$cur_profile')"; return 0
        fi
        echo "    Seerr: ${app^} is on the stock profile '$cur_profile'; looking for a Profilarr profile..."
    fi
    test=$(seerr_api POST "/api/v1/settings/$app/test" "$(APP_HOST="$host" APP_PORT="$port" APP_KEY="$key" jbuild '{"hostname": os.environ["APP_HOST"], "port": int(os.environ["APP_PORT"]), "apiKey": os.environ["APP_KEY"], "useSsl": False, "baseUrl": ""}')")
    http_ok || { todo "Seerr: could not reach ${app^} for its profile list (HTTP $(http_code)); add it in Settings > Services."; return 1; }
    body=$(printf '%s' "$test" | APP="$app" APP_HOST="$host" APP_PORT="$port" APP_KEY="$key" WANT_ROOT="$root" EXISTING="$existing" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
stock = {"Any", "SD", "HD-720p", "HD-1080p", "Ultra-HD", "HD - 720p/1080p"}
profiles = d.get("profiles") or []
pick = (next((p for p in profiles if p["name"] == "1080p Balanced"), None)
        or next((p for p in profiles if "1080" in p["name"] and p["name"] not in stock), None)
        or next((p for p in profiles if p["name"] == "HD-1080p"), None)
        or (profiles[0] if profiles else None))
if not pick:
    sys.exit("no quality profiles")
roots = [r["path"] for r in (d.get("rootFolders") or [])]
root = os.environ["WANT_ROOT"] if os.environ["WANT_ROOT"] in roots else (roots[0] if roots else os.environ["WANT_ROOT"])
if os.environ["EXISTING"]:
    body = json.loads(os.environ["EXISTING"])
    body.update(activeProfileId=pick["id"], activeProfileName=pick["name"])
else:
    body = {"name": os.environ["APP"].capitalize(), "hostname": os.environ["APP_HOST"], "port": int(os.environ["APP_PORT"]),
            "apiKey": os.environ["APP_KEY"], "useSsl": False, "baseUrl": "", "activeProfileId": pick["id"],
            "activeProfileName": pick["name"], "activeDirectory": root, "is4k": False, "tags": [], "isDefault": True,
            "externalUrl": "", "syncEnabled": True, "preventSearch": False, "tagRequests": False}
    if os.environ["APP"] == "radarr":
        body["minimumAvailability"] = "released"
    else:
        body.update(enableSeasonFolders=True, seriesType="standard", animeSeriesType="anime", animeTags=[], monitorNewItems="all")
print(json.dumps(body)); print(pick["name"], file=sys.stderr)' 2>"$COOKIE_DIR/profile.txt") \
        || { todo "Seerr: ${app^} has no quality profiles yet; add it in Settings > Services."; return 1; }
    local picked; picked=$(cat "$COOKIE_DIR/profile.txt")
    if [ -n "$existing" ]; then
        if [ "$picked" = "$cur_profile" ]; then
            warn "Seerr: ${app^} has no Profilarr profile yet (sync not finished?); staying on '$cur_profile'. Re-run after the sync."
            return 0
        fi
        id=$(printf '%s' "$existing" | jpy "d['id']")
        seerr_api PUT "/api/v1/settings/$app/$id" "$body" >/dev/null
        if http_ok; then ok "Seerr: ${app^} profile changed to '$picked'"; else todo "Seerr: could not update ${app^} (HTTP $(http_code)); pick '$picked' in Settings > Services."; fi
        return 0
    fi
    seerr_api POST "/api/v1/settings/$app" "$body" >/dev/null
    if http_ok; then
        ok "Seerr: ${app^} added (profile '$picked', root $root)"
        [[ "$picked" == "1080p Balanced" ]] || warn "Seerr: '1080p Balanced' not found in ${app^} (Profilarr sync not finished?); using '$picked'. Re-run after the sync to switch."
    else
        todo "Seerr: could not add ${app^} (HTTP $(http_code))."; fi
}

configure_seerr() {
    info "[8/10] Seerr"
    wait_for "Seerr" 180 bash -c "curl -fs $SEERR_URL/api/v1/status -o /dev/null" \
        || { todo "Seerr did not come up; skipping."; return 1; }
    local initialized
    initialized=$(http GET "$SEERR_URL/api/v1/settings/public" | jpy "d.get('initialized')")
    if [ "$initialized" = "True" ]; then
        seerr_api POST /api/v1/auth/jellyfin "$(jbuild '{"username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PASS"]}')" >/dev/null
        http_ok && ok "Seerr: already initialized; logged in" || { todo "Seerr: already initialized but login failed (HTTP $(http_code))."; return 1; }
    else
        # First admin = the Jellyfin admin; serverType 2 = Jellyfin.
        seerr_api POST /api/v1/auth/jellyfin "$(jbuild '{"username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PASS"], "hostname": "jellyfin", "port": 8096, "useSsl": False, "urlBase": "", "email": os.environ["ADMIN_EMAIL"], "serverType": 2}')" >/dev/null
        http_ok && ok "Seerr: connected to Jellyfin as $ADMIN_USER" \
                || { todo "Seerr: Jellyfin sign-in failed (HTTP $(http_code)); finish setup at $SEERR_URL."; return 1; }
    fi
    local libs id
    libs=$(seerr_api POST /api/v1/settings/jellyfin/library/sync)
    for id in $(printf '%s' "$libs" | jpy "' '.join(l['id'] for l in d)"); do
        seerr_api PUT "/api/v1/settings/jellyfin/library/$id" '{"enabled": true}' >/dev/null
    done
    ok "Seerr: Jellyfin libraries synced and enabled"
    seerr_api POST /api/v1/settings/jellyfin/sync '{"start": true}' >/dev/null
    [ -n "$RADARR_API_KEY" ] && seerr_add_arr radarr radarr 7878 "$RADARR_API_KEY" /media/movies
    [ -n "$SONARR_API_KEY" ] && seerr_add_arr sonarr sonarr 8989 "$SONARR_API_KEY" /media/tv
    if [ "$initialized" != "True" ]; then
        seerr_api POST /api/v1/settings/main '{"locale": "en"}' >/dev/null
        seerr_api POST /api/v1/settings/initialize >/dev/null
        http_ok && ok "Seerr: setup marked complete" || todo "Seerr: could not mark setup complete (HTTP $(http_code))."
    fi
}

# ── 9. Bazarr (connect to Radarr/Sonarr only; languages and providers in UI) ─
configure_bazarr() {
    info "[9/10] Bazarr"
    local cfg="/mnt/$CONFIG_POOL/configs/bazarr/config/config.yaml"
    wait_for "Bazarr to write config.yaml" 180 bash -c "grep -qE '^\s*apikey:' '$cfg'" \
        || { todo "Bazarr: config.yaml never appeared; connect Radarr/Sonarr in Settings."; return 1; }
    BAZARR_API_KEY=$(grep -m1 -E '^\s*apikey:' "$cfg" | awk '{print $2}' | tr -d '"'"'")
    wait_for "Bazarr API" 180 bash -c "curl -fs -H 'X-API-KEY: $BAZARR_API_KEY' $BAZARR_URL/api/system/status -o /dev/null" \
        || { todo "Bazarr API not responding; skipping."; return 1; }
    [ -n "$RADARR_API_KEY" ] && [ -n "$SONARR_API_KEY" ] \
        || { todo "Bazarr: missing a Radarr/Sonarr API key; connect them in Settings."; return 1; }
    local code
    code=$(curl -sS -m 60 -o /dev/null -w '%{http_code}' -X POST -H "X-API-KEY: $BAZARR_API_KEY" "$BAZARR_URL/api/system/settings" \
        --data-urlencode settings-analytics-enabled=false \
        --data-urlencode settings-general-use_radarr=true \
        --data-urlencode settings-radarr-ip=radarr --data-urlencode settings-radarr-port=7878 \
        --data-urlencode settings-radarr-base_url=/ --data-urlencode settings-radarr-ssl=false \
        --data-urlencode "settings-radarr-apikey=$RADARR_API_KEY" \
        --data-urlencode settings-general-use_sonarr=true \
        --data-urlencode settings-sonarr-ip=sonarr --data-urlencode settings-sonarr-port=8989 \
        --data-urlencode settings-sonarr-base_url=/ --data-urlencode settings-sonarr-ssl=false \
        --data-urlencode "settings-sonarr-apikey=$SONARR_API_KEY")
    if [ "$code" = "204" ]; then ok "Bazarr: connected to Radarr and Sonarr; anonymous usage data off"; else todo "Bazarr: settings POST returned HTTP $code; connect Radarr/Sonarr in Settings."; fi
    echo "    Bazarr still needs a language profile and subtitle providers (Settings > Languages / Providers)."
}

# ── 10. Qui ─────────────────────────────────────────────────────────────────
QUI_COOKIE="$COOKIE_DIR/qui.cookie"
qui_api() {  # qui_api <method> <path> [json]
    http "$1" "$QUI_URL$2" "${3-}" -b "$QUI_COOKIE" -c "$QUI_COOKIE" -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest'
}

qui_import_automation() {  # qui_import_automation <instance-id> <json>  (added enabled; an existing disabled copy is enabled)
    local inst="$1" rule="$2" name existing
    name=$(printf '%s' "$rule" | jpy "d['name']")
    existing=$(qui_api GET "/api/instances/$inst/automations" | jpy "next((a for a in d if a['name']=='$name'), None)")
    if [ -n "$existing" ]; then
        if [ "$(printf '%s' "$existing" | jpy "d.get('enabled')")" = "True" ]; then ok "Qui: automation '$name' already enabled"; return 0; fi
        qui_api PUT "/api/instances/$inst/automations/$(printf '%s' "$existing" | jpy "d['id']")" "$(printf '%s' "$existing" | jpy "dict(d, enabled=True)")" >/dev/null
        if http_ok; then ok "Qui: automation '$name' enabled"; else warn "Qui: could not enable automation '$name' (HTTP $(http_code))"; fi
        return 0
    fi
    qui_api POST "/api/instances/$inst/automations" "$(printf '%s' "$rule" | jpy "dict(d, enabled=True)")" >/dev/null
    if http_ok; then ok "Qui: automation '$name' added and enabled"; else warn "Qui: automation '$name' rejected (HTTP $(http_code))"; fi
}

qui_add_arr() {  # qui_add_arr <radarr|sonarr> <internal-url> <api-key>
    local type="$1" url="$2" key="$3" existing
    # An entry from an earlier run may carry a bad key: test it, replace it if it fails.
    existing=$(qui_api GET /api/arr/instances | jpy "next((str(a['id']) for a in d if a.get('type')=='$type' and a.get('base_url')=='$url'), None)")
    if [ -n "$existing" ]; then
        if [ "$(qui_api POST "/api/arr/instances/$existing/test" | jpy "d.get('success')")" = "True" ]; then
            ok "Qui: ${type^} integration already present and working"; return 0
        fi
        qui_api DELETE "/api/arr/instances/$existing" >/dev/null
        http_ok && echo "    Qui: replaced a ${type^} integration whose connection test failed" \
                || { warn "Qui: ${type^} integration exists but fails its test and could not be replaced (HTTP $(http_code)); fix its API key in Settings > Integrations"; return 1; }
    fi
    qui_api POST /api/arr/instances "$(T="$type" U="$url" K="$key" jbuild '{"type": os.environ["T"], "name": os.environ["T"].capitalize(), "base_url": os.environ["U"], "api_key": os.environ["K"], "enabled": True, "priority": 0, "timeout_seconds": 15}')" >/dev/null
    case "$(http_code)" in
        201) ok "Qui: ${type^} integration added" ;;
        409) ok "Qui: ${type^} integration already present" ;;
        *)   warn "Qui: ${type^} integration returned HTTP $(http_code)" ;;
    esac
}

qui_import_prowlarr_indexers() {
    [ -n "$PROWLARR_API_KEY" ] || return 0
    # Only private trackers are useful for cross-seeding (public ones hit rate limits).
    local private discovered have
    private=$(arr_api "$PROWLARR_URL" "$PROWLARR_API_KEY" GET /api/v1/indexer \
        | jpy "' '.join(str(i['id']) for i in d if i.get('enable') and i.get('protocol')=='torrent' and i.get('privacy')=='private')")
    if [ -z "$private" ]; then
        echo "    Qui: Prowlarr has no private torrent indexers yet; re-run this script (or use Settings > Indexers > 1-click sync) after adding trackers."
        return 0
    fi
    discovered=$(qui_api POST /api/torznab/indexers/discover "$(jbuild '{"base_url": "http://prowlarr:9696", "api_key": os.environ["PROWLARR_API_KEY"]}')")
    http_ok || { warn "Qui: Prowlarr discovery failed (HTTP $(http_code))"; return 1; }
    have=$(qui_api GET /api/torznab/indexers | jpy "[i.get('indexer_id') for i in d]")
    local id payload
    for id in $private; do
        [[ "$have" == *"\"$id\""* ]] && continue
        payload=$(printf '%s' "$discovered" | WANT="$id" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
i = next((x for x in d.get("indexers", []) if str(x.get("id")) == os.environ["WANT"]), None)
if not i: sys.exit(1)
print(json.dumps({"name": i["name"], "base_url": "http://prowlarr:9696", "api_key": os.environ["PROWLARR_API_KEY"], "backend": "prowlarr",
                  "indexer_id": str(i["id"]), "enabled": True, "capabilities": i.get("caps", []), "categories": i.get("categories", [])}))') || continue
        qui_api POST /api/torznab/indexers "$payload" >/dev/null
        http_ok && ok "Qui: imported private indexer $(printf '%s' "$payload" | jpy "d['name']") from Prowlarr" \
                || warn "Qui: indexer $id import returned HTTP $(http_code)"
    done
}

configure_qui() {
    info "[10/10] Qui"
    wait_for "Qui" 180 bash -c "curl -fs $QUI_URL/health -o /dev/null" \
        || { todo "Qui did not come up; skipping."; return 1; }
    local need
    need=$(http GET "$QUI_URL/api/auth/check-setup" | jpy "d.get('setupRequired')")
    if [ "$need" = "True" ]; then
        http POST "$QUI_URL/api/auth/setup" "$(jbuild '{"username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PASS"]}')" -c "$QUI_COOKIE" -H 'Content-Type: application/json' >/dev/null
        http_ok && ok "Qui: account created ($ADMIN_USER / $ADMIN_PASS)" || { todo "Qui: setup returned HTTP $(http_code); finish it at $QUI_URL."; return 1; }
    else
        http POST "$QUI_URL/api/auth/login" "$(jbuild '{"username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PASS"]}')" -c "$QUI_COOKIE" -H 'Content-Type: application/json' >/dev/null
        http_ok && ok "Qui: logged in" || { todo "Qui: login failed (HTTP $(http_code)); configure it at $QUI_URL."; return 1; }
    fi

    # qBittorrent instance, with local filesystem access (shared /media mount).
    local inst
    inst=$(qui_api GET /api/instances | jpy "next((i['id'] for i in d if i['host']=='$QB_INT'), None)")
    if [ -z "$inst" ]; then
        inst=$(qui_api POST /api/instances "$(jbuild '{"name": "qbittorrent", "host": "http://qbittorrent:8080", "username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PASS"], "hasLocalFilesystemAccess": True}')" | jpy "d['id']")
        [ -n "$inst" ] && ok "Qui: qBittorrent instance added" || { todo "Qui: could not add the qBittorrent instance (HTTP $(http_code))."; return 1; }
    else
        ok "Qui: qBittorrent instance already present"
    fi

    # Reflink cross-seed mode (ZFS), flat layout, plus reannounce. One PUT.
    # The update must carry the login again: Qui stores whatever username the
    # PUT holds, and an empty one switches the instance to "no login", after
    # which qBittorrent answers 403 and Qui backs off forever.
    qui_api PUT "/api/instances/$inst" "$(jbuild '{"name": "qbittorrent", "host": "http://qbittorrent:8080", "username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PASS"], "hasLocalFilesystemAccess": True, "useReflinks": True, "useHardlinks": False, "hardlinkBaseDir": "/media/downloads/crossseed", "hardlinkDirPreset": "flat", "fallbackToRegularMode": False, "reannounceSettings": {"enabled": True, "initialWaitSeconds": 15, "reannounceIntervalSeconds": 7, "maxAgeSeconds": 600, "maxRetries": 50, "aggressive": False, "monitorAll": True, "excludeCategories": False, "categories": [], "excludeTags": False, "tags": [], "excludeTrackers": False, "trackers": []}}')" >/dev/null
    http_ok && ok "Qui: reflink cross-seed mode (/media/downloads/crossseed, flat) + reannounce enabled" \
            || warn "Qui: instance settings update returned HTTP $(http_code)"

    # Qui backs off (up to an hour after an IP ban) when qBittorrent rejected
    # it earlier. Re-activating the instance clears that state; the test then
    # says right away whether Qui can log in.
    local conn
    qui_api PUT "/api/instances/$inst/status" '{"isActive": true}' >/dev/null
    conn=$(qui_api POST "/api/instances/$inst/test")
    if [ "$(printf '%s' "$conn" | jpy "d.get('connected')")" = "True" ]; then ok "Qui: connected to qBittorrent"; else
        todo "Qui: cannot connect to qBittorrent: $(printf '%s' "$conn" | jpy "d.get('error') or d.get('message') or d")"; fi

    # Cross-seed rules + RSS automation (wiki sections 3.1 and 3.3).
    qui_api PATCH /api/cross-seed/settings "$(I="$inst" jbuild '{"useCrossCategoryAffix": True, "categoryAffixMode": "suffix", "categoryAffix": ".cross", "skipPieceBoundarySafetyCheck": False, "enabled": True, "runIntervalMinutes": 90, "targetInstanceIds": [int(os.environ["I"])], "targetIndexerIds": [], "rssSourceExcludeTags": ["cross-seed"]}')" >/dev/null
    http_ok && ok "Qui: cross-seed rules (.cross suffix, piece check on) and RSS automation (90 min) set" \
            || warn "Qui: cross-seed settings returned HTTP $(http_code)"

    # Auto-search on completion (wiki 3.4).
    qui_api PUT "/api/cross-seed/completion/$inst" '{"enabled": true, "categories": [], "tags": [], "excludeCategories": [], "excludeTags": ["cross-seed"], "indexerIds": [], "bypassTorznabCache": false, "delaySeconds": 0}' >/dev/null
    http_ok && ok "Qui: auto-search on completion enabled" || warn "Qui: completion settings returned HTTP $(http_code)"

    # Automations from the wiki (section 4), imported DISABLED like the UI does —
    # "Remove Unlinked" in particular must be reviewed before it is switched on.
    qui_import_automation "$inst" '{"name":"Remove Unlinked","trackerPattern":"*","trackerDomains":["*"],"conditions":{"schemaVersion":"1","delete":{"enabled":true,"mode":"deleteWithFilesIncludeCrossSeeds","includeHardlinks":true,"condition":{"operator":"AND","conditions":[{"field":"HARDLINK_SCOPE","operator":"NOT_EQUAL","value":"outside_qbittorrent"},{"field":"COMPLETION_ON_AGE","operator":"GREATER_THAN_OR_EQUAL","value":"1296000"}]}}}}'
    qui_import_automation "$inst" '{"name":"Unregistered","trackerPattern":"*","trackerDomains":["*"],"conditions":{"schemaVersion":"1","delete":{"enabled":true,"mode":"deleteWithFilesIncludeCrossSeeds","condition":{"operator":"AND","conditions":[{"field":"IS_UNREGISTERED","operator":"EQUAL","value":"true"},{"field":"COMPLETION_ON_AGE","operator":"GREATER_THAN_OR_EQUAL","value":"86400"}]}}}}'
    qui_import_automation "$inst" '{"name":"Stalled","trackerPattern":"*","trackerDomains":["*"],"conditions":{"schemaVersion":"1","delete":{"enabled":true,"mode":"deleteWithFiles","condition":{"operator":"AND","conditions":[{"field":"PROGRESS","operator":"LESS_THAN_OR_EQUAL","value":"0.02"},{"field":"ADDED_ON_AGE","operator":"GREATER_THAN_OR_EQUAL","value":"3600"}]}}}}'
    qui_import_automation "$inst" '{"name":"Tag Stalled (H&R Risk)","trackerPattern":"*","trackerDomains":["*"],"conditions":{"schemaVersion":"1","tag":{"enabled":true,"tags":["stuck-hr-risk"],"mode":"full","condition":{"operator":"AND","conditions":[{"field":"PROGRESS","operator":"GREATER_THAN_OR_EQUAL","value":"0.02"},{"field":"PROGRESS","operator":"LESS_THAN","value":"1"},{"field":"ADDED_ON_AGE","operator":"GREATER_THAN_OR_EQUAL","value":"172800"}]}}}}'

    # Orphan scan (wiki 5).
    qui_api PUT "/api/instances/$inst/orphan-scan/settings" '{"enabled": true}' >/dev/null
    http_ok && ok "Qui: orphan scan enabled" || warn "Qui: orphan scan settings returned HTTP $(http_code)"

    # *arr integrations (wiki 2.2) and private indexers from Prowlarr (wiki 2.1).
    [ -n "$RADARR_API_KEY" ] && qui_add_arr radarr "$RADARR_INT" "$RADARR_API_KEY"
    [ -n "$SONARR_API_KEY" ] && qui_add_arr sonarr "$SONARR_INT" "$SONARR_API_KEY"
    qui_import_prowlarr_indexers
    echo "    Qui: run a one-time Library Scan (Cross-Seed > Scan) once you have private indexers; it is long-running so this script does not start it."
}

# ── Run in the wiki's install order ─────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " Auto-configuring the stack (login everywhere: $ADMIN_USER / $ADMIN_PASS)"
echo "═══════════════════════════════════════════════════════════════"
configure_qbittorrent
configure_radarr
configure_sonarr
configure_flaresolverr
configure_prowlarr
configure_profilarr
configure_jellyfin
configure_seerr
configure_bazarr
configure_qui

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " Done. Services and their URLs:"
echo "═══════════════════════════════════════════════════════════════"
docker ps --format "{{.Names}}" | while read -r container_name; do
    ports=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{ (index $conf 0).HostPort }} {{end}}{{end}}' "$container_name")
    if [ -n "$ports" ]; then
        for port in $ports; do echo "  $container_name | http://$HOST_IP:$port"; done
    else
        echo "  $container_name | no published port"
    fi
done
echo ""
echo "  Logins (qBittorrent, Radarr, Sonarr, Prowlarr, Profilarr, Jellyfin, Seerr, Qui):"
echo "    user: $ADMIN_USER   password: $ADMIN_PASS   email: $ADMIN_EMAIL"
echo "  CHANGE THESE before exposing anything beyond your LAN."
if [ "${#TODO_LIST[@]}" -gt 0 ]; then
    echo ""
    echo "  Finish by hand:"
    for item in "${TODO_LIST[@]}"; do echo "   - $item"; done
fi
echo ""
echo "  Still manual by design: Prowlarr indexers (your trackers), Bazarr languages"
echo "  and providers, and the one-time Qui library scan."
echo "Script completed."
