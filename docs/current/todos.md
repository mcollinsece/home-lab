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
- [ ] **`bootstrap/new-claude-sandbox.sh` — reproducible auth-ready sandbox spawn.**

      New sandboxes start blank (no provider auto-injects creds; see platform.md
      "Agent sandbox lifecycle"). The script covers two auth modes, selectable at
      run-time:

      **Usage (flags are composable — combine freely):**
      ```
      new-claude-sandbox.sh <name> [--bedrock] [--claudeai | --clone <src-sandbox>]
      ```
      Examples:
      ```
      new-claude-sandbox.sh worker-1 --bedrock                  # Bedrock keys; must claude login
      new-claude-sandbox.sh worker-1 --claudeai                 # Host auth; no login needed
      new-claude-sandbox.sh worker-1 --clone claude-code        # Clone from another sandbox
      new-claude-sandbox.sh worker-1 --bedrock --claudeai       # Both: full replica of director
      new-claude-sandbox.sh worker-1 --bedrock --clone <src>    # Both: Bedrock + cloned sandbox
      ```

      **`--bedrock`**
      - Sources AWS keys from `~/home-lab/.secrets/bedrock.env` (gitignored, never
        argv — keys go to `--env` flags only via `source`; never in `$@` or history).
        File format:
        ```bash
        AWS_ACCESS_KEY_ID=AKIAxxxxx
        AWS_SECRET_ACCESS_KEY=xxxxx
        AWS_REGION=us-east-1
        ```
      - Passes keys as `--env` flags to `openshell sandbox create`. Keys are inert
        until a project sets `CLAUDE_CODE_USE_BEDROCK=1`.
      - Without `--claudeai` or `--clone`: prints **"Now run: openshell sandbox
        connect <name> → claude login"** (OAuth can't be scripted).

      **`--claudeai`**
      - Clones the subscription token from the **host-level Claude Code session**
        (the director). Source: `~/.claude/credentials.json` — direct local file
        read, no sandbox exec. Trade-off: new sandbox shares the host OAuth session;
        token refreshes are transparent on Max/Pro.
      - Steps: read → `mktemp` (mode 600, `trap`-deleted on exit) → create sandbox
        → `openshell sandbox exec mkdir -p /sandbox/.claude` → `openshell sandbox
        upload` credentials.json into place.
      - Prints: **"Claude.ai token cloned from host director. No claude login needed."**

      **`--clone <src-sandbox>`**
      - Generic sandbox-to-sandbox credential clone. Copies `/sandbox/.claude/`
        from an existing running OpenShell sandbox into the new one. Agent-agnostic:
        will work for Codex, Gemini, or any future sandbox type once those are
        added — a Codex worker can clone from another Codex sandbox, etc.
      - Steps: `openshell sandbox exec -n <src> -- cat /sandbox/.claude/.credentials.json`
        → `mktemp` (mode 600, `trap`-deleted) → create sandbox → upload into place.
      - Use case: spinning up additional workers that replicate an existing sandbox's
        auth state exactly, or cloning a sandbox that has already done `claude login`
        rather than going back to the host director.

      **Common post-create step (all modes):**
      - Optionally uploads `openshell/project-settings/bedrock-test.json` to
        `/sandbox/bedrock-test/.claude/settings.json` as the example Bedrock
        opt-in project (non-secret; committed in git).
      - Prints a summary: sandbox name, flags used, policy version applied,
        one-liner to connect.

      **Prerequisites the script checks and aborts on:**
      - `openshell status` → Connected (gateway running)
      - `~/home-lab/.secrets/bedrock.env` readable (`--bedrock`)
      - `~/.claude/credentials.json` readable (`--claudeai`)
      - `<src-sandbox>` is `Ready` (`--clone`)

      **File layout to create:**
      - `bootstrap/new-claude-sandbox.sh` — the script (executable, gitignored
        `.secrets/` already in `.gitignore`)
      - `openshell/project-settings/bedrock-test.json` — the committed non-secret
        Bedrock project settings (`CLAUDE_CODE_USE_BEDROCK=1` etc.) that the script
        can upload as a usage example
      - `~/home-lab/.secrets/bedrock.env` — secrets file, gitignored, populated
        from password manager after rotate (see key-rotation item above)

      > **Host director / sandboxed workers pattern.**
      > A Claude Code process running directly on the host (outside any OpenShell
      > policy) has full filesystem access + the `openshell` CLI — it can spawn
      > sandboxes, exec commands into them, upload/download files, and read their
      > output. That makes it a natural **orchestrator/brain**: the host session
      > directs; each OpenShell sandbox is an isolated worker with deny-by-default
      > egress. OpenShell's primary job is isolation/containerization; the host
      > director is what gives that fleet intentional shape.
      >
      > The three auth flags cover the two directions auth can flow:
      > - `--claudeai` — director → worker (host session seeds a new sandbox)
      > - `--clone <src>` — worker → worker (any running sandbox seeds another;
      >   agent-agnostic, works for Codex/Gemini sandboxes in Phase 4)
      > - `--bedrock` — orthogonal (AWS keys, combinable with either)
      >
      > Phase 4 extension: each new agent family adds its own host-credential flag
      > alongside `--clone` (which already works generically):
      > - `--codex` — clones host `~/.codex/` creds / `OPENAI_API_KEY`
      > - `--gemini` — clones host GCP application-default token
      > Whether that stays as per-agent scripts (`new-codex-sandbox.sh`) or merges
      > into one `new-sandbox.sh --agent <type>` is an open decision for Phase 4.

