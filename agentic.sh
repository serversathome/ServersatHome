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

  info "Waiting for network..."
  local attempts=0
  while ! pct exec "$CT_ID" -- ping -c1 -W2 1.1.1.1 &>/dev/null; do
    ((attempts++))
    [[ $attempts -lt 30 ]] || error "Container failed to get network after 60s."
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

echo ">>> Installing global npm packages..."
npm install -g "${NPM_QUIET[@]}" typescript ts-node eslint prettier

echo ">>> Installing Go..."
GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
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
# Verified keys (checked against code.claude.com/docs, 2026-07): the env vars
# below are all valid current settings. CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
# must live inside "env" (it's an environment variable, not a top-level key).
# Removed: CLAUDE_CODE_ENABLE_AUTO_MODE (dead no-op since Claude Code v2.1.207 —
# auto mode works from permissions.defaultMode alone) and alwaysThinkingEnabled
# (current models use adaptive thinking; MAX_THINKING_TOKENS still caps the
# budget). The old "enableRemoteControl" key was never real — Remote Control is
# enabled per-session with /rc or for all sessions via /config (Pro/Max).
mkdir -p /root/.claude
# Permissions model: auto mode instead of a blanket allow-list.
#   defaultMode "auto" auto-approves actions but routes them through a
#   background safety classifier (still blocks rm -rf / , rm -rf ~ , etc.).
#   Unlike bypassPermissions, auto mode is NOT refused when running as root,
#   and defaultMode is honored from user settings (~/.claude/settings.json).
#   The "deny" list applies in EVERY mode (including auto) — it's the hard
#   floor protecting credentials/secrets and a few destructive commands.
# Env extras: DISABLE_AUTOUPDATER stops Claude's background auto-updater (we
# self-manage the version via agentic-update, so the background check just
# risks version drift/races); CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC is the
# umbrella that silences telemetry/error-reporting/feedback/surveys for a quiet
# headless box (trade-off: also disables error reporting).
cat > /root/.claude/settings.json << 'SETTINGS'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "defaultMode": "auto",
    "deny": [
      "Read(**/.env)",
      "Read(**/.env.*)",
      "Read(**/.credentials.json)",
      "Read(/root/.claude/.credentials.json)",
      "Read(**/secrets/**)",
      "Read(**/*.pem)",
      "Read(**/id_rsa)",
      "Read(**/id_ed25519)",
      "Bash(dd:*)",
      "Bash(mkfs:*)",
      "Bash(rm -rf /:*)",
      "Bash(rm -rf ~:*)"
    ]
  },
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000",
    "MAX_THINKING_TOKENS": "31999",
    "DISABLE_AUTOUPDATER": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  },
  "enabledPlugins": {
    "code-review@claude-plugins-official": true,
    "commit-commands@claude-plugins-official": true,
    "context7@claude-plugins-official": true,
    "frontend-design@claude-plugins-official": true,
    "security-guidance@claude-plugins-official": true,
    "typescript-lsp@claude-plugins-official": true,
    "pyright-lsp@claude-plugins-official": true,
    "gopls-lsp@claude-plugins-official": true,
    "rust-analyzer-lsp@claude-plugins-official": true,
    "superpowers@superpowers-marketplace": true
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
install_plugin() {
  local name="$1"
  if "$CLAUDE_BIN" plugin install "${name}@claude-plugins-official" 2>/dev/null; then
    echo "    installed ${name}@claude-plugins-official"
  else
    echo "    [WARN] could not install plugin: ${name}@claude-plugins-official"
  fi
  return 0
}

install_plugin frontend-design
install_plugin code-review
install_plugin commit-commands
install_plugin security-guidance
install_plugin context7
# LSP plugins — real-time diagnostics + navigation. Thin wrappers around the
# language servers installed below; they need the server binary on PATH.
install_plugin typescript-lsp
install_plugin pyright-lsp
install_plugin gopls-lsp
install_plugin rust-analyzer-lsp

# Superpowers lives in its own marketplace.
"$CLAUDE_BIN" plugin install superpowers@superpowers-marketplace 2>/dev/null \
  && echo "    installed superpowers@superpowers-marketplace" \
  || echo "    [WARN] could not install superpowers"

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
# Headless plugin install has been historically finicky. The container-intended
# mechanism is the (currently undocumented) CLAUDE_CODE_PLUGIN_SEED_DIR env var,
# which seeds pre-staged plugins on first launch. If `claude plugin list` above
# is empty after provisioning, stage the plugin repos into a seed dir and export
# CLAUDE_CODE_PLUGIN_SEED_DIR=<dir> in /root/.bashrc, or simply run the
# `claude plugin install` commands above once inside an interactive session.
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
# Playwright doesn't support Ubuntu 26.04 yet (microsoft/playwright#40117) and
# hard-errors instead of falling back, so force the ubuntu24.04 build, which runs
# fine on 26.04's newer glibc. This whole block is non-fatal: a browser-install
# failure must NEVER abort provisioning (it previously killed everything after
# it — Docker services, SSH, cron — because the script runs under `set -e`).
set +e
# The override MUST include the arch suffix — Playwright's build keys are
# "ubuntu24.04-x64", not "ubuntu24.04". Without "-x64" it can't find a build.
export PLAYWRIGHT_HOST_PLATFORM_OVERRIDE="ubuntu24.04-x64"
# Make the override durable for interactive sessions too (systemd services read
# their own Environment=, but 'claude' launched over SSH reads /etc/environment),
# so the skill can re-install browsers on 26.04 later without hitting the error.
grep -q PLAYWRIGHT_HOST_PLATFORM_OVERRIDE /etc/environment 2>/dev/null \
  || echo 'PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64' >> /etc/environment
pip install --break-system-packages -q playwright \
  && echo "    python playwright package installed" \
  || echo "    [WARN] pip install playwright failed (webapp-testing skill will error on import)"
if python3 -m playwright install --with-deps chromium; then
  echo "    Playwright chromium + OS deps installed (ubuntu24.04-x64 build, running on 26.04)"
elif python3 -m playwright install chromium; then
  echo "    Playwright chromium installed (browser only; some OS deps may be missing)"
else
  echo "    [WARN] Playwright browser install failed."
  echo "    Ubuntu 26.04 isn't supported by Playwright yet (microsoft/playwright#40117)."
  echo "    Re-run this once support lands, or to retry the 24.04-build workaround:"
  echo "      PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64 python3 -m playwright install --with-deps chromium"
fi
unset PLAYWRIGHT_HOST_PLATFORM_OVERRIDE
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
Permission mode is "auto" (permissions.defaultMode). Actions are auto-approved
but pass through a background safety classifier that still blocks catastrophic
commands (rm -rf /, rm -rf ~). A deny floor in ~/.claude/settings.json applies in
every mode and blocks reading credentials/secrets (.env, *.pem, id_rsa,
.credentials.json) — do not try to work around it.

## Agent Teams
Agent teams are enabled. You can spawn parallel teammates for complex tasks:
- Use agent teams for work that benefits from parallel exploration
- Use subagents (Task tool) for quick focused work that reports back
- tmux is installed for split-pane team visualization

## Remote Control
Remote Control lets you steer a live local session from the Claude mobile app or
web. It is NOT enabled via settings.json — turn it on per session with `/rc`
(or `claude remote-control`), or for all sessions via `/config` →
"Enable Remote Control for all sessions". Requires a Pro/Max login (research
preview), so it only applies once someone signs in interactively.

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
- Thinking is adaptive — the model decides when to think; lean into it for complex work

## Installed Plugins / Skills
Plugins are staged via the `claude plugin` CLI at provision time and enabled via
the `enabledPlugins` block in ~/.claude/settings.json. Run `claude plugin list`
to confirm what's active.
- **frontend-design**: Production-grade UI with distinctive aesthetics (auto-activates on frontend tasks)
- **code-review**: Multi-agent PR review with confidence scoring
- **commit-commands**: Git commit, push, and PR workflows (/commit, /push, /pr)
- **security-guidance**: Security warnings when editing sensitive files
- **context7**: Live, version-specific library docs lookup (reduces API hallucinations)
- **typescript-lsp / pyright-lsp / gopls-lsp / rust-analyzer-lsp**: real-time
  diagnostics + navigation (backed by the language servers on PATH)
- **superpowers**: Development workflow framework — brainstorm → plan → implement with TDD
  - /superpowers:brainstorm — Refine ideas before coding
  - /superpowers:write-plan — Create implementation plans
  - /superpowers:execute-plan — Execute plans in batches via subagents
  - Auto-activating skills: test-driven-development, systematic-debugging, verification-before-completion
- **webapp-testing** (local skill, not a marketplace plugin): Playwright-based
  browser testing for UI verification and debugging
CLAUDEMD

echo ">>> Configuring SSH..."
sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
systemctl enable ssh
systemctl restart ssh

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
CCUI_BIN="$(command -v cloudcli || echo /usr/bin/cloudcli)"
mkdir -p /root/.cloudcli
echo "    CloudCLI UI installed: $("$CCUI_BIN" version 2>/dev/null || echo 'version unknown')"

# Browser feature runtime. CloudCLI detects Playwright via require('playwright')
# from its GLOBAL package dir, but its in-app "Install Runtime" button installs
# into the server's cwd (/project) — which require() can't resolve, so the button
# silently never takes effect. Fix: install Playwright GLOBALLY (resolvable) plus
# its Chromium using the ubuntu24.04-x64 fallback build (26.04 isn't officially
# supported by Playwright yet), so the Browser tab is ready with no button click.
echo ">>> Installing Playwright runtime for CloudCLI Browser feature..."
export PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64
npm install -g "${NPM_QUIET[@]}" playwright \
  || echo "    [WARN] global Playwright install failed (CloudCLI Browser feature won't work)"
playwright install chromium \
  || echo "    [WARN] Chromium download failed; retry later with: PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64 playwright install chromium"
unset PLAYWRIGHT_HOST_PLATFORM_OVERRIDE

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
# CloudCLI's "Install Runtime" (Playwright/Chromium for the Browser feature)
# hard-fails on Ubuntu 26.04, which Playwright doesn't officially support yet
# (microsoft/playwright#40117). Same override we use for the webapp-testing
# skill: force the ubuntu24.04-x64 fallback build, which runs on 26.04's glibc.
Environment=PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64
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
note  "claude logged in (creds on disk; run 'claude' /login if WARN)" "test -s /root/.claude/.credentials.json"
check "cloudcli service active"     "systemctl is-active --quiet cloudcli"
check "UI listening on :3001"       "ss -ltn | grep -q ':3001'"
check "docker daemon running"       "systemctl is-active --quiet docker"
check "disk under 90% on /"         "test $(df --output=pcent / | tail -1 | tr -dc 0-9) -lt 90"

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

echo ">>> [3/6] Claude Code..."
curl -fsSL https://claude.ai/install.sh | bash || echo "    [WARN] Claude Code update failed"

echo ">>> [4/6] CloudCLI UI (claudecodeui)..."
npm install -g --no-fund --no-audit --loglevel=error @cloudcli-ai/cloudcli@latest || echo "    [WARN] CloudCLI UI update failed"
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
  echo -e "  ${BOLD}Features:${NC}    Agent teams (experimental), adaptive thinking, 64k output tokens"
  echo -e "  ${BOLD}Remote Control:${NC} enable per-session with ${CYAN}/rc${NC} or all sessions via ${CYAN}/config${NC} (Pro/Max)"
  echo -e "  ${BOLD}Plugins:${NC}     frontend-design, code-review, commit-commands, security-guidance,"
  echo -e "               context7, superpowers, + LSP (typescript/pyright/gopls/rust-analyzer)"
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
