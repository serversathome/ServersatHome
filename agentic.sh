#!/usr/bin/env bash
# ============================================================================
# Claude Code LXC Deployer for Proxmox
# Creates a fully provisioned Ubuntu 26.04 LXC container ready for Claude Code
#
# Run on your Proxmox host:
#   curl -fsSL https://raw.githubusercontent.com/serversathome/ServersatHome/main/agentic.sh -o /tmp/agentic.sh && bash /tmp/agentic.sh
#
# GitHub: https://github.com/serversathome/ServersatHome
# ============================================================================

set -euo pipefail

# ── Colors & Helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

header() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║        Claude Code LXC Deployer (Proxmox)        ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Pre-flight checks ──────────────────────────────────────────────────────
preflight() {
  [[ $(id -u) -eq 0 ]] || error "This script must be run as root on the Proxmox host."
  command -v pct   &>/dev/null || error "pct not found. Are you running this on a Proxmox host?"
  command -v pveam &>/dev/null || error "pveam not found. Are you running this on a Proxmox host?"
}

# ── Template Resolution ─────────────────────────────────────────────────────
resolve_template() {
  info "Resolving latest Ubuntu 26.04 LXC template from catalog..."
  pveam update >/dev/null 2>&1 || true
  local found
  found=$(pveam available --section system 2>/dev/null \
            | awk '{print $NF}' \
            | grep -E '^ubuntu-26\.04-standard' \
            | sort -V | tail -n1)
  if [[ -n "$found" ]]; then
    TEMPLATE="$found"
    success "Using template: $TEMPLATE"
  else
    TEMPLATE="ubuntu-26.04-standard_26.04-1_amd64.tar.zst"
    warn "No 26.04 template found in catalog; using fallback name: $TEMPLATE"
    warn "Verify with: pveam available --section system | grep ubuntu-26.04"
  fi
}

