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
- [x] **`setup-host.sh` reproducibility — verified 2026-06-12 (idempotent re-run).**
      Re-ran on `.51` and confirmed every check below (Node 22, OpenShell `v0.0.62`,
      gateway + `podman.socket` active, `driver=podman`, bind `0.0.0.0:17670`,
      `Connected`), plus the manual post-steps: `claude-code` sandbox `Ready`/healthy,
      `claude login` + a live prompt through the egress policy, and `portainer.lab.lan`
      → Traefik 200. The path snag hit on the way (relative `--policy` path) is now in
      the runbook.

      > **Caveat — what this did *not* prove:** this was an idempotent re-run over the
      > already-built host, **not** the clean snapshot-revert test described below. The
      > from-absolute-zero rebuild is therefore unproven (an ordering/dependency bug
      > could hide behind pre-existing state). Judged acceptable for a transitional dev
      > host: the repo + runbook — not a VM snapshot — are the durability guarantee, so
      > the `working-openshell-claude` snapshot can be deleted. Run the clean-revert
      > procedure below before/at the real migration to a new box.

- [ ] **(Optional, for the real migration) Clean snapshot-revert reproducibility test.**
      Safe because a working snapshot is the escape hatch. Troubleshooting runbook:
      [../../bootstrap/TROUBLESHOOTING.md](../../bootstrap/TROUBLESHOOTING.md).

      0. **Push everything to GitHub FIRST.** A revert wipes anything not on GitHub —
         including Claude's local memory under `~/.claude/`. The repo (incl.
         TROUBLESHOOTING.md) is the only thing that survives, so confirm
         `git status` is clean and pushed before going further.
      1. **Snapshot the working state now** (Proxmox → snapshot, e.g. `working-openshell-claude`).
         This is the rollback target if the test goes badly.
      2. **Revert to the pre-setup snapshot** (clean Debian + Traefik/Portainer, before
         today's AI build). If no such snapshot exists, this approach can't give a truly
         clean test — fall back to a fresh VM, or just re-run bootstrap over the current
         host (idempotent, but proves less).
      3. `git clone <repo> ~/home-lab && ~/home-lab/bootstrap/setup-host.sh`
      4. Verify the script's work:
         - `node -v` (≥22), `openshell --version` (= 0.0.62)
         - `systemctl --user is-active openshell-gateway podman.socket`
         - `journalctl --user -u openshell-gateway | grep 'compute driver'` → `driver=podman`
         - `ss -tlnp | grep 17670` → `0.0.0.0:17670` (the #1 gotcha — see runbook)
         - `openshell status` → Connected
      5. Manual post-steps the script does NOT do (expected — see runbook):
         - quadlets: `systemctl --user start traefik portainer && podman ps`
           (Portainer admin account resets — its data is a Podman volume, not git)
         - sandbox: `openshell sandbox create --name claude-code --no-auto-providers \
             --policy ~/home-lab/openshell/policies/claude-code.yaml -- claude` then `claude login`
         - AdGuard wildcard (off-host) and Podman secrets (none yet) — unaffected
      6. **If it fails:** troubleshoot with TROUBLESHOOTING.md; if badly, revert to the
         `working-openshell-claude` snapshot from step 1.
      7. On success, note any fixes needed and fold them back into `setup-host.sh`.

      > If steps 5's quadlet-start / sandbox-create should be automated, say so and I'll
      > fold `systemctl --user start traefik portainer` (and optionally the sandbox
      > create) into `setup-host.sh` to make the rebuild closer to one-shot.
- [ ] **Secrets are not in git by design** — document/script how to re-create them on
      a new host from my password manager. Two distinct stores: (a) Podman secrets for
      quadlet services (`anthropic_api_key` etc. — none yet); (b) **sandbox-resident**
      creds for agents — subscription via `claude login`, AWS Bedrock keys via the
      sandbox `~/.claude/settings.json` `env` block (see Phase 3). A snapshot revert
      wipes both → re-add manually.

## Phase 3 — Bedrock dual auth (IN PROGRESS — decided us-east-1 + Sonnet 4.6)
Design: subscription (OAuth) stays the **default**; Bedrock is **opt-in per
project**. Correction baked in 2026-06-12: OpenShell v0.0.62 has **no AWS provider
type** and can't SigV4-sign, so the original `openshell provider create` plan is
dead — AWS keys live **inside the sandbox as env vars** (Claude Code's AWS SDK
signs). Egress policy already handles Bedrock.

- [x] **Network policy → Bedrock egress** — `openshell/policies/claude-code.yaml`
      v2 hot-reloaded onto the live `claude-code` sandbox (bedrock-runtime
      us-east-1/2 + us-west-2, bedrock.us-east-1). No `sts.*` for static keys.
- [ ] **Create a scoped IAM user** — `bedrock:InvokeModel`,
      `InvokeModelWithResponseStream`, `ListInferenceProfiles`, `GetInferenceProfile`
      on `inference-profile/*` + `foundation-model/*`, plus the marketplace
      subscribe condition (see Claude Code Bedrock IAM block). Store keys in my vault.
      First-time only: submit the Bedrock model-access use-case form in the console.
- [ ] **Put AWS keys in the sandbox** (no rebuild) — add to the sandbox user
      `~/.claude/settings.json` `env` block (`AWS_ACCESS_KEY_ID`,
      `AWS_SECRET_ACCESS_KEY`, `AWS_REGION=us-east-1`) via `openshell sandbox exec
      claude-code`. Keys stay out of git. (On a future rebuild, prefer
      `openshell sandbox create … --env AWS_ACCESS_KEY_ID=… …` instead.)
- [ ] **Bedrock project settings** — in a test project inside the sandbox, write
      `.claude/settings.json` with `{"env":{"CLAUDE_CODE_USE_BEDROCK":"1",
      "AWS_REGION":"us-east-1","ANTHROPIC_MODEL":"us.anthropic.claude-sonnet-4-6"}}`.
- [ ] **Verify** — `cd` into the Bedrock project, run `claude`, confirm `/status`
      shows `Amazon Bedrock`, run a prompt; `cd` to any other dir → back to
      subscription. (Egress already proven for both paths via policy v2.)

## Later phases (no blockers, just sequencing)
- [ ] Phase 4 — Codex sandbox (`OPENAI_API_KEY`) + Gemini CLI BYOC sandbox.
- [ ] Phase 5 — always-on OpenClaw assistant (BYOC on Podman).
- [ ] Local image registry (`registry/registry.container`, `:5000`) — pre-work for
      building BYOC/project images locally.
- [ ] Phase 6 — NemoClaw experiment (the one Docker service; deferred).
- [ ] Phase 7 — NeMo Agent Toolkit orchestration.
