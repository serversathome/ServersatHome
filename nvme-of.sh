#!/bin/bash
# ==========================================
# Proxmox NVMe-oF Auto Setup for TrueNAS
# Fully Automated and User-Friendly
# ==========================================
set -euo pipefail

# Color output for better UX
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_error() { echo -e "${RED}Error: $1${NC}" >&2; }
echo_success() { echo -e "${GREEN}✅ $1${NC}"; }
echo_info() { echo -e "${YELLOW}ℹ️  $1${NC}"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo_error "This script must be run as root"
   exit 1
fi

# Prompt for TrueNAS IP with validation
while true; do
    read -rp "Enter the IP of your TrueNAS NVMe-oF server: " TRUENAS_IP
    if [[ -z "$TRUENAS_IP" ]]; then
        echo_error "No IP entered."
        continue
    fi
    # Basic IP validation
    if [[ $TRUENAS_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        break
    else
        echo_error "Invalid IP format. Please try again."
    fi
done

apt install -y nvme-cli


# Discover NVMe-oF targets
echo_info "Discovering NVMe-oF targets on $TRUENAS_IP..."
if ! DISCOVERY=$(nvme discover -t tcp -a "$TRUENAS_IP" -s 4420 2>&1); then
    echo_error "Failed to discover targets. Check network connectivity and TrueNAS configuration."
    echo "$DISCOVERY"
    exit 1
fi

# Filter for real NVMe subsystems only (ignore discovery controller)
SUBSYSTEMS=$(echo "$DISCOVERY" | awk '
/subtype: *nvme/ {subnqn=""; traddr=""; next}
/subnqn:/ {subnqn=$2}
/traddr:/ {traddr=$2; if(subnqn !~ /discovery/ && subnqn!="" && traddr!="") print subnqn "|" traddr}
')

if [[ -z "$SUBSYSTEMS" ]]; then
    echo_error "No NVMe-oF subsystems found. Check IP/network."
    exit 1
fi

# Display menu
echo ""
echo "Available NVMe-oF targets:"
echo "=========================="
i=1
declare -A SUBS
while IFS="|" read -r nqn traddr; do
    SUBS[$i]="$nqn|$traddr"
    echo "[$i] NQN: $nqn"
    echo "    IP:  $traddr"
    echo ""
    ((i++))
done <<< "$SUBSYSTEMS"

# Prompt user to select target
while true; do
    read -rp "Select the target to use (enter number): " TARGET_INDEX
    if [[ "$TARGET_INDEX" =~ ^[0-9]+$ ]] && [[ -n "${SUBS[$TARGET_INDEX]:-}" ]]; then
        break
    else
        echo_error "Invalid selection. Please enter a number from 1 to $((i-1))."
    fi
done

SELECTED=${SUBS[$TARGET_INDEX]}
NQN=$(echo "$SELECTED" | cut -d'|' -f1)
TRADDR=$(echo "$SELECTED" | cut -d'|' -f2)
TRANSPORT="tcp"

echo ""
echo_info "Selected configuration:"
echo "  NQN: $NQN"
echo "  Target IP: $TRADDR"
echo "  Transport: $TRANSPORT"
echo ""

# Check if already connected
if nvme list 2>/dev/null | grep -q "$NQN"; then
    echo_info "Already connected to this target. Skipping connection..."
else
    # Connect to NVMe-oF target
    echo_info "Connecting to NVMe-oF target..."
    if ! nvme connect -t "$TRANSPORT" -a "$TRADDR" -s 4420 -n "$NQN"; then
        echo_error "Failed to connect to NVMe-oF target."
        exit 1
    fi
    sleep 2  # Give the system time to recognize the device
fi

# Detect NVMe device with retry logic
MAX_RETRIES=5
RETRY_COUNT=0
DEVICE=""

while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    DEVICE=$(nvme list 2>/dev/null | grep "$NQN" | awk '{print $1}' | head -n1)
    if [[ -n "$DEVICE" ]]; then
        break
    fi
    ((RETRY_COUNT++))
    echo_info "Waiting for device to appear (attempt $RETRY_COUNT/$MAX_RETRIES)..."
    sleep 2
done

if [[ -z "$DEVICE" ]]; then
    echo_error "Failed to detect NVMe device after connect."
    exit 1
fi

echo_success "Detected NVMe device: $DEVICE"

# Check if device already has a filesystem or is part of a pool
if blkid "$DEVICE" &>/dev/null; then
    echo_info "Device appears to have existing data:"
    blkid "$DEVICE"
    read -rp "Continue and create new ZFS pool? This will DESTROY existing data! (yes/no): " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        echo "Aborted by user."
        exit 0
    fi
fi

# Prompt for ZFS pool name with validation
while true; do
    read -rp "Enter a name for the new ZFS pool: " POOL_NAME
    if [[ -z "$POOL_NAME" ]]; then
        echo_error "No pool name entered."
        continue
    fi
    # Check if pool already exists
    if zpool list "$POOL_NAME" &>/dev/null; then
        echo_error "Pool '$POOL_NAME' already exists. Choose a different name."
        continue
    fi
    # Validate pool name (alphanumeric, dash, underscore)
    if [[ "$POOL_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        break
    else
        echo_error "Invalid pool name. Use only letters, numbers, dashes, and underscores."
    fi
done

# Create ZFS pool
echo_info "Creating ZFS pool '$POOL_NAME' on $DEVICE..."
if ! zpool create "$POOL_NAME" "$DEVICE"; then
    echo_error "Failed to create ZFS pool."
    exit 1
fi

echo_success "ZFS pool '$POOL_NAME' created successfully"

# ------------------------------------------
# Create systemd service for NVMe connect
# ------------------------------------------
NVME_SERVICE="/etc/systemd/system/nvme-connect@${POOL_NAME}.service"
cat <<EOF > "$NVME_SERVICE"
[Unit]
Description=Connect NVMe-oF volume from TrueNAS for pool %i
After=network-online.target
Wants=network-online.target
Before=zfs-import.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 10
ExecStart=/usr/sbin/nvme connect -t $TRANSPORT -a $TRADDR -s 4420 -n $NQN
ExecStop=/usr/sbin/nvme disconnect -n $NQN
RemainAfterExit=yes
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

# ------------------------------------------
# Create systemd service for ZFS import
# ------------------------------------------
ZPOOL_SERVICE="/etc/systemd/system/zpool-import@${POOL_NAME}.service"
cat <<EOF > "$ZPOOL_SERVICE"
[Unit]
Description=Import ZFS pool %i after NVMe connection
After=nvme-connect@%i.service zfs-import.target
Requires=nvme-connect@%i.service
Before=zfs-mount.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/sbin/zpool import -f %i
ExecStartPost=/bin/sleep 2
RemainAfterExit=yes
Restart=on-failure
RestartSec=30

[Install]
WantedBy=zfs-mount.service
EOF

# Reload systemd and enable services
echo_info "Enabling systemd services..."
systemctl daemon-reload
systemctl enable "nvme-connect@${POOL_NAME}.service"
systemctl enable "zpool-import@${POOL_NAME}.service"

# Test the services
echo_info "Testing service status..."
systemctl status "nvme-connect@${POOL_NAME}.service" --no-pager || true
systemctl status "zpool-import@${POOL_NAME}.service" --no-pager || true

echo ""
echo_success "NVMe-oF setup complete!"
echo_success "ZFS pool '$POOL_NAME' created and persistent systemd services enabled."
echo ""
echo_info "Pool is now accessible at: /$POOL_NAME"
echo_info "To verify: zpool status $POOL_NAME"
echo_info "Services will auto-start on reboot."
