#!/usr/bin/env bash
# ============================================================================
# TrueNAS *arr stack, the complete edition: datasets + one compose stack per
# container + Dockge + full auto-configuration
#
# What it does, in order:
#   1. Creates the datasets: configs (one subdataset per app), media (with the
#      movies / tv / downloads folder structure) and stacks (one directory
#      per container, each holding its own compose.yaml, the layout Dockge
#      manages).
#   2. Creates the shared Docker network "arr" and writes a compose stack per
#      container; every stack joins "arr", so containers keep reaching each
#      other by name across stacks.
#   3. If you choose to launch: gets qBittorrent's WireGuard config (paste a
#      wg0.conf, or generate one from AirVPN with airvpn-wg.sh, which can also
#      set up alerts and automatic server switching) and asks for a forwarded
#      port if your VPN gave you one, then launches every
#      stack (including Dockge) and configures every app
#      through its API in the order from wiki.serversatho.me/en/InstallInstructions:
#
#        qBittorrent -> Radarr -> Sonarr -> Trawl -> Prowlarr
#        -> Profilarr -> Jellyfin -> Seerr -> Bazarr -> Qui -> Tracearr -> Dockge
#
#   Along the way it detects a GPU (NVIDIA, Intel or AMD, dedicated or
#   integrated), measures what it can decode and encode with Jellyfin's own
#   ffmpeg, passes it into the Jellyfin stack and switches Jellyfin to
#   hardware transcoding with exactly those capabilities. No GPU: software
#   transcoding, as before.
#
# Every step is idempotent (safe to re-run) and isolated: a step that cannot be
# completed prints what to finish in the UI and the rest still runs.
#
# Logins: the script asks for one username and password and creates that
# login in every app (Enter keeps the defaults admin / changeme; the email is
# admin@admin.com). The choice is remembered in configs/arr-complete.env for
# re-runs. Dockge rejects letters-only passwords such as the default, so it
# gets a generated one in that case, printed at the end, and its
# authentication is switched off either way.
#
# Run in the TrueNAS shell as root:
#   sudo su -c "wget https://raw.githubusercontent.com/serversathome/ServersatHome/refs/heads/main/arr-complete.sh && chmod +x arr-complete.sh && bash arr-complete.sh"
# ============================================================================

# ok()/warn()/todo() always succeed, so "cmd && ok ... || todo ..." is a safe
# one-line if/else throughout this file.
# shellcheck disable=SC2015
set -uo pipefail

# ── Defaults for every login this script creates (asked for below) ─────────
ADMIN_USER="admin"
ADMIN_PASS="changeme"
ADMIN_EMAIL="admin@admin.com"
QB_FORWARDED_PORT=""   # fixed forwarded port from the VPN provider, if any

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
        # A sign of life every 30s, so a long wait is not mistaken for a hang.
        [ $(( waited % 30 )) -eq 0 ] && echo "    ... still waiting (${waited}s of ${timeout}s)" >&2
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
COOKIE_DIR=$(mktemp -d)   # session cookies for the apps configured below
trap 'rm -rf "$COOKIE_DIR" "$HTTP_STATUS_FILE" "$HTTP_BODY_FILE" "$HTTP_ERR_FILE"' EXIT
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
    echo "Only one data pool found; using '$CONFIG_POOL' for configs, stacks and media."
else
    choose_pool "Which pool should hold the app configs and compose stacks (SSD pool if you have one)?"
    CONFIG_POOL="$CHOSEN_POOL"
    choose_pool "Which pool should hold the media library (can be the same pool)?" "$CONFIG_POOL"
    MEDIA_POOL="$CHOSEN_POOL"
fi

# Dataset names need to be lowercase with no spaces for the rest of the stack.
for pool in "$CONFIG_POOL" "$MEDIA_POOL"; do
    [[ "$pool" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] \
        || die "Pool name '$pool' must be lowercase with no spaces. Rename the pool or create a compliant one."
done
echo "Configs/stacks pool: $CONFIG_POOL    Media pool: $MEDIA_POOL"

# ── Login ───────────────────────────────────────────────────────────────────
# One username and password for every app. The answers are kept in a
# root-only file inside the configs dataset so a re-run offers them as the
# defaults (the apps already hold that login; a different one would lock the
# script out of them).
SETUP_STATE_FILE="/mnt/$CONFIG_POOL/configs/arr-complete.env"
if [ -s "$SETUP_STATE_FILE" ]; then
    # Written by this script with printf %q, so sourcing it is safe.
    # shellcheck source=/dev/null
    . "$SETUP_STATE_FILE"
    echo "Previous answers loaded from $SETUP_STATE_FILE (Enter keeps them)."
fi
echo ""
echo "Login to create in every app (Enter keeps the value in brackets):"
while :; do
    read -rp "  Username [$ADMIN_USER]: " answer
    [ -z "$answer" ] && break
    if [[ "$answer" =~ ^[^[:space:]]{3,}$ ]]; then ADMIN_USER="$answer"; break; fi
    echo "  At least 3 characters and no spaces (Profilarr insists on that)."
done
while :; do
    read -rsp "  Password [$([ "$ADMIN_PASS" = changeme ] && echo changeme || echo 'keep the saved one')]: " answer; echo
    [ -z "$answer" ] && break
    if [ "${#answer}" -lt 8 ]; then echo "  At least 8 characters (Tracearr insists on that)."; continue; fi
    if [[ "$answer" =~ ^[[:space:]]|[[:space:]]$ ]]; then echo "  No leading or trailing spaces, please."; continue; fi
    read -rsp "  Repeat the password: " answer2; echo
    if [ "$answer" != "$answer2" ]; then echo "  They differ; try again."; continue; fi
    ADMIN_PASS="$answer"; break
done
unset answer answer2

# ── Host facts ──────────────────────────────────────────────────────────────
# LAN network for the qBittorrent VPN LAN bypass. Use the interface that
# carries the default route and its real prefix (not the first address
# `hostname -I` returns, which can be a Docker bridge, and not an assumed /24).
DEFAULT_IF=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
HOST_CIDR=$(ip -o -4 addr show dev "${DEFAULT_IF:-lo}" scope global 2>/dev/null | awk '{print $4; exit}')
HOST_IP="${HOST_CIDR%/*}"
if [ -n "$HOST_CIDR" ]; then
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

# ── GPU for Jellyfin transcoding ────────────────────────────────────────────
# Decided here because it shapes the Jellyfin compose file. What the GPU can
# actually decode and encode is measured right after (see below) with
# Jellyfin's own ffmpeg in a throwaway container; the Jellyfin step applies it.
#   NVIDIA : needs the TrueNAS NVIDIA driver (Apps > Settings) for nvidia-smi
#            and the container runtime to exist; the card is passed with the
#            container toolkit.
#   Intel / AMD : the render node under /dev/dri is passed through, plus the
#            groups that own it, since Jellyfin runs as 568.
# Preference when several are present: NVIDIA, then Intel, then AMD.
GPU_VENDOR="none"; GPU_NAME=""; GPU_RENDER=""; GPU_NOTE=""
detect_gpu() {
    local node vendor dev
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        GPU_VENDOR="nvidia"
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
        return 0
    fi
    if lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -qi nvidia; then
        GPU_NOTE="An NVIDIA GPU is in the PCI list but its driver is not loaded: turn on 'Install NVIDIA Drivers' under Apps > Settings in the TrueNAS UI and re-run this script. Jellyfin uses software transcoding until then."
    fi
    for node in /sys/class/drm/renderD*; do
        [ -r "$node/device/vendor" ] || continue
        vendor=$(cat "$node/device/vendor")
        case "$vendor" in
            0x8086) GPU_VENDOR="intel"; GPU_RENDER="/dev/dri/${node##*/}"; break ;;
            0x1002) [ "$GPU_VENDOR" = "none" ] && { GPU_VENDOR="amd"; GPU_RENDER="/dev/dri/${node##*/}"; } ;;
        esac
    done
    if [ "$GPU_VENDOR" != "none" ] && [ ! -c "$GPU_RENDER" ]; then
        GPU_NOTE="render node $GPU_RENDER is not a character device; cannot pass it to Jellyfin"
        GPU_VENDOR="none"
    fi
    if [ "$GPU_VENDOR" != "none" ]; then
        dev=$(basename "$(readlink -f "/sys/class/drm/${GPU_RENDER##*/}/device" 2>/dev/null)" 2>/dev/null)
        GPU_NAME=$(lspci -s "$dev" 2>/dev/null | sed 's/^[0-9a-f:.]* [^:]*: //' | head -1)
        [ -z "$GPU_NOTE" ] || GPU_NOTE="an NVIDIA GPU is also present but its driver is not loaded (Apps > Settings > Install NVIDIA Drivers); the ${GPU_VENDOR^^} GPU is used instead"
    fi
}
detect_gpu
# Say what was looked at and what came of it, so a software-only result is
# never a mystery (VM without passthrough, missing driver, no GPU at all).
info "GPU for Jellyfin hardware transcoding"
GPU_DRI_NODES=$(find /dev/dri -maxdepth 1 -name 'card*' -o -name 'renderD*' 2>/dev/null | sed 's|.*/||' | sort | tr '\n' ' ')
GPU_DISPLAYS=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | sed 's/^/      /')
echo "    Checked: nvidia-smi, render nodes under /dev/dri, PCI display adapters"
echo "    /dev/dri: ${GPU_DRI_NODES:-(absent)}"
echo "    Display adapters (lspci):"; echo "${GPU_DISPLAYS:-      (none listed)}"
case "$GPU_VENDOR" in
    none)
        echo "    Result: no usable GPU; Jellyfin will transcode in software."
        if [ -n "$GPU_DISPLAYS" ] && ! printf '%s\n' "$GPU_DISPLAYS" | grep -viE '1234:1111|qemu|bochs|virtio|vmware|hyper-v|microsoft corporation|red hat' | grep -q .; then
            echo "    Every display adapter is a virtual one, so TrueNAS is running in a VM and the"
            echo "    physical GPU has not been passed through. Pass it to the VM (PCI passthrough; a"
            echo "    renderD* node then appears under /dev/dri) and re-run this script."
        elif [[ "$GPU_DRI_NODES" == *card* ]]; then
            echo "    A display device exists but no renderD* node: its driver is not loaded or the GPU"
            echo "    has no video engine Jellyfin can use."
        fi
        [ -n "$GPU_NOTE" ] && echo "    $GPU_NOTE"
        ;;
    nvidia) echo "    Result: NVIDIA ${GPU_NAME:-GPU} (NVENC/NVDEC)${GPU_NOTE:+; note: $GPU_NOTE}" ;;
    *)      echo "    Result: ${GPU_VENDOR^^} ${GPU_NAME:-GPU} via $GPU_RENDER${GPU_NOTE:+; note: $GPU_NOTE}" ;;
esac

