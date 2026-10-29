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
#      and the events you care about.
#   5. Auto-switch (optional): when the chosen server goes down, the monitor
#      rewrites wg0.conf for the best healthy server matching the same
#      filters (countries, bandwidth; same ranking) and restarts the
#      container. With alerts or auto-switch on, the monitor's cron job
#      ("airvpn-wg.sh monitor", every 5 minutes) is added automatically.
#
# Run again once set up, it opens a menu: change just the server, device,
# port or alerts, send a test alert, or check the server's status. On a
# terminal the menus are full screen (arrow keys, Enter, Esc = back); --plain
# keeps numbered prompts.
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
# (wget -O replaces an older copy; plain wget would save airvpn-wg.sh.1 and
# run the old one):
#   sudo su -c "wget -O airvpn-wg.sh https://raw.githubusercontent.com/serversathome/ServersatHome/refs/heads/main/airvpn-wg.sh && chmod +x airvpn-wg.sh && bash airvpn-wg.sh"
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
q()    { printf '%q' "$1"; }   # a path quoted for a command the user copies

usage() {
    cat <<'EOF'
Usage: airvpn-wg.sh [command] [options]

Commands:
  menu         (default once set up) change the server, device, port or
               alerts, send a test alert or check the status
  setup        (default the first time) pick a device and server, write
               wg0.conf, set up alerts and auto-switch
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
  --plain             numbered prompts instead of full-screen menus
                      (same as AIRVPN_WG_TUI=0)
  -h, --help          this help

On a terminal the menus are full screen: arrow keys, Enter, Esc = back.

The API key is read from airvpn-wg.env, or from AIRVPN_API_KEY in the
environment, or asked for. With --device and --server, setup runs without
menus (alerts are left as they are), e.g. from another script:
  AIRVPN_API_KEY=... airvpn-wg.sh --output /path/wg0.conf --device truenas --server Menkent
EOF
}

# This script's own path (SCRIPT_PATH becomes the copy next to wg0.conf once
# install_self has put it there; the cron job runs that copy).
SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")
SCRIPT_PATH=$SELF

# ── Arguments ───────────────────────────────────────────────────────────────
CMD=setup; CMD_GIVEN=0; OUTPUT="./wg0.conf"; OUTPUT_GIVEN=0; ARG_DEVICE=""; ARG_SERVER=""; ARG_PORT=""
while [ $# -gt 0 ]; do
    case "$1" in
        menu|setup|alerts|test-alert|monitor) CMD=$1; CMD_GIVEN=1 ;;
        -o|--output) OUTPUT=${2-}; OUTPUT_GIVEN=1; shift ;;
        --device)    ARG_DEVICE=${2-}; shift ;;
        --server)    ARG_SERVER=${2-}; shift ;;
        --port)      ARG_PORT=${2-}; shift ;;
        --plain)     AIRVPN_WG_TUI=0 ;;
        -h|--help)   usage; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
    shift
done
[ -n "$OUTPUT" ] || die "--output needs a path."

command -v curl >/dev/null || die "curl is required."
command -v python3 >/dev/null || die "python3 is required."

# ── Full-screen menus ───────────────────────────────────────────────────────
# On a terminal that can show them, the menus are full screen (Python's
# curses, part of python3's standard library): arrow keys, Enter, Esc = back.
# With no terminal, a terminal that is too small or can't do it, --plain or
# AIRVPN_WG_TUI=0, the same questions are plain numbered prompts. Cron
# ("monitor") never shows a menu. TUI_PY is the program; tui runs one screen.
TUI=0
TUI_TITLE="AirVPN WireGuard"
read -r -d '' TUI_PY <<'PY'
import curses, locale, os, sys, textwrap, time

locale.setlocale(locale.LC_ALL, "")
os.environ.setdefault("ESCDELAY", "25")
UTF8 = "utf" in locale.getpreferredencoding(False).lower()
G = dict(up="↑↓", dot="●", bullet="•", line="─", more="…") if UTF8 else \
    dict(up="Up/Down", dot="*", bullet="*", line="-", more="...")
ENTER = ("\n", "\r", curses.KEY_ENTER)
BACKSPACE = (curses.KEY_BACKSPACE, "\x7f", "\x08")


def num(v, missing=9e9):
    try:
        return float(v)
    except ValueError:
        return missing


