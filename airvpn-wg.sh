#!/usr/bin/env bash
# ============================================================================
# AirVPN WireGuard config generator + server monitor
#
# Builds a wg0.conf (WireGuard, Linux, IPv4 only) straight from the AirVPN
# API, ready for hotio's qBittorrent (/config/wireguard/wg0.conf) or any other
# WireGuard client:
#
#   1. Device: pick one of the devices (keys) on your AirVPN account, or
#      create a new one.
#   2. Server: filter by your preferred countries and a minimum server
#      bandwidth (read from AirVPN's live list: currently 2000, 6000 or
#      20000 Mbit/s; the default is the largest size on offer), healthy
#      servers only, ranked on load + reliability + measured ping (outages
#      counted from AirVPN's session history, 90 days for the top 5, 10 days
#      for the rest). A server refilling after a recent outage is ranked on
#      its load once users are back, not on its misleadingly low current
#      load. The list shows every figure, so any server can still be picked.
#   3. Generate: writes wg0.conf, backs up the previous one, and checks the
#      config really belongs to the chosen device.
#   4. Alerts (optional): pick a channel (ntfy, Discord, Gotify, Telegram)
#      and the events you care about, then run
#      "airvpn-wg.sh monitor" from cron.
#   5. Auto-switch (optional): when the chosen server goes down, the monitor
#      rewrites wg0.conf for the next healthy server matching the same
#      filters (countries, bandwidth, sort) and restarts the container.
#
# Needs an AirVPN API key: https://airvpn.org/apisettings/ (premium account).
# Settings (key, choices, alert channel) are kept in airvpn-wg.env next to
# wg0.conf, readable by root only.
#
# AirVPN bans IPs that send more than 600 API requests in 10 minutes. This
# script caps itself at MAX_CALLS requests per run. The server menu uses about
# one per listed server plus 8 for each server whose 90 days are read (the
# top 5, more when reading reshuffles the top; typically 40-120); "monitor"
# uses 1 to 3, and the same as the menu when it auto-switches. Nothing is
# cached between runs: the history is read fresh each time.
#
# Run in the TrueNAS shell as root:
#   sudo su -c "wget https://raw.githubusercontent.com/serversathome/ServersatHome/refs/heads/main/airvpn-wg.sh && chmod +x airvpn-wg.sh && bash airvpn-wg.sh"
#
# Usage: see "airvpn-wg.sh --help".
# ============================================================================

set -uo pipefail

API="https://airvpn.org/api"
MAX_CALLS=300                # hard cap per run: half AirVPN's ban limit (600 per 10 minutes)
MAX_HISTORY_CHECKS=60        # servers whose last 10 days of history are read (1 request each)
DEEP_CHECKS=5                # top servers whose full RELIABILITY_DAYS are read
DEEP_ROUNDS=10               # re-checks until the whole top DEEP_CHECKS has them
RELIABILITY_DAYS=90          # 10 days per request, so 8 more requests per deep server
OUTAGE_PENALTY=20            # ranking: 1 (weighted) outage per 30 days counts like 20% load
PING_WEIGHT=0.25             # ranking: 1 ms of ping counts like 0.25% load. Low on purpose: for
                             # torrents, capacity and uptime matter far more than latency
SHORT_OUTAGE_WEIGHT=0.2      # a short outage (under ~20 min) counts as this much of one
LONG_OUTAGE_HOURLY=0.5       # a long outage (30+ min) counts 1, plus this per hour beyond the first
WG_PORTS="1637 47107 51820"  # AirVPN's WireGuard ports (UDP)

# ── Helpers ─────────────────────────────────────────────────────────────────
info() { echo ">>> $*"; }
ok()   { echo "    ✔ $*"; }
warn() { echo "⚠️  $*" >&2; }
die()  { echo "❌ $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: airvpn-wg.sh [command] [options]

Commands:
  setup        (default) pick a device and server, write wg0.conf, set up alerts
  alerts       change the alert channel, events and auto-switch only
  test-alert   send a test message to the configured channel
  monitor      check the chosen server once, alert on changes and
               auto-switch if it is down (for cron)

Options:
  -o, --output PATH   wg0.conf to write (default ./wg0.conf). airvpn-wg.env
                      and airvpn-wg.state live in the same directory.
  --device NAME       AirVPN device name (skips the device menu)
  --server NAME       AirVPN server name (e.g. Menkent)
                      (skips the server menu)
  --port PORT         WireGuard port: 1637 (default), 47107 or 51820
  -h, --help          this help

The API key is read from airvpn-wg.env, or from AIRVPN_API_KEY in the
environment, or asked for. With --device and --server, setup runs without
menus (alerts are left as they are), e.g. from another script:
  AIRVPN_API_KEY=... airvpn-wg.sh --output /path/wg0.conf --device truenas --server Menkent
EOF
}

# ── Arguments ───────────────────────────────────────────────────────────────
CMD=setup; OUTPUT="./wg0.conf"; ARG_DEVICE=""; ARG_SERVER=""; ARG_PORT=""
while [ $# -gt 0 ]; do
    case "$1" in
        setup|alerts|test-alert|monitor) CMD=$1 ;;
        -o|--output) OUTPUT=${2-}; shift ;;
        --device)    ARG_DEVICE=${2-}; shift ;;
        --server)    ARG_SERVER=${2-}; shift ;;
        --port)      ARG_PORT=${2-}; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
    shift
done
[ -n "$OUTPUT" ] || die "--output needs a path."

command -v curl >/dev/null || die "curl is required."
command -v python3 >/dev/null || die "python3 is required."

OUT_DIR=$(cd "$(dirname "$OUTPUT")" 2>/dev/null && pwd) || die "Directory for $OUTPUT does not exist."
OUTPUT="$OUT_DIR/$(basename "$OUTPUT")"
ENV_FILE="$OUT_DIR/airvpn-wg.env"
STATE_FILE="$OUT_DIR/airvpn-wg.state"

CALLS_FILE=$(mktemp)
echo 0 > "$CALLS_FILE"
PING_FILE=$(mktemp)
REL_FILE=$(mktemp)
HIST_DIR=$(mktemp -d)
HIST_NOW=$(date +%s)
trap 'rm -rf "$CALLS_FILE" "$PING_FILE" "$REL_FILE" "$HIST_DIR"' EXIT

# ── Saved settings ──────────────────────────────────────────────────────────
# Everything the menus remember, with defaults. A key in the environment wins
# over the saved one.
ENV_KEY=${AIRVPN_API_KEY:-}
AIRVPN_API_KEY=""
DEVICE=""; SERVER=""; WG_PORT=1637
COUNTRIES=""; MIN_BW=""   # MIN_BW "" = largest size AirVPN has
ALERT_CHANNEL=none
NTFY_URL=""; NTFY_TOKEN=""; DISCORD_WEBHOOK=""
GOTIFY_URL=""; GOTIFY_TOKEN=""; TELEGRAM_TOKEN=""; TELEGRAM_CHAT_ID=""
EVENT_SERVER_DOWN=1; EVENT_SERVER_WARNING=1; EVENT_SERVER_LOAD=0; LOAD_THRESHOLD=90
EVENT_DEVICE_OFFLINE=0; EVENT_EXPIRY=1; EXPIRY_DAYS=7; EVENT_RECOVERY=1
AUTO_SWITCH=0; RESTART_CONTAINER=qbittorrent
SETTINGS="AIRVPN_API_KEY DEVICE SERVER WG_PORT COUNTRIES MIN_BW
ALERT_CHANNEL NTFY_URL NTFY_TOKEN DISCORD_WEBHOOK GOTIFY_URL GOTIFY_TOKEN
TELEGRAM_TOKEN TELEGRAM_CHAT_ID EVENT_SERVER_DOWN EVENT_SERVER_WARNING
EVENT_SERVER_LOAD LOAD_THRESHOLD EVENT_DEVICE_OFFLINE EVENT_EXPIRY EXPIRY_DAYS
EVENT_RECOVERY AUTO_SWITCH RESTART_CONTAINER"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
[ -n "$ENV_KEY" ] && AIRVPN_API_KEY=$ENV_KEY

