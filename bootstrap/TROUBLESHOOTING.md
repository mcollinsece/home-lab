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
  host is rebuilt. The onboard wizard re-creates the sandbox.
- **AdGuard `*.lab.lan` wildcard** lives on the AdGuard LXC (`.53`), off this VM —
  unaffected by the revert.
- **OpenShell inference routing** — re-run the `openshell provider create` +
  `openshell inference set` commands from `docs/current/todos.md` step 6.
