# Punchlist — things for me (the human) to do

Manual, sensitive, or interactive steps the bootstrap can't do. See
[platform.md](platform.md) for current state and
[../future/ai-dev-ground.md](../future/ai-dev-ground.md) for the phase plan.

## Phase 2 — COMPLETE ✅
- [x] **Claude Code authenticated** — `claude login` (Max/Pro OAuth) succeeded.
- [x] **AdGuard DNS rewrites** — `*.lab.lan → .51`, `adguard.lan → .53`,
      `debian.lan → .51`. Verified `portainer.lab.lan → .51 → Traefik 200`.

  > Optional: the VM resolves via the router (`.1`), not AdGuard, so `*.lab.lan`
  > doesn't resolve *from the VM*. Point its resolver at `192.168.0.53` only if you
  > want local name resolution on the VM — not required.

## Reproducibility / migration prep (server is not its forever home)
- [ ] **Push this repo to GitHub** and confirm a clean clone + `bootstrap/setup-host.sh`
      reproduces the host on a fresh Debian 13 VM (dry-run on a throwaway VM before trusting it).
- [ ] **Back up OpenShell mTLS state** decision: `~/.local/state/openshell/tls/` is
      regenerated on install, so it does NOT need committing — confirm a rebuilt host
      re-pairs cleanly rather than trying to preserve certs.
- [ ] **Podman secrets are not in git by design** — document/script how to re-create
      them on a new host (`anthropic_api_key`, AWS Bedrock creds) from my password manager.

## Phase 3 — Bedrock dual auth (needs my AWS creds)
- [ ] Create a scoped IAM user (`bedrock:InvokeModel*` only); store keys in my vault.
- [ ] `openshell provider create` for AWS; add `bedrock-runtime.<region>` + `sts.<region>`
      to a Bedrock project policy. Verify the current Bedrock model ID.

## Later phases (no blockers, just sequencing)
- [ ] Phase 4 — Codex sandbox (`OPENAI_API_KEY`) + Gemini CLI BYOC sandbox.
- [ ] Phase 5 — always-on OpenClaw assistant (BYOC on Podman).
- [ ] Local image registry (`registry/registry.container`, `:5000`) — pre-work for
      building BYOC/project images locally.
- [ ] Phase 6 — NemoClaw experiment (the one Docker service; deferred).
- [ ] Phase 7 — NeMo Agent Toolkit orchestration.