class UI:
    def __init__(self, scr, title, text):
        self.scr, self.title, self.text = scr, title, text
        scr.keypad(True)
        self.cursor(0)
        rev, bold = curses.A_REVERSE, curses.A_BOLD
        self.bar = self.sel = rev
        self.bar |= bold
        self.dim, self.warn, self.good, self.accent = curses.A_DIM, bold, bold, bold
        if curses.has_colors():
            curses.start_color()
            bg = -1
            try:
                curses.use_default_colors()
            except curses.error:
                bg = curses.COLOR_BLACK
            curses.init_pair(1, curses.COLOR_WHITE, curses.COLOR_BLUE)
            curses.init_pair(2, curses.COLOR_BLACK, curses.COLOR_CYAN)
            curses.init_pair(3, curses.COLOR_YELLOW, bg)
            curses.init_pair(4, curses.COLOR_GREEN, bg)
            curses.init_pair(5, curses.COLOR_CYAN, bg)
            self.bar = curses.color_pair(1) | bold
            self.sel = curses.color_pair(2)
            self.warn = curses.color_pair(3) | bold
            self.good = curses.color_pair(4)
            self.accent = curses.color_pair(5) | bold

    @staticmethod
    def cursor(on):
        try:
            curses.curs_set(on)
        except curses.error:
            pass

    def put(self, y, x, s, attr=0):
        h, w = self.scr.getmaxyx()
        if not 0 <= y < h or x >= w - 1:
            return
        try:
            self.scr.addstr(y, x, s.replace("\t", " ")[: w - 1 - x], attr)
        except Exception:   # off-screen, or a character the terminal can't show
            pass

    # key — the next key. Arrow and page keys the terminal sends in a form its
    # terminfo entry doesn't list (e.g. ESC [ B instead of ESC O B) are
    # decoded here, so they don't read as Esc.
    SEQ = {"A": curses.KEY_UP, "B": curses.KEY_DOWN, "C": curses.KEY_RIGHT, "D": curses.KEY_LEFT,
           "H": curses.KEY_HOME, "F": curses.KEY_END, "1~": curses.KEY_HOME, "7~": curses.KEY_HOME,
           "4~": curses.KEY_END, "8~": curses.KEY_END, "3~": curses.KEY_DC,
           "5~": curses.KEY_PPAGE, "6~": curses.KEY_NPAGE}

    def key(self):
        try:
            k = self.scr.get_wch()
        except curses.error:
            return None
        if k != "\x1b":
            return k
        self.scr.nodelay(True)
        try:
            seq = ""
            try:
                c = self.scr.get_wch()
            except curses.error:
                return k
            if c not in ("[", "O"):
                return k
            while len(seq) < 6:
                try:
                    c = self.scr.get_wch()
                except curses.error:
                    break
                seq += c if isinstance(c, str) else ""
                if seq[-1:].isalpha() or seq[-1:] == "~":
                    break
            return self.SEQ.get(seq, None)
        finally:
            self.scr.nodelay(False)

    # frame <footer> — clear, title bar, footer bar. Returns (h, w).
    def frame(self, footer):
        self.scr.erase()
        h, w = self.scr.getmaxyx()
        self.put(0, 0, (" " + self.title).ljust(w), self.bar)
        self.put(h - 1, 0, (" " + footer).ljust(w), self.bar)
        return h, w

    # text <y> <max rows> — the screen's explanation, wrapped. Lines starting
    # with ⚠/! are warnings. Returns the rows used (plus a blank one).
    def text_block(self, y, maxrows):
        w = self.scr.getmaxyx()[1]
        lines = []
        for para in self.text.split("\n"):
            lines += textwrap.wrap(para, max(10, w - 5), break_on_hyphens=False) or [""]
        while lines and not lines[-1]:
            lines.pop()
        if not lines or maxrows <= 0:
            return 0
        if len(lines) > maxrows:
            lines = lines[: maxrows - 1] + [G["more"]]
        warn = False
        for i, l in enumerate(lines):
            if l[:1] in ("⚠", "!"):
                warn = True
            elif not l:
                warn = False
            self.put(y + i, 2, l, self.warn if warn else 0)
        return len(lines) + 1

    @staticmethod
    def scroll(top, cur, rows, n):
        if cur < top:
            top = cur
        elif cur >= top + rows:
            top = cur - rows + 1
        return max(0, min(top, n - rows))

    # nav <key> <cur> <n> <page> [selectable] — the new cursor for a movement
    # key, or None for any other key.
    @staticmethod
    def nav(k, cur, n, page, ok=lambda i: True):
        step = {curses.KEY_UP: -1, curses.KEY_DOWN: 1, curses.KEY_PPAGE: -page,
                curses.KEY_NPAGE: page, curses.KEY_HOME: -n, curses.KEY_END: n}.get(k)
        if step is None or n == 0:
            return None
        i = max(0, min(n - 1, cur + step))
        d = 1 if step > 0 else -1
        while not ok(i) and 0 <= i + d < n:
            i += d
        while not ok(i) and 0 <= i - d < n:
            i -= d
        return i if ok(i) else cur

    # menu — items "key<TAB>label[<TAB>hotkey]"; key "-" is a heading line.
    # Returns the key picked, None for Esc.
    def menu(self, default, items):
        ok = lambda i: items[i][0] != "-"
        idx = [i for i in range(len(items)) if ok(i)]
        if not idx:
            return None
        cur = next((i for i in idx if items[i][0] == default), idx[0])
        hot = {it[2].lower(): it[0] for it in items if len(it) > 2 and it[2]}
        top = 0
        while True:
            h, w = self.frame("%s move   Enter select   Esc back" % G["up"])
            y = 2 + self.text_block(2, h - 4 - min(len(items), 5))
            rows = max(1, h - 2 - y)
            top = self.scroll(top, cur, rows, len(items))
            for r in range(min(rows, len(items) - top)):
                i = top + r
                label = items[i][1] if len(items[i]) > 1 else items[i][0]
                if not ok(i):
                    self.put(y + r, 2, label, self.accent)
                else:
                    self.put(y + r, 2, (" " + label).ljust(w - 5), self.sel if i == cur else 0)
            if len(items) > rows:
                self.put(h - 2, 2, "%d of %d" % (idx.index(cur) + 1, len(idx)), self.dim)
            k = self.key()
            if k in ENTER:
                return items[cur][0]
            if isinstance(k, str) and k.lower() in hot:
                return hot[k.lower()]
            if k in ("\x1b", "q", curses.KEY_LEFT) + BACKSPACE:
                return None
            n = self.nav(k, cur, len(items), rows, ok)
            if n is not None:
                cur = n

    # input — one line of text, prefilled with the default. Returns it, None for Esc.
    def input(self, default, secret):
        buf, pos, off = list(default), len(default), 0
        while True:
            h, w = self.frame("Enter OK   Esc back   Ctrl-U clear")
            y = 2 + self.text_block(2, h - 6)
            fw = max(10, w - 8)
            if pos < off:
                off = pos
            elif pos > off + fw - 1:
                off = pos - fw + 1
            shown = "".join(G["bullet"] * len(buf) if secret else buf)
            self.put(y, 2, "> ", self.accent)
            self.put(y, 4, shown[off:off + fw].ljust(fw), self.sel)
            self.cursor(1)
            try:
                self.scr.move(y, 4 + pos - off)
            except curses.error:
                pass
            k = self.key()
            self.cursor(0)
            if k in ENTER:
                return "".join(buf)
            if k == "\x1b":
                return None
            if k in BACKSPACE:
                if pos:
                    del buf[pos - 1]
                    pos -= 1
            elif k == curses.KEY_DC:
                if pos < len(buf):
                    del buf[pos]
            elif k == curses.KEY_LEFT:
                pos = max(0, pos - 1)
            elif k == curses.KEY_RIGHT:
                pos = min(len(buf), pos + 1)
            elif k in (curses.KEY_HOME, "\x01"):
                pos = 0
            elif k in (curses.KEY_END, "\x05"):
                pos = len(buf)
            elif k == "\x15":
                buf, pos = [], 0
            elif isinstance(k, str) and k.isprintable():
                buf.insert(pos, k)
                pos += 1

    # checklist — items "key<TAB>label<TAB>1|0". Returns the ticked keys,
    # space separated ("" = none), None for Esc. Typing jumps to an item.
    def checklist(self, items):
        on = [len(it) > 2 and it[2] == "1" for it in items]
        cur = top = 0
        typed, last = "", 0.0
        n = len(items)
        while True:
            h, w = self.frame("%s move   Space tick   + all   - none   Enter done   Esc back" % G["up"])
            y = 2 + self.text_block(2, h - 5 - min(n, 5))
            rows = max(1, h - 3 - y)
            top = self.scroll(top, cur, rows, n)
            for r in range(min(rows, n - top)):
                i = top + r
                label = items[i][1] if len(items[i]) > 1 else items[i][0]
                attr = self.sel if i == cur else (self.good if on[i] else 0)
                self.put(y + r, 2, (" [%s] %s" % ("x" if on[i] else " ", label)).ljust(w - 5), attr)
            status = "%d ticked" % sum(on)
            if n > rows:
                status += "   %d of %d" % (cur + 1, n)
            if typed and time.time() - last < 1.5:
                status += "   jump: " + typed
            self.put(h - 2, 2, status, self.dim)
            k = self.key()
            if k in ENTER:
                return " ".join(it[0] for it, o in zip(items, on) if o)
            if k in ("\x1b", curses.KEY_LEFT):
                return None
            if k == " " and n:
                on[cur] = not on[cur]
            elif k == "+":
                on = [True] * n
            elif k == "-":
                on = [False] * n
            elif isinstance(k, str) and k.isalnum():
                now = time.time()
                typed = typed + k.lower() if now - last < 1.5 else k.lower()
                last = now
                for i in list(range(cur, n)) + list(range(cur)):
                    words = [items[i][0].lower()] + (items[i][1].lower().split() if len(items[i]) > 1 else [])
                    if any(wd.startswith(typed) for wd in words):
                        cur = i
                        break
            else:
                m = self.nav(k, cur, n, rows)
                if m is not None:
                    cur = m

    # servers — server_rows TSV (see airvpn-wg.sh). Returns the picked row's
    # number in the ranked order, "c" to change the filters, None for Esc.
    def servers(self, current, items, pinged):
        rows = [r + ["-"] * (14 - len(r)) for r in items]
        if not rows:
            return None
        hist_ok = lambda r: r[7] in ("ok", "new")
        sorts = [("rank", lambda i: i),
                 ("load", lambda i: (num(rows[i][4]), i)),
                 ("ping", lambda i: (num(rows[i][6]), i)),
                 ("outages", lambda i: (num(rows[i][11]) if hist_ok(rows[i]) else 9e9, i)),
                 ("name", lambda i: rows[i][0].lower())]
        sort, order, cur, top = 0, list(range(len(rows))), 0, 0
        while True:
            h, w = self.frame("%s move   Enter use this server   s sort: %s   c change filters   Esc back"
                              % (G["up"], sorts[sort][0]))
            y = 2 + self.text_block(2, min(4, max(0, h - 14)))
            cols = 3 + 1 + 3 + 2 + 14 + 1 + 3 + 1 + 6 + 1 + 6 + (7 if pinged else 0) + 2
            outw = 26
            locw = max(6, min(24, w - 2 - cols - outw))
            self.put(y, 1, " %3s  %-14s %-3s %-*s %6s %6s%s  %s" % (
                "#", "Server", "CC", locw, "Location", "Load", "Users",
                " %6s" % "Ping" if pinged else "", "Outages"), curses.A_BOLD)
            y += 1
            detail_y = h - 6
            avail = max(1, detail_y - y - 1)
            top = self.scroll(top, cur, avail, len(order))
            for r in range(min(avail, len(order) - top)):
                i = order[top + r]
                n, cc, loc, load, rload, users, ms, hist, lng, sht, days, rate, deep, ip = rows[i][:14]
                shown_load = "~%s%%" % rload if rload != load else "%s%%" % load
                if hist in ("ok", "new"):
                    out = "%s long, %s short in %sd" % (lng, sht, days)
                    oattr = self.good if lng == "0" and sht == "0" else 0
                    if hist == "new" and num(days) < 10:
                        out += " (new)"
                else:
                    out = "unknown" if hist == "unknown" else "not checked"
                    oattr = self.warn
                mark = G["dot"] if n == current else " "
                line = "%s%3d  %-14s %-3s %-*.*s %6s %6s%s  " % (
                    mark, i + 1, n, cc, locw, locw, loc, shown_load, users,
                    " %6s" % ("-" if ms == "-" else ms + "ms") if pinged else "")
                selected = top + r == cur
                self.put(y + r, 1, (line + out).ljust(w - 3) if selected else line,
                         self.sel if selected else 0)
                if not selected:
                    self.put(y + r, 1 + len(line), out, oattr)
            if len(order) > avail:
                self.put(detail_y - 1, 2, "%d of %d" % (cur + 1, len(order)), self.dim)
            self.put(detail_y, 1, G["line"] * (w - 2), self.dim)
            self.detail(detail_y + 1, rows[order[cur]], current, pinged)
            k = self.key()
            if k in ENTER:
                return str(order[cur] + 1)
            if k in ("c", "C"):
                return "c"
            if k in ("s", "S"):
                picked = order[cur]
                sort = (sort + 1) % len(sorts)
                order = sorted(range(len(rows)), key=sorts[sort][1])
                cur = order.index(picked)
            elif k in ("\x1b", "q", curses.KEY_LEFT) + BACKSPACE:
                return None
            else:
                m = self.nav(k, cur, len(order), avail)
                if m is not None:
                    cur = m

    def detail(self, y, r, current, pinged):
        n, cc, loc, load, rload, users, ms, hist, lng, sht, days, rate, deep, ip = r[:14]
        head = "%s  %s (%s)   entry %s" % (n, loc, cc.upper(), ip)
        if n == current:
            head += "   %s in use now" % G["dot"]
        self.put(y, 2, head, self.accent)
        l2 = "Load %s%%" % load
        if rload != load:
            l2 += " now, ~%s%% once its users are back (it had an outage in the last few hours)" % rload
        l2 += ", %s users" % users
        if pinged:
            l2 += ", no ping answer" if ms == "-" else ", ping %s ms" % ms
        self.put(y + 1, 2, l2)
        if hist in ("ok", "new"):
            l3 = "Outages: %s long (30+ min), %s short in %s days = %s weighted per 30 days" % (lng, sht, days, rate)
            if deep != "1":
                l3 += "; only 10 days read, so its rank is less certain"
            self.put(y + 2, 2, l3)
        elif hist == "unknown":
            self.put(y + 2, 2, "Outage history could not be read, so it is ranked as unreliable.", self.warn)
        else:
            self.put(y + 2, 2, "Outage history not checked (outside the servers read), so it is ranked as unreliable.", self.warn)


