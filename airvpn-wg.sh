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
#      bandwidth (AirVPN servers are 2000, 6000 or 20000 Mbit/s), healthy
#      servers only, sorted by load, free bandwidth, users, measured ping
#      or a ping + load balance. Or pick a whole
#      country and let AirVPN choose a server at connect time.
#   3. Generate: writes wg0.conf, backs up the previous one, and checks the
#      config really belongs to the chosen device.
#   4. Alerts (optional): pick a channel (AirVPN notification, ntfy,
#      Discord, Gotify, Telegram) and the events you care about, then run
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
# script caps itself at MAX_CALLS requests per run; "monitor" uses 1 to 3.
#
# Run in the TrueNAS shell as root:
#   sudo su -c "wget https://raw.githubusercontent.com/serversathome/ServersatHome/refs/heads/main/airvpn-wg.sh && chmod +x airvpn-wg.sh && bash airvpn-wg.sh"
#
# Usage: see "airvpn-wg.sh --help".
# ============================================================================

set -uo pipefail

API="https://airvpn.org/api"
MAX_CALLS=40                 # hard cap per run, far below AirVPN's ban limit
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
  --server NAME|CC    server name (e.g. Menkent) or country code (e.g. nl)
                      (skips the server menu)
  --port PORT         WireGuard port: 1637 (default), 47107 or 51820
  -h, --help          this help

The API key is read from airvpn-wg.env, or from AIRVPN_API_KEY in the
environment, or asked for. With --device and --server, setup runs without
menus (alerts are left as they are), e.g. from another script:
  AIRVPN_API_KEY=... airvpn-wg.sh --output /path/wg0.conf --device truenas --server nl
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
trap 'rm -f "$CALLS_FILE" "$PING_FILE"' EXIT

# ── Saved settings ──────────────────────────────────────────────────────────
# Everything the menus remember, with defaults. A key in the environment wins
# over the saved one.
ENV_KEY=${AIRVPN_API_KEY:-}
AIRVPN_API_KEY=""
DEVICE=""; SERVER_MODE=""; SERVER=""; WG_PORT=1637
COUNTRIES=""; MIN_BW=20000; SORT=load
ALERT_CHANNEL=none
NTFY_URL=""; NTFY_TOKEN=""; DISCORD_WEBHOOK=""
GOTIFY_URL=""; GOTIFY_TOKEN=""; TELEGRAM_TOKEN=""; TELEGRAM_CHAT_ID=""
EVENT_SERVER_DOWN=1; EVENT_SERVER_WARNING=1; EVENT_SERVER_LOAD=0; LOAD_THRESHOLD=90
EVENT_DEVICE_OFFLINE=0; EVENT_EXPIRY=1; EXPIRY_DAYS=7; EVENT_RECOVERY=1
AUTO_SWITCH=0; RESTART_CONTAINER=qbittorrent
SAVE_KEY=1
SETTINGS="AIRVPN_API_KEY DEVICE SERVER_MODE SERVER WG_PORT COUNTRIES MIN_BW SORT
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
            if [ "$v" = AIRVPN_API_KEY ] && [ "$SAVE_KEY" != 1 ]; then echo "AIRVPN_API_KEY=''"; continue; fi
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
    local n p
    n=$(( $(cat "$CALLS_FILE") + 1 ))
    [ "$n" -gt "$MAX_CALLS" ] && die "Stopping after $MAX_CALLS API requests this run (AirVPN bans IPs above 600 per 10 minutes)."
    echo "$n" > "$CALLS_FILE"
    local args=() hdr=()
    for p in "$@"; do args+=(--data-urlencode "$p"); done
    [ -n "$AIRVPN_API_KEY" ] && hdr=(-H "API-KEY: $AIRVPN_API_KEY")
    curl -sS -m 30 -G "${hdr[@]}" "${args[@]}" "$API/$svc/"
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

