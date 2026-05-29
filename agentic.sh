#!/usr/bin/env bash
# ============================================================================
#  Claude Code LXC Deployer for Proxmox
#  Creates a fully provisioned Ubuntu 26.04 LXC container ready for Claude Code
#
#  Run on your Proxmox host:
#    curl -fsSL https://raw.githubusercontent.com/serversathome-personal/code/main/agentic.sh -o /tmp/agentic.sh && bash /tmp/agentic.sh
#
#  GitHub: https://github.com/serversathome-personal/code
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
  echo -e "${BOLD}║        Claude Code LXC Deployer (Proxmox)       ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Pre-flight checks ──────────────────────────────────────────────────────
preflight() {
  [[ $(id -u) -eq 0 ]] || error "This script must be run as root on the Proxmox host."
  command -v pct &>/dev/null || error "pct not found. Are you running this on a Proxmox host?"
  command -v pveam &>/dev/null || error "pveam not found. Are you running this on a Proxmox host?"
}

# ── Configuration ───────────────────────────────────────────────────────────
get_config() {
  # Find next available CT ID
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")

  # Template
  TEMPLATE="ubuntu-26.04-standard_26.04-1_amd64.tar.zst"

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
  echo "  CT ID:      $CT_ID"
  echo "  Hostname:   $CT_HOSTNAME"
  echo "  Template:   $TEMPLATE"
  echo "  CPU:        $CT_CORES cores"
  echo "  RAM:        $CT_RAM MB ($(( CT_RAM / 1024 )) GB)"
  echo "  Swap:       $CT_SWAP MB"
  echo "  Disk:       ${CT_DISK}G on $CT_STORAGE"
  echo "  Network:    $CT_IP"
  echo "  DNS:        $CT_DNS"
  echo "─────────────────────────────────────────────────"
  echo ""
  read -rp "Proceed? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

# ── Download Ubuntu 24.04 Template ─────────────────────────────────────────
get_template() {
  info "Checking for template: $TEMPLATE"

  # Download if not already present
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

  # Wait for network connectivity
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

# Normalize HOME in case the provisioner is ever run via sudo without -i/-H.
# Everything below assumes root's home; pct exec is already clean, but this
# keeps rustup / Claude Code / git config landing in /root no matter what.
ROOT_HOME="$(getent passwd 0 | cut -d: -f6)"; ROOT_HOME="${ROOT_HOME:-/root}"
[[ "${HOME:-}" != "$ROOT_HOME" ]] && export HOME="$ROOT_HOME"

# Resilient apt installer: try the batch, then fall back to one-by-one so a
# single renamed/dropped package on a brand-new base image (26.04) can't abort
# the whole run under `set -e`.
apt_install() {
  if ! apt-get install -y -qq "$@" >/dev/null 2>&1; then
    echo "    [warn] batch install failed; retrying individually..."
    local p
    for p in "$@"; do
      apt-get install -y -qq "$p" >/dev/null 2>&1 || echo "    [warn] skipped (unavailable): $p"
    done
  fi
}

echo ">>> Setting timezone to America/New_York..."
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
echo "America/New_York" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

echo ">>> Generating locale..."
apt-get update -qq
apt_install locales
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
locale-gen en_US.UTF-8 > /dev/null 2>&1
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

echo ">>> Updating system..."
apt-get upgrade -y -qq

echo ">>> Installing core packages..."
apt_install \
  git curl wget unzip zip \
  ca-certificates gnupg lsb-release apt-transport-https software-properties-common \
  bash-completion locales \
  htop nano vim tmux screen \
  jq yq tree \
  net-tools iproute2 iputils-ping bind9-dnsutils \
  openssh-server \
  cron logrotate

echo ">>> Installing build tools & dev libraries..."
apt_install \
  build-essential make cmake pkg-config autoconf automake libtool \
  python3 python3-pip python3-venv python3-dev \
  libssl-dev libffi-dev libsqlite3-dev zlib1g-dev \
  libreadline-dev libbz2-dev libncurses-dev liblzma-dev libxml2-dev libxslt1-dev

echo ">>> Installing search & productivity tools..."
apt_install \
  ripgrep fd-find fzf bat \
  rsync \
  sqlite3

echo ">>> Installing database clients..."
apt_install \
  postgresql-client redis-tools

echo ">>> Installing Node.js 22.x LTS..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs
echo "    Node.js $(node --version) / npm $(npm --version)"

echo ">>> Installing global npm packages..."
npm install -g typescript ts-node eslint prettier

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
echo "    Claude Code installed"

echo ">>> Configuring Claude Code permissions + plugins..."
mkdir -p /root/.claude

# NOTE: claude-plugins-official is built into every Claude Code install, so its
# plugins (frontend-design, code-review, commit-commands, security-guidance,
# context7) need no marketplace declaration. Only third-party marketplaces like
# superpowers must be declared in extraKnownMarketplaces. Plugins in enabledPlugins
# install from their marketplaces on first launch — no npx/CLI step needed.
cat > /root/.claude/settings.json << 'SETTINGS'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "allow": [
      "Bash(*)",
      "Read(*)",
      "Write(*)",
      "Edit(*)",
      "MultiEdit(*)",
      "WebFetch(*)",
      "WebSearch(*)",
      "TodoRead(*)",
      "TodoWrite(*)",
      "Grep(*)",
      "Glob(*)",
      "LS(*)",
      "Task(*)",
      "mcp__*"
    ]
  },
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000",
    "MAX_THINKING_TOKENS": "31999"
  },
  "alwaysThinkingEnabled": true,
  "extraKnownMarketplaces": {
    "superpowers-marketplace": {
      "source": { "source": "github", "repo": "obra/superpowers-marketplace" }
    }
  },
  "enabledPlugins": {
    "frontend-design@claude-plugins-official": true,
    "code-review@claude-plugins-official": true,
    "commit-commands@claude-plugins-official": true,
    "security-guidance@claude-plugins-official": true,
    "context7@claude-plugins-official": true,
    "superpowers@superpowers-marketplace": true
  }
}
SETTINGS