# ── Configuration ───────────────────────────────────────────────────────────
get_config() {
  # Find next available CT ID
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")

  # Resolve newest Ubuntu 26.04 template (sets $TEMPLATE)
  resolve_template

  echo -e "${BOLD}Container Configuration${NC}"
  echo "─────────────────────────────────────────────────"

  read -rp "Container ID [$next_id]: " CT_ID
  CT_ID="${CT_ID:-$next_id}"
  [[ "$CT_ID" =~ ^[0-9]+$ ]] || error "Container ID must be a number."
  pct status "$CT_ID" &>/dev/null && error "Container ID $CT_ID already exists."

  read -rp "Hostname [claude-code]: " CT_HOSTNAME
  CT_HOSTNAME="${CT_HOSTNAME:-claude-code}"

  read -rsp "Root password: " CT_PASSWORD
  echo ""
  [[ -n "$CT_PASSWORD" ]] || error "Password cannot be empty."

  read -rp "CPU cores [4]: " CT_CORES
  CT_CORES="${CT_CORES:-4}"

  read -rp "RAM in MB [10240]: " CT_RAM
  CT_RAM="${CT_RAM:-10240}"

  read -rp "Swap in MB [2048]: " CT_SWAP
  CT_SWAP="${CT_SWAP:-2048}"

  read -rp "Disk size in GB [30]: " CT_DISK
  CT_DISK="${CT_DISK:-30}"

  read -rp "Storage [truenas-lvm]: " CT_STORAGE
  CT_STORAGE="${CT_STORAGE:-truenas-lvm}"

  # Network - default DHCP
  read -rp "IP address (DHCP or x.x.x.x/xx) [dhcp]: " CT_IP
  CT_IP="${CT_IP:-dhcp}"
  if [[ "$CT_IP" != "dhcp" ]]; then
    read -rp "Gateway: " CT_GW
    [[ -n "$CT_GW" ]] || error "Gateway is required for static IP."
  fi

  read -rp "DNS server [1.1.1.1]: " CT_DNS
  CT_DNS="${CT_DNS:-1.1.1.1}"

  # SSH key (optional)
  read -rp "Path to SSH public key (optional, press Enter to skip): " CT_SSH_KEY

  echo ""
  echo -e "${BOLD}Summary${NC}"
  echo "─────────────────────────────────────────────────"
  echo "  CT ID:     $CT_ID"
  echo "  Hostname:  $CT_HOSTNAME"
  echo "  Template:  $TEMPLATE"
  echo "  CPU:       $CT_CORES cores"
  echo "  RAM:       $CT_RAM MB ($(( CT_RAM / 1024 )) GB)"
  echo "  Swap:      $CT_SWAP MB"
  echo "  Disk:      ${CT_DISK}G on $CT_STORAGE"
  echo "  Network:   $CT_IP"
  echo "  DNS:       $CT_DNS"
  echo "─────────────────────────────────────────────────"
  echo ""
  read -rp "Proceed? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

# ── Download Ubuntu 26.04 Template ─────────────────────────────────────────
get_template() {
  info "Checking for template: $TEMPLATE"
  if ! pveam list local 2>/dev/null | grep -q "$TEMPLATE"; then
    info "Downloading $TEMPLATE ..."
    pveam download local "$TEMPLATE" || error "Failed to download template. Run 'pveam update' and try again."
  else
    success "Template already downloaded: $TEMPLATE"
  fi
  TEMPLATE_PATH="local:vztmpl/$TEMPLATE"
}

# ── Create Container ───────────────────────────────────────────────────────
create_container() {
  info "Creating LXC container $CT_ID..."

  # Build network string
  local net_str="name=eth0,bridge=vmbr0"
  if [[ "$CT_IP" == "dhcp" ]]; then
    net_str+=",ip=dhcp"
  else
    net_str+=",ip=$CT_IP,gw=$CT_GW"
  fi

  # Build pct create command
  local cmd=(
    pct create "$CT_ID" "$TEMPLATE_PATH"
    --hostname "$CT_HOSTNAME"
    --password "$CT_PASSWORD"
    --cores "$CT_CORES"
    --memory "$CT_RAM"
    --swap "$CT_SWAP"
    --rootfs "$CT_STORAGE:$CT_DISK"
    --net0 "$net_str"
    --nameserver "$CT_DNS"
    --ostype ubuntu
    --unprivileged 0
    --features nesting=1,keyctl=1
    --onboot 1
    --start 0
  )

  # Add SSH key if provided
  if [[ -n "${CT_SSH_KEY:-}" && -f "$CT_SSH_KEY" ]]; then
    cmd+=(--ssh-public-keys "$CT_SSH_KEY")
  fi

  "${cmd[@]}"
  success "Container $CT_ID created."

  # Disable AppArmor for Docker-in-LXC compatibility
  info "Setting AppArmor profile to unconfined (required for Docker)..."
  echo "lxc.apparmor.profile: unconfined" >> "/etc/pve/lxc/${CT_ID}.conf"
}

# ── Start & Wait for Network ──────────────────────────────────────────────
start_container() {
  info "Starting container $CT_ID..."
  pct start "$CT_ID"
  sleep 3

  info "Waiting for network (DNS + outbound HTTPS to github.com)..."
  # Test what provisioning actually needs — name resolution and an outbound TCP
  # connection — rather than ICMP, which some networks block and which proves
  # nothing about DNS. bash's /dev/tcp needs no extra packages in the template.
  local attempts=0
  while ! pct exec "$CT_ID" -- bash -c 'getent hosts github.com >/dev/null && timeout 5 bash -c "exec 3<>/dev/tcp/github.com/443"' &>/dev/null; do
    (( ++attempts ))
    [[ $attempts -lt 30 ]] || error "Container failed to get network after 60s (check DNS '$CT_DNS', the gateway, and bridge vmbr0)."
    sleep 2
  done
  success "Container is online."
}

# ── Provision Container ───────────────────────────────────────────────────
provision_container() {
  info "Provisioning container (this takes a few minutes)..."

  # Write provision script to host, then push into container
  cat > /tmp/provision-${CT_ID}.sh << 'PROVISION_EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo ">>> Setting timezone to America/New_York..."
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
echo "America/New_York" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

echo ">>> Generating locale..."
apt-get update -qq
apt-get install -y -qq locales
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
locale-gen en_US.UTF-8 > /dev/null 2>&1
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

echo ">>> Updating system..."
apt-get upgrade -y -qq

echo ">>> Installing core packages..."
apt-get install -y -qq \
  git curl wget unzip zip \
  ca-certificates gnupg lsb-release apt-transport-https software-properties-common \
  bash-completion locales \
  htop nano vim tmux screen \
  jq yq tree \
  net-tools iproute2 iputils-ping dnsutils \
  openssh-server \
  cron logrotate

echo ">>> Installing build tools & dev libraries..."
apt-get install -y -qq \
  build-essential make cmake pkg-config autoconf automake libtool \
  python3 python3-pip python3-venv python3-dev \
  libssl-dev libffi-dev libsqlite3-dev zlib1g-dev \
  libreadline-dev libbz2-dev libncurses-dev liblzma-dev libxml2-dev libxslt-dev

echo ">>> Installing search & productivity tools..."
apt-get install -y -qq \
  ripgrep fd-find fzf bat \
  rsync \
  sqlite3

echo ">>> Installing database clients..."
apt-get install -y -qq \
  postgresql-client redis-tools

echo ">>> Installing Node.js (latest LTS via NodeSource)..."
# setup_lts.x tracks the current LTS line, so fresh deploys get the newest
# *safe* Node automatically (Node 24 today; it rolls to the next LTS on its own
# when one lands — no script edit needed). We deliberately track LTS, not the
# odd/Current line (short-lived, not recommended here). apt upgrades keep it
# patched within the line; a major-version jump stays a deliberate rebuild
# rather than an unattended 4 a.m. surprise.
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt-get install -y -qq nodejs
# Quiet flags reused for every provisioning npm install: drop the funding/audit
# lines and the deprecation warnings that come from these packages' upstream
# transitive deps (not fixable from here). Scoped to provisioning only — your
# own installs under /project behave normally.
NPM_QUIET=(--no-fund --no-audit --loglevel=error)
# Take npm to its own latest release — the bundled npm lags behind and otherwise
# prints an "update available" notice on every install.
npm install -g "${NPM_QUIET[@]}" npm@latest || echo "    [WARN] npm self-update failed; using bundled npm"
echo "    Node.js $(node --version) / npm $(npm --version)"
# npm 12+ blocks dependencies' install scripts behind an allowlist (separate from
# ignore-scripts), so native modules like CloudCLI's better-sqlite3/node-pty/
# bcrypt never compile and the service crash-loops with no bind on :3001. We just
# took npm to latest (>=12), so set the allowlist NOW, before any native install
# below (CloudCLI, Playwright, the language servers). It persists to /root/.npmrc
# under npm 12+; harmless if npm is still <12.
npm config set dangerously-allow-all-scripts true 2>/dev/null || true

echo ">>> Installing global npm packages..."
npm install -g "${NPM_QUIET[@]}" typescript ts-node eslint prettier

echo ">>> Installing Go..."
GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
# Go's tarballs are per-architecture; the host arch decides (amd64 or arm64).
GO_ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile.d/go.sh
echo "    Go $(/usr/local/go/bin/go version | awk '{print $3}')"

echo ">>> Installing Rust..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
echo "    Rust $(rustc --version | awk '{print $2}')"

echo ">>> Installing Docker..."
curl -fsSL https://get.docker.com | sh
systemctl enable docker
echo "    Docker $(docker --version | awk '{print $3}' | tr -d ',')"

echo ">>> Installing Docker Compose plugin..."
apt-get install -y -qq docker-compose-plugin 2>/dev/null || true
echo "    Compose $(docker compose version --short 2>/dev/null || echo 'included with Docker')"

echo ">>> Installing Claude Code (native installer)..."
curl -fsSL https://claude.ai/install.sh | bash
# Ensure claude is on PATH for all sessions
if [[ -f "$HOME/.local/bin/claude" ]]; then
  ln -sf "$HOME/.local/bin/claude" /usr/local/bin/claude 2>/dev/null || true
elif [[ -f "$HOME/.claude/bin/claude" ]]; then
  ln -sf "$HOME/.claude/bin/claude" /usr/local/bin/claude 2>/dev/null || true
fi
CLAUDE_BIN="$(command -v claude || echo /usr/local/bin/claude)"
echo "    Claude Code installed: $("$CLAUDE_BIN" --version 2>/dev/null || echo 'version unknown')"

echo ">>> Configuring Claude Code settings (permissions + env)..."
# NOTE on enabledPlugins: we DO declare it here. Earlier belief was that
# enabledPlugins is ignored in non-interactive/container contexts — that's
# wrong. `claude plugin install X@mkt` installs the plugin but leaves it
# Status: disabled; the enabled-state lives in enabledPlugins in THIS file
# (user settings, ~/.claude/settings.json), which IS honored. Without this
# block every plugin below (including the LSP servers) stays disabled and
# CloudCLI's /project chat shows only the 1 local skill. Enabled skills show
# up live after the cloudcli restart — no fresh session needed.
#
# Verified keys (checked against code.claude.com/docs, 2026-10): everything
# below is current. CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS must live inside "env"
# (it's an environment variable, not a top-level key) and agent teams are still
# experimental/opt-in. Dropped on purpose:
#   - CLAUDE_CODE_ENABLE_AUTO_MODE: documented as "accepted for compatibility,
#     no effect" — auto mode works from permissions.defaultMode alone.
#   - MAX_THINKING_TOKENS / alwaysThinkingEnabled: current models (Fable,
#     Opus/Sonnet/Haiku 5.x) use adaptive reasoning; a fixed thinking budget has
#     no effect on them. Use /effort (or "effortLevel") to tune a session.
#   - CLAUDE_CODE_MAX_OUTPUT_TOKENS: per-model defaults beat a blanket cap.
#   - CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: it also turns off feature-flag
#     fetching, which makes Remote Control (/rc) unavailable and stops the
#     background runs of plugin command sources. Not worth it for quiet logs.
#   - "enableRemoteControl": never a real key. Remote Control is enabled with
#     /rc (per session), `claude --rc`, or remoteControlAtStartup via /config.
mkdir -p /root/.claude
# Permissions model: auto mode instead of a blanket allow-list.
#   defaultMode "auto" auto-approves actions but routes them through a
#   background safety classifier (still blocks rm -rf / , rm -rf ~ , etc.).
#   Unlike bypassPermissions, auto mode is not documented as refused for root,
#   and defaultMode is honored from USER settings (~/.claude/settings.json) —
#   it is silently ignored if set in a project .claude/settings.json.
#   The "deny" list applies in EVERY mode (including auto) and is evaluated
#   before the classifier — it's the hard floor for credentials/secrets.
# Deny-rule syntax (permissions docs):
#   - Read paths: "~/x" = home, "//x" = absolute, "/x" = RELATIVE TO THE
#     SETTINGS FILE'S DIRECTORY (so a single-slash /root/... never matched the
#     real credentials file — that's why the home-anchored forms are used).
#   - Bash: "cmd *" matches the command and its args; "cmd*" (no space) is a
#     prefix match, so "mkfs*" also catches mkfs.ext4 & friends. ("cmd:*" is an
#     accepted alias for "cmd *".) Deny rules don't follow a binary by full path
#     or through `sh -c`; they're a floor, not a sandbox.
# DISABLE_AUTOUPDATER stops Claude's background auto-updater only; we update
# deliberately via `claude update` in agentic-update, which still works.
cat > /root/.claude/settings.json << 'SETTINGS'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "defaultMode": "auto",
    "deny": [
      "Read(**/.env)",
      "Read(**/.env.*)",
      "Read(**/.credentials.json)",
      "Read(~/.claude/.credentials.json)",
      "Read(~/.claude.json)",
      "Read(~/.cloudcli/auth.db)",
      "Read(**/secrets/**)",
      "Read(**/*.pem)",
      "Read(**/id_rsa)",
      "Read(**/id_ed25519)",
      "Bash(dd *)",
      "Bash(mkfs*)",
      "Bash(rm -rf / *)",
      "Bash(rm -rf ~ *)"
    ]
  },
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "DISABLE_AUTOUPDATER": "1"
  },
  "enabledPlugins": {
    "code-review@claude-plugins-official": true,
    "commit-commands@claude-plugins-official": true,
    "context7@claude-plugins-official": true,
    "frontend-design@claude-plugins-official": true,
    "security-guidance@claude-plugins-official": true,
    "claude-security@claude-plugins-official": true,
    "modern-web-guidance@claude-plugins-official": true,
    "typescript-lsp@claude-plugins-official": true,
    "pyright-lsp@claude-plugins-official": true,
    "gopls-lsp@claude-plugins-official": true,
    "rust-analyzer-lsp@claude-plugins-official": true,
    "clangd-lsp@claude-plugins-official": true,
    "superpowers@superpowers-marketplace": true,
    "elements-of-style@superpowers-marketplace": true
  }
}
SETTINGS