save_settings() {
    local v tmp
    tmp=$(mktemp "$OUT_DIR/.airvpn-wg.env.XXXXXX") || die "Cannot write to $OUT_DIR."
    chmod 600 "$tmp"
    {
        echo "# airvpn-wg.sh settings, written $(date '+%Y-%m-%d %H:%M'). Contains secrets."
        for v in $SETTINGS; do
            # The key is only kept when the monitor needs it (see key_reasons).
            if [ "$v" = AIRVPN_API_KEY ] && [ -z "$(key_reasons)" ]; then echo "AIRVPN_API_KEY=''"; continue; fi
            printf '%s=%q\n' "$v" "${!v}"
        done
    } > "$tmp"
    mv "$tmp" "$ENV_FILE"
}

# ── AirVPN API ──────────────────────────────────────────────────────────────
# api <service> [name=value ...]
# GET https://airvpn.org/api/<service>/ with the API key (when set), values
# URL-encoded. Prints the body. Every request counts against MAX_CALLS; the
# counter lives in a file so it survives $(api ...) subshells.
api() {
    local svc=$1; shift
    local p
    reserve_calls 1 || die "Stopping after $MAX_CALLS API requests this run (AirVPN bans IPs above 600 per 10 minutes)."
    local args=() hdr=()
    for p in "$@"; do args+=(--data-urlencode "$p"); done
    [ -n "$AIRVPN_API_KEY" ] && hdr=(-H "API-KEY: $AIRVPN_API_KEY")
    curl -sS -m 30 -G "${hdr[@]}" "${args[@]}" "$API/$svc/"
}

# reserve_calls <n> — counts n requests against MAX_CALLS; returns 1 (and
# counts nothing) if they would go over it.
reserve_calls() {
    local n
    n=$(( $(cat "$CALLS_FILE") + $1 ))
    [ "$n" -gt "$MAX_CALLS" ] && return 1
    echo "$n" > "$CALLS_FILE"
}

# jget '<python expression over d>' — evaluate against JSON on stdin.
# Scalars print raw, dicts/lists as JSON. Bad JSON or a failing expression -> "".
jget() {
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = eval(sys.argv[1])
except Exception:
    sys.exit(0)
if v is not None:
    print(json.dumps(v) if isinstance(v, (dict, list)) else v)' "$1"
}

result_of() { jget 'd.get("result")'; }

# ── Prompts ─────────────────────────────────────────────────────────────────
# ask <prompt> <default> — prints the answer (the default on Enter).
ask() {
    local a
    read -rp "$1${2:+ [$2]}: " a </dev/tty
    printf '%s' "${a:-$2}"
}
yesno() {  # yesno <prompt> <y|n>
    local a
    a=$(ask "$1 (y/n)" "$2")
    [[ "$a" =~ ^[Yy] ]]
}

# ── Step 0: API key ─────────────────────────────────────────────────────────
USERINFO=""
ensure_key() {
    if [ -z "$AIRVPN_API_KEY" ]; then
        echo "Create an API key at https://airvpn.org/apisettings/ (and activate it)."
        read -rsp "AirVPN API key: " AIRVPN_API_KEY </dev/tty; echo
    fi
    [ -n "$AIRVPN_API_KEY" ] || die "No API key."
    USERINFO=$(api userinfo)
    [ "$(result_of <<<"$USERINFO")" = ok ] \
        || die "AirVPN rejected the API key: $(result_of <<<"$USERINFO")"
    [ "$(jget 'd["user"]["premium"]' <<<"$USERINFO")" = True ] \
        || die "The config generator needs a premium AirVPN account."
    ok "AirVPN account $(jget 'd["user"]["login"]' <<<"$USERINFO"), expires in $(jget 'd["user"]["expiration_days"]' <<<"$USERINFO") days"
}

# ── Step 1: device ──────────────────────────────────────────────────────────
DEVICE_IP=""
# Prints one TSV line per device: name, id, status, ipv4, last connection.
device_rows() {
    python3 -c '
import json, sys
d = json.load(sys.stdin)
for x in d.get("devices", []):
    print("\t".join(str(v or "-") for v in (x["name"], x["id"], x.get("status"),
          x.get("wireguard_ipv4"), x.get("vpn_last_from_date"))))'
}

create_device() {
    local name resp newid i cur r
    name=$(ask "Name for the new device (letters, digits, - and _)" "")
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid device name."
    # The generator picks devices by name, so names must stay unique.
    cut -f1 <<<"$1" | grep -qxF "$name" && die "A device named $name already exists."
    resp=$(api devices action=add)
    [ "$(result_of <<<"$resp")" = ok ] || die "AirVPN refused to add a device: $(result_of <<<"$resp")"
    newid=$(jget 'd["id"]' <<<"$resp")
    [ -n "$newid" ] || die "AirVPN did not return the new device's id."
    # AirVPN queues the add (status "create") and names it "New device"; its
    # keys are usually ready within 15s. Poll every 10s for up to 2 minutes,
    # then rename it (modify is immediate).
    echo "Device requested, waiting for AirVPN to create its keys..." >&2
    for i in $(seq 1 12); do
        sleep 10
        cur=$(api devices action=list | device_rows | awk -F'\t' -v id="$newid" '$2==id')
        if [ "$(cut -f3 <<<"$cur")" = ready ]; then
            r=$(api devices action=modify id="$newid" name="$name")
            if [ "$(result_of <<<"$r")" = ok ]; then
                DEVICE=$name
            else
                DEVICE=$(cut -f1 <<<"$cur")
                warn "Could not rename the device ($(result_of <<<"$r")); it is called \"$DEVICE\"."
            fi
            DEVICE_IP=$(cut -f4 <<<"$cur")
            ok "Device $DEVICE created ($DEVICE_IP)"
            return 0
        fi
        [ $(( i % 3 )) -eq 0 ] && echo "    ... still waiting ($(( i * 10 ))s)" >&2
    done
    die "AirVPN has not finished creating the device after 2 minutes. Re-run the script and pick it from the list."
}

pick_device() {
    local list rows i choice line busy
    list=$(api devices action=list)
    [ "$(result_of <<<"$list")" = ok ] || die "Could not list devices: $(result_of <<<"$list")"
    rows=$(device_rows <<<"$list")

    if [ -n "$ARG_DEVICE" ]; then
        line=$(awk -F'\t' -v n="$ARG_DEVICE" '$1==n' <<<"$rows")
        [ -n "$line" ] || die "No device named \"$ARG_DEVICE\" on this account."
    else
        echo
        echo "Devices on your AirVPN account:"
        i=0
        while IFS=$'\t' read -r name _ status ip last; do
            [ -n "$name" ] || continue
            i=$(( i + 1 ))
            printf '  %2d) %-20s %-8s %-16s last connected %s\n' "$i" "$name" "$status" "$ip" "$last"
        done <<<"$rows"
        echo "   n) Create a new device"
        local def=1
        [ -n "$DEVICE" ] && def=$(awk -F'\t' -v n="$DEVICE" '$1==n{print NR}' <<<"$rows")
        choice=$(ask "Device" "${def:-1}")
        if [[ "$choice" =~ ^[Nn]$ ]]; then
            create_device "$rows"
            return 0
        fi
        [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ] || die "Invalid choice."
        line=$(sed -n "${choice}p" <<<"$rows")
    fi

    DEVICE=$(cut -f1 <<<"$line"); DEVICE_IP=$(cut -f4 <<<"$line")
    [ "$(cut -f3 <<<"$line")" = ready ] || die "Device $DEVICE is not ready yet (status $(cut -f3 <<<"$line")). Try again in a minute."
    ok "Device $DEVICE ($DEVICE_IP)"

    # One device = one WireGuard key = one connection. Two machines sharing a
    # device keep knocking each other off.
    busy=$(DEV="$DEVICE" jget '", ".join(s["server_name"] for s in d.get("sessions", []) if s["device_name"] == __import__("os").environ["DEV"])' <<<"$USERINFO")
    if [ -n "$busy" ]; then
        warn "Device $DEVICE is connected right now (to $busy). If that is another machine, give this one its own device."
    fi
}