def main():
    a = sys.argv[1:] + [""] * 5
    widget, title, text, default, out = a[:5]
    flags = sys.argv[6:]
    if widget == "probe":
        try:
            curses.setupterm()
            cols, lines = os.get_terminal_size(1)
        except Exception:
            return 3
        return 0 if cols >= 60 and lines >= 16 else 3
    items = [l.split("\t") for l in os.environ.get("TUI_ITEMS", "").split("\n") if l.strip()]

    def run(scr):
        ui = UI(scr, title, text)
        if widget == "menu":
            return ui.menu(default, items)
        if widget == "input":
            return ui.input(default, "secret" in flags)
        if widget == "checklist":
            return ui.checklist(items)
        if widget == "servers":
            return ui.servers(default, items, "pinged" in flags)
        raise ValueError("unknown widget " + widget)
    try:
        res = curses.wrapper(run)
    except KeyboardInterrupt:
        return 130
    except Exception:
        import traceback
        traceback.print_exc()
        return 3
    if res is None:
        return 1
    with open(out, "w") as f:
        f.write(res)
    return 0


sys.exit(main())
PY

# tui_init — use the full-screen menus if this terminal can show them
# (60x16 at least).
tui_init() {
    [ "${AIRVPN_WG_TUI:-1}" != 0 ] || return 0
    { : </dev/tty; } 2>/dev/null || return 0
    [ "${TERM:-dumb}" != dumb ] || return 0
    python3 -c "$TUI_PY" probe </dev/tty >/dev/tty 2>/dev/null && TUI=1
}

# tui <screen> <text> <default> [items] [flags...] — one full-screen step on
# the terminal, titled $TUI_TITLE; prints the answer. Returns 1 for Esc (back).
# Screens: menu (items "key<TAB>label[<TAB>hotkey]", key "-" = a heading),
# input (flag "secret" hides it), checklist (items "key<TAB>label<TAB>1|0";
# prints the ticked keys) and servers (items = server_rows; flag "pinged").
tui() {
    local out rc
    out=$(mktemp) || die "mktemp failed."
    TUI_ITEMS=${4-} python3 -c "$TUI_PY" "$1" "$TUI_TITLE" "$2" "$3" "$out" "${@:5}" </dev/tty >/dev/tty 2>/dev/tty
    rc=$?
    cat "$out"; rm -f "$out"
    case $rc in
        0|1) return $rc ;;
        130) kill -s TERM $$; exit 1 ;;     # Ctrl-C
        *) echo "❌ The full-screen menu failed. Run again with --plain for numbered prompts." >&2
           kill -s TERM $$; exit 1 ;;
    esac
}

# tui_msg <text> — show a message until Enter or Esc.
tui_msg() { tui menu "$1" ok $'ok\tOK' >/dev/null; return 0; }

case "$CMD" in menu|setup|alerts) tui_init ;; esac

# wg_in_use [exclude] — "container<TAB>path<TAB>note<TAB>running (1/0)" for
# every container that
# uses a WireGuard client config: a known in-container path (hotio
# /config/wireguard/wg0.conf, gluetun /gluetun/wireguard/wg0.conf, linuxserver
# /config/wg_confs/wg0.conf, /etc/wireguard/wg0.conf) mapped back through its
# mounts, never guessed. Server configs (no Endpoint, e.g. wg-easy) are left
# out. Stopped containers count too (a bad wg0.conf is a common reason), and a
# hotio container with VPN_ENABLED=true is listed even before its wg0.conf
# exists. [exclude] leaves out that wg0.conf.
wg_in_use() {
    local ids
    command -v docker >/dev/null || return 0
    ids=$(docker ps -aq 2>/dev/null)
    [ -n "$ids" ] || return 0
    # shellcheck disable=SC2086
    docker inspect $ids 2>/dev/null | EXCLUDE="${1-}" python3 -c '
import json, os, re, sys
KNOWN = ["/config/wireguard/wg0.conf", "/gluetun/wireguard/wg0.conf",
         "/config/wg_confs/wg0.conf", "/etc/wireguard/wg0.conf"]
skip = os.path.realpath(os.environ["EXCLUDE"]) if os.environ["EXCLUDE"] else None
def client(f):
    try:
        with open(f, errors="replace") as fh:
            return re.search(r"^\s*Endpoint\s*=", fh.read(), re.M | re.I) is not None
    except OSError:
        return False
seen = set()
try:
    containers = json.load(sys.stdin)
except Exception:
    containers = []
for c in containers:
    name = c.get("Name", "").lstrip("/")
    running = (c.get("State") or {}).get("Running")
    env = (c.get("Config") or {}).get("Env") or []
    vpn = any(e.lower() == "vpn_enabled=true" for e in env)
    for m in c.get("Mounts", []):
        src, dst = m.get("Source") or "", (m.get("Destination") or "").rstrip("/")
        if not src or not dst:
            continue
        for k in KNOWN:
            if k != dst and not k.startswith(dst + "/"):
                continue
            f = os.path.realpath(src + k[len(dst):])
            if f == skip or (name, f) in seen:
                continue
            if os.path.isfile(f):
                if not client(f):
                    continue
                note = "used by " + name + ("" if running else ", stopped")
            elif vpn and k == KNOWN[0] and os.path.isdir(src):
                note = name + " expects it; not created yet"
            else:
                continue
            seen.add((name, f))
            print("\t".join((name, f, note, "1" if running else "0")))'
}

# Without --output the default is ./wg0.conf in the current folder, which is
# easy to get wrong (e.g. running from a home folder). If a running container
# already uses a wg0.conf, offer that file instead.
if [ "$OUTPUT_GIVEN" = 0 ] && { [ "$CMD" = setup ] || [ "$CMD" = alerts ] || [ "$CMD" = menu ]; } && [ -z "${AIRVPN_WG_EMBEDDED:-}" ]; then
    in_use=$(wg_in_use "$OUTPUT")
    if [ -n "$in_use" ] && [ "$TUI" = 1 ]; then
        default_out="$(cd "$(dirname "$OUTPUT")" 2>/dev/null && pwd)/wg0.conf"
        pick=$(tui menu "No --output given. Which WireGuard config should this work on? These are the ones your containers use." \
            "$(head -n 1 <<<"$in_use" | cut -f2)" \
            "$(awk -F'\t' '{ printf "%s\t%s (%s)\n", $2, $2, $3 }' <<<"$in_use")"$'\n'"@default"$'\t'"The default: $default_out") \
            || { info "Cancelled; nothing was changed."; exit 0; }
        [ "$pick" != @default ] && OUTPUT=$pick
        unset in_use pick default_out
    elif [ -n "$in_use" ]; then
        echo "No --output given, so the default is $(cd "$(dirname "$OUTPUT")" 2>/dev/null && pwd)/wg0.conf."
        echo "WireGuard configs used by your containers:"
        i=0
        while IFS=$'\t' read -r c f n _; do i=$(( i + 1 )); printf '  %d) %s (%s)\n' "$i" "$f" "$n"; done <<<"$in_use"
        echo "  0) Keep the default ($(cd "$(dirname "$OUTPUT")" 2>/dev/null && pwd)/wg0.conf)"
        while :; do
            { : </dev/tty; } 2>/dev/null || break
            read -rp "Which wg0.conf? [1]: " pick </dev/tty || break
            pick=${pick:-1}
            [ "$pick" = 0 ] && break
            if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -le "$i" ]; then
                OUTPUT=$(sed -n "${pick}p" <<<"$in_use" | cut -f2); break
            fi
            echo "Type a number from the list."
        done
        unset in_use i c f n pick
    fi
fi

OUT_DIR=$(cd "$(dirname "$OUTPUT")" 2>/dev/null && pwd) || die "Directory for $OUTPUT does not exist."
OUTPUT="$OUT_DIR/$(basename "$OUTPUT")"
ENV_FILE="$OUT_DIR/airvpn-wg.env"
STATE_FILE="$OUT_DIR/airvpn-wg.state"
SWITCH_FAILED_FILE="$OUT_DIR/airvpn-wg.switch-failed"   # last failed auto-switch

CALLS_FILE=$(mktemp)
echo 0 > "$CALLS_FILE"
PING_FILE=$(mktemp)
REL_FILE=$(mktemp)
HIST_DIR=$(mktemp -d)
HIST_NOW=$(date +%s)
trap 'rm -rf "$CALLS_FILE" "$PING_FILE" "$REL_FILE" "$HIST_DIR"' EXIT
trap 'exit 1' TERM    # no_tty stops the whole script from inside $(...)

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

# Once set up (a device and server saved), running without a command opens
# the menu, so one thing can be changed without going through everything.
if [ "$CMD_GIVEN" = 0 ] && [ -n "$DEVICE" ] && [ -n "$SERVER" ] && [ -z "$ARG_DEVICE$ARG_SERVER$ARG_PORT" ] \
    && [ -z "${AIRVPN_WG_EMBEDDED:-}" ] && { : </dev/tty; } 2>/dev/null; then
    CMD=menu
fi

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

# A failed request has no "result", only "error" (e.g. {"error": "Not authorized"}).
result_of() { jget 'd.get("result") or d.get("error")'; }

