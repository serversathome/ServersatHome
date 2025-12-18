#!/bin/bash

# Prompt the user for pool names
read -p "Enter the pool name for configs: " CONFIG_POOL
read -p "Enter the pool name for media (can be same as configs): " MEDIA_POOL

# Retrieve the private IP address of the server and convert it to CIDR notation
PRIVATE_IP=$(hostname -I | awk '{print $1}')
CIDR_NETWORK="${PRIVATE_IP%.*}.0/24"

# Define datasets and directories
CONFIG_DATASETS=("prowlarr" "radarr" "sonarr" "jellyseerr" "profilarr" "bazarr" "jellyfin" "qbittorrent" "dozzle")
MEDIA_SUBDIRECTORIES=("movies" "tv" "downloads")
DOCKER_COMPOSE_PATH="/mnt/$CONFIG_POOL/docker"
QBITTORRENT_WIREGUARD_DIR="/mnt/$CONFIG_POOL/configs/qbittorrent/wireguard"

# Function to create and set up a dataset
create_dataset() {
    local pool_name="$1"
    local dataset_name="$2"
    local dataset_path="$pool_name/$dataset_name"
    local mountpoint="/mnt/$dataset_path"

    if ! zfs list "$dataset_path" >/dev/null 2>&1; then
        echo "Creating dataset: $dataset_path"
        zfs create "$dataset_path"
    fi

    # Ensure dataset is mounted
    if ! mountpoint -q "$mountpoint"; then
        echo "Mounting dataset: $dataset_path"
        zfs mount "$dataset_path"
    fi

    # Verify mount exists before applying permissions
    if [ -d "$mountpoint" ]; then
        chown root:apps "$mountpoint"
        chmod 770 "$mountpoint"
    else
        echo "⚠️ Warning: $mountpoint does not exist after mounting. Check dataset status."
    fi
}

# Function to create a directory if it doesn't exist
create_directory() {
    local dir_path="$1"
    if [ ! -d "$dir_path" ]; then
        echo "Creating directory: $dir_path"
        mkdir -p "$dir_path"
        chown root:apps "$dir_path"
        chmod 770 "$dir_path"
    else
        echo "Directory already exists: $dir_path, updating permissions..."
        chown root:apps "$dir_path"
        chmod 770 "$dir_path"
    fi
}

# Create the "configs" dataset (parent) on the config pool
create_dataset "$CONFIG_POOL" "configs"

# Create the config datasets on the config pool
for dataset in "${CONFIG_DATASETS[@]}"; do
    create_dataset "$CONFIG_POOL" "configs/$dataset"
done

# Create the "media" dataset on the media pool
create_dataset "$MEDIA_POOL" "media"

# Create subdirectories inside the media dataset
for subdir in "${MEDIA_SUBDIRECTORIES[@]}"; do
    create_directory "/mnt/$MEDIA_POOL/media/$subdir"
done

# Ensure Docker Compose directory exists
create_directory "$DOCKER_COMPOSE_PATH"

# Ensure the Docker Compose file path exists
DOCKER_COMPOSE_FILE="$DOCKER_COMPOSE_PATH/docker-compose.yml"
if [ ! -d "$DOCKER_COMPOSE_PATH" ]; then
    echo "⚠️ Docker Compose directory missing, creating: $DOCKER_COMPOSE_PATH"
    mkdir -p "$DOCKER_COMPOSE_PATH"
    chown root:apps "$DOCKER_COMPOSE_PATH"
    chmod 770 "$DOCKER_COMPOSE_PATH"
fi

# Generate docker-compose.yml
cat > "$DOCKER_COMPOSE_FILE" <<EOF
networks:
  media_network:
    driver: bridge