# ── Step 2: server ──────────────────────────────────────────────────────────
STATUS=""
SERVER_LABEL=""

# server_rows <countries> <min_bw> [exclude] — healthy servers, best first
# (lowest score, below), TSV (every field non-empty: read merges runs of tabs):
#   1 name  2 cc  3 location  4 load %  5 ranked load %  6 users
#   7 ping ms ("-" not measured or no answer)
#   8 history: ok | new (server younger than the history read) | unknown
#     (could not read it) | nc (not checked)
#   9 long outages  10 short outages  11 days of history
#   12 weighted outages per 30 days  13 deep (1 = full RELIABILITY_DAYS read)
#   14 entry IP
# Pings come from $PING_FILE (measure_pings), history from $REL_FILE
# (fetch_history).
# Ranked load: AirVPN drops a server's users during an outage, so for a few
# hours afterwards its load is misleadingly low. For a server with an outage
# in the last 6 hours whose users are still below 90% of its usual sessions,
# the load is scaled up to what it will be with those sessions back.
# Score = PING_WEIGHT x ping ms + ranked load % + OUTAGE_PENALTY per weighted outage per
# 30 days (see analyze_history); without ping every server gets the same
# ping, so load and reliability decide;
# a server whose history is unknown or unchecked counts as 3 outages per 30
# days, so it is never ranked as reliable. History shorter than 10 days
# counts as 10 days, so one outage on a brand-new server is not a 15/month
# rate.
server_rows() {
    CC="$1" MINBW="$2" EXCLUDE="${3-}" PINGS="$PING_FILE" REL="$REL_FILE" \
    PENALTY="$OUTAGE_PENALTY" PINGW="$PING_WEIGHT" python3 -c '
import json, os, statistics, sys
d = json.load(sys.stdin)
cc = set(os.environ["CC"].lower().split())
minbw = int(os.environ["MINBW"] or 0)
penalty = float(os.environ["PENALTY"])
ping_w = float(os.environ["PINGW"])
pings = {}
for line in open(os.environ["PINGS"]):
    n, _, v = line.rstrip("\n").partition("\t")
    try:
        pings[n] = float(v)
    except ValueError:
        pass
rel = {}
for line in open(os.environ["REL"]):
    f = line.rstrip("\n").split("\t")
    if len(f) == 9:
        rel[f[0]] = f[1:]   # status long short days rate30 normal last_min deep
rows = [s for s in d["servers"] if s.get("health") == "ok" and s.get("bw_max", 0) >= minbw
        and (not cc or s["country_code"] in cc) and s["public_name"] != os.environ["EXCLUDE"]]
per_user = [s["currentload"] / s["users"] for s in rows if s.get("users", 0) >= 50]
fleet_ratio = statistics.median(per_user) if per_user else None
def ranked_load(s):
    load, users = s["currentload"], s.get("users", 0)
    r = rel.get(s["public_name"])
    if not r or r[0] not in ("ok", "new") or not r[6].isdigit() or int(r[6]) > 360:
        return load
    normal = int(r[5])
    if normal < 20 or users >= 0.9 * normal:
        return load
    ratio = load / users if users >= 10 else fleet_ratio
    return load if ratio is None else min(100, max(load, round(normal * ratio)))
def rate(s):
    r = rel.get(s["public_name"])
    return float(r[4]) if r and r[0] in ("ok", "new") else 3.0
ping = lambda s: pings.get(s["public_name"], 9999)
key = lambda s: (ping_w * ping(s) + ranked_load(s) + penalty * rate(s), ping(s))
for s in sorted(rows, key=key):
    n = s["public_name"]
    p = pings.get(n)
    r = rel.get(n)
    hist = [r[0], r[1], r[2], r[3], r[4], r[7]] if r else ["nc", "0", "0", "0", "-", "0"]
    print("\t".join([n, s["country_code"], s.get("location") or "-", str(s["currentload"]),
                     str(ranked_load(s)), str(s.get("users", 0)),
                     "%.0f" % p if p is not None else "-"] + hist + [s.get("ip_v4_in1") or "-"]))' <<<"$STATUS"
}

# fetch_history <servers> <chunks> — reads server_rows output on stdin and
# makes sure each of the first <servers> servers has its last <chunks> x 10
# days of session counts (15-minute steps) in $HIST_DIR: one request to the
# public "server" service (no key) per 10-day chunk not read yet this run,
# 6 at a time. A request that fails (no answer, an error, or not a usable
# history) is retried once, so one dropped request does not turn a server's
# whole record into "unknown". Then rewrites $REL_FILE (analyze_history).
# Nothing is kept after the run. Requests that would go over MAX_CALLS are
# skipped (return 1) and those servers show as not checked.
fetch_history() {
    local n k to jobs="" failed
    for n in $(cut -f1 | head -n "$1"); do
        for k in $(seq 0 $(( $2 - 1 ))); do
            [ -s "$HIST_DIR/$n.$k.json" ] && continue
            to=$(( HIST_NOW - k * 864000 ))
            jobs+="$n $k $(( to - 864000 )) $to"$'\n'
        done
    done
    if [ -n "$jobs" ]; then
        if ! reserve_calls "$(grep -c . <<<"$jobs")"; then
            warn "Skipping outage history for some servers: it would go over $MAX_CALLS API requests this run."
            analyze_history
            return 1
        fi
        download_history <<<"$jobs"
        failed=$(bad_history <<<"$jobs")
        if [ -n "$failed" ]; then
            if reserve_calls "$(grep -c . <<<"$failed")"; then
                download_history <<<"$failed"
            else
                warn "Not retrying $(grep -c . <<<"$failed") failed history request(s): it would go over $MAX_CALLS API requests this run."
            fi
        fi
    fi
    analyze_history
}

# download_history — reads "name chunk from to" lines on stdin and fetches
# each into $HIST_DIR/<name>.<chunk>.json, 6 at a time (already counted).
download_history() {
    API="$API" HIST_DIR="$HIST_DIR" xargs -P 6 -L 1 sh -c \
        'curl -sS -m 30 -G --data-urlencode "name=$1" --data-urlencode "from=$3" --data-urlencode "to=$4" \
             --data-urlencode window=900 --data-urlencode panels=sessions "$API/server/" > "$HIST_DIR/$1.$2.json" 2>/dev/null' _
}

# bad_history — reads the same lines and prints those whose file is not a
# usable 15-minute history (empty, not JSON, an API error, another step).
bad_history() {
    HIST_DIR="$HIST_DIR" python3 -c '
import json, os, sys
for line in sys.stdin:
    f = line.split()
    if len(f) != 4:
        continue
    try:
        d = json.load(open(os.path.join(os.environ["HIST_DIR"], "%s.%s.json" % (f[0], f[1]))))
        assert int(d["window"]) == 900 and "sessions" in d["panels"]
    except Exception:
        print(line.rstrip("\n"))'
}