# ── Prompts ─────────────────────────────────────────────────────────────────
# ask <prompt> <default> — prints the answer (the default on Enter). With no
# terminal to read from (or end of input) it stops instead of taking defaults
# forever, which could loop between menus.
# Prompts run inside $(...), where die would only end the subshell, so this
# signals the main script ($$ is its PID even in a subshell).
# tty_read <read args...> — read from the terminal, or stop if there is none.
# The terminal is checked first, quietly: read prints its prompt on stderr, so
# stderr must not be silenced around the read itself.
tty_read() {
    { : </dev/tty; } 2>/dev/null || no_tty
    read "$@" </dev/tty || no_tty
}
no_tty() {
    echo "❌ No terminal to ask on. Run airvpn-wg.sh interactively, or give --device and --server." >&2
    kill -s TERM $$
    exit 1
}
ask() {
    local a
    if [ "$TUI" = 1 ]; then
        a=$(tui input "$1" "$2") || a=$2    # Esc keeps the default
        printf '%s' "$a"; return 0
    fi
    tty_read -rp "$1${2:+ [$2]}: " a
    printf '%s' "${a:-$2}"
}
# ask_or_back <prompt> <default> — like ask, but returns 1 (go back) for "b",
# or for a blank answer when there is no default to keep. Prints the answer.
ask_or_back() {
    local a hint
    if [ "$TUI" = 1 ]; then
        a=$(tui input "$1" "$2") || return 1
    else
        if [ -n "$2" ]; then hint=" (b = back)"; else hint=" (Enter = back)"; fi
        tty_read -rp "$1$hint${2:+ [$2]}: " a
        case "$a" in b|B|back) return 1 ;; esac
    fi
    a=${a:-$2}
    [ -n "$a" ] || return 1
    printf '%s' "$a"
}
yesno() {  # yesno <prompt> <y|n>
    local a
    if [ "$TUI" = 1 ]; then
        a=$(tui menu "$1" "$2" $'y\tYes\ty\nn\tNo\tn') || a=n    # Esc = no
        [ "$a" = y ]; return
    fi
    a=$(ask "$1 (y/n)" "$2")
    [[ "$a" =~ ^[Yy] ]]
}

# ── Step 0: API key ─────────────────────────────────────────────────────────
USERINFO=""
ensure_key() {
    if [ -z "$AIRVPN_API_KEY" ]; then
        if [ "$TUI" = 1 ]; then
            AIRVPN_API_KEY=$(TUI_TITLE="AirVPN API key" tui input "Paste your AirVPN API key. Create one at https://airvpn.org/apisettings/ (and activate it); it needs a premium account." "" secret) || AIRVPN_API_KEY=""
        else
            echo "Create an API key at https://airvpn.org/apisettings/ (and activate it)."
            tty_read -rsp "AirVPN API key: " AIRVPN_API_KEY; echo
        fi
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
    while :; do
        name=$(ask_or_back "Name for the new device (letters, digits, - and _)" "") || return 1
        if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then echo "Letters, digits, - and _ only."; continue; fi
        # The generator picks devices by name, so names must stay unique.
        if cut -f1 <<<"$1" | grep -qxF "$name"; then echo "A device named $name already exists."; continue; fi
        break
    done
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
    local list rows i choice line busy online name status ip last when
    list=$(api devices action=list)
    [ "$(result_of <<<"$list")" = ok ] || die "Could not list devices: $(result_of <<<"$list")"
    rows=$(device_rows <<<"$list")
    # Devices online right now ("name<TAB>server"). One device = one WireGuard
    # key = one connection: a device already used by another machine makes
    # the two keep knocking each other off.
    online=$(jget '"\n".join("%s\t%s" % (s["device_name"], s["server_name"]) for s in d.get("sessions", []))' <<<"$USERINFO")

    if [ -n "$ARG_DEVICE" ]; then
        line=$(awk -F'\t' -v n="$ARG_DEVICE" '$1==n' <<<"$rows")
        [ -n "$line" ] || die "No device named \"$ARG_DEVICE\" on this account."
        [ "$(cut -f3 <<<"$line")" = ready ] || die "Device $ARG_DEVICE is not ready yet (status $(cut -f3 <<<"$line")). Try again in a minute."
        busy=$(awk -F'\t' -v n="$ARG_DEVICE" '$1==n{print $2}' <<<"$online" | paste -sd, - | sed 's/,/, /g')
        [ -n "$busy" ] && warn "Device $ARG_DEVICE is connected right now (to $busy). If that is another machine, give this one its own device."
    elif [ "$TUI" = 1 ]; then
        tui_pick_device; return
    else
        while :; do
            echo
            echo "Devices on your AirVPN account:"
            i=0
            while IFS=$'\t' read -r name _ status ip last; do
                [ -n "$name" ] || continue
                i=$(( i + 1 ))
                busy=$(awk -F'\t' -v n="$name" '$1==n{print $2}' <<<"$online" | paste -sd, - | sed 's/,/, /g')
                if [ -n "$busy" ]; then when="connected now to $busy"; else when="last connected $last"; fi
                printf '  %2d) %-20s %-8s %-16s %s\n' "$i" "$name" "$status" "$ip" "$when"
            done <<<"$rows"
            echo "   n) Create a new device"
            local def=1
            [ -n "$DEVICE" ] && def=$(awk -F'\t' -v n="$DEVICE" '$1==n{print NR}' <<<"$rows")
            [ "$i" -eq 0 ] && def=n    # no devices yet: create one
            while :; do
                choice=$(ask "Device" "${def:-1}")
                if [[ "$choice" =~ ^[Nn]$ ]]; then
                    create_device "$rows" && return 0
                    continue 2    # went back: show the list again
                fi
                [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ] && break
                echo "Type a number from the list, or n."
            done
            line=$(sed -n "${choice}p" <<<"$rows")
            name=$(cut -f1 <<<"$line")
            if [ "$(cut -f3 <<<"$line")" != ready ]; then
                echo "Device $name is not ready yet (status $(cut -f3 <<<"$line")); pick another, or wait a minute and pick it again."
                continue
            fi
            busy=$(awk -F'\t' -v n="$name" '$1==n{print $2}' <<<"$online" | paste -sd, - | sed 's/,/, /g')
            [ -z "$busy" ] && break
            warn "Device $name is connected right now (to $busy). If another machine uses it, the two will keep knocking each other off."
            yesno "Use it anyway? (only if this is the same machine; n = pick another device)" n && break
        done
    fi

    DEVICE=$(cut -f1 <<<"$line"); DEVICE_IP=$(cut -f4 <<<"$line")
    ok "Device $DEVICE ($DEVICE_IP)"
}

# tui_pick_device — pick_device's menu, full screen (uses its rows and
# online). Returns 1 for Esc.
tui_pick_device() {
    local TUI_TITLE="Device" items name status ip last busy when def choice line
    while :; do
        items=""
        while IFS=$'\t' read -r name _ status ip last; do
            [ -n "$name" ] || continue
            busy=$(awk -F'\t' -v n="$name" '$1==n{print $2}' <<<"$online" | paste -sd, - | sed 's/,/, /g')
            if [ -n "$busy" ]; then when="connected now to $busy"; else when="last connected $last"; fi
            items+=$(printf '%s\t%-20s %-8s %-16s %s' "$name" "$name" "$status" "$ip" "$when")$'\n'
        done <<<"$rows"
        items+=$'@new\t+ Create a new device\tn'
        def=${DEVICE:-}
        [ -z "$def" ] && def=$(head -n 1 <<<"$rows" | cut -f1)
        [ -z "$def" ] && def=@new
        choice=$(tui menu "Pick the AirVPN device (WireGuard key) this machine connects as. One device = one connection: two machines sharing a device keep knocking each other off." "$def" "$items") || return 1
        if [ "$choice" = @new ]; then
            create_device "$rows" && return 0
            continue    # went back: show the list again
        fi
        line=$(awk -F'\t' -v n="$choice" '$1==n' <<<"$rows")
        if [ "$(cut -f3 <<<"$line")" != ready ]; then
            tui_msg "Device $choice is not ready yet (status $(cut -f3 <<<"$line")). Pick another, or wait a minute and pick it again."
            continue
        fi
        busy=$(awk -F'\t' -v n="$choice" '$1==n{print $2}' <<<"$online" | paste -sd, - | sed 's/,/, /g')
        [ -z "$busy" ] && break
        yesno "⚠ Device $choice is connected right now (to $busy). If another machine uses it, the two will keep knocking each other off.

Use it anyway? (only if this is the same machine)" n && break
    done
    DEVICE=$choice; DEVICE_IP=$(cut -f4 <<<"$line")
    ok "Device $DEVICE ($DEVICE_IP)"
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
    local exclude=${1-} rows n chunks=$(( (RELIABILITY_DAYS + 9) / 10 ))
    PINGED=0
    rows=$(server_rows "$COUNTRIES" "$MIN_BW" "$exclude")
    [ -n "$rows" ] || { RANKED=""; return 1; }
    echo "Pinging $(wc -l <<<"$rows") servers..."
    measure_pings <<<"$rows" && PINGED=1
    rows=$(server_rows "$COUNTRIES" "$MIN_BW" "$exclude")
    n=$(wc -l <<<"$rows"); [ "$n" -gt "$MAX_HISTORY_CHECKS" ] && n=$MAX_HISTORY_CHECKS
    echo "Reading 10 days of outage history for $n servers ($n API requests)..."
    fetch_history "$MAX_HISTORY_CHECKS" 1 <<<"$rows"
    for _ in $(seq 1 "$DEEP_ROUNDS"); do
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
    if [ "$TUI" = 1 ]; then
        tui_pick_server || return 1
        set_server_label; ok "Server: $SERVER_LABEL"; return 0
    fi

    # Bandwidth, countries and the ranked list loop: "c" at the server prompt
    # (or filters that match nothing) goes back to bandwidth and countries.
    # History already read this run is reused, so a second pass costs less.
    while :; do
        echo
        # Sizes come from the live server list, so new or retired sizes show up
        # as they are; with nothing saved the default is the largest size.
        local sizes
        sizes=$(jget '", ".join("%d (%d servers)" % (b, n) for b, n in sorted(__import__("collections").Counter(s["bw_max"] for s in d["servers"] if s.get("health") == "ok").items()))' <<<"$STATUS")
        echo "AirVPN server sizes right now, in Mbit/s: ${sizes:-unknown}"
        [ -n "$MIN_BW" ] || MIN_BW=$(largest_size)
        while :; do
            MIN_BW=$(ask "Minimum server bandwidth in Mbit/s (0 = any)" "$MIN_BW")
            [[ "$MIN_BW" =~ ^[0-9]+$ ]] && break
            echo "A number, please (0 = any size)."
            MIN_BW=$(largest_size)
        done

        echo
        # Only countries with at least one healthy server that meets the bandwidth
        # filter: there is no point picking one without.
        local usable
        usable=$(country_rows "$MIN_BW" | awk -F'\t' '$3 > 0')
        if [ -z "$usable" ]; then
            echo "No healthy AirVPN server has >= $MIN_BW Mbit/s right now; try a lower minimum."
            MIN_BW=0; continue
        fi
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
        if ! rank_servers; then
            echo "No healthy server matches those filters; lower the bandwidth or add countries."
            continue
        fi
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
            choice=$(ask "Server number (1-$i, c = change bandwidth or countries)" 1)
            [[ "$choice" =~ ^[Cc]$ ]] && break
            [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ] && break
            echo "Type a number from the list, or c."
        done
        [[ "$choice" =~ ^[Cc]$ ]] && continue
        line=$(sed -n "${choice}p" <<<"$rows")
        SERVER=$(cut -f1 <<<"$line")
        break
    done
    set_server_label; ok "Server: $SERVER_LABEL"
}

