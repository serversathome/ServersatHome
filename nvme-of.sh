#!/bin/bash
# ==========================================
# Proxmox NVMe-oF Auto Setup for TrueNAS
# Fully Automated and User-Friendly
# ==========================================

# Trap to catch any exits
trap 'echo "Script exited at line $LINENO with code $?"' EXIT

# Color output for better UX
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_error() { echo -e "${RED}Error: $1${NC}" >&2; }
echo_success() { echo -e "${GREEN}✅ $1${NC}"; }
echo_info() { echo -e "${YELLOW}ℹ️  $1${NC}"; }

echo "Script started - debugging enabled"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo_error "This script must be run as root"
   exit 1
fi

echo "Root check passed"

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

echo "IP validated: $TRUENAS_IP"


apt update && apt install -y nvme-cli


echo "nvme-cli check complete"

# Discover NVMe-oF targets
echo_info "Discovering NVMe-oF targets on $TRUENAS_IP..."
DISCOVERY=$(nvme discover -t tcp -a "$TRUENAS_IP" -s 4420 2>&1)
DISC_STATUS=$?

echo "Discovery status: $DISC_STATUS"

if [[ $DISC_STATUS -ne 0 ]]; then
    echo_error "Failed to discover targets. Check network connectivity and TrueNAS configuration."
    echo "$DISCOVERY"
    exit 1
fi

echo "Discovery succeeded"