# server_rows <countries> <min_bw> <sort> — healthy servers, TSV:
# name, cc, location, load, bw, bw_max, users, ping ms ("-" if not
# measured), recovering (1 = under 5% load), entry IP.
# Pings come from $PING_FILE (see measure_pings); an unanswered ping sorts
# last. Recovering servers sort last whatever the order: AirVPN drops a
# server's users during an outage (packet loss, maintenance), so a server
# that has just come back shows "ok" with almost no load and would otherwise
# top the "lowest load" list.
server_rows() {
    CC="$1" MINBW="$2" SORTBY="$3" PINGS="$PING_FILE" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
cc = set(os.environ["CC"].lower().split())
minbw = int(os.environ["MINBW"] or 0)
pings = {}
for line in open(os.environ["PINGS"]):
    n, _, ms = line.rstrip("\n").partition("\t")
    try:
        pings[n] = float(ms)
    except ValueError:
        pass
ping = lambda s: pings.get(s["public_name"], 9999)
recovering = lambda s: s["currentload"] < 5
rows = [s for s in d["servers"] if s.get("health") == "ok" and s.get("bw_max", 0) >= minbw
        and (not cc or s["country_code"] in cc)]
key = {"load":     lambda s: (s["currentload"], -(s["bw_max"] - s["bw"])),
       "free":     lambda s: (-(s["bw_max"] - s["bw"]), s["currentload"]),
       "users":    lambda s: (s.get("users", 0), s["currentload"]),
       "ping":     lambda s: (ping(s), s["currentload"]),
       "balanced": lambda s: (ping(s) + s["currentload"], ping(s))}[os.environ["SORTBY"]]
for s in sorted(rows, key=lambda s: (recovering(s), key(s))):
    p = pings.get(s["public_name"])
    print("\t".join([str(s.get(k, "")) for k in
          ("public_name", "country_code", "location", "currentload", "bw", "bw_max", "users")]
          + ["%.0f" % p if p is not None else "-", "1" if recovering(s) else "0", s.get("ip_v4_in1", "")]))' <<<"$STATUS"
}