# What can the GPU really decode and encode? Hardware varies too much for a
# model table, so it is measured with Jellyfin's own ffmpeg in a one-off
# container (docker run --rm: nothing stays behind except the Jellyfin image,
# which the stack needs anyway):
#   Intel / AMD : vainfo lists the VA-API profiles (VLD = decode, EncSlice =
#                 encode, EncSliceLP = Intel low-power encode); ffmpeg then
#                 checks QSV (Intel) and OpenCL (HDR tone mapping), runs a
#                 real encode per codec, normal and low-power, and tries the
#                 driver's own HDR10 tone mapping (VPP) on a generated clip.
#   NVIDIA      : ffmpeg encodes a test pattern with h264/hevc/av1_nvenc and
#                 decodes generated clips with the *_cuvid decoders (NVDEC),
#                 including 10-bit HEVC and VP9.
# Results feed the Jellyfin step. If the container cannot even reach the GPU
# (missing NVIDIA runtime, odd permissions), the stack is written without GPU
# passthrough rather than failing to start.
GPU_ACCEL=""; GPU_DEC=""; GPU_ENC=""; GPU_HEVC10=0; GPU_VP9_10=0; GPU_REXT10=0; GPU_REXT12=0; GPU_LP=""; GPU_TONEMAP=0; GPU_VPP=0; GPU_DRIVER=""
JELLYFIN_IMAGE="lscr.io/linuxserver/jellyfin:latest"
PROBE_VAAPI=$(cat <<'EOF'
set +e
FF=/usr/lib/jellyfin-ffmpeg/ffmpeg; VI=/usr/lib/jellyfin-ffmpeg/vainfo
[ -x "$VI" ] || VI=$(command -v vainfo)
timeout 60 "$VI" --display drm --device "$RENDER" 2>&1 | sed 's/^/vainfo: /'
QSV=0
timeout 60 "$FF" -v error -init_hw_device vaapi=va:"$RENDER" -init_hw_device qsv=qs@va -f lavfi -i nullsrc=s=64x64:d=0.1 -f null - >/dev/null 2>&1 && { echo qsv=1; QSV=1; }
timeout 60 "$FF" -v error -init_hw_device vaapi=va:"$RENDER" -init_hw_device opencl=ocl@va -f lavfi -i nullsrc=s=64x64:d=0.1 -f null - >/dev/null 2>&1 && echo opencl=1
# Real encodes, with the rate control Jellyfin uses (VBR). vainfo lists an
# encoder profile whether or not it works: low-power (VDEnc) encoding on
# older Intel generations needs the i915 HuC firmware, and only an actual
# encode shows whether it is there.
enc_test() {  # enc_test <h264|hevc|av1> <low_power 0|1>
    if [ "$QSV" = 1 ]; then
        timeout 90 "$FF" -v error -init_hw_device vaapi=va:"$RENDER" -init_hw_device qsv=qs@va -filter_hw_device qs \
            -f lavfi -i "testsrc2=s=320x240:r=25:d=0.4" -vf "format=nv12,hwupload=extra_hw_frames=64" \
            -c:v "${1}_qsv" -preset veryfast -low_power "$2" -b:v 2M -maxrate 2M -bufsize 4M -f null - >/dev/null 2>&1
    else
        timeout 90 "$FF" -v error -init_hw_device vaapi=va:"$RENDER" -filter_hw_device va \
            -f lavfi -i "testsrc2=s=320x240:r=25:d=0.4" -vf "format=nv12,hwupload" \
            -c:v "${1}_vaapi" -low_power "$2" -b:v 2M -maxrate 2M -f null - >/dev/null 2>&1
    fi
}
for c in h264 hevc av1; do
    if enc_test "$c" 0; then echo "encok_$c=1"; else echo "encfail_$c=1"; fi
    enc_test "$c" 1 && echo "lpok_$c=1"
done
# Driver (VPP) tone mapping: tonemap_vaapi needs a real HDR10 input with
# mastering-display metadata, so make a tiny one with libx265 first. This is
# the filter chain Jellyfin uses for "Enable VPP Tone mapping".
T=$(mktemp -d)
if timeout 90 "$FF" -v error -y -f lavfi -i "testsrc2=s=320x240:r=25:d=0.4" -pix_fmt yuv420p10le -c:v libx265 \
     -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
     -x265-params "log-level=none:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" \
     "$T/hdr10.mp4" >/dev/null 2>&1; then
    timeout 60 "$FF" -v error -init_hw_device vaapi=va:"$RENDER" -hwaccel vaapi -hwaccel_device va -hwaccel_output_format vaapi \
        -i "$T/hdr10.mp4" -vf "tonemap_vaapi=format=nv12:p=bt709:t=bt709:m=bt709" -f null - >/dev/null 2>&1 && echo vpp_tonemap=1
else echo vpp_untested=1; fi
rm -rf "$T"; exit 0
EOF
)
PROBE_NVIDIA=$(cat <<'EOF'
set +e
FF=/usr/lib/jellyfin-ffmpeg/ffmpeg; T=$(mktemp -d); cd "$T" || exit 1
SRC="-f lavfi -i testsrc2=s=320x240:r=25:d=0.4"
enc() { timeout 60 "$FF" -v error -y $SRC -c:v "$1" -f null - >/dev/null 2>&1; }
mk()  { local f="$1"; shift; timeout 90 "$FF" -v error -y $SRC "$@" "$f" >/dev/null 2>&1 && [ -s "$f" ]; }
dec() { timeout 60 "$FF" -v error -c:v "$1" -i "$2" -f null - >/dev/null 2>&1; }
for c in h264 hevc av1; do enc "${c}_nvenc" && echo "enc_$c=1"; done
mk h264.mp4 -c:v libx264 -pix_fmt yuv420p && dec h264_cuvid h264.mp4 && echo dec_h264=1
mk hevc.mp4 -c:v libx265 -pix_fmt yuv420p -x265-params log-level=none && dec hevc_cuvid hevc.mp4 && echo dec_hevc=1
mk hevc10.mp4 -c:v libx265 -pix_fmt yuv420p10le -x265-params log-level=none && dec hevc_cuvid hevc10.mp4 && echo dec_hevc10=1
mk vp9.webm -c:v libvpx-vp9 -pix_fmt yuv420p && dec vp9_cuvid vp9.webm && echo dec_vp9=1
mk vp9_10.webm -c:v libvpx-vp9 -pix_fmt yuv420p10le -profile:v 2 && dec vp9_cuvid vp9_10.webm && echo dec_vp9_10=1
mk vp8.webm -c:v libvpx -pix_fmt yuv420p && dec vp8_cuvid vp8.webm && echo dec_vp8=1
mk mpeg2.mpg -c:v mpeg2video -pix_fmt yuv420p && dec mpeg2_cuvid mpeg2.mpg && echo dec_mpeg2video=1
if mk av1.mkv -c:v libsvtav1 -pix_fmt yuv420p -preset 12 || mk av1.mkv -c:v libaom-av1 -pix_fmt yuv420p -cpu-used 8; then
    dec av1_cuvid av1.mkv && echo dec_av1=1
else echo av1_untested=1; fi
rm -rf "$T"; exit 0
EOF
)
gpu_tonemap_summary() {
    if [ "$GPU_TONEMAP" = 1 ] && [ "$GPU_VPP" = 1 ]; then echo "on (OpenCL, plus Intel VPP for HDR10)"
    elif [ "$GPU_TONEMAP" = 1 ]; then echo "on (OpenCL/CUDA)"
    elif [ "$GPU_VPP" = 1 ]; then echo "HDR10 only, via the Intel driver (VPP); no OpenCL runtime in this image, so HLG/Dolby Vision are not tone mapped"
    else echo "off (no OpenCL runtime in this image and no driver tone mapping)"; fi
}
probe_gpu() {
    local out
    echo "    Measuring what the $GPU_VENDOR GPU can decode/encode with Jellyfin's ffmpeg in a throwaway container"
    echo "    (docker run --rm $JELLYFIN_IMAGE; nothing stays behind except the image, which the stack needs anyway)..."
    case "$GPU_VENDOR" in
        nvidia) out=$(timeout 900 docker run --rm --gpus all -e NVIDIA_DRIVER_CAPABILITIES=all --entrypoint /bin/bash "$JELLYFIN_IMAGE" -c "$PROBE_NVIDIA" 2>&1) ;;
        *)      out=$(timeout 900 docker run --rm --device /dev/dri:/dev/dri -e RENDER="$GPU_RENDER" --entrypoint /bin/bash "$JELLYFIN_IMAGE" -c "$PROBE_VAAPI" 2>&1) ;;
    esac
    local rc=$?
    if [ $rc -ne 0 ]; then
        GPU_NOTE="GPU probe container failed (exit $rc): $(printf '%s' "$out" | grep -v '^vainfo:' | tail -2 | tr '\n' ' '). Jellyfin runs without the GPU."
        GPU_VENDOR="none"; return 1
    fi
    local parsed
    parsed=$(printf '%s\n' "$out" | VENDOR="$GPU_VENDOR" python3 -c '
import json, os, re, sys
lines = sys.stdin.read().splitlines()
flags = {l.split("=")[0]: 1 for l in lines if re.fullmatch(r"[a-z0-9_]+=1", l)}
dec, enc, lp = [], [], []
hevc10 = vp9_10 = rext10 = rext12 = 0
driver = ""
if os.environ["VENDOR"] == "nvidia":
    dec = [c for c in ("h264", "hevc", "vp8", "vp9", "av1", "mpeg2video") if flags.get("dec_" + c)]
    if "h264" in dec: dec.append("vc1")            # NVDEC has decoded VC-1 on every generation that has NVDEC
    if "av1_untested" in flags and flags.get("enc_av1"): dec.append("av1")   # AV1 encode implies AV1 decode
    enc = [c for c in ("h264", "hevc", "av1") if flags.get("enc_" + c)]
    hevc10, vp9_10 = flags.get("dec_hevc10", 0), flags.get("dec_vp9_10", 0)
else:
    for l in lines:
        m = re.match(r"vainfo:\s*VAProfile(\S+)\s*:\s*VAEntrypoint(\S+)", l)
        dm = re.search(r"vainfo:.*Driver version:\s*(.*)", l)
        if dm: driver = dm.group(1).strip()
        if not m: continue
        prof, ep = m.groups()
        if ep == "VLD":
            if prof.startswith("H264"): dec.append("h264")
            elif prof in ("HEVCMain", "HEVCMain10"): dec.append("hevc"); hevc10 |= prof == "HEVCMain10"
            elif prof.startswith("HEVC"): rext10 |= prof in ("HEVCMain422_10", "HEVCMain444", "HEVCMain444_10"); rext12 |= prof in ("HEVCMain12", "HEVCMain422_12", "HEVCMain444_12")
            elif prof in ("VP9Profile0", "VP9Profile2"): dec.append("vp9"); vp9_10 |= prof == "VP9Profile2"
            elif prof == "AV1Profile0": dec.append("av1")
            elif prof.startswith("MPEG2"): dec.append("mpeg2video")
            elif prof.startswith("VC1"): dec.append("vc1")
            elif prof.startswith("VP8"): dec.append("vp8")
        elif ep in ("EncSlice", "EncSliceLP"):
            c = "h264" if prof.startswith("H264") else "hevc" if prof == "HEVCMain" else "av1" if prof == "AV1Profile0" else None
            if c:
                enc.append(c)
                if ep == "EncSliceLP": lp.append(c)
dedupe = lambda xs: sorted(set(xs), key=["h264", "hevc", "mpeg2video", "vc1", "vp8", "vp9", "av1"].index)
notes = []
if os.environ["VENDOR"] != "nvidia":
    # The driver lists a profile; the test encode decides.
    for c in dedupe(enc):
        if flags.get("encfail_" + c):
            notes.append(c + " encode is listed by the driver but a test encode failed; hardware " + c + " encoding stays off")
    bad_lp = [c for c in dedupe(lp) if not flags.get("lpok_" + c)]
    if bad_lp:
        notes.append("low-power " + "/".join(bad_lp) + " encoding is listed by the driver but a test encode failed (i915 HuC firmware not loaded?); the normal encoder is used instead")
    enc = [c for c in enc if not flags.get("encfail_" + c)]
    lp = [c for c in lp if flags.get("lpok_" + c)]
print(json.dumps({"dec": dedupe(dec), "enc": dedupe(enc), "lp": dedupe(lp), "hevc10": int(bool(hevc10)), "vp9_10": int(bool(vp9_10)),
                  "rext10": int(bool(rext10)), "rext12": int(bool(rext12)), "qsv": flags.get("qsv", 0), "opencl": flags.get("opencl", 0),
                  "vpp": flags.get("vpp_tonemap", 0), "driver": driver, "notes": notes}))')
    GPU_DEC=$(printf '%s' "$parsed" | jpy "','.join(d['dec'])")
    GPU_ENC=$(printf '%s' "$parsed" | jpy "','.join(d['enc'])")
    GPU_LP=$(printf '%s' "$parsed" | jpy "','.join(d['lp'])")
    GPU_HEVC10=$(printf '%s' "$parsed" | jpy "d['hevc10']"); GPU_VP9_10=$(printf '%s' "$parsed" | jpy "d['vp9_10']")
    GPU_REXT10=$(printf '%s' "$parsed" | jpy "d['rext10']"); GPU_REXT12=$(printf '%s' "$parsed" | jpy "d['rext12']")
    GPU_DRIVER=$(printf '%s' "$parsed" | jpy "d['driver']")
    local note
    while IFS= read -r note; do [ -n "$note" ] && warn "GPU: $note"; done < <(printf '%s' "$parsed" | jpy "'\n'.join(d['notes'])")
    if [ -z "$GPU_DEC" ] && [ -z "$GPU_ENC" ]; then
        GPU_NOTE="The $GPU_VENDOR GPU exposed no decoders or encoders to Jellyfin's ffmpeg${GPU_DRIVER:+ (driver: $GPU_DRIVER)}; Jellyfin runs without it. Probe output: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
        GPU_VENDOR="none"; return 1
    fi
    case "$GPU_VENDOR" in
        nvidia) GPU_ACCEL="nvenc"; GPU_TONEMAP=1 ;;   # CUDA tone mapping is available wherever NVENC is
        intel)  if [ "$(printf '%s' "$parsed" | jpy "d['qsv']")" = "1" ]; then GPU_ACCEL="qsv"; else GPU_ACCEL="vaapi"; fi
                GPU_TONEMAP=$(printf '%s' "$parsed" | jpy "d['opencl']"); GPU_VPP=$(printf '%s' "$parsed" | jpy "d['vpp']") ;;
        amd)    GPU_ACCEL="vaapi"; GPU_TONEMAP=$(printf '%s' "$parsed" | jpy "d['opencl']") ;;
    esac
    local tenbit=""
    [ "$GPU_HEVC10" = 1 ] && tenbit+=", 10-bit HEVC"
    [ "$GPU_VP9_10" = 1 ] && tenbit+=", 10-bit VP9"
    [ "$GPU_REXT10" = 1 ] && tenbit+=", HEVC RExt 10-bit"
    [ "$GPU_REXT12" = 1 ] && tenbit+=", HEVC RExt 12-bit"
    ok "GPU probe finished. The throwaway container found:"
    [ -n "$GPU_DRIVER" ] && echo "      driver:            $GPU_DRIVER"
    echo "      hardware decode:   ${GPU_DEC:-none}${tenbit}"
    echo "      hardware encode:   ${GPU_ENC:-none}${GPU_LP:+ (Intel low-power: $GPU_LP)}"
    echo "      acceleration:      $GPU_ACCEL"
    echo "      HDR tone mapping:  $(gpu_tonemap_summary)"
    echo "    These settings are applied to Jellyfin in step 7."
}
[ "$GPU_VENDOR" = "none" ] || probe_gpu || warn "$GPU_NOTE"
echo ""

# Compose fragments for the Jellyfin stack (already indented for the file).
JELLYFIN_GPU_ENV=""
JELLYFIN_GPU_BLOCK=""
case "$GPU_VENDOR" in
    intel|amd)
        render_gid=$(stat -c '%g' "$GPU_RENDER")
        # The card node of the same device (its group is usually "video").
        card_node=$(find "/sys/class/drm/${GPU_RENDER##*/}/device/drm" -maxdepth 1 -name 'card*' 2>/dev/null | head -1)
        video_gid=$(stat -c '%g' "/dev/dri/${card_node##*/}" 2>/dev/null || echo "$render_gid")
        JELLYFIN_GPU_BLOCK="    devices:
      - /dev/dri:/dev/dri
    group_add:
      - \"$render_gid\""
        [ "$video_gid" != "$render_gid" ] && JELLYFIN_GPU_BLOCK+="
      - \"$video_gid\""
        ;;
    nvidia)
        JELLYFIN_GPU_ENV="      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=all"
        JELLYFIN_GPU_BLOCK="    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]"
        ;;
esac

# ── Layout ──────────────────────────────────────────────────────────────────
# configs/<app>: one dataset per app. Seerr is the exception: its container
# always runs as UID 1000 (the node user) and ignores `user:`, so its dataset
# is owned by 1000 — see wiki.serversatho.me/en/seerr.
# stacks/<container>: one DIRECTORY per container inside the stacks dataset,
# each with its own compose.yaml — the layout Dockge manages.
CONFIG_DATASETS=("prowlarr" "radarr" "sonarr" "seerr" "profilarr" "bazarr" "jellyfin" "qbittorrent" "qui" "dozzle" "tracearr" "trawl" "dockge")
MEDIA_SUBDIRECTORIES=("movies" "tv" "downloads" "downloads/torrent" "downloads/crossseed")
STACKS=("qbittorrent" "radarr" "sonarr" "trawl" "prowlarr" "profilarr" "jellyfin" "seerr" "bazarr" "qui" "tracearr" "dozzle" "watchtower" "dockge")
CONFIGS_PATH="/mnt/$CONFIG_POOL/configs"
STACKS_PATH="/mnt/$CONFIG_POOL/stacks"
MEDIA_PATH="/mnt/$MEDIA_POOL/media"
QBITTORRENT_WIREGUARD_DIR="$CONFIGS_PATH/qbittorrent/wireguard"
DOCKER_NETWORK="arr"

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
# save_answers — keep the answers for re-runs (again after the forwarded port,
# which is only asked when launching).
save_answers() {
    {
        echo "# Answers from the last run of arr-complete.sh (root only). Delete to be asked afresh."
        printf 'ADMIN_USER=%q\nADMIN_PASS=%q\nQB_FORWARDED_PORT=%q\n' "$ADMIN_USER" "$ADMIN_PASS" "$QB_FORWARDED_PORT"
    } > "$SETUP_STATE_FILE" && chmod 600 "$SETUP_STATE_FILE"
}
save_answers
for dataset in "${CONFIG_DATASETS[@]}"; do
    if [ "$dataset" = "seerr" ]; then
        create_dataset "$CONFIG_POOL" "configs/$dataset" "1000:1000"
    else
        create_dataset "$CONFIG_POOL" "configs/$dataset"
    fi
done

create_dataset "$MEDIA_POOL" "media"
for subdir in "${MEDIA_SUBDIRECTORIES[@]}"; do
    create_directory "$MEDIA_PATH/$subdir"
done

# Tracearr's all-in-one image keeps its database, Redis and app data in three
# folders; its entrypoint owns them for the internal postgres/redis users, so
# they are created once and never re-owned (a running database must keep its
# ownership).
for subdir in postgres redis data; do
    [ -d "$CONFIGS_PATH/tracearr/$subdir" ] || create_directory "$CONFIGS_PATH/tracearr/$subdir"
done

create_dataset "$CONFIG_POOL" "stacks"
for stack in "${STACKS[@]}"; do
    create_directory "$STACKS_PATH/$stack"
done

# ── Compose stacks ──────────────────────────────────────────────────────────
# One compose.yaml per container under stacks/<container>. Each file is
# regenerated every run (it has to reflect the pools you chose); when the
# existing file differs it is backed up first, so hand edits are never lost.
# Every stack joins the shared "arr" network, created below, so the
# containers keep reaching each other by name (radarr, qbittorrent, ...)
# even though they are separate compose projects.
NETWORK_BLOCK="
networks:
  default:
    name: $DOCKER_NETWORK
    external: true"

