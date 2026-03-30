FROM quay.io/podman/stable:latest

SHELL ["/bin/bash", "-c"]

# Copy entrypoint provided by the repo and make it executable
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Run container as the existing podman user (UID 1000) and set HOME
USER podman
ENV HOME=/home/podman

ENTRYPOINT ["/entrypoint.sh"]