# tui_pick_server — pick_server's bandwidth, countries and ranked list, full
# screen. Esc goes back a step; returns 1 for Esc at the bandwidth.
tui_pick_server() {
    local TUI_TITLE="Server" items choice usable cc name n all on text shallow unknown
    while :; do
        [ -n "$MIN_BW" ] || MIN_BW=$(largest_size)
        # Sizes come from the live server list, as in the plain menu.
        items=$(MINBW="$MIN_BW" python3 -c '
import collections, json, os, sys
d = json.load(sys.stdin)
ok = [s.get("bw_max", 0) for s in d["servers"] if s.get("health") == "ok"]
sizes = collections.Counter(ok)
cur = os.environ["MINBW"]
for b in sorted(sizes, reverse=True):
    print("%d\t%6d Mbit/s or more   %3d healthy servers (%d of this size)" % (b, b, sum(1 for x in ok if x >= b), sizes[b]))
print("0\t   Any size            %3d healthy servers" % len(ok))
if cur.isdigit() and int(cur) and int(cur) not in sizes:
    print("%s\t%6s Mbit/s or more   (your saved minimum)" % (cur, cur))
print("@other\t   Another minimum...")' <<<"$STATUS")
        choice=$(tui menu "Minimum server size. AirVPN servers come in different sizes (bandwidth, in Mbit/s); bigger ones have more room for everyone's traffic. Only servers at least this big are listed next." "$MIN_BW" "$items") || return 1
        if [ "$choice" = @other ]; then
            choice=$(ask_or_back "Minimum server bandwidth in Mbit/s (0 = any size)" "$MIN_BW") || continue
            [[ "$choice" =~ ^[0-9]+$ ]] || { tui_msg "A number, please (0 = any size)."; continue; }
        fi
        MIN_BW=$choice

        while :; do
            usable=$(country_rows "$MIN_BW" | awk -F'\t' '$3 > 0')
            if [ -z "$usable" ]; then
                tui_msg "No healthy AirVPN server has >= $MIN_BW Mbit/s right now; pick a lower minimum."
                continue 2
            fi
            items=""
            while IFS=$'\t' read -r cc name n all; do
                on=0; [[ " $COUNTRIES " == *" $cc "* ]] && on=1
                items+=$(printf '%s\t%s  %-24s %3d / %-3d\t%s' "$cc" "$cc" "$name" "$n" "$all" "$on")$'\n'
            done <<<"$usable"
            # Saved countries that no longer qualify are dropped: only listed
            # ones can come back ticked.
            choice=$(tui checklist "Countries: tick the ones you'd like (Space), then Enter. Nothing ticked = every country. Numbers: healthy servers of >= $MIN_BW Mbit/s / all servers there." "" "$items") || continue 2
            COUNTRIES=$choice

            echo
            if ! rank_servers; then
                tui_msg "No healthy server matches those filters; lower the bandwidth or add countries."
                continue
            fi
            text="Ranked best first on load + reliability + ping (1 outage a month = $OUTAGE_PENALTY% load, 1 ms of ping = $PING_WEIGHT% load). Outages from AirVPN's session history: $RELIABILITY_DAYS days for the top $DEEP_CHECKS, 10 for the rest; long = down ~30 min or more, short = under ~20 min. ~ = load once its users are back after a recent outage."
            shallow=$(shallow_top <<<"$RANKED" | xargs)
            unknown=$(awk -F'\t' '$8 == "unknown"' <<<"$RANKED" | grep -c .)
            [ -n "$shallow" ] && text+=$'\n'"⚠ Only 10 days of history for $shallow (stopped by the re-check or request limit), so their rank is less certain."
            [ "$unknown" -gt 0 ] && text+=$'\n'"⚠ Could not read the outage history of $unknown server(s); they are ranked as unreliable."
            choice=$(tui servers "$text" "$SERVER" "$RANKED" "$([ "$PINGED" = 1 ] && echo pinged)") || continue
            [ "$choice" = c ] && continue 2
            SERVER=$(sed -n "${choice}p" <<<"$RANKED" | cut -f1)
            return 0
        done
    done
}

set_server_label() {
    SERVER_LABEL="$SERVER ($(N="$SERVER" jget '[s["location"] + ", " + s["country_name"] for s in d["servers"] if s["public_name"] == __import__("os").environ["N"]][0]' <<<"$STATUS"))"
}

# ── Step 3: generate wg0.conf ───────────────────────────────────────────────
WG_CHANGED=0    # set by generate when wg0.conf is new or different
generate() {
    local port=${ARG_PORT:-$WG_PORT} conf addr tmp
    [[ " $WG_PORTS " == *" $port "* ]] || die "Port must be one of: $WG_PORTS"
    WG_PORT=$port

    # The device goes by name: an unknown name or an id is silently replaced
    # by the account's default device, so the Address is checked below.
    # The generator names a WireGuard profile wireguard_<entry IP>_udp_<port>,
    # and not every port is offered on entry IP 1: for one it doesn't know it
    # answers "zero files in package". Then the other entry IPs are tried.
    local entry tried=""
    for entry in 1 3 2 4; do
        tried+=" wireguard_${entry}_udp_$port"
        conf=$(api generator protocols="wireguard_${entry}_udp_$port" servers="$SERVER" system=linux \
            device="$DEVICE" iplayer_entry=ipv4 iplayer_exit=ipv4)
        grep -q '^\[Interface\]' <<<"$conf" && break
        [[ "$(result_of <<<"$conf")" == *"zero files"* ]] || break
    done
    if ! grep -q '^\[Interface\]' <<<"$conf"; then
        [[ "$(result_of <<<"$conf")" == *"zero files"* ]] \
            && die "AirVPN's generator has no WireGuard profile for UDP $port on $SERVER (tried$tried). Pick another port."
        die "AirVPN did not return a config: $(result_of <<<"$conf")"
    fi
    [ "$entry" != 1 ] && ok "UDP $port is on $SERVER's entry IP $entry"
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
    cmp -s "$tmp" "$OUTPUT" 2>/dev/null || WG_CHANGED=1
    mv "$tmp" "$OUTPUT"
    ok "Wrote $OUTPUT (WireGuard, Linux, IPv4 only, $(sed -n 's/^Endpoint *= *//p' <<<"$conf"))"
}

# containers_using <wg0.conf> — running containers that use exactly this
# file: the same mount mapping as wg_in_use, so a container that only mounts a
# folder above it (a whole pool or configs root) doesn't count.
containers_using() {
    local target
    target=$(realpath -m "$1")
    wg_in_use | awk -F'\t' -v t="$target" '$2 == t && $4 == 1 { print $1 }'
}

# restart_users — after a new wg0.conf, restart the running containers that
# use it so they switch over. Returns 1 if there is none to restart.
restart_users() {
    local names n
    names=$(containers_using "$OUTPUT")
    [ -n "$names" ] || return 1
    for n in $names; do
        if docker restart "$n" >/dev/null 2>&1; then ok "Restarted $n so it uses the new wg0.conf"
        else warn "Could not restart $n; restart it by hand: docker restart $n"; fi
    done
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
    local c n
    [ "$TUI" = 1 ] && { tui_configure_alerts; return; }
    echo
    echo "Alerts (Enter = keep the choice in brackets):"
    echo "  1) None (no alerts)"
    echo "  2) ntfy"
    echo "  3) Discord webhook"
    echo "  4) Gotify"
    echo "  5) Telegram bot"
    case "$ALERT_CHANNEL" in ntfy) c=2 ;; discord) c=3 ;; gotify) c=4 ;; telegram) c=5 ;; *) c=1 ;; esac
    # A channel's details can go back to this menu (Enter on an empty
    # question, or b), where 1 is the way out.
    local v1 v2
    while :; do
        case "$(ask "Channel" "$c")" in
            2) v1=$(ask_or_back "ntfy topic URL (e.g. https://ntfy.sh/my-airvpn-alerts)" "$NTFY_URL") || continue
               v2=$(ask "ntfy access token (Enter if none${NTFY_TOKEN:+, \"none\" to clear the saved one})" "$NTFY_TOKEN")
               [ "$v2" = none ] && v2=""
               ALERT_CHANNEL=ntfy NTFY_URL=$v1 NTFY_TOKEN=$v2 ;;
            3) v1=$(ask_or_back "Discord webhook URL" "$DISCORD_WEBHOOK") || continue
               ALERT_CHANNEL=discord DISCORD_WEBHOOK=$v1 ;;
            4) v1=$(ask_or_back "Gotify URL (e.g. https://gotify.example.com)" "$GOTIFY_URL") || continue
               v2=$(ask_or_back "Gotify application token" "$GOTIFY_TOKEN") || continue
               ALERT_CHANNEL=gotify GOTIFY_URL=$v1 GOTIFY_TOKEN=$v2 ;;
            5) v1=$(ask_or_back "Telegram bot token" "$TELEGRAM_TOKEN") || continue
               v2=$(ask_or_back "Telegram chat ID" "$TELEGRAM_CHAT_ID") || continue
               ALERT_CHANNEL=telegram TELEGRAM_TOKEN=$v1 TELEGRAM_CHAT_ID=$v2 ;;
            1) ALERT_CHANNEL=none ;;
            *) echo "Pick 1-5."; continue ;;
        esac
        break
    done
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