# analyze_history — turns the session histories in $HIST_DIR into $REL_FILE,
# TSV: name, status (ok/new/unknown), long outages, short outages, days of
# history, weighted outages per 30 days, usual sessions, minutes since the
# last outage ("none"), deep (1/0).
# An outage shows as missing 15-minute points and/or sessions under 25% of
# the median of the previous 4 hours (only tested above 20 sessions); points
# less than 2 hours apart are one outage. A gap shared by 80%+ of the servers
# covering that moment is AirVPN's statistics, not an outage. (The packet
# loss series is no use: its averages read 0 straight through an outage.)
# Length: 2+ missing points in a row (no data for ~30 min or more) is a long
# outage, weighted 1 + LONG_OUTAGE_HOURLY per hour beyond the first; at most
# one missing point (an 11-minute outage showed as exactly one) or just a dip
# in sessions is short, weighted SHORT_OUTAGE_WEIGHT. Accurate to about the
# 15-minute step.
analyze_history() {
    python3 -c '
import glob, json, os, statistics, sys
from collections import Counter, defaultdict
hist_dir, now = sys.argv[1], int(sys.argv[2]) * 1000
short_w, hourly_w = float(sys.argv[3]), float(sys.argv[4])
STEP, HOUR, DAY = 900000, 3600000, 86400000
files = defaultdict(dict)
for f in glob.glob(os.path.join(hist_dir, "*.json")):
    name, chunk = os.path.basename(f)[:-5].rsplit(".", 1)
    files[name][int(chunk)] = f
series, failed, start, spans = {}, set(), {}, {}
for name, chunks in files.items():
    pts, oldest, span = {}, None, []
    for k, f in chunks.items():
        try:
            d = json.load(open(f))
            assert int(d["window"]) * 1000 == STEP
            ser = list(d["panels"]["sessions"]["series"].values())[0]
        except Exception:
            failed.add(name)
            continue
        pts.update((int(t), v) for t, v in ser)
        span.append((int(d["from"]) * 1000, int(d["to"]) * 1000))
        oldest = int(d["from"]) * 1000 if oldest is None else min(oldest, int(d["from"]) * 1000)
    pts = sorted(pts.items())
    while pts and not pts[0][1]:        # zeros before a new server went live
        pts.pop(0)
    if pts:
        series[name], start[name], spans[name] = pts, oldest, span
end = (now // STEP) * STEP - STEP       # last complete step
missing, cover = {}, Counter()
for name, pts in series.items():
    present = {t for t, _ in pts}
    first = pts[0][0] - pts[0][0] % STEP
    # Only inside chunks that were read: a chunk that failed is not an outage.
    grid = [t for t in range(first, end + 1, STEP) if any(lo < t <= hi - STEP for lo, hi in spans[name])]
    cover.update(grid)
    missing[name] = {t for t in grid if t not in present}
shared = Counter(t for m in missing.values() for t in m)
statgap = {t for t, c in shared.items() if cover[t] >= 3 and c >= 0.8 * cover[t]}
for name in sorted(files):
    if name not in series:
        print("\t".join([name, "unknown", "0", "0", "0", "-", "0", "none", "0"]))
        continue
    pts = series[name]
    flagged = {t for t in missing[name] if t not in statgap}
    vals = [v for _, v in pts]
    for i, (t, v) in enumerate(pts):
        prev = vals[max(0, i - 16):i]
        if len(prev) >= 8:
            med = statistics.median(prev)
            if med >= 20 and v < 0.25 * med:
                flagged.add(t)
    groups, last = [], None
    for t in sorted(flagged):
        if last is None or t - last > 2 * HOUR:
            groups.append([])
        groups[-1].append(t)
        last = t
    events = [g[0] for g in groups]
    gaps = missing[name] - statgap
    n_long = n_short = 0
    weight = 0.0
    for g in groups:
        run = best = 0
        for t in g:
            if t in gaps:
                run = run + 1 if t - STEP in gaps else 1
                best = max(best, run)
        if best >= 2:
            n_long += 1
            weight += 1 + hourly_w * max(0.0, best * STEP / HOUR - 1)
        else:
            n_short += 1
            weight += short_w
    days = max(0.0, (now - pts[0][0]) / DAY)
    rate30 = weight / max(days, 10.0) * 30
    recent = [v for t, v in pts if t >= now - 3 * DAY and not any(0 <= t - e <= 3 * HOUR for e in events)]
    normal = statistics.median(recent or vals)
    status = "unknown" if name in failed else ("new" if pts[0][0] > start[name] + DAY else "ok")
    print("\t".join([name, status, str(n_long), str(n_short), str(int(round(days))), "%.2f" % rate30,
                     str(int(normal)), str(int((now - last) / 60000)) if last else "none",
                     "1" if len(files[name]) > 1 else "0"]))' "$HIST_DIR" "$HIST_NOW" "$SHORT_OUTAGE_WEIGHT" "$LONG_OUTAGE_HOURLY" > "$REL_FILE"
}

# rank_servers [exclude] — sets RANKED to server_rows output for the saved
# filters, best first, reading everything fresh: pings, 10
# days of history for up to MAX_HISTORY_CHECKS servers, then RELIABILITY_DAYS
# for the top DEEP_CHECKS. Reading a server's 90 days can push it out of the
# top (flaky servers with a good ping get there on 10 clean days), letting in
# one that only has 10 days, so this repeats until every server in the top
# has its full history: up to DEEP_ROUNDS rounds, or until MAX_CALLS stops
# it. Sets PINGED=1 when pings were measured; returns 1 if nothing matches.
RANKED=""; PINGED=0
# shallow_top — the servers in the top DEEP_CHECKS of server_rows output (on
# stdin) that only have 10 days of history (unknown ones can't get more).
shallow_top() {
    head -n "$DEEP_CHECKS" | awk -F'\t' '$13 == 0 && $8 != "unknown" { print $1 }'
}
rank_servers() {
    local exclude=${1-} rows n round chunks=$(( (RELIABILITY_DAYS + 9) / 10 ))
    PINGED=0
    rows=$(server_rows "$COUNTRIES" "$MIN_BW" "$exclude")
    [ -n "$rows" ] || { RANKED=""; return 1; }
    echo "Pinging $(wc -l <<<"$rows") servers..."
    measure_pings <<<"$rows" && PINGED=1
    rows=$(server_rows "$COUNTRIES" "$MIN_BW" "$exclude")
    n=$(wc -l <<<"$rows"); [ "$n" -gt "$MAX_HISTORY_CHECKS" ] && n=$MAX_HISTORY_CHECKS
    echo "Reading 10 days of outage history for $n servers ($n API requests)..."
    fetch_history "$MAX_HISTORY_CHECKS" 1 <<<"$rows"
    for round in $(seq 1 "$DEEP_ROUNDS"); do
        rows=$(server_rows "$COUNTRIES" "$MIN_BW" "$exclude")
        n=$(shallow_top <<<"$rows" | wc -l)
        [ "$n" -gt 0 ] || break
        echo "Reading $RELIABILITY_DAYS days of history for $n of the top $DEEP_CHECKS ($(( n * (chunks - 1) )) API requests)..."
        fetch_history "$DEEP_CHECKS" "$chunks" <<<"$rows" || break
    done
    RANKED=$(server_rows "$COUNTRIES" "$MIN_BW" "$exclude")
}

# measure_pings — reads server_rows output on stdin, pings every server's
# entry IP from this machine (3 pings, 32 servers at a time) and writes
# "name<TAB>avg ms" to $PING_FILE. No API requests. Returns 1 without ping.
measure_pings() {
    : > "$PING_FILE"
    if ! command -v ping >/dev/null; then
        warn "ping is not installed, so ping is left out of the ranking."
        return 1
    fi
    cut -f1,14 | awk -F'\t' '$2 != "-"' | tr '\t' ' ' \
        | xargs -P 32 -L 1 sh -c 'ms=$(ping -c 3 -W 1 -q "$2" 2>/dev/null | sed -n "s#.*= *[0-9.]*/\([0-9.]*\)/.*#\1#p"); printf "%s\t%s\n" "$1" "$ms"' _ \
        >> "$PING_FILE"
}

# largest_size — the biggest bw_max among healthy servers in $STATUS: the
# default minimum bandwidth when none is saved (sizes are never hardcoded).
largest_size() {
    jget 'max(s["bw_max"] for s in d["servers"] if s.get("health") == "ok")' <<<"$STATUS"
}

# country_rows <min_bw> — TSV: cc, name, healthy servers >= min_bw, all servers.
country_rows() {
    MINBW="$1" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
minbw = int(os.environ["MINBW"] or 0)
for c in sorted(d["countries"], key=lambda c: c["country_name"]):
    big = sum(1 for s in d["servers"] if s["country_code"] == c["country_code"]
              and s.get("health") == "ok" and s.get("bw_max", 0) >= minbw)
    print("\t".join(str(v) for v in (c["country_code"], c["country_name"], big, c.get("servers", 0))))' <<<"$STATUS"
}

pick_server() {
    local match rows i choice line
    STATUS=$(api status)
    [ "$(result_of <<<"$STATUS")" = ok ] || die "Could not read AirVPN server status."

    if [ -n "$ARG_SERVER" ]; then
        match=$(N="$ARG_SERVER" jget '[s["public_name"] for s in d["servers"] if s["public_name"].lower() == __import__("os").environ["N"].lower()][0]' <<<"$STATUS")
        [ -n "$match" ] || die "\"$ARG_SERVER\" is not an AirVPN server name (see https://airvpn.org/status/)."
        SERVER=$match
        set_server_label; ok "Server: $SERVER_LABEL"; return 0
    fi

    echo
    # Sizes come from the live server list, so new or retired sizes show up
    # as they are; with nothing saved the default is the largest size.
    local sizes
    sizes=$(jget '", ".join("%d (%d servers)" % (b, n) for b, n in sorted(__import__("collections").Counter(s["bw_max"] for s in d["servers"] if s.get("health") == "ok").items()))' <<<"$STATUS")
    echo "AirVPN server sizes right now, in Mbit/s: ${sizes:-unknown}"
    [ -n "$MIN_BW" ] || MIN_BW=$(largest_size)
    MIN_BW=$(ask "Minimum server bandwidth in Mbit/s (0 = any)" "$MIN_BW")
    [[ "$MIN_BW" =~ ^[0-9]+$ ]] || die "Bandwidth must be a number."

    echo
    # Only countries with at least one healthy server that meets the bandwidth
    # filter: there is no point picking one without.
    local usable
    usable=$(country_rows "$MIN_BW" | awk -F'\t' '$3 > 0')
    [ -n "$usable" ] || die "No healthy AirVPN server has >= $MIN_BW Mbit/s right now. Run again with a lower minimum."
    echo "Countries with healthy servers of >= $MIN_BW Mbit/s (matching / all servers):"
    awk -F'\t' '{ printf "  %s  %-22s %2d / %2d\n", $1, $2, $3, $4 }' <<<"$usable" | column -c "${COLUMNS:-100}" 2>/dev/null \
        || awk -F'\t' '{ printf "  %s  %-22s %2d / %2d\n", $1, $2, $3, $4 }' <<<"$usable"
    # Enter keeps the saved list, so "all" is the way back to every country.
    # Saved countries that no longer qualify (e.g. after raising the minimum)
    # are dropped from it first, so Enter cannot loop on them.
    local known all_codes cc saved="" dropped=""
    known=$(cut -f1 <<<"$usable")
    all_codes=$(country_rows 0 | cut -f1)
    for cc in $COUNTRIES; do
        if grep -qxF "$cc" <<<"$known"; then saved="$saved $cc"; else dropped="$dropped $cc"; fi
    done
    COUNTRIES=$(xargs <<<"$saved")
    [ -n "$dropped" ] && echo "Dropped from your saved countries (no servers >= $MIN_BW Mbit/s):$dropped"
    saved=$COUNTRIES
    while true; do
        if [ -n "$COUNTRIES" ]; then
            COUNTRIES=$(ask "Preferred country codes, space separated (Enter keeps, \"all\" = every country)" "$COUNTRIES")
        else
            COUNTRIES=$(ask "Preferred country codes, space separated (Enter = every country)" "")
        fi
        COUNTRIES=$(tr 'A-Z,' 'a-z ' <<<"$COUNTRIES" | xargs)
        [ "$COUNTRIES" = all ] && COUNTRIES=""
        cc=""
        for cc in $COUNTRIES; do grep -qxF "$cc" <<<"$known" || break; cc=""; done
        [ -z "$cc" ] && break
        if grep -qxF "$cc" <<<"$all_codes"; then
            echo "$cc has no healthy servers with >= $MIN_BW Mbit/s; pick from the list."
        else
            echo "Unknown country code: $cc"
        fi
        COUNTRIES=$saved
    done

    echo
    rank_servers || die "No healthy server matches those filters. Lower the bandwidth or add countries."
    rows=$RANKED
    echo
    echo "Ranked best first on load + reliability + ping (1 outage a month = $OUTAGE_PENALTY% load, 1 ms of ping = $PING_WEIGHT% load):"
    printf '  %3s  %-14s %-3s %-22s %5s %6s' "#" "Server" "CC" "Location" "Load" "Users"
    [ "$PINGED" = 1 ] && printf ' %6s' "Ping"
    printf '  %s\n' "Outages"
    i=0
    local adjusted=0 unknown=0
    while IFS=$'\t' read -r name cc loc load rload users ms hist long short days _ _ _; do
        i=$(( i + 1 ))
        if [ "$rload" != "$load" ]; then load="~$rload"; adjusted=1; fi
        printf '  %3d) %-14s %-3s %-22.22s %4s%% %6s' "$i" "$name" "$cc" "$loc" "$load" "$users"
        if [ "$PINGED" = 1 ]; then
            if [ "$ms" = - ]; then printf ' %6s' "-"; else printf ' %4sms' "$ms"; fi
        fi
        case "$hist" in
            ok|new)  printf '  %s long, %s short in %sd' "$long" "$short" "$days"
                     [ "$hist" = new ] && [ "$days" -lt 10 ] && printf ' (new server)' ;;
            unknown) printf '  unknown'; unknown=$(( unknown + 1 )) ;;
            *)       printf '  not checked' ;;
        esac
        echo
    done <<<"$rows"
    echo
    [ "$PINGED" = 1 ] && awk -F'\t' '$7 == "-" { f = 1 } END { exit !f }' <<<"$rows" && echo "Ping \"-\" = no answer."
    [ "$adjusted" = 1 ] && echo "~ = load once its users are back: it had an outage in the last few hours, so its current load is misleadingly low."
    echo "Outages: from AirVPN's session history, $RELIABILITY_DAYS days for the top $DEEP_CHECKS and 10 days for the others."
    local shallow
    shallow=$(shallow_top <<<"$rows" | xargs)
    echo "  long = down ~30 min or more (counts fully, more if it lasted hours); short = under ~20 min (counts $SHORT_OUTAGE_WEIGHT)."
    [ -n "$shallow" ] && warn "Only 10 days of history for $shallow (stopped by the re-check or request limit), so their rank is less certain."
    [ "$unknown" -gt 0 ] && warn "Could not read the outage history of $unknown server(s); they are ranked as unreliable. If every server shows unknown, AirVPN's server API may have changed."
    while true; do
        choice=$(ask "Server number (1-$i)" 1)
        [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ] && break
        echo "Type a number from the list."
    done
    line=$(sed -n "${choice}p" <<<"$rows")
    SERVER=$(cut -f1 <<<"$line")
    set_server_label; ok "Server: $SERVER_LABEL"
}

