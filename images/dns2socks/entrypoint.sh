#!/bin/sh
set -e

# If the user manually passes arguments (e.g. `docker run ... dns2socks -h`), run them directly
if [ "$#" -gt 0 ]; then
    exec dns2socks "$@"
fi

# Otherwise, map Environment Variables to the binary's arguments
# Using `set --` to safely build an array of command-line arguments in POSIX sh

set -- -l "${LISTEN_ADDR:-0.0.0.0:53}"
set -- "$@" -d "${DNS_REMOTE_SERVER:-8.8.8.8:53}"
set -- "$@" -s "${SOCKS5_SETTINGS:-socks5://127.0.0.1:1080}"
set -- "$@" -v "${VERBOSITY:-info}"

if [ -n "$TIMEOUT" ]; then
    set -- "$@" -t "$TIMEOUT"
fi

if [ "$FORCE_TCP" = "true" ] || [ "$FORCE_TCP" = "1" ]; then
    set -- "$@" -f
fi

if [ "$CACHE_RECORDS" = "true" ] || [ "$CACHE_RECORDS" = "1" ]; then
    set -- "$@" -c
fi

echo "Starting dns2socks..."
# `exec` replaces the shell process with dns2socks so it receives system signals correctly
exec dns2socks "$@"