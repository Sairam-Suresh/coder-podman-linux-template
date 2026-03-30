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
    procps \
    unzip \
    vim \
    wget \
    rsync \
    iproute2 \
    podman-remote \
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

USER coder

RUN pipx ensurepath