# tui_configure_alerts — configure_alerts, full screen. Esc on a channel's
# details goes back to the channels, Esc on the events back to the channel
# too; returns 1 for Esc on the channels (nothing changed).
tui_configure_alerts() {
    local TUI_TITLE="Alerts" c v1 v2 sel err
    local saved_channel=$ALERT_CHANNEL
    while :; do
        c=$(tui menu "Where should alerts go? A cron job checks your server every 5 minutes and alerts you about the events you pick next." "$ALERT_CHANNEL" \
            $'none\tNone (no alerts)\nntfy\tntfy\ndiscord\tDiscord webhook\ngotify\tGotify\ntelegram\tTelegram bot') \
            || { ALERT_CHANNEL=$saved_channel; return 1; }
        case "$c" in
            ntfy) v1=$(ask_or_back "ntfy topic URL (e.g. https://ntfy.sh/my-airvpn-alerts)" "$NTFY_URL") || continue
                  v2=$(ask "ntfy access token (leave empty if none)" "$NTFY_TOKEN")
                  ALERT_CHANNEL=ntfy NTFY_URL=$v1 NTFY_TOKEN=$v2 ;;
            discord) v1=$(ask_or_back "Discord webhook URL" "$DISCORD_WEBHOOK") || continue
                  ALERT_CHANNEL=discord DISCORD_WEBHOOK=$v1 ;;
            gotify) v1=$(ask_or_back "Gotify URL (e.g. https://gotify.example.com)" "$GOTIFY_URL") || continue
                  v2=$(ask_or_back "Gotify application token" "$GOTIFY_TOKEN") || continue
                  ALERT_CHANNEL=gotify GOTIFY_URL=$v1 GOTIFY_TOKEN=$v2 ;;
            telegram) v1=$(ask_or_back "Telegram bot token" "$TELEGRAM_TOKEN") || continue
                  v2=$(ask_or_back "Telegram chat ID" "$TELEGRAM_CHAT_ID") || continue
                  ALERT_CHANNEL=telegram TELEGRAM_TOKEN=$v1 TELEGRAM_CHAT_ID=$v2 ;;
            *) ALERT_CHANNEL=none; ok "Alerts off"; return 0 ;;
        esac
        sel=$(tui checklist "Which events should send an alert via $ALERT_CHANNEL?" "" "$(printf '%s\t%s\t%s\n' \
            down "Server down (health error, or removed by AirVPN)" "$EVENT_SERVER_DOWN" \
            warning "Server warning (e.g. packet loss, maintenance announced)" "$EVENT_SERVER_WARNING" \
            load "Server load at or above a threshold (asked next; now $LOAD_THRESHOLD%)" "$EVENT_SERVER_LOAD" \
            offline "Device ${DEVICE:-?} not connected to AirVPN" "$EVENT_DEVICE_OFFLINE" \
            expiry "Subscription about to expire (asked next; now $EXPIRY_DAYS days before)" "$EVENT_EXPIRY" \
            recovery "All clear when a problem goes away" "$EVENT_RECOVERY")") || continue
        sel=" $sel "
        EVENT_SERVER_DOWN=0; EVENT_SERVER_WARNING=0; EVENT_SERVER_LOAD=0
        EVENT_DEVICE_OFFLINE=0; EVENT_EXPIRY=0; EVENT_RECOVERY=0
        [[ $sel == *" down "* ]] && EVENT_SERVER_DOWN=1
        [[ $sel == *" warning "* ]] && EVENT_SERVER_WARNING=1
        [[ $sel == *" offline "* ]] && EVENT_DEVICE_OFFLINE=1
        [[ $sel == *" recovery "* ]] && EVENT_RECOVERY=1
        if [[ $sel == *" load "* ]]; then
            EVENT_SERVER_LOAD=1
            LOAD_THRESHOLD=$(ask "Alert when the server's load is at or above this many %" "$LOAD_THRESHOLD")
            [[ "$LOAD_THRESHOLD" =~ ^[0-9]+$ ]] || LOAD_THRESHOLD=90
        fi
        if [[ $sel == *" expiry "* ]]; then
            EVENT_EXPIRY=1
            EXPIRY_DAYS=$(ask "Warn how many days before the subscription expires" "$EXPIRY_DAYS")
            [[ "$EXPIRY_DAYS" =~ ^[0-9]+$ ]] || EXPIRY_DAYS=7
        fi
        break
    done
    if yesno "Send a test alert via $ALERT_CHANNEL now?" y; then
        if err=$(send_alert "AirVPN monitor test" "Test from airvpn-wg.sh on $(hostname): alerts for $DEVICE work." 2>&1); then
            tui_msg "Test alert sent via $ALERT_CHANNEL. If it didn't arrive, check the details and change them here again."
        else
            tui_msg "⚠ $(tail -n 1 <<<"$err" | sed "s/^⚠️ *//") Check the details and change them here again."
        fi
    fi
}

# configure_monitor — the alert and auto-switch questions, then a review;
# "n" goes through them again, so a slip needs no restart.
# Returns 1 when the full-screen menus were left with Esc (nothing to save).
configure_monitor() {
    if [ "$TUI" = 1 ]; then
        while :; do
            tui_configure_alerts || return 1
            configure_autoswitch
            TUI_TITLE="Alerts and auto-switch" yesno "Review:

$(monitor_summary)

Save this? (No = go through alerts and auto-switch again)" y && return 0
        done
    fi
    while :; do
        configure_alerts
        configure_autoswitch
        echo
        monitor_summary | sed '1s/^/Review: /; 2,$s/^/        /'
        yesno "Save this? (n = go through alerts and auto-switch again)" y && return 0
    done
}

# monitor_summary — the alert and auto-switch settings, two lines.
monitor_summary() {
    local events=""
    if [ "$ALERT_CHANNEL" = none ]; then
        echo "alerts off"
    else
        [ "$EVENT_SERVER_DOWN" = 1 ] && events="$events server down,"
        [ "$EVENT_SERVER_WARNING" = 1 ] && events="$events warning,"
        [ "$EVENT_SERVER_LOAD" = 1 ] && events="$events load >= $LOAD_THRESHOLD%,"
        [ "$EVENT_DEVICE_OFFLINE" = 1 ] && events="$events device offline,"
        [ "$EVENT_EXPIRY" = 1 ] && events="$events expiry within $EXPIRY_DAYS days,"
        [ "$EVENT_RECOVERY" = 1 ] && events="$events all clear,"
        events=${events%,}
        echo "alerts via $ALERT_CHANNEL for${events:- no events}"
    fi
    if [ "$AUTO_SWITCH" = 1 ]; then
        if [ -n "$RESTART_CONTAINER" ]; then echo "auto-switch on, restarts $RESTART_CONTAINER"
        else echo "auto-switch on, no restart (a new wg0.conf waits for a manual restart)"; fi
    else
        echo "auto-switch off"
    fi
}

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
    [ "$TUI" = 1 ] && { tui_configure_autoswitch; return; }
    echo
    echo "Auto-switch: when $SERVER goes down, the monitor rewrites wg0.conf for the next"
    echo "best healthy server matching your filters (${COUNTRIES:-all countries}, >= ${MIN_BW:-the largest size} Mbit/s;"
    echo "load + reliability + ping, as in the list) and restarts the container that uses it."
    if yesno "Enable auto-switch?" "$([ "$AUTO_SWITCH" = 1 ] && echo y || echo n)"; then
        AUTO_SWITCH=1
        # The name has to exist (a typo would make every switch's restart
        # fail), so ask again until it does. From arr-complete.sh the
        # container is started right after this, so it is not checked there.
        # After a wrong name there is no default: Enter asks again, so "no
        # restart" is only ever chosen by typing none.
        local names def=${RESTART_CONTAINER:-none} detected
        # If the saved name isn't a container here, offer the one that has
        # this wg0.conf mounted instead.
        if [ -z "${AIRVPN_WG_EMBEDDED:-}" ] && [ -n "$RESTART_CONTAINER" ] && command -v docker >/dev/null \
            && ! docker inspect "$RESTART_CONTAINER" >/dev/null 2>&1; then
            detected=$(containers_using "$OUTPUT" | head -n 1)
            [ -n "$detected" ] && def=$detected
        fi
        while :; do
            RESTART_CONTAINER=$(ask "Container to restart after a switch (\"none\" = don't restart)" "$def")
            [ -n "$RESTART_CONTAINER" ] || { echo "Type a container name, or none."; continue; }
            if [ "$RESTART_CONTAINER" = none ]; then RESTART_CONTAINER=""; break; fi
            [ -n "${AIRVPN_WG_EMBEDDED:-}" ] && break
            command -v docker >/dev/null || break
            docker inspect "$RESTART_CONTAINER" >/dev/null 2>&1 && break
            names=$(docker ps -a --format '{{.Names}}' 2>/dev/null | sort | xargs)
            if [ -n "$names" ]; then
                echo "No container named $RESTART_CONTAINER. Containers here: $names"
            else
                echo "No container named $RESTART_CONTAINER: there are no containers on this machine yet."
                echo "Type none, or set up the containers first and add it later with: bash $(q "$SCRIPT_PATH") alerts --output $(q "$OUTPUT")"
            fi
            def=""
        done
        if [ -n "$RESTART_CONTAINER" ]; then ok "Auto-switch on, restarts $RESTART_CONTAINER"
        else warn "Auto-switch on, but no container is restarted: a new wg0.conf only takes effect when the container using it restarts."; fi
    else
        AUTO_SWITCH=0
    fi
}

