#!/bin/bash
# ==========================================
# Proxmox NVMe-oF Auto Setup for TrueNAS
# Fully Automated and User-Friendly
# Version 2.0 (2026-10): Proxmox VE 9 / TrueNAS 25.10+
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

if ! apt-get install -y nvme-cli; then
    echo_error "Failed to install nvme-cli."
    exit 1
fi

# Load the NVMe/TCP initiator now and on every boot (it pulls in nvme-fabrics)
modprobe nvme-tcp || { echo_error "Could not load the nvme-tcp kernel module."; exit 1; }
echo "nvme-tcp" > /etc/modules-load.d/nvme-tcp.conf

# TrueNAS subsystems that don't "Allow any host" must list this NQN as an allowed host
if [[ -s /etc/nvme/hostnqn ]]; then
    echo_info "This host's NQN (add it to the subsystem's allowed hosts in TrueNAS if needed):"
    echo "    $(cat /etc/nvme/hostnqn)"
fi

# Discover targets
echo_info "Discovering NVMe-oF targets on $TRUENAS_IP..."
DISCOVERY=$(nvme discover -t tcp -a "$TRUENAS_IP" -s 4420 2>&1)
if [[ $? -ne 0 ]]; then
    echo_error "Failed to discover targets."
    echo "$DISCOVERY"
    echo_info "Check that the NVMe-oF service is running in TrueNAS, the port is 4420/TCP, and this host is allowed."
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
if ! nvme connect -t "$TRANSPORT" -a "$TRADDR" -s 4420 -n "$NQN" 2>&1; then
    echo_info "nvme connect returned an error (it does this if the target is already connected); checking for its device..."
fi
sleep 5

# Find new device
DEVICES_AFTER=$(lsblk -ndo NAME | grep -E '^nvme[0-9]+n[0-9]+$' || true)
DEVICE=$(comm -13 <(echo "$DEVICES_BEFORE" | sort) <(echo "$DEVICES_AFTER" | sort) | head -n1)

# If no new device appeared (e.g. already connected), find the namespace that
# belongs to the selected NQN. Never fall back to "the first nvme disk": on a
# host with a local NVMe boot drive that would be the boot disk.
if [[ -z "$DEVICE" ]]; then
    for blk in /sys/block/nvme*n*; do
        [[ -e "$blk/device/subsysnqn" ]] || continue
        if [[ "$(cat "$blk/device/subsysnqn")" == "$NQN" ]]; then
            DEVICE=$(basename "$blk")
            break
        fi
    done
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

# Disable ZFS cache import for this pool since it won't be available at boot
echo_info "Configuring ZFS to not use cache for this pool..."
zpool set cachefile=none "$POOL_NAME"

# Create systemd services
echo_info "Creating systemd services..."

SERVICE_NAME="nvme-connect-${POOL_NAME}"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Connect NVMe-oF for ${POOL_NAME}
# Network storage: start once the network is up. (The old DefaultDependencies=no +
# Before=zfs-import.target ordering formed a boot ordering cycle with
# network-online.target, which systemd breaks by dropping one of the jobs.)
After=network-online.target
Wants=network-online.target

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
After=${SERVICE_NAME}.service
Requires=${SERVICE_NAME}.service
After=zfs-import.target
# Import before Proxmox autostarts guests that may live on this pool
Before=pve-guests.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/sbin/zpool import -f -N ${POOL_NAME}
ExecStartPost=/sbin/zfs mount -a
# Export before the NVMe-oF link is torn down at shutdown (units stop in reverse order)
ExecStop=/sbin/zpool export ${POOL_NAME}
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl enable "${ZPOOL_SERVICE}.service"

# zfs-import-cache.service is left alone: it imports this host's OTHER pools at
# boot, and this pool is already kept out of the cache file (cachefile=none).
# Earlier versions of this script masked it; warn if that is still in place.
if [[ "$(systemctl is-enabled zfs-import-cache.service 2>/dev/null)" == "masked" ]]; then
    echo_info "zfs-import-cache.service is masked (an older version of this script did that)."
    echo_info "Your other ZFS pools won't import at boot until you run: systemctl unmask zfs-import-cache.service"
fi

echo ""
echo_success "Setup Complete!"
echo ""
echo_info "Pool: $POOL_NAME at /$POOL_NAME"
echo_info "Device: $DEVICE"
echo_info "Services: ${SERVICE_NAME}.service, ${ZPOOL_SERVICE}.service"
echo ""
echo_success "Configuration:"
echo "  ✓ NVMe-oF connection will start once the network is online"
echo "  ✓ Pool import will happen after NVMe connection (before guest autostart)"
echo "  ✓ Pool kept out of the ZFS cache file (other pools still import normally)"
echo ""
echo_info "Test with: systemctl status ${SERVICE_NAME}.service"
echo_info "Reboot to test full persistence!"
