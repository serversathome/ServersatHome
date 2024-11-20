#!/bin/bash

# Remove old Docker packages
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    sudo apt-get remove -y $pkg
done

# Update package list
sudo apt-get update

# Install required dependencies for Docker repository setup
sudo apt-get install ca-certificates curl gnupg -y

# Create directory for storing Docker GPG key
sudo install -m 0755 -d /etc/apt/keyrings

# Download Docker GPG key and save it
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Set proper permissions for the key file
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker APT repository to sources list
echo \
 "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
 $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
 sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package list again to include Docker packages
sudo apt-get update

# Install Docker and related components
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
