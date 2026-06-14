# Punchlist

See [platform.md](platform.md) for current state and
[../future/ai-dev-ground.md](../future/ai-dev-ground.md) for the overall arc.

---

## Immediate next steps (do these in order)

> Run these after pulling the latest commit on the homelab VM. (Still the recommended post-clone / post-setup flow; valid after the Docker + NemoClaw infrastructure work in this session.)

**1 — Activate Docker group in your shell** (one-time, if you just ran setup-host.sh):
```bash
newgrp docker
# or log out and back in
docker ps   # should work without sudo
```

**2 — Stop and clean up old Podman services** (decommission the old stack — run if coming from a pre-migration snapshot):
```bash
systemctl --user stop traefik portainer registry openclaw litellm 2>/dev/null || true
systemctl --user disable traefik portainer registry openclaw litellm 2>/dev/null || true
# Remove old Quadlet symlinks that are now dead
find ~/.config/containers/systemd/ -type l | while read f; do
  [ -e "$f" ] || rm "$f" && echo "removed broken symlink $f"
done
systemctl --user daemon-reload
```

**3 — Run init-secrets** (populates `.secrets/bedrock.env` + `.secrets/litellm.env`):
```bash
init-secrets
```

**4 — Copy non-secret config and start Docker services**:
```bash
cp litellm/litellm.env.example litellm/litellm.env
docker compose -f docker/compose.yml up -d
docker compose -f docker/compose.yml ps   # all should be Up
```

**5 — Smoke-test LiteLLM**:
```bash
LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)
curl -s http://localhost:4000/v1/models -H "Authorization: Bearer ${LITELLM_KEY}" \
  | python3 -m json.tool
# Should return claude-sonnet-4-6 in the model list
```

**6 — Wire OpenShell inference routing** (one-time; existing provider can be updated):
```bash
LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)
# If a litellm-local provider already exists, delete it first:
# openshell provider delete --name litellm-local
openshell provider create \
    --name litellm-local --type openai \
    --credential "OPENAI_API_KEY=${LITELLM_KEY}" \
    --config OPENAI_BASE_URL=http://localhost:4000/v1
openshell inference set --no-verify --provider litellm-local --model claude-sonnet-4-6
openshell inference get   # confirm provider=litellm-local, model=claude-sonnet-4-6
```

**7 — Install NemoClaw** (interactive — have the LiteLLM key from step 3 ready):
```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
# During 'nemoclaw onboard', when asked for inference provider:
#   → Select: OpenAI-compatible
#   → API key: <LITELLM_MASTER_KEY from .secrets/litellm.env>
#   → Base URL: http://localhost:4000/v1
#   → Model: claude-sonnet-4-6
# (See new "Troubleshoot director" section below for Bad Gateway / Provisioning issues.)
```

**8 — Wire openclaw.lab.lan through Traefik** (after NemoClaw onboard / director creation):
```bash
# (Pre-placed during session at traefik/dynamic/openclaw-nemoclaw.yml — file provider watches the dir.)
# NemoClaw publishes on http://127.0.0.1:18789 (or via its forward).
# The yml below (or the pre-placed one) gives HTTPS at openclaw.lab.lan:
cat > ~/home-lab/traefik/dynamic/openclaw-nemoclaw.yml <<'EOF'
http:
  routers:
    openclaw:
      rule: "Host(`openclaw.lab.lan`)"
      entrypoints: [websecure]
      tls: {}
      service: openclaw
  services:
    openclaw:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:18789"
EOF
# Traefik hot-reloads (file provider). See "Troubleshoot director (openclaw.lab.lan Bad Gateway)" below.
```

**9 — (Re)create claude-code sandbox on the lab gateway (post-nemoclaw / after any driver or CLI skew)**:
```bash
# Always use the lab gateway explicitly (17670) + the 0.0.62 binary (/usr/bin after restore).
# The nemoclaw install leaves a 0.0.44 CLI in .local/.npm-global that may take precedence in PATH.
/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure sandbox delete claude-code 2>/dev/null || true
/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure sandbox create --name claude-code --no-auto-providers \
    --policy ~/home-lab/openshell/policies/claude-code.yaml \
    --env ANTHROPIC_BASE_URL=https://inference.local \
    --env ANTHROPIC_API_KEY=unused \
    -- claude
# (Use https://... if the lab gateway is running with TLS/mTLS certs.)
# Then: /usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure sandbox connect claude-code
# Inside: claude login (if using subscription) or just tasks (inference.local → lab gateway → litellm).
```
(See "Update setup-host.sh" and "Dual gateway / post-nemoclaw claude-code" todos below.)

---

## Phase 7 — Docker + NemoClaw migration ✅ (2026-06-13, pending NemoClaw onboard)

Migrated from rootless Podman Quadlets to Docker Engine + Docker Compose.
OpenClaw moved from a Podman Quadlet to NemoClaw (NVIDIA-managed, runs OpenClaw
inside an OpenShell sandbox).

