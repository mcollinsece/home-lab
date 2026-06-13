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
HOST_CLAUDE_JSON="$HOME/.claude.json"          # internal state: hasCompletedOnboarding, migrations, etc.
BEDROCK_PROJECT_SETTINGS="$REPO_DIR/openshell/project-settings/bedrock-test.json"

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Inject hasTrustDialogAccepted=true for /sandbox into a .claude.json temp file.
# Claude Code checks this field before showing the "do you trust this folder?" dialog.
add_sandbox_trust() {
  local file="$1" tmp
  tmp="$(mktemp)"
  python3 -c "
import sys, json
d = json.load(open(sys.argv[1]))
if 'projects' not in d:
    d['projects'] = {}
proj = d['projects'].get('/sandbox', {})
proj['hasTrustDialogAccepted'] = True
proj.setdefault('allowedTools', [])
proj.setdefault('mcpContextUris', [])
proj.setdefault('mcpServers', {})
proj.setdefault('enabledMcpjsonServers', [])
proj.setdefault('disabledMcpjsonServers', [])
d['projects']['/sandbox'] = proj
open(sys.argv[2], 'w').write(json.dumps(d))
" "$file" "$tmp" && mv "$tmp" "$file"
}

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
TMPFILE_CLAUDE_JSON=""
cleanup() {
  [[ -z "$TMPFILE"             || ! -f "$TMPFILE"             ]] || rm -f "$TMPFILE"
  [[ -z "$TMPFILE_SETTINGS"    || ! -f "$TMPFILE_SETTINGS"    ]] || rm -f "$TMPFILE_SETTINGS"
  [[ -z "$TMPFILE_CLAUDE_JSON" || ! -f "$TMPFILE_CLAUDE_JSON" ]] || rm -f "$TMPFILE_CLAUDE_JSON"
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
  [[ -r "$HOST_CLAUDE_JSON" ]] \
    || die "--claudeai: $HOST_CLAUDE_JSON not found. Expected after first run of claude on the host."
  ok "Host .claude.json readable (hasCompletedOnboarding + migration state)"
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
  ok "settings.json copied"
  TMPFILE_CLAUDE_JSON="$(mktemp)"; chmod 600 "$TMPFILE_CLAUDE_JSON"
  cp "$HOST_CLAUDE_JSON" "$TMPFILE_CLAUDE_JSON"
  add_sandbox_trust "$TMPFILE_CLAUDE_JSON"
  ok ".claude.json copied + /sandbox pre-trusted (no wizard, no trust dialog)"
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
  TMPFILE_CLAUDE_JSON="$(mktemp)"; chmod 600 "$TMPFILE_CLAUDE_JSON"
  openshell sandbox exec -n "$CLONE_SRC" -- \
    cat /sandbox/.claude.json > "$TMPFILE_CLAUDE_JSON" 2>/dev/null || true
  if [[ -s "$TMPFILE_CLAUDE_JSON" ]]; then
    add_sandbox_trust "$TMPFILE_CLAUDE_JSON"
    ok ".claude.json read from '$CLONE_SRC' + /sandbox pre-trusted"
  else
    ok "No .claude.json in '$CLONE_SRC' — wizard will run on first launch"
    TMPFILE_CLAUDE_JSON=""
  fi
fi

# ---- build --env, --upload, and entrypoint arrays ----------------------------
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

# Files are staged flat under /sandbox (guaranteed to exist), then moved into
# place by the entrypoint wrapper before claude starts — so claude never sees
# the first-run wizard even on its very first invocation.
UPLOAD_FLAGS=()
SETUP_CMDS=()

if $USE_CLAUDEAI || $USE_CLONE; then
  UPLOAD_FLAGS+=(--upload "$TMPFILE:/sandbox/.creds_upload")
  SETUP_CMDS+=('mkdir -p /sandbox/.claude')
  SETUP_CMDS+=('mv /sandbox/.creds_upload /sandbox/.claude/.credentials.json 2>/dev/null || true')
  if [[ -n "$TMPFILE_SETTINGS" && -s "$TMPFILE_SETTINGS" ]]; then
    UPLOAD_FLAGS+=(--upload "$TMPFILE_SETTINGS:/sandbox/.settings_upload")
    SETUP_CMDS+=('mv /sandbox/.settings_upload /sandbox/.claude/settings.json 2>/dev/null || true')
  fi
  if [[ -n "$TMPFILE_CLAUDE_JSON" && -s "$TMPFILE_CLAUDE_JSON" ]]; then
    # .claude.json lives at home root, not inside .claude/ — stages as .claude_json_upload
    UPLOAD_FLAGS+=(--upload "$TMPFILE_CLAUDE_JSON:/sandbox/.claude_json_upload")
    SETUP_CMDS+=('mv /sandbox/.claude_json_upload /sandbox/.claude.json 2>/dev/null || true')
  fi
fi

if $USE_BEDROCK && [[ -f "$BEDROCK_PROJECT_SETTINGS" ]]; then
  UPLOAD_FLAGS+=(--upload "$BEDROCK_PROJECT_SETTINGS:/sandbox/.bedrock_upload")
  SETUP_CMDS+=('mkdir -p /sandbox/bedrock-test/.claude')
  SETUP_CMDS+=('mv /sandbox/.bedrock_upload /sandbox/bedrock-test/.claude/settings.json 2>/dev/null || true')
fi

if [[ ${#UPLOAD_FLAGS[@]} -gt 0 ]]; then
  # join setup commands with '; ' then append 'exec claude'
  SETUP_SCRIPT="$(printf '%s; ' "${SETUP_CMDS[@]}")exec claude"
  ENTRYPOINT=(-- sh -c "$SETUP_SCRIPT")
else
  ENTRYPOINT=(-- claude)
fi

# ---- create (blocks — claude runs interactively; files pre-staged via --upload)
openshell sandbox create \
  --name "$SANDBOX_NAME" \
  --no-auto-providers \
  --policy "$POLICY" \
  ${ENV_FLAGS[@]+"${ENV_FLAGS[@]}"} \
  ${UPLOAD_FLAGS[@]+"${UPLOAD_FLAGS[@]}"} \
  "${ENTRYPOINT[@]}"

# ---- summary (prints after user exits claude) ---------------------------------
AUTH_MODES=()
$USE_BEDROCK  && AUTH_MODES+=("Bedrock (keys injected via --env)")
$USE_CLAUDEAI && AUTH_MODES+=("Claude.ai (token from host director)")
$USE_CLONE    && AUTH_MODES+=("Subscription (token cloned from '$CLONE_SRC')")
[[ ${#AUTH_MODES[@]} -eq 0 ]] && AUTH_MODES+=("none — run 'claude login' inside the sandbox")

printf '\n\033[1;32m=== Session ended — sandbox still running ===\033[0m\n'
printf '  Name:   %s\n' "$SANDBOX_NAME"
printf '  Auth:   %s\n' "${AUTH_MODES[*]}"
printf '\n  Reconnect: openshell sandbox connect %s\n' "$SANDBOX_NAME"

if ! $USE_CLAUDEAI && ! $USE_CLONE; then
  printf '\n  \033[1;33mNote:\033[0m Run inside the sandbox: claude login\n'
  printf '  (OAuth cannot be scripted — one interactive step per fresh sandbox)\n'
fi

if $USE_BEDROCK && [[ -f "$BEDROCK_PROJECT_SETTINGS" ]]; then
  printf '\n  Bedrock test: cd /sandbox/bedrock-test && claude -p "say bedrock-ok"\n'
fi
printf '\n'
