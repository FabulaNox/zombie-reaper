# zombie-reaper

Find and safely reap zombie processes on Linux. Ships with systemd timer units
for both user-scope (no sudo) and system-scope (full coverage) installations.

A zombie process (`Z` state in `ps`) is an already-dead process whose parent has
not yet called `wait()` to collect its exit status. You cannot `kill` a zombie -
it is already dead. The standard mitigation is to nudge the parent with
`SIGCHLD`, which prompts the parent to call `wait()` on its children.

## Features

- **Inspect first, act second** - `--list` (default) reports zombies and the
  recommended action; `--nudge` performs the SIGCHLD; `--dry-run` previews.
- **Protected parents** - daemons such as `systemd`, `dockerd`, `sshd` get
  SIGCHLD only (never escalated). Configurable via `ZOMBIE_REAPER_PROTECTED`.
- **Stale detection** - parents older than `ZOMBIE_REAPER_STALE_SECS` (default
  3.5 days) are flagged as `warn` for manual review.
- **systemd timer** - runs every 6 hours, persistent across missed runs.
- **Pure bash 4+, no dependencies** beyond `ps`, `awk`, `kill` (plus `stat`/`mv`
  for log rotation - both standard coreutils/util-linux).

## Install

The install script is pure POSIX `sh` - no `make`, no build tools, no
runtime deps beyond `ps`/`awk`/`kill`.

### User scope (default - no sudo)

```sh
./install.sh
systemctl --user enable --now zombie-reaper.timer
```

Installs to:
- `~/.local/bin/zombie-reaper`
- `~/.config/systemd/user/zombie-reaper.{service,timer}`
- `~/.local/share/man/man1/zombie-reaper.1`

> **Headless / no-login boxes:** the user-scope timer only fires while you
> have an active session. For set-and-forget on a server you don't log into,
> either install system-scope (below) or enable lingering:
> `loginctl enable-linger "$USER"`.

### System scope (requires sudo - needed to reap zombies under other users)

```sh
./install.sh --system
sudo systemctl enable --now zombie-reaper.timer
```

Installs to:
- `/usr/local/bin/zombie-reaper`
- `/etc/systemd/system/zombie-reaper.{service,timer}`
- `/usr/local/share/man/man1/zombie-reaper.1`

### Schedule

The timer fires 10 minutes after the user session starts (`OnBootSec=10min`)
and every 6 hours thereafter (`OnUnitActiveSec=6h`). `Persistent=true` means
a missed run on a powered-off box catches up at the next start.

`systemctl --user list-timers zombie-reaper.timer` will show `NEXT=-` until
the service has run at least once - that's `OnUnitActiveSec` semantics, not a
bug. Run it once manually with `systemctl --user start zombie-reaper.service`
to seed the schedule.

### Uninstall

```sh
./install.sh --uninstall              # user scope
./install.sh --uninstall --system     # system scope
```

## Permissions caveat

`kill -CHLD <ppid>` only works when the caller can signal the parent process -
which means same UID, or root. A **user-scope** install will silently fail to
nudge zombies whose parents are owned by other users (system daemons, other
logged-in users). If you want to reap *all* zombies on the host, use the
**system-scope** install.

The output explicitly logs `permission denied` cases so you can tell whether a
particular zombie was skipped.

## Usage

```sh
zombie-reaper            # --list (default): inspect only
zombie-reaper --list
zombie-reaper --dry-run  # show what --nudge would do
zombie-reaper --nudge    # send SIGCHLD to each unique parent
```

### Configuration

| Environment variable | Default | Purpose |
|----------------------|---------|---------|
| `ZOMBIE_REAPER_PROTECTED` | `systemd\|init\|wazuh\|ossec\|dockerd\|containerd\|sshd` | Extended-regex alternation of parent process names that should *only* get SIGCHLD (never any escalation). |
| `ZOMBIE_REAPER_STALE_SECS` | `302400` (3.5 days) | Parents older than this are flagged `warn` after nudging. |
| `ZOMBIE_REAPER_LOG` | `/var/log/zombie-reaper/reaper.jsonl` (root) or `${XDG_STATE_HOME:-~/.local/state}/zombie-reaper/reaper.jsonl` | Path to the append-only JSONL run log. Set to empty (`ZOMBIE_REAPER_LOG=`) to disable file logging (journal only). |
| `ZOMBIE_REAPER_LOG_MAX_BYTES` | `1048576` (1 MiB) | Rotate the log to `<path>.1` once it reaches this size. On-disk footprint is bounded to twice this value. |

To override under systemd, drop a file at
`~/.config/systemd/user/zombie-reaper.service.d/override.conf` (user) or
`/etc/systemd/system/zombie-reaper.service.d/override.conf` (system):

```ini
[Service]
Environment="ZOMBIE_REAPER_PROTECTED=systemd|init|sshd|myappd"
Environment="ZOMBIE_REAPER_STALE_SECS=86400"
```

Then `systemctl daemon-reload`.

## Inspect logs

```sh
journalctl -t zombie-reaper                          # all runs
journalctl -t zombie-reaper --since "24h ago"        # last 24h
journalctl --user -t zombie-reaper                   # user-scope install
systemctl status zombie-reaper.timer                 # next run
systemctl list-timers zombie-reaper.timer
```

## Durable log (JSONL)

Each run appends one JSON object to `ZOMBIE_REAPER_LOG`. The record carries the
run totals plus a per-parent tally so you can see **who spawned how many zombie
children, and how many were reaped**:

```json
{"ts":"2026-05-22T14:03:01+03:00","host":"myhost","mode":"nudge","zombies_found":9,"parents_nudged":3,"reaped":5,"remaining":4,"warnings":1,"parents":[{"cmd":"myappd","pid":1234,"found":3,"reaped":3,"action":"sigchld","skip_reason":null}]}
```

`action` is `sigchld` | `warn` | `skip`. A `skip` carries a `skip_reason` of
`gone`, `defunct` (the parent is itself a zombie), or `kernel-thread` (kernel
threads are never signalled).

Query it with standard tools (no special dependency):

```sh
tail -n 1 /var/log/zombie-reaper/reaper.jsonl | python3 -m json.tool   # last run, pretty
grep '"reaped":0' /var/log/zombie-reaper/reaper.jsonl                  # runs that reaped nothing
jq '.parents[] | select(.reaped==0 and .found>0)' reaper.jsonl         # parents that ignored SIGCHLD (jq optional)
```

The log rotates to `reaper.jsonl.1` once it reaches `ZOMBIE_REAPER_LOG_MAX_BYTES`,
so total disk use stays bounded. Logging is best-effort: a write failure logs a
warning to the journal and never aborts a reap.

## Development

Three checks gate every push:

```sh
shellcheck src/zombie-reaper.sh scripts/sanitisation-gate.sh install.sh
bats tests/
sh scripts/sanitisation-gate.sh .sanitisation-patterns
```

Requires `shellcheck` and `bats` (Debian/Ubuntu: `apt install shellcheck bats`).

## Known issues

See [docs/known-issues.md](docs/known-issues.md) - notably, `speech-dispatcher`
spawns workers it never reaps; the zombie is harmless but always appears in the
report. This is an upstream bug, not a zombie-reaper bug.

## License

Apache 2.0 - see [LICENSE](LICENSE) and [NOTICE](NOTICE).
