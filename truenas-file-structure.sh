#!/bin/bash

# Prompt the user for the pool name
read -p "Enter the pool name: " POOLNAME

# Retrieve the private IP address of the server and convert it to CIDR notation
PRIVATE_IP=$(hostname -I | awk '{print $1}')
CIDR_NETWORK="${PRIVATE_IP%.*}.0/24"

# Define datasets and directories
CONFIG_DATASETS=("prowlarr" "radarr" "sonarr" "jellyseerr" "recyclarr" "bazarr" "tdarr" "jellyfin" "qbittorrent" "dozzle")
TDARR_SUBDIRS=("server" "logs" "transcode_cache")
MEDIA_SUBDIRECTORIES=("movies" "tv" "downloads")
DOCKER_COMPOSE_PATH="/mnt/$POOLNAME/docker"
QBITTORRENT_WIREGUARD_DIR="/mnt/$POOLNAME/configs/qbittorrent/wireguard"

# Function to create and set up a dataset
create_dataset() {
    local dataset_name="$1"
    local dataset_path="$POOLNAME/$dataset_name"
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
        chown apps:apps "$mountpoint"
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
        chown apps:apps "$dir_path"
        chmod 770 "$dir_path"
    else
        echo "Directory already exists: $dir_path, skipping..."
    fi
}

# Create the "configs" dataset (parent)
create_dataset "configs"

# Create the config datasets
for dataset in "${CONFIG_DATASETS[@]}"; do
    create_dataset "configs/$dataset"
done

# Create the "media" dataset (instead of a directory)
create_dataset "media"

# Create subdirectories inside the media dataset
for subdir in "${MEDIA_SUBDIRECTORIES[@]}"; do
    create_directory "/mnt/$POOLNAME/media/$subdir"
done

# Ensure Tdarr subdirectories exist (only if tdarr dataset is properly mounted)
TDARR_MOUNTPOINT="/mnt/$POOLNAME/configs/tdarr"
if mountpoint -q "$TDARR_MOUNTPOINT"; then
    for subdir in "${TDARR_SUBDIRS[@]}"; do
        create_directory "$TDARR_MOUNTPOINT/$subdir"
    done
else
    echo "⚠️ Skipping tdarr subdirectory creation; dataset is not mounted."
fi

# Ensure Docker Compose directory exists
create_directory "$DOCKER_COMPOSE_PATH"