echo ">>> Enabling Claude Code Remote Control auto-start..."
# The CLI auto-starts a phone/browser-controllable session when
# remoteControlAtStartup=true in ~/.claude.json (connect from claude.ai/code or
# the Claude mobile app). settings.json has no documented key for this; the
# in-app equivalent is the /config toggle. Requires a Pro/Max login
# (run: claude /login) — API keys are NOT supported for Remote Control.
if command -v jq >/dev/null 2>&1; then
  if [[ -f /root/.claude.json ]]; then
    tmp=$(mktemp); jq '.remoteControlAtStartup = true' /root/.claude.json > "$tmp" && mv "$tmp" /root/.claude.json
  else
    echo '{ "remoteControlAtStartup": true }' > /root/.claude.json
  fi
else
  echo "    [warn] jq missing; skipping remote-control auto-start (enable later via /config)."
fi

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
- **Languages**: Node.js 22 LTS, Python 3 (system default), Go (latest), Rust (latest)
- **Package managers**: npm, pip (use --break-system-packages), cargo, go install
- **Docker**: Docker Engine + Compose plugin, running and ready
- **Containers**: Watchtower (auto-updates), Code Server (port 8443)
- **Search tools**: ripgrep (rg), fd-find (fdfind), fzf
- **Databases**: PostgreSQL client (psql), Redis client (redis-cli), SQLite3

## Permissions
All tools are pre-approved — no permission prompts. Bash, Read, Write, Edit, WebFetch, WebSearch, Task, and MCP tools all run without confirmation.

## Subagents & Agent Teams
- **Subagents** (Task tool): quick, focused workers that report back. Define reusable ones as
  Markdown files in ~/.claude/agents/ (see /agents).