services:
  prowlarr:
    image: linuxserver/prowlarr
    container_name: prowlarr
    restart: unless-stopped
    ports:
      - 9696:9696
    networks:
      - media_network
    volumes:
      - /mnt/$CONFIG_POOL/configs/prowlarr:/config
      - /mnt/$MEDIA_POOL/media:/media

  radarr:
    image: linuxserver/radarr
    container_name: radarr
    restart: unless-stopped
    ports:
      - 7878:7878
    environment:
      - PUID=568
      - PGID=568
      - TZ=America/New_York
    networks:
      - media_network
    volumes:
      - /mnt/$CONFIG_POOL/configs/radarr:/config
      - /mnt/$MEDIA_POOL/media:/media

  sonarr:
    image: linuxserver/sonarr
    container_name: sonarr
    restart: unless-stopped
    ports:
      - 8989:8989
    environment:
      - PUID=568
      - PGID=568
      - TZ=America/New_York
    networks:
      - media_network
    volumes:
      - /mnt/$CONFIG_POOL/configs/sonarr:/config
      - /mnt/$MEDIA_POOL/media:/media

  jellyseerr:
    image: fallenbagel/jellyseerr
    container_name: jellyseerr
    restart: unless-stopped
    ports:
      - 5055:5055
    environment:
      - TZ=America/New_York
    networks:
      - media_network
    user: "568:568"
    volumes:
      - /mnt/$CONFIG_POOL/configs/jellyseerr:/app/config
      
  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    environment:
      - LOG_LEVEL=info
      - LOG_HTML=false
      - CAPTCHA_SOLVER=none
      - TZ=America/New_York
    networks:
      - media_network
    ports:
      - 8191:8191
    restart: unless-stopped

  profilarr:
    image: santiagosayshey/profilarr:latest
    container_name: profilarr
    ports:
      - 6868:6868
    networks:
      - media_network
    volumes:
      - /mnt/$CONFIG_POOL/configs/profilarr:/config
    environment:
      - TZ=America/New_York
    restart: unless-stopped

  bazarr:
    image: linuxserver/bazarr
    container_name: bazarr
    restart: unless-stopped
    ports:
      - 6767:6767
    environment:
      - PUID=568
      - PGID=568
      - TZ=America/New_York
    networks:
      - media_network
    volumes:
      - /mnt/$CONFIG_POOL/configs/bazarr:/config
      - /mnt/$MEDIA_POOL/media:/media

  jellyfin:
    container_name: jellyfin
    environment:
      - PUID=568
      - PGID=568
      - TZ=America/New_York
    image: lscr.io/linuxserver/jellyfin:latest
    ports:
      - '8096:8096'
    restart: unless-stopped
    networks:
      - media_network
    volumes:
      - /mnt/$CONFIG_POOL/configs/jellyfin:/config
      - /mnt/$MEDIA_POOL/media:/media

  qbittorrent:
    container_name: qbittorrent
    image: ghcr.io/hotio/qbittorrent
    restart: unless-stopped
    ports:
      - 8080:8080
    environment:
      - PUID=568
      - PGID=568
      - UMASK=002
      - TZ=America/New_York
      - WEBUI_PORTS=8080/tcp,8080/udp
      - VPN_ENABLED=true
      - VPN_CONF=wg0
      - VPN_PROVIDER=generic
      - VPN_LAN_NETWORK=$CIDR_NETWORK,10.8.0.0/24,100.64.0.0/10,100.84.0.0/10
      - VPN_LAN_LEAK_ENABLED=false
      - VPN_EXPOSE_PORTS_ON_LAN=
      - VPN_AUTO_PORT_FORWARD=true
      - VPN_PORT_REDIRECTS=
      - VPN_FIREWALL_TYPE=auto
      - VPN_HEALTHCHECK_ENABLED=false
      - VPN_NAMESERVERS=wg
      - PRIVOXY_ENABLED=false
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=1
    volumes:
      - /mnt/$CONFIG_POOL/configs/qbittorrent:/config
      - /mnt/$MEDIA_POOL/media:/media

  dozzle:
    image: amir20/dozzle
    container_name: dozzle
    restart: unless-stopped
    ports:
      - '8888:8080'
    networks:
      - media_network
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /mnt/$CONFIG_POOL/configs/dozzle:/data

  watchtower:
    container_name: watchtower
    environment:
      - TZ=America/New_York
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_NOTIFICATIONS_HOSTNAME=TrueNAS
      - WATCHTOWER_INCLUDE_STOPPED=true
      - WATCHTOWER_DISABLE_CONTAINERS=ix*
      - WATCHTOWER_NO_STARTUP_MESSAGE=true
      - WATCHTOWER_SCHEDULE=0 0 3 * * *
    image: nickfedor/watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

      