# Ensure the Docker Compose file path exists
DOCKER_COMPOSE_FILE="$DOCKER_COMPOSE_PATH/docker-compose.yml"
if [ ! -d "$DOCKER_COMPOSE_PATH" ]; then
    echo "⚠️ Docker Compose directory missing, creating: $DOCKER_COMPOSE_PATH"
    mkdir -p "$DOCKER_COMPOSE_PATH"
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
      - /mnt/$POOLNAME/configs/prowlarr:/config
      - /mnt/$POOLNAME/media:/media

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
      - /mnt/$POOLNAME/configs/radarr:/config
      - /mnt/$POOLNAME/media:/media

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
      - /mnt/$POOLNAME/configs/sonarr:/config
      - /mnt/$POOLNAME/media:/media

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
    volumes:
      - /mnt/$POOLNAME/configs/jellyseerr:/app/config
      
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

  recyclarr:
    image: ghcr.io/recyclarr/recyclarr
    user: 568:568
    container_name: recyclarr
    restart: unless-stopped
    environment:
      CRON_SCHEDULE: 0 0 * * *
    networks:
      - media_network
    volumes:
      - /mnt/$POOLNAME/configs/recyclarr:/config

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
      - /mnt/$POOLNAME/configs/bazarr:/config
      - /mnt/$POOLNAME/media:/media

  tdarr:
    container_name: tdarr
    image: ghcr.io/haveagitgat/tdarr:latest
    restart: unless-stopped
    ports:
      - 8265:8265 # webUI port
      - 8266:8266 # server port
    environment:
      - TZ=America/New_York
      - PUID=568
      - PGID=568
      - UMASK_SET=002
      - serverIP=0.0.0.0
      - serverPort=8266
      - webUIPort=8265
      - internalNode=true
      - inContainer=true
      - ffmpegVersion=6
      - nodeName=MyInternalNode
      - NVIDIA_DRIVER_CAPABILITIES=all
      - NVIDIA_VISIBLE_DEVICES=all
    volumes:
      - /mnt/$POOLNAME/configs/tdarr:/app/config
      - /mnt/$POOLNAME/configs/tdarr/server:/app/server
      - /mnt/$POOLNAME/configs/tdarr/logs:/app/logs
      - /mnt/$POOLNAME/configs/tdarr/transcode_cache:/temp
      - /mnt/$POOLNAME/media:/media

    devices:
      - /dev/dri:/dev/dri
  #  deploy:
  #    resources:
  #      reservations:
  #        devices:
  #        - driver: nvidia
  #          count: all
  #          capabilities: [gpu]
    networks:
      - media_network

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
      - /mnt/$POOLNAME/configs/jellyfin:/config
      - /mnt/$POOLNAME/media:/media

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
      - VPN_LAN_NETWORK=$CIDR_NETWORK
      - VPN_EXPOSE_PORTS_ON_LAN=
      - VPN_AUTO_PORT_FORWARD=true
      - VPN_AUTO_PORT_FORWARD_TO_PORTS=5687
      - VPN_KEEP_LOCAL_DNS=false
      - VPN_FIREWALL_TYPE=auto
      - PRIVOXY_ENABLED=false
      - UNBOUND_ENABLED=false
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=1
    volumes:
      - /mnt/$POOLNAME/configs/qbittorrent:/config
      - /mnt/$POOLNAME/media:/media

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
      - /mnt/$POOLNAME/configs/dozzle:/data
EOF

echo "Docker Compose file created at $DOCKER_COMPOSE_FILE"
echo "Script completed."

# Ask the user if they want to launch the Docker containers
read -p "Would you like to launch the Docker containers now? (yes/no): " LAUNCH_CONTAINERS

# ... (rest of your existing script remains unchanged)

if [[ "$LAUNCH_CONTAINERS" =~ ^[Yy]es$ ]]; then
    # Ensure the WireGuard directory exists
    create_directory "$QBITTORRENT_WIREGUARD_DIR"

    # Prompt the user to paste their WireGuard VPN configuration
    echo "Please paste your WireGuard VPN configuration below by using SHIFT+INS to paste (press Ctrl+D when done):"
    WG_CONFIG=$(cat)

    # Save the VPN configuration as wg0.conf
    echo "$WG_CONFIG" > "$QBITTORRENT_WIREGUARD_DIR/wg0.conf"
    echo "WireGuard configuration saved to $QBITTORRENT_WIREGUARD_DIR/wg0.conf"

    # Change to the Docker Compose directory and launch the containers
    cd "$DOCKER_COMPOSE_PATH"
    echo "Launching Docker containers from $DOCKER_COMPOSE_PATH..."
    docker compose up -d

    if [ $? -eq 0 ]; then
        echo "Docker containers launched successfully!"

        # Ask the user if they want to configure recyclarr
        read -p "Would you like to sync recyclarr to radarr and sonarr? (yes/no): " CONFIGURE_RECYCLARR

        if [[ "$CONFIGURE_RECYCLARR" =~ ^[Yy]es$ ]]; then
            echo "Configuring recyclarr..."

            # Paths to Radarr and Sonarr config files
            RADARR_CONFIG_FILE="/mnt/$POOLNAME/configs/radarr/config.xml"
            SONARR_CONFIG_FILE="/mnt/$POOLNAME/configs/sonarr/config.xml"

            # Function to extract API key from config file
            extract_api_key() {
                local config_file="$1"
                if [ -f "$config_file" ]; then
                    grep -oP '(?<=<ApiKey>)[^<]+' "$config_file"
                else
                    echo ""
                fi
            }

            # Extract Radarr API key
            RADARR_API_KEY=$(extract_api_key "$RADARR_CONFIG_FILE")
            if [ -z "$RADARR_API_KEY" ]; then
                echo "⚠️ Error: Radarr API key not found in $RADARR_CONFIG_FILE"
                exit 1
            fi

            # Extract Sonarr API key
            SONARR_API_KEY=$(extract_api_key "$SONARR_CONFIG_FILE")
            if [ -z "$SONARR_API_KEY" ]; then
                echo "⚠️ Error: Sonarr API key not found in $SONARR_CONFIG_FILE"
                exit 1
            fi

            echo "Radarr API key: $RADARR_API_KEY"
            echo "Sonarr API key: $SONARR_API_KEY"

            # Step 1: Run `recyclarr config create` inside the recyclarr container
            echo "Creating recyclarr configuration..."
            docker exec -it recyclarr recyclarr config create

            # Step 2: Overwrite the recyclarr.yml file with the provided template
            RECYCLARR_YML="/mnt/$POOLNAME/configs/recyclarr/recyclarr.yml"
            echo "Updating $RECYCLARR_YML with API keys..."

            cat > "$RECYCLARR_YML" <<EOF
