# deploy

Files that run Meru as a service and show what it is doing:

| Path | What it does |
| --- | --- |
| `launchd/com.meru.merud.plist` | starts `merud` at login on macOS and restarts it if it exits |
| `systemd/merud.service` | the same on Linux, as a systemd user unit |
| `systemd/meru-searxng.container` | runs SearXNG with rootless Podman and exposes it on loopback only |
| `observability/compose.yaml` | a local Grafana stack that receives `merud`'s metrics and traces |
| `observability/dashboards/meru.json` | the Meru dashboard that stack loads |
| `observability/dashboards/meru-usage.json` | the Meru usage dashboard: totals for the chosen range, then one bar per hour over the last 24 hours |

The release installer puts `merud` in `~/.local/bin`, which is the path in the
Linux unit and the release form of the Mac commands below. Run it with:

```sh
curl -fsSL https://github.com/aarora79/meru/releases/latest/download/install.sh | bash
```

If you build from source with `go install ./cmd/merud`, the binary goes in
`~/go/bin`. Keep that source-build edit separate from the canonical release
unit:

```sh
mkdir -p ~/.config/systemd/user
sed 's|%h/.local/bin/merud|%h/go/bin/merud|' deploy/systemd/merud.service \
  > ~/.config/systemd/user/merud.service
```

## macOS: launchd

launchd reads agents from `~/Library/LaunchAgents/`. It doesn't expand `~` or
`$HOME`, so the plist uses `__HOME__` as a placeholder, and `sed` fills in your home
directory while copying it:

```sh
mkdir -p ~/.meru
sed "s|__HOME__|$HOME|g" deploy/launchd/com.meru.merud.plist \
  > ~/Library/LaunchAgents/com.meru.merud.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.meru.merud.plist
```

If you installed a release, `merud` lives in `~/.local/bin`. Run this copy in
place of the `sed` line above; its first expression points the plist there:

```sh
sed -e "s|__HOME__/go/bin/merud|$HOME/.local/bin/merud|" -e "s|__HOME__|$HOME|g" \
  deploy/launchd/com.meru.merud.plist > ~/Library/LaunchAgents/com.meru.merud.plist
```

`merud` now starts each time you log in, and launchd starts it again if it exits.
Anything `merud` prints before its own log opens goes to `~/.meru/merud.out.log` and
`~/.meru/merud.err.log`.

Check it, restart it, or remove it:

```sh
launchctl print gui/$(id -u)/com.meru.merud      # state and last exit code
launchctl kickstart -k gui/$(id -u)/com.meru.merud
launchctl bootout gui/$(id -u)/com.meru.merud
```

## Linux: systemd

The release installer does these steps after `meru setup` has written a config.
To do them by hand, install the unit for your user, so `merud` runs as you and
reads your `~/.meru`:

```sh
mkdir -p ~/.config/systemd/user
cp deploy/systemd/merud.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now merud
```

systemd restarts `merud` after a crash, and leaves it stopped after
`systemctl --user stop merud`. A user unit starts when you log in. To start it at
boot, before anyone logs in, as on a home server or a cloud machine you reach over
SSH, turn on lingering once:

```sh
sudo loginctl enable-linger "$USER"
```

Check it and read its output:

```sh
systemctl --user status merud
journalctl --user -u merud -n 50 --no-pager
```

The installer asks before it runs `sudo loginctl enable-linger "$USER"`. Say yes
only when this is a server that should keep Meru running after you log out. The
choice is not needed on a workstation where your login session stays open.

### SearXNG with rootless Podman

The release installer prefers a working rootless Podman, then falls back to a
working Docker daemon. It installs neither. With Podman, it copies the Quadlet
to `~/.config/containers/systemd/meru-searxng.container`, reloads the user
manager and starts `meru-searxng.service`. The Quadlet's `[Install]` section
wires it to `default.target` each time the generator runs. The generated service
mounts `~/.meru/searxng` and publishes only `127.0.0.1:8888`.

Check or restart it with:

```sh
systemctl --user status meru-searxng
journalctl --user -u meru-searxng -n 50 --no-pager
systemctl --user restart meru-searxng
```

Use the same lingering choice as `merud` if SearXNG must run after logout. With
Docker, the installer creates the named container `meru-searxng` with restart
policy `unless-stopped`; inspect it with `docker ps -a --filter
name=meru-searxng` and `docker logs meru-searxng`.

## Windows

Meru has no Windows service wrapper yet; that is future work. Until then, start
`merud.exe` by hand or from a Task Scheduler task that runs at log on.

## Observability stack

`observability/compose.yaml` runs one container, `grafana/otel-lgtm`, which holds an
OpenTelemetry Collector, Prometheus, Tempo, Loki and Grafana, with Meru's two
dashboards in `observability/dashboards/`.
[docs/observability.md](../docs/observability.md) shows how to start it, point
`merud` at it, read the dashboards, query the metrics from the command line and
stop it.
