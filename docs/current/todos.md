# Punchlist

See [platform.md](platform.md) for current state and
[../future/ai-dev-ground.md](../future/ai-dev-ground.md) for the overall arc.

## Phase 4 — OpenClaw + secrets management

OpenClaw is an AI agent orchestration platform (not a CLI tool). It sits *above*
OpenShell: it calls `openshell sandbox create` internally to spawn worker sandboxes,
manages their lifecycle, dispatches tasks, and aggregates results. The native
integration is documented at docs.openclaw.ai/gateway/openshell.

**Architecture:**
```
OpenClaw (Quadlet — always-on director)
   └── OpenShell gateway  ← OpenClaw configures this as its sandbox backend
         ├── claude-code sandbox  (worker — osbox --claudeai)
         ├── codex sandbox        (worker — osbox --codex, Phase 5)
         └── gemini sandbox       (worker — osbox --gemini, Phase 6)
```

OpenClaw runs as a Podman Quadlet because it's the orchestration layer — not a worker
to be isolated. OpenShell remains the control plane for all agent sandboxes. Running
OpenClaw inside OpenShell would prevent it from using OpenShell as its backend.
For k8s migration: OpenClaw Quadlet → k8s Deployment; OpenShell sandboxes → k8s Pods.

**Phase 4 status:**
- [x] **Local image registry** — `registry/registry.container` Quadlet running at
      `registry.lab.lan`. Push: `podman push --tls-verify=false registry.lab.lan/<image>:<tag>`.
- [x] **`osbox` idempotency** — name-collision detection added; exits cleanly if the
      sandbox already exists, prints connect/dispatch/recreate instructions.
- [x] **Secrets manager** — `bootstrap/init-secrets.sh` (PATH-installed as `init-secrets`):
      populates `.secrets/bedrock.env` (for osbox) and Podman secrets
      `bedrock_aws_*` + `anthropic_api_key` (for Quadlet containers).
- [x] **`openclaw/openclaw.container`** Quadlet scaffolding — web UI at `openclaw.lab.lan`,
      state volume, `anthropic_api_key` Podman secret, `openshell-gateway.service` dep.
      Browser automation (`SYS_ADMIN` + `--shm-size=1g`) is commented out; enable when needed.
- [x] **`openclaw/Containerfile`** — extends upstream image with openshell CLI pre-installed
      and gateway pointed at `host.containers.internal:17670`. Build + push to local registry
      when ready to wire up OpenShell backend from inside OpenClaw.

**Remaining manual steps:**
- [ ] **`init-secrets`** — run once to create Bedrock + Anthropic API key Podman secrets.
- [ ] **`cp openclaw/openclaw.env.example openclaw/openclaw.env`** — fill in gateway URL.
- [ ] **`systemctl --user start openclaw`** — start the OpenClaw Quadlet.
- [ ] **OpenClaw gateway config** — in OpenClaw UI (http://openclaw.lab.lan):
      Settings → Gateway → OpenShell → URL: `http://host.containers.internal:17670`.
- [ ] **Custom image** — `podman build -t registry.lab.lan/openclaw:latest openclaw/ &&
      podman push --tls-verify=false registry.lab.lan/openclaw:latest`, then switch
      `openclaw.container` Image= to `registry.lab.lan/openclaw:latest`. This bakes in
      the openshell CLI so OpenClaw can spawn sandboxes directly.

## Phase 5 — Codex sandbox

Add OpenAI Codex CLI as a first-class `osbox`-managed agent.

- [ ] **`openshell/policies/codex.yaml`** — egress policy for OpenAI API endpoints.
- [ ] **`--codex` flag for `osbox`** — sets `AGENT_CMD=codex`, sources `OPENAI_API_KEY`
      via `init-secrets` (adds to `.secrets/codex.env` + Podman secret), clones
      `~/.codex/` state if present. The `AGENT_CMD` hook is already wired.
- [ ] **`openshell/project-settings/codex-test.json`** — non-secret opt-in settings.
- [ ] **Verify** `osbox codex-1 --codex --headless` → dispatch
      `openshell sandbox exec -n codex-1 -- codex -p "task"`.

## Phase 6 — Gemini CLI sandbox

Add Google Gemini CLI as a sandboxed agent via the same `osbox` pattern.

- [ ] **`openshell/policies/gemini.yaml`** — egress for Gemini API / GCP endpoints.
- [ ] **`--gemini` flag for `osbox`** — sets `AGENT_CMD=gemini`, injects GCP
      application-default credentials or `GOOGLE_API_KEY` via `init-secrets`.
- [ ] **`openshell/project-settings/gemini-test.json`**.
- [ ] **Verify** `osbox gemini-1 --gemini --headless` → dispatch
      `openshell sandbox exec -n gemini-1 -- gemini -p "task"`.

## Phase 7 — NemoClaw + NeMo Agent Toolkit

- [ ] **NemoClaw** — deferred Docker service. Evaluate whether Podman can replace the
      Docker dependency before committing to a design. If Podman works, run as an
      OpenShell BYOC sandbox to keep it on the same control plane as other agents.
- [ ] **NeMo Agent Toolkit orchestration** — multi-agent pipeline wiring across Claude,
      Codex, and Gemini workers. Design TBD once Phases 4–6 agents are stable and the
      director/worker dispatch pattern is proven at scale.
