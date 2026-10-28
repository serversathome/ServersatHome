#!/bin/bash

# ============================================================
# Docker Engine installer for Ubuntu / Debian
# Follows https://docs.docker.com/engine/install/ubuntu/ and
# https://docs.docker.com/engine/install/debian/ (docker.asc key, deb822 sources)
# Version: 2.0 (2026-10-28)
# ============================================================

set -euo pipefail

# Work out which Docker repository to use
. /etc/os-release
if [[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *ubuntu* ]]; then
    DOCKER_DISTRO="ubuntu"
    DOCKER_SUITE="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
elif [[ "${ID:-}" == "debian" ]]; then
    DOCKER_DISTRO="debian"
    DOCKER_SUITE="$VERSION_CODENAME"
else
    echo "Unsupported distribution: ${PRETTY_NAME:-unknown}. This script supports Ubuntu and Debian."
    exit 1
fi

# Remove old / conflicting Docker packages (only the ones that are installed)
OLD_PKGS=$(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc 2>/dev/null | cut -f1 || true)
if [[ -n "$OLD_PKGS" ]]; then
    # shellcheck disable=SC2086
    sudo apt-get remove -y $OLD_PKGS
fi

# Remove the repo definition and key left by older versions of this script,
# otherwise apt fails with "Conflicting values set for option Signed-By"
sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg

# Update package list
sudo apt-get update

# Install required dependencies for Docker repository setup
sudo apt-get install ca-certificates curl -y

# Create directory for storing Docker GPG key
sudo install -m 0755 -d /etc/apt/keyrings

# Download Docker GPG key and save it
sudo curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc

# Set proper permissions for the key file
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker APT repository (deb822 format)
sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/${DOCKER_DISTRO}
Suites: ${DOCKER_SUITE}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# Update package list again to include Docker packages
sudo apt-get update

# Install Docker and related components
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

echo "Docker installed: $(docker --version)"
