# Punchlist

See [platform.md](platform.md) for current state and
[../future/ai-dev-ground.md](../future/ai-dev-ground.md) for the overall arc.

---

## Post-clone / fresh-setup flow

> Run these after pulling the latest commit on the homelab VM. Docker Compose services,
> NemoClaw director, and the claude-code wrapper must all be started in order.

**1 — Activate Docker group in your shell** (one-time, if you just ran setup-host.sh):
```bash
newgrp docker
# or log out and back in
docker ps   # should work without sudo
```

**2 — Run init-secrets** (populates `.secrets/bedrock.env` + `.secrets/litellm.env`):
```bash
init-secrets
```

**3 — Copy non-secret config and start Docker services**:
```bash
cp litellm/litellm.env.example litellm/litellm.env
docker compose -f docker/compose.yml up -d
docker compose -f docker/compose.yml ps   # all should be Up
```

**4 — Smoke-test LiteLLM**:
```bash
LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)
curl -s http://localhost:4000/v1/models -H "Authorization: Bearer ${LITELLM_KEY}" \
  | python3 -m json.tool
# Should return claude-sonnet-4-6, claude-code-wrapper-local, and aliases
```

**5 — Wire OpenShell inference routing** (one-time; existing provider can be updated):
```bash
LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)
openshell provider create \
    --name litellm-local --type openai \
    --credential "OPENAI_API_KEY=${LITELLM_KEY}" \
    --config OPENAI_BASE_URL=http://localhost:4000/v1
openshell inference set --no-verify --provider litellm-local --model claude-sonnet-4-6
openshell inference get   # confirm provider=litellm-local, model=claude-sonnet-4-6
```

**6 — Install NemoClaw** (interactive — have the LiteLLM key from step 2 ready):
```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
# During 'nemoclaw onboard', when asked for inference provider:
#   → Select: OpenAI-compatible
#   → API key: <LITELLM_MASTER_KEY from .secrets/litellm.env>
#   → Base URL: http://localhost:4000/v1
#   → Model: claude-sonnet-4-6
```

**7 — Start the probe service** (patches NemoClaw director and starts openclaw gateway):
```bash
systemctl --user enable --now nemoclaw-director-control-ui
systemctl --user status nemoclaw-director-control-ui   # active (exited) is normal

# The probe: CORS patch → provider rename → claude-code-wrapper-local add →
#            pass-through shim → ai-net connect → openclaw gateway start (as sandbox user)
# Verify:
curl -sk -H 'Host: openclaw.lab.lan' https://localhost/ -o /dev/null -w "%{http_code}\n"
# Expect: 200
```

**8 — Start the claude-code wrapper sandbox**:
```bash
# First create the sandbox if it doesn't exist:
/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure \
  sandbox create --name claude-revproxy --no-auto-providers \
  --policy ~/home-lab/openshell/policies/claude-code.yaml

# Then log in to Claude on the host and sync credentials:
claude auth login   # interactive OAuth — run on host, not in sandbox
bootstrap/sync-claude-credentials.sh

# Start the wrapper:
bootstrap/setup-claude-revproxy.sh
# Verifies: sandbox connected to ai-net as claude-code-wrapper, uvicorn on :8000
```

**9 — (Re)create claude-code sandbox on the lab gateway** (for interactive use):
```bash
# Always use the lab gateway explicitly (17670) + the 0.0.62 binary.
/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure \
  sandbox delete claude-code 2>/dev/null || true
/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure \
  sandbox create --name claude-code --no-auto-providers \
    --policy ~/home-lab/openshell/policies/claude-code.yaml \
    --env ANTHROPIC_BASE_URL=https://inference.local \
    --env ANTHROPIC_API_KEY=unused \
    -- claude
```

> **Post-nemoclaw note:** After `nemoclaw onboard` the default openshell CLI may
> be 0.0.44. Always use `/usr/bin/openshell` + `--gateway-endpoint http://127.0.0.1:17670
> --gateway-insecure` for lab sandbox commands. Then:
> `ln -sfn ~/home-lab/openshell/gateway.env ~/.config/openshell/gateway.env`

---

## Phase 7 — Docker + NemoClaw migration ✅ fully live (2026-06-13/14)

Migrated from rootless Podman Quadlets to Docker Engine + Docker Compose.
OpenClaw moved from a Podman Quadlet to NemoClaw (NVIDIA-managed, runs OpenClaw
inside an OpenShell sandbox). claude-code-wrapper-local added as a second agentic
model (OAuth path, no Bedrock credentials in the sandbox).