set_server_label() {
    SERVER_LABEL="$SERVER ($(N="$SERVER" jget '[s["location"] + ", " + s["country_name"] for s in d["servers"] if s["public_name"] == __import__("os").environ["N"]][0]' <<<"$STATUS"))"
}

# ── Step 3: generate wg0.conf ───────────────────────────────────────────────
generate() {
    local port=${ARG_PORT:-$WG_PORT} conf addr tmp
    [[ " $WG_PORTS " == *" $port "* ]] || die "Port must be one of: $WG_PORTS"
    WG_PORT=$port

    # The device goes by name: an unknown name or an id is silently replaced
    # by the account's default device, so the Address is checked below.
    conf=$(api generator protocols="wireguard_1_udp_$port" servers="$SERVER" system=linux \
        device="$DEVICE" iplayer_entry=ipv4 iplayer_exit=ipv4)
    if ! grep -q '^\[Interface\]' <<<"$conf"; then
        die "AirVPN did not return a config: $(result_of <<<"$conf")"
    fi
    grep -q '^PrivateKey' <<<"$conf" && grep -q '^Endpoint' <<<"$conf" || die "AirVPN returned an incomplete config."
    addr=$(sed -n 's/^Address *= *//p' <<<"$conf")
    [ "$addr" = "$DEVICE_IP/32" ] \
        || die "AirVPN returned a config for another device (Address $addr, expected $DEVICE_IP/32). Not writing it."

    tmp=$(mktemp "$OUT_DIR/.wg0.conf.XXXXXX") || die "Cannot write to $OUT_DIR."
    printf '%s\n' "$conf" > "$tmp"
    # Same ownership arr-complete.sh uses for qBittorrent's wg0.conf.
    if getent group apps >/dev/null 2>&1; then chown root:apps "$tmp"; chmod 660 "$tmp"; else chmod 600 "$tmp"; fi
    if [ -s "$OUTPUT" ] && ! cmp -s "$tmp" "$OUTPUT"; then
        cp -p "$OUTPUT" "$OUTPUT.bak" && ok "Previous config saved as $OUTPUT.bak"
    fi
    mv "$tmp" "$OUTPUT"
    ok "Wrote $OUTPUT (WireGuard, Linux, IPv4 only, $(sed -n 's/^Endpoint *= *//p' <<<"$conf"))"
}

