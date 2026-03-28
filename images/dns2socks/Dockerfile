FROM debian:bookworm-slim AS builder

# Install required dependencies to download and extract the archive
RUN apt-get update && \
    apt-get install -y wget unzip && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /tmp

# Download the specific release and unzip it
RUN wget -q https://github.com/tun2proxy/dns2socks/releases/download/v0.2.3/dns2socks-x86_64-unknown-linux-gnu.zip && \
    unzip dns2socks-x86_64-unknown-linux-gnu.zip && \
    ls -la /tmp/

# --- Runtime Stage ---
FROM debian:bookworm-slim

# Install CA certificates in case secure remote connections are needed
RUN apt-get update && \
    apt-get install -y ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Copy the extracted binary and library
COPY --from=builder /tmp/dns2socks /opt/dns2socks/dns2socks
COPY --from=builder /tmp/libdns2socks_core.so /opt/dns2socks/libdns2socks_core.so
RUN chmod +x /opt/dns2socks/dns2socks

# Make sure the library (.so) is discoverable and the binary is in the PATH
ENV LD_LIBRARY_PATH="/opt/dns2socks:$LD_LIBRARY_PATH"
ENV PATH="/opt/dns2socks:$PATH"

# Add the entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Expose standard DNS ports
EXPOSE 53/tcp 53/udp

# Use the wrapper script as the entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]