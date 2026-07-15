#!/usr/bin/env bash
# setup-lb-ssl.sh
#
# Configures HAProxy on lb-01 for SSL TERMINATION with a self-signed cert:
#   1. installs haproxy + openssl on lb-01
#   2. generates a self-signed certificate directly on lb-01 and bundles it
#      into the single PEM file (cert + key) that HAProxy expects
#   3. deploys config/haproxy.cfg (HTTPS :443 terminates TLS, HTTP :80
#      redirects to HTTPS, backend speaks plain HTTP to web-01/web-02)
#   4. validates the config and (re)starts HAProxy
#
# Usage (from your host machine, once the lab containers are up):
#   ./scripts/setup-lb-ssl.sh            # defaults to lb-01 on localhost:2210
#   ./scripts/setup-lb-ssl.sh <ssh-port>
#
# Lab layout (waka-man/web_infra_lab compose.yml):
#   lb-01  172.25.0.10  ssh localhost:2210  http :8082->80  https :4443->443
#   web-01 172.25.0.11  ssh localhost:2211  http :8080->80
#   web-02 172.25.0.12  ssh localhost:2212  http :8081->80

set -euo pipefail

PORT="${1:-2210}"
HOST="localhost"
USER="ubuntu"
KEY_PATH="$HOME/.ssh/web_infra_lab_key"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAPROXY_CFG="$SCRIPT_DIR/../config/haproxy.cfg"

# Reuse the key pair from the SSH-hardening home activity if it exists,
# otherwise fall back to password login (ubuntu/pass123).
SSH_OPTS=(-p "$PORT")
SCP_OPTS=(-P "$PORT")
if [ -f "$KEY_PATH" ]; then
    SSH_OPTS+=(-i "$KEY_PATH")
    SCP_OPTS+=(-i "$KEY_PATH")
fi

echo ">> Copying haproxy.cfg to $USER@$HOST:$PORT"
scp "${SCP_OPTS[@]}" "$HAPROXY_CFG" "$USER@$HOST:/tmp/haproxy.cfg"

echo ">> Installing HAProxy, generating self-signed cert, deploying config..."
ssh "${SSH_OPTS[@]}" "$USER@$HOST" bash -s <<'REMOTE'
set -e

# 1. Install haproxy + openssl
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq haproxy openssl

# 2. Self-signed certificate (365 days, RSA 2048), bundled the way HAProxy
#    wants it: certificate followed by private key in ONE pem file.
sudo mkdir -p /etc/haproxy/certs
if [ ! -f /etc/haproxy/certs/lb-01.pem ]; then
    sudo openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -keyout /tmp/lb-01.key -out /tmp/lb-01.crt \
        -subj "/C=RW/ST=Kigali/L=Kigali/O=ALU/OU=WebInfra/CN=lb-01" \
        -addext "subjectAltName=DNS:lb-01,DNS:localhost,IP:172.25.0.10"
    sudo bash -c 'cat /tmp/lb-01.crt /tmp/lb-01.key > /etc/haproxy/certs/lb-01.pem'
    sudo rm -f /tmp/lb-01.key /tmp/lb-01.crt
    sudo chmod 600 /etc/haproxy/certs/lb-01.pem
    echo ">> Generated new self-signed cert at /etc/haproxy/certs/lb-01.pem"
else
    echo ">> Reusing existing cert at /etc/haproxy/certs/lb-01.pem"
fi

# 3. Deploy the config
sudo cp /tmp/haproxy.cfg /etc/haproxy/haproxy.cfg
rm -f /tmp/haproxy.cfg

# 4. Validate, then (re)start — the lab containers have no systemd,
#    so fall back through service/init.d/haproxy directly.
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo service haproxy restart 2>/dev/null \
  || sudo /etc/init.d/haproxy restart 2>/dev/null \
  || { sudo pkill haproxy 2>/dev/null || true; sudo haproxy -f /etc/haproxy/haproxy.cfg -D; }

echo ">> HAProxy is up:"
ps aux | grep '[h]aproxy' || true
REMOTE

echo
echo ">> Done. Verify from your host:"
echo "     curl -k  https://localhost:4443/      # TLS terminated at lb-01, self-signed => -k"
echo "     curl -kv https://localhost:4443/ 2>&1 | grep -E 'subject|issuer'"
echo "     curl -i  http://localhost:8082/       # should 301-redirect to https"
