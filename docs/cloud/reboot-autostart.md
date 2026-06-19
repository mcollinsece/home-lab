# Reboot Autostart (EC2)

> Status as of the 2026-06-19 EC2 deployment. **Implementation deferred** — this
> documents what survives a reboot today and the services to add to close the gaps.
> See also [aws-ec2-deployment.md](aws-ec2-deployment.md).

## What survives a reboot today

| Component | Mechanism | Survives? |
|---|---|---|
| Docker daemon | `systemctl enable docker` | ✅ |
| Compose services (Traefik, Portainer, Registry, LiteLLM) | `restart: unless-stopped` | ✅ |
| OpenShell lab gateway (`:17670`) | systemd `--user` + linger | ✅ |
| OpenClaw socat relay (`172.19.0.1:18790`) | `openclaw-socat-relay.service` (user) | ✅ (retries until tunnel up) |
| Credential-sync timers (claude/grok, daily) | `sync-*-creds.timer` (user) | ✅ |
| Sandbox **containers** (claude-revproxy, grok-wrapper, my-assistant) | `restart: unless-stopped` | ✅ container only |
| ai-net membership of sandboxes (aliases) | persisted by Docker | ✅ |

## What does NOT survive (the gaps)

The sandbox **containers** restart, but processes launched inside them via
`docker exec -d` are **not** restarted with the container:

1. **Claude Code wrapper** (`uvicorn` on `:8000`) — re-run
   `bootstrap/setup-claude-revproxy.sh`.
2. **Grok wrapper** (`uvicorn` on `:8001`) — re-run `bootstrap/setup-grok-wrapper.sh`.
3. **OpenClaw director** — the `openclaw` process, the host SSH tunnel that serves
   `127.0.0.1:18789`, and the dashboard port-forward are managed host-side by
   NemoClaw and are not re-established on boot. Recover with:
   `nemoclaw my-assistant recover`.

The socat relay (gap-free itself) depends on the SSH tunnel from #3, so until the
director is recovered, `openclaw.lab.lan` returns 502.

### Manual recovery after a reboot (until services are added)

```bash
cd ~/home-lab
nemoclaw my-assistant recover            # director: openclaw + tunnel + port-forward
sg docker -c 'bootstrap/setup-claude-revproxy.sh'   # claude wrapper :8000
sg docker -c 'bootstrap/setup-grok-wrapper.sh'      # grok wrapper :8001
# socat relay auto-recovers once 127.0.0.1:18789 is back
```

## Proposed autostart services (to implement later)

Add three `systemd --user` units (linger already enabled). Ordering:
`docker.service` → director recover → wrappers → (socat relay already auto).

`~/.config/systemd/user/nemoclaw-director.service`
```ini
[Unit]
Description=Recover NemoClaw OpenClaw director (openclaw + SSH tunnel + port-forward)
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/sg docker -c "%h/.npm-global/bin/nemoclaw my-assistant recover"
# Retry until docker + gateway are ready
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
```

`~/.config/systemd/user/claude-wrapper.service`
```ini
[Unit]
Description=Claude Code wrapper (uvicorn :8000 in claude-revproxy sandbox)
After=docker.service nemoclaw-director.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/sg docker -c "%h/home-lab/bootstrap/setup-claude-revproxy.sh"
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
```

`~/.config/systemd/user/grok-wrapper.service`
```ini
[Unit]
Description=Grok wrapper (uvicorn :8001 in grok-wrapper sandbox)
After=docker.service nemoclaw-director.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/sg docker -c "%h/home-lab/bootstrap/setup-grok-wrapper.sh"
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
```

Enable with:
```bash
systemctl --user daemon-reload
systemctl --user enable nemoclaw-director.service claude-wrapper.service grok-wrapper.service
```

> Notes:
> - The wrapper scripts are idempotent (sync creds, ensure ai-net, (re)start uvicorn),
>   so running them on every boot is safe.
> - `sg docker -c` is required because the login shell's primary group does not include
>   `docker` until a fresh login; the user-manager picks it up after
>   `sudo systemctl restart user@$(id -u).service` (done once during host setup).
> - Validate the full chain after a real reboot before relying on it (tracked with
>   item 3 in the deployment punchlist).
```
