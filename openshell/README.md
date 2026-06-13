# OpenShell (agent sandboxes, Docker driver)

[OpenShell](https://github.com/NVIDIA/OpenShell) runs sandboxed coding agents
(Claude Code, Codex, etc.) as isolated containers on the homelab VM.
Phases 2–3 of [../docs/future/ai-dev-ground.md](../docs/future/ai-dev-ground.md).

## Files

| File | Role |
|---|---|
| `gateway.env` | gateway env overrides; symlinked to `~/.config/openshell/gateway.env` |
| `policies/claude-code.yaml` | network policy for the Claude Code sandbox — allows Anthropic + Bedrock egress |

The OpenShell binary, its `openshell-gateway` systemd `--user` service, and the
mTLS certs under `~/.local/state/openshell/` are installed by
[`../bootstrap/setup-host.sh`](../bootstrap/setup-host.sh) — not committed here.

## Inference: `inference.local`

All agent sandboxes route inference through OpenShell's built-in privacy gateway
(`inference.local`) rather than holding real credentials. The gateway forwards to
LiteLLM, which holds the actual Bedrock keys.

```
sandbox → inference.local → OpenShell gateway → LiteLLM (:4000) → Bedrock
```

Wire this once after LiteLLM is running:
```bash
LITELLM_KEY=$(grep LITELLM_MASTER_KEY ~/home-lab/.secrets/litellm.env | cut -d= -f2)
openshell provider create \
    --name litellm-local --type openai \
    --credential "OPENAI_API_KEY=${LITELLM_KEY}" \
    --config OPENAI_BASE_URL=http://localhost:4000/v1
openshell inference set --no-verify --provider litellm-local --model claude-sonnet-4-6
openshell inference get  # verify
```

## Why `gateway.env` matters (the one gotcha)

The Debian `.deb` install binds the gateway to `127.0.0.1`, but Docker-driver sandboxes
need `0.0.0.0:17670`: containers reach the gateway over the host bridge
(`host.docker.internal`), not loopback. Without it, sandboxes provision but fail
with `Policy fetch failed`. `gateway.env` sets `OPENSHELL_DRIVERS=docker`
and `OPENSHELL_BIND_ADDRESS=0.0.0.0`. mTLS still gates the wider bind.

> `openshell doctor check` may report a Docker error even when Docker is active —
> confirm the real backend in the gateway log:
> `journalctl --user -u openshell-gateway | grep 'compute driver'`.
> Expect `Using compute driver driver=docker`.

## Reinstall / reproduce

```bash
~/home-lab/bootstrap/setup-host.sh   # installs OpenShell + links gateway.env
```

## (Re)create the Claude Code sandbox

Sandboxes use `inference.local` — no raw credentials in the sandbox:

```bash
openshell sandbox create --name claude-code --no-auto-providers \
    --policy ~/home-lab/openshell/policies/claude-code.yaml \
    --env ANTHROPIC_BASE_URL=https://inference.local \
    --env ANTHROPIC_API_KEY=unused \
    -- claude
# First run only — only needed if using subscription auth alongside inference.local:
openshell sandbox connect claude-code
#   inside: claude login   (browser OAuth)
```

> **Note:** The previous pattern (`--env AWS_ACCESS_KEY_ID=…`) is deprecated.
> Inference now routes through `inference.local` → LiteLLM → Bedrock. The sandbox
> holds no real credentials.

## NemoClaw sandbox

NemoClaw manages its own OpenClaw sandbox automatically. After `nemoclaw onboard`,
the sandbox appears in `openshell sandbox list` like any other. NemoClaw handles its
lifecycle; use `nemoclaw <name> connect` or `http://127.0.0.1:18789` to access it.

## Everyday commands

```bash
openshell sandbox list
openshell sandbox connect claude-code
openshell policy get claude-code --full
openshell logs claude-code --tail
openshell inference get                 # show active inference route
openshell term                          # live TUI
```

Sandboxes are **outbound-only** — no Traefik exposure needed. Sandbox state is
ephemeral; the durable, reproducible parts are this dir + `setup-host.sh`.
