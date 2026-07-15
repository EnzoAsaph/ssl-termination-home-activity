#!/usr/bin/env bash
# setup-ufw-web.sh
#
# Configures UFW on a web server (web-01 or web-02) so that it accepts
# plain-text HTTP (port 80) ONLY from the load balancer (lb-01, 172.25.0.10).
# Everything else inbound is denied, except SSH so we can still manage it.
#
# Also installs nginx with a page identifying the server if nothing is
# listening on :80 yet, so the load balancer has something to balance.
#
# Usage (from your host machine, once the lab containers are up):
#   ./scripts/setup-ufw-web.sh 2211   # web-01
#   ./scripts/setup-ufw-web.sh 2212   # web-02
#
# NOTE: UFW needs the NET_ADMIN capability inside a container. If `ufw enable`
# fails with an iptables permission error, add this to each web service in
# the lab's compose.yml and re-create the containers:
#     cap_add:
#       - NET_ADMIN

set -euo pipefail

PORT="${1:?Usage: $0 <ssh-port>   (2211 = web-01, 2212 = web-02)}"
HOST="localhost"
USER="ubuntu"
KEY_PATH="$HOME/.ssh/web_infra_lab_key"
LB_IP="172.25.0.10"

SSH_OPTS=(-p "$PORT")
if [ -f "$KEY_PATH" ]; then
    SSH_OPTS+=(-i "$KEY_PATH")
fi

echo ">> Configuring UFW on $USER@$HOST:$PORT (HTTP allowed only from $LB_IP)"
ssh "${SSH_OPTS[@]}" "$USER@$HOST" bash -s -- "$LB_IP" <<'REMOTE'
set -e
LB_IP="$1"

sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw

# Make sure something is actually serving HTTP on :80
if ! netstat -lnt 2>/dev/null | grep -q ':80 '; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
    echo "<h1>$(hostname)</h1>" | sudo tee /var/www/html/index.html >/dev/null
    sudo service nginx start 2>/dev/null || sudo nginx
fi

# --- UFW rules -------------------------------------------------------------
# Order matters: allow SSH FIRST so enabling the firewall can't lock us out.
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing

# 1. keep management access
sudo ufw allow 22/tcp comment 'SSH management'

# 2. plain-text HTTP ONLY from the load balancer
sudo ufw allow from "$LB_IP" to any port 80 proto tcp comment 'HTTP from lb-01 only'

# (no other rule for port 80 -> any other source hits "default deny")
sudo ufw --force enable

echo ">> UFW status on $(hostname):"
sudo ufw status verbose
REMOTE

echo
echo ">> Done. Verify:"
echo "     From lb-01 (allowed):   docker exec lb-01 curl -s http://172.25.0.$( [ "$PORT" = 2211 ] && echo 11 || echo 12 )/"
echo "     From host (denied):     curl --max-time 5 http://localhost:$( [ "$PORT" = 2211 ] && echo 8080 || echo 8081 )/   # should time out"
