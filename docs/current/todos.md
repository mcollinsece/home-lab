# Punchlist

See [platform.md](platform.md) for current state and
[../future/ai-dev-ground.md](../future/ai-dev-ground.md) for the overall arc.

---

## Immediate next steps (do these in order)

> Run these after pulling the latest commit on the homelab VM.

**1 — Activate Docker group in your shell** (one-time, if you just ran setup-host.sh):
```bash
newgrp docker
# or log out and back in
docker ps   # should work without sudo
```

**2 — Stop and clean up old Podman services** (decommission the old stack):
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
```

**8 — Wire openclaw.lab.lan through Traefik** (after NemoClaw onboard):
```bash
# NemoClaw publishes on http://127.0.0.1:18789.
# Add traefik/openclaw-nemoclaw.yml so it gets HTTPS routing at openclaw.lab.lan:
cat > ~/home-lab/traefik/openclaw-nemoclaw.yml <<'EOF'
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
# Traefik hot-reloads this (file provider watches the directory).
```

**9 — Recreate claude-code sandbox with Docker driver**:
```bash
# The old Podman-based sandbox is orphaned. Create a fresh Docker-backed one:
openshell sandbox create --name claude-code --no-auto-providers \
    --policy openshell/policies/claude-code.yaml \
    --env ANTHROPIC_BASE_URL=https://inference.local \
    --env ANTHROPIC_API_KEY=unused \
    -- claude
openshell sandbox connect claude-code
# Inside the sandbox: claude login   (only needed if using subscription auth)
```

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

### Remaining (post-migration manual steps)

- [ ] **NemoClaw onboard** — `curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash`
      Select "OpenAI-compatible" provider during wizard:
      ```
      API key:  $(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)
      Base URL: http://localhost:4000/v1
      Model:    claude-sonnet-4-6
      ```
- [ ] **NemoClaw → Traefik route** — NemoClaw publishes OpenClaw at `http://127.0.0.1:18789`.
      Wire `openclaw.lab.lan` through Traefik using the file provider
      (since NemoClaw-managed Docker containers don't get Traefik labels automatically).
      Add `traefik/openclaw-nemoclaw.yml`:
      ```yaml
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
      ```
- [ ] **Wire OpenShell inference routing to LiteLLM** (after `docker compose up -d`):
      ```bash
      LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)
      openshell provider create \
          --name litellm-local --type openai \
          --credential "OPENAI_API_KEY=${LITELLM_KEY}" \
          --config OPENAI_BASE_URL=http://localhost:4000/v1
      openshell inference set --no-verify --provider litellm-local --model claude-sonnet-4-6
      openshell inference get
      ```
- [ ] **Recreate claude-code sandbox** — Podman-based sandbox is orphaned by the Docker
      driver switch. Create a new Docker-backed sandbox:
      ```bash
      openshell sandbox create --name claude-code --no-auto-providers \
          --policy openshell/policies/claude-code.yaml \
          --env ANTHROPIC_BASE_URL=https://inference.local \
          --env ANTHROPIC_API_KEY=unused \
          -- claude
      ```
- [ ] **Verify Portainer connects to Docker** — open `https://portainer.lab.lan` and
      confirm it shows Docker containers (not a blank/disconnected state).

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
