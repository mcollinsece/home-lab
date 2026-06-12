# OpenShell (agent sandboxes, rootless Podman)

[OpenShell](https://github.com/NVIDIA/OpenShell) runs sandboxed coding agents
(Claude Code, Codex, etc.) as isolated containers on the homelab VM's existing
**rootless Podman** — no Docker. Phases 2–3 of
[../docs/future/ai-dev-ground.md](../docs/future/ai-dev-ground.md).

## Files
| File | Role |
|---|---|
| `gateway.env` | gateway env overrides; symlinked to `~/.config/openshell/gateway.env` |
| `policies/claude-code.yaml` | network policy for the Claude Code sandbox — **dual-auth** (Anthropic subscription + Amazon Bedrock egress); pure-L4 so SigV4 passes |

The OpenShell binary, its `openshell-gateway` systemd `--user` service, and the
mTLS certs under `~/.local/state/openshell/` are installed by
[`../bootstrap/setup-host.sh`](../bootstrap/setup-host.sh) — not committed here.

## Why `gateway.env` matters (the one gotcha)
The Debian `.deb` install binds the gateway to `127.0.0.1`, but the Podman driver
needs `0.0.0.0:17670`: sandboxes reach the gateway over the host bridge
(`host.containers.internal`), not loopback. Without it, sandboxes provision but
fail with `Policy fetch failed`. `gateway.env` sets `OPENSHELL_DRIVERS=podman`
and `OPENSHELL_BIND_ADDRESS=0.0.0.0`. mTLS still gates the wider bind.

> `openshell doctor check` always errors on Docker even when the Podman driver is
> active and working — cosmetic. Confirm the real backend in the gateway log:
> `journalctl --user -u openshell-gateway | grep 'compute driver'`.

## Reinstall / reproduce
```bash
~/home-lab/bootstrap/setup-host.sh        # installs OpenShell + links gateway.env
```

## (Re)create the Claude Code sandbox
```bash
openshell sandbox create --name claude-code --no-auto-providers \
    --policy ~/home-lab/openshell/policies/claude-code.yaml \
    --env AWS_ACCESS_KEY_ID=… --env AWS_SECRET_ACCESS_KEY=… --env AWS_REGION=us-east-1 \
    -- claude
# first run only — authenticate the Max/Pro subscription:
openshell sandbox connect claude-code
#   inside: claude login   (browser OAuth)  then  claude
```

A new sandbox starts **blank** — no provider auto-injects creds. The `--env` flags
above carry the Bedrock keys (inert until a project sets `CLAUDE_CODE_USE_BEDROCK`);
`claude login` adds the subscription. Per-project subscription↔Bedrock switching and
the full lifecycle/reproducibility notes are in
[../docs/future/ai-dev-ground.md](../docs/future/ai-dev-ground.md) (Phase 3 +
"Sandbox lifecycle") and [../docs/current/platform.md](../docs/current/platform.md).

## Everyday commands
```bash
openshell sandbox list
openshell sandbox connect claude-code
openshell policy get claude-code --full
openshell logs claude-code --tail
openshell term                                  # live TUI
```

Sandboxes are **outbound-only** — no Traefik exposure needed. Sandbox state is
ephemeral; the durable, reproducible parts are this dir + `setup-host.sh`.