EOF

echo "Docker Compose file created at $DOCKER_COMPOSE_FILE"
echo "Script completed."

# Ask the user if they want to launch the Docker containers
read -p "Would you like to launch the Docker containers now? (yes/no): " LAUNCH_CONTAINERS
# Launch Docker containers
if [[ "$LAUNCH_CONTAINERS" =~ ^[Yy]es$ ]]; then
    # Ensure the WireGuard directory exists
    create_directory "$QBITTORRENT_WIREGUARD_DIR"

    # Prompt the user to paste their WireGuard VPN configuration
    echo "Please paste your WireGuard VPN configuration below by using SHIFT+INS to paste (press ENTER then Ctrl+D when done):"
    WG_CONFIG=$(cat)

    # Save the VPN configuration as wg0.conf
    echo "$WG_CONFIG" > "$QBITTORRENT_WIREGUARD_DIR/wg0.conf"
    chown root:apps "$QBITTORRENT_WIREGUARD_DIR/wg0.conf"
    chmod 660 "$QBITTORRENT_WIREGUARD_DIR/wg0.conf"
    echo "WireGuard configuration saved to $QBITTORRENT_WIREGUARD_DIR/wg0.conf"

    # Change to the Docker Compose directory and launch the containers
    cd "$DOCKER_COMPOSE_PATH"
    echo "Launching Docker containers from $DOCKER_COMPOSE_PATH..."
    docker compose up -d

    if [ $? -eq 0 ]; then
        echo "Docker containers launched successfully!"

        # Modify qBittorrent.conf after the container is running
        QBITTORRENT_CONF_FILE="/mnt/$CONFIG_POOL/configs/qbittorrent/config/qBittorrent.conf"
        echo "Waiting for qBittorrent to generate its configuration file..."
        while [ ! -f "$QBITTORRENT_CONF_FILE" ]; do
            sleep 5
            echo "Waiting for $QBITTORRENT_CONF_FILE to be created..."
        done

        # Update or add the DefaultSavePath in the [BitTorrent] section
        if grep -q "\[BitTorrent\]" "$QBITTORRENT_CONF_FILE"; then
            echo "[BitTorrent] section found in $QBITTORRENT_CONF_FILE"
            if grep -q "Session\\DefaultSavePath=" "$QBITTORRENT_CONF_FILE"; then
                echo "Updating Session\\DefaultSavePath in $QBITTORRENT_CONF_FILE"
                sed -i "/\[BitTorrent\]/,/^\[/ s|Session\\DefaultSavePath=.*|Session\\DefaultSavePath=/media/downloads|" "$QBITTORRENT_CONF_FILE"
            else
                echo "Adding Session\\DefaultSavePath under [BitTorrent] section in $QBITTORRENT_CONF_FILE"
                sed -i "/\[BitTorrent\]/a Session\\DefaultSavePath=/media/downloads" "$QBITTORRENT_CONF_FILE"
            fi
        else
            echo "[BitTorrent] section not found in $QBITTORRENT_CONF_FILE"
            echo "Adding [BitTorrent] section and Session\\DefaultSavePath to $QBITTORRENT_CONF_FILE"
            echo -e "\n[BitTorrent]\nSession\\DefaultSavePath=/media/downloads" >> "$QBITTORRENT_CONF_FILE"
        fi

        echo "qBittorrent default save path set to /media/downloads in $QBITTORRENT_CONF_FILE"

        # Restart the qBittorrent container to apply the changes
        echo "Restarting qBittorrent container to apply the new configuration..."
        docker restart qbittorrent

        echo "qBittorrent configuration updated and container restarted."

        # Extract API keys from Radarr and Sonarr config files
        echo "Extracting API keys from Radarr and Sonarr..."
        RADARR_CONFIG_FILE="/mnt/$CONFIG_POOL/configs/radarr/config.xml"
        SONARR_CONFIG_FILE="/mnt/$CONFIG_POOL/configs/sonarr/config.xml"

        # Function to extract API key from config file
        extract_api_key() {
            local config_file="$1"
            if [ -f "$config_file" ]; then
                grep -oP '(?<=<ApiKey>)[^<]+' "$config_file"
            else
                echo ""
            fi
        }

        # Wait for config files to be generated
        echo "Waiting for Radarr and Sonarr to generate config files..."
        while [ ! -f "$RADARR_CONFIG_FILE" ] || [ ! -f "$SONARR_CONFIG_FILE" ]; do
            sleep 5
            echo "Waiting for config files..."
        done

        # Extract Radarr API key
        RADARR_API_KEY=$(extract_api_key "$RADARR_CONFIG_FILE")
        if [ -z "$RADARR_API_KEY" ]; then
            echo "⚠️ Warning: Radarr API key not found in $RADARR_CONFIG_FILE"
        else
            echo "Radarr API key extracted successfully"
        fi

        # Extract Sonarr API key
        SONARR_API_KEY=$(extract_api_key "$SONARR_CONFIG_FILE")
        if [ -z "$SONARR_API_KEY" ]; then
            echo "⚠️ Warning: Sonarr API key not found in $SONARR_CONFIG_FILE"
        else
            echo "Sonarr API key extracted successfully"
        fi

        # Add root folders to Radarr and Sonarr using their APIs
        if [ -n "$RADARR_API_KEY" ] && [ -n "$SONARR_API_KEY" ]; then
            echo "Adding root folders to Radarr and Sonarr..."

            # Wait for Radarr and Sonarr to be fully initialized
            echo "Waiting for Radarr and Sonarr to be ready..."
            until curl -s "http://localhost:7878/api/v3/system/status" -o /dev/null; do sleep 5; done
            until curl -s "http://localhost:8989/api/v3/system/status" -o /dev/null; do sleep 5; done

            # Add root folder to Radarr
            echo "Adding root folder to Radarr..."
            curl -X POST "http://localhost:7878/api/v3/rootfolder" \
              -H "X-Api-Key: $RADARR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{
                    "path": "/media/movies"
                  }'

            # Add root folder to Sonarr
            echo "Adding root folder to Sonarr..."
            curl -X POST "http://localhost:8989/api/v3/rootfolder" \
              -H "X-Api-Key: $SONARR_API_KEY" \
              -H "Content-Type: application/json" \
              -d '{
                    "path": "/media/tv"
                  }'

            echo "Root folders added successfully!"
        else
            echo "⚠️ Skipping root folder creation due to missing API keys. You can add them manually later."
        fi
    else
        echo "⚠️ Failed to launch Docker containers. Check the logs for errors."
    fi
