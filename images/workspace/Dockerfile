FROM debian:13

SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

# Install baseline packages
RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
    bash \
    build-essential \
    curl \
    htop \
    jq \
    locales \
    man \
    pipx \
    python3 \
    python3-pip \
    sudo \
    unzip \
    vim \
    wget \
    rsync \
    iproute2 \
    git \
    && rm -rf /var/lib/apt/lists/*

# Generate the desired locale (en_US.UTF-8)
# Ensure en_US.UTF-8 is enabled and generated to avoid setlocale warnings
RUN if [ -f /etc/locale.gen ]; then \
        sed -i -e '/en_US.UTF-8/s/^# *//' /etc/locale.gen || true; \
    fi && \
    locale-gen en_US.UTF-8 || true && \
    update-locale LANG=en_US.UTF-8 || true

# Make typing unicode characters in the terminal work.
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Add coder user
RUN useradd coder \
    --create-home \
    --shell=/bin/bash \
    --uid=1000 \
    --user-group && \
    echo "coder ALL=(ALL) NOPASSWD:ALL" >>/etc/sudoers.d/nopasswd

# 1. Update APT, install podman, fuse-overlayfs, and uidmap (required for rootless on Debian)
RUN apt-get update && apt-get install -y \
    podman \
    fuse-overlayfs \
    podman-compose \
    uidmap \
    && \
    # Ensure newuidmap/newgidmap are owned by root and setuid so rootless userns setup can work
    if command -v newuidmap >/dev/null 2>&1; then \
        chown root:root $(command -v newuidmap) && chmod 4755 $(command -v newuidmap); \
    fi && \
    if command -v newgidmap >/dev/null 2>&1; then \
        chown root:root $(command -v newgidmap) && chmod 4755 $(command -v newgidmap); \
    fi && \
    rm -rf /var/lib/apt/lists/*

# 2. Create the 'coder' user with a home directory and configure subuid/subgid
RUN echo -e "root:1:65535\ncoder:1:999\ncoder:1001:64535" > /etc/subuid && \
    echo -e "root:1:65535\ncoder:1:999\ncoder:1001:64535" > /etc/subgid


# 4. Add configuration files directly to the 'coder' user's config path
ADD https://raw.githubusercontent.com/containers/image_build/refs/heads/main/podman/containers.conf /etc/containers/containers.conf
ADD https://raw.githubusercontent.com/containers/image_build/refs/heads/main/podman/podman-containers.conf /home/coder/.config/containers/containers.conf

# 5. Fix permissions for the 'coder' user, chmod containers.conf, and populate storage.conf to enable Fuse storage
RUN chown coder:coder -R /home/coder && \
    chmod 644 /etc/containers/containers.conf && \
    mkdir -p /etc/containers && \
    # Prefer the packaged default if present; otherwise create a minimal config suitable for rootless/fuse-overlay
    if [ -f /usr/share/containers/storage.conf ]; then \
        sed -e 's|^#mount_program|mount_program|g' \
            -e '/additionalimage.*/a "/var/lib/shared",' \
            -e 's|^mountopt[[:space:]]*=.*$|mountopt = "nodev,fsync=0"|g' \
            /usr/share/containers/storage.conf > /etc/containers/storage.conf ; \
    else \
        # create storage.conf without a heredoc (avoids Dockerfile parsing issues)
        printf '%s\n' '[storage]' \
            'driver = "overlay"' \
            'runroot = "/run/containers/storage"' \
            'graphroot = "/var/lib/containers/storage"' \
            '' \
            '[storage.options]' \
            'mount_program = "/usr/bin/fuse-overlayfs"' \
            'additionalimagestores = ["/var/lib/shared"]' \
            'mountopt = "nodev,fsync=0"' > /etc/containers/storage.conf && \
        # ensure the same sed transformations are applied (safe no-op if already correct)
        sed -i -e 's|^#mount_program|mount_program|g' \
               -e '/additionalimage.*/a "/var/lib/shared",' \
               -e 's|^mountopt[[:space:]]*=.*$|mountopt = "nodev,fsync=0"|g' \
               /etc/containers/storage.conf || true ; \
    fi && \
    chmod 644 /etc/containers/storage.conf

# Setup internal Podman to pass subscriptions down from host to internal container
RUN printf '/run/secrets/etc-pki-entitlement:/run/secrets/etc-pki-entitlement\n/run/secrets/rhsm:/run/secrets/rhsm\n' > /etc/containers/mounts.conf

# Note VOLUME options must always happen after the chown call above
VOLUME /var/lib/containers
VOLUME /home/coder/.local/share/containers

# 6. Set up shared directories and lock files
RUN mkdir -p /var/lib/shared/overlay-images \
             /var/lib/shared/overlay-layers \
             /var/lib/shared/vfs-images \
             /var/lib/shared/vfs-layers && \
    touch /var/lib/shared/overlay-images/images.lock \
          /var/lib/shared/overlay-layers/layers.lock \
          /var/lib/shared/vfs-images/images.lock \
          /var/lib/shared/vfs-layers/layers.lock

ENV _CONTAINERS_USERNS_CONFIGURED="" \
    DOCKER_HOST=unix:///run/user/1000/podman/podman.sock \
    BUILDAH_ISOLATION=chroot

USER coder

# Ensure pipx can create its log/state directory as root before switching user
# RUN mkdir -p /home/coder/.local/state && chown -R coder:coder /home/coder/.local || true

# RUN pipx ensurepath