# write_stack <name>   (compose text on stdin, without the networks block)
write_stack() {
    local name="$1" file="$STACKS_PATH/$1/compose.yaml" tmp backup
    tmp=$(mktemp)
    { cat; printf '%s\n' "$NETWORK_BLOCK"; } > "$tmp"
    if [ -f "$file" ] && ! cmp -s "$tmp" "$file"; then
        backup="$file.bak-$(date +%Y%m%d-%H%M%S)"
        cp -p "$file" "$backup"
        warn "stacks/$name/compose.yaml changed; the previous one is at $backup"
    fi
    mv "$tmp" "$file"
    chown root:apps "$file"; chmod 660 "$file"
}

write_stack prowlarr <<EOF
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
      - $CONFIGS_PATH/prowlarr:/config
EOF

write_stack radarr <<EOF
services:
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
      - $CONFIGS_PATH/radarr:/config
      - $MEDIA_PATH:/media
EOF

write_stack sonarr <<EOF
services:
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
      - $CONFIGS_PATH/sonarr:/config
      - $MEDIA_PATH:/media
EOF

write_stack seerr <<EOF
services:
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
      - $CONFIGS_PATH/seerr:/app/config
EOF

# Trawl replaces FlareSolverr: it serves the same FlareSolverr API on 8191
# (Prowlarr keeps using its FlareSolverr proxy type) and adds a dashboard at
# /dashboard. The standard image needs an x86 CPU with AVX2; older CPUs get
# the :baseline build of the same release.
TRAWL_TAG=latest
if [ "$(uname -m)" = x86_64 ] && ! grep -qw avx2 /proc/cpuinfo; then TRAWL_TAG=baseline; fi
write_stack trawl <<EOF
services:
  trawl:
    image: ghcr.io/germondai/trawl:$TRAWL_TAG
    container_name: trawl
    restart: unless-stopped
    # Camoufox (Firefox) needs more shared memory than Docker's 64 MB default.
    shm_size: 1gb
    environment:
      - TZ=$TZ_VALUE
      # One process, no Redis: clearance is cached in memory.
      - SESSION_CACHE_DRIVER=memory
      - BROWSER_POOL_SIZE=1
      # The request-history dashboard at /dashboard, without a token (LAN only).
      - METRICS_DASHBOARD_ENABLED=true
      - METRICS_DB_PATH=/data/metrics/trawl.sqlite
    ports:
      - 8191:8191
    volumes:
      - $CONFIGS_PATH/trawl:/data/metrics
EOF

write_stack profilarr <<EOF
services:
  profilarr:
    image: ghcr.io/dictionarry-hub/profilarr:latest
    container_name: profilarr
    restart: unless-stopped
    ports:
      - "6868:6868"
    volumes:
      - $CONFIGS_PATH/profilarr:/config
    environment:
      - PUID=568
      - PGID=568
      - UMASK=022
      - TZ=$TZ_VALUE
EOF

write_stack bazarr <<EOF
services:
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
      - $CONFIGS_PATH/bazarr:/config
      - $MEDIA_PATH:/media
EOF

# The GPU lines come from the detection above (empty when there is no GPU).
write_stack jellyfin <<EOF
services:
  jellyfin:
    container_name: jellyfin
    image: $JELLYFIN_IMAGE
    environment:
      - PUID=568
      - PGID=568
      - TZ=$TZ_VALUE
$JELLYFIN_GPU_ENV
    ports:
      - '8096:8096'
    restart: unless-stopped
    volumes:
      - $CONFIGS_PATH/jellyfin:/config
      - $MEDIA_PATH:/media
$JELLYFIN_GPU_BLOCK
EOF

# A function, because the forwarded port is only asked when launching: the
# stack is written now with the saved port and rewritten if it changes.
write_qbittorrent_stack() {
write_stack qbittorrent <<EOF
services:
  qbittorrent:
    container_name: qbittorrent
    # hotio's floating stable tag (the same image as "release"); Watchtower
    # keeps it current. The variables below follow hotio's current base image
    # (VPN_FIREWALL_TYPE is gone, nftables only; VPN_INTERFACE_PREFIXES and
    # Unbound are new; VPN_AUTO_PORT_FORWARD defaults to false).
    image: ghcr.io/hotio/qbittorrent:latest
    restart: unless-stopped
    ports:
      - 8080:8080
    environment:
      - PUID=568
      - PGID=568
      - UMASK=002
      - TZ=$TZ_VALUE
      - WEBUI_PORTS=8080/tcp
      - VPN_ENABLED=true
      - VPN_CONF=wg0
      - VPN_PROVIDER=generic
      - VPN_LAN_NETWORK=$CIDR_NETWORK,10.8.0.0/24
      - VPN_LAN_LEAK_ENABLED=false
      - VPN_EXPOSE_PORTS_ON_LAN=
      # false for a plain WireGuard config, or the fixed forwarded port asked
      # for when launching (qBittorrent then listens on it); "true" only works
      # together with VPN_PROVIDER=proton or pia.
      - VPN_AUTO_PORT_FORWARD=${QB_FORWARDED_PORT:-false}
      - VPN_PORT_REDIRECTS=
      - VPN_HEALTHCHECK_ENABLED=false
      - VPN_NAMESERVERS=wg
      - VPN_INTERFACE_PREFIXES=
      - PRIVOXY_ENABLED=false
      - UNBOUND_ENABLED=false
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=1
    volumes:
      - $CONFIGS_PATH/qbittorrent:/config
      - $MEDIA_PATH:/media
EOF
}
write_qbittorrent_stack

write_stack qui <<EOF
services:
  qui:
    image: ghcr.io/autobrr/qui:latest
    container_name: qui
    user: "568:568"
    restart: unless-stopped
    ports:
      - "7476:7476"
    volumes:
      - $CONFIGS_PATH/qui:/config
      - $MEDIA_PATH:/media
EOF

# Tracearr per wiki.serversatho.me/en/tracearr: the supervised image bundles
# TimescaleDB and Redis, generates its own secrets on first run, and needs
# the memory, shm and nofile settings below for the database.
write_stack tracearr <<EOF
services:
  tracearr:
    image: ghcr.io/connorgallopo/tracearr:supervised
    container_name: tracearr
    shm_size: 512mb
    mem_limit: 3g
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    ports:
      - "3000:3000"
    environment:
      - TZ=$TZ_VALUE
      - LOG_LEVEL=info
    volumes:
      - $CONFIGS_PATH/tracearr/postgres:/data/postgres
      - $CONFIGS_PATH/tracearr/redis:/data/redis
      - $CONFIGS_PATH/tracearr/data:/data/tracearr
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:3000/health"]
      interval: 30s
      timeout: 10s
      start_period: 60s
      retries: 3
EOF

write_stack dozzle <<EOF
services:
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
      - $CONFIGS_PATH/dozzle:/data
      - /proc:/host/proc:ro
EOF

write_stack watchtower <<EOF
services:
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

# Dockge manages the stacks directory. It must see the directory at the SAME
# path inside the container as on the host, because the compose commands it
# runs refer to that path.
write_stack dockge <<EOF
services:
  dockge:
    image: louislam/dockge:latest
    restart: unless-stopped
    container_name: dockge
    ports:
      - 5001:5001
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $CONFIGS_PATH/dockge:/app/data
      - $STACKS_PATH:$STACKS_PATH
    environment:
      - DOCKGE_STACKS_DIR=$STACKS_PATH
      - PUID=568
      - PGID=568
      - DOCKGE_ENABLE_CONSOLE=true
EOF

echo "Compose stacks written under $STACKS_PATH (one directory per container)."
echo "Datasets and directories are in place."

# ── Launch ──────────────────────────────────────────────────────────────────
read -rp "Would you like to launch AND auto-configure the Docker containers now? (yes/no): " LAUNCH_CONTAINERS
if [[ ! "$LAUNCH_CONTAINERS" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo "Docker containers were not launched. To start a stack by hand:"
    echo "  docker network create $DOCKER_NETWORK   (once)"
    echo "  docker compose -f $STACKS_PATH/<container>/compose.yaml up -d"
    exit 0
fi

docker info >/dev/null 2>&1 \
    || die "Cannot talk to the Docker daemon. Enable the Apps service in the TrueNAS UI, then re-run."

# WireGuard config for qBittorrent (hotio expects /config/wireguard/wg0.conf).
# Asked here, once the qbittorrent dataset exists and before the stacks start,
# so qBittorrent comes up with its tunnel. Paste one, or generate one from
# AirVPN with airvpn-wg.sh: that script and its settings live next to wg0.conf
# (its cron job, if any, runs it from there).
WG_FILE="$QBITTORRENT_WIREGUARD_DIR/wg0.conf"
AIRVPN_WG="$QBITTORRENT_WIREGUARD_DIR/airvpn-wg.sh"
AIRVPN_WG_URL="https://raw.githubusercontent.com/serversathome/ServersatHome/refs/heads/main/airvpn-wg.sh"
create_directory "$QBITTORRENT_WIREGUARD_DIR"

# paste_wg — read a pasted wg0.conf and save it.
paste_wg() {
    local conf
    echo "Paste your WireGuard configuration below using SHIFT+INS (press ENTER then Ctrl+D when done):"
    conf=$(cat)
    conf=${conf//$'\r'/}    # a config copied from Windows keeps CRLF line ends
    if [ -z "${conf//[[:space:]]/}" ]; then
        todo "No WireGuard configuration entered. qBittorrent will not start until $WG_FILE exists."
        return
    fi
    grep -q '^\[Interface\]' <<<"$conf" && grep -q '^\[Peer\]' <<<"$conf" \
        || warn "That does not look like a WireGuard config (no [Interface]/[Peer] sections); saving it anyway."
    printf '%s\n' "$conf" > "$WG_FILE"
    chown root:apps "$WG_FILE"
    chmod 660 "$WG_FILE"
    ok "WireGuard configuration saved to $WG_FILE"
}

# fetch_airvpn_wg — put the latest airvpn-wg.sh in the wireguard folder: the
# repo's, else (offline) keep the one already there, else the copy next to
# this script. Its monitor cron job runs that copy, so re-runs refresh it.
# Prints what happened; returns 1 if there is no copy at all.
fetch_airvpn_wg() {
    local local_copy
    local_copy="$(cd "$(dirname "$0")" && pwd)/airvpn-wg.sh"
    if curl -fsSL -m 60 "$AIRVPN_WG_URL" -o "$AIRVPN_WG.tmp" && grep -q '^# AirVPN WireGuard config generator' "$AIRVPN_WG.tmp"; then
        if [ -f "$AIRVPN_WG" ] && cmp -s "$AIRVPN_WG.tmp" "$AIRVPN_WG"; then
            rm -f "$AIRVPN_WG.tmp"
        else
            [ -f "$AIRVPN_WG" ] && ok "airvpn-wg.sh updated to the latest version (its monitor cron job runs it)"
            mv "$AIRVPN_WG.tmp" "$AIRVPN_WG"
        fi
    else
        rm -f "$AIRVPN_WG.tmp"
        # Offline: keep a working installed copy rather than swap in whatever
        # sits next to this script, which may be older.
        if [ -f "$AIRVPN_WG" ]; then
            warn "Could not download the latest airvpn-wg.sh; keeping the copy in $QBITTORRENT_WIREGUARD_DIR."
        elif [ -f "$local_copy" ]; then
            warn "Could not download the latest airvpn-wg.sh; using the copy next to arr-complete.sh."
            cp "$local_copy" "$AIRVPN_WG"
        else
            return 1
        fi
    fi
    chown root:root "$AIRVPN_WG"
    chmod 700 "$AIRVPN_WG"
}

# airvpn_wg — fetch airvpn-wg.sh into the wireguard folder and run it
# interactively.
airvpn_wg() {
    fetch_airvpn_wg || { todo "Could not download airvpn-wg.sh ($AIRVPN_WG_URL). Paste a wg0.conf into $WG_FILE, or download it and run: bash airvpn-wg.sh --output $WG_FILE"; return; }
    echo ""
    AIRVPN_WG_EMBEDDED=1 bash "$AIRVPN_WG" --output "$WG_FILE"
    if [ -s "$WG_FILE" ]; then
        WG_FROM_AIRVPN=1
    else
        todo "No WireGuard config was generated. Re-run: bash $AIRVPN_WG --output $WG_FILE (or paste one into that file)."
    fi
}

WG_FROM_AIRVPN=0
if [ -s "$WG_FILE" ]; then
    echo "WireGuard config already present at $WG_FILE (leaving it alone)."
    if [ -f "$AIRVPN_WG" ]; then
        fetch_airvpn_wg
        echo "  To pick another AirVPN server or change alerts: bash $AIRVPN_WG --output $WG_FILE"
    fi
else
    echo ""
    echo "qBittorrent needs a WireGuard config (wg0.conf) for its VPN:"
    echo "  1) Paste a wg0.conf from your VPN provider"
    echo "  2) Auto-generate a wg0.conf for me (AirVPN only, needs an API key)"
    echo "  3) Skip for now"
    while :; do
        # End of input (nothing left to read) counts as skip instead of looping.
        read -rp "Choose [1-3]: " answer || answer=3
        case "$answer" in
            1) paste_wg; break ;;
            2) airvpn_wg; break ;;
            3) todo "No WireGuard config yet. qBittorrent will not start until $WG_FILE exists (paste one there, or generate one: bash airvpn-wg.sh --output $WG_FILE)."; break ;;
            *) echo "Please enter 1, 2 or 3." ;;
        esac
    done
    unset answer
fi

# Forwarded port: asked here, after the VPN config, since only a launch uses
# it. qBittorrent's stack was written with the saved value; it is rewritten
# (backing up the old file, as write_stack does) only if the answer changes.
echo ""
echo "qBittorrent VPN port forwarding (optional): if your VPN provider gave you a fixed"
echo "forwarded port (AirVPN: Client Area -> Forwarded Ports), enter it and qBittorrent"
echo "listens on it. Enter keeps the value in brackets."
QB_PORT_WRITTEN=$QB_FORWARDED_PORT
while :; do
    read -rp "  Forwarded port [${QB_FORWARDED_PORT:-none}]: " answer || break
    [ -z "$answer" ] && break
    if [ "$answer" = none ]; then QB_FORWARDED_PORT=""; break; fi
    if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le 65535 ]; then QB_FORWARDED_PORT="$answer"; break; fi
    echo "  A number between 1 and 65535, Enter to keep, or 'none' for no forwarded port."
done
unset answer
if [ "$QB_FORWARDED_PORT" != "$QB_PORT_WRITTEN" ]; then
    write_qbittorrent_stack
    save_answers
    if [ -n "$QB_FORWARDED_PORT" ]; then ok "qBittorrent stack updated for forwarded port $QB_FORWARDED_PORT"
    else ok "qBittorrent stack updated: no forwarded port"; fi
fi

# The shared network, once.
if docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
    echo "Docker network '$DOCKER_NETWORK' already exists."
else
    docker network create "$DOCKER_NETWORK" >/dev/null || die "Could not create the Docker network '$DOCKER_NETWORK'."
    echo "Docker network '$DOCKER_NETWORK' created."
fi

# Trawl replaced FlareSolverr. On an install made before that, take the old
# stack down (it holds port 8191) and move its compose file out of stacks/ so
# Dockge stops listing it; FlareSolverr kept no data.
if [ -f "$STACKS_PATH/flaresolverr/compose.yaml" ] || docker container inspect flaresolverr >/dev/null 2>&1; then
    echo "Replacing FlareSolverr with Trawl..."
    if [ -f "$STACKS_PATH/flaresolverr/compose.yaml" ]; then
        docker compose -f "$STACKS_PATH/flaresolverr/compose.yaml" down >/dev/null 2>&1
        mv "$STACKS_PATH/flaresolverr/compose.yaml" "$STACKS_PATH/flaresolverr-compose.yaml.bak-$(date +%Y%m%d-%H%M%S)"
        rmdir "$STACKS_PATH/flaresolverr" 2>/dev/null \
            || warn "stacks/flaresolverr still holds other files; Dockge may keep listing it."
    fi
    docker rm -f flaresolverr >/dev/null 2>&1
    ok "FlareSolverr removed (its compose file is kept in $STACKS_PATH as flaresolverr-compose.yaml.bak-*)"
