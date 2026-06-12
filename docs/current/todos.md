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
- [x] **Pushed to GitHub** — branch `traefik-portainer-on-vm`.
- [ ] **Test `setup-host.sh` reproducibility — on a THROWAWAY, not `.51`.**
      Do NOT reset the live VM: it holds the working OpenShell + authenticated
      `claude-code` sandbox; reproducing by destroying it is backwards. Use a
      Proxmox full-clone of this VM, or a fresh Debian 13 VM.

      1. Provision the throwaway (user `debian`, uid 1000, sudo). If it's a clone,
         change **hostname + IP + MAC** so it doesn't collide with `.51` on the LAN.
      2. `git clone <repo> ~/home-lab && ~/home-lab/bootstrap/setup-host.sh`
      3. Verify the script's work:
         - `node -v` (≥22), `openshell --version` (= 0.0.62)
         - `systemctl --user is-active openshell-gateway podman.socket`
         - gateway log: `journalctl --user -u openshell-gateway | grep 'compute driver'`
           → `driver=podman`
         - `openshell status` → Connected
      4. Verify the manual post-steps the script does NOT do (by design):
         - quadlets: `systemctl --user start traefik portainer && podman ps`
         - sandbox: `openshell sandbox create --name claude-code --no-auto-providers \
             --policy ~/home-lab/openshell/policies/claude-code.yaml -- claude`
           then `claude login` (interactive OAuth)
         - AdGuard `*.lab.lan` wildcard (lives on the AdGuard LXC, off-host)
         - Podman secrets (none yet; Phase 3)
      5. Confirm OpenShell mTLS re-pairs cleanly on the fresh install (certs are
         regenerated under `~/.local/state/openshell/tls/`, so they are NOT
         committed — a rebuild should just work).
      6. Tear down the throwaway.

      > If steps 4's quadlet-start or sandbox-create feel like they *should* be in
      > the script: say so and I'll fold `systemctl --user start traefik portainer`
      > (and optionally the sandbox create) into `setup-host.sh`.
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
