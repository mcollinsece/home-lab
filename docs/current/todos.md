# Punchlist

See [platform.md](platform.md) for current state and
[../future/ai-dev-ground.md](../future/ai-dev-ground.md) for the overall arc.

## Phase 4 — OpenClaw + secrets management

OpenClaw is a Claude Code variant built for persistent, always-on assistant use.
The design principle: **OpenShell is the single control plane for all agents.**
OpenClaw runs as an OpenShell BYOC sandbox — not a raw Podman container — so it
gets the same policy enforcement, exec dispatch, and lifecycle management as every
other agent. Quadlet handles one narrow job: calling `osbox` on boot so the sandbox
exists after a reboot.

**Architecture:**
- `osbox openclaw --claudeai --headless` creates a headless sandbox from the OpenClaw
  BYOC image. The Podman container persists after the setup script exits; the sandbox
  stays `Ready` for `openshell sandbox exec` dispatch.
- A systemd unit (`openclaw-start.service`, `Type=oneshot`) runs `osbox` idempotently
  at boot — skip creation if the sandbox is already registered. Reboots covered;
  OpenShell stays the authoritative registry.
- `osbox` needs a `--if-not-exists` guard (or name-collision detection) so the boot
  service is safe to run repeatedly without error.

**Secrets manager** — replaces the manual `.secrets/` file pattern with something
that survives a clean rebuild without manual copy-paste from a password manager:
- Evaluate **Podman secrets** (`podman secret create`) — already available, integrates
  with Quadlet via `Secret=` in container units. Simple; no extra tooling.
- Evaluate **SOPS + age** — encrypt secrets in git, decrypt with a key from the
  password manager. Survives a repo clone; `.age` extension already gitignored.
- Decision drives how `osbox --bedrock`, `--codex`, `--gemini` source keys going
  forward. Pick one and migrate `~/.secrets/bedrock.env` to it.

**Work items:**
- [ ] **Local image registry** — `registry/registry.container` Quadlet + Traefik route
      at `registry.lab.lan`. Required before pulling or building BYOC images.
- [ ] **OpenClaw BYOC image** — pull/build and push to local registry (`:5000`).
      Define `openshell/policies/openclaw.yaml` (egress scope TBD from OpenClaw docs).
- [ ] **`osbox` idempotency** — add name-collision detection: if sandbox already exists,
      print status and exit 0. Makes the boot service safe to repeat.
- [ ] **`openclaw-start.service`** systemd unit — `Type=oneshot`, calls
      `osbox openclaw --claudeai --headless`; wired to `openshell-gateway.service`
      via `After=`/`Wants=` so it fires once the gateway is up.
- [ ] **Secrets manager** — pick Podman secrets vs SOPS+age; migrate `bedrock.env`;
      document re-creation procedure for a clean-host rebuild (replaces the manual
      `.secrets/` step that currently requires a password manager copy-paste).
- [ ] **Verify** sandbox survives a gateway restart and a full reboot; confirm
      `openshell sandbox exec -n openclaw -- openclaw -p "task"` dispatches correctly.

## Phase 5 — Codex sandbox

Add OpenAI Codex CLI as a first-class `osbox`-managed agent.

- [ ] **`openshell/policies/codex.yaml`** — egress policy for OpenAI API endpoints.
- [ ] **`--codex` flag for `osbox`** — sets `AGENT_CMD=codex`, sources `OPENAI_API_KEY`
      via the secrets manager chosen in Phase 4, clones `~/.codex/` state if present.
      The `AGENT_CMD` hook is already wired — this is mostly a credential + policy block.
- [ ] **`openshell/project-settings/codex-test.json`** — committed non-secret opt-in
      settings (mirrors `bedrock-test.json` pattern).
- [ ] **Verify** `osbox codex-1 --codex --headless` → dispatch
      `openshell sandbox exec -n codex-1 -- codex -p "task"`.

## Phase 6 — Gemini CLI sandbox

Add Google Gemini CLI as a sandboxed agent via the same `osbox` pattern.

- [ ] **`openshell/policies/gemini.yaml`** — egress for Gemini API / GCP endpoints.
- [ ] **`--gemini` flag for `osbox`** — sets `AGENT_CMD=gemini`, injects GCP
      application-default credentials or `GOOGLE_API_KEY` via secrets manager.
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