fi

# Each stack is its own compose project, named after its directory (that is
# what Dockge expects to find).
echo "Launching the stacks from $STACKS_PATH..."
for stack in "${STACKS[@]}"; do
    docker compose -f "$STACKS_PATH/$stack/compose.yaml" up -d \
        || todo "The '$stack' stack did not launch. Check: docker compose -f $STACKS_PATH/$stack/compose.yaml logs"
done
echo "Stacks launched."

# ============================================================================
#                           AUTO-CONFIGURATION PHASE
#
# Containers talk to each other by container name over the shared "arr"
# network (radarr, sonarr, qbittorrent, ...). This script talks to them from
# the TrueNAS shell through the published ports on localhost.
# ============================================================================
export ADMIN_USER ADMIN_PASS ADMIN_EMAIL

QB_URL="http://localhost:8080"
RADARR_URL="http://localhost:7878";   RADARR_INT="http://radarr:7878"
SONARR_URL="http://localhost:8989";   SONARR_INT="http://sonarr:8989"
PROWLARR_URL="http://localhost:9696"; PROWLARR_INT="http://prowlarr:9696"
TRAWL_URL="http://localhost:8191";    TRAWL_INT="http://trawl:8191/"
PROFILARR_URL="http://localhost:6868"
JELLYFIN_URL="http://localhost:8096"; JELLYFIN_INT="http://jellyfin:8096"
SEERR_URL="http://localhost:5055";    SEERR_INT="http://seerr:5055"
BAZARR_URL="http://localhost:6767"
QUI_URL="http://localhost:7476"
TRACEARR_URL="http://localhost:3000"
DOCKGE_URL="http://localhost:5001"
QB_INT="http://qbittorrent:8080"

# ── Shared *arr helpers (Radarr / Sonarr / Prowlarr share one API shape) ────
# arr_api <base-url> <api-key> <method> <path> [json-body]
arr_api() {
    local base="$1" key="$2" method="$3" path="$4" body="${5-}"
    http "$method" "$base$path" "$body" -H "X-Api-Key: $key" -H 'Content-Type: application/json'
}

# arr_key <app> -> prints the API key from the app's config.xml (waits for it)
arr_key() {
    local app="$1" cfg="$CONFIGS_PATH/$1/config.xml"
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
            out=$(qb_login_result "$(docker exec "$app" curl -sS -m 10 -w $'\n%{http_code}' --data-urlencode "username=$ADMIN_USER" --data-urlencode "password=$ADMIN_PASS" "$QB_INT/api/v2/auth/login" 2>&1)")
            echo "    probe: login as $ADMIN_USER from inside '$app' -> $out  (Ok. = good; Fails. = wrong password; banned = too many failed logins, 1h)"
        fi
    else
        echo "    probe: no curl inside '$app'; cannot test the path to qBittorrent from there"
    fi
    log=$(find "$CONFIGS_PATH/qbittorrent" -name 'qbittorrent.log' 2>/dev/null | head -1)
    if [ -n "$log" ]; then
        echo "    qBittorrent log, last WebUI lines:"
        grep -iE 'webui|webapi|banned|host header' "$log" | tail -5 | sed 's/^/      /'
    fi
}

# arr_add_qbittorrent <app> <base-url> <api-key> <category-field> <category>
# Builds the client from the app's own schema so field names stay correct.
# The client is tested first (POST .../test) and only a passing one is
# saved; forceSave then skips the save-time validation. The container name
# is tried first, then the TrueNAS LAN address through the published port
# as a fallback, and the real error is printed either way.
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
# qb_login_result <curl output ending in "\n<http code>"> -> "Ok." | "Fails." | "banned [HTTP 403]" | "<body> [HTTP code]"
# The login API changed in qBittorrent 5.2: a good login answers 204 No
# Content (older versions: 200 "Ok."), a bad one 401 (older: 200 "Fails."),
# and a banned address 403 in both. Judge by the status code first.
qb_login_result() {
    local out="$1" code body
    code="${out##*$'\n'}"; body="${out%$'\n'*}"; [ "$body" = "$out" ] && body=""
    case "$code" in
        2??) if [ "$body" = "Fails." ]; then echo "Fails."; else echo "Ok."; fi ;;
        401) echo "Fails." ;;
        403) echo "banned [HTTP 403]" ;;
        *)   printf '%s [HTTP %s]\n' "$(printf '%s' "$body" | tr -d '\r' | head -c 100)" "${code:-none}" ;;
    esac
}
qb_login() {  # qb_login <user> <pass> -> session cookie in $QB_COOKIE on success
    local out
    out=$(qb_curl -c "$QB_COOKIE" -w $'\n%{http_code}' --data-urlencode "username=$1" --data-urlencode "password=$2" "$QB_URL/api/v2/auth/login" 2>/dev/null)
    [ "$(qb_login_result "$out")" = "Ok." ]
}
qb_post()  { qb_curl -b "$QB_COOKIE" "$@"; }   # qb_post <form args...> <url>
qb_code()  { qb_post -o /dev/null -w '%{http_code}' "$@" 2>/dev/null; }   # HTTP status of a logged-in call
qb_2xx()   { case "$1" in 2??) return 0 ;; *) return 1 ;; esac; }   # qBittorrent 5.2 answers 204 where older versions answered 200
# qb_login_from_host <user> <pass> -> "Ok." | "Fails." | "banned [HTTP 403]" | "<error> [HTTP code]"
# A real credential check: the request enters through the published port.
qb_login_from_host() {
    local out
    out=$(curl -sS -m 15 -w $'\n%{http_code}' --data-urlencode "username=$1" --data-urlencode "password=$2" "$QB_URL/api/v2/auth/login" 2>&1)
    qb_login_result "$out"
}
qb_pref() { printf '%s' "$1" | jpy "d.get('$2')"; }

configure_qbittorrent() {
    info "[1/12] qBittorrent"
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
        qb_2xx "$code" || { todo "qBittorrent: setPreferences for the WebUI login returned HTTP $code; set $ADMIN_USER / $ADMIN_PASS in Tools > Options > WebUI."; return 1; }
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
    # straight into /media/downloads (no per-category subfolders), incomplete
    # ones and .torrent files in /media/downloads/torrent.
    code=$(qb_code --data-urlencode 'json={"save_path":"/media/downloads","temp_path_enabled":true,"temp_path":"/media/downloads/torrent","export_dir":"/media/downloads/torrent","auto_tmm_enabled":true,"torrent_content_layout":"Original"}' \
        "$QB_URL/api/v2/app/setPreferences")
    if qb_2xx "$code"; then ok "qBittorrent: save paths set (/media/downloads, incomplete in /media/downloads/torrent)"; else
        todo "qBittorrent: could not set the save paths (HTTP $code); set them in Tools > Options > Downloads."; fi

    # WebUI: bypass authentication for clients on localhost. Set only after the
    # real login was verified from the host above, because from here on a
    # loopback login succeeds with any password.
    code=$(qb_code --data-urlencode 'json={"bypass_local_auth":true}' "$QB_URL/api/v2/app/setPreferences")
    if qb_2xx "$code"; then ok "qBittorrent: bypass authentication for clients on localhost enabled"; else
        todo "qBittorrent: could not enable the localhost authentication bypass (HTTP $code); tick it in Tools > Options > WebUI."; fi

    # Connection / BitTorrent / Advanced per wiki.serversatho.me/en/qBittorrent:
    # no connection limits (-1 = box unchecked), no torrent queueing, more
    # parallel checking, all torrent traffic bound to the VPN interface on
    # every IPv4 address, and the Default disk IO type (0), which on hotio's
    # default libtorrent 2.1 build is pread/pwrite. Installs made when this
    # script set POSIX-compliant (2) are moved back to Default;
    # qBittorrent reads it at startup, so it applies from the next restart
    # (Watchtower's next update, or: docker restart qbittorrent).
    code=$(qb_code --data-urlencode 'json={"max_connec":-1,"max_connec_per_torrent":-1,"max_uploads":-1,"max_uploads_per_torrent":-1,"queueing_enabled":false,"max_active_checking_torrents":3,"current_network_interface":"wg0","current_interface_address":"0.0.0.0","disk_io_type":0}' \
        "$QB_URL/api/v2/app/setPreferences")
    if qb_2xx "$code"; then ok "qBittorrent: connection limits off, queueing off, 3 checking torrents, interface wg0 / all IPv4, disk IO type Default (pread/pwrite)"; else
        todo "qBittorrent: could not apply the connection/advanced settings (HTTP $code); set them in Tools > Options."; fi

    # Categories for Radarr and Sonarr, both saving straight into
    # /media/downloads. The path is set explicitly: a category with an empty
    # save path would make qBittorrent use /media/downloads/<category>. An
    # existing category (earlier run) is re-pointed with editCategory.
    local cat cats cur
    cats=$(qb_post "$QB_URL/api/v2/torrents/categories" 2>/dev/null)
    for cat in radarr sonarr; do
        if [ "$(printf '%s' "$cats" | jpy "'$cat' in d")" = "True" ]; then
            cur=$(printf '%s' "$cats" | jpy "d['$cat'].get('savePath')")
            if [ "$cur" = "/media/downloads" ]; then ok "qBittorrent: category '$cat' already saves to /media/downloads"; continue; fi
            # editCategory answers 409 when nothing changes, hence the check above.
            code=$(qb_code --data-urlencode "category=$cat" --data-urlencode "savePath=/media/downloads" "$QB_URL/api/v2/torrents/editCategory")
            if qb_2xx "$code"; then ok "qBittorrent: category '$cat' save path changed from '${cur:-<default>}' to /media/downloads"; else
                warn "qBittorrent: could not change the save path of category '$cat' (HTTP $code); set it to /media/downloads in the WebUI"; fi
            continue
        fi
        code=$(qb_code --data-urlencode "category=$cat" --data-urlencode "savePath=/media/downloads" "$QB_URL/api/v2/torrents/createCategory")
        if qb_2xx "$code"; then ok "qBittorrent: category '$cat' -> /media/downloads"; else
            warn "qBittorrent: could not create category '$cat' (HTTP $code)"; fi
    done
    [ "$QB_MODE" = "exec" ] && docker exec qbittorrent rm -f "$QB_COOKIE" >/dev/null 2>&1
    rm -f "$QB_COOKIE"
}

# ── 2/3. Radarr and Sonarr ──────────────────────────────────────────────────
configure_radarr() {
    info "[2/12] Radarr"
    RADARR_API_KEY=$(arr_key radarr) || { todo "Radarr: config.xml never appeared; skipping."; return 1; }
    wait_for "Radarr API" 180 bash -c "curl -fs -H 'X-Api-Key: $RADARR_API_KEY' $RADARR_URL/api/v3/system/status -o /dev/null" \
        || { todo "Radarr API not responding; skipping."; return 1; }
    arr_enable_forms_auth Radarr "$RADARR_URL" "$RADARR_API_KEY" v3
    arr_add_root_folder   Radarr "$RADARR_URL" "$RADARR_API_KEY" /media/movies
    arr_add_qbittorrent   Radarr "$RADARR_URL" "$RADARR_API_KEY" movieCategory radarr
}

configure_sonarr() {
    info "[3/12] Sonarr"
    SONARR_API_KEY=$(arr_key sonarr) || { todo "Sonarr: config.xml never appeared; skipping."; return 1; }
    wait_for "Sonarr API" 180 bash -c "curl -fs -H 'X-Api-Key: $SONARR_API_KEY' $SONARR_URL/api/v3/system/status -o /dev/null" \
        || { todo "Sonarr API not responding; skipping."; return 1; }
    arr_enable_forms_auth Sonarr "$SONARR_URL" "$SONARR_API_KEY" v3
    arr_add_root_folder   Sonarr "$SONARR_URL" "$SONARR_API_KEY" /media/tv
    arr_add_qbittorrent   Sonarr "$SONARR_URL" "$SONARR_API_KEY" tvCategory sonarr
}

