#!/bin/bash
set -e

# Log all output
exec > >(tee -a /var/log/opencode-install.log) 2>&1

echo "Starting OpenCode Platform installation on VPS..."
echo "Date: $(date)"

# Check root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (or with sudo)"
  exit 1
fi

echo "--- Installing dependencies ---"
apt-get update
# Install curl, git, sqlite3, ufw
apt-get install -y curl git sqlite3 ufw build-essential

# Install Node.js LTS (20.x)
if ! command -v node > /dev/null; then
    echo "Installing Node.js LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
else
    echo "Node.js is already installed. Version: $(node -v)"
fi

echo "--- Installing OpenCode CLI ---"
# Install OpenCode CLI globally
npm install -g opencode-ai

echo "--- Installing cloudflared ---"
if ! command -v cloudflared > /dev/null; then
    echo "Downloading and installing cloudflared..."
    curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i cloudflared.deb
    rm cloudflared.deb
else
    echo "cloudflared is already installed. Version: $(cloudflared -v)"
fi

echo "--- Setting up UFW (Firewall) ---"
# Ensure UFW allows SSH and is enabled
ufw allow OpenSSH
echo "y" | ufw enable

echo "--- Creating directory structure ---"
mkdir -p /srv/opencode/controlplane
mkdir -p /srv/repos
mkdir -p /srv/workspaces
mkdir -p /etc/opencode

# Set permissions for /etc/opencode
chmod 700 /etc/opencode

echo "--- Deploying Control Plane ---"
# Assuming this script is run from the repository root
if [ -d "./controlplane" ]; then
    cp -r ./controlplane/* /srv/opencode/controlplane/
    cp -r ./scripts /srv/opencode/
    cd /srv/opencode/controlplane
    echo "Installing control plane dependencies..."
    npm install --production
    cd - > /dev/null
else
    echo "Warning: ./controlplane directory not found in current path. You may need to copy it manually."
fi

echo "--- Configuring systemd service ---"
cat << 'EOF' > /etc/systemd/system/controlplane.service
[Unit]
Description=OpenCode Control Plane
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/srv/opencode/controlplane
ExecStart=/usr/bin/node server.js
Restart=on-failure
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable controlplane.service
systemctl restart controlplane.service

echo "--- Installation Complete ---"
echo "The system is now running the control plane."
echo "Please set up a temporary cloudflared tunnel to access the setup wizard on port 3000,"
echo "or use SSH port forwarding to access it locally."
echo "Example: cloudflared tunnel --url http://localhost:3000"
