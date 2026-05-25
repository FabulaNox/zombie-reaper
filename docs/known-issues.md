# Known issues

## `speech-dispatcher` zombies are persistent

If `speech-dispatcher` is running, it spawns `sd_espeak-ng-mb` (or equivalent
TTS engine) workers that it does not reap. SIGCHLD has no effect - the parent
ignores it. The zombies are harmless and the kernel still reclaims memory; only
the PID slot remains occupied.

zombie-reaper will report these every run with a `warn` flag once the parent
exceeds the stale threshold. There is no fix from the zombie-reaper side; it is
an upstream `speech-dispatcher` bug.

To silence the report for this specific case, stop and disable the
speech-dispatcher service (most desktop systems do not need it running unless
you actively use a screen reader).

## Snap loop devices (related class of problem, out of scope)

A related but distinct class of orphaned-kernel-object problem is the snap loop
device leak: snap deletes `.snap` files immediately after an upgrade, but
running processes hold the underlying `/dev/loop*` device open until they
restart. The result is `/dev/loop*` entries that show up in `lsblk` and the
file manager as "phantom drives".

zombie-reaper does not handle this - it is a separate problem requiring a udev
rule. Reference rule, save as `/etc/udev/rules.d/90-hide-snap-loops.rules`:

```
SUBSYSTEM=="block", KERNEL=="loop*", ENV{ID_LOOP_BACKING_FILENAME}=="/var/lib/snapd/snaps/*", ENV{UDISKS_IGNORE}="1"
```

Then `sudo udevadm control --reload && sudo udevadm trigger`.

## "Permission denied" on user-scope installs

The user-scope systemd timer can only signal parent processes owned by the
same UID. Daemons running as root, systemd-managed services, or processes
owned by other users will produce a `permission denied` line in the journal.

This is intentional behaviour of the Linux kill(2) syscall, not a
zombie-reaper bug. If you need to reap zombies under any user, install with
system scope instead.

## Per-parent `reaped` is an approximation (count-diff attribution)

The per-parent `reaped` count is computed by comparing a parent's zombie-child
count before and after a ~2-second settle (`reaped = found - still_present`). It
attributes by counting, not by tracking individual PIDs, so two scenarios skew it:

- **Parent exits during the settle (over-count).** If the parent itself dies in
  the 2 s window, its still-unreaped zombies are reparented to PID 1 and vanish
  from the parent's count - so the parent is credited with reaping them when they
  merely moved. This is the most likely skew, and it inflates `reaped` in exactly
  the "parent crashed" case. The run-level `remaining` count stays accurate
  (those zombies are reaped by init shortly after).
- **Parent spawns new zombies during the settle (under-count).** A busy parent
  that reaps its old zombies but forks new ones shows little net change, so its
  `reaped` reads low.
- **PID reuse (negligible).** Attribution keys on PID; reuse within ~2 s is
  vanishingly unlikely.

These are inherent to a lightweight count-diff approach and are documented rather
than engineered around, consistent with the tool's best-effort design. The
run-level totals (`zombies_found`, `remaining`) are reliable; per-parent `reaped`
is a useful signal, not an exact ledger.

## `speech-dispatcher` shows `found > 0, reaped 0`

`speech-dispatcher` ignores `SIGCHLD`, so its zombie children are never reaped by a
nudge. In the JSONL log this surfaces as a parent with `found > 0` and `reaped: 0`
every run. This is the per-parent accounting working as intended - it distinguishes
a parent that cooperates from one that is stuck - not a zombie-reaper bug.