# ── 4. Trawl ────────────────────────────────────────────────────────────────
configure_trawl() {
    info "[4/12] Trawl"
    # It starts a browser before it answers; give it time.
    if wait_for "Trawl" 180 bash -c "curl -fs $TRAWL_URL/health -o /dev/null"; then ok "Trawl is up (nothing to configure; dashboard at http://$HOST_IP:8191/dashboard)"
    else todo "Trawl did not respond on :8191 (docker logs trawl); Prowlarr's proxy test may fail."; fi
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
    info "[5/12] Prowlarr"
    PROWLARR_API_KEY=$(arr_key prowlarr) || { todo "Prowlarr: config.xml never appeared; skipping."; return 1; }
    wait_for "Prowlarr API" 180 bash -c "curl -fs -H 'X-Api-Key: $PROWLARR_API_KEY' $PROWLARR_URL/api/v1/system/status -o /dev/null" \
        || { todo "Prowlarr API not responding; skipping."; return 1; }
    arr_enable_forms_auth Prowlarr "$PROWLARR_URL" "$PROWLARR_API_KEY" v1

    # Trawl as an indexer proxy, applied to indexers tagged "flaresolverr".
    # Prowlarr has no Trawl type: Trawl speaks the FlareSolverr API, so it is a
    # FlareSolverr proxy pointed at trawl:8191. The tag keeps its name, so
    # indexers already tagged on an older install keep using the proxy.
    local have tag_id body
    have=$(arr_api "$PROWLARR_URL" "$PROWLARR_API_KEY" GET /api/v1/indexerproxy | jpy "next((p for p in d if p['implementation']=='FlareSolverr'), None)")
    if [ -n "$have" ]; then
        # Present from a FlareSolverr install: repoint it at Trawl.
        if [ "$(printf '%s' "$have" | jpy "next((f.get('value') for f in d['fields'] if f['name']=='host'), '')")" = "$TRAWL_INT" ]; then
            ok "Prowlarr: Trawl proxy already present"
        else
            body=$(printf '%s' "$have" | TRAWL_INT="$TRAWL_INT" python3 -c '
import json, os, sys
t = json.load(sys.stdin)
for f in t["fields"]:
    if f["name"] == "host": f["value"] = os.environ["TRAWL_INT"]
t["name"] = "Trawl"
print(json.dumps(t))')
            arr_api "$PROWLARR_URL" "$PROWLARR_API_KEY" PUT "/api/v1/indexerproxy/$(printf '%s' "$have" | jpy "d['id']")?forceSave=true" "$body" >/dev/null
            if http_ok; then ok "Prowlarr: FlareSolverr proxy now points at Trawl ($TRAWL_INT)"
            else todo "Prowlarr: could not repoint the FlareSolverr proxy at Trawl (HTTP $(http_code)); set its host to $TRAWL_INT in Settings > Indexers."; fi
        fi
    else
        tag_id=$(prowlarr_tag_id flaresolverr)
        body=$(arr_api "$PROWLARR_URL" "$PROWLARR_API_KEY" GET /api/v1/indexerproxy/schema \
            | TAG_ID="${tag_id:-0}" TRAWL_INT="$TRAWL_INT" python3 -c '
import json, os, sys
t = next(x for x in json.load(sys.stdin) if x.get("implementation") == "FlareSolverr")
for f in t["fields"]:
    if f["name"] == "host": f["value"] = os.environ["TRAWL_INT"]
    if f["name"] == "requestTimeout": f["value"] = 60
t.update(name="Trawl", tags=[int(os.environ["TAG_ID"])] if int(os.environ["TAG_ID"]) else [])
t.pop("id", None)
print(json.dumps(t))')
        arr_api "$PROWLARR_URL" "$PROWLARR_API_KEY" POST '/api/v1/indexerproxy?forceSave=true' "$body" >/dev/null
        if http_ok; then ok "Prowlarr: Trawl proxy added (tag 'flaresolverr')"; else todo "Prowlarr: could not add the Trawl proxy (HTTP $(http_code))."; fi
    fi

    [ -n "$RADARR_API_KEY" ] && prowlarr_add_app Radarr "$RADARR_INT" "$RADARR_API_KEY"
    [ -n "$SONARR_API_KEY" ] && prowlarr_add_app Sonarr "$SONARR_INT" "$SONARR_API_KEY"
    local n_idx
    n_idx=$(arr_api "$PROWLARR_URL" "$PROWLARR_API_KEY" GET /api/v1/indexer | jpy "len(d)")
    if [ "${n_idx:-0}" = "0" ]; then
        echo "    Prowlarr has no indexers yet: add your trackers in Indexers > Add Indexer (tag Cloudflare-protected ones 'flaresolverr')."
    else
        ok "Prowlarr: $n_idx indexer(s) configured"
    fi
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
    info "[6/12] Profilarr"
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
    profilarr_link_anime_db
    profilarr_sync_all
}

# Second database (wiki section 3): Dumpstarr, the community database built
# on top of Dictionarry and the TRaSH formats. It is the one of the three
# listed catalogs with an anime profile that applies to Radarr and Sonarr
# alike ("Anime 1080p", based on the TRaSH anime profile, dual audio
# preferred). Linked exactly like the stock Dictionarry entry: hourly
# auto-pull (sync_strategy 60 minutes, auto_pull on). Dictionarry stays the
# higher-priority database, so on a name clash its definitions win.
PROFILARR_ANIME_DB="Dumpstarr"
PROFILARR_ANIME_DB_REPO="https://github.com/Dumpstarr/Database"
PROFILARR_ANIME_PROFILE="Anime 1080p"
profilarr_link_anime_db() {
    local dbs
    dbs=$(http GET "$PROFILARR_URL/api/v1/databases" "" -b "$PROFILARR_COOKIE" | jpy "[x['name'] for x in d]")
    if [[ "$dbs" == *"\"$PROFILARR_ANIME_DB\""* ]]; then
        ok "Profilarr: database '$PROFILARR_ANIME_DB' already linked"
    else
        # The API links synchronously (clone + build), so this can take a minute.
        echo "    Profilarr: linking database '$PROFILARR_ANIME_DB' ($PROFILARR_ANIME_DB_REPO)..."
        http POST "$PROFILARR_URL/api/v1/databases" \
            "$(NAME="$PROFILARR_ANIME_DB" REPO="$PROFILARR_ANIME_DB_REPO" jbuild '{"name": os.environ["NAME"], "repository_url": os.environ["REPO"], "sync_strategy": 60, "auto_pull": True}')" \
            -b "$PROFILARR_COOKIE" -H 'Content-Type: application/json' -m 600 >/dev/null
        if http_ok; then ok "Profilarr: database '$PROFILARR_ANIME_DB' linked (auto-pull hourly, like Dictionarry)"
        else todo "Profilarr: linking '$PROFILARR_ANIME_DB' returned HTTP $(http_code); link $PROFILARR_ANIME_DB_REPO under Databases for the anime profile."; return 1; fi
    fi
    # Its profiles only show up once the cache is built.
    wait_for "Profilarr database '$PROFILARR_ANIME_DB'" 300 bash -c "curl -fs -b '$PROFILARR_COOKIE' '$PROFILARR_URL/api/v1/status' | python3 -c \"import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(x['name']=='$PROFILARR_ANIME_DB' and x['counts']['qualityProfiles']>0 for x in d['databases']) else 1)\"" \
        || warn "Profilarr: '$PROFILARR_ANIME_DB' has no profiles yet; the anime profile is picked up on the next run"
}

# profilarr_page_data <page path> -> that page's load data as JSON
# (SvelteKit __data.json is devalue-encoded; decoded generically, layout and
# page data merged).
profilarr_page_data() {
    http GET "$PROFILARR_URL$1/__data.json" "" -b "$PROFILARR_COOKIE" | python3 -c '
import json, sys
raw = json.load(sys.stdin)
SPECIAL = {-1: None, -2: None, -3: float("nan"), -4: float("inf"), -5: float("-inf"), -6: -0.0}
def hydrate(values, i, memo):
    if i in SPECIAL: return SPECIAL[i]
    if i in memo: return memo[i]
    v = values[i]
    if isinstance(v, list):
        if v and isinstance(v[0], str) and v[0] in ("Date","Set","Map","RegExp","Object","BigInt","null","Symbol"):
            out = [hydrate(values, j, memo) for j in v[1:]] if v[0] in ("Set","Map","Object") else v[1:]
        else:
            out = [hydrate(values, j, memo) for j in v]
    elif isinstance(v, dict):
        out = {k: hydrate(values, j, memo) for k, j in v.items()}
    else:
        out = v
    memo[i] = out
    return out
merged = {}
for node in raw.get("nodes") or []:
    if node and node.get("type") == "data":
        data = hydrate(node["data"], 0, {})
        if isinstance(data, dict): merged.update(data)
print(json.dumps(merged))' 2>/dev/null
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
profilarr_saved() {  # profilarr_saved <form action result> -> true when the action succeeded
    http_ok && [[ "$1" == *'"type":"success"'* ]]
}
# profilarr_automation <instance-name> <what> <path?/action> <form args...>
# Saves one of the per-Arr automations (drift detection, renames, cleanup)
# and reports the outcome; the JSON answer carries "type":"success"|"failure".
profilarr_automation() {
    local name="$1" what="$2" path="$3" res; shift 3
    res=$(profilarr_post "$path" "$@")
    if profilarr_saved "$res"; then ok "Profilarr: $name $what enabled"
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
            idle)       return 0 ;;
            failed)     return 1 ;;
            ""|unknown) return 2 ;;
        esac
        sleep 5; waited=$(( waited + 5 ))
        [ "$waited" -ge 600 ] && return 3
    done
}

# Sync to one Arr: every Dictionarry quality profile (their custom formats
# come along) plus the anime profile from the second database, the delay
# profile and the naming / quality-definition / media-settings configs that
# match the Arr.
profilarr_instance_id() {  # profilarr_instance_id <Radarr|Sonarr> -> id ("" if not linked)
    http GET "$PROFILARR_URL/api/v1/arr" "" -b "$PROFILARR_COOKIE" | jpy "next((a['id'] for a in d if a['name']=='$1'), None)"
}

profilarr_sync_instance() {  # profilarr_sync_instance <Radarr|Sonarr>
    local name="$1" id lists res
    id=$(profilarr_instance_id "$name")
    [ -n "$id" ] || { todo "Profilarr: $name is not linked; sync it in the UI."; return 1; }

    # The profile/config names live only in the sync page's load data
    # (SvelteKit __data.json, decoded by profilarr_page_data).
    lists=$(profilarr_page_data "/arr/$id/sync" | NAME="$name" ANIME_DB="$PROFILARR_ANIME_DB" ANIME_PROFILE="$PROFILARR_ANIME_PROFILE" python3 -c '
import json, os, sys
found = (json.load(sys.stdin) or {}).get("databases")
if not isinstance(found, list) or not found: sys.exit(1)
# Dictionarry (the stock database) supplies every profile plus the delay /
# naming / quality-definition / media-settings configs. The anime database
# only contributes its anime profile(s).
db = next((x for x in found if x.get("name") == "Dictionarry"), found[0])
anime_db = next((x for x in found if x.get("name") == os.environ["ANIME_DB"]), None)
names = lambda src, key: [x["name"] for x in (src.get(key) or []) if isinstance(x, dict) and x.get("name")]
sel = [{"databaseId": db["id"], "profileName": n} for n in names(db, "qualityProfiles")]
anime = []
if anime_db:
    qps = names(anime_db, "qualityProfiles")
    anime = [n for n in qps if n == os.environ["ANIME_PROFILE"]] or [n for n in qps if "anime" in n.lower()]
    # Sonarr v5 keeps size limits per profile, so the anime profile can take the
    # anime database'\''s own sizes; everything else uses the instance-wide pick
    # below. On Sonarr v4 and Radarr (global sizes) Profilarr stores and ignores it.
    anime_qdef = (names(anime_db, "qualityDefinitionsConfigs") or [None])[0]
    sel += [dict({"databaseId": anime_db["id"], "profileName": n},
                 **({"qualityDefinitionsConfigName": anime_qdef} if anime_qdef else {})) for n in anime]
# Lower number = higher priority; the last-synced (highest-priority) database wins on clashes.
prio = [{"databaseId": db["id"], "priority": 1}] + ([{"databaseId": anime_db["id"], "priority": 2}] if anime_db else [])
# The database ships one delay/naming/etc. config per app ("Radarr", "Sonarr").
# Prefer the one named after this instance; fall back to the first listed.
app = os.environ["NAME"].lower()
def pick(key):
    xs = names(db, key)
    return next((n for n in xs if app in n.lower()), xs[0] if xs else "")
print(json.dumps({"dbId": db["id"], "db": db.get("name"), "qp": names(db, "qualityProfiles"), "anime": anime, "sel": sel, "prio": prio,
                  "dp": pick("delayProfiles"), "naming": pick("namingConfigs"), "qdef": pick("qualityDefinitionsConfigs"), "media": pick("mediaSettingsConfigs")}))' 2>/dev/null)
    [ -n "$lists" ] || { todo "Profilarr: could not read the Dictionarry profile list for $name; pick profiles under Arrs > $name > Sync."; return 1; }
    local db_id qp_sel qp_prio dp_name naming qdef media anime
    db_id=$(printf '%s' "$lists" | jpy "d['dbId']")
    qp_sel=$(printf '%s' "$lists" | jpy "d['sel']")
    qp_prio=$(printf '%s' "$lists" | jpy "d['prio']")
    dp_name=$(printf '%s' "$lists" | jpy "d['dp']")
    naming=$(printf '%s' "$lists" | jpy "d['naming']")
    qdef=$(printf '%s' "$lists" | jpy "d['qdef']")
    media=$(printf '%s' "$lists" | jpy "d['media']")
    anime=$(printf '%s' "$lists" | jpy "', '.join(d['anime'])")
    echo "    Profilarr/$name: $(printf '%s' "$lists" | jpy "len(d['qp'])") quality profiles from '$(printf '%s' "$lists" | jpy "d['db']")', delay '$dp_name', naming '$naming', quality defs '$qdef', media settings '$media'"
    if [ -n "$anime" ]; then echo "    Profilarr/$name: anime profile '$anime' from '$PROFILARR_ANIME_DB'"
    else warn "Profilarr/$name: no anime profile found in '$PROFILARR_ANIME_DB'; re-run once that database has finished building"; fi

    # Save selections (scheduled daily at 04:00 so later database updates flow
    # through). A form action answers 200 with "type":"failure" when it
    # rejects the input, so the body is checked, not only the status.
    res=$(profilarr_action "$id" saveQualityProfiles --data-urlencode "selections=$qp_sel" --data-urlencode "priorities=$qp_prio" \
        --data-urlencode 'trigger=schedule' --data-urlencode 'cron=0 4 * * *')
    profilarr_saved "$res" || { todo "Profilarr: saving quality profiles for $name failed (HTTP $(http_code)): $(printf '%s' "$res" | head -c 160)"; return 1; }
    if [ -n "$dp_name" ]; then
        res=$(profilarr_action "$id" saveDelayProfiles --data-urlencode "databaseId=$db_id" --data-urlencode "profileName=$dp_name" \
            --data-urlencode 'trigger=schedule' --data-urlencode 'cron=0 4 * * *')
        profilarr_saved "$res" || warn "Profilarr: saving the delay profile for $name failed (HTTP $(http_code)): $(printf '%s' "$res" | head -c 160)"
    fi
    res=$(profilarr_action "$id" saveMediaManagement \
        --data-urlencode "namingDatabaseId=${naming:+$db_id}" --data-urlencode "namingConfigName=$naming" \
        --data-urlencode "qualityDefinitionsDatabaseId=${qdef:+$db_id}" --data-urlencode "qualityDefinitionsConfigName=$qdef" \
        --data-urlencode "mediaSettingsDatabaseId=${media:+$db_id}" --data-urlencode "mediaSettingsConfigName=$media" \
        --data-urlencode 'trigger=schedule' --data-urlencode 'cron=0 4 * * *')
    profilarr_saved "$res" || warn "Profilarr: saving media management for $name failed (HTTP $(http_code)): $(printf '%s' "$res" | head -c 160)"

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
    # (updateCleanup parses enabled as "1"; the drift and rename actions parse "true".)
    profilarr_automation "$name" "cleanup" "/arr/$id/settings?/updateCleanup" \
        --data-urlencode 'enabled=1' --data-urlencode 'cron=0 0 * * 0'
    # First cleanup pass right away (queued as a job; Profilarr runs it).
    local res
    res=$(profilarr_post "/arr/$id/settings?/runCleanupNow")
    if profilarr_saved "$res"; then ok "Profilarr: $name cleanup run queued"
    else warn "Profilarr: could not queue a cleanup run for $name (HTTP $(http_code)): $(printf '%s' "$res" | head -c 160)"; fi
}

# ── Profilarr upgrades (wiki section 4.4) ───────────────────────────────────
# The two "Servers@Home Upgrade Filter" definitions from
# wiki.serversatho.me/en/profilarr#h-441-sample-filters, exactly as the
# page's Import dialog expects them. Radarr searches the 5 lowest-scoring
# monitored, released, below-cutoff movies per run; Sonarr 1 series per run.
PROFILARR_UPGRADE_FILTER_RADARR='{
  "name": "Servers@Home Upgrade Filter",
  "enabled": true,
  "group": {
    "type": "group",
    "match": "all",
    "children": [
      { "type": "rule", "field": "monitored", "operator": "is", "value": true },
      { "type": "rule", "field": "status", "operator": "eq", "value": "released" },
      { "type": "rule", "field": "cutoff_met", "operator": "is", "value": false }
    ]
  },
  "selector": "lowest_score",
  "count": 5,
  "cutoff": 100,
  "tag": ""
}'
PROFILARR_UPGRADE_FILTER_SONARR='{
  "name": "Servers@Home Upgrade Filter",
  "enabled": true,
  "group": {
    "type": "group",
    "match": "all",
    "children": [
      { "type": "rule", "field": "monitored", "operator": "is", "value": true },
      { "type": "group", "match": "any", "children": [
          { "type": "rule", "field": "status", "operator": "eq", "value": "continuing" },
          { "type": "rule", "field": "status", "operator": "eq", "value": "ended" }
      ] },
      { "type": "rule", "field": "cutoff_met", "operator": "is", "value": false },
      { "type": "rule", "field": "episode_file_count", "operator": "gt", "value": 0 }
    ]
  },
  "selector": "lowest_score",
  "count": 1,
  "cutoff": 100,
  "tag": ""
}'