# measure_pings — reads server_rows output on stdin, pings every server's
# entry IP from this machine (3 pings, 32 servers at a time) and writes
# "name<TAB>avg ms" to $PING_FILE. No API requests. Returns 1 without ping.
measure_pings() {
    : > "$PING_FILE"
    if ! command -v ping >/dev/null; then
        warn "ping is not installed; sorting by load instead."
        return 1
    fi
    cut -f1,10 | awk -F'\t' '$2 != ""' | tr '\t' ' ' \
        | xargs -P 32 -L 1 sh -c 'ms=$(ping -c 3 -W 1 -q "$2" 2>/dev/null | sed -n "s#.*= *[0-9.]*/\([0-9.]*\)/.*#\1#p"); printf "%s\t%s\n" "$1" "$ms"' _ \
        >> "$PING_FILE"
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
    local match rows i choice line sort_choice
    STATUS=$(api status)
    [ "$(result_of <<<"$STATUS")" = ok ] || die "Could not read AirVPN server status."

    if [ -n "$ARG_SERVER" ]; then
        match=$(N="$ARG_SERVER" jget '[s["public_name"] for s in d["servers"] if s["public_name"].lower() == __import__("os").environ["N"].lower()][0]' <<<"$STATUS")
        if [ -n "$match" ]; then
            SERVER_MODE=server; SERVER=$match
        else
            match=$(N="$ARG_SERVER" jget '[c["country_code"] for c in d["countries"] if c["country_code"] == __import__("os").environ["N"].lower()][0]' <<<"$STATUS")
            [ -n "$match" ] || die "\"$ARG_SERVER\" is neither an AirVPN server name nor a country code."
            SERVER_MODE=country; SERVER=$match
        fi
        set_server_label; ok "Server: $SERVER_LABEL"; return 0
    fi

    echo
    echo "AirVPN servers come in 2000, 6000 and 20000 Mbit/s sizes."
    MIN_BW=$(ask "Minimum server bandwidth in Mbit/s (0 = any)" "$MIN_BW")
    [[ "$MIN_BW" =~ ^[0-9]+$ ]] || die "Bandwidth must be a number."

    echo
    echo "Countries (healthy servers with >= $MIN_BW Mbit/s / all servers):"
    country_rows "$MIN_BW" | awk -F'\t' '{ printf "  %s  %-22s %2d / %2d\n", $1, $2, $3, $4 }' | column -c "${COLUMNS:-100}" 2>/dev/null \
        || country_rows "$MIN_BW" | awk -F'\t' '{ printf "  %s  %-22s %2d / %2d\n", $1, $2, $3, $4 }'
    # Enter keeps the saved list, so "all" is the way back to every country.
    local known cc saved=$COUNTRIES
    known=$(country_rows 0 | cut -f1)
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
        echo "Unknown country code: $cc"
        COUNTRIES=$saved
    done

    echo
    echo "Sort by:"
    echo "  1) lowest load"
    echo "  2) most free bandwidth"
    echo "  3) fewest users"
    echo "  4) lowest ping from this machine"
    echo "  5) balanced: ping + load (1% load counts like 1 ms of ping)"
    case "$SORT" in free) sort_choice=2 ;; users) sort_choice=3 ;; ping) sort_choice=4 ;; balanced) sort_choice=5 ;; *) sort_choice=1 ;; esac
    case "$(ask "Sort" "$sort_choice")" in
        2) SORT=free ;; 3) SORT=users ;; 4) SORT=ping ;; 5) SORT=balanced ;; *) SORT=load ;;
    esac

    rows=$(server_rows "$COUNTRIES" "$MIN_BW" load)
    [ -n "$rows" ] || die "No healthy server matches those filters. Lower the bandwidth or add countries."
    local pinged=0
    if [ "$SORT" = ping ] || [ "$SORT" = balanced ]; then
        echo "Pinging $(wc -l <<<"$rows") servers..."
        if measure_pings <<<"$rows"; then pinged=1; else SORT=load; fi
    fi
    rows=$(server_rows "$COUNTRIES" "$MIN_BW" "$SORT")
    echo
    printf '  %3s  %-14s %-3s %-26s %5s %15s %6s' "#" "Server" "CC" "Location" "Load" "Used/Max Mbit" "Users"
    [ "$pinged" = 1 ] && printf ' %6s' "Ping"
    echo
    i=0
    while IFS=$'\t' read -r name cc loc load bw bwmax users ms recovering _; do
        i=$(( i + 1 ))
        printf '  %3d) %-14s %-3s %-26.26s %4s%% %7s/%-7s %6s' "$i" "$name" "$cc" "$loc" "$load" "$bw" "$bwmax" "$users"
        if [ "$pinged" = 1 ]; then
            if [ "$ms" = - ]; then printf ' %6s' "-"; else printf ' %4sms' "$ms"; fi
        fi
        [ "$recovering" = 1 ] && printf '  recovering'
        echo
    done <<<"$rows"
    echo
    grep -q $'\t-\t[01]\t[^\t]*$' <<<"$rows" && echo "Ping \"-\" = no answer (listed last)."
    grep -q $'\t1\t[^\t]*$' <<<"$rows" \
        && echo "recovering = under 5% load: usually just back from an outage that dropped its users (listed last)."
    echo "Type a number to use that server."
    local example=${COUNTRIES%% *}
    echo "Advanced: type a country code (e.g. ${example:-us}) instead to use <cc>.vpn.airdns.org,"
    echo "where AirVPN picks a server for you at every connect. It survives an outage on"
    echo "its own but ignores your bandwidth filter. With auto-switch you don't need it."
    choice=$(ask "Server" 1)
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ] || die "Invalid choice."
        line=$(sed -n "${choice}p" <<<"$rows")
        SERVER_MODE=server; SERVER=$(cut -f1 <<<"$line")
    else
        choice=$(tr 'A-Z' 'a-z' <<<"$choice")
        country_rows 0 | cut -f1 | grep -qx "$choice" || die "Unknown country code: $choice"
        SERVER_MODE=country; SERVER=$choice
    fi
    set_server_label; ok "Server: $SERVER_LABEL"
}

