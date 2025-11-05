#!/bin/bash

# ==========================================
# Proxmox NVMe-oF Auto Setup for TrueNAS
# Fully Automated and User-Friendly
# ==========================================

set -euo pipefail

# Prompt for TrueNAS IP
read -rp "Enter the IP of your TrueNAS NVMe-oF server: " TRUENAS_IP
if [[ -z "$TRUENAS_IP" ]]; then
    echo "Error: No IP entered."
    exit 1
fi


apt install -y nvme-cli


# Discover NVMe-oF targets
echo "Discovering NVMe-oF targets on $TRUENAS_IP..."
DISCOVERY=$(nvme discover -t tcp -a "$TRUENAS_IP" -s 4420)

# Filter for real NVMe subsystems only (ignore discovery controller)
SUBSYSTEMS=$(echo "$DISCOVERY" | awk '
/subtype: *nvme/ {subnqn=""; traddr=""; next}
/subnqn:/ {subnqn=$2}
/traddr:/ {traddr=$2; if(subnqn !~ /discovery/ && subnqn!="" && traddr!="") print subnqn "|" traddr}
')

if [[ -z "$SUBSYSTEMS" ]]; then
    echo "No NVMe-oF subsystems found. Check IP/network."
    exit 1
fi

# Display menu
i=1
declare -A SUBS
while IFS="|" read -r nqn traddr; do
    SUBS[$i]="$nqn|$traddr"
    echo "[$i] NQN: $nqn  IP: $traddr"
    ((i++))
done <<< "$SUBSYSTEMS"

# Prompt user to select target
read -rp "Select the target to use (enter number): " TARGET_INDEX
if ! [[ "$TARGET_INDEX" =~ ^[0-9]+$ ]] || [[ -z "${SUBS[$TARGET_INDEX]:-}" ]]; then
    echo "Invalid selection."
    exit 1
fi

SELECTED=${SUBS[$TARGET_INDEX]}
NQN=$(echo "$SELECTED" | cut -d'|' -f1)
TRADDR=$(echo "$SELECTED" | cut -d'|' -f2)
TRANSPORT="tcp"

echo "Selected NQN: $NQN"
echo "Target IP: $TRADDR"
echo "Transport: $TRANSPORT"

# Connect to NVMe-oF target
echo "Connecting to NVMe-oF target..."
nvme connect -t "$TRANSPORT" -a "$TRADDR" -s 4420 -n "$NQN"

# Detect NVMe device
DEVICE=$(nvme list | grep "$NQN" | awk '{print $1}')
if [[ -z "$DEVICE" ]]; then
    echo "Failed to detect NVMe device after connect."
    exit 1
fi
echo "Detected NVMe device: $DEVICE"

# Prompt for ZFS pool name
read -rp "Enter a name for the new ZFS pool: " POOL_NAME
if [[ -z "$POOL_NAME" ]]; then
    echo "Error: No pool name entered."
    exit 1
fi

# Create ZFS pool
echo "Creating ZFS pool '$POOL_NAME' on $DEVICE..."
zpool create "$POOL_NAME" "$DEVICE"

# ------------------------------------------
# Create systemd service for NVMe connect
# ------------------------------------------
NVME_SERVICE="/etc/systemd/system/nvme-connect@${POOL_NAME}.service"
cat <<EOF > "$NVME_SERVICE"
[Unit]
Description=Connect NVMe-oF volume from TrueNAS
After=network-online.target
Wants=network-online.target
BindsTo=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 10
ExecStart=/usr/bin/nvme connect -t $TRANSPORT -a $TRADDR -s 4420 -n $NQN
ExecStop=/usr/bin/nvme disconnect -n $NQN
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# ------------------------------------------
# Create systemd service for ZFS import
# ------------------------------------------
ZPOOL_SERVICE="/etc/systemd/system/zpool-import@${POOL_NAME}.service"
cat <<EOF > "$ZPOOL_SERVICE"
[Unit]
Description=Import ZFS pool $POOL_NAME after NVMe connection
After=nvme-connect@${POOL_NAME}.service
Requires=nvme-connect@${POOL_NAME}.service

[Service]
Type=oneshot
ExecStart=/sbin/zpool import -f $POOL_NAME
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable services
systemctl daemon-reload
systemctl enable "nvme-connect@${POOL_NAME}.service"
systemctl enable "zpool-import@${POOL_NAME}.service"

echo "✅ NVMe-oF setup complete."
echo "ZFS pool '$POOL_NAME' created and persistent systemd services enabled."
