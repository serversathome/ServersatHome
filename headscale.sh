#!/bin/bash

# ============================================================
# Headscale Auto-Installer
# Deploys Headscale v0.28.0 with Headscale-UI and Traefik
# ============================================================

set -euo pipefail

# --- Version Pinning ---
HEADSCALE_VERSION="0.28.0"
HEADSCALE_UI_VERSION="2025.08.23"
TRAEFIK_VERSION="v3.6"

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root."
   exit 1
fi

# Check for Docker
if ! command -v docker &> /dev/null; then
    echo "Docker is not installed. Please install Docker first."
    exit 1
fi

# Prompt for configuration
read -p "Enter your full domain (e.g., headscale.example.com): " FULL_DOMAIN
read -p "Enter your email for Let's Encrypt certificates: " ACME_EMAIL
read -p "Enter your VPS public IPv4 address (for embedded DERP): " VPS_IPV4
read -p "Enter MagicDNS base domain (must differ from server domain, e.g., ts.example.com): " BASE_DOMAIN

# Validate inputs
if [[ -z "$FULL_DOMAIN" || -z "$ACME_EMAIL" || -z "$VPS_IPV4" || -z "$BASE_DOMAIN" ]]; then
    echo "All fields are required. Exiting."
    exit 1
fi

if [[ "$FULL_DOMAIN" == "$BASE_DOMAIN" ]]; then
    echo "Error: MagicDNS base_domain must be different from the server domain."
    exit 1
fi

echo ""
echo "Configuration Summary:"
echo "  Headscale version: $HEADSCALE_VERSION"
echo "  Domain:            $FULL_DOMAIN"
echo "  ACME Email:        $ACME_EMAIL"
echo "  VPS IPv4:          $VPS_IPV4"
echo "  MagicDNS Domain:   $BASE_DOMAIN"
echo ""
read -p "Proceed? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# Create the directory structure
mkdir -p headscale/config headscale/lib headscale/letsencrypt