- **Agent teams** are ENABLED (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1). Use these when teammates
  need to share findings and coordinate, not just report back — e.g. "create a team to refactor X
  with one teammate per layer." Each teammate is a full Claude Code instance with a shared task
  list and messaging. They use significantly more tokens than a single session, so reserve them
  for genuinely parallel, independent work. tmux is installed for split-pane visualization.

## Remote Control
Auto-start is configured (remoteControlAtStartup in ~/.claude.json) so each session is controllable
from claude.ai/code or the Claude mobile app — execution stays local in this container. Requires a
Pro/Max login (run `claude` then /login); API keys are not supported. Toggle per-session with
/remote-control, or adjust the default via /config.

## Docker Usage
Docker compose files should go in /docker/<service-name>/docker-compose.yml. 
Watchtower is already running and will auto-update any containers with `restart: unless-stopped`.
All Docker containers in this LXC need `security_opt: [apparmor=unconfined]`.

## Conventions
- Prefer creating files over printing long code blocks
- Use git for version control on all projects in /project/src/
- When installing Python packages, use: pip install --break-system-packages <package>
- Extended thinking is always on — use it for complex architectural decisions

## Installed Plugins
Declared in ~/.claude/settings.json and installed from their marketplaces on first launch.
Run /plugin to confirm they're active or add more.
- **frontend-design** (claude-plugins-official): production-grade UI aesthetics
- **code-review** (claude-plugins-official): multi-agent PR review with confidence scoring
- **commit-commands** (claude-plugins-official): git commit/push/PR workflows (/commit, /push, /pr)
- **security-guidance** (claude-plugins-official): warnings when editing sensitive files
- **context7** (claude-plugins-official): live, version-specific library docs (reduces API hallucinations)
- **superpowers** (superpowers-marketplace): brainstorm → plan → implement (TDD) workflow
  - /superpowers:brainstorm, /superpowers:write-plan, /superpowers:execute-plan
  - Auto-activating skills: test-driven-development, systematic-debugging, verification-before-completion

## Installed Skills
- **webapp-testing** (~/.claude/skills/): Playwright-based browser testing for UI verification
CLAUDEMD

echo ">>> Installing webapp-testing skill (from anthropics/skills)..."
git clone --depth 1 --filter=blob:none --sparse https://github.com/anthropics/skills.git /tmp/anthropic-skills
cd /tmp/anthropic-skills && git sparse-checkout set skills/webapp-testing
mkdir -p /root/.claude/skills/
cp -r /tmp/anthropic-skills/skills/webapp-testing /root/.claude/skills/webapp-testing
rm -rf /tmp/anthropic-skills
cd /root

echo ">>> Installing Playwright for webapp-testing skill..."
npx -y playwright install --with-deps chromium

echo ">>> Configuring SSH..."
sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
systemctl enable ssh
systemctl restart ssh

echo ">>> Setting up shell environment..."
if ! grep -q "Claude Code Container" /root/.bashrc 2>/dev/null; then
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
fi

echo ">>> Setting up Git defaults..."
git config --global init.defaultBranch main
git config --global core.editor nano
git config --global pull.rebase false

echo ">>> Setting up Docker services..."
mkdir -p /docker/watchtower
cat > /docker/watchtower/docker-compose.yml << 'DCOMPOSE'
services:
  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    environment:
      TZ: America/New_York
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_INCLUDE_STOPPED: "true"
      WATCHTOWER_SCHEDULE: "0 0 4 * * *"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    security_opt:
      - apparmor=unconfined
DCOMPOSE

mkdir -p /docker/code-server
cat > /docker/code-server/docker-compose.yml << 'DCOMPOSE2'
services:
  code-server:
    image: lscr.io/linuxserver/code-server:latest
    container_name: code-server
    restart: unless-stopped
    environment:
      PUID: "0"
      PGID: "0"
      TZ: America/New_York
      PASSWORD: admin
    volumes:
      - ./config:/config
      - /:/config/workspace
    ports:
      - 8443:8443
    security_opt:
      - apparmor=unconfined
