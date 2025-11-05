#!/bin/bash
# ==========================================
# Proxmox NVMe-oF Auto Setup for TrueNAS
# Fully Automated and User-Friendly
# ==========================================

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo_error() { echo -e "${RED}Error: $1${NC}" >&2; }
echo_success() { echo -e "${GREEN}✅ $1${NC}"; }
echo_info() { echo -e "${YELLOW}ℹ️  $1${NC}"; }

# Root check
if [[ $EUID -ne 0 ]]; then
   echo_error "This script must be run as root"
   exit 1
fi

# Get TrueNAS IP
while true; do
    read -rp "Enter the IP of your TrueNAS NVMe-oF server: " TRUENAS_IP
    if [[ -z "$TRUENAS_IP" ]]; then
        echo_error "No IP entered."
        continue
    fi
    if [[ $TRUENAS_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        break
    else
        echo_error "Invalid IP format."
    fi
done

# Install nvme-cli
if ! command -v nvme &> /dev/null; then
    echo_info "Installing nvme-cli..."
    apt update && apt install -y nvme-cli
fi

# Discover targets
echo_info "Discovering NVMe-oF targets on $TRUENAS_IP..."
DISCOVERY=$(nvme discover -t tcp -a "$TRUENAS_IP" -s 4420 2>&1)
if [[ $? -ne 0 ]]; then
    echo_error "Failed to discover targets."
    echo "$DISCOVERY"
    exit 1
fi

# Parse subsystems
SUBSYSTEMS=$(echo "$DISCOVERY" | awk '
/subtype: *nvme/ {subnqn=""; traddr=""; next}
/subnqn:/ {subnqn=$2}
/traddr:/ {traddr=$2; if(subnqn !~ /discovery/ && subnqn!="" && traddr!="") print subnqn "|" traddr}
')

if [[ -z "$SUBSYSTEMS" ]]; then
    echo_error "No NVMe-oF subsystems found."
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

# Select target
while true; do
    read -rp "Select target (enter number): " TARGET_INDEX
    if [[ "$TARGET_INDEX" =~ ^[0-9]+$ ]] && [[ -n "${SUBS[$TARGET_INDEX]:-}" ]]; then
        break
    fi
    echo_error "Invalid selection."
done

SELECTED=${SUBS[$TARGET_INDEX]}
NQN=$(echo "$SELECTED" | cut -d'|' -f1)
TRADDR=$(echo "$SELECTED" | cut -d'|' -f2)
TRANSPORT="tcp"

echo ""
echo_info "Selected: $NQN"
echo ""

# Snapshot existing devices
DEVICES_BEFORE=$(lsblk -ndo NAME | grep -E '^nvme[0-9]+n[0-9]+$' || true)

# Connect
echo_info "Connecting to NVMe-oF target..."
nvme connect -t "$TRANSPORT" -a "$TRADDR" -s 4420 -n "$NQN" 2>&1
sleep 5

# Find new device
DEVICES_AFTER=$(lsblk -ndo NAME | grep -E '^nvme[0-9]+n[0-9]+$' || true)
DEVICE=$(comm -13 <(echo "$DEVICES_BEFORE" | sort) <(echo "$DEVICES_AFTER" | sort) | head -n1)

# If no new device found, just take the first nvme device (likely already connected)
if [[ -z "$DEVICE" ]]; then
    DEVICE=$(lsblk -ndo NAME | grep -E '^nvme[0-9]+n[0-9]+$' | head -n1)
fi

if [[ -z "$DEVICE" ]]; then
    echo_error "Failed to detect NVMe device."
    lsblk
    exit 1
fi

DEVICE="/dev/$DEVICE"
echo_success "Device: $DEVICE"

# Check for existing pool
echo_info "Checking for existing ZFS pools..."
IMPORT_OUTPUT=$(zpool import 2>&1 || true)

if echo "$IMPORT_OUTPUT" | grep -q "pool:"; then
    echo "$IMPORT_OUTPUT"
    echo ""
    read -rp "Import existing pool? (yes/no): " IMPORT_EXISTING
    
    if [[ "$IMPORT_EXISTING" == "yes" ]]; then
        read -rp "Pool name to import: " POOL_NAME
        zpool import -f "$POOL_NAME"
        if [[ $? -eq 0 ]]; then
            echo_success "Pool imported"
            CREATE_NEW_POOL="no"
        else
            CREATE_NEW_POOL="yes"
        fi
    else
        CREATE_NEW_POOL="yes"
    fi
else
    CREATE_NEW_POOL="yes"
fi

# Create new pool if needed
if [[ "$CREATE_NEW_POOL" == "yes" ]]; then
    while true; do
        read -rp "Enter ZFS pool name: " POOL_NAME
        if [[ -z "$POOL_NAME" ]]; then
            echo_error "No name entered."
            continue
        fi
        if zpool list "$POOL_NAME" &>/dev/null; then
            echo_error "Pool exists."
            continue
        fi
        if [[ "$POOL_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            break
        fi
        echo_error "Invalid name."
    done

    echo_info "Creating ZFS pool '$POOL_NAME' on $DEVICE..."
    zpool create "$POOL_NAME" "$DEVICE"
    if [[ $? -eq 0 ]]; then
        echo_success "Pool created"
    else
        echo_error "Failed to create pool"
        exit 1
    fi
fi

# Show pool
echo ""
zpool status "$POOL_NAME"
echo ""

# Create systemd services
echo_info "Creating systemd services..."

SERVICE_NAME="nvme-connect-${POOL_NAME}"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Connect NVMe-oF for ${POOL_NAME}
After=network-online.target
Wants=network-online.target
Before=zfs-import.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 10
ExecStart=/usr/sbin/nvme connect -t ${TRANSPORT} -a ${TRADDR} -s 4420 -n ${NQN}
ExecStop=/usr/sbin/nvme disconnect -n ${NQN}
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

ZPOOL_SERVICE="zpool-import-${POOL_NAME}"
cat > "/etc/systemd/system/${ZPOOL_SERVICE}.service" <<EOF
[Unit]
Description=Import ZFS pool ${POOL_NAME}
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

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl enable "${ZPOOL_SERVICE}.service"

echo ""
echo_success "Setup Complete!"
echo ""
echo_info "Pool: $POOL_NAME at /$POOL_NAME"
echo_info "Device: $DEVICE"
echo_info "Services: ${SERVICE_NAME}.service, ${ZPOOL_SERVICE}.service"
echo ""
echo_info "Reboot to test persistence!"