# ── Alerts ──────────────────────────────────────────────────────────────────
# send_alert <title> <message> — returns non-zero if the channel refused it.
send_alert() {
    local title=$1 msg=$2 code hdr=()
    case "$ALERT_CHANNEL" in
        none) return 0 ;;
        ntfy)
            [ -n "$NTFY_TOKEN" ] && hdr=(-H "Authorization: Bearer $NTFY_TOKEN")
            code=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' "${hdr[@]}" \
                -H "Title: $title" -H "Tags: warning" --data-binary "$msg" "$NTFY_URL") ;;
        discord)
            code=$(T="$title" M="$msg" python3 -c 'import json, os; print(json.dumps({"content": "**%s**\n%s" % (os.environ["T"], os.environ["M"])}))' \
                | curl -sS -m 20 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- "$DISCORD_WEBHOOK") ;;
        gotify)
            code=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' -H "X-Gotify-Key: $GOTIFY_TOKEN" \
                -F "title=$title" -F "message=$msg" -F "priority=8" "${GOTIFY_URL%/}/message") ;;
        telegram)
            code=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
                --data-urlencode "text=$title"$'\n'"$msg" "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage") ;;
        *) warn "Unknown alert channel: $ALERT_CHANNEL"; return 1 ;;
    esac
    [[ "$code" =~ ^2[0-9][0-9]$ ]] && return 0
    warn "Sending the $ALERT_CHANNEL alert failed (HTTP $code)."; return 1
}

configure_alerts() {
    local c n flag
    echo
    echo "Alert channel:"
    echo "  1) None"
    echo "  2) ntfy"
    echo "  3) Discord webhook"
    echo "  4) Gotify"
    echo "  5) Telegram bot"
    case "$ALERT_CHANNEL" in ntfy) c=2 ;; discord) c=3 ;; gotify) c=4 ;; telegram) c=5 ;; *) c=1 ;; esac
    case "$(ask "Channel" "$c")" in
        2) ALERT_CHANNEL=ntfy
           NTFY_URL=$(ask "ntfy topic URL (e.g. https://ntfy.sh/my-airvpn-alerts)" "$NTFY_URL")
           NTFY_TOKEN=$(ask "ntfy access token (empty if none)" "$NTFY_TOKEN") ;;
        3) ALERT_CHANNEL=discord
           DISCORD_WEBHOOK=$(ask "Discord webhook URL" "$DISCORD_WEBHOOK") ;;
        4) ALERT_CHANNEL=gotify
           GOTIFY_URL=$(ask "Gotify URL (e.g. https://gotify.example.com)" "$GOTIFY_URL")
           GOTIFY_TOKEN=$(ask "Gotify application token" "$GOTIFY_TOKEN") ;;
        5) ALERT_CHANNEL=telegram
           TELEGRAM_TOKEN=$(ask "Telegram bot token" "$TELEGRAM_TOKEN")
           TELEGRAM_CHAT_ID=$(ask "Telegram chat ID" "$TELEGRAM_CHAT_ID") ;;
        *) ALERT_CHANNEL=none ;;
    esac
    [ "$ALERT_CHANNEL" = none ] && { ok "Alerts off"; return 0; }

    while true; do
        echo
        echo "Events to alert on (type a number to toggle, Enter when done):"
        printf '  [%s] 1) Server down (health error, or removed by AirVPN)\n' "$(mark "$EVENT_SERVER_DOWN")"
        printf '  [%s] 2) Server warning (e.g. packet loss, maintenance announced)\n' "$(mark "$EVENT_SERVER_WARNING")"
        printf '  [%s] 3) Server load at or above %s%%\n' "$(mark "$EVENT_SERVER_LOAD")" "$LOAD_THRESHOLD"
        printf '  [%s] 4) Device %s not connected to AirVPN\n' "$(mark "$EVENT_DEVICE_OFFLINE")" "${DEVICE:-?}"
        printf '  [%s] 5) Subscription expires within %s days\n' "$(mark "$EVENT_EXPIRY")" "$EXPIRY_DAYS"
        printf '  [%s] 6) All clear when a problem goes away\n' "$(mark "$EVENT_RECOVERY")"
        n=$(ask "Toggle" "")
        case "$n" in
            "") break ;;
            1) EVENT_SERVER_DOWN=$(( 1 - EVENT_SERVER_DOWN )) ;;
            2) EVENT_SERVER_WARNING=$(( 1 - EVENT_SERVER_WARNING )) ;;
            3) EVENT_SERVER_LOAD=$(( 1 - EVENT_SERVER_LOAD ))
               if [ "$EVENT_SERVER_LOAD" = 1 ]; then
                   LOAD_THRESHOLD=$(ask "Load threshold in %" "$LOAD_THRESHOLD")
                   [[ "$LOAD_THRESHOLD" =~ ^[0-9]+$ ]] || LOAD_THRESHOLD=90
               fi ;;
            4) EVENT_DEVICE_OFFLINE=$(( 1 - EVENT_DEVICE_OFFLINE )) ;;
            5) EVENT_EXPIRY=$(( 1 - EVENT_EXPIRY ))
               if [ "$EVENT_EXPIRY" = 1 ]; then
                   EXPIRY_DAYS=$(ask "Warn how many days before expiry" "$EXPIRY_DAYS")
                   [[ "$EXPIRY_DAYS" =~ ^[0-9]+$ ]] || EXPIRY_DAYS=7
               fi ;;
            6) EVENT_RECOVERY=$(( 1 - EVENT_RECOVERY )) ;;
            *) echo "Pick 1-6." ;;
        esac
    done
    if yesno "Send a test alert now?" y; then
        send_alert "AirVPN monitor test" "Test from airvpn-wg.sh on $(hostname): alerts for $DEVICE work." \
            && ok "Test alert sent via $ALERT_CHANNEL"
    fi
}

