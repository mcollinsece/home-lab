# Punchlist

See [platform.md](platform.md) for current state and
[../future/ai-dev-ground.md](../future/ai-dev-ground.md) for the overall arc.

## Phase 4 — OpenClaw (remaining)

OpenClaw is live at `https://openclaw.lab.lan` with the claude-cli primary backend working.

- [ ] **Configure OpenShell backend in OpenClaw UI** — Settings → Gateway → OpenShell →
      URL: `http://host.containers.internal:17670`. This wires OpenClaw to the sandbox
      control plane so it can create/manage worker sandboxes from the director.
- [ ] **Fix Bedrock fallback model ID** — `openclaw models list` shows
      `amazon-bedrock/us.anthropic.claude-sonnet-4-6` but invocation fails with
      `model_not_found`. OpenClaw's Bedrock provider likely needs the full versioned
      inference-profile ARN (e.g. `us.anthropic.claude-sonnet-4-6-20250514-v1:0`).
      Check the AWS Bedrock console for the exact cross-region inference profile ID and
      update `openclaw.env` / `openclaw.json` accordingly.

## Phase 4.5 — LiteLLM proxy

LiteLLM is the single OpenAI-compatible routing layer for all inference in the
homelab. OpenClaw talks to it directly over ai-net. OpenShell sandboxes reach it
via `inference.local` (OpenShell's built-in privacy router, configured to forward
to LiteLLM). CLI tools inside sandboxes (claude-code, gemini, codex, grok) never
see real credentials — Bedrock provides the model, the CLIs provide the agentic
runtime. Adding a new provider later is a one-line addition to `litellm/config.yaml`.

See **[litellm-proxy.md](litellm-proxy.md)** for the full architecture, config
files, and toggle mechanism.

### Step 1 — LiteLLM Quadlet

- [ ] **Verify Bedrock model ID** — AWS console → Bedrock → Inference → Cross-region
      inference → us-east-1. Confirm exact ID for Claude Sonnet 4.6
      (format: `us.anthropic.claude-sonnet-4-6-<date>-v1:0`). Update
      `litellm/config.yaml` before starting the service.
- [ ] **Create `litellm/` directory** — `litellm.container`, `litellm.env.example`,
      `config.yaml` (copy from litellm-proxy.md spec).
- [ ] **Add `litellm_master_key` Podman secret and update `init-secrets.sh`**:
      `openssl rand -hex 32 | podman secret create litellm_master_key -`
      Write the key to `.secrets/litellm.env` (`LITELLM_MASTER_KEY=<value>`).
      Add a LiteLLM section to `init-secrets.sh` so rebuilds reproduce it.
- [ ] **Symlink Quadlet and start**:
      `ln -s ~/home-lab/litellm/litellm.container ~/.config/containers/systemd/`
      `systemctl --user daemon-reload && systemctl --user start litellm`
- [ ] **Smoke-test LiteLLM**:
      `curl http://localhost:4000/v1/models -H "Authorization: Bearer <master_key>"`
      Should return a model list including `claude-sonnet-4-6`.

### Step 2 — Wire OpenShell gateway to LiteLLM

- [ ] **Create OpenShell provider pointing to LiteLLM**:
      ```bash
      openshell provider create \
          --name litellm-local --type openai \
          --credential OPENAI_API_KEY=$(grep LITELLM_MASTER_KEY ~/.secrets/litellm.env | cut -d= -f2) \
          --config OPENAI_BASE_URL=http://localhost:4000/v1
      ```
      (Gateway runs on host, so `localhost:4000` reaches LiteLLM's published port.)
- [ ] **Set inference route**:
      `openshell inference set --provider litellm-local --model claude-sonnet-4-6`
- [ ] **Verify**: `openshell inference get` — confirm provider=litellm-local,
      model=claude-sonnet-4-6.
- [ ] **Test sandbox inference**:
      `openshell sandbox exec -n claude-code -- claude -p "say hi"` with
      `ANTHROPIC_BASE_URL=https://inference.local ANTHROPIC_API_KEY=unused`
      in the sandbox env. Check LiteLLM logs confirm the request arrived.

### Step 3 — Wire OpenClaw director to LiteLLM

- [ ] **Register LiteLLM in OpenClaw** — apply config patch inside the container:
      ```bash
      echo '{
        "models": {"providers": {"litellm": {"baseUrl": "http://litellm:4000/v1", "apiKey": "<master_key>"}}},
        "agents": {"defaults": {"model": {"primary": "litellm/claude-sonnet-4-6", "fallbacks": ["claude-cli/claude-sonnet-4-6"]}}}
      }' | podman exec -i --user node openclaw openclaw config patch --stdin
      systemctl --user restart openclaw
      ```
- [ ] **Remove broken `amazon-bedrock/...` from openclaw.json** — already replaced
      by the patch above; confirm with `openclaw config get agents.defaults.model`.
- [ ] **Remove Bedrock secrets from `openclaw.container`** — delete the three
      `Secret=bedrock_aws_*` lines; Bedrock creds now live only in `litellm.container`.
      Rebuild OpenClaw image and restart.
- [ ] **Test director via LiteLLM**:
      `podman exec --user node openclaw openclaw agent --local --agent main --message "say hi"`
      Should respond via `litellm/claude-sonnet-4-6` → Bedrock.

### Step 4 — Simplify osbox + update docs

- [ ] **Update `osbox`** — replace `--bedrock` credential injection with
      `ANTHROPIC_BASE_URL=https://inference.local ANTHROPIC_API_KEY=unused`
      in new sandbox creates. Remove AWS credential injection from `--bedrock` path.
- [ ] **Update `setup-host.sh`** — add `litellm/` to Quadlet symlink scan; add
      OpenShell provider creation + inference set step; add `litellm_master_key`
      to the manual-steps block.
- [ ] **Update `openclaw.env.example`** — replace `amazon-bedrock/...` model comment
      with `litellm/claude-sonnet-4-6`.

## Phase 8 — OpenClaw rootless credential access

Currently the openclaw container image sets `USER root` so the `entrypoint.sh` wrapper
can `chmod 644` the host-mounted `.credentials.json` and `.claude.json` at startup before
dropping to the `node` user via `runuser`. This works, but it permanently makes those
files world-readable on the host.

The right fix is to avoid the chmod entirely by ensuring the container's `node` user
(uid 1000 inside the container) maps to the same host uid as `debian` (uid 1000), so
it can read the 600-mode credential files directly. In rootless Podman the mapping is
currently `container uid 0 = host uid 1000`, which is why root is needed today.

- [ ] **Evaluate `--userns=keep-id`** — `PodmanArgs=--userns=keep-id` in the Quadlet maps
      container uid 1000 (node) to host uid 1000 (debian). Node can then read 600-mode
      creds directly. Requires re-chowning the state volume files first (they were written
      under the old uid mapping). Test by stopping openclaw, running
      `podman unshare chown -R 1000:1000 <state-vol>`, adding the PodmanArgs, and
      reverting the Containerfile `USER` back to `node`.
- [ ] **Revert Containerfile to `USER node`** — once the userns approach is confirmed,
      remove `USER root` and `entrypoint.sh`; the `node` user will own everything natively.
- [ ] **Revert credential chmod** — remove `chmod 644` from entrypoint; `.credentials.json`
      and `.claude.json` stay at mode 600 on the host.

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

## Phase 9 — OpenClaw alternative provider support

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
