#!/bin/bash
set -euo pipefail

# Entry point for PinP container — create certs and Podman config then start service
HOME_DIR=${HOME:-/home/podman}
USERNAME=${USERNAME:-$(basename "$HOME_DIR")}

# Use cert dir under the podman user's home to avoid permission issues
CERT_DIR="$HOME_DIR/container-certs"

# Ensure home, cert and config directories exist
mkdir -p "$HOME_DIR" "$CERT_DIR" "$HOME_DIR/.config/containers"

# Try to download certs via Tailscale SOCKS5 if available, else fallback to direct
TS_SOCKS=127.0.0.1:1055
HOMELAB_BASE="https://homelab.tail4ef781.ts.net/stepca"

# Wait for homelab to be reachable (via Tailscale SOCKS5) before fetching certs
HOMELAB_HOST="https://homelab.tail4ef781.ts.net"
echo "Waiting for $HOMELAB_HOST to return HTTP 200..."
until curl --socks5-hostname "$TS_SOCKS" -sS -I --max-time 5 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$HOMELAB_HOST/" 2>/dev/null | head -n1 | grep -qE 'HTTP/[^ ]+ 200'; do
  echo "Waiting for $HOMELAB_HOST to return 200..."
  sleep 1
done
echo "$HOMELAB_HOST returned 200; continuing."

if curl --socks5-hostname "$TS_SOCKS" -fsSL -o "$CERT_DIR/root.crt" "$HOMELAB_BASE/roots.pem"; then
  echo "Downloaded root certificate via SOCKS5"
else
  echo "SOCKS5 fetch failed, trying direct download"
  curl -fsSL -o "$CERT_DIR/root.crt" "$HOMELAB_BASE/roots.pem" || true
fi

if curl --socks5-hostname "$TS_SOCKS" -fsSL -o "$CERT_DIR/intermed.crt" "$HOMELAB_BASE/intermediates.pem"; then
  echo "Downloaded intermediate certificate via SOCKS5"
else
  echo "SOCKS5 fetch failed, trying direct download"
  curl -fsSL -o "$CERT_DIR/intermed.crt" "$HOMELAB_BASE/intermediates.pem" || true
fi

# Create combined bundle if available
if [ -f "$CERT_DIR/root.crt" ] || [ -f "$CERT_DIR/intermed.crt" ]; then
  cat "$CERT_DIR/root.crt" "$CERT_DIR/intermed.crt" > "$CERT_DIR/ca-bundle.crt" 2>/dev/null || true
fi

# Write containers.conf in the user's config dir (use CERT_DIR variable)
cat > "$HOME_DIR/.config/containers/containers.conf" <<CONF
[engine]
compose_warning_logs = false

[containers]
userns = "keep-id"
volumes = [
  "${CERT_DIR}/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro",
  "${CERT_DIR}/ca-bundle.crt:/etc/pki/tls/certs/ca-bundle.crt:ro",
  "${CERT_DIR}/ca-bundle.crt:/etc/ssl/cert.pem:ro"
]
env = [
  "NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt",
  "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt",
  "REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt",
  "CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt"
]

[build]
env = [
  "NODE_EXTRA_CA_CERTS=${CERT_DIR}/ca-bundle.crt",
  "SSL_CERT_FILE=${CERT_DIR}/ca-bundle.crt",
  "REQUESTS_CA_BUNDLE=${CERT_DIR}/ca-bundle.crt",
  "CURL_CA_BUNDLE=${CERT_DIR}/ca-bundle.crt"
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