# profilarr_enable_upgrades <Radarr|Sonarr>
# Saves the upgrade config: enabled, every 6 hours (Profilarr's default, the
# rate the sample counts were written for), round-robin, with the sample
# filter added to whatever filters already exist. The filter needs an id;
# the UI's Import generates one, so this does too.
profilarr_enable_upgrades() {
    local name="$1" id cfg filter filters res
    id=$(profilarr_instance_id "$name")
    [ -n "$id" ] || return 1
    cfg=$(profilarr_page_data "/arr/$id/upgrades" | jpy "d.get('config')")
    if [ "$(printf '%s' "${cfg:-null}" | jpy "bool(d.get('enabled')) and any(f.get('name')=='Servers@Home Upgrade Filter' and f.get('enabled') for f in (d.get('filters') or []) if isinstance(f, dict))")" = "True" ]; then
        ok "Profilarr: $name upgrades already enabled with the Servers@Home filter"; return 0
    fi
    if [ "$name" = "Radarr" ]; then filter="$PROFILARR_UPGRADE_FILTER_RADARR"; else filter="$PROFILARR_UPGRADE_FILTER_SONARR"; fi
    filters=$(printf '%s' "$filter" | EXISTING="${cfg:-null}" python3 -c '
import json, os, sys, uuid
new = json.load(sys.stdin)
new["id"] = str(uuid.uuid4())
try:
    old = json.loads(os.environ["EXISTING"]) or {}
    kept = [f for f in (old.get("filters") or []) if isinstance(f, dict) and f.get("name") != new["name"]]
except Exception:
    kept = []
print(json.dumps(kept + [new]))')
    res=$(profilarr_post "/arr/$id/upgrades?/save" --data-urlencode 'enabled=true' --data-urlencode 'cron=0 */6 * * *' \
        --data-urlencode 'filterMode=round_robin' --data-urlencode "filters=$filters")
    if profilarr_saved "$res"; then ok "Profilarr: $name upgrades enabled (Servers@Home Upgrade Filter, every 6 hours)"
    else warn "Profilarr: could not enable upgrades for $name (HTTP $(http_code)): $(printf '%s' "$res" | head -c 200)"; fi
}

profilarr_sync_all() {
    local app
    for app in Radarr Sonarr; do
        profilarr_sync_instance "$app"
        profilarr_enable_automations "$app"
        profilarr_enable_upgrades "$app"
    done
}

# ── 7. Jellyfin ─────────────────────────────────────────────────────────────
JF_AUTH='MediaBrowser Client="truenas-setup", Device="truenas", DeviceId="truenas-setup-script", Version="1.0.0"'
jf_api() {  # jf_api <method> <path> [json] [extra curl args]
    local method="$1" path="$2" body="${3-}"; shift $(( $# < 3 ? $# : 3 ))
    local auth="$JF_AUTH"; [ -n "$JELLYFIN_TOKEN" ] && auth="$JF_AUTH, Token=\"$JELLYFIN_TOKEN\""
    http "$method" "$JELLYFIN_URL$path" "$body" -H "Authorization: $auth" -H 'Content-Type: application/json' "$@"
}

# jf_api_key <app-name> -> a Jellyfin API key named <app-name> (created if missing)
jf_api_key() {
    local app="$1" key
    key=$(jf_api GET /Auth/Keys | jpy "next((k['AccessToken'] for k in d.get('Items', []) if k.get('AppName')=='$app'), None)")
    [ -n "$key" ] && { printf '%s' "$key"; return 0; }
    jf_api POST "/Auth/Keys?app=$app" >/dev/null
    jf_api GET /Auth/Keys | jpy "next((k['AccessToken'] for k in d.get('Items', []) if k.get('AppName')=='$app'), None)"
}

# jf_add_library <name> <collectionType> <path>
# Real-time monitoring is switched on explicitly: Jellyfin's API default for
# an omitted EnableRealtimeMonitor is false (only the web UI ticks it), and
# without it new files only appear at the next scheduled scan (12 h). A
# library from an earlier run gets it switched on in place.
jf_add_library() {
    local name="$1" ctype="$2" path="$3" lib body
    lib=$(jf_api GET /Library/VirtualFolders | jpy "next((v for v in d if v.get('Name')=='$name'), None)")
    if [ -n "$lib" ]; then
        if [ "$(printf '%s' "$lib" | jpy "(d.get('LibraryOptions') or {}).get('EnableRealtimeMonitor')")" = "True" ]; then
            ok "Jellyfin: library '$name' already present (real-time monitoring on)"; return 0
        fi
        body=$(printf '%s' "$lib" | python3 -c '
import json, sys
v = json.load(sys.stdin)
o = v.get("LibraryOptions") or {}
o["EnableRealtimeMonitor"] = True
print(json.dumps({"Id": v["ItemId"], "LibraryOptions": o}))')
        jf_api POST /Library/VirtualFolders/LibraryOptions "$body" >/dev/null
        if http_ok; then ok "Jellyfin: library '$name' already present; real-time monitoring switched on"; else
            todo "Jellyfin: could not switch on real-time monitoring for '$name' (HTTP $(http_code)); tick 'Enable real time monitoring' in Dashboard > Libraries > $name."; fi
        return 0
    fi
    jf_api POST "/Library/VirtualFolders?name=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$name")&collectionType=$ctype&refreshLibrary=true" \
        "{\"LibraryOptions\": {\"EnableRealtimeMonitor\": true, \"PathInfos\": [{\"Path\": \"$path\"}]}}" >/dev/null
    if http_ok; then ok "Jellyfin: library '$name' -> $path (real-time monitoring on)"; else todo "Jellyfin: could not add library '$name' (HTTP $(http_code))."; fi
}

# arr_add_jellyfin <app> <base-url> <api-key> <jellyfin-api-key>
# Settings > Connect > Emby / Jellyfin: after every import, upgrade, rename
# or delete the app tells Jellyfin which folder changed, so new downloads
# show up right away. Both sides see the media under the same /media path,
# so no path mapping is needed. Built from the app's own schema; only a
# connection that passes its test is saved.
arr_add_jellyfin() {
    local app="$1" base="$2" key="$3" jf_key="$4" have body res
    have=$(arr_api "$base" "$key" GET /api/v3/notification | jpy "next((n['name'] for n in d if n['implementation']=='MediaBrowser'), None)")
    if [ -n "$have" ]; then ok "$app: Jellyfin connection already present ('$have')"; return 0; fi
    body=$(arr_api "$base" "$key" GET /api/v3/notification/schema | JF_KEY="$jf_key" python3 -c '
import json, os, sys
t = next(x for x in json.load(sys.stdin) if x.get("implementation") == "MediaBrowser")
vals = {"host": "jellyfin", "port": 8096, "useSsl": False, "urlBase": "",
        "apiKey": os.environ["JF_KEY"], "notify": False, "updateLibrary": True}
for f in t["fields"]:
    if f["name"] in vals:
        f["value"] = vals[f["name"]]
for ev in ("Download", "Upgrade", "Rename", "MovieDelete", "MovieFileDelete", "MovieFileDeleteForUpgrade",
           "SeriesDelete", "EpisodeFileDelete", "EpisodeFileDeleteForUpgrade"):
    if t.get("supportsOn" + ev):
        t["on" + ev] = True
t.update(name="Jellyfin", tags=[])
t.pop("id", None)
print(json.dumps(t))') || { todo "$app: Emby / Jellyfin not found in the connection schema; add it in Settings > Connect."; return 1; }
    res=$(arr_api "$base" "$key" POST /api/v3/notification/test "$body")
    if ! http_ok; then
        todo "$app: Jellyfin connection test failed (HTTP $(http_code)): $(arr_errors "$res"); add Emby / Jellyfin (host jellyfin, port 8096) in Settings > Connect."
        return 1
    fi
    res=$(arr_api "$base" "$key" POST '/api/v3/notification?forceSave=true' "$body")
    if http_ok; then ok "$app: Jellyfin connection added (library refresh on import, upgrade, rename and delete)"; else
        todo "$app: could not add the Jellyfin connection (HTTP $(http_code)): $(arr_errors "$res"); add Emby / Jellyfin in Settings > Connect."; fi
}

# Radarr and Sonarr come before Jellyfin in the install order, so their
# Jellyfin connections are added here, once Jellyfin can hand out an API key.
jellyfin_connect_arrs() {
    [ -n "$RADARR_API_KEY$SONARR_API_KEY" ] || return 0
    local jf_key
    jf_key=$(jf_api_key radarr-sonarr)
    [ -n "$jf_key" ] || { todo "Jellyfin: could not create an API key for Radarr and Sonarr; add Emby / Jellyfin in Settings > Connect in both."; return 1; }
    [ -n "$RADARR_API_KEY" ] && arr_add_jellyfin Radarr "$RADARR_URL" "$RADARR_API_KEY" "$jf_key"
    [ -n "$SONARR_API_KEY" ] && arr_add_jellyfin Sonarr "$SONARR_URL" "$SONARR_API_KEY" "$jf_key"
    return 0
}

configure_jellyfin() {
    info "[7/12] Jellyfin"
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
    jellyfin_connect_arrs
    jellyfin_configure_transcoding
}

# Hardware transcoding (Dashboard > Playback > Transcoding), from the probe
# at the top of the script. Jellyfin keeps the whole encoding configuration
# as one object: read it, change only the hardware fields, write it back.
jellyfin_configure_transcoding() {
    local cfg body accel_now
    cfg=$(jf_api GET /System/Configuration/encoding)
    http_ok || { todo "Jellyfin: could not read the encoding settings (HTTP $(http_code)); check Dashboard > Playback > Transcoding."; return 1; }
    if [ "$GPU_VENDOR" = "none" ]; then
        # The stack was just written without GPU passthrough, so hardware
        # settings left over from an earlier run would fail every transcode.
        accel_now=$(printf '%s' "$cfg" | jpy "d.get('HardwareAccelerationType')")
        if [ -n "$accel_now" ] && [ "$accel_now" != "none" ]; then
            body=$(printf '%s' "$cfg" | jpy "dict(d, HardwareAccelerationType='none', EnableHardwareEncoding=False, HardwareDecodingCodecs=[])")
            jf_api POST /System/Configuration/encoding "$body" >/dev/null
            if http_ok; then todo "Jellyfin: no usable GPU on this run, so the '$accel_now' transcoding settings from an earlier run were switched back to software (the container no longer has the device). Re-run once the GPU is back.${GPU_NOTE:+ ($GPU_NOTE)}"
            else todo "Jellyfin: no usable GPU on this run, but the '$accel_now' transcoding settings from an earlier run are still active and could not be reset (HTTP $(http_code)); set Hardware acceleration to None in Dashboard > Playback > Transcoding.${GPU_NOTE:+ ($GPU_NOTE)}"; fi
        else
            ok "Jellyfin: no usable GPU; software transcoding${GPU_NOTE:+ ($GPU_NOTE)}"
        fi
        return 0
    fi
    body=$(printf '%s' "$cfg" | ACCEL="$GPU_ACCEL" VENDOR="$GPU_VENDOR" RENDER="$GPU_RENDER" DEC="$GPU_DEC" ENC="$GPU_ENC" LP="$GPU_LP" \
        HEVC10="$GPU_HEVC10" VP9_10="$GPU_VP9_10" REXT10="$GPU_REXT10" REXT12="$GPU_REXT12" TONEMAP="$GPU_TONEMAP" VPP="$GPU_VPP" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
e = os.environ
dec = [c for c in e["DEC"].split(",") if c]; enc = [c for c in e["ENC"].split(",") if c]; lp = [c for c in e["LP"].split(",") if c]
d["HardwareAccelerationType"] = e["ACCEL"]
d["HardwareDecodingCodecs"] = dec
d["EnableDecodingColorDepth10Hevc"] = e["HEVC10"] == "1" and "hevc" in dec
d["EnableDecodingColorDepth10Vp9"] = e["VP9_10"] == "1" and "vp9" in dec
d["EnableDecodingColorDepth10HevcRext"] = e["REXT10"] == "1"
d["EnableDecodingColorDepth12HevcRext"] = e["REXT12"] == "1"
d["EnableHardwareEncoding"] = "h264" in enc
d["AllowHevcEncoding"] = "hevc" in enc
d["AllowAv1Encoding"] = "av1" in enc
d["EnableTonemapping"] = e["TONEMAP"] == "1"
d["EnableVppTonemapping"] = e["VENDOR"] == "intel" and e["VPP"] == "1"
d["PreferSystemNativeHwDecoder"] = True
d["EnableEnhancedNvdecDecoder"] = e["VENDOR"] == "nvidia"
d["EnableIntelLowPowerH264HwEncoder"] = e["VENDOR"] == "intel" and "h264" in lp
d["EnableIntelLowPowerHevcHwEncoder"] = e["VENDOR"] == "intel" and "hevc" in lp
if e["VENDOR"] in ("intel", "amd"):
    d["VaapiDevice"] = e["RENDER"]
if e["VENDOR"] == "intel":
    d["QsvDevice"] = e["RENDER"]
print(json.dumps(d))')
    [ -n "$body" ] || { todo "Jellyfin: could not build the encoding settings from what the server returned; set $GPU_ACCEL transcoding in Dashboard > Playback > Transcoding."; return 1; }
    jf_api POST /System/Configuration/encoding "$body" >/dev/null
    http_ok || { todo "Jellyfin: saving the encoding settings returned HTTP $(http_code); set $GPU_ACCEL transcoding in Dashboard > Playback > Transcoding."; return 1; }
    # Read it back: the server answers 204 before anything is checked, so the
    # only proof is what it reports afterwards.
    local readback
    readback=$(jf_api GET /System/Configuration/encoding)
    accel_now=$(printf '%s' "$readback" | jpy "d.get('HardwareAccelerationType')")
    if [ "$accel_now" = "$GPU_ACCEL" ]; then
        ok "Jellyfin: hardware transcoding set to $GPU_ACCEL (${GPU_NAME:-$GPU_VENDOR}): decode [${GPU_DEC:-none}], encode [${GPU_ENC:-none}], HDR tone mapping $(gpu_tonemap_summary)"
        echo "    Jellyfin reports: $(printf '%s' "$readback" | jpy "f\"acceleration={d.get('HardwareAccelerationType')}, device={d.get('QsvDevice') or d.get('VaapiDevice')}, decode={','.join(d.get('HardwareDecodingCodecs') or [])}, hw encode={d.get('EnableHardwareEncoding')}, HEVC encode={d.get('AllowHevcEncoding')}, AV1 encode={d.get('AllowAv1Encoding')}, tone mapping={d.get('EnableTonemapping')}, VPP tone mapping={d.get('EnableVppTonemapping')}\"")"
        echo "    (Dashboard > Playback > Transcoding; reload the page if it was already open.)"
        if [ "$GPU_TONEMAP" != 1 ] && [ "$GPU_VPP" != 1 ]; then
            warn "Jellyfin: no tone mapping is available on this GPU/driver, so HDR video is transcoded without it (colors look washed out on SDR screens)."
        elif [ "$GPU_TONEMAP" != 1 ]; then
            echo "    Jellyfin: HDR10 is tone mapped by the Intel driver (VPP). The image has no OpenCL runtime, so HLG and Dolby Vision content is transcoded without tone mapping."
        fi
    else
        todo "Jellyfin: accepted the encoding settings (HTTP $(http_code)) but reads back acceleration '${accel_now:-?}' instead of '$GPU_ACCEL'; set $GPU_ACCEL transcoding in Dashboard > Playback > Transcoding. Sent: $(printf '%s' "$body" | head -c 300)"
    fi
}

# ── 8. Seerr ────────────────────────────────────────────────────────────────
SEERR_COOKIE="$COOKIE_DIR/seerr.cookie"
seerr_api() {  # seerr_api <method> <path> [json]
    http "$1" "$SEERR_URL$2" "${3-}" -b "$SEERR_COOKIE" -c "$SEERR_COOKIE" -H 'Content-Type: application/json'
}

# seerr_add_arr <radarr|sonarr> <internal-host> <port> <api-key> <root>
# Quality profile: "1080p Balanced" from Profilarr/Dictionarry, else any other
# synced 1080p profile, else the stock HD-1080p. Sonarr also gets the anime
# profile ("Anime 1080p"). An entry that already exists but still sits on a
# stock profile (Seerr configured before the Profilarr sync had landed) is
# updated in place.
SEERR_STOCK_PROFILES="{'Any', 'SD', 'HD-720p', 'HD-1080p', 'Ultra-HD', 'HD - 720p/1080p'}"   # a python set literal
seerr_add_arr() {
    local app="$1" host="$2" port="$3" key="$4" root="$5" existing cur_profile cur_anime test body id
    existing=$(seerr_api GET "/api/v1/settings/$app" | jpy "next((s for s in d if s['hostname']=='$host'), None)")
    if [ -n "$existing" ]; then
        cur_profile=$(printf '%s' "$existing" | jpy "d.get('activeProfileName')")
        cur_anime=$(printf '%s' "$existing" | jpy "d.get('activeAnimeProfileName') or ''")
        # Done when the default profile is a Profilarr one and, for Sonarr,
        # the anime profile is set to a Profilarr one too.
        if [ "$(printf '%s' "$existing" | jpy "d.get('activeProfileName') not in $SEERR_STOCK_PROFILES and ('$app' != 'sonarr' or (d.get('activeAnimeProfileName') or 'Any') not in $SEERR_STOCK_PROFILES)")" = "True" ]; then
            ok "Seerr: ${app^} already configured (profile '$cur_profile'${cur_anime:+, anime $cur_anime})"; return 0
        fi
        echo "    Seerr: ${app^} is on the stock profile '$cur_profile'${cur_anime:+ (anime $cur_anime)}; looking for Profilarr profiles..."
    fi
    test=$(seerr_api POST "/api/v1/settings/$app/test" "$(APP_HOST="$host" APP_PORT="$port" APP_KEY="$key" jbuild '{"hostname": os.environ["APP_HOST"], "port": int(os.environ["APP_PORT"]), "apiKey": os.environ["APP_KEY"], "useSsl": False, "baseUrl": ""}')")
    http_ok || { todo "Seerr: could not reach ${app^} for its profile list (HTTP $(http_code)); add it in Settings > Services."; return 1; }
    body=$(printf '%s' "$test" | APP="$app" APP_HOST="$host" APP_PORT="$port" APP_KEY="$key" WANT_ROOT="$root" EXISTING="$existing" ANIME_PROFILE="$PROFILARR_ANIME_PROFILE" STOCK="$SEERR_STOCK_PROFILES" python3 -c '
import ast, json, os, sys
d = json.load(sys.stdin)
stock = ast.literal_eval(os.environ["STOCK"])
profiles = d.get("profiles") or []
pick = (next((p for p in profiles if p["name"] == "1080p Balanced"), None)
        or next((p for p in profiles if "1080" in p["name"] and p["name"] not in stock), None)
        or next((p for p in profiles if p["name"] == "HD-1080p"), None)
        or (profiles[0] if profiles else None))
if not pick:
    sys.exit("no quality profiles")
roots = [r["path"] for r in (d.get("rootFolders") or [])]
root = os.environ["WANT_ROOT"] if os.environ["WANT_ROOT"] in roots else (roots[0] if roots else os.environ["WANT_ROOT"])
# Sonarr only: Seerr routes anime requests to a separate quality profile.
# Use the Profilarr one ("Anime 1080p" from the anime database), else any
# profile with "anime" in its name. With neither, the anime fields are left
# unset (Seerr then uses the default profile) so a re-run can still set them.
anime = None
if os.environ["APP"] == "sonarr":
    anime = (next((p for p in profiles if p["name"] == os.environ["ANIME_PROFILE"]), None)
             or next((p for p in profiles if "anime" in p["name"].lower()), None))
existing = json.loads(os.environ["EXISTING"]) if os.environ["EXISTING"] else None
if existing:
    body = dict(existing, activeProfileId=pick["id"], activeProfileName=pick["name"])
else:
    body = {"name": os.environ["APP"].capitalize(), "hostname": os.environ["APP_HOST"], "port": int(os.environ["APP_PORT"]),
            "apiKey": os.environ["APP_KEY"], "useSsl": False, "baseUrl": "", "activeProfileId": pick["id"],
            "activeProfileName": pick["name"], "activeDirectory": root, "is4k": False, "tags": [], "isDefault": True,
            "externalUrl": "", "syncEnabled": True, "preventSearch": False, "tagRequests": False}
    if os.environ["APP"] == "radarr":
        body["minimumAvailability"] = "released"
    else:
        body.update(enableSeasonFolders=True, seriesType="standard", animeSeriesType="anime", animeTags=[], monitorNewItems="all")
if anime:
    body.update(activeAnimeProfileId=anime["id"], activeAnimeProfileName=anime["name"],
                activeAnimeDirectory=(existing or {}).get("activeAnimeDirectory") or root, animeSeriesType="anime")
changed = (not existing or existing.get("activeProfileName") != body["activeProfileName"]
           or existing.get("activeAnimeProfileName") != body.get("activeAnimeProfileName"))
print(json.dumps(body))
print(pick["name"], file=sys.stderr); print(anime["name"] if anime else "", file=sys.stderr); print(int(changed), file=sys.stderr)' 2>"$COOKIE_DIR/profile.txt") \
        || { todo "Seerr: ${app^} has no quality profiles yet; add it in Settings > Services."; return 1; }
    local picked anime_picked changed
    picked=$(sed -n 1p "$COOKIE_DIR/profile.txt"); anime_picked=$(sed -n 2p "$COOKIE_DIR/profile.txt"); changed=$(sed -n 3p "$COOKIE_DIR/profile.txt")
    if [ -n "$existing" ]; then
        if [ "$changed" != "1" ]; then
            if [ "$picked" = "$cur_profile" ] && [ "$app" = sonarr ] && [ -z "$anime_picked" ]; then
                warn "Seerr: Sonarr keeps '$cur_profile'; no anime profile in Sonarr yet (Profilarr '$PROFILARR_ANIME_DB' sync not finished?). Re-run after the sync."
            else
                warn "Seerr: ${app^} has no Profilarr profile yet (sync not finished?); staying on '$cur_profile'. Re-run after the sync."
            fi
            return 0
        fi
        id=$(printf '%s' "$existing" | jpy "d['id']")
        seerr_api PUT "/api/v1/settings/$app/$id" "$body" >/dev/null
        if http_ok; then ok "Seerr: ${app^} profile changed to '$picked'${anime_picked:+, anime profile $anime_picked}"; else todo "Seerr: could not update ${app^} (HTTP $(http_code)); pick '$picked' in Settings > Services."; fi
        return 0
    fi
    seerr_api POST "/api/v1/settings/$app" "$body" >/dev/null
    if http_ok; then
        ok "Seerr: ${app^} added (profile '$picked'${anime_picked:+, anime profile $anime_picked}, root $root)"
        [ "$app" != sonarr ] || [ -n "$anime_picked" ] || warn "Seerr: no anime profile found in Sonarr yet (Profilarr '$PROFILARR_ANIME_DB' sync not finished?); anime requests use '$picked' until a re-run."
        [[ "$picked" == "1080p Balanced" ]] || warn "Seerr: '1080p Balanced' not found in ${app^} (Profilarr sync not finished?); using '$picked'. Re-run after the sync to switch."
    else
        todo "Seerr: could not add ${app^} (HTTP $(http_code))."; fi
}

configure_seerr() {
    info "[8/12] Seerr"
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
    local libs id n_lib=0 n_fail=0
    libs=$(seerr_api POST /api/v1/settings/jellyfin/library/sync)
    http_ok || warn "Seerr: Jellyfin library sync returned HTTP $(http_code)"
    for id in $(printf '%s' "$libs" | jpy "' '.join(l['id'] for l in d)"); do
        n_lib=$(( n_lib + 1 ))
        seerr_api PUT "/api/v1/settings/jellyfin/library/$id" '{"enabled": true}' >/dev/null
        http_ok || n_fail=$(( n_fail + 1 ))
    done
    if [ "$n_lib" -gt 0 ] && [ "$n_fail" -eq 0 ]; then ok "Seerr: $n_lib Jellyfin libraries synced and enabled"
    else todo "Seerr: Jellyfin libraries: $n_lib found, $n_fail could not be enabled; check Settings > Jellyfin."; fi
    seerr_api POST /api/v1/settings/jellyfin/sync '{"start": true}' >/dev/null
    [ -n "$RADARR_API_KEY" ] && seerr_add_arr radarr radarr 7878 "$RADARR_API_KEY" /media/movies
    [ -n "$SONARR_API_KEY" ] && seerr_add_arr sonarr sonarr 8989 "$SONARR_API_KEY" /media/tv
    if [ "$initialized" != "True" ]; then
        seerr_api POST /api/v1/settings/main '{"locale": "en"}' >/dev/null
        seerr_api POST /api/v1/settings/initialize >/dev/null
        http_ok && ok "Seerr: setup marked complete" || todo "Seerr: could not mark setup complete (HTTP $(http_code))."
    fi
}

# ── 9. Bazarr (login + Radarr/Sonarr; languages and providers in the UI) ───
# Bazarr settings are one form POST (field names settings-<section>-<key>,
# 204 on success). The login is the Form type; Bazarr hashes the password
# itself, and the API key keeps working regardless of the login type, so the
# rest of this step is unaffected.
configure_bazarr() {
    info "[9/12] Bazarr"
    local cfg="$CONFIGS_PATH/bazarr/config/config.yaml"
    wait_for "Bazarr to write config.yaml" 180 bash -c "grep -qE '^\s*apikey:' '$cfg'" \
        || { todo "Bazarr: config.yaml never appeared; connect Radarr/Sonarr in Settings."; return 1; }
    BAZARR_API_KEY=$(grep -m1 -E '^\s*apikey:' "$cfg" | awk '{print $2}' | tr -d '"'"'")
    wait_for "Bazarr API" 180 bash -c "curl -fs -H 'X-API-KEY: $BAZARR_API_KEY' $BAZARR_URL/api/system/status -o /dev/null" \
        || { todo "Bazarr API not responding; skipping."; return 1; }
    [ -n "$RADARR_API_KEY" ] && [ -n "$SONARR_API_KEY" ] \
        || { todo "Bazarr: missing a Radarr/Sonarr API key; connect them in Settings."; return 1; }
    local code
    code=$(curl -sS -m 60 -o /dev/null -w '%{http_code}' -X POST -H "X-API-KEY: $BAZARR_API_KEY" "$BAZARR_URL/api/system/settings" \
        --data-urlencode settings-auth-type=form \
        --data-urlencode "settings-auth-username=$ADMIN_USER" \
        --data-urlencode "settings-auth-password=$ADMIN_PASS" \
        --data-urlencode settings-analytics-enabled=false \
        --data-urlencode settings-general-use_radarr=true \
        --data-urlencode settings-radarr-ip=radarr --data-urlencode settings-radarr-port=7878 \
        --data-urlencode settings-radarr-base_url=/ --data-urlencode settings-radarr-ssl=false \
        --data-urlencode "settings-radarr-apikey=$RADARR_API_KEY" \
        --data-urlencode settings-general-use_sonarr=true \
        --data-urlencode settings-sonarr-ip=sonarr --data-urlencode settings-sonarr-port=8989 \
        --data-urlencode settings-sonarr-base_url=/ --data-urlencode settings-sonarr-ssl=false \
        --data-urlencode "settings-sonarr-apikey=$SONARR_API_KEY")
    if [ "$code" = "204" ]; then ok "Bazarr: Form login ($ADMIN_USER / $ADMIN_PASS), connected to Radarr and Sonarr, anonymous usage data off"; else
        todo "Bazarr: settings POST returned HTTP $code; set the login and connect Radarr/Sonarr in Settings."; fi
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
    discovered=$(qui_api POST /api/torznab/indexers/discover "$(PROWLARR_API_KEY="$PROWLARR_API_KEY" jbuild '{"base_url": "http://prowlarr:9696", "api_key": os.environ["PROWLARR_API_KEY"]}')")
    http_ok || { warn "Qui: Prowlarr discovery failed (HTTP $(http_code))"; return 1; }
    have=$(qui_api GET /api/torznab/indexers | jpy "[i.get('indexer_id') for i in d]")
    local id payload
    for id in $private; do
        [[ "$have" == *"\"$id\""* ]] && continue
        payload=$(printf '%s' "$discovered" | WANT="$id" PROWLARR_API_KEY="$PROWLARR_API_KEY" python3 -c '
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
    info "[10/12] Qui"
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

    # Hardlink cross-seed mode, flat layout, plus reannounce. One PUT.
    # The update must carry the login again: Qui stores whatever username the
    # PUT holds, and an empty one switches the instance to "no login", after
    # which qBittorrent answers 403 and Qui backs off forever.
    qui_api PUT "/api/instances/$inst" "$(jbuild '{"name": "qbittorrent", "host": "http://qbittorrent:8080", "username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PASS"], "hasLocalFilesystemAccess": True, "useHardlinks": True, "useReflinks": False, "hardlinkBaseDir": "/media/downloads/crossseed", "hardlinkDirPreset": "flat", "fallbackToRegularMode": False, "reannounceSettings": {"enabled": True, "initialWaitSeconds": 15, "reannounceIntervalSeconds": 7, "maxAgeSeconds": 600, "maxRetries": 50, "aggressive": False, "monitorAll": True, "excludeCategories": False, "categories": [], "excludeTags": False, "tags": [], "excludeTrackers": False, "trackers": []}}')" >/dev/null
    http_ok && ok "Qui: hardlink cross-seed mode (/media/downloads/crossseed, flat) + reannounce enabled" \
            || warn "Qui: instance settings update returned HTTP $(http_code)"

    # Qui backs off (up to an hour after an IP ban) when qBittorrent rejected
    # it earlier. Re-activating the instance clears that state; the test then
    # says right away whether Qui can log in.
    local conn
    qui_api PUT "/api/instances/$inst/status" '{"isActive": true}' >/dev/null
    conn=$(qui_api POST "/api/instances/$inst/test")
    if [ "$(printf '%s' "$conn" | jpy "d.get('connected')")" = "True" ]; then ok "Qui: connected to qBittorrent"; else
        todo "Qui: cannot connect to qBittorrent: $(printf '%s' "$conn" | jpy "d.get('error') or d.get('message') or d")"; fi

    # Cross-seed rules + RSS automation (wiki sections 3.1 and 3.3), and the
    # post-injection "Max auto-start download": a new cross-seed that still
    # has to fetch more than this many MiB stays paused for review.
    qui_api PATCH /api/cross-seed/settings "$(I="$inst" jbuild '{"useCrossCategoryAffix": True, "categoryAffixMode": "suffix", "categoryAffix": ".cross", "skipPieceBoundarySafetyCheck": False, "enabled": True, "runIntervalMinutes": 90, "targetInstanceIds": [int(os.environ["I"])], "targetIndexerIds": [], "rssSourceExcludeTags": ["cross-seed"], "autoResumeMaxDownloadMb": 5}')" >/dev/null
    http_ok && ok "Qui: cross-seed rules (.cross suffix, piece check on), RSS automation (90 min), max auto-start download 5 MiB" \
            || warn "Qui: cross-seed settings returned HTTP $(http_code)"

    # Auto-search on completion (wiki 3.4).
    qui_api PUT "/api/cross-seed/completion/$inst" '{"enabled": true, "categories": [], "tags": [], "excludeCategories": [], "excludeTags": ["cross-seed"], "indexerIds": [], "bypassTorznabCache": false, "delaySeconds": 0}' >/dev/null
    http_ok && ok "Qui: auto-search on completion enabled" || warn "Qui: completion settings returned HTTP $(http_code)"

    # Automations from the wiki (section 4), added enabled.
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

# ── 11. Tracearr ────────────────────────────────────────────────────────────
# Tracearr's API lives under /api/v1 with a Better Auth session cookie. The
# first sign-up becomes the owner; Jellyfin is connected with a Jellyfin API
# key, which this script creates in Jellyfin for the purpose.
TRACEARR_COOKIE="$COOKIE_DIR/tracearr.cookie"
tracearr_api() {  # tracearr_api <method> <path> [json]
    http "$1" "$TRACEARR_URL$2" "${3-}" -b "$TRACEARR_COOKIE" -c "$TRACEARR_COOKIE" -H 'Content-Type: application/json'
}
tracearr_ready() {  # /health answers 200 while still starting; "mode":"ready" is the real signal
    [[ "$(curl -sS -m 10 "$TRACEARR_URL/health" 2>/dev/null)" == *'"mode":"ready"'* ]]
}

configure_tracearr() {
    info "[11/12] Tracearr"
    if ! wait_for "Tracearr (its bundled database takes a minute on first start)" 300 tracearr_ready; then
        # Say what it is doing instead: the health answer carries the mode
        # (starting / maintenance / ready) and the database and Redis state.
        local health cstate
        health=$(curl -sS -m 10 "$TRACEARR_URL/health" 2>&1 | head -c 300)
        cstate=$(docker ps -a --filter name='^tracearr$' --format '{{.Status}}' 2>/dev/null)
        todo "Tracearr did not become ready. Container: ${cstate:-not found}. /health: ${health:-no answer}. Check: docker logs --tail 50 tracearr"
        return 1
    fi
    local status res
    status=$(http GET "$TRACEARR_URL/api/v1/setup/status")
    if [ "$(printf '%s' "$status" | jpy "d.get('needsSetup')")" = "True" ]; then
        tracearr_api POST /api/v1/auth/sign-up/email "$(jbuild '{"name": "Admin", "username": os.environ["ADMIN_USER"], "email": os.environ["ADMIN_EMAIL"], "password": os.environ["ADMIN_PASS"]}')" >/dev/null
        http_ok && ok "Tracearr: owner account created ($ADMIN_USER / $ADMIN_PASS)" \
                || { todo "Tracearr: account creation returned HTTP $(http_code); finish setup at $TRACEARR_URL."; return 1; }
    else
        tracearr_api POST /api/v1/auth/sign-in/username "$(jbuild '{"username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PASS"]}')" >/dev/null
        http_ok && ok "Tracearr: logged in" || { todo "Tracearr: login failed (HTTP $(http_code)); configure it at $TRACEARR_URL."; return 1; }
    fi

    local key server_id
    server_id=$(tracearr_api GET /api/v1/servers | jpy "next((s.get('id') for s in (d if isinstance(d, list) else d.get('servers') or []) if s.get('url')=='$JELLYFIN_INT'), None)")
    if [ -n "$server_id" ]; then
        ok "Tracearr: Jellyfin already connected"
    else
        [ -n "$JELLYFIN_TOKEN" ] || { todo "Tracearr: no Jellyfin session from step 7; add Jellyfin under Settings (http://jellyfin:8096 + an API key)."; return 1; }
        key=$(jf_api_key Tracearr)
        [ -n "$key" ] || { todo "Tracearr: could not create a Jellyfin API key; make one in Jellyfin (Dashboard > API Keys) and add the server in Tracearr."; return 1; }
        res=$(tracearr_api POST /api/v1/auth/jellyfin/connect-api-key "$(JF_INT="$JELLYFIN_INT" K="$key" jbuild '{"serverUrl": os.environ["JF_INT"], "serverName": "Jellyfin", "apiKey": os.environ["K"]}')")
        if http_ok; then ok "Tracearr: Jellyfin connected ($JELLYFIN_INT); users and libraries sync in the background"; else
            todo "Tracearr: connecting Jellyfin returned HTTP $(http_code): $(printf '%s' "$res" | head -c 200)"; return 1; fi
        server_id=$(printf '%s' "$res" | jpy "d.get('serverId')")
    fi
    tracearr_link_seerr "$server_id"
    echo "    Tracearr: sharing rules and notifications are yours to tune under Settings."
}

# tracearr_link_seerr <tracearr server id>
# "Link Seerr" on the Jellyfin connection: Tracearr reads request history
# from Seerr. It probes Seerr with the key and insists that Seerr's media
# server is this same Jellyfin. The key comes from Seerr's own settings
# (Seerr > Settings > General > API key) through the session step 8 opened.
tracearr_link_seerr() {
    local server_id="$1" linked seerr_key res
    [ -n "$server_id" ] || return 1
    linked=$(tracearr_api GET /api/v1/request-services | jpy "[r.get('serverId') for r in d]")
    if [[ "$linked" == *"\"$server_id\""* ]]; then ok "Tracearr: Seerr already linked to Jellyfin"; return 0; fi
    seerr_key=$(seerr_api GET /api/v1/settings/main | jpy "d.get('apiKey')")
    [ -n "$seerr_key" ] || { todo "Tracearr: could not read the Seerr API key (Seerr step not logged in?); link Seerr under Settings > Connections with the key from Seerr > Settings > General."; return 1; }
    res=$(tracearr_api POST /api/v1/request-services "$(SID="$server_id" SURL="$SEERR_INT" SKEY="$seerr_key" jbuild '{"serverId": os.environ["SID"], "url": os.environ["SURL"], "apiKey": os.environ["SKEY"]}')")
    if http_ok; then ok "Tracearr: Seerr linked to Jellyfin ($SEERR_INT); request history syncs in the background"; else
        todo "Tracearr: linking Seerr returned HTTP $(http_code): $(printf '%s' "$res" | head -c 200)"; fi
}

# ── 12. Dockge ──────────────────────────────────────────────────────────────
# Dockge's first-run account is created over socket.io, not HTTP. socket.io's
# long-polling transport is plain HTTP, so curl can drive it: handshake,
# connect to the namespace, send the event with an ack id, read the ack.
dockge_sio_get()  { curl -sS -m 40 "$DOCKGE_URL/socket.io/?EIO=4&transport=polling&sid=$1" 2>/dev/null | tr '\036' '\n'; }
dockge_sio_send() { curl -sS -m 20 -o /dev/null -X POST "$DOCKGE_URL/socket.io/?EIO=4&transport=polling&sid=$1" -H 'Content-Type: text/plain;charset=UTF-8' --data-raw "$2" 2>/dev/null; }
# dockge_sio_ack <sid> <ack-id> -> the ack payload (JSON array) for that id, polling twice at most
dockge_sio_ack() {
    local sid="$1" ack="$2" out
    for _ in 1 2; do
        out=$(dockge_sio_get "$sid" | grep -m1 "^43${ack}\[")
        [ -n "$out" ] && { printf '%s' "${out#43"$ack"}"; return 0; }
    done
    return 1
}

# Dockge refuses any password its strength check rates "Too weak", and a
# letters-only password such as the default "changeme" is exactly that (it
# wants 6+ characters of at least two kinds). The chosen password is used
# when Dockge accepts it; otherwise Dockge gets a generated one. Either is
# kept in a root-only file inside its config dataset for re-runs and printed
# in the summary, and then authentication is switched off so the UI opens
# without a login (Dockge auto-logs the admin in).
DOCKGE_PASS=""
DOCKGE_PASS_FILE=""
dockge_accepts() {  # Dockge's strength check: 6+ characters and at least two kinds (lower, upper, digit, other)
    local p="$1" kinds=0
    [ "${#p}" -ge 6 ] || return 1
    [[ "$p" =~ [a-z] ]] && kinds=$(( kinds + 1 ))
    [[ "$p" =~ [A-Z] ]] && kinds=$(( kinds + 1 ))
    [[ "$p" =~ [0-9] ]] && kinds=$(( kinds + 1 ))
    [[ "$p" =~ [^a-zA-Z0-9] ]] && kinds=$(( kinds + 1 ))
    [ "$kinds" -ge 2 ]
}
configure_dockge() {
    info "[12/12] Dockge"
    wait_for "Dockge" 180 bash -c "curl -fs $DOCKGE_URL/ -o /dev/null" \
        || { todo "Dockge did not come up; create the admin user at $DOCKGE_URL."; return 1; }
    DOCKGE_PASS_FILE="$CONFIGS_PATH/dockge/admin-password.txt"
    if [ -s "$DOCKGE_PASS_FILE" ]; then
        DOCKGE_PASS=$(head -1 "$DOCKGE_PASS_FILE" | tr -d '[:space:]')
    elif dockge_accepts "$ADMIN_PASS"; then
        DOCKGE_PASS="$ADMIN_PASS"
    else
        DOCKGE_PASS="Dockge-$(openssl rand -hex 6 2>/dev/null || date +%s%N | sha256sum | cut -c1-12)"
    fi
    local sid first ack user pass
    sid=$(curl -sS -m 20 "$DOCKGE_URL/socket.io/?EIO=4&transport=polling" 2>/dev/null | tr '\036' '\n' | sed -n 's/^0{"sid":"\([^"]*\)".*/\1/p')
    [ -n "$sid" ] || { todo "Dockge: socket.io handshake failed; create the admin user at $DOCKGE_URL."; return 1; }
    dockge_sio_send "$sid" '40'
    # The connect answer comes with 42["setup"] on a fresh install, or with
    # 42["autoLogin"] once authentication has been disabled.
    first=$(dockge_sio_get "$sid")
    user=$(jbuild 'os.environ["ADMIN_USER"]'); pass=$(DOCKGE_PASS="$DOCKGE_PASS" jbuild 'os.environ["DOCKGE_PASS"]')
    if [[ "$first" == *'["autoLogin"'* ]]; then
        ok "Dockge: already set up, authentication disabled (no login needed)"
        dockge_sio_send "$sid" '41'
        return 0
    fi
    if [[ "$first" == *'["setup"'* ]]; then
        dockge_sio_send "$sid" "421[\"setup\",$user,$pass]"
        ack=$(dockge_sio_ack "$sid" 1)
        if [[ "$ack" == *'"ok":true'* ]]; then
            printf '%s\n' "$DOCKGE_PASS" > "$DOCKGE_PASS_FILE" && chmod 600 "$DOCKGE_PASS_FILE"
            ok "Dockge: admin user created ($ADMIN_USER / $DOCKGE_PASS); password saved to $DOCKGE_PASS_FILE"
        else
            todo "Dockge: setup answered '${ack:-nothing}'; create the admin user at $DOCKGE_URL."
            dockge_sio_send "$sid" '41'; return 1
        fi
    fi
    # Log in on this socket (setup alone does not), then switch authentication
    # off; Dockge re-checks the password for that one change.
    dockge_sio_send "$sid" "422[\"login\",{\"username\":$user,\"password\":$pass}]"
    ack=$(dockge_sio_ack "$sid" 2)
    if [[ "$ack" != *'"ok":true'* ]]; then
        if [ -s "$DOCKGE_PASS_FILE" ]; then
            todo "Dockge: login as $ADMIN_USER with the password in $DOCKGE_PASS_FILE failed ('${ack:-no answer}'); check $DOCKGE_URL."
        else
            todo "Dockge: an account exists but $DOCKGE_PASS_FILE is missing, so this script cannot log in; log in at $DOCKGE_URL with the password you set and disable authentication under Settings."
        fi
        dockge_sio_send "$sid" '41'; return 1
    fi
    dockge_sio_send "$sid" "423[\"setSettings\",{\"disableAuth\":true},$pass]"
    ack=$(dockge_sio_ack "$sid" 3)
    dockge_sio_send "$sid" '41'
    if [[ "$ack" != *'"ok":true'* ]]; then
        todo "Dockge: could not disable authentication ('${ack:-no answer}'); log in as $ADMIN_USER with the password in $DOCKGE_PASS_FILE."
        return 1
    fi
    # Dockge only announces the auto-login when a page's socket connects, so a
    # tab opened before this step keeps asking for a login until it reconnects.
    # A restart makes every open tab reconnect and log itself in.
    docker restart dockge >/dev/null 2>&1
    wait_for "Dockge after the restart" 180 bash -c "curl -fs $DOCKGE_URL/ -o /dev/null" \
        || warn "Dockge did not answer after the restart; check: docker logs dockge"
    ok "Dockge: authentication disabled; the UI opens without a login (reload any Dockge tab that was already open)"
    echo "    Dockge manages the stacks in $STACKS_PATH; use Scan Stacks Folder if one is missing from its list."
}

# ── Run in the wiki's install order ─────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " Auto-configuring the stack (login everywhere: $ADMIN_USER / $ADMIN_PASS)"
echo "═══════════════════════════════════════════════════════════════"
configure_qbittorrent
configure_radarr
configure_sonarr
configure_trawl
configure_prowlarr
configure_profilarr
configure_jellyfin
configure_seerr
configure_bazarr
configure_qui
configure_tracearr
configure_dockge

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " Done. Services and their URLs:"
echo "═══════════════════════════════════════════════════════════════"
docker ps --format "{{.Names}}" | while read -r container_name; do
    ports=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{ (index $conf 0).HostPort }} {{end}}{{end}}' "$container_name")
    if [ -n "$ports" ]; then
        # Trawl's port is its API; the page to open is the dashboard.
        path=""; [ "$container_name" = trawl ] && path="/dashboard"
        for port in $ports; do echo "  $container_name | http://$HOST_IP:$port$path"; done
    else
        echo "  $container_name | no published port"
    fi
done
echo ""
echo "  Logins (qBittorrent, Radarr, Sonarr, Prowlarr, Profilarr, Jellyfin, Seerr, Bazarr, Qui, Tracearr):"
echo "    user: $ADMIN_USER   password: $ADMIN_PASS   email: $ADMIN_EMAIL"
if [ -n "$DOCKGE_PASS_FILE" ] && [ -s "$DOCKGE_PASS_FILE" ]; then
    if [ "$DOCKGE_PASS" = "$ADMIN_PASS" ]; then
        echo "  Dockge: authentication is disabled (no login needed); its admin user is the same login, should you turn it back on."
    else
        echo "  Dockge: authentication is disabled (no login needed). Its admin user is $ADMIN_USER / $DOCKGE_PASS"
        echo "    (also in $DOCKGE_PASS_FILE) should you turn authentication back on."
    fi
fi
if [ "$ADMIN_PASS" = changeme ]; then echo "  CHANGE THESE before exposing anything beyond your LAN."; fi
echo "  (Your answers are kept root-only in $SETUP_STATE_FILE for re-runs.)"
[ -n "$QB_FORWARDED_PORT" ] && echo "  qBittorrent listens on forwarded port $QB_FORWARDED_PORT (VPN_AUTO_PORT_FORWARD)."
[ "$WG_FROM_AIRVPN" = 1 ] && echo "  qBittorrent's WireGuard config came from AirVPN; to change server, alerts or auto-switch: bash $AIRVPN_WG --output $WG_FILE"
echo "  Stacks: $STACKS_PATH/<container>/compose.yaml, managed from Dockge at http://$HOST_IP:5001"
if [ "$GPU_VENDOR" = "none" ]; then
    echo "  Jellyfin transcoding: software (no usable GPU found).${GPU_NOTE:+ $GPU_NOTE}"
else
    echo "  Jellyfin transcoding: $GPU_ACCEL on ${GPU_NAME:-$GPU_VENDOR}; decode [${GPU_DEC:-none}], encode [${GPU_ENC:-none}]"
fi
if [ "${#TODO_LIST[@]}" -gt 0 ]; then
    echo ""
    echo "  Finish by hand:"
    for item in "${TODO_LIST[@]}"; do echo "   - $item"; done
fi
echo ""
echo "  Still manual by design: Prowlarr indexers (your trackers), Bazarr languages"
echo "  and providers, and the one-time Qui library scan."
echo "Script completed."
