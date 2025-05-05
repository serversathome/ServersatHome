#!/bin/bash
# version 0.9

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Use sudo." >&2
    exit 1
fi

# Ask for host media directory
read -p "Where is your media directory on the host? (e.g., /mnt/tank/media): " HOST_MEDIA_DIR

# Verify directory exists
if [ ! -d "$HOST_MEDIA_DIR" ]; then
    echo "Error: Directory $HOST_MEDIA_DIR does not exist on the host." >&2
    exit 1
fi

# Prompt for WireGuard VPN configuration
echo -e "\nPaste your WireGuard VPN configuration below (press ENTER, then Ctrl+D when done):"
WG_TMP_FILE="/tmp/wg0.conf"
cat > "$WG_TMP_FILE"
chmod 600 "$WG_TMP_FILE"
echo "WireGuard config saved to $WG_TMP_FILE"

# Define variables
CONTAINER_NAME="qbit"
QBITTORRENT_PORT="8080"
CONTAINER_MOUNT_POINT="/media"

# Mount media directory into container
echo "Mounting host directory $HOST_MEDIA_DIR to container's $CONTAINER_MOUNT_POINT..."
incus config device add $CONTAINER_NAME mediadisk disk source="$HOST_MEDIA_DIR" path="$CONTAINER_MOUNT_POINT" shift=true

# Ensure /etc/wireguard exists in container and push wg0.conf
incus exec $CONTAINER_NAME -- mkdir -p /etc/wireguard
incus file push "$WG_TMP_FILE" "$CONTAINER_NAME/etc/wireguard/wg0.conf"
incus exec $CONTAINER_NAME -- chmod 600 /etc/wireguard/wg0.conf

# Enter container to set up everything
incus exec $CONTAINER_NAME -- /bin/bash <<'EOF'
# Create apps user with UID:GID 568:568 if not present
if ! grep -q "^apps:" /etc/group; then
    groupadd -g 568 apps
fi
if ! id -u apps >/dev/null 2>&1; then
    useradd -u 568 -g apps -d /home/apps -m apps
fi

# Install required packages
apt update && apt upgrade -y
apt install -y wireguard nano software-properties-common curl
add-apt-repository ppa:qbittorrent-team/qbittorrent-stable -y
apt update
apt install -y qbittorrent-nox

# Enable and start WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# Run qBittorrent once to generate config directory
sudo -u apps qbittorrent-nox &
sleep 10
pkill -u apps qbittorrent-nox || true
sleep 2

# Write qBittorrent config
sudo -u apps mkdir -p /home/apps/.config/qBittorrent
sudo -u apps bash -c 'cat > /home/apps/.config/qBittorrent/qBittorrent.conf' <<'CFG_EOF'
[Application]
FileLogger\Enabled=true
FileLogger\Path=/home/apps/.local/share/qBittorrent/logs

[BitTorrent]
Session\DefaultSavePath=/media/downloads
Session\Interface=wg0
Session\InterfaceName=wg0
Session\Port=6881
Session\QueueingSystemEnabled=true

[LegalNotice]
Accepted=true

[Preferences]
Advanced\RecheckOnCompletion=false
Connection\PortRangeMin=6881
Connection\PortRangeMax=6891
Downloads\SavePath=/media/downloads
Downloads\PreAllocation=true
Downloads\UseIncompleteExtension=true
WebUI\Address=*
WebUI\Port=8080
WebUI\Username=admin
WebUI\Password_PBKDF2=@ByteArray(xQsvH0gizLpYMkVon8hULg==:Ewk84E6W4Una5KA2BqKTLSm1JrYEf1obrVRIe/BvRW1bazpuPypyzJfE2zSGGOlc7Hl2K0kS4qRJkoZEJkeTJg==)
WebUI\CSRFProtection=false
CFG_EOF

# Set permissions
chown -R apps:apps /home/apps/.config/qBittorrent

# Create systemd service for qBittorrent
cat > /etc/systemd/system/qbittorrent-nox.service <<SVC_EOF
[Unit]
Description=qBittorrent-nox service
After=wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=simple
User=apps
Group=apps
WorkingDirectory=/home/apps
ExecStart=/usr/bin/qbittorrent-nox --webui-port=8080
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC_EOF

# Reload systemd and start services
systemctl daemon-reload
systemctl enable --now qbittorrent-nox
EOF

# Display access info
CONTAINER_IP=$(incus exec $CONTAINER_NAME -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo -e "\n✅ qBittorrent with VPN Setup Complete!"
echo "WebUI: http://$CONTAINER_IP:$QBITTORRENT_PORT"
echo "Username: admin"
echo "Password: adminadmin"
echo "Downloads saved to: $CONTAINER_MOUNT_POINT/downloads (host path: $HOST_MEDIA_DIR)"
echo "WireGuard VPN is active inside container. Kill switch enforced by network bind."
