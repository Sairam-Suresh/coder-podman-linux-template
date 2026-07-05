FROM quay.io/podman/stable:latest

SHELL ["/bin/bash", "-c"]

USER root

RUN printf "root:1:131072\npodman:1:131072\n" | tee /etc/subuid /etc/subgid

# Copy entrypoint provided by the repo and make it executable
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER root
ENV HOME=/root

ENTRYPOINT ["/entrypoint.sh"]