mark() { [ "$1" = 1 ] && echo x || echo " "; }

# key_reasons — what the cron monitor needs the API key for, comma separated;
# empty when nothing does (alerts off or only server events, no auto-switch),
# in which case the key is not saved.
key_reasons() {
    local r=()
    [ "$AUTO_SWITCH" = 1 ] && r+=("auto-switch")
    if [ "$ALERT_CHANNEL" != none ]; then
        [ "$EVENT_DEVICE_OFFLINE" = 1 ] && r+=("device offline alerts")
        [ "$EVENT_EXPIRY" = 1 ] && r+=("expiry alerts")
    fi
    local IFS=,
    echo "${r[*]}" | sed 's/,/, /g'
}

# save_monitor_settings — after the alert/auto-switch questions: make sure a
# key is at hand if the monitor needs one, save, and say what was kept.
save_monitor_settings() {
    local why
    why=$(key_reasons)
    [ -n "$why" ] && [ -z "$AIRVPN_API_KEY" ] && ensure_key
    save_settings
    if [ -n "$why" ]; then
        ok "Settings and API key saved in $ENV_FILE (root only); the monitor needs the key for $why."
    else
        ok "Settings saved in $ENV_FILE (no API key: alerts and auto-switch don't need it)."
    fi
}

configure_autoswitch() {
    echo
    echo "Auto-switch: when $SERVER goes down, the monitor rewrites wg0.conf for the next"
    echo "best healthy server matching your filters (${COUNTRIES:-all countries}, >= ${MIN_BW:-the largest size} Mbit/s;"
    echo "load + reliability + ping, as in the list) and restarts the container that uses it."
    if yesno "Enable auto-switch?" "$([ "$AUTO_SWITCH" = 1 ] && echo y || echo n)"; then
        AUTO_SWITCH=1
        RESTART_CONTAINER=$(ask "Container to restart after a switch (\"none\" = don't restart)" "${RESTART_CONTAINER:-none}")
        [ "$RESTART_CONTAINER" = none ] && RESTART_CONTAINER=""
        if [ -n "$RESTART_CONTAINER" ] && command -v docker >/dev/null && ! docker inspect "$RESTART_CONTAINER" >/dev/null 2>&1; then
            warn "No container named $RESTART_CONTAINER right now; a switch will still rewrite wg0.conf."
        fi
        ok "Auto-switch on${RESTART_CONTAINER:+, restarts $RESTART_CONTAINER}"
    else
        AUTO_SWITCH=0
    fi
}

# setup_cron — the monitor only works from cron, so add, update or remove its
# job to match the settings: needed when alerts or auto-switch are on. On
# TrueNAS the job goes through the middleware (midclt), so it shows under
# System -> Advanced Settings -> Cron Jobs and survives updates; elsewhere it
# goes in root's crontab. Each job is tagged with its wg0.conf, so re-running
# updates it instead of adding another. Falls back to printing the line.
setup_cron() {
    local self cmd tag want=0 ids line
    self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
    cmd="bash $(printf '%q' "$self") monitor --output $(printf '%q' "$OUTPUT")"
    tag="airvpn-wg monitor: $OUTPUT"
    { [ "$ALERT_CHANNEL" != none ] || [ "$AUTO_SWITCH" = 1 ]; } && want=1
    echo
    if command -v midclt >/dev/null; then
        ids=$(midclt call cronjob.query 2>/dev/null | TAG="$tag" python3 -c '
import json, os, sys
try:
    print(" ".join(str(j["id"]) for j in json.load(sys.stdin) if j.get("description") == os.environ["TAG"]))
except Exception:
    sys.exit(1)') || { warn "Could not read the TrueNAS cron jobs."; cron_manual "$cmd" "$want"; return; }
        if [ "$want" = 0 ]; then
            for line in $ids; do midclt call cronjob.delete "$line" >/dev/null && ok "Removed the monitor's cron job (alerts and auto-switch are off)"; done
            return 0
        fi
        line=$(CMD="$cmd" TAG="$tag" python3 -c '
import json, os
print(json.dumps({"user": "root", "command": os.environ["CMD"], "description": os.environ["TAG"], "enabled": True,
                  "schedule": {"minute": "*/5", "hour": "*", "dom": "*", "month": "*", "dow": "*"}}))')
        if [ -n "$ids" ]; then
            midclt call cronjob.update "${ids%% *}" "$line" >/dev/null && { ok "Updated the TrueNAS cron job: the monitor runs every 5 minutes"; return 0; }
        else
            midclt call cronjob.create "$line" >/dev/null && { ok "Added a TrueNAS cron job (System -> Advanced Settings -> Cron Jobs): the monitor runs every 5 minutes"; return 0; }
        fi
        warn "Could not save the TrueNAS cron job."
        cron_manual "$cmd" "$want"
    elif command -v crontab >/dev/null; then
        # Read the whole crontab before writing it back, keeping every other
        # line: piping "crontab -l" straight into "crontab -" can lose them.
        local current
        current=$(crontab -l 2>/dev/null | grep -vF "# $tag")
        line=$( { [ -n "$current" ] && printf '%s\n' "$current"; [ "$want" = 1 ] && echo "*/5 * * * * $cmd >/dev/null # $tag"; } | crontab - 2>&1 ) \
            || { warn "Could not update the crontab: $line"; cron_manual "$cmd" "$want"; return; }
        if [ "$want" = 1 ]; then ok "Added to root's crontab: the monitor runs every 5 minutes"; else ok "No monitor cron job needed (alerts and auto-switch are off)"; fi
    else
        cron_manual "$cmd" "$want"
    fi
}

# cron_manual <command> <wanted> — what to add by hand when setup_cron can't.
cron_manual() {
    [ "$2" = 1 ] || return 0
    echo "Run the monitor every 5 minutes (1-3 API requests per run, plus up to about"
    echo "$(( MAX_HISTORY_CHECKS + DEEP_CHECKS * 8 )) when it switches servers). TrueNAS: System -> Advanced Settings ->"
    echo "Cron Jobs -> Add, user root, command:"
    echo "    $1"
    echo "Other Linux: add to root's crontab (crontab -e):"
    echo "    */5 * * * * $1"
}

# ── Auto-switch ─────────────────────────────────────────────────────────────
# auto_switch <status json> — regenerate wg0.conf for the best healthy server
# matching the saved filters (never the current one), save it as the new
# server and restart the container. Sets SWITCH_TO on success; SWITCH_ERR
# says why it failed, or what went wrong after the switch (restart).
SWITCH_TO=""; SWITCH_ERR=""; SWITCH_WARN=""
auto_switch() {
    local old=$SERVER next out
    STATUS=$1
    [ -n "$MIN_BW" ] || MIN_BW=$(largest_size)
    # Same ranking as the menu (pings, outage history, reliability), read fresh.
    rank_servers "$old"
    next=$(head -n 1 <<<"$RANKED" | cut -f1)
    if [ -z "$next" ]; then
        SWITCH_ERR="no healthy server with >= $MIN_BW Mbit/s in ${COUNTRIES:-any country}"
        return 1
    fi
    [ -n "$AIRVPN_API_KEY" ] || { SWITCH_ERR="no API key saved in $ENV_FILE"; return 1; }
    # Same device as now: its address is in the current wg0.conf, and
    # generate checks the new config against it.
    DEVICE_IP=$(sed -n 's/^Address *= *\([0-9.]*\).*/\1/p' "$OUTPUT" 2>/dev/null)
    [ -n "$DEVICE_IP" ] || { SWITCH_ERR="cannot read the device address from $OUTPUT"; return 1; }
    case "$(head -n 1 <<<"$RANKED" | cut -f8)" in
        ok|new) ;;
        *) SWITCH_WARN="Its outage history could not be read, so its reliability is not verified." ;;
    esac
    SERVER=$next
    if ! out=$( (generate) 2>&1 ); then
        SERVER=$old
        SWITCH_ERR=$(tail -n 1 <<<"$out" | sed 's/^❌ //')
        return 1
    fi
    echo "$out"
    save_settings
    SWITCH_TO=$next
    if [ -n "$RESTART_CONTAINER" ]; then
        if docker restart "$RESTART_CONTAINER" >/dev/null 2>&1; then
            ok "Restarted $RESTART_CONTAINER"
        else
            SWITCH_ERR="docker restart $RESTART_CONTAINER failed; restart it by hand."
        fi
    fi
    return 0
}