# Create the docker-compose.yaml file
cat <<EOF > headscale/docker-compose.yaml
services:
  headscale:
    image: 'headscale/headscale:${HEADSCALE_VERSION}'
    container_name: 'headscale'
    restart: 'unless-stopped'
    command: 'serve'
    read_only: true
    tmpfs:
      - /var/run/headscale
    volumes:
      - './config:/etc/headscale:ro'
      - './lib:/var/lib/headscale'
      TZ: 'America/New_York'
    healthcheck:
      test: ["CMD", "headscale", "health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.headscale.rule=Host(\`${FULL_DOMAIN}\`)"
      - "traefik.http.routers.headscale.tls.certresolver=myresolver"
      - "traefik.http.routers.headscale.entrypoints=websecure"
      - "traefik.http.routers.headscale.tls=true"
      - "traefik.http.services.headscale.loadbalancer.server.port=8080"

  headscale-ui:
    image: 'ghcr.io/gurucomputing/headscale-ui:${HEADSCALE_UI_VERSION}'
    container_name: 'headscale-ui'
    restart: 'unless-stopped'
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.headscale-ui.loadbalancer.server.port=8080"
      - "traefik.http.routers.headscale-ui.rule=Host(\`${FULL_DOMAIN}\`) && PathPrefix(\`/web\`)"
      - "traefik.http.routers.headscale-ui.entrypoints=websecure"
      - "traefik.http.routers.headscale-ui.tls=true"
      - "traefik.http.routers.headscale-ui.tls.certresolver=myresolver"

  traefik:
    image: "traefik:${TRAEFIK_VERSION}"
    container_name: "traefik"
    restart: "unless-stopped"
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entryPoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entryPoints.websecure.address=:443"
      - "--certificatesresolvers.myresolver.acme.httpchallenge=true"
      - "--certificatesresolvers.myresolver.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.myresolver.acme.email=${ACME_EMAIL}"
      - "--certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
      - "3478:3478/udp"
    volumes:
      - "./letsencrypt:/letsencrypt"
      - "/var/run/docker.sock:/var/run/docker.sock:ro"

EOF

# Create the config.yaml file
cat <<EOF > headscale/config/config.yaml
---
server_url: https://${FULL_DOMAIN}
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: false

noise:
  private_key_path: /var/lib/headscale/noise_private.key

prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential

derp:
  server:
    enabled: true
    region_id: 999
    region_code: "headscale"
    region_name: "Headscale Embedded DERP"
    verify_clients: true
    stun_listen_addr: "0.0.0.0:3478"
    private_key_path: /var/lib/headscale/derp_server_private.key
    automatically_add_embedded_derp_region: true
    ipv4: ${VPS_IPV4}
  urls:
    - https://controlplane.tailscale.com/derpmap/default
  paths: []
  auto_update_enabled: true
  update_frequency: 3h

disable_check_updates: false
ephemeral_node_inactivity_timeout: 30m

database:
  type: sqlite
  debug: false
  gorm:
    prepare_stmt: true
    parameterized_queries: true
    skip_err_record_not_found: true
    slow_threshold: 1000
  sqlite:
    path: /var/lib/headscale/db.sqlite
    write_ahead_log: true
    wal_autocheckpoint: 1000

acme_url: https://acme-v02.api.letsencrypt.org/directory
acme_email: ""
tls_letsencrypt_hostname: ""
tls_letsencrypt_cache_dir: /var/lib/headscale/cache
tls_letsencrypt_challenge_type: HTTP-01
tls_letsencrypt_listen: ":http"
tls_cert_path: ""
tls_key_path: ""

log:
  format: text
  level: info

policy:
  mode: database
  path: ""

dns:
  magic_dns: true
  base_domain: ${BASE_DOMAIN}
  override_local_dns: true
  nameservers:
    global:
      - 1.1.1.1
      - 1.0.0.1
      - 2606:4700:4700::1111
      - 2606:4700:4700::1001
    split: {}
  search_domains: []
  extra_records: []

unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"

logtail:
  enabled: false

randomize_client_port: false

taildrop:
  enabled: true
EOF

echo "Deployment files created in 'headscale' directory."

# Start the Docker containers
echo "Starting Docker containers..."
if ! docker compose -f headscale/docker-compose.yaml up -d; then
    echo "Failed to start Docker containers. Exiting..."
    exit 1
fi

# Wait for headscale to be healthy
echo "Waiting for Headscale to become healthy..."
MAX_RETRIES=30
RETRY_COUNT=0
while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    HEALTH=$(docker inspect --format='{{.State.Health.Status}}' headscale 2>/dev/null || echo "unknown")
    if [[ "$HEALTH" == "healthy" ]]; then
        echo "Headscale is healthy."
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "  Waiting... ($RETRY_COUNT/$MAX_RETRIES) [status: $HEALTH]"
    sleep 5
done

if [[ "$HEALTH" != "healthy" ]]; then
    echo "Warning: Headscale did not report healthy in time. Attempting API key creation anyway..."
fi

# Create the API key and capture the output
API_KEY=$(docker exec headscale headscale apikeys create 2>&1)
if [ $? -ne 0 ]; then
    echo "Failed to create API Key. You can create one manually with:"
    echo "  docker exec headscale headscale apikeys create"
    exit 1
fi

echo ""
echo "============================================================"
echo "  Headscale Deployment Complete!"
echo "============================================================"
echo ""
echo "  API Key: $API_KEY"
echo ""
echo "  Admin UI: https://$FULL_DOMAIN/web"
echo ""
echo "  In the UI settings, enter:"
echo "    Headscale URL: https://$FULL_DOMAIN"
echo "    API Key:       (the key shown above)"
echo ""
echo "  To connect a client:"
echo "    tailscale up --login-server=https://$FULL_DOMAIN"
echo ""
echo "  Useful commands:"
echo "    docker exec headscale headscale users create <username>"
echo "    docker exec headscale headscale nodes list"
echo "    docker exec headscale headscale apikeys list"
echo "============================================================"