# tui_configure_autoswitch — configure_autoswitch, full screen: the
# container to restart is picked from the ones on this machine.
tui_configure_autoswitch() {
    local TUI_TITLE="Auto-switch" names detected def items c
    if ! yesno "When $SERVER goes down, the monitor can rewrite wg0.conf for the next best healthy server matching your filters (${COUNTRIES:-all countries}, >= ${MIN_BW:-the largest size} Mbit/s; load + reliability + ping, as in the list) and restart the container that uses it.

Turn auto-switch on?" "$([ "$AUTO_SWITCH" = 1 ] && echo y || echo n)"; then
        AUTO_SWITCH=0; return 0
    fi
    AUTO_SWITCH=1
    names=""
    if [ -z "${AIRVPN_WG_EMBEDDED:-}" ] && command -v docker >/dev/null; then
        names=$(docker ps -a --format '{{.Names}}' 2>/dev/null | sort)
    fi
    # From arr-complete.sh (no containers yet) or without docker: type it.
    if [ -z "$names" ]; then
        c=$(ask "Container to restart after a switch (\"none\" = don't restart)" "${RESTART_CONTAINER:-none}")
        [ "$c" = none ] && c=""
        RESTART_CONTAINER=$c
    else
        detected=$(containers_using "$OUTPUT" | head -n 1)
        def=$RESTART_CONTAINER
        grep -qxF "$def" <<<"$names" || def=${detected:-@none}
        items=$(while read -r c; do
                    if [ "$c" = "$detected" ]; then printf '%s\t%s (uses this wg0.conf)\n' "$c" "$c"
                    else printf '%s\t%s\n' "$c" "$c"; fi
                done <<<"$names")$'\n@none\tDon\'t restart anything (a new wg0.conf waits for a manual restart)'
        c=$(tui menu "Which container should be restarted after a switch? A new wg0.conf only takes effect when the container using it restarts." "$def" "$items") || c=${RESTART_CONTAINER:-@none}
        [ "$c" = @none ] && c=""
        RESTART_CONTAINER=$c
    fi
    if [ -n "$RESTART_CONTAINER" ]; then ok "Auto-switch on, restarts $RESTART_CONTAINER"
    else warn "Auto-switch on, but no container is restarted: a new wg0.conf only takes effect when the container using it restarts."; fi
}

# install_self — keep the script next to wg0.conf (and its settings), so the
# cron job runs it from there and nothing depends on where it was downloaded.
# The downloaded copy is then removed ("moved"), unless it serves another
# wg0.conf itself (an airvpn-wg.env beside it), e.g. arr-complete's copy run
# with --output elsewhere.
install_self() {
    local dest="$OUT_DIR/airvpn-wg.sh"
    [ -f "$SELF" ] || return 0      # run from a pipe: nothing to copy
    if [ "$(realpath "$SELF")" = "$(realpath -m "$dest")" ]; then SCRIPT_PATH=$dest; return 0; fi
    if cp "$SELF" "$dest.tmp" && chmod 700 "$dest.tmp" && mv "$dest.tmp" "$dest"; then
        chown root:root "$dest" 2>/dev/null
        SCRIPT_PATH=$dest
        if [ ! -f "$(dirname "$SELF")/airvpn-wg.env" ] && rm -f "$SELF"; then
            ok "Moved airvpn-wg.sh to $OUT_DIR, next to wg0.conf"
        else
            ok "Copied airvpn-wg.sh to $OUT_DIR, next to wg0.conf"
        fi
    else
        rm -f "$dest.tmp"
        warn "Could not copy airvpn-wg.sh to $OUT_DIR; it stays at $SELF."
    fi
}