DCOMPOSE2

cd /docker/watchtower && docker compose up -d
cd /docker/code-server && docker compose up -d

echo ">>> Setting up auto-update cron..."
cat > /etc/cron.d/system-update << 'CRON'
# Weekly system update - Sunday 3:00 AM ET
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * 0 root apt-get update -qq && apt-get upgrade -y -qq && apt-get autoremove -y -qq && apt-get clean -qq >> /var/log/auto-update.log 2>&1
CRON
chmod 0644 /etc/cron.d/system-update

cat > /etc/logrotate.d/auto-update << 'LOGROTATE'
/var/log/auto-update.log {
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
echo "║          Provisioning Complete!                  ║"
echo "╚══════════════════════════════════════════════════╝"
PROVISION_EOF

  chmod +x /tmp/provision-${CT_ID}.sh
  pct push "$CT_ID" /tmp/provision-${CT_ID}.sh /tmp/provision.sh
  pct exec "$CT_ID" -- chmod +x /tmp/provision.sh
  pct exec "$CT_ID" -- /tmp/provision.sh
  rm -f /tmp/provision-${CT_ID}.sh
}

# ── Print Summary ─────────────────────────────────────────────────────────
print_summary() {
  # Get container IP
  local ct_ip
  ct_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')

  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║       Claude Code LXC Ready!                    ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Container:${NC}  $CT_ID ($CT_HOSTNAME)"
  echo -e "  ${BOLD}IP:${NC}         ${ct_ip:-pending (DHCP)}"
  echo -e "  ${BOLD}Resources:${NC}  ${CT_CORES} CPU / $(( CT_RAM / 1024 )) GB RAM / ${CT_DISK} GB disk"
  echo -e "  ${BOLD}Storage:${NC}    $CT_STORAGE"
  echo -e "  ${BOLD}Timezone:${NC}   America/New_York"
  echo ""
  echo -e "  ${BOLD}Connect:${NC}"
  echo -e "    Console:  ${CYAN}pct enter $CT_ID${NC}"
  [[ -n "${ct_ip:-}" ]] && echo -e "    SSH:      ${CYAN}ssh root@${ct_ip}${NC}"
  [[ -n "${ct_ip:-}" ]] && echo -e "    Code:     ${CYAN}http://${ct_ip}:8443${NC}  (password: admin)"
  echo ""
  echo -e "  ${BOLD}Start Claude Code:${NC}"
  echo -e "    ${CYAN}claude${NC}    (shell auto-cd's to /project on login)"
  echo ""
  echo -e "  ${BOLD}Installed:${NC}"
  echo "    • Claude Code (native)    • Node.js 22 LTS"
  echo "    • Python 3 + pip + venv   • Go (latest)"
  echo "    • Rust (via rustup)       • Docker + Compose"
  echo "    • Git, ripgrep, fzf, fd   • Build essentials"
  echo "    • PostgreSQL & Redis CLI  • Watchtower (auto-update containers)"
  echo "    • Code Server (port 8443)"
  echo ""
  echo -e "  ${BOLD}Permissions:${NC}  All tools pre-approved (no prompts)"
  echo -e "  ${BOLD}Config:${NC}      ~/.claude/settings.json"
  echo -e "  ${BOLD}Features:${NC}    Agent teams, extended thinking, 64k output, remote control, auto-approved tools"
  echo -e "  ${BOLD}Plugins:${NC}     frontend-design, code-review, commit-commands, security-guidance,"
  echo -e "               context7, superpowers  (run /plugin to verify)"
  echo -e "  ${BOLD}Skills:${NC}      webapp-testing"
  echo -e "  ${BOLD}Remote Control:${NC} auto-start on (claude.ai/code or mobile app) — needs Pro/Max /login"
  echo -e "  ${BOLD}Auto-updates:${NC} Sundays 3 AM ET (system) / Daily 4 AM ET (Docker)"
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
  print_summary
}

main "$@"