set_server_label() {
    if [ "$SERVER_MODE" = server ]; then
        SERVER_LABEL="$SERVER ($(N="$SERVER" jget '[s["location"] + ", " + s["country_name"] for s in d["servers"] if s["public_name"] == __import__("os").environ["N"]][0]' <<<"$STATUS"))"
    else
        SERVER_LABEL="any server in $(N="$SERVER" jget '[c["country_name"] for c in d["countries"] if c["country_code"] == __import__("os").environ["N"]][0]' <<<"$STATUS") ($SERVER.vpn.airdns.org)"
    fi
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
    local title=$1 msg=$2 code r hdr=()
    case "$ALERT_CHANNEL" in
        none) return 0 ;;
        airvpn)
            r=$(api notification subject="$title" body="$msg")
            [ "$(result_of <<<"$r")" = ok ] && return 0
            warn "AirVPN notification failed: $(result_of <<<"$r")"; return 1 ;;
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
    echo "  2) AirVPN notification (shows on airvpn.org; email if enabled in your"
    echo "     AirVPN notification options under Air -> API)"
    echo "  3) ntfy"
    echo "  4) Discord webhook"
    echo "  5) Gotify"
    echo "  6) Telegram bot"
    case "$ALERT_CHANNEL" in airvpn) c=2 ;; ntfy) c=3 ;; discord) c=4 ;; gotify) c=5 ;; telegram) c=6 ;; *) c=1 ;; esac
    case "$(ask "Channel" "$c")" in
        2) ALERT_CHANNEL=airvpn ;;
        3) ALERT_CHANNEL=ntfy
           NTFY_URL=$(ask "ntfy topic URL (e.g. https://ntfy.sh/my-airvpn-alerts)" "$NTFY_URL")
           NTFY_TOKEN=$(ask "ntfy access token (empty if none)" "$NTFY_TOKEN") ;;
        4) ALERT_CHANNEL=discord
           DISCORD_WEBHOOK=$(ask "Discord webhook URL" "$DISCORD_WEBHOOK") ;;
        5) ALERT_CHANNEL=gotify
           GOTIFY_URL=$(ask "Gotify URL (e.g. https://gotify.example.com)" "$GOTIFY_URL")
           GOTIFY_TOKEN=$(ask "Gotify application token" "$GOTIFY_TOKEN") ;;
        6) ALERT_CHANNEL=telegram
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
    if needs_key_for_monitor && [ "$SAVE_KEY" != 1 ]; then
        warn "The selected events/channel need the API key, so it will be saved in $ENV_FILE."
        SAVE_KEY=1
    fi
    if yesno "Send a test alert now?" y; then
        send_alert "AirVPN monitor test" "Test from airvpn-wg.sh on $(hostname): alerts for $DEVICE work." \
            && ok "Test alert sent via $ALERT_CHANNEL"
    fi
}

mark() { [ "$1" = 1 ] && echo x || echo " "; }

needs_key_for_monitor() {
    [ "$ALERT_CHANNEL" = airvpn ] || [ "$EVENT_DEVICE_OFFLINE" = 1 ] || [ "$EVENT_EXPIRY" = 1 ]
}

configure_autoswitch() {
    echo
    if [ "$SERVER_MODE" != server ]; then
        echo "Auto-switch needs a specific server; $SERVER.vpn.airdns.org already moves to"
        echo "another server in that country whenever the tunnel reconnects."
        AUTO_SWITCH=0
        return 0
    fi
    echo "Auto-switch: when $SERVER goes down, the monitor rewrites wg0.conf for the next"
    echo "healthy server matching your filters (${COUNTRIES:-all countries}, >= $MIN_BW Mbit/s,"
    echo "sorted by $SORT) and restarts the container that uses it."
    if yesno "Enable auto-switch?" "$([ "$AUTO_SWITCH" = 1 ] && echo y || echo n)"; then
        AUTO_SWITCH=1
        RESTART_CONTAINER=$(ask "Container to restart after a switch (\"none\" = don't restart)" "${RESTART_CONTAINER:-none}")
        [ "$RESTART_CONTAINER" = none ] && RESTART_CONTAINER=""
        if [ -n "$RESTART_CONTAINER" ] && command -v docker >/dev/null && ! docker inspect "$RESTART_CONTAINER" >/dev/null 2>&1; then
            warn "No container named $RESTART_CONTAINER right now; a switch will still rewrite wg0.conf."
        fi
        if [ "$SAVE_KEY" != 1 ]; then
            warn "Auto-switch needs the API key, so it will be saved in $ENV_FILE."
            SAVE_KEY=1
        fi
        ok "Auto-switch on${RESTART_CONTAINER:+, restarts $RESTART_CONTAINER}"
    else
        AUTO_SWITCH=0
    fi
}

