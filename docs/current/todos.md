# Punchlist

See [platform.md](platform.md) for current state and
[../future/ai-dev-ground.md](../future/ai-dev-ground.md) for the overall arc.

## Phase 4 — OpenClaw finish-up

Infrastructure is built and committed. The remaining steps are manual (secrets,
interactive config, and a custom image build).

- [ ] **`init-secrets`** — run once after any clean rebuild to create Podman secrets
      (`bedrock_aws_*`, `anthropic_api_key`) and `.secrets/bedrock.env`.
- [ ] **`cp openclaw/openclaw.env.example openclaw/openclaw.env`** — fill in (or accept
      the default `OPENSHELL_GATEWAY_URL=http://host.containers.internal:17670`).
- [ ] **`systemctl --user start openclaw`** — start the OpenClaw Quadlet.
- [ ] **Configure OpenShell backend in OpenClaw UI** — `http://openclaw.lab.lan` →
      Settings → Gateway → OpenShell → URL: `http://host.containers.internal:17670`.
- [ ] **Custom image with openshell CLI** — once gateway config is verified:
      ```
      podman build -t registry.lab.lan/openclaw:latest openclaw/
      podman push --tls-verify=false registry.lab.lan/openclaw:latest
      ```
      Then update `openclaw/openclaw.container` `Image=` to `registry.lab.lan/openclaw:latest`
      and restart. This bakes the openshell CLI into the container so OpenClaw can
      create/manage worker sandboxes directly.

## Phase 5 — Codex sandbox

Add OpenAI Codex CLI as a first-class `osbox`-managed agent.

- [ ] **`init-secrets` update** — add Codex section: prompts for `OPENAI_API_KEY`,
      writes `.secrets/codex.env`, creates `codex_openai_api_key` Podman secret.
- [ ] **`openshell/policies/codex.yaml`** — egress policy for OpenAI API endpoints.
- [ ] **`--codex` flag for `osbox`** — sets `AGENT_CMD=codex`, sources `OPENAI_API_KEY`
      from `.secrets/codex.env`. The `AGENT_CMD` hook is already wired.
- [ ] **`openshell/project-settings/codex-test.json`** — committed non-secret opt-in
      settings (mirrors `bedrock-test.json` pattern).
- [ ] **Verify** `osbox codex-1 --codex --headless` → dispatch
      `openshell sandbox exec -n codex-1 -- codex -p "task"`.

## Phase 6 — Gemini CLI sandbox

Add Google Gemini CLI as a sandboxed agent via the same `osbox` pattern.

- [ ] **`init-secrets` update** — add Gemini section: `GOOGLE_API_KEY`, writes
      `.secrets/gemini.env`, creates `gemini_api_key` Podman secret.
- [ ] **`openshell/policies/gemini.yaml`** — egress for Gemini API / GCP endpoints.
- [ ] **`--gemini` flag for `osbox`** — sets `AGENT_CMD=gemini`, sources key from
      `.secrets/gemini.env`.
- [ ] **`openshell/project-settings/gemini-test.json`**.
- [ ] **Verify** `osbox gemini-1 --gemini --headless` → dispatch
      `openshell sandbox exec -n gemini-1 -- gemini -p "task"`.

## Phase 7 — NemoClaw + NeMo Agent Toolkit

- [ ] **NemoClaw** — evaluate whether rootless Podman can replace the Docker dependency
      before committing to a design. If yes, run as an OpenShell BYOC sandbox (same
      control plane as other agents); if no, Quadlet with Docker socket.
- [ ] **NeMo Agent Toolkit orchestration** — multi-agent pipeline wiring across Claude,
      Codex, and Gemini workers. Design TBD once Phases 4–6 agents are stable and the
      director/worker dispatch pattern is proven at scale.