## Phase 3 — Bedrock dual auth — COMPLETE ✅ (2026-06-12, us-east-1 + Sonnet 4.6)
Design: subscription (OAuth) stays the **default**; Bedrock is **opt-in per
project**. Correction baked in 2026-06-12: OpenShell v0.0.62 has **no AWS provider
type** and can't SigV4-sign, so the original `openshell provider create` plan was
dead — AWS keys live **inside the sandbox as env vars** (Claude Code's AWS SDK
signs); egress handled by the policy.

- [x] **Network policy → Bedrock egress** — `openshell/policies/claude-code.yaml`
      v2 hot-reloaded onto the live `claude-code` sandbox (bedrock-runtime
      us-east-1/2 + us-west-2, bedrock.us-east-1). No `sts.*` for static keys.
- [x] **Scoped IAM user** created (`bedrock:InvokeModel*` + inference-profile read
      + marketplace subscribe condition); Sonnet 4.6 model access granted in us-east-1.
- [x] **AWS keys in the sandbox** — merged into the sandbox user
      `~/.claude/settings.json` `env` block (inert until a project opts in);
      subscription `.credentials.json` untouched. (On rebuild: `sandbox create … --env`.)
- [x] **Bedrock project settings** — `/sandbox/bedrock-test/.claude/settings.json`
      sets `CLAUDE_CODE_USE_BEDROCK=1` + `us.anthropic.claude-sonnet-4-6`.
- [x] **Verified both paths** — `claude -p` from `/sandbox/bedrock-test` → Bedrock
      Sonnet 4.6 (`bedrock-ok`); from `/sandbox` → subscription (`subscription-ok`).
      `cd`-based switch works, no re-auth.

> ⚠️ **Rotate the current IAM access key** — it was pasted in a Claude chat to do
> the setup, so it lives in that transcript + host shell history. Generate a fresh
> key in IAM, re-run the in-sandbox merge with the new one, delete the old key.

## Later phases (no blockers, just sequencing)
- [ ] Phase 4 — Codex sandbox (`OPENAI_API_KEY`) + Gemini CLI BYOC sandbox.
- [ ] Phase 5 — always-on OpenClaw assistant (BYOC on Podman).
- [ ] Local image registry (`registry/registry.container`, `:5000`) — pre-work for
      building BYOC/project images locally.
- [ ] Phase 6 — NemoClaw experiment (the one Docker service; deferred).
- [ ] Phase 7 — NeMo Agent Toolkit orchestration.
