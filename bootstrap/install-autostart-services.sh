#!/usr/bin/env bash
#
# install-autostart-services.sh — install the systemd --user units that bring the
# stack back after a reboot, plus the daily OAuth credential-sync timers.
#
# Closes the reboot gaps documented in docs/cloud/reboot-autostart.md:
#   - sandbox CONTAINERS return (restart: unless-stopped) but the uvicorn wrappers
#     (started via `docker exec -d`) and the director's OpenClaw/SSH-tunnel do not.
#
# Units installed (all `systemd --user`, linger keeps them alive after logout):
#   nemoclaw-director.service  -> nemoclaw <name> recover
#   claude-wrapper.service     -> setup-claude-revproxy.sh
#   grok-wrapper.service       -> setup-grok-wrapper.sh
#   sync-claude-creds.timer    -> daily sync-claude-credentials.sh
#   sync-grok-creds.timer      -> daily sync-grok-credentials.sh
# (openclaw-socat-relay.service is installed by setup-openclaw-relay.sh.)
#
#   bootstrap/install-autostart-services.sh [--name <sandbox>]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEMO_NAME="my-assistant"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NEMO_NAME="$2"; shift 2 ;;
    -h|--help) echo "usage: install-autostart-services.sh [--name <sandbox>]"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
UD="$HOME/.config/systemd/user"
mkdir -p "$UD"

# Ensure linger so user units run without an active login session.
loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes' || sudo loginctl enable-linger "$USER"

say "Writing systemd --user units"

cat > "$UD/nemoclaw-director.service" <<EOF
[Unit]
Description=Recover NemoClaw OpenClaw director (openclaw + SSH tunnel + port-forward)
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/sg docker -c "%h/.npm-global/bin/nemoclaw ${NEMO_NAME} recover"
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
EOF

cat > "$UD/claude-wrapper.service" <<EOF
[Unit]
Description=Claude Code wrapper (uvicorn :8000 in claude-revproxy sandbox)
After=docker.service nemoclaw-director.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/sg docker -c "${REPO_DIR}/bootstrap/setup-claude-revproxy.sh"
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
EOF

cat > "$UD/grok-wrapper.service" <<EOF
[Unit]
Description=Grok wrapper (uvicorn :8001 in grok-wrapper sandbox)
After=docker.service nemoclaw-director.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/sg docker -c "${REPO_DIR}/bootstrap/setup-grok-wrapper.sh"
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
EOF

# Daily OAuth credential refresh (tokens expire).
cat > "$UD/sync-claude-creds.service" <<EOF
[Unit]
Description=Sync Claude OAuth credentials to claude-revproxy sandbox
[Service]
Type=oneshot
ExecStart=/usr/bin/sg docker -c "${REPO_DIR}/bootstrap/sync-claude-credentials.sh"
EOF
cat > "$UD/sync-claude-creds.timer" <<'EOF'
[Unit]
Description=Daily Claude credential sync
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF

cat > "$UD/sync-grok-creds.service" <<EOF
[Unit]
Description=Sync Grok OAuth credentials to grok-wrapper sandbox
[Service]
Type=oneshot
ExecStart=/usr/bin/sg docker -c "${REPO_DIR}/bootstrap/sync-grok-credentials.sh"
EOF
cat > "$UD/sync-grok-creds.timer" <<'EOF'
[Unit]
Description=Daily Grok credential sync
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable nemoclaw-director.service claude-wrapper.service grok-wrapper.service
systemctl --user enable --now sync-claude-creds.timer sync-grok-creds.timer

say "Enabled units:"
systemctl --user is-enabled nemoclaw-director.service claude-wrapper.service grok-wrapper.service \
  sync-claude-creds.timer sync-grok-creds.timer openclaw-socat-relay.service openshell-gateway.service 2>&1 \
  | paste -d' ' <(printf '%s\n' director claude grok claude-timer grok-timer socat gateway) - || true
echo
echo "Reboot recovery order: docker -> nemoclaw-director -> claude/grok wrappers; socat relay auto-retries."
echo "Validate after a real reboot (see docs/cloud/reboot-autostart.md)."
