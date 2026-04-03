#!/bin/bash
set -euo pipefail

# Entry point for PinP container — create certs and Podman config then start service
HOME_DIR=${HOME:-/home/podman}
USERNAME=${USERNAME:-$(basename "$HOME_DIR")}

# Use cert dir under the podman user's home to avoid permission issues
CERT_DIR="$HOME_DIR/container-certs"

# Default rootless network backend for podman (override with PODMAN_NETWORK_MODE)
NET_MODE=${PODMAN_NETWORK_MODE:-${NETWORK_MODE:-pasta}}
if [ "$NET_MODE" != "pasta" ] && [ "$NET_MODE" != "slirp4netns" ]; then
  echo "Unsupported PODMAN_NETWORK_MODE '$NET_MODE'; falling back to pasta"
  NET_MODE="pasta"
fi

# Ensure home, cert and config directories exist
mkdir -p "$HOME_DIR" "$CERT_DIR" "$HOME_DIR/.config/containers"

# Try to download certs via Tailscale SOCKS5 if available, else fallback to direct
TS_SOCKS=127.0.0.1:1055
HOMELAB_BASE="http://stepca.service.internal"

# Default proxy settings for containers launched by nested Podman.
PODMAN_PROXY_HOST=${PODMAN_PROXY_HOST:-localhost}
PODMAN_PROXY_PORT=${PODMAN_PROXY_PORT:-1055}
PODMAN_HTTP_PROXY=${PODMAN_HTTP_PROXY:-http://${PODMAN_PROXY_HOST}:${PODMAN_PROXY_PORT}}
PODMAN_HTTPS_PROXY=${PODMAN_HTTPS_PROXY:-${PODMAN_HTTP_PROXY}}
PODMAN_ALL_PROXY=${PODMAN_ALL_PROXY:-socks5://${PODMAN_PROXY_HOST}:${PODMAN_PROXY_PORT}}
PODMAN_NO_PROXY=${PODMAN_NO_PROXY:-127.0.0.1,localhost,::1}

# Wait for healthcheck endpoint to be reachable (via Tailscale SOCKS5) before fetching certs
HOMELAB_HOST="http://healthcheck.service.internal"
echo "Waiting for $HOMELAB_HOST (healthcheck) to be reachable via SOCKS5..."
until curl --socks5-hostname 127.0.0.1:1055 -sS -I --max-time 5 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$HOMELAB_HOST/" 2>/dev/null | head -n1 | grep -qE 'HTTP/[^ ]+ 200'; do
  echo "Waiting for $HOMELAB_HOST (healthcheck) to be reachable via SOCKS5..."
  sleep 1
done
echo "$HOMELAB_HOST reachable via SOCKS5; continuing."

if curl --socks5-hostname 127.0.0.1:1055 -fsSL -o "$CERT_DIR/root.crt" "http://stepca.service.internal/roots.pem"; then
  echo "Downloaded root certificate via SOCKS5"
else
  echo "Failed to download root certificate via SOCKS5; skipping (no direct fallback)"
fi

if curl --socks5-hostname 127.0.0.1:1055 -fsSL -o "$CERT_DIR/intermed.crt" "http://stepca.service.internal/intermediates.pem"; then
  echo "Downloaded intermediate certificate via SOCKS5"
else
  echo "Failed to download intermediate certificate via SOCKS5; skipping (no direct fallback)"
fi

# Create combined bundle if available
if [ -f "$CERT_DIR/root.crt" ] || [ -f "$CERT_DIR/intermed.crt" ]; then
  cat "$CERT_DIR/root.crt" "$CERT_DIR/intermed.crt" > "$CERT_DIR/ca-bundle.crt" 2>/dev/null || true
fi

# Write containers.conf in the user's config dir (use CERT_DIR variable)
cat > "$HOME_DIR/.config/containers/containers.conf" <<CONF
[engine]
compose_warning_logs = false

[network]
default_rootless_network_cmd = "${NET_MODE}"

[containers]
userns = "keep-id"
volumes = [
  "${CERT_DIR}/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro",
  "${CERT_DIR}/ca-bundle.crt:/etc/pki/tls/certs/ca-bundle.crt:ro",
  "${CERT_DIR}/ca-bundle.crt:/etc/ssl/cert.pem:ro",
  "/proc:/proc",
]
env = [
  "NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt",
  "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt",
  "REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt",
  "CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt",
  "HTTP_PROXY=${PODMAN_HTTP_PROXY}",
  "HTTPS_PROXY=${PODMAN_HTTPS_PROXY}",
  "ALL_PROXY=${PODMAN_ALL_PROXY}",
  "NO_PROXY=${PODMAN_NO_PROXY}",
  "http_proxy=${PODMAN_HTTP_PROXY}",
  "https_proxy=${PODMAN_HTTPS_PROXY}",
  "all_proxy=${PODMAN_ALL_PROXY}",
  "no_proxy=${PODMAN_NO_PROXY}"
]
default_sysctls = []

[build]
env = [
  "NODE_EXTRA_CA_CERTS=${CERT_DIR}/ca-bundle.crt",
  "SSL_CERT_FILE=${CERT_DIR}/ca-bundle.crt",
  "REQUESTS_CA_BUNDLE=${CERT_DIR}/ca-bundle.crt",
  "CURL_CA_BUNDLE=${CERT_DIR}/ca-bundle.crt",
  "HTTP_PROXY=${PODMAN_HTTP_PROXY}",
  "HTTPS_PROXY=${PODMAN_HTTPS_PROXY}",
  "ALL_PROXY=${PODMAN_ALL_PROXY}",
  "NO_PROXY=${PODMAN_NO_PROXY}",
  "http_proxy=${PODMAN_HTTP_PROXY}",
  "https_proxy=${PODMAN_HTTPS_PROXY}",
  "all_proxy=${PODMAN_ALL_PROXY}",
  "no_proxy=${PODMAN_NO_PROXY}"
]
CONF

# Write mounts.conf to instruct podman about host mount (used by some runtimes)
echo "${CERT_DIR}:${CERT_DIR}" > "$HOME_DIR/.config/containers/mounts.conf"

# If running as root, ensure files are owned by UID 1000 so the podman user can use them.
if [ "$(id -u)" -eq 0 ]; then
  chown -R 1000:1000 "$HOME_DIR/.config/containers" || true
  chown -R 1000:1000 "$CERT_DIR" || true
fi

# Start the Podman system service (foreground)
# Use unix socket under /tmp/podman (shared volume)
mkdir -p /tmp/podman
if [ "$(id -u)" -eq 0 ]; then
  chown 1000:1000 /tmp/podman || true
fi

exec podman system service --time 0 unix:///tmp/podman/podman.sock