echo ">>> Adding plugin marketplaces..."
# The official marketplace is auto-registered on first INTERACTIVE launch only,
# so a non-interactive provisioning run must add it explicitly. We use ONLY the
# first-party marketplace now — the old 'anthropics/claude-code' demo repo
# (registers as 'claude-code-plugins') ships same-named example copies that
# shadow the official ones, and boxes were silently landing on those.
"$CLAUDE_BIN" plugin marketplace add anthropics/claude-plugins-official \
  || echo "    [WARN] could not add claude-plugins-official"
# Refresh the index BEFORE installing — a stale cache makes name@official
# silently fall through, which is how boxes ended up on demo copies.
"$CLAUDE_BIN" plugin marketplace update claude-plugins-official \
  || echo "    [WARN] could not update claude-plugins-official index"
# Third-party marketplace for Superpowers.
"$CLAUDE_BIN" plugin marketplace add obra/superpowers-marketplace \
  || echo "    [WARN] could not add superpowers-marketplace"

echo ">>> Installing Claude Code plugins (official CLI)..."
# Install pinned to the official marketplace only (no demo fallthrough).
# Non-fatal — a single failed plugin won't abort provisioning. Enabled-state is
# declared in settings.json above (enabledPlugins); install just stages files.
# --yes: a plugin with a marketplace-declared install command would otherwise
# wait on a y/n prompt that this non-interactive run can never answer.
install_plugin() {  # install_plugin <name> <marketplace>
  local ref="$1@$2"
  if "$CLAUDE_BIN" plugin install "$ref" --yes 2>/dev/null; then
    echo "    installed $ref"
  else
    echo "    [WARN] could not install plugin: $ref"
  fi
  return 0
}

