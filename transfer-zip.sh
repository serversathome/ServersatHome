#!/bin/bash
# ============================================================================
#  Transfer.zip Automated Deployment Script
#  For Servers@Home / TrueNAS users
#  https://wiki.serversatho.me
# ============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_banner() {
    echo -e "${CYAN}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║        Transfer.zip Deployment Script            ║"
    echo "  ║        Servers@Home Community                     ║"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_step() {
    echo -e "\n${GREEN}[✓]${NC} ${BOLD}$1${NC}"
}

log_info() {
    echo -e "    ${CYAN}→${NC} $1"
}

log_warn() {
    echo -e "    ${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "\n${RED}[✗]${NC} ${BOLD}$1${NC}"
}

# ============================================================================
#  Preflight checks
# ============================================================================

print_banner

# Check we're in a suitable directory
STACKS_DIR="$(pwd)"
echo -e "${BOLD}Current directory:${NC} $STACKS_DIR"
echo ""

# Check for required tools
for cmd in git docker openssl sed; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "$cmd is required but not installed. Aborting."
        exit 1
    fi
done

# Check docker compose (v2)
if ! docker compose version &>/dev/null; then
    log_error "Docker Compose V2 is required. Please update Docker."
    exit 1
fi

# ============================================================================
#  Detect host private IPv4
# ============================================================================

log_step "Detecting host private IPv4 address..."

# Try multiple methods to find the private IP
HOST_IP=""

# Method 1: ip route (most reliable on Linux)
if command -v ip &>/dev/null; then
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' || true)
fi

# Method 2: hostname -I
if [ -z "$HOST_IP" ] && command -v hostname &>/dev/null; then
    HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
fi

# Method 3: ifconfig fallback
if [ -z "$HOST_IP" ] && command -v ifconfig &>/dev/null; then
    HOST_IP=$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | \
              grep -v '127.0.0.1' | head -1 | grep -Eo '([0-9]*\.){3}[0-9]*' || true)
fi

if [ -z "$HOST_IP" ]; then
    log_error "Could not auto-detect host IP."
    read -rp "    Enter your TrueNAS host private IPv4 address: " HOST_IP
fi

# Validate IP format
if ! echo "$HOST_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    log_error "Invalid IP address: $HOST_IP"
    exit 1
fi

log_info "Detected host IP: ${BOLD}$HOST_IP${NC}"

# ============================================================================
#  Prompt for domain / SITE_URL
# ============================================================================

echo ""
echo -e "${BOLD}How will users access Transfer.zip?${NC}"
echo ""
echo "  If you're using a reverse proxy or Cloudflare Tunnel with a domain:"
echo "    Enter your domain (e.g., transfer.example.com)"
echo ""
echo "  If you just want to access it by IP on your LAN:"
echo "    Press Enter to use http://${HOST_IP}:9001"
echo ""
read -rp "  Domain or Enter for LAN-only [${HOST_IP}:9001]: " USER_DOMAIN

if [ -z "$USER_DOMAIN" ]; then
    SITE_URL="http://${HOST_IP}:9001"
    COOKIE_DOMAIN="${HOST_IP}"
    log_info "SITE_URL set to: ${BOLD}${SITE_URL}${NC}"
else
    # Strip protocol if user included it
    USER_DOMAIN=$(echo "$USER_DOMAIN" | sed 's|^https\?://||' | sed 's|/$||')
    SITE_URL="https://${USER_DOMAIN}"
    COOKIE_DOMAIN="${USER_DOMAIN}"
    log_info "SITE_URL set to: ${BOLD}${SITE_URL}${NC}"
fi

# ============================================================================
#  Clone the repository
# ============================================================================

REPO_DIR="${STACKS_DIR}/transfer-zip-web"

if [ -d "$REPO_DIR" ]; then
    log_warn "Directory ${REPO_DIR} already exists."
    read -rp "    Delete and re-clone? (y/N): " RECLONE
    if [[ "$RECLONE" =~ ^[Yy]$ ]]; then
        rm -rf "$REPO_DIR"
    else
        log_error "Aborting. Remove or rename the existing directory first."
        exit 1
    fi
fi

log_step "Cloning transfer.zip-web repository..."
git clone https://github.com/robinkarlberg/transfer.zip-web.git "$REPO_DIR"
cd "$REPO_DIR"
log_info "Cloned to: $REPO_DIR"

