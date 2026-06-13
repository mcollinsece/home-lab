#!/usr/bin/env bash
#
# new-claude-sandbox.sh — spin up an auth-ready Claude Code OpenShell sandbox
#
# Usage:
#   new-claude-sandbox.sh <name> [--bedrock] [--claudeai | --clone <src-sandbox>]
#
# Flags (composable — combine freely):
#   --bedrock              inject Bedrock keys from ~/home-lab/.secrets/bedrock.env
#   --claudeai             clone Claude.ai token from host ~/.claude/.credentials.json
#   --clone <src>          clone token from a running OpenShell sandbox (agent-agnostic)
#
# Examples:
#   new-claude-sandbox.sh worker-1 --bedrock
#   new-claude-sandbox.sh worker-1 --claudeai
#   new-claude-sandbox.sh worker-1 --clone claude-code
#   new-claude-sandbox.sh worker-1 --bedrock --claudeai
#   new-claude-sandbox.sh worker-1 --bedrock --clone claude-code
#
# See docs/current/todos.md for design notes (director/worker pattern, auth modes).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$REPO_DIR/openshell/policies/claude-code.yaml"
BEDROCK_ENV="$REPO_DIR/.secrets/bedrock.env"
HOST_CREDS="$HOME/.claude/.credentials.json"
HOST_SETTINGS="$HOME/.claude/settings.json"
BEDROCK_PROJECT_SETTINGS="$REPO_DIR/openshell/project-settings/bedrock-test.json"

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- parse args ---------------------------------------------------------------
SANDBOX_NAME=""
USE_BEDROCK=false
USE_CLAUDEAI=false
USE_CLONE=false
CLONE_SRC=""

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bedrock)  USE_BEDROCK=true; shift ;;
    --claudeai) USE_CLAUDEAI=true; shift ;;
    --clone)
      [[ $# -gt 1 ]] || die "--clone requires a source sandbox name"
      USE_CLONE=true; CLONE_SRC="$2"; shift 2 ;;
    -h|--help)  usage 0 ;;
    -*)         die "Unknown flag: $1" ;;
    *)
      [[ -z "$SANDBOX_NAME" ]] || die "Unexpected argument: $1"
      SANDBOX_NAME="$1"; shift ;;
  esac
done

[[ -n "$SANDBOX_NAME" ]] \
  || die "Usage: new-claude-sandbox.sh <name> [--bedrock] [--claudeai | --clone <src>]"
( $USE_CLAUDEAI && $USE_CLONE ) \
  && die "--claudeai and --clone are mutually exclusive (both clone auth; pick one)"

# ---- temp files — hold cloned credentials/settings, auto-cleaned on any exit --
TMPFILE=""
TMPFILE_SETTINGS=""
cleanup() {
  [[ -z "$TMPFILE"          || ! -f "$TMPFILE"          ]] || rm -f "$TMPFILE"
  [[ -z "$TMPFILE_SETTINGS" || ! -f "$TMPFILE_SETTINGS" ]] || rm -f "$TMPFILE_SETTINGS"
}
trap cleanup EXIT

# ---- preflight ----------------------------------------------------------------
say "Preflight checks"

openshell status 2>/dev/null | grep -qi 'connected' \
  || die "OpenShell gateway is not connected. Run: systemctl --user start openshell-gateway"
ok "OpenShell gateway connected"

[[ -f "$POLICY" ]] \
  || die "Policy file not found: $POLICY"
ok "Policy file present"

if $USE_BEDROCK; then
  [[ -r "$BEDROCK_ENV" ]] \
    || die "--bedrock: $BEDROCK_ENV not found.\n       Populate it from your password manager:\n         AWS_ACCESS_KEY_ID=AKIAxxxxx\n         AWS_SECRET_ACCESS_KEY=xxxxx\n         AWS_REGION=us-east-1"
  ok "Bedrock env file readable"
fi

if $USE_CLAUDEAI; then
  [[ -r "$HOST_CREDS" ]] \
    || die "--claudeai: $HOST_CREDS not found. Run 'claude login' on the host first."
  ok "Host .credentials.json readable"
  [[ -r "$HOST_SETTINGS" ]] \
    || die "--claudeai: $HOST_SETTINGS not found. Expected after first run of claude on the host."
  ok "Host settings.json readable"
fi

if $USE_CLONE; then
  openshell sandbox list 2>/dev/null | grep -q "$CLONE_SRC" \
    || die "--clone: sandbox '$CLONE_SRC' not found or not running"
  ok "Source sandbox '$CLONE_SRC' found"
fi

# ---- read credentials now (before create — fail fast) -------------------------
if $USE_CLAUDEAI; then
  say "Reading Claude.ai state from host director"
  TMPFILE="$(mktemp)"; chmod 600 "$TMPFILE"
  cp "$HOST_CREDS" "$TMPFILE"
  ok ".credentials.json copied"
  TMPFILE_SETTINGS="$(mktemp)"; chmod 600 "$TMPFILE_SETTINGS"
  cp "$HOST_SETTINGS" "$TMPFILE_SETTINGS"
  ok "settings.json copied (theme, skipDangerousModePermissionPrompt, onboarding state)"
fi