# Curated plugins. modern-web-guidance fetches its guides via npx at query time,
# so it needs outbound npm access. LSP plugins give real-time diagnostics +
# navigation; they are thin wrappers around the language servers installed below
# and need the server binary on PATH (one per toolchain this box ships, incl.
# C/C++ via build-essential).
for p in frontend-design code-review commit-commands security-guidance context7 \
         claude-security modern-web-guidance \
         typescript-lsp pyright-lsp gopls-lsp rust-analyzer-lsp clangd-lsp; do
  install_plugin "$p" claude-plugins-official
done

# Superpowers also appears in the official marketplace, but pinned to a SHA that
# lags upstream — install from Jesse Vincent's own marketplace so the box tracks
# current releases. elements-of-style lives only there (pure markdown).
for p in superpowers elements-of-style; do
  install_plugin "$p" superpowers-marketplace
done

# Sanity check — list what actually landed.
echo ">>> Installed plugins:"
"$CLAUDE_BIN" plugin list 2>/dev/null || echo "    (plugin list unavailable)"

echo ">>> Installing language servers (backends for the *-lsp plugins)..."
# The *-lsp plugins are thin wrappers that shell out to a language server on
# PATH — they do NOT self-install the binary. Toolchains (Node/Go/Rust) are
# already installed above, so this just adds the servers. All non-fatal.
command -v typescript-language-server >/dev/null 2>&1 \
  || npm install -g "${NPM_QUIET[@]}" typescript-language-server typescript \
  || echo "    [WARN] typescript-language-server install failed"
command -v pyright-langserver >/dev/null 2>&1 \
  || npm install -g "${NPM_QUIET[@]}" pyright \
  || echo "    [WARN] pyright install failed"
command -v clangd >/dev/null 2>&1 \
  || apt-get install -y -qq clangd \
  || echo "    [WARN] clangd install failed"
if [ ! -x /usr/local/bin/gopls ] && [ -x /usr/local/go/bin/go ]; then
  GOBIN=/usr/local/bin /usr/local/go/bin/go install golang.org/x/tools/gopls@latest \
    || echo "    [WARN] gopls install failed"
fi
if ! command -v rust-analyzer >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/rustup" ]; then
  "$HOME/.cargo/bin/rustup" component add rust-analyzer >/dev/null 2>&1 \
    && ln -sf "$("$HOME/.cargo/bin/rustup" which rust-analyzer 2>/dev/null)" /usr/local/bin/rust-analyzer \
    || echo "    [WARN] rust-analyzer install failed"
fi

# ---------------------------------------------------------------------------
# FALLBACK if the above installs don't persist in your Claude Code version:
# The documented container mechanism is CLAUDE_CODE_PLUGIN_SEED_DIR (env-vars
# docs): a read-only directory (":"-separated list) whose marketplaces are
# registered at startup and whose cached plugins are used without re-cloning.
# If `claude plugin list` above is empty after provisioning, stage the plugin
# repos into a seed dir and export CLAUDE_CODE_PLUGIN_SEED_DIR=<dir> in
# /root/.bashrc, or simply run the `claude plugin install` commands above once
# inside an interactive session.
# ---------------------------------------------------------------------------

echo ">>> Installing webapp-testing skill (from anthropics/skills)..."
# Installed as a plain user skill (NOT a marketplace plugin). A SKILL.md placed
# under ~/.claude/skills/ is picked up automatically with no plugin entry needed.
git clone --depth 1 --filter=blob:none --sparse https://github.com/anthropics/skills.git /tmp/anthropic-skills
cd /tmp/anthropic-skills && git sparse-checkout set skills/webapp-testing
mkdir -p /root/.claude/skills/
cp -r /tmp/anthropic-skills/skills/webapp-testing /root/.claude/skills/webapp-testing
rm -rf /tmp/anthropic-skills
cd /root

echo ">>> Installing Playwright (Python) for the webapp-testing skill..."
# The webapp-testing skill imports the PYTHON playwright package
# ("from playwright.sync_api import ..."), so the Node playwright we install for
# CloudCLI's Browser feature is NOT enough — the pip package must be present too,
# or the skill dies at import. Both share the same browser cache
# (~/.cache/ms-playwright), so Chromium is downloaded once for both.
# Playwright supports Ubuntu 26.04 natively since 1.61 (microsoft/playwright#40117
# is closed), so the old PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64 hack
# is gone and must not be set — it would pull the wrong browser build. This whole
# block is non-fatal: a browser-install failure must NEVER abort provisioning
# (it previously killed everything after it — Docker services, SSH, cron —
# because the script runs under `set -e`).
set +e
unset PLAYWRIGHT_HOST_PLATFORM_OVERRIDE
pip install --break-system-packages -q playwright \
  && echo "    python playwright package installed" \
  || echo "    [WARN] pip install playwright failed (webapp-testing skill will error on import)"