print_cron() {
    [ "$ALERT_CHANNEL" = none ] && [ "$AUTO_SWITCH" != 1 ] && return 0
    local self
    self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
    echo
    echo "For alerts and auto-switch, run the monitor every 5 minutes (1-3 API requests per run)."
    echo "TrueNAS: System -> Advanced Settings -> Cron Jobs -> Add, user root, command:"
    echo "    bash $self monitor --output $OUTPUT"
    echo "Other Linux: add that line to root's crontab (crontab -e) as"
    echo "    */5 * * * * bash $self monitor --output $OUTPUT"
}

# ── Auto-switch ─────────────────────────────────────────────────────────────
# auto_switch <status json> — regenerate wg0.conf for the best healthy server
# matching the saved filters (never the current one), save it as the new
# server and restart the container. Sets SWITCH_TO on success; SWITCH_ERR
# says why it failed, or what went wrong after the switch (restart).
SWITCH_TO=""; SWITCH_ERR=""
auto_switch() {
    local old=$SERVER next out
    STATUS=$1
    if [ "$SORT" = ping ] || [ "$SORT" = balanced ]; then
        server_rows "$COUNTRIES" "$MIN_BW" load | measure_pings
    fi
    next=$(server_rows "$COUNTRIES" "$MIN_BW" "$SORT" | awk -F'\t' -v cur="$old" '$1 != cur && !f { print $1; f = 1 }')
    if [ -z "$next" ]; then
        SWITCH_ERR="no healthy server with >= $MIN_BW Mbit/s in ${COUNTRIES:-any country}"
        return 1
    fi
    [ -n "$AIRVPN_API_KEY" ] || { SWITCH_ERR="no API key saved in $ENV_FILE"; return 1; }
    # Same device as now: its address is in the current wg0.conf, and
    # generate checks the new config against it.
    DEVICE_IP=$(sed -n 's/^Address *= *\([0-9.]*\).*/\1/p' "$OUTPUT" 2>/dev/null)
    [ -n "$DEVICE_IP" ] || { SWITCH_ERR="cannot read the device address from $OUTPUT"; return 1; }
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
    target=$(MODE="$SERVER_MODE" N="$SERVER" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
mode, n = os.environ["MODE"], os.environ["N"]
if mode == "server":
    m = [s for s in d["servers"] if s["public_name"] == n]
    label = n
else:
    m = [c for c in d["countries"] if c["country_code"] == n]
    label = m[0]["country_name"] if m else n
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
    if [ "$down" = 1 ] && [ "$AUTO_SWITCH" = 1 ] && [ "$SERVER_MODE" = server ]; then
        if auto_switch "$status"; then
            # The old server's alerts no longer apply: forget them without
            # "all clear" messages and report the switch instead.
            rm -f "$STATE_FILE"
            msg="$label is down (${why:-health error}). wg0.conf now uses $SWITCH_TO."
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
        configure_alerts; configure_autoswitch; save_settings; ok "Saved $ENV_FILE"; print_cron ;;
    setup)
        info "AirVPN WireGuard config for $OUTPUT"
        ensure_key
        pick_device
        pick_server
        generate
        if [ -n "$ARG_DEVICE" ] && [ -n "$ARG_SERVER" ]; then
            save_settings
        else
            if [ -z "$ENV_KEY" ]; then
                yesno "Save the API key in $ENV_FILE (root only)? Needed for the monitor's device/expiry events and AirVPN alerts" y \
                    && SAVE_KEY=1 || SAVE_KEY=0
            fi
            yesno "Set up alerts?" "$([ "$ALERT_CHANNEL" = none ] && echo n || echo y)" && configure_alerts
            configure_autoswitch
            save_settings
            ok "Settings saved in $ENV_FILE"
            print_cron
        fi
        echo
        info "Done. Restart the container using it (e.g. docker restart qbittorrent) to switch over."
        ;;
esac
