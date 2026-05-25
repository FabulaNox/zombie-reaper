#!/usr/bin/env bats
# Unit tests for the escalation_action() decision function.
# We source the script (the BASH_SOURCE guard prevents main from running).

setup() {
    # shellcheck source=../src/zombie-reaper.sh
    source "${BATS_TEST_DIRNAME}/../src/zombie-reaper.sh"
}

@test "empty parent name => skip" {
    [ "$(escalation_action '')" = "skip" ]
}

@test "dead-parent sentinel => skip" {
    [ "$(escalation_action '<dead parent>')" = "skip" ]
}

@test "protected parent, fresh => sigchld" {
    [ "$(escalation_action 'systemd' 100)" = "sigchld" ]
    [ "$(escalation_action 'dockerd' 60)" = "sigchld" ]
    [ "$(escalation_action 'sshd' 1000)" = "sigchld" ]
}

@test "protected parent, stale => warn" {
    [ "$(escalation_action 'systemd' 999999)" = "warn" ]
    [ "$(escalation_action 'dockerd' 302401)" = "warn" ]
}

@test "protected parent, exactly at threshold => sigchld (not stale yet)" {
    # threshold is strict >, so age == STALE_SECS should be sigchld
    [ "$(escalation_action 'systemd' 302400)" = "sigchld" ]
}

@test "unknown parent, fresh => sigchld" {
    [ "$(escalation_action 'myappd' 100)" = "sigchld" ]
    [ "$(escalation_action 'nginx' 86400)" = "sigchld" ]
}

@test "unknown parent, stale => warn" {
    [ "$(escalation_action 'myappd' 999999)" = "warn" ]
}

@test "missing age argument defaults to 0 => sigchld" {
    [ "$(escalation_action 'systemd')" = "sigchld" ]
    [ "$(escalation_action 'somebodydaemon')" = "sigchld" ]
}

@test "custom protected list via env" {
    # Re-source with override
    ZOMBIE_REAPER_PROTECTED='myappd|otherd' \
        source "${BATS_TEST_DIRNAME}/../src/zombie-reaper.sh"
    [ "$(escalation_action 'myappd' 100)" = "sigchld" ]
    [ "$(escalation_action 'myappd' 999999)" = "warn" ]
}

@test "custom stale threshold via env" {
    ZOMBIE_REAPER_STALE_SECS=60 \
        source "${BATS_TEST_DIRNAME}/../src/zombie-reaper.sh"
    [ "$(escalation_action 'nginx' 30)" = "sigchld" ]
    [ "$(escalation_action 'nginx' 120)" = "warn" ]
}

@test "ZOMBIE_REAPER_LOG unset => non-empty default path ending in reaper.jsonl" {
    # setup() already sourced the script (setting the default), so unset first
    # to exercise the genuinely-unset path.
    unset ZOMBIE_REAPER_LOG
    source "${BATS_TEST_DIRNAME}/../src/zombie-reaper.sh"
    [ -n "$ZOMBIE_REAPER_LOG" ]
    case "$ZOMBIE_REAPER_LOG" in
        */zombie-reaper/reaper.jsonl) : ;;
        *) printf 'unexpected path: %s\n' "$ZOMBIE_REAPER_LOG"; return 1 ;;
    esac
}

@test "ZOMBIE_REAPER_LOG set to empty stays empty (logging disabled)" {
    # Plain assignment (not a VAR=val source prefix): setup() already sourced the
    # script and set the default, so we must establish the empty value in THIS
    # shell before re-sourcing. The script must then leave it empty (disabled).
    ZOMBIE_REAPER_LOG=""
    source "${BATS_TEST_DIRNAME}/../src/zombie-reaper.sh"
    [ -z "$ZOMBIE_REAPER_LOG" ]
}

@test "ZOMBIE_REAPER_LOG_MAX_BYTES defaults to 1048576" {
    unset ZOMBIE_REAPER_LOG_MAX_BYTES
    source "${BATS_TEST_DIRNAME}/../src/zombie-reaper.sh"
    [ "$ZOMBIE_REAPER_LOG_MAX_BYTES" -eq 1048576 ]
}

@test "ZOMBIE_REAPER_LOG_MAX_BYTES non-numeric falls back to default" {
    unset ZOMBIE_REAPER_LOG_MAX_BYTES
    ZOMBIE_REAPER_LOG_MAX_BYTES="abc"
    source "${BATS_TEST_DIRNAME}/../src/zombie-reaper.sh"
    [ "$ZOMBIE_REAPER_LOG_MAX_BYTES" -eq 1048576 ]
}