if python3 -m playwright install --with-deps chromium; then
  echo "    Playwright chromium + OS deps installed"
elif python3 -m playwright install chromium; then
  echo "    Playwright chromium installed (browser only; some OS deps may be missing)"
else
  echo "    [WARN] Playwright browser install failed. Retry later with:"
  echo "      python3 -m playwright install --with-deps chromium"
fi
set -e

echo ">>> Setting up /project directory..."
mkdir -p /project
cat > /project/CLAUDE.md << 'CLAUDEMD'
# Claude Code Workspace

## Environment
- **OS**: Ubuntu 26.04 LXC container on Proxmox
- **Working directory**: /project
- **Timezone**: America/New_York
- **User**: root

## Available Tools
- **Languages**: Node.js (latest LTS), Python 3 (system default), Go (latest), Rust (latest)
- **Package managers**: npm, pip (use --break-system-packages), cargo, go install
- **Docker**: Docker Engine + Compose plugin, running and ready
- **Web UI**: CloudCLI UI (claudecodeui) on port 3001 — chat, file explorer/editor, git, shell
- **Search tools**: ripgrep (rg), fd-find (fdfind), fzf
- **Databases**: PostgreSQL client (psql), Redis client (redis-cli), SQLite3

## Permissions
Permission mode is "auto" (permissions.defaultMode in ~/.claude/settings.json).
Actions are auto-approved but pass through a background safety classifier that
still blocks catastrophic commands (rm -rf /, rm -rf ~). A deny floor in
~/.claude/settings.json applies in every mode and blocks reading
credentials/secrets (.env, *.pem, id_rsa, .credentials.json, ~/.claude.json,
the CloudCLI auth DB) — do not try to work around it.

## Agent Teams
Agent teams are enabled (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1; still
experimental). You can spawn parallel teammates for complex tasks:
- Use agent teams for work that benefits from parallel exploration
- Use subagents (the Agent tool) for quick focused work that reports back
- While teams are enabled, a *named* subagent launches as a teammate — leave
  subagents unnamed when you just want a worker that reports back
- Teammates run in-process by default; tmux is installed, so set
  `"teammateMode": "auto"` in ~/.claude/settings.json for split panes

