FROM localhost/base_workspace:local

USER root

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    apt-get install -y --no-install-recommends --no-install-suggests dbus-x11 libdatetime-perl openssl ssl-cert xfce4 xfce4-goodies && \
    rm /run/reboot-required* || true && \
    rm -rf /var/lib/apt/lists/*

RUN wget -P /root https://github.com/kasmtech/KasmVNC/releases/download/v1.3.2/kasmvncserver_bookworm_1.3.2_amd64.deb && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y /root/kasmvncserver_bookworm_1.3.2_amd64.deb && \
    wget -O /tmp/google-chrome-stable_current_amd64.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/google-chrome-stable_current_amd64.deb

# Setting the required environment variables
ARG USER=coder
RUN echo 'LANG=en_US.UTF-8' >> /etc/default/locale; \
    echo 'export GNOME_SHELL_SESSION_MODE=debian' > /home/$USER/.xsessionrc; \
    echo 'export XDG_CURRENT_DESKTOP=xfce' >> /home/$USER/.xsessionrc; \
    echo 'export XDG_SESSION_TYPE=x11' >> /home/$USER/.xsessionrc;

USER coder