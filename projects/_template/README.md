# Project template — a service that "just works" with Traefik

Copy this directory to start a new service:

```bash
cp -r projects/_template projects/<name>
```

Then pick **one** of the two deployment styles below. Both produce the same result:
the service is reachable at `http://<name>.lab.lan` with no Traefik config edits.

## How the routing works (read once)

Traefik watches the rootless Podman socket and auto-creates a route for any
container labelled `traefik.enable=true`. The hostname comes from the **container
name** via the provider's `defaultRule` (`Host(\`{{ normalize .Name }}.lab.lan\`)`).
So the entire integration is usually a name + one label.

Three rules to remember:

1. **Name the container.** In Quadlets set `ContainerName=<name>`; in compose set
   `container_name: <name>`. Otherwise the name is `systemd-<unit>` / `<project>_<svc>`
   and you'll get an ugly host.
2. **Declare the port only if it isn't 80.** If the app listens on something else,
   add `traefik.http.services.<name>.loadbalancer.server.port=<port>`. Traefik can't
   guess when an image exposes multiple ports.
3. **Be on `ai-net`.** That's the network Traefik routes over.

DNS: a single wildcard `*.lab.lan → 192.168.0.51` in AdGuard makes every name
resolve. Until that's set, test with `curl -H 'Host: <name>.lab.lan' http://192.168.0.51/`.

## Option A — Quadlet (preferred, systemd-native)

Files: `app.container`, `Containerfile` (if building), `env.example`.

```bash
mv app.container <name>.container          # and replace every <name> inside
cp env.example <name>.env                  # fill in; gitignored
# build your image if needed:
podman build -t localhost:5000/<name>:0.1.0 projects/<name> && podman push localhost:5000/<name>:0.1.0
ln -sf ~/home-lab/projects/<name>/<name>.container ~/.config/containers/systemd/<name>.container
systemctl --user daemon-reload
systemctl --user start <name>.service
```

Teardown (clean, no leftovers):

```bash
systemctl --user disable --now <name>.service
rm ~/.config/containers/systemd/<name>.container
systemctl --user daemon-reload
podman rmi localhost:5000/<name>:0.1.0      # optional
```

## Option B — Compose (quick experiments / upstream stacks)

File: `compose.yaml`.

```bash
cd projects/<name>
podman compose up -d
# ...
podman compose down                         # teardown
```

Both styles attach to the same `ai-net` and are discovered by the same Traefik —
mix and match per project.
