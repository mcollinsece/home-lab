# Punchlist

See [platform.md](platform.md) for current state and
[../future/ai-dev-ground.md](../future/ai-dev-ground.md) for the overall arc.

---

## Immediate next steps (do these in order)

> Run these after pulling the latest commit on the homelab VM. (The recommended post-clone / post-setup / post-migration-repro flow. Onboard (step 7) + initial director create have been executed; the active work is director provisioning troubleshoot (step 8 route is pre-placed as static yml) and the explicit lab claude-code recreate (step 9) after any nemoclaw run or clean rebuild. See Phase 7 Remaining below for the current Bad Gateway status and exact commands.)

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

## Phase 7 — Docker + NemoClaw migration ✅ (2026-06-13; onboard complete, claude-code Ready on lab gw; director provisioning / openclaw Bad Gateway in progress)

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

**Top priority (user-reported at end of session):**
- [ ] **Troubleshoot openclaw.lab.lan Bad Gateway / director stuck in Provisioning**:
  Current symptom (user): 502 / Bad Gateway on openclaw.lab.lan.
  - Run: `nemoclaw director status` (expect exact phase; "Connected", not just Provisioning).
  - `nemoclaw director rebuild --yes` (if stuck; workspace preserved).
  - Listener: `ss -tlnp | grep 18789` (or 8080 forward).
  - Route test: `curl -k -H 'Host: openclaw.lab.lan' https://localhost/` (should stop 502 once Ready; served via pre-placed `traefik/dynamic/openclaw-nemoclaw.yml` + file provider).
  - Watch the nemoclaw gateway log: `tail -f /home/debian/.local/state/nemoclaw/openshell-docker-gateway/openshell-gateway.log` (CreateSandbox/GetSandbox/supervisor, policy "managed_inference" to inference.local, no legacy "stopping" errors).
  - Connect once Ready: `nemoclaw director connect`.
  - Dual-gw context: director uses nemoclaw's 0.0.44 gateway (8080 + 10.89.0.1 alias/iptables workaround from session); lab claude-code uses separate 17670 mTLS (0.0.62). 10.89 alias + iptables were added for nemoclaw gw reachability.
  - After stable: consider `Clean up 10.89...` item below.
- [ ] **Finalize bootstrap/setup-host.sh for full reproducibility** (targeted banner + NOTE updates done in session + this pass; full end-to-end clean-VM verify remains):
  Script covers Docker/OpenShell 0.0.62/gateway.env symlink/compose if secrets + tools. Post-nemoclaw flow (symlink restore + exact lab claude-code recreate via `/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 ...`) is in the final manual-steps heredoc and in todos immediate step 9. 
  - After edits here, re-verify on a clean checkout: setup-host.sh + init-secrets + docker compose + nemoclaw onboard + symlink + explicit 17670 claude-code recreate + `nemoclaw director status` + route curls.
- [ ] **Verify full end-to-end reproducibility** (see above): clean VM/snapshot, run the whole flow, confirm both gateways, claude-code Ready (inference.local), director Ready, openclaw.lab.lan + traefik.dashboard/ + litellm smoke all work, policies effective. Update this item when a full repro succeeds end-to-end.
- [ ] **Traefik Docker provider version skew**: Persistent "client version 1.24 too old" (even with DOCKER_API_VERSION=1.41 env in compose). We rely on static `traefik/dynamic/traefik-dashboard.yml` (for dashboard) + `openclaw-nemoclaw.yml`. Documented in traefik/README.md and TROUBLESHOOTING. Fix later (newer Traefik image/SDK or socket proxy) or accept static files for critical routers.
- [ ] **Clean up 10.89 alias + iptables** (session workaround for nemoclaw gw bind/reachability from legacy Podman subnets) once director is stable/Ready and no longer required.
- [ ] **Persist / make robust the lab 17670 gateway** (systemd service can get taken over by nemoclaw metadata after onboard). Prefer explicit `--gateway-endpoint http://127.0.0.1:17670 --gateway-insecure` (or https) for all lab commands; or add a dedicated user service/unit for the 0.0.62 side.
- [x] (done) Static Traefik routes + dashboard workaround pre-placed and hot-reloading (file provider).
- [x] (done) gateway.env restore documented + symlink step in setup-host + post-nemoclaw notes everywhere.
- [x] (done) All claude-code / lab examples updated to explicit /usr/bin + 17670 endpoint form.
- [x] (done) DOCKER_API_VERSION, dual-gw reality, 0.0.62 re-install, container cleans, lock/pkill, cert paths, LiteLLM wiring, onboard-driven config captured in docs + TROUBLESHOOTING.

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
