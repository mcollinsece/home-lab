# Bootstrap / OpenShell troubleshooting

Runbook for reproducing the host with [`setup-host.sh`](setup-host.sh) — written
from the actual failure modes hit during builds. Lives in the repo on purpose: after
a VM snapshot revert this is the only copy you have.

## How the script is ordered (don't reorder)

1. base pkgs → Node 22 → Docker Engine → linger → insecure registry config
2. **OpenShell install** — the gateway starts here on its default `127.0.0.1` bind
3. **gateway.env symlink + gateway restart** — this flips the gateway to
   `0.0.0.0` bind + the `docker` driver. Step 3 *must* run after step 2.

## Symptom → cause → fix

### Sandbox stuck in `Error`; logs show `Policy fetch failed after 5 attempts: failed to connect to OpenShell server`

**The #1 gotcha.** The gateway is bound to `127.0.0.1`. Docker sandbox containers
reach the gateway over the host bridge (`host.docker.internal` → bridge gateway IP),
not loopback, so they can't connect.

- Check the bind: `ss -tlnp | grep 17670` → must be `0.0.0.0:17670`, **not** `127.0.0.1`.
- Check config: `ls -l ~/.config/openshell/gateway.env` (should be a symlink to the repo)
  and `grep BIND ~/.config/openshell/gateway.env` → `OPENSHELL_BIND_ADDRESS=0.0.0.0`.
- Fix: ensure the symlink exists, then `systemctl --user restart openshell-gateway`.

### `openshell doctor check` reports an error

Likely cosmetic. Confirm the real backend instead:
```bash
journalctl --user -u openshell-gateway | grep -E 'compute driver|Connected to Docker'
```
Expect `Using compute driver driver=docker`.

### Gateway came up on the wrong driver

`gateway.env` wasn't loaded. Verify the symlink, `OPENSHELL_DRIVERS=docker`, and that
Docker is running: `docker info`. Restart the gateway:
```bash
systemctl --user restart openshell-gateway
```

### `docker compose up -d` fails with "env file not found"

Secrets not yet populated. Run `init-secrets` first, then retry. The compose file
requires `.secrets/bedrock.env` and `.secrets/litellm.env` to exist before LiteLLM
can start.

### LiteLLM starts but model list is empty (`{"data": [], "object": "list"}`)

The config file isn't being loaded. Check:
```bash
docker compose -f ~/home-lab/docker/compose.yml logs litellm | head -40
```
Common cause: `command:` in compose.yml doesn't include `--config /app/config.yaml`.
Verify the compose file has `command: ["--config", "/app/config.yaml", "--port", "4000"]`.

### LiteLLM returns 400 on Bedrock requests

Bedrock model ID mismatch. Claude 4.x cross-region inference profiles use
`us.anthropic.claude-sonnet-4-6` (no date suffix). Verify in the AWS console:
Bedrock → Inference → Cross-region inference. Update `litellm/config.yaml` and restart.

### `claude login` → `Failed to connect to <host>` / `ERR_BAD_REQUEST` inside sandbox

Deny-by-default egress blocked a host the login flow needs. Add it to
`openshell/policies/claude-code.yaml`, then hot-reload onto the running sandbox:
```bash
openshell policy set claude-code --policy openshell/policies/claude-code.yaml --wait
```
Known-good host set (already in the committed policy): `api.anthropic.com`,
`platform.claude.com`, `claude.ai`, `console.anthropic.com`, `statsig.anthropic.com`,
`sentry.io`.

### `openshell inference set` fails with embeddings error

Normal — Bedrock doesn't support the embeddings probe. Use `--no-verify`:
```bash
openshell inference set --no-verify --provider litellm-local --model claude-sonnet-4-6
```

### `openshell logs <name> --tail` hangs

`--tail` follows the stream (never returns in a script). Use it without `--tail`, or
go straight to: `docker logs openshell-sandbox-<name>` (in-container supervisor stderr).

### Podman-based sandboxes disappeared after Docker migration

Expected. The OpenShell driver was switched from `podman` to `docker`
(see `openshell/gateway.env`). Old Podman-managed sandbox containers are orphaned.
Recreate them:
```bash
openshell sandbox create --name claude-code --no-auto-providers \
    --policy openshell/policies/claude-code.yaml \
    --env ANTHROPIC_BASE_URL=https://inference.local \
    --env ANTHROPIC_API_KEY=unused \
    -- claude
```

### `apt install nodejs` prints `dpkg-preconfigure: unable to re-open stdin`

Harmless — just means no TTY. Node still installs.

## Where to look first

| What | Command |
|---|---|
| Gateway health | `openshell status` · `systemctl --user status openshell-gateway` |
| Gateway logs | `journalctl --user -u openshell-gateway -n 100 --no-pager` |
| Docker service health | `docker compose -f ~/home-lab/docker/compose.yml ps` |
| LiteLLM logs | `docker compose -f ~/home-lab/docker/compose.yml logs -f litellm` |
| Sandbox phase | `openshell sandbox list` |
| Sandbox internals | `docker logs openshell-sandbox-<name>` |
| Listening bind | `ss -tlnp | grep 17670` |
| Inference route | `openshell inference get` |

## After a clean snapshot revert — expected, not bugs

- **OpenShell mTLS** certs regenerate on install (`~/.local/state/openshell/tls/`,
  not in git) — the gateway re-pairs automatically.
- **Portainer** admin account + data live in a Docker volume (runtime state, not
  git) → you'll repeat Portainer's first-run setup.
- **Docker Compose services** — re-run `docker compose -f ~/home-lab/docker/compose.yml up -d`
  after `init-secrets`.