# setup_cron — the monitor only works from cron, so add, update or remove its
# job to match the settings: needed when alerts or auto-switch are on. On
# TrueNAS the job goes through the middleware (midclt), so it shows under
# System -> Advanced Settings -> Cron Jobs (described "AirVPN monitor") and
# survives updates; elsewhere it goes in root's crontab. A job is recognised
# by its command, which ends in "monitor --output <this wg0.conf>" (or by
# the description earlier versions gave it), so re-running updates it
# instead of adding another, and separate wg0.conf files keep separate jobs.
# Falls back to printing the line.
setup_cron() {
    local cmd mine tag="AirVPN monitor" oldtag want=0 ids line
    mine="monitor --output $(printf '%q' "$OUTPUT")"
    cmd="bash $(printf '%q' "$SCRIPT_PATH") $mine"
    oldtag="airvpn-wg monitor: $OUTPUT"     # earlier versions' description: still matched
    { [ "$ALERT_CHANNEL" != none ] || [ "$AUTO_SWITCH" = 1 ]; } && want=1
    echo
    if command -v midclt >/dev/null; then
        ids=$(midclt call cronjob.query 2>/dev/null | MINE="$mine" OLDTAG="$oldtag" python3 -c '
import json, os, sys
try:
    print(" ".join(str(j["id"]) for j in json.load(sys.stdin)
                   if (j.get("command") or "").endswith(" " + os.environ["MINE"])
                   or j.get("description") == os.environ["OLDTAG"]))
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
        current=$(crontab -l 2>/dev/null | grep -vF -e " $mine >/dev/null" -e "# $oldtag")
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
    # Cheap checks before the ranking, which costs up to ~100 requests.
    [ -n "$AIRVPN_API_KEY" ] || { SWITCH_ERR="no API key saved in $ENV_FILE"; return 1; }
    # Same device as now: its address is in the current wg0.conf, and
    # generate checks the new config against it.
    DEVICE_IP=$(sed -n 's/^Address *= *\([0-9.]*\).*/\1/p' "$OUTPUT" 2>/dev/null)
    [ -n "$DEVICE_IP" ] || { SWITCH_ERR="cannot read the device address from $OUTPUT"; return 1; }
    # Same ranking as the menu (pings, outage history, reliability), read fresh.
    rank_servers "$old"
    next=$(head -n 1 <<<"$RANKED" | cut -f1)
    if [ -z "$next" ]; then
        SWITCH_ERR="no healthy server with >= $MIN_BW Mbit/s in ${COUNTRIES:-any country}"
        return 1
    fi
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
    # A failed switch (e.g. no matching server) is retried every 30 minutes,
    # not on every 5-minute run: each attempt reads the history again.
    if [ "$down" = 1 ] && [ "$AUTO_SWITCH" = 1 ] && [ -n "$(find "$SWITCH_FAILED_FILE" -mmin -30 2>/dev/null)" ]; then
        echo "    auto-switch failed less than 30 minutes ago ($(cat "$SWITCH_FAILED_FILE" 2>/dev/null)); retrying later"
        conds+=("noswitch|AirVPN auto-switch failed|Could not switch away from $label: $(cat "$SWITCH_FAILED_FILE" 2>/dev/null)")
    elif [ "$down" = 1 ] && [ "$AUTO_SWITCH" = 1 ]; then
        if auto_switch "$status"; then
            rm -f "$SWITCH_FAILED_FILE"
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
        printf '%s\n' "$SWITCH_ERR" > "$SWITCH_FAILED_FILE"
        conds+=("noswitch|AirVPN auto-switch failed|Could not switch away from $label: $SWITCH_ERR")
    fi
    [ "$down" = 0 ] && rm -f "$SWITCH_FAILED_FILE"
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
            if [ "$ALERT_CHANNEL" = none ]; then echo "    $title"; else echo "    alert sent: $title"; fi
            active+=("$key|$title")
        fi
    done
    while IFS='|' read -r key title; do
        [ -n "$key" ] || continue
        printf '%s\n' "${conds[@]}" | grep -q "^$key|" && continue
        if [ "$EVENT_RECOVERY" = 1 ]; then
            send_alert "All clear: $title" "Resolved: $title" && [ "$ALERT_CHANNEL" != none ] && echo "    all clear sent: $title"
        fi
    done <<<"$prev"
    if [ ${#active[@]} -gt 0 ]; then printf '%s\n' "${active[@]}" > "$STATE_FILE"; else rm -f "$STATE_FILE"; fi
}

# ── Setup ───────────────────────────────────────────────────────────────────
# run_setup — the whole setup: device, server, wg0.conf, alerts and
# auto-switch. Returns 1 if it was left with Esc before anything was written.
run_setup() {
    info "AirVPN WireGuard config for $OUTPUT"
    ensure_key
    # Esc on the server goes back to the device (full-screen menus only).
    while :; do
        pick_device || return 1
        pick_server && break
        [ -n "$ARG_DEVICE" ] && return 1
    done
    generate
    install_self
    if [ -n "$ARG_DEVICE" ] && [ -n "$ARG_SERVER" ]; then
        save_settings
    else
        echo
        echo "Optional: a monitor (run from cron) can alert you about problems and switch"
        echo "servers automatically when this one goes down."
        configure_monitor
        save_monitor_settings
        setup_cron
        echo "To change the server, alerts or auto-switch later: bash $(q "$SCRIPT_PATH") --output $(q "$OUTPUT")"
    fi
    echo
    finish_change
}

# finish_change — after a new wg0.conf: restart the container using it.
finish_change() {
    local others
    # A new wg0.conf only takes effect when the container using it
    # restarts, so do that here. arr-complete.sh runs this before starting
    # the containers, so there is nothing to restart then.
    if [ -n "${AIRVPN_WG_EMBEDDED:-}" ]; then
        info "Done."
    elif [ "$WG_CHANGED" = 0 ]; then
        info "Done. wg0.conf is unchanged, so nothing needs a restart."
    elif restart_users; then
        info "Done."
    else
        others=$(wg_in_use "$OUTPUT" | awk -F'\t' '{ printf "%s%s uses %s", (NR > 1 ? "; " : ""), $1, $2 }')
        if [ -n "$others" ]; then
            warn "No running container uses $OUTPUT ($others). To change that one: bash $(q "$SCRIPT_PATH") --output <its wg0.conf>"
            info "Done."
        else
            info "Done. No running container uses $OUT_DIR; restart whatever uses wg0.conf to switch over."
        fi
    fi
}

# ── Menu ────────────────────────────────────────────────────────────────────
# The menu once set up: change one thing (server, device, port, alerts)
# without going through the rest, send a test alert or check the status.

# load_device — the saved device's address (generate checks the new config
# against it), or pick another device if it is gone. Returns 1 for Esc.
load_device() {
    local list line
    list=$(api devices action=list)
    [ "$(result_of <<<"$list")" = ok ] || die "Could not list devices: $(result_of <<<"$list")"
    line=$(device_rows <<<"$list" | awk -F'\t' -v n="$DEVICE" '$1==n')
    if [ -n "$line" ] && [ "$(cut -f3 <<<"$line")" = ready ]; then
        DEVICE_IP=$(cut -f4 <<<"$line"); return 0
    fi
    warn "Device $DEVICE is no longer on your AirVPN account (or not ready); pick another."
    [ "$TUI" = 1 ] && tui_msg "⚠ Device $DEVICE is no longer on your AirVPN account (or not ready). Pick another one next."
    pick_device
}

# pick_port — the WireGuard port. Returns 1 for Esc.
pick_port() {
    local p
    if [ "$TUI" = 1 ]; then
        p=$(TUI_TITLE="WireGuard port" tui menu "AirVPN takes WireGuard on these UDP ports. If your network blocks or slows down one, try another." "$WG_PORT" \
            "$(for p in $WG_PORTS; do printf '%s\tUDP %s%s\n' "$p" "$p" "$([ "$p" = 1637 ] && echo ' (default)')"; done)") || return 1
    else
        while :; do
            p=$(ask "WireGuard port ($WG_PORTS)" "$WG_PORT")
            [[ " $WG_PORTS " == *" $p "* ]] && break
            echo "Pick one of: $WG_PORTS"
        done
    fi
    WG_PORT=$p; ARG_PORT=""
}

# status_text — the current server's health and the saved settings.
status_text() {
    local status used conf_time
    status=$(api status)
    if [ "$(result_of <<<"$status")" = ok ]; then
        N="$SERVER" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
m = [s for s in d["servers"] if s["public_name"] == os.environ["N"]]
if not m:
    print("Server:       %s is no longer listed by AirVPN!" % os.environ["N"])
else:
    s = m[0]
    print("Server:       %s (%s, %s): health %s, load %s%%, %s users, %s Mbit/s" % (
        s["public_name"], s.get("location", "?"), s.get("country_name", "?"), s.get("health", "?"),
        s.get("currentload", "?"), s.get("users", "?"), s.get("bw_max", "?")))
    w = " ".join(s.get("warning", "").split())
    if w:
        print("              warning: " + w)' <<<"$status"
    else
        echo "Server:       $SERVER (could not reach the AirVPN status API)"
    fi
    echo "Device:       $DEVICE"
    echo "Port:         UDP $WG_PORT, endpoint $(sed -n 's/^Endpoint *= *//p' "$OUTPUT" 2>/dev/null)"
    conf_time=$(date -r "$OUTPUT" '+%Y-%m-%d %H:%M' 2>/dev/null)
    echo "wg0.conf:     $OUTPUT${conf_time:+ (written $conf_time)}"
    used=$(containers_using "$OUTPUT" | xargs)
    echo "Used by:      ${used:-no running container}"
    echo "Filters:      ${COUNTRIES:-all countries}, >= ${MIN_BW:-the largest size} Mbit/s"
    monitor_summary | sed '1s/^/Monitor:      /; 2,$s/^/              /'
    if [ -s "$STATE_FILE" ]; then
        echo "Active alerts: $(cut -d'|' -f2 "$STATE_FILE" | paste -sd ';' - | sed 's/;/; /g')"
    fi
    if [ -s "$SWITCH_FAILED_FILE" ]; then
        echo "Last auto-switch failed: $(cat "$SWITCH_FAILED_FILE")"
    fi
}

# menu_action <action> — one menu entry. Returns 1 if it was left with Esc.
menu_action() {
    case "$1" in
        server)
            ensure_key; load_device || return 1
            pick_server || return 1
            generate; install_self; save_settings; setup_cron; finish_change ;;
        device)
            ensure_key; pick_device || return 1
            generate; install_self; save_settings; setup_cron; finish_change ;;
        port)
            pick_port || return 1
            ensure_key; load_device || return 1
            generate; install_self; save_settings; setup_cron; finish_change ;;
        alerts)
            configure_monitor || return 1
            save_monitor_settings; install_self; setup_cron ;;
        test)
            if [ "$ALERT_CHANNEL" = none ]; then
                [ "$TUI" = 1 ] && tui_msg "No alert channel is set up yet: pick \"Alerts and auto-switch\" first." && return 1
                warn "No alert channel is set up yet: pick \"Alerts and auto-switch\" first."; return 0
            fi
            local err
            if err=$(send_alert "AirVPN monitor test" "Test from airvpn-wg.sh on $(hostname)." 2>&1); then
                [ "$TUI" = 1 ] && { tui_msg "Test alert sent via $ALERT_CHANNEL."; return 1; }
                ok "Test alert sent via $ALERT_CHANNEL"
            else
                [ "$TUI" = 1 ] && { tui_msg "⚠ $(tail -n 1 <<<"$err" | sed "s/^⚠️ *//")"; return 1; }
                echo "$err" >&2
            fi ;;
        status)
            if [ "$TUI" = 1 ]; then
                TUI_TITLE="Status" tui_msg "$(status_text)"; return 1
            fi
            echo; status_text ;;
        setup)
            run_setup || return 1 ;;
    esac
}

# home_menu — the menu, until q (or Esc).
home_menu() {
    local choice items summary
    items=$'server\t1) Change server\t1
device\t2) Change device (WireGuard key)\t2
port\t3) Change WireGuard port\t3
alerts\t4) Alerts and auto-switch\t4
test\t5) Send a test alert\t5
status\t6) Status: is the server OK?\t6
setup\t7) Full setup again\t7
quit\tq) Quit\tq'
    while :; do
        summary="Server $SERVER, device $DEVICE, UDP $WG_PORT -> $OUTPUT
Alerts: $(monitor_summary | paste -sd ';' - | sed 's/;/; /')"
        if [ "$TUI" = 1 ]; then
            choice=$(tui menu "$summary" server "$items") || choice=quit
        else
            echo
            echo "$summary"
            cut -f2 <<<"$items" | sed 's/^/  /'
            while :; do
                choice=$(ask "Choice" "q")
                choice=$(awk -F'\t' -v k="$choice" '$3 == k { print $1 }' <<<"$items")
                [ -n "$choice" ] && break
                echo "Type 1-7 or q."
            done
        fi
        [ "$choice" = quit ] && return 0
        echo
        # Back from the full-screen menus: show what the change printed.
        if menu_action "$choice" && [ "$TUI" = 1 ]; then
            tty_read -rp "Press Enter to go back to the menu... " _
        fi
    done
}

# ── Main ────────────────────────────────────────────────────────────────────
case "$CMD" in
    monitor)
        monitor ;;
    test-alert)
        [ "$ALERT_CHANNEL" != none ] || die "No alert channel configured. Run: bash $(q "$SCRIPT_PATH") alerts --output $(q "$OUTPUT")"
        send_alert "AirVPN monitor test" "Test from airvpn-wg.sh on $(hostname)." && ok "Test alert sent via $ALERT_CHANNEL" ;;
    alerts)
        [ -f "$ENV_FILE" ] || die "No $ENV_FILE. Run setup first."
        configure_monitor || { info "Cancelled; nothing was changed."; exit 0; }
        save_monitor_settings; install_self; setup_cron ;;
    menu)
        [ -n "$DEVICE" ] && [ -n "$SERVER" ] || die "Nothing set up yet for $OUTPUT. Run: bash $(q "$SELF") setup --output $(q "$OUTPUT")"
        home_menu ;;
    setup)
        run_setup || info "Cancelled; nothing was changed."
        ;;
esac
