# ==============================================================================
# STAGE 1: WORKSPACE (Base CLI-only Workspace with Remote Podman Wrapper)
# ==============================================================================
FROM debian:13 AS workspace

USER root

SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
    bash \
    ca-certificates \
    curl \
    git \
    direnv \
    vim \
    jq \
    locales \
    openssh-client \
    procps \
    sudo \
    xz-utils && \
    rm -rf /var/lib/apt/lists/*

# Generate the desired locale (en_US.UTF-8)
RUN if [ -f /etc/locale.gen ]; then \
        sed -i -e '/en_US.UTF-8/s/^# *//' /etc/locale.gen || true; \
    fi && \
    locale-gen en_US.UTF-8 || true && \
    update-locale LANG=en_US.UTF-8 || true

# Make typing unicode characters in the terminal work.
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Silence direnv's noisy exports globally
ENV DIRENV_LOG_FORMAT=""

# Install Node.js (needed for devcontainer support)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
      apt-get install -y nodejs && \
      rm -rf /var/lib/apt/lists/*

RUN echo "prefix=/home/coder/.local" > /etc/npmrc

# Add coder user
RUN useradd coder \
    --create-home \
    --shell=/bin/bash \
    --uid=1000 \
    --user-group && \
    echo "coder ALL=(ALL) NOPASSWD:ALL" >>/etc/sudoers.d/nopasswd

RUN mkdir -p /home/coder/.local/bin /home/coder/.local/lib && \
    chown -R coder:coder /home/coder/.local

USER coder

# Point Nix clients directly to the mounted socket of our shared Nix Daemon service
ENV NIX_REMOTE=unix:///nix/var/nix/daemon-socket/socket
ENV PATH=/home/coder/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/home/coder/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games
# Define globally for standard reference
ENV CERT_DIR=/home/coder/.local/share/ca-certificates

# Dynamically source the Nix profile if the shared store gets mounted at runtime & enable direnv
RUN echo 'if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh; fi' >> ~/.bashrc && \
    echo 'if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix.sh ]; then . /nix/var/nix/profiles/default/etc/profile.d/nix.sh; fi' >> ~/.bashrc && \
    echo 'if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh; fi' >> ~/.profile && \
    echo 'if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix.sh ]; then . /nix/var/nix/profiles/default/etc/profile.d/nix.sh; fi' >> ~/.profile && \
    echo 'export NIX_REMOTE=unix:///nix/var/nix/daemon-socket/socket' >> ~/.bashrc && \
    echo 'eval "$(direnv hook bash)"' >> ~/.bashrc && \
    echo 'export DIRENV_LOG_FORMAT=""' >> ~/.bashrc

# Ensure system-wide environments also have NIX_REMOTE, NPM configuration, and direnv presets
USER root
RUN echo 'export NIX_REMOTE=unix:///nix/var/nix/daemon-socket/socket' >> /etc/bash.bashrc && \
    echo 'if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh; fi' >> /etc/bash.bashrc && \
    echo 'if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix.sh ]; then . /nix/var/nix/profiles/default/etc/profile.d/nix.sh; fi' >> /etc/bash.bashrc && \
    echo 'export NIX_REMOTE=unix:///nix/var/nix/daemon-socket/socket' >> /etc/profile.d/nix.sh && \
    echo 'export NPM_CONFIG_PREFIX="/home/coder/.local"' >> /etc/bash.bashrc && \
    echo 'export PATH="/home/coder/.local/bin:$PATH"' >> /etc/bash.bashrc && \
    echo 'export NPM_CONFIG_PREFIX="/home/coder/.local"' >> /etc/profile.d/npm.sh && \
    echo 'export PATH="/home/coder/.local/bin:$PATH"' >> /etc/profile.d/npm.sh && \
    echo 'eval "$(direnv hook bash)"' >> /etc/bash.bashrc && \
    echo 'export DIRENV_LOG_FORMAT=""' >> /etc/bash.bashrc
USER coder

# Set up local prefix to allow global npm installations without root permissions
RUN export NPM_CONFIG_PREFIX="$HOME/.local" && \
        mkdir -p "$NPM_CONFIG_PREFIX" && \
        npm config set prefix "$NPM_CONFIG_PREFIX" && \
        if ! grep -q "NPM_CONFIG_PREFIX" ~/.bashrc; then \
            echo 'export NPM_CONFIG_PREFIX="$HOME/.local"' >> ~/.bashrc && \
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc; \
        fi && \
        export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"

RUN npm install -g @devcontainers/cli

USER root

# Create a clean symlink to point 'docker' directly to the system 'podman' executable path.
# This ensures standard container tooling compatibility without needing a script wrapper.
RUN ln -sf /usr/bin/podman /usr/local/bin/docker

USER coder

RUN mkdir -p "$HOME/.ssh" && \
    chmod 700 "$HOME/.ssh" && \
    (ssh-keyscan -H github.com >> "$HOME/.ssh/known_hosts" || true) && \
    chmod 600 "$HOME/.ssh/known_hosts" || true

USER root

# Standard default shell for the image
CMD ["/bin/bash"]


# ==============================================================================
# STAGE 2: WORKSPACE-PODMAN (CLI Workspace with Local Podman-in-Podman Engine)
# ==============================================================================
FROM workspace AS workspace-podman

USER root

# Install standard stable versions of Podman runtime dependencies.
# Note: Adding dbus-x11 and libcap2-bin to ensure robust capabilities and D-Bus integration in CLI.
RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
    podman \
    crun \
    conmon \
    netavark \
    fuse-overlayfs \
    catatonit \
    uidmap \
    slirp4netns \
    dbus-user-session \
    dbus-x11 \
    libcap2-bin \
    iptables && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/containers && touch /etc/containers/nodocker

# Configure Sub-UIDs and Sub-GIDs mapping rules for root and coder.
# Note: Since the outer container has at most 65,536 UIDs mapped by keep-id, our subordinate UID ranges
# must fit comfortably inside the [0 - 65535] limits to prevent operation-not-permitted errors during namespace writing.
RUN echo "root:10000:50000" > /etc/subuid && \
    echo "root:10000:50000" > /etc/subgid && \
    echo "coder:10000:50000" >> /etc/subuid && \
    echo "coder:10000:50000" >> /etc/subgid

# Create internal mount target for Host Image Cache sharing
RUN mkdir -p /var/lib/shared-host-cache && chown -R coder:coder /var/lib/shared-host-cache

# Setup system-level Podman configuration files
# Note: Added "/var/lib/shared-host-cache" to additionalimagestores dynamically to support image reuse.
# Added ignore_chown_errors = true and mountopt = "nodev,fsync=0" globally to ensure both systems read it.
RUN mkdir -p /etc/containers && \
    echo -e "[registries.search]\nregistries = ['docker.io', 'quay.io', 'gcr.io']" > /etc/containers/registries.conf && \
    echo -e "[storage]\ndriver = \"overlay\"\nrunroot = \"/run/containers/storage\"\ngraphroot = \"/var/lib/containers/storage\"\n\n[storage.options]\nadditionalimagestores = [\"/var/lib/shared-host-cache\"]\n\n[storage.options.overlay]\nmount_program = \"/usr/bin/fuse-overlayfs\"\nmountopt = \"nodev,fsync=0\"" > /etc/containers/storage.conf

# Write customized default containers.conf for PinP environments with hardcoded absolute paths & proxy servers
# Crucial Change: Force 'cgroup_manager = "cgroupfs"', 'events_backend = "file"', 'service_timeout = 0', and 'cgroups = "disabled"'.
# This registers standard configuration drivers but disables cgroups nested handling to run inside unprivileged sandboxes.
RUN cat <<'EOF' > /etc/containers/containers.conf
[engine]
compose_warning_logs = false
runtime = "crun"
database_backend = "sqlite"
cgroup_manager = "cgroupfs"
events_backend = "file"
service_timeout = 0

[containers]
cgroups = "disabled"
netns = "host"
net = "host"
userns = "keep-id"
seccomp_profile = "unconfined"
add_capabilities = ["SYS_PTRACE", "SYS_ADMIN"]
log_driver = "k8s-file"
privileged = true
default_capabilities = [
  "CHOWN",
  "DAC_OVERRIDE",
  "FOWNER",
  "FSETID",
  "KILL",
  "MKNOD",
  "NET_BIND_SERVICE",
  "NET_RAW",
  "SETFCAP",
  "SETGID",
  "SETPCAP",
  "SETUID",
  "SYS_CHROOT",
  "AUDIT_WRITE",
  "SYS_PTRACE",
  "SYS_ADMIN"
]
volumes = [
  "/home/coder/.local/share/ca-certificates/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro",
  "/home/coder/.local/share/ca-certificates/ca-bundle.crt:/etc/pki/tls/certs/ca-bundle.crt:ro",
  "/home/coder/.local/share/ca-certificates/ca-bundle.crt:/etc/ssl/cert.pem:ro"
]
env = [
  "NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt",
  "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt",
  "REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt",
  "CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt",
  "HTTP_PROXY=http://192.168.18.9:1055",
  "HTTPS_PROXY=http://192.168.18.9:1055",
  "ALL_PROXY=http://192.168.18.9:1055",
  "NO_PROXY=localhost,127.0.0.1,192.168.18.9",
  "http_proxy=http://192.168.18.9:1055",
  "https_proxy=http://192.168.18.9:1055",
  "all_proxy=http://192.168.18.9:1055",
  "no_proxy=localhost,127.0.0.1,192.168.18.9"
]
default_sysctls = []
EOF

# Setup unprivileged storage parent path ownership natively
RUN mkdir -p /home/coder/.local/share/containers && \
    chown -R coder:coder /home/coder/.local/share/containers

# Setup runtime working directories and global environment settings for Rootless execution
RUN mkdir -p /run/user/1000 && chown -R coder:coder /run/user/1000 && chmod 700 /run/user/1000
ENV XDG_RUNTIME_DIR=/run/user/1000

# Define Podman volumes for storage persistence
VOLUME /var/lib/containers
VOLUME /home/coder/.local/share/containers

ENV BUILDAH_ISOLATION=chroot

# Create the automated initialization script to expose the Rootless Podman socket inside the workspace
# Crucial Change: Completely omits command-line arguments (relying on containers.conf instead) to bypass argument splitting bugs.
RUN cat > /usr/local/bin/init-local-podman.sh <<'EOF' && \
    chmod +x /usr/local/bin/init-local-podman.sh
#!/bin/bash
set -euo pipefail

# Ensure D-Bus has a valid system machine-id and starting the service
echo "Configuring D-Bus environment..."
sudo dbus-uuidgen --ensure
if [ -f /etc/init.d/dbus ]; then
    sudo /etc/init.d/dbus start || true
fi

# Set up user runtime directory
export XDG_RUNTIME_DIR="/run/user/1000"
sudo mkdir -p "$XDG_RUNTIME_DIR"
sudo chown -R coder:coder "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

SOCKET_PATH="/var/run/docker.sock"
USER_SOCKET="/run/user/1000/podman/podman.sock"

echo "Initializing rootless Podman socket..."

# Ensure we start with a clean runtime socket state
sudo rm -f "$SOCKET_PATH"
rm -rf "/run/user/1000/podman"
mkdir -p "/run/user/1000/podman"
chmod 700 "/run/user/1000/podman"

# Crucial Change: Clear remote configuration parameters globally to avoid client-only locks
unset CONTAINER_HOST
unset CONTAINER_CONNECTION

# Launch the system service in the background as the rootless 'coder' user (no sudo)
podman system service --time=0 >/tmp/podman-service.stdout 2>/tmp/podman-service.stderr &
SERVICE_PID=$!

# Wait for the user socket to initiate
SOCKET_FOUND=0
for i in {1..25}; do
    if [ -S "$USER_SOCKET" ]; then
        SOCKET_FOUND=1
        break
    fi
    sleep 0.2
done

if [ "$SOCKET_FOUND" -eq 1 ]; then
    # Expose the user-owned socket to /var/run/docker.sock via symlink for developer tool compatibility
    sudo ln -sf "$USER_SOCKET" "$SOCKET_PATH"
    sudo chmod 0666 "$SOCKET_PATH" || true
    echo "Rootless Podman socket active and linked to $SOCKET_PATH successfully."
else
    echo "Error: Rootless Podman socket failed to initialize." >&2
    echo "=========================================================" >&2
    echo "                  PODMAN TROUBLESHOOTING                 " >&2
    echo "=========================================================" >&2
    echo "1. Verify the outer container has permission to use namespaces." >&2
    echo "   (Ensure it is run with --privileged or --cap-add=SYS_ADMIN)" >&2
    echo "2. Check if /dev/fuse is accessible for fuse-overlayfs." >&2
    echo "   (Try running the outer container with --device /dev/fuse)" >&2
    echo "=========================================================" >&2
    echo "--- Podman Service Error Log ---" >&2
    if [ -f /tmp/podman-service.stderr ]; then
        cat /tmp/podman-service.stderr >&2
    fi
    echo "=========================================================" >&2
    exit 1
fi
EOF

USER coder
CMD ["/bin/bash"]


# ==============================================================================
# STAGE 3: WORKSPACE-DESKTOP (Desktop Environment, Remote Podman Wrapper)
# ==============================================================================
FROM workspace AS workspace-desktop

USER root

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    text_packages=(dbus-x11 libdatetime-perl openssl ssl-cert xfce4 xfce4-goodies) && \
    apt-get install -y --no-install-recommends --no-install-suggests "${text_packages[@]}"

RUN set -eux; \
    curl -fsSL -o /root/kasmvncserver_bookworm_1.3.2_amd64.deb https://github.com/kasmtech/KasmVNC/releases/download/v1.3.2/kasmvncserver_bookworm_1.3.2_amd64.deb; \
    curl -fsSL -o /tmp/google-chrome-stable_current_amd64.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y /root/kasmvncserver_bookworm_1.3.2_amd64.deb /tmp/google-chrome-stable_current_amd64.deb; \
    rm -f /root/kasmvncserver_bookworm_1.3.2_amd64.deb /tmp/google-chrome-stable_current_amd64.deb; \
    rm -rf /var/lib/apt/lists/*

# Wrapper to ensure Chrome runs well inside containers (disable /dev/shm usage etc.)
RUN cat > /usr/local/bin/google-chrome <<'EOF' && \
    chmod +x /usr/local/bin/google-chrome
#!/bin/sh
exec /usr/bin/google-chrome "$@" --disable-dev-shm-usage
EOF

# Setting the required environment variables
ARG USER=coder
RUN echo 'LANG=en_US.UTF-8' >> /etc/default/locale; \
    echo 'export GNOME_SHELL_SESSION_MODE=debian' > /home/$USER/.xsessionrc; \
    echo 'export XDG_CURRENT_DESKTOP=xfce' >> /home/$USER/.xsessionrc; \
    echo 'export XDG_SESSION_TYPE=x11' >> /home/$USER/.xsessionrc;

USER coder
CMD ["/bin/bash"]


# ==============================================================================
# STAGE 4: WORKSPACE-DESKTOP-PODMAN (Desktop Environment with Local Podman-in-Podman Engine)
# ==============================================================================
FROM workspace-podman AS workspace-desktop-podman

USER root

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    text_packages_podman=(dbus-x11 libdatetime-perl openssl ssl-cert xfce4 xfce4-goodies) && \
    apt-get install -y --no-install-recommends --no-install-suggests "${text_packages_podman[@]}"

RUN set -eux; \
    curl -fsSL -o /root/kasmvncserver_bookworm_1.3.2_amd64.deb https://github.com/kasmtech/KasmVNC/releases/download/v1.3.2/kasmvncserver_bookworm_1.3.2_amd64.deb; \
    curl -fsSL -o /tmp/google-chrome-stable_current_amd64.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y /root/kasmvncserver_bookworm_1.3.2_amd64.deb /tmp/google-chrome-stable_current_amd64.deb; \
    rm -f /root/kasmvncserver_bookworm_1.3.2_amd64.deb /tmp/google-chrome-stable_current_amd64.deb; \
    rm -rf /var/lib/apt/lists/*

# Wrapper to ensure Chrome runs well inside containers (disable /dev/shm usage etc.)
RUN cat > /usr/local/bin/google-chrome <<'EOF' && \
    chmod +x /usr/local/bin/google-chrome
#!/bin/sh
exec /usr/bin/google-chrome "$@" --disable-dev-shm-usage
EOF

# Setting the required environment variables
ARG USER=coder
RUN echo 'LANG=en_US.UTF-8' >> /etc/default/locale; \
    echo 'export GNOME_SHELL_SESSION_MODE=debian' > /home/$USER/.xsessionrc; \
    echo 'export XDG_CURRENT_DESKTOP=xfce' >> /home/$USER/.xsessionrc; \
    echo 'export XDG_SESSION_TYPE=x11' >> /home/$USER/.xsessionrc;

USER coder
CMD ["/bin/bash"]