FROM debian:13

SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

# Install baseline packages
RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
    bash \
    build-essential \
    containerd.io \
    curl \
    docker-ce \
    docker-ce-cli \
    docker-buildx-plugin \
    docker-compose-plugin \
    htop \
    jq \
    locales \
    man \
    pipx \
    python3 \
    python3-pip \
    software-properties-common \
    sudo \
    systemd \
    systemd-sysv \
    unzip \
    vim \
    wget \
    rsync \
    iproute2 && \
# Install latest Git using their official PPA
    add-apt-repository ppa:git-core/ppa && \
    apt-get install --yes git \
    && rm -rf /var/lib/apt/lists/*

# Generate the desired locale (en_US.UTF-8)
RUN locale-gen en_US.UTF-8

# Make typing unicode characters in the terminal work.
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Add coder user
RUN useradd coder \
    --create-home \
    --shell=/bin/bash \
    --groups=docker \
    --uid=1000 \
    --user-group && \
    echo "coder ALL=(ALL) NOPASSWD:ALL" >>/etc/sudoers.d/nopasswd

# 1. Update APT, install podman, fuse-overlayfs, and uidmap (required for rootless on Debian)
RUN apt-get update && apt-get install -y \
    podman \
    fuse-overlayfs \
    uidmap \
    && rm -rf /var/lib/apt/lists/*

# 2. Create the 'coder' user with a home directory and configure subuid/subgid
RUN echo "coder:10000:5000" > /etc/subuid && \
    echo "coder:10000:5000" > /etc/subgid

# 3. Define volumes mapped to the new 'coder' user
VOLUME /var/lib/containers
VOLUME /home/coder/.local/share/containers

# 4. Add configuration files directly to the 'coder' user's config path
ADD https://raw.githubusercontent.com/containers/libpod/master/contrib/podmanimage/stable/containers.conf /etc/containers/containers.conf
ADD https://raw.githubusercontent.com/containers/libpod/master/contrib/podmanimage/stable/podman-containers.conf /home/coder/.config/containers/containers.conf

# 5. Fix permissions for the 'coder' user, chmod containers.conf, and adjust storage.conf to enable Fuse storage
RUN chown coder:coder -R /home/coder && \
    chmod 644 /etc/containers/containers.conf && \
    sed -i -e 's|^#mount_program|mount_program|g' \
           -e '/additionalimage.*/a "/var/lib/shared",' \
           -e 's|^mountopt[[:space:]]*=.*$|mountopt = "nodev,fsync=0"|g' \
           /etc/containers/storage.conf

# 6. Set up shared directories and lock files
RUN mkdir -p /var/lib/shared/overlay-images \
             /var/lib/shared/overlay-layers \
             /var/lib/shared/vfs-images \
             /var/lib/shared/vfs-layers && \
    touch /var/lib/shared/overlay-images/images.lock \
          /var/lib/shared/overlay-layers/layers.lock \
          /var/lib/shared/vfs-images/images.lock \
          /var/lib/shared/vfs-layers/layers.lock

ENV _CONTAINERS_USERNS_CONFIGURED=""
ENV DOCKER_HOST=unix:///run/user/1000/podman/podman.sock

USER coder

RUN pipx ensurepath # adds user's bin directory to PATH