- [x] Install Docker Engine and add `debian` to docker group
- [x] Create `docker/compose.yml` — Traefik, Portainer, Registry, LiteLLM
- [x] Switch OpenShell gateway driver: `OPENSHELL_DRIVERS=docker`
- [x] Remove all Podman Quadlet files (`.container`, `.volume`, `.network`)
- [x] Update `bootstrap/setup-host.sh` — Docker steps replace Quadlet steps
- [x] Update `bootstrap/init-secrets.sh` — env files only, no Podman secrets
- [x] Update `projects/_template/` — Docker Compose is the standard pattern
- [x] Update docs

### Remaining (post-migration manual steps) + current session todos

- [ ] **Complete / troubleshoot NemoClaw director (openclaw.lab.lan Bad Gateway)**:
      Re-run or finish `nemoclaw onboard` (or `nemoclaw onboard --recreate-sandbox`).
      Choose OpenAI-compatible, provide LiteLLM details (key from .secrets, URL, model).
      Provide sandbox name e.g. "director".
      Then:
      - `nemoclaw director status` (expect Ready / Connected, not Provisioning).
      - If stuck in Provisioning: `nemoclaw director rebuild --yes` (recreates container; workspace preserved).
      - Check listener: `ss -tlnp | grep 18789` (nemoclaw sets up forward).
      - Test route: `curl -k -H 'Host: openclaw.lab.lan' https://localhost/` (should stop being 502/Bad Gateway once Ready; the pre-placed `traefik/dynamic/openclaw-nemoclaw.yml` routes it).
      - Connect: `nemoclaw director connect` (or `nemoclaw <name> connect`).
      - Watch gateway log: `tail -f /home/debian/.local/state/nemoclaw/openshell-docker-gateway/openshell-gateway.log` (look for supervisor relay, "CreateSandbox", GetSandbox, no "stopping" deserial errors — we cleaned old containers).
      - Note: nemoclaw pins 0.0.44 (its gateway on 8080 plaintext); lab uses separate 17670 (mTLS). The 10.89.0.1 lo alias + iptables (added during session) are required for nemoclaw gw reachability from its bridge.
- [ ] **Update bootstrap/setup-host.sh for full reproducibility**:
      Script is mostly good (Docker, OpenShell 0.0.62, gateway.env symlink to simple repo version, compose up if secrets, tools). But sync the final manual-steps banner and post-nemoclaw flow:
      - After `nemoclaw onboard`, always restore `ln -sfn ~/home-lab/openshell/gateway.env ~/.config/openshell/gateway.env` (nemoclaw may write its full 8080 config).
      - Recreate lab claude-code **using the lab gateway explicitly**:
        `/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure sandbox delete claude-code || true`
        `/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure sandbox create --name claude-code --no-auto-providers --policy ~/home-lab/openshell/policies/claude-code.yaml --env ANTHROPIC_BASE_URL=https://inference.local --env ANTHROPIC_API_KEY=unused -- claude`
        (Use /usr/bin for 0.0.62 + --env support; plain `openshell` may resolve to nemoclaw's 0.0.44 in PATH after its install.)
      - Start/ensure lab gateway on 17670 if the service is now tied to nemoclaw side (manual start with env + /usr/bin/openshell-gateway --bind-address 0.0.0.0 --port 17670 + TLS certs from ~/.local/state/openshell/tls/ as needed).
      - Note dual-gateway reality and that nemoclaw will install its own 0.0.44 CLI/gateway.
      - (I started targeted updates to the script's final banner in this session; finish the full sync.)
- [ ] **Verify full end-to-end reproducibility** after any setup-host.sh update: clean VM, run setup-host + init-secrets + docker compose up (if needed) + nemoclaw onboard (with details) + the two recreate commands above. Confirm: both gateways healthy, claude-code Ready with inference.local, director Ready, routes work (including openclaw.lab.lan and traefik.lab.lan/dashboard/), inference smoke from both sides, policies effective.
- [ ] **Traefik Docker provider version skew**: Still logs "client version 1.24 too old" (min 1.40) even with DOCKER_API_VERSION=1.41 in compose (env is present after force-recreate; SDK in v3.3 image reports old). Rely on static files in dynamic/ for critical routers (we added traefik-dashboard.yml as workaround; openclaw-nemoclaw.yml already static). Other label-based services may be affected until fixed (newer Traefik image, socket proxy, or accept and document).
- [ ] **Clean up 10.89 alias + iptables** (added as nemoclaw gw workaround during session) once director is stable and no longer needed.
- [ ] **Persist lab gateway on 17670** (currently sometimes manual start after nemoclaw takes over the systemd service/metadata). Consider a dedicated user service or script, or keep using explicit --gateway-endpoint in all lab commands.
- [ ] Update claude-code examples/docs everywhere to prefer explicit lab gateway endpoint post-nemoclaw.

(Immediate 1-9 steps below remain the recommended post-clone / post-setup flow; they are still valid.)

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
