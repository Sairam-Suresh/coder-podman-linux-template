FROM alpine:3.19

# Install nftables and iproute2 for network control
RUN apk add --no-cache nftables iproute2

# Copy the entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Run the entrypoint
ENTRYPOINT ["/entrypoint.sh"]