# ============================================================================
#  Run createenv.sh (creates .env + next/.env with random Mongo password)
# ============================================================================

log_step "Running createenv.sh to generate environment files..."
chmod +x createenv.sh
./createenv.sh
log_info "Environment files created with random MongoDB password"

# ============================================================================
#  Copy conf.json example
# ============================================================================

log_step "Copying next/conf.json.example → next/conf.json..."
cp next/conf.json.example next/conf.json
log_info "Frontend configuration file ready"

# ============================================================================
#  Fix Dockerfile permissions bug
# ============================================================================

log_step "Patching next/Dockerfile (fixing public dir ownership)..."
sed -i 's|COPY --from=builder /app/public ./public|COPY --from=builder --chown=nextjs:nodejs /app/public ./public|' next/Dockerfile
log_info "Fixed EACCES permission issue for /app/public"

# ============================================================================
#  Generate JWT key pair
# ============================================================================

log_step "Generating JWT key pair for API ↔ worker authentication..."
openssl genrsa -out private.pem 2048 2>/dev/null
openssl rsa -in private.pem -pubout -out public.pem 2>/dev/null
chmod 600 private.pem
chmod 644 public.pem
log_info "Generated private.pem and public.pem"

# ============================================================================
#  Update docker-compose.yml — replace 127.0.0.1 with host IP
# ============================================================================

log_step "Updating docker-compose.yml — binding ports to ${HOST_IP}..."
sed -i "s|127.0.0.1:|${HOST_IP}:|g" docker-compose.yml
log_info "All service ports now bind to ${HOST_IP}"

# ============================================================================
#  Update next/.env — SITE_URL and COOKIE_DOMAIN
# ============================================================================

log_step "Updating next/.env with SITE_URL and COOKIE_DOMAIN..."

# Replace SITE_URL line (handles both http://localhost:9001 and any other default)
if grep -q '^SITE_URL=' next/.env; then
    sed -i "s|^SITE_URL=.*|SITE_URL=${SITE_URL}|" next/.env
else
    echo "SITE_URL=${SITE_URL}" >> next/.env
fi

# Replace COOKIE_DOMAIN line
if grep -q '^COOKIE_DOMAIN=' next/.env; then
    sed -i "s|^COOKIE_DOMAIN=.*|COOKIE_DOMAIN=${COOKIE_DOMAIN}|" next/.env
else
    echo "COOKIE_DOMAIN=${COOKIE_DOMAIN}" >> next/.env
fi

log_info "SITE_URL=${SITE_URL}"
log_info "COOKIE_DOMAIN=${COOKIE_DOMAIN}"

# ============================================================================
#  Patch secure cookie flag for HTTP/LAN-only access
# ============================================================================

if [ -z "$USER_DOMAIN" ]; then
    log_step "Patching cookie for HTTP access (LAN-only mode)..."
    sed -i 's|secure: !IS_DEV,|secure: false,|' next/src/lib/server/serverUtils.js
    log_info "Disabled Secure cookie flag (required for HTTP without HTTPS)"
    log_info "If you add a domain with HTTPS later, revert this and rebuild"
fi

# ============================================================================
#  Increase storage quota to 1PB (effectively unlimited)
# ============================================================================

log_step "Increasing storage quota to 1 PB..."
sed -i 's|10e12   // 10TB for good measure|10e15   // 1PB for self-host|' next/src/lib/server/mongoose/models/User.js
log_info "Storage quota set to 1 PB (effectively unlimited)"

# ============================================================================
#  Deploy with Docker Compose
# ============================================================================

log_step "Building and deploying containers (this may take a few minutes)..."
docker compose up -d --build
log_info "All four services starting: mongo, next, signaling-server, worker"

# ============================================================================
#  Copy public.pem into worker volume
# ============================================================================

log_step "Copying public.pem into worker data volume..."

# Wait briefly for volumes to be created
sleep 3

WORKER_VOL=$(docker volume inspect transfer-zip-web_worker_data --format '{{ .Mountpoint }}' 2>/dev/null || true)

if [ -n "$WORKER_VOL" ] && [ -d "$WORKER_VOL" ]; then
    cp public.pem "$WORKER_VOL/public.pem"
    chmod 644 "$WORKER_VOL/public.pem"
    log_info "Public key copied to worker volume"