## Remote Control
Remote Control lets you continue a session running on this box from the Claude
mobile app or claude.ai/code. Turn it on inside a session with `/remote-control`
(`/rc`), start a session with `claude --rc`, or run `claude remote-control` as a
headless server. To connect every session automatically, use `/config` →
"Enable Remote Control for all sessions" (it saves `remoteControlAtStartup` in
~/.claude/settings.json). Requires a claude.ai login (Pro/Max/Team/Enterprise;
API keys don't work), and the first use asks a one-time y/n confirmation, so do
it from an interactive shell.

## Docker Usage
Docker compose files should go in /docker/<service-name>/docker-compose.yml.
There is no always-on Watchtower daemon. Container images are refreshed one-shot
by the weekly `agentic-update` run (or on demand: `agentic-update`), so give
containers you want updated the usual `restart: unless-stopped`.
All Docker containers in this LXC need `security_opt: [apparmor=unconfined]`.

## Conventions
- Prefer creating files over printing long code blocks
- Use git for version control on all projects in /project/src/
- When installing Python packages, use: pip install --break-system-packages <package>
- Thinking is adaptive on current models (no fixed budget is configured); use
  `/effort` to raise or lower effort for a session

## Installed Plugins / Skills
Plugins are staged via the `claude plugin` CLI at provision time and enabled via
the `enabledPlugins` block in ~/.claude/settings.json. Run `claude plugin list`
to confirm what's active.
- **frontend-design**: Production-grade UI with distinctive aesthetics (auto-activates on frontend tasks)
- **code-review**: Multi-agent PR review with confidence scoring
- **commit-commands**: Git commit, push, and PR workflows (/commit, /push, /pr)
- **security-guidance**: Security warnings when editing sensitive files
- **claude-security**: Deeper security review (/security-review style audits)
- **context7**: Live, version-specific library docs lookup (reduces API hallucinations)
- **modern-web-guidance**: Current web-platform best practices (fetched via npx at query time)
- **typescript-lsp / pyright-lsp / gopls-lsp / rust-analyzer-lsp / clangd-lsp**:
  real-time diagnostics + navigation (backed by the language servers on PATH)
- **superpowers**: Development workflow framework — brainstorm → plan → implement with TDD
  - /superpowers:brainstorm — Refine ideas before coding
  - /superpowers:write-plan — Create implementation plans
  - /superpowers:execute-plan — Execute plans in batches via subagents
  - Auto-activating skills: test-driven-development, systematic-debugging, verification-before-completion
- **elements-of-style**: Writing-style guidance for prose, docs, and commit messages
- **webapp-testing** (local skill, not a marketplace plugin): Playwright-based
  browser testing for UI verification and debugging
CLAUDEMD

echo ">>> Configuring SSH..."
# Ubuntu's sshd_config Includes /etc/ssh/sshd_config.d/*.conf from the TOP of the
# file and the FIRST value of a keyword wins, so a drop-in (cloud-init ships one
# with PasswordAuthentication no) silently outranks any edit to the main file.
# Own a drop-in that sorts first instead, and keep the main-file edit for images
# that predate the Include.
sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/00-agentic.conf <<'SSHD'
# Managed by agentic.sh. Sorts before any other drop-in, and sshd keeps the first
# value it sees, so these win over cloud-init's defaults.
PermitRootLogin yes
PasswordAuthentication yes
SSHD
  chmod 0644 /etc/ssh/sshd_config.d/00-agentic.conf
fi
# Never restart into a config sshd rejects — that locks the box out of SSH.
if sshd -t 2>/dev/null || /usr/sbin/sshd -t 2>/dev/null; then
  systemctl enable ssh
  systemctl restart ssh || echo "    [WARN] ssh restart failed (check 'journalctl -u ssh')"
else
  echo "    [WARN] sshd config test failed; leaving the running sshd untouched"
fi

echo ">>> Setting up shell environment..."
cat >> /root/.bashrc << 'BASHRC'

# ── Claude Code Container ──────────────────────────────────
export EDITOR=nano
export LANG=en_US.UTF-8
export TZ=America/New_York
export PATH="$HOME/.local/bin:$HOME/.claude/bin:$HOME/.cargo/bin:/usr/local/go/bin:$PATH"

# Aliases
alias ll="ls -lah --color=auto"
alias cls="clear"
alias ..="cd .."
alias ...="cd ../.."
alias gs="git status"
alias gl="git log --oneline -20"
alias dc="docker compose"
alias dps="docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

# Always start in /project
cd /project 2>/dev/null || true
BASHRC

echo ">>> Setting up Git defaults..."
git config --global init.defaultBranch main
git config --global core.editor nano
git config --global pull.rebase false

echo ">>> Docker ready (no always-on service containers)..."
# code-server was removed — CloudCLI UI (below) already provides a file
# explorer/editor, so it was redundant (and dropped its :8443 + hardcoded
# 'admin' password surface). Watchtower is no longer a scheduled daemon; image
# updates for any containers YOU create now run one-shot from the coordinated
# 'agentic-update' script (see below).

echo ">>> Installing CloudCLI UI (claudecodeui web front end)..."
# Web front end for Claude Code: chat UI, file explorer/editor, git panel, and a
# built-in shell, served on :3001. It drives the same `claude` CLI and reads
# /root/.claude, so it inherits this container's login and auto-mode settings.
# It ships with its own login/auth (first-run account setup on the login page).
# Installed from the published npm package (latest, unpinned); the package
# includes a prebuilt server, so there is no client/server build step here.
npm install -g "${NPM_QUIET[@]}" @cloudcli-ai/cloudcli \
  || echo "    [WARN] CloudCLI UI install failed (needs Node 22+ and build tools for node-pty)"
# Self-heal in case the native build was still skipped (better-sqlite3 binding
# missing) — rebuild in place so the service can bind :3001. Gated by the
# allowlist set right after the npm self-update above.
CCUI_PKG="$(npm root -g 2>/dev/null)/@cloudcli-ai/cloudcli"
if [ -d "$CCUI_PKG/node_modules/better-sqlite3" ] && ! ls "$CCUI_PKG/node_modules/better-sqlite3/build/Release/"*.node >/dev/null 2>&1; then
  echo "    rebuilding CloudCLI native modules (better-sqlite3/node-pty/bcrypt)"
  ( cd "$CCUI_PKG" && npm rebuild >/dev/null 2>&1 ) || echo "    [WARN] CloudCLI native rebuild failed"
fi
CCUI_BIN="$(command -v cloudcli || echo /usr/bin/cloudcli)"
mkdir -p /root/.cloudcli
echo "    CloudCLI UI installed: $("$CCUI_BIN" version 2>/dev/null || echo 'version unknown')"

# Browser feature runtime. CloudCLI detects Playwright via require('playwright')
# from its GLOBAL package dir, but its in-app "Install Runtime" button installs
# into the server's cwd (/project) — which require() can't resolve, so the button
# silently never takes effect. Fix: install Playwright GLOBALLY (resolvable). The
# Chromium build is shared with the Python install above (~/.cache/ms-playwright),
# so this only downloads if that step failed.
echo ">>> Installing Playwright runtime for CloudCLI Browser feature..."
npm install -g "${NPM_QUIET[@]}" playwright \
  || echo "    [WARN] global Playwright install failed (CloudCLI Browser feature won't work)"
ls -d /root/.cache/ms-playwright/chromium-* >/dev/null 2>&1 \
  || playwright install chromium \
  || echo "    [WARN] Chromium download failed; retry later with: playwright install chromium"

# systemd unit so the UI survives reboots and restarts on failure.
cat > /etc/systemd/system/cloudcli.service << EOF
[Unit]
Description=CloudCLI UI (claudecodeui) - web front end for Claude Code
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=NODE_ENV=production
# NODE_ENV=production makes child 'npm install' omit devDependencies, which
# breaks CloudCLI's in-app plugin installs (their 'npm run build' is 'tsc' and
# needs typescript/@types/node). Force npm to include dev deps so plugin builds
# succeed.
Environment=NPM_CONFIG_INCLUDE=dev
Environment=HOME=/root
Environment=HOST=0.0.0.0
Environment=SERVER_PORT=3001
Environment=CLAUDE_CLI_PATH=/usr/local/bin/claude
Environment=DATABASE_PATH=/root/.cloudcli/auth.db
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.local/bin
WorkingDirectory=/project
ExecStart=${CCUI_BIN} start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudcli >/dev/null 2>&1 || true
systemctl start cloudcli \
  || echo "    [WARN] cloudcli service failed to start; check 'journalctl -u cloudcli'"

echo ">>> Installing coordinated update tooling (agentic-update / agentic-doctor)..."
# Single coordinated update pass, modeled on homelabhero's hh-update + hh doctor:
# OS packages -> Claude Code -> CloudCLI UI -> one-shot Watchtower for any Docker
# containers -> restart UI -> health check -> log. Re-runnable on demand
# ('agentic-update'), no container recreation required. Everything tracks latest
# (unpinned); the post-update health check is the safety net, and results land
# in /var/log/agentic-update.log.

cat > /usr/local/bin/agentic-doctor << 'DOCTOR'
#!/usr/bin/env bash
# Health check for the Claude Code container. Exit 0 = healthy, non-zero = problems.
LOG_TAG="[doctor]"
rc=0
check() { if eval "$2" >/dev/null 2>&1; then echo "  OK   $1"; else echo "  FAIL $1"; rc=1; fi; }
# note() is informational only — it never fails the health check. Used for
# user-actionable states (like "not logged in yet") that aren't container faults.
note()  { if eval "$2" >/dev/null 2>&1; then echo "  OK   $1"; else echo "  WARN $1"; fi; }

echo "$LOG_TAG $(date '+%Y-%m-%d %H:%M:%S %Z')"
check "claude binary present"       "command -v claude"
check "claude reports a version"    "claude --version"
check "settings.json is valid JSON" "python3 -m json.tool /root/.claude/settings.json"
note  "claude logged in (creds on disk; run 'claude' /login if WARN)" "test -s /root/.claude/.credentials.json"
check "cloudcli service active"     "systemctl is-active --quiet cloudcli"
check "UI listening on :3001"       "ss -ltn | grep -q ':3001'"
check "docker daemon running"       "systemctl is-active --quiet docker"
# Parse df once; an unreadable df is a "can't tell", not a failed box.
DISK_PCT=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc 0-9)
if [ -n "$DISK_PCT" ]; then
  check "disk under 90% on /"       "[ $DISK_PCT -lt 90 ]"