sonarr:
  web-1080p-v4:
    base_url: http://sonarr:8989
    api_key: $SONARR_API_KEY
    delete_old_custom_formats: true
    replace_existing_custom_formats: true
    include:
      # Comment out any of the following includes to disable them
      - template: sonarr-quality-definition-series
      - template: sonarr-v4-quality-profile-web-1080p
      - template: sonarr-v4-custom-formats-web-1080p
      - template: sonarr-v4-quality-profile-web-2160p
      - template: sonarr-v4-custom-formats-web-2160p

# Custom Formats: https://recyclarr.dev/wiki/yaml/config-reference/custom-formats/
    custom_formats:
      # HDR Formats
      - trash_ids:
          # Comment out the next line if you and all of your users' setups are fully DV compatible
          - 9b27ab6498ec0f31a3353992e19434ca # DV (WEBDL)
          # HDR10Plus Boost - Uncomment the next line if any of your devices DO support HDR10+
          # - 0dad0a507451acddd754fe6dc3a7f5e7 # HDR10Plus Boost
        assign_scores_to:
          - name: WEB-2160p


      # Optional
      - trash_ids:
           - 32b367365729d530ca1c124a0b180c64 # Bad Dual Groups
           - 82d40da2bc6923f41e14394075dd4b03 # No-RlsGroup
           - e1a997ddb54e3ecbfe06341ad323c458 # Obfuscated
           - 06d66ab109d4d2eddb2794d21526d140 # Retags
           - 1b3994c551cbb92a2c781af061f4ab44 # Scene
        assign_scores_to:
          - name: WEB-2160p

      - trash_ids:
          # Uncomment the next six lines to allow x265 HD releases with HDR/DV
          # - 47435ece6b99a0b477caf360e79ba0bb # x265 (HD)
        # assign_scores_to:
          # - name: WEB-2160p
            # score: 0
      # - trash_ids:
          # - 9b64dff695c2115facf1b6ea59c9bd07 # x265 (no HDR/DV)
        assign_scores_to:
          - name: WEB-2160p

      - trash_ids:
          - 2016d1676f5ee13a5b7257ff86ac9a93 # SDR
        assign_scores_to:
          - name: WEB-2160p
            # score: 0 # Uncomment this line to enable SDR releases

      # Optional
      - trash_ids:
           - 32b367365729d530ca1c124a0b180c64 # Bad Dual Groups
           - 82d40da2bc6923f41e14394075dd4b03 # No-RlsGroup
           - e1a997ddb54e3ecbfe06341ad323c458 # Obfuscated
           - 06d66ab109d4d2eddb2794d21526d140 # Retags
           - 1b3994c551cbb92a2c781af061f4ab44 # Scene
        assign_scores_to:
          - name: WEB-1080p

      - trash_ids:
          # Uncomment the next six lines to allow x265 HD releases with HDR/DV
          # - 47435ece6b99a0b477caf360e79ba0bb # x265 (HD)
        # assign_scores_to:
          # - name: WEB-1080p
            # score: 0
      # - trash_ids:
          # - 9b64dff695c2115facf1b6ea59c9bd07 # x265 (no HDR/DV)
        assign_scores_to:
          - name: WEB-1080p

