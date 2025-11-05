#!/bin/bash
# ==========================================
# Proxmox NVMe-oF Auto Setup for TrueNAS
# Fully Automated and User-Friendly
# ==========================================

# Don't exit on error - we'll handle errors manually
set -uo pipefail

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

# Install nvme-cli if not present
if ! command -v nvme &> /dev/null; then
    echo_info "Installing nvme-cli..."
    apt update && apt install -y nvme-cli
else
    echo_info "nvme-cli already installed"
fi

# Discover NVMe-oF targets
echo_info "Discovering NVMe-oF targets on $TRUENAS_IP..."
DISCOVERY=$(nvme discover -t tcp -a "$TRUENAS_IP" -s 4420 2>&1)
if [[ $? -ne 0 ]]; then
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
ALREADY_CONNECTED=false
if nvme list 2>/dev/null | grep -q "$NQN"; then
    echo_info "Already connected to this target."
    ALREADY_CONNECTED=true
else
    # Connect to NVMe-oF target
    echo_info "Connecting to NVMe-oF target..."
    CONNECT_OUTPUT=$(nvme connect -t "$TRANSPORT" -a "$TRADDR" -s 4420 -n "$NQN" 2>&1)
    CONNECT_STATUS=$?
    
    echo "$CONNECT_OUTPUT"
    
    if [[ $CONNECT_STATUS -eq 0 ]] || echo "$CONNECT_OUTPUT" | grep -qi "already connected\|connecting to device"; then
        echo_info "Connection successful or already established."
        sleep 3  # Give the system time to recognize the device
    else
        echo_error "Failed to connect to NVMe-oF target."
        exit 1
    fi
fi

# Detect NVMe device with retry logic
MAX_RETRIES=15
RETRY_COUNT=0
DEVICE=""

echo_info "Detecting NVMe device..."
while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    # Try to find the device
    DEVICE=$(nvme list 2>/dev/null | grep "$NQN" | awk '{print $1}' | head -n1)
    
    if [[ -n "$DEVICE" ]]; then
        echo_success "Found device: $DEVICE"
        break
    fi
    
    ((RETRY_COUNT++))
    echo_info "Waiting for device to appear (attempt $RETRY_COUNT/$MAX_RETRIES)..."
    sleep 2
done

if [[ -z "$DEVICE" ]]; then
    echo_error "Failed to detect NVMe device after $MAX_RETRIES attempts."
    echo ""
    echo "Debug information:"
    echo "==================="
    echo "All NVMe devices:"
    nvme list
    echo ""
    echo "NVMe subsystems:"
    ls -la /sys/class/nvme/ 2>/dev/null || echo "No nvme subsystems found"
    echo ""
    echo "Block devices:"
    lsblk | grep nvme || echo "No nvme block devices found"
    exit 1
fi

echo_success "Device ready: $DEVICE"

# Check if we can import an existing pool from this device
echo_info "Checking for existing ZFS pools on device..."
IMPORTABLE_POOLS=$(zpool import 2>/dev/null | grep "pool:" | awk '{print $2}')

if [[ -n "$IMPORTABLE_POOLS" ]]; then
    echo_info "Found importable pool(s):"
    zpool import
    echo ""
    read -rp "Do you want to import an existing pool? (yes/no): " IMPORT_EXISTING
    
    if [[ "$IMPORT_EXISTING" == "yes" ]]; then
        read -rp "Enter the pool name to import: " POOL_NAME
        echo_info "Importing pool '$POOL_NAME'..."
        zpool import -f "$POOL_NAME"
        
        if [[ $? -eq 0 ]]; then
            echo_success "Pool '$POOL_NAME' imported successfully"
            CREATE_NEW_POOL=false
        else
            echo_error "Failed to import pool. Will create new pool instead."
            CREATE_NEW_POOL=true
        fi
    else
        CREATE_NEW_POOL=true
    fi
else
    echo_info "No existing pools found on device."
    CREATE_NEW_POOL=true
fi

if [[ "${CREATE_NEW_POOL:-true}" == "true" ]]; then
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
    zpool create "$POOL_NAME" "$DEVICE"
    
    if [[ $? -eq 0 ]]; then
        echo_success "ZFS pool '$POOL_NAME' created successfully"
    else
        echo_error "Failed to create ZFS pool."
        exit 1
    fi
fi

# Show current pool status
echo ""
echo "Current pool status:"
zpool status "$POOL_NAME"
echo ""

# ------------------------------------------
# Create systemd service for NVMe connect
# ------------------------------------------
echo_info "Creating systemd services for persistence..."

SERVICE_NAME="nvme-connect-${POOL_NAME}"
NVME_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"

cat <<EOF > "$NVME_SERVICE"
[Unit]
Description=Connect NVMe-oF volume from TrueNAS for pool ${POOL_NAME}
After=network-online.target
Wants=network-online.target
Before=zfs-import.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 10
ExecStart=/usr/sbin/nvme connect -t $TRANSPORT -a $TRADDR -s 4420 -n $NQN
ExecStop=/usr/sbin/nvme disconnect -n $NQN
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo_success "Created $NVME_SERVICE"

# ------------------------------------------
# Create systemd service for ZFS import
# ------------------------------------------
ZPOOL_SERVICE_NAME="zpool-import-${POOL_NAME}"
ZPOOL_SERVICE="/etc/systemd/system/${ZPOOL_SERVICE_NAME}.service"

cat <<EOF > "$ZPOOL_SERVICE"
[Unit]
Description=Import ZFS pool ${POOL_NAME} after NVMe connection
After=${SERVICE_NAME}.service zfs-import.target
Requires=${SERVICE_NAME}.service
Before=zfs-mount.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/sbin/zpool import -f ${POOL_NAME}
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=zfs-mount.service
EOF

echo_success "Created $ZPOOL_SERVICE"

# Reload systemd and enable services
echo_info "Enabling systemd services..."
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl enable "${ZPOOL_SERVICE_NAME}.service"

echo ""
echo_success "===================="
echo_success "Setup Complete!"
echo_success "===================="
echo ""
echo_info "Pool Information:"
echo "  Pool Name: $POOL_NAME"
echo "  Mount Point: /$POOL_NAME"
echo "  Device: $DEVICE"
echo ""
echo_info "Services Created:"
echo "  - ${SERVICE_NAME}.service"
echo "  - ${ZPOOL_SERVICE_NAME}.service"
echo ""
echo_info "Verify with:"
echo "  zpool status $POOL_NAME"
echo "  zfs list"
echo "  systemctl status ${SERVICE_NAME}.service"
echo ""
echo_success "System will automatically connect and mount on reboot!"
