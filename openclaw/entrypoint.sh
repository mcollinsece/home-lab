#!/bin/sh
set -e
# Fix .credentials.json read access for the node user (uid 1000).
# This script runs as root; in rootless Podman root = host uid 1000 (debian),
# so we own these files and the chmod doesn't touch host root-owned data.
chmod 644 /home/node/.claude/.credentials.json 2>/dev/null || true
chmod 644 /home/node/.claude.json 2>/dev/null || true
# Drop to node and exec the original entry (tini → node openclaw.mjs gateway).
# node user can now read .credentials.json AND claude allows --dangerously-skip-permissions.
exec runuser -u node -- /usr/bin/tini -s -- "$@"
