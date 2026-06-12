# Bootstrap / OpenShell troubleshooting

Runbook for reproducing the host with [`setup-host.sh`](setup-host.sh) — written
from the actual failure modes hit during the first build (2026-06-12). Lives in
the repo on purpose: after a VM snapshot revert this is the only copy you have.

## How the script is ordered (don't reorder)
1. base pkgs → Node 22 → linger → `podman.socket` → Quadlet symlinks
2. **OpenShell install** — the gateway starts here on its default `127.0.0.1` bind
3. **gateway.env symlink + gateway restart** — this flips the gateway to
   `0.0.0.0` bind + the `podman` driver. Step 3 *must* run after step 2.

## Symptom → cause → fix

### Sandbox stuck in `Error`; `podman logs openshell-sandbox-<name>` shows `Policy fetch failed after 5 attempts: failed to connect to OpenShell server`
**The #1 gotcha.** The gateway is bound to `127.0.0.1`. Sandbox containers reach
the gateway over the host bridge (`host.containers.internal` → bridge gateway IP),
not loopback, so they can't connect.
- Check the bind: `ss -tlnp | grep 17670` → must be `0.0.0.0:17670`, **not** `127.0.0.1`.
- Check config: `ls -l ~/.config/openshell/gateway.env` (should be a symlink to the
  repo) and `grep BIND ~/.config/openshell/gateway.env` → `OPENSHELL_BIND_ADDRESS=0.0.0.0`.
- Fix: ensure the symlink exists, then `systemctl --user restart openshell-gateway`.

### `openshell doctor check` reports a Docker error
Cosmetic — it always probes Docker even on the Podman driver. Confirm the real
backend instead:
```
journalctl --user -u openshell-gateway | grep -E 'compute driver|Connected to Podman'
```
Expect `Using compute driver driver=podman` and `Connected to Podman ... rootless=true`.

### Gateway came up on the wrong driver (docker / auto)
`gateway.env` wasn't loaded. Verify the symlink and `OPENSHELL_DRIVERS=podman`, and
that the socket exists: `systemctl --user enable --now podman.socket` (the driver's
default socket is `$XDG_RUNTIME_DIR/podman/podman.sock`). Restart the gateway.

### `claude login` → `Failed to connect to <host>` / `ERR_BAD_REQUEST`
Deny-by-default egress blocked a host the login flow needs. Add it to
`openshell/policies/claude-code.yaml`, then hot-reload onto the running sandbox:
```
openshell policy set claude-code --policy openshell/policies/claude-code.yaml --wait
```
Known-good host set (already in the committed policy): `api.anthropic.com`,
`platform.claude.com` (Claude Code 2.x login), `claude.ai`, `console.anthropic.com`,
`statsig.anthropic.com`, `sentry.io`. If a *new* host appears, add it the same way.

### `openshell logs <name> --tail` hangs
`--tail` follows the stream (never returns in a script). Use it without `--tail`, or
go straight to the source: `journalctl --user -u openshell-gateway` (gateway) /
`podman logs openshell-sandbox-<name>` (in-container supervisor stderr).

### `apt install nodejs` prints `dpkg-preconfigure: unable to re-open stdin`
Harmless — just means no TTY. Node still installs.

## Where to look first
| What | Command |
|---|---|
| Gateway health | `openshell status` · `systemctl --user status openshell-gateway` |
| Gateway logs | `journalctl --user -u openshell-gateway -n 100 --no-pager` |
| Sandbox phase | `openshell sandbox list` |
| Sandbox internals | `podman logs openshell-sandbox-<name>` |
| Listening bind | `ss -tlnp | grep 17670` |

## After a clean snapshot revert — expected, not bugs
- **OpenShell mTLS** certs regenerate on install (`~/.local/state/openshell/tls/`,
  not in git) — the gateway re-pairs automatically.
- **Portainer** admin account + data live in a Podman volume (runtime state, not
  git) → you'll repeat Portainer's first-run setup.
- **`claude-code` sandbox + `claude login`** are manual post-steps (not in the
  script — see `openshell/README.md`).
- **AdGuard `*.lab.lan` wildcard** lives on the AdGuard LXC (`.53`), off this VM —
  unaffected by the revert.
- The script's last lines print the sandbox-create + quadlet-start commands it does
  **not** run for you.