else
  echo "  WARN could not read disk usage for /"
fi

if [ $rc -eq 0 ]; then echo "$LOG_TAG all checks passed"; else echo "$LOG_TAG one or more checks FAILED"; fi
exit $rc
DOCTOR
chmod +x /usr/local/bin/agentic-doctor

cat > /usr/local/bin/agentic-update << 'UPDATE'
#!/usr/bin/env bash
# Coordinated update pass for the Claude Code container.
#   Run on demand:  agentic-update
#   Runs weekly via /etc/cron.d/agentic-update. Log: /var/log/agentic-update.log
# Deliberately NOT 'set -e': one component failing must not abort the rest.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
LOG=/var/log/agentic-update.log
exec >>"$LOG" 2>&1
echo "==================================================================="
echo ">>> agentic-update starting: $(date '+%Y-%m-%d %H:%M:%S %Z')"

echo ">>> [1/6] OS packages (includes Node.js patches within its LTS line)..."
apt-get update -qq && apt-get upgrade -y -qq && apt-get autoremove -y -qq && apt-get clean -qq

echo ">>> [2/6] npm (latest)..."
npm install -g --no-fund --no-audit --loglevel=error npm@latest || echo "    [WARN] npm self-update failed"
# npm 12+ blocks dependencies' install scripts behind an allowlist (separate
# from ignore-scripts), so CloudCLI's native deps (better-sqlite3/node-pty/
# bcrypt) never compile -> cloudcli crash-loops and nothing binds :3001. Boxes
# deploy on npm 10 (builds fine) but this weekly run upgrades npm above, so the
# config MUST be set here -- AFTER npm@latest lands (it only persists to
# /root/.npmrc under npm 12+) and BEFORE the cloudcli reinstall/rebuild below.
npm config set dangerously-allow-all-scripts true 2>/dev/null || true

echo ">>> [3/6] Claude Code..."
# `claude update` is the documented manual update path for a native install
# (DISABLE_AUTOUPDATER only stops the background check; `update` still works and
# honors the autoUpdatesChannel / minimumVersion settings). Fall back to
# re-running the installer when claude is missing or too old to have `update`.
if command -v claude >/dev/null 2>&1 && claude update; then
  echo "    Claude Code: $(claude --version 2>/dev/null || echo 'version unknown')"
else
  curl -fsSL https://claude.ai/install.sh | bash || echo "    [WARN] Claude Code update failed"
fi

echo ">>> [4/6] CloudCLI UI (claudecodeui)..."
npm install -g --no-fund --no-audit --loglevel=error @cloudcli-ai/cloudcli@latest || echo "    [WARN] CloudCLI UI update failed"
# Self-heal: if the native build was skipped (better-sqlite3 binding missing),
# rebuild in place before restart -- else cloudcli loops on "Could not locate
# the bindings file". npm rebuild is itself gated by the config set above.
CCUI_PKG="$(npm root -g 2>/dev/null)/@cloudcli-ai/cloudcli"
if [ -d "$CCUI_PKG/node_modules/better-sqlite3" ] && ! ls "$CCUI_PKG/node_modules/better-sqlite3/build/Release/"*.node >/dev/null 2>&1; then
  echo "    rebuilding CloudCLI native modules (better-sqlite3/node-pty/bcrypt)"
  ( cd "$CCUI_PKG" && npm rebuild >/dev/null 2>&1 ) || echo "    [WARN] CloudCLI native rebuild failed"
fi
systemctl restart cloudcli || echo "    [WARN] cloudcli restart failed"

echo ">>> [5/6] Docker images (one-shot Watchtower)..."
if command -v docker >/dev/null 2>&1 && [ -n "$(docker ps -q 2>/dev/null)" ]; then
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower --run-once --cleanup \
    || echo "    [WARN] Watchtower one-shot run failed"
else
  echo "    (no running containers; skipped)"
fi

echo ">>> [6/6] Health check..."
if agentic-doctor; then
  echo ">>> agentic-update finished OK: $(date '+%Y-%m-%d %H:%M:%S %Z')"
else
  echo ">>> agentic-update finished WITH HEALTH-CHECK FAILURES: $(date '+%Y-%m-%d %H:%M:%S %Z')"
fi
echo ""
UPDATE
chmod +x /usr/local/bin/agentic-update

cat > /etc/cron.d/agentic-update << 'CRON'
# Weekly coordinated update - Sunday 4:00 AM ET
# (OS + Claude Code + CloudCLI UI + container images, then a health check)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 4 * * 0 root /usr/local/bin/agentic-update
CRON
chmod 0644 /etc/cron.d/agentic-update

