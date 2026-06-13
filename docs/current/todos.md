# Punchlist

See [platform.md](platform.md) for current state and
[../future/ai-dev-ground.md](../future/ai-dev-ground.md) for the overall arc.

## Phase 4 — OpenClaw (remaining)

OpenClaw is live at `https://openclaw.lab.lan`. Two housekeeping steps remain:

- [ ] **Configure OpenShell backend in OpenClaw UI** — Settings → Gateway → OpenShell →
      URL: `http://host.containers.internal:17670`. This wires OpenClaw to the sandbox
      control plane so it can create/manage worker sandboxes from the director.
- [ ] **Verify Bedrock fallback** — `podman exec openclaw openclaw models list` should
      show `amazon-bedrock/us.anthropic.claude-sonnet-4-6` alongside the `claude-cli` primary.

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
      Codex, and Gemini workers. Design TBD once Phases 5–6 agents are stable and the
      director/worker dispatch pattern is proven at scale.

## Phase 8 — OpenClaw alternative provider support

Research and wire up the five OAuth/subscription providers OpenClaw supports natively,
as alternatives to Bedrock for directing agent tasks.

- [ ] **OpenAI / ChatGPT** — `openclaw onboard --auth-choice openai`; ChatGPT Plus/Pro
      subscription OAuth. Test with `openai/gpt-4o` or `openai/o3`.
- [ ] **xAI Grok** — SuperGrok / X Premium OAuth; models `grok-4.3` and `grok-build-0.1`.
      API key fallback via `XAI_API_KEY` also supported.
- [ ] **Google Gemini CLI** — Google account OAuth via
      `openclaw models auth login --provider google-gemini-cli`. ⚠️ reports of Google
      account restrictions for third-party clients — evaluate risk before enabling.
- [ ] **GitHub Copilot** — subscription-native, no API key. Research supported models
      and whether task-dispatch quality is adequate for a director role.
- [ ] **OpenRouter** — OAuth or `OPENROUTER_API_KEY`; acts as a multi-model gateway.
      Useful for provider fallback or model-routing without per-provider accounts.
- [ ] **Document** which provider(s) to recommend as the default alternative to Bedrock
      and update `openclaw.env.example` + `init-secrets.sh` accordingly.