# Filter for real NVMe subsystems only (ignore discovery controller)
SUBSYSTEMS=$(echo "$DISCOVERY" | awk '
/subtype: *nvme/ {subnqn=""; traddr=""; next}
/subnqn:/ {subnqn=$2}
/traddr:/ {traddr=$2; if(subnqn !~ /discovery/ && subnqn!="" && traddr!="") print subnqn "|" traddr}
')

echo "Subsystems found: $(echo "$SUBSYSTEMS" | wc -l)"

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

echo "Menu displayed"

# Prompt user to select target
while true; do
    read -rp "Select the target to use (enter number): " TARGET_INDEX
    if [[ "$TARGET_INDEX" =~ ^[0-9]+$ ]] && [[ -n "${SUBS[$TARGET_INDEX]:-}" ]]; then
        break
    else
        echo_error "Invalid selection. Please enter a number from 1 to $((i-1))."
    fi
done

echo "Target selected: $TARGET_INDEX"

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

echo "About to check if already connected..."

# Check if already connected
if nvme list 2>/dev/null | grep -q "$NQN"; then
    echo_info "Already connected to this target."
    echo "Already connected flag set"
else
    echo "Not connected, will connect now..."
    # Connect to NVMe-oF target
    echo_info "Connecting to NVMe-oF target..."
    
    echo "Running: nvme connect -t $TRANSPORT -a $TRADDR -s 4420 -n $NQN"
    nvme connect -t "$TRANSPORT" -a "$TRADDR" -s 4420 -n "$NQN" 2>&1
    CONNECT_STATUS=$?
    
    echo "Connect command completed with status: $CONNECT_STATUS"
    
    echo_info "Waiting for device to be recognized..."
    sleep 5
    echo "Sleep completed"
fi

echo "Past connection section, starting device detection..."

# Detect NVMe device with retry logic
MAX_RETRIES=15
RETRY_COUNT=0
DEVICE=""

echo_info "Detecting NVMe device..."
while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    echo "Detection attempt $((RETRY_COUNT + 1))/$MAX_RETRIES"
    
    # Try to find the device
    NVME_LIST_OUTPUT=$(nvme list 2>/dev/null || echo "")
    DEVICE=$(echo "$NVME_LIST_OUTPUT" | grep "$NQN" | awk '{print $1}' | head -n1)
    
    if [[ -n "$DEVICE" ]]; then
        echo_success "Found device: $DEVICE"
        break
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo_info "Waiting for device to appear (attempt $RETRY_COUNT/$MAX_RETRIES)..."
    sleep 2
done

echo "Device detection loop completed. DEVICE=$DEVICE"

if [[ -z "$DEVICE" ]]; then
    echo_error "Failed to detect NVMe device after $MAX_RETRIES attempts."
    echo ""
    echo "Debug information:"
    echo "==================="
    echo "All NVMe devices:"
    nvme list 2>&1 || echo "nvme list failed"
    echo ""
    echo "NVMe subsystems:"
    ls -la /sys/class/nvme/ 2>/dev/null || echo "No nvme subsystems found"
    echo ""
    echo "Block devices:"
    lsblk | grep nvme || echo "No nvme block devices found"
    exit 1
fi

echo_success "Device ready: $DEVICE"

# Rest of the script continues...
echo "Continuing with ZFS pool setup..."

# Check if we can import an existing pool from this device
echo_info "Checking for existing ZFS pools..."
IMPORT_OUTPUT=$(zpool import 2>&1 || echo "")

if echo "$IMPORT_OUTPUT" | grep -q "pool:"; then
    echo_info "Found importable pool(s):"
    echo "$IMPORT_OUTPUT"
    echo ""
    read -rp "Do you want to import an existing pool? (yes/no): " IMPORT_EXISTING
    
    if [[ "$IMPORT_EXISTING" == "yes" ]]; then
        read -rp "Enter the pool name to import: " POOL_NAME
        echo_info "Importing pool '$POOL_NAME'..."
        zpool import -f "$POOL_NAME"
        IMPORT_STATUS=$?
        
        if [[ $IMPORT_STATUS -eq 0 ]]; then
            echo_success "Pool '$POOL_NAME' imported successfully"
            CREATE_NEW_POOL="no"
        else
            echo_error "Failed to import pool. Will create new pool instead."
            CREATE_NEW_POOL="yes"
        fi
    else
        CREATE_NEW_POOL="yes"
    fi
else
    echo_info "No existing pools found on device."
    CREATE_NEW_POOL="yes"
fi

if [[ "$CREATE_NEW_POOL" == "yes" ]]; then
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
    CREATE_STATUS=$?
    
    if [[ $CREATE_STATUS -eq 0 ]]; then
        echo_success "ZFS pool '$POOL_NAME' created successfully"
    else
        echo_error "Failed to create ZFS pool (exit code: $CREATE_STATUS)"
        exit 1
    fi
fi

# Show current pool status
echo ""
echo "Current pool status:"
zpool status "$POOL_NAME" 2>&1 || echo "Failed to get pool status"
echo ""

# ------------------------------------------
# Create systemd service for NVMe connect
# ------------------------------------------
echo_info "Creating systemd services for persistence..."

SERVICE_NAME="nvme-connect-${POOL_NAME}"
NVME_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"

cat > "$NVME_SERVICE" <<'SERVICEEOF'
[Unit]
Description=Connect NVMe-oF volume from TrueNAS for pool POOLNAME
After=network-online.target
Wants=network-online.target
Before=zfs-import.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 10
ExecStart=/usr/sbin/nvme connect -t TRANSPORT -a TRADDR -s 4420 -n NQN
ExecStop=/usr/sbin/nvme disconnect -n NQN
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

# Replace placeholders
sed -i "s|POOLNAME|${POOL_NAME}|g" "$NVME_SERVICE"
sed -i "s|TRANSPORT|${TRANSPORT}|g" "$NVME_SERVICE"
sed -i "s|TRADDR|${TRADDR}|g" "$NVME_SERVICE"
sed -i "s|NQN|${NQN}|g" "$NVME_SERVICE"

echo_success "Created $NVME_SERVICE"

# ------------------------------------------
# Create systemd service for ZFS import
# ------------------------------------------
ZPOOL_SERVICE_NAME="zpool-import-${POOL_NAME}"
ZPOOL_SERVICE="/etc/systemd/system/${ZPOOL_SERVICE_NAME}.service"

cat > "$ZPOOL_SERVICE" <<ZPOOLEOF
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
ZPOOLEOF

echo_success "Created $ZPOOL_SERVICE"

# Reload systemd and enable services
echo_info "Enabling systemd services..."
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service" 2>&1 || echo "Warning: Failed to enable nvme service"
systemctl enable "${ZPOOL_SERVICE_NAME}.service" 2>&1 || echo "Warning: Failed to enable zpool service"

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

trap - EXIT
echo "Script completed successfully"
