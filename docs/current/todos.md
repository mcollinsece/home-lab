# Punchlist

See [platform.md](platform.md) for current state and
[../future/ai-dev-ground.md](../future/ai-dev-ground.md) for the overall arc.

## Critical / unblockers

- [ ] **Rotate IAM access key** `AKIAXNGUU6EIISYI3O4S` — pasted in a Claude chat and
      lives in host shell history. Steps: create a new key for the same scoped IAM user
      → update `~/.secrets/bedrock.env` → verify Bedrock still works → delete the old
      key in IAM console.

- [ ] **Document/script secrets re-creation** from password manager for a clean-host
      rebuild. Two stores: (a) Podman secrets for quadlet services (none yet);
      (b) sandbox-resident creds — `claude login` (OAuth, interactive only) and
      `~/.secrets/bedrock.env` (AWS Bedrock keys). A snapshot revert wipes both.

- [ ] **(Optional) Clean snapshot-revert reproducibility test.** Idempotent re-run was
      verified 2026-06-12 but a true from-zero rebuild was never tested. Safe because a
      working snapshot is the rollback target. Runbook:
      [../../bootstrap/TROUBLESHOOTING.md](../../bootstrap/TROUBLESHOOTING.md).

## Phase 4 — OpenClaw (always-on assistant)

OpenClaw is a Claude Code variant designed for persistent assistant use. Goal: run it
as an always-on BYOC container on Podman with a Quadlet restart policy so it survives
reboots. The local registry is pre-work needed before any BYOC image.

- [ ] **Local image registry** — `registry/registry.container` Quadlet + Traefik route
      at `registry.lab.lan`. Required before building or pulling BYOC/project images.
- [ ] **Pull/build OpenClaw image** and push to local registry (`:5000`).
- [ ] **`openshell/policies/openclaw.yaml`** — egress policy for OpenClaw. Likely
      broader than `claude-code.yaml` (may need package registries, etc.).
- [ ] **`openclaw/openclaw.container`** Quadlet unit — BYOC image, restart policy,
      volume for persistent state.
- [ ] **Auth** — `osbox --claudeai` pattern or direct volume-mount of `~/.claude/`
      depending on how OpenClaw resolves credentials.
- [ ] **Verify** `systemctl --user start openclaw` → always-on, survives reboot.

## Phase 5 — Codex sandbox

Add Codex CLI (OpenAI) as a first-class `osbox`-managed sandbox agent.

- [ ] **`openshell/policies/codex.yaml`** — egress policy for OpenAI API endpoints.
- [ ] **`--codex` flag for `osbox`** — sets `AGENT_CMD=codex`, injects `OPENAI_API_KEY`
      from `~/.secrets/codex.env`, clones host `~/.codex/` state if present.
      The `AGENT_CMD` hook is already wired — this is mostly a credential + policy block.
- [ ] **`openshell/project-settings/codex-test.json`** — committed non-secret opt-in
      settings for a test project (mirrors `bedrock-test.json` pattern).
- [ ] **Verify** `osbox codex-1 --codex --headless` → dispatch
      `openshell sandbox exec -n codex-1 -- codex -p "task"`.

## Phase 6 — Gemini CLI sandbox

Add Gemini CLI as a sandboxed agent via the same `osbox` pattern.

- [ ] **`openshell/policies/gemini.yaml`** — egress for Gemini API / GCP endpoints.
- [ ] **`--gemini` flag for `osbox`** — sets `AGENT_CMD=gemini`, injects GCP
      application-default credentials or `GOOGLE_API_KEY` from `~/.secrets/gemini.env`.
- [ ] **`openshell/project-settings/gemini-test.json`**.
- [ ] **Verify** `osbox gemini-1 --gemini --headless` → dispatch
      `openshell sandbox exec -n gemini-1 -- gemini -p "task"`.

## Phase 7 — NemoClaw + NeMo Agent Toolkit

- [ ] **NemoClaw** — deferred Docker service. Evaluate whether Podman can replace the
      Docker dependency before committing to a design.
- [ ] **NeMo Agent Toolkit orchestration** — multi-agent pipeline wiring; design TBD
      once Phases 4–6 agents are stable and the director/worker pattern is proven
      across Claude, Codex, and Gemini workers.