# Configuration specific to Radarr.
radarr:
 uhd-bluray-web:
    base_url: http://radarr:7878
    api_key: $RADARR_API_KEY
    delete_old_custom_formats: true
    replace_existing_custom_formats: true
    include:
     # Comment out any of the following includes to disable them
     - template: radarr-quality-definition-movie
     - template: radarr-quality-profile-uhd-bluray-web
     - template: radarr-custom-formats-uhd-bluray-web
     - template: radarr-quality-definition-movie
     - template: radarr-quality-profile-hd-bluray-web
     - template: radarr-custom-formats-hd-bluray-web

# Custom Formats: https://recyclarr.dev/wiki/yaml/config-reference/custom-formats/
    custom_formats:
     # Audio
     - trash_ids:
         # Uncomment the next section to enable Advanced Audio Formats
         # - 496f355514737f7d83bf7aa4d24f8169 # TrueHD Atmos
         # - 2f22d89048b01681dde8afe203bf2e95 # DTS X
         # - 417804f7f2c4308c1f4c5d380d4c4475 # ATMOS (undefined)
         # - 1af239278386be2919e1bcee0bde047e # DD+ ATMOS
         # - 3cafb66171b47f226146a0770576870f # TrueHD
         # - dcf3ec6938fa32445f590a4da84256cd # DTS-HD MA
         # - a570d4a0e56a2874b64e5bfa55202a1b # FLAC
         # - e7c2fcae07cbada050a0af3357491d7b # PCM
         # - 8e109e50e0a0b83a5098b056e13bf6db # DTS-HD HRA
         # - 185f1dd7264c4562b9022d963ac37424 # DD+
         # - f9f847ac70a0af62ea4a08280b859636 # DTS-ES
         # - 1c1a4c5e823891c75bc50380a6866f73 # DTS
         # - 240770601cc226190c367ef59aba7463 # AAC
         # - c2998bd0d90ed5621d8df281e839436e # DD
       assign_scores_to:
         - name: UHD Bluray + WEB

     # Movie Versions
     - trash_ids:
         - 9f6cbff8cfe4ebbc1bde14c7b7bec0de # IMAX Enhanced
       assign_scores_to:
         - name: UHD Bluray + WEB
           # score: 0 # Uncomment this line to disable prioritised IMAX Enhanced releases

     # Optional
     - trash_ids:
         # Comment out the next line if you and all of your users' setups are fully DV compatible
         - 923b6abef9b17f937fab56cfcf89e1f1 # DV (WEBDL)
         # HDR10Plus Boost - Uncomment the next line if any of your devices DO support HDR10+
         # - b17886cb4158d9fea189859409975758 # HDR10Plus Boost
       assign_scores_to:
         - name: UHD Bluray + WEB

     - trash_ids:
         - 9c38ebb7384dada637be8899efa68e6f # SDR
       assign_scores_to:
         - name: UHD Bluray + WEB
           # score: 0 # Uncomment this line to allow SDR releases

     - trash_ids:
         - 9f6cbff8cfe4ebbc1bde14c7b7bec0de # IMAX Enhanced
       assign_scores_to:
         - name: HD Bluray + WEB
           # score: 0 # Uncomment this line to disable prioritised IMAX Enhanced releases
EOF

            echo "recyclarr.yml file updated successfully!"

            # Step 3: Run `recyclarr sync` inside the recyclarr container
            echo "Running recyclarr sync..."
            docker exec -it recyclarr recyclarr sync

            echo "recyclarr configuration and sync completed!"
        else
            echo "Skipping recyclarr configuration."
        fi
    else
        echo "⚠️ Failed to launch Docker containers. Check the logs for errors."
    fi
else
    echo "Docker containers were not launched. You can start them manually by running:"
    echo "cd $DOCKER_COMPOSE_PATH && docker compose up -d"
fi
