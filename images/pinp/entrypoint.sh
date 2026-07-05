#!/bin/bash
set -euo pipefail

# Running natively as root inside the sidecar namespace
HOME_DIR="/root"
CERT_DIR="$HOME_DIR/container-certs"

# Ensure directories exist
mkdir -p "$HOME_DIR" "$CERT_DIR" "$HOME_DIR/.config/containers"

# Default proxy settings for containers launched by nested Podman.
PODMAN_PROXY_HOST=${PODMAN_PROXY_HOST:-192.168.18.9}
PODMAN_PROXY_PORT=${PODMAN_PROXY_PORT:-1055}

export HTTP_PROXY=${PODMAN_HTTP_PROXY:-http://${PODMAN_PROXY_HOST}:${PODMAN_PROXY_PORT}}
export HTTPS_PROXY=${PODMAN_HTTPS_PROXY:-${HTTP_PROXY}}
export ALL_PROXY=${PODMAN_ALL_PROXY:-socks5://${PODMAN_PROXY_HOST}:${PODMAN_PROXY_PORT}}
export NO_PROXY=${PODMAN_NO_PROXY:-127.0.0.1,localhost,::1}
export http_proxy="$HTTP_PROXY"
export https_proxy="$HTTPS_PROXY"
export all_proxy="$ALL_PROXY"
export no_proxy="$NO_PROXY"

# Wait for healthcheck endpoint to be reachable
HOMELAB_HOST="http://healthcheck.service.internal"
echo "Waiting for $HOMELAB_HOST..."
until curl --socks5-hostname 192.168.18.9:1055 -sS -I --max-time 5 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$HOMELAB_HOST/" 2>/dev/null | head -n1 | grep -qE 'HTTP/[^ ]+ 200'; do
  sleep 1
done

curl --socks5-hostname 192.168.18.9:1055 -fsSL -o "$CERT_DIR/root.crt" "http://stepca.service.internal/roots.pem" || true
curl --socks5-hostname 192.168.18.9:1055 -fsSL -o "$CERT_DIR/intermed.crt" "http://stepca.service.internal/intermediates.pem" || true

if [ -f "$CERT_DIR/root.crt" ] || [ -f "$CERT_DIR/intermed.crt" ]; then
  cat "$CERT_DIR/root.crt" "$CERT_DIR/intermed.crt" > "$CERT_DIR/ca-bundle.crt" 2>/dev/null || true
fi

# Write containers.conf
cat > "$HOME_DIR/.config/containers/containers.conf" <<CONF
[engine]
compose_warning_logs = false

[containers]
netns = "host"
net = "host"
seccomp_profile = "unconfined"
add_capabilities = ["SYS_PTRACE", "SYS_ADMIN"]
volumes = [
  "${CERT_DIR}/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro",
  "${CERT_DIR}/ca-bundle.crt:/etc/pki/tls/certs/ca-bundle.crt:ro",
  "${CERT_DIR}/ca-bundle.crt:/etc/ssl/cert.pem:ro",
]
env = [
  "NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt",
  "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt",
  "REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt",
  "CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt",
  "HTTP_PROXY=${HTTP_PROXY}",
  "HTTPS_PROXY=${HTTPS_PROXY}",
  "ALL_PROXY=${ALL_PROXY}",
  "NO_PROXY=${NO_PROXY}",
  "http_proxy=${http_proxy}",
  "https_proxy=${https_proxy}",
  "all_proxy=${all_proxy}",
  "no_proxy=${no_proxy}"
]
CONF

mkdir -p /etc/containers
cat > /etc/containers/storage.conf <<EOF
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
EOF

# Initialize and expose socket
SOCKET_PATH="/tmp/podman/podman.sock"
mkdir -p "$(dirname "$SOCKET_PATH")"
rm -f "$SOCKET_PATH"
podman system service --time 0 unix://"$SOCKET_PATH" &
SERVICE_PID=$!
echo "Waiting for Podman socket to initialize..."
until [ -S "$SOCKET_PATH" ]; do
  sleep 0.2
done

chmod 0666 "$SOCKET_PATH"
echo "Podman socket permissions opened to 0666 successfully."

wait $SERVICE_PID