else
    log_warn "Could not find worker volume mountpoint automatically."
    log_warn "Trying docker cp fallback..."
    WORKER_CONTAINER=$(docker compose ps -q worker 2>/dev/null || true)
    if [ -n "$WORKER_CONTAINER" ]; then
        docker cp public.pem "${WORKER_CONTAINER}:/worker_data/public.pem"
        log_info "Public key copied via docker cp"
    else
        log_error "Could not copy public.pem to worker. You may need to do this manually:"
        echo "    docker cp public.pem <worker-container>:/worker_data/public.pem"
    fi
fi

# ============================================================================
#  Restart worker to pick up the key
# ============================================================================

log_step "Restarting worker service..."
docker compose restart worker
sleep 2

# ============================================================================
#  Verify services are running
# ============================================================================

log_step "Checking service status..."
echo ""

SERVICES=("mongo" "next" "signaling-server" "worker")
ALL_HEALTHY=true

for svc in "${SERVICES[@]}"; do
    STATUS=$(docker compose ps --format '{{.State}}' "$svc" 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "running" ]; then
        echo -e "    ${GREEN}●${NC} ${svc}: running"
    else
        echo -e "    ${RED}●${NC} ${svc}: ${STATUS}"
        ALL_HEALTHY=false
    fi
done

# ============================================================================
#  Create user account
# ============================================================================

echo ""
read -rp "$(echo -e "${BOLD}Would you like to create a user account now? (Y/n):${NC} ")" CREATE_ACCT
CREATE_ACCT=${CREATE_ACCT:-Y}

if [[ "$CREATE_ACCT" =~ ^[Yy]$ ]]; then
    read -rp "    Email: " ACCT_EMAIL
    read -srp "    Password: " ACCT_PASS
    echo ""

    if [ -n "$ACCT_EMAIL" ] && [ -n "$ACCT_PASS" ]; then
        REGISTER_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
            "http://${HOST_IP}:9001/api/auth/register" \
            -H "Content-Type: application/json" \
            -d "{\"email\":\"${ACCT_EMAIL}\",\"password\":\"${ACCT_PASS}\"}")

        if [ "$REGISTER_RESP" = "200" ] || [ "$REGISTER_RESP" = "201" ]; then
            log_info "Account created for ${ACCT_EMAIL}"
        else
            log_warn "Account creation returned HTTP ${REGISTER_RESP}"
            log_warn "You can retry manually:"
            echo "    curl -X POST http://${HOST_IP}:9001/api/auth/register -H 'Content-Type: application/json' -d '{\"email\":\"${ACCT_EMAIL}\",\"password\":\"yourpassword\"}'"
        fi
    else
        log_warn "Email or password was empty — skipping account creation"
    fi
fi

# ============================================================================
#  Summary
# ============================================================================

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"

if [ "$ALL_HEALTHY" = true ]; then
    echo -e "${GREEN}${BOLD}  ✓ Transfer.zip deployed successfully!${NC}"
else
    echo -e "${YELLOW}${BOLD}  ⚠ Some services may still be starting. Check logs:${NC}"
    echo -e "    docker compose logs -f"
fi

echo ""
echo -e "  ${BOLD}Web UI:${NC}            http://${HOST_IP}:9001"
echo -e "  ${BOLD}Signaling Server:${NC}  http://${HOST_IP}:9002"
echo -e "  ${BOLD}SITE_URL:${NC}          ${SITE_URL}"
echo -e "  ${BOLD}Stack directory:${NC}   ${REPO_DIR}"
echo ""

if [ -n "$USER_DOMAIN" ]; then
    echo -e "  ${BOLD}Next steps:${NC}"
    echo -e "    1. Configure your reverse proxy / Cloudflare Tunnel"
    echo -e "       Route ${BOLD}/ws${NC} → http://${HOST_IP}:9002  (must be first!)"
    echo -e "       Route ${BOLD}/${NC}   → http://${HOST_IP}:9001  (catch-all)"
    echo -e "    2. Test at ${SITE_URL}"
else
    echo -e "  ${BOLD}Access Transfer.zip at:${NC} http://${HOST_IP}:9001"
fi

echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "    cd ${REPO_DIR}"
echo -e "    docker compose logs -f          # follow all logs"
echo -e "    docker compose restart           # restart all services"
echo -e "    docker compose down              # stop everything"
echo -e "    git pull && docker compose up -d --build  # update"
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