- **NemoClaw sandbox + `claude login`** — re-run `nemoclaw onboard` after the
  host is rebuilt. The onboard wizard re-creates / reconfigures the director sandbox.
- **AdGuard `*.lab.lan` wildcard** lives on the AdGuard LXC (`.53`), off this VM —
  unaffected by the revert.
- **OpenShell inference routing** — re-run the `openshell provider create` +
  `openshell inference set` commands from `docs/current/todos.md` step 6 (use explicit
  `--gateway-endpoint` for the lab 17670 gateway).

## New issues surfaced during the Docker + NemoClaw migration session

### openclaw.lab.lan Bad Gateway (or 502) / director stuck in Provisioning
- Symptom: long "Still creating sandbox in gateway..." (hundreds of seconds), "Create stream exited with code 1 after sandbox was created.", `nemoclaw director status` says Provisioning (or "not present"), no 18789 listener, route 502.
- Cause: async provisioning after the create (supervisor relay inside the container, OpenClaw startup, policy). The non-TTY create stream often exits 1 (harmless for the sandbox itself). Legacy Podman networks left "10.89" subnets that confused the nemoclaw gateway bind (we added 10.89.0.1 lo alias + iptables as workaround). Old docker "stopping" state deserial errors in the 0.0.44 driver.
- Fix / troubleshooting (run in shell with PATH + newgrp):
  - `nemoclaw director status` (note the exact phase and any "Connected: no").
  - `tail -f /home/debian/.local/state/nemoclaw/openshell-docker-gateway/openshell-gateway.log` (watch ListSandboxes, GetSandbox, supervisor relay, "CreateSandbox", any "stopping" errors).
  - If stuck: `nemoclaw director rebuild --yes` (recreates the container; workspace preserved). We cleaned old containers in the session.
  - Check listener/forward: `ss -tlnp | grep 18789`.
  - Test: `curl -k -H 'Host: openclaw.lab.lan' https://localhost/` (should become non-502 once Ready).
  - The pre-placed `traefik/dynamic/openclaw-nemoclaw.yml` (file provider) does the routing once 18789 is forwarded.
  - Connect: `nemoclaw director connect`.
  - Note the dual-gateway: director lives on the nemoclaw 8080 gateway (its 10.89 alias); lab sandboxes on 17670.

### Dual-gateway / post-nemoclaw claude-code or lab commands use the wrong gateway (or 0.0.44 CLI)
- Symptom: `openshell sandbox ...` or status talks to the nemoclaw 8080 gateway; claude-code create fails or lacks `inference.local` envs; "provider already exists" or transport errors.
- Cause: nemoclaw onboard installs its own 0.0.44 CLI (in ~/.local/bin and ~/.npm-global/bin) and registers its gateway as the default "openshell"/"nemoclaw". It may overwrite `~/.config/openshell/gateway.env` with a full 8080/disable-TLS config. The lab needs the separate 17670 gateway (restored 0.0.62 via re-install of the package) + the simple repo `gateway.env`.
- Fix:
  - Always restore after nemoclaw: `ln -sfn ~/home-lab/openshell/gateway.env ~/.config/openshell/gateway.env` (must be the simple driver=docker + BIND=0.0.0.0 version from the repo; never the nemoclaw full one).
  - For lab commands use the explicit 17670 endpoint + the 0.0.62 binary:
    `/usr/bin/openshell --gateway-endpoint http://127.0.0.1:17670 --gateway-insecure ...` (or https if TLS certs loaded).
  - Recreate claude-code exactly as in todos.md step 9 (full --env).
  - If the systemd openshell-gateway service is now bound to the nemoclaw side, start the lab one manually:
    `env $(cat ~/.config/openshell/gateway.env | grep = | xargs) /usr/bin/openshell-gateway --bind-address 0.0.0.0 --port 17670 ...` (plus TLS flags from ~/.local/state/openshell/tls/ if desired).
  - Use `openshell gateway list` / `gateway select openshell` to manage which is active.
- The 10.89 alias + iptables (added in session) are only for the nemoclaw gateway's internal reachability.

### Traefik dashboard 404 (or 405 on HEAD) even with correct labels on the container
- Symptom: `curl -k -H 'Host: traefik.lab.lan' https://localhost/` (and /dashboard) return 404; /api also 404s.
- Cause: Docker provider keeps failing ("client version 1.24 too old", min 1.40) even with DOCKER_API_VERSION=1.41 in compose (the env ends up in the container after force-recreate, but the SDK inside the v3.3 image still reports the old version). Labels on containers (including the traefik dashboard router) are never loaded.
- Fix (done in session): added static `traefik/dynamic/traefik-dashboard.yml` (file provider is reliable). The original container labels are still in compose.yml but are secondary. Access `https://traefik.lab.lan/dashboard/` (trailing slash). Root may still 404 or 405 on HEAD tests (curl -I); real GETs to /dashboard/ now return the UI HTML.
- Workaround is permanent until the provider is fixed (newer Traefik image with updated SDK, or accept and document).

### Other session notes
- After any nemoclaw run, the lab 17670 gateway may need a manual restart (fuser -k 17670/tcp; then start with the env + /usr/bin binary + TLS flags) because nemoclaw can take over the systemd service metadata.
- The 10.89.0.1 lo alias + iptables rules (added for nemoclaw gw) are still present; they can be removed once the director is stable if no longer needed.
- Lab claude-code recreate now uses the non-TTY-friendly form when driven by tools (a simple long-running command instead of `-- claude`); in an interactive shell the standard `-- claude` + separate `connect` + `claude login` works fine once the sandbox is Ready.