- [x] Install Docker Engine and add `debian` to docker group
- [x] Create `docker/compose.yml` — Traefik, Portainer, Registry, LiteLLM
- [x] Switch OpenShell gateway driver: `OPENSHELL_DRIVERS=docker`
- [x] Remove all Podman Quadlet files (`.container`, `.volume`, `.network`)
- [x] Update `bootstrap/setup-host.sh` — Docker steps replace Quadlet steps
- [x] Update `bootstrap/init-secrets.sh` — env files only, no Podman secrets
- [x] Update `projects/_template/` — Docker Compose is the standard pattern
- [x] NemoClaw director "Ready"; `openclaw.lab.lan` returns 200; dashboard loads
- [x] Routing: Traefik → `openclaw-director:18789` (Docker network alias on ai-net) — no SSH tunnel or socat
- [x] Probe service (`nemoclaw-director-control-ui`): CORS patch, litellm-only provider, claude-code-wrapper-local model add, pass-through shim, ai-net connect, openclaw gateway start
- [x] OpenClaw model picker: `litellm/claude-sonnet-4-6` (Bedrock) + `litellm/claude-code-wrapper-local` (wrapper)
- [x] `openshell-claude-revproxy` sandbox: `claude-code-openai-wrapper` running on :8000; OAuth/Pro; no Bedrock creds
- [x] LiteLLM routing: three aliases (`claude-code-wrapper-local`, `claude-code-sonnet`, `claude-code/sonnet`) → `http://claude-code-wrapper:8000/v1`
- [x] End-to-end verified: OpenClaw → LiteLLM → claude-revproxy sandbox → Claude Code (OAuth) → Anthropic
- [x] Static Traefik routes + dashboard workaround pre-placed and hot-reloading (file provider)
- [x] gateway.env restore documented + symlink step in setup-host + post-nemoclaw notes
- [x] All claude-code / lab examples updated to explicit `/usr/bin/openshell` + 17670 endpoint form
- [x] `bootstrap/setup-claude-revproxy.sh` — wrapper start script (idempotent)
- [x] `bootstrap/sync-claude-credentials.sh` — OAuth credential sync from host to sandbox

### Remaining

- [ ] **Finalize bootstrap/setup-host.sh for full reproducibility**: script covers Docker/OpenShell/gateway.env/mkcert/tools; probe service enable + wrapper setup not yet scripted. Verify on a clean checkout: setup-host → init-secrets → docker compose up → nemoclaw onboard → probe start → wrapper start → verify all routes.
- [ ] **Verify full end-to-end reproducibility**: clean VM/snapshot, run the whole flow, confirm both gateways, claude-code Ready (inference.local), director Ready, openclaw.lab.lan + traefik.dashboard/ + litellm smoke + claude-code-wrapper-local all work.
- [ ] **Traefik Docker provider version skew**: Persistent "client version 1.24 too old" logged. We rely on static `traefik/dynamic/` routes for openclaw and dashboard. Fix later (newer Traefik image or socket proxy) or continue with static files.
- [ ] **Persist lab 17670 gateway** — nemoclaw onboard can re-take precedence in PATH. Prefer explicit `/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure` for all lab commands; or add a dedicated user service for the 0.0.62 side.
- [ ] **systemd timer for `sync-claude-credentials.sh`** — OAuth tokens expire. Add an hourly (or daily) timer to keep the `openshell-claude-revproxy` sandbox credentials fresh without manual runs.
- [ ] **Wrapper auto-start on reboot** — `setup-claude-revproxy.sh` is currently run manually. Add a systemd `--user` service (similar to `nemoclaw-director-control-ui`) that starts the wrapper automatically on login/boot.

---

## Phase 5 — Codex sandbox

Add OpenAI Codex CLI as a first-class `osbox`-managed agent.

- [ ] **`init-secrets` update** — add Codex section: prompts for `OPENAI_API_KEY`,
      writes `.secrets/codex.env`.
- [ ] **`openshell/policies/codex.yaml`** — egress policy for OpenAI API endpoints.
- [ ] **`--codex` flag for `osbox`** — sets `AGENT_CMD=codex`, injects
      `OPENAI_BASE_URL=https://inference.local/v1 OPENAI_API_KEY=unused` (inference.local
      pattern; no raw key in sandbox).
- [ ] **Verify** `osbox codex-1 --codex --headless`.

---

## Phase 6 — Gemini CLI sandbox

Add Google Gemini CLI as a sandboxed agent via the same `osbox` pattern.

- [ ] **`init-secrets` update** — add Gemini section: `GOOGLE_API_KEY`, writes `.secrets/gemini.env`.
- [ ] **`openshell/policies/gemini.yaml`** — egress for Gemini API / GCP endpoints.
- [ ] **`--gemini` flag for `osbox`** — injects `GOOGLE_GENAI_BASE_URL=https://inference.local`.
- [ ] **Verify** `osbox gemini-1 --gemini --headless`.

---

## Phase 8 — Podman + NemoClaw evaluation (future)

NemoClaw currently requires Docker Engine. If NVIDIA adds Podman support:

- [ ] **Evaluate NemoClaw Podman driver** — check NemoClaw release notes for Podman support.
      If available, test switching `OPENSHELL_DRIVERS=podman` and re-running `nemoclaw onboard`.
- [ ] **Restore rootless services** — if Podman is preferred, migrate Docker Compose services
      back to Podman Quadlets for privilege isolation (rootless Podman is better security posture
      than rootful Docker for a single-user homelab).
- [ ] **Track in future docs** — update this todo when NemoClaw publishes a Podman roadmap.

---

## Phase 9 — Alternative provider support

Research and wire up additional model providers via LiteLLM and OpenClaw.

- [ ] **OpenAI / ChatGPT** — add `gpt-4o` to `litellm/config.yaml`; uncomment OpenAI
      block. Update `init-secrets.sh` to prompt for `OPENAI_API_KEY`.
- [ ] **xAI Grok** — add `grok-3` to `litellm/config.yaml`; prompt for `XAI_API_KEY`.
- [ ] **Google Gemini API** — add `gemini-2.5-pro` to `litellm/config.yaml`; prompt
      for `GOOGLE_API_KEY`.
- [ ] **Ollama (local)** — add `ollama-local` stub in `litellm/config.yaml` with
      `http://host.docker.internal:11434/v1`; no key needed.
- [ ] **OpenRouter** — single gateway for provider fallback.
- [ ] **Document** which provider(s) to recommend as primary and update README accordingly.