if $USE_CLONE; then
  say "Reading Claude state from sandbox '$CLONE_SRC'"
  TMPFILE="$(mktemp)"; chmod 600 "$TMPFILE"
  # try both filenames — .credentials.json (current) or credentials.json (older versions)
  if ! openshell sandbox exec -n "$CLONE_SRC" -- \
       sh -c 'cat /sandbox/.claude/.credentials.json 2>/dev/null || cat /sandbox/.claude/credentials.json' \
       > "$TMPFILE" 2>/dev/null || [[ ! -s "$TMPFILE" ]]; then
    die "Could not read credentials from '$CLONE_SRC'. Is it running and authenticated?"
  fi
  ok "Credentials read from '$CLONE_SRC'"
  TMPFILE_SETTINGS="$(mktemp)"; chmod 600 "$TMPFILE_SETTINGS"
  openshell sandbox exec -n "$CLONE_SRC" -- \
    cat /sandbox/.claude/settings.json > "$TMPFILE_SETTINGS" 2>/dev/null || true
  if [[ -s "$TMPFILE_SETTINGS" ]]; then
    ok "settings.json read from '$CLONE_SRC'"
  else
    ok "No settings.json in '$CLONE_SRC' — sandbox will use defaults"
    TMPFILE_SETTINGS=""
  fi
fi

# ---- sandbox create -----------------------------------------------------------
say "Creating sandbox '$SANDBOX_NAME'"

ENV_FLAGS=()
if $USE_BEDROCK; then
  # shellcheck source=/dev/null
  source "$BEDROCK_ENV"
  [[ -n "${AWS_ACCESS_KEY_ID:-}"     ]] || die "AWS_ACCESS_KEY_ID missing from $BEDROCK_ENV"
  [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || die "AWS_SECRET_ACCESS_KEY missing from $BEDROCK_ENV"
  [[ -n "${AWS_REGION:-}"            ]] || die "AWS_REGION missing from $BEDROCK_ENV"
  ENV_FLAGS=(
    --env "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}"
    --env "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}"
    --env "AWS_REGION=${AWS_REGION}"
  )
fi

openshell sandbox create \
  --name "$SANDBOX_NAME" \
  --no-auto-providers \
  --policy "$POLICY" \
  ${ENV_FLAGS[@]+"${ENV_FLAGS[@]}"} \
  -- claude

ok "Sandbox '$SANDBOX_NAME' created"

# ---- upload credentials + settings (--claudeai or --clone) --------------------
if $USE_CLAUDEAI || $USE_CLONE; then
  say "Uploading Claude state into sandbox"
  openshell sandbox exec -n "$SANDBOX_NAME" -- mkdir -p /sandbox/.claude
  openshell sandbox upload -n "$SANDBOX_NAME" "$TMPFILE" /sandbox/.claude/.credentials.json
  ok "Credentials uploaded → /sandbox/.claude/.credentials.json"
  if [[ -n "$TMPFILE_SETTINGS" && -s "$TMPFILE_SETTINGS" ]]; then
    openshell sandbox upload -n "$SANDBOX_NAME" "$TMPFILE_SETTINGS" /sandbox/.claude/settings.json
    ok "Settings uploaded  → /sandbox/.claude/settings.json (no login wizard, theme preserved)"
  fi
fi

# ---- upload bedrock project example settings -----------------------------------
if $USE_BEDROCK && [[ -f "$BEDROCK_PROJECT_SETTINGS" ]]; then
  say "Uploading Bedrock project example (bedrock-test)"
  openshell sandbox exec -n "$SANDBOX_NAME" -- mkdir -p /sandbox/bedrock-test/.claude
  openshell sandbox upload -n "$SANDBOX_NAME" \
    "$BEDROCK_PROJECT_SETTINGS" /sandbox/bedrock-test/.claude/settings.json
  ok "Bedrock-test project ready at /sandbox/bedrock-test"
fi

# ---- summary ------------------------------------------------------------------
AUTH_MODES=()
$USE_BEDROCK  && AUTH_MODES+=("Bedrock (keys injected via --env)")
$USE_CLAUDEAI && AUTH_MODES+=("Claude.ai (token from host director)")
$USE_CLONE    && AUTH_MODES+=("Subscription (token cloned from '$CLONE_SRC')")
[[ ${#AUTH_MODES[@]} -eq 0 ]] && AUTH_MODES+=("none — run 'claude login' inside the sandbox")

printf '\n\033[1;32m=== Sandbox ready ===\033[0m\n'
printf '  Name:   %s\n' "$SANDBOX_NAME"
printf '  Auth:   %s\n' "${AUTH_MODES[*]}"
printf '  Policy: %s\n' "$POLICY"
printf '\n  Connect: openshell sandbox connect %s\n' "$SANDBOX_NAME"

if ! $USE_CLAUDEAI && ! $USE_CLONE; then
  printf '\n  \033[1;33mNext:\033[0m Inside the sandbox, run: claude login\n'
  printf '  (OAuth cannot be scripted — one interactive step per fresh sandbox)\n'
fi

if $USE_BEDROCK && [[ -f "$BEDROCK_PROJECT_SETTINGS" ]]; then
  printf '\n  Bedrock test: cd /sandbox/bedrock-test && claude -p "say bedrock-ok"\n'
fi
printf '\n'
