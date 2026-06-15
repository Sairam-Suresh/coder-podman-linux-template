FROM quay.io/podman/stable:latest

SHELL ["/bin/bash", "-c"]

USER root

# Clear any default mappings, write the clean rootless range, and migrate the system
RUN printf "podman:100000:131072\n" | tee /etc/subuid /etc/subgid && \
    podman system migrate

# Copy entrypoint provided by the repo and make it executable
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Run container as the existing podman user (UID 1000) and set HOME
USER podman
ENV HOME=/home/podman

ENTRYPOINT ["/entrypoint.sh"]