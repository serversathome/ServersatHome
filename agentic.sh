#!/bin/bash
set -e

# 1️⃣ Update system and install core dependencies
apt update && apt upgrade -y
apt install -y \
  git curl wget unzip zip htop nano vim bash-completion \
  ca-certificates gnupg lsb-release apt-transport-https software-properties-common \
  python3 python3-pip python3-venv python3-dev build-essential \
  jq sqlite3 redis-tools postgresql-client \
  net-tools iproute2 iputils-ping dnsutils \
  ufw rsync tmux screen \
  openssh-client sshpass \
  neofetch ripgrep fd-find \
  make cmake pkg-config \
  libssl-dev libffi-dev libsqlite3-dev zlib1g-dev \
  nginx certbot \
  cron docker.io docker-compose

# 2️⃣ Install Docker via your custom script
wget https://raw.githubusercontent.com/imjustleaving/ServersatHome/refs/heads/main/install-docker.sh
chmod +x install-docker.sh
bash install-docker.sh

# 3️⃣ Install Node.js 20.x via NodeSource (includes npm)
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# 4️⃣ Setup /project structure
PROJECT_DIR="/project"
mkdir -p "$PROJECT_DIR"/{src,config,data,history}
chown -R $USER:$USER "$PROJECT_DIR"

# 5️⃣ Create context.md
cat > "$PROJECT_DIR/context.md" << 'EOF'
# 🧠 Agentic Coding Context
## Overview
You are an autonomous software development assistant working inside a reproducible containerized environment.  
Your goals are to design, implement, test, and document software projects efficiently and safely.  

You have full access to:
- A local filesystem (/project)
- A /project/history folder containing previous logs, notes, diffs, and prior work context
- Standard development tools: Git, Docker, Python, Node.js, Bash
- Internet access
  
## Mission
When a new project begins, you will:
1. Read and understand /project/context.md.
2. Read any notes or logs found in /project/history.
3. Establish an initial plan and outline (requirements, architecture, milestones).
4. Document everything you do in /project/history/YYYY-MM-DD-session.md.

## Behavior Rules
- Take initiative, summarize reasoning in Markdown before major changes.
- Use small, verifiable commits.
- Preserve context in /project/history.
- Favor reusable, container-friendly, platform-agnostic designs.
- Follow best practices: lint, format, test all generated code.

## Technical Preferences
- Use Markdown for documentation.
- Store configuration files in /project/config.
- Store source code in /project/src.
- Store data and results in /project/data.

## History and Memory
- Before each session, read all .md files in /project/history.
- Append a short summary after each session.
- Example summary:
  ## Session Summary (YYYY-MM-DD)
  - Added authentication endpoints.
  - Updated Dockerfile.
  - Next steps: write integration tests.

## Security
- Do not delete user data or expose secrets.
- Operate only within /project.

## Goal
Produce high-quality, production-ready software documented with an ongoing historical record.
EOF

# 6️⃣ Add weekly auto-update cron job
(crontab -l 2>/dev/null; echo "0 3 * * 0 apt update && apt upgrade -y && apt autoremove -y && apt clean -y") | crontab -

# 7️⃣ Setup /docker directory and docker-compose files
DOCKER_DIR="/docker"
mkdir -p "$DOCKER_DIR"
cd "$DOCKER_DIR"

# Watchtower docker-compose
cat > watchtower-compose.yml << 'EOF'
services:
  watchtower:
    image: nickfedor/watchtower
    container_name: watchtower
    environment:
      - TZ=America/New_York
      - WATCHTOWER_NOTIFICATIONS_HOSTNAME=
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_INCLUDE_STOPPED=true
      - WATCHTOWER_SCHEDULE=0 0 3 * * *
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
EOF

# Code-Server docker-compose
cat > code-server-compose.yml << 'EOF'
services:
  code-server:
    image: lscr.io/linuxserver/code-server:latest
    container_name: code-server
    environment:
      - PUID=0
      - PGID=0
      - TZ=America/New_York
      - PASSWORD=admin
    volumes:
      - ./config:/config
      - /:/config/workspace
    ports:
      - 8443:8443
    restart: unless-stopped
EOF

# NextExplorer docker-compose
cat > nextexplorer-compose.yml << 'EOF'
services:
  nextexplorer:
    image: nxzai/explorer:latest
    container_name: nextexplorer
    restart: unless-stopped
    ports:
      - 3000:3000
    environment:
      - NODE_ENV=production
      - PUID=0
      - PGID=0
    volumes:
      - ./config:/config
      - ./cache:/cache
      - /:/mnt/root
EOF

# 8️⃣ Start all containers
docker compose -f watchtower-compose.yml up -d
docker compose -f code-server-compose.yml up -d
docker compose -f nextexplorer-compose.yml up -d

echo "✅ Setup complete! Your LXC is ready with agentic coding environment and Docker containers."
echo "To install the AI CLIs:

Gemini CLI:
npm install -g @google/gemini-cli

Claude CLI:
npm install -g @anthropic-ai/claude-code

Then start a session with either:

# For Gemini:
cd /project
gemini start --context ./context.md --memory ./history --watch ./src

# For Claude:
cd /project
claude start --context ./context.md --memory ./history --watch ./src
"