cat > /etc/logrotate.d/agentic-update << 'LOGROTATE'
/var/log/agentic-update.log {
    monthly
    rotate 3
    compress
    missingok
    notifempty
}
LOGROTATE

echo ">>> Cleaning up..."
apt-get autoremove -y -qq
apt-get clean -qq
rm -rf /var/lib/apt/lists/*

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║              Provisioning Complete!              ║"
echo "╚══════════════════════════════════════════════════╝"
PROVISION_EOF

  chmod +x /tmp/provision-${CT_ID}.sh
  pct push "$CT_ID" /tmp/provision-${CT_ID}.sh /tmp/provision.sh
  pct exec "$CT_ID" -- chmod +x /tmp/provision.sh
  pct exec "$CT_ID" -- /tmp/provision.sh
  rm -f /tmp/provision-${CT_ID}.sh
}

# ── Write Proxmox Notes ─────────────────────────────────────────────────────
# Drops a Markdown "card" into the container's Notes panel in the Proxmox UI
# (rendered as Markdown on PVE 7+). Uses placeholders so the heredoc can stay
# single-quoted (no accidental expansion of backticks/$ in the Markdown).
write_notes() {
  local ct_ip
  ct_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
  ct_ip="${ct_ip:-<container-ip>}"

  local notes
  notes=$(cat <<'EOF'
# 🤖 Claude Code Container

**Web UI (CloudCLI UI):** http://__IP__:3001 — _create a login on first visit_
**SSH:** `ssh root@__IP__`   |   **Console:** `pct enter __CTID__`

## Start Claude Code
Log in, then run `claude` (the shell auto-cd's to `/project`).

## Update & health
- `agentic-update` — one coordinated pass: OS → Claude Code → Web UI → container images → health check
- `agentic-doctor` — run the health check on its own
- Auto-runs weekly (Sunday 4 AM ET). Log: `/var/log/agentic-update.log`

## Service & config
- `systemctl status cloudcli` — the Web UI service (`journalctl -u cloudcli` for logs)
- Permissions: **auto mode** + secret deny-floor — `/root/.claude/settings.json`

---
_IP above is the address at deploy time; on DHCP it may change (check with `pct exec __CTID__ -- hostname -I`)._
EOF
)
  notes=${notes//__IP__/$ct_ip}
  notes=${notes//__CTID__/$CT_ID}

  if pct set "$CT_ID" --description "$notes" >/dev/null 2>&1; then
    success "Wrote container notes to the Proxmox UI."
  else
    warn "Could not set container notes (non-fatal)."
  fi
}

# ── Print Summary ─────────────────────────────────────────────────────────
print_summary() {
  local ct_ip
  ct_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')

  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║              Claude Code LXC Ready!               ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Container:${NC} $CT_ID ($CT_HOSTNAME)"
  echo -e "  ${BOLD}IP:${NC}        ${ct_ip:-pending (DHCP)}"
  echo -e "  ${BOLD}Resources:${NC} ${CT_CORES} CPU / $(( CT_RAM / 1024 )) GB RAM / ${CT_DISK} GB disk"
  echo -e "  ${BOLD}Storage:${NC}   $CT_STORAGE"
  echo -e "  ${BOLD}Timezone:${NC}  America/New_York"
  echo ""
  echo -e "  ${BOLD}Connect:${NC}"
  echo -e "    Console: ${CYAN}pct enter $CT_ID${NC}"
  [[ -n "${ct_ip:-}" ]] && echo -e "    SSH:     ${CYAN}ssh root@${ct_ip}${NC}"
  [[ -n "${ct_ip:-}" ]] && echo -e "    Web UI:  ${CYAN}http://${ct_ip}:3001${NC} (CloudCLI UI — create a login on first visit)"
  echo ""
  echo -e "  ${BOLD}Start Claude Code:${NC}"
  echo -e "    ${CYAN}claude${NC}  (shell auto-cd's to /project on login)"
  echo ""
  echo -e "  ${BOLD}Verify plugins:${NC} ${CYAN}claude plugin list${NC}"
  echo ""
  echo -e "  ${BOLD}Installed:${NC}"
  echo "    • Claude Code (native)      • Node.js (latest LTS)"
  echo "    • Python 3 + pip + venv     • Go (latest)"
  echo "    • Rust (via rustup)         • Docker + Compose"
  echo "    • Git, ripgrep, fzf, fd     • Build essentials"
  echo "    • PostgreSQL & Redis CLI    • CloudCLI UI web front end (port 3001)"
  echo ""
  echo -e "  ${BOLD}Permissions:${NC} Auto mode (classifier-guarded) + deny floor for secrets"
  echo -e "  ${BOLD}Config:${NC}      ~/.claude/settings.json"
  echo -e "  ${BOLD}Features:${NC}    Agent teams (experimental), adaptive thinking/effort (tune with ${CYAN}/effort${NC})"
  echo -e "  ${BOLD}Remote Control:${NC} ${CYAN}/rc${NC} in a session, ${CYAN}claude --rc${NC}, or all sessions via ${CYAN}/config${NC} (claude.ai login)"
  echo -e "  ${BOLD}Plugins:${NC}     frontend-design, code-review, commit-commands, security-guidance, claude-security,"
  echo -e "               context7, modern-web-guidance, superpowers, elements-of-style,"
  echo -e "               + LSP (typescript/pyright/gopls/rust-analyzer/clangd)"
  echo -e "  ${BOLD}Skills:${NC}      webapp-testing (local, Playwright)"
  echo -e "  ${BOLD}Updates:${NC}     Sundays 4 AM ET — coordinated (OS + Claude + UI + containers)"
  echo -e "               then a health check. Run anytime: ${CYAN}agentic-update${NC} / ${CYAN}agentic-doctor${NC}"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
  header
  preflight
  get_config
  get_template
  create_container
  start_container
  provision_container
  write_notes
  print_summary
}

main "$@"