else
    echo "Docker containers were not launched. You can start them manually by running:"
    echo "cd $DOCKER_COMPOSE_PATH && docker compose up -d"
fi
# Print running containers and their accessible URLs
if [[ "$LAUNCH_CONTAINERS" =~ ^[Yy]es$ ]]; then
    echo "Listing all running containers and their accessible URLs:"

    # Get the host's IP address
    host_ip=$(hostname -I | awk '{print $1}')

    # Get a list of all running containers
    docker ps --format "{{.Names}}" | while read -r container_name; do
        # Get the container's exposed ports
        ports=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{ (index $conf 0).HostPort }} {{end}}{{end}}' "$container_name")

        # Print the container name and its accessible URL
        if [ -n "$ports" ]; then
            for port in $ports; do
                echo "$container_name | http://$host_ip:$port"
            done
        else
            echo "$container_name | No exposed port found"
        fi
    done

    # Extract and print the qBittorrent password from the logs
    qbittorrent_container="qbittorrent"
    if docker ps --format "{{.Names}}" | grep -q "$qbittorrent_container"; then
        echo "Fetching qBittorrent password from logs..."
        # Wait a few seconds for qBittorrent to fully start and log the password
        sleep 10
        qbittorrent_password=$(docker logs "$qbittorrent_container" 2>&1 | grep -oP 'A temporary password is provided for this session: \K\S+' | tail -1)
        if [ -n "$qbittorrent_password" ]; then
            echo "qBittorrent WebUI password: $qbittorrent_password"
        else
            echo "qBittorrent WebUI password not found in logs. The container may still be starting."
        fi
    else
        echo "qBittorrent container is not running."
    fi
fi