@test "json_escape: plain string is unchanged" {
    [ "$(json_escape 'hello world')" = "hello world" ]
}

@test "json_escape: double quotes are escaped" {
    [ "$(json_escape 'say "hi"')" = 'say \"hi\"' ]
}

@test "json_escape: backslash is escaped (and done before quotes)" {
    [ "$(json_escape 'a\b')" = 'a\\b' ]
}

@test "json_escape: tab and newline become \\t and \\n" {
    run json_escape "$(printf 'a\tb\nc')"
    [ "$output" = 'a\tb\nc' ]
}

@test "json_escape: carriage return becomes \\r" {
    run json_escape "$(printf 'a\rb')"
    [ "$output" = 'a\rb' ]
}

@test "json_escape: no argument under set -u returns empty (no crash)" {
    run bash -c 'set -u; source "'"${BATS_TEST_DIRNAME}"'/../src/zombie-reaper.sh"; json_escape'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "stat_is_zombie: Z, Zl, Z+ are zombies" {
    stat_is_zombie "Z"
    stat_is_zombie "Zl"
    stat_is_zombie "Z+"
}

@test "stat_is_zombie: S, R, Ss, and empty are not zombies" {
    ! stat_is_zombie "S"
    ! stat_is_zombie "R"
    ! stat_is_zombie "Ss"
    ! stat_is_zombie ""
}

@test "stat_is_zombie: no argument under set -u does not crash (and is not a zombie)" {
    run bash -c 'set -u; source "'"${BATS_TEST_DIRNAME}"'/../src/zombie-reaper.sh"; stat_is_zombie; echo "status=$?"'
    [ "$status" -eq 0 ]
    [ "$output" = "status=1" ]
}

@test "is_kernel_thread: PID 2 (kthreadd) is a kernel thread" {
    [ -r /proc/2/cmdline ] || skip "no readable /proc/2 on this host"
    is_kernel_thread 2
}

@test "is_kernel_thread: the test's own shell PID is not a kernel thread" {
    [ -r /proc/$$/cmdline ] || skip "no readable /proc on this host"
    ! is_kernel_thread "$$"
}

@test "is_kernel_thread: a nonexistent PID is not reported as a kernel thread" {
    ! is_kernel_thread 999999
}

@test "is_kernel_thread: no argument under set -u does not crash (and is not a kernel thread)" {
    run bash -c 'set -u; source "'"${BATS_TEST_DIRNAME}"'/../src/zombie-reaper.sh"; is_kernel_thread; echo "status=$?"'
    [ "$status" -eq 0 ]
    [ "$output" = "status=1" ]
}

@test "write_log_record: empty ZOMBIE_REAPER_LOG writes nothing" {
    # Plain assignment before source: a VAR=val source prefix doesn't persist
    # after source when the var was already set by setup(). Must exercise the
    # empty-disable early return, so set empty in THIS shell first.
    source "${BATS_TEST_DIRNAME}/../src/zombie-reaper.sh"
    ZOMBIE_REAPER_LOG=""
    run write_log_record '{"x":1}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "write_log_record: appends one line to the target file" {
    # Plain assignment before source: VAR=val source prefix doesn't persist
    # after source when the var was already set in the outer shell.
    local f="$BATS_TEST_TMPDIR/r.jsonl"
    unset ZOMBIE_REAPER_LOG
    ZOMBIE_REAPER_LOG="$f"
    source "${BATS_TEST_DIRNAME}/../src/zombie-reaper.sh"
    write_log_record '{"a":1}'
    write_log_record '{"a":2}'
    [ "$(wc -l < "$f")" -eq 2 ]
    [ "$(sed -n 1p "$f")" = '{"a":1}' ]
}

@test "write_log_record: rotates to .1 once over the byte cap" {
    local f="$BATS_TEST_TMPDIR/r.jsonl"
    unset ZOMBIE_REAPER_LOG ZOMBIE_REAPER_LOG_MAX_BYTES
    ZOMBIE_REAPER_LOG="$f"
    ZOMBIE_REAPER_LOG_MAX_BYTES=10
    source "${BATS_TEST_DIRNAME}/../src/zombie-reaper.sh"
    write_log_record '{"first":"record-well-over-ten-bytes"}'  # file now > 10 bytes
    write_log_record '{"second":1}'                            # triggers rotation
    [ -f "$f.1" ]
    grep -q '"first"'  "$f.1"
    grep -q '"second"' "$f"
}

@test "write_log_record: unwritable directory does not abort (exit 0)" {
    # Plain assignment before source so the unwritable path actually persists
    # into this shell and the mkdir-failure branch is genuinely exercised.
    unset ZOMBIE_REAPER_LOG
    ZOMBIE_REAPER_LOG="/proc/cannot/create/here/r.jsonl"
    source "${BATS_TEST_DIRNAME}/../src/zombie-reaper.sh"
    run write_log_record '{"x":1}'
    [ "$status" -eq 0 ]
    [ ! -e "/proc/cannot/create/here/r.jsonl" ]   # nothing was actually written
}

# --- integration: real zombie -> JSONL record ---

# Spawn a process that leaves one zombie child, print the parent PID.
# The parent lives 30s (not 3s): on a slow CI runner the parent could otherwise
# exit before the script scans, reparenting the zombie to init where it is reaped
# - which showed up as a flaky "No zombie processes found" failure.
_spawn_zombie_parent() {
    bash -c 'sleep 0 & exec sleep 30' &
    echo $!
}

# Poll up to ~3s for at least one zombie to actually appear. Returns non-zero if
# none does (a hostile sandbox that reaps instantly) so callers can skip rather
# than fail on an environment quirk.
_wait_for_zombie() {
    local i=0
    while (( i < 30 )); do
        ps -eo stat= | grep -q '^Z' && return 0
        sleep 0.1
        i=$(( i + 1 ))
    done
    return 1
}

@test "integration: --list writes one valid JSONL record with expected keys" {
    command -v python3 >/dev/null 2>&1 || skip "python3 not available to validate JSON"
    local f="$BATS_TEST_TMPDIR/run.jsonl"
    local ppid
    ppid=$(_spawn_zombie_parent)
    if ! _wait_for_zombie; then
        kill "$ppid" 2>/dev/null || true
        skip "environment did not hold a zombie long enough to observe"
    fi

    ZOMBIE_REAPER_LOG="$f" bash "${BATS_TEST_DIRNAME}/../src/zombie-reaper.sh" --list

    kill "$ppid" 2>/dev/null || true

    [ -f "$f" ]
    [ "$(wc -l < "$f")" -eq 1 ]
    python3 -m json.tool < "$f" >/dev/null
    run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(sorted(d)))' "$f"
    [[ "$output" == *"host"* ]]
    [[ "$output" == *"mode"* ]]
    [[ "$output" == *"parents"* ]]
    [[ "$output" == *"reaped"* ]]
    [[ "$output" == *"zombies_found"* ]]
    run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["mode"], d["zombies_found"]>=1)' "$f"
    [[ "$output" == "list True" ]]
    # Per-parent objects (the feature the user asked for) must carry the full
    # key set - guards against a typo'd field name shipping green.
    run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); ps=d["parents"]; print(all(set(p)=={"cmd","pid","found","reaped","action","skip_reason"} for p in ps) or not ps)' "$f"
    [ "$output" = "True" ]
}

@test "integration: empty ZOMBIE_REAPER_LOG produces no file (and exits 0)" {
    local f="$BATS_TEST_TMPDIR/none.jsonl"
    run env ZOMBIE_REAPER_LOG="" bash "${BATS_TEST_DIRNAME}/../src/zombie-reaper.sh" --list
    [ "$status" -eq 0 ]   # disabled logging must never abort the run
    [ ! -e "$f" ]
}

@test "integration: --dry-run reports parents_nudged 0 and signals nothing" {
    command -v python3 >/dev/null 2>&1 || skip "python3 not available to validate JSON"
    local f="$BATS_TEST_TMPDIR/dry.jsonl"
    local ppid
    ppid=$(_spawn_zombie_parent)
    if ! _wait_for_zombie; then
        kill "$ppid" 2>/dev/null || true
        skip "environment did not hold a zombie long enough to observe"
    fi

    ZOMBIE_REAPER_LOG="$f" bash "${BATS_TEST_DIRNAME}/../src/zombie-reaper.sh" --dry-run

    kill "$ppid" 2>/dev/null || true

    [ -f "$f" ]
    run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["mode"], d["parents_nudged"]==0, d["reaped"]==0)' "$f"
    [ "$output" = "dry-run True True" ]
}