# ── Monitor (cron) ──────────────────────────────────────────────────────────
# One check. Conditions that are new since the last run are alerted once;
# conditions that went away get an "all clear" (if enabled). A condition whose
# alert could not be sent is not remembered, so the next run tries again.
monitor() {
    [ -f "$ENV_FILE" ] || die "No $ENV_FILE. Run setup first."
    [ -n "$SERVER" ] || die "No server saved in $ENV_FILE. Run setup first."
    local status ui target conds=() line key title prev active=()

    status=$(api status)
    if [ "$(result_of <<<"$status")" != ok ]; then
        warn "Could not reach the AirVPN status API; no alerts sent this run."
        exit 2
    fi
    target=$(N="$SERVER" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
label = os.environ["N"]
m = [s for s in d["servers"] if s["public_name"] == label]
if not m:
    print("\x1f".join(("missing", "0", "", label)))
else:
    s = m[0]
    print("\x1f".join((s.get("health", "?"), str(s.get("currentload", 0)), " ".join(s.get("warning", "").split()), label)))' <<<"$status")
    # \x1f, not a tab: read merges runs of tabs, so an empty warning would
    # shift the label into its place.
    local health load why label
    IFS=$'\x1f' read -r health load why label <<<"$target"
    echo "$(date '+%F %T') $label: health $health, load $load%"

    local down=0 msg
    { [ "$health" = error ] || [ "$health" = missing ]; } && down=1
    [ "$health" = missing ] && why="no longer listed by AirVPN"
    if [ "$down" = 1 ] && [ "$AUTO_SWITCH" = 1 ]; then
        if auto_switch "$status"; then
            # The old server's alerts no longer apply: forget them without
            # "all clear" messages and report the switch instead.
            rm -f "$STATE_FILE"
            msg="$label is down (${why:-health error}). wg0.conf now uses $SWITCH_TO.${SWITCH_WARN:+ $SWITCH_WARN}"
            if [ -n "$SWITCH_ERR" ]; then msg="$msg $SWITCH_ERR"
            elif [ -n "$RESTART_CONTAINER" ]; then msg="$msg Restarted $RESTART_CONTAINER."; fi
            send_alert "AirVPN switched from $label to $SWITCH_TO" "$msg"
            echo "    switched from $label to $SWITCH_TO"
            return 0
        fi
        conds+=("noswitch|AirVPN auto-switch failed|Could not switch away from $label: $SWITCH_ERR")
    fi
    if [ "$EVENT_SERVER_DOWN" = 1 ] && [ "$down" = 1 ]; then
        conds+=("down|AirVPN $label is down|$label is down: ${why:-health error}. Run airvpn-wg.sh to pick another server.")
    elif [ "$EVENT_SERVER_WARNING" = 1 ] && [ "$health" = warning ]; then
        conds+=("warning|AirVPN $label has a warning|${why:-AirVPN reports a warning for $label.}")
    fi
    if [ "$EVENT_SERVER_LOAD" = 1 ] && [ "$health" != missing ] && [ "$load" -ge "$LOAD_THRESHOLD" ]; then
        conds+=("load|AirVPN $label load ${LOAD_THRESHOLD}%+|$label is at $load% load (threshold $LOAD_THRESHOLD%).")
    fi

    if [ "$EVENT_DEVICE_OFFLINE" = 1 ] || [ "$EVENT_EXPIRY" = 1 ]; then
        if [ -z "$AIRVPN_API_KEY" ]; then
            warn "Device/expiry events need the API key in $ENV_FILE; skipped."
        else
            ui=$(api userinfo)
            if [ "$(result_of <<<"$ui")" = ok ]; then
                if [ "$EVENT_DEVICE_OFFLINE" = 1 ] && [ "$(DEV="$DEVICE" jget 'any(s["device_name"] == __import__("os").environ["DEV"] for s in d.get("sessions", []))' <<<"$ui")" != True ]; then
                    conds+=("offline|AirVPN device $DEVICE offline|Device $DEVICE has no active AirVPN session.")
                fi
                local days
                days=$(jget 'd["user"]["expiration_days"]' <<<"$ui")
                if [ "$EVENT_EXPIRY" = 1 ] && [[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -le "$EXPIRY_DAYS" ]; then
                    conds+=("expiry|AirVPN subscription expires in $days days|Your AirVPN subscription expires in $days days ($(jget 'd["user"]["expiration_date"]' <<<"$ui") UTC).")
                fi
            else
                warn "userinfo failed: $(result_of <<<"$ui")"
            fi
        fi
    fi

    prev=$(cat "$STATE_FILE" 2>/dev/null || true)
    for line in "${conds[@]}"; do
        key=${line%%|*}; title=${line#*|}; title=${title%%|*}
        if grep -q "^$key|" <<<"$prev"; then
            active+=("$key|$title")
        elif send_alert "$title" "${line#*|*|}"; then
            echo "    alert sent: $title"
            active+=("$key|$title")
        fi
    done
    while IFS='|' read -r key title; do
        [ -n "$key" ] || continue
        printf '%s\n' "${conds[@]}" | grep -q "^$key|" && continue
        if [ "$EVENT_RECOVERY" = 1 ]; then
            send_alert "All clear: $title" "Resolved: $title" && echo "    all clear sent: $title"
        fi
    done <<<"$prev"
    if [ ${#active[@]} -gt 0 ]; then printf '%s\n' "${active[@]}" > "$STATE_FILE"; else rm -f "$STATE_FILE"; fi
}

# ── Main ────────────────────────────────────────────────────────────────────
case "$CMD" in
    monitor)
        monitor ;;
    test-alert)
        [ "$ALERT_CHANNEL" != none ] || die "No alert channel configured. Run: airvpn-wg.sh alerts --output $OUTPUT"
        send_alert "AirVPN monitor test" "Test from airvpn-wg.sh on $(hostname)." && ok "Test alert sent via $ALERT_CHANNEL" ;;
    alerts)
        [ -f "$ENV_FILE" ] || die "No $ENV_FILE. Run setup first."
        configure_alerts; configure_autoswitch; save_monitor_settings; setup_cron ;;
    setup)
        info "AirVPN WireGuard config for $OUTPUT"
        ensure_key
        pick_device
        pick_server
        generate
        if [ -n "$ARG_DEVICE" ] && [ -n "$ARG_SERVER" ]; then
            save_settings
        else
            echo
            echo "Optional: a monitor (run from cron) can alert you about problems and switch"
            echo "servers automatically when this one goes down."
            yesno "Set up alerts?" "$([ "$ALERT_CHANNEL" = none ] && echo n || echo y)" && configure_alerts
            configure_autoswitch
            save_monitor_settings
            setup_cron
        fi
        echo
        info "Done. Restart the container using it (e.g. docker restart qbittorrent) to switch over."
        ;;
esac
